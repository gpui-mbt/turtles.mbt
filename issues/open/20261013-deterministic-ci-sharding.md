# Deterministic mutation sharding for CI

- Status: open proposal; no implementation in this task record
- Date: 2026-10-13 (JST)
- Priority: P2
- Inspected baseline: `6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2` (`turtles` 0.4.6)
- Dependencies: output-ownership helper from [persistent run diagnostics](20261013-persistent-run-diagnostics.md);
  shared selection ordering with [diff-aware selection](20261013-diff-aware-mutation-selection.md)
  when that option is available

## Problem and evidence

`--jobs` uses more workers inside one invocation; it does not divide work across
independent CI runners. Raising it also shares the same machine's resources.
A deterministic partition would allow an explicitly configured CI matrix
without a coordinator or a new remote service.

In [runner.mbt](https://github.com/gpui-mbt/turtles.mbt/blob/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2/cmd/turtles/runner.mbt), `run_mutation_pool` consumes
the full active set in index-aligned slots. [config.mbt](https://github.com/gpui-mbt/turtles.mbt/blob/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2/cmd/turtles/config.mbt)
has no shard option.
[cargo-mutants sharding](https://mutants.rs/shards.html) supplies the upstream
model: zero-based `k/n` selection with identical discovery inputs on each runner.
It supports slice and round-robin strategies. The bounded first version here
intentionally chooses only the deterministic round-robin strategy below.

## Proposed behavior

1. Add `--shard <k>/<n>` with integer `n > 0` and `0 <= k < n`. Reject malformed,
   repeated, overflowed, or out-of-range arguments before baseline/classification.
   `--shard 0/1` selects the full active set.

2. Establish the candidate universe after existing path/operator/skip filters,
   optional diff filtering, and Moon's target-active partition. Sort by a stable
   tuple of normalized module-relative path, byte start/end, group, original
   text, and replacement text. Define `round-robin-v1` as assigning ordinal `i`
   to shard `i % n`. Use explicit ordinal string/byte comparison, not locale
   ordering or machine-specific absolute paths.

3. Perform partitioning before `--iterate` reuse decisions. Different local
   reports must not change shard membership. Preserve stable identities and
   result ordering within each shard; `--jobs` affects execution concurrency,
   not candidate ownership. Listing uses exactly the same partition and runs
   no baseline or mutant tests.

4. Preserve current baseline validation in each executing shard, including an
   empty shard. No `--baseline=skip` or shared-baseline evidence is introduced.
   Keep target-inactive candidates distinct from active candidates assigned to
   other shards. Neither group receives a mutation outcome or affects the
   shard score.

5. Resolve reports beneath a shard-specific directory:
   `<output-base>/shards/<k>-of-<n>/`, where the base defaults to `<dir>/.turtles`
   and otherwise comes from `--output-dir`. Keep `--iterate` local to this final
   directory. An explicit `--json` destination must be unique per concurrent
   shard; use the output-ownership helper to reject collisions before writes.
   Exclude all generated output paths from source copying/fingerprints.

6. Add versioned shard metadata with `k`, `n`, algorithm, full pre-shard candidate
   count, assigned count, canonical candidate-set fingerprint, and the effective
   selection/execution configuration. Preserve the existing complete input file
   fingerprints, tool versions, and target. Persist the ordered full identity
   manifest in a sidecar so completeness can be audited beyond a short hash.
   Unknown/uncaptured execution inputs must be documented, not implied portable.

## Partial results and quality gates

Label all console/report summaries from `n > 1` as shard/subset results. The
existing local score formula remains unchanged; never count other shards as
killed, survived, timed out, or target-inactive.

For this first version, reject `--shard` together with `--fail-under` when `n > 1`
with exit 2. A threshold applied independently to each shard is not the global
weighted mutation score. `0/1` may use the existing threshold behavior.

A CI example must use the same revision, toolchain, backend, diff, effective
arguments, and denominator on every shard, run all `0..n-1` indices with
`fail-fast: false`, and retain separately named artifacts. Checking one successful
shard is never a full-run claim. Under the default zero-survivor policy, require
every matrix entry to succeed; missing, failed, or cancelled entries cannot be
accepted as completed validation.

This task emits the manifest and tests the partition invariants; a general
cross-run merger, weighted-threshold gate, and external artifact aggregator are
explicitly deferred. Do not advertise automatic global-report validation.

## Implementation boundaries

Keep the pure assignment function separate from worker execution.
`run_mutations` currently owns target partitioning while listing has its own
path. Factor a shared, target-resolved selection stage rather than duplicating
shard logic. Do not zip a filtered mutation array with a stale reuse array.

Changes belong in `cmd/turtles/` config/types/selection/report integration and
focused test files. CLI/config changes must preserve the no-shard path.
The native CLI's `--target` still names the project-under-test backend, not a
new build target for turtles itself.

The diagnostics task supplies destination ownership independently of the
`--retain-logs` flag. Sharding does not require retaining raw logs.

## Non-goals and tradeoffs

No remote worker protocol, distributed queue, adaptive scheduling, shared
scratch workspaces, cross-machine `_build` cache, random sampling mode, or
baseline bypass. Equal mutant counts do not imply equal runtime. Repeated
baseline/setup work can increase total compute; no speedup is claimed until
measured on the same project, machine class, toolchain, and selection.

## Acceptance criteria

1. Pure/property tests establish that shard sets are pairwise disjoint and their
   union exactly equals the active candidate universe, for empty input, one
   mutant, many mutants, `n = 1`, and more shards than mutants. Counts differ
   by at most one.
2. Reordered input enumeration, different checkout roots, `--jobs 1` versus
   parallel workers, and different reusable-verdict subsets produce identical
   assignments for the same canonical input.
3. All shard reports combined reproduce an unsharded fixture's identity/outcome
   map, excluding measured durations. Target-inactive files never enter shard
   membership. Repeat with diff selection when that feature exists.
4. `--list --shard` matches the executed active set without baseline tests.
   Invalid shard syntax and disallowed threshold combinations exit 2.
5. Parallel shard runs do not overwrite reports, survivor diffs, diagnostics,
   explicit JSON outputs, or each other's reuse state. Ownership collisions fail
   safely; generated artifacts do not influence subsequent candidate discovery.
6. Metadata/manifest snapshots preserve enough information to detect missing
   indices, inconsistent denominators, and different candidate/configuration
   inputs in a future verifier. The CLI does not claim to have run that verifier.
7. Without `--shard`, existing IDs, ordering, output paths, threshold handling,
   target forwarding, and reuse guards remain unchanged.

## Verification plan — not executed by this documentation change

Implement private helper tests in `*_wbtest.mbt`, deterministic partition
properties, and real multi-invocation fixture E2E. Use `.mbtx` for new CI-test
orchestration and preserve `--jobs` outcome-equivalence coverage. Follow
[the shared validation commands](README.md#verification-plan).
