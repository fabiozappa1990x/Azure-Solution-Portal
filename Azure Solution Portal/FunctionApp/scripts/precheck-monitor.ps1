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
$amaStatus = if ($ama -ge 90) { 'Pass' } elseif ($ama -ge 60) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'monitor.ama' -Title 'Copertura Azure Monitor Agent (AMA)' -Severity 'Critical' -Status $amaStatus -Rationale "AMA coverage: $ama% (VM totali: $($data.Summary.TotalMachines))." -Remediation 'Distribuire AMA sulle VM (policy/automation) e rimuovere MMA legacy dove possibile.'

$workspacesStatus = if ($data.Summary.TotalWorkspaces -gt 0) { 'Pass' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'monitor.workspaces' -Title 'Log Analytics Workspace' -Severity 'High' -Status $workspacesStatus -Rationale "Workspaces: $($data.Summary.TotalWorkspaces)." -Remediation 'Creare/standardizzare un Log Analytics Workspace e retention in base a compliance.'

$dcrStatus = if ($data.Summary.TotalDCRs -gt 0) { 'Pass' } else { 'Warn' }
$checks += New-PrecheckCheck -Id 'monitor.dcr' -Title 'Data Collection Rules (DCR)' -Severity 'High' -Status $dcrStatus -Rationale "DCR: $($data.Summary.TotalDCRs)." -Remediation 'Definire DCR standard (perf + logs) e associare le VM target.'

$totalAlerts = [int]($data.Summary.TotalMetricAlerts + $data.Summary.TotalLogAlerts)
$alertsStatus = if ($totalAlerts -ge 4) { 'Pass' } elseif ($totalAlerts -ge 1) { 'Warn' } else { 'Warn' }
$checks += New-PrecheckCheck -Id 'monitor.alerts' -Title 'Alert rules configurati' -Severity 'Medium' -Status $alertsStatus -Rationale "Alert totali (metric+log): $totalAlerts." -Remediation 'Definire alert CPU/Memoria/Disco/Heartbeat con action group e routing (ITSM).'

$readiness = Get-PrecheckReadiness -Checks $checks
$data | Add-Member -NotePropertyName 'Readiness' -NotePropertyValue $readiness -Force
$data | Add-Member -NotePropertyName 'Checks' -NotePropertyValue $checks -Force
if ($data.Summary -is [hashtable]) {
    $data.Summary['ReadinessScore'] = $readiness.score
} else {
    $data.Summary | Add-Member -NotePropertyName 'ReadinessScore' -NotePropertyValue $readiness.score -Force
}

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

$guide = @()
$totalMachines = [int]($data.Summary.TotalMachines)
$totalWorkspaces = [int]($data.Summary.TotalWorkspaces)
$totalDcr = [int]($data.Summary.TotalDCRs)

if ($totalMachines -gt 0 -and $totalWorkspaces -le 0) {
    $guide += [ordered]@{
        title = 'Definire la destinazione Log Analytics (Workspace)'
        why   = 'Sono presenti risorse (VM/Arc) ma non risulta alcun Log Analytics Workspace nella subscription analizzata.'
        how   = 'Creare o individuare un Workspace centralizzato (landing zone) e verificare che la DCR invii i dati al Workspace corretto.'
        when  = 'Alta'
    }
}

if ($totalDcr -le 0 -and $totalMachines -gt 0) {
    $guide += [ordered]@{
        title = 'Creare una Data Collection Rule (DCR) standard'
        why   = 'Senza DCR non si raccolgono log/performance in modo coerente (AMA).'
        how   = 'Creare DCR (Windows+Linux) con destination Log Analytics e associare le VM/Arc target (script/policy).'
        when  = 'Alta'
    }
}

if ($ama -lt 90) {
    $guide += [ordered]@{
        title = 'Distribuire Azure Monitor Agent (AMA) e rimuovere MMA legacy'
        why   = "Copertura AMA bassa: $ama%."
        how   = 'Usare Azure Policy o automation (deploy) per installare AMA su tutte le VM/Arc e standardizzare le estensioni.'
        when  = if ($ama -lt 60) { 'Alta' } else { 'Media' }
    }
}

if ($guide.Count -eq 0) {
    $guide += 'Nessuna azione immediata: la configurazione base risulta coerente. Procedere con tuning alert, retention e dashboard.'
}

$enterpriseHtml = New-EnterpriseHtmlReport -SolutionName 'Azure Monitor Hub' -Summary $kpis -Checks $checks -ImplementationGuide $guide -AiHtml $aiHtml -LegacyHtml $legacyHtml -Context $context
$data.ReportHTML = $enterpriseHtml

$enterpriseHtml | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$data | ConvertTo-Json -Depth 20 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force
