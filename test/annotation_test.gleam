import generators
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleeunit/should
import graded/internal/annotation
import graded/internal/effect_term
import graded/internal/types.{
  type EffectTerm, AnnotationLine, BlankLine, Check, CommentLine,
  EffectAnnotation, Effects, ExternalAnnotation, ExternalLine,
  ExternalReturnsLine, FunctionExternal, ModuleExternal, ParamBound, Polymorphic,
  ReturnsLine, Specific, TAbs, TApp, TLabels, TUnion, TVar, TypeFieldAnnotation,
  TypeFieldLine, Wildcard,
}
import qcheck

// Parse
//
// Line-level parsing of `effects` and `check` annotations: effect sets,
// interleaved comments and blank lines, and rejection of malformed input.

pub fn empty_effects_test() {
  let input = "effects view : []"
  let assert Ok([
    EffectAnnotation(kind: Effects, function: "view", params: _, effects: eff),
  ]) = annotation.parse(input)
  effect_term.to_effect_set(eff) |> should.equal(Specific(set.new()))
}

pub fn single_effect_test() {
  let input = "effects update : [Http]"
  let assert Ok([
    EffectAnnotation(kind: Effects, function: "update", params: _, effects: eff),
  ]) = annotation.parse(input)
  effect_term.to_effect_set(eff)
  |> should.equal(Specific(set.from_list(["Http"])))
}

pub fn multiple_effects_test() {
  let input = "effects update : [Http, Dom]"
  let assert Ok([
    EffectAnnotation(kind: Effects, function: "update", params: _, effects: eff),
  ]) = annotation.parse(input)
  effect_term.to_effect_set(eff)
  |> should.equal(Specific(set.from_list(["Http", "Dom"])))
}

pub fn check_line_test() {
  let input = "check view : []"
  let assert Ok([
    EffectAnnotation(kind: Check, function: "view", params: _, effects: eff),
  ]) = annotation.parse(input)
  effect_term.to_effect_set(eff) |> should.equal(Specific(set.new()))
}

pub fn check_with_effects_test() {
  let input = "check update : [Http, Dom]"
  let assert Ok([
    EffectAnnotation(kind: Check, function: "update", params: _, effects: eff),
  ]) = annotation.parse(input)
  effect_term.to_effect_set(eff)
  |> should.equal(Specific(set.from_list(["Http", "Dom"])))
}

// `$op$` sentinel reservation (Fix D): the parser never mints a `$op$`-prefixed
// TVar or binder from a loaded `.graded` (a forged sentinel), and never fails the
// whole file over one — it grounds the offending term to `[Unknown]`.

pub fn reserved_sentinel_bare_var_test() {
  let assert Ok([EffectAnnotation(effects: eff, ..)]) =
    annotation.parse("effects f : [$op$x]")
  effect_term.to_effect_set(eff)
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

pub fn reserved_sentinel_application_head_test() {
  let assert Ok([EffectAnnotation(effects: eff, ..)]) =
    annotation.parse("effects f : [$op$g([Http])]")
  effect_term.to_effect_set(eff)
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

pub fn reserved_sentinel_nested_occurrence_test() {
  // A nested `$op$x` is caught by the recursive descent; the line still parses.
  annotation.parse("effects f : [g([$op$x])]") |> should.be_ok()
}

pub fn reserved_sentinel_binder_test() {
  let assert Ok(file) = annotation.parse_file("returns m.f : fn($op$x) -> [x]")
  let assert [returns] = annotation.extract_returns(file)
  effect_term.to_effect_set(returns.operator)
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

pub fn reserved_sentinel_preserves_whole_file_test() {
  // A forged `$op$` line must NOT fail the whole file (`parse_file` is `try_map`),
  // which would let `read_spec` substitute an empty spec and lose hand-written
  // lines. Sibling `check`/`external` lines survive.
  let input =
    "check app/a.run : []
returns m.f : fn($op$x) -> [x]
assume dep/x : []"
  let assert Ok(file) = annotation.parse_file(input)
  let annotations = annotation.extract_annotations(file)
  list.any(annotations, fn(a) {
    case a {
      EffectAnnotation(kind: Check, function: "app/a.run", ..) -> True
      _ -> False
    }
  })
  |> should.be_true()
}

pub fn mixed_file_test() {
  let input =
    "effects view : []
effects update : [Http, Dom]
check view : []"
  let assert Ok(annotations) = annotation.parse(input)
  annotations
  |> fn(a) {
    case a {
      [_, _, _] -> True
      _ -> False
    }
  }
  |> should.be_true()
}

pub fn comments_and_blanks_test() {
  let input =
    "// this is a comment

effects view : []

// another comment
check update : [Http]"
  let assert Ok(annotations) = annotation.parse(input)
  annotations
  |> fn(a) {
    case a {
      [_, _] -> True
      _ -> False
    }
  }
  |> should.be_true()
}

pub fn malformed_line_test() {
  let input = "bad line"
  let assert Error(_) = annotation.parse(input)
}

pub fn missing_brackets_test() {
  let input = "effects view : Http"
  let assert Error(_) = annotation.parse(input)
}

// File parsing
//
// `parse_file` preserves comments and blank lines as structured lines, and
// `extract_checks` pulls the check annotations back out of a parsed file.

pub fn parse_file_preserves_structure_test() {
  let input =
    "// header comment

effects view : []
check view : []

// footer"
  let assert Ok(file) = annotation.parse_file(input)
  case file.lines {
    [
      CommentLine(_),
      BlankLine,
      AnnotationLine(_),
      AnnotationLine(_),
      BlankLine,
      CommentLine(_),
    ] -> should.be_true(True)
    _ -> should.be_true(False)
  }
}

pub fn extract_checks_test() {
  let input =
    "effects view : []
effects update : [Http]
check view : []
check handle_click : [Http]"
  let assert Ok(file) = annotation.parse_file(input)
  let checks = annotation.extract_checks(file)
  checks
  |> fn(c) {
    case c {
      [_, _] -> True
      _ -> False
    }
  }
  |> should.be_true()
}

// Format
//
// Serializing annotations back into spec-file lines.

pub fn format_annotation_effects_test() {
  let ann =
    EffectAnnotation(
      kind: Effects,
      function: "view",
      params: [],
      effects: effect_term.from_effect_set(Specific(set.new())),
    )
  annotation.format_annotation(ann) |> should.equal("effects view : []")
}

pub fn format_annotation_check_test() {
  let ann =
    EffectAnnotation(
      kind: Check,
      function: "update",
      params: [],
      effects: effect_term.from_effect_set(
        Specific(set.from_list(["Http", "Dom"])),
      ),
    )
  annotation.format_annotation(ann)
  |> should.equal("check update : [Dom, Http]")
}

// Parameter bounds
//
// Higher-order budgets on parameters (`f: [Stdout]`): parsing and formatting,
// with single and multiple bounds on both `effects` and `check` lines.

pub fn parse_single_param_bound_test() {
  let input = "effects apply(f: [Stdout]) : []"
  let assert Ok([ann]) = annotation.parse(input)
  ann.function |> should.equal("apply")
  ann.params
  |> should.equal([
    ParamBound(
      "f",
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
    ),
  ])
  effect_term.to_effect_set(ann.effects) |> should.equal(Specific(set.new()))
}

pub fn parse_multiple_param_bounds_test() {
  let input = "effects transform(f: [], g: [Http]) : [Http]"
  let assert Ok([ann]) = annotation.parse(input)
  ann.params
  |> should.equal([
    ParamBound("f", effect_term.from_effect_set(Specific(set.new()))),
    ParamBound(
      "g",
      effect_term.from_effect_set(Specific(set.from_list(["Http"]))),
    ),
  ])
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Specific(set.from_list(["Http"])))
}

pub fn parse_empty_param_list_is_invalid_test() {
  let input = "effects apply() : []"
  let assert Ok([ann]) = annotation.parse(input)
  ann.params |> should.equal([])
}

pub fn parse_param_bound_check_test() {
  let input = "check safe_map(f: []) : []"
  let assert Ok([ann]) = annotation.parse(input)
  ann.kind |> should.equal(Check)
  ann.params
  |> should.equal([
    ParamBound("f", effect_term.from_effect_set(Specific(set.new()))),
  ])
}

pub fn format_annotation_with_params_test() {
  let ann =
    EffectAnnotation(
      kind: Effects,
      function: "apply",
      params: [
        ParamBound(
          "f",
          effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
        ),
      ],
      effects: effect_term.from_effect_set(Specific(set.new())),
    )
  annotation.format_annotation(ann)
  |> should.equal("effects apply(f: [Stdout]) : []")
}

pub fn format_annotation_with_multiple_params_test() {
  let ann =
    EffectAnnotation(
      kind: Check,
      function: "transform",
      params: [
        ParamBound("f", effect_term.from_effect_set(Specific(set.new()))),
        ParamBound(
          "g",
          effect_term.from_effect_set(Specific(set.from_list(["Http"]))),
        ),
      ],
      effects: effect_term.from_effect_set(Specific(set.from_list(["Http"]))),
    )
  annotation.format_annotation(ann)
  |> should.equal("check transform(f: [], g: [Http]) : [Http]")
}

// Type field annotations
//
// `assume T.field : [...]` lines, both bare and module-qualified.

pub fn parse_type_field_test() {
  let input = "assume Handler.on_click : [Dom]"
  let assert Ok(file) = annotation.parse_file(input)
  let tfs = annotation.extract_type_fields(file)
  let assert [tf] = tfs
  tf.type_name |> should.equal("Handler")
  tf.field |> should.equal("on_click")
  effect_term.to_effect_set(tf.effects)
  |> should.equal(Specific(set.from_list(["Dom"])))
}

pub fn parse_type_field_multiple_effects_test() {
  let input = "assume Request.send : [Http, Io]"
  let assert Ok(file) = annotation.parse_file(input)
  let assert [tf] = annotation.extract_type_fields(file)
  effect_term.to_effect_set(tf.effects)
  |> should.equal(Specific(set.from_list(["Http", "Io"])))
}

pub fn format_type_field_test() {
  let tf =
    TypeFieldAnnotation(
      module: None,
      type_name: "Handler",
      field: "on_click",
      effects: effect_term.from_effect_set(Specific(set.from_list(["Dom"]))),
    )
  annotation.format_type_field(tf)
  |> should.equal("assume Handler.on_click : [Dom]")
}

pub fn format_type_field_qualified_test() {
  let tf =
    TypeFieldAnnotation(
      module: Some("myapp/router"),
      type_name: "Handler",
      field: "on_click",
      effects: effect_term.from_effect_set(Specific(set.from_list(["Dom"]))),
    )
  annotation.format_type_field(tf)
  |> should.equal("assume myapp/router.Handler.on_click : [Dom]")
}

pub fn parse_type_field_qualified_test() {
  let input = "assume myapp/router.Handler.on_click : [Dom]"
  let assert Ok(file) = annotation.parse_file(input)
  let assert [tf] = annotation.extract_type_fields(file)
  tf.module |> should.equal(Some("myapp/router"))
  tf.type_name |> should.equal("Handler")
  tf.field |> should.equal("on_click")
}

pub fn parse_type_field_qualified_deep_module_test() {
  let input = "assume deeply/nested/path.Config.validator : []"
  let assert Ok(file) = annotation.parse_file(input)
  let assert [tf] = annotation.extract_type_fields(file)
  tf.module |> should.equal(Some("deeply/nested/path"))
  tf.type_name |> should.equal("Config")
  tf.field |> should.equal("validator")
}

// External annotations
//
// `assume module.fn : [...]` lines for third-party functions.

pub fn parse_external_test() {
  let input = "assume gleam/http/request.send : [Http]"
  let assert Ok(file) = annotation.parse_file(input)
  let assert [ext] = annotation.extract_externals(file)
  ext.module |> should.equal("gleam/http/request")
  ext.target |> should.equal(FunctionExternal("send"))
  ext.effects |> should.equal(Specific(set.from_list(["Http"])))
}

pub fn parse_external_pure_test() {
  let input = "assume gleam/json.decode : []"
  let assert Ok(file) = annotation.parse_file(input)
  let assert [ext] = annotation.extract_externals(file)
  ext.module |> should.equal("gleam/json")
  ext.target |> should.equal(FunctionExternal("decode"))
  ext.effects |> should.equal(Specific(set.new()))
}

pub fn format_external_test() {
  let ext =
    ExternalAnnotation(
      "gleam/httpc",
      FunctionExternal("send"),
      Specific(set.from_list(["Http"])),
    )
  annotation.format_external(ext)
  |> should.equal("assume gleam/httpc.send : [Http]")
}

// Assumptions
//
// `assume <path> : [...]` lines. One keyword for every trusted declaration;
// what the line covers is read off the path's shape.

pub fn parse_assume_module_test() {
  let assert Ok(file) = annotation.parse_file("assume gleam/io : [Stdout]")
  let assert [ext] = annotation.extract_externals(file)
  ext.module |> should.equal("gleam/io")
  ext.target |> should.equal(ModuleExternal)
  ext.effects |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn parse_assume_function_test() {
  let assert Ok(file) =
    annotation.parse_file("assume gleam/http/request.send : [Http]")
  let assert [ext] = annotation.extract_externals(file)
  ext.module |> should.equal("gleam/http/request")
  ext.target |> should.equal(FunctionExternal("send"))
  ext.effects |> should.equal(Specific(set.from_list(["Http"])))
}

pub fn parse_assume_qualified_field_test() {
  let assert Ok(file) =
    annotation.parse_file("assume myapp/router.Handler.on_click : [Dom]")
  let assert [tf] = annotation.extract_type_fields(file)
  tf.module |> should.equal(Some("myapp/router"))
  tf.type_name |> should.equal("Handler")
  tf.field |> should.equal("on_click")
  effect_term.to_effect_set(tf.effects)
  |> should.equal(Specific(set.from_list(["Dom"])))
}

pub fn parse_assume_bare_field_test() {
  // An UpperCamel first segment is a type name, so a two-segment path is a
  // field of it rather than a function of a module by that name.
  let assert Ok(file) = annotation.parse_file("assume Handler.on_click : [Dom]")
  let assert [tf] = annotation.extract_type_fields(file)
  tf.module |> should.equal(None)
  tf.type_name |> should.equal("Handler")
  tf.field |> should.equal("on_click")
}

pub fn assume_over_a_lowercase_deep_path_is_invalid_test() {
  // Three lowercase segments name no shape: a module path uses slashes, so the
  // second-to-last segment would have to be a type name.
  annotation.parse_file("assume a.b.c : []")
  |> should.equal(Error(annotation.InvalidLine(1, "assume a.b.c : []")))
}

pub fn assume_over_an_empty_segment_is_invalid_test() {
  annotation.parse_file("assume m. : []")
  |> should.equal(Error(annotation.InvalidLine(1, "assume m. : []")))
  annotation.parse_file("assume .f : []")
  |> should.equal(Error(annotation.InvalidLine(1, "assume .f : []")))
}

// Retired spellings
//
// A line in a spelling this version no longer reads is refused by name, with
// the rewrite. No such line parses as anything else, so nothing is silently
// reinterpreted.

pub fn a_type_line_is_a_retired_spelling_test() {
  let input = "type m.Handler.on_click : [Dom]"
  annotation.parse_file(input)
  |> should.equal(
    Error(annotation.RetiredSpelling(1, input, annotation.RetiredType)),
  )
  annotation.describe_parse_error(annotation.RetiredSpelling(
    1,
    input,
    annotation.RetiredType,
  ))
  |> should.equal(
    "1: type m.Handler.on_click : [Dom]\n  `type <path> : <effects>` is retired; write `assume <path> : <effects>`",
  )
}

pub fn an_external_effects_line_is_a_retired_spelling_test() {
  let input = "external effects m/ffi.send : [Http]"
  annotation.parse_file(input)
  |> should.equal(
    Error(annotation.RetiredSpelling(
      1,
      input,
      annotation.RetiredExternalEffects,
    )),
  )
  annotation.describe_parse_error(annotation.RetiredSpelling(
    1,
    input,
    annotation.RetiredExternalEffects,
  ))
  |> should.equal(
    "1: external effects m/ffi.send : [Http]\n  `external effects <path> : <effects>` is retired; write `assume <path> : <effects>`",
  )
}

pub fn no_retired_line_parses_as_anything_test() {
  // Every retired opener is refused outright — none falls through to another
  // arm and keys something the author did not write.
  [
    "type m.Handler.on_click : [Dom]",
    "type Handler.on_click : [Dom]",
    "external effects m/ffi.send : [Http]",
    "external effects m/ffi : [Http]",
  ]
  |> list.each(fn(line) {
    annotation.parse_file(line)
    |> should.be_error
  })
}

pub fn format_sorted_orders_assume_then_check_then_effects_test() {
  let input =
    "effects m.g : []
check m.f : []
assume m/ffi.send : [Http]
assume m.Handler.on_click : [Dom]
"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal(
    "assume m.Handler.on_click : [Dom]
assume m/ffi.send : [Http]

check m.f : []

effects m.g : []
",
  )
}

pub fn a_canonical_assume_section_is_a_fixed_point_test() {
  let canonical =
    "assume Handler.on_click : [Dom]
assume gleam/io : [Stdout]
assume gleam/io.println : [Stdout]
assume myapp/router.Handler.on_click : [Dom]
"
  let assert Ok(file) = annotation.parse_file(canonical)
  annotation.format_sorted(file) |> should.equal(canonical)
}

pub fn assume_with_no_effects_is_invalid_test() {
  annotation.parse_file("assume gleam/io.println")
  |> should.equal(Error(annotation.InvalidLine(1, "assume gleam/io.println")))
}

// Wildcard [_]
//
// The `[_]` effect set in annotations, parameter bounds, and formatting.

pub fn parse_wildcard_effects_test() {
  let input = "effects handler : [_]"
  let assert Ok([ann]) = annotation.parse(input)
  effect_term.to_effect_set(ann.effects) |> should.equal(Wildcard)
}

pub fn parse_wildcard_check_test() {
  let input = "check handler : [_]"
  let assert Ok([ann]) = annotation.parse(input)
  ann.kind |> should.equal(Check)
  effect_term.to_effect_set(ann.effects) |> should.equal(Wildcard)
}

pub fn parse_wildcard_param_bound_test() {
  let input = "effects apply(f: [_]) : [_]"
  let assert Ok([ann]) = annotation.parse(input)
  ann.params
  |> should.equal([ParamBound("f", effect_term.from_effect_set(Wildcard))])
  effect_term.to_effect_set(ann.effects) |> should.equal(Wildcard)
}

pub fn format_wildcard_annotation_test() {
  let ann =
    EffectAnnotation(
      kind: Effects,
      function: "handler",
      params: [],
      effects: effect_term.from_effect_set(Wildcard),
    )
  annotation.format_annotation(ann) |> should.equal("effects handler : [_]")
}

// Polymorphic effect variables
//
// Effect variables (`e`) in parameter bounds and result sets, alone and mixed
// with concrete labels.

pub fn parse_polymorphic_single_variable_test() {
  let input = "effects apply(f: [e]) : [e]"
  let assert Ok([ann]) = annotation.parse(input)
  ann.params
  |> should.equal([
    ParamBound(
      "f",
      effect_term.from_effect_set(Polymorphic(set.new(), set.from_list(["e"]))),
    ),
  ])
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Polymorphic(set.new(), set.from_list(["e"])))
}

pub fn parse_polymorphic_mixed_labels_and_variables_test() {
  let input = "effects map(f: [e]) : [Stdout, e]"
  let assert Ok([ann]) = annotation.parse(input)
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Polymorphic(set.from_list(["Stdout"]), set.from_list(["e"])))
}

pub fn parse_polymorphic_multiple_variables_test() {
  let input = "effects apply2(f: [e1], g: [e2]) : [e1, e2]"
  let assert Ok([ann]) = annotation.parse(input)
  ann.params
  |> should.equal([
    ParamBound(
      "f",
      effect_term.from_effect_set(Polymorphic(set.new(), set.from_list(["e1"]))),
    ),
    ParamBound(
      "g",
      effect_term.from_effect_set(Polymorphic(set.new(), set.from_list(["e2"]))),
    ),
  ])
  effect_term.to_effect_set(ann.effects)
  |> should.equal(Polymorphic(set.new(), set.from_list(["e1", "e2"])))
}

pub fn format_polymorphic_annotation_test() {
  let ann =
    EffectAnnotation(
      kind: Effects,
      function: "apply",
      params: [
        ParamBound(
          "f",
          effect_term.from_effect_set(Polymorphic(
            set.new(),
            set.from_list(["e"]),
          )),
        ),
      ],
      effects: effect_term.from_effect_set(Polymorphic(
        set.from_list(["Stdout"]),
        set.from_list(["e"]),
      )),
    )
  annotation.format_annotation(ann)
  |> should.equal("effects apply(f: [e]) : [Stdout, e]")
}

// Parse/format roundtrips (property)
//
// qcheck properties: formatting then parsing is the identity for annotations,
// type fields, externals, and whole files; sorted formatting is idempotent.

pub fn annotation_roundtrip_test() {
  use a <- qcheck.given(generators.annotation_gen())
  let formatted = annotation.format_annotation(a)
  let assert Ok(parsed) = annotation.parse(formatted)
  parsed |> should.equal([a])
}

pub fn type_field_roundtrip_test() {
  use tf <- qcheck.given(generators.type_field_gen())
  let formatted = annotation.format_type_field(tf)
  let assert Ok(file) = annotation.parse_file(formatted)
  let assert [TypeFieldLine(parsed)] = file.lines
  parsed |> should.equal(tf)
}

pub fn external_roundtrip_test() {
  use ext <- qcheck.given(generators.external_gen())
  let formatted = annotation.format_external(ext)
  let assert Ok(file) = annotation.parse_file(formatted)
  let assert [ExternalLine(parsed)] = file.lines
  parsed |> should.equal(ext)
}

pub fn file_roundtrip_test() {
  use file <- qcheck.given(generators.graded_file_gen())
  let formatted = annotation.format_file(file)
  let assert Ok(parsed) = annotation.parse_file(formatted)
  parsed |> should.equal(file)
}

pub fn format_sorted_idempotence_test() {
  use file <- qcheck.given(generators.graded_file_gen())
  let s1 = annotation.format_sorted(file)
  let assert Ok(parsed) = annotation.parse_file(s1)
  let s2 = annotation.format_sorted(parsed)
  s1 |> should.equal(s2)
}

// merge_inferred
//
// Merging freshly inferred effects into an existing file: non-effects lines
// survive in order, the effects lines track the inferred set exactly, and an
// inferred line shadowed by an author-written external declaration is dropped.

pub fn merge_inferred_invariants_test() {
  use #(file, inferred) <- qcheck.given(
    qcheck.map2(
      generators.graded_file_gen(),
      generators.inferred_list_gen(),
      fn(f, i) { #(f, i) },
    ),
  )
  let merged =
    annotation.merge_inferred(file, inferred, [], set.new(), set.new())
  let merged_effects =
    annotation.extract_annotations(merged)
    |> list.filter(fn(a) { a.kind == Effects })

  // Non-effects lines preserved in order
  let non_effects = fn(f: types.GradedFile) {
    list.filter(f.lines, fn(line) {
      case line {
        AnnotationLine(a) -> a.kind != Effects
        _ -> True
      }
    })
  }
  non_effects(merged) |> should.equal(non_effects(file))

  // All inferred functions present
  let merged_names =
    merged_effects |> list.map(fn(a) { a.function }) |> set.from_list()
  list.each(inferred, fn(a) {
    set.contains(merged_names, a.function) |> should.be_true()
  })

  // No stale effects
  let inferred_names =
    inferred |> list.map(fn(a) { a.function }) |> set.from_list()
  list.each(merged_effects, fn(a) {
    set.contains(inferred_names, a.function) |> should.be_true()
  })

  // Effects match inferred values
  let inferred_map =
    inferred |> list.map(fn(a) { #(a.function, a) }) |> dict.from_list()
  list.each(merged_effects, fn(a) {
    let assert Ok(expected) = dict.get(inferred_map, a.function)
    a |> should.equal(expected)
  })
}

pub fn merge_inferred_drops_effect_for_external_test() {
  // An author-written `assume app.ffi : [...]` is authoritative: the
  // inferred `effects app.ffi` line (the opaque-FFI `[Unknown]` default) is
  // dropped so it neither duplicates nor shadows the declaration. Other inferred
  // functions are kept.
  let file =
    types.GradedFile(lines: [
      ExternalLine(ExternalAnnotation(
        module: "app",
        target: FunctionExternal("ffi"),
        effects: types.Specific(set.new()),
      )),
    ])
  let inferred = [
    EffectAnnotation(Effects, "app.ffi", [], effect_term.unknown()),
    EffectAnnotation(Effects, "app.other", [], effect_term.pure()),
  ]
  let effects_fns =
    annotation.merge_inferred(file, inferred, [], set.new(), set.new())
    |> annotation.extract_annotations
    |> list.filter(fn(a) { a.kind == Effects })
    |> list.map(fn(a) { a.function })
    |> set.from_list()
  set.contains(effects_fns, "app.ffi") |> should.be_false()
  set.contains(effects_fns, "app.other") |> should.be_true()
}

pub fn merge_inferred_keeps_an_external_returns_line_test() {
  // A declaration is preserved in place and never regenerated, and the inferred
  // `returns` line for the same name is dropped: one name, one answer.
  let declared =
    ExternalReturnsLine(types.ReturnsAnnotation(
      function: "app.make",
      operator: TLabels(set.from_list(["Net"])),
    ))
  let file = types.GradedFile(lines: [declared])
  let inferred_returns = [
    types.ReturnsAnnotation(function: "app.make", operator: TLabels(set.new())),
    types.ReturnsAnnotation(function: "app.other", operator: TLabels(set.new())),
  ]
  let merged =
    annotation.merge_inferred(file, [], inferred_returns, set.new(), set.new())
  merged.lines
  |> should.equal([
    declared,
    ReturnsLine(types.ReturnsAnnotation(
      function: "app.other",
      operator: TLabels(set.new()),
    )),
  ])
}

pub fn merge_inferred_keeps_an_unmatched_external_returns_line_test() {
  // A declaration for a function inference no longer reports a summary for is
  // still the author's line, so the stale-removal path that drops an unmatched
  // `returns` line does not reach it.
  let declared =
    ExternalReturnsLine(types.ReturnsAnnotation(
      function: "app.make",
      operator: TLabels(set.from_list(["Net"])),
    ))
  let file = types.GradedFile(lines: [declared])
  annotation.merge_inferred(file, [], [], set.new(), set.new())
  |> should.equal(file)
}

pub fn merge_inferred_rewrites_a_stale_external_returns_line_test() {
  // The line names one of this package's own ordinary functions, so it declares
  // nothing: it is deleted and the inferred `returns` line it was suppressing
  // is written in its place.
  let file =
    types.GradedFile(lines: [
      ExternalReturnsLine(types.ReturnsAnnotation(
        function: "app.make",
        operator: TLabels(set.from_list(["Net"])),
      )),
    ])
  let inferred_returns = [
    types.ReturnsAnnotation(
      function: "app.make",
      operator: TLabels(set.from_list(["Disk"])),
    ),
  ]
  annotation.merge_inferred(
    file,
    [],
    inferred_returns,
    set.new(),
    set.from_list(["app.make"]),
  )
  |> should.equal(
    types.GradedFile(lines: [
      ReturnsLine(types.ReturnsAnnotation(
        function: "app.make",
        operator: TLabels(set.from_list(["Disk"])),
      )),
    ]),
  )
}

pub fn merge_inferred_keeps_the_two_stale_channels_apart_test() {
  // A stale `external returns` name reaching the effects channel's filters
  // would delete the function's own `effects` line, which nothing declared
  // anything about.
  let file =
    types.GradedFile(lines: [
      ExternalReturnsLine(types.ReturnsAnnotation(
        function: "app.make",
        operator: TLabels(set.from_list(["Net"])),
      )),
      AnnotationLine(EffectAnnotation(
        Effects,
        "app.make",
        [],
        TLabels(set.new()),
      )),
    ])
  let inferred = [
    EffectAnnotation(Effects, "app.make", [], TLabels(set.from_list(["Disk"]))),
  ]
  annotation.merge_inferred(
    file,
    inferred,
    [],
    set.new(),
    set.from_list(["app.make"]),
  )
  |> should.equal(
    types.GradedFile(lines: [
      AnnotationLine(EffectAnnotation(
        Effects,
        "app.make",
        [],
        TLabels(set.from_list(["Disk"])),
      )),
    ]),
  )
}

// Second-order serialization
//
// Operator applications (`action([Stdout])`) in effect terms: formatting,
// parsing, curried multi-argument applications, and operator-typed parameter
// bounds.

pub fn format_second_order_application_test() {
  let ann =
    EffectAnnotation(
      Effects,
      "with_logger",
      [ParamBound("action", TVar("action"))],
      TApp(TVar("action"), TLabels(set.from_list(["Stdout"]))),
    )
  annotation.format_annotation(ann)
  |> should.equal("effects with_logger(action: [action]) : [action([Stdout])]")
}

pub fn residual_abstraction_in_an_effect_set_renders_parseably_test() {
  // An under-applied operator left in *effect* position. The effect-set grammar
  // has no `fn(..) -> ..` atom, so rendering the abstraction would emit a line
  // the parser rejects — `graded infer` would write a spec that fails to read
  // back. It grounds to the conservative collapse instead.
  let ann = EffectAnnotation(Effects, "probe.caller", [], TAbs("b", TVar("b")))
  let line = annotation.format_annotation(ann)
  line |> should.equal("effects probe.caller : [Unknown]")
  let assert Ok([reparsed]) = annotation.parse(line)
  annotation.format_annotation(reparsed) |> should.equal(line)
}

pub fn residual_abstraction_beside_a_label_renders_parseably_test() {
  // The same residual unioned with a resolved label: the label survives, only
  // the abstraction collapses.
  let ann =
    EffectAnnotation(
      Effects,
      "probe.caller",
      [],
      TUnion([TLabels(set.from_list(["Stdout"])), TAbs("b", TVar("b"))]),
    )
  let line = annotation.format_annotation(ann)
  line |> should.equal("effects probe.caller : [Stdout, Unknown]")
  let assert Ok(_) = annotation.parse(line)
}

pub fn operator_bound_still_renders_its_binders_test() {
  // Grounding a residual must not touch a *bound*, where `fn(a) -> [..]` is
  // legal syntax and round-trips: the spine walk consumes the binders before
  // the effect-set renderer ever sees them.
  let line = "effects run(f: fn(a) -> [a]) : [Stdout]"
  let assert Ok([ann]) = annotation.parse(line)
  annotation.format_annotation(ann) |> should.equal(line)
}

pub fn parse_second_order_application_test() {
  let assert Ok([ann]) =
    annotation.parse(
      "effects with_logger(action: [action]) : [action([Stdout])]",
    )
  ann.effects
  |> should.equal(TApp(TVar("action"), TLabels(set.from_list(["Stdout"]))))
  ann.params |> should.equal([ParamBound("action", TVar("action"))])
}

pub fn roundtrip_application_with_label_test() {
  let line = "effects run(action: [action]) : [Http, action([Stdout])]"
  let assert Ok([ann]) = annotation.parse(line)
  annotation.format_annotation(ann) |> should.equal(line)
}

pub fn roundtrip_application_multiple_args_test() {
  // A curried two-argument application: each callback is its own bracketed
  // effect term, distinct from a single multi-label argument `f([Db, Http])`.
  let line = "check run(f: [f]) : [f([Db], [Http])]"
  let assert Ok([ann]) = annotation.parse(line)
  ann.effects
  |> should.equal(TApp(
    TApp(TVar("f"), TLabels(set.from_list(["Db"]))),
    TLabels(set.from_list(["Http"])),
  ))
  annotation.format_annotation(ann) |> should.equal(line)
}

pub fn application_arg_order_is_significant_test() {
  // Currying is positional: `f([Http], [Db])` and `f([Db], [Http])` are
  // different terms, and each round-trips with its argument order preserved
  // (application arguments are not sorted, unlike union members).
  let assert Ok([a]) = annotation.parse("check run(f: [f]) : [f([Http], [Db])]")
  let assert Ok([b]) = annotation.parse("check run(f: [f]) : [f([Db], [Http])]")
  { a.effects == b.effects } |> should.be_false()
  annotation.format_annotation(a)
  |> should.equal("check run(f: [f]) : [f([Http], [Db])]")
  annotation.format_annotation(b)
  |> should.equal("check run(f: [f]) : [f([Db], [Http])]")
}

pub fn single_multi_label_application_arg_test() {
  // A single argument carrying several labels stays one argument.
  let line = "check run(f: [f]) : [f([Db, Http])]"
  let assert Ok([ann]) = annotation.parse(line)
  ann.effects
  |> should.equal(TApp(TVar("f"), TLabels(set.from_list(["Db", "Http"]))))
  annotation.format_annotation(ann) |> should.equal(line)
}

pub fn roundtrip_multi_param_operator_bound_test() {
  // A curried operator bound `fn(a, b) -> [a, b]` round-trips.
  let line =
    "check run(action: fn(a, b) -> [a, b]) : [action([Stdout], [Http])]"
  let assert Ok([ann]) = annotation.parse(line)
  ann.params
  |> should.equal([
    ParamBound("action", TAbs("a", TAbs("b", TVar("a") |> union_vars("b")))),
  ])
  annotation.format_annotation(ann) |> should.equal(line)
}

pub fn second_order_roundtrip_property_test() {
  // P-SER-2: parse ∘ format is identity on normalized serializable terms.
  use term <- qcheck.given(generators.serializable_effect_term_gen())
  let normalized = effect_term.normalize(term)
  let ann = EffectAnnotation(Effects, "f", [], normalized)
  let assert Ok([parsed]) = annotation.parse(annotation.format_annotation(ann))
  parsed.effects |> should.equal(normalized)
}

// Field bounds
//
// `param.field: [...]` bounds naming a function-typed field of a parameter.

pub fn parse_field_bound_test() {
  // A field bound's name is the `param.field` path; it parses like any other
  // parameter bound, the dot carried verbatim in the name.
  let assert Ok([ann]) =
    annotation.parse("check view(handler.on_click: [Dom]) : [Dom]")
  ann.params
  |> should.equal([
    ParamBound("handler.on_click", TLabels(set.from_list(["Dom"]))),
  ])
}

pub fn roundtrip_field_bound_test() {
  let line = "check view(handler.on_click: [Dom]) : [Dom]"
  let assert Ok([ann]) = annotation.parse(line)
  annotation.format_annotation(ann) |> should.equal(line)
}

pub fn roundtrip_mixed_param_and_field_bound_test() {
  // A `check` line can mix an ordinary parameter bound with a field bound.
  let line =
    "check view(log: [Stdout], handler.on_click: [Dom]) : [Dom, Stdout]"
  let assert Ok([ann]) = annotation.parse(line)
  annotation.format_annotation(ann) |> should.equal(line)
}

// Returns annotations
//
// `returns module.fn : fn(cb) -> [...]` lines carrying an operator term for a
// function's return value.

pub fn returns_line_round_trip_test() {
  let line = "returns app/dep.pick : fn(cb) -> [cb]"
  let assert Ok(file) = annotation.parse_file(line)
  let assert [returns] = annotation.extract_returns(file)
  returns.function |> should.equal("app/dep.pick")
  returns.operator |> should.equal(TAbs("cb", TVar("cb")))
  annotation.format_file(file) |> should.equal(line)
}

pub fn returns_line_multi_callback_round_trip_test() {
  let line = "returns m.pick : fn(a, b) -> [a, b]"
  let assert Ok(file) = annotation.parse_file(line)
  let assert [returns] = annotation.extract_returns(file)
  returns.operator
  |> should.equal(TAbs("a", TAbs("b", union_vars(TVar("a"), "b"))))
  annotation.format_file(file) |> should.equal(line)
}

// External returns annotations
//
// `external returns module.fn : [Net]` lines declaring the operator a foreign
// producer hands back. Same operator grammar as `returns`, a distinct line
// kind.

pub fn external_returns_line_round_trip_test() {
  let line = "external returns app/ffi.make_client : [Net]"
  let assert Ok(file) = annotation.parse_file(line)
  let assert [declared] = annotation.extract_external_returns(file)
  declared.function |> should.equal("app/ffi.make_client")
  declared.operator |> should.equal(TLabels(set.from_list(["Net"])))
  annotation.extract_external_returns(file) |> list.length |> should.equal(1)
  annotation.extract_returns(file) |> should.equal([])
  annotation.format_file(file) |> should.equal(line)
}

pub fn external_returns_line_operator_round_trip_test() {
  let line = "external returns m.wrap : fn(cb) -> [cb]"
  let assert Ok(file) = annotation.parse_file(line)
  let assert [declared] = annotation.extract_external_returns(file)
  declared.operator |> should.equal(TAbs("cb", TVar("cb")))
  annotation.format_file(file) |> should.equal(line)
}

pub fn external_returns_line_is_not_an_effects_annotation_test() {
  let assert Ok(annotations) =
    annotation.parse("external returns m.make : [Net]")
  annotations |> should.equal([])
}

pub fn external_returns_malformed_line_test() {
  let input =
    "effects m.a : []
external returns m.make
"
  annotation.parse_file(input)
  |> should.equal(Error(annotation.InvalidLine(2, "external returns m.make")))
}

// Helpers
//
// Shared term-building shorthand used by tests across sections.

fn union_vars(first: EffectTerm, second: String) -> EffectTerm {
  effect_term.normalize(TUnion([first, TVar(second)]))
}
