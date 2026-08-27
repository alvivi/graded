import generators
import gleam/list
import gleam/string
import gleeunit/should
import graded/internal/annotation
import graded/internal/types.{
  AnnotationLine, AssumeLine, BlankLine, Check, CommentLine, Effects,
  FieldAssumeLine, RetainedAssumeLine,
}
import qcheck

// Example-based formatting
//
// Concrete spec inputs run through parse_file and format_sorted, asserting
// exact output: comment preservation, sorting, and spacing normalization.

pub fn preserves_comments_test() {
  let input =
    "// file header
// another comment
effects view : []
check view : []"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal(
    "// file header
// another comment

check view : []

effects view : []
",
  )
}

pub fn only_check_lines_test() {
  let input = "check view : []\ncheck update : [Http]"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal(
    "check update : [Http]
check view : []
",
  )
}

pub fn only_effects_lines_test() {
  let input = "effects view : []\neffects update : [Http]"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal(
    "effects update : [Http]
effects view : []
",
  )
}

pub fn empty_file_test() {
  let input = ""
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal("\n")
}

pub fn normalizes_spacing_test() {
  let input = "effects   view  :  [ Http ,  Dom ]"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal("effects view : [Dom, Http]\n")
}

pub fn sorts_effect_labels_test() {
  let input = "effects handler : [Stdout, Http, Db]"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal("effects handler : [Db, Http, Stdout]\n")
}

// Unknown clauses
//
// Not string identity: the formatter canonically moves the known `returns`
// first, so a file that wrote it last cannot come back byte-identical. The
// three properties that do hold are asserted instead.

pub fn moves_the_known_clause_first_test() {
  let input =
    "effects m.f : [] where future : fn(a,   b) ->  [X], returns : [A], other : [Y]"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal(
    "effects m.f : [] where returns : [A], future : fn(a,   b) ->  [X], other : [Y]\n",
  )
}

pub fn wraps_a_clause_region_past_the_width_test() {
  let input =
    "effects m.longer_function_name : [] where future : [X], returns : [A], other : [Y]"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal(
    "effects m.longer_function_name : []
  where returns : [A],
        future : [X],
        other : [Y]
",
  )
}

pub fn unknown_clause_formatting_is_idempotent_test() {
  let input =
    "effects m.f : [] where future : fn(a,   b) ->  [X], returns : [A], other : [Y]"
  let assert Ok(file) = annotation.parse_file(input)
  let once = annotation.format_sorted(file)
  let assert Ok(reparsed) = annotation.parse_file(once)
  annotation.format_sorted(reparsed) |> should.equal(once)
}

pub fn a_payload_interior_never_moves_test() {
  // Neither pass may touch the bytes between an unknown payload's boundaries:
  // this version cannot canonically render a grammar it does not know.
  let input = "effects m.f : [] where future : fn(a,   b) ->  [X,  Y]"
  let assert Ok(file) = annotation.parse_file(input)
  let once = annotation.format_sorted(file)
  let assert Ok(reparsed) = annotation.parse_file(once)
  let assert [AnnotationLine(_, [clause]), BlankLine] = reparsed.lines
  clause.payload |> should.equal("fn(a,   b) ->  [X,  Y]")
}

// Ordering invariants (property)
//
// qcheck properties over generated spec files: format_sorted keeps sections
// in a fixed order, sorts entries alphabetically, and ends with a newline.

pub fn format_sorted_section_order_test() {
  use file <- qcheck.given(generators.graded_file_gen())
  let sorted = annotation.format_sorted(file)
  let assert Ok(parsed) = annotation.parse_file(sorted)
  let indices =
    parsed.lines
    |> list.filter(fn(line) { line != BlankLine })
    |> list.map(section_index)
  check_non_decreasing(indices)
}

// Externals, type fields and lines retained for their unknown clauses alone
// share the `assume` section, so they share an index.
fn section_index(line: types.GradedLine) -> Int {
  case line {
    CommentLine(_) -> 0
    AssumeLine(_, _) -> 1
    FieldAssumeLine(_, _) -> 1
    RetainedAssumeLine(..) -> 1
    AnnotationLine(a, _) ->
      case a.kind {
        Check -> 2
        Effects -> 3
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
  use file <- qcheck.given(generators.graded_file_gen())
  let sorted = annotation.format_sorted(file)
  let assert Ok(parsed) = annotation.parse_file(sorted)
  let check_names =
    annotation.extract_annotations(parsed)
    |> list.filter(fn(a) { a.kind == Check })
    |> list.map(fn(a) { a.function })
  check_names |> should.equal(list.sort(check_names, string.compare))
}

pub fn format_sorted_effects_alphabetical_test() {
  use file <- qcheck.given(generators.graded_file_gen())
  let sorted = annotation.format_sorted(file)
  let assert Ok(parsed) = annotation.parse_file(sorted)
  let effects_names =
    annotation.extract_annotations(parsed)
    |> list.filter(fn(a) { a.kind == Effects })
    |> list.map(fn(a) { a.function })
  effects_names |> should.equal(list.sort(effects_names, string.compare))
}

pub fn format_sorted_trailing_newline_test() {
  use file <- qcheck.given(generators.graded_file_gen())
  let sorted = annotation.format_sorted(file)
  string.ends_with(sorted, "\n") |> should.be_true()
}
