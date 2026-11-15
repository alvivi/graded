// Every shape a function value can be handed over in reads a charge or a
// carried latent, and no warning stands in for one: a reference passed to code
// that may run it is charged there, and the charge explains itself as the
// argument it came with.

import gleam/list
import gleam/set
import gleam/string
import gleeunit/should
import graded
import graded/internal/checker
import graded/internal/types
import support

const ffi_source =
  "pub type Wrapper {
  Wrapper(f: fn() -> Nil)
}

@external(erlang, \"m\", \"shout\")
@external(javascript, \"m\", \"shout\")
pub fn shout() -> Nil

@external(erlang, \"m\", \"run\")
@external(javascript, \"m\", \"run\")
pub fn run(w: Wrapper) -> Nil

@external(erlang, \"m\", \"run_all\")
@external(javascript, \"m\", \"run_all\")
pub fn run_all(fs: List(fn() -> Nil)) -> Nil

@external(erlang, \"m\", \"run_any\")
@external(javascript, \"m\", \"run_any\")
pub fn run_any(x: a) -> Nil
"

const spec =
  "assume app/ffi.shout : [Stdout]
assume app/ffi.run : []
assume app/ffi.run_all : []
assume app/ffi.run_any : []
check app.private_in_list : []
check app.qualified_in_list : []
check app.in_construction : []
check app.field_value : []
check app.capture : []
"

const app_source =
  "import app/ffi.{Wrapper}

pub type Config {
  Config(on_item: fn() -> Nil)
}

fn loud() -> Nil {
  ffi.shout()
}

fn run_with(x: Int, f: fn() -> Nil) -> Int {
  f()
  x
}

pub fn private_in_list() -> Nil {
  ffi.run_all([loud])
}

pub fn qualified_in_list() -> Nil {
  ffi.run_all([ffi.shout])
}

pub fn in_construction() -> Nil {
  ffi.run(Wrapper(loud))
}

pub fn field_value() -> Nil {
  let config = Config(on_item: loud)
  ffi.run_any(config.on_item)
}

pub fn capture() -> Nil {
  ffi.run_any(run_with(_, loud))
}
"

fn results() -> List(types.CheckResult) {
  let root =
    support.write_fixture("build/occurrence_shapes", [
      #("gleam.toml", "name = \"app\"\n"),
      #("app.graded", spec),
      #("src/app/ffi.gleam", ffi_source),
      #("src/app.gleam", app_source),
    ])
  let assert Ok(results) = graded.check_project(root)
  support.cleanup(root)
  results
}

pub fn every_occurrence_shape_is_charged_where_it_may_run_test() {
  let results = results()
  let assert Ok(app) =
    list.find(results, fn(result) { string.ends_with(result.file, "app.gleam") })
  // Each charge is the argument's own contributor, naming what was passed.
  app.violations
  |> list.map(fn(violation) {
    #(
      violation.function,
      checker.call_kind(violation.explanation.call),
      violation.explanation.actual,
    )
  })
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  |> should.equal([
    #(
      "capture",
      checker.PassedArgumentCall("a function capture", "app/ffi.run_any"),
      stdout(),
    ),
    #(
      "field_value",
      checker.PassedArgumentCall("`config.on_item`", "app/ffi.run_any"),
      stdout(),
    ),
    #(
      "in_construction",
      checker.PassedArgumentCall("a record", "app/ffi.run"),
      stdout(),
    ),
    #(
      "private_in_list",
      checker.PassedArgumentCall("a list or tuple", "app/ffi.run_all"),
      stdout(),
    ),
    #(
      "qualified_in_list",
      checker.PassedArgumentCall("a list or tuple", "app/ffi.run_all"),
      stdout(),
    ),
  ])
  // And nothing warns in place of a charge.
  list.flat_map(results, fn(result) { result.warnings }) |> should.equal([])
}

pub fn an_argument_charge_explains_itself_test() {
  let root =
    support.write_fixture("build/occurrence_why", [
      #("gleam.toml", "name = \"app\"\n"),
      #("app.graded", spec),
      #("src/app/ffi.gleam", ffi_source),
      #("src/app.gleam", app_source),
    ])
  let assert Ok(text) = graded.run_why(root, "app.field_value")
  support.cleanup(root)
  text
  |> string.contains(
    "passes `config.on_item` to `app/ffi.run_any`, which may run it,",
  )
  |> should.be_true
}

fn stdout() -> types.EffectSet {
  types.Specific(set.from_list(["Stdout"]))
}
