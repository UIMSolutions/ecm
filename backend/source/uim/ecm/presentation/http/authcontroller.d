/// Driving adapter for authentication (JSON over HTTP):
///   POST /odata/auth/login     {Tenant, Username, Password} -> JWT (empty Tenant = platform)
///   POST /odata/auth/refresh   (Bearer) -> new JWT, old one revoked
///   POST /odata/auth/logout    (Bearer) -> token revoked
///   GET  /odata/auth/me        (Bearer) -> session (user, tenant, auth method, expiry)
///   POST /odata/auth/password  (Bearer) {CurrentPassword, NewPassword}
///   GET  /odata/auth/config    -> which sign-in methods the UI should offer
/// Password hashing is CPU-bound, so at most `maxLogins` hashes run concurrently across all
/// worker threads; extra attempts get 503 + Retry-After and cannot starve normal traffic.
module uim.ecm.presentation.http.authcontroller;

import core.atomic;
import core.time : msecs;
import vibe.core.core : sleep;
import vibe.data.json;
import vibe.http.router : URLRouter;
import vibe.http.server;
import vibe.stream.operations : readAllUTF8;
import uim.ecm.application.dtos;
import uim.ecm.domain;
import uim.ecm.infrastructure.monitoring.metrics;
import uim.ecm.ports.usecases;
import uim.ecm.presentation.http.security;
import uim.ecm.presentation.odata.mapper;

final class AuthController
{
    private enum prefix = "/odata/auth";
    private AuthUseCases auth;
    private int maxLogins;
    private bool localLogin, xsuaaLogin;
    private size_t maxBody = 16 * 1024;

    this(AuthUseCases auth, int maxLogins, bool localLogin, bool xsuaaLogin)
    {
        this.auth = auth;
        this.maxLogins = maxLogins < 1 ? 1 : maxLogins;
        this.localLogin = localLogin;
        this.xsuaaLogin = xsuaaLogin;
    }

    void register(URLRouter router)
    {
        router.post(prefix ~ "/login", &login);
        router.post(prefix ~ "/refresh", &refresh);
        router.post(prefix ~ "/logout", &logout);
        router.get(prefix ~ "/me", &me);
        router.post(prefix ~ "/password", &password);
        router.get(prefix ~ "/config", &config);
    }

    private Json readBody(HTTPServerRequest req)
    {
        auto s = req.bodyReader.readAllUTF8(false, maxBody);
        return s.length ? parseJsonString(s) : Json.emptyObject;
    }

    private void login(HTTPServerRequest req, HTTPServerResponse res)
    {
        applySecurityHeaders(res);
        bool released;
        void release() { if (!released) { released = true; atomicOp!"-="(activeLogins, 1); } }
        scope (exit) release();

        if (atomicOp!"+="(activeLogins, 1) > maxLogins)
        {
            release();
            atomicOp!"+="(loginsRejected, 1);
            res.headers["Retry-After"] = "2";
            writeError(res, 503, "Server busy, please retry shortly");
            return;
        }
        try
        {
            auto b = readBody(req);
            auto r = auth.login(str(b, "Tenant"), str(b, "Username"), str(b, "Password"));
            release();
            atomicOp!"+="(loginsSucceeded, 1);
            writeJson(res, 200, tokenJson(r));
        }
        catch (UnauthorizedException e)
        {
            release(); // free the slot before the (non-blocking) brute-force delay
            atomicOp!"+="(loginsFailed, 1);
            sleep(500.msecs);
            writeError(res, 401, e.msg);
        }
        catch (DomainException e) writeError(res, statusOf(e), e.msg);
        catch (JSONException e) writeError(res, 400, "Invalid JSON body");
    }

    private void refresh(HTTPServerRequest req, HTTPServerResponse res)
    {
        handle(res, { writeJson(res, 200, tokenJson(auth.refresh(authenticate(auth, req)))); });
    }

    private void logout(HTTPServerRequest req, HTTPServerResponse res)
    {
        handle(res, {
            auth.logout(authenticate(auth, req));
            res.statusCode = 204;
            res.writeVoidBody();
        });
    }

    private void me(HTTPServerRequest req, HTTPServerResponse res)
    {
        handle(res, { writeJson(res, 200, toJson(auth.session(authenticate(auth, req)))); });
    }

    private void password(HTTPServerRequest req, HTTPServerResponse res)
    {
        handle(res, {
            auto who = authenticate(auth, req).principal;
            auto b = readBody(req);
            auth.changePassword(who, PasswordChange(str(b, "CurrentPassword"), str(b, "NewPassword")));
            res.statusCode = 204;
            res.writeVoidBody();
        });
    }

    private void config(HTTPServerRequest req, HTTPServerResponse res)
    {
        Json j = Json.emptyObject;
        j["localLogin"] = localLogin;
        j["xsuaaLogin"] = xsuaaLogin;
        j["tokenType"] = "JWT";
        writeJson(res, 200, j);
    }

    private void handle(HTTPServerResponse res, scope void delegate() action)
    {
        applySecurityHeaders(res);
        try action();
        catch (DomainException e) writeError(res, statusOf(e), e.msg);
        catch (JSONException e) writeError(res, 400, "Invalid JSON body");
    }

    /// OAuth2-style token response plus the session (and the legacy "token"/"expiresAt" fields).
    private static Json tokenJson(LoginResult r)
    {
        auto j = toJson(r.session);
        j["access_token"] = r.accessToken;
        j["token_type"] = r.tokenType;
        j["expires_in"] = r.expiresIn;
        j["token"] = r.accessToken;
        j["expiresAt"] = r.expiresAt;
        return j;
    }
}
