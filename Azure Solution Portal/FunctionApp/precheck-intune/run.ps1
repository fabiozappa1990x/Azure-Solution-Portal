using namespace System.Net

param($Request, $TriggerMetadata)

Write-Host "=== START precheck-intune ==="

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
$requestedTenantId = $Request.Query.TenantId
if (-not $requestedTenantId) { $requestedTenantId = $Request.Query.tenantId }
if ($requestedTenantId) { $requestedTenantId = $requestedTenantId.ToString().Trim() }

# Per Intune il subscriptionId è opzionale (tenant-wide).
# Se è 'tenant-only', estrai il tenantId direttamente dal JWT del Graph token.
$tenantId = $null

if ($subscriptionId -eq 'tenant-only') {
    Write-Host "Intune tenant-only mode: extracting tenantId from Graph JWT..."
    try {
        $parts = $graphTokenHeader.Split('.')
        if ($parts.Length -ge 2) {
            $payload = $parts[1]
            $mod4 = $payload.Length % 4
            if ($mod4 -gt 0) { $payload += '=' * (4 - $mod4) }
            $payload = $payload.Replace('-', '+').Replace('_', '/')
            $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
            $claims = $decoded | ConvertFrom-Json
            $tenantId = $claims.tid
            Write-Host "TenantId from JWT: $tenantId"
        }
    } catch {
        Write-Host "Warning: impossibile estrarre tenantId dal JWT: $($_.Exception.Message)"
    }
} else {
    # Validate management token + get tenantId dalla subscription
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
}

$azureTokenTenantId = Get-JwtTenantId $accessToken
$graphTokenTenantId = Get-JwtTenantId $graphTokenHeader
if (-not $tenantId -and $graphTokenTenantId) { $tenantId = $graphTokenTenantId }

if ($requestedTenantId -and $graphTokenTenantId -and ($graphTokenTenantId -ne $requestedTenantId)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 403; Body = '{"error":"Il token Graph non appartiene al Tenant ID selezionato"}'; Headers = $corsHeaders })
    return
}
if ($requestedTenantId -and $azureTokenTenantId -and ($azureTokenTenantId -ne $requestedTenantId)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 403; Body = '{"error":"Il token Azure non appartiene al Tenant ID selezionato"}'; Headers = $corsHeaders })
    return
}
if ($requestedTenantId -and $tenantId -and ($tenantId -ne $requestedTenantId)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 403; Body = '{"error":"La subscription/tenant target non appartiene al Tenant ID indicato"}'; Headers = $corsHeaders })
    return
}
if ($azureTokenTenantId -and $tenantId -and ($azureTokenTenantId -ne $tenantId)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 403; Body = '{"error":"Mismatch tra tenant del token Azure e tenant target"}'; Headers = $corsHeaders })
    return
}
if ($graphTokenTenantId -and $tenantId -and ($graphTokenTenantId -ne $tenantId)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 403; Body = '{"error":"Mismatch tra tenant del token Graph e tenant target"}'; Headers = $corsHeaders })
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
$env:AZURE_TENANT_ID       = if ($requestedTenantId) { $requestedTenantId } elseif ($tenantId) { $tenantId } else { '' }

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
