using namespace System.Net

param($Request, $TriggerMetadata)

Write-Host "=== START execute-assessment-365 (async) ==="

function Get-CorsHeaders {
    param($Request)
    $origin = $Request.Headers['Origin']
    if ($origin -is [array]) { $origin = $origin[0] }
    if (-not $origin) { $origin = '*' }
    return @{
        'Content-Type'                 = 'application/json'
        'Access-Control-Allow-Origin'  = $origin
        'Access-Control-Allow-Methods' = 'GET,POST,OPTIONS'
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
    } catch { return $null }
}

if ($Request.Method -eq 'OPTIONS') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 200; Headers = (Get-CorsHeaders $Request) })
    return
}

$corsHeaders = Get-CorsHeaders $Request

# --- Auth validation ---
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
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 401; Body = '{"error":"Token non valido"}'; Headers = $corsHeaders })
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

$graphTokenTenantId = Get-JwtTenantId $graphToken
$tenantId = if ($requestedTenantId) { $requestedTenantId } elseif ($graphTokenTenantId) { $graphTokenTenantId } else { (Get-JwtTenantId $accessToken) }

if ($requestedTenantId -and $graphTokenTenantId -and ($requestedTenantId -ne $graphTokenTenantId)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 403; Body = '{"error":"Token non appartiene al tenant selezionato"}'; Headers = $corsHeaders })
    return
}

# --- Generate jobId and enqueue ---
$jobId = [System.Guid]::NewGuid().ToString('N')
$jobMessage = [ordered]@{
    jobId       = $jobId
    tenantId    = $tenantId
    graphToken  = $graphToken
    startedAt   = (Get-Date).ToUniversalTime().ToString('o')
}
$jobJson = $jobMessage | ConvertTo-Json -Compress -Depth 3

# Write job to queue (output binding)
Push-OutputBinding -Name JobQueue -Value $jobJson

Write-Host "Job enqueued: $jobId for tenant $tenantId"

# Return jobId immediately — client will poll /api/get-assessment-result?jobId=...
$response = [ordered]@{
    jobId   = $jobId
    status  = 'pending'
    pollUrl = "/api/get-assessment-result?jobId=$jobId"
} | ConvertTo-Json -Compress

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = 202
    Body       = $response
    Headers    = $corsHeaders
})
Write-Host "=== END execute-assessment-365 (async) — returned 202 in <1s ==="
