// What calls are charged for the function values their arguments carry, under
// the latent-effect rules. One package holds the shapes: its foreign functions
// are declared by the package's own `assume` lines — some boundless, some with
// the contracts a reviewed catalog line would carry — so every shape reads
// without the bundled catalog.

import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import gleeunit/should
import graded
import graded/internal/annotation
import graded/internal/checker
import graded/internal/effect_term
import graded/internal/effects
import graded/internal/signatures
import graded/internal/typedefs
import graded/internal/typeinfo
import graded/internal/types
import simplifile
import support

@external(erlang, "scope_test_ffi", "reductions")
fn reductions() -> Int

const ffi_source =
  "pub type Wrapper {
  Wrapper(f: fn() -> Nil)
}

pub type Mixed {
  Mixed(fn() -> Nil, keep: fn() -> Nil)
}

pub type Handle

pub type Decoder(a)

pub type Effect(m)

@external(erlang, \"m\", \"shout\")
@external(javascript, \"m\", \"shout\")
pub fn shout() -> Nil

@external(erlang, \"m\", \"say\")
@external(javascript, \"m\", \"say\")
pub fn say(s: String) -> Nil

@external(erlang, \"m\", \"each\")
@external(javascript, \"m\", \"each\")
pub fn each(list: List(a), f: fn(a) -> Nil) -> Nil

@external(erlang, \"m\", \"each_labelled\")
@external(javascript, \"m\", \"each_labelled\")
pub fn each_labelled(list list: List(a), f f: fn(a) -> Nil) -> Nil

@external(erlang, \"m\", \"fold\")
@external(javascript, \"m\", \"fold\")
pub fn fold(over: List(a), from: b, with: fn(b, a) -> b) -> b

@external(erlang, \"m\", \"run\")
@external(javascript, \"m\", \"run\")
pub fn run(w: Wrapper) -> Nil

@external(erlang, \"m\", \"run_mixed\")
@external(javascript, \"m\", \"run_mixed\")
pub fn run_mixed(m: Mixed) -> Nil

@external(erlang, \"m\", \"run_all\")
@external(javascript, \"m\", \"run_all\")
pub fn run_all(fs: List(fn() -> Nil)) -> Nil

@external(erlang, \"m\", \"get\")
@external(javascript, \"m\", \"get\")
pub fn get() -> List(fn() -> Nil)

@external(erlang, \"m\", \"fresh\")
@external(javascript, \"m\", \"fresh\")
pub fn fresh() -> Handle

@external(erlang, \"m\", \"fresh_carrying\")
@external(javascript, \"m\", \"fresh_carrying\")
pub fn fresh_carrying() -> Handle

@external(erlang, \"m\", \"run_handle\")
@external(javascript, \"m\", \"run_handle\")
pub fn run_handle(h: Handle) -> Nil

@external(erlang, \"m\", \"inspect\")
@external(javascript, \"m\", \"inspect\")
pub fn inspect(x: a) -> String

@external(erlang, \"m\", \"run_any\")
@external(javascript, \"m\", \"run_any\")
pub fn run_any(x: a) -> Nil

@external(erlang, \"m\", \"run_twice\")
@external(javascript, \"m\", \"run_twice\")
pub fn run_twice(f: fn() -> fn() -> Nil) -> Nil

@external(erlang, \"m\", \"from\")
@external(javascript, \"m\", \"from\")
pub fn from(effect: fn(fn(m) -> Nil) -> Nil) -> Effect(m)

@external(erlang, \"m\", \"int\")
@external(javascript, \"m\", \"int\")
pub fn int() -> Decoder(Int)

@external(erlang, \"m\", \"success\")
@external(javascript, \"m\", \"success\")
pub fn success(data: Int) -> Decoder(Int)

@external(erlang, \"m\", \"field\")
@external(javascript, \"m\", \"field\")
pub fn field(name: String, field_decoder: Decoder(a), next: fn(a) -> Decoder(b)) -> Decoder(b)

@external(erlang, \"m\", \"decode\")
@external(javascript, \"m\", \"decode\")
pub fn decode(data: String, decoder: Decoder(a)) -> Result(a, Nil)

@external(erlang, \"m\", \"nosig\")
@external(javascript, \"m\", \"nosig\")
pub fn nosig(x: List(fn() -> Nil)) -> Nil
"

const spec =
  "assume app/ffi.shout : [Stdout]
assume app/ffi.say : [Stdout]
assume app/ffi.each(list: [l], f: [f]) : [f] where runs : [], relay : f(l)
assume app/ffi.each_labelled(list: [l], f: [f]) : [f] where runs : [], relay : f(l)
assume app/ffi.fold(over: [l], from: [a], with: [f]) : [f] where runs : [], relay : f(_, l)
assume app/ffi.run : []
assume app/ffi.run_mixed : []
assume app/ffi.run_all : []
assume app/ffi.get : []
assume app/ffi.fresh : []
assume app/ffi.fresh_carrying : [] where carries : [Stdout]
assume app/ffi.run_handle : []
assume app/ffi.inspect(x: [x]) : [] where runs : []
assume app/ffi.run_any : []
assume app/ffi.run_twice : []
assume app/ffi.from(effect: [effect]) : [effect([])] where carries : [effect([])]
assume app/ffi.int : [] where carries : []
assume app/ffi.success(data: [d]) : [] where runs : [], carries : [d]
assume app/ffi.field(field_decoder: [d], next: [n]) : [] where runs : [], carries : [d, n, n.returns]
assume app/ffi.decode(decoder: [d]) : [] where runs : [d]
assume nosource.run : []
"

const app_source =
  "import app/ffi.{type Decoder, Mixed, Wrapper}
import nosource

pub type Config {
  Config(on_item: fn(String) -> Nil)
}

fn loud() -> Nil {
  ffi.shout()
}

fn quiet() -> Nil {
  Nil
}

pub fn inline_effect() {
  ffi.from(fn(dispatch) {
    loud()
    dispatch(Nil)
  })
}

fn callback(dispatch: fn(Nil) -> Nil) -> Nil {
  loud()
  dispatch(Nil)
}

pub fn named_effect() {
  ffi.from(callback)
}

fn store(f: fn() -> Nil) -> fn() -> Nil {
  f
}

pub fn stored_closure() -> fn() -> Nil {
  store(fn() { loud() })
}

pub fn relayed_list() -> Nil {
  ffi.each([loud], fn(f) { f() })
}

pub fn relayed_but_ignored() -> Nil {
  ffi.each([loud], fn(_) { Nil })
}

pub fn relayed_qualified_reference() -> Nil {
  ffi.each([ffi.shout], fn(f) { f() })
}

pub fn foreign_list() -> Nil {
  ffi.each(ffi.get(), fn(f) { f() })
}

pub fn reference_as_callback() -> Nil {
  ffi.each([\"x\"], ffi.say)
}

pub fn direct_call_in_callback() -> Nil {
  ffi.each([1], fn(_) { loud() })
}

pub fn record_to_runner() -> Nil {
  ffi.run(Wrapper(loud))
}

pub fn list_to_runner() -> Nil {
  ffi.run_all([loud])
}

pub fn foreign_pair() -> Nil {
  ffi.run_all(ffi.get())
}

pub fn exported_list() -> List(fn() -> Nil) {
  [loud]
}

fn tuple_named() -> #(Int, fn() -> Nil) {
  #(1, loud)
}

pub fn tuple_from_helper() -> Nil {
  let #(_, f) = tuple_named()
  f()
}

pub fn forwarded_type_variable(x: a) -> Nil {
  ffi.run_any(x)
}

pub fn forwarded_call() -> Nil {
  forwarded_type_variable([loud])
}

pub fn external_handle() -> Nil {
  ffi.run_handle(ffi.fresh())
}

pub fn declared_handle() -> Nil {
  ffi.run_handle(ffi.fresh_carrying())
}

pub fn inspected_type_variable(x: a) -> String {
  ffi.inspect(x)
}

pub fn parsed_decoder_parameter(s: String, d: Decoder(a)) -> Result(a, Nil) {
  ffi.decode(s, d)
}

pub fn decoder_inline_tail(s: String) -> Result(Int, Nil) {
  ffi.decode(
    s,
    ffi.field(\"a\", ffi.int(), fn(a) {
      loud()
      ffi.success(a)
    }),
  )
}

fn next_fn(a: Int) -> Decoder(Int) {
  loud()
  ffi.success(a)
}

pub fn decoder_named_tail(s: String) -> Result(Int, Nil) {
  ffi.decode(s, ffi.field(\"a\", ffi.int(), next_fn))
}

fn step(acc: fn() -> Nil, _: Int) -> fn() -> Nil {
  acc()
  fn() { loud() }
}

pub fn fold_accumulator() -> Nil {
  let _ = ffi.fold([1, 2], quiet, step)
  Nil
}

pub fn parameter_receiver_field(cfg: Config) -> Nil {
  ffi.each([\"x\"], cfg.on_item)
}

pub fn built_receiver_field() -> Nil {
  let cfg = Config(on_item: ffi.say)
  ffi.each([\"x\"], cfg.on_item)
}

pub fn choice_relayed(flag: Bool) -> Nil {
  ffi.each([loud], case flag {
    True -> fn(f) { f() }
    False -> fn(_) { Nil }
  })
}

pub fn mixed_constructor() -> Nil {
  ffi.run_mixed(Mixed(loud, keep: quiet))
}

fn outer() -> fn() -> Nil {
  loud
}

fn get_outer() -> fn() -> fn() -> Nil {
  outer
}

pub fn returned_returning() -> Nil {
  ffi.run_twice(get_outer())
}

pub fn named_returning() -> Nil {
  ffi.run_twice(outer)
}

pub fn piped() -> Nil {
  [loud] |> ffi.each(fn(f) { f() })
}

pub fn labelled() -> Nil {
  ffi.each_labelled(f: fn(f) { f() }, list: [loud])
}

pub fn shorthand() -> Nil {
  let list = [loud]
  ffi.each_labelled(list:, f: fn(f) { f() })
}

pub fn no_signature() -> Nil {
  nosource.run([loud])
}
"

fn project(directory: String) -> String {
  support.write_fixture(directory, [
    #("gleam.toml", "name = \"app\"\n"),
    #("app.graded", spec),
    #("src/app/ffi.gleam", ffi_source),
    #("src/app.gleam", app_source),
  ])
}

fn active_lines() -> List(String) {
  let directory = project("/tmp/graded_latent_charges")
  let assert Ok(lines) = graded.inferred_lines_with(directory, types.Active)
  support.cleanup(directory)
  lines
}

fn answer(lines: List(String), function: String) -> String {
  let prefix = "effects app." <> function
  let assert Ok(line) =
    list.find(lines, fn(line) {
      string.starts_with(line, prefix <> " ")
      || string.starts_with(line, prefix <> "(")
    })
  line
}

pub fn each_shape_reads_its_answer_test() {
  let lines = active_lines()
  [
    #("inline_effect", "effects app.inline_effect : [Stdout]"),
    #("named_effect", "effects app.named_effect : [Stdout]"),
    #(
      "stored_closure",
      "effects app.stored_closure : [Stdout] where returns : [Stdout]",
    ),
    #("relayed_list", "effects app.relayed_list : [Stdout]"),
    #("relayed_but_ignored", "effects app.relayed_but_ignored : []"),
    #(
      "relayed_qualified_reference",
      "effects app.relayed_qualified_reference : [Stdout]",
    ),
    #("foreign_list", "effects app.foreign_list : [Unknown]"),
    #("reference_as_callback", "effects app.reference_as_callback : [Stdout]"),
    #(
      "direct_call_in_callback",
      "effects app.direct_call_in_callback : [Stdout]",
    ),
    #("record_to_runner", "effects app.record_to_runner : [Stdout]"),
    #("list_to_runner", "effects app.list_to_runner : [Stdout]"),
    #("foreign_pair", "effects app.foreign_pair : [Unknown]"),
    #("exported_list", "effects app.exported_list : []"),
    #("tuple_from_helper", "effects app.tuple_from_helper : [Unknown]"),
    #(
      "forwarded_type_variable",
      "effects app.forwarded_type_variable : [Unknown]",
    ),
    #("forwarded_call", "effects app.forwarded_call : [Unknown]"),
    #("external_handle", "effects app.external_handle : [Unknown]"),
    #("declared_handle", "effects app.declared_handle : [Stdout]"),
    // A type-variable parameter is of unknown kind, so a written line's `runs`
    // promises nothing for it; the reviewed catalog line is what reads `[]`.
    #(
      "inspected_type_variable",
      "effects app.inspected_type_variable : [Unknown]",
    ),
    #(
      "parsed_decoder_parameter",
      "effects app.parsed_decoder_parameter : [Unknown]",
    ),
    #("decoder_inline_tail", "effects app.decoder_inline_tail : [Stdout]"),
    #(
      "decoder_named_tail",
      "effects app.decoder_named_tail : [Stdout, Unknown]",
    ),
    #("fold_accumulator", "effects app.fold_accumulator : [Unknown]"),
    #(
      "parameter_receiver_field",
      "effects app.parameter_receiver_field : [Unknown]",
    ),
    #("built_receiver_field", "effects app.built_receiver_field : [Stdout]"),
  ]
  |> list.map(fn(row) { #(answer(lines, row.0), row.1) })
  |> list.each(fn(pair) { pair.0 |> should.equal(pair.1) })
}

pub fn a_choice_of_callbacks_reaches_the_relayed_option_test() {
  active_lines()
  |> answer("choice_relayed")
  |> should.equal("effects app.choice_relayed : [Stdout]")
}

pub fn every_argument_of_a_construction_is_charged_test() {
  active_lines()
  |> answer("mixed_constructor")
  |> should.equal("effects app.mixed_constructor : [Stdout]")
}

pub fn a_function_returning_a_function_escapes_unknown_test() {
  let lines = active_lines()
  answer(lines, "returned_returning")
  |> should.equal("effects app.returned_returning : [Unknown]")
  answer(lines, "named_returning")
  |> should.equal("effects app.named_returning : [Unknown]")
}

pub fn every_argument_spelling_is_charged_alike_test() {
  let lines = active_lines()
  ["piped", "labelled", "shorthand"]
  |> list.map(answer(lines, _))
  |> should.equal([
    "effects app.piped : [Stdout]",
    "effects app.labelled : [Stdout]",
    "effects app.shorthand : [Stdout]",
  ])
}

pub fn a_callee_with_no_signature_runs_every_argument_test() {
  // The function names a module with no source, so it is not typed either:
  // `loud`'s result reads unknown beside its cost.
  active_lines()
  |> answer("no_signature")
  |> should.equal("effects app.no_signature : [Stdout, Unknown]")
}

// A reviewed catalog line and the written lines shadowing it

fn inspect_kb(
  catalog_line: String,
  written: List(String),
) -> effects.KnowledgeBase {
  let parse = fn(line) {
    let assert Ok(types.GradedFile(lines: [types.AssumeLine(assume, _)])) =
      annotation.parse_file_with(line, types.Active)
    assume
  }
  effects.new_knowledge_base()
  |> effects.with_lat_mode(types.Active)
  |> effects.with_assumes([parse(catalog_line)], types.Catalog("fake"))
  |> effects.with_assumes(
    [parse("assume app/ffi.shout : [Stdout]"), ..list.map(written, parse)],
    types.UserAssume,
  )
  |> effects.with_audit(
    effects.CatalogAudit(
      ..effects.empty_audit(),
      reviewed: set.from_list([types.QualifiedName("fake/str", "inspect")]),
    ),
  )
}

fn inspect_registry(parameter: String) -> signatures.SignatureRegistry {
  let assert Ok(module) =
    glance.module(
      "pub fn inspect(" <> parameter <> ") -> String {\n  \"\"\n}\n",
    )
  signatures.from_glance_module("fake/str", module)
  |> signatures.with_types(typedefs.from_module(
    "fake/str",
    module,
    set.from_list(["erlang"]),
  ))
}

fn inspect_answer(
  knowledge_base: effects.KnowledgeBase,
  registry: signatures.SignatureRegistry,
) -> types.EffectSet {
  let assert Ok(module) =
    glance.module(
      "import app/ffi\nimport fake/str\n\nfn loud() -> Nil {\n  ffi.shout()\n}\n\npub fn go() -> String {\n  str.inspect([loud])\n}\n",
    )
  let assert [annotation] =
    checker.infer(
      module,
      "app",
      knowledge_base,
      [],
      registry,
      typeinfo.no_reading(),
      types.all_targets(),
    )
  effect_term.to_effect_set(annotation.effects)
}

pub fn a_written_line_keeps_its_own_default_over_a_reviewed_catalog_line_test() {
  let registry = inspect_registry("x: List(fn() -> Nil)")
  let catalog = "assume fake/str.inspect(x: [x]) : [] where runs : []"
  let printing = types.from_labels(["Stdout", "Unknown"])
  // The reviewed line answers no-run.
  inspect_kb(catalog, [])
  |> inspect_answer(registry)
  |> should.equal(types.empty())
  // A written line without `runs` runs everything, whatever the catalog said.
  inspect_kb(catalog, ["assume fake/str.inspect : []"])
  |> inspect_answer(registry)
  |> should.equal(printing)
  // A written line with `runs` states its own promise.
  inspect_kb(catalog, ["assume fake/str.inspect(x: [x]) : [] where runs : []"])
  |> inspect_answer(registry)
  |> should.equal(types.empty())
  inspect_kb(catalog, ["assume fake/str.inspect(x: [x]) : [] where runs : [x]"])
  |> inspect_answer(registry)
  |> should.equal(printing)
}

pub fn a_reviewed_line_speaks_for_a_parameter_of_unknown_kind_test() {
  let registry = inspect_registry("x: a")
  let catalog = "assume fake/str.inspect(x: [x]) : [] where runs : []"
  inspect_kb(catalog, [])
  |> inspect_answer(registry)
  |> should.equal(types.empty())
  // Written, the same line promises nothing for a type variable.
  inspect_kb(catalog, ["assume fake/str.inspect(x: [x]) : [] where runs : []"])
  |> inspect_answer(registry)
  |> should.equal(types.from_labels(["Stdout", "Unknown"]))
}

// Receivers

pub fn a_binding_shadowing_a_module_reads_as_its_field_test() {
  let directory =
    support.write_fixture("/tmp/graded_latent_shadowed", [
      #("gleam.toml", "name = \"app\"\n"),
      #("app.graded", spec),
      #("src/app/ffi.gleam", ffi_source),
      #(
        "src/app.gleam",
        "import app/ffi\n\npub type Printer {\n  Printer(say: fn(String) -> Nil)\n}\n\npub fn shadowed(ffi: Printer) -> Nil {\n  each([\"x\"], ffi.say)\n}\n\nfn each(list: List(String), f: fn(String) -> Nil) -> Nil {\n  app_each(list, f)\n}\n\nfn app_each(list, f) {\n  ffi.each(list, f)\n}\n",
      ),
    ])
  let assert Ok(active) = graded.inferred_lines_with(directory, types.Active)
  let assert Ok(inactive) =
    graded.inferred_lines_with(directory, types.Inactive)
  support.cleanup(directory)
  answer(active, "shadowed")
  |> should.equal("effects app.shadowed : [Unknown]")
  answer(inactive, "shadowed")
  |> should.equal("effects app.shadowed : [Stdout]")
}

pub fn a_receiver_built_per_target_reads_unknown_test() {
  let directory =
    support.write_fixture("/tmp/graded_latent_target_receiver", [
      #("gleam.toml", support.dual_target_toml("app")),
      #("app.graded", spec),
      #("src/app/ffi.gleam", ffi_source),
      #(
        "src/app.gleam",
        "import app/ffi\n\npub type Config {\n  Config(on_item: fn(String) -> Nil)\n}\n\n@target(erlang)\nfn make() -> Config {\n  Config(on_item: ffi.say)\n}\n\n@target(javascript)\nfn make() -> Config {\n  Config(on_item: fn(_) { Nil })\n}\n\npub fn handler() -> Nil {\n  let cfg = make()\n  ffi.each([\"x\"], cfg.on_item)\n}\n",
      ),
    ])
  let assert Ok(lines) = graded.inferred_lines_with(directory, types.Active)
  support.cleanup(directory)
  answer(lines, "handler") |> should.equal("effects app.handler : [Unknown]")
}

// Lineage

fn summary_project(directory: String, dependency_spec: String) -> String {
  let _ =
    support.write_fixture(directory, [
      #(
        "app/gleam.toml",
        "name = \"app\"\n\n[dependencies]\ndep = { path = \"../dep\" }\n",
      ),
      #(
        "app/src/app.gleam",
        "import app/ffi\nimport dep\n\nfn loud() -> Nil {\n  ffi.shout()\n}\n\npub fn go() -> Nil {\n  dep.hold([loud])\n}\n",
      ),
      #(
        "app/src/app/ffi.gleam",
        "@external(erlang, \"m\", \"shout\")\npub fn shout() -> Nil\n",
      ),
      #("app/app.graded", "assume app/ffi.shout : [Stdout]\n"),
      #("dep/gleam.toml", "name = \"dep\"\n"),
      #(
        "dep/src/dep.gleam",
        "pub fn hold(xs: List(fn() -> Nil)) -> Nil {\n  let _ = xs\n  Nil\n}\n",
      ),
    ])
  case dependency_spec {
    "" -> Nil
    spec -> support.write_file(directory <> "/dep/dep.graded", spec)
  }
  directory <> "/app"
}

pub fn only_a_written_line_charges_its_default_test() {
  [
    // A truthful generated summary and the inference it summarizes.
    "effects dep.hold : []\n",
    "",
    // A written line follows its own `runs`, or its default.
    "assume dep.hold(xs: [x]) : [] where runs : []\n",
    "assume dep.hold : []\n",
  ]
  |> list.index_map(fn(dependency_spec, index) {
    let parent = "/tmp/graded_latent_lineage_" <> string.inspect(index)
    let root = summary_project(parent, dependency_spec)
    let assert Ok(lines) = graded.inferred_lines_with(root, types.Active)
    support.cleanup(parent)
    answer(lines, "go")
  })
  |> should.equal([
    "effects app.go : []",
    "effects app.go : []",
    "effects app.go : []",
    "effects app.go : [Stdout]",
  ])
}

// Field calls

pub fn a_field_call_runs_what_its_arguments_carry_test() {
  let directory =
    support.write_fixture("/tmp/graded_latent_field_call", [
      #("gleam.toml", "name = \"app\"\n"),
      #("app.graded", spec),
      #("src/app/ffi.gleam", ffi_source),
      #(
        "src/app.gleam",
        "import app/ffi\n\npub type Runner {\n  Runner(run_all: fn(List(fn() -> Nil)) -> Nil)\n}\n\nfn loud() -> Nil {\n  ffi.shout()\n}\n\npub fn go(runner: Runner) -> Nil {\n  runner.run_all([loud])\n}\n",
      ),
    ])
  let assert Ok(active) = graded.inferred_lines_with(directory, types.Active)
  let assert Ok(inactive) =
    graded.inferred_lines_with(directory, types.Inactive)
  support.cleanup(directory)
  answer(active, "go")
  |> should.equal(
    "effects app.go(runner.run_all: [runner.run_all]) : [Stdout, runner.run_all]",
  )
  answer(inactive, "go")
  |> should.equal(
    "effects app.go(runner.run_all: [runner.run_all]) : [runner.run_all]",
  )
}

// Definitions `@target` gives once per target, in a package read on both:
// nothing proven of one target's reading is taken for the other's, and a name
// a module defines once per target reads as what each variant does.

const pair_ffi =
  "@external(erlang, \"m\", \"sink\")
@external(javascript, \"m\", \"sink\")
pub fn sink(x: a) -> Nil

@external(erlang, \"m\", \"shout\")
@external(javascript, \"m\", \"shout\")
pub fn shout() -> Nil
"

const pair_spec =
  "assume probe/ffi.sink : []
assume probe/ffi.shout : [Stdout]
"

fn pair_answers(
  name: String,
  sources: List(#(String, String)),
  spec: String,
) -> List(String) {
  let directory =
    support.write_fixture("/tmp/graded_target_pairs_" <> name, [
      #("gleam.toml", support.dual_target_toml("probe")),
      #("probe.graded", pair_spec <> spec),
      #("src/probe/ffi.gleam", pair_ffi),
      ..sources
    ])
  let assert Ok(lines) = graded.inferred_lines_with(directory, types.Active)
  support.cleanup(directory)
  list.filter(lines, fn(line) { !string.starts_with(line, "effects probe/") })
}

pub fn a_value_typed_differently_on_each_target_is_charged_as_each_target_reads_it_test() {
  pair_answers(
    "value",
    [
      #(
        "src/probe.gleam",
        "import probe/ffi

@target(erlang)
fn get() -> Int {
  0
}

@target(javascript)
fn get() -> fn() -> Nil {
  ffi.shout
}

pub fn main() -> Nil {
  ffi.sink(get())
}
",
      ),
    ],
    "",
  )
  |> should.equal(["effects probe.main : [Stdout]"])
}

pub fn a_target_attribute_spelled_with_spaces_splits_the_package_test() {
  pair_answers(
    "spaced",
    [
      #(
        "src/probe.gleam",
        "import probe/ffi
@target (erlang)
fn get() -> Nil { Nil }
@target
(javascript)
fn get() -> Nil { ffi.shout() }
pub fn main() -> Nil { get() }
",
      ),
    ],
    "",
  )
  |> should.equal(["effects probe.main : [Stdout]"])
}

// A type alias on one target and a custom type of the same name on the other,
// made by a foreign function: the custom type holds a function.
fn mixed_pair(alias_first: Bool) -> String {
  let alias = "@target(erlang)\npub type Held = Int\n\n"
  let custom =
    "@target(javascript)\npub type Held {\n  Held(run: fn() -> Nil)\n}\n\n"
  "import probe/ffi\n\n"
  <> case alias_first {
    True -> alias <> custom
    False -> custom <> alias
  }
  <> "@external(erlang, \"m\", \"make\")
@external(javascript, \"m\", \"make\")
fn make() -> Held

pub fn main() -> Nil {
  ffi.sink(make())
}
"
}

pub fn an_alias_and_custom_type_pair_splits_the_package_in_either_order_test() {
  list.each([True, False], fn(alias_first) {
    pair_answers(
      "mixed",
      [#("src/probe.gleam", mixed_pair(alias_first))],
      "assume probe.make : []\n",
    )
    |> should.equal(["effects probe.main : [Unknown]"])
  })
}

pub fn a_type_defined_per_target_is_read_on_each_target_alone_test() {
  pair_answers(
    "shapes",
    [
      #(
        "src/probe.gleam",
        "import probe/ffi

@target(erlang)
pub type Box {
  Box(Int)
}

@target(javascript)
pub type Box {
  Box(fn() -> Nil)
}

@external(erlang, \"m\", \"make\")
@external(javascript, \"m\", \"make\")
fn make() -> Box

@target(erlang)
pub fn main() -> Nil {
  ffi.sink(make())
}

@target(javascript)
pub fn main() -> Nil {
  Nil
}
",
      ),
    ],
    "assume probe.make : []\n",
  )
  |> should.equal(["effects probe.main : []"])
}

// `main` of a consumer whose `targets` are `consumer`, calling `call` on an
// installed `dep` whose spec graded wrote with `dep`'s own `targets` set to
// `publisher`.
fn published_answer(
  name: String,
  publisher: String,
  dep_source: String,
  call: String,
  consumer: String,
) -> List(String) {
  let directory =
    support.write_fixture("/tmp/graded_published_" <> name, [
      #(
        "gleam.toml",
        "name = \"probe\"\n\n[tools.graded]\ntargets = " <> consumer <> "\n",
      ),
      #("probe.graded", pair_spec),
      #("src/probe/ffi.gleam", pair_ffi),
      #(
        "src/probe.gleam",
        "import dep\nimport probe/ffi\n\nfn quiet() -> Nil {\n  Nil\n}\n\npub fn main() -> Nil {\n  "
          <> call
          <> "\n}\n",
      ),
      #(
        "build/packages/dep/gleam.toml",
        "name = \"dep\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = "
          <> publisher
          <> "\n",
      ),
      #("build/packages/dep/src/dep.gleam", dep_source),
    ])
  let assert Ok(Nil) = graded.run_infer(directory <> "/build/packages/dep")
  let assert Ok(lines) = graded.inferred_lines_with(directory, types.Active)
  support.cleanup(directory)
  list.filter(lines, string.starts_with(_, "effects probe.main"))
}

// Each variant names the callback the other's label calls first; JavaScript's
// runs the one labelled `second`, Erlang's runs neither.
const permuted_dep =
  "@target(erlang)
pub fn run(first a: fn() -> Nil, second b: fn() -> Nil) -> Nil {
  let _ = a
  let _ = b
  Nil
}

@target(javascript)
pub fn run(second a: fn() -> Nil, first b: fn() -> Nil) -> Nil {
  let _ = b
  a()
}
"

pub fn a_published_line_is_read_in_the_variant_each_target_builds_test() {
  let answer = fn(consumer) {
    published_answer(
      "both",
      "[\"erlang\", \"javascript\"]",
      permuted_dep,
      "dep.run(ffi.shout, quiet)",
      consumer,
    )
  }
  #(
    answer("[\"javascript\"]"),
    answer("[\"erlang\"]"),
    answer("[\"erlang\", \"javascript\"]"),
  )
  |> should.equal(
    #(["effects probe.main : [Stdout]"], ["effects probe.main : []"], [
      "effects probe.main : [Stdout]",
    ]),
  )
}

// Each variant runs its first parameter, labelled differently.
const swapped_dep =
  "@target(erlang)
pub fn run(first a: fn() -> Nil, second b: fn() -> Nil) -> Nil {
  let _ = b
  a()
}

@target(javascript)
pub fn run(second a: fn() -> Nil, first b: fn() -> Nil) -> Nil {
  let _ = b
  a()
}
"

pub fn a_one_target_line_is_read_only_on_its_target_test() {
  let answer = fn(publisher, consumer) {
    published_answer(
      "one",
      publisher,
      swapped_dep,
      "dep.run(first: ffi.shout, second: quiet)",
      consumer,
    )
  }
  let both = "[\"erlang\", \"javascript\"]"
  #(
    answer("[\"javascript\"]", "[\"javascript\"]"),
    answer("[\"javascript\"]", "[\"erlang\"]"),
    answer("[\"javascript\"]", both),
    answer("[\"erlang\"]", "[\"erlang\"]"),
    answer("[\"erlang\"]", "[\"javascript\"]"),
    answer("[\"erlang\"]", both),
  )
  |> should.equal(
    #(
      ["effects probe.main : []"],
      ["effects probe.main : [Stdout, Unknown]"],
      ["effects probe.main : [Stdout, Unknown]"],
      ["effects probe.main : [Stdout]"],
      ["effects probe.main : [Stdout, Unknown]"],
      ["effects probe.main : [Stdout, Unknown]"],
    ),
  )
}

// `graded effect` on `query` in a consumer read on both targets, of an
// installed `dep` whose spec graded wrote with `dep`'s own `targets` set to
// `publisher`. `dep/ffi.shout` prints.
fn dependency_query(
  name: String,
  publisher: String,
  dep_source: String,
  call: String,
  query: String,
) -> String {
  let assert Ok(answer) =
    dependency_query_on(name, both_targets, publisher, dep_source, call, query)
  answer
}

// The same with the consumer's `targets` set to `consumer`.
fn dependency_query_on(
  name: String,
  consumer: String,
  publisher: String,
  dep_source: String,
  call: String,
  query: String,
) -> Result(String, graded.GradedError) {
  let directory =
    support.write_fixture("/tmp/graded_dependency_query_" <> name, [
      #(
        "gleam.toml",
        "name = \"probe\"\n\n[tools.graded]\ntargets = " <> consumer <> "\n",
      ),
      #("probe.graded", ""),
      #(
        "src/probe.gleam",
        "import dep\n\nfn quiet() -> Nil {\n  Nil\n}\n\npub fn main() -> Nil {\n  "
          <> call
          <> "\n}\n",
      ),
      #(
        "build/packages/dep/gleam.toml",
        "name = \"dep\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = "
          <> publisher
          <> "\n",
      ),
      #("build/packages/dep/dep.graded", "assume dep/ffi.shout : [Stdout]\n"),
      #(
        "build/packages/dep/src/dep/ffi.gleam",
        "@external(erlang, \"m\", \"shout\")
@external(javascript, \"m\", \"shout\")
pub fn shout() -> Nil
",
      ),
      #("build/packages/dep/src/dep.gleam", dep_source),
    ])
  let assert Ok(Nil) = graded.run_infer(directory <> "/build/packages/dep")
  let answer = graded.run_effect(directory, query)
  support.cleanup(directory)
  answer
}

// The `effects` line an answer states, and whether it names a target nothing
// declares the function on.
fn stated(answer: String) -> #(String, Bool) {
  let lines = string.split(answer, "\n")
  let assert Ok(line) = list.last(lines)
  #(line, list.any(lines, string.contains(_, "nothing declares")))
}

const quiet_or_printing_dep =
  "import dep/ffi

@target(erlang)
pub fn run() -> Nil {
  Nil
}

@target(javascript)
pub fn run() -> Nil {
  ffi.shout()
}
"

pub fn a_direct_query_keeps_a_target_the_dependency_does_not_cover_test() {
  let query = fn(publisher) {
    dependency_query(
      "covered",
      publisher,
      quiet_or_printing_dep,
      "dep.run()",
      "dep.run",
    )
    |> stated
  }
  #(query("[\"erlang\"]"), query("[\"javascript\"]"))
  |> should.equal(#(
    #("effects dep.run : [Unknown]", True),
    #("effects dep.run : [Stdout, Unknown]", True),
  ))
}

pub fn a_direct_query_reads_every_target_the_dependency_covers_test() {
  dependency_query(
    "both",
    "[\"erlang\", \"javascript\"]",
    quiet_or_printing_dep,
    "dep.run()",
    "dep.run",
  )
  |> stated
  |> should.equal(#("effects dep.run : [Stdout]", False))
}

// A function only one target builds adds nothing on the other.
pub fn a_target_building_no_definition_adds_nothing_to_a_direct_query_test() {
  dependency_query(
    "absent",
    "[\"erlang\"]",
    "import dep/ffi

@target(erlang)
pub fn only() -> Nil {
  ffi.shout()
}
",
    "Nil",
    "dep.only",
  )
  |> stated
  |> should.equal(#("effects dep.only : [Stdout]", False))
}

// Each variant names its callback differently, the JavaScript one written
// first.
const renamed_dep =
  "@target(javascript)
pub fn each(g: fn() -> Nil) -> Nil {
  g()
}

@target(erlang)
pub fn each(f: fn() -> Nil) -> Nil {
  f()
}
"

pub fn a_direct_query_states_a_dependency_in_its_published_names_test() {
  let query = fn(publisher) {
    dependency_query(
      "renamed",
      publisher,
      renamed_dep,
      "dep.each(quiet)",
      "dep.each",
    )
    |> stated
  }
  #(
    query("[\"erlang\", \"javascript\"]"),
    query("[\"erlang\"]"),
    query("[\"javascript\"]"),
  )
  |> should.equal(#(
    #("effects dep.each(g: [g]) : [g]", False),
    #("effects dep.each(f: [f]) : [Unknown, f]", True),
    #("effects dep.each(g: [g]) : [Unknown, g]", True),
  ))
}

// Each variant names its callback differently, and returns it.
const renamed_producer_dep =
  "@target(javascript)
pub fn wrap(g: fn() -> Nil) -> fn() -> Nil {
  g
}

@target(erlang)
pub fn wrap(f: fn() -> Nil) -> fn() -> Nil {
  f
}
"

// On one target as on two, a covered answer is stated in the names its
// publisher writes, its returned operator's scoping bounds included.
pub fn a_one_target_query_states_a_dependency_in_its_published_names_test() {
  let query = fn(consumer, publisher, source, call, name) {
    let assert Ok(answer) =
      dependency_query_on(
        "renamed_one",
        consumer,
        publisher,
        source,
        call,
        name,
      )
    let assert Ok(line) = list.last(string.split(answer, "\n"))
    line
  }
  let both = "[\"erlang\", \"javascript\"]"
  let erlang = "[\"erlang\"]"
  let javascript = "[\"javascript\"]"
  #(
    query(erlang, both, renamed_dep, "dep.each(quiet)", "dep.each"),
    query(javascript, both, renamed_dep, "dep.each(quiet)", "dep.each"),
    query(erlang, erlang, renamed_dep, "dep.each(quiet)", "dep.each"),
    query(javascript, javascript, renamed_dep, "dep.each(quiet)", "dep.each"),
    query(erlang, both, renamed_producer_dep, "dep.wrap(quiet)()", "dep.wrap"),
    query(both, both, renamed_producer_dep, "dep.wrap(quiet)()", "dep.wrap"),
  )
  |> should.equal(#(
    "effects dep.each(g: [g]) : [g]",
    "effects dep.each(g: [g]) : [g]",
    "effects dep.each(f: [f]) : [f]",
    "effects dep.each(g: [g]) : [g]",
    "effects dep.wrap(g: [g]) : [] where returns : [g]",
    "effects dep.wrap(g: [g]) : [] where returns : [g]",
  ))
}

// The answers of a consumer read on `targets`, each of `calls` a function
// calling into an installed `dep` whose modules are `dep_files`, beside `extra`
// source and `spec` lines. `dep/ffi.shout` prints.
fn installed_answers(
  name: String,
  targets: String,
  dep_files: List(#(String, String)),
  calls: List(#(String, String)),
  extra: String,
  spec: String,
) -> List(String) {
  let directory =
    support.write_fixture(
      "/tmp/graded_installed_" <> name,
      list.append(
        [
          #(
            "gleam.toml",
            "name = \"probe\"\n\n[tools.graded]\ntargets = " <> targets <> "\n",
          ),
          #("probe.graded", "assume dep/ffi.shout : [Stdout]\n" <> spec),
          #(
            "src/probe.gleam",
            "import dep\nimport dep/service\n\n"
              <> string.concat(
              list.map(calls, fn(call) {
                "pub fn " <> call.0 <> "() -> Nil {\n  " <> call.1 <> "\n}\n\n"
              }),
            )
              <> extra,
          ),
          #(
            "build/packages/dep/gleam.toml",
            "name = \"dep\"\nversion = \"1.0.0\"\n",
          ),
          #(
            "build/packages/dep/src/dep/ffi.gleam",
            "@external(erlang, \"m\", \"shout\")
@external(javascript, \"m\", \"shout\")
pub fn shout() -> Nil
",
          ),
          #(
            "build/packages/dep/src/dep.gleam",
            "pub fn unused() -> Nil {\n  Nil\n}\n",
          ),
        ],
        list.map(dep_files, fn(file) {
          #("build/packages/dep/src/" <> file.0, file.1)
        }),
      ),
    )
  let assert Ok(lines) = graded.inferred_lines_with(directory, types.Active)
  support.cleanup(directory)
  lines
  |> list.filter(fn(line) { !string.starts_with(line, "effects probe/") })
  |> list.sort(string.compare)
}

const both_targets = "[\"erlang\", \"javascript\"]"

// A box holding an integer on Erlang and a function on JavaScript, made and
// consumed by a fallback body that runs on Erlang alone.
fn box_service(box: String) -> List(#(String, String)) {
  [
    #("dep/types.gleam", box),
    #(
      "dep/service.gleam",
      "import dep/types

@external(erlang, \"m\", \"make\")
@external(javascript, \"m\", \"make\")
fn make() -> types.Box

@external(erlang, \"m\", \"sink\")
@external(javascript, \"m\", \"sink\")
fn sink(x: types.Box) -> Nil

@external(javascript, \"m\", \"foo\")
pub fn foo() -> Nil {
  sink(make())
}
",
    ),
  ]
}

const service_spec = "assume dep/service : []\n"

fn service_answers(name: String, box: String, extra: String) -> List(String) {
  installed_answers(
    name,
    both_targets,
    box_service(box),
    [#("main", "service.foo()")],
    extra,
    service_spec,
  )
}

const custom_box =
  "@target(erlang)
pub type Box {
  Box(Int)
}

@target(javascript)
pub type Box {
  Box(fn() -> Nil)
}
"

const alias_box =
  "@target(erlang)
type Held =
  Int

@target(javascript)
type Held =
  fn() -> Nil

pub type Box {
  Box(Held)
}
"

const free_box =
  "@target(erlang)
type Held =
  List(Nil)

@target(javascript)
type Held =
  Nil

pub type Box {
  Box(Held)
}
"

pub fn a_function_capable_type_pair_in_an_installed_package_splits_the_run_test() {
  #(
    service_answers("custom_box", custom_box, ""),
    service_answers("alias_box", alias_box, ""),
    service_answers("free_box", free_box, ""),
    service_answers(
      "forced_box",
      custom_box,
      "@target(erlang)\nfn dummy() -> Nil {\n  Nil\n}\n\n@target(javascript)\nfn dummy() -> Nil {\n  Nil\n}\n",
    ),
  )
  |> should.equal(
    #(
      ["effects probe.main : []"],
      ["effects probe.main : []"],
      [
        "effects probe.main : []",
      ],
      ["effects probe.main : []"],
    ),
  )
}

const fallback_pairs =
  "import dep/ffi

@target(erlang)
fn js_prints() -> Nil {
  Nil
}

@target(javascript)
fn js_prints() -> Nil {
  ffi.shout()
}

@target(erlang)
fn erlang_prints() -> Nil {
  ffi.shout()
}

@target(javascript)
fn erlang_prints() -> Nil {
  Nil
}

fn quiet() -> Nil {
  Nil
}

@target(erlang)
pub const handler: fn() -> Nil = quiet

@target(javascript)
pub const handler: fn() -> Nil = ffi.shout

@target(erlang)
const private_handler: fn() -> Nil = quiet

@target(javascript)
const private_handler: fn() -> Nil = ffi.shout

@external(erlang, \"m\", \"go\")
pub fn runs_js_prints() -> Nil {
  js_prints()
}

@external(erlang, \"m\", \"go\")
pub fn runs_erlang_prints() -> Nil {
  erlang_prints()
}

@external(erlang, \"m\", \"go\")
pub fn runs_private_handler() -> Nil {
  private_handler()
}
"

// What a dependency defines once per target besides a public function or a
// type is read in one pass exactly as each target reads it alone: a private
// function pair a fallback body calls, read where that body runs, and a
// constant pair holding a function value, which no target traces.
pub fn a_dependency_definition_per_target_is_read_as_each_target_reads_it_test() {
  let answers = fn(targets) {
    installed_answers(
      "audit",
      targets,
      [#("dep/service.gleam", fallback_pairs)],
      [
        #("js_prints", "service.runs_js_prints()"),
        #("erlang_prints", "service.runs_erlang_prints()"),
        #("public_constant", "service.handler()"),
        #("private_constant", "service.runs_private_handler()"),
      ],
      "",
      "",
    )
  }
  #(answers(both_targets), answers("[\"javascript\"]"), answers("[\"erlang\"]"))
  |> should.equal(
    #(
      [
        "effects probe.erlang_prints : [Unknown]",
        "effects probe.js_prints : [Stdout, Unknown]",
        "effects probe.private_constant : [Unknown]",
        "effects probe.public_constant : [Unknown]",
      ],
      [
        "effects probe.erlang_prints : []",
        "effects probe.js_prints : [Stdout]",
        "effects probe.private_constant : [Unknown]",
        "effects probe.public_constant : [Unknown]",
      ],
      [
        "effects probe.erlang_prints : [Unknown]",
        "effects probe.js_prints : [Unknown]",
        "effects probe.private_constant : [Unknown]",
        "effects probe.public_constant : [Unknown]",
      ],
    ),
  )
}

// A direct query on one target that builds a variant the dependency does not
// cover answers `[Unknown]`, as the same target does in a run on both.
pub fn a_one_target_query_reads_an_uncovered_variant_as_unknown_test() {
  let query = fn(consumer) {
    dependency_query_on(
      "one_target",
      consumer,
      "[\"erlang\"]",
      quiet_or_printing_dep,
      "dep.run()",
      "dep.run",
    )
    |> result.map(stated)
  }
  #(query("[\"javascript\"]"), query("[\"erlang\"]"))
  |> should.equal(#(
    Ok(#("effects dep.run : [Unknown]", True)),
    Ok(#("effects dep.run : []", False)),
  ))
}

// One package's answers, read on `targets`, where an `@external` declared for
// Erlang alone runs its Gleam body on JavaScript: declared by the dependency's
// own spec, by the consumer's, and by the package's own; a declared `where
// returns` clause over a dependency's and over the package's own; and an
// undeclared external of the package's own whose body calls one callback.
fn fallback_answers(targets: String) -> List(String) {
  let directory =
    support.write_fixture("/tmp/graded_fallback_join", [
      #(
        "gleam.toml",
        "name = \"probe\"\n\n[tools.graded]\ntargets = " <> targets <> "\n",
      ),
      #(
        "probe.graded",
        "assume dep/ffi.shout : [Stdout]
assume dep.consumer_assumed : []
assume probe/own.own_assumed : []
assume probe/own.make : [] where returns : []
",
      ),
      #(
        "build/packages/dep/gleam.toml",
        "name = \"dep\"\nversion = \"1.0.0\"\n",
      ),
      #(
        "build/packages/dep/dep.graded",
        "assume dep/ffi.shout : [Stdout]
assume dep.dep_assumed : []
assume dep.make : [] where returns : []
",
      ),
      #(
        "build/packages/dep/src/dep/ffi.gleam",
        "@external(erlang, \"m\", \"shout\")
@external(javascript, \"m\", \"shout\")
pub fn shout() -> Nil
",
      ),
      #(
        "build/packages/dep/src/dep.gleam",
        "import dep/ffi

@external(erlang, \"dep_ffi\", \"go\")
pub fn dep_assumed() -> Nil {
  ffi.shout()
}

@external(erlang, \"dep_ffi\", \"go\")
pub fn consumer_assumed() -> Nil {
  ffi.shout()
}

@external(erlang, \"dep_ffi\", \"make\")
pub fn make() -> fn() -> Nil {
  ffi.shout
}
",
      ),
      #(
        "src/probe/own.gleam",
        "import dep/ffi

@external(erlang, \"own_ffi\", \"go\")
pub fn own_assumed() -> Nil {
  ffi.shout()
}

@external(erlang, \"own_ffi\", \"make\")
pub fn make() -> fn() -> Nil {
  ffi.shout
}

@external(erlang, \"own_ffi\", \"crossed\")
pub fn crossed(f: fn() -> Nil, g: fn() -> Nil) -> Nil {
  let _ = g
  f()
}
",
      ),
      #(
        "src/probe.gleam",
        "import dep
import probe/own

pub fn via_dep_spec() -> Nil {
  dep.dep_assumed()
}

pub fn via_consumer_spec() -> Nil {
  dep.consumer_assumed()
}

pub fn via_own_spec() -> Nil {
  own.own_assumed()
}

pub fn via_dep_returns() -> Nil {
  dep.make()()
}

pub fn via_own_returns() -> Nil {
  own.make()()
}
",
      ),
    ])
  let assert Ok(lines) = graded.inferred_lines_with(directory, types.Active)
  support.cleanup(directory)
  list.filter(lines, fn(line) {
    string.starts_with(line, "effects probe.")
    || string.starts_with(line, "effects probe/own.crossed")
  })
  |> list.sort(string.compare)
}

pub fn a_declaration_answers_only_on_the_targets_its_external_covers_test() {
  #(
    fallback_answers(both_targets),
    fallback_answers("[\"javascript\"]"),
    fallback_answers("[\"erlang\"]"),
  )
  |> should.equal(
    #(
      [
        "effects probe.via_consumer_spec : [Stdout]",
        "effects probe.via_dep_returns : [Unknown]",
        "effects probe.via_dep_spec : [Stdout]",
        "effects probe.via_own_returns : [Stdout]",
        "effects probe.via_own_spec : [Stdout]",
        "effects probe/own.crossed(f: [f]) : [Unknown, f]",
      ],
      [
        "effects probe.via_consumer_spec : [Stdout]",
        "effects probe.via_dep_returns : [Unknown]",
        "effects probe.via_dep_spec : [Stdout]",
        "effects probe.via_own_returns : [Stdout]",
        "effects probe.via_own_spec : [Stdout]",
        "effects probe/own.crossed(f: [f]) : [f]",
      ],
      [
        "effects probe.via_consumer_spec : []",
        "effects probe.via_dep_returns : []",
        "effects probe.via_dep_spec : []",
        "effects probe.via_own_returns : []",
        "effects probe.via_own_spec : []",
        "effects probe/own.crossed : [Unknown]",
      ],
    ),
  )
}

// Declarations over `@external`s on Erlang whose Gleam bodies print, or hand
// back or run a printer: what a result carries, as an installed dependency's
// own spec, the consumer's and an own module's say; what a function runs;
// and an own producer whose quiet body calls another such producer.
fn clause_answers(targets: String) -> List(String) {
  let directory =
    support.write_fixture("/tmp/graded_clause_reach", [
      #(
        "gleam.toml",
        "name = \"probe\"\n\n[tools.graded]\ntargets = " <> targets <> "\n",
      ),
      #(
        "probe.graded",
        "assume dep/ffi.shout : [Stdout]
assume dep/ffi.sink : []
assume dep.consumer_carried : [] where carries : []
assume probe/own.carried : [] where carries : []
assume probe/own.keep(value: [v]) : [] where runs : []
assume probe/own.chained : [] where returns : []
assume probe/own.inner : [] where returns : []
",
      ),
      #(
        "build/packages/dep/gleam.toml",
        "name = \"dep\"\nversion = \"1.0.0\"\n",
      ),
      #(
        "build/packages/dep/dep.graded",
        "assume dep/ffi.shout : [Stdout]
assume dep.dep_carried : [] where carries : []
",
      ),
      #(
        "build/packages/dep/src/dep/ffi.gleam",
        "@external(erlang, \"m\", \"shout\")
@external(javascript, \"m\", \"shout\")
pub fn shout() -> Nil

@external(erlang, \"m\", \"sink\")
@external(javascript, \"m\", \"sink\")
pub fn sink(x: a) -> Nil
",
      ),
      #(
        "build/packages/dep/src/dep.gleam",
        "import dep/ffi

pub type Box {
  Box(run: fn() -> Nil)
}

@external(erlang, \"dep_ffi\", \"make\")
pub fn dep_carried() -> Box {
  Box(ffi.shout)
}

@external(erlang, \"dep_ffi\", \"make\")
pub fn consumer_carried() -> Box {
  Box(ffi.shout)
}
",
      ),
      #(
        "src/probe/own.gleam",
        "import dep/ffi

pub type Box {
  Box(run: fn() -> Nil)
}

@external(erlang, \"own_ffi\", \"make\")
pub fn carried() -> Box {
  Box(ffi.shout)
}

@external(erlang, \"own_ffi\", \"keep\")
pub fn keep(value: #(fn() -> Nil, Int)) -> Nil {
  let #(f, _) = value
  f()
}

@external(erlang, \"own_ffi\", \"chained\")
pub fn chained() -> fn() -> Nil {
  inner()
}

@external(erlang, \"own_ffi\", \"inner\")
pub fn inner() -> fn() -> Nil {
  fn() { Nil }
}
",
      ),
      #(
        "src/probe.gleam",
        "import dep
import dep/ffi
import probe/own

pub fn via_dep_carries() -> Nil {
  ffi.sink(dep.dep_carried())
}

pub fn via_consumer_carries() -> Nil {
  ffi.sink(dep.consumer_carried())
}

pub fn via_own_carries() -> Nil {
  ffi.sink(own.carried())
}

pub fn via_own_runs() -> Nil {
  own.keep(#(ffi.shout, 0))
}

pub fn via_own_chain() -> Nil {
  own.chained()()
}
",
      ),
    ])
  let assert Ok(lines) = graded.inferred_lines_with(directory, types.Active)
  support.cleanup(directory)
  list.filter(lines, fn(line) { string.starts_with(line, "effects probe.") })
  |> list.sort(string.compare)
}

// Every clause answers on the target its external covers and nowhere else: on
// a target the body runs on, alone or beside the covered one, what the body
// carries or runs is read as `[Unknown]`, and a producer's quiet body calling
// another quiet producer reads `[]` there, as each target alone does.
pub fn every_clause_answers_only_on_the_targets_its_external_covers_test() {
  #(
    clause_answers(both_targets),
    clause_answers("[\"javascript\"]"),
    clause_answers("[\"erlang\"]"),
  )
  |> should.equal(
    #(
      [
        "effects probe.via_consumer_carries : [Unknown]",
        "effects probe.via_dep_carries : [Unknown]",
        "effects probe.via_own_carries : [Unknown]",
        "effects probe.via_own_chain : []",
        "effects probe.via_own_runs : [Unknown]",
      ],
      [
        "effects probe.via_consumer_carries : [Unknown]",
        "effects probe.via_dep_carries : [Unknown]",
        "effects probe.via_own_carries : [Unknown]",
        "effects probe.via_own_chain : []",
        "effects probe.via_own_runs : [Unknown]",
      ],
      [
        "effects probe.via_consumer_carries : []",
        "effects probe.via_dep_carries : []",
        "effects probe.via_own_carries : []",
        "effects probe.via_own_chain : []",
        "effects probe.via_own_runs : []",
      ],
    ),
  )
}

// A catalog line over an Erlang `@external` whose audit marks its result a
// container, the source scan's record of the external for a package read on
// `targets`, its quiet Gleam body running wherever the declaration is not
// built, and a consumer handing what it returns to a line that runs it.
fn container_answer(targets: List(String)) -> types.EffectSet {
  let name = types.QualifiedName("fake/box", "make")
  let parse = fn(line) {
    let assert Ok(types.GradedFile(lines: [types.AssumeLine(assume, _)])) =
      annotation.parse_file_with(line, types.Active)
    assume
  }
  let assert Ok(box) =
    glance.module(
      "pub type Box {\n  Box(run: fn() -> Nil)\n}\n\n@external(erlang, \"m\", \"make\")\npub fn make() -> Box {\n  Box(fn() { Nil })\n}\n",
    )
  let assert Ok(consumer) =
    glance.module(
      "import app/ffi\nimport fake/box\n\npub fn go() -> Nil {\n  ffi.sink(box.make())\n}\n",
    )
  let package_targets = types.NamedTargets(set.from_list(targets))
  let knowledge_base =
    effects.new_knowledge_base()
    |> effects.with_lat_mode(types.Active)
    |> effects.with_package_targets(package_targets)
    |> effects.with_assumes(
      [parse("assume fake/box.make : []")],
      types.Catalog("fake"),
    )
    |> effects.with_assumes(
      [parse("assume app/ffi.sink : []")],
      types.UserAssume,
    )
    |> effects.with_audit(
      effects.CatalogAudit(
        ..effects.empty_audit(),
        reviewed: set.from_list([name]),
        container_results: set.from_list([name]),
      ),
    )
    |> effects.with_dependency_foreign(
      dict.from_list([
        #(
          name,
          types.ForeignFunction(
            runs_fallback_body: targets != ["erlang"],
            compiled_targets: set.from_list(targets),
            declared_targets: set.from_list(["erlang"]),
          ),
        ),
      ]),
    )
    |> effects.with_fallback_summaries(
      dict.from_list([#(name, #(effect_term.pure(), []))]),
    )
  let registry =
    signatures.from_glance_module("fake/box", box)
    |> signatures.with_types(typedefs.from_module(
      "fake/box",
      box,
      set.from_list(targets),
    ))
  let assert [annotation] =
    checker.infer(
      consumer,
      "app",
      knowledge_base,
      [],
      registry,
      typeinfo.no_reading(),
      package_targets,
    )
  effect_term.to_effect_set(annotation.effects)
}

// What an audit derives a container result's contract to say answers only
// where the external is built, like a written clause: read where the Gleam
// body runs, alone or beside the covered target, the result is `[Unknown]`.
pub fn a_derived_container_contract_answers_only_where_its_external_covers_test() {
  #(
    container_answer(["erlang", "javascript"]),
    container_answer(["erlang"]),
    container_answer(["javascript"]),
  )
  |> should.equal(#(
    types.from_labels(["Unknown"]),
    types.empty(),
    types.from_labels(["Unknown"]),
  ))
}

// A spec-less path dependency defining `make` once per target, each variant
// naming its callback differently, read by a consumer on `consumer`, with its
// spec published first where `published`: the direct answer on `dep.make`.
fn fresh_answer(consumer: String, published: Bool) -> String {
  let root = "build/graded_fresh_query_" <> string.inspect(published)
  support.write_fixture(root, [
    #(
      "app/gleam.toml",
      "name = \"app\"\nversion = \"1.0.0\"\n\n[dependencies]\ndep = { path = \"../dep\" }\n\n[tools.graded]\ntargets = "
        <> consumer
        <> "\n",
    ),
    #("app/app.graded", ""),
    #(
      "app/src/app.gleam",
      "import dep\n\nfn quiet() -> Nil {\n  Nil\n}\n\npub fn main() -> Nil {\n  dep.make(quiet)()\n}\n",
    ),
    #(
      "dep/gleam.toml",
      "name = \"dep\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
    ),
    #("dep/src/dep.gleam", renamed_producer_dep_erlang_first),
  ])
  let _ = case published {
    True -> graded.run_infer(root <> "/dep")
    False -> Ok(Nil)
  }
  let assert Ok(answer) = graded.run_effect(root <> "/app", "dep.make")
  support.cleanup(root)
  let assert Ok(line) = list.last(string.split(answer, "\n"))
  line
}

// Each variant names its callback differently, the Erlang one written first.
const renamed_producer_dep_erlang_first =
  "@target(erlang)
pub fn make(f: fn() -> Nil) -> fn() -> Nil {
  f
}

@target(javascript)
pub fn make(g: fn() -> Nil) -> fn() -> Nil {
  g
}
"

// Inferred over a spec-less path dependency's source, a direct answer names
// its variables as its publisher names its parameters, on every target the
// consumer reads, as it does once the spec is published.
pub fn a_fresh_dependency_summary_is_stated_in_its_published_names_test() {
  let stated = "effects dep.make(f: [f]) : [] where returns : [f]"
  [
    fresh_answer("[\"erlang\"]", False),
    fresh_answer("[\"javascript\"]", False),
    fresh_answer("[\"erlang\", \"javascript\"]", False),
    fresh_answer("[\"javascript\"]", True),
  ]
  |> should.equal([stated, stated, stated, stated])
}

// A path dependency defining `dep_source`, read for both targets, with its
// spec published first where `published`, beside an app read on `consumer`
// whose `main` is `body` and whose spec holds `spec` too: `main`'s answer,
// or the direct answer on `query` where one is given.
fn path_dependency_reading(
  name: String,
  consumer: String,
  dep_source: String,
  published: Bool,
  spec: String,
  body: String,
  query: Result(String, Nil),
) -> String {
  let root = "build/graded_path_reading_" <> name
  support.write_fixture(root, [
    #(
      "app/gleam.toml",
      "name = \"app\"\nversion = \"1.0.0\"\n\n[dependencies]\ndep = { path = \"../dep\" }\n\n[tools.graded]\ntargets = "
        <> consumer
        <> "\n",
    ),
    #("app/app.graded", "assume app/ffi.shout : [Stdout]\n" <> spec),
    #(
      "app/src/app/ffi.gleam",
      "@external(erlang, \"m\", \"shout\")\n@external(javascript, \"m\", \"shout\")\npub fn shout() -> Nil\n",
    ),
    #(
      "app/src/app.gleam",
      "import app/ffi\nimport dep\n\nfn quiet() -> Nil {\n  Nil\n}\n\npub fn main() -> Nil {\n  let _ = ffi.shout\n  let _ = quiet\n  "
        <> body
        <> "\n}\n",
    ),
    #(
      "dep/gleam.toml",
      "name = \"dep\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
    ),
    #("dep/src/dep.gleam", dep_source),
  ])
  let _ = case published {
    True -> graded.run_infer(root <> "/dep")
    False -> Ok(Nil)
  }
  let line = case query {
    Ok(name) -> {
      let assert Ok(answer) = graded.run_effect(root <> "/app", name)
      let assert Ok(line) = list.last(string.split(answer, "\n"))
      line
    }
    Error(Nil) -> {
      let assert Ok(lines) =
        graded.inferred_lines_with(root <> "/app", types.Active)
      let assert Ok(line) =
        list.find(lines, string.starts_with(_, "effects app.main"))
      line
    }
  }
  support.cleanup(root)
  line
}

// Each variant returns its first argument, the two naming them in swapped
// order.
const swapped_producer_dep =
  "@target(erlang)
pub fn make(first: fn() -> Nil, second: fn() -> Nil) -> fn() -> Nil {
  let _ = second
  first
}

@target(javascript)
pub fn make(second: fn() -> Nil, first: fn() -> Nil) -> fn() -> Nil {
  let _ = first
  second
}
"

// A published returned operator is bound to the argument its line's bound
// introduces in the variant the reader builds, never to a parameter of the
// reader's that happens to share its variable's spelling: a quiet first
// argument beside an unused printer stays quiet on every target, published or
// not, as does a callback each variant names differently.
pub fn a_published_returned_operator_binds_the_argument_its_bound_introduces_test() {
  let swapped = fn(consumer, published) {
    path_dependency_reading(
      "swap",
      consumer,
      swapped_producer_dep,
      published,
      "",
      "let f = dep.make(quiet, ffi.shout)\n  f()",
      Error(Nil),
    )
  }
  let renamed = fn(consumer) {
    path_dependency_reading(
      "renamed",
      consumer,
      renamed_producer_dep_erlang_first,
      True,
      "",
      "let f = dep.make(quiet)\n  f()",
      Error(Nil),
    )
  }
  let quiet = "effects app.main : []"
  [
    swapped("[\"erlang\"]", True),
    swapped("[\"javascript\"]", True),
    swapped("[\"erlang\", \"javascript\"]", True),
    swapped("[\"javascript\"]", False),
    renamed("[\"javascript\"]"),
    renamed("[\"erlang\", \"javascript\"]"),
  ]
  |> should.equal([quiet, quiet, quiet, quiet, quiet, quiet])
}

// Where the consumer's line answers for a spec-less dependency's effects and
// its source answers for the operator it returns, each half is stated in the
// publisher's names by its own origin.
pub fn each_half_of_a_mixed_answer_is_stated_by_its_own_origin_test() {
  let query = fn(consumer) {
    path_dependency_reading(
      "mixed",
      consumer,
      renamed_producer_dep_erlang_first,
      False,
      "assume dep.make : []\n",
      "let f = dep.make(quiet)\n  f()",
      Ok("dep.make"),
    )
  }
  let stated = "effects dep.make : [] where returns : [f]"
  [
    query("[\"erlang\"]"),
    query("[\"javascript\"]"),
    query("[\"erlang\", \"javascript\"]"),
  ]
  |> should.equal([stated, stated, stated])
}

// The consumer's own line over a dependency's function defined once per
// target, written in the names the dependency publishes, is read in the
// variant the consumer's target builds: a quiet callback handed back stays
// quiet on every target.
pub fn a_consumer_line_over_a_dependency_pair_is_read_in_the_variant_built_test() {
  let answer = fn(consumer) {
    path_dependency_reading(
      "consumer_line",
      consumer,
      renamed_producer_dep_erlang_first,
      False,
      "assume dep.make(f: [f]) where returns : [f]\n",
      "let f = dep.make(quiet)\n  f()",
      Error(Nil),
    )
  }
  let quiet = "effects app.main : []"
  [
    answer("[\"erlang\"]"),
    answer("[\"javascript\"]"),
    answer("[\"erlang\", \"javascript\"]"),
  ]
  |> should.equal([quiet, quiet, quiet])
}

// A path dependency read for both targets, defining `make` once per target:
// each variant runs its first callback and returns what it returns, the
// Erlang one naming its callbacks `cb` and `e`, the JavaScript one `x` and
// `q`. Its spec holds `dep_spec`, where that is not empty, a catalog file for
// it `catalog` where one is given, and the app read on `consumer` holds `spec` and hands `make` a
// callback returning a box of `first`, then one returning a box of `second`:
// `main`'s answer.
fn callback_result_reading(
  name: String,
  consumer: String,
  dep_spec: String,
  catalog: Result(String, Nil),
  spec: String,
  first: String,
  second: String,
) -> String {
  let root = "build/graded_callback_result_" <> name
  support.write_fixture(root, [
    #(
      "app/gleam.toml",
      "name = \"app\"\nversion = \"1.0.0\"\n\n[dependencies]\ndep = { path = \"../dep\" }\n\n[tools.graded]\ntargets = "
        <> consumer
        <> "\n",
    ),
    #(
      "app/manifest.toml",
      "packages = [\n  { name = \"dep\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"../dep\" },\n]\n\n[requirements]\ndep = { path = \"../dep\" }\n",
    ),
    #(
      "app/app.graded",
      "assume app/ffi.shout : [Stdout]\nassume app/ffi.sink : []\n" <> spec,
    ),
    #(
      "app/src/app/ffi.gleam",
      "import dep\n\n@external(erlang, \"m\", \"shout\")\n@external(javascript, \"m\", \"shout\")\npub fn shout() -> Nil\n\n@external(erlang, \"m\", \"sink\")\n@external(javascript, \"m\", \"sink\")\npub fn sink(box: dep.Box) -> Nil\n",
    ),
    #(
      "app/src/app.gleam",
      "import app/ffi\nimport dep\n\nfn quiet() -> Nil {\n  Nil\n}\n\npub fn main() -> Nil {\n  let _ = ffi.shout\n  let _ = quiet\n  ffi.sink(dep.make(fn() { dep.Box("
        <> first
        <> ") }, fn() { dep.Box("
        <> second
        <> ") }))\n}\n",
    ),
    #(
      "dep/gleam.toml",
      "name = \"dep\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
    ),
    #(
      "dep/src/dep.gleam",
      "pub type Box {\n  Box(run: fn() -> Nil)\n}\n\n@target(erlang)\npub fn make(cb: fn() -> Box, e: fn() -> Box) -> Box {\n  let _ = e\n  cb()\n}\n\n@target(javascript)\npub fn make(x: fn() -> Box, q: fn() -> Box) -> Box {\n  let _ = q\n  x()\n}\n",
    ),
  ])
  let _ = case dep_spec {
    "" -> Nil
    _ -> support.write_file(root <> "/dep/dep.graded", dep_spec)
  }
  let catalog_file = "priv/catalog/dep@1.0.0"
  let _ = case catalog {
    Ok(line) -> {
      support.write_file(catalog_file <> ".graded", line)
      support.write_file(
        catalog_file <> ".audit",
        "covers 1.0.0\nreviewed dep.make\n",
      )
    }
    Error(Nil) -> Nil
  }
  let lines = graded.inferred_lines_with(root <> "/app", types.Active)
  let _ = simplifile.delete(catalog_file <> ".graded")
  let _ = simplifile.delete(catalog_file <> ".audit")
  support.cleanup(root)
  let assert Ok(lines) = lines
  let assert Ok(line) =
    list.find(lines, string.starts_with(_, "effects app.main"))
  line
}

// The line both variants of `callback_result_reading`'s `make` satisfy, in
// the names its publisher writes: the first callback runs, and the result
// carries what that callback returns.
const runs_first_and_returns_its_result =
  "assume dep.make(cb: [e], e: [q]) : [e] where carries : [e.returns]\n"

// What a callback returns is read through the bound that introduces the
// callback's variable, wherever the line came from and whatever parameter
// shares that variable's spelling: the printer the first callback returns is
// charged on every target, and a printer the second one returns is not.
pub fn a_callback_result_follows_the_bound_that_introduces_its_variable_test() {
  let read = fn(name, consumer, dep_spec, spec, first, second) {
    callback_result_reading(
      name,
      consumer,
      dep_spec,
      Error(Nil),
      spec,
      first,
      second,
    )
  }
  let line = runs_first_and_returns_its_result
  [
    read("dep_js", "[\"javascript\"]", line, "", "ffi.shout", "quiet"),
    read("dep_erl", "[\"erlang\"]", line, "", "ffi.shout", "quiet"),
    read(
      "dep_both",
      "[\"erlang\", \"javascript\"]",
      line,
      "",
      "ffi.shout",
      "quiet",
    ),
    read("own_js", "[\"javascript\"]", "", line, "ffi.shout", "quiet"),
    read("second_js", "[\"javascript\"]", line, "", "quiet", "ffi.shout"),
  ]
  |> should.equal([
    "effects app.main : [Stdout]",
    "effects app.main : [Stdout]",
    "effects app.main : [Stdout]",
    "effects app.main : [Stdout]",
    "effects app.main : []",
  ])
}

// A catalog line over a dependency's function defined once per target is in
// the names the dependency's own target configuration publishes, and is read
// in the variant the consumer's target builds: quiet callbacks stay quiet on
// every target, and a printer the first one returns is charged.
pub fn a_catalog_line_over_a_dependency_pair_is_read_in_the_variant_built_test() {
  let read = fn(name, consumer, first) {
    callback_result_reading(
      name,
      consumer,
      "",
      Ok(runs_first_and_returns_its_result),
      "",
      first,
      "quiet",
    )
  }
  [
    read("catalog_js", "[\"javascript\"]", "quiet"),
    read("catalog_erl", "[\"erlang\"]", "quiet"),
    read("catalog_both", "[\"erlang\", \"javascript\"]", "quiet"),
    read("catalog_loud", "[\"javascript\"]", "ffi.shout"),
  ]
  |> should.equal([
    "effects app.main : []",
    "effects app.main : []",
    "effects app.main : []",
    "effects app.main : [Stdout]",
  ])
}

// A path dependency read for both targets defining `dep_source`, beside an
// app read on `consumer` whose module is `app_source` and whose spec holds
// `spec`: `main`'s inferred line, or `Error` where the run stops.
fn kind_reading(
  name: String,
  consumer: String,
  dep_source: String,
  spec: String,
  app_source: String,
) -> Result(String, Nil) {
  let root = "build/graded_kind_reading_" <> name
  support.write_fixture(root, [
    #(
      "app/gleam.toml",
      "name = \"app\"\nversion = \"1.0.0\"\n\n[dependencies]\ndep = { path = \"../dep\" }\n\n[tools.graded]\ntargets = "
        <> consumer
        <> "\n",
    ),
    #("app/app.graded", spec),
    #("app/src/app.gleam", app_source),
    #(
      "dep/gleam.toml",
      "name = \"dep\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
    ),
    #("dep/src/dep.gleam", dep_source),
  ])
  let lines = graded.inferred_lines_with(root <> "/app", types.Active)
  support.cleanup(root)
  use lines <- result.try(lines |> result.replace_error(Nil))
  list.find(lines, string.starts_with(_, "effects app.main"))
}

// The first argument is a callback on both targets; the JavaScript variant
// spells the box it ignores `cb`.
const kind_pair_dep =
  "pub type Box {
  Box(run: fn() -> Nil)
}

@target(erlang)
pub fn call(cb: fn() -> Nil, value: Box) -> Nil {
  let _ = value
  cb()
}

@target(javascript)
pub fn call(x: fn() -> Nil, cb: Box) -> Nil {
  let _ = cb
  x()
}
"

// The first argument is a callback taking nothing on both targets; the
// JavaScript variant spells the one-argument callback it ignores `cb`.
const arity_pair_dep =
  "@target(erlang)
pub fn call(cb: fn() -> Nil, value: fn(Nil) -> Nil) -> Nil {
  let _ = value
  cb()
}

@target(javascript)
pub fn call(x: fn() -> Nil, cb: fn(Nil) -> Nil) -> Nil {
  let _ = cb
  x()
}
"

// The consumer's own line over a dependency's function defined once per
// target is weighed in the variant the run builds, against that variant's
// signature: a line valid in both variants is read on every target, where
// the reader spells a parameter of another kind or arity as the publisher
// spells the one the line bounds.
pub fn a_consumer_line_is_weighed_in_the_variant_the_run_builds_test() {
  let kind = fn(consumer) {
    kind_reading(
      "kind",
      consumer,
      kind_pair_dep,
      "assume dep.call(cb: [e]) : [e]\n",
      "import dep\n\nfn quiet() -> Nil {\n  Nil\n}\n\npub fn main() -> Nil {\n  dep.call(quiet, dep.Box(quiet))\n}\n",
    )
  }
  let arity = fn(consumer) {
    kind_reading(
      "arity",
      consumer,
      arity_pair_dep,
      "assume dep.call(cb: [e]) : [e] where runs : [], relay : e()\n",
      "import dep\n\nfn quiet() -> Nil {\n  Nil\n}\n\npub fn main() -> Nil {\n  dep.call(quiet, fn(_v) { Nil })\n}\n",
    )
  }
  let quiet = Ok("effects app.main : []")
  [
    kind("[\"javascript\"]"),
    kind("[\"erlang\", \"javascript\"]"),
    kind("[\"erlang\"]"),
    arity("[\"javascript\"]"),
    arity("[\"erlang\", \"javascript\"]"),
  ]
  |> should.equal([quiet, quiet, quiet, quiet, quiet])
}

// Where the variants genuinely differ, the first argument a callback on
// Erlang and a box on JavaScript, the line is refused on JavaScript alone and
// read on Erlang; a run on JavaScript alone stops on it, as on any line the
// rules forbid.
pub fn a_consumer_line_invalid_in_one_variant_is_refused_there_only_test() {
  let dep_source =
    "pub type Box {
  Box(run: fn() -> Nil)
}

@target(erlang)
pub fn call(cb: fn() -> Nil, value: fn() -> Nil) -> Nil {
  let _ = value
  cb()
}

@target(javascript)
pub fn call(cb: Box, value: fn() -> Nil) -> Nil {
  let _ = cb
  value()
}
"
  let app_source =
    "import dep\n\nfn quiet() -> Nil {\n  Nil\n}\n\n@target(erlang)\npub fn main() -> Nil {\n  dep.call(quiet, quiet)\n}\n\n@target(javascript)\npub fn main() -> Nil {\n  dep.call(dep.Box(quiet), quiet)\n}\n"
  let read = fn(consumer) {
    kind_reading(
      "genuine",
      consumer,
      dep_source,
      "assume dep.call(cb: [e]) : [e]\n",
      app_source,
    )
  }
  [
    read("[\"erlang\"]"),
    read("[\"erlang\", \"javascript\"]"),
    read("[\"javascript\"]"),
  ]
  |> should.equal([
    Ok("effects app.main : []"),
    Ok("effects app.main : [_]"),
    Error(Nil),
  ])
}

// A dependency with `modules` modules each defining a function once per
// target, and a `gleam.toml` of `keys` further entries, read by an app on
// JavaScript alone: the reductions one inference of the app spends.
fn wide_pair_work(modules: Int, keys: Int) -> Int {
  let root = "build/graded_wide_pairs"
  let indices =
    int.range(from: modules - 1, to: -1, with: [], run: list.prepend)
  let entries =
    int.range(from: keys - 1, to: -1, with: [], run: list.prepend)
    |> list.map(fn(k) {
      "key_" <> int.to_string(k) <> " = " <> int.to_string(k) <> "\n"
    })
    |> string.concat
  support.write_fixture(root, [
    #(
      "app/gleam.toml",
      "name = \"app\"\nversion = \"1.0.0\"\n\n[dependencies]\ndep = { path = \"../dep\" }\n\n[tools.graded]\ntargets = [\"javascript\"]\n",
    ),
    #("app/app.graded", ""),
    #(
      "app/src/app.gleam",
      "import dep/m0\n\npub fn main() -> Nil {\n  m0.f()\n}\n",
    ),
    #(
      "dep/gleam.toml",
      "name = \"dep\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n\n[tools.sample]\n"
        <> entries,
    ),
    ..list.map(indices, fn(i) {
      #(
        "dep/src/dep/m" <> int.to_string(i) <> ".gleam",
        "@target(erlang)\npub fn f() -> Nil {\n  Nil\n}\n\n@target(javascript)\npub fn f() -> Nil {\n  Nil\n}\n",
      )
    })
  ])
  let before = reductions()
  let assert Ok(_) = graded.inferred_lines_with(root <> "/app", types.Active)
  let spent = reductions() - before
  support.cleanup(root)
  spent
}

// A dependency's configuration is read once per run, however many of its
// modules define a function once per target and however large it is.
pub fn a_dependency_configuration_is_read_once_per_run_test() {
  { wide_pair_work(64, 1024) <= 20_000_000 } |> should.be_true
}

// A path dependency read for both targets defining `count` functions once per
// target, each taking a callback on Erlang and a box on JavaScript, beside an
// app read on both whose spec bounds every one so that only Erlang can read
// the line: `main`'s inferred line and the reductions the inference spends.
fn refused_lines_work(count: Int) -> #(Result(String, Nil), Int) {
  let root = "build/graded_refused_lines"
  let indices = int.range(from: count - 1, to: -1, with: [], run: list.prepend)
  let name = fn(i) { "f" <> int.to_string(i) }
  support.write_fixture(root, [
    #(
      "app/gleam.toml",
      "name = \"app\"\nversion = \"1.0.0\"\n\n[dependencies]\ndep = { path = \"../dep\" }\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
    ),
    #(
      "app/app.graded",
      list.map(indices, fn(i) {
        "assume dep." <> name(i) <> "(cb: [e]) : [e]\n"
      })
        |> string.concat,
    ),
    #("app/src/app.gleam", "pub fn main() -> Nil {\n  Nil\n}\n"),
    #(
      "dep/gleam.toml",
      "name = \"dep\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
    ),
    #(
      "dep/src/dep.gleam",
      "pub type Box {\n  Box(run: fn() -> Nil)\n}\n\n"
        <> string.concat(
        list.map(indices, fn(i) {
          "@target(erlang)\npub fn "
          <> name(i)
          <> "(cb: fn() -> Nil) -> Nil {\n  cb()\n}\n\n@target(javascript)\npub fn "
          <> name(i)
          <> "(cb: Box) -> Nil {\n  cb.run()\n}\n\n"
        }),
      ),
    ),
  ])
  let before = reductions()
  let lines = graded.inferred_lines_with(root <> "/app", types.Active)
  let spent = reductions() - before
  support.cleanup(root)
  let line =
    lines
    |> result.replace_error(Nil)
    |> result.try(list.find(_, string.starts_with(_, "effects app.main")))
  #(line, spent)
}

// Lines refused on one target of a run on two are each quoted from one
// reading of the spec, so many of them cost what reading them does.
pub fn refused_lines_are_quoted_from_one_reading_of_the_spec_test() {
  let #(line, spent) = refused_lines_work(384)
  line |> should.equal(Ok("effects app.main : []"))
  { spent <= 40_000_000 } |> should.be_true
}

// A package read on both targets with one function defined once per target
// and `pairs` more, each beside an `effects` and a `check` line where
// `committed`, and `warnings` `check` lines naming nothing: the reductions
// `run` spends and the warnings it reports, or those `infer` spends.
fn package_work(
  pairs: Int,
  committed: Bool,
  warnings: Int,
  command: String,
) -> #(Int, Int) {
  let root = "build/graded_package_work"
  let indices = int.range(from: pairs - 1, to: -1, with: [], run: list.prepend)
  let name = fn(i) { "app.f" <> int.to_string(i) }
  let pair = fn(i) {
    let s = int.to_string(i)
    "@target(erlang)\npub fn f"
    <> s
    <> "(cb: fn() -> Nil) -> Nil {\n  let _ = cb\n  Nil\n}\n\n@target(javascript)\npub fn f"
    <> s
    <> "(x: fn() -> Nil) -> Nil {\n  let _ = x\n  Nil\n}\n\n"
  }
  let spec =
    case committed {
      True ->
        list.map(indices, fn(i) {
          "effects " <> name(i) <> " : []\ncheck " <> name(i) <> " : []\n"
        })
      False -> []
    }
    |> list.append(
      int.range(from: warnings - 1, to: -1, with: [], run: list.prepend)
      |> list.map(fn(i) {
        "check app.missing_" <> int.to_string(i) <> " : []\n"
      }),
    )
    |> string.concat
  support.write_fixture(root, [
    #(
      "gleam.toml",
      "name = \"app\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
    ),
    #("app.graded", spec),
    #(
      "src/app.gleam",
      "@target(erlang)\npub fn g() -> Nil {\n  Nil\n}\n\n@target(javascript)\npub fn g() -> Nil {\n  Nil\n}\n\n"
        <> string.concat(list.map(indices, pair))
        <> "pub fn main() -> Nil {\n  Nil\n}\n",
    ),
  ])
  let before = reductions()
  let reported = case command {
    "infer" -> {
      let assert Ok(_) = graded.inferred_lines_with(root, types.Active)
      0
    }
    _ -> {
      let assert Ok(reports) = graded.run(root)
      list.flat_map(reports, fn(report) { report.warnings }) |> list.length
    }
  }
  let spent = reductions() - before
  support.cleanup(root)
  #(spent, reported)
}

// Four times the warnings, or four times the functions defined once per
// target, cost at most six times the work: each warning is counted, each
// committed line weighed and each public line joined through an index read
// once, not a scan per item.
pub fn a_package_s_own_pairs_and_warnings_cost_linear_work_test() {
  let ratio = fn(small: #(Int, Int), large: #(Int, Int)) {
    large.0 <= 6 * small.0
  }
  let warnings_small = package_work(0, False, 1024, "check")
  let warnings_large = package_work(0, False, 4096, "check")
  let infer_small = package_work(512, False, 0, "infer")
  let infer_large = package_work(2048, False, 0, "infer")
  let check_small = package_work(512, True, 0, "check")
  let check_large = package_work(2048, True, 0, "check")
  #(
    warnings_small.1,
    warnings_large.1,
    ratio(warnings_small, warnings_large),
    ratio(infer_small, infer_large),
    ratio(check_small, check_large),
  )
  |> should.equal(#(1024, 4096, True, True, True))
}

// A dependency defining `call` once per target whose first parameter is a
// box on both, beside an app read on `consumer` whose spec holds `spec`: the
// error the inference stops on.
fn quoted_error(consumer: String, spec: String) -> String {
  let root = "build/graded_quoted_error"
  support.write_fixture(root, [
    #(
      "app/gleam.toml",
      "name = \"app\"\nversion = \"1.0.0\"\n\n[dependencies]\ndep = { path = \"../dep\" }\n\n[tools.graded]\ntargets = "
        <> consumer
        <> "\n",
    ),
    #("app/app.graded", spec),
    #(
      "app/src/app.gleam",
      "import dep\n\nfn quiet() -> Nil {\n  Nil\n}\n\npub fn main() -> Nil {\n  dep.call(dep.Box(quiet), quiet)\n}\n",
    ),
    #(
      "dep/gleam.toml",
      "name = \"dep\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
    ),
    #(
      "dep/src/dep.gleam",
      "pub type Box {\n  Box(run: fn() -> Nil)\n}\n\n@target(erlang)\npub fn call(cb: Box, value: fn() -> Nil) -> Nil {\n  let _ = value\n  cb.run()\n}\n\n@target(javascript)\npub fn call(cb: Box, value: fn() -> Nil) -> Nil {\n  let _ = value\n  cb.run()\n}\n",
    ),
  ])
  let result = graded.inferred_lines_with(root <> "/app", types.Active)
  support.cleanup(root)
  case result {
    Error(graded.GradedParseError(message:, ..)) ->
      string.split(message, "\n") |> list.first |> result.unwrap("")
    _ -> ""
  }
}

// A diagnostic quotes the statement it is about, by its own place in the spec:
// a valid line over the same path before it is not quoted in its place.
pub fn a_diagnostic_quotes_the_statement_it_is_about_test() {
  let spec =
    "// first declaration is valid\nassume dep.call : []\n\n// this bounded declaration is forbidden\nassume dep.call(cb: [e], value: []) : [e]\n"
  let quoted = "5: assume dep.call(cb: [e], value: []) : [e]"
  [
    quoted_error("[\"erlang\", \"javascript\"]", spec),
    quoted_error("[\"erlang\"]", spec),
  ]
  |> should.equal([quoted, quoted])
}

pub fn a_type_defined_differently_on_each_target_is_read_in_every_variant_test() {
  pair_answers(
    "type",
    [
      #(
        "src/probe.gleam",
        "import probe/ffi

@target(javascript)
pub type Box {
  Box(Int)
}

@target(erlang)
pub type Box {
  Box(fn() -> Nil)
}

@target(erlang)
pub fn main() -> Nil {
  ffi.sink(Box(ffi.shout))
}

@target(javascript)
pub fn main() -> Nil {
  ffi.sink(Box(0))
}
",
      ),
    ],
    "",
  )
  |> list.contains("effects probe.main : [Stdout]")
  |> should.be_true
}

pub fn a_constant_defined_once_per_target_is_typed_on_both_test() {
  pair_answers(
    "constant",
    [
      #(
        "src/probe.gleam",
        "import probe/ffi

@target(erlang)
const held = 0

@target(javascript)
const held = ffi.shout

pub fn main() -> Nil {
  ffi.sink(held)
}
",
      ),
    ],
    "",
  )
  |> should.equal(["effects probe.main : [Unknown]"])
}

pub fn an_alias_defined_once_per_target_is_typed_on_both_test() {
  pair_answers(
    "alias",
    [
      #(
        "src/probe.gleam",
        "import probe/ffi

@target(erlang)
type Held =
  Int

@target(javascript)
type Held =
  fn() -> Nil

@external(erlang, \"m\", \"held\")
@external(javascript, \"./m.mjs\", \"held\")
fn held() -> Held

pub fn main() -> Nil {
  ffi.sink(held())
}
",
      ),
    ],
    "assume probe.held : []\n",
  )
  |> should.equal(["effects probe.main : [Unknown]"])
}

pub fn a_dependency_function_defined_once_per_target_is_typed_on_both_test() {
  let directory =
    support.write_project_with_dependency(
      directory: "/tmp/graded_target_pairs_dependency",
      package: "probe",
      spec: pair_spec,
      sources: [
        #("src/probe/ffi.gleam", pair_ffi),
        #(
          "src/probe.gleam",
          "import dep\nimport probe/ffi\n\npub fn main() -> Nil {\n  ffi.sink(dep.value())\n}\n",
        ),
      ],
      dependency: "dep",
      dependency_spec: "assume dep.value : []\n",
      dependency_sources: [
        #(
          "dep.gleam",
          "@target(erlang)
pub fn value() -> Int {
  0
}

@target(javascript)
pub fn value() -> fn() -> Nil {
  printer()
}

@target(javascript)
@external(javascript, \"./dep_ffi.mjs\", \"printer\")
fn printer() -> fn() -> Nil
",
        ),
      ],
    )
  let assert Ok(lines) = graded.inferred_lines_with(directory, types.Active)
  support.cleanup(directory)
  lines
  |> list.filter(fn(line) { string.starts_with(line, "effects probe.main") })
  |> should.equal(["effects probe.main : [Unknown]"])
}

const local_pairs =
  "import probe/ffi

pub type Box {
  Box(f: fn() -> Nil)
}

@target(erlang)
fn get() -> Nil {
  Nil
}

@target(javascript)
fn get() -> Nil {
  ffi.shout()
}

@target(erlang)
fn pick(a: Box, b: Box) -> Box {
  let _ = b
  a
}

@target(javascript)
fn pick(a: Box, b: Box) -> Box {
  let _ = a
  b
}

fn quiet() -> Nil {
  Nil
}

pub fn called() -> Nil {
  get()
}

pub fn passed() -> Nil {
  ffi.sink(get)
}

pub fn returned() -> Nil {
  ffi.sink(pick(Box(quiet), Box(ffi.shout)))
}
"

pub fn a_function_defined_once_per_target_reads_as_both_test() {
  pair_answers("local", [#("src/probe.gleam", local_pairs)], "")
  |> list.sort(string.compare)
  |> should.equal([
    "effects probe.called : [Stdout]",
    "effects probe.passed : [Stdout]",
    "effects probe.returned : [Stdout]",
  ])
}

pub fn another_module_function_defined_once_per_target_reads_as_both_test() {
  pair_answers(
    "cross",
    [
      #(
        "src/probe/pairs.gleam",
        "import probe/ffi

pub type Box {
  Box(f: fn() -> Nil)
}

@target(erlang)
pub fn get() -> Nil {
  Nil
}

@target(javascript)
pub fn get() -> Nil {
  ffi.shout()
}

@target(erlang)
pub fn pick(a: Box, b: Box) -> Box {
  let _ = b
  a
}

@target(javascript)
pub fn pick(a: Box, b: Box) -> Box {
  let _ = a
  b
}
",
      ),
      #(
        "src/probe.gleam",
        "import probe/ffi
import probe/pairs

fn quiet() -> Nil {
  Nil
}

pub fn called() -> Nil {
  pairs.get()
}

pub fn returned() -> Nil {
  ffi.sink(pairs.pick(pairs.Box(quiet), pairs.Box(ffi.shout)))
}
",
      ),
    ],
    "",
  )
  |> list.sort(string.compare)
  |> should.equal([
    "effects probe.called : [Stdout]",
    "effects probe.returned : [Stdout]",
  ])
}

// A dependency's private alias defined once per target, named by the
// annotation of a function it exposes.
pub fn a_private_alias_a_dependency_signature_names_is_typed_on_both_test() {
  let directory =
    support.write_project_with_dependency(
      directory: "/tmp/graded_target_pairs_private_alias",
      package: "probe",
      spec: pair_spec,
      sources: [
        #("src/probe/ffi.gleam", pair_ffi),
        #(
          "src/probe.gleam",
          "import dep\nimport probe/ffi\n\npub fn main() -> Nil {\n  ffi.sink(dep.value())\n}\n",
        ),
      ],
      dependency: "dep",
      dependency_spec: "assume dep.value : []\n",
      dependency_sources: [
        #(
          "dep.gleam",
          "@target(erlang)
type Held =
  Int

@target(javascript)
type Held =
  fn() -> Nil

@external(erlang, \"dep_ffi\", \"value\")
@external(javascript, \"./dep_ffi.mjs\", \"value\")
pub fn value() -> Held
",
        ),
      ],
    )
  let assert Ok(lines) = graded.inferred_lines_with(directory, types.Active)
  support.cleanup(directory)
  lines
  |> list.filter(fn(line) { string.starts_with(line, "effects probe.main") })
  |> should.equal(["effects probe.main : [Unknown]"])
}

const variant_pairs =
  "import probe/ffi

fn quiet() -> Nil {
  Nil
}

@target(erlang)
fn swapped(first a: fn() -> Nil, second b: fn() -> Nil) -> Nil {
  a()
}

@target(javascript)
fn swapped(second a: fn() -> Nil, first b: fn() -> Nil) -> Nil {
  a()
}

@target(erlang)
fn renamed(a: fn() -> Nil) -> Nil {
  a()
}

@target(javascript)
fn renamed(b: fn() -> Nil) -> Nil {
  b()
}

@target(erlang)
fn discarded(_a: fn() -> Nil) -> Nil {
  Nil
}

@target(javascript)
fn discarded(b: fn() -> Nil) -> Nil {
  b()
}

@target(erlang)
fn counted(a: fn() -> Nil) -> Nil {
  a()
}

@target(javascript)
fn counted(a: fn() -> Nil, b: fn() -> Nil) -> Nil {
  let _ = a
  b()
}

@target(erlang)
fn count_call() -> Nil {
  counted(ffi.shout)
}

@target(javascript)
fn count_call() -> Nil {
  counted(ffi.shout, quiet)
}

@target(erlang)
@external(javascript, \"./m.mjs\", \"missing\")
fn crossed() -> Nil {
  Nil
}

@target(javascript)
@external(erlang, \"m\", \"missing\")
fn crossed() -> Nil {
  Nil
}

pub fn swap() -> Nil {
  swapped(first: ffi.shout, second: quiet)
}

pub fn rename() -> Nil {
  renamed(quiet)
}

pub fn discard() -> Nil {
  discarded(quiet)
}

pub fn count() -> Nil {
  count_call()
}

pub fn cross() -> Nil {
  crossed()
}
"

// Each variant of a same-module pair is read as itself: its own labels, names,
// arity, and `@external` attributes, the latter only where they share a target
// with the variant.
pub fn each_variant_of_a_pair_is_read_as_itself_test() {
  pair_answers("variants", [#("src/probe.gleam", variant_pairs)], "")
  |> list.sort(string.compare)
  |> should.equal([
    "effects probe.count : [Stdout]",
    "effects probe.cross : []",
    "effects probe.discard : []",
    "effects probe.rename : []",
    "effects probe.swap : [Stdout]",
  ])
}

// A package read on one target reads the variant built there.
pub fn a_package_read_on_one_target_reads_the_variant_it_builds_test() {
  let directory =
    support.write_fixture("/tmp/graded_target_pairs_one_target", [
      #(
        "gleam.toml",
        "name = \"probe\"\n\n[tools.graded]\ntargets = [\"javascript\"]\n",
      ),
      #("probe.graded", pair_spec),
      #("src/probe/ffi.gleam", pair_ffi),
      #(
        "src/probe/pairs.gleam",
        "@target(erlang)
pub fn swapped(first a: fn() -> Nil, second b: fn() -> Nil) -> Nil {
  b()
}

@target(javascript)
pub fn swapped(second a: fn() -> Nil, first b: fn() -> Nil) -> Nil {
  b()
}
",
      ),
      #(
        "src/probe.gleam",
        "import probe/ffi
import probe/pairs

fn quiet() -> Nil {
  Nil
}

@target(erlang)
fn renamed(first a: fn() -> Nil, second b: fn() -> Nil) -> Nil {
  a()
}

@target(javascript)
fn renamed(first x: fn() -> Nil, second y: fn() -> Nil) -> Nil {
  y()
}

pub fn local() -> Nil {
  renamed(first: quiet, second: ffi.shout)
}

pub fn other() -> Nil {
  pairs.swapped(first: ffi.shout, second: quiet)
}
",
      ),
    ])
  let assert Ok(lines) = graded.inferred_lines_with(directory, types.Active)
  support.cleanup(directory)
  lines
  |> list.filter(fn(line) { !string.starts_with(line, "effects probe/") })
  |> list.sort(string.compare)
  |> should.equal([
    "effects probe.local : [Stdout]",
    "effects probe.other : [Stdout]",
  ])
}

// A pair of externals answers what the written name declares, for `check`,
// `why` and `effect` alike: a function-level line over an empty module
// default, and an empty function-level line.
fn external_pair_readings(name: String, spec: String) {
  let directory =
    support.write_fixture("/tmp/graded_target_pairs_" <> name, [
      #("gleam.toml", support.dual_target_toml("probe")),
      #("probe.graded", spec),
      #(
        "src/probe.gleam",
        "@target(erlang)
@external(erlang, \"m\", \"quiet\")
pub fn get() -> Nil

@target(javascript)
@external(javascript, \"./m.mjs\", \"quiet\")
pub fn get() -> Nil

pub fn main() -> Nil {
  get()
}
",
      ),
    ])
  let assert Ok(reports) = graded.run(directory)
  let assert Ok(effect) = graded.run_effect(directory, "probe.get")
  let assert Ok(why) = graded.run_why(directory, "probe.get")
  support.cleanup(directory)
  #(list.flat_map(reports, fn(report) { report.violations }), effect, why)
}

pub fn an_external_pair_is_checked_against_its_written_declaration_test() {
  let #(violations, effect, why) =
    external_pair_readings(
      "external_priority",
      "assume probe : []\nassume probe.get : [Stdout]\ncheck probe.get : []\n",
    )
  { violations != [] } |> should.be_true
  list.all(violations, fn(line) { string.contains(line, "Stdout") })
  |> should.be_true
  string.contains(effect, "[Stdout]") |> should.be_true
  string.contains(why, "[Stdout]") |> should.be_true
}

pub fn a_pure_external_pair_passes_its_check_test() {
  let #(violations, effect, why) =
    external_pair_readings(
      "external_pure",
      "assume probe.get : []\ncheck probe.get : []\ncheck probe.main : []\n",
    )
  violations |> should.equal([])
  string.contains(effect, "[]") |> should.be_true
  string.contains(why, "Unknown") |> should.be_false
}

const target_graph_pairs =
  "import probe/ffi

fn quiet() -> Nil {
  Nil
}

@target(erlang)
fn f(n: Int) -> Nil {
  g(n)
}

@target(javascript)
fn f(_n: Int) -> Nil {
  Nil
}

@target(erlang)
fn g(_n: Int) -> Nil {
  Nil
}

@target(javascript)
fn g(n: Int) -> Nil {
  ffi.shout()
  f(n)
}

@target(javascript)
fn h(n: Int) -> Nil {
  k(n)
}

@target(erlang)
fn h(_n: Int) -> Nil {
  Nil
}

@target(javascript)
fn k(_n: Int) -> Nil {
  Nil
}

@target(erlang)
fn k(n: Int) -> Nil {
  ffi.shout()
  h(n)
}

@target(erlang)
fn two(a: fn() -> Nil) -> Nil {
  a()
}

@target(javascript)
fn two(a: fn() -> Nil, b: fn() -> Nil) -> Nil {
  let _ = a
  b()
}

@target(erlang)
fn make() -> fn() -> Nil {
  fn() { two(quiet) }
}

@target(javascript)
fn make() -> fn() -> Nil {
  fn() { Nil }
}

@target(erlang)
fn run(a: fn() -> Nil) -> Nil {
  a()
}

@target(javascript)
fn run(b) {
  b()
}

@target(erlang)
fn run_both(a) {
  a()
}

@target(javascript)
fn run_both(b) {
  b()
}

pub fn cycle() -> Nil {
  f(0)
}

pub fn cycle_reversed() -> Nil {
  h(0)
}

pub fn returned() -> Nil {
  let made = make()
  made()
}

pub fn inferred() -> Nil {
  run(quiet)
}

pub fn inferred_both() -> Nil {
  run_both(quiet)
}
"

// A call graph whose cycle exists only across targets, an operator returned
// by a pair calling another pair, and callbacks girard infers under different
// names on each target, each read on the targets that build it.
pub fn each_target_reads_its_own_graph_operator_and_callbacks_test() {
  pair_answers("graphs", [#("src/probe.gleam", target_graph_pairs)], "")
  |> list.sort(string.compare)
  |> should.equal([
    "effects probe.cycle : []",
    "effects probe.cycle_reversed : []",
    "effects probe.inferred : []",
    "effects probe.inferred_both : []",
    "effects probe.returned : []",
  ])
}

// A field closure is read with the run's types, as a body is.
pub fn a_field_closure_reads_with_the_run_types_test() {
  pair_answers(
    "closure",
    [
      #(
        "src/probe.gleam",
        "import probe/ffi

pub type Box {
  Box(Int)
}

pub type Runner {
  Runner(run: fn() -> Nil)
}

pub fn make() -> Box {
  Box(1)
}

pub fn main() -> Nil {
  let r = Runner(run: fn() { ffi.sink(make()) })
  r.run()
}
",
      ),
    ],
    "",
  )
  |> list.sort(string.compare)
  |> should.equal(["effects probe.main : []", "effects probe.make : []"])
}

// An app read on both targets whose `main` is built on Erlang alone and calls a
// path dependency, declared by its absolute path, at `dependency` under the
// fixture root, whose private helper is quiet on Erlang and prints on
// JavaScript: what `infer`, `check`, `why` and `effect` say of `app.main`.
fn one_target_main(dependency: String) -> #(List(String), Int, String, String) {
  let root =
    "/tmp/graded_one_target_main_" <> string.replace(dependency, "/", "_")
  let directory =
    support.write_fixture(root, [
      #(
        "app/gleam.toml",
        "name = \"app\"\nversion = \"1.0.0\"\n\n[dependencies]\ndep = { path = \""
          <> root
          <> "/"
          <> dependency
          <> "\" }\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
      ),
      #(
        "app/app.graded",
        "assume dep/ffi.shout : [Stdout]\ncheck app.main : []\n",
      ),
      #(
        "app/src/app.gleam",
        "import dep\n\n@target(erlang)\npub fn main() -> Nil {\n  dep.run()\n}\n",
      ),
      #(
        dependency <> "/gleam.toml",
        "name = \"dep\"\nversion = \"1.0.0\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
      ),
      #(
        dependency <> "/src/dep.gleam",
        "import dep/ffi\n\n@target(javascript)\nfn helper() -> Nil {\n  ffi.shout()\n}\n\n@target(erlang)\nfn helper() -> Nil {\n  Nil\n}\n\npub fn run() -> Nil {\n  helper()\n}\n",
      ),
      #(
        dependency <> "/src/dep/ffi.gleam",
        "@external(erlang, \"dep_ffi\", \"shout\")\n@external(javascript, \"./dep_ffi.mjs\", \"shout\")\npub fn shout() -> Nil\n",
      ),
    ])
  let app = directory <> "/app"
  let inferred =
    graded.inferred_lines_with(app, types.Active)
    |> result.unwrap([])
    |> list.filter(string.starts_with(_, "effects app."))
  let violations =
    graded.run(app)
    |> result.map(list.flat_map(_, fn(report) { report.violations }))
    |> result.unwrap(["no report"])
    |> list.length
  let why = graded.run_why(app, "app.main") |> result.unwrap("no answer")
  let effect = graded.run_effect(app, "app.main") |> result.unwrap("no answer")
  support.cleanup(directory)
  #(inferred, violations, why, effect)
}

// A path dependency is one of the tree's local packages wherever its directory
// lies: in a directory named `src`, or under one.
pub fn a_path_dependency_is_local_wherever_its_directory_lies_test() {
  ["src", "lib", "outer/src/lib"]
  |> list.map(fn(dependency) { one_target_main(dependency).0 })
  |> should.equal([
    ["effects app.main : []"],
    ["effects app.main : []"],
    ["effects app.main : []"],
  ])
}

// `check`, `why` and `effect` read a function on the targets that build it, as
// `infer` publishes it: JavaScript builds no `app.main`, so what the Erlang
// definition reads there is not one of its answers.
pub fn every_command_reads_a_function_on_the_targets_that_build_it_test() {
  let #(inferred, violations, why, effect) = one_target_main("lib")
  #(
    inferred,
    violations,
    string.contains(why, "Stdout"),
    string.contains(why, "javascript"),
    string.contains(effect, "[]"),
  )
  |> should.equal(#(["effects app.main : []"], 0, False, False, True))
}

// A function defined once per target, with a different effect on each, has
// one joined line in the spec and the same line in its module's cache file.
pub fn a_cache_line_is_joined_as_its_spec_line_is_test() {
  let directory =
    support.write_fixture("/tmp/graded_joined_cache_line", [
      #("gleam.toml", support.dual_target_toml("probe")),
      #("probe.graded", "assume probe.a : [A]\nassume probe.b : [B]\n"),
      #(
        "src/probe.gleam",
        "@external(erlang, \"probe_ffi\", \"a\")\n@external(javascript, \"./probe_ffi.mjs\", \"a\")\npub fn a() -> Nil\n\n@external(erlang, \"probe_ffi\", \"b\")\n@external(javascript, \"./probe_ffi.mjs\", \"b\")\npub fn b() -> Nil\n\n@target(erlang)\npub fn split() -> Nil {\n  a()\n}\n\n@target(javascript)\npub fn split() -> Nil {\n  b()\n}\n",
      ),
    ])
  let assert Ok(Nil) = graded.run_infer(directory)
  let line = fn(path, prefix) {
    simplifile.read(directory <> path)
    |> result.unwrap("")
    |> string.split("\n")
    |> list.find(string.starts_with(_, prefix))
    |> result.unwrap("no line")
  }
  let found = #(
    line("/probe.graded", "effects probe.split"),
    line("/build/.graded/probe.graded", "effects split"),
  )
  support.cleanup(directory)
  found
  |> should.equal(#("effects probe.split : [A, B]", "effects split : [A, B]"))
}
