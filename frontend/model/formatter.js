sap.ui.define([], function () {
	"use strict";

	return {
		state(s) {
			return s === "Published" ? "Success" : s === "Archived" ? "Warning" : "None";
		},
		size(n) {
			if (!n) return "–";
			if (n < 1024) return n + " B";
			if (n < 1048576) return (n / 1024).toFixed(1) + " KB";
			return (n / 1048576).toFixed(1) + " MB";
		},
		date(d) {
			return d ? new Date(d).toLocaleString() : "";
		},
		/** Unix seconds -> local time ("" for 0/undefined). */
		unixTime(s) {
			return s ? new Date(s * 1000).toLocaleString() : "";
		}
	};
});
