/// Concrete repositories: the journal engine plus the indexes each port promises.
module uim.ecm.persistence.repositories.repositories;

import std.string : toLower;
import uim.ecm.persistence.repositories.journalrepository;
import uim.ecm.ports;
import uim.ecm.domain;

final class JournaledDocumentRepository : JournaledRepository!Document, DocumentRepository
{
    this(string dir, uint flushMs = 200)
    {
        KeyFn!Document[string] ix;
        ix["workspace"] = (const Document d) => d.workspaceId;
        ix["folder"] = (const Document d) => d.folderId;
        ix["tenant"] = (const Document d) => d.tenantId;
        super(dir, "documents", ix, flushMs);
    }
    Document[] inWorkspace(string id) { return findBy("workspace", id); }
    Document[] inFolder(string id) { return findBy("folder", id); }
    Document[] inTenant(string id) { return findBy("tenant", id); }
}

final class JournaledFolderRepository : JournaledRepository!Folder, FolderRepository
{
    this(string dir, uint flushMs = 200)
    {
        KeyFn!Folder[string] ix;
        ix["workspace"] = (const Folder f) => f.workspaceId;
        ix["parent"] = (const Folder f) => f.parentId;
        super(dir, "folders", ix, flushMs);
    }
    Folder[] inWorkspace(string id) { return findBy("workspace", id); }
    Folder[] childrenOf(string id) { return findBy("parent", id); }
}

private string loginKey(string tenantId, string username) { return tenantId ~ "|" ~ username.toLower; }

final class JournaledUserRepository : JournaledRepository!User, UserRepository
{
    this(string dir, uint flushMs = 200)
    {
        KeyFn!User[string] ix;
        ix["tenant"] = (const User u) => u.tenantId;
        ix["login"] = (const User u) => loginKey(u.tenantId, u.username);
        super(dir, "users", ix, flushMs);
    }
    User[] inTenant(string id) { return findBy("tenant", id); }
    bool byLogin(string tenantId, string username, out User user)
    {
        auto r = findBy("login", loginKey(tenantId, username));
        if (r.length == 0) return false;
        user = r[0];
        return true;
    }
}

final class JournaledTenantRepository : JournaledRepository!Tenant, TenantRepository
{
    this(string dir, uint flushMs = 200)
    {
        KeyFn!Tenant[string] ix;
        ix["slug"] = (const Tenant t) => t.slug.toLower;
        super(dir, "tenants", ix, flushMs);
    }
    bool bySlug(string slug, out Tenant tenant)
    {
        auto r = findBy("slug", slug.toLower);
        if (r.length == 0) return false;
        tenant = r[0];
        return true;
    }
}

final class JournaledWorkspaceRepository : JournaledRepository!Workspace, WorkspaceRepository
{
    this(string dir, uint flushMs = 200)
    {
        KeyFn!Workspace[string] ix;
        ix["tenant"] = (const Workspace w) => w.tenantId;
        super(dir, "workspaces", ix, flushMs);
    }
    Workspace[] inTenant(string id) { return findBy("tenant", id); }
}

final class JournaledMembershipRepository : JournaledRepository!Membership, MembershipRepository
{
    this(string dir, uint flushMs = 200)
    {
        KeyFn!Membership[string] ix;
        ix["user"] = (const Membership m) => m.userId;
        ix["workspace"] = (const Membership m) => m.workspaceId;
        ix["tenant"] = (const Membership m) => m.tenantId;
        super(dir, "memberships", ix, flushMs);
    }
    Membership[] ofUser(string id) { return findBy("user", id); }
    Membership[] ofWorkspace(string id) { return findBy("workspace", id); }
    Membership[] inTenant(string id) { return findBy("tenant", id); }
}

final class JournaledNotificationRepository : JournaledRepository!Notification, NotificationRepository
{
    this(string dir, uint flushMs = 200)
    {
        KeyFn!Notification[string] ix;
        ix["user"] = (const Notification n) => n.userId;
        super(dir, "notifications", ix, flushMs);
    }
    Notification[] ofUser(string id) { return findBy("user", id); }
}
