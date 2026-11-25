sap.ui.define(function () {
	"use strict";

	return {
		name: "QUnit test suite for uim.ecm",
		defaults: {
			page: "ui5://test-resources/uim/ecm/Test.qunit.html?testsuite={suite}&test={name}",
			qunit: { version: 2 },
			sinon: { version: 4 },
			ui5: { theme: "sap_fiori_3", compatVersion: "edge", async: true, resourceroots: { "uim.ecm": "../" } },
			loader: { paths: { "uim/ecm": "../" } }
		},
		tests: {
			"unit/unitTests": { title: "Unit tests (formatter, session/JWT)" },
			"integration/opaTests": { title: "OPA journey (login page)" }
		}
	};
});
