"""What: release only on real manifest version increases; refuse invalid versions."""

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_version import (
    format_tag,
    parse_version,
    release_from_change,
    validate_cli_version,
)


class ReleaseVersionTests(unittest.TestCase):
    def test_parse_version(self):
        self.assertEqual(parse_version('version = "0.1.9"\n'), (0, 1, 9))
        self.assertEqual(format_tag((1, 2, 3)), "v1.2.3")

    def test_reject_noncanonical_versions(self):
        for value in ("01.2.3", "1.2.3-alpha", "latest", "1.2", "1.2.03"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                parse_version(f'version = "{value}"\n')

    def test_reject_duplicate_version(self):
        with self.assertRaises(ValueError):
            parse_version('version = "0.1.0"\nversion = "0.2.0"\n')

    def test_changed_version_triggers_release(self):
        self.assertEqual(
            release_from_change('version = "0.1.0"\n', 'version = "0.2.0"\n'),
            "v0.2.0",
        )

    def test_dependency_change_does_not_trigger_release(self):
        self.assertEqual(
            release_from_change('version = "0.1.0"\nimport = "a"\n',
                                'version = "0.1.0"\nimport = "b"\n'),
            "",
        )

    def test_version_downgrade_rejected(self):
        with self.assertRaisesRegex(ValueError, "decreased"):
            release_from_change('version = "0.4.0"\n', 'version = "0.3.0"\n')

    def test_binstall_cli_must_match_manifest(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "installer.mbt").write_text('println("moon-binstall 0.1.0")\n')
            validate_cli_version(root, "moon-binstall", (0, 1, 0))
            with self.assertRaisesRegex(ValueError, "version marker"):
                validate_cli_version(root, "moon-binstall", (0, 1, 1))

    def test_turtles_cli_must_match_manifest(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli = root / "cmd/turtles/config.mbt"
            cli.parent.mkdir(parents=True)
            cli.write_text('let turtles_version : String = "0.4.0"\n')
            validate_cli_version(root, "turtles", (0, 4, 0))
            with self.assertRaisesRegex(ValueError, "version marker"):
                validate_cli_version(root, "turtles", (0, 4, 1))


if __name__ == "__main__":
    unittest.main()
