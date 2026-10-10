///|
fn path_join(left : String, right : String) -> String {
  @path.Path(left).join(@path.Path(right)).to_string()
}

///|
#cfg(platform="windows")
fn relative_path(root : String, path : String) -> String {
  @path.Path(path)
  .relative(base=@path.Path(root))
  .to_string()
  .replace_all(old="\\", new="/")
}

///|
#cfg(not(platform="windows"))
fn relative_path(root : String, path : String) -> String {
  @path.Path(path).relative(base=@path.Path(root)).to_string()
}

///|
fn should_skip_dir(name : String) -> Bool {
  name == ".git" ||
  name == "target" ||
  name == "_build" ||
  name == ".mooncakes" ||
  name == ".moon" ||
  name == ".turtles" ||
  name == "node_modules"
}

///|
/// Directories moon owns and regenerates on demand — kept warm across
/// mutants rather than swept. `.mooncakes` is moon's vendored dep cache:
/// never copied in, but `moon check` re-vendors it inside every workspace
/// (~1.3 s), so sweeping it would pay a re-vendor for every mutant.
/// `.git`/`.moon`/`target`/`node_modules`/`.turtles` are NOT moon-managed
/// — a test creating them must not leak state into the next mutant.
/// Matched on the root-relative path: moon's caches live at the workspace
/// root, and a same-named directory any deeper is test-created state.
fn moon_owned_path(relative : String) -> Bool {
  relative == "_build" || relative == ".mooncakes"
}

///|
fn is_test_source(name : String) -> Bool {
  name.has_suffix("_test.mbt") || name.has_suffix("_wbtest.mbt")
}

///|
async fn ensure_moonbit_module(root : String) -> Unit {
  let old_manifest = path_join(root, "moon.mod")
  let json_manifest = path_join(root, "moon.mod.json")
  guard @fs.exists(old_manifest) || @fs.exists(json_manifest) else {
    fail("\{root} is not a MoonBit module (moon.mod not found)")
  }
}

///|
/// A child directory carrying its own module manifest is a separate MoonBit
/// module: the root module's `moon test` never reaches its code, so mutating
/// it would produce false survivors. The root itself is never checked — the
/// caller already validated it as a module.
async fn is_nested_module(dir : String) -> Bool {
  @fs.exists(path_join(dir, "moon.mod")) ||
  @fs.exists(path_join(dir, "moon.mod.json"))
}

///|

///|
/// Files that make classification reproducible: every `.mbt` source
/// (test or not), package/module manifests, and `turtles.toml`. Nested
/// modules stay out — the root module's `moon test` never builds them.
fn is_fingerprint_file(name : String) -> Bool {
  name.has_suffix(".mbt") ||
  name == "moon.pkg" ||
  name == "moon.pkg.json" ||
  name == "moon.mod" ||
  name == "moon.mod.json" ||
  name == "moon.work" ||
  name == "moon.work.json" ||
  name == "turtles.toml"
}

///|
async fn collect_fingerprint_files(
  root : String,
  dir : String,
  output : Array[String],
) -> Unit {
  let names = @fs.readdir(dir, include_hidden=true, sort=true)
  for name in names {
    let full = path_join(dir, name)
    let kind = @fs.kind(full)
    if kind is Directory {
      if !should_skip_dir(name) && !is_nested_module(full) {
        collect_fingerprint_files(root, full, output)
      }
      continue
    }
    if kind is Regular && is_fingerprint_file(name) {
      output.push(relative_path(root, full))
    }
  }
}

///|
async fn collect_moonbit_files(
  root : String,
  dir : String,
  file_filter : String?,
  project_config : ProjectConfig,
  output : Array[String],
) -> Unit {
  let names = @fs.readdir(dir, include_hidden=true, sort=true)
  for name in names {
    let full = path_join(dir, name)
    let kind = @fs.kind(full)
    if kind is Directory {
      if !should_skip_dir(name) && !is_nested_module(full) {
        collect_moonbit_files(root, full, file_filter, project_config, output)
      }
      continue
    }
    if !(kind is Regular) || !name.has_suffix(".mbt") || is_test_source(name) {
      continue
    }
    let relative = relative_path(root, full)
    if !project_config.path_enabled(relative) {
      continue
    }
    match file_filter {
      Some(filter) if !relative.contains(filter) => continue
      _ => ()
    }
    output.push(relative)
  }
}

///|
async fn discover_mutations(
  root : String,
  file_filter : String?,
  project_config : ProjectConfig,
  skipped : Array[SkippedFile],
  skipped_blocks : Array[SkippedBlock],
) -> Array[Mutation] {
  let files : Array[String] = []
  collect_moonbit_files(root, root, file_filter, project_config, files)
  let mutations : Array[Mutation] = []
  for relative in files {
    let source = @fs.read_file(path_join(root, relative)).text()
    let found = scan_source(relative, source, project_config, skipped_blocks~) catch {
      error => {
        skipped.push({ path: relative, error: error.to_string(), })
        continue
      }
    }
    for mutation in found {
      mutations.push(mutation)
    }
  }
  mutations
}

///|
/// The fs API exposes effective access but not raw mode bits, so copies keep
/// the caller's read/write/execute rights — the only user a private temporary
/// workspace serves. A read-only file stays unwritable and a private file
/// stays private.
#cfg(not(platform="windows"))
async fn observed_permission(path : String) -> Int {
  let read = @fs.can_read(path) catch { _ => false }
  let write = @fs.can_write(path) catch { _ => false }
  let execute = @fs.can_execute(path) catch { _ => false }
  let mut permission = 0
  if read {
    permission = permission + 0o400
  }
  if write {
    permission = permission + 0o200
  }
  if execute {
    permission = permission + 0o100
  }
  permission
}

///|
#cfg(platform="windows")
fn observed_permission(_path : String) -> Int {
  // NTFS access is controlled by ACLs, not POSIX mode bits. Treat modes as
  // unchanged and let the temporary workspace inherit its parent ACL.
  0
}

///|
#cfg(not(platform="windows"))
async fn set_permission(path : String, permission : Int) -> Unit {
  @fs.chmod(path, permission)
}

///|
#cfg(platform="windows")
fn set_permission(_path : String, _permission : Int) -> Unit {
  // @fs.chmod is not supported by the Windows filesystem adapter.
  ()
}

///|
#cfg(not(platform="windows"))
async fn try_set_permission(path : String, permission : Int) -> Bool {
  @fs.chmod(path, permission) catch {
    _ => return false
  }
  true
}

///|
#cfg(platform="windows")
fn try_set_permission(_path : String, _permission : Int) -> Bool {
  true
}

///|
/// Regular files keep their permission bits: the temporary workspace must
/// behave like the original module for baseline parity.
#cfg(not(platform="windows"))
async fn copy_regular_file(source : String, target : String) -> Unit {
  let data = @fs.read_file(source)
  let permission = observed_permission(source)
  @fs.write_file(target, data, permission~)
}

///|
#cfg(platform="windows")
async fn copy_regular_file(source : String, target : String) -> Unit {
  let data = @fs.read_file(source)
  @fs.write_file(target, data)
}

///|
/// Copy a link's resolved target as plain content: used for links that escape
/// the module root and on platforms where creating a symlink is not allowed.
async fn dereference_copy(
  source : String,
  resolved : String,
  target : String,
  relative : String,
) -> Unit {
  let kind = @fs.kind(source)
  if kind is Regular {
    copy_regular_file(source, target)
  } else if kind is Directory {
    @fs.mkdir(target, recursive=true, allow_exist=true)
    copy_tree(resolved, resolved, target)
    // Restore observed permissions only after contents are in place: a
    // non-writable source directory must still accept its own copies.
    set_permission(target, observed_permission(source))
  } else {
    fail("cannot preserve symbolic link \{relative}: unsupported target kind")
  }
}

///|
/// Recreate a symlink inside the workspace. A link that resolves within the
/// module root is re-pointed at the workspace copy; a link that resolves
/// outside the module root is dereference-copied so test runs cannot modify
/// files outside the workspace through it. Where symlink creation is not
/// permitted (e.g. Windows without the required privilege), the resolved
/// content is copied instead.
async fn copy_symlink(
  root : String,
  source : String,
  destination : String,
) -> Unit {
  let relative = relative_path(root, source)
  let target = path_join(destination, relative)
  let parent = @path.Path(target).dirname().to_string()
  @fs.mkdir(parent, recursive=true, allow_exist=true)
  let resolved = @fs.realpath(source) catch {
    _ =>
      fail("cannot preserve symbolic link \{relative}: target does not resolve")
  }
  let module_root = @fs.realpath(root)
  let resolved_relative = @path.Path(resolved)
    .relative(base=@path.Path(module_root))
    .to_string()
  if resolved_relative.has_prefix("..") {
    dereference_copy(source, resolved, target, relative)
  } else {
    @fs.symlink(target, target=path_join(destination, resolved_relative)) catch {
      _ => dereference_copy(source, resolved, target, relative)
    }
  }
}

///|
/// Entries inside a read-only directory cannot be unlinked until the
/// directory becomes writable, so recursive removal loosens directory
/// permissions first. Files need no chmod: unlinking them only requires a
/// writable parent.
async fn make_writable_tree(dir : String) -> Unit {
  if !try_set_permission(dir, 0o700) {
    return
  }
  let names = @fs.readdir(dir, include_hidden=true, sort=true) catch {
    _ => return
  }
  for name in names {
    let child = path_join(dir, name)
    if @fs.kind(child, follow_symlink=false) is Directory {
      make_writable_tree(child)
    }
  }
}

///|
async fn force_rmdir(path : String) -> Unit {
  make_writable_tree(path)
  @fs.rmdir(path, recursive=true)
}

///|
/// A manifest's view of one regular file: content fingerprint plus the
/// observed permission — a mode-only change is still a dirty file.
struct ManifestFile {
  hash : String
  perm : Int
}

///|
/// Snapshot of a freshly copied workspace: every regular file's fingerprint
/// and permission, plus the directory and symlink sets. The post-mutant
/// sweep uses it to prove inter-mutant isolation inside a persistent
/// workspace.
struct WorkspaceManifest {
  files : Map[String, ManifestFile]
  /// relative dir path -> observed permission (a mode-only chmod is a
  /// dirty dir, restored after contents just like copy_tree does)
  dirs : Map[String, Int]
  links : Map[String, Bool]
}

///|
async fn snapshot_manifest(
  root : String,
  dir : String,
  manifest : WorkspaceManifest,
) -> Unit {
  let names = @fs.readdir(dir, include_hidden=true, sort=true)
  for name in names {
    let full = path_join(dir, name)
    let kind = @fs.kind(full, follow_symlink=false)
    let relative = relative_path(root, full)
    if kind is Directory {
      if should_skip_dir(name) {
        continue
      }
      manifest.dirs[relative] = observed_permission(full)
      snapshot_manifest(root, full, manifest)
    } else if kind is Regular {
      manifest.files[relative] = {
        hash: fingerprint_hex(fnv1a(@fs.read_file(full).binary())),
        perm: observed_permission(full),
      }
    } else if kind is SymLink {
      manifest.links[relative] = true
    }
  }
}

///|
async fn snapshot_workspace(root : String) -> WorkspaceManifest {
  let manifest = { files: Map([]), dirs: Map([]), links: Map([]), }
  manifest.dirs["."] = observed_permission(root)
  snapshot_manifest(root, root, manifest)
  manifest
}

///|
/// Return a reused workspace to its snapshot state: delete anything the
/// snapshot did not contain (test-run side effects, generated files) and
/// restore any snapshot file whose bytes changed or vanished. The mutated
/// source file is restored by this same pass, so no separate restore step
/// can drift out of sync with the manifest.
async fn sweep_workspace(
  root : String,
  reference : String,
  manifest : WorkspaceManifest,
) -> Unit {
  // A test may have made the workspace root itself non-traversable;
  // without this chmod the sweep below cannot even list it.
  try_set_permission(root, 0o700) |> ignore
  sweep_dir(root, root, reference, manifest)
  // Restore anything missing or changed. Strays are already gone.
  for entry in manifest.files {
    let relative = entry.0
    let current = path_join(root, relative)
    let dirty = if @fs.exists(current) {
      !(@fs.kind(current, follow_symlink=false) is Regular) ||
      observed_permission(current) != entry.1.perm ||
      fingerprint_hex(fnv1a(@fs.read_file(current).binary())) != entry.1.hash
    } else {
      true
    }
    if dirty {
      let kind = @fs.kind(current, follow_symlink=false) catch { _ => Unknown }
      if kind is Directory {
        force_rmdir(current) catch {
          _ => ()
        }
      } else {
        // chmod only real files: on a symlink it would follow through
        // and touch the link target, which may live outside the module.
        if kind is Regular {
          try_set_permission(current, 0o600) |> ignore
        }
        @fs.remove(current) catch {
          _ => ()
        }
      }
      let parent = @path.Path(current).dirname().to_string()
      @fs.mkdir(parent, recursive=true, allow_exist=true)
      copy_regular_file(path_join(reference, relative), current)
    }
  }
  // Recreate every manifest link from the reference: existence proves
  // nothing about the target, and a retargeted link leaks state too.
  for entry in manifest.links {
    let relative = entry.0
    let current = path_join(root, relative)
    let kind = @fs.kind(current, follow_symlink=false) catch { _ => Unknown }
    if kind is Directory {
      force_rmdir(current) catch {
        _ => ()
      }
    } else if @fs.exists(current) || kind is SymLink {
      @fs.remove(current) catch {
        _ => ()
      }
    }
    let parent = @path.Path(current).dirname().to_string()
    @fs.mkdir(parent, recursive=true, allow_exist=true)
    copy_symlink(reference, path_join(reference, relative), root)
  }
  // Restore recorded directory permissions deepest-first — mirroring
  // copy_tree's post-order restore, and required because a parent made
  // non-traversable would hide its children from later chmods. Missing
  // manifest dirs (deleted wholesale) are recreated first.
  let dir_list : Array[String] = []
  for entry in manifest.dirs {
    dir_list.push(entry.0)
  }
  dir_list.sort()
  for i = dir_list.length() - 1; i >= 0; i = i - 1 {
    let relative = dir_list[i]
    let current = path_join(root, relative)
    if !@fs.exists(current) {
      @fs.mkdir(current, recursive=true)
    }
    match manifest.dirs.get(relative) {
      Some(perm) => set_permission(current, perm)
      None => ()
    }
  }
}

///|
async fn sweep_dir(
  root : String,
  dir : String,
  reference : String,
  manifest : WorkspaceManifest,
) -> Unit {
  let names = @fs.readdir(dir, include_hidden=true, sort=true) catch {
    _ => return
  }
  for name in names {
    let full = path_join(dir, name)
    let kind = @fs.kind(full, follow_symlink=false)
    let relative = relative_path(root, full)
    if kind is Directory {
      if moon_owned_path(relative) {
        continue
      }
      if manifest.dirs.contains(relative) {
        // A test may have made this dir non-traversable; loosen it so the
        // sweep can list and clean inside. The recorded mode is restored
        // afterwards by sweep_workspace's permission pass.
        try_set_permission(full, 0o700) |> ignore
        sweep_dir(root, full, reference, manifest)
      } else {
        force_rmdir(full)
      }
    } else if kind is Regular {
      if !manifest.files.contains(relative) {
        @fs.remove(full)
      }
    } else if kind is SymLink {
      if !manifest.links.contains(relative) {
        @fs.remove(full)
      }
    }
  }
}

///|
/// Rebuild a persistent workspace after an unrecoverable divergence
/// (e.g. a failed mutation apply). Returns a fresh manifest.
async fn rebuild_workspace(
  workspace : String,
  reference : String,
) -> WorkspaceManifest {
  force_rmdir(workspace) catch {
    _ => ()
  }
  @fs.mkdir(workspace, recursive=true)
  copy_tree(reference, reference, workspace)
  snapshot_workspace(workspace)
}

///|
async fn copy_tree(
  root : String,
  current : String,
  destination : String,
) -> Unit {
  let names = @fs.readdir(current, include_hidden=true, sort=true)
  for name in names {
    let source = path_join(current, name)
    let kind = @fs.kind(source, follow_symlink=false)
    if kind is Directory {
      if should_skip_dir(name) {
        continue
      }
      let relative = relative_path(root, source)
      let target = path_join(destination, relative)
      let observed = observed_permission(source)
      @fs.mkdir(target, recursive=true, allow_exist=true)
      copy_tree(root, source, destination)
      // Restore observed permissions only after contents are in place: a
      // non-writable source directory must still accept its own copies.
      set_permission(target, observed)
    } else if kind is Regular {
      let relative = relative_path(root, source)
      let target = path_join(destination, relative)
      let parent = @path.Path(target).dirname().to_string()
      @fs.mkdir(parent, recursive=true, allow_exist=true)
      copy_regular_file(source, target)
    } else if kind is SymLink {
      copy_symlink(root, source, destination)
    }
    // Other kinds (sockets, fifos, devices) are skipped: they cannot be
    // reproduced inside a temporary workspace.
  }
}
