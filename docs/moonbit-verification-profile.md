# Experimental MoonBit verification profile

`scripts/verify_moon_profile.py` is an explicitly invoked **companion CLI** in
the turtles source checkout. It is not an installed native turtles flag or a
Mooncakes release. A plain `turtles` invocation, its runtime score, schema-3
report, iteration rules, and old schema-2 project ratchets are unchanged.

The first profile is intentionally limited to the GPUI source-equivalent
`TextRange::length`, `utf8_scalar_width`, and `utf16_scalar_width` helpers plus
the identical `TextRange` carrier. It does not verify composition transactions,
imported `Result` lowering, GUI/FFI/IME, callers' preconditions, general machine
overflow, or the whole MoonBit language. It is not Kani equivalence: the proof
backend uses mathematical integers, with explicit signed-Int-fit requirements
for this range subtraction.

## Required reviewed pilot

The source project must contain the separately reviewed official-export pilot
at `infra/linux-desktop/composition-proof.py`, the unchanged contracts/tests,
and its toolchain lock. The profile explicitly selects one reviewed pair:

- `e58e2e2`: producer SHA-256 `78ba554319eba17e50034fc59f14c531c539d2929d53bb012497363360b6975a`, fixture `proofs/composition`
- `packaging-39b1275`: producer SHA-256 `41ca263e8dd0c99ec8fd120c19ed0043c2068feb8ade9928a7311dd209f90122`, fixture `testing/composition_proof`

The latter is the byte-identical fixture packaging follow-up, commits
`38a82d851c02686481e66db87644eeb2f285771a` and
`39b1275de2580235dcbfec71958e33f61c2a52cd`. Both retain the fixed lock SHA-256
`493e83579177583ef993a098afcb102ee529dc01afd807719ce88c3b138041f2`.
Unrecognized producer hashes/layouts, tool locks, profile keys or targets are
blocked. Updating the pilot requires explicit review and adapter changes; it
is not an automatic upgrade or a generic external-command hook.

## Run explicitly

Copy `verification-profiles/moonbit-composition.example.json` outside the
source checkout and replace its placeholder with the SHA-256 of a reviewed
turtles **schema-3** executable built from this repository. This intentionally
does not accept the historical schema-2 registry executable as the new profile.
Set `pilot_revision` to the reviewed pair present in the source project.

```sh
python3 scripts/verify_moon_profile.py \
  --profile /absolute/reviewed-profile.json \
  --source-root /absolute/gpui-checkout \
  --turtles-bin /absolute/schema3-turtles \
  --artifact-dir /absolute/new-owned-run-directory \
  --moon-home /absolute/pinned-moon-home \
  --why3 /absolute/official-why3-prefix/bin/why3 \
  --solver /absolute/hash-locked-z3
```

The companion downloads or installs nothing. Python's standard library and
the already qualified compiler/Why3/Z3 are required. No shell `eval`, new
network service, LLM oracle or credential setup is used. Commands are bounded
argv subprocesses in fresh owned directories. Existing output directories are
refused without overwriting or consuming a previous success. There is no cache
reuse between profile runs. Source files, modes, origin commit/tree, source
edits, contracts, tests, profile, runtime support binaries and proof tool/config/
plugin/loadpath identities are recorded. Caller source is checked unchanged.

## What runs

1. The pristine official-export pilot must produce the exact five original
   goals, all UNSAT. Its two broken-implementation controls must compile,
   exhibit their exact native assertion failures and produce SAT only on the
   intended goal, with four other UNSAT results. Unknown, timeout, crash,
   unrelated failures or incomplete reports do not qualify a control.
2. The declared wasm `text` and `controls/text_field` production packages run
   twice from pristine source, with source-pollution checks. Moon's actual
   dry-run plan must compile both production files. Declaration-level target
   attributes, ambiguous spellings, nested declarations, comment/string
   decoys and unsupported extraction syntax are rejected.
3. The official turtles parser discovers mutations in a byte-exact helper
   extraction under native. Discovery is bounded **before** mutation execution.
   Helper tests include native boundaries, an independent bit-width model over
   every valid Unicode scalar, and 1,000 range-reconstruction PBT cases for each
   fixed seed `1`, `1777`, `4242`, `65535`.
4. Each discovered executable-body edit is mapped byte-for-byte into a fresh
   isolated **full production checkout**. The wasm production package oracle
   runs there. The proof implementation is regenerated from that actual mutant
   body while keeping all reviewed contracts/specification/witnesses fixed.
5. The pinned Moon compiler emits WhyML. The official pinned Why3 inventories
   and exports all five goals through its unchanged driver, then pinned Z3
   solves the unchanged exported SMT files. Raw compiler/export/solver logs,
   process ledgers and full task inventories are independently audited.

No sanity-control edit is counted as a production mutant. The native helper
oracle and wasm production oracle are deliberately reported separately.

## Read the report

`verification-report.json` retains the complete discovered inventory and
denominator, mappings, evaluated and unexecuted IDs, raw native turtles report,
source-runtime outcomes, and proof outcomes. `PROVED` means all five actual
goals are UNSAT. `COUNTEREXAMPLE` means actual SAT only on the changed helper's
goal. `INCONCLUSIVE` retains the precise reason for unsupported lowering,
source mismatch, unknown, timeout, malformed or untrusted evidence. None of
those is a kill.

Production runtime `KILLED` requires successful checking plus a concrete
structured failing test. Compiler/warning rejection is `UNVIABLE`, excluded
from its runtime denominator; timeout remains not killed. A proof
counterexample never increments the runtime kill numerator. Contract-equivalent
classification requires both runtime oracles to survive and all fixed exact
postconditions to be proved. A proof/model contradiction blocks that label and
the campaign.

The exporter does not request concrete solver models. SAT is therefore not
presented as an executable solver-derived input. Unsupported extraction stays
explicit. For the known typed range PBT tuple format, a separate deterministic
regression artifact is generated from the **actual shrunk PBT witness** and
checked against pristine and re-mutated production: pristine must pass, and
the same mutant must fail that exact regression test. Other witness formats
are left unsupported. `replay.json`, fixed seeds and raw regression templates
are preserved; the user's test files are never automatically changed.

Exit `0` means the bounded campaign finished with qualified evidence, not that
the source project has no defects. Setup, unknown/incomplete evidence,
pollution, interrupted work or failed replay exits `2`. An unfinished campaign
retains its full discovered denominator and unevaluated IDs rather than a
partial green score.

## Development checks

```sh
python3 -m unittest discover -s scripts/tests -v
moon fmt --check
moon check --target native --deny-warn
moon test --target native
```

The Python tests are offline synthetic adversarial fixtures. They exercise
rejection branches and do not claim solver qualification. Actual qualified
campaign reports are separate run artifacts, with exact source/tool hashes.

Sources: [MoonBit verification](https://docs.moonbitlang.com/en/stable/language/verification.html),
[official Why3 export](https://why3.org/doc/manpages.html#the-prove-command),
[Kani verification results](https://model-checking.github.io/kani/verification-results.html).
