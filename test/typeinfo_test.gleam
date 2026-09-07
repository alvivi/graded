// Tests for `graded/internal/typeinfo` — the index of girard's per-expression
// types and per-reference resolutions that the checker reads out of. Two
// properties carry the module and are pinned here: every lookup miss answers
// with an empty value rather than an error, which is what keeps girard a pure
// enhancement layer, and both maps key on the full `#(start, end)` span, so
// neighbouring expressions or accesses sharing one offset never resolve to
// each other's answer.

import girard.{
  type Resolution, type Type, ArityMismatch, Fn, LocalVariable, ModuleFn, Named,
  RecordField, Tuple, Var,
}
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
      [],
      [],
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
      [],
      [],
      [],
    )
  typeinfo.receiver_type(typeinfo.for_module(info, "app/log"), 0, 3)
  |> should.equal(Some(#("app/log", "Logger")))
  typeinfo.fn_typed_for_module(info, "app/log") |> should.equal(dict.new())
}

pub fn a_module_with_fn_typed_but_no_types_reads_empty_test() {
  let info =
    typeinfo.from_modules(
      [],
      [#("app/log", dict.from_list([#("each", set.from_list(["f"]))]))],
      [],
      [],
      [],
    )
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
      [],
      [],
      [],
    )
  typeinfo.for_module(info, "app/other") |> should.equal(dict.new())
}

pub fn an_unknown_module_has_no_fn_typed_params_test() {
  let info =
    typeinfo.from_modules(
      [],
      [#("app/log", dict.from_list([#("each", set.from_list(["f"]))]))],
      [],
      [],
      [],
    )
  typeinfo.fn_typed_for_module(info, "app/other") |> should.equal(dict.new())
}

pub fn a_function_girard_did_not_type_has_no_fn_typed_params_test() {
  let info =
    typeinfo.from_modules(
      [],
      [#("app/log", dict.from_list([#("each", set.from_list(["f"]))]))],
      [],
      [],
      [],
    )
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

// girard's reading of a module
//
// The resolutions map keys on the whole access span the way the expression map
// keys on an expression's, and the two predicates over skips and drops answer
// for a module girard never saw exactly as they do for one it saw and had
// nothing to say about.

pub fn none_records_no_evidence_test() {
  let evidence = typeinfo.evidence_for_module(typeinfo.none(), "any/module")
  evidence.resolutions |> should.equal(dict.new())
  evidence.skipped |> should.equal(dict.new())
  evidence.dropped |> should.equal(set.new())
}

pub fn from_modules_serves_each_module_its_own_evidence_test() {
  let info =
    typeinfo.from_modules(
      [],
      [],
      [
        #("app/log", resolutions([#(#(0, 9), ModuleFn("gleam/io", "println"))])),
        #(
          "app/count",
          resolutions([
            #(#(0, 9), RecordField(Named("app/count", "Counter", []), "bump")),
          ]),
        ),
      ],
      [#("app/log", dict.from_list([#("render", ArityMismatch)]))],
      [#("app/count", set.from_list(["browser_only"]))],
    )
  let log = typeinfo.evidence_for_module(info, "app/log")
  typeinfo.resolution_at(log.resolutions, 0, 9)
  |> should.equal(Some(ModuleFn("gleam/io", "println")))
  typeinfo.skip_reason(log.skipped, "render")
  |> should.equal(Some(ArityMismatch))
  typeinfo.is_dropped(log.dropped, "browser_only") |> should.be_false()

  let count = typeinfo.evidence_for_module(info, "app/count")
  typeinfo.resolution_at(count.resolutions, 0, 9)
  |> should.equal(Some(RecordField(Named("app/count", "Counter", []), "bump")))
  typeinfo.skip_reason(count.skipped, "render") |> should.equal(None)
  typeinfo.is_dropped(count.dropped, "browser_only") |> should.be_true()
}

pub fn an_unknown_module_has_no_evidence_test() {
  let info =
    typeinfo.from_modules(
      [],
      [],
      [#("app/log", resolutions([#(#(0, 9), ModuleFn("gleam/io", "println"))]))],
      [#("app/log", dict.from_list([#("render", ArityMismatch)]))],
      [#("app/log", set.from_list(["browser_only"]))],
    )
  let evidence = typeinfo.evidence_for_module(info, "app/other")
  typeinfo.resolution_at(evidence.resolutions, 0, 9) |> should.equal(None)
  typeinfo.skip_reason(evidence.skipped, "render") |> should.equal(None)
  typeinfo.is_dropped(evidence.dropped, "browser_only") |> should.be_false()
}

pub fn a_function_girard_typed_has_no_skip_reason_test() {
  typeinfo.skip_reason(dict.from_list([#("render", ArityMismatch)]), "draw")
  |> should.equal(None)
}

// Resolution spans
//
// The key is the whole access, so the receiver's own span and the enclosing
// call's — which share an offset with it — never answer for the access.

pub fn a_resolution_resolves_on_an_exact_span_test() {
  typeinfo.resolution_at(
    resolutions([#(#(10, 19), ModuleFn("gleam/io", "println"))]),
    10,
    19,
  )
  |> should.equal(Some(ModuleFn("gleam/io", "println")))
}

pub fn resolution_spans_sharing_a_start_resolve_apart_test() {
  let module_resolutions =
    resolutions([
      #(#(10, 19), RecordField(Named("app/log", "Logger", []), "println")),
      #(#(10, 25), ModuleFn("gleam/io", "println")),
    ])
  typeinfo.resolution_at(module_resolutions, 10, 19)
  |> should.equal(Some(RecordField(Named("app/log", "Logger", []), "println")))
  typeinfo.resolution_at(module_resolutions, 10, 25)
  |> should.equal(Some(ModuleFn("gleam/io", "println")))
}

pub fn resolution_spans_sharing_an_end_resolve_apart_test() {
  let module_resolutions =
    resolutions([
      #(#(0, 19), ModuleFn("gleam/io", "println")),
      #(#(10, 19), LocalVariable("io")),
    ])
  typeinfo.resolution_at(module_resolutions, 0, 19)
  |> should.equal(Some(ModuleFn("gleam/io", "println")))
  typeinfo.resolution_at(module_resolutions, 10, 19)
  |> should.equal(Some(LocalVariable("io")))
}

pub fn a_resolution_span_with_the_wrong_end_does_not_resolve_test() {
  typeinfo.resolution_at(
    resolutions([#(#(10, 19), ModuleFn("gleam/io", "println"))]),
    10,
    20,
  )
  |> should.equal(None)
}

pub fn a_resolution_span_with_the_wrong_start_does_not_resolve_test() {
  typeinfo.resolution_at(
    resolutions([#(#(10, 19), ModuleFn("gleam/io", "println"))]),
    11,
    19,
  )
  |> should.equal(None)
}

pub fn an_absent_resolution_span_resolves_to_none_test() {
  typeinfo.resolution_at(
    resolutions([#(#(10, 19), ModuleFn("gleam/io", "println"))]),
    30,
    39,
  )
  |> should.equal(None)
}

// One module's span->type slice.
fn spans(entries: List(#(#(Int, Int), Type))) -> Dict(#(Int, Int), Type) {
  dict.from_list(entries)
}

// One module's access-span->resolution slice.
fn resolutions(
  entries: List(#(#(Int, Int), Resolution)),
) -> Dict(#(Int, Int), Resolution) {
  dict.from_list(entries)
}
