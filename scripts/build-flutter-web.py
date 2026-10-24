#!/usr/bin/env python3
"""2026-10-20：为 Flutter Web 注入部署身份，供运行中的旧页面识别新部署。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parent.parent


def build_identity():
    try:
        revision = subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True, stderr=subprocess.DEVNULL
        ).strip()
        changes = subprocess.check_output(['git', 'diff', 'HEAD', '--binary'], cwd=ROOT)
    except (OSError, subprocess.CalledProcessError):
        return uuid.uuid4().hex
    untracked = subprocess.check_output(
        ['git', 'ls-files', '--others', '--exclude-standard', '-z', '--',
         'app/lib', 'app/web', 'app/pubspec.yaml', 'app/pubspec.lock', 'assets'], cwd=ROOT
    ).split(b'\0')
    fingerprint = hashlib.sha256(changes)
    for raw_path in sorted(name for name in untracked if name):
        file = ROOT / raw_path.decode('utf-8')
        if file.is_file():
            fingerprint.update(raw_path + b'\0')
            with file.open('rb') as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b''):
                    fingerprint.update(chunk)
    if changes or any(untracked):
        return f'{revision}-{fingerprint.hexdigest()[:16]}'
    return revision


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', default=os.environ.get('FLUTTER', 'flutter'))
    parser.add_argument('--version', default=os.environ.get('HANDWRITING_BUILD_VERSION'))
    parser.add_argument('--build-number', default=os.environ.get('HANDWRITING_BUILD_NUMBER'))
    parser.add_argument('--build-id', default=os.environ.get('HANDWRITING_WEB_BUILD_ID'))
    parser.add_argument('--base-href', default='/')
    args = parser.parse_args()
    version = args.version or (ROOT / 'VERSION').read_text(encoding='utf-8').strip()
    if not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?', version):
        parser.error('Invalid Web version')
    if args.build_number and (not args.build_number.isdecimal() or not 1 <= int(args.build_number) <= 2100000000):
        parser.error('Build number must be between 1 and 2100000000')
    if not re.fullmatch(r'/[A-Za-z0-9_./-]*', args.base_href) or not args.base_href.endswith('/') or '..' in args.base_href.split('/'):
        parser.error('Base href must be an absolute directory path')
    identity = args.build_id or build_identity()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', identity):
        parser.error('Invalid Web build ID')
    command = [shutil.which(args.flutter) or args.flutter, 'build', 'web', '--release', f'--build-name={version}',
               f'--dart-define=PANACHE_APP_VERSION={version}', f'--dart-define=PANACHE_BUILD_ID={identity}',
               f'--base-href={args.base_href}']
    if args.build_number:
        command.append(f'--build-number={args.build_number}')
    subprocess.run([sys.executable, str(ROOT / 'scripts/build-text-worker.py'), '--flutter', args.flutter], cwd=ROOT, check=True)
    subprocess.run(command, cwd=ROOT / 'app', check=True)
    metadata_path = ROOT / 'app/build/web/version.json'
    metadata = json.loads(metadata_path.read_text(encoding='utf-8'))
    if not isinstance(metadata, dict) or metadata.get('version') != version:
        raise RuntimeError('Flutter Web output version does not match the compiled application')
    if args.build_number and metadata.get('build_number') != args.build_number:
        raise RuntimeError('Flutter Web output build number does not match the application')
    metadata['build_id'] = identity
    metadata_path.write_text(json.dumps(metadata, ensure_ascii=False) + '\n', encoding='utf-8')
    print(f'Flutter Web: {version} / {identity}')


if __name__ == '__main__':
    main()
