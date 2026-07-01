@echo off
setlocal
cd /d "%~dp0"

where powershell >nul 2>nul
if errorlevel 1 (
  echo PowerShell was not found. Please use Windows 10/11 or install PowerShell.
  pause
  exit /b 1
)

echo.
echo Select service access mode:
echo   1. Local mode - only this computer can access
echo   2. LAN mode - devices on the same router/switch can access
echo.
set "MODE=Local"
set /p "CHOICE=Enter 1 or 2, press Enter for Local mode: "
if "%CHOICE%"=="2" set "MODE=Lan"

echo.
echo Login is required.
echo Username: cuc
echo Password: ecdav

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\serve-local.ps1" -Port 8080 -Mode "%MODE%"
if errorlevel 1 (
  echo.
  echo Failed to start the local server.
  pause
)
