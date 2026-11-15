// A name is read as the binder it named where it is written. A parameter's
// bound answers only for that parameter, a module function or an unqualified
// import only for a name no binding covers, and a value stored in a record or
// captured by a closure keeps the binder it named, whatever later binding
// shares its spelling.

import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import graded
import support

const ffi_source =
  "@external(erlang, \"m\", \"shout\")
@external(javascript, \"m\", \"shout\")
pub fn shout() -> Nil

@external(erlang, \"m\", \"run_any\")
@external(javascript, \"m\", \"run_any\")
pub fn run_any(x: a) -> Nil

@external(erlang, \"m\", \"calm\")
@external(javascript, \"m\", \"calm\")
pub fn calm() -> Nil
"

const spec =
  "assume app/ffi.shout : [Stdout]
assume app/ffi.run_any : []
assume app/ffi.calm : []
"

// Each function names a binder and reads it after another binding of the same
// spelling: a `let`, a case pattern, a closure or `use` parameter, a
// destructured `use`. `loud` prints, `quiet` and `action` do nothing.
const rebinding_source =
  "import app/ffi.{calm}
import gleam/option.{type Option, None, Some}

pub type Task {
  Task(run: fn() -> Nil)
}

pub fn action() -> Nil {
  Nil
}

fn quiet() -> Nil {
  Nil
}

fn loud() -> Nil {
  ffi.shout()
}

pub fn let_rebinding(f: fn() -> Nil) -> Nil {
  let task = Task(run: f)
  let f = quiet
  let _ = f
  task.run()
}

pub fn case_rebinding(f: fn() -> Nil, o: Option(fn() -> Nil)) -> Nil {
  let task = Task(run: f)
  case o {
    Some(f) -> {
      let _ = f
      task.run()
    }
    None -> Nil
  }
}

pub fn passed_after_rebinding(f: fn() -> Nil) -> Nil {
  let task = Task(run: f)
  let f = loud
  let _ = f
  ffi.run_any(task)
}

pub fn traced_let_rebinding() -> Nil {
  let g = ffi.shout
  let task = Task(run: g)
  let g = quiet
  let _ = g
  task.run()
}

pub fn closure_param(f: fn() -> Nil) -> fn(fn() -> Nil) -> Nil {
  let task = Task(run: f)
  fn(f) {
    let _ = f
    task.run()
  }
}

pub fn opaque_let_call(f: fn() -> Nil) -> Nil {
  let #(f) = #(loud)
  f()
}

pub fn case_pattern_call(f: fn() -> Nil, o: Option(fn() -> Nil)) -> Nil {
  case o {
    Some(f) -> f()
    None -> Nil
  }
}

fn with_loud(next: fn(fn() -> Nil) -> Nil) -> Nil {
  next(loud)
}

pub fn use_param_call(f: fn() -> Nil) -> Nil {
  use f <- with_loud()
  f()
}

fn with_pair(next: fn(#(fn() -> Nil)) -> Nil) -> Nil {
  next(#(loud))
}

pub fn destructured_use() -> Nil {
  use #(action) <- with_pair()
  action()
}

pub fn shadowed_import() -> Nil {
  let #(calm) = #(loud)
  calm()
}

pub fn pure_maker() -> fn() -> Nil {
  action
}

pub fn producer_parameter(pure_maker: fn() -> fn() -> Nil) -> Nil {
  pure_maker()()
}

fn make(handler: fn() -> Nil) -> Task {
  let handler = loud
  Task(run: handler)
}

pub fn rebound_factory() -> Nil {
  let task = make(action)
  task.run()
}
"

fn inferred_app(directory: String, source: String) -> List(String) {
  let directory =
    support.write_fixture(directory, [
      #("gleam.toml", "name = \"app\"\n"),
      #("app.graded", spec),
      #("src/app/ffi.gleam", ffi_source),
      #("src/app.gleam", source),
    ])
  let assert Ok(lines) = graded.inferred_lines(directory)
  support.cleanup(directory)
  list.filter(lines, string.starts_with(_, "effects app."))
}

pub fn a_name_reads_the_binder_it_named_where_written_test() {
  inferred_app("/tmp/graded_scope_rebinding", rebinding_source)
  |> should.equal([
    "effects app.action : []",
    // The call names the pattern's binding, which nothing traces.
    "effects app.case_pattern_call : [Unknown]",
    // The parameter stored before a case pattern rebinds its spelling.
    "effects app.case_rebinding(f: [f]) : [f]",
    // The closure's own parameter is not the parameter the record stored.
    "effects app.closure_param : [] where returns : fn(f) -> [Unknown]",
    "effects app.destructured_use : [Stdout, Unknown]",
    "effects app.let_rebinding(f: [f]) : [f]",
    "effects app.opaque_let_call : [Unknown]",
    "effects app.passed_after_rebinding(f: [f]) : [f]",
    // A parameter called as a producer is not the module's function.
    "effects app.producer_parameter(pure_maker: [pure_maker]) : [Unknown, pure_maker]",
    "effects app.pure_maker : [] where returns : []",
    // The factory's parameter is rebound before the record is built, so the
    // argument is not what the field holds.
    "effects app.rebound_factory : [Unknown]",
    // A local binding covers the name an unqualified import also brings in.
    "effects app.shadowed_import : [Unknown]",
    // The record stored the first `g`, which prints.
    "effects app.traced_let_rebinding : [Stdout]",
    "effects app.use_param_call : [Unknown]",
  ])
}

// A record stores a module function or a parameter; the field is called inside
// a closure, or after a binding, that shares the stored name's spelling.
const field_source =
  "import app/ffi

pub type Task {
  Task(run: fn() -> Nil)
}

fn loud() -> Nil {
  ffi.shout()
}

pub fn make() -> fn(fn() -> Nil) -> Nil {
  let task = Task(run: loud)
  fn(loud) {
    let _ = loud
    task.run()
  }
}

pub fn go() -> Nil {
  let f = make()
  f(fn() { Nil })
}

pub fn nested(f: fn() -> Nil) -> fn(fn() -> Nil) -> fn(fn() -> Nil) -> Nil {
  let task = Task(run: f)
  fn(f) {
    let _ = f
    fn(g) {
      let _ = g
      task.run()
    }
  }
}

pub fn module_field() -> Nil {
  let task = Task(run: loud)
  task.run()
}

pub fn parameter_field(f: fn() -> Nil) -> Nil {
  let task = Task(run: f)
  task.run()
}

pub fn field_rebinding() -> Nil {
  let task = Task(run: loud)
  let loud = fn() { Nil }
  let _ = loud
  task.run()
}
"

pub fn a_field_reads_the_binder_its_record_stored_test() {
  inferred_app("/tmp/graded_scope_field", field_source)
  |> should.equal([
    "effects app.field_rebinding : [Stdout]",
    "effects app.go : [Stdout]",
    "effects app.make : [] where returns : fn(loud) -> [Stdout]",
    "effects app.module_field : [Stdout]",
    "effects app.nested : [] where returns : fn(f) -> [Unknown]",
    "effects app.parameter_field(f: [f]) : [f]",
  ])
}

// A dependency returns closures over case-pattern bindings — a constructor
// pattern, an alias, alternatives — each sharing its name with a pure function
// of the dependency. The consumer trusts that calling the producers prints
// nothing, which is true: only the closures they return print.
pub fn a_case_arm_closes_over_its_own_pattern_test() {
  let parent =
    support.write_fixture("build/scope_case_arms", [
      #("maker/gleam.toml", "name = \"maker\"\nversion = \"1.0.0\"\n"),
      #("maker/manifest.toml", "packages = []\n"),
      #("maker/maker.graded", "assume maker/ffi.shout : [Stdout]\n"),
      #(
        "maker/src/maker/ffi.gleam",
        "@external(erlang, \"m\", \"shout\")\npub fn shout() -> Nil\n",
      ),
      #(
        "maker/src/maker.gleam",
        "import gleam/option.{type Option, None, Some}
import maker/ffi

pub type Either {
  Left(fn() -> Nil)
  Right(fn() -> Nil)
}

pub fn action() -> Nil {
  Nil
}

fn printer() -> Option(fn() -> Nil) {
  Some(ffi.shout)
}

fn pick() -> Either {
  Left(ffi.shout)
}

pub fn constructor() -> fn() -> Nil {
  case printer() {
    Some(action) -> fn() { action() }
    None -> fn() { Nil }
  }
}

pub fn aliased() -> fn() -> Nil {
  case pick() {
    Left(_ as action) -> fn() { action() }
    Right(_) -> fn() { Nil }
  }
}

pub fn alternatives() -> fn() -> Nil {
  case pick() {
    Left(action) | Right(action) -> fn() { action() }
  }
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
      #(
        "consumer/consumer.graded",
        "assume maker.constructor : []\nassume maker.aliased : []\nassume maker.alternatives : []\n",
      ),
      #(
        "consumer/src/consumer.gleam",
        "import maker

pub fn go_constructor() -> Nil {
  let f = maker.constructor()
  f()
}

pub fn go_aliased() -> Nil {
  let f = maker.aliased()
  f()
}

pub fn go_alternatives() -> Nil {
  let f = maker.alternatives()
  f()
}
",
      ),
    ])
  let assert Ok(Nil) = graded.run_infer(parent <> "/maker")
  let assert Ok(maker) = graded.inferred_lines(parent <> "/maker")
  let assert Ok(consumer) = graded.inferred_lines(parent <> "/consumer")
  support.cleanup("build/scope_case_arms")
  maker
  |> list.filter(string.starts_with(_, "effects maker."))
  |> should.equal([
    "effects maker.action : []",
    "effects maker.aliased : [Unknown]",
    "effects maker.alternatives : [Unknown]",
    "effects maker.constructor : [Unknown]",
  ])
  consumer
  |> should.equal([
    "effects consumer.go_aliased : [Unknown]",
    "effects consumer.go_alternatives : [Unknown]",
    "effects consumer.go_constructor : [Unknown]",
  ])
}

// Values that name earlier bindings hold those bindings' values: a chain of
// closures each capturing the last, a record naming the last one twice, and the
// same record handed to code that may run what it holds. Inference stays inside
// a bound on its reductions however long the chain.

const work_bound = 20_000_000

@external(erlang, "scope_test_ffi", "reductions")
fn reductions() -> Int

// `[first, first + 1, …, until - 1]`.
fn from(first: Int, until: Int) -> List(Int) {
  case first >= until {
    True -> []
    False -> [first, ..from(first + 1, until)]
  }
}

fn closure_chain(length: Int) -> String {
  let links =
    from(1, length)
    |> list.map(fn(i) {
      "  let b"
      <> int.to_string(i)
      <> " = Box(fn() { let _ = b"
      <> int.to_string(i - 1)
      <> " Nil })\n"
    })
  let all =
    from(0, length)
    |> list.map(fn(i) { "b" <> int.to_string(i) })
    |> string.join(", ")
  "pub type Box {\n  Box(run: fn() -> Nil)\n}\n\npub fn main() -> Nil {\n"
  <> "  let b0 = Box(fn() { Nil })\n"
  <> string.concat(links)
  <> "  let _ = #("
  <> all
  <> ")\n  Nil\n}\n"
}

fn doubling(length: Int, last: String) -> String {
  let levels =
    from(1, length)
    |> list.map(fn(i) {
      "  let b"
      <> int.to_string(i)
      <> " = Node(b"
      <> int.to_string(i - 1)
      <> ", b"
      <> int.to_string(i - 1)
      <> ")\n"
    })
  "pub type Tree {\n  Leaf(run: fn() -> Nil)\n  Node(left: Tree, right: Tree)\n}\n\n"
  <> "pub fn main(sink: fn(Tree) -> Nil) -> Nil {\n"
  <> "  let b0 = Leaf(fn() { Nil })\n"
  <> string.concat(levels)
  <> "  "
  <> string.replace(last, "LAST", "b" <> int.to_string(length - 1))
  <> "\n}\n"
}

fn measured_inference(
  directory: String,
  source: String,
) -> #(List(String), Int) {
  let directory =
    support.write_fixture(directory, [
      #("gleam.toml", "name = \"probe\"\n"),
      #("probe.graded", ""),
      #("src/probe.gleam", source),
    ])
  let before = reductions()
  let assert Ok(lines) = graded.inferred_lines(directory)
  let spent = reductions() - before
  support.cleanup(directory)
  #(lines, spent)
}

pub fn shared_values_are_read_once_per_site_test() {
  let #(chain, chain_spent) =
    measured_inference("/tmp/graded_scope_chain", closure_chain(64))
  chain |> should.equal(["effects probe.main : []"])
  { chain_spent <= work_bound } |> should.be_true()

  let #(built, built_spent) =
    measured_inference(
      "/tmp/graded_scope_doubling",
      doubling(40, "let _ = LAST"),
    )
  built |> should.equal(["effects probe.main : []"])
  { built_spent <= work_bound } |> should.be_true()

  let #(passed, passed_spent) =
    measured_inference("/tmp/graded_scope_passed", doubling(40, "sink(LAST)"))
  passed
  |> should.equal(["effects probe.main(sink: [sink]) : [Unknown, sink]"])
  { passed_spent <= work_bound } |> should.be_true()
}

// A value naming the last one directly and inside separately written wrappers
// is reached through paths of unequal shape; each walk over values reads each
// written site of it once, or stops at a bound, however many paths reach it.
// The shapes: constructors, factories, a helper the value is handed to, closures
// capturing the last value, a choice of closures over it, and a record holding
// it read in another module.

const sink_source =
  "@external(erlang, \"m\", \"sink\")
@external(javascript, \"m\", \"sink\")
pub fn sink(x: a) -> Nil

@external(erlang, \"m\", \"calm\")
@external(javascript, \"m\", \"calm\")
pub fn calm() -> Nil
"

const sink_spec =
  "assume probe/ffi.sink : []
assume probe/ffi.calm : []
"

const tree_type =
  "pub type Tree {
  Leaf(run: fn() -> Nil)
  Node(one: Tree, two: Tree, three: Tree, four: Tree)
  Wrap(inner: Tree)
}
"

// `b0` a leaf, then each `b<i>` built by `level` from `b<i - 1>`.
fn fan_levels(length: Int, level: fn(String) -> String) -> String {
  "  let b0 = Leaf(fn() { Nil })\n"
  <> string.concat(
    list.map(from(1, length), fn(i) {
      "  let b"
      <> int.to_string(i)
      <> " = "
      <> level("b" <> int.to_string(i - 1))
      <> "\n"
    }),
  )
}

fn fan(node: String, wrap: String) -> fn(String) -> String {
  fn(previous) {
    node
    <> "("
    <> previous
    <> ", "
    <> wrap
    <> "("
    <> previous
    <> "), "
    <> wrap
    <> "("
    <> previous
    <> "), "
    <> wrap
    <> "("
    <> previous
    <> "))"
  }
}

fn measured_fan(
  directory: String,
  files: List(#(String, String)),
) -> #(List(String), Int) {
  let directory = support.write_fixture(directory, files)
  let before = reductions()
  let assert Ok(lines) = graded.inferred_lines(directory)
  let spent = reductions() - before
  support.cleanup(directory)
  #(list.filter(lines, string.starts_with(_, "effects probe.main")), spent)
}

fn fan_project(main: String) -> List(#(String, String)) {
  [
    #("gleam.toml", "name = \"probe\"\n"),
    #("probe.graded", sink_spec),
    #("src/probe/ffi.gleam", sink_source),
    #("src/probe.gleam", "import probe/ffi\n\n" <> tree_type <> "\n" <> main),
  ]
}

pub fn every_walk_over_values_reads_each_site_once_test() {
  let length = 16
  let last = "b" <> int.to_string(length - 1)
  let shapes = [
    #(
      "constructors",
      "pub fn main() -> Nil {\n"
        <> fan_levels(length, fan("Node", "Wrap"))
        <> "  ffi.sink("
        <> last
        <> ")\n}\n",
    ),
    #(
      "factories",
      "fn node(a: Tree, b: Tree, c: Tree, d: Tree) -> Tree {\n  Node(a, b, c, d)\n}\n\nfn wrap(x: Tree) -> Tree {\n  Wrap(x)\n}\n\npub fn main() -> Nil {\n"
        <> fan_levels(length, fan("node", "wrap"))
        <> "  ffi.sink("
        <> last
        <> ")\n}\n",
    ),
    #(
      "a helper it is handed to",
      "fn helper(t: Tree) -> Nil {\n  ffi.sink(t)\n}\n\npub fn main() -> Nil {\n"
        <> fan_levels(length, fan("Node", "Wrap"))
        <> "  helper("
        <> last
        <> ")\n}\n",
    ),
    #(
      "closures capturing it",
      "pub fn main() -> Nil {\n"
        <> fan_levels(length, fn(previous) {
        "Node("
        <> previous
        <> ", Leaf(fn() { ffi.sink("
        <> previous
        <> ") }), Wrap("
        <> previous
        <> "), Leaf(fn() { let _ = "
        <> previous
        <> " Nil }))"
      })
        <> "  ffi.sink("
        <> last
        <> ")\n}\n",
    ),
    #(
      "a choice of closures over it",
      "fn apply(f: fn() -> Nil) -> Nil {\n  f()\n}\n\npub fn main(x: Int) -> Nil {\n  let c0 = ffi.calm\n"
        <> string.concat(
        list.map(from(1, length), fn(i) {
          let previous = "c" <> int.to_string(i - 1)
          "  let c"
          <> int.to_string(i)
          <> " = case x {\n    0 -> "
          <> previous
          <> "\n    1 -> fn() { "
          <> previous
          <> "() }\n    _ -> fn() {\n      "
          <> previous
          <> "()\n      "
          <> previous
          <> "()\n    }\n  }\n"
        }),
      )
        <> "  apply(c"
        <> int.to_string(length - 1)
        <> ")\n}\n",
    ),
  ]
  list.each(shapes, fn(shape) {
    let #(name, main) = shape
    let #(lines, spent) =
      measured_fan("/tmp/graded_scope_fan", fan_project(main))
    #(name, lines) |> should.equal(#(name, ["effects probe.main : [Unknown]"]))
    #(name, spent <= work_bound) |> should.equal(#(name, True))
  })
  // The same value, returned in a record another module reads.
  let #(lines, spent) =
    measured_fan("/tmp/graded_scope_fan_across", [
      #("gleam.toml", "name = \"probe\"\n"),
      #("probe.graded", sink_spec),
      #("src/probe/ffi.gleam", sink_source),
      #(
        "src/probe/tree.gleam",
        tree_type
          <> "\npub type Box {\n  Box(tree: Tree)\n}\n\npub fn make() -> Box {\n"
          <> fan_levels(length, fan("Node", "Wrap"))
          <> "  Box(tree: "
          <> last
          <> ")\n}\n",
      ),
      #(
        "src/probe.gleam",
        "import probe/ffi\nimport probe/tree\n\npub fn main() -> Nil {\n  let box = tree.make()\n  ffi.sink(box.tree)\n}\n",
      ),
    ])
  lines |> should.equal(["effects probe.main : [Unknown]"])
  { spent <= work_bound } |> should.be_true()
}

// A producer's summary read in another module of the package: a record holding
// a field of the producer's parameter, where the consumer's function of the
// same parameter name starts at the same offset, and one offset later; a
// record holding the producer's private function, where the consumer has a
// pure one of the same name, and where it has none.

const model_source =
  "pub type Task {
  Task(run: fn() -> Nil)
}

pub type Box {
  Box(task: Task)
}

pub fn invoke(b: Box) -> Nil {
  let task = b.task
  task.run()
}
"

// `prefix`, a comment line, then `tail` starting at byte `offset`.
fn padded(prefix: String, tail: String, offset: Int) -> String {
  prefix
  <> "//"
  <> string.repeat(" ", offset - string.byte_size(prefix) - 3)
  <> "\n"
  <> tail
}

fn boundary_answers(
  directory: String,
  producer: String,
  probe: String,
) -> List(String) {
  let directory =
    support.write_fixture(directory, [
      #("gleam.toml", "name = \"probe\"\n"),
      #("probe.graded", ""),
      #("src/model.gleam", model_source),
      #("src/producer.gleam", producer),
      #("src/probe.gleam", probe),
    ])
  let assert Ok(lines) = graded.inferred_lines(directory)
  support.cleanup(directory)
  list.filter(lines, string.starts_with(_, "effects probe."))
}

pub fn a_summary_names_nothing_of_the_module_reading_it_test() {
  let stored =
    "pub fn make(f: model.Task) -> model.Box {\n  model.Box(task: model.Task(run: f.run))\n}\n"
  let consumer =
    padded(
      "import gleam/io\nimport model\nimport producer\n\nfn loud() -> Nil {\n  io.println(\"PRINTED\")\n}\n",
      "pub fn go(f: model.Task) -> Nil {\n  let _ = f\n  model.invoke(producer.make(model.Task(run: loud)))\n}\n\npub fn main() -> Nil {\n  go(model.Task(run: fn() { Nil }))\n}\n",
      200,
    )
  // The caller hands the producer the printing task, and its own `f`, at the
  // same offset, a pure one.
  boundary_answers(
    "/tmp/graded_scope_aligned",
    padded("import model\n", stored, 200),
    consumer,
  )
  |> should.equal([
    "effects probe.go : [Unknown]",
    "effects probe.main : [Unknown]",
  ])
  boundary_answers(
    "/tmp/graded_scope_shifted",
    padded("import model\n", stored, 201),
    consumer,
  )
  |> should.equal([
    "effects probe.go : [Unknown]",
    "effects probe.main : [Unknown]",
  ])
  let named =
    "import gleam/io\nimport model\n\nfn loud() -> Nil {\n  io.println(\"PRINTED\")\n}\n\npub fn make() -> model.Box {\n  model.Box(task: model.Task(run: loud))\n}\n"
  boundary_answers(
    "/tmp/graded_scope_named",
    named,
    "import model\nimport producer\n\nfn loud() -> Nil {\n  Nil\n}\n\npub fn main() -> Nil {\n  let _ = loud\n  model.invoke(producer.make())\n}\n",
  )
  |> should.equal(["effects probe.main : [Unknown]"])
  boundary_answers(
    "/tmp/graded_scope_absent",
    named,
    "import model\nimport producer\n\npub fn main() -> Nil {\n  model.invoke(producer.make())\n}\n",
  )
  |> should.equal(["effects probe.main : [Unknown]"])
}

// A record update's shorthand field has no span of its own. Two such fields
// are two values, each read: the runner calls the printing `b`.
const update_source =
  "import probe/ffi

pub type Duo {
  Duo(a: Int, b: fn(String) -> Nil, tag: Int)
}

pub fn main() -> Nil {
  let a = 1
  let b = ffi.shout
  let value = Duo(a: 0, b: ffi.calm, tag: 0)
  ffi.run(Duo(..value, FIELDS))
}
"

fn update_answer(fields: String) -> List(String) {
  let directory =
    support.write_fixture("/tmp/graded_scope_update", [
      #("gleam.toml", "name = \"probe\"\n"),
      #(
        "probe.graded",
        "assume probe/ffi.calm : []\nassume probe/ffi.run : []\nassume probe/ffi.shout : [Stdout]\n",
      ),
      #(
        "src/probe/ffi.gleam",
        "@external(erlang, \"m\", \"calm\")\npub fn calm(s: String) -> Nil\n\n@external(erlang, \"m\", \"shout\")\npub fn shout(s: String) -> Nil\n\n@external(erlang, \"m\", \"run\")\npub fn run(x: a) -> Nil\n",
      ),
      #("src/probe.gleam", string.replace(update_source, "FIELDS", fields)),
    ])
  let assert Ok(lines) = graded.inferred_lines(directory)
  support.cleanup(directory)
  list.filter(lines, string.starts_with(_, "effects probe.main"))
}

pub fn shorthand_update_fields_are_each_read_test() {
  update_answer("a:, b:")
  |> should.equal(["effects probe.main : [Stdout, Unknown]"])
  update_answer("b:, a:")
  |> should.equal(["effects probe.main : [Stdout, Unknown]"])
  update_answer("a: a, b: b")
  |> should.equal(["effects probe.main : [Stdout]"])
}

// Choices nested in choices, each level holding the last directly and inside
// three other choices: four functions, however many paths reach them.
fn nested_choices(length: Int) -> String {
  "import probe/ffi\n\npub fn choose(x: Int) -> Nil {\n  let f0 = ffi.calm0\n"
  <> string.concat(
    list.map(from(1, length), fn(i) {
      let f = "f" <> int.to_string(i - 1)
      "  let f"
      <> int.to_string(i)
      <> " = case x {\n    0 -> "
      <> f
      <> "\n    1 -> case x {\n      0 -> "
      <> f
      <> "\n      _ -> ffi.calm1\n    }\n    2 -> case x {\n      0 -> "
      <> f
      <> "\n      _ -> ffi.calm2\n    }\n    _ -> case x {\n      0 -> "
      <> f
      <> "\n      _ -> ffi.calm3\n    }\n  }\n"
    }),
  )
  <> "  f"
  <> int.to_string(length - 1)
  <> "()\n}\n\npub fn main() -> Nil {\n  choose(0)\n}\n"
}

pub fn nested_choices_are_listed_once_per_alternative_test() {
  let calms =
    string.concat(
      list.map(from(0, 4), fn(i) {
        "@external(erlang, \"m\", \"calm"
        <> int.to_string(i)
        <> "\")\npub fn calm"
        <> int.to_string(i)
        <> "() -> Nil\n\n"
      }),
    )
  let #(lines, spent) =
    measured_fan("/tmp/graded_scope_choices", [
      #("gleam.toml", "name = \"probe\"\n"),
      #(
        "probe.graded",
        string.concat(
          list.map(from(0, 4), fn(i) {
            "assume probe/ffi.calm" <> int.to_string(i) <> " : []\n"
          }),
        ),
      ),
      #("src/probe/ffi.gleam", calms),
      #("src/probe.gleam", nested_choices(16)),
    ])
  lines |> should.equal(["effects probe.main : []"])
  { spent <= work_bound } |> should.be_true()
}

// Forty-one closures, each written apart, each capturing the last level of a
// shared fan, chosen between and then both called and handed on: each
// alternative is listed and called once, whatever the fan its captures hold.
fn closures_over_a_fan(length: Int) -> String {
  let last = "b" <> int.to_string(length - 1)
  let arm = fn(pattern) {
    "    " <> pattern <> " -> fn() { ffi.sink(" <> last <> ") }\n"
  }
  "pub fn main() -> Nil {\n"
  <> fan_levels(length, fan("Node", "Wrap"))
  <> "  let f = case 0 {\n"
  <> string.concat(list.map(from(0, 40), fn(i) { arm(int.to_string(i)) }))
  <> arm("_")
  <> "  }\n  f()\n  ffi.sink(f)\n}\n"
}

pub fn a_choice_of_closures_over_a_shared_fan_is_read_once_per_alternative_test() {
  list.each([6, 8], fn(length) {
    let #(lines, spent) =
      measured_fan(
        "/tmp/graded_scope_closure_choice",
        fan_project(closures_over_a_fan(length)),
      )
    #(length, lines) |> should.equal(#(length, ["effects probe.main : []"]))
    #(length, spent <= work_bound) |> should.equal(#(length, True))
  })
}

// A function defined once per target beside seventeen functions that all call
// each other and it: read on both targets, inference stays inside a bound on
// its reductions.
fn dense_cycle_beside_a_pair(size: Int) -> String {
  let arms = fn(calls) {
    "  case n {\n    0 -> Nil\n    _ -> {\n"
    <> string.concat(list.map(calls, fn(call) { "      " <> call <> "\n" }))
    <> "      Nil\n    }\n  }\n"
  }
  let g = fn(i) { "g" <> int.to_string(i) <> "(n - 1)" }
  "fn quiet() -> Nil {\n  Nil\n}\n\n@target(erlang)\nfn f0(n: Int, _cb: fn() -> Nil) -> Nil {\n"
  <> arms(list.map(from(1, size), g))
  <> "}\n\n@target(javascript)\nfn f0(n: Int, cb: fn() -> Nil) -> Nil {\n  case n {\n    0 -> Nil\n    _ -> cb()\n  }\n}\n\n"
  <> string.concat(
    list.map(from(1, size), fn(i) {
      "fn g"
      <> int.to_string(i)
      <> "(n: Int) -> Nil {\n"
      <> arms([
        "f0(n - 1, quiet)",
        ..list.filter_map(from(1, size), fn(j) {
          case j == i {
            True -> Error(Nil)
            False -> Ok(g(j))
          }
        })
      ])
      <> "}\n\n"
    }),
  )
  <> "pub fn main() -> Nil {\n  f0(0, quiet)\n}\n"
}

pub fn a_dense_cycle_beside_a_pair_is_read_on_both_targets_within_a_bound_test() {
  let #(lines, spent) =
    measured_fan("/tmp/graded_scope_dense_pair", [
      #("gleam.toml", support.dual_target_toml("probe")),
      #("probe.graded", ""),
      #("src/probe.gleam", dense_cycle_beside_a_pair(18)),
    ])
  lines |> should.equal(["effects probe.main : []"])
  { spent <= work_bound } |> should.be_true()
}

// One closure capturing a long tuple, named by 1,001 branches: one value,
// however long its written key runs.
fn repeated_large_closure(elements: Int, branches: Int) -> String {
  let zeros = string.join(list.map(from(0, elements), fn(_) { "0" }), ", ")
  "pub fn main() -> Nil {\n  let r = #("
  <> zeros
  <> ")\n  let f = fn() {\n    let _ = r\n    Nil\n  }\n  let h = case 0 {\n"
  <> string.concat(
    list.map(from(0, branches - 1), fn(i) {
      "    " <> int.to_string(i) <> " -> f\n"
    }),
  )
  <> "    _ -> f\n  }\n  h()\n}\n"
}

pub fn a_branch_naming_a_binding_again_is_not_another_alternative_test() {
  list.each([#(8, 1002), #(100, 1000), #(100, 1001)], fn(shape) {
    let #(elements, branches) = shape
    let directory =
      support.write_fixture("/tmp/graded_scope_repeated_closure", [
        #("gleam.toml", "name = \"probe\"\n"),
        #("probe.graded", ""),
        #("src/probe.gleam", repeated_large_closure(elements, branches)),
      ])
    let assert Ok(lines) = graded.inferred_lines(directory)
    support.cleanup(directory)
    #(shape, list.filter(lines, string.starts_with(_, "effects probe.main")))
    |> should.equal(#(shape, ["effects probe.main : []"]))
  })
}

// A choice keeps its first thousand distinct alternatives; one already kept,
// however often a branch names it again, is not one more. Each source holds
// `distinct` pure functions, each named by one branch (the last by the
// wildcard), and one more branch for each function `repeats` names again.
fn many_choices(distinct: Int, repeats: List(Int)) -> String {
  let functions =
    list.map(from(0, distinct), fn(i) {
      "fn q" <> int.to_string(i) <> "() -> Nil {\n  Nil\n}\n"
    })
  let branches =
    list.map(from(0, distinct - 1), fn(i) {
      "    " <> int.to_string(i) <> " -> q" <> int.to_string(i) <> "\n"
    })
  let extra =
    list.index_map(repeats, fn(target, index) {
      "    "
      <> int.to_string(distinct + index)
      <> " -> q"
      <> int.to_string(target)
      <> "\n"
    })
  string.join(functions, "\n")
  <> "\npub fn choose(x: Int) -> Nil {\n  let f = case x {\n"
  <> string.concat(branches)
  <> string.concat(extra)
  <> "    _ -> q"
  <> int.to_string(distinct - 1)
  <> "\n  }\n  f()\n}\n\npub fn main() -> Nil {\n  choose(0)\n}\n"
}

fn choice_answer(distinct: Int, repeats: List(Int)) -> List(String) {
  let directory =
    support.write_fixture("/tmp/graded_scope_choice_budget", [
      #("gleam.toml", "name = \"probe\"\n"),
      #("probe.graded", ""),
      #("src/probe.gleam", many_choices(distinct, repeats)),
    ])
  let assert Ok(lines) = graded.inferred_lines(directory)
  support.cleanup(directory)
  list.filter(lines, string.starts_with(_, "effects probe.main"))
}

pub fn a_choice_widens_only_past_a_thousand_distinct_alternatives_test() {
  choice_answer(999, [0]) |> should.equal(["effects probe.main : []"])
  choice_answer(1000, []) |> should.equal(["effects probe.main : []"])
  choice_answer(1000, [0, 999, 500])
  |> should.equal(["effects probe.main : []"])
  choice_answer(1001, []) |> should.equal(["effects probe.main : [Unknown]"])
}
