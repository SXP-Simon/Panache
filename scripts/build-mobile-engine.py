#!/usr/bin/env python3
"""由 Gradle/Xcode 调用，交叉编译随包的 Rust FFI 引擎。"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
ANDROID_TARGETS = {'arm64-v8a': 'aarch64-linux-android', 'x86_64': 'x86_64-linux-android'}
IOS_TARGETS = {
    (False, 'arm64'): 'aarch64-apple-ios',
    (True, 'arm64'): 'aarch64-apple-ios-sim',
    (True, 'x86_64'): 'x86_64-apple-ios',
}


def build_library(cargo, target, filename, env):
    target_dir = ROOT / 'target'
    subprocess.run(
        [cargo, 'build', '--manifest-path', str(ROOT / 'Cargo.toml'),
         '--target-dir', str(target_dir), '--locked', '--release',
         '-p', 'handwriting-bridge', '--target', target],
        env=env, check=True,
    )
    return target_dir / target / 'release' / filename


def build_android(args, parser, cargo, env):
    if not args.ndk:
        parser.error('Android 构建必须传入 --ndk')
    hosts = list((args.ndk / 'toolchains/llvm/prebuilt').glob('*'))
    if len(hosts) != 1:
        parser.error('NDK LLVM 工具链不存在')
    toolchain = hosts[0] / 'bin'
    for abi in args.abis.split(','):
        target = ANDROID_TARGETS[abi]
        key = target.replace('-', '_')
        compiler = toolchain / (target + '24-clang' + ('.cmd' if os.name == 'nt' else ''))
        target_env = env | {
            'CARGO_TARGET_' + key.upper() + '_LINKER': str(compiler),
            'CC_' + key: str(compiler),
            'AR_' + key: str(toolchain / ('llvm-ar.exe' if os.name == 'nt' else 'llvm-ar')),
        }
        library = build_library(cargo, target, 'libhandwriting_bridge.so', target_env)
        destination = args.output / abi
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copy2(library, destination)


def build_ios(args, parser, cargo, env):
    simulator = env.get('PLATFORM_NAME') == 'iphonesimulator'
    libraries = []
    for arch in env.get('ARCHS', 'arm64').split():
        target = IOS_TARGETS.get((simulator, arch))
        if target is None:
            parser.error('不支持的 iOS 架构: ' + arch)
        libraries.append(build_library(cargo, target, 'libhandwriting_bridge.a', env))
    args.output.mkdir(parents=True, exist_ok=True)
    destination = args.output / 'libhandwriting_bridge.a'
    if len(libraries) == 1:
        shutil.copy2(libraries[0], destination)
    else:
        subprocess.run(['xcrun', 'lipo', '-create', *map(str, libraries), '-output', str(destination)], check=True)


def main():
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
        build_android(args, parser, cargo, env)
    else:
        build_ios(args, parser, cargo, env)


if __name__ == '__main__':
    main()
