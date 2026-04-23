using namespace System.Net

param($Request, $TriggerMetadata)

Write-Host "=== START precheck-monitor-v2 ==="

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

$corsHeaders = Get-CorsHeaders $Request

if ($Request.Method -eq 'OPTIONS') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 200
        Headers    = $corsHeaders
    })
    return
}

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
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 401
        Body       = '{"error":"Token mancante"}'
        Headers    = $corsHeaders
    })
    return
}

$accessToken = $authHeader.Substring(7).Trim()
if ($accessToken.Length -lt 100) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 401
        Body       = '{"error":"Token troppo corto"}'
        Headers    = $corsHeaders
    })
    return
}

$subscriptionId = $Request.Query.SubscriptionId
if (-not $subscriptionId) { $subscriptionId = $Request.Query.subscriptionId }
$requestedTenantId = $Request.Query.TenantId
if (-not $requestedTenantId) { $requestedTenantId = $Request.Query.tenantId }
if ($requestedTenantId) { $requestedTenantId = $requestedTenantId.ToString().Trim() }
if (-not $subscriptionId) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 400
        Body       = '{"error":"SubscriptionId mancante"}'
        Headers    = $corsHeaders
    })
    return
}

try {
    $headers = @{ 'Authorization' = "Bearer $accessToken"; 'Content-Type' = 'application/json' }
    $result = Invoke-RestMethod -Uri "https://management.azure.com/subscriptions/${subscriptionId}?api-version=2022-12-01" -Headers $headers -Method Get
    $tokenTenantId = Get-JwtTenantId $accessToken
    $subscriptionTenantId = if ($result.tenantId) { $result.tenantId.ToString().Trim() } else { $null }

    if ($requestedTenantId -and $tokenTenantId -and ($tokenTenantId -ne $requestedTenantId)) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = 403
            Body       = '{"error":"Il token Azure non appartiene al Tenant ID selezionato"}'
            Headers    = $corsHeaders
        })
        return
    }
    if ($requestedTenantId -and $subscriptionTenantId -and ($subscriptionTenantId -ne $requestedTenantId)) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = 403
            Body       = '{"error":"La subscription selezionata non appartiene al Tenant ID indicato"}'
            Headers    = $corsHeaders
        })
        return
    }
    if ($tokenTenantId -and $subscriptionTenantId -and ($tokenTenantId -ne $subscriptionTenantId)) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = 403
            Body       = '{"error":"Mismatch tra tenant del token e tenant della subscription"}'
            Headers    = $corsHeaders
        })
        return
    }
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 401
        Body       = '{"error":"Token non valido o subscription non accessibile"}'
        Headers    = $corsHeaders
    })
    return
}

$scriptPath = $null
$paths = @(
    (Join-Path $PSScriptRoot '..\scripts\precheck-monitor-v2.ps1'),
    'D:\home\site\wwwroot\scripts\precheck-monitor-v2.ps1',
    '/home/site/wwwroot/scripts/precheck-monitor-v2.ps1'
)

foreach ($path in $paths) {
    if (Test-Path $path) { $scriptPath = $path; break }
}

if (-not $scriptPath) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 500
        Body       = '{"error":"Script precheck-monitor-v2.ps1 non trovato"}'
        Headers    = $corsHeaders
    })
    return
}

$env:AZURE_ACCESS_TOKEN = $accessToken
$env:AZURE_SUBSCRIPTION_ID = $subscriptionId
$env:AZURE_TENANT_ID = if ($requestedTenantId) { $requestedTenantId } else { '' }

$tempDir = if ($env:TEMP) { $env:TEMP } else { '/tmp' }
$outHtml = Join-Path $tempDir "report_monitor_v2_$subscriptionId.html"
$outJson = Join-Path $tempDir "report_monitor_v2_$subscriptionId.json"

if (Test-Path $outJson) { Remove-Item $outJson -Force }
if (Test-Path $outHtml) { Remove-Item $outHtml -Force }

try {
    & $scriptPath -SubscriptionId $subscriptionId -OutputPath $outHtml

    if (Test-Path $outJson) {
        $jsonContent = Get-Content $outJson -Raw
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = 200
            Body       = $jsonContent
            Headers    = $corsHeaders
        })
    } else {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = 500
            Body       = '{"error":"Report JSON non generato"}'
            Headers    = $corsHeaders
        })
    }
} catch {
    $err = @{
        error    = $_.Exception.Message
        position = (if ($_.InvocationInfo) { $_.InvocationInfo.PositionMessage } else { $null })
        stack    = (if ($_.ScriptStackTrace) { $_.ScriptStackTrace } else { $null })
    } | ConvertTo-Json -Depth 6

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 500
        Body       = $err
        Headers    = $corsHeaders
    })
} finally {
    Remove-Item Env:AZURE_ACCESS_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_SUBSCRIPTION_ID -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_TENANT_ID -ErrorAction SilentlyContinue
    Write-Host "=== END precheck-monitor-v2 ==="
}
