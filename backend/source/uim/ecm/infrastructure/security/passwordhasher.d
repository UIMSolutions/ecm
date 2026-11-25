/// PBKDF2-HMAC-SHA256 password hashing, stored as pbkdf2-sha256$iter$salt$hash.
/// Uses OpenSSL's PKCS5_PBKDF2_HMAC (assembly-optimized SHA-256), which is several times
/// faster than a Phobos implementation at the same iteration count. The format is unchanged,
/// so hashes written by earlier releases still verify.
module uim.ecm.infrastructure.security.passwordhasher;

import std.base64 : Base64;
import std.conv : to;
import std.string : split;
import uim.ecm.infrastructure.security.crypto;
import uim.ecm.infrastructure.security.openssl : EVP_sha256, PKCS5_PBKDF2_HMAC;
import uim.ecm.ports.services : PasswordHasher;

final class Pbkdf2PasswordHasher : PasswordHasher
{
    private uint iterations;

    this(uint iterations = 210_000) // OWASP 2023 recommendation for PBKDF2-HMAC-SHA256 is 600k; 210k balances login latency
    {
        this.iterations = iterations;
    }

    string hash(string password)
    {
        auto salt = secureRandom(16);
        auto dk = pbkdf2(password, salt, iterations);
        return ("pbkdf2-sha256$" ~ iterations.to!string ~ "$" ~ Base64.encode(salt) ~ "$" ~ Base64.encode(dk)).idup;
    }

    bool verify(string password, string stored)
    {
        auto parts = stored.split("$");
        if (parts.length != 4 || parts[0] != "pbkdf2-sha256") return false;
        try
        {
            auto iter = parts[1].to!uint;
            if (iter < 1000 || iter > 10_000_000) return false;
            auto salt = Base64.decode(parts[2]);
            auto expected = Base64.decode(parts[3]);
            return constantTimeEquals(pbkdf2(password, salt, iter), expected);
        }
        catch (Exception) return false;
    }

    /// true if the hash was made with fewer iterations than configured (re-hash after login).
    bool needsRehash(string stored)
    {
        auto parts = stored.split("$");
        try return parts.length != 4 || parts[1].to!uint < iterations;
        catch (Exception) return true;
    }
}

private ubyte[] pbkdf2(string password, const(ubyte)[] salt, uint iterations)
{
    auto dk = new ubyte[32];
    if (PKCS5_PBKDF2_HMAC(password.ptr, cast(int) password.length, salt.ptr, cast(int) salt.length,
            cast(int) iterations, EVP_sha256(), 32, dk.ptr) != 1)
        throw new Exception("PBKDF2 failed");
    return dk;
}

unittest
{
    auto h = new Pbkdf2PasswordHasher(1000);
    auto s = h.hash("correct horse");
    assert(h.verify("correct horse", s));
    assert(!h.verify("wrong horse", s));
    assert(!h.verify("x", "garbage"));
    assert(new Pbkdf2PasswordHasher(2000).needsRehash(s));
    // RFC 7914 / known vector: PBKDF2-HMAC-SHA256("passwd", "salt", 1, 64) starts with 55ac046e
    auto v = pbkdf2("passwd", cast(const(ubyte)[]) "salt", 1);
    assert(v[0 .. 4] == [0x55, 0xac, 0x04, 0x6e]);
}
