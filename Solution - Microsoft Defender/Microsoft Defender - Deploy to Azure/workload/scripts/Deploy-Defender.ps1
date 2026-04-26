<#
.SYNOPSIS
    Deploya Microsoft Defender for Cloud tramite Bicep.

.DESCRIPTION
    Script di deployment per Microsoft Defender for Cloud con attivazione dei piani
    Defender (Servers, Storage, KeyVault, ARM, CSPM), security contacts, auto-provisioning
    MDE/AMA e Azure Security Benchmark policy.

.PARAMETER SubscriptionId
    ID della sottoscrizione Azure.

.PARAMETER DeploymentName
    Nome base del deployment.

.PARAMETER EmailRecipients
    Indirizzi email security contact (separati da punto e virgola).

.PARAMETER EnableDefenderForServers
    Abilita Defender for Servers (default: true).

.PARAMETER ServersSubPlan
    Sub-plan Servers: P1 o P2 (default: P2 con MDE integrato).

.PARAMETER EnableDefenderForStorage
    Abilita Defender for Storage (default: true).

.PARAMETER EnableDefenderForKeyVault
    Abilita Defender for Key Vault (default: true).

.PARAMETER EnableDefenderForARM
    Abilita Defender for Resource Manager (default: true).

.PARAMETER EnableDefenderForContainers
    Abilita Defender for Containers (default: false).

.PARAMETER EnableCSPM
    Abilita Defender CSPM (Cloud Security Posture Management, default: true).

.PARAMETER EnableMDEAutoProvisioning
    Abilita auto-provisioning Microsoft Defender for Endpoint (default: true).

.PARAMETER EnableAMAAutoProvisioning
    Abilita auto-provisioning Azure Monitor Agent via Defender (default: true).

.PARAMETER AssignSecurityBenchmark
    Assegna l'iniziativa Azure Security Benchmark (default: true).

.EXAMPLE
    .\Deploy-Defender.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" -DeploymentName "defender-prod" -EmailRecipients "security@contoso.com"

.EXAMPLE
    .\Deploy-Defender.ps1 `
        -SubscriptionId "00000000-0000-0000-0000-000000000000" `
        -DeploymentName "defender-prod" `
        -EmailRecipients "security@contoso.com;ciso@contoso.com" `
        -ServersSubPlan "P2" `
        -EnableCSPM $true
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$DeploymentName,

    [Parameter(Mandatory)]
    [string]$EmailRecipients,

    [Parameter()]
    [string]$Location = 'westeurope',

    [Parameter()]
    [bool]$EnableDefenderForServers = $true,

    [Parameter()]
    [ValidateSet('Standard', 'Free')]
    [string]$ServersPlanTier = 'Standard',

    [Parameter()]
    [ValidateSet('P1', 'P2')]
    [string]$ServersSubPlan = 'P2',

    [Parameter()]
    [bool]$EnableDefenderForSqlVm = $true,

    [Parameter()]
    [bool]$EnableDefenderForStorage = $true,

    [Parameter()]
    [bool]$EnableDefenderForKeyVault = $true,

    [Parameter()]
    [bool]$EnableDefenderForARM = $true,

    [Parameter()]
    [bool]$EnableDefenderForDns = $false,

    [Parameter()]
    [bool]$EnableDefenderForAppService = $false,

    [Parameter()]
    [bool]$EnableDefenderForContainers = $false,

    [Parameter()]
    [bool]$EnableCSPM = $true,

    [Parameter()]
    [string]$Phone = '',

    [Parameter()]
    [bool]$AlertNotificationsMediumSeverity = $true,

    [Parameter()]
    [bool]$NotifySubscriptionOwners = $true,

    [Parameter()]
    [bool]$EnableMDEAutoProvisioning = $true,

    [Parameter()]
    [bool]$EnableAMAAutoProvisioning = $true,

    [Parameter()]
    [bool]$AssignSecurityBenchmark = $true,

    [Parameter()]
    [ValidateSet('Default', 'DoNotEnforce')]
    [string]$SecurityBenchmarkEnforcementMode = 'DoNotEnforce'
)

$ErrorActionPreference = 'Stop'
$bicepFile = Join-Path $PSScriptRoot '..\bicep\deploy.bicep'

# ── Prerequisiti ──────────────────────────────────────────────────────────────

Write-Host "`n=== Microsoft Defender for Cloud - Deployment Script ===" -ForegroundColor Cyan
Write-Host "Deployment Name  : $DeploymentName"
Write-Host "Email Recipients : $EmailRecipients"
Write-Host "Servers Plan     : $ServersPlanTier ($ServersSubPlan)"
Write-Host "CSPM             : $EnableCSPM"
Write-Host "MDE AutoProv     : $EnableMDEAutoProvisioning"
Write-Host "AMA AutoProv     : $EnableAMAAutoProvisioning"
Write-Host "Security Bench.  : $AssignSecurityBenchmark ($SecurityBenchmarkEnforcementMode)"
Write-Host ""

if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) {
    Write-Error "Bicep CLI non trovato. Installa con: winget install Microsoft.Bicep"
}

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Error "Modulo Az.Accounts non trovato. Esegui: Install-Module -Name Az -Scope CurrentUser"
}

# ── Connessione ───────────────────────────────────────────────────────────────

Write-Host "Connessione ad Azure..." -ForegroundColor Yellow
$context = Get-AzContext
if (-not $context -or $context.Subscription.Id -ne $SubscriptionId) {
    Connect-AzAccount -Subscription $SubscriptionId
} else {
    Set-AzContext -Subscription $SubscriptionId | Out-Null
    Write-Host "  Già connesso a: $($context.Account.Id)" -ForegroundColor Green
}

# ── Parametri deployment ───────────────────────────────────────────────────────

$params = @{
    deploymentName                      = $DeploymentName
    location                            = $Location
    enableDefenderForServers            = $EnableDefenderForServers
    serversPlanTier                     = $ServersPlanTier
    serversSubPlan                      = $ServersSubPlan
    enableDefenderForSqlVm              = $EnableDefenderForSqlVm
    enableDefenderForStorage            = $EnableDefenderForStorage
    enableDefenderForKeyVault           = $EnableDefenderForKeyVault
    enableDefenderForARM                = $EnableDefenderForARM
    enableDefenderForDns                = $EnableDefenderForDns
    enableDefenderForAppService         = $EnableDefenderForAppService
    enableDefenderForContainers         = $EnableDefenderForContainers
    enableCSPM                          = $EnableCSPM
    emailRecipients                     = $EmailRecipients
    phone                               = $Phone
    alertNotificationsMediumSeverity    = $AlertNotificationsMediumSeverity
    notifySubscriptionOwners            = $NotifySubscriptionOwners
    enableMDEAutoProvisioning           = $EnableMDEAutoProvisioning
    enableAMAAutoProvisioning           = $EnableAMAAutoProvisioning
    assignSecurityBenchmark             = $AssignSecurityBenchmark
    securityBenchmarkEnforcementMode    = $SecurityBenchmarkEnforcementMode
}

# ── Deploy ─────────────────────────────────────────────────────────────────────

Write-Host "`nAvvio deployment..." -ForegroundColor Yellow
$deploymentName_full = "defender-$DeploymentName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

$deployment = New-AzSubscriptionDeployment `
    -Name                    $deploymentName_full `
    -Location                $Location `
    -TemplateFile            $bicepFile `
    -TemplateParameterObject $params `
    -Verbose:$VerbosePreference

if ($deployment.ProvisioningState -eq 'Succeeded') {
    Write-Host "`n✅ Deployment completato con successo!" -ForegroundColor Green
    Write-Host ""
    Write-Host "=== PROSSIMI PASSI ===" -ForegroundColor Yellow
    Write-Host "1. Verifica i piani Defender attivi: https://portal.azure.com/#view/Microsoft_Azure_Security/SecurityMenuBlade/~/Environment"
    Write-Host "2. Controlla il Secure Score: https://portal.azure.com/#view/Microsoft_Azure_Security/SecurityMenuBlade/~/SecureScore"
    Write-Host "3. Esamina le raccomandazioni High severity e assegna owner per ogni remediation"
    Write-Host "4. Verifica che MDE sia installato sulle VM (auto-provisioning attivato)"
    Write-Host "5. Configura alert/SIEM per notifiche sicurezza (Sentinel o Logic App)"
    Write-Host ""
    Write-Host "=== LINK UTILI ===" -ForegroundColor Cyan
    Write-Host "Defender Portal  : https://portal.azure.com/#view/Microsoft_Azure_Security"
    Write-Host "Documentazione   : https://learn.microsoft.com/azure/defender-for-cloud/defender-for-cloud-introduction"
} else {
    Write-Warning "Deployment concluso con stato: $($deployment.ProvisioningState)"
    if ($deployment.ProvisioningState -eq 'Failed') {
        Write-Error "Deployment fallito. Verifica i dettagli nell'activity log di Azure."
    }
}
