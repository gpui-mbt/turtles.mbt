# Migrate contributor-only Python tools to MoonBit where parity is provable

- Priority: P2 for routine test harnesses; P3 for experimental proof tooling
- Scope: developer/CI scripts only, not the installed turtles CLI
- Status: open; `scripts/self_report.mbtx` is the first small port

## Context

The released CLI is already a native MoonBit executable. Its dependencies do not
include Python and it does not need a turtles source checkout.
`moon install f4ah6o/turtles/cmd/turtles@0.4.7` provides the supported consumer UX.
Version 0.4.7 is published on Mooncakes and fixes the obsolete dependency
manifest in 0.4.6. CI covers both registry installation and native release
assets on Linux, macOS Apple Silicon, and Windows without a turtles checkout.

The remaining Python files are **not** runtime dependencies. Removing them can
reduce contributor-toolchain diversity, but rewriting them is **not** required
for a portable, clone-free CLI. Avoid a risky bulk translation.

## Workstreams

1. **Routine test harnesses:** port `timeout_smoke.py`,
   `darwin_timeout_smoke.py`, `windows_smoke.py`,
   `windows_job.py`, and `pbt_acceptance.py` to MoonBit scripts or
   native MoonBit test packages. Preserve process-tree handling, timeouts,
   exit codes, platform skips, source-fingerprint checks, and negative tests.
   Prefer `.mbtx` for standalone command runners and package tests for pure
   validators.
2. **CI JSON assertions:** replace the remaining inline Python JSON checks in
   `.github/workflows/ci.yml` with typed MoonBit validation or an equivalent
   test, without relaxing schema/output assertions. The six-kill binary E2E
   validator is already covered by `scripts/self_report.mbtx`.
3. **Release guards:** migrate `release_version.py` and its tests only after
   parity for version/tag/asset validation, non-2xx handling, malformed and
   conflicting API responses, and no premature publication is demonstrated.
   Never weaken the tag/release safety invariants to remove Python.
4. **Experimental proof companion:** assess `verify_moon_profile.py` and
   its adversarial tests separately. It is intentionally checkout-only and
   currently depends on external proof tools. Port only with equivalent
   cancellation, provenance, artifact-isolation, and replay protections.

## Acceptance criteria

- A published native release executable runs from an unrelated directory
  with Python commands blocked and without checking out turtles.
- A separately published, updated Mooncakes package resolves all its
  dependencies under the current MoonBit toolchain before claiming registry
  install compatibility; do not equate a working native asset with a working
  Mooncakes source-package install.
- For each ported script, positive **and** negative cases run in CI;
  platform-specific runs remain on the corresponding runners.
- Existing Python test gates are retained until MoonBit replacements pass.
- `moon check --target native --deny-warn`, `moon test --target native`,
  `moon test scripts/self_report.mbtx`, and the fixture E2E pass.
- `moon.mod`, runtime flags, schema 3, and published release behavior do not
  change as an unintended side effect.
