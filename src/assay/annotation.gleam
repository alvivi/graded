import assay/types.{
  type AnnotationKind, type AssayFile, type AssayLine, type EffectAnnotation,
  AnnotationLine, AssayFile, BlankLine, Check, CommentLine, EffectAnnotation,
  Effects,
}
import gleam/bool
import gleam/dict
import gleam/list
import gleam/result
import gleam/set
import gleam/string

pub type ParseError {
  InvalidLine(line_number: Int, content: String)
}

/// Parse an .assay file preserving full structure (comments, blanks, annotations).
pub fn parse_file(input: String) -> Result(AssayFile, ParseError) {
  input
  |> string.split("\n")
  |> list.index_map(fn(line, index) { #(index + 1, line) })
  |> list.try_map(fn(pair) {
    let #(line_number, line) = pair
    parse_structured_line(line, line_number)
  })
  |> result.map(fn(lines) { AssayFile(lines:) })
}

/// Parse an .assay file returning only the annotations (discards structure).
pub fn parse(input: String) -> Result(List(EffectAnnotation), ParseError) {
  use file <- result.try(parse_file(input))
  Ok(extract_annotations(file))
}

/// Extract all annotations from a parsed file.
pub fn extract_annotations(file: AssayFile) -> List(EffectAnnotation) {
  list.filter_map(file.lines, fn(line) {
    case line {
      AnnotationLine(annotation) -> Ok(annotation)
      CommentLine(_) -> Error(Nil)
      BlankLine -> Error(Nil)
    }
  })
}

/// Extract only `check` annotations (enforced invariants).
pub fn extract_checks(file: AssayFile) -> List(EffectAnnotation) {
  extract_annotations(file)
  |> list.filter(fn(annotation) { annotation.kind == Check })
}

/// Render an EffectAnnotation back to its .assay line format.
pub fn format_annotation(annotation: EffectAnnotation) -> String {
  let prefix = case annotation.kind {
    Effects -> "effects"
    Check -> "check"
  }
  let effects_string = format_effect_set(annotation.effects)
  prefix <> " " <> annotation.function <> " : " <> effects_string
}

/// Render a full AssayFile back to a string, preserving structure.
pub fn format_file(file: AssayFile) -> String {
  file.lines
  |> list.map(fn(line) {
    case line {
      AnnotationLine(annotation) -> format_annotation(annotation)
      CommentLine(text) -> text
      BlankLine -> ""
    }
  })
  |> string.join("\n")
}

/// Merge inferred effects into an existing AssayFile, preserving structure.
///
/// - `check` lines: kept exactly where they are, unchanged
/// - Comments and blank lines: kept exactly where they are
/// - Existing `effects` lines: updated in-place with new effect set
/// - Stale `effects` lines (function no longer exists): removed
/// - New functions not yet in file: `effects` lines appended at end
pub fn merge_inferred(
  file: AssayFile,
  inferred: List(EffectAnnotation),
) -> AssayFile {
  let inferred_map =
    inferred
    |> list.map(fn(annotation) { #(annotation.function, annotation) })
    |> dict.from_list()

  let #(new_lines, placed) =
    list.fold(file.lines, #([], set.new()), fn(state, line) {
      let #(lines, placed_set) = state
      case line {
        AnnotationLine(annotation) ->
          case annotation.kind {
            Effects ->
              case dict.get(inferred_map, annotation.function) {
                Ok(new_annotation) -> #(
                  [AnnotationLine(new_annotation), ..lines],
                  set.insert(placed_set, annotation.function),
                )
                Error(Nil) -> #(lines, placed_set)
              }
            Check -> #([line, ..lines], placed_set)
          }
        CommentLine(_) -> #([line, ..lines], placed_set)
        BlankLine -> #([line, ..lines], placed_set)
      }
    })

  let remaining =
    inferred
    |> list.filter(fn(annotation) { !set.contains(placed, annotation.function) })
    |> list.map(AnnotationLine)

  AssayFile(lines: list.append(list.reverse(new_lines), remaining))
}

// PRIVATE

fn parse_structured_line(
  line: String,
  line_number: Int,
) -> Result(AssayLine, ParseError) {
  let trimmed = string.trim(line)
  case trimmed {
    "" -> Ok(BlankLine)
    "//" <> _ -> Ok(CommentLine(line))
    "effects " <> _ | "check " <> _ ->
      case parse_annotation_line(trimmed, line_number, line) {
        Ok(annotation) -> Ok(AnnotationLine(annotation))
        Error(parse_error) -> Error(parse_error)
      }
    _ -> Error(InvalidLine(line_number, line))
  }
}

fn parse_annotation_line(
  trimmed: String,
  line_number: Int,
  original: String,
) -> Result(EffectAnnotation, ParseError) {
  let #(kind, rest) = case trimmed {
    "effects " <> remaining -> #(Ok(Effects), remaining)
    "check " <> remaining -> #(Ok(Check), remaining)
    _ -> #(Error(Nil), "")
  }
  case kind {
    Error(Nil) -> Error(InvalidLine(line_number, original))
    Ok(parsed_kind) ->
      parse_annotation_rest(parsed_kind, rest, line_number, original)
  }
}

fn parse_annotation_rest(
  kind: AnnotationKind,
  rest: String,
  line_number: Int,
  original: String,
) -> Result(EffectAnnotation, ParseError) {
  case string.split(rest, ":") {
    [name_part, effects_part] -> {
      let name = string.trim(name_part)
      case name == "" {
        True -> Error(InvalidLine(line_number, original))
        False ->
          case parse_effect_set(string.trim(effects_part)) {
            Error(Nil) -> Error(InvalidLine(line_number, original))
            Ok(effect_set) ->
              Ok(EffectAnnotation(kind:, function: name, effects: effect_set))
          }
      }
    }
    _ -> Error(InvalidLine(line_number, original))
  }
}

fn parse_effect_set(input: String) -> Result(set.Set(String), Nil) {
  let trimmed = string.trim(input)
  let has_brackets =
    string.starts_with(trimmed, "[") && string.ends_with(trimmed, "]")
  use <- bool.guard(when: !has_brackets, return: Error(Nil))
  let inner =
    trimmed
    |> string.drop_start(1)
    |> string.drop_end(1)
    |> string.trim()
  case inner {
    "" -> Ok(set.new())
    _ ->
      inner
      |> string.split(",")
      |> list.map(string.trim)
      |> list.filter(fn(label) { label != "" })
      |> set.from_list()
      |> Ok()
  }
}

fn format_effect_set(effect_set: set.Set(String)) -> String {
  case set.to_list(effect_set) |> list.sort(string.compare) {
    [] -> "[]"
    labels -> "[" <> string.join(labels, ", ") <> "]"
  }
}
