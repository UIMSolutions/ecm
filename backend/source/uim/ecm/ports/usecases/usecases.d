/// Driving ports. Every use case receives the authenticated Principal; tenant isolation and
/// workspace permissions are enforced in the application layer, not in the adapters.
module uim.ecm.ports.usecases.usecases;

import uim.ecm.application.dtos;
import uim.ecm.domain;
import uim.ecm.ports.storages.streams;

interface DocumentUseCases
{
    Folder[] listFolders(Principal who, string workspaceId); // workspaceId empty = all accessible
    Folder getFolder(Principal who, string id);
    Folder createFolder(Principal who, string workspaceId, string name, string parentId);
    Folder updateFolder(Principal who, string id, FolderPatch patch);
    void deleteFolder(Principal who, string id);

    Document[] listDocuments(Principal who, DocumentFilter filter);
    Document getDocument(Principal who, string id);
    Document createDocument(Principal who, NewDocument input);
    Document updateDocument(Principal who, string id, DocumentPatch patch);
    void deleteDocument(Principal who, string id);

    /// Streaming upload/download: content is never held in memory as a whole.
    Document uploadContent(Principal who, string id, ByteSource src, string mimeType);
    ContentInfo contentInfo(Principal who, string id);
    void readContent(Principal who, string id, ByteSink sink);
    Document publish(Principal who, string id);
    Document archive(Principal who, string id);

    DocumentHit[] searchDocuments(Principal who, string query, size_t limit);
    size_t reindexAll(Principal who);
}

/// Login, JWT session handling and user administration.
interface AuthUseCases
{
    /// Verifies credentials and issues a signed JWT access token.
    LoginResult login(string tenantSlug, string username, string password);
    /// Verifies a bearer token (own JWT or, if enabled, an XSUAA token) on every request.
    Authentication authenticate(string bearerToken);
    /// Issues a fresh token for a still valid local token and revokes the old one.
    LoginResult refresh(Authentication current);
    /// Revokes the presented token (no-op for external tokens).
    void logout(Authentication current);
    SessionInfo session(Authentication current);
    void changePassword(Principal who, PasswordChange change);

    User[] listUsers(Principal who);
    User getUser(Principal who, string id);
    User createUser(Principal who, NewUser input);
    User updateUser(Principal who, string id, UserPatch patch);
    void deleteUser(Principal who, string id);
}

interface TenancyUseCases
{
    Tenant[] listTenants(Principal who);
    Tenant getTenant(Principal who, string id);
    Tenant createTenant(Principal who, NewTenant input);
    Tenant updateTenant(Principal who, string id, TenantPatch patch);
    void deleteTenant(Principal who, string id);

    WorkspaceView[] listWorkspaces(Principal who);
    WorkspaceView getWorkspace(Principal who, string id);
    WorkspaceView createWorkspace(Principal who, string name, string description);
    WorkspaceView updateWorkspace(Principal who, string id, WorkspacePatch patch);
    void deleteWorkspace(Principal who, string id);

    MemberView[] listMembers(Principal who);
    MemberView addMember(Principal who, string workspaceId, string username, string role);
    MemberView updateMember(Principal who, string id, string role);
    void removeMember(Principal who, string id);
}

/// A user's own notifications. Platform administrators have none (they see no tenant content).
interface NotificationUseCases
{
    Notification[] list(Principal who);
    Notification get(Principal who, string id);
    Notification setRead(Principal who, string id, bool read);
    void remove(Principal who, string id);
    size_t markAllRead(Principal who);
}
