using namespace System.Net

param($Request, $TriggerMetadata)

Write-Host "=== START ==="

if ($Request.Method -eq 'OPTIONS') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 200
    })
    return
}

$authHeader = $Request.Headers['Authorization']

if ($authHeader -is [array]) {
    $authHeader = $authHeader[0]
}

if ($authHeader -is [System.Security.SecureString]) {
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($authHeader)
    $authHeader = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
} else {
    $authHeader = $authHeader.ToString()
}

if (-not $authHeader -or -not $authHeader.StartsWith('Bearer ')) {
    Write-Host "ERROR: No token"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 401
        Body = '{"error":"Token mancante"}'
        Headers = @{ 
            'Content-Type' = 'application/json'
        }
    })
    return
}

$accessToken = $authHeader.Substring(7).Trim()
Write-Host "Token length: $($accessToken.Length)"

if ($accessToken.Length -lt 100) {
    Write-Host "ERROR: Token too short"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 401
        Body = '{"error":"Token troppo corto"}'
        Headers = @{ 
            'Content-Type' = 'application/json'
            'Access-Control-Allow-Origin' = '*'
        }
    })
    return
}

$subscriptionId = $Request.Query.SubscriptionId
if (-not $subscriptionId) {
    $subscriptionId = $Request.Query.subscriptionId
}

if (-not $subscriptionId) {
    Write-Host "ERROR: No subscription"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 400
        Body = '{"error":"SubscriptionId mancante"}'
        Headers = @{ 
            'Content-Type' = 'application/json'
            'Access-Control-Allow-Origin' = '*'
        }
    })
    return
}

Write-Host "Subscription: $subscriptionId"

try {
    Write-Host "Testing token..."
    $headers = @{
        'Authorization' = "Bearer $accessToken"
        'Content-Type' = 'application/json'
    }
    
    $url = "https://management.azure.com/subscriptions/${subscriptionId}?api-version=2022-12-01"
    $result = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
    Write-Host "Token valid for: $($result.displayName)"
    
} catch {
    Write-Host "ERROR: Token invalid - $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 401
        Body = '{"error":"Token non valido"}'
        Headers = @{ 
            'Content-Type' = 'application/json'
            'Access-Control-Allow-Origin' = '*'
        }
    })
    return
}

$scriptPath = $null
$paths = @(
    (Join-Path $PSScriptRoot '..\scripts\precheck-monitor.ps1'),
    'D:\home\site\wwwroot\scripts\precheck-monitor.ps1',
    '/home/site/wwwroot/scripts/precheck-monitor.ps1',
    # Backward compatibility
    (Join-Path $PSScriptRoot '..\scripts\testluca.ps1'),
    'D:\home\site\wwwroot\scripts\testluca.ps1',
    '/home/site/wwwroot/scripts/testluca.ps1'
)

foreach ($path in $paths) {
    Write-Host "Trying: $path"
    if (Test-Path $path) {
        $scriptPath = $path
        Write-Host "Found script at: $path"
        break
    }
}

if (-not $scriptPath) {
    Write-Host "ERROR: Script not found"
    Write-Host "Searched paths:"
    foreach ($p in $paths) {
        Write-Host "  - $p : $(Test-Path $p)"
    }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 500
        Body = '{"error":"Script precheck-monitor.ps1 non trovato"}'
        Headers = @{ 
            'Content-Type' = 'application/json'
            'Access-Control-Allow-Origin' = '*'
        }
    })
    return
}

$env:AZURE_ACCESS_TOKEN = $accessToken
$env:AZURE_SUBSCRIPTION_ID = $subscriptionId

$tempDir = if ($env:TEMP) { $env:TEMP } else { '/tmp' }
$outHtml = Join-Path $tempDir "report_$subscriptionId.html"
$outJson = Join-Path $tempDir "report_$subscriptionId.json"

Write-Host "Output HTML: $outHtml"
Write-Host "Output JSON: $outJson"

if (Test-Path $outJson) { Remove-Item $outJson -Force }
if (Test-Path $outHtml) { Remove-Item $outHtml -Force }

try {
    Write-Host "Executing script..."
    & $scriptPath -SubscriptionId $subscriptionId -OutputPath $outHtml
    Write-Host "Script completed"
    
    if (Test-Path $outJson) {
        $jsonContent = Get-Content $outJson -Raw
        Write-Host "JSON generated: $($jsonContent.Length) bytes"
        
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = 200
            Body = $jsonContent
            Headers = @{ 
                'Content-Type' = 'application/json'
            }
        })
    } else {
        Write-Host "ERROR: JSON not generated"
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = 500
            Body = '{"error":"Report JSON non generato"}'
            Headers = @{ 
                'Content-Type' = 'application/json'
                'Access-Control-Allow-Origin' = '*'
            }
        })
    }
    
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    Write-Host "Stack: $($_.ScriptStackTrace)"
    
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 500
        Body = "{`"error`":`"$($_.Exception.Message)`"}"
        Headers = @{ 
            'Content-Type' = 'application/json'
            'Access-Control-Allow-Origin' = '*'
        }
    })
} finally {
    Remove-Item Env:AZURE_ACCESS_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_SUBSCRIPTION_ID -ErrorAction SilentlyContinue
    Write-Host "=== PRECHECK FUNCTION END ==="
}
