/// Composition root: the only place that knows every adapter and wires them to the ports.
///
/// Scaling model: the services are created once and shared by all worker threads (their
/// repositories and the search index are guarded by reader/writer locks). Every worker thread
/// runs its own vibe.d event loop with its own listening socket (SO_REUSEPORT), so connections
/// are spread over all cores and idle keep-alive connections cost almost nothing.
module uim.ecm.composition;

import core.time : seconds;
import std.algorithm.iteration : map;
import std.array : array;
import vibe.core.core : logicalProcessorCount;
import vibe.core.log;
import vibe.http.fileserver : HTTPFileServerSettings, serveStaticFiles;
import vibe.http.router : URLRouter;
import vibe.http.server;
import uim.ecm.application.dtos;
import uim.ecm.application.services.accesspolicy;
import uim.ecm.application.usecases.authservice;
import uim.ecm.application.usecases.documentservice;
import uim.ecm.application.usecases.notificationservice;
import uim.ecm.application.usecases.tenancyservice;
import uim.ecm.domain;
import uim.ecm.infrastructure.clients.system;
import uim.ecm.infrastructure.clients.textextractor;
import uim.ecm.infrastructure.configuration;
import uim.ecm.infrastructure.security;
import uim.ecm.infrastructure.workers.threadpool;
import uim.ecm.persistence.repositories.repositories;
import uim.ecm.persistence.storages.filecontentstore;
import uim.ecm.persistence.storages.searchindex;
import uim.ecm.persistence.storages.tokenrevocation;
import uim.ecm.ports;
import uim.ecm.presentation.http.authcontroller;
import uim.ecm.presentation.http.healthcontroller;
import uim.ecm.presentation.odata.controller;

/// All long-lived, thread-safe services of the process.
final class Application
{
    AppConfig config;
    uint workers;
    int maxLogins;
    DocumentService documents;
    AuthService auth;
    TenancyService tenancy;
    NotificationService notifications;
    private void delegate()[] shutdownHooks;

    this(AppConfig config)
    {
        this.config = config;
        workers = config.workers ? config.workers : cast(uint) logicalProcessorCount;
        // password hashing is CPU-bound: cap how many run at once so reads keep flowing
        maxLogins = config.maxConcurrentLogins > 0 ? config.maxConcurrentLogins : cast(int)(workers > 1 ? workers / 2 : 1);

        auto ids = new UuidGenerator;
        auto clock = new UtcClock;
        auto dir = config.dataDir, flush = config.journalFlushMs;

        // --- persistence adapters (one shared, thread-safe instance per entity type)
        auto docRepo = new JournaledDocumentRepository(dir, flush);
        auto folderRepo = new JournaledFolderRepository(dir, flush);
        auto userRepo = new JournaledUserRepository(dir, flush);
        auto tenantRepo = new JournaledTenantRepository(dir, flush);
        auto workspaceRepo = new JournaledWorkspaceRepository(dir, flush);
        auto memberRepo = new JournaledMembershipRepository(dir, flush);
        auto noteRepo = new JournaledNotificationRepository(dir, flush);
        auto executor = new ThreadPoolExecutor(config.indexThreads);
        shutdownHooks ~= { executor.shutdown(); };
        shutdownHooks ~= {
            docRepo.close(); folderRepo.close(); userRepo.close(); tenantRepo.close();
            workspaceRepo.close(); memberRepo.close(); noteRepo.close();
        };

        // --- application services
        notifications = new NotificationService(noteRepo, memberRepo, ids, clock, executor);
        auto access = new AccessPolicy(workspaceRepo, memberRepo);
        documents = new DocumentService(docRepo, folderRepo, new FileContentStore(dir), ids, clock,
            new InMemorySearchIndex, new DefaultTextExtractor, access, executor, notifications);
        tenancy = new TenancyService(tenantRepo, workspaceRepo, memberRepo, userRepo, docRepo,
            folderRepo, ids, clock, access, notifications);

        // --- security: own JWTs (HS256) + optional XSUAA (RS256)
        auto tokens = new JwtTokenService(jwtSecrets(), config.auth.issuer, config.auth.audience, clock,
            config.auth.leewaySeconds);
        ExternalTokenValidator xsuaa;
        if (config.xsuaaEnabled)
            xsuaa = new XsuaaTokenValidator(config.auth.xsappname, config.auth.verificationKey, clock);
        AuthSettings s;
        s.mode = parseMode(config.effectiveAuthMode);
        s.tokenTtlSeconds = config.auth.tokenTtlMinutes * 60;
        s.defaultTenantSlug = config.auth.defaultTenant;
        s.autoProvision = config.auth.autoProvision;
        if (s.mode != AuthMode.local && xsuaa is null)
            logWarn("Auth mode '%s' without XSUAA binding: only local JWTs will be accepted", s.mode);
        auth = new AuthService(userRepo, tenantRepo, memberRepo, new Pbkdf2PasswordHasher, tokens,
            new InMemoryTokenRevocationStore(clock), xsuaa, ids, clock, s, notifications);
        logInfo("Authentication: mode=%s, JWT issuer=%s audience=%s ttl=%smin, XSUAA=%s",
            s.mode, config.auth.issuer, config.auth.audience, config.auth.tokenTtlMinutes,
            xsuaa is null ? "off" : config.auth.xsappname);
    }

    /// First start: platform admin + default tenant with its tenant admin.
    void bootstrap()
    {
        auto b = config.bootstrap;
        string[] notes;
        auto platformPw = orGenerated(b.platformAdminPassword, notes, "platform admin password");
        if (!auth.bootstrapPlatformAdmin(b.platformAdminUser, platformPw)) return;
        auto adminPw = orGenerated(b.adminPassword, notes, "tenant admin password");
        auto tenant = tenancy.createTenant(systemPrincipal, NewTenant(b.defaultTenantName, b.defaultTenant));
        auth.createUser(systemPrincipal, NewUser(tenant.id, b.adminUser, "Administrator", "", adminPw, "admin"));
        logWarn("Initial setup: platform admin '%s', tenant '%s' with admin '%s'", b.platformAdminUser, tenant.slug, b.adminUser);
        foreach (n; notes) logWarn("Generated %s", n);
    }

    /// The index is rebuilt in the background; the server accepts requests immediately.
    void reindex()
    {
        logInfo("Queued %s documents for indexing", documents.reindexAll(systemPrincipal));
    }

    /// Builds the router of one worker thread (routers are not shared between event loops).
    URLRouter router()
    {
        auto r = new URLRouter;
        auto mode = config.effectiveAuthMode;
        new HealthController(config.metricsToken).register(r);
        new AuthController(auth, maxLogins, mode != "xsuaa", mode != "local" && config.xsuaaEnabled).register(r);
        new ODataController(documents, auth, tenancy, notifications, config.corsOrigin).register(r);
        if (config.frontendDir.length)
        {
            auto fs = new HTTPFileServerSettings;
            fs.maxAge = 300.seconds;
            r.get("*", serveStaticFiles(config.frontendDir, fs));
        }
        return r;
    }

    HTTPServerSettings serverSettings()
    {
        auto s = new HTTPServerSettings;
        s.port = config.port;
        s.bindAddresses = [config.bind];
        s.maxRequestSize = config.maxUploadMb * 1024 * 1024;
        s.keepAliveTimeout = 60.seconds;
        s.serverString = "ecm";
        // request bodies are never parsed eagerly (vibe-http 1.6): JSON is read by the adapters,
        // content is streamed, so large uploads are never buffered
        s.options = HTTPServerOption.reusePort | HTTPServerOption.reuseAddress;
        return s;
    }

    void shutdown()
    {
        foreach (f; shutdownHooks) f(); // drain background jobs, flush journals
    }

    private const(ubyte[])[] jwtSecrets()
    {
        const(ubyte[])[] list;
        if (config.auth.jwtSecret.length >= 32)
            list ~= cast(const(ubyte)[]) config.auth.jwtSecret.dup;
        else
        {
            if (config.auth.jwtSecret.length)
                logError("ECM_JWT_SECRET is shorter than 32 characters and is ignored");
            list ~= secureRandom(32);
            logWarn("ECM_JWT_SECRET not set (min. 32 chars): tokens are invalidated on restart and not shared between instances");
        }
        foreach (p; config.auth.jwtPreviousSecrets)
            if (p.length >= 32) list ~= cast(const(ubyte)[]) p.dup;
        return list;
    }

    private static AuthMode parseMode(string m)
    {
        switch (m)
        {
            case "xsuaa": return AuthMode.xsuaa;
            case "hybrid": return AuthMode.hybrid;
            default: return AuthMode.local;
        }
    }

    private static string orGenerated(string value, ref string[] notes, string label)
    {
        if (value.length) return value;
        auto v = randomToken(12);
        notes ~= label ~ ": " ~ v;
        return v;
    }
}
