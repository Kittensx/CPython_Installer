@echo off
setlocal
cd /d "%~dp0"
title CPython Installer Builder v1.0.0

if not exist "%~dp0builder\builder_wizard.ps1" (
    echo [ERROR] The builder files are missing.
    echo Expected: "%~dp0builder\builder_wizard.ps1"
    echo.
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
  -File "%~dp0builder\builder_wizard.ps1" ^
  -ConfigPath "%~dp0builder\builder_config.json"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" echo The guided builder exited with code %RC%.
pause
exit /b %RC%
