#!/usr/bin/env python3
"""Check ELF version requirements in an unpacked Panache Linux release."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


BACKENDS = ('backend/handwriting-server', 'backend/panache-mcp')


def version(text):
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)+', text):
        raise ValueError(f'expected a numeric version, got {text!r}')
    parts = [int(n) for n in text.split('.')]
    while len(parts) > 2 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def requirements(output):
    # readelf also prints names that the object defines or merely lists in .gnu.version.
    needs = re.search(r'^Version needs section [^\n]+\n((?:[ \t]+[^\n]+\n?)*)', output, re.M)
    block = needs[1] if needs else ''
    if not needs and 'No version information found' not in output and not re.search(
            r'^Version (?:symbols|definition) section ', output, re.M):
        raise ValueError('unrecognized GNU readelf version output')
    providers = re.findall(r'\bFile: \S+\s+Cnt: (\d+)', block)
    names = re.findall(r'\bName: (\S+)\s+Flags:', block)
    count = re.search(r'\(VERNEEDNUM\)\s+(\d+)', output)
    if ('<corrupt' in block or bool(needs) != ('(VERNEED)' in output)
            or len(providers) != (int(count[1]) if count else 0)
            or len(names) != sum(map(int, providers))):
        raise ValueError('incomplete ELF version needs')
    return [n.removeprefix('GLIBC_') for n in names if n.startswith('GLIBC_')]


def raise_error(error):
    raise error


def scan(root, tool, ceiling):
    checked = 0
    exceeded = 0
    for directory, dirs, files in os.walk(root, onerror=raise_error):
        dirs.sort()
        for name in sorted(dirs + files):
            path = Path(directory, name)
            if path.is_symlink() and not path.resolve(strict=True).is_relative_to(root):
                raise ValueError(f'{path}: link leaves bundle')
            if path.is_dir():
                continue
            if not path.is_file():
                raise ValueError(f'{path}: expected a regular file')
            relative = path.relative_to(root).as_posix()
            with path.open('rb') as stream:
                if stream.read(4) != b'\x7fELF':
                    if relative in (*BACKENDS, 'backend/panache-updater', 'handwriting_app') or re.search(r'\.so(?:\.|$)', name):
                        raise ValueError(f'{relative}: expected ELF')
                    continue
            result = subprocess.run([tool, '-W', '-d', '-V', str(path)], capture_output=True,
                                    text=True, env={**os.environ, 'LC_ALL': 'C'})
            if result.returncode or result.stderr.strip():
                raise ValueError(f'{relative}: readelf: {result.stderr.strip() or result.returncode}')
            try:
                highest = max(requirements(result.stdout), key=version, default=None)
            except ValueError as error:
                raise ValueError(f'{relative}: {error}') from error
            checked += 1
            if highest and version(highest) > ceiling:
                print(f'{relative}: requires GLIBC_{highest}')
                exceeded += 1
    print(f'{checked} ELF files checked, {exceeded} above the requested ceiling')
    return int(bool(exceeded))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path, help='unpacked directory containing backend/')
    parser.add_argument('--max-glibc', required=True, type=version, metavar='VERSION')
    args = parser.parse_args()
    tool = shutil.which('readelf')
    if not tool:
        print('GNU readelf not found', file=sys.stderr)
        return 5
    try:
        root = args.bundle.resolve(strict=True)
        if not root.is_dir():
            raise ValueError('expected an unpacked bundle directory')
        missing = [name for name in BACKENDS if not (root / name).exists()]
        if missing:
            print('missing required backend: ' + ', '.join(missing), file=sys.stderr)
            return 4
        if not (root / 'handwriting_app').is_file():
            raise ValueError('missing desktop executable handwriting_app')
        return scan(root, tool, args.max_glibc)
    except (OSError, ValueError, RuntimeError) as error:
        print(error, file=sys.stderr)
        return 3


if __name__ == '__main__':
    sys.exit(main())
