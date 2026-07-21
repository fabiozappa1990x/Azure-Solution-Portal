@echo off
REM ============================================================
REM  Azure Solution Portal - Avvio locale
REM  Serve il frontend su http://localhost:8787 e apre il browser.
REM  Le chiamate API puntano alla Azure Function (vedi API_BASE_URL
REM  in script.js): non serve backend locale.
REM ============================================================
setlocal
set "PORT=8787"
set "FRONTEND=%~dp0Azure Solution Portal\Frontend"

if not exist "%FRONTEND%\StartServer.ps1" (
    echo [ERRORE] StartServer.ps1 non trovato in "%FRONTEND%"
    pause
    exit /b 1
)

echo ============================================================
echo   Azure Solution Portal
echo   URL:  http://localhost:%PORT%
echo   Dir:  %FRONTEND%
echo ============================================================
echo.

cd /d "%FRONTEND%"

REM Preferisci PowerShell 7 (pwsh); fallback a Windows PowerShell 5.1
set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

REM Server in una finestra dedicata
start "Azure Solution Portal - Server" %PSEXE% -ExecutionPolicy Bypass -NoProfile -File "StartServer.ps1" -Port %PORT%

REM Attendi che il listener sia pronto, poi apri il browser
timeout /t 3 /nobreak >nul
start "" "http://localhost:%PORT%"

echo Server avviato in una finestra separata. Chiudi quella finestra per fermarlo.
endlocal
