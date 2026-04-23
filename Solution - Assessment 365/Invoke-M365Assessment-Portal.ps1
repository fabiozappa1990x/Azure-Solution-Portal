<#
.SYNOPSIS
    Wrapper per avviare M365-Assess dalla solution "Assessment 365" del portale.

.DESCRIPTION
    Importa il modulo locale incluso nella cartella Solution - Assessment 365 e
    invoca Invoke-M365Assessment con i parametri principali.
#>

[CmdletBinding()]
param(
    [string]$TenantId,
    [string[]]$Section,
    [string]$OutputFolder = ".\M365-Assessment",
    [switch]$QuickScan,
    [switch]$NonInteractive,
    [switch]$OpenReport,
    [switch]$SkipConnection,
    [switch]$UseDeviceCode
)

$modulePath = Join-Path $PSScriptRoot 'src\M365-Assess'
if (-not (Test-Path $modulePath)) {
    throw "Modulo non trovato: $modulePath"
}

Import-Module $modulePath -Force

$params = @{}
if ($TenantId) { $params.TenantId = $TenantId }
if ($Section -and $Section.Count -gt 0) { $params.Section = $Section }
if ($OutputFolder) { $params.OutputFolder = $OutputFolder }
if ($QuickScan) { $params.QuickScan = $true }
if ($NonInteractive) { $params.NonInteractive = $true }
if ($OpenReport) { $params.OpenReport = $true }
if ($SkipConnection) { $params.SkipConnection = $true }
if ($UseDeviceCode) { $params.UseDeviceCode = $true }

Write-Host "Avvio M365-Assess..." -ForegroundColor Cyan
Invoke-M365Assessment @params
