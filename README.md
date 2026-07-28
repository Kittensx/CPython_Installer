# CPython_Installer

A guided Windows builder for turning official CPython source releases into tested MSI installers. Supports ZIP, TAR, TAR.GZ, TAR.BZ2, TAR.XZ, and nested archives; handles prerequisites, isolated documentation tools, preflight checks, compilation, regression tests, packaging, cleanup, and side-by-side installs through one step-by-step launcher.

# CPython Installer Builder — Version 1.0.0

A guided Windows utility that turns an official CPython source release into a
locally built Windows installer. It is intended for people who want to build
Python themselves but do not want to manually coordinate Visual Studio,
MSBuild, WiX, Sphinx, source extraction, regression testing, and output
collection.

> **Start here:** double-click `START_HERE.bat`, then choose **1 - Guided full
> workflow**.

## What it does

The builder can:

- Read a CPython source folder or archive.
- Recursively unpack nested ZIP and TAR-family archives into a managed
  temporary folder.
- Detect the actual CPython source root automatically.
- Check or install Git, compatible Visual Studio Build Tools, and legacy WiX
  prerequisites.
- Create an isolated documentation environment without changing packages in
  your everyday Python installations.
- Build x64 Windows installers, generate documentation, run CPython regression
  tests, collect output, and create SHA-256 manifests.
- Launch the newest generated installer and optionally clean temporary source
  files afterward.

## Beginner quick start

1. Download an official CPython **source release** archive. A source ZIP,
   `.tar`, `.tar.gz`, `.tar.bz2`, `.tar.xz`, or equivalent nested archive is
   suitable.
2. Extract this builder package into a writable folder. Avoid running it
   directly from inside the downloaded ZIP.
3. Double-click `START_HERE.bat`.
4. Choose **1 - Guided full workflow**.
5. When asked for the source, drag the downloaded archive into the command
   window and press Enter.
6. For a first build, keep the recommended defaults:
   - Architecture: x64
   - Packed single EXE: enabled
   - Documentation: enabled
   - Regression tests: enabled
   - Clean build: enabled
7. Allow Windows Administrator access only when the prerequisite or installer
   steps request it.
8. Keep the command window open. Building CPython and running its tests can
   take a while.
9. Open the root `output` folder when the workflow finishes.

A shorter checklist is available in [`docs/QUICK_START.md`](docs/QUICK_START.md).

## Supported archive types

The guided source picker supports:

- `.zip`
- `.tar`
- `.tar.gz` and `.tgz`
- `.tar.bz2`, `.tbz2`, and `.tbz`
- `.tar.xz` and `.txz`
- `.tar.zst` and `.tzst`, when the installed Windows TAR tool supports them

Archives can be nested inside other supported archives. Extraction is limited
by depth and archive-count safeguards, and entries containing unsafe absolute
or parent-traversal paths are rejected.

## Installer name and version

The public default explicitly disables CPython's test marker and enables
release-style version text. For a final CPython 3.10.20 source release, the
installer should display **Python 3.10.20**, not
`Python 3.10.20dev…-test` or `Python 3.10.20-test`.

The result is still an independent local build. It is not an official,
python.org-signed installer. The builder keeps CPython's machine-local MSI
identity behavior instead of using the official release identity.

## Folder layout

```text
CPython_Installer_Builder/
├── START_HERE.bat          Recommended entry point
├── README.md               This guide
├── advanced_tools/         Manual troubleshooting and maintenance BAT files
├── builder/                Internal PowerShell implementation and config
├── docs/                   License, quick start, notices, and troubleshooting
├── output/                 Completed installers and build reports
└── runtime/                Isolated builder-only Python environment
```

The root is intentionally uncluttered. Normal users only need
`START_HERE.bat` and this README.

## What gets installed on the computer?

The prerequisite workflow may install or enable:

- Git for Windows
- Visual Studio 2022 Build Tools with C++ components
- .NET Framework 3.5 compatibility support for older WiX-based CPython builds

The builder also creates its own isolated documentation environment under
`runtime`. It does not intentionally upgrade or remove packages from your
normal Python environments.

## Output and documentation

Each build creates a timestamped folder under `output`. Depending on selected
options, that folder can include:

- The packed Python installer EXE
- The complete installer layout
- Copied HTML documentation
- `build.log`
- `build_report.txt`
- `build_manifest.json`
- `SHA256SUMS.txt`

## Advanced tools

The numbered BAT files in `advanced_tools` run individual steps such as
prerequisite repair, documentation setup, preflight, build-only mode, latest
installer launch, legacy .NET setup, and isolated-environment reset.

They are provided for troubleshooting. Use the guided workflow first.

## Important safety notes

- Build only source archives obtained from a source you trust.
- Locally generated installers are normally unsigned.
- Test the generated interpreter in a separate install directory before
  replacing an older Python installation.
- Keep existing project virtual environments until the new interpreter has
  passed your application-specific tests.
- Review `docs/THIRD_PARTY_NOTICES.md` before redistributing a generated
  installer.

## Troubleshooting

See [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md). Logs are stored under
`builder/logs` and inside each timestamped output folder.

## License

The CPython Installer Builder code is licensed under the MIT License:
[`docs/LICENSE.md`](docs/LICENSE.md).

Copyright (c) 2026 KittensX.

CPython and bundled third-party components retain their own licenses. See
[`docs/THIRD_PARTY_NOTICES.md`](docs/THIRD_PARTY_NOTICES.md).
