// What the type inference could and could not read of one package, held as
// data and rendered as a report.
//
// The command over it decides nothing. No charge, no spec line and no exit code
// depends on anything counted here: it is built from the context `check` builds
// and from the rows `why` prints, and if it disagreed with either that would be
// a bug in this module. The reason text for a site is `checker`'s own, so the
// three surfaces cannot word one site differently.
//
// The accounting is disjoint by construction. A module is read or unread;
// within a read module every function and every constant is exactly one of
// typed, skipped or left out of every run; every ambiguous call is in exactly
// one provenance class. Nothing is derived by subtraction from a total, and
// nothing is "typed" by omission.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import graded/internal/compat
import graded/internal/config
import graded/internal/types.{type ClassificationCheck}

// One package's coverage, everything the report states.
pub type CoverageReport {
  CoverageReport(
    versions: Versions,
    targets: List(String),
    targets_source: config.TargetsSource,
    // The targets the inference ran on, primary first.
    ran_on: List(String),
    modules_read: Int,
    modules_unread: Int,
    functions: DefinitionCounts,
    constants: DefinitionCounts,
    calls: CallCounts,
    // Present only when non-empty, each in its own section.
    skipped: List(SkippedDefinition),
    undecided: List(SiteRow),
    // Every row the inference answered nothing for, whatever class it counts
    // in: a lexically settled and a wired row both reach it, and the reason no
    // evidence arrived is the same finding either way.
    no_typed_evidence: List(SiteRow),
    disagreements: List(SiteRow),
    mismatches: List(SiteRow),
    // Modules the primary run read and a second run did not, whose definitions
    // keep the primary's drops — the one state in which a non-zero left-out
    // count is expected.
    unfilled_modules: List(String),
    path_dependencies: List(PathDependency),
  )
}

// The versions of what is *running*, beside the girard the analyzed project's
// own manifest pins where that is a different one.
pub type Versions {
  Versions(observed: compat.Observed, manifest_girard: Option(String))
}

// One kind of top-level definition, counted across the package. `unread` is the
// definitions of a module the inference returned no result for: they are in no
// other count, so a reader who sees it non-zero knows to look at the inference.
pub type DefinitionCounts {
  DefinitionCounts(typed: Int, skipped: Int, left_out: Int, unread: Int)
}

// Every ambiguous call in exactly one class. There is no separate total: the
// headline is the sum of the five, so the report cannot print a total its own
// classes do not add up to. `provenance_class` is exhaustive over
// `GradedClassification` and the lexical split is by whether the inference
// answered at all, so the five do partition the rows a package holds. Whether
// the two *agree* is a further reading of the same rows: `disagreements` cuts
// across the classes and is stated beside, not within, which is why the
// lexical halves are named for the evidence and not for the verdict.
pub type CallCounts {
  CallCounts(
    decided: Int,
    lexical_with_evidence: Int,
    lexical_no_evidence: Int,
    wired: Int,
    undecided: Int,
    disagreements: Int,
  )
}

// One definition the inference declined: its qualified path, where it sits, the
// kind that answered, and the error bucket. `location` is `None` for a skip
// naming no definition the module declares, which is listed under its own
// marker and counted in none of the three standings.
pub type SkippedDefinition {
  SkippedDefinition(
    path: String,
    location: Option(String),
    kind: DefinitionKind,
    bucket: String,
  )
}

pub type DefinitionKind {
  Function
  Constant
}

// One ambiguous call as a listed row: where it sits, and what is being said
// about it. `detail` is `checker`'s own wording, never this module's.
pub type SiteRow {
  SiteRow(
    module: String,
    function: String,
    site: String,
    location: String,
    detail: String,
  )
}

// One typed path dependency: a package installed from hex is not typed and is
// not listed.
pub type PathDependency {
  PathDependency(
    package: String,
    ran_on: List(String),
    unread_modules: Int,
    skipped: Int,
    left_out: Int,
  )
}

// Which provenance class one row falls in, read off its graded half alone. The
// class is what a reader is counting; the typed half refines it into the
// sub-counts and the listings.
pub type ProvenanceClass {
  // The inference chose between the module call and the field call.
  DecidedByInference
  // The extractor settled it, whatever the inference said.
  SettledLexically
  // A construction site named the value, so the call was charged that.
  WiredFromConstruction
  // Neither reading was established, and the call was charged `[Unknown]`.
  Undecided
}

// One row's class. Exhaustive over `GradedClassification` on purpose: a new
// classification has to be placed here rather than falling into a default.
pub fn provenance_class(check: ClassificationCheck) -> ProvenanceClass {
  case check.graded {
    types.TypeSelectedModule(..) -> DecidedByInference
    types.Field(shadowed: Some(_)) -> DecidedByInference
    types.SyntaxModule(..) -> SettledLexically
    types.Field(shadowed: None) -> SettledLexically
    types.WiredValue(..) -> WiredFromConstruction
    types.UndecidedShadowed(..) -> Undecided
  }
}

// The whole report as text. Every conditional section is present only when it
// has a row.
pub fn render(report: CoverageReport) -> String {
  [
    version_lines(report.versions),
    ["", targets_line(report), inference_line(report)],
    ["", ..count_lines(report)],
    section("modules the second run could not read", report.unfilled_modules),
    section("skipped definitions", list.map(report.skipped, skipped_line)),
    section("undecided shadowed calls", list.map(report.undecided, site_line)),
    section("no typed evidence", list.map(report.no_typed_evidence, site_line)),
    section("disagreements", list.map(report.disagreements, site_line)),
    section("identity mismatches", list.map(report.mismatches, site_line)),
    ["", path_dependency_header(report.path_dependencies)],
    list.map(report.path_dependencies, path_dependency_line),
    section("versions", notices(report.versions)),
  ]
  |> list.flatten()
  |> string.join("\n")
}

// Two version lines: the toolchain the package is built with, then graded and
// the libraries it reads the package through.
fn version_lines(versions: Versions) -> List(String) {
  let compat.Observed(graded:, girard:, glance:, otp:, gleam:) =
    versions.observed
  [
    [
      stated("gleam", gleam, compat.verified_gleam),
      stated("erlang/OTP", otp, [compat.verified_otp]),
    ],
    [
      "graded " <> graded,
      stated("girard", girard, [compat.verified_girard]),
      stated("glance", glance, [compat.verified_glance]),
    ],
  ]
  |> list.map(string.join(_, ", "))
}

// One observed version and how it stands. Every version the header names is
// claimed, so an unverified one always has a list to state itself against.
fn stated(
  name: String,
  observed: Result(String, Nil),
  verified: List(String),
) -> String {
  case compat.standing(observed, verified) {
    compat.Unobserved -> name <> " not observed"
    compat.Verified(observed: version) ->
      name <> " " <> version <> " (verified)"
    compat.Unverified(observed: version, verified:) ->
      name
      <> " "
      <> version
      <> " (verified: "
      <> string.join(verified, ", ")
      <> ")"
  }
}

// The lines a reader acts on: an unverified compiler or analyzer, and a project
// whose manifest pins a girard other than the one running.
fn notices(versions: Versions) -> List(String) {
  let compat.Observed(girard:, glance:, gleam:, ..) = versions.observed
  [
    unverified_notice("gleam", gleam, compat.verified_gleam),
    unverified_notice("girard", girard, [compat.verified_girard]),
    unverified_notice("glance", glance, [compat.verified_glance]),
    manifest_notice(versions),
  ]
  |> list.filter_map(fn(notice) { notice })
}

fn unverified_notice(
  name: String,
  observed: Result(String, Nil),
  verified: List(String),
) -> Result(String, Nil) {
  case compat.standing(observed, verified) {
    compat.Unverified(observed: version, verified:) ->
      Ok(
        name
        <> " "
        <> version
        <> " is not a verified version (verified: "
        <> string.join(verified, ", ")
        <> ")",
      )
    compat.Verified(..) | compat.Unobserved -> Error(Nil)
  }
}

// The analyzed project's manifest names a girard; the analyzer running is the
// one graded loaded. A checkout of graded pointed at another project is exactly
// that case, and the line says which is which.
fn manifest_notice(versions: Versions) -> Result(String, Nil) {
  case versions.manifest_girard, versions.observed.girard {
    Some(pinned), Ok(running) if pinned != running ->
      Ok(
        "the project's manifest pins girard "
        <> pinned
        <> "; the analyzer running is girard "
        <> running,
      )
    _, _ -> Error(Nil)
  }
}

// Which targets the package is analysed on, and where that reading came from.
fn targets_line(report: CoverageReport) -> String {
  "targets: "
  <> string.join(report.targets, ", ")
  <> " — "
  <> targets_source_text(report.targets_source, report.targets)
}

fn targets_source_text(
  source: config.TargetsSource,
  targets: List(String),
) -> String {
  case source {
    config.ToolsGradedTargets ->
      "`[tools.graded].targets` names " <> string.join(targets, " and ")
    config.TopLevelTarget -> "gleam.toml's `target` names it"
    config.UnreadableDeclaration -> unreadable_declaration_text
    config.NoTargetDeclared -> no_target_declared_text
    config.NoConfig -> "there is no gleam.toml, so nothing is narrowed"
  }
}

// Which targets the inference itself ran on, and why there was or was not a
// second run.
fn inference_line(report: CoverageReport) -> String {
  "type inference: ran on "
  <> string.join(report.ran_on, ", ")
  <> case report.ran_on {
    [] -> "; nothing was typed"
    [_] -> "; no @target function, so no second run"
    [_, ..] -> "; a @target function gates the second run"
  }
}

const unreadable_declaration_text = "gleam.toml names a target graded cannot read, so every target stays in reach"

const no_target_declared_text = "gleam.toml declares none, so bodies are read on erlang and declarations on both"

fn count_lines(report: CoverageReport) -> List(String) {
  [
    [
      "modules: "
        <> int.to_string(report.modules_read)
        <> " read, "
        <> int.to_string(report.modules_unread)
        <> " unread",
      "functions: "
        <> definition_counts(report.functions)
        <> ", "
        <> int.to_string(report.functions.unread)
        <> " unread",
      "constants: "
        <> definition_counts(report.constants)
        <> ", "
        <> int.to_string(report.constants.unread)
        <> " unread",
    ],
    call_counts(report.calls),
  ]
  |> list.flatten()
}

fn definition_counts(counts: DefinitionCounts) -> String {
  int.to_string(counts.typed)
  <> " typed, "
  <> int.to_string(counts.skipped)
  <> " skipped, "
  <> int.to_string(counts.left_out)
  <> " left out of every run"
}

// The headline, then one class per row. The five that partition the rows are
// bulleted alike and sum to the headline; the disagreement count, which cuts
// across them, says on its own row that it is counted again.
fn call_counts(counts: CallCounts) -> List(String) {
  [
    "ambiguous calls: " <> int.to_string(call_total(counts)),
    ..bulleted([
      int.to_string(counts.decided) <> " decided by the type inference",
      int.to_string(counts.lexical_with_evidence)
        <> " settled lexically with typed evidence",
      int.to_string(counts.lexical_no_evidence)
        <> " settled lexically with no typed evidence",
      int.to_string(counts.wired) <> " wired from a construction",
      int.to_string(counts.undecided) <> " undecided",
      int.to_string(counts.disagreements)
        <> " disagreements, counted again in the class each falls in",
    ])
  ]
}

// The headline count: the classes summed, never a number carried beside them.
pub fn call_total(counts: CallCounts) -> Int {
  counts.decided
  + counts.lexical_with_evidence
  + counts.lexical_no_evidence
  + counts.wired
  + counts.undecided
}

fn skipped_line(skipped: SkippedDefinition) -> String {
  let head = case skipped.location {
    Some(location) -> skipped.path <> " (" <> location <> ")"
    None -> "(unlocated) " <> skipped.path
  }
  head
  <> ": "
  <> skipped.bucket
  <> case skipped.kind {
    Constant -> " — constant"
    Function -> ""
  }
}

fn site_line(row: SiteRow) -> String {
  row.module
  <> "."
  <> row.function
  <> " `"
  <> row.site
  <> "` ("
  <> row.location
  <> "): "
  <> row.detail
}

fn path_dependency_header(dependencies: List(PathDependency)) -> String {
  case dependencies {
    [] -> "path dependencies: none"
    [_, ..] -> "path dependencies:"
  }
}

fn path_dependency_line(dependency: PathDependency) -> String {
  "  "
  <> dependency.package
  <> " (typed on "
  <> string.join(dependency.ran_on, ", ")
  <> "): "
  <> int.to_string(dependency.unread_modules)
  <> " modules unread, "
  <> int.to_string(dependency.skipped)
  <> " skipped, "
  <> int.to_string(dependency.left_out)
  <> " left out of every run"
}

// A titled section, or nothing at all when it has no rows.
fn section(title: String, lines: List(String)) -> List(String) {
  case lines {
    [] -> []
    [_, ..] -> ["", title, ..indented(lines)]
  }
}

// Every section's rows are rendered unindented and get their indentation here,
// so a renderer added later does not have to know the convention.
fn indented(lines: List(String)) -> List(String) {
  list.map(lines, fn(line) { "  " <> line })
}

// A count row under the line it breaks down.
fn bulleted(lines: List(String)) -> List(String) {
  indented(list.map(lines, fn(line) { "- " <> line }))
}

// The `line:column` of a byte offset in `source`, one-based, with the column
// counted in characters so a line holding a multi-byte character reads the way
// an editor shows it.
pub fn coordinates(source: String, offset: Int) -> String {
  let before = byte_prefix(source, offset)
  let lines = string.split(before, "\n")
  let line = list.length(lines)
  let column = case list.last(lines) {
    Ok(last) -> string.length(last) + 1
    Error(Nil) -> 1
  }
  int.to_string(line) <> ":" <> int.to_string(column)
}

// The first `offset` bytes of `source` as a string. glance spans are byte
// offsets while `string` counts characters, so the cut is made on the bytes and
// the result decoded back, rather than walked character by character. An offset
// landing inside a multi-byte character decodes to nothing, so the cut backs off
// a byte at a time until it lands on a boundary.
fn byte_prefix(source: String, offset: Int) -> String {
  let bytes = bit_array.from_string(source)
  case offset <= 0 {
    True -> ""
    False ->
      case
        bit_array.slice(bytes, 0, offset) |> result.try(bit_array.to_string)
      {
        Ok(prefix) -> prefix
        Error(Nil) -> byte_prefix(source, offset - 1)
      }
  }
}
