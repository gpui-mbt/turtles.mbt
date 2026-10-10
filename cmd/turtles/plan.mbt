///|
/// Dependency-aware test selection for `--affected`.
///
/// The plan is built from `moon test --dry-run` — moon's own build plan —
/// so the dependency edges are authoritative, not re-derived from moon.pkg
/// parsing. For every package we record which local packages its test
/// executables link (direct `-i` entries plus the transitively reachable
/// closure over library edges). A mutant in package P is then classified by
/// running only the tests of packages whose test targets can observe P.
/// The plan is built in two passes: pass one records every fqn/dir/artifact
/// mapping so `-i` imports resolve regardless of build-package line order;
/// pass two resolves imports. An unresolved module-local `-i` invalidates
/// the whole plan — a narrowed test set must never be silently computed
/// from partial edges — and the caller falls back to `moon test`.
struct TestPlan {
  /// package dir (relative to module root) -> package fqn
  dir_to_fqn : Map[String, String]
  /// package dir -> set of package dirs its test targets can observe
  observables : Map[String, Map[String, Bool]]
}

///|
fn split_args(line : String) -> Array[String] {
  let out : Array[String] = []
  for part in line.split(" ") {
    let t = part.trim(chars=" '\t\r\n").to_owned()
    if t != "" {
      out.push(t)
    }
  }
  out
}

///|
/// Strip the build-output prefix off a module-local artifact path:
/// `./_build/<backend>/<profile>/<kind>/<pkg-path>/<name>` → `pkg-path`.
/// Returns None for paths outside `_build` (external deps, $MOON_HOME).
fn artifact_pkg_path(path : String) -> String? {
  let path = path.replace_all(old="\\", new="/")
  let path = if path.has_prefix("./") { path[2:].to_owned() } else { path }
  let parts = path.split("/").collect()
  if parts.length() < 4 || parts[0].to_owned() != "_build" {
    return None
  }
  // parts: _build, backend, profile, kind, <pkg-path...>, basename
  if parts.length() < 6 {
    return Some("")
  }
  let joined : Array[String] = []
  for i = 4; i < parts.length() - 1; i = i + 1 {
    joined.push(parts[i].to_owned())
  }
  Some(joined.join("/"))
}

///|
/// Mappings learned from a module's dry-run plan. The artifact path ->
/// source dir correspondence is observed from each package's own
/// `-o`/`--pkg-sources` pair rather than guessed from a convention;
/// conflicting observations mark the artifact dir ambiguous and resolve to
/// None, failing closed to the module-wide test run.
struct PlanBuilder {
  fqn_to_dir : Map[String, String]
  dir_to_fqn : Map[String, String]
  /// artifact pkg path (e.g. "time/internal/tzif") -> source dir, or None
  /// when two source dirs map to it
  artifact_to_dir : Map[String, String?]
  /// source dir -> direct dep dirs (non-test targets only)
  source_deps : Map[String, Map[String, Bool]]
  /// source dir -> direct dep dirs of its test executables
  test_deps : Map[String, Map[String, Bool]]
  /// build-package records awaiting import resolution in pass two
  pending : Array[PendingLine]
  /// positional `.mbt` inputs observed on build-package lines, in order
  raw_sources : Array[String]
  /// how many `moonc build-package` lines the plan contained
  mut build_package_lines : Int
}

///|
/// One `moonc build-package` line held for pass two: who owns it, whether
/// it is a test target, and its raw `-i` entries.
struct PendingLine {
  owner : String
  test_mode : Bool
  imports : Array[String]
}

///|
fn PlanBuilder::new() -> PlanBuilder {
  {
    fqn_to_dir: Map([]),
    dir_to_fqn: Map([]),
    artifact_to_dir: Map([]),
    source_deps: Map([]),
    test_deps: Map([]),
    pending: [],
    raw_sources: [],
    build_package_lines: 0,
  }
}

///|
fn PlanBuilder::record_pkg_sources(
  self : PlanBuilder,
  args : Array[String],
) -> Unit {
  for i = 0; i + 1 < args.length(); i = i + 1 {
    if args[i] == "-pkg-sources" || args[i] == "--pkg-sources" {
      match args[i + 1].split(":").collect() {
        [fqn, dir] => {
          let dir = if dir.has_prefix("./") {
            dir[2:].to_owned()
          } else {
            dir.to_owned()
          }
          let dir = if dir == "" { "." } else { dir }
          self.fqn_to_dir[fqn.to_owned()] = dir
          // `moon test -p` selects by exact fqn. Test targets reuse the
          // source dir with a `_test`-suffixed fqn (e.g. blackbox); keep
          // the plain fqn so `-p` names a real package.
          let fqn = fqn.to_owned()
          let keep_existing = match self.dir_to_fqn.get(dir) {
            Some(existing) =>
              !existing.has_suffix("_test") && fqn.has_suffix("_test")
            None => false
          }
          if !keep_existing {
            self.dir_to_fqn[dir] = fqn
          }
        }
        _ => ()
      }
    }
  }
}

///|
fn PlanBuilder::record_artifact_mapping(
  self : PlanBuilder,
  out_path : String?,
  owner_dir : String,
) -> Unit {
  match out_path {
    Some(out_path) =>
      match artifact_pkg_path(out_path) {
        Some(pkg_path) =>
          match self.artifact_to_dir.get(pkg_path) {
            Some(existing) =>
              if existing != Some(owner_dir) {
                self.artifact_to_dir[pkg_path] = None
              }
            None => self.artifact_to_dir[pkg_path] = Some(owner_dir)
          }
        None => ()
      }
    None => ()
  }
}

///|
/// Map an `-i <path>:<alias>` import to a local source dir. The alias is
/// the import name, not the package identity, so only the .mi path is used.
fn PlanBuilder::dep_dir_of_import(
  self : PlanBuilder,
  entry : String,
) -> String? {
  let mi_path = match entry.rev_find(":") {
    Some(colon) => entry[:colon].to_owned()
    None => entry
  }
  match artifact_pkg_path(mi_path) {
    Some(pkg_path) =>
      match self.artifact_to_dir.get(pkg_path) {
        Some(Some(dir)) => Some(dir)
        _ => None
      }
    None => None
  }
}

///|
fn PlanBuilder::record_line(self : PlanBuilder, line : String) -> Unit {
  if !line.has_prefix("moonc build-package") {
    return
  }
  let args = split_args(line)
  self.build_package_lines = self.build_package_lines + 1
  // Positional source paths lead the argv: `moonc build-package
  // ./foo.mbt ./bar.mbt -o ...`. The first `-`-prefixed argument ends
  // the source list, which keeps flag *values* (e.g. the file after
  // `-doctest-only`) from being mistaken for positional inputs.
  let mut positional = 2
  while positional < args.length() && !args[positional].has_prefix("-") {
    if args[positional].has_suffix(".mbt") {
      self.raw_sources.push(args[positional])
    }
    positional = positional + 1
  }
  let mut pkg : String? = None
  let mut output : String? = None
  let mut test_mode = false
  let imports : Array[String] = []
  let mut i = 1
  while i < args.length() {
    match args[i] {
      "-pkg" | "--pkg" => {
        if i + 1 < args.length() {
          pkg = Some(args[i + 1])
        }
        i = i + 2
      }
      "-o" => {
        if i + 1 < args.length() {
          output = Some(args[i + 1])
        }
        i = i + 2
      }
      "-i" => {
        if i + 1 < args.length() {
          imports.push(args[i + 1])
        }
        i = i + 2
      }
      "-test-mode" => {
        test_mode = true
        i = i + 1
      }
      _ => i = i + 1
    }
  }
  self.record_pkg_sources(args)
  guard pkg is Some(pkg_fqn) else { return }
  guard self.fqn_to_dir.get(pkg_fqn) is Some(owner_dir) else { return }
  self.record_artifact_mapping(output, owner_dir)
  // Imports are resolved in pass two: an artifact's owner may only appear
  // on a later build-package line.
  self.pending.push({ owner: owner_dir, test_mode, imports, })
}

///|
/// Pass two: map every queued `-i` import to a local source dir now that
/// all artifact mappings are known. Artifacts outside `_build` are
/// external deps — they can never observe a module-local mutant, so an
/// unmappable external import is safely dropped. An unmappable `_build`
/// import means a local edge was lost: the plan is invalidated rather
/// than silently narrowed.
fn PlanBuilder::resolve_imports(self : PlanBuilder) -> Bool {
  for pending in self.pending {
    let table = if pending.test_mode {
      self.test_deps
    } else {
      self.source_deps
    }
    let deps = match table.get(pending.owner) {
      Some(existing) => existing
      None => {
        let created : Map[String, Bool] = Map([])
        table[pending.owner] = created
        created
      }
    }
    for entry in pending.imports {
      match self.dep_dir_of_import(entry) {
        Some(dir) => deps[dir] = true
        None => {
          let mi_path = match entry.rev_find(":") {
            Some(colon) => entry[:colon].to_owned()
            None => entry
          }
          if artifact_pkg_path(mi_path) is Some(_) {
            return false
          }
        }
      }
    }
  }
  true
}

///|
/// Transitive closure over the module-local package graph.
fn reach_from(
  graph : Map[String, Map[String, Bool]],
  seeds : Map[String, Bool],
) -> Map[String, Bool] {
  let seen : Map[String, Bool] = Map([])
  let stack : Array[String] = []
  for dir, _ in seeds {
    stack.push(dir)
  }
  while stack.length() > 0 {
    let dir = match stack.pop() {
      Some(dir) => dir
      None => break
    }
    if seen.contains(dir) {
      continue
    }
    seen[dir] = true
    match graph.get(dir) {
      Some(deps) =>
        for dep, _ in deps {
          if !seen.contains(dep) {
            stack.push(dep)
          }
        }
      None => ()
    }
  }
  seen
}

///|
/// None means at least one module-local import could not be resolved —
/// the honest answer is the module-wide test run, not a partial plan.
/// A plan with no known packages is useless for `--affected` too, so it
/// lands in the same fallback.
fn PlanBuilder::build(self : PlanBuilder) -> TestPlan? {
  guard self.resolve_imports() else { return None }
  guard self.dir_to_fqn.length() > 0 else { return None }
  let observables : Map[String, Map[String, Bool]] = Map([])
  for dir, _ in self.dir_to_fqn {
    let seeds : Map[String, Bool] = Map([])
    seeds[dir] = true
    match self.test_deps.get(dir) {
      Some(deps) =>
        for dep, _ in deps {
          seeds[dep] = true
        }
      None => ()
    }
    observables[dir] = reach_from(self.source_deps, seeds)
  }
  Some({ dir_to_fqn: self.dir_to_fqn, observables, })
}

///|
/// Package dir owning a mutated file: the longest package dir prefix.
/// Returns None when the file sits outside every known package — callers
/// then fall back to a module-wide test run.
fn TestPlan::package_dir_of(self : TestPlan, path : String) -> String? {
  let mut best : String? = None
  for dir, _ in self.dir_to_fqn {
    let matches = if dir == "." { true } else { path.has_prefix(dir + "/") }
    if matches {
      match best {
        Some(current) => if dir.length() > current.length() { best = Some(dir) }
        None => best = Some(dir)
      }
    }
  }
  best
}

///|
/// The packages whose tests can observe a mutation: the mutated package's
/// own tests plus every package whose test targets transitively link it.
/// Sorted for deterministic output. None means "run the module-wide test"
/// — the only honest answer when the mutation cannot be placed.
fn TestPlan::test_packages_for(
  self : TestPlan,
  mutation : Mutation,
) -> Array[String]? {
  guard self.package_dir_of(mutation.path) is Some(pkg_dir) else { return None }
  let selected : Map[String, Bool] = Map([])
  for owner, observable in self.observables {
    if observable.contains(pkg_dir) {
      selected[owner] = true
    }
  }
  selected[pkg_dir] = true
  let fqns : Array[String] = []
  for dir, _ in selected {
    match self.dir_to_fqn.get(dir) {
      Some(fqn) => fqns.push(fqn)
      None => return None
    }
  }
  fqns.sort()
  Some(fqns)
}

///|
/// What one `moon test --dry-run` proves, split by consumer.
///
/// `active_sources` is the set of module-relative source paths Moon
/// selected for the requested backend — the authoritative answer to
/// "would this file be compiled?", already reflecting `supported_targets`,
/// file-level `targets`, `preferred_target`, and the package graph. For
/// `--target all` it is the union over every emitted backend plan.
///
/// `test_plan` is the dependency graph `--affected` narrows test runs
/// with; `None` keeps the module-wide fallback when resolution fails.
struct MoonPlan {
  active_sources : Map[String, Bool]
  test_plan : TestPlan?
}

///|
/// Reduce one dry-run source path to module-relative form, or None when
/// it is outside the module tree: generated `_build` output, vendored
/// `.mooncakes` dependencies, `$MOON_HOME` core packages, or anything
/// resolving above the module root.
fn normalize_plan_source(root : String, raw : String) -> String? {
  let path = raw.replace_all(old="\\", new="/")
  if path.has_prefix("$") || !path.has_suffix(".mbt") {
    return None
  }
  let rel = if path.has_prefix("/") ||
    (path.length() > 2 && path.find(":/") == Some(1)) {
    // Absolute paths resolve against the module root; escaping it drops out.
    @path.Path(path)
    .relative(base=@path.Path(root))
    .to_string()
    .replace_all(old="\\", new="/")
  } else {
    path
  }
  let mut cleaned = rel.replace_all(old="\\", new="/")
  while cleaned.has_prefix("./") {
    cleaned = cleaned[2:].to_owned()
  }
  if cleaned == "" || cleaned.has_prefix("..") {
    return None
  }
  let first = match cleaned.find("/") {
    Some(slash) => cleaned[:slash].to_owned()
    None => cleaned
  }
  if should_skip_dir(first) {
    return None
  }
  Some(cleaned)
}

///|
/// The normalized module-relative source set observed across every
/// build-package line — a union, so `--target all` keeps sources active
/// on any emitted backend plan.
fn PlanBuilder::active_sources(
  self : PlanBuilder,
  root : String,
) -> Map[String, Bool] {
  let sources : Map[String, Bool] = Map([])
  for raw in self.raw_sources {
    match normalize_plan_source(root, raw) {
      Some(relative) => sources[relative] = true
      None => ()
    }
  }
  sources
}

///|
/// Capture the build plan without running it: `moon test --dry-run` prints
/// every command moon would execute. Runs once on the pristine reference
/// workspace before workers start mutating anything. The same commands
/// feed active-source discovery and the `--affected` dependency graph, so
/// a target-aware plan can never disagree with itself.
async fn load_moon_plan(
  reference : String,
  target? : String? = None,
) -> MoonPlan {
  let log = reference + "-plan.log"
  let output = @process.redirect_to_file(log)
  let code = @process.run(
    "moon",
    moon_args(["test", "--dry-run"], target),
    cwd=reference,
    stdout=output,
    stderr=output,
  )
  guard code == 0 else { fail("moon test --dry-run exited \{code}") }
  let text = @fs.read_file(log).text()
  let builder = PlanBuilder::new()
  for line in text.split("\n") {
    builder.record_line(line.to_owned())
  }
  // No build-package lines means the plan's shape was not understood at
  // all — indeterminate rather than an empty active-source set.
  guard builder.build_package_lines > 0 else {
    fail("moon test --dry-run emitted no build-package commands")
  }
  {
    active_sources: builder.active_sources(reference),
    test_plan: builder.build(),
  }
}

///|
/// Split discovered mutants by whether Moon compiles their file for the
/// selected target. `reuse` arrives index-aligned with `mutations`; the
/// returned array is index-aligned with the active subsequence so an
/// iterate verdict always travels with its own mutant. Order is preserved.
fn partition_by_active_source(
  mutations : Array[Mutation],
  reuse : Array[MutationResult?],
  active_sources : Map[String, Bool],
) -> (Array[Mutation], Array[MutationResult?], Array[Mutation]) {
  let active : Array[Mutation] = []
  let active_reuse : Array[MutationResult?] = []
  let inactive : Array[Mutation] = []
  for i, mutation in mutations {
    if active_sources.contains(mutation.path) {
      active.push(mutation)
      active_reuse.push(if i < reuse.length() { reuse[i] } else { None })
    } else {
      inactive.push(mutation)
    }
  }
  (active, active_reuse, inactive)
}
