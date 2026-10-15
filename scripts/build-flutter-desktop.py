#!/usr/bin/env python3
"""2026-10-12：在当前平台构建含 Rust sidecar 的独立 Flutter 桌面包。"""
import argparse
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def run(*args, cwd=ROOT):
    subprocess.run(args, cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', default=os.environ.get('FLUTTER', 'flutter'))
    parser.add_argument('--version', default=os.environ.get('HANDWRITING_BUILD_VERSION'))
    parser.add_argument('--build-number', default=os.environ.get('HANDWRITING_BUILD_NUMBER'))
    args = parser.parse_args()
    version = args.version or (ROOT / 'VERSION').read_text().strip()
    if not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?', version):
        parser.error('Invalid release version')
    if args.build_number and (not args.build_number.isdecimal() or not 1 <= int(args.build_number) <= 2100000000):
        parser.error('Build number must be between 1 and 2100000000')
    os.environ['HANDWRITING_BUILD_VERSION'] = version
    target = {'Darwin': 'macos', 'Windows': 'windows', 'Linux': 'linux'}[platform.system()]
    if target != 'macos':
        run('cargo', 'build', '--locked', '--release', '-p', 'handwriting-server')
    run(args.flutter, 'pub', 'get', cwd=ROOT / 'app')
    build_number = [f'--build-number={args.build_number}'] if args.build_number else []
    run(args.flutter, 'build', target, '--release', f'--build-name={version}', *build_number, cwd=ROOT / 'app')
    output = ROOT / 'target/desktop-package' / target
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    if target == 'macos':
        source = next((ROOT / 'app/build/macos/Build/Products/Release').glob('*.app'))
        bundle = output / source.name
        shutil.copytree(source, bundle, symlinks=True)
        backend = bundle / 'Contents/Resources/backend'
    else:
        if target == 'windows':
            source = ROOT / 'app/build/windows/x64/runner/Release'
        else:
            source = ROOT / 'app/build/linux' / ('arm64' if platform.machine() in ('arm64', 'aarch64') else 'x64') / 'release/bundle'
        bundle = output / 'HandwritingWeb'
        shutil.copytree(source, bundle, symlinks=True)
        backend = bundle / 'backend'
    # macOS 的 Xcode 构建阶段已包含 sidecar，分发时直接复用。
    if target != 'macos':
        backend.mkdir()
        binary = 'handwriting-server.exe' if target == 'windows' else 'handwriting-server'
        shutil.copy2(ROOT / 'target/release' / binary, backend / binary)
        shutil.copytree(ROOT / 'assets/font_assets', backend / 'font_assets')
        (backend / 'VERSION').write_text(f'{version}\n', encoding='utf-8', newline='\n')
        shutil.copy2(ROOT / 'LICENSE', backend / 'LICENSE')
        shutil.copy2(ROOT / 'crates/handwriting-core/NOTICE', backend / 'NOTICE')
        shutil.copytree(ROOT / 'crates/handwriting-core/licenses', backend / 'licenses')
        shutil.copytree(ROOT / 'assets/licenses', backend / 'licenses', dirs_exist_ok=True)
    if target == 'macos':
        run('codesign', '--force', '--sign', '-', '--entitlements', str(ROOT / 'app/macos/Runner/Release.entitlements'), str(bundle))
        run('codesign', '--verify', '--deep', '--strict', str(bundle))
        archive = output / f'HandwritingWeb-{version}-{platform.machine()}.zip'
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(bundle), str(archive))
    else:
        archive = shutil.make_archive(str(output / f'HandwritingWeb-{version}-{platform.machine()}'), 'zip' if target == 'windows' else 'gztar', root_dir=output, base_dir=bundle.name)
    print(f'独立客户端：{bundle}\n分发包：{archive}')


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    main()
