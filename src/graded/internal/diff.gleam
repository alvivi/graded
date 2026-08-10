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
import gleam/result
import gleam/string

// Diffing
//
// The entry point and the line model underneath it. The trailing newline is
// part of what a write would change, so it is modelled explicitly rather than
// folded into the last line.

// Diff `old` against `new`, or `None` when the two are byte-identical.
pub fn contextual(old: String, new: String) -> Option(String) {
  use <- bool.guard(when: old == new, return: None)
  let old_side = split_side(old)
  let new_side = split_side(new)
  Some(
    diff_lines(old_side.lines, new_side.lines)
    |> split_final_keep(old_side.ending, new_side.ending)
    |> mark_endings(old_side.ending, new_side.ending)
    |> render,
  )
}

// One side of the diff: its content lines, and whether the text they came from
// ended in a newline.
type Side {
  Side(lines: List(String), ending: Ending)
}

type Ending {
  Terminated
  Unterminated
}

// Split text into content lines plus its ending. The empty string is zero
// lines; every other text keeps one content line per line of input, dropping
// only the sentinel a trailing newline splits off — `"x\n"` is the single
// content line `"x"`, and `"\n"` is a single empty content line.
fn split_side(text: String) -> Side {
  case text {
    "" -> Side(lines: [], ending: Terminated)
    _ ->
      case string.ends_with(text, "\n") {
        True ->
          Side(
            lines: string.split(string.drop_end(text, 1), "\n"),
            ending: Terminated,
          )
        False -> Side(lines: string.split(text, "\n"), ending: Unterminated)
      }
  }
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

fn keep(line: String) -> Edit {
  Keep(line:, note: NoNote)
}

fn remove(line: String) -> Edit {
  Remove(line:, note: NoNote)
}

fn add(line: String) -> Edit {
  Add(line:, note: NoNote)
}

// When only the trailing newline changed, the shared final line is still a
// change: render it as a removal followed by an addition so each side's
// marker has a line of its own to follow.
fn split_final_keep(
  edits: List(Edit),
  old_ending: Ending,
  new_ending: Ending,
) -> List(Edit) {
  use <- bool.guard(when: old_ending == new_ending, return: edits)
  case list.reverse(edits) {
    [Keep(line:, note: _), ..rest] ->
      list.reverse([add(line), remove(line), ..rest])
    [] | [Remove(..), ..] | [Add(..), ..] -> edits
  }
}

// Attach the no-newline marker to the last diff line belonging to a side that
// ends without one.
fn mark_endings(
  edits: List(Edit),
  old_ending: Ending,
  new_ending: Ending,
) -> List(Edit) {
  edits
  |> mark_side(old_ending, in_old)
  |> mark_side(new_ending, in_new)
}

fn mark_side(
  edits: List(Edit),
  ending: Ending,
  belongs: fn(Edit) -> Bool,
) -> List(Edit) {
  case ending {
    Terminated -> edits
    Unterminated -> {
      // Walking from the end, the side's last diff line is the first one the
      // walk meets that belongs to it.
      let #(tail, rest) =
        list.split_while(list.reverse(edits), fn(edit) { !belongs(edit) })
      case rest {
        [] -> edits
        [last, ..head] ->
          list.reverse(list.append(tail, [with_no_newline(last), ..head]))
      }
    }
  }
}

fn in_old(edit: Edit) -> Bool {
  case edit {
    Keep(..) | Remove(..) -> True
    Add(..) -> False
  }
}

fn in_new(edit: Edit) -> Bool {
  case edit {
    Keep(..) | Add(..) -> True
    Remove(..) -> False
  }
}

fn with_no_newline(edit: Edit) -> Edit {
  case edit {
    Keep(line:, note: _) -> Keep(line:, note: NoNewline)
    Remove(line:, note: _) -> Remove(line:, note: NoNewline)
    Add(line:, note: _) -> Add(line:, note: NoNewline)
  }
}

// Longest common subsequence
//
// Lines the two sides share stay context; everything else is a removal or an
// addition. Common leading and trailing lines are matched directly so the
// quadratic search only runs over the part that actually differs.

// The two sides indexed by position, so the search can address a line by
// index instead of walking a list.
type Grid {
  Grid(
    old: Dict(Int, String),
    new: Dict(Int, String),
    old_size: Int,
    new_size: Int,
  )
}

// Lengths of the longest common subsequence of the two suffixes, keyed by
// where each suffix starts.
type Memo =
  Dict(#(Int, Int), Int)

fn diff_lines(old: List(String), new: List(String)) -> List(Edit) {
  let #(prefix, old_rest, new_rest) = take_common_prefix(old, new, [])
  let #(suffix, old_middle, new_middle) = take_common_suffix(old_rest, new_rest)
  list.flatten([
    list.map(prefix, keep),
    middle_edits(old_middle, new_middle),
    list.map(suffix, keep),
  ])
}

fn take_common_prefix(
  old: List(String),
  new: List(String),
  acc: List(String),
) -> #(List(String), List(String), List(String)) {
  case old, new {
    [old_line, ..old_rest], [new_line, ..new_rest] if old_line == new_line ->
      take_common_prefix(old_rest, new_rest, [old_line, ..acc])
    _, _ -> #(list.reverse(acc), old, new)
  }
}

fn take_common_suffix(
  old: List(String),
  new: List(String),
) -> #(List(String), List(String), List(String)) {
  let #(suffix, old_rest, new_rest) =
    take_common_prefix(list.reverse(old), list.reverse(new), [])
  #(list.reverse(suffix), list.reverse(old_rest), list.reverse(new_rest))
}

// Diff the part left over once the shared ends are matched off.
fn middle_edits(old: List(String), new: List(String)) -> List(Edit) {
  case old, new {
    [], _ -> list.map(new, add)
    _, [] -> list.map(old, remove)
    _, _ -> {
      let grid =
        Grid(
          old: index_lines(old),
          new: index_lines(new),
          old_size: list.length(old),
          new_size: list.length(new),
        )
      let #(edits, _memo) = walk(grid, 0, 0, dict.new(), [])
      list.reverse(edits)
    }
  }
}

fn index_lines(lines: List(String)) -> Dict(Int, String) {
  list.index_fold(lines, dict.new(), fn(acc, line, index) {
    dict.insert(acc, index, line)
  })
}

// Walk both sides from the front, emitting one edit per step.
fn walk(
  grid: Grid,
  old_index: Int,
  new_index: Int,
  memo: Memo,
  acc: List(Edit),
) -> #(List(Edit), Memo) {
  case old_index < grid.old_size, new_index < grid.new_size {
    False, False -> #(acc, memo)
    False, True ->
      walk(grid, old_index, new_index + 1, memo, [
        add(line_at(grid.new, new_index)),
        ..acc
      ])
    True, False ->
      walk(grid, old_index + 1, new_index, memo, [
        remove(line_at(grid.old, old_index)),
        ..acc
      ])
    True, True -> {
      let old_line = line_at(grid.old, old_index)
      case old_line == line_at(grid.new, new_index) {
        True ->
          walk(grid, old_index + 1, new_index + 1, memo, [keep(old_line), ..acc])
        False -> walk_change(grid, old_index, new_index, memo, acc)
      }
    }
  }
}

// One step at a line the two sides disagree on: take whichever move leaves the
// longer common subsequence behind, preferring the removal on a tie so a
// replacement renders as a `-` line followed by its `+`.
fn walk_change(
  grid: Grid,
  old_index: Int,
  new_index: Int,
  memo: Memo,
  acc: List(Edit),
) -> #(List(Edit), Memo) {
  let #(without_old, memo) = lcs(grid, old_index + 1, new_index, memo)
  let #(without_new, memo) = lcs(grid, old_index, new_index + 1, memo)
  case without_old >= without_new {
    True ->
      walk(grid, old_index + 1, new_index, memo, [
        remove(line_at(grid.old, old_index)),
        ..acc
      ])
    False ->
      walk(grid, old_index, new_index + 1, memo, [
        add(line_at(grid.new, new_index)),
        ..acc
      ])
  }
}

fn lcs(grid: Grid, old_index: Int, new_index: Int, memo: Memo) -> #(Int, Memo) {
  use <- bool.guard(
    when: old_index >= grid.old_size || new_index >= grid.new_size,
    return: #(0, memo),
  )
  case dict.get(memo, #(old_index, new_index)) {
    Ok(length) -> #(length, memo)
    Error(Nil) -> {
      let #(length, memo) = compute_lcs(grid, old_index, new_index, memo)
      #(length, dict.insert(memo, #(old_index, new_index), length))
    }
  }
}

fn compute_lcs(
  grid: Grid,
  old_index: Int,
  new_index: Int,
  memo: Memo,
) -> #(Int, Memo) {
  case line_at(grid.old, old_index) == line_at(grid.new, new_index) {
    True -> {
      let #(rest, memo) = lcs(grid, old_index + 1, new_index + 1, memo)
      #(rest + 1, memo)
    }
    False -> {
      let #(without_old, memo) = lcs(grid, old_index + 1, new_index, memo)
      let #(without_new, memo) = lcs(grid, old_index, new_index + 1, memo)
      #(int.max(without_old, without_new), memo)
    }
  }
}

fn line_at(lines: Dict(Int, String), index: Int) -> String {
  dict.get(lines, index) |> result.unwrap("")
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
