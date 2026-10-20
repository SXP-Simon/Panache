#!/usr/bin/env python3
"""2026-10-12：在当前平台构建含 Rust sidecar 的独立 Flutter 桌面包。"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

from windows_launcher import brand_launcher

# 保留调用者选用的 ASCII junction，避免 Windows 原生构建工具重新落回中文路径。
ROOT = Path(__file__).absolute().parent.parent


def run(*args, cwd=ROOT, **options):
    subprocess.run(args, cwd=cwd, check=True, **options)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def bundle_updater(bundle, backend, target, version, build, flutter):
    machine = platform.machine().lower()
    architecture = 'arm64' if machine in ('arm64', 'aarch64') else 'x64'
    suffix = f'{target}-{architecture}'
    if suffix not in {'windows-x64', 'linux-x64', 'macos-arm64'}:
        raise ValueError(f'Unsupported updater platform: {suffix}')
    dart = Path(flutter).resolve().parent / ('dart.bat' if target == 'windows' else 'dart')
    if not dart.is_file():
        dart = shutil.which('dart') or 'dart'
    helper = ROOT / 'target' / ('panache-updater.exe' if target == 'windows' else 'panache-updater')
    helper.parent.mkdir(parents=True, exist_ok=True)
    run(str(dart), 'pub', 'get', cwd=ROOT / 'app/updater')
    run(str(dart), 'compile', 'exe', 'bin/panache_updater.dart', '-o', str(helper), cwd=ROOT / 'app/updater')
    run(str(helper), '--self-check', capture_output=True, timeout=30)
    shutil.copy2(helper, backend / helper.name)
    marker = {
        'schema': 1, 'product': 'Panache', 'platform': suffix,
        'version': version, 'build_number': build,
        'layout': 'windows-versioned' if target == 'windows' else 'bundle',
        'executable': 'Contents/MacOS/Panache' if target == 'macos' else 'handwriting_app.exe' if target == 'windows' else 'handwriting_app',
    }
    marker_path = Path('Contents/Resources/panache-install.json') if target == 'macos' else Path('panache-install.json')
    write_json(bundle / marker_path, marker)
    if target == 'windows':
        runtime_id = f'{version}-{build}'
        runtime = bundle.parent / f'.runtime-{runtime_id}'
        if runtime.exists():
            raise FileExistsError(runtime)
        bundle.rename(runtime)
        (bundle / 'versions').mkdir(parents=True)
        runtime.rename(bundle / 'versions' / runtime_id)
        launcher = bundle / 'handwriting_app.exe'
        shutil.copy2(helper, launcher)
        brand_launcher(bundle / 'versions' / runtime_id / 'handwriting_app.exe', launcher)
        # GUI 子系统没有控制台；显式提供管道供 Dart 自检写入 stdout。
        run(str(launcher), '--self-check', capture_output=True, timeout=30)
        write_json(bundle / marker_path, marker)
        pointer = {'schema': 1, 'product': 'Panache', 'version': version,
                   'build_number': build, 'runtime': f'versions/{runtime_id}'}
        write_json(bundle / 'active.json', pointer)
        write_json(bundle / 'last-good.json', pointer)
    elif target == 'macos':
        run('codesign', '--force', '--sign', '-', str(backend / helper.name))


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
    build = int(args.build_number or 1)
    run(args.flutter, 'build', target, '--release', f'--build-name={version}', f'--build-number={build}', cwd=ROOT / 'app')
    output = ROOT / 'target/desktop-package' / target
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    if target == 'macos':
        source = ROOT / 'app/build/macos/Build/Products/Release/Panache.app'
        bundle = output / source.name
        shutil.copytree(source, bundle, symlinks=True)
        backend = bundle / 'Contents/Resources/backend'
    else:
        if target == 'windows':
            source = ROOT / 'app/build/windows/x64/runner/Release'
        else:
            source = ROOT / 'app/build/linux' / ('arm64' if platform.machine() in ('arm64', 'aarch64') else 'x64') / 'release/bundle'
        bundle = output / 'Panache'
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
    bundle_updater(bundle, backend, target, version, build, args.flutter)
    if target == 'macos':
        run('codesign', '--force', '--sign', '-', '--entitlements', str(ROOT / 'app/macos/Runner/Release.entitlements'), str(bundle))
        run('codesign', '--verify', '--deep', '--strict', str(bundle))
        archive = output / f'Panache-{version}-{platform.machine()}.zip'
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(bundle), str(archive))
    else:
        archive = shutil.make_archive(str(output / f'Panache-{version}-{platform.machine()}'), 'zip' if target == 'windows' else 'gztar', root_dir=output, base_dir=bundle.name)
    print(f'独立客户端：{bundle}\n分发包：{archive}')


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    main()
