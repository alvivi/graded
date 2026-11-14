// The answer census: what it reports for a root, and that two runs over the
// same roots write the same text.

import answer_census
import gleam/list
import gleam/string
import simplifile
import support

const root = "/tmp/graded_answer_census_root"

const unloadable = "/tmp/graded_answer_census_unloadable"

fn write_root() -> Nil {
  let _ =
    support.write_fixture(root, [
      #("gleam.toml", "name = \"census_root\"\n"),
      #(
        "census_root.graded",
        "effects census_root/shout.loud : [Disk]\n"
          <> "assume census_root/ffi.run : []\n"
          <> "check census_root/shout.loud : []\n",
      ),
      #(
        "src/census_root/shout.gleam",
        "import census_root/ffi\n\n"
          <> "pub fn loud() -> Nil {\n  ffi.run(fn() { Nil })\n  ffi.mystery()\n}\n\n"
          <> "pub fn quiet() -> Int {\n  1\n}\n\nfn hidden() -> Int {\n  2\n}\n",
      ),
      #(
        "src/census_root/ffi.gleam",
        support.foreign_fn("run", "(f: fn() -> Nil) -> Nil")
          <> support.foreign_fn("mystery", "() -> Nil"),
      ),
    ])
  Nil
}

// The census of one root, one entry per line.
fn census_lines(root: String) -> List(String) {
  answer_census.census([root])
  |> string.split("\n")
  |> list.filter(fn(line) { line != "" })
}

pub fn census_is_stable_across_runs_test() {
  write_root()
  let first = answer_census.census(["census=" <> root])
  let second = answer_census.census(["census=" <> root])
  support.cleanup(root)
  assert first == second
}

pub fn census_lines_are_sorted_test() {
  write_root()
  let lines = census_lines("census=" <> root)
  support.cleanup(root)
  assert lines == list.sort(lines, string.compare)
}

pub fn census_reads_answers_from_source_not_committed_lines_test() {
  write_root()
  let lines = census_lines("census=" <> root)
  support.cleanup(root)
  // The committed `[Disk]` is not what the census reports: the body's own
  // charge is, and the unresolved foreign call is attributed.
  assert list.contains(
    lines,
    "answer census census_root/shout.loud : [Unknown]",
  )
  assert list.contains(lines, "answer census census_root/shout.quiet : []")
  assert list.contains(lines, "root census public 4")
  assert list.contains(lines, "root census load ok")
  assert list.contains(
    lines,
    "unknown census census_root/shout.loud direct no-origin undeclared-external",
  )
  // The `check` line is weighed against the same fresh answer.
  assert list.any(lines, fn(line) {
    string.starts_with(
      line,
      "violation census <root>/src/census_root/shout.gleam",
    )
  })
}

pub fn census_writes_nothing_under_the_root_test() {
  write_root()
  let assert Ok(before) = simplifile.get_files(root)
  let _ = answer_census.census(["census=" <> root])
  let assert Ok(after) = simplifile.get_files(root)
  let assert Ok(spec) = simplifile.read(root <> "/census_root.graded")
  support.cleanup(root)
  assert list.sort(before, string.compare) == list.sort(after, string.compare)
  assert string.starts_with(spec, "effects census_root/shout.loud : [Disk]\n")
}

pub fn census_keeps_an_unloadable_root_in_the_count_test() {
  let _ = support.write_unparseable_spec_project(unloadable)
  let lines = census_lines("broken=" <> unloadable)
  support.cleanup(unloadable)
  assert list.contains(lines, "root broken public 1")
  assert list.contains(lines, "answer broken proj.go : unloaded")
  assert list.any(lines, string.starts_with(_, "root broken load error "))
}

const pair_root = "/tmp/graded_answer_census_pair"

// A root read on both targets whose helper defines two functions once per
// target: one prints on one target, the other calls an undeclared external on
// one target. `erlang_first` says which target each is on.
fn write_pair_root(erlang_first: Bool) -> Nil {
  let #(first, second) = case erlang_first {
    True -> #("erlang", "javascript")
    False -> #("javascript", "erlang")
  }
  let _ =
    support.write_fixture(pair_root, [
      #("gleam.toml", support.dual_target_toml("pair_root")),
      #(
        "pair_root.graded",
        "assume pair_root/ffi.shout : [Stdout]\ncheck pair_root.main_print : []\n",
      ),
      #(
        "src/pair_root.gleam",
        "import pair_root/helper\n\n"
          <> "pub fn main_print() -> Nil {\n  helper.run_print()\n}\n\n"
          <> "pub fn main_unknown() -> Nil {\n  helper.run_unknown()\n}\n",
      ),
      #(
        "src/pair_root/helper.gleam",
        "import pair_root/ffi\n\n"
          <> "@target("
          <> first
          <> ")\npub fn run_print() -> Nil {\n  ffi.shout()\n}\n\n"
          <> "@target("
          <> second
          <> ")\npub fn run_print() -> Nil {\n  Nil\n}\n\n"
          <> "@target("
          <> first
          <> ")\npub fn run_unknown() -> Nil {\n  ffi.mystery()\n}\n\n"
          <> "@target("
          <> second
          <> ")\npub fn run_unknown() -> Nil {\n  Nil\n}\n",
      ),
      #(
        "src/pair_root/ffi.gleam",
        support.foreign_fn("shout", "() -> Nil")
          <> support.foreign_fn("mystery", "() -> Nil"),
      ),
    ])
  Nil
}

// The check verdicts and unknown sources of a root read on both targets are
// those of every target, whichever the run reads last.
pub fn census_reads_every_target_of_a_two_target_root_test() {
  let read = fn(erlang_first) {
    write_pair_root(erlang_first)
    let lines = census_lines("pair=" <> pair_root)
    support.cleanup(pair_root)
    #(
      list.contains(lines, "answer pair pair_root.main_print : [Stdout]"),
      list.any(lines, fn(line) {
        string.starts_with(line, "violation pair ")
        && string.contains(line, "main_print")
      }),
      list.any(lines, string.starts_with(
        _,
        "unknown pair pair_root.main_unknown ",
      )),
    )
  }
  assert read(True) == #(True, True, True)
  assert read(False) == #(True, True, True)
}
