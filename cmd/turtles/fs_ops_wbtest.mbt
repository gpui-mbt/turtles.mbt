///|
test "build and VCS directories are skipped" {
  for
    name in [
      ".git", "target", "_build", ".mooncakes", ".moon", ".turtles", "node_modules",
    ] {
    assert_true(should_skip_dir(name))
  }
  for name in ["src", ".github", "targeted", "build", ".moonx"] {
    assert_false(should_skip_dir(name))
  }
}

///|
test "test sources are excluded" {
  for name in ["foo_test.mbt", "foo_wbtest.mbt"] {
    assert_true(is_test_source(name))
  }
  for name in ["foo.mbt", "test.mbt", "foo_test.mbt.bak", "foo.test.mbt"] {
    assert_false(is_test_source(name))
  }
}

///|
async test "ensure_moonbit_module requires a manifest" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let missing = path_join(temp, "missing")
    @fs.mkdir(missing, recursive=true)
    let mut raised = false
    ensure_moonbit_module(missing) catch {
      _ => raised = true
    }
    assert_true(raised)
    for manifest in ["moon.mod", "moon.mod.json"] {
      let root = path_join(temp, "module-\{manifest}")
      @fs.mkdir(root, recursive=true)
      write_file(path_join(root, manifest), "x")
      ensure_moonbit_module(root)
    }
  })
}

///|
async test "collect_moonbit_files applies skip, suffix, and filter rules" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let root = path_join(temp, "module")
    make_module_tree(root)
    write_file(path_join(root, "a.mbt"), "pub fn a() -> Int { 1 }\n")
    write_file(path_join(root, "a_test.mbt"), "test \"a\" { () }\n")
    write_file(path_join(root, "b_wbtest.mbt"), "test \"b\" { () }\n")
    write_file(path_join(root, "notes.txt"), "not moonbit\n")
    write_file(path_join(root, ".hidden.mbt"), "pub fn h() -> Int { 3 }\n")
    let sub = path_join(root, "sub")
    @fs.mkdir(sub, recursive=true)
    write_file(path_join(sub, "c.mbt"), "pub fn c() -> Int { 2 }\n")
    for skipped in ["_build", ".git", "node_modules"] {
      let dir = path_join(root, skipped)
      @fs.mkdir(dir, recursive=true)
      write_file(path_join(dir, "junk.mbt"), "pub fn junk() -> Int { 0 }\n")
    }
    let found : Array[String] = []
    collect_moonbit_files(root, root, None, default_project_config(), found)
    found.sort()
    json_inspect(found, content=["a.mbt", "sub/c.mbt", ".hidden.mbt"])
    let filtered : Array[String] = []
    collect_moonbit_files(
      root,
      root,
      Some("c.mbt"),
      default_project_config(),
      filtered,
    )
    json_inspect(filtered, content=["sub/c.mbt"])
    let configured : Array[String] = []
    collect_moonbit_files(
      root,
      root,
      None,
      parse_project_config("include = [\"sub/\"]"),
      configured,
    )
    json_inspect(configured, content=["sub/c.mbt"])
    let excluded : Array[String] = []
    collect_moonbit_files(
      root,
      root,
      None,
      parse_project_config("exclude = [\"sub/\"]"),
      excluded,
    )
    excluded.sort()
    json_inspect(excluded, content=["a.mbt", ".hidden.mbt"])
  })
}

///|
async test "module-relative paths use portable separators" {
  let temp = @fs.tmpdir(prefix="turtles-path")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let root = path_join(temp, "module")
    let nested = path_join(root, "pkg/nested")
    @fs.mkdir(nested, recursive=true)
    let source = path_join(nested, "lib.mbt")
    write_file(source, "pub fn value() -> Int { 1 }\n")
    assert_eq(relative_path(root, source), "pkg/nested/lib.mbt")
  })
}

///|
async test "nested module directories are not collected" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let root = path_join(temp, "module")
    make_module_tree(root)
    write_file(path_join(root, "a.mbt"), "pub fn a() -> Int { 1 }\n")
    let nested = path_join(root, "nested")
    make_module_tree(nested)
    write_file(path_join(nested, "inner.mbt"), "pub fn i() -> Int { 2 }\n")
    let deep = path_join(nested, "deep")
    make_module_tree(deep)
    write_file(path_join(deep, "d.mbt"), "pub fn d() -> Int { 3 }\n")
    let plain = path_join(root, "plain")
    @fs.mkdir(plain, recursive=true)
    write_file(path_join(plain, "p.mbt"), "pub fn p() -> Int { 4 }\n")
    let found : Array[String] = []
    collect_moonbit_files(root, root, None, default_project_config(), found)
    found.sort()
    json_inspect(found, content=["a.mbt", "plain/p.mbt"])
  })
}

///|
#cfg(not(platform="windows"))
async test "observed_permission mirrors read, write, and execute bits" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let cases = [
      (0o644, 0o600),
      (0o755, 0o700),
      (0o444, 0o400),
      (0o600, 0o600),
      (0o222, 0o200),
      (0o000, 0o000),
    ]
    for case_ in cases {
      let (mode, expected) = case_
      let file = path_join(temp, "f-\{mode}")
      @fs.write_file(file, "x", permission=mode)
      inspect(observed_permission(file), content="\{expected}")
    }
    inspect(observed_permission(path_join(temp, "does-not-exist")), content="0")
  })
}

///|
async test "copy_tree omits skipped directories" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let source = path_join(temp, "source")
    make_module_tree(source)
    write_file(path_join(source, "keep.mbt"), "pub fn k() -> Int { 1 }\n")
    let plain = path_join(source, "plain")
    @fs.mkdir(plain, recursive=true)
    write_file(path_join(plain, "inner.mbt"), "pub fn i() -> Int { 2 }\n")
    let build = path_join(source, "_build")
    @fs.mkdir(build, recursive=true)
    write_file(path_join(build, "junk.mbt"), "junk\n")
    write_file(path_join(source, ".hidden.mbt"), "pub fn h() -> Int { 3 }\n")
    let workspace = path_join(temp, "workspace")
    @fs.mkdir(workspace, recursive=true)
    copy_tree(source, source, workspace)
    assert_true(@fs.exists(path_join(workspace, "keep.mbt")))
    assert_true(@fs.exists(path_join(workspace, "plain/inner.mbt")))
    assert_true(@fs.exists(path_join(workspace, ".hidden.mbt")))
    assert_true(!@fs.exists(path_join(workspace, "_build")))
  })
}

///|
#cfg(not(platform="windows"))
async test "force_rmdir removes read-only directory trees" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true) catch { _ => () })
    let locked = path_join(temp, "locked")
    @fs.mkdir(locked, recursive=true)
    write_file(path_join(locked, "inside.txt"), "content")
    let nested = path_join(locked, "nested")
    @fs.mkdir(nested, recursive=true)
    write_file(path_join(nested, "deep.txt"), "deep")
    let hidden_dir = path_join(locked, ".hidden")
    @fs.mkdir(hidden_dir, recursive=true)
    write_file(path_join(hidden_dir, "secret.txt"), "secret")
    @fs.chmod(nested, 0o555)
    @fs.chmod(hidden_dir, 0o555)
    @fs.chmod(locked, 0o555)
    force_rmdir(locked)
    assert_true(!@fs.exists(locked))
  })
}

///|
async test "sweep removes test-created state in non-moon dirs" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let source = path_join(temp, "source")
    make_module_tree(source)
    write_file(path_join(source, "a.mbt"), "pub fn a() -> Int { 1 }\n")
    let workspace = path_join(temp, "workspace")
    @fs.mkdir(workspace, recursive=true)
    copy_tree(source, source, workspace)
    let manifest = snapshot_workspace(workspace)
    // mutant N's test writes into dirs that were never copied
    for name in [".git", ".moon", "target", ".turtles", "node_modules"] {
      let dir = path_join(workspace, name)
      @fs.mkdir(dir, recursive=true)
      write_file(path_join(dir, "stray.txt"), "mutant N state")
    }
    // moon-managed dirs keep warm state instead
    for name in ["_build", ".mooncakes"] {
      let dir = path_join(workspace, name)
      @fs.mkdir(dir, recursive=true)
      write_file(path_join(dir, "warm.txt"), "build cache")
    }
    // mutant N's test also dirties a real source file
    write_file(path_join(workspace, "a.mbt"), "corrupted\n")
    sweep_workspace(workspace, source, manifest)
    // mutant N+1 must not observe any of it
    for name in [".git", ".moon", "target", ".turtles", "node_modules"] {
      assert_true(!@fs.exists(path_join(workspace, name)))
    }
    for name in ["_build", ".mooncakes"] {
      assert_eq(
        @fs.read_file(path_join(workspace, name + "/warm.txt")).text(),
        "build cache",
      )
    }
    assert_eq(
      @fs.read_file(path_join(workspace, "a.mbt")).text(),
      "pub fn a() -> Int { 1 }\n",
    )
  })
}

///|
#cfg(not(platform="windows"))
async test "sweep restores modes, link targets, and only root caches" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let source = path_join(temp, "source")
    make_module_tree(source)
    write_file(path_join(source, "a.mbt"), "pub fn a() -> Int { 1 }\n")
    @fs.write_file(
      path_join(source, "helper.sh"),
      "#!/bin/sh\n",
      permission=0o755,
    )
    write_file(path_join(source, "real.txt"), "linked")
    @fs.symlink(path_join(source, "link.txt"), target="real.txt")
    @fs.symlink(path_join(source, "gone.txt"), target="real.txt")
    let pkg = path_join(source, "pkg")
    @fs.mkdir(pkg, recursive=true)
    write_file(path_join(pkg, "kept.mbt"), "real package file")
    let workspace = path_join(temp, "workspace")
    @fs.mkdir(workspace, recursive=true)
    copy_tree(source, source, workspace)
    let manifest = snapshot_workspace(workspace)
    // mutant N's test mutates filesystem state without touching bytes
    let helper = path_join(workspace, "helper.sh")
    @fs.chmod(helper, 0o644)
    @fs.remove(path_join(workspace, "link.txt"))
    @fs.symlink(path_join(workspace, "link.txt"), target="a.mbt")
    // an outright delete (no replacement) must recreate, not crash
    @fs.remove(path_join(workspace, "gone.txt"))
    // and hides strays inside same-named dirs below the root
    let nested = path_join(workspace, "pkg")
    let deep_build = path_join(nested, "_build")
    @fs.mkdir(deep_build, recursive=true)
    write_file(path_join(deep_build, "stray"), "leak")
    let deep_cakes = path_join(nested, ".mooncakes")
    @fs.mkdir(deep_cakes, recursive=true)
    write_file(path_join(deep_cakes, "stray"), "leak")
    let root_build = path_join(workspace, "_build")
    @fs.mkdir(root_build, recursive=true)
    write_file(path_join(root_build, "warm"), "cache")
    // a mode-only change on an existing dir: entry stays, mode must not
    @fs.chmod(nested, 0o555)
    sweep_workspace(workspace, source, manifest)
    // mutant N+1 sees the original state
    assert_true(@fs.can_execute(helper))
    assert_eq(@fs.read_file(path_join(workspace, "link.txt")).text(), "linked")
    assert_eq(@fs.read_file(path_join(workspace, "gone.txt")).text(), "linked")
    assert_true(@fs.can_write(path_join(workspace, "pkg")))
    assert_true(!@fs.exists(deep_build))
    assert_true(!@fs.exists(deep_cakes))
    assert_true(@fs.exists(path_join(workspace, "pkg/kept.mbt")))
    assert_eq(@fs.read_file(path_join(root_build, "warm")).text(), "cache")
  })
}

///|
async fn write_file(path : String, content : String) -> Unit {
  @fs.write_file(path, content)
}

///|
async fn make_module_tree(dir : String) -> Unit {
  @fs.mkdir(dir, recursive=true)
  write_file(
    path_join(dir, "moon.mod"),
    "name = \"turtles_copy_fixture\"\nversion = \"0.1.0\"\n",
  )
  write_file(path_join(dir, "moon.pkg"), "")
}

///|
#cfg(not(platform="windows"))
async test "copied regular files preserve permission bits" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let source = path_join(temp, "source")
    make_module_tree(source)
    @fs.write_file(
      path_join(source, "helper.sh"),
      "#!/bin/sh\necho helper-ok\n",
      permission=0o755,
    )
    @fs.write_file(
      path_join(source, "locked.txt"),
      "do not write\n",
      permission=0o444,
    )
    write_file(path_join(source, "data.txt"), "plain")
    let workspace = path_join(temp, "workspace")
    @fs.mkdir(workspace, recursive=true)
    copy_tree(source, source, workspace)
    let copied = path_join(workspace, "helper.sh")
    assert_true(@fs.can_execute(copied))
    assert_eq(@fs.read_file(copied).text(), "#!/bin/sh\necho helper-ok\n")
    assert_true(!@fs.can_execute(path_join(workspace, "data.txt")))
    assert_true(!@fs.can_write(path_join(workspace, "locked.txt")))
    assert_true(@fs.can_write(path_join(workspace, "data.txt")))
  })
}

///|
#cfg(not(platform="windows"))
async test "read-only directories copy with their contents" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    // force_rmdir restores writability so read-only dirs can be removed;
    // protect_from_cancel makes it legal inside a nocancel defer.
    group.add_defer(() => {
      @async.protect_from_cancel(() => force_rmdir(temp) catch { _ => () })
    })
    let source = path_join(temp, "source")
    make_module_tree(source)
    let locked_dir = path_join(source, "locked")
    @fs.mkdir(locked_dir, recursive=true)
    write_file(path_join(locked_dir, "inside.txt"), "content")
    @fs.chmod(locked_dir, 0o555)
    let workspace = path_join(temp, "workspace")
    @fs.mkdir(workspace, recursive=true)
    copy_tree(source, source, workspace)
    let copied_dir = path_join(workspace, "locked")
    assert_eq(
      @fs.read_file(path_join(copied_dir, "inside.txt")).text(),
      "content",
    )
    assert_true(!@fs.can_write(copied_dir))
  })
}

///|
#cfg(platform="windows")
async test "copying regular files preserves contents with inherited ACLs" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let source = path_join(temp, "source")
    make_module_tree(source)
    write_file(path_join(source, "data.txt"), "Windows file content")
    let workspace = path_join(temp, "workspace")
    @fs.mkdir(workspace, recursive=true)
    copy_tree(source, source, workspace)
    assert_eq(
      @fs.read_file(path_join(workspace, "data.txt")).text(),
      "Windows file content",
    )
  })
}

///|
#cfg(not(platform="windows"))
async test "internal symlinks are recreated inside the workspace" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let source = path_join(temp, "source")
    make_module_tree(source)
    write_file(path_join(source, "real.txt"), "linked fixture data")
    @fs.symlink(path_join(source, "link.txt"), target="real.txt")
    let workspace = path_join(temp, "workspace")
    @fs.mkdir(workspace, recursive=true)
    copy_tree(source, source, workspace)
    let copied = path_join(workspace, "link.txt")
    inspect(@fs.kind(copied, follow_symlink=false) is SymLink, content="true")
    assert_eq(@fs.read_file(copied).text(), "linked fixture data")
    // the recreated link must point inside the workspace, not back to the
    // original tree
    let target = @fs.realpath(copied)
    assert_eq(target, @fs.realpath(path_join(workspace, "real.txt")))
  })
}

///|
#cfg(not(platform="windows"))
async test "symlinks escaping the module root are dereference-copied" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let source = path_join(temp, "source")
    make_module_tree(source)
    let outside = path_join(temp, "outside.txt")
    write_file(outside, "external content")
    @fs.symlink(path_join(source, "external.txt"), target=outside)
    let workspace = path_join(temp, "workspace")
    @fs.mkdir(workspace, recursive=true)
    copy_tree(source, source, workspace)
    let copied = path_join(workspace, "external.txt")
    inspect(@fs.kind(copied, follow_symlink=false) is Regular, content="true")
    assert_eq(@fs.read_file(copied).text(), "external content")
  })
}

///|
#cfg(not(platform="windows"))
async test "symlinks to directories are copied as trees" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let source = path_join(temp, "source")
    make_module_tree(source)
    let real_dir = path_join(source, "assets")
    @fs.mkdir(real_dir, recursive=true)
    write_file(path_join(real_dir, "data.txt"), "asset payload")
    @fs.symlink(path_join(source, "assets-link"), target="assets")
    let workspace = path_join(temp, "workspace")
    @fs.mkdir(workspace, recursive=true)
    copy_tree(source, source, workspace)
    let copied = path_join(workspace, "assets-link")
    assert_true(@fs.kind(copied, follow_symlink=false) is SymLink)
    assert_eq(
      @fs.read_file(path_join(copied, "data.txt")).text(),
      "asset payload",
    )
  })
}

///|
#cfg(not(platform="windows"))
async test "directory symlinks escaping the module root are copied as trees" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let source = path_join(temp, "source")
    make_module_tree(source)
    let outside = path_join(temp, "outside-assets")
    @fs.mkdir(outside, recursive=true)
    write_file(path_join(outside, "data.txt"), "external asset")
    @fs.symlink(path_join(source, "external-assets"), target=outside)
    let workspace = path_join(temp, "workspace")
    @fs.mkdir(workspace, recursive=true)
    copy_tree(source, source, workspace)
    let copied = path_join(workspace, "external-assets")
    assert_true(@fs.kind(copied, follow_symlink=false) is Directory)
    assert_eq(
      @fs.read_file(path_join(copied, "data.txt")).text(),
      "external asset",
    )
  })
}

///|
#cfg(not(platform="windows"))
async test "symlinks in nested directories keep their parents" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let source = path_join(temp, "source")
    make_module_tree(source)
    write_file(path_join(source, "real.txt"), "nested fixture data")
    let deep = path_join(source, "a/b")
    @fs.mkdir(deep, recursive=true)
    @fs.symlink(path_join(deep, "link.txt"), target="../../real.txt")
    let workspace = path_join(temp, "workspace")
    @fs.mkdir(workspace, recursive=true)
    copy_tree(source, source, workspace)
    assert_eq(
      @fs.read_file(path_join(workspace, "a/b/link.txt")).text(),
      "nested fixture data",
    )
  })
}

///|
#cfg(not(platform="windows"))
async test "dangling symlinks fail instead of being silently dropped" {
  let temp = @fs.tmpdir(prefix="turtles-test")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let source = path_join(temp, "source")
    make_module_tree(source)
    @fs.symlink(path_join(source, "missing.txt"), target="no-such-target")
    let workspace = path_join(temp, "workspace")
    @fs.mkdir(workspace, recursive=true)
    let mut raised = false
    copy_tree(source, source, workspace) catch {
      _ => raised = true
    }
    assert_true(raised)
  })
}
