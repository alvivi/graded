// Tests for the Lustre 5 catalog entries, the lint over the bundled catalog's
// own file names, and the spec-annotation lint that warns on `check`/`type`
// lines whose target exists nowhere in the project.
//
// Like the topo tests, fixtures are materialised under `/tmp/` so the Gleam
// compiler doesn't try to compile them as project modules. The file-name lint
// is the exception: it reads the real `priv/catalog/`.

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
  type EffectSet, type Warning, Specific, UnkeyedEffectsShapeWarning,
  UnknownClauseWarning, UnmatchedCheckWarning, UnmatchedFieldAssumeWarning,
  UnverifiedCheckShapeWarning,
}
import simplifile
import support.{cleanup, write_fixture}

// Helpers
//
// Fixture-project scaffolding shared by all tests below: materialise a project
// under `/tmp/`, run the checker or inferrer, and read back warnings or
// inferred effects.

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
  let assert Ok(results) = graded.check_project(directory)
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
//
// The catalog entries for Lustre 5: app constructors are pure while the
// runtime functions that mount an app carry their real effects.

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

// Spec-annotation lint
//
// The lint that warns on `check`/`assume` lines whose target exists nowhere in
// the project: unqualified or misspelled names are flagged, while targets that
// resolve — including through dependencies and function-type aliases — are not.

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
      #("app.graded", "assume Opts.on_change : []\ncheck run : []\n"),
    ])

  expect_warning(warnings, UnmatchedFieldAssumeWarning(name: "Opts.on_change"))
  expect_warning(warnings, UnmatchedCheckWarning(function: "run"))
}

// A `check` whose subject is a field parses and keys nothing. Read as a
// function name it would be a typo; read by shape it is a shape no verification
// covers yet.
pub fn a_field_shaped_check_warns_about_its_shape_test() {
  let warnings =
    lint_warnings("check_shape", [
      #("opts.gleam", opts_module),
      #("app.graded", "check opts.Opts.on_change : []\n"),
    ])

  expect_warning(
    warnings,
    UnverifiedCheckShapeWarning(name: "opts.Opts.on_change"),
  )
  refute_warning(
    warnings,
    UnmatchedCheckWarning(function: "opts.Opts.on_change"),
  )
}

// The same mistake one tier over, in all three spellings. An `effects` line
// only ever keys `module.function`, so a field path — qualified or with its
// module implied by the type — and a bare module path are lines no run can
// read, and `infer`, which rewrites this tier from source, deletes them
// without a word. One fixture, since the three lines are read by one pass.
pub fn a_field_or_module_shaped_effects_line_warns_about_its_shape_test() {
  let warnings =
    lint_warnings("effects_shape", [
      #("opts.gleam", opts_module),
      #(
        "app.graded",
        "effects opts.Opts.on_change : []\neffects Opts.on_change : []\neffects opts : []\n",
      ),
    ])

  expect_warning(
    warnings,
    UnkeyedEffectsShapeWarning(name: "opts.Opts.on_change"),
  )
  // The spelling the segment count alone cannot tell from a function: read as
  // `module.function` it names a module `Opts`, which no Gleam module is.
  expect_warning(warnings, UnkeyedEffectsShapeWarning(name: "Opts.on_change"))
  expect_warning(warnings, UnkeyedEffectsShapeWarning(name: "opts"))
}

// The line the shape lint must not draw. A dangling function path is stale, not
// malformed: this tier is regenerated from source on every `infer`, so a line
// outliving its function is the tier working as designed, and warning about it
// would fire on every renamed function until the next `infer`.
pub fn a_dangling_effects_line_is_not_a_shape_warning_test() {
  let warnings =
    lint_warnings("effects_shape_dangling", [
      #("opts.gleam", opts_module),
      #("app.graded", "effects opts.ghost : []\n"),
    ])

  refute_warning(warnings, UnkeyedEffectsShapeWarning(name: "opts.ghost"))
}

pub fn qualified_check_and_type_lines_do_not_warn_test() {
  lint_warnings("clean", [
    #("opts.gleam", opts_module),
    #(
      "app.graded",
      "assume opts.Opts.on_change : []\ncheck opts.run : [Stdout]\n",
    ),
  ])
  |> should.equal([])
}

// Unknown clause keys
//
// A clause key this version does not read parses, is retained, and warns —
// once per line, all its keys together, so one future line is not noisy. The
// warning belongs to the project-spec lint, so a dependency's spec stays
// silent: its consumer cannot fix it.

pub fn an_unknown_clause_key_warns_once_per_line_test() {
  let warnings =
    lint_warnings("unknown_clause", [
      #("opts.gleam", "pub fn run() -> Nil {\n  Nil\n}\n"),
      #(
        "app.graded",
        "check opts.run : [] where future : [X], raises : [Y]
assume dep/x where returns.0 : [Net]
",
      ),
    ])

  expect_warning(
    warnings,
    UnknownClauseWarning(path: "opts.run", keys: ["future", "raises"]),
  )
  expect_warning(
    warnings,
    UnknownClauseWarning(path: "dep/x", keys: ["returns.0"]),
  )
}

pub fn a_dependency_spec_unknown_clause_is_silent_test() {
  let root =
    support.write_project_with_dependency(
      directory: "/tmp/graded_release_dep_unknown_clause",
      package: "proj",
      spec: "check proj.caller : []\n",
      sources: [
        #(
          "proj.gleam",
          "import dep/store\n\npub fn caller() -> Nil {\n  store.insert()\n}\n",
        ),
      ],
      dependency: "dep",
      dependency_spec: "assume dep/store.insert : [] where future : [X]\n",
      dependency_sources: [
        #(
          "dep/store.gleam",
          "@external(erlang, \"dep_ffi\", \"insert\")\npub fn insert() -> Nil\n",
        ),
      ],
    )
  let assert Ok(results) = graded.check_project(root)
  let warnings = list.flat_map(results, fn(r) { r.warnings })
  cleanup(root)

  list.any(warnings, fn(warning) {
    case warning {
      UnknownClauseWarning(..) -> True
      _ -> False
    }
  })
  |> should.be_false()
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
      #("app.graded", "assume opts.Opts.gone : []\ncheck opts.missing : []\n"),
    ])

  expect_warning(warnings, UnmatchedFieldAssumeWarning(name: "opts.Opts.gone"))
  expect_warning(warnings, UnmatchedCheckWarning(function: "opts.missing"))
}

// A field `assume` line qualified at an *installed* dependency module names a field
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
    #("app.graded", "assume widgets/ui.Config.on_click : [Dom]\n"),
  ])
  |> refute_warning(UnmatchedFieldAssumeWarning(
    name: "widgets/ui.Config.on_click",
  ))
}

// A field `assume` line qualified at a module that is neither a project module nor an
// installed/path dependency is a typo — it resolves nothing, so it's flagged.
pub fn unknown_module_qualifier_warns_test() {
  // `optz` is a typo of the project module `opts`.
  lint_warnings("unknown_mod", [
    #(
      "opts.gleam",
      "pub type Opts {\n  Opts(on_change: fn(String) -> Nil)\n}\n",
    ),
    #("app.graded", "assume optz.Opts.on_change : []\n"),
  ])
  |> expect_warning(UnmatchedFieldAssumeWarning(name: "optz.Opts.on_change"))
}

// A field declared through a module-local function alias (`callback: Handler`
// with `type Handler = fn(...)`) is callable, so its field `assume` line is a valid
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
    #("app.graded", "assume widget.Widget.callback : [Dom]\n"),
  ])
  |> refute_warning(UnmatchedFieldAssumeWarning(name: "widget.Widget.callback"))
}

// A field typed with a function alias imported from another project module
// (`callback: handlers.Handler`) is callable, so its field `assume` line is valid and
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
    #("app.graded", "assume widget.Widget.callback : [Dom]\n"),
  ])
  |> refute_warning(UnmatchedFieldAssumeWarning(name: "widget.Widget.callback"))
}

// A module-local alias that delegates to an imported alias
// (`type LocalHandler = handlers.Handler`) still resolves to a function, so a
// field typed `LocalHandler` is callable and its field `assume` line must not warn.
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
    #("app.graded", "assume widget.Widget.callback : [Dom]\n"),
  ])
  |> refute_warning(UnmatchedFieldAssumeWarning(name: "widget.Widget.callback"))
}

// A field whose type is a non-function type owned by an installed dependency
// (`value: types.Record`) genuinely can't be called, so its field `assume` line is dead
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
    #("app.graded", "assume widget.Widget.value : []\n"),
  ])
  |> expect_warning(UnmatchedFieldAssumeWarning(name: "widget.Widget.value"))
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
    #("app.graded", "assume widget.Widget.callback : [Dom]\n"),
  ])
  |> refute_warning(UnmatchedFieldAssumeWarning(name: "widget.Widget.callback"))
}

// A field `assume` line on a project type whose field isn't function-typed can never
// resolve a field call, so it's dead and must be flagged — the lint shouldn't
// treat a plain data field as a valid target.
pub fn non_function_field_annotation_warns_test() {
  lint_warnings("nonfn", [
    #("rec.gleam", "pub type Rec {\n  Rec(count: Int)\n}\n"),
    #("app.graded", "assume rec.Rec.count : []\n"),
  ])
  |> expect_warning(UnmatchedFieldAssumeWarning(name: "rec.Rec.count"))
}

// Bundled catalog file names
//
// Every bundled file is named `{package}@{major.minor.patch}.graded`. A name
// that does not split that way is dropped before it can be selected, and a
// version selection cannot order is one whose file wins on directory order
// rather than on the version it declares.

pub fn every_catalog_file_names_a_package_and_a_version_test() {
  let assert Ok(paths) = simplifile.get_files(effects.catalog_directory())
  paths
  |> list.filter(string.ends_with(_, ".graded"))
  |> list.filter_map(malformed_catalog_name)
  |> should.equal([])
}

// The complaint about one file name, or `Error(Nil)` for a name that reads as a
// package and a `major.minor.patch` version — the shape `bundled_catalog_files`
// keeps and `parse_semver` compares. A pre-release or build suffix is not one:
// selection compares the version prefix alone, so the suffix would name a file
// nothing distinguishes from its release.
fn malformed_catalog_name(path: String) -> Result(String, Nil) {
  let name = path |> filepath.base_name |> filepath.strip_extension
  case string.split(name, "@") {
    [_package, version] ->
      case list.try_map(string.split(version, "."), int.parse) {
        Ok([major, minor, patch]) if #(major, minor, patch) != #(0, 0, 0) ->
          Error(Nil)
        Ok(_) | Error(Nil) ->
          Ok(
            path
            <> " names the version `"
            <> version
            <> "`, which is not a `major.minor.patch` above 0.0.0. Version "
            <> "selection compares those three numbers, so it cannot place "
            <> "this file. Rename it.",
          )
      }
    _ ->
      Ok(
        path
        <> " is not named `{package}@{version}.graded`, so no package claims "
        <> "it and it is never selected. Rename it or drop it.",
      )
  }
}

// A bundled file that stops parsing is skipped at runtime, voiding that
// package's effects with a green suite: only two packages have content tests.
pub fn every_catalog_file_parses_test() {
  let assert Ok(paths) = simplifile.get_files(effects.catalog_directory())
  paths
  |> list.filter(string.ends_with(_, ".graded"))
  |> list.filter_map(unparseable_catalog_file)
  |> should.equal([])
}

// The complaint about one bundled file, or `Error(Nil)` for one that reads and
// parses.
fn unparseable_catalog_file(path: String) -> Result(String, Nil) {
  case simplifile.read(path) {
    Error(_) -> Ok(path <> " could not be read.")
    Ok(content) ->
      case annotation.parse_file(content) {
        Ok(_) -> Error(Nil)
        Error(error) ->
          Ok(
            path
            <> " does not parse at line "
            <> annotation.describe_parse_error(error)
            <> ". Its package resolves to [Unknown] for every consumer.",
          )
      }
  }
}

pub fn no_two_catalog_files_parse_to_one_version_test() {
  let assert Ok(files) =
    effects.bundled_catalog_files(effects.catalog_directory())
  colliding_catalog_files(files) |> should.equal([])
}

// One message per group of bundled files that parse to the same version, so a
// failure names the files a contributor has to fix.
fn colliding_catalog_files(files: List(effects.CatalogFile)) -> List(String) {
  files
  |> list.group(fn(file) { #(file.package, file.parsed) })
  |> dict.values
  |> list.filter_map(fn(group) {
    case group {
      [_] | [] -> Error(Nil)
      [_, _, ..] -> Ok(collision_message(group))
    }
  })
}

fn collision_message(group: List(effects.CatalogFile)) -> String {
  group
  |> list.map(fn(file) { file.path })
  |> list.sort(string.compare)
  |> string.join(" and ")
  <> " parse to the same major.minor.patch; version selection cannot order "
  <> "them, so which one wins is filesystem order. Give one a distinct "
  <> "version or drop it."
}
