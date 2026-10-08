#!/usr/bin/env python3
"""How: safely bump one patch release and synchronize executable version strings."""
import argparse
from pathlib import Path
import re
import sys

VERSION = re.compile(r'^(version[ \t]*=[ \t]*")(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)("[ \t]*)$', re.MULTILINE)

def parse_version(content):
    matches = list(VERSION.finditer(content))
    if len(matches) != 1:
        raise ValueError("moon.mod must have exactly one semantic version assignment")
    m = matches[0]
    return f"{int(m['major'])}.{int(m['minor'])}.{int(m['patch'])}", m

def changes_for(root, kind):
    manifest = root / "moon.mod"
    source = manifest.read_text(encoding="utf-8")
    old, match = parse_version(source)
    major, minor, patch = map(int, old.split("."))
    new = f"{major}.{minor}.{patch + 1}"
    changed = {manifest: source[:match.start()] + match.group(1) + new + match.group(5) + source[match.end():]}
    if kind == "turtles":
        extra = {"cmd/turtles/config.mbt": (f'let turtles_version : String = "{old}"', f'let turtles_version : String = "{new}"')}
    elif kind == "moon-binstall":
        extra = {
            "installer.mbt": (f'println("moon-binstall {old}")', f'println("moon-binstall {new}")'),
        }
    else:
        extra = {}
    for name, (old_value, new_value) in extra.items():
        path = root / name
        text = path.read_text(encoding="utf-8")
        if text.count(old_value) != 1:
            raise ValueError(f"{name}: expected exactly one version marker {old_value}")
        changed[path] = text.replace(old_value, new_value, 1)
    return "v" + new, changed

def main():
    cli = argparse.ArgumentParser(description="Validate and bump MoonBit release version")
    cli.add_argument("action", choices=("read", "check-tag", "bump"))
    cli.add_argument("--kind", choices=("moon-binstall", "turtles", "hotpath", "dsh"), required=True)
    cli.add_argument("--root", type=Path, default=Path("."))
    cli.add_argument("--tag")
    args = cli.parse_args()
    root = args.root.resolve()
    if args.action in ("read", "check-tag"):
        version, _ = parse_version((root / "moon.mod").read_text(encoding="utf-8"))
        tag = "v" + version
        if args.action == "check-tag" and args.tag != tag:
            raise ValueError(f"tag {args.tag!r} does not match moon.mod ({tag})")
        print(tag)
    else:
        tag, changes = changes_for(root, args.kind)
        for path, content in changes.items():
            path.write_text(content, encoding="utf-8")
        print(tag)
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"release-version: {error}", file=sys.stderr)
        sys.exit(1)
