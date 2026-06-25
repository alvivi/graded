import gleam/list
import gleam/set
import gleeunit/should
import graded
import graded/internal/annotation
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

pub fn path_dep_module_level_external_marks_pure_test() {
  // Source-only path dep `dep` exposing a function with an opaque FFI body that
  // graded would otherwise infer as [Unknown]. The consumer spec declares the
  // whole dep module pure with a module-level `external effects dep : []`. The
  // consumer's `check caller : []` must hold: the module-level external
  // suppresses path-dep source inference for that module, so `dep.touch`
  // resolves to [] (pure) — NOT [Unknown].
  let app_root = "build/pd_modext_app"
  let dep_root = "build/pd_modext_dep"
  let _ = simplifile.delete(app_root)
  let _ = simplifile.delete(dep_root)

  let assert Ok(Nil) = simplifile.create_directory_all(dep_root <> "/src")
  let assert Ok(Nil) =
    simplifile.write(dep_root <> "/gleam.toml", "name = \"dep\"\n")
  let assert Ok(Nil) =
    simplifile.write(
      dep_root <> "/src/dep.gleam",
      "@external(erlang, \"d\", \"t\")\npub fn touch() -> Nil\n",
    )

  let assert Ok(Nil) = simplifile.create_directory_all(app_root)
  let assert Ok(Nil) =
    simplifile.write(
      app_root <> "/gleam.toml",
      "name = \"app\"\n\n[dependencies]\ndep = { path = \"../pd_modext_dep\" }\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      app_root <> "/app.graded",
      "external effects dep : []\n\ncheck app.caller : []\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      app_root <> "/app.gleam",
      "import dep\n\npub fn caller() -> Nil {\n  dep.touch()\n}\n",
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
