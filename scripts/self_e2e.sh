#!/bin/sh
# turtles self-verification gate.
#
# Run the (possibly mutated) turtles binary against fixtures/basic and
# check its schema-3 report through the standalone MoonBit validator.
# The fixed fixture path prevents self-mutation from recursing into ".".
#
# Required on PATH: moon. No Python interpreter is needed.
set -eu

report_dir="$(mktemp -d)"
trap 'rm -rf "$report_dir"' EXIT

validate() {
  moon run scripts/self_report.mbtx -- "$1"
}

# Existing output directory (detect a missing allow_exist=true).
moon run cmd/turtles -- --dir fixtures/basic --timeout 60 \
  --json "$report_dir/report.json"
validate "$report_dir/report.json"

# Nonexistent nested output directory (detect a missing recursive=true).
moon run cmd/turtles -- --dir fixtures/basic --timeout 60 \
  --json "$report_dir/nested/deep/report.json"
validate "$report_dir/nested/deep/report.json"
