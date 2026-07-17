<#
.SYNOPSIS
Azure Posture Assessment (Well-Architected / CAF) — read-only.
.DESCRIPTION
Valuta la postura della subscription sui 5 pilastri Well-Architected usando Azure Advisor,
Secure Score, compliance delle Azure Policy e inventario risorse. Solo REST API con token OAuth
delegato inoltrato dalla Azure Function. Nessuna modifica alle risorse.
.NOTES
Version: 1.0 — allineato al pattern precheck-* (EnterprisePrecheck.psm1).
#>

param(
    [Parameter(Mandatory=$true)]  [string]$SubscriptionId,
    [Parameter(Mandatory=$false)] [string]$OutputPath = ".\Posture-Report.html"
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
Write-Host "=== AZURE POSTURE ASSESSMENT START ==="

$data = @{
    Timestamp       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Subscription    = @{}
    Advisor         = @{ Cost = 0; Security = 0; HighAvailability = 0; Performance = 0; OperationalExcellence = 0; Total = 0 }
    AdvisorTop      = @()
    SecureScore     = @{}
    Policy          = @{ Assignments = 0; NonCompliantResources = 0; CompliantResources = 0; CompliancePct = 100 }
    Resources       = @{ Total = 0; ByType = @{}; ByLocation = @{}; Untagged = 0; UntaggedPct = 0 }
    Locks           = 0
    Summary         = @{}
}

# [1] Subscription
Write-Host "[1/6] Subscription..."
$sub = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId"
if ($sub) { $data.Subscription = @{ Name = $sub.displayName; Id = $sub.subscriptionId } }

# [2] Azure Advisor (WAF pillars)
Write-Host "[2/6] Azure Advisor recommendations..."
$advisor = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Advisor/recommendations" -ApiVersion "2023-01-01"
if ($advisor -and $advisor.value) {
    foreach ($r in $advisor.value) {
        $cat = [string]$r.properties.category
        switch ($cat) {
            'Cost'                  { $data.Advisor.Cost++ }
            'Security'              { $data.Advisor.Security++ }
            'HighAvailability'      { $data.Advisor.HighAvailability++ }
            'Performance'           { $data.Advisor.Performance++ }
            'OperationalExcellence' { $data.Advisor.OperationalExcellence++ }
        }
    }
    $data.Advisor.Total = @($advisor.value).Count
    $data.AdvisorTop = @($advisor.value | Where-Object { $_.properties.impact -eq 'High' } | Select-Object -First 25 | ForEach-Object {
        @{
            Category = [string]$_.properties.category
            Impact   = [string]$_.properties.impact
            Problem  = [string]$_.properties.shortDescription.problem
        }
    })
    Write-Host "  Advisor: $($data.Advisor.Total) recs (Sec:$($data.Advisor.Security) HA:$($data.Advisor.HighAvailability) Cost:$($data.Advisor.Cost))"
}

# [3] Secure Score (Defender for Cloud)
Write-Host "[3/6] Secure Score..."
$secureScore = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Security/secureScores/ascScore" -ApiVersion "2020-01-01"
if ($secureScore -and $secureScore.properties) {
    $pct = if ($secureScore.properties.score.percentage) { [math]::Round($secureScore.properties.score.percentage * 100, 1) } else { 0 }
    $data.SecureScore = @{ Score = $secureScore.properties.score.current; Max = $secureScore.properties.score.max; Percentage = $pct }
    Write-Host "  Secure Score: $pct%"
}

# [4] Azure Policy compliance
Write-Host "[4/6] Policy compliance..."
$assignments = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/policyAssignments" -ApiVersion "2022-06-01"
if ($assignments -and $assignments.value) { $data.Policy.Assignments = @($assignments.value).Count }

$summaryUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.PolicyInsights/policyStates/latest/summarize?api-version=2019-10-01"
$policySummary = Invoke-AzureAPI -Uri $summaryUri -Method "POST"
if ($policySummary -and $policySummary.value) {
    $res = $policySummary.value[0].results
    if ($res) {
        $data.Policy.NonCompliantResources = [int]$res.nonCompliantResources
        $totalRes = [int]$res.resourceDetails.Count
        if ($res.PSObject.Properties.Name -contains 'resourceDetails' -and $res.resourceDetails) {
            $compliant = ($res.resourceDetails | Where-Object { $_.complianceState -eq 'Compliant' } | Measure-Object -Property count -Sum).Sum
            $data.Policy.CompliantResources = [int]$compliant
        }
        $denom = $data.Policy.NonCompliantResources + $data.Policy.CompliantResources
        $data.Policy.CompliancePct = if ($denom -gt 0) { [math]::Round(($data.Policy.CompliantResources / $denom) * 100, 1) } else { 100 }
    }
}

# [5] Resource inventory & governance
Write-Host "[5/6] Resource inventory..."
$resources = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/resources" -ApiVersion "2021-04-01"
if ($resources -and $resources.value) {
    $all = @($resources.value)
    $data.Resources.Total = $all.Count
    $untagged = 0
    foreach ($r in $all) {
        $t = [string]$r.type
        if (-not $data.Resources.ByType.ContainsKey($t)) { $data.Resources.ByType[$t] = 0 }
        $data.Resources.ByType[$t]++
        $loc = [string]$r.location
        if ($loc) {
            if (-not $data.Resources.ByLocation.ContainsKey($loc)) { $data.Resources.ByLocation[$loc] = 0 }
            $data.Resources.ByLocation[$loc]++
        }
        $hasTags = $r.PSObject.Properties.Name -contains 'tags' -and $r.tags -and ($r.tags.PSObject.Properties | Measure-Object).Count -gt 0
        if (-not $hasTags) { $untagged++ }
    }
    $data.Resources.Untagged = $untagged
    $data.Resources.UntaggedPct = if ($all.Count -gt 0) { [math]::Round(($untagged / $all.Count) * 100, 1) } else { 0 }
    Write-Host "  Resources: $($all.Count) ($untagged untagged)"
}

# [6] Resource locks (governance)
Write-Host "[6/6] Resource locks..."
$locks = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/locks" -ApiVersion "2020-05-01"
if ($locks -and $locks.value) { $data.Locks = @($locks.value).Count }

# ---- Build checks (EnterprisePrecheck) ----
Import-Module (Join-Path $PSScriptRoot 'lib/EnterprisePrecheck.psm1') -Force

$checks = @()

# Security pillar
$secStatus = if ($data.Advisor.Security -eq 0) { 'Pass' } elseif ($data.Advisor.Security -le 5) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'waf.security' -Title 'Pilastro Security (Advisor + Secure Score)' -Severity 'Critical' -Status $secStatus -Rationale "Raccomandazioni Security: $($data.Advisor.Security). Secure Score: $($data.SecureScore.Percentage)%." -Remediation 'Rimedia le raccomandazioni Security di Advisor; abilita Defender for Cloud e alza il Secure Score con ownership e SLA.'

$scoreVal = if ($data.SecureScore.Percentage) { [double]$data.SecureScore.Percentage } else { 0 }
$scoreStatus = if ($scoreVal -ge 70) { 'Pass' } elseif ($scoreVal -ge 40) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'waf.securescore' -Title 'Secure Score posture' -Severity 'High' -Status $scoreStatus -Rationale "Secure Score corrente: $scoreVal%." -Remediation 'Pianifica remediation delle raccomandazioni Defender for Cloud High/Medium.'

# Reliability pillar
$haStatus = if ($data.Advisor.HighAvailability -eq 0) { 'Pass' } elseif ($data.Advisor.HighAvailability -le 5) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'waf.reliability' -Title 'Pilastro Reliability (High Availability)' -Severity 'High' -Status $haStatus -Rationale "Raccomandazioni High Availability: $($data.Advisor.HighAvailability)." -Remediation 'Introduci availability zones/set, backup e ridondanza sui workload critici indicati da Advisor.'

# Cost pillar
$costStatus = if ($data.Advisor.Cost -eq 0) { 'Pass' } elseif ($data.Advisor.Cost -le 5) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'waf.cost' -Title 'Pilastro Cost Optimization' -Severity 'Medium' -Status $costStatus -Rationale "Raccomandazioni Cost: $($data.Advisor.Cost). Dettaglio completo nella soluzione Azure Cost Optimization." -Remediation 'Applica right-sizing, reserved instances e cleanup risorse orfane suggerite da Advisor.'

# Performance pillar
$perfStatus = if ($data.Advisor.Performance -eq 0) { 'Pass' } elseif ($data.Advisor.Performance -le 5) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'waf.performance' -Title 'Pilastro Performance Efficiency' -Severity 'Medium' -Status $perfStatus -Rationale "Raccomandazioni Performance: $($data.Advisor.Performance)." -Remediation 'Valuta SKU/tier e caching sui workload segnalati da Advisor.'

# Operational Excellence pillar
$opsStatus = if ($data.Advisor.OperationalExcellence -eq 0) { 'Pass' } elseif ($data.Advisor.OperationalExcellence -le 5) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'waf.operations' -Title 'Pilastro Operational Excellence' -Severity 'Medium' -Status $opsStatus -Rationale "Raccomandazioni Operational Excellence: $($data.Advisor.OperationalExcellence)." -Remediation 'Adotta IaC, monitoring e processi operativi consigliati da Advisor.'

# Governance: Policy compliance
$polStatus = if ($data.Policy.Assignments -eq 0) { 'Fail' } elseif ($data.Policy.CompliancePct -ge 90) { 'Pass' } elseif ($data.Policy.CompliancePct -ge 70) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'waf.governance.policy' -Title 'Governance — Azure Policy' -Severity 'High' -Status $polStatus -Rationale "Assegnazioni policy: $($data.Policy.Assignments). Compliance: $($data.Policy.CompliancePct)% ($($data.Policy.NonCompliantResources) risorse non conformi)." -Remediation 'Assegna una baseline (Azure Security Benchmark / CAF landing zone) e rimedia le risorse non conformi.'

# Governance: Tagging
$tagStatus = if ($data.Resources.Total -eq 0) { 'Skip' } elseif ($data.Resources.UntaggedPct -le 10) { 'Pass' } elseif ($data.Resources.UntaggedPct -le 40) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'waf.governance.tags' -Title 'Governance — Tagging risorse' -Severity 'Low' -Status $tagStatus -Rationale "Risorse senza tag: $($data.Resources.Untagged)/$($data.Resources.Total) ($($data.Resources.UntaggedPct)%)." -Remediation 'Definisci una tagging policy (owner, costcenter, environment) e applicala via Azure Policy.'

$readiness = Get-PrecheckReadiness -Checks $checks
$data.Readiness = $readiness
$data.Checks = $checks

$data.Summary = @{
    AdvisorTotal        = $data.Advisor.Total
    SecurityRecs        = $data.Advisor.Security
    ReliabilityRecs     = $data.Advisor.HighAvailability
    CostRecs            = $data.Advisor.Cost
    SecureScorePercent  = $scoreVal
    PolicyCompliancePct = $data.Policy.CompliancePct
    TotalResources      = $data.Resources.Total
    UntaggedPct         = $data.Resources.UntaggedPct
    ReadinessScore      = $readiness.score
}

# ---- HTML report ----
$topTypes = ($data.Resources.ByType.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15 | ForEach-Object {
    "<tr><td>$([System.Net.WebUtility]::HtmlEncode($_.Key))</td><td>$($_.Value)</td></tr>"
}) -join "`n"
$advRows = ($data.AdvisorTop | Select-Object -First 25 | ForEach-Object {
    "<tr><td>$([System.Net.WebUtility]::HtmlEncode($_.Category))</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Impact))</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Problem))</td></tr>"
}) -join "`n"

$appendix = @"
<div>
  <h3>Appendice tecnica</h3>
  <h4>Advisor — raccomandazioni High impact (top 25)</h4>
  <table><thead><tr><th>Pilastro</th><th>Impact</th><th>Problema</th></tr></thead><tbody>$advRows</tbody></table>
  <h4>Inventario risorse per tipo (top 15)</h4>
  <table><thead><tr><th>Tipo</th><th>Count</th></tr></thead><tbody>$topTypes</tbody></table>
</div>
"@

$aiPayload = @{
    solution = 'Azure Posture Assessment (Well-Architected / CAF)'
    summary  = $data.Summary
    checks   = $checks
    advisor  = $data.Advisor
}
$aiHtml = Invoke-EnterpriseOpenAIHtml -SolutionName 'Azure Posture Assessment' -Payload $aiPayload

$kpis = @{
    Kpi1Label = 'Advisor recs'; Kpi1Value = $data.Advisor.Total
    Kpi2Label = 'Secure Score'; Kpi2Value = "$scoreVal%"
    Kpi3Label = 'Policy compliance'; Kpi3Value = "$($data.Policy.CompliancePct)%"
    Kpi4Label = 'Risorse'; Kpi4Value = $data.Resources.Total
}

$guide = @()
foreach ($c in $checks) {
    if ($c.status -in @('Fail','Warn') -and $c.remediation) {
        $guide += [ordered]@{ title = [string]$c.title; why = [string]$c.rationale; how = [string]$c.remediation; when = [string]$c.severity }
    }
}
if ($guide.Count -eq 0) { $guide += 'Postura allineata al Well-Architected Framework. Mantieni monitoraggio Advisor e review periodiche.' }

$htmlContent = New-EnterpriseHtmlReport -SolutionName 'Azure Posture Assessment' -Summary $kpis -Checks $checks -ImplementationGuide $guide -AiHtml $aiHtml -LegacyHtml $appendix -Context @{
    SubscriptionName = $data.Subscription.Name
    SubscriptionId   = $SubscriptionId
    Timestamp        = $data.Timestamp
}

$htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$data['ReportHTML'] = $htmlContent
$jsonPath = $OutputPath -replace "\.html$", ".json"
$data | ConvertTo-Json -Depth 15 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Host "=== AZURE POSTURE DONE === Time: $([math]::Round(((Get-Date)-$startTime).TotalSeconds))s Readiness: $($readiness.score)%"
