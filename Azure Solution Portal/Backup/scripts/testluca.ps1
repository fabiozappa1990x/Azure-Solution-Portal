<#
.SYNOPSIS
Azure Monitor Deep Analysis - Versione FINALE con Report HTML Professionale
.NOTES
Versione: 3.0 FINAL - Production Ready
Author: AI Assistant + Luca Soriano
Date: 2025
Features:
- VM Extension detection con Get-AzVMExtension
- Azure Policy con Get-AzPolicyStateSummary
- Report HTML visivo e professionale
- Export JSON e CSV
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\AzureMonitorReport.html",
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipDCRAssociations
)

# Configurazione AI
$apiKey = "1pN5y5zgK2iSmWhNNFrA0UpNX5krFMI10mz8A6XWFb9gXLs0Kvw2JQQJ99BJACYeBjFXJ3w3AAAAACOGR3VY"
$endpoint = "https://openaitestluca.cognitiveservices.azure.com/openai/deployments/AVM/chat/completions?api-version=2025-01-01-preview"

# ============================================================================
# FUNZIONI HELPER
# ============================================================================

function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

function Fix-AzureModules {
    Write-ColorOutput "`n=== CARICAMENTO MODULI AZURE ===" "Cyan"
    
    try {
        Write-ColorOutput "Verifica moduli necessari..." "Yellow"
        
        $modulesToImport = @(
            'Az.Accounts',
            'Az.Resources',
            'Az.Monitor',
            'Az.OperationalInsights',
            'Az.Compute',
            'Az.ConnectedMachine',
            'Az.PolicyInsights'
        )
        
        foreach ($mod in $modulesToImport) {
            try {
                $loadedModule = Get-Module -Name $mod
                
                if (-not $loadedModule) {
                    Write-ColorOutput "  Importazione $mod..." "DarkGray"
                    Import-Module $mod -Force -ErrorAction Stop -WarningAction SilentlyContinue
                    Write-ColorOutput "    ✓ $mod caricato" "Green"
                } else {
                    Write-ColorOutput "  ✓ $mod già presente (v$($loadedModule.Version))" "Green"
                }
            } catch {
                $installed = Get-Module -Name $mod -ListAvailable
                if ($installed) {
                    Write-ColorOutput "    ⚠ $mod installato ma non caricabile" "Yellow"
                } else {
                    Write-ColorOutput "    ℹ $mod non installato (opzionale)" "DarkGray"
                }
            }
        }
        
        Write-ColorOutput "✓ Verifica moduli completata" "Green"
        
    } catch {
        Write-ColorOutput "⚠ Errore nella gestione moduli: $($_.Exception.Message)" "Yellow"
    }
}

# ============================================================================
# RACCOLTA DATI AVANZATA
# ============================================================================

function Get-AzureMonitorDataAdvanced {
    Write-ColorOutput "`n╔══════════════════════════════════════════════════════════════════════╗" "Cyan"
    Write-ColorOutput "║          INIZIO RACCOLTA DATI AZURE MONITOR - DEEP ANALYSIS         ║" "Cyan"
    Write-ColorOutput "╚══════════════════════════════════════════════════════════════════════╝" "Cyan"
    
    $monitoringData = @{
        Timestamp                = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Subscription             = @{}
        
        # VM & Arc
        AzureVMs                 = @()
        ArcServers               = @()
        
        # Insights & Extensions
        VMInsights               = @()
        Extensions               = @()
        
        # Data Collection
        DataCollectionRules      = @()
        DCRAssociations          = @()
        DCRDetails               = @()
        
        # Workspaces
        LogAnalyticsWorkspaces   = @()
        WorkspaceAgents          = @()
        
        # Policy
        PolicySummary            = @{}
        PolicyAssignments        = @()
        PolicySetDefinitions     = @()
        PolicyCompliance         = @()
        
        # Identity
        ManagedIdentities        = @()
        IdentityRoleAssignments  = @()
        
        # Alerting
        ActionGroups             = @()
        MetricAlerts             = @()
        LogAlerts                = @()
        ActivityLogAlerts        = @()
        
        # Other
        ApplicationInsights      = @()
        Workbooks                = @()
        DiagnosticSettings       = @()
        
        # Summary
        Summary                  = @{}
    }
    
    try {
        # ═══════════════════════════════════════════════════════════════
        # CONNESSIONE
        # ═══════════════════════════════════════════════════════════════
        Write-ColorOutput "`n[1/15] Verifica connessione Azure..." "Yellow"
        $context = Get-AzContext
        if (-not $context) {
            Write-ColorOutput "Non connesso. Eseguo Connect-AzAccount..." "Red"
            Connect-AzAccount
            $context = Get-AzContext
        }
        
        if ($SubscriptionId) {
            Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
            $context = Get-AzContext
        }
        
        $monitoringData.Subscription = @{
            Name     = $context.Subscription.Name
            Id       = $context.Subscription.Id
            TenantId = $context.Tenant.Id
        }
        
        Write-ColorOutput "✓ Connesso: $($context.Subscription.Name)" "Green"
        
        # ═══════════════════════════════════════════════════════════════
        # VM AZURE - CON Get-AzVMExtension CORRETTO
        # ═══════════════════════════════════════════════════════════════
        Write-ColorOutput "`n[2/15] Raccolta Virtual Machines Azure..." "Yellow"
        try {
            $azureVMs = Get-AzVM -ErrorAction Stop
            Write-ColorOutput "  ✓ Trovate $($azureVMs.Count) VM" "Green"
            
            $counter = 0
            foreach ($vm in $azureVMs) {
                $counter++
                Write-ColorOutput "  [$counter/$($azureVMs.Count)] Analisi $($vm.Name)..." "DarkGray"
                
                try {
                    $hasAMA = $false
                    $hasLegacyMMA = $false
                    $hasDependencyAgent = $false
                    $extensions = @()
                    $powerState = "Unknown"
                    
                    # Recupera power state
                    try {
                        $vmStatus = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status -ErrorAction SilentlyContinue
                        
                        if ($vmStatus.Statuses) {
                            $ps = $vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" } | Select-Object -First 1
                            if ($ps) { $powerState = $ps.DisplayStatus }
                        }
                    } catch { }
                    
                    # ✅ RECUPERA ESTENSIONI CON Get-AzVMExtension
                    try {
                        $vmExtensions = Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -ErrorAction SilentlyContinue
                        
                        if ($vmExtensions) {
                            Write-ColorOutput "    ✓ Trovate $($vmExtensions.Count) estensioni" "DarkGray"
                            
                            foreach ($ext in $vmExtensions) {
                                $extensions += @{
                                    Name      = $ext.Name
                                    Type      = $ext.ExtensionType
                                    Publisher = $ext.Publisher
                                    Version   = $ext.TypeHandlerVersion
                                    Status    = $ext.ProvisioningState
                                }
                                
                                if ($ext.ExtensionType -eq "AzureMonitorWindowsAgent" -or $ext.ExtensionType -eq "AzureMonitorLinuxAgent") {
                                    $hasAMA = $true
                                    Write-ColorOutput "      → AMA trovato!" "Green"
                                }
                                if ($ext.ExtensionType -eq "MicrosoftMonitoringAgent" -or $ext.ExtensionType -eq "OmsAgentForLinux") {
                                    $hasLegacyMMA = $true
                                    Write-ColorOutput "      → Legacy MMA trovato!" "Yellow"
                                }
                                if ($ext.ExtensionType -eq "DependencyAgentWindows" -or $ext.ExtensionType -eq "DependencyAgentLinux") {
                                    $hasDependencyAgent = $true
                                    Write-ColorOutput "      → Dependency Agent trovato!" "Green"
                                }
                            }
                        }
                    } catch {
                        Write-ColorOutput "    ⚠ Errore estensioni: $($_.Exception.Message)" "DarkYellow"
                    }
                    
                    # Identity
                    $identityType = "None"
                    $principalId = $null
                    if ($vm.Identity) {
                        $identityType = $vm.Identity.Type
                        $principalId = $vm.Identity.PrincipalId
                    }
                    
                    $monitoringData.AzureVMs += @{
                        Name                  = $vm.Name
                        ResourceGroup         = $vm.ResourceGroupName
                        Location              = $vm.Location
                        ResourceId            = $vm.Id
                        Type                  = "Azure VM"
                        OsType                = $vm.StorageProfile.OsDisk.OsType
                        VmSize                = $vm.HardwareProfile.VmSize
                        PowerState            = $powerState
                        HasAMA                = $hasAMA
                        HasLegacyMMA          = $hasLegacyMMA
                        HasDependencyAgent    = $hasDependencyAgent
                        Extensions            = $extensions
                        ExtensionCount        = $extensions.Count
                        IdentityType          = $identityType
                        PrincipalId           = $principalId
                        Tags                  = $vm.Tags
                    }
                    
                } catch {
                    Write-ColorOutput "    ⚠ Errore VM: $($_.Exception.Message)" "DarkYellow"
                }
            }
            
            $totalExt = ($monitoringData.AzureVMs | Measure-Object -Property ExtensionCount -Sum).Sum
            $vmsWithAMA = ($monitoringData.AzureVMs | Where-Object { $_.HasAMA }).Count
            Write-ColorOutput "✓ Analizzate $($monitoringData.AzureVMs.Count) VM Azure" "Green"
            Write-ColorOutput "  → Totale estensioni: $totalExt | VM con AMA: $vmsWithAMA" "Cyan"
            
        } catch {
            Write-ColorOutput "⚠ Errore VM: $($_.Exception.Message)" "Yellow"
        }
        
        # ═══════════════════════════════════════════════════════════════
        # ARC SERVERS
        # ═══════════════════════════════════════════════════════════════
        Write-ColorOutput "`n[3/15] Raccolta Arc-enabled Servers..." "Yellow"
        try {
            if (Get-Command Get-AzConnectedMachine -ErrorAction SilentlyContinue) {
                $arcServers = Get-AzConnectedMachine -ErrorAction SilentlyContinue
                
                if ($arcServers) {
                    Write-ColorOutput "  Trovati $($arcServers.Count) Arc Servers" "Green"
                    
                    foreach ($arc in $arcServers) {
                        try {
                            $arcExtensions = Get-AzConnectedMachineExtension -ResourceGroupName $arc.ResourceGroupName -MachineName $arc.Name -ErrorAction SilentlyContinue
                            
                            $hasAMA = $false
                            $hasLegacyMMA = $false
                            $hasDependencyAgent = $false
                            $extensions = @()
                            
                            if ($arcExtensions) {
                                foreach ($ext in $arcExtensions) {
                                    $extensions += @{
                                        Name      = $ext.Name
                                        Type      = $ext.MachineExtensionType
                                        Publisher = $ext.Publisher
                                        Version   = $ext.TypeHandlerVersion
                                        Status    = $ext.ProvisioningState
                                    }
                                    
                                    if ($ext.MachineExtensionType -match "AzureMonitor") { $hasAMA = $true }
                                    if ($ext.MachineExtensionType -match "MicrosoftMonitoringAgent|OmsAgent") { $hasLegacyMMA = $true }
                                    if ($ext.MachineExtensionType -match "DependencyAgent") { $hasDependencyAgent = $true }
                                }
                            }
                            
                            $monitoringData.ArcServers += @{
                                Name                  = $arc.Name
                                ResourceGroup         = $arc.ResourceGroupName
                                Location              = $arc.Location
                                ResourceId            = $arc.Id
                                Type                  = "Arc Server"
                                OsType                = $arc.OSName
                                Status                = $arc.Status
                                AgentVersion          = $arc.AgentVersion
                                HasAMA                = $hasAMA
                                HasLegacyMMA          = $hasLegacyMMA
                                HasDependencyAgent    = $hasDependencyAgent
                                Extensions            = $extensions
                                PrincipalId           = $arc.IdentityPrincipalId
                                Tags                  = $arc.Tags
                            }
                            
                        } catch { }
                    }
                }
                
                Write-ColorOutput "✓ Analizzati $($monitoringData.ArcServers.Count) Arc Servers" "Green"
            } else {
                Write-ColorOutput "⊗ Modulo Az.ConnectedMachine non disponibile" "DarkGray"
            }
            
        } catch {
            Write-ColorOutput "⚠ Errore Arc: $($_.Exception.Message)" "Yellow"
        }
        
        # ═══════════════════════════════════════════════════════════════
        # LOG ANALYTICS WORKSPACES
        # ═══════════════════════════════════════════════════════════════
        Write-ColorOutput "`n[4/15] Raccolta Log Analytics Workspaces..." "Yellow"
        try {
            $workspaces = Get-AzOperationalInsightsWorkspace -ErrorAction Stop
            
            foreach ($ws in $workspaces) {
                try {
                    $solutions = Get-AzOperationalInsightsIntelligencePack -ResourceGroupName $ws.ResourceGroupName -WorkspaceName $ws.Name -ErrorAction SilentlyContinue
                    
                    $hasVMInsights = $false
                    $hasSecurityInsights = $false
                    $hasUpdateManagement = $false
                    $installedSolutions = @()
                    
                    if ($solutions) {
                        foreach ($sol in $solutions) {
                            if ($sol.Enabled) {
                                $installedSolutions += $sol.Name
                                if ($sol.Name -eq "VMInsights") { $hasVMInsights = $true }
                                if ($sol.Name -match "Security") { $hasSecurityInsights = $true }
                                if ($sol.Name -eq "Updates") { $hasUpdateManagement = $true }
                            }
                        }
                    }
                    
                    $monitoringData.LogAnalyticsWorkspaces += @{
                        Name                  = $ws.Name
                        ResourceGroup         = $ws.ResourceGroupName
                        Location              = $ws.Location
                        ResourceId            = $ws.ResourceId
                        Sku                   = $ws.Sku
                        RetentionInDays       = $ws.RetentionInDays
                        DailyCappedGb         = $ws.DailyQuotaGb
                        CustomerId            = $ws.CustomerId
                        HasVMInsights         = $hasVMInsights
                        HasSecurityInsights   = $hasSecurityInsights
                        HasUpdateManagement   = $hasUpdateManagement
                        Solutions             = $installedSolutions
                    }
                    
                } catch { }
            }
            
            Write-ColorOutput "✓ Trovati $($monitoringData.LogAnalyticsWorkspaces.Count) Workspaces" "Green"
            
        } catch {
            Write-ColorOutput "⚠ Errore Workspaces" "Yellow"
        }
        
        # ═══════════════════════════════════════════════════════════════
        # DATA COLLECTION RULES
        # ═══════════════════════════════════════════════════════════════
        Write-ColorOutput "`n[5/15] Raccolta Data Collection Rules..." "Yellow"
        try {
            $dcrs = Get-AzDataCollectionRule -ErrorAction Stop
            
            foreach ($dcr in $dcrs) {
                try {
                    $dcrDetail = Get-AzDataCollectionRule -ResourceGroupName $dcr.ResourceGroupName -Name $dcr.Name -ErrorAction SilentlyContinue
                    
                    $dataFlows = @()
                    $dcrType = "Unknown"
                    
                    if ($dcrDetail.DataFlow) {
                        foreach ($flow in $dcrDetail.DataFlow) {
                            $dataFlows += @{
                                Streams      = $flow.Streams
                                Destinations = $flow.Destinations
                            }
                            
                            if ($flow.Streams -contains "Microsoft-InsightsMetrics") { $dcrType = "VM Insights" }
                            if ($flow.Streams -contains "Microsoft-Event") { $dcrType = "Windows Events" }
                            if ($flow.Streams -contains "Microsoft-Syslog") { $dcrType = "Linux Syslog" }
                            if ($flow.Streams -contains "Microsoft-Perf") { $dcrType = "Performance" }
                        }
                    }
                    
                    $monitoringData.DataCollectionRules += @{
                        Name          = $dcr.Name
                        ResourceGroup = $dcr.ResourceGroupName
                        Location      = $dcr.Location
                        ResourceId    = $dcr.Id
                        Type          = $dcrType
                        DataFlows     = $dataFlows
                        Description   = $dcr.Description
                    }
                    
                } catch { }
            }
            
            Write-ColorOutput "✓ Trovati $($monitoringData.DataCollectionRules.Count) DCR" "Green"
            
        } catch {
            Write-ColorOutput "⚠ Nessun DCR trovato" "Yellow"
        }
        
        # ═══════════════════════════════════════════════════════════════
        # DCR ASSOCIATIONS
        # ═══════════════════════════════════════════════════════════════
        Write-ColorOutput "`n[6/15] Raccolta DCR Associations..." "Yellow"
        if (-not $SkipDCRAssociations) {
            try {
                $allMachines = $monitoringData.AzureVMs + $monitoringData.ArcServers
                
                foreach ($machine in $allMachines) {
                    try {
                        $assocs = Get-AzDataCollectionRuleAssociation -TargetResourceId $machine.ResourceId -ErrorAction SilentlyContinue
                        
                        if ($assocs) {
                            foreach ($assoc in $assocs) {
                                $monitoringData.DCRAssociations += @{
                                    MachineName           = $machine.Name
                                    MachineType           = $machine.Type
                                    AssociationName       = $assoc.Name
                                    DataCollectionRuleId  = $assoc.DataCollectionRuleId
                                }
                            }
                        }
                    } catch { }
                }
                
                Write-ColorOutput "✓ Trovate $($monitoringData.DCRAssociations.Count) associazioni" "Green"
                
            } catch {
                Write-ColorOutput "⚠ Errore associazioni" "Yellow"
            }
        } else {
            Write-ColorOutput "⊗ Saltato" "DarkGray"
        }
        
        # ═══════════════════════════════════════════════════════════════
        # AZURE POLICY - VERSIONE CORRETTA
        # ═══════════════════════════════════════════════════════════════
        Write-ColorOutput "`n[7/15] Raccolta Azure Policy..." "Yellow"
        try {
            # ✅ Policy Summary
            $policySummary = Get-AzPolicyStateSummary -ErrorAction SilentlyContinue
            
            if ($policySummary) {
                Write-ColorOutput "  ✓ Policy Summary trovato" "Green"
                Write-ColorOutput "    Non-Compliant Resources: $($policySummary.NonCompliantResources)" "DarkGray"
                
                $monitoringData.PolicySummary = @{
                    NonCompliantResources = $policySummary.NonCompliantResources
                    NonCompliantPolicies  = $policySummary.NonCompliantPolicies
                    TotalAssignments      = if ($policySummary.PolicyAssignments) { $policySummary.PolicyAssignments.Count } else { 0 }
                }
            }
            
            # ✅ Policy Assignments
            $allPolicyAssignments = Get-AzPolicyAssignment -ErrorAction SilentlyContinue
            
            if ($allPolicyAssignments) {
                $monitoringPolicyCount = 0
                
                foreach ($policy in $allPolicyAssignments) {
                    $isMonitoringPolicy = $false
                    $policyCategory = "Other"
                    
                    if ($policy.Name -match "ama|monitor|diagnostic|insights|defender|audit") {
                        $isMonitoringPolicy = $true
                    }
                    
                    if ($policy.Properties.DisplayName -match "Monitor|Azure Monitor|Log Analytics|Diagnostic|Insights|Agent|Defender|Audit") {
                        $isMonitoringPolicy = $true
                    }
                    
                    if ($policy.Name -match "ama") { $policyCategory = "Azure Monitor Agent" }
                    elseif ($policy.Name -match "diagnostic") { $policyCategory = "Diagnostic Settings" }
                    elseif ($policy.Name -match "insights") { $policyCategory = "VM Insights" }
                    elseif ($policy.Name -match "defender") { $policyCategory = "Microsoft Defender" }
                    
                    if ($isMonitoringPolicy) {
                        $monitoringPolicyCount++
                        
                        $complianceState = "Unknown"
                        $nonCompliantResources = 0
                        
                        try {
                            $policyStates = Get-AzPolicyState -PolicyAssignmentName $policy.Name -Top 50 -ErrorAction SilentlyContinue
                            
                            if ($policyStates) {
                                $nonCompliantResources = ($policyStates | Where-Object { $_.ComplianceState -eq "NonCompliant" }).Count
                                
                                if ($nonCompliantResources -eq 0) {
                                    $complianceState = "Compliant"
                                } else {
                                    $complianceState = "NonCompliant"
                                }
                            }
                        } catch { }
                        
                        $monitoringData.PolicyAssignments += @{
                            Name                  = $policy.Name
                            DisplayName           = $policy.Properties.DisplayName
                            Category              = $policyCategory
                            ComplianceState       = $complianceState
                            NonCompliantResources = $nonCompliantResources
                            EnforcementMode       = $policy.Properties.EnforcementMode
                        }
                        
                        Write-ColorOutput "    ✓ [$policyCategory] $($policy.Properties.DisplayName)" "DarkGray"
                    }
                }
                
                Write-ColorOutput "✓ Trovate $monitoringPolicyCount Policy Monitoring" "Green"
            }
            
        } catch {
            Write-ColorOutput "⚠ Errore Policy: $($_.Exception.Message)" "Yellow"
        }
        
        # ═══════════════════════════════════════════════════════════════
        # MANAGED IDENTITIES
        # ═══════════════════════════════════════════════════════════════
        Write-ColorOutput "`n[8/15] Raccolta Managed Identities..." "Yellow"
        try {
            $allMachines = $monitoringData.AzureVMs + $monitoringData.ArcServers
            
            foreach ($machine in $allMachines) {
                if ($machine.PrincipalId) {
                    try {
                        $roleAssignments = Get-AzRoleAssignment -ObjectId $machine.PrincipalId -ErrorAction SilentlyContinue
                        
                        $roles = @()
                        $hasMonitoringRole = $false
                        
                        if ($roleAssignments) {
                            foreach ($role in $roleAssignments) {
                                $roles += @{
                                    RoleDefinitionName = $role.RoleDefinitionName
                                    Scope              = $role.Scope
                                }
                                
                                if ($role.RoleDefinitionName -match "Monitoring|Log Analytics") {
                                    $hasMonitoringRole = $true
                                }
                            }
                        }
                        
                        $monitoringData.ManagedIdentities += @{
                            MachineName        = $machine.Name
                            MachineType        = $machine.Type
                            PrincipalId        = $machine.PrincipalId
                            IdentityType       = $machine.IdentityType
                            RoleAssignments    = $roles
                            HasMonitoringRole  = $hasMonitoringRole
                        }
                        
                    } catch { }
                }
            }
            
            Write-ColorOutput "✓ Trovate $($monitoringData.ManagedIdentities.Count) Managed Identities" "Green"
            
        } catch {
            Write-ColorOutput "⚠ Errore Identities" "Yellow"
        }
        
        # ═══════════════════════════════════════════════════════════════
        # ACTION GROUPS
        # ═══════════════════════════════════════════════════════════════
        Write-ColorOutput "`n[9/15] Raccolta Action Groups..." "Yellow"
        try {
            $actionGroups = Get-AzActionGroup -ErrorAction Stop
            
            foreach ($ag in $actionGroups) {
                $receivers = @{
                    Email     = if ($ag.EmailReceiver) { $ag.EmailReceiver.Count } else { 0 }
                    Sms       = if ($ag.SmsReceiver) { $ag.SmsReceiver.Count } else { 0 }
                    Webhook   = if ($ag.WebhookReceiver) { $ag.WebhookReceiver.Count } else { 0 }
                }
                
                $monitoringData.ActionGroups += @{
                    Name          = $ag.Name
                    ResourceGroup = $ag.ResourceGroupName
                    Enabled       = $ag.Enabled
                    Receivers     = $receivers
                }
            }
            
            Write-ColorOutput "✓ Trovati $($monitoringData.ActionGroups.Count) Action Groups" "Green"
            
        } catch {
            Write-ColorOutput "⚠ Nessun Action Group" "Yellow"
        }
        
        # ═══════════════════════════════════════════════════════════════
        # METRIC ALERTS
        # ═══════════════════════════════════════════════════════════════
        Write-ColorOutput "`n[10/15] Raccolta Metric Alerts..." "Yellow"
        try {
            $metricAlerts = Get-AzMetricAlertRuleV2 -ErrorAction SilentlyContinue
            
            foreach ($alert in $metricAlerts) {
                $monitoringData.MetricAlerts += @{
                    Name          = $alert.Name
                    ResourceGroup = $alert.ResourceGroupName
                    Severity      = $alert.Severity
                    Enabled       = $alert.Enabled
                }
            }
            
            Write-ColorOutput "✓ Trovati $($monitoringData.MetricAlerts.Count) Metric Alerts" "Green"
            
        } catch {
            Write-ColorOutput "⚠ Nessun Metric Alert" "Yellow"
        }
        
        # ═══════════════════════════════════════════════════════════════
        # LOG ALERTS
        # ═══════════════════════════════════════════════════════════════
        Write-ColorOutput "`n[11/15] Raccolta Log Alerts..." "Yellow"
        try {
            $logAlerts = Get-AzScheduledQueryRule -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            
            foreach ($alert in $logAlerts) {
                $monitoringData.LogAlerts += @{
                    Name          = $alert.Name
                    ResourceGroup = $alert.ResourceGroupName
                    Enabled       = $alert.Enabled
                }
            }
            
            Write-ColorOutput "✓ Trovati $($monitoringData.LogAlerts.Count) Log Alerts" "Green"
            
        } catch {
            Write-ColorOutput "⚠ Nessun Log Alert" "Yellow"
        }
        
        # ═══════════════════════════════════════════════════════════════
        # APPLICATION INSIGHTS
        # ═══════════════════════════════════════════════════════════════
        Write-ColorOutput "`n[12/15] Raccolta Application Insights..." "Yellow"
        try {
            $appInsights = Get-AzResource -ResourceType "Microsoft.Insights/components" -ErrorAction Stop
            
            foreach ($ai in $appInsights) {
                $monitoringData.ApplicationInsights += @{
                    Name          = $ai.Name
                    ResourceGroup = $ai.ResourceGroupName
                    Location      = $ai.Location
                }
            }
            
            Write-ColorOutput "✓ Trovati $($monitoringData.ApplicationInsights.Count) App Insights" "Green"
            
        } catch {
            Write-ColorOutput "⚠ Nessun App Insights" "Yellow"
        }
        
        # ═══════════════════════════════════════════════════════════════
        # WORKBOOKS
        # ═══════════════════════════════════════════════════════════════
        Write-ColorOutput "`n[13/15] Raccolta Workbooks..." "Yellow"
        try {
            $workbooks = Get-AzResource -ResourceType "Microsoft.Insights/workbooks" -ErrorAction SilentlyContinue
            
            foreach ($wb in $workbooks) {
                $monitoringData.Workbooks += @{
                    Name = $wb.Name
                }
            }
            
            Write-ColorOutput "✓ Trovati $($monitoringData.Workbooks.Count) Workbooks" "Green"
            
        } catch {
            Write-ColorOutput "⚠ Nessun Workbook" "Yellow"
        }
        
        # ═══════════════════════════════════════════════════════════════
        # DIAGNOSTIC SETTINGS (SAMPLE)
        # ═══════════════════════════════════════════════════════════════
        Write-ColorOutput "`n[14/15] Diagnostic Settings (sample)..." "Yellow"
        Write-ColorOutput "⊗ Saltato per performance" "DarkGray"
        
        # ═══════════════════════════════════════════════════════════════
        # SUMMARY
        # ═══════════════════════════════════════════════════════════════
        Write-ColorOutput "`n[15/15] Generazione Summary..." "Yellow"
        
        $totalMachines = $monitoringData.AzureVMs.Count + $monitoringData.ArcServers.Count
        $machinesWithAMA = ($monitoringData.AzureVMs + $monitoringData.ArcServers | Where-Object { $_.HasAMA }).Count
        $machinesWithLegacy = ($monitoringData.AzureVMs + $monitoringData.ArcServers | Where-Object { $_.HasLegacyMMA }).Count
        $machinesWithInsights = ($monitoringData.AzureVMs + $monitoringData.ArcServers | Where-Object { $_.HasAMA -and $_.HasDependencyAgent }).Count
        
        $monitoringData.Summary = @{
            TotalMachines              = $totalMachines
            AzureVMs                   = $monitoringData.AzureVMs.Count
            ArcServers                 = $monitoringData.ArcServers.Count
            MachinesWithAMA            = $machinesWithAMA
            MachinesWithLegacyMMA      = $machinesWithLegacy
            MachinesWithVMInsights     = $machinesWithInsights
            UnmonitoredMachines        = $totalMachines - $machinesWithAMA - $machinesWithLegacy
            AMA_Coverage_Percent       = if ($totalMachines -gt 0) { [math]::Round(($machinesWithAMA / $totalMachines) * 100, 2) } else { 0 }
            Insights_Coverage_Percent  = if ($totalMachines -gt 0) { [math]::Round(($machinesWithInsights / $totalMachines) * 100, 2) } else { 0 }
            TotalDCRs                  = $monitoringData.DataCollectionRules.Count
            TotalDCRAssociations       = $monitoringData.DCRAssociations.Count
            TotalWorkspaces            = $monitoringData.LogAnalyticsWorkspaces.Count
            WorkspacesWithVMInsights   = ($monitoringData.LogAnalyticsWorkspaces | Where-Object { $_.HasVMInsights }).Count
            TotalMonitoringPolicies    = $monitoringData.PolicyAssignments.Count
            NonCompliantPolicies       = ($monitoringData.PolicyAssignments | Where-Object { $_.ComplianceState -eq "NonCompliant" }).Count
            TotalManagedIdentities     = $monitoringData.ManagedIdentities.Count
            TotalActionGroups          = $monitoringData.ActionGroups.Count
            TotalMetricAlerts          = $monitoringData.MetricAlerts.Count
            TotalLogAlerts             = $monitoringData.LogAlerts.Count
            TotalAppInsights           = $monitoringData.ApplicationInsights.Count
            TotalWorkbooks             = $monitoringData.Workbooks.Count
        }
        
        Write-ColorOutput "✓ Summary completato" "Green"
        
        Write-ColorOutput "`n╔══════════════════════════════════════════════════════════════════════╗" "Cyan"
        Write-ColorOutput "║                      QUICK SUMMARY                                   ║" "Cyan"
        Write-ColorOutput "╚══════════════════════════════════════════════════════════════════════╝" "Cyan"
        Write-ColorOutput "  Macchine: $totalMachines | AMA: $machinesWithAMA ($($monitoringData.Summary.AMA_Coverage_Percent)%)" "White"
        Write-ColorOutput "  DCR: $($monitoringData.DataCollectionRules.Count) | Workspaces: $($monitoringData.LogAnalyticsWorkspaces.Count)" "White"
        Write-ColorOutput "  Policy: $($monitoringData.PolicyAssignments.Count) | Alerts: $($monitoringData.MetricAlerts.Count + $monitoringData.LogAlerts.Count)" "White"
        
    } catch {
        Write-ColorOutput "ERRORE: $($_.Exception.Message)" "Red"
        throw
    }
    
    Write-ColorOutput "`n╔══════════════════════════════════════════════════════════════════════╗" "Green"
    Write-ColorOutput "║              RACCOLTA DATI COMPLETATA                                ║" "Green"
    Write-ColorOutput "╚══════════════════════════════════════════════════════════════════════╝" "Green"
    
    return $monitoringData
}

# ============================================================================
# ANALISI AI
# ============================================================================

function Invoke-AIAnalysis {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$MonitoringData
    )
    
    Write-ColorOutput "`n╔══════════════════════════════════════════════════════════════════════╗" "Cyan"
    Write-ColorOutput "║                    ANALISI AI IN CORSO                               ║" "Cyan"
    Write-ColorOutput "╚══════════════════════════════════════════════════════════════════════╝" "Cyan"
    
    $dataJson = $MonitoringData | ConvertTo-Json -Depth 8 -Compress
    
    Write-ColorOutput "  Dimensione dati: $([math]::Round($dataJson.Length / 1KB, 2)) KB" "DarkGray"
    
    $prompt = @"
Analizza questi dati Azure Monitor e genera un report DETTAGLIATO in ITALIANO in formato HTML.

DATI:
$dataJson

GENERA SEZIONI HTML CON:

1. EXECUTIVE SUMMARY (con punteggio maturità 1-10, coverage %, criticità TOP 3)
2. ANALISI VM & ARC (distribuzione agenti, VM non monitorate, identity)
3. DATA COLLECTION RULES (tipi DCR, associazioni, configurazione)
4. LOG ANALYTICS WORKSPACES (soluzioni attive, retention, quota)
5. AZURE POLICY (compliance, policy mancanti)
6. ALERTING (metric/log alerts, action groups, gaps)
7. RACCOMANDAZIONI PRIORITARIE (TOP 10 azioni, quick wins, migration MMA→AMA)
8. COSTI & OTTIMIZZAZIONE
9. COMPLIANCE & SECURITY
10. ROADMAP 30-60-90 giorni

Usa HTML con <div class="section">, <h2>, <ul>, <table> per strutturare.
Usa emoji per rendere visivo.
Sii tecnico ma chiaro.
"@
    
    $headers = @{
        "Content-Type" = "application/json"
        "api-key"      = $apiKey
    }
    
    $requestBody = @{
        messages = @(
            @{
                role    = "system"
                content = "Sei un Azure Solutions Architect esperto. Rispondi in italiano con report HTML dettagliati."
            }
            @{
                role    = "user"
                content = $prompt
            }
        )
        max_completion_tokens = 4000
    }
    
    $body = $requestBody | ConvertTo-Json -Depth 5
    
    try {
        Write-ColorOutput "  Invio richiesta AI..." "Yellow"
        
        $response = Invoke-RestMethod -Uri $endpoint -Method POST -Headers $headers -Body $body -ContentType "application/json" -TimeoutSec 180
        
        if ($response.choices -and $response.choices[0].message.content) {
            $aiReport = $response.choices[0].message.content
            Write-ColorOutput "✓ Report AI generato!" "Green"
            Write-ColorOutput "  Token: $($response.usage.total_tokens)" "DarkGray"
            
            return $aiReport
        } else {
            throw "Risposta AI non valida"
        }
        
    } catch {
        Write-ColorOutput "⚠ ERRORE AI: $($_.Exception.Message)" "Red"
        
        Write-ColorOutput "`nGenerazione report semplificato..." "Yellow"
        
        return Generate-SimpleHTMLReport -Data $MonitoringData
    }
}

function Generate-SimpleHTMLReport {
    param([hashtable]$Data)
    
    $html = @"
<div class="section">
<h2>📊 AZURE MONITOR ANALYSIS (Fallback Report)</h2>

<div class="card">
<h3>Machines Overview</h3>
<table>
<tr><th>Metric</th><th>Value</th></tr>
<tr><td>Total Machines</td><td>$($Data.Summary.TotalMachines)</td></tr>
<tr><td>Azure VMs</td><td>$($Data.Summary.AzureVMs)</td></tr>
<tr><td>Arc Servers</td><td>$($Data.Summary.ArcServers)</td></tr>
<tr><td>With AMA</td><td>$($Data.Summary.MachinesWithAMA) ($($Data.Summary.AMA_Coverage_Percent)%)</td></tr>
<tr><td>With VM Insights</td><td>$($Data.Summary.MachinesWithVMInsights)</td></tr>
<tr><td>Unmonitored</td><td>$($Data.Summary.UnmonitoredMachines)</td></tr>
</table>
</div>

<div class="card">
<h3>Infrastructure</h3>
<ul>
<li>Data Collection Rules: $($Data.Summary.TotalDCRs)</li>
<li>DCR Associations: $($Data.Summary.TotalDCRAssociations)</li>
<li>Log Analytics Workspaces: $($Data.Summary.TotalWorkspaces)</li>
<li>Monitoring Policies: $($Data.Summary.TotalMonitoringPolicies)</li>
</ul>
</div>

<div class="card alert-warning">
<h3>⚠ Raccomandazioni Prioritarie</h3>
<ol>
$(if ($Data.Summary.UnmonitoredMachines -gt 0) { "<li>Installare AMA su $($Data.Summary.UnmonitoredMachines) macchine</li>" })
$(if ($Data.Summary.TotalDCRs -eq 0) { "<li>Configurare Data Collection Rules</li>" })
$(if ($Data.Summary.TotalMonitoringPolicies -eq 0) { "<li>Implementare Azure Policy per monitoring</li>" })
$(if ($Data.Summary.TotalActionGroups -eq 0) { "<li>Configurare Action Groups</li>" })
$(if ($Data.Summary.TotalMetricAlerts -eq 0) { "<li>Configurare Alert critici</li>" })
</ol>
</div>
</div>
"@
    
    return $html
}

# ============================================================================
# ESPORTAZIONE HTML PROFESSIONALE
# ============================================================================

function Export-HTMLReport {
    param(
        [string]$AIReport,
        [hashtable]$RawData,
        [string]$OutputPath
    )
    
    Write-ColorOutput "`n╔══════════════════════════════════════════════════════════════════════╗" "Cyan"
    Write-ColorOutput "║                  ESPORTAZIONE REPORT HTML                            ║" "Cyan"
    Write-ColorOutput "╚══════════════════════════════════════════════════════════════════════╝" "Cyan"
    
    # Calcola metriche per dashboard
    $maturityScore = 2
    if ($RawData.Summary.AMA_Coverage_Percent -gt 80) { $maturityScore += 3 }
    elseif ($RawData.Summary.AMA_Coverage_Percent -gt 50) { $maturityScore += 2 }
    elseif ($RawData.Summary.AMA_Coverage_Percent -gt 0) { $maturityScore += 1 }
    
    if ($RawData.Summary.TotalDCRs -gt 0) { $maturityScore += 1 }
    if ($RawData.Summary.TotalMonitoringPolicies -gt 0) { $maturityScore += 1 }
    if ($RawData.Summary.TotalActionGroups -gt 0) { $maturityScore += 1 }
    if ($RawData.Summary.TotalMetricAlerts -gt 0 -or $RawData.Summary.TotalLogAlerts -gt 0) { $maturityScore += 1 }
    if ($RawData.Summary.WorkspacesWithVMInsights -gt 0) { $maturityScore += 1 }
    
    $maturityColor = if ($maturityScore -le 3) { "#e74c3c" } elseif ($maturityScore -le 6) { "#f39c12" } else { "#27ae60" }
    
    $htmlTemplate = @"
<!DOCTYPE html>
<html lang="it">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure Monitor Analysis Report - $($RawData.Subscription.Name)</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 20px;
            color: #2c3e50;
        }
        
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            border-radius: 20px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            overflow: hidden;
        }
        
        .header {
            background: linear-gradient(135deg, #0078d4 0%, #00bcf2 100%);
            color: white;
            padding: 40px;
            text-align: center;
        }
        
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.2);
        }
        
        .header .subtitle {
            font-size: 1.2em;
            opacity: 0.9;
        }
        
        .header .meta {
            margin-top: 20px;
            font-size: 0.9em;
            opacity: 0.8;
        }
        
        .dashboard {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            padding: 30px;
            background: #f8f9fa;
        }
        
        .metric-card {
            background: white;
            border-radius: 15px;
            padding: 25px;
            box-shadow: 0 5px 15px rgba(0,0,0,0.1);
            border-left: 5px solid #0078d4;
            transition: transform 0.3s ease, box-shadow 0.3s ease;
        }
        
        .metric-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 10px 30px rgba(0,0,0,0.15);
        }
        
        .metric-card .icon {
            font-size: 2.5em;
            margin-bottom: 10px;
        }
        
        .metric-card .label {
            font-size: 0.9em;
            color: #7f8c8d;
            margin-bottom: 5px;
        }
        
        .metric-card .value {
            font-size: 2em;
            font-weight: bold;
            color: #0078d4;
        }
        
        .metric-card .subtext {
            font-size: 0.85em;
            color: #95a5a6;
            margin-top: 5px;
        }
        
        .maturity-score {
            background: linear-gradient(135deg, $maturityColor 0%, darken($maturityColor, 10%) 100%);
            color: white;
            border-left-color: white;
        }
        
        .maturity-score .value {
            color: white;
            font-size: 3em;
        }
        
        .content {
            padding: 40px;
        }
        
        .section {
            margin-bottom: 40px;
        }
        
        .section h2 {
            color: #0078d4;
            font-size: 1.8em;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 3px solid #0078d4;
        }
        
        .card {
            background: #f8f9fa;
            border-radius: 10px;
            padding: 25px;
            margin-bottom: 20px;
            border-left: 4px solid #0078d4;
        }
        
        .card h3 {
            color: #2c3e50;
            margin-bottom: 15px;
            font-size: 1.3em;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 15px;
            background: white;
            border-radius: 8px;
            overflow: hidden;
        }
        
        th {
            background: #0078d4;
            color: white;
            padding: 12px;
            text-align: left;
            font-weight: 600;
        }
        
        td {
            padding: 12px;
            border-bottom: 1px solid #ecf0f1;
        }
        
        tr:hover {
            background: #f1f3f5;
        }
        
        .alert-warning {
            background: #fff3cd;
            border-left-color: #ffc107;
        }
        
        .alert-danger {
            background: #f8d7da;
            border-left-color: #dc3545;
        }
        
        .alert-success {
            background: #d4edda;
            border-left-color: #28a745;
        }
        
        ul, ol {
            margin-left: 25px;
            margin-top: 10px;
        }
        
        li {
            margin-bottom: 8px;
            line-height: 1.6;
        }
        
        .badge {
            display: inline-block;
            padding: 5px 12px;
            border-radius: 20px;
            font-size: 0.85em;
            font-weight: 600;
            margin-right: 5px;
        }
        
        .badge-success { background: #d4edda; color: #155724; }
        .badge-warning { background: #fff3cd; color: #856404; }
        .badge-danger { background: #f8d7da; color: #721c24; }
        .badge-info { background: #d1ecf1; color: #0c5460; }
        
        .progress-bar {
            width: 100%;
            height: 30px;
            background: #ecf0f1;
            border-radius: 15px;
            overflow: hidden;
            margin: 10px 0;
        }
        
        .progress-fill {
            height: 100%;
            background: linear-gradient(90deg, #0078d4 0%, #00bcf2 100%);
            display: flex;
            align-items: center;
            justify-content: center;
            color: white;
            font-weight: bold;
            transition: width 1s ease;
        }
        
        .footer {
            background: #2c3e50;
            color: white;
            padding: 30px;
            text-align: center;
        }
        
        .vm-list {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
            gap: 15px;
            margin-top: 15px;
        }
        
        .vm-card {
            background: white;
            border-radius: 8px;
            padding: 15px;
            border-left: 4px solid #0078d4;
        }
        
        .vm-card.monitored { border-left-color: #28a745; }
        .vm-card.unmonitored { border-left-color: #dc3545; }
        
        .vm-card h4 {
            color: #2c3e50;
            margin-bottom: 10px;
        }
        
        .vm-card .vm-meta {
            font-size: 0.85em;
            color: #7f8c8d;
        }
        
        @media print {
            body { background: white; padding: 0; }
            .container { box-shadow: none; }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔍 Azure Monitor Analysis Report</h1>
            <div class="subtitle">Deep Analysis & Recommendations</div>
            <div class="meta">
                <strong>Subscription:</strong> $($RawData.Subscription.Name)<br>
                <strong>Generated:</strong> $($RawData.Timestamp)<br>
                <strong>Tenant:</strong> $($RawData.Subscription.TenantId)
            </div>
        </div>
        
        <div class="dashboard">
            <div class="metric-card maturity-score">
                <div class="icon">🎯</div>
                <div class="label">Maturity Score</div>
                <div class="value">$maturityScore/10</div>
                <div class="subtext">Azure Monitor Readiness</div>
            </div>
            
            <div class="metric-card">
                <div class="icon">💻</div>
                <div class="label">Total Machines</div>
                <div class="value">$($RawData.Summary.TotalMachines)</div>
                <div class="subtext">Azure VMs: $($RawData.Summary.AzureVMs) | Arc: $($RawData.Summary.ArcServers)</div>
            </div>
            
            <div class="metric-card">
                <div class="icon">📊</div>
                <div class="label">AMA Coverage</div>
                <div class="value">$($RawData.Summary.AMA_Coverage_Percent)%</div>
                <div class="subtext">$($RawData.Summary.MachinesWithAMA) / $($RawData.Summary.TotalMachines) machines</div>
                <div class="progress-bar">
                    <div class="progress-fill" style="width: $($RawData.Summary.AMA_Coverage_Percent)%">
                        $($RawData.Summary.AMA_Coverage_Percent)%
                    </div>
                </div>
            </div>
            
            <div class="metric-card">
                <div class="icon">📋</div>
                <div class="label">Data Collection Rules</div>
                <div class="value">$($RawData.Summary.TotalDCRs)</div>
                <div class="subtext">Associations: $($RawData.Summary.TotalDCRAssociations)</div>
            </div>
            
            <div class="metric-card">
                <div class="icon">📁</div>
                <div class="label">Log Analytics</div>
                <div class="value">$($RawData.Summary.TotalWorkspaces)</div>
                <div class="subtext">VM Insights: $($RawData.Summary.WorkspacesWithVMInsights)</div>
            </div>
            
            <div class="metric-card">
                <div class="icon">🛡️</div>
                <div class="label">Azure Policies</div>
                <div class="value">$($RawData.Summary.TotalMonitoringPolicies)</div>
                <div class="subtext">Non-Compliant: $($RawData.Summary.NonCompliantPolicies)</div>
            </div>
            
            <div class="metric-card">
                <div class="icon">🔔</div>
                <div class="label">Alerts</div>
                <div class="value">$($RawData.Summary.TotalMetricAlerts + $RawData.Summary.TotalLogAlerts)</div>
                <div class="subtext">Metric: $($RawData.Summary.TotalMetricAlerts) | Log: $($RawData.Summary.TotalLogAlerts)</div>
            </div>
            
            <div class="metric-card">
                <div class="icon">📧</div>
                <div class="label">Action Groups</div>
                <div class="value">$($RawData.Summary.TotalActionGroups)</div>
                <div class="subtext">Notification channels</div>
            </div>
        </div>
        
        <div class="content">
            $AIReport
            
            <div class="section">
                <h2>🖥️ Virtual Machines Details</h2>
                <div class="vm-list">
$(foreach ($vm in $RawData.AzureVMs) {
    $statusClass = if ($vm.HasAMA) { "monitored" } else { "unmonitored" }
    $statusIcon = if ($vm.HasAMA) { "✅" } else { "❌" }
    
    @"
                    <div class="vm-card $statusClass">
                        <h4>$statusIcon $($vm.Name)</h4>
                        <div class="vm-meta">
                            <strong>OS:</strong> $($vm.OsType)<br>
                            <strong>Size:</strong> $($vm.VmSize)<br>
                            <strong>State:</strong> $($vm.PowerState)<br>
                            <strong>Extensions:</strong> $($vm.ExtensionCount)<br>
                            $(if ($vm.HasAMA) { "<span class='badge badge-success'>AMA</span>" })
                            $(if ($vm.HasLegacyMMA) { "<span class='badge badge-warning'>Legacy MMA</span>" })
                            $(if ($vm.HasDependencyAgent) { "<span class='badge badge-info'>Dependency Agent</span>" })
                        </div>
                    </div>
"@
})
                </div>
            </div>
            
            <div class="section">
                <h2>📊 Azure Policy Compliance</h2>
                <table>
                    <thead>
                        <tr>
                            <th>Policy Name</th>
                            <th>Category</th>
                            <th>Compliance</th>
                            <th>Non-Compliant Resources</th>
                        </tr>
                    </thead>
                    <tbody>
$(foreach ($policy in $RawData.PolicyAssignments) {
    $complianceBadge = if ($policy.ComplianceState -eq "Compliant") { 
        "<span class='badge badge-success'>Compliant</span>" 
    } elseif ($policy.ComplianceState -eq "NonCompliant") { 
        "<span class='badge badge-danger'>Non-Compliant</span>" 
    } else { 
        "<span class='badge badge-warning'>Unknown</span>" 
    }
    
    @"
                        <tr>
                            <td>$($policy.DisplayName)</td>
                            <td>$($policy.Category)</td>
                            <td>$complianceBadge</td>
                            <td>$($policy.NonCompliantResources)</td>
                        </tr>
"@
})
                    </tbody>
                </table>
            </div>
            
            <div class="section">
                <h2>📋 Data Collection Rules</h2>
                <table>
                    <thead>
                        <tr>
                            <th>Name</th>
                            <th>Type</th>
                            <th>Location</th>
                            <th>Description</th>
                        </tr>
                    </thead>
                    <tbody>
$(foreach ($dcr in $RawData.DataCollectionRules) {
    @"
                        <tr>
                            <td>$($dcr.Name)</td>
                            <td><span class='badge badge-info'>$($dcr.Type)</span></td>
                            <td>$($dcr.Location)</td>
                            <td>$($dcr.Description)</td>
                        </tr>
"@
})
                    </tbody>
                </table>
            </div>
        </div>
        
        <div class="footer">
            <p><strong>Azure Monitor Deep Analysis Tool</strong></p>
            <p>Generated with AI-powered analysis | Version 3.0 FINAL</p>
            <p style="margin-top: 10px; font-size: 0.9em; opacity: 0.8;">
                📄 <a href="#" style="color: white;" onclick="window.print()">Print Report</a> | 
                💾 Export as JSON available
            </p>
        </div>
    </div>
</body>
</html>
"@
    
    try {
        # Salva HTML
        $htmlTemplate | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
        Write-ColorOutput "✓ Report HTML salvato: $OutputPath" "Green"
        
        # Salva JSON
        $jsonPath = $OutputPath -replace "\.html$", ".json"
        $RawData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force
        Write-ColorOutput "✓ JSON salvato: $jsonPath" "Green"
        
        # Salva CSV VM
        $csvPath = $OutputPath -replace "\.html$", "_VMs.csv"
        $allMachines = $RawData.AzureVMs + $RawData.ArcServers
        if ($allMachines.Count -gt 0) {
            $allMachines | Select-Object Name, Type, OsType, VmSize, PowerState, HasAMA, HasLegacyMMA, HasDependencyAgent, ExtensionCount | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
            Write-ColorOutput "✓ CSV salvato: $csvPath" "Green"
        }
        
    } catch {
        Write-ColorOutput "⚠ Errore salvataggio: $($_.Exception.Message)" "Red"
        throw
    }
}

# ============================================================================
# MAIN
# ============================================================================

try {
    $startTime = Get-Date
    
    Write-ColorOutput @"
╔════════════════════════════════════════════════════════════════════╗
║                                                                    ║
║     AZURE MONITOR DEEP ANALYZER - v3.0 FINAL                      ║
║     Professional HTML Report Edition                               ║
║                                                                    ║
╚════════════════════════════════════════════════════════════════════╝
"@ "Cyan"
    
    # Fix moduli
    Fix-AzureModules
    
    # Raccolta dati
    $monitoringData = Get-AzureMonitorDataAdvanced
    
    # Analisi AI
    $aiReport = Invoke-AIAnalysis -MonitoringData $monitoringData
    
    # Esportazione HTML
    Export-HTMLReport -AIReport $aiReport -RawData $monitoringData -OutputPath $OutputPath
    
    $duration = (Get-Date) - $startTime
    
    Write-ColorOutput "`n╔════════════════════════════════════════════════════════════════════╗" "Green"
    Write-ColorOutput "║                   ✓ COMPLETATO!                                    ║" "Green"
    Write-ColorOutput "╚════════════════════════════════════════════════════════════════════╝" "Green"
    Write-ColorOutput "`nTempo: $($duration.Minutes)m $($duration.Seconds)s" "White"
    
    Write-ColorOutput "`n📄 Files generati:" "Cyan"
    Write-ColorOutput "  ├─ 🌐 Report HTML: $OutputPath" "White"
    Write-ColorOutput "  ├─ 📊 JSON Data:   $($OutputPath -replace '\.html$', '.json')" "White"
    Write-ColorOutput "  └─ 📈 VM CSV:      $($OutputPath -replace '\.html$', '_VMs.csv')" "White"
    
    Write-ColorOutput "`n💡 Apri il report:" "Yellow"
    Write-ColorOutput "   Invoke-Item '$OutputPath'" "Gray"
    
    # Apri automaticamente il browser
    Start-Process $OutputPath
    
} catch {
    Write-ColorOutput "`n╔════════════════════════════════════════════════════════════════════╗" "Red"
    Write-ColorOutput "║                         ✗ ERRORE                                   ║" "Red"
    Write-ColorOutput "╚════════════════════════════════════════════════════════════════════╝" "Red"
    Write-ColorOutput $_.Exception.Message "Red"
    
    $errorLog = ".\Error_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $_ | Out-File $errorLog
    Write-ColorOutput "`n⚠ Error log: $errorLog" "Yellow"
    
    exit 1
}