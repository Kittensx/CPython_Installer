# Troubleshooting

## Where are the logs?

Build and setup logs are written under `builder\logs`. Each build also keeps
its main log and report in the corresponding timestamped `output` folder.

## The source archive has another archive inside it

That is supported. The guided workflow recursively recognizes ZIP, TAR,
TAR.GZ/TGZ, TAR.BZ2/TBZ2/TBZ, TAR.XZ/TXZ, and TAR.ZST/TZST archives. It
extracts them under `%TEMP%\CPythonInstallerBuilder` until it finds a valid
CPython source root.

## Visual Studio or MSBuild is missing

Run `START_HERE.bat`, choose the prerequisite option, and allow the elevation
prompt. The builder checks for Visual Studio Build Tools with the C++ workload
and chooses a compatible MSBuild/toolset for the selected CPython branch.

## WiX says Microsoft.Build.Utilities 2.0.0.0 is missing

Older CPython MSI branches use legacy WiX tasks that depend on the .NET
Framework 3.5 compatibility stack. Use:

`advanced_tools\07_INSTALL_LEGACY_NETFX35.bat`

Restart Windows if requested, then run preflight again.

## Sphinx or pkg_resources fails

The builder uses an isolated environment under
`runtime\.builder_requirements_venv`; it does not need to change packages in
your normal Python installation. To rebuild it, run:

`advanced_tools\08_RESET_ISOLATED_REQUIREMENTS.bat`

Then use the documentation-requirements option in `START_HERE.bat`.

## Git reports that the source is not a repository

Official source archives do not contain the `.git` directory. Git metadata
warnings can appear during compilation and are usually harmless when the
build summary still reports zero errors.

## The installer is unsigned

A locally generated installer is normally unsigned and Windows may show a
SmartScreen or unknown-publisher warning. Do not distribute a build unless
you trust the source archive and have reviewed the output. Code signing is an
advanced deployment responsibility.

## I only need a manual step

The numbered BAT files in `advanced_tools` expose individual maintenance,
preflight, build, install, documentation, and reset operations. Most users
should continue using `START_HERE.bat`.
