# Quick Start

1. Download an official CPython **source archive**. Do not choose the normal
   Windows installer; this tool needs the source ZIP or TAR archive.
2. Extract this builder ZIP into a normal writable folder.
3. Double-click `START_HERE.bat`.
4. Choose **1 - Guided full workflow**.
5. Drag the CPython source archive into the window when requested.
6. Accept the recommended options for a first build.
7. Allow the prerequisite step to install or repair missing Windows tools.
8. Leave the window open while compilation and regression tests run.
9. Find the completed installer in the root `output` folder.

The default public configuration builds x64, documentation, a packed EXE,
and the CPython regression tests. Test-marker branding is disabled, so a
final source release such as 3.10.20 uses the release-style label
`Python 3.10.20` rather than a `-test` label.
