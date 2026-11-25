/// The application's own access tokens: JWT signed with HMAC-SHA256 (HS256).
///
/// Claims: iss, aud, sub (user id), preferred_username, tid (tenant id, empty = platform),
/// role, iat, nbf, exp, jti. Verification is strict: only "HS256" is accepted (no "none",
/// no algorithm confusion), issuer and audience must match, and the time window is checked
/// with a small leeway. Several secrets can be configured for key rotation: the first one
/// signs, all of them verify; the "kid" header selects the key.
module uim.ecm.infrastructure.security.jwttokenservice;

import std.digest : toHexString, LetterCase;
import std.digest.hmac : hmac;
import std.digest.sha : SHA256, sha256Of;
import vibe.data.json;
import uim.ecm.domain;
import uim.ecm.infrastructure.security.crypto;
import uim.ecm.infrastructure.security.jwt;
import uim.ecm.ports.services;

final class JwtTokenService : TokenService
{
    private static struct Key { string kid; immutable(ubyte)[] secret; }

    private Key[] keys; // keys[0] signs
    private string issuer, audience;
    private long leeway;
    private TimeSource time;

    /// secrets[0] signs new tokens; every secret verifies (rotation).
    this(const(ubyte[])[] secrets, string issuer, string audience, TimeSource time, long leewaySeconds = 30)
    {
        assert(secrets.length > 0, "at least one JWT secret is required");
        foreach (s; secrets)
            keys ~= Key(keyId(s), s.idup);
        this.issuer = issuer;
        this.audience = audience;
        this.time = time;
        this.leeway = leewaySeconds;
    }

    IssuedToken issue(Principal p, long issuedAt, long expiresAt)
    {
        auto jti = randomToken(16);
        Json h = Json.emptyObject;
        h["alg"] = "HS256";
        h["typ"] = "JWT";
        h["kid"] = keys[0].kid;
        Json c = Json.emptyObject;
        c["iss"] = issuer;
        c["aud"] = audience;
        c["sub"] = p.userId;
        c["preferred_username"] = p.username;
        c["tid"] = p.tenantId;
        c["role"] = cast(string) p.role;
        c["iat"] = issuedAt;
        c["nbf"] = issuedAt;
        c["exp"] = expiresAt;
        c["jti"] = jti;
        auto input = signingInput(h, c);
        return IssuedToken(input ~ "." ~ b64url(sign(keys[0].secret, input)), jti);
    }

    bool verify(string token, out TokenClaims claims)
    {
        JwtParts p;
        if (!parseJwt(token, p)) return false;
        if (str(p.header, "alg") != "HS256") return false;
        auto typ = str(p.header, "typ");
        if (typ.length && typ != "JWT") return false;

        // pick the key by "kid"; without kid try all (tokens of older releases)
        auto kid = str(p.header, "kid");
        bool ok;
        foreach (k; keys)
            if (!kid.length || k.kid == kid)
                if (constantTimeEquals(sign(k.secret, p.signingInput), p.signature)) { ok = true; break; }
        if (!ok) return false;

        auto c = p.payload;
        if (str(c, "iss") != issuer || !audienceContains(c, audience)) return false;
        if (!hasNum(c, "exp") || !hasNum(c, "iat")) return false;
        const now = time.now().toUnixTime();
        if (num(c, "exp") + leeway < now) return false;
        if (hasNum(c, "nbf") && num(c, "nbf") - leeway > now) return false;
        auto sub = str(c, "sub");
        auto jti = str(c, "jti");
        if (!sub.length || !jti.length) return false;
        try
            claims.principal = Principal(sub, str(c, "preferred_username"), str(c, "tid"), parseRole(str(c, "role")));
        catch (DomainException) return false;
        claims.tokenId = jti;
        claims.issuedAt = num(c, "iat");
        claims.expiresAt = num(c, "exp");
        return true;
    }

    private static ubyte[] sign(const(ubyte)[] secret, string input)
    {
        auto mac = hmac!SHA256(secret);
        mac.put(cast(const(ubyte)[]) input);
        return mac.finish().dup;
    }

    private static string keyId(const(ubyte)[] secret)
    {
        auto d = sha256Of(secret);
        return toHexString!(LetterCase.lower)(d[0 .. 6]).idup;
    }
}

version (unittest)
{
    import std.datetime.systime : SysTime;
    private final class FixedClock : TimeSource
    {
        long t;
        this(long t) { this.t = t; }
        SysTime now() { return SysTime.fromUnixTime(t); }
    }
}

unittest
{
    import std.array : split;
    auto clock = new FixedClock(1_800_000_000);
    auto secret = cast(immutable(ubyte)[]) "0123456789abcdef0123456789abcdef";
    auto svc = new JwtTokenService([secret], "ecm", "ecm-api", clock);
    auto p = Principal("u1", "alice", "t1", Role.editor);
    auto t = svc.issue(p, clock.t, clock.t + 600);

    TokenClaims c;
    assert(svc.verify(t.token, c));
    assert(c.principal == p && c.tokenId == t.tokenId && c.expiresAt == clock.t + 600);

    // tampered payload
    auto parts = t.token.split(".");
    Json forged = parseJsonString(cast(string) unb64url(parts[1]));
    forged["role"] = "admin";
    assert(!svc.verify(parts[0] ~ "." ~ b64url(cast(const(ubyte)[]) forged.toString()) ~ "." ~ parts[2], c));

    // alg "none"
    Json none = Json.emptyObject; none["alg"] = "none";
    assert(!svc.verify(b64url(cast(const(ubyte)[]) none.toString()) ~ "." ~ parts[1] ~ ".", c));

    // other issuer / audience / key
    assert(!new JwtTokenService([secret], "other", "ecm-api", clock).verify(t.token, c));
    assert(!new JwtTokenService([secret], "ecm", "other", clock).verify(t.token, c));
    auto other = cast(immutable(ubyte)[]) "ffffffffffffffffffffffffffffffff";
    assert(!new JwtTokenService([other], "ecm", "ecm-api", clock).verify(t.token, c));

    // rotation: a new primary key still accepts tokens of the previous one
    assert(new JwtTokenService([other, secret], "ecm", "ecm-api", clock).verify(t.token, c));

    // expiry and not-before (30 s leeway)
    clock.t += 600 + 31;
    assert(!svc.verify(t.token, c));
    clock.t = 1_800_000_000 - 31;
    assert(!svc.verify(t.token, c));
}
