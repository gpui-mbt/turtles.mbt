///|
/// Strip the markers that give a message oracle meaning, so a property can
/// prove the classifier ignores everything else.
fn pbt_scrub_oracle_markers(text : String) -> String {
  text
  .replace_all(old="QuickCheck falsified", new="quickcheck falsified")
  .replace_all(old="@EXPECT_FAILED", new="EXPECT_FAILED")
  .replace_all(old="counterexample:", new="counterexample~")
}

///|
test "prop any QuickCheck falsified message classifies as a property kill" {
  @quickcheck.check((input : (String, String, String, String)) => {
    let (filename, test_name, before, after) = input
    let message = before + "QuickCheck falsified" + after
    test_kind(filename, test_name, message) == Property
  })
}

///|
test "prop markdown failures without a property marker are doc tests" {
  @quickcheck.check((input : (String, String, String)) => {
    let (stem, test_name, message) = input
    let message = pbt_scrub_oracle_markers(message)
    test_kind(stem + ".mbt.md", test_name, message) == DocTest
  })
}

///|
test "prop unnamed failures without a property marker are doc tests" {
  @quickcheck.check((input : (String, String)) => {
    let (filename, message) = input
    let message = pbt_scrub_oracle_markers(message)
    test_kind(filename, "", message) == DocTest
  })
}

///|
test "prop expect failures classify as snapshots outside doc tests" {
  @quickcheck.check((input : (String, String, String)) => {
    let (filename, test_name, tail) = input
    let filename = filename.replace_all(old=".mbt.md", new=".mbtmd")
    let test_name = if test_name == "" { "t" } else { test_name }
    let message = "@EXPECT_FAILED " + pbt_scrub_oracle_markers(tail)
    test_kind(filename, test_name, message) == Snapshot
  })
}

///|
test "prop parse_counterexample reads the first counterexample line" {
  @quickcheck.check((input : (String, String, String)) => {
    let (head, value, tail) = input
    let head = pbt_scrub_oracle_markers(head)
    let value = value.replace_all(old="\n", new=" ")
    let message = head + "\ncounterexample: " + value + "\n" + tail
    parse_counterexample(message) == Some(value.trim().to_owned())
  })
}

///|
test "prop parse_counterexample is absent without a counterexample line" {
  @quickcheck.check((message : String) => {
    let scrubbed = pbt_scrub_oracle_markers(message)
    parse_counterexample(scrubbed) == None
  })
}

///|
test "prop parse_kill_line decodes the documented json shape" {
  @quickcheck.check((input : (String, String, Int32, String, String)) => {
    let (pkg, filename, index, test_name, message) = input
    let line = (
      {
        "package": Json(pkg),
        "filename": Json(filename),
        "index": Json(index.to_string()),
        "test_name": Json(test_name),
        "message": Json(message),
      } : Json).stringify()
    match parse_kill_line(line) {
      Some(kill) =>
        kill.pkg == pkg &&
        kill.filename == filename &&
        kill.index == index &&
        kill.test_name == test_name &&
        kill.kind == test_kind(filename, test_name, message)
      None => false
    }
  })
}

///|
test "prop unstable_kills is symmetric and reports only one-sided tests" {
  @quickcheck.check((input : (Array[String], Array[String])) => {
    let (first_names, second_names) = input
    let first = first_names.map(name => {
      (
        {
          pkg: "p",
          filename: "f.mbt",
          index: 0,
          test_name: name,
          kind: Assertion,
          counterexample: None,
        } : Kill)
    })
    let second = second_names.map(name => {
      (
        {
          pkg: "p",
          filename: "f.mbt",
          index: 0,
          test_name: name,
          kind: Assertion,
          counterexample: None,
        } : Kill)
    })
    let forward = unstable_kills(first, second)
    let backward = unstable_kills(second, first)
    // Same set of unstable tests regardless of argument order.
    if forward.length() != backward.length() {
      return false
    }
    let first_keys : Map[String, Bool] = Map([])
    for name in first_names {
      first_keys[name] = true
    }
    let second_keys : Map[String, Bool] = Map([])
    for name in second_names {
      second_keys[name] = true
    }
    for kill in forward {
      let key = kill.test_name
      if first_keys.contains(key) == second_keys.contains(key) {
        return false
      }
    }
    let forward_keys : Map[String, Bool] = Map([])
    for kill in forward {
      forward_keys[kill.test_name] = true
    }
    for kill in backward {
      if !forward_keys.contains(kill.test_name) {
        return false
      }
    }
    true
  })
}
