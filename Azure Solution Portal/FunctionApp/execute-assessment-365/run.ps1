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
        return [string]($decoded | ConvertFrom-Json).tid
    } catch { return $null }
}

function Get-StorageCredentials {
    $connStr = $env:AzureWebJobsStorage
    $name = ($connStr -split ';' | Where-Object { $_ -match '^AccountName=' }) -replace 'AccountName=',''
    $key  = ($connStr -split ';' | Where-Object { $_ -match '^AccountKey='  }) -replace 'AccountKey=',''
    return @{ Name = $name; Key = $key }
}

function Get-StorageSignature {
    param([string]$StringToSign, [string]$Key)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Convert]::FromBase64String($Key))
    return [System.Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($StringToSign)))
}

function Send-QueueMessage {
    param([string]$QueueName, [string]$Message)
    $creds   = Get-StorageCredentials
    $name    = $creds.Name
    $key     = $creds.Key
    $dateStr = (Get-Date).ToUniversalTime().ToString('R')
    $b64Msg  = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Message))
    $xmlBody = "<QueueMessage><MessageText>$b64Msg</MessageText></QueueMessage>"
    $bodyLen = [System.Text.Encoding]::UTF8.GetByteCount($xmlBody)

    $strToSign = "POST`n`napplication/xml`n`nx-ms-date:$dateStr`nx-ms-version:2020-04-08`n/$name/$QueueName/messages"
    $sig = Get-StorageSignature -StringToSign $strToSign -Key $key

    $headers = @{
        Authorization  = "SharedKey ${name}:${sig}"
        'x-ms-date'    = $dateStr
        'x-ms-version' = '2020-04-08'
        'Content-Type' = 'application/xml'
    }
    $uri = "https://${name}.queue.core.windows.net/$QueueName/messages"
    Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $xmlBody -ErrorAction Stop | Out-Null
}

function Write-StatusBlob {
    param([string]$JobId, [string]$Content)
    try {
        $creds   = Get-StorageCredentials
        $name    = $creds.Name
        $key     = $creds.Key
        $container = 'm365assessment-results'
        $blobName  = "$JobId.json"
        $dateStr   = (Get-Date).ToUniversalTime().ToString('R')
        $bytes     = [System.Text.Encoding]::UTF8.GetBytes($Content)

        $strToSign = "PUT`n`napplication/json`n`nx-ms-blob-type:BlockBlob`nx-ms-date:$dateStr`nx-ms-version:2020-04-08`n/$name/$container/$blobName"
        $sig = Get-StorageSignature -StringToSign $strToSign -Key $key

        $headers = @{
            Authorization      = "SharedKey ${name}:${sig}"
            'x-ms-blob-type'   = 'BlockBlob'
            'x-ms-date'        = $dateStr
            'x-ms-version'     = '2020-04-08'
            'Content-Type'     = 'application/json'
        }
        $uri = "https://${name}.blob.core.windows.net/${container}/${blobName}"
        Invoke-RestMethod -Method PUT -Uri $uri -Headers $headers -Body $bytes -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "WARNING: blob write failed: $($_.Exception.Message)"
    }
}

if ($Request.Method -eq 'OPTIONS') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 200; Headers = (Get-CorsHeaders $Request) })
    return
}

$corsHeaders = Get-CorsHeaders $Request

# --- Auth ---
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
$graphTenantId = Get-JwtTenantId $graphToken
$tenantId = if ($requestedTenantId) { $requestedTenantId } elseif ($graphTenantId) { $graphTenantId } else { Get-JwtTenantId $accessToken }

if ($requestedTenantId -and $graphTenantId -and ($requestedTenantId -ne $graphTenantId)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 403; Body = '{"error":"Token non appartiene al tenant selezionato"}'; Headers = $corsHeaders })
    return
}

# --- Enqueue job ---
try {
    $jobId = [System.Guid]::NewGuid().ToString('N')
    $jobMsg = @{ jobId = $jobId; tenantId = $tenantId; graphToken = $graphToken; startedAt = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress -Depth 3

    # Write pending blob first
    $pendingBlob = @{ jobId = $jobId; status = 'pending'; tenantId = $tenantId } | ConvertTo-Json -Compress
    Write-StatusBlob -JobId $jobId -Content $pendingBlob

    # Enqueue to storage queue
    Send-QueueMessage -QueueName 'm365assessment-jobs' -Message $jobMsg

    Write-Host "Job enqueued: $jobId for tenant $tenantId"

    $respBody = @{ jobId = $jobId; status = 'pending'; pollUrl = "/api/get-assessment-result?jobId=$jobId" } | ConvertTo-Json -Compress
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 202; Body = $respBody; Headers = $corsHeaders })
} catch {
    Write-Host "ERROR enqueuing job: $($_.Exception.Message)"
    $err = @{ error = "Impossibile avviare l'assessment: $($_.Exception.Message)" } | ConvertTo-Json -Compress
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 500; Body = $err; Headers = $corsHeaders })
}

Write-Host "=== END execute-assessment-365 (async) ==="
