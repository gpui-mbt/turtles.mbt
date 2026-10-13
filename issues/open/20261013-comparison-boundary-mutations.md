# Opt-in comparison boundary mutations

- Status: open proposal; no implementation in this task record
- Date: 2026-10-13 (JST)
- Priority: P1
- Inspected baseline: `6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2` (`turtles` 0.4.6)
- Dependencies: none; preserve the selection contracts in [the task index](README.md)

## Problem and evidence

Tests can distinguish below-limit and above-limit values without checking equality.
The current scanner can reverse a comparison, but cannot isolate that equality gap.
For example, tests at 9 and 11 can kill `x < 10` -> `x > 10` while missing the
behavioral difference introduced by `x < 10` -> `x <= 10`.

In [scanner.mbt](https://github.com/gpui-mbt/turtles.mbt/blob/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2/cmd/turtles/scanner.mbt),
`operator_specs` maps `<` to `>`, `>` to `<`, `<=` to `>`, and `>=` to `<`.
`AstCandidateVisitor::record_operator` stops after its first matching specification.
Merely appending another entry for the same input operator would therefore not
generate both mutants.

The [cargo-mutants 25.1.0 changelog](https://mutants.rs/changelog.html)
explicitly records strict-to-inclusive comparison mutations. This proposal ports
that idea and adds the corresponding inclusive-to-strict changes for MoonBit;
it does not claim all four entries below come from that changelog.

## Proposed behavior

1. Add the opt-in operator group `boundary`, accepted by both `--operators` and
   `turtles.toml`. Its complete initial set is:

   | Original | Replacement |
   | --- | --- |
   | `<` | `<=` |
   | `>` | `>=` |
   | `<=` | `<` |
   | `>=` | `>` |

2. Emit every enabled matching specification, in a documented stable order.
   Retain existing comparison reversals and their identities when both groups
   are selected. `boundary` alone must work even when an earlier matching
   `comparison` entry is disabled.

3. Keep the default mutation set unchanged. Update
   `ProjectConfig::operator_enabled`: its current `group != Body` default would
   accidentally enable a newly added group. Both `body` and `boundary` must be
   explicitly opted into.

4. Continue using parser locations and the existing scalar-to-UTF-8 boundary
   conversion. A replacement changes only the operator's byte range. Keep
   original-text verification, duplicate suppression, skip markers, visibility
   attribution, and target-active selection.

5. Report the new group as `boundary`; retain the existing mutant identity inputs
   and all four outcome meanings. A new operator does not guarantee type-valid
   code, so `moon check` remains authoritative for `UNVIABLE`.

Example after implementation:

```sh
turtles --dir . --operators comparison,boundary --list
turtles --dir . --operators boundary --target native
```

These are proposed commands, not currently supported behavior.

## Implementation boundaries

Keep discovery in `cmd/turtles/scanner.mbt`; do not expose parser types to the
runner or add a lexical fallback. Extend group parsing/formatting and default
selection in `types.mbt`, and help/config tests in `config.mbt` and the existing
white-box test files.

Preserve the existing operator ordering when `boundary` is not requested.
The existing duplicate check compares path, span, and replacement, rather than
group; the four new edits do not collide with current comparison reversals.
Do not broaden duplicate attribution semantics as an incidental refactor.

The package version must change when this feature is released, so older
`--iterate` reports remain subject to the existing version guard. Do not relax
whole-module fingerprint checks or reuse survivors.

## Non-goals

No arithmetic/bitwise expansion, numeric-literal mutation, match-arm deletion,
return-type inference, parser upgrade, or change to the default score threshold.
Whether to enable this group by default is a separate evidence-backed decision.

## Acceptance criteria

1. A table-driven scanner test observes exactly the four edits above. Selecting
   `comparison,boundary` emits both intended replacements for each applicable
   operator, without duplicates. Selecting `boundary` alone is not blocked by
   the first-match behavior.
2. Default discovery and explicit legacy group sets preserve their previous
   identities and order. CLI selection continues to replace the TOML operator
   list, rather than silently changing precedence.
3. A real fixture with a comparison helper and only below/above tests lets the
   equality-boundary mutant survive. Adding an equality test kills it. Repeat
   for strict and inclusive comparisons in both directions.
4. Unicode before the operator, CRLF source, and nested expressions preserve
   exact byte edits. Comments, string contents, excluded test files, and skipped
   declarations do not acquire new candidates.
5. `--target native`, `js`, and `all` preserve active/inactive classification;
   boundary mutants in inactive files are never counted as survivors.
6. Repeated discovery and `--jobs 1` versus parallel execution produce the same
   mutant identities and outcomes, ignoring measured durations.
7. Reports and `--iterate` recognize `boundary` after the implementation's
   version update, without admitting stale or amplification-derived verdicts.

## Verification plan — not executed by this documentation change

Follow [the shared MoonBit validation rules](README.md#moonbit-implementation-rules).
Add focused `*_wbtest.mbt` cases for private scanner/config functions and a
fixture-level CLI acceptance test. Name tests for the behavior they establish.

Run `moon fmt --check`, `moon check --target native --deny-warn`,
`moon test --target native`, and `moon info --target native`; review any generated
interface diff. Run the new fixture baseline and mutation E2E separately.
Do not use snapshot update flags in the mutation oracle.
