module uim.ecm.domain.entities.notification;

import std.datetime.systime : SysTime;

/// A message for exactly one user. The text is not stored: the UI renders it from `kind`
/// plus actor/subject/detail, so notifications follow the user's language.
struct Notification
{
    string id;
    string tenantId;
    string userId;      // recipient
    string workspaceId;
    string kind;        // e.g. "document.published", "workspace.member_added"
    string actor;       // user name of whoever caused it
    string subject;     // e.g. document or workspace name
    string refId;       // id of the referenced object
    string detail;      // e.g. the role
    bool read;
    SysTime createdAt;
}
