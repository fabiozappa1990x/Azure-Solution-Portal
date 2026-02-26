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

$apiKey   = "1pN5y5zgK2iSmWhNNFrA0UpNX5krFMI10mz8A6XWFb9gXLs0Kvw2JQQJ99BJACYeBjFXJ3w3AAAAACOGR3VY"
$endpoint = "https://openaitestluca.cognitiveservices.azure.com/openai/deployments/AVM/chat/completions?api-version=2025-01-01-preview"

$accessToken = $env:AZURE_ACCESS_TOKEN
if (-not $accessToken) { Write-Error "AZURE_ACCESS_TOKEN not found."; exit 1 }

function Invoke-AzureAPI {
    param([string]$Uri, [string]$ApiVersion = "2022-12-01", [string]$Method = "GET")
    $headers = @{ 'Authorization' = "Bearer $accessToken"; 'Content-Type' = 'application/json' }
    $fullUri = if ($Uri -like "*api-version*") { $Uri } else { "${Uri}?api-version=$ApiVersion" }
    try {
        return Invoke-RestMethod -Uri $fullUri -Headers $headers -Method $Method -ErrorAction Stop
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

# === AI ANALYSIS ===
Write-Host "=== AI ANALYSIS ==="
$dataJson = $data | ConvertTo-Json -Depth 8 -Compress

$prompt = @"
Analizza questi dati Azure Update Manager e genera un report DETTAGLIATO in ITALIANO in formato HTML.

DATI:
$dataJson

GENERA SEZIONI HTML CON:
1. EXECUTIVE SUMMARY (maturità patch management, finestre di manutenzione configurate, VM non gestite)
2. MAINTENANCE CONFIGURATIONS (finestre configurate, schedule, VM assegnate)
3. PATCH MODE VMs (AutomaticByPlatform vs Manual vs NotConfigured con risk assessment)
4. AGGIORNAMENTI IN SOSPESO (VM con patch critiche non installate, security risk)
5. POLICY DI AGGIORNAMENTO (assessment periodico, auto-patching scope)
6. RACCOMANDAZIONI PRIORITARIE (TOP 8 azioni per centralizzare il patch management)

Usa HTML con <div class="section">, <h2>, <ul>, <table>.
Usa emoji. Evidenzia i rischi di sicurezza legati a patch non applicate.
"@

$aiHeaders = @{ "Content-Type" = "application/json"; "api-key" = $apiKey }
$body = @{
    messages = @(
        @{ role = "system"; content = "Sei un Azure Patch Management Architect esperto in Azure Update Manager. Rispondi in italiano con report HTML." }
        @{ role = "user";   content = $prompt }
    )
    max_completion_tokens = 4000
} | ConvertTo-Json -Depth 5

try {
    $aiResp  = Invoke-RestMethod -Uri $endpoint -Method POST -Headers $aiHeaders -Body $body -ContentType "application/json" -TimeoutSec 120
    $aiReport = $aiResp.choices[0].message.content
    Write-Host "AI report generated."
} catch {
    Write-Warning "AI error: $($_.Exception.Message)"
    $aiReport = "<div class='section'><h2>Analisi AI non disponibile</h2><p>$($_.Exception.Message)</p></div>"
}

# === HTML ===
$htmlContent = @"
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Update Manager Precheck Report</title>
<style>
  body{font-family:'Segoe UI',sans-serif;background:#f5f5f5;margin:0;padding:20px}
  .container{max-width:1200px;margin:0 auto;background:white;border-radius:10px;padding:40px;box-shadow:0 2px 10px rgba(0,0,0,.1)}
  h1{color:#ff8c00;border-bottom:3px solid #ff8c00;padding-bottom:10px} h2{color:#ff8c00;margin-top:30px}
  .section{margin:20px 0;padding:20px;background:#f8f9fa;border-left:4px solid #ff8c00}
  table{width:100%;border-collapse:collapse;margin:15px 0} th{background:#ff8c00;color:white;padding:12px;text-align:left}
  td{padding:10px;border-bottom:1px solid #ddd}
  .badge-success{background:#28a745;color:white;padding:5px 10px;border-radius:5px}
  .badge-warning{background:#ffc107;color:black;padding:5px 10px;border-radius:5px}
  .badge-danger{background:#dc3545;color:white;padding:5px 10px;border-radius:5px}
</style></head><body><div class="container">
<h1>🔄 Azure Update Manager — Precheck Report</h1>
<p><strong>Subscription:</strong> $($data.Subscription.Name)</p>
<p><strong>Data:</strong> $($data.Timestamp)</p>
$aiReport
<div class="section"><h2>📊 Summary</h2>
<table><tr><th>Metrica</th><th>Valore</th></tr>
<tr><td>Maintenance Configurations</td><td>$($data.Summary.TotalMaintenanceConfigs)</td></tr>
<tr><td>VM Totali</td><td>$($data.Summary.TotalVMs)</td></tr>
<tr><td>VM con Auto-Patching</td><td>$($data.Summary.VMsWithAutoPatching)</td></tr>
<tr><td>VM con Patching Manuale</td><td>$($data.Summary.VMsWithManualPatching)</td></tr>
<tr><td>VM Assegnate a MC</td><td>$($data.Summary.VMsAssignedToMC)</td></tr>
<tr><td>Policy Update Assegnate</td><td>$($data.Summary.TotalUpdatePolicies)</td></tr>
<tr><td>Policy Assessment Attiva</td><td>$(if($data.Summary.HasAssessmentPolicy){'Sì'}else{'No'})</td></tr>
<tr><td>Policy Auto-Patch Attiva</td><td>$(if($data.Summary.HasAutoPatchPolicy){'Sì'}else{'No'})</td></tr>
<tr><td>Update Critici In Sospeso</td><td>$($data.Summary.CriticalUpdatesPending)</td></tr>
</table></div>
</div></body></html>
"@

$htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$data['ReportHTML'] = $htmlContent
$jsonPath = $OutputPath -replace "\.html$", ".json"
$data | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Host "=== UPDATE MANAGER PRECHECK DONE === Time: $([math]::Round(((Get-Date)-$startTime).TotalSeconds))s"
