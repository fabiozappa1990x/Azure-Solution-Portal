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
    $headers = @{ "Authorization" = "Bearer $accessToken"; "Content-Type" = "application/json" }
    $fullUri = if ($Uri -like "*api-version*") { $Uri } else { "${Uri}?api-version=$ApiVersion" }
    try {
        $response = Invoke-RestMethod -Uri $fullUri -Headers $headers -Method $Method -ErrorAction Stop

        if ($Method -eq "GET" -and $response -and ($response.PSObject.Properties.Name -contains "nextLink") -and $response.nextLink -and
            ($response.PSObject.Properties.Name -contains "value") -and ($response.value -is [System.Collections.IEnumerable])) {
            $all = @()
            $all += @($response.value)
            $next = $response.nextLink
            $pageCount = 0
            while ($next -and $pageCount -lt 200) {
                $pageCount++
                $page = Invoke-RestMethod -Uri $next -Headers $headers -Method $Method -ErrorAction Stop
                if ($page -and ($page.PSObject.Properties.Name -contains "value") -and $page.value) {
                    $all += @($page.value)
                }
                $next = if ($page -and ($page.PSObject.Properties.Name -contains "nextLink")) { $page.nextLink } else { $null }
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

Import-Module (Join-Path $PSScriptRoot "lib/EnterprisePrecheck.psm1") -Force

# Enterprise checks
$checks = @()
$coverage = [double]$data.Summary.BackupCoverage_Pct
$coverageStatus = if ($coverage -ge 90) { "Pass" } elseif ($coverage -ge 60) { "Warn" } else { "Fail" }
$checks += New-PrecheckCheck -Id "backup.coverage" -Title "Copertura backup VM" -Severity "Critical" -Status $coverageStatus -Rationale "Copertura VM: $coverage% (protette: $($data.Summary.ProtectedVMs) / $($data.Summary.TotalVMs))." -Remediation "Abilita backup per le VM non protette e verifica che esista una policy standard per l’ambiente."

$softDeleteStatus = if ($data.Summary.TotalVaults -eq 0) { "Warn" } elseif ($data.Summary.VaultsWithSoftDelete -eq $data.Summary.TotalVaults) { "Pass" } else { "Warn" }
$checks += New-PrecheckCheck -Id "backup.softdelete" -Title "Soft delete su Recovery Services Vault" -Severity "High" -Status $softDeleteStatus -Rationale "Vault: $($data.Summary.TotalVaults), Soft Delete abilitato: $($data.Summary.VaultsWithSoftDelete)." -Remediation "Abilita Soft Delete (AlwaysOn/Enabled) su tutti i vault."

$redundancyStatus = if ($data.Summary.TotalVaults -eq 0) { "Warn" } elseif ($data.Summary.VaultsWithGRS -gt 0) { "Pass" } else { "Warn" }
$checks += New-PrecheckCheck -Id "backup.redundancy" -Title "Ridondanza dei vault (GRS)" -Severity "Medium" -Status $redundancyStatus -Rationale "Vault con GRS: $($data.Summary.VaultsWithGRS)." -Remediation "Valuta GRS per carichi critici e requisiti BCDR."

$policiesStatus = if ($data.Summary.TotalPolicies -gt 0) { "Pass" } else { "Fail" }
$checks += New-PrecheckCheck -Id "backup.policies" -Title "Policy di backup disponibili" -Severity "Medium" -Status $policiesStatus -Rationale "Policy totali: $($data.Summary.TotalPolicies)." -Remediation "Crea policy standard (VM/Azure Files/Workload) con retention e schedule coerenti."

$readiness = Get-PrecheckReadiness -Checks $checks
$data.Readiness = $readiness
$data.Checks = $checks
if ($data.Summary -is [hashtable]) {
    $data.Summary["ReadinessScore"] = $readiness.score
} else {
    $data.Summary | Add-Member -NotePropertyName "ReadinessScore" -NotePropertyValue $readiness.score -Force
}

$enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }

function Convert-ItemsToListHtml {
    param(
        [Parameter(Mandatory)] [array] $Items,
        [Parameter()] [int] $Max = 20,
        [Parameter(Mandatory)] [scriptblock] $ToLi
    )
    if (-not $Items -or $Items.Count -eq 0) { return '<span class="muted">Nessun elemento.</span>' }
    $rows = @($Items | Select-Object -First $Max | ForEach-Object { & $ToLi $_ })
    $suffix = if ($Items.Count -gt $Max) { "<li class='muted'>... +$($Items.Count - $Max) altri</li>" } else { '' }
    return "<ul style='margin:8px 0 0 18px'>" + ($rows -join '') + $suffix + "</ul>"
}

$vaults = @($data.RecoveryServicesVaults)
$preferredVault = @(
    $vaults | Where-Object { $_.SoftDeleteEnabled -eq $true -and $_.StorageType -match 'Geo' } | Select-Object -First 1
)
if (-not $preferredVault) { $preferredVault = @($vaults | Where-Object { $_.SoftDeleteEnabled -eq $true } | Select-Object -First 1) }
if (-not $preferredVault) { $preferredVault = @($vaults | Select-Object -First 1) }

$unprotected = @($data.AzureVMs | Where-Object { -not $_.IsProtected })
$protected   = @($data.AzureVMs | Where-Object { $_.IsProtected })
$vaultsSoftDeleteOff = @($vaults | Where-Object { -not $_.SoftDeleteEnabled })
$vaultsLrs = @($vaults | Where-Object { $_.StorageType -notmatch 'Geo' })

$impl = @()
$impl += "<h3>Deep-dive dell'ambiente rilevato</h3>"
$impl += "<ul style='margin:8px 0 0 18px'>"
$impl += "<li><b>Recovery Services Vault</b>: $($data.Summary.TotalVaults) (GRS: $($data.Summary.VaultsWithGRS), SoftDelete: $($data.Summary.VaultsWithSoftDelete)).</li>"
$impl += "<li><b>Policy</b>: $($data.Summary.TotalPolicies) • Auto-enable (Azure Policy) rilevate: $($data.Summary.AutoPoliciesCount).</li>"
$impl += "<li><b>VM</b>: totali $($data.Summary.TotalVMs) • protette $($data.Summary.ProtectedVMs) • non protette $($data.Summary.UnprotectedVMs) • copertura $($data.Summary.BackupCoverage_Pct)%.</li>"
$impl += "<li><b>Protected items</b>: $($data.Summary.TotalProtectedItems) (attenzione: include workload non-VM se presenti nel vault).</li>"
$impl += "</ul>"

$impl += "<h3 style='margin-top:14px'>Guida operativa: cosa fare in questo ambiente</h3>"
$impl += "<ol style='margin:8px 0 0 18px'>"

if ($vaults.Count -eq 0) {
    $impl += "<li><b>Crea un Recovery Services Vault</b>: non ho trovato alcun vault. Crea un vault in una regione coerente con i workload (di norma stessa region delle VM) e applica baseline security (Soft Delete, immutability se prevista, RBAC, locks).</li>"
} else {
    $pv = $preferredVault | Select-Object -First 1
    $pvName = if ($pv) { & $enc $pv.Name } else { '' }
    $pvRg = if ($pv) { & $enc $pv.ResourceGroup } else { '' }
    $pvLoc = if ($pv) { & $enc $pv.Location } else { '' }
    $pvRed = if ($pv) { & $enc $pv.StorageType } else { '' }
    $impl += "<li><b>Seleziona il vault target</b>: vault consigliato in questo contesto: <b>$pvName</b> <span class='muted'>(RG: $pvRg • Region: $pvLoc • Redundancy: $pvRed)</span>. Valuta consolidamento se ci sono più vault con policy divergenti.</li>"

    if ($vaultsSoftDeleteOff.Count -gt 0) {
        $impl += "<li><b>Hardening del vault</b>: rilevati vault con Soft Delete disabilitato. Abilita Soft Delete (Enabled/AlwaysOn) su tutti i vault per ridurre rischio di delete malevoli.</li>"
    }
    if ($vaultsLrs.Count -gt 0) {
        $impl += "<li><b>Ridondanza (GRS)</b>: alcuni vault risultano non-GeoRedundant. Valuta GRS per workload critici e requisiti BCDR (RPO/RTO, compliance).</li>"
    }
}

if ($data.Summary.TotalPolicies -eq 0) {
    $impl += "<li><b>Crea policy standard</b>: non ho trovato policy nel vault. Crea policy per VM (daily/weekly) con retention coerente (es. 30/90/365) e naming standard. Se devi proteggere Azure Files/SQL in VM, crea policy dedicate.</li>"
} else {
    $impl += "<li><b>Rivedi policy esistenti</b>: sono presenti policy nel vault. Verifica schedule/retention, timezone e separazione prod/non-prod. Allinea il numero di policy per evitare eccessiva frammentazione.</li>"
}

if ($unprotected.Count -gt 0) {
    $impl += "<li><b>Abilita backup sulle VM non protette</b>: ho trovato <b>$($unprotected.Count)</b> VM non protette. Se esiste già un vault target, abilita backup solo per quelle non protette (evita duplicazioni)."
    $impl += (Convert-ItemsToListHtml -Items $unprotected -Max 25 -ToLi { param($vm) "<li><b>$(& $enc $vm.Name)</b> <span class='muted'>(RG: $(& $enc $vm.ResourceGroup) • Region: $(& $enc $vm.Location) • OS: $(& $enc $vm.OsType))</span></li>" })
    $impl += "</li>"
} else {
    $impl += "<li><b>Copertura VM</b>: tutte le VM risultano protette. Verifica che la protezione sia Healthy e che i job siano in SLA (success rate, duration, throttling).</li>"
}

if ($data.Summary.AutoPoliciesCount -eq 0) {
    $impl += "<li><b>Automation / auto-enablement</b>: non risultano policy assignments per auto-enable backup. Se il modello operativo lo richiede, valuta Azure Policy per standardizzare la protezione (scope RG/subscription) e ridurre drift.</li>"
} else {
    $impl += "<li><b>Automation</b>: risultano policy di backup presenti. Verifica scope ed enforcement, ed escludi workload non idonei per evitare protezione non desiderata.</li>"
}

$impl += "<li><b>Validazione post-deploy</b>: verifica che le VM siano in stato Protected, esegui un backup on-demand e un restore test su una VM campione. KPI minimi: backup success rate, restore test periodico, retention compliance.</li>"
$impl += "</ol>"

$implementationHtml = ($impl -join "`n")

# Build a technical appendix (no AI required)
$vaultRows = ($data.RecoveryServicesVaults | Select-Object -First 50 | ForEach-Object {
    "<tr><td>$($_.Name)</td><td>$($_.ResourceGroup)</td><td>$($_.Location)</td><td>$($_.StorageType)</td><td>$($_.SoftDeleteEnabled)</td></tr>"
}) -join "`n"

$unprotected = $data.AzureVMs | Where-Object { -not $_.IsProtected } | Select-Object -First 80
$unprotRows = ($unprotected | ForEach-Object {
    "<tr><td>$($_.Name)</td><td>$($_.ResourceGroup)</td><td>$($_.Location)</td><td>$($_.OsType)</td></tr>"
}) -join "`n"

$appendix = @"
<div>
  <h3>Appendice tecnica</h3>
  <h4>Recovery Services Vault (top 50)</h4>
  <table>
    <thead><tr><th>Name</th><th>RG</th><th>Region</th><th>Redundancy</th><th>SoftDelete</th></tr></thead>
    <tbody>$vaultRows</tbody>
  </table>
  <h4>VM non protette (top 80)</h4>
  <table>
    <thead><tr><th>Name</th><th>RG</th><th>Region</th><th>OS</th></tr></thead>
    <tbody>$unprotRows</tbody>
  </table>
</div>
"@

$aiPayload = @{
    solution = "Azure Backup"
    summary  = $data.Summary
    checks   = $checks
    topUnprotectedVMs = $unprotected | Select-Object -First 20 Name, ResourceGroup, Location, OsType
    vaults   = $data.RecoveryServicesVaults | Select-Object -First 10 Name, Location, StorageType, SoftDeleteEnabled
}

$aiHtml = Invoke-EnterpriseOpenAIHtml -SolutionName "Azure Backup" -Payload $aiPayload

$kpis = @{
    Kpi1Label = "Vaults"
    Kpi1Value = $data.Summary.TotalVaults
    Kpi2Label = "VM protette"
    Kpi2Value = "$($data.Summary.ProtectedVMs)/$($data.Summary.TotalVMs)"
    Kpi3Label = "Copertura"
    Kpi3Value = "$coverage%"
    Kpi4Label = "Policy"
    Kpi4Value = $data.Summary.TotalPolicies
}

$context = @{
    SubscriptionName = $data.Subscription.Name
    SubscriptionId   = $SubscriptionId
    Timestamp        = $data.Timestamp
}

$htmlContent = New-EnterpriseHtmlReport -SolutionName "Azure Backup" -Summary $kpis -Checks $checks -AiHtml $aiHtml -ImplementationHtml $implementationHtml -LegacyHtml $appendix -Context $context

$htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$data["ReportHTML"] = $htmlContent
$jsonPath = $OutputPath -replace "\.html$", ".json"
$data | ConvertTo-Json -Depth 15 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Host "=== BACKUP PRECHECK DONE === Time: $([math]::Round(((Get-Date)-$startTime).TotalSeconds))s Readiness: $($readiness.score)%"

