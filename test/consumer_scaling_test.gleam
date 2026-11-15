// One value of a large recursive family handed to each kind of consumer
// thousands of times: a callback runner, a field call, a foreign function whose
// line has no bounds, a catalog function a review covered, and a written line
// with `runs`, `relay` and `carries`. Every callee's callback is spelled through
// a deep alias chain over the family, and the foreign functions return an
// external container. One more case reads one large value from functions that
// alternate between targets. What a callee's parameters are, what its line
// says and what a type can hold are read once for the run, so every case's
// inference runs inside a bound on its reductions, with its answer. Every case
// is a program the compiler accepts.
//
//   gleam run -m consumer_scaling_test -- [DIR]
//
// writes every case as a project under DIR (default `build/consumer_scaling`),
// to measure it from outside.

import argv
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleeunit/should
import graded
import shellout
import simplifile
import support

const work_bound = 90_000_000

const uses = 2048

@external(erlang, "scope_test_ffi", "reductions")
fn reductions() -> Int

// A case: its name, `main`'s module (importing `probe/ffi` and `probe/model`),
// the function whose inferred effects are checked, and its answer.
type Case {
  Case(name: String, main: String, function: String, answer: String)
}

const family_size = 32

const arity = 32

const alias_depth = 49

fn from(first: Int, until: Int) -> List(Int) {
  case first >= until {
    True -> []
    False -> [first, ..from(first + 1, until)]
  }
}

fn parameters() -> String {
  from(0, arity)
  |> list.map(fn(i) { "a" <> int.to_string(i) })
  |> string.join(", ")
}

fn ints() -> String {
  string.join(list.repeat("Int", arity), ", ")
}

// `family_size` mutually recursive types of `arity` parameters, each passing
// its parameters on rotated to the next and holding its first; the callback
// type `Act0` over the first and an alias chain over it; and a record whose
// field is the end of that chain.
fn model_source() -> String {
  let parameters = parameters()
  let rotated =
    from(1, arity + 1)
    |> list.map(fn(i) { "a" <> int.to_string(i % arity) })
    |> string.join(", ")
  let family =
    list.map(from(0, family_size), fn(i) {
      let index = int.to_string(i)
      let next = int.to_string({ i + 1 } % family_size)
      "pub type T"
      <> index
      <> "("
      <> parameters
      <> ") {\n  Next"
      <> index
      <> "(T"
      <> next
      <> "("
      <> rotated
      <> "))\n  End"
      <> index
      <> "(a0)\n}\n\n"
    })
  let chain =
    list.map(from(1, alias_depth), fn(i) {
      "pub type Act"
      <> int.to_string(i)
      <> "("
      <> parameters
      <> ") =\n  Act"
      <> int.to_string(i - 1)
      <> "("
      <> parameters
      <> ")\n\n"
    })
  string.concat(family)
  <> "pub type Act0("
  <> parameters
  <> ") =\n  fn(T0("
  <> parameters
  <> ")) -> T0("
  <> parameters
  <> ")\n\n"
  <> string.concat(chain)
  <> "pub type Feeder {\n  Feeder(run: "
  <> last_act()
  <> ")\n}\n\npub fn make() -> T0("
  <> ints()
  <> ") {\n  End0(0)\n}\n"
}

fn last_act() -> String {
  "Act" <> int.to_string(alias_depth - 1) <> "(" <> ints() <> ")"
}

fn ffi_source() -> String {
  let root = "model.T0(" <> ints() <> ")"
  let act = "model." <> last_act()
  "import probe/model

pub type Carrier(a)

@external(erlang, \"m\", \"sink\")
@external(javascript, \"../m.mjs\", \"sink\")
pub fn sink(x: a) -> Nil

@external(erlang, \"m\", \"identity\")
@external(javascript, \"../m.mjs\", \"identity\")
pub fn identity(x: " <> root <> ") -> " <> root <> "

@external(erlang, \"m\", \"each\")
@external(javascript, \"../m.mjs\", \"each\")
pub fn each(xs: List(" <> root <> "), f: " <> act <> ") -> Nil

@external(erlang, \"m\", \"keep\")
@external(javascript, \"../m.mjs\", \"keep\")
pub fn keep(xs: List(" <> root <> "), f: " <> act <> ") -> Carrier(" <> root <> ")

@external(erlang, \"m\", \"hold\")
@external(javascript, \"../m.mjs\", \"hold\")
pub fn hold(x: " <> root <> ", f: " <> act <> ") -> Carrier(" <> root <> ")
"
}

const spec =
  "assume probe/ffi.sink : []
assume probe/ffi.identity : []
assume probe/ffi.hold : []
assume probe/ffi.each(xs: [x], f: [f]) : [f] where runs : [], relay : f(x)
assume probe/ffi.keep(xs: [x], f: [f]) : [f]
  where runs : [x], relay : f(x), carries : [x, f.returns]
"

fn consumer(name: String, prelude: String, line: String) -> Case {
  Case(
    name:,
    main: "import gleam/list\nimport probe/ffi\nimport probe/model\n\npub fn main() -> Nil {\n"
      <> prelude
      <> string.repeat(line, uses)
      <> "  Nil\n}\n\npub fn unused() -> List(Int) {\n  list.new()\n}\n",
    function: "main",
    answer: "[]",
  )
}

// Doubled tuples this many levels deep in the helper the alternating functions
// call.
const levels = 16

const alternating = 1024

fn alternating_case() -> Case {
  let tuples =
    list.map(from(1, levels + 1), fn(i) {
      "  let t"
      <> int.to_string(i)
      <> " = #(t"
      <> int.to_string(i - 1)
      <> ", t"
      <> int.to_string(i - 1)
      <> ")\n"
    })
  let callers =
    list.map(from(0, alternating), fn(i) {
      let target = case i % 2 {
        0 -> "erlang"
        _ -> "javascript"
      }
      "@target("
      <> target
      <> ")\npub fn run_"
      <> int.to_string(i)
      <> "() -> Nil {\n  helper()\n}\n\n"
    })
  Case(
    name: "one value read from functions alternating targets",
    main: "import probe/ffi\n\nfn helper() -> Nil {\n  let t0 = 0\n"
      <> string.concat(tuples)
      <> "  ffi.sink(t"
      <> int.to_string(levels)
      <> ")\n}\n\n"
      <> string.concat(callers),
    function: "run_1",
    answer: "[]",
  )
}

fn cases() -> List(Case) {
  [
    consumer("callback runner", "", "  ffi.each([model.make()], fn(x) { x })\n"),
    consumer(
      "field call",
      "  let h = model.Feeder(run: ffi.identity)\n",
      "  let _ = h.run(model.make())\n",
    ),
    consumer(
      "foreign function with no bounds",
      "",
      "  let _ = ffi.hold(model.make(), fn(x) { x })\n",
    ),
    consumer(
      "reviewed catalog function",
      "",
      "  let _ = list.map([model.make()], fn(x) { x })\n",
    ),
    consumer(
      "written runs, relay and carries",
      "",
      "  ffi.sink(ffi.keep([model.make()], fn(x) { x }))\n",
    ),
    alternating_case(),
  ]
}

fn slug(text: String) -> String {
  text
  |> string.replace(", ", "_")
  |> string.replace(" ", "_")
}

const manifest =
  "packages = [
  { name = \"gleam_stdlib\", version = \"1.0.5\", build_tools = [\"gleam\"], requirements = [], source = \"hex\", outer_checksum = \"0\" },
]

[requirements]
gleam_stdlib = { version = \">= 1.0.0 and < 2.0.0\" }
"

const both_targets = "\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n"

fn gleam_toml(stdlib: String) -> String {
  "name = \"probe\"\nversion = \"1.0.0\"\n\n[dependencies]\ngleam_stdlib = "
  <> stdlib
  <> "\n"
  <> both_targets
}

fn case_files(case_: Case) -> List(#(String, String)) {
  [
    #("gleam.toml", gleam_toml("\">= 1.0.0 and < 2.0.0\"")),
    #("manifest.toml", manifest),
    #("probe.graded", spec),
    #("src/probe.gleam", case_.main),
    #("src/probe/model.gleam", model_source()),
    #("src/probe/ffi.gleam", ffi_source()),
  ]
}

pub fn every_case_reads_its_answer_inside_the_bound_test() {
  list.each(cases(), fn(case_) {
    let directory =
      support.write_fixture(
        "build/consumer_scaling_" <> slug(case_.name),
        case_files(case_),
      )
    support.install_stdlib(directory)
    let before = reductions()
    let assert Ok(lines) = graded.inferred_lines(directory)
    let spent = reductions() - before
    support.cleanup(directory)
    let answer =
      list.find(lines, string.starts_with(
        _,
        "effects probe." <> case_.function <> " ",
      ))
    #(case_.name, answer)
    |> should.equal(#(
      case_.name,
      Ok("effects probe." <> case_.function <> " : " <> case_.answer),
    ))
    #(case_.name, spent <= work_bound)
    |> should.equal(#(case_.name, True))
  })
}

// Every case as a project the compiler checks, against the standard library
// this repository builds with.
pub fn every_case_compiles_test() {
  let stdlib = absolute("build/packages/gleam_stdlib")
  list.each(cases(), fn(case_) {
    let directory = absolute("build/consumer_scaling_check")
    let _ = simplifile.delete(directory)
    write_files(directory, [
      #("gleam.toml", gleam_toml("{ path = \"" <> stdlib <> "\" }")),
      #("src/probe.gleam", case_.main),
      #("src/probe/model.gleam", model_source()),
      #("src/probe/ffi.gleam", ffi_source()),
    ])
    let checked =
      shellout.command(run: "gleam", with: ["check"], in: directory, opt: [])
      |> result.map_error(fn(failure) { failure.1 })
    let _ = simplifile.delete(directory)
    #(case_.name, result.map(checked, fn(_) { Nil }))
    |> should.equal(#(case_.name, Ok(Nil)))
  })
}

fn write_files(directory: String, files: List(#(String, String))) -> Nil {
  list.each(files, fn(file) {
    let path = directory <> "/" <> file.0
    let _ = simplifile.create_directory_all(parent(path))
    let _ = simplifile.write(path, file.1)
    Nil
  })
}

fn absolute(path: String) -> String {
  case simplifile.current_directory() {
    Ok(cwd) -> cwd <> "/" <> path
    Error(_) -> path
  }
}

fn parent(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_, ..rest] -> rest |> list.reverse |> string.join("/")
    [] -> "."
  }
}

// Write every case under the directory given, one project each.
pub fn main() -> Nil {
  let root = case argv.load().arguments {
    [directory, ..] -> directory
    [] -> "build/consumer_scaling"
  }
  list.each(cases(), fn(case_) {
    let directory = root <> "/" <> slug(case_.name)
    write_files(directory, case_files(case_))
    support.install_stdlib(directory)
  })
}
