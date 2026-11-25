/// Random numbers and constant-time comparison.
module uim.ecm.infrastructure.security.crypto;

import std.base64 : Base64URLNoPadding;
import uim.ecm.infrastructure.security.openssl : RAND_bytes;

/// Cryptographically secure random bytes (OpenSSL CSPRNG).
ubyte[] secureRandom(size_t n)
{
    auto buf = new ubyte[n];
    if (RAND_bytes(buf.ptr, cast(int) n) != 1)
        throw new Exception("RAND_bytes failed");
    return buf;
}

/// Random URL-safe secret, e.g. for generated passwords and token ids.
string randomToken(size_t bytes = 18)
{
    return Base64URLNoPadding.encode(secureRandom(bytes)).idup;
}

bool constantTimeEquals(const(ubyte)[] a, const(ubyte)[] b) pure nothrow @nogc @safe
{
    if (a.length != b.length) return false;
    ubyte diff = 0;
    foreach (i; 0 .. a.length) diff |= cast(ubyte)(a[i] ^ b[i]);
    return diff == 0;
}

unittest
{
    assert(secureRandom(32).length == 32);
    assert(constantTimeEquals([1, 2, 3], [1, 2, 3]));
    assert(!constantTimeEquals([1, 2, 3], [1, 2, 4]));
    assert(!constantTimeEquals([1, 2], [1, 2, 3]));
}
