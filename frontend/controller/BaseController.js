sap.ui.define([
	"sap/ui/core/mvc/Controller",
	"sap/ui/core/UIComponent",
	"sap/m/MessageBox"
], function (Controller, UIComponent, MessageBox) {
	"use strict";

	return Controller.extend("uim.ecm.controller.BaseController", {
		getRouter() { return UIComponent.getRouterFor(this); },
		getSession() { return this.getOwnerComponent().session; },
		text(key, args) { return this.getOwnerComponent().getModel("i18n").getResourceBundle().getText(key, args); },

		/**
		 * OData call through the session (bearer token, CSRF, 401 handling).
		 * Returns the Response, or null after showing the error (unless quiet).
		 */
		async api(method, path, body, headers, quiet) {
			let res;
			try {
				res = await this.getSession().api(method, path, body, headers);
			} catch (e) {
				if (!quiet) MessageBox.error(this.text("networkError"));
				return null;
			}
			if (res.status === 401) return null; // the session navigates to the login page
			if (!res.ok) {
				let msg = res.statusText;
				try { msg = (await res.json()).error.message; } catch (e) { /* keep status text */ }
				if (!quiet) MessageBox.error(msg);
				return null;
			}
			return res;
		}
	});
});
