///|
/// A mutation assembled from arbitrary fields: `line`/`column`/`visibility`
/// sit outside `mutation_identity`, so they are fixed here.
fn pbt_mutation(
  path : String,
  start : Int32,
  end : Int32,
  original : String,
  replacement : String,
) -> Mutation {
  {
    path,
    start,
    end,
    line: 0,
    column: 0,
    group: Literal,
    original,
    replacement,
    visibility: Private,
  }
}

///|
test "prop mutation fingerprints are stable for identical inputs" {
  @quickcheck.check((input : (String, Int32, Int32, String, String)) => {
    let (path, start, end, original, replacement) = input
    let mutation = pbt_mutation(path, start, end, original, replacement)
    // Same content, independently constructed: identity and id must match.
    let copy = pbt_mutation(path, start, end, original, replacement)
    mutation_identity(mutation) == mutation_identity(copy) &&
    mutation_id(mutation) == mutation_id(copy) &&
    fingerprint_text(mutation_identity(mutation)) ==
    fingerprint_text(mutation_identity(copy))
  })
}

///|
test "prop mutation_identity separates every field" {
  // Appending a sentinel to any one field must change the identity: the
  // NUL separators keep "a\0b" inside one field from merging into the next.
  @quickcheck.check((input : (String, Int32, Int32, String, String)) => {
    let (path, start, end, original, replacement) = input
    let base = pbt_mutation(path, start, end, original, replacement)
    let base_identity = mutation_identity(base)
    mutation_identity({ ..base, path: base.path + "!", }) != base_identity &&
    mutation_identity({ ..base, start: base.start + 1, }) != base_identity &&
    mutation_identity({ ..base, end: base.end + 1, }) != base_identity &&
    mutation_identity({ ..base, original: base.original + "!", }) !=
    base_identity &&
    mutation_identity({ ..base, replacement: base.replacement + "!", }) !=
    base_identity
  })
}

///|
test "prop mutation_identity ignores line column and visibility" {
  // Identity is content-anchored: display metadata and the visibility
  // bucket must not change it.
  @quickcheck.check((input : (String, Int32, Int32, String, String, Int32)) => {
    let (path, start, end, original, replacement, line) = input
    let base = pbt_mutation(path, start, end, original, replacement)
    let base_identity = mutation_identity(base)
    mutation_identity({ ..base, line, }) == base_identity &&
    mutation_identity({ ..base, column: line, }) == base_identity &&
    mutation_identity({ ..base, visibility: Public, }) == base_identity &&
    mutation_identity({ ..base, visibility: Test, }) == base_identity
  })
}

///|
test "prop fingerprint_hex is a stable 16-digit lowercase hex string" {
  @quickcheck.check((hash : UInt64) => {
    let rendered = fingerprint_hex(hash)
    if rendered != fingerprint_hex(hash) {
      return false
    }
    if rendered.length() != 16 {
      return false
    }
    for c in rendered {
      if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
        return false
      }
    }
    true
  })
}
