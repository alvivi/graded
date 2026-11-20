// What a directory argument reads, by spelling and cwd, through the CLI.

import gleam/list
import gleeunit/should
import shellout
import simplifile
import support

const root = "build/directory_cli"

// The compiled CLI run from `cwd`: its exit status and output, stderr merged.
fn graded(cwd: String, arguments: List(String)) -> #(Int, String) {
  let assert Ok(repo) = simplifile.current_directory()
  let assert Ok(packages) = simplifile.read_directory("build/dev/erlang")
  let ebin =
    list.map(packages, fn(p) { repo <> "/build/dev/erlang/" <> p <> "/ebin" })
  let run = ["-noshell", "-eval", "graded:main(), erlang:halt(0)", "-extra"]
  let command = list.flatten([["-pa", ..ebin], run, arguments])
  case shellout.command(run: "erl", with: command, in: cwd, opt: []) {
    Ok(output) -> #(0, output)
    Error(failure) -> failure
  }
}

fn violation(file: String, call: String) -> #(Int, String) {
  #(1, file <> ": main calls " <> call <> loud)
}

const loud =
  " with effects [Stdout] (from your spec's `assume` line) but declared []\n\ngraded: 1 violation(s) found\n"

const passed = #(0, "graded: all checks passed\n")

fn error(message: String) -> #(Int, String) {
  #(1, "graded: error: " <> message <> "\n")
}

fn tarball(path: String) -> #(Int, String) {
  let read = "could not read " <> path
  let hex = " as a hex tarball: {\"" <> path <> "\",enoent}"
  error(read <> " (run `gleam export hex-tarball` first): " <> read <> hex)
}

fn toml(name: String, version: String) -> String {
  "name = \"" <> name <> "\"\nversion = \"" <> version <> "\"\n"
}

const go = "pub fn go() -> Nil { Nil }\n"

const loud_module =
  "@external(erlang, \"f\", \"l\")\npub fn loud() -> Nil\npub fn main() { loud() }\n"

pub fn spellings_from_the_package_root_and_beside_it_test() {
  let proj =
    support.write_fixture(root <> "/r1/app", [
      #("gleam.toml", toml("proj", "1.0.0")),
      #("proj.graded", "assume sub/x.loud : [Stdout]\ncheck sub/x.main : []\n"),
      #("src/sub/x.gleam", loud_module),
      #("extra/extra.graded", "assume y.loud : [Stdout]\ncheck y.main : []\n"),
      #("extra/y.gleam", loud_module),
    ])
  let assert Ok(_) = simplifile.create_directory_all(root <> "/r1/side")
  let assert Ok(cwd) = simplifile.current_directory()
  let absolute = cwd <> "/" <> proj
  // Regressions: a trailing slash after `..`, and an absolute `extra`.
  graded(root <> "/r1/side", ["check", "../app/src/"])
  |> should.equal(violation("../app/src/sub/x.gleam", "sub/x.loud"))
  graded(proj, ["check", absolute <> "/extra"])
  |> should.equal(violation(absolute <> "/extra/y.gleam", "y.loud"))
  // Controls: a relative `extra`, an absolute `src/`, and from inside `src/`.
  graded(proj, ["check", "extra"])
  |> should.equal(violation("extra/y.gleam", "y.loud"))
  graded(proj, ["check", absolute <> "/src"])
  |> should.equal(violation(absolute <> "/src/sub/x.gleam", "sub/x.loud"))
  graded(proj <> "/src", ["check", "sub"]) |> should.equal(passed)
  graded(proj <> "/src", ["check", "."]) |> should.equal(passed)
  // A regression: `format` on a `src/` subtree formatted `src/sub/sub.graded`.
  graded(proj, ["format", "--check", "src/sub"])
  |> should.equal(error("Unformatted .graded files:\n  proj.graded"))
  graded(proj, ["format", "src/sub"]) |> should.equal(#(0, ""))
  simplifile.read(proj <> "/proj.graded")
  |> should.equal(Ok("assume sub/x.loud : [Stdout]\n\ncheck sub/x.main : []\n"))
  simplifile.is_file(proj <> "/src/sub/sub.graded") |> should.equal(Ok(False))
  support.cleanup(root <> "/r1")
}

pub fn a_climb_out_of_a_decoy_package_reads_the_package_above_test() {
  let walk =
    support.write_fixture(root <> "/walk", [
      #("gleam.toml", toml("walk", "1.0.0")),
      #("walk.graded", "check a/sub/caller.go : []\ncheck a/other.go : []\n"),
      #(
        "src/a/sub/caller.gleam",
        "import a/other\npub fn go() { other.go() }\n",
      ),
      #("src/a/other.gleam", "import depx\npub fn go() { depx.go() }\n"),
      #("build/packages/depx/depx.graded", "effects depx.go : [Disk]\n"),
      #("build/packages/depx/gleam.toml", toml("depx", "1.0.0")),
      #("build/packages/depx/src/depx.gleam", go),
      #("src/a/runner/gleam.toml", toml("decoy", "2.0.0")),
      #("src/a/runner/decoy.graded", "effects decoy.go : []\n"),
    ])
  let runner = walk <> "/src/a/runner"
  // Regressions: the whole package analysed, the subtree alone reported, and
  // `pack` naming the package's tarball.
  graded(runner, ["check", "../sub"])
  |> should.equal(#(
    1,
    "../../../src/a/sub/caller.gleam: go calls a/other.go with effects [Disk] (from in-memory inference) but declared []\n\ngraded: 1 violation(s) found\n",
  ))
  ["../sub", "../runner/../sub", "../sub/"]
  |> list.each(fn(spelling) {
    graded(runner, ["pack", spelling])
    |> should.equal(tarball("../../../build/walk-1.0.0.tar"))
  })
  // A regression: the argument is read before it is normalized.
  graded(runner, ["pack", "../missing/../sub"])
  |> should.equal(error("Could not read directory: ../missing/../sub"))
  // A control: a spelling not starting with `..` walks as it is written.
  graded(runner, ["pack", "./../runner/../sub"])
  |> should.equal(tarball("./../runner/build/decoy-2.0.0.tar"))
  support.cleanup(walk)
}

pub fn pack_walks_any_other_spelling_as_it_is_written_test() {
  // Controls: a complete package at `src/`, and a walk through `spare/..`.
  let outer =
    support.write_fixture(root <> "/pack", [
      #("gleam.toml", toml("outer", "1.0.0")),
      #("outer.graded", "effects outer.go : []\n"),
      #("src/gleam.toml", toml("inner", "2.0.0")),
      #("src/inner.graded", "effects inner.go : []\n"),
      #("cwd/spare/gleam.toml", toml("spare", "1.0.0")),
      #("cwd/spare/spare.graded", "effects spare.go : []\n"),
      #("cwd/local/local.gleam", go),
    ])
  graded(outer, ["pack", "./src"])
  |> should.equal(tarball("./src/build/inner-2.0.0.tar"))
  graded(outer, ["pack", "src"])
  |> should.equal(tarball("./build/outer-1.0.0.tar"))
  graded(outer <> "/cwd", ["pack", "spare/../local"])
  |> should.equal(tarball("spare/build/spare-1.0.0.tar"))
  support.cleanup(outer)
}

pub fn infer_on_a_folder_writes_its_own_spec_test() {
  // A control: an outer package's spec configured into the folder is kept.
  let configured = "check amod.go : []\neffects amod.go : []\n"
  let spec_file = "spec_file = \"vendor/inner/extra/graded.graded\"\n"
  let outer =
    support.write_fixture(root <> "/destination", [
      #("gleam.toml", toml("outer", "1.0.0") <> "[tools.graded]\n" <> spec_file),
      #("src/amod.gleam", go),
      #("vendor/inner/gleam.toml", toml("inner", "1.0.0")),
      #("vendor/inner/inner.graded", "effects pmod.go : []\n"),
      #("vendor/inner/src/pmod.gleam", go),
      #("vendor/inner/extra/fixture.gleam", go),
      #("vendor/inner/extra/graded.graded", configured),
    ])
  let inner = outer <> "/vendor/inner"
  graded(inner, ["infer", "--check", "extra"])
  |> should.equal(error(
    "Stale spec file extra/extra.graded; run `graded infer` to update it:\n+ effects fixture.go : []\n\\ No newline at end of file",
  ))
  graded(inner, ["infer", "extra"])
  |> should.equal(#(0, "graded: inferred effects written\n"))
  simplifile.is_file(inner <> "/extra/extra.graded") |> should.equal(Ok(True))
  simplifile.read(inner <> "/extra/graded.graded")
  |> should.equal(Ok(configured))
  support.cleanup(outer)
}

pub fn a_directory_the_os_does_not_read_is_an_error_test() {
  let no_src =
    support.write_fixture(root <> "/no_src", [
      #("gleam.toml", toml("no_src", "1.0.0")),
      #("no_src.graded", "assume m.f : [Time]\ncheck m.go : []\n"),
      #("m.gleam", go),
    ])
  // A regression: `pack` walked on to the package's tarball.
  graded(no_src, ["pack", "src/typo"])
  |> should.equal(error("Could not read directory: src/typo"))
  // Controls: `catalog`, a bare non-directory word, and a no-argument `format`.
  graded(no_src, ["catalog", "gleam_stdlib", "src/typo"])
  |> should.equal(error("Could not read directory: src/typo"))
  let usage = "\nRun `graded --help` for usage."
  graded(no_src, ["missing/../src"])
  |> should.equal(error("unknown command `missing/../src`" <> usage))
  graded(no_src, ["format", "--check"])
  |> should.equal(error("Unformatted .graded files:\n  no_src.graded"))
  support.cleanup(no_src)
}
