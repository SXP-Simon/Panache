import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('web_runner', Path(__file__).parents[1] / 'test-flutter-web.py')
assert spec is not None and spec.loader is not None
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class CanvasKitCompatibilityTest(unittest.TestCase):
    def test_scoped_patch_preserves_crlf_and_rebuilds_snapshot_once(self):
        with tempfile.TemporaryDirectory() as directory:
            sdk = Path(directory)
            source = sdk / 'packages/flutter_tools/lib/src/test/flutter_web_platform.dart'
            source.parent.mkdir(parents=True)
            snapshot = sdk / 'bin/cache/flutter_tools.snapshot'
            snapshot.parent.mkdir(parents=True)
            snapshot.write_bytes(b'old cache')
            content = f'outside: {runner.OLD}\r\n  shelf.Response _localCanvasKitHandler(request) {{\r\n    {runner.OLD}\r\n  }}\r\n'.encode()
            source.write_bytes(content)
            self.assertTrue(runner.repair_canvaskit_route(sdk))
            expected = (
                f'outside: {runner.OLD}\r\n'
                '  shelf.Response _localCanvasKitHandler(request) {\r\n'
                f'    {runner.NEW}\r\n  }}\r\n'
            ).encode()
            self.assertEqual(source.read_bytes(), expected)
            self.assertFalse(snapshot.exists())
            snapshot.write_bytes(b'rebuilt cache')
            self.assertFalse(runner.repair_canvaskit_route(sdk))
            self.assertEqual(snapshot.read_bytes(), b'rebuilt cache')

    def test_unknown_handler_is_not_modified(self):
        with tempfile.TemporaryDirectory() as directory:
            sdk = Path(directory)
            source = sdk / 'packages/flutter_tools/lib/src/test/flutter_web_platform.dart'
            source.parent.mkdir(parents=True)
            content = b'  shelf.Response _localCanvasKitHandler(request) {\n    different();\n  }\n'
            source.write_bytes(content)
            with self.assertRaises(RuntimeError):
                runner.repair_canvaskit_route(sdk)
            self.assertEqual(source.read_bytes(), content)


if __name__ == '__main__':
    unittest.main()
