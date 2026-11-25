/// Integration tests: login, JWT verification, refresh, logout and XSUAA user mapping,
/// wired with the real adapters on a temporary data directory.
module authflow;

import std.exception : assertThrown;
import std.file : rmdirRecurse, tempDir, exists;
import std.path : buildPath;
import std.typecons : Nullable, nullable;
import std.uuid : randomUUID;
import uim.ecm.application.dtos;
import uim.ecm.application.services.accesspolicy;
import uim.ecm.application.usecases.authservice;
import uim.ecm.application.usecases.notificationservice;
import uim.ecm.application.usecases.tenancyservice;
import uim.ecm.domain;
import uim.ecm.infrastructure.clients.system;
import uim.ecm.infrastructure.security;
import uim.ecm.infrastructure.workers.threadpool;
import uim.ecm.persistence.repositories.repositories;
import uim.ecm.persistence.storages.tokenrevocation;
import uim.ecm.ports;

private final class StubXsuaa : ExternalTokenValidator
{
    ExternalIdentity[string] known;
    Nullable!ExternalIdentity validate(string token)
    {
        if (auto p = token in known) return nullable(*p);
        return Nullable!ExternalIdentity.init;
    }
}

private struct Fixture
{
    string dir;
    AuthService auth;
    TenancyService tenancy;
    StubXsuaa xsuaa;
    ThreadPoolExecutor pool;
    Tenant tenant;
    void delegate()[] closers;

    static Fixture make(AuthMode mode)
    {
        Fixture f;
        f.dir = buildPath(tempDir, "ecm-test-" ~ randomUUID().toString());
        auto ids = new UuidGenerator;
        auto clock = new UtcClock;
        auto users = new JournaledUserRepository(f.dir, 10);
        auto tenants = new JournaledTenantRepository(f.dir, 10);
        auto workspaces = new JournaledWorkspaceRepository(f.dir, 10);
        auto members = new JournaledMembershipRepository(f.dir, 10);
        auto docs = new JournaledDocumentRepository(f.dir, 10);
        auto folders = new JournaledFolderRepository(f.dir, 10);
        auto notes = new JournaledNotificationRepository(f.dir, 10);
        f.pool = new ThreadPoolExecutor(1);
        f.closers = [&users.close, &tenants.close, &workspaces.close, &members.close, &docs.close,
                     &folders.close, &notes.close];
        auto events = new NotificationService(notes, members, ids, clock, f.pool);
        auto access = new AccessPolicy(workspaces, members);
        f.tenancy = new TenancyService(tenants, workspaces, members, users, docs, folders, ids, clock, access, events);
        auto secret = cast(immutable(ubyte)[]) "test-secret-test-secret-test-secret!";
        f.xsuaa = new StubXsuaa;
        AuthSettings s;
        s.mode = mode;
        s.tokenTtlSeconds = 600;
        f.auth = new AuthService(users, tenants, members, new Pbkdf2PasswordHasher(1000),
            new JwtTokenService([secret], "ecm", "ecm-api", clock), new InMemoryTokenRevocationStore(clock),
            f.xsuaa, ids, clock, s, events);
        f.auth.bootstrapPlatformAdmin("platform", "platform-pw");
        f.tenant = f.tenancy.createTenant(systemPrincipal, NewTenant("Acme", "acme"));
        f.auth.createUser(systemPrincipal, NewUser(f.tenant.id, "alice", "Alice", "", "alice-secret", "editor"));
        return f;
    }

    void dispose()
    {
        pool.shutdown();
        foreach (c; closers) c();
        if (exists(dir)) rmdirRecurse(dir);
    }
}

unittest // login -> authenticate -> refresh -> logout
{
    auto f = Fixture.make(AuthMode.hybrid);
    scope (exit) f.dispose();

    auto r = f.auth.login("acme", "alice", "alice-secret");
    assert(r.tokenType == "Bearer" && r.expiresIn == 600 && r.session.tenantSlug == "acme");

    auto a = f.auth.authenticate(r.accessToken);
    assert(a.method == AuthMethod.local && a.principal.username == "alice" && a.principal.role == Role.editor);

    auto r2 = f.auth.refresh(a);
    assertThrown!UnauthorizedException(f.auth.authenticate(r.accessToken)); // old token revoked
    auto a2 = f.auth.authenticate(r2.accessToken);
    assert(a2.tokenId != a.tokenId);

    f.auth.logout(a2);
    assertThrown!UnauthorizedException(f.auth.authenticate(r2.accessToken));

    assertThrown!UnauthorizedException(f.auth.login("acme", "alice", "wrong"));
    assertThrown!UnauthorizedException(f.auth.login("nope", "alice", "alice-secret"));
    assertThrown!UnauthorizedException(f.auth.authenticate("garbage"));
}

unittest // deactivation and role changes apply to already issued tokens
{
    auto f = Fixture.make(AuthMode.local);
    scope (exit) f.dispose();
    auto r = f.auth.login("acme", "alice", "alice-secret");
    auto admin = f.auth.login("", "platform", "platform-pw");
    auto pa = f.auth.authenticate(admin.accessToken).principal;
    assert(pa.isPlatformAdmin);

    UserPatch p;
    p.role = "viewer";
    f.auth.updateUser(pa, r.session.user.id, p);
    assert(f.auth.authenticate(r.accessToken).principal.role == Role.viewer);

    UserPatch off;
    off.active = false;
    f.auth.updateUser(pa, r.session.user.id, off);
    assertThrown!UnauthorizedException(f.auth.authenticate(r.accessToken));
}

unittest // password change
{
    auto f = Fixture.make(AuthMode.local);
    scope (exit) f.dispose();
    auto a = f.auth.authenticate(f.auth.login("acme", "alice", "alice-secret").accessToken);
    assertThrown!ValidationException(f.auth.changePassword(a.principal, PasswordChange("wrong", "new-password-1")));
    assertThrown!ValidationException(f.auth.changePassword(a.principal, PasswordChange("alice-secret", "short")));
    f.auth.changePassword(a.principal, PasswordChange("alice-secret", "new-password-1"));
    f.auth.login("acme", "alice", "new-password-1");
}

unittest // XSUAA: subdomain -> tenant, scopes -> role, just-in-time provisioning
{
    auto f = Fixture.make(AuthMode.hybrid);
    scope (exit) f.dispose();
    ExternalIdentity bob;
    bob.subdomain = "acme";
    bob.userName = "bob@example.com";
    bob.givenName = "Bob";
    bob.familyName = "Builder";
    bob.scopes = ["Editor"];
    f.xsuaa.known["xsuaa-bob"] = bob;

    auto a = f.auth.authenticate("xsuaa-bob");
    assert(a.method == AuthMethod.xsuaa && a.principal.tenantId == f.tenant.id && a.principal.role == Role.editor);
    auto s = f.auth.session(a);
    assert(s.user.displayName == "Bob Builder" && s.user.passwordHash.length == 0);
    assertThrown!ValidationException(f.auth.refresh(a));

    // scopes are re-evaluated on every request
    bob.scopes = ["Viewer"];
    f.xsuaa.known["xsuaa-bob"] = bob;
    auto again = f.auth.authenticate("xsuaa-bob");
    assert(again.principal.userId == a.principal.userId && again.principal.role == Role.viewer);

    // no ECM scope -> forbidden; external users cannot use the password login
    bob.scopes = [];
    f.xsuaa.known["xsuaa-none"] = bob;
    assertThrown!ForbiddenException(f.auth.authenticate("xsuaa-none"));
    assertThrown!UnauthorizedException(f.auth.login("acme", "bob@example.com", ""));
}

unittest // xsuaa-only mode disables the password login and own tokens
{
    auto f = Fixture.make(AuthMode.xsuaa);
    scope (exit) f.dispose();
    assertThrown!ForbiddenException(f.auth.login("acme", "alice", "alice-secret"));
}
