import filepath
import glance
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import gleeunit/should
import graded
import graded/internal/annotation
import graded/internal/checker
import graded/internal/cli
import graded/internal/config
import graded/internal/effect_term
import graded/internal/effects
import graded/internal/signatures
import graded/internal/types.{type EffectTerm}
import simplifile
import support

// Baseline fixture checks
//
// End-to-end runs over test/fixtures: pure views and recursive helpers pass
// their [] budgets, while impure and transitively impure callers fail them.

pub fn pure_view_passes_test() {
  let assert Ok(results) = graded.check_project("test/fixtures")
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
  let assert Ok(results) = graded.check_project("test/fixtures")
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
  let assert Ok(results) = graded.check_project("test/fixtures")
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
  // the `check run : []` budget with an unresolved effect from the function
  // returned by `pick`.
  //
  // Covers both the first-order producer (`pick`/`run`, returning `fn() -> Nil`)
  // and the second-order one (`pick_cb`/`run_cb`, returning a callback-taking
  // `fn(fn() -> Nil) -> Nil`) — the latter exercises the neutral operator's
  // binder over the callback position rather than a ground pure.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let result =
    list.find(results, fn(r) {
      r.file == "test/fixtures/recursive_returned_operator.gleam"
    })
  let assert Ok(r) = result
  r.violations |> should.equal([])
}

pub fn impure_view_fails_test() {
  let assert Ok(results) = graded.check_project("test/fixtures")
  let impure_result =
    list.find(results, fn(r) { r.file == "test/fixtures/impure_view.gleam" })
  let assert Ok(r) = impure_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("view")
  v.explanation.call.function |> should.equal("println")
}

pub fn transitive_violation_detected_test() {
  let assert Ok(results) = graded.check_project("test/fixtures")
  let trans_result =
    list.find(results, fn(r) { r.file == "test/fixtures/transitive.gleam" })
  let assert Ok(r) = trans_result
  { r.violations != [] } |> should.be_true()
}

// Field calls on constructed receivers
//
// Function-typed fields wired at a visible construction site — a local
// binding, a factory, an inline construction, or several distinct sites —
// resolve to the wired effect instead of [Unknown].

pub fn validator_flow_violation_detected_test() {
  // validator_flow.run constructs a Validator locally and calls its
  // field. The field is wired to io.println so the run function's
  // effects are [Stdout] — the check budget of [] must fail.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let validator_result =
    list.find(results, fn(r) { r.file == "test/fixtures/validator_flow.gleam" })
  let assert Ok(r) = validator_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.explanation.call.function |> should.equal("println")
}

pub fn factory_field_violation_detected_test() {
  // factory_field.run binds its Validator from make(io.println), a *factory*
  // that wires the field to its parameter. With no `type` annotation, factory
  // field provenance resolves v.to_error to io.println's [Stdout], so the []
  // check budget must fail. (B1: the escape-hatch annotation is unnecessary.)
  let assert Ok(results) = graded.check_project("test/fixtures")
  let factory_result =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_field.gleam" })
  let assert Ok(r) = factory_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.explanation.call.function |> should.equal("println")
}

pub fn inline_construction_field_resolves_through_construction_test() {
  // inline_construction_field.run calls a function-typed field directly on an
  // *inline, un-let-bound* construction: `Validator(to_error: io.println)
  // .to_error("oops")`. The field is wired to io.println right at the
  // construction, so resolving the field call through the receiver's type and
  // construction provenance yields the precise [Stdout] — not the conservative
  // [Unknown] of an untraceable receiver. Reporting it as [] would be unsound,
  // so the [] budget must still fail, now with actual [Stdout].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/inline_construction_field.gleam"
    })
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn field_union_polymorphic_on_param_receiver_test() {
  // field_union.run calls a function-typed field on a *parameter* receiver
  // (`p: Parser`). The field's package-wide construction sites (pure + printing)
  // are nominal evidence that must never resolve a parameter receiver — a caller
  // can supply any Parser. So the call stays polymorphic: `run` infers the field
  // bound `p.run` and, with no bound supplied on the `check` line, grounds to
  // [Unknown]. A caller that supplies a concrete `Parser` (a proven construction)
  // resolves it precisely instead.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let union_result =
    list.find(results, fn(r) { r.file == "test/fixtures/field_union.gleam" })
  let assert Ok(r) = union_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

// External functions
//
// Bodyless @external functions infer [Unknown] unless an `assume`
// declaration supplies the real effect.

pub fn external_is_unknown_test() {
  // A bodyless `@external` (opaque FFI) is inferred `[Unknown]`, not `[]`, and
  // `run` — which calls it — inherits that. Against a `[]` budget this must be a
  // violation with actual `[Unknown]`. Without the fix the FFI (and its caller)
  // would be `[]` and the check would pass — a soundness hole.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let ffi_result =
    list.find(results, fn(r) { r.file == "test/fixtures/ffi_external.gleam" })
  let assert Ok(r) = ffi_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn external_same_module_declared_effects_test() {
  // A same-module (unqualified) call into a bodyless `@external` that carries an
  // `assume` declaration inherits the DECLARED effects, not the
  // `[Unknown]` an undeclared external yields. `read_clock` calls `now()` bare,
  // so against a `[]` budget the actual must be the declared `[Time]`. Without
  // the fix the local path bypassed the knowledge base and reported `[Unknown]`.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let same_module_result =
    list.find(results, fn(r) {
      r.file == "test/fixtures/external_same_module.gleam"
    })
  let assert Ok(r) = same_module_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("read_clock")
  v.explanation.actual |> should.equal(types.Specific(set.from_list(["Time"])))
}

pub fn check_line_on_an_external_checks_its_declaration_test() {
  // A `check` line on the external *itself*. There is no body to check it
  // against, so the budget is checked against what declares the external: the
  // spec's `assume [Time]` exceeds a `[]` budget, and an external
  // nothing declares carries `[Unknown]`, which exceeds it too — including the
  // one whose pure-looking Gleam fallback body would otherwise pass it. A budget
  // that covers the declaration passes.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/external_budget.gleam" })
  r.violations
  |> list.map(fn(v) { v.function })
  |> list.sort(string.compare)
  |> should.equal([
    "calls_wired_external", "declared_over_budget",
    "passes_external_as_callback", "stale_inferred", "undeclared", "wrapper",
  ])
  let assert Ok(declared) =
    list.find(r.violations, fn(v) { v.function == "declared_over_budget" })
  declared.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Time"])))
  let assert Ok(undeclared) =
    list.find(r.violations, fn(v) { v.function == "undeclared" })
  undeclared.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn a_committed_effects_line_does_not_declare_an_external_test() {
  // A `check` line on an external the spec carries an ordinary `effects` line
  // for — what a Gleam function that later became an `@external` leaves behind.
  // Inference over a body says nothing about foreign code, so the line declares
  // nothing and the budget is checked against `[Unknown]`; trusting its `[]`
  // would pass a budget no declaration backs.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/external_budget.gleam" })
  let assert Ok(stale) =
    list.find(r.violations, fn(v) { v.function == "stale_inferred" })
  stale.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  stale.explanation.reason |> should.equal(Some(types.UndeclaredExternal))
  // No source is named: the committed line is not the answer, so crediting it
  // would point at a line that proves nothing.
  stale.explanation.origin |> should.equal(None)
}

pub fn a_caller_of_an_external_is_charged_what_declares_it_test() {
  // The caller of an external the spec carries a stale `effects` line for. The
  // line does not answer for the external, so it may not answer for a call into
  // it either: the caller is charged the same `[Unknown]`, not the `[]` that
  // would let a budget pass on the strength of a line nothing backs.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/external_budget.gleam" })
  let assert Ok(wrapper) =
    list.find(r.violations, fn(v) { v.function == "wrapper" })
  wrapper.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  wrapper.explanation.reason |> should.equal(Some(types.UndeclaredExternal))
  wrapper.explanation.origin |> should.equal(None)
  // The same call, from the other side of a module boundary.
  let root = "build/external_cross_module_caller"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "check app.wrapper : []\neffects ffi.clock : []\n"),
    #(
      "ffi.gleam",
      "@external(erlang, \"ffi_module\", \"clock\")\npub fn clock() -> Nil\n",
    ),
    #(
      "app.gleam",
      "import ffi\n\npub fn wrapper() -> Nil {\n  ffi.clock()\n}\n",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  violation.explanation.reason |> should.equal(Some(types.UndeclaredExternal))
  support.cleanup(root)
}

pub fn an_external_passed_as_a_value_is_charged_what_declares_it_test() {
  // The external reached as a *value* rather than through a call: handed to a
  // higher-order helper, and wired into a record field. Both resolve it through
  // the same declaration a direct call goes through, so both carry `[Unknown]`.
  // Walking the bodyless `@external` instead would lift it to `[]` and let a
  // budget pass here that `wrapper`'s direct call fails.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/external_budget.gleam" })
  let assert Ok(callback) =
    list.find(r.violations, fn(v) {
      v.function == "passes_external_as_callback"
    })
  callback.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  let assert Ok(wired) =
    list.find(r.violations, fn(v) { v.function == "calls_wired_external" })
  wired.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn a_cross_module_external_callback_is_charged_its_declaration_test() {
  // The callback case across a module boundary, where the external is a
  // qualified reference resolved through the knowledge base rather than a
  // same-module name. The stale `effects ffi.clock : []` does not answer for
  // foreign code, so it may not answer for a function value naming it either.
  let root = "build/external_callback_cross_module"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "check app.wrapper : []\neffects ffi.clock : []\n"),
    #(
      "ffi.gleam",
      "@external(erlang, \"ffi_module\", \"clock\")\npub fn clock() -> Nil\n",
    ),
    #(
      "app.gleam",
      "import ffi

pub fn apply_callback(f: fn() -> Nil) -> Nil {
  f()
}

pub fn wrapper() -> Nil {
  apply_callback(ffi.clock)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  support.cleanup(root)
}

// Bounded assume lines
//
// A bound list on an `assume` line carries substitution scaffolding for a
// foreign higher-order function: a bound's name matches a call-site argument,
// and its payload's free variables are the keys the argument's effects bind.
// Nothing verifies the declaration itself — that stays what `assume` means.

pub fn a_bounded_assume_charges_the_arguments_effects_test() {
  // `assume ffi.each(f: [f]) : [f]`: the caller accrues the argument's actual
  // effects, not `[]` — parity of substitution with a bounded `effects` line.
  let root = "build/bounded_assume_substitution"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.run : []\nassume ffi.each(f: [f]) : [f]\nassume ffi.disk_read : [Disk]\n",
    ),
    #(
      "ffi.gleam",
      support.foreign_fn("each", "(f: fn() -> Nil) -> Nil")
        <> "\n"
        <> support.foreign_fn("disk_read", "() -> Nil"),
    ),
    #(
      "app.gleam",
      "import ffi\n\npub fn run() -> Nil {\n  ffi.each(ffi.disk_read)\n}\n",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_decoupled_bound_name_still_binds_test() {
  // `assume ffi.map(g: [e]) : [e]`: a bound contributes through its payload's
  // free variables, so `e` needn't name the bound to be a substitution key.
  let root = "build/bounded_assume_decoupled_name"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.run : []\nassume ffi.map(g: [e]) : [e]\nassume ffi.disk_read : [Disk]\n",
    ),
    #(
      "ffi.gleam",
      support.foreign_fn("map", "(g: fn() -> Nil) -> Nil")
        <> "\n"
        <> support.foreign_fn("disk_read", "() -> Nil"),
    ),
    #(
      "app.gleam",
      "import ffi\n\npub fn run() -> Nil {\n  ffi.map(ffi.disk_read)\n}\n",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_ground_budget_on_an_assume_is_inert_test() {
  // `assume ffi.each(f: [Disk]) : []` beside a tracked argument that prints:
  // nothing checks the argument against the budget, and nothing propagates its
  // effects — the caller is charged the declared `[]`. The argument is a named
  // function reference, since an inline closure's body is walked by the
  // extractor and would charge the caller regardless of the declaration.
  let root = "build/bounded_assume_inert_budget"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.run : []\nassume ffi.each(f: [Disk]) : []\nassume ffi.log : [Stdout]\n",
    ),
    #(
      "ffi.gleam",
      support.foreign_fn("each", "(f: fn() -> Nil) -> Nil")
        <> "\n"
        <> support.foreign_fn("log", "() -> Nil"),
    ),
    #(
      "app.gleam",
      "import ffi\n\npub fn run() -> Nil {\n  ffi.each(ffi.log)\n}\n",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  r.violations |> should.equal([])
  support.cleanup(root)
}

pub fn a_dependency_specs_bounded_assume_substitutes_test() {
  // The same substitution one package boundary away: the dependency ships the
  // bounded declaration in its spec, and the consumer's call site binds the
  // bound to its own argument.
  let root =
    support.write_project_with_dependency(
      directory: "build/bounded_assume_dep_spec",
      package: "proj",
      spec: "check app.run : []\n",
      sources: [
        #(
          "app.gleam",
          "import dep/ffi\n\npub fn run() -> Nil {\n  ffi.each(ffi.disk_read)\n}\n",
        ),
      ],
      dependency: "dep",
      dependency_spec: "assume dep/ffi.each(f: [f]) : [f]\nassume dep/ffi.disk_read : [Disk]\n",
      dependency_sources: [
        #(
          "dep/ffi.gleam",
          support.foreign_fn("each", "(f: fn() -> Nil) -> Nil")
            <> "\n"
            <> support.foreign_fn("disk_read", "() -> Nil"),
        ),
      ],
    )
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn infer_binds_a_decoupled_assume_bound_test() {
  // The declaring line's bounds ride the same fold as its term, so `infer`
  // resolves them exactly as `check` does: the decoupled `e` binds the
  // argument's `[Disk]`, and the published line carries no `[Unknown]` from a
  // variable nothing bound.
  let root = "build/bounded_assume_infer"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ffi.map(g: [e]) : [e]\nassume ffi.disk_read : [Disk]\n",
    ),
    #(
      "ffi.gleam",
      support.foreign_fn("map", "(g: fn() -> Nil) -> Nil")
        <> "\n"
        <> support.foreign_fn("disk_read", "() -> Nil"),
    ),
    #(
      "app.gleam",
      "import ffi\n\npub fn run() -> Nil {\n  ffi.map(ffi.disk_read)\n}\n",
    ),
  ])
  let assert Ok(preview) = graded.run_infer_dry_run(root)
  preview |> string.contains("effects app.run : [Disk]") |> should.be_true()
  preview |> string.contains("Unknown") |> should.be_false()
  support.cleanup(root)
}

pub fn a_consumer_assume_overrides_a_dependency_bound_list_test() {
  // The consumer's line wins the term, and its bounds win with it: paired
  // with the dependency's `f: [f]` instead, the consumer's decoupled `x`
  // would bind nothing and charge a pure callback `[Unknown]`.
  let root =
    support.write_project_with_dependency(
      directory: "build/bounded_assume_consumer_override",
      package: "proj",
      spec: "assume dep/ffi.each(f: [x]) : [x]\ncheck app.run : []\n",
      sources: [
        #(
          "app.gleam",
          "import dep/ffi\n\nfn pure_cb() -> Nil {\n  Nil\n}\n\npub fn run() -> Nil {\n  ffi.each(pure_cb)\n}\n",
        ),
      ],
      dependency: "dep",
      dependency_spec: "assume dep/ffi.each(f: [f]) : [f]\n",
      dependency_sources: [
        #(
          "dep/ffi.gleam",
          support.foreign_fn("each", "(f: fn() -> Nil) -> Nil"),
        ),
      ],
    )
  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])
  support.cleanup(root)
}

pub fn a_bounded_assume_over_a_running_fallback_binds_its_own_bounds_test() {
  // A target-conditional external whose Gleam fallback also runs, under a
  // bounded `assume`: the line suppresses the fallback half, so the charge is
  // the declared term alone and the call site binds through the line's own
  // bound list — the decoupled `e` through the `action` payload that names
  // it. With the line's list standing down, `e` stayed free and a pure
  // callback was charged the `[Unknown]` it grounds to.
  let root = "build/bounded_assume_running_fallback"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.run(action: [e]) : [e]
assume ext.disk : [Disk]
check app.go : []
check app.go_impure : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(action: fn() -> Nil) -> Nil {
  action()
}

@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
pub fn disk() -> Nil
",
    ),
    #(
      "app.gleam",
      "import ext

fn pure_cb() -> Nil {
  Nil
}

pub fn go() -> Nil {
  ext.run(pure_cb)
}

pub fn go_impure() -> Nil {
  ext.run(ext.disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("go_impure")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_suppressed_charge_binds_through_the_declared_bounds_alone_test() {
  // `assume ext.run(cb: [other]) : [other]` beside a running fallback whose
  // *parameter* is also named `other`: the line suppresses the fallback half,
  // so its variable means the `cb` argument its own payload binds and nothing
  // else — the fallback's `other()` call is no longer charged through the
  // `other` parameter. Only the caller handing `[Disk]` through the declared
  // half fails its `[]` budget; the one reaching the disk through the
  // suppressed body's parameter passes on the line's say-so.
  let root = "build/bounded_assume_half_namespaces"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.run(cb: [other]) : [other]
assume ext.disk : [Disk]
assume ext.noop : []
check app.fallback_disk : []
check app.decl_disk : []
check app.both_pure : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(cb: fn() -> Nil, other: fn() -> Nil) -> Nil {
  other()
}

@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
pub fn disk() -> Nil

@external(erlang, \"n\", \"n\")
@external(javascript, \"n\", \"n\")
pub fn noop() -> Nil
",
    ),
    #(
      "app.gleam",
      "import ext

pub fn fallback_disk() -> Nil {
  ext.run(ext.noop, ext.disk)
}

pub fn decl_disk() -> Nil {
  ext.run(ext.disk, ext.noop)
}

pub fn both_pure() -> Nil {
  ext.run(ext.noop, ext.noop)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("decl_disk")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_declared_clause_closed_by_its_bounds_binds_test() {
  // The decorator shape: an `@external` producer whose returned closure runs
  // the callback it was handed. The clause's variable is scoped by the line's
  // own bound list, and a caller invoking the returned closure is charged the
  // argument's actual effects.
  let root = "build/bounded_assume_decorator"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.run : []\nassume ffi.wrap(cb: [cb]) : [] where returns : [cb]\nassume ffi.disk_read : [Disk]\n",
    ),
    #(
      "ffi.gleam",
      support.foreign_fn("wrap", "(cb: fn() -> Nil) -> fn() -> Nil")
        <> "\n"
        <> support.foreign_fn("disk_read", "() -> Nil"),
    ),
    #(
      "app.gleam",
      "import ffi\n\npub fn run() -> Nil {\n  let f = ffi.wrap(ffi.disk_read)\n  f()\n}\n",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_clause_only_bounded_declaration_binds_test() {
  // No effects claim at all, so the name has no params-channel entry — the
  // bounds ride the declared summary alone, and the clause still binds. The
  // producer call itself stays `[Unknown]` (nothing declares its effects),
  // which is what shows the `[Disk]` half came through the clause.
  let root = "build/bounded_assume_clause_only"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.run : []\nassume ffi.wrap(cb: [cb]) where returns : [cb]\nassume ffi.disk_read : [Disk]\n",
    ),
    #(
      "ffi.gleam",
      support.foreign_fn("wrap", "(cb: fn() -> Nil) -> fn() -> Nil")
        <> "\n"
        <> support.foreign_fn("disk_read", "() -> Nil"),
    ),
    #(
      "app.gleam",
      "import ffi\n\npub fn run() -> Nil {\n  let f = ffi.wrap(ffi.disk_read)\n  f()\n}\n",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  // The producer call itself reports its own undeclared-external row; the
  // returned closure's invocation is the one the clause resolves.
  let assert Ok(returned) =
    list.find(r.violations, fn(v) { v.explanation.call.module == "<returned>" })
  returned.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_decoupled_bound_scoping_a_clause_binds_by_parameter_name_test() {
  // `assume ffi.wrap(cb: [e]) : [] where returns : [cb]`: the bound's payload
  // names `e`, and the clause variable `cb` — a bound *name* no payload binds —
  // gets the synthesized self-referential binding, so it binds by parameter
  // name instead of collapsing to `[Unknown]` after passing the gate.
  let root = "build/bounded_assume_decoupled_clause"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.run : []\nassume ffi.wrap(cb: [e]) : [] where returns : [cb]\nassume ffi.disk_read : [Disk]\n",
    ),
    #(
      "ffi.gleam",
      support.foreign_fn("wrap", "(cb: fn() -> Nil) -> fn() -> Nil")
        <> "\n"
        <> support.foreign_fn("disk_read", "() -> Nil"),
    ),
    #(
      "app.gleam",
      "import ffi\n\npub fn run() -> Nil {\n  let f = ffi.wrap(ffi.disk_read)\n  f()\n}\n",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn an_aliased_payload_does_not_capture_a_clause_variable_test() {
  // `assume ffi.wrap(cb: [e], other: [cb]) : [] where returns : [cb]`: the
  // clause's `cb` names the parameter `cb` even though `other`'s payload
  // reuses the name, so the returned closure is charged the `[Disk]` handed
  // as `cb` — not the pure `other` whose payload happens to bind `cb` too.
  let root = "build/bounded_assume_aliased_payload"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.run : []\nassume ffi.wrap(cb: [e], other: [cb]) : [] where returns : [cb]\nassume ffi.disk_read : [Disk]\nassume ffi.noop : []\n",
    ),
    #(
      "ffi.gleam",
      support.foreign_fn(
        "wrap",
        "(cb: fn() -> Nil, other: fn() -> Nil) -> fn() -> Nil",
      )
        <> "\n"
        <> support.foreign_fn("disk_read", "() -> Nil")
        <> "\n"
        <> support.foreign_fn("noop", "() -> Nil"),
    ),
    #(
      "app.gleam",
      "import ffi\n\npub fn run() -> Nil {\n  let f = ffi.wrap(ffi.disk_read, ffi.noop)\n  f()\n}\n",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn an_unscoped_declared_clause_is_dropped_test() {
  // `returns : [zz]` on a line whose bounds name only `cb`: the loader drops
  // the clause, the returned closure resolves `[Unknown]`, and `check` reports
  // it open.
  let root = "build/bounded_assume_unscoped_clause"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.run : []\nassume ffi.wrap(cb: [cb]) : [] where returns : [zz]\n",
    ),
    #(
      "ffi.gleam",
      support.foreign_fn("wrap", "(cb: fn() -> Nil) -> fn() -> Nil"),
    ),
    #(
      "app.gleam",
      "import ffi\n\npub fn run() -> Nil {\n  let f = ffi.wrap(fn() { Nil })\n  f()\n}\n",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  support.cleanup(root)
}

pub fn a_dotted_variable_in_a_declared_clause_is_dropped_test() {
  // A dotted variable rides the field-bound story a foreign producer doesn't
  // have: the strict base rejects it — no `Closed`-path leniency leaks in —
  // and the clause is dropped.
  let root = "build/bounded_assume_dotted_clause"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.run : []\nassume ffi.wrap(cb: [cb]) : [] where returns : [config.run]\n",
    ),
    #(
      "ffi.gleam",
      support.foreign_fn("wrap", "(cb: fn() -> Nil) -> fn() -> Nil"),
    ),
    #(
      "app.gleam",
      "import ffi\n\npub fn run() -> Nil {\n  let f = ffi.wrap(fn() { Nil })\n  f()\n}\n",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  support.cleanup(root)
}

pub fn differing_bounds_on_the_two_channels_each_bind_their_own_test() {
  // One line declares the effects with its bounds (feeding the params
  // channel), a second clause-only line carries different bounds for its
  // clause: the term binds against the channel entry, the clause against the
  // summary's own carried bounds — never mixed.
  let root = "build/bounded_assume_differing_bounds"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.run : []\nassume ffi.wrap(cb: [e]) : [e]\nassume ffi.wrap(cb: [Stdout]) where returns : [cb]\nassume ffi.disk_read : [Disk]\n",
    ),
    #(
      "ffi.gleam",
      support.foreign_fn("wrap", "(cb: fn() -> Nil) -> fn() -> Nil")
        <> "\n"
        <> support.foreign_fn("disk_read", "() -> Nil"),
    ),
    #(
      "app.gleam",
      "import ffi\n\npub fn run() -> Nil {\n  let f = ffi.wrap(ffi.disk_read)\n  f()\n}\n",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert Ok(direct) =
    list.find(r.violations, fn(v) { v.explanation.call.module == "ffi" })
  direct.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  let assert Ok(returned) =
    list.find(r.violations, fn(v) { v.explanation.call.module == "<returned>" })
  returned.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_same_module_declared_decorator_uses_its_carried_bounds_test() {
  // The producer is an own `@external` whose callback parameter is typed
  // through an alias, declared with a decoupled bound, and called from its own
  // module: the alias-blind registry can't derive the bound, so only the
  // carried bounds supply `cb`, and only the hoisted synthesis binds it.
  let root = "build/bounded_assume_same_module"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check ffi.run : []\nassume ffi.wrap(cb: [e]) : [] where returns : [cb]\nassume ffi2.disk_read : [Disk]\n",
    ),
    #("ffi2.gleam", support.foreign_fn("disk_read", "() -> Nil")),
    #(
      "helper.gleam",
      "import ffi2\n\npub fn noisy() -> Nil {\n  ffi2.disk_read()\n}\n",
    ),
    #(
      "ffi.gleam",
      "import helper

pub type Cb =
  fn() -> Nil

@external(erlang, \"m\", \"wrap\")
@external(javascript, \"m\", \"wrap\")
pub fn wrap(cb: Cb) -> fn() -> Nil

pub fn run() -> Nil {
  let f = wrap(helper.noisy)
  f()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ffi.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("run")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_dependency_specs_declared_decorator_binds_test() {
  // The decorator declaration shipped in a dependency's spec: the consumer's
  // call site binds the clause against the dependency line's own bounds.
  let root =
    support.write_project_with_dependency(
      directory: "build/bounded_assume_dep_decorator",
      package: "proj",
      spec: "check app.run : []\n",
      sources: [
        #(
          "app.gleam",
          "import dep/ffi\n\npub fn run() -> Nil {\n  let f = ffi.wrap(ffi.disk_read)\n  f()\n}\n",
        ),
      ],
      dependency: "dep",
      dependency_spec: "assume dep/ffi.wrap(cb: [cb]) : [] where returns : [cb]\nassume dep/ffi.disk_read : [Disk]\n",
      dependency_sources: [
        #(
          "dep/ffi.gleam",
          support.foreign_fn("wrap", "(cb: fn() -> Nil) -> fn() -> Nil")
            <> "\n"
            <> support.foreign_fn("disk_read", "() -> Nil"),
        ),
      ],
    )
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_closed_clause_with_a_decoupled_bound_binds_by_parameter_name_test() {
  // The hand-written `Closed` counterpart of the decoupled-clause case:
  // `effects dep/prod.make(cb: [e]) : [] where returns : [cb]` in a shipped
  // spec. The synthesis fix lives on the shared summary-bounds path, so the
  // clause variable binds by parameter name here exactly as it does for a
  // declared summary.
  let root =
    support.write_project_with_dependency(
      directory: "build/bounded_closed_decoupled",
      package: "proj",
      spec: "check app.run : []\n",
      sources: [
        #(
          "app.gleam",
          "import dep/ffi\nimport dep/prod\n\npub fn run() -> Nil {\n  let f = prod.make(ffi.disk_read)\n  f()\n}\n",
        ),
      ],
      dependency: "dep",
      dependency_spec: "assume dep/ffi.disk_read : [Disk]\neffects dep/prod.make(cb: [e]) : [] where returns : [cb]\n",
      dependency_sources: [
        #(
          "dep/prod.gleam",
          "pub fn make(cb: fn() -> Nil) -> fn() -> Nil {\n  fn() { cb() }\n}\n",
        ),
        #("dep/ffi.gleam", support.foreign_fn("disk_read", "() -> Nil")),
      ],
    )
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_target_conditional_fallback_body_is_checked_test() {
  // An `@external` covering one target only: on the other, its Gleam body is
  // what runs. The declaration answers for callers, but the body is ordinary
  // code nothing else weighs, so the budget covers both — a fallback that reads
  // the disk fails a `[]` budget its declaration alone would pass.
  let root = "build/external_target_fallback"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check ext.log : []\nassume ext.log : []\nassume ext.sink : [Disk]\n",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"log\")
pub fn log() -> Nil {
  sink()
}

@external(erlang, \"ext_ffi\", \"sink\")
@external(javascript, \"ext_ffi\", \"sink\")
fn sink() -> Nil
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("log")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_target_excluded_external_is_ordinary_gleam_test() {
  // `@target(erlang)` with a javascript-only `@external`: the foreign
  // implementation is never compiled, so the Gleam body is the only one that
  // exists and the function is ordinary Gleam on every channel. Weighing the
  // declaration beside it charged callers `[Unknown]` for code that is not
  // built — a false violation on a body plainly within its budget — and held
  // the values it hands back opaque for the same absent reason.
  let root = "build/external_target_excluded"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check ext.log : []
check ext.calls_built_field : [Disk]
assume ext.disk : [Disk]
",
    ),
    #(
      "ext.gleam",
      "pub type Handler {
  Handler(run: fn() -> Nil)
}

@external(erlang, \"ext_ffi\", \"disk\")
@external(javascript, \"ext_ffi\", \"disk\")
pub fn disk() -> Nil

@target(erlang)
@external(javascript, \"ext_ffi\", \"log\")
pub fn log() -> Nil {
  Nil
}

@target(erlang)
@external(javascript, \"ext_ffi\", \"builds\")
pub fn builds(run: fn() -> Nil) -> Handler {
  Handler(run: run)
}

@target(erlang)
pub fn calls_built_field() -> Nil {
  let handler = builds(fn() { disk() })
  handler.run()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  r.violations |> should.equal([])
  // And the query says what the body does, rather than the `[Unknown]` an
  // undeclared external carries.
  let assert Ok(answered) = graded.run_effect(root, "ext.log")
  answered |> string.contains("effects ext.log : []") |> should.be_true()
  support.cleanup(root)
}

pub fn a_package_target_excludes_a_declaration_too_test() {
  // The same carve-out as `@target`, stated once for the whole package:
  // `target = "javascript"` never compiles an `@external(erlang, …)`, so its
  // Gleam body is the only implementation that exists and the function is
  // ordinary Gleam. Reading `gleam.toml`'s field as no narrowing at all held
  // these functions foreign — charging callers the `[Unknown]` of an undeclared
  // external over a body plainly within its budget, and keeping the values they
  // hand back opaque for the same absent reason.
  let root = "build/package_target_excluded"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\ntarget = \"javascript\"\n"),
    #(
      "proj.graded",
      "check ext.log : []
check ext.calls_built_field : [Disk]
assume ext.disk : [Disk]
",
    ),
    #(
      "ext.gleam",
      "pub type Handler {
  Handler(run: fn() -> Nil)
}

@external(erlang, \"ext_ffi\", \"disk\")
@external(javascript, \"ext_ffi\", \"disk\")
pub fn disk() -> Nil

@external(erlang, \"ext_ffi\", \"log\")
pub fn log() -> Nil {
  Nil
}

@external(erlang, \"ext_ffi\", \"builds\")
pub fn builds(run: fn() -> Nil) -> Handler {
  Handler(run: run)
}

pub fn calls_built_field() -> Nil {
  let handler = builds(fn() { disk() })
  handler.run()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  r.violations |> should.equal([])
  // And the query says what the body does, rather than the `[Unknown]` an
  // undeclared external carries.
  let assert Ok(answered) = graded.run_effect(root, "ext.log")
  answered |> string.contains("effects ext.log : []") |> should.be_true()
  support.cleanup(root)
}

pub fn a_package_target_leaves_no_fallback_to_run_test() {
  // The other direction: `target = "erlang"` with an `@external(erlang, …)`
  // leaves no uncovered target, so the Gleam body beside it is dead text. It
  // was charged to every caller anyway — a `[Disk]` violation over a body that
  // is never compiled, decided by a `gleam.toml` field nothing read.
  let root = "build/package_target_covered"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\ntarget = \"erlang\"\n"),
    #(
      "proj.graded",
      "assume ffi.disk : [Disk]
assume ext.log : []
check ext.wrapper : []
",
    ),
    #(
      "ffi.gleam",
      "@external(erlang, \"d\", \"w\")\n@external(javascript, \"d\", \"w\")\npub fn disk() -> Nil\n",
    ),
    #(
      "ext.gleam",
      "import ffi

@external(erlang, \"e\", \"l\")
pub fn log() -> Nil {
  ffi.disk()
}

pub fn wrapper() -> Nil {
  log()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])
  support.cleanup(root)
}

pub fn a_function_built_for_no_target_stays_foreign_test() {
  // The two narrowings can leave nothing between them: `target = "erlang"` with
  // `@target(javascript)` builds the function on no channel at all, so Gleam
  // compiles neither implementation. Reading that empty set as the carve-out
  // above — "the declaration covers no compiled target, so the body is the only
  // implementation" — walked a body nobody runs: the `assume` line
  // was dropped as stale with a warning telling the author to fix source that
  // is correct, and `effect` answered with what the fallback does instead of
  // the `[Unknown]` of foreign code.
  let root = "build/external_no_compiled_target"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\ntarget = \"erlang\"\n"),
    #(
      "proj.graded",
      "assume ext.shout : [Stdout]
check ext.wrapper : [Stdout]
",
    ),
    #(
      "ext.gleam",
      "@target(javascript)
@external(javascript, \"ext_ffi\", \"shout\")
pub fn shout(message: String) -> Nil {
  Nil
}

@target(javascript)
pub fn wrapper() -> Nil {
  shout(\"x\")
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  // The declaration stands: no violation against the budget it states, and no
  // lint calling the line stale.
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])
  results |> list.flat_map(fn(r) { r.warnings }) |> should.equal([])
  // And the query answers with the declaration rather than the `[]` of a body
  // that is never built.
  let assert Ok(answered) = graded.run_effect(root, "ext.shout")
  answered
  |> string.contains("effects ext.shout : [Stdout]")
  |> should.be_true()
  support.cleanup(root)
}

pub fn a_running_fallback_body_is_charged_to_every_caller_test() {
  // The declaration alone is the whole story only where it covers every target.
  // Where it does not, the Gleam fallback is what runs, and composition is
  // union — so a caller inherits the declaration *and* that body, whether it
  // sits in the same module or another one. Charging only the declaration let a
  // `[]` budget pass over an external whose fallback reads the disk.
  let root = "build/external_fallback_callers"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ext : []
assume ext.sink : [Disk]
check ext.wrapper : []
check other.calls_it : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"log\")
pub fn log() -> Nil {
  sink()
}

@external(erlang, \"ext_ffi\", \"sink\")
@external(javascript, \"ext_ffi\", \"sink\")
fn sink() -> Nil

pub fn wrapper() -> Nil {
  log()
}
",
    ),
    #(
      "other.gleam",
      "import ext

pub fn calls_it() -> Nil {
  ext.log()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let disk = types.Specific(set.from_list(["Disk"]))

  let assert Ok(same_module) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  let assert Ok(wrapper) =
    list.find(same_module.violations, fn(v) { v.function == "wrapper" })
  wrapper.explanation.actual |> should.equal(disk)

  let assert Ok(cross_module) =
    list.find(results, fn(r) { r.file == root <> "/other.gleam" })
  let assert [calls_it] = cross_module.violations
  calls_it.explanation.actual |> should.equal(disk)

  // And every surface agrees on the one name: the query answers what the
  // callers are charged, rather than the declaration the fast path could see
  // without walking the body.
  let assert Ok(answered) = graded.run_effect(root, "ext.log")
  answered |> string.contains("[Disk]") |> should.be_true()
  support.cleanup(root)
}

pub fn a_fallback_reads_a_nested_external_on_its_own_targets_test() {
  // A fallback body runs on the targets its own declaration leaves uncovered,
  // and a target-conditional external it calls is reached there and nowhere
  // else. Two externals declared `@external(javascript, …)` are both Erlang
  // fallbacks, so `a`'s body calls `b`'s *body* — never the JavaScript
  // implementation `b`'s declaration describes. Reading the callee as the
  // package-wide union charged `a`, and every caller of it, a `[Disk]` no
  // implementation either of them reaches can perform.
  let root = "build/external_nested_target_conditional"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.a : []
assume ext.b : [Disk]
check ext.a : []
check ext.wrapper : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"b\")
pub fn b() -> Nil {
  Nil
}

@external(javascript, \"ext_ffi\", \"a\")
pub fn a() -> Nil {
  b()
}

pub fn wrapper() -> Nil {
  a()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  // Both walks of `a`'s body agree — the summary its callers are charged
  // through, and the walk its own `check` line performs.
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])
  let assert Ok(answered) = graded.run_effect(root, "ext.wrapper")
  answered |> string.contains("effects ext.wrapper : []") |> should.be_true()
  support.cleanup(root)
}

pub fn two_fallbacks_on_opposite_targets_do_not_mix_test() {
  // The same narrowing between two fallbacks of the *same* module whose active
  // targets are disjoint: `c` is declared for Erlang, so its body runs on
  // JavaScript alone, while `a` is declared for JavaScript and runs on Erlang.
  // On Erlang `a` reaches `c`'s Erlang implementation, which its declaration
  // answers for. Charging `c`'s summary there let a body that can only run on
  // JavaScript contaminate one that can only run on Erlang.
  let root = "build/external_disjoint_fallbacks"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.a : []
assume ext.c : []
assume ext.disk : [Disk]
check ext.wrapper : []
",
    ),
    #(
      "ext.gleam",
      "@external(erlang, \"ext_ffi\", \"disk\")
@external(javascript, \"ext_ffi\", \"disk\")
fn disk() -> Nil

@external(erlang, \"ext_ffi\", \"c\")
pub fn c() -> Nil {
  disk()
}

@external(javascript, \"ext_ffi\", \"a\")
pub fn a() -> Nil {
  c()
}

pub fn wrapper() -> Nil {
  a()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])
  // `c` itself is unchanged: an ordinary caller is compiled for both targets,
  // so it pays the declaration on one and that same body on the other.
  let assert Ok(answered) = graded.run_effect(root, "ext.c")
  answered |> string.contains("[Disk]") |> should.be_true()
  support.cleanup(root)
}

pub fn a_nested_external_still_charges_what_the_fallback_reaches_test() {
  // The narrowing sharpens only where the effect is unreachable. Both halves
  // still arrive where the fallback runs into them: `b`'s own Erlang fallback
  // touches the disk, and `d` declares an Erlang implementation that does —
  // each reached by `a`'s Erlang body, each charged to it and to its caller.
  let root = "build/external_nested_reachable"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext : []
assume ext.d : [Time]
assume ext.disk : [Disk]
check ext.wrapper : []
",
    ),
    #(
      "ext.gleam",
      "@external(erlang, \"ext_ffi\", \"disk\")
@external(javascript, \"ext_ffi\", \"disk\")
fn disk() -> Nil

@external(javascript, \"ext_ffi\", \"b\")
pub fn b() -> Nil {
  disk()
}

@external(erlang, \"ext_ffi\", \"d\")
pub fn d() -> Nil

@external(javascript, \"ext_ffi\", \"a\")
pub fn a() -> Nil {
  b()
  d()
}

pub fn wrapper() -> Nil {
  a()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  let assert Ok(violation) =
    list.find(r.violations, fn(v) { v.function == "wrapper" })
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk", "Time"])))
  support.cleanup(root)
}

pub fn a_girard_typed_fallback_callback_binds_in_the_same_module_test() {
  // The fallback's parameter carries no `fn(...)` annotation — only girard
  // knows it is function-typed, so its bound exists only as the one recorded
  // beside the settled summary. A same-module `run(pure_cb)` substituted with
  // syntax-derived bounds alone, found none, and kept `[action]` free — failing
  // a `[]` budget the qualified call from another module passed. The local path
  // now substitutes with the recorded bounds, and the effectful callback still
  // fails, so the bound resolves rather than vanishing.
  let root = "build/external_fallback_girard_local"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext : []
assume ext.disk : [Disk]
check ext.uses : []
check ext.uses_impure : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(action) -> Nil {
  action()
}

@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
pub fn disk() -> Nil

fn pure_cb() -> Nil {
  Nil
}

pub fn uses() -> Nil {
  run(pure_cb)
}

pub fn uses_impure() -> Nil {
  run(disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("uses_impure")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_girard_typed_sibling_fallback_rekeys_its_callback_test() {
  // `a`'s fallback forwards its callback into sibling fallback `b`, and both
  // parameters are girard-typed only. Settling installed each summary's term
  // without its bounds, so the pass walking `a` had nothing to re-key `b`'s
  // `action` onto `a`'s `callback` — the variable leaked into `a`'s summary and
  // a cross-module `ext.a(pure)` failed a `[]` budget it plainly meets.
  let root = "build/external_fallback_girard_siblings"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.a : []
assume ext.b : []
check app.go : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"b\")
pub fn b(action) -> Nil {
  action()
}

@external(javascript, \"ext_ffi\", \"a\")
pub fn a(callback) -> Nil {
  b(callback)
}
",
    ),
    #(
      "app.gleam",
      "import ext

fn pure_cb() -> Nil {
  Nil
}

pub fn go() -> Nil {
  ext.a(pure_cb)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])
  support.cleanup(root)
}

pub fn a_girard_typed_fallback_lifts_as_an_operator_test() {
  // `run`'s callback parameter is girard-typed only, and `run` travels as a
  // *value* into a higher-order `invoke` that applies it. The lift abstracted
  // over syntactically fn-typed parameters alone, so the summary's `action`
  // variable stayed free, the application went stuck, and a `[]` budget the
  // pure callback plainly meets failed with `[Unknown]`. The recorded fallback
  // bound names the binder, so the application reduces to the callback's own
  // effects — and the effectful callback still fails.
  let root = "build/external_fallback_girard_operator"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ext : []
assume app.disk : [Disk]
check app.go : []
check app.go_impure : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(action) -> Nil {
  action()
}
",
    ),
    #(
      "app.gleam",
      "import ext

fn pure_cb() -> Nil {
  Nil
}

@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
fn disk() -> Nil

fn invoke(op: fn(fn() -> Nil) -> Nil, cb: fn() -> Nil) -> Nil {
  op(cb)
}

pub fn go() -> Nil {
  invoke(ext.run, pure_cb)
}

pub fn go_impure() -> Nil {
  invoke(ext.run, disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("go_impure")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_fallback_lift_keeps_its_callback_arity_test() {
  // `run` has two girard-typed callbacks and invokes only the second; the
  // first contributes no variable to the settled term, so recording bounds
  // for surviving variables alone dropped it — and the lift rebuilt from the
  // recorded names abstracted over `second` only, leaving the second
  // application stuck and `[Unknown]` covering the rest. The bounds keep the
  // full callback shape, so both applications reduce and neither budget sees
  // an `[Unknown]` a stuck spine would put there.
  //
  // Both shapes cost `[Disk]` wherever the disk callback is passed: `second`
  // because the body calls it, and `first` because `keep` is a name
  // `assume ext : []` declares, which states its own effects and nothing about
  // the callback it is handed.
  let root = "build/external_fallback_callback_arity"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext : []
assume app.disk : [Disk]
check app.go : [Disk]
check app.go_swapped : [Disk]
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(first, second) -> Nil {
  keep(first)
  second()
}

fn keep(f: fn() -> Nil) -> Nil {
  Nil
}
",
    ),
    #(
      "app.gleam",
      "import ext

fn pure_cb() -> Nil {
  Nil
}

@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
fn disk() -> Nil

fn invoke(
  op: fn(fn() -> Nil, fn() -> Nil) -> Nil,
  x: fn() -> Nil,
  y: fn() -> Nil,
) -> Nil {
  op(x, y)
}

pub fn go() -> Nil {
  invoke(ext.run, pure_cb, disk)
}

pub fn go_swapped() -> Nil {
  invoke(ext.run, disk, pure_cb)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])
  support.cleanup(root)
}

pub fn a_labeled_fallback_callback_lifts_under_its_bound_name_test() {
  // `run`'s callback parameter is labeled (`with action:`), and the settled
  // fallback term is stated over the in-body name `action` — the name the
  // recorded bound carries. The lift abstracted over the label `with`, so
  // `action` stayed free, the application went stuck, and a `[]` budget the
  // pure callback plainly meets failed with `[Unknown]`. The binder is the
  // bound's name, so the application reduces — and the effectful callback
  // still fails.
  let root = "build/external_fallback_labeled_operator"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ext : []
assume app.disk : [Disk]
check app.go : []
check app.go_impure : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(with action: fn() -> Nil) -> Nil {
  action()
}
",
    ),
    #(
      "app.gleam",
      "import ext

fn pure_cb() -> Nil {
  Nil
}

@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
fn disk() -> Nil

fn invoke(op: fn(fn() -> Nil) -> Nil, cb: fn() -> Nil) -> Nil {
  op(cb)
}

pub fn go() -> Nil {
  invoke(ext.run, pure_cb)
}

pub fn go_impure() -> Nil {
  invoke(ext.run, disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("go_impure")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_girard_typed_fallback_lifts_locally_as_an_operator_test() {
  // The same shape inside one module: `run` is handed to a sibling `invoke`
  // rather than referenced across a boundary, so the lift goes through the
  // same-module path. It, too, must abstract over the recorded fallback bound
  // a girard-typed callback exists only as. `run` is undeclared — the shape
  // whose summary is the only story — so the `[Unknown]` it carries rides
  // every total, and the lift's work shows in the `[Disk]` beside it.
  let root = "build/external_fallback_girard_operator_local"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.disk : [Disk]
check ext.go : [Unknown]
check ext.go_impure : [Unknown]
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(action) -> Nil {
  action()
}

@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
fn disk() -> Nil

fn pure_cb() -> Nil {
  Nil
}

fn invoke(op: fn(fn() -> Nil) -> Nil, cb: fn() -> Nil) -> Nil {
  op(cb)
}

pub fn go() -> Nil {
  invoke(run, pure_cb)
}

pub fn go_impure() -> Nil {
  invoke(run, disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("go_impure")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk", "Unknown"])))
  support.cleanup(root)
}

pub fn a_substituted_call_reports_a_substituted_fallback_test() {
  // A higher-order external whose fallback calls its function-typed parameter,
  // called with a `[Disk]` callback. The boundless `assume` suppresses the
  // body's half, and the auto-detected `action` bound charges the callback
  // exactly as it does for a bodyless external — `[Disk, Time]` — while the
  // explanation's suppressed share states what the body would have charged at
  // this call site, so it substitutes too: `[Disk]`, not the polymorphic
  // `[action]` the knowledge base holds before any arguments are bound. The
  // two fields describe one call, and a structured consumer must not read a
  // variable the actual set already resolved.
  let root = "build/external_fallback_substituted"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.run : [Time]
assume app.disk : [Disk]
check app.uses_impure : []
check app.via_helper : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(action: fn() -> Nil) -> Nil {
  action()
}
",
    ),
    #(
      "app.gleam",
      "import ext

@external(erlang, \"a\", \"d\")
@external(javascript, \"a\", \"d\")
pub fn disk() -> Nil

pub fn uses_impure() -> Nil {
  ext.run(disk)
}

fn helper(f: fn() -> Nil) -> Nil {
  ext.run(f)
}

pub fn via_helper() -> Nil {
  helper(disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  // Directly, and re-bound through a helper whose own walk left the share
  // stated over the helper's parameter: both substitute at every step.
  ["uses_impure", "via_helper"]
  |> list.each(fn(function) {
    let assert Ok(violation) =
      list.find(r.violations, fn(v) { v.function == function })
    violation.explanation.actual
    |> should.equal(types.Specific(set.from_list(["Disk", "Time"])))
    violation.explanation.fallback
    |> should.equal(
      types.FallbackSuppressed(types.Specific(set.from_list(["Disk"]))),
    )
  })
  support.cleanup(root)
}

pub fn an_unwalked_fallback_still_charges_the_callback_test() {
  // The `c`/`d` import cycle aborts the whole in-memory pass, so `a.run`'s
  // fallback body is never walked and its summary would be absent. The
  // callback shape is recorded anyway: under the boundless `assume`, a direct
  // call and the operator channel both charge the `[Disk]` callback beside
  // the declared `[Time]`, instead of the value channel lifting the declared
  // term alone.
  let root = "build/external_fallback_unwalked"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume a.run : [Time]
assume a.disk : [Disk]
check b.direct : []
check b.via_operator : []
",
    ),
    #(
      "a.gleam",
      "@external(javascript, \"a\", \"r\")
pub fn run(action: fn() -> Nil) -> Nil {
  action()
}

@external(erlang, \"a\", \"d\")
@external(javascript, \"a\", \"d\")
pub fn disk() -> Nil
",
    ),
    #(
      "b.gleam",
      "import a

pub fn direct() -> Nil {
  a.run(a.disk)
}

fn invoke(op: fn(fn() -> Nil) -> Nil, x: fn() -> Nil) -> Nil {
  op(x)
}

pub fn via_operator() -> Nil {
  invoke(a.run, a.disk)
}
",
    ),
    #("c.gleam", "import d\n\npub fn go() -> Nil {\n  d.go()\n}\n"),
    #("d.gleam", "import c\n\npub fn go() -> Nil {\n  c.go()\n}\n"),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) = list.find(results, fn(r) { r.file == root <> "/b.gleam" })
  ["direct", "via_operator"]
  |> list.each(fn(function) {
    let assert Ok(violation) =
      list.find(r.violations, fn(v) { v.function == function })
    violation.explanation.actual
    |> should.equal(types.Specific(set.from_list(["Disk", "Time"])))
  })
  support.cleanup(root)
}

pub fn an_unwalked_union_still_charges_the_callback_test() {
  // The `c`/`d` cycle skips every walk, and the module-level `assume` never
  // suppresses, so a caller pays the declaration unioned with the `[Unknown]`
  // the unwalked body reads as. The callback rides that union too — the
  // unwalked body may call it — so a budget admitting `[Time, Unknown]`
  // still fails on the known `[Disk]`, on the direct call and through the
  // operator channel alike.
  let root = "build/external_fallback_unwalked_union"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume a : [Time]
assume a.disk : [Disk]
check b.direct : [Time, Unknown]
check b.via_operator : [Time, Unknown]
",
    ),
    #(
      "a.gleam",
      "@external(javascript, \"a\", \"r\")
pub fn run(action: fn() -> Nil) -> Nil {
  action()
}

@external(erlang, \"a\", \"d\")
@external(javascript, \"a\", \"d\")
pub fn disk() -> Nil
",
    ),
    #(
      "b.gleam",
      "import a

pub fn direct() -> Nil {
  a.run(a.disk)
}

fn invoke(op: fn(fn() -> Nil) -> Nil, x: fn() -> Nil) -> Nil {
  op(x)
}

pub fn via_operator() -> Nil {
  invoke(a.run, a.disk)
}
",
    ),
    #("c.gleam", "import d\n\npub fn go() -> Nil {\n  d.go()\n}\n"),
    #("d.gleam", "import c\n\npub fn go() -> Nil {\n  c.go()\n}\n"),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) = list.find(results, fn(r) { r.file == root <> "/b.gleam" })
  ["direct", "via_operator"]
  |> list.each(fn(function) {
    let assert Ok(violation) =
      list.find(r.violations, fn(v) { v.function == function })
    violation.explanation.actual
    |> should.equal(types.Specific(set.from_list(["Disk", "Time", "Unknown"])))
  })
  support.cleanup(root)
}

pub fn a_module_declaration_read_alone_still_charges_the_callback_test() {
  // The same declaration-only reading as above, under a *module-level*
  // declaration — one that never suppresses. `inner`'s recorded summary
  // bounds pre-empt the registry injection while its fallback half is out of
  // the walk's reach, so nothing else carries the callback: the conservative
  // charge applies to every boundless declaration read alone, and `outer`'s
  // walked body weighs `inner(disk)` as `[Disk, Time]`.
  let root = "build/external_fallback_module_narrowed"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext : [Time]
assume ext.disk : [Disk]
check ext.outer : [Time]
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"o\", \"o\")
pub fn outer() -> Nil {
  inner(disk)
}

@external(erlang, \"i\", \"i\")
pub fn inner(action: fn() -> Nil) -> Nil {
  action()
}

@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
pub fn disk() -> Nil
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("outer")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk", "Time"])))
  support.cleanup(root)
}

pub fn a_narrowed_walk_still_charges_the_callback_test() {
  // `outer`'s fallback runs on javascript alone, and `inner` declares
  // javascript — so from inside that walk `inner`'s own fallback is out of
  // reach and the boundless `assume` answers by itself. The conservative
  // callback charge still applies on that reading: `inner(disk)` in the
  // walked body charges `[Disk]`, so `outer`'s own line fails its `[]`
  // budget instead of reading the body as pure.
  let root = "build/external_fallback_narrowed_walk"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.outer : []
assume ext.inner : []
assume ext.disk : [Disk]
check ext.outer : []
",
    ),
    #(
      "ext.gleam",
      "@external(erlang, \"o\", \"o\")
pub fn outer() -> Nil {
  inner(disk)
}

@external(javascript, \"i\", \"i\")
pub fn inner(action: fn() -> Nil) -> Nil {
  action()
}

@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
pub fn disk() -> Nil
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("outer")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_suppressed_field_call_is_not_charged_through_its_bound_test() {
  // The fallback's only effect is a field call on its record argument, so the
  // summary's one bound is the dotted `r.go`. That bound exists solely to
  // bind the *suppressed* body's variable — a boundless `assume` keeps the
  // conservative charge for function-typed arguments, not for the field
  // calls the suppressed body makes, so wiring `disk` into the record
  // charges nothing.
  let root = "build/external_fallback_field_bound"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.run : []
assume app.disk : [Disk]
check app.uses : []
",
    ),
    #(
      "ext.gleam",
      "pub type Runner {
  Runner(go: fn() -> Nil)
}

@external(javascript, \"e\", \"r\")
pub fn run(r: Runner) -> Nil {
  r.go()
}
",
    ),
    #(
      "app.gleam",
      "import ext

@external(erlang, \"a\", \"d\")
@external(javascript, \"a\", \"d\")
pub fn disk() -> Nil

pub fn uses() -> Nil {
  ext.run(ext.Runner(go: disk))
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  r.violations |> should.equal([])
  support.cleanup(root)
}

pub fn a_decoupled_bound_lifts_through_a_value_channel_test() {
  // `assume ext.run(cb: [e]) : [e]` handed to a higher-order helper: the
  // lift abstracts over the parameter name `cb`, and the charge's variable
  // names the same parameter, so the application reduces to the callback's
  // `[Disk]` — not the `[Unknown]` a payload variable left raw under the
  // binder grounds to.
  let root = "build/external_fallback_decoupled_lift"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.run(cb: [e]) : [e]
assume app.disk : [Disk]
check app.via_operator : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(cb: fn() -> Nil) -> Nil {
  cb()
}
",
    ),
    #(
      "app.gleam",
      "import ext

@external(erlang, \"a\", \"d\")
@external(javascript, \"a\", \"d\")
pub fn disk() -> Nil

fn invoke(op: fn(fn() -> Nil) -> Nil, x: fn() -> Nil) -> Nil {
  op(x)
}

pub fn via_operator() -> Nil {
  invoke(ext.run, disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("via_operator")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_colliding_share_still_quotes_its_own_argument_test() {
  // `assume ext.run(cb: [other]) : [Time, other]` beside a fallback that
  // calls its *own* parameter named `other`: the declared payload and the
  // fallback parameter are distinct variables even though they share a
  // spelling. The charge binds through the `cb` argument — `[Time]` for a
  // pure one — while the suppressed share binds through the `other`
  // argument, quoting the `[Disk]` the body would actually have charged.
  let root = "build/external_fallback_colliding_share"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.run(cb: [other]) : [Time, other]
assume ext.disk : [Disk]
assume ext.noop : []
check app.fallback_disk : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(cb: fn() -> Nil, other: fn() -> Nil) -> Nil {
  other()
}

@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
pub fn disk() -> Nil

@external(erlang, \"n\", \"n\")
@external(javascript, \"n\", \"n\")
pub fn noop() -> Nil
",
    ),
    #(
      "app.gleam",
      "import ext

pub fn fallback_disk() -> Nil {
  ext.run(ext.noop, ext.disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("fallback_disk")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Time"])))
  violation.explanation.fallback
  |> should.equal(
    types.FallbackSuppressed(types.Specific(set.from_list(["Disk"]))),
  )
  support.cleanup(root)
}

pub fn a_value_channel_charges_the_callback_under_a_boundless_assume_test() {
  // `ext.run` handed around as a value instead of called directly: as an
  // operator argument, and wired into a record field. The boundless `assume`
  // says nothing about the callback, so every channel keeps the conservative
  // callback charge a direct call auto-injects — `[Disk, Time]`, never the
  // bare `[Time]` that would let a check pass or fail on the call's shape.
  let root = "build/external_fallback_value_channels"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.run : [Time]
assume app.disk : [Disk]
check app.via_operator : []
check app.via_field : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(action: fn() -> Nil) -> Nil {
  action()
}
",
    ),
    #(
      "app.gleam",
      "import ext

pub type Runner {
  Runner(go: fn(fn() -> Nil) -> Nil)
}

@external(erlang, \"a\", \"d\")
@external(javascript, \"a\", \"d\")
pub fn disk() -> Nil

fn invoke(op: fn(fn() -> Nil) -> Nil, x: fn() -> Nil) -> Nil {
  op(x)
}

pub fn via_operator() -> Nil {
  invoke(ext.run, disk)
}

fn make() -> Runner {
  Runner(go: ext.run)
}

pub fn via_field() -> Nil {
  let r = make()
  r.go(disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  ["via_operator", "via_field"]
  |> list.each(fn(function) {
    let assert Ok(violation) =
      list.find(r.violations, fn(v) { v.function == function })
    violation.explanation.actual
    |> should.equal(types.Specific(set.from_list(["Disk", "Time"])))
  })
  support.cleanup(root)
}

pub fn a_bodyless_externals_callback_is_charged_on_every_channel_test() {
  // `ext.run` is bodyless — foreign on every target, so no fallback summary
  // records what its callbacks are — and its `assume` line is boundless. Only
  // the parsed signature says it takes one. A direct call recovered the charge
  // from that signature at the call site; every value channel read the bare
  // `[Time]`, so an effectful callback passed a pure check on the call's shape
  // alone. All three charge `[Disk, Time]`.
  let root = "build/bodyless_external_value_channels"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ext.run : [Time]
assume app.disk : [Disk]
check app.direct : []
check app.via_operator : []
check app.via_field : []
",
    ),
    #("ext.gleam", support.foreign_fn("run", "(action: fn() -> Nil) -> Nil")),
    #(
      "app.gleam",
      "import ext

pub type Runner {
  Runner(go: fn(fn() -> Nil) -> Nil)
}

@external(erlang, \"a\", \"d\")
@external(javascript, \"a\", \"d\")
pub fn disk() -> Nil

fn invoke(op: fn(fn() -> Nil) -> Nil, x: fn() -> Nil) -> Nil {
  op(x)
}

pub fn direct() -> Nil {
  ext.run(disk)
}

pub fn via_operator() -> Nil {
  invoke(ext.run, disk)
}

fn make() -> Runner {
  Runner(go: ext.run)
}

pub fn via_field() -> Nil {
  let r = make()
  r.go(disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  ["direct", "via_operator", "via_field"]
  |> list.each(fn(function) {
    let assert Ok(violation) =
      list.find(r.violations, fn(v) { v.function == function })
    violation.explanation.actual
    |> should.equal(types.Specific(set.from_list(["Disk", "Time"])))
  })
  support.cleanup(root)
}

pub fn an_unbuilt_bodyless_externals_callback_is_charged_too_test() {
  // The same name under defaulted targets, declared for javascript alone and
  // with no Gleam body to run in its place: the declaration stands beside a
  // fallback that is not there, the reading graded cannot narrow further. That
  // arm returned the declared term bare, so the callback share stopped at the
  // arm rather than at the shape of the line.
  let root = "build/unbuilt_bodyless_external_callback"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ext.run : [Time]
assume app.disk : [Disk]
check app.via_operator : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"m\", \"run\")
pub fn run(action: fn() -> Nil) -> Nil
",
    ),
    #(
      "app.gleam",
      "import ext

@external(erlang, \"a\", \"d\")
@external(javascript, \"a\", \"d\")
pub fn disk() -> Nil

fn invoke(op: fn(fn() -> Nil) -> Nil, x: fn() -> Nil) -> Nil {
  op(x)
}

pub fn via_operator() -> Nil {
  invoke(ext.run, disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("via_operator")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk", "Time"])))
  support.cleanup(root)
}

pub fn a_sibling_bodyless_external_charges_its_callback_test() {
  // The same external passed to a helper in its *own* module, which resolves
  // through the definition rather than through the knowledge base. The lift
  // reads the same charge, so the sibling channel charges what the cross-module
  // one does.
  let root = "build/bodyless_external_sibling_channel"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ext.run : [Time]
assume ext.disk : [Disk]
check ext.via_sibling : []
",
    ),
    #(
      "ext.gleam",
      support.foreign_fn("run", "(action: fn() -> Nil) -> Nil")
        <> support.foreign_fn("disk", "() -> Nil")
        <> "
fn invoke(op: fn(fn() -> Nil) -> Nil, x: fn() -> Nil) -> Nil {
  op(x)
}

pub fn via_sibling() -> Nil {
  invoke(run, disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  let assert Ok(violation) =
    list.find(r.violations, fn(v) { v.function == "via_sibling" })
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk", "Time"])))
  support.cleanup(root)
}

pub fn a_dependency_externals_callback_is_charged_on_a_value_channel_test() {
  // A dependency's bodyless higher-order `@external`, declared by the
  // dependency's own shipped spec. The consumer never calls it directly — it
  // hands it to a helper — and the callback it hands over is charged.
  let root = "build/dependency_bodyless_external_value_channel"
  support.write_project_with_dependency(
    directory: root,
    package: "proj",
    spec: "assume app.disk : [Disk]\ncheck app.via_operator : []\n",
    sources: [
      #(
        "app.gleam",
        "import dep/ffi

@external(erlang, \"a\", \"d\")
@external(javascript, \"a\", \"d\")
pub fn disk() -> Nil

fn invoke(op: fn(fn() -> Nil) -> Nil, x: fn() -> Nil) -> Nil {
  op(x)
}

pub fn via_operator() -> Nil {
  invoke(ffi.run, disk)
}
",
      ),
    ],
    dependency: "dep",
    dependency_spec: "assume dep/ffi.run : [Time]\n",
    dependency_sources: [
      #(
        "dep/ffi.gleam",
        support.foreign_fn("run", "(action: fn() -> Nil) -> Nil"),
      ),
    ],
  )
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("via_operator")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk", "Time"])))
  support.cleanup(root)
}

pub fn a_module_assumed_helper_charges_its_callback_on_every_shape_test() {
  // `assume m : []` over ordinary higher-order Gleam states what `each`'s own
  // body costs and says nothing about the callback handed to it — the same
  // reading a boundless per-function line gets. Every shape pays the callback:
  // called or handed around, from inside the declared module or outside it.
  //
  // The same-module halves are the ones a declaration answers for through the
  // sibling path, which kept the declaration's set alone and charged the
  // callback to nobody; the cross-module halves were blocked by a second
  // reading, the bounds this run's own inference recorded over the very body
  // the line speaks over.
  let root = "build/module_assumed_helper_callback"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume m : []
assume m.disk : [Disk]
check m.same_module_call : []
check m.same_module_value : []
check other.cross_module_call : []
check other.cross_module_value : []
",
    ),
    #(
      "m.gleam",
      "pub fn each(cb: fn() -> Nil) -> Nil {
  cb()
}

@external(erlang, \"a\", \"d\")
@external(javascript, \"a\", \"d\")
pub fn disk() -> Nil

fn invoke(op: fn(fn() -> Nil) -> Nil, x: fn() -> Nil) -> Nil {
  op(x)
}

pub fn same_module_call() -> Nil {
  each(disk)
}

pub fn same_module_value() -> Nil {
  invoke(each, disk)
}
",
    ),
    #(
      "other.gleam",
      "import m

fn invoke(op: fn(fn() -> Nil) -> Nil, x: fn() -> Nil) -> Nil {
  op(x)
}

pub fn cross_module_call() -> Nil {
  m.each(m.disk)
}

pub fn cross_module_value() -> Nil {
  invoke(m.each, m.disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let charged =
    results
    |> list.flat_map(fn(r) { r.violations })
    |> list.filter_map(fn(violation) {
      case violation.explanation.actual {
        types.Specific(effects) ->
          case set.contains(effects, "Disk") {
            True -> Ok(violation.function)
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
    |> list.sort(string.compare)
  charged
  |> should.equal([
    "cross_module_call", "cross_module_value", "same_module_call",
    "same_module_value",
  ])
  support.cleanup(root)
}

pub fn a_module_assumed_sibling_lifts_from_its_declaration_test() {
  // The sibling *value* channel, isolated from every other reading. `ignore`
  // never calls its callback, so walking its body lifts it to `λcb. []` and
  // the disk callback rides through free; the declaration is what its callers
  // pay, and it says nothing about the callback. `util.invoke` sits outside
  // the assumed module so nothing but the lift can charge anything — the twin
  // whose body does call the callback would pass either way, and is here to
  // show the lift still reduces rather than going stuck.
  let root = "build/module_assumed_sibling_lift"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume m : []
assume m.disk : [Disk]
check m.hands_over_an_uncalled_callback : []
check m.hands_over_a_called_callback : []
",
    ),
    #(
      "util.gleam",
      "pub fn invoke(op: fn(fn() -> Nil) -> Nil, x: fn() -> Nil) -> Nil {
  op(x)
}
",
    ),
    #(
      "m.gleam",
      "import util

@external(erlang, \"a\", \"d\")
@external(javascript, \"a\", \"d\")
pub fn disk() -> Nil

pub fn ignore(cb: fn() -> Nil) -> Nil {
  Nil
}

pub fn calls(cb: fn() -> Nil) -> Nil {
  cb()
}

pub fn hands_over_an_uncalled_callback() -> Nil {
  util.invoke(ignore, disk)
}

pub fn hands_over_a_called_callback() -> Nil {
  util.invoke(calls, disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) = list.find(results, fn(r) { r.file == root <> "/m.gleam" })
  ["hands_over_an_uncalled_callback", "hands_over_a_called_callback"]
  |> list.each(fn(function) {
    let assert Ok(violation) =
      list.find(r.violations, fn(v) { v.function == function })
    violation.explanation.actual
    |> should.equal(types.Specific(set.from_list(["Disk"])))
  })
  support.cleanup(root)
}

pub fn a_bodyless_externals_reference_warns_as_a_summarys_does_test() {
  // A reference to a var-carrying name warns quoting the set it carries, which
  // is what a summary-shaped one already did. The widened names inherit it:
  // the `[Time]`-declared external quotes both halves, and the pure one quotes
  // its variable alone rather than falling silent.
  let root = "build/bodyless_external_reference_warning"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ext.loud : [Time]
assume ext.quiet : []
check app.loud_go : [_]
check app.quiet_go : [_]
",
    ),
    #(
      "ext.gleam",
      support.foreign_fn("loud", "(action: fn() -> Nil) -> Nil")
        <> support.foreign_fn("quiet", "(action: fn() -> Nil) -> Nil"),
    ),
    #(
      "app.gleam",
      "import ext

pub fn apply_callback(f: fn(fn() -> Nil) -> Nil) -> Nil {
  f(fn() { Nil })
}

pub fn loud_go() -> Nil {
  apply_callback(ext.loud)
}

pub fn quiet_go() -> Nil {
  apply_callback(ext.quiet)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  r.warnings
  |> list.map(fn(warning) {
    let assert types.UntrackedEffectWarning(function:, effects:, ..) = warning
    #(function, effects)
  })
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> should.equal([
    #(
      "loud_go",
      types.Polymorphic(set.from_list(["Time"]), set.from_list(["action"])),
    ),
    #("quiet_go", types.Polymorphic(set.new(), set.from_list(["action"]))),
  ])
  support.cleanup(root)
}

pub fn a_suppressed_share_binds_through_the_fallback_bounds_test() {
  // The `assume` line's bound decouples its payload variable from the
  // parameter name (`cb: [e]`), while the suppressed body's term is stated
  // over the parameter itself (`cb`). Each half binds through its own bounds
  // at the call site: the declared `[Time]` stays as written — `e` never
  // reaches the term — and the share quotes the `[Disk]` actually
  // suppressed, not the `[Unknown]` a bound list without `cb` leaves.
  let root = "build/external_fallback_decoupled_bound"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.run(cb: [e]) : [Time]
assume app.disk : [Disk]
check app.direct : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(cb: fn() -> Nil) -> Nil {
  cb()
}
",
    ),
    #(
      "app.gleam",
      "import ext

@external(erlang, \"a\", \"d\")
@external(javascript, \"a\", \"d\")
pub fn disk() -> Nil

pub fn direct() -> Nil {
  ext.run(disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("direct")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Time"])))
  violation.explanation.fallback
  |> should.equal(
    types.FallbackSuppressed(types.Specific(set.from_list(["Disk"]))),
  )
  support.cleanup(root)
}

pub fn a_declared_sibling_call_pays_what_a_qualified_call_pays_test() {
  // A higher-order external under a boundless `assume`, called from its own
  // module and from another. The boundless line says nothing about the
  // callback, so the auto-detected `action` bound charges it at both call
  // shapes: the sibling pays the same `[Disk, Time]` the qualified caller
  // does, with the same substituted suppressed share beside it.
  let root = "build/external_fallback_sibling_parity"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.run : [Time]
assume ext.disk : [Disk]
assume app.disk : [Disk]
check app.qualified : []
check ext.sibling : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(action: fn() -> Nil) -> Nil {
  action()
}

pub fn sibling() -> Nil {
  run(disk)
}

@external(erlang, \"a\", \"d\")
@external(javascript, \"a\", \"d\")
fn disk() -> Nil
",
    ),
    #(
      "app.gleam",
      "import ext

@external(erlang, \"a\", \"d\")
@external(javascript, \"a\", \"d\")
pub fn disk() -> Nil

pub fn qualified() -> Nil {
  ext.run(disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  [#("app.gleam", "qualified"), #("ext.gleam", "sibling")]
  |> list.each(fn(expected) {
    let #(file, function) = expected
    let assert Ok(r) =
      list.find(results, fn(r) { r.file == root <> "/" <> file })
    let assert Ok(violation) =
      list.find(r.violations, fn(v) { v.function == function })
    violation.explanation.actual
    |> should.equal(types.Specific(set.from_list(["Disk", "Time"])))
    violation.explanation.fallback
    |> should.equal(
      types.FallbackSuppressed(types.Specific(set.from_list(["Disk"]))),
    )
  })
  support.cleanup(root)
}

pub fn a_ground_assume_rebinds_the_suppressed_share_through_a_helper_test() {
  // The bounded `assume` charges a ground `[Time]`, so the helper's walk hands
  // its caller calls with no variable in any *term* — the only variable left
  // is in the suppressed share, stated over the helper's own parameter. The
  // local re-attribution binds that share too: `via_helper`'s explanation
  // quotes `[Disk]`, the body's charge at this call site, not `[Unknown]`.
  let root = "build/external_fallback_helper_ground"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.run(action: [action]) : [Time]
assume app.disk : [Disk]
check app.via_helper : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(action: fn() -> Nil) -> Nil {
  action()
}
",
    ),
    #(
      "app.gleam",
      "import ext

@external(erlang, \"a\", \"d\")
@external(javascript, \"a\", \"d\")
pub fn disk() -> Nil

fn helper(f: fn() -> Nil) -> Nil {
  ext.run(f)
}

pub fn via_helper() -> Nil {
  helper(disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("via_helper")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Time"])))
  violation.explanation.fallback
  |> should.equal(
    types.FallbackSuppressed(types.Specific(set.from_list(["Disk"]))),
  )
  support.cleanup(root)
}

pub fn a_wired_field_call_rebinds_the_suppressed_share_test() {
  // A record field wired to a higher-order external under a bounded `assume`,
  // called on a factory-built receiver — the proven-value path, where the
  // wired name's charge is read from the knowledge base. The charged term
  // substitutes at the field call, and the suppressed share substitutes
  // beside it — `[Disk]`, the body's charge at this call site — whether the
  // declared term is ground (`run`) or carries the bound's variable (`tap`).
  let root = "build/external_fallback_wired_field"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.run(action: [action]) : [Time]
assume ext.tap(action: [action]) : [Time, action]
assume app.disk : [Disk]
check app.via_ground : []
check app.via_poly : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(action: fn() -> Nil) -> Nil {
  action()
}

@external(javascript, \"ext_ffi\", \"tap\")
pub fn tap(action: fn() -> Nil) -> Nil {
  action()
}
",
    ),
    #(
      "app.gleam",
      "import ext

pub type Runner {
  Runner(go: fn(fn() -> Nil) -> Nil)
}

@external(erlang, \"a\", \"d\")
@external(javascript, \"a\", \"d\")
pub fn disk() -> Nil

fn make_ground() -> Runner {
  Runner(go: ext.run)
}

fn make_poly() -> Runner {
  Runner(go: ext.tap)
}

pub fn via_ground() -> Nil {
  let r = make_ground()
  r.go(disk)
}

pub fn via_poly() -> Nil {
  let r = make_poly()
  r.go(disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  [
    #("via_ground", ["Time"]),
    #("via_poly", ["Disk", "Time"]),
  ]
  |> list.each(fn(expected) {
    let #(function, actual) = expected
    let assert Ok(violation) =
      list.find(r.violations, fn(v) { v.function == function })
    violation.explanation.actual
    |> should.equal(types.Specific(set.from_list(actual)))
    violation.explanation.fallback
    |> should.equal(
      types.FallbackSuppressed(types.Specific(set.from_list(["Disk"]))),
    )
  })
  support.cleanup(root)
}

pub fn a_phantom_binder_is_weighed_as_the_unknown_it_is_test() {
  // `lib.leaky`'s committed term carries a variable that is nobody's parameter
  // — the shape an application graded could not resolve leaves behind. A caller
  // can never bind it, so it grounds to `[Unknown]`: the budget admitting that
  // holds, and the one admitting nothing fails on `[Unknown]` rather than on an
  // internal name with a hint advising a bound for a parameter `run` hasn't got.
  let root = "build/check_phantom_binder"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "effects lib.leaky : [e_17]
check app.run : [Unknown]
check app.strict : []
",
    ),
    #("lib.gleam", "pub fn leaky() -> Nil {\n  Nil\n}\n"),
    #(
      "app.gleam",
      "import lib

pub fn run() -> Nil {
  lib.leaky()
}

pub fn strict() -> Nil {
  lib.leaky()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("strict")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  // The wording still says the effects are unresolved, and no longer advises a
  // bound for a parameter the function does not have.
  let rendered = checker.format_violation("app.gleam", violation)
  rendered
  |> string.contains("with unresolved effects [Unknown]")
  |> should.be_true()
  rendered |> string.contains("hint:") |> should.be_false()
  support.cleanup(root)
}

pub fn an_undeclared_fallback_is_charged_on_every_value_channel_test() {
  // The same undeclared external reached three ways: called, wired into a
  // record field, and passed as a callback. A call charged the fallback's
  // `[Disk]` beside the `[Unknown]`, but the value channels read the external
  // through `lookup_declared`, where the non-declaring entry inference leaves
  // for it was rejected straight to a bare `[Unknown]` — dropping effects
  // graded had walked, and charging one name differently per channel.
  let root = "build/external_fallback_channels"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume disk.write : [Disk]
check app.direct : []
check app.wired : []
check app.as_callback : []
check app.via_factory : []
",
    ),
    #("disk.gleam", "@external(erlang, \"d\", \"w\")\npub fn write() -> Nil\n"),
    #(
      "ext.gleam",
      "import disk

@external(javascript, \"ext_ffi\", \"log\")
pub fn log() -> Nil {
  disk.write()
}
",
    ),
    #(
      "maker.gleam",
      "import ext

pub type Handler {
  Handler(run: fn() -> Nil)
}

pub fn make() -> Handler {
  Handler(run: ext.log)
}
",
    ),
    #(
      "app.gleam",
      "import ext
import maker

pub fn direct() -> Nil {
  ext.log()
}

pub fn wired() -> Nil {
  let handler = maker.Handler(run: ext.log)
  handler.run()
}

fn helper(f: fn() -> Nil) -> Nil {
  f()
}

pub fn as_callback() -> Nil {
  helper(ext.log)
}

pub fn via_factory() -> Nil {
  let handler = maker.make()
  handler.run()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let total = types.Specific(set.from_list(["Disk", "Unknown"]))
  ["direct", "wired", "as_callback", "via_factory"]
  |> list.each(fn(function) {
    let assert Ok(violation) =
      list.find(r.violations, fn(v) { v.function == function })
    violation.explanation.actual |> should.equal(total)
  })

  // And they agree about *why*, not only about the total. A field call whose
  // receiver came from another module's factory reported `from in-memory
  // inference` — an origin no source claimed, minted by the lookup to carry
  // the running fallback — beside a direct call's `an external with no
  // declared effects`: two provenance stories for one name. (`as_callback`'s
  // contributor is the parameter call inside `helper`, so it reports that
  // argument rather than the external.)
  ["direct", "wired", "via_factory"]
  |> list.each(fn(function) {
    let assert Ok(violation) =
      list.find(r.violations, fn(v) { v.function == function })
    violation.explanation.reason
    |> should.equal(Some(types.UndeclaredExternal))
    violation.explanation.origin |> should.equal(None)
  })
  support.cleanup(root)
}

pub fn a_fallback_reaching_a_sibling_fallback_is_charged_it_test() {
  // `a`'s fallback calls `b`, whose fallback reaches the disk; both are
  // undeclared, so their summaries are the whole story beside the `[Unknown]`
  // foreign code carries. A single pass over the module summarised `a` against
  // a knowledge base that did not yet know what `b`'s body does, so `a`
  // recorded nothing, the disk went uncharged and `infer` under-published the
  // caller. The summaries are settled before they are published.
  let root = "build/external_fallback_siblings"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume disk.write : [Disk]
check ext.wrapper : []
",
    ),
    #("disk.gleam", "@external(erlang, \"d\", \"w\")\npub fn write() -> Nil\n"),
    #(
      "ext.gleam",
      "import disk

@external(javascript, \"ext_ffi\", \"b\")
pub fn b() -> Nil {
  disk.write()
}

@external(javascript, \"ext_ffi\", \"a\")
pub fn a() -> Nil {
  b()
}

pub fn wrapper() -> Nil {
  a()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "wrapper" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk", "Unknown"])))
  // And the same total is what gets published.
  let assert Ok(preview) = graded.run_infer_dry_run(root)
  preview
  |> string.contains("effects ext.wrapper : [Disk, Unknown]")
  |> should.be_true()
  support.cleanup(root)
}

pub fn mutually_recursive_fallbacks_settle_to_one_summary_test() {
  // `a`'s fallback calls `b` and `b`'s calls `a`, so neither can be summarised
  // against a settled summary of the other — the cycle circulates the disk one
  // member per pass. Both are undeclared, so beside the `[Unknown]` foreign
  // code carries, both land on the same total, and a caller of either is
  // charged it, whichever the walk reaches first.
  let root = "build/external_fallback_mutual"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume disk.write : [Disk]
check ext.calls_a : []
check ext.calls_b : []
",
    ),
    #("disk.gleam", "@external(erlang, \"d\", \"w\")\npub fn write() -> Nil\n"),
    #(
      "ext.gleam",
      "import disk

@external(javascript, \"ext_ffi\", \"a\")
pub fn a(n: Int) -> Nil {
  case n {
    0 -> disk.write()
    _ -> b(n - 1)
  }
}

@external(javascript, \"ext_ffi\", \"b\")
pub fn b(n: Int) -> Nil {
  a(n - 1)
}

pub fn calls_a() -> Nil {
  a(1)
}

pub fn calls_b() -> Nil {
  b(1)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  let total = types.Specific(set.from_list(["Disk", "Unknown"]))
  ["calls_a", "calls_b"]
  |> list.each(fn(function) {
    let assert Ok(v) = list.find(r.violations, fn(v) { v.function == function })
    v.explanation.actual |> should.equal(total)
  })
  // And both summaries are published as the same total, not one pass short of
  // each other.
  let assert Ok(preview) = graded.run_infer_dry_run(root)
  preview
  |> string.contains("effects ext.calls_a : [Disk, Unknown]")
  |> should.be_true()
  preview
  |> string.contains("effects ext.calls_b : [Disk, Unknown]")
  |> should.be_true()
  support.cleanup(root)
}

pub fn a_recursive_fallback_summary_reaches_a_fixed_point_test() {
  // `retry`'s fallback recurses into itself with `disk` substituted for its
  // own callback, so the summary is only complete once the recursive call is
  // charged against a settled summary of `retry` — which itself took a pass to
  // exist. Settling stopped after one pass per fallback, so the summary stayed
  // `[f]` and a wrapper passing a pure callback met a `[]` budget over a body
  // that reaches the disk.
  let root = "build/external_fallback_recursive"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext : []
assume ext.disk : [Disk]
check ext.wrapper : []
",
    ),
    #(
      "ext.gleam",
      "@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
fn disk() -> Nil

@external(javascript, \"ext_ffi\", \"retry\")
pub fn retry(f: fn() -> Nil, n: Int) -> Nil {
  case n {
    0 -> f()
    _ -> retry(disk, n - 1)
  }
}

fn pure_cb() -> Nil {
  Nil
}

pub fn wrapper() -> Nil {
  retry(pure_cb, 1)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "wrapper" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_cyclic_import_graph_still_charges_a_running_fallback_test() {
  // A cycle in the import graph leaves the in-memory inference pass with no
  // order to run in, so no fallback body is walked at all. The declaration was
  // then the whole answer for an external whose body still runs — `[Stdout]`
  // over a body that reaches the disk, silently, on a topology alone. What no
  // walk reached reads as `[Unknown]`, the same thing a dependency's unwalkable
  // fallback already answers.
  let root = "build/external_fallback_cyclic"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext : [Stdout]
assume ext.sink : [Disk]
check other.calls_it : []
",
    ),
    #(
      "ext.gleam",
      "import other

@external(javascript, \"ext_ffi\", \"log\")
pub fn log() -> Nil {
  sink()
}

@external(erlang, \"ext_ffi\", \"sink\")
@external(javascript, \"ext_ffi\", \"sink\")
fn sink() -> Nil

pub fn ping() -> Nil {
  other.pong()
}
",
    ),
    #(
      "other.gleam",
      "import ext

pub fn pong() -> Nil {
  Nil
}

pub fn calls_it() -> Nil {
  ext.log()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(caller) =
    list.find(results, fn(r) { r.file == root <> "/other.gleam" })
  let assert [calls_it] = caller.violations
  calls_it.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout", "Unknown"])))

  // And the query says the same, rather than crediting the declaration with an
  // answer the charge disagrees with.
  let assert Ok(answered) = graded.run_effect(root, "ext.log")
  answered |> string.contains("Unknown") |> should.be_true()
  support.cleanup(root)
}

pub fn a_fallback_resolves_field_calls_through_type_lines_test() {
  // The fallback body reaches a field a field `assume` line decides. The pass that
  // summarises it used to run before those lines were installed, so the summary
  // disagreed with what the external's own `check` line reported — and with
  // what `infer` wrote, whose pass installed them first. Every pass folds them
  // in the same order: the own line weighs the walked `[Disk]`, and the
  // caller — paying the suppressing `assume` line's `[]` alone — still has
  // the same `[Disk]` quoted as the suppressed share.
  let root = "build/external_fallback_type_line"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume runner.Runner.run : [Disk]
assume ext.log : []
check ext.log : []
check ext.wrapper : []
",
    ),
    #("runner.gleam", "pub type Runner {\n  Runner(run: fn() -> Nil)\n}\n"),
    #(
      "ext.gleam",
      "import runner

fn helper(r: runner.Runner) -> Nil {
  r.run()
}

@external(javascript, \"ext_ffi\", \"log\")
pub fn log() -> Nil {
  helper(blank())
}

fn blank() -> runner.Runner {
  runner.Runner(run: noop)
}

fn noop() -> Nil {
  Nil
}

pub fn wrapper() -> Nil {
  log()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  let disk = types.Specific(set.from_list(["Disk"]))
  // The external's own line weighs the resolved field call.
  let assert Ok(own) = list.find(r.violations, fn(v) { v.function == "log" })
  own.explanation.actual |> should.equal(disk)
  // The caller pays the line's `[]` alone, and the walk's `[Disk]` reaches it
  // as the suppressed share the query quotes.
  list.find(r.violations, fn(v) { v.function == "wrapper" })
  |> should.equal(Error(Nil))
  let assert Ok(answered) = graded.run_effect(root, "ext.log")
  answered
  |> string.contains("suppressed by the `assume` line: [Disk]")
  |> should.be_true()
  // And what would be written states the suppressed caller-side charge.
  let assert Ok(preview) = graded.run_infer_dry_run(root)
  preview |> string.contains("effects ext.wrapper : []") |> should.be_true()
  support.cleanup(root)
}

pub fn a_higher_order_fallback_binds_its_callback_test() {
  // The fallback calls a function-typed parameter. Summarised without the
  // synthetic bound ordinary inference gives one, that call has nothing to
  // bind and collapses to `[Unknown]`, so every caller inherits it and a
  // demonstrably pure callback fails a `[]` budget. The summary is stated over
  // the same bounds, and the call site binds them.
  let root = "build/external_fallback_higher_order"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ext.run : []
assume app.disk : [Disk]
check app.uses : []
check app.uses_impure : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(action: fn() -> Nil) -> Nil {
  action()
}
",
    ),
    #(
      "app.gleam",
      "import ext

fn pure_callback() -> Nil {
  Nil
}

@external(erlang, \"d\", \"w\")
fn disk() -> Nil

pub fn uses() -> Nil {
  ext.run(pure_callback)
}

pub fn uses_impure() -> Nil {
  ext.run(disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  // The pure callback is not charged for the fallback's call to it.
  list.any(r.violations, fn(v) { v.function == "uses" }) |> should.be_false()
  // The effectful one still is, so the bound resolves rather than vanishing.
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "uses_impure" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_fallback_bound_travels_with_every_answer_form_test() {
  // The same higher-order fallback under each of the three ways a `graded
  // effect` answer is reached: undeclared, declared per function, and declared
  // by a module-level line. Only the per-function form read the bounds the
  // fallback recorded, so the other two stated a term over a `action` variable
  // nothing in the line introduced — losing the budget, and the forwarding the
  // sentence is meant to explain.
  let root = "build/external_fallback_answer_forms"
  let sources = [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"run\")
pub fn run(action: fn() -> Nil) -> Nil {
  action()
}
",
    ),
  ]
  let answer_for = fn(spec) {
    support.write_fixture(root, [#("proj.graded", spec), ..sources])
    let assert Ok(answered) = graded.run_effect(root, "ext.run")
    answered
  }

  // Undeclared: the `[Unknown]` it carries, stated over the bound.
  answer_for("")
  |> string.contains("effects ext.run(action: [action]) : [Unknown, action]")
  |> should.be_true()

  // A module-level line, whose own declaration has no per-function bounds to
  // state — the ones here are the fallback body's.
  answer_for("assume ext : [Time]\n")
  |> string.contains("effects ext.run(action: [action]) : [Time, action]")
  |> should.be_true()

  // The per-function form suppresses the fallback half, but the boundless
  // line says nothing about the callback: the answer keeps the conservative
  // `action` variable a call site charges the argument through — the same
  // shape the other two forms state — and the body's own share is quoted as
  // suppressed rather than counted in the term.
  let per_function = answer_for("assume ext.run : []\n")
  per_function
  |> string.contains("effects ext.run(action: [action]) : [action]")
  |> should.be_true()
  per_function
  |> string.contains("suppressed by the `assume` line: [action]")
  |> should.be_true()
  support.cleanup(root)
}

pub fn a_committed_bound_does_not_travel_with_a_foreign_answer_test() {
  // A bound from an `effects` line over an `@external`'s body, with no fallback
  // to have recorded one. The entry beside it is refused as an answer because
  // the foreign implementation needn't match the body it was inferred over, and
  // the bound states an assumption about an argument on exactly that authority.
  let root = "build/external_committed_bound"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "effects ext.run(action: [Stdout]) : [Stdout]\n"),
    #(
      "ext.gleam",
      "@external(erlang, \"ext_ffi\", \"run\")
@external(javascript, \"ext_ffi\", \"run\")
pub fn run(action: fn() -> Nil) -> Nil
",
    ),
  ])
  let assert Ok(answered) = graded.run_effect(root, "ext.run")
  answered |> string.contains("action") |> should.be_false()
  support.cleanup(root)
}

pub fn a_module_external_resolves_from_catalog_functions_test() {
  // The stdlib catalog keys `gleam/io.println` and no `gleam/io` line, which is
  // the usual shape. Weighing module existence by module-level entries alone
  // called a real module a typo whenever the dependency's own sources were not
  // installed to say otherwise.
  let root = "build/external_lint_catalog_module"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "manifest.toml",
      "packages = [\n  { name = \"gleam_stdlib\", version = \"0.70.0\" },\n]\n",
    ),
    #("proj.graded", "assume gleam/io : []\nassume nowhere/mod : []\n"),
    // The manifest's one package yields sources, so a module the lint cannot
    // place really is nowhere. `gleam/io` is not among them: the catalog's
    // per-function entries are what answer for it.
    #(
      "build/packages/gleam_stdlib/src/gleam/list.gleam",
      "pub fn go() -> Nil {\n  Nil\n}\n",
    ),
    #("m.gleam", "pub fn go() -> Nil {\n  Nil\n}\n"),
  ])
  let assert Ok(results) = graded.check_project(root)
  // Only the module that really resolves nowhere is flagged.
  results
  |> list.flat_map(fn(r) { r.warnings })
  |> should.equal([types.UnmatchedModuleAssumeWarning(module: "nowhere/mod")])
  support.cleanup(root)
}

pub fn a_wired_field_separates_the_fallback_test() {
  // A field wired to a target-conditional external carries the same two sources
  // a direct call to it does. The `assume ext.log : [Net]` line suppresses the
  // body's `[Disk]` from the field's charge, and the explanation still quotes
  // the suppressed half — a body runs that the total no longer counts, and
  // silence about it would read as no body at all.
  let root = "build/external_fallback_wired_field"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.log : [Net]
assume ext.sink : [Disk]
check app.uses : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"log\")
pub fn log() -> Nil {
  sink()
}

@external(erlang, \"ext_ffi\", \"sink\")
@external(javascript, \"ext_ffi\", \"sink\")
fn sink() -> Nil
",
    ),
    #(
      "app.gleam",
      "import ext

pub type Runner {
  Runner(run: fn() -> Nil)
}

pub fn make() -> Runner {
  Runner(run: ext.log)
}

pub fn uses() -> Nil {
  let r = make()
  r.run()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [v] = r.violations
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Net"])))
  v.explanation.fallback
  |> should.equal(
    types.FallbackSuppressed(types.Specific(set.from_list(["Disk"]))),
  )
  checker.format_violation(r.file, v)
  |> string.contains(
    "its Gleam fallback body's charge suppressed by the `assume` line",
  )
  |> should.be_true()
  support.cleanup(root)
}

pub fn a_callers_explanation_separates_the_fallback_test() {
  // The declaration says `[Net]` and the body does `[Disk]`. The line
  // suppresses the body's half, so the caller pays `[Net]` alone — and the
  // message says a body runs that the `assume` line un-charged, or the charge
  // reads as though no fallback existed.
  let root = "build/external_fallback_caller_provenance"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.log : [Net]
assume ext.sink : [Disk]
check ext.wrapper : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"log\")
pub fn log() -> Nil {
  sink()
}

@external(erlang, \"ext_ffi\", \"sink\")
@external(javascript, \"ext_ffi\", \"sink\")
fn sink() -> Nil

pub fn wrapper() -> Nil {
  log()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "wrapper" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Net"])))
  v.explanation.fallback
  |> should.equal(
    types.FallbackSuppressed(types.Specific(set.from_list(["Disk"]))),
  )
  checker.format_violation(r.file, v)
  |> string.contains(
    "(from your spec's `assume` line, its Gleam fallback body's charge"
    <> " suppressed by the `assume` line)",
  )
  |> should.be_true()
  support.cleanup(root)
}

pub fn infer_publishes_the_suppressed_charge_test() {
  // What `infer` writes is what consumers get, and it is the caller-side
  // charge: `assume ext.log : []` answers alone even though the fallback body
  // reaches the disk, so the published `effects ext.wrapper : []` states
  // exactly what a caller of `wrapper` pays. The undeclared control beside it
  // keeps the union: without a line, the body's effects are still published.
  let root = "build/external_fallback_infer"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "assume ext.log : []\nassume ext.sink : [Disk]\n"),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"log\")
pub fn log() -> Nil {
  sink()
}

@external(javascript, \"ext_ffi\", \"bare\")
pub fn bare() -> Nil {
  sink()
}

@external(erlang, \"ext_ffi\", \"sink\")
@external(javascript, \"ext_ffi\", \"sink\")
fn sink() -> Nil

pub fn wrapper() -> Nil {
  log()
}

pub fn bare_wrapper() -> Nil {
  bare()
}
",
    ),
  ])
  let assert Ok(preview) = graded.run_infer_dry_run(root)
  preview |> string.contains("effects ext.wrapper : []\n") |> should.be_true()
  preview
  |> string.contains("effects ext.bare_wrapper : [Disk, Unknown]")
  |> should.be_true()
  support.cleanup(root)
}

pub fn an_undeclared_externals_fallback_is_reported_by_the_query_test() {
  // Nothing declares the external, but its fallback body is ordinary code
  // graded walked, so `check` and `why` charge `[Disk, Unknown]`. The query has
  // to state the same total rather than the bare `[Unknown]` the undeclared
  // shortcut used to return, and has to say which half came from the body.
  let root = "build/external_fallback_undeclared"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #("proj.graded", "assume disk.write : [Disk]\ncheck ext.wrapper : []\n"),
    #("disk.gleam", "@external(erlang, \"d\", \"w\")\npub fn write() -> Nil\n"),
    #(
      "ext.gleam",
      "import disk

@external(javascript, \"ext_ffi\", \"log\")
pub fn log() -> Nil {
  disk.write()
}

pub fn wrapper() -> Nil {
  log()
}
",
    ),
  ])
  // What the caller is charged.
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "wrapper" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk", "Unknown"])))
  // The query answers the same total, and separates the two halves.
  let assert Ok(answered) = graded.run_effect(root, "ext.log")
  answered |> string.contains("[Disk, Unknown]") |> should.be_true()
  answered |> string.contains("fallback body") |> should.be_true()
  support.cleanup(root)
}

pub fn a_declared_externals_fallback_is_not_credited_to_the_spec_test() {
  // The declaration says `[]` and the body does `[Disk]`. The line suppresses
  // the body's half, so the answer is the declared term — and the body is
  // still named, quoted as the suppressed share, so the reader can see what
  // the line overrode rather than believing no fallback exists.
  let root = "build/external_fallback_provenance"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #("proj.graded", "assume ext.log : []\nassume ext.sink : [Disk]\n"),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"log\")
pub fn log() -> Nil {
  sink()
}

@external(erlang, \"ext_ffi\", \"sink\")
@external(javascript, \"ext_ffi\", \"sink\")
fn sink() -> Nil
",
    ),
  ])
  let assert Ok(answered) = graded.run_effect(root, "ext.log")
  answered |> string.contains("effects ext.log : []") |> should.be_true()
  answered
  |> string.contains("resolved from your spec's `assume` line")
  |> should.be_true()
  // The comment that says a body runs which the line un-charged.
  answered
  |> string.contains("suppressed by the `assume` line: [Disk]")
  |> should.be_true()
  support.cleanup(root)
}

pub fn an_external_covering_every_target_is_not_walked_test() {
  // The same fallback body under `@external` declarations for both targets: it
  // can never run, so the declaration is the whole answer and the `[]` budget
  // holds.
  let root = "build/external_every_target"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check ext.log : []\nassume ext.log : []\nassume ext.sink : [Disk]\n",
    ),
    #(
      "ext.gleam",
      "@external(erlang, \"ext_ffi\", \"log\")
@external(javascript, \"ext_ffi\", \"log\")
pub fn log() -> Nil {
  sink()
}

@external(erlang, \"ext_ffi\", \"sink\")
@external(javascript, \"ext_ffi\", \"sink\")
fn sink() -> Nil
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  r.violations |> should.equal([])
  support.cleanup(root)
}

// Foreign code on the value channels
//
// A declaration says what calling foreign code costs. It says nothing about the
// value that code hands back, and there is no declaring form that does — so the
// operator an FFI producer returns, the provenance of the record it builds, and
// the fields its factory and update-builder shapes wire are all [Unknown],
// however precise the fallback body beside them reads.

pub fn foreign_value_channels_are_opaque_test() {
  // Five channels, each paired in the fixture with the same shape written as
  // ordinary Gleam. Only the foreign half exceeds the budget the pair shares —
  // the rule refuses foreign values, not values.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/foreign_values.gleam" })
  r.violations
  |> list.map(fn(v) { v.function })
  |> list.sort(string.compare)
  |> should.equal([
    "calls_built_field", "calls_partial_operator", "calls_returned_operator",
    "calls_updated_field", "calls_via_provenance",
  ])
  list.each(r.violations, fn(v) {
    v.explanation.actual
    |> should.equal(types.Specific(set.from_list(["Unknown"])))
  })
}

pub fn a_cross_module_foreign_producer_is_opaque_test() {
  // The same channels one module away, where each reads from the knowledge base
  // rather than from the module's own AST — including a committed `returns` line
  // for the external, which is what a function that *became* `@external` leaves
  // behind until the next `infer`.
  let root = "build/foreign_values_cross_module"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.calls_returned_operator : [Disk]
check app.calls_built_field : [Disk]
check app.calls_native_built_field : [Disk]
check app.calls_via_provenance : [Disk]
assume ffi.disk_read : [Disk]
assume ffi.make : []
assume ffi.builds : []
effects ffi.make : [] where returns : []
",
    ),
    #(
      "ffi.gleam",
      "pub type Handler {
  Handler(run: fn() -> Nil, name: String)
}

@external(erlang, \"ffi_module\", \"disk_read\")
pub fn disk_read() -> Nil

@external(erlang, \"ffi_module\", \"make\")
pub fn make() -> fn() -> Nil {
  fn() { disk_read() }
}

@external(erlang, \"ffi_module\", \"builds\")
pub fn builds(run: fn() -> Nil) -> Handler {
  Handler(run: run, name: \"ffi\")
}

pub fn native_builds(run: fn() -> Nil) -> Handler {
  Handler(run: run, name: \"native\")
}

pub fn inner(handler: Handler) -> Nil {
  handler.run()
}
",
    ),
    #(
      "app.gleam",
      "import ffi

pub fn calls_returned_operator() -> Nil {
  let handle = ffi.make()
  handle()
}

pub fn calls_built_field() -> Nil {
  let handler = ffi.builds(fn() { ffi.disk_read() })
  handler.run()
}

pub fn calls_native_built_field() -> Nil {
  let handler = ffi.native_builds(fn() { ffi.disk_read() })
  handler.run()
}

pub fn calls_via_provenance() -> Nil {
  ffi.inner(ffi.builds(fn() { ffi.disk_read() }))
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  r.violations
  |> list.map(fn(v) { v.function })
  |> list.sort(string.compare)
  |> should.equal([
    "calls_built_field", "calls_returned_operator", "calls_via_provenance",
  ])
  support.cleanup(root)
}

pub fn a_dependency_returns_line_for_its_own_external_is_refused_test() {
  // A dependency published before this rule existed ships a `returns` line for
  // its own `@external`. The consumer's evidence is the dependency's source,
  // scanned under `build/packages`, so the line stops being believed the moment
  // the consumer upgrades graded — no republish needed.
  let root = "build/foreign_values_dep_returns"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "check app.wrapper : []\n"),
    #(
      "build/packages/dep/dep.graded",
      "assume dep/ffi.make : []\neffects dep/ffi.make : [] where returns : []\n",
    ),
    #(
      "build/packages/dep/src/dep/ffi.gleam",
      "@target(erlang)
@external(erlang, \"dep_ffi\", \"make\")
pub fn make() -> fn() -> Nil {
  fn() { Nil }
}
",
    ),
    #(
      "app.gleam",
      "import dep/ffi

pub fn wrapper() -> Nil {
  let handle = ffi.make()
  handle()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  support.cleanup(root)
}

pub fn a_dependency_effects_line_for_its_own_external_is_refused_test() {
  // The effects channel of the same hole: a dependency's stale `effects` line
  // for a function its own source declares `@external`. An ordinary dependency
  // function's `effects` line is untouched, so the rule is scoped to foreign
  // code rather than to dependencies.
  let root = "build/foreign_values_dep_effects"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "check app.wrapper : []\ncheck app.plain_wrapper : []\n"),
    #(
      "build/packages/dep/dep.graded",
      "effects dep/ffi.now : []\neffects dep/ffi.plain : []\n",
    ),
    #(
      "build/packages/dep/src/dep/ffi.gleam",
      "@target(erlang)
@external(erlang, \"dep_ffi\", \"now\")
pub fn now() -> Nil

pub fn plain() -> Nil {
  Nil
}
",
    ),
    #(
      "app.gleam",
      "import dep/ffi

pub fn wrapper() -> Nil {
  ffi.now()
}

pub fn plain_wrapper() -> Nil {
  ffi.plain()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("wrapper")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  support.cleanup(root)
}

pub fn a_dependency_assume_suppresses_its_walked_running_fallback_test() {
  // On erlang the dependency's fallback body is what runs; walked, it reaches
  // an external nothing declares. The dependency author's own `assume` line
  // suppresses that half all the same: the caller pays `[Time]` alone, on the
  // shipped line's say-so, and the query answers with the same term.
  let root = "build/foreign_values_dep_fallback"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "check app.wrapper : [Time]\ncheck app.strict : []\n"
        <> "check app.via_value : [Time]\n",
    ),
    #("build/packages/dep/dep.graded", "assume dep/ffi.run : [Time]\n"),
    #(
      "build/packages/dep/src/dep/ffi.gleam",
      "@external(javascript, \"dep_ffi\", \"run\")
pub fn run() -> Nil {
  hidden()
}

@external(erlang, \"dep_ffi\", \"hidden\")
fn hidden() -> Nil
",
    ),
    #(
      "app.gleam",
      "import dep/ffi

pub fn wrapper() -> Nil {
  ffi.run()
}

pub fn strict() -> Nil {
  ffi.run()
}

fn invoke(op: fn() -> Nil) -> Nil {
  op()
}

pub fn via_value() -> Nil {
  invoke(ffi.run)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  // `wrapper`'s `[Time]` budget holds — the walked body's `[Unknown]` is no
  // part of the charge — while `strict`'s `[]` budget fails on `[Time]` alone,
  // with the suppression named beside the shipped line that did it.
  let assert [violation] = r.violations
  violation.function |> should.equal("strict")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Time"])))
  violation.explanation.fallback
  |> should.equal(
    types.FallbackSuppressed(types.Specific(set.from_list(["Unknown"]))),
  )
  checker.format_violation(r.file, violation)
  |> string.contains(
    "(from dep's shipped spec, its Gleam fallback body's charge suppressed"
    <> " by the `assume` line)",
  )
  |> should.be_true()
  // The value channel reads the same suppressed term — `via_value`'s `[Time]`
  // budget held above — and so does the query, which quotes the walked share
  // it dropped.
  let assert Ok(answered) = graded.run_effect(root, "dep/ffi.run")
  answered
  |> string.contains("effects dep/ffi.run : [Time]")
  |> should.be_true()
  answered
  |> string.contains("suppressed by the `assume` line: [Unknown]")
  |> should.be_true()
  support.cleanup(root)
}

pub fn a_project_assume_suppresses_for_callers_but_not_its_own_line_test() {
  // The split, on both `why` surfaces at once: a caller pays the declared
  // term alone and its explanation names the suppression, while the
  // external's own line still weighs the walked body — `check` is the
  // verified channel, and an `assume` changes what callers pay, never what
  // the function's own line proves.
  let root = "build/external_fallback_own_line_split"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.log : [Net]
assume ext.sink : [Disk]
check ext.log : [Disk, Net]
check app.wrapper : [Net]
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"log\")
pub fn log() -> Nil {
  sink()
}

@external(erlang, \"ext_ffi\", \"sink\")
@external(javascript, \"ext_ffi\", \"sink\")
fn sink() -> Nil
",
    ),
    #(
      "app.gleam",
      "import ext

pub fn wrapper() -> Nil {
  ext.log()
}
",
    ),
  ])
  // The external's own budget covers declaration and body; the caller's
  // covers the declaration alone. Both hold.
  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])
  // The caller's `why` names the suppression; the external's own does not —
  // its line reports the declaration with the body as a contributor beside
  // it, still weighed into the body-inclusive total.
  let assert Ok(caller_why) = graded.run_why(root, "app.wrapper")
  caller_why
  |> string.contains(
    "its Gleam fallback body's charge suppressed by the `assume` line",
  )
  |> should.be_true()
  let assert Ok(own_why) = graded.run_why(root, "ext.log")
  own_why |> string.contains("suppressed") |> should.be_false()
  own_why |> string.contains("[Disk, Net]") |> should.be_true()
  support.cleanup(root)
}

pub fn a_catalog_declaration_keeps_the_union_test() {
  // The catalog describes a version graded's maintainers annotated, not
  // necessarily the installed body, so a catalog `assume` never suppresses —
  // the running body's half stays in the union, worded as such. The
  // consumer's clause-only `where returns` line on the same name is trusted
  // all the same: the clause is the user's own written line, so the returned
  // operator answers while the effects half keeps the catalog∪body union —
  // two channels, two winning lines, each trusted by its own author.
  let root = "build/external_fallback_catalog_union"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "manifest.toml",
      "packages = [\n  { name = \"envoy\", version = \"1.0.0\" },\n]\n",
    ),
    #(
      "proj.graded",
      "assume envoy.get where returns : [Net]
check app.uses : []
",
    ),
    #(
      "build/packages/envoy/src/envoy.gleam",
      "@external(javascript, \"./envoy_ffi.mjs\", \"get\")
pub fn get() -> fn() -> Nil {
  side()
  fn() { Nil }
}

@external(erlang, \"envoy_ffi\", \"side\")
fn side() -> Nil
",
    ),
    #(
      "app.gleam",
      "import envoy

pub fn uses() -> Nil {
  let handle = envoy.get()
  handle()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  // The producer call pays the catalog's term unioned with the walked body's
  // `[Unknown]`, and says so...
  let assert Ok(producer) =
    list.find(r.violations, fn(v) { v.explanation.call.module == "envoy" })
  producer.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Environment", "Unknown"])))
  checker.format_violation(r.file, producer)
  |> string.contains(
    "(from envoy's catalog entry, unioned with its Gleam fallback body)",
  )
  |> should.be_true()
  // ...while the returned operator answers from the consumer's own clause.
  let assert Ok(applied) =
    list.find(r.violations, fn(v) { v.explanation.call.module == "<returned>" })
  applied.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Net"])))
  support.cleanup(root)
}

pub fn a_dependency_external_this_build_never_reaches_is_unknown_test() {
  // The declaration is for JavaScript, this package names Erlang, and `run` has
  // no Gleam body to run in its place — so nothing this build compiles
  // implements the name, and `[Unknown]` is the whole charge. The message says
  // so: charging `[Time]` named an implementation provably not built, and
  // reporting it as an external with no declared effects sent the reader looking
  // for a declaration the dependency plainly ships.
  let root = "build/foreign_values_dep_unreachable"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\ntarget = \"erlang\"\n"),
    #("proj.graded", "check app.wrapper : [Time]\n"),
    #("build/packages/dep/dep.graded", "assume dep/ffi.run : [Time]\n"),
    #(
      "build/packages/dep/src/dep/ffi.gleam",
      "@external(javascript, \"dep_ffi\", \"run\")
pub fn run() -> Nil
",
    ),
    #(
      "app.gleam",
      "import dep/ffi

pub fn wrapper() -> Nil {
  ffi.run()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  violation.explanation.reason
  |> should.equal(Some(types.UnbuiltExternal))
  let message = checker.format_violation(root <> "/app.gleam", violation)
  message
  |> string.contains(
    "an external declared only for a target this build does not compile",
  )
  |> should.be_true()
  message
  |> string.contains("with no declared effects")
  |> should.be_false()
  // And the query says the same thing about the same name. Carrying the
  // declaration's source alongside the `[Unknown]` it collapsed to credited
  // dep's shipped `[Time]` line with a charge that line states no part of.
  let assert Ok(answered) = graded.run_effect(root, "dep/ffi.run")
  answered
  |> string.contains(
    "an external declared only for a target this build does not compile",
  )
  |> should.be_true()
  answered |> string.contains("shipped spec") |> should.be_false()
  answered
  |> should.equal(
    graded.run_effect_from_project(root, "dep/ffi.run") |> should.be_ok(),
  )
  support.cleanup(root)
}

pub fn a_default_target_package_keeps_a_dependency_fallback_out_of_reach_test() {
  // The reading that decides it: a package naming no `target` reads Gleam
  // fallback bodies on the compiler's own default, so the dependency's erlang
  // declaration is the whole answer and the body beside it never runs. Reading
  // bodies on *every* target instead ran this one on the other target and
  // unioned an unwalked `[Unknown]` into a large part of the standard library.
  let root = "build/foreign_values_dep_default_target"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "check app.wrapper : [Time]\n"),
    #("build/packages/dep/dep.graded", "assume dep/ffi.run : [Time]\n"),
    #(
      "build/packages/dep/src/dep/ffi.gleam",
      "@external(erlang, \"dep_ffi\", \"run\")
pub fn run() -> Nil {
  Nil
}
",
    ),
    #(
      "app.gleam",
      "import dep/ffi

pub fn wrapper() -> Nil {
  ffi.run()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])
  support.cleanup(root)
}

pub fn a_defaulted_target_package_keeps_a_declared_external_test() {
  // `gleam.toml` names no target, so the compiler's default stands in for the
  // build — and a `gleam build --target javascript` graded never sees compiles
  // this declaration. So the assumed default decides nothing that would drop it:
  // `now` stays foreign code, the author's line keeps answering for it, and a
  // caller is charged the `[Time]` beside the pure fallback body's nothing.
  let root = "build/defaulted_target_declared_external"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ffi.now : [Time]
check app.wrapper : []
",
    ),
    #(
      "ffi.gleam",
      "@external(javascript, \"ffi_js\", \"now\")
pub fn now() -> Nil {
  Nil
}
",
    ),
    #(
      "app.gleam",
      "import ffi

pub fn wrapper() -> Nil {
  ffi.now()
}
",
    ),
  ])

  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Time"])))
  // And nothing calls the line stale — the spec file is reported on only when it
  // has a warning — so `infer` leaves it where it is rather than replacing it
  // with what the fallback body does.
  list.find(results, fn(r) { r.file == root <> "/proj.graded" })
  |> should.equal(Error(Nil))
  let assert Ok(_) = graded.run_infer(root)
  let assert Ok(written) = simplifile.read(root <> "/proj.graded")
  written
  |> string.contains("assume ffi.now : [Time]")
  |> should.be_true()
  support.cleanup(root)
}

pub fn every_command_reads_a_dependency_external_on_the_same_targets_test() {
  // One name, three surfaces. The dependency's declaration is for JavaScript,
  // this package names Erlang, and what runs there is the dependency's Gleam
  // body — walked, and it writes to disk — so all three answer `[Disk]` and none
  // of them the declaration's `[Time]`. The walk narrowed and the query did not,
  // so `check` charged the caller the body's effects while `effect` answered
  // with the declaration.
  let root = "build/dep_external_command_agreement"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\ntarget = \"erlang\"\n"),
    #("proj.graded", "check app.wrapper : []\n"),
    #(
      "build/packages/dep/dep.graded",
      "assume dep/ffi.run : [Time]\nassume dep/ffi.scribble : [Disk]\n",
    ),
    #(
      "build/packages/dep/src/dep/ffi.gleam",
      "@external(javascript, \"dep_ffi\", \"run\")
pub fn run() -> Nil {
  scribble()
}

@external(erlang, \"dep_ffi\", \"scribble\")
pub fn scribble() -> Nil
",
    ),
    #(
      "app.gleam",
      "import dep/ffi

pub fn wrapper() -> Nil {
  ffi.run()
}
",
    ),
  ])

  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))

  let assert Ok(answered) = graded.run_effect(root, "dep/ffi.run")
  answered |> string.contains("[Disk]") |> should.be_true()
  answered |> string.contains("Time") |> should.be_false()
  // The source line names what the charge came from, in `why`'s words: the body
  // running in the declaration's place. Naming the shipped spec instead pointed
  // at the very line the `[Unknown]` beside it had ruled out.
  answered
  |> string.contains(
    "its Gleam fallback body, which is what runs on the targets this build"
    <> " compiles",
  )
  |> should.be_true()
  answered |> string.contains("shipped spec") |> should.be_false()
  // The fast path and the full context agree, as they must for any name.
  answered
  |> should.equal(
    graded.run_effect_from_project(root, "dep/ffi.run")
    |> should.be_ok(),
  )

  let assert Ok(why) = graded.run_why(root, "app.wrapper")
  why |> string.contains("[Disk]") |> should.be_true()
  why |> string.contains("Time") |> should.be_false()
  support.cleanup(root)
}

pub fn a_defaulted_target_package_reads_its_own_fallback_the_same_way_test() {
  // One `@external(erlang, …)` of this package's, with a Gleam fallback that
  // reaches the disk, under a `gleam.toml` naming no target. Erlang is what the
  // compiler builds when nothing says otherwise, and the declaration covers it,
  // so nothing runs that body: `check`, `why`, `effect` and the caller's charge
  // all say `[Time]`.
  //
  // The walk read the body on every target and the knowledge base read it on the
  // default, so a `check` line matching what every caller pays failed on a
  // `[Disk]` the assumed build never performs — and `why` totalled a set
  // `effect` disagreed with, for the stdlib-shaped FFI a default-configured
  // project writes.
  let defaulted = "build/defaulted_target_own_fallback"
  let named = "build/named_target_own_fallback"
  let sources = [
    #(
      "proj.graded",
      "assume ffi.now : [Time]
assume sink.disk : [Disk]
check ffi.now : [Time]
",
    ),
    #(
      "sink.gleam",
      "@external(erlang, \"sink_ffi\", \"disk\")
pub fn disk() -> Nil
",
    ),
    #(
      "ffi.gleam",
      "import sink

@external(erlang, \"ffi_ffi\", \"now\")
pub fn now() -> Nil {
  sink.disk()
}
",
    ),
    #(
      "app.gleam",
      "import ffi

pub fn tick() -> Nil {
  ffi.now()
}
",
    ),
  ]
  support.write_fixture(defaulted, [
    #("gleam.toml", "name = \"proj\"\n"),
    ..sources
  ])
  // The same package saying out loud what the default assumed, which is the
  // configuration the fix aligns the defaulted one with.
  support.write_fixture(named, [
    #("gleam.toml", "name = \"proj\"\ntarget = \"erlang\"\n"),
    ..sources
  ])

  let assert Ok(results) = graded.check_project(defaulted)
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])
  results |> list.flat_map(fn(r) { r.warnings }) |> should.equal([])

  let assert Ok(why) = graded.run_why(defaulted, "ffi.now")
  why |> string.contains("[Time]") |> should.be_true()
  why |> string.contains("Disk") |> should.be_false()

  let assert Ok(answered) = graded.run_effect(defaulted, "ffi.now")
  answered |> string.contains("[Time]") |> should.be_true()
  answered |> string.contains("Disk") |> should.be_false()
  answered
  |> should.equal(
    graded.run_effect_from_project(defaulted, "ffi.now") |> should.be_ok(),
  )

  let assert Ok(caller) = graded.run_why(defaulted, "app.tick")
  caller |> string.contains("[Time]") |> should.be_true()
  caller |> string.contains("Disk") |> should.be_false()

  // And every one of them reads as the named-target package does, word for word.
  let assert Ok(named_results) = graded.check_project(named)
  named_results
  |> list.flat_map(fn(r) { r.violations })
  |> should.equal([])
  graded.run_why(named, "ffi.now") |> should.equal(Ok(why))
  graded.run_effect(named, "ffi.now") |> should.equal(Ok(answered))
  graded.run_why(named, "app.tick") |> should.equal(Ok(caller))

  support.cleanup(defaulted)
  support.cleanup(named)
}

pub fn an_unbuilt_own_external_reads_the_same_on_every_surface_test() {
  // `jsonly` declares JavaScript, the build compiles Erlang, and there is no
  // Gleam body to run in its place — so nothing this build reaches implements
  // the name. Every caller is charged `[Unknown]`, and the function's own budget
  // is charged the same: weighing the spec's `[Time]` against it alone held the
  // function to a declaration the same build had ruled out for everyone calling
  // it, so `check` and `why` said `[Time]` where `effect` and the callers said
  // `[Unknown]`.
  let root = "build/unbuilt_own_external_surfaces"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\ntarget = \"erlang\"\n"),
    #(
      "proj.graded",
      "assume ffi.jsonly : [Time]
check ffi.jsonly : []
check app.wrapper : []
",
    ),
    #(
      "ffi.gleam",
      "@external(javascript, \"ffi_js\", \"jsonly\")
pub fn jsonly() -> Nil
",
    ),
    #(
      "app.gleam",
      "import ffi

pub fn wrapper() -> Nil {
  ffi.jsonly()
}
",
    ),
  ])

  let assert Ok(results) = graded.check_project(root)
  let assert Ok(own) =
    list.find(results, fn(r) { r.file == root <> "/ffi.gleam" })
  let assert [own_violation] = own.violations
  own_violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  own_violation.explanation.reason |> should.equal(Some(types.UnbuiltExternal))
  own_violation.explanation.origin |> should.equal(None)
  // The caller pays what the function's own line was weighed against, for the
  // same recorded reason.
  let assert Ok(caller) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [caller_violation] = caller.violations
  caller_violation.explanation.actual
  |> should.equal(own_violation.explanation.actual)
  caller_violation.explanation.reason
  |> should.equal(own_violation.explanation.reason)

  let assert Ok(why) = graded.run_why(root, "ffi.jsonly")
  why |> string.contains("[Unknown]") |> should.be_true()
  why |> string.contains("Time") |> should.be_false()
  why
  |> string.contains("declared only for a target this build does not compile")
  |> should.be_true()

  let assert Ok(answered) = graded.run_effect(root, "ffi.jsonly")
  answered |> string.contains("[Unknown]") |> should.be_true()
  answered |> string.contains("Time") |> should.be_false()
  answered
  |> string.contains(
    "an external declared only for a target this build does not compile",
  )
  |> should.be_true()
  support.cleanup(root)
}

pub fn a_wired_field_reads_a_foreign_value_as_a_call_does_test() {
  // Two dependency `@external`s reaching their call sites wired into a record
  // field rather than named, each with a cause of its own. `unbuilt` is shipped
  // as `[Time]` over a JavaScript-only declaration this Erlang build never
  // compiles; `bare` is compiled here and declared nowhere. Both are charged
  // what a direct call to them is charged and say why in the same words —
  // naming the shipped spec pointed the reader at the very line the `[Unknown]`
  // beside it had ruled out, and reporting the unbuilt one as undeclared named
  // a cause the other surfaces do not.
  let root = "build/wired_field_foreign_value"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\ntarget = \"erlang\"\n"),
    #("proj.graded", "check app.tick : []\ncheck app.tock : []\n"),
    #("build/packages/dep/dep.graded", "assume dep/ffi.unbuilt : [Time]\n"),
    #(
      "build/packages/dep/src/dep/ffi.gleam",
      "@external(javascript, \"dep_ffi\", \"unbuilt\")
pub fn unbuilt() -> Nil

@external(erlang, \"dep_ffi\", \"bare\")
pub fn bare() -> Nil
",
    ),
    #(
      "app.gleam",
      "import dep/ffi

pub type Clock {
  Clock(read: fn() -> Nil)
}

pub fn build_unbuilt() -> Clock {
  Clock(read: ffi.unbuilt)
}

pub fn build_bare() -> Clock {
  Clock(read: ffi.bare)
}

pub fn tick() -> Nil {
  let c = build_unbuilt()
  c.read()
}

pub fn tock() -> Nil {
  let c = build_bare()
  c.read()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })

  let assert Ok(unbuilt) =
    list.find(r.violations, fn(violation) { violation.function == "tick" })
  unbuilt.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  unbuilt.explanation.reason |> should.equal(Some(types.UnbuiltExternal))
  unbuilt.explanation.origin |> should.equal(None)
  let unbuilt_message = checker.format_violation(r.file, unbuilt)
  unbuilt_message
  |> string.contains(
    "wired to an external declared only for a target this build does not"
    <> " compile",
  )
  |> should.be_true()
  unbuilt_message |> string.contains("shipped spec") |> should.be_false()

  let assert Ok(bare) =
    list.find(r.violations, fn(violation) { violation.function == "tock" })
  bare.explanation.reason |> should.equal(Some(types.UndeclaredExternal))
  checker.format_violation(r.file, bare)
  |> string.contains("wired to an external with no declared effects")
  |> should.be_true()

  // And `why` prints the line each violation does, as it does for every other
  // contributor.
  let assert Ok(why) = graded.run_why(root, "app.tick")
  why
  |> string.contains(
    "wired to an external declared only for a target this build does not"
    <> " compile",
  )
  |> should.be_true()
  let assert Ok(why) = graded.run_why(root, "app.tock")
  why
  |> string.contains("wired to an external with no declared effects")
  |> should.be_true()
  support.cleanup(root)
}

// The `why` line reporting `name` as a contributor, or `Error(Nil)` where no
// line names it.
fn contributor_line(output: String, name: String) -> Result(String, Nil) {
  string.split(output, "\n")
  |> list.filter(string.contains(_, " " <> name <> " "))
  |> list.first
}

// Declared FFI returns
//
// `external returns` declares the operator a foreign producer hands back — the
// one value channel a declaration reaches. It answers on both resolution paths
// (a same-module `@external` and a cross-module one), only where the
// declaration stands alone against what the build compiles, and only ground.

pub fn a_declared_return_resolves_a_same_module_producer_test() {
  // The producer and its caller in one module: the callee is keyed with no
  // module at all, so this path never consults the knowledge base for an
  // ordinary summary. The declaration is the only thing that can answer, and
  // the same fixture without the line is what says the budget is not vacuous.
  let root = "build/declared_returns_same_module"
  let declared = same_module_violations(root, declared_same_module_spec)
  declared |> should.equal([])

  let undeclared = same_module_violations(root, inferred_same_module_spec)
  let assert [violation] = undeclared
  violation.function |> should.equal("caller")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn a_declared_return_resolves_a_cross_module_producer_test() {
  // One module away, where the summary is read from the knowledge base. The
  // record-building external beside it stays opaque: the declaration describes
  // the returned operator and nothing else, so the provenance channel is
  // unchanged.
  let root = "build/declared_returns_cross_module"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.calls_returned_operator : [Disk]
check app.calls_built_field : [Disk]
assume ffi.disk_read : [Disk]
assume ffi.make : []
assume ffi.builds : []
assume ffi.make where returns : [Disk]
",
    ),
    #(
      "ffi.gleam",
      "pub type Handler {
  Handler(run: fn() -> Nil, name: String)
}

@external(erlang, \"ffi_module\", \"disk_read\")
@external(javascript, \"ffi_module\", \"disk_read\")
pub fn disk_read() -> Nil

@external(erlang, \"ffi_module\", \"make\")
@external(javascript, \"ffi_module\", \"make\")
pub fn make() -> fn() -> Nil

@external(erlang, \"ffi_module\", \"builds\")
pub fn builds(run: fn() -> Nil) -> Handler {
  Handler(run: run, name: \"ffi\")
}
",
    ),
    #(
      "app.gleam",
      "import ffi

pub fn calls_returned_operator() -> Nil {
  let handle = ffi.make()
  handle()
}

pub fn calls_built_field() -> Nil {
  let handler = ffi.builds(fn() { ffi.disk_read() })
  handler.run()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  r.violations
  |> list.map(fn(v) { v.function })
  |> should.equal(["calls_built_field"])
  support.cleanup(root)
}

pub fn a_polymorphic_declared_return_is_not_loaded_test() {
  // The operator's `f` is the producer's own parameter, left free: substituting
  // through it is exactly what a serialized summary is refused for, since
  // nothing sanitized the name. The loader drops the line rather than trusting
  // it, so the call stays [Unknown].
  let root = "build/declared_returns_polymorphic"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.calls_wrapped : []
assume ffi.wrap : []
assume ffi.wrap where returns : [f]
",
    ),
    #(
      "ffi.gleam",
      "@external(erlang, \"ffi_module\", \"wrap\")
@external(javascript, \"ffi_module\", \"wrap\")
pub fn wrap(callback: fn() -> Nil) -> fn() -> Nil
",
    ),
    #(
      "app.gleam",
      "import ffi

pub fn calls_wrapped() -> Nil {
  let wrapped = ffi.wrap(fn() { Nil })
  wrapped()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  support.cleanup(root)
}

pub fn a_declared_return_out_of_reach_answers_nothing_test() {
  // The declaration names a target this build does not compile, so nothing it
  // describes is what runs — the same reading that drops the external's own
  // declared effects drops what it declares about the value.
  let root = "build/declared_returns_unbuilt"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\ntarget = \"erlang\"\n"),
    #(
      "proj.graded",
      "check app.calls_returned_operator : []
assume ffi.make : []
assume ffi.make where returns : []
",
    ),
    #(
      "ffi.gleam",
      "@external(javascript, \"ffi_module\", \"make\")
pub fn make() -> fn() -> Nil
",
    ),
    #(
      "app.gleam",
      "import ffi

pub fn calls_returned_operator() -> Nil {
  let handle = ffi.make()
  handle()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  // The producer call is charged [Unknown] too — nothing this build compiles
  // implements it — so the applied operator is picked out by its own sentinel.
  let assert Ok(applied) =
    list.find(r.violations, fn(v) { v.explanation.call.module == "<returned>" })
  applied.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  applied.explanation.reason |> should.equal(Some(types.UnbuiltExternal))
  // And it says what a direct call to the same `@external` says: one reading,
  // one sentence, two channels.
  checker.format_violation(r.file, applied)
  |> string.contains(
    "an external declared only for a target this build does not compile",
  )
  |> should.be_true()
  support.cleanup(root)
}

pub fn a_declared_return_beside_a_suppressed_fallback_answers_test() {
  // Both halves in reach: the foreign implementation on the target the line
  // names, the Gleam body on the one it leaves uncovered. The clause is the
  // user's own written line, and a written clause is trusted whole — the
  // refusal that stood here lifts on the clause's own suppressing source, so
  // both producers' closures resolve and every budget holds. (The refusing
  // arm survives for a clause from a non-suppressing origin; no such origin
  // ships clauses until a catalog returns tier exists, which is where it must
  // be pinned.)
  let root = "build/declared_returns_fallback"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.calls_partial : []
check app.calls_covered : []
assume ffi.partial : []
assume ffi.covered : []
assume ffi.partial where returns : []
assume ffi.covered where returns : []
",
    ),
    #(
      "ffi.gleam",
      "@external(javascript, \"ffi_module\", \"partial\")
pub fn partial() -> fn() -> Nil {
  fn() { Nil }
}

@external(erlang, \"ffi_module\", \"covered\")
@external(javascript, \"ffi_module\", \"covered\")
pub fn covered() -> fn() -> Nil
",
    ),
    #(
      "app.gleam",
      "import ffi

pub fn calls_partial() -> Nil {
  let handle = ffi.partial()
  handle()
}

pub fn calls_covered() -> Nil {
  let handle = ffi.covered()
  handle()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  r.violations |> should.equal([])
  support.cleanup(root)
}

pub fn infer_and_check_agree_about_a_declared_return_test() {
  // The declaration is state no inference pass re-derives, so both commands
  // have to load it: `infer` publishes what `check` scores. The stale inferred
  // `returns` line beside it is the window an author is in between the function
  // becoming `@external` and the next `infer` — the declaration answers over it.
  let root = "build/declared_returns_infer"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.caller : [Net]
assume ffi.make_client : [Net] where returns : [Net]
effects ffi.make_client : [] where returns : [Disk]
",
    ),
    #(
      "ffi.gleam",
      "@external(erlang, \"ffi_module\", \"make_client\")
@external(javascript, \"ffi_module\", \"make_client\")
pub fn make_client() -> fn() -> Nil
",
    ),
    #(
      "app.gleam",
      "import ffi

pub fn caller() -> Nil {
  let send = ffi.make_client()
  send()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])

  let assert Ok(Nil) = graded.run_infer(root)
  let assert Ok(written) = simplifile.read(root <> "/proj.graded")
  written |> string.contains("effects app.caller : [Net]") |> should.be_true()
  written
  |> string.contains("assume ffi.make_client : [Net] where returns : [Net]")
  |> should.be_true()
  support.cleanup(root)
}

pub fn a_dependency_declares_what_its_own_producer_returns_test() {
  // The dep author's line about their own `@external` factory. The consumer
  // reads it from the shipped spec, tagged as the declaration it is — tagged
  // like an inferred summary instead, the whole tier would no-op, since a
  // dependency's declared name is foreign by definition.
  let root = "build/declared_returns_dep"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "check app.wrapper : []\n"),
    #(
      "build/packages/dep/dep.graded",
      "assume dep/ffi.make : []
assume dep/ffi.make where returns : [Disk]
",
    ),
    #(
      "build/packages/dep/src/dep/ffi.gleam",
      "@external(erlang, \"dep_ffi\", \"make\")
@external(javascript, \"dep_ffi\", \"make\")
pub fn make() -> fn() -> Nil
",
    ),
    #(
      "app.gleam",
      "import dep/ffi

pub fn wrapper() -> Nil {
  let handle = ffi.make()
  handle()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_path_dependency_declares_what_its_own_producer_returns_test() {
  // The same line one dependency kind over, where the spec is committed beside
  // the source rather than shipped under build/packages.
  let r =
    run_path_dep_spec_fixture(
      "declared_returns_path_dep",
      [
        #(
          "dep.gleam",
          "@external(erlang, \"dep_ffi\", \"make\")
@external(javascript, \"dep_ffi\", \"make\")
pub fn make() -> fn() -> Nil
",
        ),
      ],
      "assume dep.make : []
assume dep.make where returns : [Disk]
",
      "check app.wrapper : []\n",
      "import dep

pub fn wrapper() -> Nil {
  let handle = dep.make()
  handle()
}
",
    )
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

pub fn a_dependency_declares_a_return_for_its_own_gleam_function_test() {
  // Over one of the dependency's *ordinary* functions the line is kept, not
  // dropped: arbitrating a spec against the source beside it is the dep author's
  // job at their own `infer` time, and the effects channel already trusts their
  // `assume` line in exactly this position.
  let root = "build/declared_returns_dep_native"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "check app.wrapper : []\n"),
    #(
      "build/packages/dep/dep.graded",
      "effects dep/ffi.make : []
assume dep/ffi.make where returns : [Disk]
",
    ),
    #(
      "build/packages/dep/src/dep/ffi.gleam",
      "pub fn make() -> fn() -> Nil {
  fn() { Nil }
}
",
    ),
    #(
      "app.gleam",
      "import dep/ffi

pub fn wrapper() -> Nil {
  let handle = ffi.make()
  handle()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_stale_returns_clauses_line_is_ignored_and_repaired_test() {
  // The line names one of this package's own ordinary functions, whose returned
  // closure every caller can see for itself — so it declares nothing. It is
  // ignored at load, not merely warned about: trusted between `infer` runs it
  // would be a per-function override of the walk. `infer` then deletes it and
  // writes the clause it was suppressing.
  let root = "build/declared_returns_stale"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.caller : []
assume lib.make where returns : [Disk]
",
    ),
    #(
      "lib.gleam",
      "pub fn make() -> fn() -> Nil {
  fn() { Nil }
}
",
    ),
    #(
      "app.gleam",
      "import lib

pub fn caller() -> Nil {
  let handle = lib.make()
  handle()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])

  let assert Ok(preview) = graded.run_infer_dry_run(root)
  let changed =
    preview
    |> string.split("\n")
    |> list.filter(fn(line) {
      string.starts_with(line, "- ") || string.starts_with(line, "+ ")
    })
  changed
  |> list.contains("- assume lib.make where returns : [Disk]")
  |> should.be_true()
  changed
  |> list.contains("+ effects lib.make : [] where returns : []")
  |> should.be_true()
  support.cleanup(root)
}

pub fn a_declared_return_leaves_the_effects_channel_alone_test() {
  // The two stale channels are separate sets. Were the returns one to reach the
  // effects channel's filters, the committed `effects lib.make` line would be
  // dropped and the call charged by inference instead — so the call's [Stdout]
  // is what says they stayed apart, and the applied operator's absence from the
  // charge is what says the stale declaration was still ignored.
  let root = "build/declared_returns_cross_channel"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.caller : []
effects lib.make : [Stdout]
assume lib.make where returns : [Disk]
",
    ),
    #(
      "lib.gleam",
      "pub fn make() -> fn() -> Nil {
  fn() { Nil }
}
",
    ),
    #(
      "app.gleam",
      "import lib

pub fn caller() -> Nil {
  let handle = lib.make()
  handle()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
  support.cleanup(root)
}

pub fn the_lint_flags_every_dead_external_returns_line_test() {
  // The four ways the line can be dead, and the one live line beside them. Two
  // are the existence branches the `assume` lint already had; two are
  // this form's own, and both are lines the loader silently drops — the warning
  // is the only place a reader learns the line does nothing.
  let root = "build/declared_returns_lint"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ffi.wrap where returns : [f]
assume lib where returns : [Net]
assume lib.make where returns : [Disk]
assume lib.nope where returns : [Disk]
assume ffi.make where returns : [Net]
",
    ),
    #(
      "ffi.gleam",
      "@external(erlang, \"ffi_module\", \"wrap\")
@external(javascript, \"ffi_module\", \"wrap\")
pub fn wrap(callback: fn() -> Nil) -> fn() -> Nil

@external(erlang, \"ffi_module\", \"make\")
@external(javascript, \"ffi_module\", \"make\")
pub fn make() -> fn() -> Nil
",
    ),
    #(
      "lib.gleam",
      "pub fn make() -> fn() -> Nil {
  fn() { Nil }
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  results
  |> list.flat_map(fn(r) { r.warnings })
  |> should.equal([
    types.UngroundReturnsClauseWarning(function: "ffi.wrap", free_vars: ["f"]),
    types.DotlessReturnsClauseWarning(name: "lib"),
    types.StaleReturnsClauseWarning(function: "lib.make"),
    types.UnmatchedReturnsClauseWarning(function: "lib.nope"),
  ])
  support.cleanup(root)
}

pub fn the_lint_scopes_a_declared_clause_by_its_bounds_test() {
  // The bounded-line lint cases together: a clause closed by the line's own
  // bounds is silent; a clause with an unscoped variable names only that
  // variable; a ground clause on a boundless line is still silent; and a
  // bounded term variable no payload binds gets the term oracle's own warning
  // — while a boundless polymorphic assume is deliberately not linted.
  let root = "build/bounded_assume_lint"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ffi.wrap(cb: [cb]) where returns : [cb]
assume ffi.make where returns : [Net]
assume ffi.trace(cb: [cb]) : [] where returns : [cb, zz]
assume ffi.each(f: [Stdout]) : [x]
assume ffi.fold(g: [g]) : [g]
",
    ),
    #(
      "ffi.gleam",
      support.foreign_fn("wrap", "(cb: fn() -> Nil) -> fn() -> Nil")
        <> "\n"
        <> support.foreign_fn("make", "() -> fn() -> Nil")
        <> "\n"
        <> support.foreign_fn("trace", "(cb: fn() -> Nil) -> fn() -> Nil")
        <> "\n"
        <> support.foreign_fn("each", "(f: fn() -> Nil) -> Nil")
        <> "\n"
        <> support.foreign_fn("fold", "(g: fn() -> Nil) -> Nil"),
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  // `ffi.fold`'s term variable is covered by its bound's payload, so the term
  // oracle stays silent for it.
  results
  |> list.flat_map(fn(r) { r.warnings })
  |> should.equal([
    types.UnboundAssumeTermVariableWarning(function: "ffi.each", free_vars: [
      "x",
    ]),
    types.UngroundReturnsClauseWarning(function: "ffi.trace", free_vars: [
      "zz",
    ]),
  ])
  support.cleanup(root)
}

pub fn the_lint_flags_an_aliased_bound_payload_test() {
  // `cb: [e], other: [cb]`: the line's term and clause both spell `cb`, which
  // the payload channel binds to `other`'s argument and the name channel to
  // `cb`'s own — so the lint names the variable beside the payload that
  // captures it, on the `assume` line and its `effects` twin alike. The plain
  // decoupled line and the self-referential one stay silent, and so does an
  // aliased list whose variable the line never uses.
  let root = "build/aliased_bound_lint"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ffi.wrap(cb: [e], other: [cb]) : [cb] where returns : [cb]
assume ffi.plain(cb: [e]) : [e]
assume ffi.own(cb: [cb]) : [cb]
assume ffi.unused(cb: [e], other: [cb]) : [Net]
effects app.twin(cb: [e], other: [cb]) : [cb] where returns : [cb]
",
    ),
    #(
      "ffi.gleam",
      support.foreign_fn(
        "wrap",
        "(cb: fn() -> Nil, other: fn() -> Nil) -> fn() -> Nil",
      )
        <> "\n"
        <> support.foreign_fn("plain", "(cb: fn() -> Nil) -> Nil")
        <> "\n"
        <> support.foreign_fn("own", "(cb: fn() -> Nil) -> Nil")
        <> "\n"
        <> support.foreign_fn(
        "unused",
        "(cb: fn() -> Nil, other: fn() -> Nil) -> Nil",
      ),
    ),
    #(
      "app.gleam",
      "pub fn twin(cb: fn() -> Nil, other: fn() -> Nil) -> fn() -> Nil {\n  other()\n  cb\n}\n",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  results
  |> list.flat_map(fn(r) { r.warnings })
  |> should.equal([
    types.AliasedBoundVariableWarning(function: "ffi.wrap", variables: [
      #("cb", "other"),
    ]),
    types.AliasedBoundVariableWarning(function: "app.twin", variables: [
      #("cb", "other"),
    ]),
  ])
  support.cleanup(root)
}

pub fn a_later_self_binding_emits_no_alias_warning_test() {
  // Regression: on `other: [cb], cb: [cb]` the binding fold's last binder
  // for `cb` is the parameter `cb` itself, so the term and clause channels
  // agree and the line warns nothing — on the `assume` line and its
  // `effects` twin alike. The reversed list, where the alias binds last,
  // still warns.
  let root = "build/aliased_bound_lint_order"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ffi.wrap(other: [cb], cb: [cb]) : [cb] where returns : [cb]
assume ffi.flip(cb: [cb], other: [cb]) : [cb] where returns : [cb]
effects app.twin(other: [cb], cb: [cb]) : [cb] where returns : [cb]
",
    ),
    #(
      "ffi.gleam",
      support.foreign_fn(
        "wrap",
        "(other: fn() -> Nil, cb: fn() -> Nil) -> fn() -> Nil",
      )
        <> "\n"
        <> support.foreign_fn(
        "flip",
        "(cb: fn() -> Nil, other: fn() -> Nil) -> fn() -> Nil",
      ),
    ),
    #(
      "app.gleam",
      "pub fn twin(other: fn() -> Nil, cb: fn() -> Nil) -> fn() -> Nil {\n  other()\n  cb\n}\n",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  results
  |> list.flat_map(fn(r) { r.warnings })
  |> should.equal([
    types.AliasedBoundVariableWarning(function: "ffi.flip", variables: [
      #("cb", "other"),
    ]),
  ])
  support.cleanup(root)
}

pub fn the_term_oracle_skips_a_dead_external_test() {
  // A stale line (over a visible Gleam body) and an unmatched one (naming
  // nothing anywhere) each get the existence channel's warning alone: the
  // term oracle stays silent on a line whose one fix is removal, even though
  // both terms name a variable no payload binds.
  let root = "build/dead_external_term_oracle"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume app.local(cb: [cb]) : [zz]
assume nowhere.gone(cb: [cb]) : [zz]
",
    ),
    #("app.gleam", "pub fn local(cb: fn() -> Nil) -> Nil {\n  cb()\n}\n"),
  ])
  let assert Ok(results) = graded.check_project(root)
  results
  |> list.flat_map(fn(r) { r.warnings })
  |> should.equal([
    types.StaleFunctionAssumeWarning(function: "app.local"),
    types.UnmatchedFunctionAssumeWarning(function: "nowhere.gone"),
  ])
  support.cleanup(root)
}

pub fn why_names_the_declaration_that_resolved_a_producer_test() {
  // The call used to print ", whose producer could not be resolved,". It now
  // names the line that answered, in the words that say *declaration* rather
  // than a file name — which is the distinction the feature exists to surface.
  let root = "build/declared_returns_why"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.caller : [Net]
assume ffi.make_client : [Net]
assume ffi.make_client where returns : [Net]
",
    ),
    #(
      "ffi.gleam",
      "@external(erlang, \"ffi_module\", \"make_client\")
@external(javascript, \"ffi_module\", \"make_client\")
pub fn make_client() -> fn() -> Nil
",
    ),
    #(
      "app.gleam",
      "import ffi

pub fn caller() -> Nil {
  let send = ffi.make_client()
  send()
}
",
    ),
  ])
  let assert Ok(why) = graded.run_why(root, "app.caller")
  let assert Ok(line) = contributor_line(why, "returned")
  line
  |> string.contains(
    "calls a function returned by `ffi.make_client` with effects [Net]"
    <> " (from your spec's `assume` line)",
  )
  |> should.be_true()
  why
  |> string.contains("whose producer could not be resolved")
  |> should.be_false()
  support.cleanup(root)
}

pub fn the_fixture_declared_producer_resolves_from_its_line_test() {
  // The shared fixture set's own declared producer, whose caller sits in the
  // same module — the resolution path that consults no knowledge base for an
  // inferred summary. Its `check` line passing says the call resolved; this
  // says what it resolved to, and from where.
  let assert Ok(why) =
    graded.run_why("test/fixtures", "foreign_values.calls_declared_operator")
  why
  |> string.contains(
    "calls a function returned by `declared_returns_operator` with effects"
    <> " [Disk] (from your spec's `assume` line)",
  )
  |> should.be_true()
}

// The spec declaring the same-module producer's return, and the spec that
// leaves it to inference — which writes no summary for an `@external` at all.
const declared_same_module_spec = "check ffi.caller : [Net]
assume ffi.make_client : [Net]
assume ffi.make_client where returns : [Net]
"

const inferred_same_module_spec = "check ffi.caller : [Net]
assume ffi.make_client : [Net]
"

// The violations of a one-module project whose `@external` producer and its
// caller sit side by side, checked against `spec`.
fn same_module_violations(root: String, spec: String) -> List(types.Violation) {
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", spec),
    #(
      "ffi.gleam",
      "@external(erlang, \"ffi_module\", \"make_client\")
@external(javascript, \"ffi_module\", \"make_client\")
pub fn make_client() -> fn() -> Nil

pub fn caller() -> Nil {
  let send = make_client()
  send()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ffi.gleam" })
  support.cleanup(root)
  r.violations
}

pub fn a_governed_sibling_charges_its_module_what_it_charges_everyone_test() {
  // `assume m : [Disk]` answers for every caller of `m.logs`, and a
  // sibling is a caller. Walking the body for the sibling and reading the
  // declaration for everyone else charged one name two sets depending on where
  // it was called from — `m.wrapper` failed its `[Disk]` on the body's
  // `[Stdout]` while `app.xwrapper` passed the same budget.
  let root = "build/module_external_local_caller"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume m : [Disk]
assume loud.shout : [Stdout]
check m.wrapper : [Disk]
check app.xwrapper : [Disk]
check m.logs : [Disk]
",
    ),
    #(
      "m.gleam",
      "import loud

pub fn logs() -> Nil {
  loud.shout()
}

pub fn wrapper() -> Nil {
  logs()
}
",
    ),
    #(
      "app.gleam",
      "import m

pub fn xwrapper() -> Nil {
  m.logs()
}
",
    ),
    #(
      "loud.gleam",
      "@external(erlang, \"l\", \"s\")
@external(javascript, \"l\", \"s\")
pub fn shout() -> Nil
",
    ),
  ])

  let assert Ok(results) = graded.check_project(root)
  // Neither caller pays more than the declaration.
  let assert Ok(caller) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  caller.violations |> should.equal([])
  // The one line `m.logs`'s own budget fails on is its body, which no caller of
  // it is charged.
  let assert Ok(governed) =
    list.find(results, fn(r) { r.file == root <> "/m.gleam" })
  governed.violations
  |> list.map(fn(violation) {
    #(violation.function, violation.explanation.actual)
  })
  |> should.equal([#("logs", types.Specific(set.from_list(["Stdout"])))])

  // Word for word the same contributor line, whichever module the call sits in.
  let assert Ok(local) = graded.run_why(root, "m.wrapper")
  let assert Ok(cross) = graded.run_why(root, "app.xwrapper")
  contributor_line(local, "m.logs")
  |> should.equal(contributor_line(cross, "m.logs"))
  contributor_line(cross, "m.logs")
  |> should.equal(Ok(
    "  calls m.logs with effects [Disk] (from a module-level `assume` in your"
    <> " spec)",
  ))
  support.cleanup(root)
}

pub fn an_undeclared_unbuilt_external_names_one_cause_test() {
  // Both true of `nothing` at once: no `assume` line declares it, and
  // its `@external` names a target this build does not compile. Out of reach is
  // the cause every surface reports, because it is the one that decides the
  // charge — answering that nothing declares it named a cause `check` and `why`
  // do not, over a set all three agreed on.
  let root = "build/undeclared_unbuilt_provenance"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\ntarget = \"erlang\"\n"),
    #("proj.graded", "check app.wrapper : []\n"),
    #(
      "ffi.gleam",
      "@external(javascript, \"ffi_js\", \"nothing\")
pub fn nothing() -> Nil
",
    ),
    #(
      "app.gleam",
      "import ffi

pub fn wrapper() -> Nil {
  ffi.nothing()
}
",
    ),
  ])

  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  violation.explanation.reason |> should.equal(Some(types.UnbuiltExternal))

  let assert Ok(why) = graded.run_why(root, "app.wrapper")
  let assert Ok(answered) = graded.run_effect(root, "ffi.nothing")
  [why, answered]
  |> list.each(fn(output) {
    output
    |> string.contains("declared only for a target this build does not compile")
    |> should.be_true()
    output |> string.contains("with no declared effects") |> should.be_false()
  })
  support.cleanup(root)
}

// The agreement matrix
//
// Every name shape a foreign charge can take, under every shape a package's
// target configuration can take, read on all four surfaces at once: the charge
// a `check` line weighs, the total `why` states, the set `graded effect`
// answers, and what a caller — in another module, in the name's own, and
// through a record field — pays. Three rounds of fixes had this invariant come
// back on whichever channel the last round did not name; the rows below are
// what a fourth would have to get past.

// One name under one configuration: what every surface must charge for it, and
// the wording they must agree on where no declaration answered.
type MatrixRow {
  MatrixRow(
    // The name every surface is asked about.
    name: String,
    // Functions charged for `name` — in another module, in its own, and through
    // a field wired to it.
    callers: List(String),
    // What a caller pays, and what the query answers.
    charge: List(String),
    // What `name`'s own `check` line is weighed against: the charge, plus
    // whatever Gleam body of its own runs beside the declaration.
    own_total: List(String),
    // A phrase every surface naming the cause must print, where the charge came
    // from no declaration.
    cause: Option(String),
    // A phrase no surface describing the charge may print.
    absent: List(String),
  )
}

pub fn every_surface_charges_one_name_one_set_test() {
  // A package naming no target reads fallback bodies on the compiler's default
  // and declarations on every target, so a JavaScript declaration answers and
  // the Erlang body beside it runs too.
  let defaulted = [
    MatrixRow(
      name: "ffi.declared_bodyless",
      callers: ["call_declared_bodyless", "local_declared_bodyless", "tick"],
      charge: ["Time"],
      own_total: ["Time"],
      cause: None,
      absent: ["Unknown"],
    ),
    MatrixRow(
      name: "ffi.declared_fallback",
      callers: ["call_declared_fallback", "local_declared_fallback"],
      // The `assume` line suppresses the running body's half for callers; the
      // external's own line still weighs the walked body, as `gov.governed`'s
      // module-level form does below.
      charge: ["Time"],
      own_total: ["Disk", "Time"],
      cause: None,
      absent: ["Unknown"],
    ),
    MatrixRow(
      name: "ffi.undeclared_bodyless",
      callers: ["call_undeclared_bodyless", "local_undeclared_bodyless"],
      charge: ["Unknown"],
      own_total: ["Unknown"],
      cause: Some(undeclared_cause),
      absent: [unbuilt_cause],
    ),
    MatrixRow(
      name: "ffi.undeclared_fallback",
      callers: ["call_undeclared_fallback", "local_undeclared_fallback"],
      charge: ["Disk", "Unknown"],
      own_total: ["Disk", "Unknown"],
      cause: Some(undeclared_cause),
      absent: [unbuilt_cause],
    ),
    MatrixRow(
      name: "gov.governed",
      callers: ["call_governed", "local_governed"],
      charge: ["Net"],
      // The line answers for callers; the visible body is weighed beside it
      // against this function's own budget and nothing else.
      own_total: ["Disk", "Net"],
      cause: None,
      absent: ["Disk"],
    ),
  ]
  // One declared target: a JavaScript declaration describes an implementation
  // this build never compiles, so what runs is the Gleam body beside it — or
  // nothing at all.
  let single = [
    MatrixRow(
      name: "ffi.declared_bodyless",
      callers: ["call_declared_bodyless", "local_declared_bodyless", "tick"],
      charge: ["Unknown"],
      own_total: ["Unknown"],
      cause: Some(unbuilt_cause),
      absent: ["Time"],
    ),
    MatrixRow(
      name: "ffi.declared_fallback",
      callers: ["call_declared_fallback", "local_declared_fallback"],
      charge: ["Disk"],
      own_total: ["Disk"],
      cause: None,
      absent: ["Time", "Unknown"],
    ),
    MatrixRow(
      name: "ffi.undeclared_bodyless",
      callers: ["call_undeclared_bodyless", "local_undeclared_bodyless"],
      charge: ["Unknown"],
      own_total: ["Unknown"],
      // Undeclared and out of reach at once: out of reach is what decides the
      // charge, so it is the cause every surface names.
      cause: Some(unbuilt_cause),
      absent: [undeclared_cause],
    ),
    MatrixRow(
      name: "ffi.undeclared_fallback",
      callers: ["call_undeclared_fallback", "local_undeclared_fallback"],
      charge: ["Disk"],
      own_total: ["Disk"],
      cause: None,
      absent: ["Unknown"],
    ),
    MatrixRow(
      name: "gov.governed",
      callers: ["call_governed", "local_governed"],
      charge: ["Net"],
      own_total: ["Disk", "Net"],
      cause: None,
      absent: ["Disk"],
    ),
  ]
  // Both targets declared: each half is in reach on its own target, and a caller
  // is charged their union.
  let dual = [
    MatrixRow(
      name: "ffi.declared_bodyless",
      callers: ["call_declared_bodyless", "local_declared_bodyless", "tick"],
      charge: ["Time"],
      own_total: ["Time"],
      cause: None,
      absent: ["Unknown"],
    ),
    MatrixRow(
      name: "ffi.declared_fallback",
      callers: ["call_declared_fallback", "local_declared_fallback"],
      // Suppressed for callers, weighed on the external's own line — the same
      // split the defaulted matrix pins.
      charge: ["Time"],
      own_total: ["Disk", "Time"],
      cause: None,
      absent: ["Unknown"],
    ),
    MatrixRow(
      name: "ffi.undeclared_bodyless",
      callers: ["call_undeclared_bodyless", "local_undeclared_bodyless"],
      charge: ["Unknown"],
      own_total: ["Unknown"],
      cause: Some(undeclared_cause),
      absent: [unbuilt_cause],
    ),
    MatrixRow(
      name: "ffi.undeclared_fallback",
      callers: ["call_undeclared_fallback", "local_undeclared_fallback"],
      charge: ["Disk", "Unknown"],
      own_total: ["Disk", "Unknown"],
      cause: Some(undeclared_cause),
      absent: [unbuilt_cause],
    ),
    MatrixRow(
      name: "gov.governed",
      callers: ["call_governed", "local_governed"],
      charge: ["Net"],
      own_total: ["Disk", "Net"],
      cause: None,
      absent: ["Disk"],
    ),
  ]

  [
    #("build/agreement_matrix_defaulted", "name = \"proj\"\n", defaulted),
    #(
      "build/agreement_matrix_single",
      "name = \"proj\"\ntarget = \"erlang\"\n",
      single,
    ),
    #("build/agreement_matrix_dual", support.dual_target_toml("proj"), dual),
  ]
  |> list.each(fn(configuration) {
    let #(root, toml, rows) = configuration
    support.write_fixture(root, [#("gleam.toml", toml), ..matrix_sources()])
    let assert Ok(results) = graded.check_project(root)
    list.each(rows, check_matrix_row(root, results, _))
    support.cleanup(root)
  })
}

// The two causes a surface names where no declaration accounts for the charge.
// Read by both the direct-call wording and the wired-field wording, which
// continues the same phrase.
const undeclared_cause = "an external with no declared effects"

const unbuilt_cause = "an external declared only for a target this build does not compile"

// The package every configuration of the matrix is written over: one name of
// each shape a foreign charge takes, each with a caller in another module, a
// caller in its own, and — for the bodyless declared one — a record field wired
// to it. Every `check` line is `[]`, so each function's violations report the
// whole of what it is charged.
fn matrix_sources() -> List(#(String, String)) {
  [
    #(
      "proj.graded",
      "assume sink.disk : [Disk]
assume ffi.declared_bodyless : [Time]
assume ffi.declared_fallback : [Time]
assume gov : [Net]
check ffi.declared_bodyless : []
check ffi.declared_fallback : []
check ffi.undeclared_bodyless : []
check ffi.undeclared_fallback : []
check ffi.local_declared_bodyless : []
check ffi.local_declared_fallback : []
check ffi.local_undeclared_bodyless : []
check ffi.local_undeclared_fallback : []
check gov.governed : []
check gov.local_governed : []
check app.call_declared_bodyless : []
check app.call_declared_fallback : []
check app.call_undeclared_bodyless : []
check app.call_undeclared_fallback : []
check app.call_governed : []
check wired.tick : []
",
    ),
    #(
      "sink.gleam",
      "@external(erlang, \"s\", \"d\")
@external(javascript, \"s\", \"d\")
pub fn disk() -> Nil
",
    ),
    #(
      "ffi.gleam",
      "import sink

@external(javascript, \"f\", \"db\")
pub fn declared_bodyless() -> Nil

@external(javascript, \"f\", \"df\")
pub fn declared_fallback() -> Nil {
  sink.disk()
}

@external(javascript, \"f\", \"ub\")
pub fn undeclared_bodyless() -> Nil

@external(javascript, \"f\", \"uf\")
pub fn undeclared_fallback() -> Nil {
  sink.disk()
}

pub fn local_declared_bodyless() -> Nil {
  declared_bodyless()
}

pub fn local_declared_fallback() -> Nil {
  declared_fallback()
}

pub fn local_undeclared_bodyless() -> Nil {
  undeclared_bodyless()
}

pub fn local_undeclared_fallback() -> Nil {
  undeclared_fallback()
}
",
    ),
    #(
      "gov.gleam",
      "import sink

pub fn governed() -> Nil {
  sink.disk()
}

pub fn local_governed() -> Nil {
  governed()
}
",
    ),
    #(
      "wired.gleam",
      "import ffi

pub type Clock {
  Clock(read: fn() -> Nil)
}

pub fn build() -> Clock {
  Clock(read: ffi.declared_bodyless)
}

pub fn tick() -> Nil {
  let c = build()
  c.read()
}
",
    ),
    #(
      "app.gleam",
      "import ffi
import gov

pub fn call_declared_bodyless() -> Nil {
  ffi.declared_bodyless()
}

pub fn call_declared_fallback() -> Nil {
  ffi.declared_fallback()
}

pub fn call_undeclared_bodyless() -> Nil {
  ffi.undeclared_bodyless()
}

pub fn call_undeclared_fallback() -> Nil {
  ffi.undeclared_fallback()
}

pub fn call_governed() -> Nil {
  gov.governed()
}
",
    ),
  ]
}

// One row of the matrix, on all four surfaces.
fn check_matrix_row(
  root: String,
  results: List(types.CheckResult),
  row: MatrixRow,
) -> Nil {
  let charge = types.Specific(set.from_list(row.charge))
  let label = root <> " " <> row.name
  // `check`, for the name itself and for every caller of it.
  #(label, checked_set(results, function_of(row.name)))
  |> should.equal(#(label, types.Specific(set.from_list(row.own_total))))
  list.each(row.callers, fn(caller) {
    #(label <> " <- " <> caller, checked_set(results, caller))
    |> should.equal(#(label <> " <- " <> caller, charge))
  })
  // `why`, for the name's own total and for every caller's telling of it.
  let rendered = rendered_set(row.charge)
  let assert Ok(own_why) = graded.run_why(root, row.name)
  #(label, string.contains(own_why, rendered_set(row.own_total)))
  |> should.equal(#(label, True))
  // `graded effect`, in the one wording the fast path answers in too.
  let assert Ok(query) = graded.run_effect(root, row.name)
  #(label, string.contains(query, "effects " <> row.name <> " : " <> rendered))
  |> should.equal(#(label, True))
  #(label, graded.run_effect_from_project(root, row.name))
  |> should.equal(#(label, Ok(query)))
  // And the cause, wherever two surfaces describe the same one.
  let callers_why =
    list.map(row.callers, fn(caller) {
      let assert Ok(output) = graded.run_why(root, caller_name(caller))
      output
    })
  list.each([query, ..callers_why], fn(output) {
    case row.cause {
      Some(cause) ->
        #(label, cause, string.contains(output, cause))
        |> should.equal(#(label, cause, True))
      None -> Nil
    }
    list.each(row.absent, fn(absent) {
      #(label, absent, string.contains(output, absent))
      |> should.equal(#(label, absent, False))
    })
  })
}

// The effect set a function's `check` line was weighed against: every
// contributor it reported, unioned — which under a `[]` budget is the whole of
// what the function is charged.
fn checked_set(
  results: List(types.CheckResult),
  function: String,
) -> types.EffectSet {
  results
  |> list.flat_map(fn(result) { result.violations })
  |> list.filter(fn(violation) { violation.function == function })
  |> list.fold(types.Specific(set.new()), fn(total, violation) {
    types.union(total, violation.explanation.actual)
  })
}

// An effect set as every surface prints it, so an expectation is compared
// against the printed form rather than a guess at its ordering.
fn rendered_set(labels: List(String)) -> String {
  annotation.format_effect_term(
    effect_term.from_effect_set(types.Specific(set.from_list(labels))),
  )
}

// The bare function name a `check` line's violations are keyed by.
fn function_of(name: String) -> String {
  let assert Ok(#(_module, function)) = annotation.split_function_name(name)
  function
}

// The module each matrix caller lives in, which its bare name does not carry.
fn caller_name(caller: String) -> String {
  case caller {
    "tick" -> "wired.tick"
    "local_governed" -> "gov.local_governed"
    "call_" <> _ -> "app." <> caller
    _ -> "ffi." <> caller
  }
}

pub fn two_target_restricted_checks_do_not_share_a_helper_test() {
  // One helper, two callers, opposite targets. The analysis of that helper is
  // memoised by callee and ancestors and by nothing else, so the table carried
  // across annotations handed whichever ran first its answer to the other --
  // and the two answers differ, since the external the helper calls is foreign
  // code on JavaScript and a pure Gleam fallback on Erlang. Each check alone
  // was right; together the Erlang one failed on the JavaScript one's `[Disk]`.
  let root = "build/target_restricted_memo"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.b : [Disk]\ncheck ext.e : []\ncheck ext.j : []\n",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"b\")
pub fn b() -> Nil {
  Nil
}

fn h() -> Nil {
  b()
}

@target(erlang)
pub fn e() -> Nil {
  h()
}

@target(javascript)
pub fn j() -> Nil {
  h()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  // The JavaScript caller reaches the foreign implementation and fails; the
  // Erlang one reaches the fallback and passes. One violation, and it is that
  // one -- neither answer stands in for the other.
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("j")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_returns_line_is_computed_on_the_producer_targets_test() {
  // The operator a producer hands back is what its own body builds, so a
  // `@target(erlang)` producer's closure over a JavaScript-only external
  // returns what that external's Erlang fallback does. Computed package-wide,
  // the `returns` line published the unreachable declaration's effect -- and
  // disagreed with the `effects` line beside it, which was narrowed.
  let root = "build/returns_target_restricted"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #("proj.graded", "assume ext.b : [Disk]\n"),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"b\")
pub fn b() -> Nil {
  Nil
}

@target(erlang)
pub fn make() -> fn() -> Nil {
  fn() { b() }
}
",
    ),
  ])
  let assert Ok(_) = graded.run_infer(root)
  let assert Ok(written) = simplifile.read(root <> "/proj.graded")
  string.contains(written, "effects ext.make : [] where returns : []")
  |> should.be_true()
  string.contains(written, "where returns : [Disk]") |> should.be_false()
  support.cleanup(root)
}

pub fn an_ordinary_target_restricted_body_narrows_too_test() {
  // `@target` restricts an ordinary function exactly as it restricts an
  // `@external`: this body is built for Erlang and nowhere else, so the
  // JavaScript-only external it calls answers with the Gleam fallback that runs
  // there rather than with what its declaration says the foreign implementation
  // does. Only fallback bodies were narrowed, so a plain function under a
  // `@target` was charged an effect no build of it can perform.
  let root = "build/ordinary_target_restricted_body"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #("proj.graded", "assume ext.b : [Disk]\ncheck ext.w : []\n"),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"b\")
pub fn b() -> Nil {
  Nil
}

@target(erlang)
pub fn w() -> Nil {
  b()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])
  // And what `infer` publishes for it says the same.
  let assert Ok(answered) = graded.run_effect(root, "ext.w")
  answered |> string.contains("effects ext.w : []") |> should.be_true()
  support.cleanup(root)
}

pub fn a_dependency_declaration_the_build_excludes_is_not_charged_test() {
  // The consumer builds for Erlang alone, and the dependency hands only
  // JavaScript to foreign code -- so what runs here is the dependency's Gleam
  // body, and its `[Disk]` declaration describes an implementation this build
  // never compiles. That declaration was trusted in full: the scan classified it
  // excluded and dropped it, leaving the shipped `assume` line keyed by nothing
  // that knew it answers for a target this build never compiles. `check app.w :
  // []` is the assertion — the body does nothing, and charging the declaration
  // beside it would fail the line.
  let root = "build/dep_declaration_build_excludes"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\ntarget = \"erlang\"\n"),
    #("proj.graded", "check app.w : []\n"),
    #("build/packages/dep/dep.graded", "assume dep/ffi.run : [Disk]\n"),
    #(
      "build/packages/dep/src/dep/ffi.gleam",
      "@external(javascript, \"dep_ffi\", \"run\")
pub fn run() -> Nil {
  Nil
}
",
    ),
    #(
      "app.gleam",
      "import dep/ffi

pub fn w() -> Nil {
  ffi.run()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])
  let assert Ok(answered) = graded.run_effect(root, "dep/ffi.run")
  answered |> string.contains("Disk") |> should.be_false()
  support.cleanup(root)
}

pub fn a_dependency_declaration_the_build_compiles_still_answers_test() {
  // The control: the same shape with the dependency declaring the target this
  // build compiles. Its foreign implementation is what runs, so the declaration
  // answers in full and no `[Unknown]` joins it.
  let root = "build/dep_declaration_build_compiles"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\ntarget = \"erlang\"\n"),
    #("proj.graded", "check app.w : [Disk]\n"),
    #("build/packages/dep/dep.graded", "assume dep/ffi.run : [Disk]\n"),
    #(
      "build/packages/dep/src/dep/ffi.gleam",
      "@external(erlang, \"dep_ffi\", \"run\")
@external(javascript, \"dep_ffi\", \"run\")
pub fn run() -> Nil
",
    ),
    #(
      "app.gleam",
      "import dep/ffi

pub fn w() -> Nil {
  ffi.run()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])
  support.cleanup(root)
}

pub fn a_dependency_fallback_out_of_reach_does_not_widen_test() {
  // The widening stands in for a body that runs where the *calling* code does.
  // Here the caller is itself a fallback running on Erlang alone, and the
  // dependency's declaration covers Erlang — so the dependency's own fallback
  // runs on JavaScript, which this body never reaches, and there is no unwalked
  // body to stand `[Unknown]` in for. The union was applied before anything
  // asked which targets were in reach, and it travels under the declaration's
  // source, so nothing downstream could subtract it: a `[Disk]` budget over a
  // call resolving to exactly `[Disk]` failed on a `[Disk, Unknown]`.
  let root = "build/dep_fallback_out_of_reach"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume app.a : []
check app.a : [Disk]
check app.wrapper : [Disk]
",
    ),
    #("build/packages/dep/dep.graded", "assume dep/ffi.run : [Disk]\n"),
    #(
      "build/packages/dep/src/dep/ffi.gleam",
      "@external(erlang, \"dep_ffi\", \"run\")
pub fn run() -> Nil {
  Nil
}
",
    ),
    #(
      "app.gleam",
      "import dep/ffi

@external(javascript, \"app_ffi\", \"a\")
pub fn a() -> Nil {
  ffi.run()
}

pub fn wrapper() -> Nil {
  a()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])
  support.cleanup(root)
}

pub fn a_dependency_declaration_out_of_reach_answers_its_body_test() {
  // The other direction, where the fallback is *all* there is to say: the
  // dependency's declaration covers JavaScript, this body runs on Erlang, and
  // what runs there is the dependency's Gleam fallback, which reaches the net.
  // The declaration's `[Disk]` describes foreign code this call never reaches,
  // so keeping it beside the body's own effects charged the caller an effect of
  // the wrong implementation, under a message already naming the body as the
  // source.
  let root = "build/dep_declaration_out_of_reach"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #("proj.graded", "assume app.a : []\ncheck app.a : [Disk]\n"),
    #(
      "build/packages/dep/dep.graded",
      "assume dep/ffi.run : [Disk]\nassume dep/ffi.reach : [Net]\n",
    ),
    #(
      "build/packages/dep/src/dep/ffi.gleam",
      "@external(javascript, \"dep_ffi\", \"run\")
pub fn run() -> Nil {
  reach()
}

@external(erlang, \"dep_ffi\", \"reach\")
pub fn reach() -> Nil
",
    ),
    #(
      "app.gleam",
      "import dep/ffi

@external(javascript, \"app_ffi\", \"a\")
pub fn a() -> Nil {
  ffi.run()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Net"])))
  support.cleanup(root)
}

pub fn the_effect_fast_path_defers_a_dependency_fallback_test() {
  // The spec declares the dependency function, so the fast path could answer
  // from the spec alone — but the dependency's own source says the name is
  // `@external` with a running fallback, which only a walk the fast path
  // performs no part of can weigh. The consumer's `assume` suppresses that
  // body's half, so callers pay `[Time]` alone — and the query still defers
  // to the full context, whose answer quotes the suppressed `[Net]` share the
  // fast path could never have seen.
  let root = "build/effect_fast_path_dep_fallback"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume dep/ffi.run : [Time]\nassume dep/ffi.reach : [Net]\n"
        <> "check app.wrapper : [Time]\n",
    ),
    #(
      "build/packages/dep/src/dep/ffi.gleam",
      "@external(javascript, \"dep_ffi\", \"run\")
pub fn run() -> Nil {
  reach()
}

@external(erlang, \"dep_ffi\", \"reach\")
pub fn reach() -> Nil
",
    ),
    #(
      "app.gleam",
      "import dep/ffi

pub fn wrapper() -> Nil {
  ffi.run()
}
",
    ),
  ])
  // What the caller is charged: the declared term alone, so the `[Time]`
  // budget holds.
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  r.violations |> should.equal([])
  // And what the query answers for the same name: the declaration the spec
  // states, with the walked body's share quoted as suppressed.
  let assert Ok(answered) = graded.run_effect(root, "dep/ffi.run")
  answered
  |> string.contains("effects dep/ffi.run : [Time]")
  |> should.be_true()
  answered
  |> string.contains("suppressed by the `assume` line: [Net]")
  |> should.be_true()
  answered
  |> should.equal(
    graded.run_effect_from_project(root, "dep/ffi.run") |> should.be_ok(),
  )
  support.cleanup(root)
}

pub fn an_undeclared_dependency_external_reports_as_an_external_test() {
  // The dependency's own source says `run` is foreign, so nothing graded holds
  // describes what it does. That is an external with no declared effects, not a
  // name that merely went unkeyed — the knowledge base already recorded which
  // of the dependency's functions are foreign.
  let root = "build/foreign_values_dep_undeclared"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "check app.wrapper : []\n"),
    #(
      "build/packages/dep/src/dep/ffi.gleam",
      "@external(erlang, \"dep_ffi\", \"run\")
pub fn run() -> Nil
",
    ),
    #(
      "app.gleam",
      "import dep/ffi

pub fn wrapper() -> Nil {
  ffi.run()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  violation.explanation.reason
  |> should.equal(Some(types.UndeclaredExternal))
  checker.format_violation(r.file, violation)
  |> string.contains("an external with no declared effects")
  |> should.be_true()
  support.cleanup(root)
}

pub fn a_path_dependency_spec_is_sanitized_against_its_source_test() {
  // A committed path dependency, whose spec is loaded through a different fold
  // than an installed package's. Its source sits at the declared `path`, so the
  // same evidence is in hand and the same lines are refused.
  let root = "build/foreign_values_path_dep"
  support.write_fixture(root, [
    #(
      "proj/gleam.toml",
      "name = \"proj\"\n\n[dependencies]\npdep = { path = \"../pdep\" }\n",
    ),
    #("proj/proj.graded", "check app.wrapper : []\n"),
    #(
      "proj/src/app.gleam",
      "import pdep/ffi

pub fn wrapper() -> Nil {
  let handle = ffi.make()
  handle()
}
",
    ),
    #("pdep/gleam.toml", "name = \"pdep\"\n"),
    #("pdep/pdep.graded", "effects pdep/ffi.make : [] where returns : []\n"),
    #(
      "pdep/src/pdep/ffi.gleam",
      "@target(erlang)
@external(erlang, \"pdep_ffi\", \"make\")
pub fn make() -> fn() -> Nil {
  fn() { Nil }
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root <> "/proj")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/proj/src/app.gleam" })
  { r.violations != [] } |> should.be_true()
  list.each(r.violations, fn(v) {
    v.explanation.actual
    |> should.equal(types.Specific(set.from_list(["Unknown"])))
  })
  support.cleanup(root)
}

pub fn a_spec_less_path_dependency_cannot_inherit_a_stale_operator_test() {
  // Why the dependency half of the rule is attached before path-dependency
  // inference rather than after: a spec-less path dep is inferred against the
  // knowledge base, so a wrapper of an installed dependency's stale returned
  // operator would otherwise be inferred pure and folded in at that strength,
  // where no later gate can reach it.
  let root = "build/foreign_values_path_dep_order"
  support.write_fixture(root, [
    #(
      "proj/gleam.toml",
      "name = \"proj\"\n\n[dependencies]\npdep = { path = \"../pdep\" }\n",
    ),
    #("proj/proj.graded", "check app.wrapper : []\n"),
    #(
      "proj/build/packages/dep/dep.graded",
      "assume dep/ffi.make : []\neffects dep/ffi.make : [] where returns : []\n",
    ),
    #(
      "proj/build/packages/dep/src/dep/ffi.gleam",
      "@target(erlang)
@external(erlang, \"dep_ffi\", \"make\")
pub fn make() -> fn() -> Nil {
  fn() { Nil }
}
",
    ),
    #(
      "proj/src/app.gleam",
      "import pdep/wrap

pub fn wrapper() -> Nil {
  wrap.run()
}
",
    ),
    #("pdep/gleam.toml", "name = \"pdep\"\n"),
    #(
      "pdep/src/pdep/wrap.gleam",
      "import dep/ffi

pub fn run() -> Nil {
  let handle = ffi.make()
  handle()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root <> "/proj")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/proj/src/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  support.cleanup(root)
}

pub fn one_helper_called_twice_is_reported_once_test() {
  // Two calls into one helper collect that helper's single site twice, and both
  // copies say the same thing. `why` prints one line for it, so `check` reports
  // one violation for it.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/why_target.gleam" })
  r.violations
  |> list.filter(fn(v) { v.function == "checked_calls_helper_twice" })
  |> list.map(fn(v) { checker.format_violation(r.file, v) })
  |> list.length
  |> should.equal(1)
}

// Opaque receivers and field bounds
//
// Field calls whose receiver has no visible construction site: field `assume` lines
// and hand-written field bounds discharge them, unbound calls stay [Unknown],
// and inference surfaces the polymorphic field bound.

pub fn opaque_receiver_violation_detected_test() {
  // opaque_receiver.run binds its Validator from make() — a *cross-function*
  // construction the syntax-level path can't see. girard types the receiver,
  // and the `assume opaque_receiver.Validator.to_error : [Stdout]` annotation
  // resolves the field call, so the [] check budget must fail. This is the
  // milestone-3b case that 0.6.0's same-function value flow could not handle.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let opaque_result =
    list.find(results, fn(r) { r.file == "test/fixtures/opaque_receiver.gleam" })
  let assert Ok(r) = opaque_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  // Crucially the effect is the precise [Stdout] (resolved via the type
  // annotation), not the [Unknown] graded would fall back to without girard.
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn field_bound_resolves_untraceable_receiver_test() {
  // field_bound.caller calls `v.to_error` where `v` arrives as a parameter —
  // no construction site, no field `assume` line. The hand-written field bound on the
  // `check field_bound.caller(v.to_error: [Stdout]) : []` line resolves the
  // field call to [Stdout], so the [] budget must fail with that precise
  // effect (not the [Unknown] graded would otherwise fall back to).
  let assert Ok(results) = graded.check_project("test/fixtures")
  let field_bound_result =
    list.find(results, fn(r) { r.file == "test/fixtures/field_bound.gleam" })
  let assert Ok(r) = field_bound_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("caller")
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn opaque_fn_typed_field_discharges_via_bound_test() {
  // opaque_field.exec calls `r.run` where `r` is an opaque parameter — no
  // construction site, no field `assume` line. `run` is a `fn`-typed field, so the call
  // becomes a synthetic field-effect variable rather than [Unknown]. The
  // `check opaque_field.exec(r.run: [Stdout]) : []` field bound discharges that
  // variable to [Stdout], so the [] budget must fail with the precise [Stdout].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/opaque_field.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "exec" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn opaque_fn_typed_field_unbound_is_unknown_test() {
  // opaque_field.exec_unbound makes the same opaque `fn`-typed field call with
  // NO field bound. The synthetic `r.run` variable can't be discharged, so it
  // concretizes to [Unknown] — the soundness floor — and the [] budget fails
  // with [Unknown], never silently []. This is the invariant the polymorphic
  // field-bound feature must never violate.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/opaque_field.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "exec_unbound" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
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

pub fn field_call_param_receiver_not_specialized_by_type_test() {
  // Soundness invariant, full pipeline: `default_options` wires
  // `Options.resolver` to a [Stdout] value, but `annotate`'s receiver is a
  // *parameter* — a caller can build the record differently — so the field call
  // must NOT be specialized to [Stdout]. It stays polymorphic and, against the
  // [] budget with no field bound, surfaces as [Unknown], never [Stdout]. This is
  // the girard options-builder understatement the precedence fix closes.
  let root = "build/field_poly_soundness_proj"
  let results =
    run_project_with_spec(
      root,
      "import gleam/io

pub type Options {
  Options(resolver: fn() -> Nil)
}

fn disk() -> Nil {
  io.println(\"x\")
}

pub fn default_options() -> Options {
  Options(resolver: disk)
}

pub fn annotate(options: Options) -> Nil {
  options.resolver()
}
",
      "check proj.annotate : []\n",
    )
  let assert Ok(r) =
    list.find(results, fn(r) { string.ends_with(r.file, "proj.gleam") })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "annotate" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn field_call_record_update_inherited_field_is_unknown_test() {
  // Tier 1 leaves a record update untraceable: `with_resolver` rebuilds via
  // `Options(..base, ..)`, and `use_it` binds that call result before the field
  // call. The inherited `resolver` field is not proven for this receiver, so the
  // call resolves to [Unknown] rather than borrowing the package default. (Tier 2's
  // field-selective overlay is what promotes an *updated* field to proven.)
  let root = "build/field_poly_record_update_proj"
  let results =
    run_project_with_spec(
      root,
      "import gleam/io

pub type Options {
  Options(resolver: fn() -> Nil, label: String)
}

fn disk() -> Nil {
  io.println(\"x\")
}

pub fn default_options() -> Options {
  Options(resolver: disk, label: \"\")
}

pub fn with_label(base: Options, label: String) -> Options {
  Options(..base, label: label)
}

pub fn use_it() -> Nil {
  let o = with_label(default_options(), \"x\")
  o.resolver()
}
",
      "check proj.use_it : []\n",
    )
  let assert Ok(r) =
    list.find(results, fn(r) { string.ends_with(r.file, "proj.gleam") })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "use_it" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
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
    effects.empty_knowledge_base("."),
    [],
    signatures.empty(),
    dict.new(),
    dict.new(),
    types.all_targets(),
  ))
}

// Factory forwarding
//
// Field wirings that route a factory or constructor argument onto the
// caller's own parameter, so a caller-side bound can discharge the forwarded
// effect; untraceable and shadowed receivers stay [Unknown].

pub fn factory_forward_resolves_through_factory_test() {
  // factory_forward.caller calls `inner(make_options(resolver))`: the factory
  // result is built inline, so its `resolver` field wiring forwards inner's
  // `options.resolver` field-effect variable onto the caller's own `resolver`
  // parameter. The `check ...caller(resolver: [Stdout]) : []` bound discharges
  // it to [Stdout], so the [] budget fails with the precise effect — not the
  // [Unknown] an untraced factory return would collapse to.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn factory_forward_resolves_through_inline_constructor_test() {
  // Same forwarding for an inline *constructor* argument
  // (`inner(Options(resolver: resolver))`).
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_ctor" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn factory_forward_resolves_through_labeled_factory_test() {
  // Labeled factory wiring (`inner(make_options(resolver: resolver))`) routes
  // through the factory's parameter label to the same field, so it forwards too.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_labeled" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn factory_forward_resolves_through_shorthand_factory_test() {
  // Shorthand labeled wiring (`make_options(resolver:)`) is sugar for
  // `make_options(resolver: resolver)`, so its value is the `resolver` variable
  // and it forwards the same way — not the [Unknown] an opaque shorthand gives.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_shorthand" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn factory_forward_marker_survives_sibling_source_test() {
  // factory_forward.mixed_caller forwards through `make_runner(run)` while the
  // same `Runner.run` field also has a polymorphic source from `relay_runner`
  // (`Runner(run: relay)`). `run_inner`'s receiver is a parameter, so the field
  // call stays polymorphic — a receiver-keyed field variable that forwards onto
  // the caller's own `run` parameter, where the `run: [Stdout]` bound discharges
  // it to [Stdout]. The sibling `relay` source belongs to a *different*
  // construction site and no longer pollutes this receiver: the nominal index is
  // never consulted for a parameter receiver, so [Unknown] is gone.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "mixed_caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn factory_forward_resolves_through_factory_alias_test() {
  // factory_forward.caller_alias binds the factory result to a `let` before
  // passing it (`let o = make_options(resolver); inner(o)`). The alias preserves
  // the constructed field wiring, so `o.resolver` re-keys onto the caller's
  // `resolver` parameter and the `resolver: [Stdout]` bound discharges it — the
  // [] budget fails with [Stdout], not the [Unknown] an opaque alias gave before.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_alias" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn factory_forward_resolves_through_constructor_alias_test() {
  // factory_forward.caller_ctor_alias binds an inline constructor before passing
  // it (`let o = Options(resolver: resolver); inner(o)`). The constructor wiring
  // forwards the same way, so the bound discharges to [Stdout].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_ctor_alias" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn factory_forward_resolves_through_nested_construction_test() {
  // factory_forward.caller_nested wires `resolver` two construction levels deep
  // (`inner_holder(make_holder(make_options(resolver)))`). Each hop's field
  // wiring is traced in turn, so `holder.options.resolver` re-keys onto the
  // caller's `resolver` and the bound discharges to [Stdout].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_nested" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn factory_forward_computed_alias_stays_unknown_test() {
  // factory_forward.caller_computed_alias binds a computed receiver
  // (`let o = get_options(make_options(resolver)); inner(o)`). The binding is an
  // opaque call result, not a traceable construction, so forwarding doesn't
  // apply and the field call concretizes to [Unknown].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_computed_alias" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn factory_forward_shadowed_alias_stays_unknown_test() {
  // factory_forward.caller_shadow rebinds a traceable factory alias to a computed
  // value before forwarding (`let o = make_options(resolver); let o =
  // get_options(o); inner(o)`). The shadowing binding clears the stale factory
  // provenance, so the field call concretizes to [Unknown] — proving a
  // reassignment can never leave a forwarded effect understated.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_shadow" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn factory_forward_computed_receiver_resolves_test() {
  // factory_forward.caller_computed threads the factory result through a
  // passthrough helper (`inner(get_options(make_options(resolver)))`).
  // `get_options` returns its parameter, so return-value provenance forwards the
  // factory-wired `resolver` onto the caller's `resolver` and the bound
  // discharges it to [Stdout] — where before Phase 1 it collapsed to [Unknown].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/factory_forward.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_computed" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
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
    effects.empty_knowledge_base("."),
    [],
    signatures.from_glance_module("factory_forward", module),
    dict.new(),
    dict.new(),
    types.all_targets(),
  ))
}

// Nested field calls
//
// Field calls whose receiver is itself a field access (`o.inner.run()`),
// resolved via field `assume` lines or dotted field bounds, falling back to
// [Unknown] when neither applies.

pub fn nested_field_resolves_via_type_line_test() {
  // nested_field.via_type calls `o.inner.run()` — a NESTED field call whose
  // receiver `o.inner` is itself a field access, not a bare variable. girard
  // types the `o.inner` span as `Inner`, so the `type nested_field.Inner.run :
  // [Disk]` line resolves it, and the [] budget fails with the precise [Disk].
  // Before nested extraction this collapsed to a computed application
  // ([Unknown]).
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/nested_field.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "via_type" })
  v.explanation.actual |> should.equal(types.Specific(set.from_list(["Disk"])))
}

pub fn nested_field_discharges_via_dotted_bound_test() {
  // nested_field.via_bound has a dotted field bound on its `check` line
  // (`check nested_field.via_bound(o.inner.run: [Stdout]) : []`). The nested
  // `o.inner.run` field call carries the dotted path `o.inner` as its object, so
  // the bound matches and discharges to [Stdout], winning over the field `assume` line.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/nested_field.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "via_bound" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn nested_field_unbound_is_unknown_test() {
  // nested_field.unbound calls `h.loose.act()` — a nested fn-typed field with no
  // field `assume` line and no field bound. The synthetic field-effect variable can't be
  // discharged, so it concretizes to [Unknown] — the soundness floor — and the
  // [] budget fails with [Unknown], never silently [].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/nested_field.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "unbound" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

// Synthesized-project helpers
//
// Scaffolding shared by the sections below: materialise a throwaway project
// under the gitignored `build/`, run infer or check on it, and assert on the
// surfaced annotations.

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

// Receivers that shadow an import alias
//
// The effect sets the resolution rule produces, end to end: a wired field's own
// effects where the receiver has that field, the module's where a complete
// construction proves it does not, and `[Unknown]` — never the shadowed
// module's — wherever extraction could not tell. `loud.emit` and `loud.holler`
// are impure and `loud.quiet` is pure, so every case below reads differently
// under the two branches.

fn shadow_effects(name: String) -> types.EffectTerm {
  let root = "build/shadowed_receiver"
  write_project(
    root,
    [
      #(
        "loud.gleam",
        "@external(erlang, \"loud_ffi\", \"emit\")
pub fn emit(s: String) -> Nil

pub fn holler(s: String) -> Nil {
  emit(s)
}

pub fn quiet(s: String) -> Nil {
  Nil
}
",
      ),
      #(
        "dep_mod.gleam",
        "import loud

pub type Boxed {
  Boxed(emit: fn(String) -> Nil)
}

pub const default_boxed = Boxed(emit: loud.emit)
",
      ),
      #(
        "proj.gleam",
        "import dep_mod
import loud

pub type Fmt {
  Fmt(
    quiet: fn(String) -> Nil,
    other: fn(String) -> Nil,
    emit: fn(String) -> Nil,
  )
}

fn shout(s: String) -> Nil {
  loud.emit(s)
}

pub fn make_fmt(o: fn(String) -> Nil) -> Fmt {
  Fmt(quiet: shout, other: o, emit: shout)
}

pub fn wired_field_wins() -> Nil {
  let loud = Fmt(quiet: shout, other: shout, emit: shout)
  loud.quiet(\"hi\")
}

pub fn absent_field_takes_the_module() -> Nil {
  let loud = Fmt(quiet: shout, other: shout, emit: shout)
  loud.holler(\"hi\")
}

pub fn closure_takes_the_module() -> Nil {
  let loud = fn(_s: String) { Nil }
  loud.emit(\"hi\")
}

pub fn factory_routed_field() -> Nil {
  let loud = make_fmt(shout)
  loud.other(\"hi\")
}

pub fn factory_untraced_field() -> Nil {
  let loud = make_fmt(shout)
  loud.emit(\"hi\")
}

pub fn imported_constant_field() -> Nil {
  let loud = dep_mod.default_boxed
  loud.emit(\"hi\")
}
",
      ),
    ],
    "assume loud.emit : [Stdout]\n",
  )
  let assert Ok(Nil) = graded.run_infer(root)
  let assert Ok(content) = simplifile.read(root <> "/proj.graded")
  let assert Ok(file) = annotation.parse_file(content)
  let assert Ok(annotation) =
    list.find(annotation.extract_annotations(file), fn(a) {
      a.function == "proj." <> name
    })
  annotation.effects
}

pub fn a_shadowed_receivers_wired_field_is_charged_test() {
  // The undercharge: `loud` shadows the module `loud`, whose `quiet` is pure,
  // and the record's own `quiet` field is wired to a function that is not.
  shadow_effects("wired_field_wins")
  |> should.equal(types.TLabels(set.from_list(["Stdout"])))
}

pub fn a_complete_constructions_absent_field_reads_the_module_test() {
  // The overcharge, the other way: this construction wired every field the
  // type declares, and `holler` is none of them — so the call is the module's,
  // which is what compiles.
  shadow_effects("absent_field_takes_the_module")
  |> should.equal(types.TLabels(set.from_list(["Stdout"])))
}

pub fn a_shadowing_closure_reads_the_module_test() {
  // A function value has no fields, so `loud.emit` is the module's.
  shadow_effects("closure_takes_the_module")
  |> should.equal(types.TLabels(set.from_list(["Stdout"])))
}

pub fn a_factory_routed_field_keeps_its_effects_test() {
  // A partial binding is not an unknown one: the field the factory did route
  // resolves through the machinery it always did.
  shadow_effects("factory_routed_field")
  |> should.equal(types.TLabels(set.from_list(["Stdout"])))
}

pub fn a_factory_unrouted_field_is_unknown_test() {
  // The factory fills `emit` internally, so this binding never traced it.
  // Absent means untraced here, and answering `loud.emit` would credit the
  // call with a declaration that describes another function.
  shadow_effects("factory_untraced_field")
  |> should.equal(types.TLabels(set.from_list(["Unknown"])))
}

pub fn a_shadowing_imported_constant_is_unknown_test() {
  // A lowercase imported name can be a record constant with a callable field —
  // which is what this is — so it proves nothing about the value's type.
  shadow_effects("imported_constant_field")
  |> should.equal(types.TLabels(set.from_list(["Unknown"])))
}

fn run_project_with_spec(
  root: String,
  source: String,
  spec: String,
) -> List(types.CheckResult) {
  write_project(root, [#("proj.gleam", source)], spec)
  let assert Ok(results) = graded.check_project(root)
  results
}

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

// Unreadable spec files
//
// A spec file that is there but cannot be read is not the same as a package
// with no spec file: checking against no annotations at all would pass every
// module by skipping it.

pub fn check_over_an_unreadable_spec_errors_test() {
  let root = "build/check_unreadable_spec"
  write_project(
    root,
    [#("proj.gleam", "pub fn main() -> Nil {\n  Nil\n}\n")],
    "",
  )
  let assert Ok(Nil) = simplifile.delete(root <> "/proj.graded")
  let assert Ok(Nil) = simplifile.create_directory(root <> "/proj.graded")

  graded.check_project(root)
  |> should.equal(
    Error(graded.FileReadError(root <> "/proj.graded", simplifile.Eisdir)),
  )
  let _ = simplifile.delete(root)
  Nil
}

// Unreadable manifests
//
// A `gleam.toml` that is there but cannot be read is not the same as a package
// with no `gleam.toml`: defaulting the package name to the directory's would
// read and write a spec file the manifest never named.

pub fn check_over_an_unreadable_manifest_errors_test() {
  // Rooted outside the repository so the walk-up stops at this directory
  // rather than adopting graded's own manifest.
  let root = "/tmp/graded_unreadable_manifest"
  write_project(
    root,
    [#("proj.gleam", "pub fn main() -> Nil {\n  Nil\n}\n")],
    "",
  )
  let assert Ok(Nil) = simplifile.delete(root <> "/gleam.toml")
  let assert Ok(Nil) = simplifile.create_directory(root <> "/gleam.toml")

  let toml = root <> "/gleam.toml"
  graded.check_project(root)
  |> should.equal(
    Error(graded.InvalidConfig(
      path: toml,
      message: config.describe_error(config.TomlReadError(
        toml,
        simplifile.Eisdir,
      )),
    )),
  )
  let _ = simplifile.delete(root)
  Nil
}

// Field-effect forwarding through call hops
//
// A callee's field-effect variable re-keys onto the caller's receiver across
// one or more call hops, surfacing as an inferred field bound the caller's
// `check` line can discharge.

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
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
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
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

// Cross-module provenance
//
// Return provenance (getters, rebuilds, labeled passthroughs) threads through
// the knowledge base in topological order, so computed receivers forward
// across module boundaries.

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
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
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
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
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
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
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
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

// Receiver-path forwarding
//
// Receivers passed as parameter-rooted paths (`config.options`), aliases, or
// passthrough call results re-key the callee's field variable onto the full
// path; computed aliases stay conservative.

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
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
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
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
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
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
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
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

// Field-call shape variants
//
// Remaining field-call shapes: dotted round trips, pipe targets, alias-typed
// fields, same-named imported types, and cross-module field `assume` lines on nested
// receivers.

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
  // captured (resolved by `assume pipe_field.Inner.run : [Disk]`) and the []
  // budget fails with [Disk]. Before the fix the pipe target fell through to the
  // generic walker, dropped the effect, and the budget passed unsoundly.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/pipe_field.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "via_pipe" })
  v.explanation.actual |> should.equal(types.Specific(set.from_list(["Disk"])))
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
  // A nested call whose INTERMEDIATE receiver type lives in ANOTHER module.
  // `handler.handle` calls `model.service.org.create("acme")`;
  // girard types `model.service.org` as `svc.OrganizationService`, and the
  // module-qualified `assume svc.OrganizationService.create : [Storage, Time]`
  // line resolves it cross-module — so the [] budget fails with that precise
  // effect. Synthesized as a multi-module project so the consumer's field `assume` line
  // points at a type defined in a different module.
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
        <> "assume svc.OrganizationService.create : [Storage, Time]\n",
    )

  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/handler.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "handle" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Storage", "Time"])))

  let _ = simplifile.delete(root)
  Nil
}

// Field effects derived from construction
//
// Field effects inferred from what the construction wires in — inline
// closures, operator-typed closures, and same-module named functions — with
// no hand-written field `assume` line.

pub fn closure_field_effect_from_construction_test() {
  // A record field wired to an *inline closure* at construction resolves to the
  // closure body's effect ([Stdout]) without a hand-written `type` annotation —
  // previously this fell back to [Unknown].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let closure_result =
    list.find(results, fn(r) { r.file == "test/fixtures/closure_field.gleam" })
  let assert Ok(r) = closure_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn operator_typed_closure_field_test() {
  // An *operator-typed* field (a closure that calls its own callback) is lifted
  // to `λnext. [next]` and applied at the field call `m.wrap(io.println)`,
  // resolving to the supplied callback's [Stdout] — previously [Unknown].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let operator_result =
    list.find(results, fn(r) { r.file == "test/fixtures/operator_field.gleam" })
  let assert Ok(r) = operator_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn inferred_field_effect_from_construction_test() {
  // inferred_field binds the receiver from a *call* (`let l = make()`). Tier 2's
  // let-bound call-result provenance grounds `make`'s return construction
  // (`Logger(emit: io.println)`) per receiver, so `l.emit()` resolves to the
  // precise [Stdout] — the in-package construction is proven for this receiver,
  // not borrowed from the nominal index.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let inferred_result =
    list.find(results, fn(r) { r.file == "test/fixtures/inferred_field.gleam" })
  let assert Ok(r) = inferred_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn local_field_value_resolved_test() {
  // local_field.run wires a *same-module* function (my_logger : [Stdout]) into a
  // record field and binds the receiver from a call (`let l = make()`). Tier 2's
  // call-result provenance grounds `make`'s return construction per receiver, so
  // `l.emit()` resolves the wired same-module function to the precise [Stdout].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let local_result =
    list.find(results, fn(r) { r.file == "test/fixtures/local_field.gleam" })
  let assert Ok(r) = local_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

// Same-module wiring
//
// A function wired into a record field by the very module being inferred. It is
// not in the knowledge base yet — that holds the spec file, the dependencies and
// the project modules already inferred — so resolution falls back to the
// module's own definitions. Each assertion is on the exact effect set: the
// difference this covers is a stray `Unknown` alongside the real effect.

fn local_wired_actual(function: String) -> types.EffectSet {
  fixture_actual("local_wired.gleam", function)
}

pub fn local_wired_direct_construction_test() {
  // `perform(Reader(read: disk_read, ..), "x")` wires a private same-module
  // function straight into the constructor. Constructor arguments are skipped
  // during extraction, so the field call is the only route to [Disk] — nothing
  // else in the body can contribute it.
  local_wired_actual("run_direct")
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

pub fn local_wired_inherited_construction_test() {
  // The receiver is a call result (`default_reader()`) whose construction wired
  // the field to a same-module private function. `disk_read` is named nowhere in
  // the calling body, so [Disk] can only come from resolving the field.
  local_wired_actual("run_inherited")
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

pub fn local_wired_builder_overlay_test() {
  // A builder overlay replaces the constructor's default with another
  // same-module function. The override's [Stdout] resolves and the default's
  // [Disk] is gone — last-write-wins, and no `Unknown` from the unlisted
  // override.
  local_wired_actual("run_replaced")
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn local_wired_producer_call_test() {
  // The field is wired from a same-module producer call
  // (`Reader(read: make_read(), ..)`): the returned closure's [Disk] resolves.
  local_wired_actual("run_producer")
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

pub fn local_wired_closure_test() {
  // A let-bound closure wired into the field by shorthand resolves to the
  // closure body's [Disk], with no `Unknown` for the field call.
  local_wired_actual("run_closure")
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

pub fn local_wired_parameter_stays_polymorphic_test() {
  // A field wired to the caller's own parameter is not a module function:
  // it stays polymorphic in that parameter instead of borrowing a same-module
  // definition.
  local_wired_actual("run_unresolved")
  |> should.equal(types.Polymorphic(set.new(), set.from_list(["read"])))
}

pub fn local_wired_opaque_producer_is_unknown_test() {
  // The field is wired from an external producer graded can't see into. There is
  // no definition to lift, so the field call stays [Unknown].
  local_wired_actual("run_opaque")
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn local_wired_undeclared_external_is_unknown_test() {
  // The field is wired to a same-module bodyless `@external` with no
  // `assume` line. There is no body to lift — reading its empty one
  // as pure would understate it — so it stays [Unknown].
  local_wired_actual("run_undeclared_external")
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn local_wired_self_reference_terminates_test() {
  // A function wiring *itself* into the field it then calls. Resolution stops at
  // the cycle rather than looping, leaving [Unknown].
  local_wired_actual("run_self_wired")
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn local_wired_mutual_reference_terminates_test() {
  // Two functions wiring each other into the field they call: the cycle is cut
  // the same way, [Unknown], and the analysis terminates.
  local_wired_actual("run_mutual")
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn builder_field_replaced_is_precise_test() {
  // builder_field.run_replaced binds `opts = default_options() |>
  // with_resolver(logging_resolver)` and calls `annotate(_, opts)`. Tier 2's
  // overlay resolves `annotate`'s polymorphic `options.resolver` onto the
  // builder-set `logging_resolver` — [Stdout], last-write-wins — not the default
  // resolver's [Disk], and not [Unknown].
  builder_field_actual("run_replaced")
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn builder_field_inherited_default_test() {
  // builder_field.run_default calls `annotate(_, default_options())` with no
  // override, so the field call inherits the default resolver's [Disk].
  builder_field_actual("run_default")
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

pub fn builder_field_cross_package_test() {
  // The real cross-package case: a consumer calls a *dependency's* builder and
  // annotate. The dependency is present as an installed package — its `.graded`
  // spec carries `annotate`'s polymorphic field bound, and its source under
  // `build/packages` gives both the parameter positions and `with_resolver`'s
  // builder signature (derived from the source the consumer compiled against, so
  // it can never skew from a stale spec — no `update` line is needed here). The
  // consumer composes the overlay and resolves `annotate`'s field onto the
  // consumer-supplied resolver — [Stdout], not [Unknown].
  let root = "build/xpkg_builder"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) =
    simplifile.create_directory_all(root <> "/build/packages/dep/src")

  let assert Ok(Nil) =
    simplifile.write(root <> "/gleam.toml", "name = \"app\"\n")
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/app.gleam",
      "import dep

@external(erlang, \"m\", \"log\")
fn log(message: String) -> Nil

pub fn run() -> Nil {
  let opts = dep.default_options() |> dep.with_resolver(log)
  dep.annotate(\"x\", opts)
}
",
    )
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/app.graded",
      "assume app.log : [Stdout]\ncheck app.run : []\n",
    )
  // The dependency's source — graded reads it only for parameter positions.
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/build/packages/dep/src/dep.gleam",
      "pub type Options {
  Options(resolver: fn(String) -> Nil)
}

pub fn default_options() -> Options {
  Options(resolver: fn(_) { Nil })
}

pub fn with_resolver(options: Options, resolver: fn(String) -> Nil) -> Options {
  Options(..options, resolver:)
}

pub fn annotate(source: String, options: Options) -> Nil {
  options.resolver(source)
}
",
    )
  // The dependency's installed metadata: annotate's polymorphic field bound. No
  // `update` line — the builder signature is derived from the source above.
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/build/packages/dep/dep.graded",
      "effects dep.annotate(options.resolver: [options.resolver]) : [options.resolver]
effects dep.default_options : []
effects dep.with_resolver : []
",
    )

  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "run" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))

  let _ = simplifile.delete(root)
  Nil
}

pub fn builder_field_inline_argument_test() {
  // The builder call inline as annotate's argument (not let-bound) resolves the
  // overridden resolver to [Stdout], the same as the let-bound form.
  builder_field_actual("run_inline_arg")
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn builder_field_labeled_reordered_arguments_test() {
  // builder_field.run_labeled_reordered calls the labeled builder with its
  // arguments in the reverse of the parameter order (`resolver:` before
  // `options:`). The labels route each argument to its parameter position, so
  // the overlay still replaces the resolver — [Stdout], not the default [Disk].
  builder_field_actual("run_labeled_reordered")
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn builder_field_whole_caller_union_test() {
  // builder_field.run_union unions the eager construction's own [Disk] (a real,
  // separate effect — nuance #2) with the overridden field call's [Stdout]. The
  // two surface as separate per-call violations against the [] budget; together
  // they cover the whole-caller union.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/builder_field.gleam" })
  let union =
    r.violations
    |> list.filter(fn(v) { v.function == "run_union" })
    |> list.fold(set.new(), fn(acc, v) {
      case v.explanation.actual {
        types.Specific(labels) -> set.union(acc, labels)
        _ -> acc
      }
    })
  union |> should.equal(set.from_list(["Disk", "Stdout"]))
}

// The reported effect of `function`'s violation in one `test/fixtures` file.
fn fixture_actual(file: String, function: String) -> types.EffectSet {
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/" <> file })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == function })
  v.explanation.actual
}

fn builder_field_actual(function: String) -> types.EffectSet {
  fixture_actual("builder_field.gleam", function)
}

fn builder_chain_actual(function: String) -> types.EffectSet {
  fixture_actual("builder_chain.gleam", function)
}

fn builder_shadow_actual(function: String) -> types.EffectSet {
  fixture_actual("builder_shadow.gleam", function)
}

pub fn builder_shadow_rebound_param_is_unknown_test() {
  // A builder that rebinds its `resolver` parameter before the update stores a
  // fixed value, not the caller's argument. It must not be modeled as a builder
  // that stores the caller's (pure) value — the field stays [Unknown], not [].
  builder_shadow_actual("run_shadowed_param")
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn builder_shadow_shadowed_name_is_unknown_test() {
  // A local closure shadowing the top-level `with_resolver` name must not have
  // the top-level builder's signature applied — the field stays [Unknown].
  builder_shadow_actual("run_shadowed_name")
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn builder_shadow_param_function_collision_is_unknown_test() {
  // A parameter named the same as a pure module function (`handler`) wired into a
  // field resolves as the parameter — the call stays polymorphic in `handler`,
  // never borrowing the module function's [] effect (which would under-report).
  builder_shadow_actual("run_param_collision")
  |> should.equal(types.Polymorphic(set.new(), set.from_list(["handler"])))
}

pub fn builder_shadow_closure_param_collision_is_unknown_test() {
  // A *closure* parameter named the same as a pure module function (`handler`)
  // wired into a field is neither the module function nor an enclosing
  // parameter, so a direct read of the field stays [Unknown] rather than
  // borrowing the module function's [].
  builder_shadow_actual("run_closure_param_collision")
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn builder_shadow_closure_param_collision_forwarded_is_unknown_test() {
  // The same closure-parameter collision read through a forwarding callee: the
  // forwarded field variable stays [Unknown] too.
  builder_shadow_actual("run_closure_param_collision_forwarded")
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn builder_shadow_fixed_sibling_is_unknown_test() {
  // A builder that writes one field from a fixed value states no overlay: the
  // fields it does not write would fall through to a base that grounds nothing.
  // The field pass reads such a builder for the fields it *does* route; a field
  // call through it still resolves [Unknown].
  builder_shadow_actual("run_fixed_sibling")
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn builder_chain_update_preserves_resolver_test() {
  // A later `with_reporter` update preserves the resolver set by an earlier
  // `with_resolver` — the overlay composes.
  builder_chain_actual("run_chained")
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn builder_chain_last_write_wins_test() {
  // Two resolver updates: the second (logging, [Stdout]) wins over the first
  // (disk, [Disk]).
  builder_chain_actual("run_last_wins")
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn builder_chain_opaque_base_updated_field_test() {
  // A builder over an untraceable producer resolves the updated field precisely;
  // the base never has to ground.
  builder_chain_actual("run_opaque_base")
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn builder_chain_inline_update_over_opaque_base_test() {
  // An inline `Options(..opaque_options(), resolver: logging_resolver)`: the
  // updated resolver resolves to [Stdout], field-selective over the opaque base.
  builder_chain_actual("run_inline_updated")
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn builder_chain_call_result_replacement_direct_test() {
  // A builder-set field whose replacement is a call result (`resolver:
  // make_logging()`) resolves precisely on a direct read — the per-value
  // resolver applies the returned closure — to [Stdout], not [Unknown].
  builder_chain_actual("run_call_result_direct")
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn builder_chain_call_result_replacement_forwarded_test() {
  // The same call-result replacement forwarded through `annotate`: the forwarding
  // site grounds the resolver's operator to [Stdout] (not [Unknown]).
  builder_chain_actual("run_call_result_forwarded")
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn builder_chain_closure_replacement_forwarded_test() {
  // An inline closure builder replacement forwarded through `annotate` resolves
  // to the first-order closure body's [Stdout], not [Unknown].
  builder_chain_actual("run_closure_forwarded")
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn builder_chain_inherited_field_over_traceable_base_test() {
  // The inherited resolver (only the reporter was updated) over a *traceable*
  // producer grounds through that producer's wiring to [Disk], forwarded through
  // `annotate` — the base is groundable, so the overlay must not discard it.
  builder_chain_actual("run_traceable_inherited")
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

pub fn builder_chain_inherited_field_over_traceable_base_direct_test() {
  // The same inherited field read directly off the overlay.
  builder_chain_actual("run_traceable_inherited_direct")
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

pub fn builder_chain_inherited_field_over_chained_traceable_base_test() {
  // Two stacked overlays: the inherited field grounds through both layers.
  builder_chain_actual("run_traceable_inherited_chained")
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

pub fn builder_chain_inherited_field_over_opaque_base_test() {
  // The inherited reporter (not updated) over the opaque base falls through to
  // the untraceable base and stays [Unknown] — sound, never guessed.
  builder_chain_actual("run_inline_inherited")
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn shadow_field_does_not_borrow_function_effect_test() {
  // shadow_field.make wires a destructured, opaque local `handler` into a field.
  // That local shadows the top-level `handler` (pure []). The field call
  // `c.run()` must stay [Unknown] — never borrow the shadowed function's effect,
  // which would under-report (the field is really an untraceable value).
  fixture_actual("shadow_field.gleam", "go")
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

// Callback arguments and local resolution
//
// Arguments to fn-typed parameters (named, labeled) resolve to their real
// effects, record-update field values are walked, and parameter shadowing
// wins over same-module names.

pub fn named_fn_arg_resolves_test() {
  // named_fn_arg.run passes a *same-module named function* (logging_parser :
  // [Stdout]) to a first-order fn-typed parameter. The argument resolves to the
  // function's real effect, so the [] budget fails with the precise [Stdout] —
  // not the [Unknown] graded fell back to before (inline closures already
  // resolved; named references did not).
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/named_fn_arg.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "run" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn labeled_callback_resolves_test() {
  // labeled_callback.run passes an effectful callback (logging_parser :
  // [Stdout]) with a Gleam label (`with:`). Argument-to-parameter matching now
  // binds the labelled argument, so the parameter's effect variable discharges
  // to [Stdout] instead of leaking unresolved into the fully-applied caller.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/labeled_callback.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "run" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn record_update_field_walked_test() {
  // record_update.run updates a field with an effectful expression (shout :
  // [Stdout]). The call sits inside a record update, so its effect surfaces
  // only if the extractor walks the updated field values, not just the base
  // record. Without that, the [Stdout] is silently dropped and `run` wrongly
  // resolves to [].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/record_update.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "run" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn shadowed_param_resolves_through_bound_test() {
  // shadow_param.run takes a fn-typed parameter `handler` that shadows a
  // same-module function of the same name (handler : [Stdout]). The forwarded
  // argument must resolve through the param bound ([]), not by lifting the
  // shadowed function — so the [] budget holds and `run` has no violation.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/shadow_param.gleam" })
  list.any(r.violations, fn(v) { v.function == "run" }) |> should.be_false()
}

pub fn aliased_param_call_resolves_through_bound_test() {
  // shadow_param.run_alias aliases its fn-typed parameter (`let f = handler`)
  // and calls the alias directly. The call must resolve through the parameter's
  // bound ([]), not the shadowed same-module `handler` nor [Unknown], so the []
  // budget holds and `run_alias` has no violation.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == "test/fixtures/shadow_param.gleam" })
  list.any(r.violations, fn(v) { v.function == "run_alias" })
  |> should.be_false()
}

// Infer/check round trip
//
// `run_infer` regenerates the fixtures spec in place, preserving the
// hand-written check lines alongside the inferred effects.

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
  let assert Ok(results) = graded.check_project("test/fixtures")
  let impure_result =
    list.find(results, fn(r) { r.file == "test/fixtures/impure_view.gleam" })
  let assert Ok(r) = impure_result
  { r.violations != [] } |> should.be_true()

  // Restore the captured fixture so subsequent test runs start clean.
  let assert Ok(Nil) = simplifile.write(spec_path, original)
}

// Dependency effect loading
//
// Effects, polymorphic bounds, and module-level externals load from installed
// and path dependencies — from a committed spec when present, otherwise by
// inferring the dependency's source.

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

  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/proj.gleam" })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "run" })
  v.explanation.actual |> should.equal(types.Specific(set.from_list(["Http"])))

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

  let assert Ok(results) = graded.check_project(app_root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == app_root <> "/app.gleam" })

  // Pure callback: the bound discharges, so the [] budget holds.
  list.any(r.violations, fn(v) { v.function == "caller_pure" })
  |> should.be_false()
  // Impure callback: the callback's real effect ([Stdout]) flows through the
  // bound — not a leaked variable, not [Unknown].
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_impure" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))

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

  let assert Ok(results) = graded.check_project(app_root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == app_root <> "/app.gleam" })

  list.any(r.violations, fn(v) { v.function == "caller_pure" })
  |> should.be_false()
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "caller_impure" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))

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
  run_path_dep_project(name, dep_files, None, spec, app_src)
}

// The same fixture with the dependency shipping a committed `dep.graded` of its
// own — the branch a consumer takes when the dep author already ran `graded
// infer`, rather than the source-inference fallback.
fn run_path_dep_spec_fixture(
  name: String,
  dep_files: List(#(String, String)),
  dep_spec: String,
  spec: String,
  app_src: String,
) -> types.CheckResult {
  run_path_dep_project(name, dep_files, Some(dep_spec), spec, app_src)
}

fn run_path_dep_project(
  name: String,
  dep_files: List(#(String, String)),
  dep_spec: Option(String),
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
  case dep_spec {
    Some(content) -> {
      let assert Ok(Nil) = simplifile.write(dep_root <> "/dep.graded", content)
      Nil
    }
    None -> Nil
  }

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

  let assert Ok(results) = graded.check_project(app_root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == app_root <> "/app.gleam" })
  r
}

pub fn path_dep_module_level_external_marks_pure_test() {
  // Source-only path dep `dep` with an opaque FFI body graded would infer as
  // [Unknown]. `assume dep : []` declares the whole module pure, so
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
      "assume dep : []\n\ncheck app.caller : []\n",
      "import dep\n\npub fn caller() -> Nil {\n  dep.touch()\n}\n",
    )
  list.any(r.violations, fn(v) { v.function == "caller" })
  |> should.be_false()
}

pub fn a_spec_less_path_dep_external_is_not_a_declaration_test() {
  // Inference over a spec-less path dependency's source records its bodyless
  // `@external` as [Unknown]. That is a walk, not a written line, so it must not
  // answer for foreign code the way a committed spec does — otherwise the call
  // reads as resolved from the path dependency when nothing declared it.
  let r =
    run_path_dep_fixture(
      "pd_inferred_external",
      [
        #(
          "dep.gleam",
          "@external(erlang, \"d\", \"t\")\npub fn touch() -> Nil\n",
        ),
      ],
      "check app.caller : []\ncheck app.passes : []\n",
      "import dep

pub fn caller() -> Nil {
  dep.touch()
}

pub fn passes() -> Nil {
  apply(dep.touch)
}

fn apply(f: fn() -> Nil) -> Nil {
  f()
}
",
    )
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  v.explanation.reason |> should.equal(Some(types.UndeclaredExternal))
  // Not attributed to the path dependency: no declaration answered.
  v.explanation.origin |> should.equal(None)
  // The query reads the same name through the same gate, rather than claiming
  // the answer came from inference over the dependency's source.
  let assert Ok(answered) =
    graded.run_effect("build/pd_inferred_external_app", "dep.touch")
  answered
  |> string.contains("an external with no declared effects")
  |> should.be_true()
  // And a reference to it warns about nothing, as unresolved references do.
  r.warnings |> should.equal([])
}

pub fn a_committed_path_dep_external_still_declares_test() {
  // The other half of the same rule: a line the dep author committed *is* a
  // declaration, so it answers for the external and names itself as the source.
  let r =
    run_path_dep_spec_fixture(
      "pd_committed_external",
      [
        #(
          "dep.gleam",
          "@external(erlang, \"d\", \"t\")\npub fn touch() -> Nil\n",
        ),
      ],
      "assume dep.touch : [Disk]\n",
      "check app.caller : []\n",
      "import dep\n\npub fn caller() -> Nil {\n  dep.touch()\n}\n",
    )
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  v.explanation.origin |> should.equal(Some(types.PathDependency("dep")))
}

pub fn a_malformed_path_dep_spec_keeps_the_spec_branch_test() {
  // A path dependency shipping a spec file that does not parse stays on the
  // spec branch: its entries are ignored and the consumer falls back to the
  // tiers below, rather than inferring over the dependency's source. Source
  // inference would answer `[]` for the dep's pure function; the empty spec
  // answers nothing, so the call charges [Unknown].
  let r =
    run_path_dep_spec_fixture(
      "pd_malformed_spec",
      [#("dep.gleam", "pub fn noop() -> Nil {\n  Nil\n}\n")],
      "not a spec line\n",
      "check app.caller : []\n",
      "import dep\n\npub fn caller() -> Nil {\n  dep.noop()\n}\n",
    )
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  v.explanation.origin |> should.equal(None)
}

pub fn path_dep_module_level_external_preserves_effect_test() {
  // A non-empty module-level external propagates that exact set, it does not
  // collapse to pure. `assume dep : [Database]` makes `dep.touch`
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
      "assume dep : [Database]\n\ncheck app.caller : []\n",
      "import dep\n\npub fn caller() -> Nil {\n  dep.touch()\n}\n",
    )
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Database"])))
}

// The dep source and consumer call the three shipped-external tests share: an
// opaque FFI body graded can only infer as [Unknown], and an app whose `caller`
// budget is [] until the dep's declaration resolves it.
fn ffi_dep_files() -> List(#(String, String)) {
  [#("ffi.gleam", "@external(erlang, \"d\", \"n\")\npub fn now() -> Nil\n")]
}

const ffi_caller_src = "import ffi\n\npub fn caller() -> Nil {\n  ffi.now()\n}\n"

pub fn path_dep_shipped_function_external_resolves_test() {
  // The dep's own `assume` line for its FFI, read from the spec it
  // ships. Before those lines were consumed, `ffi.now` resolved to [Unknown] for
  // every consumer even though the dep author had declared it.
  let r =
    run_path_dep_spec_fixture(
      "pd_shipped_fn_ext",
      ffi_dep_files(),
      "assume ffi.now : [Time]\n",
      "check app.caller : []\n",
      ffi_caller_src,
    )
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual |> should.equal(types.Specific(set.from_list(["Time"])))
  v.explanation.origin |> should.equal(Some(types.PathDependency("dep")))
}

pub fn path_dep_shipped_module_external_resolves_test() {
  // A module-level line in the shipped spec governs every function in that
  // module for the consumer, and names the dep it came from.
  let r =
    run_path_dep_spec_fixture(
      "pd_shipped_mod_ext",
      ffi_dep_files(),
      "assume ffi : [Time]\n",
      "check app.caller : []\n",
      ffi_caller_src,
    )
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual |> should.equal(types.Specific(set.from_list(["Time"])))
  v.explanation.origin
  |> should.equal(
    Some(types.ModuleAssumeOrigin(source: types.PathDependency("dep"))),
  )
}

pub fn consumer_module_external_beats_a_shipped_one_test() {
  // Both sides declare the same module. The consumer's own line is applied
  // before path deps are folded in, and the dep's spec overrides only what the
  // catalog wrote — so the consumer keeps the last word on the module.
  let r =
    run_path_dep_spec_fixture(
      "pd_shipped_mod_ext_shadowed",
      ffi_dep_files(),
      "assume ffi : [Time]\n",
      "assume ffi : [Mocked]\n\ncheck app.caller : []\n",
      ffi_caller_src,
    )
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Mocked"])))
  v.explanation.origin
  |> should.equal(Some(types.ModuleAssumeOrigin(source: types.UserAssume)))
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
      "assume ffi : []\n\ncheck app.caller : []\n",
      "import wrapper\n\npub fn caller() -> Nil {\n  wrapper.go()\n}\n",
    )
  list.any(r.violations, fn(v) { v.function == "caller" })
  |> should.be_false()
}

pub fn path_dep_module_external_keeps_returned_operator_test() {
  // A module-level external suppresses only the call effect, not the
  // returned-operator metadata. `make` returns a pure closure; `wrapper` does
  // `let action = ffi.make()  action()`. With `assume ffi : []`, the
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
      "assume ffi : []\n\ncheck app.caller : []\n",
      "import wrapper\n\npub fn caller() -> Nil {\n  wrapper.go()\n}\n",
    )
  list.any(r.violations, fn(v) { v.function == "caller" })
  |> should.be_false()
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

  let assert Ok(results) = graded.check_project(app_root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == app_root <> "/app.gleam" })
  list.any(r.violations, fn(v) { v.function == "caller" })
  |> should.be_false()

  let _ = simplifile.delete(app_root)
  let _ = simplifile.delete(dep_root)
  Nil
}

// Project-module externals
//
// Module-level `assume` declarations governing sibling project
// modules, during both check and infer.

// An opaque FFI body graded infers as [Unknown]: the canonical declared-external
// target across the module-external project fixtures below.
const ffi_touch = "@external(erlang, \"d\", \"t\")\npub fn touch() -> Nil\n"

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

  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  r
}

pub fn project_module_level_external_marks_pure_test() {
  // A project module `db` with an opaque FFI body graded would infer as
  // [Unknown]. `assume db : []` declares the whole module pure, so
  // `db.touch` resolves to [] and `check caller : []` holds — the
  // project-module counterpart of `path_dep_module_level_external_marks_pure`.
  // Before the fix the in-memory inference of `db` left an [Unknown] in
  // `all_effects` that shadowed the declaration.
  let r =
    run_project_module_fixture(
      "modext_pure",
      [#("db.gleam", ffi_touch)],
      "assume db : []\n\ncheck app.caller : []\n",
      "import db\n\npub fn caller() -> Nil {\n  db.touch()\n}\n",
    )
  list.any(r.violations, fn(v) { v.function == "caller" })
  |> should.be_false()
}

pub fn project_module_level_external_preserves_effect_test() {
  // A non-empty module-level external propagates that exact set, it does not
  // collapse to pure or stay an inferred [Unknown]. `assume db :
  // [Database]` makes `db.touch` resolve to [Database], so `check caller : []`
  // fails with [Database].
  let r =
    run_project_module_fixture(
      "modext_eff",
      [#("db.gleam", ffi_touch)],
      "assume db : [Database]\n\ncheck app.caller : []\n",
      "import db\n\npub fn caller() -> Nil {\n  db.touch()\n}\n",
    )
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Database"])))
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
      "assume db : []\n\ncheck app.caller : []\n",
      "import wrapper\n\npub fn caller() -> Nil {\n  wrapper.go()\n}\n",
    )
  list.any(r.violations, fn(v) { v.function == "caller" })
  |> should.be_false()
}

pub fn project_module_external_keeps_returned_operator_test() {
  // A module-level external suppresses only the call effect, not the
  // returned-operator metadata. `db.make` returns a pure closure; `wrapper` does
  // `let action = db.make()  action()`. With `assume db : []`, the call
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
      "assume db : []\n\ncheck app.caller : []\n",
      "import wrapper\n\npub fn caller() -> Nil {\n  wrapper.go()\n}\n",
    )
  list.any(r.violations, fn(v) { v.function == "caller" })
  |> should.be_false()
}

pub fn project_module_external_infer_omits_lines_and_governs_test() {
  // `graded infer` over a project with `assume db : [Database]` writes
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
    "assume db : [Database]\n",
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

pub fn project_module_external_infer_filters_stale_effects_test() {
  // A field is wired to a function of a module declared as a module-level
  // external. The spec still carries a STALE `effects db.touch : [Stdout]` line;
  // since function effects outrank module effects, that stale entry would make
  // `graded infer` resolve `Runner.act` (and its caller `go`) to [Stdout] —
  // disagreeing with `check`, which filters it. With the stale line dropped, the
  // field resolves to the declared [Database].
  let root = "build/modext_construction_proj"
  write_project(
    root,
    [
      #("db.gleam", ffi_touch),
      #(
        "app.gleam",
        "import db\n\n"
          <> "pub type Runner {\n  Runner(act: fn() -> Nil)\n}\n\n"
          <> "pub fn go() -> Nil {\n  let r = Runner(act: db.touch)\n  r.act()\n}\n",
      ),
    ],
    "assume db : [Database]\neffects db.touch : [Stdout]\n",
  )
  let assert Ok(Nil) = graded.run_infer(root)

  let assert Ok(content) = simplifile.read(root <> "/proj.graded")
  let assert Ok(file) = annotation.parse_file(content)
  let annotations = annotation.extract_annotations(file)
  let assert Ok(go) = list.find(annotations, fn(a) { a.function == "app.go" })
  go.effects |> should.equal(types.TLabels(set.from_list(["Database"])))
}

// Function-typed fields on dependency-defined types
//
// `type` field annotations for dependency-defined records, whether declared
// in the consumer's own spec or shipped by the dependency itself.

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
      "assume repo.Repo.find : [Storage]\n\ncheck app.use_field : []\n",
      "import repo.{type Repo}\n\n"
        <> "pub fn use_field(r: Repo) -> Int {\n  r.find(\"x\")\n}\n",
    )
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "use_field" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Storage"])))
}

pub fn path_dep_ships_type_field_test() {
  // The dependency itself ships the `type` annotation in its committed
  // `dep.graded`; the consumer declares no field annotation at all. graded must
  // load the dependency spec's field `assume` lines (not just its `effects`) so the
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
      "assume dep/repo.Repo.find : [Storage]\n",
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

  let assert Ok(results) = graded.check_project(app_root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == app_root <> "/app.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "use_field" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Storage"])))

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
      "assume dep/repo.Repo.find : [Storage]\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/app.gleam",
      "import dep/repo.{type Repo}\n\n"
        <> "pub fn use_field(r: Repo) -> Int {\n  r.find(\"x\")\n}\n",
    )

  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert Ok(v) =
    list.find(r.violations, fn(v) { v.function == "use_field" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Storage"])))

  let _ = simplifile.delete(root)
  Nil
}

// Return provenance
//
// Same-module return provenance: passthroughs, getters, rebuilds, joins, and
// recursion forward constructed receivers into callee field calls, widening
// to [Unknown] only where the return can't be traced.

pub fn provenance_passthrough_resolves_test() {
  // provenance_passthrough.caller passes `id_options(Options(resolver:
  // resolver))` to `inner`. `id_options` returns its whole parameter
  // (`Passthrough`), so `o.resolver` forwards onto the caller's `resolver` and
  // the `resolver: [Stdout]` bound discharges it — the [] budget fails with
  // [Stdout], not the [Unknown] an untraced call result would collapse to.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_passthrough.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_getter_resolves_test() {
  // provenance_getter.caller (the headline case) passes `get_options(Config(..))`
  // to `inner`. `get_options` returns `config.options` (a `Path`), so `o.resolver`
  // forwards through the getter's path onto the caller's `resolver` and the
  // bound discharges it to [Stdout].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_getter.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_rebuild_resolves_test() {
  // provenance_rebuild.caller passes `normalize(Options(resolver: resolver))` to
  // `inner`. `normalize` rebuilds `Options(resolver: o.resolver)` (a `Build`), so
  // `o.resolver` forwards onto the caller's `resolver` and the bound discharges
  // it to [Stdout]. `inner`'s own receiver is a parameter, so the field call is
  // resolved as a forwarding field variable — never by the nominal index — so the
  // rebuild's sibling receiver-path wiring no longer leaks a conservative
  // [Unknown]. The result is the precise [Stdout] alone.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_rebuild.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_partial_build_resolves_test() {
  // provenance_partial.caller passes `normalize(Options(label: "", resolver:
  // resolver))` to `inner`. `normalize` rebuilds `Options(label: "", resolver:
  // o.resolver)` — a partial `Build` that keeps `resolver` and drops the literal
  // `label` — so `o.resolver` forwards onto the caller's `resolver` and the bound
  // discharges to [Stdout], where the all-or-nothing build left it [Unknown].
  // `inner`'s parameter receiver keeps the field call polymorphic, so the sibling
  // receiver-path wiring no longer leaks an [Unknown] — the precise [Stdout]
  // stands alone.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_partial.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_shorthand_build_resolves_test() {
  // provenance_shorthand.caller passes `make(resolver)` to `inner`. `make` builds
  // `Options(label: "", resolver:)` using field shorthand — sugar for `resolver:
  // resolver` — so the `Build` provenance keeps the parameter-rooted `resolver`
  // field and `o.resolver` forwards onto the caller's `resolver`, discharging to
  // [Stdout]. Classifying the shorthand field as opaque left it [Unknown].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_shorthand.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_labeled_resolves_test() {
  // provenance_labeled.caller passes `rebuild(with: Options(resolver: resolver))`
  // to `inner`. `rebuild` is a `Passthrough`, but the call labels its argument
  // (`with:`), so grounding reorders it into parameter-position order via the
  // callee signature before substituting. The constructed `Options` forwards
  // through, `o.resolver` re-keys onto the caller's `resolver`, and the bound
  // discharges to [Stdout] — where before the labeled call site widened to
  // [Unknown].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_labeled.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
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
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_binding_resolves_test() {
  // provenance_binding.caller passes `alias(Options(resolver: resolver))` to
  // `inner`. `alias` threads its parameter through a `let` before returning it,
  // so the provenance walk folds through the binding to a `Passthrough`. The
  // constructed `Options` forwards through, `o.resolver` re-keys onto the
  // caller's `resolver`, and the bound discharges to [Stdout] — proving
  // provenance survives the binding rather than widening at it.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_binding.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_recursion_resolves_test() {
  // provenance_recursion.caller passes `pick(True, Options(resolver: resolver))`
  // to `inner`. `pick` returns its `o` parameter through a tail-recursive call,
  // so its provenance is the fixpoint of the `case` join — both branches pass `o`
  // through, converging to a `Passthrough`. The constructed `Options` forwards
  // through, `o.resolver` re-keys onto the caller's `resolver`, and the bound
  // discharges to [Stdout] — where a naive walk widened on the recursion.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_recursion.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_branch_resolves_test() {
  // provenance_branch.caller passes `pick(..)` to `inner`. `pick` returns a
  // `case` over its `a`/`b` parameters, so its provenance is a `Join` of two
  // `Passthrough`s. The join grounds each branch and forwards `o.resolver` onto
  // the caller's `resolver` through both, discharging the bound to [Stdout] —
  // where before value-level joins it was [Unknown].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_branch.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_branch_of_paths_resolves_test() {
  // provenance_branch_path.caller passes `pick(..)` to `inner`. `pick` returns a
  // `case` whose branches are parameter-rooted paths (`a.options`/`b.options`),
  // so its provenance is a `Join` of two `Path`s. The join grounds each branch and
  // forwards `o.resolver` onto the caller's `resolver`, discharging the bound to
  // [Stdout] — where `classify_case_options` gates path branches, the receiver
  // would collapse to [Unknown].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_branch_path.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_branch_of_builds_resolves_test() {
  // provenance_branch_build.caller passes `pick(..)` to `inner`. `pick` returns a
  // `case` whose branches rebuild `Options(resolver: a.resolver)`, so its
  // provenance is a `Join` of two `Build`s. The join forwards `o.resolver` onto
  // the caller's `resolver` (discharging to [Stdout]). `inner`'s parameter
  // receiver keeps the field call polymorphic, so the branches' receiver-path
  // wiring no longer leaks an [Unknown] — the precise [Stdout] stands alone.
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_branch_build.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn provenance_computed_deep_stays_unknown_test() {
  // provenance_computed_deep.caller passes `deep(resolver)` to `inner`. `deep`'s
  // return is a nested call (`get(make(resolver))`), whose provenance is
  // `Opaque` (no helper-call composition in Phase 1), so it stays [Unknown].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_computed_deep.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn provenance_external_stays_unknown_test() {
  // provenance_external.caller passes `load_options(resolver)` to `inner`.
  // `load_options` is an external with no visible body, so its provenance can't
  // be traced and the field call concretizes to [Unknown].
  let assert Ok(results) = graded.check_project("test/fixtures")
  let assert Ok(r) =
    list.find(results, fn(r) {
      r.file == "test/fixtures/provenance_external.gleam"
    })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

// Nested source-directory scopes
//
// A directory inside a package's `src/` is a filter on what is reported, not on
// what is analysed. Resolution is a fact of the whole package — imports,
// `@external` discovery and module-path keying all are — so a scoped run charges
// exactly what the whole-package run charges, and its `check` lines keep the
// qualified names they were written with.

// A package whose `src/` holds one module in a nested directory and one beside
// it, both calling the same undeclared `@external`.
fn scoped_package(root: String) -> Nil {
  support.write_fixture(root, [
    #("gleam.toml", "name = \"scoped\"\n"),
    #(
      "scoped.graded",
      "effects ffi.now : []\ncheck sub/inner.go : []\ncheck outside.go : []\n",
    ),
    #(
      "src/ffi.gleam",
      "@target(erlang)
@external(erlang, \"scoped_ffi\", \"now\")
pub fn now() -> Nil
",
    ),
    #(
      "src/sub/inner.gleam",
      "import ffi\n\npub fn go() -> Nil {\n  ffi.now()\n}\n",
    ),
    #(
      "src/outside.gleam",
      "import ffi\n\npub fn go() -> Nil {\n  ffi.now()\n}\n",
    ),
  ])
  Nil
}

pub fn a_scoped_run_charges_what_the_whole_package_run_charges_test() {
  // The `@external` lives outside the scope. Analysed from the subtree alone it
  // was invisible, so the stale `effects ffi.now : []` answered and the check
  // passed; the whole-package run charges `[Unknown]`. Both now agree, and the
  // `check sub/inner.go` line still names the module it names package-wide.
  let root = "build/scoped_subtree"
  scoped_package(root)
  let scoped = root <> "/src/sub"

  let assert Ok(results) = graded.check_project(scoped)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == scoped <> "/inner.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("go")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  violation.explanation.reason |> should.equal(Some(types.UndeclaredExternal))

  // Out-of-scope files are analysed — that is what resolved the call above —
  // and not reported.
  results
  |> list.map(fn(r) { r.file })
  |> list.contains(root <> "/src/outside.gleam")
  |> should.be_false()

  // And no spurious spec lint: the `check` lines match project modules again.
  results
  |> list.flat_map(fn(r) { r.warnings })
  |> should.equal([])
  support.cleanup(root)
}

pub fn a_scoped_run_reads_the_same_result_from_an_absolute_path_test() {
  // Which spec a scoped run reads used to depend on the path form: from the
  // package root a relative subtree resolved its own (missing) spec, while an
  // absolute one resolved the surrounding project's. Both now resolve the
  // package the subtree is in.
  let root = "build/scoped_subtree_abs"
  scoped_package(root)
  let assert Ok(cwd) = simplifile.current_directory()
  let absolute = filepath.join(cwd, root <> "/src/sub")

  let assert Ok(results) = graded.check_project(absolute)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == absolute <> "/inner.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
  support.cleanup(root)
}

pub fn equivalent_spellings_of_a_scope_read_alike_test() {
  // `src/sub`, `./src/sub` and `src/sub/` name one directory, but a raw prefix
  // test read them as three: the trailing separator built a `src/sub//` prefix
  // matching none of the walked files, and the `./` failed to match the
  // package's `src/`, so the subtree was analysed as its own root under module
  // paths the `check` lines no longer named. Either way the run reported success
  // having verified nothing.
  let root = "build/scoped_subtree_spellings"
  scoped_package(root)
  let scoped = root <> "/src/sub"

  [scoped, scoped <> "/", scoped <> "//", "./" <> scoped, root <> "/src/./sub"]
  |> list.each(fn(spelling) {
    let assert Ok(results) = graded.check_project(spelling)
    let assert Ok(r) =
      list.find(results, fn(r) { r.file == scoped <> "/inner.gleam" })
    let assert [violation] = r.violations
    violation.function |> should.equal("go")
    violation.explanation.actual
    |> should.equal(types.Specific(set.from_list(["Unknown"])))
    // The scope still widened to the package, so no `check` line went unmatched.
    results |> list.flat_map(fn(r) { r.warnings }) |> should.equal([])
  })
  support.cleanup(root)
}

pub fn a_scoped_query_answers_for_the_whole_package_test() {
  // `why` and `effect` are read-only lookups over the package's index, so they
  // answer for a module outside the scope rather than declining a name the
  // analysis had to resolve anyway.
  let root = "build/scoped_subtree_query"
  scoped_package(root)
  let scoped = root <> "/src/sub"

  graded.run_effect(scoped, "outside.go")
  |> should.equal(Ok(
    "effects outside.go : [Unknown]\n// resolved from in-memory inference",
  ))
  let assert Ok(explanation) = graded.run_why(scoped, "outside.go")
  explanation |> string.contains("calls ffi.now") |> should.be_true()
  support.cleanup(root)
}

pub fn a_scoped_infer_writes_the_whole_package_spec_test() {
  // A package has one spec file, and it states the package's public surface. A
  // spec written from a subtree's modules alone would state that surface wrongly
  // rather than partially, so a scoped `infer` is a whole-package `infer`, at the
  // package root.
  let root = "build/scoped_subtree_infer"
  scoped_package(root)

  let assert Ok(_) = graded.run_infer(root <> "/src/sub")
  let assert Ok(written) = simplifile.read(root <> "/scoped.graded")
  string.contains(written, "effects sub/inner.go : [Unknown]")
  |> should.be_true()
  string.contains(written, "effects outside.go : [Unknown]") |> should.be_true()
  // The stale line for the external is repaired too, so the scoped run leaves
  // the spec exactly as the unscoped one would.
  string.contains(written, "effects ffi.now : [Unknown]") |> should.be_true()
  support.cleanup(root)
}

pub fn a_non_package_subtree_keeps_acting_as_its_own_root_test() {
  // The carve-out this repo's own `test/fixtures` workflow depends on: a subtree
  // of the surrounding project that is not under a package's `src/` is its own
  // root, so its spec is read from inside it and its module paths are keyed from
  // inside it. Widening here would write the fixture's spec into the project
  // around it.
  let root = "build/scoped_standalone/fixtures"
  support.write_fixture(root, [
    #("fixtures.graded", "check app.go : []\nassume ffi.now : [Time]\n"),
    #(
      "ffi.gleam",
      "@target(erlang)
@external(erlang, \"standalone_ffi\", \"now\")
pub fn now() -> Nil
",
    ),
    #("app.gleam", "import ffi\n\npub fn go() -> Nil {\n  ffi.now()\n}\n"),
  ])

  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Time"])))
  support.cleanup("build/scoped_standalone")
}

// Per-function externals over ordinary project functions
//
// `assume` declares code graded cannot see. A line naming a function
// of this package whose Gleam body is right there declares nothing: it is stale,
// the body is walked instead, and `infer` deletes the line rather than preserve
// a spec that under-reports the function forever.

fn stale_external_project(root: String) -> Nil {
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume m.logs : []
assume ffi.write : [Disk]
check m.logs : []
check caller.go : []
",
    ),
    #(
      "ffi.gleam",
      "@target(erlang)
@external(erlang, \"proj_ffi\", \"write\")
pub fn write() -> Nil
",
    ),
    #("m.gleam", "import ffi\n\npub fn logs() -> Nil {\n  ffi.write()\n}\n"),
    #("caller.gleam", "import m\n\npub fn go() -> Nil {\n  m.logs()\n}\n"),
  ])
  Nil
}

pub fn a_stale_project_external_is_ignored_everywhere_test() {
  // One rule, every path: the function's own `check`, a cross-module caller's,
  // `why` and `effect` all report the body's call, where the line used to
  // silence all four while same-module callers walked the body anyway.
  let root = "build/stale_external_project"
  stale_external_project(root)
  let disk = types.Specific(set.from_list(["Disk"]))

  let assert Ok(results) = graded.check_project(root)
  let assert Ok(own) =
    list.find(results, fn(r) { r.file == root <> "/m.gleam" })
  let assert [violation] = own.violations
  violation.function |> should.equal("logs")
  violation.explanation.actual |> should.equal(disk)

  let assert Ok(caller) =
    list.find(results, fn(r) { r.file == root <> "/caller.gleam" })
  let assert [call] = caller.violations
  call.explanation.actual |> should.equal(disk)

  let assert Ok(why) = graded.run_why(root, "m.logs")
  why |> string.contains("calls ffi.write") |> should.be_true()
  graded.run_effect(root, "m.logs")
  |> should.equal(Ok(
    "effects m.logs : [Disk]\n// resolved from in-memory inference",
  ))
  graded.run_effect_from_project(root, "m.logs")
  |> should.equal(Ok(
    "effects m.logs : [Disk]\n// resolved from in-memory inference",
  ))
  support.cleanup(root)
}

pub fn a_committed_line_beside_a_stale_external_is_dropped_too_test() {
  // The same spec with a committed `effects m.logs : []` line beside the stale
  // external — a pair no `infer` ever writes, so the spec's state for the name
  // is not one to trust. The committed term used to survive the external's
  // rejection and outrank the fresh walk, so a cross-module caller and the
  // query read `[]` from the spec while the warning promised the body was
  // walked instead.
  let root = "build/stale_external_committed"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume m.logs : []
assume ffi.write : [Disk]
effects m.logs : []
check caller.go : []
",
    ),
    #(
      "ffi.gleam",
      "@target(erlang)
@external(erlang, \"proj_ffi\", \"write\")
pub fn write() -> Nil
",
    ),
    #("m.gleam", "import ffi\n\npub fn logs() -> Nil {\n  ffi.write()\n}\n"),
    #("caller.gleam", "import m\n\npub fn go() -> Nil {\n  m.logs()\n}\n"),
  ])

  let assert Ok(results) = graded.check_project(root)
  let assert Ok(caller) =
    list.find(results, fn(r) { r.file == root <> "/caller.gleam" })
  let assert [call] = caller.violations
  call.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  graded.run_effect(root, "m.logs")
  |> should.equal(Ok(
    "effects m.logs : [Disk]\n// resolved from in-memory inference",
  ))
  support.cleanup(root)
}

pub fn a_stale_project_external_warns_once_test() {
  let root = "build/stale_external_warning"
  stale_external_project(root)

  let assert Ok(results) = graded.check_project(root)
  results
  |> list.flat_map(fn(r) { r.warnings })
  |> should.equal([types.StaleFunctionAssumeWarning(function: "m.logs")])
  support.cleanup(root)
}

pub fn infer_repairs_a_stale_project_external_test() {
  // The warning would otherwise recur forever while the spec kept
  // under-reporting the function, so `infer` deletes the line and writes the
  // `effects` line it was suppressing.
  let root = "build/stale_external_infer"
  stale_external_project(root)

  let assert Ok(preview) = graded.run_infer_command(cli.DryRun, root)
  let changed =
    preview
    |> string.split("\n")
    |> list.filter(fn(line) {
      string.starts_with(line, "- ") || string.starts_with(line, "+ ")
    })
  changed |> list.contains("- assume m.logs : []") |> should.be_true()
  changed |> list.contains("+ effects m.logs : [Disk]") |> should.be_true()
  support.cleanup(root)
}

pub fn a_dependency_external_over_a_visible_body_is_untouched_test() {
  // Declaring a dependency function is what the line is for, and dependency
  // sources are scanned, so "has a body" is knowable there too — a rule phrased
  // as "has a body" rather than "is one of this package's" would break every
  // legitimate use.
  let root = "build/stale_external_dependency"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "assume dep/io.writes : []\ncheck app.go : []\n"),
    #(
      "build/packages/dep/src/dep/io.gleam",
      "pub fn writes() -> Nil {\n  Nil\n}\n",
    ),
    #(
      "app.gleam",
      "import dep/io as dep_io\n\npub fn go() -> Nil {\n  dep_io.writes()\n}\n",
    ),
  ])

  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.warnings }) |> should.equal([])
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])
  support.cleanup(root)
}

pub fn a_module_level_external_over_a_project_module_is_untouched_test() {
  // The module-level form is the one that governs your own code, and it stays
  // authoritative: no warning, and the declaration answers for every function.
  let root = "build/module_external_project"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "assume m : [Disk]\ncheck m.logs : []\n"),
    #("m.gleam", "pub fn logs() -> Nil {\n  Nil\n}\n"),
  ])

  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.warnings }) |> should.equal([])
  let assert Ok(r) = list.find(results, fn(r) { r.file == root <> "/m.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
  support.cleanup(root)
}

pub fn a_module_level_external_does_not_excuse_a_visible_body_test() {
  // The line answers for every *caller* of `logs`, and a caller is charged
  // `[Disk]` and nothing else. `logs`'s own budget is another question: the body
  // is visible Gleam that runs, so a `check` line on it weighs what the body
  // does beside what the line declares. Trusting the line alone let a body
  // demonstrably over its budget report nothing at all — while the per-function
  // form over the same body is already rejected as declaring nothing.
  let root = "build/module_external_visible_body"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume m : [Disk]
assume loud.shout : [Stdout]
check m.logs : [Disk]
",
    ),
    #(
      "m.gleam",
      "import loud

pub fn logs() -> Nil {
  loud.shout()
}
",
    ),
    #(
      "loud.gleam",
      "@external(erlang, \"l\", \"s\")
@external(javascript, \"l\", \"s\")
pub fn shout() -> Nil
",
    ),
  ])

  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) = list.find(results, fn(r) { r.file == root <> "/m.gleam" })
  let assert [violation] = r.violations
  violation.function |> should.equal("logs")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
  support.cleanup(root)
}

pub fn a_catalogued_modules_uncatalogued_function_is_not_flagged_test() {
  // The catalog keys some of `gleam/erlang/process`'s functions and not
  // `subject_owner`. With that package's own sources not installed, nothing can
  // prove the name absent — but the per-function tier weighed only the exact
  // catalog key and the module-level one, so it called a real function a typo.
  // The module tier has consulted the per-function-derived module set all
  // along; both tiers now do.
  let root = "build/external_lint_catalog_function_module"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "manifest.toml",
      "packages = [\n  { name = \"gleam_erlang\", version = \"0.34.0\" },\n]\n",
    ),
    #("proj.graded", "assume gleam/erlang/process.subject_owner : [Process]\n"),
    // The package is installed — the tree is complete — but this module is not
    // among what it ships here, so only the catalog speaks for the name.
    #(
      "build/packages/gleam_erlang/src/gleam/erlang.gleam",
      "pub fn go() -> Nil {\n  Nil\n}\n",
    ),
    #("m.gleam", "pub fn go() -> Nil {\n  Nil\n}\n"),
  ])
  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.warnings }) |> should.equal([])
  support.cleanup(root)
}

pub fn a_missing_packages_tree_silences_only_what_it_hides_test() {
  // A fresh clone before `gleam deps download`: the manifest lists packages
  // whose sources are nowhere on disk. Every dependency line was flagged as a
  // typo, because "not found" was read as proof of absence over a tree that had
  // read almost nothing. Project modules were parsed either way, so what they
  // settle is settled.
  let root = "build/external_lint_no_packages"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "manifest.toml",
      "packages = [\n  { name = \"dep\", version = \"1.0.0\" },\n]\n",
    ),
    #(
      "proj.graded",
      "assume dep/io.writes : [Disk]
assume dep/io : [Disk]
assume m.no_such : []
assume m.go : []
",
    ),
    #("m.gleam", "pub fn go() -> Nil {\n  Nil\n}\n"),
  ])
  let assert Ok(results) = graded.check_project(root)
  // The dependency lines are silent; the project ones are unchanged — `m` was
  // parsed, so it defines what it defines, and `m.go`'s Gleam body is right
  // there for the stale lint to name.
  results
  |> list.flat_map(fn(r) { r.warnings })
  |> should.equal([
    types.UnmatchedFunctionAssumeWarning(function: "m.no_such"),
    types.StaleFunctionAssumeWarning(function: "m.go"),
  ])
  support.cleanup(root)
}

pub fn a_partial_packages_tree_still_flags_what_it_can_prove_test() {
  // Two manifest packages, one installed. A module of the *missing* one cannot
  // be disproved — it may be exactly what is not on disk — while a name the
  // installed package's own parsed source plainly lacks is dead whatever else
  // is missing.
  let root = "build/external_lint_partial_packages"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "manifest.toml",
      "packages = [\n  { name = \"here\", version = \"1.0.0\" },\n  { name = \"absent\", version = \"1.0.0\" },\n]\n",
    ),
    #(
      "proj.graded",
      "assume absent/thing.whatever : [Disk]
assume absent/thing : [Disk]
assume here/io.writes : [Disk]
assume here/io.typo : [Disk]
",
    ),
    #(
      "build/packages/here/src/here/io.gleam",
      "pub fn writes() -> Nil {\n  Nil\n}\n",
    ),
    #("m.gleam", "pub fn go() -> Nil {\n  Nil\n}\n"),
  ])
  let assert Ok(results) = graded.check_project(root)
  results
  |> list.flat_map(fn(r) { r.warnings })
  |> should.equal([
    types.UnmatchedFunctionAssumeWarning(function: "here/io.typo"),
  ])
  support.cleanup(root)
}

pub fn an_external_naming_nothing_is_flagged_test() {
  // Existence detection at both tiers. A line that resolves nowhere covers
  // nothing, so it is a typo rather than a budget — while the catalog- and
  // dependency-resolving lines beside it are left alone, which is the caveat
  // that keeps the lint from flagging what it cannot introspect.
  let root = "build/external_lint"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "manifest.toml",
      "packages = [\n  { name = \"gleam_stdlib\", version = \"0.70.0\" },\n  { name = \"dep\", version = \"1.0.0\" },\n]\n",
    ),
    #(
      "proj.graded",
      "assume m.no_such : []
assume nowhere/mod : []
assume gleam/io.println : [Stdout]
assume dep/io.writes : [Disk]
assume dep/io.typo : [Disk]
assume dep/io : [Disk]
",
    ),
    #(
      "build/packages/dep/src/dep/io.gleam",
      "pub fn writes() -> Nil {\n  Nil\n}\n",
    ),
    // Every manifest package yields sources, so a module the lint cannot place
    // really is nowhere. `gleam/io` itself is not among them — the catalog is
    // what answers for it.
    #(
      "build/packages/gleam_stdlib/src/gleam/list.gleam",
      "pub fn go() -> Nil {\n  Nil\n}\n",
    ),
    #("m.gleam", "pub fn go() -> Nil {\n  Nil\n}\n"),
  ])

  let assert Ok(results) = graded.check_project(root)
  results
  |> list.flat_map(fn(r) { r.warnings })
  |> should.equal([
    types.UnmatchedFunctionAssumeWarning(function: "m.no_such"),
    types.UnmatchedModuleAssumeWarning(module: "nowhere/mod"),
    // `dep/io` is a real dependency module, but it defines `writes` and not
    // `typo`. The module tier would have waved the misspelling through.
    types.UnmatchedFunctionAssumeWarning(function: "dep/io.typo"),
  ])
  support.cleanup(root)
}

pub fn a_parsed_dependency_source_outranks_the_catalog_in_the_lint_test() {
  // `gleam/list` is catalogued module-level, which answers for every name in
  // the module wherever no source says otherwise — but here the dependency's
  // source is installed and parses, and it proves `typo` does not exist. The
  // catalog tier used to wave the misspelling through anyway; the source is
  // the installed version, so its answer is definitive both ways.
  let root = "build/external_lint_source_over_catalog"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "manifest.toml",
      "packages = [\n  { name = \"gleam_stdlib\", version = \"0.70.0\" },\n]\n",
    ),
    #(
      "proj.graded",
      "assume gleam/list.typo : []\nassume gleam/list.real_fn : []\n",
    ),
    #(
      "build/packages/gleam_stdlib/src/gleam/list.gleam",
      "pub fn real_fn() -> Nil {\n  Nil\n}\n",
    ),
    #("m.gleam", "pub fn go() -> Nil {\n  Nil\n}\n"),
  ])

  let assert Ok(results) = graded.check_project(root)
  results
  |> list.flat_map(fn(r) { r.warnings })
  |> should.equal([
    types.UnmatchedFunctionAssumeWarning(function: "gleam/list.typo"),
  ])
  support.cleanup(root)
}

pub fn an_external_on_an_unreadable_dependency_is_not_flagged_test() {
  // The function tier weighs a dependency by its source, so a module whose
  // source will not parse has to keep answering for every name: the lint flags
  // what it can prove dead, and a module it cannot read proves nothing.
  let root = "build/external_lint_unreadable_dep"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "assume broken/mod.whatever : [Disk]\n"),
    #("build/packages/broken/src/broken/mod.gleam", "pub fn ( not gleam\n"),
    #("m.gleam", "pub fn go() -> Nil {\n  Nil\n}\n"),
  ])

  let assert Ok(results) = graded.check_project(root)
  results |> list.flat_map(fn(r) { r.warnings }) |> should.equal([])
  support.cleanup(root)
}

pub fn a_stale_duplicate_dependency_copy_does_not_answer_for_a_name_test() {
  // Two copies of `dep/mod` are on disk: the path dependency the project
  // declares, and a hex copy left under `build/packages` by a `gleam clean`
  // that never ran. The path dependency is what this build compiles against and
  // it defines no `writes`, so the line is dead — the stale copy still defining
  // the name is no evidence about the source in use.
  let root = "build/external_lint_stale_dep_copy"
  support.write_fixture(root, [
    #(
      "proj/gleam.toml",
      "name = \"proj\"\n\n[dependencies]\ndep = { path = \"../dep\" }\n",
    ),
    #("proj/proj.graded", "assume dep/mod.writes : [Disk]\n"),
    #(
      "proj/build/packages/dep/src/dep/mod.gleam",
      "pub fn writes() -> Nil {\n  Nil\n}\n",
    ),
    #("proj/src/m.gleam", "pub fn go() -> Nil {\n  Nil\n}\n"),
    #("dep/gleam.toml", "name = \"dep\"\n"),
    #("dep/src/dep/mod.gleam", "pub fn reads() -> Nil {\n  Nil\n}\n"),
  ])

  let assert Ok(results) = graded.check_project(root <> "/proj")
  results
  |> list.flat_map(fn(r) { r.warnings })
  |> should.equal([
    types.UnmatchedFunctionAssumeWarning(function: "dep/mod.writes"),
  ])
  support.cleanup(root)
}

pub fn a_stale_copy_does_not_stand_in_for_an_unreadable_one_test() {
  // The mirror case: the copy this build compiles against will not parse, and
  // the stale one under `build/packages` does. A module graded cannot read
  // proves nothing about the names in it, and a copy it is not compiling
  // against cannot prove it either — so the line naming a function only the
  // unreadable copy defines is left alone.
  let root = "build/external_lint_stale_copy_unreadable"
  support.write_fixture(root, [
    #(
      "proj/gleam.toml",
      "name = \"proj\"\n\n[dependencies]\ndep = { path = \"../dep\" }\n",
    ),
    #("proj/proj.graded", "assume dep/mod.writes : [Disk]\n"),
    #(
      "proj/build/packages/dep/src/dep/mod.gleam",
      "pub fn reads() -> Nil {\n  Nil\n}\n",
    ),
    #("proj/src/m.gleam", "pub fn go() -> Nil {\n  Nil\n}\n"),
    #("dep/gleam.toml", "name = \"dep\"\n"),
    #("dep/src/dep/mod.gleam", "pub fn ( not gleam\n"),
  ])

  let assert Ok(results) = graded.check_project(root <> "/proj")
  results |> list.flat_map(fn(r) { r.warnings }) |> should.equal([])
  support.cleanup(root)
}

pub fn a_stale_duplicate_dependency_copy_declares_nothing_foreign_test() {
  // Every map the dependency scan derives is read off the copy this build
  // compiles against, not just the names it defines. A stale copy under
  // `build/packages` declaring a function `@external` cannot refuse the effects
  // the live copy's shipped spec states for it, since that copy runs Gleam.
  let root = "build/stale_dep_copy_foreign"
  support.write_fixture(root, [
    #(
      "proj/gleam.toml",
      "name = \"proj\"\n\n[dependencies]\ndep = { path = \"../dep\" }\n",
    ),
    #("proj/proj.graded", "check app.go : [Disk]\n"),
    #(
      "proj/src/app.gleam",
      "import dep/mod

pub fn go() -> Nil {
  mod.writes()
}
",
    ),
    #(
      "proj/build/packages/dep/src/dep/mod.gleam",
      "@external(erlang, \"dep_ffi\", \"writes\")
pub fn writes() -> Nil
",
    ),
    #("dep/gleam.toml", "name = \"dep\"\n"),
    #("dep/dep.graded", "effects dep/mod.writes : [Disk]\n"),
    #("dep/src/dep/mod.gleam", "pub fn writes() -> Nil {\n  Nil\n}\n"),
  ])

  let assert Ok(results) = graded.check_project(root <> "/proj")
  results |> list.flat_map(fn(r) { r.violations }) |> should.equal([])
  support.cleanup(root)
}

pub fn an_external_on_a_function_less_dependency_module_is_flagged_test() {
  // A dependency module that parses and defines no function at all — a
  // type-only module — proves the name absent just as a module full of other
  // functions does. Reading "defines nothing" as "said nothing" is how a module
  // graded read would come to answer for every name in it, which is the answer
  // reserved for one it could not read.
  let root = "build/external_lint_type_only_dep"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "assume types_only/mod.whatever : [Disk]\n"),
    #(
      "build/packages/types_only/src/types_only/mod.gleam",
      "pub type Handle {\n  Handle(id: Int)\n}\n",
    ),
    #("m.gleam", "pub fn go() -> Nil {\n  Nil\n}\n"),
  ])

  let assert Ok(results) = graded.check_project(root)
  results
  |> list.flat_map(fn(r) { r.warnings })
  |> should.equal([
    types.UnmatchedFunctionAssumeWarning(function: "types_only/mod.whatever"),
  ])
  support.cleanup(root)
}

// Reference warnings and foreign code
//
// The "passed as a value" warning quotes an effect, so it reads that effect
// through the same boundary a charge does. Otherwise it would report a
// reference as carrying effects no caller of the same name is charged.

pub fn a_reference_warning_never_quotes_a_stale_foreign_effect_test() {
  // A stale `effects` line for an `@external` — what a function that became one
  // leaves behind. Its callers are charged `[Unknown]`, so a reference to it
  // must not be reported as carrying the line's `[Disk]`. An unresolved
  // reference warns about nothing, as it already did.
  let root = "build/reference_warning_foreign"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "effects ffi.stale : [Disk]\nassume ffi.declared : [Disk]\ncheck app.go : [_]\ncheck app.declared_go : [_]\n",
    ),
    #(
      "ffi.gleam",
      "@target(erlang)
@external(erlang, \"proj_ffi\", \"stale\")
pub fn stale() -> Nil

@target(erlang)
@external(erlang, \"proj_ffi\", \"declared\")
pub fn declared() -> Nil
",
    ),
    #(
      "app.gleam",
      "import ffi

pub fn apply_callback(f: fn() -> Nil) -> Nil {
  f()
}

pub fn go() -> Nil {
  apply_callback(ffi.stale)
}

pub fn declared_go() -> Nil {
  apply_callback(ffi.declared)
}
",
    ),
  ])

  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  // Only the declared external is quoted, and it is quoted with what declares it.
  r.warnings
  |> list.map(fn(warning) {
    let assert types.UntrackedEffectWarning(function:, reference:, effects:, ..) =
      warning
    #(function, reference, effects)
  })
  |> should.equal([
    #(
      "declared_go",
      types.QualifiedName("ffi", "declared"),
      types.Specific(set.from_list(["Disk"])),
    ),
  ])
  support.cleanup(root)
}

pub fn an_undeclared_fallbacks_reference_warns_only_about_what_it_knows_test() {
  // An undeclared external with a running fallback resolves to that body's
  // effects unioned with `[Unknown]`, and that answer arrives as a resolved
  // lookup rather than as the unresolved variant. Reading the variant alone let
  // `quiet` — whose fallback does nothing, so the whole set is the widening —
  // warn that ``its effects [Unknown] won't be tracked``, quoting the one thing
  // an unresolved reference is supposed to stay silent about. `loud`'s set has a
  // known half, and that half is a real effect travelling past anything that
  // tracks it, so it still warns.
  let root = "build/reference_warning_undeclared_fallback"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ffi.disk : [Disk]
check ext.pass_quiet : [_]
check ext.pass_loud : [_]
",
    ),
    #(
      "ffi.gleam",
      "@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
pub fn disk() -> Nil
",
    ),
    #(
      "raw.gleam",
      "import ffi

@external(javascript, \"e\", \"q\")
pub fn quiet() -> Nil {
  Nil
}

@external(javascript, \"e\", \"l\")
pub fn loud() -> Nil {
  ffi.disk()
}
",
    ),
    #(
      "ext.gleam",
      "import raw

fn helper(f: fn() -> Nil) -> Nil {
  f()
}

pub fn pass_quiet() -> Nil {
  helper(raw.quiet)
}

pub fn pass_loud() -> Nil {
  helper(raw.loud)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  r.warnings
  |> list.map(fn(warning) {
    let assert types.UntrackedEffectWarning(function:, reference:, effects:, ..) =
      warning
    #(function, reference, effects)
  })
  |> should.equal([
    #(
      "pass_loud",
      types.QualifiedName("raw", "loud"),
      types.Specific(set.from_list(["Disk", "Unknown"])),
    ),
  ])
  support.cleanup(root)
}

pub fn a_reference_warning_quotes_only_the_half_in_reach_test() {
  // A reference sits in a body that runs on Erlang alone, so the two externals it
  // passes read there and nowhere else. `js_only`'s declaration is for
  // JavaScript, so what runs here is its Gleam body and the warning quotes
  // exactly that body's `[Disk]`. `erlang_only`'s declaration covers Erlang, so
  // nothing declares what runs and the reference carries the `[Unknown]` a
  // warning stays silent about — its Gleam body runs on the target this one
  // never reaches. Quoting both halves regardless announced a `[Disk]` no
  // implementation in reach performs, and paired it with an `[Unknown]` the walk
  // does not charge.
  let root = "build/reference_warning_half_in_reach"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ffi.disk : [Disk]
check ext.pass_js_only : [_]
check ext.pass_erlang_only : [_]
",
    ),
    #(
      "ffi.gleam",
      "@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
pub fn disk() -> Nil
",
    ),
    #(
      "raw.gleam",
      "import ffi

@external(javascript, \"e\", \"j\")
pub fn js_only() -> Nil {
  ffi.disk()
}

@external(erlang, \"e\", \"e\")
pub fn erlang_only() -> Nil {
  ffi.disk()
}
",
    ),
    #(
      "ext.gleam",
      "import raw

fn helper(f: fn() -> Nil) -> Nil {
  f()
}

@target(erlang)
pub fn pass_js_only() -> Nil {
  helper(raw.js_only)
}

@target(erlang)
pub fn pass_erlang_only() -> Nil {
  helper(raw.erlang_only)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  r.warnings
  |> list.map(fn(warning) {
    let assert types.UntrackedEffectWarning(function:, reference:, effects:, ..) =
      warning
    #(function, reference, effects)
  })
  |> should.equal([
    #(
      "pass_js_only",
      types.QualifiedName("raw", "js_only"),
      types.Specific(set.from_list(["Disk"])),
    ),
  ])
  support.cleanup(root)
}

pub fn a_governed_native_body_still_warns_about_its_references_test() {
  // The opposite case to the covered `@external` below, and the distinction the
  // warning turns on. `assume governed : [Net]` answers for every
  // *caller* of the module's functions, but these bodies are ordinary Gleam
  // that runs: a `check` line on one is judged against the declaration and the
  // body alike, and the effectful reference one passes is as untracked as it
  // would be anywhere else — the reference is handed to code the declaration
  // speaks for, which is exactly what a warning is for.
  let root = "build/reference_warning_governed_module"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ffi.disk : [Disk]
assume governed : [Net]
check governed.wrapped : [Disk, Net]
check governed.strict : []
",
    ),
    #(
      "ffi.gleam",
      "@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
pub fn disk() -> Nil
",
    ),
    #(
      "governed.gleam",
      "import ffi

fn helper(f: fn() -> Nil) -> Nil {
  f()
}

pub fn wrapped() -> Nil {
  helper(ffi.disk)
}

pub fn strict() -> Nil {
  helper(ffi.disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/governed.gleam" })

  // A budget covers both halves: the declaration, and the visible body beside
  // it. Both bodies call `helper`, a sibling the same line governs — and that
  // line states `helper`'s own effects, not what it does with the callback it
  // is handed, so a caller pays the `[Net]` plus the `[Disk]` reference it
  // passes. `strict` breaks its `[]` on the declaration half and on the call;
  // `wrapped` meets a budget stating both.
  r.violations
  |> list.map(fn(violation) {
    let assert types.Specific(effects) = violation.explanation.actual
    violation.function
    <> ": "
    <> string.join(set.to_list(effects) |> list.sort(string.compare), ",")
  })
  |> list.sort(string.compare)
  |> should.equal(["strict: Disk,Net", "strict: Net"])

  // Both bodies still pass the reference, so both warn.
  r.warnings
  |> list.map(fn(warning) {
    let assert types.UntrackedEffectWarning(function:, reference:, effects:, ..) =
      warning
    #(function, reference, effects)
  })
  |> should.equal([
    #(
      "strict",
      types.QualifiedName("ffi", "disk"),
      types.Specific(set.from_list(["Disk"])),
    ),
    #(
      "wrapped",
      types.QualifiedName("ffi", "disk"),
      types.Specific(set.from_list(["Disk"])),
    ),
  ])
  support.cleanup(root)
}

pub fn a_covered_fallback_body_reference_warns_about_nothing_test() {
  // `covered` declares an implementation for every target it compiles for, so
  // its Gleam body is dead text the declaration alone answers for — the `disk`
  // reference in it is never passed anywhere, and a warning would quote an
  // effect no run of the function performs. `running` declares javascript
  // only, so the same body is what runs on erlang and its reference still
  // warns.
  let root = "build/reference_warning_dead_fallback"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ffi.disk : [Disk]
assume ext.covered : []
assume ext.running : []
check ext.covered : []
check ext.running : [_]
",
    ),
    #(
      "ffi.gleam",
      "@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
pub fn disk() -> Nil
",
    ),
    #(
      "ext.gleam",
      "import ffi

fn helper(f: fn() -> Nil) -> Nil {
  f()
}

@external(erlang, \"e\", \"c\")
@external(javascript, \"e\", \"c\")
pub fn covered() -> Nil {
  helper(ffi.disk)
}

@external(javascript, \"e\", \"r\")
pub fn running() -> Nil {
  helper(ffi.disk)
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/ext.gleam" })
  r.warnings
  |> list.map(fn(warning) {
    let assert types.UntrackedEffectWarning(function:, reference:, effects:, ..) =
      warning
    #(function, reference, effects)
  })
  |> should.equal([
    #(
      "running",
      types.QualifiedName("ffi", "disk"),
      types.Specific(set.from_list(["Disk"])),
    ),
  ])
  support.cleanup(root)
}

// Tier precedence on the returns channel
//
// Which spec's line answers for a name when several key it. Four rules, one per
// collision the channel can hold: a spec states summaries only about code it
// ships, the consumer's declaration is in reach while a path dependency is
// inferred, an installed dependency outranks a path dependency, and a
// declaration outranks an inferred summary across packages as well as within
// one.

pub fn a_dependency_cannot_declare_a_return_for_the_consumers_code_test() {
  // The dep's spec names `lib.make` — an ordinary Gleam function of the
  // *consumer*, whose body every caller can already see. Loaded, it would sit in
  // a tier above the summary this run infers from that body and answer [Net] for
  // a closure that prints. A spec speaks for the modules its package ships and
  // for the names a foreign scan records; `lib` is neither.
  let root = "build/declared_returns_dep_over_consumer"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "check app.caller : []
assume lib.write : [Stdout]
",
    ),
    #(
      "build/packages/dep/dep.graded",
      "assume lib.make where returns : [Net]\n",
    ),
    #(
      "build/packages/dep/src/dep.gleam",
      "pub fn nothing() -> Nil {\n  Nil\n}\n",
    ),
    #(
      "lib.gleam",
      "@external(erlang, \"lib_ffi\", \"write\")
@external(javascript, \"lib_ffi\", \"write\")
pub fn write() -> Nil

pub fn make() -> fn() -> Nil {
  fn() { write() }
}
",
    ),
    #(
      "app.gleam",
      "import lib

pub fn caller() -> Nil {
  let handle = lib.make()
  handle()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
  support.cleanup(root)
}

pub fn a_declaration_governs_a_spec_less_path_deps_inference_test() {
  // The path dependency ships no spec, so its bodies are summarized from source
  // during this run — and the body being summarized calls the closure its own
  // `@external` hands back. Both consumer declarations have to be in reach while
  // that pass runs, not merely afterwards: the `assume` line so the
  // producer call is charged, the `external returns` line so the closure call is.
  // Folded after it, the helper is settled at [Unknown] and the consumer reads
  // that instead.
  let r =
    run_path_dep_project(
      "declared_returns_path_dep_inference",
      [
        #(
          "ffi.gleam",
          "@external(erlang, \"dep_ffi\", \"make\")
@external(javascript, \"dep_ffi\", \"make\")
pub fn make() -> fn() -> Nil
",
        ),
        #(
          "helper.gleam",
          "import ffi

pub fn use_it() -> Nil {
  let handle = ffi.make()
  handle()
}
",
        ),
      ],
      None,
      "check app.wrapper : []
assume ffi.make : []
assume ffi.make where returns : [Disk]
",
      "import helper

pub fn wrapper() -> Nil {
  helper.use_it()
}
",
    )
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

pub fn an_installed_dependencys_declaration_outranks_a_path_deps_test() {
  // The same package reached twice — installed under `build/packages` and
  // declared as a path dependency — with the two copies' specs declaring
  // different returns for the same producer. Dependency specs rank above path
  // dependencies, so the installed copy's [Stdout] is the answer; the path-dep
  // fold gap-fills rather than writing over the tier above it.
  let app_root = "build/declared_returns_dep_over_path_dep_app"
  let dep_root = "build/declared_returns_dep_over_path_dep_dep"
  let producer =
    "@external(erlang, \"dep_ffi\", \"make\")
@external(javascript, \"dep_ffi\", \"make\")
pub fn make() -> fn() -> Nil
"
  support.write_fixture(dep_root, [
    #("gleam.toml", "name = \"dep\"\n"),
    #("src/dep/ffi.gleam", producer),
    #(
      "dep.graded",
      "assume dep/ffi.make : []
assume dep/ffi.make where returns : [Net]
",
    ),
  ])
  support.write_fixture(app_root, [
    #(
      "gleam.toml",
      "name = \"app\"\n\n[dependencies]\ndep = { path = \"../declared_returns_dep_over_path_dep_dep\" }\n",
    ),
    #("app.graded", "check app.wrapper : []\n"),
    #("build/packages/dep/src/dep/ffi.gleam", producer),
    #(
      "build/packages/dep/dep.graded",
      "assume dep/ffi.make : []
assume dep/ffi.make where returns : [Stdout]
",
    ),
    #(
      "app.gleam",
      "import dep/ffi

pub fn wrapper() -> Nil {
  let handle = ffi.make()
  handle()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(app_root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == app_root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
  support.cleanup(app_root)
  support.cleanup(dep_root)
}

pub fn one_packages_returns_line_cannot_bury_anothers_declaration_test() {
  // `alib` declares what its own Gleam-bodied producer hands back — the
  // cross-package keep case — and `zlib`'s spec carries a stray inferred
  // `returns` line for the very same name. Whichever order the two specs are
  // folded in, the declaration is the one that answers: it is not zlib's code to
  // state a summary about, and declared outranks inferred across specs as it
  // does within one.
  let root = "build/declared_returns_cross_package_stray"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "check app.wrapper : []\n"),
    #(
      "build/packages/alib/alib.graded",
      "effects alib/mod.make : []
assume alib/mod.make where returns : [Stdout]
",
    ),
    #(
      "build/packages/alib/src/alib/mod.gleam",
      "pub fn make() -> fn() -> Nil {
  fn() { Nil }
}
",
    ),
    #(
      "build/packages/zlib/zlib.graded",
      "effects alib/mod.make : [] where returns : [Net]\n",
    ),
    #(
      "build/packages/zlib/src/zlib.gleam",
      "pub fn nothing() -> Nil {\n  Nil\n}\n",
    ),
    #(
      "app.gleam",
      "import alib/mod

pub fn wrapper() -> Nil {
  let handle = mod.make()
  handle()
}
",
    ),
  ])
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/app.gleam" })
  let assert [violation] = r.violations
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
  support.cleanup(root)
}

pub fn a_returns_clause_on_a_field_path_is_refused_test() {
  // `app.Handler.on_click` names a field, and a field annotation has no slot
  // for a returned operator. There is no line to warn about: the grammar
  // refuses it, naming the line.
  let root = "build/declared_returns_type_shaped"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "assume app.Handler.run where returns : [Net]\n"),
    #(
      "app.gleam",
      "pub type Handler {
  Handler(run: fn() -> Nil)
}
",
    ),
  ])
  graded.check_project(root)
  |> should.equal(
    Error(graded.GradedParseError(
      root <> "/proj.graded",
      annotation.describe_parse_error(annotation.InvalidLine(
        1,
        "assume app.Handler.run where returns : [Net]",
      )),
    )),
  )
  support.cleanup(root)
}

// Unparseable spec
//
// The check reads the spec's `check` lines and its declarations. A line the
// parser rejects stops it, naming the line — checking against a spec that was
// silently emptied passes everything.

pub fn check_over_an_unparseable_spec_errors_test() {
  let root = "/tmp/graded_check_unparseable"
  let _ = support.write_unparseable_spec_project(root)

  graded.check_project(root)
  |> should.equal(
    Error(graded.GradedParseError(
      root <> "/proj.graded",
      annotation.describe_parse_error(annotation.InvalidLine(
        2,
        "not a graded line",
      )),
    )),
  )
  support.cleanup(root)
}

// A `where returns` clause across a package boundary
//
// The clause a dependency ships is read back as a `Closed` summary, its
// variables checked against that dependency's real callback parameters before
// they are bound to the consumer's own argument.

// What the consumer's `h()` — the call of the closure `wrap` handed back — is
// charged, for a dependency whose spec states `clause` for `wrap`.
fn cross_package_clause_effects(
  name: String,
  clause: String,
) -> types.EffectSet {
  cross_package_clause_effects_over(
    name,
    clause,
    "pub fn wrap(f: fn() -> Nil) -> fn() -> Nil {
  fn() { f() }
}
",
  )
}

// The same, over a dependency `wrap` written as `dep_source` states it.
fn cross_package_clause_effects_over(
  name: String,
  clause: String,
  dep_source: String,
) -> types.EffectSet {
  let root =
    support.write_project_with_dependency(
      directory: "build/" <> name,
      package: "proj",
      spec: "check proj.caller : []\nassume proj.shout : [Stdout]\n",
      sources: [
        #(
          "proj.gleam",
          "import dep/wrap

@external(erlang, \"proj_ffi\", \"shout\")
pub fn shout() -> Nil

pub fn caller() -> Nil {
  let h = wrap.wrap(shout)
  h()
}
",
        ),
      ],
      dependency: "dep",
      dependency_spec: clause,
      dependency_sources: [#("dep/wrap.gleam", dep_source)],
    )
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(violation) =
    results
    |> list.flat_map(fn(result) { result.violations })
    |> list.find(fn(violation) {
      violation.explanation.call.module == "<returned>"
    })
  support.cleanup(root)
  violation.explanation.actual
}

pub fn a_dependencys_clause_binds_the_consumers_argument_test() {
  cross_package_clause_effects(
    "clause_cross_package",
    "effects dep/wrap.wrap(f: [f]) : [] where returns : [f]\n",
  )
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn a_dependencys_open_clause_degrades_to_unknown_test() {
  // `ghost` is no parameter of the dependency's `wrap`, so nothing binds it.
  cross_package_clause_effects(
    "clause_cross_package_open",
    "effects dep/wrap.wrap(f: [f]) : [] where returns : [ghost]\n",
  )
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

// An *unannotated* callback the dependency's spec records a bound for. No
// syntactic signature shows it, so the registry alone would call the clause
// open; the recorded bound is what admits it.
const unannotated_wrap = "pub fn wrap(f) {
  fn() { f() }
}
"

pub fn a_clause_over_a_recorded_bound_binds_test() {
  cross_package_clause_effects_over(
    "clause_recorded_bound",
    "effects dep/wrap.wrap(f: [f]) : [] where returns : [f]\n",
    unannotated_wrap,
  )
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn an_assume_kept_clause_still_binds_over_its_bounds_test() {
  // The line survives an assumption for the sake of its clause; the bounds that
  // scope the clause travel on the clause itself. Over `unannotated_wrap`
  // nothing else can prove `f` is a callback, so those bounds are the whole of
  // what admits the clause — dropped, the returned closure is [Unknown].
  cross_package_clause_effects_over(
    "clause_fn_assume_bounds",
    "assume dep/wrap.wrap : []\n"
      <> "effects dep/wrap.wrap(f: [f]) : [] where returns : [f]\n",
    unannotated_wrap,
  )
  |> should.equal(types.Specific(set.from_list(["Stdout"])))

  cross_package_clause_effects_over(
    "clause_module_assume_bounds",
    "assume dep/wrap : []\n"
      <> "effects dep/wrap.wrap(f: [f]) : [] where returns : [f]\n",
    unannotated_wrap,
  )
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

// The same shape one tier over: `dep` is a *path* dependency the consumer
// declares in `gleam.toml`, so its committed spec folds through
// `with_path_dep_spec` rather than the installed-package scan.
fn path_dep_clause_effects_over(
  name: String,
  dependency_spec: String,
  dep_source: String,
) -> types.EffectSet {
  path_dep_clause_effects_in(
    name,
    "dep/wrap",
    "wrap",
    no_installed_packages,
    dependency_spec,
    dep_source,
  )
}

// The same, over a path dependency shipping `module` — whose last segment
// qualifies the producer call. `manifest` is the consumer's `manifest.toml`:
// the catalog is selected per *installed* package, so it is what decides
// whether a catalogued module is in play at all.
fn path_dep_clause_effects_in(
  name: String,
  module: String,
  producer: String,
  manifest: String,
  dependency_spec: String,
  dep_source: String,
) -> types.EffectSet {
  let assert Ok(qualifier) = list.last(string.split(module, "/"))
  let root = "build/" <> name
  support.write_fixture(root, [
    #(
      "proj/gleam.toml",
      "name = \"proj\"\n\n[dependencies]\ndep = { path = \"../dep\" }\n",
    ),
    #("proj/manifest.toml", manifest),
    #(
      "proj/proj.graded",
      "check proj.caller : []\nassume proj.shout : [Stdout]\n",
    ),
    #("proj/proj.gleam", "import " <> module <> "

@external(erlang, \"proj_ffi\", \"shout\")
pub fn shout() -> Nil

pub fn caller() -> Nil {
  let h = " <> qualifier <> "." <> producer <> "(shout)
  h()
}
"),
    #("dep/gleam.toml", "name = \"dep\"\n"),
    #("dep/dep.graded", dependency_spec),
    #("dep/src/" <> module <> ".gleam", dep_source),
  ])
  let assert Ok(results) = graded.check_project(root <> "/proj")
  let assert Ok(violation) =
    results
    |> list.flat_map(fn(result) { result.violations })
    |> list.find(fn(violation) {
      violation.explanation.call.module == "<returned>"
    })
  support.cleanup(root)
  violation.explanation.actual
}

pub fn a_path_deps_assume_kept_clause_binds_over_its_bounds_test() {
  // The path-dependency tier of the same rule. Over `unannotated_wrap` the
  // bounds on the dep's kept line are the only thing that proves `f` is a
  // callback, and they reach this tier on the clause, so no merge here has to
  // pair them with anything.
  path_dep_clause_effects_over(
    "clause_path_dep_module_assume",
    "assume dep/wrap : []\n"
      <> "effects dep/wrap.wrap(f: [f]) : [] where returns : [f]\n",
    unannotated_wrap,
  )
  |> should.equal(types.Specific(set.from_list(["Stdout"])))

  path_dep_clause_effects_over(
    "clause_path_dep_fn_assume",
    "assume dep/wrap.wrap : []\n"
      <> "effects dep/wrap.wrap(f: [f]) : [] where returns : [f]\n",
    unannotated_wrap,
  )
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn a_vendored_forks_clause_binds_over_the_catalogued_name_test() {
  // A path dependency shipping a module the bundled catalog also covers — a
  // vendored fork of a catalogued package. The catalog's per-function `assume`
  // lines key the same names the fork's clause does, and the clause is read
  // against its own line either way.
  path_dep_clause_effects_in(
    "clause_path_dep_catalog_collision",
    "envoy",
    "get",
    envoy_installed,
    "assume envoy : []\n"
      <> "effects envoy.get(f: [f]) : [] where returns : [f]\n",
    unannotated_get,
  )
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

// A manifest naming a package the bundled catalog covers, and one naming none.
const envoy_installed = "packages = [
  { name = \"envoy\", version = \"1.0.0\" },
]
"

const no_installed_packages = "packages = []\n"

// `unannotated_wrap` under the name the catalog's `envoy` entry keys.
const unannotated_get = "pub fn get(f) {
  fn() { f() }
}
"

// A clause is weighed against its own line, not against the params channel
//
// The params channel is hand-editable and keyed by function name, so a bound
// recorded for `wrap` by one line says nothing about what a clause on another
// line of the same name scopes. Two `effects` lines for one name are what a
// hand edit leaves behind: the later one decides the bounds, the earlier one
// carries the clause.

const ghost_lines = "effects dep/wrap.wrap : [] where returns : [ghost]\n"
  <> "effects dep/wrap.wrap(ghost: [ghost]) : []\n"

// `ghost` is a real parameter of `wrap`, and a first-order one: passing it a
// function is what an argument matcher would bind, and being no callback is
// what the clause may not scope over.
const generic_wrap = "pub fn wrap(ghost: a) -> fn() -> Nil {
  fn() { Nil }
}
"

pub fn a_clause_over_a_bound_from_another_line_degrades_test() {
  cross_package_clause_effects_over(
    "clause_foreign_bound",
    ghost_lines,
    generic_wrap,
  )
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

pub fn a_clause_applying_an_unannotated_callback_degrades_test() {
  // Admission is not precision: the operator-parameter shapes are read off
  // annotations, so an unannotated callback binds to a flat first-order term
  // and an application of it stays stuck.
  cross_package_clause_effects_over(
    "clause_recorded_bound_applied",
    "effects dep/wrap.wrap(f: [f]) : [] where returns : fn(cb) -> [f([cb])]\n",
    unannotated_wrap,
  )
  |> should.equal(types.Specific(set.from_list(["Unknown"])))
}

// An assumption suppresses one channel, end to end
//
// A module-level assumption governs what its functions *do*. What one of them
// *returns* is a different claim, and the clause carrying it has no line of its
// own — so `infer` keeps the `effects` line alive to hold it, and the loaders
// read the declaration over that line's effects half only.

pub fn a_module_assume_keeps_the_clause_it_does_not_speak_for_test() {
  let root = "build/module_assume_keeps_clause"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume db : []
assume ffi.log : [Disk]
assume ffi.print : [Stdout]
check app.run : []
",
    ),
    #(
      "ffi.gleam",
      "@external(erlang, \"ffi_module\", \"log\")
@external(javascript, \"ffi_module\", \"log\")
pub fn log() -> Nil

@external(erlang, \"ffi_module\", \"print\")
@external(javascript, \"ffi_module\", \"print\")
pub fn print() -> Nil
",
    ),
    #(
      "db.gleam",
      "import ffi

pub fn make() -> fn() -> Nil {
  ffi.log()
  fn() { ffi.print() }
}
",
    ),
    #(
      "app.gleam",
      "import db

pub fn run() -> Nil {
  db.make()()
}
",
    ),
  ])

  // `infer` keeps the line: its effects half is redundant under the module
  // declaration, but the clause on it is the only record of what `make` returns.
  let assert Ok(Nil) = graded.run_infer(root)
  let assert Ok(spec) = simplifile.read(root <> "/proj.graded")
  spec
  |> string.contains("effects db.make : [Disk] where returns : [Stdout]")
  |> should.be_true()
  spec |> string.contains("assume db : []") |> should.be_true()

  // And re-inferring an unchanged package does not move it.
  graded.run_infer_dry_run(root) |> should.equal(Ok("graded: no changes"))

  // At check time the two channels answer from their own sources: `db.make`'s
  // own [Disk] is suppressed by the module declaration, while the closure it
  // returns still resolves to [Stdout] through the clause on the kept line.
  let assert Ok(results) = graded.check_project(root)
  let assert [violation] = list.flat_map(results, fn(r) { r.violations })
  violation.function |> should.equal("run")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
  // The deliberately-kept line is not reported as shadowing the declaration.
  results |> list.flat_map(fn(r) { r.warnings }) |> should.equal([])

  support.cleanup(root)
}

// The clause lint
//
// The lint reports an open clause against the oracle the gate binds by, so what
// it names is exactly what degrades to `[Unknown]`.

// The warnings a one-module project whose spec is `spec` and whose source is
// `source` collects.
fn clause_lint_warnings(
  name: String,
  spec: String,
  source: String,
) -> List(types.Warning) {
  let root = "build/" <> name
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", spec),
    #("proj.gleam", source),
  ])
  let assert Ok(results) = graded.check_project(root)
  let warnings = list.flat_map(results, fn(r) { r.warnings })
  support.cleanup(root)
  warnings
}

// A producer whose callback parameter every syntactic reader can see.
const annotated_wrap = "pub fn wrap(f: fn() -> Nil) -> fn() -> Nil {
  fn() { f() }
}
"

pub fn an_open_clause_on_an_effects_line_is_reported_test() {
  // Hand-edited: `infer` writes a bound for every variable its clause mentions,
  // so an `effects` clause is closed by construction.
  clause_lint_warnings(
    "clause_lint_open",
    "effects proj.wrap(f: [f]) : [] where returns : [ghost]\n",
    annotated_wrap,
  )
  |> should.equal([
    types.UnclosedReturnsClauseWarning(function: "proj.wrap", free_vars: [
      "ghost",
    ]),
  ])
}

pub fn a_closed_clause_on_an_effects_line_is_not_reported_test() {
  clause_lint_warnings(
    "clause_lint_closed",
    "effects proj.wrap(f: [f]) : [] where returns : [f]\n",
    annotated_wrap,
  )
  |> should.equal([])
}

pub fn an_open_clause_beside_a_bound_from_another_line_is_reported_test() {
  // The lint's half of what `a_clause_over_a_bound_from_another_line_degrades_test`
  // asserts through resolution. It weighs the clause against the line it sits
  // on, so the bound the second line records leaves it unmoved.
  clause_lint_warnings(
    "clause_lint_foreign_bound",
    "effects proj.wrap : [] where returns : [ghost]\n"
      <> "effects proj.wrap(ghost: [ghost]) : []\n",
    generic_wrap,
  )
  |> should.equal([
    types.UnclosedReturnsClauseWarning(function: "proj.wrap", free_vars: [
      "ghost",
    ]),
  ])
}

pub fn an_open_clause_on_a_check_line_is_reported_test() {
  // A `check` line's clause is weighed now, so it earns the same diagnostics
  // every other live clause does: `ghost` names no callback parameter, so
  // nothing in the comparison can bind it.
  clause_lint_warnings(
    "clause_lint_check_open",
    "check proj.wrap(f: [f]) : [] where returns : [ghost]\n",
    annotated_wrap,
  )
  |> should.equal([
    types.UnclosedReturnsClauseWarning(function: "proj.wrap", free_vars: [
      "ghost",
    ]),
  ])
}

pub fn an_aliased_bound_on_a_check_line_is_reported_test() {
  // The term channel binds by payload and the clause channel by name, so a
  // payload naming a *different* bound's parameter charges two different
  // arguments on one line. A `check` line carries both channels now.
  clause_lint_warnings(
    "clause_lint_check_aliased",
    "check proj.pair(g: [g], f: [g]) : [g] where returns : [g]\n",
    "pub fn pair(f: fn() -> Nil, g: fn() -> Nil) -> fn() -> Nil {
  f()
  fn() { g() }
}
",
  )
  |> should.equal([
    types.AliasedBoundVariableWarning(function: "proj.pair", variables: [
      #("g", "f"),
    ]),
  ])
}

pub fn a_field_check_carrying_a_bound_list_is_reported_test() {
  clause_lint_warnings(
    "clause_lint_field_bounds",
    "check proj.Handler.run(cb: [cb]) : [cb]\n",
    handler_type,
  )
  |> should.equal([
    types.UnsupportedFieldCheckWarning(name: "proj.Handler.run", components: [
      types.FieldBoundList,
    ]),
  ])
}

pub fn a_field_check_carrying_a_clause_is_reported_test() {
  clause_lint_warnings(
    "clause_lint_field_clause",
    "check proj.Handler.run : [] where returns : [Http]\n",
    handler_type,
  )
  |> should.equal([
    types.UnsupportedFieldCheckWarning(name: "proj.Handler.run", components: [
      types.FieldReturnsClause,
    ]),
  ])
}

pub fn a_field_check_carrying_both_is_reported_once_test() {
  clause_lint_warnings(
    "clause_lint_field_both",
    "check proj.Handler.run(cb: [cb]) : [cb] where returns : [Http]\n",
    handler_type,
  )
  |> should.equal([
    types.UnsupportedFieldCheckWarning(name: "proj.Handler.run", components: [
      types.FieldBoundList,
      types.FieldReturnsClause,
    ]),
  ])
}

// A custom type with one callable field, for the field-shaped lints.
const handler_type = "pub type Handler {
  Handler(run: fn() -> Nil)
}

pub fn build(run: fn() -> Nil) -> Handler {
  Handler(run:)
}
"

// A verified `check` on a record field
//
// A field `check` is package-wide: a type's construction sites are wherever
// the package builds it, and each is weighed against the field's budget. What
// it proves is this package's own sites — a public constructor or factory can
// be called from outside, and no package-local pass sees those calls.

// The lines a spec's field `check` earns against one module.
fn field_check_lines(name: String, spec: String, source: String) -> Reported {
  let root = "build/" <> name
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", spec),
    #(
      "ffi.gleam",
      "@external(erlang, \"ffi_module\", \"print\")
@external(javascript, \"ffi_module\", \"print\")
pub fn print() -> Nil
",
    ),
    #("proj.gleam", source),
  ])
  let assert Ok(reports) = graded.run(root)
  let reported =
    Reported(
      violations: list.flat_map(reports, fn(r) { r.violations }),
      warnings: list.flat_map(reports, fn(r) { r.warnings }),
    )
  support.cleanup(root)
  reported
}

type Reported {
  Reported(violations: List(String), warnings: List(String))
}

const pure_budget = "assume ffi.print : [Stdout]\ncheck proj.Handler.run : []\n"

const handler_sites = "import ffi

pub type Handler {
  Handler(run: fn() -> Nil)
}

fn quiet() -> Nil {
  Nil
}

fn loud() -> Nil {
  ffi.print()
}

pub fn wired_pure() -> Handler {
  Handler(run: quiet)
}

pub fn wired_closure() -> Handler {
  Handler(run: fn() { Nil })
}
"

pub fn a_site_wiring_a_pure_function_passes_test() {
  field_check_lines("field_check_pure", pure_budget, handler_sites).violations
  |> should.equal([])
}

pub fn a_site_wiring_an_impure_function_violates_test() {
  field_check_lines("field_check_impure", pure_budget, handler_sites <> "
pub fn wired_loud() -> Handler {
  Handler(run: loud)
}
").violations
  |> should.equal([
    "build/field_check_impure/proj.gleam: wired_loud wires proj.Handler.run with effects [Stdout] but the field is declared []",
  ])
}

pub fn a_site_wiring_an_impure_closure_violates_test() {
  field_check_lines("field_check_closure", pure_budget, handler_sites <> "
pub fn wired_loud_closure() -> Handler {
  Handler(run: fn() { ffi.print() })
}
").violations
  |> should.equal([
    "build/field_check_closure/proj.gleam: wired_loud_closure wires proj.Handler.run with effects [Stdout] but the field is declared []",
  ])
}

pub fn a_site_wiring_an_untraceable_value_is_unproved_test() {
  // The limit is graded's, so the line says what could not be proved and never
  // that the code violates anything — and still exits the run non-zero, which
  // is the whole point of it riding this channel.
  field_check_lines("field_check_opaque", pure_budget, handler_sites <> "
pub fn wired_opaque(chosen: List(fn() -> Nil)) -> Handler {
  let assert [first, ..] = chosen
  Handler(run: first)
}
").violations
  |> should.equal([
    "build/field_check_opaque/proj.gleam: could not prove check proj.Handler.run at wired_opaque — the value wired here does not resolve to a function graded can follow; an `assume` line is the trusted form for a field it cannot",
  ])
}

pub fn a_factory_is_proved_through_its_call_sites_test() {
  // D2: the factory wires the field from its own parameter, which resolves to
  // the polymorphic self marker. Reporting the factory itself would fail every
  // ordinary factory; the call sites are what wire a value.
  field_check_lines(
    "field_check_factory",
    pure_budget,
    "import ffi

pub type Handler {
  Handler(run: fn() -> Nil)
}

fn quiet() -> Nil {
  Nil
}

fn loud() -> Nil {
  ffi.print()
}

pub fn make(run: fn() -> Nil) -> Handler {
  Handler(run: run)
}

pub fn clean() -> Handler {
  make(quiet)
}

pub fn dirty() -> Handler {
  make(loud)
}
",
  ).violations
  |> should.equal([
    "build/field_check_factory/proj.gleam: dirty wires proj.Handler.run with effects [Stdout] but the field is declared []",
  ])
}

// The violations a two-module fixture earns, where the type is defined in one
// module and constructed in another. `field_check_lines`'s single source file
// cannot express the boundary these cross.
fn imported_field_check_violations(
  name: String,
  app_source: String,
) -> List(String) {
  let root = "build/" <> name
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ffi.print : [Stdout]\ncheck proj/handler.Handler.run : []\n",
    ),
    #(
      "ffi.gleam",
      "@external(erlang, \"ffi_module\", \"print\")
@external(javascript, \"ffi_module\", \"print\")
pub fn print() -> Nil
",
    ),
    #(
      "proj/handler.gleam",
      "pub type Handler {
  Handler(run: fn() -> Nil)
}
",
    ),
    #("proj/app.gleam", app_source),
  ])
  let assert Ok(reports) = graded.run(root)
  let violations = list.flat_map(reports, fn(r) { r.violations })
  support.cleanup(root)
  violations
}

pub fn a_positional_construction_of_an_imported_record_is_weighed_test() {
  // A record with labelled fields is constructed positionally as readily across
  // a module boundary as inside one. Read without the defining module's labels,
  // the unlabelled argument routed to no field: the construction wired nothing,
  // the site was never weighed, and the run passed with a warning that nothing
  // constructs the type.
  imported_field_check_violations(
    "field_check_imported_positional",
    "import ffi
import proj/handler

pub fn build() -> handler.Handler {
  handler.Handler(ffi.print)
}
",
  )
  |> should.equal([
    "build/field_check_imported_positional/proj/app.gleam: build wires proj/handler.Handler.run with effects [Stdout] but the field is declared []",
  ])
}

pub fn a_factory_constructing_an_imported_record_positionally_is_weighed_test() {
  // The same labels a direct construction routes through: a factory whose tail
  // constructs another module's record positionally wires the field from its own
  // parameter, so its call sites are weighed.
  imported_field_check_violations(
    "field_check_imported_positional_factory",
    "import ffi
import proj/handler

pub fn make(run: fn() -> Nil) -> handler.Handler {
  handler.Handler(run)
}

pub fn dirty() -> handler.Handler {
  make(ffi.print)
}
",
  )
  |> should.equal([
    "build/field_check_imported_positional_factory/proj/app.gleam: dirty wires proj/handler.Handler.run with effects [Stdout] but the field is declared []",
  ])
}

pub fn a_binding_shadowing_a_factory_is_not_a_call_of_it_test() {
  // A parameter named like the factory is a call of that parameter, and the
  // package's own precedence reads an unqualified call the same way. Matched by
  // name, `unrelated` was reported as wiring a field it never touches — while
  // the real call site below is still weighed.
  field_check_lines(
    "field_check_shadowed_factory",
    pure_budget,
    "import ffi

pub type Handler {
  Handler(run: fn() -> Nil)
}

pub fn make(run: fn() -> Nil) -> Handler {
  Handler(run: run)
}

pub fn unrelated(make: fn(fn() -> Nil) -> Nil) -> Nil {
  make(ffi.print)
}

pub fn dirty() -> Handler {
  make(ffi.print)
}
",
  ).violations
  |> should.equal([
    "build/field_check_shadowed_factory/proj.gleam: dirty wires proj.Handler.run with effects [Stdout] but the field is declared []",
  ])
}

pub fn a_site_no_build_compiles_is_not_weighed_test() {
  // `@target(javascript)` in an Erlang-only package: the body is built by no
  // build of it, and the effects channel says so — `infer` writes the function
  // as pure and a `check` on it passes. The field pass walked every function
  // whatever its targets, so it alone charged a site to code that does not
  // exist. The live site beside it is still weighed.
  let root = "build/field_check_dead_target"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\ntarget = \"erlang\"\n"),
    #(
      "proj.graded",
      "assume ffi.print : [Stdout]\ncheck proj.Handler.run : []\n",
    ),
    #(
      "ffi.gleam",
      "@external(erlang, \"ffi_module\", \"print\")
@external(javascript, \"ffi_module\", \"print\")
pub fn print() -> Nil
",
    ),
    #(
      "proj.gleam",
      "import ffi

pub type Handler {
  Handler(run: fn() -> Nil)
}

@target(javascript)
pub fn dead_js() -> Handler {
  Handler(run: ffi.print)
}

pub fn live_dirty() -> Handler {
  Handler(run: ffi.print)
}
",
    ),
  ])
  let assert Ok(reports) = graded.run(root)
  reports
  |> list.flat_map(fn(r) { r.violations })
  |> should.equal([
    "build/field_check_dead_target/proj.gleam: live_dirty wires proj.Handler.run with effects [Stdout] but the field is declared []",
  ])
  support.cleanup(root)
}

pub fn a_site_in_a_defaulted_target_body_is_still_weighed_test() {
  // The other half of the same reading: the package names no target, so a
  // `--target` graded never sees may compile this body. Dropping it on the
  // narrow reading would lose a real site.
  let root = "build/field_check_defaulted_target"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ffi.print : [Stdout]\ncheck proj.Handler.run : []\n",
    ),
    #(
      "ffi.gleam",
      "@external(erlang, \"ffi_module\", \"print\")
@external(javascript, \"ffi_module\", \"print\")
pub fn print() -> Nil
",
    ),
    #(
      "proj.gleam",
      "import ffi

pub type Handler {
  Handler(run: fn() -> Nil)
}

@target(javascript)
pub fn maybe_built() -> Handler {
  Handler(run: ffi.print)
}
",
    ),
  ])
  let assert Ok(reports) = graded.run(root)
  reports
  |> list.flat_map(fn(r) { r.violations })
  |> should.equal([
    "build/field_check_defaulted_target/proj.gleam: maybe_built wires proj.Handler.run with effects [Stdout] but the field is declared []",
  ])
  support.cleanup(root)
}

pub fn a_site_is_weighed_on_the_targets_its_body_runs_on_test() {
  // The site wires a name whose only declaration is JavaScript's, in a body
  // built for Erlang alone — where that name is its Gleam fallback. Read
  // package-wide, the field pass charged the site an effect no build of this
  // body can perform, while `check proj.direct : []` on the same body reading
  // the same name passed: one name, two totals.
  let root = "build/field_check_site_targets"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext : [Disk]
check proj.Handler.run : []
check proj.direct : []
",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"b\")
pub fn b() -> Nil {
  Nil
}
",
    ),
    #(
      "proj.gleam",
      "import ext

pub type Handler {
  Handler(run: fn() -> Nil)
}

@target(erlang)
pub fn make() -> Handler {
  Handler(run: ext.b)
}

@target(erlang)
pub fn direct() -> Nil {
  ext.b()
}
",
    ),
  ])
  let assert Ok(reports) = graded.run(root)
  reports
  |> list.flat_map(fn(r) { r.violations })
  |> should.equal([])
  support.cleanup(root)
}

pub fn an_update_builder_writing_a_fixed_sibling_is_weighed_test() {
  // The builder wires the checked field from its own parameter and writes a
  // sibling from a fixed value. A builder that routes every field it writes is
  // what states an overlay, and reading that requirement here left the whole
  // builder invisible: the field pass reported that no call reaches it and
  // never weighed the argument this call passes.
  field_check_lines(
    "field_check_update_fixed_sibling",
    "assume ffi.print : [Stdout]\ncheck proj.Options.resolver : []\n",
    "import ffi

pub type Options {
  Options(resolver: fn() -> Nil, retries: Int)
}

fn quiet() -> Nil {
  Nil
}

pub fn base() -> Options {
  Options(resolver: quiet, retries: 0)
}

pub fn with_resolver(o: Options, resolver: fn() -> Nil) -> Options {
  Options(..o, resolver: resolver, retries: 3)
}

pub fn dirty() -> Options {
  with_resolver(base(), ffi.print)
}
",
  ).violations
  |> should.equal([
    "build/field_check_update_fixed_sibling/proj.gleam: dirty wires proj.Options.resolver with effects [Stdout] but the field is declared []",
  ])
}

pub fn a_factory_no_call_reaches_is_unproved_test() {
  field_check_lines(
    "field_check_uncalled",
    pure_budget,
    "pub type Handler {
  Handler(run: fn() -> Nil)
}

pub fn make(run: fn() -> Nil) -> Handler {
  Handler(run: run)
}
",
  ).violations
  |> should.equal([
    "build/field_check_uncalled/proj.gleam: could not prove check proj.Handler.run at make — the field is wired from a parameter of `proj.make`, and no call of it is visible in this package",
  ])
}

pub fn a_wired_bound_binds_the_parameter_it_names_test() {
  // The wired function is bounded on its callback alone (`handle(cb: [cb])`),
  // and that callback is its *second* parameter. Read as arity-aligned, the
  // bound landed on the leading `Int` and the callback grounded, reporting
  // `[Unknown]` for a site the declaration plainly covers. The impure site
  // below is still weighed against the same line.
  let source =
    "import ffi

pub type Handler {
  Handler(run: fn(Int, fn() -> Nil) -> Nil)
}

pub fn handle(n: Int, cb: fn() -> Nil) -> Nil {
  let _ = n
  cb()
}

pub fn loud(n: Int, cb: fn() -> Nil) -> Nil {
  let _ = n
  ffi.print()
  cb()
}
"
  field_check_lines(
    "field_check_bound_position",
    "check proj.Handler.run : fn(n, cb) -> [cb]\n",
    source <> "
pub fn wired() -> Handler {
  Handler(run: handle)
}
",
  ).violations
  |> should.equal([])

  field_check_lines(
    "field_check_bound_position_loud",
    "assume ffi.print : [Stdout]\ncheck proj.Handler.run : fn(n, cb) -> [cb]\n",
    source <> "
pub fn wired() -> Handler {
  Handler(run: loud)
}
",
  ).violations
  |> should.equal([
    "build/field_check_bound_position_loud/proj.gleam: wired wires proj.Handler.run with effects fn(p0, cb0) -> [Stdout, cb0] but the field is declared fn(n, cb) -> [cb]",
  ])
}

pub fn a_higher_order_field_meets_unknown_and_not_pure_test() {
  // D9: the binder the declaration leaves unconstrained is grounded before the
  // comparison, so `[Unknown]` covers a field that runs its callback and `[]`
  // does not.
  let source =
    "pub type Handler {
  Handler(run: fn(fn() -> Nil) -> Nil)
}

pub fn wired() -> Handler {
  Handler(run: fn(next) { next() })
}
"
  field_check_lines(
    "field_check_ho_unknown",
    "check proj.Handler.run : [Unknown]\n",
    source,
  ).violations
  |> should.equal([])

  field_check_lines(
    "field_check_ho_pure",
    "check proj.Handler.run : []\n",
    source,
  ).violations
  |> should.equal([
    "build/field_check_ho_pure/proj.gleam: wired wires proj.Handler.run with effects fn(next) -> [Unknown] but the field is declared []",
  ])
}

pub fn an_unproved_field_site_is_the_only_finding_and_still_fails_test() {
  // The exit contract: `graded check` prints "all checks passed" and exits
  // zero exactly when this list is empty, so an unproved-only spec has to
  // leave something in it.
  let reported =
    field_check_lines("field_check_exit", pure_budget, handler_sites <> "
pub fn wired_opaque(chosen: List(fn() -> Nil)) -> Handler {
  let assert [first, ..] = chosen
  Handler(run: first)
}
")
  reported.violations |> list.length() |> should.equal(1)
  let assert [line] = reported.violations
  string.contains(line, "could not prove") |> should.be_true
}

pub fn a_heterogeneous_factory_selects_its_own_variants_signature_test() {
  // The factory builds one variant of a type whose other variant gives the
  // label a different arity. Measured against the sibling's signature the
  // canonicalized site would carry the wrong number of binders.
  field_check_lines(
    "field_check_variant_factory",
    pure_budget,
    "import ffi

pub type Handler {
  Simple(run: fn() -> Nil)
  Detailed(run: fn(String, Int) -> Nil)
}

pub fn detail(run: fn(String, Int) -> Nil) -> Handler {
  Detailed(run: run)
}

fn shout(_msg: String, _n: Int) -> Nil {
  ffi.print()
}

pub fn built() -> Handler {
  detail(shout)
}
",
  ).violations
  |> should.equal([
    "build/field_check_variant_factory/proj.gleam: built wires proj.Handler.run with effects fn(_, _) -> [Stdout] but the field is declared []",
  ])
}

pub fn a_heterogeneous_type_measures_each_site_by_its_variant_test() {
  // One label, two variants, two arities. A ground budget is well-defined at
  // every arity, so both sites are weighed against the same line.
  field_check_lines(
    "field_check_variants",
    pure_budget,
    "import ffi

pub type Handler {
  Simple(run: fn() -> Nil)
  Detailed(run: fn(String, Int) -> Nil)
}

pub fn simple() -> Handler {
  Simple(run: fn() { Nil })
}

pub fn detailed() -> Handler {
  Detailed(run: fn(_msg, _n) { ffi.print() })
}
",
  ).violations
  |> should.equal([
    "build/field_check_variants/proj.gleam: detailed wires proj.Handler.run with effects fn(_, _) -> [Stdout] but the field is declared []",
  ])
}

pub fn a_field_check_naming_no_field_warns_test() {
  field_check_lines(
    "field_check_typo",
    "check proj.Handler.nope : []\n",
    handler_sites,
  ).warnings
  |> should.equal([
    "build/field_check_typo/proj.graded: warning: check proj.Handler.nope names no field of any type this package can see — check the module qualifier; the check weighs no construction site",
  ])
}

pub fn a_field_check_on_a_non_callable_field_warns_test() {
  field_check_lines(
    "field_check_non_callable",
    "check proj.Handler.name : []\n",
    "pub type Handler {
  Handler(run: fn() -> Nil, name: String)
}

pub fn wired() -> Handler {
  Handler(run: fn() { Nil }, name: \"x\")
}
",
  ).warnings
  |> should.equal([
    "build/field_check_non_callable/proj.graded: warning: check proj.Handler.name names a field no variant makes callable — only a callable field carries an effect budget, so the check weighs nothing",
  ])
}

pub fn a_field_check_nothing_constructs_warns_test() {
  field_check_lines(
    "field_check_unconstructed",
    "check proj.Handler.run : []\n",
    "pub type Handler {
  Handler(run: fn() -> Nil)
}
",
  ).warnings
  |> should.equal([
    "build/field_check_unconstructed/proj.graded: warning: check proj.Handler.run names a callable field nothing in this package constructs a value of — the check holds over no site, and proves nothing. A construction outside the package is not one graded can see",
  ])
}

pub fn a_field_check_with_a_bound_list_fails_test() {
  // D10: a warning alone would exit zero and report "all checks passed" on a
  // line nothing proved, so the unsupported component reaches the reported
  // channel too.
  field_check_lines(
    "field_check_d10_bounds",
    "check proj.Handler.run(cb: [cb]) : [cb]\n",
    handler_sites,
  ).violations
  |> should.equal([
    "build/field_check_d10_bounds/proj.graded: could not prove check proj.Handler.run — a bound list on a field path is not verified, and the bounds are what scope the effects term, so the budget cannot be read without them",
  ])
}

pub fn a_field_check_with_a_clause_still_verifies_its_budget_test() {
  // The two halves are independent: the clause alone is refused, and the field
  // budget on the same line is weighed as usual.
  field_check_lines(
    "field_check_d10_clause",
    "assume ffi.print : [Stdout]
check proj.Handler.run : [] where returns : [Http]
",
    handler_sites <> "
pub fn wired_loud() -> Handler {
  Handler(run: loud)
}
",
  ).violations
  |> should.equal([
    "build/field_check_d10_clause/proj.graded: could not prove check proj.Handler.run — a `where returns` clause on a field path is not verified — nothing keys an operator returned by calling a field. The field budget on the same line still is",
    "build/field_check_d10_clause/proj.gleam: wired_loud wires proj.Handler.run with effects [Stdout] but the field is declared []",
  ])
}

pub fn a_verified_field_check_does_not_answer_a_field_call_test() {
  // D8: a `check` proves, it never answers. Were the budget read onto the
  // field-value channel, the consumer below would resolve `h.run()` as pure
  // and its own `[Stdout]` check would then be the one reporting.
  let reported =
    field_check_lines(
      "field_check_answers_nothing",
      "assume ffi.print : [Stdout]
check proj.Handler.run : [_]
check proj.consume : [Stdout]
check proj.consume_pure : []
",
      "import ffi

pub type Handler {
  Handler(run: fn() -> Nil)
}

fn loud() -> Nil {
  ffi.print()
}

pub fn build() -> Handler {
  Handler(run: loud)
}

pub fn consume() -> Nil {
  let h = build()
  h.run()
}

pub fn consume_pure() -> Nil {
  let h = build()
  h.run()
}
",
    )
  // `consume` resolves the field call to [Stdout] — the wired function's own
  // effect, not the `[_]` the check declares — so the `[Stdout]` budget holds
  // and the `[]` one does not.
  reported.violations
  |> list.filter(fn(line) { string.contains(line, "consume_pure") })
  |> list.length()
  |> should.equal(1)
  reported.violations
  |> list.filter(fn(line) { string.contains(line, ": consume ") })
  |> should.equal([])
}

pub fn a_scoped_run_does_not_report_an_out_of_scope_field_site_test() {
  // D1's counterpart to the effects half's scoping rule: the field pass is
  // package-wide so a site anywhere resolves, and its findings are still
  // narrowed to the subtree the caller asked about.
  let root = "build/field_check_scoped"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ffi.print : [Stdout]\ncheck proj/handler.Handler.run : []\n",
    ),
    #(
      "src/ffi.gleam",
      "@external(erlang, \"ffi_module\", \"print\")
@external(javascript, \"ffi_module\", \"print\")
pub fn print() -> Nil
",
    ),
    #(
      "src/proj/handler.gleam",
      "pub type Handler {
  Handler(run: fn() -> Nil)
}
",
    ),
    #(
      "src/sub/inner.gleam",
      "import proj/handler

pub fn inside() -> handler.Handler {
  handler.Handler(run: fn() { Nil })
}
",
    ),
    #(
      "src/outside.gleam",
      "import ffi
import proj/handler

pub fn out() -> handler.Handler {
  handler.Handler(run: fn() { ffi.print() })
}
",
    ),
  ])
  let assert Ok(whole) = graded.run(root)
  whole
  |> list.flat_map(fn(r) { r.violations })
  |> should.equal([
    "build/field_check_scoped/src/outside.gleam: out wires proj/handler.Handler.run with effects [Stdout] but the field is declared []",
  ])

  let assert Ok(scoped) = graded.run(root <> "/src/sub")
  scoped
  |> list.flat_map(fn(r) { r.violations })
  |> should.equal([])
  support.cleanup(root)
}

pub fn a_dependency_defined_field_is_weighed_at_the_project_site_test() {
  // D3′ and D9's collection step together: the type is the dependency's, so
  // its callable signature has to have reached the index through the
  // dependency scan — without the arity there is no comparison at all.
  let root = "build/field_check_dependency"
  support.write_project_with_dependency(
    directory: root,
    package: "proj",
    spec: "assume ffi.print : [Stdout]\ncheck dep/handler.Handler.run : []\n",
    sources: [
      #(
        "src/ffi.gleam",
        "@external(erlang, \"ffi_module\", \"print\")
@external(javascript, \"ffi_module\", \"print\")
pub fn print() -> Nil
",
      ),
      #(
        "src/proj.gleam",
        "import dep/handler
import ffi

pub fn direct() -> handler.Handler {
  handler.Handler(run: fn() { ffi.print() })
}

pub fn through_factory() -> handler.Handler {
  handler.make(fn() { ffi.print() })
}
",
      ),
    ],
    dependency: "dep",
    dependency_spec: "",
    dependency_sources: [
      #(
        "dep/handler.gleam",
        "pub type Handler {
  Handler(run: fn() -> Nil)
}

pub fn make(run: fn() -> Nil) -> Handler {
  Handler(run: run)
}
",
      ),
    ],
  )
  let assert Ok(reports) = graded.run(root)
  reports
  |> list.flat_map(fn(r) { r.violations })
  |> list.sort(string.compare)
  |> should.equal([
    "build/field_check_dependency/src/proj.gleam: direct wires dep/handler.Handler.run with effects [Stdout] but the field is declared []",
    "build/field_check_dependency/src/proj.gleam: through_factory wires dep/handler.Handler.run with effects [Stdout] but the field is declared []",
  ])
  support.cleanup(root)
}

pub fn a_dependency_factory_routes_by_declared_labels_test() {
  // The dependency's factory constructs a record defined in another of its own
  // modules, positionally. Those labels belong to the defining module, which a
  // scan of one module at a time does not hold: the factory wired nothing, the
  // project's call of it was no site, and the run passed with a warning that
  // nothing constructs the type.
  let root = "build/field_check_dependency_positional"
  support.write_project_with_dependency(
    directory: root,
    package: "proj",
    spec: "assume ffi.print : [Stdout]\ncheck dep/handler.Handler.run : []\n",
    sources: [
      #(
        "src/ffi.gleam",
        "@external(erlang, \"ffi_module\", \"print\")
@external(javascript, \"ffi_module\", \"print\")
pub fn print() -> Nil
",
      ),
      #(
        "src/proj.gleam",
        "import dep/make
import ffi

pub fn built() -> handler.Handler {
  make.positional(ffi.print)
}
",
      ),
    ],
    dependency: "dep",
    dependency_spec: "",
    dependency_sources: [
      #(
        "dep/handler.gleam",
        "pub type Handler {
  Handler(run: fn() -> Nil)
}
",
      ),
      #(
        "dep/make.gleam",
        "import dep/handler

pub fn positional(run: fn() -> Nil) -> handler.Handler {
  handler.Handler(run)
}
",
      ),
    ],
  )
  let assert Ok(reports) = graded.run(root)
  reports
  |> list.flat_map(fn(r) { r.violations })
  |> should.equal([
    "build/field_check_dependency_positional/src/proj.gleam: built wires dep/handler.Handler.run with effects [Stdout] but the field is declared []",
  ])
  support.cleanup(root)
}

// A verified `where returns` clause on a `check` line
//
// The clause states the operator the function hands back, and the check holds
// when the declared operator contains the computed one — the same direction the
// effects budget on the same line reads in. Where no operator can be derived
// the line is reported as unproved rather than as a false assertion, since the
// limit is graded's and not the author's.

// The findings a spec's `check` lines earn against one producer module.
fn clause_check_findings(name: String, spec: String) -> List(String) {
  let root = "build/" <> name
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", spec),
    #(
      "ffi.gleam",
      "@external(erlang, \"ffi_module\", \"print\")
@external(javascript, \"ffi_module\", \"print\")
pub fn print() -> Nil
",
    ),
    #(
      "proj.gleam",
      "import ffi

pub fn wrap(f: fn() -> Nil) -> fn() -> Nil {
  fn() {
    f()
    ffi.print()
  }
}

pub fn plain() -> Nil {
  Nil
}

pub fn unannotated(f: fn() -> Nil) {
  fn() { f() }
}
",
    ),
  ])
  let assert Ok(reports) = graded.run(root)
  let violations = list.flat_map(reports, fn(r) { r.violations })
  support.cleanup(root)
  violations
}

pub fn a_clause_containing_the_returned_operator_passes_test() {
  clause_check_findings(
    "clause_check_pass",
    "assume ffi.print : [Stdout]\ncheck proj.wrap(f: [f]) : [f, Stdout] where returns : [Stdout, f]\n",
  )
  |> should.equal([])
}

pub fn a_clause_wider_than_the_returned_operator_passes_test() {
  // Declared ⊇ computed, exactly as the effects half reads: a budget, not an
  // equality.
  clause_check_findings(
    "clause_check_wider",
    "assume ffi.print : [Stdout]\ncheck proj.wrap(f: [f]) : [f, Stdout] where returns : [Stdout, f, Http]\n",
  )
  |> should.equal([])
}

pub fn a_clause_narrower_than_the_returned_operator_violates_test() {
  clause_check_findings(
    "clause_check_narrow",
    "assume ffi.print : [Stdout]\ncheck proj.wrap(f: [f]) : [f, Stdout] where returns : [Stdout]\n",
  )
  |> should.equal([
    "build/clause_check_narrow/proj.gleam: wrap returns the operator [Stdout, f] but its `where returns` clause declares [Stdout]",
  ])
}

pub fn a_clause_on_a_function_returning_no_function_violates_test() {
  // The one gate step that proves the author wrong rather than leaving the
  // question open: the return type is annotated, and it is not a function.
  clause_check_findings(
    "clause_check_non_callable",
    "check proj.plain : [] where returns : [Stdout]\n",
  )
  |> should.equal([
    "build/clause_check_non_callable/proj.gleam: plain does not return a function, so its `where returns` clause [Stdout] describes an operator the function never hands back",
  ])
}

pub fn a_clause_without_a_return_annotation_is_unproved_test() {
  // Nothing here says the assertion is false — the gate never reached the
  // question — so the line is unproved, and worded as graded's limit.
  clause_check_findings(
    "clause_check_unannotated",
    "check proj.unannotated(f: [f]) : [f] where returns : [f]\n",
  )
  |> should.equal([
    "build/clause_check_unannotated/proj.gleam: could not prove check unannotated — the function carries no return type annotation, so the operator it hands back cannot be derived from source",
  ])
}

pub fn a_verified_clause_does_not_answer_for_a_consumer_test() {
  // D8: a `check` proves, it never answers. Were the clause read onto the
  // returned-operator channel, the consumer below would resolve the producer's
  // result as `[_]` and blow its own `[Stdout]` budget. Asserting the absence
  // of a violation here is asserting the resolution, since a wildcard actual
  // fails against any finite budget.
  let root = "build/clause_check_answers_nothing"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "assume ffi.print : [Stdout]
check proj/producer.wrap : [] where returns : [_]
check proj/consumer.run : [Stdout]
",
    ),
    #(
      "ffi.gleam",
      "@external(erlang, \"ffi_module\", \"print\")
@external(javascript, \"ffi_module\", \"print\")
pub fn print() -> Nil
",
    ),
    #(
      "proj/producer.gleam",
      "import ffi

pub fn wrap() -> fn() -> Nil {
  fn() { ffi.print() }
}
",
    ),
    #(
      "proj/consumer.gleam",
      "import proj/producer

pub fn run() -> Nil {
  let handler = producer.wrap()
  handler()
}
",
    ),
  ])
  let assert Ok(reports) = graded.run(root)
  reports
  |> list.flat_map(fn(r) { r.violations })
  |> should.equal([])
  support.cleanup(root)
}

pub fn a_clause_is_verified_on_the_producer_targets_test() {
  // The check side of the narrowing `infer` performs: a `@target(erlang)`
  // producer's closure over a JavaScript-only external returns what that
  // external's Erlang fallback does, so the clause `infer` writes is the clause
  // `check` verifies. Computed package-wide, the operator carried the
  // unreachable declaration's effect and every written line failed its own
  // check.
  let root = "build/clause_check_target_restricted"
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #(
      "proj.graded",
      "assume ext.b : [Disk]\ncheck ext.make : [] where returns : []\n",
    ),
    #(
      "ext.gleam",
      "@external(javascript, \"ext_ffi\", \"b\")
pub fn b() -> Nil {
  Nil
}

@target(erlang)
pub fn make() -> fn() -> Nil {
  fn() { b() }
}
",
    ),
  ])
  let assert Ok(reports) = graded.run(root)
  reports
  |> list.flat_map(fn(r) { r.violations })
  |> should.equal([])
  support.cleanup(root)
}

// A foreign producer's clause
//
// Only the foreign implementation decides what an `@external` returns, so a
// declaration is what answers for one. Where a Gleam fallback body runs beside
// the declaration there is no union of operators to take, so the clause holds
// only when the declaration and the body's own returned operator each contain
// it.

fn foreign_clause_findings(name: String, spec: String) -> List(String) {
  let root = "build/" <> name
  support.write_fixture(root, [
    #("gleam.toml", support.dual_target_toml("proj")),
    #("proj.graded", spec),
    #(
      "log.gleam",
      "@external(erlang, \"log_module\", \"write\")
@external(javascript, \"log_module\", \"write\")
pub fn write() -> Nil
",
    ),
    #(
      "ffi.gleam",
      "import log

@external(erlang, \"ffi_module\", \"make\")
pub fn make() -> fn() -> Nil {
  fn() { log.write() }
}
",
    ),
  ])
  let assert Ok(reports) = graded.run(root)
  let violations = list.flat_map(reports, fn(r) { r.violations })
  support.cleanup(root)
  violations
}

pub fn a_foreign_clause_with_no_declaration_is_unproved_test() {
  foreign_clause_findings(
    "clause_check_foreign_undeclared",
    "assume log.write : [Http]\ncheck ffi.make : [_] where returns : [Http]\n",
  )
  |> should.equal([
    "build/clause_check_foreign_undeclared/ffi.gleam: could not prove check make — the external's Gleam fallback body runs, and there is no union of operators to weigh it with the declaration; the clause holds only when it agrees with the declaration and the fallback's own returned operator is proved beside it",
  ])
}

pub fn a_foreign_clause_agreeing_with_both_halves_passes_test() {
  foreign_clause_findings(
    "clause_check_foreign_agrees",
    "assume log.write : [Http]\nassume ffi.make where returns : [Http]\ncheck ffi.make : [_] where returns : [Http]\n",
  )
  |> should.equal([])
}

pub fn a_foreign_clause_the_running_fallback_disagrees_with_fails_test() {
  // The declaration and the clause agree, and the running Gleam body hands
  // back something else. `DeclaredReturnStanding` calls a written clause
  // settled here, so a check reading only the standing would pass this.
  foreign_clause_findings(
    "clause_check_foreign_fallback",
    "assume log.write : [Http]\nassume ffi.make where returns : [Stdout]\ncheck ffi.make : [_] where returns : [Stdout]\n",
  )
  |> should.equal([
    "build/clause_check_foreign_fallback/ffi.gleam: make returns the operator [Http] but its `where returns` clause declares [Stdout]",
  ])
}

// A dependency's running Gleam fallback body
//
// An `@external` a dependency declares for one target only falls back to its
// Gleam body on the others. A consumer that compiles those targets runs that
// body, so it is charged what the body does — walked, the way one of this
// package's own fallback bodies is, rather than assumed to be anything.

// What a consumer's call into a dependency's `@external` is charged, with that
// external's fallback body running on a target the consumer compiles.
fn dependency_fallback_violations(
  name: String,
  dependency_spec: String,
  dependency_source: String,
) -> List(types.Violation) {
  let root =
    support.write_project_with_dependency(
      directory: "build/" <> name,
      package: "proj",
      spec: "check proj.caller : []\n",
      sources: [
        #(
          "proj.gleam",
          "import dep/store

pub fn caller() -> Nil {
  store.insert()
}
",
        ),
      ],
      dependency: "dep",
      dependency_spec: dependency_spec,
      dependency_sources: [#("dep/store.gleam", dependency_source)],
    )
  let assert Ok(results) = graded.check_project(root)
  let violations = list.flat_map(results, fn(result) { result.violations })
  // The query agrees with what `check` charged, whichever path answered it.
  let assert Ok(answered) = graded.run_effect(root, "dep/store.insert")
  answered
  |> should.equal(
    graded.run_effect_from_project(root, "dep/store.insert") |> should.be_ok(),
  )
  support.cleanup(root)
  violations
}

// The shape the standard library's dicts and sets have: a JavaScript external
// whose Gleam body calls a private Erlang one beside it. On Erlang the body is
// what runs, and every name it reaches is declared, so the call costs nothing.
pub fn a_dependency_fallback_body_is_walked_test() {
  dependency_fallback_violations(
    "dep_fallback_walked",
    "assume dep/store : []\n",
    "@external(javascript, \"./store.mjs\", \"insert\")
pub fn insert() -> Nil {
  do_insert()
}

@external(erlang, \"dep_ffi\", \"insert\")
fn do_insert() -> Nil
",
  )
  |> should.equal([])
}

// Walked, not waved through: what the body reaches is charged, so a fallback
// that calls a declared effectful name costs that effect and no more. The
// declaration covers JavaScript, the body covers Erlang, and the consumer
// compiling both pays the union.
pub fn a_dependency_fallback_body_charges_what_it_calls_test() {
  let assert [violation] =
    dependency_fallback_violations(
      "dep_fallback_charges",
      "assume dep/store : []\nassume dep/store.shout : [Stdout]\n",
      "@external(javascript, \"./store.mjs\", \"insert\")
pub fn insert() -> Nil {
  shout()
}

@external(erlang, \"dep_ffi\", \"shout\")
pub fn shout() -> Nil
",
    )
  violation.function |> should.equal("caller")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

// The per-function shipped line answers alone: the dependency author's own
// `assume insert : []` suppresses the body's half — even the `[Unknown]` a
// body reaching an undeclared name is worth — on the shipped line's say-so.
// The conservative reading survives under the non-suppressing origins: the
// catalog keeps the union (`a_catalog_declaration_keeps_the_union_test`), and
// so does a module-level blanket.
pub fn a_dependency_assume_suppresses_a_body_reaching_nothing_test() {
  dependency_fallback_violations(
    "dep_fallback_suppressed",
    "assume dep/store.insert : []\n",
    "@external(javascript, \"./store.mjs\", \"insert\")
pub fn insert() -> Nil {
  hidden()
}

@external(erlang, \"dep_ffi\", \"hidden\")
fn hidden() -> Nil
",
  )
  |> should.equal([])
}

// A fallback body calling a function-typed field on an annotated parameter,
// against an `assume` line for that field. `field_line` is the line, written
// into whichever spec the caller of this passes it in — the consumer's or the
// dependency's, which resolve it by different routes and both have to.
//
// The consumer constructs the record with a pure function, so a summary left
// polymorphic in `r.run` settles at `[]` here and the `check` passes: the
// declared effect has to reach the walk to be charged at all.
fn dependency_fallback_field_violations(
  name: String,
  spec: String,
  dependency_spec: String,
) -> List(types.Violation) {
  let root =
    support.write_project_with_dependency(
      directory: "build/" <> name,
      package: "proj",
      spec: spec,
      sources: [
        #(
          "proj.gleam",
          "import dep/store

pub fn quiet() -> Nil {
  Nil
}

pub fn caller() -> Nil {
  store.insert(store.Runner(run: quiet))
}
",
        ),
      ],
      dependency: "dep",
      dependency_spec: dependency_spec,
      dependency_sources: [
        #(
          "dep/store.gleam",
          "pub type Runner {
  Runner(run: fn() -> Nil)
}

@external(javascript, \"./store.mjs\", \"insert\")
pub fn insert(r: Runner) -> Nil {
  r.run()
}
",
        ),
      ],
    )
  let assert Ok(results) = graded.check_project(root)
  support.cleanup(root)
  list.flat_map(results, fn(result) { result.violations })
}

// The line is resolved by the receiver's nominal type, and the only reading of
// that type here is the parameter's own annotation — girard annotates no
// dependency's source, so the walk holds no inferred type for `r`. That
// annotation names no module, and the shipped line qualifies its type by one, so
// the type is keyed by the module the walk is in as well as bare. Keyed bare
// alone the line went unmatched and the declared `[Disk]` was specialized away.
pub fn a_dependency_fallbacks_field_call_reads_its_declared_line_test() {
  let assert [violation] =
    dependency_fallback_field_violations(
      "dep_fallback_field_line",
      "check proj.caller : []\n",
      "assume dep/store : []\nassume dep/store.Runner.run : [Disk]\n",
    )
  violation.function |> should.equal("caller")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

// The same line, written by the consumer about a dependency's type — which is
// where a dependency shipping no spec of its own leaves it. It is charged the
// same, so the spec's field lines have to be folded into the knowledge base
// ahead of the walk that reads them, not merely ahead of this package's own
// inference.
pub fn a_dependency_fallbacks_field_call_reads_a_consumers_line_test() {
  let assert [violation] =
    dependency_fallback_field_violations(
      "dep_fallback_field_line_consumer",
      "assume dep/store.Runner.run : [Disk]\ncheck proj.caller : []\n",
      "assume dep/store : []\n",
    )
  violation.function |> should.equal("caller")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

// The same, for a fallback body whose parameter is annotated with a type from
// another module of its own package. `import_line` is how that module is
// imported and `annotation` how the type is written under that import: three
// spellings of one type, all of which have to key the one field `assume`.
//
// The type's own module qualifies that line, and the annotation is the only
// reading of the receiver's type in a dependency's body, so the spelling is all
// the walk has to go on.
fn dependency_fallback_imported_field_violations(
  name: String,
  import_line: String,
  annotation: String,
) -> List(types.Violation) {
  let root =
    support.write_project_with_dependency(
      directory: "build/" <> name,
      package: "proj",
      spec: "check proj.caller : []\n",
      sources: [
        #(
          "proj.gleam",
          "import dep/model
import dep/store

pub fn quiet() -> Nil {
  Nil
}

pub fn caller() -> Nil {
  store.insert(model.Runner(run: quiet))
}
",
        ),
      ],
      dependency: "dep",
      dependency_spec: "assume dep/store : []
assume dep/model.Runner.run : [Disk]
",
      dependency_sources: [
        #(
          "dep/model.gleam",
          "pub type Runner {
  Runner(run: fn() -> Nil)
}
",
        ),
        #("dep/store.gleam", import_line <> "

@external(javascript, \"./store.mjs\", \"insert\")
pub fn insert(r: " <> annotation <> ") -> Nil {
  r.run()
}
"),
      ],
    )
  let assert Ok(results) = graded.check_project(root)
  support.cleanup(root)
  list.flat_map(results, fn(result) { result.violations })
}

// The declared `[Disk]` is charged for every spelling. A qualified annotation
// used to name no type at all — the local registry must not claim an imported
// type's fields — so the call fell to `[Unknown]` and a consumer's accurate
// `check ... : [Disk]` failed. The alias the annotation is written under names
// the module instead, which is what the line is keyed by.
pub fn a_dependency_fallback_reads_an_imported_types_line_test() {
  let assert [violation] =
    dependency_fallback_imported_field_violations(
      "dep_fallback_imported_field",
      "import dep/model",
      "model.Runner",
    )
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

pub fn a_dependency_fallback_reads_an_aliased_imported_types_line_test() {
  let assert [violation] =
    dependency_fallback_imported_field_violations(
      "dep_fallback_aliased_field",
      "import dep/model as m",
      "m.Runner",
    )
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

// An unqualified import writes the same type with no module beside it, which is
// the spelling of a type of the module's own. It is the import that tells them
// apart, so the line keyed by the defining module is still the one read.
pub fn a_dependency_fallback_reads_an_unqualified_imported_types_line_test() {
  let assert [violation] =
    dependency_fallback_imported_field_violations(
      "dep_fallback_unqualified_field",
      "import dep/model.{type Runner}",
      "Runner",
    )
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

// A fallback body in one dependency package calling one in another. `caller` is
// the `@external` the consumer calls; the body it falls back to calls `callee`,
// whose own fallback body reaches the disk. Both module paths are parameters
// because the walk's order has to hold whichever way they sort: the packages'
// directories are enumerated in no promised order, and a pass that took the
// modules as they came would summarize `caller` against an unwalked `callee`
// half the time.
fn dependency_fallback_chain_violations(
  name: String,
  caller_path: String,
  callee_path: String,
) -> List(types.Violation) {
  let root =
    support.write_fixture("build/" <> name, [
      #("gleam.toml", "name = \"proj\"\ntarget = \"erlang\"\n"),
      #("proj.graded", "check proj.wrap : []\n"),
      #("proj.gleam", "import " <> caller_path <> "

pub fn wrap() -> Nil {
  caller.run()
}
"),
      #(
        "build/packages/upstream/src/" <> caller_path <> ".gleam",
        "import " <> callee_path <> "

@external(javascript, \"upstream_ffi\", \"run\")
pub fn run() -> Nil {
  callee.run()
}
",
      ),
      #(
        "build/packages/downstream/downstream.graded",
        "assume " <> callee_path <> ".scribble : [Disk]\n",
      ),
      #(
        "build/packages/downstream/src/" <> callee_path <> ".gleam",
        "@external(javascript, \"downstream_ffi\", \"run\")
pub fn run() -> Nil {
  scribble()
}

@external(erlang, \"downstream_ffi\", \"scribble\")
pub fn scribble() -> Nil
",
      ),
    ])
  let assert Ok(results) = graded.check_project(root)
  let violations = list.flat_map(results, fn(result) { result.violations })
  support.cleanup(root)
  violations
}

// The callee sorts after the caller, so a pass following path order walks the
// caller first and summarizes it against an unwalked callee.
pub fn a_dependency_fallback_chain_is_walked_callee_first_test() {
  let assert [violation] =
    dependency_fallback_chain_violations(
      "dep_fallback_chain_forward",
      "a/caller",
      "z/callee",
    )
  violation.function |> should.equal("wrap")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

// The same chain the other way round, where path order happens to be the walk
// order. Both arrangements answer the same, which is the point of sorting.
pub fn a_dependency_fallback_chain_is_walked_in_either_order_test() {
  let assert [violation] =
    dependency_fallback_chain_violations(
      "dep_fallback_chain_reverse",
      "z/caller",
      "a/callee",
    )
  violation.function |> should.equal("wrap")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

// The within-module half of the same question, which the module ordering above
// cannot settle: `a`'s fallback calls `b`'s and `b`'s calls `a`'s, so neither is
// summarized against a settled summary of the other. The walk iterates the
// component to a fixed point, as it does for one of this package's own.
pub fn a_dependency_fallback_cycle_settles_to_one_summary_test() {
  let assert [violation] =
    dependency_fallback_violations(
      "dep_fallback_mutual",
      "assume dep/store : []\nassume dep/store.scribble : [Disk]\n",
      "@external(javascript, \"store_ffi\", \"insert\")
pub fn insert() -> Nil {
  other(1)
}

@external(javascript, \"store_ffi\", \"a\")
fn a(n: Int) -> Nil {
  case n {
    0 -> scribble()
    _ -> other(n - 1)
  }
}

@external(javascript, \"store_ffi\", \"b\")
fn other(n: Int) -> Nil {
  a(n - 1)
}

@external(erlang, \"store_ffi\", \"scribble\")
pub fn scribble() -> Nil
",
    )
  violation.function |> should.equal("caller")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

// What `infer` writes for a caller of a dependency external whose fallback body
// runs, and that a second run writes nothing more. The walk happens where both
// commands fold their layers, so the line `infer` publishes for consumers is the
// charge `check` levies here.
pub fn infer_publishes_a_walked_dependency_fallback_test() {
  let root =
    support.write_project_with_dependency(
      directory: "build/dep_fallback_infer",
      package: "proj",
      spec: "",
      sources: [
        #(
          "proj.gleam",
          "import dep/store

pub fn caller() -> Nil {
  store.insert()
}
",
        ),
      ],
      dependency: "dep",
      dependency_spec: "assume dep/store : []\nassume dep/store.shout : [Stdout]\n",
      dependency_sources: [
        #(
          "dep/store.gleam",
          "@external(javascript, \"./store.mjs\", \"insert\")
pub fn insert() -> Nil {
  shout()
}

@external(erlang, \"dep_ffi\", \"shout\")
pub fn shout() -> Nil
",
        ),
      ],
    )
  let assert Ok(Nil) = graded.run_infer(root)
  let assert Ok(written) = simplifile.read(root <> "/proj.graded")
  written
  |> string.contains("effects proj.caller : [Stdout]")
  |> should.be_true()
  // And the second run has nothing to add: the walk is part of the fold both
  // runs perform, not state the first one left behind.
  let assert Ok(preview) = graded.run_infer_dry_run(root)
  preview |> should.equal("graded: no changes")
  support.cleanup(root)
}

// The narrowing the walk does not disturb: a dependency external declaring every
// target the consumer compiles has no body that runs, so its declaration is the
// whole charge and nothing is unioned into it.
pub fn a_dependency_external_covering_every_target_charges_its_declaration_test() {
  let assert [violation] =
    dependency_fallback_violations(
      "dep_fallback_no_body",
      "assume dep/store.insert : [Disk]\n",
      "@external(erlang, \"dep_ffi\", \"insert\")
@external(javascript, \"./store.mjs\", \"insert\")
pub fn insert() -> Nil {
  shout()
}

@external(erlang, \"dep_ffi\", \"shout\")
pub fn shout() -> Nil
",
    )
  violation.function |> should.equal("caller")
  violation.explanation.actual
  |> should.equal(types.Specific(set.from_list(["Disk"])))
}

// Two dependency modules importing each other, which the ordering pass cannot
// sort. Gleam's compiler forbids the shape, so no build produces it — but graded
// parses dependency source without compiling it, and a walk that trusted the
// graph to be acyclic would have nothing to fall back on. Both modules are
// dropped from the walk and keep the `[Unknown]` an unwalked body carries, and
// the rest of the run carries on.
pub fn a_cyclic_dependency_fallback_still_charges_the_callback_test() {
  // `dep/x` and `dep/y` import each other, so neither fallback body is
  // walked. The callback shape is recorded anyway: under the shipped
  // boundless-for-`action` line, the direct call and the operator channel
  // both charge the `[Disk]` callback beside the declared `[Time]`, and the
  // suppressed share quotes what the unwalked body reads as — its `[Unknown]`
  // plus the callback it may call, bound to this call's `[Disk]`.
  let root =
    support.write_project_with_dependency(
      directory: "build/dep_fallback_cycle_callback",
      package: "proj",
      spec: "assume proj.disk : [Disk]
check proj.direct : []
check proj.via_operator : []
",
      sources: [
        #(
          "proj.gleam",
          "import dep/x

@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
pub fn disk() -> Nil

pub fn direct() -> Nil {
  x.run(disk)
}

fn invoke(op: fn(fn() -> Nil) -> Nil, cb: fn() -> Nil) -> Nil {
  op(cb)
}

pub fn via_operator() -> Nil {
  invoke(x.run, disk)
}
",
        ),
      ],
      dependency: "dep",
      dependency_spec: "assume dep/x.run : [Time]\nassume dep/y.tick : []\n",
      dependency_sources: [
        #(
          "dep/x.gleam",
          "import dep/y

@external(javascript, \"x\", \"r\")
pub fn run(action: fn() -> Nil) -> Nil {
  y.tick()
  action()
}
",
        ),
        #(
          "dep/y.gleam",
          "import dep/x

@external(javascript, \"y\", \"t\")
pub fn tick() -> Nil {
  x.run(fn() { Nil })
}
",
        ),
      ],
    )
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/proj.gleam" })
  ["direct", "via_operator"]
  |> list.each(fn(function) {
    let assert Ok(violation) =
      list.find(r.violations, fn(v) { v.function == function })
    violation.explanation.actual
    |> should.equal(types.Specific(set.from_list(["Disk", "Time"])))
  })
  let assert Ok(direct) =
    list.find(r.violations, fn(v) { v.function == "direct" })
  direct.explanation.fallback
  |> should.equal(
    types.FallbackSuppressed(types.Specific(set.from_list(["Disk", "Unknown"]))),
  )
  support.cleanup(root)
}

pub fn a_cycle_between_dependency_fallbacks_stays_unknown_test() {
  let root =
    support.write_project_with_dependency(
      directory: "build/dep_fallback_cycle",
      package: "proj",
      spec: "check proj.caller : []\n",
      sources: [
        #(
          "proj.gleam",
          "import dep/x

pub fn caller() -> Nil {
  x.run()
}
",
        ),
      ],
      dependency: "dep",
      dependency_spec: "assume dep/x : []\nassume dep/y : []\n",
      dependency_sources: [
        #(
          "dep/x.gleam",
          "import dep/y

@external(javascript, \"x_ffi\", \"run\")
pub fn run() -> Nil {
  y.helper()
}
",
        ),
        #(
          "dep/y.gleam",
          "import dep/x

@external(javascript, \"y_ffi\", \"helper\")
pub fn helper() -> Nil {
  x.run()
}
",
        ),
      ],
    )
  let assert Ok(results) = graded.check_project(root)
  let assert [violation] = list.flat_map(results, fn(r) { r.violations })
  violation.function |> should.equal("caller")
  violation.explanation.actual
  |> types.contains_unknown
  |> should.be_true
  support.cleanup(root)
}

// Girard-typed callback parameters
//
// A parameter carrying no `fn(...)` annotation is a callback all the same when
// girard infers a function type for it. Every channel that reaches such a
// helper — a same-module call, the operator lift of a reference to it, a
// cross-module call — charges the one answer.

// The package the section runs over: `apply` takes an unannotated callback,
// and three callers reach it. `ffi.shout` is the only source of an effect, so
// nothing here depends on an installed dependency.
fn girard_callback_project(root: String) -> List(types.EffectAnnotation) {
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(root <> "/gleam.toml", "name = \"proj\"\n")
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/ffi.gleam",
      support.foreign_fn("shout", "() -> Nil"),
    )
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/proj.gleam",
      "import ffi

pub fn shout() -> Nil {
  ffi.shout()
}

pub fn apply(f) {
  f()
}

pub fn same_module() -> Nil {
  apply(shout)
}

pub fn twice(g: fn(fn() -> Nil) -> Nil, cb: fn() -> Nil) -> Nil {
  g(cb)
}

pub fn via_lift() -> Nil {
  twice(apply, shout)
}
",
    )
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/other.gleam",
      "import proj

pub fn cross_module() -> Nil {
  proj.apply(proj.shout)
}
",
    )
  let assert Ok(Nil) =
    simplifile.write(root <> "/proj.graded", "assume ffi.shout : [Stdout]\n")
  let assert Ok(Nil) = graded.run_infer(root)
  let assert Ok(content) = simplifile.read(root <> "/proj.graded")
  let assert Ok(file) = annotation.parse_file(content)
  annotation.extract_annotations(file)
}

fn inferred_effects(
  annotations: List(types.EffectAnnotation),
  function: String,
) -> EffectTerm {
  let assert Ok(annotation) =
    list.find(annotations, fn(a) { a.function == function })
  annotation.effects
}

pub fn girard_typed_callback_charges_every_caller_alike_test() {
  let root = "build/girard_callback_parity"
  let annotations = girard_callback_project(root)
  let stdout = types.TLabels(set.from_list(["Stdout"]))

  // The helper itself: one bound over the unannotated parameter.
  inferred_effects(annotations, "proj.apply")
  |> should.equal(types.TVar("f"))
  // The caller beside it, the caller in another module, and the lift of a
  // reference to it all charge the callback's own effects.
  inferred_effects(annotations, "proj.same_module") |> should.equal(stdout)
  inferred_effects(annotations, "other.cross_module") |> should.equal(stdout)
  inferred_effects(annotations, "proj.via_lift") |> should.equal(stdout)
  support.cleanup(root)
}

// Callback parameters spelled through a `fn` type alias
//
// `run(action: Action)` with `type Action = fn() -> Nil` takes a callback, and
// every reading says so: the bound `infer` writes, the call-site binding beside
// it and across the module boundary, the shape of a second-order parameter
// whose own callback is aliased too, and the conservative charge a boundless
// declaration makes.

// The package the section runs over. `ffi.shout` is the only source of an
// effect, and `ffi.each` is a boundless declared external taking an
// alias-typed callback.
fn alias_callback_project(root: String) -> Nil {
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(root <> "/gleam.toml", "name = \"proj\"\n")
  let assert Ok(Nil) =
    simplifile.write(root <> "/ffi.gleam", "pub type Callback =
  fn() -> Nil

" <> support.foreign_fn("shout", "() -> Nil") <> "
" <> support.foreign_fn("each", "(cb: Callback) -> Nil"))
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/proj.gleam",
      "import ffi

pub type Action =
  fn() -> Nil

pub type Callback =
  fn() -> Nil

pub type Op =
  fn(Callback) -> Nil

pub fn shout() -> Nil {
  ffi.shout()
}

pub fn run(action: Action) -> Nil {
  action()
}

pub fn same_module() -> Nil {
  run(shout)
}

pub fn use_op(op: Op, cb: Callback) -> Nil {
  op(cb)
}

pub fn drive() -> Nil {
  use_op(run, shout)
}
",
    )
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/other.gleam",
      "import ffi
import proj

pub fn cross_module() -> Nil {
  proj.run(proj.shout)
}

pub fn via_declared_external() -> Nil {
  ffi.each(proj.shout)
}
",
    )
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/proj.graded",
      "assume ffi.shout : [Stdout]\nassume ffi.each : []\n",
    )
  Nil
}

pub fn an_alias_typed_callback_resolves_like_an_annotated_one_test() {
  let root = "build/alias_callback_project"
  alias_callback_project(root)
  let assert Ok(Nil) = graded.run_infer(root)
  let assert Ok(content) = simplifile.read(root <> "/proj.graded")
  let assert Ok(file) = annotation.parse_file(content)
  let annotations = annotation.extract_annotations(file)
  let stdout = types.TLabels(set.from_list(["Stdout"]))

  // The bound is written, so a line stays closed by itself with no girard run.
  let assert Ok(run) =
    list.find(annotations, fn(a) { a.function == "proj.run" })
  run.effects |> should.equal(types.TVar("action"))
  run.params |> list.map(fn(b) { b.name }) |> should.equal(["action"])

  // Bound at the call site, beside the definition and from another module.
  inferred_effects(annotations, "proj.same_module") |> should.equal(stdout)
  inferred_effects(annotations, "other.cross_module") |> should.equal(stdout)

  // A second-order parameter whose own callback is aliased keeps its shape,
  // so applying it to the callback reduces instead of going stuck.
  let assert Ok(use_op) =
    list.find(annotations, fn(a) { a.function == "proj.use_op" })
  use_op.params
  |> list.map(fn(b) { b.name })
  |> list.sort(string.compare)
  |> should.equal(["cb", "op"])
  use_op.effects
  |> should.equal(types.TApp(types.TVar("op"), types.TVar("cb")))
  inferred_effects(annotations, "proj.drive") |> should.equal(stdout)

  // A boundless declaration says nothing about its callbacks, so the caller
  // pays the one it passes — through the alias too.
  inferred_effects(annotations, "other.via_declared_external")
  |> should.equal(stdout)
  support.cleanup(root)
}

pub fn an_inferred_alias_callback_spec_checks_clean_test() {
  // The spec `infer` writes for the same package passes `check`: every bound
  // it names is one the closedness oracle admits.
  let root = "build/alias_callback_roundtrip"
  alias_callback_project(root)
  let assert Ok(Nil) = graded.run_infer(root)
  let assert Ok(results) = graded.check_project(root)
  list.flat_map(results, fn(r) { r.violations }) |> should.equal([])
  list.flat_map(results, fn(r) { r.warnings }) |> should.equal([])
  support.cleanup(root)
}

pub fn a_cyclic_dependency_records_an_alias_typed_callback_test() {
  // The cycle skips the walk, so `dep/x.run` keeps the `[Unknown]` an unwalked
  // body carries — with its callback recorded beside it, though the callback is
  // spelled through an alias. Both callers pay the `[Disk]` they pass.
  let root =
    support.write_project_with_dependency(
      directory: "build/dep_cycle_alias_callback",
      package: "proj",
      spec: "assume proj.disk : [Disk]
check proj.direct : []
check proj.via_operator : []
",
      sources: [
        #(
          "proj.gleam",
          "import dep/x

@external(erlang, \"d\", \"w\")
@external(javascript, \"d\", \"w\")
pub fn disk() -> Nil

pub fn direct() -> Nil {
  x.run(disk)
}

fn invoke(op: fn(fn() -> Nil) -> Nil, cb: fn() -> Nil) -> Nil {
  op(cb)
}

pub fn via_operator() -> Nil {
  invoke(x.run, disk)
}
",
        ),
      ],
      dependency: "dep",
      dependency_spec: "assume dep/x.run : [Time]\nassume dep/y.tick : []\n",
      dependency_sources: [
        #(
          "dep/x.gleam",
          "import dep/y

pub type Action =
  fn() -> Nil

@external(javascript, \"x\", \"r\")
pub fn run(action: Action) -> Nil {
  y.tick()
  action()
}
",
        ),
        #(
          "dep/y.gleam",
          "import dep/x

@external(javascript, \"y\", \"t\")
pub fn tick() -> Nil {
  x.run(fn() { Nil })
}
",
        ),
      ],
    )
  let assert Ok(results) = graded.check_project(root)
  let assert Ok(r) =
    list.find(results, fn(r) { r.file == root <> "/proj.gleam" })
  ["direct", "via_operator"]
  |> list.each(fn(function) {
    let assert Ok(violation) =
      list.find(r.violations, fn(v) { v.function == function })
    violation.explanation.actual
    |> should.equal(types.Specific(set.from_list(["Disk", "Time"])))
  })
  support.cleanup(root)
}

// Pipes into a function capture
//
// `x |> f(_, y)` is `f(x, y)`, so the piped value binds the parameter at the
// discard's position — a callback among them. Every callee shape the ordinary
// pipe branches resolve is covered, and a receiver nothing traces reads the
// `[Unknown]` the direct call reads rather than passing for pure.

fn pipe_capture_project(root: String) -> List(types.EffectAnnotation) {
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(root <> "/gleam.toml", "name = \"proj\"\n")
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/ffi.gleam",
      support.foreign_fn("shout", "() -> Nil"),
    )
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/helper.gleam",
      "pub type Inner {
  Inner(run: fn(fn() -> Nil, Int) -> Nil)
}

pub type Outer {
  Outer(inner: Inner)
}

pub fn apply(cb: fn() -> Nil, n: Int) -> Nil {
  case n {
    0 -> Nil
    _ -> cb()
  }
}

pub fn labelled(callback cb: fn() -> Nil, times n: Int) -> Nil {
  apply(cb, n)
}
",
    )
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/proj.gleam",
      "import ffi
import helper

pub fn shout() -> Nil {
  ffi.shout()
}

fn local(cb: fn() -> Nil, n: Int) -> Nil {
  helper.apply(cb, n)
}

pub fn discard_first() -> Nil {
  shout |> helper.apply(_, 1)
}

pub fn discard_later() -> Nil {
  1 |> helper.apply(shout, _)
}

pub fn discard_labelled() -> Nil {
  shout |> helper.labelled(times: 1, callback: _)
}

pub fn discard_local() -> Nil {
  shout |> local(_, 1)
}

pub fn discard_nested_field(o: helper.Outer) -> Nil {
  shout |> o.inner.run(_, 1)
}

pub fn nested_field_direct(o: helper.Outer) -> Nil {
  o.inner.run(shout, 1)
}
",
    )
  let assert Ok(Nil) =
    simplifile.write(root <> "/proj.graded", "assume ffi.shout : [Stdout]\n")
  let assert Ok(Nil) = graded.run_infer(root)
  let assert Ok(content) = simplifile.read(root <> "/proj.graded")
  let assert Ok(file) = annotation.parse_file(content)
  annotation.extract_annotations(file)
}

pub fn piping_into_a_capture_binds_the_callback_test() {
  let root = "build/pipe_capture_project"
  let annotations = pipe_capture_project(root)
  let stdout = types.TLabels(set.from_list(["Stdout"]))

  [
    "proj.discard_first",
    "proj.discard_later",
    "proj.discard_labelled",
    "proj.discard_local",
  ]
  |> list.each(fn(function) {
    inferred_effects(annotations, function) |> should.equal(stdout)
  })

  // A receiver with no traceable construction resolves the same way it does
  // without the capture — conservatively, not as pure.
  inferred_effects(annotations, "proj.discard_nested_field")
  |> should.equal(inferred_effects(annotations, "proj.nested_field_direct"))
  support.cleanup(root)
}

// The public check result
//
// `run` hands back what `main` prints: per module, its rendered warnings and
// its rendered violations. Both halves, and both rendered by the one renderer
// the CLI reads, so a caller and the terminal cannot disagree.

pub fn the_public_report_renders_the_structured_result_test() {
  let root = "build/public_report"
  write_project(
    root,
    [
      #(
        "proj.gleam",
        "import gleam/io

pub fn shout() -> Nil {
  io.println(\"x\")
}
",
      ),
    ],
    "check proj.shout : []\ncheck proj.missing : []\n",
  )

  let assert Ok(reports) = graded.run(root)
  let assert Ok(structured) = graded.check_project(root)

  // One report per structured result, in the same order and under the same
  // file, holding exactly what the checker's own renderers produce.
  list.map(reports, fn(report) { report.file })
  |> should.equal(list.map(structured, fn(result) { result.file }))
  list.zip(reports, structured)
  |> list.each(fn(pair) {
    let #(report, result) = pair
    report.violations
    |> should.equal(
      list.map(result.violations, checker.format_violation(result.file, _)),
    )
    report.warnings
    |> should.equal(
      list.map(result.warnings, checker.format_warning(result.file, _)),
    )
  })

  // And both halves are really there: a dead `check` line earns a warning
  // against the spec file, the live one a violation against the source.
  list.flat_map(reports, fn(report) { report.warnings })
  |> list.any(string.contains(_, "proj.missing"))
  |> should.be_true
  list.flat_map(reports, fn(report) { report.violations })
  |> list.any(string.contains(_, "shout"))
  |> should.be_true
  support.cleanup(root)
}

// Shadowed receivers, end to end
//
// A parameter or local named `result`, `list` or `int` shadows the stdlib
// module of the same name, and the compiler reads the module wherever the
// receiver's type grants no accessor for the label. These run the annotation
// through the real key shapes a project builds — the one thing a splitter test
// against a hand-built registry cannot check.

// The installed stdlib, so `gleam/io` and the shadowed modules resolve through
// the bundled catalog rather than reading `[Unknown]`.
const stdlib_manifest = "packages = [
  { name = \"gleam_stdlib\", version = \"1.0.3\" },
]
"

// One project module, its inferred effect line as `graded effect` renders it.
fn shadow_effect_line(
  name: String,
  source: String,
  function: String,
) -> String {
  let root =
    support.write_fixture("build/" <> name, [
      #("gleam.toml", "name = \"proj\"\n"),
      #("manifest.toml", stdlib_manifest),
      #("ext.gleam", source),
    ])
  let assert Ok(answered) = graded.run_effect(root, "ext." <> function)
  support.cleanup(root)
  answered
}

pub fn a_shadowed_receiver_of_a_local_type_reads_as_the_module_test() {
  // The motivating shape, with the type written unqualified: `result` names the
  // parameter, `girard.Type` has no `try` field, and the compiler reads
  // `gleam/result.try`. Keyed bare, the lookup would miss the project's own
  // module and leave the whole function `[Unknown]`.
  shadow_effect_line(
    "shadow_local_type",
    "import gleam/io
import gleam/result

pub type Thing {
  Thing(n: Int)
}

pub fn shadowed(result: Thing, r: Result(Int, Nil)) -> Result(Int, Nil) {
  use v <- result.try(r)
  io.println(\"hi\")
  Ok(v + result.n)
}
",
    "shadowed",
  )
  |> string.contains("effects ext.shadowed : [Stdout]")
  |> should.be_true()
}

pub fn a_shadowed_receiver_of_an_imported_type_reads_as_the_module_test() {
  // `import model.{type Runner}` writes the type unqualified here, but the
  // index entry is keyed by the module that declares it.
  let root =
    support.write_fixture("build/shadow_imported_type", [
      #("gleam.toml", "name = \"proj\"\n"),
      #("manifest.toml", stdlib_manifest),
      #("model.gleam", "pub type Runner {\n  Runner(n: Int)\n}\n"),
      #(
        "ext.gleam",
        "import gleam/io
import gleam/list
import model.{type Runner}

pub fn shadowed(list: Runner) -> Nil {
  io.println(\"hi\")
  list.each([1, 2], fn(_x) { Nil })
}
",
      ),
    ])
  let assert Ok(answered) = graded.run_effect(root, "ext.shadowed")
  answered
  |> string.contains("effects ext.shadowed : [Stdout]")
  |> should.be_true()
  support.cleanup(root)
}

pub fn a_shadowed_receiver_behind_a_type_alias_reads_as_the_module_test() {
  // Chained aliases resolve to the type they name; the alias itself is not in
  // the index, so reading it directly would leave the call `[Unknown]`.
  shadow_effect_line(
    "shadow_alias",
    "import gleam/io
import gleam/list

pub type Thing {
  Thing(n: Int)
}

pub type Chained = Alias

pub type Alias = Thing

pub fn shadowed(list: Chained) -> Nil {
  io.println(\"hi\")
  list.each([1, 2], fn(_x) { Nil })
}
",
    "shadowed",
  )
  |> string.contains("effects ext.shadowed : [Stdout]")
  |> should.be_true()
}

pub fn a_fieldless_receiver_annotation_reads_as_the_module_test() {
  // A `fn(..)`, a tuple and a source-level generic carry no fields at all, so
  // the compiler must read the module through each. `syntactic_param_type`
  // answers named types only, which is why these need a query of their own.
  let source =
    "import gleam/list

pub fn fn_recv(list: fn(Int) -> Int) -> Nil {
  list.each([1, 2], fn(_x) { Nil })
}

pub fn tuple_recv(list: #(Int, Int)) -> Nil {
  list.each([1, 2], fn(_x) { Nil })
}

pub fn generic_recv(list: a) -> Nil {
  list.each([1, 2], fn(_x) { Nil })
}
"
  list.each(["fn_recv", "tuple_recv", "generic_recv"], fn(function) {
    shadow_effect_line("shadow_fieldless_" <> function, source, function)
    |> string.contains("Unknown")
    |> should.be_false()
  })
}

pub fn a_narrowed_variant_field_stays_charged_test() {
  // `map` is on `A` only, and the clause narrows `list` to `A`, so the field is
  // real and effectful. Reading it as `gleam/list.map` would report it pure —
  // the undercharge the "on no variant" rule exists to prevent.
  shadow_effect_line(
    "shadow_narrowed_variant",
    "import gleam/list

pub type Partial {
  A(map: fn(String) -> String)
  B(n: Int)
}

pub fn shadowed(p: Partial) -> String {
  case p {
    A(..) as list -> list.map(\"hello\")
    B(..) -> \"\"
  }
}
",
    "shadowed",
  )
  |> string.contains("Unknown")
  |> should.be_true()
}

pub fn a_wired_field_on_a_shadowing_name_keeps_its_effect_test() {
  // The undercharge the shadowed-receiver rule closed in the first place: a
  // record with a printing `to_string` field, bound to a name that shadows
  // `gleam/int`. Its effect must still be charged.
  shadow_effect_line(
    "shadow_wired_field",
    "import gleam/int
import gleam/io

pub type Fmt {
  Fmt(to_string: fn(String) -> Nil)
}

pub fn shout(message: String) -> Nil {
  io.println(message)
}

pub fn shadowed() -> Nil {
  let int = Fmt(to_string: shout)
  int.to_string(\"hi\")
}
",
    "shadowed",
  )
  |> string.contains("effects ext.shadowed : [Stdout]")
  |> should.be_true()
}

pub fn a_shadowed_receiver_in_a_fallback_body_reads_as_the_module_test() {
  // A fallback body is walked through `walk_fallbacks`, which builds its own
  // module context — the accessor index has to reach that path too.
  let root =
    support.write_fixture("build/shadow_fallback", [
      #("gleam.toml", support.dual_target_toml("proj")),
      #("manifest.toml", stdlib_manifest),
      #(
        "ext.gleam",
        "import gleam/io
import gleam/result

pub type Thing {
  Thing(n: Int)
}

@external(erlang, \"ext_ffi\", \"shadowed\")
pub fn shadowed(result: Thing, r: Result(Int, Nil)) -> Result(Int, Nil) {
  use v <- result.try(r)
  io.println(\"hi\")
  Ok(v + result.n)
}
",
      ),
    ])
  let assert Ok(answered) = graded.run_effect(root, "ext.shadowed")
  // The declaration's own `[Unknown]` stays; the walked body contributes
  // `[Stdout]` and no `Unknown` of its own.
  answered |> string.contains("Stdout") |> should.be_true()
  support.cleanup(root)
}

// A path dependency's own source, inferred with no girard types at all — the
// syntactic annotation is the only evidence there is.
fn path_dep_effect_line(
  name: String,
  dep_source: String,
  function: String,
) -> String {
  let app_root = "build/" <> name <> "_app"
  let dep_root = "build/" <> name <> "_dep"
  support.write_fixture(dep_root, [
    #("gleam.toml", "name = \"dep\"\n"),
    #("src/dep.gleam", dep_source),
  ])
  let _ = simplifile.write(dep_root <> "/manifest.toml", stdlib_manifest)
  support.write_fixture(app_root, [
    #(
      "gleam.toml",
      "name = \"app\"\n\n[dependencies]\ndep = { path = \"../"
        <> name
        <> "_dep\" }\n",
    ),
    #("manifest.toml", stdlib_manifest),
    #("app.gleam", "import dep\n\npub fn caller() -> Nil {\n  Nil\n}\n"),
  ])
  let assert Ok(answered) = graded.run_effect(app_root, "dep." <> function)
  support.cleanup(app_root)
  support.cleanup(dep_root)
  answered
}

pub fn a_path_dependency_annotated_receiver_reads_as_the_module_test() {
  // Path-dependency inference is handed empty type maps, so the annotation is
  // the whole answer — and it must reclassify there exactly as in the project.
  path_dep_effect_line(
    "shadow_path_dep",
    "import gleam/io
import gleam/list

pub type Thing {
  Thing(n: Int)
}

pub fn shadowed(list: Thing) -> Nil {
  io.println(\"hi\")
  list.each([1, 2], fn(_x) { Nil })
}
",
    "shadowed",
  )
  |> string.contains("effects dep.shadowed : [Stdout]")
  |> should.be_true()
}

pub fn a_path_dependency_rebound_receiver_stays_charged_test() {
  // The liveness gate with no girard to fall back on: `Runner(..) as list`
  // names the clause's value, so the parameter's `Empty` annotation says
  // nothing. Read through it, `map` is on no variant and the effectful field
  // would be charged as a pure `gleam/list.map`.
  path_dep_effect_line(
    "shadow_path_dep_rebound",
    "import gleam/list

pub type Empty {
  Empty(n: Int)
}

pub type Runner {
  Runner(map: fn(String) -> String)
}

pub fn shadowed(list: Empty, r: Runner) -> String {
  case r {
    Runner(..) as list -> list.map(\"hi\")
  }
}
",
    "shadowed",
  )
  |> string.contains("Unknown")
  |> should.be_true()
}

pub fn a_path_dependency_let_rebound_receiver_stays_charged_test() {
  // A `let` rebinding is already covered by the provenance gate: the receiver
  // roots at `r`, not at the `list` the annotation names, so the field stays a
  // field — here a polymorphic one. Resolved to `gleam/list.map` the answer
  // would be a flat `[]`.
  path_dep_effect_line(
    "shadow_path_dep_let_rebound",
    "import gleam/list

pub type Empty {
  Empty(n: Int)
}

pub type Runner {
  Runner(map: fn(String) -> String)
}

pub fn shadowed(list: Empty, r: Runner) -> String {
  let list = r
  list.map(\"hi\")
}
",
    "shadowed",
  )
  |> string.contains("effects dep.shadowed(r.map: [r.map]) : [r.map]")
  |> should.be_true()
}
