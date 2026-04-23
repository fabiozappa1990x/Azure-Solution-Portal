using namespace System.Net

param($Request, $TriggerMetadata)

Write-Host "=== START precheck-assessment-security ==="

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
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($authHeader)
    $authHeader = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
} else {
    $authHeader = $authHeader.ToString()
}

if (-not $authHeader -or -not $authHeader.StartsWith('Bearer ')) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 401
        Body       = '{"error":"Token Azure mancante"}'
        Headers    = $corsHeaders
    })
    return
}

$accessToken = $authHeader.Substring(7).Trim()
if ($accessToken.Length -lt 100) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 401
        Body       = '{"error":"Token Azure non valido"}'
        Headers    = $corsHeaders
    })
    return
}

$graphToken = $Request.Headers['X-Graph-Token']
if ($graphToken -is [array]) { $graphToken = $graphToken[0] }
if ($graphToken) { $graphToken = $graphToken.ToString() }
if (-not $graphToken -or $graphToken.Length -lt 100) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 401
        Body       = '{"error":"Graph token mancante. Concedi il consenso Microsoft Graph richiesto."}'
        Headers    = $corsHeaders
    })
    return
}

$subscriptionId = $Request.Query.SubscriptionId
if (-not $subscriptionId) { $subscriptionId = $Request.Query.subscriptionId }
if (-not $subscriptionId) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 400
        Body       = '{"error":"SubscriptionId mancante"}'
        Headers    = $corsHeaders
    })
    return
}

$scriptPath = $null
$paths = @(
    (Join-Path $PSScriptRoot '..\scripts\precheck-assessment-security.ps1'),
    'D:\home\site\wwwroot\scripts\precheck-assessment-security.ps1',
    '/home/site/wwwroot/scripts/precheck-assessment-security.ps1'
)
foreach ($path in $paths) {
    if (Test-Path $path) { $scriptPath = $path; break }
}

if (-not $scriptPath) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 500
        Body       = '{"error":"Script precheck-assessment-security.ps1 non trovato"}'
        Headers    = $corsHeaders
    })
    return
}

$env:AZURE_ACCESS_TOKEN    = $accessToken
$env:AZURE_GRAPH_TOKEN     = $graphToken
$env:AZURE_SUBSCRIPTION_ID = $subscriptionId

$tempDir = if ($env:TEMP) { $env:TEMP } else { '/tmp' }
$outHtml = Join-Path $tempDir "report_assessment_security_$subscriptionId.html"
$outJson = Join-Path $tempDir "report_assessment_security_$subscriptionId.json"

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
    Remove-Item Env:AZURE_ACCESS_TOKEN    -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_GRAPH_TOKEN     -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_SUBSCRIPTION_ID -ErrorAction SilentlyContinue
    Write-Host "=== END precheck-assessment-security ==="
}
