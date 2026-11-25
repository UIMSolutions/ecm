/// Minimal libcrypto prototypes (OpenSSL >= 1.1.1). libcrypto is already linked through
/// vibe-stream:tls; declaring the few symbols here keeps us independent of binding versions.
module uim.ecm.infrastructure.security.openssl;

extern (C) nothrow @nogc {
    struct BIO;
    struct EVP_PKEY;
    struct EVP_PKEY_CTX;
    struct EVP_MD_CTX;
    struct EVP_MD;
    struct ENGINE;

    BIO* BIO_new_mem_buf(const(void)* buf, int len);
    int BIO_free(BIO* a);
    EVP_PKEY* PEM_read_bio_PUBKEY(BIO* bp, EVP_PKEY** x, void* cb, void* u);
    void EVP_PKEY_free(EVP_PKEY* pkey);
    EVP_MD_CTX* EVP_MD_CTX_new();
    void EVP_MD_CTX_free(EVP_MD_CTX* ctx);
    const(EVP_MD)* EVP_sha256();
    int EVP_DigestVerifyInit(EVP_MD_CTX* ctx, EVP_PKEY_CTX** pctx, const(EVP_MD)* type, ENGINE* e, EVP_PKEY* pkey);
    int EVP_DigestVerify(EVP_MD_CTX* ctx, const(ubyte)* sig, size_t siglen, const(ubyte)* tbs, size_t tbslen);
    int RAND_bytes(ubyte* buf, int num);
    int PKCS5_PBKDF2_HMAC(const(char)* pass, int passlen, const(ubyte)* salt, int saltlen, int iter,
        const(EVP_MD)* digest, int keylen, ubyte* out_);
}
