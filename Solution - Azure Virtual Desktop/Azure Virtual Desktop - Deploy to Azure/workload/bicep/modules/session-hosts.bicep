@description('Name prefix for session hosts (e.g. avd-host)')
param namePrefix string

@description('Azure region')
param location string

@description('Number of session hosts to deploy')
@minValue(1)
@maxValue(50)
param count int = 2

@description('VM size')
param vmSize string = 'Standard_D4s_v5'

@description('OS disk type')
@allowed(['Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS'])
param osDiskType string = 'Premium_LRS'

@description('AVD image reference (marketplace)')
param imagePublisher string = 'MicrosoftWindowsDesktop'
param imageOffer string = 'windows-11'
param imageSku string = 'win11-23h2-avd'
param imageVersion string = 'latest'

@description('Local admin username')
param adminUsername string

@description('Local admin password')
@secure()
param adminPassword string

@description('Virtual Network Resource ID')
param vnetId string

@description('Subnet name for session hosts')
param subnetName string

@description('Host Pool name (for registration)')
param hostPoolName string

@description('Host Pool registration token')
@secure()
param registrationToken string

@description('Domain to join (leave empty for Azure AD join)')
param domainToJoin string = ''

@description('Domain join UPN (required if domainToJoin is set)')
param domainJoinUser string = ''

@description('Domain join password (required if domainToJoin is set)')
@secure()
param domainJoinPassword string = ''

@description('OU path for domain join (optional)')
param ouPath string = ''

@description('Enable Intune enrollment (Azure AD join only)')
param intuneEnrollment bool = false

@description('Log Analytics Workspace Resource ID for AMA')
param logAnalyticsWorkspaceId string = ''

@description('Resource tags')
param tags object = {}

var subnetId = '${vnetId}/subnets/${subnetName}'
var isDomainJoin = !empty(domainToJoin)

resource nics 'Microsoft.Network/networkInterfaces@2023-11-01' = [for i in range(0, count): {
  name: 'nic-${namePrefix}-${padLeft(i + 1, 2, '0')}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
    enableAcceleratedNetworking: true
  }
}]

resource sessionHosts 'Microsoft.Compute/virtualMachines@2024-03-01' = [for i in range(0, count): {
  name: '${namePrefix}-${padLeft(i + 1, 2, '0')}'
  location: location
  tags: union(tags, { HostPool: hostPoolName })
  identity: {
    type: isDomainJoin ? 'SystemAssigned' : 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 128
        managedDisk: {
          storageAccountType: osDiskType
        }
        deleteOption: 'Delete'
      }
      imageReference: {
        publisher: imagePublisher
        offer: imageOffer
        sku: imageSku
        version: imageVersion
      }
    }
    osProfile: {
      computerName: '${namePrefix}-${padLeft(i + 1, 2, '0')}'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: false
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          automaticByPlatformSettings: {
            rebootSetting: 'IfRequired'
          }
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nics[i].id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    licenseType: 'Windows_Client'
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
  dependsOn: [nics]
}]

// Domain join extension (if domain join is configured)
resource domainJoinExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = [for i in range(0, count): if (isDomainJoin) {
  name: 'JsonADDomainExtension'
  parent: sessionHosts[i]
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      name: domainToJoin
      ouPath: ouPath
      user: domainJoinUser
      restart: true
      options: '3'
    }
    protectedSettings: {
      password: domainJoinPassword
    }
  }
}]

// Azure AD Join extension (if no domain join)
resource aadJoinExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = [for i in range(0, count): if (!isDomainJoin) {
  name: 'AADLoginForWindows'
  parent: sessionHosts[i]
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
    settings: intuneEnrollment ? {
      mdmId: '0000000a-0000-0000-c000-000000000000'
    } : {}
  }
}]

// AVD Agent extension
resource avdAgentExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = [for i in range(0, count): {
  name: 'DSC'
  parent: sessionHosts[i]
  location: location
  dependsOn: isDomainJoin ? [domainJoinExtension[i]] : [aadJoinExtension[i]]
  properties: {
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: '2.73'
    autoUpgradeMinorVersion: true
    settings: {
      modulesUrl: 'https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_1.0.02714.342.zip'
      configurationFunction: 'Configuration.ps1\\AddSessionHost'
      properties: {
        HostPoolName: hostPoolName
        RegistrationInfoTokenCredential: {
          UserName: 'PLACEHOLDER_DO_NOT_USE'
          Password: 'PrivateSettingsRef:RegistrationInfoToken'
        }
        aadJoin: !isDomainJoin
      }
    }
    protectedSettings: {
      items: {
        RegistrationInfoToken: registrationToken
      }
    }
  }
}]

// Azure Monitor Agent extension (if workspace ID provided)
resource amaExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = [for i in range(0, count): if (!empty(logAnalyticsWorkspaceId)) {
  name: 'AzureMonitorWindowsAgent'
  parent: sessionHosts[i]
  location: location
  dependsOn: [avdAgentExtension[i]]
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.22'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}]

output sessionHostIds array = [for i in range(0, count): sessionHosts[i].id]
output sessionHostNames array = [for i in range(0, count): sessionHosts[i].name]
