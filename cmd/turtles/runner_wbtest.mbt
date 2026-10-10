///|
// The timeout probe must survive an absent `timeout` executable, then select
// the next candidate. Absolute paths make this test independent of PATH.
#cfg(all(target="native", not(platform="windows")))
async test "missing group-timeout executable falls through to the next candidate" {
  let temp = @fs.tmpdir(prefix="turtles-timeout-probe")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let missing = path_join(temp, "missing-timeout")
    let gtimeout = path_join(temp, "gtimeout")
    @fs.write_file(gtimeout, "#!/bin/sh\nexit 0\n")
    @fs.chmod(gtimeout, 0o755)
    let found = probe_group_timeout_from(temp, [missing, gtimeout])
    assert_eq(found, Some(gtimeout))
  })
}

///|
/// Exercise the real GNU helper when available. A KILL timeout and a child
/// that exits 137 can have the same shell status, so the helper diagnostic
/// must distinguish them before classification.
#cfg(all(target="native", not(platform="windows")))
async test "GNU group timeout distinguishes expiry from child exit 137" {
  let temp = @fs.tmpdir(prefix="turtles-timeout-result")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    match
      probe_group_timeout_from(temp, [
        "gtimeout", "/opt/homebrew/bin/gtimeout", "timeout",
      ]) {
      Some(executable) => {
        let expired_log = temp + "/expired.log"
        let expired_output = @process.redirect_to_file(expired_log)
        let expired = @process.run(
          executable,
          ["--verbose", "--signal=KILL", "0.1", "/bin/sleep", "5"],
          stdout=expired_output,
          stderr=expired_output,
        )
        let expiry_text = @fs.read_file(expired_log).text()
        let expired_by_helper = group_timeout_sent_kill(expiry_text)
        assert_true(
          group_timeout_result(Some(expired), expired_by_helper) ==
          CommandTimeout,
        )
        let child_log = temp + "/child-137.log"
        let child_output = @process.redirect_to_file(child_log)
        let child_exit = @process.run(
          executable,
          ["--verbose", "--signal=KILL", "5", "/bin/sh", "-c", "exit 137"],
          stdout=child_output,
          stderr=child_output,
        )
        assert_eq(child_exit, 137)
        let child_text = @fs.read_file(child_log).text()
        assert_true(
          group_timeout_result(
            Some(child_exit),
            group_timeout_sent_kill(child_text),
          ) ==
          CommandFailure,
        )
      }
      None => println("Skipping GNU timeout regression: helper is unavailable")
    }
  })
}

///|
async fn write_order_fixture(dir : String) -> Unit {
  @fs.write_file(
    path_join(dir, "moon.mod"),
    "name = \"turtles_order_fixture\"\nversion = \"0.1.0\"\n",
  )
  @fs.write_file(path_join(dir, "moon.pkg"), "")
  @fs.write_file(
    path_join(dir, "order.mbt"),
    (
      #|pub fn add(a : Int, b : Int) -> Int {
      #|  a + b
      #|}
      #|pub fn pick(a : Int, b : Int) -> Bool {
      #|  a < b
      #|}
      #|
    ),
  )
  @fs.write_file(
    path_join(dir, "order_test.mbt"),
    "test \"add\" { inspect(add(1, 2), content=\"3\") }\n",
  )
}

///|
async test "mutant ordering does not change classifications" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let module_dir = path_join(temp, "module")
    @fs.mkdir(module_dir, recursive=true)
    write_order_fixture(module_dir)
    let mutations = discover_mutations(
      module_dir,
      None,
      default_project_config(),
      [],
      [],
    )
    inspect(mutations.length(), content="2")
    let (_, _, _, forward, _, _, _) = run_mutations(
      module_dir,
      mutations,
      120000,
      None,
      2,
      false,
      Array::make(mutations.length(), None),
    )
    let reversed : Array[Mutation] = []
    for i = mutations.length() - 1; i >= 0; i = i - 1 {
      reversed.push(mutations[i])
    }
    let (_, _, _, backward, _, _, _) = run_mutations(
      module_dir,
      reversed,
      120000,
      None,
      1,
      false,
      Array::make(reversed.length(), None),
    )
    let mut mismatched = false
    for result in forward {
      for other in backward {
        if same_mutation_identity(result.mutation, other.mutation) &&
          result.outcome != other.outcome {
          mismatched = true
        }
      }
    }
    assert_false(mismatched)
    inspect(
      forward.map(result => outcome_name(result.outcome)).join(","),
      content="KILLED,SURVIVED",
    )
    inspect(
      backward.map(result => outcome_name(result.outcome)).join(","),
      content="SURVIVED,KILLED",
    )
  })
}

///|
async test "native target selects native-only tests for classification" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let module_dir = path_join(temp, "module")
    @fs.mkdir(module_dir, recursive=true)
    write_order_fixture(module_dir)
    @fs.write_file(
      path_join(module_dir, "moon.pkg"),
      "options(targets: { \"order_test.mbt\": [\"native\"] })\n",
    )
    let mutations = discover_mutations(
      module_dir,
      None,
      default_project_config(),
      [],
      [],
    )
    let (_, _, _, results, _, _, _) = run_mutations(
      module_dir,
      mutations,
      120000,
      None,
      1,
      false,
      Array::make(mutations.length(), None),
      target=Some("native"),
    )
    assert_true(
      results.any(result => {
        result.mutation.original == "+" && result.outcome == Killed
      }),
    )
  })
}

///|
async test "reported durations never exceed the wall clock" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let module_dir = path_join(temp, "module")
    @fs.mkdir(module_dir, recursive=true)
    write_order_fixture(module_dir)
    let mutations = discover_mutations(
      module_dir,
      None,
      default_project_config(),
      [],
      [],
    )
    let started = @async.now()
    let (baseline_duration_ms, _, _, results, _, _, _) = run_mutations(
      module_dir,
      mutations,
      120000,
      None,
      1,
      false,
      Array::make(mutations.length(), None),
    )
    let elapsed = @async.now() - started
    assert_true(baseline_duration_ms <= elapsed)
    for result in results {
      assert_true(result.duration_ms <= elapsed)
    }
  })
}

///|
/// A stub classifier records how many mutant runs overlap, so the pool's
/// bound and ordering can be proven without invoking `moon`.
async test "mutation pool bounds concurrency and preserves discovery order" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let module_dir = path_join(temp, "module")
    @fs.mkdir(module_dir, recursive=true)
    write_order_fixture(module_dir)
    let mutations = discover_mutations(
      module_dir,
      None,
      default_project_config(),
      [],
      [],
    )
    inspect(mutations.length(), content="2")
    let pool_dir = path_join(temp, "pool")
    @fs.mkdir(pool_dir, recursive=true)
    let reference = path_join(pool_dir, "reference")
    @fs.mkdir(reference, recursive=true)
    copy_tree(module_dir, module_dir, reference)
    let in_flight = Ref(0)
    let max_in_flight = Ref(0)
    let results = run_mutation_pool(
      pool_dir,
      reference,
      mutations,
      3,
      Array::make(mutations.length(), None),
      (_workspace, mutation) => {
        in_flight.val = in_flight.val + 1
        if in_flight.val > max_in_flight.val {
          max_in_flight.val = in_flight.val
        }
        // Wait for both classifiers to enter before measuring overlap. Worker
        // workspace setup is filesystem work and can exceed a short sleep on
        // a loaded Windows runner; the bound keeps a scheduling regression
        // from hanging the test.
        let overlap_started = @async.now()
        while in_flight.val < 2 && @async.now() - overlap_started < 5000 {
          @async.sleep(10)
        }
        let first = mutation.original == "+"
        // Once both classifiers have entered, the `+` mutation takes
        // substantially longer than `-`, forcing completion order to differ
        // from discovery order without depending on workspace setup latency.
        @async.sleep(if first { 500 } else { 20 })
        in_flight.val = in_flight.val - 1
        let outcome = if first { Killed } else { Survived }
        (outcome, None, None)
      },
    )
    inspect(results.length(), content="2")
    assert_true(max_in_flight.val > 1)
    assert_true(max_in_flight.val <= 3)
    for i, result in results {
      assert_true(same_mutation_identity(result.mutation, mutations[i]))
    }
    inspect(
      results.map(result => outcome_name(result.outcome)).join(","),
      content="KILLED,SURVIVED",
    )
    // Each mutant workspace was removed once its run finished.
    json_inspect(@fs.readdir(pool_dir, include_hidden=true, sort=true), content=[
      "reference",
    ])
  })
}

///|
async test "jobs=1 keeps mutant runs sequential" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let module_dir = path_join(temp, "module")
    @fs.mkdir(module_dir, recursive=true)
    write_order_fixture(module_dir)
    let mutations = discover_mutations(
      module_dir,
      None,
      default_project_config(),
      [],
      [],
    )
    let pool_dir = path_join(temp, "pool")
    @fs.mkdir(pool_dir, recursive=true)
    let reference = path_join(pool_dir, "reference")
    @fs.mkdir(reference, recursive=true)
    copy_tree(module_dir, module_dir, reference)
    let in_flight = Ref(0)
    let max_in_flight = Ref(0)
    let results = run_mutation_pool(
      pool_dir,
      reference,
      mutations,
      1,
      Array::make(mutations.length(), None),
      (_workspace, _mutation) => {
        in_flight.val = in_flight.val + 1
        if in_flight.val > max_in_flight.val {
          max_in_flight.val = in_flight.val
        }
        @async.sleep(20)
        in_flight.val = in_flight.val - 1
        (Killed, None, None)
      },
    )
    inspect(max_in_flight.val, content="1")
    inspect(results.length(), content="2")
  })
}

///|
/// A classify that raises must fail the whole pool instead of dropping
/// mutants silently: run_mutations surfaces it as a setup error (exit 2).
async test "a failing mutant run fails the pool" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let module_dir = path_join(temp, "module")
    @fs.mkdir(module_dir, recursive=true)
    write_order_fixture(module_dir)
    let mutations = discover_mutations(
      module_dir,
      None,
      default_project_config(),
      [],
      [],
    )
    let pool_dir = path_join(temp, "pool")
    @fs.mkdir(pool_dir, recursive=true)
    let reference = path_join(pool_dir, "reference")
    @fs.mkdir(reference, recursive=true)
    copy_tree(module_dir, module_dir, reference)
    let mut raised = false
    ignore(
      run_mutation_pool(
        pool_dir,
        reference,
        mutations,
        2,
        Array::make(mutations.length(), None),
        (_w, _m) => {
          @async.sleep(5)
          fail("classifier exploded")
        },
      ),
    ) catch {
      _ => raised = true
    }
    assert_true(raised)
  })
}

///|
test "moon_args forwards the target flag once, verbatim" {
  assert_eq(moon_args(["check"], Some("native")), [
    "check", "--target", "native",
  ])
  assert_eq(moon_args(["test", "--dry-run"], Some("all")), [
    "test", "--dry-run", "--target", "all",
  ])
  assert_eq(moon_args(["check"], None), ["check"])
}

///|
/// Mutants in files Moon does not compile for the target are partitioned
/// out before classification — they can never land in the survivor set.
async test "target-inactive mutants are partitioned out of classification" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let module_dir = path_join(temp, "module")
    @fs.mkdir(module_dir, recursive=true)
    @fs.write_file(
      path_join(module_dir, "moon.mod"),
      "name = \"turtles_partition_fixture\"\nversion = \"0.1.0\"\n",
    )
    @fs.write_file(
      path_join(module_dir, "moon.pkg"),
      "options(targets: { \"pick.mbt\": [\"js\"], \"pick_test.mbt\": [\"js\"] })\n",
    )
    @fs.write_file(
      path_join(module_dir, "order.mbt"),
      "pub fn add(a : Int, b : Int) -> Int {\n  a + b\n}\n",
    )
    @fs.write_file(
      path_join(module_dir, "pick.mbt"),
      "pub fn pick(a : Int, b : Int) -> Bool {\n  a < b\n}\n",
    )
    @fs.write_file(
      path_join(module_dir, "order_test.mbt"),
      "test \"add\" { inspect(add(1, 2), content=\"3\") }\n",
    )
    @fs.write_file(
      path_join(module_dir, "pick_test.mbt"),
      "test \"pick\" { inspect(pick(1, 2), content=\"true\") }\n",
    )
    let mutations = discover_mutations(
      module_dir,
      None,
      default_project_config(),
      [],
      [],
    )
    inspect(mutations.length(), content="2")
    let (_, _, _, results, inactive, _, _) = run_mutations(
      module_dir,
      mutations,
      120000,
      None,
      1,
      false,
      Array::make(mutations.length(), None),
      target=Some("native"),
    )
    // The native-active `+` mutant was classified; the js-only `<` was not.
    inspect(results.length(), content="1")
    json_inspect(results.map(result => result.mutation.path), content=[
      "order.mbt",
    ])
    json_inspect(inactive.map(mutation => mutation.path), content=["pick.mbt"])
  })
}

///|
/// --affected under an explicit target consumes the same target-aware
/// dry-run that produced the active-source set.
async test "affected plan retains the selected target" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let module_dir = path_join(temp, "module")
    @fs.mkdir(module_dir, recursive=true)
    write_order_fixture(module_dir)
    let mutations = discover_mutations(
      module_dir,
      None,
      default_project_config(),
      [],
      [],
    )
    let (_, _, _, results, _, scope, _) = run_mutations(
      module_dir,
      mutations,
      120000,
      None,
      1,
      true,
      Array::make(mutations.length(), None),
      target=Some("native"),
    )
    inspect(scope, content="affected")
    inspect(results.length(), content="2")
  })
}

///|
async test "pristine workspace validation failure aborts as a setup error" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let workspace = path_join(temp, "workspace")
    @fs.mkdir(workspace, recursive=true)
    let mut raised = false
    ignore(validate_workspace(workspace, workspace, 30000, None)) catch {
      _ => raised = true
    }
    assert_true(raised)
  })
}

///|
/// `--timeout-multiplier` bounds each phase at N times its measured baseline,
/// floored at 10s; the check bound scales off max(check, test) because a
/// mutant's recompile can dwarf the warm check.
test "effective_timeouts scales off baselines with a 10s floor" {
  let (flat_check, flat_test) = effective_timeouts(60000, None, 100L, 200L)
  inspect(flat_check, content="60000")
  inspect(flat_test, content="60000")
  let (check_ms, test_ms) = effective_timeouts(60000, Some(3.0), 1000L, 4000L)
  inspect(check_ms, content="12000")
  inspect(test_ms, content="12000")
  let (hub_check, hub_test) = effective_timeouts(60000, Some(3.0), 9000L, 1000L)
  inspect(hub_check, content="27000")
  inspect(hub_test, content="10000")
}
