import filepath
import gleam/list
import gleam/result
import gleam/string
import gleeunit/should
import graded
import graded/internal/annotation
import graded/internal/cli
import graded/internal/config
import simplifile
import support.{cleanup, write_fixture}

// The `effect` query command
//
// End-to-end lookups against test/fixtures: both name forms, the provenance
// comments, the not-found cases, and the defining requirement that nothing is
// written.

const fixtures = "test/fixtures"

// Every `Ok` output is `.graded` syntax, comment lines included, so it can be
// fed straight back to the parser. Asserting that here keeps the metadata
// lines from drifting into a shape the spec parser rejects.
fn should_parse(output: String) -> String {
  annotation.parse_file(output <> "\n") |> should.be_ok
  output
}

fn lookup(name: String) -> String {
  let assert Ok(output) = graded.run_effect(fixtures, name)
  should_parse(output)
}

pub fn known_function_test() {
  lookup("impure_view.view")
  |> should.equal("effects impure_view.view : [Stdout]")
}

pub fn function_known_as_unknown_is_found_test() {
  // `[Unknown]` is a resolved answer, not a miss: the query must report it
  // rather than claim the function doesn't exist.
  lookup("shadow_field.go")
  |> should.equal("effects shadow_field.go : [Unknown]")
}

pub fn declared_type_field_test() {
  lookup("opaque_receiver.Validator.to_error")
  |> should.equal(
    "type opaque_receiver.Validator.to_error : [Stdout]\n// declared by a type line",
  )
}

pub fn unspecced_function_resolves_from_memory_test() {
  // `external_same_module.read_clock` has no `effects` line in the spec, so it
  // can only resolve through the in-memory inference pass — no prior
  // `graded infer` needed.
  lookup("external_same_module.read_clock")
  |> should.equal("effects external_same_module.read_clock : [Time]")
}

pub fn function_level_external_test() {
  lookup("external_same_module.now")
  |> should.equal("effects external_same_module.now : [Time]")
}

pub fn module_level_external_fallback_is_labelled_test() {
  // `external effects fake_clock : [Time]` declares a whole module, so any
  // function name under it resolves through the module-level fallback.
  lookup("fake_clock.now")
  |> should.equal(
    "effects fake_clock.now : [Time]\n// resolved via module-level external for fake_clock",
  )
}

pub fn unknown_name_is_not_found_test() {
  graded.run_effect(fixtures, "no_such.thing")
  |> should.equal(Error(graded.EffectNotFound("no_such.thing")))
}

pub fn bare_name_is_not_found_test() {
  graded.run_effect(fixtures, "view")
  |> should.equal(Error(graded.EffectNotFound("view")))
}

pub fn private_function_is_not_found_test() {
  // `nested_higher_order.middle` is private: the inference pass records public
  // functions only, and the query serves what the knowledge base holds.
  graded.run_effect(fixtures, "nested_higher_order.middle")
  |> should.equal(Error(graded.EffectNotFound("nested_higher_order.middle")))
}

// Higher-order bounds
//
// A polymorphic effect term is useless without the bounds that bind its
// variables, so both are rendered — and both must come from the same
// annotation source.

pub fn freshly_inferred_bounds_are_rendered_test() {
  lookup("nested_higher_order.apply_twice")
  |> should.equal("effects nested_higher_order.apply_twice(f: [f]) : [f]")
}

pub fn committed_bounds_win_as_a_pair_test() {
  // The spec commits `pure_forward(g: [g]) : [g]` while the source parameter is
  // named `f`. The committed bounds travel with the committed term, so the
  // query renders `g` on both sides rather than a mixed pair.
  lookup("nested_higher_order.pure_forward")
  |> should.equal("effects nested_higher_order.pure_forward(g: [g]) : [g]")
}

pub fn check_line_bounds_stay_out_of_the_knowledge_base_test() {
  // `check factory_forward.caller(resolver: [Stdout])` is a budget for that
  // check, not a fact about the function: the query renders the inferred
  // bound instead.
  let output = lookup("factory_forward.caller")
  output
  |> should.equal(
    "effects factory_forward.caller(resolver: [resolver]) : [resolver]",
  )
  string.contains(output, "[Stdout]") |> should.be_false
}

pub fn external_suppresses_stale_committed_bounds_test() {
  // The spec holds both `external effects external_same_module.now : [Time]`
  // and a stale `effects external_same_module.now(cb: [cb]) : [cb]`. The
  // external is authoritative, so neither the stale term nor its bounds show.
  let output = lookup("external_same_module.now")
  string.contains(output, "cb") |> should.be_false
}

pub fn bound_less_committed_line_suppresses_inferred_bounds_test() {
  // `log_and_map` is higher-order in source, so inference derives `(f: [f])`.
  // Its committed line carries no bounds, so it decides both halves: gap-filling
  // the inferred ones would pair a first-order committed term with a variable
  // nothing in that term mentions.
  let output = lookup("nested_higher_order.log_and_map")
  output
  |> should.equal("effects nested_higher_order.log_and_map : [Stdout]")
  string.contains(output, "f:") |> should.be_false
}

// Name grammar
//
// A spec function name has exactly one dot — module paths use slashes. Reading
// one any looser lets a malformed line claim a name that belongs to another
// annotation kind. Both cases below are malformed or dead spec states, so they
// get their own throwaway project rather than a line in the shared fixture.

// A project holding just a spec file. No `gleam.toml`, so the spec path comes
// from the directory's own name, exactly as `test/fixtures` resolves its own.
fn spec_only_project(name: String, spec: String) -> String {
  let package = "graded_effect_" <> name
  write_fixture("/tmp/" <> package, [
    #(package <> ".graded", spec),
    #("box.gleam", "pub type Box {\n  Box(run: fn() -> Nil)\n}\n"),
  ])
}

pub fn dotted_module_effects_line_does_not_shadow_a_type_line_test() {
  // A malformed 3-segment `effects` line beside the real `type` line for the
  // same field. Split on the last dot it would key itself under the module
  // `box.Box` and answer first; the function grammar rejects it instead, so the
  // `type` line still answers.
  let project =
    spec_only_project(
      "shadow",
      "type box.Box.run : [Stdout]\neffects box.Box.run : [Disk]\n",
    )
  let assert Ok(output) = graded.run_effect(project, "box.Box.run")
  should_parse(output)
  |> should.equal("type box.Box.run : [Stdout]\n// declared by a type line")
  cleanup(project)
}

pub fn bare_type_line_answers_both_query_forms_test() {
  // A bare `type Box.run` line is keyed under no module. Both the bare query
  // and a module-qualified one find it, and the answer is rendered in the bare
  // form that declared it — the form that parses back to the same line.
  let project = spec_only_project("bare", "type Box.run : [Disk]\n")
  let bare = "type Box.run : [Disk]\n// declared by a type line"
  let assert Ok(qualified_query) = graded.run_effect(project, "box.Box.run")
  let assert Ok(bare_query) = graded.run_effect(project, "Box.run")
  should_parse(qualified_query) |> should.equal(bare)
  should_parse(bare_query) |> should.equal(bare)
  cleanup(project)
}

// Argument decoding
//
// `main`'s branches print and exit, so the rules for `graded effect`'s
// arguments are pinned on the pure decoder behind them.

pub fn parse_effect_args_requires_a_name_test() {
  cli.parse_effect_args([])
  |> should.equal(Error(cli.MissingName))
  cli.format_argument_error(cli.MissingName)
  |> should.equal("missing name for `effect`")
}

pub fn parse_effect_args_defaults_the_directory_test() {
  cli.parse_effect_args(["a.b"])
  |> should.equal(Ok(#("a.b", "src")))
}

pub fn parse_effect_args_takes_a_directory_test() {
  cli.parse_effect_args(["a.b", "dir"])
  |> should.equal(Ok(#("a.b", "dir")))
}

pub fn parse_effect_args_rejects_a_flag_name_test() {
  cli.parse_effect_args(["-x"])
  |> should.equal(Error(cli.UnknownOption("-x")))
  cli.format_argument_error(cli.UnknownOption("-x"))
  |> should.equal("unknown option `-x`")
}

pub fn parse_effect_args_rejects_a_flag_directory_test() {
  cli.parse_effect_args(["a.b", "-x"])
  |> should.equal(Error(cli.UnknownOption("-x")))
}

pub fn parse_effect_args_rejects_a_third_argument_test() {
  cli.parse_effect_args(["a.b", "dir", "extra"])
  |> should.equal(Error(cli.UnexpectedArgument("extra")))
  cli.format_argument_error(cli.UnexpectedArgument("extra"))
  |> should.equal("unexpected argument `extra`")
}

// The directory rule `effect` composes with, shared with check/infer/format/pack.

pub fn parse_directory_args_defaults_to_src_test() {
  cli.parse_directory_args([]) |> should.equal(Ok("src"))
}

pub fn parse_directory_args_takes_one_directory_test() {
  cli.parse_directory_args(["dir"]) |> should.equal(Ok("dir"))
}

pub fn parse_directory_args_rejects_a_flag_test() {
  cli.parse_directory_args(["--dry-run"])
  |> should.equal(Error(cli.UnknownOption("--dry-run")))
}

pub fn parse_directory_args_rejects_a_second_directory_test() {
  cli.parse_directory_args(["dir", "--dry-run"])
  |> should.equal(Error(cli.UnexpectedArgument("--dry-run")))
}

// Read-only
//
// The command exists to answer without touching the project. Every other test
// checks a return value, which a query that rewrote the spec would still pass.

pub fn effect_query_writes_nothing_test() {
  let spec_path = filepath.join(fixtures, config.default_spec_file("fixtures"))
  let cache_path = filepath.join(fixtures, config.default_cache_dir())
  let before = #(simplifile.read(spec_path), directory_snapshot(cache_path))

  // An unspecced name, so the in-memory inference pass runs — the code path
  // that shares the most with `graded infer`.
  let assert Ok(_) =
    graded.run_effect(fixtures, "external_same_module.read_clock")

  #(simplifile.read(spec_path), directory_snapshot(cache_path))
  |> should.equal(before)
}

// Every file under `path` paired with its content, sorted. `Error` when the
// directory is absent — which compares equal across a call that creates it.
fn directory_snapshot(path: String) -> Result(List(#(String, String)), Nil) {
  use entries <- result.try(
    simplifile.get_files(path) |> result.replace_error(Nil),
  )
  entries
  |> list.sort(string.compare)
  |> list.map(fn(file) { #(file, simplifile.read(file) |> result.unwrap("")) })
  |> Ok
}
