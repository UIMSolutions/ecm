/// JSON Web Token codec (RFC 7519, compact serialization, base64url without padding).
module uim.ecm.infrastructure.security.jwt;

import std.array : split;
import std.base64 : Base64URLNoPadding;
import std.string : stripRight;
import vibe.data.json;

struct JwtParts
{
    Json header;
    Json payload;
    string signingInput; /// "<header>.<payload>"
    ubyte[] signature;
}

string b64url(const(ubyte)[] data) { return Base64URLNoPadding.encode(data).idup; }
ubyte[] unb64url(string s) { return Base64URLNoPadding.decode(s.stripRight("=")); }

/// Splits and decodes a JWT; returns false if it is malformed.
bool parseJwt(string token, out JwtParts parts)
{
    if (token.length > 16 * 1024) return false; // refuse absurdly large headers early
    auto segs = token.split(".");
    if (segs.length != 3 || segs[0].length == 0 || segs[1].length == 0) return false;
    try
    {
        parts.header = parseJsonString(cast(string) unb64url(segs[0]));
        parts.payload = parseJsonString(cast(string) unb64url(segs[1]));
        parts.signature = unb64url(segs[2]);
        parts.signingInput = segs[0] ~ "." ~ segs[1];
        return parts.header.type == Json.Type.object && parts.payload.type == Json.Type.object;
    }
    catch (Exception) return false;
}

/// "<b64(header)>.<b64(payload)>" - the part that gets signed.
string signingInput(Json header, Json payload)
{
    return b64url(cast(const(ubyte)[]) header.toString()) ~ "." ~ b64url(cast(const(ubyte)[]) payload.toString());
}

string str(Json o, string key)
{
    auto v = o[key];
    return v.type == Json.Type.string ? v.get!string : "";
}

long num(Json o, string key)
{
    auto v = o[key];
    if (v.type == Json.Type.int_) return v.get!long;
    if (v.type == Json.Type.float_) return cast(long) v.get!double;
    return 0;
}

bool hasNum(Json o, string key)
{
    auto v = o[key];
    return v.type == Json.Type.int_ || v.type == Json.Type.float_;
}

/// "aud" may be a string or an array of strings.
bool audienceContains(Json payload, string audience)
{
    auto aud = payload["aud"];
    if (aud.type == Json.Type.string) return aud.get!string == audience;
    if (aud.type == Json.Type.array)
        foreach (a; aud)
            if (a.type == Json.Type.string && a.get!string == audience) return true;
    return false;
}

unittest
{
    Json h = Json.emptyObject; h["alg"] = "HS256";
    Json p = Json.emptyObject; p["sub"] = "u1"; p["aud"] = Json([Json("x"), Json("ecm")]);
    JwtParts parts;
    assert(parseJwt(signingInput(h, p) ~ "." ~ b64url([1, 2, 3]), parts));
    assert(str(parts.payload, "sub") == "u1" && audienceContains(parts.payload, "ecm"));
    assert(parts.signature == [1, 2, 3]);
    assert(!parseJwt("a.b", parts) && !parseJwt("not-a-jwt", parts));
}
