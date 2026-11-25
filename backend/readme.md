# ecm-backend

D / vibe.d 0.10.5 OData-v4-Backend, Clean Architecture unter `source/uim/ecm/` (Überblick: [../README.md](../README.md),
Modelle: [../uml.md](../uml.md)).

```bash
dub run                      # :8080, Konfiguration aus config/default.json + ENV (+ VCAP_SERVICES)
dub test                     # Unit-Tests aller Module + tests/authflow.d (Login, Refresh, Logout, XSUAA)
dub build -b release --compiler=ldc2
```

Einstieg für neue Adapter: Port in `source/uim/ecm/ports/` wählen, Implementierung unter `persistence/` oder
`infrastructure/` anlegen, in `source/uim/ecm/composition.d` verdrahten. Domain und Anwendungsfälle bleiben unverändert.
