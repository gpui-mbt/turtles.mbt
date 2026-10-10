///|
/// Byte offset of ASCII `needle` inside `text` — mutation spans are byte
/// offsets, so test mutations are anchored the same way the scanner's are.
fn byte_offset_of(text : String, needle : String) -> Int {
  let bytes = @utf8.encode(text)
  let n = @utf8.encode(needle)
  let mut i = 0
  while i + n.length() <= bytes.length() {
    if bytes[i:i + n.length()] == n {
      return i
    }
    i = i + 1
  }
  -1
}

///|
fn span_mutation(
  path : String,
  start : Int,
  end : Int,
  original : String,
) -> Mutation {
  {
    path,
    start,
    end,
    line: 1,
    column: 1,
    group: Arithmetic,
    original,
    replacement: "-",
    visibility: Public,
  }
}

///|
/// A survived result row carrying `mutation` — analyses only read the
/// mutation, outcome, and packages fields.
fn survived_result(mutation : Mutation) -> MutationResult {
  {
    mutation,
    outcome: Survived,
    duration_ms: 0,
    reused: false,
    packages: Some(["pkg"]),
    kills: None,
    witness: None,
    witness_skipped: None,
    amplified: None,
  }
}

///|
/// Clone a symbol/test table and add `extra` keys.
fn table_with(
  base : Map[String, Bool],
  extra : Array[String],
) -> Map[String, Bool] {
  let out : Map[String, Bool] = Map([])
  for name, marked in base {
    out[name] = marked
  }
  for name in extra {
    out[name] = true
  }
  out
}

///|
/// Module exercising every eligibility branch: pure `dup`, a `Ref`
/// mutator, a self-recursive fn, a mutually recursive pair, a `#cfg`
/// fn, an `encode`/`decode` round-trip pair, and a labelled param.
let index_fixture : String =
  #|let counter : Ref[Int] = { val: 0 }
  #|
  #|pub fn dup(x : Int) -> Int {
  #|  x + x
  #|}
  #|
  #|pub fn tally(x : Int) -> Int {
  #|  counter.val += x
  #|  counter.val
  #|}
  #|
  #|pub fn down(n : Int) -> Int {
  #|  if n <= 0 { 0 } else { down(n - 1) }
  #|}
  #|
  #|pub fn even_to_zero(n : Int) -> Int {
  #|  if n <= 0 { 0 } else { odd_to_zero(n - 1) }
  #|}
  #|
  #|pub fn odd_to_zero(n : Int) -> Int {
  #|  if n <= 0 { 1 } else { even_to_zero(n - 1) }
  #|}
  #|
  #|#cfg(target = "wasm")
  #|pub fn cfgonly(x : Int) -> Int {
  #|  x + 1
  #|}
  #|
  #|pub fn encode_s(x : Int) -> String {
  #|  x.to_string()
  #|}
  #|
  #|pub fn decode_s(s : String) -> Int {
  #|  s.length()
  #|}
  #|
  #|pub fn labelled(x : Int, k~ : Int) -> Int {
  #|  x + k
  #|}
  #|

///|
async fn write_index_module(dir : String) -> Unit {
  @fs.write_file(
    path_join(dir, "moon.mod"),
    "name = \"turtles/index_wbtest\"\nversion = \"0.1.0\"\n",
  )
  @fs.write_file(path_join(dir, "moon.pkg"), "")
  @fs.write_file(path_join(dir, "lib.mbt"), index_fixture)
}

///|
async test "recursive SCCs exclude both self-recursion and mutual recursion" {
  let dir = @fs.tmpdir(prefix="turtles-index")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    write_index_module(dir)
    let index = build_module_index(dir)
    inspect(index.recursive.contains(fn_node(".", "down")), content="true")
    inspect(
      index.recursive.contains(fn_node(".", "even_to_zero")),
      content="true",
    )
    inspect(
      index.recursive.contains(fn_node(".", "odd_to_zero")),
      content="true",
    )
    inspect(index.recursive.contains(fn_node(".", "dup")), content="false")
    inspect(index.recursive.contains(fn_node(".", "tally")), content="false")
  })
}

///|
async test "witness eligibility maps each disqualifier to its skip reason" {
  let dir = @fs.tmpdir(prefix="turtles-index")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    write_index_module(dir)
    let index = build_module_index(dir)
    let pkg = index.pkgs["."]
    inspect(witness_eligible(index, pkg.fns["dup"]) is None, content="true")
    inspect(
      witness_eligible(index, pkg.fns["tally"]) is Some(EffectsUnknown),
      content="true",
    )
    inspect(
      witness_eligible(index, pkg.fns["down"]) is Some(Recursive),
      content="true",
    )
    inspect(
      witness_eligible(index, pkg.fns["even_to_zero"]) is Some(Recursive),
      content="true",
    )
    inspect(
      witness_eligible(index, pkg.fns["cfgonly"]) is Some(Cfg),
      content="true",
    )
  })
}

///|
test "package ownership accepts Windows separators" {
  let pkg_dirs = Map([(".", true), ("pkg", true), ("pkg/nested", true)])
  assert_eq(pkg_dir_of(pkg_dirs, "pkg\\nested\\lib.mbt"), "pkg/nested")
  assert_eq(pkg_dir_of(pkg_dirs, "pkg/nested/lib.mbt"), "pkg/nested")
}

///|
async test "witness helper names embed the mutant id and retry up to 16" {
  let dir = @fs.tmpdir(prefix="turtles-index")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    write_index_module(dir)
    let index = build_module_index(dir)
    let pkg = index.pkgs["."]
    let entry = pkg.fns["dup"]
    let candidates = witness_helper_candidates(entry, "m-00ab")
    inspect(candidates.length(), content="16")
    inspect(candidates[0], content="dup__turtles_orig__mut00ab")
    inspect(candidates[15], content="dup__turtles_orig__mut00ab_15")
    // A package symbol colliding with the base name falls back to _1,
    // including colliding generated test names.
    let collision : PkgIndex = {
      ..pkg,
      symbols: table_with(pkg.symbols, ["dup__turtles_orig__mut00ab"]),
      tests: table_with(pkg.tests, [
        "turtles witness m-00ab dup guard", "turtles witness m-00ab dup",
      ]),
    }
    match choose_witness_names(entry, "m-00ab", collision) {
      Some((helper, _, _)) =>
        inspect(helper, content="dup__turtles_orig__mut00ab_1")
      None => panic()
    }
    // Saturating every candidate yields the name-collision signal.
    let saturated : PkgIndex = {
      ..pkg,
      symbols: table_with(pkg.symbols, candidates),
    }
    inspect(
      choose_witness_names(entry, "m-00ab", saturated) is None,
      content="true",
    )
  })
}

///|
async test "witness appendix clones the original body and emits both tests" {
  let dir = @fs.tmpdir(prefix="turtles-index")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    write_index_module(dir)
    let index = build_module_index(dir)
    let entry = index.pkgs["."].fns["dup"]
    let appendix = witness_appendix(
      entry, index_fixture, "dup__turtles_orig__mut00ab", "turtles witness m-00ab dup guard",
      "turtles witness m-00ab dup",
    )
    assert_true(
      appendix.contains("pub fn dup__turtles_orig__mut00ab(x : Int) -> Int"),
    )
    assert_true(appendix.contains("x + x"))
    assert_true(appendix.contains("test \"turtles witness m-00ab dup guard\""))
    assert_true(appendix.contains("test \"turtles witness m-00ab dup\""))
    assert_true(
      appendix.contains("dup(arg0) == dup__turtles_orig__mut00ab(arg0)"),
    )
    // The guard reruns the ORIGINAL on the same input.
    assert_true(
      appendix.contains(
        "dup__turtles_orig__mut00ab(arg0) == dup__turtles_orig__mut00ab(arg0)",
      ),
    )
  })
}

///|
async test "labelled parameters are forwarded by name in the witness call" {
  let dir = @fs.tmpdir(prefix="turtles-index")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    write_index_module(dir)
    let index = build_module_index(dir)
    let entry = index.pkgs["."].fns["labelled"]
    inspect(witness_call_args(entry), content="arg0, k = arg1")
  })
}

///|
async test "amplify rewrites scale budgets and shift seeds" {
  let dir = @fs.tmpdir(prefix="turtles-index")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    write_index_module(dir)
    @fs.write_file(
      path_join(dir, "moon.pkg"),
      "import { \"moonbitlang/core/quickcheck\", } for \"test\"\n",
    )
    let index = build_module_index(dir)
    let source =
      #|test "p" {
      #|  @quickcheck.check((x : Int) => dup(x) == x)
      #|}
      #|
      #|test "p2" {
      #|  @quickcheck.check((x : Int) => dup(x) == x, count = 10, seed = 7)
      #|}
      #|
      #|test "p3" {
      #|  @quickcheck.check(
      #|    (x : Int) => dup(x) == x,
      #|  )
      #|}
      #|
    let rewritten = amplify_rewrite_file(source, "lib_test.mbt", index, 4)
    match rewritten {
      None => panic()
      Some(text) => {
        // missing args -> count = 400 and the shifted seed appended
        assert_true(
          text.contains(
            "@quickcheck.check((x : Int) => dup(x) == x, count = 400, seed = \{amplify_seed})",
          ),
        )
        // count *= factor, seed += seed-offset
        assert_true(text.contains("(10 * 4)"))
        assert_true(text.contains("(7 + \{amplify_seed})"))
        // a trailing comma must not produce `,,`
        assert_true(!text.contains(",,"))
        assert_true(text.contains("count = 400, seed = \{amplify_seed}"))
      }
    }
  })
}

///|
async test "amplify leaves non-quickcheck check callees untouched" {
  let dir = @fs.tmpdir(prefix="turtles-index")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    write_index_module(dir)
    let index = build_module_index(dir)
    // `check` unqualified with no quickcheck import -> not a QuickCheck call.
    let source =
      #|test "p" {
      #|  check((x : Int) => dup(x) == x)
      #|}
      #|
    inspect(
      amplify_rewrite_file(source, "lib_test.mbt", index, 4) is None,
      content="true",
    )
  })
}

///|
async test "suggestion files pick the property family from the signature" {
  let dir = @fs.tmpdir(prefix="turtles-index")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    write_index_module(dir)
    let index = build_module_index(dir)
    let pkg = index.pkgs["."]
    let mutation = {
      let i = byte_offset_of(index_fixture, "x + x")
      span_mutation("lib.mbt", i, i + 1, "+")
    }
    let result = survived_result(mutation)
    // (A) -> A -> idempotence + involution skeletons
    let body = suggestion_file(
      pkg.fns["dup"],
      pkg,
      result,
      Some("native"),
      Some("turtles/index_wbtest"),
    )
    assert_true(body.has_prefix(property_marker))
    assert_true(body.contains("// target: native"))
    assert_true(body.contains("idempotent"))
    assert_true(body.contains("involution"))
    // encode_i has a decode_i partner -> round-trip suggestion
    let encode_mutation = {
      let i = byte_offset_of(index_fixture, "x.to_string")
      span_mutation("lib.mbt", i, i + 1, "x")
    }
    let roundtrip = suggestion_file(
      pkg.fns["encode_s"],
      pkg,
      survived_result(encode_mutation),
      None,
      Some("turtles/index_wbtest"),
    )
    assert_true(roundtrip.contains("round-trip"))
    assert_true(roundtrip.contains("decode_s"))
    assert_true(roundtrip.contains("// target: none"))
    // labelled-only shapes still get the generic stub
    let labelled_body = suggestion_file(
      pkg.fns["labelled"],
      pkg,
      result,
      None,
      Some("turtles/index_wbtest"),
    )
    assert_true(labelled_body.contains("turtles suggestion"))
  })
}

///|
async test "emit_property_files writes live files and sweeps stale markers" {
  let dir = @fs.tmpdir(prefix="turtles-index")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    write_index_module(dir)
    let index = build_module_index(dir)
    let mutation = {
      let i = byte_offset_of(index_fixture, "x + x")
      span_mutation("lib.mbt", i, i + 1, "+")
    }
    let out = path_join(dir, "out")
    @fs.mkdir(out, recursive=true)
    let listed = emit_property_files(
      out,
      [survived_result(mutation)],
      index,
      Some("turtles/index_wbtest"),
      Some("native"),
    )
    inspect(listed.length(), content="1")
    let mutid = mutation_id(mutation)
    inspect(listed[0], content="properties/\{mutid}.mbt")
    let body = @fs.read_file(path_join(out, "properties/\{mutid}.mbt")).text()
    assert_true(body.has_prefix(property_marker))
    // A stale marked file is swept; an unmarked file survives.
    @fs.write_file(
      path_join(out, "properties/stale.mbt"),
      "\{property_marker}\n// target: native\n",
    )
    @fs.write_file(
      path_join(out, "properties/keep.mbt"),
      "// user notes, no marker\n",
    )
    let listed2 = emit_property_files(
      out,
      [survived_result(mutation)],
      index,
      Some("turtles/index_wbtest"),
      Some("js"),
    )
    assert_eq(listed2, ["properties/\{mutid}.mbt"])
    inspect(@fs.exists(path_join(out, "properties/stale.mbt")), content="false")
    inspect(@fs.exists(path_join(out, "properties/keep.mbt")), content="true")
    // ... and the target line tracks the current run.
    let body2 = @fs.read_file(path_join(out, "properties/\{mutid}.mbt")).text()
    assert_true(body2.contains("// target: js"))
  })
}

///|
async test "ensure_quickcheck_import splices into regular imports only" {
  let dir = @fs.tmpdir(prefix="turtles-qc")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    // scoped test import only -> a regular block is appended
    @fs.write_file(
      path_join(dir, "moon.pkg"),
      "import {\n  \"moonbitlang/core/quickcheck\",\n} for \"test\"\n",
    )
    inspect(ensure_quickcheck_import(dir, "."), content="true")
    let first = @fs.read_file(path_join(dir, "moon.pkg")).text()
    assert_true(first.contains("} for \"test\""))
    let second = first[first.find("} for").unwrap() + 5:].to_owned()
    assert_true(second.contains("\"moonbitlang/core/quickcheck\""))
    // idempotent: already imported -> no second splice
    inspect(ensure_quickcheck_import(dir, "."), content="true")
    let again = @fs.read_file(path_join(dir, "moon.pkg")).text()
    inspect(again == first, content="true")
  })
}

///|
async test "ensure_quickcheck_import handles moon.pkg.json manifests" {
  let dir = @fs.tmpdir(prefix="turtles-qc")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    @fs.write_file(
      path_join(dir, "moon.pkg.json"),
      "{\n  \"import\": [\"moonbitlang/core/string\"]\n}\n",
    )
    inspect(ensure_quickcheck_import(dir, "."), content="true")
    let json = @fs.read_file(path_join(dir, "moon.pkg.json")).text()
    assert_true(json.contains("moonbitlang/core/quickcheck"))
    assert_true(json.contains("moonbitlang/core/string"))
  })
}

///|
test "the three PBT flags parse, and pbt-amplify rejects zero" {
  let config = parse_args([
    "turtles", "--dir", "x", "--emit-properties", "--pbt-witness", "--pbt-amplify",
    "4",
  ])
  inspect(config.emit_properties, content="true")
  inspect(config.pbt_witness, content="true")
  inspect(config.pbt_amplify is Some(4), content="true")
  inspect(
    parse_args(["turtles", "--dir", "x"]).emit_properties ||
    parse_args(["turtles", "--dir", "x"]).pbt_witness ||
    parse_args(["turtles", "--dir", "x"]).pbt_amplify is Some(_),
    content="false",
  )
  let rejected = try {
    ignore(parse_args(["turtles", "--dir", "x", "--pbt-amplify", "0"]))
    false
  } catch {
    _ => true
  }
  inspect(rejected, content="true")
}

///|
test "witness determinism failure takes precedence in either record order" {
  let guard_kill : Kill = {
    pkg: "p",
    filename: "lib.mbt",
    index: 0,
    test_name: "guard",
    kind: Property,
    counterexample: Some("1"),
  }
  let witness : Kill = {
    ..guard_kill,
    test_name: "witness",
    counterexample: Some("2"),
  }
  assert_true(
    witness_verdict_from_kills([guard_kill], "guard", "witness")
    is WitnessNondeterministic,
  )
  assert_true(
    witness_verdict_from_kills([witness], "guard", "witness")
    is WitnessFound("2"),
  )
  assert_true(
    witness_verdict_from_kills([guard_kill, witness], "guard", "witness")
    is WitnessNondeterministic,
  )
  assert_true(
    witness_verdict_from_kills([witness, guard_kill], "guard", "witness")
    is WitnessNondeterministic,
  )
}

///|
async test "witness follows local math imports and trusts resolved core aliases only" {
  let dir = @fs.tmpdir(prefix="turtles-imports")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    write_index_module(dir)
    @fs.mkdir(path_join(dir, "math"))
    @fs.write_file(path_join(dir, "math/moon.pkg"), "")
    @fs.write_file(
      path_join(dir, "math/lib.mbt"),
      "let state : Ref[Int] = Ref(0)\npub fn tick(x : Int) -> Int { state.val = x; x }\n",
    )
    @fs.write_file(
      path_join(dir, "moon.pkg"),
      "import { \"turtles/index_wbtest/math\", \"turtles/index_wbtest/math\" @m, \"moonbitlang/core/math\" @core_math, }\n",
    )
    @fs.write_file(
      path_join(dir, "lib.mbt"),
      "pub fn default_alias(x : Int) -> Int { @math.tick(x) + 0 }\npub fn explicit_alias(x : Int) -> Int { @m.tick(x) + 0 }\npub fn pure_alias(x : Double) -> Double { @core_math.sqrt(x) }\n",
    )
    let index = build_module_index(dir)
    let pkg = index.pkgs["."]
    assert_true(
      witness_eligible(index, pkg.fns["default_alias"]) is Some(EffectsUnknown),
    )
    assert_true(
      witness_eligible(index, pkg.fns["explicit_alias"]) is Some(EffectsUnknown),
    )
    assert_true(!pkg.fns["pure_alias"].effects_unknown)
  })
}

///|
async test "amplify resolves scope and aliases and ignores unrelated and bare calls" {
  let dir = @fs.tmpdir(prefix="turtles-imports")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    write_index_module(dir)
    @fs.write_file(
      path_join(dir, "moon.pkg"),
      "import { \"unrelated/package\" @quickcheck, }\nimport { \"moonbitlang/core/quickcheck\" @qc, } for \"test\"\nimport { \"moonbitlang/core/quickcheck\" @wb, } for \"wbtest\"\n",
    )
    let index = build_module_index(dir)
    let unrelated = "fn check(f : (Int) -> Bool) -> Unit { ignore(f) }\ntest { @quickcheck.check((x : Int) => true); @unrelated.check((x : Int) => true); check((x : Int) => true) }"
    assert_true(
      amplify_rewrite_file(unrelated, "lib_test.mbt", index, 4) is None,
    )
    let test_source = "test { @qc.check((x : Int) => true) }"
    assert_true(
      amplify_rewrite_file(test_source, "lib_test.mbt", index, 4) is Some(_),
    )
    assert_true(
      amplify_rewrite_file(test_source, "lib_wbtest.mbt", index, 4) is None,
    )
    assert_true(amplify_rewrite_file(test_source, "lib.mbt", index, 4) is None)
    let wb_source = "test { @wb.check((x : Int) => true) }"
    assert_true(
      amplify_rewrite_file(wb_source, "lib_wbtest.mbt", index, 4) is Some(_),
    )
  })
}

///|
async test "JSON import identities preserve source test and whitebox scopes" {
  let dir = @fs.tmpdir(prefix="turtles-imports")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    @fs.write_file(
      path_join(dir, "moon.pkg.json"),
      "{\"import\":[{\"path\":\"moonbitlang/core/math\",\"alias\":\"m\"}],\"test-import\":[{\"path\":\"moonbitlang/core/quickcheck\",\"alias\":\"qc\"}],\"wbtest-import\":[\"moonbitlang/core/quickcheck\"]}",
    )
    let source = pkg_import_map(dir, ".", Some("p"), Map([]), "source")
    let test_imports = pkg_import_map(dir, ".", Some("p"), Map([]), "test")
    let wb = pkg_import_map(dir, ".", Some("p"), Map([]), "wbtest")
    assert_eq(source.get("m"), Some("moonbitlang/core/math"))
    assert_true(source.get("qc") is None)
    assert_eq(test_imports.get("qc"), Some("moonbitlang/core/quickcheck"))
    assert_true(wb.get("qc") is None)
    assert_eq(wb.get("quickcheck"), Some("moonbitlang/core/quickcheck"))
  })
}

///|
test "manifest comments and spaced scopes do not grant import identity" {
  let source =
    #|// import { "moonbitlang/core/math", }
    #|import { "unrelated/math", }
    #|// import { "moonbitlang/core/quickcheck" @qc, } for "test"
    #|import { "moonbitlang/core/quickcheck" @qc, "unrelated/other" @other, } for    "test"
  let (_, reports) = @moon_config.parse_moon_pkg(source)
  assert_eq(reports.map(r => r.msg), [])
  assert_eq(pkg_text_import_entries(source, "source"), [
    ("unrelated/math", None),
  ])
  assert_eq(pkg_text_import_entries(source, "test"), [
    ("unrelated/math", None),
    ("moonbitlang/core/quickcheck", Some("qc")),
    ("unrelated/other", Some("other")),
  ])
}

///|
test "malformed duplicate scope imports grant no analysis permissions" {
  let source = "import { \"moonbitlang/core/quickcheck\", } for \"test\"\nimport { \"unrelated/pkg\", } for \"test\"\n"
  assert_true(pkg_text_import_entries(source, "test").is_empty())
}
