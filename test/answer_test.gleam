import gleam/option.{None, Some}
import gleam/set
import gleeunit/should
import graded/internal/answer
import graded/internal/types.{Declared, ParamBound, TAbs, TLabels, TUnion, TVar}

// Rendering one lookup
//
// Both formats read the same structured answer, so they may differ in wording
// but never in what they report. The prose renderer states only what the answer
// proves: causality when the term is a bound variable, a total otherwise.

fn labels(names: List(String)) -> types.EffectTerm {
  TLabels(set.from_list(names))
}

fn function(
  bounds: List(types.ParamBound),
  term: types.EffectTerm,
) -> answer.EffectAnswer {
  answer.FunctionAnswer(
    name: "app.run",
    module: "app",
    bounds:,
    term:,
    source: answer.FunctionEntry,
  )
}

fn prose(answer_value: answer.EffectAnswer) -> String {
  answer.render(answer_value, answer.Prose)
}

// Effects a function forwards from an argument

pub fn a_bare_bound_variable_forwards_test() {
  // The term is exactly the bound variable, so every effect is the argument's.
  function([ParamBound("f", TVar("f"))], TVar("f"))
  |> prose
  |> should.equal(
    "app.run does whatever its `f` argument does, and nothing of its own",
  )
}

pub fn a_bound_variable_beside_labels_forwards_and_adds_test() {
  function(
    [ParamBound("f", TVar("f"))],
    TUnion([TVar("f"), labels(["Stdout"])]),
  )
  |> prose
  |> should.equal(
    "app.run does whatever its `f` argument does, plus [Stdout] of its own",
  )
}

pub fn a_ground_term_beside_a_bound_states_a_total_test() {
  // `effects app.run(f: [Stdout]) : [Stdout]` records a total and a bound, not
  // a cause: `run` may do the [Stdout] itself. Prose may not claim the effects
  // came from `f`.
  function([ParamBound("f", labels(["Stdout"]))], labels(["Stdout"]))
  |> prose
  |> should.equal(
    "app.run has effects [Stdout]
  calls to argument `f` are treated as having effects [Stdout]",
  )
}

pub fn an_unbound_variable_does_not_forward_test() {
  // A variable no bound binds isn't an argument's effect, so there is nothing
  // to attribute it to.
  function([], TVar("g"))
  |> prose
  |> should.equal("app.run has effects [g]")
}

pub fn a_two_variable_union_states_a_total_test() {
  // Prose characterizes one forwarded argument; two is a shape it doesn't
  // describe, so it states the term instead of picking one.
  function(
    [ParamBound("f", TVar("f")), ParamBound("g", TVar("g"))],
    TUnion([TVar("f"), TVar("g")]),
  )
  |> prose
  |> should.equal("app.run has effects [f, g]")
}

pub fn an_operator_bound_is_quoted_not_collapsed_test() {
  // A second-order bound has no effect set to state; collapsing it would report
  // `[Unknown]` for a bound that is symbolic, not unresolved.
  function([ParamBound("f", TAbs("a", TVar("a")))], labels(["Stdout"]))
  |> prose
  |> should.equal(
    "app.run has effects [Stdout]
  argument `f` carries the operator bound `f: fn(a) -> [a]`",
  )
}

// Totals

pub fn an_empty_set_is_an_answer_test() {
  function([], labels([]))
  |> prose
  |> should.equal("app.run has no effects ([])")
}

pub fn a_wholly_unknown_term_reads_as_undetermined_test() {
  function([], labels(["Unknown"]))
  |> prose
  |> should.equal(
    "app.run was found, but its effects could not be determined: [Unknown]",
  )
}

pub fn a_partly_unknown_term_keeps_what_resolved_test() {
  // Part of the set did resolve; the wholly-unknown sentence would misreport it.
  function([], labels(["Stdout", "Unknown"]))
  |> prose
  |> should.equal(
    "app.run has effects [Stdout, Unknown]; part of them could not be determined",
  )
}

// Provenance

pub fn a_module_level_external_states_its_precedence_test() {
  // The declaration answers for names nothing else keys — not for every name in
  // the module regardless.
  answer.FunctionAnswer(
    name: "fake_clock.now",
    module: "fake_clock",
    bounds: [],
    term: labels(["Time"]),
    source: answer.ModuleExternalEntry,
  )
  |> prose
  |> should.equal(
    "fake_clock.now has effects [Time]
  source: module-level external for `fake_clock`
          used when no per-function entry exists",
  )
}

pub fn a_type_field_names_its_kind_test() {
  answer.TypeFieldAnswer(
    module: Some("myapp/repo"),
    type_name: "Repo",
    field: "find",
    term: labels(["Storage"]),
    origin: Declared,
  )
  |> prose
  |> should.equal(
    "field `find` on type `Repo` (myapp/repo) has effects [Storage]
  source: declared by a `type` line",
  )
}

pub fn a_bare_type_field_carries_no_module_test() {
  answer.TypeFieldAnswer(
    module: None,
    type_name: "Box",
    field: "run",
    term: labels(["Disk"]),
    origin: Declared,
  )
  |> prose
  |> should.equal(
    "field `run` on type `Box` has effects [Disk]
  source: declared by a `type` line",
  )
}

// The `.graded` renderer

pub fn the_graded_renderer_writes_spec_syntax_test() {
  function([ParamBound("f", TVar("f"))], TVar("f"))
  |> answer.render(answer.Graded)
  |> should.equal("effects app.run(f: [f]) : [f]")
}

pub fn the_formats_report_the_same_effects_test() {
  // Wording may differ; the effect set may not.
  let answer_value = function([], labels(["Stdout", "Time"]))
  answer.render(answer_value, answer.Graded)
  |> should.equal("effects app.run : [Stdout, Time]")
  answer.render(answer_value, answer.Prose)
  |> should.equal("app.run has effects [Stdout, Time]")
}
