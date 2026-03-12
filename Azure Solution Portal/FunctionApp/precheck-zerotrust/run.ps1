using namespace System.Net

param($Request, $TriggerMetadata)

Write-Host "=== START precheck-zerotrust ==="

function Get-CorsHeaders {
    param($Request)

    $origin = $Request.Headers['Origin']
    if ($origin -is [array]) { $origin = $origin[0] }
    if (-not $origin) { $origin = '*' }

    return @{
        'Content-Type'                 = 'application/json'
        'Access-Control-Allow-Origin'  = $origin
        'Access-Control-Allow-Methods' = 'GET,OPTIONS'
        'Access-Control-Allow-Headers' = 'Authorization,Content-Type'
        'Vary'                         = 'Origin'
    }
}

if ($Request.Method -eq 'OPTIONS') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 200
        Headers    = (Get-CorsHeaders $Request)
    })
    return
}

$corsHeaders = Get-CorsHeaders $Request

$authHeader = $Request.Headers['Authorization']
if ($authHeader -is [array]) { $authHeader = $authHeader[0] }
if ($authHeader -is [System.Security.SecureString]) {
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($authHeader)
    $authHeader = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
} else {
    $authHeader = $authHeader.ToString()
}

if (-not $authHeader -or -not $authHeader.StartsWith('Bearer ')) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 401; Body = '{"error":"Token mancante"}'; Headers = $corsHeaders })
    return
}

$accessToken = $authHeader.Substring(7).Trim()
if ($accessToken.Length -lt 100) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 401; Body = '{"error":"Token troppo corto"}'; Headers = $corsHeaders })
    return
}

# Validate token against Microsoft Graph
try {
    $headers = @{ 'Authorization' = "Bearer $accessToken"; 'Content-Type' = 'application/json' }
    $org = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/organization?`$select=id,displayName" -Headers $headers -Method Get
    Write-Host "Graph token valid for tenant: $($org.value[0].displayName)"
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 401; Body = '{"error":"Token non valido per Microsoft Graph (richiede permessi Graph delegated)"}'; Headers = $corsHeaders })
    return
}

$tenantId = $Request.Query.tenantId
if (-not $tenantId) { $tenantId = $Request.Query.TenantId }
if (-not $tenantId) {
    # Not strictly required; script can infer, but keep stable filenames
    $tenantId = 'tenant'
}

$scriptPath = $null
$paths = @(
    (Join-Path $PSScriptRoot '..\scripts\precheck-zerotrust.ps1'),
    'D:\home\site\wwwroot\scripts\precheck-zerotrust.ps1',
    '/home/site/wwwroot/scripts/precheck-zerotrust.ps1'
)
foreach ($path in $paths) {
    if (Test-Path $path) { $scriptPath = $path; break }
}

if (-not $scriptPath) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 500; Body = '{"error":"Script precheck-zerotrust.ps1 non trovato"}'; Headers = $corsHeaders })
    return
}

$env:GRAPH_ACCESS_TOKEN = $accessToken
$env:AZURE_TENANT_ID    = $tenantId

$tempDir = if ($env:TEMP) { $env:TEMP } else { '/tmp' }
$outHtml = Join-Path $tempDir "zerotrust_report_$tenantId.html"
$outJson = Join-Path $tempDir "zerotrust_report_$tenantId.json"

if (Test-Path $outJson) { Remove-Item $outJson -Force }
if (Test-Path $outHtml) { Remove-Item $outHtml -Force }

try {
    Write-Host "Executing precheck-zerotrust..."
    & $scriptPath -TenantId $tenantId -OutputPath $outHtml

    if (Test-Path $outJson) {
        $jsonContent = Get-Content $outJson -Raw
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 200; Body = $jsonContent; Headers = $corsHeaders })
    } else {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 500; Body = '{"error":"Report JSON Zero Trust non generato"}'; Headers = $corsHeaders })
    }
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 500; Body = "{`"error`":`"$($_.Exception.Message)`"}"; Headers = $corsHeaders })
} finally {
    Remove-Item Env:GRAPH_ACCESS_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_TENANT_ID -ErrorAction SilentlyContinue
    Write-Host "=== END precheck-zerotrust ==="
}
