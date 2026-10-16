///|
/// Split UTF-8 source into line strings (line terminators removed).
/// A trailing newline does not produce a phantom final line.
fn split_lines(bytes : Bytes) -> Array[String] raise {
  let lines : Array[String] = []
  let mut start = 0
  for i = 0; i < bytes.length(); i = i + 1 {
    if bytes[i] == b'\n' {
      lines.push(@utf8.decode(bytes[start:i]))
      start = i + 1
    }
  }
  if start < bytes.length() {
    lines.push(@utf8.decode(bytes[start:]))
  }
  lines
}

///|
/// 0-based index of the line containing byte `pos` (clamped in range).
fn line_of_byte(bytes : Bytes, pos : Int32) -> Int32 {
  let limit = if pos > bytes.length() { bytes.length() } else { pos }
  let mut line = 0
  for i = 0; i < limit; i = i + 1 {
    if bytes[i] == b'\n' {
      line = line + 1
    }
  }
  line
}

///|
/// 0-based index of the line containing the byte at exclusive-end `pos` -
/// i.e. the last changed byte. A changed newline still belongs to the line
/// it terminates.
fn line_of_end_byte(bytes : Bytes, pos : Int32) -> Int32 {
  if pos <= 0 {
    return 0
  }
  let limit = if pos > bytes.length() { bytes.length() } else { pos }
  let mut line = 0
  for i = 0; i < limit; i = i + 1 {
    if bytes[i] == b'\n' {
      line = line + 1
    }
  }
  if bytes[limit - 1] == b'\n' {
    line - 1
  } else {
    line
  }
}

///|
/// A unified-diff hunk for one contiguous mutation with `context` lines of
/// context. Mutations replace one byte span, so the result is a single hunk.
fn unified_mutation_diff(
  path : String,
  original_source : String,
  mutated_source : String,
) -> String raise {
  let context = 3
  let orig_bytes = @utf8.encode(original_source)
  let mut_bytes = @utf8.encode(mutated_source)
  let shared_limit = if orig_bytes.length() < mut_bytes.length() {
    orig_bytes.length()
  } else {
    mut_bytes.length()
  }
  let mut first = 0
  while first < shared_limit && orig_bytes[first] == mut_bytes[first] {
    first = first + 1
  }
  let mut last_orig = orig_bytes.length()
  let mut last_mut = mut_bytes.length()
  while last_orig > first &&
        last_mut > first &&
        orig_bytes[last_orig - 1] == mut_bytes[last_mut - 1] {
    last_orig = last_orig - 1
    last_mut = last_mut - 1
  }
  let orig_lines = split_lines(orig_bytes)
  let mut_lines = split_lines(mut_bytes)
  let first_line = line_of_byte(orig_bytes, first)
  let last_orig_line = if last_orig <= first {
    first_line - 1
  } else {
    line_of_end_byte(orig_bytes, last_orig)
  }
  let last_mut_line = if last_mut <= first {
    first_line - 1
  } else {
    line_of_end_byte(mut_bytes, last_mut)
  }
  let ctx_start = if first_line - context < 0 {
    0
  } else {
    first_line - context
  }
  let orig_end = {
    let bound = last_orig_line + context + 1
    if bound < first_line {
      first_line + context + 1
    } else if bound > orig_lines.length() {
      orig_lines.length()
    } else {
      bound
    }
  }
  let mut_end = {
    let bound = last_mut_line + context + 1
    if bound < first_line {
      first_line + context + 1
    } else if bound > mut_lines.length() {
      mut_lines.length()
    } else {
      bound
    }
  }
  let out = @buffer.Buffer()
  out.write_string_utf8("--- a/\{path}\n+++ b/\{path}\n")
  out.write_string_utf8(
    "@@ -\{ctx_start + 1},\{orig_end - ctx_start} +\{ctx_start + 1},\{mut_end - ctx_start} @@\n",
  )
  for i = ctx_start; i < first_line; i = i + 1 {
    out.write_string_utf8(" \{orig_lines[i]}\n")
  }
  for i = first_line; i <= last_orig_line && i < orig_lines.length(); i = i + 1 {
    out.write_string_utf8("-\{orig_lines[i]}\n")
  }
  for i = first_line; i <= last_mut_line && i < mut_lines.length(); i = i + 1 {
    out.write_string_utf8("+\{mut_lines[i]}\n")
  }
  for i = last_orig_line + 1; i < orig_end && i < orig_lines.length(); i = i + 1 {
    out.write_string_utf8(" \{orig_lines[i]}\n")
  }
  @utf8.decode(out.to_bytes())
}
