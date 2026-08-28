import generators
import girard
import glance
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import gleeunit/should
import graded/internal/annotation
import graded/internal/checker
import graded/internal/effect_term
import graded/internal/effects
import graded/internal/extract
import graded/internal/signatures
import graded/internal/types.{
  type EffectAnnotation, type EffectSet, Check, EffectAnnotation, Effects,
  ParamBound, Polymorphic, QualifiedName, Specific, TAbs, TApp, TLabels, TVar,
  UnmatchedFieldBoundWarning, UnmatchedParamBoundWarning, UntrackedEffectWarning,
  Wildcard,
}
import qcheck
import support

// Check basics
//
// Shared check helper plus the core subset checks: pure budgets, declared
// effects, transitive calls, closures, and unknown locals.

fn knowledge_base() -> effects.KnowledgeBase {
  effects.empty_knowledge_base()
}

fn check_source(
  source: String,
  annotations: List(EffectAnnotation),
) -> List(types.Violation) {
  let assert Ok(module) = glance.module(source)
  let #(violations, _findings, _warnings) =
    checker.check(
      module,
      "",
      annotations,
      knowledge_base(),
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations
}

pub fn pure_function_passes_test() {
  let source =
    "import gleam/list
pub fn view(items) { list.map(items, fn(x) { x }) }"
  check_source(source, [
    EffectAnnotation(
      Check,
      "view",
      [],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    ),
  ])
  |> should.equal([])
}

pub fn effectful_call_in_pure_function_fails_test() {
  let source =
    "import gleam/io
pub fn view() { io.println(\"oops\") }"
  let violations =
    check_source(source, [
      EffectAnnotation(
        Check,
        "view",
        [],
        effect_term.from_effect_set(Specific(set.new())),
        returns: None,
      ),
    ])
  violations |> list.length() |> should.equal(1)
  let assert [violation] = violations
  violation.function |> should.equal("view")
  violation.explanation.call
  |> should.equal(QualifiedName("gleam/io", "println"))
}

pub fn declared_effects_pass_test() {
  let source =
    "import gleam/io
pub fn log(msg) { io.println(msg) }"
  check_source(source, [
    EffectAnnotation(
      Check,
      "log",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
      returns: None,
    ),
  ])
  |> should.equal([])
}

pub fn transitive_violation_test() {
  let source =
    "import gleam/io
pub fn view() { helper() }
fn helper() { io.println(\"sneaky\") }"
  let violations =
    check_source(source, [
      EffectAnnotation(
        Check,
        "view",
        [],
        effect_term.from_effect_set(Specific(set.new())),
        returns: None,
      ),
    ])
  violations |> list.length() |> should.equal(1)
  let assert [violation] = violations
  violation.explanation.call
  |> should.equal(QualifiedName("gleam/io", "println"))
}

pub fn multiple_effects_union_test() {
  let source =
    "import gleam/io
import gleam/erlang/process
pub fn do_stuff() {
  io.println(\"hi\")
  process.sleep(100)
}"
  let violations =
    check_source(source, [
      EffectAnnotation(
        Check,
        "do_stuff",
        [],
        effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
        returns: None,
      ),
    ])
  violations
  |> list.any(fn(violation) { violation.explanation.call.function == "sleep" })
  |> should.be_true()
}

pub fn missing_function_ignored_test() {
  let source = "pub fn other() { Nil }"
  check_source(source, [
    EffectAnnotation(
      Check,
      "nonexistent",
      [],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    ),
  ])
  |> should.equal([])
}

pub fn closure_effects_contribute_test() {
  let source =
    "import gleam/io
import gleam/list
pub fn view(items) {
  list.map(items, fn(x) { io.println(x) })
}"
  let violations =
    check_source(source, [
      EffectAnnotation(
        Check,
        "view",
        [],
        effect_term.from_effect_set(Specific(set.new())),
        returns: None,
      ),
    ])
  { violations != [] } |> should.be_true()
}

pub fn unknown_local_function_test() {
  // Function "missing" is referenced but not defined in the module
  let source = "pub fn view() { missing() }"
  let violations =
    check_source(source, [
      EffectAnnotation(
        Check,
        "view",
        [],
        effect_term.from_effect_set(Specific(set.new())),
        returns: None,
      ),
    ])
  // Should flag as Unknown effect
  { violations != [] } |> should.be_true()
  let assert [violation] = violations
  violation.explanation.call.function |> should.equal("missing")
}

// Infer
//
// Effect inference over source modules: ground effects derived from the body,
// with only public functions reported.

pub fn infer_pure_function_test() {
  let source =
    "import gleam/list
pub fn view(items) { list.map(items, fn(x) { x }) }"
  let assert Ok(module) = glance.module(source)
  let inferred =
    checker.infer(
      module,
      "",
      knowledge_base(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert [annotation] = inferred
  annotation.kind |> should.equal(Effects)
  annotation.function |> should.equal("view")
  effect_term.to_effect_set(annotation.effects)
  |> should.equal(Specific(set.new()))
}

pub fn infer_effectful_function_test() {
  let source =
    "import gleam/io
pub fn greet() { io.println(\"hi\") }"
  let assert Ok(module) = glance.module(source)
  let inferred =
    checker.infer(
      module,
      "",
      knowledge_base(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert [annotation] = inferred
  effect_term.to_effect_set(annotation.effects)
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn infer_only_public_functions_test() {
  let source =
    "import gleam/io
pub fn view() { helper() }
fn helper() { io.println(\"x\") }"
  let assert Ok(module) = glance.module(source)
  let inferred =
    checker.infer(
      module,
      "",
      knowledge_base(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert [annotation] = inferred
  annotation.function |> should.equal("view")
}

// Infer respects existing param bounds
//
// Hand-written check bounds feed the inferred effects, and girard's
// fn-typed-param map recovers unannotated higher-order parameters.

pub fn infer_uses_param_bounds_test() {
  let source = "pub fn apply(f, x) { f(x) }"
  let assert Ok(module) = glance.module(source)
  let existing_checks = [
    EffectAnnotation(
      Check,
      "apply",
      [
        ParamBound(
          "f",
          effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
        ),
      ],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
      returns: None,
    ),
  ]
  let inferred =
    checker.infer(
      module,
      "",
      knowledge_base(),
      existing_checks,
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert [annotation] = inferred
  effect_term.to_effect_set(annotation.effects)
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn infer_without_bounds_gets_unknown_test() {
  // Without girard's fn-typed info, an unannotated `f` isn't recognised as
  // higher-order, so the call falls through to [Unknown].
  let source = "pub fn apply(f, x) { f(x) }"
  let assert Ok(module) = glance.module(source)
  let inferred =
    checker.infer(
      module,
      "",
      knowledge_base(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert [annotation] = inferred
  effect_term.to_effect_set(annotation.effects)
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

// Build the fn-typed-param map girard supplies, the way build_type_index does:
// a parameter is fn-typed when its inferred type is itself a `Fn`.
fn girard_fn_typed_for(
  module: glance.Module,
) -> dict.Dict(String, set.Set(String)) {
  case girard.annotate_module(module, girard.default_options()) {
    Ok(annotated) ->
      list.fold(annotated.functions, dict.new(), fn(acc, entry) {
        let #(name, scheme) = entry
        case scheme.type_ {
          girard.Fn(argument_types, _return) -> {
            let assert Ok(definition) =
              list.find(module.functions, fn(d) { d.definition.name == name })
            let names =
              list.zip(definition.definition.parameters, argument_types)
              |> list.filter_map(fn(pair) {
                case pair.1, { pair.0 }.name {
                  girard.Fn(_, _), glance.Named(parameter_name) ->
                    Ok(parameter_name)
                  _, _ -> Error(Nil)
                }
              })
              |> set.from_list()
            dict.insert(acc, name, names)
          }
          _ -> acc
        }
      })
    Error(_) -> dict.new()
  }
}

pub fn infer_girard_detects_unannotated_fn_typed_param_test() {
  // The enhancement: `f` has no `fn(...)` annotation, but girard infers it is a
  // function, so `apply` gets a polymorphic signature instead of [Unknown].
  let source = "pub fn apply(f, x) { f(x) }"
  let assert Ok(module) = glance.module(source)
  let inferred =
    checker.infer(
      module,
      "",
      knowledge_base(),
      [],
      signatures.empty(),
      dict.new(),
      girard_fn_typed_for(module),
      types.all_targets(),
    )
  let assert [annotation] = inferred
  effect_term.to_effect_set(annotation.effects)
  |> should.equal(Polymorphic(set.new(), set.from_list(["f"])))
}

// Higher-order parameter bounds
//
// Calls through fn-typed parameters take their effects from the declared
// bound; undeclared parameters fall back to [Unknown].

// Case 1: function that calls a parameter — effects come from the declared bound
pub fn param_call_uses_bound_test() {
  let source = "pub fn apply(f, x) { f(x) }"
  let annotation =
    EffectAnnotation(
      Check,
      "apply",
      [
        ParamBound(
          "f",
          effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
        ),
      ],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
      returns: None,
    )
  check_source(source, [annotation]) |> should.equal([])
}

// Case 1b: undeclared param call treated as Unknown, violates pure bound
pub fn param_call_without_bound_is_unknown_test() {
  let source = "pub fn apply(f, x) { f(x) }"
  check_source(source, [
    EffectAnnotation(
      Check,
      "apply",
      [],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    ),
  ])
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Case 1c: an unbound fn-typed parameter's own variable is weighed as the
// `[Unknown]` the caller could see, so an `[Unknown]`-admitting budget passes.
pub fn unbound_param_call_meets_an_unknown_budget_test() {
  let source =
    "pub fn run(cb: fn() -> Nil) -> Nil {
  cb()
}"
  check_source(source, [
    EffectAnnotation(
      Check,
      "run",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Unknown"]))),
      returns: None,
    ),
  ])
  |> should.equal([])
}

// The same call against a budget that admits nothing is still the violation it
// was, and it reports the parameter rather than the grounding the weighing did:
// the wording names the bound to add.
pub fn unbound_param_call_still_violates_a_pure_budget_test() {
  let source =
    "pub fn run(cb: fn() -> Nil) -> Nil {
  cb()
}"
  let assert [violation] =
    check_source(source, [
      EffectAnnotation(
        Check,
        "run",
        [],
        effect_term.from_effect_set(Specific(set.new())),
        returns: None,
      ),
    ])
  violation.explanation.actual
  |> should.equal(Polymorphic(set.new(), set.from_list(["cb"])))
}

// A bound the author *declared* is not the walk's own synthesis, so it is not
// grounded: a symbolic effect stated against a concrete budget stays a
// violation, whatever labels that budget admits.
pub fn a_declared_bound_variable_still_violates_an_unknown_budget_test() {
  let source =
    "pub fn run(cb: fn() -> Nil) -> Nil {
  cb()
}"
  check_source(source, [
    EffectAnnotation(
      Check,
      "run",
      [
        ParamBound(
          "cb",
          effect_term.from_effect_set(Polymorphic(
            set.new(),
            set.from_list(["cb"]),
          )),
        ),
      ],
      effect_term.from_effect_set(Specific(set.from_list(["Unknown"]))),
      returns: None,
    ),
  ])
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Case 2: declared bound of [] means param must be pure — pure arg passes
pub fn param_bound_pure_passes_test() {
  let source =
    "import gleam/list
pub fn safe_map(items, f) { list.map(items, f) }"
  let annotation =
    EffectAnnotation(
      Check,
      "safe_map",
      [ParamBound("f", effect_term.from_effect_set(Specific(set.new())))],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    )
  check_source(source, [annotation]) |> should.equal([])
}

// Case 3: inline closure effects propagate to enclosing function via flattening
pub fn inline_closure_effects_propagate_test() {
  let source =
    "import gleam/io
import gleam/list
pub fn run(items) {
  list.map(items, fn(x) { io.println(x) })
}"
  let annotation =
    EffectAnnotation(
      Check,
      "run",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
      returns: None,
    )
  check_source(source, [annotation]) |> should.equal([])
}

// Case 3b: inline closure with effects violates a pure check
pub fn inline_closure_effects_violate_pure_check_test() {
  let source =
    "import gleam/io
import gleam/list
pub fn run(items) {
  list.map(items, fn(x) { io.println(x) })
}"
  check_source(source, [
    EffectAnnotation(
      Check,
      "run",
      [],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    ),
  ])
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Field calls
//
// `object.field(args)` resolves through the type-field registry, from the
// receiver's annotated type or from girard's inferred type.

fn check_source_with_type_fields(
  source: String,
  annotations: List(EffectAnnotation),
  type_fields: List(types.FieldAnnotation),
) -> List(types.Violation) {
  let assert Ok(module) = glance.module(source)
  let kb =
    effects.with_type_fields(knowledge_base(), type_fields, types.CommittedSpec)
  let #(violations, _findings, _warnings) =
    checker.check(
      module,
      "",
      annotations,
      kb,
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations
}

// Typed param + registry entry → effects resolve correctly
pub fn field_call_typed_with_registry_test() {
  let source = "pub fn view(handler: Handler) { handler.on_click(event) }"
  let type_fields = [
    types.FieldAnnotation(
      module: None,
      type_name: "Handler",
      field: "on_click",
      effects: effect_term.from_effect_set(Specific(set.from_list(["Dom"]))),
    ),
  ]
  let annotation =
    EffectAnnotation(
      Check,
      "view",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Dom"]))),
      returns: None,
    )
  check_source_with_type_fields(source, [annotation], type_fields)
  |> should.equal([])
}

// Type-directed receiver resolution via girard.
//
// Same as `check_source_with_type_fields`, but threads girard's real inferred
// types so the receiver's nominal type is known even when it isn't a directly
// annotated parameter.
fn check_source_with_girard(
  source: String,
  annotations: List(EffectAnnotation),
  type_fields: List(types.FieldAnnotation),
) -> List(types.Violation) {
  let assert Ok(module) = glance.module(source)
  let module_types = girard_types(module)
  let kb =
    effects.with_type_fields(knowledge_base(), type_fields, types.CommittedSpec)
  let #(violations, _findings, _warnings) =
    checker.check(
      module,
      "",
      annotations,
      kb,
      signatures.empty(),
      module_types,
      dict.new(),
      types.all_targets(),
    )
  violations
}

// The canonical 3b gap: the receiver is bound from a function call, so graded's
// syntax-level path sees it as opaque. girard types it as `Validator`, so the
// `type Validator.to_error` annotation resolves the field call.
const opaque_receiver_source = "
import gleam/io

pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}

fn make() -> Validator {
  Validator(to_error: io.println)
}

pub fn run(msg: String) -> Nil {
  let v = make()
  v.to_error(msg)
}
"

fn validator_to_error_stdout() -> List(types.FieldAnnotation) {
  [
    types.FieldAnnotation(
      module: None,
      type_name: "Validator",
      field: "to_error",
      effects: effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
    ),
  ]
}

pub fn field_call_opaque_receiver_resolves_via_girard_test() {
  // With girard's type + the type annotation, the [Stdout] budget passes.
  let annotation =
    EffectAnnotation(
      Check,
      "run",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
      returns: None,
    )
  check_source_with_girard(
    opaque_receiver_source,
    [annotation],
    validator_to_error_stdout(),
  )
  |> should.equal([])
}

pub fn field_call_opaque_receiver_violates_pure_test() {
  // Dual: against a [] budget the recovered [Stdout] surfaces as a violation,
  // proving the field call actually resolved (vs. silently inferring []).
  let annotation =
    EffectAnnotation(
      Check,
      "run",
      [],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    )
  let violations =
    check_source_with_girard(
      opaque_receiver_source,
      [annotation],
      validator_to_error_stdout(),
    )
  let assert [violation] = violations
  violation.explanation.actual
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn field_call_aliased_receiver_resolves_via_girard_test() {
  // Receiver reached through an alias chain (`let w = v`) — both bindings are
  // opaque to the syntax-level path, but girard types `w` as Validator.
  let source =
    "
import gleam/io

pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}

fn make() -> Validator {
  Validator(to_error: io.println)
}

pub fn run(msg: String) -> Nil {
  let v = make()
  let w = v
  w.to_error(msg)
}
"
  let annotation =
    EffectAnnotation(
      Check,
      "run",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
      returns: None,
    )
  check_source_with_girard(source, [annotation], validator_to_error_stdout())
  |> should.equal([])
}

pub fn field_call_construction_without_annotation_resolves_test() {
  // No `type Validator.to_error` annotation exists, but the receiver is bound
  // from a same-module producer (`let v = make()`) whose return construction
  // wires `to_error` to io.println. Tier 2 grounds that construction per
  // receiver, so `v.to_error()` resolves to the precise [Stdout] without any
  // annotation — construction-derived field effects.
  let annotation =
    EffectAnnotation(
      Check,
      "run",
      [],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    )
  let violations =
    check_source_with_girard(opaque_receiver_source, [annotation], [])
  let assert [violation] = violations
  violation.explanation.actual
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// Same-module wired fields under girard's types
//
// A function wired into a record field is lifted out of the module's own
// definitions. That lift runs under the same `module_types` as every other
// analysis of the module, so a field call in the lifted body whose receiver only
// girard can type resolves there exactly as it does when the function is
// inferred directly.

// Which of the two comes first in the source: the function that is wired into
// the field, or the site that wires it.
type DeclarationOrder {
  WiredFirst
  InvokeFirst
}

// `config.inner` is a nested field access: the syntax-level path can't name its
// type, so `config.inner.run(message)` reaches the `Box.run` line only through
// girard's inferred type. `raw_invoke` is a bodyless `@external` with no
// `assume` line — there is no body to lift.
fn wired_receiver_source(order: DeclarationOrder) -> String {
  let types =
    "pub type Box {
  Box(run: fn(String) -> Nil)
}

pub type Config {
  Config(inner: Box)
}

pub type Handler {
  Handler(go: fn(Config, String) -> Nil)
}

@external(erlang, \"ffi_mod\", \"raw\")
fn raw_invoke(config: Config, message: String) -> Nil

pub fn perform(handler: Handler, config: Config, message: String) -> Nil {
  handler.go(config, message)
}

pub fn run_external(config: Config, message: String) -> Nil {
  perform(Handler(go: raw_invoke), config, message)
}
"
  let invoke =
    "pub fn invoke(config: Config, message: String) -> Nil {
  config.inner.run(message)
}
"
  let wired =
    "pub fn run_wired(config: Config, message: String) -> Nil {
  perform(Handler(go: invoke), config, message)
}
"
  case order {
    WiredFirst -> types <> wired <> invoke
    InvokeFirst -> types <> invoke <> wired
  }
}

fn box_run_stdout() -> List(types.FieldAnnotation) {
  [
    types.FieldAnnotation(
      module: None,
      type_name: "Box",
      field: "run",
      effects: effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
    ),
  ]
}

// Infer with girard's real types and a type-field annotation, returning each
// public function's inferred effect set by name.
fn infer_effects_with_girard(
  source: String,
  type_fields: List(types.FieldAnnotation),
) -> dict.Dict(String, types.EffectSet) {
  let assert Ok(module) = glance.module(source)
  checker.infer(
    module,
    "",
    effects.with_type_fields(knowledge_base(), type_fields, types.CommittedSpec),
    [],
    signatures.from_glance_module("", module),
    girard_types(module),
    dict.new(),
    types.all_targets(),
  )
  |> list.fold(dict.new(), fn(acc, a) {
    dict.insert(acc, a.function, effect_term.to_effect_set(a.effects))
  })
}

fn wired_receiver_effects(
  order: DeclarationOrder,
) -> dict.Dict(String, types.EffectSet) {
  infer_effects_with_girard(wired_receiver_source(order), box_run_stdout())
}

pub fn wired_local_function_lift_uses_module_types_test() {
  // Direct inference and the same-module wired lift agree: both reach [Stdout]
  // through `type Box.run`. Lifting without the module's types would leave a
  // residual `config.inner.run` variable, which is rejected as non-ground and
  // degrades to [Unknown].
  let inferred = wired_receiver_effects(InvokeFirst)
  dict.get(inferred, "invoke")
  |> should.equal(Ok(Specific(set.from_list(["Stdout"]))))
  dict.get(inferred, "run_wired")
  |> should.equal(Ok(Specific(set.from_list(["Stdout"]))))
}

pub fn wired_local_function_lift_is_order_independent_test() {
  // The lift shares the enclosing memo, whose `lifts` are keyed on
  // `#(name, ancestors)` with no type-environment component. Declaring the wired
  // site before the function it wires must not change either result.
  wired_receiver_effects(WiredFirst)
  |> should.equal(wired_receiver_effects(InvokeFirst))
}

pub fn wired_bodyless_external_stays_unknown_test() {
  // A field wired to a bodyless `@external` with no `assume` line has
  // no body to analyse; reading its empty one as pure would understate it.
  wired_receiver_effects(InvokeFirst)
  |> dict.get("run_external")
  |> should.equal(Ok(Specific(set.from_list(["Unknown"]))))
}

// The other two field-value shapes analysed away from their creation site: an
// inline closure and a producer call. Each body reaches `Box.run` only through
// girard's type for the closure parameter `c`.
const wired_operator_source = "
pub type Box {
  Box(run: fn(String) -> Nil)
}

pub type Config {
  Config(inner: Box)
}

pub type Handler {
  Handler(go: fn(Config, String) -> Nil)
}

pub fn perform(handler: Handler, config: Config, message: String) -> Nil {
  handler.go(config, message)
}

fn make_go() -> fn(Config, String) -> Nil {
  fn(c, m) { c.inner.run(m) }
}

pub fn run_closure(config: Config, message: String) -> Nil {
  perform(Handler(go: fn(c, m) { c.inner.run(m) }), config, message)
}

pub fn run_producer(config: Config, message: String) -> Nil {
  perform(Handler(go: make_go()), config, message)
}
"

pub fn wired_closure_field_uses_module_types_test() {
  // The closure is lifted into an operator away from its creation site.
  // Analysing it without the module's types leaves `c.inner.run` unresolved and
  // unions an [Unknown] into the caller alongside the [Stdout] the enclosing
  // body contributes.
  infer_effects_with_girard(wired_operator_source, box_run_stdout())
  |> dict.get("run_closure")
  |> should.equal(Ok(Specific(set.from_list(["Stdout"]))))
}

pub fn wired_producer_call_field_uses_module_types_test() {
  // Same for a field wired from a producer call: the returned-operator summary
  // is computed from the producer's body, which needs the module's types to
  // resolve the field call inside the closure it returns.
  infer_effects_with_girard(wired_operator_source, box_run_stdout())
  |> dict.get("run_producer")
  |> should.equal(Ok(Specific(set.from_list(["Stdout"]))))
}

// Field effects exceed declared budget → violation
pub fn field_call_violates_check_test() {
  let source = "pub fn view(handler: Handler) { handler.on_click(event) }"
  let type_fields = [
    types.FieldAnnotation(
      module: None,
      type_name: "Handler",
      field: "on_click",
      effects: effect_term.from_effect_set(Specific(set.from_list(["Dom"]))),
    ),
  ]
  let annotation =
    EffectAnnotation(
      Check,
      "view",
      [],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    )
  check_source_with_type_fields(source, [annotation], type_fields)
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Typed param but no registry entry → Unknown
pub fn field_call_typed_no_registry_is_unknown_test() {
  let source = "pub fn view(handler: Handler) { handler.on_click(event) }"
  let annotation =
    EffectAnnotation(
      Check,
      "view",
      [],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    )
  check_source_with_type_fields(source, [annotation], [])
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Untyped param → Unknown
pub fn field_call_untyped_is_unknown_test() {
  let source = "pub fn view(handler) { handler.on_click(event) }"
  let annotation =
    EffectAnnotation(
      Check,
      "view",
      [],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    )
  check_source(source, [annotation])
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Parameter-field precedence (Tier 1)
//
// A fn-typed field call resolves by: (1) a value proven for this receiver, (2) a
// `check` field bound, (3) a declared field `assume` line, (4) a live parameter root →
// a receiver-keyed field variable, (5) else `[Unknown]`. The nominal construction
// index never resolves an unproven receiver — a caller can build the record
// differently, so specializing a parameter/opaque receiver would understate.

// Infer `function`'s annotation in a single-module source, with the registry
// built from the module so fn-typed params are detected. `girard` threads girard's
// inferred types so a receiver typed only through an alias or nested path resolves.
fn infer_field_annotation_typed(
  source: String,
  function: String,
  girard: Bool,
) -> EffectAnnotation {
  let assert Ok(module) = glance.module(source)
  let registry = signatures.from_glance_module("", module)
  let module_types = case girard {
    False -> dict.new()
    True -> girard_types(module)
  }
  let inferred =
    checker.infer(
      module,
      "",
      knowledge_base(),
      [],
      registry,
      module_types,
      dict.new(),
      types.all_targets(),
    )
  let assert Ok(annotation) =
    list.find(inferred, fn(a) { a.function == function })
  annotation
}

fn infer_field_annotation(
  source: String,
  function: String,
) -> EffectAnnotation {
  infer_field_annotation_typed(source, function, False)
}

// girard's per-expression inferred types for a module, keyed by span, or empty
// when the type annotator declines the module.
fn girard_types(module: glance.Module) -> dict.Dict(#(Int, Int), girard.Type) {
  case girard.annotate_module(module, girard.default_options()) {
    Ok(annotated) ->
      list.fold(annotated.expressions, dict.new(), fn(acc, annotation) {
        dict.insert(
          acc,
          #(annotation.span.start, annotation.span.end),
          annotation.type_,
        )
      })
    Error(_) -> dict.new()
  }
}

pub fn field_call_parameter_root_stays_polymorphic_test() {
  // Rule 4: a fn-typed field of a parameter receiver stays polymorphic — the
  // call resolves to the receiver-keyed field variable `options.resolver`, which
  // forwards up rather than specializing to any package construction.
  let source =
    "pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn annotate(options: Options) -> Nil {
  options.resolver()
}
"
  let annotation = infer_field_annotation(source, "annotate")
  annotation.effects |> should.equal(types.TVar("options.resolver"))
}

pub fn field_call_parameter_alias_canonicalizes_test() {
  // A `let` alias of a parameter (`let f = options`) canonicalizes to the
  // parameter root, so `f.resolver()` resolves exactly like `options.resolver()`
  // — the field variable is keyed on `options.resolver`, not the dead `f.resolver`.
  let source =
    "pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn annotate(options: Options) -> Nil {
  let f = options
  f.resolver()
}
"
  let annotation = infer_field_annotation_typed(source, "annotate", True)
  annotation.effects |> should.equal(types.TVar("options.resolver"))
}

pub fn field_call_parameter_alias_resolves_without_girard_test() {
  // The canonicalized parameter path also drives the *syntactic* type fallback:
  // with girard unavailable, `let f = options; f.resolver()` still looks the
  // receiver up as the parameter `options` (not the dead alias `f`), so it keeps
  // resolving to the field variable rather than degrading to [Unknown].
  let source =
    "pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn annotate(options: Options) -> Nil {
  let f = options
  f.resolver()
}
"
  let annotation = infer_field_annotation(source, "annotate")
  annotation.effects |> should.equal(types.TVar("options.resolver"))
}

pub fn field_call_self_rebound_parameter_terminates_test() {
  // A parameter rebound to a path containing itself (`let options =
  // options.inner`) must not loop: aliases are canonicalized once at binding, so
  // resolution is a single substitution rather than a chase that could grow the
  // path without bound. Girard is absent here, so the nested receiver can't be
  // typed and the call is [Unknown]; reaching an assertion at all proves
  // termination.
  let source =
    "pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn annotate(options: Options) -> Nil {
  let options = options.inner
  options.resolver()
}
"
  let annotation = infer_field_annotation(source, "annotate")
  effect_term.to_effect_set(annotation.effects)
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

pub fn field_call_alias_survives_later_shadowing_test() {
  // An alias captured before its parameter is shadowed keeps resolving to the
  // *original* parameter: `let saved = options; let options = other;
  // saved.resolver()` is `options.resolver`, never `other.resolver`. The alias's
  // canonical path is fixed when it is created, so rebinding `options` afterwards
  // can't retarget it — otherwise a bound on the effectful original would be read
  // as the pure replacement.
  let source =
    "pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn annotate(options: Options, other: Options) -> Nil {
  let saved = options
  let options = other
  saved.resolver()
}
"
  let annotation = infer_field_annotation_typed(source, "annotate", True)
  annotation.effects |> should.equal(types.TVar("options.resolver"))
}

pub fn field_call_alias_matches_field_bound_test() {
  // A parameter alias keys its bound on the canonical parameter path, so a
  // `check annotate(options.resolver: [Stdout])` field bound matches `let f =
  // options; f.resolver()` — it discharges to [Stdout] (no violation against that
  // budget) and emits no spurious unmatched-field-bound warning for the alias.
  let source =
    "pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn annotate(options: Options) -> Nil {
  let f = options
  f.resolver()
}
"
  let assert Ok(module) = glance.module(source)
  let stdout = effect_term.from_effect_set(Specific(set.from_list(["Stdout"])))
  let annotation =
    EffectAnnotation(
      Check,
      "annotate",
      [ParamBound("options.resolver", stdout)],
      stdout,
      returns: None,
    )
  let #(violations, _findings, warnings) =
    checker.check(
      module,
      "",
      [annotation],
      knowledge_base(),
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations |> should.equal([])
  list.any(warnings, fn(w) {
    case w {
      UnmatchedFieldBoundWarning(..) -> True
      _ -> False
    }
  })
  |> should.be_false()
}

pub fn field_call_nested_parameter_path_stays_polymorphic_test() {
  // A nested parameter path (`config.options.resolver()`) stays polymorphic on
  // the whole path — the field variable is keyed on `config.options.resolver`.
  let source =
    "pub type Options {
  Options(resolver: fn() -> Nil)
}

pub type Config {
  Config(options: Options)
}

pub fn annotate(config: Config) -> Nil {
  config.options.resolver()
}
"
  let annotation = infer_field_annotation_typed(source, "annotate", True)
  annotation.effects |> should.equal(types.TVar("config.options.resolver"))
}

pub fn field_call_shadowed_parameter_is_unknown_test() {
  // A parameter shadowed by a later opaque `let` is untraceable — a field call
  // through a path rooted at the shadowing binding must NOT tie to the dead
  // parameter. `x.resolver()` resolves to [Unknown], proving classification
  // consults the env for the live root, not the syntactic path (`options` here
  // names the shadowing local, not the parameter).
  let source =
    "pub type Inner {
  Inner(resolver: fn() -> Nil)
}

pub type Wrapper {
  Wrapper(inner: Inner)
}

pub fn external_wrapper() -> Wrapper {
  Wrapper(inner: Inner(resolver: fn() { Nil }))
}

pub fn run(options: Wrapper) -> Nil {
  let options = external_wrapper()
  let x = options.inner
  x.resolver()
}
"
  let annotation = infer_field_annotation_typed(source, "run", True)
  effect_term.to_effect_set(annotation.effects)
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

pub fn field_call_opaque_call_result_is_unknown_test() {
  // Rule 5: a receiver bound from a call whose producer's return provenance
  // graded cannot build (`external_options`'s tail is itself a call, so its
  // provenance is opaque) is untraceable — never resolved by the nominal index,
  // so `o.resolver()` stays [Unknown].
  let source =
    "pub type Options {
  Options(resolver: fn() -> Nil)
}

fn make() -> Options {
  Options(resolver: fn() { Nil })
}

pub fn external_options() -> Options {
  make()
}

pub fn run() -> Nil {
  let o = external_options()
  o.resolver()
}
"
  let annotation = infer_field_annotation(source, "run")
  effect_term.to_effect_set(annotation.effects)
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

pub fn field_call_proven_value_beats_field_bound_test() {
  // Rule 1 > rule 2: a value proven wired to this receiver (`let v =
  // Validator(to_error: io.println)`) resolves to its real effect [Stdout] and is
  // NOT silenced by a `check caller(v.to_error: [])` field bound — concrete
  // evidence supersedes an annotation. Guards docs/REFERENCE.md's guarantee.
  let source =
    "import gleam/io

pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}

pub fn caller() -> Nil {
  let v = Validator(to_error: io.println)
  v.to_error(\"oops\")
}
"
  let assert Ok(module) = glance.module(source)
  // A field bound `v.to_error: []` that must NOT silence the proven [Stdout].
  let annotation =
    EffectAnnotation(
      Check,
      "caller",
      [
        ParamBound(
          "v.to_error",
          effect_term.from_effect_set(Specific(set.new())),
        ),
      ],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    )
  let #(violations, _findings, _warnings) =
    checker.check(
      module,
      "",
      [annotation],
      knowledge_base(),
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert Ok(v) = list.find(violations, fn(v) { v.function == "caller" })
  v.explanation.actual |> should.equal(Specific(set.from_list(["Stdout"])))
}

// External declarations
//
// `external` annotations resolve third-party and same-module `@external`
// calls that would otherwise be [Unknown].

fn check_source_with_assumes(
  source: String,
  annotations: List(EffectAnnotation),
  assumes: List(types.AssumeAnnotation),
) -> List(types.Violation) {
  let assert Ok(module) = glance.module(source)
  let kb = effects.with_assumes(knowledge_base(), assumes, types.UserAssume)
  let #(violations, _findings, _warnings) =
    checker.check(
      module,
      "",
      annotations,
      kb,
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations
}

// External resolves instead of Unknown
pub fn external_resolves_effects_test() {
  let source =
    "import gleam/httpc
pub fn fetch() { httpc.send(request) }"
  let assumes = [
    simple_assume("gleam/httpc", "send", ["Http"]),
  ]
  let annotation =
    EffectAnnotation(
      Check,
      "fetch",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Http"]))),
      returns: None,
    )
  check_source_with_assumes(source, [annotation], assumes)
  |> should.equal([])
}

// External effect exceeds budget → violation
pub fn external_violates_check_test() {
  let source =
    "import gleam/httpc
pub fn fetch() { httpc.send(request) }"
  let assumes = [
    simple_assume("gleam/httpc", "send", ["Http"]),
  ]
  let annotation =
    EffectAnnotation(
      Check,
      "fetch",
      [],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    )
  check_source_with_assumes(source, [annotation], assumes)
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

pub fn a_catalog_bounded_externals_bounds_reach_a_call_site_test() {
  // A bundled catalog file carrying a bounded external: its bounds reach a
  // consumer's call site and substitute the argument's actual effects. (The
  // catalog still loads no `where returns` tier — that's the clause half, and
  // it stays out; this pins the bounds half only.)
  let root =
    support.write_fixture("build/checker_catalog_bounded", [
      #(
        "catalog/a_pkg@1.0.0.graded",
        "assume shared/mod.each(f: [f]) : [f]\nassume shared/mod.disk : [Disk]\n",
      ),
      #(
        "manifest.toml",
        "packages = [\n  { name = \"a_pkg\", version = \"1.0.0\" },\n]\n",
      ),
    ])
  let #(functions, modules, param_bounds, type_fields) =
    effects.load_catalog(root <> "/catalog", root <> "/manifest.toml")
  let kb =
    effects.knowledge_base_from_catalog(
      root <> "/build/packages",
      effects.BundledCatalog(functions:, modules:, param_bounds:, type_fields:),
      dict.new(),
    )
  let source =
    "import shared/mod
pub fn run() { mod.each(f: mod.disk) }"
  let annotation =
    EffectAnnotation(
      Check,
      "run",
      [],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    )
  let assert Ok(module) = glance.module(source)
  let #(violations, _findings, _warnings) =
    checker.check(
      module,
      "",
      [annotation],
      kb,
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert [violation] = violations
  violation.explanation.actual
  |> should.equal(Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

// Infer `read_clock`'s effects in module `ffi_mod`, which wraps a bodyless
// same-module `@external` (`now`), under the given knowledge base.
fn infer_external_wrapper(kb: effects.KnowledgeBase) -> EffectSet {
  let source =
    "@external(erlang, \"ffi\", \"now\")
pub fn now() -> Int

pub fn read_clock() { now() }"
  let assert Ok(module) = glance.module(source)
  let inferred =
    checker.infer(
      module,
      "ffi_mod",
      kb,
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert Ok(annotation) =
    list.find(inferred, fn(a) { a.function == "read_clock" })
  effect_term.to_effect_set(annotation.effects)
}

// A same-module (unqualified) call into a bodyless `@external` inherits the
// effects declared for it in the knowledge base — qualified by the current
// module — not the `[Unknown]` an undeclared external yields. Regression for the
// FFI idiom: an `@external` binding paired with a same-module wrapper.
pub fn external_same_module_resolves_declared_effects_test() {
  let assumes = [
    simple_assume("ffi_mod", "now", ["Time"]),
  ]
  infer_external_wrapper(effects.with_assumes(
    knowledge_base(),
    assumes,
    types.UserAssume,
  ))
  |> should.equal(Specific(set.from_list(["Time"])))
}

// Without a declaration, a same-module call into a bodyless `@external` stays
// `[Unknown]` — the opaque-FFI default (`module_path` qualifies the lookup, so a
// wrong/absent entry never silently resolves to `[]`).
pub fn external_same_module_without_declaration_is_unknown_test() {
  infer_external_wrapper(knowledge_base())
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

// Wildcard budgets
//
// The `[_]` wildcard admits any effect, both as a function budget and as a
// parameter bound.

pub fn wildcard_declared_passes_all_effects_test() {
  let source =
    "import gleam/io
pub fn handler() { io.println(\"hi\") }"
  check_source(source, [
    EffectAnnotation(
      Check,
      "handler",
      [],
      effect_term.from_effect_set(Wildcard),
      returns: None,
    ),
  ])
  |> should.equal([])
}

pub fn wildcard_param_bound_passes_test() {
  let source = "pub fn apply(f, x) { f(x) }"
  let annotation =
    EffectAnnotation(
      Check,
      "apply",
      [ParamBound("f", effect_term.from_effect_set(Wildcard))],
      effect_term.from_effect_set(Wildcard),
      returns: None,
    )
  check_source(source, [annotation]) |> should.equal([])
}

pub fn wildcard_param_bound_in_pure_function_violates_test() {
  // f has wildcard effects but function declares []
  let source = "pub fn apply(f, x) { f(x) }"
  let annotation =
    EffectAnnotation(
      Check,
      "apply",
      [ParamBound("f", effect_term.from_effect_set(Wildcard))],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    )
  check_source(source, [annotation])
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Function reference warnings
//
// Effectful function references passed as values and dead (unmatched) bounds
// emit warnings; pure, unknown, and inline-closure cases stay silent.

fn check_warnings(
  source: String,
  annotations: List(EffectAnnotation),
) -> List(types.Warning) {
  let assert Ok(module) = glance.module(source)
  let #(_violations, _findings, warnings) =
    checker.check(
      module,
      "",
      annotations,
      knowledge_base(),
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  warnings
}

// Qualified function reference passed as value emits warning
pub fn function_ref_qualified_warns_test() {
  let source =
    "import gleam/io
import gleam/list
pub fn greet_all(names) { list.map(names, io.println) }"
  let warnings =
    check_warnings(source, [
      EffectAnnotation(
        Check,
        "greet_all",
        [],
        effect_term.from_effect_set(Specific(set.new())),
        returns: None,
      ),
    ])
  warnings |> list.length() |> should.equal(1)
  let assert [warning] = warnings
  let assert UntrackedEffectWarning(function:, reference:, effects:, ..) =
    warning
  function |> should.equal("greet_all")
  reference |> should.equal(QualifiedName("gleam/io", "println"))
  effects |> should.equal(Specific(set.from_list(["Stdout"])))
}

// Unqualified function reference passed as value emits warning
pub fn function_ref_unqualified_warns_test() {
  let source =
    "import gleam/io.{println}
import gleam/list
pub fn greet_all(names) { list.map(names, println) }"
  let warnings =
    check_warnings(source, [
      EffectAnnotation(
        Check,
        "greet_all",
        [],
        effect_term.from_effect_set(Specific(set.new())),
        returns: None,
      ),
    ])
  warnings |> list.length() |> should.equal(1)
  let assert [warning] = warnings
  let assert UntrackedEffectWarning(reference:, ..) = warning
  reference |> should.equal(QualifiedName("gleam/io", "println"))
}

// A field bound whose `param.field` path matches no field call in the body is
// dead (typically a typo) and emits a warning naming the path and function.
pub fn field_bound_unmatched_warns_test() {
  let source =
    "pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}
pub fn caller(v: Validator) -> Nil { v.to_error(\"bad\") }"
  let warnings =
    check_warnings(source, [
      EffectAnnotation(
        Check,
        "caller",
        // Typo: the body calls `v.to_error`, not `v.to_errorx`.
        [
          ParamBound(
            "v.to_errorx",
            effect_term.from_effect_set(Specific(set.new())),
          ),
        ],
        effect_term.from_effect_set(Specific(set.new())),
        returns: None,
      ),
    ])
  warnings |> list.length() |> should.equal(1)
  let assert [warning] = warnings
  let assert UnmatchedFieldBoundWarning(
    function:,
    field_path:,
    receiver_is_param:,
  ) = warning
  function |> should.equal("caller")
  field_path |> should.equal("v.to_errorx")
  // `v` is a parameter, so the cause is a genuine typo, not provenance shadowing.
  receiver_is_param |> should.be_true()
}

// A field bound whose path matches a real field call emits no warning.
pub fn field_bound_matched_no_warning_test() {
  let source =
    "pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}
pub fn caller(v: Validator) -> Nil { v.to_error(\"bad\") }"
  check_warnings(source, [
    EffectAnnotation(
      Check,
      "caller",
      [
        ParamBound(
          "v.to_error",
          effect_term.from_effect_set(Specific(set.new())),
        ),
      ],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    ),
  ])
  |> should.equal([])
}

// A plain parameter bound whose name matches no declared parameter is dead
// (a typo) and emits a warning naming the parameter and function.
pub fn param_bound_unmatched_warns_test() {
  let source = "pub fn apply(f, x) { f(x) }"
  let warnings =
    check_warnings(source, [
      EffectAnnotation(
        Check,
        "apply",
        // Typo: the parameter is `f`, not `g`.
        [ParamBound("g", effect_term.from_effect_set(Specific(set.new())))],
        effect_term.from_effect_set(Specific(set.new())),
        returns: None,
      ),
    ])
  warnings |> list.length() |> should.equal(1)
  let assert [warning] = warnings
  let assert UnmatchedParamBoundWarning(function:, param:) = warning
  function |> should.equal("apply")
  param |> should.equal("g")
}

// A parameter bound on a callback that's forwarded but never called directly
// still names a real parameter, so it stays load-bearing and emits no warning.
pub fn param_bound_forwarded_no_warning_test() {
  let source =
    "pub fn apply(f, x) { helper(f, x) }
pub fn helper(g, y) { g(y) }"
  check_warnings(source, [
    EffectAnnotation(
      Check,
      "apply",
      [ParamBound("f", effect_term.from_effect_set(Specific(set.new())))],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    ),
  ])
  |> should.equal([])
}

// When the field bound's receiver is a local traced to a construction site, the
// field call resolves through value provenance and never lands in the field
// list, so the bound is unmatched — but the cause is provenance shadowing, not a
// typo, and `receiver_is_param` is False to flag that.
pub fn field_bound_unmatched_non_param_receiver_test() {
  let source =
    "import gleam/io
pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}
pub fn caller() -> Nil {
  let v = Validator(io.println)
  v.to_error(\"bad\")
}"
  let warnings =
    check_warnings(source, [
      EffectAnnotation(
        Check,
        "caller",
        [
          ParamBound(
            "v.to_error",
            effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
          ),
        ],
        effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
        returns: None,
      ),
    ])
  // Construction also wires io.println as a value, emitting an untracked-effect
  // warning; pick out the field-bound one.
  let assert Ok(warning) =
    list.find(warnings, fn(w) {
      case w {
        UnmatchedFieldBoundWarning(..) -> True
        _ -> False
      }
    })
  let assert UnmatchedFieldBoundWarning(receiver_is_param:, ..) = warning
  // `v` is a local, not a parameter, so provenance shadowing is the likely cause.
  receiver_is_param |> should.be_false()
}

// Pure function reference does not emit warning
pub fn function_ref_pure_no_warning_test() {
  let source =
    "import gleam/list
import gleam/string
pub fn upper_all(items) { list.map(items, string.uppercase) }"
  check_warnings(source, [
    EffectAnnotation(
      Check,
      "upper_all",
      [],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    ),
  ])
  |> should.equal([])
}

// Unknown function reference does not emit warning
pub fn function_ref_unknown_no_warning_test() {
  let source =
    "import some/unknown
import gleam/list
pub fn run(items) { list.map(items, unknown.do_thing) }"
  check_warnings(source, [
    EffectAnnotation(
      Check,
      "run",
      [],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    ),
  ])
  |> should.equal([])
}

// Inline closure does not emit warning (effects tracked normally)
pub fn inline_closure_no_warning_test() {
  let source =
    "import gleam/io
import gleam/list
pub fn greet_all(names) { list.map(names, fn(n) { io.println(n) }) }"
  check_warnings(source, [
    EffectAnnotation(
      Check,
      "greet_all",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
      returns: None,
    ),
  ])
  |> should.equal([])
}

// Checker soundness (property)
//
// qcheck properties over generated modules: violations occur exactly when
// effects exceed the budget, and provenance never regresses the opaque
// baseline.

const call_pool = [
  #("mod_a", "call_http", "Http"),
  #("mod_b", "call_dom", "Dom"),
  #("mod_c", "call_stdout", "Stdout"),
  #("mod_d", "call_db", "Db"),
  #("mod_e", "call_fs", "FileSystem"),
]

fn call_selection_gen() -> qcheck.Generator(List(Bool)) {
  qcheck.fixed_length_list_from(qcheck.bool(), list.length(call_pool))
}

fn selected_calls(selections: List(Bool)) -> List(#(String, String, String)) {
  list.zip(call_pool, selections)
  |> list.filter_map(fn(pair) {
    case pair.1 {
      True -> Ok(pair.0)
      False -> Error(Nil)
    }
  })
}

fn build_module(
  calls: List(#(String, String, String)),
) -> Result(glance.Module, Nil) {
  let modules =
    calls
    |> list.map(fn(c) { c.0 })
    |> list.unique()
    |> list.sort(string.compare)
  let imports =
    modules |> list.map(fn(m) { "import " <> m }) |> string.join("\n")
  let body = case calls {
    [] -> "  Nil"
    _ ->
      calls
      |> list.map(fn(c) { "  " <> c.0 <> "." <> c.1 <> "()" })
      |> string.join("\n")
  }
  let source = imports <> "\npub fn test_fn() {\n" <> body <> "\n}\n"
  glance.module(source) |> result.replace_error(Nil)
}

fn build_kb(calls: List(#(String, String, String))) -> effects.KnowledgeBase {
  let all_effects =
    calls
    |> list.map(fn(c) {
      #(
        types.QualifiedName(module: c.0, function: c.1),
        #(
          effect_term.from_effect_set(types.from_labels([c.2])),
          types.CommittedSpec,
        ),
      )
    })
    |> dict.from_list()
  effects.KnowledgeBase(..bare_knowledge_base(), all_effects:)
}

fn actual_effects(calls: List(#(String, String, String))) -> EffectSet {
  calls |> list.map(fn(c) { c.2 }) |> types.from_labels()
}

pub fn check_no_false_positives_test() {
  use selections <- qcheck.given(call_selection_gen())
  let calls = selected_calls(selections)
  case build_module(calls) {
    Error(Nil) -> Nil
    Ok(module) -> {
      let kb = build_kb(calls)
      let declared = actual_effects(calls)
      let ann =
        EffectAnnotation(
          Check,
          "test_fn",
          [],
          effect_term.from_effect_set(declared),
          returns: None,
        )
      let #(violations, _findings, _) =
        checker.check(
          module,
          "",
          [ann],
          kb,
          signatures.empty(),
          dict.new(),
          dict.new(),
          types.all_targets(),
        )
      violations |> should.equal([])
    }
  }
}

// The effect a computed-receiver `caller` reports against a `(resolver: [label])
// : []` bound, run in-memory. `Specific(∅)` when nothing violated.
fn provenance_caller_effect(src: String, label: String) -> EffectSet {
  let assert Ok(module) = glance.module(src)
  let annotation =
    EffectAnnotation(
      Check,
      "caller",
      [
        ParamBound(
          "resolver",
          effect_term.from_effect_set(Specific(set.from_list([label]))),
        ),
      ],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    )
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [annotation],
      knowledge_base(),
      signatures.from_glance_module("", module),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  case list.find(violations, fn(v) { v.function == "caller" }) {
    Ok(violation) -> violation.explanation.actual
    Error(Nil) -> Specific(set.new())
  }
}

// The ground labels of an effect set (variables folded in), for the concrete-set
// comparison the provenance guard rail needs.
fn effect_labels_of(effect_set: EffectSet) -> set.Set(String) {
  case effect_set {
    Specific(labels) -> labels
    Polymorphic(labels, variables) -> set.union(labels, variables)
    Wildcard -> set.new()
  }
}

pub fn provenance_never_regresses_baseline_test() {
  // Regression guard rail, NOT a soundness proof: enabling return-value
  // provenance may only remove `Unknown` and add the concrete labels it stood
  // for. For concrete(S) = S \ {"Unknown"}, with W the provenance-off (opaque)
  // effect and P the provenance-on effect: concrete(W) ⊆ concrete(P), and
  // `Unknown ∈ P ⟹ Unknown ∈ W`. It cannot catch provenance resolving an
  // `Unknown` into an *incomplete* concrete set — that risk is held structurally
  // by reusing the trusted forwarding path and widening to Top.
  use program <- qcheck.given(generators.provenance_program_gen())
  let p =
    effect_labels_of(provenance_caller_effect(program.traced, program.label))
  let w =
    effect_labels_of(provenance_caller_effect(program.untraced, program.label))
  let concrete = fn(labels) { set.delete(labels, "Unknown") }
  // Provenance never drops a real label vs the opaque baseline.
  set.is_subset(concrete(w), of: concrete(p)) |> should.be_true()
  // Provenance never introduces an `Unknown` the opaque baseline didn't have.
  case set.contains(p, "Unknown") {
    True -> set.contains(w, "Unknown") |> should.be_true()
    False -> Nil
  }
}

pub fn check_wildcard_never_violates_test() {
  use selections <- qcheck.given(call_selection_gen())
  let calls = selected_calls(selections)
  case build_module(calls) {
    Error(Nil) -> Nil
    Ok(module) -> {
      let kb = build_kb(calls)
      let ann =
        EffectAnnotation(
          Check,
          "test_fn",
          [],
          effect_term.from_effect_set(Wildcard),
          returns: None,
        )
      let #(violations, _findings, _) =
        checker.check(
          module,
          "",
          [ann],
          kb,
          signatures.empty(),
          dict.new(),
          dict.new(),
          types.all_targets(),
        )
      violations |> should.equal([])
    }
  }
}

pub fn check_empty_budget_detects_effects_test() {
  use selections <- qcheck.given(call_selection_gen())
  let calls = selected_calls(selections)
  case calls {
    [] -> Nil
    _ ->
      case build_module(calls) {
        Error(Nil) -> Nil
        Ok(module) -> {
          let kb = build_kb(calls)
          let ann =
            EffectAnnotation(
              Check,
              "test_fn",
              [],
              effect_term.from_effect_set(types.empty()),
              returns: None,
            )
          let #(violations, _findings, _) =
            checker.check(
              module,
              "",
              [ann],
              kb,
              signatures.empty(),
              dict.new(),
              dict.new(),
              types.all_targets(),
            )
          { violations != [] } |> should.be_true()
        }
      }
  }
}

pub fn check_violations_iff_not_subset_test() {
  use #(selections, declared) <- qcheck.given(
    qcheck.map2(call_selection_gen(), generators.effect_set_gen(), fn(s, d) {
      #(s, d)
    }),
  )
  let calls = selected_calls(selections)
  case build_module(calls) {
    Error(Nil) -> Nil
    Ok(module) -> {
      let kb = build_kb(calls)
      let ann =
        EffectAnnotation(
          Check,
          "test_fn",
          [],
          effect_term.from_effect_set(declared),
          returns: None,
        )
      let #(violations, _findings, _) =
        checker.check(
          module,
          "",
          [ann],
          kb,
          signatures.empty(),
          dict.new(),
          dict.new(),
          types.all_targets(),
        )
      let has_violations = violations != []
      let actual = actual_effects(calls)
      let not_subset = !types.is_subset(actual, declared)
      has_violations |> should.equal(not_subset)
    }
  }
}

pub fn infer_matches_actual_effects_test() {
  use selections <- qcheck.given(call_selection_gen())
  let calls = selected_calls(selections)
  case build_module(calls) {
    Error(Nil) -> Nil
    Ok(module) -> {
      let kb = build_kb(calls)
      let inferred =
        checker.infer(
          module,
          "",
          kb,
          [],
          signatures.empty(),
          dict.new(),
          dict.new(),
          types.all_targets(),
        )
      let assert [ann] = inferred
      ann.function |> should.equal("test_fn")
      effect_term.to_effect_set(ann.effects)
      |> should.equal(actual_effects(calls))
    }
  }
}

// Cycle detection (property)
//
// Infer and check terminate on generated call graphs containing cycles.

fn cycle_graph_gen() -> qcheck.Generator(List(#(String, List(String)))) {
  let names = ["a", "b", "c", "d"]
  let callees_gen =
    qcheck.map(
      qcheck.fixed_length_list_from(qcheck.bool(), list.length(names)),
      fn(bools) {
        list.zip(names, bools)
        |> list.filter_map(fn(pair) {
          case pair.1 {
            True -> Ok(pair.0)
            False -> Error(Nil)
          }
        })
      },
    )
  qcheck.map(
    qcheck.fixed_length_list_from(callees_gen, list.length(names)),
    fn(all_callees) { list.zip(names, all_callees) },
  )
}

fn build_cycle_source(graph: List(#(String, List(String)))) -> String {
  graph
  |> list.index_map(fn(entry, i) {
    let #(name, callees) = entry
    let visibility = case i {
      0 -> "pub "
      _ -> ""
    }
    let body = case callees {
      [] -> "  Nil"
      cs -> cs |> list.map(fn(c) { "  " <> c <> "()" }) |> string.join("\n")
    }
    visibility <> "fn " <> name <> "() {\n" <> body <> "\n}"
  })
  |> string.join("\n")
}

fn bare_knowledge_base() -> effects.KnowledgeBase {
  effects.new_knowledge_base()
}

pub fn infer_terminates_with_cycles_test() {
  use graph <- qcheck.given(cycle_graph_gen())
  let source = build_cycle_source(graph)
  case glance.module(source) {
    Error(_) -> Nil
    Ok(module) -> {
      let inferred =
        checker.infer(
          module,
          "",
          bare_knowledge_base(),
          [],
          signatures.empty(),
          dict.new(),
          dict.new(),
          types.all_targets(),
        )
      let assert [ann] = inferred
      ann.function |> should.equal("a")
    }
  }
}

pub fn check_terminates_with_cycles_test() {
  use graph <- qcheck.given(cycle_graph_gen())
  let source = build_cycle_source(graph)
  case glance.module(source) {
    Error(_) -> Nil
    Ok(module) -> {
      let ann =
        EffectAnnotation(
          Check,
          "a",
          [],
          effect_term.from_effect_set(types.empty()),
          returns: None,
        )
      let #(violations, _findings, _) =
        checker.check(
          module,
          "",
          [ann],
          bare_knowledge_base(),
          signatures.empty(),
          dict.new(),
          dict.new(),
          types.all_targets(),
        )
      violations |> should.equal([])
    }
  }
}

// Polymorphic auto-inference
//
// Fn-typed parameters get auto-generated effect variables and matching
// bounds; existing check bounds take priority.

fn infer_single(source: String) -> EffectAnnotation {
  let assert Ok(module) = glance.module(source)
  let assert [ann] =
    checker.infer(
      module,
      "",
      knowledge_base(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  ann
}

// The inferred effect set of a single-function source — `infer_single` reduced
// to its ground effect set, for the let-bound-closure cases.
fn infer_effect(source: String) -> EffectSet {
  effect_term.to_effect_set(infer_single(source).effects)
}

pub fn infer_fn_typed_param_emits_variable_test() {
  let source =
    "
pub fn apply(f: fn(Int) -> Int, x: Int) -> Int {
  f(x)
}
"
  let ann = infer_single(source)
  ann.function |> should.equal("apply")
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Polymorphic(set.new(), set.from_list(["f"])))
  ann.params
  |> should.equal([
    ParamBound(
      "f",
      effect_term.from_effect_set(Polymorphic(set.new(), set.from_list(["f"]))),
    ),
  ])
}

pub fn infer_fn_typed_param_with_concrete_effect_test() {
  let source =
    "
import gleam/io
pub fn log_and_apply(f: fn(Int) -> Int, x: Int) -> Int {
  io.println(\"start\")
  f(x)
}
"
  let ann = infer_single(source)
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Polymorphic(set.from_list(["Stdout"]), set.from_list(["f"])))
  ann.params
  |> should.equal([
    ParamBound(
      "f",
      effect_term.from_effect_set(Polymorphic(set.new(), set.from_list(["f"]))),
    ),
  ])
}

pub fn infer_multiple_fn_typed_params_test() {
  let source =
    "
pub fn apply2(f: fn(Int) -> Int, g: fn(Int) -> Int, x: Int) -> Int {
  g(f(x))
}
"
  let ann = infer_single(source)
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Polymorphic(set.new(), set.from_list(["f", "g"])))
  ann.params
  |> should.equal([
    ParamBound(
      "f",
      effect_term.from_effect_set(Polymorphic(set.new(), set.from_list(["f"]))),
    ),
    ParamBound(
      "g",
      effect_term.from_effect_set(Polymorphic(set.new(), set.from_list(["g"]))),
    ),
  ])
}

pub fn infer_existing_check_bound_takes_priority_test() {
  // User wrote a concrete check bound; auto-inference should not
  // produce a variable for the same parameter.
  let source =
    "
pub fn apply(f: fn(Int) -> Int, x: Int) -> Int {
  f(x)
}
"
  let assert Ok(module) = glance.module(source)
  let existing =
    EffectAnnotation(
      Check,
      "apply",
      [
        ParamBound(
          "f",
          effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
        ),
      ],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
      returns: None,
    )
  let assert [ann] =
    checker.infer(
      module,
      "",
      knowledge_base(),
      [existing],
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Specific(set.from_list(["Stdout"])))
  ann.params |> should.equal([])
}

pub fn infer_unannotated_param_remains_unknown_test() {
  // Without a type annotation on `f`, glance can't tell it's fn-typed.
  // Should still fall back to [Unknown] rather than auto-generating a var.
  let source =
    "
pub fn apply(f, x) {
  f(x)
}
"
  let ann = infer_single(source)
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Specific(set.from_list(["Unknown"])))
  ann.params |> should.equal([])
}

// Call-site substitution
//
// Arguments at a polymorphic call site bind the callee's effect variables:
// constructors and function references resolve, unresolvable expressions keep
// [Unknown].

// KB pre-seeded with a polymorphic callee: `validate_range(to_error: [to_error]) : [to_error]`.
fn polymorphic_kb() -> effects.KnowledgeBase {
  let polymorphic = Polymorphic(set.new(), set.from_list(["to_error"]))
  let effects_map =
    dict.from_list([
      #(QualifiedName("validation", "validate_range"), polymorphic),
    ])
  let params_map =
    dict.from_list([
      #(QualifiedName("validation", "validate_range"), [
        ParamBound(
          "to_error",
          effect_term.from_effect_set(Polymorphic(
            set.new(),
            set.from_list(["to_error"]),
          )),
        ),
      ]),
    ])
  effects.empty_knowledge_base()
  |> effects.with_inferred(
    dict.map_values(effects_map, fn(_, v) { effect_term.from_effect_set(v) }),
    types.ProjectInferred,
  )
  |> effects.with_inferred_params(params_map)
}

pub fn substitute_constructor_at_call_site_test() {
  // Caller passes a type constructor (pure) to the fn-typed param.
  let source =
    "
import validation
pub fn new() {
  validation.validate_range(42, to_error: MyError)
}
"
  let assert Ok(module) = glance.module(source)
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [
        EffectAnnotation(
          Check,
          "new",
          [],
          effect_term.from_effect_set(Specific(set.new())),
          returns: None,
        ),
      ],
      polymorphic_kb(),
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations |> should.equal([])
}

pub fn substitute_effectful_function_ref_test() {
  // Caller passes io.println (has [Stdout]) to the fn-typed param.
  // The check declares budget [Stdout], so no violation.
  let source =
    "
import gleam/io
import validation
pub fn new() {
  validation.validate_range(42, to_error: io.println)
}
"
  let assert Ok(module) = glance.module(source)
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [
        EffectAnnotation(
          Check,
          "new",
          [],
          effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
          returns: None,
        ),
      ],
      polymorphic_kb(),
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations |> should.equal([])
}

pub fn substitute_effectful_function_ref_violates_pure_budget_test() {
  // io.println → [Stdout] → violates [] budget.
  let source =
    "
import gleam/io
import validation
pub fn new() {
  validation.validate_range(42, to_error: io.println)
}
"
  let assert Ok(module) = glance.module(source)
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [
        EffectAnnotation(
          Check,
          "new",
          [],
          effect_term.from_effect_set(Specific(set.new())),
          returns: None,
        ),
      ],
      polymorphic_kb(),
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  list.length(violations) |> should.equal(1)
}

pub fn substitute_infer_resolves_polymorphic_call_test() {
  // Infer a caller that uses validate_range with a constructor —
  // the caller's effects should be [] (not [Unknown] or [to_error]).
  let source =
    "
import validation
pub fn new() {
  validation.validate_range(42, to_error: MyError)
}
"
  let assert Ok(module) = glance.module(source)
  let assert [ann] =
    checker.infer(
      module,
      "",
      polymorphic_kb(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  effect_term.to_effect_set(ann.effects) |> should.equal(Specific(set.new()))
}

pub fn substitute_unresolvable_argument_keeps_variable_test() {
  // Caller passes an arbitrary expression (an arithmetic result, not
  // a function reference or constructor) in the fn-typed position.
  // The variable can't bind to anything concrete, so substitution
  // should leave it polymorphic with [Unknown] standing in for the
  // unresolved callback's effects.
  let source =
    "
import validation
pub fn new() {
  validation.validate_range(42, to_error: 1 + 2)
}
"
  let assert Ok(module) = glance.module(source)
  let assert [ann] =
    checker.infer(
      module,
      "",
      polymorphic_kb(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

// KB with a two-callback polymorphic function:
//   apply2(f: [f], g: [g]) : [f, g]
fn two_callback_kb() -> effects.KnowledgeBase {
  let effect_set = Polymorphic(set.new(), set.from_list(["f", "g"]))
  let effects_map =
    dict.from_list([
      #(QualifiedName("combo", "apply2"), effect_set),
      #(QualifiedName("fx", "stdout_fn"), Specific(set.from_list(["Stdout"]))),
      #(QualifiedName("fx", "http_fn"), Specific(set.from_list(["Http"]))),
    ])
  let params_map =
    dict.from_list([
      #(QualifiedName("combo", "apply2"), [
        ParamBound(
          "f",
          effect_term.from_effect_set(Polymorphic(
            set.new(),
            set.from_list(["f"]),
          )),
        ),
        ParamBound(
          "g",
          effect_term.from_effect_set(Polymorphic(
            set.new(),
            set.from_list(["g"]),
          )),
        ),
      ]),
    ])
  effects.empty_knowledge_base()
  |> effects.with_inferred(
    dict.map_values(effects_map, fn(_, v) { effect_term.from_effect_set(v) }),
    types.ProjectInferred,
  )
  |> effects.with_inferred_params(params_map)
}

pub fn substitute_same_module_local_call_test() {
  // `outer` calls a same-module local helper that takes a callback.
  // Without local-call substitution, `outer` would inherit `[g]`
  // unresolved. With it, the constructor argument binds g → [],
  // so `outer` infers as pure.
  let source =
    "
pub type MyError {
  Oops(value: Int)
}
fn helper(g: fn(Int) -> MyError, x: Int) -> MyError {
  g(x)
}
pub fn outer() -> MyError {
  helper(Oops, 42)
}
"
  let assert Ok(module) = glance.module(source)
  let inferred =
    checker.infer(
      module,
      "",
      knowledge_base(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert Ok(outer) = list.find(inferred, fn(a) { a.function == "outer" })
  effect_term.to_effect_set(outer.effects) |> should.equal(Specific(set.new()))
}

pub fn substitute_two_fn_typed_params_different_effects_test() {
  // f binds to fx.stdout_fn → [Stdout], g binds to fx.http_fn → [Http].
  // Result should be [Http, Stdout].
  let source =
    "
import combo
import fx
pub fn run() {
  combo.apply2(f: fx.stdout_fn, g: fx.http_fn)
}
"
  let assert Ok(module) = glance.module(source)
  let assert [ann] =
    checker.infer(
      module,
      "",
      two_callback_kb(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Specific(set.from_list(["Http", "Stdout"])))
}

// Two-hop effect unification
//
// Effect variables thread through chains of polymorphic forwarders and
// resolve at the outermost call site.

fn list_registry() -> signatures.SignatureRegistry {
  let source =
    "pub fn map(over l: List(a), with fun: fn(a) -> b) -> List(b) { l }"
  let assert Ok(module) = glance.module(source)
  signatures.from_glance_module("gleam/list", module)
}

fn infer_single_with_list(source: String) -> types.EffectAnnotation {
  let assert Ok(module) = glance.module(source)
  let assert [ann] =
    checker.infer(
      module,
      "",
      knowledge_base(),
      [],
      list_registry(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  ann
}

pub fn two_hop_infer_polymorphic_test() {
  let source =
    "
import gleam/list
pub fn apply_twice(f: fn(Int) -> Int, x: Int) -> List(Int) {
  list.map([x], f)
}
"
  let ann = infer_single_with_list(source)
  ann.function |> should.equal("apply_twice")
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Polymorphic(set.new(), set.from_list(["f"])))
}

fn apply_twice_kb_and_registry() -> #(
  effects.KnowledgeBase,
  signatures.SignatureRegistry,
) {
  let kb =
    effects.empty_knowledge_base()
    |> effects.with_inferred(
      dict.from_list([
        #(
          QualifiedName("mymod", "apply_twice"),
          effect_term.from_effect_set(Polymorphic(
            set.new(),
            set.from_list(["f"]),
          )),
        ),
      ]),
      types.ProjectInferred,
    )
    |> effects.with_inferred_params(
      dict.from_list([
        #(QualifiedName("mymod", "apply_twice"), [
          ParamBound(
            "f",
            effect_term.from_effect_set(Polymorphic(
              set.new(),
              set.from_list(["f"]),
            )),
          ),
        ]),
      ]),
    )
  let apply_twice_src =
    "pub fn apply_twice(f: fn(Int) -> Int, x: Int) -> List(Int) { [] }"
  let assert Ok(at_module) = glance.module(apply_twice_src)
  let reg =
    signatures.merge(
      list_registry(),
      signatures.from_glance_module("mymod", at_module),
    )
  #(kb, reg)
}

fn check_run_against_budget(budget: EffectSet) -> List(types.Violation) {
  let #(kb, reg) = apply_twice_kb_and_registry()
  let source =
    "
import gleam/io
import mymod
pub fn run(x: Int) {
  mymod.apply_twice(io.println, x)
}
"
  let assert Ok(module) = glance.module(source)
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [
        EffectAnnotation(
          Check,
          "run",
          [],
          effect_term.from_effect_set(budget),
          returns: None,
        ),
      ],
      kb,
      reg,
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations
}

pub fn two_hop_check_with_effectful_arg_passes_test() {
  check_run_against_budget(Specific(set.from_list(["Stdout"])))
  |> should.equal([])
}

pub fn two_hop_check_with_empty_budget_violates_test() {
  // Dual of the passes-test: with [] budget, the observed [Stdout] must
  // surface as a violation — proves the polymorphic call site actually
  // resolved io.println's effects rather than inferring [].
  let violations = check_run_against_budget(Specific(set.new()))
  let assert [v, ..] = violations
  v.function |> should.equal("run")
  v.explanation.actual |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn three_hop_local_chain_infers_polymorphic_test() {
  let source =
    "
import gleam/list
fn inner(h: fn(Int) -> Int, x: Int) -> List(Int) {
  list.map([x], h)
}
fn middle(g: fn(Int) -> Int, x: Int) -> List(Int) {
  inner(g, x)
}
pub fn outer(f: fn(Int) -> Int, x: Int) -> List(Int) {
  middle(f, x)
}
"
  let ann = infer_single_with_list(source)
  ann.function |> should.equal("outer")
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Polymorphic(set.new(), set.from_list(["f"])))
}

pub fn two_hop_mixed_forwarder_test() {
  let source =
    "
import gleam/io
import gleam/list
pub fn log_and_map(f: fn(Int) -> Int, x: Int) -> List(Int) {
  io.println(\"mapping\")
  list.map([x], f)
}
"
  let ann = infer_single_with_list(source)
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Polymorphic(set.from_list(["Stdout"]), set.from_list(["f"])))
}

pub fn pure_forward_infers_polymorphic_test() {
  let source =
    "
import gleam/list
pub fn pure_forward(f: fn(Int) -> Int, items: List(Int)) -> List(Int) {
  list.map(items, f)
}
"
  let ann = infer_single_with_list(source)
  ann.function |> should.equal("pure_forward")
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Polymorphic(set.new(), set.from_list(["f"])))
}

pub fn inline_closure_does_not_trigger_auto_bounds_test() {
  // Passing an inline closure should NOT activate auto-bounds — the
  // closure's body is walked separately by the extractor, and binding
  // the synthesised effect variable would spuriously add [Unknown].
  let source =
    "
import gleam/list
pub fn with_closure(items: List(Int)) -> List(Int) {
  list.map(items, fn(x) { x + 1 })
}
"
  let ann = infer_single_with_list(source)
  effect_term.to_effect_set(ann.effects) |> should.equal(types.empty())
}

pub fn mixed_tracked_and_closure_args_test() {
  // A callee with two fn-typed params, one passed a tracked ref and the
  // other an inline closure. Only the tracked param produces an auto-bound
  // — the closure's body is walked separately. `helpers.do_both` is seeded
  // as pure so the result isolates the auto-bounds contribution.
  let do_both_src =
    "pub fn do_both(f: fn(Int) -> Int, g: fn(Int) -> Int, x: Int) -> Int { x }"
  let assert Ok(db_module) = glance.module(do_both_src)
  let reg =
    signatures.merge(
      list_registry(),
      signatures.from_glance_module("helpers", db_module),
    )
  let kb =
    effects.empty_knowledge_base()
    |> effects.with_inferred(
      dict.from_list([
        #(
          QualifiedName("helpers", "do_both"),
          effect_term.from_effect_set(types.empty()),
        ),
      ]),
      types.ProjectInferred,
    )
  let source =
    "
import helpers
pub fn run(h: fn(Int) -> Int, x: Int) -> Int {
  helpers.do_both(h, fn(y) { y + 1 }, x)
}
"
  let assert Ok(module) = glance.module(source)
  let assert [ann] =
    checker.infer(
      module,
      "",
      kb,
      [],
      reg,
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  ann.function |> should.equal("run")
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Polymorphic(set.new(), set.from_list(["h"])))
}

// Polymorphic field-call substitution
//
// A field wired to a polymorphic function binds the field call's arguments to
// its effect variables, including inline closures.

// Check `t.go(<arg>, msg)` where `t` is a receiver *proven* to wire `go` to the
// polymorphic same-module function `run_it` (effect variable `action`). The
// let-bound construction makes the field value concrete for this receiver, so the
// field call resolves through it — a `LocalRef` field resolves to a plain call at
// the construction site — and the call's arguments bind `run_it`'s `action`
// variable, exactly as an ordinary second-order call does.
fn check_field_call(arg: String) -> List(types.Violation) {
  let source = "
import gleam/io
pub type Wrapper {
  Wrapper
}
pub type Task {
  Task(go: fn(fn(String) -> Nil, String) -> Nil)
}
fn run_it(action: fn(String) -> Nil, msg: String) -> Nil {
  action(msg)
}
pub fn main(msg: String) {
  let t = Task(go: run_it)
  t.go(" <> arg <> ", msg)
}
"
  let assert Ok(module) = glance.module(source)
  let registry = signatures.from_glance_module("", module)
  let #(violations, _findings, _warnings) =
    checker.check(
      module,
      "",
      [
        EffectAnnotation(
          Check,
          "main",
          [],
          effect_term.from_effect_set(Specific(set.new())),
          returns: None,
        ),
      ],
      knowledge_base(),
      registry,
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations
}

pub fn field_call_binds_effectful_argument_test() {
  // t.go(io.println, msg): the field's `action` variable binds to io.println's
  // [Stdout], so the [] budget fails with the precise [Stdout] — not a leaked
  // free variable.
  let assert [v, ..] = check_field_call("io.println")
  v.function |> should.equal("main")
  v.explanation.actual |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn field_call_binds_pure_argument_test() {
  // A constructor argument is pure, so `action` binds to [] and the field call
  // has no effect — no violation against the [] budget.
  check_field_call("Wrapper") |> should.equal([])
}

pub fn field_call_binds_identity_closure_test() {
  // An inline closure bound to a (first-order) field parameter resolves to its
  // body effect. The identity closure `fn(s) { s }` is pure, so the field call
  // has no effect — no violation. (Previously a closure here couldn't bind and
  // collapsed conservatively to [Unknown].)
  check_field_call("fn(s) { s }") |> should.equal([])
}

pub fn field_call_binds_effectful_closure_test() {
  // An effectful inline closure bound to a field parameter resolves to its body
  // effect: `fn(s) { io.println(s) }` ⟹ [Stdout].
  let assert [v, ..] = check_field_call("fn(s) { io.println(s) }")
  v.explanation.actual |> should.equal(Specific(set.from_list(["Stdout"])))
}

// Factory field provenance
//
// A receiver traced to a factory call resolves its fields from the factory's
// arguments, same-module or cross-module; untraceable receivers stay
// [Unknown].

pub fn factory_field_resolves_same_module_test() {
  // A same-module factory wires a field to its parameter; a let-bound factory
  // call binds the result's field, so `v.to_error` resolves to the argument's
  // effect ([Stdout]) instead of [Unknown].
  let source =
    "
import gleam/io
pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}
fn make(logger: fn(String) -> Nil) -> Validator {
  Validator(to_error: logger)
}
pub fn caller() -> Nil {
  let v = make(io.println)
  v.to_error(\"x\")
}
"
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
}

pub fn factory_field_resolves_cross_module_test() {
  // The package-wide factory map records a cross-module factory's signature, so
  // a let-bound `dep.make(io.println)` binds the result's field.
  let source =
    "
import gleam/io
import dep
pub fn caller() -> Nil {
  let v = dep.make(io.println)
  v.to_error(\"x\")
}
"
  let assert Ok(module) = glance.module(source)
  let kb =
    knowledge_base()
    |> effects.with_inferred(
      dict.from_list([
        #(
          QualifiedName("dep", "make"),
          effect_term.from_effect_set(types.empty()),
        ),
      ]),
      types.ProjectInferred,
    )
    |> effects.with_factories(
      dict.from_list([
        #(
          #("dep", "make"),
          types.FactorySignature(
            fields: dict.from_list([#("to_error", 0)]),
            param_labels: dict.new(),
            constructor: types.BuiltConstructor(
              module: "dep",
              variant: "Validator",
            ),
          ),
        ),
      ]),
    )
  let registry = signatures.from_glance_module("app", module)
  let pass =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
      returns: None,
    )
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [pass],
      kb,
      registry,
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations |> should.equal([])
  let fail =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(types.empty()),
      returns: None,
    )
  let #(failed, _findings, _) =
    checker.check(
      module,
      "",
      [fail],
      kb,
      registry,
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  { failed != [] } |> should.be_true()
}

pub fn factory_untraceable_receiver_stays_unknown_test() {
  // A receiver with no traceable construction (here a parameter) can't use
  // factory provenance; with no type-field annotation it stays the sound
  // [Unknown] — so the [Stdout] budget is still flagged (no resolution, no
  // understatement).
  let source =
    "
pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}
pub fn caller(v: Validator) -> Nil {
  v.to_error(\"x\")
}
"
  { second_order_violations(source, "caller", ["Stdout"]) != [] }
  |> should.be_true()
}

pub fn factory_labeled_call_falls_back_test() {
  // v1 routes positional factory calls only; a labeled call falls back
  // conservatively (no BoundConstructor), so it does not resolve to [Stdout].
  let source =
    "
import gleam/io
pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}
fn make(logger: fn(String) -> Nil) -> Validator {
  Validator(to_error: logger)
}
pub fn caller() -> Nil {
  let v = make(logger: io.println)
  v.to_error(\"x\")
}
"
  { second_order_violations(source, "caller", ["Stdout"]) != [] }
  |> should.be_true()
}

// Second-order effect variables, end-to-end
//
// Nested effect variables (operator applications) resolve through call sites,
// let bindings, returned functions, pipes, use expressions, and branches.

// Registry + KB modelling the realistic post-topological-inference state:
// `with_logger(action)` is second-order — its inferred effect is the operator
// application `action(Stdout)` (it applies `action` to a [Stdout] callback),
// and `runner(cb)` runs its callback (effect `[cb]`).
fn second_order_kb_and_registry() -> #(
  effects.KnowledgeBase,
  signatures.SignatureRegistry,
) {
  let sig_src =
    "pub fn with_logger(action: fn(fn(String) -> Nil) -> Nil) -> Nil { Nil }
pub fn runner(cb: fn(String) -> Nil) -> Nil { Nil }"
  let assert Ok(sig_mod) = glance.module(sig_src)
  let reg = signatures.from_glance_module("app", sig_mod)
  let kb =
    knowledge_base()
    |> effects.with_inferred(
      dict.from_list([
        #(
          QualifiedName("app", "with_logger"),
          types.TApp(
            types.TVar("action"),
            effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
          ),
        ),
        #(QualifiedName("app", "runner"), types.TVar("cb")),
      ]),
      types.ProjectInferred,
    )
    |> effects.with_inferred_params(
      dict.from_list([
        #(QualifiedName("app", "with_logger"), [
          ParamBound("action", types.TVar("action")),
        ]),
        #(QualifiedName("app", "runner"), [ParamBound("cb", types.TVar("cb"))]),
      ]),
    )
  #(kb, reg)
}

pub fn second_order_call_site_resolves_test() {
  // `caller` passes `runner` (an operator argument) to the second-order
  // `with_logger`. The operator application `action(Stdout)` must beta-reduce
  // with `action := λcb. [cb]` to `[Stdout]` — so a `[Stdout]` budget passes.
  let #(kb, reg) = second_order_kb_and_registry()
  let source =
    "import app
pub fn caller() -> Nil { app.with_logger(app.runner) }"
  let assert Ok(module) = glance.module(source)
  let ann =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
      returns: None,
    )
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [ann],
      kb,
      reg,
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations |> should.equal([])
}

pub fn second_order_call_site_detects_violation_test() {
  // Same call, but a pure budget `[]` must flag a violation: the resolved
  // effect is genuinely `[Stdout]`, not empty.
  let #(kb, reg) = second_order_kb_and_registry()
  let source =
    "import app
pub fn caller() -> Nil { app.with_logger(app.runner) }"
  let assert Ok(module) = glance.module(source)
  let ann =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(types.empty()),
      returns: None,
    )
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [ann],
      kb,
      reg,
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  { violations != [] } |> should.be_true()
}

pub fn second_order_inline_closure_resolves_test() {
  // The operator argument is now an inline closure rather than a named
  // function. It is analysed and lifted to `λlogger. [logger]`, so the
  // `action(Stdout)` application still beta-reduces to `[Stdout]`.
  let #(kb, reg) = second_order_kb_and_registry()
  let source =
    "import app
pub fn caller() -> Nil { app.with_logger(fn(logger) { logger(\"hi\") }) }"
  let assert Ok(module) = glance.module(source)
  let ann =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
      returns: None,
    )
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [ann],
      kb,
      reg,
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations |> should.equal([])
}

pub fn infer_operator_param_resolves_non_first_callback_test() {
  // `action`'s callback is its SECOND argument (`fn(Int, fn(String) -> Nil)`).
  // The call `action(1, io.println)` must build the operator application
  // `action(Stdout)` — resolving the position-1 argument (io.println), not the
  // position-0 Int literal. Reading position 0 would yield `action([Unknown])`.
  let source =
    "
import gleam/io
pub fn run(action: fn(Int, fn(String) -> Nil) -> Nil) -> Nil {
  action(1, io.println)
}
"
  let ann = infer_single(source)
  ann.function |> should.equal("run")
  ann.effects
  |> effect_term.normalize
  |> should.equal(types.TApp(
    types.TVar("action"),
    types.TLabels(set.from_list(["Stdout"])),
  ))
}

pub fn infer_operator_param_non_first_callback_via_pipe_test() {
  // `1 |> action(io.println)` desugars to `action(1, io.println)`: the piped
  // receiver takes position 0 and the callback stays at position 1, so the
  // pipe-adjusted positions still align with the operator's argument list and
  // the callback resolves to [Stdout].
  let source =
    "
import gleam/io
pub fn run(action: fn(Int, fn(String) -> Nil) -> Nil) -> Nil {
  1 |> action(io.println)
}
"
  let ann = infer_single(source)
  ann.effects
  |> effect_term.normalize
  |> should.equal(types.TApp(
    types.TVar("action"),
    types.TLabels(set.from_list(["Stdout"])),
  ))
}

pub fn infer_operator_param_threads_all_callbacks_test() {
  // An operator parameter taking two function arguments threads BOTH callbacks
  // as a curried application `((action [Stdout]) [FileSystem])` — neither is
  // dropped (the previous single-callback behaviour lost `fs.read`).
  let kb =
    effects.with_assumes(
      knowledge_base(),
      [fs_read_external()],
      types.UserAssume,
    )
  let source =
    "
import gleam/io
import fs
pub fn run(action: fn(fn(String) -> Nil, fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println, fs.read)
}
"
  let assert Ok(module) = glance.module(source)
  let assert [ann] =
    checker.infer(
      module,
      "",
      kb,
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  ann.effects
  |> effect_term.normalize
  |> should.equal(types.TApp(
    types.TApp(types.TVar("action"), types.TLabels(set.from_list(["Stdout"]))),
    types.TLabels(set.from_list(["FileSystem"])),
  ))
}

pub fn infer_operator_param_non_adjacent_callbacks_test() {
  // Callbacks interleaved with non-function arguments (positions 1 and 3) still
  // thread in order.
  let kb =
    effects.with_assumes(
      knowledge_base(),
      [fs_read_external()],
      types.UserAssume,
    )
  let source =
    "
import gleam/io
import fs
pub fn run(
  action: fn(Int, fn(String) -> Nil, String, fn(String) -> Nil) -> Nil,
) -> Nil {
  action(0, io.println, \"x\", fs.read)
}
"
  let assert Ok(module) = glance.module(source)
  let assert [ann] =
    checker.infer(
      module,
      "",
      kb,
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  ann.effects
  |> effect_term.normalize
  |> should.equal(types.TApp(
    types.TApp(types.TVar("action"), types.TLabels(set.from_list(["Stdout"]))),
    types.TLabels(set.from_list(["FileSystem"])),
  ))
}

pub fn second_order_two_callback_closure_resolves_test() {
  // The previously-false-positive case: a closure that invokes BOTH callbacks
  // resolves to the union of their effects, with no dangling variable. An
  // in-budget check passes; a too-tight budget is flagged.
  let source =
    "
import gleam/io
import fs
pub fn run(action: fn(fn(String) -> Nil, fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println, fs.read)
}
pub fn caller() -> Nil {
  run(fn(log, read) {
    log(\"x\")
    read(\"y\")
  })
}
"
  second_order_violations(source, "caller", ["Stdout", "FileSystem"])
  |> should.equal([])
  { second_order_violations(source, "caller", ["Stdout"]) != [] }
  |> should.be_true()
}

pub fn second_order_second_callback_only_closure_test() {
  // A closure that invokes only its second callback contributes exactly that
  // callback's effect — the first contributes nothing.
  let source =
    "
import gleam/io
import fs
pub fn run(action: fn(fn(String) -> Nil, fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println, fs.read)
}
pub fn caller() -> Nil {
  run(fn(_log, read) { read(\"y\") })
}
"
  second_order_violations(source, "caller", ["FileSystem"]) |> should.equal([])
  { second_order_violations(source, "caller", ["Stdout"]) != [] }
  |> should.be_true()
}

pub fn second_order_same_module_named_fn_resolves_test() {
  // `logger` is a sibling top-level function — NOT in the knowledge base during
  // this module's inference pass. Passing it to the second-order `run` must
  // still resolve to its effect rather than collapsing to `[Unknown]`.
  let source =
    "
import gleam/io
pub fn run(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
fn logger(cb: fn(String) -> Nil) -> Nil {
  cb(\"x\")
}
pub fn caller() -> Nil {
  run(logger)
}
"
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
}

// A let-bound closure that is *applied directly by name* (`let h = fn(x) { x };
// h(1)`) resolves to its body's effect, not `[Unknown]`. The pure first-order
// case infers `[]`.
pub fn let_bound_closure_called_directly_test() {
  let source =
    "pub fn direct_let() -> Int {
  let helper = fn(x: Int) { x + 1 }
  helper(1)
}"
  infer_effect(source) |> should.equal(Specific(set.new()))
}

// The same direct application reached through a mapper closure (`list.map(xs,
// fn(n) { helper(n) })`): `helper` is still a let-bound closure in scope, so its
// pure body resolves to `[]`.
pub fn let_bound_closure_called_in_mapper_test() {
  let source =
    "import gleam/list
pub fn let_in_map() -> List(Int) {
  let helper = fn(x: Int) { x + 1 }
  list.map([1, 2], fn(n) { helper(n) })
}"
  infer_effect(source) |> should.equal(Specific(set.new()))
}

// A direct application of a let-bound closure must not *drop* the body's real
// effects: an effectful first-order closure resolves to its body effect.
pub fn let_bound_closure_direct_call_keeps_effects_test() {
  let source =
    "import gleam/io
pub fn run() -> Nil {
  let log = fn(m: String) { io.println(m) }
  log(\"hi\")
}"
  infer_effect(source)
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// A *higher-order* let-bound closure applied directly (`let h = fn(cb) { cb(..)
// }; h(io.println)`): the closure lifts to an operator and the call's argument
// beta-reduces, giving the callback's effect rather than `[Unknown]`.
pub fn let_bound_higher_order_closure_applied_directly_test() {
  let source =
    "import gleam/io
pub fn run() -> Nil {
  let h = fn(cb) { cb(\"x\") }
  h(io.println)
}"
  infer_effect(source)
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// The direct-application fix lets a `check direct_let : []` invariant pass
// instead of being spuriously blocked by `[Unknown]`.
pub fn let_bound_closure_direct_call_satisfies_pure_check_test() {
  let source =
    "pub fn direct_let() -> Int {
  let helper = fn(x: Int) { x + 1 }
  helper(1)
}"
  let assert Ok(module) = glance.module(source)
  let ann =
    EffectAnnotation(Check, "direct_let", [], effect_term.pure(), returns: None)
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [ann],
      knowledge_base(),
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations |> should.equal([])
}

// A directly-called closure that *captures* another let-bound callable resolves
// the capture: `let suffix = string.append` is in scope at the closure's binding
// site, so `helper`'s body resolves to `string.append`'s effect (`[]`), not the
// `[Unknown]` a re-analysis with an empty environment would yield.
pub fn let_bound_closure_captures_resolved_test() {
  let source =
    "import gleam/string
pub fn run() -> String {
  let suffix = string.append
  let helper = fn(x) { suffix(x, \"!\") }
  helper(\"hi\")
}"
  infer_effect(source) |> should.equal(Specific(set.new()))
}

// A directly-called closure that captures an *effectful* callable still surfaces
// that effect (from the binding-site walk), so a pure `check` would fail — the
// capture is resolved, not silently dropped.
pub fn let_bound_closure_captures_effect_test() {
  let source =
    "import gleam/io
pub fn run() -> Nil {
  let log = io.println
  let helper = fn(x) { log(x) }
  helper(\"hi\")
}"
  infer_effect(source)
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// A let-bound `case`-of-closures applied directly (`let h = case c { ... };
// h(a)`): each branch is lifted and joined, over-approximating both, rather than
// `[Unknown]`. Here one branch logs and the other is pure, so the join is
// `[Stdout]`.
pub fn let_bound_choice_applied_directly_test() {
  let source =
    "import gleam/io
pub fn run(c: Bool) -> Nil {
  let h = case c {
    True -> fn(m: String) { io.println(m) }
    False -> fn(_m: String) { Nil }
  }
  h(\"hi\")
}"
  infer_effect(source)
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn second_order_let_bound_closure_resolves_test() {
  // A let-bound closure used by name resolves through the operator just like an
  // inline closure, rather than going `[Unknown]`.
  let source =
    "
import gleam/io
pub fn run(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
pub fn caller() -> Nil {
  let h = fn(cb) { cb(\"x\") }
  run(h)
}
"
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
}

pub fn second_order_let_bound_closure_shadowing_test() {
  // A later binding shadows an earlier one: the pure first `h` is replaced by
  // the effectful second, so the effect is [Stdout].
  let source =
    "
import gleam/io
pub fn run(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
pub fn caller() -> Nil {
  let h = fn(_cb) { Nil }
  let h = fn(cb) { cb(\"x\") }
  run(h)
}
"
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
}

pub fn second_order_returned_function_stays_unknown_test() {
  // The genuine residual: `h` is a function *returned from a call*, which graded
  // can't trace to a concrete function. It stays the sound `[Unknown]`, so even
  // a wildcard budget is the only thing that passes; a concrete budget is
  // flagged.
  let source =
    "
import gleam/io
pub fn run(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
fn make() {
  run
}
pub fn caller() -> Nil {
  let h = make()
  run(h)
}
"
  { second_order_violations(source, "caller", ["Stdout"]) != [] }
  |> should.be_true()
}

pub fn first_order_returned_function_applied_test() {
  // C2: a producer returns a *first-order* function (no callback parameter); its
  // latent effect (the returned closure's body) resolves when the let-bound
  // result is applied. `let f = make_printer(); f()` ⟹ [Stdout].
  let source =
    "
import gleam/io
fn make_printer() -> fn() -> Nil {
  fn() { io.println(\"x\") }
}
pub fn caller() -> Nil {
  let f = make_printer()
  f()
}
"
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
}

pub fn first_order_returned_named_function_applied_test() {
  // C2 with a *named* returned function rather than an inline closure.
  let source =
    "
import gleam/io
fn printer() -> Nil {
  io.println(\"x\")
}
fn make() -> fn() -> Nil {
  printer
}
pub fn caller() -> Nil {
  let f = make()
  f()
}
"
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
}

pub fn first_order_returned_function_with_value_param_test() {
  // C2: the returned function takes a (value) parameter. Its latent effect still
  // resolves when applied: `let f = make(); f(\"x\")` ⟹ [Stdout].
  let source =
    "
import gleam/io
fn make() -> fn(String) -> Nil {
  io.println
}
pub fn caller() -> Nil {
  let f = make()
  f(\"x\")
}
"
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
}

pub fn first_order_returned_function_unapplied_is_pure_test() {
  // Soundness/precision: binding the result without applying it carries no
  // effect — the returned closure's body only runs when `f` is called. So
  // `let f = make_printer()` alone leaves `caller` pure.
  let source =
    "
import gleam/io
fn make_printer() -> fn() -> Nil {
  fn() { io.println(\"x\") }
}
pub fn caller() -> Nil {
  let _f = make_printer()
  Nil
}
"
  second_order_violations(source, "caller", []) |> should.equal([])
}

pub fn second_order_returned_operator_applied_directly_test() {
  // C1: a let-bound returned operator applied *directly* — `h(io.println)` —
  // resolves the producer's returned operator and applies it, rather than
  // staying [Unknown]. (Previously only `run(h)` — h passed as an operator
  // argument — resolved.)
  let source =
    "
import gleam/io
fn logger(cb: fn(String) -> Nil) -> Nil {
  cb(\"x\")
}
fn pick() -> fn(fn(String) -> Nil) -> Nil {
  logger
}
pub fn caller() -> Nil {
  let h = pick()
  h(io.println)
}
"
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
}

pub fn second_order_returned_decorator_applied_directly_test() {
  // C1 with a *polymorphic* returned operator: `traced` wraps its operator
  // parameter. Applying the let-bound result directly binds `action := reader`
  // and unions the decorator's own effect with the wrapped operator's.
  let source =
    "
import gleam/io
import fs
fn traced(action: fn(fn(String) -> Nil) -> Nil) -> fn(fn(String) -> Nil) -> Nil {
  fn(cb) {
    io.println(\"trace\")
    action(cb)
  }
}
fn reader(cb: fn(String) -> Nil) -> Nil {
  fs.read(\"f\")
  cb(\"x\")
}
pub fn caller() -> Nil {
  let h = traced(reader)
  h(io.println)
}
"
  second_order_violations(source, "caller", ["Stdout", "FileSystem"])
  |> should.equal([])
  { second_order_violations(source, "caller", ["Stdout"]) != [] }
  |> should.be_true()
}

pub fn pipe_into_closure_operator_resolves_test() {
  // D2 (soundness): `x |> fn(f) { f("x") }` applies the closure to the piped
  // value. Previously the closure body's use of `f` was dropped and the effect
  // understated to []. Now it resolves to [Stdout].
  let source =
    "
import gleam/io
pub fn caller() -> Nil {
  io.println |> fn(f) { f(\"x\") }
}
"
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
}

pub fn pipe_into_first_order_closure_test() {
  // A first-order closure pipe target stays correct: the body's own effects are
  // accounted (the piped value is just bound, not applied).
  let source =
    "
import gleam/io
pub fn caller(msg: String) -> Nil {
  msg |> fn(m) { io.println(m) }
}
"
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
}

pub fn pipe_into_case_of_functions_test() {
  // D2 (soundness): `x |> case flag { True -> a  False -> b }` applies the
  // selected operator to the piped value; the effect is the join of branches.
  let source =
    "
import gleam/io
import fs
fn a(cb: fn(String) -> Nil) -> Nil {
  io.println(\"x\")
}
fn b(cb: fn(String) -> Nil) -> Nil {
  fs.read(\"f\")
}
pub fn caller(flag: Bool) -> Nil {
  io.println |> case flag {
    True -> a
    False -> b
  }
}
"
  second_order_violations(source, "caller", ["Stdout", "FileSystem"])
  |> should.equal([])
  { second_order_violations(source, "caller", ["Stdout"]) != [] }
  |> should.be_true()
}

pub fn pipe_into_non_function_case_stays_walked_test() {
  // A `case` pipe target with a non-function branch isn't an operator: fall
  // back to the normal walk (the piped expression's own effects still count).
  let source =
    "
import gleam/io
pub fn caller(flag: Bool) -> Int {
  io.println(\"x\")
  1 |> case flag {
    True -> 2
    False -> 3
  }
}
"
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
}

pub fn use_with_operator_callee_resolves_callback_test() {
  // C3: `use r <- with_thing()` desugars to `with_thing(fn(r) { io.println(r) })`.
  // The operator callee binds its callback to the continuation, so its callback
  // variable resolves instead of leaving a spurious unbound effect — so
  // `check caller : [Stdout]` no longer false-positives.
  let source =
    "
import gleam/io
fn with_thing(cb: fn(String) -> Nil) -> Nil {
  cb(\"x\")
}
pub fn caller() -> Nil {
  use r <- with_thing()
  io.println(r)
}
"
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
}

pub fn use_tail_depends_on_binding_test() {
  // C3: the continuation's effect comes from what the callee passes to the
  // binding. `with_logger` hands `io.println` to `log`; `log(\"hello\")` in the
  // continuation therefore carries [Stdout].
  let source =
    "
import gleam/io
fn with_logger(cb: fn(fn(String) -> Nil) -> Nil) -> Nil {
  cb(io.println)
}
pub fn caller() -> Nil {
  use log <- with_logger()
  log(\"hello\")
}
"
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
}

pub fn use_with_unknown_callee_still_counts_continuation_test() {
  // Soundness: a non-operator (unknown/external) callee must not drop the
  // continuation's effects — they're still walked from the closure body.
  let source =
    "
import gleam/io
import fs
pub fn caller() -> Nil {
  use _ <- fs.with_file()
  io.println(\"x\")
}
"
  // Effect is {Unknown (fs.with_file), Stdout (io.println)} — the empty budget
  // is violated, confirming the continuation effect survived desugaring.
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
}

pub fn second_order_branch_closures_unions_effects_test() {
  // An operator argument selected by `case` over two closures resolves to the
  // *union* of the branches' effects (over-approximating both).
  let source =
    "
import gleam/io
import fs
pub fn run(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
pub fn caller(flag: Bool) -> Nil {
  run(case flag {
    True -> fn(log) { log(\"x\") }
    False -> fn(log) {
      log(\"y\")
      fs.read(\"f\")
    }
  })
}
"
  // First branch ⟹ [Stdout] (log := io.println); second ⟹ [Stdout, FileSystem].
  // The join is their union.
  second_order_violations(source, "caller", ["Stdout", "FileSystem"])
  |> should.equal([])
  { second_order_violations(source, "caller", ["Stdout"]) != [] }
  |> should.be_true()
}

pub fn second_order_branch_same_module_fns_test() {
  // Branch over two same-module named functions (resolved via the function map).
  let source =
    "
import gleam/io
import fs
pub fn run(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
fn quiet(cb: fn(String) -> Nil) -> Nil {
  cb(\"x\")
}
fn loud(cb: fn(String) -> Nil) -> Nil {
  cb(\"x\")
  fs.read(\"f\")
}
pub fn caller(flag: Bool) -> Nil {
  run(case flag {
    True -> quiet
    False -> loud
  })
}
"
  // quiet ⟹ [Stdout]; loud ⟹ [Stdout, FileSystem]; union is both.
  second_order_violations(source, "caller", ["Stdout", "FileSystem"])
  |> should.equal([])
  { second_order_violations(source, "caller", ["Stdout"]) != [] }
  |> should.be_true()
}

pub fn second_order_let_bound_branch_test() {
  // A let-bound branch resolves the same way at its later use site.
  let source =
    "
import gleam/io
pub fn run(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
pub fn caller(flag: Bool) -> Nil {
  let h = case flag {
    True -> fn(log) { log(\"x\") }
    False -> fn(_log) { Nil }
  }
  run(h)
}
"
  // True branch ⟹ [Stdout], False branch ⟹ []; union is [Stdout].
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
}

pub fn second_order_branch_block_arm_resolves_test() {
  // A branch arm that is a *block* ending in a function resolves through its
  // tail expression (block descent), so the whole branch still resolves rather
  // than going opaque.
  let source =
    "
import gleam/io
pub fn run(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
pub fn caller(flag: Bool) -> Nil {
  run(case flag {
    True -> fn(log) { log(\"x\") }
    False -> {
      let _ = 1
      fn(log) { log(\"y\") }
    }
  })
}
"
  // Both arms are [Stdout] (log := io.println); the budget passes, [] fails.
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
}

pub fn second_order_let_bound_block_resolves_test() {
  // A let-bound block evaluating to a function resolves at the use site via its
  // tail expression, with the block's own lets in scope.
  let source =
    "
import gleam/io
pub fn run(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
pub fn caller() -> Nil {
  let h = {
    let chosen = fn(log) { log(\"x\") }
    chosen
  }
  run(h)
}
"
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
}

pub fn second_order_returned_function_same_module_test() {
  // A same-module producer `pick` returns a function; `let h = pick(); run(h)`
  // resolves to the returned function's effect (computed on-demand).
  let source =
    "
import gleam/io
pub fn run(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
fn logger(cb: fn(String) -> Nil) -> Nil {
  cb(\"x\")
}
fn pick() -> fn(fn(String) -> Nil) -> Nil {
  logger
}
pub fn caller() -> Nil {
  let h = pick()
  run(h)
}
"
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
}

pub fn second_order_returned_function_inline_test() {
  // The inline form `run(pick())` resolves the same way as the let-bound form.
  let source =
    "
import gleam/io
pub fn run(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
fn logger(cb: fn(String) -> Nil) -> Nil {
  cb(\"x\")
}
fn pick() -> fn(fn(String) -> Nil) -> Nil {
  logger
}
pub fn caller() -> Nil {
  run(pick())
}
"
  second_order_violations(source, "caller", ["Stdout"]) |> should.equal([])
  { second_order_violations(source, "caller", []) != [] } |> should.be_true()
}

pub fn second_order_returned_branch_of_params_test() {
  // A producer returns one of its *operator* parameters through a branch:
  // `pick(a, b, flag) -> case flag { True -> a  False -> b }`. The returned
  // operator is the join `a ⊔ b`; binding `a := stdout_op`, `b := fs_op` and
  // applying it (in `run(h)`) distributes over the union, so `caller` carries
  // both branches' effects: [Stdout, FileSystem].
  let source =
    "
import gleam/io
import simplifile
pub fn run(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
fn stdout_op(cb: fn(String) -> Nil) -> Nil {
  io.println(\"x\")
}
fn fs_op(cb: fn(String) -> Nil) -> Nil {
  let _ = simplifile.read(\"f\")
  Nil
}
fn pick(
  a: fn(fn(String) -> Nil) -> Nil,
  b: fn(fn(String) -> Nil) -> Nil,
  flag: Bool,
) -> fn(fn(String) -> Nil) -> Nil {
  case flag {
    True -> a
    False -> b
  }
}
pub fn caller() -> Nil {
  let h = pick(stdout_op, fs_op, True)
  run(h)
}
"
  second_order_violations(source, "caller", ["Stdout", "FileSystem"])
  |> should.equal([])
  { second_order_violations(source, "caller", ["Stdout"]) != [] }
  |> should.be_true()
}

pub fn second_order_returned_function_cross_module_test() {
  // A cross-module producer whose returned operator is in the knowledge base
  // (as the topological pass would have folded it).
  let source =
    "
import gleam/io
import dep
pub fn run(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
pub fn caller() -> Nil {
  let h = dep.pick()
  run(h)
}
"
  let assert Ok(module) = glance.module(source)
  // The topological pass folds both the producer's own effect (it's pure — it
  // just returns a function) and its returned operator into the KB.
  let kb =
    knowledge_base()
    |> effects.with_inferred(
      dict.from_list([
        #(
          QualifiedName("dep", "pick"),
          effect_term.from_effect_set(types.empty()),
        ),
      ]),
      types.ProjectInferred,
    )
    |> effects.with_fresh_returned_operators(
      dict.from_list([
        #(QualifiedName("dep", "pick"), types.TAbs("cb", types.TVar("cb"))),
      ]),
      types.ProjectInferred,
    )
  let registry = signatures.from_glance_module("app", module)
  let pass =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
      returns: None,
    )
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [pass],
      kb,
      registry,
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations |> should.equal([])
  let fail =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(types.empty()),
      returns: None,
    )
  let #(fail_violations, _findings, _) =
    checker.check(
      module,
      "",
      [fail],
      kb,
      registry,
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  { fail_violations != [] } |> should.be_true()
}

pub fn second_order_returned_function_from_spec_test() {
  // A `returns` line in the spec (as `infer` writes it) lets `check` resolve a
  // cross-module producer — exercising the parse + load path, not a hand-built
  // KB.
  let assert Ok(spec) =
    annotation.parse_file(
      "effects dep.pick : [] where returns : fn(cb) -> [cb]",
    )
  let source =
    "
import gleam/io
import dep
pub fn run(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
pub fn caller() -> Nil {
  let h = dep.pick()
  run(h)
}
"
  let assert Ok(module) = glance.module(source)
  let kb =
    knowledge_base()
    |> effects.with_inferred(
      dict.from_list([
        #(
          QualifiedName("dep", "pick"),
          effect_term.from_effect_set(types.empty()),
        ),
      ]),
      types.ProjectInferred,
    )
    |> effects.with_closed_returned_operators(
      effects.load_spec_returns_from_file(spec),
      types.CommittedSpec,
    )
  let registry = signatures.from_glance_module("app", module)
  let pass =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
      returns: None,
    )
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [pass],
      kb,
      registry,
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations |> should.equal([])
}

pub fn infer_returned_operator_entry_test() {
  // Inferring a producer that returns a function records its returned operator.
  let source =
    "
pub fn logger(cb: fn(String) -> Nil) -> Nil {
  cb(\"x\")
}
pub fn pick() -> fn(fn(String) -> Nil) -> Nil {
  logger
}
"
  let assert Ok(module) = glance.module(source)
  let #(_annotations, returns, _provenance) =
    checker.infer_with_returns(
      module,
      "",
      knowledge_base(),
      [],
      signatures.from_glance_module("app", module),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  dict.get(returns, "pick")
  |> should.equal(Ok(types.TAbs("cb", types.TVar("cb"))))
}

pub fn infer_first_order_returned_function_entry_test() {
  // C2: inferring a producer that returns a *first-order* function records its
  // latent effect (a ground set), and that round-trips through the spec syntax.
  let source =
    "
import gleam/io
pub fn make_printer() -> fn() -> Nil {
  fn() { io.println(\"x\") }
}
"
  let assert Ok(module) = glance.module(source)
  let #(_annotations, returns, _provenance) =
    checker.infer_with_returns(
      module,
      "",
      knowledge_base(),
      [],
      signatures.from_glance_module("app", module),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert Ok(operator) = dict.get(returns, "make_printer")
  operator
  |> should.equal(
    effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
  )
  // Round-trips through the clause renderer and back (a plain effect term).
  let line =
    annotation.format_annotation(EffectAnnotation(
      Effects,
      "make_printer",
      [],
      effect_term.from_effect_set(types.empty()),
      returns: Some(operator),
    ))
  let assert Ok([reparsed]) = annotation.parse(line)
  let assert Some(reparsed_operator) = reparsed.returns
  effect_term.normalize(reparsed_operator)
  |> should.equal(effect_term.normalize(operator))
}

pub fn first_order_returned_function_from_spec_test() {
  // C2 cross-module: a `returns dep.make : [Stdout]` spec line (as `infer`
  // writes it) lets `let f = dep.make(); f()` resolve in a downstream module.
  let assert Ok(spec) =
    annotation.parse_file("effects dep.make : [] where returns : [Stdout]")
  let source =
    "
import dep
pub fn caller() -> Nil {
  let f = dep.make()
  f()
}
"
  let assert Ok(module) = glance.module(source)
  let kb =
    knowledge_base()
    |> effects.with_inferred(
      dict.from_list([
        #(
          QualifiedName("dep", "make"),
          effect_term.from_effect_set(types.empty()),
        ),
      ]),
      types.ProjectInferred,
    )
    |> effects.with_closed_returned_operators(
      effects.load_spec_returns_from_file(spec),
      types.CommittedSpec,
    )
  let registry = signatures.from_glance_module("app", module)
  let pass =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
      returns: None,
    )
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [pass],
      kb,
      registry,
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations |> should.equal([])
  let fail =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(types.empty()),
      returns: None,
    )
  let #(failed, _findings, _) =
    checker.check(
      module,
      "",
      [fail],
      kb,
      registry,
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  { failed != [] } |> should.be_true()
}

pub fn infer_returned_branch_of_params_entry_test() {
  // A producer that returns one of its operator parameters through a branch
  // records the *union* as its returned operator, and that union round-trips
  // through the spec-file syntax (a polymorphic effect set `[a, b]`).
  let source =
    "
pub fn pick(
  a: fn(fn(String) -> Nil) -> Nil,
  b: fn(fn(String) -> Nil) -> Nil,
  flag: Bool,
) -> fn(fn(String) -> Nil) -> Nil {
  case flag {
    True -> a
    False -> b
  }
}
"
  let assert Ok(module) = glance.module(source)
  let #(_annotations, returns, _provenance) =
    checker.infer_with_returns(
      module,
      "",
      knowledge_base(),
      [],
      signatures.from_glance_module("app", module),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert Ok(operator) = dict.get(returns, "pick")
  operator
  |> should.equal(types.TUnion([types.TVar("a"), types.TVar("b")]))
  // Round-trips through the clause renderer and back.
  let line =
    annotation.format_annotation(EffectAnnotation(
      Effects,
      "pick",
      [],
      effect_term.from_effect_set(types.empty()),
      returns: Some(operator),
    ))
  let assert Ok([reparsed]) = annotation.parse(line)
  let assert Some(reparsed_operator) = reparsed.returns
  effect_term.normalize(reparsed_operator)
  |> should.equal(effect_term.normalize(operator))
}

pub fn second_order_returns_parameter_resolves_test() {
  // Return-polymorphism: `wrap` returns its own operator parameter, bound at the
  // producer call to `reader` ([FileSystem]); the result resolves rather than
  // collapsing to `[Unknown]`.
  let source =
    "
import gleam/io
import fs
pub fn run(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
fn wrap(
  base: fn(fn(String) -> Nil) -> Nil,
) -> fn(fn(String) -> Nil) -> Nil {
  base
}
fn reader(cb: fn(String) -> Nil) -> Nil {
  cb(\"x\")
  fs.read(\"f\")
}
pub fn caller() -> Nil {
  let h = wrap(reader)
  run(h)
}
"
  // wrap(reader) ⟹ reader's operator; run applies it to io.println ⟹
  // [Stdout] (the callback) ∪ [FileSystem] (reader's own effect).
  second_order_violations(source, "caller", ["Stdout", "FileSystem"])
  |> should.equal([])
  { second_order_violations(source, "caller", ["Stdout"]) != [] }
  |> should.be_true()
}

pub fn second_order_decorator_return_resolves_test() {
  // A decorator returns a closure that *wraps* its operator parameter. The
  // returned operator `λcb. ([Stdout] ∪ inner(cb))` binds `inner` to `reader` at
  // `traced(reader)`; the producer call no longer over-approximates the returned
  // closure's body, so the result is the clean union — no spurious `[Unknown]`.
  let source =
    "
import gleam/io
import fs
pub fn run(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
fn reader(cb: fn(String) -> Nil) -> Nil {
  cb(\"x\")
  fs.read(\"f\")
}
fn traced(
  inner: fn(fn(String) -> Nil) -> Nil,
) -> fn(fn(String) -> Nil) -> Nil {
  fn(cb) {
    io.println(\"trace\")
    inner(cb)
  }
}
pub fn caller() -> Nil {
  let h = traced(reader)
  run(h)
}
"
  second_order_violations(source, "caller", ["Stdout", "FileSystem"])
  |> should.equal([])
  { second_order_violations(source, "caller", ["FileSystem"]) != [] }
  |> should.be_true()
}

// A `fs.read : [FileSystem]` assume for second-order operator tests.
fn fs_read_external() -> types.AssumeAnnotation {
  simple_assume("fs", "read", ["FileSystem"])
}

// A boundless per-function `assume` declaring a flat effect set.
fn simple_assume(
  module: String,
  function: String,
  labels: List(String),
) -> types.AssumeAnnotation {
  types.AssumeAnnotation(
    module,
    types.FunctionAssume(function),
    params: [],
    effects: Some(Specific(set.from_list(labels))),
    returns: None,
  )
}

// Check `function` in a single-module source against a `[budget]` and return
// the violations. The registry is built from the module so same-module operator
// parameters resolve; the `fs.read` external is always available.
fn second_order_violations(
  source: String,
  function: String,
  budget: List(String),
) -> List(types.Violation) {
  let assert Ok(module) = glance.module(source)
  let kb =
    effects.with_assumes(
      knowledge_base(),
      [fs_read_external()],
      types.UserAssume,
    )
  let registry = signatures.from_glance_module("app", module)
  let ann =
    EffectAnnotation(
      Check,
      function,
      [],
      effect_term.from_effect_set(Specific(set.from_list(budget))),
      returns: None,
    )
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [ann],
      kb,
      registry,
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations
}

// Collapse classification
//
// Functions are classified as collapsible from syntax alone, independent of
// girard, so memoization stays deterministic.

// A parameter typed through a module-local function alias (`h: Handler` where
// `type Handler = fn(...)`) must be recognised as function-typed from the
// syntax alone, so the function is never *collapsed* during memoization. The
// type annotator can decline a function under load; relying on it here would
// let an effect-polymorphic function be collapsed (turning its `h(x)` call into
// `[Unknown]`) only sometimes — a nondeterministic result. Passing an empty
// girard map simulates the annotator being unavailable.
pub fn alias_fn_param_is_excluded_from_collapse_test() {
  let source =
    "pub type Handler =
  fn(String) -> Nil

pub fn apply(h: Handler, x: String) -> Nil {
  h(x)
}

pub fn plain(x: String) -> String {
  x
}
"
  let assert Ok(module) = glance.module(source)
  let context = extract.build_import_context(module)
  let cache = checker.build_scc_ids(module, context, dict.new())

  // `apply` takes an alias-typed function parameter — excluded from collapse
  // even with no girard input.
  let assert Ok(apply_scc) = dict.get(cache.scc_id, "apply")
  set.contains(cache.collapsible, apply_scc) |> should.be_false()

  // `plain` is genuinely first-order — still collapsible.
  let assert Ok(plain_scc) = dict.get(cache.scc_id, "plain")
  set.contains(cache.collapsible, plain_scc) |> should.be_true()
}

// Inference soundness regressions
//
// Shared single-module infer helpers for the issue-1/2/3 regression sections
// below.

fn infer_annotation(source: String, name: String) -> EffectAnnotation {
  let assert Ok(module) = glance.module(source)
  infer_annotation_with(
    module,
    name,
    knowledge_base(),
    signatures.from_glance_module("m", module),
  )
}

// The same over an already-parsed module, against a caller-chosen base and
// registry — for the callers whose scenario is which knowledge the analysis has,
// not what the source says.
fn infer_annotation_with(
  module: glance.Module,
  name: String,
  knowledge_base: effects.KnowledgeBase,
  registry: signatures.SignatureRegistry,
) -> EffectAnnotation {
  let inferred =
    checker.infer(
      module,
      "",
      knowledge_base,
      [],
      registry,
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert Ok(annotation) = list.find(inferred, fn(a) { a.function == name })
  annotation
}

fn infer_effect_set(source: String, name: String) -> types.EffectSet {
  effect_term.to_effect_set(infer_annotation(source, name).effects)
}

// Expression-valued callees
//
// An expression in callee position (IIFE, returned function, case of
// functions) contributes its resolved effect, never a silent [].

// An immediately invoked closure must propagate its callback's effect.
pub fn issue1_iife_propagates_callback_test() {
  let source =
    "import gleam/io
pub fn run() -> Nil { fn(callback) { callback(\"hi\") }(io.println) }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// An immediately invoked closure applies *every* argument, not just the first:
// the callback at position 1 must still be applied.
pub fn issue1_iife_applies_non_first_argument_test() {
  let source =
    "import gleam/io
pub fn run() -> Nil { fn(_value, callback) { callback(\"x\") }(1, io.println) }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// Two invoked callback parameters are both applied.
pub fn issue1_iife_applies_two_callbacks_test() {
  let source =
    "import gleam/io
pub fn run() -> Nil {
  fn(a, b) {
    a(\"x\")
    b(\"y\")
  }(io.println, io.print)
}"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// A directly called let-bound closure resolves through the binding rather than
// collapsing to [Unknown].
pub fn issue1_direct_let_bound_closure_test() {
  let source =
    "import gleam/io
pub fn run() -> Nil {
  let helper = fn(cb) { cb(\"x\") }
  helper(io.println)
}"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// An immediately applied returned function must propagate its latent effect.
pub fn issue1_returned_fn_propagates_test() {
  let source =
    "import gleam/io
fn printer() -> fn(String) -> Nil { io.println }
pub fn run() -> Nil { printer()(\"hi\") }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// A producer whose returned closure captures a *first-order* callback parameter
// (`fn make(cb) { fn() { cb(x) } }`) must propagate the callback's effect: the
// closure analysis seeds every fn-typed producer parameter, not only
// second-order operators, so `cb` resolves to the supplied function.
pub fn issue1_returned_closure_captures_callback_test() {
  let source =
    "import gleam/io
fn make(cb: fn(String) -> Nil) -> fn() -> Nil {
  fn() { cb(\"later\") }
}
pub fn run() -> Nil { make(io.println)() }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// The same applies to a closure passed to an operator that captures the
// enclosing function's first-order callback parameter.
pub fn issue1_closure_captures_enclosing_callback_test() {
  let source =
    "import gleam/io
fn with(action: fn(fn() -> Nil) -> Nil) -> Nil { action(fn() { Nil }) }
fn outer(cb: fn(String) -> Nil) -> Nil {
  with(fn(_run) { cb(\"x\") })
}
pub fn run() -> Nil { outer(io.println) }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// A returned zero-argument closure that applies a captured second-order operator
// parameter (`fn make(op) { fn() { op(io.println) } }`) yields an application
// still polymorphic in `op`. It must be kept (not rejected as a stuck term) so
// it β-reduces once `op` is bound to the producer's argument.
pub fn issue1_returned_polymorphic_application_test() {
  let source =
    "import gleam/io
fn identity(f: fn(String) -> Nil) -> Nil { f(\"x\") }
fn make(op: fn(fn(String) -> Nil) -> Nil) -> fn() -> Nil {
  fn() { op(io.println) }
}
pub fn run() -> Nil { make(identity)() }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// A returned closure whose own parameter reuses an enclosing operator
// parameter's name must not inherit the enclosing operator's callback positions:
// the inner first-order `cb()` is the closure's own parameter, not the
// second-order enclosing `cb`.
pub fn issue1_returned_closure_shadows_ambient_operator_test() {
  let source =
    "import gleam/io
fn make(cb: fn(fn() -> Nil) -> Nil) -> fn(fn() -> Nil) -> Nil {
  fn(cb) { cb() }
}
pub fn run() -> Nil { make(fn(g) { g() })(io.println) }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// A *closure* (not a bare function reference) passed as an operator's callback
// must be lifted, not collapsed to [Unknown]: the producer's returned closure
// applies the captured operator to an inline callback whose body prints.
pub fn issue1_closure_callback_to_captured_operator_test() {
  let source =
    "import gleam/io
fn identity(f: fn() -> Nil) -> Nil { f() }
fn make(op: fn(fn() -> Nil) -> Nil) -> fn() -> Nil {
  fn() { op(fn() { io.println(\"x\") }) }
}
pub fn run() -> Nil { make(identity)() }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// The same lifting applies at a direct operator call whose callback is a
// closure that itself invokes its (second-order) parameter.
pub fn issue1_closure_callback_at_direct_operator_call_test() {
  let source =
    "import gleam/io
fn apply(g: fn(fn() -> Nil) -> Nil) -> Nil { g(fn() { io.println(\"y\") }) }
pub fn run() -> Nil { apply(fn(h) { h() }) }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// A callback closure with an ordinary *value* parameter (`fn(message) {
// io.println(message) }`) must lift to its ground effect. The closure analyser
// abstracts the first parameter when positions are unknown, so the value
// parameter has to be discharged or the effect collapses to [Unknown].
pub fn issue1_value_param_callback_returned_test() {
  let source =
    "import gleam/io
fn identity(f: fn(String) -> Nil) -> Nil { f(\"x\") }
fn make(op: fn(fn(String) -> Nil) -> Nil) -> fn() -> Nil {
  fn() { op(fn(message) { io.println(message) }) }
}
pub fn run() -> Nil { make(identity)() }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// The same value-parameter callback, applied through a fn-typed operator
// parameter rather than a returned closure.
pub fn issue1_value_param_callback_direct_test() {
  let source =
    "import gleam/io
fn caller(op: fn(fn(String) -> Nil) -> Nil) -> Nil {
  op(fn(message) { io.println(message) })
}
fn identity(f: fn(String) -> Nil) -> Nil { f(\"x\") }
pub fn run() -> Nil { caller(identity) }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// A callback that *ignores* a higher-order parameter (`fn(_next) { ... }`) must
// stay an operator (its binder is kept), so applying it to a concrete operator
// β-reduces to the precise effect rather than over-approximating to [Unknown].
// The binder is kept because the callback's expected shape — the operator
// parameter's type says position 0 is itself a function — is threaded to the lift,
// distinguishing it from a value parameter.
pub fn issue1_ignored_higher_order_callback_test() {
  let source =
    "import gleam/io
fn apply_next(k: fn(fn() -> Nil) -> Nil) -> Nil { k(io.println) }
fn make(op: fn(fn(fn() -> Nil) -> Nil) -> Nil) -> fn() -> Nil {
  fn() { op(fn(_next) { io.println(\"x\") }) }
}
pub fn run() -> Nil { make(apply_next)() }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// A *higher-order* argument to an immediately-applied returned operator can't be
// lifted precisely — the returned operator's parameter type isn't tracked — so it
// falls back to the conservative [Unknown], not a leaked internal variable name.
// (See docs/LIMITATIONS.md.)
pub fn issue1_higher_order_arg_to_returned_operator_is_unknown_test() {
  let source =
    "import gleam/io
fn make() -> fn(fn(fn() -> Nil) -> Nil) -> Nil {
  fn(action) { action(io.println) }
}
pub fn run() -> Nil { make()(fn(cb) { cb() }) }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

// An immediately applied `case` of operators joins every branch's effect: the
// effectful branch (applies the callback) and the pure branch (ignores it) are
// over-approximated together.
pub fn issue1_case_of_functions_joins_test() {
  let source =
    "import gleam/io
pub fn run(b: Bool) -> Nil {
  case b {
    True -> fn(cb) { cb(\"x\") }
    False -> fn(_cb) { Nil }
  }(io.println)
}"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// An opaque computed callable collapses to [Unknown], never silently pure.
pub fn issue1_opaque_callable_is_unknown_test() {
  let source =
    "pub fn run(funcs: #(fn(String) -> Nil)) -> Nil { funcs.0(\"hi\") }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

// A pure expression-valued callable stays pure.
pub fn issue1_pure_callable_stays_pure_test() {
  let source = "pub fn run() -> String { fn(x) { x }(\"hi\") }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.new()))
}

// An immediate application `make(io.println)()` nests two calls that share a
// span start. Keying call args by the full span keeps the outer (empty) call
// from clobbering the producer's arguments, so the producer's own
// effect-polymorphic parameter still resolves to the supplied effect rather
// than leaking as an unbound variable.
pub fn issue1_immediate_returned_call_preserves_producer_args_test() {
  let source =
    "import gleam/io
fn make(cb: fn(String) -> Nil) -> fn() -> Nil {
  cb(\"setup\")
  fn() { Nil }
}
pub fn run() -> Nil { make(io.println)() }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// Lexical parameters shadowing unqualified imports
//
// A parameter or let binding that shadows an unqualified import resolves to
// the lexical binding, not the import.

// A fn-typed parameter shadowing a *pure* unqualified import must contribute
// its own effect variable, not the (pure) import's effect.
pub fn issue2_fn_param_shadows_pure_import_test() {
  let source =
    "import gleam/string.{uppercase}
pub fn run(uppercase: fn(String) -> String) -> String { uppercase(\"hi\") }"
  let annotation = infer_annotation(source, "run")
  effect_term.to_effect_set(annotation.effects)
  |> should.equal(Polymorphic(set.new(), set.from_list(["uppercase"])))
  annotation.params
  |> should.equal([ParamBound("uppercase", types.TVar("uppercase"))])
}

// A fn-typed parameter shadowing an *effectful* unqualified import must
// contribute its own effect variable, not the import's concrete effect.
pub fn issue2_fn_param_shadows_effectful_import_test() {
  let source =
    "import gleam/io.{println}
pub fn run(println: fn(String) -> Nil) -> Nil { println(\"hi\") }"
  infer_effect_set(source, "run")
  |> should.equal(Polymorphic(set.new(), set.from_list(["println"])))
}

// Forwarding the shadowing fn-typed parameter to a higher-order callee
// substitutes the caller-provided effect, not the import's.
pub fn issue2_forward_fn_param_shadow_test() {
  let source =
    "import gleam/string.{uppercase}
fn apply(g: fn(String) -> String) -> String { g(\"x\") }
pub fn run(uppercase: fn(String) -> String) -> String { apply(uppercase) }"
  infer_effect_set(source, "run")
  |> should.equal(Polymorphic(set.new(), set.from_list(["uppercase"])))
}

// A let binding shadowing an unqualified import wins when the bound value is
// forwarded (the classify path must consult lexical scope before imports).
pub fn issue2_let_shadows_import_forward_test() {
  let source =
    "import gleam/string.{uppercase}
import gleam/io
fn apply(g: fn(String) -> Nil) -> Nil { g(\"x\") }
pub fn run() -> Nil {
  let uppercase = io.println
  apply(uppercase)
}"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// A first-order (non-function) parameter shadowing an import must not resolve
// to the import's function reference when forwarded.
pub fn issue2_first_order_param_shadow_not_import_test() {
  let source =
    "import gleam/string.{uppercase}
fn apply(g: fn(String) -> String) -> String { g(\"x\") }
pub fn run(uppercase: String) -> String { apply(uppercase) }"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

// Operator closures keep their captured callable bindings
//
// A closure passed to a second-order parameter resolves captured callables
// from its binding site instead of re-walking with an empty environment.

// The canonical reproduction: a closure passed to a second-order parameter
// captures a pure qualified alias (`let suffix = string.append`). Re-analysing
// the closure body must resolve `suffix` to its effect (`[]`) from the binding
// site, so the only effect is the supplied `io.println` callback — `[Stdout]`,
// not the `[Stdout, Unknown]` an empty-environment re-walk produced.
pub fn issue3_operator_closure_captures_pure_alias_test() {
  let source =
    "import gleam/io
import gleam/string
fn with(action: fn(fn(String) -> Nil) -> Nil) -> Nil { action(io.println) }
pub fn run() -> Nil {
  let suffix = string.append
  with(fn(callback) {
    let _ = suffix(\"a\", \"b\")
    callback(\"hi\")
  })
}"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// A captured *effectful* qualified alias surfaces its effect. The operator
// supplies a pure callback, so the only effect is the captured `io.println`
// alias — proving the capture is resolved, not dropped.
pub fn issue3_operator_closure_captures_effectful_alias_test() {
  let source =
    "import gleam/io
fn with(action: fn(fn(String) -> Nil) -> Nil) -> Nil { action(fn(_x) { Nil }) }
pub fn run() -> Nil {
  let logit = io.println
  with(fn(callback) {
    logit(\"captured\")
    callback(\"hi\")
  })
}"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// A captured *let-bound closure* resolves through its own body. The operator
// supplies a pure callback, isolating the captured closure's effect.
pub fn issue3_operator_closure_captures_closure_test() {
  let source =
    "import gleam/io
fn with(action: fn(fn(String) -> Nil) -> Nil) -> Nil { action(fn(_x) { Nil }) }
pub fn run() -> Nil {
  let helper = fn(m) { io.println(m) }
  with(fn(callback) {
    helper(\"x\")
    callback(\"hi\")
  })
}"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// A captured *returned operator* (`let h = pick()`) is resolved to the
// producer's returned function when called inside the operator closure.
pub fn issue3_operator_closure_captures_returned_operator_test() {
  let source =
    "import gleam/io
fn pick() -> fn(String) -> Nil { io.println }
fn with(action: fn(fn(String) -> Nil) -> Nil) -> Nil { action(fn(_x) { Nil }) }
pub fn run() -> Nil {
  let h = pick()
  with(fn(callback) {
    h(\"x\")
    callback(\"hi\")
  })
}"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// Shadowing uses the binding visible at the closure's creation site. `f` is
// rebound from the effectful `io.println` to the pure `string.append`; the
// closure must capture the latter, so the effect is `[]` (the operator's
// callback is pure too) — not `[Stdout]`.
pub fn issue3_operator_closure_capture_respects_shadowing_test() {
  let source =
    "import gleam/io
import gleam/string
fn with(action: fn(fn(String) -> Nil) -> Nil) -> Nil { action(fn(_x) { Nil }) }
pub fn run() -> Nil {
  let f = io.println
  let f = string.append
  with(fn(callback) {
    let _ = f(\"a\", \"b\")
    callback(\"hi\")
  })
}"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.new()))
}

// A captured `case`-of-closures is lifted and joined when called, contributing
// the over-approximation of its branches without adding `[Unknown]`. One branch
// prints, the other is pure, so the capture contributes `[Stdout]`.
pub fn issue3_operator_closure_captures_choice_test() {
  let source =
    "import gleam/io
fn with(action: fn(fn(String) -> Nil) -> Nil) -> Nil { action(fn(_x) { Nil }) }
pub fn run(b: Bool) -> Nil {
  let choose = case b {
    True -> fn(m) { io.println(m) }
    False -> fn(_m) { Nil }
  }
  with(fn(callback) {
    choose(\"x\")
    callback(\"hi\")
  })
}"
  infer_effect_set(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

// Violation reporting
//
// Classifying a call site from its (possibly sentinel) name, and the prose the
// CLI prints for a violation.

// A violation of `run`'s `[]` budget, for asserting on the rendered message.
// The resolver recorded nothing about it, so the message states what the call
// kind alone establishes.
fn violation(call: types.QualifiedName, actual: EffectSet) -> types.Violation {
  explained_violation(call, actual, option.None, option.None)
}

// The same violation with what the resolver recorded about the call.
fn explained_violation(
  call: types.QualifiedName,
  actual: EffectSet,
  reason: option.Option(types.UnknownReason),
  origin: option.Option(types.LookupOrigin),
) -> types.Violation {
  types.Violation(
    function: "run",
    declared: Specific(set.new()),
    explanation: types.CallExplanation(
      call:,
      span: glance.Span(0, 0),
      actual:,
      reason:,
      origin:,
      fallback: types.NoFallback,
    ),
  )
}

fn pure_check(function: String) -> EffectAnnotation {
  EffectAnnotation(
    Check,
    function,
    [],
    effect_term.from_effect_set(Specific(set.new())),
    returns: None,
  )
}

fn formatted_violations(
  source: String,
  annotations: List(EffectAnnotation),
) -> List(String) {
  check_source(source, annotations)
  |> list.map(checker.format_violation("src/app.gleam", _))
}

pub fn call_kind_qualified_call_is_direct_test() {
  checker.call_kind(QualifiedName("gleam/io", "println"))
  |> should.equal(checker.DirectCall("gleam/io", "println"))
}

pub fn call_kind_param_sentinel_test() {
  checker.call_kind(QualifiedName("<param>", "f"))
  |> should.equal(checker.ParameterCall("f"))
}

pub fn call_kind_field_sentinel_test() {
  checker.call_kind(QualifiedName("<field>", "config.resolver"))
  |> should.equal(checker.FieldAccessCall("config", "resolver"))
}

pub fn call_kind_field_sentinel_keeps_nested_receiver_test() {
  checker.call_kind(QualifiedName("<field>", "config.inner.run"))
  |> should.equal(checker.FieldAccessCall("config.inner", "run"))
}

pub fn call_kind_field_sentinel_without_dot_is_unclassified_test() {
  checker.call_kind(QualifiedName("<field>", "run"))
  |> should.equal(checker.UnclassifiedCall)
}

pub fn call_kind_field_sentinel_without_receiver_is_unclassified_test() {
  checker.call_kind(QualifiedName("<field>", ".run"))
  |> should.equal(checker.UnclassifiedCall)
}

pub fn call_kind_field_sentinel_without_label_is_unclassified_test() {
  checker.call_kind(QualifiedName("<field>", "config."))
  |> should.equal(checker.UnclassifiedCall)
}

// A receiver with no source path carries the computed-receiver sentinel, which
// names nothing the user wrote — so it decodes to the computed-receiver kind
// rather than a receiver called `<expr>`.
pub fn call_kind_field_sentinel_computed_receiver_test() {
  checker.call_kind(QualifiedName(
    "<field>",
    extract.computed_receiver <> ".handler",
  ))
  |> should.equal(checker.ComputedFieldCall("handler"))
}

pub fn call_kind_returned_sentinel_test() {
  checker.call_kind(QualifiedName("<returned>", "pick"))
  |> should.equal(checker.ReturnedOperatorCall(QualifiedName("", "pick")))
}

// A producer in another module keeps that module, so a local `pick` and a
// dependency's `pick` don't decode alike.
pub fn call_kind_returned_sentinel_keeps_producer_module_test() {
  checker.call_kind(QualifiedName("<returned>", "somedep/api.make"))
  |> should.equal(
    checker.ReturnedOperatorCall(QualifiedName("somedep/api", "make")),
  )
}

pub fn call_kind_pipe_sentinel_test() {
  checker.call_kind(QualifiedName("<pipe>", "<operator>"))
  |> should.equal(checker.InlineFunctionCall)
}

pub fn call_kind_apply_sentinel_test() {
  checker.call_kind(QualifiedName("<apply>", "<unknown>"))
  |> should.equal(checker.ComputedValueCall)
}

pub fn call_kind_closure_sentinel_test() {
  checker.call_kind(QualifiedName("<closure>", "<applied>"))
  |> should.equal(checker.LetBoundValueCall)
}

pub fn call_kind_local_sentinel_test() {
  checker.call_kind(QualifiedName("<local>", "helper"))
  |> should.equal(checker.UnresolvedLocalCall("helper"))
}

pub fn call_kind_declared_sentinel_test() {
  // Its own sentinel, because its own wording: a module-level line over ordinary
  // Gleam declares what callers pay, and the function under it is not an
  // external.
  checker.call_kind(QualifiedName("<declared>", "myapp/db.connect"))
  |> should.equal(checker.CallerDeclaration("myapp/db.connect"))
}

pub fn call_kind_unrecognised_sentinel_is_unclassified_test() {
  checker.call_kind(QualifiedName("<bogus>", "whatever"))
  |> should.equal(checker.UnclassifiedCall)
}

// A warning's wording is the only place a reader learns what a dropped line does
// and what happens next, so the sentence is pinned like a violation's.
pub fn format_warning_stale_returns_clauses_test() {
  types.StaleReturnsClauseWarning(function: "lib.make")
  |> checker.format_warning("proj.graded", _)
  |> should.equal(
    "proj.graded: warning: assume lib.make where returns names a function of this package with a Gleam body — every caller resolves what it returns from that body, so the clause declares nothing and is ignored. `graded infer` removes it and writes the inferred clause on the `effects` line in its place",
  )
}

pub fn format_warning_unkeyed_effects_shape_test() {
  // The sentence carries the whole rule: what keys the tier, that this line
  // does not, and that the next `infer` removes it — a reader who sees it after
  // the removal has no line left to read.
  types.UnkeyedEffectsShapeWarning(name: "app.Handler.on_click")
  |> checker.format_warning("proj.graded", _)
  |> should.equal(
    "proj.graded: warning: effects app.Handler.on_click is not a function path — only `module.function` keys an effects line, so this one resolves nothing and the next `graded infer` drops it; `assume` is the line that takes a field or module path",
  )
}

// Construction-site comparison
//
// D9: both sides canonicalized to the field's own arity before comparing, the
// wired value's three shapes reaching the same budget, and the binders the
// declaration leaves unconstrained grounded before the comparison runs.

fn field_signature(
  arity: Int,
  callbacks: List(#(Int, List(Int))),
) -> types.CallableFieldSignature {
  types.CallableFieldSignature(arity:, callbacks:)
}

fn weigh(
  actual: types.EffectTerm,
  bounds: List(types.ParamBound),
  declared: types.EffectTerm,
  signature: types.CallableFieldSignature,
) -> checker.FieldComparison {
  checker.field_site_comparison(actual, bounds, declared, signature)
}

fn label_term(items: List(String)) -> types.EffectTerm {
  TLabels(set.from_list(items))
}

pub fn an_inline_closure_meets_a_ground_budget_test() {
  weigh(
    TAbs("msg", label_term(["Stdout"])),
    [],
    label_term(["Stdout"]),
    field_signature(1, []),
  )
  |> should.equal(checker.FieldWithinBudget)
}

pub fn a_named_concrete_function_meets_a_ground_budget_test() {
  // The actual is *ground* — no binders at all. Lifting only the declared side
  // would compare arity 0 against arity 1 and report correct code.
  weigh(
    label_term(["Stdout"]),
    [],
    label_term(["Stdout"]),
    field_signature(1, []),
  )
  |> should.equal(checker.FieldWithinBudget)
}

pub fn a_named_polymorphic_function_meets_a_ground_budget_test() {
  // Lifted symbolically: the bound's *payload* variable is the substitution
  // key, and the binder it becomes is then unconstrained, so it grounds.
  weigh(
    TVar("e"),
    [ParamBound(name: "cb", effects: TVar("e"))],
    effect_term.unknown(),
    field_signature(1, []),
  )
  |> should.equal(checker.FieldWithinBudget)
}

pub fn a_higher_order_field_meets_unknown_but_not_pure_test() {
  // `λnext. [next]` against `[Unknown]` passes only because the synthesized
  // binder is grounded first; against `[]` it violates.
  weigh(
    TAbs("next", TVar("next")),
    [],
    effect_term.unknown(),
    field_signature(1, [#(0, [])]),
  )
  |> should.equal(checker.FieldWithinBudget)

  weigh(
    TAbs("next", TVar("next")),
    [],
    label_term([]),
    field_signature(1, [#(0, [])]),
  )
  |> should.equal(
    checker.FieldOverBudget(actual: TAbs("next", effect_term.unknown())),
  )
}

pub fn an_operator_valued_binder_grounds_to_a_constant_operator_test() {
  // `[Unknown]` in operator position would leave `[[Unknown]([Stdout])]`
  // stuck, and a stuck application never matches a ground budget. The stand-in
  // is an operator, so the redex fires and the body reaches [Unknown].
  weigh(
    TAbs("op", TApp(TVar("op"), label_term(["Stdout"]))),
    [],
    effect_term.unknown(),
    field_signature(1, [#(0, [0])]),
  )
  |> should.equal(checker.FieldWithinBudget)
}

pub fn a_named_polymorphic_operator_field_canonicalizes_then_grounds_test() {
  // The lifting path, not a term written straight into operator form: the
  // bound's payload `op` is substituted by the binder, which stays a bare
  // higher-kinded variable and is still applied.
  weigh(
    TApp(TVar("op"), label_term(["Stdout"])),
    [ParamBound(name: "run", effects: TVar("op"))],
    effect_term.unknown(),
    field_signature(1, [#(0, [0])]),
  )
  |> should.equal(checker.FieldWithinBudget)
}

pub fn a_nested_callback_shape_grounds_at_the_inner_arity_test() {
  // `fn(op: fn(Int, fn() -> Nil) -> Nil)`: `op`'s source arity is two, but only
  // its second parameter is fn-typed, so the stand-in needs one effect binder.
  // Curried twice, the redex would not fire and the body would stay stuck.
  weigh(
    TAbs("op", TApp(TVar("op"), label_term(["Stdout"]))),
    [],
    effect_term.unknown(),
    field_signature(1, [#(0, [1])]),
  )
  |> should.equal(checker.FieldWithinBudget)
}

pub fn a_constrained_binder_is_not_grounded_test() {
  // The declaration mentions its binder, so the position is constrained and
  // the two align by position instead.
  weigh(
    TAbs("next", TVar("next")),
    [],
    TAbs("cb", TVar("cb")),
    field_signature(1, [#(0, [])]),
  )
  |> should.equal(checker.FieldWithinBudget)
}

pub fn a_wrong_arity_declared_operator_is_an_author_error_test() {
  weigh(
    TAbs("a", TAbs("b", label_term([]))),
    [],
    TAbs("cb", label_term(["Stdout"])),
    field_signature(2, []),
  )
  |> should.equal(checker.DeclaredArityMismatch(arity: 2))
}

pub fn a_ground_budget_covers_every_arity_test() {
  // One line, a heterogeneous type: a constant budget is well-defined at every
  // arity, so no variant needs a special case.
  weigh(
    label_term(["Stdout"]),
    [],
    label_term(["Stdout"]),
    field_signature(0, []),
  )
  |> should.equal(checker.FieldWithinBudget)

  weigh(
    label_term(["Stdout"]),
    [],
    label_term(["Stdout"]),
    field_signature(3, []),
  )
  |> should.equal(checker.FieldWithinBudget)
}

pub fn a_site_over_its_budget_violates_test() {
  weigh(
    TAbs("msg", label_term(["Stdout", "Http"])),
    [],
    label_term(["Stdout"]),
    field_signature(1, []),
  )
  |> should.equal(
    checker.FieldOverBudget(actual: TAbs("msg", label_term(["Http", "Stdout"]))),
  )
}

// Finding reporting
//
// The lines `graded check` prints for the shapes that are not one call over
// budget. The unproved wordings carry the whole burden of not blaming the
// author's code, since they exit non-zero exactly as a violation does.

fn site(function: String) -> types.ConstructionSite {
  types.ConstructionSite(
    function:,
    constructor: types.ConstructorIdentity(
      module: "app",
      type_name: "Handler",
      variant: "Handler",
    ),
  )
}

pub fn format_finding_returns_clause_violation_test() {
  types.ReturnsClauseViolation(
    function: "app.traced",
    declared: TAbs("cb", TLabels(set.from_list(["Stdout"]))),
    computed: TAbs("cb", TLabels(set.from_list(["Http", "Stdout"]))),
  )
  |> checker.format_finding("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: app.traced returns the operator fn(cb) -> [Http, Stdout] but its `where returns` clause declares fn(cb) -> [Stdout]",
  )
}

pub fn format_finding_non_callable_return_test() {
  types.NonCallableReturnViolation(
    function: "app.plain",
    declared: TAbs("cb", TLabels(set.from_list(["Stdout"]))),
  )
  |> checker.format_finding("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: app.plain does not return a function, so its `where returns` clause fn(cb) -> [Stdout] describes an operator the function never hands back",
  )
}

pub fn format_finding_field_site_violation_test() {
  types.FieldSiteViolation(
    field_path: "app.Handler.on_click",
    declared: TLabels(set.new()),
    actual: TLabels(set.from_list(["Stdout"])),
    site: site("app.make"),
  )
  |> checker.format_finding("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: app.make wires app.Handler.on_click with effects [Stdout] but the field is declared []",
  )
}

// Every unproved cause reads as a limit graded hit, never as a claim about the
// checked code — the line exits the run non-zero either way, so the wording is
// the only thing telling the two apart.
pub fn format_finding_untraced_field_value_test() {
  types.UnprovedCheck(
    subject: "app.Handler.on_click",
    cause: types.UntracedFieldValue,
    site: option.Some(site("app.make")),
  )
  |> checker.format_finding("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: could not prove check app.Handler.on_click at app.make — the value wired here does not resolve to a function graded can follow; an `assume` line is the trusted form for a field it cannot",
  )
}

pub fn format_finding_uncalled_factory_test() {
  types.UnprovedCheck(
    subject: "app.Handler.on_click",
    cause: types.UncalledFactory(factory: "app.make"),
    site: option.Some(site("app.make")),
  )
  |> checker.format_finding("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: could not prove check app.Handler.on_click at app.make — the field is wired from a parameter of `app.make`, and no call of it is visible in this package",
  )
}

pub fn format_finding_missing_return_annotation_test() {
  types.UnprovedCheck(
    subject: "app.traced",
    cause: types.UnderivableReturnedOperator(reason: types.NoReturnAnnotation),
    site: option.None,
  )
  |> checker.format_finding("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: could not prove check app.traced — the function carries no return type annotation, so the operator it hands back cannot be derived from source",
  )
}

pub fn format_finding_unresolved_return_tail_test() {
  types.UnprovedCheck(
    subject: "app.traced",
    cause: types.UnderivableReturnedOperator(reason: types.UnresolvedReturnTail),
    site: option.None,
  )
  |> checker.format_finding("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: could not prove check app.traced — the value it returns does not resolve to a function graded can follow",
  )
}

pub fn format_finding_undeclared_foreign_return_test() {
  types.UnprovedCheck(
    subject: "app.native",
    cause: types.UndeclaredForeignReturn,
    site: option.None,
  )
  |> checker.format_finding("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: could not prove check app.native — the producer is foreign, so its returned operator comes from a declaration rather than from source, and nothing declares one; an `assume … where returns` line is what answers for it",
  )
}

pub fn format_finding_unproved_foreign_fallback_test() {
  types.UnprovedCheck(
    subject: "app.native",
    cause: types.UnprovedForeignFallback,
    site: option.None,
  )
  |> checker.format_finding("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: could not prove check app.native — the external's Gleam fallback body runs, and there is no union of operators to weigh it with the declaration; the clause holds only when it agrees with the declaration and the fallback's own returned operator is proved beside it",
  )
}

pub fn format_finding_field_bound_list_test() {
  types.UnprovedCheck(
    subject: "app.Handler.run",
    cause: types.UnsupportedCheckComponent(component: types.FieldBoundList),
    site: option.None,
  )
  |> checker.format_finding("proj.graded", _)
  |> should.equal(
    "proj.graded: could not prove check app.Handler.run — a bound list on a field path is not verified, and the bounds are what scope the effects term, so the budget cannot be read without them",
  )
}

pub fn format_finding_field_returns_clause_test() {
  types.UnprovedCheck(
    subject: "app.Handler.run",
    cause: types.UnsupportedCheckComponent(component: types.FieldReturnsClause),
    site: option.None,
  )
  |> checker.format_finding("proj.graded", _)
  |> should.equal(
    "proj.graded: could not prove check app.Handler.run — a `where returns` clause on a field path is not verified — nothing keys an operator returned by calling a field. The field budget on the same line still is",
  )
}

pub fn format_warning_unsupported_field_check_test() {
  types.UnsupportedFieldCheckWarning(name: "app.Handler.run", components: [
    types.FieldBoundList,
    types.FieldReturnsClause,
  ])
  |> checker.format_warning("proj.graded", _)
  |> should.equal(
    "proj.graded: warning: check app.Handler.run carries a bound list and a `where returns` clause on a field path, which nothing verifies — a field check weighs the values the package wires into the field, and a field head scopes no bound list and keys no returned operator",
  )
}

pub fn format_warning_unclosed_returns_clause_test() {
  types.UnclosedReturnsClauseWarning(function: "app.traced", free_vars: [
    "ghost", "other",
  ])
  |> checker.format_warning("proj.graded", _)
  |> should.equal(
    "proj.graded: warning: the `where returns` clause on app.traced has free variable(s) `ghost`, `other` naming no callback parameter of it — the clause is ignored and the returned function resolves to [Unknown]",
  )
}

pub fn format_warning_unground_returns_clause_test() {
  // The `assume` channel's rule is the line's own bound list, and nothing
  // else: the sentence names it that way, because a variable there is dropped
  // even when the function does have a callback parameter by that name.
  types.UngroundReturnsClauseWarning(function: "ffi.traced", free_vars: [
    "action",
  ])
  |> checker.format_warning("proj.graded", _)
  |> should.equal(
    "proj.graded: warning: the `where returns` clause on assume ffi.traced has variable(s) `action` the line's bounds do not scope — nothing binds an unscoped variable at a call site, so the clause is ignored. Name the variable in the line's bound list, or spell out the concrete effects",
  )
}

pub fn format_warning_unbound_external_term_variable_test() {
  types.UnboundAssumeTermVariableWarning(function: "ffi.each", free_vars: [
    "x",
  ])
  |> checker.format_warning("proj.graded", _)
  |> should.equal(
    "proj.graded: warning: assume ffi.each declares effects with variable(s) `x` that no bound's payload binds — substitution keys are the payloads' variables, so no call site can resolve them and they stay conservative. Add a bound whose payload names the variable, or remove it",
  )
}

pub fn format_warning_aliased_bound_variable_test() {
  types.AliasedBoundVariableWarning(function: "ffi.wrap", variables: [
    #("cb", "other"),
  ])
  |> checker.format_warning("proj.graded", _)
  |> should.equal(
    "proj.graded: warning: on ffi.wrap variable(s) `cb` (payload of `other`) also name a parameter of the line — the effects term binds such a variable through the payload while the `where returns` clause binds it by parameter name, so the two can charge different arguments. Rename the payload's variable",
  )
}

pub fn format_warning_dotless_external_returns_test() {
  types.DotlessReturnsClauseWarning(name: "lib")
  |> checker.format_warning("proj.graded", _)
  |> should.equal(
    "proj.graded: warning: assume lib where returns names a module, not a function — a returns declaration is per-function; the clause resolves nothing",
  )
}

// A resolved qualified call keeps the format the README documents.
pub fn format_violation_direct_call_test() {
  violation(
    QualifiedName("gleam/io", "println"),
    Specific(set.from_list(["Stdout"])),
  )
  |> checker.format_violation("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: run calls gleam/io.println with effects [Stdout] but declared []",
  )
}

pub fn format_violation_direct_call_with_unknown_test() {
  violation(
    QualifiedName("somedep/api", "fetch"),
    Specific(set.from_list(["Unknown"])),
  )
  |> checker.format_violation("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: run calls somedep/api.fetch with unresolved effects [Unknown] but declared []",
  )
}

pub fn format_violation_field_call_with_unknown_test() {
  violation(
    QualifiedName("<field>", "config.resolver"),
    Specific(set.from_list(["Unknown"])),
  )
  |> checker.format_violation("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: run calls field `resolver` on `config` with unresolved effects [Unknown] but declared []",
  )
}

// A field call can resolve cleanly and still exceed its budget: the effects are
// over the budget, not unresolved.
pub fn format_violation_field_call_resolved_test() {
  violation(
    QualifiedName("<field>", "config.resolver"),
    Specific(set.from_list(["Stdout"])),
  )
  |> checker.format_violation("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: run calls field `resolver` on `config` with effects [Stdout] but declared []",
  )
}

// A call-result receiver has no path to print, so the prose describes it
// instead of leaking the sentinel the extractor keys it on.
pub fn format_violation_computed_receiver_field_call_test() {
  let message =
    violation(
      QualifiedName("<field>", extract.computed_receiver <> ".handler"),
      Specific(set.from_list(["Unknown"])),
    )
    |> checker.format_violation("src/app.gleam", _)
  message
  |> should.equal(
    "src/app.gleam: run calls field `handler` on a computed value with unresolved effects [Unknown] but declared []",
  )
  string.contains(message, extract.computed_receiver) |> should.be_false()
}

pub fn format_violation_partially_resolved_effects_test() {
  violation(
    QualifiedName("<apply>", "<unknown>"),
    Specific(set.from_list(["Stdout", "Unknown"])),
  )
  |> checker.format_violation("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: run calls a computed function value with unresolved effects [Stdout, Unknown] but declared []",
  )
}

// A polymorphic actual carries no `Unknown` label, so the clause stays "with
// effects" and the pre-existing variables hint is what explains it.
pub fn format_violation_polymorphic_keeps_variables_hint_test() {
  violation(
    QualifiedName("<param>", "f"),
    Polymorphic(set.new(), set.from_list(["e"])),
  )
  |> checker.format_violation("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: run calls parameter `f` with effects [e] but declared []"
    <> "\n  hint: actual effects contain unresolved variables; add a `check "
    <> "run(<param>: [...])` bound, or pass a function reference / constructor"
    <> " whose effects are known",
  )
}

// The sentinel says the name matched no parameter bound and no function of this
// module — not that the name is undefined, which it often is (a destructured
// binding, a module constant, a record field path).
pub fn format_violation_local_call_test() {
  violation(
    QualifiedName("<local>", "helper"),
    Specific(set.from_list(["Unknown"])),
  )
  |> checker.format_violation("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: run calls `helper`, which is neither a bound parameter nor a function in this module, with unresolved effects [Unknown] but declared []",
  )
}

pub fn format_violation_returned_operator_test() {
  violation(
    QualifiedName("<returned>", "pick"),
    Specific(set.from_list(["Unknown"])),
  )
  |> checker.format_violation("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: run calls a function returned by `pick` with unresolved effects [Unknown] but declared []",
  )
}

pub fn format_violation_returned_operator_qualifies_producer_test() {
  violation(
    QualifiedName("<returned>", "somedep/api.make"),
    Specific(set.from_list(["Stdout"])),
  )
  |> checker.format_violation("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: run calls a function returned by `somedep/api.make` with effects [Stdout] but declared []",
  )
}

// The same sentinel covers a pipe target and an immediately-invoked function,
// so the prose claims only what both shapes share.
pub fn format_violation_inline_function_test() {
  violation(
    QualifiedName("<pipe>", "<operator>"),
    Specific(set.from_list(["Stdout"])),
  )
  |> checker.format_violation("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: run calls an inline function with effects [Stdout] but declared []",
  )
}

// Covers a let-bound closure *and* a let-bound `case` of functions, which is
// not a closure.
pub fn format_violation_let_bound_value_test() {
  violation(
    QualifiedName("<closure>", "<applied>"),
    Specific(set.from_list(["Stdout"])),
  )
  |> checker.format_violation("src/app.gleam", _)
  |> should.equal(
    "src/app.gleam: run calls a let-bound function value with effects [Stdout] but declared []",
  )
}

// An unrecognised sentinel is described generically rather than printed. The
// assertion targets the call identity, not `<` anywhere: the variables hint
// carries a literal `(<param>: [...])` placeholder.
pub fn format_violation_unrecognised_sentinel_does_not_leak_test() {
  let message =
    violation(
      QualifiedName("<bogus>", "whatever"),
      Specific(set.from_list(["Unknown"])),
    )
    |> checker.format_violation("src/app.gleam", _)
  message
  |> should.equal(
    "src/app.gleam: run calls an unclassified call site with unresolved effects [Unknown] but declared []",
  )
  string.contains(message, "calls <") |> should.be_false()
  string.contains(message, "<bogus>") |> should.be_false()
}

// Explained violations
//
// What the resolver recorded, in the message: the reason refines the action
// phrase, the origin follows the effect set. A reason is stated only for a set
// that is still unresolved; an origin whenever one was recorded.

// The message for a `run` violation carrying `reason` and `origin`.
fn explained_message(
  call: types.QualifiedName,
  actual: EffectSet,
  reason: option.Option(types.UnknownReason),
  origin: option.Option(types.LookupOrigin),
) -> String {
  explained_violation(call, actual, reason, origin)
  |> checker.format_violation("src/app.gleam", _)
}

fn unresolved_field(reason: types.UnknownReason) -> String {
  explained_message(
    QualifiedName("<field>", "repo.find"),
    Specific(set.from_list(["Unknown"])),
    Some(reason),
    None,
  )
}

pub fn format_violation_names_the_unannotated_receiver_type_test() {
  unresolved_field(types.FieldNotAnnotated("dep/repo", "Repo"))
  |> should.equal(
    "src/app.gleam: run calls field `find` on `repo` of type `dep/repo.Repo`, which has no effect annotation for that field, with unresolved effects [Unknown] but declared []",
  )
}

pub fn format_violation_leaves_a_module_less_type_bare_test() {
  // The syntactic fallback types a receiver by its annotation alone, which
  // carries no module to qualify it with.
  unresolved_field(types.FieldNotAnnotated("", "Config"))
  |> should.equal(
    "src/app.gleam: run calls field `find` on `repo` of type `Config`, which has no effect annotation for that field, with unresolved effects [Unknown] but declared []",
  )
}

pub fn format_violation_says_the_receiver_type_is_unresolved_test() {
  unresolved_field(types.ReceiverTypeUnresolved)
  |> should.equal(
    "src/app.gleam: run calls field `find` on `repo`, whose type could not be resolved, with unresolved effects [Unknown] but declared []",
  )
}

pub fn format_violation_says_the_receiver_is_untraceable_test() {
  unresolved_field(types.UntraceableReceiver)
  |> should.equal(
    "src/app.gleam: run calls field `find` on `repo`, whose value could not be traced, with unresolved effects [Unknown] but declared []",
  )
}

pub fn format_violation_says_the_wired_value_is_unresolved_test() {
  unresolved_field(types.UnresolvedFieldValue)
  |> should.equal(
    "src/app.gleam: run calls field `find` on `repo`, whose wired value's effects could not be resolved, with unresolved effects [Unknown] but declared []",
  )
}

pub fn format_violation_keeps_the_computed_receiver_wording_test() {
  // "on a computed value" already states the untraceability every field reason
  // would repeat, so the reason adds nothing to it.
  explained_message(
    QualifiedName("<field>", extract.computed_receiver <> ".find"),
    Specific(set.from_list(["Unknown"])),
    Some(types.UntraceableReceiver),
    None,
  )
  |> should.equal(
    "src/app.gleam: run calls field `find` on a computed value with unresolved effects [Unknown] but declared []",
  )
}

pub fn format_violation_says_nothing_declares_the_call_test() {
  explained_message(
    QualifiedName("somedep/api", "fetch"),
    Specific(set.from_list(["Unknown"])),
    Some(types.NoKnownEffects),
    None,
  )
  |> should.equal(
    "src/app.gleam: run calls somedep/api.fetch, which no spec, external, or catalog declares, with unresolved effects [Unknown] but declared []",
  )
}

pub fn format_violation_says_the_external_is_undeclared_test() {
  explained_message(
    QualifiedName("app", "now"),
    Specific(set.from_list(["Unknown"])),
    Some(types.UndeclaredExternal),
    None,
  )
  |> should.equal(
    "src/app.gleam: run calls app.now, an external with no declared effects, with unresolved effects [Unknown] but declared []",
  )
}

pub fn format_violation_says_the_producer_is_unresolved_test() {
  explained_message(
    QualifiedName("<returned>", "somedep/api.pick"),
    Specific(set.from_list(["Unknown"])),
    Some(types.UntraceableProducer),
    None,
  )
  |> should.equal(
    "src/app.gleam: run calls a function returned by `somedep/api.pick`, whose producer could not be resolved, with unresolved effects [Unknown] but declared []",
  )
}

pub fn format_violation_names_the_source_that_answered_test() {
  explained_message(
    QualifiedName("gleam/io", "println"),
    Specific(set.from_list(["Stdout"])),
    None,
    Some(types.Catalog("gleam_stdlib")),
  )
  |> should.equal(
    "src/app.gleam: run calls gleam/io.println with effects [Stdout] (from gleam_stdlib's catalog entry) but declared []",
  )
}

pub fn format_violation_names_the_source_of_a_known_unknown_test() {
  // A committed `effects f : [Unknown]` line is a resolved answer whose origin
  // is the whole explanation, so it is stated even though the set is unknown.
  explained_message(
    QualifiedName("app/db", "query"),
    Specific(set.from_list(["Unknown"])),
    None,
    Some(types.CommittedSpec),
  )
  |> should.equal(
    "src/app.gleam: run calls app/db.query with unresolved effects [Unknown] (from your spec) but declared []",
  )
}

pub fn format_violation_states_a_reason_and_an_origin_together_test() {
  // Nothing keyed the function itself, so its module's declaration answered —
  // and the field it was wired through has no annotation of its own.
  explained_message(
    QualifiedName("<field>", "repo.find"),
    Specific(set.from_list(["Unknown"])),
    Some(types.FieldNotAnnotated("dep/repo", "Repo")),
    Some(types.ModuleAssumeOrigin(source: types.UserAssume)),
  )
  |> should.equal(
    "src/app.gleam: run calls field `find` on `repo` of type `dep/repo.Repo`, which has no effect annotation for that field, with unresolved effects [Unknown] (from a module-level `assume` in your spec) but declared []",
  )
}

pub fn format_violation_holds_a_reason_back_from_a_resolved_set_test() {
  // The reason is recorded whether or not a bound later discharges the term;
  // nothing about a resolved set is unexplained, so the plain phrase stands.
  explained_message(
    QualifiedName("<field>", "repo.find"),
    Specific(set.from_list(["Stdout"])),
    Some(types.FieldNotAnnotated("dep/repo", "Repo")),
    None,
  )
  |> should.equal(
    "src/app.gleam: run calls field `find` on `repo` with effects [Stdout] but declared []",
  )
}

// What a violation records
//
// The resolver that decided a call's effect records why it could not resolve it
// and which source answered, at the moment it decides. These run the real mint
// sites and assert the record, not the wording.

// The single violation `run`'s `[]` budget produces for `source`.
fn only_violation(source: String) -> types.Violation {
  let assert [violation] = check_source(source, [pure_check("run")])
  violation
}

// The violation `run` reports for a call carrying `sentinel`, where the body
// also violates elsewhere (the producer call, the wired value's own call).
fn violation_of_kind(source: String, sentinel: String) -> types.Violation {
  let assert Ok(violation) =
    check_source(source, [pure_check("run")])
    |> list.find(fn(v) { v.explanation.call.module == sentinel })
  violation
}

// The violation `run` reports for its field call.
fn field_violation(source: String) -> types.Violation {
  violation_of_kind(source, "<field>")
}

pub fn records_that_no_source_keys_the_call_test() {
  only_violation(
    "import somedep/api
pub fn run() { api.fetch() }",
  ).explanation.reason
  |> should.equal(Some(types.NoKnownEffects))
}

pub fn records_an_undeclared_external_test() {
  // A same-module bodyless `@external` with no `assume` line: the
  // body says nothing and no declaration speaks for it.
  only_violation(
    "@external(erlang, \"ffi\", \"now\")
pub fn now() -> Int

pub fn run() { now() }",
  ).explanation.reason
  |> should.equal(Some(types.UndeclaredExternal))
}

pub fn records_the_source_that_answered_test() {
  // A resolved call is over budget, not unresolved: it carries an origin and no
  // reason.
  let violation =
    only_violation(
      "import gleam/io
pub fn run() { io.println(\"x\") }",
    )
  violation.explanation.origin
  |> should.equal(Some(types.Catalog("gleam_stdlib")))
  violation.explanation.reason |> should.equal(None)
}

pub fn records_an_unresolved_receiver_type_test() {
  // No girard types are passed and the parameter carries no annotation, so
  // nothing names the receiver's type.
  only_violation(
    "pub fn run(config) -> Nil {
  config.resolver(\"x\")
}",
  ).explanation.reason
  |> should.equal(Some(types.ReceiverTypeUnresolved))
}

pub fn records_an_unannotated_field_test() {
  // The syntactic fallback types the receiver but has no module to qualify it
  // with, and no field `assume` line decides the field.
  only_violation(
    "pub type Config {
  Config(resolver: fn(String) -> Nil)
}

pub fn run(config: Config) -> Nil {
  config.resolver(\"x\")
}",
  ).explanation.reason
  |> should.equal(
    Some(types.FieldNotAnnotated(module: "", type_name: "Config")),
  )
}

pub fn records_an_untraceable_receiver_test() {
  // The receiver is rooted at a shadowing opaque `let`, so the construction it
  // came from can't be traced.
  only_violation(
    "pub type Inner {
  Inner(resolver: fn() -> Nil)
}

pub type Wrapper {
  Wrapper(inner: Inner)
}

pub fn external_wrapper() -> Wrapper {
  Wrapper(inner: Inner(resolver: fn() { Nil }))
}

pub fn run(options: Wrapper) -> Nil {
  let options = external_wrapper()
  let x = options.inner
  x.resolver()
}",
  ).explanation.reason
  |> should.equal(Some(types.UntraceableReceiver))
}

pub fn records_an_unresolved_wired_value_test() {
  // The receiver's construction is traced, but the value wired into the field
  // is a call no source resolves, so nothing grounds the field. The reason is
  // read off the term the field call resolved to, after substitution and
  // concretization — the point where a wired value's effect is finally known.
  let source =
    "import somedep/api

pub type Handler {
  Handler(handler: fn(String) -> Nil)
}

pub fn run() -> Nil {
  let h = Handler(handler: api.pick())
  h.handler(\"x\")
}"
  field_violation(source).explanation.reason
  |> should.equal(Some(types.UnresolvedFieldValue))
}

pub fn records_an_untraceable_producer_test() {
  // The producer call is a violation of its own; this is the application of
  // what it returned.
  let source =
    "import somedep/api
pub fn run() -> Nil {
  let h = api.pick()
  h(\"x\")
}"
  violation_of_kind(source, "<returned>").explanation.reason
  |> should.equal(Some(types.UntraceableProducer))
}

pub fn a_proven_field_carries_the_wired_value_source_test() {
  // The field is wired to a function the knowledge base holds, so the field
  // call reports where that function's effect came from.
  let violation =
    only_violation(
      "import gleam/io

pub type Handler {
  Handler(handler: fn(String) -> Nil)
}

pub fn run() -> Nil {
  let h = Handler(handler: io.println)
  h.handler(\"x\")
}",
    )
  violation.explanation.origin
  |> should.equal(Some(types.Catalog("gleam_stdlib")))
  violation.explanation.reason |> should.equal(None)
}

pub fn a_reason_survives_substitution_unrendered_test() {
  // An unannotated helper's field call mints a field variable and a reason; the
  // caller's field bound grounds the variable to a concrete over-budget effect.
  // The reason is still recorded — the message just doesn't state it, because
  // nothing about the reported set is unresolved.
  let source =
    "pub type Config {
  Config(resolver: fn(String) -> Nil)
}

fn helper(config: Config) -> Nil {
  config.resolver(\"x\")
}

pub fn run(config: Config) -> Nil {
  helper(config)
}"
  let annotation =
    EffectAnnotation(
      Check,
      "run",
      [
        ParamBound(
          "config.resolver",
          effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
        ),
      ],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    )
  let assert [violation] = check_source(source, [annotation])
  violation.explanation.actual
  |> should.equal(Specific(set.from_list(["Stdout"])))
  violation.explanation.reason
  |> should.equal(
    Some(types.FieldNotAnnotated(module: "", type_name: "Config")),
  )
  checker.format_violation("src/app.gleam", violation)
  |> should.equal(
    "src/app.gleam: run calls field `resolver` on `config` with effects [Stdout] but declared []",
  )
}

// Sentinels decoded end-to-end
//
// Unit tests build `Violation`s by hand; these run the checker over source so
// the real mint sites are what gets decoded.

pub fn format_violation_decodes_field_call_source_test() {
  let source =
    "pub fn run(config) -> Nil {
  config.resolver(\"x\")
}"
  let assert [message] = formatted_violations(source, [pure_check("run")])
  string.contains(message, "calls field `resolver` on `config`")
  |> should.be_true()
  string.contains(message, "<field>.") |> should.be_false()
  string.contains(message, "calls <") |> should.be_false()
}

pub fn format_violation_decodes_returned_operator_source_test() {
  let source =
    "import gleam/io
fn pick() -> fn(String) -> Nil { io.println }
pub fn run() -> Nil {
  let h = pick()
  h(\"x\")
}"
  let assert [message] = formatted_violations(source, [pure_check("run")])
  string.contains(message, "calls a function returned by `pick`")
  |> should.be_true()
  string.contains(message, "<returned>.") |> should.be_false()
  string.contains(message, "calls <") |> should.be_false()
}

pub fn format_violation_decodes_computed_application_source_test() {
  let source =
    "pub fn run(funcs: #(fn(String) -> Nil)) -> Nil {
  funcs.0(\"x\")
}"
  let assert [message] = formatted_violations(source, [pure_check("run")])
  string.contains(message, "calls a computed function value")
  |> should.be_true()
  string.contains(message, "<apply>.") |> should.be_false()
  string.contains(message, "calls <") |> should.be_false()
}

// A call-result receiver has no source path, so the extractor keys it on the
// computed-receiver sentinel — which the message describes, never prints.
pub fn format_violation_decodes_computed_receiver_source_test() {
  let source =
    "import gleam/io
pub type Handler {
  Handler(handler: fn(String) -> Nil)
}
fn make() -> Handler {
  Handler(handler: io.println)
}
pub fn run() -> Nil {
  make().handler(\"x\")
}"
  let assert [message] = formatted_violations(source, [pure_check("run")])
  string.contains(message, "calls field `handler` on a computed value")
  |> should.be_true()
  string.contains(message, extract.computed_receiver) |> should.be_false()
}

// A destructured binding is bound three lines up, so the message reports what
// failed to resolve rather than claiming the name is undefined.
pub fn format_violation_destructured_binding_source_test() {
  let source =
    "fn first(ops: List(fn() -> Nil)) -> Result(fn() -> Nil, Nil) {
  Error(Nil)
}
pub fn run(ops: List(fn() -> Nil)) -> Nil {
  let assert Ok(h) = first(ops)
  h()
}"
  let assert [message] = formatted_violations(source, [pure_check("run")])
  string.contains(
    message,
    "calls `h`, which is neither a bound parameter nor a function in this module,",
  )
  |> should.be_true()
  string.contains(message, "not defined in this module") |> should.be_false()
}

// A module constant *is* defined in this module; only the effect resolution
// failed, since the function map indexes functions alone.
pub fn format_violation_module_constant_source_test() {
  let source =
    "import gleam/io
const log = io.println

pub fn run() -> Nil {
  log(\"x\")
}"
  let assert [message] = formatted_violations(source, [pure_check("run")])
  string.contains(
    message,
    "calls `log`, which is neither a bound parameter nor a function in this module,",
  )
  |> should.be_true()
  string.contains(message, "not defined in this module") |> should.be_false()
}

// An unbounded record field path names no function at all, so the same wording
// covers it.
pub fn format_violation_unbounded_field_path_source_test() {
  let source =
    "pub fn run(options) -> Nil {
  let f = options.svc
  f(\"x\")
}"
  let assert [message] = formatted_violations(source, [pure_check("run")])
  string.contains(
    message,
    "calls `options.svc`, which is neither a bound parameter nor a function in this module,",
  )
  |> should.be_true()
  string.contains(message, "not defined in this module") |> should.be_false()
}

// A dotted bound in `param_bounds` is a *field* bound, so calling it through an
// alias reads exactly like the un-aliased field call it stands for.
pub fn format_violation_aliased_field_bound_reads_as_field_test() {
  let bounded =
    EffectAnnotation(
      Check,
      "run",
      [
        ParamBound(
          "options.svc",
          effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
        ),
      ],
      effect_term.from_effect_set(Specific(set.new())),
      returns: None,
    )
  let expected =
    "src/app.gleam: run calls field `svc` on `options` with effects [Stdout] but declared []"
  let aliased =
    "pub fn run(options) -> Nil {
  let f = options.svc
  f(\"x\")
}"
  formatted_violations(aliased, [bounded]) |> should.equal([expected])
  let direct =
    "pub fn run(options) -> Nil {
  options.svc(\"x\")
}"
  formatted_violations(direct, [bounded]) |> should.equal([expected])
}

// The pipe sentinel is minted for any inline function applied to arguments, so
// the prose can't promise a `|>` — here there is none.
pub fn format_violation_immediately_invoked_function_source_test() {
  let source =
    "import gleam/io
pub fn run() -> Nil {
  fn(a, cb) { cb(a) }(\"x\", io.println)
}"
  let assert [message] = formatted_violations(source, [pure_check("run")])
  string.contains(message, "calls an inline function") |> should.be_true()
  string.contains(message, "pipes into") |> should.be_false()
}

// The same wording covers the pipe shape the sentinel is also minted for.
pub fn format_violation_pipe_target_source_test() {
  let source =
    "import gleam/io
pub fn run() -> Nil {
  \"x\" |> fn(m) { io.println(m) }
}"
  let assert [message] = formatted_violations(source, [pure_check("run")])
  string.contains(message, "calls an inline function") |> should.be_true()
}

// A let-bound `case` of functions shares the closure sentinel without being a
// closure, so the prose says "function value".
pub fn format_violation_let_bound_choice_source_test() {
  let source =
    "import gleam/io
pub fn run(flag: Bool) -> Nil {
  let h = case flag {
    True -> fn(cb) { cb(\"a\") }
    False -> fn(cb) { cb(\"b\") }
  }
  h(io.println)
}"
  let assert [message] = formatted_violations(source, [pure_check("run")])
  string.contains(message, "calls a let-bound function value")
  |> should.be_true()
  string.contains(message, "closure") |> should.be_false()
}

// A producer in a dependency keeps its module, so it doesn't read like a
// same-module producer of the same name.
pub fn format_violation_dependency_producer_keeps_module_test() {
  let assert Ok(spec) =
    annotation.parse_file("effects dep.make : [] where returns : [Stdout]")
  let source =
    "
import dep
pub fn run() -> Nil {
  let f = dep.make()
  f()
}
"
  let assert Ok(module) = glance.module(source)
  let kb =
    knowledge_base()
    |> effects.with_inferred(
      dict.from_list([
        #(
          QualifiedName("dep", "make"),
          effect_term.from_effect_set(types.empty()),
        ),
      ]),
      types.ProjectInferred,
    )
    |> effects.with_closed_returned_operators(
      effects.load_spec_returns_from_file(spec),
      types.DependencySpec("dep"),
    )
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [pure_check("run")],
      kb,
      signatures.from_glance_module("app", module),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert [violation] = violations
  // The latent effect was decided by the dependency's `returns` line, so the
  // message names it.
  violation.explanation.origin
  |> should.equal(Some(types.DependencySpec("dep")))
  checker.format_violation("src/app.gleam", violation)
  |> should.equal(
    "src/app.gleam: run calls a function returned by `dep.make` with effects [Stdout] (from dep's shipped spec) but declared []",
  )
}

pub fn a_forwarded_field_carries_the_wired_value_source_test() {
  // The same field call as `a_proven_field_carries_the_wired_value_source_test`,
  // reached through a helper instead of read directly: the caller's
  // substitution binds the field variable to the wired value, so the source
  // that answered for that value travels with it.
  let violation =
    field_violation(
      "import gleam/io

pub type Handler {
  Handler(handler: fn(String) -> Nil)
}

fn helper(h: Handler) -> Nil {
  h.handler(\"x\")
}

pub fn run() -> Nil {
  let h = Handler(handler: io.println)
  helper(h)
}",
    )
  violation.explanation.actual
  |> should.equal(Specific(set.from_list(["Stdout"])))
  violation.explanation.origin
  |> should.equal(Some(types.Catalog("gleam_stdlib")))
}

pub fn a_type_line_names_the_spec_that_declared_it_test() {
  // The field `assume` line resolved the field call, so the message names the file the
  // line sits in rather than the bare kind of line.
  let source =
    "pub type Repo {
  Repo(find: fn(String) -> Nil)
}

pub fn run(repo: Repo) -> Nil {
  repo.find(\"x\")
}"
  let type_fields = [
    types.FieldAnnotation(
      module: None,
      type_name: "Repo",
      field: "find",
      effects: effect_term.from_effect_set(Specific(set.from_list(["Storage"]))),
    ),
  ]
  let assert [violation] =
    check_source_with_type_fields(source, [pure_check("run")], type_fields)
  violation.explanation.origin
  |> should.equal(Some(types.FieldAssumeOrigin(source: types.CommittedSpec)))
  checker.format_violation("src/app.gleam", violation)
  |> should.equal(
    "src/app.gleam: run calls field `find` on `repo` with effects [Storage] (from a field `assume` in your spec) but declared []",
  )
}

pub fn records_an_untraceable_argument_test() {
  // `validate_range`'s own term resolved — the entry gives it its callback's
  // effects — and the callback this call passes is an expression nothing
  // resolves. The `[Unknown]` is the argument's, so the entry that answered is
  // not named for it.
  let source =
    "
import validation
pub fn new() {
  validation.validate_range(42, to_error: 1 + 2)
}
"
  let assert Ok(module) = glance.module(source)
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [pure_check("new")],
      polymorphic_kb(),
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert [violation] = violations
  violation.explanation.reason |> should.equal(Some(types.UntraceableArgument))
  violation.explanation.origin |> should.equal(None)
  checker.format_violation("src/app.gleam", violation)
  |> should.equal(
    "src/app.gleam: new calls validation.validate_range, whose effects depend on an argument that could not be resolved, with unresolved effects [Unknown] but declared []",
  )
}

pub fn an_entry_that_states_unknown_keeps_its_source_test() {
  // The entry's own term is `[Unknown]`, so substitution did not put it there
  // and the source that committed it is the whole explanation.
  let source =
    "
import vault
pub fn new() {
  vault.query()
}
"
  let assert Ok(module) = glance.module(source)
  let kb =
    effects.with_inferred(
      knowledge_base(),
      dict.from_list([
        #(
          QualifiedName("vault", "query"),
          effect_term.from_effect_set(Specific(set.from_list(["Unknown"]))),
        ),
      ]),
      types.CommittedSpec,
    )
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [pure_check("new")],
      kb,
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert [violation] = violations
  violation.explanation.reason |> should.equal(None)
  violation.explanation.origin |> should.equal(Some(types.CommittedSpec))
}

pub fn records_an_untraceable_argument_through_a_helper_test() {
  // The dependency call resolved inside `helper`; the caller's unresolvable
  // callback is what took it to `[Unknown]`, so the dependency entry is not
  // named for it — the same account the direct call gives.
  let source =
    "
import validation
fn helper(cb: fn(String) -> Nil) {
  validation.validate_range(42, to_error: cb)
}
pub fn new() {
  helper(1 + 2)
}
"
  let assert Ok(module) = glance.module(source)
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [pure_check("new")],
      polymorphic_kb(),
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert [violation] = violations
  violation.explanation.reason |> should.equal(Some(types.UntraceableArgument))
  violation.explanation.origin |> should.equal(None)
  checker.format_violation("src/app.gleam", violation)
  |> should.equal(
    "src/app.gleam: new calls validation.validate_range, whose effects depend on an argument that could not be resolved, with unresolved effects [Unknown] but declared []",
  )
}

pub fn a_same_module_producer_names_no_source_test() {
  // The producer is analysed from this module's own source this run, not read
  // from a spec, so there is no source to name.
  let source =
    "
import gleam/io
fn make() -> fn() -> Nil {
  fn() { io.println(\"x\") }
}

pub fn run() -> Nil {
  let f = make()
  f()
}
"
  let assert Ok(module) = glance.module(source)
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [pure_check("run")],
      knowledge_base(),
      signatures.from_glance_module("app", module),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert Ok(violation) =
    list.find(violations, fn(v) { v.explanation.call.module == "<returned>" })
  violation.explanation.origin |> should.equal(None)
  violation.explanation.reason |> should.equal(None)
}

// Explaining a function
//
// `explain` re-walks a body and reports every contributor the subset check
// would weigh, budget or no budget. What it reports about a call has to be what
// a violation for that same call reports.

// One block per bound set, with the arguments that vary between these tests.
// girard contributes no types here: the fixtures resolve at the syntax level.
fn explain_blocks(
  module: glance.Module,
  function: String,
  bounds: List(List(types.ParamBound)),
  knowledge_base: effects.KnowledgeBase,
  registry: signatures.SignatureRegistry,
) -> Result(List(List(types.CallExplanation)), Nil) {
  checker.explain(
    module,
    "",
    function,
    bounds,
    knowledge_base,
    registry,
    dict.new(),
    dict.new(),
    types.all_targets(),
  )
  // These tests assert on contributors; the effective bounds and total term
  // paired with each block are `why`'s headline concern and are exercised
  // through it.
  |> result.map(list.map(_, fn(block) { block.explanations }))
}

// The common case: one bound set, the empty knowledge base, one block back.
fn explain_source(
  source: String,
  function: String,
  bounds: List(types.ParamBound),
) -> List(types.CallExplanation) {
  let assert Ok(module) = glance.module(source)
  let assert Ok([explanations]) =
    explain_blocks(
      module,
      function,
      [bounds],
      knowledge_base(),
      signatures.from_glance_module("app", module),
    )
  explanations
}

pub fn explain_grounds_phantom_variables_in_contributors_test() {
  // The knowledge base can answer a call with a term still carrying a variable
  // the calling function has no parameter for — an unresolved higher-order
  // shape leaves a nested closure's binder behind. The block total collapses
  // it to `[Unknown]`; the contributor line states the same collapse rather
  // than leaking the internal binder as an effect named after it.
  let source =
    "import helper/lib
pub fn run() {
  lib.use_op(1)
}"
  let assert Ok(module) = glance.module(source)
  let knowledge_base =
    effects.empty_knowledge_base()
    |> effects.with_inferred(
      dict.from_list([
        #(QualifiedName("helper/lib", "use_op"), types.TVar("cb")),
      ]),
      types.ProjectInferred,
    )
  let assert Ok([
    checker.ExplainedBlock(total:, explanations: [explanation], ..),
  ]) =
    checker.explain(
      module,
      "app",
      "run",
      [[]],
      knowledge_base,
      signatures.from_glance_module("app", module),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  total |> should.equal(effect_term.unknown())
  explanation.actual |> should.equal(Specific(set.from_list(["Unknown"])))
}

pub fn explain_returns_field_variable_bounds_test() {
  // A field-effect variable survives the total (unlike a phantom), so the
  // block's bounds carry its identity binder beside the effective bounds —
  // the same pairing inference writes — and a renderer stating the total over
  // them reads `[r.run]` as forwarding that field's effects.
  let source =
    "pub type Runner {
  Runner(run: fn() -> Nil)
}

pub fn go(r: Runner) -> Nil {
  r.run()
}"
  let assert Ok(module) = glance.module(source)
  let assert Ok([checker.ExplainedBlock(bounds:, total:, ..)]) =
    checker.explain(
      module,
      "app",
      "go",
      [[]],
      effects.empty_knowledge_base(),
      signatures.from_glance_module("app", module),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  total |> should.equal(types.TVar("r.run"))
  bounds
  |> list.contains(ParamBound("r.run", types.TVar("r.run")))
  |> should.be_true()
}

pub fn fallback_summary_records_field_variable_bounds_test() {
  // The same pairing through the fallback channel: the summary's term keeps
  // the field variable, so the recorded bounds keep its binder — without it
  // the emitted `effects` line states `[r.run]` over nothing and the prose
  // has an unexplained symbolic total.
  let source =
    "pub type Runner {
  Runner(run: fn() -> Nil)
}

@external(javascript, \"e\", \"r\")
pub fn run(r: Runner) -> Nil {
  r.run()
}"
  let assert Ok(module) = glance.module(source)
  checker.fallback_effects(
    module,
    "app",
    effects.empty_knowledge_base(),
    signatures.from_glance_module("app", module),
    dict.new(),
    dict.new(),
    types.all_targets(),
  )
  |> dict.get("run")
  |> should.equal(
    Ok(#(types.TVar("r.run"), [ParamBound("r.run", types.TVar("r.run"))])),
  )
}

pub fn fallback_summary_collapses_phantom_variables_test() {
  // The same class through the fallback channel: the summary is published to
  // every caller and to `graded effect`, so a variable that is no parameter of
  // the external is grounded before the summary is stored — otherwise the
  // query would report `[cb]` while callers and `why` groom the same term to
  // `[Unknown]`.
  let source =
    "import helper/lib
@external(javascript, \"e\", \"r\")
pub fn run() -> Nil {
  lib.use_op(1)
}"
  let assert Ok(module) = glance.module(source)
  let knowledge_base =
    effects.empty_knowledge_base()
    |> effects.with_inferred(
      dict.from_list([
        #(QualifiedName("helper/lib", "use_op"), types.TVar("cb")),
      ]),
      types.ProjectInferred,
    )
  checker.fallback_effects(
    module,
    "app",
    knowledge_base,
    signatures.from_glance_module("app", module),
    dict.new(),
    dict.new(),
    types.all_targets(),
  )
  |> dict.get("run")
  |> should.equal(Ok(#(effect_term.unknown(), [])))
}

pub fn explain_orders_contributors_by_span_test() {
  // Source order, so the enclosing `io.println` precedes the `string.append` it
  // takes its argument from, and the second statement's call comes last.
  let source =
    "import gleam/io
import gleam/string
pub fn run(a) {
  io.println(string.append(a, \"b\"))
  io.println(\"c\")
}"
  explain_source(source, "run", [])
  |> list.map(fn(explanation) { explanation.call })
  |> should.equal([
    QualifiedName("gleam/io", "println"),
    QualifiedName("gleam/string", "append"),
    QualifiedName("gleam/io", "println"),
  ])
}

pub fn explain_shares_one_analysis_across_bound_sets_test() {
  // Each bound set explains the same body under its own bounds — the reason
  // `why` prints a block per `check` line instead of picking one — and one walk
  // answers them all.
  let source =
    "pub fn run(f: fn() -> Nil, g: fn() -> Nil) -> Nil {
  f()
  g()
}"
  let assert Ok(module) = glance.module(source)
  let assert Ok([bound_f, bound_g]) =
    explain_blocks(
      module,
      "run",
      [[ParamBound("f", stdout_term())], [ParamBound("g", stdout_term())]],
      knowledge_base(),
      signatures.from_glance_module("app", module),
    )
  // The parameter each set does not name keeps the identity bound inference
  // gives it, so it reports as the parameter it is rather than as `[Unknown]`.
  bound_f
  |> list.map(fn(explanation) { explanation.actual })
  |> should.equal([
    Specific(set.from_list(["Stdout"])),
    Polymorphic(set.new(), set.from_list(["g"])),
  ])
  bound_g
  |> list.map(fn(explanation) { explanation.actual })
  |> should.equal([
    Polymorphic(set.new(), set.from_list(["f"])),
    Specific(set.from_list(["Stdout"])),
  ])
}

pub fn explain_orders_same_start_by_end_test() {
  // `f()()` puts two calls at one offset: the inner application and the
  // application of what it returns. Ordering on the start alone would leave
  // which comes first to the order the collector concatenates its categories in.
  let source =
    "pub fn run(f: fn() -> fn() -> Nil) -> Nil {
  f()()
}"
  let assert [inner, outer] = explain_source(source, "run", [])
  inner.span.start |> should.equal(outer.span.start)
  { inner.span.end < outer.span.end } |> should.be_true()
  checker.call_kind(inner.call)
  |> should.equal(checker.ParameterCall("f"))
  checker.call_kind(outer.call)
  |> should.equal(checker.ReturnedOperatorCall(QualifiedName("", "f")))
}

pub fn explain_reports_a_private_function_test() {
  // The walk is over source this module holds, so publicity decides nothing —
  // unlike an `effect` query, which answers from the public surface.
  let source =
    "import gleam/io
fn helper() -> Nil {
  io.println(\"x\")
}"
  let assert [explanation] = explain_source(source, "helper", [])
  explanation.actual |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn explain_replaces_a_local_call_with_its_own_sites_test() {
  // The helper's call surfaces at its own span; the call to the helper does not
  // appear as itself. A caller of a *pure* helper therefore has no contributors
  // at all, though it plainly makes a call.
  let source =
    "import gleam/io
pub fn run() -> Nil {
  noisy()
}

fn noisy() -> Nil {
  io.println(\"x\")
}

pub fn quiet() -> Nil {
  pure()
}

fn pure() -> Nil {
  Nil
}"
  let assert [explanation] = explain_source(source, "run", [])
  explanation.call |> should.equal(QualifiedName("gleam/io", "println"))
  explain_source(source, "quiet", []) |> should.equal([])
}

pub fn explain_bounds_resolve_a_parameter_call_test() {
  let source =
    "pub fn run(f: fn() -> Nil) -> Nil {
  f()
}"
  let assert [bounded] =
    explain_source(source, "run", [ParamBound("f", stdout_term())])
  bounded.actual |> should.equal(Specific(set.from_list(["Stdout"])))
  // A declared bound decides what the walk substitutes for the same call, which
  // is why `why` runs once per `check` line rather than picking one. Without
  // one the call still resolves — to the identity bound inference synthesises,
  // which says the effects are the argument's — rather than to `[Unknown]`.
  let assert [unbounded] = explain_source(source, "run", [])
  unbounded.actual
  |> should.equal(Polymorphic(set.new(), set.from_list(["f"])))
}

pub fn explain_misses_an_unknown_function_test() {
  let source = "pub fn run() -> Nil { Nil }"
  let assert Ok(module) = glance.module(source)
  explain_blocks(module, "absent", [[]], knowledge_base(), signatures.empty())
  |> should.equal(Error(Nil))
}

pub fn explain_agrees_with_the_violation_for_the_same_call_test() {
  // One vocabulary: the reason and origin `why` prints for a call are the ones
  // the violation carries, and both render to the same clause.
  let source =
    "
import validation
pub fn new() {
  validation.validate_range(42, to_error: 1 + 2)
}
"
  let assert Ok(module) = glance.module(source)
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [pure_check("new")],
      polymorphic_kb(),
      signatures.empty(),
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  let assert [violation] = violations
  let assert Ok([explanations]) =
    explain_blocks(module, "new", [[]], polymorphic_kb(), signatures.empty())
  let assert Ok(explanation) =
    list.find(explanations, fn(e) { e.call == violation.explanation.call })
  explanation.reason |> should.equal(violation.explanation.reason)
  explanation.origin |> should.equal(violation.explanation.origin)
  explanation.actual |> should.equal(violation.explanation.actual)
  string.contains(
    checker.format_violation("src/app.gleam", violation),
    checker.format_call_explanation(explanation),
  )
  |> should.be_true()
}

fn stdout_term() -> types.EffectTerm {
  effect_term.from_effect_set(Specific(set.from_list(["Stdout"])))
}

// A `where returns` clause, read back
//
// A clause loaded from a spec reaches the producer call as a `Closed` summary.
// The gate re-checks its variables against the producer's real callback
// parameters before binding them, so a clause naming a parameter binds
// precisely and one naming anything else degrades to `[Unknown]`.

// The knowledge base and registry for a cross-module producer `dep.wrap`,
// carrying whatever clause `spec_line` states for it.
fn closed_clause_setup(
  spec_line: String,
) -> #(effects.KnowledgeBase, signatures.SignatureRegistry) {
  let assert Ok(spec) = annotation.parse_file(spec_line)
  let dep_source =
    "pub fn wrap(f: fn() -> Nil) -> fn() -> Nil {
  fn() { f() }
}
"
  let assert Ok(dep_module) = glance.module(dep_source)
  let kb =
    knowledge_base()
    |> effects.with_inferred(
      dict.from_list([
        #(
          QualifiedName("dep", "wrap"),
          effect_term.from_effect_set(types.empty()),
        ),
      ]),
      types.ProjectInferred,
    )
    |> effects.with_closed_returned_operators(
      effects.load_spec_returns_from_file(spec),
      types.CommittedSpec,
    )
  #(kb, signatures.from_glance_module("dep", dep_module))
}

fn closed_clause_violations(spec_line: String) -> List(types.Violation) {
  let #(kb, dep_registry) = closed_clause_setup(spec_line)
  let source =
    "
import gleam/io
import dep
pub fn caller() -> Nil {
  let h = dep.wrap(noisy)
  h()
}
fn noisy() -> Nil {
  io.println(\"x\")
}
"
  let assert Ok(module) = glance.module(source)
  let registry =
    signatures.merge(signatures.from_glance_module("app", module), dep_registry)
  let #(violations, _findings, _) =
    checker.check(
      module,
      "",
      [pure_check("caller")],
      kb,
      registry,
      dict.new(),
      dict.new(),
      types.all_targets(),
    )
  violations
}

// What the call of the *returned* closure was charged. The producer call beside
// it is charged its own bound and is not what these tests are about.
fn returned_call_effects(spec_line: String) -> EffectSet {
  let assert Ok(violation) =
    closed_clause_violations(spec_line)
    |> list.find(fn(violation) {
      violation.explanation.call.module == "<returned>"
    })
  violation.explanation.actual
}

pub fn a_closed_clause_binds_the_producers_argument_test() {
  returned_call_effects("effects dep.wrap(f: [f]) : [] where returns : [f]")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn an_open_clause_degrades_to_unknown_test() {
  // `ghost` is no parameter of `dep.wrap`, so there is nothing to bind it to.
  returned_call_effects("effects dep.wrap(f: [f]) : [] where returns : [ghost]")
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

// A catalog-declared Gleam higher-order function on a value channel
//
// `gleam/list.map` is declared by a module-level catalog `assume`, and nothing
// anywhere states what its callback costs. A direct call reads the argument's
// shape at the call site and charges it there; a value channel has no such
// reading, so the declaration's silence about the callback is charged as the
// callback's own effect instead of vanishing.

fn list_value_channel_kb() -> effects.KnowledgeBase {
  knowledge_base()
  |> effects.with_callback_params(
    signatures.callback_param_names(list_registry()),
  )
}

// The inferred effects of one named function of `source`, analysed with
// `gleam/list`'s signature and its callback parameters both in reach.
fn list_value_channel_effects(source: String, function: String) -> EffectSet {
  let assert Ok(module) = glance.module(source)
  infer_annotation_with(
    module,
    function,
    list_value_channel_kb(),
    list_registry(),
  ).effects
  |> effect_term.to_effect_set
}

pub fn a_declared_map_passed_as_a_value_charges_its_callback_test() {
  // `list.map` handed to a helper that calls it. Its callback is *labelled*
  // (`with fun:`), so the binder has to be the in-body name the synthesized
  // variable carries: named after the label, the variable stays free, the
  // application goes stuck, and the precise `[Stdout]` collapses to
  // `[Unknown]`.
  let source =
    "
import gleam/io
import gleam/list

fn invoke(
  op: fn(List(String), fn(String) -> Nil) -> List(Nil),
  xs: List(String),
) -> List(Nil) {
  op(xs, io.println)
}

pub fn run(xs: List(String)) -> List(Nil) {
  invoke(list.map, xs)
}
"
  list_value_channel_effects(source, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn a_declared_map_wired_into_a_field_charges_its_callback_test() {
  // The same name wired into a record field and called through it.
  let source =
    "
import gleam/io
import gleam/list

pub type Mapper {
  Mapper(go: fn(List(String), fn(String) -> Nil) -> List(Nil))
}

fn make() -> Mapper {
  Mapper(go: list.map)
}

pub fn via_field(xs: List(String)) -> List(Nil) {
  let m = make()
  m.go(xs, io.println)
}
"
  list_value_channel_effects(source, "via_field")
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn a_declared_maps_direct_call_keeps_its_auto_bounds_test() {
  // The direct-call channel is untouched: a tracked reference still charges
  // its effect, and an inline closure — whose body the extractor walks
  // separately — still charges nothing, rather than the `[Unknown]` a
  // synthesized bound with nothing to bind would give.
  let tracked =
    "
import gleam/io
import gleam/list
pub fn run(xs: List(String)) -> List(Nil) {
  list.map(xs, io.println)
}
"
  list_value_channel_effects(tracked, "run")
  |> should.equal(Specific(set.from_list(["Stdout"])))
  let closure =
    "
import gleam/list
pub fn run(xs: List(Int)) -> List(Int) {
  list.map(xs, fn(x) { x + 1 })
}
"
  list_value_channel_effects(closure, "run") |> should.equal(types.empty())
}
