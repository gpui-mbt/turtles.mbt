"""Exercise release tag verification against real local Git repositories."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_version import verify_remote_release_tag


ROOT = Path(__file__).resolve().parents[2]


def git(cwd: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", "-C", str(cwd), *args],
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        raise AssertionError(
            f"git {' '.join(args)} failed ({result.returncode}): {result.stderr}"
        )
    return result


class ReleaseTagFetchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.remote = self.base / "remote.git"
        self.seed = self.base / "seed"
        self.runner = self.base / "runner"
        self.tag = "v0.4.1"

        subprocess.run(
            ["git", "init", "--bare", "--initial-branch=main", str(self.remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        subprocess.run(
            ["git", "init", "--initial-branch=main", str(self.seed)],
            check=True,
            capture_output=True,
            text=True,
        )
        git(self.seed, "config", "user.name", "Release guard test")
        git(self.seed, "config", "user.email", "release-guard@example.invalid")
        (self.seed / "version.txt").write_text("first\n", encoding="utf-8")
        git(self.seed, "add", "version.txt")
        git(self.seed, "commit", "-m", "first")
        git(self.seed, "remote", "add", "origin", str(self.remote))
        git(self.seed, "push", "origin", "main")
        git(self.seed, "tag", "-a", self.tag, "-m", "release")
        git(self.seed, "push", "origin", self.tag)
        git(
            self.base,
            "clone",
            "--branch",
            "main",
            "--no-tags",
            str(self.remote),
            str(self.runner),
        )

    def test_dedicated_namespace_fetch_survives_checkout_peeled_local_tag(self) -> None:
        head = git(self.runner, "rev-parse", "HEAD").stdout.strip()
        remote_tag_object = subprocess.run(
            ["git", "--git-dir", str(self.remote), "rev-parse", f"refs/tags/{self.tag}"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

        # actions/checkout can leave this remote annotated tag as a peeled
        # commit in refs/tags, which makes a normal --tags fetch fail.
        git(self.runner, "update-ref", f"refs/tags/{self.tag}", head)
        old_fetch = git(self.runner, "fetch", "origin", "--tags", "--quiet", check=False)
        self.assertNotEqual(old_fetch.returncode, 0)

        self.assertEqual(
            verify_remote_release_tag(self.tag, explicit_tag=True, root=self.runner),
            "present",
        )
        self.assertEqual(
            git(
                self.runner,
                "rev-parse",
                f"refs/release-verification/{self.tag}",
            ).stdout.strip(),
            remote_tag_object,
        )
        self.assertEqual(
            git(
                self.runner,
                "rev-list",
                "-n",
                "1",
                f"refs/release-verification/{self.tag}",
            ).stdout.strip(),
            head,
        )
        # The verification fetch must not rewrite the checkout-owned local tag.
        self.assertEqual(
            git(self.runner, "rev-parse", f"refs/tags/{self.tag}").stdout.strip(),
            head,
        )

    def test_missing_tag_is_allowed_only_for_manifest_trigger(self) -> None:
        subprocess.run(
            ["git", "--git-dir", str(self.remote), "update-ref", "-d", f"refs/tags/{self.tag}"],
            check=True,
            capture_output=True,
            text=True,
        )
        git(self.runner, "update-ref", "-d", f"refs/release-verification/{self.tag}", check=False)
        self.assertEqual(
            verify_remote_release_tag(self.tag, explicit_tag=False, root=self.runner),
            "missing",
        )
        with self.assertRaisesRegex(ValueError, "does not exist on origin"):
            verify_remote_release_tag(self.tag, explicit_tag=True, root=self.runner)

    def test_explicit_tag_for_another_commit_is_rejected(self) -> None:
        first_commit = git(self.runner, "rev-parse", "HEAD").stdout.strip()
        git(self.seed, "checkout", "main")
        (self.seed / "version.txt").write_text("second\n", encoding="utf-8")
        git(self.seed, "add", "version.txt")
        git(self.seed, "commit", "-m", "second")
        git(self.seed, "push", "origin", "main")
        git(self.runner, "fetch", "origin", "main")
        git(self.runner, "reset", "--hard", "origin/main")
        self.assertNotEqual(first_commit, git(self.runner, "rev-parse", "HEAD").stdout.strip())
        with self.assertRaisesRegex(ValueError, "different commit"):
            verify_remote_release_tag(self.tag, explicit_tag=False, root=self.runner)

    def test_branch_release_creation_uses_exact_event_sha(self) -> None:
        workflow = (ROOT / ".github/workflows/publish-native.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn('gh release create "$RELEASE_TAG" release/* --target "$GITHUB_SHA"', workflow)


if __name__ == "__main__":
    unittest.main()
