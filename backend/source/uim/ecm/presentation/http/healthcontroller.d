/// Liveness (/healthz) and Prometheus metrics (/metrics). Metrics can be protected with a
/// static bearer token (ECM_METRICS_TOKEN) because they must not be public.
module uim.ecm.presentation.http.healthcontroller;

import vibe.http.router : URLRouter;
import vibe.http.server;
import uim.ecm.infrastructure.monitoring.metrics;
import uim.ecm.infrastructure.security.crypto : constantTimeEquals;
import uim.ecm.presentation.http.security : bearerToken, writeError;

final class HealthController
{
    private string metricsToken;

    this(string metricsToken) { this.metricsToken = metricsToken; }

    void register(URLRouter router)
    {
        router.get("/healthz", (HTTPServerRequest req, HTTPServerResponse res) {
            res.headers["Cache-Control"] = "no-store";
            res.writeBody("ok", "text/plain");
        });
        router.get("/metrics", &metrics);
    }

    private void metrics(HTTPServerRequest req, HTTPServerResponse res)
    {
        if (metricsToken.length
            && !constantTimeEquals(cast(const(ubyte)[]) bearerToken(req), cast(const(ubyte)[]) metricsToken))
        {
            writeError(res, 401, "Metrics token required");
            return;
        }
        res.writeBody(renderMetrics(), "text/plain; version=0.0.4");
    }
}
