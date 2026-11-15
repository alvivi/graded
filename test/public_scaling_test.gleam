// A module of many public functions and no pair: publishing their lines costs
// work in proportion to their number. Each doubling of the count at most a
// little more than doubles the reductions an inference runs, and 4,000
// functions stay inside a bound near what one pass over them costs.

import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import graded
import support

@external(erlang, "scope_test_ffi", "reductions")
fn reductions() -> Int

const work_bound = 30_000_000

fn source(count: Int) -> String {
  case count {
    0 -> "pub fn main() -> Nil {\n  Nil\n}\n"
    _ ->
      "pub fn f"
      <> int.to_string(count)
      <> "() -> Nil {\n  Nil\n}\n\n"
      <> source(count - 1)
  }
}

// The reductions inferring a module of `count` public functions runs, its
// answers checked.
fn work(count: Int) -> Int {
  let directory =
    support.write_fixture(
      "/tmp/graded_public_scaling_" <> int.to_string(count),
      [
        #("gleam.toml", "name = \"probe\"\n"),
        #("src/probe.gleam", source(count)),
      ],
    )
  let before = reductions()
  let assert Ok(lines) = graded.inferred_lines(directory)
  let spent = reductions() - before
  support.cleanup(directory)
  lines
  |> list.filter(fn(line) {
    string.ends_with(line, "() : []") || string.ends_with(line, " : []")
  })
  |> list.length
  |> should.equal(count + 1)
  spent
}

pub fn publishing_grows_linearly_with_public_functions_test() {
  let one = work(1000)
  let two = work(2000)
  let four = work(4000)
  { two * 10 <= one * 25 } |> should.be_true
  { four * 10 <= two * 25 } |> should.be_true
  { four <= work_bound } |> should.be_true
}
