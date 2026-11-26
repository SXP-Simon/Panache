"""Run on Linux with a C compiler and GNU binutils."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'check-linux-glibc.py'


@unittest.skipUnless(sys.platform.startswith('linux') and shutil.which('cc') and shutil.which('readelf'),
                     'requires Linux cc and GNU readelf')
class LinuxGlibcTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.bundle = self.root / 'Panache'
        self.backend = self.bundle / 'backend'
        self.backend.mkdir(parents=True)
        # The provider defines a high version and contains an unrelated version string.
        # Only an ELF that imports its function should count against the ceiling.
        (self.root / 'provider.c').write_text('const char *probe(void) { return "GLIBC_99.99"; }')
        (self.root / 'versions').write_text('GLIBC_2.10 { global: probe; };')
        self.provider = self.bundle / 'provider.so'
        subprocess.run(['cc', '-shared', '-fPIC', '-nostdlib', 'provider.c',
                        '-Wl,--version-script=versions', '-o', self.provider], cwd=self.root, check=True)
        for rel in ('handwriting_app', 'backend/panache-mcp', 'backend/handwriting-server'):
            shutil.copyfile(self.provider, self.bundle / rel)

    def check(self, *args, path=None):
        env = os.environ.copy()
        if path is not None:
            env['PATH'] = path
        return subprocess.run([sys.executable, SCRIPT, self.bundle, *args],
                              capture_output=True, text=True, env=env)

    def test_definition_string_and_real_import(self):
        self.assertEqual(self.check('--max-glibc', '2.9').returncode, 0)
        (self.root / 'consumer.c').write_text('extern const char *probe(void);'
                                               'const char *call(void) { return probe(); }')
        subprocess.run(['cc', '-shared', '-fPIC', '-nostdlib', 'consumer.c',
                        self.provider, '-o', self.bundle / 'extra.so'], cwd=self.root, check=True)
        result = self.check('--max-glibc', '2.9')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('extra.so: requires GLIBC_2.10', result.stdout)
        self.assertEqual(self.check('--max-glibc', '2.10.0').returncode, 0)

    def test_missing_backend(self):
        (self.backend / 'panache-mcp').unlink()
        result = self.check('--max-glibc', '2.41')
        self.assertEqual(result.returncode, 4)
        self.assertIn('backend/panache-mcp', result.stderr)

    def test_damaged_elf(self):
        (self.backend / 'handwriting-server').write_bytes(b'\x7fELF')
        result = self.check('--max-glibc', '2.41')
        self.assertEqual(result.returncode, 3)
        self.assertIn('backend/handwriting-server', result.stderr)

    def test_missing_tool(self):
        self.assertEqual(self.check('--max-glibc', '2.41', path=str(self.root)).returncode, 5)

    def test_ceiling_required_and_numeric(self):
        self.assertEqual(self.check().returncode, 2)
        self.assertEqual(self.check('--max-glibc', 'latest').returncode, 2)


if __name__ == '__main__':
    unittest.main()
