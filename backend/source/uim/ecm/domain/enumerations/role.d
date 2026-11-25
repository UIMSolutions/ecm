/// Account role within a tenant (admin = tenant administrator) and role within a workspace.
/// The effective workspace role is min(account role, membership role); tenant admins are admins
/// everywhere in their tenant.
module uim.ecm.domain.enumerations.role;

import uim.ecm.domain.exceptions;

enum Role : string { viewer = "viewer", editor = "editor", admin = "admin" }

Role parseRole(string s)
{
    switch (s)
    {
        case "viewer": return Role.viewer;
        case "editor": return Role.editor;
        case "admin": return Role.admin;
        default: throw new ValidationException("Unknown role: " ~ s);
    }
}

int rank(Role r) pure nothrow @safe @nogc
{
    final switch (r)
    {
        case Role.viewer: return 0;
        case Role.editor: return 1;
        case Role.admin: return 2;
    }
}

bool atLeast(Role r, Role min) pure nothrow @safe @nogc { return rank(r) >= rank(min); }
Role minRole(Role a, Role b) pure nothrow @safe @nogc { return rank(a) <= rank(b) ? a : b; }

unittest
{
    assert(minRole(Role.admin, Role.viewer) == Role.viewer);
    assert(atLeast(Role.editor, Role.viewer) && !atLeast(Role.viewer, Role.editor));
    assert(parseRole("editor") == Role.editor);
}
