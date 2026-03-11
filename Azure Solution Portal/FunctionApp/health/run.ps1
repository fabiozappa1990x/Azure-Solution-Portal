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
        'Access-Control-Allow-Headers' = 'Authorization,Content-Type'
        'Vary'                         = 'Origin'
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

$requiredVars = @('AZURE_OPENAI_API_KEY', 'AZURE_OPENAI_ENDPOINT', 'AZURE_OPENAI_DEPLOYMENT')
$missing = @()
foreach ($v in $requiredVars) {
    if (-not [Environment]::GetEnvironmentVariable($v)) { $missing += $v }
}

$body = @{
    status     = 'ok'
    timestamp  = (Get-Date).ToUniversalTime().ToString('o')
    functionApp = @{
        name     = $env:WEBSITE_SITE_NAME
        slot     = $env:WEBSITE_SLOT_NAME
    }
    openAi     = @{
        configured = ($missing.Count -eq 0)
        missing    = $missing
        apiVersion = $env:AZURE_OPENAI_API_VERSION
    }
} | ConvertTo-Json -Depth 6

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = 200
    Body       = $body
    Headers    = $corsHeaders
})
