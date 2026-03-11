<#
.SYNOPSIS
Microsoft Defender for Cloud Deep Analysis - AI-Powered Precheck
.NOTES
Version: 1.0
Uses REST API only. Works with OAuth token from browser via Azure Function.
#>

param(
    [Parameter(Mandatory=$true)]  [string]$SubscriptionId,
    [Parameter(Mandatory=$false)] [string]$OutputPath = ".\Defender-Report.html"
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
Write-Host "=== DEFENDER PRECHECK START ==="

$data = @{
    Timestamp            = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Subscription         = @{}
    DefenderPlans        = @()
    SecureScore          = @{}
    TopRecommendations   = @()
    SecurityContacts     = @()
    AutoProvisionings    = @()
    PolicyAssignments    = @()
    AzureVMs             = @()
    Summary              = @{}
}

# [1] Subscription
Write-Host "[1/8] Subscription..."
$sub = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId"
if ($sub) { $data.Subscription = @{ Name = $sub.displayName; Id = $sub.subscriptionId } }

# [2] Defender Plans
Write-Host "[2/8] Defender Plans (pricings)..."
$pricings = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Security/pricings" -ApiVersion "2024-01-01"
if ($pricings -and $pricings.value) {
    foreach ($p in $pricings.value) {
        $data.DefenderPlans += @{
            Name            = $p.name
            PricingTier     = $p.properties.pricingTier
            SubPlan         = $p.properties.subPlan
            FreeTrialRemaining = $p.properties.freeTrialRemainingTime
        }
    }
    Write-Host "  Found $($data.DefenderPlans.Count) plans"
}

# [3] Secure Score
Write-Host "[3/8] Secure Score..."
$secureScore = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Security/secureScores/ascScore" -ApiVersion "2020-01-01"
if ($secureScore) {
    $data.SecureScore = @{
        Score        = $secureScore.properties.score.current
        Max          = $secureScore.properties.score.max
        Percentage   = $secureScore.properties.score.percentage
        Weight       = $secureScore.properties.weight
    }
    Write-Host "  Secure Score: $($data.SecureScore.Score)/$($data.SecureScore.Max) ($([math]::Round($data.SecureScore.Percentage * 100, 1))%)"
}

# [4] Top Recommendations
Write-Host "[4/8] Top Security Recommendations..."
$recommendations = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Security/assessments" -ApiVersion "2021-06-01"
if ($recommendations -and $recommendations.value) {
    $unhealthy = $recommendations.value | Where-Object { $_.properties.status.code -eq "Unhealthy" }
    $top10     = $unhealthy | Select-Object -First 15
    foreach ($r in $top10) {
        $data.TopRecommendations += @{
            DisplayName    = $r.properties.displayName
            Severity       = $r.properties.metadata.severity
            Status         = $r.properties.status.code
            ResourceType   = $r.properties.resourceDetails.source
        }
    }
    Write-Host "  Found $($unhealthy.Count) unhealthy assessments (showing top 15)"
}

# [5] Security Contacts
Write-Host "[5/8] Security Contacts..."
$contacts = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Security/securityContacts" -ApiVersion "2023-12-01-preview"
if ($contacts -and $contacts.value) {
    foreach ($c in $contacts.value) {
        $data.SecurityContacts += @{
            Name          = $c.name
            Emails        = $c.properties.emails
            Phone         = $c.properties.phone
            AlertNotifs   = $c.properties.notificationsByRole.state
        }
    }
    Write-Host "  Found $($data.SecurityContacts.Count) security contacts"
}

# [6] Auto Provisioning Settings
Write-Host "[6/8] Auto Provisioning Settings..."
$autoProvision = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Security/autoProvisioningSettings" -ApiVersion "2017-08-01-preview"
if ($autoProvision -and $autoProvision.value) {
    foreach ($ap in $autoProvision.value) {
        $data.AutoProvisionings += @{
            Name      = $ap.name
            AutoProvision = $ap.properties.autoProvision
        }
    }
    Write-Host "  Found $($data.AutoProvisionings.Count) auto-provisioning settings"
}

# [7] Security Policy Assignments
Write-Host "[7/8] Security Policies..."
$policies = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/policyAssignments" -ApiVersion "2021-06-01"
if ($policies -and $policies.value) {
    $secPolicies = $policies.value | Where-Object { $_.properties.displayName -match "Defender|Security|Benchmark|CIS" }
    foreach ($p in $secPolicies) {
        $data.PolicyAssignments += @{
            Name        = $p.name
            DisplayName = $p.properties.displayName
            Enforcement = $p.properties.enforcementMode
        }
    }
    Write-Host "  Found $($data.PolicyAssignments.Count) security policies"
}

# [8] Summary
Write-Host "[8/8] Summary..."
$enabledPlans = ($data.DefenderPlans | Where-Object { $_.PricingTier -eq "Standard" }).Count
$freePlans    = ($data.DefenderPlans | Where-Object { $_.PricingTier -eq "Free" }).Count
$scoreRaw     = if ($data.SecureScore.Max -gt 0) { [math]::Round(($data.SecureScore.Score / $data.SecureScore.Max) * 100, 1) } else { 0 }

$data.Summary = @{
    TotalPlans             = $data.DefenderPlans.Count
    EnabledPlans           = $enabledPlans
    FreePlans              = $freePlans
    SecureScorePercent     = $scoreRaw
    TotalRecommendations   = $data.TopRecommendations.Count
    HighSeverityRecs       = ($data.TopRecommendations | Where-Object { $_.Severity -eq "High" }).Count
    MediumSeverityRecs     = ($data.TopRecommendations | Where-Object { $_.Severity -eq "Medium" }).Count
    SecurityContactsCount  = $data.SecurityContacts.Count
    AutoProvisionEnabled   = ($data.AutoProvisionings | Where-Object { $_.AutoProvision -eq "On" }).Count
    SecurityPoliciesCount  = $data.PolicyAssignments.Count
}

Import-Module (Join-Path $PSScriptRoot 'lib/EnterprisePrecheck.psm1') -Force

$checks = @()
$score = [double]$data.Summary.SecureScorePercent
$checks += New-PrecheckCheck -Id 'defender.securescore' -Title 'Secure Score (posture)' -Severity 'Critical' -Status (
    if ($score -ge 80) { 'Pass' } elseif ($score -ge 50) { 'Warn' } else { 'Fail' }
) -Rationale "Secure Score: $score%." -Remediation 'Esegui remediation delle raccomandazioni High/Medium con ownership e scadenze (SLA).'

$checks += New-PrecheckCheck -Id 'defender.plans' -Title 'Defender plans attivi (Standard)' -Severity 'High' -Status (
    if ($data.Summary.EnabledPlans -ge 3) { 'Pass' } elseif ($data.Summary.EnabledPlans -ge 1) { 'Warn' } else { 'Fail' }
) -Rationale "Piani Standard: $($data.Summary.EnabledPlans) / $($data.Summary.TotalPlans)." -Remediation 'Abilita i piani necessari (Servers/Storage/KeyVault/ARM/CSPM) in base al perimetro.'

$checks += New-PrecheckCheck -Id 'defender.contacts' -Title 'Security contact configurato' -Severity 'High' -Status (
    if ($data.Summary.SecurityContactsCount -ge 1) { 'Pass' } else { 'Fail' }
) -Rationale "Contatti: $($data.Summary.SecurityContactsCount)." -Remediation 'Configura security contact (email/ruoli) e flusso di notifica per incident response.'

$checks += New-PrecheckCheck -Id 'defender.recs' -Title 'Raccomandazioni High severity' -Severity 'Medium' -Status (
    if ($data.Summary.HighSeverityRecs -eq 0) { 'Pass' } elseif ($data.Summary.HighSeverityRecs -le 10) { 'Warn' } else { 'Fail' }
) -Rationale "High severity: $($data.Summary.HighSeverityRecs)." -Remediation 'Prioritizza le raccomandazioni High; abilita owner assignment e tracking.'

$readiness = Get-PrecheckReadiness -Checks $checks
$data.Readiness = $readiness
$data.Checks = $checks
$data.Summary.ReadinessScore = $readiness.score

$plansRows = ($data.DefenderPlans | Select-Object -First 40 | ForEach-Object {
    "<tr><td>$($_.Name)</td><td>$($_.PricingTier)</td><td>$($_.SubPlan)</td></tr>"
}) -join "`n"

$recRows = ($data.TopRecommendations | Select-Object -First 30 | ForEach-Object {
    "<tr><td>$($_.Severity)</td><td>$($_.Title)</td><td>$($_.ResourceType)</td></tr>"
}) -join "`n"

$appendix = @"
<div>
  <h3>Appendice tecnica</h3>
  <h4>Defender plans (top 40)</h4>
  <table><thead><tr><th>Plan</th><th>Tier</th><th>SubPlan</th></tr></thead><tbody>$plansRows</tbody></table>
  <h4>Top recommendations (top 30)</h4>
  <table><thead><tr><th>Severity</th><th>Title</th><th>ResourceType</th></tr></thead><tbody>$recRows</tbody></table>
</div>
"@

$aiPayload = @{
    solution = 'Microsoft Defender for Cloud'
    summary  = $data.Summary
    checks   = $checks
    topRecommendations = $data.TopRecommendations | Select-Object -First 15 Severity, Title, ResourceType
    plans = $data.DefenderPlans | Select-Object -First 15 Name, PricingTier, SubPlan
}
$aiHtml = Invoke-EnterpriseOpenAIHtml -SolutionName 'Microsoft Defender for Cloud' -Payload $aiPayload

$kpis = @{
    Kpi1Label = 'Secure Score'
    Kpi1Value = "$score%"
    Kpi2Label = 'Plans (Std)'
    Kpi2Value = $data.Summary.EnabledPlans
    Kpi3Label = 'Recs High'
    Kpi3Value = $data.Summary.HighSeverityRecs
    Kpi4Label = 'Contacts'
    Kpi4Value = $data.Summary.SecurityContactsCount
}

$htmlContent = New-EnterpriseHtmlReport -SolutionName 'Microsoft Defender for Cloud' -Summary $kpis -Checks $checks -AiHtml $aiHtml -LegacyHtml $appendix -Context @{
    SubscriptionName = $data.Subscription.Name
    SubscriptionId   = $SubscriptionId
    Timestamp        = $data.Timestamp
}

$htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$data['ReportHTML'] = $htmlContent
$jsonPath = $OutputPath -replace "\.html$", ".json"
$data | ConvertTo-Json -Depth 15 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Host "=== DEFENDER PRECHECK DONE === Time: $([math]::Round(((Get-Date)-$startTime).TotalSeconds))s Readiness: $($readiness.score)%"

