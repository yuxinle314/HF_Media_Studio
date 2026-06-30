@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

where powershell >nul 2>nul
if errorlevel 1 (
  echo PowerShell was not found. Please use Windows 10/11 or install PowerShell.
  pause
  exit /b 1
)

echo.
echo 请选择服务访问模式:
echo   1. 本机模式 - 只允许这台电脑访问
echo   2. 局域网模式 - 同一交换机/路由器下的设备可访问
echo.
set "MODE=Local"
set /p "CHOICE=输入 1 或 2 后回车，直接回车默认本机模式: "
if "%CHOICE%"=="2" set "MODE=Lan"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\serve-local.ps1" -Port 8080 -Mode %MODE%
if errorlevel 1 (
  echo.
  echo Failed to start the local server.
  pause
)
