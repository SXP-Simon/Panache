# Copyright (C) 2026 SXP-Simon
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest


@pytest.mark.skipif(sys.platform != "win32", reason="Real NSIS and Windows image lifecycle")
def test_updated_installer_never_kills_independent_same_named_process(tmp_path):
    compiler = os.environ.get("PANACHE_TEST_MAKENSIS") or shutil.which("makensis")
    if not compiler:
        pytest.skip("Set PANACHE_TEST_MAKENSIS to a real makensis.exe")
    desktop = Path(__file__).resolve().parents[1]
    include = desktop.parent / "node_modules/app-builder-lib/templates/nsis/include"
    product_name = "Panache-nsis-fixture.exe"
    owned = tmp_path / product_name
    shutil.copy2(Path(os.environ["SYSTEMROOT"]) / "System32/ping.exe", owned)
    package = tmp_path / "installer-fixture.exe"
    script = tmp_path / "fixture.nsi"
    script.write_text(
        "\n".join(
            [
                "Unicode true",
                'Name "Panache safety fixture"',
                f'OutFile "{package}"',
                "SilentInstall silent",
                "RequestExecutionLevel user",
                '!include "LogicLib.nsh"',
                f'!addincludedir "{include}"',
                '!define APP_GUID "Panache-nsis-safety-fixture"',
                '!define PRODUCT_NAME "Panache fixture"',
                f'!define APP_EXECUTABLE_FILENAME "{product_name}"',
                '!define isUpdated "1 == 1"',
                f'!include "{desktop / "installer.nsh"}"',
                '!include "allowOnlyOneInstallerInstance.nsh"',
                'LangString appRunning 1033 "Fixture running"',
                'LangString appCannotBeClosed 1033 "Fixture cannot close"',
                "Section",
                "!insertmacro CHECK_APP_RUNNING",
                "SetErrorLevel 0",
                "SectionEnd",
            ]
        ),
        encoding="utf-8-sig",
    )
    subprocess.run([compiler, str(script)], check=True, capture_output=True, timeout=30)  # noqa: S603
    process = subprocess.Popen(  # noqa: S603
        [str(owned), "127.0.0.1", "-t"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NO_WINDOW,
    )
    try:
        assert process.poll() is None
        result = subprocess.run([str(package), "/S"], check=False, capture_output=True, timeout=30)  # noqa: S603
        assert result.returncode == 32
        assert process.poll() is None
    finally:
        process.terminate()
        process.wait(timeout=10)
    result = subprocess.run([str(package), "/S"], check=False, capture_output=True, timeout=30)  # noqa: S603
    assert result.returncode == 0
