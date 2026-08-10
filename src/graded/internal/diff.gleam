// Line diffs between two renderings of a `.graded` file, used by
// `graded infer --dry-run` to preview what a write would change.
//
// The output is a contextual diff carrying no line numbers and no file
// headers: hunks of `- `/`+ ` lines with up to two `  `-prefixed context lines
// on each side, hunks separated by a lone `@@` line. The consumer is an agent
// reading one file's delta, and numberless hunks stay stable when unrelated
// lines move.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// Diffing
//
// The entry point and the line model underneath it. Whether a line ends in a
// newline is part of its identity, so an unterminated last line never matches
// a terminated counterpart and a trailing-newline change always surfaces as a
// removal and an addition.

// Diff `old` against `new`, or `None` when the two are byte-identical.
pub fn contextual(old: String, new: String) -> Option(String) {
  use <- bool.guard(when: old == new, return: None)
  Some(diff_lines(split_side(old), split_side(new)) |> render)
}

// One content line of a side, and whether it ends in a newline. Only a side's
// last line can be `Unterminated`.
type Line {
  Line(text: String, ending: Ending)
}

type Ending {
  Terminated
  Unterminated
}

// Split text into content lines. The empty string is zero lines; every other
// text keeps one content line per line of input, dropping only the sentinel a
// trailing newline splits off — `"x\n"` is the single content line `"x"`, and
// `"\n"` is a single empty content line.
fn split_side(text: String) -> List(Line) {
  case text, string.ends_with(text, "\n") {
    "", _ -> []
    _, True ->
      string.drop_end(text, 1) |> string.split("\n") |> list.map(terminated)
    _, False -> tag_last_unterminated(string.split(text, "\n"))
  }
}

// Mark the final line as the one the text stopped at without a newline.
fn tag_last_unterminated(lines: List(String)) -> List(Line) {
  let last_index = list.length(lines) - 1
  list.index_map(lines, fn(line, index) {
    case index == last_index {
      True -> Line(text: line, ending: Unterminated)
      False -> terminated(line)
    }
  })
}

fn terminated(text: String) -> Line {
  Line(text:, ending: Terminated)
}

// Edit script
//
// The diff as data before it is rendered: one edit per line of output, in the
// order the lines are printed.

type Edit {
  Keep(line: String, note: Note)
  Remove(line: String, note: Note)
  Add(line: String, note: Note)
}

// Whether the conventional `\ No newline at end of file` marker follows a
// diff line.
type Note {
  NoNote
  NoNewline
}

fn keep(line: Line) -> Edit {
  Keep(line: line.text, note: note_for(line))
}

fn remove(line: Line) -> Edit {
  Remove(line: line.text, note: note_for(line))
}

fn add(line: Line) -> Edit {
  Add(line: line.text, note: note_for(line))
}

// A line that ends without a newline is marked wherever it lands. A `Keep`
// carries the marker only when both sides end that way on the same line, which
// is the one case git prints a single marker after a context line.
fn note_for(line: Line) -> Note {
  case line.ending {
    Terminated -> NoNote
    Unterminated -> NoNewline
  }
}

// Longest common subsequence
//
// Lines the two sides share stay context; everything else is a removal or an
// addition. Common leading and trailing lines are matched directly so the
// quadratic search only runs over the part that actually differs.

// The two sides indexed by position, so the search can address a line by
// index instead of walking a list. Indices run from zero without gaps, so a
// lookup misses exactly when it has walked past the end of that side — which
// makes the lookup itself the bounds check.
type Grid {
  Grid(old: Dict(Int, Line), new: Dict(Int, Line))
}

// Which side a step at a disagreeing line advances.
type Move {
  DropOld
  DropNew
}

// Lengths of the longest common subsequence of the two suffixes, keyed by
// where each suffix starts.
type Memo =
  Dict(#(Int, Int), Int)

fn diff_lines(old: List(Line), new: List(Line)) -> List(Edit) {
  let #(prefix, old_rest, new_rest) = take_common_prefix(old, new, [])
  let #(suffix, old_middle, new_middle) = take_common_suffix(old_rest, new_rest)
  list.flatten([
    list.map(prefix, keep),
    middle_edits(old_middle, new_middle),
    list.map(suffix, keep),
  ])
}

fn take_common_prefix(
  old: List(Line),
  new: List(Line),
  acc: List(Line),
) -> #(List(Line), List(Line), List(Line)) {
  case old, new {
    [old_line, ..old_rest], [new_line, ..new_rest] if old_line == new_line ->
      take_common_prefix(old_rest, new_rest, [old_line, ..acc])
    _, _ -> #(list.reverse(acc), old, new)
  }
}

fn take_common_suffix(
  old: List(Line),
  new: List(Line),
) -> #(List(Line), List(Line), List(Line)) {
  let #(suffix, old_rest, new_rest) =
    take_common_prefix(list.reverse(old), list.reverse(new), [])
  #(list.reverse(suffix), list.reverse(old_rest), list.reverse(new_rest))
}

// Diff the part left over once the shared ends are matched off.
fn middle_edits(old: List(Line), new: List(Line)) -> List(Edit) {
  case old, new {
    [], _ -> list.map(new, add)
    _, [] -> list.map(old, remove)
    _, _ -> {
      let grid = Grid(old: index_lines(old), new: index_lines(new))
      let #(edits, _memo) = walk(grid, 0, 0, dict.new(), [])
      list.reverse(edits)
    }
  }
}

fn index_lines(lines: List(Line)) -> Dict(Int, Line) {
  list.index_fold(lines, dict.new(), fn(acc, line, index) {
    dict.insert(acc, index, line)
  })
}

// Walk both sides from the front, emitting one edit per step. A side whose
// lookup misses is exhausted, so the other side's remaining lines are all
// additions or all removals.
fn walk(
  grid: Grid,
  old_index: Int,
  new_index: Int,
  memo: Memo,
  acc: List(Edit),
) -> #(List(Edit), Memo) {
  case dict.get(grid.old, old_index), dict.get(grid.new, new_index) {
    Error(Nil), Error(Nil) -> #(acc, memo)
    Error(Nil), Ok(new_line) ->
      walk(grid, old_index, new_index + 1, memo, [add(new_line), ..acc])
    Ok(old_line), Error(Nil) ->
      walk(grid, old_index + 1, new_index, memo, [remove(old_line), ..acc])
    Ok(old_line), Ok(new_line) if old_line == new_line ->
      walk(grid, old_index + 1, new_index + 1, memo, [keep(old_line), ..acc])
    Ok(old_line), Ok(new_line) ->
      case better_move(grid, old_index, new_index, memo) {
        #(DropOld, memo) ->
          walk(grid, old_index + 1, new_index, memo, [remove(old_line), ..acc])
        #(DropNew, memo) ->
          walk(grid, old_index, new_index + 1, memo, [add(new_line), ..acc])
      }
  }
}

// The step to take at a line the two sides disagree on: whichever move leaves
// the longer common subsequence behind, preferring the removal on a tie so a
// replacement renders as a `-` line followed by its `+`.
fn better_move(
  grid: Grid,
  old_index: Int,
  new_index: Int,
  memo: Memo,
) -> #(Move, Memo) {
  let #(without_old, memo) = lcs(grid, old_index + 1, new_index, memo)
  let #(without_new, memo) = lcs(grid, old_index, new_index + 1, memo)
  case without_old >= without_new {
    True -> #(DropOld, memo)
    False -> #(DropNew, memo)
  }
}

fn lcs(grid: Grid, old_index: Int, new_index: Int, memo: Memo) -> #(Int, Memo) {
  case dict.get(memo, #(old_index, new_index)) {
    Ok(length) -> #(length, memo)
    Error(Nil) -> {
      let #(length, memo) = compute_lcs(grid, old_index, new_index, memo)
      #(length, dict.insert(memo, #(old_index, new_index), length))
    }
  }
}

// Past the end of either side nothing is left to share, which is what stops
// the recursion.
fn compute_lcs(
  grid: Grid,
  old_index: Int,
  new_index: Int,
  memo: Memo,
) -> #(Int, Memo) {
  case dict.get(grid.old, old_index), dict.get(grid.new, new_index) {
    Ok(old_line), Ok(new_line) if old_line == new_line -> {
      let #(rest, memo) = lcs(grid, old_index + 1, new_index + 1, memo)
      #(rest + 1, memo)
    }
    Ok(_), Ok(_) -> {
      let #(without_old, memo) = lcs(grid, old_index + 1, new_index, memo)
      let #(without_new, memo) = lcs(grid, old_index, new_index + 1, memo)
      #(int.max(without_old, without_new), memo)
    }
    _, _ -> #(0, memo)
  }
}

// Rendering
//
// Changed lines plus their surrounding context, grouped into hunks.

const context_lines = 2

fn render(edits: List(Edit)) -> String {
  edits
  |> hunks
  |> list.map(fn(hunk) { string.join(list.flat_map(hunk, render_edit), "\n") })
  |> string.join("\n@@\n")
}

fn render_edit(edit: Edit) -> List(String) {
  case edit {
    Keep(line:, note:) -> ["  " <> line, ..render_note(note)]
    Remove(line:, note:) -> ["- " <> line, ..render_note(note)]
    Add(line:, note:) -> ["+ " <> line, ..render_note(note)]
  }
}

fn render_note(note: Note) -> List(String) {
  case note {
    NoNote -> []
    NoNewline -> ["\\ No newline at end of file"]
  }
}

// Cut the edit script down to the changed lines and the context around them,
// merging stretches of context too short to separate two hunks.
//
// A no-newline marker sitting on a context line outside every window is
// dropped with that line; only a `Keep` carries one, and a `Keep` carries one
// only when both sides end without a newline on the same line, which is no
// delta to report.
fn hunks(edits: List(Edit)) -> List(List(Edit)) {
  let last_index = list.length(edits) - 1
  let ranges =
    edits
    |> list.index_map(fn(edit, index) { #(index, edit) })
    |> list.filter_map(fn(entry) {
      let #(index, edit) = entry
      case is_change(edit) {
        True ->
          Ok(#(
            int.max(0, index - context_lines),
            int.min(last_index, index + context_lines),
          ))
        False -> Error(Nil)
      }
    })
    |> merge_ranges
  list.map(ranges, fn(range) {
    let #(start, end) = range
    edits |> list.drop(start) |> list.take(end - start + 1)
  })
}

fn is_change(edit: Edit) -> Bool {
  case edit {
    Keep(..) -> False
    Remove(..) | Add(..) -> True
  }
}

// Fold ascending ranges into the fewest that cover them, joining any two that
// overlap or sit next to each other.
fn merge_ranges(ranges: List(#(Int, Int))) -> List(#(Int, Int)) {
  ranges
  |> list.fold([], fn(acc, range) {
    let #(start, end) = range
    case acc {
      [] -> [range]
      [#(previous_start, previous_end), ..rest] ->
        case start <= previous_end + 1 {
          True -> [#(previous_start, int.max(previous_end, end)), ..rest]
          False -> [range, ..acc]
        }
    }
  })
  |> list.reverse
}
