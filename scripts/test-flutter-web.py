#!/usr/bin/env python3
"""运行真实 Chrome 测试，兼容固定 Flutter SDK 的 Windows CanvasKit 路由。"""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import threading
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
OLD = "final String fullPath = _fileSystem.path.fromUri(request.url);"
NEW = "final String fullPath = request.url.path;"


def repair_canvaskit_route(sdk: Path) -> bool:
    source = sdk / 'packages/flutter_tools/lib/src/test/flutter_web_platform.dart'
    original = source.read_bytes()
    start = original.find(b'shelf.Response _localCanvasKitHandler(')
    if start < 0:
        raise RuntimeError('Flutter test host changed; inspect CanvasKit routing before applying compatibility fix')
    end = original.find(b'\n  }', start)
    if end < 0:
        raise RuntimeError('Unable to locate CanvasKit handler boundary')
    handler = original[start:end]
    if NEW.encode() in handler:
        return False
    if handler.count(OLD.encode()) != 1:
        raise RuntimeError('Unknown CanvasKit route implementation; SDK left unchanged')
    source.write_bytes(original[:start] + handler.replace(OLD.encode(), NEW.encode()) + original[end:])
    # flutter 启动器不按工具源码时间自动重建快照，删除派生缓存后由 SDK 自己重建。
    (sdk / 'bin/cache/flutter_tools.snapshot').unlink(missing_ok=True)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test', action='append', help='Test file; repeat to replace the default persistence suite')
    arguments, extra = parser.parse_known_args()
    flutter = shutil.which('flutter')
    if flutter is None:
        raise RuntimeError('flutter is not on PATH')
    if os.name == 'nt':
        sdk = Path(flutter).resolve().parent.parent
        if repair_canvaskit_route(sdk):
            print('Applied Windows CanvasKit URL-path compatibility fix to Flutter test host', flush=True)
    tests = arguments.test or [
        'test/uploaded_font_browser_test.dart',
        'test/uploaded_font_storage_test.dart',
        'test/workspace_test.dart',
        'test/text_preparation_browser_test.dart',
    ]
    server = None
    if any('text_preparation_browser_test.dart' in test for test in tests):
        subprocess.run([sys.executable, str(ROOT / 'scripts/build-text-worker.py'), '--flutter', flutter], check=True)
        class WorkerHandler(SimpleHTTPRequestHandler):
            def end_headers(self):
                self.send_header('Access-Control-Allow-Origin', '*')
                super().end_headers()
        server = ThreadingHTTPServer(('127.0.0.1', 0), partial(WorkerHandler, directory=str(ROOT / 'app/web')))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        extra.append(f'--dart-define=TEXT_WORKER_TEST_URL=http://127.0.0.1:{server.server_port}/prepare-text-worker.js')
    try:
        return subprocess.run([flutter, 'test', '--platform', 'chrome', *tests, *extra], cwd=ROOT / 'app').returncode
    finally:
        if server:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    sys.exit(main())
