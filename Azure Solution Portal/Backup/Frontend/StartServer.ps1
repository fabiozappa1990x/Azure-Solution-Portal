param([int]$Port = 8787)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Web

# LOG FILE
$logFile = Join-Path $PSScriptRoot "server-log.txt"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage -ForegroundColor $(if($Level -eq "ERROR"){"Red"}elseif($Level -eq "WARN"){"Yellow"}else{"Green"})
    Add-Content -Path $logFile -Value $logMessage
}

function Get-ContentType {
    param([string]$Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLower()) {
        '.html' { 'text/html; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        '.js'   { 'application/javascript; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' }
        '.txt'  { 'text/plain; charset=utf-8' }
        '.csv'  { 'text/csv; charset=utf-8' }
        default { 'application/octet-stream' }
    }
}

function Write-Response {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [string]$Body,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [int]$StatusCode = 200
    )
    $Response.StatusCode = $StatusCode
    $Response.Headers.Add('Access-Control-Allow-Origin','*')
    $Response.Headers.Add('Access-Control-Allow-Methods','GET, POST, OPTIONS')
    $Response.Headers.Add('Access-Control-Allow-Headers','Content-Type, Authorization')
    $Response.ContentType = $ContentType
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Response.OutputStream.Write($bytes,0,$bytes.Length)
    $Response.OutputStream.Close()
}

$listener = [System.Net.HttpListener]::new()
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()

# LA ROOT È LA CARTELLA Frontend (dove si trova lo script)
$root = $PSScriptRoot
# LA ROOT DEL PROGETTO È UNA CARTELLA SOPRA
$projectRoot = Split-Path $PSScriptRoot -Parent

Write-Log "🚀 Server avviato su $prefix" "INFO"
Write-Log "📁 Frontend directory: $root" "INFO"
Write-Log "📁 Project root: $projectRoot" "INFO"
Write-Log "📝 Log file: $logFile" "INFO"

while ($true) {
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        if ($request.HttpMethod -eq 'OPTIONS') {
            Write-Response -Response $response -Body '' -StatusCode 200
            continue
        }

        $rawUrl = $request.RawUrl
        $uri = [System.Uri]::new("http://localhost" + $rawUrl)
        $path = $uri.AbsolutePath.TrimStart('/')

        Write-Log "📥 Request: $($request.HttpMethod) $path" "INFO"

        # ========================================
        # HOMEPAGE
        # ========================================
        if ($path -eq '' -or $path -eq 'index.html') {
            $filePath = Join-Path $root 'index.html'
            if (Test-Path $filePath) {
                $body = [System.IO.File]::ReadAllText($filePath)
                Write-Response -Response $response -Body $body -ContentType 'text/html; charset=utf-8'
                Write-Log "✓ Servito index.html" "INFO"
            } else {
                Write-Log "✗ index.html non trovato in: $filePath" "ERROR"
                Write-Response -Response $response -Body 'index.html non trovato' -StatusCode 404
            }
            continue
        }

        # ========================================
        # STATIC FILES (CSS, JS)
        # ========================================
        if ($path -match '^(styles\.css|script\.js)$') {
            $filePath = Join-Path $root $path
            if (Test-Path $filePath) {
                $body = [System.IO.File]::ReadAllText($filePath)
                Write-Response -Response $response -Body $body -ContentType (Get-ContentType -Path $filePath)
                Write-Log "✓ Servito file: $path" "INFO"
            } else {
                Write-Log "✗ File non trovato: $filePath" "ERROR"
                Write-Response -Response $response -Body "File non trovato: $path" -StatusCode 404
            }
            continue
        }

        # ========================================
        # API PRECHECK - CON TOKEN
        # ========================================
        if ($path -eq 'api/precheck') {
            # ESTRAI TOKEN DALL'HEADER
            $authHeader = $request.Headers['Authorization']
            
            if (-not $authHeader -or -not $authHeader.StartsWith('Bearer ')) {
                Write-Log "✗ Token mancante" "ERROR"
                Write-Response -Response $response -Body (@{ error = "Token mancante. Effettua il login." } | ConvertTo-Json) -ContentType 'application/json' -StatusCode 401
                continue
            }

            $accessToken = $authHeader.Substring(7)
            Write-Log "✓ Token ricevuto (lunghezza: $($accessToken.Length))" "INFO"

            $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
            $subscriptionId = $query['subscriptionId']

            if (-not $subscriptionId) {
                Write-Log "✗ SubscriptionId mancante" "ERROR"
                Write-Response -Response $response -Body '{"error":"SubscriptionId mancante"}' -ContentType 'application/json' -StatusCode 400
                continue
            }

            Write-Log "🔍 Esecuzione precheck per subscription: $subscriptionId" "INFO"

            # AUTENTICA CON IL TOKEN
            try {
                Write-Log "🔐 Autenticazione ad Azure con token..." "INFO"
                $secureToken = ConvertTo-SecureString -String $accessToken -AsPlainText -Force
                Connect-AzAccount -AccessToken $secureToken -AccountId "user@domain.com" -SubscriptionId $subscriptionId -ErrorAction Stop
                Write-Log "✓ Autenticato ad Azure" "INFO"
            } catch {
                Write-Log "✗ Errore autenticazione: $($_.Exception.Message)" "ERROR"
                Write-Response -Response $response -Body (@{ 
                    error = "Errore autenticazione ad Azure"
                    details = $_.Exception.Message
                } | ConvertTo-Json) -ContentType 'application/json' -StatusCode 401
                continue
            }

            # LO SCRIPT È IN ../scripts/testluca.ps1
            $scriptPath = Join-Path $projectRoot 'scripts/testluca.ps1'
            
            if (-not (Test-Path $scriptPath)) {
                $errorMsg = "Script testluca.ps1 non trovato in: $scriptPath"
                Write-Log "✗ $errorMsg" "ERROR"
                Write-Response -Response $response -Body (@{ error = $errorMsg } | ConvertTo-Json) -ContentType 'application/json' -StatusCode 500
                Disconnect-AzAccount -ErrorAction SilentlyContinue
                continue
            }

            Write-Log "✓ Script trovato: $scriptPath" "INFO"

            # OUTPUT IN ../scripts/
            $outHtml = Join-Path $projectRoot 'scripts/AzureMonitorReport.html'
            $outJson = Join-Path $projectRoot 'scripts/AzureMonitorReport.json'

            if (Test-Path $outJson) { Remove-Item $outJson -Force }
            if (Test-Path $outHtml) { Remove-Item $outHtml -Force }

            try {
                Write-Log "▶ Esecuzione script..." "INFO"
                $scriptOutput = & $scriptPath -SubscriptionId $subscriptionId -OutputPath $outHtml 2>&1
                Write-Log "✓ Script completato" "INFO"

            } catch {
                Write-Log "✗ Errore esecuzione script: $($_.Exception.Message)" "ERROR"
                Write-Response -Response $response -Body (@{ 
                    error = "Errore esecuzione script"
                    details = $_.Exception.Message
                } | ConvertTo-Json) -ContentType 'application/json' -StatusCode 500
                Disconnect-AzAccount -ErrorAction SilentlyContinue
                continue
            }

            if (Test-Path $outJson) {
                try {
                    $jsonData = [System.IO.File]::ReadAllText($outJson)
                    Write-Log "✓ JSON caricato ($($jsonData.Length) bytes)" "INFO"
                    Write-Response -Response $response -Body $jsonData -ContentType 'application/json'
                } catch {
                    Write-Log "✗ Errore lettura JSON: $($_.Exception.Message)" "ERROR"
                    Write-Response -Response $response -Body (@{ error = "Errore lettura JSON" } | ConvertTo-Json) -ContentType 'application/json' -StatusCode 500
                }
            } else {
                Write-Log "✗ JSON non generato in: $outJson" "ERROR"
                
                $generatedFiles = Get-ChildItem -Path (Join-Path $projectRoot 'scripts') -Filter "*.json" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
                Write-Log "File JSON presenti in scripts/: $($generatedFiles -join ', ')" "WARN"
                
                Write-Response -Response $response -Body (@{ 
                    error = "JSON non generato"
                    expectedPath = $outJson
                    generatedFiles = $generatedFiles
                } | ConvertTo-Json) -ContentType 'application/json' -StatusCode 500
            }

            Disconnect-AzAccount -ErrorAction SilentlyContinue
            Write-Log "🔌 Disconnesso da Azure" "INFO"
            continue
        }

        # ========================================
        # 404
        # ========================================
        Write-Log "✗ Route non trovata: $path" "WARN"
        Write-Response -Response $response -Body "Not Found: $path" -StatusCode 404

    } catch {
        $errorMsg = $_.Exception.Message
        Write-Log "✗ Errore server: $errorMsg" "ERROR"
        try { 
            Write-Response -Response $response -Body (@{ error = $errorMsg } | ConvertTo-Json) -ContentType 'application/json' -StatusCode 500 
        } catch {
            Write-Log "✗ Impossibile inviare risposta di errore" "ERROR"
        }
    }
}