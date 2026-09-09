// Tests for `graded/internal/coverage` and the `graded coverage` command.
//
// Two halves. The renderer is a pure function over a built report, so its
// wording and its conditional sections are pinned against hand-built values;
// then the command is run end to end over real fixture projects, so what the
// report states is what the checker computed rather than what a test assembled.

import glance
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import graded
import graded/internal/cli
import graded/internal/compat
import graded/internal/config
import graded/internal/coverage
import graded/internal/types
import support

// The report over a clean package
//
// Every conditional section absent, which is the shape a package with nothing
// to report prints.

const clean_report = "graded 0.20.0
gleam 1.18.0 (verified), erlang/OTP 28 (verified: 28.4.2), girard 3.0.0 (verified), glance 7.0.0

targets: erlang — gleam.toml declares none, so bodies are read on erlang and declarations on both
type inference: ran on erlang; no @target function, so no second run

modules: 16 read, 0 unread
functions: 1060 typed, 0 skipped, 0 left out of every run, 0 unread
constants: 42 typed, 0 skipped, 0 left out of every run, 0 unread
ambiguous calls: 3127 — 80 decided by the type inference, 3047 settled lexically with the inference agreeing, 0 settled lexically with no typed evidence, 0 wired from a construction, 0 undecided; 0 disagreements

path dependencies: none"

pub fn a_clean_report_states_the_counts_and_nothing_else_test() {
  coverage.render(clean()) |> should.equal(clean_report)
}

pub fn an_unverified_version_is_stated_and_noticed_test() {
  // Stated inline beside every version it was verified against, and repeated in
  // the notices, which is the section a reader acts on.
  let report =
    with_versions(
      clean(),
      compat.Observed(
        graded: "0.20.0",
        girard: Ok("3.0.0"),
        glance: Ok("7.0.0"),
        otp: Ok("28"),
        gleam: Ok("1.19.0"),
      ),
    )
  let rendered = coverage.render(report)
  rendered
  |> string.contains("gleam 1.19.0 (verified: 1.18.0)")
  |> should.be_true()
  rendered
  |> string.contains(
    "versions\n  gleam 1.19.0 is not a verified version (verified: 1.18.0)",
  )
  |> should.be_true()
}

pub fn a_version_that_could_not_be_read_is_stated_as_unobserved_test() {
  // The JavaScript target holds no application metadata; "not observed" is the
  // honest answer and no notice follows from it.
  let report =
    with_versions(
      clean(),
      compat.Observed(
        graded: "0.20.0",
        girard: Error(Nil),
        glance: Error(Nil),
        otp: Error(Nil),
        gleam: Error(Nil),
      ),
    )
  let rendered = coverage.render(report)
  rendered
  |> string.contains(
    "gleam not observed, erlang/OTP not observed, girard not observed, glance not observed",
  )
  |> should.be_true()
  rendered |> string.contains("versions\n") |> should.be_false()
}

pub fn a_manifest_pinning_another_girard_is_noticed_test() {
  // A checkout of graded pointed at another project: the line says which is
  // which rather than reporting the analyzed pin as the analyzer.
  let report =
    coverage.CoverageReport(
      ..clean(),
      versions: coverage.Versions(
        ..{ clean() }.versions,
        manifest_girard: Some("3.1.0"),
      ),
    )
  coverage.render(report)
  |> string.contains(
    "the project's manifest pins girard 3.1.0; the analyzer running is girard 3.0.0",
  )
  |> should.be_true()
}

pub fn a_manifest_naming_the_running_girard_is_not_noticed_test() {
  let report =
    coverage.CoverageReport(
      ..clean(),
      versions: coverage.Versions(
        ..{ clean() }.versions,
        manifest_girard: Some("3.0.0"),
      ),
    )
  coverage.render(report)
  |> string.contains("manifest pins")
  |> should.be_false()
}

// Where the targets came from
//
// The sentence the `targets:` line ends with. `types.PackageTargets` cannot say
// it — a named set looks the same whichever field named it — so the config's
// own reading is what is printed.

pub fn each_targets_source_states_where_the_set_came_from_test() {
  [
    #(
      config.ToolsGradedTargets,
      "`[tools.graded].targets` names erlang and javascript",
    ),
    #(config.TopLevelTarget, "gleam.toml's `target` names it"),
    #(
      config.UnreadableDeclaration,
      "gleam.toml names a target graded cannot read, so every target stays in reach",
    ),
    #(
      config.NoTargetDeclared,
      "gleam.toml declares none, so bodies are read on erlang and declarations on both",
    ),
    #(config.NoConfig, "there is no gleam.toml, so nothing is narrowed"),
  ]
  |> list.each(fn(entry) {
    let #(source, sentence) = entry
    coverage.render(
      coverage.CoverageReport(
        ..clean(),
        targets: ["erlang", "javascript"],
        targets_source: source,
      ),
    )
    |> string.contains("targets: erlang, javascript — " <> sentence)
    |> should.be_true()
  })
}

pub fn a_second_run_is_stated_on_the_inference_line_test() {
  coverage.render(
    coverage.CoverageReport(..clean(), ran_on: ["erlang", "javascript"]),
  )
  |> string.contains(
    "type inference: ran on erlang, javascript; a @target function gates the second run",
  )
  |> should.be_true()
}

// The conditional sections
//
// Each present only when it has a row, so a clean report says nothing about a
// listing that is empty.

pub fn a_skipped_constant_is_rendered_with_its_kind_test() {
  coverage.render(
    coverage.CoverageReport(..clean(), skipped: [
      coverage.SkippedDefinition(
        path: "app/server.handle",
        location: Some("src/app/server.gleam:41:1"),
        kind: coverage.Function,
        bucket: "TypeMismatch",
      ),
      coverage.SkippedDefinition(
        path: "app/config.default",
        location: Some("src/app/config.gleam:7:1"),
        kind: coverage.Constant,
        bucket: "UnboundVariable",
      ),
    ]),
  )
  |> string.contains(
    "skipped definitions
  app/server.handle (src/app/server.gleam:41:1): TypeMismatch
  app/config.default (src/app/config.gleam:7:1): UnboundVariable — constant",
  )
  |> should.be_true()
}

pub fn an_unlocated_skip_is_rendered_with_its_marker_test() {
  // It names no definition the module declares, so it carries no coordinates
  // and is listed apart rather than folded onto a sentinel span.
  coverage.render(
    coverage.CoverageReport(..clean(), skipped: [
      coverage.SkippedDefinition(
        path: "app/server.helper",
        location: None,
        kind: coverage.Function,
        bucket: "NoSuchField",
      ),
    ]),
  )
  |> string.contains("  (unlocated) app/server.helper: NoSuchField")
  |> should.be_true()
}

pub fn an_unfilled_module_is_listed_test() {
  coverage.render(
    coverage.CoverageReport(..clean(), unfilled_modules: ["app/browser"]),
  )
  |> string.contains("modules the second run could not read\n  app/browser")
  |> should.be_true()
}

pub fn a_typed_path_dependency_is_listed_test() {
  coverage.render(
    coverage.CoverageReport(..clean(), path_dependencies: [
      coverage.PathDependency(
        package: "dep",
        ran_on: ["erlang", "javascript"],
        unread_modules: 0,
        skipped: 1,
        left_out: 0,
      ),
    ]),
  )
  |> string.contains(
    "path dependencies:\n  dep (typed on erlang, javascript): 0 modules unread, 1 skipped, 0 left out of every run",
  )
  |> should.be_true()
}

// The partition
//
// Every row is in exactly one provenance class, read off its graded half. The
// two rows below are the ones that could be counted twice: a mismatch is
// undecided *and* listed as a mismatch, and a wired row with no typed evidence
// is wired *and* listed under no typed evidence.

pub fn every_row_falls_in_exactly_one_class_test() {
  let rows = [
    check(
      types.SyntaxModule("gleam/io"),
      types.ProvedModuleCall("gleam/io", "println"),
    ),
    check(
      types.TypeSelectedModule("gleam/io"),
      types.ProvedModuleCall("gleam/io", "println"),
    ),
    check(
      types.Field(Some("gleam/io")),
      types.ProvedFieldCall(#("app", "Logger"), "println"),
    ),
    check(
      types.Field(None),
      types.ProvedFieldCall(#("app", "Logger"), "println"),
    ),
    check(
      types.WiredValue(types.WiredConstructor),
      types.Undecided(types.DefinitionDropped),
    ),
    check(
      types.UndecidedShadowed(
        "gleam/list",
        types.ResolutionMismatch("gleam/list.each"),
      ),
      types.ProvedModuleCall("gleam/list", "each"),
    ),
  ]
  list.map(rows, coverage.provenance_class)
  |> should.equal([
    coverage.SettledLexically,
    coverage.DecidedByInference,
    coverage.DecidedByInference,
    coverage.SettledLexically,
    coverage.WiredFromConstruction,
    coverage.Undecided,
  ])
}

pub fn the_headline_total_is_the_classes_summed_test() {
  // There is no total beside the classes to disagree with them: the headline is
  // what they add up to, so the report cannot state one its classes do not.
  coverage.render(
    coverage.CoverageReport(
      ..clean(),
      calls: coverage.CallCounts(
        decided: 2,
        lexical_agreeing: 1,
        lexical_no_evidence: 1,
        wired: 1,
        undecided: 1,
        disagreements: 1,
      ),
    ),
  )
  |> string.contains(
    "ambiguous calls: 6 — 2 decided by the type inference, 1 settled lexically with the inference agreeing, 1 settled lexically with no typed evidence, 1 wired from a construction, 1 undecided; 1 disagreements",
  )
  |> should.be_true()
}

// Site coordinates
//
// A byte offset as `line:column`, one-based, with the column counted in
// characters so two calls in one function read as two places a reader can find.

pub fn an_offset_on_the_first_line_is_line_one_test() {
  coverage.coordinates("io.println(\"hi\")\n", 0) |> should.equal("1:1")
  coverage.coordinates("io.println(\"hi\")\n", 3) |> should.equal("1:4")
}

pub fn an_offset_after_a_newline_starts_the_next_line_test() {
  coverage.coordinates("one\ntwo\nthree\n", 8) |> should.equal("3:1")
}

pub fn a_column_after_a_multi_byte_character_counts_characters_test() {
  // `é` is two bytes and one character: the column an editor shows is the
  // character count, not the byte count.
  coverage.coordinates("let é = 1\nio.println(x)\n", 11) |> should.equal("2:1")
}

// The command, end to end
//
// Over real fixture projects, so the counts are the checker's own.

pub fn a_clean_project_reports_no_listings_test() {
  let root =
    support.write_fixture("build/coverage_clean", [
      #("gleam.toml", "name = \"app\"\n"),
      #("m.gleam", "pub fn go() -> Int {\n  1\n}\n"),
    ])
  let assert Ok(report) = graded.run_coverage(root)
  report |> string.contains("modules: 1 read, 0 unread") |> should.be_true()
  report
  |> string.contains("functions: 1 typed, 0 skipped, 0 left out of every run")
  |> should.be_true()
  report
  |> string.contains(
    "targets: erlang, javascript — there is no gleam.toml, so nothing is narrowed",
  )
  |> should.be_false()
  report |> string.contains("skipped definitions") |> should.be_false()
  report |> string.contains("undecided shadowed calls") |> should.be_false()
  report |> string.contains("path dependencies: none") |> should.be_true()
  support.cleanup(root)
}

pub fn a_gated_constant_is_reported_as_left_out_test() {
  // The one count expected non-zero on a clean package: no gated function, so
  // no second run, so the constant is read on neither.
  let root =
    support.write_fixture("build/coverage_gated_constant", [
      #("gleam.toml", "name = \"app\"\n"),
      #(
        "m.gleam",
        "@target(javascript)\npub const mode = \"browser\"\n\npub fn go() -> Int {\n  1\n}\n",
      ),
    ])
  let assert Ok(report) = graded.run_coverage(root)
  report
  |> string.contains("constants: 0 typed, 0 skipped, 1 left out of every run")
  |> should.be_true()
  report
  |> string.contains("no @target function, so no second run")
  |> should.be_true()
  support.cleanup(root)
}

pub fn a_gated_function_runs_the_inference_twice_test() {
  let root =
    support.write_fixture("build/coverage_gated_function", [
      #("gleam.toml", "name = \"app\"\n"),
      #(
        "m.gleam",
        "@target(javascript)\npub fn browser_only() -> Int {\n  1\n}\n\npub fn go() -> Int {\n  1\n}\n",
      ),
    ])
  let assert Ok(report) = graded.run_coverage(root)
  report
  |> string.contains(
    "type inference: ran on erlang, javascript; a @target function gates the second run",
  )
  |> should.be_true()
  report
  |> string.contains("functions: 2 typed, 0 skipped, 0 left out of every run")
  |> should.be_true()
  support.cleanup(root)
}

pub fn a_skipped_function_lists_its_site_and_its_calls_test() {
  // A function the inference declines is listed under `skipped definitions`,
  // and the shadowed calls inside it are undecided — two calls on one label in
  // one function, printed as two rows a reader can tell apart.
  let root =
    support.write_fixture("build/coverage_skipped", [
      #("gleam.toml", "name = \"app\"\n"),
      #(
        "m.gleam",
        "import gleam/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn broken(io: Logger) -> Nil {
  io.println(\"one\")
  io.println(\"two\")
  let mismatched: Int = \"not an int\"
  case mismatched {
    _ -> Nil
  }
}
",
      ),
    ])
  let assert Ok(report) = graded.run_coverage(root)
  report |> string.contains("skipped definitions") |> should.be_true()
  report |> string.contains("m.broken (") |> should.be_true()
  report
  |> string.contains("no typed resolution (function skipped: TypeMismatch)")
  |> should.be_true()
  report |> string.contains("undecided shadowed calls") |> should.be_true()
  let rows =
    string.split(report, "\n")
    |> list.filter(string.contains(_, "m.broken `io.println`"))
  list.length(rows) |> should.equal(2)
  // Two rows, two places: the coordinates are what tells them apart.
  { list.unique(rows) == rows } |> should.be_true()
  support.cleanup(root)
}

pub fn the_reported_call_total_is_every_row_test() {
  // The classes partition the rows only if `provenance_class` is exhaustive
  // over every classification a real package produces — which no hand-built
  // report can show. This does: the headline the classes sum to is the number
  // of rows `graded check` computed.
  let root =
    support.write_fixture("build/coverage_partition", [
      #("gleam.toml", "name = \"app\"\n"),
      #(
        "m.gleam",
        "import gleam/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn shadowed(io: Logger) -> Nil {
  io.println(\"hi\")
}

pub fn plain() -> Nil {
  io.println(\"hi\")
}
",
      ),
    ])
  let assert Ok(rows) = graded.classification_checks(root)
  let assert Ok(report) = graded.run_coverage(root)
  report
  |> string.contains(
    "ambiguous calls: " <> int.to_string(list.length(rows)) <> " — ",
  )
  |> should.be_true()
  { list.length(rows) > 0 } |> should.be_true()
  support.cleanup(root)
}

// The decoder
//
// `coverage` takes the optional directory and nothing else.

pub fn coverage_args_default_to_src_test() {
  cli.parse_coverage_args([]) |> should.equal(Ok("src"))
}

pub fn coverage_args_take_one_directory_test() {
  cli.parse_coverage_args(["dir"]) |> should.equal(Ok("dir"))
}

pub fn coverage_args_reject_an_option_test() {
  cli.parse_coverage_args(["--quiet"])
  |> should.equal(Error(cli.UnknownOption("--quiet")))
}

pub fn coverage_args_reject_an_extra_argument_test() {
  cli.parse_coverage_args(["dir", "extra"])
  |> should.equal(Error(cli.UnexpectedArgument("extra")))
}

// A `CoverageReport` with every conditional section empty and counts that
// partition.
fn clean() -> coverage.CoverageReport {
  coverage.CoverageReport(
    versions: coverage.Versions(
      observed: compat.Observed(
        graded: "0.20.0",
        girard: Ok("3.0.0"),
        glance: Ok("7.0.0"),
        otp: Ok("28"),
        gleam: Ok("1.18.0"),
      ),
      manifest_girard: None,
    ),
    targets: ["erlang"],
    targets_source: config.NoTargetDeclared,
    ran_on: ["erlang"],
    modules_read: 16,
    modules_unread: 0,
    functions: coverage.DefinitionCounts(
      typed: 1060,
      skipped: 0,
      left_out: 0,
      unread: 0,
    ),
    constants: coverage.DefinitionCounts(
      typed: 42,
      skipped: 0,
      left_out: 0,
      unread: 0,
    ),
    calls: coverage.CallCounts(
      decided: 80,
      lexical_agreeing: 3047,
      lexical_no_evidence: 0,
      wired: 0,
      undecided: 0,
      disagreements: 0,
    ),
    skipped: [],
    undecided: [],
    lexical_no_evidence: [],
    disagreements: [],
    mismatches: [],
    unfilled_modules: [],
    path_dependencies: [],
  )
}

fn with_versions(
  report: coverage.CoverageReport,
  observed: compat.Observed,
) -> coverage.CoverageReport {
  coverage.CoverageReport(
    ..report,
    versions: coverage.Versions(..report.versions, observed:),
  )
}

// One classification row; only its two halves matter to the class it falls in.
fn check(
  graded: types.GradedClassification,
  typed: types.TypedClassification,
) -> types.ClassificationCheck {
  types.ClassificationCheck(
    module: "app",
    function: "go",
    object: "io",
    label: "println",
    span: glance.Span(0, 1),
    graded:,
    typed:,
  )
}
