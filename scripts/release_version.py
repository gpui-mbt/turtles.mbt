#!/usr/bin/env python3
"""How: validate versioned release inputs without ever modifying source files."""

import argparse
from pathlib import Path
import re
import sys

VERSION = re.compile(
    r'^version[ \t]*=[ \t]*"(?P<major>0|[1-9][0-9]*)\.(?P<minor>0|[1-9][0-9]*)\.(?P<patch>0|[1-9][0-9]*)"[ \t]*$',
    re.MULTILINE,
)


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


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate MoonBit versioned releases")
    parser.add_argument("action", choices=("read", "check-tag", "changed"))
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--kind", choices=("moon-binstall", "turtles", "hotpath", "dsh"), required=True)
    parser.add_argument("--tag")
    parser.add_argument("--previous-file", type=Path)
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
    else:
        print(tag)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError) as exc:
        print(f"release-version: {exc}", file=sys.stderr)
        sys.exit(1)
