#!/usr/bin/env python3
"""Verify Darwin fallback timeout and signal cleanup kill same-group children."""

from __future__ import annotations

import json
import os
import shutil
import signal
import shlex
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


def run(command: list[str], *, env: dict[str, str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def assert_success(result: subprocess.CompletedProcess[str], label: str) -> None:
    if result.returncode != 0:
        raise SystemExit(
            f"{label} exited {result.returncode}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )


def child_pid_from_ready_file(ready: Path, token: str) -> int:
    with ready.open(encoding="utf-8") as handle:
        child_pid = int(handle.readline().strip())
        child_token = handle.readline().strip()
    if child_token != token:
        raise SystemExit("the timeout fixture child token did not match")
    return child_pid


def child_is_running(child_pid: int, token: str) -> bool:
    process = subprocess.run(
        ["/bin/ps", "-p", str(child_pid), "-o", "stat=,command="],
        capture_output=True,
        text=True,
        check=False,
    )
    row = process.stdout.strip()
    return bool(row and not row.split(None, 1)[0].startswith("Z") and token in row)


def wait_for_child_exit(child_pid: int, token: str, label: str) -> None:
    # The PID can be recycled after the helper exits, so a missing process, a
    # different command line, or a zombie all mean this fixture child is done.
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if not child_is_running(child_pid, token):
            print(label)
            return
        time.sleep(0.05)
    raise SystemExit(
        f"Darwin fallback left the same-group child running: pid={child_pid} token={token}"
    )


def process_group(pid: int) -> int | None:
    process = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "pgid="],
        capture_output=True,
        text=True,
        check=False,
    )
    value = process.stdout.strip()
    return int(value) if value else None


def process_is_live(pid: int) -> bool:
    process = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "stat="],
        capture_output=True,
        text=True,
        check=False,
    )
    state = process.stdout.strip()
    return bool(state and not state.startswith("Z"))


def wait_for_pid_exit(pid: int, label: str) -> None:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if not process_is_live(pid):
            print(label)
            return
        time.sleep(0.05)
    raise SystemExit(f"Darwin supervisor left process running: pid={pid}")


def verify_signal_cancellation(executable: Path, environment: dict[str, str]) -> None:
    """Run the hidden entry directly so its exact PID owns the signal test."""
    with tempfile.TemporaryDirectory(prefix="turtles-darwin-cancel-") as temp:
        work = Path(temp)
        fake_bin = work / "bin"
        fake_bin.mkdir()
        ready = work / "ready"
        fake_moon = fake_bin / "moon"
        fake_moon.write_text(
            "#!/bin/sh\n"
            "/bin/sleep 60 &\n"
            "child=$!\n"
            f"printf '%s\\n%s\\n' \"$$\" \"$child\" > {shlex.quote(str(ready))}\n"
            "wait \"$child\"\n",
            encoding="utf-8",
        )
        fake_moon.chmod(0o755)
        signal_environment = environment.copy()
        signal_environment["PATH"] = f"{fake_bin}:{SYSTEM_PATH}"
        supervisor = subprocess.Popen(
            [
                str(executable),
                "--__turtles_darwin_timeout_supervisor",
                "30000",
                "--",
                "moon",
                "fake-command",
            ],
            cwd=ROOT,
            env=signal_environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        moon_pid: int | None = None
        child_pid: int | None = None
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and not ready.exists():
                if supervisor.poll() is not None:
                    output, _ = supervisor.communicate()
                    raise SystemExit(
                        "hidden supervisor exited before its fake moon started\n"
                        f"stdout:\n{output}"
                    )
                time.sleep(0.01)
            if not ready.exists():
                raise SystemExit("hidden supervisor did not start its fake moon")
            lines = ready.read_text(encoding="utf-8").splitlines()
            moon_pid, child_pid = int(lines[0]), int(lines[1])
            if process_group(moon_pid) != moon_pid or process_group(child_pid) != moon_pid:
                raise SystemExit("fake moon and helper did not share the owned process group")

            os.kill(supervisor.pid, signal.SIGTERM)
            try:
                output, _ = supervisor.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                raise SystemExit("hidden supervisor ignored SIGTERM")
            if supervisor.returncode != 143:
                raise SystemExit(
                    f"hidden supervisor returned {supervisor.returncode} after SIGTERM; "
                    f"expected 143\nstdout:\n{output}"
                )
            wait_for_pid_exit(moon_pid, "Darwin supervisor SIGTERM stopped its command")
            wait_for_pid_exit(child_pid, "Darwin supervisor SIGTERM stopped its descendant")
        finally:
            if moon_pid is not None:
                try:
                    os.killpg(moon_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if supervisor.poll() is None:
                supervisor.kill()
                supervisor.wait()


def main() -> None:
    if sys.platform != "darwin":
        print("Skipping Darwin process-group smoke test on a non-Darwin host")
        return

    moon = shutil.which("moon")
    if moon is None:
        raise SystemExit("moon must be available for this smoke test")
    fallback_path = f"{Path(moon).resolve().parent}:{SYSTEM_PATH}"
    python = shutil.which("python3", path=fallback_path)
    if python is None:
        raise SystemExit("python3 must be available on the restricted fallback PATH")
    environment = os.environ.copy()
    environment["PATH"] = fallback_path
    if shutil.which("timeout", path=fallback_path) or shutil.which(
        "gtimeout", path=fallback_path
    ):
        raise SystemExit("the fallback PATH unexpectedly contains GNU timeout")

    # The runner's native whitebox test binary has its own generated argument
    # parser. This filtered test launches the private supervisor from inside
    # that binary while it checks a pristine Moon baseline; the C constructor
    # must dispatch before the generated parser sees the private arguments.
    test_result = run(
        [
            moon,
            "test",
            "cmd/turtles/runner_wbtest.mbt",
            "--target",
            "native",
            "--filter",
            "native target selects native-only tests for classification",
            "--deny-warn",
        ],
        env=environment,
        cwd=ROOT,
    )
    assert_success(test_result, "no-timeout runner test-driver integration")

    test_driver = ROOT / "_build" / "native" / "debug" / "test" / "cmd" / "turtles" / "turtles.whitebox_test.exe"
    if not test_driver.is_file():
        raise SystemExit(f"native turtles whitebox test driver not found at {test_driver}")
    driver_command = [
        str(test_driver),
        "--__turtles_darwin_timeout_supervisor",
        "3000",
        "--",
        "moon",
        "--version",
    ]
    driver_result = run(driver_command, env=environment, cwd=ROOT)
    assert_success(driver_result, "generated test-driver supervisor entry")
    if "moon " not in driver_result.stdout:
        raise SystemExit("generated test-driver supervisor did not preserve moon output")
    invalid_result = run(
        [
            str(test_driver),
            "--__turtles_darwin_timeout_supervisor",
            "0",
            "--",
            "moon",
            "--version",
        ],
        env=environment,
        cwd=ROOT,
    )
    if invalid_result.returncode != 125 or "invalid supervisor timeout" not in invalid_result.stderr:
        raise SystemExit(
            "generated test-driver supervisor did not reject an invalid timeout "
            f"deterministically (exit {invalid_result.returncode})\n"
            f"stdout:\n{invalid_result.stdout}\nstderr:\n{invalid_result.stderr}"
        )

    with tempfile.TemporaryDirectory(prefix="turtles-darwin-timeout-") as temp:
        work = Path(temp)
        helper = work / "persistent_child.py"
        helper.write_text(
            """import os, sys, time
if len(sys.argv) == 4 and sys.argv[1] == '--persistent-child':
    token, ready = sys.argv[2], sys.argv[3]
    with open(ready, 'w', encoding='utf-8') as f:
        f.write(f'{os.getpid()}\\n{token}\\n')
    while True:
        time.sleep(1)
""",
            encoding="utf-8",
        )

        # Warm the fixture build so its own compilation cannot consume the
        # short timeout intended for the deliberately sleeping mutant.
        for subcommand in ("check", "test"):
            result = run(
                [moon, subcommand, "--target", "native"],
                env=environment,
                cwd=ROOT / "fixtures" / "timeout",
            )
            assert_success(result, f"timeout fixture moon {subcommand}")

        ready = work / "child.ready"
        token = f"turtles-{uuid.uuid4().hex}"
        environment.update(
            {
                "TURTLES_TIMEOUT_HELPER": python,
                "TURTLES_TIMEOUT_HELPER_SCRIPT": str(helper),
                "TURTLES_TIMEOUT_HELPER_TOKEN": token,
                "TURTLES_TIMEOUT_HELPER_READY": str(ready),
            }
        )
        report = work / "timeout-report.json"
        output_dir = work / "output"
        command = [
            moon,
            "run",
            "cmd/turtles",
            "--",
            "--dir",
            str(ROOT / "fixtures" / "timeout"),
            "--timeout",
            "5",
            "--output-dir",
            str(output_dir),
            "--json",
            str(report),
        ]
        result = run(command, env=environment, cwd=ROOT)
        child_pid: int | None = None
        if ready.exists():
            child_pid = child_pid_from_ready_file(ready, token)

        try:
            if result.returncode != 1:
                raise SystemExit(
                    f"timed-out mutation run exited {result.returncode}, expected 1\n"
                    f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
                )
            if child_pid is None:
                raise SystemExit("the timeout fixture did not start its persistent child")

            with report.open(encoding="utf-8") as handle:
                parsed = json.load(handle)
            if parsed["summary"]["timeout"] != 1:
                raise SystemExit(f"expected one timeout, got {parsed['summary']}")
            if not any(mutant["outcome"] == "TIMEOUT" for mutant in parsed["mutants"]):
                raise SystemExit("the descendant regression was not classified as TIMEOUT")

            wait_for_child_exit(
                child_pid,
                token,
                "Darwin fallback timeout terminated its descendant group",
            )
        finally:
            if child_pid is not None:
                process = subprocess.run(
                    ["/bin/ps", "-p", str(child_pid), "-o", "stat=,command="],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                row = process.stdout.strip()
                if row and not row.split(None, 1)[0].startswith("Z") and token in row:
                    os.kill(child_pid, 9)
        build = run([moon, "build", "--target", "native"], env=environment, cwd=ROOT)
        assert_success(build, "native turtles build for signal smoke test")
        executable = ROOT / "_build" / "native" / "debug" / "build" / "cmd" / "turtles" / "turtles.exe"
        if not executable.is_file():
            raise SystemExit(f"native turtles executable not found at {executable}")
        verify_signal_cancellation(executable, environment)


if __name__ == "__main__":
    main()
