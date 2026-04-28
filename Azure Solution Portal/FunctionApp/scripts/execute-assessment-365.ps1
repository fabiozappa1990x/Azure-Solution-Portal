param(
    [Parameter(Mandatory = $true)]  [string] $TenantId,
    [Parameter(Mandatory = $false)] [string] $OutputPath = ".\assessment365-report.html"
)

$ErrorActionPreference = 'Stop'
$start = Get-Date

# ------------------------------------------------------------------
# Locate bundled M365-Assess
# ------------------------------------------------------------------
$m365Root = $null
$candidates = @(
    (Join-Path $PSScriptRoot '..\modules\M365-Assess'),
    'D:\home\site\wwwroot\modules\M365-Assess',
    '/home/site/wwwroot/modules/M365-Assess'
)
foreach ($c in $candidates) {
    $resolved = [System.IO.Path]::GetFullPath($c)
    if (Test-Path (Join-Path $resolved 'Invoke-M365Assessment.ps1')) {
        $m365Root = $resolved
        break
    }
}
if (-not $m365Root) {
    throw "M365-Assess non trovato. Verificare che il deploy includa modules\M365-Assess."
}
Write-Host "M365-Assess: $m365Root"

# Unblock scripts (Zone.Identifier mark from deploy causes Test-BlockedScripts to abort)
Get-ChildItem -Path $m365Root -Recurse -Include '*.ps1','*.psm1' -ErrorAction SilentlyContinue |
    Unblock-File -ErrorAction SilentlyContinue
Write-Host "Script sbloccati."

# ------------------------------------------------------------------
# Output folder
# ------------------------------------------------------------------
$tempBase    = if ($env:TEMP) { $env:TEMP } else { '/tmp' }
$safeTenant  = $TenantId -replace '[^a-zA-Z0-9]', '_'
$tempFolder  = Join-Path $tempBase "m365assess_$safeTenant"
if (Test-Path $tempFolder) { Remove-Item $tempFolder -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -Path $tempFolder -ItemType Directory -Force | Out-Null

# ------------------------------------------------------------------
# Run M365-Assess with Managed Identity
#
# The Function App's system-assigned Managed Identity must have been
# granted the following permissions (one-time admin setup):
#
# Graph application permissions:
#   User.Read.All, UserAuthenticationMethod.Read.All,
#   Directory.Read.All, Policy.Read.All, Application.Read.All,
#   SecurityEvents.Read.All, SecurityAlert.Read.All,
#   DeviceManagementConfiguration.Read.All,
#   DeviceManagementManagedDevices.Read.All,
#   Sites.Read.All, TeamSettings.Read.All,
#   AuditLog.Read.All, Reports.Read.All,
#   RoleManagement.Read.Directory, Group.Read.All,
#   Organization.Read.All, Domain.Read.All,
#   Agreement.Read.All, TeamworkAppSettings.Read.All,
#   OrgSettings-Forms.Read.All, SharePointTenantSettings.Read.All
#
# Exchange Online (for Email section):
#   Exchange.ManageAsApp application role +
#   "Global Reader" or "Exchange Administrator" directory role
#   assigned to the Managed Identity service principal
#
# Run Grant-M365AssessPermissions.ps1 (in this folder) to set up.
# ------------------------------------------------------------------
$invokeScript = Join-Path $m365Root 'Invoke-M365Assessment.ps1'

$sections = @(
    'Tenant', 'Identity', 'Licensing',
    'Email',                              # needs EXO managed identity permission
    'Intune', 'Security', 'Collaboration',
    'Hybrid', 'ValueOpportunity'
)

Write-Host "Avvio Invoke-M365Assessment -ManagedIdentity per tenant $TenantId ..."
Write-Host "Sezioni: $($sections -join ', ')"

try {
    & $invokeScript `
        -TenantId       $TenantId `
        -ManagedIdentity `
        -Section        $sections `
        -OutputFolder   $tempFolder `
        -NonInteractive `
        -SkipPurview `
        -CompactReport
} catch {
    Write-Host "Invoke-M365Assessment errore (provo a recuperare il report parziale): $($_.Exception.Message)"
}

# ------------------------------------------------------------------
# Recover generated HTML report
# ------------------------------------------------------------------
$assessmentDir = Get-ChildItem -Path $tempFolder -Directory -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

$reportHtml = ''
if ($assessmentDir) {
    $htmlFile = Get-ChildItem -Path $assessmentDir.FullName -Filter '_Assessment-Report*.html' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($htmlFile) {
        $reportHtml = Get-Content -Path $htmlFile.FullName -Raw -Encoding UTF8
        Write-Host "Report generato: $($htmlFile.Name) ($([math]::Round($reportHtml.Length / 1KB, 1)) KB)"
    } else {
        Write-Host "WARNING: HTML report non trovato. Contenuto cartella:"
        Get-ChildItem $assessmentDir.FullName | ForEach-Object { Write-Host "  $($_.Name)" }
    }
} else {
    Write-Host "WARNING: nessuna cartella assessment in $tempFolder"
}

# ------------------------------------------------------------------
# Summary from _Assessment-Summary CSV
# ------------------------------------------------------------------
$collectors = 0; $passed = 0; $failed = 0; $skipped = 0
if ($assessmentDir) {
    $summaryFile = Get-ChildItem -Path $assessmentDir.FullName -Filter '_Assessment-Summary*.csv' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($summaryFile) {
        $rows       = Import-Csv -Path $summaryFile.FullName
        $collectors = @($rows).Count
        $passed     = @($rows | Where-Object Status -eq 'Complete').Count
        $failed     = @($rows | Where-Object Status -eq 'Failed').Count
        $skipped    = @($rows | Where-Object Status -eq 'Skipped').Count
    }
}

# ------------------------------------------------------------------
# Fallback HTML if report was not generated
# ------------------------------------------------------------------
if (-not $reportHtml) {
    $reportHtml = @"
<!DOCTYPE html><html><head><meta charset='utf-8'><title>Assessment 365 — Errore</title>
<style>body{font-family:sans-serif;padding:32px;max-width:700px;margin:0 auto;}
.alert{background:#FEF2F2;border:1px solid #FECACA;border-radius:8px;padding:20px;margin:16px 0;}
h2{color:#DC2626;}code{background:#F1F5F9;padding:2px 6px;border-radius:4px;font-size:13px;}</style>
</head><body>
<h2>&#x26A0; Report non generato</h2>
<div class='alert'>
<p><strong>Tenant:</strong> $TenantId</p>
<p><strong>Durata:</strong> $([math]::Round(((Get-Date)-$start).TotalSeconds,1))s</p>
<p><strong>Causa pi&ugrave; probabile:</strong> la Managed Identity della Function App non ha i permessi necessari su questo tenant.</p>
<p>Eseguire <code>Grant-M365AssessPermissions.ps1</code> sul tenant target e riprovare.</p>
</div>
<p>Controllare i log della Function App (Application Insights) per dettagli.</p>
</body></html>
"@
}

# ------------------------------------------------------------------
# Write output JSON (run.ps1 reads this and returns it to the frontend)
# ------------------------------------------------------------------
$jsonPath = [System.IO.Path]::ChangeExtension($OutputPath, '.json')

$output = [ordered]@{
    GeneratedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    Tenant          = @{ TenantId = $TenantId }
    Summary         = @{
        Collectors      = $collectors
        Passed          = $passed
        Failed          = $failed
        Skipped         = $skipped
        Sections        = $sections -join ', '
        DurationSeconds = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
    }
    ReportHTML      = $reportHtml
}

$reportHtml | Out-File -FilePath $OutputPath -Encoding utf8 -Force
($output | ConvertTo-Json -Depth 6 -Compress) | Out-File -FilePath $jsonPath -Encoding utf8 -Force
Write-Host "JSON scritto: $jsonPath ($([math]::Round((Get-Item $jsonPath).Length/1KB,1)) KB)"
