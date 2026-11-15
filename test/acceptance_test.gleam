// The answers the bundled catalog's published contracts give, shape by shape:
// a project that installs the standard library and lustre 5.7.1, whose catalog
// files and audit records cover both.

import gleam/list
import gleam/string
import gleeunit/should
import graded
import support

const lustre_effect =
  "pub type Effect(message)

@external(erlang, \"lustre_effect\", \"from\")
pub fn from(effect: fn(fn(message) -> Nil) -> Nil) -> Effect(message)
"

const lustre_root =
  "import lustre/effect.{type Effect}

pub type App(start_args, model, message)

pub type Element(message)

pub type Error

@external(erlang, \"lustre\", \"application\")
pub fn application(
  init init: fn(start_args) -> #(model, Effect(message)),
  update update: fn(model, message) -> #(model, Effect(message)),
  view view: fn(model) -> Element(message),
) -> App(start_args, model, message)

@external(erlang, \"lustre\", \"start\")
pub fn start(
  app: App(start_args, model, message),
  onto selector: String,
  with arguments: start_args,
) -> Result(Nil, Error)
"

const app_source =
  "import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/io
import gleam/list
import gleam/string
import lustre
import lustre/effect

pub type Config {
  Config(on_item: fn(String) -> Nil)
}

fn loud() -> Nil {
  io.println(\"loud\")
}

fn quiet() -> Nil {
  Nil
}

pub fn inline_callback_effect() {
  effect.from(fn(dispatch) {
    io.println(\"x\")
    dispatch(Nil)
  })
}

fn callback(dispatch: fn(Nil) -> Nil) -> Nil {
  io.println(\"x\")
  dispatch(Nil)
}

pub fn named_callback_effect() {
  effect.from(callback)
}

pub fn list_relayed_and_called() -> Nil {
  list.each([loud], fn(f) { f() })
}

pub fn list_relayed_but_ignored() -> Nil {
  list.each([loud], fn(_) { Nil })
}

pub fn printer_relayed_and_called() -> Nil {
  list.each([io.println], fn(f) { f(\"x\") })
}

pub fn printer_as_the_callback() -> Nil {
  list.each([\"x\"], io.println)
}

pub fn callback_calling_a_printer() -> Nil {
  list.each([1], fn(_) { loud() })
}

pub fn inspected_type_variable(x: a) -> String {
  string.inspect(x)
}

pub fn decoder_with_inline_continuation(data: Dynamic) {
  decode.run(
    data,
    decode.field(\"a\", decode.int, fn(a) {
      io.println(\"x\")
      decode.success(a)
    }),
  )
}

pub fn decoder_returning_a_captured_decoder(data: Dynamic) {
  let inner =
    decode.field(\"b\", decode.int, fn(b) {
      io.println(\"x\")
      decode.success(b)
    })
  decode.run(data, decode.field(\"a\", decode.int, fn(_a) { inner }))
}

fn wrap(decoder: decode.Decoder(Int)) -> decode.Decoder(Int) {
  decoder
}

pub fn decoder_returning_an_untraced_decoder(data: Dynamic) {
  let inner =
    wrap(
      decode.field(\"b\", decode.int, fn(b) {
        io.println(\"x\")
        decode.success(b)
      }),
    )
  decode.run(data, decode.field(\"a\", decode.int, fn(_a) { inner }))
}

fn get_loud() -> fn() -> Nil {
  loud
}

// `no_such_value` names nothing, so the type inference skips each
// function that reads it.
pub fn untyped_alias_relayed() -> Nil {
  let f = loud
  let _ = no_such_value
  list.each([f], fn(g) { g() })
}

pub fn untyped_call_result_relayed() -> Nil {
  let _ = no_such_value
  list.each([get_loud()], fn(g) { g() })
}

fn next_fn(a: Int) -> decode.Decoder(Int) {
  io.println(\"x\")
  decode.success(a)
}

pub fn decoder_with_named_continuation(data: Dynamic) {
  decode.run(data, decode.field(\"a\", decode.int, next_fn))
}

fn init(_flags: Nil) -> #(Int, effect.Effect(Nil)) {
  #(0, effect.from(fn(_dispatch) { Nil }))
}

fn update(model: Int, _message: Nil) -> #(Int, effect.Effect(Nil)) {
  #(model, effect.from(fn(_dispatch) { Nil }))
}

fn view(_model: Int) -> lustre.Element(Nil) {
  view(0)
}

pub fn application_of_pure_callbacks() {
  lustre.application(init, update, view)
}

pub fn started_application() {
  lustre.start(application_of_pure_callbacks(), \"#app\", Nil)
}

fn step(acc: fn() -> Nil, _x: Int) -> fn() -> Nil {
  acc()
  loud
}

pub fn fold_step_calling_its_accumulator() -> Nil {
  let _ = list.fold([1, 2], quiet, step)
  Nil
}

pub fn parameter_field_relayed(cfg: Config) -> Nil {
  list.each([\"x\"], cfg.on_item)
}

pub fn built_field_relayed() -> Nil {
  let cfg = Config(on_item: io.println)
  list.each([\"x\"], cfg.on_item)
}
"

fn lines() -> List(String) {
  let root =
    support.write_fixture("build/acceptance_shapes", [
      #("gleam.toml", "name = \"app\"\nversion = \"1.0.0\"\n"),
      #(
        "manifest.toml",
        "packages = [
  { name = \"gleam_stdlib\", version = \"1.0.5\" },
  { name = \"lustre\", version = \"5.7.1\" },
]
",
      ),
      #(
        "build/packages/packages.toml",
        "[packages]\ngleam_stdlib = \"1.0.5\"\nlustre = \"5.7.1\"\n",
      ),
      #(
        "build/packages/lustre/gleam.toml",
        "name = \"lustre\"\nversion = \"5.7.1\"\n",
      ),
      #("build/packages/lustre/src/lustre.gleam", lustre_root),
      #("build/packages/lustre/src/lustre/effect.gleam", lustre_effect),
      #("src/app.gleam", app_source),
    ])
  support.install_stdlib(root)
  let assert Ok(lines) = graded.inferred_lines(root)
  support.cleanup(root)
  lines
}

fn answer(lines: List(String), function: String) -> String {
  let prefix = "effects app." <> function
  let assert Ok(line) =
    list.find(lines, fn(line) {
      string.starts_with(line, prefix <> " ")
      || string.starts_with(line, prefix <> "(")
    })
  let assert Ok(#(_, effects)) = string.split_once(line, " : ")
  effects
}

pub fn catalogued_shapes_read_the_catalogs_answers_test() {
  let lines = lines()
  [
    #("inline_callback_effect", "[Stdout]"),
    #("named_callback_effect", "[Stdout]"),
    #("list_relayed_and_called", "[Stdout]"),
    #("list_relayed_but_ignored", "[]"),
    #("printer_relayed_and_called", "[Stdout]"),
    #("printer_as_the_callback", "[Stdout]"),
    #("callback_calling_a_printer", "[Stdout]"),
    #("untyped_alias_relayed", "[Unknown]"),
    #("untyped_call_result_relayed", "[Unknown]"),
    #("inspected_type_variable", "[]"),
    #("decoder_with_inline_continuation", "[Stdout]"),
    #("decoder_returning_a_captured_decoder", "[Stdout]"),
    #("decoder_returning_an_untraced_decoder", "[Stdout, Unknown]"),
    #("decoder_with_named_continuation", "[Stdout, Unknown]"),
    #("application_of_pure_callbacks", "[]"),
    #("started_application", "[Dom, Process, Unknown]"),
    #("fold_step_calling_its_accumulator", "[Unknown]"),
    #("parameter_field_relayed", "[Unknown]"),
    #("built_field_relayed", "[Stdout]"),
  ]
  |> list.each(fn(row) {
    let #(function, expected) = row
    #(function, answer(lines, function)) |> should.equal(#(function, expected))
  })
}

// A dependency's committed summary over a closure calling a relayed
// function, read by a consumer before and after the dependency's spec is
// regenerated.

const stale_summary_dependency =
  "import gleam/io
import gleam/list

fn loud() -> Nil {
  io.println(\"old summary\")
}

pub fn tick() -> Nil {
  list.each([loud], fn(f) { f() })
}
"

fn stale_summary_tree(directory: String) -> #(String, String) {
  let parent =
    support.write_fixture(directory, [
      #(
        "old_dep/gleam.toml",
        "name = \"old_dep\"\nversion = \"1.0.0\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n",
      ),
      #("old_dep/manifest.toml", "packages = [\n" <> stdlib_entry <> "]\n"),
      #("old_dep/old_dep.graded", "effects old_dep.tick : []\n"),
      #("old_dep/src/old_dep.gleam", stale_summary_dependency),
      #(
        "consumer/gleam.toml",
        "name = \"consumer\"\nversion = \"1.0.0\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\nold_dep = { path = \"../old_dep\" }\n",
      ),
      #(
        "consumer/manifest.toml",
        "packages = [\n"
          <> stdlib_entry
          <> "  { name = \"old_dep\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [\"gleam_stdlib\"], source = \"local\", path = \"../old_dep\" },\n]\n",
      ),
      // Current for the dependency spec it reads.
      #("consumer/consumer.graded", "effects consumer.go : []\n"),
      #(
        "consumer/src/consumer.gleam",
        "import old_dep\n\npub fn go() -> Nil {\n  old_dep.tick()\n}\n",
      ),
    ])
  support.install_stdlib(parent <> "/old_dep")
  support.install_stdlib(parent <> "/consumer")
  #(parent <> "/old_dep", parent <> "/consumer")
}

// The stale summary is read as current: outside the guarantee's precondition,
// and `infer --check` says so on the dependency only.
pub fn a_stale_dependency_summary_is_read_as_written_test() {
  let #(dependency, consumer) =
    stale_summary_tree("build/acceptance_stale_summary")
  let assert Ok(stale) = graded.inferred_lines(consumer)
  let stale_dependency_check = graded.run_infer_check(dependency)
  let stale_consumer_check = graded.run_infer_check(consumer)
  support.cleanup("build/acceptance_stale_summary")
  stale |> should.equal(["effects consumer.go : []"])
  let assert Error(graded.StaleSpec(..)) = stale_dependency_check
  stale_consumer_check |> should.be_ok
}

// Regenerated by this graded, the summary carries the relayed printer.
pub fn a_regenerated_dependency_summary_reaches_the_consumer_test() {
  let #(dependency, consumer) =
    stale_summary_tree("build/acceptance_regenerated_summary")
  let assert Ok(Nil) = graded.run_infer(dependency)
  let assert Ok(regenerated) = graded.inferred_lines(consumer)
  support.cleanup("build/acceptance_regenerated_summary")
  regenerated |> should.equal(["effects consumer.go : [Stdout]"])
}

// Rows that cross a package boundary: each package installs the standard
// library, and lustre where it names it, and reaches the packages it depends
// on by path.

const stdlib_entry =
  "  { name = \"gleam_stdlib\", version = \"1.0.5\", build_tools = [\"gleam\"], requirements = [], otp_app = \"gleam_stdlib\", source = \"hex\", outer_checksum = \"00\" },\n"

const lustre_entry =
  "  { name = \"lustre\", version = \"5.7.1\", build_tools = [\"gleam\"], requirements = [\"gleam_stdlib\"], otp_app = \"lustre\", source = \"hex\", outer_checksum = \"00\" },\n"

fn local_entry(name: String, requirements: List(String)) -> String {
  "  { name = \""
  <> name
  <> "\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = ["
  <> string.join(list.map(requirements, fn(r) { "\"" <> r <> "\"" }), ", ")
  <> "], source = \"local\", path = \"../"
  <> name
  <> "\" },\n"
}

// One package of a tree under `parent`: its `gleam.toml` naming
// `dependencies`, a manifest of `entries`, its files, and what it installs.
fn tree_package(
  parent: String,
  name: String,
  dependencies: List(String),
  entries: List(String),
  lustre: Bool,
  files: List(#(String, String)),
) -> String {
  let root = parent <> "/" <> name
  let dependency_lines =
    list.map(dependencies, fn(dependency) {
      case dependency {
        "gleam_stdlib" -> "gleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n"
        "lustre" -> "lustre = \">= 5.0.0 and < 6.0.0\"\n"
        _ -> dependency <> " = { path = \"../" <> dependency <> "\" }\n"
      }
    })
  let installed = case lustre {
    True -> [
      #(
        "build/packages/packages.toml",
        "[packages]\ngleam_stdlib = \"1.0.5\"\nlustre = \"5.7.1\"\n",
      ),
      #(
        "build/packages/lustre/gleam.toml",
        "name = \"lustre\"\nversion = \"5.7.1\"\n",
      ),
      #("build/packages/lustre/src/lustre.gleam", lustre_root),
      #("build/packages/lustre/src/lustre/effect.gleam", lustre_effect),
    ]
    False -> []
  }
  support.write_fixture(root, [
    #(
      "gleam.toml",
      "name = \""
        <> name
        <> "\"\nversion = \"1.0.0\"\n\n[dependencies]\n"
        <> string.concat(dependency_lines),
    ),
    #("manifest.toml", "packages = [\n" <> string.concat(entries) <> "]\n"),
    ..list.append(installed, files)
  ])
  support.install_stdlib(root)
  root
}

fn inferred(root: String) -> List(String) {
  let assert Ok(lines) = graded.inferred_lines(root)
  lines
}

// A foreign producer's undescribed list, re-exported by a second
// package, captured by a closure the consumer builds and later calls.
pub fn a_reexported_undescribed_list_activates_unknown_test() {
  let parent = "build/acceptance_reexported_list"
  let _ =
    tree_package(parent, "producer", [], [], False, [
      #("producer.graded", "assume producer.exported : []\n"),
      #(
        "src/producer.gleam",
        "@external(erlang, \"producer_ffi\", \"exported\")\npub fn exported() -> List(fn() -> Nil)\n",
      ),
    ])
  let middle =
    tree_package(
      parent,
      "middle",
      ["producer"],
      [local_entry("producer", [])],
      False,
      [
        #(
          "src/middle.gleam",
          "import producer\n\npub fn reexported() -> List(fn() -> Nil) {\n  producer.exported()\n}\n",
        ),
      ],
    )
  let consumer =
    tree_package(
      parent,
      "consumer",
      ["gleam_stdlib", "middle"],
      [
        stdlib_entry,
        local_entry("middle", ["producer"]),
        local_entry("producer", []),
      ],
      False,
      [
        #(
          "src/consumer.gleam",
          "import gleam/list
import middle

pub fn build() -> fn() -> Nil {
  let xs = middle.reexported()
  fn() { list.each(xs, fn(f) { f() }) }
}

pub fn activate() -> Nil {
  let run = build()
  run()
}
",
        ),
      ],
    )
  let assert Ok(exported) = graded.run_effect(middle, "producer.exported")
  let middle_lines = inferred(middle)
  let consumer_lines = inferred(consumer)
  support.cleanup(parent)
  exported
  |> string.split("\n")
  |> list.filter(fn(line) { !string.starts_with(line, "//") })
  |> should.equal(["effects producer.exported : []"])
  middle_lines |> should.equal(["effects middle.reexported : []"])
  consumer_lines
  |> should.equal([
    "effects consumer.activate : [Unknown]",
    "effects consumer.build : []",
  ])
}

// One package's `app()` built from pure callbacks, and one
// whose `init` returns an effect holding a printing callback, each started by
// a separate package's `main`.
pub fn an_application_another_package_starts_test() {
  let parent = "build/acceptance_application"
  let ui =
    tree_package(
      parent,
      "ui",
      ["gleam_stdlib", "lustre"],
      [stdlib_entry, lustre_entry],
      True,
      [
        #(
          "src/ui.gleam",
          "import gleam/io
import lustre
import lustre/effect

fn init(_flags: Nil) -> #(Int, effect.Effect(Nil)) {
  #(0, effect.from(fn(_dispatch) { Nil }))
}

fn update(model: Int, _message: Nil) -> #(Int, effect.Effect(Nil)) {
  #(model, effect.from(fn(_dispatch) { Nil }))
}

fn view(_model: Int) -> lustre.Element(Nil) {
  view(0)
}

pub fn app() {
  lustre.application(init, update, view)
}

fn announce(_dispatch: fn(Nil) -> Nil) -> Nil {
  io.println(\"x\")
}

fn init_announcing(_flags: Nil) -> #(Int, effect.Effect(Nil)) {
  #(0, effect.from(announce))
}

pub fn app_announcing() {
  lustre.application(init_announcing, update, view)
}
",
        ),
      ],
    )
  let consumer =
    tree_package(
      parent,
      "consumer",
      ["gleam_stdlib", "lustre", "ui"],
      [
        stdlib_entry,
        lustre_entry,
        local_entry("ui", ["gleam_stdlib", "lustre"]),
      ],
      True,
      [
        #(
          "src/consumer.gleam",
          "import lustre
import ui

pub fn main() {
  lustre.start(ui.app(), \"#app\", Nil)
}

pub fn main_announcing() {
  lustre.start(ui.app_announcing(), \"#app\", Nil)
}
",
        ),
      ],
    )
  let ui_lines = inferred(ui)
  let consumer_lines = inferred(consumer)
  support.cleanup(parent)
  ui_lines
  |> should.equal([
    "effects ui.app : []",
    "effects ui.app_announcing : [Stdout]",
  ])
  consumer_lines
  |> should.equal([
    "effects consumer.main : [Dom, Process, Unknown]",
    "effects consumer.main_announcing : [Dom, Process, Stdout, Unknown]",
  ])
}
