# 2026-10-20：独立单文件助手退出主程序后仍可执行，无需用户安装 Python。
from pathlib import Path

root = Path(SPECPATH)
analysis = Analysis(
    [str(root / "updater.py")],
    pathex=[str(root)],
    binaries=[],
    datas=[],
    hiddenimports=["psutil"],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)
archive = PYZ(analysis.pure)
executable = EXE(
    archive,
    analysis.scripts,
    analysis.binaries,
    analysis.datas,
    [],
    name="panache-updater",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
