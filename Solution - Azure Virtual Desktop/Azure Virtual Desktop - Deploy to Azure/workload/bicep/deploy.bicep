targetScope = 'subscription'

@description('Deployment name prefix (used for resource naming)')
param deploymentName string

@description('Azure region for AVD resources')
param location string = deployment().location

@description('Use existing Resource Group')
param useExistingResourceGroup bool = false

@description('Existing Resource Group name (if useExistingResourceGroup is true)')
param existingResourceGroupName string = ''

// ── Host Pool ────────────────────────────────────────────────────────────────

@description('Host Pool type')
@allowed(['Pooled', 'Personal'])
param hostPoolType string = 'Pooled'

@description('Load balancer type (Pooled only)')
@allowed(['BreadthFirst', 'DepthFirst'])
param loadBalancerType string = 'BreadthFirst'

@description('Max sessions per host (Pooled only)')
param maxSessionLimit int = 10

@description('Enable Start VM on Connect')
param startVMOnConnect bool = true

// ── Session Hosts ────────────────────────────────────────────────────────────

@description('Number of session hosts to deploy')
@minValue(0)
@maxValue(50)
param sessionHostCount int = 2

@description('VM size for session hosts')
param vmSize string = 'Standard_D4s_v5'

@description('OS disk type')
@allowed(['Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS'])
param osDiskType string = 'Premium_LRS'

@description('AVD image SKU')
@allowed(['win11-23h2-avd', 'win11-22h2-avd', 'win10-22h2-avd-g2', 'win11-23h2-avd-m365'])
param imageSku string = 'win11-23h2-avd'

@description('Local admin username for session hosts')
param adminUsername string

@description('Local admin password for session hosts')
@secure()
param adminPassword string

// ── Networking ───────────────────────────────────────────────────────────────

@description('Virtual Network Resource ID')
param vnetId string

@description('Subnet name for session hosts')
param subnetName string

// ── Identity / Join ──────────────────────────────────────────────────────────

@description('Join type: AzureAD or ActiveDirectory')
@allowed(['AzureAD', 'ActiveDirectory'])
param joinType string = 'AzureAD'

@description('AD domain to join (required if joinType = ActiveDirectory)')
param domainToJoin string = ''

@description('Domain join UPN')
param domainJoinUser string = ''

@description('Domain join password')
@secure()
param domainJoinPassword string = ''

@description('OU path for domain join')
param ouPath string = ''

@description('Enable Intune enrollment (AzureAD join only)')
param intuneEnrollment bool = false

@description('Azure AD Group Object IDs for AVD users')
param userGroupObjectIds array = []

// ── FSLogix ──────────────────────────────────────────────────────────────────

@description('Deploy FSLogix profile storage (Azure Files)')
param deployFSLogix bool = true

@description('FSLogix profile share quota in GB')
param fslogixShareQuotaGB int = 512

@description('FSLogix storage SKU')
@allowed(['Premium_LRS', 'Premium_ZRS', 'Standard_LRS', 'Standard_GRS'])
param fslogixStorageSku string = 'Premium_LRS'

// ── Scaling Plan ─────────────────────────────────────────────────────────────

@description('Deploy Scaling Plan for automatic session host power management')
param deployScalingPlan bool = true

@description('Timezone for scaling plan')
param scalingPlanTimeZone string = 'W. Europe Standard Time'

// ── Monitoring ───────────────────────────────────────────────────────────────

@description('Log Analytics Workspace Resource ID for AVD diagnostics')
param logAnalyticsWorkspaceId string = ''

// ── Tags ─────────────────────────────────────────────────────────────────────

@description('Tags for resources')
param tagsByResource object = {}

// ─────────────────────────────────────────────────────────────────────────────

var resourceGroupName = useExistingResourceGroup ? existingResourceGroupName : 'rg-${deploymentName}'

var baseTags = {
  DeployedBy: 'Azure-Solution-Portal'
  Solution: 'Azure-Virtual-Desktop'
  ManagedBy: 'Bicep'
}

var hostPoolName = 'hp-${deploymentName}'
var appGroupName = 'ag-${deploymentName}-desktop'
var workspaceName = 'ws-${deploymentName}'
var sessionHostPrefix = 'avd-${deploymentName}'
var storageAccountName = replace(replace('stfslogix${deploymentName}', '-', ''), '_', '')
var scalingPlanName = 'sp-${deploymentName}'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = if (!useExistingResourceGroup) {
  name: resourceGroupName
  location: location
  tags: union(baseTags, contains(tagsByResource, 'Microsoft.Resources/resourceGroups') ? tagsByResource['Microsoft.Resources/resourceGroups'] : {})
}

resource existingRg 'Microsoft.Resources/resourceGroups@2024-03-01' existing = if (useExistingResourceGroup) {
  name: existingResourceGroupName
}

module hostPool 'modules/host-pool.bicep' = {
  name: 'deploy-host-pool'
  scope: useExistingResourceGroup ? existingRg : rg
  params: {
    hostPoolName: hostPoolName
    location: location
    hostPoolType: hostPoolType
    loadBalancerType: loadBalancerType
    maxSessionLimit: maxSessionLimit
    startVMOnConnect: startVMOnConnect
    preferredAppGroupType: 'Desktop'
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: union(baseTags, contains(tagsByResource, 'Microsoft.DesktopVirtualization/hostPools') ? tagsByResource['Microsoft.DesktopVirtualization/hostPools'] : {})
  }
}

module appGroup 'modules/application-group.bicep' = {
  name: 'deploy-app-group'
  scope: useExistingResourceGroup ? existingRg : rg
  params: {
    appGroupName: appGroupName
    location: location
    hostPoolId: hostPool.outputs.hostPoolId
    appGroupType: 'Desktop'
    userGroupObjectIds: userGroupObjectIds
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: union(baseTags, contains(tagsByResource, 'Microsoft.DesktopVirtualization/applicationGroups') ? tagsByResource['Microsoft.DesktopVirtualization/applicationGroups'] : {})
  }
  dependsOn: [hostPool]
}

module workspace 'modules/workspace.bicep' = {
  name: 'deploy-workspace'
  scope: useExistingResourceGroup ? existingRg : rg
  params: {
    workspaceName: workspaceName
    location: location
    applicationGroupIds: [appGroup.outputs.appGroupId]
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: union(baseTags, contains(tagsByResource, 'Microsoft.DesktopVirtualization/workspaces') ? tagsByResource['Microsoft.DesktopVirtualization/workspaces'] : {})
  }
  dependsOn: [appGroup]
}

module sessionHosts 'modules/session-hosts.bicep' = if (sessionHostCount > 0) {
  name: 'deploy-session-hosts'
  scope: useExistingResourceGroup ? existingRg : rg
  params: {
    namePrefix: sessionHostPrefix
    location: location
    count: sessionHostCount
    vmSize: vmSize
    osDiskType: osDiskType
    imageSku: imageSku
    adminUsername: adminUsername
    adminPassword: adminPassword
    vnetId: vnetId
    subnetName: subnetName
    hostPoolName: hostPoolName
    registrationToken: hostPool.outputs.registrationToken
    domainToJoin: joinType == 'ActiveDirectory' ? domainToJoin : ''
    domainJoinUser: joinType == 'ActiveDirectory' ? domainJoinUser : ''
    domainJoinPassword: joinType == 'ActiveDirectory' ? domainJoinPassword : ''
    ouPath: ouPath
    intuneEnrollment: intuneEnrollment
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: union(baseTags, contains(tagsByResource, 'Microsoft.Compute/virtualMachines') ? tagsByResource['Microsoft.Compute/virtualMachines'] : {})
  }
  dependsOn: [hostPool]
}

module fslogix 'modules/fslogix.bicep' = if (deployFSLogix) {
  name: 'deploy-fslogix'
  scope: useExistingResourceGroup ? existingRg : rg
  params: {
    storageAccountName: take(storageAccountName, 24)
    location: location
    shareQuotaGB: fslogixShareQuotaGB
    storageSku: fslogixStorageSku
    userGroupObjectIds: userGroupObjectIds
    tags: union(baseTags, contains(tagsByResource, 'Microsoft.Storage/storageAccounts') ? tagsByResource['Microsoft.Storage/storageAccounts'] : {})
  }
}

module scalingPlan 'modules/scaling-plan.bicep' = if (deployScalingPlan && hostPoolType == 'Pooled') {
  name: 'deploy-scaling-plan'
  scope: useExistingResourceGroup ? existingRg : rg
  params: {
    scalingPlanName: scalingPlanName
    location: location
    hostPoolId: hostPool.outputs.hostPoolId
    timeZone: scalingPlanTimeZone
    tags: union(baseTags, contains(tagsByResource, 'Microsoft.DesktopVirtualization/scalingPlans') ? tagsByResource['Microsoft.DesktopVirtualization/scalingPlans'] : {})
  }
  dependsOn: [hostPool]
}

// ── Outputs ──────────────────────────────────────────────────────────────────

output resourceGroupName string = resourceGroupName
output hostPoolId string = hostPool.outputs.hostPoolId
output appGroupId string = appGroup.outputs.appGroupId
output workspaceId string = workspace.outputs.workspaceId
output fslogixShareUNC string = deployFSLogix ? fslogix.outputs.profileShareUNC : ''
output avdPortalUrl string = 'https://aka.ms/avd'
