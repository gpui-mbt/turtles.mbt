///|
/// A prior run's report, distilled for --iterate reuse decisions.
struct PriorReport {
  schema : Int32
  turtles_version : String?
  moon_version : String?
  target : String?
  files : Map[String, String]
  /// identity -> (mutation, outcome, kills, amplified): the flag travels
  /// so a reused KILLED verdict can keep --pbt-amplify's attribution
  mutants : Map[String, (Mutation, Outcome, Array[Kill]?, Bool)]
}

///|
fn json_string(value : Json) -> String? {
  match value {
    String(s) => Some(s)
    _ => None
  }
}

///|
fn json_field_string(fields : Map[String, Json], name : String) -> String? {
  match fields.get(name) {
    Some(value) => json_string(value)
    None => None
  }
}

///|
fn outcome_from_name(name : String) -> Outcome? {
  match name {
    "KILLED" => Some(Killed)
    "SURVIVED" => Some(Survived)
    "TIMEOUT" => Some(Timeout)
    "UNVIABLE" => Some(Unviable)
    _ => None
  }
}

///|
/// Read a schema-3 report for --iterate. Older or partial reports yield
/// None rather than failing the run — reuse is an optimization, never
/// required for correctness.
async fn load_prior_report(path : String) -> PriorReport? {
  let text = @fs.read_file(path).text() catch { _ => return None }
  let json = @json.parse(text) catch { _ => return None }
  guard json is Object(top) else { return None }
  let schema = match json_field_string_or_number(top, "schema") {
    Some(n) => n
    None => return None
  }
  let files : Map[String, String] = Map([])
  match top.get("files") {
    Some(Object(entries)) =>
      for entry in entries {
        match json_string(entry.1) {
          Some(hash) => files[entry.0] = hash
          None => ()
        }
      }
    _ => ()
  }
  let mutants : Map[String, (Mutation, Outcome, Array[Kill]?, Bool)] = Map([])
  match top.get("mutants") {
    Some(Array(entries)) =>
      for entry in entries {
        match parse_prior_mutant(entry) {
          Some((mutation, outcome, kills, amplified)) =>
            mutants[mutation_identity(mutation)] = (
              mutation, outcome, kills, amplified,
            )
          None => ()
        }
      }
    _ => ()
  }
  Some({
    schema,
    turtles_version: json_field_string(top, "turtles_version"),
    moon_version: json_field_string(top, "moon_version"),
    target: json_field_string(top, "target"),
    files,
    mutants,
  })
}

///|
fn json_field_string_or_number(
  fields : Map[String, Json],
  name : String,
) -> Int32? {
  match fields.get(name) {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
fn parse_prior_mutant(json : Json) -> (Mutation, Outcome, Array[Kill]?, Bool)? {
  guard json is Object(fields) else { return None }
  guard fields.get("path") is Some(String(path)) else { return None }
  guard fields.get("offset") is Some(Number(start, ..)) else { return None }
  guard fields.get("end") is Some(Number(end, ..)) else { return None }
  guard fields.get("group") is Some(String(group_text)) else { return None }
  guard fields.get("original") is Some(String(original)) else { return None }
  guard fields.get("replacement") is Some(String(replacement)) else {
    return None
  }
  guard fields.get("outcome") is Some(String(outcome_text)) else { return None }
  guard fields.get("line") is Some(Number(line, ..)) else { return None }
  guard fields.get("column") is Some(Number(column, ..)) else { return None }
  let group = operator_group_from_string(group_text) catch { _ => return None }
  guard outcome_from_name(outcome_text) is Some(outcome) else { return None }
  let amplified = match fields.get("amplified") {
    Some(True) => true
    _ => false
  }
  Some(
    (
      {
        path,
        start: start.to_int(),
        end: end.to_int(),
        line: line.to_int(),
        column: column.to_int(),
        group,
        original,
        replacement,
        // The parsed mutant only ever serves as an identity key; the
        // reused result reuses the current scan's mutation, whose
        // visibility is authoritative.
        visibility: Private,
      },
      outcome,
      kills_from_json(json),
      amplified,
    ),
  )
}

///|
/// True only when both fingerprint maps agree on the same file set and
/// hashes — a file added, removed, or edited in either direction makes
/// prior verdicts unverifiable.
fn fingerprints_match(
  prior : Map[String, String],
  current : Map[String, String],
) -> Bool {
  guard prior.length() == current.length() else { return false }
  for path, hash in prior {
    if current.get(path) != Some(hash) {
      return false
    }
  }
  true
}

///|
/// Reuse is only ever an optimization: any doubt sends the mutant back
/// through the classifier. Reuse a prior KILLED/UNVIABLE verdict iff the
/// mutant's identity tuple matches (path + byte span + both texts +
/// operator group — never line numbers), the whole fingerprint map is
/// unchanged — a verdict may owe its outcome to a test file, `moon.pkg`
/// target rules, `moon.mod`, or `turtles.toml`, not just the mutated
/// source — and the same turtles/moon toolchain produced the prior
/// report. Survived/Timeout are never reused — they are exactly what an
/// iterated run must re-examine.
fn prior_reusable_outcome(
  prior : PriorReport,
  mutation : Mutation,
  current_files : Map[String, String],
  moon_version : String?,
  target~ : String? = None,
) -> (Outcome, Array[Kill]?, Bool)? {
  if prior.schema != 3 {
    return None
  }
  if prior.turtles_version != Some(turtles_version) {
    return None
  }
  if prior.moon_version != moon_version {
    return None
  }
  if prior.target != target {
    return None
  }
  guard fingerprints_match(prior.files, current_files) else { return None }
  guard prior.files.get(mutation.path) is Some(recorded_hash) &&
    current_files.get(mutation.path) == Some(recorded_hash) else {
    return None
  }
  guard prior.mutants.get(mutation_identity(mutation))
    is Some((_, outcome, kills, amplified)) else {
    return None
  }
  // Amplification changes both budget and seeds. Its kills are never
  // reusable, even when amplification is enabled again: conservatively
  // reclassify and rerun the current analysis instead of losing provenance.
  if amplified {
    return None
  }
  match outcome {
    // The kill's attribution travels with the verdict: a reused row
    // keeps the prior report's killed_by rather than degrading to
    // "unavailable". `amplified` is carried along and only emitted when
    // the current run also has --pbt-amplify on.
    Killed => Some((outcome, kills, amplified))
    Unviable => Some((outcome, None, false))
    Survived | Timeout => None
  }
}
