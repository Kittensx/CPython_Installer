[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = '',

    [Parameter(Mandatory = $false)]
    [switch]$Elevated,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptPath = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($scriptPath) -and
    $null -ne $MyInvocation.MyCommand -and
    -not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    $scriptPath = $MyInvocation.MyCommand.Path
}

$scriptDirectory = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDirectory) -and
    -not [string]::IsNullOrWhiteSpace($scriptPath)) {
    $scriptDirectory = Split-Path -Parent $scriptPath
}
if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
    $scriptDirectory = (Get-Location).ProviderPath
}
$scriptDirectory = [System.IO.Path]::GetFullPath($scriptDirectory)

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptDirectory 'builder_config.json'
}

$script:TranscriptStarted = $false

function Start-OptionalTranscript {
    if ([string]::IsNullOrWhiteSpace($LogPath)) { return }
    try {
        $parent = Split-Path -Parent $LogPath
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Start-Transcript -LiteralPath $LogPath -Force | Out-Null
        $script:TranscriptStarted = $true
    }
    catch {
        Write-Host ("[WARN] Could not start prerequisite transcript: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Stop-OptionalTranscript {
    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
        $script:TranscriptStarted = $false
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-LegacyWixMsBuildDependency {
    $assemblyName = 'Microsoft.Build.Utilities, Version=2.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a'
    try {
        $assembly = [System.Reflection.Assembly]::Load($assemblyName)
        return [pscustomobject]@{
            Available = $true
            Location = $assembly.Location
            Error = ''
        }
    }
    catch {
        return [pscustomobject]@{
            Available = $false
            Location = ''
            Error = $_.Exception.Message
        }
    }
}

function Get-GitPath {
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) { return [string]$git.Source }
    return ''
}

function Get-VsWherePath {
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates.Add((Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe'))
    }
    $command = Get-Command vswhere.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates.Add([string]$command.Source) }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    return ''
}

function Get-VisualStudioBuildToolsPath {
    $vswhere = Get-VsWherePath
    if ([string]::IsNullOrWhiteSpace($vswhere)) { return '' }

    $output = & $vswhere -latest -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) { return '' }

    $candidate = ([string]($output | Select-Object -First 1)).Trim()
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Container)) {
        return [System.IO.Path]::GetFullPath($candidate)
    }
    return ''
}

function Get-PrerequisiteState {
    $gitPath = Get-GitPath
    $visualStudioPath = Get-VisualStudioBuildToolsPath
    $legacyWix = Test-LegacyWixMsBuildDependency

    return [pscustomobject]@{
        GitPath = $gitPath
        GitAvailable = -not [string]::IsNullOrWhiteSpace($gitPath)
        VisualStudioPath = $visualStudioPath
        VisualStudioAvailable = -not [string]::IsNullOrWhiteSpace($visualStudioPath)
        LegacyWix = $legacyWix
        LegacyWixAvailable = [bool]$legacyWix.Available
    }
}

function Show-PrerequisiteState {
    param([object]$State)

    Write-Host ''
    Write-Host 'Current prerequisite state:' -ForegroundColor Cyan
    if ($State.GitAvailable) {
        Write-Host ("  [OK] Git: {0}" -f $State.GitPath) -ForegroundColor Green
    }
    else {
        Write-Host '  [MISSING] Git' -ForegroundColor Yellow
    }

    if ($State.VisualStudioAvailable) {
        Write-Host ("  [OK] Visual Studio 2022 C++ tools: {0}" -f $State.VisualStudioPath) -ForegroundColor Green
    }
    else {
        Write-Host '  [MISSING] Visual Studio 2022 Build Tools with C++ tools' -ForegroundColor Yellow
    }

    if ($State.LegacyWixAvailable) {
        $location = if ([string]::IsNullOrWhiteSpace([string]$State.LegacyWix.Location)) { 'Global Assembly Cache' } else { [string]$State.LegacyWix.Location }
        Write-Host ("  [OK] Legacy WiX/.NET dependency: {0}" -f $location) -ForegroundColor Green
    }
    else {
        Write-Host '  [MISSING] Legacy WiX/.NET Framework 3.5 dependency' -ForegroundColor Yellow
        if (-not [string]::IsNullOrWhiteSpace([string]$State.LegacyWix.Error)) {
            Write-Host ("            {0}" -f $State.LegacyWix.Error) -ForegroundColor DarkYellow
        }
    }
}

function Quote-PowerShellLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-ElevatedRepair {
    param([string]$ResolvedConfigPath)

    $logDirectory = Join-Path $scriptDirectory 'logs'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $elevatedLog = Join-Path $logDirectory ("setup_build_prerequisites_elevated_{0}.log" -f $stamp)

    $scriptLiteral = Quote-PowerShellLiteral -Value $scriptPath
    $configLiteral = Quote-PowerShellLiteral -Value $ResolvedConfigPath
    $logLiteral = Quote-PowerShellLiteral -Value $elevatedLog
    $command = "& $scriptLiteral -ConfigPath $configLiteral -Elevated -LogPath $logLiteral; exit `$LASTEXITCODE"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))

    Write-Host ''
    Write-Host 'Administrator access is required only for the missing components.' -ForegroundColor Yellow
    Write-Host 'Approve the Windows UAC prompt; progress will return to this window.' -ForegroundColor Yellow

    try {
        $process = Start-Process -FilePath 'powershell.exe' `
            -Verb RunAs `
            -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
    }
    catch {
        throw "Administrator launch was cancelled or failed: $($_.Exception.Message)"
    }

    Write-Host ''
    if (Test-Path -LiteralPath $elevatedLog -PathType Leaf) {
        Write-Host ("--- Elevated prerequisite log: {0} ---" -f $elevatedLog) -ForegroundColor Cyan
        Get-Content -LiteralPath $elevatedLog | Write-Host
        Write-Host '--- End elevated prerequisite log ---' -ForegroundColor Cyan
    }
    else {
        Write-Host ("[WARN] Elevated prerequisite log was not created: {0}" -f $elevatedLog) -ForegroundColor Yellow
    }

    if ($process.ExitCode -ne 0) {
        throw "Elevated prerequisite repair failed with exit code $($process.ExitCode). Review: $elevatedLog"
    }
}

function Invoke-WingetInstall {
    param(
        [string]$Id,
        [string]$Override = ''
    )

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'WinGet was not found. Install or update Microsoft App Installer, then run this step again.'
    }

    $arguments = @(
        'install', '--id', $Id, '--exact', '--source', 'winget',
        '--accept-source-agreements', '--accept-package-agreements',
        '--disable-interactivity'
    )
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $arguments += @('--override', $Override)
    }

    Write-Host ("winget {0}" -f ($arguments -join ' ')) -ForegroundColor Cyan
    & winget.exe @arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "WinGet failed while installing $Id (exit code $exitCode)."
    }
}

function Enable-LegacyWixDependency {
    $osBuild = [Environment]::OSVersion.Version.Build
    if ($osBuild -ge 28000) {
        throw 'Windows build 28000 or later requires the separate Microsoft .NET Framework 3.5 installer. Install it, restart Windows, and rerun preflight.'
    }

    $feature = Get-WindowsOptionalFeature -Online -FeatureName NetFx3
    if ($feature.State -eq 'Enabled') {
        Write-Host '.NET Framework 3.5 is already enabled.' -ForegroundColor Green
        return $false
    }

    Write-Host 'Enabling .NET Framework 3.5 (NetFx3)...' -ForegroundColor Cyan
    $enableResult = Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart
    Write-Host ('.NET Framework 3.5 enable result: {0}' -f $enableResult.State) -ForegroundColor Green
    return [bool]$enableResult.RestartNeeded
}

Start-OptionalTranscript
try {
    $resolvedConfigPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
    if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
        throw "Configuration file not found: $resolvedConfigPath"
    }

    # Parse the configuration now so malformed JSON is reported before any UAC
    # prompt or installation attempt.
    [void](Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json)

    $state = Get-PrerequisiteState
    Show-PrerequisiteState -State $state

    $needsRepair = -not ($state.GitAvailable -and $state.VisualStudioAvailable -and $state.LegacyWixAvailable)
    if (-not $needsRepair) {
        Write-Host ''
        Write-Host 'All system prerequisites are already available; no Administrator relaunch is required.' -ForegroundColor Green
        Stop-OptionalTranscript
        exit 0
    }

    if (-not (Test-Administrator)) {
        Stop-OptionalTranscript
        Invoke-ElevatedRepair -ResolvedConfigPath $resolvedConfigPath

        $recheckedState = Get-PrerequisiteState
        Show-PrerequisiteState -State $recheckedState
        if (-not ($recheckedState.GitAvailable -and $recheckedState.VisualStudioAvailable -and $recheckedState.LegacyWixAvailable)) {
            Write-Host ''
            Write-Host 'One or more prerequisites still require attention. A Windows restart may be required after enabling .NET Framework 3.5.' -ForegroundColor Yellow
        }
        exit 0
    }

    $restartRequired = $false

    if (-not $state.GitAvailable) {
        Write-Host ''
        Write-Host 'Installing Git...' -ForegroundColor Cyan
        Invoke-WingetInstall -Id 'Git.Git'
    }
    else {
        Write-Host 'Git is already installed; skipping WinGet.' -ForegroundColor DarkGray
    }

    if (-not $state.VisualStudioAvailable) {
        Write-Host ''
        Write-Host 'Installing Visual Studio 2022 Build Tools with Desktop C++ tools...' -ForegroundColor Cyan
        $vsOverride = '--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.Net.Component.3.5.DeveloperTools --includeRecommended'
        Invoke-WingetInstall -Id 'Microsoft.VisualStudio.2022.BuildTools' -Override $vsOverride
    }
    else {
        Write-Host 'Visual Studio 2022 C++ tools are already installed; skipping WinGet.' -ForegroundColor DarkGray
    }

    if (-not $state.LegacyWixAvailable) {
        Write-Host ''
        Write-Host 'Repairing the legacy WiX/.NET Framework dependency...' -ForegroundColor Cyan
        $restartRequired = Enable-LegacyWixDependency
    }
    else {
        Write-Host 'Legacy WiX/.NET dependency is already available; skipping NetFx3 repair.' -ForegroundColor DarkGray
    }

    $finalState = Get-PrerequisiteState
    Show-PrerequisiteState -State $finalState

    Write-Host ''
    if ($restartRequired -or -not $finalState.LegacyWixAvailable) {
        Write-Host 'A Windows restart may be required before the legacy WiX task can load. Restart, then run preflight_only.bat.' -ForegroundColor Yellow
    }
    else {
        Write-Host 'System prerequisite setup completed successfully.' -ForegroundColor Green
    }

    Stop-OptionalTranscript
    exit 0
}
catch {
    Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
    Stop-OptionalTranscript
    exit 1
}
