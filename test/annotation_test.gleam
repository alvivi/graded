import generators
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import gleeunit/should
import graded/internal/annotation
import graded/internal/effect_term
import graded/internal/types.{
  type EffectTerm, AnnotationLine, AssumeAnnotation, AssumeLine, BlankLine,
  Check, CommentLine, EffectAnnotation, Effects, FieldAnnotation,
  FieldAssumeLine, FunctionAssume, ModuleAssume, ParamBound, Polymorphic,
  RetainedAssumeLine, Specific, TAbs, TApp, TLabels, TUnion, TVar, UnknownClause,
  Wildcard,
}
import qcheck

// Parse
//
// Line-level parsing of `effects` and `check` annotations: effect sets,
// interleaved comments and blank lines, and rejection of malformed input.

pub fn empty_effects_test() {
  let input = "effects view : []"
  let assert Ok([
    EffectAnnotation(
      kind: Effects,
      function: "view",
      params: _,
      effects: eff,
      returns: None,
    ),
  ]) = annotation.parse(input)
  effect_term.to_effect_set(eff) |> should.equal(Specific(set.new()))
}

pub fn single_effect_test() {
  let input = "effects update : [Http]"
  let assert Ok([
    EffectAnnotation(
      kind: Effects,
      function: "update",
      params: _,
      effects: eff,
      returns: None,
    ),
  ]) = annotation.parse(input)
  effect_term.to_effect_set(eff)
  |> should.equal(Specific(set.from_list(["Http"])))
}

pub fn multiple_effects_test() {
  let input = "effects update : [Http, Dom]"
  let assert Ok([
    EffectAnnotation(
      kind: Effects,
      function: "update",
      params: _,
      effects: eff,
      returns: None,
    ),
  ]) = annotation.parse(input)
  effect_term.to_effect_set(eff)
  |> should.equal(Specific(set.from_list(["Http", "Dom"])))
}

pub fn check_line_test() {
  let input = "check view : []"
  let assert Ok([
    EffectAnnotation(
      kind: Check,
      function: "view",
      params: _,
      effects: eff,
      returns: None,
    ),
  ]) = annotation.parse(input)
  effect_term.to_effect_set(eff) |> should.equal(Specific(set.new()))
}

pub fn check_with_effects_test() {
  let input = "check update : [Http, Dom]"
  let assert Ok([
    EffectAnnotation(
      kind: Check,
      function: "update",
      params: _,
      effects: eff,
      returns: None,
    ),
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
  let assert Ok([parsed]) =
    annotation.parse("effects m.f : [] where returns : fn($op$x) -> [x]")
  let assert Some(operator) = parsed.returns
  effect_term.to_effect_set(operator)
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

pub fn reserved_sentinel_preserves_whole_file_test() {
  // A forged `$op$` line must NOT fail the whole file (`parse_file` is `try_map`),
  // which would let `read_spec` substitute an empty spec and lose hand-written
  // lines. Sibling `check`/`external` lines survive.
  let input =
    "check app/a.run : []
effects m.f : [] where returns : fn($op$x) -> [x]
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
      AnnotationLine(..),
      AnnotationLine(..),
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
      returns: None,
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
      returns: None,
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
      returns: None,
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
      returns: None,
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
    FieldAnnotation(
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
    FieldAnnotation(
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
  ext.target |> should.equal(FunctionAssume("send"))
  ext.effects |> should.equal(Some(Specific(set.from_list(["Http"]))))
}

pub fn parse_external_pure_test() {
  let input = "assume gleam/json.decode : []"
  let assert Ok(file) = annotation.parse_file(input)
  let assert [ext] = annotation.extract_externals(file)
  ext.module |> should.equal("gleam/json")
  ext.target |> should.equal(FunctionAssume("decode"))
  ext.effects |> should.equal(Some(Specific(set.new())))
}

pub fn format_external_test() {
  let ext =
    AssumeAnnotation(
      "gleam/httpc",
      FunctionAssume("send"),
      params: [],
      effects: Some(Specific(set.from_list(["Http"]))),
      returns: None,
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
  ext.target |> should.equal(ModuleAssume)
  ext.effects |> should.equal(Some(Specific(set.from_list(["Stdout"]))))
}

pub fn parse_assume_function_test() {
  let assert Ok(file) =
    annotation.parse_file("assume gleam/http/request.send : [Http]")
  let assert [ext] = annotation.extract_externals(file)
  ext.module |> should.equal("gleam/http/request")
  ext.target |> should.equal(FunctionAssume("send"))
  ext.effects |> should.equal(Some(Specific(set.from_list(["Http"]))))
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

// Bounded assume lines
//
// A bound list on a function-path assume head. The bounds are substitution
// scaffolding — a bound's name matches a call-site argument, its payload's
// free variables are the substitution keys — and they scope the line's own
// `where returns` clause.

pub fn parse_assume_function_with_bounds_test() {
  let assert Ok(file) = annotation.parse_file("assume m/ffi.each(f: [f]) : [f]")
  let assert [ext] = annotation.extract_externals(file)
  ext.module |> should.equal("m/ffi")
  ext.target |> should.equal(FunctionAssume("each"))
  ext.params |> should.equal([ParamBound("f", TVar("f"))])
  ext.effects
  |> should.equal(Some(Polymorphic(set.new(), set.from_list(["f"]))))
}

pub fn parse_assume_clause_only_bounded_test() {
  // No effects claim at all — the bounds exist to scope the clause. The bound
  // list's own colons must not be read as the effects separator.
  let line = "assume m/ffi.wrap(cb: [cb]) where returns : [cb]"
  let assert Ok(file) = annotation.parse_file(line)
  let assert [ext] = annotation.extract_externals(file)
  ext.params |> should.equal([ParamBound("cb", TVar("cb"))])
  ext.effects |> should.equal(None)
  ext.returns |> should.equal(Some(TVar("cb")))
  annotation.format_file(file) |> should.equal(line)
}

pub fn bounded_assume_round_trips_test() {
  let line = "assume m/ffi.wrap(cb: [cb]) : [] where returns : [cb]"
  let assert Ok(file) = annotation.parse_file(line)
  annotation.format_file(file) |> should.equal(line)
}

pub fn assume_second_order_effects_term_collapses_test() {
  // An `assume` effects term is flat — labels and variables. A second-order
  // application is a `TApp`, which the effect-set payload collapses to the
  // conservative `[Unknown]`.
  let assert Ok(file) =
    annotation.parse_file("assume m.f(cb: [cb]) : [action([cb])]")
  let assert [ext] = annotation.extract_externals(file)
  ext.effects |> should.equal(Some(Specific(set.from_list(["Unknown"]))))
}

pub fn an_operator_spelled_assume_term_collapses_test() {
  // The parens open after the effects separator, so they sit inside the term
  // — no bound list. `fn(cb) -> [cb]` reads through the term grammar and the
  // flat reduction collapses it to `[Unknown]`, exactly as the bracketed
  // application spelling does.
  let assert Ok(file) = annotation.parse_file("assume m.f : fn(cb) -> [cb]")
  let assert [ext] = annotation.extract_externals(file)
  ext.effects |> should.equal(Some(Specific(set.from_list(["Unknown"]))))
}

pub fn a_bounded_operator_spelled_assume_term_collapses_test() {
  // The suffix past a bound list reads the same bound grammar the boundless
  // head does, so the operator spelling parses on a bounded head too, and the
  // flat reduction collapses it to `[Unknown]` — never a parse error that
  // refuses the whole file over the one line.
  let assert Ok(file) =
    annotation.parse_file("assume m.f(cb: [cb]) : fn(x) -> [x]")
  let assert [ext] = annotation.extract_externals(file)
  ext.effects |> should.equal(Some(Specific(set.from_list(["Unknown"]))))
  ext.params |> should.equal([ParamBound(name: "cb", effects: TVar("cb"))])
}

pub fn a_bounded_effects_operator_term_reads_as_the_boundless_one_test() {
  // The same parity one status over: a bounded `effects` head accepts the
  // operator spelling its boundless twin always has. The effect-set grammar
  // has no `fn(..) -> ..` atom, so the formatter grounds either spelling to
  // the conservative collapse rather than emitting a line the parser rejects.
  let assert Ok(bounded) =
    annotation.parse_file("effects m.apply(g: [g]) : fn(x) -> [x]")
  annotation.format_file(bounded)
  |> should.equal("effects m.apply(g: [g]) : [Unknown]")
  let assert Ok(boundless) =
    annotation.parse_file("effects m.apply : fn(x) -> [x]")
  annotation.format_file(boundless)
  |> should.equal("effects m.apply : [Unknown]")
}

pub fn bounds_on_a_module_path_are_invalid_test() {
  // A module has no parameters, so a bound list on its path is a parse error
  // rather than a lint — nothing can have written the form.
  let input = "assume gleam/io(x: [X]) : []"
  annotation.parse_file(input)
  |> should.equal(Error(annotation.InvalidLine(1, input)))
}

pub fn bounds_on_a_field_path_are_invalid_test() {
  // A field's callable shape is not per-parameter, so the same refusal.
  let input = "assume m.Handler.on_click(cb: [cb]) : [Dom]"
  annotation.parse_file(input)
  |> should.equal(Error(annotation.InvalidLine(1, input)))
}

pub fn bounds_with_neither_effects_nor_clause_are_invalid_test() {
  // Same rule as the boundless spelling: a path on its own claims nothing.
  let input = "assume m.f(cb: [cb])"
  annotation.parse_file(input)
  |> should.equal(Error(annotation.InvalidLine(1, input)))
}

pub fn a_bounded_assume_wraps_its_clause_region_test() {
  // Past 80 columns the clause region moves to a continuation line; the bound
  // list stays on the head. Both forms parse to the same statement.
  let one_line =
    "assume myapp/very/long/module.wrap(callback: [FileSystem, Stdout]) : [Http] where returns : fn(cb) -> [Stdout]"
  let wrapped =
    "assume myapp/very/long/module.wrap(callback: [FileSystem, Stdout]) : [Http]
  where returns : fn(cb) -> [Stdout]"
  let assert Ok(file) = annotation.parse_file(one_line)
  annotation.format_file(file) |> should.equal(wrapped)
  let assert Ok(reparsed) = annotation.parse_file(wrapped)
  reparsed |> should.equal(file)
}

// The `where returns` clause
//
// A returned operator is a clause of the statement whose bound list scopes its
// variables, on any status. Its keyword is only a keyword at bracket depth 0.

pub fn parse_returns_clause_on_an_effects_line_test() {
  let assert Ok([annotation]) =
    annotation.parse(
      "effects m.traced(action: [action]) : [] where returns : fn(cb) -> [Stdout, action([cb])]",
    )
  annotation.params
  |> should.equal([ParamBound("action", TVar("action"))])
  annotation.returns
  |> should.equal(
    Some(TAbs(
      "cb",
      TUnion([
        TLabels(set.from_list(["Stdout"])),
        TApp(TVar("action"), TVar("cb")),
      ])
        |> effect_term.normalize,
    )),
  )
}

pub fn parse_returns_clause_on_a_check_line_test() {
  let assert Ok([annotation]) =
    annotation.parse("check m.make : [] where returns : [Stdout]")
  annotation.kind |> should.equal(Check)
  annotation.returns |> should.equal(Some(TLabels(set.from_list(["Stdout"]))))
}

pub fn parse_returns_clause_on_an_assume_line_test() {
  let assert Ok(file) =
    annotation.parse_file("assume m/ffi.make : [Net] where returns : [Net]")
  let assert [ext] = annotation.extract_externals(file)
  ext.effects |> should.equal(Some(Specific(set.from_list(["Net"]))))
  ext.returns |> should.equal(Some(TLabels(set.from_list(["Net"]))))
}

pub fn a_clause_only_assume_claims_no_effects_test() {
  // The rewrite of a standalone declaration of what a producer hands back. It
  // claims nothing about the producer's own effect, so the tiers below keep
  // answering for it — `None`, never the empty set.
  let assert Ok(file) =
    annotation.parse_file("assume m/ffi.make_client where returns : [Net]")
  let assert [ext] = annotation.extract_externals(file)
  ext.effects |> should.equal(None)
  ext.returns |> should.equal(Some(TLabels(set.from_list(["Net"]))))
  annotation.format_external(ext)
  |> should.equal("assume m/ffi.make_client where returns : [Net]")
}

pub fn a_clause_only_assume_names_no_effects_function_test() {
  // `external_function_names` keys the effects channel. A clause-only line
  // declares only what the producer returns, so it must not drop the inferred
  // `effects` line for the name or blank its bounds.
  let assert Ok(file) =
    annotation.parse_file("assume m.make where returns : [Net]")
  annotation.external_function_names(file)
  |> set.to_list
  |> should.equal([])
}

pub fn a_clause_on_a_field_path_is_invalid_test() {
  let input = "assume m.Handler.on_click where returns : [X]"
  annotation.parse_file(input)
  |> should.equal(Error(annotation.InvalidLine(1, input)))
}

pub fn a_clause_keyword_inside_brackets_is_not_a_clause_test() {
  // The keyword only opens a clause at depth 0, so this text stays inside the
  // effect set — where it is not one identifier, and so is a parse error rather
  // than a variable named after the keyword.
  let input = "effects m.f : [A, where returns : B]"
  annotation.parse_file(input)
  |> should.equal(Error(annotation.InvalidLine(1, input)))
}

pub fn a_clause_with_no_colon_is_invalid_test() {
  let input = "effects m.f : [] where returns [Stdout]"
  annotation.parse_file(input)
  |> should.equal(Error(annotation.InvalidLine(1, input)))
}

// Near-misses of the clause keyword
//
// The region opens on the literal ` where `. Spelled without the space before
// it, the split misses it and the whole clause stays inside the effect set,
// where it once parsed as a variable named after the typo — and formatted back
// byte-identically, so the typo never surfaced. That shape is a parse error
// naming the line instead.

pub fn a_clause_with_no_space_before_its_colon_parses_test() {
  // The colon separating a clause's key from its payload needs no space around
  // it: the entry splits at its first depth-0 colon and the key is trimmed.
  let assert Ok([check]) =
    annotation.parse("check m.f : [] where returns: [Stdout]")
  check.returns
  |> should.equal(
    Some(effect_term.from_effect_set(Specific(set.from_list(["Stdout"])))),
  )

  let assert Ok([effects]) =
    annotation.parse("effects m.f : [] where returns: [Stdout]")
  effects.returns
  |> should.equal(
    Some(effect_term.from_effect_set(Specific(set.from_list(["Stdout"])))),
  )
}

pub fn a_clause_with_no_space_after_the_effects_is_invalid_test() {
  let input = "check m.f : []where returns : [Stdout]"
  annotation.parse_file(input)
  |> should.equal(Error(annotation.InvalidLine(1, input)))

  let input = "effects m.f : []where returns : [Stdout]"
  annotation.parse_file(input)
  |> should.equal(Error(annotation.InvalidLine(1, input)))
}

pub fn a_clause_behind_extra_spaces_still_parses_test() {
  // The one near-miss that is not one: an extra space before the keyword leaves
  // the keyword itself intact, so the clause splits off and formats canonically.
  let assert Ok([check]) =
    annotation.parse("check m.f : []  where returns : [Stdout]")
  check.returns
  |> should.equal(
    Some(effect_term.from_effect_set(Specific(set.from_list(["Stdout"])))),
  )

  let assert Ok([effects]) =
    annotation.parse("effects m.f : []  where returns : [Stdout]")
  effects.returns
  |> should.equal(
    Some(effect_term.from_effect_set(Specific(set.from_list(["Stdout"])))),
  )
}

pub fn a_forged_sentinel_in_a_clause_grounds_test() {
  // The `$op$` reservation holds inside a clause: a forged sentinel grounds to
  // `[Unknown]` rather than minting a variable that could pass for a
  // producer's own.
  let assert Ok([annotation]) =
    annotation.parse("effects m.f : [] where returns : [$op$forged]")
  annotation.returns |> should.equal(Some(effect_term.unknown()))
}

pub fn clause_free_vars_names_the_open_variables_test() {
  let assert Ok([closed]) =
    annotation.parse("effects m.f : [] where returns : [Stdout]")
  annotation.clause_free_vars(closed.returns) |> set.to_list |> should.equal([])

  let assert Ok([open]) =
    annotation.parse("effects m.f : [] where returns : [Stdout, action]")
  annotation.clause_free_vars(open.returns)
  |> set.to_list
  |> should.equal(["action"])

  let assert Ok([bound]) =
    annotation.parse("effects m.f : [] where returns : fn(cb) -> [cb]")
  annotation.clause_free_vars(bound.returns) |> set.to_list |> should.equal([])

  annotation.clause_free_vars(None) |> set.to_list |> should.equal([])
}

pub fn a_params_list_with_no_name_is_invalid_test() {
  let input = "check (f: [Stdout]) : [Stdout]"
  annotation.parse_file(input)
  |> should.equal(Error(annotation.InvalidLine(1, input)))
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

pub fn a_returns_line_is_a_retired_spelling_test() {
  let input = "returns m.make : [Stdout]"
  annotation.parse_file(input)
  |> should.equal(
    Error(annotation.RetiredSpelling(1, input, annotation.RetiredReturns)),
  )
  annotation.describe_parse_error(annotation.RetiredSpelling(
    1,
    input,
    annotation.RetiredReturns,
  ))
  |> should.equal(
    "1: returns m.make : [Stdout]\n  `returns <path> : <operator>` is retired; delete it — `graded infer` writes the operator as a `where returns` clause on the `effects <path>` line",
  )
}

pub fn an_external_returns_line_is_a_retired_spelling_test() {
  let input = "external returns m/ffi.make : [Net]"
  annotation.parse_file(input)
  |> should.equal(
    Error(annotation.RetiredSpelling(
      1,
      input,
      annotation.RetiredExternalReturns,
    )),
  )
  annotation.describe_parse_error(annotation.RetiredSpelling(
    1,
    input,
    annotation.RetiredExternalReturns,
  ))
  |> should.equal(
    "1: external returns m/ffi.make : [Net]\n  `external returns <path> : <operator>` is retired; write `assume <path> where returns : <operator>`",
  )
}

pub fn the_line_half_of_a_description_stays_on_one_line_test() {
  // What a caller wrapping the description in a sentence reads. A retired
  // spelling's rewrite is a second line, so the full description would leave
  // the sentence's tail dangling under it — this half never does.
  annotation.describe_parse_error_line(annotation.RetiredSpelling(
    24,
    "returns girard.disk_resolver : [FileSystem]",
    annotation.RetiredReturns,
  ))
  |> should.equal("24: returns girard.disk_resolver : [FileSystem]")

  annotation.describe_parse_error_line(annotation.InvalidLine(3, "  nonsense "))
  |> should.equal("3: nonsense")
}

pub fn no_retired_line_parses_as_anything_test() {
  // Every retired opener is refused outright — none falls through to another
  // arm and keys something the author did not write.
  [
    "type m.Handler.on_click : [Dom]",
    "type Handler.on_click : [Dom]",
    "external effects m/ffi.send : [Http]",
    "external effects m/ffi : [Http]",
    "returns m.make : [Stdout]",
    "returns m.make : fn(cb) -> [cb]",
    "external returns m/ffi.make : [Net]",
    "external returns m/ffi : [Net]",
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

pub fn a_retained_line_sorts_and_reports_by_its_bare_path_test() {
  // A bounded retained line is ordered and named by the bare path a bounded
  // external's sort key spells — the unparsed bound text stays only in the
  // rendering, which keeps the line verbatim.
  let input =
    "assume dep.make(cb: [cb]) where future : [X]
assume dep.also(cb: [cb]) : [cb] where future : [X]
"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.unknown_clause_lines(file)
  |> should.equal([#("dep.make", ["future"]), #("dep.also", ["future"])])
  annotation.format_sorted(file)
  |> should.equal(
    "assume dep.also(cb: [cb]) : [cb] where future : [X]
assume dep.make(cb: [cb]) where future : [X]
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
      returns: None,
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
      returns: None,
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
  let assert [FieldAssumeLine(parsed, _)] = file.lines
  parsed |> should.equal(tf)
}

pub fn external_roundtrip_test() {
  use ext <- qcheck.given(generators.external_gen())
  let formatted = annotation.format_external(ext)
  let assert Ok(file) = annotation.parse_file(formatted)
  let assert [AssumeLine(parsed, _)] = file.lines
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
  let merged = annotation.merge_inferred(file, inferred, set.new(), set.new())
  let merged_effects =
    annotation.extract_annotations(merged)
    |> list.filter(fn(a) { a.kind == Effects })

  // Non-effects lines preserved in order
  let non_effects = fn(f: types.GradedFile) {
    list.filter(f.lines, fn(line) {
      case line {
        AnnotationLine(a, _) -> a.kind != Effects
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
      AssumeLine(
        AssumeAnnotation(
          module: "app",
          target: FunctionAssume("ffi"),
          params: [],
          effects: Some(types.Specific(set.new())),
          returns: None,
        ),
        [],
      ),
    ])
  let inferred = [
    EffectAnnotation(
      Effects,
      "app.ffi",
      [],
      effect_term.unknown(),
      returns: None,
    ),
    EffectAnnotation(
      Effects,
      "app.other",
      [],
      effect_term.pure(),
      returns: None,
    ),
  ]
  let effects_fns =
    annotation.merge_inferred(file, inferred, set.new(), set.new())
    |> annotation.extract_annotations
    |> list.filter(fn(a) { a.kind == Effects })
    |> list.map(fn(a) { a.function })
    |> set.from_list()
  set.contains(effects_fns, "app.ffi") |> should.be_false()
  set.contains(effects_fns, "app.other") |> should.be_true()
}

// An assumption suppresses one channel
//
// A declaration of what a function *does* says nothing about what it *returns*.
// The clause has no line of its own to live on, so an inferred one keeps its
// `effects` line alive under an assumption that would otherwise delete it —
// and only the clause does: a clause-less line claims nothing the declaration
// does not.

fn inferred_line(
  name: String,
  returns: option.Option(EffectTerm),
) -> types.EffectAnnotation {
  EffectAnnotation(
    Effects,
    name,
    [],
    TLabels(set.from_list(["Stdout"])),
    returns:,
  )
}

fn module_assume(module: String) -> types.GradedLine {
  AssumeLine(
    AssumeAnnotation(
      module:,
      target: ModuleAssume,
      params: [],
      effects: Some(types.Specific(set.new())),
      returns: None,
    ),
    [],
  )
}

fn function_assume(module: String, function: String) -> types.GradedLine {
  AssumeLine(
    AssumeAnnotation(
      module:,
      target: FunctionAssume(function),
      params: [],
      effects: Some(types.Specific(set.new())),
      returns: None,
    ),
    [],
  )
}

// The `effects` lines a merge writes, paired with the clause each carries.
fn merged_effects(
  file: types.GradedFile,
  inferred: List(types.EffectAnnotation),
) -> List(#(String, option.Option(EffectTerm))) {
  annotation.merge_inferred(file, inferred, set.new(), set.new())
  |> annotation.extract_annotations
  |> list.filter(fn(a) { a.kind == Effects })
  |> list.map(fn(a) { #(a.function, a.returns) })
}

pub fn merge_inferred_keeps_a_clause_under_a_module_assume_test() {
  let clause = Some(TLabels(set.from_list(["Net"])))
  merged_effects(types.GradedFile(lines: [module_assume("db")]), [
    inferred_line("db.make", clause),
    inferred_line("db.plain", None),
  ])
  |> should.equal([#("db.make", clause)])
}

pub fn merge_inferred_keeps_a_clause_under_a_function_assume_test() {
  let clause = Some(TLabels(set.from_list(["Net"])))
  merged_effects(
    types.GradedFile(lines: [
      function_assume("db", "make"),
      function_assume("db", "plain"),
    ]),
    [inferred_line("db.make", clause), inferred_line("db.plain", None)],
  )
  |> should.equal([#("db.make", clause)])
}

pub fn merge_inferred_composes_the_two_assume_channels_test() {
  // Both declarations cover `db.make`: the returns one strips the clause, and
  // the effects one then has a clause-less line to drop. Nothing of the
  // inferred line survives — the alternative is a line kept alive by a clause
  // the declaration above it already answers for.
  merged_effects(
    types.GradedFile(lines: [
      module_assume("db"),
      AssumeLine(
        AssumeAnnotation(
          module: "db",
          target: FunctionAssume("make"),
          params: [],
          effects: None,
          returns: Some(TLabels(set.from_list(["Net"]))),
        ),
        [],
      ),
    ]),
    [inferred_line("db.make", Some(TLabels(set.from_list(["Stdout"]))))],
  )
  |> should.equal([])
}

pub fn merge_inferred_over_a_kept_clause_line_is_idempotent_test() {
  // The second `infer` over an unchanged package: the kept line is updated in
  // place with the same inference it already holds, so the file does not move.
  let clause = Some(TLabels(set.from_list(["Net"])))
  let file =
    types.GradedFile(lines: [
      module_assume("db"),
      AnnotationLine(inferred_line("db.make", clause), []),
    ])
  annotation.merge_inferred(
    file,
    [inferred_line("db.make", clause)],
    set.new(),
    set.new(),
  )
  |> should.equal(file)
}

pub fn merge_inferred_keeps_a_declared_returns_clause_test() {
  // A declaration is preserved in place and never regenerated, and the inferred
  // clause for the same name is dropped: one name, one answer.
  let declared =
    AssumeLine(
      AssumeAnnotation(
        module: "app",
        target: FunctionAssume("make"),
        params: [],
        effects: None,
        returns: Some(TLabels(set.from_list(["Net"]))),
      ),
      [],
    )
  let file = types.GradedFile(lines: [declared])
  let inferred = [
    EffectAnnotation(
      Effects,
      "app.make",
      [],
      TLabels(set.new()),
      returns: Some(TLabels(set.new())),
    ),
    EffectAnnotation(
      Effects,
      "app.other",
      [],
      TLabels(set.new()),
      returns: Some(TLabels(set.new())),
    ),
  ]
  annotation.merge_inferred(file, inferred, set.new(), set.new())
  |> should.equal(
    types.GradedFile(lines: [
      declared,
      AnnotationLine(
        EffectAnnotation(
          Effects,
          "app.make",
          [],
          TLabels(set.new()),
          returns: None,
        ),
        [],
      ),
      AnnotationLine(
        EffectAnnotation(
          Effects,
          "app.other",
          [],
          TLabels(set.new()),
          returns: Some(TLabels(set.new())),
        ),
        [],
      ),
    ]),
  )
}

pub fn merge_inferred_keeps_an_unmatched_returns_clause_test() {
  // A declaration for a function inference no longer reports a summary for is
  // still the author's line, so the stale-removal path does not reach it.
  let file =
    types.GradedFile(lines: [
      AssumeLine(
        AssumeAnnotation(
          module: "app",
          target: FunctionAssume("make"),
          params: [],
          effects: None,
          returns: Some(TLabels(set.from_list(["Net"]))),
        ),
        [],
      ),
    ])
  annotation.merge_inferred(file, [], set.new(), set.new())
  |> should.equal(file)
}

pub fn merge_inferred_rewrites_a_stale_returns_clause_test() {
  // The line names one of this package's own ordinary functions, so it declares
  // nothing: it is deleted and the inferred clause it was suppressing is
  // written on the function's `effects` line.
  let file =
    types.GradedFile(lines: [
      AssumeLine(
        AssumeAnnotation(
          module: "app",
          target: FunctionAssume("make"),
          params: [],
          effects: None,
          returns: Some(TLabels(set.from_list(["Net"]))),
        ),
        [],
      ),
    ])
  let inferred = [
    EffectAnnotation(
      Effects,
      "app.make",
      [],
      TLabels(set.new()),
      returns: Some(TLabels(set.from_list(["Disk"]))),
    ),
  ]
  annotation.merge_inferred(
    file,
    inferred,
    set.new(),
    set.from_list(["app.make"]),
  )
  |> should.equal(
    types.GradedFile(lines: [
      AnnotationLine(
        EffectAnnotation(
          Effects,
          "app.make",
          [],
          TLabels(set.new()),
          returns: Some(TLabels(set.from_list(["Disk"]))),
        ),
        [],
      ),
    ]),
  )
}

pub fn merge_inferred_keeps_the_two_stale_channels_apart_test() {
  // A stale returns-declaration name reaching the effects channel's filters
  // would delete the function's own `effects` line, which nothing declared
  // anything about.
  let file =
    types.GradedFile(lines: [
      AssumeLine(
        AssumeAnnotation(
          module: "app",
          target: FunctionAssume("make"),
          params: [],
          effects: None,
          returns: Some(TLabels(set.from_list(["Net"]))),
        ),
        [],
      ),
      AnnotationLine(
        EffectAnnotation(
          Effects,
          "app.make",
          [],
          TLabels(set.new()),
          returns: None,
        ),
        [],
      ),
    ])
  let inferred = [
    EffectAnnotation(
      Effects,
      "app.make",
      [],
      TLabels(set.from_list(["Disk"])),
      returns: None,
    ),
  ]
  annotation.merge_inferred(
    file,
    inferred,
    set.new(),
    set.from_list(["app.make"]),
  )
  |> should.equal(
    types.GradedFile(lines: [
      AnnotationLine(
        EffectAnnotation(
          Effects,
          "app.make",
          [],
          TLabels(set.from_list(["Disk"])),
          returns: None,
        ),
        [],
      ),
    ]),
  )
}

pub fn merge_inferred_keeps_bounds_on_a_stale_conversion_test() {
  // Every claim on the line went stale while an unknown clause survives: the
  // line converts to a retained one, and the bound list rides the retained
  // path rather than being dropped by the conversion.
  let file =
    types.GradedFile(lines: [
      AssumeLine(
        AssumeAnnotation(
          module: "app",
          target: FunctionAssume("make"),
          params: [ParamBound("cb", TVar("cb"))],
          effects: Some(Polymorphic(set.new(), set.from_list(["cb"]))),
          returns: None,
        ),
        [UnknownClause(key: "future", payload: "[X]")],
      ),
    ])
  annotation.merge_inferred(file, [], set.from_list(["app.make"]), set.new())
  |> should.equal(
    types.GradedFile(lines: [
      RetainedAssumeLine(path: "app.make(cb: [cb])", unknown_clauses: [
        UnknownClause(key: "future", payload: "[X]"),
      ]),
    ]),
  )
}

pub fn a_bounded_external_still_suppresses_the_inferred_line_test() {
  // Suppression keys off the effects claim's presence, not the bound list.
  let file =
    types.GradedFile(lines: [
      AssumeLine(
        AssumeAnnotation(
          module: "m/ffi",
          target: FunctionAssume("each"),
          params: [ParamBound("f", TVar("f"))],
          effects: Some(Polymorphic(set.new(), set.from_list(["f"]))),
          returns: None,
        ),
        [],
      ),
    ])
  let inferred = [
    EffectAnnotation(
      Effects,
      "m/ffi.each",
      [],
      TLabels(set.new()),
      returns: None,
    ),
  ]
  annotation.merge_inferred(file, inferred, set.new(), set.new())
  |> should.equal(file)
}

pub fn a_clause_only_bounded_line_does_not_suppress_the_inferred_line_test() {
  // A clause-only line claims nothing on the effects channel, bounds or not,
  // so the inferred `effects` line survives beside it.
  let declared =
    AssumeLine(
      AssumeAnnotation(
        module: "m/ffi",
        target: FunctionAssume("wrap"),
        params: [ParamBound("cb", TVar("cb"))],
        effects: None,
        returns: Some(TVar("cb")),
      ),
      [],
    )
  let inferred_line =
    EffectAnnotation(
      Effects,
      "m/ffi.wrap",
      [],
      TLabels(set.new()),
      returns: None,
    )
  annotation.merge_inferred(
    types.GradedFile(lines: [declared]),
    [inferred_line],
    set.new(),
    set.new(),
  )
  |> should.equal(
    types.GradedFile(lines: [declared, AnnotationLine(inferred_line, [])]),
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
      returns: None,
    )
  annotation.format_annotation(ann)
  |> should.equal("effects with_logger(action: [action]) : [action([Stdout])]")
}

pub fn residual_abstraction_in_an_effect_set_renders_parseably_test() {
  // An under-applied operator left in *effect* position. The effect-set grammar
  // has no `fn(..) -> ..` atom, so rendering the abstraction would emit a line
  // the parser rejects — `graded infer` would write a spec that fails to read
  // back. It grounds to the conservative collapse instead.
  let ann =
    EffectAnnotation(
      Effects,
      "probe.caller",
      [],
      TAbs("b", TVar("b")),
      returns: None,
    )
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
      returns: None,
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
  let ann = EffectAnnotation(Effects, "f", [], normalized, returns: None)
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

// Inferred returned operators
//
// `where returns : fn(cb) -> [...]` clauses carrying an operator term for a
// function's return value.

pub fn returns_clause_round_trip_test() {
  let line = "effects app/dep.pick : [] where returns : fn(cb) -> [cb]"
  let assert Ok(file) = annotation.parse_file(line)
  let assert [parsed] = annotation.extract_annotations(file)
  parsed.function |> should.equal("app/dep.pick")
  parsed.returns |> should.equal(Some(TAbs("cb", TVar("cb"))))
  annotation.format_file(file) |> should.equal(line)
}

pub fn returns_clause_multi_callback_round_trip_test() {
  let line = "effects m.pick : [] where returns : fn(a, b) -> [a, b]"
  let assert Ok(file) = annotation.parse_file(line)
  let assert [parsed] = annotation.extract_annotations(file)
  parsed.returns
  |> should.equal(Some(TAbs("a", TAbs("b", union_vars(TVar("a"), "b")))))
  annotation.format_file(file) |> should.equal(line)
}

// Declared returned operators
//
// `assume module.fn where returns : [Net]` lines declaring the operator a
// foreign producer hands back. Same operator grammar as an inferred clause.

pub fn declared_returns_clause_round_trip_test() {
  let line = "assume app/ffi.make_client where returns : [Net]"
  let assert Ok(file) = annotation.parse_file(line)
  let assert [declared] = annotation.extract_externals(file)
  declared.module |> should.equal("app/ffi")
  declared.target |> should.equal(FunctionAssume("make_client"))
  declared.returns |> should.equal(Some(TLabels(set.from_list(["Net"]))))
  annotation.format_file(file) |> should.equal(line)
}

pub fn declared_returns_operator_clause_round_trip_test() {
  let line = "assume m.wrap where returns : fn(cb) -> [cb]"
  let assert Ok(file) = annotation.parse_file(line)
  let assert [declared] = annotation.extract_externals(file)
  declared.returns |> should.equal(Some(TAbs("cb", TVar("cb"))))
  annotation.format_file(file) |> should.equal(line)
}

pub fn declared_returns_clause_is_not_an_effects_annotation_test() {
  let assert Ok(annotations) =
    annotation.parse("assume m.make where returns : [Net]")
  annotations |> should.equal([])
}

// The clause list
//
// A `where` region is a comma-separated list. `returns` is the one key this
// version reads; every other key is retained verbatim, ignored for resolution,
// and re-emitted on every rewrite.

pub fn an_unknown_clause_is_retained_and_keys_nothing_test() {
  let line = "effects m.f : [] where future : [X]"
  let assert Ok(file) = annotation.parse_file(line)
  let assert [AnnotationLine(parsed, clauses)] = file.lines
  parsed.returns |> should.equal(None)
  clauses |> should.equal([UnknownClause(key: "future", payload: "[X]")])
  annotation.format_file(file) |> should.equal(line)
}

pub fn a_known_clause_reads_from_any_list_position_test() {
  let stdout = Some(TLabels(set.from_list(["A"])))

  let assert Ok([first]) =
    annotation.parse("effects m.f : [] where returns : [A], future : [X]")
  first.returns |> should.equal(stdout)

  let assert Ok([last]) =
    annotation.parse("effects m.f : [] where future : [X], returns : [A]")
  last.returns |> should.equal(stdout)
}

pub fn a_repeated_returns_clause_is_invalid_test() {
  // One slot, so a silent last-wins would be exactly the quiet bug the list
  // grammar exists to keep out.
  let input = "effects m.f : [] where returns : [A], returns : [B]"
  annotation.parse_file(input)
  |> should.equal(Error(annotation.InvalidLine(1, input)))
}

pub fn repeated_unknown_clauses_are_all_retained_in_order_test() {
  // This version cannot know whether a future key may repeat, so it keeps what
  // was written and leaves the judgement to the reader that understands it.
  let line = "effects m.f : [] where future : [X], future : [Y]"
  let assert Ok(file) = annotation.parse_file(line)
  let assert [AnnotationLine(_, clauses)] = file.lines
  clauses
  |> should.equal([
    UnknownClause(key: "future", payload: "[X]"),
    UnknownClause(key: "future", payload: "[Y]"),
  ])
  annotation.format_file(file) |> should.equal(line)
}

pub fn a_dotted_or_numeric_clause_key_is_retained_test() {
  // The charset admits the spellings a later grammar is most likely to mint,
  // without endorsing any of them: a reader that rejected these would be the
  // thing blocking the grammar it exists to leave room for.
  ["returns.0", "returns.Ok.0", "returns.returns", "raises_2"]
  |> list.each(fn(key) {
    let line = "effects m.f : [] where " <> key <> " : [X]"
    let assert Ok(file) = annotation.parse_file(line)
    let assert [AnnotationLine(parsed, clauses)] = file.lines
    parsed.returns |> should.equal(None)
    clauses |> should.equal([UnknownClause(key:, payload: "[X]")])
    annotation.format_file(file) |> should.equal(line)
  })
}

pub fn a_malformed_clause_entry_is_invalid_test() {
  // Never bless malformed syntax as "unknown": whatever this version accepts is
  // accepted permanently.
  [
    "effects m.f : [] where : [X]", "effects m.f : [] where k :",
    "effects m.f : [] where a : [X],, b : [Y]",
    "effects m.f : [] where a b : [X]",
  ]
  |> list.each(fn(input) {
    annotation.parse_file(input)
    |> should.equal(Error(annotation.InvalidLine(1, input)))
  })
}

pub fn a_payload_with_unbalanced_delimiters_is_invalid_test() {
  // A net-depth check waves each of these through; a retained clause is
  // re-emitted verbatim, so corrupt text would round-trip as well-formed.
  [
    "effects m.f : [] where foo : ([)]", "effects m.f : [] where foo : )(",
    "effects m.f : [] where foo : [A", "effects m.f : [] where foo : A]",
  ]
  |> list.each(fn(input) {
    annotation.parse_file(input)
    |> should.equal(Error(annotation.InvalidLine(1, input)))
  })
}

pub fn a_nested_comma_does_not_split_the_clause_list_test() {
  // Effect sets are `[...]` and operators `fn(...)`, both depth ≥ 1, so a
  // depth-0 comma is unambiguously a separator.
  let line = "effects m.f : [] where future : fn(a, b) -> [X, Y]"
  let assert Ok(file) = annotation.parse_file(line)
  let assert [AnnotationLine(_, clauses)] = file.lines
  clauses
  |> should.equal([
    UnknownClause(key: "future", payload: "fn(a, b) -> [X, Y]"),
  ])
}

pub fn a_payload_keeps_its_interior_whitespace_test() {
  // This version cannot canonically render a grammar it does not know, so it
  // must not reformat the interior — a future grammar may well be
  // whitespace-significant somewhere 1.0 cannot see. Only the edges normalize.
  let assert Ok(file) =
    annotation.parse_file(
      "effects m.f : []  where  future  :  fn(a,   b) ->  [X]",
    )
  let assert [AnnotationLine(_, clauses)] = file.lines
  clauses
  |> should.equal([
    UnknownClause(key: "future", payload: "fn(a,   b) ->  [X]"),
  ])
  annotation.format_file(file)
  |> should.equal("effects m.f : [] where future : fn(a,   b) ->  [X]")
}

// Lines retained for their unknown clauses alone
//
// An `assume` line whose every clause is one this version does not know carries
// no semantics at all. It parses, keys nothing, and round-trips — over all
// three path shapes, so what a line keys never depends on its path's casing.

pub fn a_function_assume_with_only_an_unknown_clause_is_retained_test() {
  let line = "assume dep.make where returns.0 : [Net]"
  let assert Ok(file) = annotation.parse_file(line)
  file.lines
  |> should.equal([
    RetainedAssumeLine(path: "dep.make", unknown_clauses: [
      UnknownClause(key: "returns.0", payload: "[Net]"),
    ]),
  ])
  annotation.extract_externals(file) |> should.equal([])
  annotation.extract_annotations(file) |> should.equal([])
  annotation.format_file(file) |> should.equal(line)
}

pub fn a_module_assume_with_only_an_unknown_clause_is_retained_test() {
  let line = "assume dep/x where future : [X]"
  let assert Ok(file) = annotation.parse_file(line)
  file.lines
  |> should.equal([
    RetainedAssumeLine(path: "dep/x", unknown_clauses: [
      UnknownClause(key: "future", payload: "[X]"),
    ]),
  ])
  annotation.module_external_modules(file) |> set.to_list() |> should.equal([])
  annotation.format_file(file) |> should.equal(line)
}

pub fn a_field_assume_with_only_an_unknown_clause_is_retained_test() {
  // `FieldAnnotation.effects` is a bare term, so a field line cannot claim
  // nothing — and fabricating `[]` would flip *keys nothing* into *is pure*.
  let line = "assume m.Handler.on_click where future : [X]"
  let assert Ok(file) = annotation.parse_file(line)
  file.lines
  |> should.equal([
    RetainedAssumeLine(path: "m.Handler.on_click", unknown_clauses: [
      UnknownClause(key: "future", payload: "[X]"),
    ]),
  ])
  annotation.extract_type_fields(file) |> should.equal([])
  annotation.format_file(file) |> should.equal(line)
}

pub fn a_retained_assume_sorts_into_the_assume_section_test() {
  let assert Ok(file) =
    annotation.parse_file(
      "effects z.f : []
assume m.b where future : [X]
assume m.a : [Net]
check y.g : []",
    )
  annotation.format_sorted(file)
  |> should.equal(
    "assume m.a : [Net]
assume m.b where future : [X]

check y.g : []

effects z.f : []
",
  )
}

pub fn a_path_a_retained_assume_cannot_name_is_invalid_test() {
  // The path is still read for its shape: a malformed one is refused rather
  // than retained.
  let input = "assume m..f where future : [X]"
  annotation.parse_file(input)
  |> should.equal(Error(annotation.InvalidLine(1, input)))
}

pub fn a_bounded_assume_with_only_an_unknown_clause_keeps_its_bounds_test() {
  // The bound list is part of the retained path text — a line that keys
  // nothing gives it no semantics — and its colons must not read as the
  // effects separator.
  let line = "assume dep.make(cb: [cb]) where future : [X]"
  let assert Ok(file) = annotation.parse_file(line)
  file.lines
  |> should.equal([
    RetainedAssumeLine(path: "dep.make(cb: [cb])", unknown_clauses: [
      UnknownClause(key: "future", payload: "[X]"),
    ]),
  ])
  annotation.extract_externals(file) |> should.equal([])
  annotation.format_file(file) |> should.equal(line)
}

pub fn a_retained_assume_keeps_a_payload_this_version_cannot_read_test() {
  // A retained bound list is left unparsed as well as unrewritten: a payload
  // in a newer version's grammar rides through this one verbatim instead of
  // failing the file.
  let line = "assume dep.make(cb: future([X])) where future : [X]"
  let assert Ok(file) = annotation.parse_file(line)
  file.lines
  |> should.equal([
    RetainedAssumeLine(path: "dep.make(cb: future([X]))", unknown_clauses: [
      UnknownClause(key: "future", payload: "[X]"),
    ]),
  ])
  annotation.extract_externals(file) |> should.equal([])
  annotation.format_file(file) |> should.equal(line)
}

pub fn a_retained_bound_list_still_needs_a_function_path_test() {
  // Only the path shape is read on a retained bounded head, and a module
  // still has no parameter slot for the paren group.
  let input = "assume gleam/io(cb: future([X])) where future : [X]"
  annotation.parse_file(input)
  |> should.equal(Error(annotation.InvalidLine(1, input)))
}

pub fn bounds_beside_an_effects_claim_still_parse_test() {
  // An effects clause is a claim this version reads, and bounds beside one
  // are its semantics — a payload today's grammar cannot read is refused
  // loudly, unknown clauses or not.
  let input = "assume dep.make(cb: future([X])) : [] where future : [X]"
  annotation.parse_file(input)
  |> should.equal(Error(annotation.InvalidLine(1, input)))
}

// Wrapped statements
//
// A statement may be written on one physical line or across several, and the
// reader accepts both. A continuation is an indented line that is also at a
// clause boundary — indentation alone is not the rule.

pub fn a_wrapped_statement_parses_as_its_one_line_form_test() {
  let one_line =
    "effects m.f : [] where returns : [A], future : [X], other : [Y]"
  let wrapped =
    "effects m.f : []
  where returns : [A],
        future : [X],
        other : [Y]"
  let assert Ok(from_one_line) = annotation.parse_file(one_line)
  let assert Ok(from_wrapped) = annotation.parse_file(wrapped)
  from_wrapped |> should.equal(from_one_line)
}

pub fn a_wrapped_payload_keeps_its_interior_bytes_test() {
  // Fragments only ever join at clause boundaries, so a payload lies wholly
  // within one physical line and its interior survives untouched.
  let assert Ok(file) =
    annotation.parse_file(
      "effects m.f : []
  where future : fn(a,   b) ->  [X],
        other : [A,  B]",
    )
  let assert [AnnotationLine(_, clauses)] = file.lines
  clauses
  |> should.equal([
    UnknownClause(key: "future", payload: "fn(a,   b) ->  [X]"),
    UnknownClause(key: "other", payload: "[A,  B]"),
  ])
}

pub fn a_clause_key_spelled_like_a_statement_keyword_test() {
  // The key charset admits `effects`, `check` and `assume`, so in an open clause
  // region the clause reading is decided before any keyword is matched.
  ["effects", "check", "assume"]
  |> list.each(fn(keyword) {
    let assert Ok(file) = annotation.parse_file("effects m.f : []
  where future : [X],
        " <> keyword <> " : [Y]")
    let assert [AnnotationLine(parsed, clauses)] = file.lines
    parsed.function |> should.equal("m.f")
    clauses
    |> should.equal([
      UnknownClause(key: "future", payload: "[X]"),
      UnknownClause(key: keyword, payload: "[Y]"),
    ])
  })
}

pub fn an_indented_comment_is_still_a_comment_test() {
  // The backward-compatibility trap: a careless continuation rule silently
  // converts both of these.
  let assert Ok(file) =
    annotation.parse_file(
      "effects m.f : []
  // indented comment
  effects m.g : []",
    )
  file.lines
  |> should.equal([
    AnnotationLine(pure_line("m.f"), []),
    CommentLine("  // indented comment"),
    AnnotationLine(pure_line("m.g"), []),
  ])
}

pub fn an_indented_statement_after_a_statement_is_its_own_line_test() {
  let assert Ok(file) =
    annotation.parse_file(
      "effects m.f : []
  effects m.g : []",
    )
  file.lines
  |> should.equal([
    AnnotationLine(pure_line("m.f"), []),
    AnnotationLine(pure_line("m.g"), []),
  ])
}

pub fn a_completed_wrapped_statement_is_flushed_by_a_comment_test() {
  let assert Ok(file) =
    annotation.parse_file(
      "effects m.f : []
  where returns : [A]
  // trailing comment

effects m.g : []",
    )
  file.lines
  |> should.equal([
    AnnotationLine(
      EffectAnnotation(
        ..pure_line("m.f"),
        returns: Some(TLabels(set.from_list(["A"]))),
      ),
      [],
    ),
    CommentLine("  // trailing comment"),
    BlankLine,
    AnnotationLine(pure_line("m.g"), []),
  ])
}

pub fn an_incomplete_wrapped_statement_names_its_first_line_test() {
  // The error points at the statement to fix and the line it starts on.
  annotation.parse_file(
    "// header
effects m.f : []
  where returns : [A],",
  )
  |> should.equal(
    Error(annotation.InvalidLine(2, "effects m.f : [] where returns : [A],")),
  )
}

pub fn a_where_region_opened_with_nothing_after_it_is_invalid_test() {
  let input = "effects m.f : [] where"
  annotation.parse_file(input)
  |> should.equal(Error(annotation.InvalidLine(1, input)))
}

pub fn an_orphan_clause_line_is_invalid_test() {
  // No comma after `[X]`, so the region closed and `b : [Y]` continues nothing.
  annotation.parse_file(
    "effects m.f : []
  where a : [X]
  b : [Y]",
  )
  |> should.equal(Error(annotation.InvalidLine(3, "  b : [Y]")))
}

pub fn an_indented_typo_is_a_failed_statement_not_a_continuation_test() {
  annotation.parse_file(
    "effects m.f : []
  effect m.g : []",
  )
  |> should.equal(Error(annotation.InvalidLine(2, "  effect m.g : []")))
}

// The wrap rule
//
// A statement renders on one line where it fits in 80 graphemes; past that its
// whole clause region moves to continuation lines, one clause each.

pub fn a_statement_at_the_width_stays_on_one_line_test() {
  // The function name is padded so the one-line rendering lands exactly on the
  // boundary, and then one grapheme past it.
  let inline = wrapping_probe(40)
  string.length(inline) |> should.equal(80)
  string.contains(inline, "\n") |> should.be_false()

  wrapping_probe(41)
  |> should.equal(
    "effects m."
    <> string.repeat("a", 41)
    <> " : []\n  where returns : [Stdout]",
  )
}

pub fn the_width_is_measured_in_graphemes_test() {
  // Not bytes: a multi-byte label would otherwise put the boundary somewhere
  // implementation-dependent, and `format --check` is a CI gate.
  let line =
    "effects m." <> string.repeat("é", 40) <> " : [] where returns : [Stdout]"
  string.length(line) |> should.equal(80)
  let assert Ok(file) = annotation.parse_file(line)
  annotation.format_file(file) |> should.equal(line)
}

pub fn a_long_effect_set_without_a_clause_does_not_wrap_test() {
  // The trigger does not promise 80 columns: only the clause region wraps.
  let line =
    "effects m.f : [Aaa, Bbb, Ccc, Ddd, Eee, Fff, Ggg, Hhh, Iii, Jjj, Kkk, Lll, Mmm, Nnn]"
  let assert Ok(file) = annotation.parse_file(line)
  { string.length(line) > 80 } |> should.be_true()
  annotation.format_file(file) |> should.equal(line)
}

pub fn the_semantic_renderers_never_wrap_test() {
  // `why` and `graded effect --format=graded` splice these into prose, so a
  // newline from one would break them silently.
  let assert Ok([long]) = annotation.parse(wrapping_probe(41))
  annotation.format_annotation(long)
  |> should.equal(
    "effects m." <> string.repeat("a", 41) <> " : [] where returns : [Stdout]",
  )

  let assert Ok(file) =
    annotation.parse_file(
      "assume dep/some/rather/long/module/path.make_the_client_for_the_session where returns : [Net]",
    )
  let assert [external] = annotation.extract_externals(file)
  { string.length(annotation.format_external(external)) > 80 }
  |> should.be_true()
  string.contains(annotation.format_external(external), "\n")
  |> should.be_false()
}

pub fn a_wrapped_statement_formats_idempotently_test() {
  let assert Ok(file) = annotation.parse_file(wrapping_probe(41))
  let once = annotation.format_sorted(file)
  let assert Ok(reparsed) = annotation.parse_file(once)
  annotation.format_sorted(reparsed) |> should.equal(once)
}

// An `effects <name> : []` annotation, the shape most of the line-structure
// tests are written over.
fn pure_line(name: String) -> types.EffectAnnotation {
  EffectAnnotation(Effects, name, [], TLabels(set.new()), None)
}

// One `effects` line whose function name is padded to `width`, carrying a
// `where returns` clause. The knob the width boundary is asserted on.
fn wrapping_probe(width: Int) -> String {
  let assert Ok(file) =
    annotation.parse_file(
      "effects m."
      <> string.repeat("a", width)
      <> " : [] where returns : [Stdout]",
    )
  annotation.format_file(file)
}

// Helpers
//
// Shared term-building shorthand used by tests across sections.

fn union_vars(first: EffectTerm, second: String) -> EffectTerm {
  effect_term.normalize(TUnion([first, TVar(second)]))
}
