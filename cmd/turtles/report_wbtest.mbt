///|
fn report_test_mutation(path : String) -> Mutation {
  {
    path,
    start: 0,
    end: 1,
    line: 1,
    column: 1,
    group: Comparison,
    original: "a",
    replacement: "b",
    visibility: Public,
  }
}

///|
fn report_test_result(outcome : Outcome) -> MutationResult {
  {
    mutation: report_test_mutation("m.mbt"),
    outcome,
    duration_ms: 1L,
    reused: false,
    packages: None,
    kills: None,
    witness: None,
    witness_skipped: None,
    amplified: None,
  }
}

///|
fn report_result_with(
  replacement : String,
  outcome : Outcome,
) -> MutationResult {
  let mutation = report_test_mutation("m.mbt")
  {
    mutation: {
      path: mutation.path,
      start: mutation.start,
      end: mutation.end,
      line: mutation.line,
      column: mutation.column,
      group: mutation.group,
      original: mutation.original,
      replacement,
      visibility: mutation.visibility,
    },
    outcome,
    duration_ms: 1L,
    reused: false,
    packages: None,
    kills: None,
    witness: None,
    witness_skipped: None,
    amplified: None,
  }
}

///|
fn report_result_with_visibility(
  replacement : String,
  outcome : Outcome,
  visibility : MutantVisibility,
) -> MutationResult {
  let result = report_result_with(replacement, outcome)
  { ..result, mutation: { ..result.mutation, visibility, }, }
}

///|
test "count_outcomes tallies every outcome" {
  let results = [
    report_test_result(Killed),
    report_test_result(Killed),
    report_test_result(Survived),
    report_test_result(Timeout),
    report_test_result(Unviable),
  ]
  let (killed, survived, timeout, unviable) = count_outcomes(results)
  inspect(killed, content="2")
  inspect(survived, content="1")
  inspect(timeout, content="1")
  inspect(unviable, content="1")
  inspect(count_outcomes([]) == (0, 0, 0, 0), content="true")
}

///|
test "mutation_score divides killed over viable" {
  inspect(mutation_score(0, 0, 0), content="100")
  inspect(mutation_score(3, 1, 0), content="75")
  inspect(mutation_score(0, 2, 0), content="0")
  inspect(mutation_score(1, 0, 1), content="50")
}

///|
test "visibility_summary splits outcomes by bucket" {
  let results = [
    report_result_with_visibility("c", Killed, Public),
    report_result_with_visibility("d", Survived, Public),
    report_result_with_visibility("e", Unviable, Public),
    report_result_with_visibility("f", Survived, Private),
    report_result_with_visibility("g", Timeout, Private),
    report_result_with_visibility("h", Killed, Test),
  ]
  let public = visibility_summary(results, Public)
  inspect(public.mutants, content="3")
  inspect(public.killed, content="1")
  inspect(public.survived, content="1")
  inspect(public.unviable, content="1")
  // Unviable is excluded from the score: 1 killed of 2 viable.
  inspect(public.score, content="50")
  let private = visibility_summary(results, Private)
  inspect(private.mutants, content="2")
  inspect(private.killed, content="0")
  inspect(private.score, content="0")
  // Test-block mutants are their own bucket: they never count toward
  // the public or private split.
  let test_bucket = visibility_summary(results, Test)
  inspect(test_bucket.mutants, content="1")
  inspect(test_bucket.killed, content="1")
}

///|
async test "write_json_report emits schema-3 JSON" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let path = path_join(temp, "nested/deep/report.json")
    let results = [report_test_result(Killed), report_test_result(Survived)]
    let report = build_report(
      "module/root",
      Some("moon 0.1.x"),
      1234L,
      100L,
      900L,
      "module",
      results,
      [],
      { "m.mbt": "hash" },
      50.0,
      target=Some("native"),
      inactive=[mk_mutation("idle.mbt", 0, 1, "+", "-")],
    )
    write_json_report(path, report)
    let content = @fs.read_file(path).text()
    assert_true(content.has_suffix("\n"))
    assert_true(content.contains("\"schema\": 3"))
    assert_true(content.contains("\"module\": \"module/root\""))
    assert_true(content.contains("\"turtles_version\""))
    assert_true(content.contains("\"moon_version\": \"moon 0.1.x\""))
    assert_true(content.contains("\"target\": \"native\""))
    assert_true(content.contains("\"inactive_mutants\": 1"))
    assert_true(content.contains("\"idle.mbt\""))
    // Int64 fields serialize as JSON strings (schema-1 did the same for
    // duration_ms — parsers must accept the quoted form).
    assert_true(content.contains("\"baseline_check_ms\": \"100\""))
    assert_true(content.contains("\"baseline_test_ms\": \"900\""))
    // Inactive mutants are excluded from the mutants array entirely.
    assert_true(!content.contains("\"path\": \"idle.mbt\""))
    assert_true(content.contains("\"test_scope\": \"module\""))
    assert_true(content.contains("\"killed\": 1"))
    assert_true(content.contains("\"survived\": 1"))
    assert_true(content.contains("\"reused\": 0"))
    assert_true(content.contains("\"score\": 50"))
    assert_true(content.contains("\"outcome\": \"KILLED\""))
    assert_true(content.contains("\"outcome\": \"SURVIVED\""))
    assert_true(content.contains("\"path\": \"m.mbt\""))
    assert_true(content.contains("\"group\": \"comparison\""))
    assert_true(content.contains("\"original\": \"a\""))
    assert_true(content.contains("\"replacement\": \"b\""))
    assert_true(content.contains("\"id\": \"m-"))
    assert_true(content.contains("\"offset\": 0"))
    assert_true(content.contains("\"visibility\": \"public\""))
    assert_true(content.contains("\"score_public\""))
    assert_true(content.contains("\"score_private\""))
    assert_true(content.contains("\"files\": {"))
    // Rewriting to an existing directory must still succeed.
    write_json_report(path, report)
    assert_true(@fs.read_file(path).text().contains("\"killed\": 1"))
  })
}

///|
test "boundary mutants report their group and stay distinct from comparison" {
  let base = report_test_mutation("m.mbt")
  let comparison = { ..base, original: "<", replacement: ">", }
  let boundary = { ..base, group: Boundary, original: "<", replacement: "<=", }
  let json = Json([
    json_mutation({ ..report_test_result(Killed), mutation: boundary, }),
  ]).stringify()
  // Single-row stringify is compact: fields keep their JSON names and the
  // boundary group name is what --iterate reads back.
  assert_true(json.contains("\"group\":\"boundary\""))
  assert_true(json.contains("\"original\":\"<\""))
  assert_true(json.contains("\"replacement\":\"<=\""))
  assert_true(mutation_id(boundary) != mutation_id(comparison))
}

///|
test "inactive_files are deduplicated and sorted" {
  let inactive = [
    mk_mutation("z.mbt", 0, 1, "+", "-"),
    mk_mutation("a.mbt", 0, 1, "+", "-"),
    mk_mutation("z.mbt", 4, 5, "<", ">"),
  ]
  let report = build_report(
    "m",
    None,
    0L,
    0L,
    0L,
    "module",
    [],
    [],
    Map([]),
    100.0,
    inactive~,
  )
  json_inspect(report.inactive_files, content=["a.mbt", "z.mbt"])
  inspect(report.inactive_mutants, content="3")
}

///|
async test "write_output_dir scopes the self-ignore and diffs timeouts" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let root = path_join(temp, "module")
    @fs.mkdir(root, recursive=true)
    write_file(path_join(root, "m.mbt"), "a")
    let results = [
      report_result_with("c", Timeout),
      report_result_with("d", Survived),
      report_result_with("e", Killed),
    ]
    let report = build_report(
      root,
      None,
      0L,
      0L,
      0L,
      "module",
      results,
      [],
      Map([]),
      50.0,
    )
    // A user-chosen output dir never gets a .gitignore.
    let custom = path_join(temp, "out")
    write_output_dir(custom, root, results, report, false)
    assert_true(!@fs.exists(path_join(custom, ".gitignore")))
    // The default .turtles dir gets it once — an existing user file wins.
    let default = path_join(root, ".turtles")
    write_output_dir(default, root, results, report, true)
    assert_eq(@fs.read_file(path_join(default, ".gitignore")).text(), "*\n")
    write_file(path_join(default, ".gitignore"), "mine\n")
    write_output_dir(default, root, results, report, true)
    assert_eq(@fs.read_file(path_join(default, ".gitignore")).text(), "mine\n")
    // Timeout is an unresolved verdict: it ships a diff artifact too.
    let entries = @fs.readdir(
      path_join(default, "survivors"),
      include_hidden=false,
      sort=false,
    )
    assert_eq(entries.length(), 2)
  })
}
