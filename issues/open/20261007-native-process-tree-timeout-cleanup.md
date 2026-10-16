# Linux without GNU timeout: clean up the entire owned process tree

Status: open — source-level gap; no fresh Linux-without-GNU-timeout runtime reproduction
Priority: P1 (runtime reliability; not a P1 regression introduced by this docs PR)
Updated: 2026-10-16 (JST)
Scope: native turtles CLI on Linux when neither `gtimeout` nor GNU `timeout` can be used

## Evidence at current main

- [`cmd/turtles/runner.mbt`](../../cmd/turtles/runner.mbt) probes `gtimeout`/`timeout`. When a helper is available, it runs Moon inside the helper's process group; when unavailable on Darwin, it uses its own process-group supervisor.
- In the remaining non-Windows, non-Darwin branch of `run_moon_command`, `@async.with_timeout_opt` runs `moon` with `cancel_handler=@process.hard_cancel()`. That fallback only identifies the immediate process for cancellation; the source does not establish termination/reaping of compiler/test descendants. This is a source-level risk, **not** a claim that Linux orphans were reproduced.
- Windows now runs Moon in a scoped Job Object. [`scripts/windows_smoke.py`](../../scripts/windows_smoke.py) checks native timeout and persistent descendants. [`scripts/darwin_timeout_smoke.py`](../../scripts/darwin_timeout_smoke.py) checks Darwin without GNU timeout, including descendant termination and signal cancellation.
- [CI run 38716379298](https://github.com/gpui-mbt/turtles.mbt/actions/runs/38716379298) completed/success on the later main line for the existing matrix. Its Linux timeout test is [`scripts/timeout_smoke.py`](../../scripts/timeout_smoke.py), which **requires** GNU timeout; it does not test Linux's missing-helper path.
- A different open issue, [Windows cold native-asset / MSVC helper](20261014-windows-cold-native-compiler-helper.md), covers the unmodified-MSVC consumer hang. A green Windows job using its documented disposable-runner workaround must not be presented as resolving that issue.

## Goal and constraints

1. Ensure that when GNU timeout is missing or its probe fails on Linux, mutation check/test and pristine baseline either use **bounded, owned-tree** cancellation or fail explicitly *before* launching an unowned process. Do not silently kill only the immediate `moon` PID.
2. The supervisor/adapter must own descendants from process creation and terminate/reap them before removing a temporary workspace. Preserve other concurrent jobs and unrelated user processes.
3. Preserve current GNU-timeout behavior, timeout vs ordinary failure classification, `--target`, `--jobs`, isolation, `--iterate`, source-tree safety, and error diagnostics.
4. Leave the existing Darwin supervisor and Windows Job Object behavior intact. Do not expand the scope to Intel macOS or to the separate Windows cold-compiler helper fix.

## Acceptance evidence required

- [ ] Reproduce a Linux environment with both `timeout` and `gtimeout` absent from the CLI's effective PATH. Record Linux distribution/arch, toolchain version, release/HEAD SHA, exact probe command, and fixture invocation.
- [ ] A deterministic nested compiler/test fixture launches a tokenized persistent child. Trigger a mutant TIMEOUT, and confirm the root and **every owned descendant** have terminated before workspace cleanup, with no further file writes; a warm build must not hide the timeout setup.
- [ ] Exercise a baseline timeout separately. Verify that a failed baseline cannot produce a valid mutation report or success status.
- [ ] Exercise explicit cancellation/interruption and multiple parallel workers without killing another worker or mutating the original working tree.
- [ ] Exercise probe failure/unsupported helper and cleanup failure; return a specific diagnostic and non-success exit instead of assuming cleanup succeeded.
- [ ] Repeat the existing Linux GNU-timeout test, Apple Silicon Darwin no-helper descendant test, and Windows job/timeout/parallel regressions. Each must have completed/success results at the final candidate HEAD.
- [ ] Record logs, check results, reproduction outcome, and any platform limitation. Do not claim all-platform qualification from source inspection or build-only success.

## Implementation boundary

Compare a Linux native process-group supervisor against explicit fail-fast when no verified group supervisor is available. Choose based on current MoonBit process API and OS capabilities, not by assuming `@process.hard_cancel()` controls descendants. Add only the minimal Linux adapter/fixture needed; preserve the Darwin/Windows paths.

Keep the fixture deterministic, bounded, and safe to run in disposable CI. Do not use `killall`, process-name sweeps, shared workspace deletion, or intrusive changes to host tools. The existing contributor Python harness may run the regression; porting it to MoonBit is a separate issue.

## Verification status for this docs change

- GitHub source and existing CI were inspected; a Linux no-helper repro, new regression suite and platform rerun were **not executed** as part of this documentation change.
- This issue describes remaining work, not a newly implemented fix or an existing Windows/macOS regression.

## History

- 2026-10-07: original draft described Windows/Apple Silicon process-tree cleanup before the later platform implementations.
- 2026-10-16: reconciled with current Darwin supervisor, Windows Job Object and CI. Narrowed the outstanding source-level risk to the Linux path without GNU timeout.
