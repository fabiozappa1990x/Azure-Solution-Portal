targetScope = 'resourceGroup'

@description('Azure region (required by the configurationAssignments resource)')
param location string

@description('Maintenance Configuration resource ID')
param maintenanceConfigurationId string

@description('Target VM resource ID (must be in this resource group)')
param vmId string

@description('Configuration assignment name')
param assignmentName string

resource assignment 'Microsoft.Maintenance/configurationAssignments@2023-04-01' = {
  name: take(assignmentName, 64)
  location: location
  properties: {
    maintenanceConfigurationId: maintenanceConfigurationId
    resourceId: vmId
  }
}

output assignmentId string = assignment.id

