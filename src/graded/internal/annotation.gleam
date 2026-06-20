import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import graded/internal/effect_term
import graded/internal/types.{
  type AnnotationKind, type EffectAnnotation, type EffectSet, type EffectTerm,
  type ExternalAnnotation, type GradedFile, type GradedLine, type ParamBound,
  type ReturnsAnnotation, type TypeFieldAnnotation, AnnotationLine, BlankLine,
  Check, CommentLine, EffectAnnotation, Effects, ExternalAnnotation,
  ExternalLine, FunctionExternal, GradedFile, ModuleExternal, ParamBound,
  Polymorphic, ReturnsAnnotation, ReturnsLine, Specific, TAbs, TApp, TLabels,
  TTop, TUnion, TVar, TypeFieldAnnotation, TypeFieldLine, Wildcard,
}

pub type ParseError {
  InvalidLine(line_number: Int, content: String)
}

// Parse an .graded file preserving full structure (comments, blanks, annotations).
pub fn parse_file(input: String) -> Result(GradedFile, ParseError) {
  input
  |> string.split("\n")
  |> list.index_map(fn(line, index) { #(index + 1, line) })
  |> list.try_map(fn(pair) {
    let #(line_number, line) = pair
    parse_structured_line(line, line_number)
  })
  |> result.map(fn(lines) { GradedFile(lines:) })
}

// Parse an .graded file returning only the annotations (discards structure).
pub fn parse(input: String) -> Result(List(EffectAnnotation), ParseError) {
  use file <- result.try(parse_file(input))
  Ok(extract_annotations(file))
}

// Extract all annotations from a parsed file.
pub fn extract_annotations(file: GradedFile) -> List(EffectAnnotation) {
  list.filter_map(file.lines, fn(line) {
    case line {
      AnnotationLine(annotation) -> Ok(annotation)
      TypeFieldLine(_) -> Error(Nil)
      ExternalLine(_) -> Error(Nil)
      ReturnsLine(_) -> Error(Nil)
      CommentLine(_) -> Error(Nil)
      BlankLine -> Error(Nil)
    }
  })
}

// Extract all `returns` annotations from a parsed file.
pub fn extract_returns(file: GradedFile) -> List(ReturnsAnnotation) {
  list.filter_map(file.lines, fn(line) {
    case line {
      ReturnsLine(returns) -> Ok(returns)
      _ -> Error(Nil)
    }
  })
}

// Render a ReturnsAnnotation back to its .graded line format.
pub fn format_returns(returns: ReturnsAnnotation) -> String {
  "returns " <> returns.function <> " : " <> format_operator(returns.operator)
}

// Format an operator term — a `TAbs` as `fn(cb) -> [body]`, anything else as a
// plain effect term (e.g. a polymorphic returned operator that's a bare `[v]`).
fn format_operator(term: EffectTerm) -> String {
  case term {
    TAbs(_, _) -> render_abstraction(term)
    other -> format_effect_term(other)
  }
}

// Extract only `check` annotations (enforced invariants).
pub fn extract_checks(file: GradedFile) -> List(EffectAnnotation) {
  extract_annotations(file)
  |> list.filter(fn(annotation) { annotation.kind == Check })
}

// Render an EffectAnnotation back to its .graded line format.
pub fn format_annotation(annotation: EffectAnnotation) -> String {
  let prefix = case annotation.kind {
    Effects -> "effects"
    Check -> "check"
  }
  let params_string = case annotation.params {
    [] -> ""
    params ->
      "(" <> string.join(list.map(params, format_param_bound), ", ") <> ")"
  }
  let effects_string = format_effect_term(annotation.effects)
  prefix
  <> " "
  <> annotation.function
  <> params_string
  <> " : "
  <> effects_string
}

// Split a qualified function name like `myapp/router.handle` into its
// module path and function name parts. Returns `Error(Nil)` for bare
// names with no `.` separator.
//
// The qualified format uses slashes within the module path
// (`gleam/io`, `myapp/web/handlers`) and a `.` to separate the module
// path from the function name. The split happens on the LAST `.` since
// function names cannot contain dots.
pub fn split_qualified_name(
  qualified: String,
) -> Result(#(String, String), Nil) {
  case list.reverse(string.split(qualified, ".")) {
    [] -> Error(Nil)
    [_only_one] -> Error(Nil)
    [function, ..rest_reversed] -> {
      let module = string.join(list.reverse(rest_reversed), ".")
      case module == "" || function == "" {
        True -> Error(Nil)
        False -> Ok(#(module, function))
      }
    }
  }
}

// Render a TypeFieldAnnotation back to its .graded line format. Includes
// the module prefix when present (qualified form, used in spec files);
// emits the bare form otherwise (cache files).
pub fn format_type_field(tf: TypeFieldAnnotation) -> String {
  let prefix = case tf.module {
    Some(module) -> module <> "."
    None -> ""
  }
  "type "
  <> prefix
  <> tf.type_name
  <> "."
  <> tf.field
  <> " : "
  <> format_effect_term(tf.effects)
}

// Extract type field annotations from a parsed file.
pub fn extract_type_fields(file: GradedFile) -> List(TypeFieldAnnotation) {
  list.filter_map(file.lines, fn(line) {
    case line {
      TypeFieldLine(tf) -> Ok(tf)
      _ -> Error(Nil)
    }
  })
}

// The qualified name (`module` or `module.function`) an external annotation
// targets. Used both as a sort key and as the rendered name in
// `format_external`.
fn external_sort_key(external_annotation: ExternalAnnotation) -> String {
  case external_annotation.target {
    ModuleExternal -> external_annotation.module
    FunctionExternal(function) -> external_annotation.module <> "." <> function
  }
}

// Render an ExternalAnnotation back to its `.graded` line format.
pub fn format_external(external_annotation: ExternalAnnotation) -> String {
  "external effects "
  <> external_sort_key(external_annotation)
  <> " : "
  <> format_effect_set(external_annotation.effects)
}

// Extract external annotations from a parsed file.
pub fn extract_externals(file: GradedFile) -> List(ExternalAnnotation) {
  list.filter_map(file.lines, fn(line) {
    case line {
      ExternalLine(external_annotation) -> Ok(external_annotation)
      _ -> Error(Nil)
    }
  })
}

// Render a full GradedFile back to a string, preserving structure.
pub fn format_file(file: GradedFile) -> String {
  file.lines
  |> list.map(fn(line) {
    case line {
      AnnotationLine(annotation) -> format_annotation(annotation)
      TypeFieldLine(tf) -> format_type_field(tf)
      ExternalLine(ext) -> format_external(ext)
      ReturnsLine(returns) -> format_returns(returns)
      CommentLine(text) -> text
      BlankLine -> ""
    }
  })
  |> string.join("\n")
}

// Merge inferred effects and returned-operator signatures into an existing
// GradedFile, preserving structure.
//
// - `check` / `type` / `external` lines, comments, blanks: kept in place
// - Existing `effects` and `returns` lines: updated in-place; removed if stale
// - New functions not yet in file: `effects` / `returns` lines appended at end
pub fn merge_inferred(
  file: GradedFile,
  inferred: List(EffectAnnotation),
  inferred_returns: List(ReturnsAnnotation),
) -> GradedFile {
  // A function the author declared with `external effects mod.fn : [...]` is
  // authoritative — that line is their opt-in to a precise FFI effect. Drop any
  // inferred `effects mod.fn` line for it so the opaque-FFI `[Unknown]` default
  // neither shadows nor duplicates the author's declaration (and a stale prior
  // inferred line is cleaned up on re-infer).
  let external_functions =
    list.filter_map(file.lines, fn(line) {
      case line {
        ExternalLine(ext) ->
          case ext.target {
            FunctionExternal(name) -> Ok(ext.module <> "." <> name)
            ModuleExternal -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
    |> set.from_list()
  let inferred =
    list.filter(inferred, fn(annotation) {
      !set.contains(external_functions, annotation.function)
    })

  let inferred_map =
    inferred
    |> list.map(fn(annotation) { #(annotation.function, annotation) })
    |> dict.from_list()
  let returns_map =
    inferred_returns
    |> list.map(fn(returns) { #(returns.function, returns) })
    |> dict.from_list()

  let #(new_lines, placed, placed_returns) =
    list.fold(file.lines, #([], set.new(), set.new()), fn(state, line) {
      let #(lines, placed_set, placed_returns_set) = state
      case line {
        AnnotationLine(annotation) ->
          case annotation.kind {
            Effects ->
              case dict.get(inferred_map, annotation.function) {
                Ok(new_annotation) -> #(
                  [AnnotationLine(new_annotation), ..lines],
                  set.insert(placed_set, annotation.function),
                  placed_returns_set,
                )
                Error(Nil) -> #(lines, placed_set, placed_returns_set)
              }
            Check -> #([line, ..lines], placed_set, placed_returns_set)
          }
        ReturnsLine(returns) ->
          case dict.get(returns_map, returns.function) {
            Ok(new_returns) -> #(
              [ReturnsLine(new_returns), ..lines],
              placed_set,
              set.insert(placed_returns_set, returns.function),
            )
            Error(Nil) -> #(lines, placed_set, placed_returns_set)
          }
        TypeFieldLine(_) | ExternalLine(_) | CommentLine(_) | BlankLine -> #(
          [line, ..lines],
          placed_set,
          placed_returns_set,
        )
      }
    })

  let remaining_effects =
    inferred
    |> list.filter(fn(annotation) { !set.contains(placed, annotation.function) })
    |> list.map(AnnotationLine)
  let remaining_returns =
    inferred_returns
    |> list.filter(fn(returns) {
      !set.contains(placed_returns, returns.function)
    })
    |> list.map(ReturnsLine)

  GradedFile(
    lines: list.flatten([
      list.reverse(new_lines),
      remaining_effects,
      remaining_returns,
    ]),
  )
}

// Format an GradedFile: normalize spacing, sort annotations, ensure trailing newline.
//
// Output order:
// 1. Leading comments (file header)
// 2. `check` lines, sorted alphabetically by function name
// 3. Blank line separator (if both check and effects lines exist)
// 4. `effects` lines, sorted alphabetically by function name
// 5. Single trailing newline
pub fn format_sorted(file: GradedFile) -> String {
  let comments = collect_comments(file.lines)
  let annotations = extract_annotations(file)

  let check_lines =
    annotations
    |> list.filter(fn(annotation) { annotation.kind == Check })
    |> list.sort(fn(left, right) {
      string.compare(left.function, right.function)
    })
    |> list.map(format_annotation)

  let effects_lines =
    annotations
    |> list.filter(fn(annotation) { annotation.kind == Effects })
    |> list.sort(fn(left, right) {
      string.compare(left.function, right.function)
    })
    |> list.map(format_annotation)

  let type_field_lines =
    extract_type_fields(file)
    |> list.sort(fn(left, right) {
      string.compare(
        left.type_name <> "." <> left.field,
        right.type_name <> "." <> right.field,
      )
    })
    |> list.map(format_type_field)

  let external_lines =
    extract_externals(file)
    |> list.sort(fn(left, right) {
      string.compare(external_sort_key(left), external_sort_key(right))
    })
    |> list.map(format_external)

  let returns_lines =
    extract_returns(file)
    |> list.sort(fn(left, right) {
      string.compare(left.function, right.function)
    })
    |> list.map(format_returns)

  let sections = [
    comments,
    external_lines,
    type_field_lines,
    check_lines,
    effects_lines,
    returns_lines,
  ]

  sections
  |> list.filter(fn(section) { section != [] })
  |> list.map(fn(section) { string.join(section, "\n") })
  |> string.join("\n\n")
  |> fn(content) { content <> "\n" }
}

// PRIVATE

fn parse_structured_line(
  line: String,
  line_number: Int,
) -> Result(GradedLine, ParseError) {
  let trimmed = string.trim(line)
  case trimmed {
    "" -> Ok(BlankLine)
    "//" <> _ -> Ok(CommentLine(line))
    "effects " <> _ | "check " <> _ ->
      case parse_annotation_line(trimmed, line_number, line) {
        Ok(annotation) -> Ok(AnnotationLine(annotation))
        Error(parse_error) -> Error(parse_error)
      }
    "type " <> rest ->
      case parse_type_field_line(rest) {
        Ok(tf) -> Ok(TypeFieldLine(tf))
        Error(Nil) -> Error(InvalidLine(line_number, line))
      }
    "external effects " <> rest ->
      case parse_external_line(rest) {
        Ok(ext) -> Ok(ExternalLine(ext))
        Error(Nil) -> Error(InvalidLine(line_number, line))
      }
    "returns " <> rest ->
      case parse_returns_line(rest) {
        Ok(returns) -> Ok(ReturnsLine(returns))
        Error(Nil) -> Error(InvalidLine(line_number, line))
      }
    _ -> Error(InvalidLine(line_number, line))
  }
}

// Parse a `returns mod.fn : fn(cb) -> [body]` line. The operator reuses the
// same `fn(..) -> [..]` syntax as an operator parameter bound.
fn parse_returns_line(rest: String) -> Result(ReturnsAnnotation, Nil) {
  use #(name, operator) <- result.try(parse_name_colon_effects(rest))
  Ok(ReturnsAnnotation(function: name, operator:))
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
  let err = Error(InvalidLine(line_number, original))
  // A params list opens with the `(` immediately after the function name. An
  // application's `(` inside the effect set is preceded by `[`, so a `[` before
  // the first `(` means there are no params (the `(` belongs to the result).
  case split_call(rest) {
    Error(Nil) ->
      case parse_name_colon_effects(rest) {
        Error(Nil) -> err
        Ok(#(name, effects)) ->
          Ok(EffectAnnotation(kind:, function: name, params: [], effects:))
      }
    Ok(#(name, params_str, suffix)) ->
      parse_params_suffix(kind, string.trim(name), params_str, suffix)
      |> result.replace_error(InvalidLine(line_number, original))
  }
}

// Split `name(params)suffix` at the params parens, matching nested parens so
// operator bounds (`fn(cb)`) and result applications don't confuse it.
// `Error(Nil)` when there's no params list (no `(`, or the first `(` is inside
// the effect brackets).
fn split_call(s: String) -> Result(#(String, String, String), Nil) {
  use #(before, rest) <- result.try(string.split_once(s, "("))
  use <- bool.guard(when: string.contains(before, "["), return: Error(Nil))
  use #(params, suffix) <- result.try(
    match_paren(string.to_graphemes(rest), 0, []),
  )
  Ok(#(before, params, suffix))
}

// Walk graphemes after an opening paren, returning the contents up to the
// matching close and the remaining suffix.
fn match_paren(
  graphemes: List(String),
  depth: Int,
  acc: List(String),
) -> Result(#(String, String), Nil) {
  case graphemes {
    [] -> Error(Nil)
    [")", ..rest] if depth == 0 ->
      #(acc |> list.reverse() |> string.concat(), string.concat(rest))
      |> Ok()
    ["(", ..rest] -> match_paren(rest, depth + 1, ["(", ..acc])
    [")", ..rest] -> match_paren(rest, depth - 1, [")", ..acc])
    [grapheme, ..rest] -> match_paren(rest, depth, [grapheme, ..acc])
  }
}

// Parse ") : [effects]" suffix and build the final annotation.
fn parse_params_suffix(
  kind: AnnotationKind,
  name: String,
  params_str: String,
  suffix: String,
) -> Result(EffectAnnotation, Nil) {
  let suffix_trimmed = string.trim(suffix)
  case string.starts_with(suffix_trimmed, ":") {
    False -> Error(Nil)
    True -> {
      let effects_str = string.trim(string.drop_start(suffix_trimmed, 1))
      case parse_effect_term(effects_str), parse_params_section(params_str) {
        Ok(effects), Ok(params) ->
          Ok(EffectAnnotation(kind:, function: name, params:, effects:))
        _, _ -> Error(Nil)
      }
    }
  }
}

// Parse a type field annotation. Two forms are accepted:
//
//   `TypeName.field_name : [effects]`               (bare — implicit module)
//   `module/path.TypeName.field_name : [effects]`   (qualified — spec file)
//
// The bare form is used in per-module cache files where the type's module is
// implied by the file's location. The qualified form is used in spec files
// where annotations from many modules share one file. The dot is the
// boundary between module path and `TypeName.field`; module path itself uses
// slashes (matching the `external effects` convention).
fn parse_type_field_line(rest: String) -> Result(TypeFieldAnnotation, Nil) {
  use #(qualified, effects) <- result.try(parse_name_colon_effects(rest))
  case string.split(qualified, ".") {
    [type_name, field] if type_name != "" && field != "" ->
      Ok(TypeFieldAnnotation(module: None, type_name:, field:, effects:))
    segments -> {
      // 3+ segments → qualified form. Last two are TypeName and field; the
      // rest joined back with `.` is the module path.
      let count = list.length(segments)
      use <- bool.guard(count < 3, Error(Nil))
      let module_segments = list.take(segments, count - 2)
      let trailing = list.drop(segments, count - 2)
      case trailing {
        [type_name, field] if type_name != "" && field != "" -> {
          let module = string.join(module_segments, ".")
          use <- bool.guard(module == "", Error(Nil))
          Ok(TypeFieldAnnotation(
            module: Some(module),
            type_name:,
            field:,
            effects:,
          ))
        }
        _ -> Error(Nil)
      }
    }
  }
}

// No "." → module-level external (e.g., `external effects gleam/list : []`)
// Has "." → function-level external (e.g., `external effects gleam/io.println : [Stdout]`)
fn parse_external_line(rest: String) -> Result(ExternalAnnotation, Nil) {
  use #(qualified, term) <- result.try(parse_name_colon_effects(rest))
  // External declarations are first-order by construction — reduce to a set.
  let effects = effect_term.to_effect_set(term)
  let segments = string.split(qualified, ".")
  let len = list.length(segments)
  case len {
    1 ->
      Ok(ExternalAnnotation(module: qualified, target: ModuleExternal, effects:))
    _ -> {
      use function <- result.try(list.last(segments))
      let module = segments |> list.take(len - 1) |> string.join(".")
      Ok(ExternalAnnotation(
        module:,
        target: FunctionExternal(function),
        effects:,
      ))
    }
  }
}

fn parse_params_section(input: String) -> Result(List(ParamBound), Nil) {
  case string.trim(input) {
    "" -> Ok([])
    trimmed -> list.try_map(split_top_level_commas(trimmed), parse_single_param)
  }
}

fn parse_single_param(input: String) -> Result(ParamBound, Nil) {
  use #(name, effects) <- result.try(parse_name_colon_effects(input))
  Ok(ParamBound(name:, effects:))
}

// Shared helper: parse "name : <bound>" returning the trimmed name and the
// bound's effect term (which may be an operator `fn(cb) -> [..]`). Split on the
// FIRST colon only, so an operator body's contents are left intact.
fn parse_name_colon_effects(
  input: String,
) -> Result(#(String, EffectTerm), Nil) {
  use #(name_part, effects_part) <- result.try(string.split_once(
    string.trim(input),
    ":",
  ))
  let name = string.trim(name_part)
  use <- bool.guard(when: name == "", return: Error(Nil))
  use effects <- result.try(parse_bound_effect(string.trim(effects_part)))
  Ok(#(name, effects))
}

// A token is an effect label if its first character is uppercase.
// Lowercase first character => effect variable.
fn is_label_token(token: String) -> Bool {
  types.is_upper_initial(token)
}

// Parse an effect term `[...]`. Beyond labels and variables, supports
// second-order *operator applications* `name(arg, ...)`; comma splitting is
// paren-aware so an application's own argument list isn't split.
fn parse_effect_term(input: String) -> Result(EffectTerm, Nil) {
  let trimmed = string.trim(input)
  use <- bool.guard(
    when: !{
      string.starts_with(trimmed, "[") && string.ends_with(trimmed, "]")
    },
    return: Error(Nil),
  )
  let inner =
    trimmed |> string.drop_start(1) |> string.drop_end(1) |> string.trim()
  case inner {
    "_" -> Ok(TTop)
    "" -> Ok(TLabels(set.new()))
    _ -> {
      use atoms <- result.try(parse_atoms(inner))
      Ok(effect_term.normalize(TUnion(atoms)))
    }
  }
}

// Parse the comma-separated atoms of an effect term body (paren-aware split,
// trimmed, empties dropped).
fn parse_atoms(inner: String) -> Result(List(EffectTerm), Nil) {
  inner
  |> split_top_level_commas()
  |> list.map(string.trim)
  |> list.filter(fn(token) { token != "" })
  |> list.try_map(parse_atom)
}

// Parse one comma-separated atom of an effect term: a label, a variable, or
// an operator application `name([arg], ...)`. An application's arguments are
// each a full bracketed effect term, and multiple arguments are *curried*:
// `f([A], [B])` ⟹ `TApp(TApp(TVar(f), A), B)`, so the comma form is
// unambiguous (a single multi-label argument is `f([A, B])`).
fn parse_atom(token: String) -> Result(EffectTerm, Nil) {
  case string.split_once(token, "(") {
    Ok(#(name, rest)) -> {
      use <- bool.guard(when: !string.ends_with(rest, ")"), return: Error(Nil))
      let callee = string.trim(name)
      use <- bool.guard(when: callee == "", return: Error(Nil))
      use args <- result.try(parse_application_args(string.drop_end(rest, 1)))
      Ok(list.fold(args, TVar(callee), fn(acc, arg) { TApp(acc, arg) }))
    }
    Error(Nil) ->
      case is_label_token(token) {
        True -> Ok(TLabels(set.from_list([token])))
        False -> Ok(TVar(token))
      }
  }
}

// Parse an operator application's argument list — comma-separated, each a full
// bracketed effect term — splitting at top-level commas only (bracket- and
// paren-aware, so a nested application or a multi-label argument isn't split).
fn parse_application_args(inner: String) -> Result(List(EffectTerm), Nil) {
  case string.trim(inner) {
    "" -> Ok([])
    trimmed ->
      trimmed
      |> split_top_level_commas()
      |> list.map(string.trim)
      |> list.try_map(parse_effect_term)
  }
}

// Split on commas at nesting depth 0, counting both `[`/`]` and `(`/`)` toward
// depth. Used for operator-application argument lists, whose arguments are
// bracketed effect terms that may themselves contain nested applications.
fn split_top_level_commas(input: String) -> List(String) {
  let #(segments, current, _depth) =
    list.fold(string.to_graphemes(input), #([], "", 0), fn(state, char) {
      let #(segments, current, depth) = state
      case char {
        "," if depth == 0 -> #([current, ..segments], "", depth)
        "[" | "(" -> #(segments, current <> char, depth + 1)
        "]" | ")" -> #(segments, current <> char, depth - 1)
        _ -> #(segments, current <> char, depth)
      }
    })
  list.reverse([current, ..segments])
}

// Parse a parameter bound's effect: an operator `fn(a, b) -> [body]` (a curried
// `TAbs`) or an ordinary effect term `[...]`.
fn parse_bound_effect(input: String) -> Result(EffectTerm, Nil) {
  let trimmed = string.trim(input)
  case string.starts_with(trimmed, "fn(") {
    False -> parse_effect_term(trimmed)
    True -> {
      use #(params_part, after) <- result.try(string.split_once(trimmed, ")"))
      let params =
        params_part
        |> string.drop_start(3)
        |> split_top_level_commas()
        |> list.map(string.trim)
        |> list.filter(fn(param) { param != "" })
      use <- bool.guard(when: params == [], return: Error(Nil))
      use #(_, body_str) <- result.try(string.split_once(after, "->"))
      use body <- result.try(parse_effect_term(string.trim(body_str)))
      Ok(list.fold_right(params, body, fn(acc, param) { TAbs(param, acc) }))
    }
  }
}

fn collect_comments(lines: List(GradedLine)) -> List(String) {
  list.filter_map(lines, fn(line) {
    case line {
      CommentLine(text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}

// Format a parameter bound. A first-order bound renders as `name: [effects]`;
// a second-order *operator* bound (a curried `TAbs`) renders as
// `name: fn(a, b) -> [body]`.
fn format_param_bound(param: ParamBound) -> String {
  case param.effects {
    TAbs(_, _) -> param.name <> ": " <> render_abstraction(param.effects)
    other -> param.name <> ": " <> format_effect_term(other)
  }
}

// Format an `EffectTerm` as `[...]`. Free variables render as bare lowercase
// names, operator applications as `name(arg, ...)`, and a wildcard as `[_]`.
// Atoms are sorted; since labels are upper-initial and variables lower-initial
// (so labels sort first), a first-order term formats byte-identically to its
// `EffectSet`.
fn format_effect_term(term: EffectTerm) -> String {
  case effect_term.normalize(term) {
    TTop -> "[_]"
    normalized ->
      "["
      <> {
        term_atoms(normalized) |> list.sort(string.compare) |> string.join(", ")
      }
      <> "]"
  }
}

fn term_atoms(term: EffectTerm) -> List(String) {
  case term {
    TLabels(labels) -> set.to_list(labels)
    TVar(name) -> [name]
    TTop -> ["_"]
    TApp(_, _) -> [render_application(term)]
    TUnion(members) -> list.flat_map(members, term_atoms)
    TAbs(_, _) -> [render_abstraction(term)]
  }
}

// Render an operator application `head([arg0], [arg1], ...)`. Walks the whole
// (possibly curried) application spine and renders arguments **in spine order**
// — currying is positional, so argument order is significant and must not be
// sorted (unlike union members). Each argument is a bracketed effect term.
fn render_application(term: EffectTerm) -> String {
  let #(head, args) = application_spine(term)
  let callee = case head {
    TVar(name) -> name
    other -> string.join(term_atoms(other) |> list.sort(string.compare), " ")
  }
  callee
  <> "("
  <> { args |> list.map(format_effect_term) |> string.join(", ") }
  <> ")"
}

// Collect an application spine `((head a0) a1 ...)` into its head and the
// argument list in application order.
fn application_spine(term: EffectTerm) -> #(EffectTerm, List(EffectTerm)) {
  case term {
    TApp(operator, argument) -> {
      let #(head, args) = application_spine(operator)
      #(head, list.append(args, [argument]))
    }
    other -> #(other, [])
  }
}

// Render an operator abstraction `fn(a, b) -> [body]`. Walks the curried
// `TAbs` spine to collect all binders in order.
fn render_abstraction(term: EffectTerm) -> String {
  let #(binders, body) = abstraction_spine(term)
  "fn(" <> string.join(binders, ", ") <> ") -> " <> format_effect_term(body)
}

// Collect a curried abstraction `λa. λb. body` into its binders (in order) and
// the innermost body.
fn abstraction_spine(term: EffectTerm) -> #(List(String), EffectTerm) {
  case term {
    TAbs(param, body) -> {
      let #(rest, inner) = abstraction_spine(body)
      #([param, ..rest], inner)
    }
    other -> #([], other)
  }
}

// Render an effect set to its `[A, B]` surface syntax: `[]` for empty, `[_]`
// for wildcard, labels then variables each sorted. The single source of truth
// for the on-disk effect-set format (`effects.format_effect_set` delegates
// here for diagnostics).
pub fn format_effect_set(effect_set: EffectSet) -> String {
  case effect_set {
    Wildcard -> "[_]"
    Specific(labels) ->
      case set.to_list(labels) |> list.sort(string.compare) {
        [] -> "[]"
        sorted -> "[" <> string.join(sorted, ", ") <> "]"
      }
    Polymorphic(labels, variables) -> {
      let sorted_labels = set.to_list(labels) |> list.sort(string.compare)
      let sorted_variables = set.to_list(variables) |> list.sort(string.compare)
      "["
      <> string.join(list.append(sorted_labels, sorted_variables), ", ")
      <> "]"
    }
  }
}
