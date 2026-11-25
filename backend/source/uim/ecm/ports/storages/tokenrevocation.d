/// Driven port: revoked JWT ids (logout, token refresh). Entries only need to live until the
/// token would have expired anyway.
module uim.ecm.ports.storages.tokenrevocation;

interface TokenRevocationStore
{
    void revoke(string tokenId, long expiresAt);
    bool isRevoked(string tokenId);
}
