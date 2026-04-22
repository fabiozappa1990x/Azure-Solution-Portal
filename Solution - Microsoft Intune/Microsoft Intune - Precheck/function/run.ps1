using namespace System.Net

param($Request, $TriggerMetadata)

Write-Host "=== START precheck-intune ==="

function ConvertFrom-Base64Url {
    param([string]$Base64Url)
    if ([string]::IsNullOrWhiteSpace($Base64Url)) { return $null }
    $padded = $Base64Url.Replace('-', '+').Replace('_', '/')
    switch ($padded.Length % 4) {
        2 { $padded += '==' }
        3 { $padded += '=' }
    }
    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($padded))
}

function Get-JwtClaims {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { return $null }
    try {
        $payloadJson = ConvertFrom-Base64Url -Base64Url $parts[1]
        if ([string]::IsNullOrWhiteSpace($payloadJson)) { return $null }
        return ($payloadJson | ConvertFrom-Json)
    } catch {
        return $null
    }
}

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

# --- Management token (validazione identità) ---
$authHeader = $Request.Headers['Authorization']
if ($authHeader -is [array]) { $authHeader = $authHeader[0] }
if ($null -eq $authHeader) {
    $authHeader = ''
} elseif ($authHeader -is [System.Security.SecureString]) {
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

# --- Graph token (per Intune Graph API) ---
$graphTokenHeader = $Request.Headers['X-Graph-Token']
if ($graphTokenHeader -is [array]) { $graphTokenHeader = $graphTokenHeader[0] }
if ($graphTokenHeader) { $graphTokenHeader = $graphTokenHeader.ToString() }

if (-not $graphTokenHeader -or $graphTokenHeader.Length -lt 100) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 401; Body = '{"error":"Graph token mancante. Verifica che il consenso alle API Graph sia stato concesso."}'; Headers = $corsHeaders })
    return
}

$subscriptionId = $Request.Query.SubscriptionId
if (-not $subscriptionId) { $subscriptionId = $Request.Query.subscriptionId }
if (-not $subscriptionId) { $subscriptionId = 'tenant-only' }

$accessClaims = Get-JwtClaims -Token $accessToken
$graphClaims  = Get-JwtClaims -Token $graphTokenHeader
$accessTid = if ($accessClaims -and $accessClaims.tid) { "$($accessClaims.tid)" } else { $null }
$graphTid  = if ($graphClaims -and $graphClaims.tid) { "$($graphClaims.tid)" } else { $null }

# Validate management token + get tenantId (for real subscriptions)
$tenantId = $null
$subscriptionIdLower = $subscriptionId.ToLowerInvariant()
$requiresArmValidation = ($subscriptionIdLower -ne 'tenant-only')

if ($requiresArmValidation) {
    try {
        $headers = @{ 'Authorization' = "Bearer $accessToken"; 'Content-Type' = 'application/json' }
        $url = "https://management.azure.com/subscriptions/${subscriptionId}?api-version=2022-12-01"
        $result = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
        Write-Host "Token valid for subscription: $($result.displayName)"
        $tenantId = $result.tenantId
    } catch {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 401; Body = '{"error":"Token non valido o subscription non accessibile"}'; Headers = $corsHeaders })
        return
    }
} else {
    Write-Host "Tenant-only mode: ARM subscription validation skipped"
}

if (-not $tenantId) {
    if ($graphTid) { $tenantId = $graphTid }
    elseif ($accessTid) { $tenantId = $accessTid }
}

if (-not $tenantId) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 401; Body = '{"error":"Impossibile determinare il tenant dai token ricevuti"}'; Headers = $corsHeaders })
    return
}

if ($graphTid -and $accessTid -and ($graphTid -ne $accessTid)) {
    Write-Warning "Access token tid ($accessTid) differs from Graph token tid ($graphTid)"
}

if ($requiresArmValidation -and $graphTid -and ($tenantId -ne $graphTid)) {
    $msg = '{"error":"Il token Graph appartiene a un tenant diverso dalla subscription selezionata. Riautenticarsi e selezionare la subscription del tenant Intune corretto."}'
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 401; Body = $msg; Headers = $corsHeaders })
    return
}

$scriptPath = $null
$paths = @(
    (Join-Path $PSScriptRoot '..\scripts\precheck-intune.ps1'),
    'D:\home\site\wwwroot\scripts\precheck-intune.ps1',
    '/home/site/wwwroot/scripts/precheck-intune.ps1'
)
foreach ($path in $paths) {
    if (Test-Path $path) { $scriptPath = $path; break }
}

if (-not $scriptPath) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 500; Body = '{"error":"Script precheck-intune.ps1 non trovato"}'; Headers = $corsHeaders })
    return
}

$env:AZURE_ACCESS_TOKEN    = $accessToken
$env:AZURE_SUBSCRIPTION_ID = $subscriptionId
$env:AZURE_GRAPH_TOKEN     = $graphTokenHeader
$env:AZURE_TENANT_ID       = if ($tenantId) { $tenantId } else { '' }

$tempDir = if ($env:TEMP) { $env:TEMP } else { '/tmp' }
$outHtml = Join-Path $tempDir "intune_report_$subscriptionId.html"
$outJson = Join-Path $tempDir "intune_report_$subscriptionId.json"

if (Test-Path $outJson) { Remove-Item $outJson -Force }
if (Test-Path $outHtml) { Remove-Item $outHtml -Force }

try {
    Write-Host "Executing precheck-intune..."
    & $scriptPath -SubscriptionId $subscriptionId -OutputPath $outHtml

    if (Test-Path $outJson) {
        $jsonContent = Get-Content $outJson -Raw
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 200; Body = $jsonContent; Headers = $corsHeaders })
    } else {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 500; Body = '{"error":"Report JSON Intune non generato"}'; Headers = $corsHeaders })
    }
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 500; Body = "{`"error`":`"$($_.Exception.Message)`"}"; Headers = $corsHeaders })
} finally {
    Remove-Item Env:AZURE_ACCESS_TOKEN    -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_SUBSCRIPTION_ID -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_GRAPH_TOKEN     -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_TENANT_ID       -ErrorAction SilentlyContinue
    Write-Host "=== END precheck-intune ==="
}
