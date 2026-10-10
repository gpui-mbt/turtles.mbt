# Changelog

## 0.4.2

### Improved

- Normalize module-relative paths before package ownership and target-plan lookups so Windows separators do not hide nested packages.
- Exercise native Windows fixture mutation, parallel worker ordering, and target-aware filtering in CI.

### Packaging

- Publish and verify the `turtles-windows-x86_64.exe` native release asset.

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
