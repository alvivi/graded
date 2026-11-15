// Every knowledge-base entry keeps the kind of statement that wrote it — a
// written line, a generated `effects` line, or this run's inference — apart
// from the source it came from, and keeps it through every merge.

import gleam/dict
import gleeunit/should
import graded
import graded/internal/effect_term
import graded/internal/effects
import graded/internal/types.{
  CurrentInference, DeclaredLine, GeneratedLine, ParamBound, QualifiedName, TVar,
}
import support

fn knowledge_base(directory: String) -> effects.KnowledgeBase {
  let assert Ok(knowledge_base) = graded.context_knowledge_base(directory)
  knowledge_base
}

fn lineage(
  knowledge_base: effects.KnowledgeBase,
  module: String,
  function: String,
) -> types.Lineage {
  let assert effects.Known(_term, source) =
    effects.lookup(knowledge_base, QualifiedName(module, function))
  effects.lineage_of(source)
}

// One spec, both kinds of line

const dependency_spec =
  "effects dep.run(cb: [cb]) : [cb] where returns : [cb]
assume dep.run(f: [f]) : [f]
effects dep.tick : [Time]
assume dep.make(g: [g]) where returns : [g]
effects dep.make(h: [h]) : [h]
assume dep/blanket : [Net]
assume dep.Handler.on_click : [Dom]
"

const dependency_source =
  "pub type Handler {
  Handler(on_click: fn() -> Nil)
}

pub fn run(f: fn() -> Nil) -> fn() -> Nil {
  f
}

pub fn tick() -> Nil {
  Nil
}

pub fn make(h: fn() -> Nil) -> fn() -> Nil {
  h
}
"

fn installed_dependency(directory: String) -> String {
  support.write_project_with_dependency(
    directory:,
    package: "app",
    spec: "",
    sources: [#("src/app.gleam", "pub fn go() -> Nil {\n  Nil\n}\n")],
    dependency: "dep",
    dependency_spec:,
    dependency_sources: [
      #("dep.gleam", dependency_source),
      #("dep/blanket.gleam", "pub fn wire() -> Nil {\n  Nil\n}\n"),
    ],
  )
}

pub fn a_written_and_a_generated_line_keep_their_own_lineage_test() {
  let directory = installed_dependency("/tmp/graded_lineage_installed")
  let knowledge_base = knowledge_base(directory)
  support.cleanup(directory)
  let run = QualifiedName("dep", "run")
  // The written line answers for the term, with its own bounds; the generated
  // line's clause keeps its own lineage beside it.
  lineage(knowledge_base, "dep", "run") |> should.equal(DeclaredLine)
  effects.lookup_param_bounds(knowledge_base, run)
  |> should.equal([ParamBound("f", TVar("f"))])
  let assert Ok(returned) =
    effects.lookup_returned_operator(knowledge_base, run)
  effects.summary_lineage(returned.summary) |> should.equal(GeneratedLine)
  lineage(knowledge_base, "dep", "tick") |> should.equal(GeneratedLine)
}

pub fn a_clause_only_assume_keeps_its_own_bounds_beside_a_generated_term_test() {
  let directory = installed_dependency("/tmp/graded_lineage_clause_only")
  let knowledge_base = knowledge_base(directory)
  support.cleanup(directory)
  let make = QualifiedName("dep", "make")
  lineage(knowledge_base, "dep", "make") |> should.equal(GeneratedLine)
  effects.lookup_param_bounds(knowledge_base, make)
  |> should.equal([ParamBound("h", TVar("h"))])
  let assert Ok(returned) =
    effects.lookup_returned_operator(knowledge_base, make)
  effects.summary_lineage(returned.summary) |> should.equal(DeclaredLine)
  returned.summary
  |> should.equal(effects.Declared(bounds: [ParamBound("g", TVar("g"))]))
}

pub fn module_level_and_field_assumes_are_written_lines_test() {
  let directory = installed_dependency("/tmp/graded_lineage_module_field")
  let knowledge_base = knowledge_base(directory)
  support.cleanup(directory)
  lineage(knowledge_base, "dep/blanket", "wire") |> should.equal(DeclaredLine)
  let assert Ok(field) =
    effects.lookup_type_field(knowledge_base, "dep", "Handler", "on_click")
  field.origin |> should.equal(types.Declared(types.DependencySpec("dep")))
}

// Every merge

pub fn lineage_survives_every_merge_test() {
  // A root with its own spec, a direct path dependency `a` with a spec, and a
  // transitively loaded `b` with none.
  let root =
    support.captured_tree("transitive_path", "/tmp/graded_lineage_tree")
  let parent = "/tmp/graded_lineage_tree"
  support.write_file(
    root <> "/app.graded",
    "assume app/ffi.ext : [Disk]\neffects app.committed : []\n",
  )
  support.write_file(
    root <> "/src/app.gleam",
    "import a\n\npub fn committed() -> Nil {\n  a.f()\n}\n\npub fn fresh() -> Nil {\n  a.g()\n}\n",
  )
  support.write_file(
    root <> "/src/app/ffi.gleam",
    "@external(erlang, \"m\", \"ext\")\npub fn ext() -> Nil\n",
  )
  support.write_file(
    parent <> "/a/src/a.gleam",
    "import b\n\npub fn f() -> Nil {\n  b.h()\n}\n\n@external(erlang, \"m\", \"g\")\npub fn g() -> Nil\n",
  )
  support.write_file(
    parent <> "/a/a.graded",
    "effects a.f : []\nassume a.g : [Net]\n",
  )
  support.write_file(
    parent <> "/b/src/b.gleam",
    "pub fn h() -> Nil {\n  Nil\n}\n",
  )
  let knowledge_base = knowledge_base(root)
  support.cleanup(parent)
  [
    lineage(knowledge_base, "app/ffi", "ext"),
    lineage(knowledge_base, "app", "committed"),
    lineage(knowledge_base, "app", "fresh"),
    lineage(knowledge_base, "a", "f"),
    lineage(knowledge_base, "a", "g"),
    lineage(knowledge_base, "b", "h"),
  ]
  |> should.equal([
    DeclaredLine,
    GeneratedLine,
    CurrentInference,
    GeneratedLine,
    DeclaredLine,
    CurrentInference,
  ])
}

// A truthful summary and the inference it summarizes

fn path_dependency_project(
  directory: String,
  dependency_spec: List(#(String, String)),
) -> String {
  support.write_fixture(directory, [
    #(
      "app/gleam.toml",
      "name = \"app\"\n\n[dependencies]\ndep = { path = \"../dep\" }\n",
    ),
    #(
      "app/src/app.gleam",
      "import app/ffi\nimport dep\n\nfn loud() -> Nil {\n  ffi.shout()\n}\n\npub fn go() -> Nil {\n  dep.apply(loud)\n}\n",
    ),
    #(
      "app/src/app/ffi.gleam",
      "@external(erlang, \"m\", \"shout\")\npub fn shout() -> Nil\n",
    ),
    #("app/app.graded", "assume app/ffi.shout : [Stdout]\n"),
    #("dep/gleam.toml", "name = \"dep\"\n"),
    #("dep/src/dep.gleam", "pub fn apply(f: fn() -> Nil) -> Nil {\n  f()\n}\n"),
    ..dependency_spec
  ])
  directory <> "/app"
}

pub fn a_generated_summary_and_its_inference_answer_alike_test() {
  let generated =
    path_dependency_project("/tmp/graded_lineage_generated", [
      #("dep/dep.graded", "effects dep.apply(f: [f]) : [f]\n"),
    ])
  let inferred = path_dependency_project("/tmp/graded_lineage_inferred", [])
  let generated_base = knowledge_base(generated)
  let inferred_base = knowledge_base(inferred)
  let answer = fn(directory) {
    graded.run_effect_formatted(directory, "app.go", graded.Graded)
  }
  let generated_answer = answer(generated)
  let inferred_answer = answer(inferred)
  support.cleanup("/tmp/graded_lineage_generated")
  support.cleanup("/tmp/graded_lineage_inferred")
  lineage(generated_base, "dep", "apply") |> should.equal(GeneratedLine)
  lineage(inferred_base, "dep", "apply") |> should.equal(CurrentInference)
  generated_answer |> should.equal(inferred_answer)
  let assert Ok(text) = generated_answer
  text
  |> should.equal(
    "// resolved from in-memory inference\neffects app.go : [Stdout]",
  )
}

pub fn the_catalog_is_written_test() {
  let assert effects.Known(_term, source) =
    effects.lookup(
      support.knowledge_base(),
      QualifiedName("gleam/io", "println"),
    )
  effects.lineage_of(source) |> should.equal(DeclaredLine)
  // A term a source folds as its own inference reads as current.
  effects.new_knowledge_base()
  |> effects.with_inferred(
    dict.from_list([#(QualifiedName("m", "f"), effect_term.pure())]),
    types.ProjectInferred,
  )
  |> lineage("m", "f")
  |> should.equal(CurrentInference)
}
