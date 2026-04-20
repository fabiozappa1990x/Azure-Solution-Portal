<#
.SYNOPSIS
Microsoft Defender XDR / Defender for Endpoint — Precheck & Gap Analysis
.NOTES
Version: 1.0
Usa Microsoft Graph API (delegated, via X-Graph-Token dal browser MSAL).
Tenant-wide: non richiede subscription Azure.
Controlla: policy MDE in Intune, Secure Score, alert attivi, gap vs baseline.
#>

param(
    [Parameter(Mandatory=$false)] [string]$SubscriptionId = 'tenant-only',
    [Parameter(Mandatory=$false)] [string]$OutputPath = ".\DefenderXDR-Report.html"
)

$graphToken = $env:AZURE_GRAPH_TOKEN
if (-not $graphToken) { Write-Error "AZURE_GRAPH_TOKEN not found."; exit 1 }

function Invoke-GraphAPI {
    param([string]$Uri, [string]$Method = "GET", [object]$Body = $null)
    $headers = @{ "Authorization" = "Bearer $graphToken"; "Content-Type" = "application/json" }
    try {
        $params = @{ Uri = $Uri; Headers = $headers; Method = $Method; ErrorAction = 'Stop' }
        if ($Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 10 -Compress) }
        $response = Invoke-RestMethod @params
        if ($Method -eq "GET" -and $response -and $response.'@odata.nextLink' -and $response.value) {
            $all = @($response.value)
            $next = $response.'@odata.nextLink'
            $pageCount = 0
            while ($next -and $pageCount -lt 50) {
                $pageCount++
                try {
                    $page = Invoke-RestMethod -Uri $next -Headers $headers -Method GET -ErrorAction Stop
                    if ($page.value) { $all += @($page.value) }
                    $next = $page.'@odata.nextLink'
                } catch { $next = $null }
            }
            $response.value = $all
            $response.'@odata.nextLink' = $null
        }
        return $response
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        Write-Warning "Graph API [$status]: $Uri — $($_.Exception.Message)"
        return $null
    }
}

$startTime = Get-Date
Write-Host "=== DEFENDER XDR PRECHECK START ==="

$data = @{
    Timestamp            = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Tenant               = @{}
    SecureScore          = @{}
    Alerts               = @{}
    ExistingMdePolicies  = @()
    PolicyGapAnalysis    = @()
    Summary              = @{}
    ReportHTML           = ""
}

# ----------------------------------------
# [1] Tenant info
# ----------------------------------------
Write-Host "[1/6] Tenant info..."
$org = Invoke-GraphAPI -Uri "https://graph.microsoft.com/v1.0/organization?`$select=id,displayName,verifiedDomains"
if ($org -and $org.value -and $org.value.Count -gt 0) {
    $t = $org.value[0]
    $data.Tenant = @{ Id = $t.id; Name = $t.displayName }
    Write-Host "Tenant: $($t.displayName)"
}

# ----------------------------------------
# [2] Secure Score (richiede SecurityEvents.Read.All — fallback graceful)
# ----------------------------------------
Write-Host "[2/6] Secure Score..."
$secureScoreResp = Invoke-GraphAPI -Uri "https://graph.microsoft.com/v1.0/security/secureScores?`$top=1&`$select=azureTenantId,currentScore,maxScore,createdDateTime,enabledServices"
if ($secureScoreResp -and $secureScoreResp.value -and $secureScoreResp.value.Count -gt 0) {
    $ss = $secureScoreResp.value[0]
    $ssPercent = if ($ss.maxScore -gt 0) { [math]::Round(($ss.currentScore / $ss.maxScore) * 100, 1) } else { 0 }
    $data.SecureScore = @{
        Current    = $ss.currentScore
        Max        = $ss.maxScore
        Percentage = $ssPercent
        Date       = $ss.createdDateTime
        Available  = $true
    }
    Write-Host "Secure Score: $($ss.currentScore)/$($ss.maxScore) ($ssPercent%)"
} else {
    $data.SecureScore = @{ Available = $false; Percentage = 0 }
    Write-Host "Secure Score: non disponibile (scope SecurityEvents.Read.All non concesso)"
}

# ----------------------------------------
# [3] Active alerts summary (richiede SecurityEvents.Read.All — fallback graceful)
# ----------------------------------------
Write-Host "[3/6] Active alerts..."
$alertsResp = Invoke-GraphAPI -Uri "https://graph.microsoft.com/v1.0/security/alerts_v2?`$top=100&`$filter=status ne 'resolved'&`$select=id,title,severity,status,category,createdDateTime"
if ($alertsResp -and $alertsResp.value) {
    $alertList = @($alertsResp.value)
    $data.Alerts = @{
        Total     = $alertList.Count
        High      = @($alertList | Where-Object { $_.severity -eq 'high' }).Count
        Medium    = @($alertList | Where-Object { $_.severity -eq 'medium' }).Count
        Low       = @($alertList | Where-Object { $_.severity -eq 'low' }).Count
        Available = $true
    }
    Write-Host "Alerts: $($alertList.Count) attivi (High: $($data.Alerts.High))"
} else {
    $data.Alerts = @{ Available = $false; Total = 0; High = 0; Medium = 0; Low = 0 }
    Write-Host "Alerts: non disponibili (scope SecurityEvents.Read.All non concesso)"
}

# ----------------------------------------
# [4] Existing MDE-related policies in Intune
# ----------------------------------------
Write-Host "[4/6] Existing MDE Intune policies..."

# Device configurations (AV, ASR, EDR, tamper)
$devConfResp = Invoke-GraphAPI -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations?`$top=500&`$select=id,displayName,@odata.type,lastModifiedDateTime"
$existingPolicies = @()
if ($devConfResp -and $devConfResp.value) {
    foreach ($p in $devConfResp.value) {
        $existingPolicies += @{
            Id           = $p.id
            DisplayName  = $p.displayName
            OdataType    = $p.'@odata.type'
            LastModified = $p.lastModifiedDateTime
        }
    }
}

# Endpoint security intents (AV, EDR, ASR via Endpoint Security blade)
$intentsResp = Invoke-GraphAPI -Uri "https://graph.microsoft.com/v1.0/deviceManagement/intents?`$select=id,displayName,templateId"
if ($intentsResp -and $intentsResp.value) {
    foreach ($i in $intentsResp.value) {
        $existingPolicies += @{
            Id           = $i.id
            DisplayName  = $i.displayName
            OdataType    = "intent:$($i.templateId)"
            LastModified = ""
        }
    }
}

$data.ExistingMdePolicies = $existingPolicies
Write-Host "Found $($existingPolicies.Count) existing Intune policies"

# ----------------------------------------
# [5] Gap Analysis vs MDE Baseline
# ----------------------------------------
Write-Host "[5/6] Gap analysis..."

$existingTypes = @($existingPolicies | ForEach-Object { $_.OdataType.ToLower() })
$existingNames = @($existingPolicies | ForEach-Object { $_.DisplayName.ToLower() })

$baselineChecks = @(
    @{ Id = 'edr-onboarding';      Name = 'EDR Onboarding (Intune connector)'; Critical = $true;  OdataMatch = 'windowsdefenderadvancedthreatprotectionconfiguration'; KeywordMatch = 'edr|onboard|atp' }
    @{ Id = 'av-nextgen';          Name = 'AV Next-Gen Protection';            Critical = $true;  OdataMatch = 'windows10endpointprotectionconfiguration';            KeywordMatch = 'av|antivirus|defender|protection|ngp' }
    @{ Id = 'tamper-protection';   Name = 'Tamper Protection (OMA-URI)';       Critical = $true;  OdataMatch = 'windows10customconfiguration';                        KeywordMatch = 'tamper' }
    @{ Id = 'network-protection';  Name = 'Network Protection (Block mode)';   Critical = $true;  OdataMatch = 'windows10customconfiguration';                        KeywordMatch = 'network.protect' }
    @{ Id = 'asr-rules';           Name = 'ASR Rules (Attack Surface Reduction)'; Critical = $false; OdataMatch = 'windows10customconfiguration';                    KeywordMatch = 'asr|attack.surface' }
    @{ Id = 'endpoint-protection'; Name = 'Endpoint Protection (firewall)';    Critical = $false; OdataMatch = 'windows10endpointprotectionconfiguration';            KeywordMatch = 'endpoint.protect|firewall' }
)

$gapAnalysis = @()
foreach ($check in $baselineChecks) {
    $odataMatch = $check.OdataMatch.ToLower()
    $kwMatch    = $check.KeywordMatch.ToLower()

    # Match by display name keyword
    $nameMatched = $existingNames | Where-Object {
        foreach ($kw in ($kwMatch -split '\|')) { if ($_ -like "*$kw*") { return $true } }
        return $false
    }
    # Match by [Baseline] prefix specifically
    $baselineNameMatched = $existingNames | Where-Object { $_ -like '*[baseline]*' -and ($_ -like "*$($check.Id.Replace('-','*'))*") }

    $present = ($nameMatched.Count -gt 0) -or ($baselineNameMatched.Count -gt 0)

    $gapAnalysis += @{
        Id       = $check.Id
        Name     = $check.Name
        Critical = $check.Critical
        Present  = $present
        Status   = if ($present) { 'OK' } else { 'MISSING' }
    }
}
$data.PolicyGapAnalysis = $gapAnalysis
Write-Host "Gap analysis: $(@($gapAnalysis | Where-Object { $_.Status -eq 'MISSING' }).Count) policy mancanti"

# ----------------------------------------
# [6] Summary
# ----------------------------------------
Write-Host "[6/6] Summary..."
$criticalMissing  = @($gapAnalysis | Where-Object { $_.Critical -and $_.Status -eq 'MISSING' }).Count
$criticalTotal    = @($gapAnalysis | Where-Object { $_.Critical }).Count
$totalMissing     = @($gapAnalysis | Where-Object { $_.Status -eq 'MISSING' }).Count

$readiness = 100
if ($criticalTotal -gt 0) { $readiness = [math]::Round((($criticalTotal - $criticalMissing) / $criticalTotal) * 100) }

$ssPercent = if ($data.SecureScore.Available) { $data.SecureScore.Percentage } else { 0 }
$ssColor   = if ($ssPercent -ge 80) { '#107c10' } elseif ($ssPercent -ge 50) { '#ff8c00' } else { '#d13438' }
$rdColor   = if ($readiness -ge 80) { '#107c10' } elseif ($readiness -ge 50) { '#ff8c00' } else { '#d13438' }

$data.Summary = @{
    TotalExistingPolicies = $existingPolicies.Count
    TotalGapChecks        = $gapAnalysis.Count
    CriticalMissing       = $criticalMissing
    TotalMissing          = $totalMissing
    ReadinessScore        = $readiness
    SecureScorePercent    = $ssPercent
    AlertsHigh            = $data.Alerts.High
    AlertsTotal           = $data.Alerts.Total
    TenantName            = $data.Tenant.Name
}

# ----------------------------------------
# HTML Report
# ----------------------------------------
$tenantName = if ($data.Tenant.Name) { $data.Tenant.Name } else { 'N/A' }

$gapRows = ""
foreach ($g in $gapAnalysis) {
    $statusColor = if ($g.Present) { '#107c10' } else { '#d13438' }
    $statusLabel = if ($g.Present) { 'PRESENTE' } else { 'MANCANTE' }
    $critLabel   = if ($g.Critical) { '<span style="background:#fff3cd;color:#856404;border-radius:3px;padding:1px 6px;font-size:11px;font-weight:700;">CRITICA</span>' } else { '' }
    $gapRows += "<tr>
        <td>$([System.Web.HttpUtility]::HtmlEncode($g.Name)) $critLabel</td>
        <td><span style='background:$statusColor;color:white;border-radius:4px;padding:2px 10px;font-size:11px;font-weight:700;'>$statusLabel</span></td>
    </tr>"
}

$policyRows = ""
foreach ($p in ($existingPolicies | Select-Object -First 100)) {
    $type = $p.OdataType -replace '#microsoft\.graph\.', ''
    $policyRows += "<tr>
        <td>$([System.Web.HttpUtility]::HtmlEncode($p.DisplayName))</td>
        <td>$([System.Web.HttpUtility]::HtmlEncode($type))</td>
    </tr>"
}

$secureScoreHtml = if ($data.SecureScore.Available) {
    "<div class='kpi-card'><div class='kpi-value' style='color:$ssColor'>$ssPercent%</div><div class='kpi-label'>Secure Score M365</div></div>"
} else {
    "<div class='kpi-card'><div class='kpi-value' style='color:#666'>N/D</div><div class='kpi-label'>Secure Score (scope mancante)</div></div>"
}

$alertsHtml = if ($data.Alerts.Available) {
    "<div class='kpi-card'><div class='kpi-value' style='color:$(if ($data.Alerts.High -gt 0){ '#d13438' } else { '#107c10' })'>$($data.Alerts.High)</div><div class='kpi-label'>Alert High Severity</div></div>"
} else {
    "<div class='kpi-card'><div class='kpi-value' style='color:#666'>N/D</div><div class='kpi-label'>Alert attivi (scope mancante)</div></div>"
}

$reportHtml = @"
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="UTF-8">
<title>Defender XDR Precheck Report</title>
<style>
  body { font-family: 'Segoe UI', sans-serif; margin: 0; padding: 20px; background: #f5f5f5; color: #333; }
  .report-header { background: linear-gradient(135deg, #0a2342, #1a4a8a); color: white; padding: 24px 28px; border-radius: 8px; margin-bottom: 24px; }
  .report-header h1 { margin: 0 0 6px; font-size: 22px; }
  .report-header p { margin: 0; opacity: 0.85; font-size: 13px; }
  .kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 14px; margin-bottom: 24px; }
  .kpi-card { background: white; border-radius: 8px; padding: 16px; text-align: center; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }
  .kpi-value { font-size: 28px; font-weight: 700; color: #0078d4; }
  .kpi-label { font-size: 12px; color: #666; margin-top: 4px; }
  .section { background: white; border-radius: 8px; padding: 20px; margin-bottom: 20px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }
  .section h2 { margin: 0 0 16px; font-size: 16px; color: #0a2342; border-bottom: 2px solid #e0e0e0; padding-bottom: 8px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { background: #f0f4ff; color: #0a2342; padding: 8px 10px; text-align: left; border-bottom: 2px solid #c8d8f0; font-weight: 600; }
  td { padding: 7px 10px; border-bottom: 1px solid #f0f0f0; vertical-align: middle; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: #fafbff; }
  .footer { text-align: center; color: #999; font-size: 11px; margin-top: 16px; }
</style>
</head>
<body>
<div class="report-header">
  <h1>Microsoft Defender XDR — Gap Analysis & Precheck</h1>
  <p>Tenant: <strong>$tenantName</strong> &nbsp;|&nbsp; Generato il: $($data.Timestamp)</p>
</div>

<div class="kpi-grid">
  <div class="kpi-card">
    <div class="kpi-value" style="color:$rdColor">$readiness%</div>
    <div class="kpi-label">MDE Readiness Score</div>
  </div>
  <div class="kpi-card">
    <div class="kpi-value" style="color:$(if($criticalMissing -gt 0){'#d13438'}else{'#107c10'})">$criticalMissing</div>
    <div class="kpi-label">Policy Critiche Mancanti</div>
  </div>
  $secureScoreHtml
  $alertsHtml
  <div class="kpi-card">
    <div class="kpi-value">$($existingPolicies.Count)</div>
    <div class="kpi-label">Policy Intune Esistenti</div>
  </div>
</div>

<div class="section">
  <h2>Gap Analysis — Baseline MDE</h2>
  <table>
    <thead><tr><th>Policy</th><th>Stato</th></tr></thead>
    <tbody>$gapRows</tbody>
  </table>
</div>

<div class="section">
  <h2>Policy Intune Esistenti</h2>
  <table>
    <thead><tr><th>Nome</th><th>Tipo</th></tr></thead>
    <tbody>$policyRows</tbody>
  </table>
</div>

<div class="footer">Report generato da Azure Solution Portal — Microsoft Defender XDR Precheck v1.0</div>
</body>
</html>
"@

$data.ReportHTML = $reportHtml

$tempDir = if ($env:TEMP) { $env:TEMP } else { '/tmp' }
$jsonPath = [System.IO.Path]::ChangeExtension($OutputPath, ".json")
if (-not [System.IO.Path]::IsPathRooted($jsonPath)) { $jsonPath = Join-Path $tempDir "defenderxdr_report_$SubscriptionId.json" }
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath = Join-Path $tempDir "defenderxdr_report_$SubscriptionId.html" }

$data | ConvertTo-Json -Depth 10 -Compress | Set-Content -Path $jsonPath -Encoding UTF8
$reportHtml | Set-Content -Path $OutputPath -Encoding UTF8

$elapsed = (Get-Date) - $startTime
Write-Host "=== DEFENDER XDR PRECHECK DONE in $([math]::Round($elapsed.TotalSeconds,1))s ==="
Write-Host "JSON: $jsonPath"
Write-Host "HTML: $OutputPath"
