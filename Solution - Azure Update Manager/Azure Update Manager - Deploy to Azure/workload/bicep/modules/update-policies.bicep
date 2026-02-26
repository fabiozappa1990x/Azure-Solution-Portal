targetScope = 'subscription'

@description('Policy assignment name prefix')
param policyNamePrefix string

@description('Azure region for policy assignment identity')
param location string

@description('Maintenance Configuration Resource ID')
param maintenanceConfigId string

@description('Assign policy to periodically check for missing updates (assessment)')
param enablePeriodicAssessment bool = true

@description('Assign policy to automatically apply updates via maintenance config')
param enableAutoPatching bool = true

var assessmentPolicyDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/59efceea-0c96-497e-a4a1-4eb2290dac15'
var autoPatchPolicyDefinitionId  = '/providers/Microsoft.Authorization/policyDefinitions/ba0df93e-e4ac-479a-aac2-134bbae39a1a'

// Policy: Enable periodic assessment for VM updates
resource assessmentPolicy 'Microsoft.Authorization/policyAssignments@2023-04-01' = if (enablePeriodicAssessment) {
  name: take('${policyNamePrefix}-assess', 64)
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'Abilita valutazione periodica aggiornamenti VM'
    description: 'Configura le VM per la valutazione automatica e periodica degli aggiornamenti disponibili'
    policyDefinitionId: assessmentPolicyDefinitionId
    enforcementMode: 'Default'
    parameters: {}
  }
}

// Policy: Schedule updates via Maintenance Configuration
resource autoPatchPolicy 'Microsoft.Authorization/policyAssignments@2023-04-01' = if (enableAutoPatching) {
  name: take('${policyNamePrefix}-patch', 64)
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'Pianifica aggiornamenti VM con Azure Update Manager'
    description: 'Associa le VM alla Maintenance Configuration per il patching automatico'
    policyDefinitionId: autoPatchPolicyDefinitionId
    enforcementMode: 'Default'
    parameters: {
      maintenanceConfigurationResourceId: {
        value: maintenanceConfigId
      }
    }
  }
}

// Contributor role for assessment policy identity
resource assessmentRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enablePeriodicAssessment) {
  name: guid(assessmentPolicy.id, subscription().id, 'Contributor')
  properties: {
    principalId: assessmentPolicy.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
  }
}

// Contributor role for auto-patch policy identity
resource patchRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableAutoPatching) {
  name: guid(autoPatchPolicy.id, subscription().id, 'Contributor')
  properties: {
    principalId: autoPatchPolicy.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
  }
}

output assessmentPolicyId string = enablePeriodicAssessment ? assessmentPolicy.id : ''
output autoPatchPolicyId string = enableAutoPatching ? autoPatchPolicy.id : ''
