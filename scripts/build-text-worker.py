#!/usr/bin/env python3
"""2026-10-24：构建独立的文本整理 Worker；开发和正式 Web 构建共享入口。"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', default=os.environ.get('FLUTTER', 'flutter'))
    args = parser.parse_args()
    flutter = Path(shutil.which(args.flutter) or args.flutter).resolve()
    sdk = flutter.parent.parent
    dart = sdk / 'bin/cache/dart-sdk/bin' / ('dart.exe' if os.name == 'nt' else 'dart')
    platform = sdk / 'bin/cache/flutter_web_sdk/kernel'
    if not dart.is_file():
        parser.error('Pass --flutter with a Flutter SDK executable available on this machine')
    subprocess.run([str(flutter), 'pub', 'get'], cwd=ROOT / 'app', check=True)
    if not platform.is_dir():
        subprocess.run([str(flutter), 'precache', '--web'], cwd=ROOT / 'app', check=True)
    # 使用 Flutter 自身的 Web 平台定义支持 AST 中的 dart:ui 类型，直接编译入口，
    # 不经过 Flutter 默认的 DOM/CanvasKit 引擎启动包装。
    subprocess.run([
        str(dart), 'compile', 'js', f'--platform-binaries={platform}',
        '--invoker=flutter_tool', '-Ddart.vm.product=true', '-O2', '--no-source-maps',
        '--packages=.dart_tool/package_config.json', '-o', 'web/prepare-text-worker.js',
        'lib/workers/prepare_text_worker.dart',
    ], cwd=ROOT / 'app', check=True)


if __name__ == '__main__':
    main()
