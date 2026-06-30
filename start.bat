@echo off
setlocal
cd /d "%~dp0"

where powershell >nul 2>nul
if errorlevel 1 (
  echo PowerShell was not found. Please use Windows 10/11 or install PowerShell.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\serve-local.ps1" -Port 8080
if errorlevel 1 (
  echo.
  echo Failed to start the local server.
  pause
)
