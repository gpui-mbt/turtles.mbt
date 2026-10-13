///|
fn mk_mutation(
  path : String,
  start : Int32,
  end : Int32,
  original : String,
  replacement : String,
) -> Mutation {
  {
    path,
    start,
    end,
    line: 1,
    column: 1,
    original,
    replacement,
    group: Arithmetic,
    visibility: Private,
  }
}

///|
fn mk_prior(
  schema : Int32,
  turtles : String?,
  moon : String?,
  file_hash : String,
  outcome : Outcome,
  kills : Array[Kill]?,
) -> PriorReport {
  let m = mk_mutation("a.mbt", 0, 1, "+", "-")
  let mutants : Map[String, (Mutation, Outcome, Array[Kill]?, Bool)] = Map([])
  mutants[mutation_identity(m)] = (m, outcome, kills, false)
  let files : Map[String, String] = Map([])
  files["a.mbt"] = file_hash
  {
    schema,
    turtles_version: turtles,
    moon_version: moon,
    target: None,
    files,
    mutants,
  }
}

///|
test "iterate reuses only identity-matched KILLED/UNVIABLE under same toolchain" {
  let current : Map[String, String] = Map([])
  current["a.mbt"] = "hash-a"
  let m = mk_mutation("a.mbt", 0, 1, "+", "-")
  let prior = mk_prior(
    3,
    Some(turtles_version),
    Some("moon x"),
    "hash-a",
    Killed,
    None,
  )
  match prior_reusable_outcome(prior, m, current, Some("moon x")) {
    Some((Killed, None, _)) => ()
    _ => fail("expected reused KILLED")
  }
  assert_true(
    prior_reusable_outcome(
      prior,
      m,
      current,
      Some("moon x"),
      target=Some("native"),
    )
    is None,
  )
  let native_prior = { ..prior, target: Some("native"), }
  assert_true(
    prior_reusable_outcome(
      native_prior,
      m,
      current,
      Some("moon x"),
      target=Some("native"),
    )
    is Some((Killed, None, _)),
  )
  // Survived and Timeout never reuse.
  let prior_survived = mk_prior(
    3,
    Some(turtles_version),
    Some("moon x"),
    "hash-a",
    Survived,
    None,
  )
  assert_eq(
    prior_reusable_outcome(prior_survived, m, current, Some("moon x")) is None,
    true,
  )
  let prior_timeout = mk_prior(
    3,
    Some(turtles_version),
    Some("moon x"),
    "hash-a",
    Timeout,
    None,
  )
  assert_eq(
    prior_reusable_outcome(prior_timeout, m, current, Some("moon x")) is None,
    true,
  )
  // Schema 1 and 2 reports never reuse after the schema-3 bump.
  for old_schema in [1, 2] {
    let old = mk_prior(
      old_schema,
      Some(turtles_version),
      Some("moon x"),
      "hash-a",
      Killed,
      None,
    )
    assert_eq(
      prior_reusable_outcome(old, m, current, Some("moon x")) is None,
      true,
    )
  }
  // turtles or moon version drift disables reuse.
  let other_turtles = mk_prior(
    3,
    Some("0.0.0"),
    Some("moon x"),
    "hash-a",
    Killed,
    None,
  )
  assert_eq(
    prior_reusable_outcome(other_turtles, m, current, Some("moon x")) is None,
    true,
  )
  let other_moon = mk_prior(
    3,
    Some(turtles_version),
    Some("moon y"),
    "hash-a",
    Killed,
    None,
  )
  assert_eq(
    prior_reusable_outcome(other_moon, m, current, Some("moon x")) is None,
    true,
  )
}

///|
test "iterate refuses reuse when file content changed" {
  let current : Map[String, String] = Map([])
  current["a.mbt"] = "new-hash"
  let m = mk_mutation("a.mbt", 0, 1, "+", "-")
  let prior = mk_prior(
    3,
    Some(turtles_version),
    Some("moon x"),
    "old-hash",
    Killed,
    None,
  )
  assert_eq(
    prior_reusable_outcome(prior, m, current, Some("moon x")) is None,
    true,
  )
}

///|
test "iterate refuses reuse when an unmutated fingerprint file changed" {
  // The mutated file is byte-identical in both runs; a test file and
  // moon.pkg drift instead — a verdict may owe its outcome to those,
  // so no row may be reused.
  let m = mk_mutation("a.mbt", 0, 1, "+", "-")
  let prior = {
    ..mk_prior(3, Some(turtles_version), Some("moon x"), "hash-a", Killed, None),
    files: {
      "a.mbt": "hash-a",
      "b_test.mbt": "hash-test",
      "moon.pkg": "hash-pkg",
    },
  }
  let changed_test : Map[String, String] = {
    "a.mbt": "hash-a",
    "b_test.mbt": "hash-test-drifted",
    "moon.pkg": "hash-pkg",
  }
  assert_true(
    prior_reusable_outcome(prior, m, changed_test, Some("moon x")) is None,
  )
  let changed_manifest : Map[String, String] = {
    "a.mbt": "hash-a",
    "b_test.mbt": "hash-test",
    "moon.pkg": "hash-pkg-drifted",
  }
  assert_true(
    prior_reusable_outcome(prior, m, changed_manifest, Some("moon x")) is None,
  )
  let added_file : Map[String, String] = {
    "a.mbt": "hash-a",
    "b_test.mbt": "hash-test",
    "moon.pkg": "hash-pkg",
    "new.mbt": "hash-new",
  }
  assert_true(
    prior_reusable_outcome(prior, m, added_file, Some("moon x")) is None,
  )
  // An identical fingerprint set still reuses.
  let unchanged : Map[String, String] = {
    "a.mbt": "hash-a",
    "b_test.mbt": "hash-test",
    "moon.pkg": "hash-pkg",
  }
  assert_true(
    prior_reusable_outcome(prior, m, unchanged, Some("moon x"))
    is Some((Killed, None, _)),
  )
}

///|
test "identity is content-anchored, not line-anchored" {
  // Same span+texts, different recorded line -> same identity.
  let m1 = mk_mutation("a.mbt", 10, 11, "+", "-")
  let m2 = {
    path: "a.mbt",
    start: 10,
    end: 11,
    line: 99,
    column: 99,
    original: "+",
    replacement: "-",
    group: Arithmetic,
    visibility: Private,
  }
  assert_eq(mutation_identity(m1), mutation_identity(m2))
  // Same line, shifted bytes -> different identity.
  let m3 = mk_mutation("a.mbt", 20, 21, "+", "-")
  assert_true(mutation_identity(m1) != mutation_identity(m3))
  // Same span, different replacement -> different identity.
  let m4 = mk_mutation("a.mbt", 10, 11, "+", "*")
  assert_true(mutation_identity(m1) != mutation_identity(m4))
}

///|
async test "iterate round-trips killed_by attribution from a prior report" {
  let temp = @fs.tmpdir(prefix="turtles-iterate")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let kills_json = Json([
      {
        pkg: "probe/p",
        filename: "lib_test.mbt",
        index: 0,
        test_name: "prop idempotent",
        kind: Property,
        counterexample: Some("0"),
      },
    ]).stringify()
    let mutant_json = "{\"path\":\"a.mbt\",\"offset\":0,\"end\":1,\"group\":\"arithmetic\",\"original\":\"+\",\"replacement\":\"-\",\"outcome\":\"KILLED\",\"line\":1,\"column\":1,\"killed_by\":\{kills_json}}"
    let report = "{\"schema\":3,\"turtles_version\":\"\{turtles_version}\",\"moon_version\":\"moon x\",\"files\":{\"a.mbt\":\"hash-a\"},\"mutants\":[\{mutant_json}]}"
    @fs.write_file(path_join(temp, "report.json"), report)
    guard load_prior_report(path_join(temp, "report.json")) is Some(prior) else {
      fail("expected prior report to load")
    }
    let current : Map[String, String] = Map([])
    current["a.mbt"] = "hash-a"
    let m = mk_mutation("a.mbt", 0, 1, "+", "-")
    match prior_reusable_outcome(prior, m, current, Some("moon x")) {
      Some((Killed, Some(kills), _)) => {
        assert_eq(kills.length(), 1)
        inspect(kills[0].pkg, content="probe/p")
        inspect(kills[0].filename, content="lib_test.mbt")
        inspect(kills[0].test_name, content="prop idempotent")
        debug_inspect(kills[0].kind, content="Property")
        debug_inspect(kills[0].counterexample, content="Some(\"0\")")
      }
      _ => fail("expected reused KILLED carrying its killed_by")
    }
    // A prior row without killed_by still degrades to "unavailable".
    let bare_json = "{\"path\":\"a.mbt\",\"offset\":0,\"end\":1,\"group\":\"arithmetic\",\"original\":\"+\",\"replacement\":\"-\",\"outcome\":\"KILLED\",\"line\":1,\"column\":1}"
    let bare_report = "{\"schema\":3,\"turtles_version\":\"\{turtles_version}\",\"moon_version\":\"moon x\",\"files\":{\"a.mbt\":\"hash-a\"},\"mutants\":[\{bare_json}]}"
    @fs.write_file(path_join(temp, "report.json"), bare_report)
    guard load_prior_report(path_join(temp, "report.json")) is Some(bare) else {
      fail("expected prior report to load")
    }
    assert_true(
      prior_reusable_outcome(bare, m, current, Some("moon x"))
      is Some((Killed, None, _)),
    )
  })
}

///|
test "mutation_id is a stable m- prefixed hex digest" {
  let id = mutation_id(mk_mutation("a.mbt", 0, 1, "+", "-"))
  assert_true(id.has_prefix("m-"))
  assert_eq(id.length(), 18)
  assert_eq(id, mutation_id(mk_mutation("a.mbt", 0, 1, "+", "-")))
}

///|
test "iterate never reuses amplification-derived kills" {
  let prior = mk_prior(
    3,
    Some(turtles_version),
    Some("moon x"),
    "hash-a",
    Killed,
    None,
  )
  let m = mk_mutation("a.mbt", 0, 1, "+", "-")
  prior.mutants[mutation_identity(m)] = (m, Killed, None, true)
  assert_true(
    prior_reusable_outcome(prior, m, prior.files, Some("moon x")) is None,
  )
  // Amplification configuration is deliberately not trusted: the same
  // conservative guard holds for a disabled or changed-factor run.
}
