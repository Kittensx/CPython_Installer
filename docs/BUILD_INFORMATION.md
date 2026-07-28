# Build Information

## Distribution identity

| Field | Value |
|---|---|
| Distribution | Independent CPython 3.10.20 Windows installer |
| CPython version | 3.10.20 |
| Architecture | x64 |
| Builder | CPython Installer Builder 1.0.0 |
| Builder repository | https://github.com/Kittensx/CPython_Installer |
| Installer mode | Private side-by-side |
| Publisher identity | Independent build; not an official python.org release |
| Digital signature | Unsigned unless a code-signing certificate is configured |

> This package contains an independently built distribution of CPython. It is
> not an official python.org release and is not affiliated with or endorsed by
> the Python Software Foundation.

## Source

| Field | Value |
|---|---|
| Upstream project | CPython |
| Upstream release | CPython 3.10.20 |
| Upstream tag | `v3.10.20` |
| Source page | https://www.python.org/downloads/release/python-31020/ |
| Source archive filename | **REPLACE AFTER FINAL BUILD** |
| Source archive SHA-256 | **REPLACE AFTER FINAL BUILD** |
| Source acquisition date | **REPLACE AFTER FINAL BUILD** |

### CPython source modifications

No CPython source-code modifications are intended for this build.

The builder changes build configuration only:

- Disables CPython's test-marker branding.
- Requests release-style version text.
- Uses an independent/private MSI identity rather than the official release identity.
- Builds documentation in an isolated Python environment.
- Builds and packages the Windows x64 installer.

If the CPython source is edited before distribution, replace the statement
above with a brief, accurate summary of every change. The Python Software
Foundation License requires a brief summary when a derivative version is made
available to others.

## Build environment

The following values describe the environment used to validate the builder.
Confirm and update them for the final public artifact.

| Component | Value |
|---|---|
| Operating system | Windows 11, x64 |
| Windows build | `26200.8875` during validation |
| Visual Studio | Visual Studio 2022 Build Tools |
| Visual Studio version | `17.14.37516.0` during validation |
| MSBuild | 17.14, .NET Framework host |
| MSVC platform toolset | `v143` |
| Target architecture | `x64` |
| Legacy compatibility | .NET Framework 3.5 enabled for legacy WiX tasks |
| Documentation builder | Sphinx `3.4.3` |
| Isolated setuptools | `80.10.2` during validation |
| WiX | Version supplied by the selected CPython source build workflow |

## Builder configuration

| Option | Value |
|---|---|
| Packed installer EXE | Enabled |
| Complete installer layout | Retained |
| Documentation | Enabled |
| Documentation copied to output | Enabled |
| CPython regression tests | Enabled |
| Clean build | Enabled for final release build |
| PGO | Disabled unless explicitly changed |
| NuGet package | Disabled unless explicitly changed |
| Embeddable ZIP | Enabled |
| Test marker | Disabled |
| Release-style installer name | Enabled |
| Official CPython MSI identity | Disabled |

## Validation record

Complete this section after building the exact files that will be published.
Do not mark a check as complete based only on an earlier test build.

- [ ] Source archive hash recorded.
- [ ] Prerequisite preflight passed.
- [ ] CPython Debug configuration compiled.
- [ ] CPython Release configuration compiled.
- [ ] HTML documentation built successfully.
- [ ] WiX/MSI projects completed with zero errors.
- [ ] CPython regression-test stage completed successfully.
- [ ] Installer completed on a test system.
- [ ] Installed executable reports `Python 3.10.20` without `-test` branding.
- [ ] Installed executable path was verified.
- [ ] `ssl`, `sqlite3`, `ctypes`, `bz2`, `lzma`, and `tkinter` imported successfully.
- [ ] Tcl/Tk test window opened successfully.
- [ ] `ensurepip` and pip were tested.
- [ ] A virtual environment was created and executed successfully.
- [ ] Side-by-side operation with other Python installations was verified.
- [ ] Final release files were hashed after all edits and packaging were complete.

## Published artifacts

Replace the placeholder rows with the exact GitHub Release filenames and
hashes. The values must match `SHA256SUMS.txt`.

| Filename | Size | SHA-256 |
|---|---:|---|
| `REPLACE-WITH-INSTALLER.exe` | **REPLACE** | **REPLACE** |
| `CPython_Installer_Builder_v1.0.0.zip` | **REPLACE** | **REPLACE** |

## Build date and revision

| Field | Value |
|---|---|
| Build date, UTC | **REPLACE AFTER FINAL BUILD** |
| Builder release/tag | `v1.0.0` or **REPLACE** |
| Builder Git commit | **REPLACE WITH COMMIT HASH** |
| Build log retained | Yes |
| Build manifest retained | Yes |
| SHA-256 manifest retained | Yes |

## Included legal files

The release should make these files available:

```text
LICENSE                 MIT License for CPython Installer Builder
LICENSE-PYTHON.txt      Exact license copied from CPython 3.10.20
THIRD_PARTY_NOTICES.md  CPython and incorporated-software notices
BUILD_INFORMATION.md    This build record
SHA256SUMS.txt           Final artifact checksums
```

## Reproducibility note

Windows installer builds may not be byte-for-byte reproducible across machines
or build dates because timestamps, tool versions, downloaded dependencies,
installer metadata, and signing can affect output bytes. This file records the
actual environment and hashes of the published artifacts so recipients can
verify that their downloads match the files produced for this release.
