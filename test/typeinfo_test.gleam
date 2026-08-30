// Tests for `graded/internal/typeinfo` — the index of girard's per-expression
// types that the checker reads receiver types out of. Two properties carry the
// module and are pinned here: every lookup miss answers with an empty value
// rather than an error, which is what keeps girard a pure enhancement layer,
// and expressions key on the full `#(start, end)` span, so neighbouring
// expressions sharing one offset never resolve to each other's type.

import girard.{type Type, Fn, Named, Tuple, Var}
import gleam/dict.{type Dict}
import gleam/option.{None, Some}
import gleam/set
import gleeunit/should
import graded/internal/typeinfo

// The empty index
//
// `none()` is the index the checker runs with when type inference is
// unavailable.

pub fn none_has_no_module_types_test() {
  typeinfo.for_module(typeinfo.none(), "any/module")
  |> should.equal(dict.new())
}

pub fn none_has_no_fn_typed_params_test() {
  let module_fn_typed = typeinfo.fn_typed_for_module(typeinfo.none(), "any")
  module_fn_typed |> should.equal(dict.new())
  typeinfo.fn_typed_params(module_fn_typed, "handle")
  |> should.equal(set.new())
}

pub fn none_resolves_no_receiver_type_test() {
  typeinfo.receiver_type(
    typeinfo.for_module(typeinfo.none(), "any/module"),
    0,
    4,
  )
  |> should.equal(None)
}

// Building an index
//
// `from_modules` keeps the span map and the fn-typed map independent: neither
// is derived from, or gated on, the other.

pub fn from_modules_serves_each_module_its_own_types_test() {
  let info =
    typeinfo.from_modules(
      [
        #("app/log", spans([#(#(0, 3), Named("app/log", "Logger", []))])),
        #("app/count", spans([#(#(0, 3), Named("app/count", "Counter", []))])),
      ],
      [],
    )
  typeinfo.receiver_type(typeinfo.for_module(info, "app/log"), 0, 3)
  |> should.equal(Some(#("app/log", "Logger")))
  typeinfo.receiver_type(typeinfo.for_module(info, "app/count"), 0, 3)
  |> should.equal(Some(#("app/count", "Counter")))
}

pub fn a_module_with_types_but_no_fn_typed_entry_reads_empty_test() {
  let info =
    typeinfo.from_modules(
      [#("app/log", spans([#(#(0, 3), Named("app/log", "Logger", []))]))],
      [],
    )
  typeinfo.receiver_type(typeinfo.for_module(info, "app/log"), 0, 3)
  |> should.equal(Some(#("app/log", "Logger")))
  typeinfo.fn_typed_for_module(info, "app/log") |> should.equal(dict.new())
}

pub fn a_module_with_fn_typed_but_no_types_reads_empty_test() {
  let info =
    typeinfo.from_modules([], [
      #("app/log", dict.from_list([#("each", set.from_list(["f"]))])),
    ])
  typeinfo.fn_typed_params(
    typeinfo.fn_typed_for_module(info, "app/log"),
    "each",
  )
  |> should.equal(set.from_list(["f"]))
  typeinfo.for_module(info, "app/log") |> should.equal(dict.new())
}

// Module misses
//
// A module girard could not annotate is absent from both maps, and reads back
// the same as a module it annotated to nothing.

pub fn an_unknown_module_has_no_types_test() {
  let info =
    typeinfo.from_modules(
      [#("app/log", spans([#(#(0, 3), Named("app/log", "Logger", []))]))],
      [],
    )
  typeinfo.for_module(info, "app/other") |> should.equal(dict.new())
}

pub fn an_unknown_module_has_no_fn_typed_params_test() {
  let info =
    typeinfo.from_modules([], [
      #("app/log", dict.from_list([#("each", set.from_list(["f"]))])),
    ])
  typeinfo.fn_typed_for_module(info, "app/other") |> should.equal(dict.new())
}

pub fn a_function_girard_did_not_type_has_no_fn_typed_params_test() {
  let info =
    typeinfo.from_modules([], [
      #("app/log", dict.from_list([#("each", set.from_list(["f"]))])),
    ])
  typeinfo.fn_typed_params(
    typeinfo.fn_typed_for_module(info, "app/log"),
    "untyped",
  )
  |> should.equal(set.new())
}

// Receiver types
//
// `receiver_type` answers only for `Named` types, and only on an exact
// `#(start, end)` match.

pub fn a_named_type_resolves_to_its_module_and_name_test() {
  typeinfo.receiver_type(
    spans([#(#(10, 11), Named("app/log", "Logger", []))]),
    10,
    11,
  )
  |> should.equal(Some(#("app/log", "Logger")))
}

pub fn a_named_types_arguments_do_not_change_its_identity_test() {
  typeinfo.receiver_type(
    spans([
      #(#(0, 6), Named("gleam", "List", [Named("gleam", "Int", [])])),
    ]),
    0,
    6,
  )
  |> should.equal(Some(#("gleam", "List")))
}

pub fn spans_sharing_a_start_resolve_apart_test() {
  let module_types =
    spans([
      #(#(10, 11), Named("app/log", "Logger", [])),
      #(#(10, 17), Fn([], Named("gleam", "Nil", []))),
      #(#(10, 20), Named("gleam", "Nil", [])),
    ])
  typeinfo.receiver_type(module_types, 10, 11)
  |> should.equal(Some(#("app/log", "Logger")))
  typeinfo.receiver_type(module_types, 10, 17) |> should.equal(None)
  typeinfo.receiver_type(module_types, 10, 20)
  |> should.equal(Some(#("gleam", "Nil")))
}

pub fn spans_sharing_an_end_resolve_apart_test() {
  let module_types =
    spans([
      #(#(0, 8), Named("gleam", "Bool", [])),
      #(#(5, 8), Named("app/log", "Logger", [])),
    ])
  typeinfo.receiver_type(module_types, 0, 8)
  |> should.equal(Some(#("gleam", "Bool")))
  typeinfo.receiver_type(module_types, 5, 8)
  |> should.equal(Some(#("app/log", "Logger")))
}

pub fn a_span_with_the_wrong_end_does_not_resolve_test() {
  typeinfo.receiver_type(
    spans([#(#(10, 11), Named("app/log", "Logger", []))]),
    10,
    12,
  )
  |> should.equal(None)
}

pub fn a_span_with_the_wrong_start_does_not_resolve_test() {
  typeinfo.receiver_type(
    spans([
      #(#(0, 8), Named("gleam", "Bool", [])),
      #(#(5, 8), Named("app/log", "Logger", [])),
    ]),
    2,
    8,
  )
  |> should.equal(None)
}

pub fn an_absent_span_resolves_to_none_test() {
  typeinfo.receiver_type(
    spans([#(#(10, 11), Named("app/log", "Logger", []))]),
    30,
    34,
  )
  |> should.equal(None)
}

pub fn a_function_type_resolves_to_none_test() {
  typeinfo.receiver_type(
    spans([#(#(0, 4), Fn([], Named("app/log", "Logger", [])))]),
    0,
    4,
  )
  |> should.equal(None)
}

pub fn a_type_variable_resolves_to_none_test() {
  typeinfo.receiver_type(spans([#(#(0, 4), Var(0))]), 0, 4)
  |> should.equal(None)
}

pub fn a_tuple_type_resolves_to_none_test() {
  typeinfo.receiver_type(
    spans([
      #(#(0, 4), Tuple([Named("gleam", "Int", []), Named("gleam", "Int", [])])),
    ]),
    0,
    4,
  )
  |> should.equal(None)
}

// One module's span->type slice.
fn spans(entries: List(#(#(Int, Int), Type))) -> Dict(#(Int, Int), Type) {
  dict.from_list(entries)
}
