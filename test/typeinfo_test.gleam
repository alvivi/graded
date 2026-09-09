// Tests for `graded/internal/typeinfo` — the index of girard's per-expression
// types and per-reference resolutions that the checker reads out of. Two
// properties carry the module and are pinned here: every lookup miss answers
// with an empty value rather than an error, which is what keeps girard a pure
// enhancement layer, and both maps key on the full `#(start, end)` span, so
// neighbouring expressions or accesses sharing one offset never resolve to
// each other's answer.

import girard.{Fn, LocalVariable, ModuleFn, Named, RecordField, Tuple, Var}
import glance
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import gleeunit/should
import graded/internal/checker
import graded/internal/typeinfo
import qcheck

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
        #("app/log", index([#(#(0, 3), Named("app/log", "Logger", []))])),
        #("app/count", index([#(#(0, 3), Named("app/count", "Counter", []))])),
      ],
      [],
      [],
      [],
      set.new(),
      set.new(),
    )
  typeinfo.receiver_type(typeinfo.for_module(info, "app/log"), 0, 3)
  |> should.equal(Some(#("app/log", "Logger")))
  typeinfo.receiver_type(typeinfo.for_module(info, "app/count"), 0, 3)
  |> should.equal(Some(#("app/count", "Counter")))
}

pub fn a_module_with_types_but_no_fn_typed_entry_reads_empty_test() {
  let info =
    typeinfo.from_modules(
      [#("app/log", index([#(#(0, 3), Named("app/log", "Logger", []))]))],
      [],
      [],
      [],
      set.new(),
      set.new(),
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
      set.new(),
      set.new(),
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
      [#("app/log", index([#(#(0, 3), Named("app/log", "Logger", []))]))],
      [],
      [],
      [],
      set.new(),
      set.new(),
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
      set.new(),
      set.new(),
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
      set.new(),
      set.new(),
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
    index([#(#(10, 11), Named("app/log", "Logger", []))]),
    10,
    11,
  )
  |> should.equal(Some(#("app/log", "Logger")))
}

pub fn a_named_types_arguments_do_not_change_its_identity_test() {
  typeinfo.receiver_type(
    index([
      #(#(0, 6), Named("gleam", "List", [Named("gleam", "Int", [])])),
    ]),
    0,
    6,
  )
  |> should.equal(Some(#("gleam", "List")))
}

pub fn spans_sharing_a_start_resolve_apart_test() {
  let module_types =
    index([
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
    index([
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
    index([#(#(10, 11), Named("app/log", "Logger", []))]),
    10,
    12,
  )
  |> should.equal(None)
}

pub fn a_span_with_the_wrong_start_does_not_resolve_test() {
  typeinfo.receiver_type(
    index([
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
    index([#(#(10, 11), Named("app/log", "Logger", []))]),
    30,
    34,
  )
  |> should.equal(None)
}

pub fn a_function_type_resolves_to_none_test() {
  typeinfo.receiver_type(
    index([#(#(0, 4), Fn([], Named("app/log", "Logger", [])))]),
    0,
    4,
  )
  |> should.equal(None)
}

pub fn a_type_variable_resolves_to_none_test() {
  typeinfo.receiver_type(index([#(#(0, 4), Var(0))]), 0, 4)
  |> should.equal(None)
}

pub fn a_tuple_type_resolves_to_none_test() {
  typeinfo.receiver_type(
    index([
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
  evidence.unlocated |> should.equal([])
  evidence.dropped |> should.equal(set.new())
}

pub fn from_modules_serves_each_module_its_own_evidence_test() {
  let info =
    typeinfo.from_modules(
      [],
      [],
      [
        #(
          "app/log",
          typeinfo.ModuleEvidence(
            resolutions: index([#(#(0, 9), ModuleFn("gleam/io", "println"))]),
            skipped: skips([#(#(10, 39), "ArityMismatch")]),
            unlocated: [],
            dropped: set.new(),
          ),
        ),
        #(
          "app/count",
          typeinfo.ModuleEvidence(
            resolutions: index([
              #(#(0, 9), RecordField(Named("app/count", "Counter", []), "bump")),
            ]),
            skipped: dict.new(),
            unlocated: [],
            dropped: set.from_list([#(40, 79)]),
          ),
        ),
      ],
      [],
      set.new(),
      set.new(),
    )
  let log = typeinfo.evidence_for_module(info, "app/log")
  typeinfo.resolution_at(log.resolutions, 0, 9)
  |> should.equal(Some(ModuleFn("gleam/io", "println")))
  typeinfo.skip_reason(log.skipped, 10, 39)
  |> should.equal(Some("ArityMismatch"))
  typeinfo.is_dropped(log.dropped, 40, 79) |> should.be_false()

  let count = typeinfo.evidence_for_module(info, "app/count")
  typeinfo.resolution_at(count.resolutions, 0, 9)
  |> should.equal(Some(RecordField(Named("app/count", "Counter", []), "bump")))
  typeinfo.skip_reason(count.skipped, 10, 39) |> should.equal(None)
  typeinfo.is_dropped(count.dropped, 40, 79) |> should.be_true()
}

pub fn an_unknown_module_has_no_evidence_test() {
  let info =
    typeinfo.from_modules(
      [],
      [],
      [
        #(
          "app/log",
          typeinfo.ModuleEvidence(
            resolutions: index([#(#(0, 9), ModuleFn("gleam/io", "println"))]),
            skipped: skips([#(#(10, 39), "ArityMismatch")]),
            unlocated: [],
            dropped: set.from_list([#(40, 79)]),
          ),
        ),
      ],
      [],
      set.new(),
      set.new(),
    )
  let evidence = typeinfo.evidence_for_module(info, "app/other")
  typeinfo.resolution_at(evidence.resolutions, 0, 9) |> should.equal(None)
  typeinfo.skip_reason(evidence.skipped, 10, 39) |> should.equal(None)
  typeinfo.is_dropped(evidence.dropped, 40, 79) |> should.be_false()
}

pub fn a_function_girard_typed_has_no_skip_reason_test() {
  typeinfo.skip_reason(skips([#(#(10, 39), "ArityMismatch")]), 40, 79)
  |> should.equal(None)
}

// Skips keyed by the definition they name
//
// girard names a declined definition by name; the reading keys it by the span
// of the definition of that name the run kept, so a `@target` pair's two halves
// never share a skip, and functions and constants are told apart by kind.

pub fn a_skip_lands_on_its_own_definitions_span_test() {
  let source = "const a = 1\nconst b = 2\npub fn render() -> Int { 3 }\n"
  let assert Ok(module) = glance.module(source)
  let evidence =
    typeinfo.evidence_of(
      skipped_result([
        #("render", girard.ArityMismatch),
        #("a", girard.NotARecord),
        #("b", girard.NotATuple),
      ]),
      checker.error_bucket,
      module,
      girard.Erlang,
    )
  evidence.unlocated |> should.equal([])
  dict.size(evidence.skipped) |> should.equal(3)
  dict.values(evidence.skipped)
  |> list.sort(string.compare)
  |> should.equal(["ArityMismatch", "NotARecord", "NotATuple"])
  typeinfo.skip_reason(
    evidence.skipped,
    span_of(module, "render").0,
    span_of(module, "render").1,
  )
  |> should.equal(Some("ArityMismatch"))
}

pub fn a_skip_lands_on_the_half_the_run_builds_test() {
  let source =
    "@target(erlang)\npub fn render() -> Int { 1 }\n\n@target(javascript)\npub fn render() -> Int { 2 }\n"
  let assert Ok(module) = glance.module(source)
  // glance holds definitions in reverse source order, so the halves are told
  // apart by the target their own attribute names rather than by position.
  let assert [erlang_half, javascript_half] =
    list.map(["erlang", "javascript"], fn(target) {
      let assert Ok(definition) =
        list.find(module.functions, fn(definition) {
          list.any(definition.attributes, fn(attribute) {
            case attribute.name, attribute.arguments {
              "target", [glance.Variable(name: named, ..)] -> named == target
              _, _ -> False
            }
          })
        })
      let location = { definition.definition }.location
      #(location.start, location.end)
    })
  let skip = [#("render", girard.ArityMismatch)]
  let on_erlang =
    typeinfo.evidence_of(
      skipped_result(skip),
      checker.error_bucket,
      module,
      girard.Erlang,
    )
  typeinfo.skip_reason(on_erlang.skipped, erlang_half.0, erlang_half.1)
  |> should.equal(Some("ArityMismatch"))
  typeinfo.skip_reason(on_erlang.skipped, javascript_half.0, javascript_half.1)
  |> should.equal(None)

  let on_javascript =
    typeinfo.evidence_of(
      skipped_result(skip),
      checker.error_bucket,
      module,
      girard.JavaScript,
    )
  typeinfo.skip_reason(
    on_javascript.skipped,
    javascript_half.0,
    javascript_half.1,
  )
  |> should.equal(Some("ArityMismatch"))
  typeinfo.skip_reason(on_javascript.skipped, erlang_half.0, erlang_half.1)
  |> should.equal(None)
}

pub fn a_skip_naming_no_definition_is_kept_whole_test() {
  // Two unplaced skips are two entries: nothing folds them onto one sentinel
  // span, where the second would overwrite the first.
  let assert Ok(module) = glance.module("pub fn render() -> Int { 1 }\n")
  let evidence =
    typeinfo.evidence_of(
      skipped_result([
        #("helper", girard.NotARecord),
        #("other", girard.NotATuple),
      ]),
      checker.error_bucket,
      module,
      girard.Erlang,
    )
  evidence.skipped |> should.equal(dict.new())
  evidence.unlocated
  |> should.equal([#("helper", "NotARecord"), #("other", "NotATuple")])
}

// A `ModuleResult` that annotated nothing and declined the named definitions.
fn skipped_result(
  skipped: List(#(String, girard.Error)),
) -> girard.ModuleResult {
  girard.ModuleResult(
    annotated: girard.AnnotatedModule(
      functions: [],
      constants: [],
      expressions: [],
      resolutions: [],
      dropped: [],
    ),
    skipped:,
  )
}

// The `#(start, end)` span of the named function in a parsed module.
fn span_of(module: glance.Module, name: String) -> #(Int, Int) {
  let assert Ok(definition) =
    list.find(module.functions, fn(def) { { def.definition }.name == name })
  let location = { definition.definition }.location
  #(location.start, location.end)
}

// Resolution spans
//
// The key is the whole access, so the receiver's own span and the enclosing
// call's — which share an offset with it — never answer for the access.

pub fn a_resolution_resolves_on_an_exact_span_test() {
  typeinfo.resolution_at(
    index([#(#(10, 19), ModuleFn("gleam/io", "println"))]),
    10,
    19,
  )
  |> should.equal(Some(ModuleFn("gleam/io", "println")))
}

pub fn resolution_spans_sharing_a_start_resolve_apart_test() {
  let module_resolutions =
    index([
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
    index([
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
    index([#(#(10, 19), ModuleFn("gleam/io", "println"))]),
    10,
    20,
  )
  |> should.equal(None)
}

pub fn a_resolution_span_with_the_wrong_start_does_not_resolve_test() {
  typeinfo.resolution_at(
    index([#(#(10, 19), ModuleFn("gleam/io", "println"))]),
    11,
    19,
  )
  |> should.equal(None)
}

pub fn an_absent_resolution_span_resolves_to_none_test() {
  typeinfo.resolution_at(
    index([#(#(10, 19), ModuleFn("gleam/io", "println"))]),
    30,
    39,
  )
  |> should.equal(None)
}

// The whole reading of one module
//
// All three slices are taken for the same module and travel together, so a
// caller asks once and cannot pair one module's types with another's evidence.

pub fn a_readings_slices_are_the_modules_own_test() {
  let info =
    typeinfo.from_modules(
      [#("app/log", index([#(#(0, 3), Named("app/log", "Logger", []))]))],
      [#("app/log", dict.from_list([#("render", set.from_list(["format"]))]))],
      [
        #(
          "app/log",
          typeinfo.ModuleEvidence(
            resolutions: index([#(#(0, 9), ModuleFn("gleam/io", "println"))]),
            skipped: skips([#(#(10, 39), "ArityMismatch")]),
            unlocated: [],
            dropped: set.from_list([#(40, 79)]),
          ),
        ),
      ],
      [],
      set.new(),
      set.new(),
    )
  let reading = typeinfo.reading_for_module(info, "app/log")
  typeinfo.receiver_type(reading.expressions, 0, 3)
  |> should.equal(Some(#("app/log", "Logger")))
  typeinfo.fn_typed_params(reading.fn_typed, "render")
  |> should.equal(set.from_list(["format"]))
  typeinfo.resolution_at(reading.evidence.resolutions, 0, 9)
  |> should.equal(Some(ModuleFn("gleam/io", "println")))
  typeinfo.skip_reason(reading.evidence.skipped, 10, 39)
  |> should.equal(Some("ArityMismatch"))
  typeinfo.is_dropped(reading.evidence.dropped, 40, 79) |> should.be_true()
}

pub fn an_unread_module_yields_the_empty_reading_test() {
  typeinfo.reading_for_module(typeinfo.none(), "any/module")
  |> should.equal(typeinfo.no_reading())
}

// The merge
//
// `merge_readings` takes the primary reading whole and adds, from the
// secondary, only what lies inside a definition the primary left out. The
// asymmetry is the point: the primary is the reading, and the secondary exists
// to fill holes the primary run could not have filled.

pub fn a_secondary_entry_inside_a_hole_is_added_test() {
  let merged =
    merge(
      reading(
        dropped: [#(100, 200)],
        expressions: [],
        resolutions: [],
        skips: [],
      ),
      reading(
        dropped: [],
        expressions: [#(#(110, 113), Named("app/log", "Logger", []))],
        resolutions: [#(#(120, 131), ModuleFn("gleam/io", "println"))],
        skips: [#(#(140, 150), "ArityMismatch")],
      ),
    )
  typeinfo.type_at(merged.expressions, 110, 113)
  |> should.equal(Some(Named("app/log", "Logger", [])))
  typeinfo.resolution_at(merged.evidence.resolutions, 120, 131)
  |> should.equal(Some(ModuleFn("gleam/io", "println")))
  typeinfo.skip_reason(merged.evidence.skipped, 140, 150)
  |> should.equal(Some("ArityMismatch"))
}

pub fn a_secondary_entry_outside_every_hole_is_discarded_test() {
  // Discarded even though the primary answers nothing at that span: an entry
  // outside a hole is a reading of a definition the primary run built, and the
  // primary's silence there is its own answer.
  let merged =
    merge(
      reading(
        dropped: [#(100, 200)],
        expressions: [],
        resolutions: [],
        skips: [],
      ),
      reading(
        dropped: [],
        expressions: [#(#(10, 13), Named("app/log", "Logger", []))],
        resolutions: [#(#(20, 31), ModuleFn("gleam/io", "println"))],
        skips: [#(#(40, 50), "ArityMismatch")],
      ),
    )
  typeinfo.type_at(merged.expressions, 10, 13) |> should.equal(None)
  typeinfo.resolution_at(merged.evidence.resolutions, 20, 31)
  |> should.equal(None)
  typeinfo.skip_reason(merged.evidence.skipped, 40, 50) |> should.equal(None)
}

pub fn a_primary_entry_is_never_replaced_test() {
  // The secondary carries a *different* resolution at the same span, inside a
  // hole: the primary's answer stands whatever the secondary says.
  let merged =
    merge(
      reading(
        dropped: [#(100, 200)],
        expressions: [#(#(110, 113), Named("app/log", "Logger", []))],
        resolutions: [#(#(120, 131), ModuleFn("gleam/io", "println"))],
        skips: [],
      ),
      reading(
        dropped: [],
        expressions: [#(#(110, 113), Named("app/log", "Silent", []))],
        resolutions: [#(#(120, 131), ModuleFn("gleam/erlang", "format"))],
        skips: [],
      ),
    )
  typeinfo.type_at(merged.expressions, 110, 113)
  |> should.equal(Some(Named("app/log", "Logger", [])))
  typeinfo.resolution_at(merged.evidence.resolutions, 120, 131)
  |> should.equal(Some(ModuleFn("gleam/io", "println")))
}

pub fn a_secondary_skip_never_unseats_a_primary_proof_test() {
  // A function both runs kept can type on the primary and fail on the
  // secondary — a helper it calls exists on one target only. Importing that
  // skip would move a proved charge to `[Unknown]`.
  let merged =
    merge(
      reading(
        dropped: [],
        expressions: [],
        resolutions: [#(#(20, 31), ModuleFn("gleam/io", "println"))],
        skips: [],
      ),
      reading(dropped: [], expressions: [], resolutions: [], skips: [
        #(#(0, 40), "TypeMismatch"),
      ]),
    )
  typeinfo.skip_reason(merged.evidence.skipped, 0, 40) |> should.equal(None)
  typeinfo.resolution_at(merged.evidence.resolutions, 20, 31)
  |> should.equal(Some(ModuleFn("gleam/io", "println")))
}

pub fn a_primary_skip_survives_a_secondary_that_typed_it_test() {
  let merged =
    merge(
      reading(dropped: [], expressions: [], resolutions: [], skips: [
        #(#(0, 40), "TypeMismatch"),
      ]),
      reading(
        dropped: [],
        expressions: [],
        resolutions: [#(#(20, 31), ModuleFn("gleam/io", "println"))],
        skips: [],
      ),
    )
  typeinfo.skip_reason(merged.evidence.skipped, 0, 40)
  |> should.equal(Some("TypeMismatch"))
}

pub fn two_skips_on_one_definition_keep_the_primarys_test() {
  let merged =
    merge(
      reading(dropped: [#(0, 40)], expressions: [], resolutions: [], skips: [
        #(#(0, 40), "TypeMismatch"),
      ]),
      reading(dropped: [], expressions: [], resolutions: [], skips: [
        #(#(0, 40), "ArityMismatch"),
      ]),
    )
  typeinfo.skip_reason(merged.evidence.skipped, 0, 40)
  |> should.equal(Some("TypeMismatch"))
}

pub fn the_merged_drops_are_the_intersection_test() {
  // A definition both runs left out is still left out; one the secondary run
  // built is not.
  let merged =
    merge(
      reading(
        dropped: [#(0, 40), #(100, 200)],
        expressions: [],
        resolutions: [],
        skips: [],
      ),
      reading(
        dropped: [#(0, 40), #(300, 400)],
        expressions: [],
        resolutions: [],
        skips: [],
      ),
    )
  merged.evidence.dropped |> should.equal(set.from_list([#(0, 40)]))
}

pub fn an_empty_secondary_clears_the_primarys_drops_test() {
  // Why a module the second run returned nothing for bypasses the merge
  // altogether: intersecting the primary's drops with an empty set would read
  // the definitions the second run never typed as typed ones.
  let merged =
    merge(
      reading(
        dropped: [#(100, 200)],
        expressions: [],
        resolutions: [],
        skips: [],
      ),
      reading(dropped: [], expressions: [], resolutions: [], skips: []),
    )
  merged.evidence.dropped |> should.equal(set.new())
}

pub fn the_secondarys_unlocated_skips_are_discarded_test() {
  // An unlocated skip names no span, so nothing can place it in a hole.
  let primary =
    reading(dropped: [#(100, 200)], expressions: [], resolutions: [], skips: [])
  let secondary =
    reading(dropped: [], expressions: [], resolutions: [], skips: [])
  let secondary =
    typeinfo.ModuleReading(
      ..secondary,
      evidence: typeinfo.ModuleEvidence(..secondary.evidence, unlocated: [
        #("helper", "NoSuchField"),
      ]),
    )
  merge(primary, secondary).evidence.unlocated
  |> should.equal([])
}

pub fn a_gated_functions_fn_typed_signature_is_imported_test() {
  // The positive `fn_typed` case: a name the primary lacks, whose secondary
  // definition sits inside a hole.
  let merged =
    merge_definitions(
      reading(
        dropped: [#(100, 200)],
        expressions: [],
        resolutions: [],
        skips: [],
      ),
      with_fn_typed(
        reading(dropped: [], expressions: [], resolutions: [], skips: []),
        [#("dropped", set.from_list(["f"]))],
      ),
      [#("dropped", #(100, 200))],
    )
  typeinfo.fn_typed_params(merged.fn_typed, "dropped")
  |> should.equal(set.from_list(["f"]))
}

pub fn an_ungated_functions_fn_typed_signature_is_not_imported_test() {
  // The negative case the name-keyed map alone cannot tell from the positive
  // one: an ordinary function the primary *skipped* and the secondary typed.
  // Its definition is outside every hole, so its signature is the wrong run's.
  let merged =
    merge_definitions(
      reading(dropped: [#(100, 200)], expressions: [], resolutions: [], skips: [
        #(#(0, 40), "TypeMismatch"),
      ]),
      with_fn_typed(
        reading(dropped: [], expressions: [], resolutions: [], skips: []),
        [#("each", set.from_list(["f"]))],
      ),
      [#("each", #(0, 40))],
    )
  typeinfo.fn_typed_params(merged.fn_typed, "each") |> should.equal(set.new())
}

// A secondary entry is added exactly when it lies inside a primary-dropped
// span and the primary answers nothing there — the claim a handful of chosen
// spans under-tests.
pub fn merge_adds_exactly_the_entries_inside_a_hole_test() {
  use scenario <- qcheck.given(merge_scenario_gen())
  let #(holes, primary_spans, secondary_spans) = scenario
  let merged =
    merge(
      reading(
        dropped: holes,
        expressions: [],
        resolutions: list.map(primary_spans, fn(span) {
          #(span, ModuleFn("gleam/io", "println"))
        }),
        skips: [],
      ),
      reading(
        dropped: [],
        expressions: [],
        resolutions: list.map(secondary_spans, fn(span) {
          #(span, ModuleFn("gleam/erlang", "format"))
        }),
        skips: [],
      ),
    )
  list.each(secondary_spans, fn(span) {
    let inside =
      list.any(holes, fn(hole) { span.0 >= hole.0 && span.1 <= hole.1 })
    let expected = case list.contains(primary_spans, span), inside {
      True, _ -> Some(ModuleFn("gleam/io", "println"))
      False, True -> Some(ModuleFn("gleam/erlang", "format"))
      False, False -> None
    }
    typeinfo.resolution_at(merged.evidence.resolutions, span.0, span.1)
    |> should.equal(expected)
  })
  list.each(primary_spans, fn(span) {
    typeinfo.resolution_at(merged.evidence.resolutions, span.0, span.1)
    |> should.equal(Some(ModuleFn("gleam/io", "println")))
  })
}

// Holes, primary spans and secondary spans drawn from one small offset pool, so
// generated spans land inside and outside holes and collide across the two
// runs often enough to matter.
fn merge_scenario_gen() -> qcheck.Generator(
  #(List(#(Int, Int)), List(#(Int, Int)), List(#(Int, Int))),
) {
  use holes <- qcheck.bind(qcheck.generic_list(
    span_gen(),
    qcheck.bounded_int(0, 3),
  ))
  use primary_spans <- qcheck.bind(qcheck.generic_list(
    span_gen(),
    qcheck.bounded_int(0, 4),
  ))
  use secondary_spans <- qcheck.bind(qcheck.generic_list(
    span_gen(),
    qcheck.bounded_int(0, 4),
  ))
  qcheck.return(#(holes, primary_spans, secondary_spans))
}

fn span_gen() -> qcheck.Generator(#(Int, Int)) {
  use start <- qcheck.bind(qcheck.bounded_int(0, 20))
  use length <- qcheck.bind(qcheck.bounded_int(0, 10))
  qcheck.return(#(start, start + length))
}

// A merge of two readings where no name-keyed fn-typed entry is in play, so the
// secondary run's kept-definition spans say nothing.
fn merge(
  primary: typeinfo.ModuleReading,
  secondary: typeinfo.ModuleReading,
) -> typeinfo.ModuleReading {
  typeinfo.merge_readings(primary, secondary, dict.new())
}

// The same merge with the secondary run's kept-definition spans, which place
// its fn-typed names inside or outside a hole.
fn merge_definitions(
  primary: typeinfo.ModuleReading,
  secondary: typeinfo.ModuleReading,
  definitions: List(#(String, #(Int, Int))),
) -> typeinfo.ModuleReading {
  typeinfo.merge_readings(primary, secondary, dict.from_list(definitions))
}

// A reading with no fn-typed signatures — what every merge case above starts
// from.
fn reading(
  dropped dropped: List(#(Int, Int)),
  expressions expressions: List(#(#(Int, Int), girard.Type)),
  resolutions resolutions: List(#(#(Int, Int), girard.Resolution)),
  skips skip_entries: List(#(#(Int, Int), String)),
) -> typeinfo.ModuleReading {
  typeinfo.ModuleReading(
    expressions: dict.from_list(expressions),
    fn_typed: dict.new(),
    evidence: typeinfo.ModuleEvidence(
      resolutions: dict.from_list(resolutions),
      skipped: skips(skip_entries),
      unlocated: [],
      dropped: set.from_list(dropped),
    ),
  )
}

// The same reading with a fn-typed map.
fn with_fn_typed(
  reading: typeinfo.ModuleReading,
  fn_typed: List(#(String, set.Set(String))),
) -> typeinfo.ModuleReading {
  typeinfo.ModuleReading(..reading, fn_typed: dict.from_list(fn_typed))
}

// One module's span-keyed slice — of types, or of resolutions.
fn index(entries: List(#(#(Int, Int), a))) -> Dict(#(Int, Int), a) {
  dict.from_list(entries)
}

// A span-keyed skip map from `#(span, bucket)` pairs.
fn skips(entries: List(#(#(Int, Int), String))) -> Dict(#(Int, Int), String) {
  dict.from_list(entries)
}
