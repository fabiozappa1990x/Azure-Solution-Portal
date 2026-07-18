@echo off
REM ============================================================
REM  Azure Solution Portal - Deploy to Customer Azure (one-click)
REM  Doppio-click su questo file per distribuire l'intera suite
REM  sul tenant/sottoscrizione Azure con cui effettui il login.
REM ============================================================
setlocal
cd /d "%~dp0"

where az >nul 2>nul
if errorlevel 1 (
    echo [ERRORE] Azure CLI ^(az^) non trovata.
    echo Installa da https://aka.ms/installazurecli e rilancia.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Deploy-ToAzure.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo Deploy completato.
) else (
    echo Deploy terminato con errori ^(codice %RC%^). Controlla l'output sopra.
)
pause
endlocal
