@echo off
setlocal
cd /d "%~dp0.."
title CPython Builder - Legacy WiX Dependency
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\builder\install_legacy_wix_netfx35.ps1" -ConfigPath "%~dp0..\builder\builder_config.json"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo Command exited with code %RC%.
pause
exit /b %RC%
