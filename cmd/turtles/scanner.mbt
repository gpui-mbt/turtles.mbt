///|
struct OpSpec {
  group : OperatorGroup
  original : String
  replacement : String
}

///|
/// The mutation table. Ordering is observable: at one AST position, specs
/// sharing an `original` are recorded in table order, which keeps existing
/// comparison mutants ahead of the opt-in boundary ones. New groups append.
fn operator_specs() -> Array[OpSpec] {
  [
    { group: Comparison, original: "==", replacement: "!=", },
    { group: Comparison, original: "!=", replacement: "==", },
    { group: Comparison, original: ">=", replacement: "<", },
    { group: Comparison, original: "<=", replacement: ">", },
    { group: Boolean, original: "&&", replacement: "||", },
    { group: Boolean, original: "||", replacement: "&&", },
    { group: Literal, original: "true", replacement: "false", },
    { group: Literal, original: "false", replacement: "true", },
    { group: Arithmetic, original: "+", replacement: "-", },
    { group: Arithmetic, original: "-", replacement: "+", },
    { group: Arithmetic, original: "*", replacement: "/", },
    { group: Arithmetic, original: "/", replacement: "*", },
    { group: Comparison, original: ">", replacement: "<", },
    { group: Comparison, original: "<", replacement: ">", },
    // Boundary mutants only differ from the original at the equality point.
    { group: Boundary, original: "<", replacement: "<=", },
    { group: Boundary, original: ">", replacement: ">=", },
    { group: Boundary, original: "<=", replacement: "<", },
    { group: Boundary, original: ">=", replacement: ">", },
  ]
}

///|
/// Parser locations use Unicode-scalar offsets in the default lexer mode.
/// Mutation application, however, slices UTF-8 bytes. Build an explicit
/// boundary table once so parser locations are never confused with bytes.
fn utf8_width(byte : Byte) -> Int32 {
  let value = byte.to_int()
  if value < 0x80 {
    1
  } else if value < 0xE0 {
    2
  } else if value < 0xF0 {
    3
  } else {
    4
  }
}

///|
fn source_byte_boundaries(bytes : Bytes) -> Array[Int32] {
  let boundaries : Array[Int32] = [0]
  let mut byte_index = 0
  while byte_index < bytes.length() {
    let width = utf8_width(bytes[byte_index])
    if byte_index + width > bytes.length() {
      panic()
    }
    byte_index = byte_index + width
    boundaries.push(byte_index)
  }
  boundaries
}

///|
fn source_byte_offset(
  boundaries : Array[Int32],
  scalar_offset : Int32,
) -> Int32 {
  if scalar_offset < 0 || scalar_offset >= boundaries.length() {
    panic()
  }
  boundaries[scalar_offset]
}

///|
fn same_mutation_identity(left : Mutation, right : Mutation) -> Bool {
  left.path == right.path &&
  left.start == right.start &&
  left.end == right.end &&
  left.replacement == right.replacement
}

///|
struct AstCandidateVisitor {
  path : String
  bytes : Bytes
  boundaries : Array[Int32]
  specs : Array[OpSpec]
  project_config : ProjectConfig
  /// impl start offsets (scalar) excluded by a turtles skip marker
  skipped_starts : Map[Int32, Bool]
  /// out-param: receives one entry per skipped top-level block
  skipped_blocks : Array[SkippedBlock]?
  /// trait name -> method name -> (declared return type, is async):
  /// `impl` methods inherit their signature, so `ret_ty` there is None
  trait_methods : Map[String, Map[String, (@syntax.Type?, Bool)]]
  /// visibility of the top-level block currently being traversed
  mut current_visibility : MutantVisibility
  mutations : Array[Mutation]
}

///|
fn AstCandidateVisitor::append_mutation(
  self : AstCandidateVisitor,
  group : OperatorGroup,
  original : String,
  replacement : String,
  start : Int32,
  end : Int32,
  line : Int32,
  column : Int32,
) -> Unit {
  if original == replacement {
    return
  }
  let mutation = {
    path: self.path,
    start,
    end,
    line,
    column,
    group,
    original,
    replacement,
    visibility: self.current_visibility,
  }
  let mut duplicate = false
  for previous in self.mutations {
    if same_mutation_identity(previous, mutation) {
      duplicate = true
      break
    }
  }
  if !duplicate {
    self.mutations.push(mutation)
  }
}

///|
fn AstCandidateVisitor::record(
  self : AstCandidateVisitor,
  spec : OpSpec,
  start_scalar : Int32,
  end_scalar : Int32,
  line : Int32,
  column : Int32,
) -> Unit {
  if !self.project_config.operator_enabled(spec.group) {
    return
  }
  let start = source_byte_offset(self.boundaries, start_scalar)
  let end = source_byte_offset(self.boundaries, end_scalar)
  if end < start || end > self.bytes.length() {
    panic()
  }
  if @utf8.decode_lossy(self.bytes[start:end]) != spec.original {
    panic()
  }
  self.append_mutation(
    spec.group,
    spec.original,
    spec.replacement,
    start,
    end,
    line,
    column,
  )
}

///|
/// Record a replacement whose original text is the complete source range.
fn AstCandidateVisitor::record_range(
  self : AstCandidateVisitor,
  group : OperatorGroup,
  replacement : String,
  start_scalar : Int32,
  end_scalar : Int32,
  line : Int32,
  column : Int32,
) -> Unit {
  if !self.project_config.operator_enabled(group) {
    return
  }
  let start = source_byte_offset(self.boundaries, start_scalar)
  let end = source_byte_offset(self.boundaries, end_scalar)
  if end < start || end > self.bytes.length() {
    panic()
  }
  let original = @utf8.decode_lossy(self.bytes[start:end])
  self.append_mutation(group, original, replacement, start, end, line, column)
}

///|
/// Record every enabled replacement for one operator spelling, in table
/// order: comparison and boundary share `<`, `>`, `<=` and `>=`. A matching
/// spec of a disabled group consumes nothing, so it must not end the search.
fn AstCandidateVisitor::record_operator(
  self : AstCandidateVisitor,
  original : String,
  start_scalar : Int32,
  end_scalar : Int32,
  line : Int32,
  column : Int32,
) -> Unit {
  for spec in self.specs {
    if spec.original == original {
      self.record(spec, start_scalar, end_scalar, line, column)
    }
  }
}

///|
impl @syntax.IterVisitor for AstCandidateVisitor with fn visit_Expr_Infix(
  self,
  op~,
  lhs~,
  rhs~,
  loc~,
) {
  match op.name {
    @syntax.LongIdent::Ident(name~) =>
      self.record_operator(
        name,
        op.loc.start.cnum,
        op.loc.end.cnum,
        op.loc.start.lnum,
        op.loc.start.column(),
      )
    _ => ()
  }
  @syntax.IterVisitor::visit_Expr_Infix(
    @syntax.IterVisitor::base(self),
    op~,
    lhs~,
    rhs~,
    loc~,
  )
}

///|
impl @syntax.IterVisitor for AstCandidateVisitor with fn visit_Expr_Constant(
  self,
  c~,
  loc~,
) {
  match c {
    @syntax.Constant::Bool(value) => {
      let original = if value { "true" } else { "false" }
      self.record_operator(
        original,
        loc.start.cnum,
        loc.end.cnum,
        loc.start.lnum,
        loc.start.column(),
      )
    }
    _ => ()
  }
  @syntax.IterVisitor::visit_Expr_Constant(
    @syntax.IterVisitor::base(self),
    c~,
    loc~,
  )
}

///|
/// For `Expr::Unary` the parser tags `op` with the location of the whole
/// expression (e.g. `-x`), so the operator text occupies only the first
/// `name` scalars of `op.loc`.
impl @syntax.IterVisitor for AstCandidateVisitor with fn visit_Expr_Unary(
  self,
  op~,
  expr~,
  loc~,
) {
  match op.name {
    @syntax.LongIdent::Ident(name~) =>
      self.record_operator(
        name,
        op.loc.start.cnum,
        op.loc.start.cnum + name.char_length(),
        op.loc.start.lnum,
        op.loc.start.column(),
      )
    _ => ()
  }
  @syntax.IterVisitor::visit_Expr_Unary(
    @syntax.IterVisitor::base(self),
    op~,
    expr~,
    loc~,
  )
}

///|
impl @syntax.IterVisitor for AstCandidateVisitor with fn visit_Expr_If(
  self,
  cond~,
  ifso~,
  ifnot~,
  loc~,
) {
  let condition_loc = cond.loc()
  self.record_range(
    Condition,
    "true",
    condition_loc.start.cnum,
    condition_loc.end.cnum,
    condition_loc.start.lnum,
    condition_loc.start.column(),
  )
  self.record_range(
    Condition,
    "false",
    condition_loc.start.cnum,
    condition_loc.end.cnum,
    condition_loc.start.lnum,
    condition_loc.start.column(),
  )
  @syntax.IterVisitor::visit_Expr_If(
    @syntax.IterVisitor::base(self),
    cond~,
    ifso~,
    ifnot~,
    loc~,
  )
}

///|
/// Map a declaration's `vis` to a mutant bucket: every `pub` form —
/// `pub`, `pub(all)`, `pub(open)` — is public; `priv` and the implicit
/// default are private.
fn decl_visibility(vis : @syntax.Visibility) -> MutantVisibility {
  match vis {
    @syntax.Visibility::Pub(..) => Public
    Default | Priv(..) => Private
  }
}

///|
/// The visibility bucket of a top-level block. `test` blocks have no
/// visibility marker — their mutants are tagged Test and excluded from
/// the public/private score split. `TopExpr`/`TopImport` carry no `vis`
/// and fall back to the implicit default.
fn impl_visibility(impl_ : @syntax.Impl) -> MutantVisibility {
  match impl_ {
    TopFuncDef(fun_decl~, ..) => decl_visibility(fun_decl.vis)
    TopTypeDef(decl) => decl_visibility(decl.type_vis)
    TopTrait(decl) => decl_visibility(decl.vis)
    TopLetDef(vis~, ..) => decl_visibility(vis)
    TopImpl(vis~, ..) => decl_visibility(vis)
    TopView(vis~, ..) => decl_visibility(vis)
    TopImplRelation(vis~, ..) => decl_visibility(vis)
    TopUsing(vis~, ..) => decl_visibility(vis)
    TopExtend(vis~, ..) => decl_visibility(vis)
    TopTest(..) => Test
    TopExpr(..) | TopImport(..) => Private
  }
}

///|
/// The byte span of a top-level block, for skip-marker region checks.
fn impl_span(impl_ : @syntax.Impl) -> (Int32, Int32) {
  let loc = match impl_ {
    TopExpr(loc~, ..) => loc
    TopTest(loc~, ..) => loc
    TopTypeDef(decl) => decl.loc
    TopFuncDef(loc~, ..) => loc
    TopLetDef(loc~, ..) => loc
    TopTrait(decl) => decl.loc
    TopImpl(loc~, ..) => loc
    TopView(loc~, ..) => loc
    TopImplRelation(loc~, ..) => loc
    TopUsing(loc~, ..) => loc
    TopExtend(loc~, ..) => loc
    TopImport(loc~, ..) => loc
  }
  (loc.start.cnum, loc.end.cnum)
}

///|
/// The line a top-level block starts on, for `--list` skip reporting.
fn impl_line(impl_ : @syntax.Impl) -> Int32 {
  let loc = match impl_ {
    TopExpr(loc~, ..) => loc
    TopTest(loc~, ..) => loc
    TopTypeDef(decl) => decl.loc
    TopFuncDef(loc~, ..) => loc
    TopLetDef(loc~, ..) => loc
    TopTrait(decl) => decl.loc
    TopImpl(loc~, ..) => loc
    TopView(loc~, ..) => loc
    TopImplRelation(loc~, ..) => loc
    TopUsing(loc~, ..) => loc
    TopExtend(loc~, ..) => loc
    TopImport(loc~, ..) => loc
  }
  loc.start.lnum
}

///|
fn is_turtles_skip_attr(raw : String) -> Bool {
  raw.trim().to_owned() == "#turtles.skip"
}

///|
fn attrs_have_skip(attrs : @list.List[@attribute.Attribute]) -> Bool {
  for attr in attrs {
    if is_turtles_skip_attr(attr.raw) {
      return true
    }
  }
  false
}

///|
/// Does this impl carry the `#turtles.skip` attribute? Attribute-bearing
/// variants are checked directly; `TopExpr`/`TopImport` cannot carry one.
fn impl_has_skip_attr(impl_ : @syntax.Impl) -> Bool {
  match impl_ {
    TopFuncDef(fun_decl~, ..) => attrs_have_skip(fun_decl.attrs)
    TopTest(attrs~, ..) => attrs_have_skip(attrs)
    TopTypeDef(decl) => attrs_have_skip(decl.attrs)
    TopLetDef(attrs~, ..) => attrs_have_skip(attrs)
    TopTrait(decl) => attrs_have_skip(decl.attrs)
    TopImpl(attrs~, ..) => attrs_have_skip(attrs)
    TopView(attrs~, ..) => attrs_have_skip(attrs)
    TopImplRelation(attrs~, ..) => attrs_have_skip(attrs)
    TopUsing(attrs~, ..) => attrs_have_skip(attrs)
    TopExtend(attrs~, ..) => attrs_have_skip(attrs)
    TopExpr(..) | TopImport(..) => false
  }
}

///|
/// A line comment is a skip marker when its text after `//` is exactly
/// `turtles: skip` — trailing words or block comments never qualify.
fn is_skip_comment(content : String) -> Bool {
  let trimmed = content.trim().to_owned()
  guard trimmed.has_prefix("//") else { return false }
  trimmed[2:].to_owned().trim().to_owned() == "turtles: skip"
}

///|
/// Scalar positions of `// turtles: skip` line comments. Comments are not
/// part of the AST, so they are collected with the lexer in comment mode.
fn skip_comment_positions(source : String) -> Array[Int32] {
  let positions : Array[Int32] = []
  let result = @lexer.tokens_from_string(source, comment=true)
  for entry in result.tokens {
    if entry.0 is @tokens.Token::COMMENT(comment) &&
      is_skip_comment(comment.content) {
      positions.push(entry.1.cnum)
    }
  }
  positions
}

///|
fn long_ident_last(ident : @syntax.LongIdent) -> String {
  match ident {
    Ident(name~) => name
    Dot(id~, ..) => id
  }
}

///|
/// Trait method signatures from `trait` declarations in the same file, for
/// `impl` blocks that inherit them rather than redeclaring `ret_ty`.
fn collect_trait_methods(
  impls : Array[@syntax.Impl],
) -> Map[String, Map[String, (@syntax.Type?, Bool)]] {
  let traits : Map[String, Map[String, (@syntax.Type?, Bool)]] = Map([])
  for impl_ in impls {
    guard impl_ is TopTrait(decl) else { continue }
    let methods : Map[String, (@syntax.Type?, Bool)] = Map([])
    for trait_method in decl.methods {
      methods[trait_method.name.name] = (
        trait_method.return_type,
        trait_method.is_async is Some(_),
      )
    }
    traits[decl.name.name] = methods
  }
  traits
}

///|
/// The impls a marker excludes. An attribute skips its own impl; a line
/// comment skips the impl it leads — the first impl ending after the
/// comment — so a marker under `///|` or inside a body selects the block.
fn skipped_impl_starts(
  impls : Array[@syntax.Impl],
  source : String,
) -> Map[Int32, Bool] {
  let skipped : Map[Int32, Bool] = Map([])
  for impl_ in impls {
    if impl_has_skip_attr(impl_) {
      skipped[impl_span(impl_).0] = true
    }
  }
  for position in skip_comment_positions(source) {
    for impl_ in impls {
      if impl_span(impl_).1 > position {
        skipped[impl_span(impl_).0] = true
        break
      }
    }
  }
  skipped
}

///|
/// The `body` group replaces a whole function body with a trivial value of
/// the declared return type (cargo-mutants' primary generator). MoonBit
/// has no `Default` trait, so only types with a canonical literal get a
/// replacement; every other type — including `Result` — is skipped rather
/// than risking UNVIABLE noise.
fn body_replacements(return_type : @syntax.Type?) -> Array[String] {
  match return_type {
    None => ["()"]
    Some(ty) =>
      match ty {
        @syntax.Type::Option(..) => ["None"]
        @syntax.Type::Tuple(tys~, ..) =>
          if tys.is_empty() {
            ["()"]
          } else {
            []
          }
        @syntax.Type::Name(constr_id~, tys~, ..) => {
          guard constr_id.id is @syntax.LongIdent::Ident(name~) else {
            return []
          }
          if tys.is_empty() {
            match name {
              "Unit" => ["()"]
              "Bool" => ["true", "false"]
              "Int" | "Int64" | "Int16" => ["0", "1", "-1"]
              "UInt" | "UInt64" | "UInt16" | "Byte" => ["0", "1"]
              "Double" | "Float" => ["0.0", "1.0"]
              "String" => ["\"\"", "\"xyzzy\""]
              _ => []
            }
          } else {
            match name {
              "Option" => ["None"]
              "Array" | "FixedArray" => ["[]"]
              "Map" => ["{}"]
              _ => []
            }
          }
        }
        _ => []
      }
  }
}

///|
/// A body that is already a single trivial literal has no meaningful body
/// mutant — replacing it would only restate a literal mutation.
fn is_trivial_body(expr : @syntax.Expr) -> Bool {
  match expr {
    Constant(..) | Unit(..) | Constr(..) | MultilineString(..) => true
    Tuple(exprs~, ..) => exprs.is_empty()
    Array(exprs~, ..) => exprs.is_empty()
    Map(elems~, ..) => elems.is_empty()
    _ => false
  }
}

///|
fn AstCandidateVisitor::record_body(
  self : AstCandidateVisitor,
  return_type : @syntax.Type?,
  is_async : Bool,
  decl_body : @syntax.DeclBody,
) -> Unit {
  if !self.project_config.operator_enabled(Body) {
    return
  }
  // `async` bodies may suspend; `extern`/FFI declarations (DeclStubs) and
  // signature-only declarations (DeclNone) have no expression to replace.
  if is_async {
    return
  }
  guard decl_body is @syntax.DeclBody::DeclBody(expr~) else { return }
  if is_trivial_body(expr) {
    return
  }
  let loc = expr.loc()
  for replacement in body_replacements(return_type) {
    self.record_range(
      Body,
      replacement,
      loc.start.cnum,
      loc.end.cnum,
      loc.start.lnum,
      loc.start.column(),
    )
  }
}

///|
impl @syntax.IterVisitor for AstCandidateVisitor with fn visit_Impl(self, impl_) {
  self.current_visibility = impl_visibility(impl_)
  let start = impl_span(impl_).0
  if self.skipped_starts.contains(start) {
    match self.skipped_blocks {
      Some(blocks) => blocks.push({ path: self.path, line: impl_line(impl_), })
      None => ()
    }
    return
  }
  @syntax.IterVisitor::visit_Impl(@syntax.IterVisitor::base(self), impl_)
}

///|
impl @syntax.IterVisitor for AstCandidateVisitor with fn visit_Impl_TopFuncDef(
  self,
  fun_decl~,
  decl_body~,
  where_clause~,
  loc~,
) {
  self.record_body(
    fun_decl.return_type,
    fun_decl.is_async is Some(_),
    decl_body,
  )
  @syntax.IterVisitor::visit_Impl_TopFuncDef(
    @syntax.IterVisitor::base(self),
    fun_decl~,
    decl_body~,
    where_clause~,
    loc~,
  )
}

///|
impl @syntax.IterVisitor for AstCandidateVisitor with fn visit_Impl_TopImpl(
  self,
  self_ty~,
  trait_~,
  method_name~,
  quantifiers~,
  method_quantifiers~,
  params~,
  ret_ty~,
  err_ty~,
  nocancel_~,
  body~,
  vis~,
  loc~,
  attrs~,
  doc~,
) {
  let (return_type, is_async) = match ret_ty {
    Some(_) => (ret_ty, false)
    None =>
      match self.trait_methods.get(long_ident_last(trait_.name)) {
        Some(methods) =>
          match methods.get(method_name.name) {
            Some((ty, async_)) => (ty, async_)
            None => (None, false)
          }
        None => (None, false)
      }
  }
  self.record_body(return_type, is_async, body)
  @syntax.IterVisitor::visit_Impl_TopImpl(
    @syntax.IterVisitor::base(self),
    self_ty~,
    trait_~,
    method_name~,
    quantifiers~,
    method_quantifiers~,
    params~,
    ret_ty~,
    err_ty~,
    nocancel_~,
    body~,
    vis~,
    loc~,
    attrs~,
    doc~,
  )
}

///|
fn scan_source(
  path : String,
  source : String,
  project_config : ProjectConfig,
  skipped_blocks? : Array[SkippedBlock],
) -> Array[Mutation] raise {
  let bytes = @utf8.encode(source)
  let (impls, reports) = @parser.parse_string(source, name=path)
  if reports.length() != 0 {
    fail(
      "parser failed for \{path}: \{reports.length()} diagnostic(s); refusing lexical fallback",
    )
  }
  let visitor = AstCandidateVisitor::{
    path,
    bytes,
    boundaries: source_byte_boundaries(bytes),
    specs: operator_specs(),
    project_config,
    skipped_starts: skipped_impl_starts(impls.to_array(), source),
    skipped_blocks,
    trait_methods: collect_trait_methods(impls.to_array()),
    current_visibility: Private,
    mutations: [],
  }
  impls.each(impl_ => @syntax.IterVisitor::visit_Impl(visitor, impl_))
  visitor.mutations
}

///|
fn apply_mutation(source : String, mutation : Mutation) -> String raise {
  let bytes = @utf8.encode(source)
  guard mutation.start >= 0 &&
    mutation.end >= mutation.start &&
    mutation.end <= bytes.length() else {
    fail("mutation offsets are outside the source")
  }
  guard @utf8.decode(bytes[mutation.start:mutation.end]) == mutation.original else {
    fail("source changed after mutation discovery")
  }
  let output = @buffer.Buffer(
    size_hint=bytes.length() + mutation.replacement.length(),
  )
  output.write_bytes(bytes[:mutation.start])
  output.write_string_utf8(mutation.replacement)
  output.write_bytes(bytes[mutation.end:])
  @utf8.decode(output.to_bytes())
}

///|
fn describe_mutation(mutation : Mutation) -> String {
  "\{mutation.path}:\{mutation.line}:\{mutation.column}: \{mutation.original} -> \{mutation.replacement}"
}
