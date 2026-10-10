#!/usr/bin/env python3
"""Exercise turtles' nested native subprocesses and fixtures on Windows."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]


def run(moon: str, args: list[str], expected: int, label: str) -> str:
    completed = subprocess.run(
        [moon, *args],
        cwd=ROOT,
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
        "Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine | "
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


def process_identity(row: dict) -> tuple[int, str, str, str]:
    return (
        int(row["ProcessId"]),
        str(row["Name"] or ""),
        str(row["ExecutablePath"] or "").casefold(),
        str(row["CommandLine"] or "").casefold(),
    )


def process_children(
    processes: list[dict], root_pid: int, expected_executable: str
) -> set[tuple[int, str, str, str]]:
    children: dict[int, list[int]] = {}
    by_pid = {int(row["ProcessId"]): row for row in processes}
    root = by_pid.get(root_pid)
    if root is None or str(root["ExecutablePath"] or "").casefold() != expected_executable:
        # The child may have exited between poll() and this process snapshot. A
        # reused PID must not turn an unrelated Windows process into a leak.
        return set()
    for row in processes:
        children.setdefault(int(row["ParentProcessId"] or 0), []).append(
            int(row["ProcessId"])
        )
    return {
        process_identity(by_pid[child])
        for child in children.get(root_pid, [])
        if child in by_pid
    }


def run_timeout_smoke(moon: str, report: Path) -> None:
    powershell = shutil.which("powershell.exe")
    if powershell is None:
        raise RuntimeError("powershell.exe is required for the Windows timeout check")

    command = [
        moon, "run", "cmd/turtles", "--", "--dir", "fixtures/timeout",
        "--target", "native", "--timeout", "1", "--json", str(report),
    ]
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    expected_executable = str(Path(moon).resolve()).casefold()
    seen_descendants: set[tuple[int, str, str, str]] = set()
    while process.poll() is None:
        seen_descendants.update(
            process_children(
                windows_processes(powershell), process.pid, expected_executable
            )
        )
        time.sleep(0.2)
    output, _ = process.communicate(timeout=30)
    if process.returncode != 1:
        raise RuntimeError(
            f"timeout fixture: expected exit 1, got {process.returncode}\n{output}"
        )
    timeout_report = read_report(report)
    assert timeout_report["summary"]["timeout"] == 1, timeout_report["summary"]

    deadline = time.monotonic() + 8
    live_processes = {process_identity(row) for row in windows_processes(powershell)}
    remaining = seen_descendants & live_processes
    while remaining and time.monotonic() < deadline:
        time.sleep(0.2)
        live_processes = {process_identity(row) for row in windows_processes(powershell)}
        remaining = seen_descendants & live_processes
    if remaining:
        raise RuntimeError(
            "timed-out direct subprocess children remain alive: "
            f"{sorted(pid for pid, _, _, _ in remaining)}"
        )


def main() -> int:
    moon = shutil.which("moon")
    if moon is None:
        raise RuntimeError("moon was not found on PATH")

    with tempfile.TemporaryDirectory(prefix="turtles-windows-") as scratch:
        temp = Path(scratch)

        basic = temp / "basic-report.json"
        run(
            moon,
            [
                "run", "cmd/turtles", "--", "--dir", "fixtures/basic",
                "--target", "native", "--timeout", "120", "--jobs", "4",
                "--json", str(basic),
            ],
            0,
            "basic parallel fixture",
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
                moon,
                [
                    "run", "cmd/turtles", "--", "--dir", "fixtures/isolation",
                    "--target", "native", "--timeout", "120", "--jobs", str(jobs),
                    "--json", str(report),
                ],
                1,
                f"isolation fixture with {jobs} worker(s)",
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
            moon,
            ["run", "cmd/turtles", "--", "--dir", "fixtures/targets", "--target", "native", "--list"],
            0,
            "native target discovery",
        )
        assert "common.mbt:" in native_list
        assert "native_only.mbt:" in native_list
        assert "js_only.mbt:" not in native_list
        assert "target-inactive: js_only.mbt" in native_list

        targets = temp / "targets-report.json"
        target_output = temp / "targets-output"
        run(
            moon,
            [
                "run", "cmd/turtles", "--", "--dir", "fixtures/targets",
                "--target", "native", "--timeout", "120", "--json", str(targets),
                "--output-dir", str(target_output),
            ],
            1,
            "native target classification",
        )
        target_report = read_report(targets)
        assert target_report["target"] == "native"
        assert target_report["inactive_mutants"] == 1
        assert target_report["inactive_files"] == ["js_only.mbt"]
        assert all(
            mutant["path"] in ("common.mbt", "native_only.mbt")
            for mutant in target_report["mutants"]
        )

        run_timeout_smoke(moon, temp / "timeout-report.json")

    print("Windows native subprocess, temp workspace, parallel, and target smoke checks passed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AssertionError, OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"windows-smoke: {exc}", file=sys.stderr)
        sys.exit(1)
