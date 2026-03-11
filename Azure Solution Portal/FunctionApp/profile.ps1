# Azure Functions profile.ps1
#
# Nota: per ridurre i cold start e rendere i check/endpoint più reattivi,
# non importiamo automaticamente i moduli Az.* (i precheck usano REST).
# Se servono comandi Az in futuro, abilita l'import impostando:
#   ENABLE_AZ_MODULES = "true"

if ($env:ENABLE_AZ_MODULES -eq 'true') {
    Write-Host "Loading Azure PowerShell modules (ENABLE_AZ_MODULES=true)..."

    if (Get-Module -ListAvailable -Name Az.Accounts) { Import-Module Az.Accounts }
    if (Get-Module -ListAvailable -Name Az.Resources) { Import-Module Az.Resources }
    if (Get-Module -ListAvailable -Name Az.Monitor) { Import-Module Az.Monitor }
    if (Get-Module -ListAvailable -Name Az.OperationalInsights) { Import-Module Az.OperationalInsights }
    if (Get-Module -ListAvailable -Name Az.Compute) { Import-Module Az.Compute }

    Write-Host "Azure PowerShell profile loaded"
} else {
    Write-Host "Azure PowerShell profile: skipping Az.* imports (fast startup)"
}
