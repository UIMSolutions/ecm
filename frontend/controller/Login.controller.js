sap.ui.define([
	"uim/ecm/controller/BaseController",
	"sap/ui/model/json/JSONModel"
], function (BaseController, JSONModel) {
	"use strict";

	const TENANT_KEY = "ecm.tenant";

	function stored() {
		try { return localStorage.getItem(TENANT_KEY); } catch (e) { return null; }
	}

	return BaseController.extend("uim.ecm.controller.Login", {
		onInit() {
			this.getView().setModel(new JSONModel({
				tenant: stored() || "", username: "", password: "", remember: stored() !== null,
				message: "", messageType: "Information", busy: false, userState: "None", passwordState: "None"
			}), "login");
			this.getRouter().getRoute("login").attachPatternMatched(this._onMatched, this);
		},

		async _onMatched(e) {
			const query = e.getParameter("arguments")["?query"] || {};
			const m = this._model();
			m.setProperty("/password", "");
			m.setProperty("/message", query.reason ? this.text(query.reason) : "");
			m.setProperty("/messageType", query.reason ? "Warning" : "Information");
			await this.getOwnerComponent().ready;
			if (this.getSession().isAuthenticated()) {
				this.getRouter().navTo("main", {}, true);
				return;
			}
			setTimeout(() => this.byId(m.getProperty("/tenant") ? "userInput" : "tenantInput").focus(), 0);
		},

		_model() { return this.getView().getModel("login"); },

		onTenantSubmit() { this.byId("userInput").focus(); },
		onUserSubmit() { this.byId("passwordInput").focus(); },

		onTogglePassword(e) {
			const input = e.getSource();
			const hidden = input.getType() === "Password";
			input.setType(hidden ? "Text" : "Password");
			input.setValueHelpIconSrc(hidden ? "sap-icon://hide" : "sap-icon://show");
		},

		onSso() {
			window.location.reload(); // the approuter redirects to the identity provider
		},

		async onSignIn() {
			const m = this._model();
			const d = m.getData();
			m.setProperty("/userState", d.username.trim() ? "None" : "Error");
			m.setProperty("/passwordState", d.password ? "None" : "Error");
			if (!d.username.trim() || !d.password || d.busy) return;

			m.setProperty("/busy", true);
			m.setProperty("/message", "");
			try {
				await this.getSession().login(d.tenant.trim(), d.username.trim(), d.password, () => {
					m.setProperty("/message", this.text("serverBusy"));
					m.setProperty("/messageType", "Information");
				});
				try {
					if (d.remember) localStorage.setItem(TENANT_KEY, d.tenant.trim());
					else localStorage.removeItem(TENANT_KEY);
				} catch (e) { /* storage disabled */ }
				m.setProperty("/password", "");
				this.getRouter().navTo("main", {}, true);
			} catch (err) {
				const key = err.status === 503 ? "serverBusy" : err.status === 403 ? "localLoginDisabled"
					: err.status === 401 ? "loginFailed" : "networkError";
				m.setProperty("/message", this.text(key));
				m.setProperty("/messageType", "Error");
				m.setProperty("/password", "");
				this.byId("passwordInput").focus();
			} finally {
				m.setProperty("/busy", false);
			}
		}
	});
});
