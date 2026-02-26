@description('Recovery Services Vault name')
param vaultName string

@description('Backup Policy Resource ID')
param backupPolicyId string

@description('Array of VM Resource IDs to protect')
param vmIds array = []

resource existingVault 'Microsoft.RecoveryServices/vaults@2024-04-01' existing = {
  name: vaultName
}

// Protect each VM with the specified backup policy
resource vmProtection 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2023-04-01' = [for vmId in vmIds: {
  name: '${vaultName}/Azure/iaasvmcontainer;iaasvmcontainerv2;${split(vmId, '/')[4]};${last(split(vmId, '/'))}/vm;iaasvmcontainerv2;${split(vmId, '/')[4]};${last(split(vmId, '/'))}'
  location: existingVault.location
  properties: {
    protectedItemType: 'Microsoft.Compute/virtualMachines'
    policyId: backupPolicyId
    sourceResourceId: vmId
  }
}]

output protectedItemCount int = length(vmIds)
