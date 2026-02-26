targetScope = 'subscription'

@description('Enable Defender for Servers (Plan 2)')
param enableDefenderForServers bool = true

@description('Servers plan tier')
@allowed(['Standard', 'Free'])
param serversPlanTier string = 'Standard'

@description('Servers sub-plan (P1 = basic, P2 = full with EDR)')
@allowed(['P1', 'P2'])
param serversSubPlan string = 'P2'

@description('Enable Defender for SQL Servers on Machines')
param enableDefenderForSqlVm bool = true

@description('Enable Defender for App Service')
param enableDefenderForAppService bool = false

@description('Enable Defender for Storage')
param enableDefenderForStorage bool = true

@description('Enable Defender for Key Vaults')
param enableDefenderForKeyVault bool = true

@description('Enable Defender for Resource Manager')
param enableDefenderForARM bool = true

@description('Enable Defender for DNS')
param enableDefenderForDns bool = false

@description('Enable Defender for Containers (AKS, ACR)')
param enableDefenderForContainers bool = false

@description('Enable CSPM (Cloud Security Posture Management) Defender plan')
param enableCSPM bool = true

// Servers
resource defenderServers 'Microsoft.Security/pricings@2024-01-01' = if (enableDefenderForServers) {
  name: 'VirtualMachines'
  properties: {
    pricingTier: serversPlanTier
    subPlan: serversPlanTier == 'Standard' ? serversSubPlan : null
  }
}

// SQL Servers on Machines
resource defenderSqlVm 'Microsoft.Security/pricings@2024-01-01' = if (enableDefenderForSqlVm) {
  name: 'SqlServerVirtualMachines'
  properties: {
    pricingTier: 'Standard'
  }
}

// App Service
resource defenderAppService 'Microsoft.Security/pricings@2024-01-01' = if (enableDefenderForAppService) {
  name: 'AppServices'
  properties: {
    pricingTier: 'Standard'
  }
}

// Storage
resource defenderStorage 'Microsoft.Security/pricings@2024-01-01' = if (enableDefenderForStorage) {
  name: 'StorageAccounts'
  properties: {
    pricingTier: 'Standard'
    subPlan: 'DefenderForStorageV2'
  }
}

// Key Vault
resource defenderKeyVault 'Microsoft.Security/pricings@2024-01-01' = if (enableDefenderForKeyVault) {
  name: 'KeyVaults'
  properties: {
    pricingTier: 'Standard'
  }
}

// Resource Manager
resource defenderARM 'Microsoft.Security/pricings@2024-01-01' = if (enableDefenderForARM) {
  name: 'Arm'
  properties: {
    pricingTier: 'Standard'
  }
}

// DNS
resource defenderDns 'Microsoft.Security/pricings@2024-01-01' = if (enableDefenderForDns) {
  name: 'Dns'
  properties: {
    pricingTier: 'Standard'
  }
}

// Containers
resource defenderContainers 'Microsoft.Security/pricings@2024-01-01' = if (enableDefenderForContainers) {
  name: 'Containers'
  properties: {
    pricingTier: 'Standard'
  }
}

// CSPM (Defender CSPM for enhanced posture management)
resource defenderCSPM 'Microsoft.Security/pricings@2024-01-01' = if (enableCSPM) {
  name: 'CloudPosture'
  properties: {
    pricingTier: 'Standard'
  }
}

output enabledPlans array = filter([
  enableDefenderForServers   ? 'Defender for Servers (${serversSubPlan})' : null
  enableDefenderForSqlVm     ? 'Defender for SQL on VMs' : null
  enableDefenderForAppService ? 'Defender for App Service' : null
  enableDefenderForStorage   ? 'Defender for Storage' : null
  enableDefenderForKeyVault  ? 'Defender for Key Vault' : null
  enableDefenderForARM       ? 'Defender for Resource Manager' : null
  enableDefenderForDns       ? 'Defender for DNS' : null
  enableDefenderForContainers ? 'Defender for Containers' : null
  enableCSPM                 ? 'Defender CSPM' : null
], item => item != null)
