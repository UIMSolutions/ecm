sap.ui.define([
  "uim/ecm/controller/BaseController", "uim/ecm/model/formatter", "uim/ecm/model/models",
  "sap/ui/model/Filter", "sap/ui/model/FilterOperator", "sap/ui/model/Sorter",
  "sap/ui/model/json/JSONModel", "sap/m/MessageToast", "sap/m/MessageBox", "sap/m/Dialog", "sap/m/Button",
  "sap/m/Input", "sap/m/Label", "sap/m/VBox", "sap/m/Select", "sap/m/CheckBox", "sap/ui/core/Item",
  "sap/m/Table", "sap/m/Column", "sap/m/ColumnListItem", "sap/m/Text",
  "sap/m/Popover", "sap/m/NotificationList", "sap/m/NotificationListItem", "sap/m/Panel",
  "sap/m/ActionSheet", "sap/m/MessageStrip"
], function (BaseController, formatter, models, Filter, FilterOperator, Sorter, JSONModel, MessageToast, MessageBox,
             Dialog, Button, Input, Label, VBox, Select, CheckBox, Item, Table, Column, ColumnListItem, Text,
             Popover, NotificationList, NotificationListItem, Panel, ActionSheet, MessageStrip) {
  "use strict";
  const WS_KEY = "ecm.workspace";
  const ROLES = ["viewer", "editor", "admin"];

  return BaseController.extend("uim.ecm.controller.Main", {
    formatter,
    _folderId: null,
    _resumed: false,

    // ---- lifecycle: the route guard sends signed-out users to the login page ----
    onInit() {
      this.getView().setModel(models.createUiModel(), "ui");
      this.getRouter().getRoute("main").attachPatternMatched(this._onMatched, this);
    },
    async _onMatched() {
      await this.getOwnerComponent().ready;
      const session = this.getSession();
      if (!session.isAuthenticated()) { this.getRouter().navTo("login", {}, true); return; }
      const user = session.getModel().getProperty("/user");
      if (this._userId === user.ID) return; // same user, view already initialised
      this._userId = user.ID;
      const s = session.getModel().getData();
      this._ui().setData({
        userName: user.DisplayName || user.Username,
        tenantName: s.tenant ? s.tenant.Name : this.text("platform"),
        isPlatform: s.isPlatform, isTenantAdmin: s.isTenantAdmin, canAdminUsers: s.isPlatform || s.isTenantAdmin,
        canWrite: false, canManageMembers: false, noWorkspace: false, workspaces: [], workspaceId: "", unread: 0
      });
      if (!s.isPlatform) { await this._loadWorkspaces(); this._startNotificationPolling(); }
    },
    _ui() { return this.getView().getModel("ui"); },

    // ---- user menu: session info, change password, sign out ----
    onUserMenu(e) {
      const s = this.getSession().getModel().getData();
      const sheet = new ActionSheet({
        title: this._ui().getProperty("/userName"), showCancelButton: true, placement: "Bottom",
        buttons: [
          new Button({ text: this.text("sessionInfo"), icon: "sap-icon://key", press: () => this.onSessionInfo() }),
          new Button({ text: this.text("changePassword"), icon: "sap-icon://locked", visible: !s.external && s.method !== "xsuaa",
                       press: () => this.onChangePassword() }),
          new Button({ text: this.text("signOut"), icon: "sap-icon://log", press: () => this.onLogout() })
        ],
        afterClose: () => sheet.destroy()
      });
      this.getView().addDependent(sheet);
      sheet.openBy(e.getSource());
    },
    onSessionInfo() {
      const s = this.getSession().getModel().getData();
      MessageBox.information(this.text("sessionDetails", [
        s.user.Username, s.tenant ? s.tenant.Slug : this.text("platform"), s.user.Role,
        this.text(s.method === "xsuaa" ? "authXsuaa" : "authLocal"), formatter.unixTime(s.expiresAt)]),
        { title: this.text("sessionInfo") });
    },
    onChangePassword() {
      const current = new Input({ type: "Password" });
      const next = new Input({ type: "Password" });
      const repeat = new Input({ type: "Password" });
      const msg = new MessageStrip({ type: "Error", visible: false, showIcon: true });
      const dlg = new Dialog({
        title: this.text("changePassword"), contentWidth: "24rem",
        content: [new VBox({ items: [msg,
          new Label({ text: this.text("currentPassword"), labelFor: current, required: true }), current,
          new Label({ text: this.text("newPasswordRequired"), labelFor: next, required: true }), next,
          new Label({ text: this.text("repeatPassword"), labelFor: repeat, required: true }), repeat
        ] }).addStyleClass("sapUiSmallMargin")],
        beginButton: new Button({ text: this.text("ok"), type: "Emphasized", press: async () => {
          const fail = (key, text) => { msg.setText(text || this.text(key)); msg.setVisible(true); };
          if (next.getValue().length < 8) return fail("passwordTooShort");
          if (next.getValue() !== repeat.getValue()) return fail("passwordMismatch");
          try {
            await this.getSession().changePassword(current.getValue(), next.getValue());
            dlg.close();
            MessageToast.show(this.text("passwordChanged"));
          } catch (err) { fail(null, err.message); }
        } }),
        endButton: new Button({ text: this.text("cancel"), press: () => dlg.close() }),
        afterClose: () => dlg.destroy()
      });
      this.getView().addDependent(dlg);
      dlg.open();
    },
    async onLogout() {
      await this.getSession().logout();
      try { sessionStorage.removeItem(WS_KEY); } catch (e) { /* ignore */ }
      window.location.replace(window.location.pathname); // fresh start: no data of the previous user stays in memory
    },

    // ---- workspaces ----
    async _loadWorkspaces() {
      const r = await this.api("GET", "Workspaces");
      if (!r) return;
      const list = (await r.json()).value;
      const ui = this._ui();
      ui.setProperty("/workspaces", list);
      ui.setProperty("/noWorkspace", list.length === 0);
      if (!list.length) return;
      const stored = sessionStorage.getItem(WS_KEY);
      this._selectWorkspace(list.some((w) => w.ID === stored) ? stored : list[0].ID);
    },
    onWorkspaceChange(e) { this._selectWorkspace(e.getParameter("selectedItem").getKey()); },
    _selectWorkspace(id) {
      const ui = this._ui();
      const ws = ui.getProperty("/workspaces").find((w) => w.ID === id);
      if (!ws) return;
      sessionStorage.setItem(WS_KEY, id);
      ui.setProperty("/workspaceId", id);
      ui.setProperty("/canWrite", ws.MyRole !== "viewer");
      ui.setProperty("/canManageMembers", ws.MyRole === "admin");
      this.byId("folderList").removeSelections(true);
      this._folderId = null;
      this._applyFilters();
      if (!this._resumed) { // lists start suspended: no data request before sign-in and workspace choice
        this._resumed = true;
        this.byId("folderList").getBinding("items").resume();
        this.byId("docTable").getBinding("items").resume();
      }
    },

    // ---- list state ----
    onFolderSelect(e) {
      this._folderId = e.getParameter("listItem").getBindingContext().getProperty("ID");
      this._applyFilters();
    },
    onShowAll() {
      this.byId("folderList").removeSelections(true);
      this._folderId = null;
      this._applyFilters();
    },
    // full-text search: OData $search (name, title and document content), ranked by relevance
    onSearch(e) {
      const q = (e.getParameter("query") || "").trim();
      const b = this.byId("docTable").getBinding("items");
      b.changeParameters({ $search: q || undefined });
      b.sort(q ? [] : new Sorter("ModifiedAt", true));
    },
    _applyFilters() {
      const ws = this._ui().getProperty("/workspaceId");
      this.byId("folderList").getBinding("items").filter([new Filter("WorkspaceID", FilterOperator.EQ, ws)]);
      const f = [new Filter("WorkspaceID", FilterOperator.EQ, ws)];
      if (this._folderId) f.push(new Filter("FolderID", FilterOperator.EQ, this._folderId));
      this.byId("docTable").getBinding("items").filter(f);
    },
    _refresh() {
      this.byId("docTable").getBinding("items").refresh();
      this.byId("folderList").getBinding("items").refresh();
    },
    _id(e) { return e.getSource().getBindingContext().getProperty("ID"); },
    _docName(e) { return e.getSource().getBindingContext().getProperty("Name"); },
    _wsId() { return this._ui().getProperty("/workspaceId"); },

    // ---- folders ----
    onNewFolder() {
      this._prompt("newFolder", [{ key: "Name", label: "name" }], async (v) => {
        if (await this.api("POST", "Folders", { WorkspaceID: this._wsId(), Name: v.Name })) this._refresh();
      });
    },
    onDeleteFolder() {
      const item = this.byId("folderList").getSelectedItem();
      if (!item) { MessageToast.show(this.text("selectFolderFirst")); return; }
      const ctx = item.getBindingContext();
      MessageBox.confirm(this.text("confirmDelete", [ctx.getProperty("Name")]), {
        onClose: async (a) => {
          if (a !== "OK") return;
          if (await this.api("DELETE", `Folders('${ctx.getProperty("ID")}')`)) { this.onShowAll(); this._refresh(); }
        }
      });
    },

    // ---- documents ----
    onNewDocument() {
      this._prompt("newDocument", [{ key: "Name", label: "name" }, { key: "Title", label: "title" }], async (v) => {
        if (await this.api("POST", "Documents", { WorkspaceID: this._wsId(), Name: v.Name, Title: v.Title, FolderID: this._folderId })) this._refresh();
      });
    },
    async onDownload(e) {
      const name = this._docName(e);
      const res = await this.api("GET", `Documents('${this._id(e)}')/$value`);
      if (!res) return;
      const url = URL.createObjectURL(await res.blob()); // header-authenticated, so no window.open
      const a = document.createElement("a");
      a.href = url; a.download = name; a.click();
      setTimeout(() => URL.revokeObjectURL(url), 10000);
    },
    onUpload(e) {
      const id = this._id(e);
      const input = document.createElement("input");
      input.type = "file";
      input.onchange = async () => {
        const file = input.files[0];
        if (file && await this.api("PUT", `Documents('${id}')/$value`, file, { "Content-Type": file.type || "application/octet-stream" })) this._refresh();
      };
      input.click();
    },
    async onPublish(e) { if (await this.api("POST", `Documents('${this._id(e)}')/ECM.Publish`)) this._refresh(); },
    async onArchive(e) { if (await this.api("POST", `Documents('${this._id(e)}')/ECM.Archive`)) this._refresh(); },
    onDeleteDoc(e) {
      const id = this._id(e);
      MessageBox.confirm(this.text("confirmDelete", [this._docName(e)]), {
        onClose: async (a) => { if (a === "OK" && await this.api("DELETE", `Documents('${id}')`)) this._refresh(); }
      });
    },
    async onReindex() {
      const r = await this.api("POST", "Reindex");
      if (r) MessageToast.show(this.text("reindexDone", [(await r.json()).value]));
    },

    // ---- management dialogs (one generic CRUD dialog) ----
    async onTenants() {
      this._crud({
        title: "tenants", entity: "Tenants",
        cols: [{ key: "Name", label: "name" }, { key: "Slug", label: "slug" }, { key: "Active", label: "active", bool: true }],
        create: async () => [{ key: "Name", label: "name" }, { key: "Slug", label: "slug" }],
        edit: (t) => [{ key: "Name", label: "name", value: t.Name }, { key: "Active", label: "active", type: "checkbox", value: t.Active }],
        remove: true
      });
    },
    onWorkspaces() {
      this._crud({
        title: "workspaces", entity: "Workspaces",
        cols: [{ key: "Name", label: "name" }, { key: "Description", label: "description" }],
        create: async () => [{ key: "Name", label: "name" }, { key: "Description", label: "description" }],
        edit: (w) => [{ key: "Name", label: "name", value: w.Name }, { key: "Description", label: "description", value: w.Description }],
        remove: true,
        changed: () => this._loadWorkspaces()
      });
    },
    onMembers() {
      const ws = this._wsId();
      this._crud({
        title: "members", entity: "Members", query: "?$filter=WorkspaceID eq '" + ws + "'",
        cols: [{ key: "Username", label: "username" }, { key: "Role", label: "role" }],
        create: async () => [{ key: "Username", label: "username" },
                             { key: "Role", label: "role", type: "select", options: ROLES, value: "viewer" }],
        beforeCreate: (v) => Object.assign({ WorkspaceID: ws }, v),
        edit: (m) => [{ key: "Role", label: "role", type: "select", options: ROLES, value: m.Role }],
        remove: true
      });
    },
    async onUsers() {
      const platform = this._ui().getProperty("/isPlatform");
      let tenants = [];
      const tmap = {};
      if (platform) {
        const r = await this.api("GET", "Tenants");
        if (!r) return;
        tenants = (await r.json()).value;
        tenants.forEach((t) => { tmap[t.ID] = t.Slug; });
      }
      const roleField = (v) => ({ key: "Role", label: "role", type: "select", options: ROLES, value: v });
      this._crud({
        title: "users", entity: "Users",
        cols: [{ key: "Username", label: "username" }, { key: "DisplayName", label: "displayName" },
               { key: "Role", label: "role" }, { key: "Active", label: "active", bool: true }]
          .concat(platform ? [{ key: "TenantID", label: "tenant", fmt: (id) => tmap[id] || this.text("platform") }] : []),
        create: async () => (platform ? [{ key: "TenantID", label: "tenant", type: "select",
            options: [{ key: "", text: this.text("platform") }].concat(tenants.map((t) => ({ key: t.ID, text: t.Slug }))) }] : [])
          .concat([{ key: "Username", label: "username" }, { key: "DisplayName", label: "displayName" },
                   { key: "Email", label: "email" }, { key: "Password", label: "password", type: "password" }, roleField("viewer")]),
        edit: (u) => [{ key: "DisplayName", label: "displayName", value: u.DisplayName }, { key: "Email", label: "email", value: u.Email },
                      roleField(u.Role), { key: "Active", label: "active", type: "checkbox", value: u.Active },
                      { key: "Password", label: "newPassword", type: "password" }],
        remove: true
      });
    },
    _crud(cfg) {
      const model = new JSONModel({ rows: [] });
      const load = async () => {
        const r = await this.api("GET", cfg.entity + (cfg.query || ""));
        if (r) model.setProperty("/rows", (await r.json()).value);
      };
      const done = () => { load(); if (cfg.changed) cfg.changed(); };
      const cell = (c) => c.bool ? new Text({ text: "{= ${" + c.key + "} ? '✓' : '–'}" })
        : new Text({ text: c.fmt ? { path: c.key, formatter: c.fmt } : "{" + c.key + "}" });
      const table = new Table({
        mode: "SingleSelectLeft",
        columns: cfg.cols.map((c) => new Column({ header: new Text({ text: this.text(c.label) }) })),
        items: { path: "/rows", template: new ColumnListItem({ cells: cfg.cols.map(cell) }) }
      });
      const selected = () => {
        const i = table.getSelectedItem();
        if (!i) MessageToast.show(this.text("selectRowFirst"));
        return i ? i.getBindingContext().getObject() : null;
      };
      const buttons = [];
      if (cfg.create) buttons.push(new Button({ icon: "sap-icon://add", text: this.text("new"), press: async () =>
        this._prompt(cfg.title, await cfg.create(), async (v) => {
          if (await this.api("POST", cfg.entity, cfg.beforeCreate ? cfg.beforeCreate(v) : v)) done();
        }) }));
      if (cfg.edit) buttons.push(new Button({ icon: "sap-icon://edit", text: this.text("edit"), press: () => {
        const row = selected();
        if (row) this._prompt(cfg.title, cfg.edit(row), async (v) => {
          if (await this.api("PATCH", `${cfg.entity}('${row.ID}')`, v)) done();
        });
      } }));
      if (cfg.remove) buttons.push(new Button({ icon: "sap-icon://delete", text: this.text("delete"), press: () => {
        const row = selected();
        if (row) MessageBox.confirm(this.text("confirmDelete", [row.Name || row.Username]), {
          onClose: async (a) => { if (a === "OK" && await this.api("DELETE", `${cfg.entity}('${row.ID}')`)) done(); }
        });
      } }));
      buttons.push(new Button({ text: this.text("close"), press: () => dlg.close() }));
      const dlg = new Dialog({
        title: this.text(cfg.title), contentWidth: "52rem", content: [table], buttons,
        afterClose: () => dlg.destroy()
      });
      dlg.setModel(model);
      this.getView().addDependent(dlg);
      dlg.open();
      load();
    },

    // ---- notifications ----
    _startNotificationPolling() {
      this._refreshUnread();
      if (this._pollTimer) return;
      const schedule = () => {
        // ~60-75 s with jitter, and only while the tab is visible: low load, no synchronised request waves
        this._pollTimer = setTimeout(async () => {
          if (document.visibilityState === "visible") await this._refreshUnread();
          schedule();
        }, 60000 + Math.random() * 15000);
      };
      schedule();
      document.addEventListener("visibilitychange", () => {
        if (document.visibilityState === "visible" && this.getSession().isAuthenticated()) this._refreshUnread();
      });
    },
    async _refreshUnread() {
      try {
        const r = await this.api("GET", "Notifications?$filter=Read eq false&$top=0&$count=true", null, null, true);
        if (r) this._ui().setProperty("/unread", (await r.json())["@odata.count"] || 0);
      } catch (e) { /* offline or restarting: the next round tries again */ }
    },
    async onNotifications(e) {
      const bell = e.getSource();
      const r = await this.api("GET", "Notifications?$orderby=CreatedAt desc&$top=50");
      if (!r) return;
      const items = (await r.json()).value.map((n) => Object.assign(n, {
        Text: this.text("notif." + n.Kind, [n.Actor, n.Subject, n.Detail]),
        When: new Date(n.CreatedAt).toLocaleString()
      }));
      const model = new JSONModel({ items });
      const drop = (id) => model.setProperty("/items", model.getProperty("/items").filter((x) => x.ID !== id));
      const pop = new Popover({
        title: this.text("notifications"), contentWidth: "26rem", contentHeight: "26rem", placement: "Bottom",
        content: [new NotificationList({
          noDataText: this.text("noNotifications"),
          items: { path: "/items", template: new NotificationListItem({
            title: "{Text}", authorName: "{Actor}", datetime: "{When}", unread: "{= !${Read}}", showCloseButton: true,
            press: (ev) => this._openNotification(ev.getSource().getBindingContext().getObject(), pop),
            close: async (ev) => {
              const n = ev.getSource().getBindingContext().getObject();
              if (await this.api("DELETE", `Notifications('${n.ID}')`)) { drop(n.ID); this._refreshUnread(); }
            }
          }) }
        })],
        endButton: new Button({ text: this.text("markAllRead"), press: async () => {
          if (await this.api("POST", "MarkAllNotificationsRead")) {
            model.setProperty("/items", model.getProperty("/items").map((x) => Object.assign(x, { Read: true })));
            this._refreshUnread();
          }
        } }),
        afterClose: () => pop.destroy()
      });
      pop.setModel(model);
      this.getView().addDependent(pop);
      pop.openBy(bell);
    },
    async _openNotification(n, pop) {
      pop.close();
      if (!n.Read) await this.api("PATCH", `Notifications('${n.ID}')`, { Read: true }, null, true);
      this._refreshUnread();
      if (n.WorkspaceID && this._ui().getProperty("/workspaces").some((w) => w.ID === n.WorkspaceID))
        this._selectWorkspace(n.WorkspaceID);
    },

    // ---- help (role-aware topics, texts live in i18n) ----
    onHelp() {
      const ui = this._ui();
      const topics = ["start", "documents", "search", "workspaces", "notifications"];
      if (ui.getProperty("/canAdminUsers")) topics.push("admin");
      if (ui.getProperty("/isPlatform")) topics.push("platform");
      const dlg = new Dialog({
        title: this.text("help"), contentWidth: "40rem",
        content: topics.map((t, i) => new Panel({
          headerText: this.text("help." + t + ".title"), expandable: true, expanded: i === 0,
          content: [new Text({ text: this.text("help." + t + ".text"), renderWhitespace: true }).addStyleClass("sapUiSmallMargin")]
        })),
        endButton: new Button({ text: this.text("close"), press: () => dlg.close() }),
        afterClose: () => dlg.destroy()
      });
      this.getView().addDependent(dlg);
      dlg.open();
    },

    // ---- helpers ----
    _field(f) {
      if (f.type === "select") {
        return new Select({
          selectedKey: f.value || "",
          items: f.options.map((o) => typeof o === "string" ? new Item({ key: o, text: o }) : new Item({ key: o.key, text: o.text }))
        });
      }
      if (f.type === "checkbox") return new CheckBox({ selected: !!f.value });
      return new Input({ type: f.type === "password" ? "Password" : "Text", value: f.value || "" });
    },
    _prompt(titleKey, fields, onOk) {
      const controls = fields.map((f) => this._field(f));
      const dlg = new Dialog({
        title: this.text(titleKey),
        content: [new VBox({
          items: fields.flatMap((f, i) => [new Label({ text: this.text(f.label), labelFor: controls[i] }), controls[i]])
        }).addStyleClass("sapUiSmallMargin")],
        beginButton: new Button({
          text: this.text("ok"), type: "Emphasized",
          press: () => {
            const v = {};
            fields.forEach((f, i) => {
              const c = controls[i];
              const val = c.isA("sap.m.Select") ? c.getSelectedKey() : c.isA("sap.m.CheckBox") ? c.getSelected() : c.getValue();
              if (f.type === "password") { if (val) v[f.key] = val; return; } // empty = unchanged
              v[f.key] = typeof val === "string" ? val.trim() : val;
            });
            dlg.close();
            onOk(v);
          }
        }),
        endButton: new Button({ text: this.text("cancel"), press: () => dlg.close() }),
        afterClose: () => dlg.destroy()
      });
      this.getView().addDependent(dlg);
      dlg.open();
    }
  });
});
