import assay/internal/annotation
import assay/internal/checker
import assay/internal/effects
import assay/internal/types.{
  type EffectSet, AnnotationLine, AssayFile, BlankLine, Check, CommentLine,
  EffectAnnotation, Effects, ExternalAnnotation, ExternalLine, FunctionExternal,
  ModuleExternal, ParamBound, Specific, TypeFieldAnnotation, TypeFieldLine,
  Wildcard,
}
import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/set
import gleam/string
import gleeunit/should
import qcheck

// ──── Generators ────

fn effect_set_gen() -> qcheck.Generator(EffectSet) {
  let label_gen =
    qcheck.from_generators(qcheck.return("Http"), [
      qcheck.return("Dom"),
      qcheck.return("Stdout"),
      qcheck.return("Db"),
      qcheck.return("FileSystem"),
      qcheck.return("Time"),
    ])
  let specific_gen =
    qcheck.map(qcheck.list_from(label_gen), fn(labels) {
      Specific(set.from_list(labels))
    })
  qcheck.from_weighted_generators(#(1, qcheck.return(Wildcard)), [
    #(4, specific_gen),
  ])
}

fn function_name_gen() -> qcheck.Generator(String) {
  qcheck.from_generators(qcheck.return("foo"), [
    qcheck.return("bar"),
    qcheck.return("baz"),
    qcheck.return("run"),
    qcheck.return("handle"),
    qcheck.return("process"),
  ])
}

fn kind_gen() -> qcheck.Generator(types.AnnotationKind) {
  qcheck.from_generators(qcheck.return(Effects), [qcheck.return(Check)])
}

fn param_bound_gen() -> qcheck.Generator(types.ParamBound) {
  let param_name_gen =
    qcheck.from_generators(qcheck.return("f"), [
      qcheck.return("g"),
      qcheck.return("h"),
      qcheck.return("callback"),
      qcheck.return("handler"),
    ])
  qcheck.map2(param_name_gen, effect_set_gen(), fn(name, effects) {
    ParamBound(name:, effects:)
  })
}

fn annotation_gen() -> qcheck.Generator(types.EffectAnnotation) {
  let no_params =
    qcheck.map2(
      qcheck.map2(kind_gen(), function_name_gen(), fn(k, f) { #(k, f) }),
      effect_set_gen(),
      fn(kf, effects) {
        let #(kind, function) = kf
        EffectAnnotation(kind:, function:, params: [], effects:)
      },
    )
  let with_param =
    qcheck.map2(
      qcheck.map2(kind_gen(), function_name_gen(), fn(k, f) { #(k, f) }),
      qcheck.map2(param_bound_gen(), effect_set_gen(), fn(p, e) { #(p, e) }),
      fn(kf, pe) {
        let #(kind, function) = kf
        let #(param, effects) = pe
        EffectAnnotation(kind:, function:, params: [param], effects:)
      },
    )
  qcheck.from_generators(no_params, [with_param])
}

fn type_field_gen() -> qcheck.Generator(types.TypeFieldAnnotation) {
  let type_name_gen =
    qcheck.from_generators(qcheck.return("Handler"), [
      qcheck.return("Request"),
      qcheck.return("Config"),
    ])
  let field_name_gen =
    qcheck.from_generators(qcheck.return("on_click"), [
      qcheck.return("send"),
      qcheck.return("validate"),
    ])
  qcheck.map2(
    qcheck.map2(type_name_gen, field_name_gen, fn(t, f) { #(t, f) }),
    effect_set_gen(),
    fn(tf, effects) {
      let #(type_name, field) = tf
      TypeFieldAnnotation(type_name:, field:, effects:)
    },
  )
}

fn external_gen() -> qcheck.Generator(types.ExternalAnnotation) {
  let module_name_gen =
    qcheck.from_generators(qcheck.return("gleam/io"), [
      qcheck.return("gleam/list"),
      qcheck.return("gleam/httpc"),
      qcheck.return("simplifile"),
    ])
  let module_ext =
    qcheck.map2(module_name_gen, effect_set_gen(), fn(module, effects) {
      ExternalAnnotation(module:, target: ModuleExternal, effects:)
    })
  let function_ext =
    qcheck.map2(
      qcheck.map2(module_name_gen, function_name_gen(), fn(m, f) { #(m, f) }),
      effect_set_gen(),
      fn(mf, effects) {
        let #(module, name) = mf
        ExternalAnnotation(module:, target: FunctionExternal(name), effects:)
      },
    )
  qcheck.from_generators(module_ext, [function_ext])
}

fn assay_line_gen() -> qcheck.Generator(types.AssayLine) {
  let comment_gen =
    qcheck.from_generators(qcheck.return("// TODO"), [
      qcheck.return("// Effect annotations"),
      qcheck.return("// Auto-generated"),
    ])
  qcheck.from_weighted_generators(
    #(3, qcheck.map(annotation_gen(), AnnotationLine)),
    [
      #(1, qcheck.map(type_field_gen(), TypeFieldLine)),
      #(1, qcheck.map(external_gen(), ExternalLine)),
      #(1, qcheck.map(comment_gen, CommentLine)),
      #(1, qcheck.return(BlankLine)),
    ],
  )
}

fn assay_file_gen() -> qcheck.Generator(types.AssayFile) {
  qcheck.map2(
    assay_line_gen(),
    qcheck.list_from(assay_line_gen()),
    fn(first, rest) { AssayFile(lines: [first, ..rest]) },
  )
}

// ──── Cluster 1: EffectSet Lattice Laws ────

pub fn subset_reflexivity_test() {
  use a <- qcheck.given(effect_set_gen())
  types.is_subset(a, a) |> should.be_true()
}

pub fn subset_transitivity_test() {
  use #(a, b, c) <- qcheck.given(
    qcheck.map2(
      qcheck.map2(effect_set_gen(), effect_set_gen(), fn(a, b) { #(a, b) }),
      effect_set_gen(),
      fn(ab, c) { #(ab.0, ab.1, c) },
    ),
  )
  case types.is_subset(a, b) && types.is_subset(b, c) {
    True -> types.is_subset(a, c) |> should.be_true()
    False -> Nil
  }
}

pub fn subset_antisymmetry_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(effect_set_gen(), effect_set_gen(), fn(a, b) { #(a, b) }),
  )
  case types.is_subset(a, b) && types.is_subset(b, a) {
    True -> a |> should.equal(b)
    False -> Nil
  }
}

pub fn union_commutativity_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(effect_set_gen(), effect_set_gen(), fn(a, b) { #(a, b) }),
  )
  types.union(a, b) |> should.equal(types.union(b, a))
}

pub fn union_associativity_test() {
  use #(a, b, c) <- qcheck.given(
    qcheck.map2(
      qcheck.map2(effect_set_gen(), effect_set_gen(), fn(a, b) { #(a, b) }),
      effect_set_gen(),
      fn(ab, c) { #(ab.0, ab.1, c) },
    ),
  )
  types.union(types.union(a, b), c)
  |> should.equal(types.union(a, types.union(b, c)))
}

pub fn union_idempotence_test() {
  use a <- qcheck.given(effect_set_gen())
  types.union(a, a) |> should.equal(a)
}

pub fn union_identity_test() {
  use a <- qcheck.given(effect_set_gen())
  types.union(a, types.empty()) |> should.equal(a)
}

pub fn wildcard_absorbs_union_test() {
  use a <- qcheck.given(effect_set_gen())
  types.union(Wildcard, a) |> should.equal(Wildcard)
}

pub fn empty_is_bottom_test() {
  use a <- qcheck.given(effect_set_gen())
  types.is_subset(types.empty(), a) |> should.be_true()
}

pub fn wildcard_is_top_test() {
  use a <- qcheck.given(effect_set_gen())
  types.is_subset(a, Wildcard) |> should.be_true()
}

pub fn union_monotonicity_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(effect_set_gen(), effect_set_gen(), fn(a, b) { #(a, b) }),
  )
  types.is_subset(a, types.union(a, b)) |> should.be_true()
}

pub fn subset_union_compatibility_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(effect_set_gen(), effect_set_gen(), fn(a, b) { #(a, b) }),
  )
  let subset = types.is_subset(a, b)
  let union_eq = types.union(a, b) == b
  subset |> should.equal(union_eq)
}

// ──── Cluster 2: Parse/Format Roundtrips ────

pub fn annotation_roundtrip_test() {
  use a <- qcheck.given(annotation_gen())
  let formatted = annotation.format_annotation(a)
  let assert Ok(parsed) = annotation.parse(formatted)
  parsed |> should.equal([a])
}

pub fn type_field_roundtrip_test() {
  use tf <- qcheck.given(type_field_gen())
  let formatted = annotation.format_type_field(tf)
  let assert Ok(file) = annotation.parse_file(formatted)
  let assert [TypeFieldLine(parsed)] = file.lines
  parsed |> should.equal(tf)
}

pub fn external_roundtrip_test() {
  use ext <- qcheck.given(external_gen())
  let formatted = annotation.format_external(ext)
  let assert Ok(file) = annotation.parse_file(formatted)
  let assert [ExternalLine(parsed)] = file.lines
  parsed |> should.equal(ext)
}

pub fn file_roundtrip_test() {
  use file <- qcheck.given(assay_file_gen())
  let formatted = annotation.format_file(file)
  let assert Ok(parsed) = annotation.parse_file(formatted)
  parsed |> should.equal(file)
}

pub fn format_sorted_idempotence_test() {
  use file <- qcheck.given(assay_file_gen())
  let s1 = annotation.format_sorted(file)
  let assert Ok(parsed) = annotation.parse_file(s1)
  let s2 = annotation.format_sorted(parsed)
  s1 |> should.equal(s2)
}

// ──── Generators (Cluster 3) ────

fn inferred_list_gen() -> qcheck.Generator(List(types.EffectAnnotation)) {
  let effects_ann_gen =
    qcheck.map2(function_name_gen(), effect_set_gen(), fn(function, effects) {
      EffectAnnotation(kind: Effects, function:, params: [], effects:)
    })
  qcheck.map(
    qcheck.map2(
      effects_ann_gen,
      qcheck.list_from(effects_ann_gen),
      fn(first, rest) { [first, ..rest] },
    ),
    fn(anns) {
      // Deduplicate by function name (last wins, matching dict.from_list)
      anns
      |> list.map(fn(a) { #(a.function, a) })
      |> dict.from_list()
      |> dict.values()
    },
  )
}

// ──── Cluster 3: merge_inferred Preservation ────

pub fn merge_preserves_non_effects_lines_test() {
  use #(file, inferred) <- qcheck.given(
    qcheck.map2(assay_file_gen(), inferred_list_gen(), fn(f, i) { #(f, i) }),
  )
  let non_effects = fn(f: types.AssayFile) {
    list.filter(f.lines, fn(line) {
      case line {
        AnnotationLine(a) -> a.kind != Effects
        _ -> True
      }
    })
  }
  let merged = annotation.merge_inferred(file, inferred)
  non_effects(merged) |> should.equal(non_effects(file))
}

pub fn merge_includes_all_inferred_test() {
  use #(file, inferred) <- qcheck.given(
    qcheck.map2(assay_file_gen(), inferred_list_gen(), fn(f, i) { #(f, i) }),
  )
  let merged = annotation.merge_inferred(file, inferred)
  let merged_effect_names =
    annotation.extract_annotations(merged)
    |> list.filter(fn(a) { a.kind == Effects })
    |> list.map(fn(a) { a.function })
    |> set.from_list()
  list.each(inferred, fn(a) {
    set.contains(merged_effect_names, a.function) |> should.be_true()
  })
}

pub fn merge_no_stale_effects_test() {
  use #(file, inferred) <- qcheck.given(
    qcheck.map2(assay_file_gen(), inferred_list_gen(), fn(f, i) { #(f, i) }),
  )
  let inferred_names =
    inferred |> list.map(fn(a) { a.function }) |> set.from_list()
  let merged = annotation.merge_inferred(file, inferred)
  annotation.extract_annotations(merged)
  |> list.filter(fn(a) { a.kind == Effects })
  |> list.each(fn(a) {
    set.contains(inferred_names, a.function) |> should.be_true()
  })
}

pub fn merge_effects_match_inferred_test() {
  use #(file, inferred) <- qcheck.given(
    qcheck.map2(assay_file_gen(), inferred_list_gen(), fn(f, i) { #(f, i) }),
  )
  let inferred_map =
    inferred
    |> list.map(fn(a) { #(a.function, a) })
    |> dict.from_list()
  let merged = annotation.merge_inferred(file, inferred)
  annotation.extract_annotations(merged)
  |> list.filter(fn(a) { a.kind == Effects })
  |> list.each(fn(a) {
    let assert Ok(expected) = dict.get(inferred_map, a.function)
    a |> should.equal(expected)
  })
}

// ──── Cluster 4: format_sorted Ordering Invariants ────

pub fn format_sorted_section_order_test() {
  use file <- qcheck.given(assay_file_gen())
  let sorted = annotation.format_sorted(file)
  let assert Ok(parsed) = annotation.parse_file(sorted)
  let indices =
    parsed.lines
    |> list.filter(fn(line) { line != BlankLine })
    |> list.map(section_index)
  check_non_decreasing(indices)
}

fn section_index(line: types.AssayLine) -> Int {
  case line {
    CommentLine(_) -> 0
    ExternalLine(_) -> 1
    TypeFieldLine(_) -> 2
    AnnotationLine(a) ->
      case a.kind {
        Check -> 3
        Effects -> 4
      }
    BlankLine -> -1
  }
}

fn check_non_decreasing(xs: List(Int)) -> Nil {
  case xs {
    [] | [_] -> Nil
    [a, b, ..rest] -> {
      { a <= b } |> should.be_true()
      check_non_decreasing([b, ..rest])
    }
  }
}

pub fn format_sorted_checks_alphabetical_test() {
  use file <- qcheck.given(assay_file_gen())
  let sorted = annotation.format_sorted(file)
  let assert Ok(parsed) = annotation.parse_file(sorted)
  let check_names =
    annotation.extract_annotations(parsed)
    |> list.filter(fn(a) { a.kind == Check })
    |> list.map(fn(a) { a.function })
  check_names |> should.equal(list.sort(check_names, string.compare))
}

pub fn format_sorted_effects_alphabetical_test() {
  use file <- qcheck.given(assay_file_gen())
  let sorted = annotation.format_sorted(file)
  let assert Ok(parsed) = annotation.parse_file(sorted)
  let effects_names =
    annotation.extract_annotations(parsed)
    |> list.filter(fn(a) { a.kind == Effects })
    |> list.map(fn(a) { a.function })
  effects_names |> should.equal(list.sort(effects_names, string.compare))
}

pub fn format_sorted_trailing_newline_test() {
  use file <- qcheck.given(assay_file_gen())
  let sorted = annotation.format_sorted(file)
  string.ends_with(sorted, "\n") |> should.be_true()
}

// ──── Generators (Cluster 5) ────

fn semver_gen() -> qcheck.Generator(#(Int, Int, Int)) {
  qcheck.map2(
    qcheck.map2(qcheck.bounded_int(0, 20), qcheck.bounded_int(0, 50), fn(a, b) {
      #(a, b)
    }),
    qcheck.bounded_int(0, 100),
    fn(ab, c) { #(ab.0, ab.1, c) },
  )
}

fn semver_string_gen() -> qcheck.Generator(String) {
  qcheck.map(semver_gen(), fn(v) {
    int.to_string(v.0) <> "." <> int.to_string(v.1) <> "." <> int.to_string(v.2)
  })
}

fn version_entry_gen() -> qcheck.Generator(#(#(Int, Int, Int), String)) {
  qcheck.map(semver_gen(), fn(v) {
    let label =
      int.to_string(v.0)
      <> "."
      <> int.to_string(v.1)
      <> "."
      <> int.to_string(v.2)
    #(v, label)
  })
}

// ──── Cluster 5: Semver Ordering Laws ────

pub fn semver_lte_reflexivity_test() {
  use a <- qcheck.given(semver_gen())
  effects.semver_lte(a, a) |> should.be_true()
}

pub fn semver_lte_transitivity_test() {
  use #(a, b, c) <- qcheck.given(
    qcheck.map2(
      qcheck.map2(semver_gen(), semver_gen(), fn(a, b) { #(a, b) }),
      semver_gen(),
      fn(ab, c) { #(ab.0, ab.1, c) },
    ),
  )
  case effects.semver_lte(a, b) && effects.semver_lte(b, c) {
    True -> effects.semver_lte(a, c) |> should.be_true()
    False -> Nil
  }
}

pub fn semver_lte_antisymmetry_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(semver_gen(), semver_gen(), fn(a, b) { #(a, b) }),
  )
  case effects.semver_lte(a, b) && effects.semver_lte(b, a) {
    True -> a |> should.equal(b)
    False -> Nil
  }
}

pub fn semver_lte_totality_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(semver_gen(), semver_gen(), fn(a, b) { #(a, b) }),
  )
  let either = effects.semver_lte(a, b) || effects.semver_lte(b, a)
  either |> should.be_true()
}

pub fn compare_semver_consistent_with_lte_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(semver_gen(), semver_gen(), fn(a, b) { #(a, b) }),
  )
  let cmp = effects.compare_semver(a, b)
  let lte = effects.semver_lte(a, b)
  case cmp {
    order.Lt | order.Eq -> lte |> should.be_true()
    order.Gt -> lte |> should.be_false()
  }
}

pub fn parse_semver_roundtrip_test() {
  use s <- qcheck.given(semver_string_gen())
  let parsed = effects.parse_semver(s)
  let reparsed =
    int.to_string(parsed.0)
    <> "."
    <> int.to_string(parsed.1)
    <> "."
    <> int.to_string(parsed.2)
  reparsed |> should.equal(s)
}

pub fn pick_best_version_eligible_test() {
  use #(versions, installed) <- qcheck.given(
    qcheck.map2(
      qcheck.map2(
        version_entry_gen(),
        qcheck.list_from(version_entry_gen()),
        fn(first, rest) { [first, ..rest] },
      ),
      semver_gen(),
      fn(vs, inst) { #(vs, inst) },
    ),
  )
  case effects.pick_best_version(versions, installed) {
    Ok(label) -> {
      // The picked version must exist in the input
      let assert Ok(picked) = list.find(versions, fn(v) { v.1 == label })
      // If there are eligible versions, picked must be ≤ installed
      let has_eligible =
        list.any(versions, fn(v) { effects.semver_lte(v.0, installed) })
      case has_eligible {
        True -> effects.semver_lte(picked.0, installed) |> should.be_true()
        False -> Nil
      }
    }
    Error(Nil) -> Nil
  }
}

// ──── Generators (Cluster 6 & 7) ────

// A pool of synthetic calls: (module, function, effect_label)
// Each call contributes exactly one effect for clear oracle reasoning.
const call_pool = [
  #("mod_a", "call_http", "Http"),
  #("mod_b", "call_dom", "Dom"),
  #("mod_c", "call_stdout", "Stdout"),
  #("mod_d", "call_db", "Db"),
  #("mod_e", "call_fs", "FileSystem"),
]

fn call_selection_gen() -> qcheck.Generator(List(Bool)) {
  qcheck.fixed_length_list_from(qcheck.bool(), list.length(call_pool))
}

fn selected_calls(selections: List(Bool)) -> List(#(String, String, String)) {
  list.zip(call_pool, selections)
  |> list.filter_map(fn(pair) {
    case pair.1 {
      True -> Ok(pair.0)
      False -> Error(Nil)
    }
  })
}

fn build_module(
  calls: List(#(String, String, String)),
) -> Result(glance.Module, Nil) {
  let modules =
    calls
    |> list.map(fn(c) { c.0 })
    |> list.unique()
    |> list.sort(string.compare)
  let imports =
    modules |> list.map(fn(m) { "import " <> m }) |> string.join("\n")
  let body = case calls {
    [] -> "  Nil"
    _ ->
      calls
      |> list.map(fn(c) { "  " <> c.0 <> "." <> c.1 <> "()" })
      |> string.join("\n")
  }
  let source = imports <> "\npub fn test_fn() {\n" <> body <> "\n}\n"
  glance.module(source) |> result.replace_error(Nil)
}

fn build_kb(calls: List(#(String, String, String))) -> effects.KnowledgeBase {
  let all_effects =
    calls
    |> list.map(fn(c) {
      #(
        types.QualifiedName(module: c.0, function: c.1),
        types.from_labels([c.2]),
      )
    })
    |> dict.from_list()
  effects.KnowledgeBase(
    all_effects:,
    param_bounds: dict.new(),
    type_fields: dict.new(),
    pure_modules: set.new(),
  )
}

fn actual_effects(calls: List(#(String, String, String))) -> EffectSet {
  calls
  |> list.map(fn(c) { c.2 })
  |> set.from_list()
  |> Specific()
}

// ──── Cluster 6: Checker Soundness ────

pub fn check_no_false_positives_test() {
  // When declared budget ⊇ actual effects, no violations
  use selections <- qcheck.given(call_selection_gen())
  let calls = selected_calls(selections)
  case build_module(calls) {
    Error(Nil) -> Nil
    Ok(module) -> {
      let kb = build_kb(calls)
      // Declare the exact effects — should produce no violations
      let declared = actual_effects(calls)
      let annotation = EffectAnnotation(Check, "test_fn", [], declared)
      checker.check(module, [annotation], kb) |> should.equal([])
    }
  }
}

pub fn check_wildcard_never_violates_test() {
  // Wildcard declared budget accepts any effects
  use selections <- qcheck.given(call_selection_gen())
  let calls = selected_calls(selections)
  case build_module(calls) {
    Error(Nil) -> Nil
    Ok(module) -> {
      let kb = build_kb(calls)
      let annotation = EffectAnnotation(Check, "test_fn", [], Wildcard)
      checker.check(module, [annotation], kb) |> should.equal([])
    }
  }
}

pub fn check_empty_budget_detects_effects_test() {
  // Pure budget with effectful calls must produce violations
  use selections <- qcheck.given(call_selection_gen())
  let calls = selected_calls(selections)
  case calls {
    [] -> Nil
    _ ->
      case build_module(calls) {
        Error(Nil) -> Nil
        Ok(module) -> {
          let kb = build_kb(calls)
          let annotation = EffectAnnotation(Check, "test_fn", [], types.empty())
          let violations = checker.check(module, [annotation], kb)
          { violations != [] } |> should.be_true()
        }
      }
  }
}

pub fn check_violations_iff_not_subset_test() {
  // Core soundness: violations exist ↔ actual ⊄ declared
  use #(selections, declared) <- qcheck.given(
    qcheck.map2(call_selection_gen(), effect_set_gen(), fn(s, d) { #(s, d) }),
  )
  let calls = selected_calls(selections)
  case build_module(calls) {
    Error(Nil) -> Nil
    Ok(module) -> {
      let kb = build_kb(calls)
      let annotation = EffectAnnotation(Check, "test_fn", [], declared)
      let violations = checker.check(module, [annotation], kb)
      let has_violations = violations != []
      let actual = actual_effects(calls)
      let not_subset = !types.is_subset(actual, declared)
      has_violations |> should.equal(not_subset)
    }
  }
}

pub fn infer_matches_actual_effects_test() {
  // Inferred effects = union of all call effects
  use selections <- qcheck.given(call_selection_gen())
  let calls = selected_calls(selections)
  case build_module(calls) {
    Error(Nil) -> Nil
    Ok(module) -> {
      let kb = build_kb(calls)
      let inferred = checker.infer(module, kb, [])
      let assert [annotation] = inferred
      annotation.function |> should.equal("test_fn")
      annotation.effects |> should.equal(actual_effects(calls))
    }
  }
}

// ──── Cluster 7: Cycle Detection ────

fn cycle_graph_gen() -> qcheck.Generator(List(#(String, List(String)))) {
  // Generate small call graphs: 2-4 functions, each calling 0-2 others
  // Functions: a, b, c, d. Each may call any of the others (including self).
  let names = ["a", "b", "c", "d"]
  let callees_gen =
    qcheck.map(
      qcheck.fixed_length_list_from(qcheck.bool(), list.length(names)),
      fn(bools) {
        list.zip(names, bools)
        |> list.filter_map(fn(pair) {
          case pair.1 {
            True -> Ok(pair.0)
            False -> Error(Nil)
          }
        })
      },
    )
  // Generate callees for each of a, b, c, d
  qcheck.map(
    qcheck.fixed_length_list_from(callees_gen, list.length(names)),
    fn(all_callees) { list.zip(names, all_callees) },
  )
}

fn build_cycle_source(graph: List(#(String, List(String)))) -> String {
  graph
  |> list.index_map(fn(entry, i) {
    let #(name, callees) = entry
    let visibility = case i {
      0 -> "pub "
      _ -> ""
    }
    let body = case callees {
      [] -> "  Nil"
      cs -> cs |> list.map(fn(c) { "  " <> c <> "()" }) |> string.join("\n")
    }
    visibility <> "fn " <> name <> "() {\n" <> body <> "\n}"
  })
  |> string.join("\n")
}

pub fn infer_terminates_with_cycles_test() {
  use graph <- qcheck.given(cycle_graph_gen())
  let source = build_cycle_source(graph)
  case glance.module(source) {
    Error(_) -> Nil
    Ok(module) -> {
      let kb =
        effects.KnowledgeBase(
          all_effects: dict.new(),
          param_bounds: dict.new(),
          type_fields: dict.new(),
          pure_modules: set.new(),
        )
      // Must terminate — no hang, no crash
      let inferred = checker.infer(module, kb, [])
      // First function is public, so exactly one annotation inferred
      let assert [annotation] = inferred
      annotation.function |> should.equal("a")
    }
  }
}

pub fn check_terminates_with_cycles_test() {
  use graph <- qcheck.given(cycle_graph_gen())
  let source = build_cycle_source(graph)
  case glance.module(source) {
    Error(_) -> Nil
    Ok(module) -> {
      let kb =
        effects.KnowledgeBase(
          all_effects: dict.new(),
          param_bounds: dict.new(),
          type_fields: dict.new(),
          pure_modules: set.new(),
        )
      // Pure cycles should produce no violations (no external effects)
      let annotation = EffectAnnotation(Check, "a", [], types.empty())
      let violations = checker.check(module, [annotation], kb)
      violations |> should.equal([])
    }
  }
}
