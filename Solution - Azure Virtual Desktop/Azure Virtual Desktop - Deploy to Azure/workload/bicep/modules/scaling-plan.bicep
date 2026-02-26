@description('Scaling Plan name')
param scalingPlanName string

@description('Azure region')
param location string

@description('Host Pool Resource ID to associate scaling plan with')
param hostPoolId string

@description('Timezone for schedule (e.g. W. Europe Standard Time)')
param timeZone string = 'W. Europe Standard Time'

@description('Friendly name')
param friendlyName string = ''

@description('Resource tags')
param tags object = {}

var scalingPlanFriendlyName = empty(friendlyName) ? scalingPlanName : friendlyName

resource scalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2023-09-05' = {
  name: scalingPlanName
  location: location
  tags: tags
  properties: {
    friendlyName: scalingPlanFriendlyName
    timeZone: timeZone
    hostPoolType: 'Pooled'
    hostPoolReferences: [
      {
        hostPoolArmPath: hostPoolId
        scalingPlanEnabled: true
      }
    ]
    schedules: [
      {
        name: 'Weekdays'
        daysOfWeek: ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday']
        rampUpStartTime: {
          hour: 7
          minute: 0
        }
        rampUpLoadBalancingAlgorithm: 'BreadthFirst'
        rampUpMinimumHostsPct: 20
        rampUpCapacityThresholdPct: 60
        peakStartTime: {
          hour: 9
          minute: 0
        }
        peakLoadBalancingAlgorithm: 'BreadthFirst'
        rampDownStartTime: {
          hour: 18
          minute: 0
        }
        rampDownLoadBalancingAlgorithm: 'DepthFirst'
        rampDownMinimumHostsPct: 0
        rampDownCapacityThresholdPct: 90
        rampDownWaitTimeMinutes: 30
        rampDownNotificationMessage: 'La sessione verrà terminata tra 30 minuti. Salva il tuo lavoro.'
        rampDownForceLogoffUsers: false
        rampDownStopHostsWhen: 'ZeroActiveSessions'
        offPeakStartTime: {
          hour: 20
          minute: 0
        }
        offPeakLoadBalancingAlgorithm: 'DepthFirst'
      }
    ]
  }
}

// Role assignment: Desktop Virtualization Power On Off Contributor for scaling plan managed identity
resource scalingPlanRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(scalingPlan.id, hostPoolId, 'Power On Off Contributor')
  scope: resourceGroup()
  properties: {
    principalId: scalingPlan.identity.principalId
    principalType: 'ServicePrincipal'
    // Desktop Virtualization Power On Off Contributor
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '40c5ff49-9181-41f8-ae61-143b0e78555e')
  }
}

output scalingPlanId string = scalingPlan.id
output scalingPlanName string = scalingPlan.name
