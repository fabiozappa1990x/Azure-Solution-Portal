@description('Recovery Services Vault name')
param vaultName string

@description('Azure region')
param location string

@description('Storage replication type')
@allowed(['GeoRedundant', 'LocallyRedundant', 'ZoneRedundant'])
param storageType string = 'GeoRedundant'

@description('Enable Cross Region Restore (requires GeoRedundant storage)')
param enableCrossRegionRestore bool = false

@description('Enable soft delete for backup items')
param enableSoftDelete bool = true

@description('Soft delete retention in days (14-180)')
@minValue(14)
@maxValue(180)
param softDeleteRetentionDays int = 14

@description('Enable immutability (Locked prevents changes)')
@allowed(['Disabled', 'Unlocked', 'Locked'])
param immutabilityState string = 'Disabled'

@description('Log Analytics Workspace Resource ID for diagnostics')
param logAnalyticsWorkspaceId string = ''

@description('Resource tags')
param tags object = {}

resource vault 'Microsoft.RecoveryServices/vaults@2024-04-01' = {
  name: vaultName
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
  }
}

resource vaultConfig 'Microsoft.RecoveryServices/vaults/backupconfig@2023-04-01' = {
  parent: vault
  name: 'vaultconfig'
  properties: {
    storageModelType: storageType
    crossRegionRestoreFlag: enableCrossRegionRestore && storageType == 'GeoRedundant'
    softDeleteFeatureState: enableSoftDelete ? 'Enabled' : 'Disabled'
    softDeleteRetentionPeriodInDays: softDeleteRetentionDays
    isSoftDeleteFeatureStateEditable: true
  }
}

resource vaultImmutability 'Microsoft.RecoveryServices/vaults/backupstorageconfig@2023-04-01' = if (immutabilityState != 'Disabled') {
  parent: vault
  name: 'vaultstorageconfig'
  properties: {
    storageModelType: storageType
    crossRegionRestoreFlag: enableCrossRegionRestore
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'diag-${vaultName}'
  scope: vault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'AzureBackupReport'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'CoreAzureBackup'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'AddonAzureBackupJobs'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'AddonAzureBackupAlerts'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'AddonAzureBackupPolicy'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'AddonAzureBackupStorage'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'AddonAzureBackupProtectedInstance'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
    metrics: [
      {
        category: 'Health'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
  }
}

output vaultId string = vault.id
output vaultName string = vault.name
output vaultPrincipalId string = vault.identity.principalId
