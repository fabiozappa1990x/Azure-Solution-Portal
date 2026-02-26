@description('Application Group name')
param appGroupName string

@description('Azure region')
param location string

@description('Host Pool Resource ID')
param hostPoolId string

@description('Application Group type: Desktop or RemoteApp')
@allowed(['Desktop', 'RemoteApp'])
param appGroupType string = 'Desktop'

@description('Friendly name shown to users')
param friendlyName string = ''

@description('Description')
param description string = ''

@description('Azure AD Group Object IDs to assign Users role')
param userGroupObjectIds array = []

@description('Log Analytics Workspace Resource ID for diagnostics')
param logAnalyticsWorkspaceId string = ''

@description('Resource tags')
param tags object = {}

var appGroupFriendlyName = empty(friendlyName) ? appGroupName : friendlyName

resource appGroup 'Microsoft.DesktopVirtualization/applicationGroups@2023-09-05' = {
  name: appGroupName
  location: location
  tags: tags
  properties: {
    hostPoolArmPath: hostPoolId
    applicationGroupType: appGroupType
    friendlyName: appGroupFriendlyName
    description: description
  }
}

resource userRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for groupId in userGroupObjectIds: {
  name: guid(appGroup.id, groupId, 'Desktop Virtualization User')
  scope: appGroup
  properties: {
    principalId: groupId
    principalType: 'Group'
    // Desktop Virtualization User role
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')
  }
}]

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'diag-${appGroupName}'
  scope: appGroup
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

output appGroupId string = appGroup.id
output appGroupName string = appGroup.name
