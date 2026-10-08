"""What: patch version increments, synchronized CLI constants, and fail-closed validation."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_version import changes_for, parse_version

class ReleaseVersionTests(unittest.TestCase):
    def test_manifest_read(self):
        self.assertEqual(parse_version('version = "0.1.9"\n')[0], "0.1.9")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            parse_version('version = "0.1.0"\nversion = "0.2.0"\n')

    def test_binstall_keeps_all_version_strings_aligned(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "moon.mod").write_text('version = "0.1.9"\n')
            (root / "installer.mbt").write_text('println("moon-binstall 0.1.9")\n')
            tag, changes = changes_for(root, "moon-binstall")
            self.assertEqual(tag, "v0.1.10")
            self.assertEqual(len(changes), 2)
            self.assertIn('version = "0.1.10"', changes[root / "moon.mod"])
            for content in changes.values():
                self.assertNotIn("moon-binstall 0.1.9", content)

    def test_turtles_keeps_cli_constant_aligned(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "moon.mod").write_text('version = "0.4.0"\n')
            cli = root / "cmd/turtles/config.mbt"
            cli.parent.mkdir(parents=True)
            cli.write_text('let turtles_version : String = "0.4.0"\n')
            tag, changed = changes_for(root, "turtles")
            self.assertEqual(tag, "v0.4.1")
            self.assertIn('turtles_version : String = "0.4.1"', changed[cli])

    def test_failed_precondition_does_not_write_manifest(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            manifest = root / "moon.mod"
            manifest.write_text('version = "0.1.0"\n')
            with self.assertRaisesRegex(ValueError, "expected exactly one"):
                changes_for(root, "turtles")
            self.assertEqual(manifest.read_text(), 'version = "0.1.0"\n')

if __name__ == "__main__":
    unittest.main()
