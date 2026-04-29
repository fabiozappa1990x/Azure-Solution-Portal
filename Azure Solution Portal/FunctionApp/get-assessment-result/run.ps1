using namespace System.Net

param($Request, $TriggerMetadata)

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
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 200; Headers = (Get-CorsHeaders $Request) })
    return
}

$corsHeaders = Get-CorsHeaders $Request
$jobId = $Request.Query.jobId
if (-not $jobId) { $jobId = $Request.Query.JobId }
if (-not $jobId) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 400; Body = '{"error":"jobId mancante"}'; Headers = $corsHeaders })
    return
}

# Read blob from Azure Storage
function Read-AssessmentBlob {
    param([string]$JobId)
    try {
        $connStr     = $env:AzureWebJobsStorage
        $accountName = ($connStr -split ';' | Where-Object { $_ -match '^AccountName=' }) -replace 'AccountName=',''
        $accountKey  = ($connStr -split ';' | Where-Object { $_ -match '^AccountKey='  }) -replace 'AccountKey=',''
        $container   = 'm365assessment-results'
        $blobName    = "$JobId.json"
        $dateStr     = (Get-Date).ToUniversalTime().ToString('R')

        $stringToSign = "GET`n`n`n`n`n`n`n`n`n`n`n`nx-ms-date:$dateStr`nx-ms-version:2020-04-08`n/$accountName/$container/$blobName"
        $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Convert]::FromBase64String($accountKey))
        $sig  = [System.Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stringToSign)))

        $headers = @{
            Authorization  = "SharedKey ${accountName}:${sig}"
            'x-ms-date'    = $dateStr
            'x-ms-version' = '2020-04-08'
        }
        $uri = "https://${accountName}.blob.core.windows.net/${container}/${blobName}"
        return Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
    } catch {
        if ($_.Exception.Response.StatusCode -eq 404) { return $null }
        Write-Host "Blob read error: $($_.Exception.Message)"
        return $null
    }
}

$blobContent = Read-AssessmentBlob -JobId $jobId

if ($null -eq $blobContent) {
    $body = @{ jobId = $jobId; status = 'pending' } | ConvertTo-Json -Compress
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 200; Body = $body; Headers = $corsHeaders })
    return
}

# blobContent is already parsed as PSCustomObject by Invoke-RestMethod (JSON auto-parse)
# Re-serialize to return as JSON
$body = $blobContent | ConvertTo-Json -Depth 8 -Compress
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 200; Body = $body; Headers = $corsHeaders })
