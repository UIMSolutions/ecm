sap.ui.define([
	"uim/ecm/model/formatter",
	"uim/ecm/model/session"
], function (formatter, Session) {
	"use strict";

	QUnit.module("formatter");

	QUnit.test("state", function (assert) {
		assert.strictEqual(formatter.state("Published"), "Success");
		assert.strictEqual(formatter.state("Archived"), "Warning");
		assert.strictEqual(formatter.state("Draft"), "None");
	});

	QUnit.test("size", function (assert) {
		assert.strictEqual(formatter.size(0), "–");
		assert.strictEqual(formatter.size(512), "512 B");
		assert.strictEqual(formatter.size(2048), "2.0 KB");
		assert.strictEqual(formatter.size(3 * 1048576), "3.0 MB");
	});

	// ---- session ----
	function b64url(obj) {
		return btoa(unescape(encodeURIComponent(JSON.stringify(obj)))) // UTF-8, like real JWTs
			.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
	}
	function jwt(claims) {
		return b64url({ alg: "HS256", typ: "JWT" }) + "." + b64url(claims) + ".sig";
	}
	function response(status, body, headers) {
		return Promise.resolve(new Response(body === undefined ? null : JSON.stringify(body),
			{ status, headers: Object.assign({ "Content-Type": "application/json" }, headers || {}) }));
	}
	function memoryStorage() {
		const m = {};
		return { getItem: (k) => (k in m ? m[k] : null), setItem: (k, v) => { m[k] = v; }, removeItem: (k) => { delete m[k]; } };
	}
	const now = () => Math.floor(Date.now() / 1000);
	const user = { ID: "u1", Username: "alice", TenantID: "t1", Role: "editor" };

	QUnit.module("session");

	QUnit.test("decodeJwt", function (assert) {
		const c = Session.decodeJwt(jwt({ sub: "u1", preferred_username: "Jürgen", exp: 42 }));
		assert.strictEqual(c.sub, "u1");
		assert.strictEqual(c.exp, 42);
		assert.strictEqual(c.preferred_username, "Jürgen");
		assert.strictEqual(Session.decodeJwt("garbage"), null);
	});

	QUnit.test("login stores the JWT and sends it as bearer token", async function (assert) {
		const token = jwt({ sub: "u1", iat: now(), exp: now() + 3600 });
		const calls = [];
		const storage = memoryStorage();
		const fetch = (url, init) => {
			calls.push({ url, init });
			if (url.endsWith("auth/login")) return response(200, { access_token: token, user, tenant: { Name: "Acme" } });
			return response(200, { value: [] });
		};
		const s = new Session({ fetch, storage });
		await s.login("acme", "alice", "secret");
		assert.ok(s.isAuthenticated());
		assert.strictEqual(storage.getItem("ecm.token"), token);
		assert.strictEqual(s.getModel().getProperty("/tenant/Name"), "Acme");

		await s.api("GET", "Workspaces");
		assert.strictEqual(calls[1].init.headers.Authorization, "Bearer " + token);
		s.destroy();
	});

	QUnit.test("a 401 ends the session", async function (assert) {
		const token = jwt({ sub: "u1", iat: now(), exp: now() + 3600 });
		let expired = null;
		const fetch = (url) => url.endsWith("auth/login")
			? response(200, { access_token: token, user }) : response(401, { error: { message: "expired" } });
		const s = new Session({ fetch, storage: memoryStorage(), onExpired: (r) => { expired = r; } });
		await s.login("", "alice", "secret");
		await s.api("GET", "Documents");
		assert.notOk(s.isAuthenticated());
		assert.strictEqual(expired, "sessionExpired");
		s.destroy();
	});

	QUnit.test("failed login rejects with the HTTP status", async function (assert) {
		const s = new Session({ fetch: () => response(401, { error: { message: "nope" } }), storage: memoryStorage() });
		try {
			await s.login("acme", "alice", "wrong");
			assert.ok(false, "login should fail");
		} catch (e) {
			assert.strictEqual(e.status, 401);
		}
		s.destroy();
	});

	QUnit.test("restore() uses a stored, unexpired token", async function (assert) {
		const token = jwt({ sub: "u1", iat: now(), exp: now() + 3600 });
		const storage = memoryStorage();
		storage.setItem("ecm.token", token);
		const fetch = (url, init) => {
			if (url.endsWith("auth/config")) return response(200, { localLogin: true, xsuaaLogin: false });
			if (url.endsWith("auth/me")) {
				return init.headers.Authorization === "Bearer " + token ? response(200, { user }) : response(401, {});
			}
			return response(404, {});
		};
		const s = new Session({ fetch, storage });
		assert.ok(await s.restore());
		assert.strictEqual(s.getModel().getProperty("/method"), "local");
		s.destroy();
	});
});
