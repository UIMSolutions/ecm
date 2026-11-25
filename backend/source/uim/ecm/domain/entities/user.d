module uim.ecm.domain.entities.user;

import std.datetime.systime : SysTime;
import uim.ecm.domain.enumerations.role;

struct User
{
    string id;
    string tenantId; // empty = platform user
    string username;
    string displayName;
    string email;
    string passwordHash; // empty for users provisioned from an external IdP (XSUAA)
    Role role = Role.viewer;
    bool active = true;
    SysTime createdAt;
}
