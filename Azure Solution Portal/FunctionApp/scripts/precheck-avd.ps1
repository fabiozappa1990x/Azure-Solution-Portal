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

# AI Configuration (same Azure OpenAI instance as testluca.ps1)
$apiKey = "9KpLBHsBIK9gn9rEI7cssnC8sVBLVsmIXr8nWDlUrfxUZUNVGDePJQQJ99CBAC5RqLJXJ3w3AAABACOG7Did"
$endpoint = "https://westeurope.api.cognitive.microsoft.com/openai/deployments/AVM/chat/completions?api-version=2025-01-01-preview"

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

# === AI ANALYSIS ===
Write-Host "=== AI ANALYSIS ==="
$dataJson = $data | ConvertTo-Json -Depth 8 -Compress

$prompt = @"
Analizza questi dati Azure Virtual Desktop e genera un report DETTAGLIATO in ITALIANO in formato HTML.

DATI:
$dataJson

GENERA SEZIONI HTML CON:
1. EXECUTIVE SUMMARY (stato attuale AVD: già deployato / parziale / non presente, readiness score)
2. INFRASTRUTTURA ESISTENTE (Host Pool, Session Hosts, Workspaces, App Groups, Scaling Plans)
3. ANALISI RETE (VNet disponibili per AVD, subnet adeguate, latenza stimata)
4. STORAGE & FSLOGIX (storage account compatibili AADKERB, profili utente FSLogix)
5. GAP ANALYSIS (cosa manca per un deployment AVD completo e production-ready)
6. RACCOMANDAZIONI PRIORITARIE (TOP 8 azioni, quick wins, configurazioni consigliate)

Usa HTML con <div class="section">, <h2>, <ul>, <table> per strutturare.
Usa emoji per rendere visivo. Sii tecnico ma chiaro.
"@

$aiHeaders = @{ "Content-Type" = "application/json"; "api-key" = $apiKey }
$body = @{
    messages = @(
        @{ role = "system"; content = "Sei un Azure Solutions Architect esperto in AVD. Rispondi in italiano con report HTML dettagliati." }
        @{ role = "user";   content = $prompt }
    )
    max_completion_tokens = 4000
} | ConvertTo-Json -Depth 5

try {
    $aiResp = Invoke-RestMethod -Uri $endpoint -Method POST -Headers $aiHeaders -Body $body -ContentType "application/json" -TimeoutSec 120
    $aiReport = $aiResp.choices[0].message.content
    Write-Host "AI report generated."
} catch {
    Write-Warning "AI error: $($_.Exception.Message)"
    $aiReport = "<div class='section'><h2>Analisi AI non disponibile</h2><p>$($_.Exception.Message)</p></div>"
}

# === HTML ===
$htmlContent = @"
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>AVD Precheck Report</title>
<style>
  body{font-family:'Segoe UI',sans-serif;background:#f5f5f5;margin:0;padding:20px}
  .container{max-width:1200px;margin:0 auto;background:white;border-radius:10px;padding:40px;box-shadow:0 2px 10px rgba(0,0,0,.1)}
  h1{color:#7719aa;border-bottom:3px solid #7719aa;padding-bottom:10px} h2{color:#7719aa;margin-top:30px}
  .section{margin:20px 0;padding:20px;background:#f8f9fa;border-left:4px solid #7719aa}
  table{width:100%;border-collapse:collapse;margin:15px 0} th{background:#7719aa;color:white;padding:12px;text-align:left}
  td{padding:10px;border-bottom:1px solid #ddd}
  .badge-success{background:#28a745;color:white;padding:5px 10px;border-radius:5px}
  .badge-warning{background:#ffc107;color:black;padding:5px 10px;border-radius:5px}
  .badge-danger{background:#dc3545;color:white;padding:5px 10px;border-radius:5px}
</style></head><body><div class="container">
<h1>🖥️ Azure Virtual Desktop — Precheck Report</h1>
<p><strong>Subscription:</strong> $($data.Subscription.Name)</p>
<p><strong>Data:</strong> $($data.Timestamp)</p>
$aiReport
<div class="section"><h2>📊 Summary</h2>
<table><tr><th>Metrica</th><th>Valore</th></tr>
<tr><td>Host Pool</td><td>$($data.Summary.TotalHostPools)</td></tr>
<tr><td>Session Hosts</td><td>$($data.Summary.TotalSessionHosts)</td></tr>
<tr><td>Session Hosts Attivi</td><td>$($data.Summary.ActiveSessionHosts)</td></tr>
<tr><td>Workspaces</td><td>$($data.Summary.TotalWorkspaces)</td></tr>
<tr><td>Application Groups</td><td>$($data.Summary.TotalAppGroups)</td></tr>
<tr><td>Scaling Plans</td><td>$($data.Summary.TotalScalingPlans)</td></tr>
<tr><td>VNet disponibili</td><td>$($data.Summary.TotalVNets)</td></tr>
<tr><td>Storage con AADKERB (FSLogix)</td><td>$($data.Summary.StorageWithFSLogix)/$($data.Summary.TotalStorageAccounts)</td></tr>
</table></div>
</div></body></html>
"@

$htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$data['ReportHTML'] = $htmlContent
$jsonPath = $OutputPath -replace "\.html$", ".json"
$data | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Host "=== AVD PRECHECK DONE === Time: $([math]::Round(((Get-Date)-$startTime).TotalSeconds))s"

