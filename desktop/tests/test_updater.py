# Copyright (C) 2026 SXP-Simon
import hashlib
import io
import plistlib
import stat
import struct
import sys
import zipfile
from dataclasses import replace
from pathlib import Path
from unittest.mock import Mock

import pytest
import updater
from updater_core import (
    Package,
    Plan,
    UpdateFailure,
    extract_bundle,
    plain_path,
    read_record,
    stamp,
    write_record,
)


@pytest.fixture
def plan(tmp_path, monkeypatch):
    data_root = tmp_path / "中文 空格" / "HandwritingWeb"
    nonce = "a" * 32
    work = data_root / "updates" / "transactions" / nonce
    work.mkdir(parents=True)
    target = tmp_path / "便携 app" / "Panache.exe"
    target.parent.mkdir()
    target.write_bytes(b"previous executable")
    package = work / "package.exe"
    package.write_bytes(b"new executable")
    digest = hashlib.sha256(package.read_bytes()).hexdigest()
    result = Plan(
        work,
        nonce,
        "win-portable",
        "1.7.0",
        "1.7.1",
        target,
        data_root,
        Package(package, package.stat().st_size, digest),
        None,
        101,
        102,
        target,
        103,
    )
    monkeypatch.setattr(updater.native, "validate_installation", Mock())
    monkeypatch.setattr(updater.native, "register_recovery", Mock())
    monkeypatch.setattr(updater.native, "unregister_recovery", Mock())
    monkeypatch.setattr(updater.native, "wait_for_parents", Mock())
    monkeypatch.setattr(updater.native, "refuse_other_instances", Mock())
    monkeypatch.setattr(updater.native, "stop_interrupted_launch", Mock())
    return result


def plan_record(plan):
    return {
        "schema": 1,
        "appId": "io.github.sxp-simon.handwriting",
        "nonce": plan.nonce,
        "mode": plan.mode,
        "current": plan.current,
        "version": plan.version,
        "target": str(plan.target),
        "dataRoot": str(plan.data_root),
        "packageFile": str(plan.package.file),
        "packageSize": plan.package.size,
        "packageDigest": plan.package.digest,
        "rollbackFile": None,
        "rollbackSize": None,
        "rollbackDigest": None,
        "parentPid": plan.parent_pid,
        "backendPid": plan.backend_pid,
        "parentExecutable": str(plan.parent_executable),
        "launcherPid": plan.launcher_pid,
    }


def test_plan_strict_schema_paths_and_versions(plan):
    file = plan.work / "plan.json"
    value = plan_record(plan)
    write_record(file, value)
    assert Plan.load(file) == plan
    for change in (
        {"command": "arbitrary"},
        {"version": "1.7.0"},
        {"packageFile": str(plan.target)},
        {"nonce": "../"},
        {"parentPid": True},
        {"target": str(plan.target.parent / ".." / "Panache.exe")},
    ):
        write_record(file, {**value, **change})
        with pytest.raises(UpdateFailure):
            Plan.load(file)


def test_plan_supports_custom_profile_directory_without_weakening_parent_binding(plan):
    original = plan.data_root
    custom = original.with_name("自定义资料目录")
    original.replace(custom)
    work = custom / "updates" / "transactions" / plan.nonce
    package = replace(plan.package, file=work / "package.exe")
    updated = replace(plan, data_root=custom, work=work, package=package)
    write_record(work / "plan.json", plan_record(updated))
    assert Plan.load(work / "plan.json") == updated
    value = plan_record(updated)
    value["dataRoot"] = str(custom.parent)
    write_record(work / "plan.json", value)
    with pytest.raises(UpdateFailure, match="invalidPlan"):
        Plan.load(work / "plan.json")


def test_recovery_plan_inference_requires_fixed_frozen_helper(plan, monkeypatch):
    helper = plan.work / "panache-updater.exe"
    monkeypatch.setattr(sys, "executable", str(helper))
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    assert updater.plan_argument(None, recovery=True) == plan.work / "plan.json"
    for recovery, frozen, name in [
        (False, True, "panache-updater.exe"),
        (True, False, "panache-updater.exe"),
        (True, True, "python.exe"),
    ]:
        monkeypatch.setattr(sys, "frozen", frozen)
        monkeypatch.setattr(sys, "executable", str(plan.work / name))
        with pytest.raises(UpdateFailure, match="invalidPlan"):
            updater.plan_argument(None, recovery=recovery)


@pytest.mark.parametrize("value", ["relative.exe", "//host/app.exe", "\\\\host\\app.exe"])
def test_plain_path_refuses_unsafe(value):
    with pytest.raises(UpdateFailure):
        plain_path(value)


def test_package_tamper_before_apply_preserves_old(plan):
    updater.prepare(plan, Path(sys.executable))
    plan.package.file.write_bytes(b"tampered bytes")
    with pytest.raises(UpdateFailure, match="integrity"):
        updater.apply(plan)
    assert plan.target.read_bytes() == b"previous executable"


def test_portable_success_commits_only_after_ack(plan, monkeypatch):
    updater.prepare(plan, Path(sys.executable))
    launched = Mock()
    launched.accepts_ack.return_value = True

    def launch(_plan, *, rollback=False):
        assert not rollback
        assert plan.target.read_bytes() == b"new executable"
        assert plan.backup.read_bytes() == b"previous executable"
        write_record(plan.work / "health.json", {"nonce": plan.nonce, "version": plan.version})
        return launched

    monkeypatch.setattr(updater.native, "launch_application", launch)
    updater.finish(plan, timeout=0.5)
    assert read_record(plan.work / "state.json")["phase"] == "committed"
    assert not plan.backup.exists()
    launched.stop.assert_not_called()


@pytest.mark.parametrize("failure", ["no_ack", "wrong_nonce", "wrong_process", "launch_failure"])
def test_failed_new_version_stops_then_restores_old(plan, monkeypatch, failure):
    updater.prepare(plan, Path(sys.executable))
    stopped = []

    def launch(_plan, *, rollback=False):
        launched = Mock()
        if rollback:
            assert plan.target.read_bytes() == b"previous executable"
            assert failure == "launch_failure" or stopped == [True]
            launched.accepts_ack.return_value = True
            write_record(plan.work / "health.json", {"nonce": plan.nonce, "version": plan.current})
        else:
            if failure == "launch_failure":
                msg = "fixture launch failure"
                raise OSError(msg)
            launched.stop.side_effect = lambda: stopped.append(True)
            launched.accepts_ack.return_value = failure != "wrong_process"
            if failure != "no_ack":
                write_record(
                    plan.work / "health.json",
                    {
                        "nonce": "bad" if failure == "wrong_nonce" else plan.nonce,
                        "version": plan.version,
                    },
                )
        return launched

    monkeypatch.setattr(updater.native, "launch_application", launch)
    updater.finish(plan, timeout=0.03)
    assert read_record(plan.work / "state.json")["phase"] == "rolled_back"
    assert plan.target.read_bytes() == b"previous executable"


def test_failed_stop_never_swaps_under_running_process(plan, monkeypatch):
    updater.prepare(plan, Path(sys.executable))
    launched = Mock()
    launched.stop.side_effect = OSError("locked")
    monkeypatch.setattr(updater.native, "launch_application", Mock(return_value=launched))
    with pytest.raises(UpdateFailure, match="stopFailed"):
        updater.finish(plan, timeout=0.001)
    assert plan.target.read_bytes() == b"new executable"
    assert plan.backup.read_bytes() == b"previous executable"


def test_rollback_rejects_corrupted_backup(plan):
    updater.prepare(plan, Path(sys.executable))
    plan.backup.write_bytes(b"corrupted backup")
    with pytest.raises(UpdateFailure, match="integrity"):
        updater.rollback(plan, "fixture", timeout=0.001)


@pytest.mark.parametrize(
    "command", [b"", b"ABORT\n", b"ARM wrong\n", b"ARM " + b"a" * 32 + b"\nABORT\n"]
)
def test_missing_arm_or_abort_does_not_update(plan, monkeypatch, command):
    monkeypatch.setattr(sys, "stdin", io.TextIOWrapper(io.BytesIO(command)))
    updater.execute(plan, Path(sys.executable))
    assert read_record(plan.work / "state.json")["phase"] == "aborted"
    assert plan.target.read_bytes() == b"previous executable"
    assert not plan.backup.exists()


def test_prepare_failure_cleans_own_staging_only(plan, monkeypatch):
    def failure(*_args):
        plan.stage.write_bytes(b"partial")
        msg = "fixture disk failure"
        raise OSError(msg)

    monkeypatch.setattr(updater, "copy_verified", failure)
    with pytest.raises(OSError, match="fixture disk failure"):
        updater.execute(plan, Path(sys.executable))
    assert not plan.stage.exists()
    assert plan.target.read_bytes() == b"previous executable"


def archive_package(plan, entries):
    target = plan.work / "package.zip"
    with zipfile.ZipFile(target, "w") as archive:
        for name, value, mode in entries:
            info = zipfile.ZipInfo(name)
            info.external_attr = mode << 16
            archive.writestr(info, value)
    return Package(target, target.stat().st_size, hashlib.sha256(target.read_bytes()).hexdigest())


@pytest.mark.parametrize(
    "entries",
    [
        [("Panache.app/../escape", b"x", stat.S_IFREG)],
        [("Panache.app/Case", b"x", stat.S_IFREG), ("Panache.app/case", b"x", stat.S_IFREG)],
        [("Panache.app/link", b"../../escape", stat.S_IFLNK)],
        [("Panache.app/link", b"missing", stat.S_IFLNK)],
        [("Panache.app/link", b"link", stat.S_IFLNK)],
        [("Panache.app/link", b"x" * 4097, stat.S_IFLNK)],
    ],
)
def test_archive_rejects_escape_duplicates_and_bad_links(plan, entries):
    package = archive_package(plan, entries)
    with pytest.raises((UpdateFailure, OSError)):
        extract_bundle(package, plan.target.parent / "stage.app")


@pytest.mark.skipif(sys.platform == "win32", reason="Windows symlink privilege varies")
def test_archive_accepts_internal_framework_link_and_apple_metadata(plan):
    package = archive_package(
        plan,
        [
            ("__MACOSX/._Panache.app", b"metadata", stat.S_IFREG),
            ("Panache.app/Framework/Versions/A/file", b"data", stat.S_IFREG | 0o644),
            ("Panache.app/Framework/Versions/Current", b"A", stat.S_IFLNK),
        ],
    )
    stage = plan.target.parent / "stage.app"
    extract_bundle(package, stage)
    assert (stage / "Framework/Versions/Current/file").read_bytes() == b"data"


def test_recovery_before_arm_leaves_current_untouched(plan):
    updater.prepare(plan, Path(sys.executable))
    updater.recover(plan)
    assert read_record(plan.work / "state.json")["phase"] == "aborted"
    assert plan.target.read_bytes() == b"previous executable"


def test_interrupted_portable_after_replace_rolls_back(plan, monkeypatch):
    updater.prepare(plan, Path(sys.executable))
    updater.apply(plan)
    stamp(plan.work, "applying")

    def launch(_plan, *, rollback=False):
        assert rollback
        write_record(plan.work / "health.json", {"nonce": plan.nonce, "version": plan.current})
        return Mock(accepts_ack=Mock(return_value=True))

    monkeypatch.setattr(updater.native, "launch_application", launch)
    updater.recover(plan)
    assert plan.target.read_bytes() == b"previous executable"
    updater.native.stop_interrupted_launch.assert_called_once()


@pytest.mark.parametrize("failed_phase", ["applying", "awaiting_health", "rolling_back"])
def test_journal_failures_do_not_block_old_version_restoration(plan, monkeypatch, failed_phase):
    updater.prepare(plan, Path(sys.executable))
    original_stamp = updater.stamp
    original_write = updater.write_record

    def write(file, value):
        if value.get("phase") == failed_phase:
            msg = "fixture journal unavailable"
            raise OSError(msg)
        original_write(file, value)

    def stamp_state(work, phase, **details):
        if phase == failed_phase or (failed_phase == "rolling_back" and phase == "awaiting_health"):
            msg = "fixture journal unavailable"
            raise OSError(msg)
        original_stamp(work, phase, **details)

    def launch(_plan, *, rollback=False):
        assert rollback
        assert plan.target.read_bytes() == b"previous executable"
        original_write(plan.work / "health.json", {"nonce": plan.nonce, "version": plan.current})
        return Mock(accepts_ack=Mock(return_value=True))

    monkeypatch.setattr(updater, "stamp", stamp_state)
    monkeypatch.setattr(updater, "write_record", write)
    monkeypatch.setattr(updater.native, "launch_application", launch)
    updater.finish(plan, timeout=0.1)
    assert plan.target.read_bytes() == b"previous executable"


def test_parent_exit_timeout_never_replaces_or_launches_second_instance(plan, monkeypatch):
    updater.prepare(plan, Path(sys.executable))
    wait = Mock(side_effect=OSError("fixture backend still alive"))
    launch = Mock()
    monkeypatch.setattr(updater.native, "wait_for_parents", wait)
    monkeypatch.setattr(updater.native, "launch_application", launch)
    updater.finish(plan, timeout=0.01)
    assert plan.target.read_bytes() == b"previous executable"
    launch.assert_not_called()


def test_another_window_after_prepare_aborts_without_install_replace_or_restart(plan, monkeypatch):
    updater.prepare(plan, Path(sys.executable))
    blocked = Mock(side_effect=UpdateFailure("fileLocked"))
    installer, launch, replace_target = Mock(), Mock(), Mock()
    monkeypatch.setattr(updater.native, "refuse_other_instances", blocked)
    monkeypatch.setattr(updater.native, "run_installer", installer)
    monkeypatch.setattr(updater.native, "launch_application", launch)
    monkeypatch.setattr(updater, "retry_replace", replace_target)
    updater.finish(plan, timeout=0.01)
    assert plan.target.read_bytes() == b"previous executable"
    assert read_record(plan.work / "state.json")["phase"] == "aborted"
    assert read_record(plan.work / "result.json")["reason"] == "fileLocked"
    installer.assert_not_called()
    launch.assert_not_called()
    replace_target.assert_not_called()


def test_duplicate_prepare_does_not_delete_preexisting_recovery_backup(plan, monkeypatch):
    updater.prepare(plan, Path(sys.executable))
    stamp(plan.work, "armed")
    monkeypatch.setattr(sys, "stdin", io.TextIOWrapper(io.BytesIO(b"")))
    with pytest.raises(UpdateFailure, match="transactionExists"):
        updater.execute(plan, Path(sys.executable))
    assert plan.backup.read_bytes() == b"previous executable"


def fake_bundle(target, version):
    executable = target / "Contents/MacOS/Panache"
    executable.parent.mkdir(parents=True)
    executable.write_bytes(struct.pack("<II", 0xFEEDFACF, 0x0100000C))
    executable.chmod(0o755)
    with (target / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleIdentifier": "io.github.sxp-simon.handwriting",
                "CFBundleShortVersionString": version,
                "CFBundleExecutable": "Panache",
            },
            stream,
        )


def test_mac_atomic_swap_journal_failure_restores_visible_old_bundle(plan, monkeypatch):
    target = plan.target.parent / "Panache.app"
    fake_bundle(target, plan.current)
    staged_source = plan.work / "archive-source" / "Panache.app"
    fake_bundle(staged_source, plan.version)
    package_file = plan.work / "package.zip"
    with zipfile.ZipFile(package_file, "w") as archive:
        for file in staged_source.rglob("*"):
            archive.write(file, str(Path("Panache.app") / file.relative_to(staged_source)))
    package = Package(
        package_file,
        package_file.stat().st_size,
        hashlib.sha256(package_file.read_bytes()).hexdigest(),
    )
    mac = replace(plan, mode="mac-bundle", target=target, package=package, launcher_pid=None)
    monkeypatch.setattr(updater.native, "validate_stage_bundle", Mock())

    def swap(stage, destination):
        # Core simulation; the platform suite covers real renamex_np on macOS.
        temporary = destination.with_name("atomic-swap-fixture")
        destination.replace(temporary)
        stage.replace(destination)
        temporary.replace(stage)

    monkeypatch.setattr(updater.native, "swap_bundle", swap)
    updater.prepare(mac, Path(sys.executable))
    original = updater.stamp

    def stamp_state(work, phase, **details):
        if phase == "swapped":
            msg = "fixture interrupted journal after swap"
            raise OSError(msg)
        original(work, phase, **details)

    def launch(_plan, *, rollback=False):
        assert rollback
        updater.validate_bundle(target, plan.current)
        write_record(mac.work / "health.json", {"nonce": mac.nonce, "version": mac.current})
        return Mock(accepts_ack=Mock(return_value=True))

    monkeypatch.setattr(updater, "stamp", stamp_state)
    monkeypatch.setattr(updater.native, "launch_application", launch)
    updater.finish(mac, timeout=0.1)
    updater.validate_bundle(target, plan.current)
    assert read_record(mac.work / "state.json")["phase"] == "rolled_back"
