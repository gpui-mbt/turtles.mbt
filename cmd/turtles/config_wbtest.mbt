///|
test "parses turtles config" {
  let config = parse_project_config(
    (
      #|# paths
      #|include = [
      #|  "src/",
      #|  "lib/",
      #|]
      #|exclude = ["generated/", "vendor/"]
      #|operators = ["comparison", "literal"]
      #|
    ),
  )
  json_inspect(config.include_patterns, content=["src/", "lib/"])
  json_inspect(config.exclude_patterns, content=["generated/", "vendor/"])
  inspect(config.path_enabled("src/math.mbt"), content="true")
  inspect(config.path_enabled("src/generated/math.mbt"), content="false")
  inspect(config.operator_enabled(Comparison), content="true")
  inspect(config.operator_enabled(Arithmetic), content="false")
}

///|
test "operator aliases parse" {
  inspect(
    operator_group_from_string("comparisons") == Comparison,
    content="true",
  )
  inspect(
    operator_group_from_string("boolean-logic") == Boolean,
    content="true",
  )
  inspect(
    operator_group_from_string("boolean-literals") == Literal,
    content="true",
  )
  inspect(operator_group_from_string("condition") == Condition, content="true")
}

///|
test "boolean-logic does not enable structural condition mutations" {
  let config = parse_project_config("operators = [\"boolean-logic\"]")
  inspect(config.operator_enabled(Boolean), content="true")
  inspect(config.operator_enabled(Condition), content="false")
  let condition_config = parse_project_config("operators = [\"conditions\"]")
  inspect(condition_config.operator_enabled(Condition), content="true")
  inspect(condition_config.operator_enabled(Boolean), content="false")
}

///|
fn config_error_message(source : String) -> String {
  let mut message = ""
  try ignore(parse_project_config(source)) catch {
    error => message = "\{error}"
  } noraise {
    _ => ()
  }
  message
}

///|
fn config_fails(source : String) -> Bool {
  config_error_message(source) != ""
}

///|
test "empty and comment-only configs keep defaults" {
  for source in ["", "   \n\t\r\n", "# only a comment\n# another\n"] {
    let config = parse_project_config(source)
    inspect(config.include_patterns.is_empty(), content="true")
    inspect(config.exclude_patterns.is_empty(), content="true")
    inspect(config.operator_enabled(Comparison), content="true")
    inspect(config.operator_enabled(Condition), content="true")
    inspect(config.path_enabled("any/file.mbt"), content="true")
  }
}

///|
test "include and exclude patterns gate paths" {
  let config = parse_project_config(
    "include = [\"src/\", \"lib/\"]\nexclude = [\"gen/\"]",
  )
  inspect(config.path_enabled("src/a.mbt"), content="true")
  inspect(config.path_enabled("lib/b.mbt"), content="true")
  inspect(config.path_enabled("test/c.mbt"), content="false")
  inspect(config.path_enabled("src/gen/d.mbt"), content="false")
  inspect(config.path_enabled("gen/e.mbt"), content="false")
  let windows = parse_project_config("include = [\"src/\"]")
  inspect(windows.path_enabled("src\\dir\\a.mbt"), content="true")
  let exclude_only = parse_project_config("exclude = [\"gen/\"]")
  inspect(exclude_only.path_enabled("src/a.mbt"), content="true")
  inspect(exclude_only.path_enabled("gen/a.mbt"), content="false")
}

///|
test "an empty operators list disables every group" {
  let config = parse_project_config("operators = []")
  inspect(config.operator_enabled(Comparison), content="false")
  inspect(config.operator_enabled(Literal), content="false")
}

///|
test "config parse errors carry line and column" {
  assert_true(config_error_message("include = [\"a\"\n").contains("at 2:1"))
  assert_true(config_error_message("# c\nexclude x").contains("at 2:9"))
  assert_true(
    config_error_message("include = [\"a\", \"b\"\nx").contains("at 2:1"),
  )
}

///|
test "malformed configs are rejected" {
  assert_true(config_fails("bogus = [\"x\"]"))
  assert_true(config_fails("include = [\"a\"]\ninclude = [\"b\"]"))
  assert_true(config_fails("exclude = [\"a\"]\nexclude = [\"b\"]"))
  assert_true(config_fails("operators = [\"a\"]\noperators = [\"b\"]"))
  assert_true(config_fails("operators = [\"vibes\"]"))
  assert_true(config_fails("include [\"a\"]"))
  assert_true(config_fails("include = \"a\""))
  assert_true(config_fails("include = [\"a\""))
  assert_true(config_fails("include = [\"a\" \"b\"]"))
  assert_true(config_fails("include = [\"a]"))
  assert_true(config_fails("include = [\"a\n\"]"))
  assert_true(config_fails("include = [\"a\\q\"]"))
  assert_true(config_fails("include = [\"a\\"))
  assert_true(config_fails("= [\"a\"]"))
  assert_true(config_fails("key with space = [\"a\"]"))
  assert_true(config_fails("include = [\"a\"] trailing"))
}

///|
test "string escapes are decoded" {
  let config = parse_project_config(
    "include = [\"a\\nb\", \"c\\td\", \"e\\\\f\", \"g\\\"h\", \"i\\rj\"]",
  )
  json_inspect(config.include_patterns, content=[
    "a\nb", "c\td", "e\\f", "g\"h", "i\rj",
  ])
}

///|
test "trailing commas and dense arrays parse" {
  let config = parse_project_config("include=[\"a\",\"b\",]")
  json_inspect(config.include_patterns, content=["a", "b"])
}

///|
fn parse_args_error(args : Array[String]) -> String {
  let mut message = ""
  try ignore(parse_args(args)) catch {
    error => message = "\{error}"
  } noraise {
    _ => ()
  }
  message
}

///|
fn parse_args_fails(args : Array[String]) -> Bool {
  parse_args_error(args) != ""
}

///|
test "parse_args defaults" {
  let config = parse_args(["turtles"])
  inspect(config.dir, content=".")
  inspect(config.target is None, content="true")
  inspect(config.timeout_ms, content="60000")
  inspect(config.jobs, content="1")
  inspect(config.fail_under is None, content="true")
  inspect(config.list, content="false")
  inspect(config.file_filter.unwrap_or("none"), content="none")
  inspect(config.json_report.unwrap_or("none"), content="none")
}

///|
test "parse_args reads every option" {
  let config = parse_args([
    "turtles", "--dir", "mod", "--timeout", "5", "--file", "src", "--json", "out.json",
    "--list",
  ])
  inspect(config.dir, content="mod")
  inspect(config.timeout_ms, content="5000")
  inspect(config.list, content="true")
  inspect(config.file_filter.unwrap_or("none"), content="src")
  inspect(config.json_report.unwrap_or("none"), content="out.json")
  let short = parse_args(["turtles", "-d", "other"])
  inspect(short.dir, content="other")
}

///|
test "parse_args reads iterate, affected, output-dir, timeout-multiplier" {
  let config = parse_args([
    "turtles", "--iterate", "--affected", "--output-dir", "out", "--timeout-multiplier",
    "3",
  ])
  inspect(config.iterate, content="true")
  inspect(config.affected, content="true")
  inspect(config.output_dir.unwrap_or("none"), content="out")
  inspect(config.timeout_multiplier.unwrap_or(-1.0), content="3")
  inspect(parse_args(["turtles"]).iterate, content="false")
  inspect(parse_args(["turtles"]).affected, content="false")
  inspect(parse_args(["turtles"]).output_dir is None, content="true")
  inspect(parse_args(["turtles"]).timeout_multiplier is None, content="true")
  assert_true(parse_args_fails(["turtles", "--output-dir"]))
  assert_true(parse_args_fails(["turtles", "--timeout-multiplier"]))
  assert_true(parse_args_fails(["turtles", "--timeout-multiplier", "0"]))
  assert_true(parse_args_fails(["turtles", "--timeout-multiplier", "-1"]))
  assert_true(parse_args_fails(["turtles", "--timeout-multiplier", "abc"]))
}

///|
test "parse_args reads jobs and fail-under" {
  let config = parse_args(["turtles", "--jobs", "4", "--fail-under", "80"])
  inspect(config.jobs, content="4")
  inspect(config.fail_under.unwrap_or(-1.0), content="80")
  let short = parse_args(["turtles", "-j", "2"])
  inspect(short.jobs, content="2")
  let fractional = parse_args(["turtles", "--fail-under", "79.5"])
  inspect(fractional.fail_under.unwrap_or(-1.0), content="79.5")
  let zero = parse_args(["turtles", "--fail-under", "0"])
  inspect(zero.fail_under.unwrap_or(-1.0), content="0")
  let hundred = parse_args(["turtles", "--fail-under", "100"])
  inspect(hundred.fail_under.unwrap_or(-1.0), content="100")
}

///|
test "parse_args selects a MoonBit target" {
  let config = parse_args(["turtles", "--target", "native"])
  debug_inspect(config.target, content="Some(\"native\")")
  let all = parse_args(["turtles", "--target", "all"])
  debug_inspect(all.target, content="Some(\"all\")")
  assert_true(parse_args_fails(["turtles", "--target"]))
  // Any non-empty value passes: moon owns backend validity, so a backend
  // unknown to this turtles build is still forwarded for moon to judge.
  let unknown = parse_args(["turtles", "--target", "future-backend"])
  debug_inspect(unknown.target, content="Some(\"future-backend\")")
  // A repeat is an argument error; an empty value is not a target.
  assert_true(
    parse_args_fails(["turtles", "--target", "native", "--target", "js"]),
  )
  assert_true(parse_args_fails(["turtles", "--target", ""]))
}

///|
test "parse_args reads --operators as a comma-separated group list" {
  let config = parse_args(["turtles", "--operators", "body,comparison"])
  let groups = config.operators.unwrap()
  inspect(groups.length(), content="2")
  inspect(groups[0] == Body, content="true")
  inspect(groups[1] == Comparison, content="true")
  inspect(parse_args(["turtles"]).operators is None, content="true")
  assert_true(parse_args_fails(["turtles", "--operators"]))
  assert_true(parse_args_fails(["turtles", "--operators", "bogus"]))
  assert_true(parse_args_fails(["turtles", "--operators", ""]))
}

///|
test "boundary is a single opt-in group name in CLI and TOML" {
  inspect(operator_group_from_string("boundary") == Boundary, content="true")
  let config = parse_args(["turtles", "--operators", "comparison,boundary"])
  let groups = config.operators.unwrap()
  inspect(groups.length(), content="2")
  inspect(groups[0] == Comparison, content="true")
  inspect(groups[1] == Boundary, content="true")
  // No alias beyond the documented spelling: a misspelled group stays an
  // error instead of silently selecting nothing.
  assert_true(parse_args_fails(["turtles", "--operators", "boundaries"]))
  assert_true(config_fails("operators = [\"boundaries\"]"))
  let toml_config = parse_project_config("operators = [\"boundary\"]")
  inspect(toml_config.operator_enabled(Boundary), content="true")
  inspect(toml_config.operator_enabled(Comparison), content="false")
}

///|
test "parse_args rejects bad input" {
  assert_true(parse_args_fails(["turtles", "--bogus"]))
  assert_true(parse_args_fails(["turtles", "x"]))
  assert_true(parse_args_fails(["turtles", "--dir"]))
  assert_true(parse_args_fails(["turtles", "--timeout"]))
  assert_true(parse_args_fails(["turtles", "--file"]))
  assert_true(parse_args_fails(["turtles", "--json"]))
  assert_true(parse_args_fails(["turtles", "--timeout", "0"]))
  assert_true(parse_args_fails(["turtles", "--timeout", "-1"]))
  assert_true(parse_args_fails(["turtles", "--timeout", "abc"]))
  assert_true(parse_args_fails(["turtles", "--jobs"]))
  assert_true(parse_args_fails(["turtles", "--jobs", "0"]))
  assert_true(parse_args_fails(["turtles", "--jobs", "-2"]))
  assert_true(parse_args_fails(["turtles", "--jobs", "abc"]))
  assert_true(parse_args_fails(["turtles", "--jobs", "1.5"]))
  assert_true(parse_args_fails(["turtles", "--fail-under"]))
  assert_true(parse_args_fails(["turtles", "--fail-under", "-1"]))
  assert_true(parse_args_fails(["turtles", "--fail-under", "101"]))
  assert_true(parse_args_fails(["turtles", "--fail-under", "abc"]))
  assert_true(parse_args_fails(["turtles", "--fail-under", "nan"]))
}

///|
async test "load_project_config reads turtles.toml and defaults when absent" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let defaults = load_project_config(temp)
    assert_true(defaults.path_enabled("anywhere/file.mbt"))
    @fs.write_file(
      @path.Path(temp).join(@path.Path("turtles.toml")).to_string(),
      "include = [\"src/\"]\noperators = [\"boolean\"]\n",
    )
    let config = load_project_config(temp)
    assert_true(config.path_enabled("src/a.mbt"))
    assert_true(!config.path_enabled("other/a.mbt"))
    assert_true(config.operator_enabled(Boolean))
    assert_true(!config.operator_enabled(Arithmetic))
  })
}

///|
test "config_parse_key accepts every key character class" {
  let bytes = @utf8.encode("aZ9_- rest")
  let position = Ref(0)
  inspect(config_parse_key(bytes, position), content="aZ9_-")
  inspect(position.val, content="5")
}

///|
test "config string escapes decode and stay inside the quotes" {
  let config = parse_project_config(
    "include = [\"a\\\\b\", \"c\\\"d\", \"e\\n\"]",
  )
  json_inspect(config.include_patterns, content=["a\\b", "c\"d", "e\n"])
}

///|
/// `turtles --version` must report the module version. The manifest may sit
/// at the module root or above the package directory depending on how the
/// test binary is launched, so search a few candidate locations.
async test "turtles_version matches moon.mod" {
  let candidates = ["moon.mod", "../moon.mod", "../../moon.mod"]
  let mut manifest : String? = None
  for path in candidates {
    if @fs.exists(path) {
      manifest = Some(path)
      break
    }
  }
  let text = @fs.read_file(manifest.unwrap()).text()
  assert_true(text.contains("version = \"\{turtles_version}\""))
}
