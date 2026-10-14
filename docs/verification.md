# turtles' own verification harness

turtles verifies itself with the same machinery it applies to other projects,
plus property-based tests and an end-to-end binary check:

1. **Unit tests** (`*_wbtest.mbt`) — deterministic behavior checks.
2. **Official QuickCheck PBT** (`*_pbt_wbtest.mbt`) —
   `moonbitlang/core/quickcheck` `@quickcheck.check` properties over pure
   invariants: fingerprints and identity tuples, kill attribution, regression
   templates, UTF-8 boundary construction, mutation application, mutation
   discovery, path filtering, and config round-tripping. The property suite is
   imported `for "wbtest"` only, so production builds never depend on it.
3. **Mutation testing** — turtles runs itself (see *Self-mutation* below).
4. **`scripts/self_e2e.sh`** — black-box check of the built binary's JSON
   report (see *Binary e2e* below).

## Self-mutation

The root `turtles.toml` is the checked-in self-verification config:

```toml
include = ["cmd/turtles/"]
```

Run it with a generous per-command timeout (each mutant pays a `moon check`
plus `moon test` of the whole module, including the property suite):

```sh
moon run cmd/turtles -- --dir . --timeout 300 --json target/turtles-self.json
```

`--jobs <n>` parallelizes across warm per-worker workspaces, and `--iterate`
reuses KILLED/UNVIABLE verdicts from a previous `.turtles/report.json` so
repeated self-runs stay cheap.

CI bounds the dogfood to `cmd/turtles/fingerprint.mbt` — a small file whose
three mutants are deterministic kills — so the gate stays fast while still
exercising the full pipeline: discovery, workspace copy, baseline, per-mutant
check + test, outcome attribution, and the JSON report.

### Survivors and the baseline

Expect some self-mutants to survive; that is the point of the exercise. When
triaging a self-run survivor, classify it rather than weakening operators or
hiding production files to reach green:

- **Equivalent mutant** — e.g. flipping an empty-input guard such as
  `if mutations.is_empty()`: the `cond → false` form only differs for modules
  without mutations, which the fixture sweep never produces. Document
  confirmed-equivalent survivors here.
- **Test gap** — the mutant changes observable behavior no test asserts on.
  Add coverage in `*_wbtest.mbt` (or extend `scripts/self_e2e.sh` assertions
  for binary-level behavior) rather than excluding the file.
- **Unobservable** — purely cosmetic output mutations (progress counters,
  formatting) that no gate observes. Tolerable; document them here.

## Binary e2e

`scripts/self_e2e.sh` runs `moon run cmd/turtles` against `fixtures/basic`
and validates the JSON report with `scripts/self_report.mbtx` (schema, six
fixture mutants, zero survivors/timeouts/unviables). It catches defects unit
tests miss — a binary that exits successfully but produces a wrong report
fails the assertions. This E2E uses only MoonBit and POSIX shell, not Python.
Run `moon test scripts/self_report.mbtx` to test the standalone MoonBit report
validator independently.

The checkout-free consumer matrix tests published 0.4.7 through both Mooncakes
and native assets on Linux, macOS Apple Silicon, and Windows. Each consumer
fixture starts without a build cache, with Python commands blocked. The
Windows runner opts out of optional Visual Studio telemetry through the
[documented SQM settings](https://learn.microsoft.com/en-us/visualstudio/ide/visual-studio-experience-improvement-program#registry-settings),
including the policy and version-specific registry keys. The installed
toolchain version is resolved with `vswhere`.
This CI setting investigates the initial Windows native-asset baseline
timeout: the registry route passed and left a `vctip` helper at job cleanup,
but their causal relationship is not established. The fixture is not
pre-built, and the CLI's process-tree timeout and cleanup checks remain
enabled.

The script runs the fixture sweep twice with different `--json` targets so
both `mkdir` flag mutants in report writing stay reachable: the first report
lands in an existing directory (a dropped `allow_exist=true` fails), the
second in a nested non-existent directory (a dropped `recursive=true` fails).

Because the script targets the *current* working directory's binary, running
it inside a mutated workspace — as a custom gate command once per-mutant
command gates exist — rebuilds and exercises the *mutated* binary. The
fixture path is hard-coded inside the script and the inner run uses the
default `check`/`test` classification, so self-mutation cannot recurse.

## JSON report schema

Schema `3` records, per mutant: `id`, `path`, `line`, `column`, `offset`,
`end`, `group`, `visibility`, `original`, `replacement`, `outcome`,
`duration_ms`, `reused`, plus optional `packages`, `killed_by`, and
`attribution`. The report header carries `module`, `turtles_version`,
`moon_version`, `target`, baseline phase durations, `test_scope`, per-file
fingerprints, `skipped_files`, and `regressions`; the summary adds `reused`,
`kills_by_kind`, `property_only_kills`, and the public/private visibility
split. Target-aware classification adds `inactive_mutants` and
`inactive_files`, excluded from the mutation score. Optional PBT fields
record witnesses, skipped witnesses, amplified kills, and property files.
Schema-2 reports are not reusable with `--iterate`.

## PBT regression acceptance

`python3 scripts/pbt_acceptance.py` checks amplified kill provenance, an
amplified pristine control, individual/combined flags, source and manifest
restoration, property live lists, and native/js/wasm/wasm-gc/all target isolation.
Amplification-derived verdicts are always rerun by `--iterate`, regardless of
factor. Amplification only rewrites qualified core QuickCheck imports visible
to each source/test/white-box scope. Bare names are conservatively left alone.
If the amplified original fails or times out, a warning identifies the mutant
and amplification leaves its original verdict unchanged.
