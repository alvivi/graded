// A value built from earlier values, read where it is consumed. Each row is a
// construct that builds a value from an earlier one; each column a place a
// value is consumed. A cell builds sixteen levels, each holding the previous
// value directly and inside three differently written wrappers of its row's
// construct, from a value that holds a printing function. Building it runs
// nothing, so the same cell without its consumer reads `[]`. With it,
// inference runs inside a bound on its reductions and the answer is never
// `[]`; where
// the consumer runs a value its row can trace, the answer holds the printer's
// `Stdout`. Every cell, with its consumer and without, is a program the
// compiler accepts.
//
//   gleam run -m fan_matrix_test -- [DIR]
//
// writes every cell as a project under DIR (default `build/fan_matrix`), to
// measure it from outside.

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

const levels = 16

const work_bound = 10_000_000

@external(erlang, "scope_test_ffi", "reductions")
fn reductions() -> Int

const ffi_source =
  "@external(erlang, \"m\", \"shout\")
@external(javascript, \"m\", \"shout\")
pub fn shout() -> Nil

@external(erlang, \"m\", \"sink\")
@external(javascript, \"m\", \"sink\")
pub fn sink(x: a) -> Nil

@external(erlang, \"m\", \"mark\")
@external(javascript, \"m\", \"mark\")
pub fn mark(x: a) -> Nil

@external(erlang, \"m\", \"each\")
@external(javascript, \"m\", \"each\")
pub fn each(list: List(a), f: fn(a) -> Nil) -> Nil
"

const spec =
  "assume probe/ffi.shout : [Stdout]
assume probe/ffi.sink : []
assume probe/ffi.mark(x: [x]) : [Mark] where runs : [x]
assume probe/ffi.each(list: [l], f: [f]) : [f] where runs : [], relay : f(l)
"

const model_source =
  "import probe/ffi

pub type Tree {
  Leaf(run: fn() -> Nil)
  Node(one: Tree, two: Tree, three: Tree, four: Tree)
  Wrap(inner: Tree)
  Pair(inner: #(Tree, Tree))
  Many(inner: List(Tree))
  Hook(run: fn(Int) -> Nil)
  Later(make: fn() -> Tree)
}

pub type Rec {
  Rec(run: fn() -> Nil, one: List(Rec), two: List(Rec), three: List(Rec))
}

pub type Feeder(a) {
  Feeder(run: fn(a) -> Nil)
}

pub fn loud() -> Nil {
  ffi.shout()
}

pub fn quiet() -> Nil {
  Nil
}

pub fn touch(t: Tree, _n: Int) -> Nil {
  ffi.sink(t)
}

pub fn touch_after(_n: Int, t: Tree) -> Nil {
  ffi.sink(t)
}

pub fn touch_between(t: Tree, _m: Int, _n: Int) -> Nil {
  ffi.sink(t)
}

pub fn with_unit(next: fn(Nil) -> Tree) -> Tree {
  next(Nil)
}

pub fn with_count(next: fn(Int) -> Tree) -> Tree {
  next(1)
}

pub fn node(a: Tree, b: Tree, c: Tree, d: Tree) -> Tree {
  Node(a, b, c, d)
}

pub fn wrap(t: Tree) -> Tree {
  Wrap(t)
}

pub fn wrap_pair(t: Tree) -> Tree {
  Pair(#(t, t))
}
"

// A row: the construct's name, the type of the value it builds, the value the
// fan starts from, one level built from the previous value `p`, and whether
// the value it builds is one a consumer that runs it reads to its printer.
type Row {
  Row(
    name: String,
    type_: String,
    base: String,
    level: fn(String) -> String,
    readable: Bool,
  )
}

// A column: the consumer's name, whether it runs the value itself (so a
// readable value reaches its printer there), the labels only its own consumer
// can add, and how it consumes the value.
type Column {
  Column(
    name: String,
    runs: Bool,
    own: List(String),
    consume: fn(Row) -> Consumer,
  )
}

// What a consumer writes: the statements of `main`, and whether the fan is
// returned by a function `make` of this module or of another one.
type Consumer {
  InPlace(statements: fn(String) -> String)
  Returned(module: Placement, statements: String)
}

type Placement {
  HereModule
  OtherModule
}

const tree_base = "model.Leaf(model.loud)"

const rec_base = "model.Rec(run: model.loud, one: [], two: [], three: [])"

fn rows() -> List(Row) {
  [
    Row(
      "record constructor",
      "model.Tree",
      tree_base,
      readable: True,
      level: fn(p) {
        "model.Node("
        <> p
        <> ", model.Wrap("
        <> p
        <> "), model.Wrap(inner: "
        <> p
        <> "), model.Wrap(model.Wrap("
        <> p
        <> ")))"
      },
    ),
    Row("tuple", "model.Tree", tree_base, readable: True, level: fn(p) {
      "model.Node("
      <> p
      <> ", model.Pair(#("
      <> p
      <> ", "
      <> p
      <> ")), model.Pair(#("
      <> p
      <> ", model.Wrap("
      <> p
      <> "))), model.Pair(#(model.Wrap("
      <> p
      <> "), "
      <> p
      <> ")))"
    }),
    Row("list", "model.Tree", tree_base, readable: True, level: fn(p) {
      "model.Node("
      <> p
      <> ", model.Many(["
      <> p
      <> "]), model.Many(["
      <> p
      <> ", "
      <> p
      <> "]), model.Many([model.Wrap("
      <> p
      <> "), .."
      <> "["
      <> p
      <> "]]))"
    }),
    Row(
      "nested case choice",
      "fn() -> Nil",
      "model.loud",
      readable: True,
      level: fn(p) {
        "case x {\n    0 -> "
        <> p
        <> "\n    1 -> case x {\n      0 -> "
        <> p
        <> "\n      _ -> model.quiet\n    }\n    2 -> case x {\n      1 -> model.quiet\n      _ -> "
        <> p
        <> "\n    }\n    _ -> case x {\n      2 -> case x {\n        _ -> "
        <> p
        <> "\n      }\n      _ -> model.quiet\n    }\n  }"
      },
    ),
    Row("block", "model.Tree", tree_base, readable: True, level: fn(p) {
      "model.Node("
      <> p
      <> ", { "
      <> p
      <> " }, {\n    let q = "
      <> p
      <> "\n    q\n  }, { model.Wrap("
      <> p
      <> ") })"
    }),
    Row(
      "closure capturing it",
      "model.Tree",
      tree_base,
      readable: True,
      level: fn(p) {
        "model.Node("
        <> p
        <> ", model.Leaf(fn() {\n    let _ = "
        <> p
        <> "\n    Nil\n  }), model.Later(fn() { "
        <> p
        <> " }), model.Later(fn() { model.Wrap("
        <> p
        <> ") }))"
      },
    ),
    Row(
      "function capture",
      "model.Tree",
      tree_base,
      readable: True,
      level: fn(p) {
        "model.Node("
        <> p
        <> ", model.Hook(model.touch("
        <> p
        <> ", _)), model.Hook(model.touch_after(_, "
        <> p
        <> ")), model.Hook(model.touch_between("
        <> p
        <> ", 1, _)))"
      },
    ),
    Row(
      "record update, labelled",
      "model.Rec",
      rec_base,
      readable: True,
      level: fn(p) {
        "model.Rec(.."
        <> p
        <> ", one: ["
        <> p
        <> "], two: [model.Rec(.."
        <> p
        <> ", one: ["
        <> p
        <> "])], three: [model.Rec(.."
        <> p
        <> ", two: ["
        <> p
        <> ", "
        <> p
        <> "])])"
      },
    ),
    Row(
      "record update, shorthand",
      "model.Rec",
      rec_base,
      readable: True,
      level: fn(p) {
        "{\n    let one = ["
        <> p
        <> "]\n    let two = [model.Rec(.."
        <> p
        <> ", one:)]\n    let three = ["
        <> p
        <> ", "
        <> p
        <> "]\n    model.Rec(.."
        <> p
        <> ", one:, two:, three:)\n  }"
      },
    ),
    Row("let alias", "model.Tree", tree_base, readable: True, level: fn(p) {
      "{\n    let a = "
      <> p
      <> "\n    let b = a\n    let c = model.Wrap(b)\n    model.Node(a, b, c, model.Wrap(a))\n  }"
    }),
    Row("use callback", "model.Tree", tree_base, readable: True, level: fn(p) {
      "model.Node("
      <> p
      <> ", {\n    use _ <- model.with_unit()\n    "
      <> p
      <> "\n  }, {\n    use _ <- model.with_unit()\n    model.Wrap("
      <> p
      <> ")\n  }, {\n    use n <- model.with_count()\n    let _ = n\n    model.Wrap(inner: "
      <> p
      <> ")\n  })"
    }),
    Row("factory call", "model.Tree", tree_base, readable: True, level: fn(p) {
      "model.node("
      <> p
      <> ", model.wrap("
      <> p
      <> "), model.wrap_pair("
      <> p
      <> "), model.wrap(model.wrap("
      <> p
      <> ")))"
    }),
  ]
}

// How a returned value is consumed: run where it is a function, handed to a
// boundless foreign function otherwise.
fn consume_returned(row: Row, call: String) -> String {
  case row.type_ {
    "fn() -> Nil" -> "  " <> call <> "()\n"
    _ -> "  ffi.sink(" <> call <> ")\n"
  }
}

// The field column reaches the value only by dispatching the field: the record
// holds a foreign function that marks and runs what it is handed, and building
// the record runs nothing. Only a field call resolved to that function adds
// `Mark`; one left unresolved still runs its argument, but marks nothing.
fn columns() -> List(Column) {
  [
    Column("callback runner", runs: True, own: [], consume: fn(_row) {
      InPlace(fn(value) {
        "  ffi.each([" <> value <> "], fn(t) { ffi.sink(t) })\n"
      })
    }),
    Column("field call", runs: True, own: ["Mark"], consume: fn(_row) {
      InPlace(fn(value) {
        "  let h = model.Feeder(run: ffi.mark)\n  h.run(" <> value <> ")\n"
      })
    }),
    Column("boundless foreign argument", runs: True, own: [], consume: fn(_row) {
      InPlace(fn(value) { "  ffi.sink(" <> value <> ")\n" })
    }),
    Column("returned value", runs: False, own: [], consume: fn(row) {
      Returned(HereModule, consume_returned(row, "make(x)"))
    }),
    Column("read in another module", runs: False, own: [], consume: fn(row) {
      Returned(OtherModule, consume_returned(row, "build.make(x)"))
    }),
  ]
}

// The same cell with its consumer left out: the value is built and dropped.
fn without_consumer(consumer: Consumer) -> Consumer {
  case consumer {
    InPlace(_) -> InPlace(fn(value) { "  let _ = " <> value <> "\n  Nil\n" })
    Returned(HereModule, _) ->
      Returned(HereModule, "  let _ = make(x)\n  Nil\n")
    Returned(OtherModule, _) ->
      Returned(OtherModule, "  let _ = build.make(x)\n  Nil\n")
  }
}

// `let b0 = …` through `let b15 = …`, indented for a function body.
fn fan_lets(row: Row) -> String {
  "  let b0 = "
  <> row.base
  <> "\n"
  <> string.concat(
    list.map(
      int.range(from: 1, to: levels, with: [], run: list.prepend)
        |> list.reverse,
      fn(i) {
        "  let b"
        <> int.to_string(i)
        <> " = "
        <> row.level("b" <> int.to_string(i - 1))
        <> "\n"
      },
    ),
  )
}

const last = "b15"

// One cell's project files, `consumer` consuming the fan.
fn cell_files(row: Row, consumer: Consumer) -> List(#(String, String)) {
  let imports = "import probe/ffi\nimport probe/model\n"
  let make =
    "pub fn make(x: Int) -> "
    <> row.type_
    <> " {\n  let _ = x\n"
    <> fan_lets(row)
    <> "  "
    <> last
    <> "\n}\n"
  let #(probe, extra) = case consumer {
    InPlace(statements) -> #(
      imports
        <> "\npub fn main(x: Int) -> Nil {\n  let _ = x\n"
        <> fan_lets(row)
        <> statements(last)
        <> "}\n",
      [],
    )
    Returned(HereModule, statements) -> #(
      imports
        <> "\n"
        <> make
        <> "\npub fn main(x: Int) -> Nil {\n"
        <> statements
        <> "}\n",
      [],
    )
    Returned(OtherModule, statements) -> #(
      imports
        <> "import probe/build\n\npub fn main(x: Int) -> Nil {\n"
        <> statements
        <> "}\n",
      [#("src/probe/build.gleam", imports <> "\n" <> make)],
    )
  }
  [
    #("gleam.toml", "name = \"probe\"\n"),
    #("probe.graded", spec),
    #("src/probe/ffi.gleam", ffi_source),
    #("src/probe/model.gleam", model_source),
    #("src/probe.gleam", probe),
    ..extra
  ]
}

fn slug(text: String) -> String {
  text
  |> string.replace(" ", "_")
  |> string.replace(",", "")
}

// Every cell of `column`: inference finishes inside the bound and `main` is not
// pure, while the same cell without its consumer is; the answer holds the
// labels only the column's consumer adds, and, where the column runs a
// readable value, its printer's `Stdout`.
fn check_column(name: String) -> Nil {
  let assert Ok(column) = list.find(columns(), fn(c) { c.name == name })
  list.each(rows(), fn(row) {
    let cell = row.name <> " / " <> column.name
    let consumer = column.consume(row)
    let #(answer, spent) = main_answer(row, consumer)
    let #(dropped, _) = main_answer(row, without_consumer(consumer))
    #(cell, dropped) |> should.equal(#(cell, Ok("effects probe.main : []")))
    #(cell, answer == Ok("effects probe.main : []"))
    |> should.equal(#(cell, False))
    #(cell, result.is_ok(answer)) |> should.equal(#(cell, True))
    #(cell, spent <= work_bound) |> should.equal(#(cell, True))
    let expected = case column.runs && row.readable {
      True -> ["Stdout", ..column.own]
      False -> column.own
    }
    list.each(expected, fn(label) {
      #(cell, label, string.contains(result.unwrap(answer, ""), label))
      |> should.equal(#(cell, label, True))
    })
  })
}

// `main`'s inferred line for a cell, and how long inference took.
fn main_answer(row: Row, consumer: Consumer) -> #(Result(String, Nil), Int) {
  let directory =
    support.write_fixture(
      "/tmp/graded_fan_matrix_" <> slug(row.name),
      cell_files(row, consumer),
    )
  let before = reductions()
  let assert Ok(lines) = graded.inferred_lines(directory)
  let spent = reductions() - before
  support.cleanup(directory)
  #(list.find(lines, string.starts_with(_, "effects probe.main")), spent)
}

pub fn callback_runner_test() {
  check_column("callback runner")
}

pub fn field_call_test() {
  check_column("field call")
}

pub fn boundless_foreign_argument_test() {
  check_column("boundless foreign argument")
}

pub fn returned_value_test() {
  check_column("returned value")
}

pub fn read_in_another_module_test() {
  check_column("read in another module")
}

// Every cell and every cell without its consumer, as modules of one project
// the compiler checks: each is a program it accepts.
pub fn every_cell_and_its_twin_compiles_test() {
  let directory = absolute("build/fan_matrix_check")
  let _ = simplifile.delete(directory)
  let programs =
    list.index_map(rows(), fn(row, i) {
      list.index_map(columns(), fn(column, j) {
        let consumer = column.consume(row)
        let name = "cell_" <> int.to_string(i) <> "_" <> int.to_string(j)
        list.append(
          program_modules(name, cell_files(row, consumer)),
          program_modules(
            name <> "_twin",
            cell_files(row, without_consumer(consumer)),
          ),
        )
      })
    })
    |> list.flatten
    |> list.flatten
  write_files(directory, [
    #("gleam.toml", "name = \"probe\"\n"),
    #("src/probe/ffi.gleam", ffi_source),
    #("src/probe/model.gleam", model_source),
    ..programs
  ])
  let checked =
    shellout.command(run: "gleam", with: ["check"], in: directory, opt: [])
    |> result.map_error(fn(failure) { failure.1 })
  let _ = simplifile.delete(directory)
  checked |> result.map(fn(_) { Nil }) |> should.equal(Ok(Nil))
}

// One cell's own modules under `name`: its `probe` module, and the module
// `make` comes from when it is another one.
fn program_modules(
  name: String,
  files: List(#(String, String)),
) -> List(#(String, String)) {
  list.filter_map(files, fn(file) {
    case file.0 {
      "src/probe.gleam" ->
        Ok(#(
          "src/probe/" <> name <> ".gleam",
          string.replace(
            file.1,
            "import probe/build\n",
            "import probe/" <> name <> "_build as build\n",
          ),
        ))
      "src/probe/build.gleam" ->
        Ok(#("src/probe/" <> name <> "_build.gleam", file.1))
      _ -> Error(Nil)
    }
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

// Write every cell under the directory given, one project each.
pub fn main() -> Nil {
  let root = case argv.load().arguments {
    [directory, ..] -> directory
    [] -> "build/fan_matrix"
  }
  list.each(rows(), fn(row) {
    list.each(columns(), fn(column) {
      let directory = root <> "/" <> slug(row.name) <> "__" <> slug(column.name)
      write_files(directory, cell_files(row, column.consume(row)))
    })
  })
}

fn parent(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_, ..rest] -> rest |> list.reverse |> string.join("/")
    [] -> "."
  }
}
