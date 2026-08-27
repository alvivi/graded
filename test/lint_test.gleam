// Tests for `graded/internal/lint` — the spec-file lint, driven through its
// own `Context` rather than a whole project run. What the integration suite
// pins is the warnings a real project produces; what these pin is the parts
// only reachable by constructing the context directly: the classifier's
// alias-chasing across modules, the qualified and unqualified import reads,
// the module-info memo, and the laziness of dependency discovery.

import glance
import gleam/dict.{type Dict}
import gleam/list
import gleam/set
import gleam/string
import gleeunit/should
import graded/internal/annotation
import graded/internal/effects
import graded/internal/lint
import graded/internal/signatures
import graded/internal/types.{QualifiedName, UnmatchedTypeFieldWarning}

// Fixture setup
//
// A context over modules given as `#(module_path, source)`, with no
// dependencies and an empty catalog. `dependency_files` panics unless a test
// supplies one, so a test that does not expect the walk proves it never runs.

fn empty_catalog() -> effects.BundledCatalog {
  effects.BundledCatalog(
    functions: dict.new(),
    modules: dict.new(),
    param_bounds: dict.new(),
    type_fields: [],
  )
}

fn index_of(
  modules: List(#(String, String)),
) -> Dict(String, #(String, glance.Module)) {
  list.fold(modules, dict.new(), fn(acc, entry) {
    let #(module_path, source) = entry
    let assert Ok(module) = glance.module(source)
    dict.insert(acc, module_path, #(module_path <> ".gleam", module))
  })
}

fn context(
  spec_source: String,
  modules: List(#(String, String)),
) -> lint.Context {
  let assert Ok(spec) = annotation.parse_file(spec_source)
  lint.Context(
    spec:,
    index: index_of(modules),
    stale_externals: set.new(),
    stale_returns_clauses: set.new(),
    catalog: empty_catalog(),
    registry: signatures.empty(),
    dependency_name: fn(_) { lint.UnreadDependency },
    dependency_files: fn() { panic as "dependency discovery was forced" },
    dependency_sources_are_complete: fn() { True },
  )
}

// A context whose dependency discovery answers, for the lints that need it.
fn with_dependencies(
  base: lint.Context,
  files: Dict(String, String),
) -> lint.Context {
  lint.Context(..base, dependency_files: fn() { files })
}

// Field `assume` lines
//
// The classifier decides whether a field's declared type can be called,
// following alias chains and imports across modules. Only what it can prove
// non-callable is flagged.

fn field_warnings(
  spec: String,
  modules: List(#(String, String)),
) -> List(String) {
  context(spec, modules)
  |> with_dependencies(dict.new())
  |> lint.run
  |> list.filter_map(fn(warning) {
    case warning {
      UnmatchedTypeFieldWarning(name:) -> Ok(name)
      _ -> Error(Nil)
    }
  })
}

pub fn a_directly_callable_field_is_not_flagged_test() {
  field_warnings("assume app.Handler.run : [Stdout]\n", [
    #("app", "pub type Handler {\n  Handler(run: fn() -> Nil)\n}\n"),
  ])
  |> should.equal([])
}

pub fn a_field_typed_through_a_local_alias_is_not_flagged_test() {
  field_warnings("assume app.Handler.run : [Stdout]\n", [
    #(
      "app",
      "pub type Action =
  fn() -> Nil

pub type Handler {
  Handler(run: Action)
}
",
    ),
  ])
  |> should.equal([])
}

pub fn a_field_typed_through_a_qualified_import_is_not_flagged_test() {
  // The field's type names another module by its import alias, so the
  // classifier reads that module's own aliases to settle it.
  field_warnings("assume app.Handler.run : [Stdout]\n", [
    #(
      "app",
      "import lib

pub type Handler {
  Handler(run: lib.Action)
}
",
    ),
    #("lib", "pub type Action =\n  fn() -> Nil\n"),
  ])
  |> should.equal([])
}

pub fn a_field_typed_through_an_unqualified_import_is_not_flagged_test() {
  field_warnings("assume app.Handler.run : [Stdout]\n", [
    #(
      "app",
      "import lib.{type Action}

pub type Handler {
  Handler(run: Action)
}
",
    ),
    #("lib", "pub type Action =\n  fn() -> Nil\n"),
  ])
  |> should.equal([])
}

pub fn a_field_that_is_plainly_not_callable_is_flagged_test() {
  field_warnings("assume app.Handler.run : [Stdout]\n", [
    #("app", "pub type Handler {\n  Handler(run: Int)\n}\n"),
  ])
  |> should.equal(["app.Handler.run"])
}

pub fn a_field_whose_alias_chain_cycles_is_not_flagged_test() {
  // An unresolvable chain reads as unknown, never as non-callable, so the
  // lint does not false-flag it.
  field_warnings("assume app.Handler.run : [Stdout]\n", [
    #(
      "app",
      "pub type A =
  B

pub type B =
  A

pub type Handler {
  Handler(run: A)
}
",
    ),
  ])
  |> should.equal([])
}

pub fn a_field_of_an_unknown_module_is_flagged_test() {
  field_warnings("assume nope.Handler.run : [Stdout]\n", [
    #("app", "pub type Handler {\n  Handler(run: fn() -> Nil)\n}\n"),
  ])
  |> should.equal(["nope.Handler.run"])
}

// The module-info memo
//
// Every module the classifier consults is parsed at most once per pass, and a
// module it cannot read is recorded as a miss rather than retried.

pub fn the_pass_records_each_module_it_consults_once_test() {
  // Two field lines resolve through the same `lib`, and `lib` is consulted
  // once per chain layer; the memo holds one entry per module either way.
  let #(_warnings, memo) =
    context("assume app.One.run : [Stdout]\nassume app.Two.run : [Disk]\n", [
      #(
        "app",
        "import lib

pub type One {
  One(run: lib.Action)
}

pub type Two {
  Two(run: lib.Action)
}
",
      ),
      #("lib", "pub type Action =\n  fn() -> Nil\n"),
    ])
    |> with_dependencies(dict.new())
    |> lint.run_recording_lookups

  dict.keys(memo)
  |> list.sort(string.compare)
  |> should.equal(["app", "lib"])
}

pub fn the_memo_records_a_module_it_could_not_read_test() {
  // `lib` is named as a dependency module whose file is not there, so the
  // lookup fails — and the failure is what the memo holds, so a second
  // consultation is not a second read attempt.
  let #(_warnings, memo) =
    context("assume app.Handler.run : [Stdout]\n", [
      #(
        "app",
        "import lib

pub type Handler {
  Handler(run: lib.Action)
}
",
      ),
    ])
    |> with_dependencies(
      dict.from_list([#("lib", "/tmp/graded_lint_no_such_file.gleam")]),
    )
    |> lint.run_recording_lookups

  dict.get(memo, "lib") |> should.equal(Ok(Error(Nil)))
}

// Laziness of dependency discovery
//
// The tree walk behind `dependency_files` is the expensive part of the pass.
// A spec with no `assume`, declared-returns or field line asks nothing of it,
// and must not force it.

pub fn a_spec_with_no_declaring_line_never_walks_the_dependency_tree_test() {
  // `dependency_files` panics; reaching the end proves it was never called.
  context("check app.go : []\neffects app.go : []\n", [
    #("app", "pub fn go() -> Nil {\n  Nil\n}\n"),
  ])
  |> lint.run
  |> should.equal([])
}

pub fn a_check_line_naming_nothing_is_still_flagged_lazily_test() {
  let warnings =
    context("check app.missing : []\n", [
      #("app", "pub fn go() -> Nil {\n  Nil\n}\n"),
    ])
    |> lint.run
  warnings
  |> should.equal([types.UnmatchedCheckWarning(function: "app.missing")])
}

// The dependency-name reading
//
// The lint's one read of the dependency scan is the three-state answer about
// one name, handed in as a closure.

pub fn a_dependency_that_defines_the_name_is_not_flagged_test() {
  let base = context("assume dep/io.write : [Disk]\n", [])
  lint.Context(
    ..base,
    dependency_name: fn(name) {
      case name {
        QualifiedName(module: "dep/io", function: "write") ->
          lint.DefinedByDependency
        _ -> lint.AbsentFromDependency
      }
    },
    dependency_files: fn() { dict.from_list([#("dep/io", "dep/io.gleam")]) },
  )
  |> lint.run
  |> should.equal([])
}

pub fn a_dependency_that_lacks_the_name_is_flagged_test() {
  let base = context("assume dep/io.typo : [Disk]\n", [])
  lint.Context(
    ..base,
    dependency_name: fn(_) { lint.AbsentFromDependency },
    dependency_files: fn() { dict.from_list([#("dep/io", "dep/io.gleam")]) },
  )
  |> lint.run
  |> should.equal([
    types.UnmatchedFunctionExternalWarning(function: "dep/io.typo"),
  ])
}
