# Changelog

## Unreleased

### Added

### Changed

### Fixed

### Deprecated

### Removed

### Security

### Migration

## 0.4.2 (candidate for review)

### Improved

- Recognize Homebrew's `gtimeout` for process-group cancellation when it is installed.

### Fixed

- Continue with direct-process cancellation when neither `timeout` nor `gtimeout` is executable, instead of aborting while probing for a helper. This lets native macOS runs proceed without GNU coreutils.
- Classify GNU timeout's KILL expiry as `TIMEOUT` while preserving an ordinary child exit status of 137 as a command failure.

### Packaging

- Point the module metadata and GitHub install examples at the maintained `gpui-mbt/turtles.mbt` repository; the Mooncakes package remains `f4ah6o/turtles`.
- Run native check, unit-test, and mutation-fixture coverage on Apple Silicon macOS, including the no-GNU-timeout runner path.

- Verify that the Darwin release runner and packaged turtles executable are arm64 before uploading the artifact.

## 0.4.0 (candidate for review)

### Added

- Target-aware mutation selection via `--target`, using Moon's own test dry-run plan to identify source files active for the selected backend. Target-inactive mutants are reported separately and excluded from the score.
- Opt-in survivor analysis with `--emit-properties`, `--pbt-witness`, and `--pbt-amplify` to suggest properties, search for differential QuickCheck witnesses, and rerun property tests with a larger budget.
- An experimental, bounded source-exact MoonBit verification companion and deterministic PBT regression/remutation tooling for a small profile of helpers. This remains separate from the default mutation-testing command and score.

### Improved

- `--iterate` now rejects stale verdicts when any source, test, package manifest, or configuration fingerprint changes, and does not reuse outcomes across targets or Moon versions.
- JSON reports remain schema 3 and now include target-inactive mutant details where applicable.

### Packaging

- Add `moonbitlang/moon_config@0.4.0` for Moon package configuration and target-plan support.
- Keep the default `turtles` run unchanged; all new analyses are opt-in.
