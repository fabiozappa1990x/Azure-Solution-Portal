@description('Recovery Services Vault name')
param vaultName string

@description('Backup Policy Resource ID for Azure File Shares')
param backupPolicyId string

@description('Storage Account resource ID hosting the file shares')
param storageAccountId string

@description('File share names to protect')
param fileShareNames array = []

var storageAccountName = last(split(storageAccountId, '/'))
var storageAccountRgName = split(storageAccountId, '/')[4]

// Register the Storage Account as a protection container in the vault
resource protectionContainer 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers@2024-04-01' = {
  name: '${vaultName}/Azure/storagecontainer;Storage;${storageAccountRgName};${storageAccountName}'
  properties: {
    backupManagementType: 'AzureStorage'
    containerType: 'StorageContainer'
    sourceResourceId: storageAccountId
  }
}

// Protect each File Share with the specified policy
resource fileShareProtectedItems 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2024-04-01' = [for shareName in fileShareNames: {
  parent: protectionContainer
  name: 'AzureFileShare;${shareName}'
  properties: {
    protectedItemType: 'AzureFileShareProtectedItem'
    sourceResourceId: storageAccountId
    policyId: backupPolicyId
  }
}]

output protectedItemCount int = length(fileShareNames)
