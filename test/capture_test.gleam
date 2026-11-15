// A function capture `f(a, _, c)` passed where a function goes reads as the
// closure it abbreviates, `fn(x) { f(a, x, c) }`: the same cost, the same
// carried latent and the same result, at a known contract, at a runner nothing
// answers for and at a boundless line. Its target is resolved as the named
// function is, never by walking the target again, so recursion through
// captures ends.

import gleam/list
import gleam/string
import gleeunit/should
import graded
import support

const ffi_source =
  "@external(erlang, \"m\", \"shout\")
@external(javascript, \"m\", \"shout\")
pub fn shout() -> Nil

@external(erlang, \"m\", \"each\")
@external(javascript, \"m\", \"each\")
pub fn each(list: List(a), f: fn(a) -> Nil) -> Nil

@external(erlang, \"m\", \"run_cb\")
@external(javascript, \"m\", \"run_cb\")
pub fn run_cb(f: fn(Int) -> Nil) -> Nil

@external(erlang, \"m\", \"keep\")
@external(javascript, \"m\", \"keep\")
pub fn keep(f: fn(Int) -> Nil) -> fn(Int) -> Nil

@external(erlang, \"m\", \"run_any\")
@external(javascript, \"m\", \"run_any\")
pub fn run_any(x: a) -> Nil
"

const spec =
  "assume app/ffi.shout : [Stdout]
assume app/ffi.each(list: [l], f: [f]) : [f] where runs : [], relay : f(l)
assume app/ffi.run_cb : []
assume app/ffi.keep(f: [f]) : [] where runs : [], carries : [f, f.returns]
assume app/ffi.run_any : []
"

const app_source =
  "import app/ffi
import nosource

pub type Tree {
  Tree(value: Int, children: List(Tree))
}

fn loud() -> Nil {
  ffi.shout()
}

fn noisy(x: Int, b: Int) -> Nil {
  loud()
}

fn run_with(x: Int, f: fn() -> Nil) -> Nil {
  f()
}

pub fn contract_capture(b: Int) -> Nil {
  ffi.each([1, 2], noisy(_, b))
}

pub fn contract_closure(b: Int) -> Nil {
  ffi.each([1, 2], fn(x) { noisy(x, b) })
}

pub fn unknown_capture(b: Int) -> Nil {
  nosource.lost(noisy(_, b))
}

pub fn unknown_closure(b: Int) -> Nil {
  nosource.lost(fn(x) { noisy(x, b) })
}

pub fn boundless_capture(b: Int) -> Nil {
  ffi.run_cb(noisy(_, b))
}

pub fn boundless_closure(b: Int) -> Nil {
  ffi.run_cb(fn(x) { noisy(x, b) })
}

pub fn carried_capture(b: Int) -> Nil {
  let kept = ffi.keep(noisy(_, b))
  ffi.run_any(kept)
}

pub fn carried_closure(b: Int) -> Nil {
  let kept = ffi.keep(fn(x) { noisy(x, b) })
  ffi.run_any(kept)
}

pub fn effectful_capture() -> Nil {
  ffi.each([1], run_with(_, loud))
}

pub fn effectful_closure() -> Nil {
  ffi.each([1], fn(x) { run_with(x, loud) })
}

pub fn effectful_capture_unknown() -> Nil {
  nosource.lost(run_with(_, loud))
}

pub fn parameter_capture(step: fn(Int, Int) -> Nil, b: Int) -> Nil {
  ffi.each([1], step(_, b))
}

pub fn self_capture(t: Tree) -> Nil {
  ffi.each(t.children, self_capture(_))
}

pub fn ping(t: Tree, n: Int) -> Nil {
  ffi.each(t.children, pong(_, n))
}

pub fn pong(t: Tree, n: Int) -> Nil {
  loud()
  ffi.each(t.children, ping(_, n))
}
"

fn lines() -> List(String) {
  let directory =
    support.write_fixture("/tmp/graded_capture_test", [
      #("gleam.toml", "name = \"app\"\n"),
      #("app.graded", spec),
      #("src/app/ffi.gleam", ffi_source),
      #("src/app.gleam", app_source),
    ])
  let assert Ok(lines) = graded.inferred_lines(directory)
  support.cleanup(directory)
  lines
}

fn effects_of(lines: List(String), function: String) -> String {
  let prefix = "effects app." <> function
  let assert Ok(line) =
    list.find(lines, fn(line) {
      string.starts_with(line, prefix <> " ")
      || string.starts_with(line, prefix <> "(")
    })
  let assert Ok(#(_, effects)) = string.split_once(line, " : ")
  effects
}

pub fn a_capture_reads_as_its_closure_test() {
  let lines = lines()
  [
    #("contract", "[Stdout]"),
    #("unknown", "[Stdout, Unknown]"),
    #("boundless", "[Stdout]"),
    #("carried", "[Stdout]"),
  ]
  |> list.each(fn(case_) {
    let #(shape, expected) = case_
    #(shape, effects_of(lines, shape <> "_capture"))
    |> should.equal(#(shape, expected))
    #(shape, effects_of(lines, shape <> "_closure"))
    |> should.equal(#(shape, expected))
  })
}

pub fn a_capture_holding_an_effectful_argument_is_charged_where_it_runs_test() {
  let lines = lines()
  effects_of(lines, "effectful_capture") |> should.equal("[Stdout]")
  effects_of(lines, "effectful_closure") |> should.equal("[Stdout]")
  effects_of(lines, "effectful_capture_unknown")
  |> should.equal("[Stdout, Unknown]")
}

pub fn a_capture_of_code_this_module_cannot_name_reads_unknown_test() {
  lines()
  |> effects_of("parameter_capture")
  |> should.equal("[Unknown]")
}

pub fn recursion_through_captures_ends_test() {
  let lines = lines()
  effects_of(lines, "self_capture") |> should.equal("[]")
  effects_of(lines, "ping") |> should.equal("[Stdout]")
  effects_of(lines, "pong") |> should.equal("[Stdout]")
}

// Applying a capture evaluates the arguments it fixes again, so its returned
// operator holds what evaluating them costs, as the closure it abbreviates
// does. Writing the capture is charged separately, where it is written.

const evaluated_source =
  "import app/ffi

fn loud() -> Nil {
  ffi.shout()
}

fn quiet(_n: Int, _x: Nil) -> Nil {
  Nil
}

fn quiet_first(_x: Nil, _n: Int) -> Nil {
  Nil
}

fn quiet_labelled(n _n: Int, x _x: Nil) -> Nil {
  Nil
}

pub fn after_hole() -> fn(Int) -> Nil {
  quiet(_, loud())
}

pub fn after_hole_closure() -> fn(Int) -> Nil {
  fn(n) { quiet(n, loud()) }
}

pub fn before_hole() -> fn(Int) -> Nil {
  quiet_first(loud(), _)
}

pub fn labelled() -> fn(Int) -> Nil {
  quiet_labelled(x: loud(), n: _)
}

pub fn pure_argument() -> fn(Int) -> Nil {
  quiet(_, Nil)
}

pub fn run_by_runner() -> Nil {
  ffi.run_cb(quiet(_, loud()))
}
"

pub fn a_capture_returns_what_evaluating_its_arguments_costs_test() {
  let directory =
    support.write_fixture("/tmp/graded_capture_evaluated", [
      #("gleam.toml", "name = \"app\"\n"),
      #("app.graded", spec),
      #("src/app/ffi.gleam", ffi_source),
      #("src/app.gleam", evaluated_source),
    ])
  let assert Ok(lines) = graded.inferred_lines(directory)
  support.cleanup(directory)
  [
    "after_hole", "after_hole_closure", "before_hole", "labelled",
    "pure_argument", "run_by_runner",
  ]
  |> list.map(fn(function) {
    let prefix = "effects app." <> function <> " : "
    let assert Ok(line) = list.find(lines, string.starts_with(_, prefix))
    #(function, string.drop_start(line, string.length(prefix)))
  })
  |> should.equal([
    #("after_hole", "[Stdout] where returns : [Stdout]"),
    #("after_hole_closure", "[] where returns : [Stdout]"),
    #("before_hole", "[Stdout] where returns : [Stdout]"),
    #("labelled", "[Stdout] where returns : [Stdout]"),
    #("pure_argument", "[] where returns : []"),
    #("run_by_runner", "[Stdout]"),
  ])
}

// A consumer applies a capture its path dependency returns, under a line that
// says only what making it costs.
pub fn a_returned_capture_charges_its_arguments_in_a_consumer_test() {
  let parent =
    support.write_fixture("build/capture_returned_across_packages", [
      #("maker/gleam.toml", "name = \"maker\"\nversion = \"1.0.0\"\n"),
      #("maker/manifest.toml", "packages = []\n"),
      #("maker/maker.graded", "assume maker.shout : [Stdout]\n"),
      #(
        "maker/src/maker.gleam",
        "@external(erlang, \"m\", \"shout\")
fn shout() -> Nil

fn quiet(_n: Int, _x: Nil) -> Nil {
  Nil
}

pub fn make() -> fn(Int) -> Nil {
  quiet(_, shout())
}
",
      ),
      #(
        "consumer/gleam.toml",
        "name = \"consumer\"\nversion = \"1.0.0\"\n\n[dependencies]\nmaker = { path = \"../maker\" }\n",
      ),
      #(
        "consumer/manifest.toml",
        "packages = [\n  { name = \"maker\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"../maker\" },\n]\n",
      ),
      #("consumer/consumer.graded", "assume maker.make : []\n"),
      #(
        "consumer/src/consumer.gleam",
        "import maker

pub fn go() -> Nil {
  let f = maker.make()
  f(1)
}
",
      ),
    ])
  let assert Ok(Nil) = graded.run_infer(parent <> "/maker")
  let assert Ok(maker) = graded.inferred_lines(parent <> "/maker")
  let assert Ok(consumer) = graded.inferred_lines(parent <> "/consumer")
  support.cleanup("build/capture_returned_across_packages")
  maker
  |> list.filter(string.starts_with(_, "effects maker.make"))
  |> should.equal(["effects maker.make : [Stdout] where returns : [Stdout]"])
  consumer |> should.equal(["effects consumer.go : [Stdout]"])
}

// Names a capture or call reaches through its scope: a local alias, a
// parameter, a captured record, and an opaque destructured local, each sharing
// a name with a pure module function or with the function itself.

const scope_source =
  "import app/ffi

pub type Config {
  Config(on_item: fn() -> Nil)
}

pub fn action() -> Nil {
  Nil
}

fn loud() -> Nil {
  ffi.shout()
}

fn quiet(_n: Int, _x: Nil) -> Nil {
  Nil
}

pub fn aliased() -> fn(Int) -> Nil {
  let action = ffi.shout
  quiet(_, action())
}

pub fn from_parameter(action) -> fn(Int) -> Nil {
  quiet(_, action())
}

pub fn from_receiver() -> fn(Int) -> Nil {
  let cfg = Config(on_item: ffi.shout)
  quiet(_, cfg.on_item())
}

pub fn destructured() -> Nil {
  let #(action) = #(loud)
  action()
}

pub fn destructured_capture() -> fn(Int) -> Nil {
  let #(action) = #(loud)
  quiet(_, action())
}

pub fn again() -> Nil {
  let #(again) = #(loud)
  again()
}
"

pub fn a_capture_and_a_call_read_names_through_their_scope_test() {
  let directory =
    support.write_fixture("/tmp/graded_capture_scope", [
      #("gleam.toml", "name = \"app\"\n"),
      #("app.graded", spec),
      #("src/app/ffi.gleam", ffi_source),
      #("src/app.gleam", scope_source),
    ])
  let assert Ok(lines) = graded.inferred_lines(directory)
  support.cleanup(directory)
  lines
  |> list.filter(string.starts_with(_, "effects app."))
  |> should.equal([
    "effects app.action : []",
    // The opaque local shadows the function being read.
    "effects app.again : [Unknown]",
    "effects app.aliased : [Stdout] where returns : [Stdout]",
    "effects app.destructured : [Unknown]",
    "effects app.destructured_capture : [Unknown]",
    // A parameter the returned capture calls has no bound there: what applying
    // it costs is unknown.
    "effects app.from_parameter(action: [action]) : [action]",
    "effects app.from_receiver : [Stdout] where returns : [Stdout]",
  ])
}

// A consumer applies a capture its path dependency returns, whose fixed
// argument calls a local alias sharing its name with a pure function of the
// dependency.
pub fn a_returned_capture_reads_a_local_alias_in_a_consumer_test() {
  let parent =
    support.write_fixture("build/capture_alias_across_packages", [
      #("maker/gleam.toml", "name = \"maker\"\nversion = \"1.0.0\"\n"),
      #("maker/manifest.toml", "packages = []\n"),
      #("maker/maker.graded", "assume maker/ffi.shout : [Stdout]\n"),
      #(
        "maker/src/maker/ffi.gleam",
        "@external(erlang, \"m\", \"shout\")\npub fn shout() -> Nil\n",
      ),
      #(
        "maker/src/maker.gleam",
        "import maker/ffi

pub fn action() -> Nil {
  Nil
}

fn quiet(_n: Int, _x: Nil) -> Nil {
  Nil
}

pub fn make_loud() -> fn(Int) -> Nil {
  let action = ffi.shout
  quiet(_, action())
}
",
      ),
      #(
        "consumer/gleam.toml",
        "name = \"consumer\"\nversion = \"1.0.0\"\n\n[dependencies]\nmaker = { path = \"../maker\" }\n",
      ),
      #(
        "consumer/manifest.toml",
        "packages = [\n  { name = \"maker\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"../maker\" },\n]\n",
      ),
      #("consumer/consumer.graded", "assume maker.make_loud : []\n"),
      #(
        "consumer/src/consumer.gleam",
        "import maker

pub fn go() -> Nil {
  let f = maker.make_loud()
  f(1)
}
",
      ),
    ])
  let assert Ok(Nil) = graded.run_infer(parent <> "/maker")
  let assert Ok(maker) = graded.inferred_lines(parent <> "/maker")
  let assert Ok(consumer) = graded.inferred_lines(parent <> "/consumer")
  support.cleanup("build/capture_alias_across_packages")
  maker
  |> list.filter(string.starts_with(_, "effects maker.make_loud"))
  |> should.equal([
    "effects maker.make_loud : [Stdout] where returns : [Stdout]",
  ])
  consumer |> should.equal(["effects consumer.go : [Stdout]"])
}
