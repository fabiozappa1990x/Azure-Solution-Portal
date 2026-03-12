<#
.SYNOPSIS
Azure Monitor Hub — Precheck 2.0 (Inventory + Roadmap)
.DESCRIPTION
Deep-dive subscription analysis:
 - Inventory of monitorable resources (Compute + selected PaaS)
 - Current monitoring posture (AMA/DCR for compute, Diagnostic Settings for PaaS)
 - Prerequisites availability (LAW/DCR/DCE/Action Groups)
 - Roadmap: phased remediation plan based on findings
.NOTES
Designed to be called by Azure Function with AZURE_ACCESS_TOKEN.
#>

param(
    [Parameter(Mandatory = $true)]  [string] $SubscriptionId,
    [Parameter(Mandatory = $false)] [string] $OutputPath = ".\\AzureMonitorHub-Precheck2.html"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$accessToken = $env:AZURE_ACCESS_TOKEN
if (-not $accessToken) { throw "AZURE_ACCESS_TOKEN not found." }

Import-Module (Join-Path $PSScriptRoot 'lib/EnterprisePrecheck.psm1') -Force

function Invoke-AzureApi {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter()] [string] $Method = 'GET'
    )

    $headers = @{ Authorization = "Bearer $accessToken"; 'Content-Type' = 'application/json' }
    try {
        $resp = Invoke-RestMethod -Uri $Uri -Headers $headers -Method $Method -ErrorAction Stop
        # auto-pagination
        if ($Method -eq 'GET' -and $resp -and ($resp.PSObject.Properties.Name -contains 'nextLink') -and $resp.nextLink -and
            ($resp.PSObject.Properties.Name -contains 'value') -and ($resp.value -is [System.Collections.IEnumerable])) {
            $all = @()
            $all += @($resp.value)
            $next = $resp.nextLink
            $guard = 0
            while ($next -and $guard -lt 200) {
                $guard++
                $page = Invoke-RestMethod -Uri $next -Headers $headers -Method $Method -ErrorAction Stop
                if ($page -and ($page.PSObject.Properties.Name -contains 'value') -and $page.value) {
                    $all += @($page.value)
                }
                $next = if ($page -and ($page.PSObject.Properties.Name -contains 'nextLink')) { $page.nextLink } else { $null }
            }
            $resp.value = $all
            $resp.nextLink = $null
        }
        return $resp
    } catch {
        return $null
    }
}

function Get-RgFromId {
    param([string] $Id)
    if (-not $Id) { return '' }
    if ($Id -match '/resourceGroups/([^/]+)/') { return $Matches[1] }
    return ''
}

function Get-DiagnosticSettings {
    param([Parameter(Mandatory)] [string] $ResourceId)
    $uri = "https://management.azure.com${ResourceId}/providers/microsoft.insights/diagnosticSettings?api-version=2021-05-01-preview"
    $resp = Invoke-AzureApi -Uri $uri
    if ($resp -and ($resp.PSObject.Properties.Name -contains 'value') -and $resp.value) { return @($resp.value) }
    return @()
}

function Get-WorkspaceLinksFromDiagSettings {
    param([array] $DiagSettings)
    $ids = @()
    foreach ($d in ($DiagSettings | Where-Object { $_ })) {
        $wsId = $null
        if ($d -and ($d.PSObject.Properties.Name -contains 'properties') -and $d.properties) {
            if ($d.properties.PSObject.Properties.Name -contains 'workspaceId') {
                $wsId = $d.properties.workspaceId
            }
        }
        if ($wsId) { $ids += [string]$wsId }
    }
    return @($ids | Where-Object { $_ } | Select-Object -Unique)
}

function Get-VmAmaState {
    param([Parameter(Mandatory)] [string] $VmId)
    $extUri = "https://management.azure.com${VmId}/extensions?api-version=2023-09-01"
    $ext = Invoke-AzureApi -Uri $extUri
    $hasAma = $false
    $extItems = @()
    if ($ext -and ($ext.PSObject.Properties.Name -contains 'value') -and $ext.value) { $extItems = @($ext.value) }
    foreach ($e in $extItems) {
        $n = if ($e -and ($e.PSObject.Properties.Name -contains 'name')) { [string]$e.name } else { '' }
        $t = ''
        if ($e -and ($e.PSObject.Properties.Name -contains 'properties') -and $e.properties) {
            if ($e.properties.PSObject.Properties.Name -contains 'type') { $t = [string]$e.properties.type }
        }
        if ($n -in @('AzureMonitorWindowsAgent','AzureMonitorLinuxAgent') -or $t -in @('AzureMonitorWindowsAgent','AzureMonitorLinuxAgent')) {
            $hasAma = $true
        }
    }

    $dcrUri = "https://management.azure.com${VmId}/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2022-06-01"
    $dcr = Invoke-AzureApi -Uri $dcrUri
    $assoc = @()
    if ($dcr -and ($dcr.PSObject.Properties.Name -contains 'value') -and $dcr.value) { $assoc = @($dcr.value) }
    $assoc = $assoc | Where-Object { $_ }
    $dcrIds = @()
    foreach ($a in $assoc) {
        $rid = $null
        if ($a -and ($a.PSObject.Properties.Name -contains 'properties') -and $a.properties) {
            if ($a.properties.PSObject.Properties.Name -contains 'dataCollectionRuleId') { $rid = $a.properties.dataCollectionRuleId }
        }
        if ($rid) { $dcrIds += [string]$rid }
    }

    return [ordered]@{
        hasAma     = $hasAma
        dcrCount   = @($dcrIds | Where-Object { $_ } | Select-Object -Unique).Count
        dcrIds     = @($dcrIds | Where-Object { $_ } | Select-Object -Unique)
    }
}

$start = Get-Date
$sub = Invoke-AzureApi -Uri "https://management.azure.com/subscriptions/${SubscriptionId}?api-version=2022-12-01"
if (-not $sub) { throw "Subscription non accessibile o non trovata: $SubscriptionId" }

# ---------- Inventory (monitorable resources) ----------
$vmResp = Invoke-AzureApi -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Compute/virtualMachines?api-version=2023-07-01"
$vms = @()
if ($vmResp -and ($vmResp.PSObject.Properties.Name -contains 'value') -and $vmResp.value) { $vms = @($vmResp.value) }
$vms = @($vms | Where-Object { $_ })

$saResp = Invoke-AzureApi -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Storage/storageAccounts?api-version=2023-01-01"
$storageAccounts = @()
if ($saResp -and ($saResp.PSObject.Properties.Name -contains 'value') -and $saResp.value) { $storageAccounts = @($saResp.value) }
$storageAccounts = @($storageAccounts | Where-Object { $_ })

$kvResp = Invoke-AzureApi -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.KeyVault/vaults?api-version=2023-07-01"
$keyVaults = @()
if ($kvResp -and ($kvResp.PSObject.Properties.Name -contains 'value') -and $kvResp.value) { $keyVaults = @($kvResp.value) }
$keyVaults = @($keyVaults | Where-Object { $_ })

# ---------- Prerequisites ----------
$lawResp = Invoke-AzureApi -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.OperationalInsights/workspaces?api-version=2022-10-01"
$workspaces = @()
if ($lawResp -and ($lawResp.PSObject.Properties.Name -contains 'value') -and $lawResp.value) { $workspaces = @($lawResp.value) }
$workspaces = @($workspaces | Where-Object { $_ })

$dcrResp = Invoke-AzureApi -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Insights/dataCollectionRules?api-version=2022-06-01"
$dcrs = @()
if ($dcrResp -and ($dcrResp.PSObject.Properties.Name -contains 'value') -and $dcrResp.value) { $dcrs = @($dcrResp.value) }
$dcrs = @($dcrs | Where-Object { $_ })

$dceResp = Invoke-AzureApi -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Insights/dataCollectionEndpoints?api-version=2022-06-01"
$dces = @()
if ($dceResp -and ($dceResp.PSObject.Properties.Name -contains 'value') -and $dceResp.value) { $dces = @($dceResp.value) }
$dces = @($dces | Where-Object { $_ })

$agResp = Invoke-AzureApi -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Insights/actionGroups?api-version=2023-01-01"
$actionGroups = @()
if ($agResp -and ($agResp.PSObject.Properties.Name -contains 'value') -and $agResp.value) { $actionGroups = @($agResp.value) }
$actionGroups = @($actionGroups | Where-Object { $_ })

# ---------- Monitoring posture ----------
$vmInventory = @()
foreach ($vm in $vms) {
    $id = [string]$vm.id
    $state = Get-VmAmaState -VmId $id
    $vmInventory += [ordered]@{
        type           = 'VirtualMachine'
        name           = [string]$vm.name
        id             = $id
        resourceGroup  = (Get-RgFromId $id)
        location       = [string]$vm.location
        monitored      = ($state.hasAma -and $state.dcrCount -gt 0)
        hasAma         = [bool]$state.hasAma
        dcrAssociations = [int]$state.dcrCount
        dcrIds         = $state.dcrIds
    }
}

$paasInventory = @()
foreach ($sa in $storageAccounts) {
    $id = [string]$sa.id
    $diag = Get-DiagnosticSettings -ResourceId $id
    $wsLinks = @(Get-WorkspaceLinksFromDiagSettings -DiagSettings $diag)
    $paasInventory += [ordered]@{
        type          = 'StorageAccount'
        name          = [string]$sa.name
        id            = $id
        resourceGroup = (Get-RgFromId $id)
        location      = [string]$sa.location
        monitored     = (@($wsLinks).Count -gt 0)
        workspaceIds  = $wsLinks
    }
}

foreach ($kv in $keyVaults) {
    $id = [string]$kv.id
    $diag = Get-DiagnosticSettings -ResourceId $id
    $wsLinks = @(Get-WorkspaceLinksFromDiagSettings -DiagSettings $diag)
    $paasInventory += [ordered]@{
        type          = 'KeyVault'
        name          = [string]$kv.name
        id            = $id
        resourceGroup = (Get-RgFromId $id)
        location      = [string]$kv.location
        monitored     = (@($wsLinks).Count -gt 0)
        workspaceIds  = $wsLinks
    }
}

$allInventory = @($vmInventory + $paasInventory)

$tot = @($allInventory).Count
$mon = @($allInventory | Where-Object { $_.monitored }).Count
$coveragePct = if ($tot -gt 0) { [math]::Round(100 * ($mon / $tot), 0) } else { 0 }

$checks = @()
$checks += New-PrecheckCheck -Id 'mon2.inventory' -Title 'Copertura risorse monitorabili' -Severity 'High' -Status (if ($coveragePct -ge 85) { 'Pass' } elseif ($coveragePct -ge 50) { 'Warn' } else { 'Fail' }) `
    -Rationale "Risorse monitorabili: $tot. Monitorate: $mon ($coveragePct%)." `
    -Remediation 'Completare onboarding delle risorse non monitorate (Compute via AMA+DCR, PaaS via Diagnostic Settings).'

$checks += New-PrecheckCheck -Id 'mon2.law' -Title 'Log Analytics Workspace disponibile' -Severity 'Critical' -Status (if (@($workspaces).Count -gt 0) { 'Pass' } else { 'Fail' }) `
    -Rationale "Workspaces trovati: $(@($workspaces).Count)." `
    -Remediation 'Creare (o individuare) un Log Analytics Workspace centrale e standardizzare retention/region.'

$checks += New-PrecheckCheck -Id 'mon2.dcr' -Title 'Data Collection Rules disponibili' -Severity 'Critical' -Status (if (@($dcrs).Count -gt 0) { 'Pass' } else { 'Warn' }) `
    -Rationale "DCR trovate: $(@($dcrs).Count)." `
    -Remediation 'Creare una DCR standard (Windows+Linux) con destination LAW e policy/script di associazione.'

$checks += New-PrecheckCheck -Id 'mon2.dce' -Title 'Data Collection Endpoint (opzionale)' -Severity 'Medium' -Status (if (@($dces).Count -gt 0) { 'Pass' } else { 'Warn' }) `
    -Rationale "DCE trovate: $(@($dces).Count). (Non sempre necessaria: dipende da network/privatelink)." `
    -Remediation 'Se richiesto (private endpoints / data ingestion isolation), creare una DCE e collegarla alla DCR.'

$checks += New-PrecheckCheck -Id 'mon2.actiongroups' -Title 'Action Groups (notifiche)' -Severity 'Medium' -Status (if (@($actionGroups).Count -gt 0) { 'Pass' } else { 'Warn' }) `
    -Rationale "Action Groups trovati: $(@($actionGroups).Count)." `
    -Remediation 'Creare action group (email/Teams/webhook/ITSM) e usarlo per alert CPU/Mem/Disco/Heartbeat.'

$readiness = Get-PrecheckReadiness -Checks $checks

# ---------- Roadmap (phased) ----------
$roadmap = @()

$missingLaw = (@($workspaces).Count -le 0)
$missingDcr = (@($dcrs).Count -le 0)
$missingAg  = (@($actionGroups).Count -le 0)

$needsFoundation = $missingLaw -or $missingDcr -or $missingAg
$roadmap += [ordered]@{
    phase = 1
    title = 'Foundation: destinazione, raccolta, alerting'
    status = if ($needsFoundation) { 'Needed' } else { 'Done' }
    actions = @(
        if ($missingLaw) { 'Creare o selezionare Log Analytics Workspace (retention, region, RBAC).' }
        if ($missingDcr) { 'Creare DCR standard (perf + logs) e destination verso LAW.' }
        if ($missingAg) { 'Creare Action Group e collegarlo alle alert rule.' }
    ) | Where-Object { $_ }
}

$vmNotMon = @($vmInventory | Where-Object { -not $_.monitored })
$roadmap += [ordered]@{
    phase = 2
    title = 'Onboarding Compute: VM (AMA + DCR association)'
    status = if ($vmNotMon.Count -gt 0) { 'Needed' } else { 'Done' }
    actions = @(
        if ($vmNotMon.Count -gt 0) { "Abilitare AMA e associare DCR sulle VM non monitorate (count: $($vmNotMon.Count))." }
        if (@($vmNotMon | Where-Object { -not $_.hasAma }).Count -gt 0) { "Installare AMA sulle VM senza agente (count: $(@($vmNotMon | Where-Object { -not $_.hasAma }).Count))." }
        if (@($vmNotMon | Where-Object { $_.hasAma -and $_.dcrAssociations -le 0 }).Count -gt 0) { "Associare DCR alle VM con AMA ma senza DCR (count: $(@($vmNotMon | Where-Object { $_.hasAma -and $_.dcrAssociations -le 0 }).Count))." }
    ) | Where-Object { $_ }
}

$paasNotMon = @($paasInventory | Where-Object { -not $_.monitored })
$roadmap += [ordered]@{
    phase = 3
    title = 'Onboarding PaaS: Diagnostic Settings → Log Analytics'
    status = if ($paasNotMon.Count -gt 0) { 'Needed' } else { 'Done' }
    actions = @(
        if ($paasNotMon.Count -gt 0) { "Configurare Diagnostic Settings su risorse PaaS non monitorate (count: $($paasNotMon.Count))." }
        if (@($paasNotMon | Where-Object { $_.type -eq 'StorageAccount' }).Count -gt 0) { "Storage account da abilitare (count: $(@($paasNotMon | Where-Object { $_.type -eq 'StorageAccount' }).Count))." }
        if (@($paasNotMon | Where-Object { $_.type -eq 'KeyVault' }).Count -gt 0) { "Key Vault da abilitare (count: $(@($paasNotMon | Where-Object { $_.type -eq 'KeyVault' }).Count))." }
    ) | Where-Object { $_ }
}

$roadmap += [ordered]@{
    phase = 4
    title = 'Validation & operations'
    status = 'Recommended'
    actions = @(
        'Validare che i dati arrivino nel Workspace (KQL queries, heartbeat, perf counters).'
        'Abilitare workbook/dashboards e definire ownership (Ops/Sec).'
        'Eseguire test di alerting end-to-end (notifiche, escalation, ITSM).'
    )
}

# ---------- Implementation guide (action plan) ----------
$guide = @()
foreach ($p in $roadmap) {
    $title = "Fase $($p.phase) — $($p.title) [$($p.status)]"
    $how = (@($p.actions) -join ' ')
    $guide += [ordered]@{
        title = $title
        why   = 'Roadmap generata sul contesto rilevato nella subscription.'
        how   = $how
        when  = 'Operativo'
    }
}

$kpis = @{
    Kpi1Label = 'Risorse monitorabili'
    Kpi1Value = $tot
    Kpi2Label = 'Monitorate'
    Kpi2Value = "$mon ($coveragePct%)"
    Kpi3Label = 'Workspaces'
    Kpi3Value = @($workspaces).Count
    Kpi4Label = 'DCR'
    Kpi4Value = @($dcrs).Count
}

$appendix = @()
$appendix += "<h3>Inventory — risorse monitorabili</h3>"
$appendix += "<p>Compute e PaaS rilevate nella subscription, con stato di monitoraggio.</p>"
$appendix += "<h4>Virtual Machines (top 80)</h4>"
$vmRows = ($vmInventory | Select-Object -First 80 | ForEach-Object {
    $m = if ($_.monitored) { 'Yes' } else { 'No' }
    "<tr><td>$($_.name)</td><td>$($_.resourceGroup)</td><td>$($_.location)</td><td>$($_.hasAma)</td><td>$($_.dcrAssociations)</td><td>$m</td></tr>"
}) -join "`n"
$appendix += "<table><thead><tr><th>Name</th><th>RG</th><th>Region</th><th>AMA</th><th>DCR assoc</th><th>Monitored</th></tr></thead><tbody>$vmRows</tbody></table>"

$appendix += "<h4>PaaS (Storage/KeyVault) (top 80)</h4>"
$paasRows = ($paasInventory | Select-Object -First 80 | ForEach-Object {
    $m = if ($_.monitored) { 'Yes' } else { 'No' }
    $ws = if ($_.workspaceIds -and @($_.workspaceIds).Count) { (@($_.workspaceIds) -join '<br/>') } else { '' }
    "<tr><td>$($_.type)</td><td>$($_.name)</td><td>$($_.resourceGroup)</td><td>$($_.location)</td><td>$m</td><td>$ws</td></tr>"
}) -join "`n"
$appendix += "<table><thead><tr><th>Type</th><th>Name</th><th>RG</th><th>Region</th><th>Monitored</th><th>Workspace</th></tr></thead><tbody>$paasRows</tbody></table>"

$appendixHtml = '<div>' + ($appendix -join "`n") + '</div>'

$aiPayload = @{
    solution = 'Azure Monitor Hub — Precheck 2.0'
    summary  = @{
        subscription = $sub.displayName
        resourcesMonitorable = $tot
        resourcesMonitored = $mon
        coveragePct = $coveragePct
        workspaces = @($workspaces).Count
        dcr = @($dcrs).Count
    }
    roadmap = $roadmap
    topNotMonitored = @($allInventory | Where-Object { -not $_.monitored } | Select-Object -First 20 type,name,resourceGroup)
}
$aiHtml = Invoke-EnterpriseOpenAIHtml -SolutionName 'Azure Monitor Hub — Precheck 2.0' -Payload $aiPayload

$data = [ordered]@{
    Version = '2.0'
    Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Subscription = [ordered]@{ Id = $SubscriptionId; Name = $sub.displayName }
    Summary = [ordered]@{
        TotalMonitorableResources = $tot
        MonitoredResources        = $mon
        CoveragePercent           = $coveragePct
        TotalVMs                  = @($vmInventory).Count
        TotalPaaS                 = @($paasInventory).Count
        TotalWorkspaces           = @($workspaces).Count
        TotalDCRs                 = @($dcrs).Count
        TotalDCEs                 = @($dces).Count
        TotalActionGroups         = @($actionGroups).Count
        ReadinessScore            = $readiness.score
    }
    Inventory = [ordered]@{
        VirtualMachines = $vmInventory
        PaaS            = $paasInventory
    }
    Roadmap = $roadmap
    Checks = $checks
    Readiness = $readiness
}

$context = @{
    SubscriptionName = $sub.displayName
    SubscriptionId   = $SubscriptionId
    Timestamp        = $data.Timestamp
}

$html = New-EnterpriseHtmlReport -SolutionName 'Azure Monitor Hub — Precheck 2.0' -Summary $kpis -Checks $checks -ImplementationGuide $guide -AiHtml $aiHtml -LegacyHtml $appendixHtml -Context $context
$data['ReportHTML'] = $html

$OutputPath = if ($OutputPath) { $OutputPath } else { ".\\AzureMonitorHub-Precheck2.html" }
$jsonPath = $OutputPath -replace "\\.html$", ".json"

$html | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$data | ConvertTo-Json -Depth 20 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Host "=== MONITOR PRECHECK 2.0 DONE === Time: $([math]::Round(((Get-Date)-$start).TotalSeconds))s Coverage: $coveragePct% Readiness: $($readiness.score)%"
