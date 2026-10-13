# Preserve bounded run and command diagnostics outside temporary workspaces

- Status: open proposal; no implementation in this task record
- Date: 2026-10-13 (JST)
- Priority: P1
- Inspected baseline: `6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2` (`turtles` 0.4.6)
- Dependencies: none; provides output ownership needed by the sharding proposal

## Problem and evidence

A timeout or unavailable kill attribution is difficult to investigate after the
temporary workspaces disappear. A baseline/setup failure can also leave the last
successful report on disk without a new completed report.

[runner.mbt](https://github.com/gpui-mbt/turtles.mbt/blob/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2/cmd/turtles/runner.mbt) redirects Moon output to
`root + "-moon-output.log"` and reuses that path across invocations.
`run_mutations` removes its temporary tree on exit. The command result currently
retains only success, failure, or timeout, not a complete process record.
[main.mbt](https://github.com/gpui-mbt/turtles.mbt/blob/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2/cmd/turtles/main.mbt) writes the final report only after
`run_mutations` returns; [report.mbt](https://github.com/gpui-mbt/turtles.mbt/blob/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2/cmd/turtles/report.mbt)
persists reports and survivor diffs, but not phase logs.

[cargo-mutants output artifacts](https://mutants.rs/mutants-out.html) demonstrate
the value of retained baseline/mutant logs, incremental progress, and protection
against concurrent writers. The proposed format below is turtles-owned, not
cargo-mutants output compatibility.

## Proposed behavior

1. Add opt-in `--retain-logs`. Create a unique run directory under the resolved
   output directory, for example `runs/<run-id>/`, before launching the baseline.
   Do not retain `_build`, copied source trees, or full temporary workspaces.
   Preserve current behavior without the flag except for the output-ownership
   safety primitive described below.

2. Save distinct phase logs before another invocation can replace the worker
   log: baseline check, both baseline test attempts, mutant check/test, and
   enabled amplification/witness attempts. Use mutant identity plus a phase and
   attempt number; worker scheduling must not change which invocation a file
   describes. Record the exact argv array, target, selected package scope,
   duration, command classification, and observed exit/signal information when
   actually available. Missing information is unknown, never inferred as fact.

3. Keep an independent versioned diagnostic manifest with run identity, start
   metadata, phase progress, completed classification records, and an explicit
   lifecycle state. Normal terminal states are `completed`, `failed`, and
   controlled `cancelled`. During execution it is `running`; after a hard crash
   a leftover `running` record means unfinished with unknown liveness, not a
   claim that a process is still alive. State changes and manifest replacement
   must not expose half-written JSON.

4. Preserve diagnostic evidence on handled baseline, worker, and output failures.
   Distinguish setup errors from mutation outcomes. An initial `SURVIVED` that is
   still awaiting PBT amplification is not a final survivor; record its stage
   explicitly. Keep diagnostics separate from `report.json` and from score
   calculations. A failed or cancelled run must not publish a completed report.

5. Continue writing the ordinary completed report only after successful run
   finalization; publish it atomically and associate it with the diagnostic run.
   Keep the previous completed report identifiable by its own run, rather than
   presenting it as the current failed run. `--iterate` must never consume the
   progress manifest or partial classifications. Do not add weaker resume
   semantics to this task.

6. Add reusable, atomic ownership checks for the resolved output destinations,
   including an explicitly requested JSON output. A concurrent writer must fail
   before overwriting another run's artifacts. Do not steal an ownership claim
   merely because a PID is absent or reused; either use a supported native lock
   or provide conservative, documented manual recovery for an abandoned claim.
   This helper also protects future concurrent shard invocations.

7. Bound *retained* raw output to 1 MiB per invocation and 64 MiB per run by
   default, recording truncation and original byte count when known. Keep the
   diagnostic metadata even when retention is exhausted. Truncation must not
   affect the full structured failure stream used for kill attribution.
   These limits do not claim to cap Moon's temporary output files.

8. Exclude generated diagnostic/output trees from source copying and fingerprint
   discovery, including supported custom output directories within the module.
   Reject output paths that overlap a source file or unsafe ownership boundary;
   never sweep unrelated files. Keep logs local: no automatic upload, environment
   dump, or claim that arbitrary test output has been redacted. Document that raw
   logs may contain secrets and require review before sharing.

## Implementation boundaries

Use focused MoonBit helpers in `cmd/turtles/`, rather than expanding `main.mbt`
into a general event system. Integrate at the centralized Moon command runner so
normal tests, target-aware commands, and survivor analyses cannot drift.

If richer command results are necessary, retain the current classification
contract and update its consumers deliberately. Keep stdout redirection: sending
nested Moon output back into a parent Moon test protocol is not an alternative
to persistent logs. Preserve attribution parsing before any retention truncation.

Cleanup must still run on diagnostics failure and cancellation. Logging must not
extend a timed-out child's lifetime or replace the existing Darwin supervisor,
Windows Job Object, or GNU timeout handling. Main already contains those platform
paths; [PR #29](https://github.com/gpui-mbt/turtles.mbt/pull/29) is not duplicated
by this task.

## Non-goals

No resumable partial execution, live web UI, JUnit/SARIF export, remote log sink,
automatic secret filtering, full-workspace retention, or new process-tree
supervisor. No promise of final-state writes after SIGKILL or power loss.

## Acceptance criteria

1. Baseline failure preserves its diagnostics and exits 2. Two baseline test
   attempts have separate logs; their evidence is not overwritten by later work.
2. Mutant check/test and PBT attempts remain distinguishable under `--jobs 1`
   and parallel execution. Attribution and final outcomes match runs without
   log retention.
3. A controlled failure after several classifications retains those stage
   records, labels the run failed, and does not replace a valid completed report
   with a partial one. Controlled cancellation still cleans temporary workspaces.
4. Reused mutants explicitly reference reused provenance or mark no new command;
   they do not receive a fabricated current-run log or duration.
5. Consecutive runs keep distinct identities. Concurrent destination collisions
   fail safely; different output destinations remain independent. Old completed
   reports and unrelated user files are preserved.
6. Oversized logs produce explicit truncation metadata while structured property
   counterexamples and kill attribution remain intact.
7. A subsequent `--iterate` run ignores partial diagnostics, applies the current
   complete-report guards, and does not invalidate itself because generated logs
   were fingerprinted.
8. Filesystem write failures are reported as location plus observed operation
   error; no test PASS, completed state, or missing log content is invented.

## Verification plan — not executed by this documentation change

Add deterministic lifecycle/retention tests, filesystem ownership tests, and
fixture tests with controlled baseline failure, timeout, worker failure, and
cancellation. Exercise the existing native platform CI matrix for command-runner
changes; label unexecuted platform checks explicitly. Follow the MoonBit package,
snapshot, and `.mbtx` conventions in [the task index](README.md).
