#!/usr/bin/env python3
"""2026-10-12：由 Gradle/Xcode 调用，交叉编译随包的 Rust FFI 引擎。"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('platform', choices=['android', 'ios'])
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--ndk', type=Path)
parser.add_argument('--abis', default='arm64-v8a,x86_64')
args = parser.parse_args()
cargo = shutil.which('cargo') or str(Path.home() / '.cargo/bin/cargo')
env = os.environ.copy()
# Xcode 的 SDKROOT 指向 iOS，会影响 Cargo 在主机上编译 build.rs。
env.pop('SDKROOT', None)

if args.platform == 'android':
    if not args.ndk:
        parser.error('Android 构建必须传入 --ndk')
    hosts = list((args.ndk / 'toolchains/llvm/prebuilt').glob('*'))
    if len(hosts) != 1:
        parser.error('NDK LLVM 工具链不存在')
    toolchain = hosts[0] / 'bin'
    targets = {
        'arm64-v8a': ('aarch64-linux-android', 'aarch64-linux-android'),
        'x86_64': ('x86_64-linux-android', 'x86_64-linux-android'),
    }
    for abi in args.abis.split(','):
        target, clang = targets[abi]
        compiler = toolchain / (clang + '24-clang' + ('.cmd' if os.name == 'nt' else ''))
        target_env = env | {
            'CARGO_TARGET_' + target.upper().replace('-', '_') + '_LINKER': str(compiler),
            'CC_' + target.replace('-', '_'): str(compiler),
            'AR_' + target.replace('-', '_'): str(toolchain / ('llvm-ar.exe' if os.name == 'nt' else 'llvm-ar')),
        }
        subprocess.run([cargo, 'build', '--manifest-path', str(ROOT / 'Cargo.toml'),
                        '--target-dir', str(ROOT / 'target'), '--locked', '--release', '-p', 'handwriting-bridge', '--target', target],
                       env=target_env, check=True)
        destination = args.output / abi
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / 'target' / target / 'release/libhandwriting_bridge.so', destination)
else:
    simulator = os.environ.get('PLATFORM_NAME') == 'iphonesimulator'
    arches = os.environ.get('ARCHS', 'arm64').split()
    libraries = []
    for arch in arches:
        target = ('aarch64-apple-ios-sim' if arch == 'arm64' else 'x86_64-apple-ios') if simulator else 'aarch64-apple-ios'
        if arch not in ('arm64', 'x86_64') or (not simulator and arch != 'arm64'):
            parser.error('不支持的 iOS 架构: ' + arch)
        subprocess.run([cargo, 'build', '--manifest-path', str(ROOT / 'Cargo.toml'),
                        '--target-dir', str(ROOT / 'target'), '--locked', '--release', '-p', 'handwriting-bridge', '--target', target],
                       env=env, check=True)
        libraries.append(ROOT / 'target' / target / 'release/libhandwriting_bridge.a')
    args.output.mkdir(parents=True, exist_ok=True)
    destination = args.output / 'libhandwriting_bridge.a'
    if len(libraries) == 1:
        shutil.copy2(libraries[0], destination)
    else:
        subprocess.run(['xcrun', 'lipo', '-create', *map(str, libraries), '-output', str(destination)], check=True)
