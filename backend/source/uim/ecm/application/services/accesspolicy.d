/// Central authorization rules for tenant content. Lookups are index-based (O(1) for tenant
/// admins, O(own memberships) for everyone else), never a scan over all workspaces or members.
module uim.ecm.application.services.accesspolicy;

import uim.ecm.ports;
import uim.ecm.domain;

final class AccessPolicy
{
    private WorkspaceRepository workspaces;
    private MembershipRepository members;

    this(WorkspaceRepository workspaces, MembershipRepository members)
    {
        this.workspaces = workspaces;
        this.members = members;
    }

    void requireTenantMember(Principal who)
    {
        if (who.tenantId.length == 0)
            throw new ForbiddenException("Platform administrators have no access to tenant content");
    }

    /// Effective role of the caller in one workspace; false if there is no access.
    bool roleIn(Principal who, Workspace ws, out Role role)
    {
        if (who.tenantId.length == 0 || ws.tenantId != who.tenantId) return false;
        if (who.isTenantAdmin) { role = Role.admin; return true; }
        foreach (m; members.ofUser(who.userId))
            if (m.workspaceId == ws.id) { role = minRole(m.role, who.role); return true; }
        return false;
    }

    /// workspaceId -> effective role, for every workspace the caller can see (used for lists).
    Role[string] accessible(Principal who)
    {
        Role[string] result;
        if (who.tenantId.length == 0) return result;
        if (who.isTenantAdmin)
        {
            foreach (ws; workspaces.inTenant(who.tenantId)) result[ws.id] = Role.admin;
        }
        else
        {
            foreach (m; members.ofUser(who.userId))
                if (m.tenantId == who.tenantId) result[m.workspaceId] = minRole(m.role, who.role);
        }
        return result;
    }

    /// Loads a workspace of the caller's tenant and checks the minimum role.
    /// Foreign or unknown workspaces look like "not found" (no existence leak).
    Workspace require(Principal who, string workspaceId, Role min, out Role role)
    {
        requireTenantMember(who);
        Workspace ws;
        if (!workspaces.find(workspaceId, ws) || !roleIn(who, ws, role))
            throw new NotFoundException("Workspace not found");
        if (!atLeast(role, min)) throw new ForbiddenException("Insufficient permissions in this workspace");
        return ws;
    }

    Workspace require(Principal who, string workspaceId, Role min)
    {
        Role r;
        return require(who, workspaceId, min, r);
    }
}
