import filepath
import gleam/list
import gleam/result
import gleam/string
import gleeunit/should
import graded
import graded/internal/annotation
import graded/internal/answer
import graded/internal/cli
import graded/internal/config
import simplifile
import support.{cleanup, write_fixture}

// The `effect` query command
//
// End-to-end lookups against test/fixtures: both name forms, the provenance
// comments, the not-found cases, and the defining requirement that nothing is
// written.

const fixtures = "test/fixtures"

// Every `Ok` output is `.graded` syntax, comment lines included, so it can be
// fed straight back to the parser. Asserting that here keeps the metadata
// lines from drifting into a shape the spec parser rejects.
fn should_parse(output: String) -> String {
  annotation.parse_file(output <> "\n") |> should.be_ok
  output
}

fn lookup(name: String) -> String {
  let assert Ok(output) = graded.run_effect(fixtures, name)
  should_parse(output)
}

pub fn known_function_test() {
  lookup("impure_view.view")
  |> should.equal(
    "effects impure_view.view : [Stdout]\n// resolved from your spec",
  )
}

pub fn function_known_as_unknown_is_found_test() {
  // `[Unknown]` is a resolved answer, not a miss: the query must report it
  // rather than claim the function doesn't exist.
  lookup("shadow_field.go")
  |> should.equal(
    "effects shadow_field.go : [Unknown]\n// resolved from your spec",
  )
}

pub fn a_committed_effects_line_does_not_answer_for_an_external_test() {
  // The spec carries `effects external_budget.stale_inferred : []`, left behind
  // by a function that became an `@external`. It is inference over a body the
  // foreign implementation needn't match, so it answers here no more than it
  // answers `check` or `why`: the query reports the same `[Unknown]` those do,
  // and credits no source for it.
  lookup("external_budget.stale_inferred")
  |> should.equal(
    "effects external_budget.stale_inferred : [Unknown]\n// an external with no declared effects",
  )
  let assert Ok(prose) =
    graded.run_effect_formatted(
      fixtures,
      "external_budget.stale_inferred",
      graded.Prose,
    )
  prose
  |> should.equal(
    "external_budget.stale_inferred has effects that could not be determined: [Unknown]\n  source: an external with no declared effects",
  )
  // A declaration still answers: the rule is about which entry won, not about
  // the name.
  lookup("external_budget.declared_within_budget")
  |> should.equal(
    "effects external_budget.declared_within_budget : [Time]\n// resolved from your spec's `assume` line",
  )
}

pub fn declared_type_field_test() {
  lookup("opaque_receiver.Validator.to_error")
  |> should.equal(
    "assume opaque_receiver.Validator.to_error : [Stdout]\n// assumed by a field `assume` in your spec",
  )
}

pub fn unspecced_function_resolves_from_memory_test() {
  // `external_same_module.read_clock` has no `effects` line in the spec, so it
  // can only resolve through the in-memory inference pass — no prior
  // `graded infer` needed.
  lookup("external_same_module.read_clock")
  |> should.equal(
    "effects external_same_module.read_clock : [Time]\n// resolved from in-memory inference",
  )
}

pub fn function_level_external_test() {
  lookup("external_same_module.now")
  |> should.equal(
    "effects external_same_module.now : [Time]\n// resolved from your spec's `assume` line",
  )
}

pub fn module_level_external_fallback_is_labelled_test() {
  // `assume fake_clock : [Time]` declares a whole module, so any
  // function name under it resolves through the module-level fallback.
  lookup("fake_clock.now")
  |> should.equal(
    "effects fake_clock.now : [Time]\n// resolved via module-level `assume` for fake_clock",
  )
}

pub fn unknown_name_is_not_found_test() {
  graded.run_effect(fixtures, "no_such.thing")
  |> should.equal(Error(graded.EffectNotFound("no_such.thing")))
}

pub fn bare_name_is_not_found_test() {
  graded.run_effect(fixtures, "view")
  |> should.equal(Error(graded.EffectNotFound("view")))
}

pub fn private_function_is_not_found_test() {
  // `nested_higher_order.middle` is private, so it is no part of the public API
  // the command answers for.
  graded.run_effect(fixtures, "nested_higher_order.middle")
  |> should.equal(Error(graded.EffectNotFound("nested_higher_order.middle")))
}

pub fn a_private_function_with_a_committed_line_is_not_found_test() {
  // `builder_shadow.disk_resolver` is private and the spec carries an `effects`
  // line for it. Publicity is a fact of the source, and it decides the question
  // before any entry is weighed — otherwise a hand-written line would export a
  // name the package does not.
  graded.run_effect(fixtures, "builder_shadow.disk_resolver")
  |> should.equal(Error(graded.EffectNotFound("builder_shadow.disk_resolver")))
  graded.run_effect_from_project(fixtures, "builder_shadow.disk_resolver")
  |> should.equal(Error(graded.EffectNotFound("builder_shadow.disk_resolver")))
}

pub fn a_name_no_project_module_defines_is_not_found_test() {
  // A line naming nothing — a typo, or a function since deleted. Its module is
  // one of this package's and parses, so the absence is evidence: the package
  // defines no such name, however precise the line's effect set reads.
  graded.run_effect(fixtures, "impure_view.no_such_function")
  |> should.equal(Error(graded.EffectNotFound("impure_view.no_such_function")))
  graded.run_effect_from_project(fixtures, "impure_view.no_such_function")
  |> should.equal(Error(graded.EffectNotFound("impure_view.no_such_function")))
}

pub fn private_external_is_not_found_test() {
  // `ffi_external.hidden_ffi` is a private `@external`. Being foreign code is
  // not what makes a name queryable: the command answers for the public API,
  // so a private external reports the same miss the private ordinary function
  // above does, rather than the `[Unknown]` a public undeclared one carries.
  graded.run_effect(fixtures, "ffi_external.hidden_ffi")
  |> should.equal(Error(graded.EffectNotFound("ffi_external.hidden_ffi")))
  // The public undeclared external in the same module still answers, so the
  // gate is on publicity and not on the rule that governs foreign code.
  lookup("ffi_external.ffi_op")
  |> should.equal(
    "effects ffi_external.ffi_op : [Unknown]\n// an external with no declared effects",
  )
}

pub fn a_private_external_with_a_declaration_is_not_found_test() {
  // A private `@external` its own spec declares. A declaration describes what
  // the foreign code does for the callers that reach it; it does not export the
  // name, so the query still declines — and callers still charge the [Time].
  let project =
    write_fixture("/tmp/graded_effect_private_declared", [
      #("gleam.toml", "name = \"probe\"\nversion = \"1.0.0\"\n"),
      #("probe.graded", "assume m.hidden : [Time]\n"),
      #(
        "src/m.gleam",
        "@target(erlang)
@external(erlang, \"x\", \"hidden\")
fn hidden() -> Nil

@target(erlang)
pub fn shown() -> Nil {
  hidden()
}
",
      ),
    ])
  graded.run_effect(project, "m.hidden")
  |> should.equal(Error(graded.EffectNotFound("m.hidden")))
  graded.run_effect_from_project(project, "m.hidden")
  |> should.equal(Error(graded.EffectNotFound("m.hidden")))
  // The public caller still resolves it, so nothing about caller resolution moved.
  graded.run_effect(project, "m.shown")
  |> should.equal(Ok(
    "effects m.shown : [Time]\n// resolved from in-memory inference",
  ))
  cleanup(project)
}

pub fn a_module_level_external_does_not_export_a_project_name_test() {
  // The documented carve-out — a module-level external answers for any name in
  // its module — is what a module graded has no source for needs. Where the
  // source is here, publicity outranks it: the private ordinary function, the
  // private `@external`, and a name the module does not define all decline,
  // with and without a per-function entry, while the public function answers
  // from the declaration as before.
  let project =
    write_fixture("/tmp/graded_effect_module_external_scope", [
      #("gleam.toml", "name = \"probe\"\nversion = \"1.0.0\"\n"),
      #(
        "probe.graded",
        "assume m : [Disk]\nassume m.hidden_ffi : [Time]\neffects m.helper : []\nassume offsite : [Http]\n",
      ),
      #(
        "src/m.gleam",
        "@target(erlang)
@external(erlang, \"x\", \"hidden_ffi\")
fn hidden_ffi() -> Nil

fn helper() -> Nil {
  Nil
}

@target(erlang)
pub fn run() -> Nil {
  hidden_ffi()
  helper()
}
",
      ),
    ])
  [
    #("m.hidden_ffi", Error(graded.EffectNotFound("m.hidden_ffi"))),
    #("m.helper", Error(graded.EffectNotFound("m.helper"))),
    #("m.absent", Error(graded.EffectNotFound("m.absent"))),
    #(
      "m.run",
      Ok("effects m.run : [Disk]\n// resolved via module-level `assume` for m"),
    ),
    // A module with no source to consult keeps the carve-out whole.
    #(
      "offsite.anything",
      Ok(
        "effects offsite.anything : [Http]\n// resolved via module-level `assume` for offsite",
      ),
    ),
  ]
  |> list.each(fn(expected) {
    let #(name, answer) = expected
    graded.run_effect(project, name) |> should.equal(answer)
    graded.run_effect_from_project(project, name) |> should.equal(answer)
  })
  cleanup(project)
}

// Higher-order bounds
//
// A polymorphic effect term is useless without the bounds that bind its
// variables, so both are rendered — and both must come from the same
// annotation source.

pub fn freshly_inferred_bounds_are_rendered_test() {
  lookup("nested_higher_order.apply_twice")
  |> should.equal(
    "effects nested_higher_order.apply_twice(f: [f]) : [f]\n// resolved from in-memory inference",
  )
}

pub fn committed_bounds_win_as_a_pair_test() {
  // The spec commits `pure_forward(g: [g]) : [g]` while the source parameter is
  // named `f`. The committed bounds travel with the committed term, so the
  // query renders `g` on both sides rather than a mixed pair.
  lookup("nested_higher_order.pure_forward")
  |> should.equal(
    "effects nested_higher_order.pure_forward(g: [g]) : [g]\n// resolved from your spec",
  )
}

pub fn check_line_bounds_stay_out_of_the_knowledge_base_test() {
  // `check factory_forward.caller(resolver: [Stdout])` is a budget for that
  // check, not a fact about the function: the query renders the inferred
  // bound instead.
  let output = lookup("factory_forward.caller")
  output
  |> should.equal(
    "effects factory_forward.caller(resolver: [resolver]) : [resolver]\n// resolved from in-memory inference",
  )
  string.contains(output, "[Stdout]") |> should.be_false
}

pub fn external_suppresses_stale_committed_bounds_test() {
  // The spec holds both `assume external_same_module.now : [Time]`
  // and a stale `effects external_same_module.now(cb: [cb]) : [cb]`. The
  // external is authoritative, so neither the stale term nor its bounds show.
  let output = lookup("external_same_module.now")
  string.contains(output, "cb") |> should.be_false
}

pub fn bound_less_committed_line_suppresses_inferred_bounds_test() {
  // `log_and_map` is higher-order in source, so inference derives `(f: [f])`.
  // Its committed line carries no bounds, so it decides both halves: gap-filling
  // the inferred ones would pair a first-order committed term with a variable
  // nothing in that term mentions.
  let output = lookup("nested_higher_order.log_and_map")
  output
  |> should.equal(
    "effects nested_higher_order.log_and_map : [Stdout]\n// resolved from your spec",
  )
  string.contains(output, "f:") |> should.be_false
}

// Name grammar
//
// A spec function name has exactly one dot — module paths use slashes. Reading
// one any looser lets a malformed line claim a name that belongs to another
// annotation kind. Both cases below are malformed or dead spec states, so they
// get their own throwaway project rather than a line in the shared fixture.

// A project holding just a spec file. No `gleam.toml`, so the spec path comes
// from the directory's own name, exactly as `test/fixtures` resolves its own.
fn spec_only_project(name: String, spec: String) -> String {
  let package = "graded_effect_" <> name
  write_fixture("/tmp/" <> package, [
    #(package <> ".graded", spec),
    #("box.gleam", "pub type Box {\n  Box(run: fn() -> Nil)\n}\n"),
  ])
}

pub fn dotted_module_effects_line_does_not_shadow_a_type_line_test() {
  // A malformed 3-segment `effects` line beside the real field `assume` line for the
  // same field. Split on the last dot it would key itself under the module
  // `box.Box` and answer first; the function grammar rejects it instead, so the
  // field `assume` line still answers.
  let project =
    spec_only_project(
      "shadow",
      "assume box.Box.run : [Stdout]\neffects box.Box.run : [Disk]\n",
    )
  let assert Ok(output) = graded.run_effect(project, "box.Box.run")
  should_parse(output)
  |> should.equal(
    "assume box.Box.run : [Stdout]\n// assumed by a field `assume` in your spec",
  )
  cleanup(project)
}

pub fn bare_type_line_answers_both_query_forms_test() {
  // A bare `type Box.run` line is keyed under no module. Both the bare query
  // and a module-qualified one find it, and the answer is rendered in the bare
  // form that declared it — the form that parses back to the same line.
  let project = spec_only_project("bare", "assume Box.run : [Disk]\n")
  let bare =
    "assume Box.run : [Disk]\n// assumed by a field `assume` in your spec"
  let assert Ok(qualified_query) = graded.run_effect(project, "box.Box.run")
  let assert Ok(bare_query) = graded.run_effect(project, "Box.run")
  should_parse(qualified_query) |> should.equal(bare)
  should_parse(bare_query) |> should.equal(bare)
  cleanup(project)
}

// The spec-only fast path
//
// A name the spec decides is answered without parsing the package. That is only
// sound if it gives the same answer the full project context would.

pub fn spec_fast_path_matches_the_full_project_context_test() {
  // One name per kind the fast path claims, plus two it must decline: a name
  // needing the in-memory pass, and one the spec never mentions.
  //
  // The rendered provenance is part of the compared output, so a committed
  // line (`impure_view.view`) and an external (`external_same_module.now`) also
  // pin that both paths tag the same origin — they fold the spec through the
  // same writers.
  [
    "impure_view.view",
    "nested_higher_order.pure_forward",
    "nested_higher_order.log_and_map",
    "external_same_module.now",
    "fake_clock.now",
    "opaque_receiver.Validator.to_error",
    "external_same_module.read_clock",
    // An `@external` the spec carries a stale `effects` line for: which of this
    // package's functions are foreign is a fact of its source, so the fast path
    // has to consult that source to answer it as the full context does.
    "external_budget.stale_inferred",
    // A private `@external`: both paths learn its publicity from that same
    // source, so both decline it rather than one answering `[Unknown]`.
    "ffi_external.hidden_ffi",
    // A private ordinary function the spec carries a line for, and a line
    // naming nothing at all: publicity and existence are facts of the source
    // too, so both paths have to consult it to decline them together.
    "builder_shadow.disk_resolver",
    "impure_view.no_such_function",
    "no_such.thing",
  ]
  |> list.each(fn(name) {
    graded.run_effect(fixtures, name)
    |> should.equal(graded.run_effect_from_project(fixtures, name))
  })
}

pub fn dependency_type_field_outranks_a_bare_project_line_test() {
  // The project declares the field bare — keyed under no module, so a qualified
  // query falls back to it — while an installed dependency declares the same
  // field under its real module. Only the full knowledge base holds the
  // dependency's line, and its exact key outranks the bare fallback, so the
  // spec alone does not decide this name and the fast path must decline it.
  let project =
    write_fixture("/tmp/graded_effect_depfield", [
      #("gleam.toml", "name = \"probe\"\nversion = \"1.0.0\"\n"),
      #("probe.graded", "assume Repo.find : [Disk]\n"),
      #("build/packages/dep/dep.graded", "assume dep.Repo.find : [Storage]\n"),
      #("src/app.gleam", "pub fn go() -> Nil {\n  Nil\n}\n"),
    ])
  let expected =
    "assume dep.Repo.find : [Storage]\n// assumed by a field `assume` in dep's shipped spec"
  graded.run_effect(project, "dep.Repo.find")
  |> should.equal(Ok(expected))
  graded.run_effect_from_project(project, "dep.Repo.find")
  |> should.equal(Ok(expected))
  cleanup(project)
}

pub fn a_path_dependency_answer_names_the_dependency_test() {
  // A path dep's committed spec decides `dep.shout`; the answer says which
  // package that was, so a reader knows the line to edit is the dep's, not
  // this project's.
  let dep_dir =
    write_fixture("/tmp/graded_effect_pathdep_dep", [
      #("gleam.toml", "name = \"dep\"\n"),
      #("dep.graded", "effects dep.shout : [Stdout]\n"),
      #(
        "src/dep.gleam",
        "import gleam/io\n\npub fn shout() -> Nil {\n  io.println(\"x\")\n}\n",
      ),
    ])
  let app_dir =
    write_fixture("/tmp/graded_effect_pathdep_app", [
      #(
        "gleam.toml",
        "name = \"app\"\n\n[dependencies]\ndep = { path = \""
          <> dep_dir
          <> "\" }\n",
      ),
      #("app.graded", ""),
      #("src/main.gleam", "pub fn run() -> Nil {\n  Nil\n}\n"),
    ])

  graded.run_effect_from_project(app_dir, "dep.shout")
  |> should.equal(Ok(
    "effects dep.shout : [Stdout]\n// resolved from path dependency dep",
  ))

  cleanup(dep_dir)
  cleanup(app_dir)
}

// Output formats
//
// Prose is what the CLI prints by default; `--format=graded` is the spec syntax
// every other test in this module asserts. Both render one structured answer,
// so they may differ in wording but never in what they report.

fn prose(name: String) -> String {
  let assert Ok(output) =
    graded.run_effect_formatted(fixtures, name, graded.Prose)
  output
}

pub fn prose_states_a_resolved_effect_test() {
  prose("impure_view.view")
  |> should.equal("impure_view.view has effects [Stdout]\n  source: your spec")
}

pub fn prose_attributes_a_forwarded_effect_test() {
  // The committed term is exactly the bound variable, so the effects are the
  // argument's. The sentence attributes effects, not calls: the term doesn't
  // prove `pure_forward` ever applies `g`.
  prose("nested_higher_order.pure_forward")
  |> should.equal(
    "nested_higher_order.pure_forward has the effects of its `g` argument, and none of its own\n  source: your spec",
  )
}

pub fn prose_states_an_undetermined_effect_test() {
  // `[Unknown]` is a resolved answer, and prose says which part of it graded
  // couldn't settle. A name that isn't there is the error path, not this.
  prose("shadow_field.go")
  |> should.equal(
    "shadow_field.go has effects that could not be determined: [Unknown]\n  source: your spec",
  )
}

pub fn prose_states_module_external_precedence_test() {
  prose("fake_clock.now")
  |> should.equal(
    "fake_clock.now has effects [Time]
  source: module-level `assume` for `fake_clock`
          used when no per-function entry exists",
  )
}

// Both formats' answers for a dependency `@external` declared only for a target
// this build does not compile. `body` is what the declaration sits over — `""`
// for a bodiless one, a Gleam block for one the build runs in its place.
fn out_of_reach_outputs(name: String, body: String) -> #(String, String) {
  let project =
    write_fixture("build/" <> name, [
      #("gleam.toml", "name = \"" <> name <> "\"\ntarget = \"erlang\"\n"),
      #(name <> ".graded", ""),
      #("build/packages/dep/dep.graded", "assume dep/ffi.run : [Time]\n"),
      #(
        "build/packages/dep/src/dep/ffi.gleam",
        "@external(javascript, \"dep_ffi\", \"run\")\npub fn run() -> Nil"
          <> body
          <> "\n",
      ),
    ])
  let assert Ok(prose_output) =
    graded.run_effect_formatted(project, "dep/ffi.run", graded.Prose)
  let assert Ok(graded_output) =
    graded.run_effect_formatted(project, "dep/ffi.run", graded.Graded)
  cleanup(project)
  #(prose_output, graded_output)
}

pub fn prose_names_an_out_of_reach_declaration_test() {
  // The dependency ships a declaration for JavaScript, this package names
  // Erlang, and `run` has no Gleam body to run in its place — so the charge is
  // the `[Unknown]` of a name nothing in reach implements. Carrying the
  // declaration's source beside it credited dep's shipped `[Time]` line with a
  // set that line states no part of, sending the reader to a declaration the
  // answer had just ruled out.
  out_of_reach_outputs("graded_effect_out_of_reach", "")
  |> should.equal(#(
    "dep/ffi.run has effects that could not be determined: [Unknown]
  source: an external declared only for a target this build does not compile",
    "effects dep/ffi.run : [Unknown]
// an external declared only for a target this build does not compile",
  ))
}

pub fn prose_names_the_body_running_in_a_declarations_place_test() {
  // The same out-of-reach declaration, except `run` has a Gleam body to run in
  // its place. That body is the whole of what the build reaches, so it is named
  // as the source rather than beside one — no `plus its Gleam fallback body`
  // line, which would read as a half added to a declaration that pays for none
  // of it. Walked, and it does nothing, so the answer is the empty set rather
  // than a guess about a dependency's body.
  out_of_reach_outputs("graded_effect_fallback_in_reach", " {\n  Nil\n}")
  |> should.equal(#(
    "dep/ffi.run is pure — no effects ([])
  source: its Gleam fallback body, which is what runs on the targets this build compiles",
    "effects dep/ffi.run : []
// its Gleam fallback body, which is what runs on the targets this build compiles",
  ))
}

pub fn an_undeclared_external_states_its_running_fallback_test() {
  // Nothing declares `raw.op`, and its Gleam body runs on the target its
  // `@external` leaves uncovered. The answer is the `[Unknown]` an undeclared
  // external carries unioned with what that body does, and the body is named
  // apart from that half so neither is credited with the other's effects.
  let project =
    write_fixture("build/graded_effect_undeclared_fallback", [
      #(
        "gleam.toml",
        support.dual_target_toml("graded_effect_undeclared_fallback"),
      ),
      #(
        "graded_effect_undeclared_fallback.graded",
        "assume ffi.disk : [Disk]\n",
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

@external(javascript, \"e\", \"o\")
pub fn op() -> Nil {
  ffi.disk()
}
",
      ),
    ])
  let assert Ok(prose_output) =
    graded.run_effect_formatted(project, "raw.op", graded.Prose)
  prose_output
  |> should.equal(
    "raw.op has effects [Disk, Unknown]; part of them could not be determined
  source: an external with no declared effects
  plus its Gleam fallback body, which runs on the targets its `@external` declares no implementation for: [Disk]",
  )
  let assert Ok(graded_output) =
    graded.run_effect_formatted(project, "raw.op", graded.Graded)
  graded_output
  |> should_parse
  |> should.equal(
    "effects raw.op : [Disk, Unknown]
// an external with no declared effects
// unioned with its Gleam fallback body, which runs on the targets its `@external` declares no implementation for: [Disk]",
  )
  cleanup(project)
}

pub fn prose_names_a_type_field_as_a_field_test() {
  prose("opaque_receiver.Validator.to_error")
  |> should.equal(
    "field `to_error` on type `Validator` (opaque_receiver) has effects [Stdout]
  source: assumed by a field `assume` in your spec",
  )
}

pub fn graded_format_still_round_trips_test() {
  // The parseable contract now belongs to `--format=graded`, and holds for the
  // provenance-carrying answers too.
  let assert Ok(output) =
    graded.run_effect_formatted(fixtures, "fake_clock.now", graded.Graded)
  should_parse(output)
  |> should.equal(
    "effects fake_clock.now : [Time]\n// resolved via module-level `assume` for fake_clock",
  )
}

pub fn the_formats_agree_on_the_effect_set_test() {
  // Every name the suite queries, in both formats: whatever the wording, the
  // rendered effect set has to appear in each.
  ["impure_view.view", "fake_clock.now", "external_same_module.read_clock"]
  |> list.each(fn(name) {
    let assert Ok(graded_output) =
      graded.run_effect_formatted(fixtures, name, graded.Graded)
    let assert Ok(prose_output) =
      graded.run_effect_formatted(fixtures, name, graded.Prose)
    let assert Ok(effect_set) = string.split_once(graded_output, " : ")
    let assert Ok(#(rendered, _)) =
      string.split_once(effect_set.1 <> "\n", "\n")
    string.contains(prose_output, rendered) |> should.be_true
  })
}

// Argument decoding
//
// `main`'s branches print and exit, so the rules for `graded effect`'s
// arguments are pinned on the pure decoder behind them.

pub fn parse_effect_args_requires_a_name_test() {
  cli.parse_effect_args([])
  |> should.equal(Error(cli.MissingName("effect")))
  cli.format_argument_error(cli.MissingName("effect"))
  |> should.equal("missing name for `effect`")
}

pub fn parse_effect_args_defaults_the_directory_test() {
  cli.parse_effect_args(["a.b"])
  |> should.equal(Ok(#("a.b", "src", answer.Prose)))
}

pub fn parse_effect_args_takes_a_directory_test() {
  cli.parse_effect_args(["a.b", "dir"])
  |> should.equal(Ok(#("a.b", "dir", answer.Prose)))
}

pub fn parse_effect_args_defaults_to_prose_test() {
  // The flagless invocation is the one a person types, so it gets the format a
  // person reads.
  let assert Ok(#(_, _, format)) = cli.parse_effect_args(["a.b"])
  format |> should.equal(answer.Prose)
}

pub fn parse_effect_args_takes_a_format_test() {
  cli.parse_effect_args(["a.b", "--format=graded"])
  |> should.equal(Ok(#("a.b", "src", answer.Graded)))
  cli.parse_effect_args(["a.b", "dir", "--format=prose"])
  |> should.equal(Ok(#("a.b", "dir", answer.Prose)))
}

pub fn parse_effect_args_takes_a_format_anywhere_test() {
  // `--format` qualifies the output rather than filling a position, so it may
  // precede the name without being read as one.
  cli.parse_effect_args(["--format=graded", "a.b", "dir"])
  |> should.equal(Ok(#("a.b", "dir", answer.Graded)))
}

pub fn parse_effect_args_rejects_an_unknown_format_test() {
  cli.parse_effect_args(["a.b", "--format=json"])
  |> should.equal(Error(cli.UnknownFormat("json")))
  cli.format_argument_error(cli.UnknownFormat("json"))
  |> should.equal("unknown format `json` (expected `prose` or `graded`)")
}

pub fn parse_effect_args_rejects_a_flag_name_test() {
  cli.parse_effect_args(["-x"])
  |> should.equal(Error(cli.UnknownOption("-x")))
  cli.format_argument_error(cli.UnknownOption("-x"))
  |> should.equal("unknown option `-x`")
}

pub fn parse_effect_args_rejects_a_flag_directory_test() {
  cli.parse_effect_args(["a.b", "-x"])
  |> should.equal(Error(cli.UnknownOption("-x")))
}

pub fn parse_effect_args_rejects_a_third_argument_test() {
  cli.parse_effect_args(["a.b", "dir", "extra"])
  |> should.equal(Error(cli.UnexpectedArgument("extra")))
  cli.format_argument_error(cli.UnexpectedArgument("extra"))
  |> should.equal("unexpected argument `extra`")
}

// The directory rule `effect` composes with, shared with check/infer/format/pack.

pub fn parse_directory_args_defaults_to_src_test() {
  cli.parse_directory_args([]) |> should.equal(Ok("src"))
}

pub fn parse_directory_args_takes_one_directory_test() {
  cli.parse_directory_args(["dir"]) |> should.equal(Ok("dir"))
}

pub fn parse_directory_args_rejects_a_flag_test() {
  cli.parse_directory_args(["--quiet"])
  |> should.equal(Error(cli.UnknownOption("--quiet")))
}

pub fn parse_directory_args_rejects_a_second_directory_test() {
  cli.parse_directory_args(["dir", "--quiet"])
  |> should.equal(Error(cli.UnexpectedArgument("--quiet")))
}

// Read-only
//
// The command exists to answer without touching the project. Every other test
// checks a return value, which a query that rewrote the spec would still pass.

pub fn effect_query_writes_nothing_test() {
  let spec_path = filepath.join(fixtures, config.default_spec_file("fixtures"))
  let cache_path = filepath.join(fixtures, config.default_cache_dir())
  let before = #(simplifile.read(spec_path), directory_snapshot(cache_path))

  // An unspecced name, so the in-memory inference pass runs — the code path
  // that shares the most with `graded infer`.
  let assert Ok(_) =
    graded.run_effect(fixtures, "external_same_module.read_clock")

  #(simplifile.read(spec_path), directory_snapshot(cache_path))
  |> should.equal(before)
}

// A spec file that is there but cannot be read is reported, rather than
// answering from a package that looks like it has no annotations.
pub fn effect_query_over_an_unreadable_spec_errors_test() {
  let root = "build/effect_unreadable_spec"
  write_fixture(root, [#("gleam.toml", "name = \"proj\"\n")])
  let assert Ok(Nil) = simplifile.create_directory(root <> "/proj.graded")

  graded.run_effect(root, "proj.anything")
  |> should.equal(
    Error(graded.FileReadError(root <> "/proj.graded", simplifile.Eisdir)),
  )
  cleanup(root)
}

// Every file under `path` paired with its content, sorted. `Error` when the
// directory is absent — which compares equal across a call that creates it.
fn directory_snapshot(path: String) -> Result(List(#(String, String)), Nil) {
  use entries <- result.try(
    simplifile.get_files(path) |> result.replace_error(Nil),
  )
  entries
  |> list.sort(string.compare)
  |> list.map(fn(file) { #(file, simplifile.read(file) |> result.unwrap("")) })
  |> Ok
}

// A module that will not parse
//
// The fast path answers from the spec alone only where the spec's word is
// final. It cannot be final about a module graded could not read, since the
// full context reports the parse failure instead of any effect at all.

pub fn an_unparseable_project_module_declines_the_fast_path_test() {
  // `graded check` on this tree errors; `graded effect` must too, rather than
  // quote the committed line for a module nothing could confirm it describes.
  let project =
    write_fixture("/tmp/graded_effect_unparseable", [
      #("gleam.toml", "name = \"probe\"\nversion = \"1.0.0\"\n"),
      #("probe.graded", "effects broken.foo : []\n"),
      #(
        "src/broken.gleam",
        "pub fn foo() -> Nil {\n  this is not gleam !!\n}\n",
      ),
    ])
  let broken = filepath.join(project, "src/broken.gleam")
  let parse_failure = fn(answer) {
    case answer {
      Error(graded.GleamParseError(path:, ..)) -> path
      _ -> "answered"
    }
  }

  graded.run_effect(project, "broken.foo")
  |> parse_failure
  |> should.equal(broken)
  graded.run_effect_from_project(project, "broken.foo")
  |> parse_failure
  |> should.equal(broken)
  cleanup(project)
}

pub fn a_nested_source_reads_its_targets_from_its_own_root_test() {
  // A relative source directory nested in the current project: dependency state
  // is the outer project's, but the spec, the config and the targets are this
  // directory's. Reading the targets from the dependency root instead had the
  // fast path classify `timed` under the *outer* package's `target` — where its
  // erlang declaration covers everything and no fallback runs — so it answered
  // from the declaration alone while the full context charged the body too.
  let project =
    write_fixture("build/graded_effect_nested_targets", [
      #(
        "graded_effect_nested_targets.graded",
        "assume ext.timed : [Time]
assume ext.disk : [Disk]
",
      ),
      #(
        "ext.gleam",
        "@external(erlang, \"e\", \"d\")
@external(javascript, \"e\", \"d\")
pub fn disk() -> Nil

@external(erlang, \"e\", \"t\")
pub fn timed() -> Nil {
  disk()
}
",
      ),
    ])
  // No `gleam.toml` of its own, so it is checked for every target — and the
  // erlang-only declaration leaves the Gleam body running on the other.
  let answered = graded.run_effect(project, "ext.timed")
  answered |> should.equal(graded.run_effect_from_project(project, "ext.timed"))
  let assert Ok(output) = answered
  output |> string.contains("Disk") |> should.be_true()
  cleanup(project)
}

pub fn a_module_outside_the_package_still_answers_from_the_spec_test() {
  // The other half of the tri-state: a module that is not this package's has no
  // source to consult and never will, so the spec answers alone — the parse
  // that settles a *project* module's foreign names is not attempted at all.
  let project =
    write_fixture("/tmp/graded_effect_foreign_module", [
      #("gleam.toml", "name = \"probe\"\nversion = \"1.0.0\"\n"),
      #("probe.graded", "assume other/mod.bar : [Disk]\n"),
      #("src/app.gleam", "pub fn go() -> Nil {\n  Nil\n}\n"),
    ])
  let expected =
    Ok(
      "effects other/mod.bar : [Disk]\n// resolved from your spec's `assume` line",
    )

  graded.run_effect(project, "other/mod.bar") |> should.equal(expected)
  graded.run_effect_from_project(project, "other/mod.bar")
  |> should.equal(expected)
  cleanup(project)
}

// Unparseable spec
//
// A read-only query answers from the spec, so a spec line the parser rejects
// stops it rather than being answered around.

pub fn effect_over_an_unparseable_spec_errors_test() {
  let root = "/tmp/graded_effect_unparseable"
  let _ = support.write_unparseable_spec_project(root)

  graded.run_effect(root, "proj.go")
  |> should.equal(
    Error(graded.GradedParseError(
      root <> "/proj.graded",
      annotation.describe_parse_error(annotation.InvalidLine(
        2,
        "not a graded line",
      )),
    )),
  )
  cleanup(root)
}

// A summary-less higher-order external's answer
//
// A boundless declaration over one says nothing about its callbacks, and the
// charge keeps a variable per callback parameter the parsed signature names.
// The query states that variable and the bound that scopes it, on both paths.

// A package whose one module holds a bodyless higher-order `@external`, under
// the spec line given.
fn higher_order_external_project(name: String, spec: String) -> String {
  write_fixture("build/" <> name, [
    #("gleam.toml", "name = \"" <> name <> "\"\n"),
    #(name <> ".graded", spec),
    #("ext.gleam", support.foreign_fn("run", "(action: fn() -> Nil) -> Nil")),
  ])
}

pub fn a_bodyless_externals_answer_states_its_callback_bound_test() {
  // The per-function `assume` states no bounds, so the bound that scopes the
  // callback variable comes from the pairing alone — and both paths state it.
  let project =
    higher_order_external_project(
      "graded_effect_bodyless_callback",
      "assume ext.run : [Time]\n",
    )
  let expected =
    Ok(
      "effects ext.run(action: [action]) : [Time, action]
// resolved from your spec's `assume` line",
    )
  graded.run_effect(project, "ext.run") |> should.equal(expected)
  graded.run_effect_from_project(project, "ext.run") |> should.equal(expected)
  cleanup(project)
}

pub fn a_module_assumed_externals_answer_states_its_callback_bound_test() {
  // The same under a module-level `assume`, which states no bounds of its own
  // anywhere: the answer took a running fallback's bounds there, and a bodyless
  // external has none, so the variable stood in the term with nothing scoping it.
  let project =
    higher_order_external_project(
      "graded_effect_module_assumed_callback",
      "assume ext : [Time]\n",
    )
  let expected =
    Ok(
      "effects ext.run(action: [action]) : [Time, action]
// resolved via module-level `assume` for ext",
    )
  graded.run_effect(project, "ext.run") |> should.equal(expected)
  graded.run_effect_from_project(project, "ext.run") |> should.equal(expected)
  cleanup(project)
}

pub fn a_dependency_externals_callback_answers_the_same_on_both_paths_test() {
  // The dependency half of the fast path: the module the queried name lives in
  // is parsed over there for its foreign names, and its callback parameters
  // come off that same parse. Without them the fast path answered the declared
  // term bare while the full context charged the callback beside it.
  let project =
    write_fixture("build/graded_effect_dependency_callback", [
      #("gleam.toml", "name = \"graded_effect_dependency_callback\"\n"),
      #(
        "graded_effect_dependency_callback.graded",
        "assume dep/ffi.run : [Time]\n",
      ),
      #(
        "build/packages/dep/src/dep/ffi.gleam",
        support.foreign_fn("run", "(action: fn() -> Nil) -> Nil"),
      ),
    ])
  let expected =
    Ok(
      "effects dep/ffi.run(action: [action]) : [Time, action]
// resolved from your spec's `assume` line",
    )
  graded.run_effect(project, "dep/ffi.run") |> should.equal(expected)
  graded.run_effect_from_project(project, "dep/ffi.run")
  |> should.equal(expected)
  cleanup(project)
}
