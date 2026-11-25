# ECM – Enterprise Content Management (vibe.d + SAP Fiori 3 / OpenUI5)

Mandantenfähiges Dokumentenmanagement: D-Backend (vibe.d 0.10.5, OData v4, hexagonale / Clean Architecture),
OpenUI5-Frontend im Fiori-3-Design mit Login-Seite und **JWT**-Sitzungen, SAP-Approuter für BTP/Cloud Foundry (XSUAA).

Weitere Dokumentation: [uml.md](uml.md) (Klassen-, Komponenten- und Sequenzdiagramme) · [nafv4.md](nafv4.md) (Architekturbeschreibung nach NAF v4)
· [approuter/readme.md](approuter/readme.md)

## Aufbau

```
mta.yaml                 MTA-Deskriptor: backend + frontend + approuter + XSUAA (mbt build -> cf deploy)
backend/                 D / vibe.d 0.10.5 / uim-framework 26.11.2
  config/default.json    Standardwerte (überschrieben durch ENV, dann VCAP_SERVICES)
  source/app.d           Einstieg: Konfiguration laden, Worker-Threads starten
  source/uim/ecm/
    composition.d        Composition Root – einzige Stelle, die alle Adapter kennt
    domain/              entities, types (Principal), enumerations (Role), services (Namensregeln), exceptions
    application/         usecases (Document-, Auth-, Tenancy-, NotificationService), services (AccessPolicy), dtos
    ports/               usecases (treibend), repositories, storages, services, messaging (getrieben)
    infrastructure/      security (JWT, XSUAA, PBKDF2), configuration, logging, monitoring, clients, workers
    persistence/         repositories (Journal), storages (Dateien, Suchindex, Token-Sperrliste)
    presentation/        http (Login/JWT, Health, Metrics), odata (OData v4, $metadata)
  tests/                 Integrationstests (Login, Refresh, Logout, XSUAA-Abbildung)
frontend/                OpenUI5 (sap_fiori_3): Component.js, manifest.json (Routing), view/, controller/,
                         model/ (session.js = JWT-Sitzung), i18n/ (en, de), localService/, test/ (QUnit, OPA5)
approuter/               @sap/approuter: XSUAA-Login, CSRF, Routing /odata -> Backend, statisches Frontend
deploy/                  compose.yaml, k8s/ecm.yaml, cloudfoundry/manifest.yml (Container-Variante ohne Approuter)
loadtest/k6.js           Lasttest
```

Abhängigkeiten zeigen nur nach innen: `presentation`/`persistence`/`infrastructure` → `ports` → `application` → `domain`.
Domain und Anwendungsfälle kennen weder vibe.d noch HTTP, JWT oder Dateien.

## Schnellstart (lokal)

```bash
cd backend
ECM_JWT_SECRET="$(openssl rand -base64 48)" \
ECM_ADMIN_PASSWORD=admin-pass-1 ECM_PLATFORM_ADMIN_PASSWORD=platform-pass-1 \
ECM_FRONTEND_DIR=../frontend dub run          # Backend + UI auf http://localhost:8080
dub test                                     # Unit- und Integrationstests

cd ../frontend && npm i && npm start          # alternativ: UI5-Tooling auf :8081, Proxy /odata -> :8080
npm test                                     # QUnit + OPA5 im Browser
```

Anmeldung: Mandant `default`, Benutzer `admin` (bzw. Mandant leer + `platform` für den Plattform-Admin).

## Login und JWT

| Endpunkt | Zweck |
|---|---|
| `POST /odata/auth/login` `{"Tenant","Username","Password"}` | prüft das Passwort und liefert `access_token` (JWT), `token_type: "Bearer"`, `expires_in`, Benutzer und Mandant |
| `POST /odata/auth/refresh` | neues Token für ein gültiges lokales Token; das alte wird gesperrt (einmalig verwendbar) |
| `POST /odata/auth/logout` | sperrt das vorgelegte Token (`204`) |
| `GET /odata/auth/me` | Sitzung: Benutzer, Mandant, Anmeldeart (`local`/`xsuaa`), Ablaufzeit |
| `POST /odata/auth/password` `{"CurrentPassword","NewPassword"}` | eigenes Passwort ändern |
| `GET /odata/auth/config` | welche Anmeldearten die Oberfläche anbieten soll (ohne Anmeldung) |

Alle übrigen Endpunkte außer `/healthz`, Service-Dokument und `$metadata` verlangen `Authorization: Bearer <JWT>`.

**Token (HS256)** – Header `{"alg":"HS256","typ":"JWT","kid":…}`, Claims `iss`, `aud`, `sub` (Benutzer-ID), `preferred_username`,
`tid` (Mandant, leer = Plattform), `role`, `iat`, `nbf`, `exp`, `jti`.
Die Prüfung ist streng: nur `HS256` (kein `none`, keine Algorithmus-Verwechslung), Signatur in konstanter Zeit, `iss`/`aud` müssen passen,
`exp`/`nbf` mit 30 s Toleranz, `jti` darf nicht gesperrt sein. Bei jeder Anfrage wird der Benutzer neu gelesen:
Deaktivierung, Rollenwechsel und deaktivierte Mandanten wirken sofort, auch auf bereits ausgestellte Tokens.

**Schlüsselrotation** – `ECM_JWT_SECRET` signiert; `ECM_JWT_PREVIOUS_SECRETS` (kommagetrennt) wird nur noch geprüft.
So bleiben Sitzungen beim Schlüsselwechsel gültig, bis sie ablaufen.

**Frontend** – eigene Login-Seite (Route `#/login`). Das Token liegt im `sessionStorage` (pro Tab, endet mit dem Tab), wird als
Bearer-Header gesendet (auch vom OData-V4-Modell) und 5 Minuten vor Ablauf erneuert – aber nur, wenn der Benutzer seit
der letzten Erneuerung aktiv war; inaktive Sitzungen laufen ab und führen zurück zur Anmeldung.
Ein `401` beendet die Sitzung sofort. Das Benutzermenü zeigt die Sitzung, ändert das Passwort und meldet ab (Token wird serverseitig gesperrt).

**XSUAA / Approuter (SAP BTP)** – `ECM_AUTH_MODE`:

| Modus | akzeptiert |
|---|---|
| `local` | nur eigene JWTs (Standard ohne XSUAA-Bindung) |
| `xsuaa` | nur XSUAA-JWTs (RS256) vom Approuter; Passwort-Login deaktiviert |
| `hybrid` | beides (Standard mit XSUAA-Bindung) |

XSUAA-Tokens werden mit dem `verificationkey` der Bindung (RS256, OpenSSL) geprüft, ebenso `exp`/`nbf` und Audience/Scopes.
Abbildung: Mandant = Subdomain des Subaccounts (sonst `ECM_XSUAA_DEFAULT_TENANT`), Rolle = höchster Scope
(`PlatformAdmin`, `Admin`, `Editor`, `Viewer`; ohne ECM-Scope `403`). Unbekannte Benutzer werden beim ersten Aufruf angelegt
(`ECM_XSUAA_AUTO_PROVISION`, Standard `true`); die Rolle folgt bei jeder Anfrage den Scopes.
Rollen-Collections: `ECM_Viewer`, `ECM_Editor`, `ECM_Admin`, `ECM_PlatformAdmin` (siehe `approuter/xs-security.json`).

**Grenzen** – Die Token-Sperrliste liegt im Speicher des (einzigen) Backend-Prozesses: Nach einem Neustart sind abgemeldete,
noch nicht abgelaufene Tokens wieder gültig; für mehrere Instanzen einen Redis-/SQL-Adapter hinter `TokenRevocationStore` ergänzen.
Ohne `ECM_JWT_SECRET` (≥ 32 Zeichen) wird pro Start ein Zufallsschlüssel erzeugt – alle Sitzungen enden dann beim Neustart.

## Konfiguration

Reihenfolge (später gewinnt): Standardwerte → `backend/config/default.json` (`ECM_CONFIG`) → Umgebungsvariablen → `VCAP_SERVICES`
(Bindung `xsuaa` sowie ein user-provided Service mit Tag `ecm-config`, dessen Credentials wie Umgebungsvariablen gelesen werden).

| Variable | Standard | Bedeutung |
|---|---|---|
| `PORT`, `ECM_BIND` | `8080`, `0.0.0.0` | HTTP-Listener |
| `ECM_DATA_DIR` | `./data` | Journale und Inhalte |
| `ECM_FRONTEND_DIR` | – | Frontend direkt vom Backend ausliefern (Standalone) |
| `ECM_AUTH_MODE` | `local` / `hybrid` | siehe oben |
| `ECM_JWT_SECRET` (alt: `ECM_TOKEN_SECRET`) | zufällig | HS256-Schlüssel, ≥ 32 Zeichen |
| `ECM_JWT_PREVIOUS_SECRETS` | – | ältere Schlüssel (Rotation) |
| `ECM_JWT_ISSUER`, `ECM_JWT_AUDIENCE` | `ecm`, `ecm-api` | `iss`/`aud` |
| `ECM_JWT_TTL_MINUTES` (alt: `ECM_TOKEN_TTL_MINUTES`) | `480` | Gültigkeit |
| `ECM_JWT_LEEWAY_SECONDS` | `30` | Uhrentoleranz |
| `ECM_XSUAA_XSAPPNAME`, `ECM_XSUAA_VERIFICATION_KEY` | aus `VCAP_SERVICES` | XSUAA lokal ohne Bindung |
| `ECM_XSUAA_AUTO_PROVISION`, `ECM_XSUAA_DEFAULT_TENANT` | `true`, `default` | Benutzerabbildung |
| `ECM_METRICS_TOKEN` | – | schützt `/metrics` (Bearer) |
| `ECM_WORKERS`, `ECM_INDEX_THREADS`, `ECM_JOURNAL_FLUSH_MS`, `ECM_MAX_CONCURRENT_LOGINS`, `ECM_MAX_UPLOAD_MB` | CPU-Kerne, 2, 200, Kerne/2, 50 | Leistung |
| `ECM_PLATFORM_ADMIN_USER/PASSWORD`, `ECM_ADMIN_USER/PASSWORD`, `ECM_DEFAULT_TENANT(_NAME)` | `platform`, `admin`, `default` | Erststart |
| `ECM_LOG_LEVEL` | `info` | `trace` … `error` |

## Betrieb

```bash
# Container
podman compose -f deploy/compose.yaml up --build     # UI: http://localhost:8080 (nginx -> Backend)
kubectl apply -f deploy/k8s/ecm.yaml                 # REGISTRY und Secret ecm-secrets/jwt-secret anpassen

# SAP BTP (Approuter + XSUAA)
mbt build && cf deploy mta_archives/uim-ecm_2.0.0.mtar
cf set-env ecm-backend ECM_JWT_SECRET '<zufällig, >= 32 Zeichen>' && cf restage ecm-backend
```

Persistenz: Journal-Dateien (JSONL) + Dateisystem unter `ECM_DATA_DIR` (Volume/PVC). Für mehrere Backend-Instanzen einen DB-Adapter
hinter den Repository-Ports, Objektspeicher hinter `ContentStore` und Redis hinter `TokenRevocationStore` ergänzen –
Domain und Anwendungsfälle bleiben unverändert. Daten früherer Versionen werden weiter gelesen; bestehende Passwort-Hashes bleiben gültig.

## OData
`/odata/v4/ecm/` · `$metadata` · `Folders`, `Documents` (CRUD) · `Documents('id')/$value` (GET/PUT Inhalt, gestreamt)
· Aktionen `Documents('id')/ECM.Publish` und `ECM.Archive`
· `$filter` (eq/ne/gt/ge/lt/le, contains/startswith/endswith, and), `$orderby`, `$top`, `$skip`, `$count`, `$search`
· `Tenants`, `Workspaces`, `Members`, `Users` (je nach Rolle; `Users.External` = über XSUAA angelegt) · unbound Action `Reindex` (Admins)
Kein `$batch`: das Frontend nutzt `groupId: "$direct"`.

## Mandanten, Arbeitsbereiche, Benutzer
```
Plattform ── Mandant (Tenant) ──┬─ Benutzer (gehören genau einem Mandanten)
                                └─ Arbeitsbereiche ── Ordner, Dokumente, Mitglieder (Benutzer + Rolle)
```
- **Plattform-Admin** (Benutzer ohne Mandant): legt Mandanten an, (de)aktiviert sie und erzeugt deren Administratoren. Er hat **keinen** Zugriff auf Inhalte.
- **Mandanten-Admin**: verwaltet Benutzer und Arbeitsbereiche seines Mandanten und ist in allen seinen Arbeitsbereichen Admin.
- **Arbeitsbereich-Admin**: verwaltet die Mitglieder seines Arbeitsbereichs. Rollen: `viewer` (lesen, suchen, laden), `editor` (zusätzlich ändern, hochladen, veröffentlichen, löschen), `admin`.
  Effektive Rolle = Minimum aus Konto-Rolle und Mitgliedsrolle.
- Jeder Mandant startet mit dem Arbeitsbereich „General“. Benutzernamen sind pro Mandant eindeutig; der Login braucht das Mandanten-Kürzel.
- Isolation: Alle Anwendungsfälle erhalten den `Principal` (aus dem JWT) und prüfen Mandant und Arbeitsbereich selbst (`AccessPolicy`); fremde Objekte erscheinen als „nicht gefunden“.
- Passwörter: PBKDF2-HMAC-SHA256 (OpenSSL) mit Salt, mindestens 8 Zeichen. Login-Fehlversuche werden um 500 ms verzögert; unbekannte Benutzer kosten
  gleich viel Rechenzeit wie bekannte. Der letzte aktive Admin je Mandant bzw. der Plattform kann nicht gelöscht, deaktiviert oder herabgestuft werden.
- Erster Start ohne Benutzer: Plattform-Admin und Standard-Mandant mit Admin; fehlende Passwörter werden erzeugt und einmalig ins Log geschrieben.

## Volltextsuche
- `GET /odata/v4/ecm/Documents?$search=vertrag%20kündigung` durchsucht Name (x3), Titel (x2) und Inhalt, alle Begriffe müssen vorkommen
  (der letzte auch als Präfix), Sortierung nach Relevanz; Treffer enthalten `SearchSnippet` und `SearchScore`. Mit `$filter` kombinierbar.
- Textextraktion: Text-/JSON-/CSV-/Markdown-/HTML-/XML-Dateien sowie DOCX, XLSX, PPTX und ODF. PDF/Scans werden (noch) nicht indiziert;
  dafür einen Adapter hinter `TextExtractor` ergänzen.
- Die Suche ist auf den eigenen Mandanten und die zugänglichen Arbeitsbereiche beschränkt.
- Der Index liegt im Speicher und wird beim Start aus den gespeicherten Dokumenten aufgebaut (`Reindex` baut ihn bei Bedarf neu auf).

## Skalierung für bis zu 10.000 gleichzeitige Benutzer
Annahme: 10.000 angemeldete Sitzungen, je eine Anfrage alle ~10 s (≈ 1.000 Anfragen/s in der Spitze, überwiegend Listen und Suche).
Die Werte sind Startpunkte und **nicht gemessen** – mit `loadtest/k6.js` gegen die eigene Umgebung prüfen.

| Maßnahme | Wirkung |
|---|---|
| Ein Event-Loop je Worker-Thread mit eigenem Listen-Socket (`SO_REUSEPORT`), `ECM_WORKERS` (Standard: CPU-Kerne) | alle Kerne werden genutzt; zehntausende Keep-Alive-Verbindungen sind günstig |
| Indizierte, thread-sichere Repositories (Reader/Writer-Lock), Änderungen per Journal write-behind (`ECM_JOURNAL_FLUSH_MS`, 200 ms) | keine Vollscans, kein Neuschreiben ganzer Dateien bei jeder Änderung |
| Berechtigungsprüfung per Index (O(1) für Mandanten-Admins) | Kosten pro Anfrage unabhängig von der Zahl der Arbeitsbereiche und Mitglieder |
| `$filter` auf `WorkspaceID`/`FolderID` wird in den Index gepusht; stabile Standardsortierung; Seiten max. 1000 mit `@odata.nextLink` | nur relevante Dokumente werden geladen, keine unbegrenzten Antworten |
| Suche: Treffer per Hash, Präfix per Binärsuche im Vokabular, Tokenisierung außerhalb des Locks | Suchkosten wachsen nicht mit dem gesamten Index |
| Textextraktion und Indexierung im Hintergrund (`ECM_INDEX_THREADS`); Reindex ist asynchron | Uploads und Änderungen blockieren keine Anfrage-Threads (Suche ist ggf. wenige Sekunden verzögert) |
| Upload/Download gestreamt (64-KiB-Blöcke, atomares Schreiben) | Speicherbedarf unabhängig von Dateigröße und Zahl paralleler Transfers |
| PBKDF2 über OpenSSL (`PKCS5_PBKDF2_HMAC`, assembler-optimiertes SHA-256); höchstens `ECM_MAX_CONCURRENT_LOGINS` Logins gleichzeitig, sonst `503` + `Retry-After` (UI wiederholt mit Jitter) | ein Anmeldesturm verdrängt keine normalen Anfragen |
| nginx: 16k Verbindungen je Worker, gzip, Keep-Alive; K8s: 3–10 Frontend-Pods per HPA, Backend 2–4 CPU, `/metrics` | Frontend skaliert horizontal, Betrieb ist messbar |

Außerdem behoben: Der automatische JSON-/Formular-Body-Parser von vibe.d ist abgeschaltet. Er hätte den Request-Body vor dem Handler verbraucht
(JSON-Anfragen wären leer angekommen) und große Uploads vollständig gepuffert.

**Grenzen**
- Es läuft genau **ein** Backend-Prozess (Single-Writer-Journal). Er nutzt alle Kerne, ist aber kein Hochverfügbarkeits-Cluster. Für mehrere Instanzen:
  SQL-Adapter hinter den Repository-Ports, Objektspeicher hinter `ContentStore`, externer Suchindex hinter `SearchIndex`.
- Bei einem Absturz können Änderungen der letzten Flush-Periode fehlen. Der Suchindex liegt im RAM (proportional zur indizierten Textmenge) und wird nach dem Start im Hintergrund neu aufgebaut.
- Dateizugriffe sind blockierendes I/O auf den Worker-Threads; Daten gehören auf schnellen lokalen Speicher (SSD/PVC) mit genug Page-Cache.
- `ECM_WORKERS` an das CPU-Limit anpassen, Datei-Deskriptor-Limit (`ulimit -n`) ≥ 65536 (in Compose gesetzt), `/metrics` nicht öffentlich exponieren.

## Hilfe und Benachrichtigungen
- **Hilfe**: Das Fragezeichen im Kopf öffnet eine rollenabhängige Hilfe (Erste Schritte, Dokumente, Suche, Arbeitsbereiche, Benachrichtigungen; Admins zusätzlich
  Administration bzw. Plattform). Die Texte stehen in `frontend/webapp/i18n/i18n.properties` (`help.*`); die Oberfläche ist bisher nur deutsch.
- **Benachrichtigungen** (nur in der Anwendung, keine E-Mail/Push): Die Glocke zeigt die Zahl ungelesener Meldungen. Ereignisse:

  | Ereignis | Empfänger |
  |---|---|
  | Dokument veröffentlicht / archiviert (`document.published`, `document.archived`) | alle Mitglieder des Arbeitsbereichs außer dem Auslöser |
  | Zum Arbeitsbereich hinzugefügt, Rolle geändert, entfernt (`workspace.member_added`, `workspace.role_changed`, `workspace.member_removed`) | der betroffene Benutzer |

- Gespeichert werden nur Art, Auslöser, Gegenstand und Detail; der Text entsteht in der Oberfläche (`notif.*` in den i18n-Dateien).
  Pro Benutzer bleiben die neuesten 200 Meldungen erhalten; beim Löschen eines Benutzers verschwinden seine Meldungen.
- Die Verteilung läuft im Hintergrund-Pool, belastet also die auslösende Anfrage nicht. Die Oberfläche fragt den Zähler etwa alle 60–75 s ab
  (mit Zufallsversatz, nur bei sichtbarem Tab): bei 10.000 Sitzungen rund 150 sehr günstige Anfragen pro Sekunde.
- OData: `Notifications` (nur eigene; `GET`, `PATCH {"Read": true}`, `DELETE`), z. B. `Notifications?$filter=Read eq false&$top=0&$count=true`
  für den Zähler. Aktion `POST /odata/v4/ecm/MarkAllNotificationsRead`. Plattform-Admins haben keine Meldungen.

## Änderungen in Version 2.0
- Struktur nach Clean Architecture unter `backend/source/uim/ecm/` (domain, application, ports, infrastructure, persistence, presentation) mit Composition Root.
- Eigenes HMAC-Token ersetzt durch standardkonforme **JWTs** (HS256, `kid`-Rotation) plus **Refresh**, **Logout mit Sperrliste**, **Passwortänderung**.
- **XSUAA**-Unterstützung (RS256) mit Approuter, `xs-security.json`, `mta.yaml`; Benutzer werden aus Scopes abgebildet und bei Bedarf angelegt.
- Typisierte Konfiguration (`config/default.json` → ENV → `VCAP_SERVICES`), optional geschützte Metriken, Security-Header, begrenzte Login-Bodies.
- PBKDF2 über OpenSSL (schneller bei gleicher Sicherheit), CSPRNG über OpenSSL.
- Behoben: Build mit vibe.d 0.10.5 (entfallene Server-Optionen, `runWorkerTaskDist`, Stream-Typen, `char[]`/`string`).
- Frontend: Root-Layout nach Fiori-Konvention, Router mit **Login-Seite**, Sitzungsmodell mit automatischer Erneuerung und CSRF-Token,
  Benutzermenü, Englisch + Deutsch, QUnit- und OPA5-Tests, lokale `$metadata`.
