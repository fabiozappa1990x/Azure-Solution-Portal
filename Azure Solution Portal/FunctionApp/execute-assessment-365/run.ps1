using namespace System.Net

param($Request, $TriggerMetadata)

Write-Host "=== START execute-assessment-365 ==="

function Get-CorsHeaders {
    param($Request)
    $origin = $Request.Headers['Origin']
    if ($origin -is [array]) { $origin = $origin[0] }
    if (-not $origin) { $origin = '*' }
    return @{
        'Content-Type'                 = 'application/json'
        'Access-Control-Allow-Origin'  = $origin
        'Access-Control-Allow-Methods' = 'GET,OPTIONS'
        'Access-Control-Allow-Headers' = 'Authorization,Content-Type,X-Graph-Token'
        'Vary'                         = 'Origin'
    }
}

function Get-JwtTenantId {
    param([string]$Token)
    try {
        if (-not $Token) { return $null }
        $parts = $Token.Split('.')
        if ($parts.Length -lt 2) { return $null }
        $payload = $parts[1]
        $mod4 = $payload.Length % 4
        if ($mod4 -gt 0) { $payload += '=' * (4 - $mod4) }
        $payload = $payload.Replace('-', '+').Replace('_', '/')
        $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
        $claims = $decoded | ConvertFrom-Json
        return [string]$claims.tid
    } catch {
        return $null
    }
}

if ($Request.Method -eq 'OPTIONS') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 200; Headers = (Get-CorsHeaders $Request) })
    return
}

$corsHeaders = Get-CorsHeaders $Request

$authHeader = $Request.Headers['Authorization']
if ($authHeader -is [array]) { $authHeader = $authHeader[0] }
if ($authHeader -is [System.Security.SecureString]) {
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($authHeader)
    $authHeader = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
} else { $authHeader = $authHeader.ToString() }

if (-not $authHeader -or -not $authHeader.StartsWith('Bearer ')) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 401; Body = '{"error":"Token Azure mancante"}'; Headers = $corsHeaders })
    return
}
$accessToken = $authHeader.Substring(7).Trim()
if ($accessToken.Length -lt 100) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 401; Body = '{"error":"Token Azure non valido"}'; Headers = $corsHeaders })
    return
}

$graphToken = $Request.Headers['X-Graph-Token']
if ($graphToken -is [array]) { $graphToken = $graphToken[0] }
if ($graphToken) { $graphToken = $graphToken.ToString() }
if (-not $graphToken -or $graphToken.Length -lt 100) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 401; Body = '{"error":"Graph token mancante"}'; Headers = $corsHeaders })
    return
}

$requestedTenantId = $Request.Query.TenantId
if (-not $requestedTenantId) { $requestedTenantId = $Request.Query.tenantId }
if ($requestedTenantId) { $requestedTenantId = $requestedTenantId.ToString().Trim() }

$azureTokenTenantId = Get-JwtTenantId $accessToken
$graphTokenTenantId = Get-JwtTenantId $graphToken
$tenantId = if ($requestedTenantId) { $requestedTenantId } elseif ($graphTokenTenantId) { $graphTokenTenantId } else { $azureTokenTenantId }

if ($requestedTenantId -and $graphTokenTenantId -and ($requestedTenantId -ne $graphTokenTenantId)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 403; Body = '{"error":"Il token Graph non appartiene al Tenant ID selezionato"}'; Headers = $corsHeaders })
    return
}
if ($requestedTenantId -and $azureTokenTenantId -and ($requestedTenantId -ne $azureTokenTenantId)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 403; Body = '{"error":"Il token Azure non appartiene al Tenant ID selezionato"}'; Headers = $corsHeaders })
    return
}

# Attempt module bootstrap (best effort, no hard fail if already embedded)
try {
    if (-not (Get-Module -ListAvailable -Name M365-Assess)) {
        Write-Host "M365-Assess module not found on Function host, installing..."
        Install-Module M365-Assess -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-Host "M365-Assess module installed."
    }
} catch {
    Write-Host "Warning: unable to install M365-Assess module: $($_.Exception.Message)"
}

$scriptPath = $null
$paths = @(
    (Join-Path $PSScriptRoot '..\scripts\execute-assessment-365.ps1'),
    'D:\home\site\wwwroot\scripts\execute-assessment-365.ps1',
    '/home/site/wwwroot/scripts/execute-assessment-365.ps1'
)
foreach ($path in $paths) { if (Test-Path $path) { $scriptPath = $path; break } }
if (-not $scriptPath) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 500; Body = '{"error":"Script execute-assessment-365.ps1 non trovato"}'; Headers = $corsHeaders })
    return
}

$env:AZURE_ACCESS_TOKEN = $accessToken
$env:AZURE_GRAPH_TOKEN = $graphToken
$env:AZURE_TENANT_ID = if ($tenantId) { $tenantId } else { '' }

$tempDir = if ($env:TEMP) { $env:TEMP } else { '/tmp' }
$outHtml = Join-Path $tempDir "assessment365_$($tenantId).html"
$outJson = Join-Path $tempDir "assessment365_$($tenantId).json"
if (Test-Path $outHtml) { Remove-Item $outHtml -Force }
if (Test-Path $outJson) { Remove-Item $outJson -Force }

try {
    & $scriptPath -TenantId $tenantId -OutputPath $outHtml
    if (Test-Path $outJson) {
        $jsonContent = Get-Content $outJson -Raw
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = 200
            Body = $jsonContent
            Headers = $corsHeaders
        })
    } else {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = 500
            Body = '{"error":"Report JSON Assessment 365 non generato"}'
            Headers = $corsHeaders
        })
    }
} catch {
    $err = @{
        error = $_.Exception.Message
        stack = if ($_.ScriptStackTrace) { $_.ScriptStackTrace } else { $null }
    } | ConvertTo-Json -Depth 5
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 500
        Body = $err
        Headers = $corsHeaders
    })
} finally {
    Remove-Item Env:AZURE_ACCESS_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_GRAPH_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_TENANT_ID -ErrorAction SilentlyContinue
    Write-Host "=== END execute-assessment-365 ==="
}
