<#
.SYNOPSIS
    Azure Solution Portal — deploy one-click su un tenant/sottoscrizione cliente.

.DESCRIPTION
    Distribuisce l'INTERA suite cloud-native sull'Azure con cui esegui il login:
      - Resource Group
      - Storage Account (con static website per il frontend + queue/container per Assessment 365)
      - Azure OpenAI (risorsa dedicata) + deployment gpt-5-mini (per gli executive summary AI)
      - Function App (PowerShell 7.4, piano Consumption pay-per-use) con tutti gli endpoint
      - Frontend (portale) pubblicato sullo static website dello storage
      - CORS + app settings + wiring completo

    Read-only per il tenant target salvo la creazione delle risorse elencate.
    Idempotente: rilanciandolo aggiorna le risorse esistenti.

.NOTES
    Requisiti: Azure CLI (az) installata. Login interattivo al tenant del cliente.
    Lanciare da dentro il repo (la cartella "Move to Azure" deve stare nella root del progetto).
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = "azure-solution-portal",
    [string]$Location       = "westeurope",
    [string]$OpenAILocation = "swedencentral",
    [string]$SubscriptionId = "",
    [string]$Prefix         = "azsolportal",
    [string]$OpenAIModel    = "gpt-5-mini",
    [string]$OpenAIModelVersion = "2025-08-07",
    [switch]$SkipOpenAI
)

$ErrorActionPreference = 'Stop'
function Info($m){ Write-Host "  $m" -ForegroundColor Cyan }
function Ok($m){   Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Step($n,$m){ Write-Host "`n[$n] $m" -ForegroundColor White -BackgroundColor DarkBlue }

Write-Host @"

============================================================
   AZURE SOLUTION PORTAL  -  Deploy to Customer Azure
============================================================
"@ -ForegroundColor Cyan

# --- 0) Prerequisiti -------------------------------------------------
Step 0 "Verifica prerequisiti"
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI non trovata. Installa da https://aka.ms/installazurecli e rilancia."
}
Ok "Azure CLI presente"

# Percorsi del progetto (lo script vive in <repo>\Move to Azure)
$repoRoot     = Split-Path $PSScriptRoot -Parent
$functionSrc  = Join-Path $repoRoot "Azure Solution Portal\FunctionApp"
$frontendSrc  = Join-Path $repoRoot "Azure Solution Portal\Frontend"
if (-not (Test-Path (Join-Path $functionSrc 'host.json'))) { throw "FunctionApp non trovata in $functionSrc. Esegui lo script dalla cartella del repo." }
if (-not (Test-Path (Join-Path $frontendSrc 'setup.html'))) { throw "Frontend non trovato in $frontendSrc." }
Ok "Codice progetto individuato"

# --- 1) Login --------------------------------------------------------
Step 1 "Login Azure (tenant del cliente)"
$acct = az account show 2>$null | ConvertFrom-Json
if (-not $acct) { az login | Out-Null; $acct = az account show | ConvertFrom-Json }

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId
} else {
    $subs = az account list --query "[?state=='Enabled'].{name:name,id:id}" -o json | ConvertFrom-Json
    if ($subs.Count -gt 1) {
        Write-Host "`n  Sottoscrizioni disponibili:" -ForegroundColor Cyan
        for ($i=0; $i -lt $subs.Count; $i++) { Write-Host ("   [{0}] {1}  ({2})" -f $i, $subs[$i].name, $subs[$i].id) }
        $sel = Read-Host "  Seleziona il numero della sottoscrizione"
        $SubscriptionId = $subs[[int]$sel].id
        az account set --subscription $SubscriptionId
    } else {
        $SubscriptionId = $acct.id
    }
}
$acct = az account show | ConvertFrom-Json
Ok "Sottoscrizione: $($acct.name)  [$($acct.id)]"
Ok "Tenant: $($acct.tenantId)"

# Suffisso deterministico dai primi 8 char del subscriptionId (nomi globali unici)
$suffix  = ($acct.id -replace '[^0-9a-fA-F]','').Substring(0,8).ToLower()
$storage = ("st{0}{1}" -f $Prefix, $suffix); if ($storage.Length -gt 24) { $storage = $storage.Substring(0,24) }
$funcApp = ("func-{0}-{1}" -f $Prefix, $suffix)
$oaiName = ("oai-{0}-{1}" -f $Prefix, $suffix)
Info "RG: $ResourceGroup | Storage: $storage | Function: $funcApp | OpenAI: $oaiName"

# --- 2) Provider registration ---------------------------------------
Step 2 "Registrazione resource provider"
foreach ($p in @('Microsoft.Web','Microsoft.Storage','Microsoft.CognitiveServices')) {
    $state = az provider show -n $p --query registrationState -o tsv 2>$null
    if ($state -ne 'Registered') { Info "Registro $p ..."; az provider register -n $p | Out-Null }
}
Ok "Provider registrati"

# --- 3) Resource Group ----------------------------------------------
Step 3 "Resource Group"
az group create -n $ResourceGroup -l $Location | Out-Null
Ok "RG $ResourceGroup"

# --- 4) Storage + static website ------------------------------------
Step 4 "Storage Account + static website"
az storage account create -n $storage -g $ResourceGroup -l $Location --sku Standard_LRS --kind StorageV2 --allow-blob-public-access true | Out-Null
$skey = az storage account keys list -n $storage -g $ResourceGroup --query "[0].value" -o tsv
az storage blob service-properties update --account-name $storage --account-key $skey --static-website --index-document setup.html --404-document setup.html --auth-mode key | Out-Null
az storage queue create -n "m365assessment-jobs" --account-name $storage --account-key $skey | Out-Null
az storage container create -n "m365assessment-results" --account-name $storage --account-key $skey --public-access off | Out-Null
$webUrl = az storage account show -n $storage -g $ResourceGroup --query "primaryEndpoints.web" -o tsv
$portalOrigin = $webUrl.TrimEnd('/')
Ok "Static website: $webUrl"

# --- 4b) App Registration (login MSAL del portale) ------------------
Step "4b" "App Registration (Azure AD) per il login del portale"
$clientId = ""
try {
    $existing = az ad app list --display-name "Azure Solution Portal" --query "[0].appId" -o tsv 2>$null
    if ($existing) {
        $clientId = $existing
        Info "App Registration esistente riusata"
    } else {
        $clientId = az ad app create --display-name "Azure Solution Portal" --sign-in-audience AzureADMyOrg --query appId -o tsv
    }
    $objId = az ad app show --id $clientId --query id -o tsv
    # SPA redirect URIs = origin del portale + localhost (dev)
    $spaBody = (@{ spa = @{ redirectUris = @($portalOrigin, "http://localhost:8787") } } | ConvertTo-Json -Depth 5 -Compress)
    $spaTmp  = New-TemporaryFile; [System.IO.File]::WriteAllText($spaTmp, $spaBody)
    az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$objId" --headers "Content-Type=application/json" --body "@$spaTmp" 2>$null | Out-Null
    Remove-Item $spaTmp -Force -ErrorAction SilentlyContinue
    # Permessi delegati: Azure Service Management (user_impersonation) + Graph User.Read
    az ad app permission add --id $clientId --api 797f4846-ba00-4fd7-ba43-dac1f8f63013 --api-permissions "41094075-9dad-400e-a0bd-54e686782033=Scope" 2>$null | Out-Null
    az ad app permission add --id $clientId --api 00000003-0000-0000-c000-000000000000 --api-permissions "e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope" 2>$null | Out-Null
    Start-Sleep -Seconds 5
    az ad app permission admin-consent --id $clientId 2>$null | Out-Null
    Ok "App Registration: $clientId (SPA redirect + ARM/User.Read consentiti)"
    Warn "Gli scope Graph avanzati (Directory.Read.All, ecc.) richiedono admin-consent al primo utilizzo dei moduli Assessment/Intune."
} catch {
    Warn "App Registration non creata ($($_.Exception.Message)). Il portale richiedera' configurazione MSAL manuale."
}

# --- 5) Azure OpenAI (best-effort) ----------------------------------
$openAiEndpoint = ""; $openAiKey = ""; $openAiDeployment = $OpenAIModel
if (-not $SkipOpenAI) {
    Step 5 "Azure OpenAI + modello $OpenAIModel"
    try {
        az cognitiveservices account create -n $oaiName -g $ResourceGroup -l $OpenAILocation --kind OpenAI --sku S0 --custom-domain $oaiName --yes | Out-Null
        $deployed = $false
        foreach ($sku in @('GlobalStandard','Standard')) {
            try {
                az cognitiveservices account deployment create -n $oaiName -g $ResourceGroup `
                    --deployment-name $OpenAIModel --model-name $OpenAIModel --model-version $OpenAIModelVersion `
                    --model-format OpenAI --sku-name $sku --sku-capacity 10 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { $deployed = $true; Ok "Modello $OpenAIModel ($sku)"; break }
            } catch {}
        }
        if ($deployed) {
            $openAiEndpoint = az cognitiveservices account show -n $oaiName -g $ResourceGroup --query "properties.endpoint" -o tsv
            $openAiKey      = az cognitiveservices account keys list -n $oaiName -g $ResourceGroup --query "key1" -o tsv
        } else {
            Warn "Quota modello non disponibile in $OpenAILocation. Deploy senza AI (report generati senza executive summary AI). Configura AZURE_OPENAI_* manualmente in seguito."
        }
    } catch {
        Warn "OpenAI non creato ($($_.Exception.Message)). Deploy senza AI."
    }
} else {
    Step 5 "Azure OpenAI -> SALTATO (-SkipOpenAI)"
}

# --- 6) Function App -------------------------------------------------
Step 6 "Function App (PowerShell 7.4, Consumption)"
az functionapp create -n $funcApp -g $ResourceGroup --consumption-plan-location $Location `
    --storage-account $storage --runtime powershell --runtime-version 7.4 `
    --functions-version 4 --os-type Windows | Out-Null
az functionapp cors add -n $funcApp -g $ResourceGroup --allowed-origins "*" 2>$null | Out-Null
$settings = @()
if ($openAiEndpoint) {
    $settings += "AZURE_OPENAI_ENDPOINT=$openAiEndpoint"
    $settings += "AZURE_OPENAI_API_KEY=$openAiKey"
    $settings += "AZURE_OPENAI_DEPLOYMENT=$openAiDeployment"
    $settings += "AZURE_OPENAI_API_VERSION=2025-04-01-preview"
}
if ($settings.Count -gt 0) { az functionapp config appsettings set -n $funcApp -g $ResourceGroup --settings $settings | Out-Null }
$funcHost = "https://$funcApp.azurewebsites.net"
Ok "Function App: $funcHost"

# --- 7) Deploy backend ----------------------------------------------
Step 7 "Deploy backend (endpoint)"
$tmp   = Join-Path $env:TEMP ("asp_deploy_" + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $tmp "func"; $zip = Join-Path $tmp "func.zip"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Copy-Item -Path $functionSrc -Destination $stage -Recurse -Force
foreach ($x in @('local.settings.json','.vscode','bin','obj')) {
    $p = Join-Path $stage $x
    if (Test-Path $p) { if ((Get-Item $p) -is [System.IO.DirectoryInfo]) { [System.IO.Directory]::Delete($p,$true) } else { [System.IO.File]::Delete($p) } }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
az functionapp deployment source config-zip -n $funcApp -g $ResourceGroup --src $zip --timeout 600 | Out-Null
Ok "Backend deployato"

# --- 8) Deploy frontend ---------------------------------------------
Step 8 "Deploy frontend (portale)"
$feStage = Join-Path $tmp "frontend"
New-Item -ItemType Directory -Force -Path $feStage | Out-Null
foreach ($f in @('setup.html','index.html','documentation.html','script.js','setup.js','styles.css')) {
    $src = Join-Path $frontendSrc $f
    if (-not (Test-Path $src)) { continue }
    $c = Get-Content $src -Raw
    # Punta il frontend al Function App appena creato
    $c = $c -replace 'https://func-[a-z0-9-]+\.azurewebsites\.net', $funcHost
    # Sostituisci il Client ID MSAL con l'App Registration del cliente
    if ($clientId) { $c = $c -replace '4ace231a-ee3c-4bb8-aa9f-85105cecce6c', $clientId }
    [System.IO.File]::WriteAllText((Join-Path $feStage $f), $c)
}
az storage blob upload-batch --account-name $storage --account-key $skey -d '$web' -s $feStage --overwrite | Out-Null
Ok "Frontend pubblicato"

# --- 9) Fine ---------------------------------------------------------
try { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}

Write-Host @"

============================================================
   DEPLOY COMPLETATO
============================================================
"@ -ForegroundColor Green
Write-Host "   Portale (SaaS):   $webUrl" -ForegroundColor Green
Write-Host "   Backend (API):    $funcHost" -ForegroundColor Green
Write-Host "   AI (OpenAI):      $(if($openAiEndpoint){"$openAiDeployment @ $openAiEndpoint"}else{'non configurata'})" -ForegroundColor $(if($openAiEndpoint){'Green'}else{'Yellow'})
Write-Host "   Resource Group:   $ResourceGroup  (sub $($acct.name))" -ForegroundColor Green
Write-Host "`n   Apri il portale e completa il wizard prerequisiti (login Azure AD del cliente)." -ForegroundColor Cyan
Write-Host ""
