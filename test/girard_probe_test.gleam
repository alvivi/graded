// The probe's coverage accounting
//
// Disjoint counts read off the merged reading: within a module the inference
// read, every function and every constant is exactly one of typed, skipped or
// left out of every run; an unread module's definitions are unread, a count of
// their own. A gated function triggers the second run, so the only definition
// left out of every run is one gated with no gated function beside it.

import girard
import girard_probe
import glance
import gleam/set
import gleeunit/should
import graded
import graded/internal/typeinfo
import graded/internal/types

// One module holding a `@target(javascript)` constant, a `@target(javascript)`
// function and a function of every build.
const target_gated = "@target(javascript)
pub const mode = \"browser\"

@target(javascript)
pub fn browser_only() -> Nil {
  Nil
}

pub fn everywhere() -> Nil {
  Nil
}
"

// A module whose only gated definition is a constant: nothing triggers a second
// run, so that constant is left out of every run.
const constant_gated = "@target(javascript)
pub const mode = \"browser\"

pub fn everywhere() -> Nil {
  Nil
}
"

pub fn both_gated_halves_are_counted_as_typed_test() {
  // A gated function triggers the second run, so every definition in the module
  // is read on the target that builds it and none is left out.
  let counted = coverage_of(target_gated)
  counted.targets |> should.equal([girard.Erlang, girard.JavaScript])
  counted.modules_read |> should.equal(1)
  counted.modules_unread |> should.equal(0)
  counted.functions_typed |> should.equal(2)
  counted.functions_skipped |> should.equal([])
  counted.functions_left_out |> should.equal(0)
  counted.constants_typed |> should.equal(1)
  counted.constants_left_out |> should.equal(0)
  counted.unlocated |> should.equal([])
}

pub fn a_gated_constant_alone_is_left_out_of_every_run_test() {
  // The one count expected non-zero on a clean package, and the reason the two
  // left-out lines are printed apart.
  let counted = coverage_of(constant_gated)
  counted.targets |> should.equal([girard.Erlang])
  counted.functions_typed |> should.equal(1)
  counted.functions_left_out |> should.equal(0)
  counted.constants_typed |> should.equal(0)
  counted.constants_left_out |> should.equal(1)
}

pub fn a_module_the_inference_did_not_read_counts_its_own_test() {
  // An unread module's definitions are in no other count: a reader who sees
  // `unread` non-zero knows to look at the inference, not at graded.
  let assert Ok(module) = glance.module(target_gated)
  let counted =
    girard_probe.coverage(
      [#("app", module)],
      typeinfo.from_modules(
        [],
        [],
        [],
        [girard.Erlang],
        set.from_list(["app"]),
        set.new(),
      ),
    )
  counted.modules_read |> should.equal(0)
  counted.modules_unread |> should.equal(1)
  counted.functions_unread |> should.equal(2)
  counted.constants_unread |> should.equal(1)
  counted.functions_typed |> should.equal(0)
  counted.functions_left_out |> should.equal(0)
}

// One module's coverage through the funnel production uses, with a resolver
// that finds nothing outside it.
fn coverage_of(source: String) -> girard_probe.Coverage {
  let assert Ok(module) = glance.module(source)
  let entries = [#("app", module)]
  girard_probe.coverage(
    entries,
    graded.annotate_on_targets(
      entries,
      fn(_module_path) { Error(Nil) },
      graded.girard_targets(types.DefaultedTargets, entries),
    ),
  )
}

// The report over a package's rows
//
// Two rows the accounting has to keep apart: a resolution mismatch, where
// graded refused a target the inference proved and the row is a disagreement,
// and a dropped definition, where the inference established nothing. The
// mismatch is counted by the shadowed tally alone — the no-typed-evidence
// tally filters on the relation, which a disagreement is not.

// A row as the probe reports it: one site in `app.target`.
fn row(
  object: String,
  label: String,
  graded: types.GradedClassification,
  typed: types.TypedClassification,
) -> types.ClassificationCheck {
  types.ClassificationCheck(
    module: "app",
    function: "target",
    object:,
    label:,
    span: glance.Span(0, 1),
    graded:,
    typed:,
  )
}

pub fn the_report_counts_a_mismatch_and_a_dropped_definition_test() {
  girard_probe.report_lines([
    row(
      "list",
      "map",
      types.UndecidedShadowed(
        "gleam/list",
        types.ResolutionMismatch("gleam/list.each"),
      ),
      types.ProvedModuleCall("gleam/list", "each"),
    ),
    row(
      "io",
      "println",
      types.UndecidedShadowed("gleam/io", types.DefinitionDropped),
      types.Undecided(types.DefinitionDropped),
    ),
  ])
  |> should.equal([
    "", "ambiguous call sites: 2", "", "relations:", "  disagree: 1",
    "  no-typed-evidence:dropped: 1", "", "graded's classification x girard's:",
    "  undecided(shadowed: dropped) / undecided:dropped: 1",
    "  undecided(shadowed: resolution-mismatch(gleam/list.each)) / proved-module: 1",
    "", "sites with no typed evidence: 1", "  rate: 50.0%", "",
    "no typed evidence, by reason:", "  no-typed-evidence:dropped: 1", "",
    "undecided shadowed calls, by reason:", "  dropped: 1",
    "  resolution-mismatch(gleam/list.each): 1", "",
    "disagreements (one read the module, the other the field):", "  1",
    "app.target  list.map: typed resolution module gleam/list.each (DISAGREES with graded's [Unknown] where list also names gleam/list (resolved to gleam/list.each, which is not this site's target))",
  ])
}
