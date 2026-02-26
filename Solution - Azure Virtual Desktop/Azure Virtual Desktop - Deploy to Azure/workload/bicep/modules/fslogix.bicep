@description('Storage Account name for FSLogix profiles (must be globally unique)')
param storageAccountName string

@description('Azure region')
param location string

@description('Azure Files share name for FSLogix profiles')
param profileShareName string = 'fslogix-profiles'

@description('Azure Files share quota in GB')
@minValue(100)
@maxValue(102400)
param shareQuotaGB int = 512

@description('Storage SKU for Azure Files')
@allowed(['Premium_LRS', 'Premium_ZRS', 'Standard_LRS', 'Standard_GRS', 'Standard_ZRS'])
param storageSku string = 'Premium_LRS'

@description('Azure AD Group Object IDs to assign Storage File Data SMB Share Contributor')
param userGroupObjectIds array = []

@description('Enable Private Endpoint for storage')
param enablePrivateEndpoint bool = false

@description('Subnet Resource ID for Private Endpoint (required if enablePrivateEndpoint is true)')
param privateEndpointSubnetId string = ''

@description('Resource tags')
param tags object = {}

var isPremium = startsWith(storageSku, 'Premium')
var storageKind = isPremium ? 'FileStorage' : 'StorageV2'
var storageAccessTier = isPremium ? 'Hot' : 'Hot'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-04-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: storageKind
  sku: {
    name: storageSku
  }
  properties: {
    accessTier: storageAccessTier
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    largeFileSharesState: isPremium ? null : 'Enabled'
    networkAcls: enablePrivateEndpoint ? {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    } : {
      defaultAction: 'Allow'
    }
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'AADKERB'
    }
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-04-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource profileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-04-01' = {
  parent: fileService
  name: profileShareName
  properties: {
    shareQuota: shareQuotaGB
    enabledProtocols: 'SMB'
    accessTier: isPremium ? 'Premium' : 'Hot'
  }
}

// Storage File Data SMB Share Contributor role for user groups
resource smb_contributor_role 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for groupId in userGroupObjectIds: {
  name: guid(storageAccount.id, groupId, 'SMB Share Contributor')
  scope: storageAccount
  properties: {
    principalId: groupId
    principalType: 'Group'
    // Storage File Data SMB Share Contributor
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb')
  }
}]

// Storage File Data SMB Share Elevated Contributor for the share itself
resource smb_elevated_role 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for groupId in userGroupObjectIds: {
  name: guid(storageAccount.id, groupId, 'SMB Share Elevated Contributor')
  scope: storageAccount
  properties: {
    principalId: groupId
    principalType: 'Group'
    // Storage File Data SMB Share Elevated Contributor
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a7264617-510b-434b-a828-9731dc254ea7')
  }
}]

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = if (enablePrivateEndpoint && !empty(privateEndpointSubnetId)) {
  name: 'pe-${storageAccountName}-file'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-${storageAccountName}-file'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: ['file']
        }
      }
    ]
  }
}

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output profileShareName string = profileShare.name
output profileShareUNC string = '\\\\${storageAccount.name}.file.core.windows.net\\${profileShareName}'
output storageAccountKey string = storageAccount.listKeys().keys[0].value
