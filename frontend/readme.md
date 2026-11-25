# ecm-frontend

SAP Fiori 3 / OpenUI5-Anwendung (`uim.ecm`). Struktur: `Component.js`, `manifest.json` (Routen `login`, `main`),
`view/`, `controller/`, `model/` (`session.js` = JWT-Sitzung, `formatter.js`, `models.js`), `i18n/` (en, de),
`localService/metadata.xml`, `test/` (QUnit, OPA5).

```bash
npm install
npm start        # http://localhost:8081, Proxy /odata -> http://localhost:8080
npm test         # Testsuite im Browser
```

Ohne Node: Backend mit `ECM_FRONTEND_DIR=../frontend` starten und `http://localhost:8080` öffnen.
