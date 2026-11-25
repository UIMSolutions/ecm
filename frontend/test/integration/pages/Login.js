sap.ui.define([
	"sap/ui/test/Opa5",
	"sap/ui/test/actions/Press",
	"sap/ui/test/matchers/PropertyStrictEquals"
], function (Opa5, Press, PropertyStrictEquals) {
	"use strict";

	const viewName = "Login";

	Opa5.createPageObjects({
		onTheLoginPage: {
			actions: {
				iPressSignInWithoutInput() {
					return this.waitFor({
						viewName, controlType: "sap.m.Button",
						matchers: new PropertyStrictEquals({ name: "type", value: "Emphasized" }),
						actions: new Press(), errorMessage: "Sign-in button not found"
					});
				}
			},
			assertions: {
				iSeeTheSignInButton() {
					return this.waitFor({
						viewName, controlType: "sap.m.Button",
						matchers: new PropertyStrictEquals({ name: "type", value: "Emphasized" }),
						success: () => Opa5.assert.ok(true, "The sign-in button is visible"),
						errorMessage: "Sign-in button not found"
					});
				},
				theUserFieldIsMarkedAsError() {
					return this.waitFor({
						viewName, id: "userInput",
						matchers: new PropertyStrictEquals({ name: "valueState", value: "Error" }),
						success: () => Opa5.assert.ok(true, "The user name field shows an error"),
						errorMessage: "User name field is not marked"
					});
				}
			}
		}
	});
});
