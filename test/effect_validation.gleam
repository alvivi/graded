// Validate graded's answers against what generated programs actually do.
//
//   gleam run -m effect_validation -- [--seed N] [--cases N] [--graded DIR]
//     [--shard I/N]
//
// Erlang cases are drawn with a fixed seed from shapes that hand an effectful
// leaf over in a list, a tuple, a record, a result, a type variable, a map, a
// closure, a capture or a returned value, to the standard library, to foreign
// runners or to a field call in another function, followed by fixed cases: a
// constructor a foreign projector applies, two callbacks sharing one bound and
// crossed bounds over a running fallback body, functions that refer to each
// other inside lists, and calls through local bindings that share their
// spelling with a pure function of the module or are read after another
// binding of the same spelling. The JavaScript project is a fixed set of cases:
// lists, records, closures and references handed to foreign runners, a list
// relayed to its callback, a field value relayed by the standard library,
// foreign producers of a list, an external type and a `Dynamic`, a definition
// gated to each target, and externals whose fallback body differs from the
// external.
//
// Every leaf is a foreign stub that prints its own label and is declared with
// a truthful `assume` line, and `main` runs each case between two markers. A
// label is attributed to the case whose markers it printed between, wherever
// its leaf was built, and every label to `main`. Each of those functions'
// inferred effects must contain the labels attributed to it, `[Unknown]` read
// as any effect.
//
// A third project reads producers' summaries across modules of one package: a
// stored field of a producer's parameter whose function starts at the
// consumer's offset, the same one offset later, and a producer's private
// function named like a pure one of the consumer's.
//
// Two-target projects are read on both targets and run on both, every label
// either run printed counting: a function, a type, a foreign signature, an
// alias a parameter is typed by, and another module's function, each defined
// once per target; and, each alone in a project of its own, a constant, an
// alias and a dependency's function defined once per target.
//
// A dependency is a negative control: with its committed summary stale
// it prints while its consumer reads `[]`, the documented precondition failure;
// regenerated, the consumer reads what it prints.
//
// `--graded DIR` answers with the graded checkout at DIR, so the same cases can
// be run against another revision.
//
// `--shard I/N` runs the blocks whose position K in `main`'s list, counted from
// 0, has K % N == I - 1, the stale control among them.

import argv
import filepath
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/pair
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded
import graded/internal/answer
import shellout
import simplifile

pub fn main() -> Nil {
  let options = parse_options(argv.load().arguments, Options(1, 40, ".", 1, 1))
  let graded = absolute(options.graded)
  let root = absolute("build/effect_validation")
  let _ = simplifile.delete(root)
  let blocks = [
    Cases("Erlang", fn() {
      validate(graded, root <> "/erlang", "erlang", erlang_cases(options))
    }),
    Cases("JavaScript", fn() {
      validate(graded, root <> "/javascript", "javascript", javascript_cases())
    }),
    Cases("module-boundary", fn() {
      boundary_cases(graded, root <> "/boundary")
    }),
    Cases("two-target", fn() { two_target_cases(graded, root <> "/targets") }),
    Cases("two-target matrix", fn() { matrix_cases(graded, root <> "/matrix") }),
    Cases("published-spec", fn() {
      publication_cases(graded, root <> "/publication")
    }),
    Cases("installed-package", fn() {
      installed_cases(graded, root <> "/installed")
    }),
    Cases("single-pass", fn() {
      single_pass_cases(graded, root <> "/single_pass")
    }),
    Cases("recursion", fn() {
      recursion_dimension_cases(graded, root <> "/recursion")
    }),
    Cases("declared-external", fn() {
      external_dimension_cases(graded, root <> "/externals")
    }),
    Cases("operator recursion", fn() {
      operator_dimension_cases(graded, root <> "/operators")
    }),
    Cases("branching walk", fn() {
      fan_dimension_cases(graded, root <> "/fans")
    }),
    Cases("line translation", fn() {
      translation_dimension_cases(graded, root <> "/translation")
    }),
    Cases("written paths", fn() {
      written_path_dimension_cases(graded, root <> "/written")
    }),
    Cases("pair-configuration cost", fn() {
      pair_cost_cases(root <> "/pair_cost")
    }),
    Cases("refusal cost", fn() {
      refusal_cost_cases(graded, root <> "/refusal_cost")
    }),
    Cases("scaling", fn() { scaling_dimension_cases(root <> "/scaling") }),
    Cases("one-target", fn() { one_target_cases(graded, root <> "/one_target") }),
    Cases("dependency location", fn() { location_cases(root <> "/location") }),
    Control(fn() { stale_control(graded, root <> "/stale") }),
  ]
  let ran =
    list.index_map(blocks, fn(block, k) {
      case k % options.shards == options.shard - 1, block {
        False, _ -> #([], [], [])
        True, Cases(label, run) -> {
          let outcome = run()
          #([coverage(label, outcome)], outcome.failures, [])
        }
        True, Control(run) -> #([], [], [run()])
      }
    })
  let failures = list.flat_map(ran, fn(share) { share.1 })
  let controls = list.flat_map(ran, fn(share) { share.2 })
  io.println(
    "effect_validation: seed "
    <> int.to_string(options.seed)
    <> ", "
    <> string.join(list.flat_map(ran, fn(share) { share.0 }), ", ")
    <> ", "
    <> int.to_string(list.length(failures))
    <> " counterexample(s)",
  )
  list.each(failures, io.println)
  list.each(controls, fn(control) {
    case control {
      Ok(text) | Error(text) -> io.println(text)
    }
  })
  case failures, list.all(controls, result.is_ok) {
    [], True -> Nil
    _, _ -> halt(1)
  }
}

// One block of the run: cases with the label their coverage is printed under,
// or the stale control.
type Block {
  Cases(label: String, run: fn() -> Outcome)
  Control(run: fn() -> Result(String, String))
}

fn coverage(target: String, outcome: Outcome) -> String {
  int.to_string(outcome.total)
  <> " "
  <> target
  <> " cases ("
  <> int.to_string(outcome.printed)
  <> " printed a label)"
}

type Options {
  Options(seed: Int, cases: Int, graded: String, shard: Int, shards: Int)
}

fn parse_options(arguments: List(String), options: Options) -> Options {
  case arguments {
    ["--seed", value, ..rest] ->
      parse_options(
        rest,
        Options(..options, seed: int.parse(value) |> result.unwrap(1)),
      )
    ["--cases", value, ..rest] ->
      parse_options(
        rest,
        Options(..options, cases: int.parse(value) |> result.unwrap(40)),
      )
    ["--graded", value, ..rest] ->
      parse_options(rest, Options(..options, graded: value))
    ["--shard", value, ..rest] ->
      case string.split(value, "/") |> list.map(int.parse) {
        [Ok(shard), Ok(shards)] if 1 <= shard && shard <= shards ->
          parse_options(rest, Options(..options, shard:, shards:))
        _ -> parse_options(rest, Options(..options, shard: 1, shards: 1))
      }
    ["--shard"] -> Options(..options, shard: 1, shards: 1)
    [_, ..rest] -> parse_options(rest, options)
    [] -> options
  }
}

// One case: the body of `case_<n>`, the helpers it needs, and the spec lines
// those helpers declare.
type Case {
  Case(name: String, body: String, helpers: String, spec: String)
}

// Shapes

// The target-independent shapes. `leaf` is the case's effectful function;
// `earlier` is a case at or before this one, whose `box_<earlier>` helper
// builds a record around that case's leaf.
fn erlang_shape(index: Int, n: Int, earlier: Int) -> Case {
  let suffix = int.to_string(n)
  let leaf = "leaf_" <> suffix
  case index {
    0 ->
      Case(
        "list relayed to its callback",
        "list.each([" <> leaf <> "], fn(f) { f() })",
        "",
        "",
      )
    1 ->
      Case(
        "list built by a callback, then relayed",
        "list.map([1], fn(_) { " <> leaf <> " }) |> list.each(fn(f) { f() })",
        "",
        "",
      )
    2 ->
      Case("list to a foreign runner", "ffi.run_all([" <> leaf <> "])", "", "")
    3 ->
      Case(
        "tuple to a foreign runner",
        "ffi.run_first(#(" <> leaf <> ", 1))",
        "",
        "",
      )
    4 ->
      Case(
        "record to a foreign runner",
        "ffi.run_box(Box(" <> leaf <> "))",
        "",
        "",
      )
    5 ->
      Case(
        "result to a foreign runner",
        "ffi.run_ok(Ok(" <> leaf <> "))",
        "",
        "",
      )
    6 ->
      Case(
        "type variable forwarded to a foreign runner",
        "forward_" <> suffix <> "(" <> leaf <> ")",
        "fn forward_" <> suffix <> "(x: a) -> Nil {\n  ffi.run_any(x)\n}\n\n",
        "",
      )
    7 ->
      Case(
        "map values to a foreign runner",
        "ffi.run_values(dict.from_list([#(\"k\", " <> leaf <> ")]))",
        "",
        "",
      )
    8 ->
      Case(
        "record built here, activated in another function",
        "activate_" <> suffix <> "(Box(" <> leaf <> "))",
        "fn activate_" <> suffix <> "(box: Box) -> Nil {\n  box.f()\n}\n\n",
        "",
      )
    9 ->
      Case(
        "closure handed to a foreign runner",
        "ffi.run_any(fn() { " <> leaf <> "() })",
        "",
        "",
      )
    10 ->
      Case(
        "capture handed to a foreign runner",
        "ffi.run_any(call_" <> suffix <> "(_, " <> leaf <> "))",
        "fn call_"
          <> suffix
          <> "(_x: Int, f: fn() -> Nil) -> Nil {\n  f()\n}\n\n",
        "",
      )
    11 ->
      Case(
        "callback parameter called by a helper",
        "apply_" <> suffix <> "(" <> leaf <> ")",
        "fn apply_" <> suffix <> "(f: fn() -> Nil) -> Nil {\n  f()\n}\n\n",
        "",
      )
    12 ->
      Case(
        "closure a helper returns, to a foreign runner",
        "ffi.run_any(make_" <> suffix <> "())",
        "fn make_"
          <> suffix
          <> "() -> fn() -> Nil {\n  fn() { "
          <> leaf
          <> "() }\n}\n\n",
        "",
      )
    _ ->
      Case(
        "record an earlier case's helper built, activated here",
        "let box = box_" <> int.to_string(earlier) <> "()\n  box.f()",
        "",
        "",
      )
  }
}

const shape_count = 14

fn erlang_cases(options: Options) -> List(Case) {
  let #(_, cases) =
    numbers(options.cases)
    |> list.map_fold(options.seed, fn(seed, n) {
      let shape = next(seed)
      let earlier = next(shape)
      #(
        earlier,
        erlang_shape(draw(shape, shape_count), n, 1 + draw(earlier, n)),
      )
    })
  list.append(cases, erlang_fixed_cases(options.cases + 1))
  |> list.append(shadowing_cases(options.cases + 5))
}

// The fixed Erlang cases, numbered from `first`: a constructor a foreign
// projector applies to each callback, two callbacks sharing one bound and
// crossed bounds over an external whose fallback body runs here, and two
// functions that hand each other to the standard library inside lists.
fn erlang_fixed_cases(first: Int) -> List(Case) {
  let number = fn(offset) { int.to_string(first + offset) }
  let quiet = fn(n) { "fn quiet_" <> n <> "() -> Nil {\n  Nil\n}\n\n" }
  let projected = number(0)
  let shared = number(1)
  let crossed = number(2)
  let recursive = number(3)
  [
    Case(
      "constructor a foreign projector applies, to a foreign runner",
      "ffi.run_boxes(ffi.project([leaf_" <> projected <> "], Box))",
      "",
      "assume app/ffi.project(xs: [x], f: [f]) : [f] where runs : [], relay : f(x), carries : [f.returns]\n",
    ),
    Case(
      "two callbacks sharing one bound, run by a fallback body",
      "fallback.run_shared(leaf_" <> shared <> ", quiet_" <> shared <> ")",
      quiet(shared),
      "assume app/fallback.run_shared(f: [e], g: [e]) : [e]\n",
    ),
    Case(
      "crossed bounds over a fallback body that runs its first callback",
      "fallback.run_crossed(leaf_" <> crossed <> ", quiet_" <> crossed <> ")",
      quiet(crossed),
      "assume app/fallback.run_crossed(f: [g], g: [f]) : [g]\n",
    ),
    Case(
      "functions handing each other to the standard library inside lists",
      "ping_" <> recursive <> "(2)",
      "pub fn ping_"
        <> recursive
        <> "(n: Int) -> Nil {\n  case n > 0 {\n    True -> list.each([pong_"
        <> recursive
        <> "], fn(f) { f(n - 1) })\n    False -> Nil\n  }\n}\n\npub fn pong_"
        <> recursive
        <> "(n: Int) -> Nil {\n  leaf_"
        <> recursive
        <> "()\n  case n > 0 {\n    True -> list.each([ping_"
        <> recursive
        <> "], fn(f) { f(n - 1) })\n    False -> Nil\n  }\n}\n\n",
      "",
    ),
  ]
}

// The shadowing Erlang cases, numbered from `first`. Each calls its leaf
// through a local binding — a parameter, a case pattern, a `use` or closure
// parameter, a destructured `let` or `use` — that shares its spelling with a
// pure function of the module or rebinds a parameter handed one, or through a
// record or closure that stored one binding and is read after another binding
// of the same spelling.
fn shadowing_cases(first: Int) -> List(Case) {
  let idle = fn(n) { "fn idle_" <> n <> "() -> Nil {\n  Nil\n}\n\n" }
  let shapes = [
    #("a parameter sharing a pure function's name", fn(n) {
      #(
        "param_" <> n <> "(leaf_" <> n <> ")",
        idle(n)
          <> "fn param_"
          <> n
          <> "(idle_"
          <> n
          <> ": fn() -> Nil) -> Nil {\n  idle_"
          <> n
          <> "()\n}\n\n",
      )
    }),
    #("a case pattern sharing a pure function's name", fn(n) {
      #(
        "case Ok(leaf_"
          <> n
          <> ") {\n    Ok(idle_"
          <> n
          <> ") -> idle_"
          <> n
          <> "()\n    Error(_) -> Nil\n  }",
        idle(n),
      )
    }),
    #("a use parameter sharing a pure function's name", fn(n) {
      #(
        "use idle_" <> n <> " <- with_" <> n <> "()\n  idle_" <> n <> "()",
        idle(n)
          <> "fn with_"
          <> n
          <> "(next: fn(fn() -> Nil) -> Nil) -> Nil {\n  next(leaf_"
          <> n
          <> ")\n}\n\n",
      )
    }),
    #("a closure parameter sharing a pure function's name", fn(n) {
      #(
        "hand_" <> n <> "(fn(idle_" <> n <> ") { idle_" <> n <> "() })",
        idle(n)
          <> "fn hand_"
          <> n
          <> "(f: fn(fn() -> Nil) -> Nil) -> Nil {\n  f(leaf_"
          <> n
          <> ")\n}\n\n",
      )
    }),
    #("a destructured let sharing a pure function's name", fn(n) {
      #(
        "let #(idle_" <> n <> ") = #(leaf_" <> n <> ")\n  idle_" <> n <> "()",
        idle(n),
      )
    }),
    #("a destructured use sharing a pure function's name", fn(n) {
      #(
        "use #(idle_" <> n <> ") <- pair_" <> n <> "()\n  idle_" <> n <> "()",
        idle(n)
          <> "fn pair_"
          <> n
          <> "(next: fn(#(fn() -> Nil)) -> Nil) -> Nil {\n  next(#(leaf_"
          <> n
          <> "))\n}\n\n",
      )
    }),
    #("a record storing a parameter, read after a let rebinds its name", fn(n) {
      #(
        "stored_" <> n <> "(leaf_" <> n <> ")",
        "fn stored_"
          <> n
          <> "(idle_"
          <> n
          <> ": fn() -> Nil) -> Nil {\n  let box = Box(idle_"
          <> n
          <> ")\n  let idle_"
          <> n
          <> " = fn() { Nil }\n  let _ = idle_"
          <> n
          <> "\n  box.f()\n}\n\n",
      )
    }),
    #(
      "a record storing a function, read in a closure whose parameter shares its name",
      fn(n) {
        #(
          "let run = closed_" <> n <> "()\n  run(fn() { Nil })",
          "fn closed_"
            <> n
            <> "() -> fn(fn() -> Nil) -> Nil {\n  let box = Box(leaf_"
            <> n
            <> ")\n  fn(leaf_"
            <> n
            <> ") {\n    let _ = leaf_"
            <> n
            <> "\n    box.f()\n  }\n}\n\n",
        )
      },
    ),
    #("a case arm returning a closure over its pattern", fn(n) {
      #(
        "let run = arm_" <> n <> "()\n  run()",
        idle(n)
          <> "fn arm_"
          <> n
          <> "() -> fn() -> Nil {\n  case Ok(leaf_"
          <> n
          <> ") {\n    Ok(idle_"
          <> n
          <> ") -> fn() { idle_"
          <> n
          <> "() }\n    Error(_) -> fn() { Nil }\n  }\n}\n\n",
      )
    }),
    #("a capture over a binding sharing a pure function's name", fn(n) {
      #(
        "let #(idle_"
          <> n
          <> ") = #(leaf_"
          <> n
          <> ")\n  ffi.run_any(ignore_"
          <> n
          <> "(_, idle_"
          <> n
          <> "()))",
        idle(n)
          <> "fn ignore_"
          <> n
          <> "(_x: Int, _y: Nil) -> Nil {\n  Nil\n}\n\n",
      )
    }),
    #("a parameter called as a producer, sharing a pure producer's name", fn(n) {
      #(
        "producer_" <> n <> "(fn() { leaf_" <> n <> " })",
        "fn idle_"
          <> n
          <> "() -> fn() -> Nil {\n  fn() { Nil }\n}\n\nfn producer_"
          <> n
          <> "(idle_"
          <> n
          <> ": fn() -> fn() -> Nil) -> Nil {\n  idle_"
          <> n
          <> "()()\n}\n\n",
      )
    }),
    #("a factory whose parameter is rebound before the record is built", fn(n) {
      #(
        "let box = rebuilt_" <> n <> "(idle_" <> n <> ")\n  box.f()",
        idle(n)
          <> "fn rebuilt_"
          <> n
          <> "(f: fn() -> Nil) -> Box {\n  let _ = f\n  let f = leaf_"
          <> n
          <> "\n  Box(f)\n}\n\n",
      )
    }),
  ]
  let rebinding = [
    #("a case pattern rebinding a parameter's name", fn(n) {
      #(
        "pattern_" <> n <> "(idle_" <> n <> ")",
        idle(n)
          <> "fn pattern_"
          <> n
          <> "(idle_"
          <> n
          <> ": fn() -> Nil) -> Nil {\n  case Ok(leaf_"
          <> n
          <> ") {\n    Ok(idle_"
          <> n
          <> ") -> idle_"
          <> n
          <> "()\n    Error(_) -> Nil\n  }\n}\n\n",
      )
    }),
    #("a destructured let rebinding a parameter's name", fn(n) {
      #(
        "rebound_" <> n <> "(idle_" <> n <> ")",
        idle(n)
          <> "fn rebound_"
          <> n
          <> "(idle_"
          <> n
          <> ": fn() -> Nil) -> Nil {\n  let #(idle_"
          <> n
          <> ") = #(leaf_"
          <> n
          <> ")\n  idle_"
          <> n
          <> "()\n}\n\n",
      )
    }),
    #("a use parameter rebinding a parameter's name", fn(n) {
      #(
        "used_" <> n <> "(idle_" <> n <> ")",
        idle(n)
          <> "fn with_"
          <> n
          <> "(next: fn(fn() -> Nil) -> Nil) -> Nil {\n  next(leaf_"
          <> n
          <> ")\n}\n\nfn used_"
          <> n
          <> "(idle_"
          <> n
          <> ": fn() -> Nil) -> Nil {\n  let _ = idle_"
          <> n
          <> "\n  use idle_"
          <> n
          <> " <- with_"
          <> n
          <> "()\n  idle_"
          <> n
          <> "()\n}\n\n",
      )
    }),
    #(
      "a record storing a parameter, read in a closure whose parameter shares its name",
      fn(n) {
        #(
          "let run = closure_"
            <> n
            <> "(leaf_"
            <> n
            <> ")\n  run(idle_"
            <> n
            <> ")",
          idle(n)
            <> "fn closure_"
            <> n
            <> "(idle_"
            <> n
            <> ": fn() -> Nil) -> fn(fn() -> Nil) -> Nil {\n  let box = Box(idle_"
            <> n
            <> ")\n  fn(idle_"
            <> n
            <> ") {\n    let _ = idle_"
            <> n
            <> "\n    box.f()\n  }\n}\n\n",
        )
      },
    ),
  ]
  list.index_map(list.append(shapes, rebinding), fn(shape, offset) {
    let #(name, build) = shape
    let #(body, helpers) = build(int.to_string(first + offset))
    Case(name, body, helpers, "")
  })
}

// A linear congruential step, so a seed always draws the same cases.
fn next(seed: Int) -> Int {
  { seed * 1_103_515_245 + 12_345 } % 2_147_483_648
}

// A number below `bound` from a step's high bits.
fn draw(state: Int, bound: Int) -> Int {
  { state / 65_536 } % bound
}

// The fixed shapes, the foreign producers and the dual-target definitions,
// fixed: each reads differently, or runs different code, per target.
fn javascript_cases() -> List(Case) {
  [
    Case(
      "list relayed to its callback",
      "list.each([leaf_1], fn(f) { f() })",
      "",
      "",
    ),
    Case("record to a foreign runner", "ffi.run_box(Box(leaf_2))", "", ""),
    Case("list to a foreign runner", "ffi.run_all([leaf_3])", "", ""),
    Case(
      "foreign producer of a list, to a foreign runner",
      "ffi.run_all(ffi.printers(leaf_4))",
      "",
      "",
    ),
    Case(
      "external type built around a callback, to a foreign runner",
      "ffi.run_handle(ffi.handle(leaf_5))",
      "",
      "",
    ),
    Case(
      "Dynamic holding a callback, to a foreign runner",
      "ffi.run_dynamic(ffi.dynamic_of(leaf_6))",
      "",
      "",
    ),
    Case(
      "field value relayed by the standard library",
      "let config = Config(on_item: say_7)\n  list.each([\"x\"], config.on_item)",
      "fn say_7(_text: String) -> Nil {\n  leaf_7()\n}\n\n",
      "",
    ),
    Case(
      "definition gated to each target",
      "gated_8()",
      "@target(javascript)
fn gated_8() -> Nil {
  ffi.run_any(leaf_8)
}

@target(erlang)
fn gated_8() -> Nil {
  Nil
}

",
      "",
    ),
    Case("reference to a foreign runner", "ffi.run_any(leaf_9)", "", ""),
    Case(
      "closure in a record, to a foreign runner",
      "ffi.run_box(Box(fn() { leaf_10() }))",
      "",
      "",
    ),
    Case(
      "list a function returns, to a foreign runner",
      "ffi.run_all(exported_11())",
      "pub fn exported_11() -> List(fn() -> Nil) {
  [leaf_11]
}

",
      "",
    ),
    Case(
      "external whose fallback body runs nothing",
      "run_dual_12([leaf_12])",
      "@external(javascript, \"./app_ffi.mjs\", \"run_all\")
pub fn run_dual_12(fs: List(fn() -> Nil)) -> Nil {
  let _ = fs
  Nil
}

",
      "assume app.run_dual_12 : []\n",
    ),
    Case(
      "external whose fallback body runs its argument",
      "ffi.run_fallback([leaf_13])",
      "",
      "",
    ),
  ]
}

// Projects

// The counterexamples one project's run turned up, and how many of its cases
// printed a label at all.
type Outcome {
  Outcome(failures: List(String), printed: Int, total: Int)
}

fn validate(
  graded: String,
  directory: String,
  target: String,
  cases: List(Case),
) -> Outcome {
  write_project(directory, target, cases)
  case observed(directory, target) {
    Error(output) ->
      Outcome(
        [target <> " project did not run:\n" <> output],
        0,
        list.length(cases),
      )
    Ok(observed) -> compare(graded, directory, target, cases, observed)
  }
}

fn compare(
  graded: String,
  directory: String,
  target: String,
  cases: List(Case),
  observed: Dict(String, Set(String)),
) -> Outcome {
  let answers = answers(graded, directory)
  let intervals =
    list.index_map(cases, fn(case_, index) {
      #("case_" <> int.to_string(index + 1), case_.name)
    })
  let failures =
    [#("main", "the whole run"), ..intervals]
    |> list.filter_map(fn(interval) {
      let #(function, name) = interval
      let printed = dict.get(observed, function) |> result.unwrap(set.new())
      let answer = dict.get(answers, function) |> result.unwrap(set.new())
      let missing =
        set.to_list(printed)
        |> list.filter(fn(label) { !set.contains(answer, label) })
      case missing, set.contains(answer, "Unknown") {
        [], _ | _, True -> Error(Nil)
        _, False ->
          Ok(
            target
            <> " "
            <> function
            <> " ("
            <> name
            <> "): printed "
            <> labels(printed)
            <> ", answered "
            <> labels(answer),
          )
      }
    })
  let printed = dict.size(dict.delete(observed, "main"))
  Outcome(failures, printed, list.length(cases))
}

fn labels(values: Set(String)) -> String {
  "["
  <> string.join(list.sort(set.to_list(values), string.compare), ", ")
  <> "]"
}

fn write_project(directory: String, target: String, cases: List(Case)) -> Nil {
  write_project_importing(directory, target, cases, "")
}

// The same, with `imports` beside the modules every project imports.
fn write_project_importing(
  directory: String,
  target: String,
  cases: List(Case),
  imports: String,
) -> Nil {
  let count = list.length(cases)
  let leaves = numbers(count)
  let source =
    "import app/fallback\nimport app/ffi\nimport gleam/dict\nimport gleam/list\n"
    <> imports
    <> "\npub type Box {\n  Box(f: fn() -> Nil)\n}\n\npub type Config {\n  Config(on_item: fn(String) -> Nil)\n}\n\n"
    <> string.concat(
      list.map(leaves, fn(n) {
        let suffix = int.to_string(n)
        "@external(erlang, \"app_leaves\", \"leaf_"
        <> suffix
        <> "\")\n@external(javascript, \"./app_leaves.mjs\", \"leaf_"
        <> suffix
        <> "\")\npub fn leaf_"
        <> suffix
        <> "() -> Nil\n\npub fn box_"
        <> suffix
        <> "() -> Box {\n  Box(leaf_"
        <> suffix
        <> ")\n}\n\n"
      }),
    )
    <> string.concat(
      list.index_map(cases, fn(case_, index) {
        let suffix = int.to_string(index + 1)
        case_.helpers
        <> "pub fn case_"
        <> suffix
        <> "() -> Nil {\n  "
        <> case_.body
        <> "\n  Nil\n}\n\n"
      }),
    )
    <> "pub fn main() -> Nil {\n"
    <> string.concat(
      list.map(leaves, fn(n) {
        let suffix = int.to_string(n)
        "  ffi.mark(\"BEGIN "
        <> suffix
        <> "\")\n  case_"
        <> suffix
        <> "()\n  ffi.mark(\"END "
        <> suffix
        <> "\")\n"
      }),
    )
    <> "}\n"
  let spec =
    string.concat(
      list.map(leaves, fn(n) {
        let suffix = int.to_string(n)
        "assume app.leaf_" <> suffix <> " : [L" <> suffix <> "]\n"
      }),
    )
    <> string.concat(list.map(cases, fn(case_) { case_.spec }))
    <> "assume app/ffi.mark : [Stdout]\nassume app/ffi : []\n"
  let leaves_erl =
    "-module(app_leaves).\n-export(["
    <> string.join(
      list.map(leaves, fn(n) { "leaf_" <> int.to_string(n) <> "/0" }),
      ", ",
    )
    <> "]).\n"
    <> string.concat(
      list.map(leaves, fn(n) {
        let suffix = int.to_string(n)
        "leaf_"
        <> suffix
        <> "() -> io:format(\"HIT "
        <> suffix
        <> "~n\"), nil.\n"
      }),
    )
  let leaves_mjs =
    string.concat(
      list.map(leaves, fn(n) {
        let suffix = int.to_string(n)
        "export function leaf_"
        <> suffix
        <> "() { console.log(\"HIT "
        <> suffix
        <> "\"); }\n"
      }),
    )
  write(directory <> "/gleam.toml", gleam_toml(target))
  write(directory <> "/app.graded", spec)
  write(directory <> "/src/app.gleam", source)
  write(directory <> "/src/app/ffi.gleam", ffi_module)
  write(directory <> "/src/app/fallback.gleam", fallback_module)
  write(directory <> "/src/app_ffi.erl", ffi_erl)
  write(directory <> "/src/app_ffi.mjs", ffi_mjs)
  write(directory <> "/src/app_leaves.erl", leaves_erl)
  write(directory <> "/src/app_leaves.mjs", leaves_mjs)
}

// The Erlang project is read for both targets, so an external declared for
// JavaScript and its Gleam fallback body that runs here are both in reach.
fn gleam_toml(target: String) -> String {
  let graded_targets = case target {
    "erlang" -> "\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n"
    _ -> ""
  }
  "name = \"app\"\nversion = \"1.0.0\"\ntarget = \""
  <> target
  <> "\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n"
  <> graded_targets
}

const ffi_module =
  "import gleam/dynamic.{type Dynamic}
import gleam/list

pub type Handle

@external(erlang, \"app_ffi\", \"mark\")
@external(javascript, \"../app_ffi.mjs\", \"mark\")
pub fn mark(text: String) -> Nil

@external(erlang, \"app_ffi\", \"run_all\")
@external(javascript, \"../app_ffi.mjs\", \"run_all\")
pub fn run_all(fs: List(fn() -> Nil)) -> Nil

@external(erlang, \"app_ffi\", \"run_first\")
@external(javascript, \"../app_ffi.mjs\", \"run_first\")
pub fn run_first(pair: #(fn() -> Nil, Int)) -> Nil

@external(erlang, \"app_ffi\", \"run_box\")
@external(javascript, \"../app_ffi.mjs\", \"run_box\")
pub fn run_box(box: a) -> Nil

@external(erlang, \"app_ffi\", \"run_boxes\")
@external(javascript, \"../app_ffi.mjs\", \"run_boxes\")
pub fn run_boxes(boxes: List(a)) -> Nil

@external(erlang, \"app_ffi\", \"project\")
@external(javascript, \"../app_ffi.mjs\", \"project\")
pub fn project(xs: List(a), f: fn(a) -> b) -> List(b)

@external(erlang, \"app_ffi\", \"run_ok\")
@external(javascript, \"../app_ffi.mjs\", \"run_ok\")
pub fn run_ok(result: Result(fn() -> Nil, Nil)) -> Nil

@external(erlang, \"app_ffi\", \"run_any\")
@external(javascript, \"../app_ffi.mjs\", \"run_any\")
pub fn run_any(value: a) -> Nil

@external(erlang, \"app_ffi\", \"run_values\")
@external(javascript, \"../app_ffi.mjs\", \"run_values\")
pub fn run_values(map: a) -> Nil

@external(erlang, \"app_ffi\", \"printers\")
@external(javascript, \"../app_ffi.mjs\", \"printers\")
pub fn printers(leaf: fn() -> Nil) -> List(fn() -> Nil)

@external(erlang, \"app_ffi\", \"handle\")
@external(javascript, \"../app_ffi.mjs\", \"handle\")
pub fn handle(leaf: fn() -> Nil) -> Handle

@external(erlang, \"app_ffi\", \"run_handle\")
@external(javascript, \"../app_ffi.mjs\", \"run_handle\")
pub fn run_handle(handle: Handle) -> Nil

@external(erlang, \"app_ffi\", \"dynamic_of\")
@external(javascript, \"../app_ffi.mjs\", \"dynamic_of\")
pub fn dynamic_of(leaf: fn() -> Nil) -> Dynamic

@external(erlang, \"app_ffi\", \"run_dynamic\")
@external(javascript, \"../app_ffi.mjs\", \"run_dynamic\")
pub fn run_dynamic(value: Dynamic) -> Nil

@external(erlang, \"app_ffi\", \"run_fields\")
@external(javascript, \"../app_ffi.mjs\", \"run_fields\")
pub fn run_fields(value: a) -> Nil

@external(erlang, \"app_ffi\", \"hit\")
@external(javascript, \"../app_ffi.mjs\", \"hit\")
pub fn hit(label: Int) -> Nil

@external(erlang, \"app_ffi\", \"ignore\")
pub fn run_fallback(fs: List(fn() -> Nil)) -> Nil {
  list.each(fs, fn(f) { f() })
}
"

// Externals whose Gleam fallback body runs on Erlang, in a module no
// module-level line covers, so each one's own line answers beside its body.
const fallback_module =
  "@external(javascript, \"../app_ffi.mjs\", \"run_shared\")
pub fn run_shared(f: fn() -> Nil, g: fn() -> Nil) -> Nil {
  f()
  g()
}

@external(javascript, \"../app_ffi.mjs\", \"run_crossed\")
pub fn run_crossed(f: fn() -> Nil, g: fn() -> Nil) -> Nil {
  let _ = g
  f()
}
"

const ffi_erl =
  "-module(app_ffi).
-export([mark/1, run_all/1, run_first/1, run_box/1, run_boxes/1, project/2,
         run_ok/1, run_any/1, run_values/1, printers/1, handle/1,
         run_handle/1, dynamic_of/1, run_dynamic/1, ignore/1, run_fields/1,
         zero_of/1, hit/1]).
mark(Text) -> io:format(\"~s~n\", [Text]), nil.
run_all(Fs) -> lists:foreach(fun(F) -> F() end, Fs), nil.
run_first({F, _}) -> F(), nil.
run_box({box, F}) -> F(), nil.
run_boxes(Bs) -> lists:foreach(fun({box, F}) -> F() end, Bs), nil.
project(Xs, F) -> lists:map(F, Xs).
run_ok({ok, F}) -> F(), nil;
run_ok(_) -> nil.
run_any(F) when is_function(F, 0) -> F(), nil;
run_any(F) when is_function(F, 1) -> F(0), nil;
run_any(_) -> nil.
run_values(M) -> lists:foreach(fun(F) -> F() end, maps:values(M)), nil.
printers(F) -> [F].
handle(F) -> {handle, F}.
run_handle({handle, F}) -> F(), nil.
dynamic_of(F) -> F.
run_dynamic(F) when is_function(F, 0) -> F(), nil;
run_dynamic(_) -> nil.
ignore(_) -> nil.
run_fields(T) when is_tuple(T) ->
    lists:foreach(fun(F) when is_function(F, 0) -> F(); (_) -> nil end,
                  tl(tuple_to_list(T))),
    nil;
run_fields(_) -> nil.
zero_of(_) -> 0.
hit(Label) -> io:format(\"HIT ~p~n\", [Label]), nil.
"

const ffi_mjs =
  "import { toList } from \"./gleam.mjs\";
export function mark(text) { console.log(text); }
export function run_all(fs) { for (const f of fs) f(); }
export function run_first(pair) { pair[0](); }
export function run_box(box) { box.f(); }
export function run_boxes(boxes) { for (const box of boxes) box.f(); }
export function project(xs, f) { return toList(xs.toArray().map(f)); }
export function run_shared(f, g) { f(); g(); }
export function run_crossed(f, _g) { f(); }
export function run_ok(result) { if (result.isOk()) result[0](); }
export function run_any(value) { if (typeof value === \"function\") value(0); }
export function run_values(map) { map.forEach((value) => value()); }
export function printers(f) { return toList([f]); }
export function handle(f) { return { run: f }; }
export function run_handle(handle) { handle.run(); }
export function dynamic_of(f) { return f; }
export function run_dynamic(value) { if (typeof value === \"function\") value(); }
export function run_fields(value) { if (value && typeof value === \"object\") for (const key of Object.keys(value)) if (typeof value[key] === \"function\") value[key](); }
export function printer_of(label) { return () => console.log(\"HIT \" + label); }
export function holder_of(label) { return { run: () => console.log(\"HIT \" + label) }; }
export function hit(label) { console.log(\"HIT \" + label); }
export function ignore(_value) { return undefined; }
"

// What graded answers for each case, from the spec `infer` writes.
fn answers(graded: String, directory: String) -> Dict(String, Set(String)) {
  infer(graded, directory)
  read(directory <> "/app.graded")
  |> string.split("\n")
  |> list.filter_map(fn(line) {
    use rest <- result.try(case line {
      "effects app." <> rest -> Ok(rest)
      _ -> Error(Nil)
    })
    use #(function, effects) <- result.map(string.split_once(rest, " : "))
    #(function, effect_labels(effects))
  })
  |> dict.from_list
}

fn effect_labels(effects: String) -> Set(String) {
  effects
  |> string.replace("[", "")
  |> string.replace("]", "")
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(label) { label != "" })
  |> set.from_list
}

// The labels each case printed while it ran.
fn observed(
  directory: String,
  target: String,
) -> Result(Dict(String, Set(String)), String) {
  use output <- result.map(
    shellout.command(
      run: "gleam",
      with: ["run", "--target", target],
      in: directory,
      opt: [],
    )
    |> result.map_error(fn(failure) { failure.1 }),
  )
  let #(observed, _) =
    output
    |> string.split("\n")
    |> list.fold(#(dict.new(), ""), fn(state, line) {
      let #(observed, current) = state
      case string.split(string.trim(line), " ") {
        ["BEGIN", n] -> #(observed, "case_" <> n)
        ["END", _] -> #(observed, "")
        ["HIT", n] -> {
          let observed = record(observed, "main", "L" <> n)
          case current {
            "" -> #(observed, current)
            _ -> #(record(observed, current, "L" <> n), current)
          }
        }
        _ -> state
      }
    })
  observed
}

fn record(
  observed: Dict(String, Set(String)),
  interval: String,
  label: String,
) -> Dict(String, Set(String)) {
  dict.upsert(observed, interval, fn(existing) {
    case existing {
      option.Some(labels) -> set.insert(labels, label)
      option.None -> set.from_list([label])
    }
  })
}

// The module-boundary cases

// A producer's summary read in another module of the same package: a producer
// storing a field of its argument whose function starts at the same offset as
// the consumer's function of the same parameter name, the same one offset
// later, and a producer storing its own private function where the consumer
// has a pure one of the same name. Each producer's function prints through a
// leaf of its own module.
fn boundary_cases(graded: String, directory: String) -> Outcome {
  let cases = [
    Case("a stored field of a parameter, at the consumer's offset", "", "", ""),
    Case("a stored field of a parameter, one offset later", "", "", ""),
    Case("a producer's private function named like the consumer's", "", "", ""),
  ]
  let app =
    "import app/aligned\nimport app/ffi\nimport app/leaves\nimport app/model\nimport app/named\nimport app/shifted\n\nfn loud() -> Nil {\n  Nil\n}\n\n"
    <> "pub fn go_1(f: model.Task) -> Nil {\n  let _ = f\n  model.invoke(aligned.make(model.Task(run: leaves.leaf_1)))\n}\n\n"
    <> "pub fn go_2(f: model.Task) -> Nil {\n  let _ = f\n  model.invoke(shifted.make(model.Task(run: leaves.leaf_2)))\n}\n\n"
    <> "pub fn case_1() -> Nil {\n  go_1(model.Task(run: fn() { Nil }))\n}\n\n"
    <> "pub fn case_2() -> Nil {\n  go_2(model.Task(run: fn() { Nil }))\n}\n\n"
    <> "pub fn case_3() -> Nil {\n  let _ = loud\n  model.invoke(named.make())\n}\n\n"
    <> "pub fn main() -> Nil {\n"
    <> string.concat(
      list.map([1, 2, 3], fn(n) {
        let suffix = int.to_string(n)
        "  ffi.mark(\"BEGIN "
        <> suffix
        <> "\")\n  case_"
        <> suffix
        <> "()\n  ffi.mark(\"END "
        <> suffix
        <> "\")\n"
      }),
    )
    <> "}\n"
  let producer =
    "pub fn make(f: model.Task) -> model.Box {\n  model.Box(task: model.Task(run: f.run))\n}\n"
  write(directory <> "/gleam.toml", gleam_toml("erlang"))
  write(
    directory <> "/app.graded",
    "assume app/leaves.leaf_1 : [L1]\nassume app/leaves.leaf_2 : [L2]\nassume app/leaves.leaf_3 : [L3]\nassume app/ffi.mark : [Stdout]\nassume app/ffi : []\n",
  )
  write(directory <> "/src/app.gleam", app)
  write(
    directory <> "/src/app/model.gleam",
    "pub type Task {\n  Task(run: fn() -> Nil)\n}\n\npub type Box {\n  Box(task: Task)\n}\n\npub fn invoke(b: Box) -> Nil {\n  let task = b.task\n  task.run()\n}\n",
  )
  write(
    directory <> "/src/app/aligned.gleam",
    padded("import app/model\n", producer, offset_of(app, "pub fn go_1(")),
  )
  write(
    directory <> "/src/app/shifted.gleam",
    padded("import app/model\n", producer, offset_of(app, "pub fn go_2(") + 1),
  )
  write(
    directory <> "/src/app/named.gleam",
    "import app/leaves\nimport app/model\n\nfn loud() -> Nil {\n  leaves.leaf_3()\n}\n\npub fn make() -> model.Box {\n  model.Box(task: model.Task(run: loud))\n}\n",
  )
  write(
    directory <> "/src/app/leaves.gleam",
    string.concat(
      list.map([1, 2, 3], fn(n) {
        let suffix = int.to_string(n)
        "@external(erlang, \"app_leaves\", \"leaf_"
        <> suffix
        <> "\")\npub fn leaf_"
        <> suffix
        <> "() -> Nil\n\n"
      }),
    ),
  )
  write(directory <> "/src/app/ffi.gleam", ffi_module)
  write(directory <> "/src/app_ffi.erl", ffi_erl)
  write(
    directory <> "/src/app_leaves.erl",
    "-module(app_leaves).\n-export([leaf_1/0, leaf_2/0, leaf_3/0]).\nleaf_1() -> io:format(\"HIT 1~n\"), nil.\nleaf_2() -> io:format(\"HIT 2~n\"), nil.\nleaf_3() -> io:format(\"HIT 3~n\"), nil.\n",
  )
  case observed(directory, "erlang") {
    Error(output) ->
      Outcome(
        ["module-boundary project did not run:\n" <> output],
        0,
        list.length(cases),
      )
    Ok(observed) -> compare(graded, directory, "erlang", cases, observed)
  }
}

// The two-target cases

// Every two-target project, run on both targets: the definitions gated to each
// target together in one, and each pair that alone types a value differently
// on the other target in a project of its own, with no gated function beside
// it.
fn two_target_cases(graded: String, root: String) -> Outcome {
  let outcomes = [
    validate_both(
      graded,
      root <> "/gated",
      gated_cases(),
      "import app/pairs\n",
      [#("src/app/pairs.gleam", pairs_module)],
    ),
    validate_both(graded, root <> "/constant", [constant_case()], "", []),
    validate_both(graded, root <> "/alias", [alias_case()], "", []),
    dependency_case(graded, root <> "/dependency"),
    validate_both(graded, root <> "/spaced", [spaced_case()], "", []),
    mixed_case(graded, root <> "/mixed_alias", True),
    mixed_case(graded, root <> "/mixed_custom", False),
    mixed_dependency_case(graded, root <> "/mixed_dep_alias", True),
    mixed_dependency_case(graded, root <> "/mixed_dep_custom", False),
  ]
  list.fold(outcomes, Outcome([], 0, 0), fn(acc, outcome) {
    Outcome(
      list.append(acc.failures, outcome.failures),
      acc.printed + outcome.printed,
      acc.total + outcome.total,
    )
  })
}

// A project read on both targets, run on each, with every label either run
// printed attributed as one run's would be.
fn validate_both(
  graded: String,
  directory: String,
  cases: List(Case),
  imports: String,
  modules: List(#(String, String)),
) -> Outcome {
  write_project_importing(directory, "erlang", cases, imports)
  list.each(modules, fn(module) {
    write(directory <> "/" <> module.0, module.1)
  })
  run_both(graded, directory, cases)
}

fn run_both(graded: String, directory: String, cases: List(Case)) -> Outcome {
  case observed(directory, "erlang"), observed(directory, "javascript") {
    Ok(erlang), Ok(javascript) ->
      compare(
        graded,
        directory,
        "two-target",
        cases,
        dict.combine(erlang, javascript, set.union),
      )
    Error(output), _ | _, Error(output) ->
      Outcome(
        ["two-target project did not run:\n" <> output],
        0,
        list.length(cases),
      )
  }
}

// Definitions gated to each target, the variant printing nothing first.
fn gated_cases() -> List(Case) {
  [
    Case(
      "a value whose type differs by target",
      "ffi.run_any(value_1())",
      "@target(erlang)
fn value_1() -> Int {
  0
}

@target(javascript)
fn value_1() -> fn() -> Nil {
  leaf_1
}

",
      "",
    ),
    Case(
      "a type defined differently on each target",
      "ffi.run_fields(value_2())",
      "@target(javascript)
pub type Held2 {
  Held2(Int)
}

@target(erlang)
pub type Held2 {
  Held2(fn() -> Nil)
}

@target(erlang)
fn value_2() -> Held2 {
  Held2(leaf_2)
}

@target(javascript)
fn value_2() -> Held2 {
  Held2(0)
}

",
      "",
    ),
    Case(
      "a foreign function taking a callback on one target and a record on the other",
      "keep_3(arg_3())",
      "pub type Holder3 {
  Holder3(run: fn() -> Nil)
}

@target(erlang)
@external(erlang, \"app_ffi\", \"ignore\")
fn keep_3(f: fn() -> Nil) -> Nil

@target(javascript)
@external(javascript, \"./app_ffi.mjs\", \"run_fields\")
fn keep_3(f: Holder3) -> Nil

@target(erlang)
fn arg_3() -> fn() -> Nil {
  leaf_3
}

@target(javascript)
fn arg_3() -> Holder3 {
  Holder3(leaf_3)
}

",
      "assume app.keep_3(f: [f]) : []\n",
    ),
    Case(
      "a foreign function whose parameter's alias is a callback on one target",
      "keep_4(arg_4())",
      "pub type Holder4 {
  Holder4(run: fn() -> Nil)
}

@target(erlang)
type Act4 =
  fn() -> Nil

@target(javascript)
type Act4 =
  Holder4

@external(erlang, \"app_ffi\", \"ignore\")
@external(javascript, \"./app_ffi.mjs\", \"run_fields\")
fn keep_4(f: Act4) -> Nil

@target(erlang)
fn arg_4() -> Act4 {
  leaf_4
}

@target(javascript)
fn arg_4() -> Act4 {
  Holder4(leaf_4)
}

",
      "assume app.keep_4(f: [f]) : []\n",
    ),
    Case(
      "a function gated to each target, called",
      "get_5()",
      "@target(erlang)
fn get_5() -> Nil {
  Nil
}

@target(javascript)
fn get_5() -> Nil {
  leaf_5()
}

",
      "",
    ),
    Case(
      "a function gated to each target, passed to a runner",
      "ffi.run_any(get_6)",
      "@target(erlang)
fn get_6() -> Nil {
  Nil
}

@target(javascript)
fn get_6() -> Nil {
  leaf_6()
}

",
      "",
    ),
    Case(
      "a function gated to each target returning a different argument",
      "ffi.run_box(pick_7(Box(quiet_7), Box(leaf_7)))",
      "@target(erlang)
fn pick_7(a: Box, b: Box) -> Box {
  let _ = b
  a
}

@target(javascript)
fn pick_7(a: Box, b: Box) -> Box {
  let _ = a
  b
}

fn quiet_7() -> Nil {
  Nil
}

",
      "",
    ),
    Case(
      "another module's function gated to each target returning a different argument",
      "ffi.run_fields(pairs.pick(pairs.Holder(quiet_8), pairs.Holder(leaf_8)))",
      "fn quiet_8() -> Nil {
  Nil
}

",
      "",
    ),
    Case(
      "another module's function gated to each target, called",
      "pairs.get()",
      "",
      "assume app/pairs.leaf_9 : [L9]\n",
    ),
  ]
}

// The other module of the gated project.
const pairs_module =
  "pub type Holder {
  Holder(run: fn() -> Nil)
}

@target(erlang)
pub fn pick(a: Holder, b: Holder) -> Holder {
  let _ = b
  a
}

@target(javascript)
pub fn pick(a: Holder, b: Holder) -> Holder {
  let _ = a
  b
}

@external(erlang, \"app_leaves\", \"leaf_9\")
@external(javascript, \"../app_leaves.mjs\", \"leaf_9\")
fn leaf_9() -> Nil

@target(erlang)
pub fn get() -> Nil {
  Nil
}

@target(javascript)
pub fn get() -> Nil {
  leaf_9()
}
"

fn constant_case() -> Case {
  Case(
    "a constant defined once per target",
    "ffi.run_any(value_1)",
    "@target(erlang)
const value_1 = 0

@target(javascript)
const value_1 = leaf_1

",
    "",
  )
}

fn alias_case() -> Case {
  Case(
    "an alias defined once per target",
    "ffi.run_any(held_1(1))",
    "@target(erlang)
type Held1 =
  Int

@target(javascript)
type Held1 =
  fn() -> Nil

@external(erlang, \"app_ffi\", \"zero_of\")
@external(javascript, \"./app_ffi.mjs\", \"printer_of\")
fn held_1(label: Int) -> Held1

",
    "assume app.held_1 : []\n",
  )
}

// A path dependency defining one function once per target, read from a
// consumer that gates nothing.
fn dependency_case(graded: String, root: String) -> Outcome {
  let cases = [
    Case(
      "a dependency's function defined once per target",
      "ffi.run_any(pairdep.value())",
      "",
      "",
    ),
  ]
  write(
    root <> "/pairdep/gleam.toml",
    "name = \"pairdep\"\nversion = \"1.0.0\"\n",
  )
  write(root <> "/pairdep/pairdep.graded", "assume pairdep.value : []\n")
  write(
    root <> "/pairdep/src/pairdep.gleam",
    "@target(erlang)
pub fn value() -> Int {
  0
}

@target(javascript)
pub fn value() -> fn() -> Nil {
  printer(1)
}

@target(javascript)
@external(javascript, \"./pairdep_ffi.mjs\", \"printer_of\")
fn printer(label: Int) -> fn() -> Nil
",
  )
  write(
    root <> "/pairdep/src/pairdep_ffi.mjs",
    "export function printer_of(label) { return () => console.log(\"HIT \" + label); }\n",
  )
  let directory = root <> "/app"
  write_project_importing(directory, "erlang", cases, "import pairdep\n")
  write(
    directory <> "/gleam.toml",
    "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\npairdep = { path = \"../pairdep\" }\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
  )
  run_both(graded, directory, cases)
}

// A function defined once per target whose `@target` attributes are written
// with spaces and newlines the compiler accepts: the package's only pair.
fn spaced_case() -> Case {
  Case(
    "a pair spelled with spaces between @target and its target",
    "get_1()",
    "@target (erlang)\nfn get_1() -> Nil {\n  Nil\n}\n\n@target\n(javascript)\nfn get_1() -> Nil {\n  leaf_1()\n}\n\n",
    "",
  )
}

// A type alias on one target and a custom type of the same name on the other,
// in either order, made by one foreign function: the package's only pair.
fn mixed_source(name: String, alias_first: Bool, public: Bool) -> String {
  let visibility = case public {
    True -> "pub "
    False -> ""
  }
  let alias =
    "@target(erlang)\n" <> visibility <> "type " <> name <> " =\n  Int\n\n"
  let custom =
    "@target(javascript)\n"
    <> visibility
    <> "type "
    <> name
    <> " {\n  "
    <> name
    <> "(run: fn() -> Nil)\n}\n\n"
  case alias_first {
    True -> alias <> custom
    False -> custom <> alias
  }
}

fn mixed_case(graded: String, directory: String, alias_first: Bool) -> Outcome {
  let case_ =
    Case(
      "an alias and a custom type of one name, one per target",
      "ffi.run_fields(make_held())",
      mixed_source("Held", alias_first, True)
        <> "@external(erlang, \"app_ffi\", \"zero_of\")\n@external(javascript, \"./app_ffi.mjs\", \"holder_of\")\nfn make_holder(label: Int) -> Held\n\nfn make_held() -> Held {\n  make_holder(1)\n}\n\n",
      "assume app.make_holder : []\n",
    )
  validate_both(graded, directory, [case_], "", [])
}

// The same pair defined by a path dependency, its value made there and handed
// to the consumer.
fn mixed_dependency_case(
  graded: String,
  root: String,
  alias_first: Bool,
) -> Outcome {
  let cases = [
    Case(
      "a dependency's alias and custom type of one name, one per target",
      "ffi.run_fields(typedep.make())",
      "",
      "",
    ),
  ]
  write(
    root <> "/typedep/gleam.toml",
    "name = \"typedep\"\nversion = \"1.0.0\"\n",
  )
  write(root <> "/typedep/typedep.graded", "assume typedep.make : []\n")
  write(
    root <> "/typedep/src/typedep.gleam",
    mixed_source("Held", alias_first, True)
      <> "@external(erlang, \"typedep_ffi\", \"make\")\n@external(javascript, \"./typedep_ffi.mjs\", \"make\")\npub fn make() -> Held\n",
  )
  write(
    root <> "/typedep/src/typedep_ffi.erl",
    "-module(typedep_ffi).\n-export([make/0]).\nmake() -> 0.\n",
  )
  write(
    root <> "/typedep/src/typedep_ffi.mjs",
    "export function make() { return { run: () => console.log(\"HIT 1\") }; }\n",
  )
  let directory = root <> "/app"
  write_project_importing(directory, "erlang", cases, "import typedep\n")
  write(
    directory <> "/gleam.toml",
    "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\ntypedep = { path = \"../typedep\" }\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
  )
  run_both(graded, directory, cases)
}

// The published-spec boundary

// The functions each published dependency defines once per target: labels
// permuted, a parameter renamed, unequal arity, one variant running nothing,
// and two taking no argument, one variant of each printing.
fn published_pairs(dep: String) -> String {
  "@external(erlang, \"" <> dep <> "_hits\", \"hit\")
@external(javascript, \"./" <> dep <> "_hits.mjs\", \"hit\")
pub fn hit() -> Nil

@target(erlang)
pub fn run_5() -> Nil {
  Nil
}

@target(javascript)
pub fn run_5() -> Nil {
  hit()
}

@target(erlang)
pub fn run_6() -> Nil {
  hit()
}

@target(javascript)
pub fn run_6() -> Nil {
  Nil
}

@external(erlang, \"" <> dep <> "_hits\", \"second\")
@external(javascript, \"./" <> dep <> "_hits.mjs\", \"second\")
pub fn run_10(first: fn() -> Nil, second: fn() -> Nil) -> fn() -> Nil

" <> published_callback_pairs
}

// What each published dependency's `hit` prints, as the label `label`.
fn published_hits(dep: String, label: Int) -> List(#(String, String)) {
  let label = int.to_string(label)
  [
    #(
      dep <> "_hits.erl",
      "-module("
        <> dep
        <> "_hits).\n-export([hit/0, second/2]).\nhit() -> io:format(\"HIT "
        <> label
        <> "~n\"), nil.\nsecond(_, B) -> B.\n",
    ),
    #(
      dep <> "_hits.mjs",
      "export function hit() { console.log(\"HIT "
        <> label
        <> "\"); }\nexport function second(_a, b) { return b; }\n",
    ),
  ]
}

const published_callback_pairs =
  "@target(erlang)
pub fn run_1(first a: fn() -> Nil, second b: fn() -> Nil) -> Nil {
  let _ = b
  a()
}

@target(javascript)
pub fn run_1(second a: fn() -> Nil, first b: fn() -> Nil) -> Nil {
  let _ = b
  a()
}

@target(erlang)
pub fn run_2(a: fn() -> Nil) -> Nil {
  a()
}

@target(javascript)
pub fn run_2(b: fn() -> Nil) -> Nil {
  b()
}

@target(erlang)
pub fn run_3(first a: fn() -> Nil) -> Nil {
  a()
}

@target(javascript)
pub fn run_3(first a: fn() -> Nil, second b: fn() -> Nil) -> Nil {
  let _ = a
  b()
}

@target(erlang)
pub fn run_4(a: fn() -> Nil) -> Nil {
  let _ = a
  Nil
}

@target(javascript)
pub fn run_4(b: fn() -> Nil) -> Nil {
  b()
}

@target(erlang)
pub fn run_7(f: fn() -> Nil) -> fn() -> Nil {
  f
}

@target(javascript)
pub fn run_7(g: fn() -> Nil) -> fn() -> Nil {
  g
}

@target(erlang)
pub fn run_8(first: fn() -> Nil, second: fn() -> Nil) -> fn() -> Nil {
  let _ = second
  first
}

@target(javascript)
pub fn run_8(second: fn() -> Nil, first: fn() -> Nil) -> fn() -> Nil {
  let _ = first
  second
}

@target(erlang)
pub fn run_9(f: fn() -> Nil, g: fn() -> Nil) -> fn() -> Nil {
  let _ = g
  f
}

@target(javascript)
pub fn run_9(g: fn() -> Nil, h: fn() -> Nil) -> fn() -> Nil {
  let _ = h
  g
}
"

// The cases a consumer runs against the dependency `dep`, the first numbered
// `first`.
fn published_cases(dep: String, first: Int) -> List(Case) {
  let leaf = fn(n) { "leaf_" <> int.to_string(n) }
  let quiet = fn(n) { "quiet_" <> int.to_string(n) }
  let with_quiet = fn(n, helpers) {
    "fn " <> quiet(n) <> "() -> Nil {\n  Nil\n}\n\n" <> helpers
  }
  let numbered = fn(index, build: fn(Int) -> Case) { build(first + index) }
  [
    numbered(0, fn(n) {
      Case(
        dep <> ".run_1 by label, printing callback first",
        dep <> ".run_1(first: " <> leaf(n) <> ", second: " <> quiet(n) <> ")",
        with_quiet(n, ""),
        "",
      )
    }),
    numbered(1, fn(n) {
      Case(
        dep <> ".run_1 by label, printing callback second",
        dep <> ".run_1(first: " <> quiet(n) <> ", second: " <> leaf(n) <> ")",
        with_quiet(n, ""),
        "",
      )
    }),
    numbered(2, fn(n) {
      Case(
        dep <> ".run_1 by position, printing callback first",
        dep <> ".run_1(" <> leaf(n) <> ", " <> quiet(n) <> ")",
        with_quiet(n, ""),
        "",
      )
    }),
    numbered(3, fn(n) {
      Case(
        dep <> ".run_2, a parameter each variant names differently",
        dep <> ".run_2(" <> leaf(n) <> ")",
        "",
        "",
      )
    }),
    numbered(4, fn(n) {
      let s = int.to_string(n)
      Case(
        dep <> ".run_3, unequal arity, each target passing its own count",
        "call_" <> s <> "()",
        with_quiet(
          n,
          gated(
            "erlang",
            "fn call_"
              <> s
              <> "() -> Nil {\n  "
              <> dep
              <> ".run_3(first: "
              <> quiet(n)
              <> ")\n}\n\n",
          )
            <> gated(
            "javascript",
            "fn call_"
              <> s
              <> "() -> Nil {\n  "
              <> dep
              <> ".run_3(first: "
              <> quiet(n)
              <> ", second: "
              <> leaf(n)
              <> ")\n}\n\n",
          ),
        ),
        "",
      )
    }),
    numbered(5, fn(n) {
      Case(
        dep <> ".run_4, one variant running nothing",
        dep <> ".run_4(" <> leaf(n) <> ")",
        "",
        "",
      )
    }),
    numbered(6, fn(_) {
      Case(
        dep <> ".run_5, its JavaScript variant printing",
        dep <> ".run_5()",
        "",
        "",
      )
    }),
    numbered(7, fn(_) {
      Case(
        dep <> ".run_6, its Erlang variant printing",
        dep <> ".run_6()",
        "",
        "",
      )
    }),
    numbered(8, fn(n) {
      Case(
        dep <> ".run_7, a returned callback each variant names differently",
        "let made = " <> dep <> ".run_7(" <> leaf(n) <> ")\n  made()",
        "",
        // The consumer's line states its effects, the dependency what it
        // returns.
        "assume " <> dep <> ".run_7 : []\n",
      )
    }),
    numbered(9, fn(n) {
      Case(
        dep
          <> ".run_8, a quiet first argument beside an unused printer, the pair naming them in swapped order",
        "let made = "
          <> dep
          <> ".run_8("
          <> quiet(n)
          <> ", "
          <> leaf(n)
          <> ")\n  made()",
        with_quiet(n, ""),
        "",
      )
    }),
    numbered(10, fn(n) {
      let named = case dep {
        "pub_js" -> "g"
        _ -> "f"
      }
      Case(
        dep
          <> ".run_9, a quiet first argument beside an unused printer, each variant naming them differently",
        "let made = "
          <> dep
          <> ".run_9("
          <> quiet(n)
          <> ", "
          <> leaf(n)
          <> ")\n  made()",
        with_quiet(n, ""),
        // The consumer's line states what it returns, the dependency its
        // effects.
        "assume "
          <> dep
          <> ".run_9("
          <> named
          <> ": ["
          <> named
          <> "]) where returns : ["
          <> named
          <> "]\n",
      )
    }),
    numbered(11, fn(n) {
      Case(
        dep
          <> ".run_10, an external whose written line spells a variable like the other parameter",
        "let made = "
          <> dep
          <> ".run_10("
          <> leaf(n)
          <> ", "
          <> quiet(n)
          <> ")\n  made()",
        with_quiet(n, ""),
        "",
      )
    }),
  ]
}

// The cases calling a published dependency's functions that take no argument,
// by the function each calls, their index among `published_cases`'.
const published_direct = [#("run_5", 7), #("run_6", 8)]

const published_count = 12

// Whether the case at `offset` among `dep`'s `published_cases`, read `on`, is
// read exactly: the quiet arguments beside unused printers, wherever the
// dependency's targets name every target the reading reads, so its line is
// read.
fn published_exact(dep: String, offset: Int, on: String) -> Bool {
  offset >= 9
  && case dep, on {
    "pub_js", "javascript" | "pub_erl", "erlang" -> True
    "pub_js", _ | "pub_erl", _ -> False
    _, _ -> True
  }
}

// The published functions taking a callback, whose direct answers the
// published-spec block holds to the parameter names their publisher writes.
const published_named = [
  "run_1", "run_2", "run_3", "run_4", "run_7", "run_8", "run_9", "run_10",
]

// Three dependencies defining `published_pairs`, each with a spec `infer`
// writes under its own `targets`: both, JavaScript alone and Erlang alone. A
// consumer calls each one's functions, runs on both targets, and is inferred
// on each target alone and on both: every answer holds what the targets it is
// read on printed, unless it is `[Unknown]`, and the two-target answer is the
// join of the single-target ones. `graded effect` on each dependency function
// that takes no argument holds the same, a target that declines the query
// read as `[Unknown]`; on each function taking a callback it is stated in the
// parameters its publisher publishes over, on each target alone and on both,
// inferred over the dependencies' sources before their specs are published
// and read from the specs after; and on both targets `check`, `effect` and
// `why` agree with the consumer's inferred spec.
fn publication_cases(graded: String, root: String) -> Outcome {
  let deps = [
    #("pub_both", "[\"erlang\", \"javascript\"]"),
    #("pub_js", "[\"javascript\"]"),
    #("pub_erl", "[\"erlang\"]"),
  ]
  list.each(deps, fn(dep) {
    let #(name, targets) = dep
    write(
      root <> "/" <> name <> "/gleam.toml",
      "name = \""
        <> name
        <> "\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = "
        <> targets
        <> "\n",
    )
    let label = published_label(name)
    write(
      root <> "/" <> name <> "/src/" <> name <> ".gleam",
      published_pairs(name),
    )
    list.each(published_hits(name, label), fn(file) {
      write(root <> "/" <> name <> "/src/" <> file.0, file.1)
    })
  })
  // Each dependency's spec, published once the fresh answers are read.
  let publish = fn() {
    list.each(deps, fn(dep) {
      let name = dep.0
      write(
        root <> "/" <> name <> "/" <> name <> ".graded",
        "assume "
          <> name
          <> ".hit : [L"
          <> int.to_string(published_label(name))
          <> "]\nassume "
          <> name
          <> ".run_10(first: [x], second: [first]) : [] where returns : [first]\n",
      )
      infer(graded, absolute(root <> "/" <> name))
    })
  }
  let cases =
    list.index_map(deps, fn(dep, index) {
      published_cases(dep.0, index * published_count + 1)
    })
    |> list.flatten
  let directory = root <> "/app"
  // `graded effect`'s `.graded` answer for each dependency's `functions`, from
  // one analysis of the app, by qualified name.
  let effect_each = fn(functions) {
    let answers =
      list.flat_map(deps, fn(dep) {
        list.map(functions, fn(function) { dep.0 <> "." <> function })
      })
      |> graded.run_effect_each(directory, _)
      |> dict.from_list
      |> names_or_error
    fn(name) {
      dict.get(answers, name) |> result.map(answer.render(_, answer.Graded))
    }
  }
  write_project_importing(
    directory,
    "erlang",
    cases,
    string.concat(list.map(deps, fn(dep) { "import " <> dep.0 <> "\n" })),
  )
  let toml = fn(targets) {
    "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n"
    <> string.concat(
      list.map(deps, fn(dep) {
        dep.0 <> " = { path = \"../" <> dep.0 <> "\" }\n"
      }),
    )
    <> "\n[tools.graded]\ntargets = "
    <> targets
    <> "\n"
  }
  let _ =
    shellout.command(
      run: "gleam",
      with: ["deps", "download"],
      in: directory,
      opt: [],
    )
  // Each function taking a callback queried on each target alone and on
  // both while no dependency has a spec: inferred over their sources.
  let fresh =
    list.flat_map(
      [
        #("erlang", "[\"erlang\"]"),
        #("javascript", "[\"javascript\"]"),
        #("both", "[\"erlang\", \"javascript\"]"),
      ],
      fn(reading) {
        write(directory <> "/gleam.toml", toml(reading.1))
        let effect = effect_each(published_named)
        list.flat_map(deps, fn(dep) {
          list.map(published_named, fn(function) {
            let name = dep.0 <> "." <> function
            #(
              reading.0,
              dep.0,
              name,
              effect(name) |> result.map(first_statement),
            )
          })
        })
      },
    )
  publish()
  // Each fresh answer names the parameters the spec published since names.
  let fresh_failures =
    list.filter_map(fresh, fn(entry) {
      let #(on, dep, name, answered) = entry
      let answer = result.unwrap(answered, "no answer")
      let publisher =
        statements(read(root <> "/" <> dep <> "/" <> dep <> ".graded"))
        |> list.find(fn(line) {
          string.starts_with(line, "effects " <> name <> "(")
          || string.starts_with(line, "effects " <> name <> " ")
        })
        |> result.unwrap("")
      case
        published_names_agree(
          answer,
          publisher_parameters(
            dep,
            string.drop_start(name, string.length(dep) + 1),
          ),
          string.ends_with(name, ".run_10"),
        )
      {
        True -> Error(Nil)
        False ->
          Ok(
            "published effect "
            <> name
            <> " read fresh on "
            <> on
            <> ": states `"
            <> answer
            <> "` where its publisher writes `"
            <> publisher
            <> "`",
          )
      }
    })
  write(directory <> "/gleam.toml", toml("[\"erlang\", \"javascript\"]"))
  case observed(directory, "erlang"), observed(directory, "javascript") {
    Error(output), _ | _, Error(output) ->
      Outcome(
        ["published-spec consumer did not run:\n" <> output],
        0,
        list.length(cases),
      )
    Ok(erlang), Ok(javascript) -> {
      // Each answer's labels, beside the names whose query declined: every
      // function queried is built on each target the app is read on.
      let direct = fn(on: String) {
        let effect = effect_each(list.map(published_direct, pair.first))
        let queried =
          list.index_map(deps, fn(dep, index) {
            list.map(published_direct, fn(called) {
              let name = dep.0 <> "." <> called.0
              #(
                "case_" <> int.to_string(index * published_count + called.1),
                #(name, effect(name)),
              )
            })
          })
          |> list.flatten
        #(
          queried
            |> list.map(fn(entry) {
              #(entry.0, #(entry.1.0, direct_labels(entry.1.1)))
            })
            |> dict.from_list,
          list.filter_map(queried, fn(entry) {
            case entry.1.1 {
              Ok(_) -> Error(Nil)
              Error(_) ->
                Ok(
                  "published effect "
                  <> entry.1.0
                  <> " read on "
                  <> on
                  <> ": declined where the function is built",
                )
            }
          }),
        )
      }
      // Each direct answer on a function taking a callback names the
      // parameters its publisher's own spec names, its returned operator's
      // variables among them.
      let named = fn(on: String) {
        let effect = effect_each(published_named)
        list.flat_map(deps, fn(dep) {
          let published =
            read(root <> "/" <> dep.0 <> "/" <> dep.0 <> ".graded")
          list.filter_map(published_named, fn(function) {
            let name = dep.0 <> "." <> function
            let publisher =
              statements(published)
              |> list.find(fn(line) {
                string.starts_with(line, "effects " <> name <> "(")
                || string.starts_with(line, "effects " <> name <> " ")
              })
              |> result.unwrap("")
            case effect(name) {
              Error(_) -> Error(Nil)
              Ok(text) -> {
                let answer = first_statement(text)
                case
                  published_names_agree(
                    answer,
                    publisher_parameters(dep.0, function),
                    function == "run_10",
                  )
                {
                  True -> Error(Nil)
                  False ->
                    Ok(
                      "published effect "
                      <> name
                      <> " read on "
                      <> on
                      <> ": states `"
                      <> answer
                      <> "` where its publisher writes `"
                      <> publisher
                      <> "`",
                    )
                }
              }
            }
          })
        })
      }
      let both = answers(graded, directory)
      let both_spec = read(directory <> "/app.graded")
      let #(both_direct, both_declined) = direct("both")
      let both_named = named("both")
      write(directory <> "/gleam.toml", toml("[\"erlang\"]"))
      let erlang_only = answers(graded, directory)
      let #(erlang_direct, erlang_declined) = direct("erlang")
      let erlang_named = named("erlang")
      write(directory <> "/gleam.toml", toml("[\"javascript\"]"))
      let javascript_only = answers(graded, directory)
      let #(javascript_direct, javascript_declined) = direct("javascript")
      let javascript_named = named("javascript")
      write(directory <> "/gleam.toml", toml("[\"erlang\", \"javascript\"]"))
      let printed = dict.combine(erlang, javascript, set.union)
      let direct_failures =
        dict.to_list(both_direct)
        |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
        |> list.flat_map(fn(entry) {
          let #(function, #(name, both_answer)) = entry
          let get = fn(answers) {
            dict.get(answers, function)
            |> result.map(fn(pair: #(String, Set(String))) { pair.1 })
            |> result.unwrap(set.from_list(["Unknown"]))
          }
          let printed_by = fn(observed) {
            dict.get(observed, function) |> result.unwrap(set.new())
          }
          let readings = [
            #("erlang", get(erlang_direct), printed_by(erlang)),
            #("javascript", get(javascript_direct), printed_by(javascript)),
            #("both", both_answer, printed_by(printed)),
          ]
          let unsound =
            list.filter_map(readings, fn(reading) {
              let #(on, answer, printed) = reading
              let missing =
                set.to_list(printed)
                |> list.filter(fn(label) { !set.contains(answer, label) })
              case missing != [] && !set.contains(answer, "Unknown") {
                True ->
                  Ok(
                    "published effect "
                    <> name
                    <> " read on "
                    <> on
                    <> ": printed "
                    <> labels(printed)
                    <> ", answered "
                    <> labels(answer),
                  )
                False -> Error(Nil)
              }
            })
          let join = set.union(get(erlang_direct), get(javascript_direct))
          case both_answer == join {
            True -> unsound
            False -> [
              "published effect "
                <> name
                <> ": both targets answered "
                <> labels(both_answer)
                <> ", the join of each alone "
                <> labels(join),
              ..unsound
            ]
          }
        })
      let inconsistent =
        consistency_failures(
          "published",
          directory,
          both_spec,
          list.index_map(cases, fn(case_, index) {
            #("app.case_" <> int.to_string(index + 1), case_.name)
          })
            |> dict.from_list,
        )
      let failures =
        list.index_map(cases, fn(case_, index) { #(index + 1, case_) })
        |> list.flat_map(fn(pair) {
          let #(n, case_) = pair
          let function = "case_" <> int.to_string(n)
          let get = fn(answers) {
            dict.get(answers, function) |> result.unwrap(set.new())
          }
          let readings = [
            #("erlang", get(erlang_only), get(erlang)),
            #("javascript", get(javascript_only), get(javascript)),
            #("both", get(both), get(printed)),
          ]
          let dep = case { n - 1 } / published_count {
            0 -> "pub_both"
            1 -> "pub_js"
            _ -> "pub_erl"
          }
          let unsound =
            list.filter_map(readings, fn(reading) {
              let #(name, answer, printed) = reading
              let missing =
                set.to_list(printed)
                |> list.filter(fn(label) { !set.contains(answer, label) })
              case
                missing != []
                && !set.contains(answer, "Unknown")
                || published_exact(dep, { n - 1 } % published_count, name)
                && answer != printed
              {
                True ->
                  Ok(
                    "published "
                    <> function
                    <> " ("
                    <> case_.name
                    <> ") read on "
                    <> name
                    <> ": printed "
                    <> labels(printed)
                    <> ", answered "
                    <> labels(answer),
                  )
                False -> Error(Nil)
              }
            })
          let join = set.union(get(erlang_only), get(javascript_only))
          case get(both) == join {
            True -> unsound
            False -> [
              "published "
                <> function
                <> " ("
                <> case_.name
                <> "): both targets answered "
                <> labels(get(both))
                <> ", the join of each alone "
                <> labels(join),
              ..unsound
            ]
          }
        })
      Outcome(
        list.flatten([
          failures,
          direct_failures,
          both_declined,
          erlang_declined,
          javascript_declined,
          both_named,
          erlang_named,
          javascript_named,
          fresh_failures,
          inconsistent,
        ]),
        dict.size(dict.delete(printed, "main")),
        list.length(cases),
      )
    }
  }
}

// The first statement of an `effect` answer, its continuation joined on.
fn first_statement(text: String) -> String {
  statements(text)
  |> list.find(fn(line) { !string.starts_with(line, "//") })
  |> result.unwrap("")
}

// The parameters a published dependency publishes `function` over: those of
// the variant its targets select, the first written where it names both,
// filled in from the other.
fn publisher_parameters(dep: String, function: String) -> List(String) {
  let erlang = case function {
    "run_1" -> ["a", "b"]
    "run_7" -> ["f"]
    "run_8" | "run_10" -> ["first", "second"]
    "run_9" -> ["f", "g"]
    _ -> ["a"]
  }
  let javascript = case function {
    "run_1" | "run_3" -> ["a", "b"]
    "run_7" -> ["g"]
    "run_8" -> ["second", "first"]
    "run_9" -> ["g", "h"]
    "run_10" -> ["first", "second"]
    _ -> ["b"]
  }
  case dep, function {
    "pub_js", _ -> javascript
    "pub_erl", _ -> erlang
    _, "run_3" -> ["a", "b"]
    _, _ -> erlang
  }
}

// Whether a direct answer is stated in its publisher's parameter names: each
// bound names one of `parameters`, once. An inferred line's bounds each
// introduce the variable their parameter names, and its returned operator
// names parameters; a written one's, `written`, introduce whatever it spells,
// and its returned operator names what they name or introduce.
fn published_names_agree(
  answer: String,
  parameters: List(String),
  written: Bool,
) -> Bool {
  let bounds = bound_items(answer)
  let names = list.map(bounds, fn(bound) { bound.0 })
  let variables = fn(items) {
    set.to_list(items)
    |> list.filter(fn(item) { string.lowercase(item) == item })
    |> list.map(fn(item) {
      string.split(item, ".") |> list.first |> result.unwrap(item)
    })
  }
  let introduced = list.flat_map(bounds, fn(bound) { variables(bound.1) })
  let returned = case string.split_once(answer, "where returns : ") {
    Ok(#(_, operator)) -> variables(effect_labels(operator))
    Error(Nil) -> []
  }
  list.length(list.unique(names)) == list.length(names)
  && list.all(names, list.contains(parameters, _))
  && case written {
    True ->
      list.all(returned, fn(variable) {
        list.contains(names, variable) || list.contains(introduced, variable)
      })
    False ->
      list.all(bounds, fn(bound) {
        list.all(variables(bound.1), fn(variable) { variable == bound.0 })
      })
      && list.all(returned, list.contains(parameters, _))
  }
}

// Each bound a statement's bound list writes, in order: its parameter name and
// the labels and variables of its effects.
fn bound_items(statement: String) -> List(#(String, Set(String))) {
  let head =
    string.split_once(statement, " : ")
    |> result.map(fn(pair) { pair.0 })
    |> result.unwrap(statement)
  case string.split_once(statement, "(") {
    Error(Nil) -> []
    Ok(#(before, bounds)) ->
      case string.length(before) < string.length(head) {
        False -> []
        True ->
          top_level_items(string.to_graphemes(bounds), 0, "", [])
          |> list.filter_map(fn(item) {
            string.split_once(item, ":")
            |> result.map(fn(pair) {
              #(string.trim(pair.0), effect_labels(pair.1))
            })
          })
      }
  }
}

// `characters` split at each comma outside brackets, up to the parenthesis
// closing the list.
fn top_level_items(
  characters: List(String),
  depth: Int,
  current: String,
  items: List(String),
) -> List(String) {
  case characters {
    [] -> list.reverse([current, ..items])
    [")", ..] if depth == 0 -> list.reverse([current, ..items])
    [",", ..rest] if depth == 0 ->
      top_level_items(rest, depth, "", [current, ..items])
    [character, ..rest] -> {
      let depth = case character {
        "[" | "(" -> depth + 1
        "]" | ")" -> depth - 1
        _ -> depth
      }
      top_level_items(rest, depth, current <> character, items)
    }
  }
}

// The label each published dependency's `hit` prints.
fn published_label(dep: String) -> Int {
  case dep {
    "pub_both" -> 901
    "pub_js" -> 902
    _ -> 903
  }
}

// The labels a `graded effect` answer states, `[Unknown]` where it declines.
fn direct_labels(answer: Result(String, a)) -> Set(String) {
  case answer {
    Ok(text) ->
      string.split(text, "\n")
      |> list.last
      |> result.map(fn(line) {
        case string.split_once(line, " : ") {
          Ok(#(_, effects)) -> effect_labels(effects)
          Error(Nil) -> set.from_list(["Unknown"])
        }
      })
      |> result.unwrap(set.from_list(["Unknown"]))
    Error(_) -> set.from_list(["Unknown"])
  }
}

// The installed-package boundary

// Types an installed package defines once per target, read by the package's
// fallback bodies: a box holding an integer on Erlang and a function on
// JavaScript, the same through a private alias inside a public type, and an
// alias on Erlang beside a custom type holding a function on JavaScript.
const installed_types =
  "@target(erlang)
pub type CustomBox {
  CustomBox(Int)
}

@target(javascript)
pub type CustomBox {
  CustomBox(fn() -> Nil)
}

@target(erlang)
type Held =
  Int

@target(javascript)
type Held =
  fn() -> Nil

pub type AliasBox {
  AliasBox(Held)
}

@target(erlang)
pub type MixedBox =
  Int

@target(javascript)
pub type MixedBox {
  MixedBox(run: fn() -> Nil)
}
"

const installed_service =
  "import gleam/latent_types

@external(erlang, \"latent_service_ffi\", \"make_custom\")
@external(javascript, \"./latent_service_ffi.mjs\", \"make\")
fn make_custom() -> latent_types.CustomBox

@external(erlang, \"latent_service_ffi\", \"sink\")
@external(javascript, \"./latent_service_ffi.mjs\", \"sink\")
fn sink_custom(x: latent_types.CustomBox) -> Nil

@external(javascript, \"./latent_service_ffi.mjs\", \"quiet\")
pub fn quiet_custom() -> Nil {
  sink_custom(make_custom())
}

@external(erlang, \"latent_service_ffi\", \"make_alias\")
@external(javascript, \"./latent_service_ffi.mjs\", \"make\")
fn make_alias() -> latent_types.AliasBox

@external(erlang, \"latent_service_ffi\", \"sink\")
@external(javascript, \"./latent_service_ffi.mjs\", \"sink\")
fn sink_alias(x: latent_types.AliasBox) -> Nil

@external(javascript, \"./latent_service_ffi.mjs\", \"quiet\")
pub fn quiet_alias() -> Nil {
  sink_alias(make_alias())
}

@external(erlang, \"latent_service_ffi\", \"make_mixed\")
@external(javascript, \"./latent_service_ffi.mjs\", \"make_mixed\")
fn make_mixed() -> latent_types.MixedBox

@external(erlang, \"latent_service_ffi\", \"sink\")
@external(javascript, \"./latent_service_ffi.mjs\", \"run_box\")
fn sink_mixed(x: latent_types.MixedBox) -> Nil

@external(erlang, \"latent_service_ffi\", \"quiet\")
pub fn mixed() -> Nil {
  sink_mixed(make_mixed())
}
"

// An installed package's type pairs, in modules added to the app's installed
// `gleam_stdlib`, which graded reads as a package it does not load as a local
// one. The app runs on both targets and is inferred on each alone and on
// both, as the published-spec block does, and on both `check`, `effect` and
// `why` agree with its inferred spec.
fn installed_cases(graded: String, root: String) -> Outcome {
  let cases = [
    Case(
      "installed custom type pair, read by an Erlang fallback",
      "latent_service.quiet_custom()",
      "",
      "",
    ),
    Case(
      "installed private alias pair in a public type, read by an Erlang fallback",
      "latent_service.quiet_alias()",
      "",
      "",
    ),
    Case(
      "installed alias and custom type pair, run by a JavaScript fallback",
      "latent_service.mixed()",
      "",
      "",
    ),
  ]
  let mixed = int.to_string(list.length(cases))
  let directory = root <> "/app"
  write_project_importing(
    directory,
    "erlang",
    cases,
    "import gleam/latent_service\n",
  )
  write(
    directory <> "/app.graded",
    read(directory <> "/app.graded") <> "assume gleam/latent_service : []\n",
  )
  let toml = fn(targets) {
    "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n\n[tools.graded]\ntargets = "
    <> targets
    <> "\n"
  }
  write(directory <> "/gleam.toml", toml("[\"erlang\", \"javascript\"]"))
  let downloaded =
    shellout.command(
      run: "gleam",
      with: ["deps", "download"],
      in: directory,
      opt: [],
    )
  let stdlib = directory <> "/build/packages/gleam_stdlib/src"
  write(stdlib <> "/gleam/latent_types.gleam", installed_types)
  write(stdlib <> "/gleam/latent_service.gleam", installed_service)
  write(
    stdlib <> "/latent_service_ffi.erl",
    "-module(latent_service_ffi).\n-export([make_custom/0, make_alias/0, make_mixed/0, sink/1, quiet/0]).\nmake_custom() -> {custom_box, 0}.\nmake_alias() -> {alias_box, 0}.\nmake_mixed() -> 0.\nsink(_) -> nil.\nquiet() -> nil.\n",
  )
  write(
    stdlib <> "/gleam/latent_service_ffi.mjs",
    "export function make() { return {}; }\nexport function sink(_) {}\nexport function quiet() {}\nexport function make_mixed() { return { run: () => console.log(\"HIT "
      <> mixed
      <> "\") }; }\nexport function run_box(box) { box.run(); }\n",
  )
  case
    downloaded,
    observed(directory, "erlang"),
    observed(directory, "javascript")
  {
    Error(failure), _, _ ->
      Outcome(
        ["installed-package dependencies did not download:\n" <> failure.1],
        0,
        list.length(cases),
      )
    _, Error(output), _ | _, _, Error(output) ->
      Outcome(
        ["installed-package app did not run:\n" <> output],
        0,
        list.length(cases),
      )
    Ok(_), Ok(erlang), Ok(javascript) -> {
      let both = answers(graded, directory)
      let both_spec = read(directory <> "/app.graded")
      write(directory <> "/gleam.toml", toml("[\"erlang\"]"))
      let erlang_only = answers(graded, directory)
      write(directory <> "/gleam.toml", toml("[\"javascript\"]"))
      let javascript_only = answers(graded, directory)
      write(directory <> "/gleam.toml", toml("[\"erlang\", \"javascript\"]"))
      let printed = dict.combine(erlang, javascript, set.union)
      let failures =
        list.index_map(cases, fn(case_, index) { #(index + 1, case_) })
        |> list.filter_map(fn(pair) {
          let #(n, case_) = pair
          let function = "case_" <> int.to_string(n)
          let get = fn(answers) {
            dict.get(answers, function) |> result.unwrap(set.new())
          }
          let answer = get(both)
          let join = set.union(get(erlang_only), get(javascript_only))
          let missing =
            set.to_list(get(printed))
            |> list.filter(fn(label) { !set.contains(answer, label) })
          case
            { missing != [] && !set.contains(answer, "Unknown") }
            || answer != join
          {
            False -> Error(Nil)
            True ->
              Ok(
                "installed "
                <> function
                <> " ("
                <> case_.name
                <> "): printed "
                <> labels(get(printed))
                <> ", answered "
                <> labels(answer)
                <> ", join of single-target answers "
                <> labels(join),
              )
          }
        })
      let inconsistent =
        consistency_failures(
          "installed",
          directory,
          both_spec,
          list.index_map(cases, fn(case_, index) {
            #("app.case_" <> int.to_string(index + 1), case_.name)
          })
            |> dict.from_list,
        )
      Outcome(
        list.append(failures, inconsistent),
        dict.size(dict.delete(printed, "main")),
        list.length(cases),
      )
    }
  }
}

// The single pass

// An installed module whose externals are declared for Erlang alone, each with
// a Gleam body that runs on JavaScript: one printing, one returning a printer.
// Each prints its case's label.
const single_installed =
  "@external(erlang, \"latent_single_ffi\", \"hit_1\")
@external(javascript, \"./latent_single_ffi.mjs\", \"hit_1\")
pub fn hit_1() -> Nil

@external(erlang, \"latent_single_ffi\", \"hit_3\")
@external(javascript, \"./latent_single_ffi.mjs\", \"hit_3\")
pub fn hit_3() -> Nil

@external(erlang, \"latent_single_ffi\", \"quiet\")
pub fn go_1() -> Nil {
  hit_1()
}

@external(erlang, \"latent_single_ffi\", \"make\")
pub fn make_3() -> fn() -> Nil {
  hit_3
}
"

// A path dependency with the same shape, declared by its own spec.
const single_dependency =
  "@external(erlang, \"single_dep_hits\", \"hit\")
@external(javascript, \"./single_dep_hits.mjs\", \"hit\")
pub fn hit() -> Nil

@external(erlang, \"single_dep_hits\", \"quiet\")
pub fn go() -> Nil {
  hit()
}
"

// Declarations attached to an `@external` declared for one target, in an app
// read on both that nothing splits: the consumer's `assume` over an installed
// module's, a path dependency's own, and the consumer's `where returns` clause
// over an installed producer. The app runs on both targets and is inferred on
// each alone and on both: every answer holds what the targets it is read on
// printed, unless it is `[Unknown]`, the two-target answer is the join of the
// single-target ones, and on both targets `check`, `effect` and `why` agree
// with its inferred spec, its own externals' fallbacks among them.
fn single_pass_cases(graded: String, root: String) -> Outcome {
  let cases = [
    Case(
      "consumer's assume over an installed Erlang external, JavaScript body printing",
      "latent_single.go_1()",
      "",
      "assume gleam/latent_single.go_1 : []\nassume gleam/latent_single.hit_1 : [L1]\n",
    ),
    Case(
      "dependency's assume over its Erlang external, JavaScript body printing",
      "single_dep.go()",
      "",
      "",
    ),
    Case(
      "consumer's returns clause over an installed Erlang producer, JavaScript body returning a printer",
      "let made = latent_single.make_3()\n  made()",
      "",
      "assume gleam/latent_single.make_3 : [] where returns : []\nassume gleam/latent_single.hit_3 : [L3]\n",
    ),
  ]
  write(
    root <> "/single_dep/gleam.toml",
    "name = \"single_dep\"\nversion = \"1.0.0\"\n",
  )
  write(root <> "/single_dep/src/single_dep.gleam", single_dependency)
  write(
    root <> "/single_dep/src/single_dep_hits.erl",
    "-module(single_dep_hits).\n-export([hit/0, quiet/0]).\nhit() -> io:format(\"HIT 2~n\"), nil.\nquiet() -> nil.\n",
  )
  write(
    root <> "/single_dep/src/single_dep_hits.mjs",
    "export function hit() { console.log(\"HIT 2\"); }\n",
  )
  write(
    root <> "/single_dep/single_dep.graded",
    "assume single_dep.hit : [L2]\nassume single_dep.go : []\n",
  )
  let directory = root <> "/app"
  write_project_importing(
    directory,
    "erlang",
    cases,
    "import gleam/latent_single\nimport single_dep\n",
  )
  let toml = app_toml("single_dep = { path = \"../single_dep\" }\n")
  write(directory <> "/gleam.toml", toml("[\"erlang\", \"javascript\"]"))
  let downloaded =
    shellout.command(
      run: "gleam",
      with: ["deps", "download"],
      in: directory,
      opt: [],
    )
  let stdlib = directory <> "/build/packages/gleam_stdlib/src"
  write(stdlib <> "/gleam/latent_single.gleam", single_installed)
  write(
    stdlib <> "/latent_single_ffi.erl",
    "-module(latent_single_ffi).\n-export([hit_1/0, hit_3/0, quiet/0, make/0]).\nhit_1() -> io:format(\"HIT 1~n\"), nil.\nhit_3() -> io:format(\"HIT 3~n\"), nil.\nquiet() -> nil.\nmake() -> fun() -> nil end.\n",
  )
  write(
    stdlib <> "/gleam/latent_single_ffi.mjs",
    "export function hit_1() { console.log(\"HIT 1\"); }\nexport function hit_3() { console.log(\"HIT 3\"); }\n",
  )
  case downloaded {
    Error(failure) ->
      Outcome(
        ["single-pass dependencies did not download:\n" <> failure.1],
        0,
        list.length(cases),
      )
    Ok(_) ->
      readings_outcome(
        "single-pass",
        graded,
        directory,
        list.map(cases, fn(case_) { #(case_, []) }),
        toml,
        True,
      )
  }
}

// The cases of an app read on both targets that nothing splits, run on each
// and inferred on each alone and on both, `toml` giving its `gleam.toml` for
// the targets it is read on. Every answer holds what the targets it is read on
// printed, unless it is `[Unknown]`, and is exactly that on the readings each
// case names; the two-target answer is the join of the single-target ones; and
// on both targets `check`, `effect` and `why` agree with its inferred spec.
// With `split`, the app is read on both targets once more with an unused
// function defined once per target beside it, which has each target read in a
// run of its own: every answer is the same as the single pass's.
fn readings_outcome(
  block: String,
  graded: String,
  directory: String,
  cases: List(#(Case, List(String))),
  toml: fn(String) -> String,
  split: Bool,
) -> Outcome {
  case observed(directory, "erlang"), observed(directory, "javascript") {
    Error(output), _ | _, Error(output) ->
      Outcome([block <> " app did not run:\n" <> output], 0, list.length(cases))
    Ok(erlang), Ok(javascript) -> {
      // Each reading starts from the spec as written: `infer` on one target
      // deletes a declaration over an external that target does not build.
      let written = read(directory <> "/app.graded")
      let reading = fn(targets) {
        write(directory <> "/gleam.toml", toml(targets))
        write(directory <> "/app.graded", written)
        answers(graded, directory)
      }
      let erlang_only = reading("[\"erlang\"]")
      let javascript_only = reading("[\"javascript\"]")
      let both = reading("[\"erlang\", \"javascript\"]")
      let both_spec = read(directory <> "/app.graded")
      let split_both = case split {
        False -> option.None
        True -> {
          let source = read(directory <> "/src/app.gleam")
          write(directory <> "/src/app.gleam", source <> split_pair)
          let answers = reading("[\"erlang\", \"javascript\"]")
          write(directory <> "/src/app.gleam", source)
          option.Some(answers)
        }
      }
      let printed = dict.combine(erlang, javascript, set.union)
      let failures =
        list.index_map(cases, fn(pair, index) { #(index + 1, pair) })
        |> list.flat_map(fn(numbered) {
          let #(n, #(case_, exact)) = numbered
          let function = "case_" <> int.to_string(n)
          let get = fn(answers) {
            dict.get(answers, function) |> result.unwrap(set.new())
          }
          let complaint = fn(what) {
            block <> " " <> function <> " (" <> case_.name <> ") " <> what
          }
          [
            #("erlang", get(erlang_only), get(erlang)),
            #("javascript", get(javascript_only), get(javascript)),
            #("both", get(both), get(printed)),
            ..case split_both {
              option.Some(split) -> [
                #("a forced split", get(split), get(printed)),
              ]
              option.None -> []
            }
          ]
          |> list.filter_map(fn(reading) {
            let #(on, answer, printed) = reading
            let missing =
              set.to_list(printed)
              |> list.filter(fn(label) { !set.contains(answer, label) })
            let unsound = missing != [] && !set.contains(answer, "Unknown")
            let inexact = list.contains(exact, on) && answer != printed
            case unsound || inexact {
              True ->
                Ok(complaint(
                  "read on "
                  <> on
                  <> ": printed "
                  <> labels(printed)
                  <> ", answered "
                  <> labels(answer),
                ))
              False -> Error(Nil)
            }
          })
          |> list.append(
            case
              get(both) == set.union(get(erlang_only), get(javascript_only))
            {
              True -> []
              False -> [
                complaint(
                  "on both targets answered "
                  <> labels(get(both))
                  <> ", the join of each alone "
                  <> labels(set.union(get(erlang_only), get(javascript_only))),
                ),
              ]
            },
          )
          |> list.append(case split_both {
            option.Some(split) ->
              case get(split) == get(both) {
                True -> []
                False -> [
                  complaint(
                    "on a forced split answered "
                    <> labels(get(split))
                    <> ", the single pass "
                    <> labels(get(both)),
                  ),
                ]
              }
            option.None -> []
          })
        })
      let inconsistent =
        consistency_failures(
          block,
          directory,
          both_spec,
          list.index_map(cases, fn(pair, index) {
            #("app.case_" <> int.to_string(index + 1), { pair.0 }.name)
          })
            |> dict.from_list,
        )
      Outcome(
        list.append(failures, inconsistent),
        dict.size(dict.delete(printed, "main")),
        list.length(cases),
      )
    }
  }
}

// An unused function defined once per target, which has a package read on
// both targets read in one run per target.
const split_pair =
  "
@target(erlang)
fn split_pair() -> Nil {
  Nil
}

@target(javascript)
fn split_pair() -> Nil {
  Nil
}
"

// The app's `gleam.toml` read on `targets`, with `dependencies` beside the
// standard library.
fn app_toml(dependencies: String) -> fn(String) -> String {
  fn(targets) {
    "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n"
    <> dependencies
    <> "\n[tools.graded]\ntargets = "
    <> targets
    <> "\n"
  }
}

// The recursion dimension

type Group {
  SelfRecursive
  MutuallyRecursive
}

// How a recursive function's effects depend on what it receives: `width`
// callbacks rotated round the calls back in, a field of a record, a function
// taken out of a list, functions gathered into a list it only returns, or a
// function it returns.
type Channel {
  CallbackChannel(width: Int)
  FieldChannel
  ContainerChannel
  AccumulatorChannel
  ReturnedChannel
}

// What a call back in passes where it received the value: the value itself,
// first a printer and then a quiet function; a quiet one; or the printer.
type Edge {
  UnchangedPrinter
  UnchangedQuiet
  Quieted
  Printing
}

fn group_name(group: Group) -> String {
  case group {
    SelfRecursive -> "self-recursive"
    MutuallyRecursive -> "mutually recursive"
  }
}

fn channel_name(channel: Channel) -> String {
  case channel {
    CallbackChannel(width: 1) -> "callback"
    CallbackChannel(width:) -> int.to_string(width) <> " rotated callbacks"
    FieldChannel -> "record field"
    ContainerChannel -> "function out of a list"
    AccumulatorChannel -> "functions gathered and returned"
    ReturnedChannel -> "returned function"
  }
}

fn edge_name(edge: Edge) -> String {
  case edge {
    UnchangedPrinter -> "a printer passed on unchanged"
    UnchangedQuiet -> "a quiet function passed on unchanged"
    Quieted -> "replaced with a quiet function"
    Printing -> "replaced with the printer"
  }
}

// One cell at case `n`: `go_<n>` reads its argument through `channel` and
// calls back in, directly or through `back_<n>`, passing what `edge` says.
// The case calls it with as many rounds as it rotates callbacks, so the value
// the last round reads is the one `edge` built. Every channel but a function
// taken out of a list is read exactly.
fn recursion_dimension_case(
  group: Group,
  channel: Channel,
  edge: Edge,
  n: Int,
) -> #(Case, Bool) {
  let s = int.to_string(n)
  let quiet = "quiet_" <> s
  let leaf = "leaf_" <> s
  let replacement = case edge {
    UnchangedPrinter | UnchangedQuiet -> option.None
    Quieted -> option.Some(quiet)
    Printing -> option.Some(leaf)
  }
  let first = case edge {
    UnchangedPrinter -> leaf
    UnchangedQuiet | Quieted | Printing -> quiet
  }
  let #(parameters, result_type, base, passed, initial, rounds, run) = case
    channel
  {
    CallbackChannel(width:) -> {
      let names =
        numbers(width) |> list.map(fn(i) { "f" <> int.to_string(i - 1) })
      let assert [head, ..rest] = names
      #(
        list.map(names, fn(name) { #(name, "fn() -> Nil") }),
        "Nil",
        head <> "()",
        list.append(rest, [option.unwrap(replacement, head)]),
        list.map(names, fn(_) { first }),
        width,
        fn(call) { call },
      )
    }
    FieldChannel -> #(
      [#("b", "Box")],
      "Nil",
      "b.f()",
      [
        option.map(replacement, fn(f) { "Box(" <> f <> ")" })
        |> option.unwrap("b"),
      ],
      ["Box(" <> first <> ")"],
      1,
      fn(call) { call },
    )
    ContainerChannel -> #(
      [#("fs", "List(fn() -> Nil)")],
      "Nil",
      "case fs {\n        [f, ..] -> f()\n        [] -> Nil\n      }",
      [
        option.map(replacement, fn(f) { "[" <> f <> "]" })
        |> option.unwrap("fs"),
      ],
      ["[" <> first <> "]"],
      1,
      fn(call) { call },
    )
    AccumulatorChannel -> #(
      [#("fs", "List(fn() -> Nil)")],
      "List(fn() -> Nil)",
      "fs",
      [
        option.map(replacement, fn(f) { "[" <> f <> ", ..fs]" })
        |> option.unwrap("fs"),
      ],
      ["[" <> first <> "]"],
      1,
      fn(call) { "let _ = " <> call },
    )
    ReturnedChannel -> #(
      [#("f", "fn() -> Nil")],
      "fn() -> Nil",
      "f",
      [option.unwrap(replacement, "f")],
      [first],
      1,
      fn(call) { "let made = " <> call <> "\n  made()" },
    )
  }
  let signature = fn(name, suffix) {
    "fn "
    <> name
    <> "(n: Int, "
    <> string.join(
      list.map(parameters, fn(parameter) {
        parameter.0 <> suffix <> ": " <> parameter.1
      }),
      ", ",
    )
    <> ") -> "
    <> result_type
    <> " {\n"
  }
  let callee = case group {
    SelfRecursive -> "go_" <> s
    MutuallyRecursive -> "back_" <> s
  }
  let back = case group {
    SelfRecursive -> ""
    MutuallyRecursive ->
      signature("back_" <> s, "_back")
      <> "  go_"
      <> s
      <> "(n, "
      <> string.join(list.map(parameters, fn(p) { p.0 <> "_back" }), ", ")
      <> ")\n}\n\n"
  }
  let helpers =
    "fn "
    <> quiet
    <> "() -> Nil {\n  Nil\n}\n\n"
    <> signature("go_" <> s, "")
    <> "  case n {\n    0 -> "
    <> base
    <> "\n    _ -> "
    <> callee
    <> "(n - 1, "
    <> string.join(passed, ", ")
    <> ")\n  }\n}\n\n"
    <> back
  let body =
    run(
      "go_"
      <> s
      <> "("
      <> int.to_string(rounds)
      <> ", "
      <> string.join(initial, ", ")
      <> ")",
    )
  #(
    Case(
      group_name(group)
        <> ", "
        <> channel_name(channel)
        <> ", "
        <> edge_name(edge),
      body,
      helpers,
      "",
    ),
    channel != ContainerChannel,
  )
}

// A path three records deep read on every call back in, the records' types
// distinct whether or not the outer label repeats the inner one, its function
// the printer or a quiet one.
fn nested_label_case(repeated: Bool, printing: Bool, n: Int) -> #(Case, Bool) {
  let s = int.to_string(n)
  let outer = case repeated {
    True -> "inner"
    False -> "outer"
  }
  let leaf = case printing {
    True -> "leaf_" <> s
    False -> "quiet_" <> s
  }
  #(
    Case(
      "self-recursive, a path through distinct records "
        <> case repeated {
        True -> "repeating a label"
        False -> "with distinct labels"
      }
        <> case printing {
        True -> ", the printer"
        False -> ", a quiet function"
      },
      "nest_"
        <> s
        <> "(1, Outer"
        <> s
        <> "(Middle"
        <> s
        <> "(Leaf"
        <> s
        <> "("
        <> leaf
        <> "))))",
      "fn quiet_"
        <> s
        <> "() -> Nil {\n  Nil\n}\n\npub type Leaf"
        <> s
        <> " {\n  Leaf"
        <> s
        <> "(run: fn() -> Nil)\n}\n\npub type Middle"
        <> s
        <> " {\n  Middle"
        <> s
        <> "(inner: Leaf"
        <> s
        <> ")\n}\n\npub type Outer"
        <> s
        <> " {\n  Outer"
        <> s
        <> "("
        <> outer
        <> ": Middle"
        <> s
        <> ")\n}\n\nfn nest_"
        <> s
        <> "(n: Int, b: Outer"
        <> s
        <> ") -> Nil {\n  case n {\n    0 -> b."
        <> outer
        <> ".inner.run()\n    _ -> nest_"
        <> s
        <> "(n - 1, b)\n  }\n}\n\n",
      "",
    ),
    True,
  )
}

// A walk down `fanout` branches of a type that holds itself, beside `extras`
// nesting types nothing reaches, and a case running a function rotated
// through `fanout` record fields on each call back in, the printer among
// them where `printing`. The walk's inference ends within the block's bound
// on work, however many unrelated types there are.
fn fan_case(fanout: Int, extras: Int, printing: Bool, n: Int) -> #(Case, Bool) {
  let s = int.to_string(n)
  let branches = list.take(["a", "b", "c"], fanout)
  let first = case printing {
    True -> "leaf_" <> s
    False -> "quiet_" <> s
  }
  let fan =
    "pub type Fan"
    <> s
    <> " {\n  Fan"
    <> s
    <> "(run: fn() -> Nil, "
    <> string.join(list.map(branches, fn(b) { b <> ": Fan" <> s }), ", ")
    <> ")\n}\n\nfn walk_"
    <> s
    <> "(n: Int, node: Fan"
    <> s
    <> ") -> Nil {\n  case n {\n    0 -> node.run()\n    _ -> {\n"
    <> string.concat(
      list.map(branches, fn(b) {
        "      walk_" <> s <> "(n - 1, node." <> b <> ")\n"
      }),
    )
    <> "    }\n  }\n}\n\npub fn walker_"
    <> s
    <> "(node: Fan"
    <> s
    <> ") -> Nil {\n  walk_"
    <> s
    <> "(1, node)\n}\n\n"
  let extra_types =
    numbers(extras)
    |> list.map(fn(index) {
      let held = case index {
        1 -> "Int"
        _ -> "Extra" <> s <> "N" <> int.to_string(index - 1)
      }
      "pub type Extra"
      <> s
      <> "N"
      <> int.to_string(index)
      <> " {\n  Extra"
      <> s
      <> "N"
      <> int.to_string(index)
      <> "(child: "
      <> held
      <> ")\n}\n\n"
    })
    |> string.concat
  let rotated = list.append(list.drop(branches, 1), list.take(branches, 1))
  let spread =
    "pub type Spread"
    <> s
    <> " {\n  Spread"
    <> s
    <> "(run: fn() -> Nil, "
    <> string.join(list.map(branches, fn(b) { b <> ": Box" }), ", ")
    <> ")\n}\n\nfn spread_"
    <> s
    <> "(n: Int, s: Spread"
    <> s
    <> ") -> Nil {\n  case n {\n    0 -> s.run()\n    _ -> spread_"
    <> s
    <> "(n - 1, Spread"
    <> s
    <> "(s.a.f, "
    <> string.join(list.map(rotated, fn(b) { "s." <> b }), ", ")
    <> "))\n  }\n}\n\n"
  let boxes =
    list.index_map(branches, fn(_, index) {
      case index {
        0 -> "Box(" <> first <> ")"
        _ -> "Box(quiet_" <> s <> ")"
      }
    })
  #(
    Case(
      "self-recursive, a walk down "
        <> int.to_string(fanout)
        <> " branches beside "
        <> int.to_string(extras)
        <> " unrelated types, a function rotated through "
        <> int.to_string(fanout)
        <> " fields"
        <> case printing {
        True -> ", the printer"
        False -> ", a quiet function"
      },
      "spread_"
        <> s
        <> "(1, Spread"
        <> s
        <> "(quiet_"
        <> s
        <> ", "
        <> string.join(boxes, ", ")
        <> "))",
      "fn quiet_"
        <> s
        <> "() -> Nil {\n  Nil\n}\n\n"
        <> fan
        <> extra_types
        <> spread,
      "",
    ),
    True,
  )
}

// A function walking a path into a record type that holds itself, beside a
// quiet case: its inference still ends.
fn self_holding_case(n: Int) -> #(Case, Bool) {
  let s = int.to_string(n)
  #(
    Case(
      "self-recursive, a path into a type that holds itself",
      "Nil",
      "pub type Node"
        <> s
        <> " {\n  Node"
        <> s
        <> "(run: fn() -> Nil, next: Node"
        <> s
        <> ")\n}\n\nfn follow_"
        <> s
        <> "(n: Int, node: Node"
        <> s
        <> ") -> Nil {\n  case n {\n    0 -> node.run()\n    _ -> follow_"
        <> s
        <> "(n - 1, node.next)\n  }\n}\n\npub fn self_holding_"
        <> s
        <> "(node: Node"
        <> s
        <> ") -> Nil {\n  follow_"
        <> s
        <> "(1, node)\n}\n\n",
      "",
    ),
    True,
  )
}

// A record field handed on as a callback round a mutual cycle, the record
// rebuilt around the printer.
fn field_as_callback_case(n: Int) -> #(Case, Bool) {
  let s = int.to_string(n)
  #(
    Case(
      "mutually recursive, a record field handed on as a callback, replaced with the printer",
      "ping_" <> s <> "(1, quiet_" <> s <> ")",
      "fn quiet_"
        <> s
        <> "() -> Nil {\n  Nil\n}\n\nfn ping_"
        <> s
        <> "(n: Int, f: fn() -> Nil) -> Nil {\n  case n {\n    0 -> f()\n    _ -> pong_"
        <> s
        <> "(n - 1, Box(leaf_"
        <> s
        <> "))\n  }\n}\n\nfn pong_"
        <> s
        <> "(n: Int, b: Box) -> Nil {\n  ping_"
        <> s
        <> "(n, b.f)\n}\n\n",
      "",
    ),
    False,
  )
}

// A record field handed to a function that runs it, no recursion involved.
fn field_passed_to_runner_case(n: Int) -> #(Case, Bool) {
  let s = int.to_string(n)
  #(
    Case(
      "a record field handed to a function that runs it, a quiet function",
      "hand_" <> s <> "(Box(quiet_" <> s <> "))",
      "fn quiet_"
        <> s
        <> "() -> Nil {\n  Nil\n}\n\nfn run_"
        <> s
        <> "(f: fn() -> Nil) -> Nil {\n  f()\n}\n\nfn hand_"
        <> s
        <> "(b: Box) -> Nil {\n  run_"
        <> s
        <> "(b.f)\n}\n\n",
      "",
    ),
    False,
  )
}

// A record field read beside a callback passed on unchanged, which makes the
// function's calls back in walked one by one rather than as one union.
fn field_beside_callback_case(n: Int) -> #(Case, Bool) {
  let s = int.to_string(n)
  #(
    Case(
      "self-recursive, record field beside an unchanged callback, replaced with the printer",
      "go_" <> s <> "(1, Box(quiet_" <> s <> "), quiet_" <> s <> ")",
      "fn quiet_"
        <> s
        <> "() -> Nil {\n  Nil\n}\n\nfn go_"
        <> s
        <> "(n: Int, b: Box, g: fn() -> Nil) -> Nil {\n  let _ = g\n  case n {\n    0 -> b.f()\n    _ -> go_"
        <> s
        <> "(n - 1, Box(leaf_"
        <> s
        <> "), g)\n  }\n}\n\n",
      "",
    ),
    True,
  )
}

// Recursive functions crossed by group, channel and edge, and callbacks
// rotated 31, 32 and 40 wide, with a record field read beside a callback,
// rotations 30 and 33 wide, paths through distinct record types and a type
// that holds itself: every answer is sound, every one but a function taken out
// of a list or a field handed on as a callback exact, on each target alone and
// on both, and the two-target answer is the join.
fn recursion_dimension_cases(graded: String, root: String) -> Outcome {
  let channels =
    list.flatten([
      [CallbackChannel(1), FieldChannel, ContainerChannel],
      [AccumulatorChannel, ReturnedChannel],
      list.map([31, 32, 40], CallbackChannel),
    ])
  let generated =
    list.flat_map([SelfRecursive, MutuallyRecursive], fn(group) {
      list.flat_map(channels, fn(channel) {
        list.map(
          [UnchangedPrinter, UnchangedQuiet, Quieted, Printing],
          fn(edge) { recursion_dimension_case(group, channel, edge, _) },
        )
      })
    })
  let builders =
    list.flatten([
      generated,
      [field_beside_callback_case],
      list.map([30, 33], fn(width) {
        recursion_dimension_case(
          SelfRecursive,
          CallbackChannel(width),
          UnchangedQuiet,
          _,
        )
      }),
      list.flat_map([True, False], fn(repeated) {
        list.map([False, True], fn(printing) {
          nested_label_case(repeated, printing, _)
        })
      }),
      [self_holding_case, field_as_callback_case, field_passed_to_runner_case],
    ])
  let cells =
    list.index_map(builders, fn(build, index) {
      let #(case_, exact) = build(index + 1)
      #(case_, case exact {
        True -> ["erlang", "javascript", "both"]
        False -> []
      })
    })
  let directory = root <> "/app"
  write_project(directory, "erlang", list.map(cells, fn(cell) { cell.0 }))
  readings_outcome("recursion", graded, directory, cells, app_toml(""), False)
}

// What one inference of the branching-walk project may spend, in reductions.
const fan_work_bound = 40_000_000

// Walks down two and three branches of a type that holds itself, beside 0, 6,
// 12 and 18 nesting types nothing reaches, each beside a printing or a quiet
// case running a function rotated through as many record fields: every
// answer is sound and exact, on each target alone and on both, its two-target
// answer the join, and one inference of the project stays within
// `fan_work_bound`, whatever unrelated types it defines.
fn fan_dimension_cases(graded: String, root: String) -> Outcome {
  let builders =
    list.flat_map([2, 3], fn(fanout) {
      list.flat_map([0, 6, 12, 18], fn(extras) {
        list.map([True, False], fn(printing) {
          fan_case(fanout, extras, printing, _)
        })
      })
    })
  let cells =
    list.index_map(builders, fn(build, index) {
      let #(case_, _) = build(index + 1)
      #(case_, ["erlang", "javascript", "both"])
    })
  let directory = root <> "/app"
  write_project(directory, "erlang", list.map(cells, fn(cell) { cell.0 }))
  let outcome =
    readings_outcome(
      "branching walk",
      graded,
      directory,
      cells,
      app_toml(""),
      False,
    )
  write(
    directory <> "/gleam.toml",
    app_toml("")("[\"erlang\", \"javascript\"]"),
  )
  let before = reductions()
  let _ = graded.inferred_lines(directory)
  let spent = reductions() - before
  case spent > fan_work_bound {
    False -> outcome
    True ->
      Outcome(..outcome, failures: [
        "branching walk: one inference spent "
          <> int.to_string(spent)
          <> " reductions, past the bound of "
          <> int.to_string(fan_work_bound),
        ..outcome.failures
      ])
  }
}

// The translation dimension

// What wrote a line over a dependency's function defined once per target.
type LineSource {
  PathSpecSource
  InstalledSpecSource
  ConsumerSpecSource
  CatalogSource
}

// The symbol a line reads the first callback's variable through.
type LineSymbol {
  // `[P]`: what the callback costs.
  BareSymbol
  // `carries : [P.returns]`: what the callback returns.
  ReturnsSymbol
  // `[P([h])]`: the callback applied as an operator.
  AppliedSymbol
}

// Which of the two callbacks the case passes prints, or runs what it is
// handed.
type PrinterAt {
  PrinterFirst
  PrinterSecond
  PrinterNeither
}

fn line_source_name(source: LineSource) -> String {
  case source {
    PathSpecSource -> "path dependency spec"
    InstalledSpecSource -> "installed spec"
    ConsumerSpecSource -> "consumer spec"
    CatalogSource -> "catalog"
  }
}

// The module a source's functions live in, and the alias a case calls it by.
fn line_source_module(source: LineSource) -> #(String, String) {
  case source {
    PathSpecSource -> #("tr_path", "tr_path")
    InstalledSpecSource -> #("gleam/tr_installed", "tr_installed")
    ConsumerSpecSource -> #("tr_own", "tr_own")
    CatalogSource -> #("tr_cat", "tr_cat")
  }
}

fn line_symbol_name(symbol: LineSymbol) -> #(String, String) {
  case symbol {
    BareSymbol -> #("run", "a bare variable")
    ReturnsSymbol -> #("make", "a callback result")
    AppliedSymbol -> #("apply", "an applied operator variable")
  }
}

// One function of a translation module, defined once per target: the Erlang
// variant, written first, names its callbacks `cb` and `e`, the JavaScript
// one `reader`, and each runs its first callback. Its line reads that
// callback through `symbol`, `first` and `second` the two bounds' variables.
type Translated {
  Translated(
    name: String,
    symbol: LineSymbol,
    first: String,
    second: String,
    reader: #(String, String),
    label: String,
  )
}

// Every function of a translation module: each symbol with the first
// bound's variable spelled like the publisher's parameter that moves, like
// the reader's, like neither, and like neither beside a second spelled like
// the reader's; and a callback result where the reader renames its second
// parameter, and where it keeps the publisher's names.
fn translated_functions() -> List(Translated) {
  [
    #("e", "e", "q", "spelled like a publisher parameter"),
    #("q", "q", "e", "spelled like a reader parameter"),
    #("u", "u", "w", "spelled like no parameter"),
    #(
      "v",
      "v",
      "q",
      "spelled like no parameter beside one spelled like a reader parameter",
    ),
  ]
  |> list.flat_map(fn(spelling) {
    let #(key, first, second, label) = spelling
    list.map([BareSymbol, ReturnsSymbol, AppliedSymbol], fn(symbol) {
      let #(prefix, name) = line_symbol_name(symbol)
      Translated(
        name: prefix <> "_" <> key,
        symbol:,
        first:,
        second:,
        reader: #("x", "q"),
        label: name <> " " <> label,
      )
    })
  })
  |> list.append([
    Translated(
      name: "make_z",
      symbol: ReturnsSymbol,
      first: "e",
      second: "q",
      reader: #("x", "z"),
      label: "a callback result spelled like a publisher parameter, the reader renaming its second parameter",
    ),
    Translated(
      name: "make_same",
      symbol: ReturnsSymbol,
      first: "e",
      second: "q",
      reader: #("cb", "e"),
      label: "a callback result spelled like a publisher parameter, the reader keeping the publisher's names",
    ),
  ])
}

// The source of a translation module: every function of
// `translated_functions`, beside the record `make` functions return.
fn translation_module() -> String {
  "pub type Box {\n  Box(f: fn() -> Nil)\n}\n\n"
  <> string.concat(
    list.map(translated_functions(), fn(function) {
      let variant = fn(target, first, second) {
        let header =
          "@target(" <> target <> ")\npub fn " <> function.name <> "("
        case function.symbol {
          BareSymbol ->
            header
            <> first
            <> ": fn() -> Nil, "
            <> second
            <> ": fn() -> Nil) -> Nil {\n  let _ = "
            <> second
            <> "\n  "
            <> first
            <> "()\n}\n\n"
          ReturnsSymbol ->
            header
            <> first
            <> ": fn() -> Box, "
            <> second
            <> ": fn() -> Box) -> Box {\n  let _ = "
            <> second
            <> "\n  "
            <> first
            <> "()\n}\n\n"
          AppliedSymbol ->
            header
            <> "\n  "
            <> first
            <> ": fn(fn() -> Nil) -> Nil,\n  "
            <> second
            <> ": fn(fn() -> Nil) -> Nil,\n  k: fn() -> Nil,\n) -> Nil {\n  let _ = "
            <> second
            <> "\n  "
            <> first
            <> "(k)\n}\n\n"
        }
      }
      variant("erlang", "cb", "e")
      <> variant("javascript", function.reader.0, function.reader.1)
    }),
  )
  <> string.concat(
    list.map(kind_collisions(), fn(kind) {
      "@target(erlang)\npub fn "
      <> kind.name
      <> kind.erlang
      <> "\n\n@target(javascript)\npub fn "
      <> kind.name
      <> kind.javascript
      <> "\n\n"
    }),
  )
}

// The exact line over `function` in `module`, written in the publisher's
// parameter names.
fn translation_line(module: String, function: Translated) -> String {
  let bounds =
    "assume "
    <> module
    <> "."
    <> function.name
    <> "(cb: ["
    <> function.first
    <> "], e: ["
    <> function.second
    <> "]"
  case function.symbol {
    BareSymbol -> bounds <> ") : [" <> function.first <> "]\n"
    ReturnsSymbol ->
      bounds
      <> ") : ["
      <> function.first
      <> "] where carries : ["
      <> function.first
      <> ".returns]\n"
    AppliedSymbol -> bounds <> ", k: [h]) : [" <> function.first <> "([h])]\n"
  }
}

// The exact line over every function of a translation module.
fn translation_lines(module: String) -> String {
  string.concat(list.map(translated_functions(), translation_line(module, _)))
  <> string.concat(
    list.map(kind_collisions(), fn(kind) {
      "assume " <> module <> "." <> kind.name <> kind.line <> "\n"
    }),
  )
}

// A function whose JavaScript variant spells a parameter of another kind or
// arity as the Erlang one, written first, spells the parameter its line
// bounds: both variants after the name, its line after the path, valid in
// both variants, how a case calls it through `alias` with `leaf` or a quiet
// function in the printing place and `quiet` elsewhere, and whether its
// answer is exact.
type KindCollision {
  KindCollision(
    name: String,
    erlang: String,
    javascript: String,
    line: String,
    call: fn(String, String, String) -> String,
    exact: Bool,
    label: String,
  )
}

fn kind_collisions() -> List(KindCollision) {
  [
    KindCollision(
      name: "k_effect",
      erlang: "(cb: fn() -> Nil, value: Box) -> Nil {\n  let _ = value\n  cb()\n}",
      javascript: "(x: fn() -> Nil, cb: Box) -> Nil {\n  let _ = cb\n  x()\n}",
      line: "(cb: [e]) : [e]",
      call: fn(alias, leaf, quiet) {
        alias
        <> ".k_effect("
        <> leaf
        <> ", "
        <> alias
        <> ".Box("
        <> quiet
        <> "))"
      },
      exact: True,
      label: "a callback the reader spells as a carried value's name, read in the effects term",
    ),
    KindCollision(
      name: "k_returns",
      erlang: "(cb: fn() -> Nil, value: Box) -> fn() -> Nil {\n  let _ = value\n  cb\n}",
      javascript: "(x: fn() -> Nil, cb: Box) -> fn() -> Nil {\n  let _ = cb\n  x\n}",
      line: "(cb: [e]) : [] where returns : [e]",
      call: fn(alias, leaf, quiet) {
        "let f = "
        <> alias
        <> ".k_returns("
        <> leaf
        <> ", "
        <> alias
        <> ".Box("
        <> quiet
        <> "))\n  f()"
      },
      exact: True,
      label: "a callback the reader spells as a carried value's name, read in `where returns`",
    ),
    KindCollision(
      name: "k_runs",
      erlang: "(cb: Box, value: fn() -> Nil) -> Nil {\n  let _ = value\n  cb.f()\n}",
      javascript: "(x: Box, cb: fn() -> Nil) -> Nil {\n  let _ = cb\n  x.f()\n}",
      line: "(cb: [v]) : [] where runs : [v]",
      call: fn(alias, leaf, quiet) {
        alias <> ".k_runs(" <> alias <> ".Box(" <> leaf <> "), " <> quiet <> ")"
      },
      exact: True,
      label: "a carried value the reader spells as a callback's name, read in `runs`",
    ),
    KindCollision(
      name: "k_relay",
      erlang: "(cb: fn(Box) -> Nil, value: Box) -> Nil {\n  cb(value)\n}",
      javascript: "(x: fn(Box) -> Nil, cb: Box) -> Nil {\n  x(cb)\n}",
      line: "(cb: [k], value: [v]) : [k] where runs : [], relay : k(v)",
      call: fn(alias, leaf, _quiet) {
        alias
        <> ".k_relay(fn(b) { ffi.run_fields(b) }, "
        <> alias
        <> ".Box("
        <> leaf
        <> "))"
      },
      exact: False,
      label: "a callback the reader spells as a carried value's name, read in `relay`",
    ),
    KindCollision(
      name: "k_carries",
      erlang: "(cb: fn() -> Box, value: Box) -> Box {\n  let _ = value\n  cb()\n}",
      javascript: "(x: fn() -> Box, cb: Box) -> Box {\n  let _ = cb\n  x()\n}",
      line: "(cb: [e]) : [e] where carries : [e.returns]",
      call: fn(alias, leaf, quiet) {
        "ffi.run_fields("
        <> alias
        <> ".k_carries(fn() { "
        <> alias
        <> ".Box("
        <> leaf
        <> ") }, "
        <> alias
        <> ".Box("
        <> quiet
        <> ")))"
      },
      exact: True,
      label: "a callback the reader spells as a carried value's name, read in `carries`",
    ),
    KindCollision(
      name: "k_arity",
      erlang: "(cb: fn() -> Nil, value: fn(Nil) -> Nil) -> Nil {\n  let _ = value\n  cb()\n}",
      javascript: "(x: fn() -> Nil, cb: fn(Nil) -> Nil) -> Nil {\n  let _ = cb\n  x()\n}",
      line: "(cb: [e]) : [e]",
      call: fn(alias, leaf, _quiet) {
        alias <> ".k_arity(" <> leaf <> ", fn(_v) { Nil })"
      },
      exact: True,
      label: "a callback the reader spells as another arity's name, read in the effects term",
    ),
    KindCollision(
      name: "k_arity_relay",
      erlang: "(cb: fn() -> Nil, value: fn(Nil) -> Nil) -> Nil {\n  let _ = value\n  cb()\n}",
      javascript: "(x: fn() -> Nil, cb: fn(Nil) -> Nil) -> Nil {\n  let _ = cb\n  x()\n}",
      line: "(cb: [e]) : [e] where runs : [], relay : e()",
      call: fn(alias, leaf, _quiet) {
        alias <> ".k_arity_relay(" <> leaf <> ", fn(_v) { Nil })"
      },
      exact: True,
      label: "a callback the reader spells as another arity's name, read in `relay`",
    ),
  ]
}

fn kind_case(
  source: LineSource,
  kind: KindCollision,
  printing: Bool,
  n: Int,
) -> Case {
  let suffix = int.to_string(n)
  let #(module, alias) = line_source_module(source)
  let quiet = "quiet_" <> suffix
  let leaf = case printing {
    True -> "leaf_" <> suffix
    False -> quiet
  }
  Case(
    name: line_source_name(source)
      <> ", "
      <> kind.label
      <> case printing {
      True -> ", printing"
      False -> ", quiet"
    },
    body: kind.call(alias, leaf, quiet),
    helpers: "fn " <> quiet <> "() -> Nil {\n  Nil\n}\n\n",
    spec: case source, printing {
      ConsumerSpecSource, True ->
        "assume " <> module <> "." <> kind.name <> kind.line <> "\n"
      _, _ -> ""
    },
  )
}

fn translation_case(
  source: LineSource,
  function: Translated,
  printer: PrinterAt,
  n: Int,
) -> Case {
  let suffix = int.to_string(n)
  let #(module, alias) = line_source_module(source)
  let leaf = "leaf_" <> suffix
  let quiet = "quiet_" <> suffix
  let #(first, second) = case printer {
    PrinterFirst -> #(leaf, quiet)
    PrinterSecond -> #(quiet, leaf)
    PrinterNeither -> #(quiet, quiet)
  }
  let runs = "fn(g: fn() -> Nil) { g() }"
  let drops = "fn(g: fn() -> Nil) {\n    let _ = g\n    Nil\n  }"
  let call = alias <> "." <> function.name
  let body = case function.symbol {
    BareSymbol -> call <> "(" <> first <> ", " <> second <> ")"
    ReturnsSymbol ->
      "ffi.run_fields("
      <> call
      <> "(fn() { "
      <> alias
      <> ".Box("
      <> first
      <> ") }, fn() { "
      <> alias
      <> ".Box("
      <> second
      <> ") }))"
    AppliedSymbol -> {
      let #(op1, op2) = case printer {
        PrinterFirst -> #(runs, drops)
        PrinterSecond -> #(drops, runs)
        PrinterNeither -> #(drops, drops)
      }
      call <> "(" <> op1 <> ", " <> op2 <> ", " <> leaf <> ")"
    }
  }
  // The consumer's own line is written once per function.
  let spec = case source, printer {
    ConsumerSpecSource, PrinterFirst -> translation_line(module, function)
    _, _ -> ""
  }
  Case(
    name: line_source_name(source)
      <> ", "
      <> function.label
      <> ", "
      <> case printer {
      PrinterFirst -> "printing in the first callback"
      PrinterSecond -> "printing in the second callback"
      PrinterNeither -> "printing in neither"
    },
    body:,
    helpers: "fn " <> quiet <> "() -> Nil {\n  Nil\n}\n\n",
    spec:,
  )
}

// A line over a dependency's function defined once per target, crossed by
// what wrote it, the symbol it reads the first callback through, how that
// callback's variable is spelled, and which callback the case makes print,
// beside a reader renaming its second parameter and one keeping the
// publisher's names, in an app read on each target alone and on both. Each
// line is exact for both variants, so every answer is the labels the case
// prints.
fn translation_dimension_cases(graded: String, root: String) -> Outcome {
  let sources = [
    PathSpecSource,
    InstalledSpecSource,
    ConsumerSpecSource,
    CatalogSource,
  ]
  let shapes =
    list.flat_map(sources, fn(source) {
      list.flat_map(translated_functions(), fn(function) {
        list.map([PrinterFirst, PrinterSecond, PrinterNeither], fn(printer) {
          #(source, function, printer)
        })
      })
    })
  let translated =
    list.map(shapes, fn(shape) {
      let #(source, function, printer) = shape
      fn(n) {
        #(translation_case(source, function, printer, n), [
          "erlang", "javascript", "both",
        ])
      }
    })
  let kinds =
    list.flat_map(sources, fn(source) {
      list.flat_map(kind_collisions(), fn(kind) {
        list.map([True, False], fn(printing) {
          fn(n) {
            #(kind_case(source, kind, printing, n), case kind.exact {
              True -> ["erlang", "javascript", "both"]
              False -> []
            })
          }
        })
      })
    })
  let cells =
    list.append(translated, kinds)
    |> list.index_map(fn(build, index) { build(index + 1) })
  let dependency = fn(name) {
    write(
      root <> "/" <> name <> "/gleam.toml",
      "name = \""
        <> name
        <> "\"\nversion = \"1.0.0\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
    )
    write(
      root <> "/" <> name <> "/src/" <> name <> ".gleam",
      translation_module(),
    )
  }
  list.each(["tr_path", "tr_own", "tr_cat"], dependency)
  write(root <> "/tr_path/tr_path.graded", translation_lines("tr_path"))
  let directory = root <> "/app"
  write_project_importing(
    directory,
    "erlang",
    list.map(cells, fn(cell) { cell.0 }),
    "import gleam/tr_installed\nimport tr_cat\nimport tr_own\nimport tr_path\n",
  )
  let toml =
    app_toml(
      "tr_cat = { path = \"../tr_cat\" }\ntr_own = { path = \"../tr_own\" }\ntr_path = { path = \"../tr_path\" }\n",
    )
  write(directory <> "/gleam.toml", toml("[\"erlang\", \"javascript\"]"))
  let downloaded =
    shellout.command(
      run: "gleam",
      with: ["deps", "download"],
      in: directory,
      opt: [],
    )
  let stdlib = directory <> "/build/packages/gleam_stdlib"
  write(stdlib <> "/src/gleam/tr_installed.gleam", translation_module())
  write(
    stdlib <> "/gleam_stdlib.graded",
    translation_lines("gleam/tr_installed"),
  )
  write(
    stdlib <> "/gleam.toml",
    read(stdlib <> "/gleam.toml")
      <> "\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
  )
  let catalog = graded <> "/priv/catalog/tr_cat@1.0.0"
  write(catalog <> ".graded", translation_lines("tr_cat"))
  write(
    catalog <> ".audit",
    "covers 1.0.0\n"
      <> string.concat(
      list.append(
        list.map(translated_functions(), fn(function) { function.name }),
        list.map(kind_collisions(), fn(kind) { kind.name }),
      )
      |> list.map(fn(name) { "reviewed tr_cat." <> name <> "\n" }),
    ),
  )
  let outcome = case downloaded {
    Error(failure) ->
      Outcome(
        ["translation dependencies did not download:\n" <> failure.1],
        0,
        list.length(cells),
      )
    Ok(_) ->
      readings_outcome("translation", graded, directory, cells, toml, False)
  }
  let _ = simplifile.delete(catalog <> ".graded")
  let _ = simplifile.delete(catalog <> ".audit")
  Outcome(
    ..outcome,
    failures: list.append(outcome.failures, kind_control(graded, root)),
  )
}

// A consumer line valid only in the Erlang variant of a function whose first
// parameter is a callback on Erlang and a box on JavaScript: read on Erlang,
// where the case prints; refused on JavaScript alone, with a warning naming
// it, when the app is read on both; and stopping a run on JavaScript alone.
fn kind_control(graded: String, root: String) -> List(String) {
  let dependency = root <> "/tr_kind"
  write(
    dependency <> "/gleam.toml",
    "name = \"tr_kind\"\nversion = \"1.0.0\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
  )
  write(
    dependency <> "/src/tr_kind.gleam",
    "pub type Box {\n  Box(f: fn() -> Nil)\n}\n\n@target(erlang)\npub fn call(cb: fn() -> Nil, value: fn() -> Nil) -> Nil {\n  let _ = value\n  cb()\n}\n\n@target(javascript)\npub fn call(cb: Box, value: fn() -> Nil) -> Nil {\n  let _ = cb\n  value()\n}\n",
  )
  let directory = root <> "/kind_app"
  write_project_importing(
    directory,
    "erlang",
    [
      Case(
        name: "a consumer line valid only in the Erlang variant",
        body: "kind_call_1()",
        helpers: "fn quiet_1() -> Nil {\n  Nil\n}\n\n@target(erlang)\nfn kind_call_1() -> Nil {\n  tr_kind.call(leaf_1, quiet_1)\n}\n\n@target(javascript)\nfn kind_call_1() -> Nil {\n  tr_kind.call(tr_kind.Box(quiet_1), quiet_1)\n}\n\n",
        spec: "assume tr_kind.call(cb: [e]) : [e]\n",
      ),
    ],
    "import tr_kind\n",
  )
  let toml = app_toml("tr_kind = { path = \"../tr_kind\" }\n")
  write(directory <> "/gleam.toml", toml("[\"erlang\"]"))
  let written = read(directory <> "/app.graded")
  case observed(directory, "erlang") {
    Error(output) -> ["kind control app did not run:\n" <> output]
    Ok(printed) -> {
      let printed = dict.get(printed, "case_1") |> result.unwrap(set.new())
      let erlang =
        dict.get(answers(graded, directory), "case_1")
        |> result.unwrap(set.new())
      write(directory <> "/app.graded", written)
      write(directory <> "/gleam.toml", toml("[\"erlang\", \"javascript\"]"))
      let warned = case
        shellout.command(
          run: "sh",
          with: ["-c", "gleam run -m graded -- check " <> directory <> " 2>&1"],
          in: graded,
          opt: [],
        )
      {
        Ok(output) | Error(#(_, output)) -> output
      }
      write(directory <> "/gleam.toml", toml("[\"javascript\"]"))
      let javascript = graded.inferred_lines(directory)
      write(directory <> "/gleam.toml", toml("[\"erlang\", \"javascript\"]"))
      [
        case erlang == printed {
          True -> Error(Nil)
          False ->
            Ok(
              "translation kind control read on erlang: printed "
              <> labels(printed)
              <> ", answered "
              <> labels(erlang),
            )
        },
        case
          string.contains(warned, "(on javascript)")
          && string.contains(warned, "is read on erlang")
          && !string.contains(warned, "(on erlang")
        {
          True -> Error(Nil)
          False ->
            Ok(
              "translation kind control read on both targets did not refuse the line on javascript alone:\n"
              <> warned,
            )
        },
        case javascript {
          Error(_) -> Error(Nil)
          Ok(_) ->
            Ok(
              "translation kind control read on javascript alone read a line its variant forbids",
            )
        },
      ]
      |> list.filter_map(fn(failure) { failure })
    }
  }
}

// The scaling dimension

// How much more work four times the input may cost, over a constant
// baseline: four times n log n is at most 5 at the sizes measured, so 6
// admits that and fails anything quadratic, which costs 16.
const scaling_multiple = 6

// A package read on both targets with a function defined once per target
// and `pairs` more in its one module, each beside an `effects` and a `check`
// line where `committed`, and `warnings` `check` lines naming nothing.
fn scaling_package(
  directory: String,
  pairs: Int,
  committed: Bool,
  warnings: Int,
) -> Nil {
  let indices = numbers(pairs) |> list.map(fn(n) { n - 1 })
  let name = fn(i) { "app.f" <> int.to_string(i) }
  write(
    directory <> "/gleam.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
  )
  write(
    directory <> "/app.graded",
    case committed {
      True ->
        list.map(indices, fn(i) {
          "effects " <> name(i) <> " : []\ncheck " <> name(i) <> " : []\n"
        })
      False -> []
    }
      |> list.append(
        numbers(warnings)
        |> list.map(fn(i) {
          "check app.missing_" <> int.to_string(i) <> " : []\n"
        }),
      )
      |> string.concat,
  )
  write(
    directory <> "/src/app.gleam",
    "@target(erlang)\npub fn g() -> Nil {\n  Nil\n}\n\n@target(javascript)\npub fn g() -> Nil {\n  Nil\n}\n\n"
      <> string.concat(
      list.map(indices, fn(i) {
        let s = int.to_string(i)
        "@target(erlang)\npub fn f"
        <> s
        <> "(cb: fn() -> Nil) -> Nil {\n  let _ = cb\n  Nil\n}\n\n@target(javascript)\npub fn f"
        <> s
        <> "(x: fn() -> Nil) -> Nil {\n  let _ = x\n  Nil\n}\n\n"
      }),
    )
      <> "pub fn main() -> Nil {\n  Nil\n}\n",
  )
}

// A dependency defining `pairs` functions once per target, each taking a
// callback on Erlang and, where `boxed`, a box on JavaScript, beside an app
// read on `targets` whose spec bounds each one: on both targets a line only
// Erlang can read where `boxed`, one both read otherwise.
fn scaling_pair_lines(
  directory: String,
  pairs: Int,
  boxed: Bool,
  targets: String,
) -> Nil {
  let indices = numbers(pairs) |> list.map(fn(n) { n - 1 })
  let name = fn(i) { "f" <> int.to_string(i) }
  write(
    directory <> "/tr_lines/gleam.toml",
    "name = \"tr_lines\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
  )
  write(
    directory <> "/tr_lines/src/tr_lines.gleam",
    "pub type Box {\n  Box(run: fn() -> Nil)\n}\n\n@target(erlang)\npub fn g() -> Nil {\n  Nil\n}\n\n@target(javascript)\npub fn g() -> Nil {\n  Nil\n}\n\n"
      <> string.concat(
      list.map(indices, fn(i) {
        let javascript = case boxed {
          True -> "(cb: Box) -> Nil {\n  cb.run()\n}\n\n"
          False -> "(x: fn() -> Nil) -> Nil {\n  x()\n}\n\n"
        }
        "@target(erlang)\npub fn "
        <> name(i)
        <> "(cb: fn() -> Nil) -> Nil {\n  cb()\n}\n\n@target(javascript)\npub fn "
        <> name(i)
        <> javascript
      }),
    ),
  )
  write(
    directory <> "/app/gleam.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n\n[dependencies]\ntr_lines = { path = \"../tr_lines\" }\n\n[tools.graded]\ntargets = "
      <> targets
      <> "\n",
  )
  write(
    directory <> "/app/app.graded",
    string.concat(
      list.map(indices, fn(i) {
        "assume tr_lines." <> name(i) <> "(cb: [e]) : [e]\n"
      }),
    ),
  )
  write(directory <> "/app/src/app.gleam", "pub fn main() -> Nil {\n  Nil\n}\n")
}

// An app read on JavaScript alone whose own `forbidden` functions each take a
// box under a line charging what it carries.
fn scaling_forbidden(directory: String, forbidden: Int) -> Nil {
  let indices = numbers(forbidden) |> list.map(fn(n) { n - 1 })
  let name = fn(i) { "f" <> int.to_string(i) }
  write(
    directory <> "/gleam.toml",
    "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"javascript\"\n\n[tools.graded]\ntargets = [\"javascript\"]\n",
  )
  write(
    directory <> "/app.graded",
    string.concat(
      list.map(indices, fn(i) {
        "assume app." <> name(i) <> "(cb: [e]) : [e]\n"
      }),
    ),
  )
  write(
    directory <> "/src/app.gleam",
    "pub type Box {\n  Box(run: fn() -> Nil)\n}\n\npub fn g(cb: Box) -> Nil {\n  cb.run()\n}\n\n"
      <> string.concat(
      list.map(indices, fn(i) {
        "pub fn " <> name(i) <> "(cb: Box) -> Nil {\n  cb.run()\n}\n\n"
      }),
    ),
  )
}

// An app read on JavaScript alone over a dependency with `modules` modules
// beside one, each defining a function once per target.
fn scaling_paired_modules(directory: String, modules: Int) -> Nil {
  list.each([0, ..numbers(modules)], fn(n) {
    write(
      directory
        <> "/tr_modules/src/tr_modules/m"
        <> int.to_string(n)
        <> ".gleam",
      "@target(erlang)\npub fn f() -> Nil {\n  Nil\n}\n\n@target(javascript)\npub fn f() -> Nil {\n  Nil\n}\n",
    )
  })
  write(
    directory <> "/tr_modules/gleam.toml",
    "name = \"tr_modules\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
  )
  write(
    directory <> "/app/gleam.toml",
    "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"javascript\"\n\n[dependencies]\ntr_modules = { path = \"../tr_modules\" }\n\n[tools.graded]\ntargets = [\"javascript\"]\n",
  )
  write(directory <> "/app/app.graded", "")
  write(
    directory <> "/app/src/app.gleam",
    "import tr_modules/m0\n\npub fn main() -> Nil {\n  m0.f()\n}\n",
  )
}

// The reductions one command over the project at `directory` spends.
fn command_work(command: String, directory: String) -> Int {
  let before = reductions()
  let _ = case command {
    "infer" -> graded.inferred_lines(directory) |> result.replace(Nil)
    "check" -> graded.run(directory) |> result.replace(Nil)
    "why" -> graded.run_why(directory, "app.main") |> result.replace(Nil)
    _ -> graded.run_effect(directory, "app.main") |> result.replace(Nil)
  }
  reductions() - before
}

// Each public command over each input the branch reads at none, N and 4N of
// it: the work four times the input adds over the empty project stays within
// `scaling_multiple` times what N adds.
fn scaling_dimension_cases(root: String) -> Outcome {
  // Each axis at a size where a scan per item would outweigh the linear
  // work beside it.
  let axes = [
    #(
      "pairs in one module",
      1024,
      ["infer", "check", "why", "effect"],
      fn(d, n) {
        scaling_package(d, n, False, 0)
        d
      },
    ),
    #("committed effects and check lines over pairs", 1024, ["check"], fn(d, n) {
      scaling_package(d, n, True, 0)
      d
    }),
    #("spec warnings", 2048, ["check"], fn(d, n) {
      scaling_package(d, 0, False, n)
      d
    }),
    #("lines refused on one target", 256, ["infer", "check"], fn(d, n) {
      scaling_pair_lines(d, n, True, "[\"erlang\", \"javascript\"]")
      d <> "/app"
    }),
    #("assume lines over pairs", 256, ["infer", "check"], fn(d, n) {
      scaling_pair_lines(d, n, False, "[\"erlang\", \"javascript\"]")
      d <> "/app"
    }),
    #("forbidden lines", 256, ["infer"], fn(d, n) {
      scaling_forbidden(d, n)
      d
    }),
    #("paired modules in a dependency", 256, ["infer"], fn(d, n) {
      scaling_paired_modules(d, n)
      d <> "/app"
    }),
    #(
      "check lines over functions built on one target",
      1024,
      ["check", "why", "effect"],
      fn(d, n) {
        scaling_one_target(d, n)
        d
      },
    ),
  ]
  let cells =
    list.flat_map(axes, fn(axis) {
      let #(label, size, commands, build) = axis
      list.map(commands, fn(command) { #(label, size, command, build) })
    })
  let failures =
    list.index_map(cells, fn(cell, index) {
      let #(label, size, command, build) = cell
      let at = fn(n) {
        let directory =
          root <> "/c" <> int.to_string(index) <> "_" <> int.to_string(n)
        let project = build(directory, n)
        // Read once before measuring, so code loading is not counted.
        let _ = command_work(command, project)
        command_work(command, project)
      }
      let base = at(0)
      let small = at(size)
      let large = at(4 * size)
      case large - base <= scaling_multiple * int.max(small - base, 1) {
        True -> Error(Nil)
        False ->
          Ok(
            "scaling: "
            <> command
            <> " over "
            <> label
            <> " spent "
            <> int.to_string(base)
            <> ", "
            <> int.to_string(small)
            <> " and "
            <> int.to_string(large)
            <> " reductions at 0, "
            <> int.to_string(size)
            <> " and "
            <> int.to_string(4 * size)
            <> ", past "
            <> int.to_string(scaling_multiple)
            <> " times the growth",
          )
      }
    })
    |> list.filter_map(fn(failure) { failure })
  Outcome(failures, 0, list.length(cells))
}

// An app read on both targets, split by one function it defines once per
// target, whose `functions` other functions are built on Erlang alone, each
// with a `check` line.
fn scaling_one_target(directory: String, functions: Int) -> Nil {
  let indices = numbers(functions) |> list.map(fn(n) { n - 1 })
  write(
    directory <> "/gleam.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
  )
  write(
    directory <> "/app.graded",
    string.concat(
      list.map(indices, fn(i) { "check app.f" <> int.to_string(i) <> " : []\n" }),
    ),
  )
  write(
    directory <> "/src/app.gleam",
    "@target(erlang)\nfn g() -> Nil {\n  Nil\n}\n\n@target(javascript)\nfn g() -> Nil {\n  Nil\n}\n\npub fn main() -> Nil {\n  g()\n}\n\n"
      <> string.concat(
      list.map(indices, fn(i) {
        "@target(erlang)\npub fn f"
        <> int.to_string(i)
        <> "() -> Nil {\n  g()\n}\n\n"
      }),
    ),
  )
}

// The one-target dimension

// A path dependency defining a private function once per target that prints
// on one target and is quiet on the other, beside public functions reaching
// each: `quiet_on_erlang` prints on JavaScript alone, `quiet_on_javascript` on
// Erlang alone.
const one_target_dependency =
  "@external(erlang, \"pairdep_ffi\", \"shout\")
@external(javascript, \"./pairdep_ffi.mjs\", \"shout\")
pub fn shout() -> Nil

@target(javascript)
fn on_javascript() -> Nil {
  shout()
}

@target(erlang)
fn on_javascript() -> Nil {
  Nil
}

@target(erlang)
fn on_erlang() -> Nil {
  shout()
}

@target(javascript)
fn on_erlang() -> Nil {
  Nil
}

pub fn quiet_on_erlang() -> Nil {
  on_javascript()
}

pub fn quiet_on_javascript() -> Nil {
  on_erlang()
}
"

// An app read on both targets, split by its path dependency, whose public
// functions are each built on one target only: on Erlang alone, on JavaScript
// alone, on Erlang alone and calling another function built only there, and on
// Erlang alone building the value a field `check` weighs. Each calls the
// dependency's function that is quiet where it is built. Run natively on both
// targets, nothing prints; every function answers `[]`; the field `check`
// passes, and the same check over a site wiring the printing function fails;
// and the consistency oracle holds.
fn one_target_cases(graded: String, root: String) -> Outcome {
  let directory = root <> "/app"
  let dependency = root <> "/pairdep"
  write(
    dependency <> "/gleam.toml",
    "name = \"pairdep\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
  )
  write(dependency <> "/src/pairdep.gleam", one_target_dependency)
  write(
    dependency <> "/src/pairdep_ffi.erl",
    "-module(pairdep_ffi).\n-export([shout/0]).\nshout() -> io:format(\"LOUD~n\"), nil.\n",
  )
  write(
    dependency <> "/src/pairdep_ffi.mjs",
    "export function shout() {\n  console.log(\"LOUD\");\n}\n",
  )
  write(
    directory <> "/gleam.toml",
    "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n\n[dependencies]\npairdep = { path = \""
      <> dependency
      <> "\" }\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
  )
  write(
    directory <> "/src/app.gleam",
    "import pairdep

pub type Box {
  Box(run: fn() -> Nil)
}

pub type Loud {
  Loud(run: fn() -> Nil)
}

@target(erlang)
pub fn erlang_only() -> Nil {
  pairdep.quiet_on_erlang()
}

@target(javascript)
pub fn javascript_only() -> Nil {
  pairdep.quiet_on_javascript()
}

@target(erlang)
fn erlang_helper() -> Nil {
  pairdep.quiet_on_erlang()
}

@target(erlang)
pub fn erlang_chain() -> Nil {
  erlang_helper()
}

@target(erlang)
pub fn erlang_box() -> Box {
  Box(run: pairdep.quiet_on_erlang)
}

@target(erlang)
pub fn erlang_loud() -> Loud {
  Loud(run: pairdep.quiet_on_javascript)
}

@target(erlang)
pub fn main() -> Nil {
  erlang_only()
  erlang_chain()
  let _ = erlang_box()
  Nil
}

@target(javascript)
pub fn main() -> Nil {
  javascript_only()
}
",
  )
  write(directory <> "/app.graded", "assume pairdep.shout : [Stdout]\n")
  let names =
    dict.from_list([
      #("app.erlang_only", "built on Erlang alone"),
      #("app.javascript_only", "built on JavaScript alone"),
      #(
        "app.erlang_chain",
        "built on Erlang alone, calling a helper built only there",
      ),
      #("app.erlang_box", "built on Erlang alone, building the checked value"),
      #("app.main", "defined once per target"),
    ])
  let printed =
    list.filter_map(["erlang", "javascript"], fn(target) {
      case
        shellout.command(
          run: "gleam",
          with: ["run", "--target", target],
          in: directory,
          opt: [],
        )
      {
        Ok(output) ->
          case string.contains(output, "LOUD") {
            True -> Ok("one-target: the app printed on " <> target)
            False -> Error(Nil)
          }
        Error(#(_, output)) ->
          Ok("one-target: the app did not run on " <> target <> ":\n" <> output)
      }
    })
  let answered = answers(graded, directory)
  let spec = read(directory <> "/app.graded")
  let off =
    dict.to_list(names)
    |> list.filter_map(fn(entry) {
      let function = string.drop_start(entry.0, string.length("app."))
      case dict.get(answered, function) {
        Ok(answer) ->
          case set.is_empty(answer) {
            True -> Error(Nil)
            False ->
              Ok(
                "one-target "
                <> entry.0
                <> " ("
                <> entry.1
                <> "): answered "
                <> labels(answer)
                <> ", which nothing that builds it prints",
              )
          }
        Error(Nil) ->
          Ok("one-target " <> entry.0 <> " (" <> entry.1 <> "): no answer")
      }
    })
  let inconsistent = consistency_failures("one-target", directory, spec, names)
  // The field checks: the quiet site's passes, the printing one's fails.
  write(
    directory <> "/app.graded",
    string.trim_end(spec)
      <> "\ncheck app.Box.run : []\ncheck app.Loud.run : []\n",
  )
  let fields = case graded.run(directory) {
    Error(_) -> ["one-target: the field checks did not run"]
    Ok(reports) -> {
      let lines = list.flat_map(reports, fn(report) { report.violations })
      let box = list.any(lines, string.contains(_, "Box.run"))
      let loud = list.any(lines, string.contains(_, "Loud.run"))
      case box, loud {
        False, True -> []
        _, _ -> [
          "one-target: the field check over a quiet site on Erlang "
          <> bool_text(!box)
          <> " passed, over a printing one "
          <> bool_text(!loud)
          <> " passed; expected yes, no",
        ]
      }
    }
  }
  write(directory <> "/app.graded", spec)
  Outcome(
    list.flatten([printed, off, inconsistent, fields]),
    0,
    dict.size(names) + 2,
  )
}

// The dependency-location dimension

// Where a path dependency lives and how its path is written: each place the
// directory under the block's root holding the app, the dependency's directory
// beside it, and the path the app declares, absolute where `None`.
const dependency_places = [
  #("a directory named src", "", "src", option.None),
  #("outer/src/lib", "", "outer/src/lib", option.None),
  #("a root holding src segments", "src/x/src/", "lib", option.None),
  #("../lib", "", "lib", option.Some("../lib")),
  #("./deps/lib", "", "app/deps/lib", option.Some("./deps/lib")),
  #("a path through ..", "", "lib", option.Some("../outer/../lib")),
]

// An app read on both targets whose `main` is built on Erlang alone and calls
// a path dependency whose private helper prints on JavaScript alone, with the
// dependency at `place`: `infer`'s line for `main`, `effect`'s answer, `why`'s
// first line, whether the run was split, and how many `check` violations.
fn located_answers(
  root: String,
  prefix: String,
  dependency: String,
  declared: option.Option(String),
) -> #(String, String, String, Bool, Int) {
  let base = root <> "/" <> prefix
  let app = base <> "app"
  let dep = base <> dependency
  write(base <> "outer/.keep", "")
  write(
    app <> "/gleam.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n\n[dependencies]\ndep = { path = \""
      <> option.unwrap(declared, dep)
      <> "\" }\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
  )
  write(
    app <> "/app.graded",
    "assume dep.shout : [Stdout]\ncheck app.main : []\n",
  )
  write(
    app <> "/src/app.gleam",
    "import dep\n\n@target(erlang)\npub fn main() -> Nil {\n  dep.run()\n}\n",
  )
  write(
    dep <> "/gleam.toml",
    "name = \"dep\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
  )
  write(
    dep <> "/src/dep.gleam",
    "@external(erlang, \"dep_ffi\", \"shout\")\n@external(javascript, \"./dep_ffi.mjs\", \"shout\")\npub fn shout() -> Nil\n\n@target(javascript)\nfn helper() -> Nil {\n  shout()\n}\n\n@target(erlang)\nfn helper() -> Nil {\n  Nil\n}\n\npub fn run() -> Nil {\n  helper()\n}\n",
  )
  let inferred =
    graded.inferred_lines(app)
    |> result.unwrap([])
    |> list.find(string.starts_with(_, "effects app.main"))
    |> result.unwrap("no line")
  let effect = graded.run_effect(app, "app.main") |> result.unwrap("no answer")
  let why = graded.run_why(app, "app.main") |> result.unwrap("no answer")
  let violations =
    graded.run(app)
    |> result.map(list.flat_map(_, fn(report) { report.violations }))
    |> result.unwrap(["no report"])
    |> list.length
  #(
    inferred,
    collapsed(effect),
    string.split(why, "\n") |> list.first |> result.unwrap(""),
    string.contains(why, "(on erlang)"),
    violations,
  )
}

// The same dependency in every place of `dependency_places` answers as it does
// declared by its absolute path in a directory named `lib`, and splits the run
// the same way.
fn location_cases(root: String) -> Outcome {
  let control = located_answers(root <> "/control", "", "lib", option.None)
  let failures =
    list.index_map(dependency_places, fn(place, index) {
      let #(name, prefix, dependency, declared) = place
      let found =
        located_answers(
          root <> "/p" <> int.to_string(index),
          prefix,
          dependency,
          declared,
        )
      case found == control {
        True -> Error(Nil)
        False ->
          Ok(
            "dependency location "
            <> name
            <> ": answered "
            <> string.inspect(found)
            <> ", the lib control "
            <> string.inspect(control),
          )
      }
    })
    |> list.filter_map(fn(failure) { failure })
  let unsplit = case control.3 {
    True -> []
    False -> ["dependency location: the lib control was not split"]
  }
  Outcome(list.append(unsplit, failures), 0, list.length(dependency_places))
}

// The refusal cost dimension

// The reductions one inference over a `refusal_cost_cases` app may spend.
const refusal_work_bound = 60_000_000

// Two apps whose spec bounds many functions so that a line the rules forbid
// is quoted for each: one read on both targets whose 512 lines over a
// dependency's pairs only Erlang can read, quiet and within
// `refusal_work_bound`; and one read on JavaScript alone whose 1,024 own
// lines all charge what a box carries, stopping on the first within the same
// bound.
fn refusal_cost_cases(graded: String, root: String) -> Outcome {
  let refused = root <> "/partial"
  let pairs = numbers(512) |> list.map(fn(n) { n - 1 })
  let name = fn(i) { "f" <> int.to_string(i) }
  write(
    refused <> "/tr_refused/gleam.toml",
    "name = \"tr_refused\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
  )
  write(
    refused <> "/tr_refused/src/tr_refused.gleam",
    "pub type Box {\n  Box(run: fn() -> Nil)\n}\n\n"
      <> string.concat(
      list.map(pairs, fn(i) {
        "@target(erlang)\npub fn "
        <> name(i)
        <> "(cb: fn() -> Nil) -> Nil {\n  cb()\n}\n\n@target(javascript)\npub fn "
        <> name(i)
        <> "(cb: Box) -> Nil {\n  cb.run()\n}\n\n"
      }),
    ),
  )
  write(
    refused <> "/app/gleam.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n\n[dependencies]\ntr_refused = { path = \"../tr_refused\" }\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
  )
  write(
    refused <> "/app/app.graded",
    string.concat(
      list.map(pairs, fn(i) {
        "assume tr_refused." <> name(i) <> "(cb: [e]) : [e]\n"
      }),
    ),
  )
  write(refused <> "/app/src/app.gleam", "pub fn main() -> Nil {\n  Nil\n}\n")
  let forbidden = root <> "/forbidden"
  let own = numbers(1024) |> list.map(fn(n) { n - 1 })
  write(
    forbidden <> "/gleam.toml",
    "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"javascript\"\n\n[tools.graded]\ntargets = [\"javascript\"]\n",
  )
  write(
    forbidden <> "/app.graded",
    string.concat(
      list.map(own, fn(i) { "assume app." <> name(i) <> "(cb: [e]) : [e]\n" }),
    ),
  )
  write(
    forbidden <> "/src/app.gleam",
    "pub type Box {\n  Box(run: fn() -> Nil)\n}\n\n"
      <> string.concat(
      list.map(own, fn(i) {
        "pub fn " <> name(i) <> "(cb: Box) -> Nil {\n  cb.run()\n}\n\n"
      }),
    ),
  )
  let measured = fn(directory) {
    let before = reductions()
    let lines = graded.inferred_lines(directory)
    #(lines, reductions() - before)
  }
  let over = fn(cell, spent) {
    case spent > refusal_work_bound {
      False -> Error(Nil)
      True ->
        Ok(
          "refusal cost: "
          <> cell
          <> " spent "
          <> int.to_string(spent)
          <> " reductions, past the bound of "
          <> int.to_string(refusal_work_bound),
        )
    }
  }
  let #(partial, partial_spent) = measured(refused <> "/app")
  let #(stopped, stopped_spent) = measured(forbidden)
  let failures =
    [
      case partial {
        Ok(lines) ->
          case list.contains(lines, "effects app.main : []") {
            True -> Error(Nil)
            False ->
              Ok(
                "refusal cost: the app with lines refused on javascript is not read as quiet",
              )
          }
        Error(_) ->
          Ok(
            "refusal cost: the app with lines refused on javascript alone stopped",
          )
      },
      over("the app with lines refused on javascript", partial_spent),
      case stopped {
        Error(_) -> Error(Nil)
        Ok(_) ->
          Ok("refusal cost: the app whose own lines are forbidden was read")
      },
      over("the app whose own lines are forbidden", stopped_spent),
    ]
    |> list.filter_map(fn(failure) { failure })
  let quotes = quote_cells(graded, root <> "/quotes")
  Outcome(list.append(failures, quotes), 0, 2 + quote_cell_count)
}

// How many cells `quote_cells` holds.
const quote_cell_count = 6

// Statements over a path other statements share, each quoted from its own
// place in the spec: a forbidden line after a valid one over the same
// function, read on both targets and on Erlang alone; two forbidden lines
// after one; a forbidden line continued onto a clause line; one after a
// module line; and two lines refused on JavaScript alone after a valid one,
// each warned about at its own line.
fn quote_cells(graded: String, root: String) -> List(String) {
  let dependency = fn(name, erlang_first) {
    write(
      root <> "/" <> name <> "/gleam.toml",
      "name = \""
        <> name
        <> "\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
    )
    write(
      root <> "/" <> name <> "/src/" <> name <> ".gleam",
      "pub type Box {\n  Box(run: fn() -> Nil)\n}\n\n@target(erlang)\npub fn call("
        <> erlang_first
        <> ", value: fn() -> Nil) -> Nil {\n  let _ = value\n  let _ = cb\n  Nil\n}\n\n@target(javascript)\npub fn call(cb: Box, value: fn() -> Nil) -> Nil {\n  let _ = value\n  cb.run()\n}\n",
    )
  }
  dependency("tr_quote", "cb: Box")
  dependency("tr_partial", "cb: fn() -> Nil")
  let app = fn(name, dependency, targets, spec) {
    let directory = root <> "/" <> name
    write(
      directory <> "/gleam.toml",
      "name = \"app\"\nversion = \"1.0.0\"\n\n[dependencies]\n"
        <> dependency
        <> " = { path = \"../"
        <> dependency
        <> "\" }\n\n[tools.graded]\ntargets = "
        <> targets
        <> "\n",
    )
    write(directory <> "/app.graded", spec)
    write(directory <> "/src/app.gleam", "pub fn main() -> Nil {\n  Nil\n}\n")
    directory
  }
  let both = "[\"erlang\", \"javascript\"]"
  let quoted = fn(directory) {
    case graded.inferred_lines(directory) {
      Error(graded.GradedParseError(message:, ..)) ->
        string.split(message, "\n") |> list.first |> result.unwrap("")
      Error(_) -> "another error"
      Ok(_) -> "no error"
    }
  }
  let one =
    "// first declaration is valid\nassume tr_quote.call : []\n\n// this bounded declaration is forbidden\nassume tr_quote.call(cb: [e], value: []) : [e]\n"
  let forbidden = "assume tr_quote.call(cb: [e], value: []) : [e]"
  let errors = [
    #(
      "one forbidden line after a valid one, on both targets",
      app("one_both", "tr_quote", both, one),
      "5: " <> forbidden,
    ),
    #(
      "one forbidden line after a valid one, on Erlang alone",
      app("one_erlang", "tr_quote", "[\"erlang\"]", one),
      "5: " <> forbidden,
    ),
    #(
      "two forbidden lines after a valid one",
      app(
        "many",
        "tr_quote",
        both,
        "assume tr_quote.call : []\n\nassume tr_quote.call(cb: [e], value: []) : [e]\nassume tr_quote.call(cb: [u], value: []) : [u]\n",
      ),
      "3: " <> forbidden,
    ),
    #(
      "a forbidden line continued onto a clause line",
      app(
        "continued",
        "tr_quote",
        both,
        "// heading\n\nassume tr_quote.call(cb: [e], value: []) : [e]\n  where carries : [e.returns]\n",
      ),
      "3: " <> forbidden <> " where carries : [e.returns]",
    ),
    #(
      "a forbidden line after a module line",
      app(
        "module_function",
        "tr_quote",
        both,
        "assume tr_quote : []\nassume tr_quote.call(cb: [e], value: []) : [e]\n",
      ),
      "2: " <> forbidden,
    ),
  ]
  let error_failures =
    list.filter_map(errors, fn(cell) {
      let #(name, directory, expected) = cell
      let got = quoted(directory)
      case got == expected {
        True -> Error(Nil)
        False ->
          Ok(
            "quotes: "
            <> name
            <> " quoted `"
            <> got
            <> "`, not `"
            <> expected
            <> "`",
          )
      }
    })
  let partial =
    app(
      "partial",
      "tr_partial",
      both,
      "assume tr_partial.call : []\n\nassume tr_partial.call(cb: [e], value: []) : [e]\nassume tr_partial.call(cb: [u], value: []) : [u]\n",
    )
  let warned = case
    shellout.command(
      run: "sh",
      with: ["-c", "gleam run -m graded -- check " <> partial <> " 2>&1"],
      in: graded,
      opt: [],
    )
  {
    Ok(output) | Error(#(_, output)) -> output
  }
  let partial_failures = case
    string.contains(
      warned,
      "warning: 3: assume tr_partial.call(cb: [e], value: []) : [e]",
    )
    && string.contains(
      warned,
      "warning: 4: assume tr_partial.call(cb: [u], value: []) : [u]",
    )
  {
    True -> []
    False -> [
      "quotes: two lines refused on javascript after a valid one were not each warned about at its own line:\n"
      <> warned,
    ]
  }
  list.append(error_failures, partial_failures)
}

// The pair-configuration cost dimension

// The reductions one inference over `pair_cost_cases`' app may spend.
const pair_work_bound = 20_000_000

// A single-target app over a dependency with 128 modules each defining a
// function once per target and a configuration of 1,024 further entries: its
// answer is quiet, and one inference stays within `pair_work_bound`, since
// the dependency's configuration is read once.
fn pair_cost_cases(root: String) -> Outcome {
  let dependency = root <> "/tr_wide"
  let modules = numbers(128) |> list.map(fn(n) { n - 1 })
  write(
    dependency <> "/gleam.toml",
    "name = \"tr_wide\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n\n[tools.sample]\n"
      <> string.concat(
      list.map(numbers(1024), fn(k) {
        "key_" <> int.to_string(k) <> " = " <> int.to_string(k) <> "\n"
      }),
    ),
  )
  list.each(modules, fn(n) {
    write(
      dependency <> "/src/tr_wide/m" <> int.to_string(n) <> ".gleam",
      "@target(erlang)\npub fn f() -> Nil {\n  Nil\n}\n\n@target(javascript)\npub fn f() -> Nil {\n  Nil\n}\n",
    )
  })
  let directory = root <> "/app"
  write(
    directory <> "/gleam.toml",
    "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"javascript\"\n\n[dependencies]\ntr_wide = { path = \"../tr_wide\" }\n\n[tools.graded]\ntargets = [\"javascript\"]\n",
  )
  write(directory <> "/app.graded", "")
  write(
    directory <> "/src/app.gleam",
    "import tr_wide/m0\n\npub fn main() -> Nil {\n  m0.f()\n}\n",
  )
  let before = reductions()
  let lines = graded.inferred_lines(directory)
  let spent = reductions() - before
  let failures =
    [
      case lines {
        Ok(lines) ->
          case list.contains(lines, "effects app.main : []") {
            True -> Error(Nil)
            False ->
              Ok(
                "pair-configuration cost: app.main is not read as quiet: "
                <> string.join(lines, "; "),
              )
          }
        Error(_) -> Ok("pair-configuration cost: the app was not read")
      },
      case spent > pair_work_bound {
        False -> Error(Nil)
        True ->
          Ok(
            "pair-configuration cost: one inference spent "
            <> int.to_string(spent)
            <> " reductions, past the bound of "
            <> int.to_string(pair_work_bound),
          )
      },
    ]
    |> list.filter_map(fn(failure) { failure })
  Outcome(failures, 0, 1)
}

// The written-path dimension

// Record types `T<n>L0` to `T<n>L<depth>`, each holding two of the one below,
// and every path down the deepest written out in `walk_<n>`, which calls
// itself on a record update of its argument where `recursive`. The case
// hands it a tree whose rightmost leaf is the case's leaf where `printing`,
// and whose leaves are all quiet otherwise.
fn written_path_case(
  depth: Int,
  recursive: Bool,
  printing: Bool,
  n: Int,
) -> Case {
  let s = int.to_string(n)
  let level = fn(index) { "T" <> s <> "L" <> int.to_string(index) }
  let levels = numbers(depth)
  let types =
    "pub type "
    <> level(0)
    <> " {\n  "
    <> level(0)
    <> "(run: fn() -> Nil)\n}\n\n"
    <> string.concat(
      list.map(levels, fn(index) {
        "pub type "
        <> level(index)
        <> " {\n  "
        <> level(index)
        <> "(left: "
        <> level(index - 1)
        <> ", right: "
        <> level(index - 1)
        <> ")\n}\n\n"
      }),
    )
  let paths =
    list.fold(levels, ["b"], fn(paths, _) {
      list.flat_map(paths, fn(path) { [path <> ".left", path <> ".right"] })
    })
  let top = level(depth)
  let walk = case recursive {
    False ->
      "fn walk_"
      <> s
      <> "(b: "
      <> top
      <> ") -> Nil {\n"
      <> string.concat(list.map(paths, fn(path) { "  " <> path <> ".run()\n" }))
      <> "}\n\n"
    True ->
      "fn walk_"
      <> s
      <> "(n: Int, b: "
      <> top
      <> ") -> Nil {\n  case n {\n    0 -> Nil\n    _ -> {\n"
      <> string.concat(
        list.map(paths, fn(path) { "      " <> path <> ".run()\n" }),
      )
      <> "      walk_"
      <> s
      <> "(n - 1, "
      <> top
      <> "(..b, left: b.left))\n    }\n  }\n}\n\n"
  }
  let quiet = "quiet_" <> s
  let chain = fn(prefix, leaf, other) {
    "let "
    <> prefix
    <> "0 = "
    <> level(0)
    <> "("
    <> leaf
    <> ")\n  "
    <> string.concat(
      list.map(list.take(levels, depth - 1), fn(index) {
        let below = int.to_string(index - 1)
        "let "
        <> prefix
        <> int.to_string(index)
        <> " = "
        <> level(index)
        <> "("
        <> other
        <> below
        <> ", "
        <> prefix
        <> below
        <> ")\n  "
      }),
    )
  }
  let half = int.to_string(depth - 1)
  let #(build, tree) = case printing {
    True -> #(
      chain("q", quiet, "q") <> chain("l", "leaf_" <> s, "q"),
      top <> "(q" <> half <> ", l" <> half <> ")",
    )
    False -> #(
      chain("q", quiet, "q"),
      top <> "(q" <> half <> ", q" <> half <> ")",
    )
  }
  let call = case recursive {
    False -> "walk_" <> s <> "(" <> tree <> ")"
    True -> "walk_" <> s <> "(2, " <> tree <> ")"
  }
  Case(
    name: int.to_string(list.length(paths))
      <> " written paths, "
      <> case recursive {
      True -> "recursive"
      False -> "nonrecursive"
    }
      <> case printing {
      True -> ", printing"
      False -> ", quiet"
    },
    body: build <> call,
    helpers: "fn " <> quiet <> "() -> Nil {\n  Nil\n}\n\n" <> types <> walk,
    spec: "",
  )
}

// Every path down binary record trees two to eight levels deep written out,
// read in a function that calls itself and in one that does not, printing at
// one leaf and quiet: every path the source writes is read, so each answer is
// the labels the case prints, and one inference stays within
// `fan_work_bound`.
fn written_path_dimension_cases(graded: String, root: String) -> Outcome {
  let builders =
    list.flat_map([2, 4, 6, 8], fn(depth) {
      list.flat_map([False, True], fn(recursive) {
        list.map([True, False], fn(printing) {
          written_path_case(depth, recursive, printing, _)
        })
      })
    })
  let cells =
    list.index_map(builders, fn(build, index) {
      #(build(index + 1), ["erlang", "javascript", "both"])
    })
  let directory = root <> "/app"
  write_project(directory, "erlang", list.map(cells, fn(cell) { cell.0 }))
  let outcome =
    readings_outcome(
      "written paths",
      graded,
      directory,
      cells,
      app_toml(""),
      False,
    )
  write(
    directory <> "/gleam.toml",
    app_toml("")("[\"erlang\", \"javascript\"]"),
  )
  let before = reductions()
  let _ = graded.inferred_lines(directory)
  let spent = reductions() - before
  case spent > fan_work_bound {
    False -> outcome
    True ->
      Outcome(..outcome, failures: [
        "written paths: one inference spent "
          <> int.to_string(spent)
          <> " reductions, past the bound of "
          <> int.to_string(fan_work_bound),
        ..outcome.failures
      ])
  }
}

// The operator dimension

// What a call back in hands an operator parameter: the operator it received,
// a known operator in its place, or the frame's other, unknown operator.
type OperatorEdge {
  OperatorUnchanged
  OperatorKnown
  OperatorUnknown
}

// What the operator the case passes does with the function it is handed.
type OperatorKind {
  RunsArgument
  IgnoresArgument
  RunsArgumentTwice
}

fn operator_edge_name(edge: OperatorEdge) -> String {
  case edge {
    OperatorUnchanged -> "the operator passed on unchanged"
    OperatorKnown -> "a known operator in its place"
    OperatorUnknown -> "the other, unknown operator in its place"
  }
}

fn operator_kind_name(kind: OperatorKind) -> String {
  case kind {
    RunsArgument -> "running its argument"
    IgnoresArgument -> "ignoring its argument"
    RunsArgumentTwice -> "running its argument twice"
  }
}

// One cell at case `n`: `walk_<n>` hands its operator a closure calling back
// in with what `edge` says, and the case calls it with the operator `kind`
// describes in both operator places, around the printer or a quiet function.
// Exact where the run reaches the function it names: not with an operator
// ignoring its argument around the printer, and not past an unknown operator,
// which widens.
fn operator_case(
  edge: OperatorEdge,
  kind: OperatorKind,
  printing: Bool,
  n: Int,
) -> #(Case, List(String)) {
  let s = int.to_string(n)
  let operator_body = case kind {
    RunsArgument -> "f()"
    IgnoresArgument -> "let _ = f\n  Nil"
    RunsArgumentTwice -> "f()\n  f()"
  }
  let passed = case edge {
    OperatorUnchanged -> "op, other"
    OperatorKnown -> "op_" <> s <> ", other"
    OperatorUnknown -> "other, op"
  }
  let function = case printing {
    True -> "leaf_" <> s
    False -> "quiet_" <> s
  }
  let exact = case edge, kind, printing {
    OperatorUnknown, _, _ -> []
    _, IgnoresArgument, True -> []
    _, _, _ -> ["erlang", "javascript", "both"]
  }
  #(
    Case(
      "operator recursion, "
        <> operator_edge_name(edge)
        <> ", an operator "
        <> operator_kind_name(kind)
        <> case printing {
        True -> ", around the printer"
        False -> ", around a quiet function"
      },
      "walk_" <> s <> "(2, op_" <> s <> ", op_" <> s <> ", " <> function <> ")",
      "fn quiet_"
        <> s
        <> "() -> Nil {\n  Nil\n}\n\nfn op_"
        <> s
        <> "(f: fn() -> Nil) -> Nil {\n  "
        <> operator_body
        <> "\n}\n\nfn walk_"
        <> s
        <> "(\n  n: Int,\n  op: fn(fn() -> Nil) -> Nil,\n  other: fn(fn() -> Nil) -> Nil,\n  f: fn() -> Nil,\n) -> Nil {\n  case n {\n    0 -> f()\n    _ -> op(fn() { walk_"
        <> s
        <> "(n - 1, "
        <> passed
        <> ", f) })\n  }\n}\n\n",
      "",
    ),
    exact,
  )
}

// A one-operator walk handing its operator a closure that calls back in with
// its own arguments, the operator running or ignoring what it is handed.
fn single_operator_case(kind: OperatorKind, n: Int) -> #(Case, List(String)) {
  let s = int.to_string(n)
  let operator_body = case kind {
    RunsArgument -> "f()"
    IgnoresArgument | RunsArgumentTwice -> "let _ = f\n  Nil"
  }
  #(
    Case(
      "operator recursion, one operator " <> operator_kind_name(kind),
      "walk_" <> s <> "(2, op_" <> s <> ", quiet_" <> s <> ")",
      "fn quiet_"
        <> s
        <> "() -> Nil {\n  Nil\n}\n\nfn op_"
        <> s
        <> "(f: fn() -> Nil) -> Nil {\n  "
        <> operator_body
        <> "\n}\n\nfn walk_"
        <> s
        <> "(n: Int, op: fn(fn() -> Nil) -> Nil, f: fn() -> Nil) -> Nil {\n  case n {\n    0 -> f()\n    _ -> op(fn() { walk_"
        <> s
        <> "(n - 1, op, f) })\n  }\n}\n\n",
      "",
    ),
    ["erlang", "javascript", "both"],
  )
}

// What one inference of the operator project may spend, in reductions.
const operator_work_bound = 40_000_000

// Recursion through an operator parameter, crossed by what a call back in
// hands the operator and what the operator does with its argument, and the
// one-operator walks running and ignoring it: every answer is sound, exact
// where the run reaches what it names, its two-target answer the join, and
// one inference of the project stays within `operator_work_bound`.
fn operator_dimension_cases(graded: String, root: String) -> Outcome {
  let generated =
    list.flat_map([OperatorUnchanged, OperatorKnown, OperatorUnknown], fn(edge) {
      list.flat_map(
        [RunsArgument, IgnoresArgument, RunsArgumentTwice],
        fn(kind) {
          list.map([False, True], fn(printing) {
            operator_case(edge, kind, printing, _)
          })
        },
      )
    })
  let builders =
    list.append(generated, [
      single_operator_case(RunsArgument, _),
      single_operator_case(IgnoresArgument, _),
    ])
  let cells = list.index_map(builders, fn(build, index) { build(index + 1) })
  let directory = root <> "/app"
  write_project(directory, "erlang", list.map(cells, fn(cell) { cell.0 }))
  let outcome =
    readings_outcome(
      "operator recursion",
      graded,
      directory,
      cells,
      app_toml(""),
      False,
    )
  write(
    directory <> "/gleam.toml",
    app_toml("")("[\"erlang\", \"javascript\"]"),
  )
  let before = reductions()
  let _ = graded.inferred_lines(directory)
  let spent = reductions() - before
  case spent > operator_work_bound {
    False -> outcome
    True ->
      Outcome(..outcome, failures: [
        "operator recursion: one inference spent "
          <> int.to_string(spent)
          <> " reductions, past the bound of "
          <> int.to_string(operator_work_bound),
        ..outcome.failures
      ])
  }
}

// The declared-external dimension

// Who owns an `@external` and its declaration: the app, in a module of its
// own; a path dependency, in its own spec; an installed package, which the
// app declares; a path dependency with no spec, which a catalog file and its
// audit, installed for the run, declare.
type Owner {
  OwnModule
  PathDependency
  InstalledPackage
  CatalogOwner
}

// The clause a declaration over an `@external` states, true of its foreign
// implementation, which is quiet, while the Gleam body prints or hands back
// a printer.
type Clause {
  EffectsClause
  ReturnsClause
  CarriesClause
  CarriesRecordClause
  RunsClause
  // A catalog line over an external returning a pair, with no audit row.
  UndescribedClause
}

fn owner_name(owner: Owner) -> String {
  case owner {
    OwnModule -> "own module"
    PathDependency -> "path dependency"
    InstalledPackage -> "installed package"
    CatalogOwner -> "catalogued path dependency"
  }
}

fn clause_name(clause: Clause) -> String {
  case clause {
    EffectsClause -> "effects"
    ReturnsClause -> "where returns"
    CarriesClause -> "where carries, in a pair"
    CarriesRecordClause -> "where carries, in a record"
    RunsClause -> "where runs"
    UndescribedClause -> "no clause, over a pair"
  }
}

// The module path an owner's externals live in, the name the app imports it
// under, its Erlang module and its JavaScript module beside it.
fn owner_module(owner: Owner) -> #(String, String, String, String) {
  case owner {
    OwnModule -> #("app/ext", "ext", "app_ext_ffi", "./ext_ffi.mjs")
    PathDependency -> #(
      "ext_dep",
      "ext_dep",
      "ext_dep_ffi",
      "./ext_dep_ffi.mjs",
    )
    InstalledPackage -> #(
      "gleam/latent_ext",
      "latent_ext",
      "latent_ext_ffi",
      "./latent_ext_ffi.mjs",
    )
    CatalogOwner -> #(
      "ev_catalog",
      "ev_catalog",
      "ev_catalog_ffi",
      "./ev_catalog_ffi.mjs",
    )
  }
}

// The audit rows behind a catalogued cell's lines: a container result for a
// pair's carries, a published contract for a record's, nothing over an
// undescribed pair, and a review of every other name.
fn catalog_audit_rows(clause: Clause, chained: Bool, n: Int) -> String {
  let s = int.to_string(n)
  let declared = case chained {
    True -> ["go_" <> s, "inner_" <> s]
    False -> ["go_" <> s]
  }
  let row = fn(name) {
    let path = "ev_catalog." <> name
    case clause {
      CarriesClause -> "container_result " <> path <> "\n"
      CarriesRecordClause -> "contract " <> path <> " : [] where carries : []\n"
      UndescribedClause -> ""
      EffectsClause | ReturnsClause | RunsClause -> "reviewed " <> path <> "\n"
    }
  }
  "reviewed ev_catalog.hit_"
  <> s
  <> "\n"
  <> string.concat(list.map(declared, row))
}

// One cell at case `n`: the owner's source for it, the declaration lines,
// and the case. The external covers `covered`; with `chained`, its body calls
// another external of the same shape whose body does the printing.
fn external_dimension_case(
  owner: Owner,
  clause: Clause,
  covered: String,
  chained: Bool,
  n: Int,
) -> #(String, String, Case) {
  let s = int.to_string(n)
  let #(path, alias, erlang_module, javascript_module) = owner_module(owner)
  let foreign = case covered {
    "erlang" -> erlang_module
    _ -> javascript_module
  }
  let hit =
    "@external(erlang, \""
    <> erlang_module
    <> "\", \"hit_"
    <> s
    <> "\")\n@external(javascript, \""
    <> javascript_module
    <> "\", \"hit_"
    <> s
    <> "\")\npub fn hit_"
    <> s
    <> "() -> Nil\n\n"
  let #(implementation, signature, printing, chained_body, clause_text, call) = case
    clause
  {
    EffectsClause -> #(
      "quiet",
      "() -> Nil",
      "hit_" <> s <> "()",
      "inner_" <> s <> "()",
      " : []",
      fn(name) { alias <> "." <> name <> "()" },
    )
    ReturnsClause -> #(
      "make",
      "() -> fn() -> Nil",
      "hit_" <> s,
      "inner_" <> s <> "()",
      " : [] where returns : []",
      fn(name) { "let made = " <> alias <> "." <> name <> "()\n  made()" },
    )
    CarriesClause -> #(
      "pair",
      "() -> #(fn() -> Nil, Int)",
      "#(hit_" <> s <> ", 0)",
      "inner_" <> s <> "()",
      case owner {
        CatalogOwner -> " : []"
        OwnModule | PathDependency | InstalledPackage ->
          " : [] where carries : []"
      },
      fn(name) { "ffi.run_first(" <> alias <> "." <> name <> "())" },
    )
    UndescribedClause -> #(
      "pair",
      "() -> #(fn() -> Nil, Int)",
      "#(hit_" <> s <> ", 0)",
      "inner_" <> s <> "()",
      " : []",
      fn(name) { "ffi.run_first(" <> alias <> "." <> name <> "())" },
    )
    CarriesRecordClause -> #(
      "boxed",
      "() -> Box",
      "Box(hit_" <> s <> ")",
      "inner_" <> s <> "()",
      " : [] where carries : []",
      fn(name) { "ffi.run_box(" <> alias <> "." <> name <> "())" },
    )
    RunsClause -> #(
      "keep",
      "(value: #(fn() -> Nil, Int)) -> Nil",
      "let #(f, _) = value\n  f()",
      "inner_" <> s <> "(value)",
      "(value: [v]) : [] where runs : []",
      fn(name) { alias <> "." <> name <> "(#(leaf_" <> s <> ", 0))" },
    )
  }
  let external = fn(name, body) {
    "@external("
    <> covered
    <> ", \""
    <> foreign
    <> "\", \""
    <> implementation
    <> "\")\npub fn "
    <> name
    <> signature
    <> " {\n  "
    <> body
    <> "\n}\n\n"
  }
  let declare = fn(name) {
    "assume " <> path <> "." <> name <> clause_text <> "\n"
  }
  let #(source, declarations) = case chained {
    False -> #(external("go_" <> s, printing), declare("go_" <> s))
    True -> #(
      external("go_" <> s, chained_body) <> external("inner_" <> s, printing),
      declare("go_" <> s) <> declare("inner_" <> s),
    )
  }
  let hit_declaration =
    "assume " <> path <> ".hit_" <> s <> " : [L" <> s <> "]\n"
  #(
    hit <> source,
    hit_declaration <> declarations,
    Case(
      owner_name(owner)
        <> ", "
        <> clause_name(clause)
        <> ", external on "
        <> covered
        <> case chained {
        True -> ", its body calling another such external"
        False -> ""
      },
      call("go_" <> s),
      "",
      "",
    ),
  )
}

// An owner's module: its cells' sources after a record type and an import.
fn owner_source(sources: List(String)) -> String {
  "pub type Box {\n  Box(f: fn() -> Nil)\n}\n\n" <> string.concat(sources)
}

// An owner's Erlang and JavaScript implementations: quiet foreign
// implementations of every clause's shape, and a printer for every case.
fn owner_foreign(erlang_module: String, cases: List(Int)) -> #(String, String) {
  let hits = list.map(cases, fn(n) { "hit_" <> int.to_string(n) })
  #(
    "-module("
      <> erlang_module
      <> ").\n-export([quiet/0, make/0, pair/0, boxed/0, keep/1"
      <> string.concat(list.map(hits, fn(hit) { ", " <> hit <> "/0" }))
      <> "]).\nquiet() -> nil.\nmake() -> fun() -> nil end.\npair() -> {fun() -> nil end, 0}.\nboxed() -> {box, fun() -> nil end}.\nkeep(_) -> nil.\n"
      <> string.concat(
      list.map(cases, fn(n) {
        let s = int.to_string(n)
        "hit_" <> s <> "() -> io:format(\"HIT " <> s <> "~n\"), nil.\n"
      }),
    ),
    "export function quiet() {}\nexport function make() { return () => undefined; }\nexport function pair() { return [() => undefined, 0]; }\nexport function boxed() { return { f: () => undefined }; }\nexport function keep(_value) {}\n"
      <> string.concat(
      list.map(cases, fn(n) {
        let s = int.to_string(n)
        "export function hit_"
        <> s
        <> "() { console.log(\"HIT "
        <> s
        <> "\"); }\n"
      }),
    ),
  )
}

// Declarations over `@external`s crossed by owner, clause, the target the
// external covers, and whether its body calls another such external, in an
// app read on both targets that nothing splits. A catalogued owner's lines are
// a catalog file and its audit, installed in graded's catalog for the run:
// container results and published contracts among them. Every answer is sound
// on each target alone, on both and on a forced split, exact on the target the
// external covers, and the two-target answer is the join and the split's.
fn external_dimension_cases(graded: String, root: String) -> Outcome {
  let owners = [OwnModule, PathDependency, InstalledPackage, CatalogOwner]
  let clauses = [
    EffectsClause,
    ReturnsClause,
    CarriesClause,
    CarriesRecordClause,
    RunsClause,
  ]
  let shapes =
    list.flat_map(owners, fn(owner) {
      let clauses = case owner {
        CatalogOwner -> list.append(clauses, [UndescribedClause])
        OwnModule | PathDependency | InstalledPackage -> clauses
      }
      list.flat_map(clauses, fn(clause) {
        list.flat_map(["erlang", "javascript"], fn(covered) {
          list.map([False, True], fn(chained) {
            #(owner, clause, covered, chained)
          })
        })
      })
    })
  let cells =
    list.index_map(shapes, fn(shape, index) {
      let #(owner, clause, covered, chained) = shape
      #(
        owner,
        covered,
        external_dimension_case(owner, clause, covered, chained, index + 1),
        case owner {
          CatalogOwner -> catalog_audit_rows(clause, chained, index + 1)
          OwnModule | PathDependency | InstalledPackage -> ""
        },
        clause,
      )
    })
  let of_owner = fn(owner) {
    list.index_map(cells, fn(cell, index) { #(index + 1, cell) })
    |> list.filter(fn(numbered) { numbered.1.0 == owner })
  }
  let cases =
    list.map(cells, fn(cell) {
      let #(owner, covered, #(_, declarations, case_), _, clause) = cell
      let spec = case owner {
        PathDependency | CatalogOwner -> ""
        OwnModule | InstalledPackage -> declarations
      }
      // A catalog line's `where returns` clause over a path dependency's
      // external is not read, so neither it nor a line with no clause is exact.
      #(Case(..case_, spec:), case owner, clause {
        _, UndescribedClause | CatalogOwner, ReturnsClause -> []
        _, _ -> [covered]
      })
    })
  let write_owner = fn(
    owner,
    directory,
    module_file,
    erlang_file,
    javascript_file,
  ) {
    let numbered = of_owner(owner)
    let #(_, _, erlang_module, _) = owner_module(owner)
    let #(erlang, javascript) =
      owner_foreign(
        erlang_module,
        list.map(numbered, fn(numbered) { numbered.0 }),
      )
    write(
      directory <> module_file,
      owner_source(list.map(numbered, fn(numbered) { numbered.1.2.0 })),
    )
    write(directory <> erlang_file, erlang)
    write(directory <> javascript_file, javascript)
    list.map(numbered, fn(numbered) { numbered.1.2.1 })
    |> string.concat
  }
  let directory = root <> "/app"
  let dependency = root <> "/ext_dep"
  write(
    dependency <> "/gleam.toml",
    "name = \"ext_dep\"\nversion = \"1.0.0\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n",
  )
  let catalogued = root <> "/ev_catalog"
  write(
    catalogued <> "/gleam.toml",
    "name = \"ev_catalog\"\nversion = \"1.0.0\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n",
  )
  let catalog_lines =
    write_owner(
      CatalogOwner,
      catalogued,
      "/src/ev_catalog.gleam",
      "/src/ev_catalog_ffi.erl",
      "/src/ev_catalog_ffi.mjs",
    )
  let catalog = graded <> "/priv/catalog/ev_catalog@1.0.0"
  write(catalog <> ".graded", catalog_lines)
  write(
    catalog <> ".audit",
    "covers 1.0.0\n" <> string.concat(list.map(cells, fn(cell) { cell.3 })),
  )
  let dependency_spec =
    write_owner(
      PathDependency,
      dependency,
      "/src/ext_dep.gleam",
      "/src/ext_dep_ffi.erl",
      "/src/ext_dep_ffi.mjs",
    )
  write(dependency <> "/ext_dep.graded", dependency_spec)
  write_project_importing(
    directory,
    "erlang",
    list.map(cases, fn(pair) { pair.0 }),
    "import app/ext\nimport ev_catalog\nimport ext_dep\nimport gleam/latent_ext\n",
  )
  let toml =
    app_toml(
      "ev_catalog = { path = \"../ev_catalog\" }\next_dep = { path = \"../ext_dep\" }\n",
    )
  write(directory <> "/gleam.toml", toml("[\"erlang\", \"javascript\"]"))
  let _ =
    write_owner(
      OwnModule,
      directory,
      "/src/app/ext.gleam",
      "/src/app_ext_ffi.erl",
      "/src/app/ext_ffi.mjs",
    )
  let downloaded =
    shellout.command(
      run: "gleam",
      with: ["deps", "download"],
      in: directory,
      opt: [],
    )
  let stdlib = directory <> "/build/packages/gleam_stdlib/src"
  let _ =
    write_owner(
      InstalledPackage,
      stdlib,
      "/gleam/latent_ext.gleam",
      "/latent_ext_ffi.erl",
      "/gleam/latent_ext_ffi.mjs",
    )
  let outcome = case downloaded {
    Error(failure) ->
      Outcome(
        ["declared-external dependencies did not download:\n" <> failure.1],
        0,
        list.length(cases),
      )
    Ok(_) ->
      readings_outcome(
        "declared-external",
        graded,
        directory,
        cases,
        toml,
        True,
      )
  }
  let _ = simplifile.delete(catalog <> ".graded")
  let _ = simplifile.delete(catalog <> ".audit")
  outcome
}

// The two-target matrix
// The two-target matrix

// One cell: the case, and what it adds to the package's other module and to
// each dependency.
type MatrixCell {
  MatrixCell(
    case_: Case,
    other: String,
    other_spec: String,
    pairdep: String,
    aliasdep: String,
    aliasdep_mjs: String,
    aliasdep_spec: String,
    declared: String,
    declared_spec: String,
  )
}

fn cell(case_: Case) -> MatrixCell {
  MatrixCell(
    case_:,
    other: "",
    other_spec: "",
    pairdep: "",
    aliasdep: "",
    aliasdep_mjs: "",
    aliasdep_spec: "",
    declared: "",
    declared_spec: "",
  )
}

// Which variant of a pair prints.
type Prints {
  ErlangPrints
  JavaScriptPrints
  BothPrint
  NeitherPrints
}

fn prints_on(prints: Prints, target: String) -> Bool {
  case prints, target {
    BothPrint, _ -> True
    ErlangPrints, "erlang" -> True
    JavaScriptPrints, "javascript" -> True
    _, _ -> False
  }
}

fn prints_name(prints: Prints) -> String {
  case prints {
    ErlangPrints -> "Erlang prints"
    JavaScriptPrints -> "JavaScript prints"
    BothPrint -> "both print"
    NeitherPrints -> "neither prints"
  }
}

// How a callback pair's two parameter lists differ.
type Shape {
  SameShape
  SwappedLabels
  RenamedParameters
  DiscardedParameter
  UnequalArity
  OneAnnotation
}

fn shape_name(shape: Shape) -> String {
  case shape {
    SameShape -> "labels and names agree"
    SwappedLabels -> "labels swapped"
    RenamedParameters -> "parameters renamed"
    DiscardedParameter -> "a parameter discarded"
    UnequalArity -> "unequal arity"
    OneAnnotation -> "one variant annotated"
  }
}

// Where a callback pair is defined and how the case calls it.
type Consumer {
  PositionalCall
  LabelledCall
  OtherModuleCall
  DependencyCall
}

fn consumer_name(consumer: Consumer) -> String {
  case consumer {
    PositionalCall -> "positional call"
    LabelledCall -> "labelled call"
    OtherModuleCall -> "another module's, labelled call"
    DependencyCall -> "a dependency's, labelled call"
  }
}

const callback_type = ": fn() -> Nil"

// One variant's parameters and body: a printing variant calls the parameter
// labelled `first`, which the case hands the leaf, and any other calls the one
// labelled `second`, which it hands a quiet function.
fn callback_variant(
  shape: Shape,
  target: String,
  prints: Bool,
) -> #(String, String) {
  let either = fn(yes, no) {
    case prints {
      True -> yes
      False -> no
    }
  }
  let two = fn(first, second) {
    "first " <> first <> callback_type <> ", second " <> second <> callback_type
  }
  case target, shape {
    "erlang", UnequalArity -> #(
      "first a" <> callback_type,
      either("a()", "Nil"),
    )
    "erlang", _ -> #(two("a", "b"), either("a()", "b()"))
    _, SameShape | _, UnequalArity -> #(two("a", "b"), either("a()", "b()"))
    _, SwappedLabels -> #(
      "second a" <> callback_type <> ", first b" <> callback_type,
      either("b()", "a()"),
    )
    _, RenamedParameters -> #(two("x", "y"), either("x()", "y()"))
    _, DiscardedParameter -> #(two("_a", "b"), "b()")
    _, OneAnnotation -> #("first a, second b", either("a()", "b()"))
  }
}

fn gated(target: String, text: String) -> String {
  "@target(" <> target <> ")\n" <> text
}

fn visibility(public: Bool) -> String {
  case public {
    True -> "pub "
    False -> ""
  }
}

fn callback_pair(
  name: String,
  shape: Shape,
  prints: Prints,
  public: Bool,
) -> String {
  ["erlang", "javascript"]
  |> list.map(fn(target) {
    let #(parameters, body) =
      callback_variant(shape, target, prints_on(prints, target))
    gated(
      target,
      visibility(public)
        <> "fn "
        <> name
        <> "("
        <> parameters
        <> ") -> Nil {\n  "
        <> body
        <> "\n}\n\n",
    )
  })
  |> string.concat
}

fn callback_cell(prints: Prints, shape: Shape, consumer: Consumer) {
  fn(n: Int) {
    let s = int.to_string(n)
    let name = "f_" <> s
    let quiet = "pub fn quiet_" <> s <> "() -> Nil {\n  Nil\n}\n\n"
    let qualified = case consumer {
      OtherModuleCall -> "other." <> name
      DependencyCall -> "pairdep." <> name
      PositionalCall | LabelledCall -> name
    }
    let arguments = fn(arity) {
      case consumer, arity {
        PositionalCall, 1 -> "leaf_" <> s
        PositionalCall, _ -> "leaf_" <> s <> ", quiet_" <> s
        _, 1 -> "first: leaf_" <> s
        _, _ -> "first: leaf_" <> s <> ", second: quiet_" <> s
      }
    }
    let #(callers, body) = case shape {
      UnequalArity -> #(
        gated(
          "erlang",
          "fn call_"
            <> s
            <> "() -> Nil {\n  "
            <> qualified
            <> "("
            <> arguments(1)
            <> ")\n}\n\n",
        )
          <> gated(
          "javascript",
          "fn call_"
            <> s
            <> "() -> Nil {\n  "
            <> qualified
            <> "("
            <> arguments(2)
            <> ")\n}\n\n",
        ),
        "call_" <> s <> "()",
      )
      _ -> #("", qualified <> "(" <> arguments(2) <> ")")
    }
    let local = consumer == PositionalCall || consumer == LabelledCall
    let pair = callback_pair(name, shape, prints, !local)
    let label =
      "callback pair, "
      <> prints_name(prints)
      <> ", "
      <> shape_name(shape)
      <> ", "
      <> consumer_name(consumer)
    let base =
      cell(Case(
        label,
        body,
        case local {
          True -> quiet <> pair <> callers
          False -> quiet <> callers
        },
        "",
      ))
    case consumer {
      OtherModuleCall -> MatrixCell(..base, other: pair)
      DependencyCall -> MatrixCell(..base, pairdep: pair)
      PositionalCall | LabelledCall -> base
    }
  }
}

// An unequal-arity pair read from another module whose printing callback
// passes only through the parameter the first-written variant lacks: Erlang
// runs `first`, JavaScript runs `second`, and only JavaScript's caller hands
// the leaf to `second`.
fn mirrored_arity_cell(consumer: Consumer) {
  fn(n: Int) {
    let s = int.to_string(n)
    let name = "m_" <> s
    let qualified = case consumer {
      DependencyCall -> "pairdep." <> name
      _ -> "other." <> name
    }
    let pair =
      gated(
        "erlang",
        "pub fn " <> name <> "(first a: fn() -> Nil) -> Nil {\n  a()\n}\n\n",
      )
      <> gated(
        "javascript",
        "pub fn "
          <> name
          <> "(first a: fn() -> Nil, second b: fn() -> Nil) -> Nil {\n  b()\n}\n\n",
      )
    let callers =
      gated(
        "erlang",
        "fn call_"
          <> s
          <> "() -> Nil {\n  "
          <> qualified
          <> "(first: quiet_"
          <> s
          <> ")\n}\n\n",
      )
      <> gated(
        "javascript",
        "fn call_"
          <> s
          <> "() -> Nil {\n  "
          <> qualified
          <> "(first: quiet_"
          <> s
          <> ", second: leaf_"
          <> s
          <> ")\n}\n\n",
      )
    let base =
      cell(Case(
        "callback pair, JavaScript prints through the parameter the first-written variant lacks, unequal arity, "
          <> consumer_name(consumer),
        "call_" <> s <> "()",
        "pub fn quiet_" <> s <> "() -> Nil {\n  Nil\n}\n\n" <> callers,
        "",
      ))
    case consumer {
      DependencyCall -> MatrixCell(..base, pairdep: pair)
      _ -> MatrixCell(..base, other: pair)
    }
  }
}

// Two pairs whose calls form a cycle only across targets: `f` calls `g` on the
// first target, `g` calls back on the second, and the leaf sits on the second
// target's `g` where nothing reaches it. With `reached`, the first target's
// `g` calls the leaf too.
fn cross_cycle_cell(first: String, second: String, reached: Bool) {
  fn(n: Int) {
    let s = int.to_string(n)
    let leaf = "leaf_" <> s <> "()"
    let reached_body = case reached {
      True -> leaf
      False -> "Nil"
    }
    cell(Case(
      "call cycle only across targets, "
        <> first
        <> " calls through"
        <> case reached {
        True -> ", reached leaf"
        False -> ", unreached leaf"
      },
      "f_" <> s <> "(0)",
      gated(
        first,
        "fn f_" <> s <> "(n: Int) -> Nil {\n  g_" <> s <> "(n)\n}\n\n",
      )
        <> gated(second, "fn f_" <> s <> "(_n: Int) -> Nil {\n  Nil\n}\n\n")
        <> gated(
        first,
        "fn g_" <> s <> "(_n: Int) -> Nil {\n  " <> reached_body <> "\n}\n\n",
      )
        <> gated(
        second,
        "fn g_"
          <> s
          <> "(n: Int) -> Nil {\n  "
          <> leaf
          <> "\n  f_"
          <> s
          <> "(n)\n}\n\n",
      ),
      "",
    ))
  }
}

// Two pairs reaching each other through a helper both targets share, a cycle
// only on `first`: the leaf sits on `second`'s `g`, which nothing reaches.
fn helper_cycle_cell(first: String, second: String) {
  fn(n: Int) {
    let s = int.to_string(n)
    cell(Case(
      "pairs reaching each other through a shared helper, a cycle only on "
        <> first,
      "f_" <> s <> "(2)",
      gated(
        first,
        "fn f_"
          <> s
          <> "(n: Int) -> Nil {\n  case n {\n    0 -> Nil\n    _ -> h_"
          <> s
          <> "(n - 1)\n  }\n}\n\n",
      )
        <> gated(second, "fn f_" <> s <> "(_n: Int) -> Nil {\n  Nil\n}\n\n")
        <> "fn h_"
        <> s
        <> "(n: Int) -> Nil {\n  g_"
        <> s
        <> "(n)\n}\n\n"
        <> gated(
        first,
        "fn g_" <> s <> "(n: Int) -> Nil {\n  f_" <> s <> "(n)\n}\n\n",
      )
        <> gated(
        second,
        "fn g_"
          <> s
          <> "(n: Int) -> Nil {\n  leaf_"
          <> s
          <> "()\n  f_"
          <> s
          <> "(n)\n}\n\n",
      ),
      "",
    ))
  }
}

// Two pairs calling each other directly, a cycle only on Erlang: the leaf
// sits on JavaScript's `g`, which nothing reaches.
fn paired_cycle_cell(n: Int) -> MatrixCell {
  let s = int.to_string(n)
  cell(Case(
    "two pairs calling each other, a cycle only on erlang",
    "f_" <> s <> "(2)",
    gated(
      "erlang",
      "fn f_"
        <> s
        <> "(n: Int) -> Nil {\n  case n {\n    0 -> Nil\n    _ -> g_"
        <> s
        <> "(n - 1)\n  }\n}\n\n",
    )
      <> gated("javascript", "fn f_" <> s <> "(_n: Int) -> Nil {\n  Nil\n}\n\n")
      <> gated(
      "erlang",
      "fn g_" <> s <> "(n: Int) -> Nil {\n  f_" <> s <> "(n)\n}\n\n",
    )
      <> gated(
      "javascript",
      "fn g_"
        <> s
        <> "(n: Int) -> Nil {\n  leaf_"
        <> s
        <> "()\n  f_"
        <> s
        <> "(n)\n}\n\n",
    ),
    "",
  ))
}

// A factory pair whose variants build the same record around a quiet
// function, the record's field then run.
fn identical_factory_cell(n: Int) -> MatrixCell {
  let s = int.to_string(n)
  let runner = "Runner" <> s
  let make =
    "fn make_"
    <> s
    <> "() -> "
    <> runner
    <> " {\n  "
    <> runner
    <> "(quiet_"
    <> s
    <> ")\n}\n\n"
  cell(Case(
    "factory pair building the same record",
    "let r = make_" <> s <> "()\n  r.run()",
    "fn quiet_"
      <> s
      <> "() -> Nil {\n  Nil\n}\n\npub type "
      <> runner
      <> " {\n  "
      <> runner
      <> "(run: fn() -> Nil)\n}\n\n"
      <> gated("erlang", make)
      <> gated("javascript", make),
    "",
  ))
}

// A factory pair whose Erlang record holds a closure calling an unequal-arity
// pair with a quiet function, and whose JavaScript record holds that function.
fn closure_factory_cell(n: Int) -> MatrixCell {
  let s = int.to_string(n)
  let runner = "Runner" <> s
  cell(Case(
    "factory pair, Erlang record holding a closure over an unequal-arity pair",
    "let r = make_" <> s <> "()\n  r.run()",
    "fn quiet_"
      <> s
      <> "() -> Nil {\n  Nil\n}\n\npub type "
      <> runner
      <> " {\n  "
      <> runner
      <> "(run: fn() -> Nil)\n}\n\n"
      <> gated(
      "erlang",
      "fn g_" <> s <> "(a: fn() -> Nil) -> Nil {\n  a()\n}\n\n",
    )
      <> gated(
      "javascript",
      "fn g_" <> s <> "(_a: fn() -> Nil, b: fn() -> Nil) -> Nil {\n  b()\n}\n\n",
    )
      <> gated(
      "erlang",
      "fn make_"
        <> s
        <> "() -> "
        <> runner
        <> " {\n  "
        <> runner
        <> "(fn() { g_"
        <> s
        <> "(quiet_"
        <> s
        <> ") })\n}\n\n",
    )
      <> gated(
      "javascript",
      "fn make_"
        <> s
        <> "() -> "
        <> runner
        <> " {\n  "
        <> runner
        <> "(quiet_"
        <> s
        <> ")\n}\n\n",
    ),
    "",
  ))
}

// A public callback pair whose variants name the labelled parameter
// differently, only JavaScript running it: its published line carries a bound.
fn bounded_pair_cell(n: Int) -> MatrixCell {
  let s = int.to_string(n)
  cell(Case(
    "public callback pair renamed by each variant, only javascript running it",
    "run_" <> s <> "(first: leaf_" <> s <> ")",
    gated(
      "erlang",
      "pub fn run_"
        <> s
        <> "(first a: fn() -> Nil) -> Nil {\n  let _ = a\n  Nil\n}\n\n",
    )
      <> gated(
      "javascript",
      "pub fn run_" <> s <> "(first b: fn() -> Nil) -> Nil {\n  b()\n}\n\n",
    ),
    "",
  ))
}

// How a type is defined once per target: as an alias on both, a custom type on
// both, or one of each. Its JavaScript definition holds a function; its Erlang
// one an `Int`.
type TypePair {
  AliasPair
  CustomPair
  AliasThenCustom
  CustomThenAlias
}

fn type_pair_name(pair: TypePair) -> String {
  case pair {
    AliasPair -> "an alias on each target"
    CustomPair -> "a custom type on each target"
    AliasThenCustom -> "an Erlang alias and a JavaScript custom type"
    CustomThenAlias -> "an Erlang custom type and a JavaScript alias"
  }
}

// Where the value is consumed: on both targets, or on one alone.
type TypeConsumer {
  SharedConsumer
  GatedConsumer(target: String)
}

// A value of a type defined once per target, made by a foreign function and
// handed to a foreign runner by `consumer`. Only JavaScript's value holds a
// function, which prints.
fn type_pair_cell(pair: TypePair, consumer: TypeConsumer) {
  fn(n: Int) {
    let s = int.to_string(n)
    let name = "Held" <> s
    let erlang = case pair {
      AliasPair | AliasThenCustom -> "pub type " <> name <> " =\n  Int\n\n"
      CustomPair | CustomThenAlias ->
        "pub type " <> name <> " {\n  " <> name <> "(Int)\n}\n\n"
    }
    let #(javascript, maker, runner) = case pair {
      AliasPair | CustomThenAlias -> #(
        "pub type " <> name <> " =\n  fn() -> Nil\n\n",
        "printer_of",
        "ffi.run_any",
      )
      CustomPair | AliasThenCustom -> #(
        "pub type " <> name <> " {\n  " <> name <> "(run: fn() -> Nil)\n}\n\n",
        "holder_of",
        "ffi.run_fields",
      )
    }
    let make =
      "@external(erlang, \"app_ffi\", \"zero_of\")\n@external(javascript, \"./app_ffi.mjs\", \""
      <> maker
      <> "\")\nfn make_"
      <> s
      <> "(label: Int) -> "
      <> name
      <> "\n\n"
    let use_value = runner <> "(make_" <> s <> "(" <> s <> "))"
    let #(consumers, body, consumer_name) = case consumer {
      SharedConsumer -> #("", use_value, "consumed on both targets")
      GatedConsumer(target:) -> #(
        gated(
          target,
          "fn use_" <> s <> "() -> Nil {\n  " <> use_value <> "\n}\n\n",
        )
          <> gated(
          case target {
            "erlang" -> "javascript"
            _ -> "erlang"
          },
          "fn use_" <> s <> "() -> Nil {\n  Nil\n}\n\n",
        ),
        "use_" <> s <> "()",
        "consumed on " <> target <> " alone",
      )
    }
    cell(Case(
      "type defined once per target, "
        <> type_pair_name(pair)
        <> ", "
        <> consumer_name,
      body,
      gated("erlang", erlang)
        <> gated("javascript", javascript)
        <> make
        <> consumers,
      "assume app.make_" <> s <> " : []\n",
    ))
  }
}

// One closure capturing a tuple of `elements` zeros, named by `branches`
// branches of one `case` and then called.
fn repeated_closure_cell(elements: Int, branches: Int) {
  fn(n: Int) {
    let s = int.to_string(n)
    let zeros = string.join(list.map(numbers(elements), fn(_) { "0" }), ", ")
    cell(Case(
      "one closure over a "
        <> int.to_string(elements)
        <> "-element tuple, named by "
        <> int.to_string(branches)
        <> " branches",
      "repeated_" <> s <> "()",
      "fn repeated_"
        <> s
        <> "() -> Nil {\n  let r = #("
        <> zeros
        <> ")\n  let f = fn() {\n    let _ = r\n    Nil\n  }\n  let h = case 0 {\n"
        <> string.concat(
        list.map(numbers(branches - 1), fn(i) {
          "    " <> int.to_string(i - 1) <> " -> f\n"
        }),
      )
        <> "    _ -> f\n  }\n  h()\n}\n\n",
      "",
    ))
  }
}

// A callback passed around a recursive cycle, the base case running it: the
// recursive call passes the printer in its place, passes the callback on, or
// passes another quiet function.
type Recursion {
  RebindDirect
  RebindAlias
  RebindChoice
  PassOn(prints: Bool)
  RebindQuiet
  RebindReturned
  RebindReference
}

fn recursion_cell(shape: Recursion) {
  fn(n: Int) {
    let s = int.to_string(n)
    let quiet = "quiet_" <> s
    let choose = fn(base: String, passed: String) {
      "fn choose_"
      <> s
      <> "(n: Int, f: fn() -> Nil) -> Nil {\n  case n {\n    0 -> "
      <> base
      <> "\n    _ -> choose_"
      <> s
      <> "(n - 1, "
      <> passed
      <> ")\n  }\n}\n\n"
    }
    let #(name, body, helpers) = case shape {
      RebindDirect -> #(
        "recursive call passing the printer",
        "choose_" <> s <> "(1, " <> quiet <> ")",
        choose("f()", "leaf_" <> s),
      )
      RebindAlias -> #(
        "recursive call passing the printer, run through an alias",
        "choose_" <> s <> "(1, " <> quiet <> ")",
        choose("{\n      let h = f\n      h()\n    }", "leaf_" <> s),
      )
      RebindChoice -> #(
        "recursive call passing the printer, run through a choice",
        "choose_" <> s <> "(1, " <> quiet <> ")",
        choose(
          "{\n      let h = case n == 0 {\n        True -> f\n        False -> f\n      }\n      h()\n    }",
          "leaf_" <> s,
        ),
      )
      PassOn(prints:) -> #(
        "recursive call passing the callback on, "
          <> case prints {
          True -> "the printer passed"
          False -> "a quiet function passed"
        },
        "choose_"
          <> s
          <> "(3, "
          <> case prints {
          True -> "leaf_" <> s
          False -> quiet
        }
          <> ")",
        choose("f()", "f"),
      )
      RebindQuiet -> #(
        "recursive call passing another quiet function",
        "choose_" <> s <> "(1, " <> quiet <> ")",
        choose("f()", quiet),
      )
      RebindReturned -> #(
        "recursive producer call passing the printer, the result run",
        "let made = make_" <> s <> "(1, " <> quiet <> ")\n  made()",
        "fn make_"
          <> s
          <> "(n: Int, f: fn() -> Nil) -> fn() -> Nil {\n  case n {\n    0 -> f\n    _ -> make_"
          <> s
          <> "(n - 1, leaf_"
          <> s
          <> ")\n  }\n}\n\n",
      )
      RebindReference -> #(
        "recursive function handed to a runner with the printer",
        "go_" <> s <> "(1, " <> quiet <> ")",
        "fn hand_"
          <> s
          <> "(n: Int, f: fn() -> Nil, k: fn(Int, fn() -> Nil) -> Nil) -> Nil {\n  k(n, f)\n}\n\nfn go_"
          <> s
          <> "(n: Int, f: fn() -> Nil) -> Nil {\n  case n {\n    0 -> f()\n    _ -> hand_"
          <> s
          <> "(n - 1, leaf_"
          <> s
          <> ", go_"
          <> s
          <> ")\n  }\n}\n\n",
      )
    }
    cell(Case(
      name,
      body,
      "fn " <> quiet <> "() -> Nil {\n  Nil\n}\n\n" <> helpers,
      "",
    ))
  }
}

// A producer pair whose Erlang closure calls an unequal-arity pair, the
// closure returned and run.
fn returned_pair_closure_cell(prints: Bool) {
  fn(n: Int) {
    let s = int.to_string(n)
    let passed = case prints {
      True -> "leaf_" <> s
      False -> "quiet_" <> s
    }
    cell(Case(
      "returned closure calling an unequal-arity pair, "
        <> case prints {
        True -> "Erlang prints"
        False -> "neither prints"
      },
      "let made = make_" <> s <> "()\n  made()",
      "fn quiet_"
        <> s
        <> "() -> Nil {\n  Nil\n}\n\n"
        <> gated(
        "erlang",
        "fn two_" <> s <> "(a: fn() -> Nil) -> Nil {\n  a()\n}\n\n",
      )
        <> gated(
        "javascript",
        "fn two_"
          <> s
          <> "(a: fn() -> Nil, b: fn() -> Nil) -> Nil {\n  let _ = a\n  b()\n}\n\n",
      )
        <> gated(
        "erlang",
        "fn make_"
          <> s
          <> "() -> fn() -> Nil {\n  fn() { two_"
          <> s
          <> "("
          <> passed
          <> ") }\n}\n\n",
      )
        <> gated(
        "javascript",
        "fn make_" <> s <> "() -> fn() -> Nil {\n  fn() { Nil }\n}\n\n",
      ),
      "",
    ))
  }
}

// A callback each variant names differently, with its annotation missing on
// the JavaScript variant or on both.
fn unannotated_rename_cell(both_bare: Bool, prints: Bool) {
  fn(n: Int) {
    let s = int.to_string(n)
    let erlang_parameter = case both_bare {
      True -> "a"
      False -> "a: fn() -> Nil"
    }
    let passed = case prints {
      True -> "leaf_" <> s
      False -> "quiet_" <> s
    }
    cell(Case(
      "renamed callback, annotation missing on "
        <> case both_bare {
        True -> "both variants"
        False -> "one variant"
      }
        <> case prints {
        True -> ", both print"
        False -> ", neither prints"
      },
      "run_" <> s <> "(" <> passed <> ")",
      "fn quiet_"
        <> s
        <> "() -> Nil {\n  Nil\n}\n\n"
        <> gated(
        "erlang",
        "fn run_" <> s <> "(" <> erlang_parameter <> ") {\n  a()\n}\n\n",
      )
        <> gated("javascript", "fn run_" <> s <> "(b) {\n  b()\n}\n\n"),
      "",
    ))
  }
}

// An external pair in a module whose default line says `[]`, under a
// function-level line: the printing leaf declared `[L]`, or a quiet foreign
// function declared `[]`.
fn declared_external_cell(prints: Bool) {
  fn(n: Int) {
    let s = int.to_string(n)
    let #(erlang, javascript, declared) = case prints {
      True -> #(
        "\"app_leaves\", \"leaf_" <> s <> "\"",
        "\"../app_leaves.mjs\", \"leaf_" <> s <> "\"",
        "[L" <> s <> "]",
      )
      False -> #(
        "\"app_ffi\", \"ignore\"",
        "\"../app_ffi.mjs\", \"ignore\"",
        "[]",
      )
    }
    let argument = case prints {
      True -> ""
      False -> "0"
    }
    let parameter = case prints {
      True -> ""
      False -> "value: Int"
    }
    MatrixCell(
      ..cell(Case(
        "external pair under a function-level line over an empty module default, "
          <> case prints {
          True -> "both print"
          False -> "neither prints"
        },
        "declared.get_" <> s <> "(" <> argument <> ")",
        "",
        "",
      )),
      declared: "@target(erlang)\n@external(erlang, "
        <> erlang
        <> ")\npub fn get_"
        <> s
        <> "("
        <> parameter
        <> ") -> Nil\n\n@target(javascript)\n@external(javascript, "
        <> javascript
        <> ")\npub fn get_"
        <> s
        <> "("
        <> parameter
        <> ") -> Nil\n\n",
      declared_spec: "assume app/declared.get_"
        <> s
        <> " : "
        <> declared
        <> "\n",
    )
  }
}

// How a function-valued pair reaches the code that runs it.
type ValueConsumer {
  CalledDirectly
  PassedToRunner
  StoredInField
  ReturnedValue
  OtherModuleValue
}

fn value_cell(prints: Prints, consumer: ValueConsumer) {
  fn(n: Int) {
    let s = int.to_string(n)
    let leaf = "leaf_" <> s
    let quiet = "pub fn quiet_" <> s <> "() -> Nil {\n  Nil\n}\n\n"
    let thunk = fn(public) {
      ["erlang", "javascript"]
      |> list.map(fn(target) {
        let body = case prints_on(prints, target) {
          True -> leaf <> "()"
          False -> "Nil"
        }
        gated(
          target,
          visibility(public)
            <> "fn g_"
            <> s
            <> "() -> Nil {\n  "
            <> body
            <> "\n}\n\n",
        )
      })
      |> string.concat
    }
    let maker =
      ["erlang", "javascript"]
      |> list.map(fn(target) {
        let returned = case prints_on(prints, target) {
          True -> leaf
          False -> "quiet_" <> s
        }
        gated(
          target,
          "fn make_" <> s <> "() -> fn() -> Nil {\n  " <> returned <> "\n}\n\n",
        )
      })
      |> string.concat
    let label = fn(how) {
      "function-valued pair, " <> prints_name(prints) <> ", " <> how
    }
    case consumer {
      CalledDirectly ->
        cell(Case(label("called directly"), "g_" <> s <> "()", thunk(False), ""))
      PassedToRunner ->
        cell(Case(
          label("passed to a runner"),
          "ffi.run_any(g_" <> s <> ")",
          thunk(False),
          "",
        ))
      StoredInField ->
        cell(Case(
          label("stored in a field"),
          "ffi.run_box(Box(g_" <> s <> "))",
          thunk(False),
          "",
        ))
      ReturnedValue ->
        cell(Case(
          label("returned"),
          "ffi.run_any(make_" <> s <> "())",
          quiet <> maker,
          "",
        ))
      OtherModuleValue ->
        MatrixCell(
          ..cell(Case(
            label("another module's, passed to a runner"),
            "ffi.run_any(other.g_" <> s <> ")",
            "",
            "",
          )),
          other: "@external(erlang, \"app_leaves\", \"leaf_"
            <> s
            <> "\")\n@external(javascript, \"../app_leaves.mjs\", \"leaf_"
            <> s
            <> "\")\nfn leaf_"
            <> s
            <> "() -> Nil\n\n"
            <> thunk(True),
          other_spec: "assume app/other.leaf_" <> s <> " : [L" <> s <> "]\n",
        )
    }
  }
}

// A pair whose variants each carry an `@external` attribute.
fn crossed_externals_cell(prints: Prints) {
  fn(n: Int) {
    let s = int.to_string(n)
    let variant = fn(target, other, path, module_target) {
      let body = case prints_on(prints, target) {
        True -> "leaf_" <> s <> "()"
        False -> "Nil"
      }
      "@target("
      <> target
      <> ")\n@external("
      <> other
      <> ", \""
      <> path
      <> "\", \"hit\")\nfn g_"
      <> s
      <> "() -> Nil {\n  "
      <> body
      <> "\n}\n\n"
      <> module_target
    }
    cell(Case(
      "externals crossed, " <> prints_name(prints),
      "g_" <> s <> "()",
      variant("erlang", "javascript", "./app_ffi.mjs", "")
        <> variant("javascript", "erlang", "app_ffi", ""),
      "",
    ))
  }
}

fn own_externals_cell(n: Int) -> MatrixCell {
  let s = int.to_string(n)
  cell(Case(
    "externals for each variant's own target, both print",
    "h_" <> s <> "(" <> s <> ")",
    "@target(erlang)\n@external(erlang, \"app_ffi\", \"hit\")\nfn h_"
      <> s
      <> "(label: Int) -> Nil\n\n@target(javascript)\n@external(javascript, \"./app_ffi.mjs\", \"hit\")\nfn h_"
      <> s
      <> "(label: Int) -> Nil\n\n",
    "assume app.h_" <> s <> " : [L" <> s <> "]\n",
  ))
}

fn constant_cell(prints: Prints) {
  fn(n: Int) {
    let s = int.to_string(n)
    let constant =
      ["erlang", "javascript"]
      |> list.map(fn(target) {
        let value = case prints_on(prints, target) {
          True -> "leaf_" <> s
          False -> "quiet_" <> s
        }
        gated(target, "const c_" <> s <> " = " <> value <> "\n\n")
      })
      |> string.concat
    cell(Case(
      "constant pair, " <> prints_name(prints),
      "ffi.run_any(c_" <> s <> ")",
      "pub fn quiet_" <> s <> "() -> Nil {\n  Nil\n}\n\n" <> constant,
      "",
    ))
  }
}

fn typed_constant_cell(n: Int) -> MatrixCell {
  let s = int.to_string(n)
  cell(Case(
    "constant pair typed differently, JavaScript prints",
    "ffi.run_any(c_" <> s <> ")",
    "@target(erlang)\nconst c_"
      <> s
      <> " = 0\n\n@target(javascript)\nconst c_"
      <> s
      <> " = leaf_"
      <> s
      <> "\n\n",
    "",
  ))
}

fn alias_cell(public: Bool) {
  fn(n: Int) {
    let s = int.to_string(n)
    let alias = fn(target, aliased) {
      gated(
        target,
        visibility(public) <> "type H" <> s <> " =\n  " <> aliased <> "\n\n",
      )
    }
    let base =
      cell(Case(
        case public {
          True -> "public alias pair, JavaScript prints"
          False -> "private alias pair, JavaScript prints"
        },
        "ffi.run_any(held_" <> s <> "(" <> s <> "))",
        alias("erlang", "Int")
          <> alias("javascript", "fn() -> Nil")
          <> "@external(erlang, \"app_ffi\", \"zero_of\")\n@external(javascript, \"./app_ffi.mjs\", \"printer_of\")\nfn held_"
          <> s
          <> "(label: Int) -> H"
          <> s
          <> "\n\n",
        "assume app.held_" <> s <> " : []\n",
      ))
    base
  }
}

fn custom_type_cell(prints: Prints) {
  fn(n: Int) {
    let s = int.to_string(n)
    let holds = case prints {
      ErlangPrints -> #("erlang", "javascript")
      _ -> #("javascript", "erlang")
    }
    cell(Case(
      "custom type pair, " <> prints_name(prints),
      "ffi.run_fields(mk_" <> s <> "())",
      gated(holds.1, "pub type B" <> s <> " {\n  B" <> s <> "(Int)\n}\n\n")
        <> gated(
        holds.0,
        "pub type B" <> s <> " {\n  B" <> s <> "(fn() -> Nil)\n}\n\n",
      )
        <> gated(
        holds.0,
        "fn mk_"
          <> s
          <> "() -> B"
          <> s
          <> " {\n  B"
          <> s
          <> "(leaf_"
          <> s
          <> ")\n}\n\n",
      )
        <> gated(
        holds.1,
        "fn mk_" <> s <> "() -> B" <> s <> " {\n  B" <> s <> "(0)\n}\n\n",
      ),
      "",
    ))
  }
}

// A dependency's alias pair reached through its annotated interface: private,
// public, or private behind another private alias.
type AliasExposure {
  PrivateAlias
  PublicAlias
  ChainedPrivateAlias
}

fn dependency_alias_cell(exposure: AliasExposure) {
  fn(n: Int) {
    let s = int.to_string(n)
    let visibility = case exposure {
      PublicAlias -> "pub "
      PrivateAlias | ChainedPrivateAlias -> ""
    }
    let alias = fn(target, aliased) {
      gated(
        target,
        visibility <> "type H" <> s <> " =\n  " <> aliased <> "\n\n",
      )
    }
    let #(exposed, chain) = case exposure {
      ChainedPrivateAlias -> #(
        "G" <> s,
        "type G" <> s <> " =\n  H" <> s <> "\n\n",
      )
      PrivateAlias | PublicAlias -> #("H" <> s, "")
    }
    MatrixCell(
      ..cell(Case(
        case exposure {
          PrivateAlias ->
            "a dependency's private alias pair in an annotated signature, JavaScript prints"
          PublicAlias -> "a dependency's public alias pair, JavaScript prints"
          ChainedPrivateAlias ->
            "a dependency's private alias pair behind another private alias, JavaScript prints"
        },
        "ffi.run_any(aliasdep.value_" <> s <> "())",
        "",
        "",
      )),
      aliasdep: alias("erlang", "Int")
        <> alias("javascript", "fn() -> Nil")
        <> chain
        <> "@external(erlang, \"aliasdep_ffi\", \"value\")\n@external(javascript, \"./aliasdep_ffi.mjs\", \"value_"
        <> s
        <> "\")\npub fn value_"
        <> s
        <> "() -> "
        <> exposed
        <> "\n\n",
      aliasdep_mjs: "export function value_"
        <> s
        <> "() { return () => console.log(\"HIT "
        <> s
        <> "\"); }\n",
      aliasdep_spec: "assume aliasdep.value_" <> s <> " : []\n",
    )
  }
}

// Pairs written out whole beside the generated shapes, each the smallest
// program of its shape.
fn standalone_cells() -> List(fn(Int) -> MatrixCell) {
  [
    // A labelled call whose swapped labels move the printing callback to the
    // other parameter on JavaScript.
    callback_cell(ErlangPrints, SwappedLabels, LabelledCall),
    // One callback parameter each variant names differently, called
    // positionally.
    fn(n) {
      let s = int.to_string(n)
      cell(Case(
        "one callback renamed by each variant, positional call",
        "run_" <> s <> "(quiet_" <> s <> ")",
        "fn quiet_"
          <> s
          <> "() -> Nil {\n  Nil\n}\n\n"
          <> gated(
          "erlang",
          "fn run_" <> s <> "(a: fn() -> Nil) -> Nil {\n  a()\n}\n\n",
        )
          <> gated(
          "javascript",
          "fn run_" <> s <> "(b: fn() -> Nil) -> Nil {\n  b()\n}\n\n",
        ),
        "",
      ))
    },
    // A callback only one variant names and runs.
    fn(n) {
      let s = int.to_string(n)
      cell(Case(
        "one callback discarded by one variant, positional call",
        "run_" <> s <> "(quiet_" <> s <> ")",
        "fn quiet_"
          <> s
          <> "() -> Nil {\n  Nil\n}\n\n"
          <> gated(
          "erlang",
          "fn run_" <> s <> "(_a: fn() -> Nil) -> Nil {\n  Nil\n}\n\n",
        )
          <> gated(
          "javascript",
          "fn run_" <> s <> "(b: fn() -> Nil) -> Nil {\n  b()\n}\n\n",
        ),
        "",
      ))
    },
    // Unequal arity, each target's caller passing its own count.
    fn(n) {
      let s = int.to_string(n)
      cell(Case(
        "unequal arity, each variant's caller passing its own count",
        "call_" <> s <> "()",
        "fn quiet_"
          <> s
          <> "() -> Nil {\n  Nil\n}\n\n"
          <> gated(
          "erlang",
          "fn run_" <> s <> "(a: fn() -> Nil) -> Nil {\n  a()\n}\n\n",
        )
          <> gated(
          "javascript",
          "fn run_"
            <> s
            <> "(a: fn() -> Nil, b: fn() -> Nil) -> Nil {\n  let _ = a\n  b()\n}\n\n",
        )
          <> gated(
          "erlang",
          "fn call_"
            <> s
            <> "() -> Nil {\n  run_"
            <> s
            <> "(quiet_"
            <> s
            <> ")\n}\n\n",
        )
          <> gated(
          "javascript",
          "fn call_"
            <> s
            <> "() -> Nil {\n  run_"
            <> s
            <> "(quiet_"
            <> s
            <> ", quiet_"
            <> s
            <> ")\n}\n\n",
        ),
        "",
      ))
    },
    // Each variant's `@external` names the other target.
    crossed_externals_cell(NeitherPrints),
    // A dependency's private alias pair named by an annotated signature.
    dependency_alias_cell(PrivateAlias),
  ]
}

fn matrix_cells() -> List(fn(Int) -> MatrixCell) {
  let every_prints = [ErlangPrints, JavaScriptPrints, BothPrint, NeitherPrints]
  let shapes = [
    SameShape, SwappedLabels, RenamedParameters, DiscardedParameter,
    UnequalArity, OneAnnotation,
  ]
  list.flatten([
    standalone_cells(),
    list.flat_map(shapes, fn(shape) {
      list.flat_map(every_prints, fn(prints) {
        [
          callback_cell(prints, shape, LabelledCall),
          callback_cell(prints, shape, PositionalCall),
        ]
      })
    }),
    list.flat_map(shapes, fn(shape) {
      list.flat_map([ErlangPrints, JavaScriptPrints], fn(prints) {
        [
          callback_cell(prints, shape, OtherModuleCall),
          callback_cell(prints, shape, DependencyCall),
        ]
      })
    }),
    list.flat_map(every_prints, fn(prints) {
      [
        value_cell(prints, CalledDirectly),
        value_cell(prints, PassedToRunner),
        value_cell(prints, StoredInField),
        value_cell(prints, ReturnedValue),
        crossed_externals_cell(prints),
        constant_cell(prints),
      ]
    }),
    [
      value_cell(ErlangPrints, OtherModuleValue),
      value_cell(JavaScriptPrints, OtherModuleValue),
      own_externals_cell,
      typed_constant_cell,
      alias_cell(True),
      alias_cell(False),
      custom_type_cell(ErlangPrints),
      custom_type_cell(JavaScriptPrints),
      dependency_alias_cell(PublicAlias),
      dependency_alias_cell(ChainedPrivateAlias),
      mirrored_arity_cell(OtherModuleCall),
      mirrored_arity_cell(DependencyCall),
      cross_cycle_cell("erlang", "javascript", False),
      cross_cycle_cell("javascript", "erlang", False),
      cross_cycle_cell("erlang", "javascript", True),
      returned_pair_closure_cell(False),
      returned_pair_closure_cell(True),
      unannotated_rename_cell(False, False),
      unannotated_rename_cell(False, True),
      unannotated_rename_cell(True, False),
      unannotated_rename_cell(True, True),
      declared_external_cell(True),
      declared_external_cell(False),
      helper_cycle_cell("erlang", "javascript"),
      helper_cycle_cell("javascript", "erlang"),
      paired_cycle_cell,
      identical_factory_cell,
      closure_factory_cell,
      bounded_pair_cell,
      repeated_closure_cell(8, 1002),
      repeated_closure_cell(100, 1000),
      repeated_closure_cell(100, 1001),
      recursion_cell(RebindDirect),
      recursion_cell(RebindAlias),
      recursion_cell(RebindChoice),
      recursion_cell(PassOn(False)),
      recursion_cell(PassOn(True)),
      recursion_cell(RebindQuiet),
      recursion_cell(RebindReturned),
      recursion_cell(RebindReference),
    ],
    list.flat_map(
      [AliasPair, CustomPair, AliasThenCustom, CustomThenAlias],
      fn(pair) {
        [
          type_pair_cell(pair, SharedConsumer),
          type_pair_cell(pair, GatedConsumer("erlang")),
          type_pair_cell(pair, GatedConsumer("javascript")),
        ]
      },
    ),
  ])
}

// The cells, numbered from one.
fn numbered_cells() -> List(MatrixCell) {
  list.index_map(matrix_cells(), fn(build, index) { build(index + 1) })
}

// Every matrix cell in one package read on both targets, with another module
// and two path dependencies, run natively on both. Each case's two-target
// answer must equal the join of the package's single-target answers and must
// contain whatever printed on either target.
fn matrix_cases(graded: String, root: String) -> Outcome {
  let cells = numbered_cells()
  let cases = list.map(cells, fn(cell) { cell.case_ })
  let directory = root <> "/app"
  write(
    root <> "/pairdep/gleam.toml",
    "name = \"pairdep\"\nversion = \"1.0.0\"\n",
  )
  write(
    root <> "/pairdep/src/pairdep.gleam",
    string.concat(list.map(cells, fn(cell) { cell.pairdep })),
  )
  write(
    root <> "/aliasdep/gleam.toml",
    "name = \"aliasdep\"\nversion = \"1.0.0\"\n",
  )
  write(
    root <> "/aliasdep/src/aliasdep.gleam",
    string.concat(list.map(cells, fn(cell) { cell.aliasdep })),
  )
  write(
    root <> "/aliasdep/src/aliasdep_ffi.erl",
    "-module(aliasdep_ffi).\n-export([value/0]).\nvalue() -> 0.\n",
  )
  write(
    root <> "/aliasdep/src/aliasdep_ffi.mjs",
    string.concat(list.map(cells, fn(cell) { cell.aliasdep_mjs })),
  )
  write(
    root <> "/aliasdep/aliasdep.graded",
    string.concat(list.map(cells, fn(cell) { cell.aliasdep_spec })),
  )
  write_project_importing(
    directory,
    "erlang",
    cases,
    "import aliasdep\nimport app/declared\nimport app/other\nimport pairdep\n",
  )
  write(
    directory <> "/src/app/other.gleam",
    string.concat(list.map(cells, fn(cell) { cell.other })),
  )
  write(
    directory <> "/src/app/declared.gleam",
    string.concat(list.map(cells, fn(cell) { cell.declared })),
  )
  let spec = read(directory <> "/app.graded")
  write(
    directory <> "/app.graded",
    spec
      <> "assume app/declared : []\n"
      <> string.concat(
      list.map(cells, fn(cell) { cell.other_spec <> cell.declared_spec }),
    ),
  )
  let toml = fn(targets) {
    "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\npairdep = { path = \"../pairdep\" }\naliasdep = { path = \"../aliasdep\" }\n\n[tools.graded]\ntargets = "
    <> targets
    <> "\n"
  }
  write(directory <> "/gleam.toml", toml("[\"erlang\", \"javascript\"]"))
  case observed(directory, "erlang"), observed(directory, "javascript") {
    Error(output), _ | _, Error(output) ->
      Outcome(
        ["two-target matrix did not run:\n" <> output],
        0,
        list.length(cases),
      )
    Ok(erlang), Ok(javascript) -> {
      let printed = dict.combine(erlang, javascript, set.union)
      let both = answers(graded, directory)
      let both_spec = read(directory <> "/app.graded")
      write(directory <> "/gleam.toml", toml("[\"erlang\"]"))
      let erlang_only = answers(graded, directory)
      write(directory <> "/gleam.toml", toml("[\"javascript\"]"))
      let javascript_only = answers(graded, directory)
      write(directory <> "/gleam.toml", toml("[\"erlang\", \"javascript\"]"))
      let inconsistent =
        consistency_failures(
          "matrix",
          directory,
          both_spec,
          list.index_map(cells, fn(cell, index) {
            #("app.case_" <> int.to_string(index + 1), cell.case_.name)
          })
            |> dict.from_list,
        )
      let failures =
        list.index_map(cells, fn(cell, index) { #(index + 1, cell) })
        |> list.filter_map(fn(pair) {
          let #(n, cell) = pair
          let function = "case_" <> int.to_string(n)
          let get = fn(answers) {
            dict.get(answers, function) |> result.unwrap(set.new())
          }
          let answer = get(both)
          let join = set.union(get(erlang_only), get(javascript_only))
          let missing =
            set.to_list(get(printed))
            |> list.filter(fn(label) { !set.contains(answer, label) })
          let unsound = missing != [] && !set.contains(answer, "Unknown")
          let off = answer != join
          case unsound || off {
            False -> Error(Nil)
            True ->
              Ok(
                "matrix "
                <> function
                <> " ("
                <> cell.case_.name
                <> "): printed "
                <> labels(get(printed))
                <> ", answered "
                <> labels(answer)
                <> ", join of single-target answers "
                <> labels(join),
              )
          }
        })
      Outcome(
        list.append(failures, inconsistent),
        dict.size(dict.delete(printed, "main")),
        list.length(cases),
      )
    }
  }
}

// Where the package's proofs disagree with its inferred spec, read with the
// two-target spec in place: a `check` of every public function's inferred
// line must pass, a `check` of a line without bounds against `[]` must fail
// exactly where the line states a nonempty set, `effect` must state the
// inferred line, and `effect` and `why` must describe the function in one
// sentence. `names` names each case function by its cell.
fn consistency_failures(
  block: String,
  directory: String,
  spec: String,
  names: Dict(String, String),
) -> List(String) {
  let spec_path = directory <> "/app.graded"
  let #(inferred, unchecked) =
    statements(spec)
    |> list.partition(fn(statement) {
      string.starts_with(statement, "effects app.")
      || string.starts_with(statement, "effects app/")
    })
  let lines =
    list.map(inferred, fn(statement) {
      let rest = string.drop_start(statement, string.length("effects "))
      let path =
        string.split(rest, " ")
        |> list.first
        |> result.unwrap("")
        |> string.split("(")
        |> list.first
        |> result.unwrap("")
      #(path, rest)
    })
  let checked = fn(lines: List(String)) {
    write(
      spec_path,
      string.join(unchecked, "\n") <> "\n" <> string.concat(lines),
    )
    violating_functions(directory)
  }
  let over_answer =
    checked(list.map(lines, fn(line) { "check " <> line.1 <> "\n" }))
  let ground =
    list.filter(lines, fn(line) {
      !string.starts_with(string.drop_start(line.1, string.length(line.0)), "(")
    })
  let over_nothing =
    checked(list.map(ground, fn(line) { "check " <> line.0 <> " : []\n" }))
  write(spec_path, spec)
  let paths = list.map(lines, fn(line) { line.0 })
  let whys =
    graded.run_why_each(directory, paths)
    |> result.unwrap([])
    |> dict.from_list
  let effects =
    names_or_error(dict.from_list(graded.run_effect_each(directory, paths)))
  list.flat_map(lines, fn(line) {
    let #(path, rest) = line
    let complaint = fn(what) {
      case dict.get(names, path) {
        Ok(name) -> block <> " " <> path <> " (" <> name <> "): " <> what
        Error(Nil) -> block <> " " <> path <> ": " <> what
      }
    }
    let first_line = fn(text: String) {
      string.split(text, "\n")
      |> list.find(fn(line) { !string.starts_with(line, "//") })
      |> result.unwrap("")
    }
    let effect = fn(format) {
      dict.get(effects, path) |> result.map(answer.render(_, format))
    }
    let effect_line = effect(answer.Graded) |> result.map(collapsed)
    let effect_sentence = effect(answer.Prose) |> result.map(first_line)
    let why_sentence =
      dict.get(names_or_error(whys), path)
      |> result.map(first_line)
    let stated = effects_part(rest)
    list.flatten([
      case set.contains(over_answer, path) {
        True -> [
          complaint("a check of its inferred line `" <> rest <> "` fails"),
        ]
        False -> []
      },
      case list.contains(ground, line) {
        False -> []
        True ->
          case set.contains(over_nothing, path), set.is_empty(stated) {
            True, True -> [
              complaint("a check against [] fails while it answers []"),
            ]
            False, False -> [
              complaint(
                "a check against [] passes while it answers " <> labels(stated),
              ),
            ]
            _, _ -> []
          }
      },
      case effect_line {
        Ok(text) ->
          case first_line(text) == collapsed("effects " <> rest) {
            True -> []
            False -> [
              complaint(
                "effect states `"
                <> first_line(text)
                <> "` where infer wrote `effects "
                <> rest
                <> "`",
              ),
            ]
          }
        Error(_) -> [complaint("effect found no answer")]
      },
      case effect_sentence, why_sentence {
        Ok(effect), Ok(why) if effect == why -> []
        Ok(effect), Ok(why) -> [
          complaint("effect says `" <> effect <> "` and why `" <> why <> "`"),
        ]
        _, _ -> [complaint("effect or why found no answer")]
      },
    ])
  })
}

fn names_or_error(answers: Dict(String, Result(v, a))) -> Dict(String, v) {
  dict.fold(answers, dict.new(), fn(acc, name, answered) {
    case answered {
      Ok(found) -> dict.insert(acc, name, found)
      Error(_) -> acc
    }
  })
}

// A spec's statements, each with its continuation lines joined onto it.
fn statements(spec: String) -> List(String) {
  string.split(spec, "\n")
  |> list.fold([], fn(acc, line) {
    case string.starts_with(line, " "), acc {
      True, [previous, ..rest] -> [
        previous <> " " <> string.trim_start(line),
        ..rest
      ]
      _, _ -> [line, ..acc]
    }
  })
  |> list.reverse
  |> list.filter(fn(statement) { statement != "" })
}

// A rendering with each continuation joined onto its statement.
fn collapsed(text: String) -> String {
  string.join(statements(text), "\n")
}

// The labels the effects half of a statement after its path names.
fn effects_part(rest: String) -> Set(String) {
  case string.split_once(rest, " : ") {
    Ok(#(_head, tail)) ->
      case string.split_once(tail, " where ") {
        Ok(#(effects, _clauses)) -> stated_set(effects)
        Error(Nil) -> stated_set(tail)
      }
    Error(Nil) -> set.new()
  }
}

// The functions a `check` of the project reports a violation for, by their
// module-qualified names.
fn violating_functions(directory: String) -> Set(String) {
  case graded.run(directory) {
    Error(_) -> set.new()
    Ok(reports) ->
      list.flat_map(reports, fn(report) {
        let module = module_of_file(report.file)
        list.filter_map(report.violations, fn(line) {
          use #(_file, rest) <- result.try(string.split_once(line, ": "))
          string.split(rest, " ")
          |> list.first
          |> result.map(fn(function) { module <> "." <> function })
        })
      })
      |> set.from_list
  }
}

// The module path of a source file under `src/`.
fn module_of_file(file: String) -> String {
  case string.split_once(file, "/src/") {
    Ok(#(_, path)) -> string.replace(path, ".gleam", "")
    Error(Nil) -> file
  }
}

// The set the last bracketed list of a stated line names.
fn stated_set(line: String) -> Set(String) {
  case string.split(line, "[") |> list.last {
    Ok(tail) ->
      string.split_once(tail, "]")
      |> result.map(fn(pair) { effect_labels("[" <> pair.0 <> "]") })
      |> result.unwrap(set.new())
    Error(Nil) -> set.new()
  }
}

// The byte offset at which `marker` first occurs in `text`.
fn offset_of(text: String, marker: String) -> Int {
  case string.split_once(text, marker) {
    Ok(#(before, _)) -> string.byte_size(before)
    Error(Nil) -> 0
  }
}

// `prefix`, a comment line, then `tail` starting at byte `offset`.
fn padded(prefix: String, tail: String, offset: Int) -> String {
  prefix
  <> "//"
  <> string.repeat(" ", offset - string.byte_size(prefix) - 3)
  <> "\n"
  <> tail
}

// The negative control

// Both packages take a standard library the bundled catalog's review covers,
// so the regenerated summary reads `list.each` as the review states it, not
// as a line about an unreviewed release.
fn stale_control(graded: String, directory: String) -> Result(String, String) {
  write(
    directory <> "/old_dep/gleam.toml",
    "name = \"old_dep\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and <= 1.0.5\"\n",
  )
  write(directory <> "/old_dep/old_dep.graded", "effects old_dep.tick : []\n")
  write(
    directory <> "/old_dep/src/old_dep.gleam",
    "import gleam/io\nimport gleam/list\n\nfn loud() -> Nil {\n  io.println(\"HIT 1\")\n}\n\npub fn tick() -> Nil {\n  list.each([loud], fn(f) { f() })\n}\n",
  )
  write(
    directory <> "/consumer/gleam.toml",
    "name = \"consumer\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and <= 1.0.5\"\nold_dep = { path = \"../old_dep\" }\n",
  )
  write(
    directory <> "/consumer/src/consumer.gleam",
    "import old_dep\n\npub fn main() -> Nil {\n  old_dep.tick()\n}\n\npub fn go() -> Nil {\n  old_dep.tick()\n}\n",
  )
  let printed =
    shellout.command(
      run: "gleam",
      with: ["run"],
      in: directory <> "/consumer",
      opt: [],
    )
    |> result.unwrap("")
    |> string.contains("HIT 1")
  let stale = consumer_answer(graded, directory)
  // Regenerated, the dependency's summary reaches its consumer.
  let _ =
    shellout.command(
      run: "gleam",
      with: ["deps", "download"],
      in: directory <> "/old_dep",
      opt: [],
    )
  infer(graded, directory <> "/old_dep")
  let regenerated = consumer_answer(graded, directory)
  case printed, set.to_list(stale), set.to_list(regenerated) {
    True, [], ["Stdout"] ->
      Ok(
        "stale dependency control: prints while its consumer reads [] (the precondition failure, as documented); regenerated, the consumer reads [Stdout]",
      )
    _, _, _ ->
      Error(
        "stale dependency control: printed "
        <> bool_text(printed)
        <> ", stale answer "
        <> labels(stale)
        <> ", regenerated answer "
        <> labels(regenerated)
        <> "; expected yes, [], [Stdout]",
      )
  }
}

fn consumer_answer(graded: String, directory: String) -> Set(String) {
  infer(graded, directory <> "/consumer")
  read(directory <> "/consumer/consumer.graded")
  |> string.split("\n")
  |> list.find_map(fn(line) {
    case line {
      "effects consumer.go : " <> effects -> Ok(effect_labels(effects))
      _ -> Error(Nil)
    }
  })
  |> result.unwrap(set.from_list(["no answer"]))
}

fn infer(graded: String, directory: String) -> Nil {
  let _ =
    shellout.command(
      run: "gleam",
      with: ["run", "-m", "graded", "--", "infer", directory],
      in: graded,
      opt: [],
    )
  Nil
}

fn bool_text(value: Bool) -> String {
  case value {
    True -> "yes"
    False -> "no"
  }
}

// 1 to `count`, in order.
fn numbers(count: Int) -> List(Int) {
  int.range(from: count, to: 0, with: [], run: list.prepend)
}

fn write(path: String, contents: String) -> Nil {
  let _ = simplifile.create_directory_all(filepath.directory_name(path))
  let _ = simplifile.write(path, contents)
  Nil
}

fn read(path: String) -> String {
  simplifile.read(path) |> result.unwrap("")
}

fn absolute(path: String) -> String {
  case string.starts_with(path, "/") {
    True -> path
    False -> {
      let assert Ok(cwd) = simplifile.current_directory()
      filepath.join(cwd, path)
    }
  }
}

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

@external(erlang, "scope_test_ffi", "reductions")
fn reductions() -> Int
