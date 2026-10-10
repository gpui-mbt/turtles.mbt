"""Regression tests for Windows smoke-test subprocess identity checks."""

from __future__ import annotations

import unittest

from scripts import windows_smoke


TURTLES = r"C:\tools\turtles.exe"
MOON = r"C:\tools\moon.exe"


def process(
    pid: int,
    parent: int,
    name: str,
    executable: str,
    command_line: str,
    creation_date: str,
) -> dict:
    return {
        "ProcessId": pid,
        "ParentProcessId": parent,
        "Name": name,
        "ExecutablePath": executable,
        "CommandLine": command_line,
        "CreationDate": creation_date,
    }


class WindowsSmokeProcessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = process(
            100,
            1,
            "turtles.exe",
            TURTLES,
            f'"{TURTLES}" --dir fixtures/timeout --timeout 1',
            "root-created",
        )
        self.root_identity = windows_smoke.process_identity(self.root)
        self.moon = process(
            200,
            100,
            "moon.exe",
            MOON,
            f'"{MOON}" test --target native',
            "child-created",
        )

    def test_observes_only_matching_direct_moon_child(self) -> None:
        sibling = process(
            201, 100, "helper.exe", r"C:\tools\helper.exe", "helper", "sibling"
        )
        nested = process(
            300,
            200,
            "moon.exe",
            MOON,
            f'"{MOON}" nested',
            "grandchild",
        )

        children = windows_smoke.process_children(
            [self.root, self.moon, sibling, nested], self.root_identity, MOON
        )

        self.assertEqual(children, {windows_smoke.process_identity(self.moon)})

    def test_rejects_a_reused_root_pid(self) -> None:
        reused_root = dict(self.root, CreationDate="reused-root-created")

        children = windows_smoke.process_children(
            [reused_root, self.moon], self.root_identity, MOON
        )

        self.assertEqual(children, set())

    def test_requires_the_expected_root_image_and_command(self) -> None:
        unrelated = dict(self.root, CommandLine='"C:\\tools\\turtles.exe" --version')

        self.assertIsNone(
            windows_smoke.find_process_identity(
                [unrelated], 100, TURTLES, "--dir fixtures/timeout"
            )
        )

    def test_rejects_an_empty_child_observation(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "observed no direct"):
            windows_smoke.require_observed_children(set())

    def test_rejects_a_surviving_child_but_ignores_pid_reuse(self) -> None:
        observed = {windows_smoke.process_identity(self.moon)}
        reused_moon = dict(self.moon, CreationDate="reused-child-created")

        with self.assertRaisesRegex(RuntimeError, "remain alive"):
            windows_smoke.require_children_exited(
                observed, {windows_smoke.process_identity(self.moon)}
            )
        windows_smoke.require_children_exited(
            observed, {windows_smoke.process_identity(reused_moon)}
        )


if __name__ == "__main__":
    unittest.main()
