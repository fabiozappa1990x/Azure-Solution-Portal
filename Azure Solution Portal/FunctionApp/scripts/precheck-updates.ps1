<#
.SYNOPSIS
Azure Update Manager Deep Analysis - AI-Powered Precheck
.NOTES
Version: 1.0
Uses REST API only. Works with OAuth token from browser via Azure Function.
#>

param(
    [Parameter(Mandatory=$true)]  [string]$SubscriptionId,
    [Parameter(Mandatory=$false)] [string]$OutputPath = ".\Updates-Report.html"
)

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
Write-Host "=== UPDATE MANAGER PRECHECK START ==="

$data = @{
    Timestamp                 = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Subscription              = @{}
    MaintenanceConfigurations = @()
    AzureVMs                  = @()
    UpdatePolicyAssignments   = @()
    PendingUpdates            = @()
    Summary                   = @{}
}

# [1] Subscription
Write-Host "[1/7] Subscription..."
$sub = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId"
if ($sub) { $data.Subscription = @{ Name = $sub.displayName; Id = $sub.subscriptionId } }

# [2] Maintenance Configurations
Write-Host "[2/7] Maintenance Configurations..."
$mcList = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Maintenance/maintenanceConfigurations" -ApiVersion "2023-09-01-preview"
if ($mcList -and $mcList.value) {
    foreach ($mc in $mcList.value) {
        $window = $mc.properties.maintenanceWindow
        $data.MaintenanceConfigurations += @{
            Name          = $mc.name
            ResourceGroup = ($mc.id -split '/')[4]
            Location      = $mc.location
            Scope         = $mc.properties.maintenanceScope
            StartDateTime = $window.startDateTime
            Duration      = $window.duration
            TimeZone      = $window.timeZone
            RecurEvery    = $window.recurEvery
        }
    }
    Write-Host "  Found $($data.MaintenanceConfigurations.Count) Maintenance Configurations"
}

# [3] Azure VMs
Write-Host "[3/7] Azure VMs..."
$vms = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Compute/virtualMachines" -ApiVersion "2023-03-01"
$vmList = @()
if ($vms -and $vms.value) {
    foreach ($vm in $vms.value) {
        # Check if VM has maintenance assignment
        $patchSettings = $vm.properties.osProfile.windowsConfiguration.patchSettings
        $patchMode = if ($patchSettings) { $patchSettings.patchMode } else {
            $linuxPatch = $vm.properties.osProfile.linuxConfiguration.patchSettings
            if ($linuxPatch) { $linuxPatch.patchMode } else { "NotConfigured" }
        }
        $vmList += @{
            Name          = $vm.name
            ResourceGroup = ($vm.id -split '/')[4]
            Location      = $vm.location
            OsType        = $vm.properties.storageProfile.osDisk.osType
            PatchMode     = $patchMode
            ResourceId    = $vm.id
        }
    }
    $data.AzureVMs = $vmList
    Write-Host "  Found $($data.AzureVMs.Count) VMs"
}

# [4] Update Policy Assignments
Write-Host "[4/7] Update Manager Policies..."
$policies = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/policyAssignments" -ApiVersion "2021-06-01"
if ($policies -and $policies.value) {
    $updatePolicies = $policies.value | Where-Object { $_.properties.displayName -match "Update|Maintenance|Patch|Assessment" }
    foreach ($p in $updatePolicies) {
        $data.UpdatePolicyAssignments += @{
            Name        = $p.name
            DisplayName = $p.properties.displayName
            Enforcement = $p.properties.enforcementMode
            PolicyId    = $p.properties.policyDefinitionId
        }
    }
    Write-Host "  Found $($data.UpdatePolicyAssignments.Count) update policies"
}

# [5] Maintenance Configuration Assignments
Write-Host "[5/7] Maintenance Assignments (VMs -> MC)..."
foreach ($mc in $data.MaintenanceConfigurations) {
    $rgName = $mc.ResourceGroup
    $mcName = $mc.Name
    $assigns = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$rgName/providers/Microsoft.Maintenance/maintenanceConfigurations/$mcName/configurationAssignments" -ApiVersion "2023-09-01-preview"
    if ($assigns -and $assigns.value) {
        $mc['AssignedResourceCount'] = $assigns.value.Count
    } else {
        $mc['AssignedResourceCount'] = 0
    }
}

# [6] Update Assessment (check VMs for pending updates via Update Manager assess)
Write-Host "[6/7] Update Assessment status per VM (sample)..."
$sampleVMs = $data.AzureVMs | Select-Object -First 10
foreach ($vm in $sampleVMs) {
    $rgName = $vm.ResourceGroup
    $vmName = $vm.Name
    $assessUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$rgName/providers/Microsoft.Compute/virtualMachines/$vmName/providers/Microsoft.UpdateManager/updateAssessments?api-version=2023-04-01&`$top=5"
    $assess = Invoke-AzureAPI -Uri $assessUri -ApiVersion "2023-04-01"
    if ($assess -and $assess.value) {
        $latestAssess = $assess.value | Sort-Object { $_.properties.assessmentActivityId } | Select-Object -Last 1
        if ($latestAssess) {
            $data.PendingUpdates += @{
                VMName               = $vmName
                OsType               = $vm.OsType
                LastAssessmentTime   = $latestAssess.properties.timestamp
                CriticalUpdateCount  = $latestAssess.properties.availablePatchCountByClassification.critical
                SecurityUpdateCount  = $latestAssess.properties.availablePatchCountByClassification.security
                OtherUpdateCount     = $latestAssess.properties.availablePatchCountByClassification.other
            }
        }
    }
}
Write-Host "  Assessed $($data.PendingUpdates.Count) VMs"

# [7] Summary
Write-Host "[7/7] Summary..."
$vmsWithAutoMode    = ($data.AzureVMs | Where-Object { $_.PatchMode -eq "AutomaticByPlatform" -or $_.PatchMode -eq "AutomaticByOS" }).Count
$vmsManualMode      = ($data.AzureVMs | Where-Object { $_.PatchMode -eq "Manual" -or $_.PatchMode -eq "NotConfigured" }).Count
$totalAssigned      = ($data.MaintenanceConfigurations | Measure-Object -Property AssignedResourceCount -Sum).Sum
$criticalPending    = ($data.PendingUpdates | Measure-Object -Property CriticalUpdateCount -Sum).Sum

$data.Summary = @{
    TotalMaintenanceConfigs   = $data.MaintenanceConfigurations.Count
    TotalVMs                  = $data.AzureVMs.Count
    VMsWithAutoPatching       = $vmsWithAutoMode
    VMsWithManualPatching     = $vmsManualMode
    VMsAssignedToMC           = $totalAssigned
    TotalUpdatePolicies       = $data.UpdatePolicyAssignments.Count
    HasAssessmentPolicy       = ($data.UpdatePolicyAssignments | Where-Object { $_.DisplayName -match "assessment|Assessment" }).Count -gt 0
    HasAutoPatchPolicy        = ($data.UpdatePolicyAssignments | Where-Object { $_.DisplayName -match "patch|Patch|maintenance" }).Count -gt 0
    AssessedVMs               = $data.PendingUpdates.Count
    CriticalUpdatesPending    = $criticalPending
}

Import-Module (Join-Path $PSScriptRoot 'lib/EnterprisePrecheck.psm1') -Force

$checks = @()
$maintenanceConfigsStatus = if ($data.Summary.TotalMaintenanceConfigs -gt 0) { 'Pass' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'updates.maintenanceconfigs' -Title 'Maintenance Configurations presenti' -Severity 'High' -Status $maintenanceConfigsStatus -Rationale "Maintenance Config: $($data.Summary.TotalMaintenanceConfigs)." -Remediation 'Crea Maintenance Configuration per finestre di patching controllate (prod/non-prod).'

$autoPct = if ($data.Summary.TotalVMs -gt 0) { [math]::Round(100 * ($data.Summary.VMsWithAutoPatching / $data.Summary.TotalVMs), 1) } else { 0 }
$patchModeStatus = if ($autoPct -ge 70) { 'Pass' } elseif ($autoPct -ge 30) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'updates.patchmode' -Title 'VM in patch mode automatico' -Severity 'Critical' -Status $patchModeStatus -Rationale "Auto patching: $autoPct% (auto: $($data.Summary.VMsWithAutoPatching) / $($data.Summary.TotalVMs))." -Remediation 'Standardizza patch mode (AutomaticByPlatform/OS) e assegna le VM a Maintenance Config.'

$policiesStatus = if ($data.Summary.HasAssessmentPolicy -and $data.Summary.HasAutoPatchPolicy) { 'Pass' } elseif ($data.Summary.HasAssessmentPolicy -or $data.Summary.HasAutoPatchPolicy) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'updates.policies' -Title 'Policy di assessment/auto-patch' -Severity 'Medium' -Status $policiesStatus -Rationale "Assessment policy: $($data.Summary.HasAssessmentPolicy); Auto-patch policy: $($data.Summary.HasAutoPatchPolicy)." -Remediation 'Assegna le policy built-in per assessment periodico e patching tramite Maintenance Configuration.'

$criticalUpdatesStatus = if ($data.Summary.CriticalUpdatesPending -eq 0) { 'Pass' } elseif ($data.Summary.CriticalUpdatesPending -le 20) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'updates.critical' -Title 'Update critici pendenti' -Severity 'High' -Status $criticalUpdatesStatus -Rationale "Critical updates pendenti (somma): $($data.Summary.CriticalUpdatesPending)." -Remediation 'Pianifica remediation delle patch critiche e verifica che le VM siano valutate (assessment) regolarmente.'

$readiness = Get-PrecheckReadiness -Checks $checks
$data.Readiness = $readiness
$data.Checks = $checks
if ($data.Summary -is [hashtable]) {
    $data.Summary['ReadinessScore'] = $readiness.score
} else {
    $data.Summary | Add-Member -NotePropertyName 'ReadinessScore' -NotePropertyValue $readiness.score -Force
}

$mcRows = ($data.MaintenanceConfigurations | Select-Object -First 40 | ForEach-Object {
    "<tr><td>$($_.Name)</td><td>$($_.ResourceGroup)</td><td>$($_.Location)</td><td>$($_.RecurEvery)</td><td>$($_.AssignedResourceCount)</td></tr>"
}) -join "`n"

$pendRows = ($data.PendingUpdates | Sort-Object CriticalUpdateCount -Descending | Select-Object -First 40 | ForEach-Object {
    "<tr><td>$($_.Name)</td><td>$($_.ResourceGroup)</td><td>$($_.PatchMode)</td><td>$($_.CriticalUpdateCount)</td><td>$($_.SecurityUpdateCount)</td></tr>"
}) -join "`n"

$appendix = @"
<div>
  <h3>Appendice tecnica</h3>
  <h4>Maintenance Configurations (top 40)</h4>
  <table><thead><tr><th>Name</th><th>RG</th><th>Region</th><th>Recurrence</th><th>Assigned</th></tr></thead><tbody>$mcRows</tbody></table>
  <h4>Pending updates (top 40)</h4>
  <table><thead><tr><th>VM</th><th>RG</th><th>PatchMode</th><th>Critical</th><th>Security</th></tr></thead><tbody>$pendRows</tbody></table>
</div>
"@

$aiPayload = @{
    solution = 'Azure Update Manager'
    summary  = $data.Summary
    checks   = $checks
    maintenanceConfigurations = $data.MaintenanceConfigurations | Select-Object -First 10 Name, Location, RecurEvery, AssignedResourceCount
    topPending = $data.PendingUpdates | Sort-Object CriticalUpdateCount -Descending | Select-Object -First 15 Name, ResourceGroup, PatchMode, CriticalUpdateCount, SecurityUpdateCount
}
$aiHtml = Invoke-EnterpriseOpenAIHtml -SolutionName 'Azure Update Manager' -Payload $aiPayload

$kpis = @{
    Kpi1Label = 'Maintenance Config'
    Kpi1Value = $data.Summary.TotalMaintenanceConfigs
    Kpi2Label = 'Auto patching'
    Kpi2Value = "$autoPct%"
    Kpi3Label = 'Critical pending'
    Kpi3Value = $data.Summary.CriticalUpdatesPending
    Kpi4Label = 'Policies'
    Kpi4Value = $data.Summary.TotalUpdatePolicies
}

$htmlContent = New-EnterpriseHtmlReport -SolutionName 'Azure Update Manager' -Summary $kpis -Checks $checks -AiHtml $aiHtml -LegacyHtml $appendix -Context @{
    SubscriptionName = $data.Subscription.Name
    SubscriptionId   = $SubscriptionId
    Timestamp        = $data.Timestamp
}

$htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$data['ReportHTML'] = $htmlContent
$jsonPath = $OutputPath -replace "\.html$", ".json"
$data | ConvertTo-Json -Depth 15 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Host "=== UPDATE MANAGER PRECHECK DONE === Time: $([math]::Round(((Get-Date)-$startTime).TotalSeconds))s Readiness: $($readiness.score)%"

