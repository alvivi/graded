// Specs read under the latent-effect rules, once the run's signatures and
// types are known: a bound the rules forbid is an error naming the line in the
// project's own spec, and refuses the whole line — charging its path the
// wildcard — in a spec another package wrote.

import gleam/list
import gleam/string
import gleeunit/should
import graded
import graded/internal/cli
import graded/internal/types
import support

const dep_ffi =
  "pub type Config {
  Config(on_item: fn(String) -> Nil)
}

@external(erlang, \"m\", \"run\")
@external(javascript, \"m\", \"run\")
pub fn run(value: Config) -> Nil
"

// The project's own spec

fn own_spec_project(directory: String) -> String {
  support.write_fixture(directory, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "// A carried variable charged by the effect term.\nassume proj/ffi.run(value: [v]) : [v]\n",
    ),
    #("src/proj/ffi.gleam", dep_ffi),
    #(
      "src/proj.gleam",
      "import proj/ffi\n\npub fn go(c: ffi.Config) -> Nil {\n  ffi.run(c)\n}\n",
    ),
  ])
}

const own_spec_error =
  "2: assume proj/ffi.run(value: [v]) : [v]
  `v` names what `value` carries, which the effect term cannot charge; list it in `runs` instead"

pub fn a_forbidden_bound_in_the_own_spec_is_an_error_naming_the_line_test() {
  let directory = own_spec_project("/tmp/graded_latent_own_spec")
  let check = graded.check_project(directory)
  let effect = graded.run_effect_formatted(directory, "proj.go", graded.Graded)
  let why = graded.run_why(directory, "proj.go")
  let infer = graded.run_infer_command(cli.DryRun, directory)
  support.cleanup(directory)
  let expected =
    graded.GradedParseError(
      path: directory <> "/proj.graded",
      message: own_spec_error,
    )
  check |> should.equal(Error(expected))
  effect |> should.equal(Error(expected))
  why |> should.equal(Error(expected))
  infer |> should.equal(Error(expected))
}

// A dependency's spec

fn dependency_project(directory: String, dependency_spec: String) -> String {
  support.write_project_with_dependency(
    directory:,
    package: "proj",
    spec: "",
    sources: [
      #(
        "src/proj.gleam",
        "import dep/ffi\n\npub fn go(c: ffi.Config) -> Nil {\n  ffi.run(c)\n}\n",
      ),
    ],
    dependency: "dep",
    dependency_spec:,
    dependency_sources: [#("dep/ffi.gleam", dep_ffi)],
  )
}

const inferred = "// resolved from in-memory inference\n"

fn consumer_answer(directory: String) -> String {
  let assert Ok(answer) =
    graded.run_effect_formatted(directory, "proj.go", graded.Graded)
  support.cleanup(directory)
  answer
}

pub fn a_forbidden_bound_in_a_dependency_spec_charges_the_wildcard_test() {
  [
    "assume dep/ffi.run(value: [v]) : [v]\n",
    // Beneath a module-level `assume` the refused line still answers.
    "assume dep/ffi : []\nassume dep/ffi.run(value: [v]) : [v]\n",
    // A generated line for the same name goes with it.
    "assume dep/ffi.run(value: [v]) : [v]\neffects dep/ffi.run : []\n",
    // So do its other clauses.
    "assume dep/ffi.run(value: [v]) : [v] where carries : [v]\n",
    "assume dep/ffi.run(value: [v]) : [v] where returns : [Net]\n",
  ]
  |> list.index_map(fn(spec, index) {
    dependency_project("/tmp/graded_latent_dep_" <> string.inspect(index), spec)
    |> consumer_answer
  })
  |> should.equal(list.repeat(inferred <> "effects proj.go : [_]", 5))
}

pub fn a_dependency_spec_without_a_forbidden_bound_answers_test() {
  dependency_project(
    "/tmp/graded_latent_dep_valid",
    "assume dep/ffi.run(value: [v]) : [] where runs : []\n",
  )
  |> consumer_answer
  |> should.equal(inferred <> "effects proj.go : []")
}

pub fn a_refused_dependency_line_answers_over_a_catalog_entry_test() {
  // `gleam/list` is catalogued, module-level, for the stdlib; the installed
  // stdlib's own spec refuses its line for `each`, and the refusal answers.
  let directory = "/tmp/graded_latent_catalog"
  let _ =
    support.write_fixture(
      directory,
      list.append(support.hex_tree("proj", [#("gleam_stdlib", "1.0.5")]), [
        #(
          "src/proj.gleam",
          "import gleam/list\n\npub fn go() -> Nil {\n  list.each([1], fn(_) { Nil })\n}\n",
        ),
        #(
          "build/packages/gleam_stdlib/src/gleam/list.gleam",
          "pub fn each(list: List(a), f: fn(a) -> Nil) -> Nil {\n  Nil\n}\n",
        ),
        #(
          "build/packages/gleam_stdlib/gleam_stdlib.graded",
          "assume gleam/list.each(list: [l], f: [f]) : [l]\n",
        ),
      ]),
    )
  consumer_answer(directory)
  |> should.equal(inferred <> "effects proj.go : [_]")
}

// The spec lint

pub fn a_bound_that_names_nothing_is_linted_under_the_rules_test() {
  let directory =
    support.write_fixture("/tmp/graded_latent_meaningless", [
      #("gleam.toml", "name = \"proj\"\n"),
      #("proj.graded", "assume proj/ffi.run(value: []) : []\n"),
      #("src/proj/ffi.gleam", dep_ffi),
    ])
  let assert Ok(active) = graded.check_project(directory)
  support.cleanup(directory)
  let warnings = fn(results: List(types.CheckResult)) {
    list.flat_map(results, fn(result) { result.warnings })
  }
  warnings(active)
  |> should.equal([
    types.MeaninglessBoundWarning(function: "proj/ffi.run", param: "value"),
  ])
}
