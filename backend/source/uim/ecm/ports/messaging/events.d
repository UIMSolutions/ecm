/// The application announces domain events; the adapter behind this port decides who hears about them.
module uim.ecm.ports.messaging.events;

import uim.ecm.domain;

interface EventPublisher
{
    /// Everyone who is a member of the workspace, except the actor.
    void toWorkspace(Principal actor, string workspaceId, string kind, string subject, string refId, string detail);
    /// One specific user (never the actor).
    void toUser(Principal actor, string tenantId, string userId, string workspaceId, string kind,
                string subject, string refId, string detail);
    /// Removes everything addressed to a deleted user.
    void userRemoved(string userId);
}
