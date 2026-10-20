# Copyright (C) 2026 SXP-Simon
"""2026-10-20：桌面更新事务的受限路径、校验和持久化协议."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import secrets
import shutil
import stat
import struct
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import cast

APP_ID = "io.github.sxp-simon.handwriting"
MAX_ENTRIES = 100000
MAX_LINK_BYTES = 4096
MACH_HEADER_BYTES = 8
MAX_PACKAGE_BYTES = 2 * 1024 * 1024 * 1024
MAX_EXPANDED_BYTES = 3 * 1024 * 1024 * 1024
TERMINAL_PHASES = frozenset({"committed", "rolled_back", "aborted"})


class UpdateError(Exception):
    """2026-10-20：仅向界面传递固定错误码."""

    def __init__(self, code: str) -> None:
        """2026-10-20：保存可翻译的错误码."""
        super().__init__(code)
        self.code = code


UpdateFailure = UpdateError


def read_record(file: Path) -> dict[str, object]:
    """2026-10-20：限制记录大小并检查 JSON 对象边界."""
    details = file.lstat()
    if not stat.S_ISREG(details.st_mode) or details.st_size > 256 * 1024:
        msg = "invalidPlan"
        raise UpdateFailure(msg)
    value: object = json.loads(file.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or not all(
        isinstance(key, str) for key in cast("dict[object, object]", value)
    ):
        msg = "invalidPlan"
        raise UpdateFailure(msg)
    return cast("dict[str, object]", value)


def write_record(file: Path, value: dict[str, object]) -> None:
    """2026-10-20：同步临时文件后原子提交事务记录."""
    temporary = file.with_name(file.name + "." + secrets.token_hex(8) + ".tmp")
    try:
        with temporary.open("x", encoding="utf-8", newline="\n") as output:
            json.dump(value, output, ensure_ascii=False, separators=(",", ":"))
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(file)
    finally:
        temporary.unlink(missing_ok=True)
    if os.name != "nt":
        descriptor = os.open(file.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def plain_path(value: str) -> Path:
    """2026-10-20：拒绝设备、网络和重解析入口，要求绝对普通路径."""
    if not value or "\x00" in value or value.startswith(("\\\\", "//")):
        msg = "unsafePath"
        raise UpdateFailure(msg)
    result = Path(value)
    if not result.is_absolute() or result == Path(result.anchor) or ".." in result.parts:
        msg = "unsafePath"
        raise UpdateFailure(msg)
    if os.name == "nt" and ":" in value[2:]:
        msg = "unsafePath"
        raise UpdateFailure(msg)
    for component in (result, *result.parents):
        if not component.exists() and not component.is_symlink():
            continue
        details = component.lstat()
        if stat.S_ISLNK(details.st_mode) or getattr(details, "st_file_attributes", 0) & 0x400:
            msg = "unsafePath"
            raise UpdateFailure(msg)
    return result


def require_string(record: dict[str, object], key: str) -> str:
    """2026-10-20：从不可信记录读取必需文本字段."""
    value = record.get(key)
    if not isinstance(value, str):
        msg = "invalidPlan"
        raise UpdateFailure(msg)
    return value


def require_integer(record: dict[str, object], key: str, maximum: int) -> int:
    """2026-10-20：整数不接受布尔值和越界值."""
    value = record.get(key)
    if not isinstance(value, int) or isinstance(value, bool) or not 0 < value <= maximum:
        msg = "invalidPlan"
        raise UpdateFailure(msg)
    return value


@dataclass(frozen=True)
class Package:
    """2026-10-20：私有事务目录内的固定安装包."""

    file: Path
    size: int
    digest: str

    @classmethod
    def parse(cls, record: dict[str, object], prefix: str, work: Path) -> Package:
        """2026-10-20：只接受工作目录内已确定名字的包."""
        file = plain_path(require_string(record, prefix + "File"))
        digest = require_string(record, prefix + "Digest")
        size = require_integer(record, prefix + "Size", MAX_PACKAGE_BYTES)
        if file.parent != work or not re.fullmatch(r"[a-f0-9]{64}", digest):
            msg = "invalidPlan"
            raise UpdateFailure(msg)
        return cls(file, size, digest)

    def verify(self) -> None:
        """2026-10-20：始终从同一普通文件句柄检查长度与 SHA256."""
        plain_path(str(self.file))
        with self.file.open("rb") as source:
            details = os.fstat(source.fileno())
            if not stat.S_ISREG(details.st_mode) or details.st_size != self.size:
                msg = "integrity"
                raise UpdateFailure(msg)
            if hashlib.file_digest(source, "sha256").hexdigest() != self.digest:
                msg = "integrity"
                raise UpdateFailure(msg)


@dataclass(frozen=True)
class Plan:
    """2026-10-20：主进程生成，外部助手再次验证的固定产品更新计划."""

    work: Path
    nonce: str
    mode: str
    current: str
    version: str
    target: Path
    data_root: Path
    package: Package
    rollback: Package | None
    parent_pid: int
    backend_pid: int
    parent_executable: Path
    launcher_pid: int | None

    @classmethod
    def load(cls, file: Path) -> Plan:
        """2026-10-20：拒绝任意命令、额外参数和路径重定向."""
        file = plain_path(str(file))
        value = read_record(file)
        expected = {
            "schema",
            "appId",
            "nonce",
            "mode",
            "current",
            "version",
            "target",
            "dataRoot",
            "packageFile",
            "packageSize",
            "packageDigest",
            "parentPid",
            "backendPid",
            "rollbackFile",
            "rollbackSize",
            "rollbackDigest",
            "parentExecutable",
            "launcherPid",
        }
        if set(value) != expected or value.get("schema") != 1 or value.get("appId") != APP_ID:
            msg = "invalidPlan"
            raise UpdateFailure(msg)
        nonce = require_string(value, "nonce")
        work = file.parent
        if (
            not re.fullmatch(r"[a-f0-9]{32}", nonce)
            or file.name != "plan.json"
            or work.name != nonce
            or work.parent.name != "transactions"
            or work.parent.parent.name != "updates"
        ):
            msg = "invalidPlan"
            raise UpdateFailure(msg)
        data_root = plain_path(require_string(value, "dataRoot"))
        if work.parent.parent.parent != data_root:
            msg = "invalidPlan"
            raise UpdateFailure(msg)
        mode = require_string(value, "mode")
        if mode not in {"win-install", "win-portable", "mac-bundle"}:
            msg = "invalidPlan"
            raise UpdateFailure(msg)
        current, version = plan_versions(value)
        target = plan_target(value, mode)
        package = Package.parse(value, "package", work)
        if package.file.name != ("package.zip" if mode == "mac-bundle" else "package.exe"):
            msg = "invalidPlan"
            raise UpdateFailure(msg)
        rollback = Package.parse(value, "rollback", work) if mode == "win-install" else None
        if rollback and rollback.file.name != "rollback.exe":
            msg = "invalidPlan"
            raise UpdateFailure(msg)
        if mode != "win-install" and any(
            value[key] is not None for key in ("rollbackFile", "rollbackSize", "rollbackDigest")
        ):
            msg = "invalidPlan"
            raise UpdateFailure(msg)
        return cls(
            work,
            nonce,
            mode,
            current,
            version,
            target,
            data_root,
            package,
            rollback,
            require_integer(value, "parentPid", 2**31 - 1),
            require_integer(value, "backendPid", 2**31 - 1),
            plain_path(require_string(value, "parentExecutable")),
            require_integer(value, "launcherPid", 2**31 - 1) if mode == "win-portable" else None,
        )

    @property
    def stage(self) -> Path:
        """2026-10-20：阶段文件只能位于目标同卷同父目录."""
        suffix = self.target.suffix if self.mode != "win-install" else ""
        return self.target.with_name(f".panache-update-{self.nonce}-stage{suffix}")

    @property
    def backup(self) -> Path:
        """2026-10-20：备份名由 nonce 唯一确定，不接受外部路径."""
        suffix = self.target.suffix if self.mode != "win-install" else ""
        return self.target.with_name(f".panache-update-{self.nonce}-backup{suffix}")

    @property
    def executable(self) -> Path:
        """2026-10-20：不同安装方式的固定启动入口."""
        if self.mode == "win-install":
            return self.target / "Panache.exe"
        if self.mode == "mac-bundle":
            return self.target / "Contents" / "MacOS" / "Panache"
        return self.target


def plan_versions(value: dict[str, object]) -> tuple[str, str]:
    """2026-10-20：只允许稳定版本的严格升级."""
    current = require_string(value, "current")
    version = require_string(value, "version")
    pattern = r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"
    if not all(re.fullmatch(pattern, item) for item in (current, version)) or tuple(
        map(int, version.split("."))
    ) <= tuple(map(int, current.split("."))):
        message = "invalidPlan"
        raise UpdateFailure(message)
    return current, version


def plan_target(value: dict[str, object], mode: str) -> Path:
    """2026-10-20：不同安装方式固定目标类型."""
    target = plain_path(require_string(value, "target"))
    if (mode == "win-portable" and target.suffix.lower() != ".exe") or (
        mode == "mac-bundle" and target.suffix != ".app"
    ):
        message = "unsafePath"
        raise UpdateFailure(message)
    return target


def require_space(parent: Path, needed: int) -> None:
    """2026-10-20：在退出当前应用前确认磁盘有准备和恢复空间."""
    if shutil.disk_usage(parent).free < needed + 64 * 1024 * 1024:
        msg = "diskSpace"
        raise UpdateFailure(msg)


def copy_verified(package: Package, target: Path) -> None:
    """2026-10-20：复制后再校验阶段文件，防止缓存文件在准备中被换包."""
    package.verify()
    with package.file.open("rb") as source, target.open("xb") as output:
        shutil.copyfileobj(source, output)
        output.flush()
        os.fsync(output.fileno())
    Package(target, package.size, package.digest).verify()


def extract_bundle(package: Package, stage: Path) -> None:
    """2026-10-20：安全展开 macOS bundle，允许仅指向 bundle 内部的相对符号链接."""
    package.verify()
    total = 0
    seen: set[str] = set()
    links: list[tuple[Path, str]] = []
    with zipfile.ZipFile(package.file) as archive:
        for entry in archive.infolist():
            part = PurePosixPath(entry.filename)
            if part.parts[:1] == ("__MACOSX",):
                continue
            if (
                not part.parts
                or part.parts[0] != "Panache.app"
                or part.is_absolute()
                or ".." in part.parts
                or "\\" in entry.filename
            ):
                msg = "invalidArchive"
                raise UpdateFailure(msg)
            relative = Path(*part.parts[1:])
            key = str(relative).casefold()
            if key in seen:
                msg = "invalidArchive"
                raise UpdateFailure(msg)
            seen.add(key)
            total += entry.file_size
            if total > MAX_EXPANDED_BYTES or len(seen) > MAX_ENTRIES:
                msg = "invalidArchive"
                raise UpdateFailure(msg)
            extract_entry(archive, entry, stage, relative, links)
    for destination, link in links:
        destination.symlink_to(link)
    for destination, _ in links:
        try:
            if not destination.resolve(strict=True).is_relative_to(stage.resolve()):
                msg = "invalidArchive"
                raise UpdateFailure(msg)
        except (OSError, RuntimeError) as error:
            msg = "invalidArchive"
            raise UpdateFailure(msg) from error


def extract_entry(
    archive: zipfile.ZipFile,
    entry: zipfile.ZipInfo,
    stage: Path,
    relative: Path,
    links: list[tuple[Path, str]],
) -> None:
    """2026-10-20：流式提取普通项，延迟创建受限内部链接."""
    destination = stage / relative
    if entry.is_dir():
        destination.mkdir(parents=True, exist_ok=True)
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    mode = entry.external_attr >> 16
    if stat.S_ISLNK(mode):
        if entry.file_size > MAX_LINK_BYTES:
            msg = "invalidArchive"
            raise UpdateFailure(msg)
        link = archive.read(entry).decode("utf-8")
        if "\x00" in link or "\\" in link:
            msg = "invalidArchive"
            raise UpdateFailure(msg)
        resolved = (destination.parent / link).resolve()
        if Path(link).is_absolute() or not resolved.is_relative_to(stage.resolve()):
            msg = "invalidArchive"
            raise UpdateFailure(msg)
        links.append((destination, link))
    elif mode == 0 or stat.S_ISREG(mode):
        with archive.open(entry) as source, destination.open("xb") as output:
            shutil.copyfileobj(source, output)
        destination.chmod(mode & 0o777 or 0o644)
    else:
        msg = "invalidArchive"
        raise UpdateFailure(msg)


def validate_bundle(bundle: Path, version: str) -> None:
    """2026-10-20：要求相同 bundleID、精确版本及 arm64 可执行入口."""
    with (bundle / "Contents" / "Info.plist").open("rb") as source:
        info: object = plistlib.load(source)
    if not isinstance(info, dict):
        msg = "invalidBundle"
        raise UpdateFailure(msg)
    values = cast("dict[str, object]", info)
    if (
        values.get("CFBundleIdentifier") != APP_ID
        or values.get("CFBundleShortVersionString") != version
        or values.get("CFBundleExecutable") != "Panache"
    ):
        msg = "invalidBundle"
        raise UpdateFailure(msg)
    executable = bundle / "Contents" / "MacOS" / "Panache"
    with executable.open("rb") as source:
        header = source.read(MACH_HEADER_BYTES)
    if len(header) != MACH_HEADER_BYTES or struct.unpack("<II", header) != (0xFEEDFACF, 0x0100000C):
        msg = "invalidBundle"
        raise UpdateFailure(msg)
    if not os.access(executable, os.X_OK):
        msg = "invalidBundle"
        raise UpdateFailure(msg)


def stamp(work: Path, phase: str, **details: object) -> None:
    """2026-10-20：在每个可恢复边界持久化日志，供重启后恢复和反馈."""
    write_record(
        work / "state.json",
        {"phase": phase, "time": time.time(), "helperPid": os.getpid(), **details},
    )
