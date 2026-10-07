///|
/// Keep in sync with `version` in the module's moon.mod; a test guards it.
let turtles_version : String = "0.4.0"

///|
fn print_help() -> Unit {
  println(
    (
      #|turtles - mutation testing for MoonBit
      #|
      #|Usage: turtles [OPTIONS]
      #|
      #|Options:
      #|  -d, --dir <PATH>        MoonBit module directory (default: .)
      #|      --target <TARGET>   Moon backend for check/test/planning (e.g. native, all)
      #|      --timeout <SECS>    Per-command timeout (default: 60)
      #|  -j, --jobs <N>          Run up to N mutants in parallel (default: 1)
      #|      --fail-under <PCT>  Exit 1 if the mutation score is below PCT (0-100)
      #|      --file <TEXT>       Only mutate source paths containing TEXT
      #|      --json <PATH>       Write a JSON report to PATH
      #|      --output-dir <DIR>  Report + survivor diffs (default: <dir>/.turtles)
      #|      --iterate           Reuse KILLED/UNVIABLE from the previous report
      #|      --timeout-multiplier <N>  Timeout = N x baseline (floor 10s)
      #|      --affected          Experimental: scope tests to affected packages
      #|      --operators <LIST>  Comma-separated operator groups (overrides
      #|                        turtles.toml; body is opt-in only)
      #|      --emit-regressions  Write regression-test templates for property kills
      #|      --emit-properties   Write property-test suggestions for survivors
      #|      --pbt-witness       Differential QuickCheck witness for survivors
      #|      --pbt-amplify <N>   Re-run survivor properties with N x count and fresh seeds
      #|      --list              List mutations without running tests
      #|      --version           Print the turtles version and exit
      #|  -h, --help              Print help
    ),
  )
}

///|
fn parse_args(args : Array[String]) -> Config raise {
  let mut dir = "."
  let mut target : String? = None
  let mut timeout_ms = 60000
  let mut jobs = 1
  let mut fail_under : Double? = None
  let mut list = false
  let mut file_filter : String? = None
  let mut json_report : String? = None
  let mut timeout_multiplier : Double? = None
  let mut iterate = false
  let mut output_dir : String? = None
  let mut affected = false
  let cli_operators : Array[OperatorGroup] = []
  let mut emit_regressions = false
  let mut emit_properties = false
  let mut pbt_witness = false
  let mut pbt_amplify : Int? = None
  let mut i = 1
  // Every iteration must consume at least one argument, so the loop can run
  // at most args.length() times; more steps means the cursor went backwards.
  let mut steps = 0
  while i < args.length() {
    steps = steps + 1
    guard steps <= args.length() else {
      fail("internal error: argument parser made no progress")
    }
    let arg = args[i]
    match arg {
      "-h" | "--help" => {
        print_help()
        @sys.exit(0)
      }
      "--version" => {
        println("turtles \{turtles_version}")
        @sys.exit(0)
      }
      "-d" | "--dir" => {
        guard i + 1 < args.length() else { fail("--dir requires a path") }
        i = i + 1
        dir = args[i]
      }
      "--target" => {
        guard i + 1 < args.length() else { fail("--target requires a target") }
        guard target is None else { fail("--target may only be given once") }
        i = i + 1
        // turtles keeps no backend list: moon owns target validity, so new
        // backends work without a turtles release. Only the missing/empty
        // value is an argument error here.
        guard args[i] != "" else {
          fail("--target requires a non-empty target")
        }
        target = Some(args[i])
      }
      "--timeout" => {
        guard i + 1 < args.length() else { fail("--timeout requires seconds") }
        i = i + 1
        let seconds = @string.parse_int(args[i]) catch {
          _ => fail("invalid timeout: \{args[i]}")
        }
        guard seconds > 0 else { fail("--timeout must be greater than zero") }
        timeout_ms = seconds * 1000
      }
      "--file" => {
        guard i + 1 < args.length() else { fail("--file requires text") }
        i = i + 1
        file_filter = Some(args[i])
      }
      "--json" => {
        guard i + 1 < args.length() else { fail("--json requires a path") }
        i = i + 1
        json_report = Some(args[i])
      }
      "-j" | "--jobs" => {
        guard i + 1 < args.length() else { fail("--jobs requires a count") }
        i = i + 1
        let count = @string.parse_int(args[i]) catch {
          _ => fail("invalid jobs: \{args[i]}")
        }
        guard count > 0 else { fail("--jobs must be a positive integer") }
        jobs = count
      }
      "--fail-under" => {
        guard i + 1 < args.length() else {
          fail("--fail-under requires a percentage")
        }
        i = i + 1
        let threshold = @string.parse_double(args[i]) catch {
          _ => fail("invalid fail-under threshold: \{args[i]}")
        }
        guard threshold >= 0.0 && threshold <= 100.0 else {
          fail("--fail-under must be between 0 and 100")
        }
        fail_under = Some(threshold)
      }
      "--iterate" => iterate = true
      "--affected" => affected = true
      "--operators" => {
        guard i + 1 < args.length() else {
          fail("--operators requires a group list")
        }
        i = i + 1
        for part in args[i].split(",") {
          let name = part.trim().to_owned()
          guard name != "" else { fail("invalid --operators list: \{args[i]}") }
          cli_operators.push(operator_group_from_string(name))
        }
      }
      "--emit-regressions" => emit_regressions = true
      "--emit-properties" => emit_properties = true
      "--pbt-witness" => pbt_witness = true
      "--pbt-amplify" => {
        guard i + 1 < args.length() else {
          fail("--pbt-amplify requires a factor")
        }
        i = i + 1
        let factor = @string.parse_int(args[i]) catch {
          _ => fail("invalid pbt-amplify factor: \{args[i]}")
        }
        guard factor >= 1 else { fail("--pbt-amplify must be >= 1") }
        pbt_amplify = Some(factor)
      }
      "--output-dir" => {
        guard i + 1 < args.length() else {
          fail("--output-dir requires a path")
        }
        i = i + 1
        output_dir = Some(args[i])
      }
      "--timeout-multiplier" => {
        guard i + 1 < args.length() else {
          fail("--timeout-multiplier requires a factor")
        }
        i = i + 1
        let factor = @string.parse_double(args[i]) catch {
          _ => fail("invalid timeout multiplier: \{args[i]}")
        }
        guard factor > 0.0 else {
          fail("--timeout-multiplier must be greater than zero")
        }
        timeout_multiplier = Some(factor)
      }
      "--list" => list = true
      other => fail("unknown argument: \{other} (try --help)")
    }
    i = i + 1
  }
  {
    dir,
    target,
    timeout_ms,
    jobs,
    fail_under,
    list,
    file_filter,
    json_report,
    timeout_multiplier,
    iterate,
    output_dir,
    affected,
    operators: if cli_operators.is_empty() {
      None
    } else {
      Some(cli_operators)
    },
    emit_regressions,
    emit_properties,
    pbt_witness,
    pbt_amplify,
  }
}

///|
fn config_is_space(byte : Byte) -> Bool {
  byte == b' ' || byte == b'\t' || byte == b'\n' || byte == b'\r'
}

///|
fn config_skip_space_and_comments(bytes : Bytes, position : Ref[Int]) -> Unit {
  while true {
    while position.val < bytes.length() && config_is_space(bytes[position.val]) {
      position.val = position.val + 1
    }
    if position.val >= bytes.length() || bytes[position.val] != b'#' {
      break
    }
    while position.val < bytes.length() && bytes[position.val] != b'\n' {
      position.val = position.val + 1
    }
  }
}

///|
fn config_error(bytes : Bytes, position : Int, message : String) -> String {
  let mut line = 1
  let mut column = 1
  let mut i = 0
  while i < position && i < bytes.length() {
    if bytes[i] == b'\n' {
      line = line + 1
      column = 1
    } else {
      column = column + 1
    }
    i = i + 1
  }
  "\{message} at \{line}:\{column}"
}

///|
fn config_consume(bytes : Bytes, position : Ref[Int], expected : Byte) -> Bool {
  if position.val < bytes.length() && bytes[position.val] == expected {
    position.val = position.val + 1
    true
  } else {
    false
  }
}

///|
fn config_expect(
  bytes : Bytes,
  position : Ref[Int],
  expected : Byte,
) -> Unit raise {
  guard config_consume(bytes, position, expected) else {
    fail(
      config_error(bytes, position.val, "expected configuration punctuation"),
    )
  }
}

///|
fn config_parse_key(bytes : Bytes, position : Ref[Int]) -> String raise {
  let start = position.val
  while position.val < bytes.length() {
    let byte = bytes[position.val]
    let valid = (byte >= b'a' && byte <= b'z') ||
      (byte >= b'A' && byte <= b'Z') ||
      (byte >= b'0' && byte <= b'9') ||
      byte == b'_' ||
      byte == b'-'
    if !valid {
      break
    }
    position.val = position.val + 1
  }
  guard start != position.val else {
    fail(config_error(bytes, position.val, "expected a configuration key"))
  }
  @utf8.decode(bytes[start:position.val])
}

///|
fn config_parse_string(bytes : Bytes, position : Ref[Int]) -> String raise {
  config_expect(bytes, position, b'"')
  let output = @buffer.Buffer()
  // Each iteration consumes at least one byte, so a step count beyond the
  // input size means the cursor went backwards instead of advancing.
  let mut steps = 0
  while position.val < bytes.length() {
    steps = steps + 1
    guard steps <= bytes.length() else {
      fail(config_error(bytes, position.val, "unterminated string"))
    }
    let byte = bytes[position.val]
    position.val = position.val + 1
    match byte {
      b'"' => return @utf8.decode(output.to_bytes())
      b'\\' => {
        guard position.val < bytes.length() else {
          fail(config_error(bytes, position.val, "unterminated string escape"))
        }
        let escaped = bytes[position.val]
        position.val = position.val + 1
        match escaped {
          b'"' => output.write_byte(b'"')
          b'\\' => output.write_byte(b'\\')
          b'n' => output.write_byte(b'\n')
          b'r' => output.write_byte(b'\r')
          b't' => output.write_byte(b'\t')
          _ =>
            fail(
              config_error(
                bytes,
                position.val,
                "unsupported string escape; use \", \\\\, \\n, \\r, or \\t",
              ),
            )
        }
      }
      b'\n' | b'\r' =>
        fail(config_error(bytes, position.val, "newline in quoted string"))
      _ => output.write_byte(byte)
    }
  }
  fail(config_error(bytes, position.val, "unterminated quoted string"))
}

///|
fn config_parse_string_array(
  bytes : Bytes,
  position : Ref[Int],
) -> Array[String] raise {
  config_expect(bytes, position, b'[')
  let values : Array[String] = []
  while true {
    config_skip_space_and_comments(bytes, position)
    if config_consume(bytes, position, b']') {
      return values
    }
    values.push(config_parse_string(bytes, position))
    config_skip_space_and_comments(bytes, position)
    if config_consume(bytes, position, b',') {
      continue
    }
    if config_consume(bytes, position, b']') {
      return values
    }
    fail(
      config_error(bytes, position.val, "expected ',' or ']' after array item"),
    )
  } nobreak {
    values
  }
}

///|
fn parse_project_config(source : String) -> ProjectConfig raise {
  let bytes = @utf8.encode(source)
  let position = Ref(0)
  let include_patterns : Array[String] = []
  let exclude_patterns : Array[String] = []
  let operators : Array[OperatorGroup] = []
  let mut operators_set = false
  let mut include_set = false
  let mut exclude_set = false
  while true {
    config_skip_space_and_comments(bytes, position)
    if position.val >= bytes.length() {
      break
    }
    let key = config_parse_key(bytes, position)
    config_skip_space_and_comments(bytes, position)
    config_expect(bytes, position, b'=')
    config_skip_space_and_comments(bytes, position)
    let values = config_parse_string_array(bytes, position)
    match key {
      "include" => {
        guard !include_set else {
          fail(config_error(bytes, position.val, "duplicate include key"))
        }
        include_set = true
        for value in values {
          include_patterns.push(value)
        }
      }
      "exclude" => {
        guard !exclude_set else {
          fail(config_error(bytes, position.val, "duplicate exclude key"))
        }
        exclude_set = true
        for value in values {
          exclude_patterns.push(value)
        }
      }
      "operators" => {
        guard !operators_set else {
          fail(config_error(bytes, position.val, "duplicate operators key"))
        }
        operators_set = true
        for value in values {
          operators.push(operator_group_from_string(value))
        }
      }
      other =>
        fail(
          config_error(
            bytes,
            position.val,
            "unknown key \{other}; expected include, exclude, or operators",
          ),
        )
    }
  }
  {
    include_patterns,
    exclude_patterns,
    operators: if operators_set {
      Some(operators)
    } else {
      None
    },
  }
}

///|
async fn load_project_config(root : String) -> ProjectConfig {
  let path = @path.Path(root).join(Path("turtles.toml")).to_string()
  if !@fs.exists(path) {
    return default_project_config()
  }
  let source = @fs.read_file(path).text()
  parse_project_config(source) catch {
    error => fail("invalid \{path}: \{error}")
  }
}
