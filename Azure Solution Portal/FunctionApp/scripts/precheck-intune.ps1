<#
.SYNOPSIS
Microsoft Intune Deep Analysis - App Inventory & Device Precheck
.NOTES
Version: 1.1
Uses Microsoft Graph API only (via X-Graph-Token from browser MSAL).
Inventario dispositivi gestiti, app rilevate e app deployate.
#>

param(
    [Parameter(Mandatory=$true)]  [string]$SubscriptionId,
    [Parameter(Mandatory=$false)] [string]$OutputPath = ".\Intune-Report.html"
)

$graphToken = $env:AZURE_GRAPH_TOKEN
if (-not $graphToken) { Write-Error "AZURE_GRAPH_TOKEN not found."; exit 1 }

# ----------------------------------------
# Helper: Graph API call con paginazione
# ----------------------------------------
function Invoke-GraphAPI {
    param([string]$Uri, [string]$Method = "GET")
    $headers = @{ "Authorization" = "Bearer $graphToken"; "Content-Type" = "application/json" }
    try {
        $response = Invoke-RestMethod -Uri $Uri -Headers $headers -Method $Method -ErrorAction Stop
        # Paginazione automatica (@odata.nextLink)
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
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Warning "Graph API failed [$statusCode]: $Uri - $($_.Exception.Message)"
        return $null
    }
}

$startTime = Get-Date
Write-Host "=== INTUNE PRECHECK START ==="

$data = @{
    Timestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Tenant         = @{}
    Summary        = @{}
    ManagedDevices = @()
    NonCompliantDevices = @()
    DetectedApps   = @()
    DeployedApps   = @()
    ReportHTML     = ""
}

# ----------------------------------------
# [1] Tenant info
# ----------------------------------------
Write-Host "[1/5] Tenant info..."
$org = Invoke-GraphAPI -Uri "https://graph.microsoft.com/v1.0/organization?`$select=id,displayName,verifiedDomains"
if ($org -and $org.value -and $org.value.Count -gt 0) {
    $tenantObj = $org.value[0]
    $data.Tenant = @{
        Id   = $tenantObj.id
        Name = $tenantObj.displayName
    }
    Write-Host "Tenant: $($tenantObj.displayName)"
}

# ----------------------------------------
# [2] Dispositivi gestiti Intune
# ----------------------------------------
Write-Host "[2/6] Managed devices..."
$devicesResp = Invoke-GraphAPI -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$top=500&`$select=id,deviceName,operatingSystem,osVersion,complianceState,lastSyncDateTime,manufacturer,model,userPrincipalName,enrolledDateTime,managementAgent,deviceEnrollmentType"
$rawDevices = @()
if ($devicesResp -and $devicesResp.value) { $rawDevices = @($devicesResp.value) }

$managedDevices = @()
foreach ($d in $rawDevices) {
    $lastSync = ""
    if ($d.lastSyncDateTime -and $d.lastSyncDateTime -ne "0001-01-01T00:00:00Z") {
        try { $lastSync = ([datetime]$d.lastSyncDateTime).ToString("yyyy-MM-dd HH:mm") } catch { $lastSync = $d.lastSyncDateTime }
    }
    $enrolled = ""
    if ($d.enrolledDateTime -and $d.enrolledDateTime -ne "0001-01-01T00:00:00Z") {
        try { $enrolled = ([datetime]$d.enrolledDateTime).ToString("yyyy-MM-dd") } catch { $enrolled = $d.enrolledDateTime }
    }
    $managedDevices += @{
        Id               = $d.id
        Name             = $d.deviceName
        OS               = $d.operatingSystem
        OSVersion        = $d.osVersion
        Compliance       = $d.complianceState
        LastSync         = $lastSync
        LastSyncRaw      = $d.lastSyncDateTime
        EnrolledDate     = $enrolled
        User             = $d.userPrincipalName
        Manufacturer     = $d.manufacturer
        Model            = $d.model
        ManagementAgent  = $d.managementAgent
        EnrollmentType   = $d.deviceEnrollmentType
    }
}
$data.ManagedDevices = $managedDevices
Write-Host "Devices found: $($managedDevices.Count)"

# ----------------------------------------
# [3] Analisi non conformita (dettagli policy)
# ----------------------------------------
Write-Host "[3/6] Non-compliance details..."
$nonCompliantDevices = @($managedDevices | Where-Object { $_.Compliance -eq 'noncompliant' })
$maxNonCompliantDetails = 50
$nonCompliantTruncated = $false
$reasonCounts = @{}
$nonCompliantDetails = @()

function Add-ReasonCount {
    param([string]$ReasonKey)
    if (-not $ReasonKey) { return }
    if ($reasonCounts.ContainsKey($ReasonKey)) {
        $reasonCounts[$ReasonKey] = [int]$reasonCounts[$ReasonKey] + 1
    } else {
        $reasonCounts[$ReasonKey] = 1
    }
}

foreach ($device in $nonCompliantDevices) {
    if ($nonCompliantDetails.Count -ge $maxNonCompliantDetails) { $nonCompliantTruncated = $true; break }
    $reasons = @()
    if ($device.Id) {
        $policyStates = Invoke-GraphAPI -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($device.Id)/deviceCompliancePolicyStates?`$select=displayName,state,settingStates"
        if ($policyStates -and $policyStates.value) {
            foreach ($policy in $policyStates.value) {
                $policyName = if ($policy.displayName) { $policy.displayName } else { "Policy" }
                $policyState = if ($policy.state) { $policy.state } else { "unknown" }
                if ($policy.settingStates) {
                    foreach ($s in $policy.settingStates) {
                        $state = if ($s.state) { $s.state } else { "unknown" }
                        if ($state -in @("nonCompliant","error","conflict")) {
                            $settingName = if ($s.settingName) { $s.settingName } elseif ($s.setting) { $s.setting } elseif ($s.settingDisplayName) { $s.settingDisplayName } else { "Setting" }
                            $reasonLabel = "$policyName - $settingName"
                            $reasons += "${policyName}: $settingName ($state)"
                            Add-ReasonCount -ReasonKey $reasonLabel
                        }
                    }
                } elseif ($policyState -in @("nonCompliant","error","conflict")) {
                    $reasons += "${policyName} ($policyState)"
                    Add-ReasonCount -ReasonKey $policyName
                }
            }
        }
    }
    if (-not $reasons -or $reasons.Count -eq 0) {
        $reasons = @("Motivo non disponibile")
        Add-ReasonCount -ReasonKey "Motivo non disponibile"
    }

    $nonCompliantDetails += @{
        Name            = $device.Name
        OS              = $device.OS
        OSVersion       = $device.OSVersion
        User            = $device.User
        Compliance      = $device.Compliance
        LastSync        = $device.LastSync
        EnrollmentType  = $device.EnrollmentType
        ManagementAgent = $device.ManagementAgent
        Reasons         = $reasons
    }
}
$data.NonCompliantDevices = $nonCompliantDetails

# ----------------------------------------
# [4] App rilevate sui dispositivi (detected apps)
# ----------------------------------------
Write-Host "[4/6] Detected apps..."
$detectedResp = Invoke-GraphAPI -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/detectedApps?`$top=500&`$select=id,displayName,version,publisher,deviceCount,platform,sizeInByte"
$rawDetected = @()
if ($detectedResp -and $detectedResp.value) { $rawDetected = @($detectedResp.value) }

$detectedApps = @()
foreach ($app in $rawDetected) {
    $detectedApps += @{
        DisplayName = $app.displayName
        Version     = if ($app.version) { $app.version } else { "N/A" }
        Publisher   = if ($app.publisher) { $app.publisher } else { "N/A" }
        DeviceCount = $app.deviceCount
        Platform    = if ($app.platform) { $app.platform } else { "unknown" }
        SizeMB      = if ($app.sizeInByte -and $app.sizeInByte -gt 0) { [math]::Round($app.sizeInByte / 1MB, 1) } else { 0 }
    }
}
# Ordina per numero di dispositivi descrescente
$data.DetectedApps = @($detectedApps | Sort-Object { $_.DeviceCount } -Descending)
Write-Host "Detected apps found: $($detectedApps.Count)"

# ----------------------------------------
# [5] App deployate (mobile apps / assignments)
# ----------------------------------------
Write-Host "[5/6] Deployed apps (mobile apps)..."
$mobileAppsResp = Invoke-GraphAPI -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps?`$top=500&`$select=id,displayName,publisher,createdDateTime,lastModifiedDateTime,isAssigned,publishingState,@odata.type"
$rawMobileApps = @()
if ($mobileAppsResp -and $mobileAppsResp.value) { $rawMobileApps = @($mobileAppsResp.value) }

$deployedApps = @()
foreach ($app in $rawMobileApps) {
    # Tipo leggibile dall'@odata.type
    $rawType = $app.'@odata.type'
    $appType = switch -Wildcard ($rawType) {
        "*win32LobApp*"                    { "Win32 App" }
        "*windowsMicrosoftEdgeApp*"        { "Microsoft Edge" }
        "*microsoftStoreForBusinessApp*"   { "Store for Business" }
        "*windowsUniversalAppX*"           { "Universal App (MSIX)" }
        "*windowsWebApp*"                  { "Web Link" }
        "*iosLobApp*"                      { "iOS LOB" }
        "*iosStoreApp*"                    { "iOS Store" }
        "*androidLobApp*"                  { "Android LOB" }
        "*androidStoreApp*"                { "Android Store" }
        "*managedAndroidLobApp*"           { "Android Managed" }
        "*managedIOSLobApp*"               { "iOS Managed" }
        "*officeSuiteApp*"                 { "Microsoft 365 Apps" }
        "*windowsPhone81AppX*"             { "Windows Phone" }
        "*webApp*"                         { "Web App" }
        default                            { "App" }
    }

    $modified = ""
    if ($app.lastModifiedDateTime) {
        try { $modified = ([datetime]$app.lastModifiedDateTime).ToString("yyyy-MM-dd") } catch { $modified = $app.lastModifiedDateTime }
    }

    $deployedApps += @{
        DisplayName     = $app.displayName
        Type            = $appType
        Publisher       = if ($app.publisher) { $app.publisher } else { "N/A" }
        IsAssigned      = $app.isAssigned
        PublishingState = $app.publishingState
        LastModified    = $modified
    }
}
# Ordina: prima quelli assegnati, poi per nome
$data.DeployedApps = @($deployedApps | Sort-Object { if ($_.IsAssigned) { 0 } else { 1 } }, { $_.DisplayName })
Write-Host "Deployed apps found: $($deployedApps.Count)"

# ----------------------------------------
# [6] Summary
# ----------------------------------------
Write-Host "[6/6] Computing summary..."

$totalDevices     = $managedDevices.Count
$compliantDevices = @($managedDevices | Where-Object { $_.Compliance -eq 'compliant' }).Count
$nonCompliantDevices = @($managedDevices | Where-Object { $_.Compliance -eq 'noncompliant' }).Count
$windowsDevices   = @($managedDevices | Where-Object { $_.OS -like '*Windows*' }).Count
$iosDevices       = @($managedDevices | Where-Object { $_.OS -like '*iOS*' }).Count
$androidDevices   = @($managedDevices | Where-Object { $_.OS -like '*Android*' }).Count
$macDevices       = @($managedDevices | Where-Object { $_.OS -like '*macOS*' -or $_.OS -like '*Mac*' }).Count

$totalDetected    = $detectedApps.Count
$totalDeployed    = $deployedApps.Count
$assignedApps     = @($deployedApps | Where-Object { $_.IsAssigned }).Count

$compliancePct = if ($totalDevices -gt 0) { [math]::Round(($compliantDevices / $totalDevices) * 100, 1) } else { 0 }

$staleThresholdDays = 30
$staleDevices = 0
foreach ($d in $managedDevices) {
    if ($d.LastSyncRaw) {
        try {
            $last = [datetime]$d.LastSyncRaw
            if ($last -lt (Get-Date).AddDays(-$staleThresholdDays)) { $staleDevices++ }
        } catch {
        }
    }
}

# Top motivi non conformita
$topReasons = @()
if ($reasonCounts.Keys.Count -gt 0) {
    $topReasons = $reasonCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10 | ForEach-Object {
        @{ Reason = $_.Key; Count = $_.Value }
    }
}

# ReadinessScore: considera conformità dispositivi e presenza app deployate
$readiness = 50
if ($totalDevices -gt 0) { $readiness += [math]::Min(30, [int]($compliancePct * 0.3)) }
if ($assignedApps -gt 0) { $readiness += 20 }
$readiness = [math]::Min(100, $readiness)

$data.Summary = @{
    TotalManagedDevices   = $totalDevices
    CompliantDevices      = $compliantDevices
    NonCompliantDevices   = $nonCompliantDevices
    CompliancePct         = $compliancePct
    WindowsDevices        = $windowsDevices
    iOSDevices            = $iosDevices
    AndroidDevices        = $androidDevices
    macOSDevices          = $macDevices
    TotalDetectedApps     = $totalDetected
    TotalDeployedApps     = $totalDeployed
    AssignedApps          = $assignedApps
    StaleDevicesOver30Days = $staleDevices
    NonCompliantDetailsCollected = $nonCompliantDetails.Count
    NonCompliantDetailsTruncated = $nonCompliantTruncated
    TopNonCompliantReasons = $topReasons
    ReadinessScore        = $readiness
}

# ----------------------------------------
# HTML Report
# ----------------------------------------
Write-Host "Generating HTML report..."

$tenantName = if ($data.Tenant.Name) { $data.Tenant.Name } else { "N/A" }
$timestamp  = $data.Timestamp

$complianceColor = if ($compliancePct -ge 80) { "#107c10" } elseif ($compliancePct -ge 50) { "#ff8c00" } else { "#d13438" }
$readinessColor  = if ($readiness -ge 80) { "#107c10" } elseif ($readiness -ge 60) { "#ff8c00" } else { "#d13438" }

# Tabella dispositivi (top 100)
$deviceRows = ""
$devicesToShow = if ($managedDevices.Count -gt 100) { $managedDevices[0..99] } else { $managedDevices }
foreach ($d in $devicesToShow) {
    $compColor = switch ($d.Compliance) {
        "compliant"    { "#107c10" }
        "noncompliant" { "#d13438" }
        default        { "#666666" }
    }
    $deviceRows += "<tr>
        <td>$([System.Web.HttpUtility]::HtmlEncode($d.Name))</td>
        <td>$([System.Web.HttpUtility]::HtmlEncode($d.OS))</td>
        <td>$([System.Web.HttpUtility]::HtmlEncode($d.OSVersion))</td>
        <td><span style='color:$compColor;font-weight:600'>$([System.Web.HttpUtility]::HtmlEncode($d.Compliance))</span></td>
        <td>$([System.Web.HttpUtility]::HtmlEncode($d.LastSync))</td>
        <td>$([System.Web.HttpUtility]::HtmlEncode($d.User))</td>
    </tr>"
}

# Tabella non conformi (top 50)
$nonCompliantRows = ""
$nonCompliantToShow = if ($nonCompliantDetails.Count -gt 50) { $nonCompliantDetails[0..49] } else { $nonCompliantDetails }
foreach ($d in $nonCompliantToShow) {
    $reasonsText = if ($d.Reasons -and $d.Reasons.Count -gt 0) { ($d.Reasons | Select-Object -First 5) -join "; " } else { "N/A" }
    $nonCompliantRows += "<tr>
        <td>$([System.Web.HttpUtility]::HtmlEncode($d.Name))</td>
        <td>$([System.Web.HttpUtility]::HtmlEncode($d.OS))</td>
        <td>$([System.Web.HttpUtility]::HtmlEncode($d.OSVersion))</td>
        <td>$([System.Web.HttpUtility]::HtmlEncode($d.User))</td>
        <td>$([System.Web.HttpUtility]::HtmlEncode($d.LastSync))</td>
        <td>$([System.Web.HttpUtility]::HtmlEncode($reasonsText))</td>
    </tr>"
}

# Tabella top motivi non conformita
$topReasonRows = ""
foreach ($r in $topReasons) {
    $topReasonRows += "<tr>
        <td>$([System.Web.HttpUtility]::HtmlEncode($r.Reason))</td>
        <td><strong>$($r.Count)</strong></td>
    </tr>"
}
if (-not $topReasonRows) {
    $topReasonRows = "<tr><td>N/A</td><td>0</td></tr>"
}

# Tabella app rilevate (top 50 per device count)
$appRows = ""
$appsToShow = if ($data.DetectedApps.Count -gt 50) { $data.DetectedApps[0..49] } else { $data.DetectedApps }
foreach ($app in $appsToShow) {
    $appRows += "<tr>
        <td>$([System.Web.HttpUtility]::HtmlEncode($app.DisplayName))</td>
        <td>$([System.Web.HttpUtility]::HtmlEncode($app.Version))</td>
        <td>$([System.Web.HttpUtility]::HtmlEncode($app.Publisher))</td>
        <td><strong>$($app.DeviceCount)</strong></td>
        <td>$([System.Web.HttpUtility]::HtmlEncode($app.Platform))</td>
    </tr>"
}

# Tabella app deployate
$deployRows = ""
foreach ($app in $data.DeployedApps) {
    $assignedLabel = if ($app.IsAssigned) { "<span style='color:#107c10;font-weight:600'>Si</span>" } else { "<span style='color:#666'>No</span>" }
    $stateColor = switch ($app.PublishingState) {
        "published" { "#107c10" }
        "processing" { "#ff8c00" }
        default { "#666666" }
    }
    $deployRows += "<tr>
        <td>$([System.Web.HttpUtility]::HtmlEncode($app.DisplayName))</td>
        <td>$([System.Web.HttpUtility]::HtmlEncode($app.Type))</td>
        <td>$([System.Web.HttpUtility]::HtmlEncode($app.Publisher))</td>
        <td>$assignedLabel</td>
        <td><span style='color:$stateColor'>$([System.Web.HttpUtility]::HtmlEncode($app.PublishingState))</span></td>
        <td>$([System.Web.HttpUtility]::HtmlEncode($app.LastModified))</td>
    </tr>"
}

$deviceNote = if ($managedDevices.Count -gt 100) { "<p style='color:#666;font-size:12px'>Mostrati i primi 100 di $totalDevices dispositivi.</p>" } else { "" }
$appNote    = if ($data.DetectedApps.Count -gt 50) { "<p style='color:#666;font-size:12px'>Mostrate le prime 50 app per numero di dispositivi (su $totalDetected totali).</p>" } else { "" }
$nonCompliantNote = if ($nonCompliantDetails.Count -gt 50) { "<p style='color:#666;font-size:12px'>Mostrati i primi 50 dispositivi non conformi.</p>" } else { "" }

$reportHtml = @"
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="UTF-8">
<title>Intune Precheck Report</title>
<style>
  body { font-family: 'Segoe UI', sans-serif; margin: 0; padding: 20px; background: #f5f5f5; color: #333; }
  .report-header { background: linear-gradient(135deg, #0078d4, #005a9e); color: white; padding: 24px 28px; border-radius: 8px; margin-bottom: 24px; }
  .report-header h1 { margin: 0 0 6px; font-size: 22px; }
  .report-header p { margin: 0; opacity: 0.85; font-size: 13px; }
  .kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 14px; margin-bottom: 24px; }
  .kpi-card { background: white; border-radius: 8px; padding: 16px; text-align: center; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }
  .kpi-value { font-size: 28px; font-weight: 700; color: #0078d4; }
  .kpi-label { font-size: 12px; color: #666; margin-top: 4px; }
  .section { background: white; border-radius: 8px; padding: 20px; margin-bottom: 20px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }
  .section h2 { margin: 0 0 16px; font-size: 16px; color: #0078d4; border-bottom: 2px solid #e0e0e0; padding-bottom: 8px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { background: #f0f6ff; color: #0078d4; padding: 8px 10px; text-align: left; border-bottom: 2px solid #cce0ff; font-weight: 600; }
  td { padding: 7px 10px; border-bottom: 1px solid #f0f0f0; vertical-align: middle; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: #fafbff; }
  .os-badge { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 11px; font-weight: 600; background: #e3f2fd; color: #0078d4; }
  .footer { text-align: center; color: #999; font-size: 11px; margin-top: 16px; }
</style>
</head>
<body>
<div class="report-header">
  <h1>Microsoft Intune — Report di Analisi</h1>
  <p>Tenant: <strong>$tenantName</strong> &nbsp;|&nbsp; Generato il: $timestamp</p>
</div>

<div class="kpi-grid">
  <div class="kpi-card">
    <div class="kpi-value">$totalDevices</div>
    <div class="kpi-label">Dispositivi Gestiti</div>
  </div>
  <div class="kpi-card">
    <div class="kpi-value" style="color:$complianceColor">$compliantDevices</div>
    <div class="kpi-label">Conformi ($compliancePct%)</div>
  </div>
  <div class="kpi-card">
    <div class="kpi-value" style="color:#d13438">$nonCompliantDevices</div>
    <div class="kpi-label">Non Conformi</div>
  </div>
  <div class="kpi-card">
    <div class="kpi-value">$totalDetected</div>
    <div class="kpi-label">App Rilevate</div>
  </div>
  <div class="kpi-card">
    <div class="kpi-value">$totalDeployed</div>
    <div class="kpi-label">App Deployate</div>
  </div>
  <div class="kpi-card">
    <div class="kpi-value" style="color:$readinessColor">$readiness%</div>
    <div class="kpi-label">Readiness Score</div>
  </div>
</div>

<div class="kpi-grid">
  <div class="kpi-card">
    <div class="kpi-value">$windowsDevices</div>
    <div class="kpi-label">Windows</div>
  </div>
  <div class="kpi-card">
    <div class="kpi-value">$iosDevices</div>
    <div class="kpi-label">iOS</div>
  </div>
  <div class="kpi-card">
    <div class="kpi-value">$androidDevices</div>
    <div class="kpi-label">Android</div>
  </div>
  <div class="kpi-card">
    <div class="kpi-value">$macDevices</div>
    <div class="kpi-label">macOS</div>
  </div>
  <div class="kpi-card">
    <div class="kpi-value">$assignedApps</div>
    <div class="kpi-label">App Assegnate</div>
  </div>
  <div class="kpi-card">
    <div class="kpi-value" style="color:#d13438">$staleDevices</div>
    <div class="kpi-label">Sync &gt; $staleThresholdDays g</div>
  </div>
</div>

<div class="section">
  <h2>Dispositivi Gestiti</h2>
  $deviceNote
  <table>
    <thead><tr><th>Nome Dispositivo</th><th>OS</th><th>Versione OS</th><th>Conformita</th><th>Ultimo Sync</th><th>Utente</th></tr></thead>
    <tbody>$deviceRows</tbody>
  </table>
</div>

<div class="section">
  <h2>Top Motivi di Non Conformita</h2>
  <table>
    <thead><tr><th>Motivo</th><th>Conteggio</th></tr></thead>
    <tbody>$topReasonRows</tbody>
  </table>
</div>

<div class="section">
  <h2>Dispositivi Non Conformi (motivi principali)</h2>
  $nonCompliantNote
  <table>
    <thead><tr><th>Nome Dispositivo</th><th>OS</th><th>Versione OS</th><th>Utente</th><th>Ultimo Sync</th><th>Motivi</th></tr></thead>
    <tbody>$nonCompliantRows</tbody>
  </table>
</div>

<div class="section">
  <h2>App Rilevate sui Dispositivi (top per diffusione)</h2>
  $appNote
  <table>
    <thead><tr><th>Nome App</th><th>Versione</th><th>Publisher</th><th>N. Dispositivi</th><th>Piattaforma</th></tr></thead>
    <tbody>$appRows</tbody>
  </table>
</div>

<div class="section">
  <h2>App Deployate in Intune</h2>
  <table>
    <thead><tr><th>Nome App</th><th>Tipo</th><th>Publisher</th><th>Assegnata</th><th>Stato</th><th>Ultima Modifica</th></tr></thead>
    <tbody>$deployRows</tbody>
  </table>
</div>

<div class="footer">Report generato da Azure Solution Portal &mdash; Microsoft Intune Precheck v1.1</div>
</body>
</html>
"@

$data.ReportHTML = $reportHtml

# ----------------------------------------
# Output JSON + HTML
# ----------------------------------------
$tempDir = if ($env:TEMP) { $env:TEMP } else { '/tmp' }
$jsonPath = [System.IO.Path]::ChangeExtension($OutputPath, ".json")
if (-not [System.IO.Path]::IsPathRooted($jsonPath)) {
    $jsonPath = Join-Path $tempDir ("intune_report_" + $SubscriptionId + ".json")
}
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $tempDir ("intune_report_" + $SubscriptionId + ".html")
}

$data | ConvertTo-Json -Depth 10 -Compress | Set-Content -Path $jsonPath -Encoding UTF8
$reportHtml | Set-Content -Path $OutputPath -Encoding UTF8

$elapsed = (Get-Date) - $startTime
Write-Host "=== INTUNE PRECHECK DONE in $([math]::Round($elapsed.TotalSeconds,1))s ==="
Write-Host "JSON: $jsonPath"
Write-Host "HTML: $OutputPath"
