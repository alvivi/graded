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
import graded/internal/types
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
  let assert Ok(lines) = graded.inferred_lines_with(directory, types.Active)
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
