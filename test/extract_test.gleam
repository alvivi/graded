import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/set.{type Set}
import gleeunit/should
import graded/internal/extract
import graded/internal/types.{
  type QualifiedName, Build, CallResult, Choice, FieldParam, FieldPath,
  FieldValue, FunctionRef, Join, Opaque, OtherExpression, ParameterRoot,
  Passthrough, Path, QualifiedName, Untraceable,
}

// Return provenance
//
// `return_provenance` traces a function's return value back to its parameters
// — passthroughs, field paths, rebuilt records, joins over branches — and
// widens to `Opaque` wherever the value can't be traced.

fn provenance_of(src: String) -> types.ReturnProvenance {
  let assert Ok(module) = glance.module(src)
  let ctx =
    extract.build_import_context(module)
    |> extract.with_factories(extract.factory_map(
      "app",
      module,
      types.every_target(),
      dict.new(),
    ))
  let assert Ok(func) =
    list.find(module.functions, fn(def) { def.definition.name == "target" })
  extract.return_provenance(func.definition, ctx)
}

pub fn provenance_passthrough_test() {
  provenance_of("fn target(o) { o }")
  |> should.equal(Passthrough(0))
}

pub fn provenance_passthrough_second_param_test() {
  provenance_of("fn target(a, b) { b }")
  |> should.equal(Passthrough(1))
}

pub fn provenance_path_test() {
  provenance_of("fn target(config) { config.options }")
  |> should.equal(Path(0, "options"))
}

pub fn provenance_nested_path_test() {
  provenance_of("fn target(config) { config.a.b }")
  |> should.equal(Path(0, "a.b"))
}

pub fn provenance_let_threaded_path_test() {
  provenance_of(
    "fn target(config) {
  let x = config.options
  x
}",
  )
  |> should.equal(Path(0, "options"))
}

pub fn provenance_build_field_path_test() {
  provenance_of(
    "pub type Options {
  Options(resolver: fn() -> Nil)
}
fn target(o) { Options(resolver: o.resolver) }",
  )
  |> should.equal(
    Build(dict.from_list([#("resolver", FieldPath(0, "resolver"))])),
  )
}

pub fn provenance_build_field_param_test() {
  provenance_of(
    "pub type Options {
  Options(resolver: fn() -> Nil)
}
fn target(r) { Options(resolver: r) }",
  )
  |> should.equal(Build(dict.from_list([#("resolver", FieldParam(0))])))
}

pub fn provenance_call_is_opaque_test() {
  provenance_of(
    "fn get(o) { o }
fn target(o) { get(o) }",
  )
  |> should.equal(Opaque)
}

// The provenance walk threads bindings through the body before folding the tail,
// so a parameter reached through a chain of `let`s, a `use` scope, or a
// `let`-bound `case` still resolves rather than widening at the binding.

pub fn provenance_survives_multi_let_test() {
  // A parameter aliased through two `let` hops still folds to a `Passthrough`.
  provenance_of(
    "fn target(config) {
  let a = config
  let b = a
  b
}",
  )
  |> should.equal(Passthrough(0))
}

pub fn provenance_survives_use_binding_test() {
  // A `use` scope threads its bound patterns; the tail parameter beneath it still
  // folds to a `Passthrough`.
  provenance_of(
    "fn with_x(f) { f(1) }
fn target(o) {
  use _x <- with_x()
  o
}",
  )
  |> should.equal(Passthrough(0))
}

pub fn provenance_survives_case_let_test() {
  // A `let` bound to a `case` whose branches all pass the same parameter through
  // folds to a single `Passthrough` (the redundant join collapses).
  provenance_of(
    "fn target(flag, o) {
  let picked = case flag {
    True -> o
    False -> o
  }
  picked
}",
  )
  |> should.equal(Passthrough(1))
}

// Bindings whose value can't be traced back to a parameter widen to `Opaque` at
// the binding rather than resolving to a wrong root — a pipe into a call, a
// closure, and a constructor destructure.

pub fn provenance_pipe_into_call_is_opaque_test() {
  provenance_of(
    "fn getopt(c) { c }
fn target(c) { c |> getopt }",
  )
  |> should.equal(Opaque)
}

pub fn provenance_returned_closure_is_opaque_test() {
  provenance_of("fn target(o) { fn() { o } }")
  |> should.equal(Opaque)
}

pub fn provenance_destructure_binding_is_opaque_test() {
  // A destructured field binds opaquely, so rebuilding from it can't forward the
  // parameter and the whole build widens.
  provenance_of(
    "pub type Options {
  Options(resolver: fn() -> Nil)
}
fn target(o) {
  let Options(resolver: r) = o
  Options(resolver: r)
}",
  )
  |> should.equal(Opaque)
}

pub fn provenance_tail_recursion_is_passthrough_test() {
  // A tail-recursive passthrough: the base branch returns `o` and the recursive
  // branch calls back with `o` at the same position. The fixpoint grounds the
  // recursive branch through the estimate and converges to `Passthrough(1)`,
  // where a naive walk (a call return is opaque) would widen.
  provenance_of(
    "fn target(stop, o) {
  case stop {
    True -> o
    False -> target(True, o)
  }
}",
  )
  |> should.equal(Passthrough(1))
}

pub fn provenance_recursion_returns_either_param_is_join_test() {
  // The recursive branch swaps the two parameters, so the function can return
  // either. The fixpoint converges to a `Join` of both passthroughs — never
  // under-reporting the branch it could take.
  provenance_of(
    "fn target(x, a, b) {
  case x {
    True -> a
    False -> target(x, b, a)
  }
}",
  )
  |> should.equal(Join([Passthrough(1), Passthrough(2)]))
}

pub fn provenance_recursion_rebuild_is_opaque_test() {
  // The recursive branch reconstructs the record rather than passing a parameter
  // through. A `Build` grounded through recursion isn't modelled, so the fixpoint
  // widens the whole function to `Opaque` instead of guessing.
  provenance_of(
    "pub type Options {
  Options(resolver: fn() -> Nil)
}
fn target(stop, o) {
  case stop {
    True -> o
    False -> target(True, Options(resolver: o.resolver))
  }
}",
  )
  |> should.equal(Opaque)
}

pub fn provenance_branch_is_join_test() {
  // A `case` over parameter branches folds to a `Join` of each branch's
  // provenance — here two `Passthrough`s onto parameters `a` and `b`.
  provenance_of(
    "fn target(x, a, b) {
  case x {
    True -> a
    False -> b
  }
}",
  )
  |> should.equal(Join([Passthrough(1), Passthrough(2)]))
}

pub fn provenance_branch_of_paths_is_join_test() {
  // A `case` whose branches are parameter-rooted *paths* (not bare parameters)
  // folds to a `Join` of each branch's `Path`. `classify_case_options` gates path
  // branches out of the called-value path; return provenance folds them itself.
  provenance_of(
    "pub type Config {
  Config(options: fn() -> Nil)
}
fn target(x, a, b) {
  case x {
    True -> a.options
    False -> b.options
  }
}",
  )
  |> should.equal(Join([Path(1, "options"), Path(2, "options")]))
}

pub fn provenance_branch_of_builds_is_join_test() {
  // A `case` whose branches rebuild a record from a parameter-rooted field folds
  // to a `Join` of each branch's `Build`.
  provenance_of(
    "pub type Options {
  Options(resolver: fn() -> Nil)
}
fn target(x, a, b) {
  case x {
    True -> Options(resolver: a.resolver)
    False -> Options(resolver: b.resolver)
  }
}",
  )
  |> should.equal(
    Join([
      Build(dict.from_list([#("resolver", FieldPath(1, "resolver"))])),
      Build(dict.from_list([#("resolver", FieldPath(2, "resolver"))])),
    ]),
  )
}

pub fn provenance_branch_with_opaque_branch_is_opaque_test() {
  // Any untraceable branch (a literal here) widens the whole join to `Opaque`,
  // so a partially-traceable `case` never under-reports a branch.
  provenance_of(
    "fn target(x, a) {
  case x {
    True -> a
    False -> 42
  }
}",
  )
  |> should.equal(Opaque)
}

pub fn provenance_literal_is_opaque_test() {
  provenance_of("fn target() { 42 }")
  |> should.equal(Opaque)
}

pub fn provenance_non_param_local_is_opaque_test() {
  provenance_of(
    "fn other() { 1 }
fn target() {
  let x = other()
  x
}",
  )
  |> should.equal(Opaque)
}

pub fn provenance_build_with_concrete_field_keeps_value_test() {
  // A constructor field wired to a concrete construction-site value (a call
  // result here) is kept as a `FieldValue`, so a later field call on the returned
  // record resolves it per receiver instead of widening the whole `Build` to
  // `Opaque`. A field wired to a parameter would be a `FieldParam`/`FieldPath`.
  provenance_of(
    "pub type Options {
  Options(resolver: fn() -> Nil)
}
fn other() { fn() { Nil } }
fn target(o) { Options(resolver: other()) }",
  )
  |> should.equal(
    Build(
      dict.from_list([
        #("resolver", FieldValue(CallResult(QualifiedName("", "other"), []))),
      ]),
    ),
  )
}

pub fn provenance_partial_build_keeps_param_field_test() {
  // A constructor mixing a parameter-rooted field with a literal default keeps
  // the traceable field and drops the literal, rather than widening the whole
  // `Build` to `Opaque` — the smart-constructor shape.
  provenance_of(
    "pub type Options {
  Options(label: String, resolver: fn() -> Nil)
}
fn target(resolver) { Options(label: \"\", resolver: resolver) }",
  )
  |> should.equal(Build(dict.from_list([#("resolver", FieldParam(0))])))
}

// Call extraction
//
// `extract_calls` walks a function body and sorts every call it finds into the
// resolved (qualified), local (unqualified), reference, and field categories.

fn parse_and_extract(src: String) -> extract.ExtractResult {
  let assert Ok(module) = glance.module(src)
  let ctx = extract.build_import_context(module)
  let assert Ok(func) =
    list.find(module.functions, fn(def) { def.definition.name == "target" })
  extract.extract_calls(func.definition.body, ctx)
}

// The same walk with `target`'s own parameters seeded, as every caller in the
// pipeline walks a body.
fn parse_and_extract_function(src: String) -> extract.ExtractResult {
  let assert Ok(module) = glance.module(src)
  let ctx = extract.build_import_context(module)
  let assert Ok(func) =
    list.find(module.functions, fn(def) { def.definition.name == "target" })
  extract.extract_function_calls(func.definition, ctx)
}

pub fn qualified_call_test() {
  let src =
    "import gleam/io
pub fn target() { io.println(\"hi\") }"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
  result.local |> should.equal([])
}

pub fn unqualified_call_test() {
  let src =
    "import gleam/io.{println}
pub fn target() { println(\"hi\") }"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn local_call_test() {
  let src =
    "pub fn target() { helper() }
fn helper() { Nil }"
  let result = parse_and_extract(src)
  result.resolved |> should.equal([])
  result.local
  |> list.map(fn(l) { l.function })
  |> should.equal(["helper"])
}

pub fn local_call_scope_test() {
  // The name alone does not say what an unqualified call reaches: `sibling` is
  // whatever the module defines, while a parameter and a destructured local
  // name their own binding however a sibling is named. A reader matching the
  // module\'s own definitions by name attributes those calls to code the body
  // never reaches.
  let src =
    "pub fn target(shadowed: fn() -> Nil) {
  sibling()
  shadowed()
  let #(destructured, _) = #(fn() { Nil }, 1)
  destructured()
}
fn sibling() { Nil }"
  parse_and_extract_function(src).local
  |> list.map(fn(l) { #(l.function, l.scope) })
  |> should.equal([
    #("sibling", types.ModuleDefinition),
    #("shadowed", types.LexicalBinding),
    #("destructured", types.LexicalBinding),
  ])
}

pub fn pipe_qualified_test() {
  let src =
    "import gleam/io
pub fn target() { \"hi\" |> io.println }"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn pipe_unqualified_test() {
  let src =
    "import gleam/io.{println}
pub fn target() { \"hi\" |> println }"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

// Pipes into a function capture
//
// `x |> f(_, y)` is `f(x, y)`: the piped value takes the discard's position,
// carries the discard's label, and the callee is resolved by the shape the
// capture names.

// The arguments recorded for the one resolved call `src`'s `target` makes,
// as `#(position, label, value)` in position order.
fn captured_args(
  src: String,
) -> List(#(Int, option.Option(String), types.ArgumentValue)) {
  let result = parse_and_extract(src)
  let assert [call] = result.resolved
  let assert Ok(args) = dict.get(result.call_args, extract.span_key(call.span))
  args
  |> list.sort(fn(a, b) { int.compare(a.position, b.position) })
  |> list.map(fn(arg) { #(arg.position, arg.label, arg.value) })
}

pub fn pipe_into_capture_at_position_zero_test() {
  captured_args(
    "import gleam/io
import helper
pub fn target() { io.println |> helper.apply(_, 1) }",
  )
  |> should.equal([
    #(0, None, FunctionRef(QualifiedName("gleam/io", "println"))),
    #(1, None, OtherExpression),
  ])
}

pub fn pipe_into_capture_at_a_later_position_test() {
  captured_args(
    "import gleam/io
import helper
pub fn target() { io.println |> helper.apply(1, _) }",
  )
  |> should.equal([
    #(0, None, OtherExpression),
    #(1, None, FunctionRef(QualifiedName("gleam/io", "println"))),
  ])
}

pub fn pipe_into_a_labelled_capture_test() {
  // The labelled arguments are written in the other order than the callee
  // declares them, so only the label the discard carries binds it correctly.
  captured_args(
    "import gleam/io
import helper
pub fn target() { io.println |> helper.apply(times: 1, callback: _) }",
  )
  |> should.equal([
    #(0, Some("times"), OtherExpression),
    #(1, Some("callback"), FunctionRef(QualifiedName("gleam/io", "println"))),
  ])
}

pub fn pipe_into_a_local_capture_test() {
  let result =
    parse_and_extract(
      "import gleam/io
pub fn target() { io.println |> helper(_, 1) }",
    )
  let assert [call] = result.local
  call.function |> should.equal("helper")
  let assert Ok(args) = dict.get(result.call_args, extract.span_key(call.span))
  let assert Ok(piped) = list.find(args, fn(a) { a.position == 0 })
  piped.value |> should.equal(FunctionRef(QualifiedName("gleam/io", "println")))
}

pub fn pipe_into_a_nested_field_capture_test() {
  let result =
    parse_and_extract(
      "import gleam/io
pub fn target(o) { io.println |> o.inner.run(_, 1) }",
    )
  let assert [call] = result.field
  call.label |> should.equal("run")
  let assert Ok(args) = dict.get(result.call_args, extract.span_key(call.span))
  let assert Ok(piped) = list.find(args, fn(a) { a.position == 0 })
  piped.value |> should.equal(FunctionRef(QualifiedName("gleam/io", "println")))
}

pub fn closure_test() {
  let src =
    "import gleam/io
pub fn target() { fn() { io.println(\"x\") } }"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn case_branches_test() {
  let src =
    "import gleam/io
pub fn target(x) {
  case x {
    True -> io.println(\"yes\")
    False -> io.println(\"no\")
  }
}"
  let result = parse_and_extract(src)
  result.resolved |> list.length() |> should.equal(2)
}

pub fn multiple_calls_test() {
  let src =
    "import gleam/io
import gleam/list
pub fn target(items) {
  list.map(items, io.println)
}"
  let result = parse_and_extract(src)
  // list.map is a resolved call, io.println is a function reference
  result.resolved
  |> list.map(fn(r) { r.name })
  |> list.contains(QualifiedName("gleam/list", "map"))
  |> should.be_true()
  result.references
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn unqualified_function_ref_test() {
  let src =
    "import gleam/io.{println}
import gleam/list
pub fn target(items) { list.map(items, println) }"
  let result = parse_and_extract(src)
  result.references
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn nested_closure_test() {
  let src =
    "import gleam/io
pub fn target() { fn() { fn() { io.println(\"deep\") } } }"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn case_guard_test() {
  let src =
    "import gleam/io
pub fn target(x) {
  case x {
    n if n > 0 -> io.println(\"pos\")
    _ -> Nil
  }
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn assignment_expression_test() {
  let src =
    "import gleam/io
pub fn target() {
  let x = io.println(\"hi\")
  x
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn pipe_chain_test() {
  let src =
    "import gleam/string
import gleam/io
pub fn target(x) {
  x |> string.uppercase |> io.println
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> list.contains(QualifiedName("gleam/io", "println"))
  |> should.be_true()
  result.resolved
  |> list.map(fn(r) { r.name })
  |> list.contains(QualifiedName("gleam/string", "uppercase"))
  |> should.be_true()
}

pub fn block_expression_test() {
  let src =
    "import gleam/io
pub fn target() {
  {
    io.println(\"in block\")
  }
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn aliased_import_test() {
  let src =
    "import gleam/io as output
pub fn target() { output.println(\"hi\") }"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

// Field calls
//
// `object.field(args)` on a parameter receiver is recorded as a field call for
// type-directed resolution; a module import receiver is not.

pub fn field_access_call_test() {
  let src = "pub fn target(handler) { handler.on_click(event) }"
  let result = parse_and_extract(src)
  result.field |> list.length() |> should.equal(1)
  let assert [fc] = result.field
  fc.object |> should.equal("handler")
  fc.label |> should.equal("on_click")
  result.local |> should.equal([])
}

pub fn field_access_pipe_test() {
  let src = "pub fn target(handler) { event |> handler.on_click }"
  let result = parse_and_extract(src)
  result.field |> list.length() |> should.equal(1)
  let assert [fc] = result.field
  fc.object |> should.equal("handler")
  fc.label |> should.equal("on_click")
}

pub fn import_not_confused_with_field_test() {
  let src =
    "import gleam/io
pub fn target() { io.println(\"hi\") }"
  let result = parse_and_extract(src)
  result.resolved |> list.length() |> should.equal(1)
  result.field |> should.equal([])
}

// Constructors
//
// Record constructors are pure, so applying or piping into one is not tracked
// as a call.

pub fn constructors_not_tracked_as_calls_test() {
  let src =
    "import gleam/string
pub fn target(value) {
  let trimmed = string.trim(value)
  case trimmed {
    \"\" -> Error(Nil)
    _ -> Ok(trimmed)
  }
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/string", "trim")])
  result.local |> should.equal([])
}

pub fn custom_constructor_not_tracked_test() {
  let src =
    "pub type Id { Id(value: String) }
pub fn target(x) { Id(x) }"
  let result = parse_and_extract(src)
  result.resolved |> should.equal([])
  result.local |> should.equal([])
}

pub fn pipe_to_constructor_not_tracked_test() {
  let src = "pub fn target(x) { x |> Ok }"
  let result = parse_and_extract(src)
  result.resolved |> should.equal([])
  result.local |> should.equal([])
}

// Local binding resolution
//
// Same-function value flow: `let`-bound function references, block tails, case
// choices, and constructor fields resolve at the call or argument site.

pub fn case_of_function_refs_is_choice_arg_test() {
  // A `case` whose arms are all function references becomes a `Choice` argument.
  let src =
    "import gleam/io
pub fn target(flag) {
  print_with(case flag {
    True -> io.println
    False -> io.print
  })
}"
  let result = parse_and_extract(src)
  result.call_args
  |> dict.values
  |> list.flatten
  |> list.map(fn(arg) { arg.value })
  |> should.equal([
    Choice([
      FunctionRef(QualifiedName("gleam/io", "println")),
      FunctionRef(QualifiedName("gleam/io", "print")),
    ]),
  ])
}

pub fn case_with_non_function_arm_is_not_choice_test() {
  // A `case` with a non-function arm (a literal) is opaque, not a `Choice`.
  let src =
    "import gleam/io
pub fn target(flag) {
  print_with(case flag {
    True -> io.println
    False -> 42
  })
}"
  let result = parse_and_extract(src)
  result.call_args
  |> dict.values
  |> list.flatten
  |> list.map(fn(arg) { arg.value })
  |> should.equal([OtherExpression])
}

pub fn block_classifies_to_tail_expression_test() {
  // A block argument resolves to its tail expression (with the block's own lets
  // in scope) — here a function reference.
  let src =
    "import gleam/io
pub fn target() {
  call_with({
    let g = io.println
    g
  })
}"
  let result = parse_and_extract(src)
  result.call_args
  |> dict.values
  |> list.flatten
  |> list.map(fn(arg) { arg.value })
  |> should.equal([FunctionRef(QualifiedName("gleam/io", "println"))])
}

pub fn pipe_into_block_resolves_tail_test() {
  // Piping into a block re-targets the pipe at the block's tail expression
  // (with the block's lets in scope), so `x |> { let f = io.println; f }`
  // resolves the call to io.println.
  let src =
    "import gleam/io
pub fn target(x) {
  x |> {
    let f = io.println
    f
  }
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn function_ref_alias_call_test() {
  let src =
    "import gleam/io
pub fn target() {
  let f = io.println
  f(\"hi\")
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
  result.local |> should.equal([])
}

pub fn unqualified_ref_alias_call_test() {
  let src =
    "import gleam/io.{println}
pub fn target() {
  let f = println
  f(\"hi\")
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn transitive_alias_call_test() {
  let src =
    "import gleam/io
pub fn target() {
  let f = io.println
  let g = f
  g(\"hi\")
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn pipe_to_local_binding_test() {
  let src =
    "import gleam/io
pub fn target() {
  let f = io.println
  \"hi\" |> f
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn shadowing_overwrites_test() {
  let src =
    "import gleam/io
pub fn target() {
  let f = io.println
  let f = some_opaque_thing
  f(\"hi\")
}"
  let result = parse_and_extract(src)
  // Second `let f = <opaque>` overwrites; call resolves as local.
  result.resolved |> should.equal([])
  result.local
  |> list.map(fn(l) { l.function })
  |> should.equal(["f"])
}

pub fn block_scope_does_not_leak_test() {
  let src =
    "import gleam/io
pub fn target() {
  {
    let f = io.println
    Nil
  }
  f(\"hi\")
}"
  let result = parse_and_extract(src)
  // `f` inside the block doesn't leak; outer `f(\"hi\")` is a local call.
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([])
  result.local
  |> list.map(fn(l) { l.function })
  |> should.equal(["f"])
}

pub fn pattern_destructure_is_opaque_test() {
  let src =
    "import gleam/io
pub fn target() {
  let #(f, _) = #(io.println, 1)
  f(\"hi\")
}"
  let result = parse_and_extract(src)
  // Destructuring drops tracking — `f` is opaque, call stays local.
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([])
  result.local
  |> list.map(fn(l) { l.function })
  |> should.equal(["f"])
}

pub fn constructor_field_call_resolves_test() {
  let src =
    "import gleam/io
pub type Validator { Validator(to_error: fn(Int) -> Nil) }
pub fn target() {
  let v = Validator(to_error: io.println)
  v.to_error(1)
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
  result.field |> should.equal([])
}

pub fn constructor_field_call_unresolved_falls_back_test() {
  let src =
    "pub type Validator { Validator(to_error: fn(Int) -> Nil) }
pub fn target() {
  let v = Validator(to_error: some_closure())
  v.to_error(1)
}"
  let result = parse_and_extract(src)
  // The to_error value is a call result — OtherExpression — so we
  // fall back to a FieldCall so type-level annotations can still apply.
  result.field
  |> list.map(fn(f) { #(f.object, f.label) })
  |> should.equal([#("v", "to_error")])
}

pub fn constructor_positional_arg_matches_label_test() {
  let src =
    "import gleam/io
pub type Validator { Validator(to_error: fn(Int) -> Nil) }
pub fn target() {
  let v = Validator(io.println)
  v.to_error(1)
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn constructor_mixed_positional_and_labelled_test() {
  let src =
    "import gleam/io
pub type Handler {
  Handler(on_click: fn() -> Nil, on_hover: fn() -> Nil)
}
pub fn target() {
  let h = Handler(io.println, on_hover: fn() { Nil })
  h.on_click()
}"
  let result = parse_and_extract(src)
  // Positional fills on_click (first field); labelled on_hover is a
  // closure so field resolution picks up only the on_click call.
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn qualified_constructor_field_call_resolves_test() {
  let src =
    "import gleam/io
import other
pub fn target() {
  let v = other.Validator(to_error: io.println)
  v.to_error(1)
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn positional_qualified_constructor_field_call_resolves_test() {
  // Another module's record is constructed positionally as readily as with
  // labels. Without that module's declared labels the unlabelled argument
  // routed to no field, so the construction wired nothing and the field call
  // fell back to `[Unknown]`.
  let src =
    "import gleam/io
import other
pub fn target() {
  let v = other.Validator(io.println)
  v.to_error(1)
}"
  let assert Ok(module) = glance.module(src)
  let context =
    extract.build_import_context(module)
    |> extract.with_cross_constructors(
      dict.from_list([#(#("other", "Validator"), [Some("to_error")])]),
    )
  let assert Ok(func) =
    list.find(module.functions, fn(def) { def.definition.name == "target" })
  extract.extract_calls(func.definition.body, context).resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn alias_as_argument_classified_as_function_ref_test() {
  let src =
    "import gleam/io
import gleam/list
pub fn target(xs) {
  let f = io.println
  list.map(xs, f)
}"
  let result = parse_and_extract(src)
  // Confirm list.map resolves and its second arg is classified as a
  // function ref to io.println (drives effect-variable binding).
  let assert Ok(call) =
    list.find(result.resolved, fn(r) {
      r.name == QualifiedName("gleam/list", "map")
    })
  let assert Ok(args) = dict.get(result.call_args, extract.span_key(call.span))
  let assert Ok(second_arg) = list.find(args, fn(a) { a.position == 1 })
  second_arg.value
  |> should.equal(FunctionRef(QualifiedName("gleam/io", "println")))
}

// Effects inside panic, todo, echo, and bitstring sub-expressions
//
// These positions hold arbitrary expressions; a call inside them must still
// be counted, not dropped as a leaf node.

fn resolved_names(src: String) -> List(QualifiedName) {
  parse_and_extract(src).resolved |> list.map(fn(r) { r.name })
}

pub fn panic_message_effects_test() {
  resolved_names(
    "import gleam/io
pub fn target() { panic as io.println(\"boom\") }",
  )
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn todo_message_effects_test() {
  resolved_names(
    "import gleam/io
pub fn target() { todo as io.println(\"boom\") }",
  )
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn echo_expression_effects_test() {
  resolved_names(
    "import gleam/io
pub fn target() { echo io.println(\"hi\") }",
  )
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn echo_message_effects_test() {
  // The optional `as` message is a separate expression from the echoed value.
  resolved_names(
    "import gleam/io
pub fn target() { echo 1 as io.println(\"label\") }",
  )
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn bitstring_segment_effects_test() {
  resolved_names(
    "import gleam/io
pub fn target() { <<io.println(\"x\")>> }",
  )
  |> should.equal([QualifiedName("gleam/io", "println")])
}

// Foreign declarations
//
// Which definitions `is_foreign_definition` holds foreign, and what an
// `@external` whose target argument cannot be read counts as.

fn is_foreign(src: String) -> Bool {
  is_foreign_for(src, types.every_target())
}

fn is_foreign_for(src: String, package_targets: Set(String)) -> Bool {
  let assert Ok(module) = glance.module(src)
  let assert Ok(definition) =
    list.find(module.functions, fn(def) { def.definition.name == "target" })
  extract.is_foreign_definition(definition, package_targets)
}

pub fn a_declaration_naming_its_target_is_foreign_test() {
  is_foreign("@external(erlang, \"m\", \"f\")\npub fn target() { Nil }")
  |> should.be_true()
}

pub fn a_target_excluded_declaration_is_not_foreign_test() {
  // No implementation is compiled for a target the function is not built for,
  // so the Gleam body is the only one that exists.
  is_foreign(
    "@target(erlang)\n@external(javascript, \"m\", \"f\")\npub fn target() { Nil }",
  )
  |> should.be_false()
}

pub fn a_definition_built_for_no_target_stays_foreign_test() {
  // A `@target` disjoint from the package's own: the function is compiled on no
  // channel, so its body is nobody's implementation. "Compiled for no target"
  // and "compiled without foreign code" are the same empty intersection and
  // mean opposite things — read as the latter, this counted as ordinary Gleam
  // and the body was walked for a function that is never built.
  is_foreign_for(
    "@target(javascript)\n@external(javascript, \"m\", \"f\")\npub fn target() { Nil }",
    set.from_list(["erlang"]),
  )
  |> should.be_true()
}

pub fn an_unreadable_target_argument_stays_foreign_test() {
  // A string where the target belongs declares a target this cannot read, and
  // "unreadable" is the same empty set as "none declared". Read as the latter,
  // the declaration counted as excluded from every compiled target — making
  // the Gleam body the trusted implementation of foreign code and publishing
  // its `[]` in place of `[Unknown]`. The compiler rejects this source, so the
  // conservative reading stands behind an assumption rather than a live case.
  is_foreign("@external(\"erlang\", \"m\", \"f\")\npub fn target() { Nil }")
  |> should.be_true()
}

// Construction sites
//
// Where a body builds a value of a custom type, with the constructor resolved
// to its defining module through the import context. A field `check` weighs
// the values wired at these sites, so a site that resolves to no module is not
// recorded at all rather than attributed to the wrong type.

fn constructions_of(src: String) -> List(types.Construction) {
  let assert Ok(module) = glance.module(src)
  let ctx =
    extract.build_import_context(module)
    |> extract.with_module_path("app")
  let assert Ok(func) =
    list.find(module.functions, fn(def) { def.definition.name == "target" })
  extract.extract_function_calls(func.definition, ctx).constructions
}

pub fn construction_records_a_same_module_constructor_test() {
  constructions_of(
    "pub type Handler {
  Handler(run: fn() -> Nil)
}

fn logger() { Nil }

fn target() {
  Handler(run: logger)
}
",
  )
  |> list.map(fn(c) { #(c.constructor, dict.to_list(c.fields)) })
  |> should.equal([
    #(types.BuiltConstructor(module: "app", variant: "Handler"), [
      #("run", types.LocalRef("logger")),
    ]),
  ])
}

pub fn construction_routes_a_positional_argument_to_its_label_test() {
  // A same-module constructor has declared labels, so a positional argument
  // reaches the field it fills.
  constructions_of(
    "pub type Handler {
  Handler(run: fn() -> Nil)
}

fn logger() { Nil }

fn target() {
  Handler(logger)
}
",
  )
  |> list.map(fn(c) { dict.to_list(c.fields) })
  |> should.equal([[#("run", types.LocalRef("logger"))]])
}

pub fn construction_records_a_qualified_constructor_by_defining_module_test() {
  constructions_of(
    "import app/handler

fn logger() { Nil }

fn target() {
  handler.Handler(run: logger)
}
",
  )
  |> list.map(fn(c) { c.constructor })
  |> should.equal([
    types.BuiltConstructor(module: "app/handler", variant: "Handler"),
  ])
}

pub fn construction_records_an_unqualified_import_by_defining_module_test() {
  constructions_of(
    "import app/handler.{Handler}

fn logger() { Nil }

fn target() {
  Handler(run: logger)
}
",
  )
  |> list.map(fn(c) { c.constructor })
  |> should.equal([
    types.BuiltConstructor(module: "app/handler", variant: "Handler"),
  ])
}

pub fn construction_skips_an_unresolvable_constructor_test() {
  // Neither this module's own types nor an import names it, so no check could
  // own the site.
  constructions_of(
    "fn target() {
  Handler(run: logger)
}

fn logger() { Nil }
",
  )
  |> should.equal([])
}

pub fn record_update_records_only_the_written_fields_test() {
  constructions_of(
    "pub type Handler {
  Handler(run: fn() -> Nil, name: String)
}

fn logger() { Nil }

fn target(base) {
  Handler(..base, run: logger)
}
",
  )
  |> list.map(fn(c) { #(c.constructor.variant, dict.to_list(c.fields)) })
  |> should.equal([#("Handler", [#("run", types.LocalRef("logger"))])])
}

pub fn construction_records_a_nested_site_test() {
  // The walk reaches a construction wherever it sits, so a site inside a
  // closure is a site.
  constructions_of(
    "pub type Handler {
  Handler(run: fn() -> Nil)
}

fn logger() { Nil }

fn target() {
  fn() { Handler(run: logger) }
}
",
  )
  |> list.map(fn(c) { c.constructor.variant })
  |> should.equal(["Handler"])
}

// Receivers that shadow an import alias
//
// `receiver.label` where `receiver` names both a local binding and an imported
// module resolves the way the compiler resolves it: the binding's type has a
// field `label` → the field call, and the module is the fallback where it does
// not. Two shapes prove "does not" — an inline `fn` literal, and a construction
// whose routing wired every field the type declares — and nothing else does.

pub fn a_shadowed_receivers_wired_field_beats_the_module_test() {
  // `int` shadows `gleam/int`, and the record it holds has a `to_string` field
  // wired to an impure function. Reading the alias first resolved this to
  // `gleam/int.to_string` — pure — for a body that calls `shout`.
  let src =
    "import gleam/int
pub type Fmt {
  Fmt(to_string: fn(String) -> Nil)
}

fn shout(s) {
  Nil
}

pub fn target() {
  let int = Fmt(to_string: shout)
  int.to_string(\"hi\")
}"
  let result = parse_and_extract_function(src)
  result.resolved |> should.equal([])
  result.local |> list.map(fn(l) { l.function }) |> should.equal(["shout"])
}

pub fn a_complete_construction_without_the_label_takes_the_module_test() {
  // Every field this construction's type declares was wired, so a label the
  // dict does not hold is a label the type does not have — the compiler's
  // fallback, and the reading that compiles.
  let src =
    "import gleam/int
pub type Fmt {
  Fmt(other: fn(String) -> Nil)
}

fn shout(s) {
  Nil
}

pub fn target() {
  let int = Fmt(other: shout)
  int.to_string(\"hi\")
}"
  let result = parse_and_extract_function(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/int", "to_string")])
  result.field |> should.equal([])
}

pub fn a_shadowing_closure_takes_the_module_test() {
  // An inline `fn` literal is a function, and a function value has no fields:
  // the module is the only reading that compiles.
  let src =
    "import gleam/io
pub fn target() {
  let io = fn(_n: Int) { Nil }
  io.println(\"hi\")
}"
  let result = parse_and_extract_function(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
  result.field |> should.equal([])
}

pub fn a_partial_construction_without_the_label_is_untraceable_test() {
  // A positional construction of a type whose declared labels are not in reach
  // wires nothing, so the absent label means untraced, not absent. Answering
  // the module here is the undercharge one level over.
  let src =
    "import gleam/int
import other

pub fn target() {
  let int = other.Fmt(shout)
  int.to_string(\"hi\")
}

fn shout(s) {
  Nil
}"
  let result = parse_and_extract_function(src)
  result.resolved |> should.equal([])
  let assert [call] = result.field
  call.label |> should.equal("to_string")
  call.provenance |> should.equal(Untraceable)
}

pub fn a_shadowing_imported_constant_is_untraceable_test() {
  // `classify_expression` mints a `BoundFunctionRef` for any lowercase imported
  // name, and a Gleam constant may be a record whose field is callable. It
  // proves nothing about the value's type, so it takes the field branch.
  let src =
    "import dep_mod
import gleam/int

pub fn target() {
  let int = dep_mod.default_fmt
  int.to_string(\"hi\")
}"
  let result = parse_and_extract_function(src)
  result.resolved |> should.equal([])
  let assert [call] = result.field
  call.provenance |> should.equal(Untraceable)
}

pub fn a_shadowing_case_over_call_results_is_untraceable_test() {
  // `classify_case_options` admits call results, so "function-like" is a
  // lifting property, not proof of a function value: a `case` over
  // record-returning calls has fields.
  let src =
    "import gleam/int

fn make() {
  Nil
}

pub fn target(flag) {
  let int = case flag {
    True -> make()
    False -> make()
  }
  int.to_string(\"hi\")
}"
  let result = parse_and_extract_function(src)
  result.resolved |> should.equal([])
  let assert [call] = result.field
  call.provenance |> should.equal(Untraceable)
}

pub fn a_shadowing_binding_extraction_cannot_type_is_untraceable_test() {
  // The stage-1 residual: extraction cannot ask what type the binding has, so
  // an opaque one funnels to `[Unknown]` rather than to the module's effects.
  // Over-approximate, and the direction that cannot undercharge.
  let src =
    "import gleam/int

pub fn target() {
  let int = 42
  int.to_string(\"hi\")
}"
  let result = parse_and_extract_function(src)
  result.resolved |> should.equal([])
  let assert [call] = result.field
  call.provenance |> should.equal(Untraceable)
}

pub fn a_clause_pattern_binding_shadows_the_parameter_it_names_test() {
  // `case r { Runner(..) as list -> .. }` binds its own `list`, so the field
  // call names the clause's value and not the parameter of the same name.
  // Read through the parameter, the receiver would carry the annotation of a
  // value the body never reaches.
  let src =
    "pub fn target(list: Empty, r: Runner) {
  case r {
    Runner(..) as list -> list.map(\"hi\")
  }
}"
  let result = parse_and_extract_function(src)
  let assert [call] = result.field
  call.object |> should.equal("list")
  call.provenance |> should.equal(Untraceable)
}

pub fn an_unshadowed_parameter_receiver_stays_parameter_rooted_test() {
  // The counterpart: a clause that binds nothing of the name leaves the
  // parameter in scope, so the receiver still roots at it.
  let src =
    "pub fn target(list: Empty, r: Runner) {
  case r {
    Runner(..) -> list.map(\"hi\")
  }
}"
  let result = parse_and_extract_function(src)
  let assert [call] = result.field
  call.provenance |> should.equal(ParameterRoot("list"))
}

// The alternative reading of a shadowed receiver
//
// A field call whose receiver's name shadows an import carries the module it
// shadows, so the checker can re-read the call once it knows the receiver's
// type. Everything extraction already proved about the value records `None`,
// and so does every receiver that shadows nothing.

pub fn an_unshadowed_receiver_carries_no_alternative_test() {
  let src =
    "pub fn target(thing) {
  thing.emit(\"hi\")
}"
  let result = parse_and_extract_function(src)
  let assert [call] = result.field
  call.shadowed_module |> should.equal(None)
}

pub fn a_nested_receiver_carries_no_alternative_test() {
  // `d.svc.find(..)` is not a bare identifier, so it can shadow no alias.
  let src =
    "import gleam/int

pub fn target(d) {
  d.int.to_string(\"hi\")
}"
  let result = parse_and_extract_function(src)
  let assert [call] = result.field
  call.object |> should.equal("d.int")
  call.shadowed_module |> should.equal(None)
}

pub fn a_shadowing_parameter_carries_the_module_test() {
  let src =
    "import gleam/int

pub fn target(int) {
  int.to_string(\"hi\")
}"
  let result = parse_and_extract_function(src)
  let assert [call] = result.field
  call.shadowed_module |> should.equal(Some("gleam/int"))
}

pub fn a_shadowing_opaque_local_carries_the_module_test() {
  let src =
    "import gleam/int

pub fn target() {
  let int = 42
  int.to_string(\"hi\")
}"
  let result = parse_and_extract_function(src)
  let assert [call] = result.field
  call.shadowed_module |> should.equal(Some("gleam/int"))
}

pub fn a_shadowing_partial_construction_carries_the_module_test() {
  let src =
    "import gleam/int
import other

pub fn target() {
  let int = other.Fmt(shout)
  int.to_string(\"hi\")
}

fn shout(s) {
  Nil
}"
  let result = parse_and_extract_function(src)
  let assert [call] = result.field
  call.shadowed_module |> should.equal(Some("gleam/int"))
}

pub fn a_wired_field_on_a_shadowing_receiver_carries_no_alternative_test() {
  // The construction wired the label, which is the type's own answer that it
  // has the field — no module reading of the call survives.
  let src =
    "import gleam/int

pub type Fmt {
  Fmt(to_string: fn(String) -> Nil)
}

pub fn target() {
  let int = Fmt(to_string: fn(_s) { Nil })
  int.to_string(\"hi\")
}"
  let result = parse_and_extract_function(src)
  let assert [call] = result.field
  call.label |> should.equal("to_string")
  call.shadowed_module |> should.equal(None)
}

// Narrowing on a shadowed receiver
//
// A receiver whose variant no pattern fixed grants only the accessors every
// variant declares, so extraction records whether anything narrowed it. The
// marks are exact in both directions: one that fires too readily keeps the
// undercharge the strict reading exists to close, and one that fires too rarely
// reads the module where the compiler reads a real field.

// The two-variant type the narrowing cases are written against: `map` is
// declared on `Fast` alone, and `list` shadows `gleam/list`.
const narrowing_prelude = "import gleam/list
import other

pub type Runner {
  Fast(map: fn(String) -> Nil)
  Slow(n: Int)
}

pub type Config {
  Config(runner: Runner)
}

fn make() -> Runner {
  Fast(fn(_s) { Nil })
}

"

// The narrowing recorded on the one field call `target` emits.
fn narrowing_of(body: String) -> types.ReceiverNarrowing {
  let result = parse_and_extract_function(narrowing_prelude <> body)
  let assert [call] = result.field
  call.receiver_narrowing
}

pub fn a_variant_pattern_on_the_subject_narrows_it_test() {
  // The subject narrows without an `as`: inside the clause `list` is known to
  // be a `Fast`, and the compiler reads the field.
  narrowing_of(
    "pub fn target(list: Runner) {
  case list {
    Fast(..) -> list.map(\"hi\")
  }
}",
  )
  |> should.equal(types.PossiblyNarrowedReceiver)
}

pub fn a_second_subject_column_narrows_its_own_subject_test() {
  narrowing_of(
    "pub fn target(n: Int, list: Runner) {
  case n, list {
    0, Fast(..) -> list.map(\"hi\")
  }
}",
  )
  |> should.equal(types.PossiblyNarrowedReceiver)
}

pub fn alternatives_selecting_one_variant_narrow_test() {
  narrowing_of(
    "pub fn target(list: Runner, flag: Bool) {
  case list, flag {
    Fast(..), True | Fast(..), False -> list.map(\"hi\")
  }
}",
  )
  |> should.equal(types.PossiblyNarrowedReceiver)
}

pub fn a_let_assert_over_a_variant_pattern_narrows_test() {
  narrowing_of(
    "pub fn target(list: Runner) {
  let assert Fast(_) = list
  list.map(\"hi\")
}",
  )
  |> should.equal(types.PossiblyNarrowedReceiver)
}

pub fn a_direct_construction_narrows_the_name_it_binds_test() {
  // A construction fixes the variant even where its routing traced no field:
  // this one is positional against a constructor whose labels are out of reach.
  narrowing_of(
    "pub fn target() {
  let list = other.Fast(fn(_s) { Nil })
  list.map(\"hi\")
}",
  )
  |> should.equal(types.PossiblyNarrowedReceiver)
}

pub fn an_alias_of_a_narrowed_name_narrows_test() {
  narrowing_of(
    "pub fn target(r: Runner) {
  case r {
    Fast(..) -> {
      let list = r
      list.map(\"hi\")
    }
  }
}",
  )
  |> should.equal(types.PossiblyNarrowedReceiver)
}

pub fn an_alias_outlives_a_rebinding_of_its_source_test() {
  // The alias\'s narrowing is fixed where it is taken, the same way its
  // canonical path is: rebinding the name it was taken from cannot reach back.
  narrowing_of(
    "pub fn target(r: Runner) {
  case r {
    Fast(..) -> {
      let list = r
      let r = make()
      list.map(\"hi\")
    }
  }
}",
  )
  |> should.equal(types.PossiblyNarrowedReceiver)
}

pub fn a_clause_pattern_name_is_possibly_narrowed_test() {
  // `Fast(..) as list` binds the clause\'s own name, which the pattern already
  // fixed to one variant.
  narrowing_of(
    "pub fn target(r: Runner) {
  case r {
    Fast(..) as list -> list.map(\"hi\")
  }
}",
  )
  |> should.equal(types.PossiblyNarrowedReceiver)
}

pub fn a_wildcard_pattern_narrows_nothing_test() {
  narrowing_of(
    "pub fn target(list: Runner) {
  case list {
    _ -> list.map(\"hi\")
  }
}",
  )
  |> should.equal(types.UnnarrowedReceiver)
}

pub fn a_variable_pattern_narrows_nothing_test() {
  narrowing_of(
    "pub fn target(list: Runner) {
  case list {
    other -> list.map(\"hi\")
  }
}",
  )
  |> should.equal(types.UnnarrowedReceiver)
}

pub fn alternatives_reaching_two_variants_narrow_nothing_test() {
  narrowing_of(
    "pub fn target(list: Runner) {
  case list {
    Fast(..) | Slow(..) -> list.map(\"hi\")
  }
}",
  )
  |> should.equal(types.UnnarrowedReceiver)
}

pub fn a_tuple_literal_subject_narrows_nothing_test() {
  // The subject is the tuple, not the variable it holds, and the compiler
  // leaves the variable un-narrowed.
  narrowing_of(
    "pub fn target(n: Int, list: Runner) {
  case #(n, list) {
    #(0, Fast(..)) -> list.map(\"hi\")
  }
}",
  )
  |> should.equal(types.UnnarrowedReceiver)
}

pub fn an_ordinary_let_over_a_variant_pattern_narrows_nothing_test() {
  // Well-typed only on a single-variant type, whose every-variant and
  // any-variant label sets coincide, so the mark would buy nothing.
  narrowing_of(
    "pub fn target(list: Runner) {
  let Fast(_) = list
  list.map(\"hi\")
}",
  )
  |> should.equal(types.UnnarrowedReceiver)
}

pub fn a_let_assert_selecting_no_variant_narrows_nothing_test() {
  narrowing_of(
    "pub fn target(list: Runner) {
  let assert _ = list
  list.map(\"hi\")
}",
  )
  |> should.equal(types.UnnarrowedReceiver)
}

pub fn narrowing_dies_with_the_clause_test() {
  narrowing_of(
    "pub fn target(list: Runner) {
  case list {
    Fast(..) -> Nil
  }
  list.map(\"hi\")
}",
  )
  |> should.equal(types.UnnarrowedReceiver)
}

pub fn a_rebinding_clears_the_mark_test() {
  narrowing_of(
    "pub fn target(list: Runner) {
  case list {
    Fast(..) -> {
      let list = make()
      list.map(\"hi\")
    }
  }
}",
  )
  |> should.equal(types.UnnarrowedReceiver)
}

pub fn a_call_result_is_un_narrowed_test() {
  narrowing_of(
    "pub fn target() {
  let list = make()
  list.map(\"hi\")
}",
  )
  |> should.equal(types.UnnarrowedReceiver)
}

pub fn an_alias_of_an_un_narrowed_parameter_is_un_narrowed_test() {
  narrowing_of(
    "pub fn target(r: Runner) {
  let list = r
  list.map(\"hi\")
}",
  )
  |> should.equal(types.UnnarrowedReceiver)
}

pub fn a_closure_parameter_is_un_narrowed_test() {
  narrowing_of(
    "pub fn target() {
  fn(list: Runner) { list.map(\"hi\") }
}",
  )
  |> should.equal(types.UnnarrowedReceiver)
}

pub fn a_projection_off_a_narrowed_value_is_un_narrowed_test() {
  // Narrowing does not survive a projection: `c.runner` is an ordinary
  // `Runner`, whatever `c` was fixed to, and the compiler reads the module
  // through it.
  narrowing_of(
    "pub fn target(c: Config) {
  case c {
    Config(..) -> {
      let list = c.runner
      list.map(\"hi\")
    }
  }
}",
  )
  |> should.equal(types.UnnarrowedReceiver)
}

pub fn a_factory_result_is_un_narrowed_test() {
  // A factory result binds exactly as a direct construction does, so the
  // binding alone cannot tell the two apart — only the mark can, and a value
  // that came back across a function boundary carries none.
  let src = narrowing_prelude <> "pub fn build(f: fn(String) -> Nil) -> Runner {
  Fast(f)
}

pub fn target() {
  let list = build(fn(_s) { Nil })
  list.map(\"hi\")
}"
  let assert Ok(module) = glance.module(src)
  let ctx =
    extract.build_import_context(module)
    |> extract.with_factories(extract.factory_map(
      "app",
      module,
      types.every_target(),
      dict.new(),
    ))
  let assert Ok(func) =
    list.find(module.functions, fn(def) { def.definition.name == "target" })
  let result = extract.extract_function_calls(func.definition, ctx)
  let assert [call] = result.field
  call.receiver_narrowing |> should.equal(types.UnnarrowedReceiver)
}

pub fn a_complete_construction_without_the_label_is_a_module_call_test() {
  // Every field the type declares was wired, so the absent label is absent from
  // the type: extraction settles it without the checker's help.
  let src =
    "import gleam/int

pub type Fmt {
  Fmt(shout: fn(String) -> Nil)
}

pub fn target() {
  let int = Fmt(shout: fn(_s) { Nil })
  int.to_string(\"hi\")
}"
  let result = parse_and_extract_function(src)
  result.field |> should.equal([])
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/int", "to_string")])
}
