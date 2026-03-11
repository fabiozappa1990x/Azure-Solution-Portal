targetScope = 'subscription'

@description('Deployment name prefix')
param deploymentName string

@description('Azure region (used for policy assignment identity only)')
param location string = deployment().location

// ── Defender Plans ────────────────────────────────────────────────────────────

@description('Enable Defender for Servers')
param enableDefenderForServers bool = true

@description('Servers plan tier: Standard (paid) or Free')
@allowed(['Standard', 'Free'])
param serversPlanTier string = 'Standard'

@description('Servers sub-plan: P1 (basic) or P2 (full with MDE)')
@allowed(['P1', 'P2'])
param serversSubPlan string = 'P2'

@description('Enable Defender for SQL Servers on Machines')
param enableDefenderForSqlVm bool = true

@description('Enable Defender for Storage')
param enableDefenderForStorage bool = true

@description('Enable Defender for Key Vault')
param enableDefenderForKeyVault bool = true

@description('Enable Defender for Resource Manager')
param enableDefenderForARM bool = true

@description('Enable Defender for DNS')
param enableDefenderForDns bool = false

@description('Enable Defender for App Service')
param enableDefenderForAppService bool = false

@description('Enable Defender for Containers')
param enableDefenderForContainers bool = false

@description('Enable Defender CSPM (Cloud Security Posture Management)')
param enableCSPM bool = true

// ── Security Contacts ─────────────────────────────────────────────────────────

@description('Security contact email addresses (semicolon-separated)')
param emailRecipients string

@description('Security contact phone number')
param phone string = ''

@description('Notify on medium severity alerts (in addition to high)')
param alertNotificationsMediumSeverity bool = true

@description('Notify subscription owners for high severity alerts')
param notifySubscriptionOwners bool = true

// ── Auto-Provisioning ─────────────────────────────────────────────────────────

@description('Enable auto-provisioning of Microsoft Defender for Endpoint')
param enableMDEAutoProvisioning bool = true

@description('Enable auto-provisioning of Azure Monitor Agent via Defender')
param enableAMAAutoProvisioning bool = true

// ── Azure Policy ──────────────────────────────────────────────────────────────

@description('Assign built-in Azure Security Benchmark initiative')
param assignSecurityBenchmark bool = true

@description('Enforcement mode for benchmark initiative')
@allowed(['Default', 'DoNotEnforce'])
param securityBenchmarkEnforcementMode string = 'DoNotEnforce'

// ─────────────────────────────────────────────────────────────────────────────

module defenderPlans 'modules/defender-plans.bicep' = {
  name: 'deploy-defender-plans'
  params: {
    enableDefenderForServers: enableDefenderForServers
    serversPlanTier: serversPlanTier
    serversSubPlan: serversSubPlan
    enableDefenderForSqlVm: enableDefenderForSqlVm
    enableDefenderForStorage: enableDefenderForStorage
    enableDefenderForKeyVault: enableDefenderForKeyVault
    enableDefenderForARM: enableDefenderForARM
    enableDefenderForDns: enableDefenderForDns
    enableDefenderForAppService: enableDefenderForAppService
    enableDefenderForContainers: enableDefenderForContainers
    enableCSPM: enableCSPM
  }
}

module securityContacts 'modules/security-contacts.bicep' = {
  name: 'deploy-security-contacts'
  params: {
    emailRecipients: emailRecipients
    phone: phone
    notifySubscriptionOwners: notifySubscriptionOwners
    alertNotificationsMediumSeverity: alertNotificationsMediumSeverity
    enableMDEAutoProvisioning: enableMDEAutoProvisioning
    enableAMAAutoProvisioning: enableAMAAutoProvisioning
  }
}

// Assign Microsoft Cloud Security Benchmark (built-in initiative)
resource securityBenchmarkAssignment 'Microsoft.Authorization/policyAssignments@2023-04-01' = if (assignSecurityBenchmark) {
  name: 'assign-${take(deploymentName, 40)}-mcsb'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'Microsoft Cloud Security Benchmark'
    description: 'Iniziativa di sicurezza Microsoft Cloud Security Benchmark per compliance e postura'
    // Microsoft Cloud Security Benchmark initiative
    policyDefinitionId: '/providers/Microsoft.Authorization/policySetDefinitions/1f3afdf9-d0c9-4c3d-847f-89da613e70a8'
    enforcementMode: securityBenchmarkEnforcementMode
    parameters: {}
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

output enabledPlans array = defenderPlans.outputs.enabledPlans
output defenderPortalUrl string = 'https://portal.azure.com/#view/Microsoft_Azure_Security/SecurityMenuBlade/~/0'
