///|
fn count_outcomes(
  results : Array[MutationResult],
) -> (Int32, Int32, Int32, Int32) {
  let mut killed = 0
  let mut survived = 0
  let mut timeout = 0
  let mut unviable = 0
  for result in results {
    match result.outcome {
      Killed => killed = killed + 1
      Survived => survived = survived + 1
      Timeout => timeout = timeout + 1
      Unviable => unviable = unviable + 1
    }
  }
  (killed, survived, timeout, unviable)
}

///|
fn mutation_score(killed : Int32, survived : Int32, timeout : Int32) -> Double {
  let viable = killed + survived + timeout
  if viable == 0 {
    100.0
  } else {
    killed.to_double() * 100.0 / viable.to_double()
  }
}

///|
/// Additive attribution fields: KILLED mutants carry the structured
/// failure records that caught them. `attribution: "unavailable"` marks
/// a kill where the oracle emitted nothing parseable (older moon,
/// crashed test binary, abort before tests ran) — the verdict still
/// stands on the exit status alone.
fn json_mutation(result : MutationResult) -> JsonMutation {
  let (killed_by, attribution) = match (result.outcome, result.kills) {
    (Killed, Some(kills)) => (Some(kills), None)
    (Killed, None) => (Some([]), Some("unavailable"))
    _ => (None, None)
  }
  {
    id: mutation_id(result.mutation),
    path: result.mutation.path,
    line: result.mutation.line,
    column: result.mutation.column,
    offset: result.mutation.start,
    end: result.mutation.end,
    group: operator_group_name(result.mutation.group),
    visibility: visibility_name(result.mutation.visibility),
    original: result.mutation.original,
    replacement: result.mutation.replacement,
    outcome: outcome_name(result.outcome),
    duration_ms: result.duration_ms,
    reused: result.reused,
    packages: result.packages,
    killed_by,
    attribution,
    witness: result.witness,
    witness_skipped: result.witness_skipped,
    amplified: result.amplified,
  }
}

///|
/// Per-kind tallies over every recorded kill, plus the headline PBT
/// metric: mutants whose entire kill attribution is property tests —
/// mutants only QuickCheck could have caught.
fn kill_counts(results : Array[MutationResult]) -> (JsonKillCounts, Int32) {
  let mut property = 0
  let mut snapshot = 0
  let mut doc_test = 0
  let mut assertion = 0
  let mut property_only = 0
  for result in results {
    guard result.outcome == Killed else { continue }
    match result.kills {
      Some(kills) => {
        let mut saw_other = false
        for kill in kills {
          match kill.kind {
            Property => property = property + 1
            Snapshot => {
              snapshot = snapshot + 1
              saw_other = true
            }
            DocTest => {
              doc_test = doc_test + 1
              saw_other = true
            }
            Assertion => {
              assertion = assertion + 1
              saw_other = true
            }
          }
        }
        if kills.length() > 0 && !saw_other {
          property_only = property_only + 1
        }
      }
      None => ()
    }
  }
  ({ property, snapshot, doc_test, assertion, }, property_only)
}

///|
/// Sorted module-relative paths holding at least one target-inactive
/// mutant — the report's `inactive_files`, and the console detail line.
fn unique_sorted_paths(mutants : Array[Mutation]) -> Array[String] {
  let seen : Map[String, Bool] = Map([])
  for mutation in mutants {
    seen[mutation.path] = true
  }
  let files : Array[String] = []
  for file, _ in seen {
    files.push(file)
  }
  files.sort()
  files
}

///|
/// Outcome tallies and score restricted to one visibility bucket,
/// using the same killed-over-viable rule as the headline score.
fn visibility_summary(
  results : Array[MutationResult],
  visibility : MutantVisibility,
) -> JsonVisibilitySummary {
  let mut mutants = 0
  let mut killed = 0
  let mut survived = 0
  let mut timeout = 0
  let mut unviable = 0
  for result in results {
    guard result.mutation.visibility == visibility else { continue }
    mutants = mutants + 1
    match result.outcome {
      Killed => killed = killed + 1
      Survived => survived = survived + 1
      Timeout => timeout = timeout + 1
      Unviable => unviable = unviable + 1
    }
  }
  {
    mutants,
    killed,
    survived,
    timeout,
    unviable,
    score: mutation_score(killed, survived, timeout),
  }
}

///|
fn build_report(
  root : String,
  moon_version : String?,
  baseline_duration_ms : Int64,
  baseline_check_ms : Int64,
  baseline_test_ms : Int64,
  test_scope : String,
  results : Array[MutationResult],
  skipped : Array[SkippedFile],
  files : Map[String, String],
  score : Double,
  regressions~ : Array[String] = [],
  target~ : String? = None,
  inactive~ : Array[Mutation] = [],
  properties~ : Array[String]? = None,
) -> JsonReport {
  let mutants : Array[JsonMutation] = []
  let mut reused = 0
  for result in results {
    mutants.push(json_mutation(result))
    if result.reused {
      reused = reused + 1
    }
  }
  let counts = count_outcomes(results)
  let (kills_by_kind, property_only_kills) = kill_counts(results)
  let skipped_files : Array[JsonSkippedFile] = []
  for entry in skipped {
    skipped_files.push({ path: entry.path, error: entry.error, })
  }
  {
    schema: 3,
    module_path: root,
    turtles_version,
    moon_version,
    target,
    inactive_mutants: inactive.length(),
    inactive_files: unique_sorted_paths(inactive),
    baseline_duration_ms,
    baseline_check_ms: Some(baseline_check_ms),
    baseline_test_ms: Some(baseline_test_ms),
    test_scope,
    mutants,
    summary: {
      killed: counts.0,
      survived: counts.1,
      timeout: counts.2,
      unviable: counts.3,
      reused,
      score,
      kills_by_kind,
      property_only_kills,
      score_public: visibility_summary(results, Public),
      score_private: visibility_summary(results, Private),
    },
    skipped_files,
    files: Some(files),
    regressions,
    properties,
  }
}

///|
/// Write `report.json` plus a `survivors/<id>.diff` unified hunk for every
/// survived or timed-out mutant — the artifact that makes an unresolved
/// verdict immediately actionable. Stale diffs from an earlier run are
/// removed so the directory only ever shows mutants the current run
/// produced. The `*` self-ignore is written only for the default
/// `.turtles` directory and only when absent: a custom `--output-dir` or
/// an existing `.gitignore` belongs to the user.
async fn write_output_dir(
  dir : String,
  root : String,
  results : Array[MutationResult],
  report : JsonReport,
  default_dir : Bool,
  emit_regressions~ : Bool = false,
) -> Unit {
  let survivors_dir = path_join(dir, "survivors")
  @fs.mkdir(survivors_dir, recursive=true, allow_exist=true)
  if default_dir && !@fs.exists(path_join(dir, ".gitignore")) {
    @fs.write_file(path_join(dir, ".gitignore"), "*\n")
  }
  let live_diffs : Map[String, Bool] = Map([])
  for result in results {
    if result.outcome is (Survived | Timeout) {
      live_diffs[mutation_id(result.mutation) + ".diff"] = true
      let source_path = path_join(root, result.mutation.path)
      let original = @fs.read_file(source_path).text() catch { _ => continue }
      let mutated = apply_mutation(original, result.mutation) catch {
        _ => continue
      }
      let diff = unified_mutation_diff(result.mutation.path, original, mutated)
      @fs.write_file(
        path_join(survivors_dir, mutation_id(result.mutation) + ".diff"),
        diff,
      )
    }
  }
  for name in @fs.readdir(survivors_dir, include_hidden=false, sort=false) {
    if name.has_suffix(".diff") && !live_diffs.contains(name) {
      @fs.remove(path_join(survivors_dir, name)) catch {
        _ => ()
      }
    }
  }
  if emit_regressions {
    write_regression_templates(dir, results)
  }
  let output = @json.to_json(report).stringify(indent=2) + "\n"
  @fs.write_file(path_join(dir, "report.json"), output)
}

///|
async fn write_json_report(path : String, report : JsonReport) -> Unit {
  let parent = @path.Path(path).dirname().to_string()
  if parent != "" {
    @fs.mkdir(parent, recursive=true, allow_exist=true)
  }
  let output = @json.to_json(report).stringify(indent=2) + "\n"
  @fs.write_file(path, output)
}
