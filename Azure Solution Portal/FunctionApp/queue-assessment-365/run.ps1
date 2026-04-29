param([string]$QueueItem, $TriggerMetadata)

$ErrorActionPreference = 'Stop'
Write-Host "=== START queue-assessment-365 ==="

# Parse queue message
$job = $QueueItem | ConvertFrom-Json
$jobId     = $job.jobId
$tenantId  = $job.tenantId
$graphToken = $job.graphToken

Write-Host "Processing job: $jobId for tenant: $tenantId"

# Storage helper — write blob via REST with storage key from connection string
function Write-AssessmentBlob {
    param([string]$JobId, [string]$Content)
    try {
        $connStr = $env:AzureWebJobsStorage
        $accountName = ($connStr -split ';' | Where-Object { $_ -match '^AccountName=' }) -replace 'AccountName=',''
        $accountKey  = ($connStr -split ';' | Where-Object { $_ -match '^AccountKey='  }) -replace 'AccountKey=',''
        $container   = 'm365assessment-results'
        $blobName    = "$JobId.json"
        $dateStr     = (Get-Date).ToUniversalTime().ToString('R')
        $contentType = 'application/json'
        $contentLen  = [System.Text.Encoding]::UTF8.GetByteCount($Content)

        $stringToSign = "PUT`n`n$contentType`n`nx-ms-blob-type:BlockBlob`nx-ms-date:$dateStr`nx-ms-version:2020-04-08`n/$accountName/$container/$blobName"
        $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Convert]::FromBase64String($accountKey))
        $sig  = [System.Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stringToSign)))

        $headers = @{
            Authorization      = "SharedKey ${accountName}:${sig}"
            'x-ms-blob-type'   = 'BlockBlob'
            'x-ms-date'        = $dateStr
            'x-ms-version'     = '2020-04-08'
            'Content-Type'     = $contentType
        }
        $uri = "https://${accountName}.blob.core.windows.net/${container}/${blobName}"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
        Invoke-RestMethod -Method PUT -Uri $uri -Headers $headers -Body $bytes -ErrorAction Stop | Out-Null
        Write-Host "Blob written: $blobName"
    } catch {
        Write-Host "ERROR writing blob: $($_.Exception.Message)"
    }
}

# Write "running" status immediately
$runningStatus = @{ jobId = $jobId; status = 'running'; tenantId = $tenantId; startedAt = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress
Write-AssessmentBlob -JobId $jobId -Content $runningStatus

$start = Get-Date

# Set token env vars for the assessment script
$env:AZURE_GRAPH_TOKEN = $graphToken
$env:AZURE_TENANT_ID   = $tenantId

try {
    # Locate the assessment execution script
    $scriptPath = $null
    $candidates = @(
        (Join-Path $PSScriptRoot '..\scripts\execute-assessment-365.ps1'),
        'C:\home\site\wwwroot\scripts\execute-assessment-365.ps1',
        'D:\home\site\wwwroot\scripts\execute-assessment-365.ps1'
    )
    foreach ($c in $candidates) {
        $r = [System.IO.Path]::GetFullPath($c)
        if (Test-Path $r) { $scriptPath = $r; break }
    }
    if (-not $scriptPath) { throw "execute-assessment-365.ps1 non trovato." }

    $tempDir = if ($env:TEMP) { $env:TEMP } else { 'C:\local\Temp' }
    $outHtml = Join-Path $tempDir "assessment365_$jobId.html"
    $outJson = Join-Path $tempDir "assessment365_$jobId.json"

    & $scriptPath -TenantId $tenantId -OutputPath $outHtml

    if (Test-Path $outJson) {
        $resultData = Get-Content $outJson -Raw -Encoding UTF8 | ConvertFrom-Json
        $reportHtml = if ($resultData.ReportHTML) { $resultData.ReportHTML } else { '' }
        $summary    = $resultData.Summary

        $result = [ordered]@{
            jobId       = $jobId
            status      = 'complete'
            tenantId    = $tenantId
            completedAt = (Get-Date).ToUniversalTime().ToString('o')
            durationSec = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
            ReportHTML  = $reportHtml
            Summary     = $summary
        }
    } else {
        $result = [ordered]@{
            jobId       = $jobId
            status      = 'error'
            tenantId    = $tenantId
            completedAt = (Get-Date).ToUniversalTime().ToString('o')
            error       = 'Report JSON non generato'
            ReportHTML  = ''
        }
    }
} catch {
    Write-Host "Assessment error: $($_.Exception.Message)"
    $result = [ordered]@{
        jobId       = $jobId
        status      = 'error'
        tenantId    = $tenantId
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
        error       = $_.Exception.Message
        ReportHTML  = ''
    }
} finally {
    Remove-Item Env:AZURE_GRAPH_TOKEN  -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_TENANT_ID    -ErrorAction SilentlyContinue
}

# Write final result blob
$resultJson = $result | ConvertTo-Json -Depth 6 -Compress
Write-AssessmentBlob -JobId $jobId -Content $resultJson

Write-Host "=== END queue-assessment-365 — job $jobId status: $($result.status) ==="
