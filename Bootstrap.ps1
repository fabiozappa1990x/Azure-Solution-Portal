#Requires -Version 7.0
<#
.SYNOPSIS
    First-time setup for Azure Solution Portal (Azure Monitor Hub).

.DESCRIPTION
    Questo script va eseguito UNA VOLTA sola su un PC con az, gh e git installati.
    Crea tutte le risorse Azure necessarie e configura GitHub per il CI/CD automatico.

    Cosa fa:
      1. Login Azure + selezione subscription
      2. Crea Resource Group, Storage Account, Function App (PowerShell 7.4, Consumption)
      3. Configura CORS sulla Function App
      4. Crea App Registration Entra ID (SPA multi-tenant, permesso Azure Management)
      5. Aggiorna i file di config (setup.js, script.js, workflow deploy)
      6. Imposta GitHub secret AZURE_FUNCTIONAPP_PUBLISH_PROFILE
      7. Push su GitHub (triggera il deploy automatico)
      8. Mostra istruzioni per creare la Static Web App

.REQUIREMENTS
    - Azure CLI  : https://aka.ms/installazurecliwindows
    - GitHub CLI : https://cli.github.com/
    - Git        : https://git-scm.com/

.EXAMPLE
    .\Bootstrap.ps1
    .\Bootstrap.ps1 -Location "northeurope"
    .\Bootstrap.ps1 -ResourceGroupName "rg-mio-portale" -Location "italynorth"
#>

param(
    [string]$ResourceGroupName = '',
    [string]$Location          = 'westeurope',
    [string]$AppNamePrefix     = 'azsolportal',
    [string]$GitHubRepo        = 'fabiozappa1990x/Azure-Solution-Portal'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

function Write-Banner {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host "  ║        Azure Solution Portal — Bootstrap Setup           ║" -ForegroundColor Cyan
    Write-Host "  ║        Azure Monitor Hub / AVD / Backup / Defender       ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Header([string]$msg) {
    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
    Write-Host "  │  $($msg.PadRight(55))│" -ForegroundColor Cyan
    Write-Host "  └─────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
}

function Write-OK([string]$msg)   { Write-Host "  ✅ $msg" -ForegroundColor Green }
function Write-Step([string]$msg) { Write-Host "  → $msg" -ForegroundColor Yellow }
function Write-Info([string]$msg) { Write-Host "     $msg" -ForegroundColor Gray }
function Write-Warn([string]$msg) { Write-Host "  ⚠️  $msg" -ForegroundColor DarkYellow }
function Write-Err([string]$msg)  { Write-Host "  ❌ $msg" -ForegroundColor Red }

function Confirm-Action([string]$msg) {
    $ans = Read-Host "  $msg [S/n]"
    return ($ans -ne 'n' -and $ans -ne 'N')
}

# ─────────────────────────────────────────────────────────────────────────────
# BANNER
# ─────────────────────────────────────────────────────────────────────────────

Clear-Host
Write-Banner

Write-Host "  Questo script crea tutte le risorse Azure necessarie e configura" -ForegroundColor White
Write-Host "  GitHub per il deploy automatico. Eseguilo una volta sola." -ForegroundColor White
Write-Host ""

if (-not (Confirm-Action "Vuoi procedere con il setup?")) {
    Write-Host "  Operazione annullata." -ForegroundColor Gray
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 0: Verifica prerequisiti
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "STEP 1/10 — Verifica prerequisiti"

$missing = @()
foreach ($cmd in @('az', 'gh', 'git')) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) {
        Write-OK "$cmd trovato"
    } else {
        Write-Err "$cmd non trovato"
        $missing += $cmd
    }
}

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "  Installa i tool mancanti prima di continuare:" -ForegroundColor Red
    if ('az'  -in $missing) { Write-Info "→ Azure CLI  : https://aka.ms/installazurecliwindows" }
    if ('gh'  -in $missing) { Write-Info "→ GitHub CLI : https://cli.github.com/" }
    if ('git' -in $missing) { Write-Info "→ Git        : https://git-scm.com/" }
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Azure Login + selezione subscription
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "STEP 2/10 — Login Azure"

$accountJson = az account show 2>$null
if (-not $accountJson) {
    Write-Step "Apertura browser per login Azure..."
    az login | Out-Null
}

$account = az account show | ConvertFrom-Json
Write-OK "Connesso come: $($account.user.name)"

# Lista subscription
$subs = az account list --output json | ConvertFrom-Json
if ($subs.Count -eq 0) {
    Write-Err "Nessuna subscription trovata. Verifica l'account Azure."
    exit 1
} elseif ($subs.Count -eq 1) {
    Write-OK "Subscription: $($subs[0].name) ($($subs[0].id))"
} else {
    Write-Host ""
    Write-Host "  Subscriptions disponibili:" -ForegroundColor White
    for ($i = 0; $i -lt $subs.Count; $i++) {
        $marker = if ($subs[$i].isDefault) { " ◄ default" } else { "" }
        Write-Host "  [$($i+1)] $($subs[$i].name) ($($subs[$i].id))$marker"
    }
    Write-Host ""
    $choice = Read-Host "  Seleziona subscription [1-$($subs.Count)]"
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $subs.Count) {
        Write-Err "Scelta non valida."
        exit 1
    }
    az account set --subscription $subs[$idx].id | Out-Null
    $account = az account show | ConvertFrom-Json
    Write-OK "Subscription selezionata: $($account.name)"
}

$subscriptionId = $account.id

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Nomi risorse
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "STEP 3/10 — Configurazione nomi risorse"

# Suffix univoco basato sui primi 8 caratteri del subscription ID
$suffix = ($subscriptionId -replace '-', '').Substring(0, 8).ToLower()

if (-not $ResourceGroupName) {
    $defaultRg = "rg-azure-solution-portal"
    $input = Read-Host "  Nome Resource Group [Invio per '$defaultRg']"
    $ResourceGroupName = if ($input.Trim()) { $input.Trim() } else { $defaultRg }
}

# Storage account: max 24 chars, solo lowercase alphanumeric
$rawStorageName     = "st$($AppNamePrefix)$suffix" -replace '[^a-z0-9]', ''
$storageAccountName = $rawStorageName.Substring(0, [Math]::Min(24, $rawStorageName.Length))

$functionAppName     = "func-$AppNamePrefix-$suffix"
$appRegDisplayName   = "Azure Solution Portal"

Write-Host ""
Write-Host "  Riepilogo risorse che verranno create:" -ForegroundColor White
Write-Info "Subscription    : $($account.name)"
Write-Info "Resource Group  : $ResourceGroupName  (region: $Location)"
Write-Info "Storage Account : $storageAccountName"
Write-Info "Function App    : $functionAppName"
Write-Info "App Registration: $appRegDisplayName"
Write-Host ""

if (-not (Confirm-Action "Confermi la creazione delle risorse?")) {
    Write-Host "  Operazione annullata." -ForegroundColor Gray
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: Resource Group
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "STEP 4/10 — Resource Group"

$rgExists = az group exists --name $ResourceGroupName
if ($rgExists -eq 'true') {
    Write-OK "Resource Group '$ResourceGroupName' già esistente — skip"
} else {
    Write-Step "Creazione Resource Group '$ResourceGroupName' in $Location..."
    az group create --name $ResourceGroupName --location $Location --output none
    Write-OK "Resource Group creato"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Storage Account
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "STEP 5/10 — Storage Account"

$stExists = az storage account show --name $storageAccountName --resource-group $ResourceGroupName --output none 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-OK "Storage Account '$storageAccountName' già esistente — skip"
} else {
    Write-Step "Creazione Storage Account '$storageAccountName'..."
    az storage account create `
        --name $storageAccountName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --sku Standard_LRS `
        --kind StorageV2 `
        --allow-blob-public-access false `
        --output none
    Write-OK "Storage Account creato"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: Function App
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "STEP 6/10 — Function App (PowerShell 7.4)"

$faExists = az functionapp show --name $functionAppName --resource-group $ResourceGroupName --output none 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-OK "Function App '$functionAppName' già esistente — skip"
} else {
    Write-Step "Creazione Function App '$functionAppName' (PowerShell 7.4, Consumption, Windows)..."
    Write-Info "Questa operazione può richiedere 1-2 minuti..."
    az functionapp create `
        --name $functionAppName `
        --resource-group $ResourceGroupName `
        --storage-account $storageAccountName `
        --consumption-plan-location $Location `
        --runtime powershell `
        --runtime-version 7.4 `
        --functions-version 4 `
        --os-type Windows `
        --output none
    Write-OK "Function App creata"
}

$functionAppUrl = "https://$functionAppName.azurewebsites.net"
Write-Info "URL: $functionAppUrl"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: CORS
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "STEP 6b — CORS Function App"

Write-Step "Configurazione CORS wildcard (*) sulla Function App..."
az functionapp cors add `
    --name $functionAppName `
    --resource-group $ResourceGroupName `
    --allowed-origins '*' `
    --output none
Write-OK "CORS configurato: allowed-origins = *"

# Abilita Basic Auth SCM (necessario per deploy con publish profile da GitHub Actions)
Write-Step "Abilitazione Basic Auth SCM (richiesto da GitHub Actions deploy)..."
az resource update `
    --resource-group $ResourceGroupName `
    --name "$functionAppName/basicPublishingCredentialsPolicies/scm" `
    --resource-type "Microsoft.Web/sites/basicPublishingCredentialsPolicies" `
    --set properties.allow=true `
    --output none 2>$null
az resource update `
    --resource-group $ResourceGroupName `
    --name "$functionAppName/basicPublishingCredentialsPolicies/ftp" `
    --resource-type "Microsoft.Web/sites/basicPublishingCredentialsPolicies" `
    --set properties.allow=true `
    --output none 2>$null
Write-OK "Basic Auth abilitato per SCM e FTP"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6c: Azure OpenAI
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "STEP 6c — Azure OpenAI (per analisi AI precheck)"

$openAiName       = $null
$openAiEndpoint   = $null
$openAiKey        = $null
$openAiDeployment = 'AVM'

# Prova region: westeurope, poi eastus come fallback
$openAiRegions = @('westeurope', 'eastus', 'swedencentral')

# Cerca se esiste già un'istanza OpenAI nel resource group
$existingOai = az cognitiveservices account list --resource-group $ResourceGroupName --query "[?kind=='OpenAI'].name" -o tsv 2>$null
if ($existingOai) {
    $openAiName = $existingOai.Trim()
    Write-OK "Azure OpenAI '$openAiName' già esistente nel resource group — skip creazione"
} else {
    $openAiName = "oai-$AppNamePrefix-$suffix"
    $openAiCreated = $false

    foreach ($region in $openAiRegions) {
        Write-Step "Tentativo creazione Azure OpenAI in '$region'..."
        az cognitiveservices account create `
            --name $openAiName `
            --resource-group $ResourceGroupName `
            --kind OpenAI `
            --sku S0 `
            --location $region `
            --yes `
            --output none 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Azure OpenAI creato in '$region'"
            $openAiCreated = $true
            break
        } else {
            Write-Warn "Region '$region' non disponibile, provo la prossima..."
        }
    }

    if (-not $openAiCreated) {
        Write-Warn "Impossibile creare Azure OpenAI automaticamente (capacity o accesso non disponibile nella region)."
        Write-Info "Puoi crearlo manualmente da Azure Portal e aggiornare le credenziali nei precheck scripts."
        Write-Info "Continuo con la configurazione degli altri componenti..."
        $openAiName = $null
    }
}

# Se l'istanza esiste, crea il deployment e ottieni le credenziali
if ($openAiName) {
    # Ottieni endpoint
    $openAiEndpoint = az cognitiveservices account show `
        --name $openAiName `
        --resource-group $ResourceGroupName `
        --query "properties.endpoint" -o tsv 2>$null

    # Ottieni API key
    $openAiKey = az cognitiveservices account keys list `
        --name $openAiName `
        --resource-group $ResourceGroupName `
        --query "key1" -o tsv 2>$null

    # Crea/verifica deployment del modello 'AVM'
    $deployExists = az cognitiveservices account deployment show `
        --name $openAiName `
        --resource-group $ResourceGroupName `
        --deployment-name $openAiDeployment `
        --output none 2>$null

    if ($LASTEXITCODE -ne 0) {
        Write-Step "Creazione deployment modello gpt-4o-mini (deployment name: '$openAiDeployment')..."
        az cognitiveservices account deployment create `
            --name $openAiName `
            --resource-group $ResourceGroupName `
            --deployment-name $openAiDeployment `
            --model-name 'gpt-4o-mini' `
            --model-version '2024-07-18' `
            --model-format OpenAI `
            --sku-capacity 1 `
            --sku-name GlobalStandard `
            --output none 2>$null

        if ($LASTEXITCODE -eq 0) {
            Write-OK "Deployment '$openAiDeployment' creato"
        } else {
            Write-Warn "Deployment automatico non riuscito — potrebbe richiedere capacità manuale."
            Write-Info "Crea manualmente il deployment 'AVM' con modello gpt-4o-mini da Azure Portal."
        }
    } else {
        Write-OK "Deployment '$openAiDeployment' già esistente — skip"
    }

    Write-OK "Azure OpenAI configurato"
    Write-Info "Endpoint: $openAiEndpoint"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7: App Registration
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "STEP 7/10 — App Registration (Entra ID)"

$clientId       = $null
$appObjectId    = $null

# Cerca se esiste già
$existingAppJson = az ad app list --display-name $appRegDisplayName --query "[0]" --output json 2>$null
if ($existingAppJson -and $existingAppJson -ne 'null') {
    $existingApp = $existingAppJson | ConvertFrom-Json
    $clientId    = $existingApp.appId
    $appObjectId = $existingApp.id
    Write-OK "App Registration '$appRegDisplayName' già esistente — skip"
    Write-Info "Client ID: $clientId"
} else {
    Write-Step "Creazione App Registration '$appRegDisplayName' (multi-tenant SPA)..."

    $appJson = az ad app create `
        --display-name $appRegDisplayName `
        --sign-in-audience AzureADandPersonalMicrosoftAccount `
        --query "{appId:appId, id:id}" `
        --output json | ConvertFrom-Json

    $clientId    = $appJson.appId
    $appObjectId = $appJson.id
    Write-OK "App Registration creata"
    Write-Info "Client ID: $clientId"

    # Configura SPA redirect URIs via Graph API (az ad app update non gestisce il tipo SPA)
    Write-Step "Configurazione redirect URI SPA (localhost + placeholder SWA)..."
    $spaBody = '{"spa":{"redirectUris":["http://localhost:8787","http://localhost:3000"]}}'
    az rest `
        --method PATCH `
        --uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" `
        --body $spaBody `
        --headers "Content-Type=application/json" `
        --output none
    Write-OK "Redirect URI configurati: localhost:8787, localhost:3000"

    # Aggiungi permesso Azure Management API (user_impersonation)
    # Resource: Azure Service Management (797f4846-ba00-4fd7-ba43-dac1f8f63013)
    # Scope:    user_impersonation (41094075-9dad-400e-a0bd-54e686782033)
    Write-Step "Aggiunta permesso Azure Management API (user_impersonation)..."
    $permBody = '{"requiredResourceAccess":[{"resourceAppId":"797f4846-ba00-4fd7-ba43-dac1f8f63013","resourceAccess":[{"id":"41094075-9dad-400e-a0bd-54e686782033","type":"Scope"}]}]}'
    az rest `
        --method PATCH `
        --uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" `
        --body $permBody `
        --headers "Content-Type=application/json" `
        --output none
    Write-OK "Permesso Azure Management API aggiunto"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8: Aggiorna file di configurazione
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "STEP 8/10 — Aggiornamento file di configurazione"

$scriptDir    = $PSScriptRoot
$setupJsPath  = Join-Path $scriptDir "Azure Solution Portal\Frontend\setup.js"
$scriptJsPath = Join-Path $scriptDir "Azure Solution Portal\Frontend\script.js"
$workflowPath = Join-Path $scriptDir ".github\workflows\deploy-functionapp.yml"

# ── setup.js ──────────────────────────────────────────────────
Write-Step "Aggiornamento setup.js (FUNCTION_APP_URL, CLIENT_ID, RESOURCE_GROUP_NAME)..."
$setupJs = Get-Content $setupJsPath -Raw -Encoding UTF8

$setupJs = $setupJs -replace "const FUNCTION_APP_URL\s+=\s+'.*?';",   "const FUNCTION_APP_URL   = '$functionAppUrl';"
$setupJs = $setupJs -replace "const CLIENT_ID\s+=\s+'[^']*';",         "const CLIENT_ID          = '$clientId';"
$setupJs = $setupJs -replace "const RESOURCE_GROUP_NAME\s+=\s+'.*?';", "const RESOURCE_GROUP_NAME = '$ResourceGroupName';"

Set-Content -Path $setupJsPath -Value $setupJs -Encoding UTF8 -NoNewline
Write-OK "setup.js aggiornato"

# ── script.js ─────────────────────────────────────────────────
Write-Step "Aggiornamento script.js (API_BASE_URL, clientId)..."
$scriptJs = Get-Content $scriptJsPath -Raw -Encoding UTF8

$scriptJs = $scriptJs -replace "const API_BASE_URL = '.*?';", "const API_BASE_URL = '$functionAppUrl';"
$scriptJs = $scriptJs -replace '(clientId:\s*")[^"]*(")', "`${1}$clientId`${2}"

Set-Content -Path $scriptJsPath -Value $scriptJs -Encoding UTF8 -NoNewline
Write-OK "script.js aggiornato"

# ── deploy-functionapp.yml ─────────────────────────────────────
Write-Step "Aggiornamento deploy-functionapp.yml (app-name)..."
$workflow = Get-Content $workflowPath -Raw -Encoding UTF8
$workflow = $workflow -replace 'app-name: [^\n]+', "app-name: $functionAppName"
Set-Content -Path $workflowPath -Value $workflow -Encoding UTF8 -NoNewline
Write-OK "deploy-functionapp.yml aggiornato"

# ── Precheck scripts (OpenAI credentials) ─────────────────────
if ($openAiEndpoint -and $openAiKey) {
    Write-Step "Aggiornamento credenziali Azure OpenAI nei precheck scripts..."
    $precheckScripts = @(
        Join-Path $scriptDir "Azure Solution Portal\FunctionApp\scripts\testluca.ps1"
        Join-Path $scriptDir "Azure Solution Portal\FunctionApp\scripts\precheck-avd.ps1"
        Join-Path $scriptDir "Azure Solution Portal\FunctionApp\scripts\precheck-backup.ps1"
        Join-Path $scriptDir "Azure Solution Portal\FunctionApp\scripts\precheck-defender.ps1"
        Join-Path $scriptDir "Azure Solution Portal\FunctionApp\scripts\precheck-updates.ps1"
    )

    # Costruisci il nuovo endpoint URL (stesso formato, deployment 'AVM')
    $newEndpoint = "$($openAiEndpoint.TrimEnd('/'))openai/deployments/$openAiDeployment/chat/completions?api-version=2025-01-01-preview"

    foreach ($scriptPath in $precheckScripts) {
        if (Test-Path $scriptPath) {
            $content = Get-Content $scriptPath -Raw -Encoding UTF8
            # Sostituisci endpoint (pattern: $endpoint = "https://...cognitiveservices.azure.com/...")
            $content = $content -replace '\$endpoint\s*=\s*"https://[^"]+cognitiveservices\.azure\.com[^"]*"', "`$endpoint = `"$newEndpoint`""
            # Sostituisci API key (pattern: $apiKey = "...")
            $content = $content -replace '\$apiKey\s*=\s*"[^"]{30,}"', "`$apiKey = `"$openAiKey`""
            Set-Content -Path $scriptPath -Value $content -Encoding UTF8 -NoNewline
            Write-OK "  $(Split-Path $scriptPath -Leaf) aggiornato"
        }
    }
} else {
    Write-Warn "OpenAI non configurato — i precheck scripts usano ancora le credenziali originali."
    Write-Info "Aggiorna manualmente \$endpoint e \$apiKey nei file FunctionApp/scripts/*.ps1"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9: GitHub secret (Publish Profile)
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "STEP 9/10 — GitHub Secrets"

# Verifica login GitHub CLI
$ghStatus = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Step "Apertura browser per login GitHub CLI..."
    gh auth login
}
Write-OK "GitHub CLI autenticato"

Write-Step "Ottenimento publish profile della Function App..."
$publishProfile = az functionapp deployment list-publishing-profiles `
    --name $functionAppName `
    --resource-group $ResourceGroupName `
    --xml

if (-not $publishProfile) {
    Write-Err "Impossibile ottenere il publish profile. Riprova manualmente."
    Write-Info "Comando: az functionapp deployment list-publishing-profiles --name $functionAppName --resource-group $ResourceGroupName --xml | gh secret set AZURE_FUNCTIONAPP_PUBLISH_PROFILE --repo $GitHubRepo"
} else {
    Write-Step "Impostazione secret AZURE_FUNCTIONAPP_PUBLISH_PROFILE su $GitHubRepo..."
    $publishProfile | gh secret set AZURE_FUNCTIONAPP_PUBLISH_PROFILE --repo $GitHubRepo
    Write-OK "Secret GitHub impostato"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10: Git commit + push
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "STEP 10/10 — Push su GitHub"

Set-Location $scriptDir

$gitStatus = git status --porcelain
if ($gitStatus) {
    Write-Step "Commit delle modifiche di configurazione..."
    git add "Azure Solution Portal/Frontend/setup.js"
    git add "Azure Solution Portal/Frontend/script.js"
    git add ".github/workflows/deploy-functionapp.yml"
    git add "Azure Solution Portal/FunctionApp/scripts/"
    git commit -m "bootstrap: configure resources - funcapp=$functionAppName clientId=$clientId"
    Write-OK "Commit creato"
}

Write-Step "Push su GitHub (triggera deploy automatico Function App)..."
git push
Write-OK "Push completato — GitHub Actions sta deployando la Function App"

# ─────────────────────────────────────────────────────────────────────────────
# RIEPILOGO FINALE
# ─────────────────────────────────────────────────────────────────────────────

$swaCreateUrl = "https://portal.azure.com/#create/Microsoft.StaticApp"

Write-Host ""
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║  ✅  SETUP COMPLETATO CON SUCCESSO!                         ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  ─── Risorse create ───────────────────────────────────────────" -ForegroundColor DarkGreen
Write-Host "  Client ID      : $clientId" -ForegroundColor White
Write-Host "  Function App   : $functionAppUrl" -ForegroundColor White
Write-Host "  Resource Group : $ResourceGroupName  ($Location)" -ForegroundColor White
Write-Host "  Storage Account: $storageAccountName" -ForegroundColor White
Write-Host ""
Write-Host "  ─── PROSSIMI PASSI (da fare manualmente) ─────────────────────" -ForegroundColor DarkYellow
Write-Host ""
Write-Host "  1️⃣   Crea la Static Web App su Azure Portal:" -ForegroundColor Yellow
Write-Host "       $swaCreateUrl" -ForegroundColor Cyan
Write-Host "       - Connetti a GitHub: $GitHubRepo  (branch: main)" -ForegroundColor Gray
Write-Host "       - App location: 'Azure Solution Portal/Frontend'" -ForegroundColor Gray
Write-Host "       - Output location: (lascia vuoto)" -ForegroundColor Gray
Write-Host "       - Azure imposta automaticamente AZURE_STATIC_WEB_APPS_API_TOKEN" -ForegroundColor Gray
Write-Host ""
Write-Host "  2️⃣   Aggiungi il dominio SWA come redirect URI nell'App Registration:" -ForegroundColor Yellow
Write-Host "       Azure Portal → Microsoft Entra ID → App registrations" -ForegroundColor Gray
Write-Host "       → '$appRegDisplayName' → Authentication → Add a platform → SPA" -ForegroundColor Gray
Write-Host "       → Inserisci: https://<nome-univoco>.azurestaticapps.net" -ForegroundColor Gray
Write-Host ""
Write-Host "  3️⃣   Visita setup.html per verificare tutti i prerequisiti:" -ForegroundColor Yellow
Write-Host "       https://<nome-univoco>.azurestaticapps.net/setup.html" -ForegroundColor Gray
Write-Host ""
Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGreen
Write-Host ""
Write-Host "  Il deploy della Function App è in corso su GitHub Actions." -ForegroundColor Gray
Write-Host "  Controlla: https://github.com/$GitHubRepo/actions" -ForegroundColor Cyan
Write-Host ""
