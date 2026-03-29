import assay/annotation
import assay/types.{
  AnnotationLine, AssayFile, BlankLine, Check, CommentLine, EffectAnnotation,
  Effects,
}
import gleam/set
import gleeunit/should

pub fn empty_effects_test() {
  let input = "effects view : []"
  let assert Ok([
    EffectAnnotation(kind: Effects, function: "view", effects: eff),
  ]) = annotation.parse(input)
  set.size(eff) |> should.equal(0)
}

pub fn single_effect_test() {
  let input = "effects update : [Http]"
  let assert Ok([
    EffectAnnotation(kind: Effects, function: "update", effects: eff),
  ]) = annotation.parse(input)
  eff |> should.equal(set.from_list(["Http"]))
}

pub fn multiple_effects_test() {
  let input = "effects update : [Http, Dom]"
  let assert Ok([
    EffectAnnotation(kind: Effects, function: "update", effects: eff),
  ]) = annotation.parse(input)
  eff |> should.equal(set.from_list(["Http", "Dom"]))
}

pub fn check_line_test() {
  let input = "check view : []"
  let assert Ok([EffectAnnotation(kind: Check, function: "view", effects: eff)]) =
    annotation.parse(input)
  set.size(eff) |> should.equal(0)
}

pub fn check_with_effects_test() {
  let input = "check update : [Http, Dom]"
  let assert Ok([
    EffectAnnotation(kind: Check, function: "update", effects: eff),
  ]) = annotation.parse(input)
  eff |> should.equal(set.from_list(["Http", "Dom"]))
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

// --- parse_file structure preservation ---

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

// --- Writer ---

pub fn format_annotation_effects_test() {
  let ann =
    EffectAnnotation(kind: Effects, function: "view", effects: set.new())
  annotation.format_annotation(ann) |> should.equal("effects view : []")
}

pub fn format_annotation_check_test() {
  let ann =
    EffectAnnotation(
      kind: Check,
      function: "update",
      effects: set.from_list(["Http", "Dom"]),
    )
  annotation.format_annotation(ann)
  |> should.equal("check update : [Dom, Http]")
}

pub fn format_file_round_trip_test() {
  let input =
    "// header

effects view : []
check view : []

// footer"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_file(file) |> should.equal(input)
}

// --- Merge ---

pub fn merge_updates_existing_test() {
  let file =
    AssayFile(lines: [
      AnnotationLine(EffectAnnotation(Effects, "view", set.new())),
    ])
  let inferred = [
    EffectAnnotation(Effects, "view", set.from_list(["Stdout"])),
  ]
  let merged = annotation.merge_inferred(file, inferred)
  let assert [AnnotationLine(ann)] = merged.lines
  ann.effects |> should.equal(set.from_list(["Stdout"]))
}

pub fn merge_preserves_checks_test() {
  let file =
    AssayFile(lines: [
      AnnotationLine(EffectAnnotation(Check, "view", set.new())),
      AnnotationLine(EffectAnnotation(
        Effects,
        "update",
        set.from_list(["Http"]),
      )),
    ])
  let inferred = [
    EffectAnnotation(Effects, "update", set.from_list(["Http", "Dom"])),
  ]
  let merged = annotation.merge_inferred(file, inferred)
  let assert [AnnotationLine(check_ann), AnnotationLine(effects_ann)] =
    merged.lines
  check_ann.kind |> should.equal(Check)
  check_ann.effects |> should.equal(set.new())
  effects_ann.effects |> should.equal(set.from_list(["Http", "Dom"]))
}

pub fn merge_removes_stale_test() {
  let file =
    AssayFile(lines: [
      AnnotationLine(EffectAnnotation(Effects, "deleted_fn", set.new())),
      AnnotationLine(EffectAnnotation(Effects, "view", set.new())),
    ])
  let inferred = [EffectAnnotation(Effects, "view", set.new())]
  let merged = annotation.merge_inferred(file, inferred)
  let assert [AnnotationLine(ann)] = merged.lines
  ann.function |> should.equal("view")
}

pub fn merge_appends_new_test() {
  let file =
    AssayFile(lines: [
      AnnotationLine(EffectAnnotation(Effects, "view", set.new())),
    ])
  let inferred = [
    EffectAnnotation(Effects, "view", set.new()),
    EffectAnnotation(Effects, "update", set.from_list(["Http"])),
  ]
  let merged = annotation.merge_inferred(file, inferred)
  let assert [AnnotationLine(first), AnnotationLine(second)] = merged.lines
  first.function |> should.equal("view")
  second.function |> should.equal("update")
}

pub fn merge_preserves_comments_test() {
  let file =
    AssayFile(lines: [
      CommentLine("// header"),
      BlankLine,
      AnnotationLine(EffectAnnotation(Effects, "view", set.new())),
      BlankLine,
      CommentLine("// invariants"),
      AnnotationLine(EffectAnnotation(Check, "view", set.new())),
    ])
  let inferred = [
    EffectAnnotation(Effects, "view", set.from_list(["Stdout"])),
  ]
  let merged = annotation.merge_inferred(file, inferred)
  let assert [
    CommentLine("// header"),
    BlankLine,
    AnnotationLine(view_eff),
    BlankLine,
    CommentLine("// invariants"),
    AnnotationLine(view_check),
  ] = merged.lines
  view_eff.effects |> should.equal(set.from_list(["Stdout"]))
  view_check.kind |> should.equal(Check)
}
