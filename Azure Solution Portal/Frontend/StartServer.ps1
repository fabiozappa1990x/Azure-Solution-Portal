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
        # HOMEPAGE → setup.html (pagina prerequisiti, nuova entry point)
        # ========================================
        if ($path -eq '' -or $path -eq 'setup.html') {
            $filePath = Join-Path $root 'setup.html'
            if (Test-Path $filePath) {
                $body = [System.IO.File]::ReadAllText($filePath)
                Write-Response -Response $response -Body $body -ContentType 'text/html; charset=utf-8'
                Write-Log "✓ Servito setup.html" "INFO"
            } else {
                Write-Log "✗ setup.html non trovato: $filePath" "ERROR"
                Write-Response -Response $response -Body 'setup.html non trovato' -StatusCode 404
            }
            continue
        }

        # ========================================
        # PORTALE SOLUZIONI
        # ========================================
        if ($path -eq 'index.html') {
            $filePath = Join-Path $root 'index.html'
            if (Test-Path $filePath) {
                $body = [System.IO.File]::ReadAllText($filePath)
                Write-Response -Response $response -Body $body -ContentType 'text/html; charset=utf-8'
                Write-Log "✓ Servito index.html" "INFO"
            } else {
                Write-Log "✗ index.html non trovato: $filePath" "ERROR"
                Write-Response -Response $response -Body 'index.html non trovato' -StatusCode 404
            }
            continue
        }

        # ========================================
        # STATIC FILES (CSS, JS)
        # ========================================
        if ($path -match '^(styles\.css|script\.js|setup\.js)$') {
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
        # API PRECHECK → gestita dalla Azure Function deployata, non da qui.
        # Se ricevi questa route significa che API_BASE_URL punta ancora a localhost.
        # ========================================
        if ($path -like 'api/*') {
            Write-Log "⚠️ Ricevuta chiamata API su server statico: $path — le API devono chiamare la Azure Function" "WARN"
            Write-Response -Response $response -Body (@{
                error = "Questo server serve solo file statici. Le chiamate API devono puntare alla Azure Function."
                hint  = "Verifica API_BASE_URL in script.js"
            } | ConvertTo-Json) -ContentType 'application/json' -StatusCode 501
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