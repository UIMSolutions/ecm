module uim.ecm.domain.entities.folder;

import std.datetime.systime : SysTime;

struct Folder
{
    string id;
    string workspaceId;
    string parentId; // empty = root of the workspace
    string name;
    SysTime createdAt;
}
