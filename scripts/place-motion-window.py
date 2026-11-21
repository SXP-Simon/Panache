"""Build and measure the Windows workbench on a verified physical display.

Use --drive for the complete benchmark. For A/B runs, start --exe mode before
flutter drive, using the same fresh --handshake path as PANACHE_MOTION_MONITOR_FILE. To attach to an already running test
instance, explicitly pass its --pid as well as its executable path.
"""

import argparse
import ctypes as c
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from ctypes import wintypes as w
from pathlib import Path


class MonitorInfo(c.Structure):
    _fields_ = [
        ("size", w.DWORD),
        ("monitor", w.RECT),
        ("work", w.RECT),
        ("flags", w.DWORD),
        ("device", w.WCHAR * 32),
    ]


class DisplayMode(c.Structure):
    _fields_ = [
        ("device", w.WCHAR * 32),
        ("spec", w.WORD),
        ("driver", w.WORD),
        ("size", w.WORD),
        ("extra", w.WORD),
        ("fields", w.DWORD),
        ("position_and_orientation", c.c_byte * 16),
        ("color", w.SHORT),
        ("duplex", w.SHORT),
        ("y_resolution", w.SHORT),
        ("tt_option", w.SHORT),
        ("collate", w.SHORT),
        ("form", w.WCHAR * 32),
        ("log_pixels", w.WORD),
        ("bits_per_pixel", w.DWORD),
        ("width", w.DWORD),
        ("height", w.DWORD),
        ("display_flags", w.DWORD),
        ("frequency", w.DWORD),
        ("remaining_fields", w.DWORD * 8),
    ]


def rect(value):
    return [value.left, value.top, value.right, value.bottom]


def checked(value):
    if not value:
        raise c.WinError(c.get_last_error())
    return value


def api(dll, name, result, *args):
    fn = getattr(dll, name)
    fn.argtypes, fn.restype = args, result
    return fn


class Desktop:
    def __init__(self):
        user = c.WinDLL("user32", use_last_error=True)
        kernel = c.WinDLL("kernel32", use_last_error=True)
        self.monitor_callback = c.WINFUNCTYPE(
            w.BOOL, w.HANDLE, w.HDC, c.POINTER(w.RECT), w.LPARAM
        )
        self.window_callback = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
        self.enum_monitors = api(
            user,
            "EnumDisplayMonitors",
            w.BOOL,
            w.HDC,
            c.POINTER(w.RECT),
            self.monitor_callback,
            w.LPARAM,
        )
        self.info = api(
            user, "GetMonitorInfoW", w.BOOL, w.HANDLE, c.POINTER(MonitorInfo)
        )
        self.mode = api(
            user,
            "EnumDisplaySettingsW",
            w.BOOL,
            w.LPCWSTR,
            w.DWORD,
            c.POINTER(DisplayMode),
        )
        self.enum_windows = api(
            user, "EnumWindows", w.BOOL, self.window_callback, w.LPARAM
        )
        self.class_name = api(user, "GetClassNameW", c.c_int, w.HWND, w.LPWSTR, c.c_int)
        self.visible = api(user, "IsWindowVisible", w.BOOL, w.HWND)
        self.pid = api(
            user, "GetWindowThreadProcessId", w.DWORD, w.HWND, c.POINTER(w.DWORD)
        )
        self.open_process = api(
            kernel, "OpenProcess", w.HANDLE, w.DWORD, w.BOOL, w.DWORD
        )
        self.close = api(kernel, "CloseHandle", w.BOOL, w.HANDLE)
        self.image = api(
            kernel,
            "QueryFullProcessImageNameW",
            w.BOOL,
            w.HANDLE,
            w.DWORD,
            w.LPWSTR,
            c.POINTER(w.DWORD),
        )
        self.times = api(
            kernel, "GetProcessTimes", w.BOOL, w.HANDLE, *([c.POINTER(w.FILETIME)] * 4)
        )
        self.dpi = api(user, "GetDpiForWindow", w.UINT, w.HWND)
        self.monitor = api(user, "MonitorFromWindow", w.HANDLE, w.HWND, w.DWORD)
        self.window_rect = api(user, "GetWindowRect", w.BOOL, w.HWND, c.POINTER(w.RECT))
        self.client_rect = api(user, "GetClientRect", w.BOOL, w.HWND, c.POINTER(w.RECT))
        self.move = api(
            user,
            "SetWindowPos",
            w.BOOL,
            w.HWND,
            w.HWND,
            c.c_int,
            c.c_int,
            c.c_int,
            c.c_int,
            w.UINT,
        )
        checked(api(user, "SetThreadDpiAwarenessContext", w.HANDLE, w.HANDLE)(-4))

    def monitors(self):
        handles = []
        checked(
            self.enum_monitors(
                None,
                None,
                self.monitor_callback(lambda h, *_: handles.append(h) or 1),
                0,
            )
        )
        return [(h, self.monitor_record(h)) for h in handles]

    def monitor_record(self, handle):
        info = MonitorInfo(size=c.sizeof(MonitorInfo))
        checked(self.info(handle, c.byref(info)))
        mode = DisplayMode(size=c.sizeof(DisplayMode))
        checked(self.mode(info.device, 0xFFFFFFFF, c.byref(mode)))
        return {
            "device": info.device,
            "hz": mode.frequency,
            "work_area": rect(info.work),
            "monitor_rect": rect(info.monitor),
            "primary": bool(info.flags & 1),
        }

    def process(self, hwnd):
        pid = w.DWORD()
        if not self.pid(hwnd, c.byref(pid)):
            return None
        handle = self.open_process(0x1000, False, pid.value)
        if not handle:
            return None
        try:
            path = c.create_unicode_buffer(32768)
            size = w.DWORD(len(path))
            times = [w.FILETIME() for _ in range(4)]
            if not self.image(handle, 0, path, c.byref(size)) or not self.times(
                handle, *(c.byref(t) for t in times)
            ):
                return None
            created = (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime
            return pid.value, Path(path.value), created
        finally:
            self.close(handle)

    def windows(self):
        handles = []
        checked(
            self.enum_windows(
                self.window_callback(lambda h, _: handles.append(h) or 1), 0
            )
        )
        for hwnd in handles:
            name = c.create_unicode_buffer(128)
            if (
                self.visible(hwnd)
                and self.class_name(hwnd, name, len(name))
                and name.value == "FLUTTER_RUNNER_WIN32_WINDOW"
            ):
                yield hwnd

    def bounds(self, fn, hwnd):
        result = w.RECT()
        checked(fn(hwnd, c.byref(result)))
        return rect(result)


class DriverJob:
    """Keep the build, driver and their descendants in one Windows job."""

    def __init__(self):
        kernel = c.WinDLL("kernel32", use_last_error=True)
        self.close = api(kernel, "CloseHandle", w.BOOL, w.HANDLE)
        self.open = api(kernel, "OpenProcess", w.HANDLE, w.DWORD, w.BOOL, w.DWORD)
        self.assign = api(
            kernel, "AssignProcessToJobObject", w.BOOL, w.HANDLE, w.HANDLE
        )
        self.includes = api(
            kernel, "IsProcessInJob", w.BOOL, w.HANDLE, w.HANDLE, c.POINTER(w.BOOL)
        )
        self.terminate = api(kernel, "TerminateJobObject", w.BOOL, w.HANDLE, w.UINT)
        self.handle = checked(
            api(kernel, "CreateJobObjectW", w.HANDLE, c.c_void_p, w.LPCWSTR)(None, None)
        )

    def start(self, command, cwd, env):
        # Wait for job assignment before spawning flutter or any descendants.
        launcher = (
            "import subprocess,sys; "
            "sys.exit(subprocess.call(sys.argv[1:]) if sys.stdin.buffer.read(1) == b'1' else 1)"
        )
        child = subprocess.Popen(
            [sys.executable, "-c", launcher, *command],
            cwd=cwd,
            env=env,
            stdin=subprocess.PIPE,
        )
        try:
            process = checked(
                self.open(0x101, False, child.pid)
            )  # TERMINATE | SET_QUOTA
            try:
                checked(self.assign(self.handle, process))
            finally:
                self.close(process)
            child.stdin.write(b"1")
            child.stdin.close()
            return child
        except BaseException:
            child.kill()
            child.wait()
            raise

    def owns(self, pid):
        process = self.open(0x1000, False, pid)
        if not process:
            return False
        try:
            included = w.BOOL()
            checked(self.includes(process, self.handle, c.byref(included)))
            return bool(included.value)
        finally:
            self.close(process)

    def finish(self):
        try:
            checked(self.terminate(self.handle, 1))
        finally:
            self.close(self.handle)


def place(args, desktop, target, record, start_filetime, driver=None, job=None):
    print(f"Waiting for {args.exe} on {record['device']} at {args.hz} Hz", flush=True)
    deadline = time.monotonic() + args.timeout
    candidates = []
    while time.monotonic() < deadline:
        if driver is not None and driver.poll() is not None:
            raise RuntimeError(
                f"Flutter drive exited before monitor verification ({driver.returncode})"
            )
        candidates = []
        for hwnd in desktop.windows():
            process = desktop.process(hwnd)
            if (
                process
                and process[1] == args.exe
                and (
                    process[0] == args.pid if args.pid else process[2] >= start_filetime
                )
            ) and (job is None or job.owns(process[0])):
                candidates.append((hwnd, process))
        if candidates:
            break
        time.sleep(0.08)
    if len(candidates) != 1:
        raise RuntimeError(f"Expected one matching test window, got {len(candidates)}")
    hwnd, process = candidates[0]
    x, y, r, b = record["work_area"]
    # Transfer first so WM_DPICHANGED is delivered before sizing the client.
    # SWP_NOZORDER | SWP_NOACTIVATE keeps the existing foreground window.
    if desktop.process(hwnd) != process:
        raise RuntimeError("Window owner changed")
    checked(
        desktop.move(
            hwnd,
            None,
            x + 8,
            y + 8,
            min(args.width, r - x - 16),
            min(args.height, b - y - 16),
            0x14,
        )
    )
    stable = 0
    while time.monotonic() < deadline:
        if desktop.process(hwnd) != process:
            raise RuntimeError("Window owner changed")
        dpi = checked(desktop.dpi(hwnd))
        outer = desktop.bounds(desktop.window_rect, hwnd)
        client = desktop.bounds(desktop.client_rect, hwnd)
        wpx, hpx = round(args.width * dpi / 96), round(args.height * dpi / 96)
        ow = wpx + outer[2] - outer[0] - client[2]
        oh = hpx + outer[3] - outer[1] - client[3]
        if ow > r - x or oh > b - y:
            raise ValueError(
                f"Requested client {wpx}x{hpx} at {dpi} DPI does not fit work area {record['work_area']}"
            )
        full = x <= outer[0] and y <= outer[1] and outer[2] <= r and outer[3] <= b
        if desktop.monitor(hwnd, 0) == target and full and client[2:] == [wpx, hpx]:
            stable += 1
            if stable >= 3:
                break
        else:
            stable = 0
            checked(
                desktop.move(
                    hwnd,
                    None,
                    x + (r - x - ow) // 2,
                    y + (b - y - oh) // 2,
                    ow,
                    oh,
                    0x14,
                )
            )
        time.sleep(0.08)
    else:
        raise TimeoutError("Window DPI, client size or monitor did not settle")
    verified = desktop.monitor_record(checked(desktop.monitor(hwnd, 0)))
    if verified != record or desktop.process(hwnd) != process:
        raise RuntimeError(
            "Display configuration or window ownership changed during verification"
        )
    result = dict(
        **verified,
        pid=process[0],
        exe=str(process[1]),
        hwnd=hwnd,
        dpi=dpi,
        client_px=client[2:],
        client_logical=[args.width, args.height],
        window_rect=outer,
    )
    # Fresh files only: Windows rename fails rather than overwriting another handshake.
    temp = args.handshake.with_name(args.handshake.name + f".{os.getpid()}.tmp")
    temp.write_text(json.dumps(result, indent=2), encoding="utf-8")
    temp.rename(args.handshake)
    print(json.dumps(result), flush=True)


def drive(args, desktop, target, record):
    app = Path(__file__).resolve().parents[1] / "app"
    flutter = shutil.which(args.flutter)
    if not flutter:
        raise FileNotFoundError(f"Flutter executable not found: {args.flutter}")
    arch = (
        os.environ.get("PROCESSOR_ARCHITEW6432") or os.environ["PROCESSOR_ARCHITECTURE"]
    )
    runner = "arm64" if arch.upper() == "ARM64" else "x64"
    args.exe = (
        app
        / "build"
        / "windows"
        / runner
        / "runner"
        / "Profile"
        / "handwriting_app.exe"
    )
    target_flag = "--target=integration_test/workbench_motion_profile_test.dart"
    passes = f"--dart-define=MOTION_PROFILE_PASSES={args.passes}"
    with tempfile.TemporaryDirectory(prefix="panache-motion-") as directory:
        args.handshake = Path(directory) / "monitor.json"
        env = dict(os.environ, PANACHE_MOTION_MONITOR_FILE=str(args.handshake))
        job = DriverJob()
        try:
            build = job.start(
                [flutter, "build", "windows", "--profile", passes, target_flag],
                app,
                env,
            )
            status = build.wait()
            if status:
                raise SystemExit(status)
            if not args.exe.is_file():
                raise FileNotFoundError(f"Profile executable missing: {args.exe}")
            start = time.time_ns() // 100 + 116444736000000000
            process = job.start(
                [
                    flutter,
                    "drive",
                    "--profile",
                    "-d",
                    "windows",
                    "--no-pub",
                    f"--use-application-binary={args.exe}",
                    passes,
                    target_flag,
                    "--driver=test_driver/motion_profile.dart",
                ],
                app,
                env,
            )
            place(args, desktop, target, record, start, process, job)
            status = process.wait(timeout=max(240, args.passes * 30))
            if status:
                raise SystemExit(status)
            print(f"Report: {app / 'build' / 'workbench_motion.json'}")
        finally:
            job.finish()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument(
        "--drive",
        action="store_true",
        help="Build and run the benchmark on the selected monitor.",
    )
    modes.add_argument(
        "--list",
        action="store_true",
        help="Read display modes without moving a window.",
    )
    parser.add_argument(
        "--flutter",
        default="flutter",
        help="Flutter executable on PATH or SDK bin/flutter.bat path.",
    )
    parser.add_argument(
        "--passes", type=int, default=4, help="Measured repetitions after warm-up."
    )
    parser.add_argument("--exe", type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--hz", type=int, default=165)
    parser.add_argument(
        "--device", help="Select a specific display when several match --hz."
    )
    parser.add_argument(
        "--handshake", type=Path, default=os.environ.get("PANACHE_MOTION_MONITOR_FILE")
    )
    parser.add_argument(
        "--width", type=int, default=960, help="Client width in logical pixels."
    )
    parser.add_argument(
        "--height", type=int, default=650, help="Client height in logical pixels."
    )
    parser.add_argument("--timeout", type=int, default=240)
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("Windows is required")
    start_filetime = time.time_ns() // 100 + 116444736000000000
    desktop = Desktop()
    monitors = desktop.monitors()
    if args.list:
        print(json.dumps([m for _, m in monitors], indent=2))
        return
    if min(args.width, args.height, args.hz, args.timeout, args.passes) <= 0:
        parser.error("Dimensions/rate/passes/timeout must be positive")
    matches = [
        (h, m)
        for h, m in monitors
        if m["hz"] == args.hz and (args.device is None or m["device"] == args.device)
    ]
    if len(matches) != 1:
        parser.error(
            f"Expected one matching monitor, got {len(matches)}; use --list and --device"
        )
    target, record = matches[0]
    if args.drive:
        if args.pid or args.exe:
            parser.error("--drive builds its own executable; omit --exe and --pid")
        drive(args, desktop, target, record)
        return
    if not args.exe or not args.handshake:
        parser.error("Use --drive, or provide --exe and --handshake")
    args.exe = args.exe.resolve()
    if args.handshake.exists():
        parser.error("Handshake already exists; use a fresh filename for each run")
    args.handshake.parent.mkdir(parents=True, exist_ok=True)
    place(args, desktop, target, record, start_filetime)


if __name__ == "__main__":
    main()
