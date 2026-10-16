#!/usr/bin/env python3
"""Exercise GNU timeout classification through the native turtles CLI."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def write_fixture(module: Path) -> None:
    module.mkdir(parents=True)
    (module / "moon.mod").write_text(
        'name = "review/timeout"\nversion = "0.1.0"\npreferred_target = "native"\n',
        encoding="utf-8",
    )
    (module / "moon.pkg").write_text("", encoding="utf-8")
    (module / "loop.mbt").write_text(
        """///|
pub fn loop_value() -> Int {
  let mut count = 0
  while false {
    count = count + 1
  }
  count
}
""",
        encoding="utf-8",
    )
    (module / "loop_test.mbt").write_text(
        '///|\ntest "loop_value" { inspect(loop_value(), content="0") }\n',
        encoding="utf-8",
    )


def main() -> None:
    moon = shutil.which("moon")
    if moon is None:
        raise SystemExit("moon is not available on PATH")
    if sys.platform == "darwin":
        helper = shutil.which("gtimeout")
        if helper is None:
            raise SystemExit(
                "gtimeout is required for the Darwin timeout-classification smoke test"
            )
    else:
        helper = shutil.which("gtimeout") or shutil.which("timeout")
        if helper is None:
            raise SystemExit("GNU timeout is not available on PATH")

    environment = os.environ.copy()
    with tempfile.TemporaryDirectory(prefix="turtles-timeout-smoke-") as temp:
        root = Path(temp)
        module = root / "module"
        output_dir = root / "output"
        write_fixture(module)

        for attempt in (1, 2):
            report_path = root / f"report-{attempt}.json"
            command = [
                moon,
                "run",
                "cmd/turtles",
                "--",
                "--dir",
                str(module),
                "--timeout",
                "3",
                "--fail-under",
                "1",
                "--iterate",
                "--pbt-amplify",
                "2",
                "--output-dir",
                str(output_dir),
                "--json",
                str(report_path),
            ]
            result = subprocess.run(
                command,
                cwd=ROOT,
                env=environment,
                capture_output=True,
                check=False,
                text=True,
                timeout=180,
            )
            if result.returncode != 1:
                raise AssertionError(
                    f"attempt {attempt} exited {result.returncode}, expected fail-under exit 1\n"
                    f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
                )

            with report_path.open(encoding="utf-8") as stream:
                report = json.load(stream)
            summary = report["summary"]
            timeout_mutants = [
                mutant for mutant in report["mutants"] if mutant["outcome"] == "TIMEOUT"
            ]
            if (
                summary["timeout"] != 1
                or summary["killed"] != 0
                or summary["score"] != 0
            ):
                raise AssertionError(f"unexpected timeout summary: {summary}")
            if (
                summary["reused"] != 0
                or len(timeout_mutants) != 1
                or timeout_mutants[0]["original"] != "false"
                or timeout_mutants[0]["replacement"] != "true"
            ):
                raise AssertionError(
                    f"timeout verdict was reused or missing: {report['mutants']}"
                )

        print(
            "GNU timeout smoke passed: timeout counted, fail-under rejected, "
            f"and TIMEOUT was rechecked on iterate (helper: {helper})."
        )


if __name__ == "__main__":
    main()
