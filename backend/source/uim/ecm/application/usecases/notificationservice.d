/// Delivers notifications (fan-out runs in the background, so the request that caused the
/// event is not slowed down) and lets users read, mark and delete their own messages.
/// Each user keeps at most 200 messages; the oldest are dropped first.
module uim.ecm.application.usecases.notificationservice;

import std.algorithm.sorting : sort;
import uim.ecm.application.dtos;
import uim.ecm.ports.usecases;
import uim.ecm.ports;
import uim.ecm.domain;

final class NotificationService : NotificationUseCases, EventPublisher
{
    private enum maxPerUser = 200;
    private enum pruneTo = 150;

    private NotificationRepository notes;
    private MembershipRepository members;
    private IdGenerator ids;
    private TimeSource time;
    private BackgroundExecutor background;

    this(NotificationRepository notes, MembershipRepository members, IdGenerator ids,
         TimeSource time, BackgroundExecutor background)
    {
        this.notes = notes; this.members = members; this.ids = ids;
        this.time = time; this.background = background;
    }

    // ---- EventPublisher ----
    void toWorkspace(Principal actor, string workspaceId, string kind, string subject, string refId, string detail)
    {
        background.post({
            foreach (m; members.ofWorkspace(workspaceId))
                if (m.userId != actor.userId)
                    deliver(m.tenantId, m.userId, workspaceId, kind, actor.username, subject, refId, detail);
        });
    }

    void toUser(Principal actor, string tenantId, string userId, string workspaceId, string kind,
                string subject, string refId, string detail)
    {
        if (userId == actor.userId) return;
        background.post({ deliver(tenantId, userId, workspaceId, kind, actor.username, subject, refId, detail); });
    }

    void userRemoved(string userId)
    {
        foreach (n; notes.ofUser(userId)) notes.remove(n.id);
    }

    private void deliver(string tenantId, string userId, string workspaceId, string kind,
                         string actor, string subject, string refId, string detail)
    {
        Notification n;
        n.id = ids.next(); n.tenantId = tenantId; n.userId = userId; n.workspaceId = workspaceId;
        n.kind = kind; n.actor = actor; n.subject = subject; n.refId = refId; n.detail = detail;
        n.createdAt = time.now();
        notes.save(n);
        auto all = notes.ofUser(userId);
        if (all.length > maxPerUser)
        {
            all.sort!((a, b) => a.createdAt < b.createdAt);
            foreach (old; all[0 .. all.length - pruneTo]) notes.remove(old.id);
        }
    }

    // ---- NotificationUseCases (own notifications only) ----
    Notification[] list(Principal who) { return notes.ofUser(who.userId); }

    Notification get(Principal who, string id) { return load(who, id); }

    Notification setRead(Principal who, string id, bool read)
    {
        auto n = load(who, id);
        if (n.read != read) { n.read = read; notes.save(n); }
        return n;
    }

    void remove(Principal who, string id)
    {
        load(who, id);
        notes.remove(id);
    }

    size_t markAllRead(Principal who)
    {
        size_t count;
        foreach (n; notes.ofUser(who.userId))
            if (!n.read) { n.read = true; notes.save(n); count++; }
        return count;
    }

    private Notification load(Principal who, string id)
    {
        Notification n;
        if (!notes.find(id, n) || n.userId != who.userId) throw new NotFoundException("Notification not found");
        return n;
    }
}
