<#
.SYNOPSIS
Azure Cost Optimization Assessment — read-only.
.DESCRIPTION
Individua sprechi e opportunità di risparmio nella subscription: raccomandazioni Cost di Azure Advisor
(con stima savings), dischi gestiti orfani, IP pubblici non associati, snapshot vecchi e resource group vuoti.
Solo REST API con token OAuth delegato. Nessuna modifica alle risorse.
.NOTES
Version: 1.0 — allineato al pattern precheck-* (EnterprisePrecheck.psm1).
#>

param(
    [Parameter(Mandatory=$true)]  [string]$SubscriptionId,
    [Parameter(Mandatory=$false)] [string]$OutputPath = ".\Cost-Report.html"
)

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
            $all = @(); $all += @($response.value)
            $next = $response.nextLink; $pageCount = 0
            while ($next -and $pageCount -lt 200) {
                $pageCount++
                $page = Invoke-RestMethod -Uri $next -Headers $headers -Method $Method -ErrorAction Stop
                if ($page -and ($page.PSObject.Properties.Name -contains 'value') -and $page.value) { $all += @($page.value) }
                $next = if ($page -and ($page.PSObject.Properties.Name -contains 'nextLink')) { $page.nextLink } else { $null }
            }
            $response.value = $all; $response.nextLink = $null
        }
        return $response
    } catch {
        Write-Warning "API failed: $fullUri - $($_.Exception.Message)"
        return $null
    }
}

$startTime = Get-Date
Write-Host "=== AZURE COST ASSESSMENT START ==="

$data = @{
    Timestamp        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Subscription     = @{}
    Currency         = 'USD'
    AnnualSavings    = 0.0
    CostRecs         = @()
    OrphanDisks      = @()
    UnusedPublicIps  = @()
    OldSnapshots     = @()
    EmptyResourceGroups = @()
    Summary          = @{}
}

# [1] Subscription
Write-Host "[1/6] Subscription..."
$sub = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId"
if ($sub) { $data.Subscription = @{ Name = $sub.displayName; Id = $sub.subscriptionId } }

# [2] Advisor cost recommendations + savings
Write-Host "[2/6] Advisor Cost recommendations..."
$advisor = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Advisor/recommendations" -ApiVersion "2023-01-01"
if ($advisor -and $advisor.value) {
    $costRecs = @($advisor.value | Where-Object { $_.properties.category -eq 'Cost' })
    foreach ($r in $costRecs) {
        $ep = $r.properties.extendedProperties
        $annual = 0.0
        if ($ep) {
            if ($ep.PSObject.Properties.Name -contains 'annualSavingsAmount' -and $ep.annualSavingsAmount) { $annual = [double]$ep.annualSavingsAmount }
            elseif ($ep.PSObject.Properties.Name -contains 'savingsAmount' -and $ep.savingsAmount) { $annual = [double]$ep.savingsAmount }
            if ($ep.PSObject.Properties.Name -contains 'savingsCurrency' -and $ep.savingsCurrency) { $data.Currency = [string]$ep.savingsCurrency }
        }
        $data.AnnualSavings += $annual
        $data.CostRecs += @{
            Impact   = [string]$r.properties.impact
            Problem  = [string]$r.properties.shortDescription.problem
            Savings  = [math]::Round($annual, 2)
        }
    }
    $data.AnnualSavings = [math]::Round($data.AnnualSavings, 2)
    Write-Host "  Cost recs: $($data.CostRecs.Count), savings/anno stimato: $($data.AnnualSavings) $($data.Currency)"
}

# [3] Orphan managed disks (Unattached)
Write-Host "[3/6] Orphan managed disks..."
$disks = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Compute/disks" -ApiVersion "2023-04-02"
if ($disks -and $disks.value) {
    foreach ($d in $disks.value) {
        if ([string]$d.properties.diskState -eq 'Unattached') {
            $data.OrphanDisks += @{
                Name = [string]$d.name
                SizeGB = [int]$d.properties.diskSizeGB
                Sku = [string]$d.sku.name
                Location = [string]$d.location
            }
        }
    }
    Write-Host "  Orphan disks: $($data.OrphanDisks.Count)"
}

# [4] Unused public IPs (no ipConfiguration)
Write-Host "[4/6] Unused public IPs..."
$pips = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Network/publicIPAddresses" -ApiVersion "2023-05-01"
if ($pips -and $pips.value) {
    foreach ($p in $pips.value) {
        $hasCfg = $p.properties.PSObject.Properties.Name -contains 'ipConfiguration' -and $p.properties.ipConfiguration
        if (-not $hasCfg) {
            $data.UnusedPublicIps += @{
                Name = [string]$p.name
                Sku = [string]$p.sku.name
                Method = [string]$p.properties.publicIPAllocationMethod
                Location = [string]$p.location
            }
        }
    }
    Write-Host "  Unused public IPs: $($data.UnusedPublicIps.Count)"
}

# [5] Old snapshots (> 30 giorni)
Write-Host "[5/6] Old snapshots..."
$snaps = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Compute/snapshots" -ApiVersion "2023-04-02"
if ($snaps -and $snaps.value) {
    $cutoff = (Get-Date).AddDays(-30)
    foreach ($s in $snaps.value) {
        $created = $null
        try { $created = [datetime]$s.properties.timeCreated } catch {}
        if ($created -and $created -lt $cutoff) {
            $ageDays = [int]((Get-Date) - $created).TotalDays
            $data.OldSnapshots += @{ Name = [string]$s.name; SizeGB = [int]$s.properties.diskSizeGB; AgeDays = $ageDays }
        }
    }
    Write-Host "  Old snapshots (>30d): $($data.OldSnapshots.Count)"
}

# [6] Empty resource groups
Write-Host "[6/6] Empty resource groups..."
$rgs = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/resourcegroups" -ApiVersion "2021-04-01"
$resources = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/resources" -ApiVersion "2021-04-01"
if ($rgs -and $rgs.value) {
    $usedRgs = @{}
    if ($resources -and $resources.value) {
        foreach ($r in $resources.value) {
            $rid = [string]$r.id
            if ($rid -match '/resourceGroups/([^/]+)/') { $usedRgs[$matches[1].ToLower()] = $true }
        }
    }
    foreach ($rg in $rgs.value) {
        $rgName = [string]$rg.name
        if (-not $usedRgs.ContainsKey($rgName.ToLower())) { $data.EmptyResourceGroups += $rgName }
    }
    Write-Host "  Empty resource groups: $($data.EmptyResourceGroups.Count)"
}

# ---- Build checks ----
Import-Module (Join-Path $PSScriptRoot 'lib/EnterprisePrecheck.psm1') -Force

$checks = @()

$savingsStatus = if ($data.AnnualSavings -le 0) { 'Pass' } elseif ($data.AnnualSavings -lt 1000) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'cost.advisor' -Title 'Risparmio annuo stimato (Advisor)' -Severity 'High' -Status $savingsStatus -Rationale "Risparmio potenziale: $($data.AnnualSavings) $($data.Currency)/anno su $($data.CostRecs.Count) raccomandazioni." -Remediation 'Applica right-sizing e reserved instances/savings plan sulle raccomandazioni Cost di Advisor.'

$diskStatus = if ($data.OrphanDisks.Count -eq 0) { 'Pass' } elseif ($data.OrphanDisks.Count -le 5) { 'Warn' } else { 'Fail' }
$diskGb = ($data.OrphanDisks | Measure-Object -Property SizeGB -Sum).Sum
$checks += New-PrecheckCheck -Id 'cost.orphandisks' -Title 'Dischi gestiti orfani (Unattached)' -Severity 'Medium' -Status $diskStatus -Rationale "Dischi non collegati: $($data.OrphanDisks.Count) ($diskGb GB totali) — costano pur non essendo usati." -Remediation 'Verifica ed elimina (o snapshot+elimina) i dischi Unattached non più necessari.'

$pipStatus = if ($data.UnusedPublicIps.Count -eq 0) { 'Pass' } elseif ($data.UnusedPublicIps.Count -le 5) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'cost.unusedips' -Title 'IP pubblici non associati' -Severity 'Medium' -Status $pipStatus -Rationale "IP pubblici non associati: $($data.UnusedPublicIps.Count) — gli IP Standard statici hanno costo anche se inutilizzati." -Remediation 'Rilascia gli IP pubblici non associati o riassegnali a risorse attive.'

$snapStatus = if ($data.OldSnapshots.Count -eq 0) { 'Pass' } elseif ($data.OldSnapshots.Count -le 10) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'cost.oldsnapshots' -Title 'Snapshot obsoleti (> 30 giorni)' -Severity 'Low' -Status $snapStatus -Rationale "Snapshot più vecchi di 30 giorni: $($data.OldSnapshots.Count)." -Remediation 'Definisci una retention policy per gli snapshot ed elimina quelli obsoleti.'

$rgStatus = if ($data.EmptyResourceGroups.Count -eq 0) { 'Pass' } elseif ($data.EmptyResourceGroups.Count -le 5) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'cost.emptyrg' -Title 'Resource group vuoti' -Severity 'Info' -Status $rgStatus -Rationale "Resource group senza risorse: $($data.EmptyResourceGroups.Count)." -Remediation 'Elimina i resource group vuoti per ridurre il clutter di governance.'

$readiness = Get-PrecheckReadiness -Checks $checks
$data.Readiness = $readiness
$data.Checks = $checks

$data.Summary = @{
    AnnualSavings      = $data.AnnualSavings
    Currency           = $data.Currency
    CostRecsCount      = $data.CostRecs.Count
    OrphanDisks        = $data.OrphanDisks.Count
    UnusedPublicIps    = $data.UnusedPublicIps.Count
    OldSnapshots       = $data.OldSnapshots.Count
    EmptyResourceGroups = $data.EmptyResourceGroups.Count
    ReadinessScore     = $readiness.score
}

# ---- HTML report ----
$recRows = ($data.CostRecs | Sort-Object { $_.Savings } -Descending | Select-Object -First 25 | ForEach-Object {
    "<tr><td>$([System.Net.WebUtility]::HtmlEncode($_.Impact))</td><td>$($_.Savings)</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Problem))</td></tr>"
}) -join "`n"
$diskRows = ($data.OrphanDisks | Select-Object -First 25 | ForEach-Object {
    "<tr><td>$([System.Net.WebUtility]::HtmlEncode($_.Name))</td><td>$($_.SizeGB) GB</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Sku))</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Location))</td></tr>"
}) -join "`n"

$appendix = @"
<div>
  <h3>Appendice tecnica</h3>
  <h4>Raccomandazioni Cost (top 25 per savings)</h4>
  <table><thead><tr><th>Impact</th><th>Savings/anno</th><th>Problema</th></tr></thead><tbody>$recRows</tbody></table>
  <h4>Dischi orfani (top 25)</h4>
  <table><thead><tr><th>Nome</th><th>Size</th><th>SKU</th><th>Location</th></tr></thead><tbody>$diskRows</tbody></table>
</div>
"@

$aiPayload = @{
    solution = 'Azure Cost Optimization Assessment'
    summary  = $data.Summary
    checks   = $checks
    topCostRecs = $data.CostRecs | Sort-Object { $_.Savings } -Descending | Select-Object -First 10
}
$aiHtml = Invoke-EnterpriseOpenAIHtml -SolutionName 'Azure Cost Optimization' -Payload $aiPayload

$kpis = @{
    Kpi1Label = "Savings/anno ($($data.Currency))"; Kpi1Value = $data.AnnualSavings
    Kpi2Label = 'Dischi orfani'; Kpi2Value = $data.OrphanDisks.Count
    Kpi3Label = 'IP inutilizzati'; Kpi3Value = $data.UnusedPublicIps.Count
    Kpi4Label = 'Snapshot vecchi'; Kpi4Value = $data.OldSnapshots.Count
}

$guide = @()
foreach ($c in $checks) {
    if ($c.status -in @('Fail','Warn') -and $c.remediation) {
        $guide += [ordered]@{ title = [string]$c.title; why = [string]$c.rationale; how = [string]$c.remediation; when = [string]$c.severity }
    }
}
if ($guide.Count -eq 0) { $guide += 'Nessuno spreco rilevante rilevato. Mantieni review Advisor mensili e budget/alert sui costi.' }

$htmlContent = New-EnterpriseHtmlReport -SolutionName 'Azure Cost Optimization' -Summary $kpis -Checks $checks -ImplementationGuide $guide -AiHtml $aiHtml -LegacyHtml $appendix -Context @{
    SubscriptionName = $data.Subscription.Name
    SubscriptionId   = $SubscriptionId
    Timestamp        = $data.Timestamp
}

$htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$data['ReportHTML'] = $htmlContent
$jsonPath = $OutputPath -replace "\.html$", ".json"
$data | ConvertTo-Json -Depth 15 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Host "=== AZURE COST DONE === Time: $([math]::Round(((Get-Date)-$startTime).TotalSeconds))s Readiness: $($readiness.score)%"
