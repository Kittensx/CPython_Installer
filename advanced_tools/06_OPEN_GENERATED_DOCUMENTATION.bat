@echo off
setlocal
cd /d "%~dp0.."
title CPython Builder - Open Documentation
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\builder\open_documentation.ps1" -ConfigPath "%~dp0..\builder\builder_config.json"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo Command exited with code %RC%.
pause
exit /b %RC%
