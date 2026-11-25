# ECM approuter

Single entry point on SAP BTP / Cloud Foundry: XSUAA login, CSRF protection, static OpenUI5 app
(`resources/`, filled by the MTA build from `../frontend`) and forwarding of `/odata/*` to the
`ecm-backend` destination with the user's JWT (`forwardAuthToken`).

```
npm install
cp default-env.json default-env.json   # fill in the xsuaa service key (never commit it)
npm start                               # http://localhost:5000, backend on :8080 with ECM_AUTH_MODE=hybrid
```

Locally the backend needs the same XSUAA verification key, e.g.
`ECM_XSUAA_XSAPPNAME=... ECM_XSUAA_VERIFICATION_KEY="$(cat key.pem)" ECM_AUTH_MODE=hybrid dub run`.

Role collections `ECM_Viewer`, `ECM_Editor`, `ECM_Admin`, `ECM_PlatformAdmin` map to the ECM roles.
Users are created in the backend on their first request (tenant = subaccount subdomain, or
`ECM_XSUAA_DEFAULT_TENANT`).
