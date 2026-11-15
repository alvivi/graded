// Values of types whose arguments grow, permute, alias or vanish, each handed
// to a boundless foreign function, and values of large recursive families
// handed over many times. What a type can hold is solved from its definitions
// once for the run, however its arguments grow and however many values of it
// are read, so every case's inference runs inside a bound on its reductions,
// with its answer:
// `[]` where the type proves no function, and never `[]` where a function can
// be reached. Every case is a program the compiler accepts.
//
//   gleam run -m type_scaling_test -- [DIR]
//
// writes every case as a project under DIR (default `build/type_scaling`), to
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

const work_bound = 30_000_000

@external(erlang, "scope_test_ffi", "reductions")
fn reductions() -> Int

const ffi_source =
  "@external(erlang, \"m\", \"shout\")
@external(javascript, \"m\", \"shout\")
pub fn shout() -> Nil

@external(erlang, \"m\", \"sink\")
@external(javascript, \"m\", \"sink\")
pub fn sink(x: a) -> Nil
"

const spec =
  "assume probe/ffi.shout : [Stdout]
assume probe/ffi.sink : []
"

// A case: its name, the modules beside `main`'s by their name under the
// case's own (`shapes` is imported as `shapes`), `main`'s statements, and
// `main`'s inferred effects.
type Case {
  Case(
    name: String,
    modules: fn(String) -> List(#(String, String)),
    main: String,
    answer: String,
  )
}

fn shapes(source: String) -> fn(String) -> List(#(String, String)) {
  fn(_prefix) { [#("shapes", source)] }
}

const doubling_step_first =
  "pub type Grow(a) {
  Step(inner: Grow(#(a, a)))
  Leaf(value: a)
}
"

fn alias_chain() -> String {
  "pub type A0(a) =\n  #(a, Int)\n"
  <> string.concat(
    list.map(from(1, 101), fn(i) {
      "pub type A"
      <> int.to_string(i)
      <> "(a) =\n  A"
      <> int.to_string(i - 1)
      <> "(List(a))\n"
    }),
  )
  <> "pub type Holder(a) {
  Holder(A100(a))
  Empty
}

pub fn empty() -> Holder(Int) {
  Empty
}

pub fn empty_of_functions() -> Holder(fn() -> Nil) {
  Empty
}
"
}

// `count` mutually recursive types of `arity` parameters, each passing its
// parameters on rotated to the next and holding its first, as `T0` … or `F0` …
// by `name`.
fn rotating_family(name: String, count: Int, arity: Int) -> String {
  let parameters = list.map(from(0, arity), fn(i) { "a" <> int.to_string(i) })
  let rotated = case parameters {
    [first, ..rest] -> list.append(rest, [first])
    [] -> []
  }
  string.concat(
    list.map(from(0, count), fn(i) {
      let index = int.to_string(i)
      "pub type "
      <> name
      <> index
      <> "("
      <> string.join(parameters, ", ")
      <> ") {\n  Next"
      <> index
      <> "("
      <> name
      <> int.to_string({ i + 1 } % count)
      <> "("
      <> string.join(rotated, ", ")
      <> "))\n  End"
      <> index
      <> "(a0)\n}\n\n"
    }),
  )
}

fn ints(count: Int) -> String {
  string.join(list.repeat("Int", count), ", ")
}

// One value of a 32-type, 32-parameter family handed over 2,048 times.
fn repeated_use() -> String {
  rotating_family("T", 32, 32)
  <> "pub fn make() -> T0("
  <> ints(32)
  <> ") {\n  End0(0)\n}\n"
}

// 512 types, each holding one member of a 128-type, 32-parameter family.
const family_users = 512

const family_size = 128

fn shared_family() -> String {
  rotating_family("F", family_size, 32)
  <> string.concat(
    list.map(from(0, family_size), fn(i) {
      "pub type Of"
      <> int.to_string(i)
      <> " =\n  F"
      <> int.to_string(i)
      <> "("
      <> ints(32)
      <> ")\n\n"
    }),
  )
  <> string.concat(
    list.map(from(0, family_users), fn(j) {
      let user = int.to_string(j)
      let member = int.to_string(j % family_size)
      "pub type W"
      <> user
      <> " {\n  W"
      <> user
      <> "(Of"
      <> member
      <> ")\n}\n\npub fn w"
      <> user
      <> "() -> W"
      <> user
      <> " {\n  W"
      <> user
      <> "(End"
      <> member
      <> "(0))\n}\n\n"
    }),
  )
}

fn cases() -> List(Case) {
  [
    Case(
      "doubling, step first",
      shapes(doubling_step_first),
      "  ffi.sink(shapes.Leaf(1))\n",
      "[]",
    ),
    Case(
      "doubling, leaf first",
      shapes(
        "pub type Grow(a) {
  Leaf(value: a)
  Step(inner: Grow(#(a, a)))
}
",
      ),
      "  ffi.sink(shapes.Leaf(1))\n",
      "[]",
    ),
    Case(
      "doubling, holding a printer",
      shapes(doubling_step_first),
      "  ffi.sink(shapes.Step(shapes.Leaf(#(ffi.shout, ffi.shout))))\n",
      "[Stdout]",
    ),
    Case(
      "tripling",
      shapes(
        "pub type Grow(a) {
  Step(Grow(#(a, a, a)))
  Leaf(a)
}
",
      ),
      "  ffi.sink(shapes.Leaf(1))\n",
      "[]",
    ),
    Case(
      "listing",
      shapes(
        "pub type Grow(a) {
  Step(Grow(List(a)))
  Leaf(a)
}
",
      ),
      "  ffi.sink(shapes.Leaf(1))\n",
      "[]",
    ),
    Case(
      "mutual recursion, read from another module",
      shapes(
        "pub type A(a) {
  ToB(B(#(a, a)))
  EndA(a)
}

pub type B(b) {
  ToA(A(List(b)))
  EndB(b)
}
",
      ),
      "  ffi.sink(shapes.EndA(1))\n"
        <> "  ffi.sink(shapes.ToB(shapes.EndB(#(1, 1))))\n",
      "[]",
    ),
    Case(
      "mutual recursion, holding a printer",
      shapes(
        "pub type A(a) {
  ToB(B(#(a, a)))
  EndA(a)
}

pub type B(b) {
  ToA(A(List(b)))
  EndB(b)
}
",
      ),
      "  ffi.sink(shapes.ToB(shapes.EndB(#(ffi.shout, ffi.shout))))\n",
      "[Stdout]",
    ),
    Case(
      "growing through another module",
      fn(prefix) {
        [
          #("pair", "pub type Pair(a) {\n  Pair(a, a)\n}\n"),
          #("shapes", "import " <> prefix <> "_pair.{type Pair}

pub type Outer(a) {
  Deeper(Outer(Pair(a)))
  Done(a)
}
"),
        ]
      },
      "  ffi.sink(shapes.Done(1))\n",
      "[]",
    ),
    Case(
      "permuted parameters",
      shapes(
        "pub type Perm(a, b, c, d, e, f, g, h) {
  Rot(Perm(b, c, d, e, f, g, h, #(a, a)))
  Hold(a)
}

pub fn held(x: Int) -> Perm(Int, Int, Int, Int, Int, Int, Int, Int) {
  Hold(x)
}
",
      ),
      "  ffi.sink(shapes.held(1))\n",
      "[]",
    ),
    Case(
      "permuted parameters, one of them a function",
      shapes(
        "pub type Perm(a, b, c, d, e, f, g, h) {
  Rot(Perm(b, c, d, e, f, g, h, #(a, a)))
  Hold(a)
}

pub fn held(x: Int) -> Perm(Int, Int, Int, Int, Int, Int, Int, fn() -> Nil) {
  Hold(x)
}
",
      ),
      "  ffi.sink(shapes.held(1))\n",
      "[Unknown]",
    ),
    Case(
      "deep alias chain",
      fn(_prefix) { [#("shapes", alias_chain())] },
      "  ffi.sink(shapes.empty())\n",
      "[]",
    ),
    Case(
      "deep alias chain of functions",
      fn(_prefix) { [#("shapes", alias_chain())] },
      "  ffi.sink(shapes.empty_of_functions())\n",
      "[Unknown]",
    ),
    Case(
      "phantom parameter",
      shapes(
        "pub type Tagged(tag, a) {
  Tagged(value: a)
}

pub type Ladder(tag) {
  Up(Ladder(fn() -> tag))
  Ground
}

pub fn ground() -> Ladder(fn() -> Nil) {
  Ground
}
",
      ),
      "  ffi.sink(shapes.Tagged(1))\n  ffi.sink(shapes.ground())\n",
      "[]",
    ),
    Case(
      "one recursive type used many times",
      fn(_prefix) { [#("shapes", repeated_use())] },
      string.repeat("  ffi.sink(shapes.make())\n", 2048),
      "[]",
    ),
    Case(
      "many types sharing one recursive family",
      fn(_prefix) { [#("shapes", shared_family())] },
      string.concat(
        list.map(from(0, family_users), fn(j) {
          "  ffi.sink(shapes.w" <> int.to_string(j) <> "())\n"
        }),
      ),
      "[]",
    ),
    Case(
      "a parameter reaching a value several steps down",
      shapes(
        "pub type S1(a) {
  S1(S2(a))
}

pub type S2(a) {
  S2(S3(a))
}

pub type S3(a) {
  S3(S4(a))
}

pub type S4(a) {
  S4(S5(a))
}

pub type S5(a) {
  S5(value: a)
}
",
      ),
      "  ffi.sink(shapes.S1(shapes.S2(shapes.S3(shapes.S4(shapes.S5(ffi.shout))))))\n",
      "[Stdout]",
    ),
  ]
}

fn from(first: Int, until: Int) -> List(Int) {
  case first >= until {
    True -> []
    False -> [first, ..from(first + 1, until)]
  }
}

fn slug(text: String) -> String {
  text
  |> string.replace(", ", "_")
  |> string.replace(" ", "_")
}

// One case's modules under `prefix`: `main`'s, and the ones beside it.
fn case_modules(case_: Case, prefix: String) -> List(#(String, String)) {
  let main =
    "import probe/ffi\nimport "
    <> prefix
    <> "_shapes as shapes\n\npub fn main() -> Nil {\n"
    <> case_.main
    <> "}\n"
  [
    #("src/" <> prefix <> ".gleam", main),
    ..list.map(case_.modules(prefix), fn(module) {
      #("src/" <> prefix <> "_" <> module.0 <> ".gleam", module.1)
    })
  ]
}

fn case_files(case_: Case) -> List(#(String, String)) {
  [
    #("gleam.toml", "name = \"probe\"\n"),
    #("probe.graded", spec),
    #("src/probe/ffi.gleam", ffi_source),
    ..case_modules(case_, "probe/" <> slug(case_.name))
  ]
}

pub fn every_case_reads_its_answer_inside_the_bound_test() {
  list.each(cases(), fn(case_) {
    let module = "probe/" <> slug(case_.name)
    let directory =
      support.write_fixture(
        "/tmp/graded_type_scaling_" <> slug(case_.name),
        case_files(case_),
      )
    let before = reductions()
    let assert Ok(lines) = graded.inferred_lines(directory)
    let spent = reductions() - before
    support.cleanup(directory)
    let answer =
      list.find(lines, string.starts_with(_, "effects " <> module <> ".main"))
    #(case_.name, answer)
    |> should.equal(#(
      case_.name,
      Ok("effects " <> module <> ".main : " <> case_.answer),
    ))
    #(case_.name, spent <= work_bound)
    |> should.equal(#(case_.name, True))
  })
}

// Every case as modules of one project the compiler checks.
pub fn every_case_compiles_test() {
  let directory = absolute("build/type_scaling_check")
  let _ = simplifile.delete(directory)
  write_files(directory, [
    #("gleam.toml", "name = \"probe\"\n"),
    #("src/probe/ffi.gleam", ffi_source),
    ..list.flat_map(cases(), fn(case_) {
      case_modules(case_, "probe/" <> slug(case_.name))
    })
  ])
  let checked =
    shellout.command(run: "gleam", with: ["check"], in: directory, opt: [])
    |> result.map_error(fn(failure) { failure.1 })
  let _ = simplifile.delete(directory)
  checked |> result.map(fn(_) { Nil }) |> should.equal(Ok(Nil))
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
    [] -> "build/type_scaling"
  }
  list.each(cases(), fn(case_) {
    write_files(root <> "/" <> slug(case_.name), case_files(case_))
  })
}
