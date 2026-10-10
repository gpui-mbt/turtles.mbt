///|
/// Property amplification (`--pbt-amplify <N>`): for each surviving
/// mutant, re-run the package's tests in a throwaway workspace with every
/// QuickCheck `check`-family call rewritten to a bigger `count` and a
/// different `seed`. A mutant killed only under the amplified budget ends
/// `KILLED` with `amplified: true` — real `moon test` evidence, never a
/// compile-time shortcut: when the rewrite leaves the module broken
/// (`moon check` fails) the survivor stays `Survived`.

///|
/// Seed written when the property leaves `seed` unset, and the offset
/// applied when it is already explicit — deliberately different from the
/// default seed (37) and from small literals, so amplification actually
/// explores new samples.
let amplify_seed : UInt64 = 11400714819323198485UL

///|
/// Rewrite only qualified calls whose visible import resolves exactly
/// to core QuickCheck. Bare names may be local or shadowed; leave them
/// unchanged rather than infer identity from an unrelated import.
fn is_check_callee(
  func : @syntax.Expr,
  pkg_imports : Map[String, String],
) -> Bool {
  match callee_head(func) {
    @syntax.Expr::Ident(id~, ..) =>
      match id.name {
        @syntax.LongIdent::Dot(pkg~, id~) =>
          (
            id == "check" ||
            id == "report" ||
            id.has_prefix("quick_check") ||
            id.has_prefix("quickcheck")
          ) &&
          pkg_imports.get(pkg) == Some("moonbitlang/core/quickcheck")
        _ => false
      }
    _ => false
  }
}

///|
/// Edits (byte spans + replacement text) for one file: `count`/`max_success`
/// args get `(<old> * N)`; a missing count gains `, count = 100*N`; the
/// seed similarly gains/offsets the alternate seed. Positions are applied
/// right-to-left so earlier offsets stay valid.
struct AmplifyEdits {
  mut changed : Bool
  edits : Array[(Int, Int, String)]
}

///|
fn AmplifyEdits::new() -> AmplifyEdits {
  { changed: false, edits: [], }
}

///|
fn AmplifyEdits::push(
  self : AmplifyEdits,
  start : Int,
  end : Int,
  text : String,
) -> Unit {
  self.edits.push((start, end, text))
  self.changed = true
}

///|
fn argument_label(arg : @syntax.Argument) -> String? {
  match arg.kind {
    @syntax.ArgumentKind::Labelled(label)
    | @syntax.ArgumentKind::LabelledPun(label)
    | @syntax.ArgumentKind::LabelledOption(label~, ..)
    | @syntax.ArgumentKind::LabelledOptionPun(label~, ..) => Some(label.name)
    _ => None
  }
}

///|
/// Visitor collecting the rewrites for one file.
struct AmplifyVisitor {
  bytes : Bytes
  boundaries : Array[Int]
  pkg_imports : Map[String, String]
  factor : Int
  edits : AmplifyEdits
}

///|
impl @syntax.IterVisitor for AmplifyVisitor with fn visit_Expr_Apply(
  self,
  func~,
  args~,
  loc~,
) {
  if is_check_callee(func, self.pkg_imports) {
    let mut count_at : (Int, Int)? = None
    let mut seed_at : (Int, Int)? = None
    for arg in args {
      match argument_label(arg) {
        Some("count") | Some("max_success") =>
          if count_at is None {
            count_at = Some(loc_bytes(self.boundaries, arg.value.loc()))
          }
        Some("seed") =>
          if seed_at is None {
            seed_at = Some(loc_bytes(self.boundaries, arg.value.loc()))
          }
        _ => ()
      }
    }
    let inserts : Array[String] = []
    match count_at {
      Some((start, end)) =>
        self.edits.push(
          start,
          end,
          "(\{@utf8.decode_lossy(self.bytes[start:end])} * \{self.factor})",
        )
      None => inserts.push("count = \{100 * self.factor}")
    }
    match seed_at {
      Some((start, end)) =>
        self.edits.push(
          start,
          end,
          "(\{@utf8.decode_lossy(self.bytes[start:end])} + \{amplify_seed})",
        )
      None => inserts.push("seed = \{amplify_seed}")
    }
    if !inserts.is_empty() {
      // Insert just before the Apply's closing ')'. A trailing comma in
      // the arg list (common in multiline calls) already supplies the
      // separator — splicing a second one would produce `,,` and break
      // `moon check`, silently sparing the mutant.
      let (_, apply_end) = loc_bytes(self.boundaries, loc)
      let extra_args = inserts.join(", ")
      let bytes = self.bytes
      let mut prev = apply_end - 2
      while prev >= 0 && bytes[prev] is (b' ' | b'\n' | b'\t' | b'\r') {
        prev = prev - 1
      }
      let text = if prev >= 0 && bytes[prev] == b',' {
        " \{extra_args}"
      } else {
        ", \{extra_args}"
      }
      self.edits.push(apply_end - 1, apply_end - 1, text)
    }
  }
  @syntax.IterVisitor::visit_Expr_Apply(
    @syntax.IterVisitor::base(self),
    func~,
    args~,
    loc~,
  )
}

///|
/// Every `.mbt` file under `dir` — test files included, since the
/// properties live there. Mirrors `collect_moonbit_files` minus the
/// test-source exclusion.
async fn collect_all_moonbit_files(
  root : String,
  dir : String,
  output : Array[String],
) -> Unit {
  for name in @fs.readdir(dir, include_hidden=true, sort=true) {
    let full = path_join(dir, name)
    let kind = @fs.kind(full) catch { _ => continue }
    if kind is Directory {
      if !should_skip_dir(name) && !is_nested_module(full) {
        collect_all_moonbit_files(root, full, output)
      }
      continue
    }
    if !(kind is Regular) || !name.has_suffix(".mbt") {
      continue
    }
    output.push(relative_path(root, full))
  }
}

///|
/// Owning package dir of a file under the index — the deepest manifest
/// dir containing it (also covers test files, which carry no fns).
fn pkg_dir_of_file(index : ModuleIndex, file : String) -> String {
  pkg_dir_of(index.pkg_dirs, file)
}

///|
/// Rewrite every QuickCheck call in one source file; returns the new
/// content, or None when nothing applied (also None on parse failure —
/// an unparseable file can only lose the survivor, never gain a kill).
fn amplify_rewrite_file(
  source : String,
  file : String,
  index : ModuleIndex,
  factor : Int,
) -> String? {
  let (impls, reports) = @parser.parse_string(source, name=file)
  if reports.length() != 0 {
    return None
  }
  let bytes = @utf8.encode(source)
  let boundaries = source_byte_boundaries(bytes)
  let dir = pkg_dir_of_file(index, file)
  let pkg_imports = match index.pkgs.get(dir) {
    Some(pkg) =>
      if file.has_suffix("_wbtest.mbt") {
        pkg.wbtest_imports
      } else if file.has_suffix("_test.mbt") {
        pkg.test_imports
      } else {
        pkg.imports
      }
    None => Map([])
  }
  let visitor : AmplifyVisitor = {
    bytes,
    boundaries,
    pkg_imports,
    factor,
    edits: AmplifyEdits::new(),
  }
  for impl_ in impls {
    @syntax.IterVisitor::visit_Impl(visitor, impl_)
  }
  if !visitor.edits.changed {
    return None
  }
  // Apply left-to-right: sort by start ascending and reject any overlap.
  let edits = visitor.edits.edits
  edits.sort_by((a, b) => a.0 - b.0)
  let buf = @buffer.Buffer(size_hint=bytes.length() + 256)
  let mut cursor = 0
  for (start, end, text) in edits {
    if start < cursor || start > end || end > bytes.length() {
      return None
    }
    buf.write_bytes(bytes[cursor:start])
    buf.write_string_utf8(text)
    cursor = end
  }
  buf.write_bytes(bytes[cursor:])
  Some(@utf8.decode_lossy(buf.to_bytes()))
}

///|
/// The amplification phase on initial survivors: per survivor, apply the
/// mutation to the shared `analysis` workspace, rewrite every QuickCheck
/// call across all module sources, `moon check`, then `moon test` the
/// mutant's packages. `amplified: true` marks kills that only happen
/// under the amplified budget.
async fn run_pbt_amplify(
  workspace : String,
  reference : String,
  results : Array[MutationResult],
  index : ModuleIndex,
  factor : Int,
  check_timeout_ms : Int,
  test_timeout_ms : Int,
  timeout_command : String?,
  target? : String? = None,
) -> Unit {
  let manifest = Ref(snapshot_workspace(workspace))
  for i, result in results {
    if !(result.outcome is Survived) {
      continue
    }
    // First amplify the pristine tree using exactly this mutant's test
    // selection. An original failure cannot establish a mutation kill.
    rewrite_amplified_workspace(workspace, index, factor)
    let control_ok = match
      run_moon_command(
        workspace,
        ["check"],
        check_timeout_ms,
        timeout_command,
        target~,
      ) {
      CommandSuccess =>
        run_moon_command(
          workspace,
          mutant_test_args(result.packages),
          test_timeout_ms * factor,
          timeout_command,
          target~,
        )
        is CommandSuccess
      _ => false
    }
    sweep_workspace(workspace, reference, manifest.val) catch {
      _ => manifest.val = rebuild_workspace(workspace, reference)
    }
    if !control_ok {
      println(
        "warning: amplification skipped for \{mutation_id(result.mutation)}: amplified original check/test failed or timed out",
      )
      continue
    }
    let mutation = result.mutation
    let target_file = path_join(workspace, mutation.path)
    let source = @fs.read_file(target_file).text() catch { _ => continue }
    let mutated = apply_mutation(source, mutation) catch { _ => continue }
    @fs.write_file(target_file, mutated) catch {
      _ => continue
    }
    rewrite_amplified_workspace(workspace, index, factor)
    let killed = match
      run_moon_command(
        workspace,
        ["check"],
        check_timeout_ms,
        timeout_command,
        target~,
      ) {
      CommandSuccess =>
        run_moon_command(
          workspace,
          mutant_test_args(result.packages),
          test_timeout_ms * factor,
          timeout_command,
          target~,
        )
        is CommandFailure
      _ => false
    }
    if killed {
      results[i] = {
        ..result,
        outcome: Killed,
        amplified: Some(true),
        kills: last_test_failures(workspace) catch {
          _ => None
        },
      }
    }
    sweep_workspace(workspace, reference, manifest.val) catch {
      _ => manifest.val = rebuild_workspace(workspace, reference)
    }
  }
}

///|
async fn rewrite_amplified_workspace(
  workspace : String,
  index : ModuleIndex,
  factor : Int,
) -> Unit {
  let files : Array[String] = []
  collect_all_moonbit_files(workspace, workspace, files)
  for file in files {
    let abs = path_join(workspace, file)
    let text = @fs.read_file(abs).text()
    match amplify_rewrite_file(text, file, index, factor) {
      Some(rewritten) => @fs.write_file(abs, rewritten)
      None => ()
    }
  }
}
