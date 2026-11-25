/// Driven ports for business data access. Repositories expose the indexed lookups the use
/// cases need, so an adapter (journal files today, SQL tomorrow) answers them without scans.
module uim.ecm.ports.repositories.repositories;

import uim.ecm.domain;

interface Repository(T)
{
    T[] all();
    size_t count();
    bool find(string id, out T entity);
    void save(T entity);
    bool remove(string id);
}

interface DocumentRepository : Repository!Document
{
    Document[] inWorkspace(string workspaceId);
    Document[] inFolder(string folderId);
    Document[] inTenant(string tenantId);
}

interface FolderRepository : Repository!Folder
{
    Folder[] inWorkspace(string workspaceId);
    Folder[] childrenOf(string parentId);
}

interface UserRepository : Repository!User
{
    User[] inTenant(string tenantId); // "" = platform users
    bool byLogin(string tenantId, string username, out User user);
}

interface TenantRepository : Repository!Tenant
{
    bool bySlug(string slug, out Tenant tenant);
}

interface WorkspaceRepository : Repository!Workspace
{
    Workspace[] inTenant(string tenantId);
}

interface MembershipRepository : Repository!Membership
{
    Membership[] ofUser(string userId);
    Membership[] ofWorkspace(string workspaceId);
    Membership[] inTenant(string tenantId);
}

interface NotificationRepository : Repository!Notification
{
    Notification[] ofUser(string userId);
}
