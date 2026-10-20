"""隔离测试启动器 PE 资源复制不会破坏 Dart AOT 快照。"""

import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'windows_launcher.py'
SPEC = importlib.util.spec_from_file_location('windows_launcher', SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class LauncherTest(unittest.TestCase):
    def test_pe_subsystem_rejects_malformed_headers_without_modification(self):
        for data in [b'not a PE', b'MZ' + bytes(62), b'MZ' + bytes(58) + struct.pack('<I', 4096)]:
            with self.subTest(data=data), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'launcher.exe'
                path.write_bytes(data)
                with self.assertRaises((ValueError, struct.error)):
                    MODULE.gui_subsystem(path)
                self.assertEqual(path.read_bytes(), data)

    @unittest.skipUnless(sys.platform == 'win32', 'Windows native resources')
    def test_branded_gui_launcher_keeps_executable_aot_snapshot(self):
        helper = os.environ.get('PANACHE_COMPILED_UPDATER')
        if not helper:
            self.skipTest('Run with PANACHE_COMPILED_UPDATER pointing to the compiled helper')
        with tempfile.TemporaryDirectory(prefix='Panache 品牌 ') as directory:
            launcher = Path(directory) / 'handwriting_app.exe'
            shutil.copy2(helper, launcher)
            source = Path(sys.executable)
            before = hashlib.sha256(source.read_bytes()).hexdigest()
            MODULE.brand_launcher(source, launcher)
            with launcher.open('rb') as stream:
                stream.seek(60)
                offset = struct.unpack('<I', stream.read(4))[0]
                stream.seek(offset + 24 + 68)
                self.assertEqual(struct.unpack('<H', stream.read(2))[0], 2)
            result = subprocess.run([str(launcher), '--self-check'], check=True,
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.stdout.strip(), 'PANACHE_UPDATER_PROTOCOL 1')
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), before)


if __name__ == '__main__':
    unittest.main()
