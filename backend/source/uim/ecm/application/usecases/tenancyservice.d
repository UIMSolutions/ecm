/// Tenants (platform admin), workspaces (tenant admin / workspace admin) and memberships.
module uim.ecm.application.usecases.tenancyservice;

import std.algorithm.searching : any;
import std.regex : matchFirst, regex;
import std.string : toLower;
import uim.ecm.application.services.accesspolicy;
import uim.ecm.application.dtos;
import uim.ecm.ports.usecases;
import uim.ecm.ports;
import uim.ecm.domain;

final class TenancyService : TenancyUseCases
{
    private TenantRepository tenants;
    private WorkspaceRepository workspaces;
    private MembershipRepository members;
    private UserRepository users;
    private DocumentRepository docs;
    private FolderRepository folders;
    private IdGenerator ids;
    private TimeSource time;
    private AccessPolicy access;
    private EventPublisher events;

    this(TenantRepository tenants, WorkspaceRepository workspaces, MembershipRepository members,
         UserRepository users, DocumentRepository docs, FolderRepository folders,
         IdGenerator ids, TimeSource time, AccessPolicy access, EventPublisher events)
    {
        this.tenants = tenants; this.workspaces = workspaces; this.members = members;
        this.users = users; this.docs = docs; this.folders = folders;
        this.ids = ids; this.time = time; this.access = access; this.events = events;
    }

    private static void requirePlatform(Principal who)
    {
        if (!who.isPlatformAdmin) throw new ForbiddenException("Platform administrator required");
    }

    private static void requireTenantAdmin(Principal who)
    {
        if (!who.isTenantAdmin) throw new ForbiddenException("Tenant administrator required");
    }

    // ---- tenants ----
    Tenant[] listTenants(Principal who) { requirePlatform(who); return tenants.all(); }

    Tenant getTenant(Principal who, string id) { requirePlatform(who); return loadTenant(id); }

    private Tenant loadTenant(string id)
    {
        Tenant t;
        if (!tenants.find(id, t)) throw new NotFoundException("Tenant '" ~ id ~ "' not found");
        return t;
    }

    Tenant createTenant(Principal who, NewTenant n)
    {
        requirePlatform(who);
        requireValidName("Tenant", n.name);
        auto slug = n.slug.toLower;
        if (matchFirst(slug, regex(`^[a-z0-9][a-z0-9-]{1,39}$`)).empty)
            throw new ValidationException("Slug must have 2-40 characters (a-z, 0-9, -)");
        Tenant dup;
        if (tenants.bySlug(slug, dup)) throw new ConflictException("Tenant slug already taken");
        Tenant t;
        t.id = ids.next(); t.name = n.name; t.slug = slug; t.createdAt = time.now();
        tenants.save(t);
        Workspace ws; // every tenant starts with a default workspace
        ws.id = ids.next(); ws.tenantId = t.id; ws.name = "General";
        ws.description = "Default workspace"; ws.createdAt = time.now();
        workspaces.save(ws);
        return t;
    }

    Tenant updateTenant(Principal who, string id, TenantPatch p)
    {
        requirePlatform(who);
        auto t = loadTenant(id);
        if (!p.name.isNull) { requireValidName("Tenant", p.name.get); t.name = p.name.get; }
        if (!p.active.isNull) t.active = p.active.get;
        tenants.save(t);
        return t;
    }

    void deleteTenant(Principal who, string id)
    {
        requirePlatform(who);
        loadTenant(id);
        if (users.inTenant(id).length > 0) throw new ConflictException("Tenant still has users");
        if (docs.inTenant(id).length > 0) throw new ConflictException("Tenant still has documents");
        auto wss = workspaces.inTenant(id);
        foreach (ws; wss)
            if (folders.inWorkspace(ws.id).length > 0) throw new ConflictException("Tenant still has folders");
        foreach (ws; wss) workspaces.remove(ws.id);
        foreach (m; members.inTenant(id)) members.remove(m.id);
        tenants.remove(id);
    }

    // ---- workspaces ----
    WorkspaceView[] listWorkspaces(Principal who)
    {
        access.requireTenantMember(who);
        auto acc = access.accessible(who);
        WorkspaceView[] result;
        foreach (ws; workspaces.inTenant(who.tenantId))
            if (auto r = ws.id in acc) result ~= WorkspaceView(ws, *r);
        return result;
    }

    WorkspaceView getWorkspace(Principal who, string id)
    {
        Role r;
        auto ws = access.require(who, id, Role.viewer, r);
        return WorkspaceView(ws, r);
    }

    WorkspaceView createWorkspace(Principal who, string name, string description)
    {
        requireTenantAdmin(who);
        requireValidName("Workspace", name);
        Workspace ws;
        ws.id = ids.next(); ws.tenantId = who.tenantId; ws.name = name;
        ws.description = description; ws.createdAt = time.now();
        workspaces.save(ws);
        return WorkspaceView(ws, Role.admin);
    }

    WorkspaceView updateWorkspace(Principal who, string id, WorkspacePatch p)
    {
        Role r;
        auto ws = access.require(who, id, Role.admin, r);
        if (!p.name.isNull) { requireValidName("Workspace", p.name.get); ws.name = p.name.get; }
        if (!p.description.isNull) ws.description = p.description.get;
        workspaces.save(ws);
        return WorkspaceView(ws, r);
    }

    void deleteWorkspace(Principal who, string id)
    {
        requireTenantAdmin(who);
        auto ws = access.require(who, id, Role.admin);
        if (docs.inWorkspace(id).length > 0 || folders.inWorkspace(id).length > 0)
            throw new ConflictException("Workspace is not empty");
        foreach (m; members.ofWorkspace(id)) members.remove(m.id);
        workspaces.remove(ws.id);
    }

    // ---- memberships (workspace admins manage the members of their workspaces) ----
    MemberView[] listMembers(Principal who)
    {
        access.requireTenantMember(who);
        MemberView[] result;
        foreach (wsId, role; access.accessible(who))
            if (role == Role.admin)
                foreach (m; members.ofWorkspace(wsId)) result ~= view(m);
        return result;
    }

    MemberView addMember(Principal who, string workspaceId, string username, string role)
    {
        auto ws = access.require(who, workspaceId, Role.admin);
        User target;
        if (!users.byLogin(ws.tenantId, username, target))
            throw new NotFoundException("User '" ~ username ~ "' not found in this tenant");
        if (members.ofWorkspace(ws.id).any!(m => m.userId == target.id))
            throw new ConflictException("User is already a member of this workspace");
        Membership m;
        m.id = ids.next(); m.workspaceId = ws.id; m.tenantId = ws.tenantId; m.userId = target.id;
        m.role = role.length ? parseRole(role) : Role.viewer;
        m.createdAt = time.now();
        members.save(m);
        events.toUser(who, m.tenantId, m.userId, ws.id, "workspace.member_added", ws.name, ws.id, cast(string) m.role);
        return view(m);
    }

    MemberView updateMember(Principal who, string id, string role)
    {
        auto m = loadMember(who, id);
        m.role = parseRole(role);
        members.save(m);
        notifyMember(who, m, "workspace.role_changed");
        return view(m);
    }

    void removeMember(Principal who, string id)
    {
        auto m = loadMember(who, id);
        members.remove(m.id);
        notifyMember(who, m, "workspace.member_removed");
    }

    private void notifyMember(Principal who, Membership m, string kind)
    {
        Workspace ws;
        if (workspaces.find(m.workspaceId, ws))
            events.toUser(who, m.tenantId, m.userId, ws.id, kind, ws.name, ws.id, cast(string) m.role);
    }

    private Membership loadMember(Principal who, string id)
    {
        Membership m;
        if (!members.find(id, m)) throw new NotFoundException("Member not found");
        try { access.require(who, m.workspaceId, Role.admin); }
        catch (NotFoundException) { throw new NotFoundException("Member not found"); }
        return m;
    }

    private MemberView view(Membership m)
    {
        User u;
        return MemberView(m, users.find(m.userId, u) ? u.username : "?");
    }
}
