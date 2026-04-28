<#
.SYNOPSIS
    Configures the Azure Monitor Hub Function App's Managed Identity with all
    permissions required to run Invoke-M365Assessment.

.DESCRIPTION
    Run this script ONCE per tenant you want to assess. It:
      1. Reads the Function App's Managed Identity service principal ID
      2. Grants all required Microsoft Graph application permissions
      3. Grants Exchange Online app roles (Exchange.ManageAsApp)
      4. Assigns directory roles (Global Reader) to the MI service principal

    After this setup, clicking "Esegui Assessment" in the portal will run the
    full M365-Assess assessment using the Function App's identity — no user
    credentials needed.

.PARAMETER FunctionAppName
    Name of the Azure Function App (e.g. 'func-azsolportal-089fb2a1').

.PARAMETER FunctionAppResourceGroup
    Azure Resource Group containing the Function App.

.PARAMETER TenantId
    Tenant ID of the target Microsoft 365 tenant to assess.
    Defaults to the current az CLI tenant.

.PARAMETER AdminUpn
    UPN of a Global Administrator in the target tenant.
    Required for Exchange Online RBAC assignment.

.PARAMETER SkipExchangeRbac
    Skip Exchange Online role assignment (Email section will be skipped in assessment).

.EXAMPLE
    .\Grant-M365AssessPermissions.ps1 `
        -FunctionAppName 'func-azsolportal-089fb2a1' `
        -FunctionAppResourceGroup 'rg-azsolportal' `
        -AdminUpn 'admin@contoso.onmicrosoft.com'

.NOTES
    Requires:
        - az CLI logged in with Contributor on the Function App resource group
        - PowerShell 7+
        - Microsoft.Graph.Authentication, Microsoft.Graph.Applications (Install-Module)
        - ExchangeOnlineManagement 3.7.1 (Install-Module)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $FunctionAppName,
    [Parameter(Mandatory)] [string] $FunctionAppResourceGroup,
    [string] $TenantId,
    [string] $AdminUpn,
    [switch] $SkipExchangeRbac
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step { param([string]$M) Write-Host "`n>>> $M" -ForegroundColor Cyan }
function Write-OK   { param([string]$M) Write-Host "  [OK] $M" -ForegroundColor Green }
function Write-Skip { param([string]$M) Write-Host "  [--] $M" -ForegroundColor DarkGray }
function Write-Warn { param([string]$M) Write-Host "  [!!] $M" -ForegroundColor Yellow }
function Write-Fail { param([string]$M) Write-Host "  [XX] $M" -ForegroundColor Red }

# ------------------------------------------------------------------
# Required Graph application permissions (same as Grant-M365AssessConsent)
# ------------------------------------------------------------------
$graphPermissions = @(
    'User.Read.All', 'UserAuthenticationMethod.Read.All',
    'Directory.Read.All', 'Organization.Read.All', 'Domain.Read.All',
    'Policy.Read.All', 'Application.Read.All',
    'AuditLog.Read.All', 'Reports.Read.All',
    'RoleManagement.Read.Directory',
    'SecurityEvents.Read.All', 'SecurityAlert.Read.All',
    'DeviceManagementConfiguration.Read.All', 'DeviceManagementManagedDevices.Read.All',
    'Sites.Read.All', 'TeamSettings.Read.All',
    'Group.Read.All', 'Agreement.Read.All',
    'TeamworkAppSettings.Read.All', 'OrgSettings-Forms.Read.All',
    'SharePointTenantSettings.Read.All'
)

$directoryRoles = @(
    @{ Name = 'Global Reader';    TemplateId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451' }
    @{ Name = 'Security Reader';  TemplateId = '5d6b6bb7-de71-4623-b4af-96380a352509' }
)

$exoRoleGroups = @('View-Only Organization Management', 'Compliance Management')

# ------------------------------------------------------------------
# STEP 1 — Enable Managed Identity on Function App + get principal ID
# ------------------------------------------------------------------
Write-Step "Step 1: Managed Identity on Function App '$FunctionAppName'"

$miJson = az functionapp identity show `
    --name $FunctionAppName `
    --resource-group $FunctionAppResourceGroup 2>/dev/null | ConvertFrom-Json

if (-not $miJson -or -not $miJson.principalId) {
    Write-Warn "Managed Identity non abilitata. Abilitazione in corso..."
    $miJson = az functionapp identity assign `
        --name $FunctionAppName `
        --resource-group $FunctionAppResourceGroup `
        --identities '[system]' 2>/dev/null | ConvertFrom-Json
    if (-not $miJson.principalId) {
        throw "Impossibile abilitare Managed Identity. Verificare permessi az CLI."
    }
    Write-OK "Managed Identity abilitata."
} else {
    Write-OK "Managed Identity già abilitata."
}

$miPrincipalId = $miJson.principalId
$miTenantId    = $miJson.tenantId
Write-OK "Principal ID: $miPrincipalId"
Write-OK "Tenant ID   : $miTenantId"

if (-not $TenantId) { $TenantId = $miTenantId }

# ------------------------------------------------------------------
# STEP 2 — Connect Microsoft Graph (delegated, admin)
# ------------------------------------------------------------------
Write-Step "Step 2: Connessione a Microsoft Graph (tenant $TenantId)"

$requiredScopes = @(
    'Application.ReadWrite.All',
    'AppRoleAssignment.ReadWrite.All',
    'RoleManagement.ReadWrite.Directory',
    'Directory.Read.All'
)

$env:MSAL_ALLOW_WAM = '0'
Connect-MgGraph -TenantId $TenantId -Scopes $requiredScopes -NoWelcome -ErrorAction Stop
Write-OK "Connesso come: $((Get-MgContext).Account)"

# ------------------------------------------------------------------
# STEP 3 — Grant Graph application permissions to MI service principal
# ------------------------------------------------------------------
Write-Step "Step 3: Permessi Microsoft Graph ($($graphPermissions.Count) permessi)"

$graphSp  = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'" -ErrorAction Stop
$roleLookup = @{}
foreach ($r in $graphSp.AppRoles) { $roleLookup[$r.Value] = $r.Id }

$existingAssignments = @(
    Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miPrincipalId -ErrorAction SilentlyContinue |
        Where-Object { $_.ResourceId -eq $graphSp.Id } |
        Select-Object -ExpandProperty AppRoleId
)

foreach ($perm in $graphPermissions) {
    if (-not $roleLookup.ContainsKey($perm)) {
        Write-Warn "$perm — non trovato in Graph AppRoles"
        continue
    }
    $roleId = $roleLookup[$perm]
    if ($existingAssignments -contains $roleId) {
        Write-Skip "$perm (già assegnato)"
        continue
    }
    try {
        New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miPrincipalId -BodyParameter @{
            PrincipalId = $miPrincipalId
            ResourceId  = $graphSp.Id
            AppRoleId   = $roleId
        } | Out-Null
        Write-OK $perm
    } catch {
        Write-Fail "$perm — $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------
# STEP 4 — Exchange.ManageAsApp
# ------------------------------------------------------------------
Write-Step "Step 4: Exchange.ManageAsApp"

try {
    $exoSp = Get-MgServicePrincipal -Filter "appId eq '00000002-0000-0ff1-ce00-000000000000'" -ErrorAction Stop
    $manageAsApp = $exoSp.AppRoles | Where-Object { $_.Value -eq 'Exchange.ManageAsApp' }
    if ($manageAsApp) {
        $existingExo = @(
            Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miPrincipalId -ErrorAction SilentlyContinue |
                Where-Object { $_.AppRoleId -eq $manageAsApp.Id }
        )
        if ($existingExo.Count -gt 0) {
            Write-Skip "Exchange.ManageAsApp (già assegnato)"
        } else {
            New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miPrincipalId -BodyParameter @{
                PrincipalId = $miPrincipalId
                ResourceId  = $exoSp.Id
                AppRoleId   = $manageAsApp.Id
            } | Out-Null
            Write-OK "Exchange.ManageAsApp"
        }
    } else {
        Write-Warn "Exchange.ManageAsApp non trovato nell'EXO SP"
    }
} catch {
    Write-Fail "Exchange.ManageAsApp — $($_.Exception.Message)"
}

# ------------------------------------------------------------------
# STEP 5 — Directory roles (Global Reader, Security Reader)
# ------------------------------------------------------------------
Write-Step "Step 5: Directory roles Entra ID"

foreach ($roleDef in $directoryRoles) {
    $dirRole = Get-MgDirectoryRole -Filter "roleTemplateId eq '$($roleDef.TemplateId)'" -ErrorAction SilentlyContinue
    if (-not $dirRole) {
        try {
            $dirRole = New-MgDirectoryRole -BodyParameter @{ roleTemplateId = $roleDef.TemplateId } -ErrorAction Stop
            Write-OK "$($roleDef.Name) — attivato nel tenant"
        } catch {
            Write-Fail "$($roleDef.Name) — $($_.Exception.Message)"; continue
        }
    }
    $members = @(
        Get-MgDirectoryRoleMemberAsServicePrincipal -DirectoryRoleId $dirRole.Id -All -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Id
    )
    if ($members -contains $miPrincipalId) {
        Write-Skip "$($roleDef.Name) (già assegnato)"
    } else {
        try {
            New-MgDirectoryRoleMemberByRef -DirectoryRoleId $dirRole.Id -BodyParameter @{
                '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$miPrincipalId"
            } -ErrorAction Stop
            Write-OK $roleDef.Name
        } catch {
            if ($_.Exception.Message -match 'already exist') { Write-Skip "$($roleDef.Name) (già presente)" }
            else { Write-Fail "$($roleDef.Name) — $($_.Exception.Message)" }
        }
    }
}

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

# ------------------------------------------------------------------
# STEP 6 — Exchange Online RBAC role groups
# ------------------------------------------------------------------
if ($SkipExchangeRbac) {
    Write-Step "Step 6: Exchange Online RBAC — SKIPPED"
    Write-Warn "La sezione Email non sarà disponibile nell'assessment."
} elseif (-not $AdminUpn) {
    Write-Step "Step 6: Exchange Online RBAC"
    Write-Warn "AdminUpn non specificato — Exchange RBAC saltato."
    Write-Warn "Eseguire: .\Grant-M365AssessPermissions.ps1 ... -AdminUpn admin@contoso.com"
} else {
    Write-Step "Step 6: Exchange Online RBAC role groups (come $AdminUpn)"
    try {
        Connect-ExchangeOnline -UserPrincipalName $AdminUpn -ShowBanner:$false -ErrorAction Stop
        Write-OK "Connesso a Exchange Online"
        # Resolve the MI display name in EXO context
        $miSpName = (Get-MgServicePrincipal -ServicePrincipalId $miPrincipalId -ErrorAction SilentlyContinue)?.DisplayName
        if (-not $miSpName) { $miSpName = $FunctionAppName }
        foreach ($rg in $exoRoleGroups) {
            try {
                $members = @(Get-RoleGroupMember -Identity $rg -ErrorAction Stop | Select-Object -ExpandProperty Name)
                if ($members -contains $miSpName) {
                    Write-Skip "$rg (già membro)"
                } else {
                    Add-RoleGroupMember -Identity $rg -Member $miSpName -ErrorAction Stop
                    Write-OK $rg
                }
            } catch {
                if ($_.Exception.Message -match 'already a member') { Write-Skip "$rg (già membro)" }
                else { Write-Fail "$rg — $($_.Exception.Message)" }
            }
        }
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    } catch {
        Write-Fail "Exchange Online connection failed: $($_.Exception.Message)"
        Write-Warn "Riprovare con -AdminUpn corretto. La sezione Email sarà skippata fino ad allora."
    }
}

# ------------------------------------------------------------------
# DONE
# ------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Setup completato." -ForegroundColor Green
Write-Host "  La Managed Identity '$FunctionAppName' e' pronta." -ForegroundColor Green
Write-Host "  Aprire il portale e cliccare 'Esegui Assessment'." -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Principal ID : $miPrincipalId"
Write-Host "  Tenant       : $TenantId"
Write-Host ""
