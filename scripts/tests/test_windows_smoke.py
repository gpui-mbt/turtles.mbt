"""Regression tests for exact helper identity in the Windows smoke test."""

from __future__ import annotations

import _thread
import ctypes
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from ctypes import wintypes
from unittest.mock import patch

from scripts import verify_moon_profile
from scripts import windows_smoke


PYTHON = r"C:\tools\python.exe"
TOKEN = "a5dbe1f194e34fe6878f6b00a8277e04"


def process(pid: int, executable: str, command_line: str) -> dict:
    return {
        "ProcessId": pid,
        "Name": "python.exe",
        "ExecutablePath": executable,
        "CommandLine": command_line,
        "CreationDate": "20261010000000.000000+000",
    }


class WindowsSmokeProcessTests(unittest.TestCase):
    def test_matches_only_the_expected_executable_and_attempt_token(self) -> None:
        helper = process(
            501,
            PYTHON,
            f'"{PYTHON}" scripts/windows_smoke.py --persistent-child {TOKEN}',
        )
        other_attempt = process(
            502,
            PYTHON,
            f'"{PYTHON}" scripts/windows_smoke.py --persistent-child other-token',
        )
        other_executable = process(
            503,
            r"C:\other\python.exe",
            fr'"C:\other\python.exe" scripts/windows_smoke.py --persistent-child {TOKEN}',
        )

        matches = windows_smoke.persistent_helper_identities(
            [helper, other_attempt, other_executable], PYTHON, TOKEN
        )

        self.assertEqual(matches, {windows_smoke.process_identity(helper)})

    def test_executable_matching_is_case_insensitive(self) -> None:
        helper = process(
            504,
            r"c:\TOOLS\PYTHON.EXE",
            fr'"c:\TOOLS\PYTHON.EXE" --persistent-child {TOKEN}',
        )

        matches = windows_smoke.persistent_helper_identities(
            [helper], PYTHON, TOKEN
        )

        self.assertEqual(matches, {windows_smoke.process_identity(helper)})


@unittest.skipUnless(os.name == "nt", "Windows Job Object contract tests")
class WindowsVerifierJobTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="verify-job-")
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def descendant_command(self, ready: Path, survived: Path) -> tuple[str, str]:
        child = (
            "from pathlib import Path; import time; "
            f"Path({str(ready)!r}).write_text('ready'); "
            "time.sleep(1.3); "
            f"Path({str(survived)!r}).write_text('survived')"
        )
        parent = "\n".join(
            (
                "import subprocess,sys,time",
                "from pathlib import Path",
                "subprocess.Popen([sys.executable, '-c', sys.argv[1]])",
                "ready=Path(sys.argv[2])",
                "deadline=time.monotonic()+3",
                "while not ready.exists() and time.monotonic()<deadline:",
                "    time.sleep(.01)",
                "time.sleep(20)",
            )
        )
        return parent, child

    def test_timeout_terminates_owned_descendants(self) -> None:
        ready = self.root / "child-ready.txt"
        survived = self.root / "child-survived.txt"
        parent, child = self.descendant_command(ready, survived)
        report = verify_moon_profile.run(
            [sys.executable, "-c", parent, child, str(ready)],
            self.root,
            {},
            self.root / "descendant-timeout.log",
            0.7,
        )
        self.assertTrue(report["timed_out"])
        self.assertTrue(ready.exists(), "the test child must actually start")
        time.sleep(1.6)
        self.assertFalse(
            survived.exists(),
            "a timed-out verifier command must not leave its descendant running",
        )

    def test_cancellation_terminates_owned_descendants(self) -> None:
        ready = self.root / "cancel-child-ready.txt"
        survived = self.root / "cancel-child-survived.txt"
        parent, child = self.descendant_command(ready, survived)
        original_wait = verify_moon_profile.WindowsJobProcess.wait
        cancellation_pending = True

        def cancel_after_child_starts(process, timeout=None):
            nonlocal cancellation_pending
            if cancellation_pending:
                deadline = time.monotonic() + 3
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                cancellation_pending = False
                raise KeyboardInterrupt
            return original_wait(process, timeout)

        with patch.object(
            verify_moon_profile.WindowsJobProcess,
            "wait",
            cancel_after_child_starts,
        ):
            with self.assertRaises(KeyboardInterrupt):
                verify_moon_profile.run(
                    [sys.executable, "-c", parent, child, str(ready)],
                    self.root,
                    {},
                    self.root / "descendant-cancel.log",
                    10,
                )
        self.assertTrue(ready.exists(), "the test child must actually start")
        time.sleep(1.6)
        self.assertFalse(
            survived.exists(),
            "cancellation must not leave its owned descendant running",
        )

    def test_real_keyboard_interrupt_is_prompt_and_terminates_descendants(self) -> None:
        ready = self.root / "interrupt-child-ready.txt"
        survived = self.root / "interrupt-child-survived.txt"
        parent, child = self.descendant_command(ready, survived)
        interrupt_sent = threading.Event()

        def interrupt_after_child_starts() -> None:
            deadline = time.monotonic() + 3
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            if ready.exists():
                time.sleep(0.15)
                _thread.interrupt_main()
                interrupt_sent.set()

        interrupter = threading.Thread(
            target=interrupt_after_child_starts,
            name="verifier-test-interrupter",
            daemon=True,
        )
        interrupter.start()
        started = time.monotonic()
        with self.assertRaises(KeyboardInterrupt):
            verify_moon_profile.run(
                [sys.executable, "-c", parent, child, str(ready)],
                self.root,
                {},
                self.root / "descendant-interrupt.log",
                10,
            )
        elapsed = time.monotonic() - started
        interrupter.join(timeout=1)

        self.assertTrue(interrupt_sent.is_set(), "interrupt thread must deliver SIGINT")
        self.assertTrue(ready.exists(), "the test child must actually start")
        self.assertLess(elapsed, 3, "native waits must return promptly to Python signals")
        time.sleep(1.6)
        self.assertFalse(
            survived.exists(),
            "a real KeyboardInterrupt must not leave its owned descendant running",
        )

    def test_normal_completion_drains_descendants_after_parent_exits(self) -> None:
        ready = self.root / "exit-child-ready.txt"
        survived = self.root / "exit-child-survived.txt"
        parent, child = self.descendant_command(ready, survived)
        parent = parent.removesuffix("time.sleep(20)")
        report = verify_moon_profile.run(
            [sys.executable, "-c", parent, child, str(ready)],
            self.root,
            {},
            self.root / "descendant-exit.log",
            10,
        )
        self.assertFalse(report["timed_out"])
        self.assertEqual(report["exit_code"], 0)
        self.assertTrue(ready.exists(), "the test child must actually start")
        time.sleep(1.6)
        self.assertFalse(
            survived.exists(),
            "normal completion must drain descendants after the initial process exits",
        )

    def test_launcher_uses_unicode_working_and_log_paths(self) -> None:
        working = self.root / "日本語 作業場所"
        working.mkdir()
        log = self.root / "日本語 記録.log"
        report = verify_moon_profile.run(
            [sys.executable, "-c", "print('utf16-path-ok')"],
            working,
            {},
            log,
            10,
        )
        self.assertFalse(report["timed_out"])
        self.assertEqual(report["exit_code"], 0)
        self.assertIn("utf16-path-ok", log.read_text(encoding="utf-8"))

    def test_failed_suspended_launches_close_the_process_handle(self) -> None:
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.GetHandleInformation.argtypes = [
            wintypes.HANDLE,
            ctypes.POINTER(wintypes.DWORD),
        ]
        kernel.GetHandleInformation.restype = wintypes.BOOL
        original_configure = verify_moon_profile.WindowsJobProcess._configure_kernel
        original_abort = verify_moon_profile.WindowsJobProcess._abort_suspended

        for failure in ("assignment", "resume"):
            with self.subTest(failure=failure):
                marker = self.root / f"{failure}-failure-child-ran.txt"
                code = f"from pathlib import Path; Path({str(marker)!r}).write_text('ran')"
                process_handles = []

                def configure(process):
                    original_configure(process)
                    if failure == "assignment":
                        def fail_assignment(_job, _child):
                            ctypes.set_last_error(5)
                            return False

                        process._kernel.AssignProcessToJobObject = fail_assignment
                    else:
                        def fail_resume(_thread):
                            ctypes.set_last_error(5)
                            return 0xFFFFFFFF

                        process._kernel.ResumeThread = fail_resume

                def record_abort(process, child_handle, job_handle):
                    process_handles.append(child_handle)
                    return original_abort(process, child_handle, job_handle)

                with patch.object(
                    verify_moon_profile.WindowsJobProcess,
                    "_configure_kernel",
                    configure,
                ), patch.object(
                    verify_moon_profile.WindowsJobProcess,
                    "_abort_suspended",
                    record_abort,
                ):
                    with (self.root / f"{failure}-failure.log").open("w") as stream:
                        with self.assertRaises(OSError):
                            verify_moon_profile.WindowsJobProcess(
                                [sys.executable, "-c", code],
                                self.root,
                                os.environ.copy(),
                                stream,
                            )

                self.assertEqual(len(process_handles), 1)
                flags = wintypes.DWORD()
                self.assertFalse(
                    kernel.GetHandleInformation(process_handles[0], ctypes.byref(flags)),
                    "a failed suspended launch must close its process handle",
                )
                self.assertFalse(marker.exists(), "a failed launch must not resume the child")

if __name__ == "__main__":
    unittest.main()
