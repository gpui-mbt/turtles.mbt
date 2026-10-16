///|
/// Property kills carrying a shrunk counterexample — the only kills that
/// can seed a regression template.
fn counterexample_kills(result : MutationResult) -> Array[Kill] {
  let kills : Array[Kill] = []
  guard result.outcome == Killed else { return kills }
  match result.kills {
    Some(attributed) =>
      for kill in attributed {
        if kill.kind == Property && kill.counterexample is Some(_) {
          kills.push(kill)
        }
      }
    None => ()
  }
  kills
}

///|
/// Output-dir-relative path of the regression template for a killed
/// mutant, or None when no property kill recorded a counterexample.
fn regression_relpath(result : MutationResult) -> String? {
  if counterexample_kills(result).is_empty() {
    None
  } else {
    Some("regressions/\{mutation_id(result.mutation)}.mbt")
  }
}

///|
/// The relative paths `report.json` lists for emitted templates, in
/// report order.
fn regression_paths(results : Array[MutationResult]) -> Array[String] {
  let paths : Array[String] = []
  for result in results {
    match regression_relpath(result) {
      Some(path) => paths.push(path)
      None => ()
    }
  }
  paths
}

///|
/// One black-box `test` block recording a property kill: the shrunk
/// counterexample next to the killing test's location and the mutant's
/// edit. Everything derived from the failure stays inside comments — the
/// counterexample text is not guaranteed to parse — so the template is
/// always a compilable starting point the user fills in.
fn regression_test_block(
  result : MutationResult,
  kill : Kill,
  ordinal : Int32,
) -> String {
  let mutation = result.mutation
  let counterexample = match kill.counterexample {
    Some(value) => value
    None => "<unavailable>"
  }
  let out = StringBuilder()
  out.write_string(
    "///|\ntest \"turtles regression \{mutation_id(mutation)}-\{ordinal}\" {\n",
  )
  out.write_string(
    "  // Property `\{kill.test_name}` (\{kill.pkg}/\{kill.filename}, index \{kill.index}) killed\n",
  )
  out.write_string(
    "  // \{mutation_id(mutation)} at \{mutation.path}:\{mutation.line}:\{mutation.column}\n",
  )
  out.write_string(
    "  //   `\{mutation.original}` -> `\{mutation.replacement}`\n",
  )
  out.write_string("  // Shrunk counterexample:\n")
  for line in counterexample.split("\n") {
    out.write_string("  //   \{line}\n")
  }
  out.write_string(
    (
      #|  //
      #|  // Call the function under test with that input and assert the
      #|  // property, e.g.:
      #|  //   let actual = function_under_test(counterexample)
      #|  //   debug_inspect(actual)
      #|}
      #|
    ),
  )
  out.to_string()
}

///|
/// The full `*_test.mbt`-style template for one killed mutant: a header
/// pinning the mutant's location and edit, then one `test` block per
/// property kill with a counterexample. None when the mutant has no such
/// kill (assertion/snapshot/doc-test kills, or unavailable attribution).
fn regression_source(result : MutationResult) -> String? {
  let kills = counterexample_kills(result)
  if kills.is_empty() {
    return None
  }
  let mutation = result.mutation
  let out = StringBuilder()
  out.write_string(
    "// turtles regression template -- mutant \{mutation_id(mutation)}\n",
  )
  out.write_string(
    "// \{mutation.path}:\{mutation.line}:\{mutation.column}  `\{mutation.original}` -> `\{mutation.replacement}`\n",
  )
  out.write_string(
    "// Paste the block(s) below into a *_test.mbt file and fill in the\n// function under test with the recorded counterexample.\n\n",
  )
  let mut ordinal = 0
  for kill in kills {
    ordinal = ordinal + 1
    out.write_string(regression_test_block(result, kill, ordinal))
    out.write_string("\n")
  }
  Some(out.to_string())
}

///|
/// Write `regressions/<mutant-id>.mbt` templates for every property kill
/// with a counterexample and sweep templates from earlier runs whose
/// mutants no longer qualify. Only invoked under `--emit-regressions`;
/// the user's source tree is never touched.
async fn write_regression_templates(
  dir : String,
  results : Array[MutationResult],
) -> Unit {
  let regressions_dir = path_join(dir, "regressions")
  @fs.mkdir(regressions_dir, recursive=true, allow_exist=true)
  let live : Map[String, Bool] = Map([])
  for result in results {
    match (regression_relpath(result), regression_source(result)) {
      (Some(_), Some(source)) => {
        let name = mutation_id(result.mutation) + ".mbt"
        live[name] = true
        @fs.write_file(path_join(regressions_dir, name), source)
      }
      _ => ()
    }
  }
  for name in @fs.readdir(regressions_dir, include_hidden=false, sort=false) {
    if name.has_suffix(".mbt") && !live.contains(name) {
      @fs.remove(path_join(regressions_dir, name)) catch {
        _ => ()
      }
    }
  }
}
