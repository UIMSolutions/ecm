/// Login, JWT session handling and user administration.
///
/// Two kinds of bearer tokens are accepted (see AuthSettings.mode):
///  * own JWTs (HS256), issued by `login`/`refresh` and revocable via `logout`;
///  * XSUAA JWTs (RS256) forwarded by the SAP approuter. Their users are mapped to local
///    accounts (tenant = subdomain or the default tenant, role = highest ECM scope) and created
///    just in time if `autoProvision` is enabled.
/// Every request re-reads the user, so deactivation and role changes take effect immediately.
module uim.ecm.application.usecases.authservice;

import core.sync.mutex : Mutex;
import std.algorithm.searching : canFind, count;
import std.regex : matchFirst, regex;
import std.string : indexOf;
import uim.ecm.application.dtos;
import uim.ecm.ports.usecases;
import uim.ecm.ports;
import uim.ecm.domain;

/// Which bearer tokens the backend accepts.
enum AuthMode : string
{
    local = "local",   /// own JWTs only (login form)
    xsuaa = "xsuaa",   /// XSUAA tokens only (approuter); local login disabled
    hybrid = "hybrid"  /// both
}

struct AuthSettings
{
    AuthMode mode = AuthMode.local;
    long tokenTtlSeconds = 8 * 3600;
    /// Tenant used for XSUAA users whose subdomain does not match a tenant slug.
    string defaultTenantSlug = "default";
    /// Create unknown XSUAA users on their first request.
    bool autoProvision = true;
}

final class AuthService : AuthUseCases
{
    private UserRepository users;
    private TenantRepository tenants;
    private MembershipRepository members;
    private PasswordHasher hasher;
    private TokenService tokens;
    private TokenRevocationStore revoked;
    private ExternalTokenValidator external; // null = XSUAA disabled
    private IdGenerator ids;
    private TimeSource time;
    private AuthSettings settings;
    private EventPublisher events;
    private string dummyHash; // equalises timing for unknown users
    private Mutex provisioning;

    this(UserRepository users, TenantRepository tenants, MembershipRepository members,
         PasswordHasher hasher, TokenService tokens, TokenRevocationStore revoked,
         ExternalTokenValidator external, IdGenerator ids, TimeSource time, AuthSettings settings,
         EventPublisher events)
    {
        this.users = users; this.tenants = tenants; this.members = members;
        this.hasher = hasher; this.tokens = tokens; this.revoked = revoked; this.external = external;
        this.ids = ids; this.time = time; this.settings = settings; this.events = events;
        this.dummyHash = hasher.hash("timing-equaliser");
        this.provisioning = new Mutex;
    }

    /// Creates the first platform administrator when no user exists. Returns true if created.
    bool bootstrapPlatformAdmin(string username, string password)
    {
        if (users.count() > 0) return false;
        createUser(systemPrincipal, NewUser("", username, "Platform administrator", "", password, "admin"));
        return true;
    }

    // ---- authentication ----
    LoginResult login(string tenantSlug, string username, string password)
    {
        enum msg = "Invalid tenant, user name or password";
        if (settings.mode == AuthMode.xsuaa)
            throw new ForbiddenException("Local login is disabled; sign in through the identity provider");
        string tenantId;
        if (tenantSlug.length)
        {
            Tenant t;
            if (!tenants.bySlug(tenantSlug, t) || !t.active)
            {
                hasher.verify(password, dummyHash);
                throw new UnauthorizedException(msg);
            }
            tenantId = t.id;
        }
        User u;
        if (!users.byLogin(tenantId, username, u))
        {
            hasher.verify(password, dummyHash);
            throw new UnauthorizedException(msg);
        }
        if (!u.active || !u.passwordHash.length || !hasher.verify(password, u.passwordHash))
            throw new UnauthorizedException(msg);
        return issueFor(u);
    }

    /// Per request: one HMAC check, one revocation lookup and two hash lookups (no password hashing).
    Authentication authenticate(string bearerToken)
    {
        if (settings.mode != AuthMode.xsuaa)
        {
            TokenClaims c;
            if (tokens.verify(bearerToken, c))
            {
                if (revoked.isRevoked(c.tokenId)) throw new UnauthorizedException("Token has been revoked");
                auto u = activeUser(c.principal.userId);
                if (u.tenantId != c.principal.tenantId) throw new UnauthorizedException("Invalid token");
                return Authentication(principalOf(u), AuthMethod.local, c.tokenId, c.expiresAt);
            }
        }
        if (settings.mode != AuthMode.local && external !is null)
        {
            auto id = external.validate(bearerToken);
            if (!id.isNull)
            {
                auto u = mapExternal(id.get);
                return Authentication(principalOf(u), AuthMethod.xsuaa, "", id.get.expiresAt);
            }
        }
        throw new UnauthorizedException("Invalid or expired token");
    }

    LoginResult refresh(Authentication current)
    {
        if (current.method != AuthMethod.local)
            throw new ValidationException("Only tokens issued by this service can be refreshed");
        auto u = activeUser(current.principal.userId);
        revoked.revoke(current.tokenId, current.expiresAt); // one-time use: the old token stops working
        return issueFor(u);
    }

    void logout(Authentication current)
    {
        if (current.method == AuthMethod.local)
            revoked.revoke(current.tokenId, current.expiresAt);
    }

    SessionInfo session(Authentication current)
    {
        auto s = describe(findUser(current.principal.userId));
        s.method = current.method;
        s.expiresAt = current.expiresAt;
        return s;
    }

    void changePassword(Principal who, PasswordChange change)
    {
        auto u = findUser(who.userId);
        if (!u.passwordHash.length)
            throw new ValidationException("This account signs in through the identity provider");
        if (!hasher.verify(change.currentPassword, u.passwordHash))
            throw new ValidationException("The current password is not correct");
        validatePassword(change.newPassword);
        u.passwordHash = hasher.hash(change.newPassword);
        users.save(u);
    }

    private LoginResult issueFor(User u)
    {
        const now = time.now().toUnixTime();
        const exp = now + settings.tokenTtlSeconds;
        auto t = tokens.issue(principalOf(u), now, exp);
        LoginResult r;
        r.accessToken = t.token;
        r.expiresAt = exp;
        r.expiresIn = settings.tokenTtlSeconds;
        r.session = describe(u);
        r.session.expiresAt = exp;
        return r;
    }

    private static Principal principalOf(User u)
    {
        return Principal(u.id, u.username, u.tenantId, u.role); // always the current role
    }

    private User activeUser(string id)
    {
        User u;
        if (!users.find(id, u) || !u.active) throw new UnauthorizedException("User is not active");
        requireActiveTenant(u.tenantId);
        return u;
    }

    private void requireActiveTenant(string tenantId)
    {
        if (!tenantId.length) return;
        Tenant t;
        if (!tenants.find(tenantId, t) || !t.active) throw new UnauthorizedException("Tenant is not active");
    }

    /// Maps an XSUAA identity to a local account; scopes decide the role on every request.
    private User mapExternal(ExternalIdentity id)
    {
        bool platform = id.scopes.canFind("PlatformAdmin");
        Role role;
        if (platform || id.scopes.canFind("Admin")) role = Role.admin;
        else if (id.scopes.canFind("Editor")) role = Role.editor;
        else if (id.scopes.canFind("Viewer")) role = Role.viewer;
        else throw new ForbiddenException("No ECM role assigned in the identity provider");

        string tenantId;
        if (!platform)
        {
            Tenant t;
            if (!(id.subdomain.length && tenants.bySlug(id.subdomain, t))
                && !tenants.bySlug(settings.defaultTenantSlug, t))
                throw new UnauthorizedException("No tenant for this subaccount");
            if (!t.active) throw new UnauthorizedException("Tenant is not active");
            tenantId = t.id;
        }

        User u;
        if (users.byLogin(tenantId, id.userName, u))
        {
            if (!u.active) throw new UnauthorizedException("User is not active");
            if (u.role != role) { u.role = role; users.save(u); }
            return u;
        }
        if (!settings.autoProvision) throw new UnauthorizedException("Unknown user");

        provisioning.lock();
        scope (exit) provisioning.unlock();
        if (users.byLogin(tenantId, id.userName, u)) return u; // created by a concurrent request
        u.id = ids.next();
        u.tenantId = tenantId;
        u.username = id.userName;
        auto name = (id.givenName ~ " " ~ id.familyName);
        u.displayName = name.length > 1 ? name : id.userName;
        u.email = id.email;
        u.role = role;
        u.createdAt = time.now();
        users.save(u);
        return u;
    }

    private SessionInfo describe(User u)
    {
        SessionInfo s;
        s.user = u;
        Tenant t;
        if (u.tenantId.length && tenants.find(u.tenantId, t)) { s.tenantName = t.name; s.tenantSlug = t.slug; }
        return s;
    }

    // ---- user management: platform admins manage everyone, tenant admins their own tenant ----
    User[] listUsers(Principal who)
    {
        requireUserAdmin(who);
        return who.isPlatformAdmin ? users.all() : users.inTenant(who.tenantId);
    }

    User getUser(Principal who, string id)
    {
        auto u = findUser(id);
        return u.id == who.userId ? u : loadManaged(who, id);
    }

    User createUser(Principal who, NewUser n)
    {
        requireUserAdmin(who);
        string tenantId = who.isPlatformAdmin ? n.tenantId : who.tenantId;
        if (tenantId.length)
        {
            Tenant t;
            if (!tenants.find(tenantId, t)) throw new ValidationException("Unknown tenant");
        }
        if (matchFirst(n.username, regex(`^[A-Za-z0-9._-]{3,64}$`)).empty)
            throw new ValidationException("User name must have 3-64 characters (letters, digits, . _ -)");
        validatePassword(n.password);
        validateEmail(n.email);
        auto role = n.role.length ? parseRole(n.role) : Role.viewer;
        if (tenantId.length == 0 && role != Role.admin)
            throw new ValidationException("Platform users must be administrators");
        User existing;
        if (users.byLogin(tenantId, n.username, existing)) throw new ConflictException("User name already taken");
        User u;
        u.id = ids.next();
        u.tenantId = tenantId;
        u.username = n.username;
        u.displayName = n.displayName.length ? n.displayName : n.username;
        u.email = n.email;
        u.role = role;
        u.passwordHash = hasher.hash(n.password);
        u.createdAt = time.now();
        users.save(u);
        return u;
    }

    User updateUser(Principal who, string id, UserPatch p)
    {
        auto u = loadManaged(who, id);
        bool wasAdmin = u.role == Role.admin && u.active;
        if (!p.displayName.isNull) u.displayName = p.displayName.get;
        if (!p.email.isNull) { validateEmail(p.email.get); u.email = p.email.get; }
        if (!p.password.isNull) { validatePassword(p.password.get); u.passwordHash = hasher.hash(p.password.get); }
        if (!p.role.isNull) u.role = parseRole(p.role.get);
        if (!p.active.isNull) u.active = p.active.get;
        if (u.tenantId.length == 0 && u.role != Role.admin)
            throw new ValidationException("Platform users must be administrators");
        if (wasAdmin && !(u.role == Role.admin && u.active) && activeAdmins(u.tenantId) <= 1)
            throw new ConflictException("The last active administrator cannot be demoted or deactivated");
        users.save(u);
        return u;
    }

    void deleteUser(Principal who, string id)
    {
        auto u = loadManaged(who, id);
        if (id == who.userId) throw new ConflictException("You cannot delete yourself");
        if (u.role == Role.admin && u.active && activeAdmins(u.tenantId) <= 1)
            throw new ConflictException("The last active administrator cannot be deleted");
        foreach (m; members.ofUser(id)) members.remove(m.id);
        events.userRemoved(id);
        users.remove(id);
    }

    // ---- helpers ----
    private User findUser(string id)
    {
        User u;
        if (!users.find(id, u)) throw new NotFoundException("User '" ~ id ~ "' not found");
        return u;
    }

    private User loadManaged(Principal who, string id)
    {
        requireUserAdmin(who);
        auto u = findUser(id);
        if (!(who.isPlatformAdmin || (who.isTenantAdmin && u.tenantId == who.tenantId)))
            throw new NotFoundException("User '" ~ id ~ "' not found");
        return u;
    }

    private static void requireUserAdmin(Principal who)
    {
        if (!who.isPlatformAdmin && !who.isTenantAdmin) throw new ForbiddenException("Administrator required");
    }

    private size_t activeAdmins(string tenantId)
    {
        return users.inTenant(tenantId).count!(u => u.active && u.role == Role.admin);
    }

    private static void validatePassword(string pw)
    {
        if (pw.length < 8 || pw.length > 256) throw new ValidationException("Password must have 8-256 characters");
    }

    private static void validateEmail(string email)
    {
        if (email.length && email.indexOf('@') < 0) throw new ValidationException("Invalid e-mail address");
    }
}
