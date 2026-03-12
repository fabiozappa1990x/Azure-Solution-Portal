<#
.SYNOPSIS
Azure Virtual Desktop Deep Analysis - AI-Powered Precheck
.NOTES
Version: 1.0
Uses REST API only. Works with OAuth token from browser via Azure Function.
#>

param(
    [Parameter(Mandatory=$true)]  [string]$SubscriptionId,
    [Parameter(Mandatory=$false)] [string]$OutputPath = ".\AVD-Report.html"
)

# Azure OpenAI configuration (from env / Function App settings)
$apiKey          = $env:AZURE_OPENAI_API_KEY
$endpointBase    = $env:AZURE_OPENAI_ENDPOINT
$deploymentName  = $env:AZURE_OPENAI_DEPLOYMENT
$openAiApiVer    = if ($env:AZURE_OPENAI_API_VERSION) { $env:AZURE_OPENAI_API_VERSION } else { "2025-01-01-preview" }
$endpoint        = $null
if ($endpointBase -and $deploymentName) {
    $endpoint = ($endpointBase.TrimEnd('/') + "/openai/deployments/$deploymentName/chat/completions?api-version=$openAiApiVer")
}

$accessToken = $env:AZURE_ACCESS_TOKEN
if (-not $accessToken) { Write-Error "AZURE_ACCESS_TOKEN not found."; exit 1 }

function Invoke-AzureAPI {
    param([string]$Uri, [string]$ApiVersion = "2022-12-01", [string]$Method = "GET")
    $headers = @{ 'Authorization' = "Bearer $accessToken"; 'Content-Type' = 'application/json' }
    $fullUri = if ($Uri -like "*api-version*") { $Uri } else { "${Uri}?api-version=$ApiVersion" }
    try {
        $response = Invoke-RestMethod -Uri $fullUri -Headers $headers -Method $Method -ErrorAction Stop

        # Auto-pagination for list endpoints
        if ($Method -eq "GET" -and $response -and ($response.PSObject.Properties.Name -contains 'nextLink') -and $response.nextLink -and
            ($response.PSObject.Properties.Name -contains 'value') -and ($response.value -is [System.Collections.IEnumerable])) {
            $all = @()
            $all += @($response.value)
            $next = $response.nextLink
            $pageCount = 0
            while ($next -and $pageCount -lt 200) {
                $pageCount++
                $page = Invoke-RestMethod -Uri $next -Headers $headers -Method $Method -ErrorAction Stop
                if ($page -and ($page.PSObject.Properties.Name -contains 'value') -and $page.value) {
                    $all += @($page.value)
                }
                $next = if ($page -and ($page.PSObject.Properties.Name -contains 'nextLink')) { $page.nextLink } else { $null }
            }
            $response.value = $all
            $response.nextLink = $null
        }

        return $response
    } catch {
        Write-Warning "API failed: $fullUri - $($_.Exception.Message)"
        return $null
    }
}

$startTime = Get-Date
Write-Host "=== AVD PRECHECK START ==="

$data = @{
    Timestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Subscription   = @{}
    HostPools      = @()
    SessionHosts   = @()
    Workspaces     = @()
    AppGroups      = @()
    ScalingPlans   = @()
    VirtualNetworks = @()
    StorageAccounts = @()
    AzureVMs       = @()
    Summary        = @{}
}

# [1] Subscription
Write-Host "[1/9] Subscription..."
$sub = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId"
if ($sub) { $data.Subscription = @{ Name = $sub.displayName; Id = $sub.subscriptionId; TenantId = $sub.tenantId } }

# [2] Host Pools
Write-Host "[2/9] Host Pools..."
$hostPools = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.DesktopVirtualization/hostPools" -ApiVersion "2023-09-05"
if ($hostPools -and $hostPools.value) {
    foreach ($hp in $hostPools.value) {
        $data.HostPools += @{
            Name               = $hp.name
            ResourceGroup      = ($hp.id -split '/')[4]
            Location           = $hp.location
            HostPoolType       = $hp.properties.hostPoolType
            LoadBalancerType   = $hp.properties.loadBalancerType
            MaxSessionLimit    = $hp.properties.maxSessionLimit
            ValidationEnv      = $hp.properties.validationEnvironment
            PreferredAppGroup  = $hp.properties.preferredAppGroupType
        }
    }
    Write-Host "  Found $($data.HostPools.Count) Host Pools"
}

# [3] Session Hosts
Write-Host "[3/9] Session Hosts..."
foreach ($hp in $data.HostPools) {
    $rgName   = $hp.ResourceGroup
    $hpName   = $hp.Name
    $sessions = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$rgName/providers/Microsoft.DesktopVirtualization/hostPools/$hpName/sessionHosts" -ApiVersion "2023-09-05"
    if ($sessions -and $sessions.value) {
        foreach ($sh in $sessions.value) {
            $data.SessionHosts += @{
                HostPool         = $hpName
                Name             = $sh.name
                Status           = $sh.properties.status
                UpdateState      = $sh.properties.updateState
                AllowNewSession  = $sh.properties.allowNewSession
                Sessions         = $sh.properties.sessions
                AgentVersion     = $sh.properties.agentVersion
                OSVersion        = $sh.properties.osVersion
            }
        }
    }
}
Write-Host "  Found $($data.SessionHosts.Count) Session Hosts"

# [4] Workspaces
Write-Host "[4/9] Workspaces AVD..."
$workspaces = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.DesktopVirtualization/workspaces" -ApiVersion "2023-09-05"
if ($workspaces -and $workspaces.value) {
    foreach ($ws in $workspaces.value) {
        $data.Workspaces += @{
            Name          = $ws.name
            ResourceGroup = ($ws.id -split '/')[4]
            Location      = $ws.location
            AppGroupRefs  = $ws.properties.applicationGroupReferences
        }
    }
    Write-Host "  Found $($data.Workspaces.Count) Workspaces"
}

# [5] Application Groups
Write-Host "[5/9] Application Groups..."
$appGroups = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.DesktopVirtualization/applicationGroups" -ApiVersion "2023-09-05"
if ($appGroups -and $appGroups.value) {
    foreach ($ag in $appGroups.value) {
        $data.AppGroups += @{
            Name              = $ag.name
            ResourceGroup     = ($ag.id -split '/')[4]
            ApplicationGroupType = $ag.properties.applicationGroupType
            HostPoolArmPath   = $ag.properties.hostPoolArmPath
        }
    }
    Write-Host "  Found $($data.AppGroups.Count) App Groups"
}

# [6] Scaling Plans
Write-Host "[6/9] Scaling Plans..."
$scalingPlans = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.DesktopVirtualization/scalingPlans" -ApiVersion "2023-09-05"
if ($scalingPlans -and $scalingPlans.value) {
    foreach ($sp in $scalingPlans.value) {
        $data.ScalingPlans += @{
            Name          = $sp.name
            ResourceGroup = ($sp.id -split '/')[4]
            HostPoolType  = $sp.properties.hostPoolType
            ScheduleCount = if ($sp.properties.schedules) { $sp.properties.schedules.Count } else { 0 }
        }
    }
    Write-Host "  Found $($data.ScalingPlans.Count) Scaling Plans"
}

# [7] VNets (for AVD subnet analysis)
Write-Host "[7/9] Virtual Networks..."
$vnets = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Network/virtualNetworks" -ApiVersion "2023-05-01"
if ($vnets -and $vnets.value) {
    foreach ($vnet in $vnets.value) {
        $subnets = @()
        if ($vnet.properties.subnets) {
            foreach ($sn in $vnet.properties.subnets) {
                $subnets += @{
                    Name          = $sn.name
                    AddressPrefix = $sn.properties.addressPrefix
                    AvailableIPs  = 0  # simplified
                }
            }
        }
        $data.VirtualNetworks += @{
            Name          = $vnet.name
            ResourceGroup = ($vnet.id -split '/')[4]
            Location      = $vnet.location
            AddressSpace  = $vnet.properties.addressSpace.addressPrefixes
            SubnetCount   = $subnets.Count
            Subnets       = $subnets
        }
    }
    Write-Host "  Found $($data.VirtualNetworks.Count) VNets"
}

# [8] Storage Accounts (FSLogix candidates)
Write-Host "[8/9] Storage Accounts (FSLogix)..."
$storageAccounts = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Storage/storageAccounts" -ApiVersion "2023-01-01"
if ($storageAccounts -and $storageAccounts.value) {
    foreach ($sa in $storageAccounts.value) {
        $azureFilesEnabled = $false
        $aadKerbEnabled    = $false
        if ($sa.properties.azureFilesIdentityBasedAuthentication) {
            $authType = $sa.properties.azureFilesIdentityBasedAuthentication.directoryServiceOptions
            $aadKerbEnabled = ($authType -eq "AADKERB")
            $azureFilesEnabled = $true
        }
        $data.StorageAccounts += @{
            Name              = $sa.name
            ResourceGroup     = ($sa.id -split '/')[4]
            Location          = $sa.location
            Kind              = $sa.kind
            Sku               = $sa.sku.name
            AzureFilesEnabled = $azureFilesEnabled
            AADKerbEnabled    = $aadKerbEnabled
        }
    }
    Write-Host "  Found $($data.StorageAccounts.Count) Storage Accounts"
}

# [9] Summary
Write-Host "[9/9] Summary..."
$data.Summary = @{
    TotalHostPools        = $data.HostPools.Count
    TotalSessionHosts     = $data.SessionHosts.Count
    ActiveSessionHosts    = ($data.SessionHosts | Where-Object { $_.Status -eq "Available" }).Count
    TotalWorkspaces       = $data.Workspaces.Count
    TotalAppGroups        = $data.AppGroups.Count
    TotalScalingPlans     = $data.ScalingPlans.Count
    TotalVNets            = $data.VirtualNetworks.Count
    StorageWithFSLogix    = ($data.StorageAccounts | Where-Object { $_.AADKerbEnabled }).Count
    TotalStorageAccounts  = $data.StorageAccounts.Count
    ReadyForDeploy        = ($data.VirtualNetworks.Count -gt 0)
    AlreadyDeployed       = ($data.HostPools.Count -gt 0)
}

Import-Module (Join-Path $PSScriptRoot 'lib/EnterprisePrecheck.psm1') -Force

$checks = @()
$deployedStatus = if ($data.Summary.AlreadyDeployed) { 'Pass' } else { 'Warn' }
$deployedRationale = if ($data.Summary.AlreadyDeployed) { 'Sono presenti risorse AVD (host pool / app group / workspace).' } else { 'Nessuna risorsa AVD rilevata: scenario “greenfield”.' }
$checks += New-PrecheckCheck -Id 'avd.deployed' -Title 'AVD già presente' -Severity 'Info' -Status $deployedStatus -Rationale $deployedRationale -Remediation 'Se greenfield, definire landing zone (network/identity) e standard di naming prima del deploy.'

$networkStatus = if ($data.Summary.TotalVNets -gt 0) { 'Pass' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'avd.network' -Title 'Rete disponibile per AVD' -Severity 'Critical' -Status $networkStatus -Rationale "Virtual Networks rilevate: $($data.Summary.TotalVNets)." -Remediation 'Predisporre VNet/subnet dedicate per session host, con DNS/route/NSG coerenti.'

$fsPct = if ($data.Summary.TotalStorageAccounts -gt 0) { [math]::Round(100 * ($data.Summary.StorageWithFSLogix / $data.Summary.TotalStorageAccounts), 0) } else { 0 }
$fslogixStatus = if ($data.Summary.TotalStorageAccounts -eq 0) { 'Warn' } elseif ($data.Summary.StorageWithFSLogix -gt 0) { 'Pass' } else { 'Warn' }
$checks += New-PrecheckCheck -Id 'avd.fslogix' -Title 'Storage compatibile FSLogix (AADKERB)' -Severity 'High' -Status $fslogixStatus -Rationale "Storage account con AADKERB: $($data.Summary.StorageWithFSLogix) / $($data.Summary.TotalStorageAccounts) ($fsPct%)." -Remediation 'Per profili FSLogix su Azure Files: abilitare AADKERB/Entra integration e validare RBAC/NTFS.'

$scalingStatus = if ($data.Summary.TotalScalingPlans -gt 0) { 'Pass' } else { 'Warn' }
$checks += New-PrecheckCheck -Id 'avd.scaling' -Title 'Scaling plan' -Severity 'Medium' -Status $scalingStatus -Rationale "Scaling plans: $($data.Summary.TotalScalingPlans)." -Remediation 'Configurare scaling plan per ottimizzare i costi (schedule, cap, drain).'

$readiness = Get-PrecheckReadiness -Checks $checks
$data.Readiness = $readiness
$data.Checks = $checks
if ($data.Summary -is [hashtable]) {
    $data.Summary['ReadinessScore'] = $readiness.score
} else {
    $data.Summary | Add-Member -NotePropertyName 'ReadinessScore' -NotePropertyValue $readiness.score -Force
}

$hpRows = ($data.HostPools | Select-Object -First 30 | ForEach-Object {
    "<tr><td>$($_.Name)</td><td>$($_.ResourceGroup)</td><td>$($_.Location)</td><td>$($_.Type)</td><td>$($_.MaxSessionLimit)</td></tr>"
}) -join "`n"
$shRows = ($data.SessionHosts | Select-Object -First 40 | ForEach-Object {
    "<tr><td>$($_.HostPool)</td><td>$($_.Name)</td><td>$($_.Status)</td><td>$($_.Sessions)</td><td>$($_.AgentVersion)</td></tr>"
}) -join "`n"
$vnetRows = ($data.VirtualNetworks | Select-Object -First 30 | ForEach-Object {
    $addr = if ($_.AddressSpace -is [array]) { ($_.AddressSpace -join ', ') } else { $_.AddressSpace }
    "<tr><td>$($_.Name)</td><td>$($_.ResourceGroup)</td><td>$($_.Location)</td><td>$addr</td><td>$($_.SubnetCount)</td></tr>"
}) -join "`n"

$appendix = @"
<div>
  <h3>Appendice tecnica</h3>
  <h4>Host Pools (top 30)</h4>
  <table><thead><tr><th>Name</th><th>RG</th><th>Region</th><th>Type</th><th>MaxSessions</th></tr></thead><tbody>$hpRows</tbody></table>
  <h4>Session Hosts (top 40)</h4>
  <table><thead><tr><th>HostPool</th><th>Name</th><th>Status</th><th>Sessions</th><th>Agent</th></tr></thead><tbody>$shRows</tbody></table>
  <h4>Virtual Networks (top 30)</h4>
  <table><thead><tr><th>Name</th><th>RG</th><th>Region</th><th>AddressSpace</th><th>Subnets</th></tr></thead><tbody>$vnetRows</tbody></table>
</div>
"@

$aiPayload = @{
    solution = 'Azure Virtual Desktop'
    summary  = $data.Summary
    checks   = $checks
    hostPools = $data.HostPools | Select-Object -First 10 Name, Location, Type, MaxSessionLimit
    sessionHosts = $data.SessionHosts | Select-Object -First 10 HostPool, Name, Status, Sessions, AgentVersion
    networks = $data.VirtualNetworks | Select-Object -First 10 Name, Location, SubnetCount
}
$aiHtml = Invoke-EnterpriseOpenAIHtml -SolutionName 'Azure Virtual Desktop' -Payload $aiPayload

$kpis = @{
    Kpi1Label = 'Host Pools'
    Kpi1Value = $data.Summary.TotalHostPools
    Kpi2Label = 'Session Hosts'
    Kpi2Value = $data.Summary.TotalSessionHosts
    Kpi3Label = 'Workspaces'
    Kpi3Value = $data.Summary.TotalWorkspaces
    Kpi4Label = 'VNets'
    Kpi4Value = $data.Summary.TotalVNets
}

$guide = @()
foreach ($c in $checks) {
    if ($c.status -in @('Fail','Warn') -and $c.remediation) {
        $guide += [ordered]@{
            title = [string]$c.title
            why   = [string]$c.rationale
            how   = [string]$c.remediation
            when  = [string]$c.severity
        }
    }
}
if ($guide.Count -eq 0) { $guide += 'Nessuna azione immediata: prerequisiti AVD risultano soddisfatti. Procedere con deploy e validazione accesso utenti.' }

$htmlContent = New-EnterpriseHtmlReport -SolutionName 'Azure Virtual Desktop' -Summary $kpis -Checks $checks -ImplementationGuide $guide -AiHtml $aiHtml -LegacyHtml $appendix -Context @{
    SubscriptionName = $data.Subscription.Name
    SubscriptionId   = $SubscriptionId
    Timestamp        = $data.Timestamp
}

$htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$data['ReportHTML'] = $htmlContent
$jsonPath = $OutputPath -replace "\.html$", ".json"
$data | ConvertTo-Json -Depth 15 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Host "=== AVD PRECHECK DONE === Time: $([math]::Round(((Get-Date)-$startTime).TotalSeconds))s Readiness: $($readiness.score)%"

