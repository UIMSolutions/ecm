/// Request/response models of the use cases (independent of HTTP/OData).
module uim.ecm.application.dtos.requests;

import std.typecons : Nullable;
import uim.ecm.domain;

struct FolderPatch { Nullable!string name, parentId; }
struct DocumentPatch { Nullable!string name, title, folderId; }
struct NewDocument { string workspaceId, folderId, name, title, mimeType; }
struct ContentInfo { string mimeType, fileName; ulong size; }
/// Optional pushdown filters; an empty field means "any".
struct DocumentFilter { string workspaceId, folderId; }
struct DocumentHit { Document doc; double score; string snippet; }

struct NewUser { string tenantId, username, displayName, email, password, role; }
struct UserPatch { Nullable!string displayName, email, password, role; Nullable!bool active; }
struct PasswordChange { string currentPassword, newPassword; }

struct NewTenant { string name, slug; }
struct TenantPatch { Nullable!string name; Nullable!bool active; }
struct WorkspacePatch { Nullable!string name, description; }
struct WorkspaceView { Workspace workspace; Role myRole; }
struct MemberView { Membership membership; string username; }
