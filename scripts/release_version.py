#!/usr/bin/env python3
"""How: validate versioned release inputs without ever modifying source files."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

VERSION = re.compile(
    r'^version[ \t]*=[ \t]*"(?P<major>0|[1-9][0-9]*)\.(?P<minor>0|[1-9][0-9]*)\.(?P<patch>0|[1-9][0-9]*)"[ \t]*$',
    re.MULTILINE,
)
HTTP_STATUS = re.compile(r"HTTP/\S+ (?P<status>[0-9]{3})(?: .*)?")
SHA256_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
EXPECTED_RELEASE_ASSETS = {
    "turtles": frozenset(
        {
            "turtles-darwin-aarch64",
            "turtles-linux-aarch64",
            "turtles-linux-x86_64",
        }
    ),
}


def parse_version(source: str) -> tuple[int, int, int]:
    matches = list(VERSION.finditer(source))
    if len(matches) != 1:
        raise ValueError("moon.mod must contain exactly one numeric SemVer version")
    m = matches[0]
    return int(m["major"]), int(m["minor"]), int(m["patch"])


def format_tag(version: tuple[int, int, int]) -> str:
    return "v" + ".".join(str(n) for n in version)


def validate_cli_version(root: Path, kind: str, version: tuple[int, int, int]) -> None:
    value = ".".join(str(n) for n in version)
    markers = {
        "moon-binstall": ("installer.mbt", f'println("moon-binstall {value}")'),
        "turtles": ("cmd/turtles/config.mbt", f'let turtles_version : String = "{value}"'),
    }
    if kind not in markers:
        return
    filename, marker = markers[kind]
    code = (root / filename).read_text(encoding="utf-8")
    if code.count(marker) != 1:
        raise ValueError(f"{filename} must have exactly one version marker {marker}")


def release_from_change(previous_source: str, current_source: str) -> str:
    previous = parse_version(previous_source)
    current = parse_version(current_source)
    if current < previous:
        raise ValueError(
            f"version decreased from {format_tag(previous)} to {format_tag(current)}"
        )
    return format_tag(current) if current > previous else ""


def validate_existing_release(
    release: object, expected_tag: str, expected_assets: frozenset[str]
) -> None:
    if not isinstance(release, dict):
        raise ValueError("existing release response must be a JSON object")
    if release.get("tag_name") != expected_tag:
        raise ValueError(
            f"existing release tag {release.get('tag_name')!r} does not match {expected_tag}"
        )
    if release.get("draft") is not False:
        raise ValueError("existing release is a draft; refusing to overwrite it")
    if release.get("prerelease") is not False:
        raise ValueError("existing release is a prerelease; refusing to overwrite it")
    published_at = release.get("published_at")
    if not isinstance(published_at, str) or not published_at.strip():
        raise ValueError("existing release has no published_at timestamp")

    assets = release.get("assets")
    if not isinstance(assets, list) or len(assets) != len(expected_assets):
        raise ValueError(
            f"existing release must contain exactly {len(expected_assets)} native assets"
        )

    seen: set[str] = set()
    for asset in assets:
        if not isinstance(asset, dict):
            raise ValueError("existing release contains an invalid asset record")
        name = asset.get("name")
        if not isinstance(name, str) or name not in expected_assets:
            raise ValueError(f"existing release contains unexpected asset {name!r}")
        if name in seen:
            raise ValueError(f"existing release contains duplicate asset {name!r}")
        seen.add(name)
        if asset.get("state") != "uploaded":
            raise ValueError(f"release asset {name!r} is not fully uploaded")
        size = asset.get("size")
        if type(size) is not int or size <= 0:
            raise ValueError(f"release asset {name!r} has no valid nonzero size")
        digest = asset.get("digest")
        if not isinstance(digest, str) or not SHA256_DIGEST.fullmatch(digest):
            raise ValueError(f"release asset {name!r} has no valid SHA-256 digest")

    if seen != expected_assets:
        missing = ", ".join(sorted(expected_assets - seen))
        raise ValueError(f"existing release is missing native assets: {missing}")


def inspect_release_api_response(
    response_text: str,
    request_exit_code: int,
    expected_tag: str,
    expected_assets: frozenset[str],
) -> str:
    sections = re.split(r"\r?\n\r?\n", response_text, maxsplit=1)
    if len(sections) != 2:
        raise ValueError(
            "GitHub release API request returned no HTTP status or response body; refusing to publish or skip"
        )
    header_lines = sections[0].splitlines()
    status_match = HTTP_STATUS.fullmatch(header_lines[0]) if header_lines else None
    if status_match is None:
        raise ValueError(
            "GitHub release API request returned no HTTP status; refusing to publish or skip"
        )
    status = int(status_match["status"])
    if status == 404 and request_exit_code != 0:
        return "missing"
    if status != 200:
        raise ValueError(
            f"GitHub release API returned HTTP {status}; refusing to publish or skip"
        )
    if request_exit_code != 0:
        raise ValueError(
            "GitHub release API request failed despite HTTP 200; refusing to skip"
        )

    if len(sections) != 2 or not sections[1].strip():
        raise ValueError("GitHub release API response has no JSON body")
    try:
        release = json.loads(sections[1])
    except json.JSONDecodeError as exc:
        raise ValueError("GitHub release API response has invalid JSON") from exc
    validate_existing_release(release, expected_tag, expected_assets)
    return "complete"


def inspect_release_list_response(
    response_text: str,
    request_exit_code: int,
    expected_tag: str,
) -> str:
    if request_exit_code != 0:
        raise ValueError(
            "GitHub release list API request failed; refusing to publish or skip"
        )
    try:
        pages = json.loads(response_text)
    except json.JSONDecodeError as exc:
        raise ValueError("GitHub release list API response has invalid JSON") from exc
    if not isinstance(pages, list):
        raise ValueError("GitHub release list API response must be a page array")

    matching_releases: list[dict[str, object]] = []
    for page in pages:
        if not isinstance(page, list):
            raise ValueError("GitHub release list API response contains an invalid page")
        for release in page:
            if not isinstance(release, dict):
                raise ValueError("GitHub release list API response contains an invalid release")
            if release.get("tag_name") == expected_tag:
                matching_releases.append(release)

    if not matching_releases:
        return "missing"
    if any(release.get("draft") is True for release in matching_releases):
        raise ValueError(
            f"draft release {expected_tag} is present in the release list; refusing to publish or skip"
        )
    raise ValueError(
        f"release list contains {expected_tag} after tag lookup returned 404; refusing to publish or skip"
    )


def verify_remote_release_tag(
    expected_tag: str,
    explicit_tag: bool,
    root: Path = Path("."),
) -> str:
    fetch = subprocess.run(
        [
            "git",
            "fetch",
            "--no-tags",
            "--prune",
            "origin",
            "refs/tags/*:refs/release-verification/*",
            "--quiet",
        ],
        cwd=root,
        capture_output=True,
        text=True,
    )
    if fetch.returncode != 0:
        detail = fetch.stderr.strip()
        suffix = f": {detail}" if detail else ""
        raise ValueError(f"failed to fetch tags for release verification{suffix}")

    tag_ref = f"refs/release-verification/{expected_tag}"
    tag_exists = subprocess.run(
        ["git", "show-ref", "--verify", "--quiet", tag_ref],
        cwd=root,
        capture_output=True,
        text=True,
    )
    if tag_exists.returncode == 1:
        if explicit_tag:
            raise ValueError(f"explicit tag {expected_tag} does not exist on origin")
        return "missing"
    if tag_exists.returncode != 0:
        detail = tag_exists.stderr.strip()
        suffix = f": {detail}" if detail else ""
        raise ValueError(f"failed to inspect remote tag {expected_tag}{suffix}")

    tagged_commit = subprocess.run(
        ["git", "rev-list", "-n", "1", tag_ref],
        cwd=root,
        capture_output=True,
        text=True,
    )
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=root,
        capture_output=True,
        text=True,
    )
    if tagged_commit.returncode != 0 or head.returncode != 0:
        raise ValueError(f"failed to resolve remote tag {expected_tag} or HEAD")
    if tagged_commit.stdout.strip() != head.stdout.strip():
        raise ValueError(f"tag {expected_tag} points at a different commit")
    return "present"


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate MoonBit versioned releases")
    parser.add_argument(
        "action",
        choices=(
            "read",
            "check-tag",
            "changed",
            "check-existing-release",
            "check-release-list",
            "verify-tag-ref",
        ),
    )
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--kind", choices=("moon-binstall", "turtles", "hotpath", "dsh"), required=True)
    parser.add_argument("--tag")
    parser.add_argument("--previous-file", type=Path)
    parser.add_argument("--response-file", type=Path)
    parser.add_argument("--request-exit-code", type=int)
    parser.add_argument("--explicit-tag", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    source = (root / "moon.mod").read_text(encoding="utf-8")
    current = parse_version(source)
    validate_cli_version(root, args.kind, current)
    tag = format_tag(current)
    if args.action == "check-tag":
        if args.tag != tag:
            raise ValueError(f"tag {args.tag!r} does not match moon.mod {tag}")
        print(tag)
    elif args.action == "changed":
        if args.previous_file is None:
            parser.error("--previous-file is required for changed")
        previous = args.previous_file.read_text(encoding="utf-8")
        print(release_from_change(previous, source))
    elif args.action in ("check-existing-release", "check-release-list"):
        if args.tag is None:
            parser.error(f"--tag is required for {args.action}")
        if args.response_file is None:
            parser.error(f"--response-file is required for {args.action}")
        if args.request_exit_code is None:
            parser.error(f"--request-exit-code is required for {args.action}")
        expected_assets = EXPECTED_RELEASE_ASSETS.get(args.kind)
        if expected_assets is None:
            raise ValueError(f"existing release validation is unsupported for {args.kind}")
        response = args.response_file.read_text(encoding="utf-8")
        if args.action == "check-existing-release":
            state = inspect_release_api_response(
                response,
                args.request_exit_code,
                args.tag,
                expected_assets,
            )
        else:
            state = inspect_release_list_response(
                response,
                args.request_exit_code,
                args.tag,
            )
        print(state)
    elif args.action == "verify-tag-ref":
        if args.tag is None:
            parser.error("--tag is required for verify-tag-ref")
        print(verify_remote_release_tag(args.tag, args.explicit_tag, root))
    else:
        print(tag)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError) as exc:
        print(f"release-version: {exc}", file=sys.stderr)
        sys.exit(1)
