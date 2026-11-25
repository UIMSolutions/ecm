sap.ui.define([
	"uim/ecm/controller/BaseController",
	"sap/ui/Device"
], function (BaseController, Device) {
	"use strict";

	return BaseController.extend("uim.ecm.controller.App", {
		onInit() {
			this.getView().addStyleClass(Device.support.touch ? "sapUiSizeCozy" : "sapUiSizeCompact");
		}
	});
});
