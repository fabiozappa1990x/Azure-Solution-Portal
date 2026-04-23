param(
    [Parameter(Mandatory = $true)] [string] $SubscriptionId,
    [Parameter(Mandatory = $false)] [string] $OutputPath = ".\\AssessmentSecurityReport.html"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$azureToken = $env:AZURE_ACCESS_TOKEN
$graphToken = $env:AZURE_GRAPH_TOKEN

if (-not $azureToken) { throw "AZURE_ACCESS_TOKEN non disponibile." }
if (-not $graphToken) { throw "AZURE_GRAPH_TOKEN non disponibile." }

function Invoke-AzureApi {
    param([Parameter(Mandatory)] [string] $Uri)
    $headers = @{ Authorization = "Bearer $azureToken"; 'Content-Type' = 'application/json' }
    try { return Invoke-RestMethod -Uri $Uri -Headers $headers -Method GET -ErrorAction Stop } catch { return $null }
}

function Invoke-GraphApi {
    param([Parameter(Mandatory)] [string] $Uri)
    $headers = @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json' }
    try { return Invoke-RestMethod -Uri $Uri -Headers $headers -Method GET -ErrorAction Stop } catch { return $null }
}

function Add-Finding {
    param(
        [Parameter(Mandatory)] [string] $Severity,
        [Parameter(Mandatory)] [string] $Area,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [string] $Remediation
    )
    $script:Findings += [PSCustomObject]@{
        Id          = "FND-$('{0:d3}' -f ($script:Findings.Count + 1))"
        Severity    = $Severity
        Area        = $Area
        Title       = $Title
        Description = $Description
        Remediation = $Remediation
    }
}

function Escape-Html {
    param([string] $Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

$script:Findings = @()
$started = Get-Date

# ---- Azure baseline ----
$sub = Invoke-AzureApi -Uri "https://management.azure.com/subscriptions/$SubscriptionId?api-version=2022-12-01"
if (-not $sub) { throw "Subscription non accessibile: $SubscriptionId" }

$subName = [string]$sub.displayName

$vmResp = Invoke-AzureApi -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Compute/virtualMachines?api-version=2023-09-01"
$vms = @()
if ($vmResp -and ($vmResp.PSObject.Properties.Name -contains 'value') -and $vmResp.value) { $vms = @($vmResp.value) }

$saResp = Invoke-AzureApi -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Storage/storageAccounts?api-version=2023-01-01"
$storageAccounts = @()
if ($saResp -and ($saResp.PSObject.Properties.Name -contains 'value') -and $saResp.value) { $storageAccounts = @($saResp.value) }

$kvResp = Invoke-AzureApi -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.KeyVault/vaults?api-version=2023-07-01"
$keyVaults = @()
if ($kvResp -and ($kvResp.PSObject.Properties.Name -contains 'value') -and $kvResp.value) { $keyVaults = @($kvResp.value) }

$ssResp = Invoke-AzureApi -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Security/secureScores?api-version=2020-01-01"
$secureScorePercent = $null
if ($ssResp -and ($ssResp.PSObject.Properties.Name -contains 'value') -and $ssResp.value -and @($ssResp.value).Count -gt 0) {
    $scoreItem = @($ssResp.value)[0]
    $scoreCurrent = 0.0
    $scoreMax = 0.0
    if ($scoreItem.properties) {
        if ($scoreItem.properties.PSObject.Properties.Name -contains 'score') { $scoreCurrent = [double]$scoreItem.properties.score }
        if ($scoreItem.properties.PSObject.Properties.Name -contains 'max') { $scoreMax = [double]$scoreItem.properties.max }
    }
    if ($scoreMax -gt 0) {
        $secureScorePercent = [math]::Round(($scoreCurrent / $scoreMax) * 100, 1)
    }
}

# ---- Graph baseline ----
$org = Invoke-GraphApi -Uri "https://graph.microsoft.com/v1.0/organization?`$select=id,displayName"
$tenantName = 'Unknown tenant'
$tenantId = ''
if ($org -and $org.value -and @($org.value).Count -gt 0) {
    $tenantName = [string]@($org.value)[0].displayName
    $tenantId = [string]@($org.value)[0].id
}

$caResp = Invoke-GraphApi -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?`$top=999"
$caPolicies = @()
if ($caResp -and ($caResp.PSObject.Properties.Name -contains 'value') -and $caResp.value) { $caPolicies = @($caResp.value) }

$securityDefaults = Invoke-GraphApi -Uri "https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy"
$securityDefaultsEnabled = $false
if ($securityDefaults -and ($securityDefaults.PSObject.Properties.Name -contains 'isEnabled')) {
    $securityDefaultsEnabled = [bool]$securityDefaults.isEnabled
}

$enabledCa = @($caPolicies | Where-Object { $_.state -eq 'enabled' }).Count
$reportOnlyCa = @($caPolicies | Where-Object { $_.state -eq 'enabledForReportingButNotEnforced' }).Count
$disabledCa = @($caPolicies | Where-Object { $_.state -eq 'disabled' }).Count

# ---- Findings ----
if (-not $securityDefaultsEnabled -and $enabledCa -eq 0) {
    Add-Finding -Severity 'Critical' -Area 'Identity' -Title 'Nessuna protezione di accesso attiva' `
        -Description 'Security Defaults sono disabilitati e non risultano policy Conditional Access in stato enabled.' `
        -Remediation 'Abilitare Security Defaults oppure attivare un set minimo di policy Conditional Access (MFA, blocco legacy auth, protezione admin).'
}

if ($enabledCa -eq 0) {
    Add-Finding -Severity 'High' -Area 'Identity' -Title 'Conditional Access non applicata in enforcement' `
        -Description "Policy CA in enforcement: $enabledCa. Report-only: $reportOnlyCa. Disabled: $disabledCa." `
        -Remediation 'Portare in enabled almeno le policy baseline ad alto impatto (MFA globale/admin, legacy auth block).'
}

if ($secureScorePercent -eq $null) {
    Add-Finding -Severity 'Medium' -Area 'Azure' -Title 'Secure Score non disponibile' `
        -Description 'Non e stato possibile leggere il Secure Score di Defender for Cloud per la subscription.' `
        -Remediation 'Verificare accesso a Microsoft Defender for Cloud e permessi Reader sulla subscription.'
} elseif ($secureScorePercent -lt 45) {
    Add-Finding -Severity 'High' -Area 'Azure' -Title 'Secure Score basso' `
        -Description "Secure Score Defender for Cloud: $secureScorePercent%." `
        -Remediation 'Correggere prioritariamente le raccomandazioni ad alta severita in Defender for Cloud.'
} elseif ($secureScorePercent -lt 65) {
    Add-Finding -Severity 'Medium' -Area 'Azure' -Title 'Secure Score migliorabile' `
        -Description "Secure Score Defender for Cloud: $secureScorePercent%." `
        -Remediation 'Pianificare remediation progressiva delle raccomandazioni Medium/High per alzare il punteggio.'
}

if (@($vms).Count -gt 0 -and $enabledCa -eq 0 -and -not $securityDefaultsEnabled) {
    Add-Finding -Severity 'High' -Area 'Hybrid' -Title 'Rischio elevato su superficie combinata Identity + Workload' `
        -Description "Sono state rilevate $(@($vms).Count) VM con controlli identita deboli (assenza CA in enforcement)." `
        -Remediation 'Rinforzare prima i controlli Identity (MFA/CA), poi hardening dei workload esposti.'
}

$critCount = @($script:Findings | Where-Object { $_.Severity -eq 'Critical' }).Count
$highCount = @($script:Findings | Where-Object { $_.Severity -eq 'High' }).Count
$mediumCount = @($script:Findings | Where-Object { $_.Severity -eq 'Medium' }).Count

$summary = [ordered]@{
    TotalVMs               = @($vms).Count
    TotalStorageAccounts   = @($storageAccounts).Count
    TotalKeyVaults         = @($keyVaults).Count
    EnabledCaPolicies      = $enabledCa
    ReportOnlyCaPolicies   = $reportOnlyCa
    DisabledCaPolicies     = $disabledCa
    SecurityDefaultsEnabled = $securityDefaultsEnabled
    SecureScorePercent     = $secureScorePercent
    TotalFindings          = @($script:Findings).Count
    CriticalFindings       = $critCount
    HighFindings           = $highCount
    MediumFindings         = $mediumCount
}

$rows = ''
foreach ($f in $script:Findings) {
    $sevColor = switch ($f.Severity) {
        'Critical' { '#d13438' }
        'High' { '#f7630c' }
        'Medium' { '#ffb900' }
        default { '#0078d4' }
    }
    $rows += "<tr><td><span style='display:inline-block;padding:2px 8px;border-radius:10px;background:$sevColor;color:white;font-weight:700;font-size:11px;'>$(Escape-Html $f.Severity)</span></td><td>$(Escape-Html $f.Area)</td><td>$(Escape-Html $f.Title)</td><td>$(Escape-Html $f.Description)</td><td>$(Escape-Html $f.Remediation)</td></tr>"
}
if (-not $rows) {
    $rows = "<tr><td colspan='5'>Nessun finding critico rilevato dal controllo cloud rapido.</td></tr>"
}

$reportHtml = @"
<html>
<head>
<meta charset="utf-8" />
<title>Assessment Security M365 + Azure</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 18px; color:#1b1b1b; }
h1 { margin:0 0 8px 0; font-size: 24px; }
.meta { color:#555; margin-bottom:16px; }
.kpi { display:grid; grid-template-columns: repeat(auto-fit,minmax(170px,1fr)); gap:10px; margin-bottom:16px; }
.card { background:#f7f9fb; border:1px solid #e2e8f0; border-radius:8px; padding:10px; }
.card .t { font-size:12px; color:#5a5a5a; }
.card .v { font-size:22px; font-weight:700; margin-top:4px; }
table { width:100%; border-collapse: collapse; font-size:12px; }
th, td { border:1px solid #e2e8f0; padding:8px; text-align:left; vertical-align:top; }
th { background:#f0f4f8; }
</style>
</head>
<body>
<h1>Assessment Security M365 + Azure</h1>
<div class="meta">Tenant: <b>$(Escape-Html $tenantName)</b> | Subscription: <b>$(Escape-Html $subName)</b> | Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
<div class="kpi">
  <div class="card"><div class="t">Findings</div><div class="v">$(@($script:Findings).Count)</div></div>
  <div class="card"><div class="t">Critical</div><div class="v">$critCount</div></div>
  <div class="card"><div class="t">High</div><div class="v">$highCount</div></div>
  <div class="card"><div class="t">Secure Score</div><div class="v">$(if ($secureScorePercent -ne $null) { "$secureScorePercent%" } else { "N/A" })</div></div>
  <div class="card"><div class="t">CA Enabled</div><div class="v">$enabledCa</div></div>
  <div class="card"><div class="t">VM totali</div><div class="v">$(@($vms).Count)</div></div>
</div>
<table>
<thead><tr><th>Severity</th><th>Area</th><th>Title</th><th>Description</th><th>Remediation</th></tr></thead>
<tbody>$rows</tbody>
</table>
</body>
</html>
"@

$output = [ordered]@{
    GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Tenant = @{
        DisplayName = $tenantName
        TenantId    = $tenantId
    }
    Subscription = @{
        Id   = $SubscriptionId
        Name = $subName
    }
    Summary = $summary
    Findings = $script:Findings
    Recommendations = @($script:Findings | Select-Object Severity, Area, Title, Remediation)
    ReportHTML = $reportHtml
    DurationSeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
}

$jsonPath = [System.IO.Path]::ChangeExtension($OutputPath, '.json')
$reportHtml | Out-File -FilePath $OutputPath -Encoding utf8 -Force
($output | ConvertTo-Json -Depth 12) | Out-File -FilePath $jsonPath -Encoding utf8 -Force
