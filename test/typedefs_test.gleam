// The type registry and the three-valued question asked of it: can a value of
// this type hold a function?

import girard
import glance
import gleam/int
import gleam/list
import gleam/set
import gleam/string
import graded
import graded/internal/typedefs.{HasArrows, NoArrows, UnknownShape}
import support

fn registry(module_path: String, source: String) -> typedefs.TypeRegistry {
  registry_on(module_path, source, set.from_list(["erlang", "javascript"]))
}

fn registry_on(
  module_path: String,
  source: String,
  targets: set.Set(String),
) -> typedefs.TypeRegistry {
  let assert Ok(module) = glance.module(source)
  typedefs.from_module(module_path, module, targets)
}

fn named(module: String, name: String, arguments: List(girard.Type)) {
  girard.Named(module:, name:, arguments:)
}

fn int() -> girard.Type {
  named("gleam", "Int", [])
}

fn thunk() -> girard.Type {
  girard.Fn([], named("gleam", "Nil", []))
}

fn shape(
  type_: girard.Type,
  registry: typedefs.TypeRegistry,
) -> typedefs.Shape {
  typedefs.shape(type_, typedefs.shapes(registry, set.new()))
}

// Prelude and structural types

pub fn prelude_scalars_hold_no_function_test() {
  assert shape(int(), typedefs.empty()) == NoArrows
  assert shape(named("gleam", "String", []), typedefs.empty()) == NoArrows
  assert shape(named("gleam", "List", [int()]), typedefs.empty()) == NoArrows
}

pub fn a_function_type_holds_one_test() {
  assert shape(thunk(), typedefs.empty()) == HasArrows
  assert shape(named("gleam", "List", [thunk()]), typedefs.empty()) == HasArrows
  assert shape(named("gleam", "Result", [int(), thunk()]), typedefs.empty())
    == HasArrows
}

pub fn an_open_type_variable_is_unknown_test() {
  assert shape(girard.Var(3), typedefs.empty()) == UnknownShape
  assert shape(named("gleam", "List", [girard.Var(3)]), typedefs.empty())
    == UnknownShape
}

pub fn a_missing_component_is_not_forgotten_beside_an_arrow_test() {
  let tuple = girard.Tuple([thunk(), named("nowhere", "Missing", [])])
  assert shape(tuple, typedefs.empty()) == UnknownShape
  assert shape(girard.Tuple([int(), int()]), typedefs.empty()) == NoArrows
}

pub fn a_missing_definition_is_unknown_test() {
  assert shape(named("app/m", "Ghost", []), typedefs.empty()) == UnknownShape
}

pub fn dynamic_is_unknown_even_as_a_declared_container_test() {
  let dynamic = named("gleam/dynamic", "Dynamic", [])
  assert typedefs.shape(
      dynamic,
      typedefs.shapes(
        typedefs.empty(),
        set.from_list([#("gleam/dynamic", "Dynamic")]),
      ),
    )
    == UnknownShape
}

// Custom types, every field

pub fn every_variant_field_is_read_labelled_or_not_test() {
  let types =
    registry(
      "app/m",
      "pub type Mixed { Mixed(fn() -> Nil, keep: Int) }
pub type Plain { Plain(Int, name: String) Other }",
    )
  assert shape(named("app/m", "Mixed", []), types) == HasArrows
  assert shape(named("app/m", "Plain", []), types) == NoArrows
}

pub fn generic_arguments_are_substituted_test() {
  let types = registry("app/m", "pub type Box(a) { Box(a) }")
  assert shape(named("app/m", "Box", [int()]), types) == NoArrows
  assert shape(named("app/m", "Box", [thunk()]), types) == HasArrows
}

pub fn a_repeated_instance_is_not_a_proof_of_anything_test() {
  let types = registry("app/m", "pub type Box(a) { Box(a) }")
  let inner = named("app/m", "Box", [thunk()])
  assert shape(named("app/m", "Box", [inner]), types) == HasArrows
  let pure = named("app/m", "Box", [int()])
  assert shape(named("app/m", "Box", [pure]), types) == NoArrows
}

pub fn an_alias_expands_with_its_arguments_test() {
  let types =
    registry(
      "app/m",
      "pub type Handler = fn() -> Nil
pub type Pair(a) = #(a, Int)
pub type Holder { Holder(Handler) }",
    )
  assert shape(named("app/m", "Pair", [int()]), types) == NoArrows
  assert shape(named("app/m", "Pair", [thunk()]), types) == HasArrows
  assert shape(named("app/m", "Holder", []), types) == HasArrows
}

pub fn imported_names_resolve_to_their_module_test() {
  let types =
    typedefs.merge(
      registry("app/a", "pub type Inner { Inner(fn() -> Nil) }"),
      registry(
        "app/b",
        "import app/a.{type Inner as Renamed}
import app/a as other
pub type Outer { Outer(Renamed) }
pub type Qualified { Qualified(other.Inner) }",
      ),
    )
  assert shape(named("app/b", "Outer", []), types) == HasArrows
  assert shape(named("app/b", "Qualified", []), types) == HasArrows
}

pub fn an_unplaceable_name_is_unknown_test() {
  let types = registry("app/m", "pub type Holder { Holder(nowhere.Thing) }")
  assert shape(named("app/m", "Holder", []), types) == UnknownShape
}

// Recursion

pub fn a_recursive_type_without_functions_holds_none_test() {
  let types = registry("app/m", "pub type Tree { Leaf(Int) Node(Tree, Tree) }")
  assert shape(named("app/m", "Tree", []), types) == NoArrows
}

pub fn a_recursive_type_with_a_function_holds_one_test() {
  let types =
    registry("app/m", "pub type Chain { End Link(Chain, fn() -> Nil) }")
  assert shape(named("app/m", "Chain", []), types) == HasArrows
}

pub fn mutual_recursion_answers_the_same_from_either_root_test() {
  let types =
    registry(
      "app/m",
      "pub type A { A(B, fn() -> Nil) }
pub type B { B(A) StopB }",
    )
  assert shape(named("app/m", "A", []), types) == HasArrows
  assert shape(named("app/m", "B", []), types) == HasArrows
}

pub fn mutual_recursion_through_a_missing_type_is_unknown_from_either_root_test() {
  let types =
    registry(
      "app/m",
      "pub type C { C(D) StopC }
pub type D { D(C, nowhere.Missing) }",
    )
  assert shape(named("app/m", "C", []), types) == UnknownShape
  assert shape(named("app/m", "D", []), types) == UnknownShape
}

pub fn function_free_mutual_recursion_holds_none_test() {
  let types =
    registry(
      "app/m",
      "pub type E { E(F) StopE }
pub type F { F(E, Int) }",
    )
  assert shape(named("app/m", "E", []), types) == NoArrows
  assert shape(named("app/m", "F", []), types) == NoArrows
}

// Arguments that grow

// `first` up to `until`, exclusive.
fn from(first: Int, until: Int) -> List(Int) {
  case first >= until {
    True -> []
    False -> [first, ..from(first + 1, until)]
  }
}

fn grow(variants: String) -> typedefs.TypeRegistry {
  registry("app/m", "pub type Grow(a) { " <> variants <> " }")
}

fn grow_of(argument: girard.Type) -> girard.Type {
  named("app/m", "Grow", [argument])
}

pub fn a_growing_instantiation_reads_its_arguments_test() {
  let types = grow("Stop(a) More(Grow(List(a)))")
  assert shape(grow_of(int()), types) == NoArrows
  assert shape(grow_of(thunk()), types) == HasArrows
}

pub fn a_doubling_argument_is_read_in_either_variant_order_test() {
  let step_first = grow("Step(inner: Grow(#(a, a))) Leaf(value: a)")
  let leaf_first = grow("Leaf(value: a) Step(inner: Grow(#(a, a)))")
  assert shape(grow_of(int()), step_first) == NoArrows
  assert shape(grow_of(thunk()), step_first) == HasArrows
  assert shape(grow_of(int()), leaf_first) == NoArrows
  assert shape(grow_of(thunk()), leaf_first) == HasArrows
}

pub fn a_tripling_or_listing_argument_is_read_test() {
  let tripling = grow("Step(Grow(#(a, a, a))) Leaf(a)")
  let listing = grow("Step(Grow(List(a))) Leaf(a)")
  assert shape(grow_of(int()), tripling) == NoArrows
  assert shape(grow_of(thunk()), tripling) == HasArrows
  assert shape(grow_of(int()), listing) == NoArrows
  assert shape(grow_of(thunk()), listing) == HasArrows
}

pub fn mutually_recursive_growing_types_answer_from_either_root_test() {
  let types =
    registry(
      "app/m",
      "pub type A(a) { ToB(B(#(a, a))) EndA(a) }
pub type B(b) { ToA(A(List(b))) EndB(b) }",
    )
  assert shape(named("app/m", "A", [int()]), types) == NoArrows
  assert shape(named("app/m", "B", [int()]), types) == NoArrows
  assert shape(named("app/m", "A", [thunk()]), types) == HasArrows
  assert shape(named("app/m", "B", [thunk()]), types) == HasArrows
}

pub fn a_type_growing_through_another_module_is_read_test() {
  let types =
    typedefs.merge(
      registry("app/a", "pub type Pair(a) { Pair(a, a) }"),
      registry(
        "app/b",
        "import app/a.{type Pair}
pub type Outer(a) { Deeper(Outer(Pair(a))) Done(a) }",
      ),
    )
  assert shape(named("app/b", "Outer", [int()]), types) == NoArrows
  assert shape(named("app/b", "Outer", [thunk()]), types) == HasArrows
}

pub fn permuted_parameters_each_reach_a_value_test() {
  let types =
    registry(
      "app/m",
      "pub type Perm(a, b, c, d, e, f, g, h) {
  Rot(Perm(b, c, d, e, f, g, h, #(a, a)))
  Hold(a)
}",
    )
  let ints = list.repeat(int(), 8)
  assert shape(named("app/m", "Perm", ints), types) == NoArrows
  list.each(from(0, 8), fn(position) {
    let arguments =
      list.index_map(ints, fn(argument, index) {
        case index == position {
          True -> thunk()
          False -> argument
        }
      })
    assert shape(named("app/m", "Perm", arguments), types) == HasArrows
  })
}

pub fn a_deep_alias_chain_is_read_to_its_end_test() {
  let chain =
    from(1, 101)
    |> list.map(fn(i) {
      "pub type A"
      <> int.to_string(i)
      <> "(a) = A"
      <> int.to_string(i - 1)
      <> "(List(a))\n"
    })
    |> string.concat
  let types =
    registry(
      "app/m",
      "pub type A0(a) = #(a, Int)\n"
        <> chain
        <> "pub type Holder(a) { Holder(A100(a)) Empty }",
    )
  assert shape(named("app/m", "A100", [int()]), types) == NoArrows
  assert shape(named("app/m", "A100", [thunk()]), types) == HasArrows
  assert shape(named("app/m", "Holder", [int()]), types) == NoArrows
  assert shape(named("app/m", "Holder", [thunk()]), types) == HasArrows
}

pub fn a_phantom_parameter_holds_nothing_test() {
  let types =
    registry(
      "app/m",
      "pub type Tagged(tag, a) { Tagged(a) }
pub type Ladder(tag) { Up(Ladder(fn() -> tag)) Ground }",
    )
  assert shape(named("app/m", "Tagged", [thunk(), int()]), types) == NoArrows
  assert shape(named("app/m", "Tagged", [int(), thunk()]), types) == HasArrows
  assert shape(named("app/m", "Ladder", [thunk()]), types) == NoArrows
}

pub fn a_parameter_reaching_a_value_several_steps_down_is_read_test() {
  let types =
    registry(
      "app/m",
      "pub type S1(a) { S1(S2(a)) }
pub type S2(a) { S2(S3(a)) }
pub type S3(a) { S3(S4(a)) }
pub type S4(a) { S4(S5(a)) }
pub type S5(a) { S5(value: a) }
pub type T1(a) { T1(T2(a)) }
pub type T2(a) { T2(T3(a)) }
pub type T3(a) { T3(run: fn(a) -> Nil) }",
    )
  assert shape(named("app/m", "S1", [int()]), types) == NoArrows
  assert shape(named("app/m", "S1", [thunk()]), types) == HasArrows
  assert shape(named("app/m", "S1", [girard.Var(1)]), types) == UnknownShape
  assert shape(named("app/m", "T1", [int()]), types) == HasArrows
}

pub fn a_large_shared_type_is_read_once_per_node_test() {
  let doubled =
    list.fold(from(0, 18), int(), fn(type_, _) { girard.Tuple([type_, type_]) })
  assert shape(doubled, typedefs.empty()) == NoArrows
  let holding = girard.Tuple([doubled, thunk()])
  assert shape(holding, typedefs.empty()) == HasArrows
}

// Foreign representations

pub fn an_external_type_is_unknown_without_a_container_contract_test() {
  let types = registry("app/m", "pub type Store(v)")
  assert shape(named("app/m", "Store", [int()]), types) == UnknownShape
  let containers = set.from_list([#("app/m", "Store")])
  let solved = typedefs.shapes(types, containers)
  assert typedefs.shape(named("app/m", "Store", [int()]), solved) == NoArrows
  assert typedefs.shape(named("app/m", "Store", [thunk()]), solved) == HasArrows
}

pub fn a_definition_built_for_no_target_is_missing_test() {
  let source = "@target(erlang)\npub type Only { Only(Int) }"
  let javascript = registry_on("app/m", source, set.from_list(["javascript"]))
  assert shape(named("app/m", "Only", []), javascript) == UnknownShape
  let erlang = registry_on("app/m", source, set.from_list(["erlang"]))
  assert shape(named("app/m", "Only", []), erlang) == NoArrows
}

pub fn every_target_variant_of_a_type_is_read_test() {
  let source =
    "@target(javascript)\npub type Box { Box(Int) }\n@target(erlang)\npub type Box { Box(fn() -> Nil) }"
  let both = registry("app/m", source)
  assert shape(named("app/m", "Box", []), both) == HasArrows
  let javascript = registry_on("app/m", source, set.from_list(["javascript"]))
  assert shape(named("app/m", "Box", []), javascript) == NoArrows
  let swapped =
    "@target(erlang)\npub type Box { Box(fn() -> Nil) }\n@target(javascript)\npub type Box { Box(Int) }"
  assert shape(named("app/m", "Box", []), registry("app/m", swapped))
    == HasArrows
}

pub fn function_free_variants_hold_none_and_reach_their_parameters_test() {
  let source =
    "@target(javascript)\npub type Box(a) { Box(a) }\n@target(erlang)\npub type Box(a) { Wrapped(List(a)) }"
  let types = registry("app/m", source)
  assert shape(named("app/m", "Box", [int()]), types) == NoArrows
  assert shape(named("app/m", "Box", [thunk()]), types) == HasArrows
}

pub fn variants_taking_different_parameters_are_unknown_test() {
  let source =
    "@target(javascript)\npub type Box(a) { Box(a) }\n@target(erlang)\npub type Box { Box(Int) }"
  assert shape(named("app/m", "Box", []), registry("app/m", source))
    == UnknownShape
}

// Function kinds

fn kind(type_: typedefs.TypeExpr, source: String) -> typedefs.FunctionKind {
  typedefs.function_kind(type_, typedefs.kinds(registry("app/m", source)))
}

fn alias(
  name: String,
  arguments: List(typedefs.TypeExpr),
) -> typedefs.TypeExpr {
  typedefs.NamedExpr("app/m", name, arguments)
}

pub fn an_alias_of_a_function_is_one_through_any_chain_test() {
  let chain =
    "pub type A0(a) = fn(a) -> a\n"
    <> string.concat(
      list.map(from(1, 101), fn(i) {
        "pub type A"
        <> int.to_string(i)
        <> "(a) = A"
        <> int.to_string(i - 1)
        <> "(a)\n"
      }),
    )
  assert kind(alias("A100", [typedefs.NamedExpr("gleam", "Int", [])]), chain)
    == typedefs.IsFunction(1)
  assert kind(alias("A100", []), chain) == typedefs.UnresolvedFunctionKind
}

pub fn an_alias_of_its_parameter_is_what_it_is_applied_to_test() {
  let source = "pub type Same(a) = a\npub type Box { Box(Int) }"
  assert kind(alias("Same", [typedefs.FnExpr([], alias("Box", []))]), source)
    == typedefs.IsFunction(0)
  assert kind(alias("Same", [alias("Box", [])]), source) == typedefs.NotFunction
}

pub fn alias_variants_that_disagree_are_unresolved_test() {
  let source =
    "pub type Box { Box(fn() -> Nil) }\n@target(erlang)\npub type Act = fn() -> Nil\n@target(javascript)\npub type Act = Box"
  assert kind(alias("Act", []), source) == typedefs.UnresolvedFunctionKind
  let agreeing =
    "@target(erlang)\npub type Act = fn() -> Nil\n@target(javascript)\npub type Act = fn() -> Nil"
  assert kind(alias("Act", []), agreeing) == typedefs.IsFunction(0)
}

// The run's registry

pub fn a_dependency_type_comes_from_the_scan_test() {
  let directory = "/tmp/graded_typedefs_scan"
  let _ =
    support.write_project_with_dependency(
      directory:,
      package: "app",
      spec: "",
      sources: [#("src/app.gleam", "pub fn go() -> Nil {\n  Nil\n}\n")],
      dependency: "dep",
      dependency_spec: "",
      dependency_sources: [
        #(
          "dep/config.gleam",
          "pub type Config {\n  Config(on_item: fn(String) -> Nil)\n}\n",
        ),
      ],
    )
  let assert Ok(types) = graded.context_type_definitions(directory)
  support.cleanup(directory)
  assert shape(named("dep/config", "Config", []), types) == HasArrows
}
