///|
async fn execute() -> Int {
  let config = parse_args(@env.args())
  execute_with_config(config)
}

///|
/// `moon --version`, best-effort — the report records it so --iterate can
/// refuse to reuse verdicts produced by a different toolchain.
async fn capture_moon_version() -> String? {
  let tmp = @fs.tmpdir(prefix="turtles-version")
  defer (force_rmdir(tmp) catch { _ => () })
  let log = path_join(tmp, "moon-version.log")
  let output = @process.redirect_to_file(log)
  let code = @process.run("moon", ["--version"], stdout=output, stderr=output) catch {
    _ => return None
  }
  guard code == 0 else { return None }
  let text = @fs.read_file(log).text() catch { _ => return None }
  let lines = text.split("\n").collect()
  if lines.length() == 0 {
    return None
  }
  let trimmed = lines[0].trim().to_owned()
  if trimmed == "" {
    None
  } else {
    Some(trimmed)
  }
}

///|
/// Content fingerprints of every file classification can observe: all .mbt
/// sources (tests included — a test change can flip an outcome), package and
/// module manifests, and turtles.toml. --iterate refuses reuse the moment
/// any of these diverge from the recorded run.
async fn fingerprint_files(root : String) -> Map[String, String] {
  let files : Array[String] = []
  collect_fingerprint_files(root, root, files)
  let fingerprints : Map[String, String] = Map([])
  for relative in files {
    let bytes = @fs.read_file(path_join(root, relative)).binary() catch {
      _ => continue
    }
    fingerprints[relative] = fingerprint_hex(fnv1a(bytes))
  }
  fingerprints
}

///|
/// Map prior-report verdicts onto the current mutant set for --iterate.
/// Index-aligned with `mutations`: Some(result) skips classification.
async fn iterate_reuse(
  output_dir : String,
  mutations : Array[Mutation],
  files : Map[String, String],
  moon_version : String?,
  target : String?,
  pbt_amplify : Int?,
) -> Array[MutationResult?] {
  let reuse : Array[MutationResult?] = Array::make(mutations.length(), None)
  let report_path = path_join(output_dir, "report.json")
  match load_prior_report(report_path) {
    Some(prior) =>
      if !fingerprints_match(prior.files, files) {
        println(
          "Iterate: source/test/manifest fingerprints changed since \{report_path}; running fresh",
        )
      } else {
        let mut matched = 0
        for i = 0; i < mutations.length(); i = i + 1 {
          match
            prior_reusable_outcome(
              prior,
              mutations[i],
              files,
              moon_version,
              target~,
            ) {
            Some((outcome, kills, amplified)) => {
              reuse[i] = Some({
                mutation: mutations[i],
                outcome,
                duration_ms: 0L,
                reused: true,
                packages: None,
                kills,
                witness: None,
                witness_skipped: None,
                // Amplification-derived kills are refused by the reuse
                // guard; this marker cannot erase their provenance.
                amplified: if pbt_amplify is Some(_) && amplified {
                  Some(true)
                } else {
                  None
                },
              })
              matched = matched + 1
            }
            None => ()
          }
        }
        println(
          "Iterate: reusing \{matched}/\{mutations.length()} verdicts from \{report_path}",
        )
      }
    None =>
      println("Iterate: no reusable report at \{report_path}; running fresh")
  }
  reuse
}

///|
/// Print the mutants a run would classify. With an explicit --target,
/// Moon's dry-run on a pristine temporary reference decides which files
/// compile for the backend — inactive mutants are reported but never
/// listed as mutants, and no baseline or mutant test runs.
async fn print_mutation_list(
  root : String,
  mutations : Array[Mutation],
  skipped_blocks : Array[SkippedBlock],
  target : String?,
) -> Unit {
  let (listed, inactive) = match target {
    Some(_) => {
      let temp = @fs.tmpdir(prefix="turtles-list")
      let reference = path_join(temp, "reference")
      @fs.mkdir(reference, recursive=true)
      copy_tree(root, root, reference)
      let plan : MoonPlan = load_moon_plan(reference, target~) catch {
        error => {
          force_rmdir(temp) catch {
            _ => ()
          }
          fail("\{error}")
        }
      }
      force_rmdir(temp) catch {
        _ => ()
      }
      let (active, _, inactive) = partition_by_active_source(
        mutations,
        [],
        plan.active_sources,
      )
      (active, inactive)
    }
    None => (mutations, [])
  }
  for mutation in listed {
    println(
      "\{describe_mutation(mutation)} [\{visibility_name(mutation.visibility)}]",
    )
  }
  for block in skipped_blocks {
    println("  \{block.path}:\{block.line} (skipped)")
  }
  match target {
    Some(selected) => {
      println(
        "Target \{selected}: \{inactive.length()} target-inactive mutation(s) not listed",
      )
      for file in unique_sorted_paths(inactive) {
        println("  target-inactive: \{file}")
      }
    }
    None => ()
  }
}

///|
async fn execute_with_config(config : Config) -> Int {
  let root = @fs.realpath(config.dir)
  ensure_moonbit_module(root)
  let project_config = load_project_config(root)
  // `--operators` replaces the turtles.toml list wholesale.
  let project_config = match config.operators {
    Some(groups) => { ..project_config, operators: Some(groups), }
    None => project_config
  }
  let moon_version = capture_moon_version()
  let skipped : Array[SkippedFile] = []
  let skipped_blocks : Array[SkippedBlock] = []
  let mutations = discover_mutations(
    root,
    config.file_filter,
    project_config,
    skipped,
    skipped_blocks,
  )
  if mutations.is_empty() {
    println("No mutations found.")
  } else {
    println("Found \{mutations.length()} mutation(s).")
  }
  if skipped.length() > 0 {
    println("Skipped \{skipped.length()} file(s) that failed to parse:")
    for entry in skipped {
      println("  \{entry.path}: \{entry.error}")
    }
  }
  if skipped_blocks.length() > 0 {
    println(
      "Skipped \{skipped_blocks.length()} block(s) marked with a turtles skip marker.",
    )
  }
  if config.list {
    print_mutation_list(root, mutations, skipped_blocks, config.target)
    return 0
  }

  let files = fingerprint_files(root)
  let (output_dir, default_dir) = match config.output_dir {
    Some(dir) => (dir, false)
    None => (path_join(root, ".turtles"), true)
  }
  let reuse = if config.iterate {
    iterate_reuse(
      output_dir,
      mutations,
      files,
      moon_version,
      config.target,
      config.pbt_amplify,
    )
  } else {
    Array::make(mutations.length(), None)
  }
  let (
    baseline_duration_ms,
    baseline_check_ms,
    baseline_test_ms,
    results,
    inactive,
    scope,
    properties,
  ) = run_mutations(
    root,
    mutations,
    config.timeout_ms,
    config.timeout_multiplier,
    config.jobs,
    config.affected,
    reuse,
    target=config.target,
    emit_properties=config.emit_properties,
    pbt_witness=config.pbt_witness,
    pbt_amplify=config.pbt_amplify,
    output_dir~,
  )
  let counts = count_outcomes(results)
  let score = mutation_score(counts.0, counts.1, counts.2)
  let reused = results.filter(result => result.reused).length()
  println("")
  println("Mutation testing complete:")
  match config.target {
    Some(selected) => println("  target:    \{selected}")
    None => ()
  }
  println("  killed:    \{counts.0}")
  println("  survived:  \{counts.1}")
  println("  timeout:   \{counts.2}")
  println("  unviable:  \{counts.3}")
  if inactive.length() > 0 {
    println("  inactive:  \{inactive.length()} (excluded from score)")
  }
  if reused > 0 {
    println("  reused:    \{reused}")
  }
  println("  score:     \{score}%")
  let public_split = visibility_summary(results, Public)
  if public_split.mutants > 0 {
    let public_viable = public_split.killed +
      public_split.survived +
      public_split.timeout
    println(
      "  public:    \{public_split.score}% (\{public_split.killed}/\{public_viable} viable killed, \{public_split.mutants} mutants)",
    )
  }
  let private_split = visibility_summary(results, Private)
  if private_split.mutants > 0 {
    let private_viable = private_split.killed +
      private_split.survived +
      private_split.timeout
    println(
      "  private:   \{private_split.score}% (\{private_split.killed}/\{private_viable} viable killed, \{private_split.mutants} mutants)",
    )
  }
  let test_split = visibility_summary(results, Test)
  if test_split.mutants > 0 {
    println(
      "  test:      \{test_split.mutants} mutant(s) in test blocks (outside the score split)",
    )
  }
  match config.fail_under {
    Some(threshold) =>
      if score >= threshold {
        println("  threshold: >=\{threshold}% met")
      } else {
        println("  threshold: >=\{threshold}% NOT met")
      }
    None => ()
  }

  let regressions = if config.emit_regressions {
    regression_paths(results)
  } else {
    []
  }
  let report = build_report(
    root,
    moon_version,
    baseline_duration_ms,
    baseline_check_ms,
    baseline_test_ms,
    scope,
    results,
    skipped,
    files,
    score,
    regressions~,
    target=config.target,
    inactive~,
    properties~,
  )
  write_output_dir(
    output_dir,
    root,
    results,
    report,
    default_dir,
    emit_regressions=config.emit_regressions,
  )
  if config.emit_regressions {
    println("  regressions: \{regressions.length()} template(s)")
  }
  match properties {
    Some(list) => println("  properties: \{list.length()} suggestion(s)")
    None => ()
  }
  println("  report:    \{path_join(output_dir, "report.json")}")
  match config.json_report {
    Some(path) => {
      write_json_report(path, report)
      println("  json:      \{path}")
    }
    None => ()
  }

  let attention = needs_attention(results)
  if attention.length() > 0 {
    println("")
    println("Mutants needing attention:")
    for result in attention {
      println("  \{describe_result(result)}")
    }
  }

  final_exit_code(counts.1, counts.2, score, config.fail_under)
}

///|
/// The mutants a user must act on, in report order.
fn needs_attention(results : Array[MutationResult]) -> Array[MutationResult] {
  results.filter(result => {
    result.outcome == Survived || result.outcome == Timeout
  })
}

///|
/// One recap line: outcome, location and edit, and the operator group.
fn describe_result(result : MutationResult) -> String {
  "\{outcome_name(result.outcome)} \{describe_mutation(result.mutation)} [\{operator_group_name(result.mutation.group)}]"
}

///|
/// A `--fail-under` threshold replaces the default all-or-nothing verdict:
/// met → 0 even with surviving mutants, missed → 1. TIMEOUT mutants already
/// count as not-killed in the score, so timing-out code cannot hide behind a
/// threshold. Setup failures exit 2 regardless (handled by `main`).
fn final_exit_code(
  survived : Int,
  timeout : Int,
  score : Double,
  fail_under : Double?,
) -> Int {
  match fail_under {
    Some(threshold) => if score >= threshold { 0 } else { 1 }
    None => if survived > 0 || timeout > 0 { 1 } else { 0 }
  }
}

///|
async fn main {
  let exit_code = execute() catch {
    error => {
      @stdio.stderr.write("turtles: \{error}\n")
      2
    }
  }
  @sys.exit(exit_code)
}
