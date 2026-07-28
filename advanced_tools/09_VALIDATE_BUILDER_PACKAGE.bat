@echo off
setlocal
cd /d "%~dp0.."
title CPython Builder - Validate Package

where py >nul 2>nul
if not errorlevel 1 (
    py -3 "%~dp0..\builder\tests\validate_package.py"
) else (
    python "%~dp0..\builder\tests\validate_package.py"
)
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo Package validation failed with code %RC%.
pause
exit /b %RC%
