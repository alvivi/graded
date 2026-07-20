// Tests for topological-order project module inference. These exercise the
// regression from the original issue (deep transitive chains needing
// multiple `graded infer` runs to converge) and a few related shapes.
//
// Fixtures are materialised at runtime under `/tmp/` so the Gleam compiler
// doesn't try to compile them as project modules — fixture modules import
// each other (e.g. `import app/d`) which would not resolve from `test/`.
// All temp directories start without any `.graded` files, which also
// exercises clean-slate inference (modules without prior `.graded` files
// still get processed).

import filepath
import gleam/dict
import gleam/int
import gleam/list
import gleam/set
import gleam/string
import gleeunit/should
import graded
import graded/internal/annotation
import graded/internal/effect_term
import graded/internal/effects
import graded/internal/types.{
  type EffectAnnotation, type EffectSet, Polymorphic, QualifiedName, Specific,
}
import simplifile

// Helpers
//
// Fixture builders that materialise project trees under /tmp, plus readback
// helpers for the .graded files inference writes.

fn make_fixture(name: String, files: List(#(String, String))) -> String {
  write_fixture("/tmp/graded_topo_" <> name, [stdlib_manifest(), ..files])
}

// A minimal `manifest.toml` so a fixture project selects the bundled catalog
// (which marks `gleam/io.println : [Stdout]`, `gleam/string` pure, …) the same
// way a real installed project would. Dependency resolution now reads the
// project's own root, so a fixture without this would see an empty catalog. A
// fixture can override it by listing its own `manifest.toml` entry.
fn stdlib_manifest() -> #(String, String) {
  #(
    "manifest.toml",
    "packages = [
  { name = \"gleam_stdlib\", version = \"0.71.0\" },
]
",
  )
}

// Materialise a tree of files at `directory`, replacing any prior contents.
// Used by both project-style fixtures (under `/tmp/graded_topo_*`) and the
// path-dep smoke test which writes to its own directory.
fn write_fixture(directory: String, files: List(#(String, String))) -> String {
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

// Four-module pure chain `a -> b -> c -> d` where `d` calls `string.uppercase`
// (no effects). Reused by every test that needs the canonical "deep
// transitive chain that the old two-pass strategy mishandled" shape.
fn pure_chain_files() -> List(#(String, String)) {
  [
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
  ]
}

// Same shape as `pure_chain_files` but with `io.println` at the leaf so the
// `Stdout` effect must propagate up four modules.
fn impure_chain_files() -> List(#(String, String)) {
  [
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
  ]
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
  effect_term.to_effect_set(annotation.effects)
}

fn pure() -> EffectSet {
  Specific(set.new())
}

fn with_labels(labels: List(String)) -> EffectSet {
  Specific(set.from_list(labels))
}

// Chain
//
// A four-module pure chain resolves in a single `graded infer` pass instead
// of needing one run per dependency level.

pub fn chain_resolves_in_one_pass_test() {
  let directory = make_fixture("chain", pure_chain_files())

  let assert Ok(Nil) = graded.run_infer(directory)

  effects_of(
    read_inferred(directory <> "/build/.graded/app/d.graded"),
    "format",
  )
  |> should.equal(pure())

  effects_of(
    read_inferred(directory <> "/build/.graded/app/c.graded"),
    "transform",
  )
  |> should.equal(pure())

  effects_of(
    read_inferred(directory <> "/build/.graded/app/b.graded"),
    "process",
  )
  |> should.equal(pure())

  // The crucial assertion: `a.run` is at the end of a 4-module chain.
  // Pre-fix this would resolve to [Unknown] and need a second `run_infer`.
  effects_of(read_inferred(directory <> "/build/.graded/app/a.graded"), "run")
  |> should.equal(pure())

  cleanup(directory)
}

// Diamond
//
// One effectful leaf reached through two branches; the apex reports the
// effect once.

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

  effects_of(read_inferred(directory <> "/build/.graded/app/d.graded"), "leaf")
  |> should.equal(with_labels(["Stdout"]))

  effects_of(read_inferred(directory <> "/build/.graded/app/b.graded"), "left")
  |> should.equal(with_labels(["Stdout"]))

  effects_of(read_inferred(directory <> "/build/.graded/app/c.graded"), "right")
  |> should.equal(with_labels(["Stdout"]))

  // The diamond apex sees Stdout via both branches and reports it once.
  effects_of(read_inferred(directory <> "/build/.graded/app/a.graded"), "run")
  |> should.equal(with_labels(["Stdout"]))

  cleanup(directory)
}

// Fan-out (one leaf, many dependents)
//
// Many modules depending on the same leaf all resolve in one pass.

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

  effects_of(
    read_inferred(directory <> "/build/.graded/app/leaf.graded"),
    "util",
  )
  |> should.equal(pure())

  list.each(["dep1", "dep2", "dep3", "dep4", "dep5"], fn(name) {
    let path = directory <> "/build/.graded/app/" <> name <> ".graded"
    effects_of(read_inferred(path), "run")
    |> should.equal(pure())
  })

  cleanup(directory)
}

// Impure chain (effect propagates through 4 modules)
//
// The leaf's Stdout effect reaches every module up to the root in one pass.

pub fn impure_chain_propagates_effect_to_root_test() {
  let directory = make_fixture("impure_chain", impure_chain_files())

  let assert Ok(Nil) = graded.run_infer(directory)

  effects_of(read_inferred(directory <> "/build/.graded/app/d.graded"), "shout")
  |> should.equal(with_labels(["Stdout"]))

  effects_of(
    read_inferred(directory <> "/build/.graded/app/c.graded"),
    "transform",
  )
  |> should.equal(with_labels(["Stdout"]))

  effects_of(
    read_inferred(directory <> "/build/.graded/app/b.graded"),
    "process",
  )
  |> should.equal(with_labels(["Stdout"]))

  effects_of(read_inferred(directory <> "/build/.graded/app/a.graded"), "run")
  |> should.equal(with_labels(["Stdout"]))

  cleanup(directory)
}

// Leaf only (single module, no project imports)
//
// The degenerate one-module project still infers and writes its cache file.

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

  effects_of(read_inferred(directory <> "/build/.graded/solo.graded"), "shout")
  |> should.equal(pure())

  cleanup(directory)
}

// Clean-slate inference
//
// Modules without prior .graded files get cache files written by a single
// inference run.

pub fn infer_writes_graded_files_from_clean_slate_test() {
  let directory = make_fixture("clean_slate", pure_chain_files())

  // Sanity: nothing exists yet — a clean slate.
  simplifile.is_file(directory <> "/build/.graded/app/a.graded")
  |> should.equal(Ok(False))

  let assert Ok(Nil) = graded.run_infer(directory)

  // All four .graded files exist after a single inference run.
  list.each(["a", "b", "c", "d"], fn(name) {
    let path = directory <> "/build/.graded/app/" <> name <> ".graded"
    simplifile.is_file(path) |> should.equal(Ok(True))
  })

  cleanup(directory)
}

// Inference idempotence
//
// A second `run_infer` against the same project must produce byte-identical
// `.graded` files. If this regresses, inference has stopped converging in
// one pass.

pub fn run_infer_is_idempotent_test() {
  let directory = make_fixture("idempotent", impure_chain_files())

  let assert Ok(Nil) = graded.run_infer(directory)
  let snapshot1 = read_all_graded(directory)

  let assert Ok(Nil) = graded.run_infer(directory)
  let snapshot2 = read_all_graded(directory)

  snapshot1 |> should.equal(snapshot2)

  cleanup(directory)
}

fn read_all_graded(directory: String) -> List(#(String, String)) {
  // Snapshot every .graded file under the test directory: the spec file
  // at the root plus all the per-module cache files under build/.graded/.
  // simplifile.get_files already returns regular files only.
  case simplifile.get_files(directory) {
    Error(_) -> []
    Ok(files) ->
      files
      |> list.filter(fn(f) { string.ends_with(f, ".graded") })
      |> list.sort(string.compare)
      |> list.map(fn(path) {
        let assert Ok(content) = simplifile.read(path)
        #(path, content)
      })
  }
}

// Returned operators cross module/package via the spec
//
// A producer's `returns` line in the spec lets a consumer in another module
// resolve a factory-produced handle to precise effects.

pub fn returns_aliased_return_generates_summary_test() {
  // Gap A: a producer whose return type is a module-local alias to `fn(...)`
  // now generates a `returns` line. Before Fix A the gate matched only a literal
  // `fn(...)` return type, so no summary was emitted for the alias.
  let directory =
    make_fixture("returns_aliased", [
      #("gleam.toml", "name = \"app\"\n"),
      #(
        "app/factory.gleam",
        "import gleam/io

pub type Resolver = fn() -> Nil

pub fn make() -> Resolver {
  fn() { io.println(\"x\") }
}
",
      ),
      #("app.graded", "check app/factory.make : []\n"),
    ])

  let assert Ok(Nil) = graded.run_infer(directory)
  let assert Ok(spec) = simplifile.read(directory <> "/app.graded")
  string.contains(spec, "returns app/factory.make : [Stdout]")
  |> should.be_true()
  cleanup(directory)
}

pub fn returns_operator_cross_module_end_to_end_test() {
  // A producer that returns a function, consumed in another module. After
  // `infer`, the spec carries a `returns` line for the producer; `check` then
  // resolves the consumer's `let h = factory.pick(); with_logger(h)` to the
  // precise [Stdout] (not [Unknown]) by loading that line.
  let directory =
    make_fixture("returns_e2e", [
      #("gleam.toml", "name = \"app\"\n"),
      #(
        "app/factory.gleam",
        "pub fn pick() -> fn(fn(String) -> Nil) -> Nil {
  logger
}

fn logger(cb: fn(String) -> Nil) -> Nil {
  cb(\"x\")
}
",
      ),
      #(
        "app/main.gleam",
        "import gleam/io
import app/factory

pub fn run() -> Nil {
  let h = factory.pick()
  with_logger(h)
}

fn with_logger(action: fn(fn(String) -> Nil) -> Nil) -> Nil {
  action(io.println)
}
",
      ),
      #("app.graded", "check app/main.run : []\n"),
    ])

  let assert Ok(Nil) = graded.run_infer(directory)

  // The producer's returned operator is serialized into the spec.
  let assert Ok(spec) = simplifile.read(directory <> "/app.graded")
  string.contains(spec, "returns app/factory.pick : fn(cb) -> [cb]")
  |> should.be_true()

  // `check` re-resolves the consumer by loading that line, flagging main.run's
  // precise [Stdout] against the [] budget (it would be [Unknown] without it).
  let assert Ok(results) = graded.run(directory)
  let assert Ok(main_result) =
    list.find(results, fn(r) { string.ends_with(r.file, "app/main.gleam") })
  let assert [violation, ..] = main_result.violations
  violation.actual |> should.equal(Specific(set.from_list(["Stdout"])))

  cleanup(directory)
}

pub fn field_from_aliased_producer_call_resolves_test() {
  // Gaps A+B together (the girard motivating shape, same module): a record field
  // wired from a producer whose return type is a module-local alias to `fn(...)`.
  // Fix A generates the producer's summary; Fix B consumes it at the construction
  // site so the field call resolves to the producer's real effect, not [Unknown].
  let directory =
    make_fixture("both_gaps", [
      #("gleam.toml", "name = \"app\"\n"),
      #(
        "app/config.gleam",
        "import gleam/io

pub type Resolver = fn() -> Nil

pub type Options {
  Options(resolver: Resolver)
}

pub fn disk_resolver() -> Resolver {
  fn() { io.println(\"x\") }
}

pub fn default_options() -> Options {
  Options(resolver: disk_resolver())
}

pub fn use_resolver(o: Options) -> Nil {
  o.resolver()
}
",
      ),
      #("app.graded", "check app/config.use_resolver : []\n"),
    ])

  let assert Ok(Nil) = graded.run_infer(directory)
  let assert Ok(results) = graded.run(directory)
  let assert Ok(config_result) =
    list.find(results, fn(r) { string.ends_with(r.file, "app/config.gleam") })
  let assert [violation, ..] = config_result.violations
  violation.actual |> should.equal(Specific(set.from_list(["Stdout"])))
  cleanup(directory)
}

// Check auto-infers project modules missing from the spec
//
// `check` infers un-specced sibling modules in memory so cross-module calls
// resolve precisely without a prior `graded infer`.

pub fn check_auto_infers_missing_module_test() {
  // No prior `graded infer`: the spec has only a `check` line and no `effects`
  // for module `b`. `check` infers `b` in memory (topological order) so
  // `a.run`'s call into `b` resolves to the precise [Stdout] — not the
  // [Unknown] it would be if `check` trusted only the (empty) spec.
  let directory =
    make_fixture("check_autoinfer", [
      #("gleam.toml", "name = \"app\"\n"),
      #(
        "app/b.gleam",
        "import gleam/io

pub fn shout() -> Nil {
  io.println(\"x\")
}
",
      ),
      #(
        "app/a.gleam",
        "import app/b

pub fn run() -> Nil {
  b.shout()
}
",
      ),
      #("app.graded", "check app/a.run : []\n"),
    ])

  let assert Ok(results) = graded.run(directory)
  let assert Ok(a_result) =
    list.find(results, fn(r) { string.ends_with(r.file, "app/a.gleam") })
  let assert [violation, ..] = a_result.violations
  violation.actual |> should.equal(Specific(set.from_list(["Stdout"])))

  cleanup(directory)
}

// Spec-file externals are honoured during inference
//
// A project module that calls into a third-party package not in the catalog
// picks up the spec file's `external effects` line during `run_infer`, not
// fall back to `[Unknown]`. Pre-fix, externals were only consumed by `run`
// (check), so `infer` produced a noisy spec even when the user had already
// declared the dependency pure.

pub fn run_infer_honours_spec_file_externals_test() {
  let directory =
    make_fixture("externals_in_infer", [
      #(
        "app/main.gleam",
        "import dee/decimal

pub fn total(a: String, b: String) -> String {
  decimal.add(a, b)
}
",
      ),
    ])

  // Mirror the user's setup: spec file at <root>/<basename>.graded
  // declares the third-party module as pure via `external effects`.
  let spec_path = directory <> "/graded_topo_externals_in_infer.graded"
  let assert Ok(Nil) =
    simplifile.write(spec_path, "external effects dee/decimal : []\n")

  let assert Ok(Nil) = graded.run_infer(directory)

  // The crucial assertion: total is inferred as pure, not [Unknown].
  effects_of(
    read_inferred(directory <> "/build/.graded/app/main.graded"),
    "total",
  )
  |> should.equal(pure())

  cleanup(directory)
}

// Cross-module type constructors are pure
//
// Calls to a custom type constructor defined in a sibling project module are
// inferred as pure regardless of position — direct call, pipe target, or
// value reference — while side effects inside a constructor's argument list
// still propagate. All four positions run against one fixture and one
// `run_infer` invocation; each function name isolates the case.

pub fn cross_module_type_constructors_resolve_pure_test() {
  let directory =
    make_fixture("cross_module_constructors", [
      #(
        "myapp/types.gleam",
        "pub type MyError {
  NotFound(id: String)
}

pub type Logged {
  Logged(message: String)
}
",
      ),
      #(
        "myapp/service.gleam",
        "import gleam/io
import myapp/types

pub fn lookup(id: String) -> Result(Nil, types.MyError) {
  Error(types.NotFound(id))
}

pub fn pipe_lookup(id: String) -> types.MyError {
  id |> types.NotFound
}

pub fn make(message: String) -> types.Logged {
  io.println(message)
  types.Logged(message)
}

pub fn maker() -> fn(String) -> types.MyError {
  types.NotFound
}
",
      ),
    ])

  let assert Ok(Nil) = graded.run_infer(directory)

  let inferred =
    read_inferred(directory <> "/build/.graded/myapp/service.graded")

  // Direct call: types.NotFound(id) — pure.
  effects_of(inferred, "lookup") |> should.equal(pure())

  // Pipe target: id |> types.NotFound — pure.
  effects_of(inferred, "pipe_lookup") |> should.equal(pure())

  // Argument-list effects propagate even though the wrapping
  // constructor itself is pure.
  effects_of(inferred, "make") |> should.equal(with_labels(["Stdout"]))

  // Value position: types.NotFound used as a function reference.
  // Currently `references` aren't fed into inference, so this passes
  // pre-fix as well — kept to pin the contract if that ever changes.
  effects_of(inferred, "maker") |> should.equal(pure())

  cleanup(directory)
}

// Path dependencies
//
// Effects, specs, and return-value provenance must cross the path-dependency
// boundary: a dep is read from its committed spec or inferred from source,
// and the results reach the consuming project.

// Same regression class as the project chain test (deep transitive
// effects must propagate in one pass) but exercising the path-dep code
// path via the test-exposed `infer_path_dep`.
pub fn path_dep_chain_resolves_in_one_pass_test() {
  let dep_path =
    write_fixture("/tmp/graded_pathdep_chain", [
      #(
        "src/dep/d.gleam",
        "import gleam/io

pub fn shout(value: String) -> Nil {
  io.println(value)
}
",
      ),
      #(
        "src/dep/c.gleam",
        "import dep/d

pub fn transform(value: String) -> Nil {
  d.shout(value)
}
",
      ),
      #(
        "src/dep/b.gleam",
        "import dep/c

pub fn process(value: String) -> Nil {
  c.transform(value)
}
",
      ),
      #(
        "src/dep/a.gleam",
        "import dep/b

pub fn run(value: String) -> Nil {
  b.process(value)
}
",
      ),
    ])

  // load_knowledge_base from a missing dir falls back to the bundled
  // catalog (which has io.println marked [Stdout]) without any project
  // externals layered on. The manifest selects catalog versions.
  let base_kb =
    effects.load_knowledge_base("nonexistent_packages_dir", "manifest.toml")

  let assert Ok(#(inferred, _params, _returns, _provenance)) =
    graded.infer_path_dep(dep_path, base_kb, set.new())

  let assert Ok(d_effects) =
    dict.get(inferred, QualifiedName(module: "dep/d", function: "shout"))
  effect_term.to_effect_set(d_effects)
  |> should.equal(Specific(set.from_list(["Stdout"])))

  // Stdout propagates all the way through c -> b -> a in a single pass.
  let assert Ok(a_effects) =
    dict.get(inferred, QualifiedName(module: "dep/a", function: "run"))
  effect_term.to_effect_set(a_effects)
  |> should.equal(Specific(set.from_list(["Stdout"])))

  let _ = simplifile.delete(dep_path)
  Nil
}

// A path dependency declared with an ABSOLUTE `path` must resolve against that
// path as-is, not be re-rooted under the project directory. Exercises the
// gleam.toml-driven `enrich_with_path_deps` resolution end-to-end (unlike the
// chain test above, which calls `infer_path_dep` directly). The dep ships a
// spec marking `dep.shout : [Stdout]`; the app calls it, so the [] budget must
// fail with [Stdout] — a clobbered absolute path would not find the spec and
// the call would leak [Unknown].
pub fn run_resolves_absolute_path_dependency_test() {
  let dep_dir =
    write_fixture("/tmp/graded_pathdep_abs_dep", [
      #("gleam.toml", "name = \"dep\"\n"),
      #("dep.graded", "effects dep.shout : [Stdout]\n"),
      #(
        "src/dep.gleam",
        "import gleam/io\n\npub fn shout() -> Nil {\n  io.println(\"x\")\n}\n",
      ),
    ])
  let app_dir =
    write_fixture("/tmp/graded_pathdep_abs_app", [
      #(
        "gleam.toml",
        "name = \"app\"\n\n[dependencies]\ndep = { path = \""
          <> dep_dir
          <> "\" }\n",
      ),
      #("app.graded", "check src/main.run : []\n"),
      #(
        "src/main.gleam",
        "import dep\n\npub fn run() -> Nil {\n  dep.shout()\n}\n",
      ),
    ])

  let assert Ok(results) = graded.run(app_dir)
  let assert Ok(r) =
    list.find(results, fn(r) { string.ends_with(r.file, "src/main.gleam") })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "run" })
  v.actual |> should.equal(Specific(set.from_list(["Stdout"])))

  cleanup(dep_dir)
  cleanup(app_dir)
}

// A path dependency with no committed spec is inferred from source; its
// return-value provenance must reach the consumer so a computed-receiver call
// into the dep resolves. `dep.get_options` returns `config.options` (a `Path`
// provenance), so in `dep.inner(dep.get_options(Config(Options(resolver:
// resolver))))` the field bound `o.resolver` forwards through the getter onto
// the caller's own `resolver` parameter — the cross-package twin of the
// provenance_getter fixture. The `resolver: [Stdout]` bound then discharges to
// [Stdout] against the [] budget. Without threading provenance out of
// `infer_path_dep` the consumer never sees it and the call collapses to
// [Unknown].
pub fn run_resolves_path_dependency_provenance_test() {
  let dep_dir =
    write_fixture("/tmp/graded_pathdep_prov_dep", [
      #("gleam.toml", "name = \"dep\"\n"),
      #(
        "src/dep.gleam",
        "pub type Options {
  Options(resolver: fn() -> Nil)
}

pub type Config {
  Config(options: Options)
}

pub fn inner(o: Options) -> Nil {
  o.resolver()
}

pub fn get_options(config: Config) -> Options {
  config.options
}
",
      ),
    ])
  let app_dir =
    write_fixture("/tmp/graded_pathdep_prov_app", [
      #(
        "gleam.toml",
        "name = \"app\"\n\n[dependencies]\ndep = { path = \""
          <> dep_dir
          <> "\" }\n",
      ),
      #("app.graded", "check src/main.caller(resolver: [Stdout]) : []\n"),
      #(
        "src/main.gleam",
        "import dep

pub fn caller(resolver: fn() -> Nil) -> Nil {
  dep.inner(dep.get_options(dep.Config(options: dep.Options(resolver: resolver))))
}
",
      ),
    ])

  let assert Ok(results) = graded.run(app_dir)
  let assert Ok(r) =
    list.find(results, fn(r) { string.ends_with(r.file, "src/main.gleam") })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "caller" })
  v.actual |> should.equal(Specific(set.from_list(["Stdout"])))

  cleanup(dep_dir)
  cleanup(app_dir)
}

// Polymorphic end-to-end
//
// Effect-polymorphic functions resolve at call sites where the caller passes
// a pure type constructor, whether the argument is labelled or positional.

// Caller passes a pure type constructor to a fn-typed parameter.
// `validation.validate_range` should infer as polymorphic over its
// callback's effects, and `entity.new` should resolve to pure when
// the callback is a constructor.
pub fn polymorphic_constructor_resolves_to_pure_test() {
  let dir =
    make_fixture("polymorphic_constructor", [
      #("gleam.toml", "name = \"polyproj\"\nversion = \"0.0.0\"\n"),
      #(
        "validation.gleam",
        "pub fn validate_range(
  value: Int,
  to_error: fn(Int) -> error,
) -> List(error) {
  case value < 0 {
    True -> [to_error(value)]
    False -> []
  }
}
",
      ),
      #(
        "entity.gleam",
        "import validation

pub type MyError {
  OutOfRange(value: Int)
}

pub fn new(value: Int) -> List(MyError) {
  validation.validate_range(value, to_error: OutOfRange)
}
",
      ),
    ])

  let assert Ok(Nil) = graded.run_infer(dir)

  // Read the spec file and verify both annotations.
  let assert Ok(content) = simplifile.read(dir <> "/polyproj.graded")
  let assert Ok(file) = annotation.parse_file(content)
  let annotations = annotation.extract_annotations(file)

  // `validation.validate_range` should be polymorphic over `to_error`.
  let validate =
    list.find(annotations, fn(ann) {
      ann.function == "validation.validate_range"
    })
  let assert Ok(v) = validate
  effect_term.to_effect_set(v.effects)
  |> should.equal(Polymorphic(set.new(), set.from_list(["to_error"])))

  // `entity.new` should have resolved the variable — OutOfRange is a
  // constructor, so the substitution yields [].
  let new_fn = list.find(annotations, fn(ann) { ann.function == "entity.new" })
  let assert Ok(n) = new_fn
  effect_term.to_effect_set(n.effects) |> should.equal(Specific(set.new()))

  let _ = simplifile.delete(dir)
  Nil
}

// Same shape as `polymorphic_constructor_resolves_to_pure_test` but
// the caller passes the constructor positionally — no `to_error:`
// label. The signature registry tells the checker that parameter 1
// of `validate_range` is named `to_error`, so positional argument 1
// still binds the effect variable.
pub fn polymorphic_constructor_resolves_positional_test() {
  let dir =
    make_fixture("polymorphic_positional", [
      #("gleam.toml", "name = \"polyproj_pos\"\nversion = \"0.0.0\"\n"),
      #(
        "validation.gleam",
        "pub fn validate_range(
  value: Int,
  to_error: fn(Int) -> error,
) -> List(error) {
  case value < 0 {
    True -> [to_error(value)]
    False -> []
  }
}
",
      ),
      #(
        "entity.gleam",
        "import validation

pub type MyError {
  OutOfRange(value: Int)
}

pub fn new(value: Int) -> List(MyError) {
  validation.validate_range(value, OutOfRange)
}
",
      ),
    ])

  let assert Ok(Nil) = graded.run_infer(dir)

  let assert Ok(content) = simplifile.read(dir <> "/polyproj_pos.graded")
  let assert Ok(file) = annotation.parse_file(content)
  let annotations = annotation.extract_annotations(file)

  let new_fn = list.find(annotations, fn(ann) { ann.function == "entity.new" })
  let assert Ok(n) = new_fn
  effect_term.to_effect_set(n.effects) |> should.equal(Specific(set.new()))

  let _ = simplifile.delete(dir)
  Nil
}

// Dense mutual recursion (memoization regression guard)
//
// A dense strongly-connected component with exponentially many simple paths
// must infer without blowup while still propagating the leaf effect around
// the ring.

// Build a module of `count` mutually-recursive first-order functions forming
// one dense strongly-connected component: `p_i` calls `p_{i+1}` (a ring) and
// `p_{i+7}` (a chord), indices wrapping. `p0` calls `io.println`, so every
// function — each reachable from every other around the ring — must infer
// `[Stdout]`. The branching ring has exponentially many simple paths, so
// before memoization a single `infer` re-walked each callee per path and blew
// up; this fixture would hang. It also pins the cycle-truncation correctness
// the memo must preserve: `p10` reaches `p0`'s effect only by going around the
// ring, so a memo that cached a path-truncated result would drop its `Stdout`.
fn dense_scc_module(count: Int) -> String {
  let body =
    indices(count)
    |> list.map(fn(i) {
      let ring = "p" <> int.to_string({ i + 1 } % count)
      let chord = "p" <> int.to_string({ i + 7 } % count)
      let prefix = case i {
        0 -> "  io.println(\"leaf\")\n"
        _ -> ""
      }
      "pub fn p"
      <> int.to_string(i)
      <> "(n: Int) -> Int {\n"
      <> prefix
      <> "  "
      <> ring
      <> "(n) + "
      <> chord
      <> "(n)\n}\n"
    })
    |> string.join("\n")
  "import gleam/io\n\n" <> body
}

pub fn dense_mutual_recursion_infers_without_blowup_test() {
  let count = 24
  let directory =
    make_fixture("dense_scc", [#("dense.gleam", dense_scc_module(count))])

  // The crucial assertion is simply that this returns at all: without per-module
  // memoization the dense SCC's exponentially-many paths make inference hang.
  let assert Ok(Nil) = graded.run_infer(directory)

  let inferred = read_inferred(directory <> "/build/.graded/dense.graded")
  let stdout = with_labels(["Stdout"])

  // `p0` holds the effect directly.
  effects_of(inferred, "p0") |> should.equal(stdout)
  // `p10` reaches it only through the ring back to `p0` — the truncation case.
  effects_of(inferred, "p10") |> should.equal(stdout)
  // Every member of the SCC sees the effect.
  indices(count)
  |> list.each(fn(i) {
    effects_of(inferred, "p" <> int.to_string(i)) |> should.equal(stdout)
  })

  cleanup(directory)
}

// `[0, 1, …, count-1]` — a local stand-in for `list.range`, which this
// stdlib version lacks.
fn indices(count: Int) -> List(Int) {
  indices_loop(count - 1, [])
}

fn indices_loop(n: Int, acc: List(Int)) -> List(Int) {
  case n < 0 {
    True -> acc
    False -> indices_loop(n - 1, [n, ..acc])
  }
}

// Out-of-tree project root resolution
//
// `infer` against a source directory whose project root is an ancestor (where
// `gleam.toml` lives) must write the spec and cache under that root, not under
// the passed source directory. Pre-fix, a non-"src" source argument was
// treated as the project root itself, scattering `src/src.graded` and
// `src/build/` into the wrong place with the wrong package name.

pub fn infer_roots_spec_at_nearest_gleam_toml_test() {
  let root =
    write_fixture("/tmp/graded_outoftree_root", [
      stdlib_manifest(),
      #("gleam.toml", "name = \"myproj\"\n"),
      #(
        "src/app.gleam",
        "import gleam/string

pub fn shout(value: String) -> String {
  string.uppercase(value)
}
",
      ),
    ])

  let assert Ok(Nil) = graded.run_infer(root <> "/src")

  // Spec lands at the project root under the package name from gleam.toml.
  simplifile.is_file(root <> "/myproj.graded")
  |> should.equal(Ok(True))
  // Not under the source directory with the basename-derived "src" name.
  simplifile.is_file(root <> "/src/src.graded")
  |> should.equal(Ok(False))

  // Cache lands under the project root, not the source directory.
  simplifile.is_directory(root <> "/build/.graded")
  |> should.equal(Ok(True))
  simplifile.is_directory(root <> "/src/build")
  |> should.equal(Ok(False))

  // Inference actually ran: the pure function reads back as pure.
  effects_of(read_inferred(root <> "/build/.graded/app.graded"), "shout")
  |> should.equal(pure())

  cleanup(root)
}
