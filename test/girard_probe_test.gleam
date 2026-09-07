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
