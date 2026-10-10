///|
/// Static per-package index of a module's top-level functions, built once
/// per run when a PBT analysis is enabled. Feeds the witness generator
/// (signature + source spans for the cloned helper), the eligibility check
/// (effects and recursion over the module call graph), and the property
/// suggestions (signature shape and encode/decode counterpart lookup).

///|
/// One positional or required-labelled parameter: its call-site spelling
/// and the type annotation text lifted straight from the source.
struct FnParamInfo {
  /// label for `name~ = arg` calls; None for positional params
  label : String?
  /// binder name for positional calls (`_` for `_ : T` discards)
  name : String
  ty : @syntax.Type
  /// source text of the type annotation
  ty_text : String
}

///|
/// A top-level `fn` declaration and everything analysis derives from it.
struct FnInfo {
  /// package directory relative to the module root ("." for root)
  pkg : String
  name : String
  /// module-relative source path
  file : String
  is_async : Bool
  /// carries a declaration-level `#cfg` attribute
  cfg : Bool
  generic : Bool
  /// every parameter is positional/discard/required-labelled and typed
  params_ok : Bool
  params : Array[FnParamInfo]
  ret : @syntax.Type?
  /// source text of the return type annotation ("" when absent)
  ret_text : String
  /// DeclStubs/DeclNone: extern or interface-style declarations have no
  /// body to clone
  stub : Bool
  /// byte span of the whole `fn` item inside `file`
  impl_start : Int
  impl_end : Int
  /// byte span of the fn name token inside `file`
  name_start : Int
  name_end : Int
  /// module-local functions referenced anywhere in the body, (pkg, name)
  edges : Array[(String, String)]
  mut effects_unknown : Bool
}

///|
/// Per-package top-level tables: the surfaces the body analysis and the
/// collision-safe naming consult.
struct PkgIndex {
  dir : String
  fns : Map[String, FnInfo]
  /// top-level `let` names -> declared type (None = untyped)
  lets : Map[String, @syntax.Type?]
  /// every top-level symbol (fns, lets, types, traits, methods, views)
  symbols : Map[String, Bool]
  /// test-name literals declared in this package's test blocks
  tests : Map[String, Bool]
  /// alias -> module-local dir or full external package path
  imports : Map[String, String]
  test_imports : Map[String, String]
  wbtest_imports : Map[String, String]
}

///|
struct ModuleIndex {
  pkgs : Map[String, PkgIndex]
  /// all dirs holding a package manifest, relative to the module root
  pkg_dirs : Map[String, Bool]
  /// file -> fns defined in it (for enclosing-fn lookup)
  fns_by_file : Map[String, Array[FnInfo]]
  /// node ids ("pkg\x01name") that sit in a recursive SCC
  recursive : Map[String, Bool]
}

///|
fn fn_node(pkg : String, name : String) -> String {
  "\{pkg}\u{1}\{name}"
}

///|
/// Value types accepted for witness signatures and top-level `let`
/// references: immutable, Eq + Debug, and Arbitrary in core quickcheck.
fn is_value_scalar(name : String) -> Bool {
  match name {
    "Unit"
    | "Bool"
    | "Int"
    | "Int16"
    | "Int64"
    | "UInt"
    | "UInt16"
    | "UInt64"
    | "Byte"
    | "Char"
    | "String"
    | "Double"
    | "Float" => true
    _ => false
  }
}

///|
/// Conservative immutable-value-type check: scalars, tuples and Option of
/// them. Array/Map/Ref/Bytes/user types are always excluded — the witness
/// only compares functions whose observable result is a plain value.
fn is_value_type(ty : @syntax.Type) -> Bool {
  match ty {
    @syntax.Type::Any(..) => false
    @syntax.Type::Tuple(tys~, ..) => {
      for item in tys {
        if !is_value_type(item) {
          return false
        }
      }
      true
    }
    @syntax.Type::Option(ty~, ..) => is_value_type(ty)
    @syntax.Type::Name(constr_id~, tys~, ..) =>
      match constr_id.id {
        @syntax.LongIdent::Ident(name~) =>
          if tys.is_empty() {
            is_value_scalar(name)
          } else {
            let args = tys.to_array()
            name == "Option" && args.length() == 1 && is_value_type(args[0])
          }
        _ => false
      }
    _ => false
  }
}

///|
/// The broader arbitrable set for property suggestions: the check input
/// must only have Arbitrary + Shrink + Debug, which core also provides for
/// the common containers.
fn is_arbitrable_scalar(name : String) -> Bool {
  is_value_scalar(name) || name == "Bytes" || name == "BigInt"
}

///|
fn is_arbitrable_type(ty : @syntax.Type) -> Bool {
  match ty {
    @syntax.Type::Any(..) => false
    @syntax.Type::Tuple(tys~, ..) => {
      for item in tys {
        if !is_arbitrable_type(item) {
          return false
        }
      }
      true
    }
    @syntax.Type::Option(ty~, ..) => is_arbitrable_type(ty)
    @syntax.Type::Name(constr_id~, tys~, ..) =>
      match constr_id.id {
        @syntax.LongIdent::Ident(name~) => {
          let args = tys.to_array()
          if args.is_empty() {
            is_arbitrable_scalar(name)
          } else {
            let container = match name {
              "Option"
              | "Result"
              | "Array"
              | "FixedArray"
              | "ReadOnlyArray"
              | "ArrayView"
              | "Iter"
              | "List"
              | "Set"
              | "Deque"
              | "Queue"
              | "PriorityQueue"
              | "Vector"
              | "Map"
              | "HashMap"
              | "HashSet" => true
              _ => false
            }
            if !container {
              return false
            }
            for arg in args {
              if !is_arbitrable_type(arg) {
                return false
              }
            }
            true
          }
        }
        _ => false
      }
    _ => false
  }
}

///|
/// Byte span of an AST location in `boundaries` terms.
fn loc_bytes(boundaries : Array[Int], loc : @basic.Location) -> (Int, Int) {
  (
    source_byte_offset(boundaries, loc.start.cnum),
    source_byte_offset(boundaries, loc.end.cnum),
  )
}

///|
/// Body-walk visitor collecting what the effects check needs: every
/// locally bound name, every bare identifier reference, every `pkg.name`
/// qualifier, and flags for the constructs that make a function
/// undecidable for the differential witness (method calls, trait
/// objects, mutation of non-local state, `raise`).
struct FnBodyVisitor {
  /// binders introduced inside the body (let/pattern/lambda/for binders)
  fresh : Map[String, Bool]
  /// bare `name` references
  idents : Map[String, Bool]
  /// `@pkg.id` references: alias -> referenced ids
  dots : Map[String, Array[String]]
  mut effects_unknown : Bool
}

///|
fn FnBodyVisitor::new() -> FnBodyVisitor {
  { fresh: Map([]), idents: Map([]), dots: Map([]), effects_unknown: false, }
}

///|
/// The identifier an assignment/mutation ultimately targets: `x` for
/// `x.f = e`, `x[0] = e`, `x = e`; `(x).f`, `(x : T).f` unwrap too. Any
/// other base expression (a call result, a record literal, ...) means the
/// storage owner cannot be decided -> treat as non-local.
fn mutation_root_ident(expr : @syntax.Expr) -> String? {
  match expr {
    @syntax.Expr::Ident(id~, ..) =>
      match id.name {
        @syntax.LongIdent::Ident(name~) => Some(name)
        _ => None
      }
    @syntax.Expr::Field(record~, ..) => mutation_root_ident(record)
    @syntax.Expr::ArrayGet(array~, ..) => mutation_root_ident(array)
    @syntax.Expr::ArrayGetSlice(array~, ..) => mutation_root_ident(array)
    @syntax.Expr::Group(expr~, ..) | @syntax.Expr::Constraint(expr~, ..) =>
      mutation_root_ident(expr)
    _ => None
  }
}

///|
/// Unwrap parenthesised/annotated callees to the application head.
fn callee_head(expr : @syntax.Expr) -> @syntax.Expr {
  match expr {
    @syntax.Expr::Group(expr~, ..) | @syntax.Expr::Constraint(expr~, ..) =>
      callee_head(expr)
    other => other
  }
}

///|
impl @syntax.IterVisitor for FnBodyVisitor with fn visit_Binder(self, binder) {
  self.fresh[binder.name] = true
  @syntax.IterVisitor::visit_Binder(@syntax.IterVisitor::base(self), binder)
}

///|
impl @syntax.IterVisitor for FnBodyVisitor with fn visit_Expr_Ident(
  self,
  id~,
  loc~,
) {
  match id.name {
    @syntax.LongIdent::Ident(name~) => self.idents[name] = true
    @syntax.LongIdent::Dot(pkg~, id~) =>
      match self.dots.get(pkg) {
        Some(ids) => ids.push(id)
        None => self.dots[pkg] = [id]
      }
  }
  @syntax.IterVisitor::visit_Expr_Ident(
    @syntax.IterVisitor::base(self),
    id~,
    loc~,
  )
}

///|
/// `f(args)` is decidable only for bare/qualified identifiers and
/// constructors; anything else — method calls, closures invoked by value,
/// `T::m` — is recorded as unknown.
impl @syntax.IterVisitor for FnBodyVisitor with fn visit_Expr_Apply(
  self,
  func~,
  args~,
  loc~,
) {
  match callee_head(func) {
    @syntax.Expr::Ident(..) | @syntax.Expr::Constr(..) => ()
    _ => self.effects_unknown = true
  }
  @syntax.IterVisitor::visit_Expr_Apply(
    @syntax.IterVisitor::base(self),
    func~,
    args~,
    loc~,
  )
}

///|
/// `x.m(args)` / `x.m!` — a method dispatch the static check cannot
/// resolve, so it counts as unknown effect surface.
impl @syntax.IterVisitor for FnBodyVisitor with fn visit_Expr_DotApply(
  env,
  self~,
  method_name~,
  args~,
  return_self~,
  loc~,
) {
  env.effects_unknown = true
  @syntax.IterVisitor::visit_Expr_DotApply(
    @syntax.IterVisitor::base(env),
    self~,
    method_name~,
    args~,
    return_self~,
    loc~,
  )
}

///|
impl @syntax.IterVisitor for FnBodyVisitor with fn visit_Expr_Method(
  self,
  type_name~,
  method_name~,
  loc~,
) {
  self.effects_unknown = true
  @syntax.IterVisitor::visit_Expr_Method(
    @syntax.IterVisitor::base(self),
    type_name~,
    method_name~,
    loc~,
  )
}

///|
/// `expr as Trait` creates a trait object: later calls through it are
/// dynamic dispatch — unknown.
impl @syntax.IterVisitor for FnBodyVisitor with fn visit_Expr_As(
  self,
  expr~,
  trait_~,
  loc~,
) {
  self.effects_unknown = true
  @syntax.IterVisitor::visit_Expr_As(
    @syntax.IterVisitor::base(self),
    expr~,
    trait_~,
    loc~,
  )
}

///|
/// `raise` is an observable effect — the witness records it as a raise,
/// not a divergence, so such functions stay ineligible.
impl @syntax.IterVisitor for FnBodyVisitor with fn visit_Expr_Raise(
  self,
  err_value~,
  loc~,
) {
  self.effects_unknown = true
  @syntax.IterVisitor::visit_Expr_Raise(
    @syntax.IterVisitor::base(self),
    err_value~,
    loc~,
  )
}

///|
/// `record.field = e` / `record.field += e` — allowed only when the record
/// binds to a name the body itself owns.
impl @syntax.IterVisitor for FnBodyVisitor with fn visit_Expr_Mutate(
  self,
  record~,
  accessor~,
  field~,
  augmented_by~,
  loc~,
) {
  match mutation_root_ident(record) {
    Some(name) => if !self.fresh.contains(name) { self.effects_unknown = true }
    None => self.effects_unknown = true
  }
  @syntax.IterVisitor::visit_Expr_Mutate(
    @syntax.IterVisitor::base(self),
    record~,
    accessor~,
    field~,
    augmented_by~,
    loc~,
  )
}

///|
impl @syntax.IterVisitor for FnBodyVisitor with fn visit_Expr_ArraySet(
  self,
  array~,
  index~,
  value~,
  loc~,
) {
  match mutation_root_ident(array) {
    Some(name) => if !self.fresh.contains(name) { self.effects_unknown = true }
    None => self.effects_unknown = true
  }
  @syntax.IterVisitor::visit_Expr_ArraySet(
    @syntax.IterVisitor::base(self),
    array~,
    index~,
    value~,
    loc~,
  )
}

///|
impl @syntax.IterVisitor for FnBodyVisitor with fn visit_Expr_ArrayAugmentedSet(
  self,
  op~,
  array~,
  index~,
  value~,
  loc~,
) {
  match mutation_root_ident(array) {
    Some(name) => if !self.fresh.contains(name) { self.effects_unknown = true }
    None => self.effects_unknown = true
  }
  @syntax.IterVisitor::visit_Expr_ArrayAugmentedSet(
    @syntax.IterVisitor::base(self),
    op~,
    array~,
    index~,
    value~,
    loc~,
  )
}

///|
/// `n = e` / `n += e` — the target must be a `let mut` the body owns;
/// assigning a parameter or a top-level binding is a non-local effect.
impl @syntax.IterVisitor for FnBodyVisitor with fn visit_Expr_Assign(
  self,
  var_~,
  expr~,
  augmented_by~,
  loc~,
) {
  let bound_here = match var_.name {
    @syntax.LongIdent::Ident(name~) => self.fresh.contains(name)
    _ => false
  }
  if !bound_here {
    self.effects_unknown = true
  }
  @syntax.IterVisitor::visit_Expr_Assign(
    @syntax.IterVisitor::base(self),
    var_~,
    expr~,
    augmented_by~,
    loc~,
  )
}

///|
/// `lhs |> rhs` restricts the rhs shape already; a callee that is not a
/// bare identifier is undecidable.
impl @syntax.IterVisitor for FnBodyVisitor with fn visit_Expr_Pipe(
  self,
  lhs~,
  rhs~,
  loc~,
) {
  match callee_head(rhs) {
    @syntax.Expr::Ident(..)
    | @syntax.Expr::Apply(..)
    | @syntax.Expr::DotApply(..)
    | @syntax.Expr::Constr(..) => ()
    _ => self.effects_unknown = true
  }
  @syntax.IterVisitor::visit_Expr_Pipe(
    @syntax.IterVisitor::base(self),
    lhs~,
    rhs~,
    loc~,
  )
}

///|
/// Pure `moonbitlang/core` packages the witness allowlists — matching the
/// issue's examples plus the other immutable-value helpers.
fn pure_core_pkg(pkg : String) -> Bool {
  match pkg {
    "math"
    | "string"
    | "char"
    | "int"
    | "int16"
    | "int64"
    | "uint"
    | "uint16"
    | "uint64"
    | "byte"
    | "bool"
    | "double"
    | "float"
    | "option"
    | "tuple"
    | "unit"
    | "list"
    | "result" => true
    _ => false
  }
}

///|
/// Read `name = "..."` out of a moon.mod / moon.mod.json manifest — the
/// module identity import paths are checked against.
async fn module_name_of(root : String) -> String? {
  let toml = path_join(root, "moon.mod")
  if @fs.exists(toml) {
    let text = @fs.read_file(toml).text() catch { _ => return None }
    for line in text.split("\n") {
      let line = line.trim().to_owned()
      if line.has_prefix("name") {
        match line.find("\"") {
          Some(first) =>
            match line.rev_find("\"") {
              Some(last) if last > first =>
                return Some(line[first + 1:last].to_owned())
              _ => ()
            }
          None => ()
        }
      }
    }
    return None
  }
  let json_manifest = path_join(root, "moon.mod.json")
  if @fs.exists(json_manifest) {
    let text = @fs.read_file(json_manifest).text() catch { _ => return None }
    let json = @json.parse(text) catch { _ => return None }
    guard json is Object(fields) else { return None }
    return json_field_string(fields, "name")
  }
  None
}

///|
/// Directories holding a package manifest, relative to the module root —
/// `"."` for the module root itself. Used to map a source file to its
/// owning package dir.
async fn collect_pkg_dirs(root : String) -> Map[String, Bool] {
  let dirs : Map[String, Bool] = Map([])
  let stack : Array[String] = ["."]
  while stack.length() > 0 {
    let dir = match stack.pop() {
      Some(dir) => dir
      None => break
    }
    let abs = if dir == "." { root } else { path_join(root, dir) }
    if @fs.exists(path_join(abs, "moon.pkg")) ||
      @fs.exists(path_join(abs, "moon.pkg.json")) {
      dirs[dir] = true
    }
    for name in @fs.readdir(abs, include_hidden=true, sort=false) {
      let full = path_join(abs, name)
      let kind = @fs.kind(full) catch { _ => continue }
      guard kind is Directory else { continue }
      if should_skip_dir(name) {
        continue
      }
      if is_nested_module(full) {
        continue
      }
      stack.push(if dir == "." { name } else { dir + "/" + name })
    }
  }
  dirs
}

///|
/// Owning package dir of a module-relative source path — the deepest
/// manifest dir containing it.
fn pkg_dir_of(pkg_dirs : Map[String, Bool], path : String) -> String {
  let path = path.replace_all(old="\\", new="/")
  let mut best = "."
  for dir, _ in pkg_dirs {
    let contains = if dir == "." { true } else { path.has_prefix(dir + "/") }
    if contains && dir.length() > best.length() {
      best = dir
    }
  }
  if best == "." && !pkg_dirs.contains(".") {
    // No manifest at the root: sources are still attributed to "." so the
    // witness manifest patch has somewhere to write.
    return "."
  }
  best
}

///|
/// Find `import { ... }` blocks in moon.pkg text and return (content
/// range, whether a `for "..."` scope follows the closing brace) for each.
fn pkg_import_blocks(text : String) -> Array[((Int, Int), Bool)] {
  let bytes = @utf8.encode(text)
  let blocks : Array[((Int, Int), Bool)] = []
  let mut i = 0
  let n = bytes.length()
  while i < n {
    // match the `import` keyword on an identifier boundary
    if bytes[i] == b'i' &&
      i + 6 <= n &&
      @utf8.decode_lossy(bytes[i:i + 6]) == "import" &&
      (i + 6 >= n || !(bytes[i + 6] >= b'a' && bytes[i + 6] <= b'z')) {
      let mut j = i + 6
      while j < n &&
            (
              bytes[j] == b' ' ||
              bytes[j] == b'\n' ||
              bytes[j] == b'\t' ||
              bytes[j] == b'\r'
            ) {
        j = j + 1
      }
      if j < n && bytes[j] == b'{' {
        let open = j
        let mut depth = 1
        j = j + 1
        while j < n && depth > 0 {
          if bytes[j] == b'{' {
            depth = depth + 1
          } else if bytes[j] == b'}' {
            depth = depth - 1
          }
          j = j + 1
        }
        let close = j - 1
        // skip whitespace after '}' and detect a `for` scope qualifier
        let mut k = j
        while k < n &&
              (
                bytes[k] == b' ' ||
                bytes[k] == b'\n' ||
                bytes[k] == b'\t' ||
                bytes[k] == b'\r'
              ) {
          k = k + 1
        }
        let scoped = k + 3 <= n && @utf8.decode_lossy(bytes[k:k + 3]) == "for"
        blocks.push(((open + 1, close), scoped))
        i = k
      } else {
        i = j
      }
    } else {
      i = i + 1
    }
  }
  blocks
}

///|
/// Extract `"path"` strings inside a moon.pkg import-block content range.
fn pkg_import_paths(text : String, start : Int, end : Int) -> Array[String] {
  let bytes = @utf8.encode(text)
  let paths : Array[String] = []
  let mut i = if start < 0 { 0 } else { start }
  let limit = if end > bytes.length() { bytes.length() } else { end }
  while i < limit {
    if bytes[i] == b'"' {
      let mut j = i + 1
      let mut stop = -1
      while j < limit {
        if bytes[j] == b'"' {
          stop = j
          break
        }
        if bytes[j] == b'\\' {
          j = j + 1
        }
        j = j + 1
      }
      if stop < 0 {
        break
      }
      paths.push(@utf8.decode_lossy(bytes[i + 1:stop]))
      i = stop + 1
    } else {
      i = i + 1
    }
  }
  paths
}

///|
/// Use Moon's manifest parser for import paths, aliases and scopes.
/// This keeps comments, whitespace and repeated blocks from masquerading
/// as imports. Malformed manifests grant no analysis permissions.
fn pkg_text_import_entries(
  text : String,
  scope : String,
) -> Array[(String, String?)] {
  let (ast, reports) = @moon_config.parse_moon_pkg(text)
  if !reports.is_empty() {
    return []
  }
  guard ast is @moon_config.Ast::Obj(fields, ..) else { return [] }
  let entries : Array[(String, String?)] = []
  for field in fields {
    let (key, value) = field
    if key != "import" && (scope == "source" || key != "\{scope}-import") {
      continue
    }
    guard value is @moon_config.Ast::Arr(items, ..) else { continue }
    for item in items {
      match item {
        @moon_config.Ast::Str(path, ..) => entries.push((path, None))
        @moon_config.Ast::Obj(props, ..) => {
          let mut path : String? = None
          let mut import_alias : String? = None
          for prop in props {
            let (name, value) = prop
            match value {
              @moon_config.Ast::Str(text, ..) =>
                if name == "path" {
                  path = Some(text)
                } else if name == "alias" {
                  import_alias = Some(text)
                }
              _ => ()
            }
          }
          match path {
            Some(path) => entries.push((path, import_alias))
            None => ()
          }
        }
        _ => ()
      }
    }
  }
  entries
}

///|
fn pkg_json_import_entries(
  text : String,
  key : String,
) -> Array[(String, String?)] {
  let json = @json.parse(text) catch { _ => return [] }
  guard json is Object(fields) else { return [] }
  guard fields.get(key) is Some(Array(entries)) else { return [] }
  let imports : Array[(String, String?)] = []
  for entry in entries {
    match entry {
      String(path) => imports.push((path, None))
      Object(obj) =>
        match json_field_string(obj, "path") {
          Some(path) => imports.push((path, json_field_string(obj, "alias")))
          None => ()
        }
      _ => ()
    }
  }
  imports
}

///|
/// Read imports visible to the requested compilation scope. Preserve
/// external identities: qualifier spelling alone never establishes purity.
async fn pkg_import_map(
  root : String,
  dir : String,
  module_name : String?,
  pkg_dirs : Map[String, Bool],
  scope : String,
) -> Map[String, String] {
  let imports : Map[String, String] = Map([])
  let abs = if dir == "." { root } else { path_join(root, dir) }
  let text_pkg = path_join(abs, "moon.pkg")
  let json_pkg = path_join(abs, "moon.pkg.json")
  let raw_entries : Array[(String, String?)] = []
  if @fs.exists(text_pkg) {
    let text = @fs.read_file(text_pkg).text() catch { _ => "" }
    for entry in pkg_text_import_entries(text, scope) {
      raw_entries.push(entry)
    }
  }
  if @fs.exists(json_pkg) {
    let text = @fs.read_file(json_pkg).text() catch { _ => "" }
    for entry in pkg_json_import_entries(text, "import") {
      raw_entries.push(entry)
    }
    if scope != "source" {
      for entry in pkg_json_import_entries(text, "\{scope}-import") {
        raw_entries.push(entry)
      }
    }
  }
  for (path, as_name) in raw_entries {
    let bound_alias = match as_name {
      Some(name) => name
      None =>
        match path.rev_find("/") {
          Some(slash) => path[slash + 1:].to_owned()
          None => path
        }
    }
    let mut resolved = path
    match module_name {
      Some(name) => {
        let prefix = name + "/"
        if path == name {
          resolved = "."
        } else if path.has_prefix(prefix) {
          let rest = path[prefix.length():].to_owned()
          if pkg_dirs.contains(rest) {
            resolved = rest
          }
        }
      }
      None => ()
    }
    imports[bound_alias] = resolved
  }
  let self_name = if dir == "." {
    match module_name {
      Some(name) => name
      None => dir
    }
  } else {
    dir
  }
  let self_alias = match self_name.rev_find("/") {
    Some(slash) => self_name[slash + 1:].to_owned()
    None => self_name
  }
  if !imports.contains(self_alias) {
    imports[self_alias] = dir
  }
  imports
}

///|
/// Extract the per-fn facts one `fn` declaration carries: parameter call
/// shapes + type text (for harness/suggestion codegen), async/cfg/generic
/// markers, and byte spans for the original-body clone.
fn fn_info_of(
  pkg : String,
  file : String,
  bytes : Bytes,
  boundaries : Array[Int],
  fun_decl : @syntax.FunDecl,
  decl_body : @syntax.DeclBody,
  loc : @basic.Location,
) -> FnInfo {
  let params : Array[FnParamInfo] = []
  let mut params_ok = true
  match fun_decl.decl_params {
    Some(decl_params) =>
      for param in decl_params {
        match param {
          @syntax.Parameter::Positional(binder~, ty~) =>
            match ty {
              Some(ty) => {
                let (ty_start, ty_end) = loc_bytes(boundaries, ty.loc())
                params.push({
                  label: None,
                  name: binder.name,
                  ty,
                  ty_text: @utf8.decode_lossy(bytes[ty_start:ty_end]),
                })
              }
              None => params_ok = false
            }
          @syntax.Parameter::DiscardPositional(ty~, ..) =>
            match ty {
              Some(ty) => {
                let (ty_start, ty_end) = loc_bytes(boundaries, ty.loc())
                params.push({
                  label: None,
                  name: "_",
                  ty,
                  ty_text: @utf8.decode_lossy(bytes[ty_start:ty_end]),
                })
              }
              None => params_ok = false
            }
          @syntax.Parameter::Labelled(binder~, ty~) =>
            match ty {
              Some(ty) => {
                let (ty_start, ty_end) = loc_bytes(boundaries, ty.loc())
                params.push({
                  label: Some(binder.name),
                  name: binder.name,
                  ty,
                  ty_text: @utf8.decode_lossy(bytes[ty_start:ty_end]),
                })
              }
              None => params_ok = false
            }
          // Optional parameters carry defaults the harness would have to
          // reproduce — skip rather than guess.
          @syntax.Parameter::Optional(..)
          | @syntax.Parameter::QuestionOptional(..) => params_ok = false
        }
      }
    None => ()
  }
  let mut cfg = false
  for attr in fun_decl.attrs {
    if attr.raw.has_prefix("#cfg") {
      cfg = true
      break
    }
  }
  let (impl_start, impl_end) = loc_bytes(boundaries, loc)
  let (name_start, name_end) = loc_bytes(boundaries, fun_decl.name.loc)
  {
    pkg,
    name: fun_decl.name.name,
    file,
    is_async: fun_decl.is_async is Some(_),
    cfg,
    generic: !fun_decl.quantifiers.is_empty(),
    params_ok,
    params,
    ret: fun_decl.return_type,
    ret_text: match fun_decl.return_type {
      Some(ty) => {
        let (s, e) = loc_bytes(boundaries, ty.loc())
        @utf8.decode_lossy(bytes[s:e])
      }
      None => ""
    },
    stub: !(decl_body is @syntax.DeclBody(_)),
    impl_start,
    impl_end,
    name_start,
    name_end,
    edges: [],
    effects_unknown: false,
  }
}

///|
/// Pass 1 of the module index: parse every non-test source, collect the
/// top-level tables (fns, lets, symbols, test names) per package.
async fn index_pass1(
  root : String,
  pkg_dirs : Map[String, Bool],
) -> (
  Map[String, PkgIndex],
  Map[String, Array[FnInfo]],
  Map[String, @syntax.DeclBody],
) {
  let pkgs : Map[String, PkgIndex] = Map([])
  let fns_by_file : Map[String, Array[FnInfo]] = Map([])
  let bodies : Map[String, @syntax.DeclBody] = Map([])
  let module_name = module_name_of(root)
  let import_maps : Map[
    String,
    (Map[String, String], Map[String, String], Map[String, String]),
  ] = Map([])
  for dir, _ in pkg_dirs {
    import_maps[dir] = (
      pkg_import_map(root, dir, module_name, pkg_dirs, "source"),
      pkg_import_map(root, dir, module_name, pkg_dirs, "test"),
      pkg_import_map(root, dir, module_name, pkg_dirs, "wbtest"),
    )
  }
  let pkg_of = (dir : String) => {
    match pkgs.get(dir) {
      Some(existing) => existing
      None => {
        let (imports, test_imports, wbtest_imports) = match
          import_maps.get(dir) {
          Some(pair) => pair
          None => (Map([]), Map([]), Map([]))
        }
        let created : PkgIndex = {
          dir,
          fns: Map([]),
          lets: Map([]),
          symbols: Map([]),
          tests: Map([]),
          imports,
          test_imports,
          wbtest_imports,
        }
        pkgs[dir] = created
        created
      }
    }
  }
  let files : Array[String] = []
  collect_moonbit_files(root, root, None, default_project_config(), files)
  for file in files {
    let source = @fs.read_file(path_join(root, file)).text() catch {
      _ => continue
    }
    let (impls, reports) = @parser.parse_string(source, name=file)
    if reports.length() != 0 {
      continue
    }
    let dir = pkg_dir_of(pkg_dirs, file)
    let pkg = pkg_of(dir)
    let bytes = @utf8.encode(source)
    let boundaries = source_byte_boundaries(bytes)
    for impl_ in impls {
      match impl_ {
        @syntax.Impl::TopFuncDef(fun_decl~, decl_body~, ..) => {
          let entry = fn_info_of(
            dir,
            file,
            bytes,
            boundaries,
            fun_decl,
            decl_body,
            impl_.loc(),
          )
          pkg.fns[entry.name] = entry
          pkg.symbols[entry.name] = true
          bodies[fn_node(dir, entry.name)] = decl_body
          match fns_by_file.get(file) {
            Some(list) => list.push(entry)
            None => fns_by_file[file] = [entry]
          }
        }
        @syntax.Impl::TopLetDef(binder~, ty~, ..) => {
          pkg.lets[binder.name] = ty
          pkg.symbols[binder.name] = true
        }
        @syntax.Impl::TopTypeDef(decl) => pkg.symbols[decl.tycon] = true
        @syntax.Impl::TopTrait(decl) => pkg.symbols[decl.name.name] = true
        @syntax.Impl::TopImpl(method_name~, ..) =>
          pkg.symbols[method_name.name] = true
        @syntax.Impl::TopView(view_func_name~, ..) =>
          pkg.symbols[view_func_name.name] = true
        @syntax.Impl::TopExtend(names~, ..) =>
          for target in names {
            pkg.symbols[target.binder.name] = true
          }
        @syntax.Impl::TopTest(name~, ..) =>
          match name {
            Some((literal, _)) => pkg.tests[literal] = true
            None => ()
          }
        _ => ()
      }
    }
  }
  (pkgs, fns_by_file, bodies)
}

///|
/// Resolve one fn body against its package tables: bare idents become
/// edges (same-package fns), let references (value-typed only), local
/// binders, or unknowns; qualified `pkg.name` uses the import map or the
/// pure-core allowlist.
fn resolve_fn_effects(
  entry : FnInfo,
  body : @syntax.DeclBody,
  pkg : PkgIndex,
  pkgs : Map[String, PkgIndex],
) -> Unit {
  guard body is @syntax.DeclBody(expr~) else {
    entry.effects_unknown = true
    return
  }
  let visitor = FnBodyVisitor::new()
  @syntax.IterVisitor::visit_Expr(visitor, expr)
  for name, _ in visitor.idents {
    if pkg.lets.contains(name) {
      match pkg.lets.get(name) {
        Some(Some(ty)) => if !is_value_type(ty) { entry.effects_unknown = true }
        _ => entry.effects_unknown = true
      }
    } else if pkg.fns.contains(name) {
      entry.edges.push((pkg.dir, name))
    } else if !visitor.fresh.contains(name) && !param_named(entry, name) {
      // Not bound locally, not a known package-level name: imported via
      // `use`, a trait method in scope, or something else the check
      // cannot decide.
      entry.effects_unknown = true
    }
  }
  for qual, ids in visitor.dots {
    match pkg.imports.get(qual) {
      Some(dir) =>
        match pkgs.get(dir) {
          Some(target) =>
            for id in ids {
              if target.fns.contains(id) {
                entry.edges.push((dir, id))
              } else if target.lets.contains(id) {
                match target.lets.get(id) {
                  Some(Some(ty)) =>
                    if !is_value_type(ty) {
                      entry.effects_unknown = true
                    }
                  _ => entry.effects_unknown = true
                }
              } else {
                // Type/trait/other top-level names in a sibling package:
                // not a callable edge but not decidable either.
                entry.effects_unknown = true
              }
            }
          None => {
            let core_prefix = "moonbitlang/core/"
            if !dir.has_prefix(core_prefix) ||
              !pure_core_pkg(dir[core_prefix.length():].to_owned()) {
              entry.effects_unknown = true
            }
          }
        }
      None =>
        // Not allowlisted and not a module-local package: @env, @fs,
        // @random, @time, FFI facades — always disqualifying.
        entry.effects_unknown = true
    }
  }
  if visitor.effects_unknown {
    entry.effects_unknown = true
  }
}

///|
fn param_named(entry : FnInfo, name : String) -> Bool {
  for param in entry.params {
    if param.name == name {
      return true
    }
  }
  false
}

///|
/// Reachable set over the module-local call graph, including the start
/// node. Node ids are `pkg\x01name`.
fn reachable_from(
  index : ModuleIndex,
  start_pkg : String,
  start_name : String,
) -> Map[String, Bool] {
  let seen : Map[String, Bool] = Map([])
  let stack : Array[(String, String)] = [(start_pkg, start_name)]
  while stack.length() > 0 {
    let (dir, name) = match stack.pop() {
      Some(node) => node
      None => break
    }
    let id = fn_node(dir, name)
    if seen.contains(id) {
      continue
    }
    seen[id] = true
    match index.pkgs.get(dir) {
      Some(pkg) =>
        match pkg.fns.get(name) {
          Some(entry) =>
            for edge in entry.edges {
              let (edir, ename) = edge
              if !seen.contains(fn_node(edir, ename)) {
                stack.push(edge)
              }
            }
          None => ()
        }
      None => ()
    }
  }
  seen
}

///|
/// Node ids sitting in a recursive SCC (or with a self edge) — detected by
/// reachability: a fn is recursive iff it reaches itself.
fn find_recursive_nodes(index : ModuleIndex) -> Map[String, Bool] {
  let recursive : Map[String, Bool] = Map([])
  for dir, pkg in index.pkgs {
    for name, _ in pkg.fns {
      let id = fn_node(dir, name)
      if recursive.contains(id) {
        continue
      }
      // f is recursive iff one of its own callees can reach back to it —
      // reachability alone always contains the start node itself.
      let entry = pkg.fns[name]
      let mut hits = false
      for edge in entry.edges {
        let (edir, ename) = edge
        if reachable_from(index, edir, ename).contains(id) {
          hits = true
          break
        }
      }
      if hits {
        // f reaches itself: mark the whole reachable SCC cheaply — every
        // node g in reach for which f is in reach(g) shares the cycle.
        let reach = reachable_from(index, dir, name)
        for (gdir, gname) in node_list(reach) {
          let g_reach = reachable_from(index, gdir, gname)
          if g_reach.contains(id) {
            recursive[fn_node(gdir, gname)] = true
          }
        }
      }
    }
  }
  recursive
}

///|
fn node_list(nodes : Map[String, Bool]) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for id, _ in nodes {
    match id.find("\u{1}") {
      Some(at) => out.push((id[:at].to_owned(), id[at + 1:].to_owned()))
      None => ()
    }
  }
  out
}

///|
/// Build the module index from the *reference* (pristine) workspace —
/// sources, package manifests, and the module name.
async fn build_module_index(root : String) -> ModuleIndex {
  let pkg_dirs = collect_pkg_dirs(root)
  let (pkgs, fns_by_file, bodies) = index_pass1(root, pkg_dirs)
  let index : ModuleIndex = { pkgs, pkg_dirs, fns_by_file, recursive: Map([]), }
  for dir, pkg in pkgs {
    for name, entry in pkg.fns {
      match bodies.get(fn_node(dir, name)) {
        Some(body) => resolve_fn_effects(entry, body, pkg, pkgs)
        None => ()
      }
    }
  }
  let recursive = find_recursive_nodes(index)
  { pkgs, pkg_dirs, fns_by_file, recursive, }
}

///|
/// The top-level `fn` whose body span encloses the mutation, or None when
/// the mutant lives in a test block, impl method, top-level let, main, or
/// any other non-fn declaration.
fn enclosing_fn(index : ModuleIndex, mutation : Mutation) -> FnInfo? {
  match index.fns_by_file.get(mutation.path) {
    None => None
    Some(fns) => {
      for entry in fns {
        if mutation.start >= entry.impl_start && mutation.end <= entry.impl_end {
          return Some(entry)
        }
      }
      None
    }
  }
}

///|
/// Skip reasons the witness reports on the survivor row.
enum WitnessSkip {
  EffectsUnknown
  Recursive
  Cfg
  NameCollision
  Nondeterministic
  HarnessError
} derive(Eq)

///|
fn witness_skip_name(skip : WitnessSkip) -> String {
  match skip {
    EffectsUnknown => "effects-unknown"
    Recursive => "recursive"
    Cfg => "cfg"
    NameCollision => "name-collision"
    Nondeterministic => "nondeterministic"
    HarnessError => "harness-error"
  }
}

///|
/// Eligibility of one survivor's enclosing fn for the differential
/// witness: signature shape (concrete immutable value types in and out,
/// no generics, no async, a real body), `#cfg`, own-recursion, and the
/// effects flags of every reachable fn.
fn witness_eligible(index : ModuleIndex, entry : FnInfo) -> WitnessSkip? {
  if entry.cfg {
    return Some(Cfg)
  }
  if entry.is_async || entry.generic || entry.stub || !entry.params_ok {
    return Some(EffectsUnknown)
  }
  for param in entry.params {
    if !is_value_type(param.ty) {
      return Some(EffectsUnknown)
    }
  }
  match entry.ret {
    Some(ty) => if !is_value_type(ty) { return Some(EffectsUnknown) }
    None => ()
  }
  if index.recursive.contains(fn_node(entry.pkg, entry.name)) {
    return Some(Recursive)
  }
  let reach = reachable_from(index, entry.pkg, entry.name)
  for (dir, name) in node_list(reach) {
    match index.pkgs.get(dir) {
      Some(pkg) =>
        match pkg.fns.get(name) {
          Some(entry) =>
            if entry.is_async || entry.stub || entry.effects_unknown {
              return Some(EffectsUnknown)
            }
          None => return Some(EffectsUnknown)
        }
      None => return Some(EffectsUnknown)
    }
  }
  None
}

///|
/// Whether a survivor's enclosing fn qualifies for property suggestions:
/// every parameter and the return type must be arbitrable (Arbitrary +
/// Shrink + Debug in core quickcheck). Generics and unannotated/optional
/// params disqualify.
fn suggestible(entry : FnInfo) -> Bool {
  if !entry.params_ok || entry.is_async || entry.stub {
    return false
  }
  for param in entry.params {
    if !is_arbitrable_type(param.ty) {
      return false
    }
  }
  match entry.ret {
    Some(ty) => is_arbitrable_type(ty)
    None => false
  }
}
