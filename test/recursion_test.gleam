// A call that reaches a function already being walked, read as what that
// function does with this call's arguments: a callback passed on around the
// cycle, a function returned from it, and a reference to it handed to a
// higher-order call.

import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import graded
import support

@external(erlang, "scope_test_ffi", "reductions")
fn reductions() -> Int

const ffi_source =
  "@external(erlang, \"m\", \"shout\")
@external(javascript, \"m\", \"shout\")
pub fn shout() -> Nil
"

const spec = "assume probe/ffi.shout : [Stdout]\n"

const shapes_source =
  "import probe/ffi

fn quiet() -> Nil {
  Nil
}

fn choose(n: Int, f: fn() -> Nil) -> Nil {
  case n {
    0 -> f()
    _ -> choose(n - 1, ffi.shout)
  }
}

pub fn direct() -> Nil {
  choose(1, quiet)
}

fn choose_alias(n: Int, f: fn() -> Nil) -> Nil {
  case n {
    0 -> {
      let h = f
      h()
    }
    _ -> choose_alias(n - 1, ffi.shout)
  }
}

pub fn alias() -> Nil {
  choose_alias(1, quiet)
}

fn choose_choice(n: Int, f: fn() -> Nil) -> Nil {
  case n {
    0 -> {
      let h = case n == 0 {
        True -> f
        False -> f
      }
      h()
    }
    _ -> choose_choice(n - 1, ffi.shout)
  }
}

pub fn choice() -> Nil {
  choose_choice(1, quiet)
}

fn ping(n: Int, f: fn() -> Nil) -> Nil {
  case n {
    0 -> f()
    _ -> pong(n - 1, ffi.shout)
  }
}

fn pong(n: Int, g: fn() -> Nil) -> Nil {
  ping(n, g)
}

pub fn mutual() -> Nil {
  ping(2, quiet)
}

pub fn public_choose(n: Int, f: fn() -> Nil) -> Nil {
  case n {
    0 -> f()
    _ -> public_choose(n - 1, ffi.shout)
  }
}

pub fn same_module() -> Nil {
  public_choose(1, quiet)
}

fn wrap(n: Int, f: fn() -> Nil) -> Nil {
  case n {
    0 -> f()
    _ -> wrap(n - 1, fn() { ffi.shout() })
  }
}

pub fn closure() -> Nil {
  wrap(1, quiet)
}

fn call_it(f: fn() -> Nil) -> Nil {
  f()
}

fn apply(n: Int, op: fn(fn() -> Nil) -> Nil, f: fn() -> Nil) -> Nil {
  case n {
    0 -> op(f)
    _ -> apply(n - 1, op, ffi.shout)
  }
}

pub fn operator() -> Nil {
  apply(1, call_it, quiet)
}

fn make(n: Int, f: fn() -> Nil) -> fn() -> Nil {
  case n {
    0 -> f
    _ -> make(n - 1, ffi.shout)
  }
}

pub fn producer() -> Nil {
  make(1, quiet)()
}

fn hand(n: Int, f: fn() -> Nil, k: fn(Int, fn() -> Nil) -> Nil) -> Nil {
  k(n, f)
}

fn go(n: Int, f: fn() -> Nil) -> Nil {
  case n {
    0 -> f()
    _ -> hand(n - 1, ffi.shout, go)
  }
}

pub fn reference() -> Nil {
  go(1, quiet)
}

fn keep(n: Int, f: fn() -> Nil) -> Nil {
  case n {
    0 -> f()
    _ -> keep(n - 1, f)
  }
}

pub fn same_quiet() -> Nil {
  keep(3, quiet)
}

pub fn same_print() -> Nil {
  keep(3, ffi.shout)
}

fn swap_quiet(n: Int, f: fn() -> Nil) -> Nil {
  case n {
    0 -> f()
    _ -> swap_quiet(n - 1, quiet)
  }
}

pub fn other_quiet() -> Nil {
  swap_quiet(1, quiet)
}

fn each(xs: List(Tree), f: fn(Tree) -> Nil) -> Nil {
  case xs {
    [] -> Nil
    [x, ..rest] -> {
      f(x)
      each(rest, f)
    }
  }
}

pub type Tree {
  Tree(children: List(Tree))
}

fn walk(tree: Tree, f: fn() -> Nil) -> Nil {
  f()
  each(tree.children, fn(child) { walk(child, f) })
}

pub fn tree_quiet(tree: Tree) -> Nil {
  walk(tree, quiet)
}

fn keep_returned(n: Int, f: fn() -> Nil) -> fn() -> Nil {
  case n {
    0 -> f
    _ -> keep_returned(n - 1, f)
  }
}

pub fn producer_same() -> Nil {
  keep_returned(1, quiet)()
}

fn go_same(n: Int, f: fn() -> Nil) -> Nil {
  case n {
    0 -> f()
    _ -> hand(n - 1, f, go_same)
  }
}

pub fn reference_same() -> Nil {
  go_same(1, quiet)
}
"

fn shapes_project(directory: String, extra_spec: String) -> String {
  support.write_fixture(directory, [
    #("gleam.toml", support.dual_target_toml("probe")),
    #("probe.graded", spec <> extra_spec),
    #("src/probe/ffi.gleam", ffi_source),
    #("src/probe.gleam", shapes_source),
  ])
}

fn answers(lines: List(String), functions: List(String)) {
  list.map(functions, fn(function) {
    let prefix = "effects probe." <> function
    let assert Ok(line) =
      list.find(lines, fn(line) {
        string.starts_with(line, prefix <> " ")
        || string.starts_with(line, prefix <> "(")
      })
    #(function, line)
  })
}

pub fn a_recursive_call_reads_what_the_callee_does_with_its_arguments_test() {
  let directory = shapes_project("/tmp/graded_recursion_shapes", "")
  let assert Ok(lines) = graded.inferred_lines(directory)
  support.cleanup(directory)
  answers(lines, [
    "direct", "alias", "choice", "mutual", "public_choose", "same_module",
    "closure", "operator", "producer", "reference",
  ])
  |> should.equal([
    #("direct", "effects probe.direct : [Stdout]"),
    #("alias", "effects probe.alias : [Stdout]"),
    #("choice", "effects probe.choice : [Stdout]"),
    #("mutual", "effects probe.mutual : [Stdout]"),
    #("public_choose", "effects probe.public_choose(f: [f]) : [Stdout, f]"),
    #("same_module", "effects probe.same_module : [Stdout]"),
    #("closure", "effects probe.closure : [Stdout]"),
    #("operator", "effects probe.operator : [Stdout]"),
    #("producer", "effects probe.producer : [Stdout]"),
    #("reference", "effects probe.reference : [Stdout]"),
  ])
}

pub fn a_callback_passed_on_unchanged_keeps_its_own_effects_test() {
  let directory = shapes_project("/tmp/graded_recursion_controls", "")
  let assert Ok(lines) = graded.inferred_lines(directory)
  support.cleanup(directory)
  answers(lines, [
    "same_quiet", "same_print", "other_quiet", "tree_quiet", "producer_same",
    "reference_same",
  ])
  |> should.equal([
    #("same_quiet", "effects probe.same_quiet : []"),
    #("same_print", "effects probe.same_print : [Stdout]"),
    #("other_quiet", "effects probe.other_quiet : []"),
    #("tree_quiet", "effects probe.tree_quiet : []"),
    #("producer_same", "effects probe.producer_same : []"),
    #("reference_same", "effects probe.reference_same : []"),
  ])
}

pub fn check_effect_and_why_read_the_recursive_call_test() {
  let directory =
    shapes_project(
      "/tmp/graded_recursion_readings",
      "check probe.direct : []\ncheck probe.same_quiet : []\n",
    )
  let assert Ok(reports) = graded.run(directory)
  let assert Ok(effect) = graded.run_effect(directory, "probe.direct")
  let assert Ok(why) = graded.run_why(directory, "probe.direct")
  support.cleanup(directory)
  let violations = list.flat_map(reports, fn(report) { report.violations })
  list.map(violations, fn(line) {
    #(
      string.contains(line, "direct calls probe.choose"),
      string.contains(line, "[Stdout]"),
    )
  })
  |> should.equal([#(True, True)])
  string.contains(effect, "[Stdout]") |> should.be_true
  string.contains(why, "calls probe.choose with effects [Stdout]")
  |> should.be_true
}

// A program of `source` beside the printing foreign function, its public
// answers by name.
fn program_answers(
  directory: String,
  source: String,
  functions: List(String),
) -> List(#(String, String)) {
  let directory =
    support.write_fixture(directory, [
      #("gleam.toml", support.dual_target_toml("probe")),
      #("probe.graded", spec),
      #("src/probe/ffi.gleam", ffi_source),
      #("src/probe.gleam", source),
    ])
  let assert Ok(lines) = graded.inferred_lines(directory)
  support.cleanup(directory)
  answers(lines, functions)
}

const paths_source =
  "import probe/ffi

fn quiet() -> Nil {
  Nil
}

pub type Box {
  Box(run: fn() -> Nil)
}

fn choose(n: Int, b: Box) -> Nil {
  case n {
    0 -> b.run()
    _ -> choose(n - 1, Box(ffi.shout))
  }
}

pub fn field() -> Nil {
  choose(1, Box(quiet))
}

fn choose_dummy(n: Int, b: Box, unused: fn() -> Nil) -> Nil {
  case n {
    0 -> b.run()
    _ -> choose_dummy(n - 1, Box(ffi.shout), unused)
  }
}

pub fn field_dummy() -> Nil {
  choose_dummy(1, Box(quiet), quiet)
}

fn ping(n: Int, b: Box) -> Nil {
  case n {
    0 -> b.run()
    _ -> pong(n - 1, Box(ffi.shout))
  }
}

fn pong(n: Int, b: Box) -> Nil {
  ping(n, b)
}

pub fn field_mutual() -> Nil {
  ping(2, Box(quiet))
}

fn tick(n: Int, b: Box) -> Nil {
  case n {
    0 -> b.run()
    _ -> tock(n - 1, Box(ffi.shout))
  }
}

fn tock(n: Int, other: Box) -> Nil {
  tick(n, other)
}

pub fn field_mutual_renamed() -> Nil {
  tick(2, Box(quiet))
}

fn rotate(n: Int, b: Box, c: Box) -> Nil {
  case n {
    0 -> b.run()
    _ -> rotate(n - 1, c, b)
  }
}

pub fn field_rotated() -> Nil {
  rotate(1, Box(quiet), Box(ffi.shout))
}

fn keep(n: Int, b: Box) -> Nil {
  case n {
    0 -> b.run()
    _ -> keep(n - 1, b)
  }
}

pub fn field_unchanged() -> Nil {
  keep(2, Box(quiet))
}

fn quieted(n: Int, b: Box) -> Nil {
  case n {
    0 -> b.run()
    _ -> quieted(n - 1, Box(quiet))
  }
}

pub fn field_quieted() -> Nil {
  quieted(2, Box(quiet))
}

fn gather(n: Int, fs: List(fn() -> Nil)) -> List(fn() -> Nil) {
  case n {
    0 -> fs
    _ -> gather(n - 1, [ffi.shout, ..fs])
  }
}

pub fn accumulated() -> Nil {
  let _ = gather(2, [])
  Nil
}
"

// A call back in whose argument rebinds a field of a record parameter
// contributes what the field then does: directly, beside a callback, through
// a mutual call — each function naming the record alike or not — and rotated
// between two records. A record passed on
// unchanged or rebuilt quiet stays quiet, and functions only gathered and
// returned add nothing.
pub fn a_recursive_call_reads_the_fields_it_rebinds_test() {
  program_answers("/tmp/graded_recursion_paths", paths_source, [
    "field", "field_dummy", "field_mutual", "field_mutual_renamed",
    "field_rotated", "field_unchanged", "field_quieted", "accumulated",
  ])
  |> should.equal([
    #("field", "effects probe.field : [Stdout]"),
    #("field_dummy", "effects probe.field_dummy : [Stdout]"),
    #("field_mutual", "effects probe.field_mutual : [Stdout]"),
    #("field_mutual_renamed", "effects probe.field_mutual_renamed : [Stdout]"),
    #("field_rotated", "effects probe.field_rotated : [Stdout]"),
    #("field_unchanged", "effects probe.field_unchanged : []"),
    #("field_quieted", "effects probe.field_quieted : []"),
    #("accumulated", "effects probe.accumulated : []"),
  ])
}

const producers_source =
  "import probe/ffi

fn quiet() -> Nil {
  Nil
}

fn ping(n: Int, f: fn() -> Nil) -> fn() -> Nil {
  case n {
    0 -> f
    _ -> pong(n - 1, f)
  }
}

fn pong(n: Int, g: fn() -> Nil) -> fn() -> Nil {
  ping(n, g)
}

pub fn mutual_quiet() -> Nil {
  let f = ping(1, quiet)
  f()
}

pub fn mutual_printer() -> Nil {
  let f = ping(1, ffi.shout)
  f()
}
"

// Mutually recursive producers solve their returns together: a quiet callback
// passed round stays quiet and a printer passed round prints, with no
// `[Unknown]` where every callback is known.
pub fn mutual_producers_read_what_they_pass_round_test() {
  program_answers("/tmp/graded_recursion_producers", producers_source, [
    "mutual_quiet", "mutual_printer",
  ])
  |> should.equal([
    #("mutual_quiet", "effects probe.mutual_quiet : []"),
    #("mutual_printer", "effects probe.mutual_printer : [Stdout]"),
  ])
}

// `rotate_<width>(n, f0, ..., f<width - 1>)` running `f0` and rotating its
// callbacks on each call back in, called with quiet ones.
fn rotation_source(width: Int) -> String {
  let names =
    list.repeat(Nil, width)
    |> list.index_map(fn(_, index) { "f" <> int.to_string(index) })
  let suffix = int.to_string(width)
  let rotated = case names {
    [first, ..rest] -> list.append(rest, [first])
    [] -> []
  }
  "fn quiet() -> Nil {\n  Nil\n}\n\nfn rotate_"
  <> suffix
  <> "(n: Int, "
  <> string.join(list.map(names, fn(name) { name <> ": fn() -> Nil" }), ", ")
  <> ") -> Nil {\n  case n {\n    0 -> f0()\n    _ -> rotate_"
  <> suffix
  <> "(n - 1, "
  <> string.join(rotated, ", ")
  <> ")\n  }\n}\n\npub fn main_"
  <> suffix
  <> "() -> Nil {\n  rotate_"
  <> suffix
  <> "(2, "
  <> string.join(list.map(names, fn(_) { "quiet" }), ", ")
  <> ")\n}\n"
}

// Callbacks rotated round a cycle settle within as many rounds as the cycle
// names them, however many there are: every width stays quiet.
pub fn a_rotation_of_any_width_settles_quiet_test() {
  [1, 31, 32, 40]
  |> list.map(fn(width) {
    program_answers("/tmp/graded_recursion_rotation", rotation_source(width), [
      "main_" <> int.to_string(width),
    ])
  })
  |> should.equal([
    [#("main_1", "effects probe.main_1 : []")],
    [#("main_31", "effects probe.main_31 : []")],
    [#("main_32", "effects probe.main_32 : []")],
    [#("main_40", "effects probe.main_40 : []")],
  ])
}

// `rotate_<width>(n, b0, ..., b<width - 1>)` running `b0`'s field and rotating
// its records on each call back in, called with quiet records and, in
// `loud_<width>`, the last one printing.
fn record_rotation_source(width: Int) -> String {
  let names =
    list.repeat(Nil, width)
    |> list.index_map(fn(_, index) { "b" <> int.to_string(index) })
  let suffix = int.to_string(width)
  let rotated = case names {
    [first, ..rest] -> list.append(rest, [first])
    [] -> []
  }
  let records = fn(last) {
    list.index_map(names, fn(_, index) {
      case index == width - 1 {
        True -> "Box(" <> last <> ")"
        False -> "Box(quiet)"
      }
    })
    |> string.join(", ")
  }
  "import probe/ffi\n\npub type Box {\n  Box(run: fn() -> Nil)\n}\n\nfn quiet() -> Nil {\n  Nil\n}\n\nfn rotate_"
  <> suffix
  <> "(n: Int, "
  <> string.join(list.map(names, fn(name) { name <> ": Box" }), ", ")
  <> ") -> Nil {\n  case n {\n    0 -> b0.run()\n    _ -> rotate_"
  <> suffix
  <> "(n - 1, "
  <> string.join(rotated, ", ")
  <> ")\n  }\n}\n\npub fn quiet_"
  <> suffix
  <> "() -> Nil {\n  rotate_"
  <> suffix
  <> "("
  <> suffix
  <> ", "
  <> records("quiet")
  <> ")\n}\n\npub fn loud_"
  <> suffix
  <> "() -> Nil {\n  rotate_"
  <> suffix
  <> "("
  <> suffix
  <> ", "
  <> records("ffi.shout")
  <> ")\n}\n"
}

// Records rotated round a cycle settle as callbacks do, however wide: quiet
// ones stay quiet and a printer among them prints.
pub fn a_rotation_of_records_settles_at_any_width_test() {
  [1, 40]
  |> list.map(fn(width) {
    let suffix = int.to_string(width)
    program_answers(
      "/tmp/graded_recursion_record_rotation",
      record_rotation_source(width),
      ["quiet_" <> suffix, "loud_" <> suffix],
    )
  })
  |> should.equal([
    [
      #("quiet_1", "effects probe.quiet_1 : []"),
      #("loud_1", "effects probe.loud_1 : [Stdout]"),
    ],
    [
      #("quiet_40", "effects probe.quiet_40 : []"),
      #("loud_40", "effects probe.loud_40 : [Stdout]"),
    ],
  ])
}

const nested_source =
  "fn quiet() -> Nil {
  Nil
}

pub type Leaf {
  Leaf(run: fn() -> Nil)
}

pub type Middle {
  Middle(inner: Leaf)
}

pub type Outer {
  Outer(inner: Middle)
}

pub type Wide {
  Wide(outer: Middle)
}

fn repeat(n: Int, b: Outer) -> Nil {
  case n {
    0 -> b.inner.inner.run()
    _ -> repeat(n - 1, b)
  }
}

pub fn repeated() -> Nil {
  repeat(1, Outer(Middle(Leaf(quiet))))
}

fn distinct(n: Int, b: Wide) -> Nil {
  case n {
    0 -> b.outer.inner.run()
    _ -> distinct(n - 1, b)
  }
}

pub fn distinct_labels() -> Nil {
  distinct(1, Wide(Middle(Leaf(quiet))))
}

pub type Node {
  Node(run: fn() -> Nil, next: Node)
}

fn follow(n: Int, node: Node) -> Nil {
  case n {
    0 -> node.run()
    _ -> follow(n - 1, node.next)
  }
}

pub fn self_holding(node: Node) -> Nil {
  follow(1, node)
}
"

// A path whose labels repeat through distinct record types is read like one
// whose labels differ; a path into a type that holds itself still ends.
pub fn a_path_repeating_a_label_through_distinct_types_is_kept_test() {
  let answers =
    program_answers("/tmp/graded_recursion_nested", nested_source, [
      "repeated", "distinct_labels", "self_holding",
    ])
  list.take(answers, 2)
  |> should.equal([
    #("repeated", "effects probe.repeated : []"),
    #("distinct_labels", "effects probe.distinct_labels : []"),
  ])
  list.drop(answers, 2)
  |> list.map(fn(answer) { string.contains(answer.1, ": [Unknown") })
  |> should.equal([True])
}

const operator_source =
  "fn quiet() -> Nil {
  Nil
}

fn use_it(f: fn() -> Nil) -> Nil {
  f()
}

fn ignore(f: fn() -> Nil) -> Nil {
  let _ = f
  Nil
}

fn walk(n: Int, op: fn(fn() -> Nil) -> Nil, f: fn() -> Nil) -> Nil {
  case n {
    0 -> f()
    _ -> op(fn() { walk(n - 1, op, f) })
  }
}

pub fn calls() -> Nil {
  walk(2, use_it, quiet)
}

pub fn ignores() -> Nil {
  walk(2, ignore, quiet)
}

fn rotate(
  n: Int,
  op: fn(fn() -> Nil) -> Nil,
  other: fn(fn() -> Nil) -> Nil,
  f: fn() -> Nil,
) -> Nil {
  case n {
    0 -> f()
    _ -> op(fn() { rotate(n - 1, other, op, f) })
  }
}

pub fn rotated() -> Nil {
  rotate(2, use_it, use_it, quiet)
}
"

// A recursive call handing an operator its own frame's arguments adds nothing
// beyond the frame, so a quiet operator stays quiet; one rotating unknown
// operators widens once its terms outgrow the bound, all within a bounded
// amount of work.
pub fn operator_recursion_reads_exactly_within_its_work_test() {
  let before = reductions()
  let answers =
    program_answers("/tmp/graded_recursion_operators", operator_source, [
      "calls", "ignores", "rotated",
    ])
  let spent = reductions() - before
  answers
  |> should.equal([
    #("calls", "effects probe.calls : []"),
    #("ignores", "effects probe.ignores : []"),
    #("rotated", "effects probe.rotated : [Unknown]"),
  ])
  { spent <= 30_000_000 } |> should.be_true
}

// A walk down a branching type that holds itself, beside `extras` nesting
// types nothing reaches.
fn fan_source(extras: Int) -> String {
  "pub type Node {\n  Node(run: fn() -> Nil, left: Node, right: Node)\n}\n\npub fn walk(n: Int, node: Node) -> Nil {\n  case n {\n    0 -> node.run()\n    _ -> {\n      walk(n - 1, node.left)\n      walk(n - 1, node.right)\n    }\n  }\n}\n\npub type Extra0 {\n  Extra0(child: Int)\n}\n"
  <> string.concat(
    list.map(
      int.range(from: extras, to: 0, with: [], run: list.prepend),
      fn(index) {
        let s = int.to_string(index)
        let below = int.to_string(index - 1)
        "\npub type Extra"
        <> s
        <> " {\n  Extra"
        <> s
        <> "(child: Extra"
        <> below
        <> ")\n}\n"
      },
    ),
  )
}

// A walk down both branches of a type that holds itself ends within a bound on
// its work that types it never reaches do not raise.
pub fn a_branching_walk_ends_within_its_work_whatever_else_is_defined_test() {
  [0, 18]
  |> list.map(fn(extras) {
    let before = reductions()
    let answers =
      program_answers("/tmp/graded_recursion_fan", fan_source(extras), [
        "walk",
      ])
    let spent = reductions() - before
    #(
      list.map(answers, fn(answer) { string.contains(answer.1, "Unknown") }),
      spent <= 30_000_000,
    )
  })
  |> should.equal([#([True], True), #([True], True)])
}

// Record types `Tree0` to `Tree<depth>`, each holding two of the one below,
// with every path down a `Tree<depth>` written out in a function that calls
// itself and in one that does not. A loud tree prints at one leaf.
fn written_paths_source(depth: Int) -> String {
  let levels = int.range(from: 1, to: depth + 1, with: [], run: list.prepend)
  let levels = list.reverse(levels)
  let below = fn(level) { int.to_string(level - 1) }
  let types =
    list.map(levels, fn(level) {
      let s = int.to_string(level)
      "pub type Tree"
      <> s
      <> " {\n  Tree"
      <> s
      <> "(left: Tree"
      <> below(level)
      <> ", right: Tree"
      <> below(level)
      <> ")\n}\n"
    })
  let paths =
    list.fold(levels, [""], fn(paths, _level) {
      list.flat_map(paths, fn(path) { [path <> ".left", path <> ".right"] })
    })
    |> list.map(fn(path) { "b" <> path <> ".run()" })
  let top = "Tree" <> int.to_string(depth)
  let quiet_chain =
    "  let q0 = Tree0(quiet)\n"
    <> string.concat(
      list.map(list.take(levels, depth - 1), fn(level) {
        "  let q"
        <> int.to_string(level)
        <> " = Tree"
        <> int.to_string(level)
        <> "(q"
        <> below(level)
        <> ", q"
        <> below(level)
        <> ")\n"
      }),
    )
  let loud_chain =
    "  let l0 = Tree0(ffi.shout)\n"
    <> string.concat(
      list.map(list.take(levels, depth - 1), fn(level) {
        "  let l"
        <> int.to_string(level)
        <> " = Tree"
        <> int.to_string(level)
        <> "(q"
        <> below(level)
        <> ", l"
        <> below(level)
        <> ")\n"
      }),
    )
  let half = "q" <> int.to_string(depth - 1)
  let quiet_tree = top <> "(" <> half <> ", " <> half <> ")"
  let loud_tree = top <> "(" <> half <> ", l" <> int.to_string(depth - 1) <> ")"
  "import probe/ffi\n\nfn quiet() -> Nil {\n  Nil\n}\n\npub type Tree0 {\n  Tree0(run: fn() -> Nil)\n}\n\n"
  <> string.join(types, "\n")
  <> "\nfn run_all(b: "
  <> top
  <> ") -> Nil {\n"
  <> string.concat(list.map(paths, fn(path) { "  " <> path <> "\n" }))
  <> "}\n\nfn run_down(n: Int, b: "
  <> top
  <> ") -> Nil {\n  case n {\n    0 -> Nil\n    _ -> {\n"
  <> string.concat(list.map(paths, fn(path) { "      " <> path <> "\n" }))
  <> "      run_down(n - 1, "
  <> top
  <> "(..b, left: b.left))\n    }\n  }\n}\n\npub fn all_quiet() -> Nil {\n"
  <> quiet_chain
  <> "  run_all("
  <> quiet_tree
  <> ")\n}\n\npub fn all_loud() -> Nil {\n"
  <> quiet_chain
  <> loud_chain
  <> "  run_all("
  <> loud_tree
  <> ")\n}\n\npub fn down_quiet() -> Nil {\n"
  <> quiet_chain
  <> "  run_down(2, "
  <> quiet_tree
  <> ")\n}\n\npub fn down_loud() -> Nil {\n"
  <> quiet_chain
  <> loud_chain
  <> "  run_down(2, "
  <> loud_tree
  <> ")\n}\n"
}

// Every path the source writes is read, however many there are, in a
// function that calls itself and in one that does not, within a bounded
// amount of work.
pub fn every_path_the_source_writes_is_read_test() {
  let before = reductions()
  let answers =
    program_answers("/tmp/graded_recursion_written", written_paths_source(8), [
      "all_quiet", "all_loud", "down_quiet", "down_loud",
    ])
  let spent = reductions() - before
  answers
  |> should.equal([
    #("all_quiet", "effects probe.all_quiet : []"),
    #("all_loud", "effects probe.all_loud : [Stdout]"),
    #("down_quiet", "effects probe.down_quiet : []"),
    #("down_loud", "effects probe.down_loud : [Stdout]"),
  ])
  { spent <= 30_000_000 } |> should.be_true
}
