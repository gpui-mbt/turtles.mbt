# Support cold Windows native-asset use with an unmodified MSVC toolchain

- Priority: P1
- Scope: Windows process supervision and published native-asset acceptance
- Status: open; the consumer CI environment has an explicit helper workaround

## Observed evidence

- Published 0.4.7 installs from Mooncakes and mutation-tests an unrelated
  module on Windows with Python commands blocked and no turtles checkout.
- The checksum-verified Windows native asset reports version 0.4.7 and help,
  but cold runs wait after the pristine baseline's moon test passes 1/1.
- Both initial runs reach the 600-second CLI baseline timeout.
- The bounded diagnostic run on head 2c59e4a5 reports a live vctip.exe
  candidate whose parent has exited. Ownership is not established by that
  final snapshot; causal attribution must remain an inference until verified.
- SQM policy and version-specific opt-out values did not prevent the helper
  from running. They are not a demonstrated solution.

Evidence: [initial failure](https://github.com/gpui-mbt/turtles.mbt/actions/runs/38504863171),
[diagnostic failure](https://github.com/gpui-mbt/turtles.mbt/actions/runs/38507630494).

## Current CI condition

Only the disposable checkout-free Windows consumer runner renames the optional
MSVC vctip executable before using the compiler. CLI process-tree checks stay
enabled; the fixture is not pre-built. A successful gate in that environment
must not be represented as support for an unmodified cold Windows toolchain.
The existing Windows source/timeout/descendant-cleanup regression gates are
unchanged.

## Acceptance criteria

1. Capture compiler/helper ancestry during process creation, rather than
   reconstructing ownership solely after parent exit.
2. Reproduce the original cold native-asset failure in a disposable Windows
   runner without pre-building the module or modifying MSVC components.
3. Resolve the lifetime mismatch while keeping hung test descendants scoped,
   terminated and classified correctly. Do not whitelist an arbitrary process
   name or stop unrelated compiler processes.
4. Run the existing Windows timeout, cancellation, process identity and
   parallel-worker regression gates.
5. Publish a new explicit version if CLI/runtime behavior changes; do not
   replace the existing 0.4.7 release assets.
6. Require both registry and native-asset cold consumer fixtures to report the
   expected version, schema 3, one KILLED mutant and no other outcomes under
   Python blocking without a turtles checkout.
