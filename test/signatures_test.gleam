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
  signatures.fn_typed_params_from_function(definition.definition)
  |> should.equal(set.from_list(["f"]))
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
  signatures.fn_typed_params_from_function(definition.definition)
  |> should.equal(set.new())
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
  signatures.fn_typed_params_from_function(definition.definition)
  |> should.equal(set.new())
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
  signatures.fn_typed_params_from_function(definition.definition)
  |> should.equal(set.from_list(["f", "g"]))
}

pub fn glance_detects_fn_typed_record_field_test() {
  let source =
    "
pub type Runner {
  Runner(run: fn() -> Nil, name: String)
}
"
  let assert Ok(module) = glance.module(source)
  signatures.fn_typed_fields_from_module(module, set.new())
  |> should.equal(set.from_list([#("Runner", "run")]))
}

pub fn glance_detects_fn_typed_field_via_alias_test() {
  // A field declared through a module-local function alias (`run: Action` with
  // `type Action = fn() -> Nil`) is callable, so it is recorded when the alias
  // is in the resolved function-alias set.
  let source =
    "
pub type Action = fn() -> Nil

pub type Runner {
  Runner(run: Action)
}
"
  let assert Ok(module) = glance.module(source)
  signatures.fn_typed_fields_from_module(module, set.from_list(["Action"]))
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
  signatures.fn_typed_fields_from_module(module, set.new())
  |> should.equal(set.new())
}

// Alias-aware return-type resolution (Fix A)
//
// Resolving a producer's return type to its underlying function type through
// module-local aliases, keeping callback positions.

fn alias_map_of(module: glance.Module) -> dict.Dict(String, glance.Type) {
  list.fold(module.type_aliases, dict.new(), fn(acc, d) {
    dict.insert(acc, d.definition.name, d.definition.aliased)
  })
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
  signatures.returned_callback_positions(rt, map) |> should.equal([])
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
  |> should.equal([0])
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
  |> should.equal([0])
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

// Loading from a packages directory
//
// Building a signature registry by walking dependency sources on disk, using
// a temporary fake packages directory.

pub fn load_from_packages_dir_walks_dep_sources_test() {
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

  let registry = signatures.load_from_packages_dir(dir)
  let params = signatures.lookup(registry, QualifiedName("fake/list", "map"))
  let assert Some([_items, f_param]) = params
  f_param.is_fn_typed |> should.be_true()
  f_param.position |> should.equal(1)

  let _ = simplifile.delete(dir)
  Nil
}

pub fn load_from_packages_dir_skips_missing_src_test() {
  let dir = "/tmp/graded_signatures_test_skip"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir <> "/erlang_only")

  let registry = signatures.load_from_packages_dir(dir)
  signatures.lookup(registry, QualifiedName("anything", "foo"))
  |> should.equal(None)

  let _ = simplifile.delete(dir)
  Nil
}
