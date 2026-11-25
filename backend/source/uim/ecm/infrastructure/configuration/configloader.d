/// Populates AppConfig from config/default.json, the environment and VCAP_SERVICES.
module uim.ecm.infrastructure.configuration.configloader;

import std.algorithm.iteration : filter, map, splitter;
import std.array : array;
import std.conv : to;
import std.file : exists, readText;
import std.process : environment;
import std.string : strip;
import vibe.data.json;
import uim.ecm.infrastructure.configuration.appconfig;

/// Loads the configuration. `env` defaults to the process environment (injectable for tests).
AppConfig loadConfig(string file = "", string[string] env = null)
{
    if (env is null) env = environment.toAA();
    AppConfig c;
    if (!file.length) file = env.get("ECM_CONFIG", "config/default.json");
    if (exists(file)) applyJson(c, parseJsonString(readText(file)));
    applyEnv(c, env);
    if (auto vcap = "VCAP_SERVICES" in env)
        if ((*vcap).length) applyVcap(c, parseJsonString(*vcap));
    return c;
}

void applyJson(ref AppConfig c, Json j)
{
    if (j.type != Json.Type.object) return;
    auto s = j["server"];
    if (s.type == Json.Type.object)
    {
        num(s, "port", c.port);
        txt(s, "bind", c.bind);
        txt(s, "corsOrigin", c.corsOrigin);
        num(s, "maxUploadMb", c.maxUploadMb);
        num(s, "workers", c.workers);
        num(s, "maxConcurrentLogins", c.maxConcurrentLogins);
        txt(s, "frontendDir", c.frontendDir);
        txt(s, "metricsToken", c.metricsToken);
    }
    auto st = j["storage"];
    if (st.type == Json.Type.object)
    {
        txt(st, "dataDir", c.dataDir);
        num(st, "journalFlushMs", c.journalFlushMs);
        num(st, "indexThreads", c.indexThreads);
    }
    auto l = j["logging"];
    if (l.type == Json.Type.object) txt(l, "level", c.logLevel);
    auto a = j["auth"];
    if (a.type == Json.Type.object)
    {
        txt(a, "mode", c.auth.mode);
        txt(a, "jwtSecret", c.auth.jwtSecret);
        txt(a, "issuer", c.auth.issuer);
        txt(a, "audience", c.auth.audience);
        num(a, "tokenTtlMinutes", c.auth.tokenTtlMinutes);
        num(a, "leewaySeconds", c.auth.leewaySeconds);
        txt(a, "defaultTenant", c.auth.defaultTenant);
        flag(a, "autoProvision", c.auth.autoProvision);
    }
    auto b = j["bootstrap"];
    if (b.type == Json.Type.object)
    {
        txt(b, "platformAdminUser", c.bootstrap.platformAdminUser);
        txt(b, "adminUser", c.bootstrap.adminUser);
        txt(b, "defaultTenant", c.bootstrap.defaultTenant);
        txt(b, "defaultTenantName", c.bootstrap.defaultTenantName);
    }
}

void applyEnv(ref AppConfig c, string[string] env)
{
    void s(string k, ref string v) { if (auto p = k in env) v = *p; }
    void n(T)(string k, ref T v) { if (auto p = k in env) if ((*p).strip.length) v = (*p).strip.to!T; }
    void b(string k, ref bool v) { if (auto p = k in env) v = *p == "true" || *p == "1" || *p == "yes"; }

    n("PORT", c.port); // set by Cloud Foundry / Kubernetes conventions
    s("ECM_BIND", c.bind);
    s("ECM_DATA_DIR", c.dataDir);
    s("ECM_CORS_ORIGIN", c.corsOrigin);
    n("ECM_MAX_UPLOAD_MB", c.maxUploadMb);
    n("ECM_WORKERS", c.workers);
    n("ECM_INDEX_THREADS", c.indexThreads);
    n("ECM_JOURNAL_FLUSH_MS", c.journalFlushMs);
    n("ECM_MAX_CONCURRENT_LOGINS", c.maxConcurrentLogins);
    s("ECM_LOG_LEVEL", c.logLevel);
    s("ECM_FRONTEND_DIR", c.frontendDir);
    s("ECM_METRICS_TOKEN", c.metricsToken);

    s("ECM_AUTH_MODE", c.auth.mode);
    // ECM_TOKEN_SECRET / ECM_TOKEN_TTL_MINUTES are the names of earlier releases
    s("ECM_TOKEN_SECRET", c.auth.jwtSecret);
    s("ECM_JWT_SECRET", c.auth.jwtSecret);
    if (auto p = "ECM_JWT_PREVIOUS_SECRETS" in env)
        c.auth.jwtPreviousSecrets = (*p).splitter(",").map!(x => x.strip).filter!(x => x.length > 0).array;
    s("ECM_JWT_ISSUER", c.auth.issuer);
    s("ECM_JWT_AUDIENCE", c.auth.audience);
    n("ECM_TOKEN_TTL_MINUTES", c.auth.tokenTtlMinutes);
    n("ECM_JWT_TTL_MINUTES", c.auth.tokenTtlMinutes);
    n("ECM_JWT_LEEWAY_SECONDS", c.auth.leewaySeconds);
    s("ECM_XSUAA_XSAPPNAME", c.auth.xsappname);
    s("ECM_XSUAA_VERIFICATION_KEY", c.auth.verificationKey);
    b("ECM_XSUAA_AUTO_PROVISION", c.auth.autoProvision);
    s("ECM_XSUAA_DEFAULT_TENANT", c.auth.defaultTenant);

    s("ECM_PLATFORM_ADMIN_USER", c.bootstrap.platformAdminUser);
    s("ECM_PLATFORM_ADMIN_PASSWORD", c.bootstrap.platformAdminPassword);
    s("ECM_ADMIN_USER", c.bootstrap.adminUser);
    s("ECM_ADMIN_PASSWORD", c.bootstrap.adminPassword);
    s("ECM_DEFAULT_TENANT", c.bootstrap.defaultTenant);
    s("ECM_DEFAULT_TENANT_NAME", c.bootstrap.defaultTenantName);
}

/// Reads the xsuaa binding and user-provided services tagged "ecm-config" (credentials = env names).
void applyVcap(ref AppConfig c, Json vcap)
{
    if (vcap.type != Json.Type.object) return;
    foreach (string label, instances; vcap)
    {
        if (instances.type != Json.Type.array) continue;
        foreach (inst; instances)
        {
            auto cred = inst["credentials"];
            if (cred.type != Json.Type.object) continue;
            if (label == "xsuaa")
            {
                txt(cred, "xsappname", c.auth.xsappname);
                txt(cred, "verificationkey", c.auth.verificationKey);
            }
            else if (hasTag(inst, "ecm-config"))
            {
                string[string] env;
                foreach (string k, v; cred)
                    if (v.type == Json.Type.string) env[k] = v.get!string;
                applyEnv(c, env);
            }
        }
    }
}

private bool hasTag(Json inst, string tag)
{
    auto tags = inst["tags"];
    if (tags.type == Json.Type.array)
        foreach (t; tags)
            if (t.type == Json.Type.string && t.get!string == tag) return true;
    return false;
}

private void txt(Json o, string k, ref string v) { if (o[k].type == Json.Type.string) v = o[k].get!string; }
private void flag(Json o, string k, ref bool v) { if (o[k].type == Json.Type.bool_) v = o[k].get!bool; }
private void num(T)(Json o, string k, ref T v) { if (o[k].type == Json.Type.int_) v = o[k].get!long.to!T; }

unittest
{
    AppConfig c;
    applyJson(c, parseJsonString(`{"server":{"port":9000},"auth":{"tokenTtlMinutes":60}}`));
    assert(c.port == 9000 && c.auth.tokenTtlMinutes == 60);
    applyEnv(c, ["PORT": "8081", "ECM_JWT_SECRET": "s", "ECM_JWT_PREVIOUS_SECRETS": "a, b,"]);
    assert(c.port == 8081 && c.auth.jwtSecret == "s" && c.auth.jwtPreviousSecrets == ["a", "b"]);
    assert(c.effectiveAuthMode == "local");
    applyVcap(c, parseJsonString(`{"xsuaa":[{"credentials":{"xsappname":"ecm!t1","verificationkey":"K"}}],
        "user-provided":[{"tags":["ecm-config"],"credentials":{"ECM_JWT_SECRET":"from-vcap"}}]}`));
    assert(c.auth.xsappname == "ecm!t1" && c.auth.jwtSecret == "from-vcap");
    assert(c.effectiveAuthMode == "hybrid");
}
