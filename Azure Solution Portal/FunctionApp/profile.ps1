# Azure Functions profile.ps1

Write-Host "Loading Azure PowerShell modules..."

# Explicitly import required modules
if (Get-Module -ListAvailable -Name Az.Accounts) {
    Import-Module Az.Accounts
}
if (Get-Module -ListAvailable -Name Az.Resources) {
    Import-Module Az.Resources
}
if (Get-Module -ListAvailable -Name Az.Monitor) {
    Import-Module Az.Monitor
}
if (Get-Module -ListAvailable -Name Az.OperationalInsights) {
    Import-Module Az.OperationalInsights
}
if (Get-Module -ListAvailable -Name Az.Compute) {
    Import-Module Az.Compute
}

Write-Host "Azure PowerShell profile loaded"