///|
test "sign" {
  inspect(sign(2, 1), content="1")
  inspect(sign(1, 2), content="0")
}

///|
/// The suite runs a checked-in helper: it must stay executable in the
/// temporary workspace.
#cfg(not(platform="windows"))
async test "helper script runs" {
  let (code, output) = @process.collect_stdout("./helper.sh", [])
  assert_eq(code, 0)
  assert_true(output.text().contains("helper-ok"))
}

///|
/// Windows launches batch helpers through cmd.exe; this exercises copied
/// fixture paths without relying on a Unix shell or executable mode bits.
#cfg(platform="windows")
async test "Windows helper script runs" {
  let (code, output) = @process.collect_stdout(
    "cmd.exe",
    ["/d", "/c", "helper.cmd"],
  )
  assert_eq(code, 0)
  assert_true(output.text().contains("helper-ok"))
}

///|
/// The suite reads through a checked-in symlink: it must still resolve in
/// the temporary workspace.
async test "linked fixture resolves" {
  let data = @fs.read_file("linked.txt").text()
  assert_true(data.contains("linked fixture data"))
}

///|
/// A run leaves a sentinel behind. Re-running the suite in the same
/// filesystem must fail, so leaked state between mutant runs kills mutants
/// for the wrong reason. A sentinel copied from a different tree is stale
/// and gets refreshed instead. To re-run the suite in this directory,
/// delete `turtles.sentinel` first.
async test "filesystem state does not leak between runs" {
  let sentinel = "turtles.sentinel"
  let here = @fs.realpath(".")
  if @fs.exists(sentinel) {
    if @fs.read_file(sentinel).text() == here {
      fail("sentinel from a previous run in this workspace is still visible")
    } else {
      @fs.write_file(sentinel, here)
    }
  } else {
    @fs.write_file(sentinel, here)
  }
}
