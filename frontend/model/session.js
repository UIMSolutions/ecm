/**
 * Client side of the authentication: holds the JWT access token, keeps it fresh and
 * performs authenticated requests.
 *
 *  - Local login: POST odata/auth/login returns a JWT (HS256). It lives in sessionStorage
 *    (per tab, gone when the tab closes) and is sent as "Authorization: Bearer ...".
 *  - Before it expires the token is exchanged via POST odata/auth/refresh, but only if the
 *    user was active since the last refresh; idle sessions run out and return to the login page.
 *  - Behind the SAP approuter (XSUAA) no token is stored: the approuter adds the user's JWT
 *    itself. The session detects this by calling odata/auth/me without a token.
 *  - Modifying requests send an X-CSRF-Token (required by the approuter, ignored standalone).
 */
sap.ui.define([
	"sap/ui/base/Object",
	"sap/ui/model/json/JSONModel"
], function (BaseObject, JSONModel) {
	"use strict";

	const AUTH = "odata/auth/";
	const API = "odata/v4/ecm/";
	const TOKEN_KEY = "ecm.token";
	const REFRESH_MARGIN_S = 300; // refresh 5 min before expiry (or after 80 % of short lifetimes)

	/** Decodes the payload of a JWT without verifying it (the server verifies). */
	function decodeJwt(token) {
		try {
			const part = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
			const json = decodeURIComponent(atob(part).split("").map(
				(c) => "%" + ("00" + c.charCodeAt(0).toString(16)).slice(-2)).join(""));
			return JSON.parse(json);
		} catch (e) {
			return null;
		}
	}

	const Session = BaseObject.extend("uim.ecm.model.Session", {
		constructor: function (options) {
			BaseObject.call(this);
			this._odata = options.odataModel || null;
			this._onExpired = options.onExpired || function () {};
			this._storage = options.storage || window.sessionStorage;
			this._fetch = options.fetch || window.fetch.bind(window);
			this._token = null;
			this._csrf = null;
			this._timer = null;
			this._lastActivity = Date.now();
			this._model = new JSONModel({
				authenticated: false, method: "", user: null, tenant: null, expiresAt: 0,
				localLogin: true, xsuaaLogin: false, isPlatform: false, isTenantAdmin: false
			});
			this._onActivity = () => { this._lastActivity = Date.now(); };
			["pointerdown", "keydown"].forEach((e) => document.addEventListener(e, this._onActivity, { passive: true }));
		},

		destroy() {
			clearTimeout(this._timer);
			["pointerdown", "keydown"].forEach((e) => document.removeEventListener(e, this._onActivity));
			BaseObject.prototype.destroy.apply(this, arguments);
		},

		getModel() { return this._model; },

		/** Lets the OData V4 model send the current token (also set later than construction). */
		setODataModel(model) {
			this._odata = model;
			if (model) model.changeHttpHeaders({ Authorization: this._token ? "Bearer " + this._token : undefined });
		},
		isAuthenticated() { return this._model.getProperty("/authenticated"); },
		getToken() { return this._token; },

		/** Restores a session after reload (stored JWT or approuter). Resolves to true if signed in. */
		async restore() {
			await this._loadConfig();
			const stored = this._storage.getItem(TOKEN_KEY);
			if (stored) {
				const claims = decodeJwt(stored);
				if (claims && claims.exp * 1000 > Date.now() + 5000 && await this._me(stored)) return true;
				this._storage.removeItem(TOKEN_KEY);
			}
			if (this._model.getProperty("/xsuaaLogin")) return this._me(null); // token added by the approuter
			return false;
		},

		/**
		 * Signs in with tenant, user name and password. Retries with jitter while the server limits
		 * concurrent logins (503). Rejects with an Error whose `status` is the HTTP status.
		 */
		async login(tenant, username, password, onBusy) {
			const body = JSON.stringify({ Tenant: tenant, Username: username, Password: password });
			let res;
			for (let attempt = 0; attempt < 6; attempt++) {
				res = await this._fetch(AUTH + "login", {
					method: "POST", headers: { "Content-Type": "application/json", Accept: "application/json" }, body
				});
				if (res.status !== 503) break;
				if (onBusy) onBusy();
				const wait = (parseInt(res.headers.get("Retry-After"), 10) || 2) * 1000;
				await new Promise((done) => setTimeout(done, wait + Math.random() * 2000));
			}
			if (!res.ok) throw await this._error(res);
			this._apply(await res.json(), true);
		},

		/** Exchanges the current JWT for a new one (the old one is revoked by the server). */
		async refresh() {
			if (!this._token) return false;
			const res = await this._fetch(AUTH + "refresh", { method: "POST", headers: this._authHeaders() });
			if (!res.ok) {
				if (res.status === 401) this._expire("sessionExpired");
				return false;
			}
			this._apply(await res.json(), true);
			return true;
		},

		/** Revokes the token on the server and forgets it locally. */
		async logout() {
			const external = this._model.getProperty("/method") === "xsuaa";
			if (this._token) {
				try {
					await this._fetch(AUTH + "logout", { method: "POST", headers: this._authHeaders() });
				} catch (e) { /* the token expires anyway */ }
			}
			this._clear();
			if (external) window.location.href = "do/logout"; // approuter ends the XSUAA session
		},

		async changePassword(currentPassword, newPassword) {
			const res = await this.request("POST", AUTH + "password",
				{ CurrentPassword: currentPassword, NewPassword: newPassword });
			if (!res.ok) throw await this._error(res);
		},

		/** OData request relative to the service root. */
		api(method, path, body, headers) {
			return this.request(method, API + path, body, headers);
		},

		/**
		 * Authenticated fetch. Adds the bearer token and, for modifying requests, the CSRF token.
		 * A 401 ends the session (navigation to the login page). Returns the Response.
		 */
		async request(method, url, body, headers) {
			this._lastActivity = Date.now();
			const raw = body instanceof Blob;
			const send = async () => {
				const h = Object.assign({ Accept: "application/json" }, this._authHeaders(),
					body && !raw ? { "Content-Type": "application/json" } : {}, headers || {});
				if (method !== "GET" && method !== "HEAD") h["X-CSRF-Token"] = await this._csrfToken();
				return this._fetch(url, { method, headers: h, body: body ? (raw ? body : JSON.stringify(body)) : undefined });
			};
			let res = await send();
			if (res.status === 403 && (res.headers.get("X-CSRF-Token") || "").toLowerCase() === "required") {
				this._csrf = null; // expired CSRF token: fetch a new one and retry once
				res = await send();
			}
			if (res.status === 401) this._expire("sessionExpired");
			return res;
		},

		// ---- internals ----
		async _loadConfig() {
			try {
				const res = await this._fetch(AUTH + "config", { headers: { Accept: "application/json" } });
				if (res.ok) {
					const c = await res.json();
					this._model.setProperty("/localLogin", c.localLogin !== false);
					this._model.setProperty("/xsuaaLogin", !!c.xsuaaLogin);
				}
			} catch (e) { /* backend not reachable yet: keep defaults */ }
		},

		async _me(token) {
			try {
				const res = await this._fetch(AUTH + "me", {
					headers: Object.assign({ Accept: "application/json" }, token ? { Authorization: "Bearer " + token } : {})
				});
				if (!res.ok) return false;
				const s = await res.json();
				s.access_token = token;
				this._apply(s, !!token);
				return true;
			} catch (e) {
				return false;
			}
		},

		_apply(s, local) {
			const user = s.user;
			this._token = local ? s.access_token : null;
			if (this._token) this._storage.setItem(TOKEN_KEY, this._token);
			const claims = this._token ? decodeJwt(this._token) : null;
			const expiresAt = (claims && claims.exp) || s.expiresAt || 0;
			const m = this._model;
			m.setProperty("/authenticated", true);
			m.setProperty("/method", s.authMethod || (local ? "local" : "xsuaa"));
			m.setProperty("/user", user);
			m.setProperty("/tenant", s.tenant || null);
			m.setProperty("/expiresAt", expiresAt);
			m.setProperty("/isPlatform", !user.TenantID && user.Role === "admin");
			m.setProperty("/isTenantAdmin", !!user.TenantID && user.Role === "admin");
			m.setProperty("/external", !!user.External);
			if (this._odata) this._odata.changeHttpHeaders({ Authorization: this._token ? "Bearer " + this._token : undefined });
			this._schedule(claims);
		},

		_schedule(claims) {
			clearTimeout(this._timer);
			if (!this._token || !claims || !claims.exp) return;
			const lifetime = claims.exp - (claims.iat || claims.exp - 3600);
			const margin = Math.min(REFRESH_MARGIN_S, lifetime * 0.2);
			const issuedAt = Date.now();
			const delay = Math.max(10, claims.exp - margin - Date.now() / 1000) * 1000;
			this._timer = setTimeout(() => {
				if (this._lastActivity > issuedAt) this.refresh(); // only active sessions are extended
				else this._timer = setTimeout(() => this._expire("sessionExpired"), margin * 1000);
			}, Math.min(delay, 2147483647));
		},

		_authHeaders() {
			return this._token ? { Authorization: "Bearer " + this._token } : {};
		},

		async _csrfToken() {
			if (this._csrf !== null) return this._csrf;
			try {
				const res = await this._fetch(API, { method: "HEAD", headers: Object.assign({ "X-CSRF-Token": "Fetch" }, this._authHeaders()) });
				this._csrf = res.headers.get("X-CSRF-Token") || "unsafe";
			} catch (e) {
				this._csrf = "unsafe";
			}
			return this._csrf;
		},

		async _error(res) {
			let msg = res.statusText;
			try { msg = (await res.json()).error.message; } catch (e) { /* keep status text */ }
			const err = new Error(msg);
			err.status = res.status;
			return err;
		},

		_clear() {
			clearTimeout(this._timer);
			this._token = null;
			this._csrf = null;
			this._storage.removeItem(TOKEN_KEY);
			this._model.setProperty("/authenticated", false);
			this._model.setProperty("/user", null);
			this._model.setProperty("/tenant", null);
			this._model.setProperty("/expiresAt", 0);
			if (this._odata) this._odata.changeHttpHeaders({ Authorization: undefined });
		},

		_expire(reason) {
			if (!this.isAuthenticated()) return;
			this._clear();
			this._onExpired(reason);
		}
	});

	Session.decodeJwt = decodeJwt;
	return Session;
});
