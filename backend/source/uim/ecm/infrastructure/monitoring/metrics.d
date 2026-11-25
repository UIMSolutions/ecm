/// Process-wide counters (lock-free) exposed at /metrics in Prometheus text format.
module uim.ecm.infrastructure.monitoring.metrics;

import core.atomic;
import std.array : appender;
import std.conv : to;

shared long requestsTotal;
shared long requestsFailed;
shared long inFlight;
shared long loginsRejected;
shared long loginsSucceeded;
shared long loginsFailed;
shared int activeLogins;

string renderMetrics()
{
    auto o = appender!string;
    void put(string name, string type, long value)
    {
        o ~= "# TYPE " ~ name ~ " " ~ type ~ "\n" ~ name ~ " " ~ value.to!string ~ "\n";
    }
    put("ecm_http_requests_total", "counter", atomicLoad(requestsTotal));
    put("ecm_http_requests_failed_total", "counter", atomicLoad(requestsFailed));
    put("ecm_http_requests_in_flight", "gauge", atomicLoad(inFlight));
    put("ecm_logins_active", "gauge", atomicLoad(activeLogins));
    put("ecm_logins_succeeded_total", "counter", atomicLoad(loginsSucceeded));
    put("ecm_logins_failed_total", "counter", atomicLoad(loginsFailed));
    put("ecm_logins_rejected_total", "counter", atomicLoad(loginsRejected));
    return o[];
}
