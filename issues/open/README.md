# Open implementation tasks

Status: four new proposals as of 2026-10-13 (JST). These records add no runtime
features. Their source baseline is [`6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2`](https://github.com/gpui-mbt/turtles.mbt/commit/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2)
(`turtles` 0.4.6).

## Prioritized proposals

| Priority | Task | Value | Dependency |
| --- | --- | --- | --- |
| P1 | [Comparison boundary mutations](20261013-comparison-boundary-mutations.md) | Expose equality-edge test gaps without changing the default mutant set | Independent |
| P1 | [Diff-aware mutation selection](20261013-diff-aware-mutation-selection.md) | Restrict PR feedback to validated changed source regions | Shared selection boundary |
| P1 | [Persistent run diagnostics](20261013-persistent-run-diagnostics.md) | Retain baseline/phase evidence and distinguish failed runs from completed reports | Independent; provides output ownership |
| P2 | [Deterministic CI sharding](20261013-deterministic-ci-sharding.md) | Partition mutation work across explicit CI jobs | Diagnostics ownership; compose with diff selection |

Implement P1 packets independently where possible. Sharding follows the
output-ownership primitive; it need not wait for diff selection to exist, but
must compose with it when present. These are proposed implementation units, not
a promise of full cargo-mutants compatibility.

## Codebase map used for this assessment

| Responsibility | Current implementation |
| --- | --- |
| CLI/configuration and orchestration | [`config.mbt`](../../cmd/turtles/config.mbt), [`main.mbt`](../../cmd/turtles/main.mbt), [`types.mbt`](../../cmd/turtles/types.mbt) |
| AST candidates, byte spans, skip markers, body replacement | [`scanner.mbt`](../../cmd/turtles/scanner.mbt); pinned parser boundary documented in [`moonbit-parser.md`](../../docs/moonbit-parser.md) |
| Temporary reference, per-worker restoration, check/test classification, timeout handling | [`runner.mbt`](../../cmd/turtles/runner.mbt), [`fs_ops.mbt`](../../cmd/turtles/fs_ops.mbt) |
| Moon target-active sources and observing-package selection | [`plan.mbt`](../../cmd/turtles/plan.mbt), runner integration |
| Kill attribution and survivor analyses | [`oracle.mbt`](../../cmd/turtles/oracle.mbt), [`amplify.mbt`](../../cmd/turtles/amplify.mbt), analysis integration in runner |
| Complete reports, survivor diffs, conservative prior-result reuse | [`report.mbt`](../../cmd/turtles/report.mbt), [`iterate.mbt`](../../cmd/turtles/iterate.mbt) |

The normal pipeline is configuration -> AST discovery -> target/test planning ->
pristine baseline validation -> isolated mutant execution -> optional survivor
analyses -> report and exit decision. Listing stops before baseline/classification.
The native executable package is [`cmd/turtles/moon.pkg`](../../cmd/turtles/moon.pkg);
it also contains the existing Windows and Darwin native process stubs.
MoonBit source-package metadata is in [`moon.mod`](../../moon.mod).

This assessment is based on source inspection, not a newly executed runtime
qualification. Existing release/CI claims remain attributable to their own runs.

## cargo-mutants comparison and scope decisions

The [cargo-mutants book](https://mutants.rs/) was reviewed for mutation patterns,
selection/configuration, output, baseline and workspace handling, iteration,
timeouts, performance, sharding, and incremental PR testing.

| Area | turtles at the inspected baseline | Decision |
| --- | --- | --- |
| Syntax-aware discovery, Boolean/arithmetic/comparison operators | Implemented via pinned MoonBit parser | Extend narrowly with opt-in boundary cases |
| Whole-function replacement and skip annotations | Implemented; body group is opt-in and supported-type bounded | Do not re-propose the basic feature |
| Parallel workers, warm workspaces, baseline validation | Implemented | Preserve isolation and deterministic result order |
| Target-aware mutation selection and observing-package tests | `--target` and opt-in `--affected` implemented | Do not replace Moon's plan with guessed dependencies |
| Iteration and adaptive timeouts | `--iterate` and `--timeout-multiplier` implemented | Keep complete-input reuse guards |
| JSON, stable identities, survivor diffs, kill attribution, PBT analyses | Implemented | Add diagnostic evidence, not another duplicate report format |
| Changed-region selection | No `--in-diff` | New proposal |
| Independent CI partitioning | No `--shard`; `--jobs` is local concurrency | New proposal |
| Durable command logs and run progress | Command output is temporary; completed report is end-of-run | New proposal |
| Rust-specific Cargo/nextest flags, `Default`-based replacement rules | Not MoonBit interfaces | Do not copy language-specific APIs literally |
| In-place mutation and baseline bypass | Not selected for these tasks | Do not weaken the pristine-workspace oracle |
| JUnit, richer context, default test-selection changes | Mentioned as follow-ups in the main README | Deferred; not implicitly implemented or closed here |

Feature-specific upstream references are
[boundary additions](https://mutants.rs/changelog.html),
[diff selection](https://mutants.rs/in-diff.html),
[output artifacts](https://mutants.rs/mutants-out.html), and
[sharding](https://mutants.rs/shards.html).
Upstream documentation and changelog describe their own behavior; all new
turtles-specific CLI/report contracts are proposals in these task records.

### Duplicate reconciliation

`issues/open` and `issues/polished` each contained only an index at inspection.
The GitHub issue search returned no issue records; the open PR search returned
[PR #29](https://github.com/gpui-mbt/turtles.mbt/pull/29), a process-cleanup task
proposal. Main already contains newer platform cleanup work; do not restate
PR #29 as an unverified current failure or duplicate it here.

PRs #25, #26, and #27 previously closed their selected milestones. Their
records remain in [`../closed/`](../closed/), including
[practical value](../closed/20260928-practical-value-milestone.md),
[MoonBit/PBT integration](../closed/20260929-moonbit-idioms-and-pbt-integration.md),
[survivor analysis](../closed/20260930-pbt-survivor-analysis.md), and
[target-aware mutation testing](../closed/20260930-target-aware-mutation-testing.md).
A merged milestone's deferred ideas are not implicitly new implementation tasks.

## Shared selection and reporting contracts

1. Apply path/operator/skip selection, optional validated diff selection, Moon's
   target-active partition, and optional sharding in that order. Reuse is decided
   against the resulting identities without changing candidate ownership.
   Listing and execution share selection helpers.
2. Never narrow the full input fingerprint map merely because fewer mutants or
   tests are executed. Keep target/tool-version checks and the existing ban on
   reusing survivors, timeouts, and amplification-derived kills.
3. Keep selected-out, target-inactive, and not-yet-executed candidates distinct.
   A subset score is not a full-module score; an interrupted execution is not a
   completed subset report.
4. Preserve existing mutation IDs and default behavior. Any additive report
   metadata needs an explicit format/version contract and round-trip tests.
   A semantic schema change needs a schema migration, not an undocumented extra
   field. Diagnostic progress is never an input to complete-report reuse.
5. Source changes outside this docs-only PR must include exact validation
   evidence. Test plans and expected outcomes are not executed test results.

## MoonBit implementation rules

Reference: the official
[MoonBit agent guide at the inspected revision](https://github.com/moonbitlang/skills/blob/8b9f1bad14bc62560dbe3537855379e561a4e066/skills/moonbit-agent-guide/SKILL.md).

1. Work within the enclosing `moon.mod` / `cmd/turtles/moon.pkg` package.
   File names do not create namespaces. Prefer focused files separated by
   `///|`, and keep unstable parser APIs behind the scanner boundary.
2. Discover APIs with `moon ide doc`, `outline`, and `peek-def` on the actual
   toolchain before choosing an implementation. Use owned types and pure
   helpers for parsing, range selection, partitioning, and state transitions.
3. Keep UTF-8 byte ranges distinct from parser Unicode-scalar offsets and
   String indexing. Do not infer source spans with regular-expression grammar.
4. Use public black-box tests where applicable and `*_wbtest.mbt` for private
   CLI/scanner helpers. Name tests for observable behavior; use deterministic
   properties and reviewed `inspect`/`debug_inspect`/`json_inspect` snapshots.
5. New agent-authored orchestration belongs in `.mbtx`; direct shell commands
   may launch tools, but do not add new shell/Python automation logic.
   Async MoonBit code uses neither `await` nor an unnecessary explicit `raise`.
6. Run formatting, checking, focused tests, and `moon info`. Never hand-edit
   generated `.mbti` files. Review intentional snapshot changes separately;
   mutation-oracle invocations must never pass `--update` or `-u`.
7. Code should express implementation, tests the behavior established, and
   commit messages the reason for change. Comments should explain non-obvious
   rejected alternatives or constraints instead of restating code.

## Verification plan

These are future implementation checks, not results of this documentation PR:

```sh
git diff --check
moon update
moon fmt --check
moon check --target native --deny-warn
moon test --target native
moon info --target native
moon -C fixtures/basic test
moon run cmd/turtles -- --dir fixtures/basic --timeout 30
```

Review exit status against each fixture's expected mutation outcomes; a CLI
exit 1 can be intentional when the fixture contains surviving mutants. Add each
packet's narrow tests and real CLI acceptance cases. Validate native/JS/all
project-under-test selection separately from the native-only turtles executable.
Run platform-specific process/filesystem checks where the implementation changes
those paths. Record PASS, FAIL, and unexecuted checks separately.

## Workflow

1. Capture new or unresolved findings here.
2. Reconcile each task against current `main`, related PRs, and verification evidence.
3. Move actionable tasks with clear scope, dependencies, acceptance criteria,
   and a verification plan to [`../polished/`](../polished/).
4. Move completed tasks to [`../closed/`](../closed/) with a closure record.
