/// Validates XSUAA-issued RS256 JWTs (forwarded by the approuter) against the verification
/// key of the bound xsuaa service instance.
module uim.ecm.infrastructure.security.xsuaavalidator;

import std.algorithm.searching : startsWith;
import std.array : appender, replace;
import std.string : indexOf, strip;
import std.typecons : Nullable, nullable;
import vibe.data.json;
import uim.ecm.infrastructure.security.jwt;
import uim.ecm.infrastructure.security.openssl;
import uim.ecm.ports.services;

final class XsuaaTokenValidator : ExternalTokenValidator
{
    private string xsappname;
    private string pem;
    private long leeway;
    private TimeSource time;

    this(string xsappname, string verificationKey, TimeSource time, long leewaySeconds = 60)
    {
        this.xsappname = xsappname;
        this.pem = normalizePem(verificationKey);
        this.time = time;
        this.leeway = leewaySeconds;
    }

    Nullable!ExternalIdentity validate(string token)
    {
        JwtParts p;
        if (!parseJwt(token, p) || str(p.header, "alg") != "RS256")
            return Nullable!ExternalIdentity.init;
        if (!verifyRs256(p.signingInput, p.signature))
            return Nullable!ExternalIdentity.init;
        const now = time.now().toUnixTime();
        if (!hasNum(p.payload, "exp") || num(p.payload, "exp") + leeway < now)
            return Nullable!ExternalIdentity.init;
        if (hasNum(p.payload, "nbf") && num(p.payload, "nbf") - leeway > now)
            return Nullable!ExternalIdentity.init;

        ExternalIdentity id;
        auto prefix = xsappname ~ ".";
        bool forUs = audienceContains(p.payload, xsappname);
        auto scopes = p.payload["scope"];
        if (scopes.type == Json.Type.array)
            foreach (s; scopes)
                if (s.type == Json.Type.string && s.get!string.startsWith(prefix))
                {
                    id.scopes ~= s.get!string[prefix.length .. $];
                    forUs = true;
                }
        if (!forUs)
            return Nullable!ExternalIdentity.init;

        id.zoneId = str(p.payload, "zid");
        auto ext = p.payload["ext_attr"];
        if (ext.type == Json.Type.object)
            id.subdomain = str(ext, "zdn");
        id.userName = str(p.payload, "user_name");
        id.email = str(p.payload, "email");
        id.givenName = str(p.payload, "given_name");
        id.familyName = str(p.payload, "family_name");
        id.expiresAt = num(p.payload, "exp");
        if (!id.userName.length)
            return Nullable!ExternalIdentity.init; // client-credential tokens carry no user
        return nullable(id);
    }

    private bool verifyRs256(string input, const(ubyte)[] sig)
    {
        auto bio = BIO_new_mem_buf(pem.ptr, cast(int) pem.length);
        if (bio is null) return false;
        scope (exit) BIO_free(bio);
        auto key = PEM_read_bio_PUBKEY(bio, null, null, null);
        if (key is null) return false;
        scope (exit) EVP_PKEY_free(key);
        auto ctx = EVP_MD_CTX_new();
        if (ctx is null) return false;
        scope (exit) EVP_MD_CTX_free(ctx);
        if (EVP_DigestVerifyInit(ctx, null, EVP_sha256(), null, key) != 1) return false;
        return EVP_DigestVerify(ctx, sig.ptr, sig.length, cast(const(ubyte)*) input.ptr, input.length) == 1;
    }

    /// XSUAA sometimes delivers the key on one line; OpenSSL needs 64-character lines.
    static string normalizePem(string key)
    {
        enum begin = "-----BEGIN PUBLIC KEY-----", end = "-----END PUBLIC KEY-----";
        auto k = key.replace("\\n", "\n").strip;
        auto b = k.indexOf(begin), e = k.indexOf(end);
        if (b < 0 || e < 0) return k;
        auto bodyText = k[b + begin.length .. e].replace("\n", "").replace("\r", "").replace(" ", "");
        auto o = appender!string;
        o ~= begin ~ "\n";
        for (size_t i = 0; i < bodyText.length; i += 64)
        {
            o ~= bodyText[i .. (i + 64 < bodyText.length ? i + 64 : bodyText.length)];
            o ~= "\n";
        }
        o ~= end ~ "\n";
        return o[];
    }
}

unittest
{
    auto pem = XsuaaTokenValidator.normalizePem("-----BEGIN PUBLIC KEY-----" ~ "A" ~ "-----END PUBLIC KEY-----");
    assert(pem == "-----BEGIN PUBLIC KEY-----\nA\n-----END PUBLIC KEY-----\n");
}
