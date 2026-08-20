// The `catalog` command
//
// Decoding its argument forms, the listing and its per-package suffixes, the
// bytes and header one printed file carries, and every way the command can fail
// to answer. The report tests run against a fixture catalog written under
// `build/`; the last section goes through the seam against graded's own bundled
// catalog.

import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import graded
import graded/internal/annotation
import graded/internal/cli
import graded/internal/effect_term
import graded/internal/effects
import graded/internal/types
import simplifile
import support

// Argument decoding
//
// `[package[@version]] [directory]`, package first: a lone argument is always a
// package, and `@` splits it from a version at its first occurrence.

pub fn no_arguments_list_the_catalog_test() {
  cli.parse_catalog_args([])
  |> should.equal(Ok(cli.ListCatalog))
}

pub fn a_package_alone_takes_the_default_directory_test() {
  cli.parse_catalog_args(["lustre"])
  |> should.equal(Ok(cli.ShowCatalog("lustre", None, "src")))
}

pub fn a_package_at_a_version_with_a_directory_test() {
  cli.parse_catalog_args(["lustre@5.0.0", "app"])
  |> should.equal(Ok(cli.ShowCatalog("lustre", Some("5.0.0"), "app")))
}

pub fn a_version_carrying_its_own_at_sign_test() {
  // The split is on the first `@`, so the rest is the version — which the
  // catalog then has no file for, rather than the argument being a usage error.
  cli.parse_catalog_args(["lustre@5@x"])
  |> should.equal(Ok(cli.ShowCatalog("lustre", Some("5@x"), "src")))
}

pub fn an_empty_version_is_a_usage_error_test() {
  cli.parse_catalog_args(["lustre@"])
  |> should.equal(Error(cli.InvalidPackage("lustre@")))
}

pub fn an_empty_package_is_a_usage_error_test() {
  cli.parse_catalog_args(["@5.0.0"])
  |> should.equal(Error(cli.InvalidPackage("@5.0.0")))
}

pub fn a_flag_in_the_package_position_is_an_unknown_option_test() {
  cli.parse_catalog_args(["--x"])
  |> should.equal(Error(cli.UnknownOption("--x")))
}

pub fn a_third_positional_is_rejected_test() {
  cli.parse_catalog_args(["lustre", "a", "b"])
  |> should.equal(Error(cli.UnexpectedArgument("b")))
}

pub fn the_rejection_messages_test() {
  cli.format_argument_error(cli.InvalidPackage("lustre@"))
  |> should.equal("expected a package or package@version, got `lustre@`")
  cli.format_argument_error(cli.UnknownOption("--x"))
  |> should.equal("unknown option `--x`")
  cli.format_argument_error(cli.UnexpectedArgument("b"))
  |> should.equal("unexpected argument `b`")
}

// The listing
//
// One `package@version` line per bundled file, sorted, with a comment on the
// line each installed package resolves to. All three suffix shapes come out of
// the same three files under three manifests.

pub fn the_listing_marks_the_selected_file_test() {
  use catalog_dir, manifest <- with_catalog(
    "build/catalog_cli_listing",
    Some(manifest_for("lustre", "5.7.0")),
  )
  catalog_report(catalog_dir, manifest, cli.ListCatalog)
  |> lines
  |> should.equal([
    "argv@1.1.0", "lustre@4.0.0", "lustre@5.0.0  // selected for lustre 5.7.0",
  ])
}

pub fn the_listing_marks_a_file_below_the_highest_test() {
  // Installed between the two bundled versions: the lower file is the one
  // selected, so the suffix lands there and nowhere else.
  use catalog_dir, manifest <- with_catalog(
    "build/catalog_cli_listing_lower",
    Some(manifest_for("lustre", "4.5.0")),
  )
  catalog_report(catalog_dir, manifest, cli.ListCatalog)
  |> lines
  |> should.equal([
    "argv@1.1.0", "lustre@4.0.0  // selected for lustre 4.5.0", "lustre@5.0.0",
  ])
}

pub fn the_listing_marks_the_fall_back_as_such_test() {
  // Nothing bundled at or below the installed version, so the highest file is
  // taken — and says so, rather than claiming to be selected for a version it
  // sits above.
  use catalog_dir, manifest <- with_catalog(
    "build/catalog_cli_listing_fallback",
    Some(manifest_for("lustre", "3.0.0")),
  )
  catalog_report(catalog_dir, manifest, cli.ListCatalog)
  |> lines
  |> should.equal([
    "argv@1.1.0", "lustre@4.0.0",
    "lustre@5.0.0  // highest bundled; none ≤ lustre 3.0.0",
  ])
}

pub fn the_listing_without_a_manifest_test() {
  // The listing is about the catalog; the manifest only decorates it.
  use catalog_dir, manifest <- with_catalog(
    "build/catalog_cli_listing_no_manifest",
    None,
  )
  catalog_report(catalog_dir, manifest, cli.ListCatalog)
  |> lines
  |> should.equal(["argv@1.1.0", "lustre@4.0.0", "lustre@5.0.0"])
}

// Printing one file
//
// The header names the file and why it was chosen; the rest is the file. What
// reaches stdout is `header <> "\n" <> file bytes`, since `report` prints with
// `io.println` and the output has exactly one trailing newline dropped for it.

pub fn the_printed_file_is_the_header_and_the_bytes_test() {
  expect_show(
    "build/catalog_cli_show",
    Some(manifest_for("lustre", "5.7.0")),
    show("lustre", None),
    "lustre@5.0.0.graded — selected for lustre 5.7.0 in manifest.toml",
    lustre_five,
  )
}

pub fn the_selected_file_follows_the_installed_version_test() {
  expect_show(
    "build/catalog_cli_show_lower",
    Some(manifest_for("lustre", "4.5.0")),
    show("lustre", None),
    "lustre@4.0.0.graded — selected for lustre 4.5.0 in manifest.toml",
    lustre_four,
  )
}

pub fn the_fall_back_prints_the_highest_bundled_file_test() {
  expect_show(
    "build/catalog_cli_show_fallback",
    Some(manifest_for("lustre", "3.0.0")),
    show("lustre", None),
    "lustre@5.0.0.graded — highest bundled version; no bundled lustre ≤ 3.0.0",
    lustre_five,
  )
}

pub fn an_explicit_version_ignores_the_manifest_test() {
  // The manifest installs 5.7.0, which the implicit form would resolve to the
  // 5.0.0 file: the explicit form neither consults it nor re-selects.
  expect_show(
    "build/catalog_cli_show_explicit_installed",
    Some(manifest_for("lustre", "5.7.0")),
    show("lustre", Some("4.0.0")),
    "lustre@4.0.0.graded — bundled version, as requested",
    lustre_four,
  )
}

pub fn a_file_ending_in_no_newline_gains_one_test() {
  // `argv@1.1.0` ends in none, so `println` supplies it — the one place the
  // printed bytes differ from the file's.
  expect_show(
    "build/catalog_cli_show_none",
    Some(manifest_for("lustre", "5.7.0")),
    show("argv", Some("1.1.0")),
    "argv@1.1.0.graded — bundled version, as requested",
    argv_entry,
  )
}

pub fn a_file_ending_in_two_newlines_keeps_both_test() {
  // `lustre@5.0.0` ends in two: an over-eager trim would eat the second, which
  // the equation above cannot see because it appends the one `println` adds.
  use catalog_dir, manifest <- with_catalog(
    "build/catalog_cli_show_two",
    Some(manifest_for("lustre", "5.7.0")),
  )
  catalog_report(catalog_dir, manifest, show("lustre", Some("5.0.0")))
  |> string.ends_with("[Dom]\n")
  |> should.be_true()
}

pub fn a_file_ending_in_a_carriage_return_keeps_it_test() {
  // `\r\n` is one grapheme and two bytes: only the newline is the one
  // `println` puts back, so only the newline comes off.
  let root =
    support.write_fixture("build/catalog_cli_crlf", [
      #("catalog/crlf@1.0.0.graded", "external effects crlf.run : []\r\n"),
    ])
  let output =
    catalog_report(
      root <> "/catalog",
      "no_such_manifest.toml",
      show("crlf", Some("1.0.0")),
    )
  support.cleanup(root)
  output
  |> should.equal(
    "// crlf@1.0.0.graded — bundled version, as requested\nexternal effects crlf.run : []\r",
  )
}

pub fn an_explicit_version_needs_no_manifest_test() {
  use catalog_dir, _manifest <- with_catalog(
    "build/catalog_cli_show_explicit",
    None,
  )
  should.equal(
    catalog_report(
      catalog_dir,
      "no_such_manifest.toml",
      show("lustre", Some("4.0.0")),
    )
      <> "\n",
    "// lustre@4.0.0.graded — bundled version, as requested\n"
      <> newline_terminated(lustre_four),
  )
}

pub fn the_printed_file_parses_as_a_spec_test() {
  use catalog_dir, manifest <- with_catalog(
    "build/catalog_cli_show_parses",
    Some(manifest_for("lustre", "5.7.0")),
  )
  catalog_report(catalog_dir, manifest, show("lustre", None))
  |> annotation.parse_file
  |> should.be_ok
}

// What `report` puts on stdout for `request`: the header line, then the file,
// with the single trailing newline `io.println` appends.
fn expect_show(
  root: String,
  manifest: Option(String),
  request: cli.CatalogRequest,
  header: String,
  body: String,
) -> Nil {
  use catalog_dir, manifest <- with_catalog(root, manifest)
  should.equal(
    catalog_report(catalog_dir, manifest, request) <> "\n",
    "// " <> header <> "\n" <> newline_terminated(body),
  )
}

// Why the command could not answer
//
// The catalog is consulted before the manifest, so a package with no bundled
// file is `NoCatalogEntry` whether or not it is installed — and every other
// problem has a non-empty list of bundled versions to name.

pub fn a_bundled_package_that_is_not_installed_test() {
  use catalog_dir, manifest <- with_catalog(
    "build/catalog_cli_not_installed",
    Some(manifest_for("lustre", "5.7.0")),
  )
  let problem = catalog_problem(catalog_dir, manifest, show("argv", None))
  problem
  |> should.equal(graded.NotInstalled("argv", ["argv@1.1.0"]))
  graded.format_catalog_problem(problem)
  |> should.equal(
    "`argv` is not in manifest.toml; bundled: argv@1.1.0 — run `graded catalog argv@1.1.0` to print one",
  )
}

pub fn the_suggested_version_is_the_highest_bundled_test() {
  use catalog_dir, manifest <- with_catalog(
    "build/catalog_cli_not_installed_highest",
    Some(manifest_for("argv", "1.1.0")),
  )
  catalog_problem(catalog_dir, manifest, show("lustre", None))
  |> graded.format_catalog_problem
  |> should.equal(
    "`lustre` is not in manifest.toml; bundled: lustre@4.0.0, lustre@5.0.0 — run `graded catalog lustre@5.0.0` to print one",
  )
}

pub fn a_package_the_catalog_does_not_bundle_test() {
  use catalog_dir, manifest <- with_catalog(
    "build/catalog_cli_no_entry",
    Some(manifest_for("lustre", "5.7.0")),
  )
  let problem = catalog_problem(catalog_dir, manifest, show("wisp", None))
  problem |> should.equal(graded.NoCatalogEntry("wisp"))
  graded.format_catalog_problem(problem)
  |> should.equal("no catalog entry for `wisp`")
}

pub fn an_installed_package_the_catalog_does_not_bundle_test() {
  // The check order: the catalog is asked first, so being installed does not
  // turn a missing entry into `NotInstalled`.
  use catalog_dir, manifest <- with_catalog(
    "build/catalog_cli_no_entry_installed",
    Some(manifest_for("wisp", "1.0.0")),
  )
  catalog_problem(catalog_dir, manifest, show("wisp", None))
  |> should.equal(graded.NoCatalogEntry("wisp"))
}

pub fn an_explicit_version_of_an_unbundled_package_test() {
  use catalog_dir, manifest <- with_catalog(
    "build/catalog_cli_no_entry_explicit",
    Some(manifest_for("lustre", "5.7.0")),
  )
  catalog_problem(catalog_dir, manifest, show("wisp", Some("1.0.0")))
  |> should.equal(graded.NoCatalogEntry("wisp"))
}

pub fn a_version_the_catalog_does_not_bundle_test() {
  use catalog_dir, manifest <- with_catalog(
    "build/catalog_cli_no_version",
    Some(manifest_for("lustre", "5.7.0")),
  )
  let problem =
    catalog_problem(catalog_dir, manifest, show("lustre", Some("3.0.0")))
  problem
  |> should.equal(
    graded.NoBundledVersion("lustre", "3.0.0", ["lustre@4.0.0", "lustre@5.0.0"]),
  )
  graded.format_catalog_problem(problem)
  |> should.equal(
    "no bundled `lustre@3.0.0`; bundled: lustre@4.0.0, lustre@5.0.0",
  )
}

pub fn a_catalog_directory_that_does_not_exist_test() {
  graded.catalog_report(
    "build/catalog_cli_missing",
    "no_such_manifest.toml",
    cli.ListCatalog,
  )
  |> should.be_error
}

pub fn a_directory_holding_no_catalog_file_test() {
  // Not graded's catalog, whichever form asked: an empty listing would read as
  // "nothing is bundled".
  let root =
    support.write_fixture("build/catalog_cli_empty", [
      #("catalog/README", "not a catalog file\n"),
    ])
  let catalog_dir = root <> "/catalog"
  let empty = graded.CatalogError(graded.EmptyCatalog(catalog_dir))
  graded.catalog_report(catalog_dir, "no_such_manifest.toml", cli.ListCatalog)
  |> should.equal(Error(empty))
  graded.catalog_report(
    catalog_dir,
    "no_such_manifest.toml",
    show("lustre", None),
  )
  |> should.equal(Error(empty))
  graded.format_catalog_problem(graded.EmptyCatalog(catalog_dir))
  |> should.equal("no catalog files under " <> catalog_dir)
  support.cleanup(root)
}

// Through the seam
//
// `run_catalog` against graded's own bundled catalog and this project's
// manifest: what the command prints is the file the catalog tier folded.

pub fn the_seam_prints_the_selected_bundled_file_test() {
  let assert Ok(files) =
    effects.bundled_catalog_files(effects.catalog_directory())
  let assert Ok(installed) =
    dict.get(effects.manifest_versions("manifest.toml"), "gleam_stdlib")
  let assert Ok(selection) =
    effects.select_catalog_file(files, "gleam_stdlib", installed)
  let assert Ok(contents) = simplifile.read(selection.file.path)
  let assert Ok(output) =
    graded.run_catalog(cli.ShowCatalog("gleam_stdlib", None, "src"))

  output
  |> string.starts_with(
    "// gleam_stdlib@" <> selection.file.version <> ".graded — selected for ",
  )
  |> should.be_true()
  { output <> "\n" }
  |> string.ends_with("\n" <> newline_terminated(contents))
  |> should.be_true()
}

// Two files one version apart
//
// Bundled versions that parse alike cannot be ordered by version, so the file
// the command names and the file the resolver folds have to be settled by
// something both share.

pub fn a_tie_selects_one_file_for_both_paths_test() {
  let root =
    support.write_fixture("build/catalog_cli_tie", [
      #("catalog/foo@1.0.0.graded", "external effects foo/x.run : [Release]\n"),
      #(
        "catalog/foo@1.0.0-rc1.graded",
        "external effects foo/x.run : [Prerelease]\n",
      ),
      #("manifest.toml", manifest_for("foo", "1.0.0")),
    ])
  let printed =
    catalog_report(
      root <> "/catalog",
      root <> "/manifest.toml",
      show("foo", None),
    )
  let #(function_effects, _module_effects, _params, _type_fields) =
    effects.load_catalog(root <> "/catalog", root <> "/manifest.toml")
  support.cleanup(root)

  // Each file declares the same function with an effect only it names, so the
  // effect the knowledge base answers with says which file the resolver folded.
  let assert Ok(#(term, _origin)) =
    dict.get(function_effects, types.QualifiedName("foo/x", "run"))
  let assert Ok(resolved) =
    ["Release", "Prerelease"]
    |> list.find(fn(label) {
      effect_term.to_effect_set(term) == types.from_labels([label])
    })
  printed
  |> string.contains("[" <> resolved <> "]")
  |> should.be_true()
}

// Fixtures
//
// One catalog of three files under two packages, whose contents differ and
// whose trailing newlines are none, one and two — the counts the printed-bytes
// equation has to hold for.

const argv_entry = "external effects argv.load : [Args]
external effects argv.raw : [Args]"

const lustre_four = "external effects lustre/four.build : []
external effects lustre/four.render : [Dom]
"

const lustre_five = "external effects lustre/five.build : []
external effects lustre/five.render : [Dom]

"

// Write the fixture catalog (and, where one is given, a manifest) under `root`,
// hand `run` the two paths `catalog_report` takes, and delete the fixture.
fn with_catalog(
  root: String,
  manifest: Option(String),
  run: fn(String, String) -> a,
) -> a {
  let catalog = [
    #("catalog/argv@1.1.0.graded", argv_entry),
    #("catalog/lustre@4.0.0.graded", lustre_four),
    #("catalog/lustre@5.0.0.graded", lustre_five),
  ]
  let files = case manifest {
    Some(contents) -> [#("manifest.toml", contents), ..catalog]
    None -> catalog
  }
  let root = support.write_fixture(root, files)
  let output = run(root <> "/catalog", root <> "/manifest.toml")
  support.cleanup(root)
  output
}

fn manifest_for(package: String, version: String) -> String {
  "packages = [\n  { name = \""
  <> package
  <> "\", version = \""
  <> version
  <> "\" },\n]\n"
}

fn show(package: String, version: Option(String)) -> cli.CatalogRequest {
  cli.ShowCatalog(package:, version:, directory: "src")
}

// The report a request is expected to answer with.
fn catalog_report(
  catalog_dir: String,
  manifest: String,
  request: cli.CatalogRequest,
) -> String {
  let assert Ok(output) = graded.catalog_report(catalog_dir, manifest, request)
  output
}

// The problem a request is expected to fail with.
fn catalog_problem(
  catalog_dir: String,
  manifest: String,
  request: cli.CatalogRequest,
) -> graded.CatalogProblem {
  let assert Error(graded.CatalogError(problem)) =
    graded.catalog_report(catalog_dir, manifest, request)
  problem
}

fn lines(output: String) -> List(String) {
  string.split(output, "\n")
}

// `text` with the single trailing newline `io.println` supplies, whether or not
// it already ends in one.
fn newline_terminated(text: String) -> String {
  case string.ends_with(text, "\n") {
    True -> text
    False -> text <> "\n"
  }
}
