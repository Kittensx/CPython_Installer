[CmdletBinding()]
param(
    [string]$ConfigPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptDirectory = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptDirectory 'builder_config.json'
}

function Resolve-ConfigPathValue {
    param([string]$Value, [string]$BaseDirectory)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Value)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $expanded))
}

try {
    $resolvedConfig = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
    $configDirectory = Split-Path -Parent $resolvedConfig
    $config = Get-Content -LiteralPath $resolvedConfig -Raw | ConvertFrom-Json
    $candidates = New-Object System.Collections.Generic.List[string]

    $outputDirectory = Resolve-ConfigPathValue -Value ([string]$config.output_dir) -BaseDirectory $configDirectory
    if (Test-Path -LiteralPath $outputDirectory -PathType Container) {
        $copiedIndexes = Get-ChildItem -LiteralPath $outputDirectory -Recurse -File -Filter 'index.html' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '(?i)\\documentation\\(html|htmlhelp)\\index\.html$' } |
            Sort-Object LastWriteTimeUtc -Descending
        foreach ($index in $copiedIndexes) { $candidates.Add($index.FullName) }
    }

    $sourceDirectory = Resolve-ConfigPathValue -Value ([string]$config.source_dir) -BaseDirectory $configDirectory
    if (-not [string]::IsNullOrWhiteSpace($sourceDirectory)) {
        foreach ($target in @('html', 'htmlhelp')) {
            $candidate = Join-Path $sourceDirectory ("Doc\build\{0}\index.html" -f $target)
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidates.Add($candidate) }
        }
    }

    $indexPath = $candidates | Select-Object -First 1
    if (-not $indexPath) {
        throw 'No generated documentation index was found in the output folder or configured source tree.'
    }

    Write-Host ("Opening documentation: {0}" -f $indexPath) -ForegroundColor Green
    Start-Process -FilePath $indexPath
    exit 0
}
catch {
    Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
