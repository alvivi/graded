// Tests for the `infer` command's arguments and its two modes: the decoder
// that separates `--dry-run` from the directory, and end-to-end runs of both
// modes over throwaway projects — including the requirement dry-run exists
// for, that a preview writes nothing at all.

import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import graded
import graded/internal/annotation
import graded/internal/cli
import graded/internal/diff
import simplifile
import support

// Argument decoding
//
// `--dry-run` selects a mode rather than filling a position, so it is accepted
// wherever it sits and the directory keeps its usual default.

pub fn infer_args_default_to_writing_src_test() {
  cli.parse_infer_args([]) |> should.equal(Ok(#("src", cli.Write)))
}

pub fn infer_args_directory_only_test() {
  cli.parse_infer_args(["lib"]) |> should.equal(Ok(#("lib", cli.Write)))
}

pub fn infer_args_dry_run_alone_test() {
  cli.parse_infer_args(["--dry-run"]) |> should.equal(Ok(#("src", cli.DryRun)))
}

pub fn infer_args_dry_run_before_directory_test() {
  cli.parse_infer_args(["--dry-run", "lib"])
  |> should.equal(Ok(#("lib", cli.DryRun)))
}

pub fn infer_args_dry_run_after_directory_test() {
  cli.parse_infer_args(["lib", "--dry-run"])
  |> should.equal(Ok(#("lib", cli.DryRun)))
}

pub fn infer_args_repeated_dry_run_test() {
  cli.parse_infer_args(["--dry-run", "lib", "--dry-run"])
  |> should.equal(Ok(#("lib", cli.DryRun)))
}

pub fn infer_args_reject_unknown_option_test() {
  cli.parse_infer_args(["--dry-runx"])
  |> should.equal(Error(cli.UnknownOption("--dry-runx")))
}

pub fn infer_args_reject_extra_argument_test() {
  cli.parse_infer_args(["lib", "extra"])
  |> should.equal(Error(cli.UnexpectedArgument("extra")))
}

pub fn infer_args_reject_extra_argument_beside_dry_run_test() {
  cli.parse_infer_args(["--dry-run", "lib", "extra"])
  |> should.equal(Error(cli.UnexpectedArgument("extra")))
}

// Previewing
//
// `run_infer_command(cli.DryRun, …)` — the seam `main` dispatches to — over
// projects at each of the states a preview has to describe: no spec file yet,
// a spec file that already matches, one holding a stale line, one gaining a
// line after its unterminated last one, and one the parser rejects.

pub fn dry_run_writes_nothing_test() {
  let root = "build/infer_dry_run_fresh"
  write_project(root, source(), NoSpec)
  let assert Ok(preview) = graded.run_infer_command(cli.DryRun, root)

  // Nothing on disk yet, so every changed line is an addition.
  let changes = changed_lines(preview)
  changes |> should.not_equal([])
  changes |> list.all(string.starts_with(_, "+ ")) |> should.be_true()

  simplifile.is_file(root <> "/proj.graded") |> should.equal(Ok(False))
  simplifile.is_directory(root <> "/build/.graded") |> should.equal(Ok(False))
  support.cleanup(root)
}

pub fn dry_run_after_infer_reports_no_changes_test() {
  let root = "build/infer_dry_run_unchanged"
  write_project(root, source(), Spec(spec()))
  let assert Ok(_) = graded.run_infer(root)
  let assert Ok(written) = simplifile.read(root <> "/proj.graded")

  graded.run_infer_command(cli.DryRun, root)
  |> should.equal(Ok("graded: no changes"))
  simplifile.read(root <> "/proj.graded") |> should.equal(Ok(written))
  support.cleanup(root)
}

pub fn dry_run_shows_only_the_stale_line_test() {
  let root = "build/infer_dry_run_stale"
  write_project(root, source(), Spec(spec()))
  let assert Ok(_) = graded.run_infer(root)
  let assert Ok(written) = simplifile.read(root <> "/proj.graded")
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/proj.graded",
      string.replace(
        written,
        "effects proj.greet : [Stdout]",
        "effects proj.greet : [Db]",
      ),
    )

  let assert Ok(preview) = graded.run_infer_command(cli.DryRun, root)
  changed_lines(preview)
  |> should.equal([
    "- effects proj.greet : [Db]", "+ effects proj.greet : [Stdout]",
  ])
  support.cleanup(root)
}

// A spec file is written without a trailing newline, so a public function
// added afterwards leaves the formerly-last line terminated on the new side
// only: it is previewed as a `-`/`+` pair carrying the marker on the `-` side.
pub fn dry_run_repairs_the_formerly_last_line_test() {
  let root = "build/infer_dry_run_append"
  write_project(root, source(), Spec(spec()))
  let assert Ok(_) = graded.run_infer(root)
  let assert Ok(written) = simplifile.read(root <> "/proj.graded")
  let assert Ok(last) = written |> string.split("\n") |> list.last
  let assert Ok(Nil) =
    simplifile.write(root <> "/proj.gleam", source_with_added_function())

  let assert Ok(preview) = graded.run_infer_command(cli.DryRun, root)
  last_lines(preview, 5)
  |> should.equal([
    "- " <> last,
    "\\ No newline at end of file",
    "+ " <> last,
    "+ effects proj.shout : [Stdout]",
    "\\ No newline at end of file",
  ])
  support.cleanup(root)
}

// A spec file the parser rejects stops the run, naming the line, rather than
// merging as if it held no lines and previewing a write that would clobber it.
pub fn dry_run_over_an_unparseable_spec_errors_test() {
  let root = "build/infer_dry_run_unparseable"
  let existing = spec() <> "this line is not a graded annotation\n"
  write_project(root, source(), Spec(existing))

  graded.run_infer_command(cli.DryRun, root)
  |> should.equal(
    Error(graded.GradedParseError(
      root <> "/proj.graded",
      annotation.InvalidLine(2, "this line is not a graded annotation"),
    )),
  )
  simplifile.read(root <> "/proj.graded") |> should.equal(Ok(existing))
  support.cleanup(root)
}

// A spec file that is there but cannot be read is not the same as no spec
// file at all: previewing against empty bytes would hide the existing lines
// and promise a write that would fail, so the read error surfaces instead.
pub fn dry_run_over_an_unreadable_spec_errors_test() {
  let root = "build/infer_dry_run_unreadable"
  write_project(root, source(), NoSpec)
  let assert Ok(Nil) = simplifile.create_directory(root <> "/proj.graded")

  graded.run_infer_command(cli.DryRun, root)
  |> should.equal(
    Error(graded.FileReadError(root <> "/proj.graded", simplifile.Eisdir)),
  )
  support.cleanup(root)
}

// The preview is exactly the diff the write turns out to produce: capture one,
// perform the write, and diff the bytes before against the bytes after.
pub fn dry_run_predicts_the_write_test() {
  let root = "build/infer_dry_run_prediction"
  write_project(root, source(), Spec(spec()))
  let assert Ok(before) = simplifile.read(root <> "/proj.graded")

  let assert Ok(preview) = graded.run_infer_command(cli.DryRun, root)
  let assert Ok(_) = graded.run_infer(root)
  let assert Ok(after) = simplifile.read(root <> "/proj.graded")

  diff.contextual(before, after) |> should.equal(Some(preview))
  support.cleanup(root)
}

// Writing
//
// The other half of the mode switch: `cli.Write` still writes both outputs and
// reports what it did.

pub fn write_mode_writes_the_spec_and_cache_test() {
  let root = "build/infer_write_mode"
  write_project(root, source(), NoSpec)

  graded.run_infer_command(cli.Write, root)
  |> should.equal(Ok("graded: inferred effects written"))
  simplifile.is_file(root <> "/proj.graded") |> should.equal(Ok(True))
  simplifile.is_file(root <> "/build/.graded/proj.graded")
  |> should.equal(Ok(True))
  support.cleanup(root)
}

// A project with no spec file starts from no lines at all, not from the single
// blank line an empty file parses to.
pub fn write_mode_starts_a_spec_without_a_leading_blank_line_test() {
  let root = "build/infer_write_fresh_spec"
  write_project(root, source(), NoSpec)

  let assert Ok(_) = graded.run_infer_command(cli.Write, root)
  let assert Ok(written) = simplifile.read(root <> "/proj.graded")
  string.starts_with(written, "\n") |> should.be_false()
  support.cleanup(root)
}

// Fixture projects
//
// A one-module project whose effects come from a declared external, so the
// inferred lines don't depend on dependency sources being installed.

type SpecFile {
  NoSpec
  Spec(contents: String)
}

fn write_project(root: String, module: String, spec_file: SpecFile) -> Nil {
  let spec_entry = case spec_file {
    NoSpec -> []
    Spec(contents:) -> [#("proj.graded", contents)]
  }
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.gleam", module),
    ..spec_entry
  ])
  Nil
}

fn source() -> String {
  "import ffi/console

pub fn greet() -> Nil {
  console.log(\"hi\")
}

pub fn quiet() -> Nil {
  Nil
}
"
}

// The same module with one more public function, as it looks after a spec has
// already been written for the original.
fn source_with_added_function() -> String {
  source() <> "
pub fn shout() -> Nil {
  console.log(\"HI\")
}
"
}

fn spec() -> String {
  "external effects ffi/console.log : [Stdout]\n"
}

// The final `count` lines of a preview, markers included.
fn last_lines(preview: String, count: Int) -> List(String) {
  let lines = string.split(preview, "\n")
  list.drop(lines, list.length(lines) - count)
}

// The `-`/`+` lines of a preview, dropping the context around them.
fn changed_lines(preview: String) -> List(String) {
  preview
  |> string.split("\n")
  |> list.filter(fn(line) {
    string.starts_with(line, "- ") || string.starts_with(line, "+ ")
  })
}

// Foreign producers and the spec `infer` writes
//
// A `returns` line describes the operator a producer hands back. For an
// `@external` no such line can be true — only the foreign implementation
// decides what it returns — so `infer` writes none, and removes one a function
// that has since become `@external` left behind.

pub fn infer_writes_no_returns_line_for_an_external_test() {
  let root = "build/infer_external_returns"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.gleam",
      "@target(erlang)
@external(erlang, \"proj_ffi\", \"make\")
pub fn make() -> fn() -> Nil {
  fn() { Nil }
}

pub fn native_make() -> fn() -> Nil {
  fn() { Nil }
}
",
    ),
  ])
  let assert Ok(_) = graded.run_infer(root)
  let assert Ok(written) = simplifile.read(root <> "/proj.graded")

  string.contains(written, "returns proj.make") |> should.be_false()
  // The ordinary producer beside it still gets one, so what is refused is the
  // foreign half rather than the channel.
  string.contains(written, "returns proj.native_make") |> should.be_true()
  support.cleanup(root)
}

pub fn infer_removes_a_returns_line_a_new_external_left_behind_test() {
  let root = "build/infer_external_returns_stale"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "returns proj.make : []\n"),
    #(
      "proj.gleam",
      "@target(erlang)
@external(erlang, \"proj_ffi\", \"make\")
pub fn make() -> fn() -> Nil {
  fn() { Nil }
}
",
    ),
  ])
  let assert Ok(preview) = graded.run_infer_command(cli.DryRun, root)
  changed_lines(preview)
  |> list.contains("- returns proj.make : []")
  |> should.be_true()
  support.cleanup(root)
}

// A write mode refuses the same spec the preview refuses, and leaves the file
// exactly as it was rather than merging into an empty file.
pub fn infer_over_an_unparseable_spec_writes_nothing_test() {
  let root = "build/infer_unparseable"
  let _ = support.write_unparseable_spec_project(root)
  let assert Ok(before) = simplifile.read(root <> "/proj.graded")

  graded.run_infer(root)
  |> should.equal(
    Error(graded.GradedParseError(
      root <> "/proj.graded",
      annotation.InvalidLine(2, "not a graded line"),
    )),
  )
  simplifile.read(root <> "/proj.graded") |> should.equal(Ok(before))
  support.cleanup(root)
}
