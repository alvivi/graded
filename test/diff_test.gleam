// Unit and property tests for `graded/internal/diff`, the line diff behind
// `graded infer --dry-run`. The preview it prints is only trustworthy if the
// diff is byte-exact, so the trailing newline gets as much attention here as
// the changed lines do.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
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
  let old = lines(["a", "b", "c", "d", "e", "f", "g", "h"])
  let new = lines(["A", "b", "c", "d", "e", "f", "g", "H"])
  diff.contextual(old, new)
  |> should.equal(Some("- a\n+ A\n  b\n  c\n@@\n  f\n  g\n- h\n+ H"))
}

// Two changes with only one unchanged line between them stay in one hunk:
// their context ranges touch.
pub fn contextual_nearby_edits_make_one_hunk_test() {
  diff.contextual("a\nb\nc\n", "A\nb\nC\n")
  |> should.equal(Some("- a\n+ A\n  b\n- c\n+ C"))
}

// Ambiguous alignments
//
// Inputs whose longest common subsequence is not unique: two alignments keep
// the same number of lines, so which one the diff picks is a choice rather
// than a consequence. These pin the choice, since it decides where the `-`
// and `+` lines land in a preview.

// `b` is the line both sides agree on the position of relative to nothing
// else, so it stays context and `a` moves around it.
pub fn contextual_swapped_lines_test() {
  diff.contextual("a\nb\n", "b\na\n")
  |> should.equal(Some("- a\n  b\n+ a"))
}

pub fn contextual_dropping_a_repeated_line_test() {
  diff.contextual("a\nb\na\n", "a\nb\n")
  |> should.equal(Some("  a\n  b\n- a"))
}

pub fn contextual_adding_a_repeated_line_test() {
  diff.contextual("a\nb\n", "a\nb\na\n")
  |> should.equal(Some("  a\n  b\n+ a"))
}

// Two lines trading places around a third: the removals lead and the
// additions follow, rather than the pair being split into two hunks.
pub fn contextual_reordered_lines_test() {
  diff.contextual("a\nb\na\nc\n", "a\nc\na\nb\n")
  |> should.equal(Some("  a\n- b\n- a\n  c\n+ a\n+ b"))
}

pub fn contextual_collapsing_a_repeated_line_test() {
  diff.contextual("a\na\n", "a\n")
  |> should.equal(Some("  a\n- a"))
}

// Anchors and gaps
//
// Lines occurring exactly once on each side pin the two sides together, and
// only the gaps between those pins are searched. These are the shapes where
// the pinning has to hold: a block of changed lines with a second change too
// far away for the trimming of the shared ends to reach, and sides with
// nothing to pin at all.

// The inserted block and the distant change stay separate hunks, rather than
// the search losing its place and rewriting everything between them.
pub fn contextual_block_insertion_with_a_distant_change_test() {
  let old = lines(numbered("a", 1, 8))
  let new =
    lines(
      list.flatten([["a1"], numbered("x", 1, 3), numbered("a", 2, 7), ["B8"]]),
    )
  diff.contextual(old, new)
  |> should.equal(Some(
    "  a1\n+ x1\n+ x2\n+ x3\n  a2\n  a3\n@@\n  a6\n  a7\n- a8\n+ B8",
  ))
}

pub fn contextual_block_deletion_with_a_distant_change_test() {
  let old =
    lines(
      list.flatten([["a1"], numbered("x", 1, 3), numbered("a", 2, 7), ["a8"]]),
    )
  let new = lines(list.flatten([["a1"], numbered("a", 2, 7), ["B8"]]))
  diff.contextual(old, new)
  |> should.equal(Some(
    "  a1\n- x1\n- x2\n- x3\n  a2\n  a3\n@@\n  a6\n  a7\n- a8\n+ B8",
  ))
}

// The same shape at a size the exact assertions above cannot spell out: fifty
// inserted lines and one distant replacement, in a two-hundred-line file.
pub fn contextual_large_block_insertion_with_a_distant_change_test() {
  let old = lines(numbered("a", 1, 200))
  let new =
    lines(
      list.flatten([
        numbered("a", 1, 20),
        numbered("x", 1, 50),
        numbered("a", 21, 199),
        ["B200"],
      ]),
    )
  let rendered = diff.contextual(old, new)
  count_starting_with(rendered, "+ ") |> should.equal(51)
  count_starting_with(rendered, "- ") |> should.equal(1)
  count_starting_with(rendered, "@@") |> should.equal(1)
}

// Scattered changes stay one hunk each: five changes far apart are five hunks,
// not one covering the whole file.
pub fn contextual_scattered_changes_make_one_hunk_each_test() {
  let rendered =
    diff.contextual(
      lines(numbered("a", 1, 100)),
      lines(every_twentieth(1, 100)),
    )
  count_starting_with(rendered, "+ ") |> should.equal(5)
  count_starting_with(rendered, "- ") |> should.equal(5)
  count_starting_with(rendered, "@@") |> should.equal(4)
}

// Sides with no line in common share no subsequence either, so the diff is
// every removal and then every addition.
pub fn contextual_sides_sharing_no_line_test() {
  diff.contextual("a\nb\nc\n", "x\ny\nz\n")
  |> should.equal(Some("- a\n- b\n- c\n+ x\n+ y\n+ z"))
}

// Repeated lines pin nothing — which occurrence matches which is the question
// — so the whole middle is searched, and the changed ends stay two hunks.
pub fn contextual_repeated_lines_between_changed_ends_test() {
  let repeated = ["a", "b", "a", "b", "a", "b"]
  diff.contextual(
    lines(list.flatten([["h1"], repeated, ["t1"]])),
    lines(list.flatten([["h2"], repeated, ["t2"]])),
  )
  |> should.equal(Some("- h1\n+ h2\n  a\n  b\n@@\n  a\n  b\n- t1\n+ t2"))
}

fn lines(items: List(String)) -> String {
  string.join(items, "\n") <> "\n"
}

// Lines named by their position, `prefix` deciding what each one is called.
fn named(from: Int, to: Int, prefix: fn(Int) -> String) -> List(String) {
  case from > to {
    True -> []
    False -> [
      prefix(from) <> int.to_string(from),
      ..named(from + 1, to, prefix)
    ]
  }
}

fn numbered(prefix: String, from: Int, to: Int) -> List(String) {
  named(from, to, fn(_) { prefix })
}

// Every twentieth line replaced, the rest of them untouched.
fn every_twentieth(from: Int, to: Int) -> List(String) {
  named(from, to, fn(n) {
    case n % 20 == 0 {
      True -> "B"
      False -> "a"
    }
  })
}

fn count_starting_with(rendered: Option(String), prefix: String) -> Int {
  rendered
  |> option.unwrap("")
  |> string.split("\n")
  |> list.count(fn(line) { string.starts_with(line, prefix) })
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
