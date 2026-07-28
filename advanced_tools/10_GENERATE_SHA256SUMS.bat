@echo off
setlocal EnableExtensions
cd /d "%~dp0"

echo ============================================================
echo Generate SHA256SUMS.txt
echo ============================================================
echo.
echo This hashes every file in this folder except SHA256SUMS.txt
echo and this generator script.
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$excluded=@('SHA256SUMS.txt','GENERATE_SHA256SUMS.bat');" ^
  "$files=Get-ChildItem -LiteralPath . -File | Where-Object { $excluded -notcontains $_.Name } | Sort-Object Name;" ^
  "if(-not $files){ throw 'No release files were found in this folder.' };" ^
  "$lines=foreach($file in $files){ $hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); '{0}  {1}' -f $hash,$file.Name };" ^
  "[System.IO.File]::WriteAllLines((Join-Path (Get-Location) 'SHA256SUMS.txt'),[string[]]$lines,(New-Object System.Text.ASCIIEncoding));" ^
  "Write-Host ''; Write-Host 'Created:' (Join-Path (Get-Location) 'SHA256SUMS.txt') -ForegroundColor Green;" ^
  "Write-Host ''; $lines | ForEach-Object { Write-Host $_ }"

if errorlevel 1 (
    echo.
    echo [ERROR] SHA-256 generation failed.
    pause
    exit /b 1
)

echo.
echo Upload SHA256SUMS.txt with the exact files that were hashed.
pause
exit /b 0
