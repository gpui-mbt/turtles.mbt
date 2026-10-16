///|
enum OperatorGroup {
  Comparison
  Boolean
  Arithmetic
  Literal
  Condition
  Body
} derive(Eq)

///|
fn operator_group_from_string(value : String) -> OperatorGroup raise {
  match value {
    "comparison" | "comparisons" => Comparison
    "boolean" | "boolean-logic" => Boolean
    "arithmetic" => Arithmetic
    "literal" | "boolean-literal" | "boolean-literals" => Literal
    "condition" | "conditions" => Condition
    "body" | "bodies" => Body
    other =>
      fail(
        "unknown operator group \{other}; expected comparison, boolean, arithmetic, literal, condition, or body",
      )
  }
}

///|
fn operator_group_name(group : OperatorGroup) -> String {
  match group {
    Comparison => "comparison"
    Boolean => "boolean"
    Arithmetic => "arithmetic"
    Literal => "literal"
    Condition => "condition"
    Body => "body"
  }
}

///|
struct ProjectConfig {
  include_patterns : Array[String]
  exclude_patterns : Array[String]
  operators : Array[OperatorGroup]?
}

///|
fn default_project_config() -> ProjectConfig {
  { include_patterns: [], exclude_patterns: [], operators: None, }
}

///|
fn ProjectConfig::path_enabled(self : ProjectConfig, path : String) -> Bool {
  let path = path.replace_all(old="\\", new="/")
  let mut included = self.include_patterns.is_empty()
  if !included {
    for pattern in self.include_patterns {
      if path.contains(pattern) {
        included = true
        break
      }
    }
  }
  if !included {
    return false
  }
  for pattern in self.exclude_patterns {
    if path.contains(pattern) {
      return false
    }
  }
  true
}

///|
fn ProjectConfig::operator_enabled(
  self : ProjectConfig,
  group : OperatorGroup,
) -> Bool {
  match self.operators {
    // `body` is opt-in: replacing whole function bodies is too aggressive a
    // default, so an unset operator list means every group except Body.
    None => group != Body
    Some(operators) => {
      for operator in operators {
        if operator == group {
          return true
        }
      }
      false
    }
  }
}

///|
struct Config {
  dir : String
  target : String?
  timeout_ms : Int32
  jobs : Int32
  fail_under : Double?
  list : Bool
  file_filter : String?
  json_report : String?
  timeout_multiplier : Double?
  iterate : Bool
  output_dir : String?
  affected : Bool
  operators : Array[OperatorGroup]?
  emit_regressions : Bool
  emit_properties : Bool
  pbt_witness : Bool
  pbt_amplify : Int32?
}

///|
struct Mutation {
  path : String
  start : Int32
  end : Int32
  line : Int32
  column : Int32
  group : OperatorGroup
  original : String
  replacement : String
  visibility : MutantVisibility
} derive(Eq)

///|
enum Outcome {
  Killed
  Survived
  Timeout
  Unviable
} derive(Eq)

///|
fn outcome_name(outcome : Outcome) -> String {
  match outcome {
    Killed => "KILLED"
    Survived => "SURVIVED"
    Timeout => "TIMEOUT"
    Unviable => "UNVIABLE"
  }
}

///|
/// Visibility of the top-level declaration enclosing a mutant. Every
/// `pub` form — `pub`, `pub(all)`, `pub(open)`, ... — is public; `priv`
/// and the implicit default are private. `test` blocks carry no
/// visibility marker, so their mutants sit in their own bucket, outside
/// the public/private score split entirely.
enum MutantVisibility {
  Public
  Private
  Test
} derive(Eq, Debug)

///|
fn visibility_name(visibility : MutantVisibility) -> String {
  match visibility {
    Public => "public"
    Private => "private"
    Test => "test"
  }
}

///|
struct MutationResult {
  mutation : Mutation
  outcome : Outcome
  duration_ms : Int64
  reused : Bool
  packages : Array[String]?
  kills : Array[Kill]?
  /// PBT witness counterexample, or "none" when the harness ran its
  /// budget without falsifying (--pbt-witness survivors only)
  witness : String?
  /// why no witness was produced (effects-unknown / recursive / cfg /
  /// name-collision / nondeterministic / harness-error)
  witness_skipped : String?
  /// killed only after --pbt-amplify rewrote the property budget
  amplified : Bool?
}

///|
struct JsonMutation {
  id : String
  path : String
  line : Int32
  column : Int32
  offset : Int32
  end : Int32
  group : String
  visibility : String
  original : String
  replacement : String
  outcome : String
  duration_ms : Int64
  reused : Bool
  packages : Array[String]?
  killed_by : Array[Kill]?
  attribution : String?
  witness : String?
  witness_skipped : String?
  amplified : Bool?
} derive(ToJson)

///|
struct JsonKillCounts {
  property : Int32
  snapshot : Int32
  doc_test : Int32
  assertion : Int32
} derive(Debug, ToJson)

///|
struct JsonSummary {
  killed : Int32
  survived : Int32
  timeout : Int32
  unviable : Int32
  reused : Int32
  score : Double
  kills_by_kind : JsonKillCounts
  property_only_kills : Int32
  score_public : JsonVisibilitySummary
  score_private : JsonVisibilitySummary
} derive(ToJson)

///|
/// Outcome tallies and score for one visibility bucket — the same
/// killed-over-viable rule as the headline score, restricted to that
/// bucket's mutants. Test-block mutants are counted in the headline
/// score only; they appear in neither bucket.
struct JsonVisibilitySummary {
  mutants : Int32
  killed : Int32
  survived : Int32
  timeout : Int32
  unviable : Int32
  score : Double
} derive(Debug, ToJson)

///|
struct JsonSkippedFile {
  path : String
  error : String
} derive(ToJson)

///|
/// A file the scanner could not parse. Skipping keeps the rest of the
/// module scannable, but mutants in that file are silently absent — the
/// report must carry them so the gap stays visible.
struct SkippedFile {
  path : String
  error : String
}

///|
/// A top-level block excluded from mutation discovery by a skip marker
/// (`#turtles.skip` or a `// turtles: skip` line comment).
struct SkippedBlock {
  path : String
  line : Int32
}

///|
struct JsonReport {
  schema : Int32
  module_path : String
  turtles_version : String
  moon_version : String?
  target : String?
  /// Mutants Moon does not compile for the selected target: reported but
  /// never classified, so they cannot distort the score.
  inactive_mutants : Int32
  /// Sorted module-relative paths contributing at least one inactive mutant.
  inactive_files : Array[String]
  baseline_duration_ms : Int64
  baseline_check_ms : Int64?
  baseline_test_ms : Int64?
  test_scope : String
  mutants : Array[JsonMutation]
  summary : JsonSummary
  skipped_files : Array[JsonSkippedFile]
  files : Map[String, String]?
  regressions : Array[String]
  /// live `properties/<id>.mbt` files written by --emit-properties
  properties : Array[String]?
} derive(ToJson(fields(module_path(rename="module"))))

///|
enum CommandResult {
  CommandSuccess
  CommandFailure
  CommandTimeout
} derive(Eq)
