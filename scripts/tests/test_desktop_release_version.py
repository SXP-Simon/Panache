"""Release overrides must reach both the Flutter command and bundled backend."""

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SOURCE = Path(__file__).resolve().parents[1] / "build-flutter-desktop.py"
SPEC = importlib.util.spec_from_file_location("desktop_build", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DesktopReleaseVersionTest(unittest.TestCase):
    def test_override_is_used_by_archive_backend_and_flutter_without_source_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = {
                "VERSION": "1.34.0\n",
                "LICENSE": "project license",
                "crates/handwriting-core/NOTICE": "notice",
                "crates/handwriting-core/licenses/license.txt": "core license",
                "assets/licenses/font-license.txt": "font license",
                "assets/font_assets/font.ttf": "font",
                "target/release/handwriting-server.exe": "backend",
                "app/build/windows/x64/runner/Release/handwriting_app.exe": "app",
            }
            for name, value in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(value, encoding="utf-8")
            commands = []

            def fake_run(*arguments, **_kwargs):
                self.assertEqual(os.environ["HANDWRITING_BUILD_VERSION"], "2.3.4")
                commands.append(arguments)

            with patch.object(MODULE, "ROOT", root), \
                 patch.object(MODULE.platform, "system", return_value="Windows"), \
                 patch.object(MODULE.platform, "machine", return_value="AMD64"), \
                 patch.object(MODULE, "run", side_effect=fake_run), \
                 patch.dict(os.environ, {}, clear=True), \
                 patch("sys.argv", [str(SOURCE), "--version", "2.3.4", "--build-number", "2003004"]):
                MODULE.main()
            self.assertEqual((root / "VERSION").read_text(), "1.34.0\n")
            self.assertTrue(any("--build-name=2.3.4" in command and
                                "--build-number=2003004" in command for command in commands))
            archive = root / "target/desktop-package/windows/Panache-2.3.4-AMD64.zip"
            with zipfile.ZipFile(archive) as package:
                self.assertEqual(package.read("Panache/backend/VERSION"), b"2.3.4\n")
                self.assertIn("Panache/handwriting_app.exe", package.namelist())
                self.assertIn("Panache/backend/licenses/font-license.txt", package.namelist())

    def test_macos_selects_panache_app_even_if_a_stale_legacy_bundle_exists(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            products = root / "app/build/macos/Build/Products/Release"
            for name in ["HandwritingWeb", "Panache"]:
                binary = products / f"{name}.app/Contents/MacOS/{name}"
                binary.parent.mkdir(parents=True)
                binary.write_text(name)
            with patch.object(MODULE, "ROOT", root), \
                 patch.object(MODULE.platform, "system", return_value="Darwin"), \
                 patch.object(MODULE.platform, "machine", return_value="arm64"), \
                 patch.object(MODULE, "run") as run, \
                 patch("sys.argv", [str(SOURCE), "--version", "2.3.4"]):
                MODULE.main()
            output = root / "target/desktop-package/macos"
            self.assertTrue((output / "Panache.app/Contents/MacOS/Panache").is_file())
            self.assertFalse((output / "HandwritingWeb.app").exists())
            self.assertIn(str(output / "Panache-2.3.4-arm64.zip"), run.call_args.args)

    def test_invalid_release_inputs_fail_before_running_builds(self):
        for arguments in [["--version", "../../wrong"], ["--version", "1.2.3", "--build-number", "0"],
                          ["--version", "1.2.3", "--build-number", "2100000001"]]:
            with self.subTest(arguments=arguments), patch.object(MODULE, "run") as run, \
                 patch("sys.argv", [str(SOURCE), *arguments]):
                with self.assertRaises(SystemExit):
                    MODULE.main()
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
