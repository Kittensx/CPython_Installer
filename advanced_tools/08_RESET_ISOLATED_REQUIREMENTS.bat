@echo off
setlocal
cd /d "%~dp0.."
title CPython Builder - Reset Isolated Requirements
set "VENV=%~dp0..\runtime\.builder_requirements_venv"

echo This removes only the builder's isolated documentation environment:
echo   "%VENV%"
echo.
echo It does not remove or change your normal Python installations.
echo.
set /p "ANSWER=Continue? [y/N]: "
if /i not "%ANSWER%"=="y" if /i not "%ANSWER%"=="yes" exit /b 0

if exist "%VENV%" rmdir /s /q "%VENV%"
if exist "%VENV%" (
    echo [ERROR] The folder could not be removed. Close programs using it and retry.
    pause
    exit /b 1
)

echo [OK] Isolated requirements environment removed.
echo Run START_HERE.bat and choose the documentation-requirements step to recreate it.
pause
exit /b 0
