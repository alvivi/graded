// What an `assume` line's bounds mean once the function's signature is read:
// the kind of each bound's parameter, and the uses the latent-effect rules
// forbid.

import glance
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleeunit/should
import graded/internal/annotation
import graded/internal/contract
import graded/internal/signatures
import graded/internal/typedefs
import graded/internal/types.{CallbackKind, NonCallbackKind, UnknownKind}

const app_source =
  "import app/callbacks
import app/config.{type Config}

pub type Local {
  Local(on_item: fn(String) -> Nil)
}

@external(erlang, \"m\", \"run\")
pub fn run(values: List(fn() -> Nil), f: fn(fn() -> Nil) -> Nil) -> Nil

@external(erlang, \"m\", \"two\")
pub fn two(n: Int) -> Nil

@external(erlang, \"m\", \"configure\")
pub fn configure(cfg: Config, local: Local) -> Nil

@external(erlang, \"m\", \"any\")
pub fn any(x: a) -> Nil

@external(erlang, \"m\", \"bare\")
pub fn bare(x) -> Nil

@external(erlang, \"m\", \"aliased\")
pub fn aliased(cb: callbacks.Callback) -> Nil

@external(erlang, \"m\", \"labelled\")
pub fn labelled(with value: Int, _unused: Int, callback cb: fn(Int) -> Nil) -> Nil
"

fn module(source: String) -> glance.Module {
  let assert Ok(module) = glance.module(source)
  module
}

fn run_registry() -> signatures.SignatureRegistry {
  let targets = set.from_list(["erlang"])
  let app = module(app_source)
  let callbacks = module("pub type Callback = fn() -> Nil")
  let config = module("pub type Config { Config(on_item: fn(String) -> Nil) }")
  signatures.with_types(
    signatures.from_glance_module("app/ffi", app),
    typedefs.from_module("app/ffi", app, targets)
      |> typedefs.merge(typedefs.from_module(
        "app/callbacks",
        callbacks,
        targets,
      ))
      |> typedefs.merge(typedefs.from_module("app/config", config, targets)),
  )
}

fn assume(line: String) -> types.AssumeAnnotation {
  let assert Ok(types.GradedFile(lines: [types.AssumeLine(assume, _)])) =
    annotation.parse_file_with(line, types.Active)
  assume
}

fn kinds(line: String) -> List(#(String, types.BoundKind, option.Option(Int))) {
  contract.resolve_bounds(assume(line), run_registry())
  |> list.map(fn(resolved) {
    #(resolved.bound.name, resolved.kind, resolved.arity)
  })
}

fn violations(line: String) -> List(contract.ContractViolation) {
  contract.line_violations(assume(line), run_registry())
}

// Kinds

pub fn a_function_typed_parameter_is_a_callback_test() {
  kinds("assume app/ffi.run(values: [l], f: [f]) : [f]")
  |> should.equal([
    #("values", NonCallbackKind, None),
    #("f", CallbackKind, Some(1)),
  ])
}

pub fn a_nominal_parameter_holding_functions_is_not_a_callback_test() {
  kinds("assume app/ffi.configure(cfg: [c], local: [o]) : []")
  |> should.equal([
    #("cfg", NonCallbackKind, None),
    #("local", NonCallbackKind, None),
  ])
}

pub fn an_imported_function_alias_is_a_callback_test() {
  kinds("assume app/ffi.aliased(cb: [cb]) : [cb]")
  |> should.equal([#("cb", CallbackKind, Some(0))])
}

pub fn a_type_variable_or_an_unannotated_parameter_is_unknown_test() {
  kinds("assume app/ffi.any(x: [x]) : [x]")
  |> should.equal([#("x", UnknownKind, None)])
  kinds("assume app/ffi.bare(x: [x]) : [x]")
  |> should.equal([#("x", UnknownKind, None)])
}

pub fn a_missing_signature_or_an_unmatched_name_is_unknown_test() {
  kinds("assume app/ffi.nowhere(x: [x]) : [x]")
  |> should.equal([#("x", UnknownKind, None)])
  kinds("assume app/ffi.two(m: [m]) : [m]")
  |> should.equal([#("m", UnknownKind, None)])
}

pub fn a_bound_names_its_parameter_by_in_body_name_then_label_test() {
  kinds(
    "assume app/ffi.labelled(value: [a], with: [b], _unused: [c], callback: [d], cb: [e]) : []",
  )
  |> should.equal([
    #("value", NonCallbackKind, None),
    #("with", NonCallbackKind, None),
    // A discarded parameter has no in-body name for a bound to name.
    #("_unused", UnknownKind, None),
    #("callback", CallbackKind, Some(1)),
    #("cb", CallbackKind, Some(1)),
  ])
}

pub fn a_field_bound_stays_a_callable_field_test() {
  kinds("assume app/ffi.configure(cfg.on_item: [e]) : [e]")
  |> should.equal([#("cfg.on_item", CallbackKind, None)])
  violations("assume app/ffi.configure(cfg.on_item: [e]) : [e]")
  |> should.equal([])
}

// Forbidden uses

pub fn a_carried_variable_in_the_effect_term_is_forbidden_test() {
  violations("assume app/ffi.two(n: [n]) : [n]")
  |> should.equal([
    contract.CarriedVariableCharged(variable: "n", parameter: "n"),
  ])
  violations(
    "assume app/ffi.configure(cfg: [c], local: [o]) : [c] where runs : [o]",
  )
  |> should.equal([
    contract.CarriedVariableCharged(variable: "c", parameter: "cfg"),
  ])
}

pub fn an_unknown_kind_or_a_callback_alias_may_be_charged_test() {
  violations("assume app/ffi.any(x: [x]) : [x]") |> should.equal([])
  violations("assume app/ffi.aliased(cb: [cb]) : [cb([])]") |> should.equal([])
}

pub fn a_result_latent_of_a_non_callback_is_forbidden_test() {
  violations(
    "assume app/ffi.run(values: [l], f: [f]) : [] where carries : [l.returns, f.returns]",
  )
  |> should.equal([
    contract.ResultOfNonCallback(variable: "l.returns", parameter: "values"),
  ])
}

pub fn a_relay_must_match_the_callback_test() {
  violations(
    "assume app/ffi.run(values: [l], f: [f]) : [f] where relay : f(_, l)",
  )
  |> should.equal([
    contract.RelayArityMismatch(callback: "f", arity: 1, written: 2),
  ])
  violations("assume app/ffi.run(values: [l], f: [f]) : [] where relay : l(f)")
  |> should.equal([
    contract.RelayIntoNonCallback(callback: "l", parameter: "values"),
    contract.CallbackCostCarried(variable: "f", parameter: "f"),
  ])
  violations("assume app/ffi.run(values: [l], f: [f]) : [f] where relay : f(l)")
  |> should.equal([])
}

pub fn runs_names_carried_variables_only_test() {
  violations("assume app/ffi.run(values: [l], f: [f]) : [] where runs : [f]")
  |> should.equal([
    contract.CallbackCostCarried(variable: "f", parameter: "f"),
  ])
}

pub fn a_variable_shared_by_a_callback_and_a_carried_bound_is_forbidden_test() {
  violations("assume app/ffi.run(values: [e], f: [e]) : []")
  |> should.equal([contract.IncompatibleSharing(variable: "e")])
  // Two carried bounds may share one variable: it names what both carry.
  violations(
    "assume app/ffi.configure(cfg: [c], local: [c]) : [] where runs : [c]",
  )
  |> should.equal([])
}

pub fn a_parameter_a_callback_on_one_target_only_is_unknown_test() {
  let pair =
    module(
      "pub type Holder { Holder(run: fn() -> Nil) }

@target(erlang)
@external(erlang, \"m\", \"keep\")
pub fn keep(f: fn() -> Nil, n: Int) -> Nil

@target(javascript)
@external(javascript, \"./m.mjs\", \"keep\")
pub fn keep(f: Holder, n: Int) -> Nil

pub type Act = fn() -> Nil

@target(erlang)
@external(erlang, \"m\", \"both\")
pub fn both(f: Act) -> Nil

@target(javascript)
@external(javascript, \"./m.mjs\", \"both\")
pub fn both(f: fn() -> Nil) -> Nil
",
    )
  let targets = set.from_list(["erlang", "javascript"])
  let registry =
    signatures.with_types(
      signatures.from_glance_module("app/pair", pair),
      typedefs.from_module("app/pair", pair, targets),
    )
  let kinds_of = fn(line) {
    contract.resolve_bounds(assume(line), registry)
    |> list.map(fn(resolved) { #(resolved.bound.name, resolved.kind) })
  }
  kinds_of("assume app/pair.keep(f: [f], n: [n]) : [] where runs : [n]")
  |> should.equal([#("f", UnknownKind), #("n", NonCallbackKind)])
  kinds_of("assume app/pair.both(f: [f]) : [f]")
  |> should.equal([#("f", CallbackKind)])
}

// Bounds that mean nothing

pub fn a_non_callback_bound_that_is_no_variable_means_nothing_test() {
  let registry = run_registry()
  [
    "assume app/ffi.two(n: []) : []",
    "assume app/ffi.two(n: [Stdout]) : []",
    "assume app/ffi.two(n: [n]) : [] where runs : [n]",
  ]
  |> list.map(fn(line) {
    contract.resolve_bounds(assume(line), registry)
    |> contract.meaningless_bounds
  })
  |> should.equal([["n"], ["n"], []])
}
