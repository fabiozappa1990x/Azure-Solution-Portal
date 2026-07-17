# Azure Solution Portal

Portale web self-service + Infrastructure-as-Code (Bicep) per il deployment rapido e l'assessment di soluzioni Azure e Microsoft 365 enterprise.

Un utente con un tenant vuoto apre il portale, verifica i prerequisiti dal browser, esegue un **precheck**/**assessment** read-only e lancia il **deploy** delle soluzioni con un click ("Deploy to Azure") o via script PowerShell.

---

## Indice

- [Architettura](#architettura)
- [Struttura del repository](#struttura-del-repository)
- [Soluzioni disponibili](#soluzioni-disponibili)
- [Componenti](#componenti)
  - [Frontend](#frontend)
  - [Function App (backend)](#function-app-backend)
- [Setup & Deploy](#setup--deploy)
- [Pattern di una soluzione](#pattern-di-una-soluzione)
- [CI/CD](#cicd)
- [Convenzioni](#convenzioni)

---

## Architettura

```
┌─────────────────┐     HTTPS      ┌──────────────────────┐     Az REST / Graph
│  Static Web App │ ─────────────▶ │   Azure Function     │ ──────────────────▶  Azure ARM
│  (Frontend)     │   Bearer JWT   │   (PowerShell 7.4)   │                      Microsoft Graph
│  MSAL / Azure AD│ ◀───────────── │   precheck / assess  │ ◀──────────────────  Log Analytics
└─────────────────┘   JSON report  └──────────────────────┘
        │                                     │
        │ "Deploy to Azure"                   │ Managed Identity /
        ▼                                     ▼ delegated token
   Azure Portal (createUiDefinition + deploy.json)
```

- **Frontend**: Static Web App (HTML/JS/CSS vanilla) con autenticazione MSAL su Azure AD. Nessun framework.
- **Backend**: Azure Function App PowerShell 7.4 (piano Premium EP1). Un endpoint HTTP per soluzione che esegue analisi read-only e ritorna un report JSON.
- **IaC**: ogni soluzione "deployabile" porta un template Bicep compilato in `deploy.json` + `createUiDefinition.json` per il pulsante *Deploy to Azure*.

---

## Struttura del repository

```
.
├── Azure Solution Portal/
│   ├── Frontend/            # Static Web App: setup.html (entry), index.html (portale), script.js, setup.js, styles.css
│   ├── FunctionApp/         # Azure Functions PowerShell (un endpoint per soluzione)
│   │   ├── <endpoint>/      # function.json + run.ps1 per ogni funzione HTTP
│   │   ├── scripts/         # logica di analisi condivisa (precheck-*.ps1, assess-*.ps1)
│   │   ├── modules/         # moduli PowerShell interni (es. M365-Assess)
│   │   ├── host.json        # config host (timeout, CORS, extension bundle)
│   │   └── requirements.psd1# moduli Az / Microsoft.Graph gestiti
│   └── scripts/             # utility
├── Solution - <Nome>/       # una cartella per soluzione (IaC + docs + script)
├── .github/workflows/       # CI/CD (compile-bicep, deploy-functionapp, deploy-frontend)
└── Bootstrap.ps1            # setup one-shot: crea RG + Storage + FunctionApp + AppReg + secrets + push
```

Ogni **soluzione deployabile** segue la struttura standard:

```
Solution - <Nome>/
  <Nome> - Deploy to Azure/
    README.md
    docs/                 # quick-start.md, deployment-guide.md
    portal-ui/            # createUiDefinition.json, deploy.json (compilato dalla CI)
    workload/
      bicep/              # deploy.bicep + modules/
      scripts/            # Deploy-<Nome>.ps1
```

Le **soluzioni di solo assessment** (M365/Entra/Azure posture) non hanno IaC di deploy: portano lo script di analisi e sono servite via endpoint della Function App.

---

## Soluzioni disponibili

| Soluzione | Tipo | Endpoint precheck/assess | Deploy IaC |
|-----------|------|--------------------------|:----------:|
| Azure Monitor Hub | Deploy + Precheck | `/api/precheck`, `/api/precheck-monitor-v2` | ✅ |
| Azure Virtual Desktop | Deploy + Precheck | `/api/precheck-avd` | ✅ |
| Azure Backup | Deploy + Precheck | `/api/precheck-backup` | ✅ |
| Microsoft Defender for Cloud | Deploy + Precheck | `/api/precheck-defender` | ✅ |
| Azure Update Manager | Deploy + Precheck | `/api/precheck-updates` | ✅ |
| Microsoft Intune | Assessment + Baseline | `/api/precheck-intune` | — |
| Microsoft Defender for Endpoint | Assessment + Baseline | `/api/precheck-defender-xdr` | — |
| Conditional Access Baseline | Assessment + Baseline | client-side (Graph) | — |
| Assessment 365 (M365-Assess) | Assessment | `/api/execute-assessment-365` | — |
| Assessment Security M365 + Azure | Assessment | `/api/precheck-assessment-security` | — |
| **Azure Posture Assessment (WAF/CAF)** | Assessment | `/api/assess-azure-posture` | — |
| **Azure Cost Optimization** | Assessment | `/api/assess-azure-cost` | — |
| **Entra ID Identity Assessment** | Assessment | `/api/assess-entra-identity` | — |

---

## Componenti

### Frontend

- **Entry point**: `setup.html` + `setup.js` — wizard prerequisiti (7 check: MSAL, login, subscription, function app, CORS, endpoint, Azure OpenAI).
- **Portale**: `index.html` + `script.js` — catalogo soluzioni con modali *Dettagli / Precheck / Deploy*.
- `staticwebapp.config.json`: `/` → rewrite su `setup.html`.
- Config runtime in testa a `script.js`: `API_BASE_URL`, `GITHUB_RAW`, `clientId`.

### Function App (backend)

- PowerShell 7.4, piano **Premium EP1** (nessun limite 10 min: `functionTimeout` = 1h).
- Un endpoint HTTP per soluzione (`<endpoint>/function.json` + `run.ps1`); logica in `scripts/`.
- CORS gestito sia in `host.json` sia negli header di risposta.
- Assessment 365 usa il pattern **async**: `queue-assessment-365` (enqueue) → worker → `get-assessment-result` (polling) per evitare il timeout del load balancer a 230s.
- Autenticazione: token delegato Azure AD (Bearer) inoltrato dal frontend; alcune analisi usano la Managed Identity della Function.

---

## Setup & Deploy

Provisioning completo su un tenant nuovo con un solo script:

```powershell
./Bootstrap.ps1
```

Esegue: check prerequisiti (`az`, `gh`, `git`) → `az login` → crea Resource Group, Storage Account, Function App → configura CORS → App Registration (SPA redirect + permesso Management API) → aggiorna i file di config del frontend → imposta il secret GitHub `AZURE_FUNCTIONAPP_PUBLISH_PROFILE` → commit & push (la CI deploya la Function). Infine stampa le istruzioni per creare la Static Web App dal portale.

---

## Pattern di una soluzione

Per aggiungere una nuova soluzione mantieni la **separazione** delle esistenti:

1. **Backend** — crea `FunctionApp/<endpoint>/function.json` + `run.ps1` (sottile: CORS, auth, chiama lo script) e la logica in `FunctionApp/scripts/<nome>.ps1` (read-only, ritorna JSON con `summary` + `findings`/`recommendations`).
2. **Frontend** — aggiungi una voce in `SOLUTIONS` (`script.js`) con `apiEndpoint`, testi *Dettagli/Precheck/Deploy* e (se assessment) una funzione di render dedicata.
3. **IaC** (solo se deployabile) — crea `Solution - <Nome>/<Nome> - Deploy to Azure/` con `workload/bicep`, `portal-ui`, `docs`.
4. **Docs** — aggiungi la sezione in `Frontend/documentation.html`.

---

## CI/CD

| Workflow | Trigger | Azione |
|----------|---------|--------|
| `compile-bicep.yml` | push su `**/deploy.bicep` | Compila Bicep → `deploy.json` (commit automatico) |
| `deploy-functionapp.yml` | push su `Azure Solution Portal/FunctionApp/**` | Deploya la Function App |
| `deploy-frontend.yml` | push su `Azure Solution Portal/Frontend/**` | Deploya la Static Web App (skippa se il secret non è impostato) |

---

## Convenzioni

- **Lingua**: italiano per UI e documentazione.
- **Stile**: enterprise, pulito; seguire i pattern esistenti (qualità > quantità).
- **Sicurezza**: gli assessment sono **read-only**; i deploy CA/Intune partono in *Report-Only*/audit. `local.settings.json` e i log non vengono mai committati (vedi `.gitignore`).
- **Naming risorse**: suffisso di 8 char derivato dal `subscriptionId`.
