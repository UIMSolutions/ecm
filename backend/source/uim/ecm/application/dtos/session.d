/// Authentication results.
module uim.ecm.application.dtos.session;

import uim.ecm.domain;

/// How the caller authenticated.
enum AuthMethod : string { local = "local", xsuaa = "xsuaa" }

struct SessionInfo
{
    User user;
    string tenantName, tenantSlug;
    AuthMethod method = AuthMethod.local;
    long expiresAt; /// expiry of the token used for this request (0 = unknown)
}

/// Result of a successful login or refresh: an OAuth2-style bearer token (JWT).
struct LoginResult
{
    string accessToken;
    string tokenType = "Bearer";
    long expiresAt;
    long expiresIn; /// seconds
    SessionInfo session;
}

/// The verified caller of one request plus the token it presented.
struct Authentication
{
    Principal principal;
    AuthMethod method;
    string tokenId;
    long expiresAt;
}
