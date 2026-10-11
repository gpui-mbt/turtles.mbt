#!/usr/bin/env python3
"""Exercise turtles' nested native subprocesses and fixtures on Windows."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import ctypes
from ctypes import wintypes
import uuid


ROOT = Path(__file__).resolve().parents[1]


ProcessIdentity = tuple[int, str, str, str, str]

PROCESS_TERMINATE = 0x0001
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
SYNCHRONIZE = 0x00100000
WAIT_OBJECT_0 = 0
WAIT_TIMEOUT = 258
ERROR_INVALID_PARAMETER = 87


class FILETIME(ctypes.Structure):
    _fields_ = [("dwLowDateTime", wintypes.DWORD), ("dwHighDateTime", wintypes.DWORD)]


def kernel32() -> ctypes.WinDLL:
    return ctypes.WinDLL("kernel32", use_last_error=True)


def process_creation_ticks(handle: int) -> int:
    create = FILETIME()
    exit_time = FILETIME()
    kernel = kernel32()
    kernel.GetProcessTimes.argtypes = [
        wintypes.HANDLE,
        ctypes.POINTER(FILETIME),
        ctypes.POINTER(FILETIME),
        ctypes.POINTER(FILETIME),
        ctypes.POINTER(FILETIME),
    ]
    kernel.GetProcessTimes.restype = wintypes.BOOL
    if not kernel.GetProcessTimes(
        handle,
        ctypes.byref(create),
        ctypes.byref(exit_time),
        ctypes.byref(FILETIME()),
        ctypes.byref(FILETIME()),
    ):
        raise ctypes.WinError(ctypes.get_last_error())
    return (create.dwHighDateTime << 32) | create.dwLowDateTime


def run_persistent_child(token: str, ready_path: Path) -> int:
    """Write a stable process identity, then remain alive for timeout checks."""
    kernel = kernel32()
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    process = kernel.GetCurrentProcess()
    ticks = process_creation_ticks(process)
    ready_path.write_text(f"{os.getpid()} {token} {ticks}\n", encoding="ascii")
    while True:
        time.sleep(60)


def cleanup_persistent_child(ready_path: Path, expected_token: str) -> None:
    """Terminate only the exact helper identity minted by this smoke attempt."""
    if not ready_path.exists():
        return
    fields = ready_path.read_text(encoding="ascii").split()
    if len(fields) != 3 or fields[1] != expected_token:
        raise RuntimeError("timeout helper identity file did not match this attempt")
    pid, _, expected_creation = int(fields[0]), fields[1], int(fields[2])

    kernel = kernel32()
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.GetProcessTimes.argtypes = [
        wintypes.HANDLE,
        ctypes.POINTER(FILETIME),
        ctypes.POINTER(FILETIME),
        ctypes.POINTER(FILETIME),
        ctypes.POINTER(FILETIME),
    ]
    kernel.GetProcessTimes.restype = wintypes.BOOL
    kernel.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
    kernel.TerminateProcess.restype = wintypes.BOOL
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.WaitForSingleObject.restype = wintypes.DWORD
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL

    handle = kernel.OpenProcess(
        PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
        False,
        pid,
    )
    if not handle:
        error = ctypes.get_last_error()
        if error == ERROR_INVALID_PARAMETER:
            return  # Windows no longer has this PID.
        raise ctypes.WinError(error)
    try:
        if process_creation_ticks(handle) != expected_creation:
            return  # The PID was reused after the original helper exited.
        if kernel.WaitForSingleObject(handle, 0) == WAIT_OBJECT_0:
            return
        if not kernel.TerminateProcess(handle, 1):
            if kernel.WaitForSingleObject(handle, 0) == WAIT_OBJECT_0:
                return
            raise ctypes.WinError(ctypes.get_last_error())
        if kernel.WaitForSingleObject(handle, 10000) != WAIT_OBJECT_0:
            raise RuntimeError(f"could not clean up timeout helper PID {pid}")
    finally:
        kernel.CloseHandle(handle)


def process_environment(moon: str) -> dict[str, str]:
    """Keep nested `moon` commands on the same toolchain as the smoke runner."""
    env = os.environ.copy()
    moon_bin = str(Path(moon).resolve().parent)
    env["PATH"] = moon_bin + os.pathsep + env.get("PATH", "")
    return env


def run(
    executable: str, args: list[str], expected: int, label: str, env: dict[str, str]
) -> str:
    completed = subprocess.run(
        [executable, *args],
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=900,
        check=False,
    )
    if completed.returncode != expected:
        raise RuntimeError(
            f"{label}: expected exit {expected}, got {completed.returncode}\n"
            f"{completed.stdout}"
        )
    return completed.stdout


def read_report(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def mutant_key(mutant: dict) -> tuple:
    return tuple(
        mutant[key]
        for key in (
            "path",
            "line",
            "column",
            "original",
            "replacement",
            "outcome",
            "group",
        )
    )


def windows_processes(powershell: str) -> list[dict]:
    command = (
        "$ErrorActionPreference='Stop'; "
        "Get-CimInstance Win32_Process | "
        "Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine,CreationDate | "
        "ConvertTo-Json -Compress"
    )
    completed = subprocess.run(
        [powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=20,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"could not inspect Windows subprocesses: {completed.stderr}")
    parsed = json.loads(completed.stdout or "null")
    if parsed is None:
        return []
    return parsed if isinstance(parsed, list) else [parsed]


def process_identity(row: dict) -> ProcessIdentity:
    creation_date = str(row.get("CreationDate") or "")
    if not creation_date:
        raise RuntimeError("Windows process snapshot omitted CreationDate")
    return (
        int(row["ProcessId"]),
        str(row["Name"] or "").casefold(),
        str(row["ExecutablePath"] or "").casefold(),
        str(row["CommandLine"] or "").casefold(),
        creation_date,
    )


def persistent_helper_identities(
    processes: list[dict], expected_executable: str, token: str
) -> set[ProcessIdentity]:
    expected_executable = expected_executable.casefold()
    token = token.casefold()
    return {
        process_identity(row)
        for row in processes
        if str(row.get("ExecutablePath") or "").casefold() == expected_executable
        and token in str(row.get("CommandLine") or "").casefold()
    }


def run_timeout_smoke(
    turtles: str, moon: str, report: Path, env: dict[str, str]
) -> None:
    powershell = shutil.which("powershell.exe")
    if powershell is None:
        raise RuntimeError("powershell.exe is required for the Windows timeout check")

    expected_python = str(Path(sys.executable).resolve())
    helper_script = str(Path(__file__).resolve())
    output_dir = report.with_name(f"{report.stem}-output")
    for attempt in (1, 2):
        attempt_report = (
            report
            if attempt == 1
            else report.with_name(f"{report.stem}-iterate{report.suffix}")
        )
        command = [
            turtles, "--dir", "fixtures/timeout",
            "--target", "native", "--timeout", "30",
            "--fail-under", "1", "--iterate",
            "--output-dir", str(output_dir), "--json", str(attempt_report),
        ]
        token = uuid.uuid4().hex
        ready_path = report.with_name(f"{report.stem}-helper-{token}.txt")
        attempt_env = env.copy()
        attempt_env.update(
            {
                "TURTLES_TIMEOUT_HELPER": expected_python,
                "TURTLES_TIMEOUT_HELPER_SCRIPT": helper_script,
                "TURTLES_TIMEOUT_HELPER_TOKEN": token,
                "TURTLES_TIMEOUT_HELPER_READY": str(ready_path.resolve()),
            }
        )
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            env=attempt_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        seen_helper: set[ProcessIdentity] = set()
        deadline = time.monotonic() + 180
        output = ""
        try:
            while True:
                snapshot = windows_processes(powershell)
                seen_helper.update(
                    persistent_helper_identities(snapshot, expected_python, token)
                )
                if process.poll() is not None:
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError(
                        f"timeout fixture attempt {attempt} exceeded the 180-second smoke deadline"
                    )
                time.sleep(0.1)
            output, _ = process.communicate(timeout=30)
        except BaseException:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=30)
            cleanup_persistent_child(ready_path, token)
            raise
        try:
            if not ready_path.is_file():
                report_details = "not written"
                if attempt_report.is_file():
                    try:
                        report_details = json.dumps(
                            read_report(attempt_report).get("summary"), sort_keys=True
                        )
                    except (OSError, ValueError, TypeError) as exc:
                        report_details = f"unreadable: {exc}"
                raise RuntimeError(
                    f"timeout fixture attempt {attempt} did not start its tokenized helper "
                    f"(exit {process.returncode})\nCLI output:\n{output.rstrip()}\n"
                    f"report summary: {report_details}"
                )
            fields = ready_path.read_text(encoding="ascii").split()
            if len(fields) != 3 or fields[1] != token:
                raise RuntimeError(
                    f"timeout fixture attempt {attempt} did not start its tokenized helper"
                )
            helper_pid = int(fields[0])
            if not any(identity[0] == helper_pid for identity in seen_helper):
                raise RuntimeError(
                    f"timeout fixture attempt {attempt} never observed its own persistent helper"
                )
            if process.returncode != 1:
                raise RuntimeError(
                    f"timeout fixture attempt {attempt}: expected fail-under exit 1, "
                    f"got {process.returncode}\n{output}"
                )
            timeout_report = read_report(attempt_report)
            summary = timeout_report["summary"]
            assert summary["timeout"] == 1, summary
            assert summary["score"] == 0, summary
            assert summary["reused"] == 0, summary

            cleanup_deadline = time.monotonic() + 2
            remaining = seen_helper.copy()
            while remaining and time.monotonic() < cleanup_deadline:
                live_helpers = persistent_helper_identities(
                    windows_processes(powershell), expected_python, token
                )
                remaining = seen_helper & live_helpers
                if remaining:
                    time.sleep(0.1)
            if remaining:
                raise RuntimeError(
                    "timed-out mutation left its tokenized helper alive: "
                    f"{sorted(pid for pid, _, _, _, _ in remaining)}"
                )
        finally:
            # If the runner regresses, terminate only this child's PID and
            # creation time, never a tree inferred from Windows parent IDs.
            cleanup_persistent_child(ready_path, token)


def build_turtles(moon: str, env: dict[str, str]) -> Path:
    run(
        moon,
        ["build", "cmd/turtles", "--target", "native"],
        0,
        "build native CLI",
        env,
    )
    build_dir = ROOT / "_build" / "native" / "debug" / "build"
    executables = list(build_dir.rglob("turtles.exe"))
    if len(executables) != 1:
        raise RuntimeError(
            f"expected one native turtles.exe under {build_dir}, found {executables}"
        )
    return executables[0].resolve()


def main() -> int:
    if len(sys.argv) == 4 and sys.argv[1] == "--persistent-child":
        return run_persistent_child(sys.argv[2], Path(sys.argv[3]))

    moon = shutil.which("moon")
    if moon is None:
        raise RuntimeError("moon was not found on PATH")

    env = process_environment(moon)
    turtles = str(build_turtles(moon, env))

    with tempfile.TemporaryDirectory(prefix="turtles-windows-") as scratch:
        temp = Path(scratch)

        basic = temp / "basic-report.json"
        run(
            turtles,
            [
                "--dir", "fixtures/basic",
                "--target", "native", "--timeout", "120", "--jobs", "4",
                "--json", str(basic),
            ],
            0,
            "basic parallel fixture",
            env,
        )
        basic_report = read_report(basic)
        assert basic_report["schema"] == 3
        assert len(basic_report["mutants"]) == 6
        assert basic_report["summary"]["survived"] == 0
        assert basic_report["summary"]["timeout"] == 0

        sequential = temp / "isolation-sequential.json"
        parallel = temp / "isolation-parallel.json"
        for report, jobs in ((sequential, 1), (parallel, 4)):
            run(
                turtles,
                [
                    "--dir", "fixtures/isolation",
                    "--target", "native", "--timeout", "120", "--jobs", str(jobs),
                    "--json", str(report),
                ],
                1,
                f"isolation fixture with {jobs} worker(s)",
                env,
            )
        isolation_reports = [read_report(sequential), read_report(parallel)]
        for report in isolation_reports:
            summary = report["summary"]
            assert summary["killed"] == 3, summary
            assert summary["survived"] == 3, summary
            assert summary["unviable"] == 0, summary
            assert summary["timeout"] == 0, summary
        assert [mutant_key(m) for m in isolation_reports[0]["mutants"]] == [
            mutant_key(m) for m in isolation_reports[1]["mutants"]
        ]

        native_list = run(
            turtles,
            ["--dir", "fixtures/targets", "--target", "native", "--list"],
            0,
            "native target discovery",
            env,
        )
        assert "common.mbt:" in native_list
        assert "native_only.mbt:" in native_list
        assert "js_only.mbt:" not in native_list
        assert "target-inactive: js_only.mbt" in native_list

        targets = temp / "targets-report.json"
        target_output = temp / "targets-output"
        run(
            turtles,
            [
                "--dir", "fixtures/targets",
                "--target", "native", "--timeout", "120", "--json", str(targets),
                "--output-dir", str(target_output),
            ],
            1,
            "native target classification",
            env,
        )
        target_report = read_report(targets)
        assert target_report["target"] == "native"
        assert target_report["inactive_mutants"] == 1
        assert target_report["inactive_files"] == ["js_only.mbt"]
        assert all(
            mutant["path"] in ("common.mbt", "native_only.mbt")
            for mutant in target_report["mutants"]
        )

        run_timeout_smoke(turtles, moon, temp / "timeout-report.json", env)

    print(
        "Windows native subprocess, timeout iteration/cancellation, temp workspace, "
        "parallel, and target smoke checks passed"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AssertionError, OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"windows-smoke: {exc}", file=sys.stderr)
        sys.exit(1)
