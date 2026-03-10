@description('Workbook display name')
param workbookName string

@description('Azure region')
param location string

@description('Log Analytics Workspace Resource ID')
param workspaceResourceId string

@description('Resource tags')
param tags object = {}

var workbookId = guid(workbookName, resourceGroup().id)

var workbookContent = loadTextContent('../workbooks/vm-monitoring.workbook.json')

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookId
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: workbookName
    serializedData: workbookContent
    version: '1.0'
    sourceId: workspaceResourceId
    category: 'Azure Monitor'
  }
}

output workbookId string = workbook.id
output workbookName string = workbook.name
output workbookUrl string = 'https://portal.azure.com/#blade/AppInsightsExtension/UsageNotebookBlade/ComponentId/subscribers/${workbook.id}'
