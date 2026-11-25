/// Bearer-token extraction and JSON helpers shared by the HTTP and OData adapters.
/// Authorization itself lives in the application layer (AccessPolicy and the services).
module uim.ecm.presentation.http.security;

import std.conv : to;
import std.string : strip, toLower;
import vibe.data.json;
import vibe.http.server;
import uim.ecm.application.dtos;
import uim.ecm.ports.usecases;
import uim.ecm.domain;

/// The raw bearer token of the request, or "".
string bearerToken(HTTPServerRequest req)
{
    auto h = req.headers.get("Authorization", "");
    enum scheme = "bearer ";
    if (h.length <= scheme.length || h[0 .. scheme.length].toLower != scheme) return "";
    return h[scheme.length .. $].strip;
}

/// Verifies the bearer token (own JWT or XSUAA JWT forwarded by the approuter).
Authentication authenticate(AuthUseCases auth, HTTPServerRequest req)
{
    auto token = bearerToken(req);
    if (!token.length) throw new UnauthorizedException("Missing bearer token");
    return auth.authenticate(token);
}

void writeJson(HTTPServerResponse res, int status, Json j)
{
    res.headers["Cache-Control"] = "no-store";
    res.writeBody(j.toString(), status, "application/json;charset=utf-8");
}

void writeError(HTTPServerResponse res, int status, string msg)
{
    Json e = Json.emptyObject;
    e["code"] = status.to!string;
    e["message"] = msg;
    Json j = Json.emptyObject;
    j["error"] = e;
    if (status == 401) res.headers["WWW-Authenticate"] = `Bearer realm="ecm"`;
    writeJson(res, status, j);
}

/// Maps business exceptions to HTTP status codes.
int statusOf(DomainException e)
{
    if (cast(UnauthorizedException) e) return 401;
    if (cast(ForbiddenException) e) return 403;
    if (cast(NotFoundException) e) return 404;
    if (cast(ConflictException) e) return 409;
    return 400;
}

/// Security headers for every API response.
void applySecurityHeaders(HTTPServerResponse res)
{
    res.headers["X-Content-Type-Options"] = "nosniff";
    res.headers["Referrer-Policy"] = "no-referrer";
    res.headers["X-Frame-Options"] = "DENY";
}
