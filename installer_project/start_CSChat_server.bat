@echo off
setlocal
cd /d "%~dp0"

echo [CSChat Server Starting...]
echo Current Directory: %CD%

:: Check if PowerShell tray script exists
:: Check if PowerShell tray script exists (DISABLED due to stability issues)
if exist "%~dp0server_tray_DISABLED.ps1" (
    echo [INFO] Starting server in Tray Mode...
    :: Launch PowerShell in STA mode (Critical for WinForms)
    powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0server_tray.ps1" > "%~dp0server_startup.log" 2>&1
    
    if %ERRORLEVEL% NEQ 0 (
        echo [ERROR] PowerShell script exited with error %ERRORLEVEL%.
        echo Check server_startup.log for details.
        type "%~dp0server_startup.log"
        pause
    )
    exit /b %ERRORLEVEL%
)

:: Fallback: Normal Mode (if script missing)
if exist "%~dp0node.exe" (
    set "NODE_PATH=%~dp0node.exe"
    echo [INFO] Using bundled Node.exe
) else (
    where node >nul 2>nul
    if %ERRORLEVEL% NEQ 0 (
        echo [ERROR] Node.js not found.
        pause
        exit /b 1
    )
    set "NODE_PATH=node"
)

"%NODE_PATH%" index.js
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Server crashed with error code %ERRORLEVEL%.
    pause
)
