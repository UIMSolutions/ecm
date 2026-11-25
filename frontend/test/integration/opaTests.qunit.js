sap.ui.define([
	"sap/ui/test/Opa5",
	"sap/ui/test/opaQunit",
	"uim/ecm/test/integration/pages/Login"
], function (Opa5, opaTest) {
	"use strict";

	Opa5.extendConfig({ viewNamespace: "uim.ecm.view.", autoWait: true });

	QUnit.module("Login");

	opaTest("shows the login page when nobody is signed in", function (Given, When, Then) {
		Given.iStartMyUIComponent({ componentConfig: { name: "uim.ecm", async: true }, hash: "login" });
		Then.onTheLoginPage.iSeeTheSignInButton();
		When.onTheLoginPage.iPressSignInWithoutInput();
		Then.onTheLoginPage.theUserFieldIsMarkedAsError();
		Then.iTeardownMyApp();
	});
});
