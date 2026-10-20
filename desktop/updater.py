# Copyright (C) 2026 SXP-Simon
"""2026-10-20：独立进程执行更新，确认新版健康前保留可恢复旧版本."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import os
import shutil
import sys
import time
import zipfile
from pathlib import Path
from typing import TYPE_CHECKING, Protocol

import updater_platform as native
from updater_core import (
    TERMINAL_PHASES,
    Package,
    Plan,
    UpdateFailure,
    copy_verified,
    extract_bundle,
    plain_path,
    read_record,
    require_space,
    stamp,
    validate_bundle,
    write_record,
)

if TYPE_CHECKING:
    from collections.abc import Generator

if sys.platform == "win32":
    import msvcrt
else:
    import fcntl

HEALTH_TIMEOUT = 120.0


class LaunchedApp(Protocol):
    """2026-10-20：仅管理本次启动的应用进程树."""

    def accepts_ack(self, ack: dict[str, object]) -> bool:
        """2026-10-20：确认健康记录来自本次启动."""
        ...

    def stop(self) -> None:
        """2026-10-20：回滚前结束本次新进程树，不能扩大到其他用户实例."""
        ...

    def release(self) -> None:
        """2026-10-20：健康确认后解除助手退出时终止进程的保护."""
        ...


@contextlib.contextmanager
def transaction_lock(work: Path) -> Generator[None]:
    """2026-10-20：操作系统锁在崩溃后自动释放，恢复进程不会并行写事务."""
    with (work / "transaction.lock").open("a+b") as stream:
        stream.seek(0)
        if stream.read(1) == b"":
            stream.write(b"0")
            stream.flush()
        stream.seek(0)
        if sys.platform == "win32":
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            if sys.platform == "win32":
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def remove_owned(plan: Plan, target: Path) -> None:
    """2026-10-20：仅清理本事务同父目录的阶段文件与备份，不跟随链接."""
    if target not in {plan.stage, plan.backup} or target.parent != plan.target.parent:
        msg = "unsafePath"
        raise UpdateFailure(msg)
    plain_path(str(target))
    if target.is_dir():
        shutil.rmtree(target)
    else:
        target.unlink(missing_ok=True)


def tree_size(root: Path) -> int:
    """2026-10-20：统计安装目录，拒绝 Windows junction 等重解析节点."""
    size = 0
    for directory, folders, files in os.walk(root, followlinks=False):
        for name in [*folders, *files]:
            target = Path(directory) / name
            plain_path(str(target))
            if target.is_file():
                size += target.stat().st_size
    return size


def prepare(plan: Plan, helper: Path) -> None:
    """2026-10-20：当前应用退出前完成校验、阶段准备、备份与恢复入口注册."""
    native.validate_installation(plan)
    if plan.stage.exists() or plan.backup.exists():
        msg = "transactionExists"
        raise UpdateFailure(msg)
    plan.package.verify()
    if plan.rollback:
        plan.rollback.verify()
    require_space(plan.target.parent, plan.package.size * 2)
    stamp(plan.work, "preparing")
    if plan.mode == "win-portable":
        require_space(plan.target.parent, plan.package.size + plan.target.stat().st_size)
        copy_verified(plan.package, plan.stage)
        with plan.target.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        size = plan.target.stat().st_size
        copy_verified(Package(plan.target, size, digest), plan.backup)
        Package(plan.backup, size, digest).verify()
        write_record(plan.work / "backup.json", {"size": size, "digest": digest})
    elif plan.mode == "mac-bundle":
        validate_bundle(plan.target, plan.current)
        require_space(plan.target.parent, plan.package.size * 6)
        extract_bundle(plan.package, plan.stage)
        validate_bundle(plan.stage, plan.version)
        native.validate_stage_bundle(plan, plan.stage)
    else:
        size = tree_size(plan.target)
        require_space(plan.target.parent, size * 2 + plan.package.size)
        shutil.copytree(plan.target, plan.backup)
    native.register_recovery(plan, helper)
    stamp(plan.work, "ready")


def retry_replace(source: Path, target: Path, timeout: float = 20) -> None:
    """2026-10-20：仅为已退出便携启动器短暂释放文件句柄预留重试."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            plain_path(str(target))
            source.replace(target)
        except PermissionError as error:
            if time.monotonic() >= deadline:
                msg = "fileLocked"
                raise UpdateFailure(msg) from error
            time.sleep(0.2)
        else:
            return


def apply(plan: Plan) -> None:
    """2026-10-20：退出完成后再次校验包，使用安装类型对应的更新方式."""
    native.wait_for_parents(plan)
    plan.package.verify()
    stamp(plan.work, "applying")
    if plan.mode == "win-portable":
        Package(plan.stage, plan.package.size, plan.package.digest).verify()
        retry_replace(plan.stage, plan.target)
    elif plan.mode == "mac-bundle":
        validate_bundle(plan.stage, plan.version)
        native.swap_bundle(plan.stage, plan.target)
        # 2026-10-20：原子交换后旧 bundle 始终可见，日志中断时也可按版本识别。
        stamp(plan.work, "swapped")
        plan.stage.replace(plan.backup)
    else:
        native.run_installer(plan)
    stamp(plan.work, "awaiting_health")


def wait_health(plan: Plan, launched: LaunchedApp, version: str, timeout: float) -> None:
    """2026-10-20：同时确认随机事务、精确版本和本次启动身份."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            ack = read_record(plan.work / "health.json")
            if (
                ack.get("nonce") == plan.nonce
                and ack.get("version") == version
                and launched.accepts_ack(ack)
            ):
                return
        except (OSError, ValueError, UpdateFailure):
            pass
        time.sleep(0.15)
    msg = "healthTimeout"
    raise UpdateFailure(msg)


def launch_and_confirm(
    plan: Plan, *, rollback: bool = False, timeout: float = HEALTH_TIMEOUT
) -> None:
    """2026-10-20：启动失败或健康确认失败时，先精确终止本次进程树."""
    (plan.work / "health.json").unlink(missing_ok=True)
    launched = native.launch_application(plan, rollback=rollback)
    try:
        wait_health(plan, launched, plan.current if rollback else plan.version, timeout)
        launched.release()
    except BaseException:
        try:
            launched.stop()
        except (OSError, UpdateFailure) as error:
            msg = "stopFailed"
            raise UpdateFailure(msg) from error
        raise


def best_effort_record(file: Path, value: dict[str, object]) -> bool:
    """2026-10-20：磁盘日志失败不能阻止恢复旧程序；恢复入口与备份继续保留."""
    try:
        write_record(file, value)
    except OSError:
        return False
    return True


def recovery_stamp(plan: Plan, phase: str, reason: str) -> bool:
    """2026-10-20：恢复期间尽力记录，不能先写日志再决定能否恢复."""
    return best_effort_record(
        plan.work / "state.json",
        {
            "phase": phase,
            "reason": reason,
            "time": time.time(),
            "helperPid": os.getpid(),
        },
    )


def rollback(plan: Plan, reason: str, timeout: float = HEALTH_TIMEOUT) -> None:
    """2026-10-20：只恢复程序与安装状态，不覆盖用户已保存输入."""
    try:
        previous_phase = read_record(plan.work / "state.json").get("phase")
    except (OSError, ValueError, UpdateFailure):
        previous_phase = None
    recovery_stamp(plan, "rolling_back", reason)
    if plan.mode == "win-portable":
        if not plan.backup.is_file():
            msg = "rollbackUnavailable"
            raise UpdateFailure(msg)
        saved = read_record(plan.work / "backup.json")
        size, digest = saved.get("size"), saved.get("digest")
        if not isinstance(size, int) or isinstance(size, bool) or not isinstance(digest, str):
            msg = "integrity"
            raise UpdateFailure(msg)
        Package(plan.backup, size, digest).verify()
        remove_owned(plan, plan.stage)
        copy_verified(Package(plan.backup, size, digest), plan.stage)
        retry_replace(plan.stage, plan.target)
    elif plan.mode == "mac-bundle":
        try:
            validate_bundle(plan.target, plan.current)
        except (OSError, ValueError, UpdateFailure):
            previous = plan.backup if plan.backup.exists() else plan.stage
            validate_bundle(previous, plan.current)
            native.swap_bundle(previous, plan.target)
    else:
        if not plan.rollback:
            msg = "rollbackUnavailable"
            raise UpdateFailure(msg)
        plan.rollback.verify()
        if previous_phase not in {"ready", "armed"}:
            native.run_installer(plan, rollback=True)
    recovery_stamp(plan, "awaiting_rollback_health", reason)
    best_effort_record(
        plan.work / "result.json",
        {
            "nonce": plan.nonce,
            "outcome": "rolled_back",
            "reason": reason,
            "from": plan.version,
            "version": plan.current,
        },
    )
    launch_and_confirm(plan, rollback=True, timeout=timeout)
    if not recovery_stamp(plan, "rolled_back", reason):
        return
    native.unregister_recovery(plan)
    remove_owned(plan, plan.stage)
    remove_owned(plan, plan.backup)


def finish(plan: Plan, timeout: float = HEALTH_TIMEOUT) -> None:
    """2026-10-20：仅新版健康确认后提交；异常自动回滚并健康重启旧版."""
    try:
        native.wait_for_parents(plan)
        native.refuse_other_instances(plan)
    except (OSError, UpdateFailure) as error:
        best_effort_record(
            plan.work / "result.json",
            {
                "nonce": plan.nonce,
                "outcome": "rolled_back",
                "reason": error.code if isinstance(error, UpdateFailure) else "exitTimeout",
                "version": plan.current,
            },
        )
        abort(plan)
        return
    try:
        apply(plan)
        launch_and_confirm(plan, timeout=timeout)
    except (OSError, ValueError, UpdateFailure) as error:
        reason = error.code if isinstance(error, UpdateFailure) else "applyFailed"
        if reason == "stopFailed":
            stamp(plan.work, "failed", reason=reason)
            raise
        rollback(plan, reason, timeout)
        return
    stamp(plan.work, "committed")
    write_record(
        plan.work / "result.json",
        {"nonce": plan.nonce, "outcome": "committed", "version": plan.version},
    )
    native.unregister_recovery(plan)
    remove_owned(plan, plan.stage)
    remove_owned(plan, plan.backup)


def abort(plan: Plan) -> None:
    """2026-10-20：没有 ARM 或用户取消时保持原安装可运行."""
    native.unregister_recovery(plan)
    remove_owned(plan, plan.stage)
    remove_owned(plan, plan.backup)
    stamp(plan.work, "aborted")


def recover(plan: Plan) -> None:
    """2026-10-20：登录恢复入口在断电或中断后读取已落盘阶段."""
    state = read_record(plan.work / "state.json")
    phase = state.get("phase")
    if phase in TERMINAL_PHASES:
        native.unregister_recovery(plan)
        return
    if phase in {"preparing", "ready"}:
        abort(plan)
    else:
        native.stop_interrupted_launch(plan)
        rollback(plan, "interrupted")


def execute(plan: Plan, helper: Path, *, recovery: bool = False) -> None:
    """2026-10-20：READY→ARM→父进程 EOF 才能进入实际替换."""
    with transaction_lock(plan.work):
        if recovery:
            recover(plan)
            return
        try:
            prepare(plan, helper)
        except (OSError, ValueError, UpdateFailure, zipfile.BadZipFile):
            with contextlib.suppress(OSError, ValueError, UpdateFailure):
                state = (
                    read_record(plan.work / "state.json")
                    if (plan.work / "state.json").exists()
                    else {}
                )
                if state.get("phase") == "preparing" and state.get("helperPid") == os.getpid():
                    abort(plan)
                elif not state:
                    stamp(plan.work, "aborted")
            raise
        command = sys.stdin.buffer.readline(128)
        if command != f"ARM {plan.nonce}\n".encode():
            abort(plan)
            return
        stamp(plan.work, "armed")
        if sys.stdin.buffer.read(1):
            abort(plan)
            return
        finish(plan)


def main() -> int:
    """2026-10-20：独立打包助手只接受固定计划文件与恢复开关."""
    parser = argparse.ArgumentParser(prog="panache-updater")
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--recover", action="store_true")
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    if args.self_check:
        return 0
    plan: Plan | None = None
    try:
        native.require_user_context()
        file = plan_argument(args.plan, recovery=bool(args.recover))
        plan = Plan.load(file)
        execute(plan, Path(sys.executable).resolve(), recovery=bool(args.recover))
    except (OSError, ValueError, UpdateFailure, zipfile.BadZipFile) as error:
        if plan:
            reason = error.code if isinstance(error, UpdateFailure) else "applyFailed"
            phase = "failed"
            with contextlib.suppress(OSError, ValueError, UpdateFailure):
                if read_record(plan.work / "state.json").get("phase") == "aborted":
                    phase = "aborted"
            recovery_stamp(plan, phase, reason)
        return 1
    return 0


def plan_argument(value: object, *, recovery: bool = False) -> Path:
    """2026-10-20：只有固定名字的独立助手可从自身事务目录恢复，缩短 RunOnce 命令."""
    if isinstance(value, Path):
        return value
    executable = Path(sys.executable)
    if (
        value is None
        and recovery
        and getattr(sys, "frozen", False) is True
        and executable.name
        in {
            "panache-updater.exe",
            "panache-updater",
        }
    ):
        return plain_path(str(executable)).parent / "plan.json"
    msg = "invalidPlan"
    raise UpdateFailure(msg)


if __name__ == "__main__":
    raise SystemExit(main())
