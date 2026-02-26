targetScope = 'subscription'

@description('Security contact email addresses (semicolon-separated)')
param emailRecipients string

@description('Security contact phone (optional)')
param phone string = ''

@description('Send notifications for high severity alerts')
param alertNotificationsHighSeverity bool = true

@description('Send notifications for medium severity alerts')
param alertNotificationsMediumSeverity bool = true

@description('Notify subscription owners')
param notifySubscriptionOwners bool = true

@description('Enable auto-provisioning of Microsoft Defender for Endpoint (MDE)')
param enableMDEAutoProvisioning bool = true

@description('Enable auto-provisioning of Azure Monitor Agent via Defender')
param enableAMAAutoProvisioning bool = true

@description('Log Analytics Workspace Resource ID for MDE data (optional)')
param mdeWorkspaceId string = ''

var emailList = filter(split(emailRecipients, ';'), e => !empty(trim(e)))

resource securityContact 'Microsoft.Security/securityContacts@2023-12-01-preview' = {
  name: 'default'
  properties: {
    emails: join(emailList, ';')
    phone: phone
    notificationsByRole: {
      state: notifySubscriptionOwners ? 'On' : 'Off'
      roles: notifySubscriptionOwners ? ['Owner', 'Contributor'] : []
    }
    alertNotifications: {
      state: 'On'
      minimalSeverity: alertNotificationsHighSeverity ? (alertNotificationsMediumSeverity ? 'Medium' : 'High') : 'High'
    }
  }
}

// Auto-provisioning: Microsoft Defender for Endpoint (MDE)
resource mdeAutoProvisioning 'Microsoft.Security/autoProvisioningSettings@2017-08-01-preview' = if (enableMDEAutoProvisioning) {
  name: 'MicrosoftDefenderForEndpoint'
  properties: {
    autoProvision: 'On'
  }
}

// Auto-provisioning: Azure Monitor Agent (via Defender)
resource amaAutoProvisioning 'Microsoft.Security/autoProvisioningSettings@2017-08-01-preview' = if (enableAMAAutoProvisioning) {
  name: 'MicrosoftMonitoringAgent'
  properties: {
    autoProvision: 'On'
  }
}

output securityContactId string = securityContact.id
