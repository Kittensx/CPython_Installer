@echo off
setlocal
cd /d "%~dp0.."
title CPython Builder - Prerequisites
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\builder\setup_build_prerequisites.ps1" -ConfigPath "%~dp0..\builder\builder_config.json"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo Command exited with code %RC%.
pause
exit /b %RC%
