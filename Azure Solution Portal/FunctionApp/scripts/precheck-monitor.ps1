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

$currentSubId = [string]$SubscriptionId
$machines = @()
if ($data.AzureVMs) { $machines += @($data.AzureVMs) }
if ($data.ArcServers) { $machines += @($data.ArcServers) }

$dcrs = @()
if ($data.DataCollectionRules) { $dcrs = @($data.DataCollectionRules) }
$workspaces = @()
if ($data.LogAnalyticsWorkspaces) { $workspaces = @($data.LogAnalyticsWorkspaces) }
$assocs = @()
if ($data.DCRAssociations) { $assocs = @($data.DCRAssociations) }

$dcrWorkspaceIds = @(
    $dcrs | ForEach-Object {
        if ($_.Destinations -and $_.Destinations.WorkspaceResourceIds) { @($_.Destinations.WorkspaceResourceIds) } else { @() }
    }
) | Where-Object { $_ } | Select-Object -Unique

$dcrWorkspaceSubIds = @(
    $dcrs | ForEach-Object {
        if ($_.Destinations -and $_.Destinations.WorkspaceSubscriptionIds) { @($_.Destinations.WorkspaceSubscriptionIds) } else { @() }
    }
) | Where-Object { $_ } | Select-Object -Unique

$hasReferencedExternalWorkspace = @($dcrWorkspaceSubIds | Where-Object { $_ -and $_ -ne $currentSubId }).Count -gt 0

$amaMachines = @($machines | Where-Object { $_.HasAMA -eq $true })
$legacyMmaMachines = @($machines | Where-Object { $_.HasLegacyMMA -eq $true })
$unmonitoredMachines = @($machines | Where-Object { -not $_.HasAMA -and -not $_.HasLegacyMMA })

$assocByMachine = @{}
foreach ($a in $assocs) {
    $n = [string]$a.MachineName
    if (-not $n) { continue }
    if (-not $assocByMachine.ContainsKey($n)) { $assocByMachine[$n] = @() }
    if ($a.DataCollectionRuleId) { $assocByMachine[$n] += [string]$a.DataCollectionRuleId }
}
$machinesWithAssoc = @($machines | Where-Object { $assocByMachine.ContainsKey([string]$_.Name) })
$machinesAmaWithoutAssoc = @($amaMachines | Where-Object { -not $assocByMachine.ContainsKey([string]$_.Name) })

$checks = @()
$ama = [double]($data.Summary.AMA_Coverage_Percent)
$amaStatus = if ($ama -ge 90) { 'Pass' } elseif ($ama -ge 60) { 'Warn' } else { 'Fail' }
$checks += New-PrecheckCheck -Id 'monitor.ama' -Title 'Copertura Azure Monitor Agent (AMA)' -Severity 'Critical' -Status $amaStatus -Rationale "AMA coverage: $ama% (VM totali: $($data.Summary.TotalMachines))." -Remediation 'Distribuire AMA sulle VM (policy/automation) e rimuovere MMA legacy dove possibile.'

$workspacesStatus = if ($data.Summary.TotalWorkspaces -gt 0) { 'Pass' } elseif ($hasReferencedExternalWorkspace) { 'Warn' } else { 'Fail' }
$wsRationale = if ($data.Summary.TotalWorkspaces -gt 0) {
    "Workspaces nella subscription: $($data.Summary.TotalWorkspaces)."
} elseif ($hasReferencedExternalWorkspace) {
    "Nessun workspace trovato nella subscription, ma le DCR puntano a workspace in altre subscription: $($dcrWorkspaceSubIds -join ', ')."
} else {
    "Nessun Log Analytics Workspace trovato nella subscription e nessuna DCR con destinazione workspace rilevata."
}
$checks += New-PrecheckCheck -Id 'monitor.workspaces' -Title 'Log Analytics Workspace (destinazione dati)' -Severity 'High' -Status $workspacesStatus -Rationale $wsRationale -Remediation 'Definisci un workspace centrale (o dedicato) e assicurati che le DCR inviino i dati a quel workspace.'

$dcrStatus = if ($data.Summary.TotalDCRs -gt 0) { 'Pass' } else { 'Warn' }
$checks += New-PrecheckCheck -Id 'monitor.dcr' -Title 'Data Collection Rules (DCR)' -Severity 'High' -Status $dcrStatus -Rationale "DCR: $($data.Summary.TotalDCRs) • Associations: $($data.Summary.TotalDCRAssociations)." -Remediation 'Definire DCR standard (perf + logs) e associare le macchine target (VM/Arc).'

$assocStatus = if ($amaMachines.Count -eq 0) { 'Skip' } elseif ($machinesAmaWithoutAssoc.Count -eq 0 -and $assocs.Count -gt 0) { 'Pass' } elseif ($assocs.Count -gt 0) { 'Warn' } else { 'Fail' }
$assocRationale = if ($amaMachines.Count -eq 0) {
    'Nessuna macchina con AMA rilevata: associazioni DCR verificabili dopo deploy AMA.'
} else {
    "Macchine con AMA: $($amaMachines.Count) • con DCR association: $($machinesWithAssoc.Count) • AMA senza association: $($machinesAmaWithoutAssoc.Count)."
}
$checks += New-PrecheckCheck -Id 'monitor.associations' -Title 'Associazioni DCR su macchine con AMA' -Severity 'Critical' -Status $assocStatus -Rationale $assocRationale -Remediation 'Associa la DCR alle VM/Arc con AMA (manuale o via policy). Senza association, i dati non vengono inviati al workspace.'

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

$enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }

function Convert-MachinesToListHtml {
    param(
        [Parameter(Mandatory)] [array] $Machines,
        [Parameter()] [int] $Max = 15
    )

    if (-not $Machines -or $Machines.Count -eq 0) { return '<span class="muted">Nessuna.</span>' }
    $rows = @($Machines | Select-Object -First $Max | ForEach-Object {
        $n = & $enc $_.Name
        $rg = if ($_.ResourceGroup) { & $enc $_.ResourceGroup } else { '—' }
        $t = if ($_.Type) { & $enc $_.Type } else { 'VM' }
        "<li><b>$n</b> <span class='muted'>($t • RG: $rg)</span></li>"
    })
    $suffix = if ($Machines.Count -gt $Max) { "<li class='muted'>... +$($Machines.Count - $Max) altre</li>" } else { '' }
    return "<ul style='margin:8px 0 0 18px'>" + ($rows -join '') + $suffix + "</ul>"
}

function Convert-WorkspacesToTableHtml {
    param(
        [Parameter(Mandatory)] [array] $Workspaces
    )

    if (-not $Workspaces -or $Workspaces.Count -eq 0) { return '<span class="muted">Nessun workspace nella subscription.</span>' }
    $rows = foreach ($ws in $Workspaces) {
        $name = & $enc $ws.Name
        $rg = & $enc $ws.ResourceGroup
        $loc = & $enc $ws.Location
        $ret = if ($ws.RetentionInDays -ne $null) { [string]$ws.RetentionInDays } else { 'N/A' }
        $vmi = if ($ws.HasVMInsights) { '<span class="badge pass">VMInsights</span>' } else { '<span class="badge skip">VMInsights off</span>' }
        "<tr><td>$name</td><td>$rg</td><td>$loc</td><td>$ret</td><td>$vmi</td></tr>"
    }
    return @"
<table style="margin-top:10px">
  <thead><tr><th>Workspace</th><th>RG</th><th>Region</th><th>Retention (days)</th><th>Note</th></tr></thead>
  <tbody>$($rows -join "`n")</tbody>
</table>
"@
}

function Convert-DcrToTableHtml {
    param(
        [Parameter(Mandatory)] [array] $Dcrs
    )

    if (-not $Dcrs -or $Dcrs.Count -eq 0) { return '<span class="muted">Nessuna DCR trovata nella subscription.</span>' }

    $rows = foreach ($d in $Dcrs) {
        $name = & $enc $d.Name
        $rg = & $enc $d.ResourceGroup
        $type = & $enc $d.Type
        $destSubs = @()
        if ($d.Destinations -and $d.Destinations.WorkspaceSubscriptionIds) { $destSubs = @($d.Destinations.WorkspaceSubscriptionIds) }
        $destText = if ($destSubs.Count -gt 0) { (& $enc ($destSubs -join ', ')) } else { 'N/A' }
        "<tr><td>$name</td><td>$rg</td><td>$type</td><td>$destText</td></tr>"
    }

    return @"
<table style="margin-top:10px">
  <thead><tr><th>DCR</th><th>RG</th><th>Type</th><th>Workspace SubIds (dest)</th></tr></thead>
  <tbody>$($rows -join "`n")</tbody>
</table>
"@
}

$implParts = @()
$implParts += "<h3>Deep-dive dell'ambiente rilevato</h3>"
$implParts += "<ul style='margin:8px 0 0 18px'>"
$implParts += "<li><b>Macchine</b>: Totali $($data.Summary.TotalMachines) (Azure VM: $($data.Summary.AzureVMs), Arc: $($data.Summary.ArcServers)).</li>"
$implParts += "<li><b>Agenti</b>: AMA $($data.Summary.MachinesWithAMA), MMA legacy $($data.Summary.MachinesWithLegacyMMA), non monitorate $($data.Summary.UnmonitoredMachines).</li>"
$implParts += "<li><b>Workspace</b>: trovati nella subscription $($data.Summary.TotalWorkspaces). Workspace referenziati da DCR: $($dcrWorkspaceIds.Count) (subIds: $([string]($dcrWorkspaceSubIds -join ', '))).</li>"
$implParts += "<li><b>DCR</b>: $($data.Summary.TotalDCRs) • Associazioni DCR: $($data.Summary.TotalDCRAssociations).</li>"
$implParts += "<li><b>Alerting</b>: Action Groups $($data.Summary.TotalActionGroups) • Metric Alerts $($data.Summary.TotalMetricAlerts) • Log Alerts $($data.Summary.TotalLogAlerts).</li>"
$implParts += "</ul>"

$implParts += "<h3 style='margin-top:14px'>Guida operativa: cosa fare in questo ambiente</h3>"
$implParts += "<ol style='margin:8px 0 0 18px'>"

# Step 1: Workspace decision
if ($workspaces.Count -gt 0) {
    $preferredWs = @($workspaces | Where-Object { $_.HasVMInsights -eq $true } | Select-Object -First 1)
    if (-not $preferredWs) { $preferredWs = @($workspaces | Select-Object -First 1) }
    $prefName = if ($preferredWs) { [string]$preferredWs.Name } else { '' }
    $prefRg = if ($preferredWs) { [string]$preferredWs.ResourceGroup } else { '' }
    $implParts += "<li><b>Conferma il Log Analytics Workspace target</b>: in questa subscription esistono già workspaces. Consigliato: <b>$(& $enc $prefName)</b> (RG: $(& $enc $prefRg))."
    $implParts += Convert-WorkspacesToTableHtml -Workspaces $workspaces
    $implParts += "</li>"
} elseif ($hasReferencedExternalWorkspace) {
    $implParts += "<li><b>Identifica il workspace centrale</b>: non ho trovato workspaces in questa subscription, ma le DCR puntano a workspace in altre subscription (<b>$(& $enc ($dcrWorkspaceSubIds -join ', '))</b>)."
    $implParts += "<div class='muted' style='margin-top:6px'>Azione consigliata: riesegui il precheck selezionando anche la/le subscription dei workspace per verificare retention, soluzioni e compliance.</div>"
    $implParts += "</li>"
} else {
    $implParts += "<li><b>Creare/standardizzare un Log Analytics Workspace</b>: non ho trovato workspaces né DCR che inviano a un workspace esistente. Per abilitare il monitoring, crea un workspace (dedicato o centrale) e definisci retention/quota in base a compliance.</li>"
}

# Step 2: DCR
if ($dcrs.Count -gt 0) {
    $implParts += "<li><b>Allinea le Data Collection Rules</b>: sono presenti DCR in subscription. Verifica che includano stream perf/log e che la destinazione Log Analytics sia corretta (workspace centrale)."
    $implParts += Convert-DcrToTableHtml -Dcrs $dcrs
    $implParts += "</li>"
} else {
    $implParts += "<li><b>Deploy DCR standard</b>: nessuna DCR trovata. Deploya una DCR standard (perf + eventlog/syslog) puntata al workspace target.</li>"
}

# Step 3: AMA rollout
if ($unmonitoredMachines.Count -gt 0) {
    $implParts += "<li><b>Distribuisci AMA sulle macchine non monitorate</b>: ho trovato <b>$($unmonitoredMachines.Count)</b> macchine senza AMA/MMA. Deploya AMA (preferibilmente via Azure Policy) e verifica che l'estensione sia in stato 'Provisioning succeeded'."
    $implParts += (Convert-MachinesToListHtml -Machines $unmonitoredMachines -Max 15)
    $implParts += "</li>"
} else {
    $implParts += "<li><b>Copertura AMA</b>: tutte le macchine risultano già con AMA o MMA legacy. Focus su associazioni DCR e destinazione workspace.</li>"
}

if ($legacyMmaMachines.Count -gt 0) {
    $implParts += "<li><b>Migrazione MMA → AMA</b>: rilevate <b>$($legacyMmaMachines.Count)</b> macchine con MMA legacy. Pianifica la migrazione ad AMA per evitare tecnologie deprecate.</li>"
}

# Step 4: DCR associations on AMA machines
if ($amaMachines.Count -gt 0 -and $machinesAmaWithoutAssoc.Count -gt 0) {
    $implParts += "<li><b>Associa le DCR alle macchine con AMA</b>: ho trovato <b>$($machinesAmaWithoutAssoc.Count)</b> macchine con AMA ma senza DCR association. Senza association i dati non arrivano al workspace."
    $implParts += (Convert-MachinesToListHtml -Machines $machinesAmaWithoutAssoc -Max 15)
    $implParts += "</li>"
} elseif ($amaMachines.Count -gt 0) {
    $implParts += "<li><b>Associazioni DCR</b>: non risultano gap evidenti (AMA presenti e associazioni rilevate). Verifica comunque che le DCR puntino al workspace corretto.</li>"
}

# Step 5: Alerting baseline
$implParts += "<li><b>Alerting & action group</b>: action groups trovati: <b>$($data.Summary.TotalActionGroups)</b>; alert rules totali: <b>$totalAlerts</b>. Se non hai una baseline completa, deploya alert CPU/Memoria/Disco/Heartbeat e routing verso il tuo ITSM/on-call.</li>"

# Step 6: Validation
$implParts += "<li><b>Validazione post-deploy</b>: dopo il deploy, verifica ingestione dati nel workspace target (es. query: <code>Heartbeat | summarize dcount(Computer)</code> e <code>InsightsMetrics | summarize count() by Name</code>).</li>"

$implParts += "</ol>"

$implementationHtml = ($implParts -join "`n")

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

$enterpriseHtml = New-EnterpriseHtmlReport -SolutionName 'Azure Monitor Hub' -Summary $kpis -Checks $checks -AiHtml $aiHtml -ImplementationHtml $implementationHtml -LegacyHtml $legacyHtml -Context $context
$data.ReportHTML = $enterpriseHtml

$enterpriseHtml | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$data | ConvertTo-Json -Depth 20 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force
