param(
    [string]$ConfigPath = "",
    [string]$RequirementsPath = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Resolve-ScriptDirectory {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }
    if ($PSCommandPath) {
        return (Split-Path -Parent $PSCommandPath)
    }
    if ($MyInvocation.MyCommand.Path) {
        return (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }
    return (Get-Location).Path
}

function Write-Status {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $line = "[{0}] {1}" -f $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}

function Invoke-LoggedNative {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description,
        [string]$WorkingDirectory = ""
    )

    Write-Status $Description
    Write-Status ('Command: "{0}" {1}' -f $Executable, ($Arguments -join " "))

    $savedErrorActionPreference = $ErrorActionPreference
    $nativePreferenceVariable = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $savedNativePreference = $null
    if ($null -ne $nativePreferenceVariable) {
        $savedNativePreference = $nativePreferenceVariable.Value
    }

    $pushedLocation = $false
    try {
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            Push-Location -LiteralPath $WorkingDirectory
            $pushedLocation = $true
        }

        # Native tools frequently use stderr for warnings and progress. Keep
        # that output visible and logged, but use the process exit code to
        # determine success.
        $ErrorActionPreference = "Continue"
        if ($null -ne $nativePreferenceVariable) {
            Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false
        }

        $output = & $Executable @Arguments 2>&1
        $exitCode = $LASTEXITCODE

        foreach ($line in $output) {
            $lineText = ""
            if ($line -is [System.Management.Automation.ErrorRecord]) {
                $lineText = $line.Exception.Message
                if ([string]::IsNullOrWhiteSpace($lineText)) {
                    $lineText = $line.ToString()
                }
            }
            else {
                $lineText = [string]$line
            }

            Write-Host $lineText
            Add-Content -LiteralPath $script:LogPath -Value $lineText -Encoding UTF8
        }
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
        if ($null -ne $nativePreferenceVariable) {
            Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $savedNativePreference
        }
        if ($pushedLocation) {
            Pop-Location
        }
    }

    if ($exitCode -ne 0) {
        throw "$Description failed with exit code $exitCode."
    }
}

function Test-PythonExecutable {
    param([string]$Candidate)

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $null
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Candidate.Trim('"'))
    if (-not (Test-Path -LiteralPath $expanded -PathType Leaf)) {
        return $null
    }

    try {
        $output = & $expanded -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $null
        }

        $reported = ([string]($output | Select-Object -Last 1)).Trim()
        if (Test-Path -LiteralPath $reported -PathType Leaf) {
            return (Resolve-Path -LiteralPath $reported).Path
        }

        return (Resolve-Path -LiteralPath $expanded).Path
    }
    catch {
        return $null
    }
}

function Resolve-PythonExecutable {
    param([object]$Config)

    $configured = ""
    if ($Config.PSObject.Properties.Name -contains "bootstrap_python") {
        $configured = [string]$Config.bootstrap_python
    }

    $useAutomaticDiscovery = [string]::IsNullOrWhiteSpace($configured) -or `
        $configured.Trim().Equals("auto", [System.StringComparison]::OrdinalIgnoreCase)

    if (-not $useAutomaticDiscovery) {
        $expanded = [Environment]::ExpandEnvironmentVariables($configured.Trim('"'))

        $resolved = Test-PythonExecutable -Candidate $expanded
        if ($resolved) {
            return $resolved
        }

        $command = Get-Command $expanded -ErrorAction SilentlyContinue
        if ($command) {
            $resolved = Test-PythonExecutable -Candidate $command.Source
            if ($resolved) {
                return $resolved
            }
        }

        throw "bootstrap_python was configured but could not be found or executed: $configured"
    }

    Write-Status "bootstrap_python is auto; searching for an installed Python interpreter."

    # Prefer the Windows Python launcher because it can select Python 3.10
    # even when Python is not present on PATH.
    $launcher = Get-Command "py.exe" -ErrorAction SilentlyContinue
    if (-not $launcher) {
        $launcher = Get-Command "py" -ErrorAction SilentlyContinue
    }

    if ($launcher) {
        foreach ($selector in @("-3.10", "-3")) {
            try {
                $output = & $launcher.Source $selector -c "import sys; print(sys.executable)" 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $reported = ([string]($output | Select-Object -Last 1)).Trim()
                    $resolved = Test-PythonExecutable -Candidate $reported
                    if ($resolved) {
                        Write-Status "Python discovered through py $selector." "OK"
                        return $resolved
                    }
                }
            }
            catch {
                # Continue to the next discovery method.
            }
        }
    }

    # Check standard per-user and machine-wide CPython installation folders.
    $directCandidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $directCandidates.Add((Join-Path $env:LOCALAPPDATA "Programs\Python\Python310\python.exe"))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $directCandidates.Add((Join-Path $env:ProgramFiles "Python310\python.exe"))
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $directCandidates.Add((Join-Path ${env:ProgramFiles(x86)} "Python310\python.exe"))
    }

    foreach ($candidate in $directCandidates) {
        $resolved = Test-PythonExecutable -Candidate $candidate
        if ($resolved) {
            Write-Status "Python discovered in a standard installation folder." "OK"
            return $resolved
        }
    }

    $searchRoots = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $searchRoots.Add((Join-Path $env:LOCALAPPDATA "Programs\Python"))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $searchRoots.Add($env:ProgramFiles)
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $searchRoots.Add(${env:ProgramFiles(x86)})
    }

    foreach ($root in $searchRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        $directories = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "Python3*" -or $_.Name -like "Python-*" } |
            Sort-Object Name -Descending

        foreach ($directory in $directories) {
            $resolved = Test-PythonExecutable -Candidate (Join-Path $directory.FullName "python.exe")
            if ($resolved) {
                Write-Status "Python discovered under $root." "OK"
                return $resolved
            }
        }
    }

    # Fall back to PATH after checking real installation directories. This
    # avoids preferring the Microsoft Store app-execution alias when possible.
    foreach ($candidateName in @("python.exe", "python")) {
        $command = Get-Command $candidateName -ErrorAction SilentlyContinue
        if ($command) {
            $resolved = Test-PythonExecutable -Candidate $command.Source
            if ($resolved) {
                Write-Status "Python discovered on PATH." "OK"
                return $resolved
            }
        }
    }

    # Last resort: use an already-built interpreter from the selected CPython
    # source tree. This normally applies only after a prior successful build.
    if ($Config.PSObject.Properties.Name -contains "source_dir") {
        $sourceDirectory = [Environment]::ExpandEnvironmentVariables(([string]$Config.source_dir).Trim('"'))
        foreach ($relativePath in @(
            "PCbuild\amd64\python.exe",
            "PCbuild\win32\python.exe",
            "PCbuild\arm64\python.exe"
        )) {
            $resolved = Test-PythonExecutable -Candidate (Join-Path $sourceDirectory $relativePath)
            if ($resolved) {
                Write-Status "Python discovered in the CPython build output." "OK"
                return $resolved
            }
        }
    }

    throw "No usable Python interpreter was found automatically. Set bootstrap_python to the full path of python.exe in builder_config.json."
}

function Save-JsonWithoutBom {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $json = $Value | ConvertTo-Json -Depth 32
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
}

$scriptDirectory = Resolve-ScriptDirectory

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptDirectory "builder_config.json"
}
if ([string]::IsNullOrWhiteSpace($RequirementsPath)) {
    $RequirementsPath = Join-Path $scriptDirectory "requirements-optional.txt"
}

$ConfigPath = [Environment]::ExpandEnvironmentVariables($ConfigPath)
$RequirementsPath = [Environment]::ExpandEnvironmentVariables($RequirementsPath)

$logDirectory = Join-Path $scriptDirectory "logs"
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:LogPath = Join-Path $logDirectory "setup_python_requirements_$stamp.log"
New-Item -ItemType File -Path $script:LogPath -Force | Out-Null

try {
    Write-Status "Python build-requirements setup started."
    Write-Status "Config: $ConfigPath"
    Write-Status "Optional requirements: $RequirementsPath"

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configuration file not found: $ConfigPath"
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

    $buildDocumentation = $false
    if ($config.PSObject.Properties.Name -contains "build_documentation") {
        $buildDocumentation = [bool]$config.build_documentation
    }

    if (-not $buildDocumentation) {
        Write-Status "build_documentation is false. Optional documentation requirements were skipped." "OK"
        Write-Status "Nothing needed to be installed." "OK"
        exit 0
    }

    $bootstrapPython = Resolve-PythonExecutable -Config $config
    Write-Status "Bootstrap Python: $bootstrapPython" "OK"

    # Builder dependencies must not be installed into the user's main Python
    # environment. That environment may contain Torch or other applications
    # with their own setuptools and package constraints.
    $requirementsEnvironment = Join-Path $scriptDirectory ".builder_requirements_venv"
    if ($config.PSObject.Properties.Name -contains "requirements_environment") {
        $configuredEnvironment = [Environment]::ExpandEnvironmentVariables(
            ([string]$config.requirements_environment).Trim('"')
        )
        if (-not [string]::IsNullOrWhiteSpace($configuredEnvironment)) {
            if ([System.IO.Path]::IsPathRooted($configuredEnvironment)) {
                $requirementsEnvironment = $configuredEnvironment
            }
            else {
                $requirementsEnvironment = Join-Path $scriptDirectory $configuredEnvironment
            }
        }
    }
    $requirementsEnvironment = [System.IO.Path]::GetFullPath($requirementsEnvironment)

    $requirementsPython = Join-Path $requirementsEnvironment "Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $requirementsPython -PathType Leaf)) {
        Write-Status "Creating isolated builder requirements environment: $requirementsEnvironment"
        Invoke-LoggedNative -Executable $bootstrapPython `
            -Arguments @("-m", "venv", $requirementsEnvironment) `
            -Description "Creating isolated Python requirements environment"
    }
    else {
        Write-Status "Reusing isolated builder requirements environment: $requirementsEnvironment" "OK"
    }

    if (-not (Test-Path -LiteralPath $requirementsPython -PathType Leaf)) {
        throw "The isolated requirements environment was created, but python.exe was not found: $requirementsPython"
    }

    $python = (Resolve-Path -LiteralPath $requirementsPython).Path
    Write-Status "Requirements Python: $python" "OK"

    Invoke-LoggedNative -Executable $python `
        -Arguments @("-m", "pip", "--version") `
        -Description "Checking isolated pip"

    $sourceDirectory = ""
    if ($config.PSObject.Properties.Name -contains "source_dir") {
        $sourceDirectory = [Environment]::ExpandEnvironmentVariables(([string]$config.source_dir).Trim('"'))
    }

    $sourceRequirementsPath = ""
    $sourceDocumentationDirectory = ""
    if (-not [string]::IsNullOrWhiteSpace($sourceDirectory)) {
        $candidateDocumentationDirectory = Join-Path $sourceDirectory "Doc"
        $candidateRequirementsPath = Join-Path $candidateDocumentationDirectory "requirements.txt"
        if (Test-Path -LiteralPath $candidateRequirementsPath -PathType Leaf) {
            $sourceDocumentationDirectory = (Resolve-Path -LiteralPath $candidateDocumentationDirectory).Path
            $sourceRequirementsPath = (Resolve-Path -LiteralPath $candidateRequirementsPath).Path
        }
    }

    $optionalRequirementLines = @()
    if (Test-Path -LiteralPath $RequirementsPath -PathType Leaf) {
        $optionalRequirementLines = @(
            Get-Content -LiteralPath $RequirementsPath |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith("#") }
        )
    }

    $expectedSphinxVersion = ""
    if (-not [string]::IsNullOrWhiteSpace($sourceRequirementsPath)) {
        Write-Status "Using CPython documentation requirements: $sourceRequirementsPath" "OK"
        foreach ($line in Get-Content -LiteralPath $sourceRequirementsPath) {
            if ($line -match '^\s*sphinx==([^\s#;]+)') {
                $expectedSphinxVersion = $Matches[1]
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($sourceRequirementsPath) -and $optionalRequirementLines.Count -eq 0) {
        throw "build_documentation is true, but the selected CPython source has no Doc\\requirements.txt and requirements-optional.txt contains no active packages."
    }

    # Resolve the source requirements and optional requirements in one pip
    # transaction. The previous implementation used two separate --upgrade
    # commands; the second command used eager upgrades and could replace a
    # setuptools pin installed by the first command.
    $installArguments = New-Object System.Collections.Generic.List[string]
    foreach ($argument in @("-m", "pip", "install", "--upgrade", "--upgrade-strategy", "only-if-needed")) {
        $installArguments.Add($argument)
    }

    if (-not [string]::IsNullOrWhiteSpace($sourceRequirementsPath)) {
        $installArguments.Add("-r")
        $installArguments.Add($sourceRequirementsPath)
    }

    if ($optionalRequirementLines.Count -gt 0) {
        Write-Status "Including additional packages from requirements-optional.txt." "OK"
        $installArguments.Add("-r")
        $installArguments.Add($RequirementsPath)
    }
    else {
        Write-Status "No additional packages are listed in requirements-optional.txt." "OK"
    }

    # Sphinx versions before 5 import pkg_resources. Setuptools 81 warns that
    # pkg_resources is approaching removal, and setuptools 82+ removes it.
    # Apply the compatibility constraint during the same resolver transaction
    # so pip cannot immediately upgrade it again.
    $compatibilityConstraintsPath = Join-Path $logDirectory "requirements_constraints_$stamp.txt"
    $compatibilityConstraints = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($expectedSphinxVersion)) {
        $sphinxMajorText = $expectedSphinxVersion.Split(".")[0]
        $sphinxMajor = 0
        if ([int]::TryParse($sphinxMajorText, [ref]$sphinxMajor) -and $sphinxMajor -lt 5) {
            $compatibilityConstraints.Add("setuptools<81")
            Write-Status "Applying legacy Sphinx compatibility constraint: setuptools<81" "OK"
        }
    }

    if ($compatibilityConstraints.Count -gt 0) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines(
            $compatibilityConstraintsPath,
            [string[]]$compatibilityConstraints,
            $utf8NoBom
        )
        $installArguments.Add("-c")
        $installArguments.Add($compatibilityConstraintsPath)
    }

    Invoke-LoggedNative -Executable $python `
        -Arguments ([string[]]$installArguments) `
        -Description "Installing isolated source-compatible documentation requirements" `
        -WorkingDirectory $sourceDocumentationDirectory

    # Verify the isolated environment with a real Python script file.
    #
    # Windows PowerShell 5.1 does not reliably preserve multiline code passed
    # to a native executable through `python -c`. It may split or rewrite the
    # command string and produce a misleading syntax error such as:
    #
    #     File "<string>", line 3
    #
    # Write a temporary script and structured JSON result instead.
    $verificationScriptPath = Join-Path $logDirectory "verify_documentation_environment_$stamp.py"
    $verificationResultPath = Join-Path $logDirectory "verify_documentation_environment_$stamp.json"

    $verificationCode = @'
import json
import sys

import sphinx

result = {
    "sphinx_version": sphinx.__version__,
}

major = int(sphinx.__version__.split(".", 1)[0])
if major < 5:
    import pkg_resources
    import setuptools

    result["setuptools_version"] = setuptools.__version__
    result["pkg_resources_path"] = pkg_resources.__file__

with open(sys.argv[1], "w", encoding="utf-8") as output_file:
    json.dump(result, output_file, indent=2)
'@

    $verificationEncoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        $verificationScriptPath,
        $verificationCode + [Environment]::NewLine,
        $verificationEncoding
    )

    if (Test-Path -LiteralPath $verificationResultPath) {
        Remove-Item -LiteralPath $verificationResultPath -Force
    }

    Invoke-LoggedNative -Executable $python `
        -Arguments @($verificationScriptPath, $verificationResultPath) `
        -Description "Verifying isolated Sphinx environment"

    if (-not (Test-Path -LiteralPath $verificationResultPath -PathType Leaf)) {
        throw "The Sphinx verification process succeeded but did not create its JSON result: $verificationResultPath"
    }

    try {
        $verificationResult = Get-Content -LiteralPath $verificationResultPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "The Sphinx verification result could not be read as JSON: $verificationResultPath"
    }

    $installedSphinxVersion = [string]$verificationResult.sphinx_version
    if ([string]::IsNullOrWhiteSpace($installedSphinxVersion)) {
        throw "The Sphinx verification result did not contain a version."
    }

    Write-Status "Installed Sphinx version: $installedSphinxVersion" "OK"

    if ($verificationResult.PSObject.Properties.Name -contains "setuptools_version") {
        Write-Status ("Isolated setuptools version: {0}" -f [string]$verificationResult.setuptools_version) "OK"
    }

    if ($verificationResult.PSObject.Properties.Name -contains "pkg_resources_path") {
        Write-Status ("Isolated pkg_resources: {0}" -f [string]$verificationResult.pkg_resources_path) "OK"
    }

    if (-not [string]::IsNullOrWhiteSpace($expectedSphinxVersion) -and $installedSphinxVersion -ne $expectedSphinxVersion) {
        throw "The CPython source requires Sphinx $expectedSphinxVersion, but the isolated environment imports Sphinx $installedSphinxVersion."
    }

    $scriptsOutput = & $python -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>&1
    $scriptsExitCode = $LASTEXITCODE
    if ($scriptsExitCode -ne 0) {
        foreach ($line in $scriptsOutput) {
            Add-Content -LiteralPath $script:LogPath -Value ([string]$line) -Encoding UTF8
        }
        throw "Unable to determine the Python Scripts directory."
    }

    $scriptsDirectory = ([string]($scriptsOutput | Select-Object -Last 1)).Trim()
    $sphinxCandidates = @(
        (Join-Path $scriptsDirectory "sphinx-build.exe"),
        (Join-Path $scriptsDirectory "sphinx-build")
    )

    $sphinxBuild = $null
    foreach ($candidate in $sphinxCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $sphinxBuild = (Resolve-Path -LiteralPath $candidate).Path
            break
        }
    }

    if (-not $sphinxBuild) {
        $command = Get-Command "sphinx-build.exe" -ErrorAction SilentlyContinue
        if (-not $command) {
            $command = Get-Command "sphinx-build" -ErrorAction SilentlyContinue
        }
        if ($command) {
            $sphinxBuild = $command.Source
        }
    }

    if (-not $sphinxBuild) {
        throw "Sphinx was installed, but sphinx-build could not be located."
    }

    Write-Status "Sphinx executable: $sphinxBuild" "OK"

    if ($config.PSObject.Properties.Name -contains "sphinx_build") {
        $config.sphinx_build = $sphinxBuild
    }
    else {
        $config | Add-Member -NotePropertyName "sphinx_build" -NotePropertyValue $sphinxBuild
    }

    Save-JsonWithoutBom -Value $config -Path $ConfigPath
    Write-Status "Updated sphinx_build in builder_config.json." "OK"

    Invoke-LoggedNative -Executable $sphinxBuild `
        -Arguments @("--version") `
        -Description "Verifying Sphinx"

    Write-Status "Optional Python build requirements are ready." "OK"
    Write-Status "Log: $script:LogPath" "OK"
    exit 0
}
catch {
    Write-Status $_.Exception.Message "ERROR"
    Write-Status "See log: $script:LogPath" "ERROR"
    exit 1
}
