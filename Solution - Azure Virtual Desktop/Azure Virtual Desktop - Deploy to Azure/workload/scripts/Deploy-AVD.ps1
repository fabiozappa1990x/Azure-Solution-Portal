<#
.SYNOPSIS
    Deploya Azure Virtual Desktop (AVD) tramite Bicep.

.DESCRIPTION
    Script di deployment per Azure Virtual Desktop con Host Pool, Session Hosts,
    FSLogix, Scaling Plan e integrazione con Azure Monitor.

.PARAMETER SubscriptionId
    ID della sottoscrizione Azure.

.PARAMETER DeploymentName
    Nome base del deployment (prefisso per tutte le risorse).

.PARAMETER Location
    Regione Azure (es: westeurope, italynorth).

.PARAMETER HostPoolType
    Tipo di Host Pool: Pooled o Personal.

.PARAMETER SessionHostCount
    Numero di session host da deployare.

.PARAMETER VmSize
    Dimensione VM per i session host.

.PARAMETER AdminUsername
    Username amministratore locale per i session host.

.PARAMETER VnetId
    Resource ID della Virtual Network.

.PARAMETER SubnetName
    Nome della subnet per i session host.

.PARAMETER JoinType
    Tipo di join: AzureAD o ActiveDirectory.

.PARAMETER EmailRecipients
    Indirizzi email separati da punto e virgola.

.EXAMPLE
    .\Deploy-AVD.ps1 `
        -SubscriptionId "00000000-0000-0000-0000-000000000000" `
        -DeploymentName "avd-prod" `
        -Location "westeurope" `
        -VnetId "/subscriptions/.../virtualNetworks/vnet-prod" `
        -SubnetName "snet-avd" `
        -AdminUsername "avdadmin"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$DeploymentName,

    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter()]
    [ValidateSet('Pooled', 'Personal')]
    [string]$HostPoolType = 'Pooled',

    [Parameter()]
    [ValidateRange(0, 50)]
    [int]$SessionHostCount = 2,

    [Parameter()]
    [string]$VmSize = 'Standard_D4s_v5',

    [Parameter(Mandatory)]
    [string]$AdminUsername,

    [Parameter(Mandatory)]
    [string]$VnetId,

    [Parameter(Mandatory)]
    [string]$SubnetName,

    [Parameter()]
    [ValidateSet('AzureAD', 'ActiveDirectory')]
    [string]$JoinType = 'AzureAD',

    [Parameter()]
    [string]$DomainToJoin = '',

    [Parameter()]
    [string]$LogAnalyticsWorkspaceId = '',

    [Parameter()]
    [switch]$DeployFSLogix = $true,

    [Parameter()]
    [switch]$DeployScalingPlan = $true,

    [Parameter()]
    [switch]$UseExistingResourceGroup
)

$ErrorActionPreference = 'Stop'
$bicepFile = Join-Path $PSScriptRoot '..\bicep\deploy.bicep'

# ── Prerequisiti ──────────────────────────────────────────────────────────────

Write-Host "`n=== Azure Virtual Desktop - Deployment Script ===" -ForegroundColor Cyan
Write-Host "Deployment Name : $DeploymentName"
Write-Host "Location        : $Location"
Write-Host "Host Pool Type  : $HostPoolType"
Write-Host "Session Hosts   : $SessionHostCount"
Write-Host "Join Type       : $JoinType"
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

# ── Password admin ─────────────────────────────────────────────────────────────

$adminPassword = Read-Host "Password per l'amministratore locale '$AdminUsername'" -AsSecureString

$domainJoinUser = ''
$domainJoinPassword = [Security.SecureString]::new()
if ($JoinType -eq 'ActiveDirectory') {
    if ([string]::IsNullOrEmpty($DomainToJoin)) {
        $DomainToJoin = Read-Host "Dominio AD da unire (es: contoso.com)"
    }
    $domainJoinUser   = Read-Host "UPN account domain join (es: join@contoso.com)"
    $domainJoinPassword = Read-Host "Password account domain join" -AsSecureString
}

# ── Parametri deployment ───────────────────────────────────────────────────────

$params = @{
    deploymentName        = $DeploymentName
    location              = $Location
    hostPoolType          = $HostPoolType
    sessionHostCount      = $SessionHostCount
    vmSize                = $VmSize
    adminUsername         = $AdminUsername
    adminPassword         = $adminPassword
    vnetId                = $VnetId
    subnetName            = $SubnetName
    joinType              = $JoinType
    domainToJoin          = $DomainToJoin
    domainJoinUser        = $domainJoinUser
    domainJoinPassword    = $domainJoinPassword
    deployFSLogix         = $DeployFSLogix.IsPresent
    deployScalingPlan     = $DeployScalingPlan.IsPresent
    logAnalyticsWorkspaceId = $LogAnalyticsWorkspaceId
    useExistingResourceGroup = $UseExistingResourceGroup.IsPresent
}

# ── Deploy ─────────────────────────────────────────────────────────────────────

Write-Host "`nAvvio deployment..." -ForegroundColor Yellow
$deploymentName_full = "avd-$DeploymentName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

$deployment = New-AzSubscriptionDeployment `
    -Name       $deploymentName_full `
    -Location   $Location `
    -TemplateFile $bicepFile `
    -TemplateParameterObject $params `
    -Verbose:$VerbosePreference

if ($deployment.ProvisioningState -eq 'Succeeded') {
    Write-Host "`n✅ Deployment completato con successo!" -ForegroundColor Green
    Write-Host ""
    Write-Host "=== OUTPUT ===" -ForegroundColor Cyan
    Write-Host "Resource Group  : $($deployment.Outputs.resourceGroupName.Value)"
    Write-Host "Host Pool ID    : $($deployment.Outputs.hostPoolId.Value)"
    Write-Host "Workspace ID    : $($deployment.Outputs.workspaceId.Value)"
    if ($DeployFSLogix) {
        Write-Host "FSLogix UNC     : $($deployment.Outputs.fslogixShareUNC.Value)"
    }
    Write-Host "AVD Portal URL  : $($deployment.Outputs.avdPortalUrl.Value)"
    Write-Host ""
    Write-Host "=== PROSSIMI PASSI ===" -ForegroundColor Yellow
    Write-Host "1. Accedi ad Azure Virtual Desktop: https://aka.ms/avd"
    Write-Host "2. Assegna utenti al Application Group"
    if ($DeployFSLogix) {
        Write-Host "3. Configura FSLogix sui session host (GPO o Registry)"
        Write-Host "   NOTA: percorso share FSLogix: $($deployment.Outputs.fslogixShareUNC.Value)"
    }
} else {
    Write-Error "Deployment fallito con stato: $($deployment.ProvisioningState)"
}
