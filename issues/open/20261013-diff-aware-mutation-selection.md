# Select mutants overlapping a validated source diff

- Status: open proposal; no implementation in this task record
- Date: 2026-10-13 (JST)
- Priority: P1
- Inspected baseline: `6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2` (`turtles` 0.4.6)
- Dependencies: none; share the selection boundary with the proposed sharding task

## Problem and evidence

A pull request may touch a few lines in a large module. The current `--file`
substring filter can narrow discovery to a path, but not to changed regions.
`--affected` selects observing tests, not changed mutant locations, and
`--iterate` intentionally invalidates reuse when any fingerprinted input changes.

[config.mbt](https://github.com/gpui-mbt/turtles.mbt/blob/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2/cmd/turtles/config.mbt) has no diff selector.
[main.mbt](https://github.com/gpui-mbt/turtles.mbt/blob/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2/cmd/turtles/main.mbt) sends the discovered set into
listing or `run_mutations`; explicit target filtering occurs through Moon's plan.
[iterate.mbt](https://github.com/gpui-mbt/turtles.mbt/blob/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2/cmd/turtles/iterate.mbt) establishes the reuse
guards that must remain intact.

[cargo-mutants --in-diff](https://mutants.rs/in-diff.html) provides the upstream
feature model: choose mutants overlapping changed source regions. This improves
feedback scope, but cannot establish the coverage of unchanged production code
after a test-only change.

## Proposed behavior

1. Add `--in-diff <FILE>`. Read a supplied unified diff; do not execute Git,
   resolve branch names, apply the patch, or modify the working tree. Relative
   diff-file paths follow the CLI's documented path convention; paths *inside*
   the diff are relative to the module selected by `--dir`.

2. Accept ordinary Git unified diffs with `a/` and `b/` prefixes and unified
   diffs without those prefixes. Select the new-side path. Support added files,
   multiple hunks, renames with content changes, CRLF, missing final newlines,
   and Git-quoted paths. Decode paths explicitly; never strip arbitrary path
   components or guess a basename match.

3. Reject absolute paths, parent traversal, unsupported combined diffs, malformed
   hunk counts, invalid source ranges, and ambiguous source-path encodings with
   exit 2 before any baseline/classification. Parse non-source/binary sections
   without mistaking their contents for MoonBit changes; they select no mutants.
   Unsupported input must not turn into a successful empty selection.

4. Check each applicable hunk's new-side context and added lines against the
   current source snapshot. A mismatch is a diagnostic naming the diff, source,
   and hunk. These checks validate the represented ranges, not an entire Git
   commit or changes outside the supplied diff. Do not use fuzzy patch matching.

5. Select a mutation when its half-open UTF-8 byte range intersects an added or
   replacement line on the new side. Context-only lines are not changed lines.
   This must include a whole-body mutant whose span contains an edited interior
   line even when the mutant's starting line is unchanged. Pure deletions and
   pure renames have no added lines and select no new candidates.

6. Compose existing path/operator/skip filters, this selector, Moon's active-source
   partition, and then optional sharding. Listing and execution must consume the
   same selection logic. Preserve aligned mutation/reuse arrays when moving
   filtering out of the current runner boundary.

7. Keep baseline validation and `--affected` test planning unchanged. Fingerprint
   the same complete set of sources, tests, manifests, and configuration as an
   unfiltered run. Diff selection is not permission to weaken `--iterate`.

Example diff production from the module directory:

```sh
git diff --relative --no-ext-diff --no-textconv --no-color --src-prefix=a/ --dst-prefix=b/ BASE...HEAD -- . > /tmp/turtles-change.diff
turtles --dir . --in-diff /tmp/turtles-change.diff --target native
```

`BASE` and `HEAD` are user-selected revisions; the checked-out source must match
the diff's new side. The second command is proposed behavior. The implementation
must not run the first command implicitly.

## Reporting and compatibility

Add optional, versioned selection metadata to completed reports: selector kind,
diff content fingerprint, pre-selector candidate count, selected count, and
excluded count. Keep target-inactive counts distinct from diff exclusions, and
label the console/report score as a selected-subset score. Keep the existing
score formula and exit codes for classified mutants.

An empty selected set retains the existing mathematical empty-set score, but
must visibly say that zero production mutants were selected and this is not a
full-module coverage result. A test-only or manifest-only diff must include a
full-run recommendation. Do not fabricate survivors, kills, or target-inactive
results for excluded mutants.

Partial selection does not make an incomplete *execution* a completed report.
The persistent-diagnostics proposal governs interrupted execution separately.
Without `--in-diff`, preserve existing discovery and reporting semantics.

## Implementation boundaries and non-goals

Use a small pure diff parser/selector in `cmd/turtles/` with owned types.
Reuse existing byte-range and mutation primitives; do not overload the current
survivor-diff emitter as a patch parser. Extend CLI config and share a selection
helper between `print_mutation_list` and execution.

No GitHub API integration, automatic PR detection, coverage-based test selection,
cross-run build cache, or default change to `--affected`. This is not a complete
solution to changes that weaken tests for untouched production code.

## Acceptance criteria

1. A fixture with two functions and a change to one expression selects precisely
   the intersecting candidates, including a body mutant overlapping that change.
   Listing and the executed report agree on the active identity set.
2. Multiple hunks, added files, quoted spaces/non-ASCII paths, renames, CRLF, and
   no-final-newline markers give exact matches. Context lines alone do not match.
3. Pure deletions, pure renames, binary-only changes, and test-only changes
   produce the documented empty/subset result rather than a full-coverage claim.
4. Stale hunk text, invalid counts, path escapes, unsupported combined diffs, and
   missing diff files fail with exit 2 before baseline/classification. Source
   discovery parse failures retain the existing policy, not a lexical fallback.
5. `--file`, TOML filters, skip markers, operator groups, and
   `--target native|js|all` compose correctly; inactive candidates are never
   classified. `--list` runs no baseline or mutant tests.
6. `--iterate` still refuses reuse after a changed test/manifest outside the
   selected production regions. No hidden filtering of fingerprint inputs occurs.
7. When sharding is implemented, the union of shards equals this selector's
   active set, and changing `--jobs` or reuse availability cannot change membership.

## Verification plan — not executed by this documentation change

Use pure-parser/selector white-box tests, deterministic property tests for range
intersection, and real CLI fixtures. Add a snapshot of selection metadata and
explicit exit-code assertions. Validate native engine tests and fixture runs on
native and JS targets as described in [the task index](README.md).
New test orchestration belongs in `.mbtx`, not a new shell/Python companion.
