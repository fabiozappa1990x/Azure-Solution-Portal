@description('Host Pool name')
param hostPoolName string

@description('Azure region')
param location string

@description('Host Pool type: Pooled or Personal')
@allowed(['Pooled', 'Personal'])
param hostPoolType string = 'Pooled'

@description('Load balancer type for Pooled host pool')
@allowed(['BreadthFirst', 'DepthFirst'])
param loadBalancerType string = 'BreadthFirst'

@description('Max session limit per session host (Pooled only)')
param maxSessionLimit int = 10

@description('Enable Start VM on Connect')
param startVMOnConnect bool = true

@description('Friendly name shown to users')
param friendlyName string = ''

@description('Description')
param description string = ''

@description('Preferred app group type')
@allowed(['Desktop', 'RailApplications'])
param preferredAppGroupType string = 'Desktop'

@description('Enable validation environment')
param validationEnvironment bool = false

@description('Log Analytics Workspace Resource ID for diagnostics')
param logAnalyticsWorkspaceId string = ''

@description('Resource tags')
param tags object = {}

var hostPoolFriendlyName = empty(friendlyName) ? hostPoolName : friendlyName

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' = {
  name: hostPoolName
  location: location
  tags: tags
  properties: {
    hostPoolType: hostPoolType
    loadBalancerType: hostPoolType == 'Pooled' ? loadBalancerType : 'Persistent'
    maxSessionLimit: hostPoolType == 'Pooled' ? maxSessionLimit : 1
    startVMOnConnect: startVMOnConnect
    friendlyName: hostPoolFriendlyName
    description: description
    preferredAppGroupType: preferredAppGroupType
    validationEnvironment: validationEnvironment
    customRdpProperty: 'audiocapturemode:i:1;audiomode:i:0;drivestoredirect:s:*;redirectclipboard:i:1;redirectcomports:i:1;redirectprinters:i:1;redirectsmartcards:i:1;screen mode id:i:2;'
    registrationInfo: {
      expirationTime: dateTimeAdd(utcNow(), 'PT2H')
      registrationTokenOperation: 'Update'
    }
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'diag-${hostPoolName}'
  scope: hostPool
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
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
  }
}

output hostPoolId string = hostPool.id
output hostPoolName string = hostPool.name
output registrationToken string = hostPool.properties.registrationInfo.token
