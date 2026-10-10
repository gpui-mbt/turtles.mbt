"""What: release only on real manifest version increases; refuse invalid versions."""

import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_version import (
    format_tag,
    inspect_release_api_response,
    inspect_release_list_response,
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

    def _valid_release(self):
        return {
            "tag_name": "v0.4.0",
            "draft": False,
            "prerelease": False,
            "published_at": "2026-10-09T03:08:49Z",
            "assets": [
                {
                    "name": name,
                    "state": "uploaded",
                    "size": 123,
                    "digest": "sha256:" + "a" * 64,
                }
                for name in (
                    "turtles-darwin-aarch64",
                    "turtles-linux-aarch64",
                    "turtles-linux-x86_64",
                    "turtles-windows-x86_64.exe",
                )
            ],
        }

    def _response(self, status, body):
        return (
            f"HTTP/2.0 {status} Test\r\ncontent-type: application/json\r\n\r\n"
            + json.dumps(body)
        )

    def _inspect(self, release, request_exit_code=0):
        return inspect_release_api_response(
            self._response(200, release),
            request_exit_code,
            "v0.4.0",
            frozenset(
                {
                    "turtles-darwin-aarch64",
                    "turtles-linux-aarch64",
                    "turtles-linux-x86_64",
                    "turtles-windows-x86_64.exe",
                }
            ),
        )

    def test_complete_published_release_is_idempotent(self):
        self.assertEqual(self._inspect(self._valid_release()), "complete")

    def test_draft_release_is_not_treated_as_published(self):
        release = self._valid_release()
        release["draft"] = True
        with self.assertRaisesRegex(ValueError, "draft"):
            self._inspect(release)

    def test_prerelease_is_not_treated_as_published(self):
        release = self._valid_release()
        release["prerelease"] = True
        with self.assertRaisesRegex(ValueError, "prerelease"):
            self._inspect(release)

    def test_partial_release_is_not_treated_as_published(self):
        release = self._valid_release()
        release["assets"].pop()
        with self.assertRaisesRegex(ValueError, "exactly 4"):
            self._inspect(release)

    def test_missing_asset_digest_is_not_treated_as_published(self):
        release = self._valid_release()
        release["assets"][0]["digest"] = None
        with self.assertRaisesRegex(ValueError, "SHA-256 digest"):
            self._inspect(release)

    def test_incomplete_asset_metadata_is_not_treated_as_published(self):
        release = self._valid_release()
        release["assets"][0]["state"] = "new"
        with self.assertRaisesRegex(ValueError, "not fully uploaded"):
            self._inspect(release)
        release = self._valid_release()
        release["assets"][0]["size"] = 0
        with self.assertRaisesRegex(ValueError, "nonzero size"):
            self._inspect(release)

    def test_missing_published_timestamp_is_not_treated_as_published(self):
        release = self._valid_release()
        release["published_at"] = None
        with self.assertRaisesRegex(ValueError, "published_at"):
            self._inspect(release)

    def test_wrong_asset_or_tag_is_not_treated_as_published(self):
        release = self._valid_release()
        release["assets"][0]["name"] = "turtles-linux-x86_64"
        with self.assertRaisesRegex(ValueError, "unexpected asset|duplicate asset"):
            self._inspect(release)
        release = self._valid_release()
        release["tag_name"] = "v0.3.0"
        with self.assertRaisesRegex(ValueError, "does not match"):
            self._inspect(release)

    def test_only_actual_not_found_is_treated_as_missing_release(self):
        self.assertEqual(
            inspect_release_api_response(
                self._response(404, {"message": "Not Found"}),
                1,
                "v0.4.0",
                frozenset({"turtles-darwin-aarch64", "turtles-linux-aarch64", "turtles-linux-x86_64", "turtles-windows-x86_64.exe"}),
            ),
            "missing",
        )
        with self.assertRaisesRegex(ValueError, "HTTP 404"):
            inspect_release_api_response(
                self._response(404, {"message": "Not Found"}),
                0,
                "v0.4.0",
                frozenset(),
            )

    def test_auth_rate_limit_and_server_errors_fail_closed(self):
        for status in (401, 403, 429, 500):
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, f"HTTP {status}"):
                inspect_release_api_response(
                    self._response(status, {"message": "API error"}),
                    1,
                    "v0.4.0",
                    frozenset({"turtles-darwin-aarch64", "turtles-linux-aarch64", "turtles-linux-x86_64", "turtles-windows-x86_64.exe"}),
                )

    def test_api_transport_failure_without_status_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "no HTTP status"):
            inspect_release_api_response("", 1, "v0.4.0", frozenset())

    def test_by_tag_404_then_matching_draft_on_later_list_page_fails_closed(self):
        expected_assets = frozenset(
            {
                "turtles-darwin-aarch64",
                "turtles-linux-aarch64",
                "turtles-linux-x86_64",
                "turtles-windows-x86_64.exe",
            }
        )
        self.assertEqual(
            inspect_release_api_response(
                self._response(404, {"message": "Not Found"}),
                1,
                "v0.4.0",
                expected_assets,
            ),
            "missing",
        )
        old_release = self._valid_release()
        old_release["tag_name"] = "v0.3.0"
        draft_release = self._valid_release()
        draft_release["draft"] = True
        response = json.dumps([[old_release], [draft_release]])
        with self.assertRaisesRegex(ValueError, "draft"):
            inspect_release_list_response(response, 0, "v0.4.0")

    def test_empty_successful_release_list_is_missing(self):
        self.assertEqual(
            inspect_release_list_response("[[]]", 0, "v0.4.0"),
            "missing",
        )

    def test_unrelated_release_in_successful_list_does_not_block_new_tag(self):
        old_release = self._valid_release()
        old_release["tag_name"] = "v0.3.0"
        self.assertEqual(
            inspect_release_list_response(
                json.dumps([[old_release]]),
                0,
                "v0.4.0",
            ),
            "missing",
        )

    def test_release_list_errors_and_invalid_pages_fail_closed(self):
        with self.assertRaisesRegex(ValueError, "request failed"):
            inspect_release_list_response("[]", 1, "v0.4.0")
        with self.assertRaisesRegex(ValueError, "invalid page"):
            inspect_release_list_response("[{}]", 0, "v0.4.0")

    def test_published_release_in_list_after_tag_lookup_404_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "after tag lookup returned 404"):
            inspect_release_list_response(
                json.dumps([[self._valid_release()]]),
                0,
                "v0.4.0",
            )


if __name__ == "__main__":
    unittest.main()
