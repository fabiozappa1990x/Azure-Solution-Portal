param(
    [Parameter(Mandatory = $true)] [string] $TenantId,
    [Parameter(Mandatory = $false)] [string] $OutputPath = ".\\assessment365-report.html"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$graphToken = $env:AZURE_GRAPH_TOKEN
if (-not $graphToken) { throw "AZURE_GRAPH_TOKEN non disponibile." }

function Invoke-GraphApi {
    param([Parameter(Mandatory)] [string] $Uri)
    $headers = @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json' }
    try { return Invoke-RestMethod -Uri $Uri -Headers $headers -Method GET -ErrorAction Stop } catch { return $null }
}

function Add-Finding {
    param(
        [string]$CheckId,
        [string]$Severity,
        [string]$Area,
        [string]$Title,
        [string]$Remediation
    )
    $script:Findings += [PSCustomObject]@{
        CheckId = $CheckId
        Severity = $Severity
        Area = $Area
        Title = $Title
        Remediation = $Remediation
    }
}

function Escape-Html {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

$script:Findings = @()
$start = Get-Date

# Lightweight tenant-wide checks inspired by M365-Assess focus areas.
$org = Invoke-GraphApi -Uri "https://graph.microsoft.com/v1.0/organization?`$select=id,displayName"
$tenantName = "Unknown tenant"
$tenantGuid = $TenantId
if ($org -and $org.value -and @($org.value).Count -gt 0) {
    $tenantName = [string]@($org.value)[0].displayName
    $tenantGuid = [string]@($org.value)[0].id
}

$secDefaults = Invoke-GraphApi -Uri "https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy"
$secDefaultsEnabled = $false
if ($secDefaults -and ($secDefaults.PSObject.Properties.Name -contains 'isEnabled')) {
    $secDefaultsEnabled = [bool]$secDefaults.isEnabled
}

$ca = Invoke-GraphApi -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?`$top=999"
$caPolicies = @()
if ($ca -and $ca.value) { $caPolicies = @($ca.value) }
$caEnabled = @($caPolicies | Where-Object { $_.state -eq 'enabled' }).Count

$users = Invoke-GraphApi -Uri "https://graph.microsoft.com/v1.0/users?`$select=id,accountEnabled,userType&`$top=999"
$enabledUsers = 0
if ($users -and $users.value) {
    $enabledUsers = @($users.value | Where-Object { $_.accountEnabled -eq $true -and $_.userType -eq 'Member' }).Count
}

if (-not $secDefaultsEnabled -and $caEnabled -eq 0) {
    Add-Finding -CheckId "A365-001" -Severity "Critical" -Area "Identity" `
        -Title "Nessuna protezione di accesso attiva" `
        -Remediation "Abilitare Security Defaults o policy CA baseline (MFA, legacy auth block)."
}
if ($caEnabled -eq 0) {
    Add-Finding -CheckId "A365-002" -Severity "High" -Area "Identity" `
        -Title "Conditional Access non in enforcement" `
        -Remediation "Attivare almeno policy CA baseline ad alta priorità."
}
if ($enabledUsers -gt 2000 -and $caEnabled -lt 5) {
    Add-Finding -CheckId "A365-003" -Severity "Medium" -Area "Identity" `
        -Title "Copertura CA bassa rispetto al numero utenti" `
        -Remediation "Rafforzare la copertura CA per utenti interni e admin."
}

$totalChecks = 3
$failedChecks = $script:Findings.Count
$critical = @($script:Findings | Where-Object Severity -eq 'Critical').Count
$high = @($script:Findings | Where-Object Severity -eq 'High').Count
$passRate = [math]::Round((($totalChecks - $failedChecks) / [math]::Max($totalChecks,1)) * 100, 1)

$rows = ''
foreach ($f in $script:Findings) {
    $color = switch ($f.Severity) {
        'Critical' { '#d13438' }
        'High' { '#f7630c' }
        'Medium' { '#ffb900' }
        default { '#107c10' }
    }
    $rows += "<tr><td>$(Escape-Html $f.CheckId)</td><td><span style='background:$color;color:white;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:700;'>$(Escape-Html $f.Severity)</span></td><td>$(Escape-Html $f.Area)</td><td>$(Escape-Html $f.Title)</td><td>$(Escape-Html $f.Remediation)</td></tr>"
}
if (-not $rows) { $rows = "<tr><td colspan='5'>Nessun finding rilevato nel quick assessment.</td></tr>" }

$reportHtml = @"
<html>
<head><meta charset='utf-8'><title>Assessment 365</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 16px; color: #1f2937; }
h1 { margin: 0 0 8px 0; }
.meta { color: #555; margin-bottom: 14px; }
.kpi { display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr)); gap:10px; margin: 12px 0 16px; }
.card { border:1px solid #e5e7eb; border-radius:8px; padding:10px; background:#f8fafc; }
.card .t { color:#64748b; font-size:12px; }
.card .v { font-size:22px; font-weight:700; }
table { width:100%; border-collapse:collapse; font-size:12px; }
th, td { border:1px solid #e5e7eb; padding:8px; text-align:left; }
th { background:#f1f5f9; }
</style>
</head>
<body>
<h1>Assessment 365 (Cloud Execution)</h1>
<div class='meta'>Tenant: <b>$(Escape-Html $tenantName)</b> | TenantId: <b>$(Escape-Html $tenantGuid)</b> | Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
<div class='kpi'>
<div class='card'><div class='t'>Total Checks</div><div class='v'>$totalChecks</div></div>
<div class='card'><div class='t'>Failed Checks</div><div class='v'>$failedChecks</div></div>
<div class='card'><div class='t'>Critical</div><div class='v'>$critical</div></div>
<div class='card'><div class='t'>High</div><div class='v'>$high</div></div>
<div class='card'><div class='t'>Pass Rate</div><div class='v'>$passRate%</div></div>
</div>
<table>
<thead><tr><th>CheckId</th><th>Severity</th><th>Area</th><th>Finding</th><th>Remediation</th></tr></thead>
<tbody>$rows</tbody>
</table>
</body></html>
"@

$output = [ordered]@{
    GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    Tenant = @{ DisplayName = $tenantName; TenantId = $tenantGuid }
    Summary = @{
        TotalChecks = $totalChecks
        FailedChecks = $failedChecks
        CriticalFindings = $critical
        HighFindings = $high
        PassRate = "$passRate%"
    }
    Findings = $script:Findings
    ReportHTML = $reportHtml
    DurationSeconds = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
}

$jsonPath = [System.IO.Path]::ChangeExtension($OutputPath, '.json')
$reportHtml | Out-File -FilePath $OutputPath -Encoding utf8 -Force
($output | ConvertTo-Json -Depth 8) | Out-File -FilePath $jsonPath -Encoding utf8 -Force
