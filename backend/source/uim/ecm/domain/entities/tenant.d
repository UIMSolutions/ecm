module uim.ecm.domain.entities.tenant;

import std.datetime.systime : SysTime;
import uim.ecm.domain.enumerations.role : Role;

struct Tenant
{
    string id, name, slug;
    bool active = true;
    SysTime createdAt;
}

struct Workspace
{
    string id, tenantId, name, description;
    SysTime createdAt;
}

struct Membership
{
    string id, workspaceId, tenantId, userId;
    Role role = Role.viewer;
    SysTime createdAt;
}
