"""Regression tests for exact helper identity in the Windows smoke test."""

from __future__ import annotations

import unittest

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


if __name__ == "__main__":
    unittest.main()
