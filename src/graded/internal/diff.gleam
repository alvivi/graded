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
import gleam/set
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

// Alignment
//
// Which lines the two sides share. Common leading and trailing lines are
// matched off directly, lines occurring exactly once on each side pin the rest
// of the two sides together, and the quadratic search runs only on the gaps
// between those pins.

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

// Diff the part left over once the shared ends are matched off. Anchors are
// context wherever they are found, and the gaps they leave are diffed apart
// from one another; finding none leaves the whole middle as one gap.
fn middle_edits(old: List(Line), new: List(Line)) -> List(Edit) {
  stitch(old, new, anchors(old, new), 0, 0, [])
}

// Emit each gap, the anchor that closes it, and finally the gap past the last
// anchor. The two indices say how far into each side the walk has come, so an
// anchor's recorded position gives the length of the gap before it.
fn stitch(
  old: List(Line),
  new: List(Line),
  anchors: List(Anchor),
  old_index: Int,
  new_index: Int,
  acc: List(List(Edit)),
) -> List(Edit) {
  case anchors {
    [] -> list.flatten(list.reverse([gap_edits(old, new), ..acc]))
    [anchor, ..rest] -> {
      let #(old_gap, old_rest) = list.split(old, anchor.old_index - old_index)
      let #(new_gap, new_rest) = list.split(new, anchor.new_index - new_index)
      stitch(
        list.drop(old_rest, 1),
        list.drop(new_rest, 1),
        rest,
        anchor.old_index + 1,
        anchor.new_index + 1,
        [[keep(anchor.line)], gap_edits(old_gap, new_gap), ..acc],
      )
    }
  }
}

// Diff one gap. Two sides sharing no line at all have an empty longest common
// subsequence, so every step of the search ties and `better_move` takes the
// removal — every removal and then every addition, which is what this emits
// without filling a rectangle to reach it.
fn gap_edits(old: List(Line), new: List(Line)) -> List(Edit) {
  use <- bool.lazy_guard(when: shares_a_line(old, new), return: fn() {
    searched_edits(old, new)
  })
  list.append(list.map(old, remove), list.map(new, add))
}

fn shares_a_line(old: List(Line), new: List(Line)) -> Bool {
  let old_lines = set.from_list(old)
  list.any(new, set.contains(old_lines, _))
}

// Anchors
//
// A line occurring exactly once on each side pins those two positions
// together. Not every such line can be kept: two of them cross when one sits
// earlier than the other on the old side and later on the new, and keeping
// both would align the sides two ways at once. The anchors are the longest run
// of candidates that does not cross.

// A line occurring exactly once on each side, and where it sits on both.
type Anchor {
  Anchor(old_index: Int, new_index: Int, line: Line)
}

fn anchors(old: List(Line), new: List(Line)) -> List(Anchor) {
  candidates(old, new) |> longest_run
}

// Every line unique to one occurrence on both sides, in old-side order.
fn candidates(old: List(Line), new: List(Line)) -> List(Anchor) {
  let old_occurrences = occurrences(old)
  let new_occurrences = occurrences(new)
  old
  |> list.index_fold([], fn(acc, line, index) {
    case single_position(new_occurrences, line) {
      Error(Nil) -> acc
      Ok(new_index) ->
        case single_position(old_occurrences, line) {
          Error(Nil) -> acc
          Ok(_) -> [Anchor(old_index: index, new_index:, line:), ..acc]
        }
    }
  })
  |> list.reverse
}

// How often a line occurs on one side, and where it sits when that is once.
type Occurrence {
  Once(index: Int)
  Repeated
}

// How often each line occurs on one side. A line occurring more than once
// pins nothing: which of its occurrences matches which is the question the
// search exists to answer.
fn occurrences(lines: List(Line)) -> Dict(Line, Occurrence) {
  list.index_fold(lines, dict.new(), fn(acc, line, index) {
    case dict.get(acc, line) {
      Error(Nil) -> dict.insert(acc, line, Once(index))
      Ok(_) -> dict.insert(acc, line, Repeated)
    }
  })
}

fn single_position(
  occurrences: Dict(Line, Occurrence),
  line: Line,
) -> Result(Int, Nil) {
  case dict.get(occurrences, line) {
    Ok(Once(index)) -> Ok(index)
    Ok(Repeated) -> Error(Nil)
    Error(Nil) -> Error(Nil)
  }
}

// The piles of a patience sort: the candidate topping each pile, keyed by pile
// index, and the candidate preceding a given one in the run being built, keyed
// by old-side position. How many piles are open is `dict.size(tops)`, since a
// candidate either tops a pile that exists or opens the next one.
type Piles {
  Piles(tops: Dict(Int, Anchor), predecessors: Dict(Int, Anchor))
}

// The longest run of candidates whose new-side positions strictly ascend, over
// candidates already in old-side order.
//
// Patience sorting: each candidate lands on the leftmost pile whose top sits at
// or past its new-side position, opening a pile when every top sits before it,
// and records the top of the pile to its left as its predecessor. The run is
// the chain of predecessors back from the top of the last pile. Those two rules
// settle which run is chosen when several are equally long, so the alignment is
// the same on every run.
//
// The piles live in a dict rather than an array, since the standard library
// ships no indexed sequence, so each probe of the binary search costs a lookup.
fn longest_run(candidates: List(Anchor)) -> List(Anchor) {
  let piles =
    list.fold(
      candidates,
      Piles(tops: dict.new(), predecessors: dict.new()),
      place,
    )
  let last = dict.get(piles.tops, dict.size(piles.tops) - 1)
  chase(piles.predecessors, last, [])
}

fn place(piles: Piles, candidate: Anchor) -> Piles {
  let open = dict.size(piles.tops)
  case dict.get(piles.tops, open - 1) {
    Error(Nil) -> stack(piles, candidate, 0, Error(Nil))
    Ok(last) ->
      case last.new_index < candidate.new_index {
        // Tops ascend left to right, so a candidate past the last of them opens
        // the next pile and follows that same top — one lookup, no search. A
        // file whose changes are scattered takes this path for every candidate,
        // since the unchanged lines between them already ascend.
        True -> stack(piles, candidate, open, Ok(last))
        False -> {
          let index = leftmost_pile(piles.tops, candidate.new_index, 0, open)
          stack(piles, candidate, index, dict.get(piles.tops, index - 1))
        }
      }
  }
}

// Put the candidate on top of pile `index`, recording `previous` — the top of
// the pile to its left — as the candidate it follows in the run.
fn stack(
  piles: Piles,
  candidate: Anchor,
  index: Int,
  previous: Result(Anchor, Nil),
) -> Piles {
  Piles(
    tops: dict.insert(piles.tops, index, candidate),
    predecessors: case previous {
      Ok(previous) ->
        dict.insert(piles.predecessors, candidate.old_index, previous)
      Error(Nil) -> piles.predecessors
    },
  )
}

// The leftmost pile whose top sits at or past `position`, or the pile after the
// last one when every top sits before it. A pile below the count always has a
// top, so a missing one can only mean the search has run past them.
fn leftmost_pile(
  tops: Dict(Int, Anchor),
  position: Int,
  low: Int,
  high: Int,
) -> Int {
  use <- bool.guard(when: low >= high, return: low)
  let middle = { low + high } / 2
  case dict.get(tops, middle) {
    Ok(top) ->
      case top.new_index >= position {
        True -> leftmost_pile(tops, position, low, middle)
        False -> leftmost_pile(tops, position, middle + 1, high)
      }
    Error(Nil) -> leftmost_pile(tops, position, middle + 1, high)
  }
}

// Follow predecessors back from the last pile's top, which lands the run in
// ascending order on both sides.
fn chase(
  predecessors: Dict(Int, Anchor),
  anchor: Result(Anchor, Nil),
  acc: List(Anchor),
) -> List(Anchor) {
  case anchor {
    Error(Nil) -> acc
    Ok(anchor) ->
      chase(predecessors, dict.get(predecessors, anchor.old_index), [
        anchor,
        ..acc
      ])
  }
}

// Longest common subsequence
//
// The search over one gap: the step taken at a disagreement is the one leaving
// the longer common subsequence behind. Scoring a step fills a rectangle the
// size of the gap, which is what the anchors above exist to keep small.

// The two sides of a gap indexed by position, so the search can address a line
// by index instead of walking a list. Indices run from zero without gaps, so a
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

fn searched_edits(old: List(Line), new: List(Line)) -> List(Edit) {
  let grid = Grid(old: index_lines(old), new: index_lines(new))
  let #(edits, _memo) = walk(grid, 0, 0, dict.new(), [])
  list.reverse(edits)
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
