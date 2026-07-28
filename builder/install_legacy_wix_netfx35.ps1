[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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

$scriptPath = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($scriptPath)) {
    $scriptPath = $MyInvocation.MyCommand.Path
}

try {
    if (-not (Test-Administrator)) {
        Write-Host 'Restarting as Administrator...' -ForegroundColor Yellow
        $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        exit $process.ExitCode
    }

    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host 'Legacy WiX / .NET Framework 3.5 Compatibility Setup' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''

    $existing = Test-LegacyWixMsBuildDependency
    if ($existing.Available) {
        $location = if ([string]::IsNullOrWhiteSpace($existing.Location)) { 'Global Assembly Cache' } else { $existing.Location }
        Write-Host ("[OK] Microsoft.Build.Utilities 2.0 is already available: {0}" -f $location) -ForegroundColor Green
        exit 0
    }

    $osBuild = [Environment]::OSVersion.Version.Build
    Write-Host ("Windows build: {0}" -f $osBuild)

    if ($osBuild -ge 28000) {
        Write-Host ''
        Write-Host '[ERROR] This Windows generation uses the standalone .NET Framework 3.5 installer.' -ForegroundColor Red
        Write-Host 'Install the Microsoft .NET Framework 3.5 package for Windows 11 26H1 or later, restart Windows, then run preflight_only.bat.' -ForegroundColor Yellow
        Write-Host 'Microsoft instructions: https://learn.microsoft.com/dotnet/framework/install/dotnet-35-windows-11' -ForegroundColor Yellow
        exit 4
    }

    Write-Host 'Enabling the NetFx3 Windows feature through DISM...' -ForegroundColor Cyan
    & dism.exe /Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart
    $dismExitCode = $LASTEXITCODE
    if ($dismExitCode -ne 0 -and $dismExitCode -ne 3010) {
        throw "DISM failed while enabling NetFx3 (exit code $dismExitCode)."
    }

    $feature = Get-WindowsOptionalFeature -Online -FeatureName NetFx3
    Write-Host ("NetFx3 feature state: {0}" -f $feature.State)

    $probe = Test-LegacyWixMsBuildDependency
    if ($probe.Available) {
        $location = if ([string]::IsNullOrWhiteSpace($probe.Location)) { 'Global Assembly Cache' } else { $probe.Location }
        Write-Host ("[OK] Legacy WiX dependency is now available: {0}" -f $location) -ForegroundColor Green
        exit 0
    }

    Write-Host ''
    Write-Host '[WARN] NetFx3 was enabled, but the current PowerShell process still cannot load Microsoft.Build.Utilities 2.0.' -ForegroundColor Yellow
    Write-Host ("Loader error: {0}" -f $probe.Error) -ForegroundColor Yellow
    Write-Host 'Restart Windows, then run preflight_only.bat. A restart is commonly required after enabling this legacy component.' -ForegroundColor Yellow
    exit 3010
}
catch {
    Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
