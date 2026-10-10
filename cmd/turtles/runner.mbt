///|
/// One place that turns a moon subcommand into argv: every `moon` turtles
/// drives — baseline, mutant check/test, dry-run planning, and the future
/// PBT analyses — goes through this so `--target` forwarding cannot drift
/// between call sites.
fn moon_args(args : Array[String], target : String?) -> Array[String] {
  let command_args = args.copy()
  match target {
    Some(selected) => {
      command_args.push("--target")
      command_args.push(selected)
    }
    None => ()
  }
  command_args
}

///|
#cfg(not(platform="windows"))
async fn supports_group_kill(temp : String) -> Bool {
  // GNU `timeout` provides process-group cleanup on Unix. If it is not
  // installed, commands still use the direct-process hard-cancel path.
  let probe_out = @process.redirect_to_file(temp + "/timeout-probe.log")
  @async.with_timeout_opt(5000, () => {
    @process.run("timeout", ["--version"], stdout=probe_out)
  }) ==
  Some(0)
}

///|
#cfg(platform="windows")
fn supports_group_kill(_temp : String) -> Bool {
  // Windows ships a different command named `timeout`; never run its
  // incompatible `/T` parser with GNU timeout arguments.
  false
}

///|
async fn run_moon_command(
  root : String,
  args : Array[String],
  timeout_ms : Int,
  group_kill : Bool,
  target? : String? = None,
) -> CommandResult {
  let command_args = moon_args(args, target)
  // Nested moon output must not reach our own stdout: when turtles runs
  // inside `moon test`, subprocess output interleaves with the test driver
  // protocol and corrupts result parsing. The log lives next to the
  // workspace so the copied tree stays pristine.
  let output = @process.redirect_to_file(root + "-moon-output.log")
  if group_kill {
    // GNU `timeout` runs moon in a fresh process group and signals the
    // GROUP on expiry — hard-killing only the moon pid orphans its
    // moonc/test-exe children, which then burn CPU until reaped (observed
    // in dogfood: orphaned test exes ran for hours). `with_timeout_opt`
    // remains as a belt around `timeout` itself.
    let secs = timeout_ms.to_double() / 1000.0
    let wrapped = ["--signal=KILL", secs.to_string(), "moon"]
    for arg in command_args {
      wrapped.push(arg)
    }
    let exit_code = @async.with_timeout_opt(timeout_ms + 5000, () => {
      @process.run("timeout", wrapped, cwd=root, stdout=output, stderr=output)
    })
    return match exit_code {
      None | Some(124) => CommandTimeout
      Some(0) => CommandSuccess
      Some(_) => CommandFailure
    }
  }
  let exit_code = @async.with_timeout_opt(timeout_ms, () => {
    @process.run(
      "moon",
      command_args,
      cwd=root,
      stdout=output,
      stderr=output,
      cancel_handler=@process.hard_cancel(),
    )
  })
  match exit_code {
    None => CommandTimeout
    Some(0) => CommandSuccess
    Some(_) => CommandFailure
  }
}

///|
async fn classify_mutant(
  root : String,
  mutation : Mutation,
  check_timeout_ms : Int,
  test_timeout_ms : Int,
  plan : TestPlan?,
  group_kill : Bool,
  target? : String? = None,
) -> (Outcome, Array[String]?, Array[Kill]?) {
  match
    run_moon_command(root, ["check"], check_timeout_ms, group_kill, target~) {
    CommandFailure => return (Unviable, None, None)
    CommandTimeout => return (Timeout, None, None)
    CommandSuccess => ()
  }
  let packages = match plan {
    Some(plan) => plan.test_packages_for(mutation)
    None => None
  }
  let args = mutant_test_args(packages)
  match run_moon_command(root, args, test_timeout_ms, group_kill, target~) {
    CommandSuccess => (Survived, packages, None)
    CommandFailure => (Killed, packages, last_test_failures(root))
    CommandTimeout => (Timeout, packages, None)
  }
}

///|
/// Run an unchanged copy before classifying mutants: divergence between the
/// original module and its temporary workspace is a setup error, not mutant
/// evidence. The baseline gets a generous budget (10x the per-mutant
/// timeout): a slow-but-valid first build must not abort the run, while a
/// mutant that hangs is still bounded by `timeout_ms`.
async fn validate_workspace(
  workspace : String,
  reference : String,
  timeout_ms : Int,
  group_kill : Bool,
  target? : String? = None,
) -> (Int64, Int64) {
  let check_started = @async.now()
  match
    run_moon_command(workspace, ["check"], timeout_ms, group_kill, target~) {
    CommandSuccess => ()
    CommandFailure =>
      fail(
        "temporary workspace failed `moon check`; refusing to classify mutants",
      )
    CommandTimeout =>
      fail("temporary workspace validation timed out during `moon check`")
  }
  let check_ms = @async.now() - check_started
  let test_ms = baseline_test_run(
    workspace,
    reference,
    timeout_ms,
    group_kill,
    target~,
  )
  (check_ms, test_ms)
}

///|
/// Determinism guard: the baseline test suite runs twice with the
/// structured oracle, sweeping the workspace back to its pristine
/// snapshot in between — the same state every mutant workspace starts
/// from. Divergence therefore reports genuine nondeterminism (a
/// property seeded from time, or any other flaky test that can flip
/// KILLED/SURVIVED at random), not state the first run left behind;
/// it aborts naming the unstable tests.
async fn baseline_test_run(
  workspace : String,
  reference : String,
  timeout_ms : Int,
  group_kill : Bool,
  target? : String? = None,
) -> Int64 {
  let test_args = mutant_test_args(None)
  let manifest = snapshot_workspace(workspace)
  let first_started = @async.now()
  let first = run_moon_command(
    workspace,
    test_args,
    timeout_ms,
    group_kill,
    target~,
  )
  let first_ms = @async.now() - first_started
  match first {
    CommandTimeout =>
      fail("temporary workspace validation timed out during `moon test`")
    _ => ()
  }
  let first_kills = last_test_failures(workspace)
  sweep_workspace(workspace, reference, manifest) catch {
    _ => ()
  }
  let second_started = @async.now()
  let second = run_moon_command(
    workspace,
    test_args,
    timeout_ms,
    group_kill,
    target~,
  )
  let second_ms = @async.now() - second_started
  match second {
    CommandTimeout =>
      fail("temporary workspace validation timed out during `moon test`")
    _ => ()
  }
  let second_kills = last_test_failures(workspace)
  let first_failed = first == CommandFailure
  let second_failed = second == CommandFailure
  if first_failed != second_failed {
    abort_unstable_baseline(first_kills, second_kills)
  }
  if first_failed {
    match (first_kills, second_kills) {
      (Some(first_set), Some(second_set)) => {
        let unstable = unstable_kills(first_set, second_set)
        if unstable.length() > 0 {
          abort_unstable_baseline(first_kills, second_kills)
        }
      }
      _ => ()
    }
    fail("temporary workspace failed `moon test`; refusing to classify mutants")
  }
  if first_ms > second_ms {
    first_ms
  } else {
    second_ms
  }
}

///|
/// Abort the run when the two baseline executions disagree. When the
/// oracle produced failure records the unstable tests are named;
/// without them only the divergence itself can be reported.
fn abort_unstable_baseline(
  first_kills : Array[Kill]?,
  second_kills : Array[Kill]?,
) -> Unit raise {
  // A passing run reports no records at all, so treat a missing stream
  // as an empty failure set — its counterpart still names the tests.
  let first_set = match first_kills {
    Some(kills) => kills
    None => []
  }
  let second_set = match second_kills {
    Some(kills) => kills
    None => []
  }
  let unstable = unstable_kills(first_set, second_set)
  let names = if unstable.is_empty() {
    ""
  } else {
    "; unstable test(s): \{unstable.map(describe_kill).join(", ")}"
  }
  fail(
    "baseline `moon test` outcomes differ between two runs\{names}; fix or reseed flaky tests (e.g. pass an explicit `seed~` to `quickcheck.check`) before mutation testing",
  )
}

///|
/// Per-phase mutant timeouts. With `--timeout-multiplier`, each phase is
/// bounded by N times its measured baseline duration, floored at 10s so a
/// sub-second baseline cannot starve a legitimately slower mutant build.
/// The check bound is scaled off `max(check, test)`, not `check` alone:
/// the baseline check runs on a warm copy, while a mutant's check must
/// recompile the mutated package plus everything that links it — on a
/// hub package that recompile can exceed the entire warm test baseline
/// (observed: moonbitlang/core `internal/strconv` checks >10s).
fn effective_timeouts(
  timeout_ms : Int,
  timeout_multiplier : Double?,
  baseline_check_ms : Int64,
  baseline_test_ms : Int64,
) -> (Int, Int) {
  match timeout_multiplier {
    None => (timeout_ms, timeout_ms)
    Some(multiplier) => {
      let floor = 10000
      let check_base = if baseline_check_ms > baseline_test_ms {
        baseline_check_ms
      } else {
        baseline_test_ms
      }
      let check_ms = (multiplier * check_base.to_double()).to_int()
      let test_ms = (multiplier * baseline_test_ms.to_double()).to_int()
      (
        if check_ms > floor {
          check_ms
        } else {
          floor
        },
        if test_ms > floor {
          test_ms
        } else {
          floor
        },
      )
    }
  }
}

///|
/// Run one mutation inside the worker's persistent workspace. The mutated
/// file is written in place (no copy), classified, and the workspace is
/// swept back to its snapshot — manifest files restored byte-for-byte and
/// stray files from test side effects removed. `_build` stays warm: n2
/// tracks content, so a restored source rebuilds cleanly and a
/// timeout-killed build leaves no stale outputs.
async fn run_one_mutant(
  workspace : String,
  reference : String,
  manifest : Ref[WorkspaceManifest],
  mutation : Mutation,
  classify : async (String, Mutation) -> (Outcome, Array[String]?, Array[Kill]?),
) -> MutationResult {
  let target = path_join(workspace, mutation.path)
  let original_source = @fs.read_file(target).text() catch {
    _ => {
      manifest.val = rebuild_workspace(workspace, reference)
      @fs.read_file(path_join(workspace, mutation.path)).text()
    }
  }
  let mutated_source = apply_mutation(original_source, mutation) catch {
    error => {
      // A failed apply means the workspace drifted from its snapshot;
      // rebuild once, then give up loudly if it still does not hold.
      manifest.val = rebuild_workspace(workspace, reference)
      let restored = @fs.read_file(path_join(workspace, mutation.path)).text()
      apply_mutation(restored, mutation) catch {
        _ =>
          fail(
            "mutation cannot be applied even after workspace rebuild: \{error}",
          )
      }
    }
  }
  @fs.write_file(target, mutated_source)
  let started = @async.now()
  // If classify raises, sweep best-effort before propagating so a failed
  // run cannot leave a mutated file for the next mutant.
  errdefer ignore(
    sweep_workspace(workspace, reference, manifest.val) catch {
      _ => ()
    },
  )
  let (outcome, packages, kills) = classify(workspace, mutation)
  let duration_ms = @async.now() - started
  sweep_workspace(workspace, reference, manifest.val) catch {
    _ => manifest.val = rebuild_workspace(workspace, reference)
  }
  {
    mutation,
    outcome,
    duration_ms,
    reused: false,
    packages,
    kills,
    witness: None,
    witness_skipped: None,
    amplified: None,
  }
}

///|
/// Fan mutants out to at most `jobs` workers. Each worker owns one
/// `worker-N` workspace for the whole run, pulling the next unclaimed
/// mutation index and writing the result into its own slot, so report order
/// always matches discovery order no matter how runs interleave. `reuse`
/// carries results recycled from a prior --iterate run; those indices are
/// recorded without running. A worker failure fails the task group, which
/// cancels the remaining workers.
async fn run_mutation_pool(
  temp : String,
  reference : String,
  mutations : Array[Mutation],
  jobs : Int,
  reuse : Array[MutationResult?],
  classify : async (String, Mutation) -> (Outcome, Array[String]?, Array[Kill]?),
) -> Array[MutationResult] {
  let total = mutations.length()
  let slots : Array[MutationResult?] = Array::make(total, None)
  let next_index = Ref(0)
  let completed = Ref(0)
  let worker_count = if jobs < total { jobs } else { total }
  @async.with_task_group(group => {
    for w in 0..<worker_count {
      let workspace = path_join(temp, "worker-\{w}")
      group.spawn_bg(() => {
        @fs.mkdir(workspace, recursive=true)
        copy_tree(reference, reference, workspace)
        let manifest = Ref(snapshot_workspace(workspace))
        while true {
          let index = next_index.val
          if index >= total {
            break
          }
          next_index.val = index + 1
          match reuse[index] {
            Some(result) => {
              slots[index] = Some(result)
              completed.val = completed.val + 1
              println(
                "[\{completed.val}/\{total}] REUSED \{describe_mutation(mutations[index])}",
              )
              continue
            }
            None => ()
          }
          let result = run_one_mutant(
            workspace,
            reference,
            manifest,
            mutations[index],
            classify,
          )
          slots[index] = Some(result)
          completed.val = completed.val + 1
          println(
            "[\{completed.val}/\{total}] \{outcome_name(result.outcome)} \{describe_mutation(mutations[index])}\{describe_kills(result)}",
          )
        }
        // The workspace is worker-local scratch: the outer tmpdir teardown
        // removes it, but free the disk eagerly so large modules do not
        // accumulate N copies for the whole run.
        force_rmdir(workspace) catch {
          _ => ()
        }
      })
    }
  })
  slots.map(slot => slot.unwrap())
}

///|
/// The `reference` tree is snapshotted before any test runs and the baseline
/// executes on a disposable copy of it, so baseline side effects cannot leak
/// into mutants and the module's working tree is never touched. Mutants run
/// in persistent per-worker workspaces that keep `_build` warm at a stable
/// path; isolation comes from restoring the snapshot after each mutant
/// rather than recopying the tree.
async fn run_mutations(
  root : String,
  mutations : Array[Mutation],
  timeout_ms : Int,
  timeout_multiplier : Double?,
  jobs : Int,
  affected : Bool,
  reuse : Array[MutationResult?],
  target? : String? = None,
  emit_properties? : Bool = false,
  pbt_witness? : Bool = false,
  pbt_amplify? : Int? = None,
  output_dir? : String = "",
) -> (
  Int64,
  Int64,
  Int64,
  Array[MutationResult],
  Array[Mutation],
  String,
  Array[String]?,
) {
  let root = @fs.realpath(root)
  let temp = @fs.tmpdir(prefix="turtles")
  @async.with_task_group <| group => {
    group.add_defer(() => {
      @async.protect_from_cancel(() => force_rmdir(temp) catch { _ => () })
    })
    let reference = path_join(temp, "reference")
    @fs.mkdir(reference, recursive=true)
    copy_tree(root, root, reference)
    // One dry-run serves both consumers of Moon's plan: active-source
    // discovery under an explicit --target, and the --affected package
    // graph. The selected backend is forwarded to the dry-run itself, so
    // both describe the same target.
    let moon_plan : MoonPlan? = if affected || target is Some(_) {
      Some(load_moon_plan(reference, target~)) catch {
        error =>
          match target {
            // The active-source set is what keeps backend-inactive files
            // out of the survivor set; a plan that cannot be read is a
            // setup error, not a degraded run.
            Some(_) => fail("cannot read the target-aware plan: \{error}")
            None => {
              println(
                "warning: --affected disabled; cannot read test plan: \{error}",
              )
              None
            }
          }
      }
    } else {
      None
    }
    let plan : TestPlan? = match moon_plan {
      Some(moon_plan) =>
        match moon_plan.test_plan {
          Some(resolved) if affected => Some(resolved)
          Some(_) => None
          None =>
            if affected {
              println(
                "warning: --affected disabled; dry-run plan has unresolved module-local imports",
              )
              None
            } else {
              None
            }
        }
      None => None
    }
    // Partition: only mutants in files Moon compiles for the selected
    // target are classified; the rest are reported target-inactive.
    let (active_mutations, active_reuse, inactive) = match moon_plan {
      Some(moon_plan) =>
        match target {
          Some(_) =>
            partition_by_active_source(
              mutations,
              reuse,
              moon_plan.active_sources,
            )
          None => (mutations, reuse, [])
        }
      None => (mutations, reuse, [])
    }
    match target {
      Some(selected) => {
        println(
          "Target: \{selected} — \{active_mutations.length()} active, \{inactive.length()} target-inactive mutation(s)",
        )
        let inactive_files = unique_sorted_paths(inactive)
        for file in inactive_files {
          println("  target-inactive: \{file}")
        }
      }
      None => ()
    }
    let baseline = path_join(temp, "baseline")
    @fs.mkdir(baseline, recursive=true)
    copy_tree(reference, reference, baseline)
    println("Baseline: moon check + moon test on pristine copy ...")
    let started = @async.now()
    let group_kill = supports_group_kill(temp)
    let (baseline_check_ms, baseline_test_ms) = validate_workspace(
      baseline,
      reference,
      timeout_ms * 10,
      group_kill,
      target~,
    )
    let baseline_duration_ms = @async.now() - started
    println("Baseline: ok")
    let (check_timeout_ms, test_timeout_ms) = effective_timeouts(
      timeout_ms, timeout_multiplier, baseline_check_ms, baseline_test_ms,
    )
    match timeout_multiplier {
      Some(_) =>
        println(
          "Timeouts: check \{check_timeout_ms / 1000}s, test \{test_timeout_ms / 1000}s (from baseline)",
        )
      None => ()
    }
    let classify = (workspace : String, mutation : Mutation) => {
      classify_mutant(
        workspace,
        mutation,
        check_timeout_ms,
        test_timeout_ms,
        plan,
        group_kill,
        target~,
      )
    }
    let results = run_mutation_pool(
      temp, reference, active_mutations, jobs, active_reuse, classify,
    )
    // Survivor analyses run after classification, in the issue's fixed
    // order: amplify first (it can still kill), witness and suggestions
    // see only the final survivors. Everything goes through `moon_args`
    // via run_moon_command, so --target keeps forwarding.
    let properties : Array[String]? = if emit_properties ||
      pbt_witness ||
      pbt_amplify is Some(_) {
      let analysis = path_join(temp, "analysis")
      @fs.mkdir(analysis, recursive=true)
      copy_tree(reference, reference, analysis)
      match (Some(build_module_index(reference)) catch { _ => None }) {
        Some(index) => {
          match pbt_amplify {
            Some(factor) =>
              run_pbt_amplify(
                analysis,
                reference,
                results,
                index,
                factor,
                check_timeout_ms,
                test_timeout_ms,
                group_kill,
                target~,
              )
            None => ()
          }
          if pbt_witness {
            run_pbt_witness(
              analysis,
              reference,
              results,
              index,
              test_timeout_ms,
              group_kill,
              target~,
            )
          }
          let listed : Array[String]? = if emit_properties {
            Some(
              emit_property_files(
                output_dir,
                results,
                index,
                module_name_of(reference),
                target,
              ),
            )
          } else {
            None
          }
          force_rmdir(analysis) catch {
            _ => ()
          }
          listed
        }
        None => {
          println(
            "warning: survivor analysis skipped; could not index the module",
          )
          force_rmdir(analysis) catch {
            _ => ()
          }
          None
        }
      }
    } else {
      None
    }
    let scope = match plan {
      Some(_) => "affected"
      None => "module"
    }
    (
      baseline_duration_ms, baseline_check_ms, baseline_test_ms, results, inactive,
      scope, properties,
    )
  }
}
