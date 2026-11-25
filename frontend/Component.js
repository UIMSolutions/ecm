sap.ui.define([
	"sap/ui/core/UIComponent",
	"sap/ui/model/json/JSONModel",
	"uim/ecm/model/models",
	"uim/ecm/model/session"
], function (UIComponent, JSONModel, models, Session) {
	"use strict";

	return UIComponent.extend("uim.ecm.Component", {
		metadata: { manifest: "json", interfaces: ["sap.ui.core.IAsyncContentCreation"] },

		init() {
			// The session must exist before UIComponent#init creates the root view, whose
			// controller waits for `ready`.
			const appView = new JSONModel({ busy: true });
			this.setModel(appView, "appView");
			this.session = new Session({
				onExpired: (reason) => this.getRouter().navTo("login", { "?query": { reason } }, true)
			});
			this.ready = this.session.restore().catch(() => false).finally(() => appView.setProperty("/busy", false));

			UIComponent.prototype.init.apply(this, arguments);

			this.setModel(models.createDeviceModel(), "device");
			this.setModel(this.session.getModel(), "session");
			this.session.setODataModel(this.getModel()); // sends the JWT with every OData V4 request
			// route only once we know whether someone is signed in (no flash of the main page)
			this.ready.then((signedIn) => {
				const router = this.getRouter();
				if (!signedIn && !/login/.test(window.location.hash)) router.navTo("login", {}, true);
				router.initialize();
			});
		},

		destroy() {
			if (this.session) this.session.destroy();
			UIComponent.prototype.destroy.apply(this, arguments);
		}
	});
});
