<#
.SYNOPSIS
    Deploya Azure Backup (Recovery Services Vault + Policy GFS) tramite Bicep.

.DESCRIPTION
    Script di deployment per Azure Backup con Recovery Services Vault,
    policy di backup GFS (Daily/Weekly/Monthly/Yearly), Enhanced Policy per
    backup orario, copertura VM e integrazione con Azure Monitor.

.PARAMETER SubscriptionId
    ID della sottoscrizione Azure.

.PARAMETER DeploymentName
    Nome base del deployment (prefisso per tutte le risorse).

.PARAMETER Location
    Regione Azure (es: westeurope, italynorth).

.PARAMETER StorageType
    Tipo ridondanza vault: GeoRedundant (default), LocallyRedundant, ZoneRedundant.

.PARAMETER EnableSoftDelete
    Abilita soft delete sul vault (protezione da eliminazioni accidentali).

.PARAMETER SoftDeleteRetentionDays
    Giorni di retention soft delete (default: 14).

.PARAMETER BackupTime
    Orario backup schedulato in UTC (default: 23:00).

.PARAMETER DailyRetentionDays
    Giorni retention backup giornaliero (default: 30).

.PARAMETER WeeklyRetentionWeeks
    Settimane retention backup settimanale (default: 12).

.PARAMETER MonthlyRetentionMonths
    Mesi retention backup mensile (default: 12).

.PARAMETER YearlyRetentionYears
    Anni retention backup annuale (default: 3).

.PARAMETER DeployEnhancedPolicy
    Deploya Enhanced Policy con backup orario (default: true).

.PARAMETER UseExistingResourceGroup
    Usa un Resource Group esistente invece di crearne uno nuovo.

.PARAMETER UseExistingVault
    Usa un Recovery Services Vault esistente invece di crearne uno nuovo.

.PARAMETER ExistingVaultResourceId
    Resource ID del vault esistente (richiesto se UseExistingVault = true).

.EXAMPLE
    .\Deploy-Backup.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" -DeploymentName "backup-prod"

.EXAMPLE
    .\Deploy-Backup.ps1 `
        -SubscriptionId "00000000-0000-0000-0000-000000000000" `
        -DeploymentName "backup-prod" `
        -Location "italynorth" `
        -StorageType "GeoRedundant" `
        -DailyRetentionDays 60 `
        -YearlyRetentionYears 7
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
    [ValidateSet('GeoRedundant', 'LocallyRedundant', 'ZoneRedundant')]
    [string]$StorageType = 'GeoRedundant',

    [Parameter()]
    [bool]$EnableSoftDelete = $true,

    [Parameter()]
    [ValidateRange(14, 180)]
    [int]$SoftDeleteRetentionDays = 14,

    [Parameter()]
    [string]$BackupTime = '23:00',

    [Parameter()]
    [ValidateRange(7, 9999)]
    [int]$DailyRetentionDays = 30,

    [Parameter()]
    [int]$WeeklyRetentionWeeks = 12,

    [Parameter()]
    [int]$MonthlyRetentionMonths = 12,

    [Parameter()]
    [int]$YearlyRetentionYears = 3,

    [Parameter()]
    [bool]$DeployEnhancedPolicy = $true,

    [Parameter()]
    [switch]$UseExistingResourceGroup,

    [Parameter()]
    [string]$ExistingResourceGroupName = '',

    [Parameter()]
    [switch]$UseExistingVault,

    [Parameter()]
    [string]$ExistingVaultResourceId = ''
)

$ErrorActionPreference = 'Stop'
$bicepFile = Join-Path $PSScriptRoot '..\bicep\deploy.bicep'

# ── Prerequisiti ──────────────────────────────────────────────────────────────

Write-Host "`n=== Azure Backup - Deployment Script ===" -ForegroundColor Cyan
Write-Host "Deployment Name  : $DeploymentName"
Write-Host "Location         : $Location"
Write-Host "Storage Type     : $StorageType"
Write-Host "Soft Delete      : $EnableSoftDelete ($SoftDeleteRetentionDays giorni)"
Write-Host "Retention Daily  : $DailyRetentionDays giorni"
Write-Host "Retention Weekly : $WeeklyRetentionWeeks settimane"
Write-Host "Retention Monthly: $MonthlyRetentionMonths mesi"
Write-Host "Retention Yearly : $YearlyRetentionYears anni"
Write-Host "Enhanced Policy  : $DeployEnhancedPolicy"
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

# Validazione vault esistente
if ($UseExistingVault -and [string]::IsNullOrEmpty($ExistingVaultResourceId)) {
    $ExistingVaultResourceId = Read-Host "Resource ID del Recovery Services Vault esistente"
}

# ── Parametri deployment ───────────────────────────────────────────────────────

$params = @{
    deploymentName             = $DeploymentName
    location                   = $Location
    storageType                = $StorageType
    enableSoftDelete           = $EnableSoftDelete
    softDeleteRetentionDays    = $SoftDeleteRetentionDays
    backupTime                 = $BackupTime
    dailyRetentionDays         = $DailyRetentionDays
    weeklyRetentionWeeks       = $WeeklyRetentionWeeks
    monthlyRetentionMonths     = $MonthlyRetentionMonths
    yearlyRetentionYears       = $YearlyRetentionYears
    deployEnhancedPolicy       = $DeployEnhancedPolicy
    useExistingResourceGroup   = $UseExistingResourceGroup.IsPresent
    existingResourceGroupName  = $ExistingResourceGroupName
    useExistingVault           = $UseExistingVault.IsPresent
    existingVaultResourceId    = $ExistingVaultResourceId
}

# ── Deploy ─────────────────────────────────────────────────────────────────────

Write-Host "`nAvvio deployment..." -ForegroundColor Yellow
$deploymentName_full = "backup-$DeploymentName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

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
        Write-Host "Resource Group  : $($deployment.Outputs.resourceGroupName.Value)"
    }
    if ($deployment.Outputs.vaultName) {
        Write-Host "Vault Name      : $($deployment.Outputs.vaultName.Value)"
    }
    if ($deployment.Outputs.vaultId) {
        Write-Host "Vault ID        : $($deployment.Outputs.vaultId.Value)"
    }
    Write-Host ""
    Write-Host "=== PROSSIMI PASSI ===" -ForegroundColor Yellow
    Write-Host "1. Verifica il vault su Azure Portal: https://portal.azure.com"
    Write-Host "2. Assegna le policy di backup alle VM che non sono ancora protette"
    Write-Host "3. Verifica la policy di auto-backup tramite Azure Policy"
    Write-Host "4. Esegui un backup manuale iniziale su alcune VM critiche"
    Write-Host "5. Testa il restore da backup prima della messa in produzione"
    Write-Host ""
    Write-Host "=== LINK UTILI ===" -ForegroundColor Cyan
    Write-Host "Portal Backup    : https://portal.azure.com/#browse/Microsoft.RecoveryServices/vaults"
    Write-Host "Documentazione   : https://learn.microsoft.com/azure/backup/backup-azure-vms-introduction"
} else {
    Write-Warning "Deployment concluso con stato: $($deployment.ProvisioningState)"
    if ($deployment.ProvisioningState -eq 'Failed') {
        Write-Error "Deployment fallito. Verifica i dettagli nell'activity log di Azure."
    }
}
