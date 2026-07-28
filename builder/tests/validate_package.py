from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "builder"


def main() -> None:
    root_files = sorted(path.name for path in ROOT.iterdir() if path.is_file())
    assert root_files == ["README.md", "START_HERE.bat"], root_files

    required = [
        ROOT / "START_HERE.bat",
        ROOT / "README.md",
        ROOT / "docs" / "LICENSE.md",
        ROOT / "docs" / "THIRD_PARTY_NOTICES.md",
        BUILDER / "builder_wizard.ps1",
        BUILDER / "build_python_installer.ps1",
        BUILDER / "builder_config.json",
    ]
    missing = [str(path.relative_to(ROOT)) for path in required if not path.is_file()]
    assert not missing, missing

    config = json.loads((BUILDER / "builder_config.json").read_text(encoding="utf-8-sig"))
    assert config["source_dir"] == ""
    assert config["sphinx_build"] == ""
    assert config["output_dir"] == "..\\output"
    assert config["requirements_environment"] == "..\\runtime\\.builder_requirements_venv"
    assert config["advanced"]["use_test_marker"] is False
    assert config["advanced"]["release_style_installer_name"] is True

    build = (BUILDER / "build_python_installer.ps1").read_text(encoding="utf-8-sig")
    assert "$args += '--no-test-marker'" in build
    assert "$env:BuildForRelease = 'true'" in build
    assert "$args += '--test-marker'" in build  # retained only behind explicit opt-in
    assert "CPython test-marker branding is disabled." in build

    wizard = (BUILDER / "builder_wizard.ps1").read_text(encoding="utf-8-sig")
    assert "CPython Windows Installer Builder v1.0.0" in wizard
    assert "Guided full workflow" in wizard
    assert "Expand-SafeZip" in wizard
    assert "Expand-SafeTar" in wizard

    assert (BUILDER / "VERSION.txt").read_text(encoding="utf-8").strip() == "1.0.0"

    forbidden = (
        "Joel" + " Davidson",
        "C:" + "\\Users\\photo",
        "D:" + "\\backup_software development",
        "README_" + "v1.1",
    )
    text_extensions = {".md", ".json", ".ps1", ".bat", ".txt", ".py"}
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in text_extensions:
            continue
        content = path.read_text(encoding="utf-8-sig", errors="ignore")
        for value in forbidden:
            assert value not in content, f"Forbidden value in {path.relative_to(ROOT)}: {value}"

    # Catch common Windows PowerShell expandable-string parsing mistakes.
    valid_scopes = {
        "alias", "env", "function", "global", "local", "private",
        "script", "using", "variable",
    }
    double_quoted_string = re.compile(r'"(?:`.|[^"`])*"')
    variable_before_colon = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*):')
    variable_before_question = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*)\?')
    for path in BUILDER.rglob("*.ps1"):
        content = path.read_text(encoding="utf-8-sig", errors="ignore")
        for line_number, line in enumerate(content.splitlines(), 1):
            for string_match in double_quoted_string.finditer(line):
                string = string_match.group(0)
                for match in variable_before_colon.finditer(string):
                    assert match.group(1).lower() in valid_scopes, (
                        f"Unbraced variable before colon in {path}:{line_number}"
                    )
                assert variable_before_question.search(string) is None, (
                    f"Unbraced variable before question mark in {path}:{line_number}"
                )

    print("Public package validation passed.")


if __name__ == "__main__":
    main()
