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
$scriptDirectory = [System.IO.Path]::GetFullPath($scriptDirectory)
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptDirectory 'builder_config.json'
}
$ConfigPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
$statePath = Join-Path $scriptDirectory 'wizard_state.json'

function Write-Title {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
}

function Write-Step {
    param([int]$Number, [string]$Text)
    Write-Host ''
    Write-Host (('[STEP {0}] {1}' -f $Number, $Text)) -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host ('[OK] {0}' -f $Text) -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host ('[WARN] {0}' -f $Text) -ForegroundColor Yellow
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$Default = $true
    )

    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host ("$Prompt $suffix")).Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Default
        }
        if ($answer -match '^[Yy]([Ee][Ss])?$') { return $true }
        if ($answer -match '^[Nn]([Oo])?$') { return $false }
        Write-Warn 'Enter Y or N.'
    }
}

function Resolve-InputPath {
    param([string]$Value)

    $trimmed = $Value.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return ''
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($trimmed)
    return [System.IO.Path]::GetFullPath($expanded)
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configuration file not found: $ConfigPath"
    }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ($null -eq $config.PSObject.Properties['copy_documentation_to_output']) {
        $config | Add-Member -NotePropertyName 'copy_documentation_to_output' -NotePropertyValue $true
    }
    if ($null -eq $config.PSObject.Properties['wizard']) {
        $config | Add-Member -NotePropertyName 'wizard' -NotePropertyValue ([pscustomobject]@{
            temporary_root = '%TEMP%\CPythonInstallerBuilder'
            maximum_nested_archive_depth = 6
            maximum_nested_archives = 40
            cleanup_temporary_source_after_success = $false
        })
    }
    return $config
}

function Save-Config {
    param([object]$Config)
    $Config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Get-ConfigValue {
    param([object]$Object, [string]$Name, $Default)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $Default
}

function Test-CpythonSourceRoot {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    foreach ($required in @('Include\patchlevel.h', 'PCbuild\build.bat', 'Tools\msi\build.bat')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $required) -PathType Leaf)) {
            return $false
        }
    }
    return $true
}

function Find-CpythonSourceRoots {
    param([string]$SearchRoot)

    $results = New-Object System.Collections.Generic.List[string]
    if (Test-CpythonSourceRoot -Path $SearchRoot) {
        $results.Add([System.IO.Path]::GetFullPath($SearchRoot))
        return @($results)
    }

    $patchFiles = Get-ChildItem -LiteralPath $SearchRoot -Recurse -File -Filter 'patchlevel.h' -ErrorAction SilentlyContinue
    foreach ($patchFile in $patchFiles) {
        if ($patchFile.Directory.Name -ine 'Include') { continue }
        $candidate = $patchFile.Directory.Parent.FullName
        if (Test-CpythonSourceRoot -Path $candidate) {
            $fullCandidate = [System.IO.Path]::GetFullPath($candidate)
            if (-not $results.Contains($fullCandidate)) {
                $results.Add($fullCandidate)
            }
        }
    }
    return @($results | Sort-Object { $_.Length }, { $_ })
}

function Get-CpythonVersionText {
    param([string]$SourceRoot)
    $text = Get-Content -LiteralPath (Join-Path $SourceRoot 'Include\patchlevel.h') -Raw
    $parts = @()
    foreach ($name in @('PY_MAJOR_VERSION', 'PY_MINOR_VERSION', 'PY_MICRO_VERSION')) {
        $match = [regex]::Match($text, "(?m)^\s*#define\s+$name\s+(\d+)\s*$")
        if (-not $match.Success) { return 'unknown' }
        $parts += $match.Groups[1].Value
    }
    return ($parts -join '.')
}

function Get-ArchiveKind {
    param([string]$Path)
    $name = [System.IO.Path]::GetFileName($Path).ToLowerInvariant()
    if ($name.EndsWith('.zip')) { return 'zip' }
    foreach ($extension in @('.tar.gz', '.tgz', '.tar.bz2', '.tbz2', '.tbz', '.tar.xz', '.txz', '.tar.zst', '.tzst', '.tar')) {
        if ($name.EndsWith($extension)) { return 'tar' }
    }
    return ''
}

function Get-ArchiveBaseName {
    param([string]$Path)
    $name = [System.IO.Path]::GetFileName($Path)
    foreach ($extension in @('.tar.gz', '.tar.bz2', '.tar.xz', '.tar.zst', '.tgz', '.tbz2', '.tbz', '.txz', '.tzst', '.tar', '.zip')) {
        if ($name.EndsWith($extension, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $name.Substring(0, $name.Length - $extension.Length)
        }
    }
    return [System.IO.Path]::GetFileNameWithoutExtension($name)
}

function Test-SafeArchiveEntryName {
    param([string]$EntryName)
    if ([string]::IsNullOrWhiteSpace($EntryName)) { return $true }
    $normalized = $EntryName.Replace([char]92, [char]47)
    if ($normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:') { return $false }
    foreach ($segment in $normalized.Split('/')) {
        if ($segment -eq '..') { return $false }
    }
    return $true
}

function Expand-SafeZip {
    param([string]$ArchivePath, [string]$Destination)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $destinationRoot = [System.IO.Path]::GetFullPath($Destination).TrimEnd($separator) + $separator
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $zip.Entries) {
            if (-not (Test-SafeArchiveEntryName -EntryName $entry.FullName)) {
                throw "Unsafe ZIP entry rejected: $($entry.FullName)"
            }
            $target = [System.IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $target.StartsWith($destinationRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "ZIP entry escapes the destination: $($entry.FullName)"
            }
            if ([string]::IsNullOrWhiteSpace($entry.Name)) {
                New-Item -ItemType Directory -Path $target -Force | Out-Null
                continue
            }
            $targetDirectory = Split-Path -Parent $target
            New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
            $input = $entry.Open()
            try {
                $output = New-Object System.IO.FileStream($target, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                try { $input.CopyTo($output) } finally { $output.Dispose() }
            }
            finally { $input.Dispose() }
        }
    }
    finally { $zip.Dispose() }
}

function Expand-SafeTar {
    param([string]$ArchivePath, [string]$Destination)

    $tar = Get-Command 'tar.exe' -ErrorAction SilentlyContinue
    if (-not $tar) {
        throw 'tar.exe was not found. Current Windows 10/11 installations normally include it; install bsdtar or extract this archive manually.'
    }

    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $entries = & $tar.Source -tf $ArchivePath 2>&1
        $listExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    if ($listExit -ne 0) {
        throw "Could not list TAR archive contents: $ArchivePath"
    }
    foreach ($entry in $entries) {
        $entryText = if ($entry -is [System.Management.Automation.ErrorRecord]) { $entry.Exception.Message } else { [string]$entry }
        if (-not (Test-SafeArchiveEntryName -EntryName $entryText)) {
            throw "Unsafe TAR entry rejected: $entryText"
        }
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    try {
        $ErrorActionPreference = 'Continue'
        & $tar.Source -xf $ArchivePath -C $Destination
        $extractExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    if ($extractExit -ne 0) {
        throw "TAR extraction failed with exit code ${extractExit}: $ArchivePath"
    }
}

function Expand-SourceArchive {
    param([string]$ArchivePath, [string]$Destination)
    $kind = Get-ArchiveKind -Path $ArchivePath
    if ($kind -eq 'zip') {
        Expand-SafeZip -ArchivePath $ArchivePath -Destination $Destination
        return
    }
    if ($kind -eq 'tar') {
        Expand-SafeTar -ArchivePath $ArchivePath -Destination $Destination
        return
    }
    throw "Unsupported archive type: $ArchivePath"
}

function Select-CpythonRoot {
    param([string[]]$Roots)
    if ($Roots.Count -eq 1) { return $Roots[0] }
    Write-Host 'Multiple CPython source trees were found:' -ForegroundColor Yellow
    for ($index = 0; $index -lt $Roots.Count; $index++) {
        Write-Host ("  [{0}] {1}" -f ($index + 1), $Roots[$index])
    }
    while ($true) {
        $choice = Read-Host 'Select the source tree number'
        $number = 0
        if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $Roots.Count) {
            return $Roots[$number - 1]
        }
        Write-Warn 'Enter one of the displayed numbers.'
    }
}

function Get-WizardTemporaryRoot {
    $config = Get-Config
    $wizardConfig = Get-ConfigValue $config 'wizard' $null
    $configured = [string](Get-ConfigValue $wizardConfig 'temporary_root' '%TEMP%\CPythonInstallerBuilder')
    $expanded = [Environment]::ExpandEnvironmentVariables($configured)
    return [System.IO.Path]::GetFullPath($expanded)
}

function Prepare-CpythonSource {
    param([switch]$ForcePrompt)

    $config = Get-Config
    $configuredSource = Resolve-InputPath -Value ([string](Get-ConfigValue $config 'source_dir' ''))
    if (-not $ForcePrompt -and -not [string]::IsNullOrWhiteSpace($configuredSource) -and (Test-CpythonSourceRoot -Path $configuredSource)) {
        if (Read-YesNo -Prompt "Reuse configured CPython source ${configuredSource}?" -Default $true) {
            return $configuredSource
        }
    }

    Write-Host ''
    Write-Host 'Enter or drag-and-drop one of the following:' -ForegroundColor Cyan
    Write-Host '  * An extracted CPython source directory'
    Write-Host '  * .zip or .tar archive'
    Write-Host '  * .tar.gz/.tgz, .tar.bz2/.tbz2, .tar.xz/.txz, or .tar.zst/.tzst'
    Write-Host 'Nested supported archives are discovered automatically.'

    while ($true) {
        $inputValue = Read-Host 'CPython source folder or archive'
        $inputPath = Resolve-InputPath -Value $inputValue
        if (-not (Test-Path -LiteralPath $inputPath)) {
            Write-Warn "Path not found: $inputPath"
            continue
        }
        break
    }

    if (Test-Path -LiteralPath $inputPath -PathType Container) {
        $directRoots = @(Find-CpythonSourceRoots -SearchRoot $inputPath)
        if ($directRoots.Count -gt 0) {
            $sourceRoot = Select-CpythonRoot -Roots $directRoots
            $config.source_dir = $sourceRoot
            $config.sphinx_build = ''
            Save-Config -Config $config
            Write-Ok ("Detected CPython {0}: {1}" -f (Get-CpythonVersionText $sourceRoot), $sourceRoot)
            return $sourceRoot
        }
    }
    elseif ([string]::IsNullOrWhiteSpace((Get-ArchiveKind -Path $inputPath))) {
        throw "The selected file is not a supported source archive: $inputPath"
    }

    $config = Get-Config
    $wizardConfig = Get-ConfigValue $config 'wizard' $null
    $maxDepth = [int](Get-ConfigValue $wizardConfig 'maximum_nested_archive_depth' 6)
    $maxArchives = [int](Get-ConfigValue $wizardConfig 'maximum_nested_archives' 40)
    $temporaryRoot = Get-WizardTemporaryRoot
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    $workspace = Join-Path $temporaryRoot ((Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null

    $queue = New-Object System.Collections.ArrayList
    $processed = @{}
    if (Test-Path -LiteralPath $inputPath -PathType Leaf) {
        [void]$queue.Add([pscustomobject]@{ Path = $inputPath; Depth = 0 })
    }
    else {
        $initialArchives = Get-ChildItem -LiteralPath $inputPath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace((Get-ArchiveKind -Path $_.FullName)) } |
            Sort-Object { $_.FullName.Length }, FullName
        foreach ($archive in $initialArchives) {
            [void]$queue.Add([pscustomobject]@{ Path = $archive.FullName; Depth = 0 })
        }
    }

    $archiveCount = 0
    while ($queue.Count -gt 0) {
        $item = $queue[0]
        $queue.RemoveAt(0)
        $archivePath = [System.IO.Path]::GetFullPath([string]$item.Path)
        if ($processed.ContainsKey($archivePath)) { continue }
        $processed[$archivePath] = $true
        if ([int]$item.Depth -gt $maxDepth) { continue }
        $archiveCount++
        if ($archiveCount -gt $maxArchives) {
            throw "Stopped after $maxArchives nested archives without locating a CPython source tree."
        }

        $folderName = ('{0:D3}_{1}' -f $archiveCount, (Get-ArchiveBaseName -Path $archivePath))
        $folderName = $folderName -replace '[^A-Za-z0-9._-]', '_'
        $destination = Join-Path $workspace $folderName
        Write-Host ("Extracting [{0}/{1}]: {2}" -f $archiveCount, $maxArchives, $archivePath) -ForegroundColor Cyan
        Expand-SourceArchive -ArchivePath $archivePath -Destination $destination

        $roots = @(Find-CpythonSourceRoots -SearchRoot $destination)
        if ($roots.Count -gt 0) {
            $sourceRoot = Select-CpythonRoot -Roots $roots
            $config = Get-Config
            $config.source_dir = $sourceRoot
            $config.sphinx_build = ''
            Save-Config -Config $config
            $state = [pscustomobject]@{
                original_input = $inputPath
                temporary_workspace = $workspace
                source_dir = $sourceRoot
                prepared_at = (Get-Date).ToString('o')
            }
            $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding UTF8
            Write-Ok ("Detected CPython {0}: {1}" -f (Get-CpythonVersionText $sourceRoot), $sourceRoot)
            Write-Ok ("Temporary workspace: $workspace")
            return $sourceRoot
        }

        $nestedArchives = Get-ChildItem -LiteralPath $destination -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace((Get-ArchiveKind -Path $_.FullName)) } |
            Sort-Object { $_.FullName.Length }, FullName
        foreach ($nestedArchive in $nestedArchives) {
            if (-not $processed.ContainsKey($nestedArchive.FullName)) {
                [void]$queue.Add([pscustomobject]@{ Path = $nestedArchive.FullName; Depth = ([int]$item.Depth + 1) })
            }
        }
    }

    throw "No supported CPython source tree was found in the selected input. Temporary extraction remains at: $workspace"
}

function Configure-BuildOptions {
    $config = Get-Config
    Write-Host ''
    Write-Host 'Build choices (press Enter to accept each displayed default):' -ForegroundColor Cyan

    $currentArchitecture = [string](@(Get-ConfigValue $config 'architectures' @('x64'))[0])
    $architecture = (Read-Host "Architecture [x64/x86] [$currentArchitecture]").Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($architecture)) { $architecture = $currentArchitecture }
    if ($architecture -notin @('x64', 'x86')) {
        Write-Warn 'Unsupported response; retaining the current architecture.'
        $architecture = $currentArchitecture
    }
    $config.architectures = @($architecture)
    $config.build_documentation = Read-YesNo -Prompt 'Build HTML documentation?' -Default ([bool]$config.build_documentation)
    $config.run_cpython_tests = Read-YesNo -Prompt 'Run the complete CPython regression tests?' -Default ([bool]$config.run_cpython_tests)
    $config.clean_before_build = Read-YesNo -Prompt 'Clean old source build outputs before starting?' -Default ([bool]$config.clean_before_build)
    $config.copy_documentation_to_output = $true
    Save-Config -Config $config
    Write-Ok 'Build choices saved.'
}

function Invoke-ChildPowerShell {
    param(
        [string]$ScriptName,
        [string[]]$Arguments = @(),
        [string]$Description
    )
    $scriptPath = Join-Path $scriptDirectory $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Required builder script not found: $scriptPath"
    }
    Write-Host ''
    Write-Host ("--- $Description ---") -ForegroundColor Cyan
    $commandArguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $Arguments
    & powershell.exe @commandArguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$Description failed with exit code $exitCode."
    }
}

function Invoke-SystemPrerequisites {
    Invoke-ChildPowerShell -ScriptName 'setup_build_prerequisites.ps1' -Arguments @('-ConfigPath', $ConfigPath) -Description 'System prerequisite setup'
}

function Invoke-PythonRequirements {
    Invoke-ChildPowerShell -ScriptName 'setup_python_requirements.ps1' -Arguments @('-ConfigPath', $ConfigPath, '-RequirementsPath', (Join-Path $scriptDirectory 'requirements-optional.txt')) -Description 'Isolated documentation requirements setup'
}

function Invoke-Preflight {
    Invoke-ChildPowerShell -ScriptName 'build_python_installer.ps1' -Arguments @('-ConfigPath', $ConfigPath, '-PreflightOnly') -Description 'Preflight checks'
}

function Invoke-Build {
    Invoke-ChildPowerShell -ScriptName 'build_python_installer.ps1' -Arguments @('-ConfigPath', $ConfigPath) -Description 'CPython installer build'
}

function Invoke-LatestInstaller {
    Invoke-ChildPowerShell -ScriptName 'install_latest_build.ps1' -Arguments @('-ConfigPath', $ConfigPath) -Description 'Latest generated installer'
}

function Invoke-OpenDocumentation {
    Invoke-ChildPowerShell -ScriptName 'open_documentation.ps1' -Arguments @('-ConfigPath', $ConfigPath) -Description 'Generated documentation'
}

function Remove-PreparedTemporarySource {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        Write-Warn 'No wizard-managed temporary source is recorded.'
        return
    }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $workspace = [System.IO.Path]::GetFullPath([string]$state.temporary_workspace)
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $temporaryRoot = (Get-WizardTemporaryRoot).TrimEnd($separator) + $separator
    if (-not $workspace.StartsWith($temporaryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a folder outside the wizard temporary root: $workspace"
    }
    if (Test-Path -LiteralPath $workspace -PathType Container) {
        Remove-Item -LiteralPath $workspace -Recurse -Force
        Write-Ok ("Removed temporary source workspace: $workspace")
    }
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    $config = Get-Config
    if ([string]$config.source_dir -eq [string]$state.source_dir) {
        $config.source_dir = ''
        $config.sphinx_build = ''
        Save-Config -Config $config
        Write-Ok 'Cleared the temporary source path from builder_config.json.'
    }
}

function Invoke-FullWorkflow {
    Write-Title 'Guided CPython Source-to-Installer Workflow'
    Write-Step 1 'Select or extract a CPython source release'
    [void](Prepare-CpythonSource)

    Write-Step 2 'Choose build options'
    Configure-BuildOptions

    Write-Step 3 'System prerequisites'
    if (Read-YesNo -Prompt 'Run/repair Git, Visual Studio Build Tools, and legacy WiX prerequisites now?' -Default $false) {
        Invoke-SystemPrerequisites
    }
    else {
        Write-Host 'Skipping installation; preflight will verify what is already present.' -ForegroundColor DarkGray
    }

    Write-Step 4 'Prepare isolated documentation requirements'
    $config = Get-Config
    if ([bool]$config.build_documentation) {
        Invoke-PythonRequirements
    }
    else {
        Write-Host 'Documentation is disabled; no Sphinx environment is needed.' -ForegroundColor DarkGray
    }

    Write-Step 5 'Run preflight checks'
    try {
        Invoke-Preflight
    }
    catch {
        Write-Warn $_.Exception.Message
        if (Read-YesNo -Prompt 'Run the system prerequisite repair and retry preflight?' -Default $true) {
            Invoke-SystemPrerequisites
            if ([bool](Get-Config).build_documentation) { Invoke-PythonRequirements }
            Invoke-Preflight
        }
        else { throw }
    }

    Write-Step 6 'Build the CPython installer'
    Invoke-Build

    Write-Step 7 'Install and inspect the result'
    if (Read-YesNo -Prompt 'Launch the newest generated installer now?' -Default $true) {
        Invoke-LatestInstaller
    }
    if ([bool](Get-Config).build_documentation -and (Read-YesNo -Prompt 'Open the generated HTML documentation?' -Default $false)) {
        Invoke-OpenDocumentation
    }

    Write-Step 8 'Optional temporary-source cleanup'
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        if (Read-YesNo -Prompt 'Remove the wizard-extracted temporary source now? Final installer output and copied documentation are preserved.' -Default $false) {
            Remove-PreparedTemporarySource
        }
        else {
            Write-Host 'Temporary source retained for another build or troubleshooting.' -ForegroundColor DarkGray
        }
    }

    Write-Title 'Workflow complete'
    Write-Ok 'The generated installer is in the output folder.'
}

function Show-Menu {
    Write-Title 'CPython Windows Installer Builder v1.0.0'
    Write-Host 'Choose the guided workflow below. Manual tools are stored in advanced_tools.'
    Write-Host ''
    Write-Host '  1. Guided full workflow (recommended)'
    Write-Host '  2. Prepare/extract source archive only'
    Write-Host '  3. Configure build options'
    Write-Host '  4. Install or repair system prerequisites'
    Write-Host '  5. Prepare isolated documentation requirements'
    Write-Host '  6. Run preflight only'
    Write-Host '  7. Build installer only'
    Write-Host '  8. Launch newest generated installer'
    Write-Host '  9. Open generated documentation'
    Write-Host '  C. Clean wizard temporary source'
    Write-Host '  Q. Quit'
}

try {
    while ($true) {
        Show-Menu
        $choice = (Read-Host 'Choose an option').Trim().ToUpperInvariant()
        try {
            switch ($choice) {
                '1' { Invoke-FullWorkflow }
                '2' { [void](Prepare-CpythonSource -ForcePrompt) }
                '3' { Configure-BuildOptions }
                '4' { Invoke-SystemPrerequisites }
                '5' { Invoke-PythonRequirements }
                '6' { Invoke-Preflight }
                '7' { Invoke-Build }
                '8' { Invoke-LatestInstaller }
                '9' { Invoke-OpenDocumentation }
                'C' { Remove-PreparedTemporarySource }
                'Q' { exit 0 }
                default { Write-Warn 'Unknown menu option.' }
            }
        }
        catch {
            Write-Host ''
            Write-Host ('[ERROR] {0}' -f $_.Exception.Message) -ForegroundColor Red
        }
        Write-Host ''
        [void](Read-Host 'Press Enter to return to the menu')
    }
}
catch {
    Write-Host ''
    Write-Host ('[ERROR] {0}' -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
