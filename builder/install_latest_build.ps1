[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'builder_config.json')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    $resolvedConfig = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
    $configDirectory = Split-Path -Parent $resolvedConfig
    $config = Get-Content -LiteralPath $resolvedConfig -Raw | ConvertFrom-Json
    $outputValue = [Environment]::ExpandEnvironmentVariables([string]$config.output_dir)
    if ([System.IO.Path]::IsPathRooted($outputValue)) {
        $outputDirectory = [System.IO.Path]::GetFullPath($outputValue)
    }
    else {
        $outputDirectory = [System.IO.Path]::GetFullPath((Join-Path $configDirectory $outputValue))
    }

    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        throw "Output directory does not exist: $outputDirectory"
    }

    $candidates = Get-ChildItem -LiteralPath $outputDirectory -Recurse -File -Filter 'python-*.exe' |
        Where-Object { $_.Name -notmatch '(?i)(venvlauncher|pythonw|launcher|test)' } |
        Sort-Object LastWriteTimeUtc -Descending

    $installer = $candidates | Select-Object -First 1
    if (-not $installer) {
        throw "No Python installer EXE was found below: $outputDirectory"
    }

    Write-Host "Launching installer:" -ForegroundColor Cyan
    Write-Host $installer.FullName -ForegroundColor Green
    Write-Host ''
    Write-Host 'The safe private build is intended for side-by-side installation. Choose a new install directory and verify it before removing an older Python.' -ForegroundColor Yellow
    $process = Start-Process -FilePath $installer.FullName -Wait -PassThru
    exit $process.ExitCode
}
catch {
    Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
