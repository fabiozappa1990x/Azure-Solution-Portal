targetScope = 'subscription'

@description('Deployment name prefix')
param deploymentName string

@description('Azure region')
param location string = deployment().location

@description('Use existing Resource Group')
param useExistingResourceGroup bool = false

@description('Existing Resource Group name')
param existingResourceGroupName string = ''

// ── Maintenance Window ────────────────────────────────────────────────────────

@description('Maintenance window start date-time (UTC, format: 2024-01-01 23:00)')
param maintenanceStartDateTime string = '2024-01-01 23:00'

@description('Maintenance window duration (ISO 8601, e.g. PT2H)')
param maintenanceDuration string = 'PT2H'

@description('Maintenance timezone')
param maintenanceTimeZone string = 'W. Europe Standard Time'

@description('Recurrence schedule')
@allowed(['Weekly', 'Monthly'])
param recurEvery string = 'Weekly'

@description('Day of week for weekly maintenance')
@allowed(['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'])
param dayOfWeek string = 'Sunday'

@description('Reboot behavior after patching')
@allowed(['IfRequired', 'Never', 'Always'])
param rebootSetting string = 'IfRequired'

// ── OS & Classifications ──────────────────────────────────────────────────────

@description('Target OS types')
@allowed(['Windows', 'Linux', 'Both'])
param osType string = 'Both'

@description('Windows update classifications to include')
param windowsClassifications array = ['Critical', 'Security', 'UpdateRollup']

@description('Linux update classifications to include')
param linuxClassifications array = ['Critical', 'Security']

// ── Automation ────────────────────────────────────────────────────────────────

@description('Assign policy for periodic assessment of available updates')
param enablePeriodicAssessmentPolicy bool = true

@description('Assign policy to auto-patch VMs with the maintenance config')
param enableAutoPatchingPolicy bool = true

// ── Monitoring ────────────────────────────────────────────────────────────────

@description('Log Analytics Workspace Resource ID for Update Manager diagnostics')
param logAnalyticsWorkspaceId string = ''

// ── Tags ──────────────────────────────────────────────────────────────────────

@description('Tags for resources')
param tagsByResource object = {}

// ─────────────────────────────────────────────────────────────────────────────

var resourceGroupName = useExistingResourceGroup ? existingResourceGroupName : 'rg-${deploymentName}'
var maintenanceConfigName = 'mc-${deploymentName}'

var baseTags = {
  DeployedBy: 'Azure-Solution-Portal'
  Solution: 'Azure-Update-Manager'
  ManagedBy: 'Bicep'
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = if (!useExistingResourceGroup) {
  name: resourceGroupName
  location: location
  tags: union(baseTags, contains(tagsByResource, 'Microsoft.Resources/resourceGroups') ? tagsByResource['Microsoft.Resources/resourceGroups'] : {})
}

resource existingRg 'Microsoft.Resources/resourceGroups@2024-03-01' existing = if (useExistingResourceGroup) {
  name: existingResourceGroupName
}

module maintenanceConfig 'modules/maintenance-configuration.bicep' = {
  name: 'deploy-maintenance-config'
  scope: useExistingResourceGroup ? existingRg : rg
  params: {
    configName: maintenanceConfigName
    location: location
    startDateTime: maintenanceStartDateTime
    duration: maintenanceDuration
    timeZone: maintenanceTimeZone
    recurEvery: recurEvery
    dayOfWeek: dayOfWeek
    osType: osType
    windowsClassifications: windowsClassifications
    linuxClassifications: linuxClassifications
    rebootSetting: rebootSetting
    tags: union(baseTags, contains(tagsByResource, 'Microsoft.Maintenance/maintenanceConfigurations') ? tagsByResource['Microsoft.Maintenance/maintenanceConfigurations'] : {})
  }
}

module updatePolicies 'modules/update-policies.bicep' = {
  name: 'deploy-update-policies'
  params: {
    policyNamePrefix: 'policy-${deploymentName}-update'
    location: location
    maintenanceConfigId: maintenanceConfig.outputs.maintenanceConfigId
    enablePeriodicAssessment: enablePeriodicAssessmentPolicy
    enableAutoPatching: enableAutoPatchingPolicy
  }
  dependsOn: [maintenanceConfig]
}

// ── Outputs ───────────────────────────────────────────────────────────────────

output resourceGroupName string = resourceGroupName
output maintenanceConfigId string = maintenanceConfig.outputs.maintenanceConfigId
output maintenanceConfigName string = maintenanceConfig.outputs.maintenanceConfigName
output updateManagerPortalUrl string = 'https://portal.azure.com/#view/Microsoft_Azure_Automation/UpdateCenterMenuBlade/~/overview'
