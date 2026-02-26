targetScope = 'subscription'

@description('Deployment name prefix')
param deploymentName string

@description('Azure region for the Recovery Services Vault')
param location string = deployment().location

@description('Use existing Resource Group')
param useExistingResourceGroup bool = false

@description('Existing Resource Group name')
param existingResourceGroupName string = ''

// ── Vault ─────────────────────────────────────────────────────────────────────

@description('Vault storage replication type')
@allowed(['GeoRedundant', 'LocallyRedundant', 'ZoneRedundant'])
param storageType string = 'GeoRedundant'

@description('Enable Cross Region Restore')
param enableCrossRegionRestore bool = false

@description('Enable soft delete')
param enableSoftDelete bool = true

@description('Soft delete retention in days')
@minValue(14)
@maxValue(180)
param softDeleteRetentionDays int = 14

// ── Policies ──────────────────────────────────────────────────────────────────

@description('Backup schedule time (UTC, e.g. 23:00)')
param backupTime string = '23:00'

@description('Daily retention in days')
@minValue(7)
@maxValue(9999)
param dailyRetentionDays int = 30

@description('Weekly retention in weeks')
param weeklyRetentionWeeks int = 12

@description('Monthly retention in months')
param monthlyRetentionMonths int = 12

@description('Yearly retention in years')
param yearlyRetentionYears int = 3

@description('Deploy Enhanced Policy (hourly backup)')
param deployEnhancedPolicy bool = true

@description('Deploy SQL Server backup policy')
param deploySqlPolicy bool = false

// ── VM Protection ─────────────────────────────────────────────────────────────

@description('VM Resource IDs to protect with backup')
param vmIdsToProtect array = []

@description('Enable Azure Policy for auto-protection of tagged VMs')
param enableBackupPolicy bool = true

@description('Tag key used to identify VMs for auto-protection')
param autoProtectTagKey string = 'BackupEnabled'

@description('Tag value used to identify VMs for auto-protection')
param autoProtectTagValue string = 'true'

// ── Monitoring ────────────────────────────────────────────────────────────────

@description('Log Analytics Workspace Resource ID for diagnostics')
param logAnalyticsWorkspaceId string = ''

@description('Email recipients for backup alerts (semicolon-separated)')
param alertEmailRecipients string = ''

// ── Tags ──────────────────────────────────────────────────────────────────────

@description('Tags for resources')
param tagsByResource object = {}

// ─────────────────────────────────────────────────────────────────────────────

var resourceGroupName = useExistingResourceGroup ? existingResourceGroupName : 'rg-${deploymentName}'
var vaultName = 'rsv-${deploymentName}'

var baseTags = {
  DeployedBy: 'Azure-Solution-Portal'
  Solution: 'Azure-Backup'
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

module vault 'modules/recovery-services-vault.bicep' = {
  name: 'deploy-rsv'
  scope: useExistingResourceGroup ? existingRg : rg
  params: {
    vaultName: vaultName
    location: location
    storageType: storageType
    enableCrossRegionRestore: enableCrossRegionRestore
    enableSoftDelete: enableSoftDelete
    softDeleteRetentionDays: softDeleteRetentionDays
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: union(baseTags, contains(tagsByResource, 'Microsoft.RecoveryServices/vaults') ? tagsByResource['Microsoft.RecoveryServices/vaults'] : {})
  }
}

module backupPolicies 'modules/backup-policies.bicep' = {
  name: 'deploy-backup-policies'
  scope: useExistingResourceGroup ? existingRg : rg
  params: {
    vaultName: vaultName
    policyNamePrefix: 'policy-${deploymentName}'
    backupTime: backupTime
    dailyRetentionDays: dailyRetentionDays
    weeklyRetentionWeeks: weeklyRetentionWeeks
    monthlyRetentionMonths: monthlyRetentionMonths
    yearlyRetentionYears: yearlyRetentionYears
    deployEnhancedPolicy: deployEnhancedPolicy
    deploySqlPolicy: deploySqlPolicy
  }
  dependsOn: [vault]
}

module vmProtection 'modules/vm-protection.bicep' = if (length(vmIdsToProtect) > 0) {
  name: 'deploy-vm-protection'
  scope: useExistingResourceGroup ? existingRg : rg
  params: {
    vaultName: vaultName
    backupPolicyId: backupPolicies.outputs.vmPolicyId
    vmIds: vmIdsToProtect
  }
  dependsOn: [backupPolicies]
}

// Azure Policy: auto-protect VMs with specific tag
module autoProtectPolicy 'modules/backup-auto-policy.bicep' = if (enableBackupPolicy) {
  name: 'deploy-backup-auto-policy'
  scope: subscription()
  params: {
    policyName: 'policy-${deploymentName}-backup-auto'
    vaultId: vault.outputs.vaultId
    backupPolicyId: backupPolicies.outputs.vmPolicyId
    tagKey: autoProtectTagKey
    tagValue: autoProtectTagValue
    location: location
  }
  dependsOn: [backupPolicies]
}

// ── Outputs ───────────────────────────────────────────────────────────────────

output resourceGroupName string = resourceGroupName
output vaultId string = vault.outputs.vaultId
output vaultName string = vault.outputs.vaultName
output vmPolicyId string = backupPolicies.outputs.vmPolicyId
output enhancedPolicyId string = backupPolicies.outputs.vmEnhancedPolicyId
output backupCenterUrl string = 'https://portal.azure.com/#blade/Microsoft_Azure_DataProtection/BackupCenterMenuBlade/overview'
