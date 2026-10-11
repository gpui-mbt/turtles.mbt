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
            "20261010000000.000000+000",
        )
        self.root_identity = windows_smoke.process_identity(self.root)
        self.moon = process(
            200,
            100,
            "moon.exe",
            MOON,
            f'"{MOON}" test --target native',
            "20261010000001.000000+000",
        )

    def test_observes_direct_moon_and_full_descendant_tree(self) -> None:
        sibling = process(
            201,
            100,
            "helper.exe",
            r"C:\tools\helper.exe",
            "helper",
            "20261010000001.500000+000",
        )
        nested = process(
            300,
            200,
            "moon.exe",
            MOON,
            f'"{MOON}" nested',
            "20261010000002.000000+000",
        )
        unrelated = process(
            400,
            999,
            "helper.exe",
            r"C:\tools\helper.exe",
            "unrelated",
            "20261010000003.000000+000",
        )

        children = windows_smoke.process_children(
            [self.root, self.moon, sibling, nested, unrelated],
            self.root_identity,
            MOON,
        )
        descendants = windows_smoke.process_descendant_depths(
            [self.root, self.moon, sibling, nested, unrelated], self.root_identity
        )

        self.assertEqual(children, {windows_smoke.process_identity(self.moon)})
        self.assertEqual(
            descendants,
            {
                windows_smoke.process_identity(self.moon): 1,
                windows_smoke.process_identity(sibling): 1,
                windows_smoke.process_identity(nested): 2,
            },
        )
        windows_smoke.require_observed_nested_processes(children, descendants)
        with self.assertRaisesRegex(RuntimeError, "no descendants beneath moon"):
            windows_smoke.require_observed_nested_processes(
                children,
                {windows_smoke.process_identity(self.moon): 1},
            )

    def test_rejects_a_reused_root_pid(self) -> None:
        reused_root = dict(
            self.root, CreationDate="20261010000003.000000+000"
        )

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

    def test_rejects_a_reused_parent_pid_for_an_older_descendant(self) -> None:
        reused_moon = dict(
            self.moon, CreationDate="20261010000003.000000+000"
        )
        nested = process(
            300,
            200,
            "test.exe",
            r"C:\tools\test.exe",
            "test",
            "20261010000002.000000+000",
        )

        descendants = windows_smoke.process_descendant_depths(
            [self.root, reused_moon, nested], self.root_identity
        )

        self.assertEqual(descendants, {windows_smoke.process_identity(reused_moon): 1})

    def test_rejects_a_surviving_descendant_but_ignores_pid_reuse(self) -> None:
        observed = {windows_smoke.process_identity(self.moon)}
        reused_moon = dict(self.moon, CreationDate="20261010000002.000000+000")

        with self.assertRaisesRegex(RuntimeError, "remain alive"):
            windows_smoke.require_descendants_exited(
                observed, {windows_smoke.process_identity(self.moon)}
            )
        windows_smoke.require_descendants_exited(
            observed, {windows_smoke.process_identity(reused_moon)}
        )


if __name__ == "__main__":
    unittest.main()
