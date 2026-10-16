///|
/// The kind of test a `moon test --test-failure-json` record describes.
/// Order of checks in `test_kind` matters: a doc test that fails on a
/// snapshot expectation is still a doc test.
enum TestKind {
  Property
  Snapshot
  DocTest
  Assertion
} derive(Eq, Debug, ToJson)

///|
fn test_kind_name(kind : TestKind) -> String {
  match kind {
    Property => "property"
    Snapshot => "snapshot"
    DocTest => "doc_test"
    Assertion => "assertion"
  }
}

///|
/// One failing test attributed to a mutant kill, parsed from a
/// `--test-failure-json` line.
struct Kill {
  pkg : String
  filename : String
  index : Int32
  test_name : String
  kind : TestKind
  counterexample : String?
} derive(Debug, ToJson(fields(pkg(rename="package"))))

///|
/// The oracle argv for every `moon test` turtles drives: baseline and
/// mutant runs alike emit structured failures so verdicts can be
/// attributed to concrete tests. Snapshot suites make `--update`/`-u`
/// poisonous here — it would rewrite the expectation on disk and turn a
/// kill into a survive — so the flag is never added.
fn mutant_test_args(packages : Array[String]?) -> Array[String] {
  let args : Array[String] = ["test", "--test-failure-json"]
  match packages {
    Some(selected) =>
      for pkg_name in selected {
        args.push("-p")
        args.push(pkg_name)
      }
    None => ()
  }
  args
}

///|
/// Classify one failure record. Verified on moon 0.1.20260920:
/// properties carry "QuickCheck falsified" in the message; `mbt check`
/// doc tests (README.mbt.md and docstring blocks) report an empty
/// `test_name` (and `.mbt.md` filename for markdown docs); snapshot
/// expectations start with "@EXPECT_FAILED"; everything else is a plain
/// assertion failure.
fn test_kind(
  filename : String,
  test_name : String,
  message : String,
) -> TestKind {
  if message.contains("QuickCheck falsified") {
    Property
  } else if filename.has_suffix(".mbt.md") || test_name == "" {
    DocTest
  } else if message.has_prefix("@EXPECT_FAILED") {
    Snapshot
  } else {
    Assertion
  }
}

///|
/// The shrunk counterexample a property failure reports, when present.
/// Only the documented `counterexample:` line is read; anything else
/// degrades to None rather than guessing.
fn parse_counterexample(message : String) -> String? {
  for line in message.split("\n") {
    if line.has_prefix("counterexample:") {
      let value = line[15:].trim().to_owned()
      return Some(value)
    }
  }
  None
}

///|
/// Parse one `--test-failure-json` line into a Kill. `index` arrives as
/// a JSON string ("0"), not a number. Lines that do not match the
/// documented shape return None so callers can skip them.
fn parse_kill_line(line : String) -> Kill? {
  let json = @json.parse(line) catch { _ => return None }
  guard json is Object(fields) else { return None }
  guard fields.get("package") is Some(String(pkg)) else { return None }
  guard fields.get("filename") is Some(String(filename)) else { return None }
  guard fields.get("message") is Some(String(message)) else { return None }
  let test_name = match fields.get("test_name") {
    Some(String(name)) => name
    _ => ""
  }
  let index = match fields.get("index") {
    Some(String(text)) => @string.parse_int(text) catch { _ => 0 }
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
  let kind = test_kind(filename, test_name, message)
  let counterexample = match kind {
    Property => parse_counterexample(message)
    _ => None
  }
  Some({ pkg, filename, index, test_name, kind, counterexample, })
}

///|
/// Extract every failure record from one `moon test` run's captured
/// output. Returns None when no structured line was found — older moon
/// versions, a crashed test binary, or an abort before tests ran all
/// land here, and the caller falls back to the exit-status verdict.
fn parse_test_failures(output : String) -> Array[Kill]? {
  let kills : Array[Kill] = []
  for line in output.split("\n") {
    let trimmed = line.trim().to_owned()
    if !trimmed.has_prefix("{") {
      continue
    }
    match parse_kill_line(trimmed) {
      Some(kill) => kills.push(kill)
      None => ()
    }
  }
  if kills.is_empty() {
    None
  } else {
    Some(kills)
  }
}

///|
/// The captured output of the most recent moon command in `root`;
/// `run_moon_command` truncates the log on every invocation.
async fn read_moon_output(root : String) -> String? {
  let text = @fs.read_file(root + "-moon-output.log").text() catch {
    _ => return None
  }
  Some(text)
}

///|
/// Failure records of the last test run in `root`, or None when the
/// structured stream was absent or unparseable.
async fn last_test_failures(root : String) -> Array[Kill]? {
  match read_moon_output(root) {
    Some(output) => parse_test_failures(output)
    None => None
  }
}

///|
/// Console suffix for a KILLED progress line, e.g.
/// ` — killed by lib_test.mbt:0 "prop idempotent" (property, counterexample: 0)`.
/// Empty for non-kills and for kills where attribution was unavailable.
fn describe_kills(result : MutationResult) -> String {
  match (result.outcome, result.kills) {
    (Killed, Some(kills)) =>
      if kills.is_empty() {
        ""
      } else {
        " — killed by " + kills.map(describe_kill).join("; ")
      }
    _ => ""
  }
}

///|
/// A stable identity for one failing test, used to diff two baseline
/// runs in the determinism guard.
fn kill_key(kill : Kill) -> String {
  "\{kill.pkg}|\{kill.filename}|\{kill.index}|\{kill.test_name}"
}

///|
/// Human label for an unstable test in the determinism-guard error.
fn describe_kill(kill : Kill) -> String {
  let kind = test_kind_name(kill.kind)
  match kill.counterexample {
    Some(counterexample) =>
      "\{kill.filename}:\{kill.index} \"\{kill.test_name}\" (\{kind}, counterexample: \{counterexample})"
    None => "\{kill.filename}:\{kill.index} \"\{kill.test_name}\" (\{kind})"
  }
}

///|
/// Read a `Kill` back out of a JSON report's `killed_by` entry — the
/// shape `Kill`'s `ToJson` writes. Any missing or malformed field
/// yields None; a report written before attribution simply has no
/// `killed_by` array to read.
fn kill_from_json(json : Json) -> Kill? {
  guard json is Object(fields) else { return None }
  guard fields.get("package") is Some(String(pkg)) else { return None }
  guard fields.get("filename") is Some(String(filename)) else { return None }
  guard fields.get("test_name") is Some(String(test_name)) else { return None }
  let kind = match fields.get("kind") {
    Some(String("Property")) => Property
    Some(String("Snapshot")) => Snapshot
    Some(String("DocTest")) => DocTest
    Some(String("Assertion")) => Assertion
    _ => return None
  }
  let index = match fields.get("index") {
    Some(Number(n, ..)) => n.to_int()
    Some(String(text)) => @string.parse_int(text) catch { _ => 0 }
    _ => 0
  }
  let counterexample = match fields.get("counterexample") {
    Some(String(value)) => Some(value)
    _ => None
  }
  Some({ pkg, filename, index, test_name, kind, counterexample, })
}

///|
/// The `killed_by` array of a prior report's mutant row, or None when
/// the row predates attribution or listed no records — either way the
/// reused verdict keeps the `attribution: "unavailable"` fallback.
fn kills_from_json(json : Json) -> Array[Kill]? {
  guard json is Object(fields) else { return None }
  guard fields.get("killed_by") is Some(Array(entries)) else { return None }
  let kills : Array[Kill] = []
  for entry in entries {
    match kill_from_json(entry) {
      Some(kill) => kills.push(kill)
      None => ()
    }
  }
  if kills.is_empty() {
    None
  } else {
    Some(kills)
  }
}

///|
/// Failure names present in exactly one of two runs — the unstable
/// tests the determinism guard reports.
fn unstable_kills(first : Array[Kill], second : Array[Kill]) -> Array[Kill] {
  let first_keys : Map[String, Bool] = Map([])
  for kill in first {
    first_keys[kill_key(kill)] = true
  }
  let second_keys : Map[String, Bool] = Map([])
  for kill in second {
    second_keys[kill_key(kill)] = true
  }
  let unstable : Array[Kill] = []
  for kill in first {
    if !second_keys.contains(kill_key(kill)) {
      unstable.push(kill)
    }
  }
  for kill in second {
    if !first_keys.contains(kill_key(kill)) {
      unstable.push(kill)
    }
  }
  unstable
}
