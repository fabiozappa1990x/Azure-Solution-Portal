targetScope = 'subscription'

@description('Policy assignment name')
param policyName string

@description('Recovery Services Vault Resource ID')
param vaultId string

@description('Backup Policy Resource ID')
param backupPolicyId string

@description('Tag key to identify VMs for auto-protection')
param tagKey string = 'BackupEnabled'

@description('Tag value to identify VMs for auto-protection')
param tagValue string = 'true'

@description('Azure region for policy assignment identity')
param location string

// Built-in policy: Configure backup on VMs with a given tag
// Policy definition ID: 09ce66bc-1220-4153-8171-b09ce908e8ee
var configureBackupPolicyDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/09ce66bc-1220-4153-8171-b09ce908e8ee'

resource policyAssignment 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: take(policyName, 64)
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'Auto-protezione VM con Azure Backup'
    description: 'Abilita automaticamente il backup per le VM con il tag ${tagKey}=${tagValue}'
    policyDefinitionId: configureBackupPolicyDefinitionId
    parameters: {
      vaultLocation: {
        value: location
      }
      inclusionTagName: {
        value: tagKey
      }
      inclusionTagValue: {
        value: [tagValue]
      }
      backupPolicyId: {
        value: backupPolicyId
      }
    }
    enforcementMode: 'Default'
  }
}

// Contributor role for the policy assignment identity to deploy backup
resource contributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(policyAssignment.id, subscription().id, 'Contributor')
  properties: {
    principalId: policyAssignment.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
  }
}

output policyAssignmentId string = policyAssignment.id
