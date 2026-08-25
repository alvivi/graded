import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import graded/internal/effect_term
import graded/internal/types.{
  type AnnotationKind, type EffectAnnotation, type EffectSet, type EffectTerm,
  type ExternalAnnotation, type GradedFile, type GradedLine, type ParamBound,
  type QualifiedName, type TypeFieldAnnotation, type UnknownClause,
  AnnotationLine, BlankLine, Check, CommentLine, EffectAnnotation, Effects,
  ExternalAnnotation, ExternalLine, FunctionExternal, GradedFile, ModuleExternal,
  ParamBound, Polymorphic, RetainedAssumeLine, Specific, TAbs, TApp, TLabels,
  TTop, TUnion, TVar, TypeFieldAnnotation, TypeFieldLine, UnknownClause,
  Wildcard,
}

// Parsing
//
// Turn raw .graded text into a structured GradedFile: one recognizer per line
// kind, with shared grammar helpers for names, effect terms, and operator
// bounds.

pub type ParseError {
  InvalidLine(line_number: Int, content: String)
  // A line written in a spelling this version no longer reads. Told apart from
  // an ordinary rejection so the error can name the rewrite.
  RetiredSpelling(line_number: Int, content: String, keyword: RetiredKeyword)
}

// A keyword that no longer starts a line.
pub type RetiredKeyword {
  RetiredType
  RetiredExternalEffects
  RetiredReturns
  RetiredExternalReturns
}

// Render a parse error as `<line number>: <line as written>`, with the rewrite
// on a second line for a retired spelling. The single source of truth for how a
// rejected line is named, so the CLI's error, the `format --stdin` branch and
// the dependency-spec warning all point at the same line the same way.
pub fn describe_parse_error(error: ParseError) -> String {
  case parse_error_hint(error) {
    None -> describe_parse_error_line(error)
    Some(hint) -> describe_parse_error_line(error) <> "\n  " <> hint
  }
}

// The `<line number>: <line as written>` half of the description, on one line.
// For a caller that wraps the description in a sentence: the hint is a line of
// its own, so a tail appended to `describe_parse_error` would dangle after the
// hint instead of closing the sentence about the line.
pub fn describe_parse_error_line(error: ParseError) -> String {
  int.to_string(error.line_number) <> ": " <> string.trim(error.content)
}

// The rewrite a retired spelling is named with, `None` for any other parse
// error.
fn parse_error_hint(error: ParseError) -> Option(String) {
  case error {
    InvalidLine(..) -> None
    RetiredSpelling(keyword:, ..) -> Some(retired_hint(keyword))
  }
}

// How to rewrite one retired spelling.
fn retired_hint(keyword: RetiredKeyword) -> String {
  case keyword {
    RetiredType ->
      "`type <path> : <effects>` is retired; write `assume <path> : <effects>`"
    RetiredExternalEffects ->
      "`external effects <path> : <effects>` is retired; write `assume <path> : <effects>`"
    RetiredReturns ->
      "`returns <path> : <operator>` is retired; delete it — `graded infer` writes the operator as a `where returns` clause on the `effects <path>` line"
    RetiredExternalReturns ->
      "`external returns <path> : <operator>` is retired; write `assume <path> where returns : <operator>`"
  }
}

// Parse an .graded file preserving full structure (comments, blanks, annotations).
pub fn parse_file(input: String) -> Result(GradedFile, ParseError) {
  use logical <- result.try(
    input
    |> string.split("\n")
    |> list.index_map(fn(line, index) { #(index + 1, line) })
    |> join_continuations(),
  )
  logical
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

// Line joining
//
// A statement may be written on one physical line or wrapped across several,
// and the reader accepts both regardless of what the formatter emits. This
// pre-pass turns physical lines into logical ones, so everything downstream —
// classification, parsing, error reporting — sees one statement per element.
//
// Indentation alone is not the rule. Today an indented `// comment` is a
// comment and an indented `effects m.f : []` is that annotation, and both stay
// so. A continuation is an indented line that is *also* at a clause boundary.

// Fold physical lines into logical ones, joining each wrapped statement's
// fragments with a single space. The first physical line's number is the
// statement's, so an error points at where it starts.
fn join_continuations(
  lines: List(#(Int, String)),
) -> Result(List(#(Int, String)), ParseError) {
  join_loop(lines, None, [])
}

fn join_loop(
  rest: List(#(Int, String)),
  pending: Option(#(Int, String)),
  acc: List(#(Int, String)),
) -> Result(List(#(Int, String)), ParseError) {
  case rest, pending {
    [], None -> Ok(list.reverse(acc))
    [], Some(statement) ->
      flush_pending(statement, acc) |> result.map(list.reverse)
    [line, ..tail], None -> join_fresh(line, tail, acc)
    [line, ..tail], Some(statement) ->
      case continues_statement(statement.1, line.1) {
        True -> join_loop(tail, Some(joined_statement(statement, line)), acc)
        False -> {
          use acc <- result.try(flush_pending(statement, acc))
          join_fresh(line, tail, acc)
        }
      }
  }
}

// Read one physical line with no statement accumulated above it. A blank or a
// comment is emitted as it stands — `GradedFile` is one logical statement per
// element, with no representation for a line inside one — and anything else
// opens a statement.
fn join_fresh(
  line: #(Int, String),
  tail: List(#(Int, String)),
  acc: List(#(Int, String)),
) -> Result(List(#(Int, String)), ParseError) {
  case string.trim(line.1) {
    "" | "//" <> _ -> join_loop(tail, None, [line, ..acc])
    _ -> join_loop(tail, Some(line), acc)
  }
}

// One physical line appended to the statement above it, joined by a single
// space and keeping the statement's own line number. Clause boundaries are the
// only place a wrap may occur, so a payload never spans a join and its interior
// bytes survive untouched.
fn joined_statement(
  statement: #(Int, String),
  line: #(Int, String),
) -> #(Int, String) {
  #(statement.0, string.trim(statement.1) <> " " <> string.trim(line.1))
}

// Emit an accumulated statement, or reject it where it is still waiting for a
// clause that never came. The error names the joined statement and the physical
// line it starts on.
fn flush_pending(
  statement: #(Int, String),
  acc: List(#(Int, String)),
) -> Result(List(#(Int, String)), ParseError) {
  use <- bool.guard(
    when: awaits_clause(string.trim(statement.1)),
    return: Error(InvalidLine(statement.0, statement.1)),
  )
  Ok([statement, ..acc])
}

// Whether an indented physical line continues the statement accumulated above
// it. Two boundaries qualify, and nothing else does:
//
//   - the statement is waiting for another clause (it ended in a comma, or
//     opened its `where` region with nothing after it) and this line spells one;
//   - the statement is complete and this line opens the `where` region.
//
// In an open region the clause reading is decided *before* any statement
// keyword is matched: the key charset admits `effects`, `check` and `assume`,
// so a wrapped statement whose clause is named after one of them must still
// read as one statement.
fn continues_statement(accumulated: String, raw: String) -> Bool {
  use <- bool.guard(when: !is_indented(raw), return: False)
  let trimmed = string.trim(raw)
  use <- bool.guard(when: trimmed == "", return: False)
  case awaits_clause(string.trim(accumulated)) {
    True -> is_clause_fragment(trimmed)
    False ->
      trimmed == clause_region_word
      || string.starts_with(trimmed, clause_region_word <> " ")
  }
}

fn is_indented(raw: String) -> Bool {
  string.starts_with(raw, " ") || string.starts_with(raw, "\t")
}

// Whether an accumulated statement is waiting for another clause.
fn awaits_clause(accumulated: String) -> Bool {
  string.ends_with(accumulated, ",")
  || accumulated == clause_region_word
  || string.ends_with(accumulated, " " <> clause_region_word)
}

// Whether a physical line spells one clause entry. The clause parser is the
// authority — a rule added to the entry grammar must not have to be added here
// too, or a wrapped statement the parser accepts stops being read as one.
fn is_clause_fragment(trimmed: String) -> Bool {
  parse_clause_entry(trimmed) |> result.is_ok()
}

fn parse_structured_line(
  line: String,
  line_number: Int,
) -> Result(GradedLine, ParseError) {
  let trimmed = string.trim(line)
  case trimmed {
    "" -> Ok(BlankLine)
    "//" <> _ -> Ok(CommentLine(line))
    "effects " <> _ | "check " <> _ ->
      parse_annotation_line(trimmed, line_number, line)
    "assume " <> rest ->
      parse_assume_line(rest)
      |> result.replace_error(InvalidLine(line_number, line))
    "type " <> _ -> Error(RetiredSpelling(line_number, line, RetiredType))
    "external effects " <> _ ->
      Error(RetiredSpelling(line_number, line, RetiredExternalEffects))
    "external returns " <> _ ->
      Error(RetiredSpelling(line_number, line, RetiredExternalReturns))
    "returns " <> _ -> Error(RetiredSpelling(line_number, line, RetiredReturns))
    _ -> Error(InvalidLine(line_number, line))
  }
}

fn parse_annotation_line(
  trimmed: String,
  line_number: Int,
  original: String,
) -> Result(GradedLine, ParseError) {
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
) -> Result(GradedLine, ParseError) {
  // The clause region comes off first: `parse_name_colon_effects` splits on the
  // first colon, so a name-first read would take `m.f where returns` for the
  // function name.
  parse_clause_then(rest, fn(head, returns, unknown_clauses) {
    parse_annotation_head(kind, head, returns)
    |> result.map(AnnotationLine(_, unknown_clauses))
  })
  |> result.replace_error(InvalidLine(line_number, original))
}

// Split a statement's `where` region off its head, read the region's clause
// list, and hand the head, the known `returns` operator and the retained
// unknown clauses to `parse_head`.
fn parse_clause_then(
  rest: String,
  parse_head: fn(String, Option(EffectTerm), List(UnknownClause)) ->
    Result(a, Nil),
) -> Result(a, Nil) {
  use #(head, region) <- result.try(split_clause_region(rest))
  use #(returns, unknown_clauses) <- result.try(case region {
    None -> Ok(#(None, []))
    Some(text) -> parse_clause_list(text)
  })
  parse_head(head, returns, unknown_clauses)
}

// Read a clause region into the one key this version knows and the entries it
// retains without reading. Ordering of the retained list is the order read,
// duplicate unknown keys included: a newer reader is the authority on whether
// its own key may repeat.
fn parse_clause_list(
  region: String,
) -> Result(#(Option(EffectTerm), List(UnknownClause)), Nil) {
  use entries <- result.try(
    region |> split_top_level_commas() |> list.try_map(parse_clause_entry),
  )
  let #(known, unknown) =
    list.partition(entries, fn(entry) { entry.0 == returns_clause_key })
  use returns <- result.try(case known {
    [] -> Ok(None)
    [#(_, payload)] -> parse_bound_effect(payload) |> result.map(Some)
    // One slot, so a second `returns` is a parse error rather than a silent
    // last-wins.
    _ -> Error(Nil)
  })
  Ok(#(
    returns,
    list.map(unknown, fn(entry) {
      UnknownClause(key: entry.0, payload: entry.1)
    }),
  ))
}

// Split one clause entry into its key and its payload at the entry's first
// depth-0 colon. The key is validated; the payload is checked for balanced
// delimiters and otherwise left verbatim, since reading it is exactly what this
// version cannot do.
fn parse_clause_entry(entry: String) -> Result(#(String, String), Nil) {
  use #(key_part, payload_part) <- result.try(split_top_level(entry, ":"))
  let key = string.trim(key_part)
  let payload = string.trim(payload_part)
  use <- bool.guard(when: !is_clause_key(key), return: Error(Nil))
  use <- bool.guard(when: payload == "", return: Error(Nil))
  use <- bool.guard(when: !balanced_delimiters(payload), return: Error(Nil))
  Ok(#(key, payload))
}

// Whether a token spells a clause key. Deliberately wide enough to admit the
// dotted and numeric shapes a later version may mint (`returns.0`,
// `returns.Ok.0`) without endorsing any of them: a reader that rejected them
// would be the thing blocking the grammar it exists to leave room for.
fn is_clause_key(key: String) -> Bool {
  key != ""
  && list.all(string.to_graphemes(key), fn(char) {
    case char {
      "." | "_" -> True
      _ -> is_alphanumeric(char)
    }
  })
}

fn is_alphanumeric(char: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    char,
  )
}

// Whether a payload's brackets and parens nest and match. A stack, not a depth
// count: `depth_delta` counts `[` and `(` alike and lets depth go negative, so a
// net-zero check waves `([)]` and `)(` through, and a retained clause is
// re-emitted verbatim — corrupt text would round-trip as well-formed.
fn balanced_delimiters(payload: String) -> Bool {
  delimiter_loop(string.to_graphemes(payload), [])
}

fn delimiter_loop(graphemes: List(String), stack: List(String)) -> Bool {
  case graphemes, stack {
    [], [] -> True
    [], _ -> False
    ["[" as opener, ..rest], _ | ["(" as opener, ..rest], _ ->
      delimiter_loop(rest, [opener, ..stack])
    ["]", ..rest], ["[", ..stack] -> delimiter_loop(rest, stack)
    [")", ..rest], ["(", ..stack] -> delimiter_loop(rest, stack)
    ["]", ..], _ | [")", ..], _ -> False
    [_, ..rest], _ -> delimiter_loop(rest, stack)
  }
}

fn parse_annotation_head(
  kind: AnnotationKind,
  head: String,
  returns: Option(EffectTerm),
) -> Result(EffectAnnotation, Nil) {
  // A params list opens with the `(` immediately after the function name. An
  // application's `(` inside the effect set is preceded by `[`, so a `[` before
  // the first `(` means there are no params (the `(` belongs to the result).
  case split_call(head) {
    Error(Nil) ->
      case parse_name_colon_effects(head) {
        Error(Nil) -> Error(Nil)
        Ok(#(name, effects)) ->
          Ok(EffectAnnotation(
            kind:,
            function: name,
            params: [],
            effects:,
            returns:,
          ))
      }
    Ok(#(name, params_str, suffix)) ->
      parse_params_suffix(kind, string.trim(name), params_str, suffix, returns)
  }
}

// The word opening the clause region. The single spelling of it: the reader
// finds a statement's end by it, the writer opens a wrapped statement's
// continuation with it, and the continuation's alignment column is measured off
// what the writer emits.
const clause_region_word = "where"

// The keyword opening the clause region. Split at bracket and paren depth 0
// only: the effect-term grammar reads any word inside brackets as a variable,
// so `[A, where returns : B]` must not be cut.
const clause_region_keyword = " " <> clause_region_word <> " "

// The one clause key this version reads. Every other key is retained and
// ignored.
const returns_clause_key = "returns"

// Split a statement into its head and the text of its `where` region. `None`
// where the statement carries no region.
fn split_clause_region(rest: String) -> Result(#(String, Option(String)), Nil) {
  case split_top_level(rest, clause_region_keyword) {
    Error(Nil) -> Ok(#(rest, None))
    Ok(#(head, tail)) -> Ok(#(head, Some(tail)))
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
  returns: Option(EffectTerm),
) -> Result(EffectAnnotation, Nil) {
  use <- bool.guard(when: name == "", return: Error(Nil))
  let suffix_trimmed = string.trim(suffix)
  case string.starts_with(suffix_trimmed, ":") {
    False -> Error(Nil)
    True -> {
      let effects_str = string.trim(string.drop_start(suffix_trimmed, 1))
      case parse_effect_term(effects_str), parse_params_section(params_str) {
        Ok(effects), Ok(params) ->
          Ok(EffectAnnotation(
            kind:,
            function: name,
            params:,
            effects:,
            returns:,
          ))
        _, _ -> Error(Nil)
      }
    }
  }
}

// What an `assume` line's path names. Told apart by shape alone, which Gleam
// casing makes unambiguous: module paths are lower snake with slashes, type
// names UpperCamel.
type AssumeSubject {
  AssumeModule(module: String)
  AssumeFunction(module: String, function: String)
  AssumeField(module: option.Option(String), type_name: String, field: String)
}

// Parse an `assume <path> : <effects>` line into the annotation its path shape
// names. A function's or a module's effects reduce to a set, as an assumption
// is first-order by construction; a field's stay a term.
fn parse_assume_line(rest: String) -> Result(GradedLine, Nil) {
  parse_clause_then(rest, parse_assume_head)
}

fn parse_assume_head(
  head: String,
  returns: Option(EffectTerm),
  unknown_clauses: List(UnknownClause),
) -> Result(GradedLine, Nil) {
  use split <- result.try(split_assume_head(head, returns, unknown_clauses))
  let AssumeHead(path:, written:, params:, term:) = split
  use subject <- result.try(split_assume_path(path))
  // A bound list attaches to a function path alone: a module has no
  // parameters, and a field's callable shape is not per-parameter. Refused
  // loudly rather than linted — a paren group on either path (empty included)
  // spells a grammar the path has no slot for.
  use <- bool.guard(
    when: params != None
      && {
      case subject {
        AssumeFunction(..) -> False
        AssumeModule(..) | AssumeField(..) -> True
      }
    },
    return: Error(Nil),
  )
  let effects = option.map(term, effect_term.to_effect_set)
  case term, returns {
    // Nothing on the line means anything to this version, so there is no
    // semantic record to hang the retained clauses on — and fabricating an
    // empty effect set for one would turn *keys nothing* into *is pure*. The
    // path is still read for its shape, so a malformed one is refused rather
    // than retained. A bound list is part of the retained path text — a line
    // that keys nothing gives it no semantics — so `written` keeps it.
    None, None -> Ok(RetainedAssumeLine(path: written, unknown_clauses:))
    _, _ ->
      case subject {
        AssumeModule(module:) ->
          Ok(ExternalLine(
            ExternalAnnotation(
              module:,
              target: ModuleExternal,
              params: [],
              effects:,
              returns:,
            ),
            unknown_clauses,
          ))
        AssumeFunction(module:, function:) ->
          Ok(ExternalLine(
            ExternalAnnotation(
              module:,
              target: FunctionExternal(function),
              params: option.unwrap(params, []),
              effects:,
              returns:,
            ),
            unknown_clauses,
          ))
        AssumeField(module:, type_name:, field:) -> {
          // A field annotation has no slot for a returned operator.
          use <- bool.guard(when: returns != None, return: Error(Nil))
          use effects <- result.try(option.to_result(term, Nil))
          Ok(TypeFieldLine(
            TypeFieldAnnotation(module:, type_name:, field:, effects:),
            unknown_clauses,
          ))
        }
      }
  }
}

// An `assume` head, split: the bare path, the path as written (bound list
// included, for the retained line that keeps it verbatim), the bound list
// (`None` where the head carries no paren group, told apart from an empty one
// so a paren group on a path with no parameter slot is refused), and the
// effects term.
type AssumeHead {
  AssumeHead(
    path: String,
    written: String,
    params: Option(List(ParamBound)),
    term: Option(EffectTerm),
  )
}

// Split an `assume` head into its path, its bound list and its effects clause.
// The effects clause is optional only where a `where` region carries the line —
// a known clause or a retained one alike: a path on its own claims nothing at
// all, and a path beside a clause no version but a later one reads is still a
// line worth keeping.
//
// The bounded form is read through `split_call` first, because a bound list
// carries colons of its own (`(cb: [cb])`): deciding the effects clause by the
// head's first colon would cut a bounded head inside its bounds.
fn split_assume_head(
  head: String,
  returns: Option(EffectTerm),
  unknown_clauses: List(UnknownClause),
) -> Result(AssumeHead, Nil) {
  case split_call(head) {
    Ok(#(name, params_str, suffix)) -> {
      let path = string.trim(name)
      use <- bool.guard(when: path == "", return: Error(Nil))
      use params <- result.try(parse_params_section(params_str))
      let written = path <> "(" <> params_str <> ")"
      use term <- result.try(case string.trim(suffix) {
        // A bounded path with no effects clause claims nothing unless a
        // `where` region rides the line — the same rule as the boundless
        // spelling below.
        "" -> {
          use <- bool.guard(
            when: returns == None && unknown_clauses == [],
            return: Error(Nil),
          )
          Ok(None)
        }
        ":" <> effects_str ->
          parse_effect_term(string.trim(effects_str)) |> result.map(Some)
        _ -> Error(Nil)
      })
      Ok(AssumeHead(path:, written:, params: Some(params), term:))
    }
    Error(Nil) ->
      case string.contains(head, ":") {
        True ->
          parse_name_colon_effects(head)
          |> result.map(fn(pair) {
            AssumeHead(
              path: pair.0,
              written: pair.0,
              params: None,
              term: Some(pair.1),
            )
          })
        False -> {
          let path = string.trim(head)
          use <- bool.guard(
            when: path == "" || { returns == None && unknown_clauses == [] },
            return: Error(Nil),
          )
          Ok(AssumeHead(path:, written: path, params: None, term: None))
        }
      }
  }
}

// Whether a path names a type field rather than a function or a module, by the
// same shape rule an `assume` line's subject is read by. Told apart from a
// function path by an UpperCamel second-to-last segment.
pub fn is_field_path(path: String) -> Bool {
  case split_assume_path(path) {
    Ok(AssumeField(..)) -> True
    Ok(AssumeModule(..)) | Ok(AssumeFunction(..)) | Error(Nil) -> False
  }
}

// Split an `assume` line's path by segment count and casing:
//
//   `gleam/io`                 -> the whole module
//   `gleam/io.println`         -> one function
//   `Handler.on_click`         -> one field, its type's module implied
//   `m/dom.Handler.on_click`   -> one field of a named module's type
//
// An empty segment, and a three-or-more-segment path whose second-to-last
// segment is not a type name, are `Error(Nil)`.
fn split_assume_path(path: String) -> Result(AssumeSubject, Nil) {
  let segments = string.split(path, ".")
  use <- bool.guard(
    when: list.any(segments, fn(segment) { segment == "" }),
    return: Error(Nil),
  )
  case segments {
    [module] -> Ok(AssumeModule(module:))
    [first, second] ->
      case types.is_upper_initial(first) {
        True -> Ok(AssumeField(module: None, type_name: first, field: second))
        False -> Ok(AssumeFunction(module: first, function: second))
      }
    // Three or more segments is the field grammar's qualified form. Read by
    // the same splitter the `effect` query uses, so the two agree on where the
    // module ends; an `assume` line additionally requires an UpperCamel type.
    _ -> {
      use #(module, type_name, field) <- result.try(split_type_field_name(path))
      case types.is_upper_initial(type_name) {
        True -> Ok(AssumeField(module:, type_name:, field:))
        False -> Error(Nil)
      }
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
  // Reserve the `$op$` sentinel prefix (Fix D). graded never *writes* one — it
  // renames sentinels back to real names before serialization — so a `$op$` token
  // in a loaded `.graded` is forged and must never mint a `TVar` that could
  // masquerade as a producer's sentinel. Ground it to `[Unknown]` instead. The
  // check runs *before* the `(` split so an application head (`$op$f([A])`) is
  // caught too; a nested occurrence is caught by the recursive descent.
  use <- bool.guard(
    when: string.starts_with(string.trim(token), effect_term.sentinel_prefix),
    return: Ok(effect_term.unknown()),
  )
  case string.split_once(token, "(") {
    Ok(#(name, rest)) -> {
      use <- bool.guard(when: !string.ends_with(rest, ")"), return: Error(Nil))
      let callee = string.trim(name)
      use <- bool.guard(when: !is_identifier_token(callee), return: Error(Nil))
      use args <- result.try(parse_application_args(string.drop_end(rest, 1)))
      Ok(list.fold(args, TVar(callee), fn(acc, arg) { TApp(acc, arg) }))
    }
    Error(Nil) -> {
      use <- bool.guard(when: !is_identifier_token(token), return: Error(Nil))
      case is_label_token(token) {
        True -> Ok(TLabels(set.from_list([token])))
        False -> Ok(TVar(token))
      }
    }
  }
}

// Whether a token is one bare identifier, which is all a label or a variable is
// ever spelled as. Whitespace, brackets, parens and colons inside one mean the
// text around the effect set leaked into it: a near-miss of the
// ` where returns ` keyword (`[] where returns: [X]`, `[]where returns : [X]`)
// leaves the whole clause inside the set, where it would otherwise mint a
// variable named after the typo and round-trip byte-identically.
fn is_identifier_token(token: String) -> Bool {
  token != ""
  && !list.any([" ", "\t", "[", "]", "(", ")", ":"], string.contains(token, _))
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
    list.fold(string.to_graphemes(input), #([], [], 0), fn(state, char) {
      let #(segments, current, depth) = state
      case char {
        "," if depth == 0 -> #([joined(current), ..segments], [], depth)
        "[" | "(" -> #(segments, [char, ..current], depth + 1)
        "]" | ")" -> #(segments, [char, ..current], depth - 1)
        _ -> #(segments, [char, ..current], depth)
      }
    })
  list.reverse([joined(current), ..segments])
}

// A reversed grapheme accumulator, back into a string.
fn joined(reversed: List(String)) -> String {
  reversed |> list.reverse() |> string.concat()
}

// Split `input` at the first occurrence of `token` sitting at bracket and paren
// depth 0. `Error(Nil)` where every occurrence is nested, or there is none.
fn split_top_level(
  input: String,
  token: String,
) -> Result(#(String, String), Nil) {
  split_top_level_from(input, token, "", 0)
}

fn split_top_level_from(
  rest: String,
  token: String,
  seen: String,
  depth: Int,
) -> Result(#(String, String), Nil) {
  use #(before, after) <- result.try(string.split_once(rest, token))
  let depth = depth + depth_delta(before)
  case depth == 0 {
    True -> Ok(#(seen <> before, after))
    False -> split_top_level_from(after, token, seen <> before <> token, depth)
  }
}

// How much a run of text opens or closes brackets and parens overall.
fn depth_delta(text: String) -> Int {
  string.to_graphemes(text)
  |> list.fold(0, fn(depth, char) {
    case char {
      "[" | "(" -> depth + 1
      "]" | ")" -> depth - 1
      _ -> depth
    }
  })
}

// Parse a parameter bound's effect: an operator `fn(a, b) -> [body]` (a curried
// `TAbs`) or an ordinary effect term `[...]`.
fn parse_bound_effect(input: String) -> Result(EffectTerm, Nil) {
  let trimmed = string.trim(input)
  case string.starts_with(trimmed, "fn(") {
    False -> parse_effect_term(trimmed)
    True -> {
      // The binder list runs to the paren matching the `fn(`, so a binder list
      // holding a nested paren is cut in the right place.
      use #(params_part, after) <- result.try(
        match_paren(string.to_graphemes(string.drop_start(trimmed, 3)), 0, []),
      )
      let params =
        params_part
        |> split_top_level_commas()
        |> list.map(string.trim)
        |> list.filter(fn(param) { param != "" })
      use <- bool.guard(when: params == [], return: Error(Nil))
      // A `$op$`-prefixed *binder* (`fn($op$x) -> …`) is a forged sentinel (Fix D).
      // It can't be ground in place like a variable, so the whole abstraction
      // parses conservatively as `[Unknown]` rather than as a parse `Error`, which
      // would refuse the whole file over one forged binder.
      use <- bool.guard(
        when: list.any(params, string.starts_with(
          _,
          effect_term.sentinel_prefix,
        )),
        return: Ok(effect_term.unknown()),
      )
      use #(_, body_str) <- result.try(string.split_once(after, "->"))
      use body <- result.try(parse_effect_term(string.trim(body_str)))
      Ok(list.fold_right(params, body, fn(acc, param) { TAbs(param, acc) }))
    }
  }
}

// Extraction
//
// Pull typed annotation lists out of a parsed GradedFile, dropping the
// structural lines (comments, blanks) that only matter for round-tripping.

// Extract all annotations from a parsed file.
pub fn extract_annotations(file: GradedFile) -> List(EffectAnnotation) {
  list.filter_map(file.lines, fn(line) {
    case line {
      AnnotationLine(annotation, _) -> Ok(annotation)
      TypeFieldLine(_, _) -> Error(Nil)
      ExternalLine(_, _) -> Error(Nil)
      RetainedAssumeLine(..) -> Error(Nil)
      CommentLine(_) -> Error(Nil)
      BlankLine -> Error(Nil)
    }
  })
}

// The path a line names, `Error(Nil)` for a comment or a blank. The one
// derivation of it: what `format_sorted` orders the `assume` section by and what
// a warning names its subject with, so a line is reported by the path the file
// renders for it.
pub fn line_path(line: GradedLine) -> Result(String, Nil) {
  case line {
    AnnotationLine(annotation, _) -> Ok(annotation.function)
    TypeFieldLine(tf, _) -> Ok(type_field_path(tf))
    ExternalLine(ext, _) -> Ok(external_sort_key(ext))
    RetainedAssumeLine(path:, ..) -> Ok(path)
    CommentLine(_) | BlankLine -> Error(Nil)
  }
}

// The clauses a line retained without reading, empty for a line carrying none.
pub fn line_unknown_clauses(line: GradedLine) -> List(UnknownClause) {
  case line {
    AnnotationLine(_, clauses)
    | TypeFieldLine(_, clauses)
    | ExternalLine(_, clauses)
    | RetainedAssumeLine(unknown_clauses: clauses, ..) -> clauses
    CommentLine(_) | BlankLine -> []
  }
}

// The path of every line carrying a clause this version does not read, with
// that line's keys in the order they were written. The lint's whole input.
pub fn unknown_clause_lines(file: GradedFile) -> List(#(String, List(String))) {
  list.filter_map(file.lines, fn(line) {
    use path <- result.try(line_path(line))
    case line_unknown_clauses(line) {
      [] -> Error(Nil)
      clauses -> Ok(#(path, list.map(clauses, fn(clause) { clause.key })))
    }
  })
}

// Extract only `check` annotations (enforced invariants).
pub fn extract_checks(file: GradedFile) -> List(EffectAnnotation) {
  extract_annotations(file)
  |> list.filter(fn(annotation) { annotation.kind == Check })
}

// Extract only `effects` annotations (inferred, regenerated by `infer`).
pub fn extract_effects(file: GradedFile) -> List(EffectAnnotation) {
  extract_annotations(file)
  |> list.filter(fn(annotation) { annotation.kind == Effects })
}

// Extract type field annotations from a parsed file.
pub fn extract_type_fields(file: GradedFile) -> List(TypeFieldAnnotation) {
  list.filter_map(file.lines, fn(line) {
    case line {
      TypeFieldLine(tf, _) -> Ok(tf)
      _ -> Error(Nil)
    }
  })
}

// Extract external annotations from a parsed file.
pub fn extract_externals(file: GradedFile) -> List(ExternalAnnotation) {
  list.filter_map(file.lines, fn(line) {
    case line {
      ExternalLine(external_annotation, _) -> Ok(external_annotation)
      _ -> Error(Nil)
    }
  })
}

// The `<module>.<function>` names a file declares an *effect* for with a
// function-level `assume <module>.<function> : [...]` line. Module-level
// declarations (`assume <module> : [...]`) don't count — they target a whole
// module, not one function — and neither does a line carrying only a
// `where returns` clause, which claims nothing about the function's own
// effect. That line is authoritative for the function it names, so both
// `merge_inferred` and the committed-bounds load treat an `effects` line for
// the same name as stale.
//
// Not every such line is valid. One naming a function of this package's own
// source that has a visible Gleam body declares nothing — the callers see that
// body — and its name reaches both readers as `stale`, which restores the
// `effects` line to authority over it.
pub fn external_function_names(file: GradedFile) -> set.Set(String) {
  declaring_function_names(file, fn(ext) { option.is_some(ext.effects) })
}

// The line and operator of every `where returns` clause on an `assume` line.
// The whole annotation rather than its rendered path, so a reader judges a
// clause by the target it parsed as — the ones naming no function included.
pub fn assume_returns(
  file: GradedFile,
) -> List(#(ExternalAnnotation, EffectTerm)) {
  list.filter_map(extract_externals(file), fn(ext) {
    case ext.returns {
      Some(operator) -> Ok(#(ext, operator))
      None -> Error(Nil)
    }
  })
}

// The `<module>.<function>` names a file declares a returned operator for with
// a `where returns` clause on an `assume` line. Read by `merge_inferred`, which
// writes no clause of its own for a name a declaration already answers for, and
// by the stale-declaration lint.
pub fn assume_returns_names(file: GradedFile) -> set.Set(String) {
  declaring_function_names(file, fn(ext) { option.is_some(ext.returns) })
}

// The `<module>.<function>` names whose per-function `assume` line carries the
// claim `claims` selects. One walk for both channels — the effect one and the
// returned-operator one — so the rule that a module-level line names no
// function is stated once and the two cannot drift apart.
fn declaring_function_names(
  file: GradedFile,
  claims: fn(ExternalAnnotation) -> Bool,
) -> set.Set(String) {
  extract_externals(file)
  |> list.filter_map(fn(ext) {
    case claims(ext) {
      True -> external_line_name(ext)
      False -> Error(Nil)
    }
  })
  |> set.from_list()
}

// The modules a file declares with a module-level `assume
// <module> : [...]` line (no `.`). Per-function externals (`<module>.<fn>`)
// don't count — they target one function, not the whole module. These are the
// modules whose source inference the consumer's declaration overrides.
pub fn module_external_modules(file: GradedFile) -> set.Set(String) {
  list.filter_map(extract_externals(file), fn(ext) {
    case ext.target, ext.effects {
      ModuleExternal, Some(_) -> Ok(ext.module)
      ModuleExternal, None | FunctionExternal(_), _ -> Error(Nil)
    }
  })
  |> set.from_list()
}

// Qualified names
//
// Spec files identify functions by module-qualified name; splitting one back
// into its parts is needed wherever a name must be resolved per-module.

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

// Split a spec-file *function* name into its module path and function name.
// Stricter than `split_qualified_name`: the module path uses slashes, so a
// qualified function name has exactly one `.`. A name with more is a type field
// (`module.Type.field`) or malformed, and is rejected here rather than being
// keyed under a dotted module that would shadow the field `assume` line
// declaring it.
//
// `split_qualified_name` stays the lenient last-dot split for the payloads that
// legitimately carry dotted left-hand sides (nested field receivers such as
// `config.inner.run`).
pub fn split_function_name(
  qualified: String,
) -> Result(#(String, String), Nil) {
  case string.split(qualified, ".") {
    [module, function] if module != "" && function != "" ->
      Ok(#(module, function))
    _ -> Error(Nil)
  }
}

// Split a type-field name into its optional module path, type name, and field.
// Two forms are accepted:
//
//   `TypeName.field`             -> #(None, TypeName, field)
//   `module/path.TypeName.field` -> #(Some(module/path), TypeName, field)
//
// The bare form is used in per-module cache files where the type's module is
// implied by the file's location; the qualified form is used in spec files where
// annotations from many modules share one file.
//
// The last two segments are always the type name and the field, and any leading
// segments are joined back with `.`. The single authority on where the module
// ends: what the `effect` query splits a queried name with, and what
// `split_assume_path` reads a qualified `assume` subject with, that one
// additionally requiring the type name to be UpperCamel.
pub fn split_type_field_name(
  qualified: String,
) -> Result(#(option.Option(String), String, String), Nil) {
  case string.split(qualified, ".") {
    [type_name, field] if type_name != "" && field != "" ->
      Ok(#(None, type_name, field))
    segments -> {
      let count = list.length(segments)
      use <- bool.guard(count < 3, Error(Nil))
      let module = segments |> list.take(count - 2) |> string.join(".")
      case list.drop(segments, count - 2) {
        [type_name, field] if module != "" && type_name != "" && field != "" ->
          Ok(#(Some(module), type_name, field))
        _ -> Error(Nil)
      }
    }
  }
}

// Merging
//
// Fold freshly inferred results into an existing GradedFile so `graded infer`
// updates derived lines without disturbing hand-written ones.

// Merge inferred effects into an existing GradedFile, preserving structure.
//
// - `check` / `assume` lines, comments, blanks: kept in place
// - Existing `effects` lines: updated in-place; removed if stale
// - New functions not yet in file: `effects` lines appended at end
//
// The two stale sets are separate channels and stay separate: an `assume` line
// that declares no effects suppresses this package's `effects` lines for the
// name, and one that declares no returned operator suppresses the clause on
// that line. Threading either set into the other's filters deletes a claim
// about a channel nobody declared anything on.
//
// The declarations themselves are scoped the same way, and for the same reason.
// An assumption about what a function *does* suppresses the inferred `effects`
// lines it covers, but a `where returns` clause on one of those lines is a claim
// about what the function *returns*, which nothing has declared. Such a line
// survives whole — the grammar has no clause-only `effects` line, so the effects
// half rides along and the loaders read the declaration over it. Only both
// declarations together take the line out.
pub fn merge_inferred(
  file: GradedFile,
  inferred: List(EffectAnnotation),
  stale_externals: set.Set(String),
  stale_returns_clauses: set.Set(String),
) -> GradedFile {
  // The value channel first, so the two suppressions compose: a name both an
  // effects declaration and a returns declaration cover loses its clause here
  // and its whole line below, rather than surviving on a clause the declaration
  // already answers for.
  //
  // A function whose return an `assume … where returns` clause declares needs
  // no inferred clause: the declaration answers for it, and a second claim for
  // the same name would sit in the file looking like a second opinion. Except
  // where that declaration is stale — it names one of this package's own
  // ordinary functions — in which case it is dropped below and the inferred
  // clause written in its place.
  let declared_returns =
    set.difference(assume_returns_names(file), stale_returns_clauses)
  let inferred =
    list.map(inferred, fn(annotation) {
      case set.contains(declared_returns, annotation.function) {
        True -> EffectAnnotation(..annotation, returns: None)
        False -> annotation
      }
    })

  // A function the author declared with `assume mod.fn : [...]` is
  // authoritative — that line is their opt-in to a precise FFI effect. Drop any
  // inferred `effects mod.fn` line for it so the opaque-FFI `[Unknown]` default
  // neither shadows nor duplicates the author's declaration (and a stale prior
  // inferred line is cleaned up on re-infer).
  //
  // Except where the line names one of this package's own ordinary functions.
  // Nothing there is foreign, so the line is stale rather than authoritative: it
  // is dropped below and the inferred `effects` line written in its place, which
  // is what stops `check` warning about it forever while the spec under-reports
  // the function.
  let external_functions =
    set.difference(external_function_names(file), stale_externals)
  // A module-level `assume mod : [...]` declares the whole module's
  // effect, so every inferred `effects mod.fn` line is likewise redundant and
  // would shadow the declaration. Drop them all for the declared module.
  let external_modules = module_external_modules(file)
  // The `effects` lines carrying a clause this version does not read. Scoped to
  // `effects` lines because those are the only ones rebuilt from `inferred_map`
  // below; every other line kind survives on its own path.
  let retaining_effects =
    names_of_lines(file.lines, fn(line) {
      case line {
        AnnotationLine(a, [_, ..]) if a.kind == Effects -> Ok(a.function)
        AnnotationLine(..)
        | TypeFieldLine(..)
        | ExternalLine(..)
        | RetainedAssumeLine(..)
        | CommentLine(_)
        | BlankLine -> Error(Nil)
      }
    })
  let inferred =
    list.filter(inferred, fn(annotation) {
      // Both declarations speak for the effects channel alone. A line still
      // carrying a clause after the strip above is the only home that clause
      // has — the grammar writes no clause-only `effects` line — so it survives
      // whole, and the loaders read the declaration over its effects half. That
      // holds for a retained clause as much as for an inferred one, and more
      // so: this version can re-derive the operator it wrote, and cannot
      // re-derive a key it does not read. A clause-less line claims nothing the
      // declaration does not, and goes.
      option.is_some(annotation.returns)
      || set.contains(retaining_effects, annotation.function)
      || {
        !set.contains(external_functions, annotation.function)
        && !in_external_module(annotation.function, external_modules)
      }
    })

  let inferred_map =
    inferred
    |> list.map(fn(annotation) { #(annotation.function, annotation) })
    |> dict.from_list()

  // The functions whose `effects` lines already exist in the file are updated
  // in place below; the rest are appended.
  let present_effects =
    names_of_lines(file.lines, fn(line) {
      case line {
        AnnotationLine(a, _) if a.kind == Effects -> Ok(a.function)
        AnnotationLine(_, _) -> Error(Nil)
        TypeFieldLine(_, _) -> Error(Nil)
        ExternalLine(_, _) -> Error(Nil)
        RetainedAssumeLine(..) -> Error(Nil)
        CommentLine(_) -> Error(Nil)
        BlankLine -> Error(Nil)
      }
    })

  // An `effects` line takes its freshly inferred value; one whose function is
  // no longer inferred is stale and dropped. A `check`/`assume`/comment/blank
  // stays as written, minus whichever of an `assume` line's two claims is
  // stale.
  //
  // A clause this version does not read survives every one of those paths
  // except the drop, where the subject itself is gone. Only a version that
  // understands a key can re-derive it, so a rewrite that dropped one would
  // delete from a committed file something nothing here can put back.
  let new_lines =
    list.filter_map(file.lines, fn(line) {
      case line {
        AnnotationLine(a, unknown_clauses) if a.kind == Effects ->
          dict.get(inferred_map, a.function)
          |> result.map(AnnotationLine(_, unknown_clauses))
        ExternalLine(e, unknown_clauses) ->
          case
            surviving_external(e, stale_externals, stale_returns_clauses),
            unknown_clauses
          {
            Ok(external), _ -> Ok(ExternalLine(external, unknown_clauses))
            Error(Nil), [] -> Error(Nil)
            // Both declarations went stale, but the line still carries a clause
            // only a later version can judge. What it keys is gone; what it
            // retains is not — the bound list included, which rides the
            // retained path.
            Error(Nil), _ ->
              Ok(RetainedAssumeLine(path: external_path(e), unknown_clauses:))
          }
        _ -> Ok(line)
      }
    })

  let remaining_effects =
    inferred
    |> list.filter(fn(a) { !set.contains(present_effects, a.function) })
    |> list.map(AnnotationLine(_, []))

  GradedFile(lines: list.flatten([new_lines, remaining_effects]))
}

// One `assume` line's annotation after the stale claims are stripped from it,
// or `Error(Nil)` where nothing it claimed survives. The record rather than the
// line, so the call site keeps what the line retained.
fn surviving_external(
  external: ExternalAnnotation,
  stale_externals: set.Set(String),
  stale_returns_clauses: set.Set(String),
) -> Result(ExternalAnnotation, Nil) {
  case external_line_name(external) {
    Error(Nil) -> Ok(external)
    Ok(name) -> {
      let effects = case set.contains(stale_externals, name) {
        True -> None
        False -> external.effects
      }
      let returns = case set.contains(stale_returns_clauses, name) {
        True -> None
        False -> external.returns
      }
      case effects, returns {
        None, None -> Error(Nil)
        _, _ -> Ok(ExternalAnnotation(..external, effects:, returns:))
      }
    }
  }
}

// The `<module>.<function>` a per-function external names, or `Error(Nil)` for
// a module-level one.
fn external_line_name(external: ExternalAnnotation) -> Result(String, Nil) {
  case external.target {
    FunctionExternal(_) -> Ok(external_sort_key(external))
    ModuleExternal -> Error(Nil)
  }
}

// The set of names a filter extracts from a list of lines.
fn names_of_lines(
  lines: List(GradedLine),
  extract: fn(GradedLine) -> Result(String, Nil),
) -> set.Set(String) {
  lines |> list.filter_map(extract) |> set.from_list()
}

// Whether a qualified function name's module carries a module-level external.
// Short-circuits when nothing is declared (the common case), so the qualified
// name isn't split needlessly.
fn in_external_module(
  function: String,
  external_modules: set.Set(String),
) -> Bool {
  use <- bool.guard(set.is_empty(external_modules), False)
  case split_qualified_name(function) {
    Ok(#(module, _function)) -> set.contains(external_modules, module)
    Error(Nil) -> False
  }
}

// Formatting
//
// Render annotations and whole files back to .graded text — the single source
// of truth for the on-disk surface syntax, so parse and format round-trip.

// Render a full GradedFile back to a string, preserving structure.
pub fn format_file(file: GradedFile) -> String {
  file.lines |> list.map(format_line) |> string.join("\n")
}

// The width past which a statement moves its clause region onto continuation
// lines. `gleam format`'s own target, measured in graphemes on the canonical
// one-line rendering — not bytes and not terminal display width, so
// `format --check` puts the boundary in the same place everywhere.
//
// The trigger does not promise 80 columns: only the clause region wraps. A long
// effect set stays on its line, since wrapping that means a pretty-printer over
// the whole effect grammar.
const max_line_width = 80

// What a wrapped statement's `where` opens with. The clause after it sets the
// column its siblings align in, so the alignment is measured off this exact
// string rather than re-added from its parts.
const clause_opener = "  " <> clause_region_word <> " "

// Render one line of a file. The wrap rule lives here rather than in the
// semantic renderers below: those have callers that splice their output into
// prose, and a renderer that can return a newline breaks them silently.
fn format_line(line: GradedLine) -> String {
  let #(head, clauses) = statement_parts(line)
  let inline = inline_statement(#(head, clauses))
  // All-or-nothing, never filled to width: `format --check` is a CI gate, so
  // the rule has to be trivially deterministic.
  case clauses == [] || string.length(inline) <= max_line_width {
    True -> inline
    False ->
      head
      <> "\n"
      <> clause_opener
      <> string.join(
        clauses,
        ",\n" <> string.repeat(" ", string.length(clause_opener)),
      )
  }
}

// A line split into the head it renders and its clause list, each clause
// rendered. The seam the wrap rule works at: everything built from these stays
// on one line, and only `format_line` may put a newline between them.
fn statement_parts(line: GradedLine) -> #(String, List(String)) {
  case line {
    AnnotationLine(annotation, unknown_clauses) -> #(
      annotation_head(annotation),
      clause_list(annotation.returns, unknown_clauses),
    )
    TypeFieldLine(tf, unknown_clauses) -> #(
      type_field_head(tf),
      clause_list(None, unknown_clauses),
    )
    ExternalLine(ext, unknown_clauses) -> #(
      external_head(ext),
      clause_list(ext.returns, unknown_clauses),
    )
    RetainedAssumeLine(path:, unknown_clauses:) -> #(
      "assume " <> path,
      clause_list(None, unknown_clauses),
    )
    CommentLine(text) -> #(text, [])
    BlankLine -> #("", [])
  }
}

// A statement's head and clauses on one physical line.
fn inline_statement(parts: #(String, List(String))) -> String {
  parts.0 <> clause_region(parts.1)
}

// The clauses of one statement, rendered: the known `returns` first, the
// retained unknowns after in read order. A canonical order, so a file that
// wrote them the other way round still formats idempotently.
fn clause_list(
  returns: Option(EffectTerm),
  unknown_clauses: List(UnknownClause),
) -> List(String) {
  let known = case returns {
    Some(operator) -> [returns_clause_key <> " : " <> format_operator(operator)]
    None -> []
  }
  list.append(
    known,
    // Verbatim between its delimiters: this version cannot canonically render a
    // grammar it does not know, so it must not reformat the interior.
    list.map(unknown_clauses, fn(clause) {
      clause.key <> " : " <> clause.payload
    }),
  )
}

// A statement's clause region on one line, or nothing where it carries none.
fn clause_region(clauses: List(String)) -> String {
  case clauses {
    [] -> ""
    _ -> clause_region_keyword <> string.join(clauses, ", ")
  }
}

// Format an GradedFile: normalize spacing, sort annotations, ensure trailing newline.
//
// Output order: leading comments, then one section per status — `assume`
// sorted by path, `check` and `effects` each sorted by function name — blank
// line separated, with a single trailing newline.
pub fn format_sorted(file: GradedFile) -> String {
  let comments = collect_comments(file.lines)

  let check_lines =
    sorted_section(file.lines, fn(line) {
      case line {
        AnnotationLine(a, _) if a.kind == Check -> Ok(a.function)
        _ -> Error(Nil)
      }
    })

  let effects_lines =
    sorted_section(file.lines, fn(line) {
      case line {
        AnnotationLine(a, _) if a.kind == Effects -> Ok(a.function)
        _ -> Error(Nil)
      }
    })

  // Externals, type fields and lines retained for their unknown clauses alone
  // are one `assume` section, ordered by the path each line renders, so the
  // section reads in the order a reader scans it.
  let assume_lines =
    sorted_section(file.lines, fn(line) {
      case line {
        ExternalLine(..) | TypeFieldLine(..) | RetainedAssumeLine(..) ->
          line_path(line)
        _ -> Error(Nil)
      }
    })

  let sections = [comments, assume_lines, check_lines, effects_lines]

  sections
  |> list.filter(fn(section) { section != [] })
  |> list.map(fn(section) { string.join(section, "\n") })
  |> string.join("\n\n")
  |> fn(content) { content <> "\n" }
}

// One section of a sorted file: the lines `key` selects, ordered by the key it
// gives them, each rendered whole.
fn sorted_section(
  lines: List(GradedLine),
  key: fn(GradedLine) -> Result(String, Nil),
) -> List(String) {
  lines
  |> list.filter_map(fn(line) {
    key(line) |> result.map(fn(sort_key) { #(sort_key, line) })
  })
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  |> list.map(fn(entry) { format_line(entry.1) })
}

// Render an EffectAnnotation back to its .graded line format, always on one
// line. Callers outside the file path splice the result into prose, so this and
// its two siblings below go through `inline_statement`, which cannot emit a
// newline; only `format_line` applies the width rule.
pub fn format_annotation(annotation: EffectAnnotation) -> String {
  inline_statement(statement_parts(AnnotationLine(annotation, [])))
}

// The head an `effects`/`check` line renders — everything before its `where`
// region.
fn annotation_head(annotation: EffectAnnotation) -> String {
  let prefix = case annotation.kind {
    Effects -> "effects"
    Check -> "check"
  }
  prefix
  <> " "
  <> annotation.function
  <> bound_list(annotation.params)
  <> " : "
  <> format_effect_term(annotation.effects)
}

// A statement's bound list, parenthesised — nothing at all where it has none.
fn bound_list(params: List(ParamBound)) -> String {
  case params {
    [] -> ""
    _ -> "(" <> string.join(list.map(params, format_param_bound), ", ") <> ")"
  }
}

// The free variables of a statement's `where returns` clause, the operator's
// own binders excluded. Empty where the statement carries no clause. Read by
// the gate that binds a clause's variables and by the lint that reports an open
// one; the parser and the loaders judge a clause not at all.
pub fn clause_free_vars(returns: Option(EffectTerm)) -> set.Set(String) {
  case returns {
    Some(operator) -> effect_term.free_vars(operator)
    None -> set.new()
  }
}

// Format an operator term — a `TAbs` as `fn(cb) -> [body]`, anything else as a
// plain effect term (e.g. a polymorphic returned operator that's a bare `[v]`).
fn format_operator(term: EffectTerm) -> String {
  case term {
    TAbs(_, _) -> render_abstraction(term)
    other -> format_effect_term(other)
  }
}

// Render a TypeFieldAnnotation back to its .graded line format.
pub fn format_type_field(tf: TypeFieldAnnotation) -> String {
  inline_statement(statement_parts(TypeFieldLine(tf, [])))
}

fn type_field_head(tf: TypeFieldAnnotation) -> String {
  "assume " <> type_field_path(tf) <> " : " <> format_effect_term(tf.effects)
}

// The path a type field annotation renders: the qualified form used in spec
// files when the module is present, the bare form used in cache files
// otherwise. A sort key, the rendered name in `format_type_field`, and the name
// the spec lint reports a dead line by, so all three spell one path one way.
pub fn type_field_path(tf: TypeFieldAnnotation) -> String {
  let prefix = case tf.module {
    Some(module) -> module <> "."
    None -> ""
  }
  prefix <> tf.type_name <> "." <> tf.field
}

// Render an ExternalAnnotation back to its `.graded` line format, always on one
// line — see `format_annotation`.
pub fn format_external(external_annotation: ExternalAnnotation) -> String {
  inline_statement(statement_parts(ExternalLine(external_annotation, [])))
}

fn external_head(external_annotation: ExternalAnnotation) -> String {
  let effects_clause = case external_annotation.effects {
    Some(effects) -> " : " <> format_effect_set(effects)
    None -> ""
  }
  "assume " <> external_path(external_annotation) <> effects_clause
}

// The path an `assume` line renders, bound list included — no keyword and no
// effects clause. Shared with `merge_inferred`'s stale-conversion site, which
// rebuilds a `RetainedAssumeLine` from a semantic line and must keep the bounds
// in the retained path.
fn external_path(external_annotation: ExternalAnnotation) -> String {
  external_sort_key(external_annotation)
  <> bound_list(external_annotation.params)
}

// The qualified name (`module` or `module.function`) an external annotation
// targets. Used both as a sort key and as the rendered name in
// `format_external`.
fn external_sort_key(external_annotation: ExternalAnnotation) -> String {
  case external_qualified_name(external_annotation) {
    Error(Nil) -> external_annotation.module
    Ok(qualified) -> types.dotted_name(qualified)
  }
}

// The `QualifiedName` a per-function `assume` line targets, `Error(Nil)` for a
// module-level one. The one place an external's module and function are put
// back together, so every reader that keys by that name — and `external_sort_key`,
// which renders it — agrees on the shape.
pub fn external_qualified_name(
  external_annotation: ExternalAnnotation,
) -> Result(QualifiedName, Nil) {
  case external_annotation.target {
    ModuleExternal -> Error(Nil)
    FunctionExternal(function) ->
      Ok(types.QualifiedName(external_annotation.module, function))
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
pub fn format_param_bound(param: ParamBound) -> String {
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
pub fn format_effect_term(term: EffectTerm) -> String {
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
    // A residual abstraction *inside* an effect set is an under-applied
    // operator, not a resolved effect: an operator bound renders through
    // `format_param_bound`, whose spine walk consumes every binder, so nothing
    // legitimately reaches here. The effect-set grammar has no `fn(..) -> ..`
    // atom, so rendering one would emit a line the parser rejects; ground it to
    // the conservative collapse instead, keeping every rendered line readable
    // back in.
    TAbs(_, _) -> [types.unknown_label]
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
  spine_loop(term, [])
}

fn spine_loop(
  term: EffectTerm,
  args: List(EffectTerm),
) -> #(EffectTerm, List(EffectTerm)) {
  case term {
    TApp(operator, argument) -> spine_loop(operator, [argument, ..args])
    other -> #(other, args)
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
