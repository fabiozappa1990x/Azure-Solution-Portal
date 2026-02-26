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

# === AI ANALYSIS ===
Write-Host "=== AI ANALYSIS ==="
$dataJson = $data | ConvertTo-Json -Depth 8 -Compress

$prompt = @"
Analizza questi dati Microsoft Defender for Cloud e genera un report DETTAGLIATO in ITALIANO in formato HTML.

DATI:
$dataJson

GENERA SEZIONI HTML CON:
1. EXECUTIVE SUMMARY (Secure Score, piani attivi, criticità TOP 3)
2. DEFENDER PLANS STATUS (quali piani attivi/free con impatto sulla sicurezza)
3. TOP RACCOMANDAZIONI (le più critiche da risolvere con priorità)
4. CONTATTI DI SICUREZZA & AUTO-PROVISIONING (stato notifiche e MDE deployment)
5. COMPLIANCE POLICIES (benchmark attivi, gap rispetto a MCSB/CIS)
6. RACCOMANDAZIONI PRIORITARIE (TOP 8 azioni per migliorare la postura di sicurezza)

Usa HTML con <div class="section">, <h2>, <ul>, <table>.
Usa emoji. Sii tecnico ma chiaro. Indica il rischio finanziario/reputazionale.
"@

$aiHeaders = @{ "Content-Type" = "application/json"; "api-key" = $apiKey }
$body = @{
    messages = @(
        @{ role = "system"; content = "Sei un Azure Security Architect esperto in Defender for Cloud e CSPM. Rispondi in italiano con report HTML." }
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
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Defender Precheck Report</title>
<style>
  body{font-family:'Segoe UI',sans-serif;background:#f5f5f5;margin:0;padding:20px}
  .container{max-width:1200px;margin:0 auto;background:white;border-radius:10px;padding:40px;box-shadow:0 2px 10px rgba(0,0,0,.1)}
  h1{color:#d13438;border-bottom:3px solid #d13438;padding-bottom:10px} h2{color:#d13438;margin-top:30px}
  .section{margin:20px 0;padding:20px;background:#f8f9fa;border-left:4px solid #d13438}
  table{width:100%;border-collapse:collapse;margin:15px 0} th{background:#d13438;color:white;padding:12px;text-align:left}
  td{padding:10px;border-bottom:1px solid #ddd}
  .badge-success{background:#28a745;color:white;padding:5px 10px;border-radius:5px}
  .badge-warning{background:#ffc107;color:black;padding:5px 10px;border-radius:5px}
  .badge-danger{background:#dc3545;color:white;padding:5px 10px;border-radius:5px}
</style></head><body><div class="container">
<h1>🔐 Microsoft Defender for Cloud — Precheck Report</h1>
<p><strong>Subscription:</strong> $($data.Subscription.Name)</p>
<p><strong>Data:</strong> $($data.Timestamp)</p>
$aiReport
<div class="section"><h2>📊 Summary</h2>
<table><tr><th>Metrica</th><th>Valore</th></tr>
<tr><td>Secure Score</td><td>$($data.Summary.SecureScorePercent)%</td></tr>
<tr><td>Piani Defender Totali</td><td>$($data.Summary.TotalPlans)</td></tr>
<tr><td>Piani Attivi (Standard)</td><td>$($data.Summary.EnabledPlans)</td></tr>
<tr><td>Piani Non Attivi (Free)</td><td>$($data.Summary.FreePlans)</td></tr>
<tr><td>Raccomandazioni Critiche</td><td>$($data.Summary.HighSeverityRecs)</td></tr>
<tr><td>Raccomandazioni Medie</td><td>$($data.Summary.MediumSeverityRecs)</td></tr>
<tr><td>Contatti Sicurezza</td><td>$($data.Summary.SecurityContactsCount)</td></tr>
<tr><td>Auto-Provisioning ON</td><td>$($data.Summary.AutoProvisionEnabled)</td></tr>
</table></div>
</div></body></html>
"@

$htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$data['ReportHTML'] = $htmlContent
$jsonPath = $OutputPath -replace "\.html$", ".json"
$data | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Host "=== DEFENDER PRECHECK DONE === Time: $([math]::Round(((Get-Date)-$startTime).TotalSeconds))s"
