<#
.SYNOPSIS
Azure Monitor Deep Analysis - Wrapper entrypoint
.NOTES
Keeps backward compatibility with historical script name (testluca.ps1).
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\\AzureMonitorReport.html",

    [Parameter(Mandatory=$false)]
    [switch]$SkipDCRAssociations
)

$legacyScript = Join-Path $PSScriptRoot 'testluca.ps1'
if (-not (Test-Path $legacyScript)) {
    throw "Script legacy non trovato: $legacyScript"
}

& $legacyScript @PSBoundParameters

# Post-process to enterprise format (keeps compatibility with existing frontend fields)
Import-Module (Join-Path $PSScriptRoot 'lib/EnterprisePrecheck.psm1') -Force

$jsonPath = $OutputPath -replace "\.html$", ".json"
if (-not (Test-Path $jsonPath)) {
    throw "JSON non generato dal legacy script: $jsonPath"
}

$data = Get-Content $jsonPath -Raw | ConvertFrom-Json -Depth 20

$checks = @()
$ama = [double]($data.Summary.AMA_Coverage_Percent)
$checks += New-PrecheckCheck -Id 'monitor.ama' -Title 'Copertura Azure Monitor Agent (AMA)' -Severity 'Critical' -Status (
    if ($ama -ge 90) { 'Pass' } elseif ($ama -ge 60) { 'Warn' } else { 'Fail' }
) -Rationale "AMA coverage: $ama% (VM totali: $($data.Summary.TotalMachines))." -Remediation 'Distribuire AMA sulle VM (policy/automation) e rimuovere MMA legacy dove possibile.'

$checks += New-PrecheckCheck -Id 'monitor.workspaces' -Title 'Log Analytics Workspace' -Severity 'High' -Status (
    if ($data.Summary.TotalWorkspaces -gt 0) { 'Pass' } else { 'Fail' }
) -Rationale "Workspaces: $($data.Summary.TotalWorkspaces)." -Remediation 'Creare/standardizzare un Log Analytics Workspace e retention in base a compliance.'

$checks += New-PrecheckCheck -Id 'monitor.dcr' -Title 'Data Collection Rules (DCR)' -Severity 'High' -Status (
    if ($data.Summary.TotalDCRs -gt 0) { 'Pass' } else { 'Warn' }
) -Rationale "DCR: $($data.Summary.TotalDCRs)." -Remediation 'Definire DCR standard (perf + logs) e associare le VM target.'

$totalAlerts = [int]($data.Summary.TotalMetricAlerts + $data.Summary.TotalLogAlerts)
$checks += New-PrecheckCheck -Id 'monitor.alerts' -Title 'Alert rules configurati' -Severity 'Medium' -Status (
    if ($totalAlerts -ge 4) { 'Pass' } elseif ($totalAlerts -ge 1) { 'Warn' } else { 'Warn' }
) -Rationale "Alert totali (metric+log): $totalAlerts." -Remediation 'Definire alert CPU/Memoria/Disco/Heartbeat con action group e routing (ITSM).'

$readiness = Get-PrecheckReadiness -Checks $checks
$data | Add-Member -NotePropertyName 'Readiness' -NotePropertyValue $readiness -Force
$data | Add-Member -NotePropertyName 'Checks' -NotePropertyValue $checks -Force
$data.Summary.ReadinessScore = $readiness.score

$legacyHtml = $data.ReportHTML
$data | Add-Member -NotePropertyName 'LegacyReportHTML' -NotePropertyValue $legacyHtml -Force

$kpis = @{
    Kpi1Label = 'VM Totali'
    Kpi1Value = $data.Summary.TotalMachines
    Kpi2Label = 'AMA coverage'
    Kpi2Value = "$ama%"
    Kpi3Label = 'Workspaces'
    Kpi3Value = $data.Summary.TotalWorkspaces
    Kpi4Label = 'DCR'
    Kpi4Value = $data.Summary.TotalDCRs
}

$aiPayload = @{
    solution = 'Azure Monitor Hub'
    summary  = $data.Summary
    checks   = $checks
    topUnmonitored = @($data.AzureVMs | Where-Object { -not $_.HasAMA } | Select-Object -First 20 Name, ResourceGroup, OsType)
}
$aiHtml = Invoke-EnterpriseOpenAIHtml -SolutionName 'Azure Monitor Hub' -Payload $aiPayload

$context = @{
    SubscriptionName = $data.Subscription.Name
    SubscriptionId   = $data.Subscription.Id
    Timestamp        = $data.Timestamp
}

$enterpriseHtml = New-EnterpriseHtmlReport -SolutionName 'Azure Monitor Hub' -Summary $kpis -Checks $checks -AiHtml $aiHtml -LegacyHtml $legacyHtml -Context $context
$data.ReportHTML = $enterpriseHtml

$enterpriseHtml | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$data | ConvertTo-Json -Depth 20 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force
