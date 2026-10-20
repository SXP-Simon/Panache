"""2026-10-20：为独立更新启动器保留应用图标、产品版本和无控制台入口。"""

import ctypes
from pathlib import Path
import struct
import sys


def gui_subsystem(executable: Path):
    # PE32 与 PE32+ 的 Subsystem 字段均位于 Optional Header 的第 68 字节。
    with executable.open("r+b") as stream:
        if stream.read(2) != b"MZ":
            raise ValueError("Not a PE executable")
        stream.seek(60)
        offset = struct.unpack("<I", stream.read(4))[0]
        if offset < 64 or offset > executable.stat().st_size - 94:
            raise ValueError("Invalid PE header")
        stream.seek(offset)
        if stream.read(4) != b"PE\0\0":
            raise ValueError("Invalid PE signature")
        stream.seek(offset + 24)
        if struct.unpack("<H", stream.read(2))[0] not in {0x10B, 0x20B}:
            raise ValueError("Unsupported optional header")
        stream.seek(offset + 24 + 68)
        if struct.unpack("<H", stream.read(2))[0] not in {2, 3}:
            raise ValueError("Unsupported executable subsystem")
        stream.seek(-2, 1)
        stream.write(struct.pack("<H", 2))


def brand_launcher(source: Path, destination: Path):
    """只复制构建出的 Flutter Runner 的图标/版本，不修改安装或运行中的文件。"""
    if sys.platform != "win32":
        raise OSError("Windows resources require a Windows build host")
    library = ctypes.WinDLL("kernel32", use_last_error=True)
    pointer, integer, word = ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint16
    callback = ctypes.WINFUNCTYPE(ctypes.c_int, pointer, pointer, pointer, ctypes.c_ssize_t)
    language_callback = ctypes.WINFUNCTYPE(
        ctypes.c_int, pointer, pointer, pointer, word, ctypes.c_ssize_t
    )
    signatures = {
        "LoadLibraryExW": ([ctypes.c_wchar_p, pointer, integer], pointer),
        "FreeLibrary": ([pointer], ctypes.c_int),
        "EnumResourceNamesW": ([pointer, pointer, callback, ctypes.c_ssize_t], ctypes.c_int),
        "EnumResourceLanguagesW": ([pointer, pointer, pointer, language_callback, ctypes.c_ssize_t], ctypes.c_int),
        "FindResourceExW": ([pointer, pointer, pointer, word], pointer),
        "SizeofResource": ([pointer, pointer], integer),
        "LoadResource": ([pointer, pointer], pointer),
        "LockResource": ([pointer], pointer),
        "BeginUpdateResourceW": ([ctypes.c_wchar_p, ctypes.c_int], pointer),
        "UpdateResourceW": ([pointer, pointer, pointer, word, pointer, integer], ctypes.c_int),
        "EndUpdateResourceW": ([pointer, ctypes.c_int], ctypes.c_int),
    }
    for name, (arguments, result) in signatures.items():
        function = getattr(library, name)
        function.argtypes, function.restype = arguments, result
    module = library.LoadLibraryExW(str(source), None, 0x2 | 0x20)
    if not module:
        raise ctypes.WinError(ctypes.get_last_error())
    update = None
    errors = []
    copied = set()

    @language_callback
    def copy_language(handle, kind, name, language, _parameter):
        try:
            resource = library.FindResourceExW(handle, kind, name, language)
            size = library.SizeofResource(handle, resource)
            data = library.LockResource(library.LoadResource(handle, resource))
            if not size or not data or not library.UpdateResourceW(
                update, kind, name, language, data, size
            ):
                raise ctypes.WinError(ctypes.get_last_error())
            copied.add(kind)
            return 1
        except Exception as error:
            errors.append(error)
            return 0

    @callback
    def copy_name(handle, kind, name, _parameter):
        if not library.EnumResourceLanguagesW(handle, kind, name, copy_language, 0):
            if not errors:
                errors.append(ctypes.WinError(ctypes.get_last_error()))
            return 0
        return 1

    try:
        update = library.BeginUpdateResourceW(str(destination), False)
        if not update:
            raise ctypes.WinError(ctypes.get_last_error())
        for kind in (3, 14, 16):  # RT_ICON、RT_GROUP_ICON、RT_VERSION。
            if not library.EnumResourceNamesW(module, kind, copy_name, 0):
                raise errors[0] if errors else ctypes.WinError(ctypes.get_last_error())
        if copied != {3, 14, 16}:
            raise ValueError("Missing Panache icon or product version")
        if not library.EndUpdateResourceW(update, False):
            raise ctypes.WinError(ctypes.get_last_error())
        update = None
    finally:
        if update:
            library.EndUpdateResourceW(update, True)
        library.FreeLibrary(module)
    gui_subsystem(destination)
