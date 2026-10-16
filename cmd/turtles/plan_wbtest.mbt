///|
/// A minimal dry-run fragment in the real moon format: library build,
/// internal test build, and a dependent package whose tests link the lib.
fn sample_plan() -> String {
  [
    "moonc build-package ./uuid/uuid.mbt -o ./_build/wasm/debug/test/uuid/uuid.core -pkg moonbitlang/x/uuid -pkg-type library -pkg-sources moonbitlang/x/uuid:./uuid -target wasm",
    "moonc build-package ./uuid/uuid.mbt ./_build/wasm/debug/test/uuid/__generated_driver_for_internal_test.mbt -o ./_build/wasm/debug/test/uuid/uuid.internal_test.core -pkg moonbitlang/x/uuid -pkg-type executable -i ./_build/wasm/debug/test/uuid/uuid.mi:uuid -pkg-sources moonbitlang/x/uuid:./uuid -test-mode",
    "moonc build-package ./uuid/uuid_test.mbt -o ./_build/wasm/debug/test/uuid/uuid.blackbox_test.core -pkg moonbitlang/x/uuid_blackbox_test -pkg-type executable -i ./_build/wasm/debug/test/uuid/uuid.mi:uuid -pkg-sources moonbitlang/x/uuid_blackbox_test:./uuid -test-mode",
    "moonc build-package ./jwt/jwt.mbt -o ./_build/wasm/debug/test/jwt/jwt.core -pkg moonbitlang/x/jwt -pkg-type library -i ./_build/wasm/debug/test/uuid/uuid.mi:uuid -pkg-sources moonbitlang/x/jwt:./jwt -target wasm",
    "moonc build-package ./jwt/jwt_test.mbt -o ./_build/wasm/debug/test/jwt/jwt.blackbox_test.core -pkg moonbitlang/x/jwt_blackbox_test -pkg-type executable -i ./_build/wasm/debug/test/jwt/jwt.mi:jwt -i ./_build/wasm/debug/test/uuid/uuid.mi:uuid -pkg-sources moonbitlang/x/jwt_blackbox_test:./jwt -test-mode",
    "moonc build-package ./codec/codec.mbt -o ./_build/wasm/debug/test/codec/codec.core -pkg moonbitlang/x/codec -pkg-type library -pkg-sources moonbitlang/x/codec:./codec -target wasm",
  ].join("\n")
}

///|
fn build_sample_plan() -> TestPlan {
  let builder = PlanBuilder::new()
  for line in sample_plan().split("\n") {
    builder.record_line(line.to_owned())
  }
  builder.build().unwrap()
}

///|
test "artifact_pkg_path strips the _build prefix layout" {
  assert_eq(
    artifact_pkg_path("./_build/wasm/debug/test/uuid/uuid.core"),
    Some("uuid"),
  )
  assert_eq(
    artifact_pkg_path("_build/native/release/test/a/b/c/d.mi"),
    Some("a/b/c"),
  )
  assert_eq(artifact_pkg_path("$MOON_HOME/lib/x.mi"), None)
  assert_eq(artifact_pkg_path("./uuid/uuid.mbt"), None)
}

///|
test "plan maps a mutation to its package dir" {
  let plan = build_sample_plan()
  assert_eq(plan.package_dir_of("uuid/uuid.mbt"), Some("uuid"))
  assert_eq(plan.package_dir_of("jwt/sub/x.mbt"), Some("jwt"))
  assert_eq(plan.package_dir_of("elsewhere/x.mbt"), None)
}

///|
test "test_packages_for selects observers transitively and canonical fqns" {
  let plan = build_sample_plan()
  match plan.test_packages_for(mk_mutation("uuid/uuid.mbt", 0, 1, "+", "-")) {
    Some(pkgs) =>
      // uuid's own tests plus jwt's tests (jwt links uuid).
      assert_eq(pkgs, ["moonbitlang/x/jwt", "moonbitlang/x/uuid"])
    None => fail("expected a package selection")
  }
  // codec observes nothing but itself.
  match plan.test_packages_for(mk_mutation("codec/codec.mbt", 0, 1, "+", "-")) {
    Some(pkgs) => assert_eq(pkgs, ["moonbitlang/x/codec"])
    None => fail("expected a package selection")
  }
  // A file outside every package falls back to module-wide.
  assert_eq(
    plan.test_packages_for(mk_mutation("none/x.mbt", 0, 1, "+", "-")),
    None,
  )
}

///|
test "imports resolve regardless of build-package line order" {
  let builder = PlanBuilder::new()
  // m/b imports m/a's artifact before m/a's own -o line appears.
  builder.record_line(
    "moonc build-package ./b/b.mbt -o ./_build/wasm/debug/test/b/b.core -pkg m/b -i ./_build/wasm/debug/test/a/a.mi:a -pkg-sources m/b:./b",
  )
  builder.record_line(
    "moonc build-package ./a/a.mbt -o ./_build/wasm/debug/test/a/a.core -pkg m/a -pkg-sources m/a:./a",
  )
  match builder.build() {
    Some(plan) =>
      match plan.test_packages_for(mk_mutation("a/a.mbt", 0, 1, "+", "-")) {
        Some(pkgs) => assert_eq(pkgs, ["m/a", "m/b"])
        None => fail("expected a package selection")
      }
    None => fail("expected a resolved plan")
  }
}

///|
test "an unresolved module-local import invalidates the plan" {
  let builder = PlanBuilder::new()
  builder.record_line(
    "moonc build-package ./a/a.mbt -o ./_build/wasm/debug/test/a/a.core -pkg m/a -pkg-sources m/a:./a",
  )
  // `ghost` has no recorded owner anywhere in the dry run.
  builder.record_line(
    "moonc build-package ./a/a_test.mbt -o ./_build/wasm/debug/test/a/a.blackbox_test.core -pkg m/a_blackbox_test -i ./_build/wasm/debug/test/ghost/g.mi:g -pkg-sources m/a_blackbox_test:./a -test-mode",
  )
  assert_true(builder.build() is None)
}

///|
test "an unresolved external import does not invalidate the plan" {
  let builder = PlanBuilder::new()
  builder.record_line(
    "moonc build-package ./a/a.mbt -o ./_build/wasm/debug/test/a/a.core -pkg m/a -i '$MOON_HOME/lib/m.mi:m' -pkg-sources m/a:./a",
  )
  assert_true(builder.build() is Some(_))
}

///|
test "split_args strips quotes and squeezes whitespace" {
  assert_eq(
    split_args("moonc build-package -i '$MOON_HOME/lib/m.mi:m'  -pkg x"),
    ["moonc", "build-package", "-i", "$MOON_HOME/lib/m.mi:m", "-pkg", "x"],
  )
}

///|
test "record_line collects only leading positional sources" {
  let builder = PlanBuilder::new()
  builder.record_line(
    "moonc build-package ./a/a.mbt ./a/extra.mbt -o ./_build/native/debug/test/a/a.core -pkg m/a -pkg-sources m/a:./a -doctest-only ./a/doc.mbt",
  )
  // The -doctest-only file is a flag *value* behind a `-` argument,
  // never a positional input.
  json_inspect(builder.raw_sources, content=["./a/a.mbt", "./a/extra.mbt"])
  inspect(builder.build_package_lines, content="1")
}

///|
test "normalize_plan_source resolves relative and absolute in-module paths" {
  let root = "/root/mod"
  assert_eq(normalize_plan_source(root, "./lib/a.mbt"), Some("lib/a.mbt"))
  assert_eq(normalize_plan_source(root, "lib/a.mbt"), Some("lib/a.mbt"))
  assert_eq(normalize_plan_source(root, "a.mbt"), Some("a.mbt"))
  assert_eq(
    normalize_plan_source(root, "/root/mod/lib/a.mbt"),
    Some("lib/a.mbt"),
  )
  assert_eq(
    normalize_plan_source(root, "\\root\\mod\\lib\\a.mbt"),
    Some("lib/a.mbt"),
  )
  assert_eq(normalize_plan_source(root, "/root/mod/a.mbt"), Some("a.mbt"))
  // Generated, vendored, external, and out-of-module sources drop out.
  assert_eq(normalize_plan_source(root, "./_build/native/x.mbt"), None)
  assert_eq(normalize_plan_source(root, ".mooncakes/dep/a.mbt"), None)
  assert_eq(normalize_plan_source(root, "/root/other/a.mbt"), None)
  assert_eq(normalize_plan_source(root, "../outside/a.mbt"), None)
  assert_eq(normalize_plan_source(root, "$MOON_HOME/lib/a.mbt"), None)
  assert_eq(normalize_plan_source(root, "./lib/a.mbti"), None)
}

///|
test "active_sources unions per-backend source sets for --target all" {
  let builder = PlanBuilder::new()
  // A --target all dry run emits one line set per backend; a file
  // compiled under any of them counts as active.
  builder.record_line(
    "moonc build-package ./common.mbt ./native_only.mbt -o ./_build/native/debug/test/m/m.core -pkg m/m -pkg-sources m/m:./ -target native",
  )
  builder.record_line(
    "moonc build-package ./common.mbt ./js_only.mbt -o ./_build/js/debug/test/m/m.core -pkg m/m -pkg-sources m/m:./ -target js",
  )
  let sources = builder.active_sources("/mod")
  let names = sources.keys().collect()
  names.sort()
  json_inspect(names, content=["common.mbt", "js_only.mbt", "native_only.mbt"])
}

///|
test "partition_by_active_source keeps reuse aligned with its mutant" {
  let m1 = mk_mutation("a.mbt", 0, 1, "+", "-")
  let m2 = mk_mutation("idle.mbt", 2, 3, "<", ">")
  let m3 = mk_mutation("b.mbt", 4, 5, "==", "!=")
  let reuse : Array[MutationResult?] = [
    Some({
      mutation: m1,
      outcome: Killed,
      duration_ms: 0L,
      reused: true,
      packages: None,
      kills: None,
      witness: None,
      witness_skipped: None,
      amplified: None,
    }),
    None,
    None,
  ]
  let active : Map[String, Bool] = { "a.mbt": true, "b.mbt": true }
  let (actives, active_reuse, inactive) = partition_by_active_source(
    [m1, m2, m3],
    reuse,
    active,
  )
  json_inspect(actives.map(mutation => mutation.path), content=[
    "a.mbt", "b.mbt",
  ])
  json_inspect(inactive.map(mutation => mutation.path), content=["idle.mbt"])
  inspect(active_reuse.length(), content="2")
  assert_true(active_reuse[0] is Some(_))
  assert_true(active_reuse[1] is None)
}
