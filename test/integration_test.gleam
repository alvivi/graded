import glance
import gleam/dict
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import gleeunit/should
import graded
import graded/internal/annotation
import graded/internal/checker
import graded/internal/effect_term
import graded/internal/effects
import graded/internal/signatures
import graded/internal/types
import simplifile

pub fn pure_view_passes_test() {
  let assert Ok(results) = graded.run("test/fixtures")
  let pure_result =
    list.find(results, fn(r) { r.file == "test/fixtures/pure_view.gleam" })
  let assert Ok(r) = pure_result
  r.violations |> should.equal([])
}

pub fn let_bound_view_passes_test() {
  // The MVU idiom: a let-bound element builder (`let row = fn(item) { ... }`)
  // mapped over a list. The view is pure, so the `check view : []` invariant
  // must pass — the let-bound closure resolves to its body effect, not
  // `[Unknown]`.
  let assert Ok(results) = graded.run("test/fixtures")
  let result =
    list.find(results, fn(r) { r.file == "test/fixtures/let_bound_view.gleam" })
  let assert Ok(r) = result
  r.violations |> should.equal([])
}

pub fn recursive_fn_arg_resolves_pure_test() {
  // A self-recursive function passed by name to a higher-order call
  // (`list.flat_map(children, walk)`) must resolve to its real (pure) effect,
  // not [Unknown]: the recursive reference is already on the analysis stack, so
  // it contributes nothing rather than collapsing the result. With girard type
  // info active (as here), the operator-lift path reaches the recursive
  // reference; before the fix it leaked a phantom variable that became
  // [Unknown], failing the `check walk : []` budget.
  let assert Ok(results) = graded.run("test/fixtures")
  let result =
    list.find(results, fn(r) {
      r.file == "test/fixtures/recursive_fn_arg.gleam"
    })
  let assert Ok(r) = result
  r.violations |> should.equal([])
}

pub fn recursive_returned_operator_resolves_pure_test() {
  // A same-module recursive producer whose recursive branch returns a recursive
  // producer call (`pick(n - 1)`). Applying the operator it returns must treat
  // that branch as neutral, not [Unknown]: the producer is already on the
  // returned-operator analysis stack, so it contributes no effect — matching
  // `X = [] union X`, whose least solution is `[]`. Before the fix `run` failed
  // the `check run : []` budget with `<returned>.pick : [Unknown]`.
  //
  // Covers both the first-order producer (`pick`/`run`, returning `fn() -> Nil`)
  // and the second-order one (`pick_cb`/`run_cb`, returning a callback-taking
  // `fn(fn() -> Nil) -> Nil`) — the latter exercises the neutral operator's
  // binder over the callback position rather than a ground pure.
  let assert Ok(results) = graded.run("test/fixtures")
  let result =
    list.find(results, fn(r) {
      r.file == "test/fixtures/recursive_returned_operator.gleam"
    })
  let assert Ok(r) = result
  r.violations |> should.equal([])
}

pub fn impure_view_fails_test() {
  let assert Ok(results) = graded.run("test/fixtures")
  let impure_result =
    list.find(results, fn(r) { r.file == "test/fixtures/impure_view.gleam" })
  let assert Ok(r) = impure_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("view")
  v.call.function |> should.equal("println")
}

pub fn transitive_violation_detected_test() {
  let assert Ok(results) = graded.run("test/fixtures")
  let trans_result =
    list.find(results, fn(r) { r.file == "test/fixtures/transitive.gleam" })
  let assert Ok(r) = trans_result
  { r.violations != [] } |> should.be_true()
}

pub fn validator_flow_violation_detected_test() {
  // validator_flow.run constructs a Validator locally and calls its
  // field. The field is wired to io.println so the run function's
  // effects are [Stdout] — the check budget of [] must fail.
  let assert Ok(results) = graded.run("test/fixtures")
  let validator_result =
    list.find(results, fn(r) { r.file == "test/fixtures/validator_flow.gleam" })
  let assert Ok(r) = validator_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.call.function |> should.equal("println")
}

pub fn factory_field_violation_detected_test() {
  // factory_field.run binds its Validator from make(io.println), a *factory*
  // that wires the field to its parameter. With no `type` annotation, factory
  // field provenance resolves v.to_error to io.println's [Stdout], so the []
  // check budget must fail. (B1: the escape-hatch annotation is unnecessary.)
  let assert Ok(results) = graded.run("test/fixtures")
  let factory_result =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_field.gleam" })
  let assert Ok(r) = factory_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.call.function |> should.equal("println")
}

pub fn inline_construction_field_resolves_through_construction_test() {
  // inline_construction_field.run calls a function-typed field directly on an
  // *inline, un-let-bound* construction: `Validator(to_error: io.println)
  // .to_error("oops")`. The field is wired to io.println right at the
  // construction, so resolving the field call through the receiver's type and
  // construction provenance yields the precise [Stdout] — not the conservative
  // [Unknown] of an untraceable receiver. Reporting it as [] would be unsound,
  // so the [] budget must still fail, now with actual [Stdout].
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/inline_construction_field.gleam"
    })
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn field_union_operator_reduces_test() {
  // field_union.run calls a function-typed field built at two *distinct*
  // construction sites (pure + printing), so the field's inferred effect is a
  // *union* of operators (`λ_. [] ⊔ λ_. [Stdout]`). Calling it with a
  // non-function argument must apply and β-reduce that union to the precise
  // [Stdout] — not leak the raw operator bounds into run's effect set, which
  // would ground to [Unknown]. Regression for the union-of-operators field-call
  // leak surfaced across the parser-combinator idiom (atto, bitty, automata).
  let assert Ok(results) = graded.run("test/fixtures")
  let union_result =
    list.find(results, fn(r) { r.file == "test/fixtures/field_union.gleam" })
  let assert Ok(r) = union_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn external_is_unknown_test() {
  // A bodyless `@external` (opaque FFI) is inferred `[Unknown]`, not `[]`, and
  // `run` — which calls it — inherits that. Against a `[]` budget this must be a
  // violation with actual `[Unknown]`. Without the fix the FFI (and its caller)
  // would be `[]` and the check would pass — a soundness hole.
  let assert Ok(results) = graded.run("test/fixtures")
  let ffi_result =
    list.find(results, fn(r) { r.file == "test/fixtures/ffi_external.gleam" })
  let assert Ok(r) = ffi_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.actual |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn external_same_module_declared_effects_test() {
  // A same-module (unqualified) call into a bodyless `@external` that carries an
  // `external effects` declaration inherits the DECLARED effects, not the
  // `[Unknown]` an undeclared external yields. `read_clock` calls `now()` bare,
  // so against a `[]` budget the actual must be the declared `[Time]`. Without
  // the fix the local path bypassed the knowledge base and reported `[Unknown]`.
  let assert Ok(results) = graded.run("test/fixtures")
  let same_module_result =
    list.find(results, fn(r) {
      r.file == "test/fixtures/external_same_module.gleam"
    })
  let assert Ok(r) = same_module_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("read_clock")
  v.actual |> should.equal(types.Specific(set.from_list(["Time"])))
}

pub fn opaque_receiver_violation_detected_test() {
  // opaque_receiver.run binds its Validator from make() — a *cross-function*
  // construction the syntax-level path can't see. girard types the receiver,
  // and the `type opaque_receiver.Validator.to_error : [Stdout]` annotation
  // resolves the field call, so the [] check budget must fail. This is the
  // milestone-3b case that 0.6.0's same-function value flow could not handle.
  let assert Ok(results) = graded.run("test/fixtures")
  let opaque_result =
    list.find(results, fn(r) { r.file == "test/fixtures/opaque_receiver.gleam" })
  let assert Ok(r) = opaque_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  // Crucially the effect is the precise [Stdout] (resolved via the type
  // annotation), not the [Unknown] graded would fall back to without girard.
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn field_bound_resolves_untraceable_receiver_test() {
  // field_bound.caller calls `v.to_error` where `v` arrives as a parameter —
  // no construction site, no `type` line. The hand-written field bound on the
  // `check field_bound.caller(v.to_error: [Stdout]) : []` line resolves the
  // field call to [Stdout], so the [] budget must fail with that precise
  // effect (not the [Unknown] graded would otherwise fall back to).
  let assert Ok(results) = graded.run("test/fixtures")
  let field_bound_result =
    list.find(results, fn(r) { r.file == "test/fixtures/field_bound.gleam" })
  let assert Ok(r) = field_bound_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("caller")
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn opaque_fn_typed_field_discharges_via_bound_test() {
  // opaque_field.exec calls `r.run` where `r` is an opaque parameter — no
  // construction site, no `type` line. `run` is a `fn`-typed field, so the call
  // becomes a synthetic field-effect variable rather than [Unknown]. The
  // `check opaque_field.exec(r.run: [Stdout]) : []` field bound discharges that
  // variable to [Stdout], so the [] budget must fail with the precise [Stdout].
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/opaque_field.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "exec" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn opaque_fn_typed_field_unbound_is_unknown_test() {
  // opaque_field.exec_unbound makes the same opaque `fn`-typed field call with
  // NO field bound. The synthetic `r.run` variable can't be discharged, so it
  // concretizes to [Unknown] — the soundness floor — and the [] budget fails
  // with [Unknown], never silently []. This is the invariant the polymorphic
  // field-bound feature must never violate.
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/opaque_field.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "exec_unbound" })
  v.actual |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn opaque_fn_typed_field_round_trips_as_field_bound_test() {
  // Inferring opaque_field.exec surfaces the synthetic field-effect variable as
  // a polymorphic *field bound* on the function's signature — the field-bound
  // analog of the parameter bounds a fn-typed parameter produces. The inferred
  // `effects` line carries a `r.run`-keyed bound whose effect is the `[r.run]`
  // variable, so the polymorphic signature round-trips through the spec file.
  let assert Ok(results) = checker_infer_opaque_field()
  let assert Ok(annotation) = list.find(results, fn(a) { a.function == "exec" })
  let assert Ok(bound) =
    list.find(annotation.params, fn(b) { b.name == "r.run" })
  bound.effects |> should.equal(types.TVar("r.run"))
  annotation.effects |> should.equal(types.TVar("r.run"))
}

// Infer the opaque_field fixture module in isolation and return its public
// annotations, so the round-trip test can inspect the surfaced field bound
// without round-tripping the whole spec file.
fn checker_infer_opaque_field() -> Result(List(types.EffectAnnotation), Nil) {
  use source <- result.try(
    simplifile.read("test/fixtures/opaque_field.gleam")
    |> result.replace_error(Nil),
  )
  use module <- result.try(glance.module(source) |> result.replace_error(Nil))
  Ok(checker.infer(
    module,
    "opaque_field",
    effects.empty_knowledge_base(),
    [],
    signatures.empty(),
    dict.new(),
    dict.new(),
  ))
}

pub fn factory_forward_resolves_through_factory_test() {
  // factory_forward.caller calls `inner(make_options(resolver))`: the factory
  // result is built inline, so its `resolver` field wiring forwards inner's
  // `options.resolver` field-effect variable onto the caller's own `resolver`
  // parameter. The `check ...caller(resolver: [Stdout]) : []` bound discharges
  // it to [Stdout], so the [] budget fails with the precise effect — not the
  // [Unknown] an untraced factory return would collapse to.
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn factory_forward_resolves_through_inline_constructor_test() {
  // Same forwarding for an inline *constructor* argument
  // (`inner(Options(resolver: resolver))`).
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_ctor" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn factory_forward_resolves_through_labeled_factory_test() {
  // Labeled factory wiring (`inner(make_options(resolver: resolver))`) routes
  // through the factory's parameter label to the same field, so it forwards too.
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_labeled" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn factory_forward_resolves_through_shorthand_factory_test() {
  // Shorthand labeled wiring (`make_options(resolver:)`) is sugar for
  // `make_options(resolver: resolver)`, so its value is the `resolver` variable
  // and it forwards the same way — not the [Unknown] an opaque shorthand gives.
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_shorthand" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn factory_forward_marker_survives_sibling_source_test() {
  // factory_forward.mixed_caller forwards through `make_runner(run)` while the
  // same `Runner.run` field also has a polymorphic source from `relay_runner`
  // (`Runner(run: relay)`). The merged field keeps `source: Some`, so the bare
  // factory marker must resolve alongside it rather than being regrounded by the
  // sibling source. The two sites contribute independently: the factory marker
  // forwards onto the caller's `run` parameter and the `run: [Stdout]` bound
  // discharges it to [Stdout], while the polymorphic source's variable is
  // unbound at this call and concretizes to [Unknown]. Both are present —
  // before, the source regrounded the marker and the result was only [Unknown],
  // dropping the forwarded [Stdout].
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "mixed_caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout", "Unknown"])))
}

pub fn factory_forward_resolves_through_factory_alias_test() {
  // factory_forward.caller_alias binds the factory result to a `let` before
  // passing it (`let o = make_options(resolver); inner(o)`). The alias preserves
  // the constructed field wiring, so `o.resolver` re-keys onto the caller's
  // `resolver` parameter and the `resolver: [Stdout]` bound discharges it — the
  // [] budget fails with [Stdout], not the [Unknown] an opaque alias gave before.
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_alias" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn factory_forward_resolves_through_constructor_alias_test() {
  // factory_forward.caller_ctor_alias binds an inline constructor before passing
  // it (`let o = Options(resolver: resolver); inner(o)`). The constructor wiring
  // forwards the same way, so the bound discharges to [Stdout].
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_ctor_alias" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn factory_forward_resolves_through_nested_construction_test() {
  // factory_forward.caller_nested wires `resolver` two construction levels deep
  // (`inner_holder(make_holder(make_options(resolver)))`). Each hop's field
  // wiring is traced in turn, so `holder.options.resolver` re-keys onto the
  // caller's `resolver` and the bound discharges to [Stdout].
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_nested" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn factory_forward_computed_alias_stays_unknown_test() {
  // factory_forward.caller_computed_alias binds a computed receiver
  // (`let o = get_options(make_options(resolver)); inner(o)`). The binding is an
  // opaque call result, not a traceable construction, so forwarding doesn't
  // apply and the field call concretizes to [Unknown].
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_computed_alias" })
  v.actual |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn factory_forward_shadowed_alias_stays_unknown_test() {
  // factory_forward.caller_shadow rebinds a traceable factory alias to a computed
  // value before forwarding (`let o = make_options(resolver); let o =
  // get_options(o); inner(o)`). The shadowing binding clears the stale factory
  // provenance, so the field call concretizes to [Unknown] — proving a
  // reassignment can never leave a forwarded effect understated.
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_shadow" })
  v.actual |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn factory_forward_computed_receiver_resolves_test() {
  // factory_forward.caller_computed threads the factory result through a
  // passthrough helper (`inner(get_options(make_options(resolver)))`).
  // `get_options` returns its parameter, so return-value provenance forwards the
  // factory-wired `resolver` onto the caller's `resolver` and the bound
  // discharges it to [Stdout] — where before Phase 1 it collapsed to [Unknown].
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_computed" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn factory_forward_round_trips_as_param_bound_test() {
  // Inferring factory_forward.caller surfaces the forwarded field effect as a
  // polymorphic *parameter* bound on `resolver` (the factory field is wired to a
  // bare fn-typed parameter, so the dotted callee var re-keys to the plain
  // param var). The function effect and the bound are both `[resolver]`, so the
  // polymorphic signature round-trips.
  let assert Ok(results) = checker_infer_factory_forward()
  let assert Ok(annotation) =
    list.find(results, fn(a) { a.function == "caller" })
  let assert Ok(bound) =
    list.find(annotation.params, fn(b) { b.name == "resolver" })
  bound.effects |> should.equal(types.TVar("resolver"))
  annotation.effects |> should.equal(types.TVar("resolver"))
}

// Infer the factory_forward fixture module in isolation, with a registry built
// from its own signatures so the factory/receiver-parameter positions resolve.
fn checker_infer_factory_forward() -> Result(List(types.EffectAnnotation), Nil) {
  use source <- result.try(
    simplifile.read("test/fixtures/factory_forward.gleam")
    |> result.replace_error(Nil),
  )
  use module <- result.try(glance.module(source) |> result.replace_error(Nil))
  Ok(checker.infer(
    module,
    "factory_forward",
    effects.empty_knowledge_base(),
    [],
    signatures.from_glance_module("factory_forward", module),
    dict.new(),
    dict.new(),
  ))
}

pub fn nested_field_resolves_via_type_line_test() {
  // nested_field.via_type calls `o.inner.run()` — a NESTED field call whose
  // receiver `o.inner` is itself a field access, not a bare variable. girard
  // types the `o.inner` span as `Inner`, so the `type nested_field.Inner.run :
  // [Disk]` line resolves it, and the [] budget fails with the precise [Disk].
  // Before nested extraction this collapsed to <apply>.<unknown> ([Unknown]).
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/nested_field.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "via_type" })
  v.actual |> should.equal(types.Specific(set.from_list(["Disk"])))
}

pub fn nested_field_discharges_via_dotted_bound_test() {
  // nested_field.via_bound has a dotted field bound on its `check` line
  // (`check nested_field.via_bound(o.inner.run: [Stdout]) : []`). The nested
  // `o.inner.run` field call carries the dotted path `o.inner` as its object, so
  // the bound matches and discharges to [Stdout], winning over the `type` line.
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/nested_field.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "via_bound" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn nested_field_unbound_is_unknown_test() {
  // nested_field.unbound calls `h.loose.act()` — a nested fn-typed field with no
  // `type` line and no field bound. The synthetic field-effect variable can't be
  // discharged, so it concretizes to [Unknown] — the soundness floor — and the
  // [] budget fails with [Unknown], never silently [].
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/nested_field.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "unbound" })
  v.actual |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

// Materialise a single-package project named `proj` under `root` from `files`
// (each `#(relative_path, contents)` under the project root), run `graded
// infer`, and return the inferred public-API annotations parsed back from the
// spec file. `root` lives under the gitignored `build/`; it is cleared first.
fn infer_project(
  root: String,
  files: List(#(String, String)),
) -> List(types.EffectAnnotation) {
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(root <> "/gleam.toml", "name = \"proj\"\n")
  list.each(files, fn(file) {
    let #(path, contents) = file
    let assert Ok(Nil) = simplifile.write(root <> "/" <> path, contents)
    Nil
  })
  let assert Ok(Nil) = simplifile.write(root <> "/proj.graded", "")
  let assert Ok(Nil) = graded.run_infer(root)
  let assert Ok(content) = simplifile.read(root <> "/proj.graded")
  let assert Ok(file) = annotation.parse_file(content)
  annotation.extract_annotations(file)
}

fn field_forwarding_source() -> String {
  "pub type Options {\n"
  <> "  Options(resolver: fn() -> Nil)\n"
  <> "}\n\n"
  <> "pub type Inner {\n"
  <> "  Inner(run: fn() -> Nil)\n"
  <> "}\n\n"
  <> "pub type Outer {\n"
  <> "  Outer(inner: Inner)\n"
  <> "}\n\n"
  <> "pub fn direct(options: Options) -> Nil {\n"
  <> "  options.resolver()\n"
  <> "}\n\n"
  <> "pub fn inner(options: Options) -> Nil {\n"
  <> "  options.resolver()\n"
  <> "}\n\n"
  <> "pub fn one_hop(options: Options) -> Nil {\n"
  <> "  inner(options)\n"
  <> "}\n\n"
  <> "pub fn two_hop(options: Options) -> Nil {\n"
  <> "  one_hop(options)\n"
  <> "}\n\n"
  <> "pub fn recursive(options: Options) -> Nil {\n"
  <> "  inner(options)\n"
  <> "  recursive(options)\n"
  <> "}\n\n"
  <> "pub fn nested_inner(o: Outer) -> Nil {\n"
  <> "  o.inner.run()\n"
  <> "}\n\n"
  <> "pub fn nested_forward(x: Outer) -> Nil {\n"
  <> "  nested_inner(x)\n"
  <> "}\n"
}

fn run_project_with_spec(
  root: String,
  source: String,
  spec: String,
) -> List(types.CheckResult) {
  write_project(root, [#("proj.gleam", source)], spec)
  let assert Ok(results) = graded.run(root)
  results
}

fn expect_field_bound(
  annotations: List(types.EffectAnnotation),
  function: String,
  field_path: String,
) {
  let assert Ok(annotation) =
    list.find(annotations, fn(a) { a.function == function })
  let assert Ok(bound) =
    list.find(annotation.params, fn(b) { b.name == field_path })
  bound.effects |> should.equal(types.TVar(field_path))
  annotation.effects |> should.equal(types.TVar(field_path))
}

pub fn field_effect_forwarding_infers_direct_and_hops_test() {
  let annotations =
    infer_project("build/field_forwarding_app", [
      #("proj.gleam", field_forwarding_source()),
    ])

  expect_field_bound(annotations, "proj.direct", "options.resolver")
  expect_field_bound(annotations, "proj.inner", "options.resolver")
  expect_field_bound(annotations, "proj.one_hop", "options.resolver")
  expect_field_bound(annotations, "proj.two_hop", "options.resolver")
  expect_field_bound(annotations, "proj.recursive", "options.resolver")
  expect_field_bound(annotations, "proj.nested_forward", "x.inner.run")
}

pub fn field_effect_forwarding_unbound_check_stays_unknown_test() {
  let root = "build/field_forwarding_unbound_check"
  let results =
    run_project_with_spec(
      root,
      field_forwarding_source(),
      "check proj.one_hop : []\n",
    )
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/proj.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "one_hop" })
  v.actual |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn field_effect_forwarding_bound_check_uses_forwarded_bound_test() {
  let root = "build/field_forwarding_bound_check"
  let results =
    run_project_with_spec(
      root,
      field_forwarding_source(),
      "check proj.one_hop(options.resolver: [Stdout]) : []\n",
    )
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/proj.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "one_hop" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_cross_module_getter_resolves_test() {
  // A public getter in another module. `app.caller` calls
  // `dep.inner(dep.get_options(config))`; `get_options` returns `config.options`,
  // and its return provenance is threaded through the knowledge base by
  // topological order, so the computed receiver forwards cross-module onto
  // `config.options.resolver` and the field bound discharges it to [Stdout].
  let root = "build/provenance_cross_module"
  write_project(
    root,
    [
      #(
        "dep.gleam",
        "pub type Options {\n  Options(resolver: fn() -> Nil)\n}\n\n"
          <> "pub type Config {\n  Config(options: Options)\n}\n\n"
          <> "pub fn inner(o: Options) -> Nil {\n  o.resolver()\n}\n\n"
          <> "pub fn get_options(config: Config) -> Options {\n  config.options\n}\n",
      ),
      #(
        "app.gleam",
        "import dep\n\n"
          <> "pub fn caller(config: dep.Config) -> Nil {\n"
          <> "  dep.inner(dep.get_options(config))\n"
          <> "}\n",
      ),
    ],
    "check app.caller(config.options.resolver: [Stdout]) : []\n",
  )
  let assert Ok(results) = graded.run(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_cross_module_getter_over_construction_resolves_test() {
  // Same cross-module getter, but the receiver is built inline from the caller's
  // own `resolver` parameter before the getter runs: `dep.inner(dep.get_options(
  // dep.Config(options: dep.Options(resolver: resolver))))`. The getter's `Path`
  // provenance threads through the knowledge base and the field bound re-keys
  // onto the bare `resolver` through the construction, discharging to [Stdout]
  // — the construction-through-getter twin of the passthrough case above.
  let root = "build/provenance_cross_module_construct"
  write_project(
    root,
    [
      #(
        "dep.gleam",
        "pub type Options {\n  Options(resolver: fn() -> Nil)\n}\n\n"
          <> "pub type Config {\n  Config(options: Options)\n}\n\n"
          <> "pub fn inner(o: Options) -> Nil {\n  o.resolver()\n}\n\n"
          <> "pub fn get_options(config: Config) -> Options {\n  config.options\n}\n",
      ),
      #(
        "app.gleam",
        "import dep\n\n"
          <> "pub fn caller(resolver: fn() -> Nil) -> Nil {\n"
          <> "  dep.inner(dep.get_options(dep.Config(options: dep.Options(resolver: resolver))))\n"
          <> "}\n",
      ),
    ],
    "check app.caller(resolver: [Stdout]) : []\n",
  )
  let assert Ok(results) = graded.run(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_cross_module_rebuild_resolves_test() {
  // A public rebuild helper in another module. `app.caller` calls
  // `dep.inner(dep.normalize(dep.Options(resolver: resolver)))`; `normalize`
  // returns `Options(resolver: o.resolver)` — a `Build` whose provenance is
  // threaded through the knowledge base by topological order. The build grounds
  // to a constructed value cross-module, `o.resolver` re-keys onto the caller's
  // `resolver`, and the field bound discharges it to [Stdout] — the cross-module
  // twin of the same-module `provenance_rebuild` build forwarding.
  let root = "build/provenance_cross_module_rebuild"
  write_project(
    root,
    [
      #(
        "dep.gleam",
        "pub type Options {\n  Options(resolver: fn() -> Nil)\n}\n\n"
          <> "pub fn inner(o: Options) -> Nil {\n  o.resolver()\n}\n\n"
          <> "pub fn normalize(o: Options) -> Options {\n  Options(resolver: o.resolver)\n}\n",
      ),
      #(
        "app.gleam",
        "import dep\n\n"
          <> "pub fn caller(resolver: fn() -> Nil) -> Nil {\n"
          <> "  dep.inner(dep.normalize(dep.Options(resolver: resolver)))\n"
          <> "}\n",
      ),
    ],
    "check app.caller(resolver: [Stdout]) : []\n",
  )
  let assert Ok(results) = graded.run(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_cross_module_labeled_resolves_test() {
  // A labeled call to a public helper in another module. `app.caller` calls
  // `dep.inner(dep.rebuild(with: dep.Options(resolver: resolver)))`; the label
  // binds the argument out of textual order, so grounding reorders it into
  // parameter-position order via the callee's registry signature — the
  // qualified-callee twin of the same-module `provenance_labeled` fixture. The
  // constructed `Options` forwards through the `Passthrough`, `o.resolver`
  // re-keys onto the caller's `resolver`, and the bound discharges to [Stdout].
  let root = "build/provenance_cross_module_labeled"
  write_project(
    root,
    [
      #(
        "dep.gleam",
        "pub type Options {\n  Options(resolver: fn() -> Nil)\n}\n\n"
          <> "pub fn inner(o: Options) -> Nil {\n  o.resolver()\n}\n\n"
          <> "pub fn rebuild(with o: Options) -> Options {\n  o\n}\n",
      ),
      #(
        "app.gleam",
        "import dep\n\n"
          <> "pub fn caller(resolver: fn() -> Nil) -> Nil {\n"
          <> "  dep.inner(dep.rebuild(with: dep.Options(resolver: resolver)))\n"
          <> "}\n",
      ),
    ],
    "check app.caller(resolver: [Stdout]) : []\n",
  )
  let assert Ok(results) = graded.run(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

fn receiver_path_forwarding_source() -> String {
  "pub type Options {\n"
  <> "  Options(resolver: fn() -> Nil)\n"
  <> "}\n\n"
  <> "pub type Inner {\n"
  <> "  Inner(run: fn() -> Nil)\n"
  <> "}\n\n"
  <> "pub type Outer {\n"
  <> "  Outer(inner: Inner)\n"
  <> "}\n\n"
  <> "pub type Config {\n"
  <> "  Config(options: Options, outer: Outer)\n"
  <> "}\n\n"
  <> "pub fn inner(options: Options) -> Nil {\n"
  <> "  options.resolver()\n"
  <> "}\n\n"
  <> "pub fn nested_inner(o: Outer) -> Nil {\n"
  <> "  o.inner.run()\n"
  <> "}\n\n"
  // Forwards `config.options` as the receiver: inner's `options.resolver`
  // re-keys to `config.options.resolver`.
  <> "pub fn forward_path(config: Config) -> Nil {\n"
  <> "  inner(config.options)\n"
  <> "}\n\n"
  // Forwards `config.outer`: nested_inner's `o.inner.run` re-keys to
  // `config.outer.inner.run`.
  <> "pub fn forward_nested(config: Config) -> Nil {\n"
  <> "  nested_inner(config.outer)\n"
  <> "}\n\n"
  <> "fn get_options(options: Options) -> Options {\n"
  <> "  options\n"
  <> "}\n\n"
  // Computed receiver whose helper returns its parameter (`Passthrough`): return
  // provenance forwards `config.options` through the call, so inner's
  // `options.resolver` re-keys to `config.options.resolver`.
  <> "pub fn forward_computed(config: Config) -> Nil {\n"
  <> "  inner(get_options(config.options))\n"
  <> "}\n\n"
  // Aliased receiver path: the alias preserves the path, so inner's
  // `options.resolver` re-keys to `config.options.resolver`.
  <> "pub fn forward_alias(config: Config) -> Nil {\n"
  <> "  let alias = config.options\n"
  <> "  inner(alias)\n"
  <> "}\n\n"
  // Direct parameter alias: `forwarded` aliases the `options` parameter, so
  // inner's `options.resolver` re-keys to the caller's `options.resolver`.
  <> "pub fn forward_param_alias(options: Options) -> Nil {\n"
  <> "  let forwarded = options\n"
  <> "  inner(forwarded)\n"
  <> "}\n\n"
  // Computed-receiver alias: the binding is an opaque call result, so it stays
  // conservative even though `config.options` flows into it.
  <> "pub fn forward_computed_alias(config: Config) -> Nil {\n"
  <> "  let alias = get_options(config.options)\n"
  <> "  inner(alias)\n"
  <> "}\n"
}

// A function whose inferred effects collapsed to `[Unknown]` with no caller-
// rooted field bound surfaced — the conservative outcome for non-forwardable
// receivers.
fn expect_unknown_without_field_bound(
  annotations: List(types.EffectAnnotation),
  function: String,
) {
  let assert Ok(annotation) =
    list.find(annotations, fn(a) { a.function == function })
  annotation.effects |> should.equal(effect_term.unknown())
  annotation.params
  |> list.filter(fn(b) { string.starts_with(b.name, "config.") })
  |> should.equal([])
}

pub fn receiver_path_forwarding_infers_path_test() {
  let annotations =
    infer_project("build/receiver_path_forwarding", [
      #("proj.gleam", receiver_path_forwarding_source()),
    ])

  expect_field_bound(
    annotations,
    "proj.forward_path",
    "config.options.resolver",
  )
}

pub fn receiver_path_forwarding_infers_nested_callee_field_test() {
  let annotations =
    infer_project("build/receiver_path_forwarding_nested", [
      #("proj.gleam", receiver_path_forwarding_source()),
    ])

  expect_field_bound(
    annotations,
    "proj.forward_nested",
    "config.outer.inner.run",
  )
}

pub fn receiver_path_forwarding_unbound_check_stays_unknown_test() {
  let root = "build/receiver_path_forwarding_unbound_check"
  let results =
    run_project_with_spec(
      root,
      receiver_path_forwarding_source(),
      "check proj.forward_path : []\n",
    )
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/proj.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "forward_path" })
  v.actual |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn receiver_path_forwarding_bound_check_discharges_test() {
  let root = "build/receiver_path_forwarding_bound_check"
  let results =
    run_project_with_spec(
      root,
      receiver_path_forwarding_source(),
      "check proj.forward_path(config.options.resolver: [Stdout]) : []\n",
    )
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/proj.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "forward_path" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn receiver_path_forwarding_computed_receiver_resolves_test() {
  // `inner(get_options(config.options))` — `get_options` returns its parameter,
  // so return-value provenance forwards `config.options` through the call and
  // inner's `options.resolver` re-keys to `config.options.resolver`.
  let annotations =
    infer_project("build/receiver_path_forwarding_computed", [
      #("proj.gleam", receiver_path_forwarding_source()),
    ])

  expect_field_bound(
    annotations,
    "proj.forward_computed",
    "config.options.resolver",
  )
}

pub fn receiver_path_forwarding_alias_infers_path_test() {
  // `let alias = config.options; inner(alias)` — the alias preserves the
  // receiver path, so the forwarded field bound is `config.options.resolver`,
  // identical to the inline `inner(config.options)` case.
  let annotations =
    infer_project("build/receiver_path_forwarding_alias", [
      #("proj.gleam", receiver_path_forwarding_source()),
    ])

  expect_field_bound(
    annotations,
    "proj.forward_alias",
    "config.options.resolver",
  )
}

pub fn receiver_path_forwarding_param_alias_infers_path_test() {
  // `let forwarded = options; inner(forwarded)` — a direct parameter alias
  // forwards onto the caller's own `options.resolver`, just like passing the
  // parameter directly.
  let annotations =
    infer_project("build/receiver_path_forwarding_param_alias", [
      #("proj.gleam", receiver_path_forwarding_source()),
    ])

  expect_field_bound(
    annotations,
    "proj.forward_param_alias",
    "options.resolver",
  )
}

pub fn receiver_path_forwarding_computed_alias_stays_conservative_test() {
  // `let alias = get_options(config.options); inner(alias)` — the alias is bound
  // from a computed call result, not a traceable path, so it stays [Unknown].
  let annotations =
    infer_project("build/receiver_path_forwarding_computed_alias", [
      #("proj.gleam", receiver_path_forwarding_source()),
    ])

  expect_unknown_without_field_bound(annotations, "proj.forward_computed_alias")
}

pub fn receiver_path_forwarding_alias_bound_check_discharges_test() {
  // A `check` field bound on the aliased path discharges to [Stdout], proving the
  // alias re-keys onto the caller's receiver exactly as the inline path does.
  let root = "build/receiver_path_forwarding_alias_bound_check"
  let results =
    run_project_with_spec(
      root,
      receiver_path_forwarding_source(),
      "check proj.forward_alias(config.options.resolver: [Stdout]) : []\n",
    )
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/proj.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "forward_alias" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn receiver_path_forwarding_param_alias_bound_check_discharges_test() {
  // A `check` field bound on the direct parameter alias discharges to [Stdout].
  let root = "build/receiver_path_forwarding_param_alias_bound_check"
  let results =
    run_project_with_spec(
      root,
      receiver_path_forwarding_source(),
      "check proj.forward_param_alias(options.resolver: [Stdout]) : []\n",
    )
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/proj.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "forward_param_alias" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn nested_field_round_trips_as_dotted_field_bound_test() {
  // Inferring a nested fn-typed field call on a same-module type (no `type`
  // line, no field bound) surfaces it as a polymorphic *dotted* field bound —
  // `o.inner.run` — mirroring the single-level round-trip but with a
  // multi-segment path. Run through the full `run_infer` pipeline so girard
  // types the nested receiver (the same-module polymorphic path needs the
  // resolved receiver type, which only girard supplies for a nested receiver).
  let annotations =
    infer_project("build/nested_poly_app", [
      #(
        "proj.gleam",
        "pub type Inner {\n  Inner(run: fn() -> Nil)\n}\n\n"
          <> "pub type Outer {\n  Outer(inner: Inner)\n}\n\n"
          <> "pub fn poke(o: Outer) -> Nil {\n  o.inner.run()\n}\n",
      ),
    ])
  let assert Ok(annotation) =
    list.find(annotations, fn(a) { a.function == "proj.poke" })
  let assert Ok(bound) =
    list.find(annotation.params, fn(b) { b.name == "o.inner.run" })
  bound.effects |> should.equal(types.TVar("o.inner.run"))
  annotation.effects |> should.equal(types.TVar("o.inner.run"))
}

pub fn nested_field_pipe_target_resolves_test() {
  // `"x" |> o.inner.run` — a NESTED field call used as a pipe target. The pipe
  // path emits a FieldCall for the nested receiver, so the field's effect is
  // captured (resolved by `type pipe_field.Inner.run : [Disk]`) and the []
  // budget fails with [Disk]. Before the fix the pipe target fell through to the
  // generic walker, dropped the effect, and the budget passed unsoundly.
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/pipe_field.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "via_pipe" })
  v.actual |> should.equal(types.Specific(set.from_list(["Disk"])))
}

pub fn alias_typed_field_round_trips_as_field_bound_test() {
  // A `fn`-typed field declared through a module-local alias (`run: Action` with
  // `type Action = fn(String) -> Nil`) is callable. Inferring a function that
  // calls it on an opaque receiver surfaces the polymorphic field bound `r.run`,
  // not [Unknown] — the alias is resolved exactly as for fn-typed parameters.
  let annotations =
    infer_project("build/alias_field_app", [
      #(
        "proj.gleam",
        "pub type Action = fn(String) -> Nil\n\n"
          <> "pub type Runner {\n  Runner(run: Action)\n}\n\n"
          <> "pub fn go(r: Runner) -> Nil {\n  r.run(\"x\")\n}\n",
      ),
    ])
  let assert Ok(annotation) =
    list.find(annotations, fn(a) { a.function == "proj.go" })
  let assert Ok(bound) =
    list.find(annotation.params, fn(b) { b.name == "r.run" })
  bound.effects |> should.equal(types.TVar("r.run"))
  annotation.effects |> should.equal(types.TVar("r.run"))
}

pub fn imported_same_name_field_does_not_borrow_local_test() {
  // The local module defines its own fn-typed `Runner.run`, and `go` calls
  // `r.run()` on an *imported* `ext.Runner` that shares the type name and field
  // label. The field fallback consults only the current module's registry, so
  // the imported field must not borrow the local one: `go` resolves to [Unknown]
  // with no `r.run` bound — not a spurious polymorphic field variable for an
  // unrelated imported type.
  let annotations =
    infer_project("build/imported_samename_app", [
      #("ext.gleam", "pub type Runner {\n  Runner(run: fn() -> Nil)\n}\n"),
      #(
        "proj.gleam",
        "import ext\n\n"
          <> "pub type Runner {\n  Runner(run: fn() -> Nil)\n}\n\n"
          <> "pub fn go(r: ext.Runner) -> Nil {\n  r.run()\n}\n",
      ),
    ])
  let assert Ok(annotation) =
    list.find(annotations, fn(a) { a.function == "proj.go" })
  list.any(annotation.params, fn(b) { b.name == "r.run" })
  |> should.be_false()
  effect_term.to_effect_set(annotation.effects)
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn nested_field_resolves_cross_module_type_line_test() {
  // The essem case: a nested call whose INTERMEDIATE receiver type lives in
  // ANOTHER module. `handler.handle` calls `model.service.org.create("acme")`;
  // girard types `model.service.org` as `svc.OrganizationService`, and the
  // module-qualified `type svc.OrganizationService.create : [Storage, Time]`
  // line resolves it cross-module — so the [] budget fails with that precise
  // effect. Synthesized as a multi-module project so the consumer's `type` line
  // points at a type defined in a different module, exactly essem's shape.
  let root = "build/nested_xmod_app"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(root <> "/gleam.toml", "name = \"proj\"\n")
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/svc.gleam",
      "pub type OrganizationService {\n"
        <> "  OrganizationService(create: fn(String) -> Nil)\n}\n\n"
        <> "pub type Services {\n  Services(org: OrganizationService)\n}\n\n"
        <> "pub type Model {\n  Model(service: Services)\n}\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/handler.gleam",
      "import svc\n\n"
        <> "pub fn handle(model: svc.Model) -> Nil {\n"
        <> "  model.service.org.create(\"acme\")\n}\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/proj.graded",
      "check handler.handle : []\n\n"
        <> "type svc.OrganizationService.create : [Storage, Time]\n",
    )

  let assert Ok(results) = graded.run(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/handler.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "handle" })
  v.actual |> should.equal(types.Specific(set.from_list(["Storage", "Time"])))

  let _ = simplifile.delete(root)
  Nil
}

pub fn closure_field_effect_from_construction_test() {
  // A record field wired to an *inline closure* at construction resolves to the
  // closure body's effect ([Stdout]) without a hand-written `type` annotation —
  // previously this fell back to [Unknown].
  let assert Ok(results) = graded.run("test/fixtures")
  let closure_result =
    list.find(results, fn(r) { r.file == "test/fixtures/closure_field.gleam" })
  let assert Ok(r) = closure_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn operator_typed_closure_field_test() {
  // An *operator-typed* field (a closure that calls its own callback) is lifted
  // to `λnext. [next]` and applied at the field call `m.wrap(io.println)`,
  // resolving to the supplied callback's [Stdout] — previously [Unknown].
  let assert Ok(results) = graded.run("test/fixtures")
  let operator_result =
    list.find(results, fn(r) { r.file == "test/fixtures/operator_field.gleam" })
  let assert Ok(r) = operator_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn inferred_field_effect_from_construction_test() {
  // Stage C: inferred_field has NO `type Logger.emit` annotation. graded
  // derives the field's effect from the construction `Logger(emit: io.println)`
  // and girard types the receiver, so the [] check budget fails with the
  // precise [Stdout] — no hand-written type annotation needed.
  let assert Ok(results) = graded.run("test/fixtures")
  let inferred_result =
    list.find(results, fn(r) { r.file == "test/fixtures/inferred_field.gleam" })
  let assert Ok(r) = inferred_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn local_field_value_resolved_test() {
  // local_field.run wires a *same-module* function (my_logger : [Stdout]) into a
  // record field and calls it. graded qualifies the bare reference by the module
  // and resolves its effect, so the [] check budget fails with the precise
  // [Stdout] — the case that previously fell back to [Unknown]. local_field also
  // defines a `Logger` type, same as inferred_field, so a pass here also proves
  // same-named constructors in different modules aren't conflated.
  let assert Ok(results) = graded.run("test/fixtures")
  let local_result =
    list.find(results, fn(r) { r.file == "test/fixtures/local_field.gleam" })
  let assert Ok(r) = local_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn named_fn_arg_resolves_test() {
  // named_fn_arg.run passes a *same-module named function* (logging_parser :
  // [Stdout]) to a first-order fn-typed parameter. The argument resolves to the
  // function's real effect, so the [] budget fails with the precise [Stdout] —
  // not the [Unknown] graded fell back to before (inline closures already
  // resolved; named references did not).
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/named_fn_arg.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "run" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn labeled_callback_resolves_test() {
  // labeled_callback.run passes an effectful callback (logging_parser :
  // [Stdout]) with a Gleam label (`with:`). Argument-to-parameter matching now
  // binds the labelled argument, so the parameter's effect variable discharges
  // to [Stdout] instead of leaking unresolved into the fully-applied caller.
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/labeled_callback.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "run" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn record_update_field_walked_test() {
  // record_update.run updates a field with an effectful expression (shout :
  // [Stdout]). The call sits inside a record update, so its effect surfaces
  // only if the extractor walks the updated field values, not just the base
  // record. Without that, the [Stdout] is silently dropped and `run` wrongly
  // resolves to [].
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/record_update.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "run" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn shadowed_param_resolves_through_bound_test() {
  // shadow_param.run takes a fn-typed parameter `handler` that shadows a
  // same-module function of the same name (handler : [Stdout]). The forwarded
  // argument must resolve through the param bound ([]), not by lifting the
  // shadowed function — so the [] budget holds and `run` has no violation.
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/shadow_param.gleam" })
  list.any(r.violations, fn(v) { v.function == "run" }) |> should.be_false()
}

pub fn aliased_param_call_resolves_through_bound_test() {
  // shadow_param.run_alias aliases its fn-typed parameter (`let f = handler`)
  // and calls the alias directly. The call must resolve through the parameter's
  // bound ([]), not the shadowed same-module `handler` nor [Unknown], so the []
  // budget holds and `run_alias` has no violation.
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/shadow_param.gleam" })
  list.any(r.violations, fn(v) { v.function == "run_alias" })
  |> should.be_false()
}

pub fn infer_then_check_round_trip_test() {
  // `run_infer` rewrites the spec file in place, so capture the canonical
  // fixture content up front and restore it at the end — keeping the test
  // self-contained rather than duplicating the fixture as a literal here.
  let spec_path = "test/fixtures/fixtures.graded"
  let assert Ok(original) = simplifile.read(spec_path)

  // Infer regenerates the public-effects portion of the spec file while
  // preserving the hand-written check lines.
  let assert Ok(Nil) = graded.run_infer("test/fixtures")

  let assert Ok(content) = simplifile.read(spec_path)
  let assert Ok(file) = annotation.parse_file(content)

  // The spec file's check lines should still be there after `infer`.
  let checks = annotation.extract_checks(file)
  { list.length(checks) >= 3 } |> should.be_true()

  // Inferred effects lines should also be present.
  let all = annotation.extract_annotations(file)
  { list.length(all) > list.length(checks) } |> should.be_true()

  // Check still catches violations via the spec's check annotations.
  let assert Ok(results) = graded.run("test/fixtures")
  let impure_result =
    list.find(results, fn(r) { r.file == "test/fixtures/impure_view.gleam" })
  let assert Ok(r) = impure_result
  { r.violations != [] } |> should.be_true()

  // Restore the captured fixture so subsequent test runs start clean.
  let assert Ok(Nil) = simplifile.write(spec_path, original)
}

pub fn run_resolves_deps_from_target_dir_test() {
  // graded.run is handed a project directory that is NOT the process cwd (which
  // stays at the repository root under `gleam test`). Dependency specs must be
  // read from THAT directory's `build/packages`, not the repo's. We build a
  // throwaway project under the gitignored `build/` whose own `build/packages`
  // declares `dep.fetch : [Http]`; `run` calls it, so the `[]` budget must fail
  // with the precise [Http]. When dependency loading is cwd-relative, the repo
  // has no such dep and the call leaks as [Unknown] instead.
  let root = "build/cwd_dep_fixture"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) =
    simplifile.create_directory_all(root <> "/build/packages/dep")
  let assert Ok(Nil) =
    simplifile.write(root <> "/gleam.toml", "name = \"proj\"\n")
  let assert Ok(Nil) =
    simplifile.write(root <> "/proj.graded", "check proj.run : []\n")
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/proj.gleam",
      "import dep\n\npub fn run() -> Nil {\n  dep.fetch()\n}\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/build/packages/dep/dep.graded",
      "effects dep.fetch : [Http]\n",
    )

  let assert Ok(results) = graded.run(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/proj.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "run" })
  v.actual |> should.equal(types.Specific(set.from_list(["Http"])))

  let assert Ok(Nil) = simplifile.delete(root)
}

// Write an app project and a sibling path-dependency `dep` exposing a
// higher-order `dep_apply` that *invokes* its callback parameter. The app calls
// it with a pure callback and an impure (`io.println`) one. When `write_spec`
// is True the dep ships a committed `dep.graded` (the fast path consumers read);
// otherwise the dep has source only (graded infers it). Both branches must load
// the dep's polymorphic param bound so the callback's effect discharges at the
// call site instead of leaking the parameter's effect variable.
fn setup_path_dep_project(
  app_root: String,
  dep_name: String,
  write_spec: Bool,
) {
  let dep_root = "build/" <> dep_name
  let _ = simplifile.delete(app_root)
  let _ = simplifile.delete(dep_root)

  let assert Ok(Nil) = simplifile.create_directory_all(dep_root <> "/src")
  let assert Ok(Nil) =
    simplifile.write(
      dep_root <> "/src/dep.gleam",
      "pub fn dep_apply(f f: fn(String) -> a) -> a {\n  f(\"x\")\n}\n",
    )
  let assert Ok(Nil) =
    simplifile.write(dep_root <> "/gleam.toml", "name = \"dep\"\n")
  let assert Ok(Nil) = case write_spec {
    True ->
      simplifile.write(
        dep_root <> "/dep.graded",
        "effects dep.dep_apply(f: [f]) : [f]\n",
      )
    False -> Ok(Nil)
  }

  let assert Ok(Nil) = simplifile.create_directory_all(app_root)
  let assert Ok(Nil) =
    simplifile.write(
      app_root <> "/gleam.toml",
      "name = \"app\"\n\n[dependencies]\ndep = { path = \"../"
        <> dep_name
        <> "\" }\n",
    )
  // manifest.toml lets catalog selection resolve `gleam/io.println : [Stdout]`,
  // so the impure-callback case can assert the real effect flows through.
  let assert Ok(Nil) =
    simplifile.write(
      app_root <> "/manifest.toml",
      "packages = [{ name = \"gleam_stdlib\", version = \"0.70.0\" }]\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      app_root <> "/app.graded",
      "check app.caller_pure : []\ncheck app.caller_impure : []\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      app_root <> "/app.gleam",
      "import dep\nimport gleam/io\n\n"
        <> "fn pure_cb(s: String) -> Int {\n  case s {\n    \"\" -> 0\n    _ -> 1\n  }\n}\n\n"
        <> "pub fn caller_pure() -> Int {\n  dep.dep_apply(pure_cb)\n}\n\n"
        <> "pub fn caller_impure() -> Nil {\n  dep.dep_apply(io.println)\n}\n",
    )
  Nil
}

pub fn path_dep_hof_param_discharges_from_source_test() {
  // Path dep with source only (no committed spec): graded infers `dep_apply`'s
  // polymorphic bound and must thread it into the knowledge base so the pure
  // callback discharges to []. Before the fix, the variable `f` leaked.
  let app_root = "build/pd_src_app"
  setup_path_dep_project(app_root, "pd_src_dep", False)

  let assert Ok(results) = graded.run(app_root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == app_root <> "/app.gleam" })

  // Pure callback: the bound discharges, so the [] budget holds.
  list.any(r.violations, fn(v) { v.function == "caller_pure" })
  |> should.be_false()
  // Impure callback: the callback's real effect ([Stdout]) flows through the
  // bound — not a leaked variable, not [Unknown].
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_impure" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))

  let _ = simplifile.delete(app_root)
  let _ = simplifile.delete("build/pd_src_dep")
  Nil
}

pub fn path_dep_hof_param_discharges_from_spec_test() {
  // Path dep shipping a committed `dep.graded` carrying the polymorphic bound:
  // the consumer must load the bound (not just the effect) so the callback
  // discharges. Before the fix, the spec-file branch dropped the bound too.
  let app_root = "build/pd_spec_app"
  setup_path_dep_project(app_root, "pd_spec_dep", True)

  let assert Ok(results) = graded.run(app_root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == app_root <> "/app.gleam" })

  list.any(r.violations, fn(v) { v.function == "caller_pure" })
  |> should.be_false()
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_impure" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))

  let _ = simplifile.delete(app_root)
  let _ = simplifile.delete("build/pd_spec_dep")
  Nil
}

// Build a source-only path-dependency fixture under build/<name>_{dep,app}, run
// graded on the app, and return the CheckResult for app.gleam. `dep_files` maps
// each path under the dep's `src/` to its source; `spec` is the app's `.graded`
// contents; `app_src` is app.gleam's contents.
fn run_path_dep_fixture(
  name: String,
  dep_files: List(#(String, String)),
  spec: String,
  app_src: String,
) -> types.CheckResult {
  let app_root = "build/" <> name <> "_app"
  let dep_root = "build/" <> name <> "_dep"
  let _ = simplifile.delete(app_root)
  let _ = simplifile.delete(dep_root)

  let assert Ok(Nil) = simplifile.create_directory_all(dep_root <> "/src")
  let assert Ok(Nil) =
    simplifile.write(dep_root <> "/gleam.toml", "name = \"dep\"\n")
  list.each(dep_files, fn(file) {
    let #(path, content) = file
    let assert Ok(Nil) = simplifile.write(dep_root <> "/src/" <> path, content)
    Nil
  })

  let assert Ok(Nil) = simplifile.create_directory_all(app_root)
  let assert Ok(Nil) =
    simplifile.write(
      app_root <> "/gleam.toml",
      "name = \"app\"\n\n[dependencies]\ndep = { path = \"../"
        <> name
        <> "_dep\" }\n",
    )
  let assert Ok(Nil) = simplifile.write(app_root <> "/app.graded", spec)
  let assert Ok(Nil) = simplifile.write(app_root <> "/app.gleam", app_src)

  let assert Ok(results) = graded.run(app_root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == app_root <> "/app.gleam" })
  r
}

pub fn path_dep_module_level_external_marks_pure_test() {
  // Source-only path dep `dep` with an opaque FFI body graded would infer as
  // [Unknown]. `external effects dep : []` declares the whole module pure, so
  // `dep.touch` resolves to [] and `check caller : []` holds.
  let r =
    run_path_dep_fixture(
      "pd_modext",
      [
        #(
          "dep.gleam",
          "@external(erlang, \"d\", \"t\")\npub fn touch() -> Nil\n",
        ),
      ],
      "external effects dep : []\n\ncheck app.caller : []\n",
      "import dep\n\npub fn caller() -> Nil {\n  dep.touch()\n}\n",
    )
  list.any(r.violations, fn(v) { v.function == "caller" })
  |> should.be_false()
}

pub fn path_dep_module_level_external_preserves_effect_test() {
  // A non-empty module-level external propagates that exact set, it does not
  // collapse to pure. `external effects dep : [Database]` makes `dep.touch`
  // resolve to [Database], so `check caller : []` fails with an actual of
  // [Database] — not flattened to [] and not left as an inferred [Unknown].
  let r =
    run_path_dep_fixture(
      "pd_modext_eff",
      [
        #(
          "dep.gleam",
          "@external(erlang, \"d\", \"t\")\npub fn touch() -> Nil\n",
        ),
      ],
      "external effects dep : [Database]\n\ncheck app.caller : []\n",
      "import dep\n\npub fn caller() -> Nil {\n  dep.touch()\n}\n",
    )
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Database"])))
}

pub fn path_dep_module_external_propagates_through_wrapper_test() {
  // A module-level external governs its module DURING the dependency's own
  // inference. The dep's `wrapper` calls the declared-pure `ffi`; were `ffi`
  // inferred [Unknown] and dropped only afterward, `wrapper.go` would be
  // polluted. It resolves to [] instead, so `check caller : []` holds through
  // the wrapper.
  let r =
    run_path_dep_fixture(
      "pd_modext_wrap",
      [
        #(
          "ffi.gleam",
          "@external(erlang, \"d\", \"t\")\npub fn touch() -> Nil\n",
        ),
        #(
          "wrapper.gleam",
          "import ffi\n\npub fn go() -> Nil {\n  ffi.touch()\n}\n",
        ),
      ],
      "external effects ffi : []\n\ncheck app.caller : []\n",
      "import wrapper\n\npub fn caller() -> Nil {\n  wrapper.go()\n}\n",
    )
  list.any(r.violations, fn(v) { v.function == "caller" })
  |> should.be_false()
}

pub fn path_dep_module_external_keeps_returned_operator_test() {
  // A module-level external suppresses only the call effect, not the
  // returned-operator metadata. `make` returns a pure closure; `wrapper` does
  // `let action = ffi.make()  action()`. With `external effects ffi : []`, the
  // call to `make` resolves to [] and `action()` resolves through `make`'s kept
  // returned operator, so `check caller : []` holds. Dropping the returned
  // operator would leave `action()` as [Unknown] and fail the check.
  let r =
    run_path_dep_fixture(
      "pd_modext_ret",
      [
        #("ffi.gleam", "pub fn make() -> fn() -> Nil {\n  fn() { Nil }\n}\n"),
        #(
          "wrapper.gleam",
          "import ffi\n\npub fn go() -> Nil {\n  let action = ffi.make()\n  action()\n}\n",
        ),
      ],
      "external effects ffi : []\n\ncheck app.caller : []\n",
      "import wrapper\n\npub fn caller() -> Nil {\n  wrapper.go()\n}\n",
    )
  list.any(r.violations, fn(v) { v.function == "caller" })
  |> should.be_false()
}

// An opaque FFI body graded infers as [Unknown]: the canonical declared-external
// target across the module-external project fixtures below.
const ffi_touch = "@external(erlang, \"d\", \"t\")\npub fn touch() -> Nil\n"

// Write a fresh project at `root`: `name = "proj"` gleam.toml, each
// `#(filename, source)` module at the root, and the `proj.graded` spec.
fn write_project(
  root: String,
  modules: List(#(String, String)),
  spec: String,
) -> Nil {
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(root <> "/gleam.toml", "name = \"proj\"\n")
  list.each(modules, fn(file) {
    let #(path, content) = file
    let assert Ok(Nil) = simplifile.write(root <> "/" <> path, content)
    Nil
  })
  let assert Ok(Nil) = simplifile.write(root <> "/proj.graded", spec)
  Nil
}

// Write a multi-module project (the extra `modules` plus an `app.gleam`) and its
// spec, run graded, and return the CheckResult for app.gleam. The project-module
// counterpart of `run_path_dep_fixture`: the declared-external module is a
// sibling project module, not a path dependency.
fn run_project_module_fixture(
  name: String,
  modules: List(#(String, String)),
  spec: String,
  app_src: String,
) -> types.CheckResult {
  let root = "build/" <> name <> "_proj"
  write_project(root, [#("app.gleam", app_src), ..modules], spec)

  let assert Ok(results) = graded.run(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  r
}

pub fn project_module_level_external_marks_pure_test() {
  // A project module `db` with an opaque FFI body graded would infer as
  // [Unknown]. `external effects db : []` declares the whole module pure, so
  // `db.touch` resolves to [] and `check caller : []` holds — the
  // project-module counterpart of `path_dep_module_level_external_marks_pure`.
  // Before the fix the in-memory inference of `db` left an [Unknown] in
  // `all_effects` that shadowed the declaration.
  let r =
    run_project_module_fixture(
      "modext_pure",
      [#("db.gleam", ffi_touch)],
      "external effects db : []\n\ncheck app.caller : []\n",
      "import db\n\npub fn caller() -> Nil {\n  db.touch()\n}\n",
    )
  list.any(r.violations, fn(v) { v.function == "caller" })
  |> should.be_false()
}

pub fn project_module_level_external_preserves_effect_test() {
  // A non-empty module-level external propagates that exact set, it does not
  // collapse to pure or stay an inferred [Unknown]. `external effects db :
  // [Database]` makes `db.touch` resolve to [Database], so `check caller : []`
  // fails with [Database].
  let r =
    run_project_module_fixture(
      "modext_eff",
      [#("db.gleam", ffi_touch)],
      "external effects db : [Database]\n\ncheck app.caller : []\n",
      "import db\n\npub fn caller() -> Nil {\n  db.touch()\n}\n",
    )
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Database"])))
}

pub fn project_module_external_propagates_through_wrapper_test() {
  // A module-level external governs its module DURING the project's in-memory
  // inference. The sibling `wrapper.go` calls the declared-pure `db.touch`; were
  // `db.touch` inferred [Unknown] and only dropped at final lookup, `wrapper.go`
  // would be polluted. It resolves to [] instead, so `check caller : []` holds
  // through the wrapper.
  let r =
    run_project_module_fixture(
      "modext_wrap",
      [
        #("db.gleam", ffi_touch),
        #(
          "wrapper.gleam",
          "import db\n\npub fn go() -> Nil {\n  db.touch()\n}\n",
        ),
      ],
      "external effects db : []\n\ncheck app.caller : []\n",
      "import wrapper\n\npub fn caller() -> Nil {\n  wrapper.go()\n}\n",
    )
  list.any(r.violations, fn(v) { v.function == "caller" })
  |> should.be_false()
}

pub fn project_module_external_keeps_returned_operator_test() {
  // A module-level external suppresses only the call effect, not the
  // returned-operator metadata. `db.make` returns a pure closure; `wrapper` does
  // `let action = db.make()  action()`. With `external effects db : []`, the call
  // to `make` resolves to [] and `action()` resolves through `make`'s kept
  // returned operator, so `check caller : []` holds. Dropping the returned
  // operator would leave `action()` as [Unknown] and fail the check.
  let r =
    run_project_module_fixture(
      "modext_ret",
      [
        #("db.gleam", "pub fn make() -> fn() -> Nil {\n  fn() { Nil }\n}\n"),
        #(
          "wrapper.gleam",
          "import db\n\npub fn go() -> Nil {\n  let action = db.make()\n  action()\n}\n",
        ),
      ],
      "external effects db : []\n\ncheck app.caller : []\n",
      "import wrapper\n\npub fn caller() -> Nil {\n  wrapper.go()\n}\n",
    )
  list.any(r.violations, fn(v) { v.function == "caller" })
  |> should.be_false()
}

pub fn project_module_external_infer_omits_lines_and_governs_test() {
  // `graded infer` over a project with `external effects db : [Database]` writes
  // no inferred `effects db.*` lines (the declaration governs the module, like a
  // function-level external suppresses its own line), and a sibling `wrapper.go`
  // calling into `db` inherits the declared [Database] — so `infer` and `check`
  // agree on the cross-module effect.
  let root = "build/modext_infer_proj"
  write_project(
    root,
    [
      #("db.gleam", ffi_touch),
      #("wrapper.gleam", "import db\n\npub fn go() -> Nil {\n  db.touch()\n}\n"),
    ],
    "external effects db : [Database]\n",
  )
  let assert Ok(Nil) = graded.run_infer(root)

  let assert Ok(content) = simplifile.read(root <> "/proj.graded")
  let assert Ok(file) = annotation.parse_file(content)
  let annotations = annotation.extract_annotations(file)
  list.any(annotations, fn(a) { string.starts_with(a.function, "db.") })
  |> should.be_false()
  let assert Ok(go) =
    list.find(annotations, fn(a) { a.function == "wrapper.go" })
  go.effects |> should.equal(types.TLabels(set.from_list(["Database"])))
}

pub fn project_module_external_infer_filters_construction_kb_test() {
  // A field wired to a declared-external module's function resolves through the
  // construction index. The spec still carries a STALE `effects db.touch :
  // [Stdout]` line; since function effects outrank module effects, that stale
  // entry would pollute the construction knowledge base and make `graded infer`
  // resolve `Runner.act` (and its caller `go`) to [Stdout] — disagreeing with
  // `check`, which filters it. With the stale line dropped from the construction
  // KB too, the field resolves to the declared [Database].
  let root = "build/modext_construction_proj"
  write_project(
    root,
    [
      #("db.gleam", ffi_touch),
      #(
        "app.gleam",
        "import db\n\n"
          <> "pub type Runner {\n  Runner(act: fn() -> Nil)\n}\n\n"
          <> "pub fn make() -> Runner {\n  Runner(act: db.touch)\n}\n\n"
          <> "pub fn go(r: Runner) -> Nil {\n  r.act()\n}\n",
      ),
    ],
    "external effects db : [Database]\neffects db.touch : [Stdout]\n",
  )
  let assert Ok(Nil) = graded.run_infer(root)

  let assert Ok(content) = simplifile.read(root <> "/proj.graded")
  let assert Ok(file) = annotation.parse_file(content)
  let annotations = annotation.extract_annotations(file)
  let assert Ok(go) = list.find(annotations, fn(a) { a.function == "app.go" })
  go.effects |> should.equal(types.TLabels(set.from_list(["Database"])))
}

pub fn path_dep_cross_module_positional_discharges_test() {
  // Source-only path dep whose module `b` calls another module `a`'s
  // higher-order function POSITIONALLY (`a.apply(pure_cb)`). Inferring the dep
  // needs a registry covering its own modules, so the positional callback
  // matches `apply`'s bound by position — otherwise `b.run` keeps the
  // unresolved variable and the consumer's [] check fails. Labelled calls
  // resolved without it (matched by name); this is the positional gap.
  let app_root = "build/pd_xmod_app"
  let dep_root = "build/pd_xmod_dep"
  let _ = simplifile.delete(app_root)
  let _ = simplifile.delete(dep_root)

  let assert Ok(Nil) = simplifile.create_directory_all(dep_root <> "/src/dep")
  let assert Ok(Nil) =
    simplifile.write(dep_root <> "/gleam.toml", "name = \"dep\"\n")
  let assert Ok(Nil) =
    simplifile.write(
      dep_root <> "/src/dep/a.gleam",
      "pub fn apply(f f: fn(String) -> a) -> a {\n  f(\"x\")\n}\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      dep_root <> "/src/dep/b.gleam",
      "import dep/a\n\n"
        <> "fn pure_cb(s: String) -> Int {\n  case s {\n    \"\" -> 0\n    _ -> 1\n  }\n}\n\n"
        <> "pub fn run() -> Int {\n  a.apply(pure_cb)\n}\n",
    )

  let assert Ok(Nil) = simplifile.create_directory_all(app_root)
  let assert Ok(Nil) =
    simplifile.write(
      app_root <> "/gleam.toml",
      "name = \"app\"\n\n[dependencies]\ndep = { path = \"../pd_xmod_dep\" }\n",
    )
  let assert Ok(Nil) =
    simplifile.write(app_root <> "/app.graded", "check app.caller : []\n")
  let assert Ok(Nil) =
    simplifile.write(
      app_root <> "/app.gleam",
      "import dep/b\n\npub fn caller() -> Int {\n  b.run()\n}\n",
    )

  let assert Ok(results) = graded.run(app_root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == app_root <> "/app.gleam" })
  list.any(r.violations, fn(v) { v.function == "caller" })
  |> should.be_false()

  let _ = simplifile.delete(app_root)
  let _ = simplifile.delete(dep_root)
  Nil
}

// ----- function-typed fields on dependency-defined types -----

pub fn path_dep_type_field_resolves_from_consumer_spec_test() {
  // A path dep defines a capability record `Repo(find: fn(String) -> Int)`. The
  // consumer calls `r.find(...)` through a parameter typed by the dependency,
  // and annotates that field in its OWN spec with a module-qualified `type`
  // line. graded must type the receiver as the dependency's nominal type
  // (`dep/repo.Repo`) so the `#(module, type, field)` lookup hits — which means
  // girard has to read the path dependency's source, not just `build/packages`.
  // Before the fix the receiver type was unresolved and the call leaked
  // [Unknown]; now it resolves to the annotated [Storage].
  let r =
    run_path_dep_fixture(
      "pd_typefield_consumer",
      [#("repo.gleam", "pub type Repo {\n  Repo(find: fn(String) -> Int)\n}\n")],
      "type repo.Repo.find : [Storage]\n\ncheck app.use_field : []\n",
      "import repo.{type Repo}\n\n"
        <> "pub fn use_field(r: Repo) -> Int {\n  r.find(\"x\")\n}\n",
    )
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "use_field" })
  v.actual |> should.equal(types.Specific(set.from_list(["Storage"])))
}

pub fn path_dep_ships_type_field_test() {
  // The dependency itself ships the `type` annotation in its committed
  // `dep.graded`; the consumer declares no field annotation at all. graded must
  // load the dependency spec's `type` lines (not just its `effects`) so the
  // consumer's `r.find(...)` resolves to the dependency-declared [Storage].
  let app_root = "build/pd_ships_typefield_app"
  let dep_root = "build/pd_ships_typefield_dep"
  let _ = simplifile.delete(app_root)
  let _ = simplifile.delete(dep_root)

  let assert Ok(Nil) = simplifile.create_directory_all(dep_root <> "/src/dep")
  let assert Ok(Nil) =
    simplifile.write(dep_root <> "/gleam.toml", "name = \"dep\"\n")
  let assert Ok(Nil) =
    simplifile.write(
      dep_root <> "/src/dep/repo.gleam",
      "pub type Repo {\n  Repo(find: fn(String) -> Int)\n}\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      dep_root <> "/dep.graded",
      "type dep/repo.Repo.find : [Storage]\n",
    )

  let assert Ok(Nil) = simplifile.create_directory_all(app_root)
  let assert Ok(Nil) =
    simplifile.write(
      app_root <> "/gleam.toml",
      "name = \"app\"\n\n[dependencies]\ndep = { path = \"../pd_ships_typefield_dep\" }\n",
    )
  let assert Ok(Nil) =
    simplifile.write(app_root <> "/app.graded", "check app.use_field : []\n")
  let assert Ok(Nil) =
    simplifile.write(
      app_root <> "/app.gleam",
      "import dep/repo.{type Repo}\n\n"
        <> "pub fn use_field(r: Repo) -> Int {\n  r.find(\"x\")\n}\n",
    )

  let assert Ok(results) = graded.run(app_root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == app_root <> "/app.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "use_field" })
  v.actual |> should.equal(types.Specific(set.from_list(["Storage"])))

  let _ = simplifile.delete(app_root)
  let _ = simplifile.delete(dep_root)
  Nil
}

pub fn installed_dep_ships_type_field_test() {
  // The reporter's primary case: a published (under `build/packages`) dependency
  // ships its own `type` field effects. The fixture lives under the gitignored
  // `build/` so its `build/packages` resolves package-root-relative — exercising
  // both the dependency-aware girard resolver (to type the receiver) and
  // dependency `type`-field loading (to resolve the field). The consumer writes
  // no annotation; `r.find(...)` must resolve to the dependency's [Storage].
  let root = "build/installed_typefield_fixture"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) =
    simplifile.create_directory_all(root <> "/build/packages/dep/src/dep")
  let assert Ok(Nil) =
    simplifile.write(root <> "/gleam.toml", "name = \"app\"\n")
  let assert Ok(Nil) =
    simplifile.write(root <> "/app.graded", "check app.use_field : []\n")
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/build/packages/dep/src/dep/repo.gleam",
      "pub type Repo {\n  Repo(find: fn(String) -> Int)\n}\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/build/packages/dep/dep.graded",
      "type dep/repo.Repo.find : [Storage]\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/app.gleam",
      "import dep/repo.{type Repo}\n\n"
        <> "pub fn use_field(r: Repo) -> Int {\n  r.find(\"x\")\n}\n",
    )

  let assert Ok(results) = graded.run(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "use_field" })
  v.actual |> should.equal(types.Specific(set.from_list(["Storage"])))

  let _ = simplifile.delete(root)
  Nil
}

pub fn provenance_passthrough_resolves_test() {
  // provenance_passthrough.caller passes `id_options(Options(resolver:
  // resolver))` to `inner`. `id_options` returns its whole parameter
  // (`Passthrough`), so `o.resolver` forwards onto the caller's `resolver` and
  // the `resolver: [Stdout]` bound discharges it — the [] budget fails with
  // [Stdout], not the [Unknown] an untraced call result would collapse to.
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_passthrough.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_getter_resolves_test() {
  // provenance_getter.caller (the headline case) passes `get_options(Config(..))`
  // to `inner`. `get_options` returns `config.options` (a `Path`), so `o.resolver`
  // forwards through the getter's path onto the caller's `resolver` and the
  // bound discharges it to [Stdout].
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_getter.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_rebuild_resolves_test() {
  // provenance_rebuild.caller passes `normalize(Options(resolver: resolver))` to
  // `inner`. `normalize` rebuilds `Options(resolver: o.resolver)` (a `Build`), so
  // `o.resolver` forwards onto the caller's `resolver` and the bound discharges
  // it to [Stdout]. The rebuild's own receiver-path wiring registers a
  // conservative [Unknown] source on the field, so the result carries both — the
  // mixed-site shape of factory_forward.mixed_caller. The [Stdout] is what proves
  // the forwarding fired (before Phase 1 the receiver was wholly [Unknown]).
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_rebuild.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout", "Unknown"])))
}

pub fn provenance_partial_build_resolves_test() {
  // provenance_partial.caller passes `normalize(Options(label: "", resolver:
  // resolver))` to `inner`. `normalize` rebuilds `Options(label: "", resolver:
  // o.resolver)` — a partial `Build` that keeps `resolver` and drops the literal
  // `label` — so `o.resolver` forwards onto the caller's `resolver` and the bound
  // discharges to [Stdout], where the all-or-nothing build left it [Unknown].
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_partial.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout", "Unknown"])))
}

pub fn provenance_labeled_resolves_test() {
  // provenance_labeled.caller passes `rebuild(with: Options(resolver: resolver))`
  // to `inner`. `rebuild` is a `Passthrough`, but the call labels its argument
  // (`with:`), so grounding reorders it into parameter-position order via the
  // callee signature before substituting. The constructed `Options` forwards
  // through, `o.resolver` re-keys onto the caller's `resolver`, and the bound
  // discharges to [Stdout] — where before the labeled call site widened to
  // [Unknown].
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_labeled.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_labeled_reorder_maps_position_test() {
  // Adversarial reorder: `wrap(tag first: Int, opts second: Options)` returns its
  // second parameter, and the call labels the arguments out of textual order
  // (`wrap(opts: Options(..), tag: 0)`). Grounding must route the `opts:` label to
  // position 1 — where the `Passthrough` reads — not to its textual position 0 (an
  // `Int` that wouldn't forward). It resolves to [Stdout], proving the label maps
  // to the declared position rather than the call-site order.
  let root = "build/provenance_labeled_reorder"
  let results =
    run_project_with_spec(
      root,
      "pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn inner(o: Options) -> Nil {
  o.resolver()
}

fn wrap(tag first: Int, opts second: Options) -> Options {
  let _ = first
  second
}

pub fn caller(resolver: fn() -> Nil) -> Nil {
  inner(wrap(opts: Options(resolver: resolver), tag: 0))
}
",
      "check proj.caller(resolver: [Stdout]) : []\n",
    )
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/proj.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_binding_resolves_test() {
  // provenance_binding.caller passes `alias(Options(resolver: resolver))` to
  // `inner`. `alias` threads its parameter through a `let` before returning it,
  // so the provenance walk folds through the binding to a `Passthrough`. The
  // constructed `Options` forwards through, `o.resolver` re-keys onto the
  // caller's `resolver`, and the bound discharges to [Stdout] — proving
  // provenance survives the binding rather than widening at it.
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_binding.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_recursion_resolves_test() {
  // provenance_recursion.caller passes `pick(True, Options(resolver: resolver))`
  // to `inner`. `pick` returns its `o` parameter through a tail-recursive call,
  // so its provenance is the fixpoint of the `case` join — both branches pass `o`
  // through, converging to a `Passthrough`. The constructed `Options` forwards
  // through, `o.resolver` re-keys onto the caller's `resolver`, and the bound
  // discharges to [Stdout] — where a naive walk widened on the recursion.
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_recursion.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_branch_resolves_test() {
  // provenance_branch.caller passes `pick(..)` to `inner`. `pick` returns a
  // `case` over its `a`/`b` parameters, so its provenance is a `Join` of two
  // `Passthrough`s. The join grounds each branch and forwards `o.resolver` onto
  // the caller's `resolver` through both, discharging the bound to [Stdout] —
  // where before value-level joins it was [Unknown].
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_branch.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_computed_deep_stays_unknown_test() {
  // provenance_computed_deep.caller passes `deep(resolver)` to `inner`. `deep`'s
  // return is a nested call (`get(make(resolver))`), whose provenance is
  // `Opaque` (no helper-call composition in Phase 1), so it stays [Unknown].
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_computed_deep.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn provenance_external_stays_unknown_test() {
  // provenance_external.caller passes `load_options(resolver)` to `inner`.
  // `load_options` is an external with no visible body, so its provenance can't
  // be traced and the field call concretizes to [Unknown].
  let assert Ok(results) = graded.run("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_external.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(types.Specific(set.from_list(["Unknown"])))
}
