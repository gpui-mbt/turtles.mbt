# turtles

Mutation testing for MoonBit projects — the `cargo-mutants` idea, implemented entirely in MoonBit and adapted to `moon test`.

`turtles` finds small source-level changes ("mutants"), applies them one at a time in a **temporary copy** of your MoonBit module, and asks your tests to catch them. Surviving mutants point at behavior your tests don't actually pin down. Your working tree is never intentionally modified.

See [CHANGELOG.md](CHANGELOG.md) for release notes.

## Install

The supported way to install `turtles` is `moon install`, which builds the native executable from source (requires the MoonBit toolchain). It puts a `turtles` binary in `~/.moon/bin` (the same directory `moon` itself lives in, so it is usually already on `PATH`). Override the destination with `--bin <DIR>`.

### Stable — Mooncakes

The registry package is the default install path. The 0.4.0 release candidate's pinned install command is:

```sh
moon install f4ah6o/turtles/cmd/turtles@0.4.0
```

### Development — GitHub

```sh
moon install https://github.com/f4ah6o/turtles.git cmd/turtles --branch main
```

Install from the matching source tag after it is created:

```sh
moon install https://github.com/f4ah6o/turtles.git cmd/turtles --tag v0.4.0
```

### From a local clone

```sh
moon install ./cmd/turtles
```

## First run in 30 seconds

```sh
turtles --version          # turtles 0.4.0
turtles --help

cd path/to/your-moonbit-module
turtles --dir .            # or: turtles --list to preview the mutation set
```

Every mutant runs in its own temporary workspace; on a small module the whole run takes seconds.

## Typical local usage

```sh
turtles --dir .                    # run all discovered mutants
turtles --dir . --list             # preview mutations without running tests
turtles --dir . --file src/parser  # only mutate paths containing TEXT
turtles --dir . --target native     # run only what moon compiles for native
turtles --dir . --target js --list  # preview the js-active mutation set
turtles --dir . --timeout 120      # per-command timeout in seconds (default 60)
turtles --dir . --json report.json # machine-readable report (schema 3)
turtles --dir . --iterate          # reuse KILLED/UNVIABLE outcomes from the last run
turtles --dir . --affected         # run only tests that can observe each mutant
turtles --dir . --emit-regressions # write regression-test templates for property kills
turtles --dir . --emit-properties  # write property-test skeletons for survivors
turtles --dir . --pbt-witness      # differential QuickCheck witness for survivors
turtles --dir . --pbt-amplify 4    # re-run survivor properties with 4x budget
turtles --dir . --timeout-multiplier 3   # per-phase timeout = 3x the measured baseline (min 10s)
```

### Parallel execution

```sh
turtles --dir . --jobs 4
```

`--jobs N` runs up to `N` mutants concurrently (validated as a positive integer; default `1`). Each worker gets a persistent `worker-N` workspace with a warm `_build`, restored to its snapshot after every mutant, and the baseline `moon check` + `moon test` runs exactly once before any mutant. Results and the JSON report are always ordered by discovery order, not completion order — parallelism never makes reports flaky.

`--target` passes the selected MoonBit backend to the baseline, mutant checks and tests, the `--affected` test plan, and mutant selection itself. Moon's own `moon test --dry-run` plan decides which source files compile for the backend — mutants in files it does not select are reported **target-inactive**: visible in the console and report, never classified (so they can never inflate the survivor set), and excluded from the score. `--target all` unions Moon's standard backends, `--target js --list` previews exactly what a js run would classify, and any non-empty target value is forwarded for moon to validate — turtles keeps no backend list. The report records the target, and `--iterate` never reuses verdicts from another target.

Note that `moon` itself already parallelizes a single build; `--jobs` parallelizes *across mutants*, so values above ~2× your CPU count only add contention.

## CI usage

Install a pinned release and run turtles against your module:

```sh
moon install f4ah6o/turtles/cmd/turtles@0.4.0
turtles --dir . --fail-under 80 --json turtles-report.json
```

By default turtles exits `1` when any mutant survives or times out — the right behavior once a codebase is clean, but awkward when introducing mutation testing to an existing suite. Use `--fail-under` to ratchet the bar gradually:

```sh
turtles --dir . --fail-under 80
```

- `score >= threshold` → exit `0`, even if survivors exist.
- `score < threshold` → exit `1`.
- Setup or baseline failures → exit `2` regardless of thresholds.
- Without `--fail-under`, the previous rule applies: exit `1` on any `SURVIVED` or `TIMEOUT` mutant.

The range `0..100` is validated; fractional values like `--fail-under 79.5` are accepted.

### Mutation score semantics

```
score = killed / viable * 100     where viable = killed + survived + timeout
```

- `UNVIABLE` mutants (which fail `moon check`) are excluded from the score entirely.
- Target-inactive mutants (files the selected `--target` does not compile) are excluded too — they are never classified.
- `TIMEOUT` mutants count as *not killed* — a mutant that makes your tests hang drags the score down instead of being silently forgiven.
- An empty mutation set scores `100`.

## Reading results

Per mutant, turtles reports `path:line:column`, `original -> replacement`, and its operator group:

- comparisons: `== ↔ !=`, `> → <`, `< → >`, `>= → <`, `<= → >`
- boolean logic: `&& ↔ ||`
- arithmetic: `+ ↔ -`, `* ↔ /`, unary `-x → +x`
- boolean literals: `true ↔ false`
- conditions: whole `if` conditions → `true` or `false`
- bodies (opt-in `body` group): a whole function body → a trivial literal of the declared return type (`0`/`1`/`-1` for signed ints, `0`/`1` for unsigned, `true`/`false` for `Bool`, `0.0`/`1.0` for floats, `""`/`"xyzzy"` for `String`, `()` for `Unit` or omitted annotations, `None` for `T?`/`Option[T]`, `[]` for `Array`/`FixedArray`, `{}` for `Map`)

Outcome classification:

- **KILLED** — `moon check` succeeded and `moon test` failed.
- **SURVIVED** — both commands succeeded; tests did not detect the change.
- **TIMEOUT** — checking or testing exceeded the configured timeout.
- **UNVIABLE** — `moon check` rejected the mutated source.

After the summary counts, every `SURVIVED`/`TIMEOUT` mutant is reprinted under `Mutants needing attention:` so the actionable list is at the end of the output.

Every run writes a schema-`3` report and per-survivor unified diffs to `<dir>/.turtles/` (which git-ignores itself): `report.json` plus `survivors/<id>.diff` for each surviving or timed-out mutant. The report adds stable mutant `id`s (FNV-1a over path + byte offsets + original + replacement + group), per-phase baseline durations (`baseline_check_ms`/`baseline_test_ms`), `test_scope`, a `files` fingerprint map, `skipped_files`, `reused` counts, the selected `target` (`null` when `--target` is omitted), and `inactive_mutants`/`inactive_files` for mutants Moon does not compile under that target:

```json
{
  "schema": 3,
  "module": "/abs/path",
  "turtles_version": "0.4.0",
  "moon_version": "moon 0.1.20260920 (914d7da 2026-09-20) ~/.moon/bin/moon",
  "target": "native",
  "inactive_mutants": 1,
  "inactive_files": ["js_only.mbt"],
  "baseline_duration_ms": "216",
  "baseline_check_ms": "70",
  "baseline_test_ms": "146",
  "test_scope": "module",
  "mutants": [
    { "id": "m-e7ccdf47c3b8bc0b", "path": "math.mbt", "line": 3, "column": 5,
      "offset": 47, "end": 48, "group": "arithmetic",
      "original": "+", "replacement": "-", "outcome": "KILLED",
      "duration_ms": "202", "reused": false }
  ],
  "summary": { "killed": 6, "survived": 0, "timeout": 0, "unviable": 0,
               "reused": 0, "score": 100 }
}
```

### Survivor analysis (opt-in)

Three opt-in analyses split the `SURVIVED` bucket — all off by default, so a plain run changes nothing:

- `--emit-properties` writes `<output>/properties/<mutant-id>.mbt` skeleton tests for survivors whose parameter and return types have `Arbitrary + Shrink + Debug` instances. The shape is chosen from the signature: idempotence + involution for `(A) -> A`, commutativity + associativity for `(A, A) -> A`, a round-trip for `encode`/`decode`-style pairs, otherwise a `@quickcheck.check` stub over the parameter tuple. Each generated file starts with the marker `// turtles: generated property suggestion` plus the producing target; each run sweeps marker-bearing files that are no longer in the live set (a target switch removes a native-only mutant's suggestion) while never touching unmarked files. User tests are never edited — drop a skeleton into the package's tests when it looks right.
- `--pbt-witness` runs a differential witness on eligible survivors: for each surviving `fn f`, a temporary workspace gets a renamed copy of the original body plus a white-box `@quickcheck.check(args => f(args) == f__turtles_orig(args))` and a determinism guard. If QuickCheck falsifies the equivalence, the counterexample is recorded as `"witness"` — strong evidence the mutant is a real gap. Ineligible survivors report `witness_skipped`: `"effects-unknown"` (mutable state, async, non-core calls, trait dispatch — anything the call-graph analysis cannot prove pure), `"recursive"` (the fn sits in a recursive SCC — an unbounded self-rewriting copy could diverge), `"cfg"` (a `#cfg(...)` declaration), `"nondeterministic"` (the guard falsified — `f(args) != f(args)`), `"name-collision"` (no collision-safe helper name left after 16 tries) or `"harness-error"`. `witness`/`witness_skipped` fields appear only on survivors the analysis ran for; `witness: "none"` means the harness ran and did not falsify.
- `--pbt-amplify <N>` re-runs each survivor's module tests with the property budget scaled ×`N` (`count = 100*N`, or `existing*N` for explicit counts) and seeds shifted, in a temporary workspace. A mutant killed only after amplification reports `KILLED` with `"amplified": true`.

All three respect `--target`: every Moon invocation is forwarded through the same target-aware helper, target-inactive mutants get no analysis, and `--iterate` never reuses witness/suggestion/amplification results across a target change. The witness harness is appended to the mutated copy of the function's own file, so it inherits that file's `targets` applicability — `--target all` compiles it on every backend where the function exists.

`--output-dir <path>` relocates the report directory; `--json` additionally writes a plain report anywhere for CI. `--iterate` loads the previous `<output-dir>/report.json` and reuses `KILLED`/`UNVIABLE` outcomes for mutants whose file content hash and identity tuple are unchanged (marked `"reused": true`); `SURVIVED`/`TIMEOUT` mutants always re-run. Reuse is refused wholesale when the schema, turtles version, moon version, or selected target differ, or when *any* fingerprinted file changed since the report — sources, tests, `moon.pkg`, `moon.mod`, `turtles.toml` — since a verdict may owe its outcome to a file the mutant never touches. `--affected` is opt-in test selection: it parses `moon test --dry-run` to learn the package graph and runs `moon test -p` on just the mutated package plus packages whose test targets transitively link it, falling back to a module-wide run whenever resolution is uncertain. Under an explicit `--target` that same target-aware dry-run is what marks inactive mutants, so selection and test planning can never disagree. An empty mutation set still produces a schema-3 report with `mutants: []`; `--list` never runs tests.

## Kill attribution and determinism

Every test run turtles drives — baseline and mutants alike — goes through `moon test --test-failure-json`, which prints one JSON record per failing test. `turtles` never passes `--update`/`-u`, so a snapshot expectation can never be silently rewritten mid-run.

For each `KILLED` mutant the report adds a `killed_by` array attributing the kill to concrete tests. Each entry carries `package`, `filename`, `index`, `test_name`, a `kind` (`"Property"`, `"Snapshot"`, `"DocTest"`, or `"Assertion"`), and for property kills the shrunk `counterexample` string. On moon 0.1.20260920 doc tests report an empty `test_name` — `.mbt.md` files under their own filename, docstring `mbt check` blocks under the source `.mbt` file — which is how `DocTest` is detected. If the structured stream is missing or unparseable (older moon, crashed test binary, abort before tests ran), the verdict still comes from the exit status and the row carries `"killed_by": []` with `"attribution": "unavailable"`. The summary gains `kills_by_kind` (per-kind kill counts) and `property_only_kills` — mutants only a QuickCheck property caught, the headline value of PBT.

With `--emit-regressions`, every mutant killed by a property with a shrunk counterexample also gets a `regressions/<mutant-id>.mbt` template in the output directory: a paste-ready black-box `test` block recording the counterexample, the killing test's location, and the mutant's edit, ready to fill in with a call to the function under test. The report's additive `regressions` field lists the emitted paths. The flag only writes into the output directory — the module's own test files are never touched — and stale templates are swept on each opt-in run.

The baseline runs the test suite **twice** on the pristine copy, restoring the workspace snapshot in between so each run sees the state every mutant starts from. If the two runs disagree on which tests fail, the run aborts as a setup error naming the unstable tests — a flaky oracle would make every verdict meaningless. Keep QuickCheck's fixed default seed or pass an explicit `seed~`; never derive seeds from time in tests used as a mutation oracle.

## Configuration

If `turtles.toml` exists in the target MoonBit module root, turtles reads mutation selection from it before scanning sources.

```toml
include = ["src/", "lib/"]
exclude = ["generated/", "vendor/"]
operators = ["comparison", "boolean", "arithmetic", "literal", "condition"]
```

- `include`: optional path substrings; when non-empty, at least one must match the normalized relative source path.
- `exclude`: optional path substrings; matching sources are skipped.
- `operators`: optional operator groups. Supported groups are `comparison`, `boolean`, `arithmetic`, `literal`, `condition` (whole-`if`-condition replacement), and `body` (function-body replacement). `boolean` covers only logical `&&`/`||`; selecting `condition` alone gives structural mutations without logical ones, and vice versa. `body` is never enabled implicitly — with no `operators` list every group *except* `body` runs.
- CLI `--operators <LIST>` takes a comma-separated group list and replaces the `turtles.toml` list wholesale, e.g. `turtles --dir . --operators body,comparison`.

The `body` group skips functions it has no typed literal for — user-defined types, `Result`, tuples, type parameters — rather than generating UNVIABLE mutants, and it never touches `test` blocks, `async` functions, `extern`/FFI declarations, or bodies that are already a single trivial literal.

### Skipping blocks

A top-level block is excluded from mutation discovery when it carries the `#turtles.skip` attribute, or when a `// turtles: skip` line comment leads it (the comment also works inside the block's body):

```mbt
///|
#turtles.skip
pub fn fragile() -> Int {
  1 + 2
}

// turtles: skip
///|
pub fn also_skipped() -> Int {
  3 + 4
}
```

`--list` reports how many blocks were skipped this way.

- CLI `--file` remains an additional filter on top of `turtles.toml`.
- Test files remain excluded by default and cannot be enabled through this configuration.

The configuration parser intentionally supports a small TOML-compatible subset: top-level arrays of double-quoted strings, comments, trailing commas, and multiline arrays. Unknown keys and operator groups are rejected instead of silently ignored.

## Safety model

`turtles` never runs tests in the module's working tree. The module is copied into a temporary directory, excluding `.git`, `target`, `_build`, `.mooncakes`, `.moon`, and `node_modules`. The copy keeps the caller's read/write/execute permissions on files and directories and recreates symlinks that resolve inside the module as links; symlinks that point outside the module are dereference-copied so writes cannot escape the workspace, and dangling links are a hard error.

The first copy is a pristine `reference` tree, snapshotted before any test executes. The baseline runs `moon check` and `moon test` on a disposable `baseline` copy of that reference — a failure there is a setup error (exit `2`), not a mutant outcome — so state written by the baseline cannot leak into mutants either. Each mutant then runs in one of `jobs` persistent `worker-N` workspaces copied once from `reference`: the mutation is written in place, classified, and the workspace is swept back to its manifest snapshot — recorded bytes are restored and any file the snapshot did not contain is deleted — so state written by earlier runs (sentinels, caches, generated files) cannot leak into later classifications, and mutant order cannot change results. `_build` stays warm inside each workspace, which is where most of the speedup comes from. This holds under `--jobs N` as well: workers share the read-only `reference` and never share a workspace. The temporary directory is removed when the run finishes.

Nested MoonBit modules — child directories carrying their own `moon.mod`/`moon.mod.json` — are excluded from discovery: the root module's `moon test` cannot reach their code, so their mutants would falsely survive.

On Windows, symlinks require privilege elevation and are dereference-copied instead of recreated.

## Implementation notes

`turtles` itself is a native MoonBit executable. The CLI, configuration parser, mutation discovery/application, temporary-workspace handling, subprocess execution, timeout handling, bounded parallelism, classification, and JSON reporting are all written in MoonBit. There is no Rust or Cargo implementation.

The project currently uses:

- `moonbitlang/async` for subprocess execution, cancellation, timing, the worker-pool task group, and async filesystem operations
- `moonbitlang/parser@0.4.0` for syntax-aware mutation candidate discovery
- `moonbitlang/x` for native path/system support
- `moon check` and `moon test` for mutant classification

Comments, strings, character literals, test files (`*_test.mbt`, `*_wbtest.mbt`), generated/build directories, and function arrows are excluded by syntax rather than lexical heuristics. Candidate discovery is driven by the pinned experimental parser AST; parser diagnostics abort discovery instead of triggering a lexical fallback. The unstable API is confined to `cmd/turtles/scanner.mbt`; see `docs/moonbit-parser.md`.

## Development

### Experimental proof companion

An opt-in source-checkout companion combines source-exact helper mutation,
independent model tests, the reviewed official MoonBit→Why3→Z3 export backend,
and deterministic PBT regression/remutation replay. Its first profile covers
only three GPUI range/Unicode helpers. It keeps runtime kills and actual proof
counterexamples separate and does not change the native default command or
existing reports. See [the bounded profile and its limitations](docs/moonbit-verification-profile.md).

The native engine checks are:

```sh
moon update
moon fmt --check
moon check --target native --deny-warn
moon test --target native
moon -C fixtures/basic test
moon run cmd/turtles -- --dir fixtures/basic --timeout 30
```

The real fixture E2E also validates schema-3 JSON report generation, deterministic ordering under `--jobs`, `--fail-under` exit codes, and target-aware selection on `fixtures/targets` (`--target native|js|all` for `--list` and full runs, including cross-target `--iterate` reuse refusal).

## Planned follow-ups

JUnit reports, richer survivor context, and smarter default test selection are still open. Prebuilt release binaries remain out of scope — turtles needs the MoonBit toolchain at runtime anyway.

## Patch release from `latest`

Move the `latest` tag to the current `main` commit and push it:

```sh
git switch main
git pull --ff-only origin main
git tag -f latest HEAD
git push --force origin refs/tags/latest
```

The `latest` event runs the patch version bump, updates `moon.mod` (and
the CLI version constant, when present), atomically pushes the version
commit with a fixed `vX.Y.Z` tag, builds Linux x64/ARM64 and macOS ARM64
assets, and publishes the versioned GitHub Release. `latest` is a trigger,
not a Release tag.

The workflow refuses stale main/tag targets or an existing version tag,
and rerunning the same failed release reuses its tagged version commit.
The token must be allowed to push to `main`; branch protection is not
bypassed. Direct `vX.Y.Z` tag pushes are still supported when the tag
matches the version recorded in `moon.mod`.

