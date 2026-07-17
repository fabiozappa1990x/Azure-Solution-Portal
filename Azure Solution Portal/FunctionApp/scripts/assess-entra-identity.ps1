<#
.SYNOPSIS
Entra ID Identity Assessment — read-only (Microsoft Graph).
.DESCRIPTION
Valuta la postura identity del tenant Entra ID: ruoli privilegiati, Security Defaults vs Conditional Access,
copertura MFA/CA, utenti guest, igiene delle app registration (segreti/certificati in scadenza) e utenti inattivi.
Solo Graph REST con token delegato inoltrato via header X-Graph-Token. Nessuna modifica al tenant.
.NOTES
Version: 1.0 — allineato al pattern precheck-* (EnterprisePrecheck.psm1).
Il parametro SubscriptionId è ignorato (assessment tenant-wide).
#>

param(
    [Parameter(Mandatory=$false)] [string]$SubscriptionId = 'tenant-only',
    [Parameter(Mandatory=$false)] [string]$OutputPath = ".\Entra-Report.html"
)

$graphToken = $env:AZURE_GRAPH_TOKEN
if (-not $graphToken) { Write-Error "AZURE_GRAPH_TOKEN not found."; exit 1 }

function Invoke-GraphAPI {
    param([string]$Uri, [switch]$ConsistencyEventual)
    $headers = @{ 'Authorization' = "Bearer $graphToken"; 'Content-Type' = 'application/json' }
    if ($ConsistencyEventual) { $headers['ConsistencyLevel'] = 'eventual' }
    try {
        $response = Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get -ErrorAction Stop
        if ($response -and ($response.PSObject.Properties.Name -contains 'value')) {
            $all = @(); $all += @($response.value)
            $next = if ($response.PSObject.Properties.Name -contains '@odata.nextLink') { $response.'@odata.nextLink' } else { $null }
            $pageCount = 0
            while ($next -and $pageCount -lt 200) {
                $pageCount++
                $page = Invoke-RestMethod -Uri $next -Headers $headers -Method Get -ErrorAction Stop
                if ($page -and ($page.PSObject.Properties.Name -contains 'value')) { $all += @($page.value) }
                $next = if ($page.PSObject.Properties.Name -contains '@odata.nextLink') { $page.'@odata.nextLink' } else { $null }
            }
            return $all
        }
        return $response
    } catch {
        Write-Warning "Graph failed: $Uri - $($_.Exception.Message)"
        return $null
    }
}

$graphBase = 'https://graph.microsoft.com/v1.0'
$startTime = Get-Date
Write-Host "=== ENTRA IDENTITY ASSESSMENT START ==="

$data = @{
    Timestamp        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Tenant           = @{}
    Users            = @{ Total = 0; Enabled = 0; Guests = 0; InactiveUnknown = $true; Inactive90d = 0 }
    PrivilegedRoles  = @{ GlobalAdmins = 0; TotalPrivileged = 0; Roles = @() }
    SecurityDefaults = @{ Enabled = $false; Known = $false }
    ConditionalAccess= @{ Total = 0; Enabled = 0; ReportOnly = 0; MfaAll = $false; BlockLegacy = $false }
    AppRegistrations = @{ Total = 0; ExpiredSecrets = 0; ExpiringSoon = 0 }
    Summary          = @{}
}

# [1] Tenant / organization
Write-Host "[1/7] Organization..."
$org = Invoke-GraphAPI -Uri "$graphBase/organization"
if ($org) {
    $o = if ($org -is [array]) { $org[0] } else { $org }
    $data.Tenant = @{ Name = [string]$o.displayName; Id = [string]$o.id }
}

# [2] Users (enabled / guests)
Write-Host "[2/7] Users..."
$users = Invoke-GraphAPI -Uri "$graphBase/users?`$select=id,accountEnabled,userType&`$top=999"
if ($users) {
    $arr = @($users)
    $data.Users.Total = $arr.Count
    $data.Users.Enabled = @($arr | Where-Object { $_.accountEnabled -eq $true }).Count
    $data.Users.Guests = @($arr | Where-Object { [string]$_.userType -eq 'Guest' }).Count
    Write-Host "  Users: $($data.Users.Total) (guests: $($data.Users.Guests))"
}

# [2b] Inactive users (sign-in activity, richiede AuditLog.Read.All + Entra ID P1)
$signin = Invoke-GraphAPI -Uri "$graphBase/users?`$select=id,signInActivity&`$top=999"
if ($signin) {
    $cutoff = (Get-Date).AddDays(-90)
    $inactive = 0; $measured = $false
    foreach ($u in @($signin)) {
        if ($u.PSObject.Properties.Name -contains 'signInActivity' -and $u.signInActivity -and $u.signInActivity.lastSignInDateTime) {
            $measured = $true
            $last = $null
            try { $last = [datetime]$u.signInActivity.lastSignInDateTime } catch {}
            if ($last -and $last -lt $cutoff) { $inactive++ }
        }
    }
    if ($measured) { $data.Users.InactiveUnknown = $false; $data.Users.Inactive90d = $inactive }
}

# [3] Privileged roles
Write-Host "[3/7] Privileged roles..."
$roles = Invoke-GraphAPI -Uri "$graphBase/directoryRoles"
if ($roles) {
    $privTemplates = @{
        '62e90394-69f5-4237-9190-012177145e10' = 'Global Administrator'
        'e8611ab8-c189-46e8-94e1-60213ab1f814' = 'Privileged Role Administrator'
        '194ae4cb-b126-40b2-bd5b-6091b380977d' = 'Security Administrator'
        'f28a1f50-f6e7-4571-818b-6a12f2af6b6c' = 'SharePoint Administrator'
        '29232cdf-9323-42fd-ade2-1d097af3e4de' = 'Exchange Administrator'
    }
    $totalPriv = 0
    foreach ($r in @($roles)) {
        $members = Invoke-GraphAPI -Uri "$graphBase/directoryRoles/$($r.id)/members?`$select=id"
        $count = if ($members) { @($members).Count } else { 0 }
        $tpl = [string]$r.roleTemplateId
        if ($tpl -eq '62e90394-69f5-4237-9190-012177145e10') { $data.PrivilegedRoles.GlobalAdmins = $count }
        if ($privTemplates.ContainsKey($tpl)) {
            $totalPriv += $count
            $data.PrivilegedRoles.Roles += @{ Name = [string]$r.displayName; Members = $count }
        }
    }
    $data.PrivilegedRoles.TotalPrivileged = $totalPriv
    Write-Host "  Global Admins: $($data.PrivilegedRoles.GlobalAdmins)"
}

# [4] Security Defaults
Write-Host "[4/7] Security Defaults..."
$secDef = Invoke-GraphAPI -Uri "$graphBase/policies/identitySecurityDefaultsEnforcementPolicy"
if ($secDef) {
    $sd = if ($secDef -is [array]) { $secDef[0] } else { $secDef }
    if ($sd.PSObject.Properties.Name -contains 'isEnabled') {
        $data.SecurityDefaults.Enabled = [bool]$sd.isEnabled
        $data.SecurityDefaults.Known = $true
    }
}

# [5] Conditional Access
Write-Host "[5/7] Conditional Access..."
$ca = Invoke-GraphAPI -Uri "$graphBase/identity/conditionalAccess/policies"
if ($ca) {
    $arr = @($ca)
    $data.ConditionalAccess.Total = $arr.Count
    $data.ConditionalAccess.Enabled = @($arr | Where-Object { [string]$_.state -eq 'enabled' }).Count
    $data.ConditionalAccess.ReportOnly = @($arr | Where-Object { [string]$_.state -eq 'enabledForReportingButNotEnforced' }).Count
    foreach ($p in $arr) {
        if ([string]$p.state -ne 'enabled') { continue }
        $gc = $p.grantControls
        $usersAll = $p.conditions.users.includeUsers -contains 'All'
        if ($gc -and ($gc.builtInControls -contains 'mfa') -and $usersAll) { $data.ConditionalAccess.MfaAll = $true }
        $apps = $p.conditions.clientAppTypes
        if ($apps -and (($apps -contains 'exchangeActiveSync') -or ($apps -contains 'other')) -and $gc -and ($gc.builtInControls -contains 'block')) {
            $data.ConditionalAccess.BlockLegacy = $true
        }
    }
    Write-Host "  CA policies: $($data.ConditionalAccess.Total) (enabled: $($data.ConditionalAccess.Enabled))"
}

# [6] App registrations hygiene
Write-Host "[6/7] App registrations..."
$apps = Invoke-GraphAPI -Uri "$graphBase/applications?`$select=id,displayName,passwordCredentials,keyCredentials&`$top=999"
if ($apps) {
    $arr = @($apps)
    $data.AppRegistrations.Total = $arr.Count
    $now = Get-Date; $soon = $now.AddDays(30)
    foreach ($a in $arr) {
        $creds = @()
        if ($a.passwordCredentials) { $creds += @($a.passwordCredentials) }
        if ($a.keyCredentials) { $creds += @($a.keyCredentials) }
        foreach ($c in $creds) {
            if (-not $c.endDateTime) { continue }
            $end = $null
            try { $end = [datetime]$c.endDateTime } catch {}
            if (-not $end) { continue }
            if ($end -lt $now) { $data.AppRegistrations.ExpiredSecrets++ }
            elseif ($end -lt $soon) { $data.AppRegistrations.ExpiringSoon++ }
        }
    }
    Write-Host "  Apps: $($data.AppRegistrations.Total) (expired secrets: $($data.AppRegistrations.ExpiredSecrets))"
}

# [7] Build checks
Write-Host "[7/7] Building checks..."
Import-Module (Join-Path $PSScriptRoot 'lib/EnterprisePrecheck.psm1') -Force

$checks = @()

# Global Admin sprawl
$ga = [int]$data.PrivilegedRoles.GlobalAdmins
$gaStatus = if ($ga -eq 0) { 'Fail' } elseif ($ga -ge 1 -and $ga -le 5) { 'Pass' } elseif ($ga -le 8) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'entra.globaladmins' -Title 'Numero di Global Administrator' -Severity 'Critical' -Status $gaStatus -Rationale "Global Admin: $ga. Best practice Microsoft: mantenere un numero ridotto (idealmente ≤ 5) di ruoli privilegiati permanenti." -Remediation 'Riduci i Global Admin permanenti, adotta PIM (just-in-time) e mantieni 2 account break-glass esclusi dalle CA.'

# MFA / CA coverage
if ($data.ConditionalAccess.Total -gt 0) {
    $mfaStatus = if ($data.ConditionalAccess.MfaAll) { 'Pass' } elseif ($data.ConditionalAccess.Enabled -gt 0) { 'Warn' } else { 'Fail' }
    $mfaRationale = "Policy CA totali: $($data.ConditionalAccess.Total) (enabled: $($data.ConditionalAccess.Enabled), report-only: $($data.ConditionalAccess.ReportOnly)). MFA per tutti gli utenti: $($data.ConditionalAccess.MfaAll)."
} else {
    $mfaStatus = if ($data.SecurityDefaults.Enabled) { 'Warn' } else { 'Fail' }
    $mfaRationale = if ($data.SecurityDefaults.Enabled) { 'Nessuna Conditional Access: la sicurezza si basa solo sui Security Defaults (MFA base, non granulare).' } else { 'Nessuna Conditional Access e Security Defaults disabilitati: MFA non garantita.' }
}
$checks += New-PrecheckCheck -Id 'entra.mfa' -Title 'Copertura MFA (Conditional Access / Security Defaults)' -Severity 'Critical' -Status $mfaStatus -Rationale $mfaRationale -Remediation 'Implementa una CA che imponga MFA a tutti gli utenti (o adotta la baseline Conditional Access del portale).'

# Legacy auth block
$legacyStatus = if ($data.ConditionalAccess.BlockLegacy -or $data.SecurityDefaults.Enabled) { 'Pass' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'entra.legacyauth' -Title 'Blocco legacy authentication' -Severity 'High' -Status $legacyStatus -Rationale "Blocco legacy auth via CA: $($data.ConditionalAccess.BlockLegacy). Security Defaults: $($data.SecurityDefaults.Enabled)." -Remediation 'Crea una CA che blocca i protocolli di autenticazione legacy (POP/IMAP/SMTP/ActiveSync di base).'

# Security defaults vs CA (posture consistency)
$sdStatus = if (-not $data.SecurityDefaults.Known) { 'Skip' } elseif ($data.SecurityDefaults.Enabled -and $data.ConditionalAccess.Enabled -gt 0) { 'Warn' } else { 'Pass' }
$checks += New-PrecheckCheck -Id 'entra.securitydefaults' -Title 'Coerenza Security Defaults / Conditional Access' -Severity 'Medium' -Status $sdStatus -Rationale "Security Defaults abilitati: $($data.SecurityDefaults.Enabled); CA abilitate: $($data.ConditionalAccess.Enabled). I due meccanismi non vanno usati insieme." -Remediation 'Con tenant enterprise usa esclusivamente Conditional Access e disabilita i Security Defaults.'

# Guest governance
$guestPct = if ($data.Users.Total -gt 0) { [math]::Round(($data.Users.Guests / $data.Users.Total) * 100, 1) } else { 0 }
$guestStatus = if ($data.Users.Guests -eq 0) { 'Pass' } elseif ($guestPct -le 30) { 'Pass' } elseif ($guestPct -le 60) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'entra.guests' -Title 'Governance utenti guest (B2B)' -Severity 'Low' -Status $guestStatus -Rationale "Guest: $($data.Users.Guests)/$($data.Users.Total) ($guestPct%)." -Remediation 'Applica access review periodiche sui guest e restrizioni di invito/accesso via Entra External Identities.'

# App registration hygiene
$appStatus = if ($data.AppRegistrations.ExpiredSecrets -eq 0 -and $data.AppRegistrations.ExpiringSoon -le 3) { 'Pass' } elseif ($data.AppRegistrations.ExpiredSecrets -le 5) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'entra.appsecrets' -Title 'Igiene credenziali app registration' -Severity 'Medium' -Status $appStatus -Rationale "App: $($data.AppRegistrations.Total). Segreti scaduti: $($data.AppRegistrations.ExpiredSecrets); in scadenza (30gg): $($data.AppRegistrations.ExpiringSoon)." -Remediation 'Ruota i segreti scaduti/in scadenza, preferisci certificati o federated credentials (workload identity).'

# Inactive users
if (-not $data.Users.InactiveUnknown) {
    $inactStatus = if ($data.Users.Inactive90d -eq 0) { 'Pass' } elseif ($data.Users.Inactive90d -le 20) { 'Warn' } else { 'Fail' }
    $checks += New-PrecheckCheck -Id 'entra.inactive' -Title 'Utenti inattivi (> 90 giorni)' -Severity 'Low' -Status $inactStatus -Rationale "Utenti senza sign-in da oltre 90 giorni: $($data.Users.Inactive90d)." -Remediation 'Disabilita o rimuovi gli account inattivi tramite access review automatizzate.'
} else {
    $checks += New-PrecheckCheck -Id 'entra.inactive' -Title 'Utenti inattivi (> 90 giorni)' -Severity 'Low' -Status 'Skip' -Rationale 'Dato sign-in non disponibile: richiede AuditLog.Read.All e licenza Entra ID P1/P2.' -Remediation 'Concedi AuditLog.Read.All e abilita Entra ID P1 per misurare gli utenti inattivi.'
}

$readiness = Get-PrecheckReadiness -Checks $checks
$data.Readiness = $readiness
$data.Checks = $checks

$data.Summary = @{
    GlobalAdmins       = $data.PrivilegedRoles.GlobalAdmins
    CaPolicies         = $data.ConditionalAccess.Total
    Guests             = $data.Users.Guests
    TotalUsers         = $data.Users.Total
    ExpiredSecrets     = $data.AppRegistrations.ExpiredSecrets
    Inactive90d        = if ($data.Users.InactiveUnknown) { 'n/d' } else { $data.Users.Inactive90d }
    SecurityDefaults   = $data.SecurityDefaults.Enabled
    ReadinessScore     = $readiness.score
}

# ---- HTML report ----
$roleRows = ($data.PrivilegedRoles.Roles | ForEach-Object {
    "<tr><td>$([System.Net.WebUtility]::HtmlEncode($_.Name))</td><td>$($_.Members)</td></tr>"
}) -join "`n"

$appendix = @"
<div>
  <h3>Appendice tecnica</h3>
  <h4>Ruoli privilegiati (membri)</h4>
  <table><thead><tr><th>Ruolo</th><th>Membri</th></tr></thead><tbody>$roleRows</tbody></table>
  <h4>Conditional Access</h4>
  <table><thead><tr><th>Metrica</th><th>Valore</th></tr></thead><tbody>
    <tr><td>Policy totali</td><td>$($data.ConditionalAccess.Total)</td></tr>
    <tr><td>Enabled</td><td>$($data.ConditionalAccess.Enabled)</td></tr>
    <tr><td>Report-only</td><td>$($data.ConditionalAccess.ReportOnly)</td></tr>
    <tr><td>MFA per tutti</td><td>$($data.ConditionalAccess.MfaAll)</td></tr>
    <tr><td>Blocco legacy auth</td><td>$($data.ConditionalAccess.BlockLegacy)</td></tr>
  </tbody></table>
</div>
"@

$aiPayload = @{
    solution = 'Entra ID Identity Assessment'
    summary  = $data.Summary
    checks   = $checks
    privileged = $data.PrivilegedRoles
}
$aiHtml = Invoke-EnterpriseOpenAIHtml -SolutionName 'Entra ID Identity Assessment' -Payload $aiPayload

$kpis = @{
    Kpi1Label = 'Global Admins'; Kpi1Value = $data.PrivilegedRoles.GlobalAdmins
    Kpi2Label = 'CA policies'; Kpi2Value = $data.ConditionalAccess.Total
    Kpi3Label = 'Guest'; Kpi3Value = $data.Users.Guests
    Kpi4Label = 'Segreti scaduti'; Kpi4Value = $data.AppRegistrations.ExpiredSecrets
}

$guide = @()
foreach ($c in $checks) {
    if ($c.status -in @('Fail','Warn') -and $c.remediation) {
        $guide += [ordered]@{ title = [string]$c.title; why = [string]$c.rationale; how = [string]$c.remediation; when = [string]$c.severity }
    }
}
if ($guide.Count -eq 0) { $guide += 'Postura identity solida. Mantieni PIM, access review e rotazione segreti come processi ricorrenti.' }

$htmlContent = New-EnterpriseHtmlReport -SolutionName 'Entra ID Identity Assessment' -Summary $kpis -Checks $checks -ImplementationGuide $guide -AiHtml $aiHtml -LegacyHtml $appendix -Context @{
    SubscriptionName = $data.Tenant.Name
    SubscriptionId   = $data.Tenant.Id
    Timestamp        = $data.Timestamp
}

$htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$data['ReportHTML'] = $htmlContent
$jsonPath = $OutputPath -replace "\.html$", ".json"
$data | ConvertTo-Json -Depth 15 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Host "=== ENTRA IDENTITY DONE === Time: $([math]::Round(((Get-Date)-$startTime).TotalSeconds))s Readiness: $($readiness.score)%"
