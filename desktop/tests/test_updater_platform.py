# Copyright (C) 2026 SXP-Simon
import dataclasses
import hashlib
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from unittest.mock import Mock

import psutil
import pytest
import updater_platform as native
from updater_core import Package, Plan, UpdateFailure


def running_python():
    # 2026-10-20：framework Python 的 sys.executable 是会再次 exec 的启动器，不能充当稳定 GUI。
    return str(Path(psutil.Process().exe()).resolve())


@pytest.fixture
def native_plan(tmp_path):
    work = tmp_path / "事务 中文"
    work.mkdir()
    package = work / "package.exe"
    package.write_bytes(b"verified")
    executable = Path(running_python())
    return Plan(
        work,
        "a" * 32,
        "win-portable",
        "1.7.0",
        "1.7.1",
        executable,
        tmp_path,
        Package(package, package.stat().st_size, hashlib.sha256(b"verified").hexdigest()),
        None,
        os.getpid(),
        os.getpid(),
        executable,
        os.getpid(),
    )


def wait_file(path):
    deadline = time.monotonic() + 15
    while not path.exists():
        if time.monotonic() >= deadline:
            pytest.fail(f"Owned fixture did not start: {path}")
        time.sleep(0.02)
    return int(path.read_text())


def wait_stopped(identity):
    deadline = time.monotonic() + 10
    while native._matching_process(identity) is not None:
        if time.monotonic() >= deadline:
            pytest.fail(f"Owned process survived cleanup: {identity}")
        time.sleep(0.02)


@pytest.mark.parametrize("mode", ["win-install", "win-portable", "mac-bundle"])
def test_other_window_of_same_target_is_rejected_without_termination(
    native_plan, monkeypatch, mode
):
    plan = dataclasses.replace(native_plan, mode=mode)
    expected = plan.target if mode == "win-portable" else plan.executable
    parent = Mock(pid=101)
    renderer = Mock(pid=102)
    renderer.exe.return_value = str(expected)
    other = Mock(pid=103)
    other.exe.return_value = str(expected)
    unrelated = Mock(pid=104)
    unrelated.exe.return_value = str(native_plan.work / "OtherProduct")
    monkeypatch.setattr(
        native.psutil, "process_iter", Mock(return_value=[renderer, unrelated, other])
    )
    monkeypatch.setattr(native, "_descends_from", lambda process, _parent: process is renderer)
    with pytest.raises(UpdateFailure, match="fileLocked"):
        native.refuse_other_instances(plan, parent)
    for process in (renderer, other, unrelated):
        process.kill.assert_not_called()
        process.terminate.assert_not_called()


def test_prepare_allows_own_renderer_but_apply_rechecks_new_window(native_plan, monkeypatch):
    plan = dataclasses.replace(native_plan, mode="win-install")
    parent, renderer = Mock(pid=101), Mock(pid=102)
    parent.exe.return_value = renderer.exe.return_value = str(plan.executable)
    monkeypatch.setattr(native.psutil, "process_iter", Mock(return_value=[parent, renderer]))
    monkeypatch.setattr(native, "_descends_from", lambda process, _parent: process is renderer)
    native.refuse_other_instances(plan, parent)
    with pytest.raises(UpdateFailure, match="fileLocked"):
        native.refuse_other_instances(plan)


def test_nsis_preflight_refuses_other_target_with_same_image_name(native_plan, monkeypatch):
    plan = dataclasses.replace(native_plan, mode="win-install")
    other = Mock(pid=103)
    other.exe.return_value = str(native_plan.work / "another-install" / "Panache.exe")
    other.username.return_value = psutil.Process().username()
    monkeypatch.setattr(native.psutil, "process_iter", Mock(return_value=[other]))
    with pytest.raises(UpdateFailure, match="fileLocked"):
        native.refuse_other_instances(plan)
    other.terminate.assert_not_called()


def start_fixture(plan, monkeypatch, *, broken_record=False):
    root_file, child_file = plan.work / "root-pid", plan.work / "child-pid"
    child_code = "import time;time.sleep(60)"
    code = (
        "import os,subprocess,sys,time;from pathlib import Path;"
        f"Path({str(root_file)!r}).write_text(str(os.getpid()));"
        f"child=subprocess.Popen([{running_python()!r},'-c',{child_code!r}]);"
        f"Path({str(child_file)!r}).write_text(str(child.pid));time.sleep(60)"
    )
    original = native._spawn_process

    def spawn(arguments, directory, environment, output):
        assert arguments[0] == str(plan.executable)
        return original([running_python(), "-c", code], directory, environment, output)

    monkeypatch.setattr(native, "_spawn_process", spawn)
    if broken_record:

        def fail_record(_file, _value):
            wait_file(child_file)
            message = "disk full"
            raise OSError(message)

        monkeypatch.setattr(native, "write_record", fail_record)
    return root_file, child_file


def test_native_identity_refuses_reused_pid_without_touching_live_process():
    process = psutil.Process()
    identity = native._identity(process)
    assert native._matching_process(identity).pid == os.getpid()
    assert native._matching_process({**identity, "created": process.create_time() - 1}) is None
    assert (
        native._matching_process({**identity, "exe": str(Path(sys.executable).with_name("other"))})
        is None
    )
    with pytest.raises(UpdateFailure, match=native.PROCESS_IDENTITY):
        native._matching_process({**identity, "pid": True})


def test_fixture_uses_actual_runtime_even_when_python_executable_names_a_launcher(monkeypatch):
    actual = Path(psutil.Process().exe()).resolve()
    monkeypatch.setattr(sys, "executable", str(actual.with_name("framework-launcher")))
    assert Path(running_python()) == actual


def test_real_new_application_tree_stops_even_when_recording_is_broken(native_plan, monkeypatch):
    _, child_file = start_fixture(native_plan, monkeypatch)
    launched = native.launch_application(native_plan)
    child = psutil.Process(wait_file(child_file))
    identity = native._identity(child)
    monkeypatch.setattr(native, "write_record", Mock(side_effect=OSError("disk full")))
    launched.stop()
    wait_stopped(launched.root)
    wait_stopped(identity)


def test_launch_record_failure_cleans_real_root_and_sidecar_before_return(native_plan, monkeypatch):
    root_file, child_file = start_fixture(native_plan, monkeypatch, broken_record=True)
    with pytest.raises(UpdateFailure, match=native.INSTALL_FAILED):
        native.launch_application(native_plan)
    for path in (root_file, child_file):
        pid = wait_file(path)
        try:
            process = psutil.Process(pid)
            assert process.status() == psutil.STATUS_ZOMBIE
        except psutil.NoSuchProcess:
            pass


def test_fast_exit_is_reported_as_fixed_failure(native_plan, monkeypatch):
    original = native._spawn_process

    def spawn(_arguments, directory, environment, output):
        process, job = original(
            [running_python(), "-c", "raise SystemExit(2)"], directory, environment, output
        )
        process.wait(timeout=10)
        return process, job

    monkeypatch.setattr(native, "_spawn_process", spawn)
    with pytest.raises(UpdateFailure, match=native.INSTALL_FAILED):
        native.launch_application(native_plan)


@pytest.mark.skipif(sys.platform != "win32", reason="NSIS uses a Windows Job Object")
def test_real_installer_timeout_cleans_only_its_owned_tree(tmp_path):
    child_file = tmp_path / "installer-child"
    child_code = "import time;time.sleep(60)"
    code = (
        "import subprocess,sys,time;from pathlib import Path;"
        f"child=subprocess.Popen([{running_python()!r},'-c',{child_code!r}]);"
        f"Path({str(child_file)!r}).write_text(str(child.pid));time.sleep(60)"
    )
    with (tmp_path / "installer.log").open("wb") as output:
        process, job = native._spawn_process(
            [running_python(), "-c", code], tmp_path, dict(os.environ), output
        )
    child = psutil.Process(wait_file(child_file))
    child_identity = native._identity(child)
    with pytest.raises(UpdateFailure, match=native.INSTALL_FAILED):
        native._wait_installation(process, job, 0.05)
    assert process.poll() is not None
    wait_stopped(child_identity)
    assert psutil.Process().is_running()


def test_health_release_preserves_real_application_until_explicit_stop(native_plan, monkeypatch):
    _, child_file = start_fixture(native_plan, monkeypatch)
    launched = native.launch_application(native_plan)
    child_identity = native._identity(psutil.Process(wait_file(child_file)))
    launched.release()
    assert native._matching_process(launched.root) is not None
    assert native._matching_process(child_identity) is not None
    launched.stop()
    wait_stopped(child_identity)


def test_recovery_refuses_elevation_before_reading_untrusted_files(native_plan, monkeypatch):
    guard = Mock(side_effect=UpdateFailure(native.PERMISSIONS))
    monkeypatch.setattr(native, "_require_unprivileged", guard)
    monkeypatch.setattr(native, "read_record", Mock(side_effect=AssertionError("read too early")))
    with pytest.raises(UpdateFailure, match=native.PERMISSIONS):
        native.stop_interrupted_launch(native_plan)
    with pytest.raises(UpdateFailure, match=native.PERMISSIONS):
        native.require_user_context()
    assert guard.call_count == 2


def test_system_signature_timeout_is_fixed_error(monkeypatch):
    monkeypatch.setattr(
        native.subprocess, "run", Mock(side_effect=subprocess.TimeoutExpired("codesign", 1))
    )
    with pytest.raises(UpdateFailure, match=native.INVALID_BUNDLE):
        native._assess(["/usr/bin/codesign", "--verify"], native.INVALID_BUNDLE)


def test_nsis_rejects_missing_recovery_package(native_plan):
    if sys.platform != "win32":
        pytest.skip("Windows NSIS identity contract")
    installed = dataclasses.replace(native_plan, mode="win-install", rollback=None)
    with pytest.raises(UpdateFailure, match=native.RECOVERY_UNAVAILABLE):
        native.run_installer(installed, rollback=True)


def test_recovery_command_does_not_repeat_long_transaction_directory(native_plan):
    work = native_plan.work / ("long-user-profile-" * 5)
    work.mkdir()
    plan = dataclasses.replace(native_plan, work=work)
    helper = work / ("panache-updater.exe" if sys.platform == "win32" else "panache-updater")
    helper.write_bytes(b"fixed bundled helper")
    arguments = native._recovery_arguments(plan, helper)
    assert arguments == [str(helper), "--recover"]
    assert subprocess.list2cmdline(arguments).count(str(work)) == 1


@pytest.mark.skipif(sys.platform != "win32", reason="Electron Windows dataDir contract")
def test_profile_uses_actual_parent_local_appdata_before_chromium_profile(tmp_path):
    local, roaming, chrome = (tmp_path / name for name in ("local", "roaming", "chrome"))
    for directory in (local, roaming, chrome):
        directory.mkdir()
    parent = Mock()
    parent.environ.return_value = {"LOCALAPPDATA": str(local), "APPDATA": str(roaming)}
    parent.cmdline.return_value = ["Panache.exe", "--user-data-dir=" + str(chrome)]
    assert native._profile_from_parent(parent) == local / "HandwritingWeb"
    parent.environ.return_value = {"APPDATA": str(roaming)}
    assert native._profile_from_parent(parent) == chrome / "HandwritingWeb"
    parent.cmdline.return_value = ["Panache.exe"]
    assert native._profile_from_parent(parent) == roaming / "Panache/HandwritingWeb"


@pytest.mark.skipif(sys.platform != "darwin", reason="Electron macOS dataDir contract")
def test_profile_uses_actual_parent_home(tmp_path):
    parent = Mock()
    parent.environ.return_value = {"HOME": str(tmp_path)}
    assert (
        native._profile_from_parent(parent)
        == tmp_path / "Library/Application Support/HandwritingWeb"
    )


@pytest.mark.skipif(sys.platform != "darwin", reason="Darwin extended attribute ABI")
def test_mac_quarantine_round_trip_uses_native_attribute_api(tmp_path):
    source, destination = tmp_path / "download.zip", tmp_path / "Panache.app"
    source.write_bytes(b"fixture")
    destination.mkdir()
    assert native._mac_quarantine(source) is None
    quarantine = b"0081;0;PanacheTests;00000000-0000-0000-0000-000000000000"
    native._set_mac_quarantine(source, quarantine)
    assert native._mac_quarantine(source) == quarantine
    native._set_mac_quarantine(destination, native._mac_quarantine(source))
    assert native._mac_quarantine(destination) == quarantine


def test_relaunch_preserves_workspace_without_overriding_chromium_profile(native_plan, monkeypatch):
    original = native._spawn_process

    def spawn(arguments, directory, environment, output):
        assert not any(value.startswith("--user-data-dir") for value in arguments)
        if sys.platform == "win32":
            assert Path(environment["LOCALAPPDATA"]) == native_plan.data_root.parent
        return original(
            [running_python(), "-c", "import time;time.sleep(60)"], directory, environment, output
        )

    monkeypatch.setattr(native, "_spawn_process", spawn)
    launched = native.launch_application(native_plan)
    launched.stop()


@pytest.mark.skipif(sys.platform != "win32", reason="Real NSIS command-line contract")
def test_real_nsis_directory_with_chinese_and_spaces(native_plan, monkeypatch):
    compiler = os.environ.get("PANACHE_TEST_MAKENSIS") or shutil.which("makensis")
    if not compiler:
        pytest.skip("Set PANACHE_TEST_MAKENSIS to a real makensis.exe")
    package_file = native_plan.work / "安装器 fixture.exe"
    script = native_plan.work / "fixture.nsi"
    script.write_text(
        'Unicode true\nName "Panache native fixture"\n'
        f'OutFile "{package_file}"\nSilentInstall silent\nRequestExecutionLevel user\n'
        'InstallDir "$TEMP\\panache-wrong-directory"\nSection\n'
        'CreateDirectory "$INSTDIR"\nFileOpen $0 "$INSTDIR\\received.txt" w\n'
        'FileWriteUTF16LE $0 "$INSTDIR"\nFileClose $0\nSectionEnd\n',
        encoding="utf-8-sig",
    )
    subprocess.run([compiler, str(script)], check=True, capture_output=True, timeout=30)  # noqa: S603
    target = native_plan.work / "安装 目标 中文"
    package = Package(
        package_file,
        package_file.stat().st_size,
        hashlib.sha256(package_file.read_bytes()).hexdigest(),
    )
    plan = dataclasses.replace(native_plan, mode="win-install", target=target, package=package)
    monkeypatch.setattr(native, "_require_unprivileged", Mock())
    monkeypatch.setattr(native, "_windows_version", Mock(return_value=plan.version))
    monkeypatch.setattr(native, "_registry_binding", Mock())
    native.run_installer(plan)
    assert (target / "received.txt").read_text(encoding="utf-16-le") == str(target)


@pytest.mark.skipif(sys.platform != "win32", reason="Native Windows Job lifecycle")
@pytest.mark.parametrize("release", [False, True])
def test_windows_helper_abrupt_exit_kills_only_unacknowledged_tree(native_plan, release):
    info_file = native_plan.work / "processes.json"
    child_file = native_plan.work / "grandchild-pid"
    log_file = native_plan.work / "owned.log"
    child_code = (
        "import subprocess,sys,time;from pathlib import Path;"
        f"child=subprocess.Popen([{running_python()!r},'-c','import time;time.sleep(60)']);"
        f"Path({str(child_file)!r}).write_text(str(child.pid));time.sleep(60)"
    )
    code = f"""
import os,sys,time
from pathlib import Path
sys.path.insert(0, {str(Path(native.__file__).parent)!r})
import psutil
import updater_platform as native
with Path({str(log_file)!r}).open('wb') as output:
    arguments = [{running_python()!r}, '-c', {child_code!r}]
    directory = Path({str(native_plan.work)!r})
    process, job = native._spawn_process(arguments, directory, dict(os.environ), output)
deadline = time.monotonic() + 15
while not Path({str(child_file)!r}).exists():
    if time.monotonic() >= deadline: raise RuntimeError('child not ready')
    time.sleep(.02)
child = psutil.Process(int(Path({str(child_file)!r}).read_text()))
identities = {{'root': native._identity(psutil.Process(process.pid)),
              'child': native._identity(child)}}
native.write_record(Path({str(info_file)!r}), identities)
if {release!r}: job.release()
os._exit(0)
"""
    supervisor = subprocess.Popen([running_python(), "-c", code])  # noqa: S603
    assert supervisor.wait(timeout=20) == 0
    identities = native.read_record(info_file)
    root, child = identities["root"], identities["child"]
    if release:
        assert native._matching_process(root) is not None
        assert native._matching_process(child) is not None
        native.LaunchedApp(native_plan, root, identities={child["pid"]: child}).stop()
    wait_stopped(root)
    wait_stopped(child)
