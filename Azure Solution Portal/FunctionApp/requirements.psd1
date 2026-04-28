@{
    'Az.Accounts' = '3.*'
    'Az.Resources' = '7.*'
    'Az.Monitor' = '5.*'
    'Az.OperationalInsights' = '3.*'
    'Az.Compute' = '8.*'
    # Microsoft Graph SDK — required by Assessment 365 (Invoke-M365Assessment)
    'Microsoft.Graph.Authentication'                = '2.*'
    'Microsoft.Graph.Identity.DirectoryManagement'  = '2.*'
    'Microsoft.Graph.Identity.SignIns'              = '2.*'
    'Microsoft.Graph.Users'                         = '2.*'
    'Microsoft.Graph.Reports'                       = '2.*'
    'Microsoft.Graph.Applications'                  = '2.*'
    'Microsoft.Graph.DeviceManagement'              = '2.*'
    'Microsoft.Graph.Security'                      = '2.*'
    'Microsoft.Graph.Groups'                        = '2.*'
    'Microsoft.Graph.Teams'                         = '2.*'
    'Microsoft.Graph.Sites'                         = '2.*'
    # Exchange Online — required by Assessment 365 Email section
    # NOTE: 3.8.0+ conflicts with Microsoft.Graph MSAL. Pin to 3.7.1.
    'ExchangeOnlineManagement'                      = '3.7.1'
}