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

$script:GraphErrors = @()
$script:EndpointStatus = @{}

function Set-EndpointStatus {
    param(
        [string]$Label,
        [string]$Status,
        [int]$StatusCode = 0,
        [int]$Records = 0
    )
    if (-not $Label) { return }
    $script:EndpointStatus[$Label] = @{
        Label      = $Label
        Status     = $Status
        StatusCode = $StatusCode
        Records    = $Records
    }
}

function Get-CompliancePlatform {
    param($Policy)
    $t = ""
    try { $t = "$($Policy.OdataType)".ToLowerInvariant() } catch { $t = "" }
    if ($t -like '*windows*') { return 'windows' }
    if ($t -like '*ios*' -or $t -like '*ipad*') { return 'ios' }
    if ($t -like '*android*') { return 'android' }
    if ($t -like '*mac*') { return 'macos' }
    return 'other'
}

function Get-ConfigPlatform {
    param($Profile)
    $src = ""
    $type = ""
    try { $src = "$($Profile.Source)".ToLowerInvariant() } catch { $src = "" }
    try { $type = "$($Profile.OdataType)".ToLowerInvariant() } catch { $type = "" }

    if ($Profile.Platforms -and @($Profile.Platforms).Count -gt 0) {
        $all = @($Profile.Platforms) | ForEach-Object { "$_".ToLowerInvariant() }
        if ($all -contains 'windows10' -or $all -contains 'windows11' -or $all -contains 'windows') { return 'windows' }
        if ($all -contains 'ios' -or $all -contains 'ipados') { return 'ios' }
        if ($all -contains 'android' -or $all -contains 'androidforwork') { return 'android' }
        if ($all -contains 'macos') { return 'macos' }
    }

    if ($src -eq 'grouppolicyconfigurations') { return 'windows' }
    if ($type -like '*windows*') { return 'windows' }
    if ($type -like '*ios*' -or $type -like '*ipad*') { return 'ios' }
    if ($type -like '*android*') { return 'android' }
    if ($type -like '*mac*') { return 'macos' }
    return 'other'
}

function Is-ConfiguredValue {
    param($Value)
    if ($null -eq $Value) { return $false }

    if ($Value -is [bool]) { return [bool]$Value }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return ([double]$Value -gt 0)
    }

    if ($Value -is [string]) {
        $v = $Value.Trim()
        if (-not $v) { return $false }
        $n = $v.ToLowerInvariant()
        if ($n -in @('notconfigured','none','unknown','false','0','disabled','notset')) { return $false }
        return $true
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        try { return (@($Value).Count -gt 0) } catch { return $false }
    }

    return $true
}

function Get-ConfiguredSettingsCount {
    param(
        $Object,
        [string[]]$ExcludeProperties = @()
    )
    if (-not $Object) { return 0 }
    $count = 0
    foreach ($prop in $Object.PSObject.Properties) {
        $name = $prop.Name
        if ($ExcludeProperties -contains $name) { continue }
        if ($name -like '@odata*') { continue }
        if (Is-ConfiguredValue -Value $prop.Value) { $count++ }
    }
    return $count
}

function Get-EndpointValueCount {
    param(
        [string]$Label,
        [string]$Uri
    )
    $r = Invoke-GraphAPI -Label $Label -Uri $Uri
    if ($r -and $r.value) { return @($r.value).Count }
    return 0
}

# ----------------------------------------
# Helper: Graph API call con paginazione
# ----------------------------------------
function Invoke-GraphAPI {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [string]$Label = ""
    )
    $headers = @{ "Authorization" = "Bearer $graphToken"; "Content-Type" = "application/json" }
    if (-not $Label) { $Label = $Uri }
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
        $records = if ($response -and $response.value) { @($response.value).Count } elseif ($null -ne $response) { 1 } else { 0 }
        Set-EndpointStatus -Label $Label -Status 'ok' -StatusCode 200 -Records $records
        return $response
    } catch {
        $statusCode = 0
        try { $statusCode = [int]$_.Exception.Response.StatusCode.value__ } catch { $statusCode = 0 }
        Set-EndpointStatus -Label $Label -Status 'error' -StatusCode $statusCode -Records 0
        $script:GraphErrors += @{
            Endpoint   = $Label
            Uri        = $Uri
            StatusCode = $statusCode
            Message    = $_.Exception.Message
        }
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
    ExistingCompliancePolicies = @()
    ExistingConfigProfiles     = @()
    ReportHTML     = ""
}

# ----------------------------------------
# [1] Tenant info
# ----------------------------------------
Write-Host "[1/5] Tenant info..."
$org = Invoke-GraphAPI -Label "Organization" -Uri "https://graph.microsoft.com/v1.0/organization?`$select=id,displayName,verifiedDomains"
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
$devicesResp = Invoke-GraphAPI -Label "ManagedDevices" -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$top=500&`$select=id,deviceName,operatingSystem,osVersion,complianceState,lastSyncDateTime,manufacturer,model,userPrincipalName,enrolledDateTime,managementAgent,deviceEnrollmentType"
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
# [3] Non conformi: solo lista, nessuna chiamata per-device (troppo lenta)
# ----------------------------------------
Write-Host "[3/6] Non-compliance summary (no per-device API calls)..."
$nonCompliantDevicesList = @($managedDevices | Where-Object { $_.Compliance -eq 'noncompliant' })
$nonCompliantTruncated = $false
$reasonCounts = @{}
$nonCompliantDetails = @()

$maxNonCompliantDetails = 50
foreach ($device in $nonCompliantDevicesList) {
    if ($nonCompliantDetails.Count -ge $maxNonCompliantDetails) { $nonCompliantTruncated = $true; break }
    $nonCompliantDetails += @{
        Name            = $device.Name
        OS              = $device.OS
        OSVersion       = $device.OSVersion
        User            = $device.User
        Compliance      = $device.Compliance
        LastSync        = $device.LastSync
        EnrollmentType  = $device.EnrollmentType
        ManagementAgent = $device.ManagementAgent
        Reasons         = @("Dettaglio non disponibile in modalità rapida")
    }
}
$data.NonCompliantDevices = $nonCompliantDetails

# ----------------------------------------
# [4] App rilevate sui dispositivi (detected apps)
# ----------------------------------------
Write-Host "[4/6] Detected apps..."
$detectedResp = Invoke-GraphAPI -Label "DetectedApps(v1)" -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/detectedApps?`$top=500&`$select=id,displayName,version,publisher,deviceCount,platform,sizeInByte"
if (-not $detectedResp -or -not $detectedResp.value -or @($detectedResp.value).Count -eq 0) {
    $detectedResp = Invoke-GraphAPI -Label "DetectedApps(beta)" -Uri "https://graph.microsoft.com/beta/deviceAppManagement/detectedApps?`$top=500&`$select=id,displayName,version,publisher,deviceCount,platform,sizeInByte"
}
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
$mobileAppsResp = Invoke-GraphAPI -Label "MobileApps(v1)" -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps?`$top=500&`$select=id,displayName,publisher,createdDateTime,lastModifiedDateTime,isAssigned,publishingState,@odata.type"
if (-not $mobileAppsResp -or -not $mobileAppsResp.value -or @($mobileAppsResp.value).Count -eq 0) {
    $mobileAppsResp = Invoke-GraphAPI -Label "MobileApps(beta)" -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=500&`$select=id,displayName,publisher,createdDateTime,lastModifiedDateTime,isAssigned,publishingState,@odata.type"
}
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
# [5b] Compliance policy — una sola chiamata con $expand=assignments
# ----------------------------------------
Write-Host "[5b] Existing compliance policies (expand=assignments)..."
# $expand=assignments restituisce le assegnazioni inline: zero chiamate N+1
$compPoliciesResp = Invoke-GraphAPI -Label "CompliancePolicies" -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies?`$top=500&`$expand=assignments"
$existingCompPolicies = @()
if ($compPoliciesResp -and $compPoliciesResp.value) {
    foreach ($p in $compPoliciesResp.value) {
        $platform  = Get-CompliancePlatform -Policy @{ OdataType = $p.'@odata.type' }
        $assignCount = if ($p.assignments) { @($p.assignments).Count } else { 0 }
        $notes = @()
        if ($assignCount -le 0) { $notes += 'Non assegnata' }
        $existingCompPolicies += @{
            Id               = $p.id
            DisplayName      = $p.displayName
            OdataType        = $p.'@odata.type'
            LastModified     = $p.lastModifiedDateTime
            Platform         = $platform
            AssignmentCount  = $assignCount
            IsAssigned       = ($assignCount -gt 0)
            ConfiguredSettings = 0
            Assessment       = if ($assignCount -gt 0) { 'OK' } else { 'WARN' }
            Findings         = ($notes -join '; ')
        }
    }
}
$data.ExistingCompliancePolicies = $existingCompPolicies
Write-Host "Existing compliance policies: $($existingCompPolicies.Count)"

# ----------------------------------------
# [5c] Configuration profiles — una sola chiamata per endpoint con $expand=assignments
# ----------------------------------------
Write-Host "[5c] Existing config profiles (expand=assignments)..."

$legacyConfigProfilesResp = Invoke-GraphAPI -Label "DeviceConfigurations" -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations?`$top=500&`$expand=assignments"
$settingsCatalogResp      = Invoke-GraphAPI -Label "ConfigurationPolicies" -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$top=500&`$expand=assignments"
$adminTemplatesResp       = Invoke-GraphAPI -Label "GroupPolicyConfigurations" -Uri "https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations?`$top=500&`$expand=assignments"

$existingConfigProfiles = @()

if ($legacyConfigProfilesResp -and $legacyConfigProfilesResp.value) {
    foreach ($p in $legacyConfigProfilesResp.value) {
        $assignCount = if ($p.assignments) { @($p.assignments).Count } else { 0 }
        $findings = @()
        if ($assignCount -le 0) { $findings += 'Profile non assegnato' }
        $existingConfigProfiles += @{
            Id               = $p.id
            DisplayName      = $p.displayName
            OdataType        = $p.'@odata.type'
            Source           = 'deviceConfigurations'
            LastModified     = $p.lastModifiedDateTime
            AssignmentCount  = $assignCount
            IsAssigned       = ($assignCount -gt 0)
            ConfiguredSettings = 0
            Assessment       = if ($assignCount -gt 0) { 'OK' } else { 'WARN' }
            Findings         = ($findings -join '; ')
        }
    }
}

if ($settingsCatalogResp -and $settingsCatalogResp.value) {
    foreach ($p in $settingsCatalogResp.value) {
        $assignCount = if ($p.assignments) { @($p.assignments).Count } else { 0 }
        $findings = @()
        if ($assignCount -le 0) { $findings += 'Policy non assegnata' }
        $existingConfigProfiles += @{
            Id               = $p.id
            DisplayName      = if ($p.name) { $p.name } else { $p.displayName }
            OdataType        = if ($p.'@odata.type') { $p.'@odata.type' } else { '#microsoft.graph.deviceManagementConfigurationPolicy' }
            Source           = 'configurationPolicies'
            Platforms        = if ($p.platforms) { @($p.platforms) } else { @() }
            Technologies     = if ($p.technologies) { @($p.technologies) } else { @() }
            LastModified     = $p.lastModifiedDateTime
            AssignmentCount  = $assignCount
            IsAssigned       = ($assignCount -gt 0)
            ConfiguredSettings = 0
            Assessment       = if ($assignCount -gt 0) { 'OK' } else { 'WARN' }
            Findings         = ($findings -join '; ')
        }
    }
}

if ($adminTemplatesResp -and $adminTemplatesResp.value) {
    foreach ($p in $adminTemplatesResp.value) {
        $assignCount = if ($p.assignments) { @($p.assignments).Count } else { 0 }
        $findings = @()
        if ($assignCount -le 0) { $findings += 'Template non assegnato' }
        $existingConfigProfiles += @{
            Id               = $p.id
            DisplayName      = $p.displayName
            OdataType        = '#microsoft.graph.groupPolicyConfiguration'
            Source           = 'groupPolicyConfigurations'
            LastModified     = $p.lastModifiedDateTime
            AssignmentCount  = $assignCount
            IsAssigned       = ($assignCount -gt 0)
            ConfiguredSettings = 0
            Assessment       = if ($assignCount -gt 0) { 'OK' } else { 'WARN' }
            Findings         = ($findings -join '; ')
        }
    }
}

# Dedup per Id
$dedupById = @{}
foreach ($p in $existingConfigProfiles) {
    if (-not $p.Id) { continue }
    if (-not $dedupById.ContainsKey($p.Id)) { $dedupById[$p.Id] = $p }
}
$data.ExistingConfigProfiles = @($dedupById.Values)
Write-Host "Existing config profiles: $($data.ExistingConfigProfiles.Count)"

$statusValues = @($script:EndpointStatus.Values)
$status403 = @($statusValues | Where-Object { $_.StatusCode -eq 403 }).Count
$status401 = @($statusValues | Where-Object { $_.StatusCode -eq 401 }).Count
$hints = @()
if ($status403 -gt 0) { $hints += "Alcuni endpoint Graph hanno risposto 403 (permessi mancanti su Intune/Graph o admin consent non concesso)." }
if ($status401 -gt 0) { $hints += "Alcuni endpoint Graph hanno risposto 401 (token scaduto/non valido)." }
if ($data.ManagedDevices.Count -eq 0 -and $statusValues.Count -gt 0 -and @($statusValues | Where-Object { $_.Label -like 'ManagedDevices*' -and $_.Status -eq 'error' }).Count -gt 0) { $hints += "Nessun dispositivo rilevato perché la lettura ManagedDevices fallisce." }
if ($data.DetectedApps.Count -eq 0 -and @($statusValues | Where-Object { $_.Label -like 'DetectedApps*' -and $_.Status -eq 'error' }).Count -gt 0) { $hints += "Nessuna app rilevata perché l'endpoint DetectedApps non è accessibile." }
if ($data.DeployedApps.Count -eq 0 -and @($statusValues | Where-Object { $_.Label -like 'MobileApps*' -and $_.Status -eq 'error' }).Count -gt 0) { $hints += "Nessuna app deployata rilevata perché l'endpoint MobileApps non è accessibile." }

$data.Diagnostics = @{
    GraphErrors         = $script:GraphErrors
    EndpointStatus      = $statusValues
    PermissionHints     = $hints
    ErrorCount          = @($script:GraphErrors).Count
    EndpointErrorCount  = @($statusValues | Where-Object { $_.Status -eq 'error' }).Count
}

# Inventory e BestPracticeChecks vengono calcolati DOPO il Summary (dopo che $windowsDevices ecc. sono definiti)

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

# ----------------------------------------
# Inventory e Best Practice Checks (qui tutte le variabili sono definite)
# ----------------------------------------
$deviceByPlatform = @{
    windows = [int]$windowsDevices
    ios     = [int]$iosDevices
    android = [int]$androidDevices
    macos   = [int]$macDevices
    other   = [math]::Max(0, [int]($totalDevices - $windowsDevices - $iosDevices - $androidDevices - $macDevices))
}

$complianceByPlatform = @{ windows = 0; ios = 0; android = 0; macos = 0; other = 0 }
foreach ($p in $existingCompPolicies) {
    $k = Get-CompliancePlatform -Policy $p
    if (-not $complianceByPlatform.ContainsKey($k)) { $k = 'other' }
    $complianceByPlatform[$k] = [int]$complianceByPlatform[$k] + 1
}

$configByPlatform = @{ windows = 0; ios = 0; android = 0; macos = 0; other = 0 }
$configBySource   = @{ deviceConfigurations = 0; configurationPolicies = 0; groupPolicyConfigurations = 0; other = 0 }
foreach ($p in $data.ExistingConfigProfiles) {
    $k = Get-ConfigPlatform -Profile $p
    if (-not $configByPlatform.ContainsKey($k)) { $k = 'other' }
    $configByPlatform[$k] = [int]$configByPlatform[$k] + 1
    $src = if ($p.Source) { "$($p.Source)" } else { 'other' }
    if (-not $configBySource.ContainsKey($src)) { $src = 'other' }
    $configBySource[$src] = [int]$configBySource[$src] + 1
}

$requiredPlatforms = @()
foreach ($pk in @('windows','ios','android','macos')) {
    if ([int]$deviceByPlatform[$pk] -gt 0) { $requiredPlatforms += $pk }
}
if ($requiredPlatforms.Count -eq 0) { $requiredPlatforms = @('windows','ios','android','macos') }

# BestPracticeChecks — uso array script-scope per evitare bug di scope in funzione
$bestPracticeChecks = [System.Collections.Generic.List[hashtable]]::new()

$bestPracticeChecks.Add(@{ Id='graph-endpoints';           Area='Permissions';    Title='Endpoint Graph accessibili per il precheck';                    Passed=($data.Diagnostics.EndpointErrorCount -eq 0); Severity='critical'; Status=if($data.Diagnostics.EndpointErrorCount -eq 0){'OK'}else{'MISSING'}; Recommendation='Concedere admin consent alle permission Intune Graph richieste e riautenticarsi.'; DeployHint='Verifica App Registration e consenso admin.' })
$bestPracticeChecks.Add(@{ Id='has-compliance-policies';   Area='Compliance';     Title='Almeno una Compliance Policy presente nel tenant';              Passed=($existingCompPolicies.Count -gt 0); Severity='critical'; Status=if($existingCompPolicies.Count -gt 0){'OK'}else{'MISSING'}; Recommendation='Creare almeno una compliance policy baseline per piattaforma.'; DeployHint='Usare Configura Baseline Intune.' })
$bestPracticeChecks.Add(@{ Id='has-config-profiles';       Area='Configuration';  Title='Almeno un Configuration Profile presente nel tenant';           Passed=($data.ExistingConfigProfiles.Count -gt 0); Severity='critical'; Status=if($data.ExistingConfigProfiles.Count -gt 0){'OK'}else{'MISSING'}; Recommendation='Creare configuration profiles (Settings Catalog / templates) baseline.'; DeployHint='Usare Configura Baseline Intune.' })
$bestPracticeChecks.Add(@{ Id='has-assigned-apps';         Area='Applications';   Title='Almeno una app assegnata in Intune';                            Passed=($assignedApps -gt 0); Severity='warning'; Status=if($assignedApps -gt 0){'OK'}else{'MISSING'}; Recommendation='Pubblicare e assegnare app core (M365, browser, agent, security tooling).'; DeployHint='Rivedere tab App Deployate e assignments.' })
$bestPracticeChecks.Add(@{ Id='device-compliance-target';  Area='Compliance';     Title='Conformità dispositivi >= 80%';                                 Passed=($compliancePct -ge 80); Severity='warning'; Status=if($compliancePct -ge 80){'OK'}else{'MISSING'}; Recommendation='Indagare i motivi di non conformità e correggere policy/assegnazioni.'; DeployHint='Controllare tab dispositivi e motivi non conformità.' })

foreach ($pk in $requiredPlatforms) {
    $bestPracticeChecks.Add(@{ Id="platform-$pk-compliance"; Area="Platform/$pk"; Title="Policy di compliance presenti per piattaforma $pk"; Passed=([int]$complianceByPlatform[$pk] -gt 0); Severity='critical'; Status=if([int]$complianceByPlatform[$pk] -gt 0){'OK'}else{'MISSING'}; Recommendation="Definire almeno una compliance policy per $pk."; DeployHint='Usare Configura Baseline Intune (platform-aware).' })
    $bestPracticeChecks.Add(@{ Id="platform-$pk-config";     Area="Platform/$pk"; Title="Configuration profile presenti per piattaforma $pk"; Passed=([int]$configByPlatform[$pk] -gt 0); Severity='warning'; Status=if([int]$configByPlatform[$pk] -gt 0){'OK'}else{'MISSING'}; Recommendation="Definire almeno un configuration profile per $pk."; DeployHint='Usare Configura Baseline Intune (platform-aware).' })
}

$data.Inventory = @{
    DevicesByPlatform        = $deviceByPlatform
    ComplianceByPlatform     = $complianceByPlatform
    ConfigProfilesByPlatform = $configByPlatform
    ConfigProfilesBySource   = $configBySource
    RequiredPlatforms        = $requiredPlatforms
}
$data.BestPracticeChecks = @($bestPracticeChecks)

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
    ExistingCompliancePolicies = $existingCompPolicies.Count
    ExistingConfigProfiles     = $data.ExistingConfigProfiles.Count
    BestPracticeChecksTotal    = $bestPracticeChecks.Count
    BestPracticeChecksPassed   = @($bestPracticeChecks | Where-Object { $_.Passed }).Count
    BestPracticeChecksMissing  = @($bestPracticeChecks | Where-Object { -not $_.Passed }).Count
    StaleDevicesOver30Days = $staleDevices
    NonCompliantDetailsCollected = $nonCompliantDetails.Count
    NonCompliantDetailsTruncated = $nonCompliantTruncated
    TopNonCompliantReasons = $topReasons
    GraphEndpointErrors   = $data.Diagnostics.EndpointErrorCount
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
