/// Entry point: load configuration, compose the application, start one HTTP listener per worker.
module app;

import vibe.core.core : runApplication, runWorkerTaskDist, setupWorkerThreads;
import vibe.core.log;
import vibe.http.server : listenHTTP;
import uim.ecm.composition;
import uim.ecm.infrastructure.configuration;
import uim.ecm.infrastructure.logging.logging;

// Shared across worker threads (set once at startup, read-only afterwards).
private __gshared Application g_app;

/// Runs once per worker thread: own router, own listening socket, shared services.
private void startWorker() nothrow
{
    try listenHTTP(g_app.serverSettings(), g_app.router());
    catch (Exception e) logError("Worker failed to listen: %s", e.msg);
}

int main(string[] args)
{
    auto config = loadConfig();
    configureLogging(config.logLevel);
    g_app = new Application(config);
    g_app.bootstrap();
    g_app.reindex();

    setupWorkerThreads(g_app.workers);
    runWorkerTaskDist(&startWorker);
    logInfo("ECM backend on %s:%s with %s worker threads, data in %s", config.bind, config.port,
        g_app.workers, config.dataDir);
    scope (exit) g_app.shutdown();
    return runApplication(&args);
}
