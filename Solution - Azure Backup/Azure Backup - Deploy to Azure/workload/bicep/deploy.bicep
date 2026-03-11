targetScope = 'subscription'

@description('Deployment name prefix')
param deploymentName string

@description('Azure region for the Recovery Services Vault')
param location string = deployment().location

@description('Use existing Resource Group')
param useExistingResourceGroup bool = false

@description('Existing Resource Group name')
param existingResourceGroupName string = ''

// ── Vault selection ───────────────────────────────────────────────────────────

@description('Use an existing Recovery Services Vault')
param useExistingVault bool = false

@description('Existing Recovery Services Vault resource ID (required if useExistingVault = true)')
param existingVaultResourceId string = ''

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

// ── Azure Files Protection ────────────────────────────────────────────────────

@description('Enable backup for Azure File Shares (single Storage Account)')
param enableAzureFileShareBackup bool = false

@description('Storage Account resource ID hosting the file shares (required if enableAzureFileShareBackup = true)')
param fileShareStorageAccountId string = ''

@description('File share names to protect (comma-separated in UI, array in template)')
param fileShareNames array = []

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
var vaultName = useExistingVault ? last(split(existingVaultResourceId, '/')) : 'rsv-${deploymentName}'
var vaultResourceGroupName = useExistingVault ? split(existingVaultResourceId, '/')[4] : resourceGroupName

var baseTags = {
  DeployedBy: 'Azure-Solution-Portal'
  Solution: 'Azure-Backup'
  ManagedBy: 'Bicep'
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = if (!useExistingVault && !useExistingResourceGroup) {
  name: resourceGroupName
  location: location
  tags: union(baseTags, contains(tagsByResource, 'Microsoft.Resources/resourceGroups') ? tagsByResource['Microsoft.Resources/resourceGroups'] : {})
}

module vault 'modules/recovery-services-vault.bicep' = if (!useExistingVault) {
  name: 'deploy-rsv'
  scope: resourceGroup(resourceGroupName)
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
  scope: resourceGroup(vaultResourceGroupName)
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
    deployFileSharePolicy: enableAzureFileShareBackup
  }
  dependsOn: [
    vault
  ]
}

module vmProtection 'modules/vm-protection.bicep' = if (length(vmIdsToProtect) > 0) {
  name: 'deploy-vm-protection'
  scope: resourceGroup(vaultResourceGroupName)
  params: {
    vaultName: vaultName
    backupPolicyId: backupPolicies.outputs.vmPolicyId
    vmIds: vmIdsToProtect
  }
  dependsOn: [backupPolicies]
}

module fileShareProtection 'modules/file-share-protection.bicep' = if (enableAzureFileShareBackup && !empty(fileShareStorageAccountId) && length(fileShareNames) > 0) {
  name: 'deploy-file-share-protection'
  scope: resourceGroup(vaultResourceGroupName)
  params: {
    vaultName: vaultName
    backupPolicyId: backupPolicies.outputs.fileSharePolicyId
    storageAccountId: fileShareStorageAccountId
    fileShareNames: fileShareNames
  }
  dependsOn: [backupPolicies]
}

// Azure Policy: auto-protect VMs with specific tag
module autoProtectPolicy 'modules/backup-auto-policy.bicep' = if (enableBackupPolicy) {
  name: 'deploy-backup-auto-policy'
  scope: subscription()
  params: {
    policyName: 'policy-${deploymentName}-backup-auto'
    backupPolicyId: backupPolicies.outputs.vmPolicyId
    tagKey: autoProtectTagKey
    tagValue: autoProtectTagValue
    location: location
  }
  dependsOn: [backupPolicies]
}

// ── Outputs ───────────────────────────────────────────────────────────────────

output resourceGroupName string = vaultResourceGroupName
output vaultId string = useExistingVault ? existingVaultResourceId : vault.outputs.vaultId
output vaultName string = vaultName
output vmPolicyId string = backupPolicies.outputs.vmPolicyId
output enhancedPolicyId string = backupPolicies.outputs.vmEnhancedPolicyId
output backupCenterUrl string = 'https://portal.azure.com/#blade/Microsoft_Azure_DataProtection/BackupCenterMenuBlade/overview'
