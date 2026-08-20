import gleam/list
import gleam/string
import gleeunit/should
import graded
import graded/internal/annotation
import graded/internal/answer
import graded/internal/checker
import graded/internal/cli
import simplifile
import support

// The `why` explanation command
//
// End-to-end explanations against test/fixtures: what a block says, one block
// per `check` line, the shapes that make the contributor list differ from the
// call sites written in the body, and the not-found cases.

const fixtures = "test/fixtures"

fn why(name: String) -> String {
  let assert Ok(output) = graded.run_why(fixtures, name)
  output
}

fn lines(output: String) -> List(String) {
  string.split(output, "\n")
}

pub fn explains_a_checked_function_test() {
  why("impure_view.view")
  |> lines
  |> should.equal([
    "impure_view.view has effects [Stdout]",
    "declared check impure_view.view : []",
    "  calls gleam/io.println with effects [Stdout] (from gleam_stdlib's catalog entry)",
    "  calls gleam/list.map with effects [] (from a module-level `assume` in gleam_stdlib's catalog entry)",
  ])
}

pub fn explains_a_function_without_a_check_line_test() {
  // Nothing to declare, so the block is the header and its contributors. The
  // target calls one helper twice: both calls collect that helper's single site
  // identically, and the one line here is the collapse of the pair.
  let output = why("why_target.calls_helper_twice")
  string.contains(output, "declared") |> should.be_false()
  output
  |> lines
  |> should.equal([
    "why_target.calls_helper_twice has effects [Stdout]",
    "  calls gleam/io.println with effects [Stdout] (from gleam_stdlib's catalog entry)",
  ])
}

pub fn explains_a_second_order_function_test() {
  // `action(cb)` resolves only symbolically. The header states the term the
  // spec's inferred line holds — the same sentence `graded effect` answers
  // with — while the contributor line grounds the still-symbolic application
  // to the conservative `[Unknown]` every printed effect set is.
  why("why_target.applies_operator")
  |> lines
  |> should.equal([
    "why_target.applies_operator has effects [action([cb])]",
    "  calls parameter `action` with unresolved effects [Unknown]",
  ])
}

pub fn explains_a_private_function_test() {
  // `transitive.helper` is private: `graded effect` declines it, since it
  // answers from the public surface, but `why` walks a body this project holds.
  why("transitive.helper")
  |> lines
  |> should.equal([
    "transitive.helper has effects [Stdout]",
    "  calls gleam/io.println with effects [Stdout] (from gleam_stdlib's catalog entry)",
  ])
  graded.run_effect(fixtures, "transitive.helper") |> should.be_error()
}

pub fn explains_an_unresolved_call_test() {
  // The reason the call stayed `[Unknown]` is the whole point of the line.
  why("opaque_field.exec_unbound")
  |> string.contains(
    "calls field `run` on `r` of type `opaque_field.Runner`, which has no effect annotation for that field, with unresolved effects [Unknown]",
  )
  |> should.be_true()
}

pub fn explains_a_field_variable_total_as_forwarding_test() {
  // The total is the synthetic `r.run` field variable, and the block's bounds
  // carry its identity binder — so the header reads it as forwarding that
  // field's effects, the sentence `graded effect` answers with, rather than
  // as `has effects [r.run]`, an effect named after the path.
  why("opaque_field.exec_unbound")
  |> lines
  |> list.first
  |> should.equal(Ok(
    "opaque_field.exec_unbound has the effects of its `r.run` argument, and none of its own",
  ))
}

pub fn explains_one_block_per_check_line_test() {
  // `two_bounds` has two `check` lines that share a budget and bind a different
  // parameter each, so only the declarations tell the blocks apart — and each
  // block's contributors are the ones its own bounds resolved. The parameter a
  // line does not bind keeps the identity bound inference gives it, so each
  // block names both parameters and differs in what it knows about them.
  let assert [first, second] =
    string.split(why("why_target.two_bounds"), "\n\n")
  first
  |> lines
  |> should.equal([
    "why_target.two_bounds has the effects of its `g` argument, plus [Stdout] of its own",
    "declared check why_target.two_bounds(f: [Stdout]) : [Stdout]",
    "  calls parameter `f` with effects [Stdout]",
    "  calls parameter `g` with effects [g]",
  ])
  second
  |> lines
  |> should.equal([
    "why_target.two_bounds has the effects of its `f` argument, plus [Stdout] of its own",
    "declared check why_target.two_bounds(g: [Stdout]) : [Stdout]",
    "  calls parameter `f` with effects [f]",
    "  calls parameter `g` with effects [Stdout]",
  ])
}

pub fn a_declared_bound_variable_survives_in_the_header_test() {
  // The block's total is groomed against the names the block's own bounds can
  // bind, which includes the ones the `check` line declared — not the
  // synthesised ones alone. Grooming against those left a `[Unknown]` header
  // over a contributor stating `[action]`: the per-call projection less
  // conservative than the total it is part of.
  why("why_target.bound_forwards")
  |> lines
  |> should.equal([
    "why_target.bound_forwards has the effects of its `action` argument, and none of its own",
    "declared check why_target.bound_forwards(action: [action]) : [action]",
    "  calls parameter `action` with effects [action]",
  ])
}

pub fn a_higher_order_function_explains_as_the_query_answers_it_test() {
  // `why` and `effect` answer about one function, so they cannot disagree about
  // its total. `two_bounds` calls both its function-typed parameters and has no
  // `check` line binding either here, so the walk states its effects over the
  // identity bounds inference gives them — where it used to report a parameter
  // in plain sight as a name the module does not define, and collapse the total
  // to `[Unknown]`. The header reads those bounds too, so a total that is
  // exactly the callback's variable is worded as the forwarding it is.
  let assert Ok(explained) = graded.run_why(fixtures, "why_target.forwards")
  explained
  |> lines
  |> should.equal([
    "why_target.forwards has the effects of its `action` argument, and none of its own",
    "  calls parameter `action` with effects [action]",
  ])
  let assert Ok(answered) =
    graded.run_effect_formatted(fixtures, "why_target.forwards", answer.Graded)
  answered
  |> string.contains("effects why_target.forwards(action: [action]) : [action]")
  |> should.be_true()
}

pub fn differing_substitutions_at_one_site_both_survive_test() {
  // One helper site, two callbacks: the site contributes different effects per
  // call, and collapsing those would hide the effectful one.
  why("why_target.passes_two_callbacks")
  |> lines
  |> list.filter(string.contains(_, "calls parameter `action`"))
  |> should.equal([
    "  calls parameter `action` with effects [Stdout]",
    "  calls parameter `action` with effects []",
  ])
}

pub fn an_opaque_external_is_not_explained_as_pure_test() {
  // `@external` is opaque foreign code, so the answer is the conservative
  // `[Unknown]` — including for the one carrying a pure-looking Gleam fallback,
  // whose body says nothing about what the native implementation does.
  why("ffi_external.ffi_op")
  |> lines
  |> should.equal([
    "ffi_external.ffi_op has effects that could not be determined: [Unknown]",
    "  is an external with no declared effects, with unresolved effects [Unknown]",
  ])
  why("ffi_external.ffi_with_body")
  |> string.contains("has effects that could not be determined: [Unknown]")
  |> should.be_true()
}

pub fn an_external_declaration_explains_the_external_test() {
  // The declaration is the whole explanation: an `external effects` line is what
  // the analysis knows about foreign code, and it answers here as it answers a
  // caller — including when what it declares is purity.
  why("external_same_module.now")
  |> lines
  |> should.equal([
    "external_same_module.now has effects [Time]",
    "  is an external with effects [Time] (from your spec's `assume` line)",
  ])
  why("local_wired.opaque_read")
  |> string.contains("is pure — no effects ([])")
  |> should.be_true()
}

pub fn an_external_agrees_with_the_violation_for_it_test() {
  // One vocabulary, as for an ordinary call: the clause `check` prints when an
  // external blows the budget on its own `check` line is the line `why` prints
  // for that external, phrase for phrase.
  let assert Ok(results) = graded.run(fixtures)
  let assert Ok(result) =
    list.find(results, fn(r) { r.file == fixtures <> "/external_budget.gleam" })
  let assert Ok(violation) =
    list.find(result.violations, fn(v) { v.function == "declared_over_budget" })
  let rendered = checker.format_violation(result.file, violation)
  let assert [_header, _declaration, line] =
    why("external_budget.declared_over_budget") |> lines
  string.contains(rendered, string.trim(line)) |> should.be_true()
}

pub fn a_committed_effects_line_does_not_explain_an_external_test() {
  // The spec carries `effects external_budget.stale_inferred : []`, left behind
  // by a function that became an `@external`. It is inference over a body, not
  // a statement about foreign code, so it neither answers nor gets credited —
  // reporting its `[]` would claim the spec declared a purity it never did.
  why("external_budget.stale_inferred")
  |> lines
  |> should.equal([
    "external_budget.stale_inferred has effects that could not be determined: [Unknown]",
    "declared check external_budget.stale_inferred : []",
    "  is an external with no declared effects, with unresolved effects [Unknown]",
  ])
}

pub fn a_declared_unknown_external_names_its_declaration_test() {
  // `external effects … : [Unknown]` is a declaration that the effect isn't
  // known — still a declaration, so the line names it rather than reporting the
  // external as undeclared. Told from the entry that won, not from its value:
  // an undeclared external carries the same `[Unknown]` and reads differently.
  why("external_budget.declared_unknown")
  |> lines
  |> should.equal([
    "external_budget.declared_unknown has effects that could not be determined: [Unknown]",
    "  is an external with unresolved effects [Unknown] (from your spec's `assume` line)",
  ])
  why("ffi_external.ffi_op")
  |> string.contains("with no declared effects")
  |> should.be_true()
}

pub fn an_external_reads_differently_from_a_call_into_it_test() {
  // The external's own line states what it *is*; its caller's line states a call
  // into it. Same effects and same source, different sentence — the caller does
  // make a call, and the declaration is not one.
  why("ffi_external.ffi_op")
  |> string.contains("is an external")
  |> should.be_true()
  why("ffi_external.run")
  |> string.contains("calls ffi_external.ffi_op")
  |> should.be_true()
}

pub fn a_module_external_explains_an_ordinary_function_test() {
  // An `external effects <module>` line over a project module declares what
  // every function under it does, and answers for every caller of them. So it
  // answers here twice: for `helper` itself, and for the sibling `helper` calls
  // — a same-module call pays the declared `[Disk]` exactly as a call from any
  // other module does, and reading the sibling's body instead charged one name
  // two sets depending on where it was called from.
  //
  // Named as what it is. `helper` is ordinary Gleam, and calling it an external
  // contradicted the rule that rejects a per-function `external effects` line
  // over a function whose body is right there: the line governs callers, and the
  // wording says so.
  let root = "build/why_module_external"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("proj.graded", "external effects probe : [Disk]\n"),
    #(
      "probe.gleam",
      "pub fn helper() -> Nil {\n  quiet()\n}\n\nfn quiet() -> Nil {\n  Nil\n}\n",
    ),
  ])
  let assert Ok(output) = graded.run_why(root, "probe.helper")
  output
  |> lines
  |> should.equal([
    "probe.helper has effects [Disk]",
    "  is declared for its callers with effects [Disk] (from a module-level `assume` in your spec)",
    "  calls probe.quiet with effects [Disk] (from a module-level `assume` in your spec)",
  ])
  output |> string.contains("is an external") |> should.be_false()
  // The one answer, in each command's own words.
  let assert Ok(effect) =
    graded.run_effect_formatted(root, "probe.helper", answer.Prose)
  effect
  |> string.contains("probe.helper has effects [Disk]")
  |> should.be_true()
  support.cleanup(root)
}

pub fn a_module_external_violation_uses_the_same_wording_test() {
  // One vocabulary, as for every other contributor: the clause `check` prints
  // when the declaration blows the function's own budget is the line `why`
  // prints for it, phrase for phrase.
  let root = "build/why_module_external_violation"
  support.write_fixture(root, [
    #("gleam.toml", "name = \"proj\"\n"),
    #(
      "proj.graded",
      "external effects probe : [Disk]\ncheck probe.helper : []\n",
    ),
    #("probe.gleam", "pub fn helper() -> Nil {\n  Nil\n}\n"),
  ])
  let assert Ok(results) = graded.run(root)
  let assert Ok(result) =
    list.find(results, fn(r) { r.file == root <> "/probe.gleam" })
  let assert [violation] = result.violations
  let rendered = checker.format_violation(result.file, violation)
  rendered
  |> should.equal(
    root
    <> "/probe.gleam: helper is declared for its callers with effects [Disk]"
    <> " (from a module-level `assume` in your spec) but declared []",
  )
  let assert Ok(output) = graded.run_why(root, "probe.helper")
  let assert [_header, _declaration, line] = lines(output)
  string.contains(rendered, string.trim(line)) |> should.be_true()
  support.cleanup(root)
}

pub fn a_function_with_no_contributors_says_so_test() {
  // The helper is pure, so its caller collects nothing — though it does call
  // something, which is why the line doesn't claim otherwise.
  why("why_target.calls_pure_helper")
  |> lines
  |> should.equal([
    "why_target.calls_pure_helper is pure — no effects ([])",
    "  has no reachable effect contributors",
  ])
}

pub fn agrees_with_the_violation_for_the_same_call_test() {
  // One vocabulary: the clause `check` prints for a violating call is the line
  // `why` prints for it, phrase for phrase.
  let assert Ok(results) = graded.run(fixtures)
  let assert Ok(result) =
    list.find(results, fn(r) { r.file == fixtures <> "/impure_view.gleam" })
  let assert [violation] = result.violations
  let rendered = checker.format_violation(result.file, violation)
  let assert Ok(line) =
    why("impure_view.view")
    |> lines
    |> list.find(string.contains(_, "io.println"))
  string.contains(rendered, string.trim(line)) |> should.be_true()
}

pub fn unqualified_name_is_not_found_test() {
  graded.run_why(fixtures, "view")
  |> should.equal(Error(graded.FunctionNotFound("view")))
}

pub fn unknown_module_is_not_found_test() {
  graded.run_why(fixtures, "no_such_module.view")
  |> should.equal(Error(graded.FunctionNotFound("no_such_module.view")))
}

pub fn unknown_function_is_not_found_test() {
  graded.run_why(fixtures, "impure_view.absent")
  |> should.equal(Error(graded.FunctionNotFound("impure_view.absent")))
}

pub fn a_dependency_function_is_not_found_test() {
  // `why` re-walks a body, so it explains this project's functions only — a
  // dependency's effects are what `graded effect` answers.
  graded.run_why(fixtures, "gleam/io.println")
  |> should.equal(Error(graded.FunctionNotFound("gleam/io.println")))
  graded.run_effect(fixtures, "gleam/io.println") |> should.be_ok()
}

pub fn writes_nothing_test() {
  let spec = fixtures <> "/fixtures.graded"
  let assert Ok(before) = simplifile.read(spec)
  let _ = why("impure_view.view")
  simplifile.read(spec) |> should.equal(Ok(before))
}

// Argument decoding
//
// `main`'s branch prints and exits, so the rules for `graded why`'s arguments
// are pinned on the pure decoder behind it.

pub fn parse_why_args_requires_a_name_test() {
  cli.parse_why_args([])
  |> should.equal(Error(cli.MissingName("why")))
  cli.format_argument_error(cli.MissingName("why"))
  |> should.equal("missing name for `why`")
}

pub fn parse_why_args_defaults_the_directory_test() {
  cli.parse_why_args(["a.b"])
  |> should.equal(Ok(#("a.b", "src")))
}

pub fn parse_why_args_takes_a_directory_test() {
  cli.parse_why_args(["a.b", "dir"])
  |> should.equal(Ok(#("a.b", "dir")))
}

pub fn parse_why_args_rejects_a_flag_as_a_name_test() {
  cli.parse_why_args(["--format=graded"])
  |> should.equal(Error(cli.UnknownOption("--format=graded")))
}

pub fn parse_why_args_rejects_an_extra_argument_test() {
  cli.parse_why_args(["a.b", "dir", "extra"])
  |> should.equal(Error(cli.UnexpectedArgument("extra")))
}

// Unparseable spec
//
// The explanation reads the spec's `check` lines, so a line the parser rejects
// stops it rather than explaining against a spec that was silently emptied.

pub fn why_over_an_unparseable_spec_errors_test() {
  let root = "/tmp/graded_why_unparseable"
  let _ = support.write_unparseable_spec_project(root)

  graded.run_why(root, "proj.go")
  |> should.equal(
    Error(graded.GradedParseError(
      root <> "/proj.graded",
      annotation.InvalidLine(2, "not a graded line"),
    )),
  )
  support.cleanup(root)
}
