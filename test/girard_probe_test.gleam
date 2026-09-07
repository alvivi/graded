// The probe's coverage accounting
//
// What "girard-typed functions" counts. A definition left out of the build for
// the other target was never walked, so it is neither typed nor skipped, and a
// module girard declined outright contributes none of its functions either.
// girard drops constants beside functions, so the typed count subtracts the
// function half alone — the constants were never in a function count.

import girard
import girard_probe
import glance
import gleam/dict
import gleeunit/should
import graded/internal/types

// One module holding a `@target(javascript)` constant, a `@target(javascript)`
// function and a function of every build: typed for Erlang, girard drops two
// definitions of which one is a function.
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

pub fn a_dropped_function_is_not_counted_as_typed_test() {
  let assert Ok(module) = glance.module(target_gated)
  let entries = [#("app", module)]
  let counted =
    girard_probe.coverage(
      entries,
      girard.annotate_package(entries, girard.default_options()),
    )
  counted.functions |> should.equal(2)
  counted.walked_functions |> should.equal(2)
  counted.skipped |> should.equal([])
  counted.dropped_definitions |> should.equal(2)
  counted.dropped_functions |> should.equal(1)
  girard_probe.typed_functions(counted) |> should.equal(1)
}

pub fn a_module_girard_returned_nothing_for_counts_no_typed_function_test() {
  // The package's own function total still reports every module's functions;
  // only the walked count drops the module girard has no result for.
  let assert Ok(module) = glance.module(target_gated)
  let counted = girard_probe.coverage([#("app", module)], dict.new())
  counted.functions |> should.equal(2)
  counted.walked_functions |> should.equal(0)
  girard_probe.typed_functions(counted) |> should.equal(0)
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
