/// Revoked JWT ids, kept in memory until the token would have expired anyway.
/// One backend process serves all worker threads, so a shared, mutex-guarded set is enough;
/// for several instances put a Redis/SQL adapter behind the same port.
module uim.ecm.persistence.storages.tokenrevocation;

import core.sync.mutex : Mutex;
import uim.ecm.ports;

final class InMemoryTokenRevocationStore : TokenRevocationStore
{
    private long[string] revoked; // jti -> exp
    private Mutex lock;
    private TimeSource time;
    private size_t writes;

    this(TimeSource time)
    {
        this.time = time;
        lock = new Mutex;
    }

    void revoke(string tokenId, long expiresAt)
    {
        if (!tokenId.length) return;
        lock.lock_nothrow();
        scope (exit) lock.unlock_nothrow();
        revoked[tokenId] = expiresAt;
        if (++writes % 256 == 0) purge();
    }

    bool isRevoked(string tokenId)
    {
        lock.lock_nothrow();
        scope (exit) lock.unlock_nothrow();
        return (tokenId in revoked) !is null;
    }

    size_t length()
    {
        lock.lock_nothrow();
        scope (exit) lock.unlock_nothrow();
        return revoked.length;
    }

    private void purge()
    {
        const now = time.now().toUnixTime();
        string[] old;
        foreach (k, exp; revoked)
            if (exp < now) old ~= k;
        foreach (k; old) revoked.remove(k);
    }
}
