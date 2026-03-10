<#
.SYNOPSIS
Azure Monitor Deep Analysis - Wrapper entrypoint
.NOTES
Keeps backward compatibility with historical script name (testluca.ps1).
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\\AzureMonitorReport.html",

    [Parameter(Mandatory=$false)]
    [switch]$SkipDCRAssociations
)

$legacyScript = Join-Path $PSScriptRoot 'testluca.ps1'
if (-not (Test-Path $legacyScript)) {
    throw "Script legacy non trovato: $legacyScript"
}

& $legacyScript @PSBoundParameters

