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
$scoreStatus = if ($score -ge 80) { 'Pass' } elseif ($score -ge 50) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'defender.securescore' -Title 'Secure Score (posture)' -Severity 'Critical' -Status $scoreStatus -Rationale "Secure Score: $score%." -Remediation 'Esegui remediation delle raccomandazioni High/Medium con ownership e scadenze (SLA).'

$plansStatus = if ($data.Summary.EnabledPlans -ge 3) { 'Pass' } elseif ($data.Summary.EnabledPlans -ge 1) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'defender.plans' -Title 'Defender plans attivi (Standard)' -Severity 'High' -Status $plansStatus -Rationale "Piani Standard: $($data.Summary.EnabledPlans) / $($data.Summary.TotalPlans)." -Remediation 'Abilita i piani necessari (Servers/Storage/KeyVault/ARM/CSPM) in base al perimetro.'

$contactsStatus = if ($data.Summary.SecurityContactsCount -ge 1) { 'Pass' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'defender.contacts' -Title 'Security contact configurato' -Severity 'High' -Status $contactsStatus -Rationale "Contatti: $($data.Summary.SecurityContactsCount)." -Remediation 'Configura security contact (email/ruoli) e flusso di notifica per incident response.'

$recsStatus = if ($data.Summary.HighSeverityRecs -eq 0) { 'Pass' } elseif ($data.Summary.HighSeverityRecs -le 10) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'defender.recs' -Title 'Raccomandazioni High severity' -Severity 'Medium' -Status $recsStatus -Rationale "High severity: $($data.Summary.HighSeverityRecs)." -Remediation 'Prioritizza le raccomandazioni High; abilita owner assignment e tracking.'

$readiness = Get-PrecheckReadiness -Checks $checks
$data.Readiness = $readiness
$data.Checks = $checks
if ($data.Summary -is [hashtable]) {
    $data.Summary['ReadinessScore'] = $readiness.score
} else {
    $data.Summary | Add-Member -NotePropertyName 'ReadinessScore' -NotePropertyValue $readiness.score -Force
}

$enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }

function Convert-ToListHtml {
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

$enabledPlans = @($data.DefenderPlans | Where-Object { $_.PricingTier -eq 'Standard' })
$disabledPlans = @($data.DefenderPlans | Where-Object { $_.PricingTier -ne 'Standard' })
$topHigh = @($data.TopRecommendations | Where-Object { $_.Severity -eq 'High' } | Select-Object -First 15)
$topAny = @($data.TopRecommendations | Select-Object -First 15)

$impl = @()
$impl += "<h3>Deep-dive dell'ambiente rilevato</h3>"
$impl += "<ul style='margin:8px 0 0 18px'>"
$impl += "<li><b>Secure Score</b>: $($data.Summary.SecureScorePercent)%.</li>"
$impl += "<li><b>Defender plans</b>: Standard $($data.Summary.EnabledPlans) / Totali $($data.Summary.TotalPlans) (Free: $($data.Summary.FreePlans)).</li>"
$impl += "<li><b>Raccomandazioni</b>: totali $($data.Summary.TotalRecommendations) (High: $($data.Summary.HighSeverityRecs), Medium: $($data.Summary.MediumSeverityRecs)).</li>"
$impl += "<li><b>Security contact</b>: $($data.Summary.SecurityContactsCount) • Auto-provisioning enabled: $($data.Summary.AutoProvisionEnabled) • Policy assignments security: $($data.Summary.SecurityPoliciesCount).</li>"
$impl += "</ul>"

$impl += "<h3 style='margin-top:14px'>Guida operativa: cosa fare in questo ambiente</h3>"
$impl += "<ol style='margin:8px 0 0 18px'>"

if ($data.Summary.EnabledPlans -eq 0) {
    $impl += "<li><b>Abilita Defender for Cloud (baseline)</b>: nessun piano Standard rilevato. Abilita almeno CSPM e i piani core (Servers, Storage, Key Vault, Resource Manager) in base al perimetro.</li>"
} else {
    $impl += "<li><b>Allinea i piani Defender</b>: piani Standard attivi: <b>$($enabledPlans.Count)</b>. Valuta se mancano piani rilevanti per i tuoi workload. Esempio: Servers/Containers/SQL/Storage/KeyVault/ARM.</li>"
}

if ($disabledPlans.Count -gt 0) {
    $impl += "<li><b>Piani non Standard (da valutare)</b>: questi piani risultano non in Standard tier (Free/Off)."
    $impl += (Convert-ToListHtml -Items $disabledPlans -Max 18 -ToLi { param($p) "<li><b>$(& $enc $p.Name)</b> <span class='muted'>(Tier: $(& $enc $p.PricingTier) • SubPlan: $(& $enc $p.SubPlan))</span></li>" })
    $impl += "</li>"
}

if ($data.Summary.SecurityContactsCount -eq 0) {
    $impl += "<li><b>Configura Security Contact</b>: nessun contatto trovato. Imposta email/ruoli e abilita le notifiche per alert e posture changes (SOC/IR).</li>"
} else {
    $impl += "<li><b>Security Contact</b>: già configurato. Verifica che le mail siano di un gruppo (non persona) e che il routing incidenti sia conforme al processo SOC/IR.</li>"
}

if ($data.Summary.AutoProvisionEnabled -eq 0) {
    $impl += "<li><b>Auto provisioning (agent)</b>: non risulta abilitato. Valuta auto-provisioning (MDE/AMA) per standardizzare la copertura sui server e ridurre drift.</li>"
} else {
    $impl += "<li><b>Auto provisioning</b>: risulta attivo. Verifica scope, exclusions e compatibilità con la tua baseline (AMA, MDE, proxy, egress).</li>"
}

if ($data.Summary.HighSeverityRecs -gt 0) {
    $impl += "<li><b>Remediation prioritaria (High)</b>: ci sono raccomandazioni High severity aperte. Definisci ownership e SLA e pianifica remediation a sprint."
    $impl += (Convert-ToListHtml -Items $topHigh -Max 12 -ToLi { param($r) "<li><b>$(& $enc $r.Title)</b> <span class='muted'>(ResourceType: $(& $enc $r.ResourceType))</span></li>" })
    $impl += "</li>"
} else {
    $impl += "<li><b>High severity</b>: non risultano raccomandazioni High tra le top raccolte. Continua con hardening e controllo drift (policy).</li>"
}

if ($data.Summary.SecurityPoliciesCount -eq 0) {
    $impl += "<li><b>Governance (Azure Policy)</b>: non risultano policy security rilevanti. Assegna baseline come Microsoft Cloud Security Benchmark (MCSB) o iniziative interne e monitora compliance.</li>"
} else {
    $impl += "<li><b>Governance</b>: sono presenti policy assignments security. Verifica che coprano tagging, security baseline, diagnostic settings, e che abbiano remediation tasks dove applicabile.</li>"
}

$impl += "<li><b>Validazione post-deploy</b>: controlla che Secure Score inizi a migliorare, che i piani siano attivi (pricing), e che le raccomandazioni si riducano con trend. KPI: secure score, #high recs, coverage agent, compliance policy.</li>"
$impl += "</ol>"

$implementationHtml = ($impl -join "`n")

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

$htmlContent = New-EnterpriseHtmlReport -SolutionName 'Microsoft Defender for Cloud' -Summary $kpis -Checks $checks -AiHtml $aiHtml -ImplementationHtml $implementationHtml -LegacyHtml $appendix -Context @{
    SubscriptionName = $data.Subscription.Name
    SubscriptionId   = $SubscriptionId
    Timestamp        = $data.Timestamp
}

$htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$data['ReportHTML'] = $htmlContent
$jsonPath = $OutputPath -replace "\.html$", ".json"
$data | ConvertTo-Json -Depth 15 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Host "=== DEFENDER PRECHECK DONE === Time: $([math]::Round(((Get-Date)-$startTime).TotalSeconds))s Readiness: $($readiness.score)%"

