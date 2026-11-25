module uim.ecm.presentation.odata.mapper;

import vibe.data.json;
import uim.ecm.application.dtos;
import uim.ecm.ports.usecases;
import uim.ecm.domain;

Json toJson(Document d)
{
    Json j = Json.emptyObject;
    j["ID"] = d.id;
    j["WorkspaceID"] = d.workspaceId;
    j["FolderID"] = d.folderId.length ? Json(d.folderId) : Json(null);
    j["Name"] = d.name;
    j["Title"] = d.title;
    j["MimeType"] = d.mimeType;
    j["Size"] = d.size;
    j["Revision"] = d.revision;
    j["Status"] = cast(string) d.status;
    j["CreatedBy"] = d.createdBy;
    j["CreatedAt"] = d.createdAt.toISOExtString();
    j["ModifiedAt"] = d.modifiedAt.toISOExtString();
    j["SearchSnippet"] = Json(null);
    j["SearchScore"] = Json(null);
    return j;
}

Json toJson(Document d, string snippet, double score)
{
    auto j = toJson(d);
    j["SearchSnippet"] = snippet;
    j["SearchScore"] = score;
    return j;
}

Json toJson(Folder f)
{
    Json j = Json.emptyObject;
    j["ID"] = f.id;
    j["WorkspaceID"] = f.workspaceId;
    j["ParentID"] = f.parentId.length ? Json(f.parentId) : Json(null);
    j["Name"] = f.name;
    j["CreatedAt"] = f.createdAt.toISOExtString();
    return j;
}

/// Never exposes the password hash.
Json toJson(User u)
{
    Json j = Json.emptyObject;
    j["ID"] = u.id;
    j["TenantID"] = u.tenantId.length ? Json(u.tenantId) : Json(null);
    j["Username"] = u.username;
    j["DisplayName"] = u.displayName;
    j["Email"] = u.email;
    j["Role"] = cast(string) u.role;
    j["Active"] = u.active;
    j["External"] = u.passwordHash.length == 0; // provisioned from XSUAA, no local password
    j["CreatedAt"] = u.createdAt.toISOExtString();
    return j;
}

Json toJson(Tenant t)
{
    Json j = Json.emptyObject;
    j["ID"] = t.id;
    j["Name"] = t.name;
    j["Slug"] = t.slug;
    j["Active"] = t.active;
    j["CreatedAt"] = t.createdAt.toISOExtString();
    return j;
}

Json toJson(WorkspaceView v)
{
    Json j = Json.emptyObject;
    j["ID"] = v.workspace.id;
    j["TenantID"] = v.workspace.tenantId;
    j["Name"] = v.workspace.name;
    j["Description"] = v.workspace.description;
    j["MyRole"] = cast(string) v.myRole;
    j["CreatedAt"] = v.workspace.createdAt.toISOExtString();
    return j;
}

Json toJson(MemberView v)
{
    Json j = Json.emptyObject;
    j["ID"] = v.membership.id;
    j["WorkspaceID"] = v.membership.workspaceId;
    j["UserID"] = v.membership.userId;
    j["Username"] = v.username;
    j["Role"] = cast(string) v.membership.role;
    j["CreatedAt"] = v.membership.createdAt.toISOExtString();
    return j;
}

/// {"user": ..., "tenant": {ID?, Name, Slug} | null}
Json toJson(SessionInfo s)
{
    Json j = Json.emptyObject;
    j["user"] = toJson(s.user);
    if (s.user.tenantId.length)
    {
        Json t = Json.emptyObject;
        t["ID"] = s.user.tenantId;
        t["Name"] = s.tenantName;
        t["Slug"] = s.tenantSlug;
        j["tenant"] = t;
    }
    else j["tenant"] = Json(null);
    j["authMethod"] = cast(string) s.method;
    j["expiresAt"] = s.expiresAt;
    return j;
}

Json toJson(Notification n)
{
    Json j = Json.emptyObject;
    j["ID"] = n.id;
    j["Kind"] = n.kind;
    j["Actor"] = n.actor;
    j["Subject"] = n.subject;
    j["Detail"] = n.detail;
    j["WorkspaceID"] = n.workspaceId;
    j["RefID"] = n.refId;
    j["Read"] = n.read;
    j["CreatedAt"] = n.createdAt.toISOExtString();
    return j;
}

bool has(Json j, string key) { return j[key].type != Json.Type.undefined; }

string str(Json j, string key, string def = "")
{
    auto v = j[key];
    return v.type == Json.Type.string ? v.get!string : def;
}
