import glance
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleeunit/should
import graded/internal/signatures
import graded/internal/types.{QualifiedName}
import simplifile

// Glance AST detection
//
// Detecting fn-typed parameters and record fields straight from a parsed
// glance module, since that syntax-level pass is what feeds the registry.

pub fn glance_detects_fn_typed_param_test() {
  let source =
    "
pub fn apply(f: fn(Int) -> Int, x: Int) -> Int {
  f(x)
}
"
  let assert Ok(module) = glance.module(source)
  let assert [definition] = module.functions
  signatures.ordered_callback_params(
    definition.definition,
    signatures.type_alias_map(module.type_aliases),
    set.new(),
  )
  |> should.equal(["f"])
}

pub fn glance_skips_non_fn_params_test() {
  let source =
    "
pub fn greet(name: String) -> String {
  name
}
"
  let assert Ok(module) = glance.module(source)
  let assert [definition] = module.functions
  signatures.ordered_callback_params(
    definition.definition,
    signatures.type_alias_map(module.type_aliases),
    set.new(),
  )
  |> should.equal([])
}

pub fn glance_skips_unannotated_params_test() {
  let source =
    "
pub fn apply(f, x) {
  f(x)
}
"
  let assert Ok(module) = glance.module(source)
  let assert [definition] = module.functions
  signatures.ordered_callback_params(
    definition.definition,
    signatures.type_alias_map(module.type_aliases),
    set.new(),
  )
  |> should.equal([])
}

pub fn glance_detects_multiple_fn_typed_params_test() {
  let source =
    "
pub fn apply2(f: fn(Int) -> Int, g: fn(Int) -> Int, x: Int) -> Int {
  g(f(x))
}
"
  let assert Ok(module) = glance.module(source)
  let assert [definition] = module.functions
  signatures.ordered_callback_params(
    definition.definition,
    signatures.type_alias_map(module.type_aliases),
    set.new(),
  )
  |> should.equal(["f", "g"])
}

pub fn glance_detects_fn_typed_record_field_test() {
  let source =
    "
pub type Runner {
  Runner(run: fn() -> Nil, name: String)
}
"
  let assert Ok(module) = glance.module(source)
  signatures.fn_typed_fields_from_module(module, alias_map_of(module))
  |> should.equal(set.from_list([#("Runner", "run")]))
}

pub fn glance_detects_fn_typed_field_via_alias_test() {
  // A field declared through a module-local function alias (`run: Action` with
  // `type Action = fn() -> Nil`) is callable, so it is recorded — the alias is
  // chased through the module's own alias map, as a parameter's is.
  let source =
    "
pub type Action = fn() -> Nil

pub type Runner {
  Runner(run: Action)
}
"
  let assert Ok(module) = glance.module(source)
  signatures.fn_typed_fields_from_module(module, alias_map_of(module))
  |> should.equal(set.from_list([#("Runner", "run")]))
}

pub fn glance_skips_unlabelled_fn_typed_field_test() {
  // An unlabelled `fn`-typed field can't be reached by a `record.field(..)`
  // call, so it isn't recorded.
  let source =
    "
pub type Wrapped {
  Wrapped(fn() -> Nil)
}
"
  let assert Ok(module) = glance.module(source)
  signatures.fn_typed_fields_from_module(module, alias_map_of(module))
  |> should.equal(set.new())
}

// Callable-field signatures
//
// The shape a field `check` measures a construction site against: the field's
// own arity, and for each fn-typed parameter that parameter's own callback
// positions. Keyed per variant, because variants of one type may give a label
// different types.

fn field_index_of(source: String) -> types.FieldIndex {
  let assert Ok(module) = glance.module(source)
  signatures.field_index_from_module("app", module, alias_map_of(module))
}

fn callable_fields(
  source: String,
) -> dict.Dict(#(String, String, String, String), types.CallableFieldSignature) {
  field_index_of(source).callable
}

pub fn callable_field_records_arity_and_callbacks_test() {
  callable_fields(
    "
pub type Handler {
  Handler(run: fn(String) -> Nil, name: String)
}
",
  )
  |> should.equal(
    dict.from_list([
      #(
        #("app", "Handler", "Handler", "run"),
        types.CallableFieldSignature(arity: 1, callbacks: []),
      ),
    ]),
  )
}

pub fn callable_field_records_a_nested_callback_shape_test() {
  // `op`'s source arity is two, but only its second parameter is fn-typed —
  // so the constant operator standing in for an unconstrained `op` needs one
  // effect binder, not two. A flat position list cannot say that.
  callable_fields(
    "
pub type Handler {
  Handler(run: fn(fn(Int, fn() -> Nil) -> Nil) -> Nil)
}
",
  )
  |> should.equal(
    dict.from_list([
      #(
        #("app", "Handler", "Handler", "run"),
        types.CallableFieldSignature(arity: 1, callbacks: [#(0, [1])]),
      ),
    ]),
  )
}

pub fn callable_field_is_keyed_per_variant_test() {
  // One label, two variants, two arities: a site is measured against the
  // signature of the variant it builds.
  callable_fields(
    "
pub type Handler {
  Simple(run: fn() -> Nil)
  Detailed(run: fn(String, Int) -> Nil)
}
",
  )
  |> should.equal(
    dict.from_list([
      #(
        #("app", "Handler", "Simple", "run"),
        types.CallableFieldSignature(arity: 0, callbacks: []),
      ),
      #(
        #("app", "Handler", "Detailed", "run"),
        types.CallableFieldSignature(arity: 2, callbacks: []),
      ),
    ]),
  )
}

pub fn field_index_records_every_labelled_field_test() {
  // Callable or not: a `check` naming a field that exists and is not callable
  // is a different diagnostic from one naming no field at all.
  field_index_of(
    "
pub type Handler {
  Handler(run: fn() -> Nil, name: String, fn() -> Nil)
}
",
  ).labels
  |> should.equal(
    set.from_list([#("app", "Handler", "run"), #("app", "Handler", "name")]),
  )
}

pub fn field_index_maps_each_variant_to_its_type_test() {
  // A construction site names its variant while a `check` names the type.
  field_index_of(
    "
pub type Handler {
  Simple(run: fn() -> Nil)
  Detailed(run: fn() -> Nil)
}
",
  ).variant_types
  |> should.equal(
    dict.from_list([
      #(#("app", "Simple"), "Handler"),
      #(#("app", "Detailed"), "Handler"),
    ]),
  )
}

pub fn callable_field_resolves_an_alias_test() {
  callable_fields(
    "
pub type Action = fn(String) -> Nil

pub type Handler {
  Handler(run: Action)
}
",
  )
  |> should.equal(
    dict.from_list([
      #(
        #("app", "Handler", "Handler", "run"),
        types.CallableFieldSignature(arity: 1, callbacks: []),
      ),
    ]),
  )
}

pub fn callable_fields_skip_unlabelled_and_plain_fields_test() {
  callable_fields(
    "
pub type Handler {
  Handler(fn() -> Nil, name: String)
}
",
  )
  |> should.equal(dict.new())
}

// Alias-aware return-type resolution (Fix A)
//
// Resolving a producer's return type to its underlying function type through
// module-local aliases, keeping callback positions.

fn alias_map_of(module: glance.Module) -> dict.Dict(String, glance.Type) {
  signatures.type_alias_map(module.type_aliases)
}

fn return_type_of(module: glance.Module, name: String) -> glance.Type {
  let assert Ok(def) =
    list.find(module.functions, fn(d) { d.definition.name == name })
  let assert Some(rt) = def.definition.return
  rt
}

pub fn resolve_function_type_direct_alias_test() {
  let source =
    "
pub type R = fn() -> Nil
pub fn make() -> R { fn() { Nil } }
"
  let assert Ok(module) = glance.module(source)
  let map = alias_map_of(module)
  let rt = return_type_of(module, "make")
  signatures.resolve_function_type(rt, map) |> should.be_ok()
  signatures.returned_callback_positions(rt, map) |> should.equal(Ok([]))
}

pub fn resolve_function_type_chained_alias_test() {
  let source =
    "
pub type A = B
pub type B = fn() -> Nil
pub fn make() -> A { fn() { Nil } }
"
  let assert Ok(module) = glance.module(source)
  let map = alias_map_of(module)
  signatures.resolve_function_type(return_type_of(module, "make"), map)
  |> should.be_ok()
}

pub fn resolve_function_type_cyclic_alias_terminates_test() {
  let source =
    "
pub type A = B
pub type B = A
pub fn make() -> A { fn() { Nil } }
"
  let assert Ok(module) = glance.module(source)
  let map = alias_map_of(module)
  signatures.resolve_function_type(return_type_of(module, "make"), map)
  |> should.be_error()
}

pub fn resolve_function_type_non_function_alias_test() {
  let source =
    "
pub type Id = Int
pub fn make() -> Id { 1 }
"
  let assert Ok(module) = glance.module(source)
  let map = alias_map_of(module)
  signatures.resolve_function_type(return_type_of(module, "make"), map)
  |> should.be_error()
}

pub fn returned_callback_positions_operator_outer_test() {
  let source =
    "
pub type Op = fn(fn() -> Nil) -> Nil
pub fn make() -> Op { fn(_cb) { Nil } }
"
  let assert Ok(module) = glance.module(source)
  let map = alias_map_of(module)
  signatures.returned_callback_positions(return_type_of(module, "make"), map)
  |> should.equal(Ok([0]))
}

pub fn returned_callback_positions_nested_callback_alias_test() {
  // The layer the direct `fn(fn()->Nil)` test does NOT catch: the callback
  // argument is itself an alias, resolved through the alias map.
  let source =
    "
pub type Callback = fn() -> Nil
pub type Op = fn(Callback) -> Nil
pub fn make() -> Op { fn(_cb) { Nil } }
"
  let assert Ok(module) = glance.module(source)
  let map = alias_map_of(module)
  signatures.returned_callback_positions(return_type_of(module, "make"), map)
  |> should.equal(Ok([0]))
}

pub fn resolve_function_type_imported_alias_test() {
  // A return type that references an alias imported from another module is a
  // `NamedType(module: Some(_))`, absent from the local alias map → Error (G4).
  let source =
    "
import foo
pub fn make() -> foo.Resolver { todo }
"
  let assert Ok(module) = glance.module(source)
  let map = alias_map_of(module)
  signatures.resolve_function_type(return_type_of(module, "make"), map)
  |> should.be_error()
}

// Alias-typed parameters in the registry
//
// A parameter spelled through a module-local `fn` alias is the callback its
// underlying type says it is. The registry resolves it at every depth: the
// parameter's own type, an alias of an alias, and the callback positions
// inside an operator parameter's own argument list.

fn params_of(
  source: String,
  function: String,
) -> List(signatures.ParameterInfo) {
  let assert Ok(module) = glance.module(source)
  let assert Some(params) =
    signatures.lookup(
      signatures.from_glance_module("m", module),
      QualifiedName(module: "m", function: function),
    )
  params
}

pub fn registry_reads_an_alias_typed_param_as_fn_typed_test() {
  let assert [param] =
    params_of(
      "
pub type Action = fn() -> Nil
pub fn run(action: Action) -> Nil { action() }
",
      "run",
    )
  param.is_fn_typed |> should.be_true
  param.is_annotated |> should.be_true
  param.is_operator |> should.be_false
  param.callback_positions |> should.equal([])
}

pub fn registry_reads_an_alias_of_an_alias_as_fn_typed_test() {
  let assert [param] =
    params_of(
      "
pub type Action = Runner
pub type Runner = fn() -> Nil
pub fn run(action: Action) -> Nil { action() }
",
      "run",
    )
  param.is_fn_typed |> should.be_true
}

pub fn registry_reads_an_alias_typed_operator_param_test() {
  // Both layers are aliases: the parameter's own type, and the callback it
  // takes. The callback position is read through the inner one.
  let assert [param] =
    params_of(
      "
pub type Callback = fn() -> Nil
pub type Op = fn(Callback) -> Nil
pub fn drive(op: Op) -> Nil { op(fn() { Nil }) }
",
      "drive",
    )
  param.is_fn_typed |> should.be_true
  param.is_operator |> should.be_true
  param.callback_positions |> should.equal([0])
}

pub fn registry_leaves_a_non_function_alias_first_order_test() {
  let assert [param] =
    params_of(
      "
pub type Id = Int
pub fn keep(id: Id) -> Id { id }
",
      "keep",
    )
  param.is_fn_typed |> should.be_false
  param.is_annotated |> should.be_true
}

pub fn operator_param_shapes_resolve_aliases_at_every_depth_test() {
  // `op`'s type, its callback, and that callback's own callback are each
  // spelled through an alias.
  let source =
    "
pub type Inner = fn() -> Nil
pub type Callback = fn(Inner) -> Nil
pub type Op = fn(Callback) -> Nil
pub fn drive(op: Op) -> Nil { todo }
"
  let assert Ok(module) = glance.module(source)
  let assert Ok(definition) =
    list.find(module.functions, fn(d) { d.definition.name == "drive" })
  signatures.operator_param_shapes(definition.definition, alias_map_of(module))
  |> should.equal(dict.from_list([#("op", [#(0, [0])])]))
}

// Parsing a dependency source tree
//
// Walking a dependency's `src/` on disk, using a temporary fake package
// directory, and folding what comes back into a registry.

fn registry_from_source_dir(
  source_dir: String,
) -> signatures.SignatureRegistry {
  use acc, module_path, _source_path, parsed <- signatures.fold_source_dir(
    source_dir,
    signatures.empty(),
  )
  case parsed {
    Ok(module) ->
      signatures.merge(acc, signatures.from_glance_module(module_path, module))
    Error(Nil) -> acc
  }
}

pub fn parse_source_dir_walks_dep_sources_test() {
  let dir = "/tmp/graded_signatures_test_pkgs"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) =
    simplifile.create_directory_all(dir <> "/fake_dep/src/fake")
  let assert Ok(Nil) =
    simplifile.write(
      dir <> "/fake_dep/src/fake/list.gleam",
      "pub fn map(items: List(a), f: fn(a) -> b) -> List(b) {
  todo
}
",
    )

  let registry = registry_from_source_dir(dir <> "/fake_dep/src")
  let params = signatures.lookup(registry, QualifiedName("fake/list", "map"))
  let assert Some([_items, f_param]) = params
  f_param.is_fn_typed |> should.be_true()
  f_param.position |> should.equal(1)

  let _ = simplifile.delete(dir)
  Nil
}

pub fn parse_source_dir_skips_missing_src_test() {
  let dir = "/tmp/graded_signatures_test_skip"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir <> "/erlang_only")

  let registry = registry_from_source_dir(dir <> "/erlang_only/src")
  signatures.lookup(registry, QualifiedName("anything", "foo"))
  |> should.equal(None)

  let _ = simplifile.delete(dir)
  Nil
}

// The accessor index
//
// What each custom type's declaration grants, keyed by type rather than by
// label: whether the type was indexed at all, every label any variant declares,
// and whether the declaration is opaque.

fn accessors_of(
  source: String,
  module_path: String,
) -> signatures.SignatureRegistry {
  let assert Ok(module) = glance.module(source)
  signatures.from_glance_module(module_path, module)
}

pub fn accessor_index_unions_labels_across_variants_test() {
  // The union, not the intersection: a label on one variant of two is reachable
  // through a pattern that narrows to it, so the type does grant it.
  let registry =
    accessors_of(
      "
pub type Partial {
  A(map: fn(Int) -> Int)
  B(n: Int)
}
",
      "m",
    )
  let assert Some(info) = signatures.accessor_info(registry, #("m", "Partial"))
  info.any_label |> should.equal(set.from_list(["map", "n"]))
  info.opaque_ |> should.be_false()
}

pub fn accessor_index_holds_a_type_with_no_labelled_fields_test() {
  // "Indexed, and declares no such label" has to be distinguishable from "never
  // indexed", so a labelless type still gets an entry.
  let registry =
    accessors_of(
      "
pub type Colour {
  Red
  Green
}

pub type Pair {
  Pair(Int, Int)
}
",
      "m",
    )
  let assert Some(colour) = signatures.accessor_info(registry, #("m", "Colour"))
  colour.any_label |> should.equal(set.new())
  let assert Some(pair) = signatures.accessor_info(registry, #("m", "Pair"))
  pair.any_label |> should.equal(set.new())
  signatures.accessor_info(registry, #("m", "Absent")) |> should.equal(None)
}

pub fn accessor_index_carries_opacity_test() {
  let registry =
    accessors_of(
      "
pub opaque type Hidden {
  Hidden(map: fn(Int) -> Int)
}
",
      "m",
    )
  let assert Some(info) = signatures.accessor_info(registry, #("m", "Hidden"))
  info.opaque_ |> should.be_true()
  info.any_label |> should.equal(set.from_list(["map"]))
}

pub fn merge_propagates_the_accessor_index_test() {
  // The registry is how the index reaches the checker, so both operands of a
  // merge must survive it.
  let dep =
    accessors_of("pub type Runner { Runner(map: fn(Int) -> Int) }", "dep")
  let project = accessors_of("pub type Thing { Thing(n: Int) }", "m")
  let merged = signatures.merge(dep, project)
  signatures.accessor_info(merged, #("dep", "Runner")) |> should.be_some()
  signatures.accessor_info(merged, #("m", "Thing")) |> should.be_some()
}

pub fn merging_a_single_function_registry_keeps_the_index_test() {
  // The same-module registries put a `from_single_function` registry on the
  // winning side of the merge; its empty index must not erase the real one.
  let assert Ok(module) =
    glance.module(
      "pub type Thing { Thing(n: Int) }
pub fn f(x) { x }",
    )
  let registry = signatures.from_glance_module("m", module)
  let assert [definition] = module.functions
  let local = signatures.from_single_function("m", definition, dict.new())
  signatures.accessor_info(local, #("m", "Thing")) |> should.equal(None)
  signatures.accessor_info(signatures.merge(registry, local), #("m", "Thing"))
  |> should.be_some()
}

pub fn every_prelude_type_is_seeded_into_the_accessor_index_test() {
  // A prelude receiver (`int: Int`) types as `Named("gleam", "Int", [])`, which
  // no module declaration produces — without the seed the index misses it and
  // a call through the shadowing name stays `[Unknown]`. `UtfCodepoint` is the
  // one an enumeration written from memory drops.
  let registry = accessors_of("pub fn f(x) { x }", "m")
  list.each(
    [
      "Int", "Float", "String", "Bool", "Nil", "BitArray", "UtfCodepoint",
      "List", "Result",
    ],
    fn(name) {
      let assert Some(info) =
        signatures.accessor_info(registry, #("gleam", name))
      info.any_label |> should.equal(set.new())
      info.opaque_ |> should.be_false()
    },
  )
}

pub fn the_prelude_seed_survives_a_merge_test() {
  let dep = accessors_of("pub type Runner { Runner(n: Int) }", "dep")
  let project = accessors_of("pub type Thing { Thing(n: Int) }", "m")
  signatures.accessor_info(signatures.merge(dep, project), #("gleam", "Int"))
  |> should.be_some()
}

pub fn a_project_type_named_like_a_prelude_type_keys_apart_test() {
  // The seed is keyed under `gleam`, so a module's own `Result` is its own
  // entry and neither shadows the other.
  let registry =
    accessors_of("pub type Result { Result(map: fn(Int) -> Int) }", "m")
  let assert Some(own) = signatures.accessor_info(registry, #("m", "Result"))
  own.any_label |> should.equal(set.from_list(["map"]))
  let assert Some(prelude) =
    signatures.accessor_info(registry, #("gleam", "Result"))
  prelude.any_label |> should.equal(set.new())
}
