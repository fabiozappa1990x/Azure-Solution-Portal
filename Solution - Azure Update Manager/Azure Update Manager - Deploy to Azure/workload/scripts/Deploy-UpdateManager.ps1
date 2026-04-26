<#
.SYNOPSIS
    Deploya Azure Update Manager (Maintenance Configuration + Policy) tramite Bicep.

.DESCRIPTION
    Script di deployment per Azure Update Manager con Maintenance Configuration,
    finestra di manutenzione configurabile, policy di periodic assessment e
    auto-patching per VM Windows e Linux.

.PARAMETER SubscriptionId
    ID della sottoscrizione Azure.

.PARAMETER DeploymentName
    Nome base del deployment (prefisso per tutte le risorse).

.PARAMETER Location
    Regione Azure (es: westeurope, italynorth).

.PARAMETER MaintenanceStartDateTime
    Data/ora inizio finestra manutenzione UTC (formato: "2024-01-01 23:00").

.PARAMETER MaintenanceDuration
    Durata finestra manutenzione ISO 8601 (default: PT2H = 2 ore).

.PARAMETER MaintenanceTimeZone
    Timezone finestra manutenzione (default: "W. Europe Standard Time").

.PARAMETER RecurEvery
    Ricorrenza: Weekly o Monthly (default: Weekly).

.PARAMETER DayOfWeek
    Giorno settimana per manutenzione settimanale (default: Sunday).

.PARAMETER RebootSetting
    Comportamento reboot: IfRequired, Never, Always (default: IfRequired).

.PARAMETER OsType
    Tipo OS target: Windows, Linux, Both (default: Both).

.PARAMETER EnablePeriodicAssessmentPolicy
    Assegna policy Azure per assessment periodico aggiornamenti (default: true).

.PARAMETER EnableAutoPatchingPolicy
    Assegna policy Azure per auto-patching tramite Maintenance Config (default: true).

.PARAMETER LogAnalyticsWorkspaceId
    Resource ID workspace Log Analytics per diagnostics Update Manager.

.PARAMETER UseExistingResourceGroup
    Usa un Resource Group esistente.

.PARAMETER UseExistingMaintenanceConfiguration
    Usa una Maintenance Configuration esistente invece di crearne una nuova.

.PARAMETER ExistingMaintenanceConfigurationId
    Resource ID della Maintenance Configuration esistente.

.EXAMPLE
    .\Deploy-UpdateManager.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" -DeploymentName "updates-prod"

.EXAMPLE
    .\Deploy-UpdateManager.ps1 `
        -SubscriptionId "00000000-0000-0000-0000-000000000000" `
        -DeploymentName "updates-prod" `
        -Location "italynorth" `
        -MaintenanceStartDateTime "2024-01-07 02:00" `
        -DayOfWeek "Saturday" `
        -OsType "Both"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$DeploymentName,

    [Parameter()]
    [string]$Location = 'westeurope',

    [Parameter()]
    [string]$MaintenanceStartDateTime = '2024-01-01 23:00',

    [Parameter()]
    [string]$MaintenanceDuration = 'PT2H',

    [Parameter()]
    [string]$MaintenanceTimeZone = 'W. Europe Standard Time',

    [Parameter()]
    [ValidateSet('Weekly', 'Monthly')]
    [string]$RecurEvery = 'Weekly',

    [Parameter()]
    [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
    [string]$DayOfWeek = 'Sunday',

    [Parameter()]
    [ValidateSet('IfRequired', 'Never', 'Always')]
    [string]$RebootSetting = 'IfRequired',

    [Parameter()]
    [ValidateSet('Windows', 'Linux', 'Both')]
    [string]$OsType = 'Both',

    [Parameter()]
    [string[]]$WindowsClassifications = @('Critical', 'Security', 'UpdateRollup'),

    [Parameter()]
    [string[]]$LinuxClassifications = @('Critical', 'Security'),

    [Parameter()]
    [bool]$EnablePeriodicAssessmentPolicy = $true,

    [Parameter()]
    [bool]$EnableAutoPatchingPolicy = $true,

    [Parameter()]
    [string]$LogAnalyticsWorkspaceId = '',

    [Parameter()]
    [switch]$UseExistingResourceGroup,

    [Parameter()]
    [string]$ExistingResourceGroupName = '',

    [Parameter()]
    [switch]$UseExistingMaintenanceConfiguration,

    [Parameter()]
    [string]$ExistingMaintenanceConfigurationId = ''
)

$ErrorActionPreference = 'Stop'
$bicepFile = Join-Path $PSScriptRoot '..\bicep\deploy.bicep'

# ── Prerequisiti ──────────────────────────────────────────────────────────────

Write-Host "`n=== Azure Update Manager - Deployment Script ===" -ForegroundColor Cyan
Write-Host "Deployment Name  : $DeploymentName"
Write-Host "Location         : $Location"
Write-Host "Maintenance      : $MaintenanceStartDateTime ($RecurEvery - $DayOfWeek)"
Write-Host "Duration         : $MaintenanceDuration"
Write-Host "Timezone         : $MaintenanceTimeZone"
Write-Host "Reboot           : $RebootSetting"
Write-Host "OS Type          : $OsType"
Write-Host "Assessment Policy: $EnablePeriodicAssessmentPolicy"
Write-Host "AutoPatch Policy : $EnableAutoPatchingPolicy"
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

# Validazione Maintenance Config esistente
if ($UseExistingMaintenanceConfiguration -and [string]::IsNullOrEmpty($ExistingMaintenanceConfigurationId)) {
    $ExistingMaintenanceConfigurationId = Read-Host "Resource ID della Maintenance Configuration esistente"
}

# ── Parametri deployment ───────────────────────────────────────────────────────

$params = @{
    deploymentName                       = $DeploymentName
    location                             = $Location
    maintenanceStartDateTime             = $MaintenanceStartDateTime
    maintenanceDuration                  = $MaintenanceDuration
    maintenanceTimeZone                  = $MaintenanceTimeZone
    recurEvery                           = $RecurEvery
    dayOfWeek                            = $DayOfWeek
    rebootSetting                        = $RebootSetting
    osType                               = $OsType
    windowsClassifications               = $WindowsClassifications
    linuxClassifications                 = $LinuxClassifications
    enablePeriodicAssessmentPolicy       = $EnablePeriodicAssessmentPolicy
    enableAutoPatchingPolicy             = $EnableAutoPatchingPolicy
    logAnalyticsWorkspaceId              = $LogAnalyticsWorkspaceId
    useExistingResourceGroup             = $UseExistingResourceGroup.IsPresent
    existingResourceGroupName            = $ExistingResourceGroupName
    useExistingMaintenanceConfiguration  = $UseExistingMaintenanceConfiguration.IsPresent
    existingMaintenanceConfigurationId   = $ExistingMaintenanceConfigurationId
}

# ── Deploy ─────────────────────────────────────────────────────────────────────

Write-Host "`nAvvio deployment..." -ForegroundColor Yellow
$deploymentName_full = "updates-$DeploymentName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

$deployment = New-AzSubscriptionDeployment `
    -Name                    $deploymentName_full `
    -Location                $Location `
    -TemplateFile            $bicepFile `
    -TemplateParameterObject $params `
    -Verbose:$VerbosePreference

if ($deployment.ProvisioningState -eq 'Succeeded') {
    Write-Host "`n✅ Deployment completato con successo!" -ForegroundColor Green
    Write-Host ""
    Write-Host "=== OUTPUT ===" -ForegroundColor Cyan
    if ($deployment.Outputs.resourceGroupName) {
        Write-Host "Resource Group         : $($deployment.Outputs.resourceGroupName.Value)"
    }
    if ($deployment.Outputs.maintenanceConfigId) {
        Write-Host "Maintenance Config ID  : $($deployment.Outputs.maintenanceConfigId.Value)"
    }
    Write-Host ""
    Write-Host "=== PROSSIMI PASSI ===" -ForegroundColor Yellow
    Write-Host "1. Verifica la Maintenance Configuration su Azure Portal"
    Write-Host "2. Assegna le VM alla Maintenance Configuration (Configuration Assignments)"
    Write-Host "3. Imposta patch mode 'AutomaticByPlatform' sulle VM che vuoi gestire"
    Write-Host "4. Esegui un assessment manuale per vedere gli update pendenti"
    Write-Host "5. Verifica che le policy Azure siano in enforcement sulle VM target"
    Write-Host ""
    Write-Host "=== LINK UTILI ===" -ForegroundColor Cyan
    Write-Host "Update Manager   : https://portal.azure.com/#view/Microsoft_Azure_Automation/UpdateMgmtMenuBlade"
    Write-Host "Documentazione   : https://learn.microsoft.com/azure/update-manager/overview"
} else {
    Write-Warning "Deployment concluso con stato: $($deployment.ProvisioningState)"
    if ($deployment.ProvisioningState -eq 'Failed') {
        Write-Error "Deployment fallito. Verifica i dettagli nell'activity log di Azure."
    }
}
