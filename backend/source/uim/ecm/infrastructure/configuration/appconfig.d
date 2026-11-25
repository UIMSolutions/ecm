/// Type-safe configuration. Precedence (lowest -> highest):
/// built-in defaults -> config/default.json -> environment variables -> VCAP_SERVICES.
module uim.ecm.infrastructure.configuration.appconfig;

struct AuthConfig
{
    /// "local" | "xsuaa" | "hybrid"; empty = hybrid if an xsuaa service is bound, else local
    string mode;
    /// HS256 signing secret (>= 32 chars). Generated per process if missing (tokens then die on restart).
    string jwtSecret;
    /// Older secrets that still verify tokens (key rotation).
    string[] jwtPreviousSecrets;
    string issuer = "ecm";
    string audience = "ecm-api";
    long tokenTtlMinutes = 480;
    long leewaySeconds = 30;
    /// XSUAA (from VCAP_SERVICES or ECM_XSUAA_*)
    string xsappname;
    string verificationKey;
    bool autoProvision = true;
    string defaultTenant = "default";
}

struct BootstrapConfig
{
    string platformAdminUser = "platform";
    string platformAdminPassword;
    string adminUser = "admin";
    string adminPassword;
    string defaultTenant = "default";
    string defaultTenantName = "Default";
}

struct AppConfig
{
    ushort port = 8080;
    string bind = "0.0.0.0";
    string dataDir = "./data";
    string corsOrigin;
    size_t maxUploadMb = 50;
    uint workers;               /// 0 = number of logical CPUs
    size_t indexThreads = 2;
    uint journalFlushMs = 200;
    int maxConcurrentLogins;    /// 0 = workers / 2
    string logLevel = "info";
    string frontendDir;         /// serve the OpenUI5 app from here (standalone mode); empty = off
    string metricsToken;        /// protects /metrics; empty = unprotected
    AuthConfig auth;
    BootstrapConfig bootstrap;

    /// True when an XSUAA verification key is configured.
    @property bool xsuaaEnabled() const { return auth.xsappname.length && auth.verificationKey.length; }

    @property string effectiveAuthMode() const
    {
        if (auth.mode.length) return auth.mode;
        return xsuaaEnabled ? "hybrid" : "local";
    }
}
