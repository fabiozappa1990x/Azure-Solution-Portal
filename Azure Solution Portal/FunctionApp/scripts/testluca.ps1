<#
.SYNOPSIS
Azure Monitor Deep Analysis - API-Only Version (Compatible with Azure Function + Browser Token)
.NOTES
Version: 4.0 API-ONLY
Uses only REST API calls, no Az cmdlets required
Works with OAuth token from browser via Azure Function
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\AzureMonitorReport.html",
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipDCRAssociations
)

# Azure OpenAI configuration (from env / Function App settings)
$apiKey          = $env:AZURE_OPENAI_API_KEY
$endpointBase    = $env:AZURE_OPENAI_ENDPOINT
$deploymentName  = $env:AZURE_OPENAI_DEPLOYMENT
$openAiApiVer    = if ($env:AZURE_OPENAI_API_VERSION) { $env:AZURE_OPENAI_API_VERSION } else { "2025-01-01-preview" }
$endpoint        = $null
if ($endpointBase -and $deploymentName) {
    $endpoint = ($endpointBase.TrimEnd('/') + "/openai/deployments/$deploymentName/chat/completions?api-version=$openAiApiVer")
}

# Get access token from environment (set by run.ps1)
$accessToken = $env:AZURE_ACCESS_TOKEN
if (-not $accessToken) {
    Write-Error "AZURE_ACCESS_TOKEN not found. This script must be called from Azure Function."
    exit 1
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-ColorOutput {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

function Invoke-AzureAPI {
    param(
        [string]$Uri,
        [string]$ApiVersion = "2022-12-01",
        [string]$Method = "GET"
    )
    
    $headers = @{
        'Authorization' = "Bearer $accessToken"
        'Content-Type' = 'application/json'
    }
    
    $fullUri = if ($Uri -like "*api-version*") { $Uri } else { "${Uri}?api-version=$ApiVersion" }
    
    try {
        $response = Invoke-RestMethod -Uri $fullUri -Headers $headers -Method $Method -ErrorAction Stop

        # Auto-pagination for list endpoints
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
        Write-Warning "API call failed: $fullUri - $($_.Exception.Message)"
        return $null
    }
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

$startTime = Get-Date

Write-ColorOutput @"
╔════════════════════════════════════════════════════════════════════╗
║     AZURE MONITOR DEEP ANALYZER - v4.0 API-ONLY                   ║
║     Browser Token Compatible Edition                               ║
╚════════════════════════════════════════════════════════════════════╝
"@ "Cyan"

# Initialize data structure
$monitoringData = @{
    Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Subscription = @{}
    AzureVMs = @()
    ArcServers = @()
    VMInsights = @()
    Extensions = @()
    DataCollectionRules = @()
    DCRAssociations = @()
    DCRDetails = @()
    LogAnalyticsWorkspaces = @()
    WorkspaceAgents = @()
    PolicySummary = @{}
    PolicyAssignments = @()
    PolicyCompliance = @()
    ManagedIdentities = @()
    IdentityRoleAssignments = @()
    ActionGroups = @()
    MetricAlerts = @()
    LogAlerts = @()
    ActivityLogAlerts = @()
    ApplicationInsights = @()
    Workbooks = @()
    DiagnosticSettings = @()
    Summary = @{}
}

Write-ColorOutput "`n╔══════════════════════════════════════════════════════════════════════╗" "Cyan"
Write-ColorOutput "║          INIZIO RACCOLTA DATI AZURE MONITOR - API MODE              ║" "Cyan"
Write-ColorOutput "╚══════════════════════════════════════════════════════════════════════╝" "Cyan"

# ═══════════════════════════════════════════════════════════════
# [1/15] SUBSCRIPTION INFO
# ═══════════════════════════════════════════════════════════════
Write-ColorOutput "`n[1/15] Subscription Info..." "Yellow"
$subInfo = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId"
if ($subInfo) {
    $monitoringData.Subscription = @{
        Name = $subInfo.displayName
        Id = $subInfo.subscriptionId
        TenantId = $subInfo.tenantId
    }
    Write-ColorOutput "✓ Subscription: $($subInfo.displayName)" "Green"
}

# ═══════════════════════════════════════════════════════════════
# [2/15] AZURE VMs
# ═══════════════════════════════════════════════════════════════
Write-ColorOutput "`n[2/15] Raccolta Virtual Machines Azure..." "Yellow"
$vms = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Compute/virtualMachines" -ApiVersion "2023-03-01"

if ($vms -and $vms.value) {
    Write-ColorOutput "  ✓ Trovate $($vms.value.Count) VM" "Green"
    
    $counter = 0
    foreach ($vm in $vms.value) {
        $counter++
        $vmName = $vm.name
        $rgName = ($vm.id -split '/')[4]
        
        Write-ColorOutput "  [$counter/$($vms.value.Count)] Analisi $vmName..." "DarkGray"
        
        # Get VM instance view for power state
        $powerState = "Unknown"
        try {
            $vmStatus = Invoke-AzureAPI -Uri "https://management.azure.com$($vm.id)/instanceView" -ApiVersion "2023-03-01"
            if ($vmStatus -and $vmStatus.statuses) {
                $ps = $vmStatus.statuses | Where-Object { $_.code -like "PowerState/*" } | Select-Object -First 1
                if ($ps) { $powerState = $ps.displayStatus }
            }
        } catch { }
        
        # Get VM extensions
        $extUri = "https://management.azure.com$($vm.id)/extensions"
        $extensions = Invoke-AzureAPI -Uri $extUri -ApiVersion "2023-03-01"
        
        $hasAMA = $false
        $hasLegacyMMA = $false
        $hasDependencyAgent = $false
        $extList = @()
        
        if ($extensions -and $extensions.value) {
            Write-ColorOutput "    ✓ Trovate $($extensions.value.Count) estensioni" "DarkGray"
            
            foreach ($ext in $extensions.value) {
                $extList += @{
                    Name = $ext.name
                    Type = $ext.properties.type
                    Publisher = $ext.properties.publisher
                    Version = $ext.properties.typeHandlerVersion
                    Status = $ext.properties.provisioningState
                }
                
                if ($ext.properties.type -match "AzureMonitor.*Agent") {
                    $hasAMA = $true
                    Write-ColorOutput "      → AMA trovato!" "Green"
                }
                if ($ext.properties.type -match "MicrosoftMonitoringAgent|OmsAgent") {
                    $hasLegacyMMA = $true
                    Write-ColorOutput "      → Legacy MMA trovato!" "Yellow"
                }
                if ($ext.properties.type -match "DependencyAgent") {
                    $hasDependencyAgent = $true
                    Write-ColorOutput "      → Dependency Agent trovato!" "Green"
                }
            }
        }
        
        # Identity
        $identityType = "None"
        $principalId = $null
        if ($vm.identity) {
            $identityType = $vm.identity.type
            $principalId = $vm.identity.principalId
        }
        
        $monitoringData.AzureVMs += @{
            Name = $vmName
            ResourceGroup = $rgName
            Location = $vm.location
            ResourceId = $vm.id
            Type = "Azure VM"
            OsType = $vm.properties.storageProfile.osDisk.osType
            VmSize = $vm.properties.hardwareProfile.vmSize
            PowerState = $powerState
            HasAMA = $hasAMA
            HasLegacyMMA = $hasLegacyMMA
            HasDependencyAgent = $hasDependencyAgent
            Extensions = $extList
            ExtensionCount = $extList.Count
            IdentityType = $identityType
            PrincipalId = $principalId
            Tags = $vm.tags
        }
    }
    
    $totalExt = ($monitoringData.AzureVMs | Measure-Object -Property ExtensionCount -Sum).Sum
    $vmsWithAMA = ($monitoringData.AzureVMs | Where-Object { $_.HasAMA }).Count
    Write-ColorOutput "✓ Analizzate $($monitoringData.AzureVMs.Count) VM Azure" "Green"
    Write-ColorOutput "  → Totale estensioni: $totalExt | VM con AMA: $vmsWithAMA" "Cyan"
}

# ═══════════════════════════════════════════════════════════════
# [3/15] ARC SERVERS
# ═══════════════════════════════════════════════════════════════
Write-ColorOutput "`n[3/15] Raccolta Arc-enabled Servers..." "Yellow"
$arcServers = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.HybridCompute/machines" -ApiVersion "2023-03-15-preview"

if ($arcServers -and $arcServers.value) {
    Write-ColorOutput "  Trovati $($arcServers.value.Count) Arc Servers" "Green"
    
    foreach ($arc in $arcServers.value) {
        $arcName = $arc.name
        $rgName = ($arc.id -split '/')[4]
        
        # Get Arc extensions
        $arcExtUri = "https://management.azure.com$($arc.id)/extensions"
        $arcExtensions = Invoke-AzureAPI -Uri $arcExtUri -ApiVersion "2023-03-15-preview"
        
        $hasAMA = $false
        $hasLegacyMMA = $false
        $hasDependencyAgent = $false
        $extensions = @()
        
        if ($arcExtensions -and $arcExtensions.value) {
            foreach ($ext in $arcExtensions.value) {
                $extensions += @{
                    Name = $ext.name
                    Type = $ext.properties.type
                    Publisher = $ext.properties.publisher
                    Version = $ext.properties.typeHandlerVersion
                    Status = $ext.properties.provisioningState
                }
                
                if ($ext.properties.type -match "AzureMonitor") { $hasAMA = $true }
                if ($ext.properties.type -match "MicrosoftMonitoringAgent|OmsAgent") { $hasLegacyMMA = $true }
                if ($ext.properties.type -match "DependencyAgent") { $hasDependencyAgent = $true }
            }
        }
        
        $monitoringData.ArcServers += @{
            Name = $arcName
            ResourceGroup = $rgName
            Location = $arc.location
            ResourceId = $arc.id
            Type = "Arc Server"
            OsType = $arc.properties.osName
            Status = $arc.properties.status
            AgentVersion = $arc.properties.agentVersion
            HasAMA = $hasAMA
            HasLegacyMMA = $hasLegacyMMA
            HasDependencyAgent = $hasDependencyAgent
            Extensions = $extensions
            PrincipalId = $arc.identity.principalId
            Tags = $arc.tags
        }
    }
    
    Write-ColorOutput "✓ Analizzati $($monitoringData.ArcServers.Count) Arc Servers" "Green"
} else {
    Write-ColorOutput "⊗ Nessun Arc Server trovato" "DarkGray"
}

# ═══════════════════════════════════════════════════════════════
# [4/15] LOG ANALYTICS WORKSPACES
# ═══════════════════════════════════════════════════════════════
Write-ColorOutput "`n[4/15] Raccolta Log Analytics Workspaces..." "Yellow"
$workspaces = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.OperationalInsights/workspaces" -ApiVersion "2022-10-01"

if ($workspaces -and $workspaces.value) {
    foreach ($ws in $workspaces.value) {
        $wsName = $ws.name
        $rgName = ($ws.id -split '/')[4]
        
        # Get workspace solutions (intelligence packs)
        $solutionsUri = "https://management.azure.com$($ws.id)/intelligencePacks"
        $solutions = Invoke-AzureAPI -Uri $solutionsUri -ApiVersion "2020-08-01"
        
        $hasVMInsights = $false
        $hasSecurityInsights = $false
        $hasUpdateManagement = $false
        $installedSolutions = @()
        
        if ($solutions -and $solutions.value) {
            foreach ($sol in $solutions.value) {
                if ($sol.properties.enabled) {
                    $installedSolutions += $sol.name
                    if ($sol.name -eq "VMInsights") { $hasVMInsights = $true }
                    if ($sol.name -match "Security") { $hasSecurityInsights = $true }
                    if ($sol.name -eq "Updates") { $hasUpdateManagement = $true }
                }
            }
        }
        
        $monitoringData.LogAnalyticsWorkspaces += @{
            Name = $wsName
            ResourceGroup = $rgName
            Location = $ws.location
            ResourceId = $ws.id
            Sku = $ws.properties.sku.name
            RetentionInDays = $ws.properties.retentionInDays
            DailyCappedGb = $ws.properties.workspaceCapping.dailyQuotaGb
            CustomerId = $ws.properties.customerId
            HasVMInsights = $hasVMInsights
            HasSecurityInsights = $hasSecurityInsights
            HasUpdateManagement = $hasUpdateManagement
            Solutions = $installedSolutions
        }
    }
    
    Write-ColorOutput "✓ Trovati $($monitoringData.LogAnalyticsWorkspaces.Count) Workspaces" "Green"
}

# ═══════════════════════════════════════════════════════════════
# [5/15] DATA COLLECTION RULES
# ═══════════════════════════════════════════════════════════════
Write-ColorOutput "`n[5/15] Raccolta Data Collection Rules..." "Yellow"
$dcrs = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Insights/dataCollectionRules" -ApiVersion "2022-06-01"

if ($dcrs -and $dcrs.value) {
    foreach ($dcr in $dcrs.value) {
        $dcrType = "Unknown"
        $dataFlows = @()
        
        if ($dcr.properties.dataFlows) {
            foreach ($flow in $dcr.properties.dataFlows) {
                $dataFlows += @{
                    Streams = $flow.streams
                    Destinations = $flow.destinations
                }
                
                if ($flow.streams -contains "Microsoft-InsightsMetrics") { $dcrType = "VM Insights" }
                if ($flow.streams -contains "Microsoft-Event") { $dcrType = "Windows Events" }
                if ($flow.streams -contains "Microsoft-Syslog") { $dcrType = "Linux Syslog" }
                if ($flow.streams -contains "Microsoft-Perf") { $dcrType = "Performance" }
            }
        }
        
        $monitoringData.DataCollectionRules += @{
            Name = $dcr.name
            ResourceGroup = ($dcr.id -split '/')[4]
            Location = $dcr.location
            ResourceId = $dcr.id
            Type = $dcrType
            DataFlows = $dataFlows
            Description = $dcr.properties.description
        }
    }
    
    Write-ColorOutput "✓ Trovati $($monitoringData.DataCollectionRules.Count) DCR" "Green"
}

# ═══════════════════════════════════════════════════════════════
# [6/15] DCR ASSOCIATIONS
# ═══════════════════════════════════════════════════════════════
Write-ColorOutput "`n[6/15] Raccolta DCR Associations..." "Yellow"
if (-not $SkipDCRAssociations) {
    $allMachines = $monitoringData.AzureVMs + $monitoringData.ArcServers
    
    foreach ($machine in $allMachines) {
        $assocUri = "https://management.azure.com$($machine.ResourceId)/providers/Microsoft.Insights/dataCollectionRuleAssociations"
        $assocs = Invoke-AzureAPI -Uri $assocUri -ApiVersion "2022-06-01"
        
        if ($assocs -and $assocs.value) {
            foreach ($assoc in $assocs.value) {
                $monitoringData.DCRAssociations += @{
                    MachineName = $machine.Name
                    MachineType = $machine.Type
                    AssociationName = $assoc.name
                    DataCollectionRuleId = $assoc.properties.dataCollectionRuleId
                }
            }
        }
    }
    
    Write-ColorOutput "✓ Trovate $($monitoringData.DCRAssociations.Count) associazioni" "Green"
} else {
    Write-ColorOutput "⊗ Saltato" "DarkGray"
}

# ═══════════════════════════════════════════════════════════════
# [7/15] AZURE POLICY
# ═══════════════════════════════════════════════════════════════
Write-ColorOutput "`n[7/15] Raccolta Azure Policy..." "Yellow"
$policyAssignments = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/policyAssignments" -ApiVersion "2021-06-01"

if ($policyAssignments -and $policyAssignments.value) {
    $monitoringPolicyCount = 0
    
    foreach ($policy in $policyAssignments.value) {
        $isMonitoringPolicy = $false
        $policyCategory = "Other"
        
        if ($policy.properties.displayName -match "Monitor|Azure Monitor|Log Analytics|Diagnostic|Insights|Agent|Defender|Audit") {
            $isMonitoringPolicy = $true
        }
        
        if ($policy.properties.displayName -match "Azure Monitor Agent") { $policyCategory = "Azure Monitor Agent" }
        elseif ($policy.properties.displayName -match "Diagnostic") { $policyCategory = "Diagnostic Settings" }
        elseif ($policy.properties.displayName -match "Insights") { $policyCategory = "VM Insights" }
        elseif ($policy.properties.displayName -match "Defender") { $policyCategory = "Microsoft Defender" }
        
        if ($isMonitoringPolicy) {
            $monitoringPolicyCount++
            
            $monitoringData.PolicyAssignments += @{
                Name = $policy.name
                DisplayName = $policy.properties.displayName
                Category = $policyCategory
                EnforcementMode = $policy.properties.enforcementMode
            }
            
            Write-ColorOutput "    ✓ [$policyCategory] $($policy.properties.displayName)" "DarkGray"
        }
    }
    
    Write-ColorOutput "✓ Trovate $monitoringPolicyCount Policy Monitoring" "Green"
}

# ═══════════════════════════════════════════════════════════════
# [8/15] MANAGED IDENTITIES
# ═══════════════════════════════════════════════════════════════
Write-ColorOutput "`n[8/15] Raccolta Managed Identities..." "Yellow"
$allMachines = $monitoringData.AzureVMs + $monitoringData.ArcServers

foreach ($machine in $allMachines) {
    if ($machine.PrincipalId) {
        # Get role assignments for this identity
        $roleUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleAssignments"
        $roleAssignments = Invoke-AzureAPI -Uri "${roleUri}?`$filter=principalId eq '$($machine.PrincipalId)'" -ApiVersion "2022-04-01"
        
        $roles = @()
        $hasMonitoringRole = $false
        
        if ($roleAssignments -and $roleAssignments.value) {
            foreach ($role in $roleAssignments.value) {
                # Get role definition
                $roleDef = Invoke-AzureAPI -Uri "https://management.azure.com$($role.properties.roleDefinitionId)" -ApiVersion "2022-04-01"
                
                $roleName = if ($roleDef) { $roleDef.properties.roleName } else { "Unknown" }
                
                $roles += @{
                    RoleDefinitionName = $roleName
                    Scope = $role.properties.scope
                }
                
                if ($roleName -match "Monitoring|Log Analytics") {
                    $hasMonitoringRole = $true
                }
            }
        }
        
        $monitoringData.ManagedIdentities += @{
            MachineName = $machine.Name
            MachineType = $machine.Type
            PrincipalId = $machine.PrincipalId
            IdentityType = $machine.IdentityType
            RoleAssignments = $roles
            HasMonitoringRole = $hasMonitoringRole
        }
    }
}

Write-ColorOutput "✓ Trovate $($monitoringData.ManagedIdentities.Count) Managed Identities" "Green"

# ═══════════════════════════════════════════════════════════════
# [9/15] ACTION GROUPS
# ═══════════════════════════════════════════════════════════════
Write-ColorOutput "`n[9/15] Raccolta Action Groups..." "Yellow"
$actionGroups = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Insights/actionGroups" -ApiVersion "2023-01-01"

if ($actionGroups -and $actionGroups.value) {
    foreach ($ag in $actionGroups.value) {
        $receivers = @{
            Email = if ($ag.properties.emailReceivers) { $ag.properties.emailReceivers.Count } else { 0 }
            Sms = if ($ag.properties.smsReceivers) { $ag.properties.smsReceivers.Count } else { 0 }
            Webhook = if ($ag.properties.webhookReceivers) { $ag.properties.webhookReceivers.Count } else { 0 }
        }
        
        $monitoringData.ActionGroups += @{
            Name = $ag.name
            ResourceGroup = ($ag.id -split '/')[4]
            Enabled = $ag.properties.enabled
            Receivers = $receivers
        }
    }
    
    Write-ColorOutput "✓ Trovati $($monitoringData.ActionGroups.Count) Action Groups" "Green"
}

# ═══════════════════════════════════════════════════════════════
# [10/15] METRIC ALERTS
# ═══════════════════════════════════════════════════════════════
Write-ColorOutput "`n[10/15] Raccolta Metric Alerts..." "Yellow"
$metricAlerts = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Insights/metricAlerts" -ApiVersion "2018-03-01"

if ($metricAlerts -and $metricAlerts.value) {
    foreach ($alert in $metricAlerts.value) {
        $monitoringData.MetricAlerts += @{
            Name = $alert.name
            ResourceGroup = ($alert.id -split '/')[4]
            Severity = $alert.properties.severity
            Enabled = $alert.properties.enabled
        }
    }
}
Write-ColorOutput "✓ Trovati $($monitoringData.MetricAlerts.Count) Metric Alerts" "Green"

# ═══════════════════════════════════════════════════════════════
# [11/15] LOG ALERTS
# ═══════════════════════════════════════════════════════════════
Write-ColorOutput "`n[11/15] Raccolta Log Alerts..." "Yellow"
$logAlerts = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Insights/scheduledQueryRules" -ApiVersion "2023-03-15-preview"

if ($logAlerts -and $logAlerts.value) {
    foreach ($alert in $logAlerts.value) {
        $monitoringData.LogAlerts += @{
            Name = $alert.name
            ResourceGroup = ($alert.id -split '/')[4]
            Enabled = $alert.properties.enabled
        }
    }
}
Write-ColorOutput "✓ Trovati $($monitoringData.LogAlerts.Count) Log Alerts" "Green"

# ═══════════════════════════════════════════════════════════════
# [12/15] APPLICATION INSIGHTS
# ═══════════════════════════════════════════════════════════════
Write-ColorOutput "`n[12/15] Raccolta Application Insights..." "Yellow"
$appInsights = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Insights/components" -ApiVersion "2020-02-02"

if ($appInsights -and $appInsights.value) {
    foreach ($ai in $appInsights.value) {
        $monitoringData.ApplicationInsights += @{
            Name = $ai.name
            ResourceGroup = ($ai.id -split '/')[4]
            Location = $ai.location
        }
    }
}
Write-ColorOutput "✓ Trovati $($monitoringData.ApplicationInsights.Count) App Insights" "Green"

# ═══════════════════════════════════════════════════════════════
# [13/15] WORKBOOKS
# ═══════════════════════════════════════════════════════════════
Write-ColorOutput "`n[13/15] Raccolta Workbooks..." "Yellow"
$workbooks = Invoke-AzureAPI -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Insights/workbooks" -ApiVersion "2022-04-01"

if ($workbooks -and $workbooks.value) {
    foreach ($wb in $workbooks.value) {
        $monitoringData.Workbooks += @{
            Name = $wb.name
        }
    }
}
Write-ColorOutput "✓ Trovati $($monitoringData.Workbooks.Count) Workbooks" "Green"

# ═══════════════════════════════════════════════════════════════
# [14/15] DIAGNOSTIC SETTINGS (SAMPLE)
# ═══════════════════════════════════════════════════════════════
Write-ColorOutput "`n[14/15] Diagnostic Settings (sample)..." "Yellow"
Write-ColorOutput "⊗ Saltato per performance" "DarkGray"

# ═══════════════════════════════════════════════════════════════
# [15/15] SUMMARY
# ═══════════════════════════════════════════════════════════════
Write-ColorOutput "`n[15/15] Generazione Summary..." "Yellow"

$totalMachines = $monitoringData.AzureVMs.Count + $monitoringData.ArcServers.Count
$machinesWithAMA = ($monitoringData.AzureVMs + $monitoringData.ArcServers | Where-Object { $_.HasAMA }).Count
$machinesWithLegacy = ($monitoringData.AzureVMs + $monitoringData.ArcServers | Where-Object { $_.HasLegacyMMA }).Count
$machinesWithInsights = ($monitoringData.AzureVMs + $monitoringData.ArcServers | Where-Object { $_.HasAMA -and $_.HasDependencyAgent }).Count

$monitoringData.Summary = @{
    TotalMachines = $totalMachines
    AzureVMs = $monitoringData.AzureVMs.Count
    ArcServers = $monitoringData.ArcServers.Count
    MachinesWithAMA = $machinesWithAMA
    MachinesWithLegacyMMA = $machinesWithLegacy
    MachinesWithVMInsights = $machinesWithInsights
    UnmonitoredMachines = $totalMachines - $machinesWithAMA - $machinesWithLegacy
    AMA_Coverage_Percent = if ($totalMachines -gt 0) { [math]::Round(($machinesWithAMA / $totalMachines) * 100, 2) } else { 0 }
    Insights_Coverage_Percent = if ($totalMachines -gt 0) { [math]::Round(($machinesWithInsights / $totalMachines) * 100, 2) } else { 0 }
    TotalDCRs = $monitoringData.DataCollectionRules.Count
    TotalDCRAssociations = $monitoringData.DCRAssociations.Count
    TotalWorkspaces = $monitoringData.LogAnalyticsWorkspaces.Count
    WorkspacesWithVMInsights = ($monitoringData.LogAnalyticsWorkspaces | Where-Object { $_.HasVMInsights }).Count
    TotalMonitoringPolicies = $monitoringData.PolicyAssignments.Count
    TotalManagedIdentities = $monitoringData.ManagedIdentities.Count
    TotalActionGroups = $monitoringData.ActionGroups.Count
    TotalMetricAlerts = $monitoringData.MetricAlerts.Count
    TotalLogAlerts = $monitoringData.LogAlerts.Count
    TotalAppInsights = $monitoringData.ApplicationInsights.Count
    TotalWorkbooks = $monitoringData.Workbooks.Count
}

Write-ColorOutput "✓ Summary completato" "Green"

Write-ColorOutput "`n╔══════════════════════════════════════════════════════════════════════╗" "Cyan"
Write-ColorOutput "║                      QUICK SUMMARY                                   ║" "Cyan"
Write-ColorOutput "╚══════════════════════════════════════════════════════════════════════╝" "Cyan"
Write-ColorOutput "  Macchine: $totalMachines | AMA: $machinesWithAMA ($($monitoringData.Summary.AMA_Coverage_Percent)%)" "White"
Write-ColorOutput "  DCR: $($monitoringData.DataCollectionRules.Count) | Workspaces: $($monitoringData.LogAnalyticsWorkspaces.Count)" "White"
Write-ColorOutput "  Policy: $($monitoringData.PolicyAssignments.Count) | Alerts: $($monitoringData.MetricAlerts.Count + $monitoringData.LogAlerts.Count)" "White"

Write-ColorOutput "`n╔══════════════════════════════════════════════════════════════════════╗" "Green"
Write-ColorOutput "║              RACCOLTA DATI COMPLETATA                                ║" "Green"
Write-ColorOutput "╚══════════════════════════════════════════════════════════════════════╝" "Green"

# ============================================================================
# AI ANALYSIS
# ============================================================================

Write-ColorOutput "`n╔══════════════════════════════════════════════════════════════════════╗" "Cyan"
Write-ColorOutput "║                    ANALISI AI IN CORSO                               ║" "Cyan"
Write-ColorOutput "╚══════════════════════════════════════════════════════════════════════╝" "Cyan"

$dataJson = $monitoringData | ConvertTo-Json -Depth 8 -Compress
Write-ColorOutput "  Dimensione dati: $([math]::Round($dataJson.Length / 1KB, 2)) KB" "DarkGray"

$prompt = @"
Analizza questi dati Azure Monitor e genera un report DETTAGLIATO in ITALIANO in formato HTML.

DATI:
$dataJson

GENERA SEZIONI HTML CON:
1. EXECUTIVE SUMMARY (punteggio maturità, coverage %, criticità TOP 3)
2. ANALISI VM & ARC (distribuzione agenti, VM non monitorate, identity)
3. DATA COLLECTION RULES (tipi DCR, associazioni, configurazione)
4. LOG ANALYTICS WORKSPACES (soluzioni attive, retention, quota)
5. AZURE POLICY (compliance, policy mancanti)
6. ALERTING (metric/log alerts, action groups, gaps)
7. RACCOMANDAZIONI PRIORITARIE (TOP 10 azioni, quick wins, migration MMA→AMA)

Usa HTML con <div class="section">, <h2>, <ul>, <table> per strutturare.
Usa emoji per rendere visivo.
Sii tecnico ma chiaro.
"@

$headers = @{
    "Content-Type" = "application/json"
    "api-key" = $apiKey
}

$requestBody = @{
    messages = @(
        @{
            role = "system"
            content = "Sei un Azure Solutions Architect esperto. Rispondi in italiano con report HTML dettagliati."
        }
        @{
            role = "user"
            content = $prompt
        }
    )
    max_completion_tokens = 4000
} | ConvertTo-Json -Depth 5

$aiReport = "<div class='section'><h2>Analisi AI non disponibile</h2><p>Configura AZURE_OPENAI_ENDPOINT / AZURE_OPENAI_DEPLOYMENT / AZURE_OPENAI_API_KEY.</p></div>"
if ($apiKey -and $endpoint) {
    try {
        Write-ColorOutput "  Invio richiesta AI..." "Yellow"
        $response = Invoke-RestMethod -Uri $endpoint -Method POST -Headers $headers -Body $requestBody -ContentType "application/json" -TimeoutSec 180

        if ($response.choices -and $response.choices[0].message.content) {
            $aiReport = $response.choices[0].message.content
            Write-ColorOutput "✓ Report AI generato!" "Green"
            Write-ColorOutput "  Token: $($response.usage.total_tokens)" "DarkGray"
        } else {
            throw "Risposta AI non valida"
        }
    } catch {
        Write-ColorOutput "⚠ ERRORE AI: $($_.Exception.Message)" "Red"
        $aiReport = "<div class='section'><h2>Analisi AI non disponibile</h2><p>$($_.Exception.Message)</p></div>"
    }
}

# ============================================================================
# EXPORT HTML
# ============================================================================

Write-ColorOutput "`n╔══════════════════════════════════════════════════════════════════════╗" "Cyan"
Write-ColorOutput "║                  ESPORTAZIONE REPORT HTML                            ║" "Cyan"
Write-ColorOutput "╚══════════════════════════════════════════════════════════════════════╝" "Cyan"

$maturityScore = 5  # Calcola score basato sui dati
if ($monitoringData.Summary.AMA_Coverage_Percent -gt 80) { $maturityScore += 3 }
if ($monitoringData.Summary.TotalDCRs -gt 0) { $maturityScore += 1 }
if ($monitoringData.Summary.TotalActionGroups -gt 0) { $maturityScore += 1 }

$htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Azure Monitor Report - $($monitoringData.Subscription.Name)</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; background: #f5f5f5; margin: 0; padding: 20px; }
        .container { max-width: 1200px; margin: 0 auto; background: white; border-radius: 10px; padding: 40px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #0078d4; border-bottom: 3px solid #0078d4; padding-bottom: 10px; }
        h2 { color: #0078d4; margin-top: 30px; }
        .section { margin: 20px 0; padding: 20px; background: #f8f9fa; border-left: 4px solid #0078d4; }
        table { width: 100%; border-collapse: collapse; margin: 15px 0; }
        th { background: #0078d4; color: white; padding: 12px; text-align: left; }
        td { padding: 10px; border-bottom: 1px solid #ddd; }
        .badge-success { background: #28a745; color: white; padding: 5px 10px; border-radius: 5px; }
        .badge-warning { background: #ffc107; color: black; padding: 5px 10px; border-radius: 5px; }
        .badge-danger { background: #dc3545; color: white; padding: 5px 10px; border-radius: 5px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔍 Azure Monitor Analysis Report</h1>
        <p><strong>Subscription:</strong> $($monitoringData.Subscription.Name)</p>
        <p><strong>Date:</strong> $($monitoringData.Timestamp)</p>
        <p><strong>Maturity Score:</strong> $maturityScore/10</p>
        
        $aiReport
        
        <div class="section">
            <h2>📊 Summary</h2>
            <table>
                <tr><th>Metric</th><th>Value</th></tr>
                <tr><td>Total Machines</td><td>$($monitoringData.Summary.TotalMachines)</td></tr>
                <tr><td>AMA Coverage</td><td>$($monitoringData.Summary.AMA_Coverage_Percent)%</td></tr>
                <tr><td>Workspaces</td><td>$($monitoringData.Summary.TotalWorkspaces)</td></tr>
                <tr><td>DCRs</td><td>$($monitoringData.Summary.TotalDCRs)</td></tr>
                <tr><td>Policies</td><td>$($monitoringData.Summary.TotalMonitoringPolicies)</td></tr>
                <tr><td>Alerts</td><td>$($monitoringData.Summary.TotalMetricAlerts + $monitoringData.Summary.TotalLogAlerts)</td></tr>
            </table>
        </div>
        
        <div class="section">
            <h2>🖥️ Virtual Machines</h2>
            <table>
                <tr><th>Name</th><th>OS</th><th>AMA</th><th>Extensions</th></tr>
$( foreach ($vm in $monitoringData.AzureVMs) {
    $amaBadge = if ($vm.HasAMA) { "<span class='badge-success'>✓ AMA</span>" } else { "<span class='badge-danger'>✗ No AMA</span>" }
    "                <tr><td>$($vm.Name)</td><td>$($vm.OsType)</td><td>$amaBadge</td><td>$($vm.ExtensionCount)</td></tr>`n"
})
            </table>
        </div>
    </div>
</body>
</html>
"@

$htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
Write-ColorOutput "✓ Report HTML salvato: $OutputPath" "Green"

# ✅ AGGIUNGI L'HTML AL JSON per permettere il download dal browser
$monitoringData['ReportHTML'] = $htmlContent

# Save JSON
$jsonPath = $OutputPath -replace "\.html$", ".json"
$monitoringData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force
Write-ColorOutput "✓ JSON salvato: $jsonPath" "Green"

# Save CSV (VMs)
$csvPath = $OutputPath -replace "\.html$", "_VMs.csv"
$allMachines = $monitoringData.AzureVMs + $monitoringData.ArcServers
if ($allMachines.Count -gt 0) {
    $allMachines | Select-Object Name, Type, OsType, HasAMA, HasLegacyMMA, ExtensionCount | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-ColorOutput "✓ CSV salvato: $csvPath" "Green"
}

$duration = (Get-Date) - $startTime

Write-ColorOutput "`n╔════════════════════════════════════════════════════════════════════╗" "Green"
Write-ColorOutput "║                   ✓ COMPLETATO!                                    ║" "Green"
Write-ColorOutput "╚════════════════════════════════════════════════════════════════════╝" "Green"
Write-ColorOutput "`nTempo: $($duration.Minutes)m $($duration.Seconds)s" "White"

Write-ColorOutput "`n📄 Files generati:" "Cyan"
Write-ColorOutput "  ├─ 🌐 Report HTML: $OutputPath" "White"
Write-ColorOutput "  ├─ 📊 JSON Data:   $jsonPath" "White"
Write-ColorOutput "  └─ 📈 VM CSV:      $csvPath" "White"
