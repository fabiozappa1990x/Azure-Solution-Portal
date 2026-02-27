<#
.SYNOPSIS
Azure Backup Deep Analysis - AI-Powered Precheck
.NOTES
Version: 1.0
Uses REST API only. Works with OAuth token from browser via Azure Function.
#>

param(
    [Parameter(Mandatory=$true)]  [string]$SubscriptionId,
    [Parameter(Mandatory=$false)] [string]$OutputPath = ".\Backup-Report.html"
)

$apiKey  $apiKey = "9KpLBHsBIK9gn9rEI7cssnC8sVBLVsmIXr8nWDlUrfxUZUNVGDePJQQJ99CBAC5RqLJXJ3w3AAABACOG7Did"
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
Write-Host "=== BACKUP PRECHECK START ==="

$data = @{
    Timestamp             = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Subscription          = @{}
    RecoveryServicesVaults = @()
    BackupPolicies        = @()
    ProtectedItems        = @()
    AzureVMs              = @()
    AutoBackupPolicies    = @()
    Summary               = @{}
}

# [1] Subscription
Write-Host "[1/7] Subscription..."
$sub = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId"
if ($sub) { $data.Subscription = @{ Name = $sub.displayName; Id = $sub.subscriptionId } }

# [2] Recovery Services Vaults
Write-Host "[2/7] Recovery Services Vaults..."
$vaults = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.RecoveryServices/vaults" -ApiVersion "2023-04-01"
if ($vaults -and $vaults.value) {
    foreach ($v in $vaults.value) {
        $skuName     = if ($v.sku) { $v.sku.name } else { "Unknown" }
        $softDelete  = $v.properties.securitySettings.softDeleteSettings.softDeleteState
        $storageType = $v.properties.redundancySettings.storageModelType
        $data.RecoveryServicesVaults += @{
            Name              = $v.name
            ResourceGroup     = ($v.id -split '/')[4]
            Location          = $v.location
            Sku               = $skuName
            SoftDeleteEnabled = ($softDelete -eq "Enabled" -or $softDelete -eq "AlwaysOn")
            StorageType       = $storageType
            ResourceId        = $v.id
        }
    }
    Write-Host "  Found $($data.RecoveryServicesVaults.Count) Vaults"
}

# [3] Backup Policies per vault
Write-Host "[3/7] Backup Policies..."
foreach ($vault in $data.RecoveryServicesVaults) {
    $rgName    = $vault.ResourceGroup
    $vaultName = $vault.Name
    $policies  = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$rgName/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies" -ApiVersion "2023-04-01"
    if ($policies -and $policies.value) {
        foreach ($pol in $policies.value) {
            $data.BackupPolicies += @{
                VaultName     = $vaultName
                Name          = $pol.name
                WorkloadType  = $pol.properties.backupManagementType
                PolicyType    = $pol.properties.policyType
            }
        }
    }
}
Write-Host "  Found $($data.BackupPolicies.Count) Backup Policies"

# [4] Protected Items per vault
Write-Host "[4/7] Protected Items (backup coverage)..."
foreach ($vault in $data.RecoveryServicesVaults) {
    $rgName    = $vault.ResourceGroup
    $vaultName = $vault.Name
    $items     = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$rgName/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems" -ApiVersion "2023-04-01"
    if ($items -and $items.value) {
        foreach ($item in $items.value) {
            $data.ProtectedItems += @{
                VaultName              = $vaultName
                Name                   = $item.name
                WorkloadType           = $item.properties.workloadType
                ProtectionState        = $item.properties.protectionState
                LastBackupStatus       = $item.properties.lastBackupStatus
                LastBackupTime         = $item.properties.lastBackupTime
                PolicyName             = $item.properties.policyName
            }
        }
    }
}
Write-Host "  Found $($data.ProtectedItems.Count) Protected Items"

# [5] All Azure VMs (to find unprotected)
Write-Host "[5/7] Azure VMs (copertura backup)..."
$vms = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Compute/virtualMachines" -ApiVersion "2023-03-01"
if ($vms -and $vms.value) {
    $protectedVmIds = $data.ProtectedItems | Where-Object { $_.WorkloadType -eq "VM" } | ForEach-Object { $_.Name -replace ".*iaasvmcontainerv2;.*;", "" }
    foreach ($vm in $vms.value) {
        $isProtected = $protectedVmIds -contains $vm.name
        $data.AzureVMs += @{
            Name          = $vm.name
            ResourceGroup = ($vm.id -split '/')[4]
            Location      = $vm.location
            OsType        = $vm.properties.storageProfile.osDisk.osType
            IsProtected   = $isProtected
        }
    }
    Write-Host "  Found $($data.AzureVMs.Count) VMs, $($data.AzureVMs | Where-Object {$_.IsProtected} | Measure-Object | Select-Object -ExpandProperty Count) protected"
}

# [6] Policy Assignments for auto-backup
Write-Host "[6/7] Azure Policy (auto-backup)..."
$policyAssignments = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/policyAssignments" -ApiVersion "2021-06-01"
if ($policyAssignments -and $policyAssignments.value) {
    $backupPolicies = $policyAssignments.value | Where-Object { $_.properties.displayName -match "Backup|Recovery" }
    foreach ($p in $backupPolicies) {
        $data.AutoBackupPolicies += @{
            Name        = $p.name
            DisplayName = $p.properties.displayName
            Enforcement = $p.properties.enforcementMode
        }
    }
    Write-Host "  Found $($data.AutoBackupPolicies.Count) Backup Policies"
}

# [7] Summary
Write-Host "[7/7] Summary..."
$totalVMs       = $data.AzureVMs.Count
$protectedVMs   = ($data.AzureVMs | Where-Object { $_.IsProtected }).Count
$unprotectedVMs = $totalVMs - $protectedVMs
$coveragePct    = if ($totalVMs -gt 0) { [math]::Round(($protectedVMs / $totalVMs) * 100, 2) } else { 0 }

$data.Summary = @{
    TotalVaults         = $data.RecoveryServicesVaults.Count
    VaultsWithGRS       = ($data.RecoveryServicesVaults | Where-Object { $_.StorageType -eq "GeoRedundant" }).Count
    VaultsWithSoftDelete = ($data.RecoveryServicesVaults | Where-Object { $_.SoftDeleteEnabled }).Count
    TotalPolicies       = $data.BackupPolicies.Count
    TotalProtectedItems = $data.ProtectedItems.Count
    TotalVMs            = $totalVMs
    ProtectedVMs        = $protectedVMs
    UnprotectedVMs      = $unprotectedVMs
    BackupCoverage_Pct  = $coveragePct
    AutoPoliciesCount   = $data.AutoBackupPolicies.Count
}

# === AI ANALYSIS ===
Write-Host "=== AI ANALYSIS ==="
$dataJson = $data | ConvertTo-Json -Depth 8 -Compress

$prompt = @"
Analizza questi dati Azure Backup e genera un report DETTAGLIATO in ITALIANO in formato HTML.

DATI:
$dataJson

GENERA SEZIONI HTML CON:
1. EXECUTIVE SUMMARY (copertura backup %, vault esistenti, criticità TOP 3)
2. RECOVERY SERVICES VAULTS (ridondanza GRS/LRS, soft delete, stato)
3. VM NON PROTETTE (elenco VM senza backup con risk assessment)
4. POLICY DI BACKUP (GFS retention, RPO/RTO stimati, gap di configurazione)
5. AUTOMAZIONE (Azure Policy auto-backup, scope coverage)
6. RACCOMANDAZIONI PRIORITARIE (TOP 8 azioni per raggiungere 100% copertura)

Usa HTML con <div class="section">, <h2>, <ul>, <table>.
Usa emoji. Sii tecnico ma chiaro.
"@

$aiHeaders = @{ "Content-Type" = "application/json"; "api-key" = $apiKey }
$body = @{
    messages = @(
        @{ role = "system"; content = "Sei un Azure Solutions Architect esperto in Backup e BCDR. Rispondi in italiano con report HTML." }
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
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Backup Precheck Report</title>
<style>
  body{font-family:'Segoe UI',sans-serif;background:#f5f5f5;margin:0;padding:20px}
  .container{max-width:1200px;margin:0 auto;background:white;border-radius:10px;padding:40px;box-shadow:0 2px 10px rgba(0,0,0,.1)}
  h1{color:#107c10;border-bottom:3px solid #107c10;padding-bottom:10px} h2{color:#107c10;margin-top:30px}
  .section{margin:20px 0;padding:20px;background:#f8f9fa;border-left:4px solid #107c10}
  table{width:100%;border-collapse:collapse;margin:15px 0} th{background:#107c10;color:white;padding:12px;text-align:left}
  td{padding:10px;border-bottom:1px solid #ddd}
  .badge-success{background:#28a745;color:white;padding:5px 10px;border-radius:5px}
  .badge-warning{background:#ffc107;color:black;padding:5px 10px;border-radius:5px}
  .badge-danger{background:#dc3545;color:white;padding:5px 10px;border-radius:5px}
</style></head><body><div class="container">
<h1>🛡️ Azure Backup — Precheck Report</h1>
<p><strong>Subscription:</strong> $($data.Subscription.Name)</p>
<p><strong>Data:</strong> $($data.Timestamp)</p>
$aiReport
<div class="section"><h2>📊 Summary</h2>
<table><tr><th>Metrica</th><th>Valore</th></tr>
<tr><td>Recovery Services Vault</td><td>$($data.Summary.TotalVaults)</td></tr>
<tr><td>Vault con GRS</td><td>$($data.Summary.VaultsWithGRS)</td></tr>
<tr><td>Vault con Soft Delete</td><td>$($data.Summary.VaultsWithSoftDelete)</td></tr>
<tr><td>Policy Backup Totali</td><td>$($data.Summary.TotalPolicies)</td></tr>
<tr><td>Item Protetti</td><td>$($data.Summary.TotalProtectedItems)</td></tr>
<tr><td>VM Totali</td><td>$($data.Summary.TotalVMs)</td></tr>
<tr><td>VM Protette</td><td>$($data.Summary.ProtectedVMs)</td></tr>
<tr><td>VM Non Protette</td><td>$($data.Summary.UnprotectedVMs)</td></tr>
<tr><td>Copertura Backup</td><td>$($data.Summary.BackupCoverage_Pct)%</td></tr>
</table></div>
</div></body></html>
"@

$htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$data['ReportHTML'] = $htmlContent
$jsonPath = $OutputPath -replace "\.html$", ".json"
$data | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Host "=== BACKUP PRECHECK DONE === Time: $([math]::Round(((Get-Date)-$startTime).TotalSeconds))s"
