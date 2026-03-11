@description('Recovery Services Vault name')
param vaultName string

@description('Backup policy name prefix')
param policyNamePrefix string

@description('VM backup schedule time (UTC, 24h format, e.g. 23:00)')
param backupTime string = '23:00'

@description('VM backup frequency')
@allowed(['Daily', 'Weekly'])
param backupFrequency string = 'Daily'

@description('Days of week for weekly backup')
param daysOfWeek array = ['Sunday']

@description('Daily backup retention days')
@minValue(7)
@maxValue(9999)
param dailyRetentionDays int = 30

@description('Weekly backup retention weeks')
@minValue(1)
@maxValue(5163)
param weeklyRetentionWeeks int = 12

@description('Monthly backup retention months')
@minValue(1)
@maxValue(1188)
param monthlyRetentionMonths int = 12

@description('Yearly backup retention years')
@minValue(1)
@maxValue(99)
param yearlyRetentionYears int = 3

@description('Enable instant restore snapshot retention (days)')
@minValue(1)
@maxValue(5)
param instantRestoreRetentionDays int = 2

@description('Deploy an Enhanced Policy (supports Trusted Azure VMs and full disk backup)')
param deployEnhancedPolicy bool = true

@description('Deploy SQL Server in VM backup policy')
param deploySqlPolicy bool = false

@description('Deploy Azure File Share backup policy')
param deployFileSharePolicy bool = false

resource existingVault 'Microsoft.RecoveryServices/vaults@2024-04-01' existing = {
  name: vaultName
}

var backupTimeArray = split(backupTime, ':')
var backupHour = int(backupTimeArray[0])
var backupMinute = int(backupTimeArray[1])

// Standard VM Backup Policy (Azure VM)
resource vmBackupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2024-04-01' = {
  parent: existingVault
  name: '${policyNamePrefix}-vm-standard'
  properties: {
    backupManagementType: 'AzureIaasVM'
    instantRPDetails: {
      azureBackupRGNamePrefix: 'rg-backup-snapshots'
      azureBackupRGNameSuffix: ''
    }
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: backupFrequency
      scheduleRunTimes: [
        '2024-01-01T${padLeft(string(backupHour), 2, '0')}:${padLeft(string(backupMinute), 2, '0')}:00Z'
      ]
      scheduleRunDays: backupFrequency == 'Weekly' ? daysOfWeek : null
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: [
          '2024-01-01T${padLeft(string(backupHour), 2, '0')}:${padLeft(string(backupMinute), 2, '0')}:00Z'
        ]
        retentionDuration: {
          count: dailyRetentionDays
          durationType: 'Days'
        }
      }
      weeklySchedule: {
        daysOfTheWeek: [daysOfWeek[0]]
        retentionTimes: [
          '2024-01-01T${padLeft(string(backupHour), 2, '0')}:${padLeft(string(backupMinute), 2, '0')}:00Z'
        ]
        retentionDuration: {
          count: weeklyRetentionWeeks
          durationType: 'Weeks'
        }
      }
      monthlySchedule: {
        retentionScheduleFormatType: 'Daily'
        retentionScheduleDaily: {
          daysOfTheMonth: [{ date: 1, isLast: false }]
        }
        retentionTimes: [
          '2024-01-01T${padLeft(string(backupHour), 2, '0')}:${padLeft(string(backupMinute), 2, '0')}:00Z'
        ]
        retentionDuration: {
          count: monthlyRetentionMonths
          durationType: 'Months'
        }
      }
      yearlySchedule: {
        retentionScheduleFormatType: 'Daily'
        monthsOfYear: ['January']
        retentionScheduleDaily: {
          daysOfTheMonth: [{ date: 1, isLast: false }]
        }
        retentionTimes: [
          '2024-01-01T${padLeft(string(backupHour), 2, '0')}:${padLeft(string(backupMinute), 2, '0')}:00Z'
        ]
        retentionDuration: {
          count: yearlyRetentionYears
          durationType: 'Years'
        }
      }
    }
    instantRpRetentionRangeInDays: instantRestoreRetentionDays
    tieringPolicy: {
      ArchivedRP: {
        tieringMode: 'DoNotTier'
        duration: 0
        durationType: 'Invalid'
      }
    }
    policyType: 'V1'
  }
}

// Enhanced VM Backup Policy (supports Trusted Azure VMs, selective disk backup)
resource vmEnhancedPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2024-04-01' = if (deployEnhancedPolicy) {
  parent: existingVault
  name: '${policyNamePrefix}-vm-enhanced'
  properties: {
    backupManagementType: 'AzureIaasVM'
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicyV2'
      scheduleRunFrequency: 'Hourly'
      hourlySchedule: {
        interval: 4
        scheduleWindowStartTime: '2024-01-01T08:00:00Z'
        scheduleWindowDuration: 16
      }
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: ['2024-01-01T23:00:00Z']
        retentionDuration: {
          count: dailyRetentionDays
          durationType: 'Days'
        }
      }
      weeklySchedule: {
        daysOfTheWeek: [daysOfWeek[0]]
        retentionTimes: ['2024-01-01T23:00:00Z']
        retentionDuration: {
          count: weeklyRetentionWeeks
          durationType: 'Weeks'
        }
      }
      monthlySchedule: {
        retentionScheduleFormatType: 'Daily'
        retentionScheduleDaily: {
          daysOfTheMonth: [{ date: 1, isLast: false }]
        }
        retentionTimes: ['2024-01-01T23:00:00Z']
        retentionDuration: {
          count: monthlyRetentionMonths
          durationType: 'Months'
        }
      }
    }
    instantRpRetentionRangeInDays: instantRestoreRetentionDays
    policyType: 'V2'
  }
}

// SQL Server in Azure VM backup policy
resource sqlBackupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2024-04-01' = if (deploySqlPolicy) {
  parent: existingVault
  name: '${policyNamePrefix}-sql'
  properties: {
    backupManagementType: 'AzureWorkload'
    workLoadType: 'SQLDataBase'
    subProtectionPolicy: [
      {
        policyType: 'Full'
        schedulePolicy: {
          schedulePolicyType: 'SimpleSchedulePolicy'
          scheduleRunFrequency: 'Weekly'
          scheduleRunDays: daysOfWeek
          scheduleRunTimes: ['2024-01-01T23:00:00Z']
        }
        retentionPolicy: {
          retentionPolicyType: 'LongTermRetentionPolicy'
          weeklySchedule: {
            daysOfTheWeek: [daysOfWeek[0]]
            retentionTimes: ['2024-01-01T23:00:00Z']
            retentionDuration: {
              count: weeklyRetentionWeeks
              durationType: 'Weeks'
            }
          }
          monthlySchedule: {
            retentionScheduleFormatType: 'Weekly'
            retentionScheduleWeekly: {
              daysOfTheWeek: [daysOfWeek[0]]
              weeksOfTheMonth: ['First']
            }
            retentionTimes: ['2024-01-01T23:00:00Z']
            retentionDuration: {
              count: monthlyRetentionMonths
              durationType: 'Months'
            }
          }
        }
      }
      {
        policyType: 'Log'
        schedulePolicy: {
          schedulePolicyType: 'LogSchedulePolicy'
          scheduleFrequencyInMins: 60
        }
        retentionPolicy: {
          retentionPolicyType: 'SimpleRetentionPolicy'
          retentionDuration: {
            count: 15
            durationType: 'Days'
          }
        }
      }
    ]
    settings: {
      timeZone: 'UTC'
      isCompression: false
      issqlcompression: false
    }
  }
}

// Azure File Share backup policy (AzureStorage)
resource fileShareBackupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2024-04-01' = if (deployFileSharePolicy) {
  parent: existingVault
  name: '${policyNamePrefix}-afs'
  properties: {
    backupManagementType: 'AzureStorage'
    workLoadType: 'AzureFileShare'
    timeZone: 'UTC'
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      scheduleRunTimes: [
        '2024-01-01T${padLeft(string(backupHour), 2, '0')}:${padLeft(string(backupMinute), 2, '0')}:00Z'
      ]
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: [
          '2024-01-01T${padLeft(string(backupHour), 2, '0')}:${padLeft(string(backupMinute), 2, '0')}:00Z'
        ]
        retentionDuration: {
          count: dailyRetentionDays
          durationType: 'Days'
        }
      }
    }
  }
}

output vmPolicyId string = vmBackupPolicy.id
output vmEnhancedPolicyId string = deployEnhancedPolicy ? vmEnhancedPolicy.id : ''
output sqlPolicyId string = deploySqlPolicy ? sqlBackupPolicy.id : ''
output fileSharePolicyId string = deployFileSharePolicy ? fileShareBackupPolicy.id : ''
