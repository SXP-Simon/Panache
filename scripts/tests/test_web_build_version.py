"""2026-10-20：验证 Web 编译身份与部署元数据一致，拒绝错误或未完成的构建。"""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'build-flutter-web.py'
SPEC = importlib.util.spec_from_file_location('web_build', SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class WebBuildTest(unittest.TestCase):
    def test_identity_and_version_reach_bundle_and_deployment_without_source_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'VERSION').write_text('0.1.0\n')
            metadata_path = root / 'app/build/web/version.json'
            metadata_path.parent.mkdir(parents=True)
            metadata_path.write_text(json.dumps({'version': '2.3.4', 'build_number': '2003004', 'app_name': 'Panache'}))
            with patch.object(MODULE, 'ROOT', root), patch.object(MODULE.subprocess, 'run') as run, patch.dict(os.environ, {}, clear=True), patch('sys.argv', [str(SOURCE), '--version', '2.3.4', '--build-number', '2003004', '--build-id', 'source-123', '--base-href', '/panache/']):
                MODULE.main()
            command = run.call_args.args[0]
            self.assertIn('--build-name=2.3.4', command)
            self.assertIn('--dart-define=PANACHE_APP_VERSION=2.3.4', command)
            self.assertIn('--dart-define=PANACHE_BUILD_ID=source-123', command)
            self.assertIn('--base-href=/panache/', command)
            self.assertEqual(json.loads(metadata_path.read_text())['build_id'], 'source-123')
            self.assertEqual((root / 'VERSION').read_text(), '0.1.0\n')

    def test_mismatched_output_never_receives_a_new_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            metadata_path = root / 'app/build/web/version.json'
            metadata_path.parent.mkdir(parents=True)
            metadata_path.write_text('{"version":"0.1.0"}')
            with patch.object(MODULE, 'ROOT', root), patch.object(MODULE.subprocess, 'run'), patch('sys.argv', [str(SOURCE), '--version', '2.3.4', '--build-id', 'source-123']):
                with self.assertRaises(RuntimeError):
                    MODULE.main()
            self.assertNotIn('build_id', json.loads(metadata_path.read_text()))

    def test_untracked_application_source_changes_also_change_deployment_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'app/lib/new_feature.dart'
            source.parent.mkdir(parents=True)
            source.write_text('first build')
            with patch.object(MODULE, 'ROOT', root), patch.object(MODULE.subprocess, 'check_output', side_effect=['a' * 40, b'', b'app/lib/new_feature.dart\0']):
                first = MODULE.build_identity()
            source.write_text('second build')
            with patch.object(MODULE, 'ROOT', root), patch.object(MODULE.subprocess, 'check_output', side_effect=['a' * 40, b'', b'app/lib/new_feature.dart\0']):
                second = MODULE.build_identity()
            self.assertNotEqual(first, second)
            self.assertTrue(first.startswith('a' * 40))

    def test_invalid_inputs_fail_before_building(self):
        for arguments in [['--version', '../../wrong'], ['--version', '1.2.3', '--build-id', 'bad value'], ['--version', '1.2.3', '--base-href', '/foo/../'], ['--version', '1.2.3', '--build-number', '0']]:
            with self.subTest(arguments=arguments), patch.object(MODULE.subprocess, 'run') as run, patch('sys.argv', [str(SOURCE), *arguments]):
                with self.assertRaises(SystemExit):
                    MODULE.main()
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
