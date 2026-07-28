[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'builder_config.json'),

    [Parameter(Mandatory = $false)]
    [switch]$PreflightOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Stage {
    param([string]$Message)
    Write-Host ""
    Write-Host ("=== {0} ===" -f $Message) -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host ("[OK] {0}" -f $Message) -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host ("[WARN] {0}" -f $Message) -ForegroundColor Yellow
}

function Stop-Build {
    param([string]$Message, [int]$ExitCode = 1)
    Write-Host ("[ERROR] {0}" -f $Message) -ForegroundColor Red
    exit $ExitCode
}

function Get-ConfigValue {
    param(
        [object]$Object,
        [string]$PropertyName,
        $DefaultValue
    )

    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$PropertyName]) {
        return $Object.$PropertyName
    }
    return $DefaultValue
}

function Resolve-ConfiguredPath {
    param(
        [string]$PathValue,
        [string]$BaseDirectory
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return ''
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $expanded))
}

function Get-CpythonVersion {
    param([string]$SourceDirectory)

    $patchLevel = Join-Path $SourceDirectory 'Include\patchlevel.h'
    if (-not (Test-Path -LiteralPath $patchLevel -PathType Leaf)) {
        throw "Cannot determine the CPython version because Include\patchlevel.h is missing."
    }

    $text = Get-Content -LiteralPath $patchLevel -Raw
    $values = @{}
    foreach ($name in @('PY_MAJOR_VERSION', 'PY_MINOR_VERSION', 'PY_MICRO_VERSION')) {
        $match = [regex]::Match($text, "(?m)^\s*#define\s+$name\s+(\d+)\s*$")
        if (-not $match.Success) {
            throw "Cannot parse $name from Include\patchlevel.h."
        }
        $values[$name] = [int]$match.Groups[1].Value
    }

    $serial = 0
    $serialMatch = [regex]::Match($text, '(?m)^\s*#define\s+PY_RELEASE_SERIAL\s+(\d+)\s*$')
    if ($serialMatch.Success) {
        $serial = [int]$serialMatch.Groups[1].Value
    }

    $level = 'final'
    $levelMatch = [regex]::Match($text, '(?m)^\s*#define\s+PY_RELEASE_LEVEL\s+(PY_RELEASE_LEVEL_[A-Z]+)\s*$')
    if ($levelMatch.Success) {
        switch ($levelMatch.Groups[1].Value) {
            'PY_RELEASE_LEVEL_ALPHA' { $level = 'a' }
            'PY_RELEASE_LEVEL_BETA'  { $level = 'b' }
            'PY_RELEASE_LEVEL_GAMMA' { $level = 'rc' }
            default                  { $level = 'final' }
        }
    }

    $baseVersion = '{0}.{1}.{2}' -f $values['PY_MAJOR_VERSION'], $values['PY_MINOR_VERSION'], $values['PY_MICRO_VERSION']
    $displayVersion = $baseVersion
    if ($level -ne 'final') {
        $displayVersion = '{0}{1}{2}' -f $baseVersion, $level, $serial
    }

    return [pscustomobject]@{
        Major = $values['PY_MAJOR_VERSION']
        Minor = $values['PY_MINOR_VERSION']
        Micro = $values['PY_MICRO_VERSION']
        Level = $level
        Serial = $serial
        BaseVersion = $baseVersion
        DisplayVersion = $displayVersion
    }
}

function Find-VsWhere {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }
    return $null
}

function Get-VisualStudioBuildToolsInfos {
    $vswhere = Find-VsWhere
    if (-not $vswhere) {
        return @()
    }

    $jsonText = & $vswhere -all -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json 2>$null | Out-String
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($jsonText)) {
        return @()
    }

    try {
        # Windows PowerShell 5.1 can preserve a JSON top-level array as one
        # nested Object[] value. If that value is treated as one record,
        # property enumeration joins every installationPath into one string.
        # Flatten the parsed value explicitly before reading its properties.
        $parsedInstances = $jsonText | ConvertFrom-Json
        $instances = New-Object System.Collections.Generic.List[object]

        $pending = New-Object System.Collections.Stack
        $pending.Push($parsedInstances)
        while ($pending.Count -gt 0) {
            $current = $pending.Pop()
            if ($null -eq $current) {
                continue
            }

            if ($current -is [System.Array]) {
                for ($index = $current.Length - 1; $index -ge 0; $index--) {
                    $pending.Push($current[$index])
                }
                continue
            }

            $instances.Add($current)
        }
    }
    catch {
        return @()
    }

    $results = @()
    foreach ($instance in $instances) {
        $installationPath = ([string]$instance.installationPath).Trim()
        if ([string]::IsNullOrWhiteSpace($installationPath)) {
            continue
        }

        # A single vswhere record must never contain a second drive-rooted
        # path. This guard turns parser regressions into a clear warning rather
        # than passing a concatenated path to Join-Path.
        if ($installationPath -match '(?i)\s+[A-Z]:\\') {
            Write-Warn ("Ignoring malformed combined Visual Studio path from vswhere: {0}" -f $installationPath)
            continue
        }

        $versionText = ([string]$instance.installationVersion).Trim()
        $major = 0
        if ($versionText -match '^(\d+)\.') {
            $major = [int]$Matches[1]
        }

        $results += [pscustomobject]@{
            InstallationPath = $installationPath
            InstallationVersion = $versionText
            MajorVersion = $major
            DisplayName = ([string]$instance.displayName).Trim()
        }
    }

    return @($results |
        Group-Object { $_.InstallationPath.ToLowerInvariant() } |
        ForEach-Object { $_.Group | Sort-Object InstallationVersion -Descending | Select-Object -First 1 } |
        Sort-Object -Property @{ Expression = 'MajorVersion'; Descending = $true }, @{ Expression = 'InstallationVersion'; Descending = $true })
}

function Get-MaxSupportedVisualStudioMajor {
    param([string]$SourceDirectory)

    $pythonProps = Join-Path $SourceDirectory 'PCbuild\python.props'
    if (-not (Test-Path -LiteralPath $pythonProps -PathType Leaf)) {
        return $null
    }

    $text = Get-Content -LiteralPath $pythonProps -Raw
    $versions = @()
    foreach ($match in [regex]::Matches($text, "VisualStudioVersion\)'\s*==\s*'(\d+)\.0'")) {
        $versions += [int]$match.Groups[1].Value
    }

    if (-not $versions -or $versions.Count -eq 0) {
        return $null
    }
    return ($versions | Measure-Object -Maximum).Maximum
}

function Resolve-VisualStudioBuildToolsInfo {
    param(
        [object[]]$InstalledInstances,
        [string]$ConfiguredValue,
        [Nullable[int]]$MaxSupportedMajor
    )

    if (-not $InstalledInstances -or $InstalledInstances.Count -eq 0) {
        return $null
    }

    $requested = if ([string]::IsNullOrWhiteSpace($ConfiguredValue)) { 'auto_compatible' } else { $ConfiguredValue.Trim() }
    if ($requested -ieq 'latest') {
        return $InstalledInstances | Sort-Object MajorVersion -Descending | Select-Object -First 1
    }

    if ($requested -ieq 'auto' -or $requested -ieq 'auto_compatible') {
        if ($null -ne $MaxSupportedMajor) {
            $compatible = @($InstalledInstances | Where-Object { $_.MajorVersion -le $MaxSupportedMajor } | Sort-Object MajorVersion -Descending)
            if ($compatible.Count -gt 0) {
                return $compatible[0]
            }
            return $null
        }
        return $InstalledInstances | Sort-Object MajorVersion -Descending | Select-Object -First 1
    }

    if ($requested -notmatch '^\d+$') {
        throw "advanced.visual_studio_major must be 'auto_compatible', 'latest', or a major version such as 17 or 18. Received: $requested"
    }

    $requestedMajor = [int]$requested
    $selected = @($InstalledInstances | Where-Object { $_.MajorVersion -eq $requestedMajor } | Sort-Object InstallationVersion -Descending)
    if ($selected.Count -eq 0) {
        $installed = ($InstalledInstances | ForEach-Object { $_.MajorVersion } | Select-Object -Unique | Sort-Object) -join ', '
        throw "Requested Visual Studio major version '$requestedMajor' is not installed. Installed major versions: $installed"
    }
    return $selected[0]
}

function Get-MSBuildPath {
    param([string]$VisualStudioInstallationPath)

    # Prefer 32-bit .NET Framework MSBuild. Legacy WiX 3 tasks used by older
    # CPython installer branches are more reliable in this host than in newer
    # 64-bit or dotnet-based MSBuild hosts.
    foreach ($relative in @('MSBuild\Current\Bin\MSBuild.exe', 'MSBuild\15.0\Bin\MSBuild.exe')) {
        $candidate = Join-Path $VisualStudioInstallationPath $relative
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

function Get-InstalledPlatformToolsets {
    param([string]$VisualStudioInstallationPath)

    $vcMsBuildRoot = Join-Path $VisualStudioInstallationPath 'MSBuild\Microsoft\VC'
    if (-not (Test-Path -LiteralPath $vcMsBuildRoot -PathType Container)) {
        return @()
    }

    $toolsets = Get-ChildItem -LiteralPath $vcMsBuildRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^v\d+$' -and
            $null -ne $_.Parent -and
            $_.Parent.Name -eq 'PlatformToolsets'
        } |
        ForEach-Object { $_.Name } |
        Select-Object -Unique |
        Sort-Object { [int]($_.Substring(1)) } -Descending

    return @($toolsets)
}

function Resolve-PlatformToolset {
    param(
        [string]$ConfiguredValue,
        [string[]]$InstalledToolsets
    )

    $requested = if ([string]::IsNullOrWhiteSpace($ConfiguredValue)) { 'auto' } else { $ConfiguredValue.Trim() }
    if ($requested -ieq 'auto') {
        if (-not $InstalledToolsets -or $InstalledToolsets.Count -eq 0) {
            return $null
        }
        return $InstalledToolsets[0]
    }

    if ($requested -notmatch '^v\d+$') {
        throw "advanced.platform_toolset must be 'auto' or a value such as v145, v143, or v142. Received: $requested"
    }

    if ($InstalledToolsets -and $InstalledToolsets.Count -gt 0 -and $requested -notin $InstalledToolsets) {
        throw "Requested platform toolset '$requested' is not installed. Installed toolsets: $($InstalledToolsets -join ', ')"
    }

    return $requested
}

function Get-NetFx3State {
    if ([Environment]::OSVersion.Version.Build -ge 28000) {
        return 'StandaloneOnThisWindowsBuild'
    }

    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction Stop
        return $feature.State.ToString()
    }
    catch {
        return 'Unknown'
    }
}


function Test-LegacyWixMsBuildDependency {
    $assemblyName = 'Microsoft.Build.Utilities, Version=2.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a'
    try {
        $assembly = [System.Reflection.Assembly]::Load($assemblyName)
        return [pscustomobject]@{
            Available = $true
            FullName = $assembly.FullName
            Location = $assembly.Location
            Error = ''
        }
    }
    catch {
        return [pscustomobject]@{
            Available = $false
            FullName = $assemblyName
            Location = ''
            Error = $_.Exception.Message
        }
    }
}

function Find-BootstrapPython {
    param([string]$ConfiguredValue)

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredValue) -and $ConfiguredValue -ne 'auto') {
        $resolved = Resolve-ConfiguredPath -PathValue $ConfiguredValue -BaseDirectory (Split-Path -Parent $script:ResolvedConfigPath)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "Configured bootstrap_python does not exist: $resolved"
        }
        return $resolved
    }

    $candidates = @()
    $pyCommand = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($pyCommand) {
        foreach ($selector in @('-3.10', '-3')) {
            try {
                $candidate = & $pyCommand.Source $selector -c "import sys; print(sys.executable)" 2>$null
                if ($LASTEXITCODE -eq 0 -and $candidate) {
                    $candidates += (($candidate | Select-Object -First 1).Trim())
                }
            }
            catch {
            }
        }
    }

    $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($pythonCommand) {
        $candidates += $pythonCommand.Source
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    return $null
}

function Get-SphinxBuildForPython {
    param([string]$PythonPath)

    if ([string]::IsNullOrWhiteSpace($PythonPath) -or -not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
        return $null
    }

    try {
        $pathOutput = & $PythonPath -c "import os, sysconfig; print(os.path.join(sysconfig.get_path('scripts'), 'sphinx-build.exe'))" 2>$null
        if ($LASTEXITCODE -eq 0 -and $pathOutput) {
            $candidate = (($pathOutput | Select-Object -First 1).Trim())
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                return [System.IO.Path]::GetFullPath($candidate)
            }
        }
    }
    catch {
    }

    return $null
}

function Invoke-LoggedCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$LogPath,
        [string]$Description
    )

    Write-Host ("Running: {0} {1}" -f $FilePath, ($Arguments -join ' '))
    Push-Location $WorkingDirectory

    $exitCode = $null
    $invocationError = $null
    $savedErrorActionPreference = $ErrorActionPreference
    $nativePreferenceVariable = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $savedNativePreference = $null
    if ($null -ne $nativePreferenceVariable) {
        $savedNativePreference = $nativePreferenceVariable.Value
    }

    try {
        # Windows PowerShell 5.1 converts text written by native programs to
        # stderr into ErrorRecord objects. With the builder-wide
        # ErrorActionPreference set to Stop, harmless compiler/Sphinx warnings
        # can terminate the wrapper before the native exit code is checked.
        #
        # Keep native stderr in the log and console, but judge success solely
        # from the process exit code.
        $ErrorActionPreference = 'Continue'
        if ($null -ne $nativePreferenceVariable) {
            Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false
        }

        & $FilePath @Arguments 2>&1 |
            ForEach-Object {
                $line = $_.ToString()
                Write-Host $line
                $line | Out-File -LiteralPath $LogPath -Append -Encoding unicode
            }

        $exitCode = $LASTEXITCODE
    }
    catch {
        $invocationError = $_
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
        if ($null -ne $nativePreferenceVariable) {
            Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $savedNativePreference
        }
        Pop-Location
    }

    if ($null -ne $invocationError) {
        $message = $invocationError.Exception.Message
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = $invocationError.ToString()
        }
        throw "$Description could not be executed: $message"
    }

    if ($null -eq $exitCode) {
        throw "$Description ended without returning a native process exit code. Review: $LogPath"
    }

    if ($exitCode -ne 0) {
        throw "$Description failed with exit code $exitCode. Review: $LogPath"
    }
}

function Invoke-BatchFile {
    param(
        [string]$BatchPath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$LogPath,
        [string]$Description
    )

    $quotedBatch = '"{0}"' -f $BatchPath
    $commandLine = 'call {0}' -f $quotedBatch
    if ($Arguments.Count -gt 0) {
        $commandLine += ' ' + ($Arguments -join ' ')
    }

    Invoke-LoggedCommand -FilePath $env:ComSpec -Arguments @('/d', '/s', '/c', $commandLine) -WorkingDirectory $WorkingDirectory -LogPath $LogPath -Description $Description
}

function Get-ArchitectureInfo {
    param([string]$Architecture)

    switch ($Architecture.ToLowerInvariant()) {
        'x64' {
            return [pscustomobject]@{ Name = 'x64'; InstallerFlag = '-x64'; PcBuildPlatform = 'x64'; LayoutName = 'amd64' }
        }
        'amd64' {
            return [pscustomobject]@{ Name = 'x64'; InstallerFlag = '-x64'; PcBuildPlatform = 'x64'; LayoutName = 'amd64' }
        }
        'x86' {
            return [pscustomobject]@{ Name = 'x86'; InstallerFlag = '-x86'; PcBuildPlatform = 'Win32'; LayoutName = 'win32' }
        }
        'win32' {
            return [pscustomobject]@{ Name = 'x86'; InstallerFlag = '-x86'; PcBuildPlatform = 'Win32'; LayoutName = 'win32' }
        }
        'arm64' {
            return [pscustomobject]@{ Name = 'arm64'; InstallerFlag = '-ARM64'; PcBuildPlatform = 'ARM64'; LayoutName = 'arm64' }
        }
        default {
            throw "Unsupported architecture '$Architecture'. Use x64, x86, or arm64."
        }
    }
}

function Test-ArchitectureSupport {
    param(
        [string]$InstallerScript,
        [object[]]$ArchitectureInfos
    )

    $scriptText = Get-Content -LiteralPath $InstallerScript -Raw
    foreach ($architecture in $ArchitectureInfos) {
        if ($architecture.Name -eq 'arm64' -and $scriptText -notmatch '(?i)ARM64') {
            throw "This CPython source version does not expose ARM64 in its MSI build script."
        }
    }
}

function Clean-KnownBuildOutputs {
    param(
        [string]$SourceDirectory,
        [object[]]$ArchitectureInfos
    )

    foreach ($architecture in $ArchitectureInfos) {
        $layout = Join-Path $SourceDirectory ("PCbuild\{0}\en-us" -f $architecture.LayoutName)
        if (Test-Path -LiteralPath $layout) {
            Write-Host "Removing old installer layout: $layout"
            Remove-Item -LiteralPath $layout -Recurse -Force
        }
    }

    $msiObj = Join-Path $SourceDirectory 'Tools\msi\obj'
    if (Test-Path -LiteralPath $msiObj) {
        Write-Host "Removing old MSI object directory: $msiObj"
        Remove-Item -LiteralPath $msiObj -Recurse -Force
    }
}

function Copy-PrivateInstallerLayouts {
    param(
        [string]$SourceDirectory,
        [string]$RunOutputDirectory,
        [object[]]$ArchitectureInfos,
        [bool]$KeepCompleteLayout
    )

    $copied = @()
    foreach ($architecture in $ArchitectureInfos) {
        $layout = Join-Path $SourceDirectory ("PCbuild\{0}\en-us" -f $architecture.LayoutName)
        if (-not (Test-Path -LiteralPath $layout -PathType Container)) {
            throw "Expected installer layout was not created: $layout"
        }

        $destination = Join-Path $RunOutputDirectory $architecture.LayoutName
        New-Item -ItemType Directory -Path $destination -Force | Out-Null

        if ($KeepCompleteLayout) {
            Copy-Item -Path (Join-Path $layout '*') -Destination $destination -Recurse -Force
        }
        else {
            Get-ChildItem -LiteralPath $layout -File -Filter '*.exe' | Copy-Item -Destination $destination -Force
        }

        $copied += Get-ChildItem -LiteralPath $destination -Recurse -File
    }
    return $copied
}

function Write-ArtifactManifest {
    param(
        [string]$RunOutputDirectory,
        [object]$VersionInfo,
        [string]$Mode,
        [object[]]$ArchitectureInfos,
        [string]$SourceDirectory,
        [datetime]$BuildStarted,
        [string]$LogPath
    )

    $files = Get-ChildItem -LiteralPath $RunOutputDirectory -Recurse -File |
        Where-Object { $_.Name -notin @('build_manifest.json', 'SHA256SUMS.txt', 'build_report.txt') }

    $manifestFiles = @()
    $sumLines = @()
    foreach ($file in $files) {
        $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
        $relative = $file.FullName.Substring($RunOutputDirectory.Length).TrimStart('\')
        $manifestFiles += [pscustomobject]@{
            path = $relative
            size_bytes = $file.Length
            sha256 = $hash.Hash.ToLowerInvariant()
        }
        $sumLines += ('{0}  {1}' -f $hash.Hash.ToLowerInvariant(), $relative)
    }

    $manifest = [pscustomobject]@{
        format_version = 1
        created_utc = [DateTime]::UtcNow.ToString('o')
        source_directory = $SourceDirectory
        cpython_version = $VersionInfo.DisplayVersion
        installer_mode = $Mode
        architectures = @($ArchitectureInfos | ForEach-Object { $_.Name })
        build_started_local = $BuildStarted.ToString('o')
        build_log = $LogPath
        files = $manifestFiles
    }

    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $RunOutputDirectory 'build_manifest.json') -Encoding UTF8
    $sumLines | Set-Content -LiteralPath (Join-Path $RunOutputDirectory 'SHA256SUMS.txt') -Encoding ASCII

    $installerExecutables = $files | Where-Object {
        $_.Extension -ieq '.exe' -and $_.Name -match '(?i)^python-.*(amd64|win32|arm64|webinstall|embed|x86|x64)?.*\.exe$'
    }
    if (-not $installerExecutables) {
        $installerExecutables = $files | Where-Object { $_.Extension -ieq '.exe' }
    }

    $report = @(
        'CPython Installer Builder Report',
        '================================',
        ('Version: {0}' -f $VersionInfo.DisplayVersion),
        ('Mode: {0}' -f $Mode),
        ('Architectures: {0}' -f (($ArchitectureInfos | ForEach-Object { $_.Name }) -join ', ')),
        ('Source: {0}' -f $SourceDirectory),
        ('Output: {0}' -f $RunOutputDirectory),
        ('Build log: {0}' -f $LogPath),
        '',
        'Installer executables:'
    )
    if ($installerExecutables) {
        foreach ($installer in $installerExecutables) {
            $report += ('  {0}' -f $installer.FullName)
        }
    }
    else {
        $report += '  No EXE installer was detected. Review the build log and copied layout.'
    }
    $report | Set-Content -LiteralPath (Join-Path $RunOutputDirectory 'build_report.txt') -Encoding UTF8

    return $installerExecutables
}

try {
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        Stop-Build 'This builder must run on Windows.' 2
    }

    $script:ResolvedConfigPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
    if (-not (Test-Path -LiteralPath $script:ResolvedConfigPath -PathType Leaf)) {
        Stop-Build "Configuration file not found: $script:ResolvedConfigPath" 2
    }

    Write-Stage 'Loading configuration'
    $configDirectory = Split-Path -Parent $script:ResolvedConfigPath
    $config = Get-Content -LiteralPath $script:ResolvedConfigPath -Raw | ConvertFrom-Json

    $sourceDirectory = Resolve-ConfiguredPath -PathValue ([string](Get-ConfigValue $config 'source_dir' '')) -BaseDirectory $configDirectory
    $outputDirectory = Resolve-ConfiguredPath -PathValue ([string](Get-ConfigValue $config 'output_dir' '.\output')) -BaseDirectory $configDirectory
    $mode = ([string](Get-ConfigValue $config 'installer_mode' 'private_side_by_side')).ToLowerInvariant()
    $architectures = @(Get-ConfigValue $config 'architectures' @('x64'))
    $packSingleExe = [bool](Get-ConfigValue $config 'pack_single_exe' $true)
    $buildDocumentation = [bool](Get-ConfigValue $config 'build_documentation' $false)
    $copyDocumentationToOutput = [bool](Get-ConfigValue $config 'copy_documentation_to_output' $true)
    $runTests = [bool](Get-ConfigValue $config 'run_cpython_tests' $false)
    $cleanBeforeBuild = [bool](Get-ConfigValue $config 'clean_before_build' $false)
    $bootstrapSetting = [string](Get-ConfigValue $config 'bootstrap_python' 'auto')
    $sphinxBuild = [string](Get-ConfigValue $config 'sphinx_build' '')

    $buildOptions = Get-ConfigValue $config 'build_options' $null
    $usePgo = [bool](Get-ConfigValue $buildOptions 'use_pgo' $false)
    $buildNuget = [bool](Get-ConfigValue $buildOptions 'build_nuget_package' $false)
    $buildZip = [bool](Get-ConfigValue $buildOptions 'build_embeddable_zip' $true)

    $signing = Get-ConfigValue $config 'signing' $null
    $certificateName = [string](Get-ConfigValue $signing 'certificate_name' '')

    $advanced = Get-ConfigValue $config 'advanced' $null
    $allowOfficialIdentity = [bool](Get-ConfigValue $advanced 'allow_official_identity' $false)
    $keepCompleteLayout = [bool](Get-ConfigValue $advanced 'keep_complete_installer_layout' $true)
    $requireNetFx35 = [bool](Get-ConfigValue $advanced 'require_net_framework_35' $true)
    $platformToolsetSetting = [string](Get-ConfigValue $advanced 'platform_toolset' 'auto')
    $visualStudioMajorSetting = [string](Get-ConfigValue $advanced 'visual_studio_major' 'auto_compatible')
    $useTestMarker = [bool](Get-ConfigValue $advanced 'use_test_marker' $false)
    $releaseStyleInstallerName = [bool](Get-ConfigValue $advanced 'release_style_installer_name' $true)

    if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
        Stop-Build "CPython source directory not found: $sourceDirectory" 3
    }

    foreach ($requiredPath in @('PCbuild\build.bat', 'Include\patchlevel.h')) {
        $fullPath = Join-Path $sourceDirectory $requiredPath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            Stop-Build "This is not a supported CPython source tree. Missing: $requiredPath" 3
        }
    }

    $versionInfo = Get-CpythonVersion -SourceDirectory $sourceDirectory
    $architectureInfos = @($architectures | ForEach-Object { Get-ArchitectureInfo -Architecture ([string]$_) })
    Write-Ok ("Detected CPython {0}" -f $versionInfo.DisplayVersion)
    Write-Ok ("Source: {0}" -f $sourceDirectory)
    Write-Ok ("Mode: {0}" -f $mode)
    Write-Ok ("Architectures: {0}" -f (($architectureInfos | ForEach-Object { $_.Name }) -join ', '))

    Write-Stage 'Checking build prerequisites'
    $vsInfos = @(Get-VisualStudioBuildToolsInfos)
    if (-not $vsInfos -or $vsInfos.Count -eq 0) {
        Stop-Build 'Visual Studio Build Tools with the MSVC x86/x64 C++ tools were not detected. Return to START_HERE.bat and run the prerequisite step, or install the Desktop development with C++ workload.' 4
    }

    $maxSupportedVisualStudioMajor = Get-MaxSupportedVisualStudioMajor -SourceDirectory $sourceDirectory
    $vsInfo = Resolve-VisualStudioBuildToolsInfo -InstalledInstances $vsInfos -ConfiguredValue $visualStudioMajorSetting -MaxSupportedMajor $maxSupportedVisualStudioMajor
    if (-not $vsInfo) {
        $installedMajors = ($vsInfos | ForEach-Object { $_.MajorVersion } | Select-Object -Unique | Sort-Object) -join ', '
        if ($null -ne $maxSupportedVisualStudioMajor) {
            Stop-Build ("This CPython source supports Visual Studio through major version {0}, but only newer Visual Studio instances were found ({1}). Install Visual Studio 2022 Build Tools and rerun preflight. Do not force Visual Studio 2026 for this legacy WiX installer branch." -f $maxSupportedVisualStudioMajor, $installedMajors) 4
        }
        Stop-Build 'No compatible Visual Studio Build Tools installation was found.' 4
    }

    $msbuildPath = Get-MSBuildPath -VisualStudioInstallationPath $vsInfo.InstallationPath
    if (-not $msbuildPath) {
        Write-Host 'Detected Visual Studio candidates:' -ForegroundColor Yellow
        foreach ($candidateInfo in $vsInfos) {
            $candidateMsBuild = Get-MSBuildPath -VisualStudioInstallationPath $candidateInfo.InstallationPath
            $candidateState = if ($candidateMsBuild) { $candidateMsBuild } else { 'MSBuild.exe not found' }
            Write-Host ("  VS {0}: {1} -> {2}" -f $candidateInfo.MajorVersion, $candidateInfo.InstallationPath, $candidateState) -ForegroundColor Yellow
        }
        Stop-Build ("MSBuild.exe was not found under the selected Visual Studio installation: {0}" -f $vsInfo.InstallationPath) 4
    }

    # CPython's build.bat calls find_msbuild.bat, which otherwise selects the
    # newest Visual Studio instance through vswhere. Pinning MSBUILD here keeps
    # an installed VS 2026/MSBuild 18 from taking over an old WiX 3 build that
    # needs VS 2022/MSBuild 17.
    $env:MSBUILD = $msbuildPath
    $env:VisualStudioVersion = ('{0}.0' -f $vsInfo.MajorVersion)

    Write-Ok ("Visual Studio/MSVC: {0} (version {1})" -f $vsInfo.InstallationPath, $vsInfo.InstallationVersion)
    Write-Ok ("Pinned MSBuild host: {0}" -f $msbuildPath)
    if ($null -ne $maxSupportedVisualStudioMajor) {
        Write-Ok ("CPython source supports Visual Studio through major version {0}" -f $maxSupportedVisualStudioMajor)
    }

    $installedPlatformToolsets = @(Get-InstalledPlatformToolsets -VisualStudioInstallationPath $vsInfo.InstallationPath)
    $selectedPlatformToolset = Resolve-PlatformToolset -ConfiguredValue $platformToolsetSetting -InstalledToolsets $installedPlatformToolsets
    if ($selectedPlatformToolset) {
        # Older CPython branches only recognize Visual Studio versions known when that branch was released.
        # Exporting both properties prevents a newer MSBuild (for example VS 2026 / 18.x) from falling
        # through to an obsolete toolset such as v140.
        $env:PlatformToolset = $selectedPlatformToolset
        $env:BasePlatformToolset = $selectedPlatformToolset
        Write-Ok ("MSVC platform toolset: {0} (installed: {1})" -f $selectedPlatformToolset, ($installedPlatformToolsets -join ', '))
    }
    else {
        Write-Warn 'Could not auto-detect an installed MSVC platform toolset. The CPython project will choose its own default. Set advanced.platform_toolset explicitly if MSB8020 occurs.'
    }

    $netFxState = Get-NetFx3State
    if ($netFxState -eq 'Enabled') {
        Write-Ok '.NET Framework 3.5 Windows feature is enabled.'
    }
    elseif ($netFxState -eq 'StandaloneOnThisWindowsBuild') {
        Write-Warn 'Windows build 28000 or later uses the separate .NET Framework 3.5 installer rather than the NetFx3 Windows feature.'
    }
    elseif ($netFxState -eq 'Unknown') {
        Write-Warn 'Could not query the NetFx3 Windows feature without elevation. Checking the exact legacy WiX assembly instead.'
    }
    else {
        Write-Warn (".NET Framework 3.5 Windows feature state: {0}." -f $netFxState)
    }

    # The feature-state check alone is not enough. WiX 3.x used by older
    # CPython branches loads Microsoft.Build.Utilities, Version=2.0.0.0.
    # Probe that exact assembly before starting a long interpreter build.
    $legacyWixDependency = Test-LegacyWixMsBuildDependency
    if ($legacyWixDependency.Available) {
        $dependencyLocation = if ([string]::IsNullOrWhiteSpace($legacyWixDependency.Location)) {
            'Global Assembly Cache'
        }
        else {
            $legacyWixDependency.Location
        }
        Write-Ok ("Legacy WiX MSBuild dependency is available: {0}" -f $dependencyLocation)
    }
    elseif ($requireNetFx35) {
        $installHint = if ([Environment]::OSVersion.Version.Build -ge 28000) {
            'Install the standalone .NET Framework 3.5 package for this Windows version, restart Windows, and rerun preflight_only.bat.'
        }
        else {
            'Run advanced_tools\07_INSTALL_LEGACY_NETFX35.bat as Administrator, restart Windows if requested, and rerun preflight from START_HERE.bat.'
        }
        Stop-Build ("Legacy WiX cannot load Microsoft.Build.Utilities, Version=2.0.0.0. {0} Loader error: {1}" -f $installHint, $legacyWixDependency.Error) 4
    }
    else {
        Write-Warn ("Legacy WiX MSBuild dependency is unavailable: {0}" -f $legacyWixDependency.Error)
    }

    $bootstrapPython = Find-BootstrapPython -ConfiguredValue $bootstrapSetting
    if ($bootstrapPython) {
        $env:PYTHON = $bootstrapPython
        Write-Ok ("Bootstrap Python: {0}" -f $bootstrapPython)
    }
    else {
        Write-Warn 'No bootstrap Python was found. PCbuild may download one through NuGet, but documentation or MSI helper tasks may fail.'
    }

    if ($buildDocumentation) {
        if (-not [string]::IsNullOrWhiteSpace($sphinxBuild)) {
            $sphinxBuild = Resolve-ConfiguredPath -PathValue $sphinxBuild -BaseDirectory $configDirectory
        }

        if ([string]::IsNullOrWhiteSpace($sphinxBuild) -or -not (Test-Path -LiteralPath $sphinxBuild -PathType Leaf)) {
            $sphinxCommand = Get-Command sphinx-build.exe -ErrorAction SilentlyContinue
            if ($sphinxCommand) {
                $sphinxBuild = $sphinxCommand.Source
            }
        }

        if (([string]::IsNullOrWhiteSpace($sphinxBuild) -or -not (Test-Path -LiteralPath $sphinxBuild -PathType Leaf)) -and $bootstrapPython) {
            $sphinxBuild = Get-SphinxBuildForPython -PythonPath $bootstrapPython
        }

        if ([string]::IsNullOrWhiteSpace($sphinxBuild) -or -not (Test-Path -LiteralPath $sphinxBuild -PathType Leaf)) {
            Stop-Build 'build_documentation is true, but sphinx-build.exe was not found. Return to START_HERE.bat and run the documentation-requirements step.' 4
        }
        # CPython 3.10's Doc\make.bat executes %SPHINXBUILD% without
        # quoting it during its availability check. A correct executable path
        # therefore fails when any parent directory contains a space.
        #
        # Put the isolated environment's Scripts directory first on PATH and
        # pass command names without spaces. Do NOT replace the global PYTHON
        # variable here: PCbuild and Tools\msi use PYTHON for their bootstrap
        # interpreter and NuGet/external-fetch logic.
        $documentationScriptsDirectory = Split-Path -Parent $sphinxBuild
        $documentationPathEntries = @(
            $env:PATH -split ';' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        $documentationPathAlreadyPresent = $false
        foreach ($pathEntry in $documentationPathEntries) {
            if ($pathEntry.TrimEnd('\') -ieq $documentationScriptsDirectory.TrimEnd('\')) {
                $documentationPathAlreadyPresent = $true
                break
            }
        }

        if (-not $documentationPathAlreadyPresent) {
            $env:PATH = $documentationScriptsDirectory + ';' + $env:PATH
        }

        $sphinxCommandName = [System.IO.Path]::GetFileName($sphinxBuild)
        $env:SPHINXBUILD = $sphinxCommandName

        $documentationPython = Join-Path $documentationScriptsDirectory 'python.exe'
        if (-not (Test-Path -LiteralPath $documentationPython -PathType Leaf)) {
            Stop-Build ("The isolated documentation environment is incomplete. python.exe was not found beside Sphinx: {0}" -f $documentationPython) 4
        }

        $documentationBlurb = Join-Path $documentationScriptsDirectory 'blurb.exe'
        if (Test-Path -LiteralPath $documentationBlurb -PathType Leaf) {
            $env:BLURB = [System.IO.Path]::GetFileName($documentationBlurb)
        }
        else {
            # python.exe resolves to the isolated environment because its
            # Scripts directory is first on PATH during the documentation step.
            $env:BLURB = 'python.exe -m blurb'
        }

        Write-Ok ("Bootstrap Python retained for CPython build: {0}" -f $bootstrapPython)
        Write-Ok ("Documentation Python (isolated): {0}" -f $documentationPython)
        Write-Ok ("Sphinx executable: {0}" -f $sphinxBuild)
        Write-Ok ("SPHINXBUILD command: {0}" -f $env:SPHINXBUILD)
        Write-Ok ("BLURB command: {0}" -f $env:BLURB)
        Write-Ok ("Documentation tools PATH entry: {0}" -f $documentationScriptsDirectory)
    }

    $privateBuildScript = Join-Path $sourceDirectory 'Tools\msi\build.bat'
    $releaseBuildScript = Join-Path $sourceDirectory 'Tools\msi\buildrelease.bat'

    switch ($mode) {
        'private_side_by_side' {
            if (-not (Test-Path -LiteralPath $privateBuildScript -PathType Leaf)) {
                Stop-Build 'This CPython source tree does not include Tools\msi\build.bat, so it cannot create the requested Windows installer.' 3
            }
            Test-ArchitectureSupport -InstallerScript $privateBuildScript -ArchitectureInfos $architectureInfos
            Write-Ok 'Private side-by-side installer path is available.'
        }
        'official_identity' {
            if (-not $allowOfficialIdentity) {
                Stop-Build 'official_identity mode is blocked. Set advanced.allow_official_identity to true only after reading the warning in README.md.' 5
            }
            if (-not (Test-Path -LiteralPath $releaseBuildScript -PathType Leaf)) {
                Stop-Build 'This CPython source tree does not include Tools\msi\buildrelease.bat.' 3
            }
            if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
                Stop-Build 'Git is required by CPython Tools\msi\buildrelease.bat but was not found on PATH.' 4
            }
            Test-ArchitectureSupport -InstallerScript $releaseBuildScript -ArchitectureInfos $architectureInfos
            Write-Warn 'official_identity mode uses CPython release installer identities. A locally built unsigned installer may not upgrade or interoperate cleanly with a python.org installation.'
        }
        default {
            Stop-Build "Unknown installer_mode '$mode'. Use private_side_by_side or official_identity." 2
        }
    }

    if ($PreflightOnly) {
        Write-Stage 'Preflight complete'
        Write-Ok 'The configured source tree and required local build tools passed preflight.'
        exit 0
    }

    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $runOutputDirectory = Join-Path $outputDirectory ("Python-{0}-{1}-{2}" -f $versionInfo.DisplayVersion, $mode, $timestamp)
    New-Item -ItemType Directory -Path $runOutputDirectory -Force | Out-Null
    $logPath = Join-Path $runOutputDirectory 'build.log'
    $buildStarted = Get-Date

    if ($cleanBeforeBuild) {
        Write-Stage 'Cleaning prior installer outputs'
        Clean-KnownBuildOutputs -SourceDirectory $sourceDirectory -ArchitectureInfos $architectureInfos
    }

    if ($buildDocumentation) {
        $documentationMakeScript = Join-Path $sourceDirectory 'Doc\make.bat'
        if (-not (Test-Path -LiteralPath $documentationMakeScript -PathType Leaf)) {
            throw "Documentation was requested, but Doc\\make.bat was not found: $documentationMakeScript"
        }

        Write-Stage 'Building CPython documentation in isolated environment'
        $savedPythonEnvironment = $env:PYTHON
        $savedSphinxEnvironment = $env:SPHINXBUILD
        $savedBlurbEnvironment = $env:BLURB

        try {
            # Quote PYTHON because older Doc\make.bat files expand it directly
            # and the isolated environment path may contain spaces.
            $env:PYTHON = ('"{0}"' -f $documentationPython)
            $env:SPHINXBUILD = [System.IO.Path]::GetFileName($sphinxBuild)
            $env:BLURB = if (Test-Path -LiteralPath $documentationBlurb -PathType Leaf) {
                [System.IO.Path]::GetFileName($documentationBlurb)
            }
            else {
                'python.exe -m blurb'
            }

            $documentationTarget = if ($mode -eq 'official_identity') { 'htmlhelp' } else { 'html' }
            Invoke-BatchFile `
                -BatchPath $documentationMakeScript `
                -Arguments @($documentationTarget) `
                -WorkingDirectory (Split-Path -Parent $documentationMakeScript) `
                -LogPath $logPath `
                -Description ("CPython documentation build ({0})" -f $documentationTarget)
        }
        finally {
            $env:PYTHON = $savedPythonEnvironment
            $env:SPHINXBUILD = $savedSphinxEnvironment
            $env:BLURB = $savedBlurbEnvironment
        }

        if ($bootstrapPython) {
            $env:PYTHON = $bootstrapPython
        }

        $documentationOutputDirectory = Join-Path $sourceDirectory ("Doc\build\{0}" -f $documentationTarget)
        $documentationIndex = Join-Path $documentationOutputDirectory 'index.html'
        if (Test-Path -LiteralPath $documentationIndex -PathType Leaf) {
            $recordedDocumentationDirectory = $documentationOutputDirectory
            $recordedDocumentationIndex = $documentationIndex

            if ($copyDocumentationToOutput) {
                $copiedDocumentationDirectory = Join-Path $runOutputDirectory ("documentation\{0}" -f $documentationTarget)
                New-Item -ItemType Directory -Path $copiedDocumentationDirectory -Force | Out-Null
                Write-Host ("Copying documentation into final output: {0}" -f $copiedDocumentationDirectory) -ForegroundColor Cyan
                Copy-Item -Path (Join-Path $documentationOutputDirectory '*') -Destination $copiedDocumentationDirectory -Recurse -Force
                $copiedDocumentationIndex = Join-Path $copiedDocumentationDirectory 'index.html'
                if (Test-Path -LiteralPath $copiedDocumentationIndex -PathType Leaf) {
                    $recordedDocumentationDirectory = $copiedDocumentationDirectory
                    $recordedDocumentationIndex = $copiedDocumentationIndex
                    Write-Ok ("Preserved documentation in final output: {0}" -f $copiedDocumentationIndex)
                }
                else {
                    Write-Warn ("Documentation copy completed, but index.html was not found at: {0}" -f $copiedDocumentationIndex)
                }
            }

            $documentationLocationFile = Join-Path $runOutputDirectory 'documentation_location.txt'
            @(
                "Documentation target: $documentationTarget"
                "Documentation directory: $recordedDocumentationDirectory"
                "Documentation start page: $recordedDocumentationIndex"
                "Original source documentation directory: $documentationOutputDirectory"
            ) | Set-Content -LiteralPath $documentationLocationFile -Encoding UTF8
            Write-Ok ("Documentation HTML: {0}" -f $recordedDocumentationIndex)
            Write-Ok ("Documentation location record: {0}" -f $documentationLocationFile)
        }
        else {
            Write-Warn ("Documentation build reported success, but index.html was not found at: {0}" -f $documentationIndex)
        }

        Write-Ok 'Documentation completed; restored bootstrap Python for PCbuild/MSI tasks.'
    }

    Write-Stage ("Building CPython {0}" -f $versionInfo.DisplayVersion)
    if ($mode -eq 'private_side_by_side') {
        $args = @()
        foreach ($architecture in $architectureInfos) {
            $args += $architecture.InstallerFlag
        }
        if ($useTestMarker) {
            $args += '--test-marker'
            Write-Warn 'CPython test-marker branding is enabled. The generated installer and interpreter will include -test identifiers.'
        }
        else {
            # Explicitly request the normal CPython identity. This also guards
            # against an inherited UseTestMarker environment variable.
            $args += '--no-test-marker'
            Write-Ok 'CPython test-marker branding is disabled.'
        }

        if ($packSingleExe) {
            $args += '--pack'
        }
        # Documentation is built above with its isolated Python environment.
        # Do not pass --doc here, because Tools\msi\build.bat would reuse the
        # global PYTHON variable needed by PCbuild and external-fetch helpers.

        $savedBuildForRelease = [Environment]::GetEnvironmentVariable('BuildForRelease', 'Process')
        $savedUseTestMarker = [Environment]::GetEnvironmentVariable('UseTestMarker', 'Process')
        try {
            if ($releaseStyleInstallerName) {
                # CPython's snapshot MSI defaults to a date-based dev label.
                # BuildForRelease uses the source release version (for example
                # Python 3.10.20) while ReleaseUri remains machine-local, so
                # this is still an independent local build identity.
                $env:BuildForRelease = 'true'
                Write-Ok ('Release-style installer version text enabled: Python {0}' -f $versionInfo.DisplayVersion)
            }
            else {
                Remove-Item Env:BuildForRelease -ErrorAction SilentlyContinue
            }

            if ($useTestMarker) {
                $env:UseTestMarker = 'true'
            }
            else {
                Remove-Item Env:UseTestMarker -ErrorAction SilentlyContinue
            }

            Invoke-BatchFile -BatchPath $privateBuildScript -Arguments $args -WorkingDirectory (Split-Path -Parent $privateBuildScript) -LogPath $logPath -Description 'CPython private MSI installer build'
        }
        finally {
            if ($null -eq $savedBuildForRelease) {
                Remove-Item Env:BuildForRelease -ErrorAction SilentlyContinue
            }
            else {
                $env:BuildForRelease = $savedBuildForRelease
            }

            if ($null -eq $savedUseTestMarker) {
                Remove-Item Env:UseTestMarker -ErrorAction SilentlyContinue
            }
            else {
                $env:UseTestMarker = $savedUseTestMarker
            }
        }

        if ($runTests) {
            Write-Stage 'Running CPython regression tests'
            foreach ($architecture in $architectureInfos) {
                $pythonExe = Join-Path $sourceDirectory ("PCbuild\{0}\python.exe" -f $architecture.LayoutName)
                if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
                    throw "Built interpreter not found for tests: $pythonExe"
                }
                Invoke-LoggedCommand -FilePath $pythonExe -Arguments @('-m', 'test', '-q') -WorkingDirectory $sourceDirectory -LogPath $logPath -Description ("CPython tests for {0}" -f $architecture.Name)
            }
        }

        Copy-PrivateInstallerLayouts -SourceDirectory $sourceDirectory -RunOutputDirectory $runOutputDirectory -ArchitectureInfos $architectureInfos -KeepCompleteLayout $keepCompleteLayout | Out-Null
    }
    else {
        $args = @()
        foreach ($architecture in $architectureInfos) {
            $args += $architecture.InstallerFlag
        }
        # Documentation is prebuilt above when enabled. Always skip the
        # release script's internal Doc\make.bat invocation so it cannot reuse
        # the bootstrap PYTHON environment for documentation dependencies.
        $args += '-D'
        if (-not $usePgo) {
            $args += '--skip-pgo'
        }
        if (-not $buildNuget) {
            $args += '--skip-nuget'
        }
        if (-not $buildZip) {
            $args += '--skip-zip'
        }
        if (-not [string]::IsNullOrWhiteSpace($certificateName)) {
            $args += @('-c', ('"{0}"' -f $certificateName))
        }
        $args += @('-o', ('"{0}"' -f $runOutputDirectory))

        Invoke-BatchFile -BatchPath $releaseBuildScript -Arguments $args -WorkingDirectory (Split-Path -Parent $releaseBuildScript) -LogPath $logPath -Description 'CPython release installer build'
    }

    Write-Stage 'Verifying and hashing output'
    $installers = Write-ArtifactManifest -RunOutputDirectory $runOutputDirectory -VersionInfo $versionInfo -Mode $mode -ArchitectureInfos $architectureInfos -SourceDirectory $sourceDirectory -BuildStarted $buildStarted -LogPath $logPath

    if (-not $installers -or @($installers).Count -eq 0) {
        throw 'The build command completed, but no installer EXE was detected in the packaged output.'
    }

    foreach ($installer in @($installers)) {
        if ($installer.Length -lt 1MB) {
            Write-Warn ("Installer candidate is unexpectedly small: {0} ({1} bytes)" -f $installer.FullName, $installer.Length)
        }
        else {
            Write-Ok ("Installer: {0}" -f $installer.FullName)
        }
    }

    Write-Stage 'Build complete'
    Write-Host ("Output directory: {0}" -f $runOutputDirectory) -ForegroundColor Green
    Write-Host 'Review build_report.txt and SHA256SUMS.txt before installing.'
    exit 0
}
catch {
    Write-Host ''
    $errorMessage = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($errorMessage)) {
        $errorMessage = $_.ToString()
    }
    Write-Host ("[ERROR] {0}" -f $errorMessage) -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    exit 1
}
