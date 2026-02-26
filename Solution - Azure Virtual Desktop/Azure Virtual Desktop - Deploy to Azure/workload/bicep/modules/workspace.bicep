@description('Workspace name')
param workspaceName string

@description('Azure region')
param location string

@description('Friendly name shown to users')
param friendlyName string = ''

@description('Description')
param description string = ''

@description('Application Group IDs to associate with this workspace')
param applicationGroupIds array = []

@description('Log Analytics Workspace Resource ID for diagnostics')
param logAnalyticsWorkspaceId string = ''

@description('Resource tags')
param tags object = {}

var workspaceFriendlyName = empty(friendlyName) ? workspaceName : friendlyName

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    friendlyName: workspaceFriendlyName
    description: description
    applicationGroupReferences: applicationGroupIds
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'diag-${workspaceName}'
  scope: workspace
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
