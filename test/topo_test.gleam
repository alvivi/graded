//// Tests for topological-order project module inference. These exercise the
//// regression from the original issue (deep transitive chains needing
//// multiple `graded infer` runs to converge) and a few related shapes.
////
//// Fixtures are materialised at runtime under `/tmp/` so the Gleam compiler
//// doesn't try to compile them as project modules — fixture modules import
//// each other (e.g. `import app/d`) which would not resolve from `test/`.
//// All temp directories start without any `.graded` files, which also
//// exercises Risk 2 ("modules without prior .graded files still get
//// processed").

import filepath
import gleam/list
import gleam/set
import gleeunit/should
import graded
import graded/internal/annotation
import graded/internal/types.{type EffectAnnotation, type EffectSet, Specific}
import simplifile

// ----- helpers -----

fn make_fixture(name: String, files: List(#(String, String))) -> String {
  let directory = "/tmp/graded_topo_" <> name
  let _ = simplifile.delete(directory)
  list.each(files, fn(entry) {
    let #(relative_path, contents) = entry
    let full_path = directory <> "/" <> relative_path
    let parent = filepath.directory_name(full_path)
    let assert Ok(Nil) = simplifile.create_directory_all(parent)
    let assert Ok(Nil) = simplifile.write(full_path, contents)
  })
  directory
}

fn cleanup(directory: String) -> Nil {
  let _ = simplifile.delete(directory)
  Nil
}

fn read_inferred(graded_path: String) -> List(EffectAnnotation) {
  let assert Ok(content) = simplifile.read(graded_path)
  let assert Ok(file) = annotation.parse_file(content)
  annotation.extract_annotations(file)
}

fn effects_of(
  annotations: List(EffectAnnotation),
  function: String,
) -> EffectSet {
  let assert Ok(annotation) =
    list.find(annotations, fn(a) { a.function == function })
  annotation.effects
}

fn pure() -> EffectSet {
  Specific(set.new())
}

fn with_labels(labels: List(String)) -> EffectSet {
  Specific(set.from_list(labels))
}

// ----- chain (the reported issue, verbatim) -----

pub fn chain_resolves_in_one_pass_test() {
  let directory =
    make_fixture("chain", [
      #(
        "app/d.gleam",
        "import gleam/string

pub fn format(value: String) -> String {
  string.uppercase(value)
}
",
      ),
      #(
        "app/c.gleam",
        "import app/d

pub fn transform(value: String) -> String {
  d.format(value)
}
",
      ),
      #(
        "app/b.gleam",
        "import app/c

pub fn process(value: String) -> String {
  c.transform(value)
}
",
      ),
      #(
        "app/a.gleam",
        "import app/b

pub fn run(value: String) -> String {
  b.process(value)
}
",
      ),
    ])

  let assert Ok(Nil) = graded.run_infer(directory)

  // All four modules pure — none should be tagged [Unknown].
  effects_of(read_inferred(directory <> "/priv/graded/app/d.graded"), "format")
  |> should.equal(pure())

  effects_of(
    read_inferred(directory <> "/priv/graded/app/c.graded"),
    "transform",
  )
  |> should.equal(pure())

  effects_of(read_inferred(directory <> "/priv/graded/app/b.graded"), "process")
  |> should.equal(pure())

  // The crucial assertion: `a.run` is at the end of a 4-module chain.
  // Pre-fix this would resolve to [Unknown] and need a second `run_infer`.
  effects_of(read_inferred(directory <> "/priv/graded/app/a.graded"), "run")
  |> should.equal(pure())

  cleanup(directory)
}

// ----- diamond -----

pub fn diamond_propagates_effects_through_both_branches_test() {
  let directory =
    make_fixture("diamond", [
      #(
        "app/d.gleam",
        "import gleam/io

pub fn leaf() -> Nil {
  io.println(\"leaf\")
}
",
      ),
      #(
        "app/b.gleam",
        "import app/d

pub fn left() -> Nil {
  d.leaf()
}
",
      ),
      #(
        "app/c.gleam",
        "import app/d

pub fn right() -> Nil {
  d.leaf()
}
",
      ),
      #(
        "app/a.gleam",
        "import app/b
import app/c

pub fn run() -> Nil {
  b.left()
  c.right()
}
",
      ),
    ])

  let assert Ok(Nil) = graded.run_infer(directory)

  effects_of(read_inferred(directory <> "/priv/graded/app/d.graded"), "leaf")
  |> should.equal(with_labels(["Stdout"]))

  effects_of(read_inferred(directory <> "/priv/graded/app/b.graded"), "left")
  |> should.equal(with_labels(["Stdout"]))

  effects_of(read_inferred(directory <> "/priv/graded/app/c.graded"), "right")
  |> should.equal(with_labels(["Stdout"]))

  // The diamond apex sees Stdout via both branches and reports it once.
  effects_of(read_inferred(directory <> "/priv/graded/app/a.graded"), "run")
  |> should.equal(with_labels(["Stdout"]))

  cleanup(directory)
}

// ----- fan-out (one leaf, many dependents) -----

pub fn fanout_resolves_all_dependents_in_one_pass_test() {
  let leaf =
    "import gleam/string

pub fn util(value: String) -> String {
  string.uppercase(value)
}
"
  let dependent =
    "import app/leaf

pub fn run(value: String) -> String {
  leaf.util(value)
}
"
  let directory =
    make_fixture("fanout", [
      #("app/leaf.gleam", leaf),
      #("app/dep1.gleam", dependent),
      #("app/dep2.gleam", dependent),
      #("app/dep3.gleam", dependent),
      #("app/dep4.gleam", dependent),
      #("app/dep5.gleam", dependent),
    ])

  let assert Ok(Nil) = graded.run_infer(directory)

  effects_of(read_inferred(directory <> "/priv/graded/app/leaf.graded"), "util")
  |> should.equal(pure())

  list.each(["dep1", "dep2", "dep3", "dep4", "dep5"], fn(name) {
    let path = directory <> "/priv/graded/app/" <> name <> ".graded"
    effects_of(read_inferred(path), "run")
    |> should.equal(pure())
  })

  cleanup(directory)
}

// ----- impure chain (effect propagates through 4 modules) -----

pub fn impure_chain_propagates_effect_to_root_test() {
  let directory =
    make_fixture("impure_chain", [
      #(
        "app/d.gleam",
        "import gleam/io

pub fn shout(value: String) -> Nil {
  io.println(value)
}
",
      ),
      #(
        "app/c.gleam",
        "import app/d

pub fn transform(value: String) -> Nil {
  d.shout(value)
}
",
      ),
      #(
        "app/b.gleam",
        "import app/c

pub fn process(value: String) -> Nil {
  c.transform(value)
}
",
      ),
      #(
        "app/a.gleam",
        "import app/b

pub fn run(value: String) -> Nil {
  b.process(value)
}
",
      ),
    ])

  let assert Ok(Nil) = graded.run_infer(directory)

  effects_of(read_inferred(directory <> "/priv/graded/app/d.graded"), "shout")
  |> should.equal(with_labels(["Stdout"]))

  effects_of(
    read_inferred(directory <> "/priv/graded/app/c.graded"),
    "transform",
  )
  |> should.equal(with_labels(["Stdout"]))

  effects_of(read_inferred(directory <> "/priv/graded/app/b.graded"), "process")
  |> should.equal(with_labels(["Stdout"]))

  effects_of(read_inferred(directory <> "/priv/graded/app/a.graded"), "run")
  |> should.equal(with_labels(["Stdout"]))

  cleanup(directory)
}

// ----- leaf only (single module, no project imports) -----

pub fn single_module_with_no_project_imports_test() {
  let directory =
    make_fixture("leaf_only", [
      #(
        "solo.gleam",
        "import gleam/string

pub fn shout(value: String) -> String {
  string.uppercase(value)
}
",
      ),
    ])

  let assert Ok(Nil) = graded.run_infer(directory)

  effects_of(read_inferred(directory <> "/priv/graded/solo.graded"), "shout")
  |> should.equal(pure())

  cleanup(directory)
}

// ----- Risk 2: modules without prior .graded files get .graded files written -----

pub fn infer_writes_graded_files_from_clean_slate_test() {
  let directory =
    make_fixture("clean_slate", [
      #(
        "app/d.gleam",
        "import gleam/string

pub fn format(value: String) -> String {
  string.uppercase(value)
}
",
      ),
      #(
        "app/c.gleam",
        "import app/d

pub fn transform(value: String) -> String {
  d.format(value)
}
",
      ),
      #(
        "app/b.gleam",
        "import app/c

pub fn process(value: String) -> String {
  c.transform(value)
}
",
      ),
      #(
        "app/a.gleam",
        "import app/b

pub fn run(value: String) -> String {
  b.process(value)
}
",
      ),
    ])

  // Sanity: nothing exists yet — Risk 2 starting condition.
  simplifile.is_file(directory <> "/priv/graded/app/a.graded")
  |> should.equal(Ok(False))

  let assert Ok(Nil) = graded.run_infer(directory)

  // All four .graded files exist after a single inference run.
  list.each(["a", "b", "c", "d"], fn(name) {
    let path = directory <> "/priv/graded/app/" <> name <> ".graded"
    simplifile.is_file(path) |> should.equal(Ok(True))
  })

  cleanup(directory)
}
