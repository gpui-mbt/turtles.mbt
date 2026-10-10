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


ROOT = Path(__file__).resolve().parents[1]


ProcessIdentity = tuple[int, str, str, str, str]


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


def find_process_identity(
    processes: list[dict],
    root_pid: int,
    expected_executable: str,
    expected_command_fragment: str,
) -> ProcessIdentity | None:
    by_pid = {int(row["ProcessId"]): row for row in processes}
    root = by_pid.get(root_pid)
    if root is None:
        return None
    identity = process_identity(root)
    if (
        identity[2] != expected_executable.casefold()
        or expected_command_fragment.casefold() not in identity[3]
    ):
        return None
    return identity


def process_children(
    processes: list[dict],
    root_identity: ProcessIdentity,
    expected_child_executable: str,
) -> set[ProcessIdentity]:
    by_pid = {int(row["ProcessId"]): row for row in processes}
    root = by_pid.get(root_identity[0])
    # A child may exit between two snapshots. Requiring the complete root
    # identity prevents a reused PID from making an unrelated process look like
    # the turtles process whose subprocesses this smoke is tracking.
    if root is None or process_identity(root) != root_identity:
        return set()
    return {
        process_identity(by_pid[child])
        for child, row in by_pid.items()
        if int(row["ParentProcessId"] or 0) == root_identity[0]
        and str(row["ExecutablePath"] or "").casefold()
        == expected_child_executable.casefold()
    }


def require_observed_children(children: set[ProcessIdentity]) -> None:
    if not children:
        raise RuntimeError("timeout smoke observed no direct nested moon.exe children")


def require_children_exited(
    observed: set[ProcessIdentity], live: set[ProcessIdentity]
) -> None:
    remaining = observed & live
    if remaining:
        raise RuntimeError(
            "timed-out direct subprocess children remain alive: "
            f"{sorted(pid for pid, _, _, _, _ in remaining)}"
        )


def run_timeout_smoke(
    turtles: str, moon: str, report: Path, env: dict[str, str]
) -> None:
    powershell = shutil.which("powershell.exe")
    if powershell is None:
        raise RuntimeError("powershell.exe is required for the Windows timeout check")

    expected_turtles = str(Path(turtles).resolve())
    expected_moon = str(Path(moon).resolve())
    output_dir = report.with_name(f"{report.stem}-output")
    for attempt in (1, 2):
        attempt_report = (
            report
            if attempt == 1
            else report.with_name(f"{report.stem}-iterate{report.suffix}")
        )
        command = [
            turtles, "--dir", "fixtures/timeout",
            "--target", "native", "--timeout", "1",
            "--fail-under", "1", "--iterate",
            "--output-dir", str(output_dir), "--json", str(attempt_report),
        ]
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        seen_children: set[ProcessIdentity] = set()
        root_identity: ProcessIdentity | None = None
        deadline = time.monotonic() + 180
        try:
            while True:
                snapshot = windows_processes(powershell)
                if root_identity is None:
                    root_identity = find_process_identity(
                        snapshot,
                        process.pid,
                        expected_turtles,
                        "--dir fixtures/timeout",
                    )
                if root_identity is not None:
                    seen_children.update(
                        process_children(snapshot, root_identity, expected_moon)
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
            raise

        if root_identity is None:
            raise RuntimeError(
                f"timeout smoke attempt {attempt} never observed its turtles.exe process"
            )
        require_observed_children(seen_children)
        if process.returncode != 1:
            raise RuntimeError(
                f"timeout fixture attempt {attempt}: expected fail-under exit 1, "
                f"got {process.returncode}\n{output}"
            )
        timeout_report = read_report(attempt_report)
        summary = timeout_report["summary"]
        assert summary["timeout"] == 1, summary
        assert summary["score"] == 0, summary
        # TIMEOUT verdicts must never be reused, including on Windows' direct
        # process-cancellation path.
        assert summary["reused"] == 0, summary

        cleanup_deadline = time.monotonic() + 8
        live_processes = {
            process_identity(row) for row in windows_processes(powershell)
        }
        remaining = seen_children & live_processes
        while remaining and time.monotonic() < cleanup_deadline:
            time.sleep(0.2)
            live_processes = {
                process_identity(row) for row in windows_processes(powershell)
            }
            remaining = seen_children & live_processes
        require_children_exited(seen_children, live_processes)


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
