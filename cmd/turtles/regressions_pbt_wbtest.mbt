///|
/// A kill assembled from arbitrary fields: pkg/filename/index are fixed
/// because the regression helpers only read test_name, kind, and
/// counterexample.
fn pbt_kill(
  test_name : String,
  kind_raw : Int32,
  has_counterexample : Bool,
  counterexample : String,
) -> Kill {
  let kind = match pbt_mod4(kind_raw) {
    0 => Assertion
    1 => Snapshot
    2 => DocTest
    _ => Property
  }
  {
    pkg: "p",
    filename: "f.mbt",
    index: 0,
    test_name,
    kind,
    counterexample: if has_counterexample {
      Some(counterexample)
    } else {
      None
    },
  }
}

///|
/// Signed mod-4 bucket for picking a kill kind.
fn pbt_mod4(raw : Int32) -> Int32 {
  let m = raw % 4
  if m < 0 {
    m + 4
  } else {
    m
  }
}

///|
/// Signed mod-4 bucket for picking a mutation outcome.
fn pbt_outcome(raw : Int32) -> Outcome {
  match pbt_mod4(raw) {
    0 => Killed
    1 => Survived
    2 => Timeout
    _ => Unviable
  }
}

///|
/// A MutationResult over arbitrary mutation fields, outcome, kill list,
/// and whether attribution is present at all.
fn pbt_result(
  path : String,
  start : Int32,
  end : Int32,
  original : String,
  replacement : String,
  outcome_raw : Int32,
  kills_present : Bool,
  kills : Array[Kill],
) -> MutationResult {
  {
    mutation: pbt_mutation(path, start, end, original, replacement),
    outcome: pbt_outcome(outcome_raw),
    duration_ms: 0L,
    reused: false,
    packages: None,
    kills: if kills_present {
      Some(kills)
    } else {
      None
    },
    witness: None,
    witness_skipped: None,
    amplified: None,
  }
}

///|
test "prop counterexample_kills keeps exactly the property kills with a counterexample" {
  @quickcheck.check((
    input : (
      String,
      Int32,
      Int32,
      String,
      String,
      Int32,
      Bool,
      Array[(String, Int32, Bool, String)],
    ),
  ) => {
    let (
      path,
      start,
      end,
      original,
      replacement,
      outcome_raw,
      present,
      raw_kills,
    ) = input
    let kills = raw_kills.map(k => pbt_kill(k.0, k.1, k.2, k.3))
    let result = pbt_result(
      path, start, end, original, replacement, outcome_raw, present, kills,
    )
    let selected = counterexample_kills(result)
    if result.outcome != Killed {
      return selected.is_empty()
    }
    // Exactly the Property kills carrying Some(counterexample), in order;
    // absent attribution means no kills are visible at all.
    let expected = (if present { kills } else { [] }).filter(k => {
      k.kind == Property && k.counterexample is Some(_)
    })
    if selected.length() != expected.length() {
      return false
    }
    for i = 0; i < selected.length(); i = i + 1 {
      if selected[i].test_name != expected[i].test_name ||
        selected[i].kind != Property {
        return false
      }
    }
    true
  })
}

///|
test "prop regression_relpath exists iff a counterexample kill exists" {
  @quickcheck.check((
    input : (
      String,
      Int32,
      Int32,
      String,
      String,
      Int32,
      Bool,
      Array[(String, Int32, Bool, String)],
    ),
  ) => {
    let (
      path,
      start,
      end,
      original,
      replacement,
      outcome_raw,
      present,
      raw_kills,
    ) = input
    let kills = raw_kills.map(k => pbt_kill(k.0, k.1, k.2, k.3))
    let result = pbt_result(
      path, start, end, original, replacement, outcome_raw, present, kills,
    )
    match regression_relpath(result) {
      Some(relpath) =>
        !counterexample_kills(result).is_empty() &&
        relpath.has_prefix("regressions/") &&
        relpath.has_suffix(".mbt") &&
        relpath.contains(mutation_id(result.mutation))
      None => counterexample_kills(result).is_empty()
    }
  })
}

///|
test "prop regression_source embeds every counterexample as comments" {
  @quickcheck.check((
    input : (
      String,
      Int32,
      Int32,
      String,
      String,
      Array[(String, Int32, Bool, String)],
    ),
  ) => {
    let (path, start, end, original, replacement, raw_kills) = input
    // Always Killed with full attribution so the template exists exactly
    // when at least one Property kill carries a counterexample.
    let kills = raw_kills.map(k => pbt_kill(k.0, k.1, k.2, k.3))
    let result = pbt_result(
      path, start, end, original, replacement, 0, true, kills,
    )
    let expected = kills.filter(k => {
      k.kind == Property && k.counterexample is Some(_)
    })
    match regression_source(result) {
      Some(source) => {
        if expected.is_empty() {
          return false
        }
        let mut blocks = 0
        for line in source.split("\n") {
          if line.contains("test \"turtles regression") {
            blocks = blocks + 1
          }
        }
        if blocks != expected.length() {
          return false
        }
        // Each counterexample's text survives into the template.
        for kill in expected {
          match kill.counterexample {
            Some(value) =>
              for line in value.split("\n") {
                if !source.contains("//   \{line}") {
                  return false
                }
              }
            None => return false
          }
        }
        true
      }
      None => expected.is_empty()
    }
  })
}
