sap.ui.define([
	"sap/ui/model/json/JSONModel",
	"sap/ui/Device"
], function (JSONModel, Device) {
	"use strict";

	return {
		createDeviceModel() {
			const model = new JSONModel(Device);
			model.setDefaultBindingMode("OneWay");
			return model;
		},

		/** View state of the main page (derived from session + selected workspace). */
		createUiModel() {
			return new JSONModel({
				userName: "", tenantName: "", isPlatform: false, isTenantAdmin: false, canAdminUsers: false,
				canWrite: false, canManageMembers: false, noWorkspace: false, workspaces: [], workspaceId: "", unread: 0
			});
		}
	};
});
