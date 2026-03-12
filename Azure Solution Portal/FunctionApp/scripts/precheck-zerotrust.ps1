<#
.SYNOPSIS
Zero Trust Assessment (tenant-scoped) via Microsoft Graph
.NOTES
- This script runs in Azure Functions PowerShell.
- It uses delegated Graph token passed from the portal (GRAPH_ACCESS_TOKEN).
#>

param(
    [Parameter(Mandatory = $false)]
    [string] $TenantId = '',

    [Parameter(Mandatory = $false)]
    [string] $OutputPath = ".\\ZeroTrustReport.html"
)

$graphToken = $env:GRAPH_ACCESS_TOKEN
if (-not $graphToken) {
    throw "GRAPH_ACCESS_TOKEN not found. This script must be called from Azure Function."
}

Import-Module (Join-Path $PSScriptRoot 'lib/EnterprisePrecheck.psm1') -Force

function Invoke-Graph {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter()] [string] $Method = 'GET'
    )
    $headers = @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json' }
    try {
        return Invoke-RestMethod -Uri $Uri -Headers $headers -Method $Method -ErrorAction Stop
    } catch {
        $statusCode = $null
        try { $statusCode = $_.Exception.Response.StatusCode.value__ } catch {}
        return [pscustomobject]@{
            __error = $true
            status  = $statusCode
            message = $_.Exception.Message
        }
    }
}

$startTime = Get-Date
$timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

# Core tenant info
$org = Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/organization?`$select=id,displayName"
$tenantDisplayName = if ($org.__error) { 'N/A' } else { [string]$org.value[0].displayName }
$tenantIdActual    = if ($org.__error) { $TenantId } else { [string]$org.value[0].id }

# Security defaults
$secDefaults = Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy"
$securityDefaultsEnabled = $null
if (-not $secDefaults.__error) { $securityDefaultsEnabled = [bool]$secDefaults.isEnabled }

# Conditional Access policies
$ca = Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies"
$caPolicies = @()
if (-not $ca.__error -and $ca.value) { $caPolicies = @($ca.value) }
$caEnabled = @($caPolicies | Where-Object { $_.state -eq 'enabled' }).Count

# Authentication methods policy
$authMethodsPolicy = Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy"
$strongMethodsEnabled = $null
if (-not $authMethodsPolicy.__error -and $authMethodsPolicy.authenticationMethodConfigurations) {
    $cfg = @($authMethodsPolicy.authenticationMethodConfigurations)
    $strong = @('fido2', 'microsoftAuthenticator', 'windowsHelloForBusiness')
    $strongMethodsEnabled = ($cfg | Where-Object { $strong -contains $_.'@odata.type'.Split('.')[-1] -and $_.state -eq 'enabled' }).Count -gt 0
}

# MFA registration report (optional, may require additional permissions and can be large)
$mfaRegPercent = $null
$mfaReport = Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/reports/authenticationMethods/userRegistrationDetails?`$top=999"
if (-not $mfaReport.__error -and $mfaReport.value) {
    $rows = @($mfaReport.value)
    if ($rows.Count -gt 0) {
        $registered = @($rows | Where-Object { $_.isMfaRegistered -eq $true }).Count
        $mfaRegPercent = [math]::Round(100 * ($registered / $rows.Count), 1)
    }
}

# Legacy auth blocked (heuristic via CA policy that blocks clientAppTypes "other")
$legacyAuthBlocked = $null
if ($caPolicies.Count -gt 0) {
    $legacyBlock = $caPolicies | Where-Object {
        $_.state -eq 'enabled' -and $_.conditions -and $_.conditions.clientAppTypes -and
        ($_.conditions.clientAppTypes -contains 'other') -and $_.grantControls -and
        ($_.grantControls.builtInControls -contains 'block')
    }
    $legacyAuthBlocked = @($legacyBlock).Count -gt 0
}

$summary = [ordered]@{
    TenantId                    = $tenantIdActual
    TenantDisplayName           = $tenantDisplayName
    SecurityDefaultsEnabled     = $securityDefaultsEnabled
    ConditionalAccessTotalCount = $caPolicies.Count
    ConditionalAccessEnabledCount = $caEnabled
    StrongMethodsEnabled        = $strongMethodsEnabled
    MfaRegistrationPercent      = $mfaRegPercent
    LegacyAuthBlocked           = $legacyAuthBlocked
}

# Enterprise checks
$checks = @()

$baselineOk = ($securityDefaultsEnabled -eq $true) -or ($caEnabled -ge 1)
$baselineStatus = if ($baselineOk) { 'Pass' } else { 'Fail' }
$baselineRationale = if ($baselineOk) { 'Security Defaults o Conditional Access risultano configurati.' } else { 'Nessuna baseline di access control rilevata (Security Defaults off e CA policies non abilitate).' }
$checks += New-PrecheckCheck -Id 'zt.baseline' -Title 'Baseline access controls presenti' -Severity 'Critical' -Status $baselineStatus -Rationale $baselineRationale -Remediation 'Abilita Security Defaults (tenant small) o implementa una baseline di Conditional Access (MFA + legacy auth block + risk based).'

if ($securityDefaultsEnabled -ne $null) {
    $secDefaultsStatus = if ($securityDefaultsEnabled) { 'Warn' } else { 'Pass' }
    $secDefaultsRationale = if ($securityDefaultsEnabled) { 'Security Defaults abilitati (baseline pronta, ma meno granularità rispetto a CA).' } else { 'Security Defaults disabilitati (ok se sostituiti da Conditional Access enterprise).' }
    $checks += New-PrecheckCheck -Id 'zt.securitydefaults' -Title 'Security Defaults' -Severity 'Medium' -Status $secDefaultsStatus -Rationale $secDefaultsRationale -Remediation 'Se usi CA enterprise, tieni Security Defaults disabilitati; altrimenti abilitali come baseline.'
} else {
    $checks += New-PrecheckCheck -Id 'zt.securitydefaults' -Title 'Security Defaults' -Severity 'Medium' -Status 'Skip' -Rationale 'Impossibile leggere lo stato (permessi Graph insufficienti).' -Remediation 'Concedi Policy.Read.All (admin consent) per leggere le policy tenant.'
}

$caStatus = if ($caEnabled -ge 5) { 'Pass' } elseif ($caEnabled -ge 1) { 'Warn' } else { if ($securityDefaultsEnabled) { 'Warn' } else { 'Fail' } }
$checks += New-PrecheckCheck -Id 'zt.conditionalaccess' -Title 'Conditional Access policies abilitate' -Severity 'High' -Status $caStatus -Rationale "CA abilitate: $caEnabled (totali: $($caPolicies.Count))." -Remediation 'Implementa baseline CA: MFA for admins/users, block legacy auth, require compliant device per app critiche, risk based.'

if ($legacyAuthBlocked -ne $null) {
    $legacyStatus = if ($legacyAuthBlocked) { 'Pass' } else { 'Fail' }
    $legacyRationale = if ($legacyAuthBlocked) { 'Rilevata almeno una policy CA che blocca client app "other" (legacy auth).' } else { 'Nessuna policy CA di block legacy auth rilevata.' }
    $checks += New-PrecheckCheck -Id 'zt.legacyauth' -Title 'Legacy authentication' -Severity 'Critical' -Status $legacyStatus -Rationale $legacyRationale -Remediation 'Crea una CA policy per bloccare legacy auth (clientAppTypes: other) e migra i client legacy.'
} else {
    $checks += New-PrecheckCheck -Id 'zt.legacyauth' -Title 'Legacy authentication' -Severity 'Critical' -Status 'Skip' -Rationale 'Impossibile determinare (CA policies non leggibili o non presenti).' -Remediation 'Concedi Policy.Read.All e verifica Conditional Access.'
}

if ($strongMethodsEnabled -ne $null) {
    $strongStatus = if ($strongMethodsEnabled) { 'Pass' } else { 'Warn' }
    $strongRationale = if ($strongMethodsEnabled) { 'Rilevati metodi forti (FIDO2 / Authenticator / WHfB) abilitati.' } else { 'Metodi forti non rilevati come abilitati nel policy set.' }
    $checks += New-PrecheckCheck -Id 'zt.strongmethods' -Title 'Metodi forti abilitati' -Severity 'High' -Status $strongStatus -Rationale $strongRationale -Remediation 'Abilita metodi resistenti al phishing (FIDO2/WHfB) e promuovi passwordless.'
} else {
    $checks += New-PrecheckCheck -Id 'zt.strongmethods' -Title 'Metodi forti abilitati' -Severity 'High' -Status 'Skip' -Rationale 'Impossibile leggere authentication methods policy (permessi insufficienti).' -Remediation 'Concedi Policy.Read.All (admin consent).'
}

if ($mfaRegPercent -ne $null) {
    $mfaStatus = if ($mfaRegPercent -ge 80) { 'Pass' } elseif ($mfaRegPercent -ge 50) { 'Warn' } else { 'Fail' }
    $checks += New-PrecheckCheck -Id 'zt.mfareg' -Title 'MFA registration' -Severity 'High' -Status $mfaStatus -Rationale "MFA registration stimata: $mfaRegPercent%." -Remediation 'Esegui campagne di registration (SSPR/MFA), enforce registration e monitora adoption.'
} else {
    $checks += New-PrecheckCheck -Id 'zt.mfareg' -Title 'MFA registration' -Severity 'High' -Status 'Skip' -Rationale 'Report MFA non disponibile (permessi Reports.Read.All o endpoint non accessibile).' -Remediation 'Concedi Reports.Read.All (admin consent) per leggere i report di registration.'
}

$readiness = Get-PrecheckReadiness -Checks $checks
if ($summary -is [hashtable]) { $summary['ReadinessScore'] = $readiness.score } else { $summary | Add-Member -NotePropertyName 'ReadinessScore' -NotePropertyValue $readiness.score -Force }

$aiPayload = @{
    solution = "Zero Trust Assessment"
    summary  = $summary
    checks   = $checks
    caSample = $caPolicies | Select-Object -First 10 displayName, state
}
$aiHtml = Invoke-EnterpriseOpenAIHtml -SolutionName "Zero Trust Assessment" -Payload $aiPayload

$kpis = @{
    Kpi1Label = 'Tenant'
    Kpi1Value = $tenantDisplayName
    Kpi2Label = 'CA enabled'
    Kpi2Value = $caEnabled
    Kpi3Label = 'MFA reg'
    Kpi3Value = if ($mfaRegPercent -ne $null) { "$mfaRegPercent%" } else { 'N/A' }
    Kpi4Label = 'Legacy auth'
    Kpi4Value = if ($legacyAuthBlocked -eq $true) { 'Blocked' } elseif ($legacyAuthBlocked -eq $false) { 'Allowed' } else { 'N/A' }
}

$context = @{
    SubscriptionName = $tenantDisplayName
    SubscriptionId   = $tenantIdActual
    Timestamp        = $timestamp
}

$enterpriseHtml = New-EnterpriseHtmlReport -SolutionName "Zero Trust Assessment" -Summary $kpis -Checks $checks -AiHtml $aiHtml -LegacyHtml '' -Context $context

$out = [ordered]@{
    Timestamp = $timestamp
    Tenant    = @{ Id = $tenantIdActual; Name = $tenantDisplayName }
    Summary   = $summary
    Checks    = $checks
    Readiness = $readiness
    ReportHTML = $enterpriseHtml
}

$jsonPath = $OutputPath -replace "\.html$", ".json"
$enterpriseHtml | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$out | ConvertTo-Json -Depth 20 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Host "=== ZT PRECHECK DONE === Time: $([math]::Round(((Get-Date)-$startTime).TotalSeconds))s Readiness: $($readiness.score)%"
