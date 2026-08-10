// Unit and property tests for `graded/internal/diff`, the line diff behind
// `graded infer --dry-run`. The preview it prints is only trustworthy if the
// diff is byte-exact, so the trailing newline gets as much attention here as
// the changed lines do.

import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import graded/internal/diff
import qcheck

// Changed lines
//
// The shape of the output: additions, removals, replacements, and how far
// apart two edits have to be before they become separate hunks.

pub fn contextual_equal_is_none_test() {
  diff.contextual(
    "effects app.main : [Stdout]\n",
    "effects app.main : [Stdout]\n",
  )
  |> should.equal(None)
}

pub fn contextual_empty_inputs_are_none_test() {
  diff.contextual("", "") |> should.equal(None)
}

pub fn contextual_addition_test() {
  diff.contextual("a\nb\n", "a\nb\nc\n")
  |> should.equal(Some("  a\n  b\n+ c"))
}

pub fn contextual_addition_to_empty_test() {
  diff.contextual("", "a\nb\n")
  |> should.equal(Some("+ a\n+ b"))
}

pub fn contextual_removal_test() {
  diff.contextual("a\nb\nc\n", "a\nc\n")
  |> should.equal(Some("  a\n- b\n  c"))
}

pub fn contextual_replacement_test() {
  diff.contextual("a\nb\nc\n", "a\nB\nc\n")
  |> should.equal(Some("  a\n- b\n+ B\n  c"))
}

// Only two context lines on each side of a change, so the untouched lines
// between two distant edits split the output into separate hunks.
pub fn contextual_distant_edits_make_two_hunks_test() {
  let old = string.join(["a", "b", "c", "d", "e", "f", "g", "h"], "\n") <> "\n"
  let new = string.join(["A", "b", "c", "d", "e", "f", "g", "H"], "\n") <> "\n"
  diff.contextual(old, new)
  |> should.equal(Some("- a\n+ A\n  b\n  c\n@@\n  f\n  g\n- h\n+ H"))
}

// Two changes with only one unchanged line between them stay in one hunk:
// their context ranges touch.
pub fn contextual_nearby_edits_make_one_hunk_test() {
  diff.contextual("a\nb\nc\n", "A\nb\nC\n")
  |> should.equal(Some("- a\n+ A\n  b\n- c\n+ C"))
}

// Trailing newlines
//
// `annotation.format_file` does not append a trailing newline, so a spec file
// gaining or losing one is a real delta the preview has to show rather than
// report as no change.

pub fn contextual_gaining_trailing_newline_test() {
  diff.contextual("a\nb", "a\nb\n")
  |> should.equal(Some("  a\n- b\n\\ No newline at end of file\n+ b"))
}

pub fn contextual_losing_trailing_newline_test() {
  diff.contextual("a\nb\n", "a\nb")
  |> should.equal(Some("  a\n- b\n+ b\n\\ No newline at end of file"))
}

// A line that gains a following line also gains a newline, so it is not a
// context line: it leaves the old side unterminated and enters the new side
// terminated.
pub fn contextual_appending_after_an_unterminated_line_test() {
  diff.contextual("a\nb", "a\nb\nc")
  |> should.equal(Some(
    "  a\n- b\n\\ No newline at end of file\n+ b\n+ c\n\\ No newline at end of file",
  ))
}

pub fn contextual_removing_an_unterminated_line_test() {
  diff.contextual("a\nb\nc", "a\nb")
  |> should.equal(Some(
    "  a\n- b\n- c\n\\ No newline at end of file\n+ b\n\\ No newline at end of file",
  ))
}

// Both sides ending without a newline on the same unchanged line is no delta:
// one marker, on the context line they share.
pub fn contextual_shared_unterminated_line_stays_context_test() {
  diff.contextual("x\nb", "y\nb")
  |> should.equal(Some("- x\n+ y\n  b\n\\ No newline at end of file"))
}

pub fn contextual_empty_against_one_blank_line_test() {
  diff.contextual("", "\n") |> should.equal(Some("+ "))
}

// Each side that ends without a newline gets its own marker, after that
// side's last diff line.
pub fn contextual_marks_both_unterminated_sides_test() {
  diff.contextual("a\nb", "a\nc")
  |> should.equal(Some(
    "  a\n- b\n\\ No newline at end of file\n+ c\n\\ No newline at end of file",
  ))
}

// Equality (property)
//
// The one invariant the dry-run leans on: a diff appears exactly when the
// bytes differ, so "no changes" can never hide a write.

pub fn contextual_is_none_only_for_equal_texts_test() {
  use #(a, b) <- qcheck.given(qcheck.tuple2(text_gen(), text_gen()))
  { diff.contextual(a, b) == None } |> should.equal(a == b)
}

pub fn contextual_reflexive_is_none_test() {
  use text <- qcheck.given(text_gen())
  diff.contextual(text, text) |> should.equal(None)
}

// Draw from a handful of lines so generated pairs collide often enough to
// exercise the equal branch, and end the text with or without a newline.
fn text_gen() -> qcheck.Generator(String) {
  use lines <- qcheck.bind(qcheck.list_from(line_gen()))
  use ending <- qcheck.map(
    qcheck.from_generators(qcheck.return("\n"), [
      qcheck.return(""),
    ]),
  )
  case lines {
    [] -> ""
    _ -> string.join(lines, "\n") <> ending
  }
}

fn line_gen() -> qcheck.Generator(String) {
  qcheck.from_generators(qcheck.return("a"), [
    qcheck.return("b"),
    qcheck.return("effects app.main : [Stdout]"),
    qcheck.return(""),
  ])
}
