# Copyright (c) 2026 SXP-Simon
"""2026-10-20：桌面更新的当前用户进程、系统安装器与原子交换适配."""

from __future__ import annotations

import contextlib
import ctypes
import errno
import os
import plistlib
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import BinaryIO, cast

import psutil
from updater_core import APP_ID, Plan, UpdateFailure, plain_path, read_record, write_record

if sys.platform == "win32":
    import winreg

INSTALL_GUID = str(uuid.uuid5(uuid.UUID("50e065bc-3134-11e6-9bab-38c9862bdaf3"), APP_ID))
EXIT_TIMEOUT = "fileLocked"
INSTALL_FAILED = "helperFailed"
INVALID_BUNDLE = "invalidBundle"
PERMISSIONS = "permissionDenied"
PROCESS_IDENTITY = "invalidInstallation"
RECOVERY_UNAVAILABLE = "rollbackUnavailable"
REPLACE_FAILED = "helperFailed"
STOP_FAILED = "stopFailed"
SYSTEM_APPROVAL = "trustRequired"
UNSAFE_PATH = "unsafePath"
UNSUPPORTED_INSTALL = "unsupportedLocation"
RUN_ONCE = r"Software\Microsoft\Windows\CurrentVersion\RunOnce"
VERSION_SIGNATURE = 0xFEEF04BD
RUN_ONCE_LIMIT = 260
MAX_QUARANTINE_BYTES = 65536
MAX_JOB_PROCESSES = 65536
WIN_MORE_DATA = 234
WIN_NO_PROCESS = 87


def _same_path(left: Path, right: Path) -> bool:
    """2026-10-20：比较实际文件位置，Windows 同时折叠大小写."""
    return os.path.normcase(str(left.resolve())) == os.path.normcase(str(right.resolve()))


def _owned_process(pid: int) -> psutil.Process:
    """2026-10-20：只读取同一用户的进程，不接受跨账户目标."""
    process = psutil.Process(pid)
    if process.username() != psutil.Process().username():
        raise UpdateFailure(PROCESS_IDENTITY)
    return process


def _identity(process: psutil.Process) -> dict[str, object]:
    """2026-10-20：PID 必须与出生时间及实际入口共同持久化."""
    return {"pid": process.pid, "created": process.create_time(), "exe": process.exe()}


def _matching_process(identity: dict[str, object]) -> psutil.Process | None:
    """2026-10-20：PID 已复用或原进程退出时绝不操作其继任者."""
    pid, created, executable = identity.get("pid"), identity.get("created"), identity.get("exe")
    if (
        not isinstance(pid, int)
        or isinstance(pid, bool)
        or not isinstance(created, (float, int))
        or isinstance(created, bool)
        or not isinstance(executable, str)
    ):
        raise UpdateFailure(PROCESS_IDENTITY)
    try:
        process = _owned_process(pid)
        if process.create_time() != created or not _same_path(
            Path(process.exe()), Path(executable)
        ):
            return None
        if process.status() == psutil.STATUS_ZOMBIE:
            return None
    except psutil.NoSuchProcess:
        return None
    except psutil.AccessDenied as error:
        raise UpdateFailure(PROCESS_IDENTITY) from error
    return process


def _descends_from(process: psutil.Process, ancestor: psutil.Process) -> bool:
    """2026-10-20：父子链匹配也校验祖先进程出生时间."""
    return any(
        item.pid == ancestor.pid and item.create_time() == ancestor.create_time()
        for item in process.parents()
    )


class _FixedVersion(ctypes.Structure):
    """2026-10-20：Windows 固定版本资源布局."""

    _fields_ = [
        (name, ctypes.c_uint32)
        for name in (
            "signature",
            "struct_version",
            "file_ms",
            "file_ls",
            "product_ms",
            "product_ls",
            "mask",
            "flags",
            "operating_system",
            "file_type",
            "subtype",
            "date_ms",
            "date_ls",
        )
    ]
    signature: int
    product_ms: int
    product_ls: int


def _windows_version(executable: Path) -> str:
    """2026-10-20：从已存在的 PE 版本资源读取产品版本，不执行待检查文件."""
    if sys.platform != "win32":
        raise UpdateFailure(UNSUPPORTED_INSTALL)
    library = ctypes.WinDLL("version", use_last_error=True)
    size_function = library.GetFileVersionInfoSizeW
    size_function.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_uint32)]
    size_function.restype = ctypes.c_uint32
    ignored = ctypes.c_uint32()
    size = int(size_function(str(executable), ctypes.byref(ignored)))
    if not 0 < size <= 1024 * 1024:
        raise UpdateFailure(PROCESS_IDENTITY)
    buffer = ctypes.create_string_buffer(size)
    read_function = library.GetFileVersionInfoW
    read_function.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    read_function.restype = ctypes.c_int
    if not read_function(str(executable), 0, size, buffer):
        raise UpdateFailure(PROCESS_IDENTITY)
    query = library.VerQueryValueW
    query.argtypes = [
        ctypes.c_void_p,
        ctypes.c_wchar_p,
        ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(ctypes.c_uint),
    ]
    query.restype = ctypes.c_int
    pointer, length = ctypes.c_void_p(), ctypes.c_uint()
    if not query(
        buffer, "\\", ctypes.byref(pointer), ctypes.byref(length)
    ) or length.value < ctypes.sizeof(_FixedVersion):
        raise UpdateFailure(PROCESS_IDENTITY)
    version = _FixedVersion.from_buffer_copy(
        ctypes.string_at(pointer, ctypes.sizeof(_FixedVersion))
    )
    if version.signature != VERSION_SIGNATURE:
        raise UpdateFailure(PROCESS_IDENTITY)
    return f"{version.product_ms >> 16}.{version.product_ms & 0xFFFF}.{version.product_ls >> 16}"


def _registry_binding(plan: Plan, version: str) -> None:
    """2026-10-20：只自动升级与当前用户 NSIS 注册信息一致的安装目录."""
    if sys.platform != "win32":
        raise UpdateFailure(UNSUPPORTED_INSTALL)
    try:
        access = winreg.KEY_READ | winreg.KEY_WOW64_64KEY
        with winreg.OpenKey(
            winreg.HKEY_CURRENT_USER, rf"Software\{INSTALL_GUID}", 0, access
        ) as key:
            location, _ = winreg.QueryValueEx(key, "InstallLocation")
        uninstall = rf"Software\Microsoft\Windows\CurrentVersion\Uninstall\{INSTALL_GUID}"
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, uninstall, 0, access) as key:
            display, _ = winreg.QueryValueEx(key, "DisplayName")
            installed_version, _ = winreg.QueryValueEx(key, "DisplayVersion")
            command, _ = winreg.QueryValueEx(key, "UninstallString")
        expected_command = f'"{plan.target / "Uninstall Panache.exe"}" /currentuser'
        if (
            not isinstance(location, str)
            or not _same_path(Path(location), plan.target)
            or display != "Panache"
            or installed_version != version
            or not isinstance(command, str)
            or command.casefold() != expected_command.casefold()
        ):
            raise UpdateFailure(UNSUPPORTED_INSTALL)
    except OSError as error:
        raise UpdateFailure(UNSUPPORTED_INSTALL) from error


def _profile_from_parent(parent: psutil.Process) -> Path:
    """2026-10-20：更新目录必须属于实际父进程使用的工作区资料目录."""
    environment = parent.environ()
    if sys.platform == "darwin":
        home = environment.get("HOME") or str(Path.home())
        return plain_path(str(Path(home) / "Library/Application Support/HandwritingWeb"))
    if environment.get("LOCALAPPDATA"):
        return plain_path(str(Path(environment["LOCALAPPDATA"]) / "HandwritingWeb"))
    arguments = parent.cmdline()[1:]
    profiles = [
        value.split("=", 1)[1] for value in arguments if value.startswith("--user-data-dir=")
    ]
    for index, value in enumerate(arguments[:-1]):
        if value == "--user-data-dir":
            profiles.append(arguments[index + 1])
    if len(profiles) > 1:
        raise UpdateFailure(UNSAFE_PATH)
    if profiles:
        return plain_path(str(Path(profiles[0]) / "HandwritingWeb"))
    roaming = environment.get("APPDATA")
    if not roaming:
        raise UpdateFailure(UNSAFE_PATH)
    return plain_path(str(Path(roaming) / "Panache/HandwritingWeb"))


def _writable_directory(directory: Path) -> None:
    """2026-10-20：实际创建探针验证写入权限，拒绝隐式提升权限."""
    try:
        with tempfile.TemporaryFile(dir=directory):
            pass
    except OSError as error:
        raise UpdateFailure(PERMISSIONS) from error


def _require_unprivileged() -> None:
    """2026-10-20：通用计划助手不在提升权限的上下文中运行."""
    if sys.platform not in {"win32", "darwin"}:
        raise UpdateFailure(UNSUPPORTED_INSTALL)
    if sys.platform == "win32":
        shell = ctypes.WinDLL("shell32", use_last_error=True)
        shell.IsUserAnAdmin.restype = ctypes.c_int
        if shell.IsUserAnAdmin():
            raise UpdateFailure(PERMISSIONS)
    elif os.geteuid() == 0:
        raise UpdateFailure(PERMISSIONS)


def require_user_context() -> None:
    """2026-10-20：正常执行与登录恢复都必须先拒绝管理员计划上下文."""
    _require_unprivileged()


def _validate_product(plan: Plan, parent: psutil.Process, executable: Path) -> Path:
    """2026-10-20：分别验证安装类型，不把便携载荷误认为外层启动器."""
    if plan.mode == "mac-bundle":
        return _validate_mac_product(plan, executable)
    if sys.platform != "win32" or _windows_version(executable) != plan.current:
        raise UpdateFailure(PROCESS_IDENTITY)
    if _windows_version(plan.package.file) != plan.version:
        raise UpdateFailure(PROCESS_IDENTITY)
    if plan.mode == "win-install":
        if not _same_path(executable, plan.executable):
            raise UpdateFailure(PROCESS_IDENTITY)
        _registry_binding(plan, plan.current)
        _writable_directory(plan.target)
        if plan.rollback is None or _windows_version(plan.rollback.file) != plan.current:
            raise UpdateFailure(RECOVERY_UNAVAILABLE)
    else:
        if plan.launcher_pid is None:
            raise UpdateFailure(UNSUPPORTED_INSTALL)
        launcher = _owned_process(plan.launcher_pid)
        if (
            not _same_path(Path(launcher.exe()), plan.target)
            or not _descends_from(parent, launcher)
            or _windows_version(plan.target) != plan.current
        ):
            raise UpdateFailure(PROCESS_IDENTITY)
    return executable.parent / "resources/backend/handwriting-backend.exe"


def _validate_mac_product(plan: Plan, executable: Path) -> Path:
    """2026-10-20：单独验证 macOS 原有产品和精确版本，不执行其入口."""
    if sys.platform != "darwin" or not _same_path(executable, plan.executable):
        raise UpdateFailure(PROCESS_IDENTITY)
    with (plan.target / "Contents/Info.plist").open("rb") as source:
        info = cast("dict[str, object]", plistlib.load(source))
    if (
        info.get("CFBundleIdentifier") != APP_ID
        or info.get("CFBundleShortVersionString") != plan.current
    ):
        raise UpdateFailure(PROCESS_IDENTITY)
    return plan.target / "Contents/Resources/backend/handwriting-backend"


def refuse_other_instances(plan: Plan, parent: psutil.Process | None = None) -> None:
    """2026-10-20：同目标的其他窗口可能有未保存内容，只拒绝更新，不按名称终止."""
    expected = plan.target if plan.mode == "win-portable" else plan.executable
    own_launcher = plan.launcher_pid if parent is not None else None
    current_user = psutil.Process().username()
    for process in psutil.process_iter():
        try:
            executable = Path(process.exe())
            same_installer_image = (
                plan.mode == "win-install"
                and executable.name.casefold() == expected.name.casefold()
                and process.username() == current_user
            )
            if not same_installer_image and not _same_path(executable, expected):
                continue
            if parent is not None and (
                process.pid == parent.pid or _descends_from(process, parent)
            ):
                continue
            if own_launcher is not None and process.pid == own_launcher:
                continue
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
        message = "fileLocked"
        raise UpdateFailure(message)


def validate_installation(plan: Plan) -> None:
    """2026-10-20：退出前绑定产品、当前用户、父子关系、版本和安装位置."""
    _require_unprivileged()
    try:
        parent = _owned_process(plan.parent_pid)
        backend = _owned_process(plan.backend_pid)
        parent_executable = plain_path(parent.exe())
        if not _same_path(parent_executable, plan.parent_executable) or not _same_path(
            _profile_from_parent(parent), plan.data_root
        ):
            raise UpdateFailure(PROCESS_IDENTITY)
        if not _descends_from(backend, parent):
            raise UpdateFailure(PROCESS_IDENTITY)
        expected_backend = _validate_product(plan, parent, parent_executable)
        if not _same_path(Path(backend.exe()), expected_backend):
            raise UpdateFailure(PROCESS_IDENTITY)
        refuse_other_instances(plan, parent)
        _writable_directory(plan.target.parent)
        if plan.mode != "win-portable" and plan.data_root.is_relative_to(plan.target):
            raise UpdateFailure(UNSAFE_PATH)
        processes = [parent, backend]
        if plan.launcher_pid is not None:
            processes.append(_owned_process(plan.launcher_pid))
        write_record(
            plan.work / "parents.json",
            {"nonce": plan.nonce, "processes": [_identity(item) for item in processes]},
        )
    except (psutil.Error, OSError, KeyError) as error:
        raise UpdateFailure(PROCESS_IDENTITY) from error


def wait_for_parents(plan: Plan, timeout: float = 60) -> None:
    """2026-10-20：只等待已绑定的旧进程退出，不按名称杀死进程."""
    record = read_record(plan.work / "parents.json")
    identities = record.get("processes")
    if record.get("nonce") != plan.nonce or not isinstance(identities, list):
        raise UpdateFailure(PROCESS_IDENTITY)
    deadline = time.monotonic() + timeout
    while True:
        active = False
        for value in cast("list[object]", identities):
            if not isinstance(value, dict):
                raise UpdateFailure(PROCESS_IDENTITY)
            active |= _matching_process(cast("dict[str, object]", value)) is not None
        if not active:
            return
        if time.monotonic() >= deadline:
            raise UpdateFailure(EXIT_TIMEOUT)
        time.sleep(0.1)


def _recovery_arguments(plan: Plan, helper: Path) -> list[str]:
    """2026-10-20：恢复入口只有固定助手、当前事务和恢复标志."""
    expected = plan.work / ("panache-updater.exe" if sys.platform == "win32" else "panache-updater")
    if not _same_path(plain_path(str(helper)), expected):
        raise UpdateFailure(UNSAFE_PATH)
    return [str(helper), "--recover"]


def register_recovery(plan: Plan, helper: Path) -> None:
    """2026-10-20：记录一次性登录恢复入口，成功或撤销时删除，不提升权限."""
    arguments = _recovery_arguments(plan, helper)
    if sys.platform == "win32":
        command = subprocess.list2cmdline(arguments)
        if len(command) > RUN_ONCE_LIMIT:
            raise UpdateFailure(RECOVERY_UNAVAILABLE)
        with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, RUN_ONCE, 0, winreg.KEY_SET_VALUE) as key:
            winreg.SetValueEx(key, "!PanacheUpdate-" + plan.nonce, 0, winreg.REG_SZ, command)
    elif sys.platform == "darwin":
        agents = plain_path(str(Path.home() / "Library/LaunchAgents"))
        agents.mkdir(mode=0o700, parents=True, exist_ok=True)
        destination = agents / f"{APP_ID}.update-{plan.nonce}.plist"
        temporary = destination.with_suffix(".tmp")
        with temporary.open("xb") as output:
            plistlib.dump(
                {
                    "Label": destination.stem,
                    "ProgramArguments": arguments,
                    "RunAtLoad": True,
                    "ProcessType": "Background",
                },
                output,
            )
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(destination)
    else:
        raise UpdateFailure(UNSUPPORTED_INSTALL)


def unregister_recovery(plan: Plan) -> None:
    """2026-10-20：仅移除当前 nonce 对应的恢复入口."""
    if sys.platform == "win32":
        with (
            contextlib.suppress(FileNotFoundError),
            winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_ONCE, 0, winreg.KEY_SET_VALUE) as key,
        ):
            winreg.DeleteValue(key, "!PanacheUpdate-" + plan.nonce)
    elif sys.platform == "darwin":
        file = (
            plain_path(str(Path.home() / "Library/LaunchAgents"))
            / f"{APP_ID}.update-{plan.nonce}.plist"
        )
        file.unlink(missing_ok=True)


def run_installer(plan: Plan, *, rollback: bool = False) -> None:
    """2026-10-20：仅以当前用户运行已校验 NSIS，保留其注册表与卸载语义."""
    if sys.platform != "win32" or plan.mode != "win-install":
        raise UpdateFailure(UNSUPPORTED_INSTALL)
    package = plan.rollback if rollback else plan.package
    if package is None:
        raise UpdateFailure(RECOVERY_UNAVAILABLE)
    package.verify()
    version = plan.current if rollback else plan.version
    target = str(plan.target)
    if any(character in target for character in ('"', "\r", "\n")):
        raise UpdateFailure(UNSAFE_PATH)
    # 2026-10-20：NSIS 的 /D 必须最后且不加引号，不能使用通用 argv 的空格转义。
    arguments = subprocess.list2cmdline([str(package.file), "/S", "/currentuser", "--updated"])
    arguments += " /D=" + target
    # 2026-10-20：入口是当前事务内验证 SHA256 的固定 NSIS，不接受命令或额外参数。
    _require_unprivileged()
    deadline = time.monotonic() + 300
    with (plan.work / "installer.log").open("ab") as output:
        process, job = _spawn_process(arguments, plan.target.parent, dict(os.environ), output)
    _wait_installation(process, job, max(0, deadline - time.monotonic()))
    if process.returncode != 0 or _windows_version(plan.executable) != version:
        raise UpdateFailure(INSTALL_FAILED)
    _registry_binding(plan, version)


def _wait_installation(
    process: subprocess.Popen[bytes],
    job: _WindowsJob | None,
    timeout: float,
) -> None:
    """2026-10-20：安装器超时先精确停止整棵本次树，再把失败交给回滚."""
    deadline = time.monotonic() + timeout
    try:
        process.wait(timeout=timeout)
        if job:
            job.wait(max(0, deadline - time.monotonic()))
            job.release()
    except (OSError, subprocess.SubprocessError, UpdateFailure) as error:
        _stop_failed_launch(process, None, job)
        raise UpdateFailure(INSTALL_FAILED) from error


def swap_bundle(stage: Path, target: Path) -> None:
    """2026-10-20：同卷交换整个 macOS bundle，禁止两次 rename 的入口缺口."""
    if (
        sys.platform != "darwin"
        or stage.parent != target.parent
        or stage.suffix != ".app"
        or target.suffix != ".app"
    ):
        raise UpdateFailure(UNSUPPORTED_INSTALL)
    plain_path(str(stage))
    plain_path(str(target))
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    exchange = library.renamex_np
    exchange.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    exchange.restype = ctypes.c_int
    if exchange(os.fsencode(stage), os.fsencode(target), 2) != 0:
        raise UpdateFailure(REPLACE_FAILED) from OSError(ctypes.get_errno(), "renamex_np")
    descriptor = os.open(target.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def validate_stage_bundle(plan: Plan, stage: Path) -> None:
    """2026-10-20：验证完整签名，不移除隔离属性或重新签名绕过系统信任."""
    if sys.platform != "darwin" or plan.mode != "mac-bundle":
        raise UpdateFailure(UNSUPPORTED_INSTALL)
    result = _assess(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(stage)], INVALID_BUNDLE
    )
    if result.returncode != 0:
        raise UpdateFailure(INVALID_BUNDLE)
    quarantine: bytes | None = None
    for source in (plan.package.file, plan.target):
        quarantine = _mac_quarantine(source)
        if quarantine:
            _set_mac_quarantine(stage, quarantine)
            break
    if quarantine:
        assessment = _assess(
            ["/usr/sbin/spctl", "--assess", "--type", "execute", str(stage)], SYSTEM_APPROVAL
        )
        if assessment.returncode != 0:
            raise UpdateFailure(SYSTEM_APPROVAL)


def _mac_quarantine(source: Path) -> bytes | None:
    """2026-10-20：使用 Darwin 原生 xattr ABI；Python os 的 xattr 入口仅支持 Linux."""
    if sys.platform != "darwin":
        raise UpdateFailure(UNSUPPORTED_INSTALL)
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    read = library.getxattr
    read.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_uint32,
        ctypes.c_int,
    ]
    read.restype = ctypes.c_ssize_t
    name = b"com.apple.quarantine"
    size = int(read(os.fsencode(source), name, None, 0, 0, 0))
    if size < 0 and ctypes.get_errno() == errno.ENOATTR:
        return None
    if not 0 <= size <= MAX_QUARANTINE_BYTES:
        raise UpdateFailure(PERMISSIONS)
    buffer = ctypes.create_string_buffer(size)
    actual = int(read(os.fsencode(source), name, buffer, size, 0, 0))
    if not 0 <= actual <= size:
        raise UpdateFailure(PERMISSIONS)
    return ctypes.string_at(buffer, actual)


def _set_mac_quarantine(destination: Path, value: bytes) -> None:
    """2026-10-20：保持下载或旧应用的隔离标记，不自动移除系统信任限制."""
    if sys.platform != "darwin":
        raise UpdateFailure(UNSUPPORTED_INSTALL)
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    write = library.setxattr
    write.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_uint32,
        ctypes.c_int,
    ]
    write.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(value)
    if write(os.fsencode(destination), b"com.apple.quarantine", buffer, len(value), 0, 0) != 0:
        raise UpdateFailure(PERMISSIONS)


def _assess(arguments: list[str], failure: str) -> subprocess.CompletedProcess[bytes]:
    """2026-10-20：系统签名检查超时也只返回固定错误，不能绕过事务边界."""
    try:
        return subprocess.run(arguments, check=False, capture_output=True, timeout=90)  # noqa: S603
    except (OSError, subprocess.SubprocessError) as error:
        raise UpdateFailure(failure) from error


def _empty_identities() -> dict[int, dict[str, object]]:
    """2026-10-20：为每次启动分配独立的进程身份表."""
    return {}


def _process_session(pid: int) -> int:
    """2026-10-20：通过 POSIX 公共 getsid 读取独立 session，避免平台类型假设."""
    function = ctypes.CDLL(None, use_errno=True).getsid
    function.argtypes, function.restype = [ctypes.c_int], ctypes.c_int
    session = int(function(pid))
    if session < 0:
        raise ProcessLookupError(ctypes.get_errno(), "getsid")
    return session


class _BasicLimits(ctypes.Structure):
    """2026-10-20：Windows Job 的固定限制结构，不允许子进程逃逸."""

    _fields_ = [
        ("process_time", ctypes.c_int64),
        ("job_time", ctypes.c_int64),
        ("flags", ctypes.c_uint32),
        ("minimum", ctypes.c_size_t),
        ("maximum", ctypes.c_size_t),
        ("processes", ctypes.c_uint32),
        ("affinity", ctypes.c_size_t),
        ("priority", ctypes.c_uint32),
        ("scheduling", ctypes.c_uint32),
    ]
    flags: int


class _ExtendedLimits(ctypes.Structure):
    """2026-10-20：只启用关闭即结束本次新进程树的 Job 标记."""

    _fields_ = [
        ("basic", _BasicLimits),
        ("io", ctypes.c_uint64 * 6),
        ("process_memory", ctypes.c_size_t),
        ("job_memory", ctypes.c_size_t),
        ("peak_process_memory", ctypes.c_size_t),
        ("peak_job_memory", ctypes.c_size_t),
    ]
    basic: _BasicLimits


class _JobAccounting(ctypes.Structure):
    """2026-10-20：等待 Job 中所有本次子进程结束，而非只等启动器."""

    _fields_ = [
        ("times", ctypes.c_int64 * 4),
        ("page_faults", ctypes.c_uint32),
        ("total", ctypes.c_uint32),
        ("active", ctypes.c_uint32),
        ("terminated", ctypes.c_uint32),
    ]
    active: int


class _WindowsJob:
    """2026-10-20：挂起启动并先加入 Job，消除派生 sidecar 的记录时间窗口."""

    library: ctypes.CDLL

    def __init__(self) -> None:
        if sys.platform != "win32":
            raise UpdateFailure(UNSUPPORTED_INSTALL)
        self.library = ctypes.WinDLL("kernel32", use_last_error=True)
        create = self.library.CreateJobObjectW
        create.argtypes, create.restype = [ctypes.c_void_p, ctypes.c_wchar_p], ctypes.c_void_p
        self.handle = ctypes.c_void_p(create(None, None))
        if not self.handle.value:
            raise UpdateFailure(INSTALL_FAILED)
        try:
            self._limits(0x2000)
        except (OSError, UpdateFailure) as error:
            self._close()
            raise UpdateFailure(INSTALL_FAILED) from error

    def _limits(self, flags: int) -> None:
        """2026-10-20：健康提交前保留 KILL_ON_JOB_CLOSE，提交后显式解除."""
        value = _ExtendedLimits()
        value.basic.flags = flags
        function = self.library.SetInformationJobObject
        function.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        function.restype = ctypes.c_int
        if not function(self.handle, 9, ctypes.byref(value), ctypes.sizeof(value)):
            raise UpdateFailure(STOP_FAILED)

    def assign(self, process: subprocess.Popen[bytes]) -> None:
        """2026-10-20：主线程未运行前绑定已启动的精确 Windows 进程对象."""
        open_process = self.library.OpenProcess
        open_process.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
        open_process.restype = ctypes.c_void_p
        handle = ctypes.c_void_p(open_process(0x100 | 0x1, 0, process.pid))
        if not handle.value:
            raise UpdateFailure(STOP_FAILED)
        try:
            assign = self.library.AssignProcessToJobObject
            assign.argtypes, assign.restype = [ctypes.c_void_p, ctypes.c_void_p], ctypes.c_int
            if not assign(self.handle, handle):
                raise UpdateFailure(STOP_FAILED)
        finally:
            self._close_handle(handle)

    def active(self) -> int:
        """2026-10-20：查询本 Job 内的实际存活数，包括安装器派生的进程."""
        value = _JobAccounting()
        function = self.library.QueryInformationJobObject
        function.argtypes = [
            ctypes.c_void_p,
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_uint32,
            ctypes.c_void_p,
        ]
        function.restype = ctypes.c_int
        if not function(self.handle, 1, ctypes.byref(value), ctypes.sizeof(value), None):
            raise UpdateFailure(STOP_FAILED)
        return value.active

    def wait(self, timeout: float) -> None:
        """2026-10-20：等待所有子进程结束，超时不得冒充安装完成."""
        deadline = time.monotonic() + timeout
        while self.active():
            if time.monotonic() >= deadline:
                raise UpdateFailure(EXIT_TIMEOUT)
            time.sleep(0.05)

    def _member_handles(self) -> list[ctypes.c_void_p]:
        """2026-10-20：保留本 Job 现存成员的等待句柄，退出计数归零不等于句柄已发信号."""
        if sys.platform != "win32":
            raise UpdateFailure(UNSUPPORTED_INSTALL)
        query = self.library.QueryInformationJobObject
        query.argtypes = [
            ctypes.c_void_p,
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_uint32,
            ctypes.c_void_p,
        ]
        query.restype = ctypes.c_int
        capacity = 64
        while capacity <= MAX_JOB_PROCESSES:
            buffer = ctypes.create_string_buffer(8 + capacity * ctypes.sizeof(ctypes.c_size_t))
            if query(self.handle, 3, buffer, ctypes.sizeof(buffer), None):
                count = ctypes.c_uint32.from_buffer(buffer, 4).value
                if count > capacity:
                    raise UpdateFailure(STOP_FAILED)
                return self._open_members(buffer, count)
            if ctypes.get_last_error() != WIN_MORE_DATA:
                raise UpdateFailure(STOP_FAILED)
            capacity = max(capacity * 2, ctypes.c_uint32.from_buffer(buffer).value)
        raise UpdateFailure(STOP_FAILED)

    def _member_handle(self, pid: int) -> ctypes.c_void_p | None:
        """2026-10-20：打开后再次确认 Job 归属，PID 复用不能延伸等待目标."""
        if sys.platform != "win32":
            raise UpdateFailure(UNSUPPORTED_INSTALL)
        function = self.library.OpenProcess
        function.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
        function.restype = ctypes.c_void_p
        handle = ctypes.c_void_p(function(0x100000 | 0x1000, 0, pid))
        if not handle.value:
            if ctypes.get_last_error() == WIN_NO_PROCESS:
                return None
            raise UpdateFailure(STOP_FAILED)
        accepted = False
        try:
            belongs = ctypes.c_int()
            check = self.library.IsProcessInJob
            check.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
            check.restype = ctypes.c_int
            if not check(handle, self.handle, ctypes.byref(belongs)) or not belongs.value:
                raise UpdateFailure(STOP_FAILED)
            accepted = True
            return handle
        finally:
            if not accepted:
                self._close_handle(handle)

    def _open_members(
        self, buffer: ctypes.Array[ctypes.c_char], count: int
    ) -> list[ctypes.c_void_p]:
        """2026-10-20：只能等待精确 Job 成员，不按进程名终止或扩展目标."""
        handles: list[ctypes.c_void_p] = []
        try:
            for index in range(count):
                offset = 8 + index * ctypes.sizeof(ctypes.c_size_t)
                pid = ctypes.c_size_t.from_buffer(buffer, offset).value
                if handle := self._member_handle(pid):
                    handles.append(handle)
        except (OSError, UpdateFailure):
            for handle in handles:
                self._close_handle(handle)
            raise
        return handles

    def stop(self) -> None:
        """2026-10-20：结束 Job 内的本次树，同时等待成员的内核退出信号与 Job 清空."""
        handles = self._member_handles()
        deadline = time.monotonic() + 10
        try:
            function = self.library.TerminateJobObject
            function.argtypes, function.restype = [ctypes.c_void_p, ctypes.c_uint32], ctypes.c_int
            if not function(self.handle, 1):
                raise UpdateFailure(STOP_FAILED)
            # 2026-10-20：终止后再捕获一次，覆盖首次枚举后派生、尚未退出的成员。
            handles.extend(self._member_handles())
            self.wait(max(0, deadline - time.monotonic()))
            wait = self.library.WaitForSingleObject
            wait.argtypes, wait.restype = [ctypes.c_void_p, ctypes.c_uint32], ctypes.c_uint32
            for handle in handles:
                remaining = max(0, int((deadline - time.monotonic()) * 1000))
                if wait(handle, remaining) != 0:
                    raise UpdateFailure(STOP_FAILED)
        finally:
            for handle in handles:
                self._close_handle(handle)
        self._close()

    def release(self) -> None:
        """2026-10-20：只有健康 ACK 后才让新版脱离助手生命周期."""
        if self.handle.value:
            try:
                self._limits(0)
            except UpdateFailure as error:
                raise UpdateFailure(INSTALL_FAILED) from error
            self._close()

    def _close_handle(self, handle: ctypes.c_void_p) -> None:
        """2026-10-20：显式关闭本模块持有的句柄，禁止继承给应用."""
        function = self.library.CloseHandle
        function.argtypes, function.restype = [ctypes.c_void_p], ctypes.c_int
        function(handle)

    def _close(self) -> None:
        """2026-10-20：幂等释放助手自己的 Job 句柄."""
        if self.handle.value:
            self._close_handle(self.handle)
            self.handle = ctypes.c_void_p()


def _spawn_process(
    arguments: list[str] | str,
    directory: Path,
    environment: dict[str, str],
    output: BinaryIO,
) -> tuple[subprocess.Popen[bytes], _WindowsJob | None]:
    """2026-10-20：Windows 挂起加入 Job 后才恢复，其他系统使用独立 session."""
    job = _WindowsJob() if sys.platform == "win32" else None
    process: subprocess.Popen[bytes] | None = None
    flags = 0
    if sys.platform == "win32":
        flags = subprocess.CREATE_NO_WINDOW | 0x4
    try:
        process = subprocess.Popen(  # noqa: S603
            arguments,
            cwd=directory,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=output,
            close_fds=True,
            creationflags=flags,
            start_new_session=sys.platform != "win32",
        )
        if job:
            job.assign(process)
            _owned_process(process.pid).resume()
    except (OSError, psutil.Error, UpdateFailure) as error:
        if process:
            _stop_failed_launch(process, None, job)
        elif job:
            job.stop()
        raise UpdateFailure(INSTALL_FAILED) from error
    else:
        return process, job


@dataclass
class LaunchedApp:
    """2026-10-20：持有本次新启动的精确进程身份及健康确认边界."""

    plan: Plan
    root: dict[str, object]
    rollback: bool = False
    identities: dict[int, dict[str, object]] = field(default_factory=_empty_identities)
    job: _WindowsJob | None = None

    def capture_children(self) -> None:
        """2026-10-20：先在内存记录进程，写日志失败也仍可可靠停止."""
        process = _matching_process(self.root)
        if process is not None:
            for child in process.children(recursive=True):
                with contextlib.suppress(psutil.NoSuchProcess):
                    self.identities[child.pid] = _identity(child)
        elif sys.platform != "win32":
            self._capture_session()

    def _capture_session(self) -> None:
        """2026-10-20：旧根已退出时只收集本次独立 session 内仍存活的同用户后代."""
        root_pid = cast("int", self.root["pid"])
        created = cast("float", self.root["created"])
        try:
            root = _owned_process(root_pid)
            if root.create_time() != created or root.status() != psutil.STATUS_ZOMBIE:
                # 2026-10-20：活着但入口改变、或 PID 已复用时，不能冒充已退出并继续回滚。
                raise UpdateFailure(STOP_FAILED)
        except psutil.NoSuchProcess:
            pass
        for process in psutil.process_iter():
            with contextlib.suppress(psutil.NoSuchProcess, psutil.AccessDenied, ProcessLookupError):
                if process.username() != psutil.Process().username():
                    continue
                if _process_session(process.pid) != root_pid or process.create_time() < created:
                    continue
                owned = _owned_process(process.pid)
                self.identities[owned.pid] = _identity(owned)

    def remember(self) -> None:
        """2026-10-20：轮询捕获本次树并持久化，健康提交必须知道日志是否失败."""
        self.capture_children()
        write_record(
            self.plan.work / "launch.json",
            {
                "nonce": self.plan.nonce,
                "version": self.plan.current if self.rollback else self.plan.version,
                "root": self.root,
                "processes": list(self.identities.values()),
            },
        )

    def accepts_ack(self, ack: dict[str, object]) -> bool:
        """2026-10-20：确认主进程、真实版本和其本次后端，而非仅检查 PID 存在."""
        self.remember()
        expected = self.plan.current if self.rollback else self.plan.version
        pid, backend_pid = ack.get("pid"), ack.get("backendPid")
        if (
            ack.get("nonce") != self.plan.nonce
            or ack.get("version") != expected
            or not isinstance(pid, int)
            or isinstance(pid, bool)
            or not isinstance(backend_pid, int)
            or isinstance(backend_pid, bool)
        ):
            return False
        try:
            root = _matching_process(self.root)
            main, backend = _owned_process(pid), _owned_process(backend_pid)
            if root is None or (main.pid != root.pid and not _descends_from(main, root)):
                return False
            executable = Path(main.exe())
            main_matches = _same_path(executable, self.plan.executable)
            if self.plan.mode == "win-portable":
                main_matches = (
                    executable.name == "Panache.exe" and _windows_version(executable) == expected
                )
            if not main_matches:
                return False
            expected_backend = executable.parent / "resources/backend/handwriting-backend.exe"
            if self.plan.mode == "mac-bundle":
                expected_backend = (
                    self.plan.target / "Contents/Resources/backend/handwriting-backend"
                )
            if not _same_path(Path(backend.exe()), expected_backend) or not _descends_from(
                backend, main
            ):
                return False
            self.identities[main.pid], self.identities[backend.pid] = (
                _identity(main),
                _identity(backend),
            )
            self.remember()
        except (psutil.Error, OSError, UpdateFailure):
            return False
        return True

    def stop(self) -> None:
        """2026-10-20：只终止本次记录的进程及子进程，等待文件锁真实释放."""
        if self.job:
            self.job.stop()
            self.job = None
            return
        self.capture_children()
        live = [
            process
            for identity in [*self.identities.values(), self.root]
            if (process := _matching_process(identity)) is not None
        ]
        for process in live:
            with contextlib.suppress(psutil.NoSuchProcess):
                process.terminate()
        _, alive = psutil.wait_procs(live, timeout=5)
        for process in alive:
            with contextlib.suppress(psutil.NoSuchProcess):
                process.kill()
        _, alive = psutil.wait_procs(alive, timeout=5)
        for process in alive:
            with contextlib.suppress(psutil.NoSuchProcess):
                if process.status() != psutil.STATUS_ZOMBIE:
                    raise UpdateFailure(STOP_FAILED)

    def release(self) -> None:
        """2026-10-20：健康确认后解除 Job 关闭语义，保留新版及其后端运行."""
        if self.job:
            self.job.release()
            self.job = None


def launch_application(plan: Plan, *, rollback: bool = False) -> LaunchedApp:
    """2026-10-20：固定启动入口与参数，保留工作区并将输出写入事务目录."""
    plain_path(str(plan.executable))
    environment = {
        key: value
        for key, value in os.environ.items()
        if key not in {"ELECTRON_RUN_AS_NODE", "NODE_OPTIONS"}
    }
    flag = "--panache-rollback=" if rollback else "--panache-update="
    if sys.platform == "win32":
        environment["LOCALAPPDATA"] = str(plan.data_root.parent)
    elif sys.platform == "darwin":
        environment["HOME"] = str(plan.data_root.parents[2])
    arguments = [str(plan.executable), flag + plan.nonce]
    with (plan.work / "application.log").open("ab") as output:
        process, job = _spawn_process(arguments, plan.executable.parent, environment, output)
    launched: LaunchedApp | None = None
    try:
        launched = LaunchedApp(plan, _identity(_owned_process(process.pid)), rollback, job=job)
        launched.remember()
    except (psutil.Error, OSError, UpdateFailure) as error:
        _stop_failed_launch(process, launched, job)
        raise UpdateFailure(INSTALL_FAILED) from error
    return launched


def _stop_failed_launch(
    process: subprocess.Popen[bytes],
    launched: LaunchedApp | None,
    job: _WindowsJob | None,
) -> None:
    """2026-10-20：启动后记录失败也先停止本次树，不能失去句柄后直接回滚."""
    failure: BaseException | None = None
    try:
        if launched:
            launched.stop()
        elif job:
            job.stop()
    except (psutil.Error, OSError, subprocess.SubprocessError, UpdateFailure) as error:
        failure = error
    try:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=10)
    except (psutil.Error, OSError, subprocess.SubprocessError, UpdateFailure) as error:
        failure = error
    if failure:
        raise UpdateFailure(STOP_FAILED) from failure


def stop_interrupted_launch(plan: Plan) -> None:
    """2026-10-20：恢复时只处理相同事务和相同出生身份的未确认进程."""
    _require_unprivileged()
    file = plan.work / "launch.json"
    if not file.exists():
        return
    value = read_record(file)
    root, identities = value.get("root"), value.get("processes")
    if (
        value.get("nonce") != plan.nonce
        or value.get("version") != plan.version
        or not isinstance(root, dict)
        or not isinstance(identities, list)
    ):
        raise UpdateFailure(PROCESS_IDENTITY)
    restored: dict[int, dict[str, object]] = {}
    for item in cast("list[object]", identities):
        if not isinstance(item, dict):
            raise UpdateFailure(PROCESS_IDENTITY)
        identity = cast("dict[str, object]", item)
        if not isinstance(identity.get("pid"), int):
            raise UpdateFailure(PROCESS_IDENTITY)
        restored[cast("int", identity["pid"])] = identity
    LaunchedApp(plan, cast("dict[str, object]", root), identities=restored).stop()
