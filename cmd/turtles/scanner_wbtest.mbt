///|
fn has_mutation(
  mutations : Array[Mutation],
  original : String,
  replacement : String,
) -> Bool {
  for mutation in mutations {
    if mutation.original == original && mutation.replacement == replacement {
      return true
    }
  }
  false
}

///|
test "line comments do not produce candidates" {
  let source = "// true && a > b\n"
  inspect(
    scan_source("comment.mbt", source, default_project_config()).length(),
    content="0",
  )
}

///|
test "AST discovery finds expression operators and literals" {
  let source =
    #|fn f(a : Int, b : Int) -> Bool {
    #|  // true && a > b
    #|  true && a > b
    #|}
  let mutations = scan_source("sample.mbt", source, default_project_config())
  inspect(mutations.length(), content="3")
  assert_true(has_mutation(mutations, "&&", "||"))
  assert_true(has_mutation(mutations, ">", "<"))
  assert_true(has_mutation(mutations, "true", "false"))
}

///|
test "nested block-comment text inside line comments produces no candidates" {
  let source = "// /* true /* a + b */ false */\nfn f() -> Unit { () }"
  let mutations = scan_source("sample.mbt", source, default_project_config())
  inspect(mutations.length(), content="0")
}

///|
test "strings and character literals do not produce candidates" {
  let string_source = "fn f() -> String { \"true && a > b\" }"
  let char_source = "fn g() -> Char { 'a' }"
  inspect(
    scan_source("string.mbt", string_source, default_project_config()).length(),
    content="0",
  )
  inspect(
    scan_source("char.mbt", char_source, default_project_config()).length(),
    content="0",
  )
}

///|
test "function arrows are not operators but arithmetic is" {
  let source = "fn f(x : Int) -> Int { x - 1 }"
  let mutations = scan_source("sample.mbt", source, default_project_config())
  inspect(mutations.length(), content="1")
  inspect(mutations[0].original, content="-")
  inspect(mutations[0].replacement, content="+")
}

///|
test "nested expressions are all traversed" {
  let source = "fn f(a : Int, b : Int, c : Int, d : Int, e : Int) -> Bool { (a + b > c) && (d == e) }"
  let mutations = scan_source("sample.mbt", source, default_project_config())
  inspect(mutations.length(), content="4")
  assert_true(has_mutation(mutations, "+", "-"))
  assert_true(has_mutation(mutations, ">", "<"))
  assert_true(has_mutation(mutations, "&&", "||"))
  assert_true(has_mutation(mutations, "==", "!="))
}

///|
test "operator aliases preserve the existing mutation table" {
  let source =
    #|fn cmp(a : Int, b : Int) -> Bool {
    #|  a == b && a != b && a >= b && a <= b && a > b && a < b
    #|}
    #|fn logic(a : Bool, b : Bool) -> Bool { a || b }
    #|fn arithmetic(a : Int, b : Int) -> Int { a + b - a * b / 1 }
  let mutations = scan_source("aliases.mbt", source, default_project_config())
  inspect(mutations.length(), content="16")
  assert_true(has_mutation(mutations, "==", "!="))
  assert_true(has_mutation(mutations, "!=", "=="))
  assert_true(has_mutation(mutations, ">=", "<"))
  assert_true(has_mutation(mutations, "<=", ">"))
  assert_true(has_mutation(mutations, ">", "<"))
  assert_true(has_mutation(mutations, "<", ">"))
  assert_true(has_mutation(mutations, "&&", "||"))
  assert_true(has_mutation(mutations, "||", "&&"))
  assert_true(has_mutation(mutations, "+", "-"))
  assert_true(has_mutation(mutations, "-", "+"))
  assert_true(has_mutation(mutations, "*", "/"))
  assert_true(has_mutation(mutations, "/", "*"))
}

///|
test "if conditions are traversed" {
  let source = "fn f(a : Int, b : Int) -> Int { if a > b { a } else { b } }"
  let mutations = scan_source("sample.mbt", source, default_project_config())
  inspect(mutations.length(), content="3")
  assert_true(has_mutation(mutations, "a > b", "true"))
  assert_true(has_mutation(mutations, "a > b", "false"))
  assert_true(has_mutation(mutations, ">", "<"))
}

///|
test "if conditions produce true and false replacements" {
  let source = "fn f(flag : Bool) -> Int { if flag { 1 } else { 2 } }"
  let mutations = scan_source("sample.mbt", source, default_project_config())
  inspect(mutations.length(), content="2")
  assert_true(has_mutation(mutations, "flag", "true"))
  assert_true(has_mutation(mutations, "flag", "false"))
}

///|
test "if condition no-ops are filtered and literal replacements deduplicate" {
  let source =
    #|fn yes() -> Int { if true { 1 } else { 2 } }
    #|fn no() -> Int { if false { 1 } else { 2 } }
  let mutations = scan_source("sample.mbt", source, default_project_config())
  inspect(mutations.length(), content="2")
  assert_true(has_mutation(mutations, "true", "false"))
  assert_true(has_mutation(mutations, "false", "true"))
}

///|
test "comments and strings do not produce if condition candidates" {
  let source =
    #|// if true { 1 } else { 2 }
    #|fn text() -> String { "if false { 1 } else { 2 }" }
    #|fn real(flag : Bool) -> Int { if flag { 1 } else { 2 } }
  let mutations = scan_source("sample.mbt", source, default_project_config())
  inspect(mutations.length(), content="2")
  assert_true(has_mutation(mutations, "flag", "true"))
  assert_true(has_mutation(mutations, "flag", "false"))
}

///|
test "nested if expressions are traversed" {
  let source =
    #|fn f(outer : Bool, inner : Bool) -> Int {
    #|  if outer {
    #|    if inner { 1 } else { 2 }
    #|  } else {
    #|    3
    #|  }
    #|}
  let mutations = scan_source("sample.mbt", source, default_project_config())
  inspect(mutations.length(), content="4")
  assert_true(has_mutation(mutations, "outer", "true"))
  assert_true(has_mutation(mutations, "outer", "false"))
  assert_true(has_mutation(mutations, "inner", "true"))
  assert_true(has_mutation(mutations, "inner", "false"))
}

///|
test "Unicode before if condition uses UTF-8 byte ranges" {
  let source =
    #|// 前置 😀
    #|fn f(条件 : Bool) -> Int {
    #|  if 条件 { 1 } else { 2 }
    #|}
  let mutations = scan_source("unicode.mbt", source, default_project_config())
  inspect(mutations.length(), content="2")
  let mutation = mutations[0]
  let expected_start = @utf8.encode(
    "// 前置 😀\nfn f(条件 : Bool) -> Int {\n  if ",
  ).length()
  let expected_end = expected_start + @utf8.encode("条件").length()
  inspect(mutation.start, content="49")
  inspect(mutation.end, content="55")
  assert_eq(mutation.start, expected_start)
  assert_eq(mutation.end, expected_end)
  inspect(mutation.line, content="3")
  inspect(mutation.column, content="6")
  inspect(mutation.original, content="条件")
  inspect(mutation.replacement, content="true")
  inspect(
    apply_mutation(source, mutation),
    content=(
      #|// 前置 😀
      #|fn f(条件 : Bool) -> Int {
      #|  if true { 1 } else { 2 }
      #|}
    ),
  )
}

///|
test "return expressions are traversed" {
  let source = "fn f(a : Int, b : Int) -> Bool { return a == b }"
  let mutations = scan_source("sample.mbt", source, default_project_config())
  inspect(mutations.length(), content="1")
  inspect(mutations[0].original, content="==")
}

///|
test "nested function-body blocks are traversed" {
  let source =
    #|fn f(a : Int, b : Int) -> Int {
    #|  if a > b {
    #|    a + b
    #|  } else {
    #|    a - b
    #|  }
    #|}
  let mutations = scan_source("sample.mbt", source, default_project_config())
  inspect(mutations.length(), content="5")
  assert_true(has_mutation(mutations, "a > b", "true"))
  assert_true(has_mutation(mutations, "a > b", "false"))
  assert_true(has_mutation(mutations, ">", "<"))
  assert_true(has_mutation(mutations, "+", "-"))
  assert_true(has_mutation(mutations, "-", "+"))
}

///|
test "Unicode source ranges use parser positions and apply by UTF-8 bytes" {
  let source =
    #|// 日本語 true && a > b
    #|fn f(値 : Int) -> Int {
    #|  let text = "😀 true && a > b"
    #|  値 + 1
    #|}
  let mutations = scan_source("unicode.mbt", source, default_project_config())
  inspect(mutations.length(), content="1")
  let mutation = mutations[0]
  inspect(mutation.start, content="92")
  inspect(mutation.end, content="93")
  inspect(mutation.line, content="4")
  inspect(mutation.column, content="5")
  inspect(mutation.original, content="+")
  inspect(
    apply_mutation(source, mutation),
    content=(
      #|// 日本語 true && a > b
      #|fn f(値 : Int) -> Int {
      #|  let text = "😀 true && a > b"
      #|  値 - 1
      #|}
    ),
  )
}

///|
test "unary negation produces the arithmetic mutation" {
  let source = "fn negate(x : Int) -> Int { -x }"
  let mutations = scan_source("sample.mbt", source, default_project_config())
  inspect(mutations.length(), content="1")
  let mutation = mutations[0]
  inspect(mutation.group == Arithmetic, content="true")
  inspect(mutation.original, content="-")
  inspect(mutation.replacement, content="+")
  inspect(
    apply_mutation(source, mutation),
    content="fn negate(x : Int) -> Int { +x }",
  )
}

///|
test "nested unary expressions are traversed" {
  let source = "fn f(x : Int) -> Int { -(-x + 1) }"
  let mutations = scan_source("sample.mbt", source, default_project_config())
  inspect(mutations.length(), content="3")
  let minuses = mutations.filter(m => m.original == "-")
  inspect(minuses.length(), content="2")
  assert_true(has_mutation(mutations, "+", "-"))
}

///|
test "unsupported unary operators produce no candidates" {
  let source = "fn f(flag : Bool) -> Bool { !flag }"
  let mutations = scan_source("sample.mbt", source, default_project_config())
  inspect(mutations.length(), content="0")
}

///|
test "arithmetic group filtering controls unary mutations" {
  let source = "fn negate(x : Int) -> Int { -x }"
  let config = parse_project_config("operators = [\"comparison\"]")
  inspect(scan_source("sample.mbt", source, config).length(), content="0")
}

///|
test "logical and condition groups select independently" {
  let source = "fn f(a : Bool, b : Bool) -> Int { if a && b { 1 } else { 0 } }"
  let boolean = parse_project_config("operators = [\"boolean\"]")
  let boolean_mutations = scan_source("sample.mbt", source, boolean)
  inspect(boolean_mutations.length(), content="1")
  inspect(boolean_mutations[0].original, content="&&")
  let condition = parse_project_config("operators = [\"condition\"]")
  let condition_mutations = scan_source("sample.mbt", source, condition)
  inspect(condition_mutations.length(), content="2")
  assert_true(has_mutation(condition_mutations, "a && b", "true"))
  assert_true(has_mutation(condition_mutations, "a && b", "false"))
}

///|
test "mutation identity is explicitly deduplicated" {
  let source = "a + b"
  let bytes = @utf8.encode(source)
  let visitor = AstCandidateVisitor::{
    path: "sample.mbt",
    bytes,
    boundaries: source_byte_boundaries(bytes),
    specs: operator_specs(),
    project_config: default_project_config(),
    skipped_starts: Map([]),
    skipped_blocks: None,
    trait_methods: Map([]),
    current_visibility: Private,
    mutations: [],
  }
  // Look the spec up by content so appending to the table cannot silently
  // change which operator this test records twice.
  let mut plus : OpSpec? = None
  for spec in operator_specs() {
    if spec.original == "+" && spec.replacement == "-" {
      plus = Some(spec)
    }
  }
  let plus = plus.unwrap()
  visitor.record(plus, 2, 3, 1, 3)
  visitor.record(plus, 2, 3, 1, 3)
  inspect(visitor.mutations.length(), content="1")
}

///|
test "parser failure does not fall back to lexical scanning" {
  try scan_source("broken.mbt", "fn broken(", default_project_config()) catch {
    _ => ()
  } noraise {
    _ => fail("parser failure unexpectedly produced mutation candidates")
  }
}

///|
test "utf8 boundaries cover every width" {
  let bytes = @utf8.encode("aé日😀b")
  inspect(utf8_width(bytes[0]), content="1")
  inspect(utf8_width(bytes[1]), content="2")
  inspect(utf8_width(bytes[3]), content="3")
  inspect(utf8_width(bytes[6]), content="4")
  json_inspect(source_byte_boundaries(bytes), content=[0, 1, 3, 6, 10, 11])
  inspect(source_byte_offset(source_byte_boundaries(bytes), 3), content="6")
}

///|
test "mutation identity compares every field" {
  let base : Mutation = {
    path: "a.mbt",
    start: 1,
    end: 2,
    line: 3,
    column: 4,
    group: Comparison,
    original: "x",
    replacement: "y",
    visibility: Private,
  }
  assert_true(same_mutation_identity(base, base))
  for
    changed in [
      { ..base, path: "b.mbt", },
      { ..base, start: 0, },
      { ..base, end: 5, },
      { ..base, replacement: "z", },
    ] {
    assert_false(same_mutation_identity(base, changed))
  }
  assert_true(
    same_mutation_identity(base, {
      ..base,
      line: 9,
      column: 9,
      group: Literal,
      original: "q",
    }),
  )
}

///|
test "operator filtering applies to scanned candidates" {
  let source = "fn f(a : Int, b : Int) -> Bool { a == b || a > b }"
  let boolean_only = parse_project_config("operators = [\"boolean\"]")
  let mutations = scan_source("s.mbt", source, boolean_only)
  inspect(mutations.length(), content="1")
  inspect(mutations[0].original, content="||")
  let comparison_only = parse_project_config("operators = [\"comparison\"]")
  let comparisons = scan_source("s.mbt", source, comparison_only)
  inspect(comparisons.length(), content="2")
}

///|
test "apply_mutation validates offsets and source text" {
  let source = "fn f() -> Int { 1 }"
  let base : Mutation = {
    path: "f.mbt",
    start: 16,
    end: 17,
    line: 1,
    column: 17,
    group: Arithmetic,
    original: "1",
    replacement: "2",
    visibility: Private,
  }
  inspect(apply_mutation(source, base), content="fn f() -> Int { 2 }")
  for
    bad in [
      { ..base, start: -1, },
      { ..base, start: 17, end: 16, },
      { ..base, end: 1000, },
      { ..base, original: "9", },
    ] {
    let mut raised = false
    try ignore(apply_mutation(source, bad)) catch {
      _ => raised = true
    } noraise {
      _ => ()
    }
    assert_true(raised)
  }
}

///|
test "describe_mutation renders path, position, and replacement" {
  let mutation : Mutation = {
    path: "a/b.mbt",
    start: 0,
    end: 1,
    line: 3,
    column: 7,
    group: Comparison,
    original: "+",
    replacement: "-",
    visibility: Private,
  }
  inspect(describe_mutation(mutation), content="a/b.mbt:3:7: + -> -")
}

///|
test "existing fixture candidate parity" {
  let source =
    #|pub fn add(a : Int, b : Int) -> Int {
    #|  a + b
    #|}
    #|pub fn greater(a : Int, b : Int) -> Bool {
    #|  a > b
    #|}
    #|pub fn both(a : Bool, b : Bool) -> Bool {
    #|  a && b
    #|}
    #|pub fn enabled() -> Bool {
    #|  true
    #|}
    #|pub fn choose(flag : Bool) -> Int {
    #|  if flag { 1 } else { 2 }
    #|}
  let mutations = scan_source(
    "fixtures/basic/math.mbt",
    source,
    default_project_config(),
  )
  inspect(mutations.length(), content="6")
  assert_true(has_mutation(mutations, "+", "-"))
  assert_true(has_mutation(mutations, ">", "<"))
  assert_true(has_mutation(mutations, "&&", "||"))
  assert_true(has_mutation(mutations, "true", "false"))
  assert_true(has_mutation(mutations, "flag", "true"))
  assert_true(has_mutation(mutations, "flag", "false"))
}

///|
fn body_config() -> ProjectConfig raise {
  parse_project_config("operators = [\"body\"]")
}

///|
test "body group is opt-in: default config produces no body mutants" {
  let source = "fn total(a : Int, b : Int) -> Int { a + b }"
  let mutations = scan_source("sample.mbt", source, default_project_config())
  // The `+` arithmetic mutant remains; no whole-body replacement appears.
  inspect(mutations.length(), content="1")
  inspect(mutations[0].group == Body, content="false")
}

///|
test "body group replaces the whole body with typed literals" {
  let source = "fn total(a : Int, b : Int) -> Int { a + b }"
  let mutations = scan_source("sample.mbt", source, body_config())
  inspect(mutations.length(), content="3")
  assert_true(has_mutation(mutations, "a + b", "0"))
  assert_true(has_mutation(mutations, "a + b", "1"))
  assert_true(has_mutation(mutations, "a + b", "-1"))
  for mutation in mutations {
    inspect(mutation.group == Body, content="true")
  }
}

///|
test "body replacements follow the declared return type" {
  let source =
    #|fn a() -> Bool { x() }
    #|fn b() -> String { x() }
    #|fn c() -> Int? { x() }
    #|fn d() -> Array[Int] { x() }
    #|fn e() -> Map[String, Int] { x() }
    #|fn f() -> Double { x() }
    #|fn g() { x() }
  let mutations = scan_source("sample.mbt", source, body_config())
  assert_true(has_mutation(mutations, "x()", "true"))
  assert_true(has_mutation(mutations, "x()", "false"))
  assert_true(has_mutation(mutations, "x()", "\"\""))
  assert_true(has_mutation(mutations, "x()", "\"xyzzy\""))
  assert_true(has_mutation(mutations, "x()", "None"))
  assert_true(has_mutation(mutations, "x()", "[]"))
  assert_true(has_mutation(mutations, "x()", "{}"))
  assert_true(has_mutation(mutations, "x()", "0.0"))
  assert_true(has_mutation(mutations, "x()", "()"))
  inspect(mutations.length(), content="10")
}

///|
test "body group skips unsupported return types" {
  let source =
    #|struct Point { x : Int }
    #|fn p() -> Point { mk() }
    #|fn r() -> Result[Int, String] { mk() }
    #|fn t() -> (Int, Int) { mk() }
  let mutations = scan_source("sample.mbt", source, body_config())
  inspect(mutations.length(), content="0")
}

///|
test "body group skips trivial, async, and stub declarations" {
  let source =
    #|fn a() -> Int { 0 }
    #|fn b() -> Int? { None }
    #|async fn c() -> Int { x() }
    #|extern "C" fn d() -> Int = "d"
  let mutations = scan_source("sample.mbt", source, body_config())
  inspect(mutations.length(), content="0")
}

///|
test "test blocks never get body mutants" {
  let source =
    #|test "sum" {
    #|  inspect(1 + 1, content="2")
    #|}
  let mutations = scan_source("sample.mbt", source, body_config())
  inspect(mutations.length(), content="0")
}

///|
test "turtles.skip attribute excludes the whole block" {
  let source =
    #|#turtles.skip
    #|pub fn helper(a : Int) -> Int {
    #|  a + 1
    #|}
    #|pub fn live(a : Int) -> Int {
    #|  a + 2
    #|}
  let skipped : Array[SkippedBlock] = []
  let mutations = scan_source(
    "sample.mbt",
    source,
    default_project_config(),
    skipped_blocks=skipped,
  )
  inspect(mutations.length(), content="1")
  assert_true(has_mutation(mutations, "+", "-"))
  inspect(skipped.length(), content="1")
  // The reported line is the block's first line — the attribute itself.
  inspect(skipped[0].line, content="1")
}

///|
test "turtles: skip line comment excludes the following block" {
  let source =
    #|pub fn live(a : Int) -> Int {
    #|  a + 1
    #|}
    #|// turtles: skip
    #|pub fn helper(a : Int) -> Int {
    #|  a + 2
    #|}
  let skipped : Array[SkippedBlock] = []
  let mutations = scan_source(
    "sample.mbt",
    source,
    default_project_config(),
    skipped_blocks=skipped,
  )
  inspect(mutations.length(), content="1")
  inspect(skipped.length(), content="1")
  inspect(skipped[0].line, content="5")
}

///|
test "loose comments are not skip markers" {
  let source =
    #|// turtles: skip this later
    #|// turtles:skip
    #|pub fn f(a : Int) -> Int {
    #|  a + 1
    #|}
  let skipped : Array[SkippedBlock] = []
  let mutations = scan_source(
    "sample.mbt",
    source,
    default_project_config(),
    skipped_blocks=skipped,
  )
  inspect(mutations.length(), content="1")
  inspect(skipped.length(), content="0")
}

///|
test "body mutants carry a distinct group for fingerprints" {
  inspect(operator_group_name(Body), content="body")
  inspect(operator_group_from_string("body") == Body, content="true")
}

///|
fn operators_config(groups : Array[String]) -> ProjectConfig raise {
  let entries = StringBuilder()
  for i = 0; i < groups.length(); i = i + 1 {
    if i > 0 {
      entries.write_string(",")
    }
    entries.write_string("\"")
    entries.write_string(groups[i])
    entries.write_string("\"")
  }
  parse_project_config("operators = [\{entries}]")
}

///|
/// Four comparisons, one per boundary form, one per function so the edit
/// location is unambiguous.
fn boundary_source() -> String {
  (
    #|fn below(x : Int) -> Bool { x < 10 }
    #|fn at_most(x : Int) -> Bool { x <= 10 }
    #|fn above(x : Int) -> Bool { x > 10 }
    #|fn at_least(x : Int) -> Bool { x >= 10 }
  )
}

///|
test "boundary group produces exactly the four equality-only mutations" {
  let mutations = scan_source(
    "b.mbt",
    boundary_source(),
    operators_config(["boundary"]),
  )
  inspect(mutations.length(), content="4")
  for mutation in mutations {
    inspect(mutation.group == Boundary, content="true")
  }
  // One function per operator, so the boundary mutant of `<=` (`<=` -> `<`)
  // is the only candidate in the second function.
  let expected = [("<", "<="), ("<=", "<"), (">", ">="), (">=", ">")]
  for i = 0; i < expected.length(); i = i + 1 {
    let (original, replacement) = expected[i]
    inspect(has_mutation(mutations, original, replacement), content="true")
    // The edit replaces the complete operator text and nothing else, so
    // the byte span always equals the operator's own length.
    let mutation = mutations[i]
    inspect(mutation.original, content=original)
    inspect(mutation.replacement, content=replacement)
    inspect(
      mutation.end - mutation.start,
      content="\{mutation.original.length()}",
    )
  }
}

///|
test "the default configuration produces no boundary mutations" {
  let mutations = scan_source(
    "b.mbt",
    boundary_source(),
    default_project_config(),
  )
  inspect(mutations.length(), content="4")
  for mutation in mutations {
    inspect(mutation.group == Comparison, content="true")
  }
  let default_only = scan_source(
    "b.mbt",
    boundary_source(),
    operators_config(["comparison"]),
  )
  inspect(default_only.length(), content="4")
  assert_true(default_only.iter().all(m => m.group == Comparison))
}

///|
test "comparison and boundary share a position in table order with distinct ids" {
  let config = operators_config(["comparison", "boundary"])
  let mutations = scan_source("b.mbt", boundary_source(), config)
  inspect(mutations.length(), content="8")
  // Discovery is per function in source order; within one position the
  // comparison mutant is recorded before the boundary mutant.
  let expected = [
    ("<", ">", Comparison),
    ("<", "<=", Boundary),
    ("<=", ">", Comparison),
    ("<=", "<", Boundary),
    (">", "<", Comparison),
    (">", ">=", Boundary),
    (">=", "<", Comparison),
    (">=", ">", Boundary),
  ]
  for i = 0; i < expected.length(); i = i + 1 {
    let (original, replacement, group) = expected[i]
    inspect(mutations[i].original, content=original)
    inspect(mutations[i].replacement, content=replacement)
    inspect(mutations[i].group == group, content="true")
  }
  // Group order on the command line never changes the generation order.
  let reversed = scan_source(
    "b.mbt",
    boundary_source(),
    operators_config(["boundary", "comparison"]),
  )
  inspect(reversed.length(), content="8")
  for i = 0; i < mutations.length(); i = i + 1 {
    inspect(mutation_id(reversed[i]), content=mutation_id(mutations[i]))
  }
  inspect(
    mutation_id(mutations[0]) != mutation_id(mutations[1]),
    content="true",
  )
}

///|
test "boundary mutants edit the exact byte span in UTF-8 CRLF source" {
  let source =
    #|// 境界値の比較: 10 以下と 10 以上
    #|fn at_most(x : Int) -> Bool { x < 10 }
    #|
  let source = source.replace_all(old="\n", new="\r\n")
  let config = operators_config(["boundary"])
  let mutations = scan_source("b.mbt", source, config)
  inspect(mutations.length(), content="1")
  let bytes = @utf8.encode(source)
  for mutation in mutations {
    inspect(
      @utf8.decode(bytes[mutation.start:mutation.end]),
      content=mutation.original,
    )
  }
  let mut relaxed : Mutation? = None
  for mutation in mutations {
    if mutation.replacement == "<=" {
      relaxed = Some(mutation)
    }
  }
  let mutation = relaxed.unwrap()
  // The operator widens by one byte; the non-ASCII comment line above it
  // survives byte-for-byte.
  let applied = apply_mutation(source, mutation)
  inspect(applied.contains("x <= 10 }\r\n"), content="true")
  inspect(
    applied.contains("// 境界値の比較: 10 以下と 10 以上\r\n"),
    content="true",
  )
  inspect(applied.length(), content="\{source.length() + 1}")
}

///|
test "skipped blocks and disabled boundary stay free of boundary mutants" {
  let source =
    #|#turtles.skip
    #|fn skipped(x : Int) -> Bool { x < 10 }
    #|fn active(x : Int) -> Bool { x < 10 }
  let mutations = scan_source("b.mbt", source, operators_config(["boundary"]))
  inspect(mutations.length(), content="1")
  inspect(mutations[0].line, content="3")
  inspect(mutations[0].replacement, content="<=")
}

///|
test "mutants are tagged with the enclosing declaration's visibility" {
  let source =
    #|pub fn pub_fn(a : Int) -> Int { a + 1 }
    #|fn default_fn(a : Int) -> Int { a + 1 }
    #|priv fn priv_fn(a : Int) -> Int { a + 1 }
    #|trait S { m(Self) -> Int }
    #|pub impl S for Int with m(self) { self + 1 }
    #|trait T { n(Self) -> Int }
    #|impl T for Int with n(self) { self + 1 }
    #|test "inside" { ignore(1 + 1) }
    #|let top_let = 1 + 1
    #|pub let pub_let = 2 + 3
  let mutations = scan_source("v.mbt", source, default_project_config())
  inspect(mutations.length(), content="8")
  for mutation in mutations {
    match mutation.line {
      // pub fn, pub impl, and pub let are public; impl methods use the
      // impl's own visibility marker.
      1 | 5 | 10 => debug_inspect(mutation.visibility, content="Public")
      // test blocks carry no visibility: they are their own bucket.
      8 => debug_inspect(mutation.visibility, content="Test")
      // `fn`, `priv fn`, plain `impl`, and `let` are all private.
      _ => debug_inspect(mutation.visibility, content="Private")
    }
  }
}

///|
test "mutants inside skipped blocks keep no stale visibility" {
  let source =
    #|pub fn public_fn(a : Int) -> Int { a + 1 }
    #|#turtles.skip
    #|fn skipped_fn(a : Int) -> Int { a + 1 }
    #|fn private_fn(a : Int) -> Int { a + 1 }
  let mutations = scan_source("v.mbt", source, default_project_config())
  inspect(mutations.length(), content="2")
  debug_inspect(mutations[0].visibility, content="Public")
  debug_inspect(mutations[1].visibility, content="Private")
}

///|
test "impl method bodies use the trait's declared return type" {
  let source =
    #|trait Sized {
    #|  size(Self) -> Int
    #|}
    #|impl Sized for Point with size(self) {
    #|  self.x
    #|}
  let mutations = scan_source("sample.mbt", source, body_config())
  inspect(mutations.length(), content="3")
  assert_true(has_mutation(mutations, "self.x", "0"))
  assert_true(has_mutation(mutations, "self.x", "1"))
  assert_true(has_mutation(mutations, "self.x", "-1"))
}
