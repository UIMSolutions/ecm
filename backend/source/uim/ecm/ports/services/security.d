/// Driven ports for credentials and tokens.
module uim.ecm.ports.services.security;

import std.typecons : Nullable;
import uim.ecm.domain;

interface PasswordHasher
{
    string hash(string password);
    bool verify(string password, string stored);
}

/// What a verified access token says about its holder.
struct TokenClaims
{
    Principal principal;
    string tokenId;   /// jti
    long issuedAt;    /// iat (unix seconds)
    long expiresAt;   /// exp (unix seconds)
}

struct IssuedToken
{
    string token;
    string tokenId;
}

/// Issues and verifies the application's own access tokens (JWT).
interface TokenService
{
    IssuedToken issue(Principal p, long issuedAt, long expiresAt);
    /// Checks signature, algorithm, issuer, audience and time window.
    bool verify(string token, out TokenClaims claims);
}

/// An identity asserted by an external identity provider (XSUAA via the approuter).
struct ExternalIdentity
{
    string zoneId, subdomain, userName, email, givenName, familyName;
    string[] scopes; /// local scope names without the "<xsappname>." prefix
    long expiresAt;
}

/// Validates tokens of an external identity provider.
interface ExternalTokenValidator
{
    Nullable!ExternalIdentity validate(string token);
}
