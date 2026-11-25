# ECM – UML-Modell

Diagramme in Mermaid (GitHub, VS Code und GitLab rendern sie direkt). Stand: Version 2.0 (JWT, XSUAA, Clean Architecture).

## 1. Komponentendiagramm (Einsatz auf SAP BTP)

```mermaid
flowchart LR
    user([Browser<br/>OpenUI5 / Fiori 3])
    subgraph BTP["SAP BTP – Cloud Foundry"]
        ar["ecm-approuter<br/>@sap/approuter"]
        be["ecm-backend<br/>D / vibe.d 0.10.5"]
        uaa[("XSUAA<br/>ecm-uaa")]
    end
    store[("Datenträger<br/>Journale + Inhalte")]

    user -- "HTTPS, Session-Cookie" --> ar
    ar -- "OAuth2 / OIDC Login" --> uaa
    ar -- "/odata/* + XSUAA-JWT (forwardAuthToken)" --> be
    ar -- "statische Ressourcen" --> user
    be -- "verificationkey (VCAP_SERVICES)" -.-> uaa
    be --> store
```

Standalone/Container: Browser → nginx (oder `ECM_FRONTEND_DIR` im Backend) → Backend; Anmeldung über die Login-Seite mit eigenem JWT.

## 2. Schichten und Pakete (Backend)

```mermaid
flowchart TB
    subgraph presentation["presentation"]
        http["http<br/>AuthController · HealthController · security"]
        odata["odata<br/>ODataController · mapper · query · metadata"]
    end
    subgraph infrastructure["infrastructure"]
        sec["security<br/>JwtTokenService · XsuaaTokenValidator · Pbkdf2PasswordHasher · crypto"]
        cfg["configuration<br/>AppConfig · configloader"]
        mon["monitoring · logging"]
        cli["clients<br/>UuidGenerator · UtcClock · DefaultTextExtractor"]
        wrk["workers<br/>ThreadPoolExecutor"]
    end
    subgraph persistence["persistence"]
        repo["repositories<br/>Journaled*Repository"]
        stor["storages<br/>FileContentStore · InMemorySearchIndex · InMemoryTokenRevocationStore"]
    end
    subgraph ports["ports"]
        puc["usecases (treibend)"]
        pdr["repositories · storages · services · messaging (getrieben)"]
    end
    subgraph application["application"]
        uc["usecases<br/>DocumentService · AuthService · TenancyService · NotificationService"]
        as["services<br/>AccessPolicy"]
        dto["dtos"]
    end
    domain["domain<br/>entities · types · enumerations · services · exceptions"]
    comp["composition.d<br/>(Composition Root)"]

    presentation --> puc
    uc -. implementiert .-> puc
    uc --> pdr
    sec -. implementiert .-> pdr
    cli -. implementiert .-> pdr
    wrk -. implementiert .-> pdr
    repo -. implementiert .-> pdr
    stor -. implementiert .-> pdr
    application --> domain
    ports --> domain
    comp --> presentation & infrastructure & persistence & application
```

## 3. Klassendiagramm – Domain

```mermaid
classDiagram
    class Tenant {
        +string id
        +string name
        +string slug
        +bool active
        +SysTime createdAt
    }
    class Workspace {
        +string id
        +string tenantId
        +string name
        +string description
    }
    class Membership {
        +string id
        +string workspaceId
        +string tenantId
        +string userId
        +Role role
    }
    class User {
        +string id; +string tenantId; +string username; +string displayName
        +string email; +string passwordHash; +Role role; +bool active
    }
    class Folder {
        +string id
        +string workspaceId
        +string parentId
        +string name
    }
    class Document {
        +string id; +string tenantId; +string workspaceId; +string folderId
        +string name; +string title; +string mimeType; +long size; +int revision
        +DocumentStatus status
        +replaceContent(size, mime, now)
        +publish(now)
        +archive(now)
        +ensureMutable()
    }
    class Notification {
        +string userId
        +string kind
        +string actor
        +string subject
        +bool read
    }
    class Principal {
        <<value object>>
        +string userId; +string username; +string tenantId; +Role role
        +isPlatformAdmin() bool
        +isTenantAdmin() bool
    }
    class Role {
        <<enumeration>>
        viewer
        editor
        admin
    }
    class DocumentStatus {
        <<enumeration>>
        Draft
        Published
        Archived
    }

    Tenant "1" --> "*" Workspace
    Tenant "1" --> "*" User
    Workspace "1" --> "*" Membership
    User "1" --> "*" Membership
    Workspace "1" --> "*" Folder
    Workspace "1" --> "*" Document
    Folder "0..1" --> "*" Document
    Folder "0..1" --> "*" Folder : parent
    User "1" --> "*" Notification
    User ..> Role
    Membership ..> Role
    Document ..> DocumentStatus
    Principal ..> Role
```

## 4. Klassendiagramm – Authentifizierung (Ports und Adapter)

```mermaid
classDiagram
    direction LR
    class AuthUseCases {
        <<interface>>
        +login(tenantSlug, username, password) LoginResult
        +authenticate(bearerToken) Authentication
        +refresh(Authentication) LoginResult
        +logout(Authentication)
        +session(Authentication) SessionInfo
        +changePassword(Principal, PasswordChange)
        +listUsers() / createUser() / updateUser() / deleteUser()
    }
    class AuthService {
        -AuthSettings settings
        -mapExternal(ExternalIdentity) User
        -issueFor(User) LoginResult
    }
    class AuthSettings {
        +AuthMode mode
        +long tokenTtlSeconds
        +string defaultTenantSlug
        +bool autoProvision
    }
    class AuthMode {
        <<enumeration>>
        local
        xsuaa
        hybrid
    }
    class TokenService {
        <<interface>>
        +issue(Principal, iat, exp) IssuedToken
        +verify(token, out TokenClaims) bool
    }
    class ExternalTokenValidator {
        <<interface>>
        +validate(token) Nullable~ExternalIdentity~
    }
    class TokenRevocationStore {
        <<interface>>
        +revoke(jti, exp)
        +isRevoked(jti) bool
    }
    class PasswordHasher {
        <<interface>>
        +hash(pw) string
        +verify(pw, stored) bool
    }
    class JwtTokenService {
        HS256
        iss/aud/exp/nbf/jti
        kid-Rotation
    }
    class XsuaaTokenValidator {
        RS256
        verificationkey
        Scopes
    }
    class InMemoryTokenRevocationStore
    class Pbkdf2PasswordHasher {
        OpenSSL PKCS5_PBKDF2_HMAC
    }
    class AuthController {
        POST login/refresh/logout/password
        GET me/config
    }
    class LoginResult {
        +accessToken
        +tokenType
        +expiresAt
        +expiresIn
        +SessionInfo session
    }
    class Authentication {
        +Principal principal
        +AuthMethod method
        +tokenId
        +expiresAt
    }

    AuthService ..|> AuthUseCases
    AuthService --> TokenService
    AuthService --> ExternalTokenValidator
    AuthService --> TokenRevocationStore
    AuthService --> PasswordHasher
    AuthService --> UserRepository
    AuthService --> TenantRepository
    AuthService --> AuthSettings
    AuthSettings --> AuthMode
    JwtTokenService ..|> TokenService
    XsuaaTokenValidator ..|> ExternalTokenValidator
    InMemoryTokenRevocationStore ..|> TokenRevocationStore
    Pbkdf2PasswordHasher ..|> PasswordHasher
    AuthController --> AuthUseCases
    AuthUseCases ..> LoginResult
    AuthUseCases ..> Authentication
```

## 5. Klassendiagramm – Frontend

```mermaid
classDiagram
    class Component {
        +session: Session
        +ready: Promise
        +init()
    }
    class Session {
        -token; -csrf; -timer
        +restore() Promise~bool~
        +login(tenant, user, pw) Promise
        +refresh() Promise~bool~
        +logout() Promise
        +changePassword(cur, new) Promise
        +api(method, path, body) Promise~Response~
        +request(method, url, body) Promise~Response~
        +setODataModel(model)
        +decodeJwt(token)$
    }
    class BaseController {
        +getRouter()
        +getSession()
        +text(key)
        +api(...)
    }
    class AppController
    class LoginController {
        +onSignIn()
        +onSso()
        +onTogglePassword()
    }
    class MainController {
        +onUserMenu()
        +onChangePassword()
        +onLogout()
        Dokumente, Ordner, Verwaltung, Benachrichtigungen
    }
    class formatter {
        <<module>>
        state()
        size()
        date()
        unixTime()
    }
    class ODataModel {
        <<sap.ui.model.odata.v4>>
    }

    Component *-- Session
    Session --> ODataModel : Authorization-Header
    BaseController <|-- AppController
    BaseController <|-- LoginController
    BaseController <|-- MainController
    BaseController --> Session
    MainController ..> formatter
```

## 6. Sequenz – Login mit Passwort (lokales JWT)

```mermaid
sequenceDiagram
    actor U as Benutzer
    participant L as Login.controller
    participant S as Session (model/session.js)
    participant AC as AuthController
    participant AS as AuthService
    participant H as Pbkdf2PasswordHasher
    participant T as JwtTokenService

    U->>L: Mandant, Benutzer, Passwort
    L->>S: login(tenant, user, pw)
    S->>AC: POST /odata/auth/login
    AC->>AC: Login-Slot belegen (max. N gleichzeitig, sonst 503)
    AC->>AS: login(slug, user, pw)
    AS->>H: verify(pw, hash)
    H-->>AS: ok
    AS->>T: issue(Principal, iat, exp)
    T-->>AS: JWT (HS256, jti)
    AS-->>AC: LoginResult
    AC-->>S: 200 {access_token, token_type, expires_in, user, tenant}
    S->>S: sessionStorage, OData-Header, Refresh-Timer
    L->>L: navTo("main")
```

## 7. Sequenz – Anfrage mit JWT, Refresh und Logout

```mermaid
sequenceDiagram
    participant S as Session
    participant OC as ODataController
    participant AS as AuthService
    participant T as JwtTokenService
    participant R as TokenRevocationStore
    participant UR as UserRepository
    participant DS as DocumentService

    S->>OC: GET /odata/v4/ecm/Documents (Bearer JWT)
    OC->>AS: authenticate(token)
    AS->>T: verify (alg, Signatur, iss, aud, exp, nbf)
    AS->>R: isRevoked(jti)?
    AS->>UR: find(sub) – aktiv? Rolle aktuell?
    AS-->>OC: Authentication(Principal)
    OC->>DS: listDocuments(Principal, Filter)
    DS-->>OC: Dokumente (nur zugängliche Arbeitsbereiche)
    OC-->>S: 200 OData-Antwort

    Note over S: 5 min vor exp, nur bei Benutzeraktivität
    S->>AS: POST /odata/auth/refresh
    AS->>R: revoke(alter jti)
    AS->>T: issue(...)
    AS-->>S: neues JWT

    S->>AS: POST /odata/auth/logout
    AS->>R: revoke(jti)
    AS-->>S: 204
```

## 8. Sequenz – Single Sign-on über Approuter (XSUAA)

```mermaid
sequenceDiagram
    actor U as Benutzer
    participant AR as Approuter
    participant UAA as XSUAA
    participant S as Session
    participant AS as AuthService
    participant X as XsuaaTokenValidator
    participant UR as UserRepository

    U->>AR: GET /index.html
    AR->>UAA: Redirect (Authorization Code)
    UAA-->>AR: JWT (RS256, scope, zid, ext_attr.zdn)
    AR-->>U: App + Session-Cookie
    S->>AR: GET /odata/auth/me (ohne eigenes Token)
    AR->>AS: + Authorization: Bearer <XSUAA-JWT>
    AS->>X: validate(token)
    X-->>AS: ExternalIdentity(userName, subdomain, scopes)
    AS->>UR: byLogin(tenant(subdomain), userName)
    alt unbekannt und autoProvision
        AS->>UR: save(neuer User, Rolle aus Scopes)
    end
    AS-->>S: Sitzung (authMethod = xsuaa)
```

## 9. Zustandsdiagramm – Dokument

```mermaid
stateDiagram-v2
    [*] --> Draft : createDocument
    Draft --> Draft : uploadContent (revision++)
    Draft --> Published : publish (size > 0)
    Published --> Published : uploadContent
    Draft --> Archived : archive
    Published --> Archived : archive
    Archived --> [*] : deleteDocument
    Draft --> [*] : deleteDocument
    Published --> [*] : deleteDocument
    note right of Archived : schreibgeschützt (ensureMutable)
```

## 10. Zustandsdiagramm – Sitzung (Frontend)

```mermaid
stateDiagram-v2
    [*] --> Restoring : Component.init
    Restoring --> SignedIn : gespeichertes JWT gültig / Approuter-Token
    Restoring --> SignedOut : kein gültiges Token
    SignedOut --> SignedIn : login()
    SignedIn --> SignedIn : refresh() bei Aktivität
    SignedIn --> SignedOut : 401 / Ablauf ohne Aktivität
    SignedIn --> SignedOut : logout() (Token gesperrt)
```
