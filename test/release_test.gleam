// Tests for the Lustre 5 catalog entries and the spec-annotation lint that
// warns on `check`/`type` lines whose target exists nowhere in the project.
//
// Like the topo tests, fixtures are materialised under `/tmp/` so the Gleam
// compiler doesn't try to compile them as project modules.

import gleam/list
import gleam/set
import gleam/string
import gleeunit/should
import graded
import graded/internal/annotation
import graded/internal/effect_term
import graded/internal/types.{
  type EffectSet, type Warning, Specific, UnmatchedCheckWarning,
  UnmatchedTypeFieldWarning,
}
import simplifile

// helpers

fn write_fixture(directory: String, files: List(#(String, String))) -> String {
  let _ = simplifile.delete(directory)
  list.each(files, fn(entry) {
    let #(relative_path, contents) = entry
    let full_path = directory <> "/" <> relative_path
    let segments = string.split(full_path, "/")
    let parent =
      segments
      |> list.take(list.length(segments) - 1)
      |> string.join("/")
    let assert Ok(_) = simplifile.create_directory_all(parent)
    let assert Ok(Nil) = simplifile.write(full_path, contents)
  })
  directory
}

fn cleanup(directory: String) -> Nil {
  let _ = simplifile.delete(directory)
  Nil
}

// A fixture project must carry its own `gleam.toml` so package-root resolution
// stops at the fixture (and reads the fixture's `manifest.toml`) instead of
// walking up to the real project root. The spec file is then `app.graded`.
fn project_files() -> List(#(String, String)) {
  [
    #("gleam.toml", "name = \"app\"\nversion = \"1.0.0\"\n"),
    #(
      "manifest.toml",
      "packages = [
  { name = \"lustre\", version = \"5.7.0\" },
]
",
    ),
  ]
}

// Materialise a fixture project (with `project_files()` plus `files`), run the
// checker, and return the collected spec-lint warnings. The fixture is removed
// before returning, so assertions run against the warnings alone.
fn lint_warnings(
  name: String,
  files: List(#(String, String)),
) -> List(Warning) {
  let directory =
    write_fixture(
      "/tmp/graded_release_" <> name,
      list.append(project_files(), files),
    )
  let assert Ok(results) = graded.run(directory)
  let warnings = list.flat_map(results, fn(r) { r.warnings })
  cleanup(directory)
  warnings
}

fn expect_warning(warnings: List(Warning), warning: Warning) -> Nil {
  list.contains(warnings, warning)
  |> should.be_true
}

fn refute_warning(warnings: List(Warning), warning: Warning) -> Nil {
  list.contains(warnings, warning)
  |> should.be_false
}

fn read_inferred_effect(graded_path: String, function: String) -> EffectSet {
  let assert Ok(content) = simplifile.read(graded_path)
  let assert Ok(file) = annotation.parse_file(content)
  let assert Ok(ann) =
    list.find(annotation.extract_annotations(file), fn(a) {
      a.function == function
    })
  effect_term.to_effect_set(ann.effects)
}

fn pure() -> EffectSet {
  Specific(set.new())
}

fn labels(xs: List(String)) -> EffectSet {
  Specific(set.from_list(xs))
}

// Lustre 5 catalog

pub fn lustre5_constructors_are_pure_test() {
  let directory =
    write_fixture(
      "/tmp/graded_release_lustre",
      list.append(project_files(), [
        #(
          "ui.gleam",
          "import lustre

pub fn app() {
  lustre.application(init, update, view)
}

pub fn comp() {
  lustre.component(init, update, view, options)
}

pub fn mount() {
  lustre.start(app(), \"#app\", Nil)
}

fn init(_flags) {
  0
}

fn update(model, _msg) {
  model
}

fn view(_model) {
  0
}

fn options() {
  []
}
",
        ),
      ]),
    )

  let assert Ok(Nil) = graded.run_infer(directory)
  let cache = directory <> "/build/.graded/ui.graded"

  read_inferred_effect(cache, "app")
  |> should.equal(pure())

  read_inferred_effect(cache, "comp")
  |> should.equal(pure())

  // The effectful runtime functions still carry their effects.
  read_inferred_effect(cache, "mount")
  |> should.equal(labels(["Dom", "Process"]))

  cleanup(directory)
}

// spec-annotation lint

const opts_module = "import gleam/io

pub type Opts {
  Opts(on_change: fn(String) -> Nil)
}

pub fn run(o: Opts) -> Nil {
  io.println(\"log\")
  o.on_change(\"x\")
}
"

pub fn unqualified_check_and_type_lines_warn_test() {
  // Both lines are unqualified — the exact mistake from the field report.
  let warnings =
    lint_warnings("lint", [
      #("opts.gleam", opts_module),
      #("app.graded", "type Opts.on_change : []\ncheck run : []\n"),
    ])

  expect_warning(warnings, UnmatchedTypeFieldWarning(name: "Opts.on_change"))
  expect_warning(warnings, UnmatchedCheckWarning(function: "run"))
}

pub fn qualified_check_and_type_lines_do_not_warn_test() {
  lint_warnings("clean", [
    #("opts.gleam", opts_module),
    #(
      "app.graded",
      "type opts.Opts.on_change : []\ncheck opts.run : [Stdout]\n",
    ),
  ])
  |> should.equal([])
}

pub fn mismatched_qualifier_warns_test() {
  // `opts` is a project module: `gone` is no field of `Opts`, and `missing` is
  // no function of the module.
  let warnings =
    lint_warnings("typo", [
      #(
        "opts.gleam",
        "pub type Opts {\n  Opts(on_change: fn(String) -> Nil)\n}\n",
      ),
      #("app.graded", "type opts.Opts.gone : []\ncheck opts.missing : []\n"),
    ])

  expect_warning(warnings, UnmatchedTypeFieldWarning(name: "opts.Opts.gone"))
  expect_warning(warnings, UnmatchedCheckWarning(function: "opts.missing"))
}

// A `type` line qualified at an *installed* dependency module names a field
// graded can't introspect (the type isn't a project type), but girard still
// resolves it from the receiver's nominal type — so it must not be flagged.
pub fn dependency_type_field_does_not_warn_test() {
  lint_warnings("dep_type", [
    #("app_mod.gleam", "pub fn render() -> Nil {\n  Nil\n}\n"),
    // A real installed dependency (under build/packages) owning the type.
    #(
      "build/packages/widgets/src/widgets/ui.gleam",
      "pub type Config {\n  Config(on_click: fn() -> Nil)\n}\n",
    ),
    #("app.graded", "type widgets/ui.Config.on_click : [Dom]\n"),
  ])
  |> refute_warning(UnmatchedTypeFieldWarning(
    name: "widgets/ui.Config.on_click",
  ))
}

// A `type` line qualified at a module that is neither a project module nor an
// installed/path dependency is a typo — it resolves nothing, so it's flagged.
pub fn unknown_module_qualifier_warns_test() {
  // `optz` is a typo of the project module `opts`.
  lint_warnings("unknown_mod", [
    #(
      "opts.gleam",
      "pub type Opts {\n  Opts(on_change: fn(String) -> Nil)\n}\n",
    ),
    #("app.graded", "type optz.Opts.on_change : []\n"),
  ])
  |> expect_warning(UnmatchedTypeFieldWarning(name: "optz.Opts.on_change"))
}

// A field declared through a module-local function alias (`callback: Handler`
// with `type Handler = fn(...)`) is callable, so its `type` line is a valid
// target and must not be flagged.
pub fn function_alias_field_does_not_warn_test() {
  lint_warnings("alias", [
    #(
      "widget.gleam",
      "pub type Handler =
  fn(String) -> Nil

pub type Widget {
  Widget(callback: Handler)
}
",
    ),
    #("app.graded", "type widget.Widget.callback : [Dom]\n"),
  ])
  |> refute_warning(UnmatchedTypeFieldWarning(name: "widget.Widget.callback"))
}

// A field typed with a function alias imported from another project module
// (`callback: handlers.Handler`) is callable, so its `type` line is valid and
// must not be flagged — the qualified alias is resolved across modules.
pub fn qualified_function_alias_field_does_not_warn_test() {
  lint_warnings("qual_alias", [
    #("handlers.gleam", "pub type Handler =\n  fn(String) -> Nil\n"),
    #(
      "widget.gleam",
      "import handlers

pub type Widget {
  Widget(callback: handlers.Handler)
}
",
    ),
    #("app.graded", "type widget.Widget.callback : [Dom]\n"),
  ])
  |> refute_warning(UnmatchedTypeFieldWarning(name: "widget.Widget.callback"))
}

// A module-local alias that delegates to an imported alias
// (`type LocalHandler = handlers.Handler`) still resolves to a function, so a
// field typed `LocalHandler` is callable and its `type` line must not warn.
pub fn alias_chain_through_imported_alias_does_not_warn_test() {
  lint_warnings("alias_chain", [
    #("handlers.gleam", "pub type Handler =\n  fn(String) -> Nil\n"),
    #(
      "widget.gleam",
      "import handlers

pub type LocalHandler =
  handlers.Handler

pub type Widget {
  Widget(callback: LocalHandler)
}
",
    ),
    #("app.graded", "type widget.Widget.callback : [Dom]\n"),
  ])
  |> refute_warning(UnmatchedTypeFieldWarning(name: "widget.Widget.callback"))
}

// A field whose type is a non-function type owned by an installed dependency
// (`value: types.Record`) genuinely can't be called, so its `type` line is dead
// and must be flagged — graded parses the dependency to confirm.
pub fn dependency_non_function_field_warns_test() {
  lint_warnings("dep_nonfn", [
    #(
      "build/packages/dep/src/dep/types.gleam",
      "pub type Record {\n  Record(x: Int)\n}\n",
    ),
    #(
      "widget.gleam",
      "import dep/types

pub type Widget {
  Widget(value: types.Record)
}
",
    ),
    #("app.graded", "type widget.Widget.value : []\n"),
  ])
  |> expect_warning(UnmatchedTypeFieldWarning(name: "widget.Widget.value"))
}

// The dependency counterpart of the project case: a field typed with a
// *function* alias from an installed dependency stays callable, so it must not
// warn even though graded had to parse the dependency to tell.
pub fn dependency_function_alias_field_does_not_warn_test() {
  lint_warnings("dep_fn_alias", [
    #(
      "build/packages/dep/src/dep/types.gleam",
      "pub type Handler =\n  fn(String) -> Nil\n",
    ),
    #(
      "widget.gleam",
      "import dep/types

pub type Widget {
  Widget(callback: types.Handler)
}
",
    ),
    #("app.graded", "type widget.Widget.callback : [Dom]\n"),
  ])
  |> refute_warning(UnmatchedTypeFieldWarning(name: "widget.Widget.callback"))
}

// A `type` line on a project type whose field isn't function-typed can never
// resolve a field call, so it's dead and must be flagged — the lint shouldn't
// treat a plain data field as a valid target.
pub fn non_function_field_annotation_warns_test() {
  lint_warnings("nonfn", [
    #("rec.gleam", "pub type Rec {\n  Rec(count: Int)\n}\n"),
    #("app.graded", "type rec.Rec.count : []\n"),
  ])
  |> expect_warning(UnmatchedTypeFieldWarning(name: "rec.Rec.count"))
}
