# Native process-tree timeout cleanup on Windows and Apple Silicon macOS

Status: open — source finding; platform reproduction and implementation pending  
Updated: 2026-10-07 (JST)

## Finding and scope

At main `8a1816ab494c4595449608e940ca5663af966b74`,
[run_moon_command](../../cmd/turtles/runner.mbt) uses GNU `timeout` for
process-group termination only when its probe succeeds. With `group_kill=false`,
the fallback hard-cancels the `moon` PID. The source explicitly notes that child
compiler/test executables may remain orphaned.

That fallback is not evidence of bounded native cancellation on Windows or a
standard macOS installation without GNU `timeout`. This is a source-level gap;
no fresh platform reproduction is claimed by this task.

Provide bounded owned-process-tree cancellation for the CLI on Windows and
**Apple Silicon / arm64 macOS only**. Intel macOS is excluded. Keep Linux/GNU
`timeout` behavior and unrelated workers/processes intact.

## Dependencies and implementation boundary

- Reconcile current `runner.mbt`, subprocess-library/toolchain behavior and the
  target host before selecting an OS adapter.
- Preserve baseline/mutant classification, target forwarding, deterministic
  parallel reports and temporary-workspace isolation.
- Cancel and reap owned descendants before restoring/deleting a workspace.
  If safe cleanup cannot be established, fail explicitly instead of claiming
  completed cleanup or reusing a possibly active workspace.
- Verify the missing/unsupported `timeout` probe path as well as cancellation.
- The source-exact Python companion has separate POSIX process-group
  assumptions; porting that entire companion is outside this CLI packet.

## Acceptance

- [ ] Reproduce the fallback with GNU `timeout` absent on each declared host,
  recording source/toolchain/library/OS and arm64 architecture for macOS.
- [ ] A deterministic fixture starts a hanging compiler/test descendant.
  Expiry is classified TIMEOUT; the complete owned tree is gone before workspace
  cleanup, with no lingering process or file writer.
- [ ] Cover baseline and mutant timeouts, repeated runs and multiple workers.
  A timed-out worker cannot terminate another worker or the original project.
- [ ] Successful commands and ordinary test failures preserve existing results;
  probe/setup/cleanup failures produce actionable diagnostics.
- [ ] Existing Linux/GNU-`timeout` and target/parallel/isolation regressions pass.
- [ ] Retain final-source process/cleanup evidence separately for Windows and
  Apple Silicon macOS. Build-only success is not runtime qualification.

This records a bounded follow-up, not an OS support claim or a request to start
new Windows implementation work immediately.
