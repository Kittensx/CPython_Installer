@echo off
setlocal
cd /d "%~dp0.."
title CPython Builder - Documentation Requirements
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\builder\setup_python_requirements.ps1" -ConfigPath "%~dp0..\builder\builder_config.json" -RequirementsPath "%~dp0..\builder\requirements-optional.txt"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo Command exited with code %RC%.
pause
exit /b %RC%
