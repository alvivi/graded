import generators
import girard
import girard/types as girard_types
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
  ParamBound, Polymorphic, QualifiedName, Specific, TypeFieldEffect,
  UnmatchedFieldBoundWarning, UnmatchedParamBoundWarning, UntrackedEffectWarning,
  Wildcard,
}
import qcheck

fn knowledge_base() -> effects.KnowledgeBase {
  effects.empty_knowledge_base()
}

fn check_source(
  source: String,
  annotations: List(EffectAnnotation),
) -> List(types.Violation) {
  let assert Ok(module) = glance.module(source)
  let #(violations, _warnings) =
    checker.check(
      module,
      annotations,
      knowledge_base(),
      signatures.empty(),
      dict.new(),
      dict.new(),
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
      ),
    ])
  violations |> list.length() |> should.equal(1)
  let assert [violation] = violations
  violation.function |> should.equal("view")
  violation.call |> should.equal(QualifiedName("gleam/io", "println"))
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
      ),
    ])
  violations |> list.length() |> should.equal(1)
  let assert [violation] = violations
  violation.call |> should.equal(QualifiedName("gleam/io", "println"))
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
      ),
    ])
  violations
  |> list.any(fn(violation) { violation.call.function == "sleep" })
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
      ),
    ])
  // Should flag as Unknown effect
  { violations != [] } |> should.be_true()
  let assert [violation] = violations
  violation.call.function |> should.equal("missing")
}

// Infer

pub fn infer_pure_function_test() {
  let source =
    "import gleam/list
pub fn view(items) { list.map(items, fn(x) { x }) }"
  let assert Ok(module) = glance.module(source)
  let inferred =
    checker.infer(
      module,
      knowledge_base(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
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
      knowledge_base(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
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
      knowledge_base(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
    )
  let assert [annotation] = inferred
  annotation.function |> should.equal("view")
}

// Infer respects existing param bounds

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
    ),
  ]
  let inferred =
    checker.infer(
      module,
      knowledge_base(),
      existing_checks,
      signatures.empty(),
      dict.new(),
      dict.new(),
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
      knowledge_base(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
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
          girard_types.Fn(argument_types, _return) -> {
            let assert Ok(definition) =
              list.find(module.functions, fn(d) { d.definition.name == name })
            let names =
              list.zip(definition.definition.parameters, argument_types)
              |> list.filter_map(fn(pair) {
                case pair.1, { pair.0 }.name {
                  girard_types.Fn(_, _), glance.Named(parameter_name) ->
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
      knowledge_base(),
      [],
      signatures.empty(),
      dict.new(),
      girard_fn_typed_for(module),
    )
  let assert [annotation] = inferred
  effect_term.to_effect_set(annotation.effects)
  |> should.equal(Polymorphic(set.new(), set.from_list(["f"])))
}

// Higher-order / parameter bound tests

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
    ),
  ])
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Field call tests (Case 4)

fn check_source_with_type_fields(
  source: String,
  annotations: List(EffectAnnotation),
  type_fields: List(types.TypeFieldAnnotation),
) -> List(types.Violation) {
  let assert Ok(module) = glance.module(source)
  let kb = effects.with_type_fields(knowledge_base(), type_fields)
  let #(violations, _warnings) =
    checker.check(
      module,
      annotations,
      kb,
      signatures.empty(),
      dict.new(),
      dict.new(),
    )
  violations
}

// Typed param + registry entry → effects resolve correctly
pub fn field_call_typed_with_registry_test() {
  let source = "pub fn view(handler: Handler) { handler.on_click(event) }"
  let type_fields = [
    types.TypeFieldAnnotation(
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
    )
  check_source_with_type_fields(source, [annotation], type_fields)
  |> should.equal([])
}

// Stage A: type-directed receiver resolution via girard.
//
// Same as `check_source_with_type_fields`, but threads girard's real inferred
// types so the receiver's nominal type is known even when it isn't a directly
// annotated parameter.
fn check_source_with_girard(
  source: String,
  annotations: List(EffectAnnotation),
  type_fields: List(types.TypeFieldAnnotation),
) -> List(types.Violation) {
  let assert Ok(module) = glance.module(source)
  let module_types = case
    girard.annotate_module(module, girard.default_options())
  {
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
  let kb = effects.with_type_fields(knowledge_base(), type_fields)
  let #(violations, _warnings) =
    checker.check(
      module,
      annotations,
      kb,
      signatures.empty(),
      module_types,
      dict.new(),
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

fn validator_to_error_stdout() -> List(types.TypeFieldAnnotation) {
  [
    types.TypeFieldAnnotation(
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
    )
  let violations =
    check_source_with_girard(
      opaque_receiver_source,
      [annotation],
      validator_to_error_stdout(),
    )
  let assert [violation] = violations
  violation.actual |> should.equal(Specific(set.from_list(["Stdout"])))
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
    )
  check_source_with_girard(source, [annotation], validator_to_error_stdout())
  |> should.equal([])
}

pub fn field_call_girard_without_annotation_still_unknown_test() {
  // girard types the receiver, but no `type Validator.to_error` annotation
  // exists, so the effect is still [Unknown] — documents the A/C boundary:
  // Stage A needs the annotation for the effect; Stage C removes that need.
  let annotation =
    EffectAnnotation(
      Check,
      "run",
      [],
      effect_term.from_effect_set(Specific(set.new())),
    )
  let violations =
    check_source_with_girard(opaque_receiver_source, [annotation], [])
  let assert [violation] = violations
  violation.actual |> should.equal(Specific(set.from_list(["Unknown"])))
}

// Field effects exceed declared budget → violation
pub fn field_call_violates_check_test() {
  let source = "pub fn view(handler: Handler) { handler.on_click(event) }"
  let type_fields = [
    types.TypeFieldAnnotation(
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
    )
  check_source(source, [annotation])
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// External declaration tests

fn check_source_with_externals(
  source: String,
  annotations: List(EffectAnnotation),
  externals: List(types.ExternalAnnotation),
) -> List(types.Violation) {
  let assert Ok(module) = glance.module(source)
  let kb = effects.with_externals(knowledge_base(), externals)
  let #(violations, _warnings) =
    checker.check(
      module,
      annotations,
      kb,
      signatures.empty(),
      dict.new(),
      dict.new(),
    )
  violations
}

// External resolves instead of Unknown
pub fn external_resolves_effects_test() {
  let source =
    "import gleam/httpc
pub fn fetch() { httpc.send(request) }"
  let externals = [
    types.ExternalAnnotation(
      "gleam/httpc",
      types.FunctionExternal("send"),
      Specific(set.from_list(["Http"])),
    ),
  ]
  let annotation =
    EffectAnnotation(
      Check,
      "fetch",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Http"]))),
    )
  check_source_with_externals(source, [annotation], externals)
  |> should.equal([])
}

// External effect exceeds budget → violation
pub fn external_violates_check_test() {
  let source =
    "import gleam/httpc
pub fn fetch() { httpc.send(request) }"
  let externals = [
    types.ExternalAnnotation(
      "gleam/httpc",
      types.FunctionExternal("send"),
      Specific(set.from_list(["Http"])),
    ),
  ]
  let annotation =
    EffectAnnotation(
      Check,
      "fetch",
      [],
      effect_term.from_effect_set(Specific(set.new())),
    )
  check_source_with_externals(source, [annotation], externals)
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Wildcard [_] tests

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
    )
  check_source(source, [annotation])
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// ──── Function Reference Warnings ────

fn check_warnings(
  source: String,
  annotations: List(EffectAnnotation),
) -> List(types.Warning) {
  let assert Ok(module) = glance.module(source)
  let #(_violations, warnings) =
    checker.check(
      module,
      annotations,
      knowledge_base(),
      signatures.empty(),
      dict.new(),
      dict.new(),
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
      ),
    ])
  warnings |> list.length() |> should.equal(1)
  let assert [warning] = warnings
  let assert UnmatchedFieldBoundWarning(function:, field_path:) = warning
  function |> should.equal("caller")
  field_path |> should.equal("v.to_errorx")
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
  let source = "pub fn apply(f, x) { helper(f, x) }
pub fn helper(g, y) { g(y) }"
  check_warnings(source, [
    EffectAnnotation(
      Check,
      "apply",
      [ParamBound("f", effect_term.from_effect_set(Specific(set.new())))],
      effect_term.from_effect_set(Specific(set.new())),
    ),
  ])
  |> should.equal([])
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
    ),
  ])
  |> should.equal([])
}

// ──── Checker Soundness (property) ────

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
        effect_term.from_effect_set(types.from_labels([c.2])),
      )
    })
    |> dict.from_list()
  effects.KnowledgeBase(
    all_effects:,
    param_bounds: dict.new(),
    type_fields: dict.new(),
    returned_operators: dict.new(),
    factories: dict.new(),
    pure_modules: set.new(),
  )
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
        )
      let #(violations, _) =
        checker.check(
          module,
          [ann],
          kb,
          signatures.empty(),
          dict.new(),
          dict.new(),
        )
      violations |> should.equal([])
    }
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
        )
      let #(violations, _) =
        checker.check(
          module,
          [ann],
          kb,
          signatures.empty(),
          dict.new(),
          dict.new(),
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
            )
          let #(violations, _) =
            checker.check(
              module,
              [ann],
              kb,
              signatures.empty(),
              dict.new(),
              dict.new(),
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
        )
      let #(violations, _) =
        checker.check(
          module,
          [ann],
          kb,
          signatures.empty(),
          dict.new(),
          dict.new(),
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
          kb,
          [],
          signatures.empty(),
          dict.new(),
          dict.new(),
        )
      let assert [ann] = inferred
      ann.function |> should.equal("test_fn")
      effect_term.to_effect_set(ann.effects)
      |> should.equal(actual_effects(calls))
    }
  }
}

// ──── Cycle Detection (property) ────

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
  effects.KnowledgeBase(
    all_effects: dict.new(),
    param_bounds: dict.new(),
    type_fields: dict.new(),
    returned_operators: dict.new(),
    factories: dict.new(),
    pure_modules: set.new(),
  )
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
          bare_knowledge_base(),
          [],
          signatures.empty(),
          dict.new(),
          dict.new(),
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
        )
      let #(violations, _) =
        checker.check(
          module,
          [ann],
          bare_knowledge_base(),
          signatures.empty(),
          dict.new(),
          dict.new(),
        )
      violations |> should.equal([])
    }
  }
}

// ──── Polymorphic auto-inference ────

fn infer_single(source: String) -> EffectAnnotation {
  let assert Ok(module) = glance.module(source)
  let assert [ann] =
    checker.infer(
      module,
      knowledge_base(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
    )
  ann
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
    )
  let assert [ann] =
    checker.infer(
      module,
      knowledge_base(),
      [existing],
      signatures.empty(),
      dict.new(),
      dict.new(),
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

// ──── Call-site substitution ────

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
  let #(violations, _) =
    checker.check(
      module,
      [
        EffectAnnotation(
          Check,
          "new",
          [],
          effect_term.from_effect_set(Specific(set.new())),
        ),
      ],
      polymorphic_kb(),
      signatures.empty(),
      dict.new(),
      dict.new(),
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
  let #(violations, _) =
    checker.check(
      module,
      [
        EffectAnnotation(
          Check,
          "new",
          [],
          effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
        ),
      ],
      polymorphic_kb(),
      signatures.empty(),
      dict.new(),
      dict.new(),
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
  let #(violations, _) =
    checker.check(
      module,
      [
        EffectAnnotation(
          Check,
          "new",
          [],
          effect_term.from_effect_set(Specific(set.new())),
        ),
      ],
      polymorphic_kb(),
      signatures.empty(),
      dict.new(),
      dict.new(),
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
      polymorphic_kb(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
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
      polymorphic_kb(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
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
      knowledge_base(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
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
      two_callback_kb(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
    )
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Specific(set.from_list(["Http", "Stdout"])))
}

// ──── Two-hop effect unification ────

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
      knowledge_base(),
      [],
      list_registry(),
      dict.new(),
      dict.new(),
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
  let #(violations, _) =
    checker.check(
      module,
      [EffectAnnotation(Check, "run", [], effect_term.from_effect_set(budget))],
      kb,
      reg,
      dict.new(),
      dict.new(),
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
  v.actual |> should.equal(Specific(set.from_list(["Stdout"])))
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
    )
  let source =
    "
import helpers
pub fn run(h: fn(Int) -> Int, x: Int) -> Int {
  helpers.do_both(h, fn(y) { y + 1 }, x)
}
"
  let assert Ok(module) = glance.module(source)
  let assert [ann] = checker.infer(module, kb, [], reg, dict.new(), dict.new())
  ann.function |> should.equal("run")
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Polymorphic(set.new(), set.from_list(["h"])))
}

// ──── Polymorphic field-call substitution (review issue #8) ────

// A KB whose `Task.go` field is wired to a polymorphic function `helper.run_it`
// (effect variable `action`), plus a registry giving run_it's parameter
// positions so the field call's arguments bind that variable.
fn polymorphic_field_kb_and_registry() -> #(
  effects.KnowledgeBase,
  signatures.SignatureRegistry,
) {
  let action_var =
    effect_term.from_effect_set(Polymorphic(
      set.new(),
      set.from_list(["action"]),
    ))
  let kb =
    effects.with_inferred_type_fields(knowledge_base(), [
      #(
        #("", "Task", "go"),
        TypeFieldEffect(
          effects: action_var,
          bounds: [ParamBound("action", action_var)],
          source: Some(QualifiedName("helper", "run_it")),
        ),
      ),
    ])
  let run_it_src =
    "pub fn run_it(action: fn(String) -> Nil, msg: String) -> Nil { action(msg) }"
  let assert Ok(run_it_module) = glance.module(run_it_src)
  let registry = signatures.from_glance_module("helper", run_it_module)
  #(kb, registry)
}

fn check_field_call(arg: String) -> List(types.Violation) {
  let #(kb, registry) = polymorphic_field_kb_and_registry()
  let source = "
import gleam/io
pub fn main(t: Task, msg: String) {
  t.go(" <> arg <> ", msg)
}
"
  let assert Ok(module) = glance.module(source)
  let #(violations, _warnings) =
    checker.check(
      module,
      [
        EffectAnnotation(
          Check,
          "main",
          [],
          effect_term.from_effect_set(Specific(set.new())),
        ),
      ],
      kb,
      registry,
      dict.new(),
      dict.new(),
    )
  violations
}

pub fn field_call_binds_effectful_argument_test() {
  // t.go(io.println, msg): the field's `action` variable binds to io.println's
  // [Stdout], so the [] budget fails with the precise [Stdout] — not a leaked
  // free variable.
  let assert [v, ..] = check_field_call("io.println")
  v.function |> should.equal("main")
  v.actual |> should.equal(Specific(set.from_list(["Stdout"])))
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
  v.actual |> should.equal(Specific(set.from_list(["Stdout"])))
}

// ──── B1: factory field provenance ────

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
    )
    |> effects.with_factories(
      dict.from_list([
        #(#("dep", "make"), dict.from_list([#("to_error", 0)])),
      ]),
    )
  let registry = signatures.from_glance_module("app", module)
  let pass =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
    )
  let #(violations, _) =
    checker.check(module, [pass], kb, registry, dict.new(), dict.new())
  violations |> should.equal([])
  let fail =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(types.empty()),
    )
  let #(failed, _) =
    checker.check(module, [fail], kb, registry, dict.new(), dict.new())
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

// ──── Second-order (nested) effect variables: end-to-end ────

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
    )
  let #(violations, _) =
    checker.check(module, [ann], kb, reg, dict.new(), dict.new())
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
    )
  let #(violations, _) =
    checker.check(module, [ann], kb, reg, dict.new(), dict.new())
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
    )
  let #(violations, _) =
    checker.check(module, [ann], kb, reg, dict.new(), dict.new())
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
  let kb = effects.with_externals(knowledge_base(), [fs_read_external()])
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
    checker.infer(module, kb, [], signatures.empty(), dict.new(), dict.new())
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
  let kb = effects.with_externals(knowledge_base(), [fs_read_external()])
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
    checker.infer(module, kb, [], signatures.empty(), dict.new(), dict.new())
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
    )
    |> effects.with_inferred_returned_operators(
      dict.from_list([
        #(QualifiedName("dep", "pick"), types.TAbs("cb", types.TVar("cb"))),
      ]),
    )
  let registry = signatures.from_glance_module("app", module)
  let pass =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
    )
  let #(violations, _) =
    checker.check(module, [pass], kb, registry, dict.new(), dict.new())
  violations |> should.equal([])
  let fail =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(types.empty()),
    )
  let #(fail_violations, _) =
    checker.check(module, [fail], kb, registry, dict.new(), dict.new())
  { fail_violations != [] } |> should.be_true()
}

pub fn second_order_returned_function_from_spec_test() {
  // A `returns` line in the spec (as `infer` writes it) lets `check` resolve a
  // cross-module producer — exercising the parse + load path, not a hand-built
  // KB.
  let assert Ok(spec) =
    annotation.parse_file("returns dep.pick : fn(cb) -> [cb]")
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
    )
    |> effects.with_inferred_returned_operators(
      effects.load_spec_returns_from_file(spec),
    )
  let registry = signatures.from_glance_module("app", module)
  let pass =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
    )
  let #(violations, _) =
    checker.check(module, [pass], kb, registry, dict.new(), dict.new())
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
  let #(_annotations, returns) =
    checker.infer_with_returns(
      module,
      knowledge_base(),
      [],
      signatures.from_glance_module("app", module),
      dict.new(),
      dict.new(),
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
  let #(_annotations, returns) =
    checker.infer_with_returns(
      module,
      knowledge_base(),
      [],
      signatures.from_glance_module("app", module),
      dict.new(),
      dict.new(),
    )
  let assert Ok(operator) = dict.get(returns, "make_printer")
  operator
  |> should.equal(
    effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
  )
  // Round-trips through `format_returns` / parse (a plain effect term).
  let line =
    annotation.format_returns(types.ReturnsAnnotation("make_printer", operator))
  let assert Ok(spec) = annotation.parse_file(line)
  let assert [reparsed] = annotation.extract_returns(spec)
  effect_term.normalize(reparsed.operator)
  |> should.equal(effect_term.normalize(operator))
}

pub fn first_order_returned_function_from_spec_test() {
  // C2 cross-module: a `returns dep.make : [Stdout]` spec line (as `infer`
  // writes it) lets `let f = dep.make(); f()` resolve in a downstream module.
  let assert Ok(spec) = annotation.parse_file("returns dep.make : [Stdout]")
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
    )
    |> effects.with_inferred_returned_operators(
      effects.load_spec_returns_from_file(spec),
    )
  let registry = signatures.from_glance_module("app", module)
  let pass =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
    )
  let #(violations, _) =
    checker.check(module, [pass], kb, registry, dict.new(), dict.new())
  violations |> should.equal([])
  let fail =
    EffectAnnotation(
      Check,
      "caller",
      [],
      effect_term.from_effect_set(types.empty()),
    )
  let #(failed, _) =
    checker.check(module, [fail], kb, registry, dict.new(), dict.new())
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
  let #(_annotations, returns) =
    checker.infer_with_returns(
      module,
      knowledge_base(),
      [],
      signatures.from_glance_module("app", module),
      dict.new(),
      dict.new(),
    )
  let assert Ok(operator) = dict.get(returns, "pick")
  operator
  |> should.equal(types.TUnion([types.TVar("a"), types.TVar("b")]))
  // Round-trips through `format_returns` / parse.
  let line =
    annotation.format_returns(types.ReturnsAnnotation("pick", operator))
  let assert Ok(spec) = annotation.parse_file(line)
  let assert [reparsed] = annotation.extract_returns(spec)
  effect_term.normalize(reparsed.operator)
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

// A `fs.read : [FileSystem]` external for second-order operator tests.
fn fs_read_external() -> types.ExternalAnnotation {
  types.ExternalAnnotation(
    "fs",
    types.FunctionExternal("read"),
    Specific(set.from_list(["FileSystem"])),
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
  let kb = effects.with_externals(knowledge_base(), [fs_read_external()])
  let registry = signatures.from_glance_module("app", module)
  let ann =
    EffectAnnotation(
      Check,
      function,
      [],
      effect_term.from_effect_set(Specific(set.from_list(budget))),
    )
  let #(violations, _) =
    checker.check(module, [ann], kb, registry, dict.new(), dict.new())
  violations
}

// ----- collapse classification is girard-independent (determinism) -----

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
  let cache = checker.build_scc_ids(module, context, dict.new(), True)

  // `apply` takes an alias-typed function parameter — excluded from collapse
  // even with no girard input.
  let assert Ok(apply_scc) = dict.get(cache.scc_id, "apply")
  set.contains(cache.collapsible, apply_scc) |> should.be_false()

  // `plain` is genuinely first-order — still collapsible.
  let assert Ok(plain_scc) = dict.get(cache.scc_id, "plain")
  set.contains(cache.collapsible, plain_scc) |> should.be_true()
}
