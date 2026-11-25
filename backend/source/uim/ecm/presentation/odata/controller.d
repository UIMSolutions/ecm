/// Driving adapter: OData v4 over HTTP. Talks only to the use-case ports.
/// Entity sets are described once (EntitySet) and served by one generic CRUD routine.
module uim.ecm.presentation.odata.controller;

import core.atomic;
import std.algorithm.iteration : map;
import std.algorithm.searching : startsWith;
import std.array : array, join, replace, split;
import std.conv : to;
import std.regex : matchFirst, regex;
import std.string : indexOf, strip;
import std.uri : decodeComponent;
import vibe.core.log;
import vibe.data.json;
import vibe.http.common : HTTPMethod, HTTPStatusException;
import vibe.http.router : URLRouter;
import vibe.http.server;
import vibe.core.stream : InputStream, IOMode, OutputStream;
import vibe.internal.interfaceproxy : InterfaceProxy;
import vibe.stream.operations : readAllUTF8;
import uim.ecm.presentation.odata.mapper;
import uim.ecm.presentation.odata.metadata;
import uim.ecm.infrastructure.monitoring.metrics;
import uim.ecm.presentation.odata.query;
import uim.ecm.presentation.http.security;
import uim.ecm.application.dtos;
import uim.ecm.ports.usecases;
import uim.ecm.ports;
import uim.ecm.domain;

final class ODataController {
    private enum prefix = "/odata/v4/ecm";

    private struct EntitySet {
        Json[]delegate(Principal, HTTPServerRequest) list;
        Json delegate(Principal, string) get;
        Json delegate(Principal, Json) create;
        Json delegate(Principal, string, Json) update;
        void delegate(Principal, string) remove;
    }

    private DocumentUseCases ecm;
    private AuthUseCases auth;
    private TenancyUseCases tenancy;
    private NotificationUseCases notifications;
    private string corsOrigin;
    private EntitySet[string] sets;

    this(DocumentUseCases ecm, AuthUseCases auth, TenancyUseCases tenancy, NotificationUseCases notifications,
        string corsOrigin) {
        this.ecm = ecm;
        this.auth = auth;
        this.tenancy = tenancy;
        this.notifications = notifications;
        this.corsOrigin = corsOrigin;

        sets["Folders"] = EntitySet(
            (Principal w, HTTPServerRequest r) => ecm.listFolders(w, pushdown(r.query.get("$filter", ""), "WorkspaceID"))
                .map!(x => toJson(x)).array,
                (Principal w, string k) => toJson(ecm.getFolder(w, k)),
                (Principal w, Json b) => toJson(ecm.createFolder(w, str(b, "WorkspaceID"), str(b, "Name"), str(b, "ParentID"))),
                (Principal w, string k, Json b) {
            FolderPatch p;
            if (has(b, "Name"))
                p.name = str(b, "Name");
            if (has(b, "ParentID"))
                p.parentId = str(b, "ParentID");
            return toJson(ecm.updateFolder(w, k, p));
        },
            (Principal w, string k) { ecm.deleteFolder(w, k); });

        sets["Documents"] = EntitySet(
            (Principal w, HTTPServerRequest r) => documentItems(w, r),
            (Principal w, string k) => toJson(ecm.getDocument(w, k)),
            (Principal w, Json b) => toJson(ecm.createDocument(w, NewDocument(str(b, "WorkspaceID"),
                str(b, "FolderID"), str(b, "Name"), str(b, "Title"), str(b, "MimeType")))),
            (Principal w, string k, Json b) {
            DocumentPatch p;
            if (has(b, "Name"))
                p.name = str(b, "Name");
            if (has(b, "Title"))
                p.title = str(b, "Title");
            if (has(b, "FolderID"))
                p.folderId = str(b, "FolderID");
            return toJson(ecm.updateDocument(w, k, p));
        },
            (Principal w, string k) { ecm.deleteDocument(w, k); });

        sets["Users"] = EntitySet(
            (Principal w, HTTPServerRequest r) => auth.listUsers(w)
                .map!(x => toJson(x)).array,
                (Principal w, string k) => toJson(auth.getUser(w, k)),
                (Principal w, Json b) => toJson(auth.createUser(w, NewUser(str(b, "TenantID"), str(b, "Username"),
                    str(b, "DisplayName"), str(b, "Email"), str(b, "Password"), str(b, "Role")))),
                (Principal w, string k, Json b) {
            UserPatch p;
            if (has(b, "DisplayName"))
                p.displayName = str(b, "DisplayName");
            if (has(b, "Email"))
                p.email = str(b, "Email");
            if (has(b, "Password"))
                p.password = str(b, "Password");
            if (has(b, "Role"))
                p.role = str(b, "Role");
            if (b["Active"].type == Json.Type.bool_)
                p.active = b["Active"].get!bool;
            return toJson(auth.updateUser(w, k, p));
        },
            (Principal w, string k) { auth.deleteUser(w, k); });

        sets["Tenants"] = EntitySet(
            (Principal w, HTTPServerRequest r) => tenancy.listTenants(w)
                .map!(x => toJson(x)).array,
                (Principal w, string k) => toJson(tenancy.getTenant(w, k)),
                (Principal w, Json b) => toJson(tenancy.createTenant(w, NewTenant(str(b, "Name"), str(b, "Slug")))),
                (Principal w, string k, Json b) {
            TenantPatch p;
            if (has(b, "Name"))
                p.name = str(b, "Name");
            if (b["Active"].type == Json.Type.bool_)
                p.active = b["Active"].get!bool;
            return toJson(tenancy.updateTenant(w, k, p));
        },
            (Principal w, string k) { tenancy.deleteTenant(w, k); });

        sets["Workspaces"] = EntitySet(
            (Principal w, HTTPServerRequest r) => tenancy.listWorkspaces(w)
                .map!(x => toJson(x)).array,
                (Principal w, string k) => toJson(tenancy.getWorkspace(w, k)),
                (Principal w, Json b) => toJson(tenancy.createWorkspace(w, str(b, "Name"), str(b, "Description"))),
                (Principal w, string k, Json b) {
            WorkspacePatch p;
            if (has(b, "Name"))
                p.name = str(b, "Name");
            if (has(b, "Description"))
                p.description = str(b, "Description");
            return toJson(tenancy.updateWorkspace(w, k, p));
        },
            (Principal w, string k) { tenancy.deleteWorkspace(w, k); });

        sets["Members"] = EntitySet(
            (Principal w, HTTPServerRequest r) => tenancy.listMembers(w)
                .map!(x => toJson(x)).array,
                (Principal w, string k) {
            foreach (m; tenancy.listMembers(w))
                if (m.membership.id == k)
                    return toJson(m);
            throw new NotFoundException("Member not found");
        },
            (Principal w, Json b) => toJson(tenancy.addMember(w, str(b, "WorkspaceID"), str(b, "Username"), str(b, "Role"))),
            (Principal w, string k, Json b) => toJson(tenancy.updateMember(w, k, str(b, "Role"))),
            (Principal w, string k) { tenancy.removeMember(w, k); });

        // Own notifications only; created by the system, so no POST (405).
        sets["Notifications"] = EntitySet(
            (Principal w, HTTPServerRequest r) => notifications.list(w)
                .map!(x => toJson(x)).array,
                (Principal w, string k) => toJson(notifications.get(w, k)),
                null,
                (Principal w, string k, Json b) => toJson(notifications.setRead(w, k,
                    b["Read"].type == Json.Type.bool_ ? b["Read"].get!bool : true)),
                (Principal w, string k) { notifications.remove(w, k); });
    }

    void register(URLRouter router) {
        router.any(prefix, &handle);
        router.any(prefix ~ "/*", &handle);
    }

    private void handle(HTTPServerRequest req, HTTPServerResponse res) {
        atomicOp!"+="(inFlight, 1);
        scope (exit)
            atomicOp!"-="(inFlight, 1);
        atomicOp!"+="(requestsTotal, 1);
        try {
            applyCors(res);
            applySecurityHeaders(res);
            if (req.method == HTTPMethod.OPTIONS) {
                res.statusCode = 204;
                res.writeVoidBody();
                return;
            }
            res.headers["OData-Version"] = "4.0";
            auto path = relativePath(req);
            if (path.length == 0 || path == "/") {
                serviceDocument(res);
                return;
            }
            if (path == "/$metadata") {
                res.writeBody(metadataXml, 200, "application/xml");
                return;
            }
            route(path[1 .. $], authenticate(auth, req).principal, req, res);
        } catch (UnauthorizedException e) {
            res.headers["WWW-Authenticate"] = "Bearer";
            sendError(res, 401, e.msg);
        } catch (ForbiddenException e) {
            sendError(res, 403, e.msg);
        } catch (NotFoundException e) {
            sendError(res, 404, e.msg);
        } catch (ValidationException e) {
            sendError(res, 400, e.msg);
        } catch (ConflictException e) {
            sendError(res, 409, e.msg);
        } catch (DomainException e) {
            sendError(res, 400, e.msg);
        } catch (HTTPStatusException e) {
            sendError(res, e.status, e.msg);
        } catch (JSONException e) {
            sendError(res, 400, "Invalid JSON body");
        } catch (Exception e) {
            logError("ECM error: %s", e.msg);
            sendError(res, 500, "Internal server error");
        }
    }

    private void route(string seg, Principal who, HTTPServerRequest req, HTTPServerResponse res) {
        if (seg == "Reindex") {
            if (req.method != HTTPMethod.POST)
                throw new HTTPStatusException(405, "Method not allowed");
            Json j = Json.emptyObject;
            j["value"] = cast(long)ecm.reindexAll(who);
            sendJson(res, 200, j);
            return;
        }
        if (seg == "MarkAllNotificationsRead") {
            if (req.method != HTTPMethod.POST)
                throw new HTTPStatusException(405, "Method not allowed");
            Json j = Json.emptyObject;
            j["value"] = cast(long)notifications.markAllRead(who);
            sendJson(res, 200, j);
            return;
        }
        auto m = matchFirst(seg, regex(
                `^(Folders|Documents|Users|Tenants|Workspaces|Members|Notifications)(?:\('([^']*)'\))?(?:/(.+))?$`));
        if (m.empty)
            throw new NotFoundException("Unknown resource: " ~ seg);
        string set = m[1].idup, key = m[2].idup, rest = m[3].idup;
        bool hasKey = key.length > 0;
        if (set == "Documents" && hasKey && rest.length) {
            documentExtras(key, rest, who, req, res);
            return;
        }
        crud(set, hasKey, key, rest, who, req, res);
    }

    private void crud(string name, bool hasKey, string key, string rest, Principal who,
        HTTPServerRequest req, HTTPServerResponse res) {
        auto s = sets[name];
        auto m = req.method;
        if (!hasKey) {
            if (rest == "$count" && m == HTTPMethod.GET) {
                sendCount(s.list(who, req), req, res);
                return;
            }
            if (rest.length)
                throw new NotFoundException("Unknown resource");
            if (m == HTTPMethod.GET) {
                sendCollection(name, s.list(who, req), req, res);
                return;
            }
            if (m == HTTPMethod.POST && s.create !is null) {
                auto j = s.create(who, readBody(req));
                sendCreated(res, name, j["ID"].get!string, j);
                return;
            }
            throw new HTTPStatusException(405, "Method not allowed");
        }
        if (rest.length)
            throw new NotFoundException("Unknown resource");
        switch (m) {
        case HTTPMethod.GET: {
                sendEntity(res, name, s.get(who, key));
                return;
            }
        case HTTPMethod.PATCH, HTTPMethod.PUT: {
                sendEntity(res, name, s.update(who, key, readBody(req)));
                return;
            }
        case HTTPMethod.DELETE: {
                s.remove(who, key);
                noContent(res);
                return;
            }
        default:
            throw new HTTPStatusException(405, "Method not allowed");
        }
    }

    /// Documents('id')/$value (content) and the bound actions ECM.Publish / ECM.Archive.
    private void documentExtras(string key, string rest, Principal who, HTTPServerRequest req, HTTPServerResponse res) {
        auto m = req.method;
        if (rest == "$value") {
            if (m == HTTPMethod.GET) {
                auto info = ecm.contentInfo(who, key);
                res.contentType = info.mimeType;
                res.headers["Content-Length"] = info.size.to!string;
                res.headers["Content-Disposition"] = "attachment; filename=\"" ~ info.fileName.replace("\"", "") ~ "\"";
                ecm.readContent(who, key, new VibeSink(res.bodyWriter)); // streamed in chunks
                return;
            }
            if (m == HTTPMethod.PUT) {
                ecm.uploadContent(who, key, new VibeSource(req.bodyReader), // streamed to disk
                    req.headers.get("Content-Type", "application/octet-stream"));
                noContent(res);
                return;
            }
            throw new HTTPStatusException(405, "Method not allowed");
        }
        if (rest == "ECM.Publish" || rest == "ECM.Archive") {
            if (m != HTTPMethod.POST)
                throw new HTTPStatusException(405, "Method not allowed");
            sendJson(res, 200, toJson(rest == "ECM.Publish" ? ecm.publish(who, key) : ecm.archive(who, key)));
            return;
        }
        throw new NotFoundException("Unknown resource");
    }

    // ---------------- helpers ----------------
    /// $search: full-text hits by relevance. Otherwise the WorkspaceID/FolderID terms of $filter are
    /// pushed down to the repository indexes, so only the relevant documents are loaded.
    private Json[] documentItems(Principal who, HTTPServerRequest req) {
        auto q = req.query.get("$search", "").strip;
        if (q.length > 0)
            return ecm.searchDocuments(who, q, 500).map!(h => toJson(h.doc, h.snippet, h.score))
                .array;
        auto filter = req.query.get("$filter", "");
        return ecm.listDocuments(who, DocumentFilter(pushdown(filter, "WorkspaceID"), pushdown(filter, "FolderID")))
            .map!(d => toJson(d)).array;
    }

    private string relativePath(HTTPServerRequest req) {
        auto uri = req.requestURI;
        auto q = uri.indexOf('?');
        if (q >= 0)
            uri = uri[0 .. q];
        return decodeComponent(uri)[prefix.length .. $];
    }

    private Json readBody(HTTPServerRequest req) {
        auto s = req.bodyReader.readAllUTF8();
        return s.length ? parseJsonString(s) : Json.emptyObject;
    }

    private void applyCors(HTTPServerResponse res) {
        if (!corsOrigin.length)
            return;
        res.headers["Access-Control-Allow-Origin"] = corsOrigin;
        res.headers["Access-Control-Allow-Methods"] = "GET,POST,PATCH,PUT,DELETE,OPTIONS";
        res.headers["Access-Control-Allow-Headers"] =
            "Content-Type,Accept,OData-Version,OData-MaxVersion,Prefer,If-Match,Authorization,X-CSRF-Token";
        res.headers["Access-Control-Expose-Headers"] = "Location,OData-Version";
    }

    private void serviceDocument(HTTPServerResponse res) {
        Json j = Json.emptyObject;
        j["@odata.context"] = "$metadata";
        Json[] v;
        foreach (n; [
                "Tenants", "Workspaces", "Members", "Users", "Folders",
                "Documents", "Notifications"
            ]) {
            Json e = Json.emptyObject;
            e["name"] = n;
            e["kind"] = "EntitySet";
            e["url"] = n;
            v ~= e;
        }
        j["value"] = Json(v);
        sendJson(res, 200, j);
    }

    private enum maxPage = 1000;

    private void sendCollection(string set, Json[] items, HTTPServerRequest req, HTTPServerResponse res) {
        auto opts = parseOptions(req);
        bool searching = req.query.get("$search", "").strip.length > 0;
        if (!searching && opts.orderby.length == 0)
            opts.orderby = "CreatedAt,ID"; // stable paging
        bool capped = opts.top < 0 || opts.top > maxPage; // never return unbounded pages
        if (capped)
            opts.top = maxPage;
        auto r = applyQuery(items, opts);
        Json j = Json.emptyObject;
        j["@odata.context"] = "$metadata#" ~ set;
        if (opts.count)
            j["@odata.count"] = r.total;
        j["value"] = Json(r.page);
        long next = (opts.skip < 0 ? 0 : opts.skip) + cast(long)r.page.length;
        if (capped && next < r.total)
            j["@odata.nextLink"] = nextLink(req, next, maxPage);
        sendJson(res, 200, j);
    }

    private string nextLink(HTTPServerRequest req, long skip, long top) {
        auto uri = req.requestURI;
        auto q = uri.indexOf('?');
        string base = q < 0 ? uri : uri[0 .. q];
        string[] keep;
        if (q >= 0)
            foreach (part; uri[q + 1 .. $].split("&"))
                if (!part.startsWith("$skip=") && !part.startsWith("$top="))
                    keep ~= part;
        keep ~= "$skip=" ~ skip.to!string;
        keep ~= "$top=" ~ top.to!string;
        return base ~ "?" ~ keep.join("&");
    }

    private void sendCount(Json[] items, HTTPServerRequest req, HTTPServerResponse res) {
        auto o = parseOptions(req);
        o.top = -1;
        o.skip = 0;
        res.writeBody(applyQuery(items, o).total.to!string, 200, "text/plain");
    }

    private void sendEntity(HTTPServerResponse res, string set, Json j) {
        j["@odata.context"] = "$metadata#" ~ set ~ "/$entity";
        sendJson(res, 200, j);
    }

    private void sendCreated(HTTPServerResponse res, string set, string id, Json j) {
        j["@odata.context"] = "$metadata#" ~ set ~ "/$entity";
        res.headers["Location"] = prefix ~ "/" ~ set ~ "('" ~ id ~ "')";
        sendJson(res, 201, j);
    }

    private void noContent(HTTPServerResponse res) {
        res.statusCode = 204;
        res.writeVoidBody();
    }

    private void sendJson(HTTPServerResponse res, int status, Json body_) {
        res.writeBody(body_.toString(), status, "application/json;odata.metadata=minimal;charset=utf-8");
    }

    private void sendError(HTTPServerResponse res, int status, string msg) {
        atomicOp!"+="(requestsFailed, 1);
        Json err = Json.emptyObject;
        err["code"] = status.to!string;
        err["message"] = msg;
        Json j = Json.emptyObject;
        j["error"] = err;
        sendJson(res, status, j);
    }
}

/// Adapts vibe.d streams to the application's streaming ports (64 KiB at a time, no buffering of whole files).
private final class VibeSource : ByteSource {
    private InputStream s;
    this(InputStream s) {
        this.s = s;
    }

    size_t read(scope ubyte[] buf) {
        return s.empty ? 0 : s.read(buf, IOMode.once);
    }
}

private final class VibeSink : ByteSink {
    private InterfaceProxy!OutputStream o;
    this(InterfaceProxy!OutputStream o) {
        this.o = o;
    }

    void write(scope const(ubyte)[] data) {
        o.write(data);
    }
}
