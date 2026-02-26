@description('Maintenance Configuration name')
param configName string

@description('Azure region')
param location string

@description('Maintenance window start date-time (UTC, format: 2024-01-01 23:00)')
param startDateTime string = '2024-01-01 23:00'

@description('Maintenance window duration (ISO 8601, e.g. PT2H = 2 hours)')
param duration string = 'PT2H'

@description('Maintenance window timezone')
param timeZone string = 'W. Europe Standard Time'

@description('Recurrence: Daily, Weekly, Monthly')
@allowed(['Daily', 'Weekly', 'Monthly'])
param recurEvery string = 'Weekly'

@description('Day of week for weekly maintenance (e.g. Sunday)')
param dayOfWeek string = 'Sunday'

@description('Week of month for monthly maintenance (First, Second, Third, Fourth, Last)')
@allowed(['First', 'Second', 'Third', 'Fourth', 'Last'])
param weekOfMonth string = 'Second'

@description('Day of month for monthly maintenance (1-28, or use weekOfMonth+dayOfWeek)')
param useWeeklyOccurrence bool = true

@description('OS types to update: Windows, Linux, or Both')
@allowed(['Windows', 'Linux', 'Both'])
param osType string = 'Both'

@description('Update classifications for Windows')
param windowsClassifications array = ['Critical', 'Security', 'UpdateRollup', 'FeaturePack', 'ServicePack', 'Definition', 'Tools', 'Updates']

@description('Update classifications for Linux')
param linuxClassifications array = ['Critical', 'Security', 'Other']

@description('KBIDs to exclude from Windows updates (optional)')
param windowsExcludeKbIds array = []

@description('Package name-masks to exclude from Linux updates (optional)')
param linuxExcludePackages array = []

@description('Reboot setting after update')
@allowed(['IfRequired', 'Never', 'Always'])
param rebootSetting string = 'IfRequired'

@description('Resource tags')
param tags object = {}

var recurrenceExpression = recurEvery == 'Daily' ? '1Day' : (recurEvery == 'Weekly' ? '1Week ${dayOfWeek}' : (useWeeklyOccurrence ? '1Month ${weekOfMonth} ${dayOfWeek}' : '1Month'))

resource maintenanceConfig 'Microsoft.Maintenance/maintenanceConfigurations@2023-09-01-preview' = {
  name: configName
  location: location
  tags: tags
  properties: {
    maintenanceScope: 'InGuestPatch'
    maintenanceWindow: {
      startDateTime: startDateTime
      duration: duration
      timeZone: timeZone
      recurEvery: recurrenceExpression
      expirationDateTime: null
    }
    installPatches: {
      rebootSetting: rebootSetting
      windowsParameters: osType != 'Linux' ? {
        classificationsToInclude: windowsClassifications
        kbNumbersToExclude: windowsExcludeKbIds
        kbNumbersToInclude: []
      } : null
      linuxParameters: osType != 'Windows' ? {
        classificationsToInclude: linuxClassifications
        packageNameMasksToExclude: linuxExcludePackages
        packageNameMasksToInclude: []
      } : null
    }
    visibility: 'Custom'
    namespace: 'Microsoft.Maintenance'
    extensionProperties: {}
  }
}

output maintenanceConfigId string = maintenanceConfig.id
output maintenanceConfigName string = maintenanceConfig.name
