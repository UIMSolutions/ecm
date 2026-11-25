/// Value object: the authenticated caller. tenantId is empty for platform users.
module uim.ecm.domain.types.principal;

import uim.ecm.domain.enumerations.role;

struct Principal
{
    string userId, username, tenantId;
    Role role;

    @property bool isPlatformAdmin() const pure nothrow @safe @nogc { return tenantId.length == 0 && role == Role.admin; }
    @property bool isTenantAdmin() const pure nothrow @safe @nogc { return tenantId.length > 0 && role == Role.admin; }
}

/// The technical principal used for bootstrap and background jobs.
enum systemPrincipal = Principal("system", "system", "", Role.admin);
