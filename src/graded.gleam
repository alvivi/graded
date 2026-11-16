//// Effect checker for Gleam via sidecar `.graded` annotation files.
////
//// graded verifies that your Gleam functions respect their declared effect
//// budgets. Annotations live in `.graded` sidecar files alongside your source
//// — your Gleam code stays clean.
////
//// ## Usage
////
//// ```sh
//// gleam run -m graded check [directory]         # enforce check annotations (default)
//// gleam run -m graded infer [directory]         # infer and write effect annotations
//// gleam run -m graded infer --dry-run [dir]     # preview the spec changes, writing nothing
//// gleam run -m graded infer --check [dir]       # fail if the spec is stale (CI mode)
//// gleam run -m graded effect <name> [directory] # look up one effect, writing nothing
//// gleam run -m graded effect <name> --format=graded  # ... as a .graded line
//// gleam run -m graded why <name> [directory]    # explain a function's effects
//// gleam run -m graded catalog                   # list the bundled catalog files
//// gleam run -m graded catalog <package>         # print the catalog file selected for it
//// gleam run -m graded catalog <package>@<ver>   # print exactly that bundled file
//// gleam run -m graded format [directory]        # normalize .graded file formatting
//// ```
////
//// ## Programmatic API
////
//// Use `run` to check a directory and get back one `ModuleReport` per file,
//// carrying the warning and violation lines graded prints for it. Use
//// `run_infer` to infer effects and write `.graded` files, or
//// `run_infer_dry_run` to get back a diff of what that write would change
//// without performing it, or `run_infer_check` to fail when it would change
//// anything. Use `run_effect` to resolve one function or
//// type-field name and get its `.graded` line back, `run_why` to get the
//// effects of one function explained call by call, or `catalog_list` /
//// `catalog_show` to read graded's own bundled catalog — none of them
//// touching anything on disk.
////
//// Every type this module's signatures name is defined here. Nothing under
//// `graded/internal` is part of the API, and a release may change it freely.
////

import argv
import filepath
import girard
import glance
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded/internal/annotation
import graded/internal/answer.{type EffectAnswer}
import graded/internal/checker
import graded/internal/cli
import graded/internal/compat
import graded/internal/config
import graded/internal/contract
import graded/internal/coverage
import graded/internal/diff
import graded/internal/effect_term
import graded/internal/effects.{type KnowledgeBase}
import graded/internal/extract
import graded/internal/lint
import graded/internal/pack
import graded/internal/package_tree.{type LocalPackages}
import graded/internal/signatures.{type SignatureRegistry}
import graded/internal/topo
import graded/internal/typedefs
import graded/internal/typeinfo
import graded/internal/types.{
  type CheckResult, type EffectAnnotation, type EffectTerm, type GradedFile,
  type QualifiedName, AnnotationLine, CheckResult, EffectAnnotation, GradedFile,
  QualifiedName,
}
import simplifile

// Errors and CLI dispatch
//
// The error type every command returns, and the argv dispatcher that routes
// to the per-command runners below.

/// Errors that can occur during checking, inference, or formatting.
///
/// Every variant is renderable on its own: where the cause is a graded type,
/// the variant carries what graded would print for it rather than the type
/// itself, so naming an error never means importing `graded/internal`.
pub type GradedError {
  /// Could not read the source directory.
  DirectoryReadError(path: String, cause: simplifile.FileError)
  /// Could not read a source or annotation file.
  FileReadError(path: String, cause: simplifile.FileError)
  /// Could not write an annotation file.
  FileWriteError(path: String, cause: simplifile.FileError)
  /// Could not create the output directory for annotation files.
  DirectoryCreateError(path: String, cause: simplifile.FileError)
  /// A `.gleam` source file could not be parsed.
  GleamParseError(path: String, cause: glance.Error)
  /// A `.graded` annotation file could not be parsed. `message` is the
  /// description graded itself prints, line number and hint included.
  GradedParseError(path: String, message: String)
  /// `gleam.toml` was present but malformed, unreadable, or missing its
  /// `name`. A missing `gleam.toml` is tolerated and does not produce this
  /// error. `message` describes what was wrong with it.
  InvalidConfig(path: String, message: String)
  /// One or more `.graded` files are not formatted (returned by `run_format_check`).
  FormatCheckFailed(paths: List(String))
  /// The spec file at `path` is not what `graded infer` would write (returned
  /// by `run_infer_check`). `diff` is the line diff `run_infer_dry_run` returns
  /// for the same project.
  StaleSpec(path: String, diff: String)
  /// The project's import graph contains a cycle. Gleam disallows circular
  /// imports at the language level, so this should be unreachable in
  /// practice — if it ever fires it indicates a bug in the dependency edge
  /// extraction rather than user code.
  CyclicImports(modules: List(String))
  /// `graded effect` found no effect for the queried name: it names no public
  /// function and no declared type field.
  EffectNotFound(name: String)
  /// `graded why` found no function to explain: the name isn't module-qualified,
  /// names no module of this project, or names no function of that module.
  FunctionNotFound(name: String)
  /// `graded pack` could not inject the spec into the hex tarball: the tarball
  /// was missing, its identity didn't match the project, the configured
  /// `spec_file` path was unsafe, or the tarball transform failed.
  PackError(message: String)
  /// graded's bundled catalog could not be read, or `graded catalog` could not
  /// answer: see `CatalogProblem`.
  CatalogError(problem: CatalogProblem)
}

/// Why graded's bundled catalog could not be read, or why `graded catalog`
/// could not answer. `EmptyCatalog` and `NoCatalogDirectory` stop every command
/// that resolves calls against the catalog, not only `graded catalog`.
pub type CatalogProblem {
  /// No bundled file names this package.
  NoCatalogEntry(package: String)
  /// The package is bundled, but not at the version asked for.
  NoBundledVersion(package: String, requested: String, bundled: List(String))
  /// The package is bundled but not in this project's manifest.
  NotInstalled(package: String, bundled: List(String))
  /// There is no manifest to read at the path the command consulted, or its
  /// TOML is malformed, so no package has an installed version to select on.
  NoManifest(path: String)
  /// The catalog directory exists but holds no catalog file.
  EmptyCatalog(directory: String)
  /// None of the paths graded looks for its bundled catalog under exists.
  NoCatalogDirectory(candidates: List(String))
}

pub fn main() -> Nil {
  set_binary_heap_allowance(binary_heap_allowance)
  case argv.load().arguments {
    [] -> run_check("src")

    ["--help", ..] | ["-h", ..] | ["help", ..] -> io.println(usage_text())

    ["--version", ..] -> io.println("graded " <> version())

    ["format", "--stdin"] ->
      case read_stdin() {
        // The read failure has no meaning to a library consumer — this is the
        // only caller — so it is reported here rather than through a new
        // `GradedError` variant.
        Error(reason) -> {
          io.println_error("graded: error: " <> reason)
          halt(1)
        }
        Ok(input) ->
          case run_format_stdin(input) {
            Ok(output) -> io.print(output)
            Error(GradedParseError(message:, ..)) -> {
              io.println_error(
                "graded: error: parse error in stdin:" <> message,
              )
              halt(1)
            }
            Error(error) -> fail(error)
          }
      }

    ["format", "--check", ..rest] ->
      with_directory(rest, fn(directory) {
        case run_format_check(directory) {
          Ok(Nil) -> Nil
          Error(error) -> fail(error)
        }
      })

    ["format", ..rest] ->
      with_directory(rest, fn(directory) {
        case run_format(directory) {
          Ok(Nil) -> Nil
          Error(error) -> fail(error)
        }
      })

    ["infer", ..rest] ->
      report(cli.parse_infer_args(rest), fn(arguments) {
        let #(directory, mode) = arguments
        run_infer_command(mode, directory)
      })

    ["check", ..rest] -> with_directory(rest, run_check)

    ["pack", ..rest] -> with_directory(rest, pack_and_report)

    ["effect", ..rest] ->
      report(cli.parse_effect_args(rest), fn(arguments) {
        let #(name, directory, format) = arguments
        // The decoder already answers in the renderer's own vocabulary, so
        // the CLI takes the internal path rather than converting twice.
        effect_answer(directory, name)
        |> result.map(answer.render(_, format))
      })

    ["why", ..rest] ->
      report(cli.parse_why_args(rest), fn(arguments) {
        let #(name, directory) = arguments
        run_why(directory, name)
      })

    ["catalog", ..rest] -> report(cli.parse_catalog_args(rest), run_catalog)

    ["coverage", ..rest] -> report(cli.parse_directory_args(rest), run_coverage)

    [first] -> dispatch_unknown(first)

    [first, extra, ..] ->
      case string.starts_with(first, "-") {
        True -> usage_error("unknown option `" <> first <> "`")
        False -> usage_error("unexpected argument `" <> extra <> "`")
      }
  }
}

fn pack_and_report(directory: String) -> Nil {
  case pack_project(resolve_package_root(directory)) {
    Ok(message) -> io.println(message)
    Error(error) -> fail(error)
  }
}

// Print an error to stderr and exit non-zero: the shared failure path for
// every command.
fn fail(error: GradedError) -> Nil {
  io.println_error("graded: error: " <> format_error(error))
  halt(1)
}

// Run `command` on decoded arguments and print what it returns, or print the
// usage error the decoder rejected them with: the shared path for every command
// whose output is one string — infer/effect/why.
fn report(
  arguments: Result(a, cli.ArgumentError),
  command: fn(a) -> Result(String, GradedError),
) -> Nil {
  case arguments {
    Error(error) -> usage_error(cli.format_argument_error(error))
    Ok(arguments) ->
      case command(arguments) {
        Ok(output) -> io.println(output)
        Error(error) -> fail(error)
      }
  }
}

// Run `command` with the optional directory argument shared by
// check/infer/format/pack, or print the usage error `cli.parse_directory_args`
// rejected it with.
fn with_directory(rest: List(String), command: fn(String) -> Nil) -> Nil {
  case cli.parse_directory_args(rest) {
    Ok(directory) -> command(directory)
    Error(error) -> usage_error(cli.format_argument_error(error))
  }
}

// A first token that is neither a known command nor a flag: treat an existing
// directory as `check <dir>` (the bare-directory shorthand), and anything else as
// an unknown command — exiting non-zero rather than silently checking a directory
// that isn't there. A new subcommand adds its own branch above this fallback.
fn dispatch_unknown(first: String) -> Nil {
  case string.starts_with(first, "-") {
    True -> usage_error("unknown option `" <> first <> "`")
    False ->
      case simplifile.is_directory(first) {
        Ok(True) -> run_check(first)
        _ -> usage_error("unknown command `" <> first <> "`")
      }
  }
}

fn usage_error(message: String) -> Nil {
  io.println_error("graded: error: " <> message)
  io.println_error("Run `graded --help` for usage.")
  halt(1)
}

fn usage_text() -> String {
  "graded — effect checker for Gleam

Usage:
  graded [check] [directory]    Check effect annotations (default: src)
  graded infer [directory]      Infer effects; write the spec file and cache
  graded infer --dry-run [dir]  Preview spec changes without writing
  graded infer --check [dir]    Fail if inference would change the spec (CI mode)
  graded effect <name> [dir]    Look up a function or type-field effect (read-only)
    --format=prose              Describe the answer in sentences (default)
    --format=graded             Print it as a `.graded` line, provenance in a comment
  graded why <name> [dir]       Explain where a function's effects come from (read-only)
  graded catalog                List the bundled catalog files (read-only)
  graded catalog <pkg> [dir]    Print the catalog file selected for the installed <pkg>
  graded catalog <pkg>@<ver>    Print that bundled version ([dir] accepted); bundled catalog only
  graded coverage [dir]         Report what the type inference could and could not read (read-only)
  graded pack [directory]       Inject the spec into the hex tarball for release
  graded format [directory]     Format the spec file
  graded format --check [dir]   Verify formatting without writing (CI mode)
  graded format --stdin         Format the spec file read from stdin
  graded --help                 Show this help
  graded --version              Show the installed version"
}

// Packing
//
// The `pack` command: inject the configured `.graded` spec into the project's
// hex tarball so it ships to consumers at `build/packages/<dep>/<spec_file>` and
// is found by the existing dependency resolver — no consumer-side code. graded
// patches and rehashes the tarball; the user builds it (`gleam export
// hex-tarball`) and publishes it (via the Hex publish API, never `gleam
// publish`, which rebuilds the tarball and drops the injected file).

/// Inject the configured `.graded` spec into `project_root`'s hex tarball.
/// The archive patched is `build/<name>-<version>.tar` and no other path.
/// Returns a success message (with the publish command), a `GradedParseError`
/// when the spec does not parse — nothing a consumer would read is ever packed
/// — or a `PackError`.
pub fn pack_project(project_root: String) -> Result(String, GradedError) {
  let gleam_toml = filepath.join(project_root, "gleam.toml")

  // The raw (relative) spec path is the archive entry; the resolved path is
  // where the source spec is read from disk. `read_config`/`resolve_path` return
  // the resolved read path, which may be root-prefixed or absolute — wrong for an
  // archive entry — so the two are kept distinct.
  use raw_cfg <- result.try(
    config.read(gleam_toml)
    |> result.map_error(fn(_) {
      PackError(
        "graded pack needs a package with a readable gleam.toml at "
        <> gleam_toml,
      )
    }),
  )
  let entry_name = raw_cfg.spec_file
  let resolved_spec = config.resolve_path(project_root, raw_cfg.spec_file)

  // A spec_file that is absolute or escapes the package root can't be a safe
  // archive-relative entry.
  use _ <- result.try(
    pack.validate_archive_entry(entry_name) |> result.map_error(pack_error),
  )

  // Read through the parser, before the tarball is opened. A spec this version
  // rejects is one every consumer's loader rejects too, so injecting it ships a
  // package whose whole spec reads as no annotations at all. What goes into the
  // archive is the file's own bytes — the entry is the spec verbatim, never a
  // re-render of the parse.
  use spec <- result.try(case read_spec_on_disk(resolved_spec) {
    // No spec and an empty one carry the same instruction: there is nothing to
    // ship yet. `read_spec_on_disk` reads a missing file as no bytes, which
    // every other command treats as a project to infer from scratch and `pack`
    // alone treats as an error. A spec that is there but unreadable, and one
    // that does not parse, travel as themselves — `infer` fixes neither.
    Ok(#("", _)) ->
      Error(PackError(
        "no spec file at " <> resolved_spec <> "; run `graded infer` first",
      ))
    Ok(#(content, _parsed)) -> Ok(content)
    Error(error) -> Error(error)
  })

  use tarball_path <- result.try(
    pack.resolve_tarball(project_root, gleam_toml, raw_cfg)
    |> result.map_error(pack_error),
  )

  use checksum <- result.try(
    pack.patch_tarball(tarball_path, spec, entry_name)
    |> result.map_error(pack_error),
  )

  Ok(pack.success_message(tarball_path, entry_name, checksum))
}

// Render one archive-patching problem as this module's error. Every variant
// but the last is a `PackError` carrying the prose the CLI prints; a rename
// that failed names the OS cause instead, and the verified archive it left
// behind.
fn pack_error(problem: pack.PackProblem) -> GradedError {
  case problem {
    pack.UnsafeSpecEntry(entry:) ->
      PackError(
        "configured spec_file `"
        <> entry
        <> "` must be a relative path inside the package",
      )
    pack.MissingVersion(gleam_toml:) ->
      PackError("no `version` in " <> gleam_toml <> "; add one to publish")
    pack.MissingDefaultTarball(path:, message:) ->
      PackError(
        "could not read "
        <> path
        <> " (run `gleam export hex-tarball` first): "
        <> message,
      )
    pack.WrongTarball(
      path:,
      found:,
      found_version:,
      expected:,
      expected_version:,
    ) ->
      PackError(
        "tarball at "
        <> path
        <> " is "
        <> found
        <> "@"
        <> found_version
        <> ", not the project's "
        <> expected
        <> "@"
        <> expected_version,
      )
    pack.InjectionFailed(tarball:, message:) ->
      PackError("could not patch " <> tarball <> ": " <> message)
    pack.VerificationFailed(message:) ->
      PackError("patched tarball failed verification: " <> message)
    pack.ReplaceFailed(path:, temp: _, cause:) -> FileWriteError(path, cause)
  }
}

// Checking
//
// The `check` command: assemble the knowledge base for the project, run the
// checker over each source file, and collect violations and warnings.

/// What checking one file found, as the lines graded prints for it.
///
/// Both halves, because both are what a caller acts on: the CLI prints the
/// warnings with their count and the violations with theirs, and exits on the
/// violations alone. A count is `list.length` of the list.
pub type ModuleReport {
  ModuleReport(
    /// The source file these results belong to — the spec file, for the
    /// warnings a spec line earns on its own.
    file: String,
    /// One rendered line per warning, in the order graded reports them.
    warnings: List(String),
    /// One rendered line per violation, likewise. A `check` graded could not
    /// prove is reported here too, worded as such: it is not a proof, so the
    /// run must not pass on it.
    violations: List(String),
  )
}

/// Run the checker on all .gleam files in a directory.
///
/// Reads the project's single spec file (default `<package_name>.graded`)
/// to find inferred public-API effects, `check` invariants, `assume`
/// declarations, and field annotations, then reports one `ModuleReport` per
/// source file, plus one for the spec file itself where a spec line is dead.
pub fn run(directory: String) -> Result(List(ModuleReport), GradedError) {
  use #(spec_file, per_target) <- result.map(check_project_targets(directory))
  target_reports(spec_file, per_target)
}

// The `check` results of a run, or of each target's where the package was read
// on several one at a time, as the reports `check` prints.
fn target_reports(
  spec_file: String,
  per_target: List(#(Option(String), List(CheckResult))),
) -> List(ModuleReport) {
  case per_target {
    [#(None, results)] -> list.map(results, module_report)
    _ ->
      joined_reports(
        spec_file,
        list.map(per_target, fn(entry) {
          #(option.unwrap(entry.0, ""), list.map(entry.1, module_report))
        }),
      )
  }
}

// Each target's rendered reports as one per file: every violation once, with
// the targets it holds on; a module's warnings from any target; and a spec-file
// warning only where every target reports it, since a line one target's build
// leaves without a function names one on another.
fn joined_reports(
  spec_file: String,
  per_target: List(#(String, List(ModuleReport))),
) -> List(ModuleReport) {
  let targets = list.length(per_target)
  let #(order, grouped) =
    list.fold(per_target, #([], dict.new()), fn(acc, entry) {
      let #(target, reports) = entry
      list.fold(reports, acc, fn(acc, report) {
        let #(order, grouped) = acc
        let order = case dict.has_key(grouped, report.file) {
          True -> order
          False -> [report.file, ..order]
        }
        #(
          order,
          dict.upsert(grouped, report.file, fn(existing) {
            list.append(option.unwrap(existing, []), [#(target, report)])
          }),
        )
      })
    })
  list.reverse(order)
  |> list.filter_map(fn(file) {
    use reports <- result.map(dict.get(grouped, file))
    let violations =
      list.map(reports, fn(entry) { #(Some(entry.0), { entry.1 }.violations) })
      |> joined_by_target
      |> list.map(fn(entry) {
        entry.0 <> " (on " <> string.join(entry.1, ", ") <> ")"
      })
    // How many targets report each warning.
    let reported =
      checker.holding_counts(
        list.map(reports, fn(entry) { { entry.1 }.warnings }),
      )
    let warnings =
      list.flat_map(reports, fn(entry) { { entry.1 }.warnings })
      |> list.unique
      |> list.filter(fn(line) {
        file != spec_file || dict.get(reported, line) == Ok(targets)
      })
    ModuleReport(file:, warnings:, violations:)
  })
}

// One file's results, rendered exactly as the CLI prints them.
fn module_report(result: CheckResult) -> ModuleReport {
  ModuleReport(
    file: result.file,
    warnings: list.map(result.warnings, checker.format_warning(result.file, _)),
    violations: list.append(
      list.map(result.violations, checker.format_violation(result.file, _)),
      list.map(result.findings, checker.format_finding(result.file, _)),
    ),
  )
}

// Every ambiguous call in the package, classified by graded and by girard and
// the pair compared — `Agree` rows included, so a caller filters rather than
// guesses what was left out. Spec-independent: the pass ignores the annotation
// list, so a module with no `check` line contributes its rows like any other.
@internal
pub fn classification_checks(
  directory: String,
) -> Result(List(types.ClassificationCheck), GradedError) {
  use ctx <- result.map(load_project_context(directory))
  context_classification_checks(ctx)
}

// The same rows off a context already assembled, so the coverage report reads
// what `graded check` computed rather than a second pass over the same source:
// each function's rows from the targets that build it.
fn context_classification_checks(
  ctx: ProjectContext,
) -> List(types.ClassificationCheck) {
  case ctx.per_target {
    [] -> target_classification_checks(ctx)
    contexts ->
      list.flat_map(contexts, fn(entry) {
        target_classification_checks(entry.1)
        |> list.filter(fn(row) {
          reads_on(ctx.builds, row.module <> "." <> row.function, entry.0)
        })
      })
      |> list.unique
  }
}

fn target_classification_checks(
  ctx: ProjectContext,
) -> List(types.ClassificationCheck) {
  let ProjectContext(sources:, type_info:, knowledge_base:, ..) = ctx
  use #(gleam_path, module) <- list.flat_map(sources.parsed)
  let module_path =
    config.module_path_for_source(gleam_path, sources.source_directory)
  checker.classify_module(
    module,
    module_path,
    knowledge_base,
    typeinfo.reading_for_module(type_info, module_path),
    sources.cfg.targets,
  )
}

// The same run, keeping the structured results. `why` and graded's own tests
// read the resolution behind a violation; a caller linking against the module
// gets the rendered form, so the structured types stay free to change.
@internal
pub fn check_project(
  directory: String,
) -> Result(List(CheckResult), GradedError) {
  use #(spec_file, per_target) <- result.map(check_project_targets(directory))
  case per_target {
    [#(_, results)] -> results
    _ ->
      joined_check_results(
        spec_file,
        list.map(per_target, fn(entry) { entry.1 }),
      )
  }
}

// The `check` results of each target the package is read on, where it is read
// on several one at a time, or of its one reading, beside its spec file.
fn check_project_targets(
  directory: String,
) -> Result(#(String, List(#(Option(String), List(CheckResult)))), GradedError) {
  use ctx <- result.try(load_project_context(directory))
  let spec_file = ctx.sources.cfg.spec_file
  let per_target = case ctx.per_target {
    [] -> [#(None, context_check_results(ctx, None))]
    contexts ->
      list.map(contexts, fn(entry) {
        #(entry.0, context_check_results(entry.1, Some(entry.0)))
      })
      |> warnings_on_builders(spec_file, ctx.builds, _)
      |> list.map(fn(entry) { #(Some(entry.0), entry.1) })
  }
  Ok(#(spec_file, per_target))
}

// Each target's results with each spec-file warning about one of the package's
// functions answered by the targets that build it: a target that builds no
// definition of the function, where another does, reports the warning exactly
// where one of those does. A warning every target building its function
// reports is then reported by every target, as the joins keep it.
fn warnings_on_builders(
  spec_file: String,
  builds: PackageBuilds,
  per_target: List(#(String, List(CheckResult))),
) -> List(#(String, List(CheckResult))) {
  use <- bool.guard(when: dict.is_empty(builds.partial), return: per_target)
  let read_on = fn(warning, target) {
    case types.warning_function(warning) {
      Ok(function) -> reads_on(builds, function, target)
      Error(Nil) -> True
    }
  }
  let spec_warnings = fn(results: List(CheckResult)) {
    list.flat_map(results, fn(result) {
      case result.file == spec_file {
        True -> result.warnings
        False -> []
      }
    })
  }
  // What the targets building each warning's function report.
  let built =
    list.flat_map(per_target, fn(entry) {
      list.filter(spec_warnings(entry.1), read_on(_, entry.0))
    })
    |> list.unique
  let built_set = set.from_list(built)
  list.map(per_target, fn(entry) {
    let #(target, results) = entry
    let kept =
      list.filter(spec_warnings(results), fn(warning) {
        read_on(warning, target) || set.contains(built_set, warning)
      })
    let kept_set = set.from_list(kept)
    let answered =
      list.filter(built, fn(warning) {
        !read_on(warning, target) && !set.contains(kept_set, warning)
      })
    let warnings = list.append(kept, answered)
    #(target, case list.any(results, fn(result) { result.file == spec_file }) {
      True ->
        list.map(results, fn(result) {
          case result.file == spec_file {
            True -> CheckResult(..result, warnings:)
            False -> result
          }
        })
      False ->
        case warnings {
          [] -> results
          warnings -> [
            CheckResult(
              file: spec_file,
              violations: [],
              findings: [],
              warnings:,
            ),
            ..results
          ]
        }
    })
  })
}

// `spec` without the `effects` lines over names the package defines once per
// target.
fn without_per_target_lines(
  spec: GradedFile,
  pairs: PackagePairs,
) -> GradedFile {
  GradedFile(
    lines: list.filter(spec.lines, fn(line) {
      case line {
        AnnotationLine(annotation: ann, ..) if ann.kind == types.Effects ->
          result.is_error(pair_of(pairs, ann.function))
        _ -> True
      }
    }),
  )
}

// Each module's functions defined once per target, by module path and by
// source file, read once for the package's runs on its targets.
type PackagePairs {
  PackagePairs(
    by_module: Dict(
      String,
      Dict(String, List(glance.Definition(glance.Function))),
    ),
    by_file: Dict(
      String,
      Dict(String, List(glance.Definition(glance.Function))),
    ),
  )
}

fn package_pairs(
  index: Dict(String, #(String, glance.Module)),
) -> PackagePairs {
  let by_module =
    dict.map_values(index, fn(_module_path, entry) {
      checker.module_pairs(entry.1)
    })
  PackagePairs(
    by_module:,
    by_file: dict.fold(index, dict.new(), fn(acc, module_path, entry) {
      case dict.get(by_module, module_path) {
        Ok(pairs) -> dict.insert(acc, entry.0, pairs)
        Error(Nil) -> acc
      }
    }),
  )
}

fn no_package_pairs() -> PackagePairs {
  PackagePairs(by_module: dict.new(), by_file: dict.new())
}

// The definitions of the function `name` qualifies, where a module of the
// package defines it once per target.
fn pair_of(
  pairs: PackagePairs,
  name: String,
) -> Result(List(glance.Definition(glance.Function)), Nil) {
  use #(module_path, function) <- result.try(annotation.split_function_name(
    name,
  ))
  use module_pairs <- result.try(dict.get(pairs.by_module, module_path))
  dict.get(module_pairs, function)
}

// The targets of a run on several, and which of them build each of the
// package's own functions, by module path and name: read once for the run, and
// read by everything that joins a function's results across its targets.
type PackageBuilds {
  PackageBuilds(
    targets: List(String),
    functions: Dict(String, Dict(String, FunctionBuilds)),
    // The functions some of the run's targets build and others do not, by
    // qualified name, beside the targets that build each.
    partial: Dict(String, List(String)),
  )
}

// One function of the package: every definition in source order, and the
// definition each target of the run that builds one builds.
type FunctionBuilds {
  FunctionBuilds(
    variants: List(glance.Definition(glance.Function)),
    built: List(#(String, glance.Definition(glance.Function))),
  )
}

fn package_builds(
  index: Dict(String, #(String, glance.Module)),
  targets: List(String),
) -> PackageBuilds {
  let functions =
    dict.map_values(index, fn(_module_path, entry) {
      checker.module_definitions(entry.1)
      |> dict.map_values(fn(_name, variants) {
        FunctionBuilds(
          variants:,
          built: extract.built_variants(variants, targets),
        )
      })
    })
  let count = list.length(targets)
  PackageBuilds(
    targets:,
    functions:,
    partial: dict.fold(functions, dict.new(), fn(acc, module_path, by_name) {
      dict.fold(by_name, acc, fn(acc, name, one) {
        case partial_readers(one, count) {
          Ok(readers) -> dict.insert(acc, module_path <> "." <> name, readers)
          Error(Nil) -> acc
        }
      })
    }),
  )
}

// The targets that build `one`, where some of the run's `count` targets build
// it and others do not.
fn partial_readers(
  one: FunctionBuilds,
  count: Int,
) -> Result(List(String), Nil) {
  let readers = list.map(one.built, fn(entry) { entry.0 })
  case readers != [] && list.length(readers) < count {
    True -> Ok(readers)
    False -> Error(Nil)
  }
}

fn no_package_builds() -> PackageBuilds {
  PackageBuilds(targets: [], functions: dict.new(), partial: dict.new())
}

// The package's own function `name`, as the run's targets build it.
fn function_builds(
  builds: PackageBuilds,
  name: String,
) -> Result(FunctionBuilds, Nil) {
  use #(module_path, function) <- result.try(annotation.split_function_name(
    name,
  ))
  use by_name <- result.try(dict.get(builds.functions, module_path))
  dict.get(by_name, function)
}

// Whether the run reads the package's function `name` on `target`: where one
// of its targets builds the function, on those that do; where none does, or
// `name` is not one of the package's functions, on every target.
fn reads_on(builds: PackageBuilds, name: String, target: String) -> Bool {
  case dict.get(builds.partial, name) {
    Ok(readers) -> list.contains(readers, target)
    Error(Nil) -> True
  }
}

// The targets of the run that read a line over `path`: those that build the
// function it names, the package's own or a dependency's, where any does;
// every target otherwise.
fn line_builders(
  builds: PackageBuilds,
  dependencies: DependencySources,
  path: String,
) -> List(String) {
  let built = case function_builds(builds, path) {
    Ok(one) -> list.map(one.built, fn(entry) { entry.0 })
    Error(Nil) -> dependency_builders(builds.targets, dependencies, path)
  }
  case built {
    [] -> builds.targets
    built -> built
  }
}

// The `targets` that build the dependency function `path`, where some
// definition of it is kept on some targets alone; none otherwise.
fn dependency_builders(
  targets: List(String),
  dependencies: DependencySources,
  path: String,
) -> List(String) {
  {
    use #(module_path, function) <- result.try(annotation.split_function_name(
      path,
    ))
    use scanned <- result.try(dict.get(dependencies.modules, module_path))
    use variants <- result.map(case scanned {
      ParsedModule(gated:, ..) -> dict.get(gated, function)
      UnreadableModule -> Error(Nil)
    })
    list.filter(targets, fn(target) {
      result.is_ok(built_variant(variants, target))
    })
  }
  |> result.unwrap([])
}

// Whether a run on `package_targets`, one of several, reads a line over
// `path`.
fn reads_line_on(
  builds: PackageBuilds,
  dependencies: DependencySources,
  path: String,
  package_targets: types.PackageTargets,
) -> Bool {
  let reading = types.build_targets(package_targets)
  list.any(line_builders(builds, dependencies, path), set.contains(reading, _))
}

// One function's lines from several targets as one: each line of a target
// that builds it, read over the published parameters of its definitions;
// `first` where no target of the run builds it.
fn joined_built_line(
  one: FunctionBuilds,
  first: EffectAnnotation,
  lines: List(#(String, EffectAnnotation)),
) -> EffectAnnotation {
  list.filter_map(lines, fn(entry) {
    list.key_find(one.built, entry.0)
    |> result.map(fn(definition) { #(definition, entry.1) })
  })
  |> checker.joined_target_line(one.variants, _)
  |> result.unwrap(first)
}

// `spec` as `target` reads it: without the `check` lines over a function it
// builds no definition of where another target of the run builds one, and with
// each over a name the package defines once per target read in the parameter
// names of the definition built on `target`.
fn spec_on_target(
  spec: GradedFile,
  pairs: PackagePairs,
  builds: PackageBuilds,
  target: String,
) -> GradedFile {
  let lines = case dict.is_empty(builds.partial) {
    True -> spec.lines
    False ->
      list.filter(spec.lines, fn(line) {
        case line {
          AnnotationLine(annotation: ann, ..) if ann.kind == types.Check ->
            reads_on(builds, ann.function, target)
          _ -> True
        }
      })
  }
  GradedFile(
    lines: list.map(lines, fn(line) {
      case line {
        AnnotationLine(annotation: ann, ..) if ann.kind == types.Check ->
          {
            use #(module_path, function) <- result.try(
              annotation.split_function_name(ann.function),
            )
            use module_pairs <- result.try(dict.get(
              pairs.by_module,
              module_path,
            ))
            use #(variants, definition) <- result.map(checker.pair_variant(
              module_pairs,
              function,
              target,
            ))
            AnnotationLine(
              ..line,
              annotation: checker.in_variant_names(variants, definition, ann),
            )
          }
          |> result.unwrap(line)
        _ -> line
      }
    }),
  )
}

// What each module's `check` lines found on `target`, about names the package
// defines once per target, stated in their published parameter names.
fn in_published_names(
  results: List(CheckResult),
  pairs: PackagePairs,
  target: String,
) -> List(CheckResult) {
  list.map(results, fn(result) {
    case dict.get(pairs.by_file, result.file) {
      Error(Nil) -> result
      Ok(pairs) ->
        CheckResult(
          ..result,
          violations: list.map(result.violations, fn(violation) {
            case checker.pair_variant(pairs, violation.function, target) {
              Ok(#(variants, definition)) ->
                checker.violation_in_published_names(
                  variants,
                  definition,
                  violation,
                )
              Error(Nil) -> violation
            }
          }),
          findings: list.map(result.findings, finding_in_published_names(
            pairs,
            target,
            _,
          )),
        )
    }
  })
}

// A finding about a name a module defines once per target, one of its
// `pairs`, stated in its published parameter names.
fn finding_in_published_names(
  pairs: Dict(String, List(glance.Definition(glance.Function))),
  target: String,
  finding: types.CheckFinding,
) -> types.CheckFinding {
  {
    use function <- result.try(case finding {
      types.ReturnsClauseViolation(function:, ..)
      | types.NonCallableReturnViolation(function:, ..) -> Ok(function)
      _ -> Error(Nil)
    })
    use #(variants, definition) <- result.map(checker.pair_variant(
      pairs,
      function,
      target,
    ))
    checker.finding_in_published_names(variants, definition, finding)
  }
  |> result.unwrap(finding)
}

// Each target's structured results as one per file: every violation and
// finding any target reports, a module's warnings from any target, and a
// spec-file warning only where every target reports it.
fn joined_check_results(
  spec_file: String,
  per_target: List(List(CheckResult)),
) -> List(CheckResult) {
  let targets = list.length(per_target)
  let #(order, grouped) =
    list.fold(list.flatten(per_target), #([], dict.new()), fn(acc, result) {
      let #(order, grouped) = acc
      let order = case dict.has_key(grouped, result.file) {
        True -> order
        False -> [result.file, ..order]
      }
      #(
        order,
        dict.upsert(grouped, result.file, fn(existing) {
          list.append(option.unwrap(existing, []), [result])
        }),
      )
    })
  list.reverse(order)
  |> list.filter_map(fn(file) {
    use results <- result.map(dict.get(grouped, file))
    // How many targets report each warning.
    let reported =
      checker.holding_counts(list.map(results, fn(one) { one.warnings }))
    CheckResult(
      file:,
      violations: list.flat_map(results, fn(one) { one.violations })
        |> list.unique,
      findings: list.flat_map(results, fn(one) { one.findings }) |> list.unique,
      warnings: list.flat_map(results, fn(one) { one.warnings })
        |> list.unique
        |> list.filter(fn(warning) {
          file != spec_file || dict.get(reported, warning) == Ok(targets)
        }),
    )
  })
}

// `target` is the one target `ctx` reads, where the package is read on several
// one at a time: each `check` line over a name defined once per target is then
// read in the parameter names of the definition built there, and what it finds
// is stated in the published ones.
fn context_check_results(
  ctx: ProjectContext,
  target: Option(String),
) -> List(CheckResult) {
  let ProjectContext(sources:, registry:, type_info:, knowledge_base:, ..) = ctx
  let ProjectSources(
    source_directory: directory,
    reported_directory:,
    cfg:,
    spec:,
    parsed:,
    ..,
  ) = sources
  // Every module of the package was analysed, so a call out of the asked-about
  // subtree resolved against the real callee and each module kept the path its
  // `check` lines name. Only the results are narrowed back to what was asked.
  let reported = case reported_directory == directory {
    True -> parsed
    False ->
      list.filter(parsed, fn(entry) {
        within_directory(reported_directory, entry.0)
      })
  }

  let #(results, field_report) =
    check_modules(
      case target {
        Some(target) ->
          spec_on_target(spec, ctx.package_pairs, ctx.builds, target)
        None -> spec
      },
      parsed,
      reported,
      directory,
      ctx.field_index,
      knowledge_base,
      registry,
      type_info,
      cfg.targets,
    )

  // Spec-level lint: `check`/field `assume` lines whose target doesn't exist in any
  // project module. These silently do nothing (a vacuous check, or a field
  // annotation that resolves to [Unknown]), so they're reported against the
  // spec file itself rather than any source file.
  let results = case target {
    Some(target) -> in_published_names(results, ctx.package_pairs, target)
    None -> results
  }
  let spec_warnings =
    list.append(lint.run(lint_context(ctx)), field_report.warnings)
  case spec_warnings, field_report.spec_findings {
    [], [] -> results
    warnings, findings -> [
      CheckResult(file: cfg.spec_file, violations: [], findings:, warnings:),
      ..results
    ]
  }
}

// The `check` results of `modules`, each with the field findings it earned,
// and the field pass behind them. A field `check` is package-wide: a type's
// construction sites are wherever the package builds it, so the pass runs over
// every module in `parsed` and its findings are grouped back onto the file
// that earned each one.
fn check_modules(
  spec: GradedFile,
  parsed: List(#(String, glance.Module)),
  modules: List(#(String, glance.Module)),
  directory: String,
  field_index: types.FieldIndex,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  type_info: typeinfo.TypeInfo,
  package_targets: types.PackageTargets,
) -> #(List(CheckResult), FieldCheckResults) {
  let #(field_checks, function_checks) =
    list.partition(annotation.extract_checks(spec), fn(ann) {
      annotation.is_field_path(ann.function)
    })
  let checks_by_module = checks_grouped_by_module(function_checks)
  let field_report =
    field_check_results(
      field_checks,
      parsed,
      directory,
      field_index,
      knowledge_base,
      registry,
      type_info,
      package_targets,
    )
  let results =
    list.map(modules, fn(entry) {
      let #(gleam_path, module) = entry
      let module_path = config.module_path_for_source(gleam_path, directory)
      let module_checks = case dict.get(checks_by_module, module_path) {
        Ok(list) -> list
        Error(_) -> []
      }
      let result =
        check_one_file(
          gleam_path,
          module_path,
          module,
          module_checks,
          knowledge_base,
          registry,
          typeinfo.reading_for_module(type_info, module_path),
          package_targets,
        )
      case dict.get(field_report.findings, gleam_path) {
        Ok(findings) ->
          CheckResult(
            ..result,
            findings: list.append(result.findings, findings),
          )
        Error(Nil) -> result
      }
    })
  #(results, field_report)
}

// Field checks
//
// A field `check` names a type by the module that defines it and is proved by
// the construction sites the package holds, which are anywhere in it. The pass
// is package-wide for that reason and its findings are grouped by the file
// whose sites earned them, so a scoped run reports what it was asked about.
//
// What it proves is this package's own sites. A public constructor or factory
// can be called from outside, and no package-local pass sees those calls.

// The field pass's results: findings by constructing file, findings the spec
// line earns on its own, and the spec-file warnings.
type FieldCheckResults {
  FieldCheckResults(
    findings: Dict(String, List(types.CheckFinding)),
    spec_findings: List(types.CheckFinding),
    warnings: List(types.Warning),
  )
}

fn field_check_results(
  field_checks: List(EffectAnnotation),
  parsed: List(#(String, glance.Module)),
  directory: String,
  field_index: types.FieldIndex,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  type_info: typeinfo.TypeInfo,
  package_targets: types.PackageTargets,
) -> FieldCheckResults {
  // A shape nothing gives a meaning is rejected on the violations channel, not
  // merely linted: a warning exits zero, and a line that was never proved must
  // not pass. Which components a field head does not support is the lint's
  // rule, read from there so the warning and the finding cannot drift.
  let unsupported =
    list.flat_map(field_checks, fn(ann) {
      lint.unsupported_field_components(ann)
      |> list.map(unsupported_field_finding(ann.function, _))
    })
  // A bound list is what scopes the effects term, so a line carrying one is not
  // weighed at all; a `where returns` clause leaves the budget on the same line
  // supported, so that line still is.
  let weighable = list.filter(field_checks, fn(ann) { ann.params == [] })
  let #(checks, unmatched) = resolve_field_checks(weighable, field_index)
  use <- bool.lazy_guard(when: checks == [], return: fn() {
    FieldCheckResults(
      findings: dict.new(),
      spec_findings: unsupported,
      warnings: unmatched,
    )
  })
  let reports =
    list.map(parsed, fn(entry) {
      let #(gleam_path, module) = entry
      let module_path = config.module_path_for_source(gleam_path, directory)
      #(
        gleam_path,
        checker.check_field_sites(
          module,
          module_path,
          checks,
          field_index,
          knowledge_base,
          registry,
          typeinfo.reading_for_module(type_info, module_path),
          package_targets,
        ),
      )
    })
  // What every module together saw: which templates something called, and which
  // checks any site at all answered. Both are meaningless per module.
  let #(called, touched) =
    list.fold(reports, #(set.new(), set.new()), fn(acc, entry) {
      let #(called, touched) = acc
      let #(_gleam_path, report) = entry
      #(set.union(called, report.called), set.union(touched, report.touched))
    })
  // A template whose field is wired from one of its own parameters proves
  // nothing on its own: what it wires is whatever its callers pass. One no
  // visible call reaches is an analysis limit, reported as one.
  let findings =
    list.fold(reports, dict.new(), fn(acc, entry) {
      let #(gleam_path, report) = entry
      let uncalled =
        report.templates
        |> list.filter(fn(template) { !set.contains(called, template.function) })
        |> list.map(fn(template) {
          types.UnprovedCheck(
            subject: template.check_path,
            cause: types.UncalledFactory(factory: template.function),
            site: Some(template.site),
          )
        })
      case list.append(report.findings, uncalled) {
        [] -> acc
        found -> dict.insert(acc, gleam_path, found)
      }
    })
  // A check no site anywhere in the package answered holds vacuously, which is
  // not a proof. Counted over every module, so a scoped run does not report it.
  let unconstructed =
    checks
    |> list.filter(fn(check) { !set.contains(touched, check.path) })
    |> list.map(fn(check) {
      types.UnconstructedFieldCheckWarning(name: check.path)
    })
    |> list.unique()
  FieldCheckResults(
    findings:,
    spec_findings: unsupported,
    warnings: list.append(unmatched, unconstructed),
  )
}

fn unsupported_field_finding(
  path: String,
  component: types.CheckComponent,
) -> types.CheckFinding {
  types.UnprovedCheck(
    subject: path,
    cause: types.UnsupportedCheckComponent(component:),
    site: None,
  )
}

// Resolve each field `check` line to the type it names, and warn about the
// lines that name none. A qualified path names its type's defining module; an
// unqualified one is resolved against every module defining a type of that
// name, since the line has no other way to say which.
fn resolve_field_checks(
  field_checks: List(EffectAnnotation),
  field_index: types.FieldIndex,
) -> #(List(checker.FieldCheck), List(types.Warning)) {
  let callable_labels =
    field_index.callable
    |> dict.keys()
    |> list.map(fn(key) {
      let #(module, type_name, _variant, field) = key
      #(module, type_name, field)
    })
    |> set.from_list()
  // Read once for the lines that name no module.
  let labelled = checker.labels_by_type_field(field_index.labels)
  let #(chunks, warnings) =
    list.fold(field_checks, #([], []), fn(acc, ann) {
      let #(checks, warnings) = acc
      let targets = case annotation.split_type_field_name(ann.function) {
        Error(Nil) -> []
        Ok(#(Some(module), type_name, field)) ->
          case set.contains(field_index.labels, #(module, type_name, field)) {
            True -> [#(module, type_name, field)]
            False -> []
          }
        Ok(#(None, type_name, field)) -> labelled(type_name, field)
      }
      let declared = list.filter(targets, set.contains(callable_labels, _))
      case targets, declared {
        [], _ -> #(checks, [
          types.UnmatchedFieldCheckWarning(name: ann.function),
          ..warnings
        ])
        _, [] -> #(checks, [
          types.NonCallableFieldCheckWarning(name: ann.function),
          ..warnings
        ])
        _, declared -> #(
          [
            list.map(declared, fn(target) {
              let #(module, type_name, field) = target
              checker.FieldCheck(
                path: ann.function,
                module:,
                type_name:,
                field:,
                declared: ann.effects,
              )
            }),
            ..checks
          ],
          warnings,
        )
      }
    })
  #(list.reverse(chunks) |> list.flatten, warnings)
}

// Everything a read-only command needs about a project: the parsed sources, the
// indexes derived from them, and the assembled knowledge base. Built by
// `load_project_context`, which writes nothing — `check` and `effect` share it.
type ProjectContext {
  ProjectContext(
    // The parse stage this context was built from, held whole rather than
    // copied field by field, so a new project input is declared once.
    sources: ProjectSources,
    registry: SignatureRegistry,
    type_info: typeinfo.TypeInfo,
    // The per-function `assume` lines that declare nothing, because
    // they name one of this package's own Gleam-bodied functions. Decided once
    // here: the knowledge base is assembled without them, and the spec lint
    // reports them, so the two can't disagree about which lines are live.
    stale_assumes: Set(String),
    // The same about the `where returns` clauses, on the value channel. Two
    // sets rather than one: each suppresses only its own channel's lines, and
    // each is reported by its own warning.
    stale_returns_clauses: Set(String),
    knowledge_base: KnowledgeBase,
    // The bundled catalog this context was assembled against. Held rather than
    // re-read by the spec lint, which weighs the same entries the knowledge
    // base was built from.
    catalog: effects.BundledCatalog,
    // The dependency scan this context was assembled from. Held for the spec
    // lint, which decides whether a dependency module defines the name an
    // `assume` line gives it — a question this walk already parsed
    // every dependency module to answer for the registry.
    dependencies: DependencySources,
    // What this package's own modules and its dependencies' say about their
    // custom types' record fields. A field `check` is package-wide and reaches
    // a dependency-defined type, so what it measures a site against is
    // gathered package-wide too.
    field_index: types.FieldIndex,
    // Module path -> source file for the whole dependency tree, walked once
    // when this context was assembled (girard's resolver reads it) and held so
    // the spec lint weighs its declaring lines against the same scan rather
    // than repeating the walk.
    dep_files: Dict(String, String),
    // The packages the dependency tree holds, discovered once when this
    // context was assembled.
    local_packages: LocalPackages,
    // Module path -> source file for every module the spec lint may place: the
    // dependency scan above, and every other local package's `src/`.
    placement_files: Dict(String, String),
    // What the inference read of each path dependency it typed, in declaration
    // order, counted where it was read. Observational, and the coverage report
    // is the only reader: a dependency installed from hex is not typed and is
    // not here. The counts are kept rather than the readings they came from,
    // which every command would otherwise hold for its whole run.
    typed_path_dependencies: List(coverage.PathDependency),
    // How a line over a function a dependency defines once per target is read
    // in this run, built once for it.
    pair_readings: Dict(#(String, String), PairReading),
    // The targets each dependency package defining a public function once per
    // target publishes for, by package root, read once for the run.
    publishers: Dict(String, types.PackageTargets),
    // Each of the package's modules' functions defined once per target, read
    // once for its runs on several targets; empty for a run on one.
    package_pairs: PackagePairs,
    // Which of the run's targets build each of the package's functions, read
    // once for its runs on several targets; empty for a run on one.
    builds: PackageBuilds,
    // Each target's own context, where the package was read on several targets
    // one at a time; empty otherwise.
    per_target: List(#(String, ProjectContext)),
    // The girard runs those contexts shared, by target and module.
    girard_runs: GirardRuns,
  )
}

// A project's own inputs: the config, the spec and every source file parsed.
// The parse stage of a context, split out because a caller that only has to
// decide whether a name exists needs this and nothing that follows it.
type ProjectSources {
  ProjectSources(
    // The analysed directory, not the caller's raw argument: module paths derive
    // from it, so it travels with the rest of the context.
    source_directory: String,
    // The subtree the caller asked about, which the analysed directory may be
    // wider than. Results outside it are analysed and not reported.
    reported_directory: String,
    cfg: config.GradedConfig,
    spec: GradedFile,
    parsed: List(#(String, glance.Module)),
    index: Dict(String, #(String, glance.Module)),
    package_root: String,
    // The spec file's text as read, for a message pointing at one of its lines.
    spec_text: String,
  )
}

// Read the config and spec and parse every source file. Touches no dependency,
// runs no inference: the cheap half of `load_project_context`.
fn load_project_sources(
  directory: String,
) -> Result(ProjectSources, GradedError) {
  let SourceScope(analysed: directory, reported:) = source_scope(directory)
  use cfg <- result.try(read_config(directory))
  let package_root = resolve_package_root(directory)
  use #(spec_text, spec) <- result.try(read_spec_on_disk(cfg.spec_file))
  use gleam_files <- result.try(find_gleam_files(directory))
  use parsed <- result.map(parse_all_files(gleam_files))
  let index = build_module_index(parsed, directory)
  ProjectSources(
    source_directory: directory,
    reported_directory: reported,
    cfg:,
    spec:,
    parsed:,
    index:,
    package_root:,
    spec_text:,
  )
}

// Assemble a project's knowledge base without writing anything: read the config
// and spec, parse every source file, scan dependency sources, run girard, and
// fold the spec, dependencies, catalog, and an in-memory inference pass into one
// knowledge base.
fn load_project_context(
  directory: String,
) -> Result(ProjectContext, GradedError) {
  use sources <- result.try(load_project_sources(directory))
  project_context(sources)
}

fn project_context(
  sources: ProjectSources,
) -> Result(ProjectContext, GradedError) {
  let #(targets, shared) =
    target_split(sources.source_directory, sources.cfg, sources.index)
  case targets {
    [] -> {
      use #(base, _shared) <- result.map(context_base(sources, shared, False))
      context_on(base, sources.cfg.targets)
    }
    [first, ..rest] -> {
      let on = fn(target, shared) {
        let sources =
          ProjectSources(..sources, cfg: on_target(sources.cfg, target))
        use #(base, shared) <- result.map(context_base(sources, shared, True))
        #(
          #(target, context_on(base, sources.cfg.targets)),
          #(target, base.refused),
          shared,
        )
      }
      use #(lead, lead_refused, shared) <- result.try(on(first, shared))
      use #(others, refused, _shared) <- result.try(
        list.try_fold(rest, #([], [lead_refused], shared), fn(acc, target) {
          let #(others, refused, shared) = acc
          use #(context, one, shared) <- result.map(on(target, shared))
          #([context, ..others], [one, ..refused], shared)
        }),
      )
      use Nil <- result.map(
        settle_own_refusals(
          sources.cfg.spec_file,
          list.reverse(refused),
          line_builders(shared.builds, { lead.1 }.dependencies, _),
        ),
      )
      ProjectContext(..lead.1, sources:, per_target: [
        lead,
        ..list.reverse(others)
      ])
    }
  }
}

// The targets a run analyses its package on one at a time, each as a run built
// for that target alone would, beside what those runs share. Every target the
// package names, where it names more than one and the package or a local
// package in its tree defines a name once per target, or a dependency it reads
// defines a public function once per target; none otherwise.
fn target_split(
  directory: String,
  cfg: config.GradedConfig,
  index: Dict(String, #(String, glance.Module)),
) -> #(List(String), Shared) {
  let named = named_targets(cfg)
  let shared = Shared(..no_sharing(), index: Some(index))
  use <- bool.guard(when: list.length(named) < 2, return: #([], shared))
  let package_root = resolve_package_root(directory)
  let local = package_tree.discover(package_root)
  let #(parsed, parsed_dirs) = parsed_dependency_sources(package_root, local)
  // Compared in one spelling: a declaration may name the same directory
  // relatively or absolutely, through `.` and `..`.
  let working = working_directory()
  let local_dirs = package_tree.source_directories(local, working)
  let split =
    list.any(dict.values(index), fn(entry) {
      checker.defines_per_target(entry.1)
    })
    || list.any(dict.to_list(parsed), fn(entry) {
      case entry {
        #(path, Ok(module)) ->
          case package_tree.under_source_directory(path, local_dirs, working) {
            True -> checker.defines_per_target(module)
            False ->
              checker.defines_public_function_per_target(module)
              || defines_function_capable_type_per_target(path, module, named)
          }
        #(_path, Error(Nil)) -> False
      }
    })
  let shared = Shared(..shared, parsed:, parsed_dirs:)
  case split {
    False -> #([], shared)
    True -> {
      let dep_files = tree_module_files(package_root, local)
      #(
        named,
        Shared(
          ..shared,
          girard: shared_girard_runs(index, dep_files, named),
          scanned: target_blind_scan(package_root, local, parsed, parsed_dirs),
          tree: Some(#(local, dep_files)),
          builds: package_builds(index, named),
          split: True,
        ),
      )
    }
  }
}

// Whether `module`, keyed `module_path`, defines a type once per target where
// a definition may hold a function value on one of `targets`, read against the
// module's own definitions on that target alone. A type no definition of which
// may hold one carries nothing on any target.
fn defines_function_capable_type_per_target(
  module_path: String,
  module: glance.Module,
  targets: List(String),
) -> Bool {
  let names =
    list.append(
      list.map(module.type_aliases, fn(definition) {
        definition.definition.name
      }),
      list.map(module.custom_types, fn(definition) {
        definition.definition.name
      }),
    )
  let paired = checker.written_more_than_once(names)
  use <- bool.guard(when: paired == [], return: False)
  list.any(targets, fn(target) {
    let registry =
      typedefs.from_module(module_path, module, set.from_list([target]))
    let function_free = typedefs.function_free_in(registry)
    list.any(paired, fn(name) {
      let key = #(module_path, name)
      typedefs.defines(registry, key) && !function_free(key)
    })
  })
}

// What a context holds before the walk of the package's own modules, save the
// layers that read which of its functions are foreign code and what its
// factories build, which `context_on` adds for the targets it is read on.
type ContextBase {
  ContextBase(
    context: ProjectContext,
    constructors: Dict(#(String, String), List(Option(String))),
    declared_modules: Set(String),
    // The project's own lines this run refused, where it is one of several.
    refused: List(OwnViolation),
  )
}

// `base` read on `package_targets`: the package's own foreign functions and
// factories, and its modules inferred in memory.
fn context_on(
  base: ContextBase,
  package_targets: types.PackageTargets,
) -> ProjectContext {
  let context = base.context
  let ProjectContext(registry:, type_info:, ..) = context
  let index = context.sources.index
  let knowledge_base =
    context.knowledge_base
    |> effects.with_package_targets(package_targets)
    // Recorded before the inference pass below, so an `@external` resolves to
    // what declares it while this project's own modules are being inferred, not
    // only when they are later checked.
    |> effects.with_foreign_functions(project_foreign_functions(
      index,
      package_targets,
    ))
    // Before the inference pass, not after it, and in the order `infer` folds
    // them: a body walked during inference resolves its field calls through the
    // same factory signatures a body walked at check time does — the field
    // `assume` lines they read beside these fold earlier still, above.
    // Installed afterwards, the pass ran without them and a function whose
    // effects it settled — an `@external`'s running fallback, whose callers
    // read the summary and never the body — kept an answer the two commands
    // would then disagree about.
    //
    // After `with_builders` folded the dependencies' factories, since this
    // merges rather than replaces and the later fold wins: this package's own
    // modules answer for a path a dependency also claims.
    |> with_project_factories(index, package_targets, base.constructors)
    // Fill gaps for project modules not (yet) in the spec by inferring them in
    // memory, so `check` resolves cross-module calls without a prior `graded
    // infer`. Committed effects are never overridden; fresh returns win over
    // committed clauses. Nothing is written to disk.
    |> infer_project_in_memory(
      index,
      registry,
      type_info,
      base.declared_modules,
      package_targets,
    )
  ProjectContext(
    ..context,
    sources: ProjectSources(
      ..context.sources,
      cfg: config.GradedConfig(..context.sources.cfg, targets: package_targets),
    ),
    registry:,
    type_info:,
    knowledge_base:,
    per_target: [],
  )
}

// The expensive half: everything a context holds beyond the parsed sources.
// Fails before any of it is built when graded's bundled catalog can't be read.
// `per_target` where the context is one of several, each read on one target:
// a committed `effects` line over a name the package defines once per target
// is then the join of every target's answer, and each target's walk answers
// for that name instead.
fn context_base(
  sources: ProjectSources,
  shared: Shared,
  per_target: Bool,
) -> Result(#(ContextBase, Shared), GradedError) {
  let ProjectSources(cfg:, spec:, index:, package_root:, spec_text:, ..) =
    sources
  // Parsed first, and read once the signatures can weigh its lines.
  use parsed_catalog <- result.try(shared_catalog(shared, package_root))
  let declared_modules = annotation.module_assume_modules(spec)
  // The package's targets under both readings, which together decide whether a
  // function is foreign code or the Gleam body is its only implementation, and
  // whether a fallback body beside a declaration runs. One value for the whole
  // run, this package and its dependencies alike: a dependency is compiled for
  // the consumer's target, not its own.
  let package_targets = cfg.targets
  // Read once for the package's runs on its targets, which share it.
  let package_pairs = case per_target, shared.pairs {
    False, _ -> no_package_pairs()
    True, Some(pairs) -> pairs
    True, None -> package_pairs(index)
  }
  let committed = case per_target {
    True -> without_per_target_lines(spec, package_pairs)
    False -> spec
  }
  let native_of = native_functions_of(index, package_targets)
  let stale_assumes = stale_project_assumes(spec, native_of)
  let stale_returns_clauses = stale_project_assume_returns(spec, native_of)
  // Walked once for the run, and handed to everything that reads the tree:
  // girard's resolver reads its module files, and every spec-less path
  // dependency below is typed against the same map.
  let #(local, dep_files) = shared_tree(shared, package_root)
  let scan =
    dependency_scan(
      package_root,
      local,
      package_targets,
      ParsedTree(files: shared.parsed, dirs: shared.parsed_dirs),
      shared.scanned,
    )
  let dep_sources = scan.sources
  let project_registry = build_project_registry(index, package_targets)
  let registry =
    signatures.merge(dependency_registry(dep_sources), project_registry)
  let type_definitions =
    build_type_definitions(index, dep_sources, package_targets)
  let registry = signatures.with_types(registry, type_definitions)
  // Built once for the run: the specs other packages wrote, the catalog and
  // the project's own lines are all read through it.
  let publishers = publisher_configurations(dep_sources, shared.publishers)
  let readings = pair_readings(dep_sources, package_targets, publishers)
  // The project's own lines, weighed as the run reads them. Run alone on its
  // targets, a line the rules forbid is an error; one of several runs refuses
  // it and leaves the verdict to them all.
  let refused =
    own_contract_violations(spec, spec_text, readings, registry, !per_target)
  use Nil <- result.try(case per_target {
    False -> own_contract_error(cfg.spec_file, refused)
    True -> Ok(Nil)
  })
  let reported =
    reported_refusals(refused, shared.builds, dep_sources, cfg.targets)
  let reading = spec_reading(registry, readings)
  // Read once and kept: the knowledge base is built from it and the spec lint
  // weighs the same entries.
  let catalog = effects.read_parsed_catalog(parsed_catalog, reading)
  let registry = signatures.with_shapes(registry, catalog.audit.containers)
  let type_info =
    type_index(
      index,
      dep_files,
      package_targets,
      dependency_target_variants(index, dep_sources),
      shared.girard,
    )
  let girard_targets =
    run_targets(
      package_targets,
      index_entries(index),
      dependency_target_variants(index, dep_sources),
    )

  // Built once for the whole run: every module's factory scan below routes its
  // constructions through the same labels.
  let constructors = package_constructors(index, dep_sources, package_targets)

  // Read once: the run's knowledge base starts from it, and so does the
  // baseline a newly loaded package is weighed against.
  let catalog_kb = catalog_knowledge_base(package_root, catalog, scan, reading)
  // The project's own lines over a function a dependency defines once per
  // target, in the variant this run builds.
  let reading_spec = rebased_consumer_lines(spec, readings, refused)
  let kb_base =
    catalog_kb
    |> effects.with_dependency_foreign(dependency_foreign(dep_sources))
    // Before anything is looked up: every foreign lookup is read on the targets
    // this build compiles, and every command reads them the same way.
    |> effects.with_package_targets(cfg.targets)
    // Which parameters of a declared name are callbacks, from the one registry
    // this run builds. Ahead of the path-dependency and fallback-body walks
    // below: a body walked there charges a declared name the same conservative
    // callback share a body walked at check time does.
    |> effects.with_callback_params(signatures.callback_param_names(registry))
    // Consumer externals are applied before path-dep inference so a module-level
    // external governs a path dependency's module during that dep's own
    // inference, not only at the final lookup.
    |> with_spec_assumes(reading_spec, stale_assumes)
    // Applied before path-dep inference for the same reason the externals above
    // are, one channel over: a spec-less path dependency's bodies are summarized
    // during that pass, and a consumer line declaring what one of its producers
    // hands back has to be in reach while they are, not only afterwards.
    |> with_spec_declared_returns(reading_spec, stale_returns_clauses)
    |> with_builders(index, dep_sources, package_targets, constructors)
    |> with_tree_baseline(index, scan, package_targets)
  // The dependency modules whose `@external` falls back to a running Gleam
  // body — read once, and handed to both passes that weigh them: the
  // path-dependency inference below types the ones it owns, and the fallback
  // walk after it takes those readings rather than typing them again.
  let retained = retained_fallback_modules(dep_sources)
  let #(kb_base, typed_dep_modules, typed_path_dependencies) =
    enrich_with_path_deps(
      kb_base,
      package_root,
      local,
      dep_files,
      declared_modules,
      package_targets,
      retained,
      arbitration_baseline(
        local,
        catalog_kb,
        scan,
        project_registry,
        reading_spec,
        stale_assumes,
        stale_returns_clauses,
        package_targets,
      ),
      registry,
      reading,
      dep_sources,
    )
  let #(kb_base, fallback_runs) =
    kb_base
    // Ahead of the fallback walk below, not merely ahead of the inference pass:
    // the field a dependency's fallback body calls may be declared here rather
    // than in that dependency's own spec, a consumer's line for a dependency's
    // type. Folded after the walk it was not there to answer, the call stayed
    // polymorphic in the field, and a caller constructing the record settled
    // the summary at whatever it wired in.
    |> with_spec_type_fields(spec)
    // Every layer that can key a dependency name is folded by here — the
    // catalog, the dependency specs, the module-level assumes, a spec-less
    // path dependency's own inference, and the field lines above — so a
    // fallback body is walked against everything a caller of it would resolve
    // against. Before this package's own inference, whose walks read the
    // summaries this leaves behind.
    |> with_dependency_fallback_effects(
      dep_files,
      retained,
      typed_dep_modules,
      registry,
      package_targets,
      girard_targets,
      fallback_typing(shared, dep_sources, retained),
    )
  let kb_base =
    kb_base
    |> with_committed_spec(committed, stale_assumes)
    // What this package defines, for the query that answers from its public API.
    |> effects.with_project_functions(project_function_visibility(index))
    // Committed project clauses are Closed: read back, not inferred this run.
    // The fresh in-memory pass below re-infers project returns and, being Fresh,
    // wins over these for the same key.
    //
    // The `assume … where returns` declarations folded above outrank both, by
    // two different mechanisms, and the difference matters to anyone editing
    // either. Against this committed load the **ordering is load-bearing**: the
    // merge gap-fills, so a spec written before the function became `@external`,
    // still carrying its inferred clause until the next `infer`, loses only
    // because the declaration is already there. Against the fresh pass below the
    // ordering decides nothing — that merge lets the incoming summary win — and
    // the declaration survives on `merge_returns`'s explicit
    // declared-beats-inferred rule instead. That rule reads as redundant from
    // here, since fresh inference keys no foreign name; it is what holds if any
    // link of that three-file invariant chain ever gives.
    |> effects.with_closed_returned_operators(
      effects.load_spec_returns_from_file(committed),
      types.CommittedSpec,
    )
  Ok(#(
    ContextBase(
      constructors:,
      declared_modules:,
      refused: reported,
      context: ProjectContext(
        sources:,
        registry:,
        type_info:,
        stale_assumes:,
        stale_returns_clauses:,
        knowledge_base: kb_base,
        catalog:,
        dependencies: dep_sources,
        field_index: package_field_index(dep_sources, index),
        dep_files:,
        local_packages: local,
        placement_files: placement_files(dep_files, local),
        typed_path_dependencies: list.reverse(typed_path_dependencies),
        pair_readings: readings,
        publishers:,
        package_pairs:,
        builds: case per_target {
          True -> shared.builds
          False -> no_package_builds()
        },
        per_target: [],
        girard_runs: shared.girard,
      ),
    ),
    Shared(
      ..shared,
      catalog: Some(parsed_catalog),
      fallback_runs:,
      publishers:,
      pairs: Some(package_pairs),
    ),
  ))
}

// Every `@external` this project declares, qualified by its module: the names
// whose effects only a declaration speaks for.
fn project_foreign_functions(
  index: Dict(String, #(String, glance.Module)),
  package_targets: types.PackageTargets,
) -> Dict(QualifiedName, types.ForeignFunction) {
  use names, module_path, #(_gleam_path, module) <- dict.fold(index, dict.new())
  dict.merge(
    names,
    checker.foreign_functions(module, module_path, package_targets),
  )
}

// The per-function `assume <module>.<function>` lines that declare
// nothing: those naming one of this package's own functions whose Gleam body is
// right there, visible and run by every caller.
//
// The one place validity is decided. Everything downstream is a consequence:
// the knowledge base is assembled without these lines, so no lookup can reach
// around the rule and none of them can bury the body-derived term; `check`
// warns once about each; and `infer` deletes them and writes the `effects` line
// they were suppressing.
//
// `native_of` answers with a module's Gleam-bodied function names, and
// `Error(Nil)` where there is no source to consult. That absence is not
// evidence: a module outside this package (declaring a *dependency* function
// with a body is the line's documented use, and dep sources are scanned, so
// "has a body" is knowable there too), one outside a scoped run, or one that
// would not parse all leave the line standing.
fn stale_project_assumes(
  spec: GradedFile,
  native_of: fn(String) -> Result(Set(String), Nil),
) -> Set(String) {
  declaring_nothing(annotation.assume_function_names(spec), native_of)
}

// The returned-operator declarations that declare nothing: the same rule one
// channel over, over the same predicate, so the two cannot drift apart.
//
// Derived apart from `stale_project_assumes` and threaded apart from it. That
// set drives the effects channel's two suppressions — committed `effects` lines
// with their bounds, and the inferred lines `infer` writes — and a returns name
// reaching either would delete a function's effect lines because its *value* was
// declared.
fn stale_project_assume_returns(
  spec: GradedFile,
  native_of: fn(String) -> Result(Set(String), Nil),
) -> Set(String) {
  declaring_nothing(annotation.assume_returns_names(spec), native_of)
}

// Which of `names` this package defines with a Gleam body — the rule both
// declaring forms are held to, written once. A name whose module offers no
// source to consult is kept out: absence is not evidence, so the line stands.
fn declaring_nothing(
  names: Set(String),
  native_of: fn(String) -> Result(Set(String), Nil),
) -> Set(String) {
  set.filter(names, fn(name) {
    case annotation.split_function_name(name) {
      Error(Nil) -> False
      Ok(#(module, function)) ->
        case native_of(module) {
          Ok(native) -> set.contains(native, function)
          Error(Nil) -> False
        }
    }
  })
}

// The names the spec still declares a `where returns` clause for: every
// `assume … where returns` in it, minus the ones this package's own source
// makes stale. What the fast path checks a dependency name against, since a
// clause the spec no longer declares leaves the tiers below it free to answer.
fn surviving_returns_declarations(
  spec: GradedFile,
  stale_returns_clauses: Set(String),
) -> Set(String) {
  set.difference(annotation.assume_returns_names(spec), stale_returns_clauses)
}

// A module's Gleam-bodied function names as the project index holds them, in
// the shape `stale_project_assumes` asks for.
fn native_functions_of(
  index: Dict(String, #(String, glance.Module)),
  package_targets: types.PackageTargets,
) -> fn(String) -> Result(Set(String), Nil) {
  // Each module's, read once for every line that asks.
  let natives =
    dict.map_values(index, fn(_module_path, entry) {
      checker.native_function_names(entry.1, package_targets)
    })
  dict.get(natives, _)
}

// The spec's assume declarations minus the ones that declare nothing.
fn declaring_assumes(
  spec: GradedFile,
  stale: Set(String),
) -> List(types.AssumeAnnotation) {
  annotation.extract_assumes(spec)
  |> list.filter(fn(assume) {
    case annotation.assume_qualified_name(assume) {
      Ok(qualified) -> !set.contains(stale, types.dotted_name(qualified))
      Error(Nil) -> True
    }
  })
}

// Every function this project defines, keyed by module then by function: what
// the package's public API is, as its source states it.
fn project_function_visibility(
  index: Dict(String, #(String, glance.Module)),
) -> Dict(String, Dict(String, types.Visibility)) {
  use modules, module_path, #(_gleam_path, module) <- dict.fold(
    index,
    dict.new(),
  )
  dict.insert(modules, module_path, checker.function_visibility(module))
}

// Group a parsed spec file's `check` annotations by their module path. Used
// during `run` to hand each source file only the checks that apply to it.
// The checker expects bare function names per module, so we strip the
// module qualifier from the grouped annotations. The `where returns` clause
// travels with the line: the checker weighs it against the operator the
// function hands back.
fn checks_grouped_by_module(
  checks: List(EffectAnnotation),
) -> Dict(String, List(EffectAnnotation)) {
  list.fold(checks, dict.new(), fn(acc, ann) {
    case annotation.split_function_name(ann.function) {
      Error(_) -> acc
      Ok(#(module, function)) -> {
        let bare = EffectAnnotation(..ann, function:)
        let existing = case dict.get(acc, module) {
          Ok(list) -> list
          Error(_) -> []
        }
        dict.insert(acc, module, [bare, ..existing])
      }
    }
  })
}

// Run the checker against one source file using the slice of `check`
// annotations from the spec file that mention this file's module.
fn check_one_file(
  gleam_path: String,
  module_path: String,
  module: glance.Module,
  module_checks: List(EffectAnnotation),
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  package_targets: types.PackageTargets,
) -> CheckResult {
  let #(violations, findings, warnings) =
    checker.check(
      module,
      module_path,
      module_checks,
      knowledge_base,
      registry,
      reading,
      package_targets,
    )
  CheckResult(file: gleam_path, violations:, findings:, warnings:)
}

// Spec lint
//
// The pass itself lives in `graded/internal/lint`; what stays here is the
// project state it reads. Dependency discovery is handed over as thunks, so a
// spec with no line kind that asks a question of the dependency tree never
// pays for the walk.

// The lint's view of an assembled context. The dependency scan's own types
// stay here: the lint's one read of it is the three-state answer about a
// name, so a closure over `dependency_name` is what crosses the boundary.
fn lint_context(context: ProjectContext) -> lint.Context {
  let ProjectContext(
    sources: ProjectSources(spec:, index:, ..),
    stale_assumes:,
    stale_returns_clauses:,
    catalog:,
    dependencies:,
    registry:,
    local_packages:,
    placement_files:,
    ..,
  ) = context
  lint.Context(
    spec:,
    index:,
    stale_assumes:,
    stale_returns_clauses:,
    catalog:,
    registry:,
    dependency_name: dependency_name(dependencies, _),
    dependency_files: placement_files,
    dependency_sources_are_complete: fn() {
      package_tree.is_complete(local_packages)
    },
    resolve_bounds: contract.resolve_bounds(_, registry),
    reader_view: consumer_view(context.pair_readings),
  )
}

// Map of module path -> source file for every installed dependency (under
// `build/packages`) and path dependency (under its declared `path`). Lets the
// spec lint tell a dependency type from a typo, and parse a dependency module
// when it needs to resolve a field's declared type.
//
// Costs a directory walk of the whole tree, so a command scans once and threads
// the result to everything that resolves against it.
@internal
pub fn dependency_module_files(package_root: String) -> Dict(String, String) {
  tree_module_files(package_root, package_tree.discover(package_root))
}

// Every module the spec lint may place, for the tree at `package_root`.
@internal
pub fn placement_module_files(package_root: String) -> Dict(String, String) {
  let local = package_tree.discover(package_root)
  placement_files(tree_module_files(package_root, local), local)
}

// The placement map the context assembled for `directory` holds, which is the
// one `check`'s spec lint reads.
@internal
pub fn context_placement_files(
  directory: String,
) -> Result(Dict(String, String), GradedError) {
  use ctx <- result.map(load_project_context(directory))
  ctx.placement_files
}

// The knowledge base the context assembled for `directory` holds.
@internal
pub fn context_knowledge_base(
  directory: String,
) -> Result(KnowledgeBase, GradedError) {
  use ctx <- result.map(load_project_context(directory))
  ctx.knowledge_base
}

// Every custom type and alias the context assembled for `directory` holds.
@internal
pub fn context_type_definitions(
  directory: String,
) -> Result(typedefs.TypeRegistry, GradedError) {
  use ctx <- result.map(load_project_context(directory))
  ctx.registry.types
}

// The directories whose `gleam.toml` the context assembled for `directory`
// read, in the order it read them.
@internal
pub fn context_tree_visits(
  directory: String,
) -> Result(List(String), GradedError) {
  use ctx <- result.map(load_project_context(directory))
  ctx.local_packages.visited
}

// What the run answered for `name` before any newly loaded package was
// loaded, rendered as `graded effect --format=graded` renders an answer.
// `EffectNotFound` where nothing answered, as for a project with no newly
// loaded package.
@internal
pub fn arbitration_baseline_answer(
  directory: String,
  name: String,
) -> Result(String, GradedError) {
  use sources <- result.try(load_project_sources(
    source_scope(directory).analysed,
  ))
  let ProjectSources(cfg:, spec:, index:, package_root:, ..) = sources
  let reading = effects.trusting_reading()
  use catalog <- result.try(load_bundled_catalog(package_root, reading))
  let native_of = native_functions_of(index, cfg.targets)
  let local = package_tree.discover(package_root)
  let scan =
    dependency_scan(
      package_root,
      local,
      cfg.targets,
      ParsedTree(files: dict.new(), dirs: dict.new()),
      dict.new(),
    )
  case
    arbitration_baseline(
      local,
      catalog_knowledge_base(package_root, catalog, scan, reading),
      scan,
      build_project_registry(index, cfg.targets),
      spec,
      stale_project_assumes(spec, native_of),
      stale_project_assume_returns(spec, native_of),
      cfg.targets,
    )
  {
    None -> Error(EffectNotFound(name))
    Some(baseline) ->
      answer_from(baseline, name)
      |> result.map(answer.render_graded)
      |> result.replace_error(EffectNotFound(name))
  }
}

// The same map, over a tree already discovered: the installed packages, the
// root's own path dependencies, whose copy of a module path wins, and every
// other local package the root's runtime dependencies reach, which fills only
// the paths neither holds. Dev-only packages are not in it.
fn tree_module_files(
  package_root: String,
  local: LocalPackages,
) -> Dict(String, String) {
  let installed = effects.dependency_module_files(packages_dir(package_root))
  let read_today =
    list.fold(local.direct, installed, fn(acc, dep) {
      let #(_name, dep_path) = dep
      let src_dir =
        filepath.join(config.resolve_path(package_root, dep_path), "src")
      dict.merge(acc, effects.source_dir_module_files(src_dir))
    })
  package_tree.newly_loaded(local)
  |> list.fold(read_today, fn(acc, package) {
    dict.merge(
      effects.source_dir_module_files(filepath.join(package.directory, "src")),
      acc,
    )
  })
}

// Every module the spec lint may place: the dependency scan, which holds every
// runtime local package, and the `src/` of every dev-only one. A module the
// scan holds keeps the file it holds.
fn placement_files(
  dep_files: Dict(String, String),
  local: LocalPackages,
) -> Dict(String, String) {
  use acc, name, package <- dict.fold(local.packages, dep_files)
  case package_tree.class_of(local, name) {
    package_tree.DevOnly ->
      dict.merge(
        effects.source_dir_module_files(filepath.join(package.directory, "src")),
        acc,
      )
    package_tree.Direct | package_tree.NewlyLoaded -> acc
  }
}

// Effect queries
//
// The `effect` command: resolve one name against the project's knowledge base
// into a structured answer, writing nothing. The CLI prints it as prose; this
// module's API renders it as spec syntax.

/// Look up one name's effect in `directory`'s project and render it as a
/// `.graded` line.
///
/// `name` is either a module-qualified function (`myapp/router.handle`) or a
/// type field (`myapp/repo.Repo.find`). Functions resolve from the spec file,
/// dependencies, the catalog, and an in-memory inference pass, so a public
/// function resolves without a prior `graded infer`; type fields resolve from
/// declared field `assume` lines. Any provenance is appended as a `//` comment line, so
/// the whole output parses as `.graded` syntax. Nothing is written to disk.
///
/// The CLI defaults to `--format=prose` for the person reading a terminal; this
/// function keeps returning the parseable form, which is what a caller linking
/// against the module wants. `run_effect_formatted` takes the format.
///
/// Returns `EffectNotFound` when the name is neither a public function nor a
/// declared type field.
pub fn run_effect(
  directory: String,
  name: String,
) -> Result(String, GradedError) {
  run_effect_formatted(directory, name, Graded)
}

/// How `run_effect_formatted` renders an answer.
pub type Format {
  /// A `.graded` line, with any provenance as a `//` comment — the whole
  /// output parses as spec syntax.
  Graded
  /// Sentences describing the same answer, as `graded effect` prints them.
  Prose
}

/// Look up one name's effect and render it in `format`. Both formats render
/// one structured answer, so they can differ in wording but never in what they
/// report.
pub fn run_effect_formatted(
  directory: String,
  name: String,
  format: Format,
) -> Result(String, GradedError) {
  effect_answer(directory, name)
  |> result.map(answer.render(_, answer_format(format)))
}

fn answer_format(format: Format) -> answer.Format {
  case format {
    Graded -> answer.Graded
    Prose -> answer.Prose
  }
}

// Resolve `name` to a structured answer, trying the spec-only fast path first.
fn effect_answer(
  directory: String,
  name: String,
) -> Result(EffectAnswer, GradedError) {
  let directory = source_scope(directory).analysed
  use cfg <- result.try(read_config(directory))
  use spec <- result.try(read_spec(cfg.spec_file))
  // A bounded `assume` line is weighed against the run's signatures before
  // anything answers, which only the full context reads.
  let fast =
    !list.any(annotation.extract_assumes(spec), fn(assume) {
      assume.params != []
    })
  let found = case fast {
    True -> spec_answer(directory, spec, cfg.targets, name)
    False -> Error(Nil)
  }
  case found {
    Ok(found) -> Ok(found)
    Error(Nil) -> project_answer(directory, name)
  }
}

/// Look up `name` the long way: assemble the whole project context — every
/// module parsed, dependency sources scanned, girard run package-wide — and
/// answer from its knowledge base, skipping the spec-only fast path
/// `run_effect` tries first.
///
/// Exposed (pub) primarily so a test can assert the two paths agree. A
/// fast-path answer is only correct if it is what the full context would have
/// said, byte for byte; nothing else about the two is allowed to differ.
@internal
pub fn run_effect_from_project(
  directory: String,
  name: String,
) -> Result(String, GradedError) {
  project_answer(source_scope(directory).analysed, name)
  |> result.map(answer.render_graded)
}

// Answer from the full project context: every module parsed, dependency sources
// scanned, girard run package-wide.
fn project_answer(
  directory: String,
  name: String,
) -> Result(EffectAnswer, GradedError) {
  use ctx <- result.try(load_project_context(directory))
  case ctx.per_target {
    [] -> {
      let signature = function_signature(ctx, name)
      let targets =
        types.build_targets(ctx.sources.cfg.targets)
        |> set.to_list
        |> list.sort(string.compare)
      case answer_from(ctx.knowledge_base, name) {
        Ok(found) ->
          Ok(case targets {
            [target] ->
              answer_in_published_names(signature, name, found, target)
            _ -> found
          })
        Error(Nil) -> uncovered_answer(ctx.builds, signature, name, targets)
      }
    }
    contexts -> per_target_answer(ctx, contexts, name)
  }
  |> result.replace_error(EffectNotFound(name))
}

// One answer for `name` from each target's analysis. A target that builds a
// public definition of the function and declares nothing for it reads
// `[Unknown]`, as a call to it does there; a target that builds none adds
// nothing. A name no target declares is no answer, unless a dependency's
// line over it is not read on one of them because its package publishes for
// other targets.
fn per_target_answer(
  ctx: ProjectContext,
  contexts: List(#(String, ProjectContext)),
  name: String,
) -> Result(EffectAnswer, Nil) {
  let signature = function_signature(ctx, name)
  let read =
    list.filter_map(contexts, fn(entry) {
      let #(target, context) = entry
      case answer_from(context.knowledge_base, name) {
        Ok(found) ->
          Ok(#(
            target,
            Some(answer_in_published_names(signature, name, found, target)),
          ))
        Error(Nil) ->
          case builds_on(ctx.builds, signature, name, target) {
            True -> Ok(#(target, None))
            False -> Error(Nil)
          }
      }
    })
  let found =
    list.filter_map(read, fn(entry) {
      option.to_result(entry.1, Nil) |> result.map(fn(one) { #(entry.0, one) })
    })
  let undeclared =
    list.filter_map(read, fn(entry) {
      case entry.1 {
        Some(_) -> Error(Nil)
        None -> Ok(entry.0)
      }
    })
  case found, undeclared {
    [], _ -> uncovered_answer(ctx.builds, signature, name, undeclared)
    [#(_, lead), ..rest], [] -> {
      use <- bool.guard(
        when: list.all(rest, fn(entry) { entry.1 == lead }),
        return: Ok(lead),
      )
      Ok(joined_function_answer(ctx.builds, signature, name, lead, read))
    }
    [#(_, lead), ..], _ ->
      case joined_function_answer(ctx.builds, signature, name, lead, read) {
        answer.FunctionAnswer(source:, ..) as joined ->
          Ok(
            answer.FunctionAnswer(
              ..joined,
              source: answer.UndeclaredOn(
                targets: undeclared,
                declared: Some(source),
              ),
            ),
          )
        answer.TypeFieldAnswer(..) -> Error(Nil)
      }
  }
}

// `[Unknown]` for `name` on each of `targets` that builds a definition of the
// dependency function its package's line is not read on, its package
// publishing for other targets; no answer where there is none.
fn uncovered_answer(
  builds: PackageBuilds,
  signature: FunctionSignature,
  name: String,
  targets: List(String),
) -> Result(EffectAnswer, Nil) {
  use #(module, _function) <- result.try(annotation.split_function_name(name))
  case
    list.filter(targets, fn(target) {
      builds_on(builds, signature, name, target)
      && uncovered_on(signature, target)
    })
  {
    [] -> Error(Nil)
    uncovered ->
      Ok(answer.FunctionAnswer(
        name:,
        module:,
        bounds: [],
        term: effect_term.unknown(),
        returns: None,
        source: answer.UndeclaredOn(targets: uncovered, declared: None),
      ))
  }
}

// Whether the line a dependency's package publishes over the signature's
// function is not read on `target`: a function it defines once per target,
// published for targets that leave `target` out.
fn uncovered_on(signature: FunctionSignature, target: String) -> Bool {
  case signature {
    DependencySignature(variants: [_, _, ..], publisher:) ->
      !set.contains(types.build_targets(publisher), target)
    DependencySignature(..) | ProjectSignature | NoSignature -> False
  }
}

// The definitions a function name reads over: a module of this package's, or
// a dependency's beside the targets its package publishes for.
type FunctionSignature {
  ProjectSignature
  DependencySignature(
    variants: List(glance.Definition(glance.Function)),
    publisher: types.PackageTargets,
  )
  NoSignature
}

// The public definitions of `name`'s function, from this package's parse or
// from the dependency module's source the scan read.
fn function_signature(ctx: ProjectContext, name: String) -> FunctionSignature {
  case annotation.split_function_name(name) {
    Error(Nil) -> NoSignature
    Ok(#(module_path, function)) ->
      case dict.get(ctx.sources.index, module_path) {
        Ok(_) -> ProjectSignature
        Error(Nil) ->
          case dict.get(ctx.dependencies.modules, module_path) {
            Ok(ParsedModule(source_path:, ..)) ->
              case read_and_parse_gleam_or_nil(source_path) {
                Ok(module) ->
                  DependencySignature(
                    variants: public_variants(module, function),
                    publisher: dependency_publisher(
                      ctx,
                      source_path,
                      module_path,
                    ),
                  )
                Error(Nil) -> NoSignature
              }
            Ok(UnreadableModule) | Error(Nil) -> NoSignature
          }
      }
  }
}

// The targets the package of the dependency module at `source_path`
// publishes for, as the run read them.
fn dependency_publisher(
  ctx: ProjectContext,
  source_path: String,
  module_path: String,
) -> types.PackageTargets {
  let root = dependency_root(source_path, module_path)
  dict.get(ctx.publishers, root)
  |> result.lazy_unwrap(fn() { publisher_targets(root) })
}

fn public_variants(
  module: glance.Module,
  function: String,
) -> List(glance.Definition(glance.Function)) {
  list.filter(module.functions, fn(definition) {
    definition.definition.name == function
    && definition.definition.publicity == glance.Public
  })
}

// The package root a dependency module's source file sits under.
fn dependency_root(source_path: String, module_path: String) -> String {
  string.drop_end(
    source_path,
    string.length("/src/" <> module_path <> ".gleam"),
  )
}

// The targets the package at `root` publishes its spec for.
fn publisher_targets(root: String) -> types.PackageTargets {
  case config.read(filepath.join(root, "gleam.toml")) {
    Ok(cfg) -> cfg.targets
    Error(_) -> types.DefaultedTargets
  }
}

// Whether `target` builds a definition of the function `name`: one of the
// package's own as the run's targets build it, a dependency's by its
// definitions.
fn builds_on(
  builds: PackageBuilds,
  signature: FunctionSignature,
  name: String,
  target: String,
) -> Bool {
  case signature {
    ProjectSignature ->
      case function_builds(builds, name) {
        Ok(one) -> result.is_ok(list.key_find(one.built, target))
        Error(Nil) -> False
      }
    DependencySignature(variants:, ..) ->
      result.is_ok(built_variant(variants, target))
    NoSignature -> False
  }
}

// The definition `target` builds among `variants`.
fn built_variant(
  variants: List(glance.Definition(glance.Function)),
  target: String,
) -> Result(glance.Definition(glance.Function), Nil) {
  extract.built_functions(variants, set.from_list([target]))
  |> list.find(fn(definition) {
    set.contains(
      extract.compiled_targets(definition, set.from_list([target])),
      target,
    )
  })
}

// A function answer joined from each target's, `lead` the first a target
// declared, as `infer` publishes the name: over this package's published
// parameters, or over those a dependency's package publishes in. A target
// that builds the function and declares nothing contributes `[Unknown]` and no
// returned operator. Any other answer is `lead`.
fn joined_function_answer(
  builds: PackageBuilds,
  signature: FunctionSignature,
  name: String,
  lead: EffectAnswer,
  read: List(#(String, Option(EffectAnswer))),
) -> EffectAnswer {
  case lead, answer_line(name, lead) {
    answer.FunctionAnswer(returns:, ..), Ok(first) -> {
      let joined =
        list.filter_map(read, target_line(name, _))
        |> signature_joined_line(builds, signature, name, first, _)
      answer.FunctionAnswer(
        ..lead,
        bounds: joined.params,
        term: joined.effects,
        returns: case returns, joined.returns {
          Some(returned), Some(operator) ->
            Some(effects.ReturnedOperator(..returned, operator:))
          _, _ -> None
        },
      )
    }
    _, _ -> lead
  }
}

// One target's answer for `name` as the line stating it: `[Unknown]` and no
// returned operator where the target declares nothing.
fn target_line(
  name: String,
  entry: #(String, Option(EffectAnswer)),
) -> Result(#(String, EffectAnnotation), Nil) {
  case entry.1 {
    Some(found) -> answer_line(name, found)
    None ->
      Ok(EffectAnnotation(
        kind: types.Effects,
        function: name,
        params: [],
        effects: effect_term.unknown(),
        returns: None,
      ))
  }
  |> result.map(fn(line) { #(entry.0, line) })
}

// Each target's line for `name` as one, over the parameters the signature
// publishes, a function of the package's own read on the targets that build it
// as `infer` publishes it; `first` where it names no definitions.
fn signature_joined_line(
  builds: PackageBuilds,
  signature: FunctionSignature,
  name: String,
  first: EffectAnnotation,
  lines: List(#(String, EffectAnnotation)),
) -> EffectAnnotation {
  case signature {
    DependencySignature(..) ->
      list.map(lines, fn(entry) { entry.1 })
      |> checker.union_of_lines
      |> result.unwrap(first)
    ProjectSignature ->
      case function_builds(builds, name) {
        Ok(one) -> joined_built_line(one, first, lines)
        Error(Nil) -> first
      }
    NoSignature -> first
  }
}

// One target's answer for a dependency's function it defines once per target,
// read in the parameter names of the definition `target` builds, as stated in
// the names its package publishes in: its bounds, its term, and its returned
// operator with the bounds that scope it.
fn answer_in_published_names(
  signature: FunctionSignature,
  name: String,
  found: EffectAnswer,
  target: String,
) -> EffectAnswer {
  case signature, found {
    DependencySignature(variants: [_, _, ..] as variants, publisher:),
      answer.FunctionAnswer(bounds:, term:, returns:, ..)
    ->
      {
        use definition <- result.try(built_variant(variants, target))
        use to <- result.map(checker.publisher_parameters(variants, publisher))
        // A line inferred over the dependency's source names its variables
        // after the parameters of the variant read; a written line keeps its
        // own. Each channel is read by its own origin: an answer's effects
        // and the operator it returns can come from different sources.
        let rebased = fn(inferred, params, term) {
          case inferred {
            True -> checker.rebased_inferred_line
            False -> checker.rebased_line
          }(
            definition.definition.parameters,
            to,
            EffectAnnotation(
              kind: types.Effects,
              function: name,
              params:,
              effects: term,
              returns: None,
            ),
          )
        }
        let line = rebased(inferred_summary(found), bounds, term)
        answer.FunctionAnswer(
          ..found,
          bounds: line.params,
          term: line.effects,
          returns: option.map(returns, fn(returned) {
            let inferred = case returned.source {
              types.PathDependencyInferred(_) -> True
              _ -> False
            }
            published_returns(returned, fn(params, term) {
              rebased(inferred, params, term)
            })
          }),
        )
      }
      |> result.unwrap(found)
    _, _ -> found
  }
}

// Whether an answer is inference over a spec-less path dependency's source.
fn inferred_summary(found: EffectAnswer) -> Bool {
  case found {
    answer.FunctionAnswer(
      source: answer.Entry(
        entry: types.FunctionEntry(origin: types.PathDependencyInferred(_), ..),
        ..,
      ),
      ..,
    ) -> True
    _ -> False
  }
}

// A returned operator stated through `rebased`, with the bounds that scope it.
fn published_returns(
  returned: effects.ReturnedOperator,
  rebased: fn(List(types.ParamBound), types.EffectTerm) -> EffectAnnotation,
) -> effects.ReturnedOperator {
  let #(scoping, rescoped) = case returned.summary {
    effects.Declared(bounds:) -> #(bounds, effects.Declared)
    effects.Closed(bounds:) -> #(bounds, effects.Closed)
    effects.Fresh -> #([], fn(_) { effects.Fresh })
  }
  let clause = rebased(scoping, returned.operator)
  effects.ReturnedOperator(
    ..returned,
    operator: clause.effects,
    summary: rescoped(clause.params),
  )
}

// A function answer as the `effects` line stating it.
fn answer_line(
  name: String,
  found: EffectAnswer,
) -> Result(EffectAnnotation, Nil) {
  case found {
    answer.FunctionAnswer(bounds:, term:, returns:, ..) ->
      Ok(EffectAnnotation(
        kind: types.Effects,
        function: name,
        params: bounds,
        effects: term,
        returns: option.map(returns, fn(returned) { returned.operator }),
      ))
    answer.TypeFieldAnswer(..) -> Error(Nil)
  }
}

// Resolve `name` against one knowledge base. The function interpretation is
// tried first: a module path never contains a `.`, so a type-field name splits
// to a module that can't exist and falls through, while a plain function name
// resolves before it can be misread as `type.field`.
fn answer_from(
  knowledge_base: KnowledgeBase,
  name: String,
) -> Result(EffectAnswer, Nil) {
  case function_effect(knowledge_base, name) {
    Ok(found) -> Ok(found)
    Error(Nil) -> type_field_effect(knowledge_base, name)
  }
}

// Answer from the spec file alone, skipping the project context entirely.
//
// Building a context glance-parses every module, scans dependency sources and
// runs girard package-wide — all of it wasted when the spec already decides the
// name. The answer is rendered by the same two renderers the full path uses,
// against a knowledge base folded in the same order `load_project_context`
// folds its spec-derived layers, so a hit here is byte-identical to what the
// full context would have produced.
//
// It only answers where the spec's word is final:
//
// - A field `assume` line declaring a field under its own module: spec `type` fields
//   are merged last of all, so an exact key wins outright. A bare line's
//   module-less key is a fallback, not a decision, and stays with the full
//   context.
// - A per-function `assume <module>.<function>`: `with_assumes`
//   inserts over whatever came before, and every later layer keeps existing
//   entries, so nothing can displace it.
// - Any name in one of this package's own modules: dependency, catalog and
//   path-dependency entries are keyed by *their* module paths, which Gleam
//   forbids from colliding with this package's, so no other source can key it
//   and the in-memory inference pass keeps existing entries.
//
// Anything else — a name needing the in-memory pass, or a dependency function —
// misses here and falls through.
fn spec_answer(
  directory: String,
  spec: GradedFile,
  // The package's targets, from the one config read this command makes. Which
  // functions of the queried module are foreign code depends on them, and so
  // does which half of a target-conditional `@external` answers.
  targets: types.PackageTargets,
  name: String,
) -> Result(EffectAnswer, Nil) {
  case annotation.split_function_name(name) {
    // A name the function grammar accepts. The full path resolves it as a
    // function *before* it considers a type field, so the fast path may not
    // answer at all — from either renderer — until it knows no other source can
    // key that function.
    Ok(#(module, function)) -> {
      let project_modules = project_module_files(directory)
      use <- bool.guard(
        when: !set.contains(annotation.assume_function_names(spec), name)
          && !dict.has_key(project_modules, module),
        return: Error(Nil),
      )
      // What this package's source says about the queried module — which of its
      // functions are foreign code, which it exports, and which of them a
      // per-function external names in vain — is a fact of that source, not of
      // the spec, and the spec is folded against it. One file is parsed to
      // settle all three: the module the queried name lives in.
      use parsed <- result.try(module_source_facts(
        project_modules,
        module,
        targets,
      ))
      let native_of = fn(queried) {
        case queried == module {
          True -> Ok(parsed.native)
          False -> Error(Nil)
        }
      }
      let stale = stale_project_assumes(spec, native_of)
      // The clause channel's own staleness, derived beside the effects
      // channel's rather than reused from it: the two drive different
      // suppressions, and a returns name reaching the effects set would delete
      // a function's effect lines because its *value* was declared.
      let stale_returns = stale_project_assume_returns(spec, native_of)
      // A producer's returned-operator clause is inferred by walking its body,
      // and a fresh summary outranks the committed clause the spec carries for
      // the same name — so the spec's word is not final about it, whatever the
      // spec says. Left whole to the full context, which walks that body.
      use <- bool.guard(
        when: set.contains(parsed.producers, function),
        return: Error(Nil),
      )
      // The same question one tier down, and it is the returns channel alone
      // that asks it. A name outside this package's own modules can carry a
      // `where returns` clause from a source this path never reads — an
      // installed dependency's shipped spec, a path dependency's spec, or
      // inference over a spec-less path dependency's source — and on that
      // channel the consumer's own declaration is what displaces it
      // (`with_declared_returned_operators` lets the incoming entry win, and
      // the consumer's fold runs last). So the spec settles this name only
      // where it declares the clause itself; a *committed* clause does not
      // count, since that fold gap-fills and a dependency's declaration folded
      // earlier outranks it.
      //
      // The effects channel is still final here — a per-function `assume`
      // outranks every later layer — but an answer is one value, so it goes
      // whole to the full context or not at all.
      use <- bool.guard(
        when: !dict.has_key(project_modules, module)
          && !set.contains(
          surviving_returns_declarations(spec, stale_returns),
          name,
        ),
        return: Error(Nil),
      )
      // An `@external` of this package's whose Gleam fallback body runs is
      // charged that body's effects on top of its declaration, and walking a
      // body is exactly what the fast path exists not to do. Deferred whole, so
      // the answer cannot be the declaration alone where the full context says
      // more.
      use <- bool.guard(
        when: runs_a_fallback_body(parsed.foreign, name),
        return: Error(Nil),
      )
      let dependency =
        dependency_facts_for(directory, project_modules, module, targets)
      // And a *dependency's* external whose fallback body runs, for the same
      // reason: the full context walks that body during its dependency pass and
      // charges the name what it does, so answering from the declaration alone
      // would quote a charge `check` does not levy.
      use <- bool.guard(
        when: runs_a_fallback_body(dependency.foreign, name),
        return: Error(Nil),
      )
      answer_from(
        with_module_facts(
          spec_knowledge_base(spec, stale, stale_returns, targets),
          parsed,
        )
          |> effects.with_dependency_foreign(dependency.foreign)
          // The dependency module's own callback parameters, from the parse
          // above: a boundless declaration over one of its higher-order
          // externals charges a variable per callback, and an answer without
          // them quotes the declared term the full context widened.
          |> effects.with_callback_params(dependency.callbacks),
        name,
      )
    }
    // Not a function name — only a type field can answer. A spec field `assume` line is
    // merged last of all, so an entry under the queried name's *own* module is
    // final. The module-less key a bare line lands under is not: it is only the
    // fallback `type_field_effect` reaches for when nothing declares the exact
    // module, and a dependency's spec — which the fast path never reads — can
    // declare it. So the spec decides this name only if it declares it
    // qualified; a bare line is left to the full context, which weighs it
    // against every dependency's field `assume` lines.
    // An answer carrying the queried module is one the exact key produced; one
    // carrying none fell back to the bare key, so it isn't the spec's decision.
    Error(Nil) ->
      case
        type_field_effect(
          spec_knowledge_base(spec, set.new(), set.new(), targets),
          name,
        )
      {
        Ok(answer.TypeFieldAnswer(module: Some(_), ..) as found) -> Ok(found)
        Ok(answer.TypeFieldAnswer(module: None, ..))
        | Ok(answer.FunctionAnswer(..))
        | Error(Nil) -> Error(Nil)
      }
  }
}

// The spec layers of `load_project_context`'s knowledge base, folded in the same
// order and by the same functions, over nothing else.
//
// The spec's clause channel is among them, both halves: `graded effect` states
// the `where returns` clause a name answers with, so a fast-path answer without
// one would differ from the full context's for the same name. No body is walked
// here — the clauses are read off the spec exactly as the full context reads
// them back, and each stale filter is applied to the channel it was derived
// for.
fn spec_knowledge_base(
  spec: GradedFile,
  stale_assumes: Set(String),
  stale_returns_clauses: Set(String),
  targets: types.PackageTargets,
) -> KnowledgeBase {
  effects.new_knowledge_base()
  |> effects.with_package_targets(targets)
  |> with_spec_assumes(spec, stale_assumes)
  |> with_spec_declared_returns(spec, stale_returns_clauses)
  |> with_committed_spec(spec, stale_assumes)
  |> effects.with_closed_returned_operators(
    effects.load_spec_returns_from_file(spec),
    types.CommittedSpec,
  )
  |> with_spec_type_fields(spec)
}

// Whether the queried name is an `@external` that falls back to Gleam on some
// target it is compiled for, according to `foreign` — either scan's map, since
// the question and its consequence are the same for this package's source and a
// dependency's. A body runs, and the fast path walks none.
fn runs_a_fallback_body(
  foreign: Dict(QualifiedName, types.ForeignFunction),
  name: String,
) -> Bool {
  case annotation.split_function_name(name) {
    Error(Nil) -> False
    Ok(#(module, function)) ->
      case dict.get(foreign, QualifiedName(module:, function:)) {
        Ok(types.ForeignFunction(runs_fallback_body:, ..)) -> runs_fallback_body
        Error(Nil) -> False
      }
  }
}

// What a *dependency's* source says about the queried module: which of its
// functions are `@external`, and which parameters of each are callbacks. Both
// come off one parse, because both answer the same question about the same
// module and a second parse could read a different copy of it.
type DependencyModuleFacts {
  DependencyModuleFacts(
    foreign: Dict(QualifiedName, types.ForeignFunction),
    callbacks: Dict(QualifiedName, List(String)),
  )
}

// What a *dependency's* source says about the queried module.
//
// Empty for one of this package's own modules: Gleam forbids a dependency from
// keying one, so nothing over there can change the answer. For a dependency
// module — which a per-function `assume` line may name — the
// declaration alone understates an `@external` whose Gleam fallback body runs,
// because the full context walks that body and unions what it does into the
// charge. It also understates a boundless declaration over a higher-order one,
// whose callbacks the full context charges off this same signature. One module
// is located and parsed to settle both, so the fast path can tell the first
// case and hand it back, and answer the second as the full context does.
fn dependency_facts_for(
  directory: String,
  project_modules: Dict(String, String),
  module: String,
  package_targets: types.PackageTargets,
) -> DependencyModuleFacts {
  let none = DependencyModuleFacts(foreign: dict.new(), callbacks: dict.new())
  use <- bool.guard(when: dict.has_key(project_modules, module), return: none)
  let files = dependency_module_files(resolve_package_root(directory))
  // A dependency graded cannot locate or parse is one the full context cannot
  // read either, so both answer from the declaration alone.
  use <- bool.guard(when: !dict.has_key(files, module), return: none)
  case dict.get(files, module) |> result.try(read_and_parse_gleam_or_nil) {
    Ok(parsed) ->
      DependencyModuleFacts(
        foreign: checker.dependency_foreign_functions(
          parsed,
          module,
          package_targets,
        ),
        callbacks: module_callback_params(module, parsed, package_targets),
      )
    Error(Nil) -> none
  }
}

fn read_and_parse_gleam_or_nil(path: String) -> Result(glance.Module, Nil) {
  read_and_parse_gleam(path) |> result.replace_error(Nil)
}

// This package's own source files, keyed by module path. Listing the file names
// costs a directory walk and no parsing, so it stays on the fast path.
fn project_module_files(directory: String) -> Dict(String, String) {
  case find_gleam_files(directory) {
    Error(_) -> dict.new()
    Ok(paths) ->
      paths
      |> list.map(fn(path) {
        #(config.module_path_for_source(path, directory), path)
      })
      |> dict.from_list()
  }
}

// What the fast path learns from one project module's source: which of its
// functions are foreign code, and what each of its functions' visibility is.
// Neither is a fact of the spec — an `effects` line left behind for an
// `@external` would otherwise be read as answering, and a hand-written line for
// a private name or a typo would be too.
type ModuleFacts {
  ModuleFacts(
    foreign: Dict(QualifiedName, types.ForeignFunction),
    visibility: Dict(String, Dict(String, types.Visibility)),
    native: Set(String),
    // Which parameters of each of its functions are callbacks — what the full
    // context reads off the whole-package registry, taken here from the one
    // module this path parses. A boundless declaration over a higher-order
    // `@external` charges a variable per callback, so an answer without them
    // quotes a narrower term than `check` levies.
    callbacks: Dict(QualifiedName, List(String)),
    // Which of its functions return a function — the producers whose returned
    // operator the full context infers by walking their bodies. A fresh summary
    // outranks the spec's committed clause for the same name, so a producer's
    // clause is not the spec's to decide and the fast path declines it.
    producers: Set(String),
  )
}

// One project module's source facts, parsed on demand.
//
// Three outcomes, not two. A module that is not this package's has no such
// facts and never will: `Ok` with none, and the spec answers alone as it did
// before any file was consulted. One of this package's that parses answers with
// what its source says. One of this package's that will not read or parse is
// `Error(Nil)`: the fast path declines the whole question rather than answer
// from the spec, because the full context would report the parse failure
// instead — and a fast-path answer is only correct if it is what the full
// context would have said.
fn module_source_facts(
  project_modules: Dict(String, String),
  module_path: String,
  package_targets: types.PackageTargets,
) -> Result(ModuleFacts, Nil) {
  case dict.get(project_modules, module_path) {
    Error(Nil) ->
      Ok(ModuleFacts(
        foreign: dict.new(),
        visibility: dict.new(),
        native: set.new(),
        callbacks: dict.new(),
        producers: set.new(),
      ))
    Ok(path) -> {
      use module <- result.map(
        read_and_parse_gleam(path) |> result.replace_error(Nil),
      )
      ModuleFacts(
        foreign: checker.foreign_functions(module, module_path, package_targets),
        visibility: dict.from_list([
          #(module_path, checker.function_visibility(module)),
        ]),
        native: checker.native_function_names(module, package_targets),
        callbacks: module_callback_params(module_path, module, package_targets),
        producers: producer_names(module),
      )
    }
  }
}

// The callback parameters of one parsed module's functions — what the full
// context reads off the whole-package registry, derived here from the single
// module a fast-path answer parses. Both fast-path halves take it from here, so
// neither can read a module's signatures differently from the other.
fn module_callback_params(
  module_path: String,
  module: glance.Module,
  package_targets: types.PackageTargets,
) -> Dict(QualifiedName, List(String)) {
  signatures.callback_param_names(built_registry(
    module_path,
    module,
    package_targets,
  ))
}

// The module's functions whose declared return type is a function — through the
// module's own type aliases too, by the same alias-aware reading the walk uses.
// A function with no return annotation is not one: the returns pass reads the
// declared type, so a body handing back a closure under no annotation carries
// no summary either.
fn producer_names(module: glance.Module) -> Set(String) {
  let aliases = signatures.type_alias_map(module.type_aliases)
  module.functions
  |> list.filter_map(fn(definition) {
    let function = definition.definition
    use return_type <- result.try(option.to_result(function.return, Nil))
    signatures.resolve_function_type(return_type, aliases)
    |> result.replace(function.name)
  })
  |> set.from_list
}

// Fold one module's source facts into a knowledge base, in the same three calls
// the full context makes over the whole package.
fn with_module_facts(
  knowledge_base: KnowledgeBase,
  facts: ModuleFacts,
) -> KnowledgeBase {
  knowledge_base
  |> effects.with_foreign_functions(facts.foreign)
  |> effects.with_project_functions(facts.visibility)
  |> effects.with_callback_params(facts.callbacks)
}

// Render `name` as an `effects` line, or `Error(Nil)` when it isn't a known
// qualified function. A function known to have `[Unknown]` effects is still a
// hit — only a name the knowledge base has never heard of misses.
fn function_effect(
  knowledge_base: KnowledgeBase,
  name: String,
) -> Result(EffectAnswer, Nil) {
  use #(module, function) <- result.try(annotation.split_function_name(name))
  let qualified = QualifiedName(module:, function:)
  // The command answers for the public API, so what this package's source says
  // about the name is settled before any entry is weighed — a hand-written line
  // for a private function, or for one no module defines, describes nothing the
  // package exports.
  use <- bool.guard(
    when: declined_by_publicity(knowledge_base, qualified),
    return: Error(Nil),
  )
  // Foreign code is answered by what declares it, exactly as `check` and `why`
  // answer for it: an entry inferred over an `@external`'s body describes
  // something the foreign implementation needn't match, so it is no answer here
  // either, however concrete it reads.
  //
  // A running Gleam fallback body travels with the answer either way: nothing
  // declares the external, but that body is ordinary code graded walked, and
  // `check` and `why` charge its effects — so the query states them too rather
  // than reporting a bare `[Unknown]` the other two disagree with.
  //
  // One derivation for all three halves — what the name charges, what a running
  // fallback contributed to that, and where the declaration stands in it — which
  // is what keeps the answer reading as `check` and `why` read the same name.
  let charge = effects.declared_charge(knowledge_base, qualified)
  let fallback = charge.fallback
  // The returns channel, read through the same gate a call site goes through:
  // a declaration out of reach, one with a running fallback beside it, and an
  // opaque value's inferred summary all answer nothing there, so an answer
  // that printed one would put this command at odds with `check` and `why` on
  // the same name. Derived once beside the charge, since all four answers
  // below are built from that charge.
  let returns =
    effects.lookup_returned_operator(knowledge_base, qualified)
    |> option.from_result
  // The bounds a running fallback body states its effects over: a fallback
  // that calls a function-typed parameter names that parameter, and without
  // its bound the line names a variable nothing introduces. They ride the
  // answers the fallback's body accounts for; the function-entry answer
  // instead takes `lookup_param_bounds`' full pairing, a declaring line's own
  // bounds included. A per-function bound from anywhere else was written over
  // a body the foreign implementation needn't match, exactly like the entry
  // beside it, so it is no more an answer here than that entry is.
  let fallback_bounds =
    effects.fallback_param_bounds(knowledge_base, qualified)
    |> list.filter(fn(bound) {
      !set.is_disjoint(
        effect_term.free_vars(bound.effects),
        effect_term.free_vars(charge.term),
      )
    })
  // A declaration this build reaches no part of accounts for none of the charge,
  // so the answer names neither it nor its source — the same clearing `check`
  // and `why` make when they charge the name. The lookup still holds the entry
  // that keyed it, and quoting that entry credited a dependency's shipped
  // `[Time]` line with the `[Unknown]` its being out of reach collapsed to.
  //
  // Asked ahead of what declares the name, as the walk asks it: an external that
  // is both undeclared and out of reach is out of reach first, and answering
  // that nothing declares it named a cause the other surfaces do not.
  use <- bool.guard(
    when: charge.declaration != effects.DeclarationCharged,
    return: Ok(
      answer.FunctionAnswer(
        name:,
        module:,
        bounds: fallback_bounds,
        term: charge.term,
        returns:,
        source: case charge.declaration {
          // The body running in the declaration's place is the whole of the
          // term, not a half added to it, so it is named as the source and not
          // beside one.
          effects.FallbackAnswersInstead -> answer.RunningFallbackBody
          effects.NothingImplementsName -> answer.UnreachedDeclaration
          // Excluded by the guard this branch sits under.
          effects.DeclarationCharged -> answer.UnreachedDeclaration
        },
      ),
    ),
  )
  use <- bool.guard(
    when: checker.undeclared_external(knowledge_base, qualified),
    return: Ok(answer.FunctionAnswer(
      name:,
      module:,
      bounds: fallback_bounds,
      term: charge.term,
      returns:,
      source: answer.UndeclaredExternal(fallback:),
    )),
  )
  case effects.lookup_declared(knowledge_base, qualified) {
    effects.Unknown -> Error(Nil)
    // Which map answered is reported by the lookup itself, so the recorded
    // source can't disagree with the term beside it.
    effects.Known(term, types.ModuleAssumeEntry(origin:)) ->
      Ok(answer.FunctionAnswer(
        name:,
        module:,
        // The full pairing, as the function-entry answer below takes: a
        // module-level `assume` states no bounds of its own, and where the
        // charge synthesized a callback variable for one of the module's
        // higher-order externals, the bound that scopes it is in this list and
        // in no other.
        bounds: effects.lookup_param_bounds(knowledge_base, qualified),
        term:,
        returns:,
        source: answer.Entry(types.ModuleAssumeEntry(origin:), fallback:),
      ))
    effects.Known(term, types.FunctionEntry(..) as source) ->
      Ok(answer.FunctionAnswer(
        name:,
        module:,
        bounds: effects.lookup_param_bounds(knowledge_base, qualified),
        term:,
        returns:,
        source: answer.Entry(source, fallback:),
      ))
  }
}

// Whether `graded effect` must decline `name` whatever the knowledge base holds.
//
// The command answers for the public API: a private function is not part of it,
// and neither is a name this package's source never defines — a typo in a spec
// line names nothing, however precise its effect set reads. Both are refusals
// the entries themselves cannot express, since a hand-written line for a private
// function and one for a real public function are the same line.
//
// This outranks the module-level-external carve-out. `assume <module>`
// answers for every name in its module, which is what a module graded has no
// source for needs — but where the source *is* here, a declaration describes
// behaviour for callers; it does not export a name. Nothing about how callers
// resolve either name changes.
fn declined_by_publicity(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Bool {
  case effects.project_visibility(knowledge_base, name) {
    effects.ProjectFunction(visibility: types.Internal)
    | effects.NotProjectFunction -> True
    effects.ProjectFunction(visibility: types.Exported)
    | effects.NoProjectEvidence -> False
  }
}

// Render `name` as a field `assume` line, or `Error(Nil)` when it isn't a declared type
// field. `name` is split by the same grammar that parses a field `assume` line, so both
// declared forms can be queried back: `module.Type.field` and the bare
// `Type.field` of a cache file.
//
// A bare line is keyed under no module, so a qualified query falls back to the
// `""` key rather than reporting a field the spec plainly declares as missing.
// Resolving a *call* still needs the module — a receiver's nominal type always
// carries one, which is why `graded check` warns that a bare line is dead — but
// the query answers what the spec says, and says it in the form that declared
// it.
fn type_field_effect(
  knowledge_base: KnowledgeBase,
  name: String,
) -> Result(EffectAnswer, Nil) {
  use #(module, type_name, field) <- result.try(
    annotation.split_type_field_name(name),
  )
  let declared = case module {
    Some(module) ->
      case effects.lookup_type_field(knowledge_base, module, type_name, field) {
        Ok(type_field) -> Ok(#(Some(module), type_field))
        Error(Nil) -> bare_type_field(knowledge_base, type_name, field)
      }
    None -> bare_type_field(knowledge_base, type_name, field)
  }
  use #(declared_module, type_field) <- result.try(declared)
  Ok(answer.TypeFieldAnswer(
    module: declared_module,
    type_name:,
    field:,
    term: type_field.effects,
    origin: type_field.origin,
  ))
}

// A bare `type Type.field` line, keyed under no module.
fn bare_type_field(
  knowledge_base: KnowledgeBase,
  type_name: String,
  field: String,
) -> Result(#(Option(String), types.TypeFieldEffect), Nil) {
  effects.lookup_type_field(knowledge_base, "", type_name, field)
  |> result.map(fn(type_field) { #(None, type_field) })
}

// Explanations
//
// The `why` command: re-walk one function's body and report every effect
// contributor the checker reaches, with the vocabulary violations already use.
// Writes nothing.

/// Explain where one function's effects come from, as prose.
///
/// `name` is a module-qualified function in one of this project's own modules
/// (`myapp/router.handle`) — `why` re-walks a body, so there has to be one.
/// Private functions are accepted: the walk is over source this project holds,
/// unlike `run_effect`, which answers from the public knowledge base.
///
/// The output holds one block per `check` line declared for the function, each
/// with that line's own bounds fed to the analysis, in spec-file order — two
/// `check` lines can substitute the same body differently, so neither block
/// speaks for the other. With no `check` line there is one block, analysed with
/// no bounds. A block states the function's total effect, the `check` line it
/// came from (informationally — the subset verdict is `graded check`'s), and one
/// line per contributing call: what the call is, the effects it contributes, and
/// either why they stayed unresolved or which source resolved them.
///
/// Contributors are the calls the checker reaches, not the call sites written
/// in the body: a resolved call to a same-module function is replaced by that
/// function's own calls, so those surface instead, at spans inside it.
///
/// Returns `FunctionNotFound` when the name isn't a function of a project
/// module. Nothing is written to disk.
pub fn run_why(directory: String, name: String) -> Result(String, GradedError) {
  use #(module_path, function) <- result.try(
    annotation.split_function_name(name)
    |> result.replace_error(FunctionNotFound(name)),
  )
  // The name is settled against the parsed sources alone: a name this project
  // does not define is not found without paying for the dependency scan, the
  // package-wide girard run and the knowledge base the explanation needs.
  use sources <- result.try(load_project_sources(directory))
  use #(_gleam_path, module) <- result.try(
    dict.get(sources.index, module_path)
    |> result.replace_error(FunctionNotFound(name)),
  )
  use <- bool.guard(
    when: !defines_function(module, function),
    return: Error(FunctionNotFound(name)),
  )
  use ctx <- result.try(project_context(sources))
  why_in(ctx, module, module_path, function, name)
}

// `graded why` for each of `names`, against one project context.
@internal
pub fn run_why_each(
  directory: String,
  names: List(String),
) -> Result(List(#(String, Result(String, GradedError))), GradedError) {
  use sources <- result.try(load_project_sources(directory))
  use ctx <- result.map(project_context(sources))
  list.map(names, fn(name) {
    #(name, {
      use #(module_path, function) <- result.try(
        annotation.split_function_name(name)
        |> result.replace_error(FunctionNotFound(name)),
      )
      use #(_gleam_path, module) <- result.try(
        dict.get(sources.index, module_path)
        |> result.replace_error(FunctionNotFound(name)),
      )
      use <- bool.guard(
        when: !defines_function(module, function),
        return: Error(FunctionNotFound(name)),
      )
      why_in(ctx, module, module_path, function, name)
    })
  })
}

fn why_in(
  ctx: ProjectContext,
  module: glance.Module,
  module_path: String,
  function: String,
  name: String,
) -> Result(String, GradedError) {
  // Straight from the spec's `check` lines rather than the per-module grouping
  // `run` builds, whose lists are prepend-reversed — the blocks are printed in
  // the order the spec declares them. A function with no line still gets one
  // block, analysed with no bounds. Matched by the same split `run` groups them
  // by, so one function's lines are the same set to both commands.
  let checks = case
    annotation.extract_checks(ctx.sources.spec)
    |> list.filter(fn(ann) {
      annotation.split_function_name(ann.function)
      == Ok(#(module_path, function))
    })
  {
    [] -> [None]
    checks -> list.map(checks, Some)
  }
  // Explained on every target that builds the function, each in its own
  // context, and stated once: the joined total, each contributor beside the
  // targets it comes from.
  let contexts = case ctx.per_target {
    [] -> [#(None, ctx)]
    contexts ->
      list.filter_map(contexts, fn(entry) {
        case reads_on(ctx.builds, name, entry.0) {
          True -> Ok(#(Some(entry.0), entry.1))
          False -> Error(Nil)
        }
      })
  }
  let explained =
    list.filter_map(contexts, fn(entry) {
      let #(target, ctx) = entry
      // Read in the parameter names of the definition built on that target,
      // and stated in the published ones.
      let variant =
        option.to_result(target, Nil)
        |> result.try(checker.target_variant(module, function, _))
      let bounds =
        list.map(checks, fn(check) {
          option.map(check, fn(line) {
            case variant {
              Ok(#(variants, definition)) ->
                checker.in_variant_names(variants, definition, line)
              Error(Nil) -> line
            }
          })
          |> check_bounds
        })
      checker.explain(
        module,
        module_path,
        function,
        bounds,
        ctx.knowledge_base,
        ctx.registry,
        typeinfo.reading_for_module(ctx.type_info, module_path),
        ctx.sources.cfg.targets,
      )
      |> result.map(fn(explained) {
        case variant {
          Ok(#(variants, definition)) ->
            checker.explained_in_published_names(
              variants,
              definition,
              explained,
            )
          Error(Nil) -> explained
        }
      })
      |> result.map(fn(result) { #(target, result) })
    })
  use <- bool.guard(
    when: explained == [],
    return: Error(FunctionNotFound(name)),
  )
  let classifications =
    list.flat_map(explained, fn(entry) { { entry.1 }.classifications })
    |> list.unique
  let rendered =
    list.index_map(checks, fn(check, index) {
      let blocks =
        list.filter_map(explained, fn(entry) {
          list.drop({ entry.1 }.blocks, index)
          |> list.first
          |> result.map(fn(block) { #(entry.0, block) })
        })
      why_block(
        name,
        check,
        list.flat_map(blocks, fn(entry) { { entry.1 }.bounds }) |> list.unique,
        effect_term.normalize(
          types.TUnion(list.map(blocks, fn(entry) { { entry.1 }.total })),
        ),
        list.map(blocks, fn(entry) { #(entry.0, { entry.1 }.explanations) }),
      )
    })
  // After the blocks and once, not per block: the resolutions are a property of
  // the body, which every block explains the same one of.
  case classifications {
    [] -> rendered
    checks -> list.append(rendered, [typed_resolution_block(checks)])
  }
  |> string.join("\n\n")
  |> Ok
}

// What girard resolved each ambiguous call in the body to, beside what graded
// charged it as. Only the sites lexically in the named function: a contributor
// reached through a same-module call is one `why` on that callee away, and its
// resolutions belong to its own body.
fn typed_resolution_block(
  classifications: List(types.ClassificationCheck),
) -> String {
  [
    "typed resolutions",
    ..list.map(classifications, fn(check) {
      "  " <> checker.format_typed_resolution(check)
    })
  ]
  |> string.join("\n")
}

// Whether the module defines a function by this name. Publicity is not
// consulted: `why` walks a body this project holds, so a private function is
// explained as a public one is.
fn defines_function(module: glance.Module, function: String) -> Bool {
  list.any(module.functions, fn(definition) {
    definition.definition.name == function
  })
}

// The bounds a block is analysed under: the `check` line's own, or none.
fn check_bounds(check: Option(EffectAnnotation)) -> List(types.ParamBound) {
  case check {
    Some(ann) -> ann.params
    None -> []
  }
}

// Each target's lines joined in order, each beside the targets that state it:
// the `n`th time a target states a line is the `n`th time the join does.
fn joined_by_target(
  per_target: List(#(Option(String), List(String))),
) -> List(#(String, List(String))) {
  let #(order, tags) =
    list.fold(per_target, #([], dict.new()), fn(acc, entry) {
      let #(target, lines) = entry
      let #(acc, _seen) =
        list.fold(lines, #(acc, dict.new()), fn(state, line) {
          let #(#(order, tags), seen) = state
          let nth = dict.get(seen, line) |> result.unwrap(0)
          let key = #(line, nth)
          let order = case dict.has_key(tags, key) {
            True -> order
            False -> [key, ..order]
          }
          let tags =
            dict.upsert(tags, key, fn(existing) {
              list.append(option.unwrap(existing, []), option.values([target]))
            })
          #(#(order, tags), dict.insert(seen, line, nth + 1))
        })
      acc
    })
  list.reverse(order)
  |> list.map(fn(key) { #(key.0, dict.get(tags, key) |> result.unwrap([])) })
}

// One `check` line's explanation: the function's total effect, the declaration
// the analysis ran under, and its contributors. `bounds` are the ones the walk
// actually substituted — declared plus synthesised — as `explain` returned
// them, and `total` is the block's effect as a term: the per-call explanations
// ground each effect for printing, which concretizes a still-symbolic operator
// application to `[Unknown]`, so a total rebuilt from them would misstate a
// second-order function the spec's inferred line states symbolically.
fn why_block(
  name: String,
  check: Option(EffectAnnotation),
  bounds: List(types.ParamBound),
  total: types.EffectTerm,
  per_target: List(#(Option(String), List(types.CallExplanation))),
) -> String {
  // The sentence `graded effect` states a total in, bounds included, so the two
  // commands describe one function's effects in one wording — a total that is
  // exactly a callback's variable reads as forwarding that argument, not as an
  // effect named after it.
  let header = answer.function_sentence(name, bounds, total)
  // The whole declaration, bounds included: two `check` lines can share a budget
  // and differ only in what they bind, and the budget alone wouldn't say which
  // block is which.
  let declaration = case check {
    Some(ann) -> ["declared " <> annotation.format_annotation(ann)]
    None -> []
  }
  // Not "makes no calls": a caller of a pure local helper does call something —
  // the helper contributes no effects, so nothing of it is reached.
  // Each target's contributors in order, where the package was read on several
  // one at a time: a line every target states as often is stated once, beside
  // the targets it comes from.
  let joined =
    list.map(per_target, fn(entry) {
      #(entry.0, list.map(entry.1, checker.format_call_explanation))
    })
    |> joined_by_target
  let lines = case joined {
    [] -> ["  has no reachable effect contributors"]
    joined ->
      list.map(joined, fn(entry) {
        case entry.1 {
          [] -> "  " <> entry.0
          on -> "  " <> entry.0 <> " (on " <> string.join(on, ", ") <> ")"
        }
      })
  }
  list.flatten([[header], declaration, lines])
  |> string.join("\n")
}

// Catalog
//
// The `catalog` command: what graded's own bundled `priv/catalog/` holds. The
// listing marks the file each installed package resolves to; the show forms
// print one file verbatim under a header naming it and why it was chosen.

/// List the bundled catalog: one `package@version` line per bundled file,
/// sorted, with a comment on the line each installed package of the project
/// the process runs in resolves to.
///
/// This is graded's bundled catalog alone: a dependency's shipped spec, a path
/// dependency's spec and your own `assume` all override it, so `run_effect` is
/// what answers which source wins for a name. Nothing is written to disk.
pub fn catalog_list() -> Result(String, GradedError) {
  run_catalog(cli.ListCatalog)
}

/// Print one bundled catalog file for `package`, under a `//` header line
/// saying which file it is and why — so the output is itself a valid `.graded`
/// file. `version` names a bundled version exactly; `None` selects the one
/// `directory`'s project installs. Nothing is written to disk.
pub fn catalog_show(
  package: String,
  version: option.Option(String),
  directory: String,
) -> Result(String, GradedError) {
  run_catalog(cli.ShowCatalog(package:, version:, directory:))
}

// Coverage
//
// What the type inference could and could not read of one package, printed.
// Read-only, decides nothing and always succeeds with exit code 0: `check` is
// the command that fails, and a report whose content is not a property of the
// user's code has no business being a CI gate.
//
// Built from the context `check` builds and from the rows `why` prints, so it
// cannot disagree with either — and `@internal` rather than public, because a
// diagnostic's output format is the kind of surface a 1.0 should not freeze.
@internal
pub fn run_coverage(directory: String) -> Result(String, GradedError) {
  use ctx <- result.map(load_project_context(directory))
  let rows = context_classification_checks(ctx)
  let ProjectContext(sources:, typed_path_dependencies:, ..) = ctx
  // Where the package was read on several targets one at a time, what girard
  // read of it on all of them, merged from the runs each target shared.
  let type_info = case ctx.per_target {
    [] -> ctx.type_info
    _ ->
      type_index(
        sources.index,
        ctx.dep_files,
        sources.cfg.targets,
        dependency_target_variants(sources.index, ctx.dependencies),
        ctx.girard_runs,
      )
  }
  let package_root = sources.package_root
  let modules = package_modules(sources)
  let unread = unread_modules(modules, type_info)
  coverage.render(coverage.CoverageReport(
    versions: coverage.Versions(
      observed: observed_versions(),
      manifest_girard: dict.get(
        effects.manifest_versions(manifest_path(package_root)),
        "girard",
      )
        |> option.from_result(),
    ),
    targets: set.to_list(types.build_targets(sources.cfg.targets))
      |> list.sort(string.compare),
    targets_source: sources.cfg.targets_source,
    ran_on: list.map(type_info.targets, typeinfo.target_name),
    modules_read: list.length(modules) - unread,
    modules_unread: unread,
    functions: definition_counts(modules, type_info, function_locations),
    constants: definition_counts(modules, type_info, constant_locations),
    calls: call_counts(rows),
    skipped: skipped_definitions(modules, type_info),
    undecided: listed_sites(sources.index, rows, is_undecided),
    no_typed_evidence: listed_sites(
      sources.index,
      rows,
      is_without_typed_evidence,
    ),
    disagreements: listed_sites(sources.index, rows, is_disagreement),
    mismatches: listed_sites(sources.index, rows, is_identity_mismatch),
    unfilled_modules: set.to_list(type_info.unfilled)
      |> list.sort(string.compare),
    path_dependencies: typed_path_dependencies,
  ))
}

// Every module this package declares, in source order, each beside the path the
// inference keyed it under. The join between glance's files and the type index
// is made here once and handed to every count and listing below.
fn package_modules(
  sources: ProjectSources,
) -> List(#(String, String, glance.Module)) {
  list.map(sources.parsed, fn(entry) {
    let #(gleam_path, module) = entry
    #(
      config.module_path_for_source(gleam_path, sources.source_directory),
      gleam_path,
      module,
    )
  })
}

// The modules the inference returned no result for, among the ones this package
// declares.
fn unread_modules(
  modules: List(#(String, String, glance.Module)),
  type_info: typeinfo.TypeInfo,
) -> Int {
  list.count(modules, fn(entry) { set.contains(type_info.absent, entry.0) })
}

fn function_locations(module: glance.Module) -> List(glance.Span) {
  list.map(module.functions, fn(definition) {
    { definition.definition }.location
  })
}

fn constant_locations(module: glance.Module) -> List(glance.Span) {
  list.map(module.constants, fn(definition) {
    { definition.definition }.location
  })
}

// One kind of definition counted across the package: within a module the
// inference read, each is exactly one of typed, skipped or left out; an unread
// module's are unread and in no other count.
fn definition_counts(
  modules: List(#(String, String, glance.Module)),
  type_info: typeinfo.TypeInfo,
  locations_of: fn(glance.Module) -> List(glance.Span),
) -> coverage.DefinitionCounts {
  use counts, entry <- list.fold(
    modules,
    coverage.DefinitionCounts(typed: 0, skipped: 0, left_out: 0, unread: 0),
  )
  let #(module_path, _gleam_path, module) = entry
  let locations = locations_of(module)
  case set.contains(type_info.absent, module_path) {
    True ->
      coverage.DefinitionCounts(
        ..counts,
        unread: counts.unread + list.length(locations),
      )
    False -> {
      let evidence = typeinfo.evidence_for_module(type_info, module_path)
      use counts, location <- list.fold(locations, counts)
      case typeinfo.standing_of(evidence, location) {
        typeinfo.LeftOut ->
          coverage.DefinitionCounts(..counts, left_out: counts.left_out + 1)
        typeinfo.Skipped(..) ->
          coverage.DefinitionCounts(..counts, skipped: counts.skipped + 1)
        typeinfo.Typed ->
          coverage.DefinitionCounts(..counts, typed: counts.typed + 1)
      }
    }
  }
}

// Every ambiguous call in exactly one provenance class, with the disagreements
// counted beside rather than within.
fn call_counts(rows: List(types.ClassificationCheck)) -> coverage.CallCounts {
  coverage.CallCounts(
    decided: list.count(rows, fn(row) {
      coverage.provenance_class(row) == coverage.DecidedByInference
    }),
    // The inference answered — agreeing or not. A lexical row it contradicts
    // is counted here and again under `disagreements`, which is the count that
    // states the verdict.
    lexical_with_evidence: list.count(rows, fn(row) {
      coverage.provenance_class(row) == coverage.SettledLexically
      && !without_evidence(row)
    }),
    lexical_no_evidence: list.count(rows, is_lexical_without_evidence),
    wired: list.count(rows, fn(row) {
      coverage.provenance_class(row) == coverage.WiredFromConstruction
    }),
    undecided: list.count(rows, is_undecided),
    disagreements: list.count(rows, is_disagreement),
  )
}

fn without_evidence(row: types.ClassificationCheck) -> Bool {
  case checker.relate(row) {
    types.NoTypedEvidence(..) -> True
    types.Compared(..) -> False
  }
}

fn is_undecided(row: types.ClassificationCheck) -> Bool {
  coverage.provenance_class(row) == coverage.Undecided
}

fn is_lexical_without_evidence(row: types.ClassificationCheck) -> Bool {
  coverage.provenance_class(row) == coverage.SettledLexically
  && without_evidence(row)
}

// A row charged with the inference having answered nothing at all. Both the
// classes a call can be charged from without an answer reach it — settled
// lexically, and wired from a construction — and each still counts in its own
// class, so the listing cuts across the partition rather than redrawing it.
fn is_without_typed_evidence(row: types.ClassificationCheck) -> Bool {
  case coverage.provenance_class(row) {
    coverage.SettledLexically | coverage.WiredFromConstruction ->
      without_evidence(row)
    coverage.DecidedByInference | coverage.Undecided -> False
  }
}

fn is_disagreement(row: types.ClassificationCheck) -> Bool {
  checker.relate(row) == types.Compared(types.Disagree)
}

// A row graded refused because the resolution did not name this site. It counts
// once, under undecided, and is listed again because a mismatch is the finding
// the listing exists for.
fn is_identity_mismatch(row: types.ClassificationCheck) -> Bool {
  case row.graded {
    types.UndecidedShadowed(reason: types.ResolutionMismatch(..), ..) -> True
    _ -> False
  }
}

// Every definition the inference declined, with where it sits. A skip naming no
// definition the module declares keeps its name and its bucket and no location.
fn skipped_definitions(
  modules: List(#(String, String, glance.Module)),
  type_info: typeinfo.TypeInfo,
) -> List(coverage.SkippedDefinition) {
  use entry <- list.flat_map(modules)
  let #(module_path, gleam_path, module) = entry
  let evidence = typeinfo.evidence_for_module(type_info, module_path)
  // Read only for a module that has a skip to place, and read once for both
  // kinds rather than once per skip.
  let source = case dict.is_empty(evidence.skipped) {
    True -> Error(Nil)
    False -> simplifile.read(gleam_path) |> result.replace_error(Nil)
  }
  let placed =
    list.append(
      skipped_of(
        module_path,
        gleam_path,
        source,
        evidence,
        coverage.Function,
        list.map(module.functions, fn(definition) {
          #({ definition.definition }.name, { definition.definition }.location)
        }),
      ),
      skipped_of(
        module_path,
        gleam_path,
        source,
        evidence,
        coverage.Constant,
        list.map(module.constants, fn(definition) {
          #({ definition.definition }.name, { definition.definition }.location)
        }),
      ),
    )
  list.append(
    placed,
    list.map(evidence.unlocated, fn(entry) {
      coverage.SkippedDefinition(
        path: module_path <> "." <> entry.0,
        location: None,
        kind: coverage.Function,
        bucket: entry.1,
      )
    }),
  )
}

fn skipped_of(
  module_path: String,
  gleam_path: String,
  source: Result(String, Nil),
  evidence: typeinfo.ModuleEvidence,
  kind: coverage.DefinitionKind,
  definitions: List(#(String, glance.Span)),
) -> List(coverage.SkippedDefinition) {
  use #(name, location) <- list.filter_map(definitions)
  use bucket <- result.map(
    typeinfo.skip_reason(evidence.skipped, location.start, location.end)
    |> option.to_result(Nil),
  )
  coverage.SkippedDefinition(
    path: module_path <> "." <> name,
    location: Some(site_location(gleam_path, source, location.start)),
    kind:,
    bucket:,
  )
}

// The rows one listing shows, each with its source coordinates and the wording
// `check` and `why` use for the same site.
fn listed_sites(
  index: Dict(String, #(String, glance.Module)),
  rows: List(types.ClassificationCheck),
  keep: fn(types.ClassificationCheck) -> Bool,
) -> List(coverage.SiteRow) {
  // A listing can hold many rows in one module; the memo keeps each file to a
  // single read rather than one per row.
  let #(_sources, listed) =
    list.fold(list.filter(rows, keep), #(dict.new(), []), fn(acc, row) {
      let #(sources, listed) = acc
      case dict.get(index, row.module) {
        Error(Nil) -> acc
        Ok(#(gleam_path, _module)) -> {
          let #(sources, source) = source_text(sources, gleam_path)
          #(sources, [
            coverage.SiteRow(
              module: row.module,
              function: row.function,
              site: row.object <> "." <> row.label,
              location: site_location(gleam_path, source, row.span.start),
              detail: checker.typed_resolution_detail(row),
            ),
            ..listed
          ])
        }
      }
    })
  list.reverse(listed)
}

// One file's text out of the memo, reading it the first time it is asked for.
fn source_text(
  sources: Dict(String, Result(String, Nil)),
  gleam_path: String,
) -> #(Dict(String, Result(String, Nil)), Result(String, Nil)) {
  case dict.get(sources, gleam_path) {
    Ok(source) -> #(sources, source)
    Error(Nil) -> {
      let source = simplifile.read(gleam_path) |> result.replace_error(Nil)
      #(dict.insert(sources, gleam_path, source), source)
    }
  }
}

// `path:line:column` for one byte offset. The source is read at the listing, in
// a read-only command, rather than kept in the context for a listing that is
// usually empty; an unreadable file leaves the path bare.
fn site_location(
  gleam_path: String,
  source: Result(String, Nil),
  offset: Int,
) -> String {
  case source {
    Ok(source) -> gleam_path <> ":" <> coverage.coordinates(source, offset)
    Error(Nil) -> gleam_path
  }
}

// One typed path dependency's own reading, counted the way the package's is.
// Counted where the reading is made, so the reading itself need not be held for
// the rest of the run.
fn path_dependency_row(
  package: String,
  type_info: typeinfo.TypeInfo,
) -> coverage.PathDependency {
  coverage.PathDependency(
    package:,
    ran_on: list.map(type_info.targets, typeinfo.target_name),
    unread_modules: set.size(type_info.absent),
    skipped: dict.fold(type_info.evidence, 0, fn(total, _path, evidence) {
      total + dict.size(evidence.skipped) + list.length(evidence.unlocated)
    }),
    left_out: dict.fold(type_info.evidence, 0, fn(total, _path, evidence) {
      total + set.size(evidence.dropped)
    }),
  )
}

// The two forms behind `catalog_list` and `catalog_show`, over the CLI's own
// decoded request so `main` dispatches without rebuilding it.
@internal
pub fn run_catalog(request: cli.CatalogRequest) -> Result(String, GradedError) {
  use manifest <- result.try(case request {
    // The listing takes no directory of its own, so it walks up from the one
    // the process runs in.
    cli.ListCatalog -> Ok(catalog_manifest_path(working_directory()))
    cli.ShowCatalog(directory:, ..) -> {
      use _ <- result.map(read_directory(directory))
      catalog_manifest_path(directory)
    }
  })
  use catalog_dir <- result.try(bundled_catalog_directory())
  catalog_report(catalog_dir, manifest, request)
}

// graded's bundled catalog, selected against the manifest of the package at
// `package_root`, for a command that resolves calls against it. Every such
// command stops here when the catalog can't be read: without it each call the
// catalog covers would answer `[Unknown]`.
fn load_bundled_catalog(
  package_root: String,
  reading: effects.SpecReading,
) -> Result(effects.BundledCatalog, GradedError) {
  use files <- result.map(locate_bundled_catalog())
  read_bundled_catalog(files, package_root, reading)
}

// The bundled catalog's files, read before anything else so a run without a
// catalog fails before it builds anything.
fn locate_bundled_catalog() -> Result(List(effects.CatalogFile), GradedError) {
  use catalog_dir <- result.try(bundled_catalog_directory())
  catalog_files(catalog_dir)
}

// The catalog files selected for this package's installed versions, read.
fn read_bundled_catalog(
  files: List(effects.CatalogFile),
  package_root: String,
  reading: effects.SpecReading,
) -> effects.BundledCatalog {
  effects.load_project_catalog(files, manifest_path(package_root), reading)
}

// How the specs other packages wrote, and the bundled catalog, are read in a
// run: a line whose bounds the latent-effect rules forbid, once the run's
// signatures and types are known, is refused.
fn spec_reading(
  registry: SignatureRegistry,
  readings: Dict(#(String, String), PairReading),
) -> effects.SpecReading {
  effects.SpecReading(
    refuses: fn(assume) { contract.line_violations(assume, registry) != [] },
    rebase: fn(source, file) { rebased_pair_lines(file, readings, source) },
  )
}

// The project's own lines over a function a dependency defines once per
// target, in the variant the run builds, as the dependency's own lines are;
// each of `refused` stands in as `assume <path> : [_]`.
fn rebased_consumer_lines(
  spec: GradedFile,
  readings: Dict(#(String, String), PairReading),
  refused: List(OwnViolation),
) -> GradedFile {
  rebased_pair_lines(spec, readings, effects.ConsumerLines)
  |> annotation.replace_lines_by_path(
    list.filter_map(refused, fn(violation) {
      annotation.blocker_for_path(violation.path) |> option.to_result(Nil)
    }),
  )
}

// One of the project's own `assume` lines as the run reads it: in the variant
// the run builds where it is over a function a dependency defines once per
// target, as written otherwise.
fn consumer_view(
  readings: Dict(#(String, String), PairReading),
) -> fn(types.AssumeAnnotation) -> checker.ReaderView {
  fn(assume: types.AssumeAnnotation) {
    case assume.target {
      types.FunctionAssume(name:) ->
        case dict.get(readings, #(assume.module, name)) {
          Ok(PairReading(parameters: Ok(#(from, to)), ..)) ->
            checker.rebased_assume_view(from, to, assume)
          _ -> checker.as_written(assume)
        }
      types.ModuleAssume -> checker.as_written(assume)
    }
  }
}

// How a run reads a line over a function a dependency defines once per
// target: from the parameters the dependency publishes in, those of the
// variant its own target configuration selects, to those of the variant the
// run builds, beside whether that configuration covers the run's targets.
type PairReading {
  PairReading(
    covered: Bool,
    parameters: Result(
      #(List(glance.FunctionParameter), List(glance.FunctionParameter)),
      Nil,
    ),
  )
}

// The targets each package holding a module that defines a public function
// once per target publishes for, by package root, beside `known`: each
// package's configuration is read once per run.
fn publisher_configurations(
  dependencies: DependencySources,
  known: Dict(String, types.PackageTargets),
) -> Dict(String, types.PackageTargets) {
  use acc, module_path, scanned <- dict.fold(dependencies.modules, known)
  case scanned {
    ParsedModule(pairs:, source_path:, ..) ->
      case dict.is_empty(pairs) {
        True -> acc
        False -> {
          let root = dependency_root(source_path, module_path)
          case dict.has_key(acc, root) {
            True -> acc
            False -> dict.insert(acc, root, publisher_targets(root))
          }
        }
      }
    UnreadableModule -> acc
  }
}

// Every public function a dependency module defines once per target, by
// module path and name, with how a run on `reader` reads a line over it, its
// package's targets read from `publishers`.
fn pair_readings(
  dependencies: DependencySources,
  reader: types.PackageTargets,
  publishers: Dict(String, types.PackageTargets),
) -> Dict(#(String, String), PairReading) {
  use acc, module_path, scanned <- dict.fold(dependencies.modules, dict.new())
  case scanned {
    ParsedModule(pairs:, source_path:, ..) ->
      case dict.is_empty(pairs) {
        True -> acc
        False -> {
          let root = dependency_root(source_path, module_path)
          let publisher =
            dict.get(publishers, root)
            |> result.lazy_unwrap(fn() { publisher_targets(root) })
          let covered =
            set.is_subset(
              types.build_targets(reader),
              types.build_targets(publisher),
            )
          use acc, name, variants <- dict.fold(pairs, acc)
          let parameters = {
            use from <- result.try(checker.publisher_parameters(
              variants,
              publisher,
            ))
            use to <- result.map(checker.reader_parameters(variants, reader))
            #(from, to)
          }
          dict.insert(
            acc,
            #(module_path, name),
            PairReading(covered:, parameters:),
          )
        }
      }
    UnreadableModule -> acc
  }
}

// The lines `source` wrote over a function a dependency defines once per
// target, moved from the parameters the dependency publishes in to those of
// the variant the run builds, each through `checker.rebased_line` or
// `checker.rebased_assume`. A line the dependency's own spec states describes
// only the variants that package was read on: a run on a target its
// configuration does not cover drops it, and the function answers as one
// nothing declares.
fn rebased_pair_lines(
  file: GradedFile,
  readings: Dict(#(String, String), PairReading),
  source: effects.LineSource,
) -> GradedFile {
  use <- bool.guard(when: dict.is_empty(readings), return: file)
  let read = fn(line, module_path, name, rebased) {
    case dict.get(readings, #(module_path, name)), source {
      Error(Nil), _ -> Ok(line)
      Ok(PairReading(covered: False, ..)), effects.DependencySpecLines ->
        Error(Nil)
      Ok(PairReading(parameters: Ok(#(from, to)), ..)), _ ->
        Ok(rebased(from, to))
      Ok(PairReading(parameters: Error(Nil), ..)), _ -> Ok(line)
    }
  }
  GradedFile(
    lines: list.filter_map(file.lines, fn(line) {
      case line {
        AnnotationLine(annotation: ann, ..) ->
          case annotation.split_function_name(ann.function) {
            Ok(#(module_path, name)) ->
              read(line, module_path, name, fn(from, to) {
                AnnotationLine(
                  ..line,
                  annotation: checker.rebased_line(from, to, ann),
                )
              })
            Error(Nil) -> Ok(line)
          }
        types.AssumeLine(
          assume: types.AssumeAnnotation(
            module:,
            target: types.FunctionAssume(name:),
            ..,
          ) as assume,
          ..,
        ) ->
          read(line, module, name, fn(from, to) {
            types.AssumeLine(
              ..line,
              assume: checker.rebased_assume(from, to, assume),
            )
          })
        _ -> Ok(line)
      }
    }),
  )
}

// One of the project's own `assume` lines whose bounds the latent-effect rules
// forbid: its place in the spec, its path, the statement as written and what
// it breaks, stated in the line's own names.
type OwnViolation {
  OwnViolation(line: Int, path: String, statement: String, description: String)
}

// The project's own `assume` lines whose bounds the latent-effect rules forbid
// once kinds are known, each read as the run reads it: in the variant the run
// builds where it is over a function a dependency defines once per target.
// Only the first where `first_only`: a run alone on its targets stops on it.
// Each is quoted from its own place in the spec, read once where any is
// found.
fn own_contract_violations(
  spec: GradedFile,
  spec_text: String,
  readings: Dict(#(String, String), PairReading),
  registry: SignatureRegistry,
  first_only: Bool,
) -> List(OwnViolation) {
  let in_reader_variant = consumer_view(readings)
  let finding = fn(entry: #(types.GradedLine, Int)) {
    case entry.0 {
      types.AssumeLine(assume:, ..) -> {
        let view = in_reader_variant(assume)
        case contract.line_violations(view.line, registry) {
          [] -> Error(Nil)
          [violation, ..] ->
            Ok(#(
              entry.1,
              assume,
              contract.stated_in(violation, view.parameter, view.variable)
                |> contract.describe,
            ))
        }
      }
      _ -> Error(Nil)
    }
  }
  let entries = list.index_map(spec.lines, fn(line, index) { #(line, index) })
  let found = case first_only {
    True ->
      list.find_map(entries, finding)
      |> result.map(list.wrap)
      |> result.unwrap([])
    False -> list.filter_map(entries, finding)
  }
  // Each quoted from its own place in the spec, in one pass over it.
  let statements = case found {
    [] -> []
    _ -> annotation.statements_at(spec_text, list.map(found, fn(one) { one.0 }))
  }
  list.zip(found, statements)
  |> list.map(fn(pair) {
    let #(#(line, assume, description), statement) = pair
    let statement = case statement {
      Some(#(line_number, text)) -> int.to_string(line_number) <> ": " <> text
      None -> annotation.format_assume(assume)
    }
    OwnViolation(
      line:,
      path: annotation.assume_name(assume),
      statement:,
      description:,
    )
  })
}

// What one of several runs reports of the lines it refused: those over
// functions it builds a definition of, or that no target of the run builds. A
// line over a function only another target builds is refused here, and the
// verdict on it is the other targets'.
fn reported_refusals(
  refused: List(OwnViolation),
  builds: PackageBuilds,
  dependencies: DependencySources,
  package_targets: types.PackageTargets,
) -> List(OwnViolation) {
  list.filter(refused, fn(violation) {
    reads_line_on(builds, dependencies, violation.path, package_targets)
  })
}

// The error a run on one target reports for the first of its own lines it
// cannot read.
fn own_contract_error(
  spec_path: String,
  violations: List(OwnViolation),
) -> Result(Nil, GradedError) {
  case violations {
    [] -> Ok(Nil)
    [first, ..] ->
      Error(GradedParseError(
        path: spec_path,
        message: first.statement <> "\n  " <> first.description,
      ))
  }
}

// What runs on several targets one at a time do with the project's own lines
// some of them refused, each beside the target that refused it, weighed on the
// targets that read each line, `readers` of its path: a line every one of them
// refused is an error naming them, and one only some refused is read on the
// others, with a warning naming the ones that did not.
fn settle_own_refusals(
  spec_path: String,
  refused: List(#(String, List(OwnViolation))),
  readers: fn(String) -> List(String),
) -> Result(Nil, GradedError) {
  let by_line =
    list.fold(refused, dict.new(), fn(acc, entry) {
      let #(target, violations) = entry
      list.fold(violations, acc, fn(acc, violation) {
        dict.upsert(acc, violation.line, fn(existing) {
          list.append(option.unwrap(existing, []), [#(target, violation)])
        })
      })
    })
  let lines =
    dict.to_list(by_line)
    |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
    |> list.map(fn(entry) { entry.1 })
  let everywhere =
    list.find(lines, fn(refusals) {
      case refusals {
        [] -> False
        [#(_, first), ..] ->
          list.length(
            list.unique(list.map(refusals, fn(refusal) { refusal.0 })),
          )
          == list.length(readers(first.path))
      }
    })
  case everywhere {
    Ok([#(_, first), ..] as refusals) ->
      Error(GradedParseError(
        path: spec_path,
        message: first.statement <> explained_refusals(refusals),
      ))
    _ -> {
      list.each(lines, fn(refusals) {
        case refusals {
          [] -> Nil
          [#(_, first), ..] ->
            warn_own_refusal(spec_path, readers(first.path), refusals)
        }
      })
      Ok(Nil)
    }
  }
}

// What each target refusing a line found, once per distinct finding, beside
// the targets that found it.
fn explained_refusals(refusals: List(#(String, OwnViolation))) -> String {
  list.fold(refusals, [], fn(acc: List(#(String, List(String))), refusal) {
    let #(target, violation) = refusal
    case list.key_find(acc, violation.description) {
      Ok(on) ->
        list.key_set(acc, violation.description, list.append(on, [target]))
      Error(Nil) -> list.append(acc, [#(violation.description, [target])])
    }
  })
  |> list.map(fn(entry) {
    "\n  " <> entry.0 <> " (on " <> string.join(entry.1, ", ") <> ")"
  })
  |> string.concat
}

// The warning for one line some of `targets` refused and the others read.
fn warn_own_refusal(
  spec_path: String,
  targets: List(String),
  refusals: List(#(String, OwnViolation)),
) -> Nil {
  case refusals {
    [] -> Nil
    [#(_, first), ..] -> {
      let refusing = list.unique(list.map(refusals, fn(refusal) { refusal.0 }))
      let reading =
        list.filter(targets, fn(target) { !list.contains(refusing, target) })
      io.println_error(
        spec_path
        <> ": warning: "
        <> first.statement
        <> explained_refusals(refusals)
        <> "\n  the line is not read on "
        <> string.join(refusing, ", ")
        <> ", and is read on "
        <> string.join(reading, ", "),
      )
    }
  }
}

fn bundled_catalog_directory() -> Result(String, GradedError) {
  locate_catalog(effects.catalog_candidates())
}

// The first of `candidates` that is an existing directory. Takes the candidates
// as an argument so a test can point it at paths of its own.
@internal
pub fn locate_catalog(candidates: List(String)) -> Result(String, GradedError) {
  list.find(candidates, fn(candidate) {
    simplifile.is_directory(candidate) == Ok(True)
  })
  |> result.replace_error(CatalogError(NoCatalogDirectory(candidates)))
}

// The catalog files under `catalog_dir`. A directory holding no
// `{package}@{version}.graded` file is not graded's catalog, whichever way the
// lookup landed on it.
fn catalog_files(
  catalog_dir: String,
) -> Result(List(effects.CatalogFile), GradedError) {
  use files <- result.try(
    effects.bundled_catalog_files(catalog_dir)
    |> result.map_error(fn(cause) { DirectoryReadError(catalog_dir, cause) }),
  )
  use <- bool.guard(
    when: files == [],
    return: Error(CatalogError(EmptyCatalog(catalog_dir))),
  )
  Ok(files)
}

// The `manifest.toml` of the package `directory` belongs to, found by walking
// up from it as every command's knowledge base does. Exposed so a test can walk
// up from a fixture subdirectory.
@internal
pub fn catalog_manifest_path(directory: String) -> String {
  manifest_path(resolve_package_root(source_scope(directory).analysed))
}

// The process's own directory, absolute so the walk to a package root is a real
// one: the relative `.` a failed lookup falls back to is its own parent, which
// halts the walk where it starts.
fn working_directory() -> String {
  simplifile.current_directory() |> result.unwrap(".")
}

// Read `directory` for the sake of failing on one that isn't there. A directory
// argument names the project whose manifest is read, and a missing one would
// otherwise walk up to whichever project the process sits in and answer for
// that.
fn read_directory(directory: String) -> Result(Nil, GradedError) {
  simplifile.read_directory(directory)
  |> result.replace(Nil)
  |> result.map_error(DirectoryReadError(directory, _))
}

// Render `request` against the catalog directory and manifest it names. One
// layer below `run_catalog`, taking both paths as arguments so a test can point
// it at a fixture catalog and manifest.
@internal
pub fn catalog_report(
  catalog_dir: String,
  manifest_path: String,
  request: cli.CatalogRequest,
) -> Result(String, GradedError) {
  use files <- result.try(catalog_files(catalog_dir))
  case request {
    cli.ListCatalog -> Ok(catalog_listing(files, manifest_path))
    cli.ShowCatalog(package:, version:, directory: _) ->
      catalog_file_output(files, manifest_path, package, version)
  }
}

// One `package@version` line per bundled file, sorted by package then version,
// with the note of the file the manifest resolves that package to. Where there
// is no manifest to read, nothing selects and the listing leads with a line
// saying so — undecorated lines otherwise read as a project the catalog covers
// none of.
fn catalog_listing(
  files: List(effects.CatalogFile),
  manifest_path: String,
) -> String {
  let manifest = effects.read_manifest_versions(manifest_path)
  let installed = result.unwrap(manifest, dict.new())
  let lines =
    files
    |> list.sort(compare_catalog_files)
    |> list.map(fn(file) {
      let label = catalog_label(file)
      case listing_suffix(files, installed, file) {
        Ok(note) -> label <> "  // " <> note
        Error(Nil) -> label
      }
    })
  case manifest {
    Ok(_versions) -> string.join(lines, "\n")
    Error(Nil) ->
      string.join(
        ["// no readable manifest.toml at " <> manifest_path, ..lines],
        "\n",
      )
  }
}

// The note this file's line carries. A package the manifest doesn't list
// selects nothing, and a file its package's installed version resolves past
// carries no note.
fn listing_suffix(
  files: List(effects.CatalogFile),
  installed: Dict(String, String),
  file: effects.CatalogFile,
) -> Result(String, Nil) {
  use version <- result.try(dict.get(installed, file.package))
  use selection <- result.try(effects.select_catalog_file(
    files,
    file.package,
    version,
  ))
  use <- bool.guard(when: selection.file.path != file.path, return: Error(Nil))
  Ok(case selection {
    effects.Selected(_) -> "selected for " <> file.package <> " " <> version
    effects.HighestBundled(_) ->
      "highest bundled; none ≤ " <> file.package <> " " <> version
  })
}

// One bundled file, printed under the header that names it. The explicit form
// reads no manifest: the version asked for is the one printed, whatever the
// project installs.
fn catalog_file_output(
  files: List(effects.CatalogFile),
  manifest_path: String,
  package: String,
  version: Option(String),
) -> Result(String, GradedError) {
  let bundled = list.filter(files, fn(file) { file.package == package })
  use <- bool.guard(
    when: bundled == [],
    return: Error(CatalogError(NoCatalogEntry(package))),
  )
  use #(file, note) <- result.try(case version {
    Some(version) ->
      list.find(bundled, fn(file) { file.version == version })
      |> result.map(fn(file) { #(file, "bundled version, as requested") })
      |> result.replace_error(
        CatalogError(NoBundledVersion(
          package:,
          requested: version,
          bundled: catalog_labels(bundled),
        )),
      )
    None -> {
      use installed <- result.try(
        effects.read_manifest_versions(manifest_path)
        |> result.replace_error(CatalogError(NoManifest(manifest_path))),
      )
      use version <- result.map(
        dict.get(installed, package)
        |> result.replace_error(
          CatalogError(NotInstalled(package:, bundled: catalog_labels(bundled))),
        ),
      )
      // A non-empty list for the package always selects one of its files, so a
      // failure here is a broken invariant rather than a case to render.
      // nolint: assert_ok_pattern -- a broken invariant, not an error to handle
      let assert Ok(selection) =
        effects.select_catalog_file(bundled, package, version)
        as "a package with bundled files always selects one"
      #(selection.file, selection_note(selection, package, version))
    }
  })
  print_catalog_file(file, note)
}

// Why the implicit form chose this file: the installed version it covers, or
// the fall-back that fires when nothing bundled is old enough.
fn selection_note(
  selection: effects.CatalogSelection,
  package: String,
  version: String,
) -> String {
  case selection {
    effects.Selected(_) ->
      "selected for " <> package <> " " <> version <> " in manifest.toml"
    effects.HighestBundled(_) ->
      "highest bundled version; no bundled " <> package <> " ≤ " <> version
  }
}

// The header line, then the file verbatim. `report` prints with `io.println`,
// which appends a newline, so exactly one trailing newline is dropped here for
// it to put back: a file that ends in one prints byte-identically.
fn print_catalog_file(
  file: effects.CatalogFile,
  note: String,
) -> Result(String, GradedError) {
  use contents <- result.map(
    simplifile.read(file.path)
    |> result.map_error(fn(cause) { FileReadError(file.path, cause) }),
  )
  let header = "// " <> catalog_label(file) <> ".graded — " <> note
  header <> "\n" <> drop_trailing_newline(contents)
}

// `text` without the newline byte it ends in, if it ends in one. Byte-wise: a
// `\r\n` is a single grapheme, so dropping the last grapheme would take the
// carriage return with it and a CRLF file would not print as it reads.
fn drop_trailing_newline(text: String) -> String {
  let bytes = bit_array.from_string(text)
  let without_last = bit_array.slice(bytes, 0, bit_array.byte_size(bytes) - 1)
  case string.ends_with(text, "\n"), without_last {
    True, Ok(trimmed) -> bit_array.to_string(trimmed) |> result.unwrap(text)
    True, Error(Nil) | False, Ok(_) | False, Error(Nil) -> text
  }
}

// Bundled files as `package@version` tokens, ascending by version: what an
// error message lists, and where its suggestion reads the highest off the end.
fn catalog_labels(files: List(effects.CatalogFile)) -> List(String) {
  files |> list.sort(compare_catalog_files) |> list.map(catalog_label)
}

fn catalog_label(file: effects.CatalogFile) -> String {
  file.package <> "@" <> file.version
}

fn compare_catalog_files(
  left: effects.CatalogFile,
  right: effects.CatalogFile,
) -> order.Order {
  string.compare(left.package, right.package)
  |> order.break_tie(effects.compare_semver(left.parsed, right.parsed))
}

// Formatting
//
// The `format` command and its `--check`/`--stdin` variants: parse the spec
// file, sort it, and write or compare the normalized form.

/// Format the project's spec file in place. The spec file is the single
/// source of truth for hand-written `check`/`assume` lines and
/// the inferred public-API effects.
pub fn run_format(directory: String) -> Result(Nil, GradedError) {
  use cfg <- result.try(read_config(directory))
  use formatted <- result.try(format_one_spec(cfg.spec_file))
  case formatted {
    None -> Ok(Nil)
    Some(formatted) ->
      simplifile.write(cfg.spec_file, formatted)
      |> result.map_error(FileWriteError(cfg.spec_file, _))
  }
}

/// Format a `.graded` spec given as a string, as `graded format --stdin` does
/// for editor integration: parse the input, then sort and reformat it. Returns
/// a `GradedParseError` naming `<stdin>` if the input doesn't parse.
pub fn run_format_stdin(input: String) -> Result(String, GradedError) {
  annotation.parse_file(input)
  |> result.map(annotation.format_sorted)
  |> result.map_error(graded_parse_error("<stdin>", _))
}

/// Check that the project's spec file is already formatted. Returns error
/// with the file path if it isn't. Used by CI as `format --check`.
pub fn run_format_check(directory: String) -> Result(Nil, GradedError) {
  use cfg <- result.try(read_config(directory))
  use formatted <- result.try(format_one_spec(cfg.spec_file))
  case formatted {
    None -> Ok(Nil)
    Some(formatted) ->
      case simplifile.read(cfg.spec_file) {
        Error(_) -> Ok(Nil)
        Ok(content) ->
          case content == formatted {
            True -> Ok(Nil)
            False -> Error(FormatCheckFailed(paths: [cfg.spec_file]))
          }
      }
  }
}

// Format the spec file's contents, or `None` when there is no spec file. A
// missing file is tolerated; a malformed one is a parse error.
fn format_one_spec(
  spec_path: String,
) -> Result(option.Option(String), GradedError) {
  case simplifile.read(spec_path) {
    Error(_) -> Ok(None)
    Ok(content) ->
      annotation.parse_file(content)
      |> result.map(fn(file) { Some(annotation.format_sorted(file)) })
      |> result.map_error(graded_parse_error(spec_path, _))
  }
}

// Source parsing and signatures
//
// Find and glance-parse the project's sources, and build the signature
// registry used for positional argument matching at call sites.

fn find_gleam_files(directory: String) -> Result(List(String), GradedError) {
  config.source_files(directory)
  |> result.map_error(DirectoryReadError(directory, _))
  |> result.map(
    list.filter(_, fn(path) {
      string.ends_with(path, ".gleam") && !under_build_dir(directory, path)
    }),
  )
}

// A `.gleam` inside the scanned root's own `build/` subtree is dependency or
// compiler output, never project source. The `src/` scoping in
// `scope_to_source_directory` already keeps a package-root run out of `build/`;
// this excludes it for any argument that isn't so scoped (a non-package subtree,
// or a package with a non-standard layout). Scoped to the leading directory so a
// throwaway project rooted *at* a `build/...` path (as test harnesses use) is
// still scanned — only a `build/` directly below the scanned root is skipped.
fn under_build_dir(directory: String, path: String) -> Bool {
  let prefix = directory <> "/"
  let relative = case string.starts_with(path, prefix) {
    True -> string.drop_start(path, string.length(prefix))
    False -> path
  }
  case filepath.split(relative) {
    ["build", ..] -> True
    _ -> False
  }
}

// A command's target: the directory whose sources are analysed, and the subtree
// whose results are reported.
//
// The two differ only for a directory nested inside its own package's `src/`.
// Resolution is a fact of the whole package — imports, `@external` discovery and
// module-path keying all are — so analysing a subtree alone re-keys every module
// (`sub/inner` becomes `inner`, and the `check` lines naming it stop matching)
// and resolves a call out of the subtree against nothing. The analysis therefore
// widens to the package's `src/`, and the passed directory filters what is
// reported.
type SourceScope {
  SourceScope(analysed: String, reported: String)
}

fn source_scope(directory: String) -> SourceScope {
  let scoped = scope_to_source_directory(normalize_directory(directory))
  case enclosing_source_root(scoped) {
    Some(root) -> SourceScope(analysed: root, reported: scoped)
    None -> SourceScope(analysed: scoped, reported: scoped)
  }
}

// The `src/` of the package `directory` sits strictly inside, if any.
//
// `None` for the package's own `src/`, and for a directory no package's `src/`
// encloses — a standalone tree, an out-of-tree source directory, or a subtree of
// the surrounding project that is not under its `src/`. Those keep acting as
// their own root, which is what `spec_root_for`'s carve-out already promises
// them and what this repo's own `test/fixtures` workflow depends on.
fn enclosing_source_root(directory: String) -> Option(String) {
  let root = resolve_package_root(directory)
  let source_root = case root {
    "." -> "src"
    _ -> filepath.join(root, "src")
  }
  case within_directory(source_root, directory) {
    True -> Some(source_root)
    False -> None
  }
}

// Whether `path` names a file inside `directory`'s subtree.
//
// A prefix test, so both sides must already be normalized — `normalize_directory`
// settles the argument every scope derives from, and the paths compared against
// it come from a walk of that same directory.
fn within_directory(directory: String, path: String) -> Bool {
  string.starts_with(path, directory <> "/")
}

// The caller's directory argument in the one spelling everything downstream
// compares against. `src/sub`, `./src/sub` and `src/sub/` name one directory,
// but a raw prefix test reads them as three: a trailing separator builds a
// `src/sub//` prefix that matches none of the walked files, and a `./` prefix
// fails to match the package's `src/`, so the subtree is analysed as its own
// root under the wrong module paths. Either way `check` lines stop matching and
// the run reports success having verified nothing.
//
// `.` survives as itself rather than expanding to the empty string: it is the
// production layout's root, which `scope_to_source_directory` and
// `source_root_for` both key on by name.
fn normalize_directory(directory: String) -> String {
  case filepath.expand(directory) {
    Ok("") -> "."
    Ok(expanded) -> expanded
    // Only a relative path climbing past its own root fails to expand. It names
    // nothing to scan, so it travels on unchanged and fails where it is read.
    Error(Nil) -> directory
  }
}

// Scope a command's target directory to source files. When the argument is a
// package root (a `gleam.toml` beside a `src/` directory), descend into `src/`
// so module names derive unprefixed (`app`, not `src/app`) and the walk skips
// `build/` and `test/`. A bare `src` argument, an out-of-tree source directory,
// or a non-package subtree is left untouched. The `.` root maps to the literal
// `"src"` (not `filepath.join(".", "src")`, which yields `"./src"`) so it keeps
// hitting the production `"src"` layout convention shared with `read_config`.
fn scope_to_source_directory(directory: String) -> String {
  let has_toml = simplifile.is_file(filepath.join(directory, "gleam.toml"))
  let has_src = simplifile.is_directory(filepath.join(directory, "src"))
  case has_toml, has_src {
    Ok(True), Ok(True) ->
      case directory {
        "." -> "src"
        _ -> filepath.join(directory, "src")
      }
    _, _ -> directory
  }
}

// Parse every project source file once, returning `(path, parsed module)`
// pairs. Used by `run_infer` so the topo sort can read each module's
// imports without re-parsing on the inference pass.
fn parse_all_files(
  gleam_files: List(String),
) -> Result(List(#(String, glance.Module)), GradedError) {
  list.try_map(gleam_files, fn(gleam_path) {
    use module <- result.try(read_and_parse_gleam(gleam_path))
    Ok(#(gleam_path, module))
  })
}

fn read_and_parse_gleam(
  gleam_path: String,
) -> Result(glance.Module, GradedError) {
  use source <- result.try(
    simplifile.read(gleam_path)
    |> result.map_error(FileReadError(gleam_path, _)),
  )
  glance.module(source)
  |> result.map_error(GleamParseError(gleam_path, _))
}

// What the package's own modules and its dependencies' say about their custom
// types' record fields.
fn package_field_index(
  dep_sources: DependencySources,
  index: Dict(String, #(String, glance.Module)),
) -> types.FieldIndex {
  signatures.merge_field_index(
    dependency_field_index(dep_sources),
    build_project_field_index(index),
  )
}

// Every custom type and alias the package and its scanned dependencies define;
// the package's own win where both define one name.
fn build_type_definitions(
  index: Dict(String, #(String, glance.Module)),
  dep_sources: DependencySources,
  package_targets: types.PackageTargets,
) -> typedefs.TypeRegistry {
  let targets = types.declaration_targets(package_targets)
  dict.fold(
    index,
    dependency_type_definitions(dep_sources),
    fn(acc, module_path, entry) {
      typedefs.merge(acc, typedefs.from_module(module_path, entry.1, targets))
    },
  )
}

// What every project module says about its custom types' record fields, keyed
// the same way a dependency's is so the two merge into one package-wide index.
fn build_project_field_index(
  index: Dict(String, #(String, glance.Module)),
) -> types.FieldIndex {
  dict.fold(index, signatures.empty_field_index(), fn(acc, module_path, entry) {
    let #(_gleam_path, module) = entry
    signatures.merge_field_index(
      acc,
      signatures.field_index_from_module(
        module_path,
        module,
        signatures.type_alias_map(module.type_aliases),
      ),
    )
  })
}

// Build a signature registry covering every project module. Used by
// the checker's call-site substitution to resolve effect variables
// when the caller passes positional (unlabeled) arguments.
fn build_project_registry(
  index: Dict(String, #(String, glance.Module)),
  package_targets: types.PackageTargets,
) -> SignatureRegistry {
  dict.fold(index, signatures.empty(), fn(acc, module_path, entry) {
    let #(_gleam_path, module) = entry
    signatures.merge(acc, built_registry(module_path, module, package_targets))
  })
}

// `module`'s signatures as its package builds them: a name defined once per
// target is read off the definitions built on `package_targets`.
fn built_registry(
  module_path: String,
  module: glance.Module,
  package_targets: types.PackageTargets,
) -> SignatureRegistry {
  signatures.from_glance_module(
    module_path,
    glance.Module(
      ..module,
      functions: extract.built_functions(
        module.functions,
        types.declaration_targets(package_targets),
      ),
    ),
  )
}

// Build a package-wide map keyed by `#(defining module, name)` from a per-module
// `name -> value` map, qualifying each entry with the module it came from.
fn qualify_by_module(
  index: Dict(String, #(String, glance.Module)),
  per_module: fn(String, glance.Module) -> Dict(String, value),
) -> Dict(#(String, String), value) {
  dict.fold(index, dict.new(), fn(acc, path, entry) {
    let #(_gleam_path, module) = entry
    dict.fold(per_module(path, module), acc, fn(inner, name, value) {
      dict.insert(inner, #(path, name), value)
    })
  })
}

// Type index

// Run girard's whole-package type inference once over every project module
// and fold the result into a `TypeInfo`: per-module expression types keyed by
// their `#(start, end)` span, the fn-typed parameters girard inferred, and
// girard's own reading of each module — the member every reference resolved to,
// the definitions it declined, and the ones it left out for the other target.
// girard is best-effort: a function it can't type contributes no expressions,
// so the checker silently falls back to syntax-level resolution for it.
//
// A path dependency is read exactly the same way, with the resolver seeded from
// the *consumer's* package root: a dep resolves its own modules from `index`
// and everything else — the packages it and the consumer share — from the
// consumer's `build/packages`, which is the one tree Gleam installs for both.
// Without it girard could not type a dep function whose signature names a
// dependency type, and every shadowed receiver in the dep would read
// `[Unknown]`.
//
// `dep_files` is the consumer's whole dependency tree, scanned once by the
// caller: every module the resolver may reach outside `index`. Taking the scan
// rather than the root keeps it off the per-path-dependency path, which calls
// this once per dep.
//
// Exposed (pub) so a test can ask what girard read of a dep directly, rather
// than inferring it from a charge.
@internal
pub fn build_type_index(
  index: Dict(String, #(String, glance.Module)),
  dep_files: Dict(String, String),
  package_targets: types.PackageTargets,
) -> typeinfo.TypeInfo {
  type_index(index, dep_files, package_targets, set.new(), dict.new())
}

// The same, with the targets the dependency modules the package reaches read
// differently on.
fn type_index(
  index: Dict(String, #(String, glance.Module)),
  dep_files: Dict(String, String),
  package_targets: types.PackageTargets,
  dependency_variants: Set(String),
  done: GirardRuns,
) -> typeinfo.TypeInfo {
  annotate_with_runs(
    index_entries(index),
    build_girard_resolver(index, dep_files),
    run_targets(package_targets, index_entries(index), dependency_variants),
    done,
  )
  |> typeinfo.on_declared_targets(types.declaration_targets(package_targets))
}

fn index_entries(
  index: Dict(String, #(String, glance.Module)),
) -> List(#(String, glance.Module)) {
  dict.to_list(index)
  |> list.map(fn(pair) {
    let #(module_path, #(_gleam_path, module)) = pair
    #(module_path, module)
  })
}

// girard's results for a package, by the target each run was made on.
type GirardRuns =
  Dict(String, Dict(String, girard.ModuleResult))

fn girard_run(
  entries: List(#(String, glance.Module)),
  resolver: fn(String) -> Result(String, Nil),
  target: girard.Target,
) -> Dict(String, girard.ModuleResult) {
  let options =
    girard.default_options()
    |> girard.with_target(target)
    |> girard.with_resolver(resolver)
  girard.annotate_package(entries, options)
}

// The whole package annotated once per target and merged per module: the
// primary run's reading whole, and a secondary run's only inside the
// definitions the primary left out for the other target.
//
// A module the primary run returned no result for is `absent` — the largest
// hole there is, and not a *dropped* one, so nothing fills it and every site in
// it keeps reading as "no typed evidence". A module a secondary run returned no
// result for bypasses the merge entirely and keeps the primary's reading whole,
// drops included: intersecting the primary's drops with an empty set would read
// the definitions that run never typed as typed ones.
//
// Split out from `build_type_index` so the coverage probe measures the merge
// production runs rather than one of its own.
@internal
pub fn annotate_on_targets(
  entries: List(#(String, glance.Module)),
  resolver: fn(String) -> Result(String, Nil),
  targets: List(girard.Target),
) -> typeinfo.TypeInfo {
  annotate_with_runs(entries, resolver, targets, dict.new())
}

// The same, reusing any run `done` already holds for a target.
fn annotate_with_runs(
  entries: List(#(String, glance.Module)),
  resolver: fn(String) -> Result(String, Nil),
  targets: List(girard.Target),
  done: GirardRuns,
) -> typeinfo.TypeInfo {
  let modules = dict.from_list(entries)
  let runs =
    list.map(targets, fn(target) {
      case dict.get(done, typeinfo.target_name(target)) {
        Ok(results) -> #(target, results)
        Error(Nil) -> #(target, girard_run(entries, resolver, target))
      }
    })
  case runs {
    [] -> typeinfo.none()
    [#(primary_target, primary_results), ..secondary_runs] -> {
      let primaries =
        dict.to_list(primary_results)
        |> list.filter_map(fn(pair) {
          let #(module_path, module_result) = pair
          use module <- result.map(dict.get(modules, module_path))
          #(
            module_path,
            module,
            primary_reading(module_result, module, primary_target),
          )
        })
      let readings =
        list.map(primaries, fn(entry) {
          let #(module_path, module, primary) = entry
          #(
            module_path,
            merged_reading(primary, module, module_path, secondary_runs),
          )
        })
      typeinfo.from_modules(
        list.map(readings, fn(pair) { #(pair.0, { pair.1 }.expressions) }),
        list.map(readings, fn(pair) { #(pair.0, { pair.1 }.fn_typed) }),
        list.map(readings, fn(pair) { #(pair.0, { pair.1 }.evidence) }),
        targets,
        dict.keys(modules)
          |> set.from_list()
          |> set.drop(dict.keys(primary_results)),
        unfilled_modules(dict.keys(primary_results), secondary_runs),
      )
      |> typeinfo.with_target_types(target_types(
        primaries,
        primary_target,
        secondary_runs,
      ))
    }
  }
}

// Each run's own reading of every module's expression types, where more than
// one target was run. A run that returned no result for a module types
// nothing in it.
fn target_types(
  primaries: List(#(String, glance.Module, typeinfo.ModuleReading)),
  primary_target: girard.Target,
  secondary_runs: List(#(girard.Target, Dict(String, girard.ModuleResult))),
) -> Dict(String, List(typeinfo.TargetTypes)) {
  use <- bool.guard(when: secondary_runs == [], return: dict.new())
  list.fold(primaries, dict.new(), fn(acc, entry) {
    let #(module_path, _module, primary) = entry
    let secondaries =
      list.map(secondary_runs, fn(run) {
        let #(target, results) = run
        case dict.get(results, module_path) {
          Ok(module_result) ->
            typeinfo.TargetTypes(
              target: typeinfo.target_name(target),
              expressions: typeinfo.span_types(module_result),
              dropped: typeinfo.holes(
                list.map(module_result.annotated.dropped, fn(definition) {
                  #(definition.span.start, definition.span.end)
                }),
              ),
            )
          Error(Nil) ->
            typeinfo.TargetTypes(
              target: typeinfo.target_name(target),
              expressions: dict.new(),
              dropped: typeinfo.holes([]),
            )
        }
      })
    dict.insert(acc, module_path, [
      typeinfo.TargetTypes(
        target: typeinfo.target_name(primary_target),
        expressions: primary.expressions,
        dropped: typeinfo.holes(set.to_list(primary.evidence.dropped)),
      ),
      ..secondaries
    ])
  })
}

// The primary run's reading of one module with every secondary run's folded
// into it. A run that returned no result for this module is skipped rather than
// merged as an empty reading, which would clear the primary's drops.
//
// A module the primary run left nothing out of has no hole for a secondary run
// to fill, so the merge over it is the identity and its secondary reading is
// never built. That is every module but the handful holding a `@target` pair.
fn merged_reading(
  primary: typeinfo.ModuleReading,
  module: glance.Module,
  module_path: String,
  secondary_runs: List(#(girard.Target, Dict(String, girard.ModuleResult))),
) -> typeinfo.ModuleReading {
  use <- bool.guard(set.is_empty(primary.evidence.dropped), primary)
  list.fold(secondary_runs, primary, fn(acc, run) {
    let #(target, results) = run
    case dict.get(results, module_path) {
      Error(Nil) -> acc
      Ok(module_result) -> {
        let #(reading, definitions) =
          secondary_reading(module_result, module, target)
        typeinfo.merge_readings(acc, reading, definitions)
      }
    }
  })
}

// The modules the primary run read that some secondary run did not.
fn unfilled_modules(
  read: List(String),
  secondary_runs: List(#(girard.Target, Dict(String, girard.ModuleResult))),
) -> Set(String) {
  list.fold(secondary_runs, set.new(), fn(acc, run) {
    list.filter(read, fn(module_path) { !dict.has_key({ run.1 }, module_path) })
    |> list.fold(acc, set.insert)
  })
}

// The primary run's reading of one module. Nothing places its fn-typed entries
// against a hole — the holes are its own — so it carries no definition spans.
fn primary_reading(
  module_result: girard.ModuleResult,
  module: glance.Module,
  target: girard.Target,
) -> typeinfo.ModuleReading {
  typeinfo.ModuleReading(
    expressions: typeinfo.span_types(module_result),
    fn_typed: fn_typed_params_from_schemes(module_result, module, target),
    evidence: typeinfo.evidence_of(
      module_result,
      checker.error_bucket,
      module,
      target,
    ),
    by_target: [],
  )
}

// A secondary run's reading of one module, beside the span of every function
// that run kept — the identity the merge places a name-keyed fn-typed entry by.
fn secondary_reading(
  module_result: girard.ModuleResult,
  module: glance.Module,
  target: girard.Target,
) -> #(typeinfo.ModuleReading, Dict(String, #(Int, Int))) {
  #(
    primary_reading(module_result, module, target),
    list.fold(module.functions, dict.new(), fn(acc, definition) {
      let function = definition.definition
      case typeinfo.kept_on_target(definition, target) {
        True ->
          dict.insert(acc, function.name, #(
            function.location.start,
            function.location.end,
          ))
        False -> acc
      }
    }),
  )
}

// The targets girard is run on, primary first: `girard_target`'s choice, then
// the other target when some *function* in the package is gated to it by
// `@target`, or when the package is read on the other target too and one name
// of its own constants, type aliases or custom types, or a definition a
// dependency module it imports exposes through its public interface, is
// defined once for each target. A package with none of these runs once and
// pays nothing.
//
// A definition gated to the other target alone can be read only from code
// gated the same way, which triggers the run by itself. A pair can be read from
// ungated code and types it differently on each target: a constant or alias
// directly, a custom type through its fields and constructors.
@internal
pub fn girard_targets(
  package_targets: types.PackageTargets,
  entries: List(#(String, glance.Module)),
) -> List(girard.Target) {
  run_targets(package_targets, entries, set.new())
}

fn run_targets(
  package_targets: types.PackageTargets,
  entries: List(#(String, glance.Module)),
  dependency_variants: Set(String),
) -> List(girard.Target) {
  let primary = girard_target(package_targets)
  let other = case primary {
    girard.Erlang -> girard.JavaScript
    girard.JavaScript -> girard.Erlang
  }
  let other_name = typeinfo.target_name(other)
  let function_gated =
    list.any(entries, fn(entry) {
      list.any({ entry.1 }.functions, gated_alone_to(_, other_name))
    })
  let read_on_other =
    set.contains(types.declaration_targets(package_targets), other_name)
  let pair_gated =
    read_on_other
    && {
      set.contains(dependency_variants, other_name)
      || list.any(entries, fn(entry) {
        let module = entry.1
        list.contains(
          paired_targets(module.constants, fn(definition) {
            definition.definition.name
          }),
          other_name,
        )
        || list.any(paired_type_names(module, read_any, read_any), fn(pair) {
          pair.0 == other_name
        })
      })
    }
  case function_gated || pair_gated {
    True -> [primary, other]
    False -> [primary]
  }
}

fn gated_alone_to(definition: glance.Definition(a), target: String) -> Bool {
  extract.compiled_targets(definition, types.every_target())
  == set.from_list([target])
}

// The one target girard is run on. Gleam compiles a whole build for a single
// target, and girard takes one per run, so a package naming both is typed on
// Erlang and its JavaScript-only definitions come back as `dropped` rather than
// silently absent. `build_targets` is the reading to take: a package naming no
// target is compiled for Erlang, exactly as `gleam build` defaults — and so is
// one naming neither of the two, which names no target girard runs on.
@internal
pub fn girard_target(package_targets: types.PackageTargets) -> girard.Target {
  let targets = types.build_targets(package_targets)
  case set.contains(targets, "erlang"), set.contains(targets, "javascript") {
    False, True -> girard.JavaScript
    True, True | True, False | False, False -> girard.Erlang
  }
}

// From girard's inferred top-level signatures, the set of function-typed
// parameter names for each function — including parameters with no syntactic
// `fn(...)` annotation, which the glance-only detection misses. A parameter is
// function-typed when its inferred type (positional in the function's `Fn`
// type) is itself a `Fn`. A name defined once per target is read off the
// definition `target` builds, which is the one girard typed.
fn fn_typed_params_from_schemes(
  module_result: girard.ModuleResult,
  module: glance.Module,
  target: girard.Target,
) -> Dict(String, Set(String)) {
  let function_map =
    extract.built_functions(
      module.functions,
      set.from_list([typeinfo.target_name(target)]),
    )
    |> list.fold(dict.new(), fn(acc, definition) {
      dict.insert(acc, definition.definition.name, definition.definition)
    })
  list.fold(module_result.annotated.functions, dict.new(), fn(acc, entry) {
    let #(name, scheme) = entry
    case scheme.type_, dict.get(function_map, name) {
      girard.Fn(argument_types, _return), Ok(function) ->
        dict.insert(acc, name, fn_typed_names(function, argument_types))
      _, _ -> acc
    }
  })
}

// The names of `function`'s parameters whose inferred type (positional in
// `argument_types`) is itself a `Fn`.
fn fn_typed_names(
  function: glance.Function,
  argument_types: List(girard.Type),
) -> Set(String) {
  // Positional mapping is only sound when girard's `Fn` arity matches glance's
  // parameter count. `list.zip` would silently truncate a mismatch, so skip the
  // function entirely rather than map parameters to the wrong types.
  use <- bool.guard(
    when: list.length(function.parameters) != list.length(argument_types),
    return: set.new(),
  )
  list.zip(function.parameters, argument_types)
  |> list.filter_map(fn(pair) {
    let #(parameter, argument_type) = pair
    case argument_type, parameter.name {
      girard.Fn(_, _), glance.Named(parameter_name) -> Ok(parameter_name)
      _, _ -> Error(Nil)
    }
  })
  |> set.from_list()
}

// A girard `Resolver` that resolves graded's own project modules from `index`
// first (so non-`src` layouts like `test/fixtures` work), then dependency
// modules from `dep_files` (installed deps under `build/packages` and path deps
// at their declared location, both keyed package-root-relative). The stock disk
// resolver is the last resort: it reads `build/packages` relative to the process
// cwd, which misses path deps entirely and misses installed deps when graded is
// invoked from outside the package root — so a dependency-defined type on a
// parameter would leave the receiver untyped and its field calls `[Unknown]`.
fn build_girard_resolver(
  index: Dict(String, #(String, glance.Module)),
  dep_files: Dict(String, String),
) -> fn(String) -> Result(String, Nil) {
  let disk = girard.disk_resolver()
  fn(module_path) {
    case dict.get(index, module_path) {
      Ok(#(gleam_path, _module)) ->
        simplifile.read(gleam_path) |> result.replace_error(Nil)
      Error(Nil) ->
        case dict.get(dep_files, module_path) {
          Ok(file) -> simplifile.read(file) |> result.replace_error(Nil)
          Error(Nil) -> disk(module_path)
        }
    }
  }
}

// Module index and import graph
//
// Map dotted module names to parsed files and derive each module's
// project-internal imports — the nodes and edges of the topological sort.

// Build an index from dotted module name (`app/router`) to the parsed file.
// This is the set of *project* modules — every module name in this dict is
// a candidate dependency-graph node.
fn build_module_index(
  parsed: List(#(String, glance.Module)),
  directory: String,
) -> Dict(String, #(String, glance.Module)) {
  list.fold(parsed, dict.new(), fn(acc, entry) {
    let #(gleam_path, module) = entry
    let module_path = config.module_path_for_source(gleam_path, directory)
    dict.insert(acc, module_path, #(gleam_path, module))
  })
}

// For every project module, derive its set of project-internal imports.
// Imports of stdlib/dep modules (anything not in `index`) are filtered out
// — those are leaves with effects already resolved via the knowledge base
// and don't belong in the topological sort.
fn build_dependency_graph(
  index: Dict(String, #(String, glance.Module)),
) -> Dict(String, Set(String)) {
  dict.map_values(index, fn(_module_path, entry) {
    let #(_path, module) = entry
    project_imports(module, index)
  })
}

// The modules `index` holds that `module` imports. Every import is an edge,
// including one written under a discarded alias, which binds no module name
// and still brings unqualified items whose calls key the imported module.
fn project_imports(
  module: glance.Module,
  index: Dict(String, #(String, glance.Module)),
) -> Set(String) {
  extract.imported_modules(module)
  |> set.filter(fn(imported) { dict.has_key(index, imported) })
}

// Inference
//
// The `infer` command: infer each module's effects in import order, write the
// per-module cache, and merge public annotations into the spec file. Also the
// in-memory variant `check` uses for modules not yet in the spec.

/// Infer effects for all `.gleam` files in `directory`. Writes two outputs:
///
/// 1. **Per-module cache files** under `<cache_dir>/<module_path>.graded`,
///    containing the inferred effects of every function in the module
///    (public + private). Regenerated freely; not shipped.
///
/// 2. **One spec file** at `<spec_file>` containing the inferred effects of
///    every *public* function across all modules, plus any hand-written
///    `check`, `assume`, or `type` annotations the user already
///    had in the spec file (those lines are preserved verbatim).
///
/// Walks the project's import graph in topological order so each module is
/// analysed after every other project module it imports — a single pass
/// resolves transitive chains of any depth.
pub fn run_infer(directory: String) -> Result(Nil, GradedError) {
  use outcome <- result.try(compute_infer(directory))
  write_infer_outcome(outcome)
}

/// Preview what `run_infer` would change: a line diff of the spec file, or a
/// message saying there is nothing to change. Runs the same inference
/// `run_infer` does and writes nothing — neither the spec file nor the cache.
///
/// The diff's old side is the spec file exactly as it sits on disk, so the
/// re-rendering `run_infer` applies to every line it writes shows up in the
/// preview too.
pub fn run_infer_dry_run(directory: String) -> Result(String, GradedError) {
  use outcome <- result.try(compute_infer(directory))
  infer_changes(outcome)
  |> option.unwrap("graded: no changes")
  |> Ok
}

/// Check that the project's spec file is already what `run_infer` would write.
/// Returns a `StaleSpec` error carrying the diff `run_infer_dry_run` would print
/// if it isn't. Runs the same inference and writes nothing. Used by CI as
/// `infer --check`.
pub fn run_infer_check(directory: String) -> Result(Nil, GradedError) {
  use outcome <- result.try(compute_infer(directory))
  case infer_changes(outcome) {
    None -> Ok(Nil)
    Some(changes) ->
      Error(StaleSpec(path: outcome.cfg.spec_file, diff: changes))
  }
}

// The line diff from the spec file as it sits on disk to the one the inference
// would write, or `None` when writing it would change nothing.
fn infer_changes(outcome: InferOutcome) -> option.Option(String) {
  diff.contextual(
    outcome.spec_on_disk,
    annotation.format_file(outcome.merged_spec),
  )
}

// Run `infer` in one of its modes, returning the message to print. The seam
// `main`'s `infer` branch dispatches through, so every mode is reachable from
// tests.
@internal
pub fn run_infer_command(
  mode: cli.InferMode,
  directory: String,
) -> Result(String, GradedError) {
  case mode {
    cli.Write ->
      run_infer(directory)
      |> result.replace("graded: inferred effects written")
    cli.DryRun -> run_infer_dry_run(directory)
    cli.Check ->
      run_infer_check(directory)
      |> result.replace("graded: spec is up to date")
  }
}

// Write everything the compute phase derived: each module's cache file in
// topological order, then the merged spec.
fn write_infer_outcome(outcome: InferOutcome) -> Result(Nil, GradedError) {
  use Nil <- result.try(list.try_each(outcome.cache_files, write_cache_file))
  write_spec_file(outcome.cfg.spec_file, outcome.merged_spec)
}

// Everything `infer` derives before anything is written: the resolved config,
// the spec file as it sits on disk and as the fresh inference would leave it,
// and the per-module cache files in topological order.
type InferOutcome {
  InferOutcome(
    cfg: config.GradedConfig,
    spec_on_disk: String,
    merged_spec: GradedFile,
    cache_files: List(CacheFile),
  )
}

// One module's inferred effects as the cache file they would be written to.
type CacheFile {
  CacheFile(path: String, file: GradedFile)
}

// What inferring one module produces: the knowledge base later modules resolve
// against, the module's public annotations and returned operators for the spec
// file, and its cache file.
type ModuleInference {
  ModuleInference(
    knowledge_base: KnowledgeBase,
    public: List(EffectAnnotation),
    cache: Option(CacheFile),
  )
}

// Run the whole of inference without touching disk beyond reads, so both
// `run_infer` and `run_infer_dry_run` decide what would be written from one
// shared computation.
fn compute_infer(directory: String) -> Result(InferOutcome, GradedError) {
  use state <- result.map(infer_state(directory))
  InferOutcome(
    cfg: state.cfg,
    spec_on_disk: state.spec_on_disk,
    merged_spec: annotation.merge_inferred(
      state.spec,
      state.public_annotations,
      stale_assumes: state.stale_assumes,
      stale_returns_clauses: state.stale_returns_clauses,
    ),
    cache_files: state.cache_files,
  )
}

// Everything one inference run derives, before it is shaped into what `infer`
// writes: the inputs it read, the indexes and registry it built, the knowledge
// base every module was inferred against and left behind, and the public
// annotations and cache files in topological order.
type InferState {
  InferState(
    // The analysed directory module paths derive from.
    source_directory: String,
    cfg: config.GradedConfig,
    spec_on_disk: String,
    spec: GradedFile,
    stale_assumes: Set(String),
    stale_returns_clauses: Set(String),
    index: Dict(String, #(String, glance.Module)),
    registry: SignatureRegistry,
    type_info: typeinfo.TypeInfo,
    dependencies: DependencySources,
    knowledge_base: KnowledgeBase,
    public_annotations: List(EffectAnnotation),
    cache_files: List(CacheFile),
  )
}

// What one target's run hands the join of several: its lines and cache files,
// and the spec lines it found stale.
type TargetLines {
  TargetLines(
    public_annotations: List(EffectAnnotation),
    cache_files: List(CacheFile),
    stale_assumes: Set(String),
    stale_returns_clauses: Set(String),
  )
}

fn target_lines(state: InferState) -> TargetLines {
  TargetLines(
    public_annotations: state.public_annotations,
    cache_files: state.cache_files,
    stale_assumes: state.stale_assumes,
    stale_returns_clauses: state.stale_returns_clauses,
  )
}

// The inference run behind `compute_infer`, reading nothing from the spec's
// committed `effects` lines.
fn infer_state(directory: String) -> Result(InferState, GradedError) {
  infer_runs(directory, False) |> result.map(fn(runs) { runs.0 })
}

// The inference run behind `compute_infer`, beside each target's own run where
// the package was read on several one at a time and `keep` asks for them;
// none otherwise.
fn infer_runs(
  directory: String,
  keep: Bool,
) -> Result(#(InferState, List(#(String, InferState))), GradedError) {
  // A package has one spec file, so a scoped `infer` is a whole-package `infer`:
  // a spec written from a subtree's modules alone would state the package's
  // public surface wrongly rather than partially.
  let directory = source_scope(directory).analysed
  use cfg <- result.try(read_config(directory))
  use #(targets, shared) <- result.try(case named_targets(cfg) {
    [_, _, ..] -> {
      use index <- result.map(project_index(directory))
      target_split(directory, cfg, index)
    }
    _ -> Ok(#([], no_sharing()))
  })
  case targets {
    [] ->
      infer_state_on(directory, cfg, shared, False)
      |> result.map(fn(run) { #(run.0, []) })
    [first, ..rest] -> {
      use #(state, first_refused, shared) <- result.try(infer_state_on(
        directory,
        on_target(cfg, first),
        shared,
        True,
      ))
      // Unless `keep` asks for every run, only the latest is held whole; each
      // earlier one keeps what the join reads of it.
      let kept = fn(target, state) {
        case keep {
          True -> [#(target, state)]
          False -> []
        }
      }
      use #(last, earlier, runs, refused, _shared) <- result.try(
        list.try_fold(
          rest,
          #(
            #(first, state),
            [],
            kept(first, state),
            [#(first, first_refused)],
            shared,
          ),
          fn(acc, target) {
            let #(#(previous, state), earlier, runs, refused, shared) = acc
            use #(next, next_refused, shared) <- result.map(infer_state_on(
              directory,
              on_target(cfg, target),
              shared,
              True,
            ))
            #(
              #(target, next),
              [#(previous, target_lines(state)), ..earlier],
              list.append(runs, kept(target, next)),
              [#(target, next_refused), ..refused],
              shared,
            )
          },
        ),
      )
      use Nil <- result.map(
        settle_own_refusals(cfg.spec_file, list.reverse(refused), line_builders(
          shared.builds,
          last.1.dependencies,
          _,
        )),
      )
      #(
        joined_infer_state(cfg, last, list.reverse(earlier), shared.builds),
        runs,
      )
    }
  }
}

// One inference run on `cfg`'s targets as they stand, reusing what `shared`
// holds and handing on what it adds.
fn infer_state_on(
  directory: String,
  cfg: config.GradedConfig,
  shared: Shared,
  per_target: Bool,
) -> Result(#(InferState, List(OwnViolation), Shared), GradedError) {
  use #(base, shared) <- result.try(infer_base(
    directory,
    cfg,
    shared,
    per_target,
  ))
  Ok(#(
    infer_fold(base, cfg.targets, base.registry, base.type_info),
    base.refused,
    shared,
  ))
}

// What the runs of one package on its targets, one at a time, compute once:
// only what is built from inputs that are the same on every target.
//
// - `index`: the package's own modules, parsed.
// - `parsed`: every dependency module, parsed.
// - `girard`: girard's runs over the package, by girard target.
// - `catalog`: the bundled catalog, selected and parsed.
// - `scanned`: what the dependency scan derives from a module that reads no
//   target, by source path.
// - `fallback_runs`: girard's runs, by girard target, over every dependency
//   module whose fallback bodies some target walks.
// - `publishers`: the targets each dependency package defining a public
//   function once per target publishes for, by package root.
// - `pairs`: each of the package's modules' functions defined once per
//   target.
// - `tree`: the local packages and the module files of the dependency tree.
// - `split`: whether runs on other targets share these.
type Shared {
  Shared(
    index: Option(Dict(String, #(String, glance.Module))),
    tree: Option(#(LocalPackages, Dict(String, String))),
    parsed: ParsedSources,
    parsed_dirs: Dict(String, List(String)),
    girard: GirardRuns,
    catalog: Option(effects.ParsedCatalog),
    scanned: Dict(String, ScannedModule),
    fallback_runs: GirardRuns,
    publishers: Dict(String, types.PackageTargets),
    pairs: Option(PackagePairs),
    builds: PackageBuilds,
    split: Bool,
  )
}

fn no_sharing() -> Shared {
  Shared(
    index: None,
    parsed: dict.new(),
    parsed_dirs: dict.new(),
    girard: dict.new(),
    catalog: None,
    scanned: dict.new(),
    fallback_runs: dict.new(),
    publishers: dict.new(),
    pairs: None,
    builds: no_package_builds(),
    tree: None,
    split: False,
  )
}

// The local packages under `package_root` and its dependency tree's module
// files, or the ones `shared` already holds.
fn shared_tree(
  shared: Shared,
  package_root: String,
) -> #(LocalPackages, Dict(String, String)) {
  case shared.tree {
    Some(tree) -> tree
    None -> {
      let local = package_tree.discover(package_root)
      #(local, tree_module_files(package_root, local))
    }
  }
}

// The bundled catalog selected for the package under `package_root` and
// parsed, or the one `shared` already holds.
fn shared_catalog(
  shared: Shared,
  package_root: String,
) -> Result(effects.ParsedCatalog, GradedError) {
  case shared.catalog {
    Some(catalog) -> Ok(catalog)
    None -> {
      use catalog_files <- result.map(locate_bundled_catalog())
      effects.parse_project_catalog(catalog_files, manifest_path(package_root))
    }
  }
}

// The targets the package names, sorted, where it names them.
fn named_targets(cfg: config.GradedConfig) -> List(String) {
  case cfg.targets {
    types.NamedTargets(targets:) ->
      set.to_list(targets) |> list.sort(string.compare)
    types.DefaultedTargets -> []
  }
}

// Everything an inference run builds before it walks the package's modules:
// the knowledge base every module starts from, save the layers that read which
// of the package's own functions are foreign code and what its factories build,
// which `infer_fold` adds for the targets it walks on.
type InferBase {
  InferBase(
    directory: String,
    cfg: config.GradedConfig,
    spec_on_disk: String,
    spec: GradedFile,
    stale_assumes: Set(String),
    stale_returns_clauses: Set(String),
    index: Dict(String, #(String, glance.Module)),
    registry: SignatureRegistry,
    type_info: typeinfo.TypeInfo,
    dependencies: DependencySources,
    dep_files: Dict(String, String),
    knowledge_base: KnowledgeBase,
    constructors: Dict(#(String, String), List(Option(String))),
    declared_modules: Set(String),
    sorted: List(String),
    // The project's own lines this run refused, where it is one of several.
    refused: List(OwnViolation),
  )
}

fn infer_base(
  directory: String,
  cfg: config.GradedConfig,
  shared: Shared,
  per_target: Bool,
) -> Result(#(InferBase, Shared), GradedError) {
  let package_root = resolve_package_root(directory)
  // As in `project_context`: parsed first, read once signatures are known.
  use parsed_catalog <- result.try(shared_catalog(shared, package_root))
  use #(spec_on_disk, spec) <- result.try(read_spec_on_disk(cfg.spec_file))
  let declared_modules = annotation.module_assume_modules(spec)

  use index <- result.try(case shared.index {
    Some(index) -> Ok(index)
    None -> project_index(directory)
  })
  // As in `project_context`: one target set for the package and every
  // dependency it is built with.
  let package_targets = cfg.targets
  let native_of = native_functions_of(index, package_targets)
  let stale_assumes = stale_project_assumes(spec, native_of)
  let stale_returns_clauses = stale_project_assume_returns(spec, native_of)

  // Build a signature registry covering every project module so the checker can
  // do positional argument matching for cross-module polymorphic calls. Hoisted
  // above `kb_base` because the builders below consume it; it needs only
  // `index`/`package_root`.
  // As in `project_context`: one walk of the tree for the run.
  let #(local, dep_files) = shared_tree(shared, package_root)
  let scan =
    dependency_scan(
      package_root,
      local,
      package_targets,
      ParsedTree(files: shared.parsed, dirs: shared.parsed_dirs),
      shared.scanned,
    )
  let dep_sources = scan.sources
  let project_registry = build_project_registry(index, package_targets)
  let registry =
    signatures.merge(dependency_registry(dep_sources), project_registry)
  let type_definitions =
    build_type_definitions(index, dep_sources, package_targets)
  let registry = signatures.with_types(registry, type_definitions)
  // As in `project_context`: one table for the run, the own spec's contracts
  // weighed as the run reads them once kinds are known, and other packages'
  // specs read under the same rules.
  let publishers = publisher_configurations(dep_sources, shared.publishers)
  let readings = pair_readings(dep_sources, package_targets, publishers)
  let refused =
    own_contract_violations(spec, spec_on_disk, readings, registry, !per_target)
  use Nil <- result.try(case per_target {
    False -> own_contract_error(cfg.spec_file, refused)
    True -> Ok(Nil)
  })
  let reported =
    reported_refusals(refused, shared.builds, dep_sources, cfg.targets)
  let reading = spec_reading(registry, readings)
  let catalog = effects.read_parsed_catalog(parsed_catalog, reading)
  let registry = signatures.with_shapes(registry, catalog.audit.containers)
  let type_info =
    type_index(
      index,
      dep_files,
      package_targets,
      dependency_target_variants(index, dep_sources),
      shared.girard,
    )
  let girard_targets =
    run_targets(
      package_targets,
      index_entries(index),
      dependency_target_variants(index, dep_sources),
    )
  // As in `project_context`: one map for the run, not one per module.
  let constructors = package_constructors(index, dep_sources, package_targets)

  // As in `project_context`: read once, for the run and for the baseline.
  let catalog_kb = catalog_knowledge_base(package_root, catalog, scan, reading)
  // The project's own lines over a function a dependency defines once per
  // target, in the variant this run builds.
  let reading_spec = rebased_consumer_lines(spec, readings, refused)
  let kb_base =
    catalog_kb
    |> effects.with_dependency_foreign(dependency_foreign(dep_sources))
    |> effects.with_package_targets(cfg.targets)
    // As in `project_context`: the callback parameters of every parsed
    // signature, in reach of the walks below.
    |> effects.with_callback_params(signatures.callback_param_names(registry))
    // Consumer externals are applied before path-dep inference so a module-level
    // external governs a path dependency's module during that dep's own
    // inference, not only at the final lookup.
    |> with_spec_assumes(reading_spec, stale_assumes)
    // Declared returns are state no inference pass re-derives. Without them the
    // walk of a caller's body writes `[Unknown]` where `check` scores the same
    // body from the declaration, and the two commands disagree about it — so
    // they are folded here, at the point `check` folds them, ahead of the
    // path-dep pass whose own inference reads them too.
    |> with_spec_declared_returns(reading_spec, stale_returns_clauses)
    |> with_builders(index, dep_sources, package_targets, constructors)
    |> with_tree_baseline(index, scan, package_targets)
  // As in `project_context`: read once, and handed to both passes that weigh
  // these modules.
  let retained = retained_fallback_modules(dep_sources)
  let #(kb_base, typed_dep_modules, _typed_path_dependencies) =
    enrich_with_path_deps(
      kb_base,
      package_root,
      local,
      dep_files,
      declared_modules,
      package_targets,
      retained,
      arbitration_baseline(
        local,
        catalog_kb,
        scan,
        project_registry,
        reading_spec,
        stale_assumes,
        stale_returns_clauses,
        package_targets,
      ),
      registry,
      reading,
      dep_sources,
    )
  // As in `project_context`: after every layer that can key a dependency name,
  // and before this package's own inference reads the summaries; the type
  // fields first, in reach of the fallback walk, which resolves a dependency
  // body's field calls through these lines.
  let #(kb_base, fallback_runs) =
    kb_base
    |> with_spec_type_fields(spec)
    |> with_dependency_fallback_effects(
      dep_files,
      retained,
      typed_dep_modules,
      registry,
      package_targets,
      girard_targets,
      fallback_typing(shared, dep_sources, retained),
    )

  let graph = build_dependency_graph(index)
  use sorted <- result.try(
    topo.sort(graph)
    |> result.map_error(fn(error) {
      let topo.Cycle(nodes:) = error
      CyclicImports(modules: nodes)
    }),
  )
  Ok(#(
    InferBase(
      directory:,
      cfg:,
      spec_on_disk:,
      spec:,
      stale_assumes:,
      stale_returns_clauses:,
      index:,
      registry:,
      type_info:,
      dependencies: dep_sources,
      dep_files:,
      knowledge_base: kb_base,
      constructors:,
      declared_modules:,
      sorted:,
      refused: reported,
    ),
    Shared(
      ..shared,
      index: Some(index),
      catalog: Some(parsed_catalog),
      fallback_runs:,
      publishers:,
    ),
  ))
}

// The package's modules walked on `package_targets`, against `base`'s knowledge
// base with the package's own foreign functions and factories read on those
// targets, `registry` and `type_info`.
fn infer_fold(
  base: InferBase,
  package_targets: types.PackageTargets,
  registry: SignatureRegistry,
  type_info: typeinfo.TypeInfo,
) -> InferState {
  let InferBase(
    directory:,
    cfg:,
    spec_on_disk:,
    spec:,
    stale_assumes:,
    stale_returns_clauses:,
    index:,
    dependencies: dep_sources,
    constructors:,
    declared_modules:,
    sorted:,
    ..,
  ) = base
  let base_kb =
    base.knowledge_base
    |> effects.with_package_targets(package_targets)
    |> effects.with_foreign_functions(project_foreign_functions(
      index,
      package_targets,
    ))
    |> with_project_factories(index, package_targets, constructors)
  let #(knowledge_base, public_annotations, cache_files) =
    list.fold(sorted, #(base_kb, [], []), fn(state, module_path) {
      let #(kb, acc, cache_acc) = state
      case dict.get(index, module_path) {
        Error(_) -> state
        Ok(#(_gleam_path, module)) -> {
          let inference =
            infer_one_module(
              module,
              module_path,
              cfg.cache_dir,
              kb,
              registry,
              typeinfo.reading_for_module(type_info, module_path),
              declared_modules,
              package_targets,
            )
          // Prepend new entries so each iteration is O(|new|) instead of
          // O(|acc|); final order doesn't matter, merge_inferred keys by name.
          // The cache accumulator is reversed back into topological order
          // before the write phase walks it.
          #(
            inference.knowledge_base,
            list.append(inference.public, acc),
            case inference.cache {
              None -> cache_acc
              Some(cache) -> [cache, ..cache_acc]
            },
          )
        }
      }
    })

  InferState(
    source_directory: directory,
    cfg:,
    spec_on_disk:,
    spec:,
    stale_assumes:,
    stale_returns_clauses:,
    index:,
    registry:,
    type_info:,
    dependencies: dep_sources,
    knowledge_base:,
    public_annotations:,
    cache_files: list.reverse(cache_files),
  )
}

// girard's run of the package on each of `targets`, made once for every
// target's own analysis to share: each of them reads the same sources and
// dependencies, so each would make the same runs.
fn shared_girard_runs(
  index: Dict(String, #(String, glance.Module)),
  dep_files: Dict(String, String),
  targets: List(String),
) -> GirardRuns {
  let entries = index_entries(index)
  let resolver = build_girard_resolver(index, dep_files)
  list.filter_map(targets, fn(target) {
    use run_target <- result.map(case target {
      "erlang" -> Ok(girard.Erlang)
      "javascript" -> Ok(girard.JavaScript)
      _ -> Error(Nil)
    })
    #(target, girard_run(entries, resolver, run_target))
  })
  |> dict.from_list
}

// Every module of the package under `directory`, parsed, by module path.
fn project_index(
  directory: String,
) -> Result(Dict(String, #(String, glance.Module)), GradedError) {
  use gleam_files <- result.try(find_gleam_files(directory))
  use parsed <- result.map(parse_all_files(gleam_files))
  build_module_index(parsed, directory)
}

// `cfg` read on `target` alone.
fn on_target(cfg: config.GradedConfig, target: String) -> config.GradedConfig {
  config.GradedConfig(
    ..cfg,
    targets: types.NamedTargets(set.from_list([target])),
  )
}

// Each target's inference joined into one: every public function's line and
// cache line read over its published parameters and joined; the rest as the
// first target's run left it, beside every target's own run.
fn joined_infer_state(
  cfg: config.GradedConfig,
  last: #(String, InferState),
  earlier: List(#(String, TargetLines)),
  builds: PackageBuilds,
) -> InferState {
  let #(last_target, state) = last
  let lines = list.append(earlier, [#(last_target, target_lines(state))])
  InferState(
    ..state,
    cfg:,
    stale_assumes: list.fold(earlier, state.stale_assumes, fn(acc, entry) {
      set.intersection(acc, { entry.1 }.stale_assumes)
    }),
    stale_returns_clauses: list.fold(
      earlier,
      state.stale_returns_clauses,
      fn(acc, entry) {
        set.intersection(acc, { entry.1 }.stale_returns_clauses)
      },
    ),
    public_annotations: joined_lines(
      builds,
      list.map(lines, fn(entry) { #(entry.0, { entry.1 }.public_annotations) }),
      fn(function) { annotation.split_function_name(function) },
    ),
    cache_files: joined_cache_files(builds, cfg.cache_dir, lines),
  )
}

// One line per function across the targets' lines, in the order the targets
// first state each function. `locate` splits a line's function into its module
// path and bare name.
fn joined_lines(
  builds: PackageBuilds,
  per_target: List(#(String, List(EffectAnnotation))),
  locate: fn(String) -> Result(#(String, String), Nil),
) -> List(EffectAnnotation) {
  let #(order, grouped) =
    list.fold(per_target, #([], dict.new()), fn(acc, entry) {
      let #(target, lines) = entry
      list.fold(lines, acc, fn(acc, line) {
        let #(order, grouped) = acc
        let order = case dict.has_key(grouped, line.function) {
          True -> order
          False -> [line.function, ..order]
        }
        #(
          order,
          dict.upsert(grouped, line.function, fn(existing) {
            [#(target, line), ..option.unwrap(existing, [])]
          }),
        )
      })
    })
  list.reverse(order)
  |> list.filter_map(fn(function) {
    use lines <- result.try(dict.get(grouped, function))
    let lines = list.reverse(lines)
    case lines {
      [] -> Error(Nil)
      [#(_, single)] -> Ok(single)
      [#(_, first), ..] ->
        Ok(joined_line(builds, function, first, lines, locate))
    }
  })
}

// One function's lines from several targets as one line, read on the targets
// that build it over the published parameters of its definitions.
fn joined_line(
  builds: PackageBuilds,
  function: String,
  first: EffectAnnotation,
  lines: List(#(String, EffectAnnotation)),
  locate: fn(String) -> Result(#(String, String), Nil),
) -> EffectAnnotation {
  {
    use #(module_path, name) <- result.try(locate(function))
    use by_name <- result.try(dict.get(builds.functions, module_path))
    use one <- result.map(dict.get(by_name, name))
    joined_built_line(one, first, lines)
  }
  |> result.unwrap(first)
}

// Each module's cache file joined across the targets, line by line.
fn joined_cache_files(
  builds: PackageBuilds,
  cache_dir: String,
  states: List(#(String, TargetLines)),
) -> List(CacheFile) {
  let #(order, files) =
    list.fold(states, #([], dict.new()), fn(acc, entry) {
      let #(target, state) = entry
      list.fold(state.cache_files, acc, fn(acc, cache) {
        let #(order, files) = acc
        let order = case dict.has_key(files, cache.path) {
          True -> order
          False -> [cache.path, ..order]
        }
        let lines =
          list.filter_map(cache.file.lines, fn(line) {
            case line {
              AnnotationLine(annotation, _) -> Ok(annotation)
              _ -> Error(Nil)
            }
          })
        #(
          order,
          dict.upsert(files, cache.path, fn(existing) {
            list.append(option.unwrap(existing, []), [#(target, lines)])
          }),
        )
      })
    })
  list.reverse(order)
  |> list.filter_map(fn(path) {
    use per_target <- result.map(dict.get(files, path))
    let module_path =
      path
      |> string.drop_start(
        string.length(filepath.join(cache_dir, "_")) - string.length("_"),
      )
      |> string.drop_end(string.length(".graded"))
    CacheFile(
      path:,
      file: GradedFile(
        lines: joined_lines(builds, per_target, fn(name) {
          Ok(#(module_path, name))
        })
        |> list.map(AnnotationLine(_, [])),
      ),
    )
  })
}

// Infer effects for a single module. Public annotations come back qualified
// with the module path, and the cache file (with bare names) carries what the
// write phase would write for the module — `None` when the module inferred
// nothing, so no cache file and no directory for it are created. The caller
// accumulates the public annotations for the eventual spec file write.
fn infer_one_module(
  module: glance.Module,
  module_path: String,
  cache_dir: String,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  declared_modules: Set(String),
  package_targets: types.PackageTargets,
) -> ModuleInference {
  let knowledge_base =
    with_module_fallback_effects(
      knowledge_base,
      module,
      module_path,
      registry,
      reading,
      package_targets,
    )
  let #(inferred, returned_operators, provenance) =
    checker.infer_with_returns(
      module,
      module_path,
      knowledge_base,
      [],
      registry,
      reading,
      package_targets,
    )

  // Skip the cache file when there's nothing to record. Saves an mkdir syscall
  // per stdlib-only module.
  let cache = case inferred {
    [] -> None
    _ ->
      Some(CacheFile(
        path: filepath.join(cache_dir, module_path <> ".graded"),
        file: GradedFile(lines: list.map(inferred, AnnotationLine(_, []))),
      ))
  }

  // Thread inferred effects, polymorphic param bounds, and returned-operator
  // signatures into the KB so later modules in the topo-sort pass can resolve
  // call sites targeting this module's functions. A module-level-external module
  // resolves via its declaration, so later modules calling into it agree with
  // `check`.
  let threaded_kb =
    thread_inferred_into_kb(
      knowledge_base,
      inferred,
      returned_operators,
      module_path,
      declared_modules,
    )
  let new_kb =
    effects.with_provenance(
      threaded_kb,
      qualify_bare_names(provenance, module_path),
    )
    |> with_module_baseline_provenance(module, module_path, package_targets)

  let public_names = public_function_names(module)
  let public_annotations =
    inferred
    |> list.filter(fn(ann) { set.contains(public_names, ann.function) })
    |> list.map(fn(ann) {
      EffectAnnotation(..ann, function: module_path <> "." <> ann.function)
    })

  ModuleInference(knowledge_base: new_kb, public: public_annotations, cache:)
}

// Infer project modules in topological order, in memory, folding their
// effects, param bounds, and returned operators into `base_kb` — with existing
// (spec / dependency) entries taking priority, so committed effects are never
// overridden. This lets `check` resolve calls into project modules that haven't
// been `graded infer`-ed yet, without writing the cache. When the import graph
// has a cycle the pass is skipped (the real `graded infer` reports that error;
// `check` degrades to spec-only), but each running fallback's callback shape
// is still recorded beside the `[Unknown]` its unwalked body carries.
fn infer_project_in_memory(
  base_kb: KnowledgeBase,
  index: Dict(String, #(String, glance.Module)),
  registry: SignatureRegistry,
  type_info: typeinfo.TypeInfo,
  declared_modules: Set(String),
  package_targets: types.PackageTargets,
) -> KnowledgeBase {
  case topo.sort(build_dependency_graph(index)) {
    Error(_) ->
      dict.fold(index, base_kb, fn(kb, module_path, entry) {
        let #(_gleam_path, module) = entry
        fold_fallback_summaries(
          kb,
          module_path,
          checker.unwalked_fallback_effects(
            module,
            typeinfo.reading_for_module(type_info, module_path),
            package_targets,
          ),
        )
      })
    Ok(sorted) ->
      list.fold(sorted, base_kb, fn(kb, module_path) {
        case dict.get(index, module_path) {
          Error(_) -> kb
          Ok(#(_gleam_path, module)) ->
            fold_inferred_module(
              kb,
              module,
              module_path,
              registry,
              type_info,
              declared_modules,
              package_targets,
            )
        }
      })
  }
}

// Infer one module against `kb` and fold its effects, param bounds, and
// returned operators (qualified by `module_path`) into the knowledge base, with
// existing entries winning. The per-module step of `infer_project_in_memory`.
fn fold_inferred_module(
  kb: KnowledgeBase,
  module: glance.Module,
  module_path: String,
  registry: SignatureRegistry,
  type_info: typeinfo.TypeInfo,
  declared_modules: Set(String),
  package_targets: types.PackageTargets,
) -> KnowledgeBase {
  let kb =
    with_module_fallback_effects(
      kb,
      module,
      module_path,
      registry,
      typeinfo.reading_for_module(type_info, module_path),
      package_targets,
    )
  let #(inferred, returned_operators, provenance) =
    checker.infer_with_returns(
      module,
      module_path,
      kb,
      [],
      registry,
      typeinfo.reading_for_module(type_info, module_path),
      package_targets,
    )
  let threaded_kb =
    thread_inferred_into_kb(
      kb,
      inferred,
      returned_operators,
      module_path,
      declared_modules,
    )
  effects.with_provenance(
    threaded_kb,
    qualify_bare_names(provenance, module_path),
  )
  |> with_module_baseline_provenance(module, module_path, package_targets)
}

// Fold a module's provenance, as the structural baseline reads it, into the
// baseline.
fn with_module_baseline_provenance(
  knowledge_base: KnowledgeBase,
  module: glance.Module,
  module_path: String,
  package_targets: types.PackageTargets,
) -> KnowledgeBase {
  effects.with_baseline_provenance(
    knowledge_base,
    checker.baseline_provenance(
      module,
      module_path,
      knowledge_base,
      package_targets,
    )
      |> qualify_bare_names(module_path),
  )
}

// Fold what the module's running Gleam fallback bodies do into `knowledge_base`,
// before the module is inferred.
//
// Every pass that infers does this, so a caller of a target-conditional
// `@external` is charged the same effects whichever pass ran: the one that
// reports violations, and the one that writes the spec and cache. A write pass
// that skipped it would publish a caller as pure over an external whose
// fallback is not — and publish it for consumers, whose own walk of this
// package's bodies is a separate pass over dependency source
// (`with_dependency_fallback_effects`) and cannot correct a shipped line.
//
// The walk needs only the callees already folded, which topological order
// guarantees, so it belongs immediately before the module's own inference.
fn with_module_fallback_effects(
  knowledge_base: KnowledgeBase,
  module: glance.Module,
  module_path: String,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  package_targets: types.PackageTargets,
) -> KnowledgeBase {
  let knowledge_base =
    fold_fallback_summaries(
      knowledge_base,
      module_path,
      checker.fallback_effects(
        module,
        module_path,
        knowledge_base,
        registry,
        reading,
        package_targets,
      ),
    )
  effects.with_fallback_operators(
    knowledge_base,
    qualify_bare_names(
      checker.fallback_operators(
        module,
        module_path,
        knowledge_base,
        registry,
        reading,
        package_targets,
      ),
      module_path,
    ),
  )
}

// Fold one module's fallback summaries in, qualified by its module path. Both
// walks — this package's modules and its dependencies' — key their results the
// same way, so which one produced them leaves no mark on the base.
fn fold_fallback_summaries(
  knowledge_base: KnowledgeBase,
  module_path: String,
  summaries: Dict(String, #(EffectTerm, List(types.ParamBound))),
) -> KnowledgeBase {
  effects.with_fallback_summaries(
    knowledge_base,
    qualify_bare_names(summaries, module_path),
  )
}

// Re-key a bare-name map (a module's inferred returned operators or return-value
// provenance) into the `QualifiedName`-keyed form the knowledge base is threaded
// with, qualifying every key by `module_path`.
fn qualify_bare_names(
  map: Dict(String, value),
  module_path: String,
) -> Dict(QualifiedName, value) {
  dict.fold(map, dict.new(), fn(acc, function, value) {
    dict.insert(acc, QualifiedName(module: module_path, function:), value)
  })
}

// Thread a module's freshly inferred effects, polymorphic param bounds, and
// returned-operator signatures (all qualified by `module_path`) into the
// knowledge base. Existing entries win.
//
// A module the consumer declared with a module-level external (in
// `declared_modules`) has its inferred *call effect* dropped so lookup falls
// through to the declared set — the project-module counterpart of the path-dep
// `drop_module_declared` in `infer_path_dep_module`. Returned-operator and
// parameter-bound metadata describe what a function returns and how it consumes
// operator arguments, not its call effect, so they are kept.
fn thread_inferred_into_kb(
  knowledge_base: KnowledgeBase,
  inferred: List(EffectAnnotation),
  returned_operators: Dict(String, types.EffectTerm),
  module_path: String,
  declared_modules: Set(String),
) -> KnowledgeBase {
  let #(effects_dict, params_dict, returns_dict) =
    qualified_inferred(inferred, returned_operators, module_path)
  let effects_dict =
    effects.drop_module_declared(effects_dict, declared_modules)
  // Main project topo loop + the in-memory pre-pass: results inferred this run,
  // originating in this project's own inference.
  fold_inferred_into_kb(
    knowledge_base,
    effects_dict,
    params_dict,
    returns_dict,
    types.ProjectInferred,
  )
}

// Qualify a module's freshly inferred effects, polymorphic param bounds, and
// returned operators by `module_path`, producing the three `QualifiedName`-keyed
// maps the knowledge base is threaded with. Split from `thread_inferred_into_kb`
// so the path-dep inference loop can both fold the maps into its running KB and
// accumulate them for the caller without re-deriving them.
fn qualified_inferred(
  inferred: List(EffectAnnotation),
  returned_operators: Dict(String, types.EffectTerm),
  module_path: String,
) -> #(
  Dict(QualifiedName, types.EffectTerm),
  Dict(QualifiedName, List(types.ParamBound)),
  Dict(QualifiedName, types.EffectTerm),
) {
  let qualify = fn(function) { QualifiedName(module: module_path, function:) }
  let effects_dict =
    list.fold(inferred, dict.new(), fn(acc, ann) {
      dict.insert(acc, qualify(ann.function), ann.effects)
    })
  let params_dict =
    list.fold(inferred, dict.new(), fn(acc, ann) {
      case ann.params {
        [] -> acc
        params -> dict.insert(acc, qualify(ann.function), params)
      }
    })
  let returns_dict = qualify_bare_names(returned_operators, module_path)
  #(effects_dict, params_dict, returns_dict)
}

// Build a set of public function names from a parsed Gleam module.
fn public_function_names(module: glance.Module) -> set.Set(String) {
  list.fold(module.functions, set.new(), fn(acc, def) {
    case def.definition.publicity {
      glance.Public -> set.insert(acc, def.definition.name)
      glance.Private -> acc
    }
  })
}

// Answer census
//
// What graded's own answer census reads off one package: every public
// function's answer as `infer` computes it, the call sites behind each answer
// that is partly unknown, and every `check` line's verdict against that same
// knowledge base. Nothing is read from the spec's committed `effects` lines and
// nothing is written.

// Every public function's line as `infer` would write it, sorted, without
// writing anything.
@internal
pub fn inferred_lines(directory: String) -> Result(List(String), GradedError) {
  use state <- result.map(infer_state(directory))
  state.public_annotations
  |> list.map(annotation.format_annotation)
  |> list.sort(string.compare)
}

// One package's census.
@internal
pub type CensusRoot {
  CensusRoot(
    // Every public function's inferred line, qualified by its module.
    answers: List(EffectAnnotation),
    // For each public function, the contributors `why` lists for it whose
    // effects hold `Unknown`.
    unknown_sources: List(#(String, List(types.CallExplanation))),
    // Every violation and unproved check, rendered as `check` prints it.
    violations: List(String),
  )
}

// The verdicts and unknown sources are read on each target's own run, where
// the package was read on several one at a time, and joined as `check` and
// `why` join them.
@internal
pub fn census_root(directory: String) -> Result(CensusRoot, GradedError) {
  use #(state, runs) <- result.map(infer_runs(directory, True))
  let InferState(cfg:, index:, public_annotations:, ..) = state
  let builds = case runs {
    [] -> no_package_builds()
    runs -> package_builds(index, list.map(runs, fn(entry) { entry.0 }))
  }
  let runs = case runs {
    [] -> [#(None, state)]
    runs -> list.map(runs, fn(entry) { #(Some(entry.0), entry.1) })
  }
  CensusRoot(
    answers: public_annotations,
    unknown_sources: list.filter_map(public_annotations, fn(ann) {
      census_unknown_sources(ann, index, runs, builds)
    }),
    violations: target_reports(
      cfg.spec_file,
      list.map(runs, fn(entry) {
        #(entry.0, census_check_results(entry.1, entry.0, builds))
      }),
    )
      |> list.flat_map(fn(report) { report.violations }),
  )
}

// Every `check` line's verdict against one run's knowledge base, the spec's
// field findings first; on `target`, each read in the parameter names of the
// definition built there and stated in the published ones.
fn census_check_results(
  state: InferState,
  target: Option(String),
  builds: PackageBuilds,
) -> List(CheckResult) {
  let InferState(
    source_directory:,
    cfg:,
    spec:,
    index:,
    registry:,
    type_info:,
    dependencies:,
    knowledge_base:,
    ..,
  ) = state
  let parsed =
    dict.values(index)
    |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  let pairs = case target {
    Some(_) -> package_pairs(index)
    None -> no_package_pairs()
  }
  let #(results, field_report) =
    check_modules(
      case target {
        Some(target) -> spec_on_target(spec, pairs, builds, target)
        None -> spec
      },
      parsed,
      parsed,
      source_directory,
      package_field_index(dependencies, index),
      knowledge_base,
      registry,
      type_info,
      cfg.targets,
    )
  let results = case target {
    Some(target) -> in_published_names(results, pairs, target)
    None -> results
  }
  case field_report.spec_findings {
    [] -> results
    findings -> [
      CheckResult(file: cfg.spec_file, violations: [], findings:, warnings: []),
      ..results
    ]
  }
}

// The contributors to one public answer that `why` lists with an `Unknown` in
// them, under no bounds, on every run that builds the function, each stated in
// the published parameter names; `Error(Nil)` where there are none.
fn census_unknown_sources(
  ann: EffectAnnotation,
  index: Dict(String, #(String, glance.Module)),
  runs: List(#(Option(String), InferState)),
  builds: PackageBuilds,
) -> Result(#(String, List(types.CallExplanation)), Nil) {
  use #(module_path, function) <- result.try(annotation.split_function_name(
    ann.function,
  ))
  use #(_gleam_path, module) <- result.try(dict.get(index, module_path))
  let explanations =
    list.filter(runs, fn(entry) {
      case entry.0 {
        Some(target) -> reads_on(builds, ann.function, target)
        None -> True
      }
    })
    |> list.flat_map(fn(entry) {
      let #(target, state) = entry
      let variant =
        option.to_result(target, Nil)
        |> result.try(checker.target_variant(module, function, _))
      checker.explain(
        module,
        module_path,
        function,
        [[]],
        state.knowledge_base,
        state.registry,
        typeinfo.reading_for_module(state.type_info, module_path),
        state.cfg.targets,
      )
      |> result.map(fn(explained) {
        case variant {
          Ok(#(variants, definition)) ->
            checker.explained_in_published_names(
              variants,
              definition,
              explained,
            )
          Error(Nil) -> explained
        }
      })
      |> result.map(fn(explained) {
        list.flat_map(explained.blocks, fn(block) { block.explanations })
      })
      |> result.unwrap([])
    })
    |> list.filter(fn(explanation) {
      types.contains_unknown(explanation.actual)
    })
    |> list.unique
  use <- bool.guard(when: explanations == [], return: Error(Nil))
  Ok(#(ann.function, explanations))
}

// Write one module's cache file, creating the directory it lives in.
fn write_cache_file(cache: CacheFile) -> Result(Nil, GradedError) {
  let parent_directory = filepath.directory_name(cache.path)
  use Nil <- result.try(
    simplifile.create_directory_all(parent_directory)
    |> result.map_error(DirectoryCreateError(parent_directory, _)),
  )
  write_graded_file(cache.path, cache.file)
}

// Write the project's spec file — the merge with the existing spec has already
// happened in `compute_infer`.
fn write_spec_file(
  spec_path: String,
  merged: GradedFile,
) -> Result(Nil, GradedError) {
  // create_directory_all is a no-op when the parent already exists, so it's
  // safe to call unconditionally — and necessary when the user has
  // configured a non-default spec_file in a subdirectory.
  let parent = filepath.directory_name(spec_path)
  use Nil <- result.try(case parent == "" || parent == "." {
    True -> Ok(Nil)
    False ->
      simplifile.create_directory_all(parent)
      |> result.map_error(DirectoryCreateError(parent, _))
  })
  write_graded_file(spec_path, merged)
}

fn write_graded_file(
  path: String,
  graded_file: GradedFile,
) -> Result(Nil, GradedError) {
  simplifile.write(path, annotation.format_file(graded_file))
  |> result.map_error(FileWriteError(path, _))
}

// Project layout
//
// Resolve the project root, spec file, cache directory, and dependency state
// (`build/packages`, `manifest.toml`) from the source directory and
// `gleam.toml`.

// Read the project's `[tools.graded]` config and return spec/cache paths
// already resolved relative to the project root. The root is the nearest
// ancestor of the source directory holding a `gleam.toml` (see `spec_root_for`),
// so a source directory like `../other/src` resolves its spec and cache under
// `../other`, not under the passed directory.
//
// Resolved paths are returned in the same `GradedConfig` shape so callers
// can use them as-is for I/O without further joining.
fn read_config(directory: String) -> Result(config.GradedConfig, GradedError) {
  // Normalized here too: `format` reaches the spec through this function
  // without going through `source_scope`, so this is where its argument's
  // spelling is settled. A no-op for the callers already scoped.
  let project_root = spec_root_for(normalize_directory(directory))
  let toml_path = filepath.join(project_root, "gleam.toml")
  use raw <- result.try(case config.read(toml_path) {
    Ok(cfg) -> Ok(cfg)
    // Missing gleam.toml: fall back to defaults. A gleam.toml that is there
    // and unreadable — a directory, no permission, a failing device — is an
    // error, so a spec file named from the directory is never written in place
    // of the one the manifest names.
    Error(config.TomlReadError(_, simplifile.Enoent)) ->
      Ok(config.defaults_for(default_package_name(project_root)))
    Error(cause) ->
      Error(InvalidConfig(
        path: toml_path,
        message: config.describe_error(cause),
      ))
  })
  Ok(
    config.GradedConfig(
      ..raw,
      spec_file: config.resolve_path(project_root, raw.spec_file),
      cache_dir: config.resolve_path(project_root, raw.cache_dir),
    ),
  )
}

// Where the spec and cache live: the nearest ancestor `gleam.toml`, found by
// the same walk-up `resolve_package_root` uses for dependency state, so an
// out-of-tree source like `../other/src` roots its spec under `../other` rather
// than writing it back under the passed directory. The one exception is a
// relative source directory nested in the current project whose only ancestor
// `gleam.toml` is the cwd: it keeps acting as its own root (the `src` layout
// aside), so pointing graded at a subtree of the current project — e.g. a test
// fixture directory — doesn't write the spec into the surrounding project.
fn spec_root_for(directory: String) -> String {
  let walked = resolve_package_root(directory)
  let source_root = source_root_for(directory)
  case walked == "." && source_root != "." {
    True -> source_root
    False -> walked
  }
}

// The Gleam project root: where dependency state lives — `build/packages`,
// `manifest.toml`, and the `gleam.toml` that lists path dependencies. Found by
// walking up from the source directory to the nearest ancestor holding a
// `gleam.toml`, so a source directory nested inside a project (e.g. a test
// fixture tree) inherits that project's installed dependencies rather than the
// process cwd's. Falls back to the source directory when no `gleam.toml` is
// found anywhere up the tree.
fn resolve_package_root(directory: String) -> String {
  let source_root = source_root_for(directory)
  find_gleam_toml_dir(source_root, source_root)
}

// The directory a source argument is rooted at. `src` is the production layout,
// whose root is the current directory; any other directory acts as its own
// root. Shared by spec/cache resolution (`read_config`) and the dependency-root
// walk-up so the two stay in step.
fn source_root_for(directory: String) -> String {
  case directory {
    "src" -> "."
    _ -> directory
  }
}

// Dependency `.graded` specs live under `<root>/build/packages/<dep>/`.
fn packages_dir(package_root: String) -> String {
  filepath.join(package_root, "build/packages")
}

// `manifest.toml` (installed dependency versions, for catalog selection) sits
// at the project root next to `gleam.toml`.
fn manifest_path(package_root: String) -> String {
  filepath.join(package_root, "manifest.toml")
}

// Dependency sources
//
// What graded derives from a dependency's own `src/`: the names each module
// defines, parameter positions for positional argument matching, the
// update-builder signatures its public builders declare, and the `@external`s
// it declares. One walk parses each file once and derives all four from that
// parse, under the module path the file sits at.

// What one or more dependency source trees yielded, held by module path rather
// than flattened by name. Everything a module path contributes comes from the
// single copy of it that won the scan: a dependency that moved to a path
// dependency without a `gleam clean` leaves a stale copy under `build/packages`
// beside the live one, and the copy this build compiles against is the only one
// that speaks for the path — for what it defines, what its signatures are, what
// builders it exports and what it declares foreign alike.
type DependencySources {
  DependencySources(modules: Dict(String, ScannedModule))
}

// One scanned copy of a module path: everything derived from that single parse.
type ScannedModule {
  ParsedModule(
    // The functions it defines, private ones included: the question is whether
    // the name exists, and a line naming a private dependency function is dead
    // for a different reason than a typo is.
    functions: Set(String),
    // Its parameter signatures, for positional argument matching at polymorphic
    // call sites.
    registry: SignatureRegistry,
    // The update builders it exports. Only public builders cross a package
    // boundary, so only those are recorded. Read from the source the consumer
    // compiled against, so a builder resolved from here can never skew from a
    // stale serialized `update` line — it takes precedence over the spec-loaded
    // map.
    updates: Dict(#(String, String), types.UpdateSignature),
    // The factories it exports, on the same terms as `updates`: only a public
    // one crosses a package boundary, and a consumer's call to one wires the
    // field from its own argument.
    factories: Dict(#(String, String), types.FactorySignature),
    // The constructors it defines, by `#(module path, variant)`, with their
    // ordered field labels. A consumer constructing one positionally routes its
    // arguments through these.
    constructors: Dict(#(String, String), List(Option(String))),
    // Whether the two maps above are everything this module's source states, or
    // whether a construction in it waits on another module's declared labels.
    signatures: SignatureState,
    // Every `@external` it declares. Scanned here because this walk already
    // parses each dependency module once, and because it is the only evidence a
    // consumer has: a dependency's spec cannot be trusted to say which of its
    // own functions are foreign, since a stale line for one is exactly what
    // this map exists to refuse.
    foreign: Dict(types.QualifiedName, types.ForeignFunction),
    // The file this copy was read from, and the module paths it imports. Kept
    // for the fallback-body pass, which re-reads and re-parses the modules whose
    // bodies it walks: the path names *this* copy, the one the build compiles
    // against, so a duplicate left elsewhere on disk is never the one walked.
    // The imports order that pass, so a fallback calling another dependency's
    // fallback is walked after it.
    //
    // Two cheap facts of the parse rather than the parsed module itself: an AST
    // kept on this record would live as long as the context that holds the whole
    // scan, and the worst case is every module of every dependency at once.
    // Whether the pass has anything to walk here is not among them — `foreign`
    // above already answers it, and a second copy of that answer is one more
    // thing to keep in step with how those entries are selected.
    source_path: String,
    imports: List(String),
    // What its custom types say about their record fields. Read from the
    // source the consumer compiled against, for the same reason `updates` is.
    field_index: types.FieldIndex,
    // Its custom types and type aliases in full: every variant's fields and
    // generic parameters.
    type_definitions: typedefs.TypeRegistry,
    // The targets a definition its public interface may read is kept on
    // alone, so that girard types the interface differently there.
    target_variants: Set(String),
    // Each public function it defines once per target, beside all of its
    // definitions: what a line its package published over the name is read
    // through.
    pairs: Dict(String, List(glance.Definition(glance.Function))),
    // Each public function some definition of which is kept on some targets
    // alone, beside all of its definitions: which targets build it.
    gated: Dict(String, List(glance.Definition(glance.Function))),
  )
  // The file would not read or parse. Recorded rather than dropped so it
  // shadows any copy of the path scanned before it, and contributes nothing in
  // its place: the shadowed copy is not the one this build compiles against,
  // and a dependency graded cannot read falls back to its serialized signature.
  UnreadableModule
}

fn empty_dependency_sources() -> DependencySources {
  DependencySources(modules: dict.new())
}

// The three name-keyed views of a scan, each folded out of the winning copies
// once the whole walk is in hand.

// Parameter signatures for every function the scanned copies define.
fn dependency_registry(sources: DependencySources) -> SignatureRegistry {
  use acc, _path, scanned <- dict.fold(sources.modules, signatures.empty())
  case scanned {
    ParsedModule(registry:, ..) -> signatures.merge(acc, registry)
    UnreadableModule -> acc
  }
}

// What the scanned copies say about their custom types' record fields.
fn dependency_type_definitions(
  sources: DependencySources,
) -> typedefs.TypeRegistry {
  use acc, _path, scanned <- dict.fold(sources.modules, typedefs.empty())
  case scanned {
    ParsedModule(type_definitions:, ..) -> typedefs.merge(acc, type_definitions)
    UnreadableModule -> acc
  }
}

fn dependency_field_index(sources: DependencySources) -> types.FieldIndex {
  use acc, _path, scanned <- dict.fold(
    sources.modules,
    signatures.empty_field_index(),
  )
  case scanned {
    ParsedModule(field_index:, ..) ->
      signatures.merge_field_index(acc, field_index)
    UnreadableModule -> acc
  }
}

// The factories the scanned copies export.
fn dependency_factories(
  sources: DependencySources,
) -> Dict(#(String, String), types.FactorySignature) {
  use acc, _path, scanned <- dict.fold(sources.modules, dict.new())
  case scanned {
    ParsedModule(factories:, ..) -> dict.merge(acc, factories)
    UnreadableModule -> acc
  }
}

// Every constructor the package can name, keyed by `#(defining module,
// variant)`: its dependencies' and its own, the package's own winning a clash.
fn package_constructors(
  index: Dict(String, #(String, glance.Module)),
  dep_sources: DependencySources,
  package_targets: types.PackageTargets,
) -> Dict(#(String, String), List(Option(String))) {
  dict.merge(
    dependency_constructors(dep_sources),
    dict.fold(index, dict.new(), fn(acc, module_path, entry) {
      let #(_gleam_path, module) = entry
      dict.merge(
        acc,
        extract.constructor_registry(
          module_path,
          module,
          types.declaration_targets(package_targets),
        ),
      )
    }),
  )
}

// The constructors the scanned copies define.
fn dependency_constructors(
  sources: DependencySources,
) -> Dict(#(String, String), List(Option(String))) {
  use acc, _path, scanned <- dict.fold(sources.modules, dict.new())
  case scanned {
    ParsedModule(constructors:, ..) -> dict.merge(acc, constructors)
    UnreadableModule -> acc
  }
}

// The update builders the scanned copies export.
fn dependency_updates(
  sources: DependencySources,
) -> Dict(#(String, String), types.UpdateSignature) {
  use acc, _path, scanned <- dict.fold(sources.modules, dict.new())
  case scanned {
    ParsedModule(updates:, ..) -> dict.merge(acc, updates)
    UnreadableModule -> acc
  }
}

// The `@external`s the scanned copies declare.
fn dependency_foreign(
  sources: DependencySources,
) -> Dict(types.QualifiedName, types.ForeignFunction) {
  use acc, _path, scanned <- dict.fold(sources.modules, dict.new())
  case scanned {
    ParsedModule(foreign:, ..) -> dict.merge(acc, foreign)
    UnreadableModule -> acc
  }
}

// Dependency fallback bodies
//
// An `@external` a dependency declares for one target only falls back to its
// Gleam body on the others, and a consumer compiling those targets runs that
// body. Walked here, once per command, so the consumer is charged what it does
// rather than the `[Unknown]` an unwalked body is worth.

// Fold what every dependency `@external`'s running Gleam fallback body does into
// `knowledge_base`.
//
// Run once the spec layers are folded — the catalog, the dependency specs, the
// module-level assumes and any spec-less path dependency's own inference — and
// before this package's modules are inferred, so a body reaching a dependency
// name resolves it against everything that can key it, and every later lookup
// of a walked external reads the summary rather than the widening.
//
// The scan kept a path rather than an AST, so each module is read and parsed
// again here and dropped before the next: one AST live at a time, as during the
// scan itself. The reading below holds the retained modules together for the
// length of one girard run and hands back no AST.
fn with_dependency_fallback_effects(
  knowledge_base: KnowledgeBase,
  dep_files: Dict(String, String),
  retained: Dict(String, RetainedModule),
  typed: Dict(String, typeinfo.ModuleReading),
  registry: SignatureRegistry,
  package_targets: types.PackageTargets,
  targets: List(girard.Target),
  typing: FallbackTyping,
) -> #(KnowledgeBase, GirardRuns) {
  use <- bool.guard(when: dict.is_empty(retained), return: #(
    knowledge_base,
    typing.runs,
  ))
  // A module the path-dependency pass already typed keeps that reading rather
  // than paying for a second run of its own.
  let untyped =
    dict.filter(retained, fn(_module_path, module) {
      !dict.has_key(typed, module.source_path)
    })
  let #(fresh, runs) = fallback_readings(dep_files, untyped, targets, typing)
  let readings = dict.merge(fresh, typed)
  let #(ordered, cyclic) = dependency_walk_order(retained)
  // A cycle member's body is never walked, but its callback shape is still
  // recorded beside the `[Unknown]` an unwalked body carries.
  let knowledge_base =
    list.fold(cyclic, knowledge_base, fn(kb, entry) {
      let #(module_path, retained) = entry
      case parsed_source(typing.parsed, retained.source_path) {
        Error(Nil) -> kb
        Ok(module) ->
          fold_fallback_summaries(
            kb,
            module_path,
            checker.unwalked_dependency_fallback_effects(
              module,
              package_targets,
            ),
          )
      }
    })
  use <- pair_with(runs)
  use kb, #(module_path, retained) <- list.fold(ordered, knowledge_base)
  // A re-parse that fails is the `UnreadableModule` case one stage later: the
  // module is skipped, and its externals keep the `[Unknown]` an unwalked body
  // carries.
  case parsed_source(typing.parsed, retained.source_path) {
    Error(Nil) -> kb
    Ok(module) ->
      fold_fallback_summaries(
        kb,
        module_path,
        checker.dependency_fallback_effects(
          module,
          module_path,
          kb,
          registry,
          reading_for_source(readings, retained.source_path),
          package_targets,
        ),
      )
  }
}

// girard's reading of the dependency modules the fallback pass has a body to
// walk in, keyed by the source file that pass re-parses. Keyed by path rather
// than by module path because the retained set merges package ownership away,
// and two dependencies may name a module the same.
//
// The retained modules are what is typed — not the trees they sit in, and not
// one package at a time. A dependency whose externals all declare their effects
// contributes nothing here, and one module of a fifty-module package is all the
// walk reads. Everything those modules import, the rest of their own packages
// included, is resolved behind girard's resolver off the consumer's tree, which
// holds every installed package and every runtime local package's source; a
// package installed from hex is read there exactly as a local one is.
//
// The parsed modules live only as long as the girard run: what comes back is
// the reading, and the walk re-parses each module in its turn.
fn fallback_readings(
  dep_files: Dict(String, String),
  retained: Dict(String, RetainedModule),
  targets: List(girard.Target),
  typing: FallbackTyping,
) -> #(Dict(String, typeinfo.ModuleReading), GirardRuns) {
  use <- bool.guard(when: dict.is_empty(retained), return: #(
    dict.new(),
    typing.runs,
  ))
  let index = parsed_retained(retained, typing.parsed)
  // girard's runs, by target, over every module some target walks: a run on
  // another target reads its own modules' results from the same runs. A run
  // whose runs no other target shares types its own modules alone.
  let union = case typing.shared {
    True -> dict.merge(parsed_retained(typing.union, typing.parsed), index)
    False -> index
  }
  let runs =
    list.fold(targets, typing.runs, fn(runs, target) {
      let name = typeinfo.target_name(target)
      case dict.has_key(runs, name) {
        True -> runs
        False -> {
          dict.insert(
            runs,
            name,
            girard_run(
              index_entries(union),
              build_girard_resolver(union, dep_files),
              target,
            ),
          )
        }
      }
    })
  let type_info =
    annotate_with_runs(
      index_entries(index),
      build_girard_resolver(index, dep_files),
      targets,
      runs,
    )
  let readings =
    dict.fold(index, dict.new(), fn(acc, module_path, entry) {
      dict.insert(
        acc,
        entry.0,
        typeinfo.reading_for_module(type_info, module_path),
      )
    })
  #(readings, case typing.shared {
    True -> runs
    False -> typing.runs
  })
}

// How the fallback pass types the modules it walks: `union`, every module some
// target walks, and the girard runs over it already made, which are kept for
// other targets' runs where `shared`.
type FallbackTyping {
  FallbackTyping(
    union: Dict(String, RetainedModule),
    runs: GirardRuns,
    shared: Bool,
    // The dependency modules the run already parsed, by source path.
    parsed: ParsedSources,
  )
}

// Each of `retained`, parsed, by module path; one that does not read or parse
// is left out.
fn parsed_retained(
  retained: Dict(String, RetainedModule),
  parsed: ParsedSources,
) -> Dict(String, #(String, glance.Module)) {
  dict.fold(retained, dict.new(), fn(acc, module_path, module) {
    case parsed_source(parsed, module.source_path) {
      Error(Nil) -> acc
      Ok(found) -> dict.insert(acc, module_path, #(module.source_path, found))
    }
  })
}

// The module at `source_path`: as `parsed` holds it, else read and parsed.
fn parsed_source(
  parsed: ParsedSources,
  source_path: String,
) -> Result(glance.Module, Nil) {
  case dict.get(parsed, source_path) {
    Ok(found) -> found
    Error(Nil) -> read_and_parse_gleam_or_nil(source_path)
  }
}

// The fallback typing for a run on `shared`'s terms: over `retained` alone, or,
// where runs on other targets follow, over every dependency module with an
// `@external` that leaves some target to a Gleam body.
fn fallback_typing(
  shared: Shared,
  dependencies: DependencySources,
  retained: Dict(String, RetainedModule),
) -> FallbackTyping {
  use <- bool.guard(
    when: !shared.split,
    return: FallbackTyping(
      union: retained,
      runs: dict.new(),
      shared: False,
      parsed: shared.parsed,
    ),
  )
  let union =
    dict.fold(dependencies.modules, retained, fn(acc, module_path, scanned) {
      case scanned {
        ParsedModule(source_path:, imports:, ..) ->
          case runs_a_fallback(shared.parsed, source_path) {
            True ->
              dict.insert(
                acc,
                module_path,
                RetainedModule(source_path:, imports:),
              )
            False -> acc
          }
        UnreadableModule -> acc
      }
    })
  FallbackTyping(
    union:,
    runs: shared.fallback_runs,
    shared: True,
    parsed: shared.parsed,
  )
}

// Whether the module `parsed` holds at `source_path` has an `@external` whose
// Gleam body runs on some target.
fn runs_a_fallback(parsed: ParsedSources, source_path: String) -> Bool {
  case dict.get(parsed, source_path) {
    Ok(Ok(module)) ->
      list.any(module.functions, fn(definition) {
        extract.declares_external(definition)
        && checker.has_running_fallback(definition, both_targets())
      })
    _ -> False
  }
}

// `next()` beside `extra`.
fn pair_with(extra: b, next: fn() -> a) -> #(a, b) {
  #(next(), extra)
}

// The reading recorded for the module re-parsed from `source_path`, or the
// empty one — which is every dependency graded did not type.
fn reading_for_source(
  readings: Dict(String, typeinfo.ModuleReading),
  source_path: String,
) -> typeinfo.ModuleReading {
  case dict.get(readings, source_path) {
    Ok(reading) -> reading
    Error(Nil) -> typeinfo.no_reading()
  }
}

// One dependency module the fallback-body pass has something to walk in: where
// its winning copy was read from, and the module paths it imports.
type RetainedModule {
  RetainedModule(source_path: String, imports: List(String))
}

// Those modules, keyed by module path. Which they are is read off `foreign`
// rather than recorded beside it, so the pass and the scan cannot come to
// different answers about which `@external`s fall back to a running body.
fn retained_fallback_modules(
  sources: DependencySources,
) -> Dict(String, RetainedModule) {
  use acc, module_path, scanned <- dict.fold(sources.modules, dict.new())
  case scanned {
    UnreadableModule -> acc
    ParsedModule(foreign:, source_path:, imports:, ..) ->
      case
        list.any(dict.values(foreign), fn(entry) { entry.runs_fallback_body })
      {
        False -> acc
        True ->
          dict.insert(acc, module_path, RetainedModule(source_path:, imports:))
      }
  }
}

// The order the retained modules are walked in: callees before callers, so a
// fallback body calling another dependency's fallback reads its summary rather
// than the `[Unknown]` an unwalked one carries.
//
// One graph over every retained module, not one per package: a fallback in one
// package can call a fallback in another, and the scan keys by module path with
// package ownership merged away, so there is no per-package boundary to sort
// within. Edges are imports restricted to the retained modules — a retained
// module reaching another only through an unretained one does not reach its
// *summary*, since the intermediate's own call is a resolved lookup rather than
// a walk.
//
// Expected acyclic, because the winning copies are the ones the build compiles
// against and the compiler accepted that set — but not relied on, which is why
// the components rather than a plain sort: `scc_order` groups a cycle instead of
// rejecting the whole graph, so the modules that *can* be ordered still are.
// A component of more than one module is a cycle: its members import each
// other, so no order settles either against the other's summary. Those come
// back in the second list, walked by nothing, so their callback shapes can
// still be recorded; a module merely downstream of one reads it as an
// ordinary unwalked name.
fn dependency_walk_order(
  retained: Dict(String, RetainedModule),
) -> #(List(#(String, RetainedModule)), List(#(String, RetainedModule))) {
  let components = topo.scc_order(fallback_import_graph(retained))
  warn_on_cyclic_modules(components)
  let resolve = fn(paths: List(String)) {
    list.filter_map(paths, fn(module_path) {
      dict.get(retained, module_path)
      |> result.map(fn(retained) { #(module_path, retained) })
    })
  }
  let #(ordered, cyclic) =
    list.partition(components, fn(component) {
      case component {
        [_] -> True
        _ -> False
      }
    })
  #(resolve(list.flatten(ordered)), resolve(list.flatten(cyclic)))
}

// Name the modules dropped for importing each other, once for the whole graph.
fn warn_on_cyclic_modules(components: List(List(String))) -> Nil {
  let cyclic =
    list.flat_map(components, fn(component) {
      case component {
        [_] -> []
        cycle -> cycle
      }
    })
  use <- bool.guard(when: cyclic == [], return: Nil)
  io.println_error(
    "graded: warning: dependency modules import each other in a cycle ("
    <> string.join(list.sort(cyclic, string.compare), ", ")
    <> "); their Gleam fallback bodies are not walked, and each charges an "
    <> "[Unknown] share beside any callback it may call",
  )
}

// The import graph over the retained modules, with both ends of every edge among
// them: an import of anything else names no node, and a graph edge to a node it
// does not hold orders nothing.
fn fallback_import_graph(
  retained: Dict(String, RetainedModule),
) -> Dict(String, Set(String)) {
  let every = set.from_list(dict.keys(retained))
  use _module_path, module <- dict.map_values(retained)
  module.imports
  |> list.filter(set.contains(every, _))
  |> set.from_list
}

// Answer for `name` from the scan, read off the winning copy of its module and
// that copy alone — the answer a name is owed is what the source this build
// compiles against says, not what any copy left on disk beside it still holds.
fn dependency_name(
  sources: DependencySources,
  name: QualifiedName,
) -> lint.DependencyName {
  case dict.get(sources.modules, name.module) {
    Error(Nil) | Ok(UnreadableModule) -> lint.UnreadDependency
    Ok(ParsedModule(functions:, ..)) ->
      case set.contains(functions, name.function) {
        True -> lint.DefinedByDependency
        False -> lint.AbsentFromDependency
      }
  }
}

// Merge two scans; `b`'s copy of a module path replaces `a`'s whole, so no path
// is ever spoken for by two copies at once.
// Whether a scanned module's derived signatures are final.
//
// A module is scanned on its own, and a positional construction of another
// module's record routes through labels that module declares — read only once
// every module has been scanned. A module whose signatures wait on those is
// read again then, and no other module is.
type SignatureState {
  SignaturesFinal
  SignaturesAwaitLabels
}

fn merge_dependency_sources(
  a: DependencySources,
  b: DependencySources,
) -> DependencySources {
  DependencySources(modules: dict.merge(a.modules, b.modules))
}

// The dependency scan a command reads, and the same scan as it stood before
// any local package the root does not declare by path was loaded.
type TreeScan {
  TreeScan(
    // Installed packages and every local package the root's runtime
    // dependencies reach. An installed or direct copy of a module path wins
    // over a newly loaded one.
    sources: DependencySources,
    // Installed packages and the root's own path dependencies.
    baseline: DependencySources,
    // The module paths only a newly loaded package's copy holds.
    newly_loaded_modules: Set(String),
  )
}

fn dependency_scan(
  package_root: String,
  local: LocalPackages,
  package_targets: types.PackageTargets,
  parsed: ParsedTree,
  scanned: Dict(String, ScannedModule),
) -> TreeScan {
  let baseline =
    merge_dependency_sources(
      packages_dir_sources(
        packages_dir(package_root),
        package_targets,
        parsed,
        scanned,
      ),
      path_dep_sources(package_root, local, package_targets, parsed, scanned),
    )
  let newly_loaded =
    package_tree.newly_loaded(local)
    |> list.fold(empty_dependency_sources(), fn(acc, package) {
      merge_dependency_sources(
        acc,
        source_dir_sources(
          package.directory <> "/src",
          package_targets,
          parsed,
          scanned,
        ),
      )
    })
  let newly_loaded_modules =
    dict.keys(newly_loaded.modules)
    |> list.filter(fn(module_path) {
      !dict.has_key(baseline.modules, module_path)
    })
    |> set.from_list
  let labelled = with_declared_labels(baseline, package_targets, parsed.files)
  // With no module of their own, the newly loaded packages add nothing the
  // installed and direct copies do not already hold.
  let sources = case set.is_empty(newly_loaded_modules) {
    True -> labelled
    False ->
      merge_dependency_sources(newly_loaded, baseline)
      |> with_declared_labels(package_targets, parsed.files)
  }
  TreeScan(sources:, baseline: labelled, newly_loaded_modules:)
}

// Record what the knowledge base's constructors, factories and update
// builders were before the newly loaded packages were scanned, where any was.
fn with_tree_baseline(
  knowledge_base: KnowledgeBase,
  index: Dict(String, #(String, glance.Module)),
  scan: TreeScan,
  package_targets: types.PackageTargets,
) -> KnowledgeBase {
  use <- bool.guard(
    when: set.is_empty(scan.newly_loaded_modules),
    return: knowledge_base,
  )
  let built =
    with_builders(
      effects.new_knowledge_base(),
      index,
      scan.baseline,
      package_targets,
      package_constructors(index, scan.baseline, package_targets),
    )
  effects.with_structural_baseline(
    knowledge_base,
    effects.constructors(built),
    effects.factories(built),
    effects.updates(built),
    scan.newly_loaded_modules,
  )
}

// The catalog and the installed packages' specs, as a knowledge base, over the
// `@external`s of the scan without the newly loaded packages. Their own
// externals are added to it for the run; a newly loaded package is weighed
// against it as it stands.
fn catalog_knowledge_base(
  package_root: String,
  catalog: effects.BundledCatalog,
  scan: TreeScan,
  reading: effects.SpecReading,
) -> KnowledgeBase {
  effects.knowledge_base_from_catalog(
    packages_dir(package_root),
    catalog,
    dependency_foreign(scan.baseline),
    reading,
  )
}

// What the run answered before any newly loaded package was loaded:
// `catalog_kb` and every line of the consumer's own spec, over the callback
// parameters of the scan without them. `None` where no package is newly
// loaded.
fn arbitration_baseline(
  local: LocalPackages,
  catalog_kb: KnowledgeBase,
  scan: TreeScan,
  project_registry: SignatureRegistry,
  spec: GradedFile,
  stale_assumes: Set(String),
  stale_returns_clauses: Set(String),
  package_targets: types.PackageTargets,
) -> Option(KnowledgeBase) {
  use <- bool.guard(when: package_tree.newly_loaded(local) == [], return: None)
  catalog_kb
  |> effects.with_package_targets(package_targets)
  |> effects.with_callback_params(
    signatures.callback_param_names(signatures.merge(
      dependency_registry(scan.baseline),
      project_registry,
    )),
  )
  |> with_spec_assumes(spec, stale_assumes)
  |> with_spec_declared_returns(spec, stale_returns_clauses)
  |> with_committed_spec(spec, stale_assumes)
  |> effects.with_closed_returned_operators(
    effects.load_spec_returns_from_file(spec),
    types.CommittedSpec,
  )
  |> with_spec_type_fields(spec)
  |> Some
}

// Derive again the signatures that waited on another module's declared labels.
//
// A dependency constructs a record defined in another module positionally as
// readily as one of its own, and the labels that routes through belong to the
// module defining the constructor — in hand only once every dependency module
// is scanned. Only the modules that named one are read again, and the pass runs
// at all only where some module did.
fn with_declared_labels(
  sources: DependencySources,
  package_targets: types.PackageTargets,
  parsed: ParsedSources,
) -> DependencySources {
  use <- bool.guard(when: !awaits_labels(sources), return: sources)
  let constructors = dependency_constructors(sources)
  DependencySources(
    modules: dict.map_values(sources.modules, fn(module_path, scanned) {
      case scanned {
        ParsedModule(signatures: SignaturesAwaitLabels, source_path:, ..) ->
          case parsed_source(parsed, source_path) {
            Ok(module) ->
              with_routed_templates(
                scanned,
                module,
                module_path,
                constructors,
                package_targets,
              )
            // A copy that no longer reads or parses keeps what the first scan
            // derived, exactly as an unreadable one keeps nothing.
            Error(_) -> scanned
          }
        ParsedModule(..) | UnreadableModule -> scanned
      }
    }),
  )
}

fn awaits_labels(sources: DependencySources) -> Bool {
  dict.values(sources.modules)
  |> list.any(fn(scanned) {
    case scanned {
      ParsedModule(signatures: SignaturesAwaitLabels, ..) -> True
      ParsedModule(..) | UnreadableModule -> False
    }
  })
}

// One module's factories and update builders, derived with every module's
// declared labels in reach. Everything else the first scan read of it stands:
// this is the same source, read again for the one derivation that needed more
// than it.
fn with_routed_templates(
  scanned: ScannedModule,
  module: glance.Module,
  module_path: String,
  constructors: Dict(#(String, String), List(Option(String))),
  package_targets: types.PackageTargets,
) -> ScannedModule {
  case scanned {
    UnreadableModule -> scanned
    ParsedModule(..) -> {
      let context =
        extract.build_import_context_on(
          module,
          types.declaration_targets(package_targets),
        )
        |> extract.with_module_path(module_path)
        |> extract.with_cross_constructors(constructors)
      ParsedModule(
        ..scanned,
        updates: extract.public_update_signatures(
          module,
          module_path,
          context,
          types.declaration_targets(package_targets),
        ),
        factories: extract.public_factory_signatures(
          module,
          module_path,
          context,
          types.declaration_targets(package_targets),
        ),
        signatures: SignaturesFinal,
      )
    }
  }
}

// Attach the builders derived from dependency source and from the current
// package's own modules; the package's own win (module namespaces don't
// overlap). Seeded ahead of every inference pass — the path-dep fallback and
// the in-memory project pass — so each composes builder overlays the same way
// the final pass does. Attaching them later leaves a widened result that is
// never recomputed.
fn with_builders(
  knowledge_base: KnowledgeBase,
  index: Dict(String, #(String, glance.Module)),
  dep_sources: DependencySources,
  package_targets: types.PackageTargets,
  // Folded once for the run by the caller, which reads it too: a builder that
  // constructs another module's record positionally routes its arguments
  // through these labels.
  constructors: Dict(#(String, String), List(Option(String))),
) -> KnowledgeBase {
  knowledge_base
  |> effects.with_constructors(constructors)
  |> effects.with_factories(dependency_factories(dep_sources))
  |> effects.with_updates(dependency_updates(dep_sources))
  |> effects.with_updates(
    qualify_by_module(index, fn(module_path, module) {
      extract.update_map(
        module_path,
        module,
        types.declaration_targets(package_targets),
        constructors,
      )
    }),
  )
}

// Fold the factories this package's own modules define, routed through
// `constructors` — and into the structural baseline, where there is one,
// routed through the labels it holds.
fn with_project_factories(
  knowledge_base: KnowledgeBase,
  index: Dict(String, #(String, glance.Module)),
  package_targets: types.PackageTargets,
  constructors: Dict(#(String, String), List(Option(String))),
) -> KnowledgeBase {
  let factories = fn(constructors) {
    qualify_by_module(index, fn(module_path, module) {
      extract.factory_map(
        module_path,
        module,
        types.declaration_targets(package_targets),
        constructors,
      )
    })
  }
  let knowledge_base =
    effects.with_factories(knowledge_base, factories(constructors))
  case effects.baseline_constructors(knowledge_base) {
    Some(baseline) ->
      effects.with_baseline_factories(knowledge_base, factories(baseline))
    None -> knowledge_base
  }
}

// Scan the `src/` tree of every installed dependency under `build/packages`.
fn packages_dir_sources(
  packages_directory: String,
  package_targets: types.PackageTargets,
  parsed: ParsedTree,
  scanned: Dict(String, ScannedModule),
) -> DependencySources {
  case simplifile.read_directory(packages_directory) {
    Error(_) -> empty_dependency_sources()
    Ok(entries) ->
      list.fold(entries, empty_dependency_sources(), fn(acc, dep) {
        let src_dir =
          filepath.join(filepath.join(packages_directory, dep), "src")
        merge_dependency_sources(
          acc,
          source_dir_sources(src_dir, package_targets, parsed, scanned),
        )
      })
  }
}

// Every dependency source file a run's scan reads, parsed, by path: shared by
// the analyses of one package on several targets, which each scan the same
// files.
type ParsedSources =
  Dict(String, Result(glance.Module, Nil))

// The parsed dependency sources beside the files the walk that parsed them
// found under each `src/` tree, for a scan reading each tree's files without
// searching every path.
type ParsedTree {
  ParsedTree(files: ParsedSources, dirs: Dict(String, List(String)))
}

fn parsed_dependency_sources(
  package_root: String,
  local: LocalPackages,
) -> #(ParsedSources, Dict(String, List(String))) {
  dependency_source_dirs(package_root, local)
  |> list.fold(#(dict.new(), dict.new()), fn(acc, source_dir) {
    use acc, _module_path, source_path, parsed <- signatures.fold_source_dir(
      source_dir,
      acc,
    )
    let #(files, dirs) = acc
    #(
      dict.insert(files, source_path, parsed),
      dict.upsert(dirs, source_dir, fn(listed) {
        [source_path, ..option.unwrap(listed, [])]
      }),
    )
  })
}

// Every `src/` tree a run's dependency scan reads: each installed package's,
// each direct path dependency's and each newly loaded local package's.
fn dependency_source_dirs(
  package_root: String,
  local: LocalPackages,
) -> List(String) {
  let packages_directory = packages_dir(package_root)
  let installed = case simplifile.read_directory(packages_directory) {
    Ok(entries) ->
      list.map(entries, fn(dep) {
        filepath.join(filepath.join(packages_directory, dep), "src")
      })
    Error(_) -> []
  }
  let direct =
    list.map(local.direct, fn(dep) {
      config.resolve_path(package_root, dep.1) <> "/src"
    })
  let loaded =
    list.map(package_tree.newly_loaded(local), fn(package) {
      package.directory <> "/src"
    })
  list.flatten([installed, direct, loaded])
}

// What the scan derives from every dependency module that reads no target,
// by source path: the same on every target, so built once for all of them.
fn target_blind_scan(
  package_root: String,
  local: LocalPackages,
  parsed: ParsedSources,
  parsed_dirs: Dict(String, List(String)),
) -> Dict(String, ScannedModule) {
  dependency_source_dirs(package_root, local)
  |> list.fold(dict.new(), fn(acc, source_dir) {
    use acc, module_path, source_path, module <- signatures.fold_source_dir_with(
      source_dir,
      parsed,
      parsed_dirs,
      acc,
    )
    case module {
      Ok(module) ->
        case checker.reads_targets(module) {
          True -> acc
          False ->
            dict.insert(
              acc,
              source_path,
              scanned_module(
                module_path,
                source_path,
                Ok(module),
                both_targets(),
              ),
            )
        }
      Error(Nil) -> acc
    }
  })
}

fn both_targets() -> types.PackageTargets {
  types.NamedTargets(types.every_target())
}

// Each public function of `module` some definition of which is kept on some
// targets alone, beside all of its definitions.
fn public_gated(
  module: glance.Module,
) -> Dict(String, List(glance.Definition(glance.Function))) {
  use <- bool.guard(
    when: !list.any(module.functions, extract.gated),
    return: dict.new(),
  )
  checker.module_definitions(module)
  |> dict.filter(fn(_name, definitions) {
    list.any(definitions, extract.gated)
    && list.any(definitions, fn(definition) {
      definition.definition.publicity == glance.Public
    })
  })
}

// Each public function `module` defines once per target, beside all of its
// definitions.
fn public_pairs(
  module: glance.Module,
) -> Dict(String, List(glance.Definition(glance.Function))) {
  use <- bool.guard(
    when: !checker.defines_public_function_per_target(module),
    return: dict.new(),
  )
  let grouped =
    list.fold(module.functions, dict.new(), fn(acc, definition) {
      dict.upsert(acc, definition.definition.name, fn(existing) {
        list.append(option.unwrap(existing, []), [definition])
      })
    })
  dict.filter(grouped, fn(_name, definitions) {
    case definitions {
      [_, _, ..] ->
        list.any(definitions, fn(definition) {
          definition.definition.publicity == glance.Public
        })
      _ -> False
    }
  })
}

// What the scan derives from one module path's parse, read on
// `package_targets`.
fn scanned_module(
  module_path: String,
  source_path: String,
  parsed: Result(glance.Module, Nil),
  package_targets: types.PackageTargets,
) -> ScannedModule {
  case parsed {
    Ok(module) -> {
      // The two template readings below each walk this module's imports and
      // constructors; built once here rather than once per reading.
      let context =
        extract.build_import_context_on(
          module,
          types.declaration_targets(package_targets),
        )
        |> extract.with_module_path(module_path)
      ParsedModule(
        functions: module_function_names(module),
        registry: built_registry(module_path, module, package_targets),
        updates: extract.public_update_signatures(
          module,
          module_path,
          context,
          types.declaration_targets(package_targets),
        ),
        factories: extract.public_factory_signatures(
          module,
          module_path,
          context,
          types.declaration_targets(package_targets),
        ),
        constructors: extract.constructor_registry(
          module_path,
          module,
          types.declaration_targets(package_targets),
        ),
        signatures: case
          extract.awaits_declared_labels(
            module,
            context,
            types.declaration_targets(package_targets),
          )
        {
          True -> SignaturesAwaitLabels
          False -> SignaturesFinal
        },
        foreign: checker.dependency_foreign_functions(
          module,
          module_path,
          package_targets,
        ),
        source_path:,
        imports: module_import_paths(module),
        field_index: signatures.field_index_from_module(
          module_path,
          module,
          signatures.type_alias_map(module.type_aliases),
        ),
        type_definitions: typedefs.from_module(
          module_path,
          module,
          types.declaration_targets(package_targets),
        ),
        target_variants: interface_target_variants(module),
        pairs: public_pairs(module),
        gated: public_gated(module),
      )
    }
    Error(Nil) -> UnreadableModule
  }
}

// Scan one package's `src/` tree, recording what each module derives under its
// module path. A file that would not read or parse derives nothing, and is
// recorded as the unreadable copy of its path.
fn source_dir_sources(
  source_dir: String,
  package_targets: types.PackageTargets,
  parsed: ParsedTree,
  scanned: Dict(String, ScannedModule),
) -> DependencySources {
  use acc, module_path, source_path, parsed <- signatures.fold_source_dir_with(
    source_dir,
    parsed.files,
    parsed.dirs,
    empty_dependency_sources(),
  )
  // A module that reads no target derives the same on every target, so a scan
  // on another target may already hold it.
  let scanned = case dict.get(scanned, source_path) {
    Ok(scanned) -> scanned
    Error(Nil) ->
      scanned_module(module_path, source_path, parsed, package_targets)
  }
  DependencySources(modules: dict.insert(acc.modules, module_path, scanned))
}

// The targets on which `module`'s public interface types something
// differently, because a definition it reaches is kept on that target alone
// while the module defines its name again for another:
//
// - a public function, constant, type alias or non-opaque custom type defined
//   once per target;
// - a type a public signature, constant, alias or non-opaque custom type's
//   fields name, where that type is an alias defined once per target, or one
//   reaching such an alias through the module's own aliases, private ones
//   included;
// - any definition defined once per target, where a public function or
//   constant states no complete type and girard infers one that may reach it.
//
// A name kept on one target and defined nowhere else is read only from code
// kept on that target too. An opaque type's fields are no part of what another
// module reads.
fn interface_target_variants(module: glance.Module) -> Set(String) {
  use <- bool.guard(
    when: !list.any(module.functions, gated)
      && !list.any(module.constants, gated)
      && !list.any(module.type_aliases, gated)
      && !list.any(module.custom_types, gated),
    return: set.new(),
  )
  let inferred =
    list.any(module.functions, fn(definition) {
      definition.definition.publicity == glance.Public
      && !fully_annotated(definition.definition)
    })
    || list.any(module.constants, fn(definition) {
      definition.definition.publicity == glance.Public
      && definition.definition.annotation == None
    })
  let read = fn(publicity) { publicity == glance.Public || inferred }
  let exposed_type = fn(definition: glance.Definition(glance.CustomType)) {
    definition.definition.publicity == glance.Public
    && !definition.definition.opaque_
  }
  let dependent = target_dependent_types(module)
  let interface = public_interface_types(module)
  list.flatten([
    paired_targets(
      list.filter(module.functions, fn(definition) {
        read(definition.definition.publicity)
      }),
      fn(definition) { definition.definition.name },
    ),
    paired_targets(
      list.filter(module.constants, fn(definition) {
        read(definition.definition.publicity)
      }),
      fn(definition) { definition.definition.name },
    ),
    paired_type_names(
      module,
      fn(definition) { read(definition.definition.publicity) },
      exposed_type,
    )
      |> list.map(fn(pair) { pair.0 }),
    dict.fold(dependent, [], fn(acc, target, names) {
      case list.any(interface, mentions_any(_, names)) {
        True -> [target, ..acc]
        False -> acc
      }
    }),
  ])
  |> set.from_list
}

// The module's own alias names whose expansion depends on each target: one
// defined once per target, and one that names such an alias, through any chain
// of the module's aliases. A custom type's name types the same on every
// target, so only aliases carry the dependence on.
fn target_dependent_types(module: glance.Module) -> Dict(String, Set(String)) {
  let aliased =
    list.map(module.type_aliases, fn(definition) { definition.definition.name })
    |> set.from_list
  // A name defined once per target where one of its definitions is an alias:
  // what it expands to differs between the targets, whatever the others are.
  let seeds =
    paired_type_entries(module, read_any, read_any)
    |> list.filter(fn(entry) { set.contains(aliased, entry.1) })
    |> list.map(fn(entry) { #(entry.0, entry.1) })
    |> list.fold(dict.new(), fn(acc, pair) {
      let #(target, name) = pair
      dict.upsert(acc, target, fn(names) {
        set.insert(option.unwrap(names, set.new()), name)
      })
    })
  let definitions =
    list.map(module.type_aliases, fn(definition) {
      #(definition.definition.name, [definition.definition.aliased])
    })
  dict.map_values(seeds, fn(_target, names) {
    dependent_closure(names, definitions)
  })
}

fn dependent_closure(
  names: Set(String),
  definitions: List(#(String, List(glance.Type))),
) -> Set(String) {
  let grown =
    list.fold(definitions, names, fn(acc, definition) {
      let #(name, types) = definition
      case list.any(types, mentions_any(_, acc)) {
        True -> set.insert(acc, name)
        False -> acc
      }
    })
  case set.size(grown) == set.size(names) {
    True -> names
    False -> dependent_closure(grown, definitions)
  }
}

// Every type another module reads off this one: public signatures, constant
// annotations, aliases, and a non-opaque custom type's fields.
fn public_interface_types(module: glance.Module) -> List(glance.Type) {
  list.flatten([
    list.flat_map(module.functions, fn(definition) {
      let function = definition.definition
      case function.publicity {
        glance.Public ->
          option.values([
            function.return,
            ..list.map(function.parameters, fn(parameter) { parameter.type_ })
          ])
        glance.Private -> []
      }
    }),
    list.filter_map(module.constants, fn(definition) {
      case definition.definition.publicity {
        glance.Public -> option.to_result(definition.definition.annotation, Nil)
        glance.Private -> Error(Nil)
      }
    }),
    list.filter_map(module.type_aliases, fn(definition) {
      case definition.definition.publicity {
        glance.Public -> Ok(definition.definition.aliased)
        glance.Private -> Error(Nil)
      }
    }),
    list.flat_map(module.custom_types, fn(definition) {
      let custom = definition.definition
      case custom.publicity, custom.opaque_ {
        glance.Public, False ->
          list.flat_map(custom.variants, fn(variant) {
            list.map(variant.fields, variant_field_type)
          })
        _, _ -> []
      }
    }),
  ])
}

fn variant_field_type(field: glance.VariantField) -> glance.Type {
  case field {
    glance.LabelledVariantField(item:, ..) -> item
    glance.UnlabelledVariantField(item:) -> item
  }
}

// Whether a type names, unqualified, one of `names`.
fn mentions_any(type_: glance.Type, names: Set(String)) -> Bool {
  case type_ {
    glance.NamedType(name:, module: None, parameters:, ..) ->
      set.contains(names, name) || list.any(parameters, mentions_any(_, names))
    glance.NamedType(parameters:, ..) ->
      list.any(parameters, mentions_any(_, names))
    glance.TupleType(elements:, ..) ->
      list.any(elements, mentions_any(_, names))
    glance.FunctionType(parameters:, return:, ..) ->
      mentions_any(return, names)
      || list.any(parameters, mentions_any(_, names))
    glance.VariableType(..) | glance.HoleType(..) -> False
  }
}

fn gated(definition: glance.Definition(a)) -> Bool {
  list.any(definition.attributes, fn(attribute) { attribute.name == "target" })
}

fn fully_annotated(function: glance.Function) -> Bool {
  function.return != None
  && list.all(function.parameters, fn(parameter) { parameter.type_ != None })
}

// For each type `module` defines once per target, counting aliases and custom
// types as the one namespace they share: the target its definition is kept on
// and whether `alias_read` or `custom_read` keeps that definition.
fn paired_type_names(
  module: glance.Module,
  alias_read: fn(glance.Definition(glance.TypeAlias)) -> Bool,
  custom_read: fn(glance.Definition(glance.CustomType)) -> Bool,
) -> List(#(String, Bool)) {
  paired_type_entries(module, alias_read, custom_read)
  |> list.filter_map(fn(entry) {
    case entry.2 {
      True -> Ok(#(entry.0, entry.3))
      False -> Error(Nil)
    }
  })
}

// Each definition of a type name `module` defines once per target: the target
// it is kept on, its name, whether the matching reader keeps it, and whether
// it is an alias.
fn paired_type_entries(
  module: glance.Module,
  alias_read: fn(glance.Definition(glance.TypeAlias)) -> Bool,
  custom_read: fn(glance.Definition(glance.CustomType)) -> Bool,
) -> List(#(String, String, Bool, Bool)) {
  let entries =
    list.append(
      list.map(module.type_aliases, fn(definition) {
        #(
          definition.definition.name,
          extract.compiled_targets(definition, types.every_target()),
          alias_read(definition),
          True,
        )
      }),
      list.map(module.custom_types, fn(definition) {
        #(
          definition.definition.name,
          extract.compiled_targets(definition, types.every_target()),
          custom_read(definition),
          False,
        )
      }),
    )
  let counts =
    list.fold(entries, dict.new(), fn(acc, entry) {
      dict.upsert(acc, entry.0, fn(count) { option.unwrap(count, 0) + 1 })
    })
  list.filter_map(entries, fn(entry) {
    let #(name, targets, read, alias) = entry
    case dict.get(counts, name), set.to_list(targets) {
      Ok(count), [target] if count > 1 -> Ok(#(target, name, read, alias))
      _, _ -> Error(Nil)
    }
  })
}

fn read_any(_definition: a) -> Bool {
  True
}

// The one target `@target` keeps each definition on, for the definitions
// whose name another definition of `definitions` shares.
fn paired_targets(
  definitions: List(glance.Definition(a)),
  name: fn(glance.Definition(a)) -> String,
) -> List(String) {
  let counts =
    list.fold(definitions, dict.new(), fn(acc, definition) {
      dict.upsert(acc, name(definition), fn(count) {
        option.unwrap(count, 0) + 1
      })
    })
  list.filter_map(definitions, fn(definition) {
    case
      dict.get(counts, name(definition)),
      set.to_list(extract.compiled_targets(definition, types.every_target()))
    {
      Ok(count), [target] if count > 1 -> Ok(target)
      _, _ -> Error(Nil)
    }
  })
}

// The targets some dependency module the package's modules reach, directly or
// through other dependency modules, reads differently on.
fn dependency_target_variants(
  index: Dict(String, #(String, glance.Module)),
  sources: DependencySources,
) -> Set(String) {
  let roots =
    dict.fold(index, [], fn(acc, _path, entry) {
      list.append(module_import_paths(entry.1), acc)
    })
  reach_variants(roots, sources, set.new(), set.new())
}

fn reach_variants(
  pending: List(String),
  sources: DependencySources,
  seen: Set(String),
  variants: Set(String),
) -> Set(String) {
  case pending {
    [] -> variants
    [module_path, ..rest] ->
      case
        set.contains(seen, module_path),
        dict.get(sources.modules, module_path)
      {
        False, Ok(ParsedModule(imports:, target_variants:, ..)) ->
          reach_variants(
            list.append(imports, rest),
            sources,
            set.insert(seen, module_path),
            set.union(variants, target_variants),
          )
        _, _ ->
          reach_variants(rest, sources, set.insert(seen, module_path), variants)
      }
  }
}

// The module paths a module imports.
fn module_import_paths(module: glance.Module) -> List(String) {
  list.map(module.imports, fn(definition) { definition.definition.module })
}

// Every function a module defines, public and private alike.
fn module_function_names(module: glance.Module) -> Set(String) {
  list.fold(module.functions, set.new(), fn(acc, definition) {
    set.insert(acc, definition.definition.name)
  })
}

fn find_gleam_toml_dir(dir: String, original: String) -> String {
  let dir = case dir {
    "" -> "."
    _ -> dir
  }
  case simplifile.is_file(filepath.join(dir, "gleam.toml")) {
    Ok(True) -> dir
    _ -> {
      let parent = case filepath.directory_name(dir) {
        "" -> "."
        other -> other
      }
      // Halt at a fixed point so an exhausted walk falls back to the source dir.
      // `.` is its own fixed point, halting a relative walk at the cwd. An
      // absolute walk halts at `/`, whose `directory_name` is `""` → `.`: left
      // unchecked it would fold into the cwd and wrongly adopt that project's
      // root, so `/` halts explicitly.
      case parent == dir || dir == "/" {
        True -> original
        False -> find_gleam_toml_dir(parent, original)
      }
    }
  }
}

fn default_package_name(project_root: String) -> String {
  // Used only when no gleam.toml is found: the project root's last path
  // segment, or "graded" when that's empty, "/", or ".".
  case filepath.base_name(project_root) {
    "" | "/" | "." -> "graded"
    name -> name
  }
}

fn read_spec(spec_path: String) -> Result(GradedFile, GradedError) {
  read_spec_on_disk(spec_path) |> result.map(fn(spec) { spec.1 })
}

// The spec file's bytes and the parse of them. A spec file that isn't there
// yet reads as no bytes and no lines — not as an empty file, which parses to
// one blank line — so a project with no spec is inferred from scratch. A spec
// file that is there but cannot be read, or that does not parse, is an error
// naming the offending line: no command carries on as though the package had
// no annotations, and `infer` stops before merging rather than writing an
// empty file over the hand-written lines.
fn read_spec_on_disk(
  spec_path: String,
) -> Result(#(String, GradedFile), GradedError) {
  case effects.read_optional_file(spec_path) {
    Ok(None) -> Ok(#("", GradedFile(lines: [])))
    Error(cause) -> Error(FileReadError(spec_path, cause))
    Ok(Some(content)) ->
      annotation.parse_file(content)
      |> result.map(fn(file) { #(content, file) })
      |> result.map_error(graded_parse_error(spec_path, _))
  }
}

// Path dependencies
//
// Fold every local package the root's runtime dependencies reach into the
// knowledge base: read a committed spec when present, otherwise infer the
// package from source.

// Each runtime local package, callees before callers, so a package is folded
// after every package it reaches:
//
// 1. Its spec file (named by its own `[tools.graded]`, defaulting to
//    `<package_name>.graded`), when it ships one. A root path dependency's
//    spec folds through `with_path_dep_spec`, below the consumer's own entries
//    and above the catalog.
//
// 2. Otherwise — no spec, or one whose bytes graded cannot read, which is
//    warned about and read as shipping none — inference over its source. A
//    root path dependency's results gap-fill against every written line and
//    are arbitrated with the catalog by `with_path_dep_inferred`.
//
// A package the root does not declare by path is weighed instead, name by
// name, against `baseline` — what the run answered before that package was
// loaded — through `with_newly_loaded_spec` and `with_newly_loaded_inferred`:
// its contribution is written only where it takes no written answer away and
// adds no `[Unknown]` the baseline answer lacked.
//
// A module the consumer declared with a module-level external (in
// `consumer_modules`) is not inferred over (see `infer_path_dep`), so the
// consumer's declaration governs it. A root path dependency's spec is left
// untouched by it: a function-keyed entry from an authoritative dep spec still
// wins over the *consumer's* module-level external, per-function beating
// module-level. Against the catalog the dependency's own module-level line
// reads the other way — for a module it ships, it answers over the catalog's
// per-function entries too (`with_path_dep_spec`).
//
// Every package is typed against `dep_files`, which holds every runtime local
// package's modules beside the installed ones.
fn enrich_with_path_deps(
  knowledge_base: KnowledgeBase,
  package_root: String,
  local: LocalPackages,
  dep_files: Dict(String, String),
  consumer_modules: Set(String),
  package_targets: types.PackageTargets,
  retained: Dict(String, RetainedModule),
  baseline: Option(KnowledgeBase),
  registry: SignatureRegistry,
  reading: effects.SpecReading,
  dep_sources: DependencySources,
) -> #(
  KnowledgeBase,
  Dict(String, typeinfo.ModuleReading),
  List(coverage.PathDependency),
) {
  let direct = dict.from_list(local.direct)
  use state, package <- list.fold(
    package_tree.runtime_order(local),
    #(knowledge_base, dict.new(), []),
  )
  let #(kb, readings, typed) = state
  let name = package.name
  let #(location, newly_loaded) = case dict.get(direct, name) {
    // A root path dependency is read where the root's declaration names it,
    // relative to the project root unless absolute.
    Ok(dep_path) -> #(config.resolve_path(package_root, dep_path), None)
    Error(Nil) -> #(package.directory, baseline)
  }
  let spec_path = filepath.join(location, package.spec_file)
  let load = effects.load_dep_spec_at(location, spec_path, reading)
  effects.warn_dep_spec_load(name, load)
  case load {
    effects.SpecLoaded(spec:, ..) -> {
      let origin = types.PathDependency(package: name)
      let kb = case newly_loaded {
        Some(baseline) ->
          effects.with_newly_loaded_spec(kb, baseline, spec, origin)
        None -> effects.with_path_dep_spec(kb, spec, origin)
      }
      #(kb, readings, typed)
    }
    effects.SpecAbsent | effects.SpecUnreadable(..) -> {
      let index = path_dep_index(location)
      let type_info =
        type_index(
          index,
          dep_files,
          package_targets,
          dependency_target_variants(index, dep_sources),
          dict.new(),
        )
      let readings = retained_readings(readings, index, type_info, retained)
      // Counted beside the knowledge base for the coverage report: a
      // dependency installed from hex is not typed and has none of this.
      let typed = [path_dependency_row(name, type_info), ..typed]
      case
        infer_typed_path_dep(
          location,
          index,
          type_info,
          kb,
          consumer_modules,
          package_targets,
          registry,
        )
      {
        Error(Nil) -> #(kb, readings, typed)
        Ok(inferred) -> #(
          fold_path_dep_inference(kb, inferred, name, newly_loaded),
          readings,
          typed,
        )
      }
    }
  }
}

// Fold what inferring one path dependency produced into the knowledge base:
// weighed against `baseline` for a package the root does not declare by path,
// as a root path dependency's otherwise. Inference over the dep's source, not a
// line its author wrote: the origin says so, so nothing downstream reads it as
// a declaration.
fn fold_path_dep_inference(
  knowledge_base: KnowledgeBase,
  inferred: PathDepInference,
  name: String,
  baseline: Option(KnowledgeBase),
) -> KnowledgeBase {
  let origin = types.PathDependencyInferred(package: name)
  case baseline {
    Some(baseline) ->
      effects.with_newly_loaded_inferred(
        knowledge_base,
        baseline,
        inferred.effects,
        inferred.params,
        inferred.returns,
        inferred.provenance,
        origin,
      )
    None ->
      fold_inferred_into_kb(
        knowledge_base,
        inferred.effects,
        inferred.params,
        inferred.returns,
        origin,
      )
      |> effects.with_provenance(inferred.provenance)
      |> effects.with_baseline_provenance(inferred.baseline_provenance)
  }
}

// The readings this dep's typing already holds for the modules the fallback
// pass has a body to walk in, keyed by source path the way that pass reads
// them. Only the copies the scan retained: a module the scan settled on another
// package's copy of is not the one that pass walks.
fn retained_readings(
  readings: Dict(String, typeinfo.ModuleReading),
  index: Dict(String, #(String, glance.Module)),
  type_info: typeinfo.TypeInfo,
  retained: Dict(String, RetainedModule),
) -> Dict(String, typeinfo.ModuleReading) {
  use acc, module_path, #(source_path, _module) <- dict.fold(index, readings)
  case dict.get(retained, module_path) {
    Ok(RetainedModule(source_path: walked, ..)) if walked == source_path ->
      dict.insert(
        acc,
        source_path,
        typeinfo.reading_for_module(type_info, module_path),
      )
    Ok(RetainedModule(..)) | Error(Nil) -> acc
  }
}

// Scan the `src/` tree of every path dependency declared in `gleam.toml`. Path
// deps live at their declared `path`, not under `build/packages`, so
// `packages_dir_sources` never sees them — without this their cross-module
// callees lack the parameter-position info that positional (unlabeled) argument
// matching needs to bind effect variables at the call site, and their builders
// resolve only from a serialized `update` line.
fn path_dep_sources(
  package_root: String,
  local: LocalPackages,
  package_targets: types.PackageTargets,
  parsed: ParsedTree,
  scanned: Dict(String, ScannedModule),
) -> DependencySources {
  list.fold(local.direct, empty_dependency_sources(), fn(acc, dep) {
    let #(_name, dep_path) = dep
    let resolved_dep_path = config.resolve_path(package_root, dep_path)
    merge_dependency_sources(
      acc,
      source_dir_sources(
        resolved_dep_path <> "/src",
        package_targets,
        parsed,
        scanned,
      ),
    )
  })
}

// Apply three `QualifiedName`-keyed inferred maps — effects, polymorphic param
// bounds, and returned-operator signatures — to the knowledge base. The shared
// tail of `thread_inferred_into_kb` and the infer-from-source path-dep branch:
// effects alone would leave a higher-order callee's bound unloaded, so its
// callback's effect variable would leak unsubstituted into every caller.
// Existing effects and param bounds win; the returned-operator summaries are
// `Fresh` — inferred this run, so they win over a committed clause's entry for
// the same key. `lookup_origin` names the source of the effect terms,
// recorded for the keys this merge wins.
//
// The origin also selects which effects fold runs: a spec-less path
// dependency's walk is the one source the catalog arbitrates with, so it goes
// through `with_path_dep_inferred`. Read off the origin rather than threaded
// beside it, so the dependency's own pass and the consumer's fold of its
// results cannot drift apart. The project's own inference is not this rule's
// subject — its modules are not catalogued.
fn fold_inferred_into_kb(
  knowledge_base: KnowledgeBase,
  effs: Dict(QualifiedName, types.EffectTerm),
  params: Dict(QualifiedName, List(types.ParamBound)),
  returns: Dict(QualifiedName, types.EffectTerm),
  lookup_origin: types.LookupOrigin,
) -> KnowledgeBase {
  case lookup_origin {
    types.PathDependencyInferred(..) ->
      effects.with_path_dep_inferred(
        knowledge_base,
        effs,
        params,
        lookup_origin,
      )
    types.UserAssume
    | types.CommittedSpec
    | types.ProjectInferred
    | types.DependencySpec(..)
    | types.PathDependency(..)
    | types.Catalog(..)
    | types.ModuleAssumeOrigin(..)
    | types.FieldAssumeOrigin(..) ->
      knowledge_base
      |> effects.with_inferred(effs, lookup_origin)
      |> effects.with_inferred_params(params)
  }
  |> effects.with_fresh_returned_operators(returns, lookup_origin)
}

// The module files girard resolves a path dependency's own tree against: the
// consumer's whole dependency scan, plus the `src/` of every path dependency
// the *dependency* declares, and theirs in turn.
//
// A nested path dependency is named only in the dep's own `gleam.toml`, so the
// consumer's scan — installed packages and the consumer's own path deps — does
// not hold it, and a dep module importing one would be typed by nothing: girard
// declines the whole function, and every shadowed receiver in it reads
// `[Unknown]`.
//
// The consumer's scan wins a collision, since it holds the copy the build
// compiles against. A dependency reached twice, or one whose declarations lead
// back to it, is entered once.
//
// Exposed (pub) so a test can ask what a dep resolves against without going
// through `gleam.toml` resolution twice.
@internal
pub fn path_dep_resolver_files(
  dep_path: String,
  dep_files: Dict(String, String),
) -> Dict(String, String) {
  path_dep_resolver_files_recording_visits(dep_path, dep_files).0
}

// The same walk, handing back the dependency directories it entered, in the
// order it entered them. A directory entered twice appears twice, which is what
// makes "each is entered once" a property a test can read rather than one it
// has to infer from timing.
@internal
pub fn path_dep_resolver_files_recording_visits(
  dep_path: String,
  dep_files: Dict(String, String),
) -> #(Dict(String, String), List(String)) {
  // The dependency the walk starts at is entered by the caller, which holds its
  // modules already — its declarations are all this reads of it.
  let walk =
    nested_path_dep_files(
      PathDepWalk(
        files: dict.new(),
        entered: set.from_list([config.normalized_path(dep_path)]),
        order: [],
      ),
      dep_path,
    )
  #(dict.merge(walk.files, dep_files), list.reverse(walk.order))
}

// What the walk over a dependency's own path dependencies carries: the module
// files found so far, the directories already entered, and the order they were
// entered in.
//
// `entered` holds normalized paths. `resolve_path` joins a declared `path` onto
// the directory that declared it and leaves the `..` segments in, so one
// directory two dependencies reach by different routes arrives under two
// spellings; keyed raw, each spelling is its own entry and a diamond is walked
// once per route through it.
type PathDepWalk {
  PathDepWalk(
    files: Dict(String, String),
    entered: Set(String),
    order: List(String),
  )
}

fn nested_path_dep_files(walk: PathDepWalk, dep_path: String) -> PathDepWalk {
  use walk, dep <- list.fold(
    package_tree.path_dependencies(filepath.join(dep_path, "gleam.toml")),
    walk,
  )
  let #(_name, nested_path) = dep
  let nested = config.resolve_path(dep_path, nested_path)
  let entered = config.normalized_path(nested)
  use <- bool.guard(when: set.contains(walk.entered, entered), return: walk)
  // Read on the way in, past the check rather than before it: a directory
  // several dependencies name costs one read of its `src/`, not one per edge
  // that reaches it. Read under the collapsed path, so the file names the
  // resolver hands girard are the ones any other scan of that tree produces.
  nested_path_dep_files(
    PathDepWalk(
      files: dict.merge(
        effects.source_dir_module_files(filepath.join(entered, "src")),
        walk.files,
      ),
      entered: set.insert(walk.entered, entered),
      order: [entered, ..walk.order],
    ),
    entered,
  )
}

// Every module of a path dependency's `src/` tree, keyed the way the type index
// and the effect inference both read it: module path -> #(source file, parsed
// module). A file that does not parse is left out, as it is for the project.
@internal
pub fn path_dep_index(
  dep_path: String,
) -> Dict(String, #(String, glance.Module)) {
  use acc, module_path, gleam_path, parsed <- signatures.fold_source_dir(
    dep_path <> "/src",
    dict.new(),
  )
  case parsed {
    Ok(module) -> dict.insert(acc, module_path, #(gleam_path, module))
    Error(Nil) -> acc
  }
}

/// Build the dependency-graph index for a single path dep, topo-sort it,
/// then infer every module in dependency order. Returns the union of all
/// inferred effects, polymorphic param bounds, returned-operator signatures,
/// and return-value provenance keyed by `QualifiedName` so the caller can fold
/// them into the global knowledge base — the provenance lets a consumer resolve
/// a computed-receiver call into the dep (`dep.inner(dep.factory(x))`) that a
/// committed dep spec, which does not serialize provenance, cannot. Errors are
/// swallowed (returned as `Error(Nil)`) to
/// preserve the existing tolerance: a malformed dep shouldn't break the whole
/// project.
///
/// Exposed (pub) primarily so tests can exercise the topological-order path
/// inference on a temporary directory tree without going through
/// `gleam.toml` resolution. Production callers go through
/// `enrich_with_path_deps` which reads `gleam.toml` to discover dep paths.
@internal
pub fn infer_path_dep(
  dep_path: String,
  dep_files: Dict(String, String),
  base_kb: KnowledgeBase,
  consumer_modules: Set(String),
  package_targets: types.PackageTargets,
) -> Result(
  #(
    Dict(QualifiedName, types.EffectTerm),
    Dict(QualifiedName, List(types.ParamBound)),
    Dict(QualifiedName, types.EffectTerm),
    Dict(QualifiedName, types.ReturnProvenance),
  ),
  Nil,
) {
  let index = path_dep_index(dep_path)
  infer_typed_path_dep(
    dep_path,
    index,
    path_dep_type_info(dep_path, index, dep_files, package_targets),
    base_kb,
    consumer_modules,
    package_targets,
    signatures.empty(),
  )
  |> result.map(fn(inferred) {
    #(inferred.effects, inferred.params, inferred.returns, inferred.provenance)
  })
}

// What inferring one path dependency produced, keyed by `QualifiedName`: its
// effects, polymorphic parameter bounds, returned-operator summaries and
// return-value provenance, and the provenance as the structural baseline reads
// it.
type PathDepInference {
  PathDepInference(
    effects: Dict(QualifiedName, types.EffectTerm),
    params: Dict(QualifiedName, List(types.ParamBound)),
    returns: Dict(QualifiedName, types.EffectTerm),
    provenance: Dict(QualifiedName, types.ReturnProvenance),
    baseline_provenance: Dict(QualifiedName, types.ReturnProvenance),
  )
}

// girard's reading of a path dependency, resolved from the consumer's tree —
// the one place a dep's own imports of installed packages can be found — with
// the path dependencies the dep declares for itself beside it.
fn path_dep_type_info(
  dep_path: String,
  index: Dict(String, #(String, glance.Module)),
  dep_files: Dict(String, String),
  package_targets: types.PackageTargets,
) -> typeinfo.TypeInfo {
  build_type_index(
    index,
    path_dep_resolver_files(dep_path, dep_files),
    package_targets,
  )
}

// The inference itself, over a dep already indexed and typed. Split from the
// entry point above so the caller that holds a reading of the dep — the one
// that hands the same modules to the fallback-body pass — spends one girard run
// on it rather than two.
fn infer_typed_path_dep(
  dep_path: String,
  index_with_paths: Dict(String, #(String, glance.Module)),
  type_info: typeinfo.TypeInfo,
  base_kb: KnowledgeBase,
  consumer_modules: Set(String),
  package_targets: types.PackageTargets,
  // The run's own registry, so a call from the dep into any package the run
  // parsed matches the callee's parameters as the project's own call does.
  run_registry: SignatureRegistry,
) -> Result(PathDepInference, Nil) {
  // Path-dep checks come from the dep's spec file (loaded by
  // enrich_with_path_deps), not from per-module files. Inference here only
  // needs the parsed module.
  let index =
    dict.map_values(index_with_paths, fn(_module_path, entry) {
      let #(_gleam_path, module) = entry
      #(module, [])
    })

  let graph =
    dict.map_values(index, fn(_module_path, entry) {
      let #(module, _checks) = entry
      extract.imported_modules(module)
      |> set.filter(fn(imported) { dict.has_key(index, imported) })
    })

  // A registry covering the dep's own modules over the run's, so a call from
  // the dep (`b.run` calling `a.apply(cb)`, or `other.apply(cb)` in another
  // package) matches the callee's bound by parameter position during
  // inference — exactly as the project registry does for the project's own
  // modules. The dep's own modules win a collision. Built from the
  // already-parsed `index`, not re-read.
  let registry =
    dict.fold(index, run_registry, fn(acc, module_path, entry) {
      let #(module, _checks) = entry
      signatures.merge(
        acc,
        built_registry(module_path, module, package_targets),
      )
    })

  use sorted <- result.try(topo.sort(graph) |> result.map_error(fn(_) { Nil }))
  // The dep's own KB is internal to this pass; its entries are re-folded by the
  // caller under the package name `gleam.toml` declared. The directory name is
  // what this entry point knows the dep by.
  let origin =
    types.PathDependencyInferred(package: filepath.base_name(dep_path))
  let #(inferred, _final_kb) =
    list.fold(
      sorted,
      #(
        PathDepInference(
          effects: dict.new(),
          params: dict.new(),
          returns: dict.new(),
          provenance: dict.new(),
          baseline_provenance: dict.new(),
        ),
        base_kb,
      ),
      fn(state, module_path) {
        infer_path_dep_module(
          state,
          module_path,
          index,
          registry,
          type_info,
          consumer_modules,
          origin,
          package_targets,
        )
      },
    )
  Ok(inferred)
}

fn infer_path_dep_module(
  state: #(PathDepInference, KnowledgeBase),
  module_path: String,
  index: Dict(String, #(glance.Module, List(types.EffectAnnotation))),
  registry: SignatureRegistry,
  type_info: typeinfo.TypeInfo,
  consumer_modules: Set(String),
  lookup_origin: types.LookupOrigin,
  package_targets: types.PackageTargets,
) -> #(PathDepInference, KnowledgeBase) {
  let #(acc, kb) = state
  case dict.get(index, module_path) {
    Error(_) -> state
    Ok(#(module, checks)) -> {
      let #(annotations, returned_operators, provenance) =
        checker.infer_with_returns(
          module,
          module_path,
          kb,
          checks,
          registry,
          typeinfo.reading_for_module(type_info, module_path),
          package_targets,
        )
      // Qualify the module's results once, then both fold them into the dep's
      // own KB (so later modules in its topo order resolve calls into this one)
      // and accumulate them for the caller.
      let #(inferred_effs, inferred_params, inferred_returns) =
        qualified_inferred(annotations, returned_operators, module_path)
      // A consumer's module-level external governs only the *call effect* of the
      // module's functions: drop the inferred effect so it resolves to the
      // declared one — for the dep's later modules and the consumer alike.
      // Returned-operator and parameter-bound metadata describe what a function
      // returns and how it consumes operator arguments, not its call effect, so
      // they are kept; a sibling wrapper doing `let f = mod.make(); f()` still
      // resolves `f` instead of falling to `[Unknown]`.
      let inferred_effs =
        effects.drop_module_declared(inferred_effs, consumer_modules)
      let inferred_provenance = qualify_bare_names(provenance, module_path)
      let baseline_provenance =
        checker.baseline_provenance(module, module_path, kb, package_targets)
        |> qualify_bare_names(module_path)
      let new_kb =
        fold_inferred_into_kb(
          kb,
          inferred_effs,
          inferred_params,
          inferred_returns,
          lookup_origin,
        )
        |> effects.with_provenance(inferred_provenance)
        |> effects.with_baseline_provenance(baseline_provenance)
      #(
        PathDepInference(
          effects: dict.merge(acc.effects, inferred_effs),
          params: dict.merge(acc.params, inferred_params),
          returns: dict.merge(acc.returns, inferred_returns),
          provenance: dict.merge(acc.provenance, inferred_provenance),
          baseline_provenance: dict.merge(
            acc.baseline_provenance,
            baseline_provenance,
          ),
        ),
        new_kb,
      )
    }
  }
}

// The spec's layers of a knowledge base
//
// Three folds compose them: `check`'s, `infer`'s, and the `effect` query's
// spec-only fast path, each interleaving its own layers between them. What
// these hold is the derivation of a layer's arguments and the origin it is
// tagged with — the halves that could disagree between folds. Which layers a
// fold applies is the fold's own: the fast path is held to the full context's
// answer by a test comparing the two, not by this grouping.

// The spec's `assume` declarations, minus the stale ones.
fn with_spec_assumes(
  knowledge_base: KnowledgeBase,
  spec: GradedFile,
  stale_assumes: Set(String),
) -> KnowledgeBase {
  effects.with_assumes(
    knowledge_base,
    declaring_assumes(spec, stale_assumes),
    types.UserAssume,
  )
}

// The spec's `where returns` declarations, minus the stale ones. A stale line
// is ignored at load as well as warned about and rewritten: trusted between
// `infer` runs it would be a per-function override of what the walk can see for
// itself.
fn with_spec_declared_returns(
  knowledge_base: KnowledgeBase,
  spec: GradedFile,
  stale_returns_clauses: Set(String),
) -> KnowledgeBase {
  effects.with_declared_returned_operators(
    knowledge_base,
    effects.load_spec_assume_returns_from_file(spec)
      |> drop_stale_names(stale_returns_clauses),
    types.UserAssume,
  )
}

// The spec's field `assume` lines, which resolve a field call on any receiver of the
// named type.
fn with_spec_type_fields(
  knowledge_base: KnowledgeBase,
  spec: GradedFile,
) -> KnowledgeBase {
  effects.with_type_fields(
    knowledge_base,
    annotation.extract_type_fields(spec),
    types.CommittedSpec,
  )
}

// Fold a spec file's committed `effects` lines and their parameter bounds into
// a knowledge base. The two travel together: a committed higher-order line's
// bounds are loaded with its effect term, so the pair the checker substitutes
// with always comes from one annotation source — otherwise the committed term
// would pair with freshly inferred bounds, whose variable names need not match
// it.
//
// Lines for a module-level-external module are dropped from both, so they can't
// reshadow the declaration (which lives in `module_effects`, consulted only when
// `all_effects` misses). `graded infer` no longer writes such lines; this guards
// a stale or hand-written one.
//
// A *stale* per-function external is still a declaring line of this spec, so
// the effects reader has already dropped the committed `effects` line for its
// name. Its own bounds are dropped here: `with_spec_assumes` has dropped the
// external, and those bounds would answer to a term no line supplies. With
// neither line answering, the body is walked, as the stale warning says.
//
// Shared by the full project context and the `effect` query's spec-only fast
// path, which must fold the spec exactly as the full context does for its answer
// to be the one the full context would have given.
fn with_committed_spec(
  knowledge_base: KnowledgeBase,
  spec: GradedFile,
  stale_assumes: Set(String),
) -> KnowledgeBase {
  // Read off the spec being folded, not taken from the caller: the modules to
  // drop are a property of that spec, and a caller passing any other set folds
  // in the very lines this function exists to drop.
  let declared_modules = annotation.module_assume_modules(spec)
  knowledge_base
  |> effects.with_inferred(
    effects.load_spec_effects_from_file(spec)
      |> effects.drop_module_declared(declared_modules),
    types.CommittedSpec,
  )
  |> effects.with_inferred_params(
    effects.load_spec_params_from_file(spec)
    |> effects.drop_module_declared(declared_modules)
    |> drop_stale_names(stale_assumes),
  )
}

// Drop every entry whose dotted name a stale per-function external also names.
fn drop_stale_names(
  entries: Dict(QualifiedName, a),
  stale_assumes: Set(String),
) -> Dict(QualifiedName, a) {
  use <- bool.guard(set.is_empty(stale_assumes), entries)
  dict.filter(entries, fn(name, _value) {
    !set.contains(stale_assumes, types.dotted_name(name))
  })
}

// CLI plumbing
//
// Argument handling, human-readable printing of errors, violations, and
// warnings, and the exit/stdin externals behind `main`.

fn run_check(directory: String) -> Nil {
  case run(directory) {
    Ok(reports) -> {
      let violations = list.flat_map(reports, fn(report) { report.violations })
      let warnings = list.flat_map(reports, fn(report) { report.warnings })
      list.each(warnings, io.println)
      case warnings {
        [] -> Nil
        _ ->
          io.println(
            "graded: " <> int.to_string(list.length(warnings)) <> " warning(s)",
          )
      }
      case violations {
        [] -> io.println("graded: all checks passed")
        _ -> {
          list.each(violations, io.println)
          io.println(
            "\ngraded: "
            <> int.to_string(list.length(violations))
            <> " violation(s) found",
          )
          halt(1)
        }
      }
    }
    Error(error) -> fail(error)
  }
}

// The public parse error for a spec file: the description graded prints for
// the cause, so the variant carries no internal type. One renderer, so the
// wording a caller reads and the wording the CLI prints cannot fork.
fn graded_parse_error(
  path: String,
  cause: annotation.ParseError,
) -> GradedError {
  GradedParseError(path:, message: annotation.describe_parse_error(cause))
}

fn format_error(error: GradedError) -> String {
  case error {
    DirectoryReadError(path, _) -> "Could not read directory: " <> path
    FileReadError(path, _) -> "Could not read: " <> path
    FileWriteError(path, _) -> "Could not write: " <> path
    DirectoryCreateError(path, _) -> "Could not create directory: " <> path
    GleamParseError(path, _) -> "Could not parse: " <> path
    GradedParseError(path, message) ->
      "Parse error in " <> path <> ":" <> message
    InvalidConfig(path, message) ->
      "Invalid gleam.toml: " <> path <> ": " <> message
    FormatCheckFailed(paths:) ->
      "Unformatted .graded files:\n"
      <> string.join(list.map(paths, fn(path) { "  " <> path }), "\n")
    StaleSpec(path:, diff:) ->
      "Stale spec file "
      <> path
      <> "; run `graded infer` to update it:\n"
      <> diff
    CyclicImports(modules:) ->
      "Cyclic project imports detected (this should be unreachable — Gleam disallows circular imports):\n"
      <> string.join(list.map(modules, fn(m) { "  " <> m }), "\n")
    EffectNotFound(name:) ->
      "no public function or type field named `" <> name <> "`"
    FunctionNotFound(name:) ->
      "no function named `"
      <> name
      <> "` (`why` explains functions defined in this project's modules, named as `module/path.function`)"
    PackError(message:) -> message
    CatalogError(problem:) -> format_catalog_problem(problem)
  }
}

// The message a `CatalogError` prints. Exposed so the wording of each problem —
// the recovery command `NotInstalled` names in particular — is covered without
// going through the branch that prints and halts.
@internal
pub fn format_catalog_problem(problem: CatalogProblem) -> String {
  case problem {
    NoCatalogEntry(package:) -> "no catalog entry for `" <> package <> "`"
    NoBundledVersion(package:, requested:, bundled:) ->
      "no bundled `"
      <> package
      <> "@"
      <> requested
      <> "`; bundled: "
      <> string.join(bundled, ", ")
    NotInstalled(package:, bundled:) ->
      "`"
      <> package
      <> "` is not in manifest.toml; bundled: "
      <> string.join(bundled, ", ")
      <> " — run `graded catalog "
      <> result.unwrap(list.last(bundled), package)
      <> "` to print one"
    NoManifest(path:) ->
      "no readable manifest.toml at "
      <> path
      <> "; run `gleam deps download` in that package, or name the version to "
      <> "print: `graded catalog <package>@<version>`"
    EmptyCatalog(directory:) -> "no catalog files under " <> directory
    NoCatalogDirectory(candidates:) ->
      "no bundled catalog directory; looked in "
      <> string.join(candidates, ", ")
  }
}

@external(erlang, "erlang", "halt")
@external(javascript, "./graded_ffi.mjs", "halt")
fn halt(code: Int) -> Nil

// How many words of off-heap binaries, the source text a run reads among
// them, the process running a command may reference before that alone sets off
// a full sweep of its heap.
const binary_heap_allowance = 1_000_000

// Set the running process's minimum binary virtual heap size
// (`min_bin_vheap_size`) to `words`. Nothing on JavaScript.
@external(erlang, "graded_ffi", "set_binary_heap_allowance")
fn set_binary_heap_allowance(_words: Int) -> Nil {
  Nil
}

// Read all of standard input to EOF as a single string, or the reason it could
// not be read. A read error is reported rather than folded into end-of-input:
// `format --stdin` writes its result back over what the user is editing, and a
// truncated read wrote a shortened file with a successful exit.
// nolint: stringly_typed_error -- opaque platform read diagnostic, printed by the CLI
@external(erlang, "graded_ffi", "read_stdin")
@external(javascript, "./graded_ffi.mjs", "read_stdin")
fn read_stdin() -> Result(String, String)

// The versions of what is running: graded itself, the analyzer it loaded, the
// release under it, and the compiler on the path. Read here rather than in
// `compat`, which holds no FFI; the coverage report is the only reader.
//
// The compiler read is a subprocess, so this is called by `graded coverage`
// alone — `check`, `infer`, `effect` and `why` never reach it.
@internal
pub fn observed_versions() -> compat.Observed {
  compat.Observed(
    graded: version(),
    girard: loaded_version("girard"),
    glance: loaded_version("glance"),
    otp: otp_release(),
    gleam: compiler_version(),
  )
}

// graded's own version, from the loaded OTP application's `vsn` (sourced from
// `gleam.toml` at build time). `"unknown"` where no application metadata is
// resolved, which is every read on JavaScript.
fn version() -> String {
  loaded_version("graded") |> result.unwrap("unknown")
}

// Any loaded application's version, read the same way. The applications graded
// loaded are the analyzer in use whatever directory it points at, which is what
// the coverage report states.
@external(erlang, "graded_ffi", "loaded_version")
@external(javascript, "./graded_ffi.mjs", "loaded_version")
fn loaded_version(application: String) -> Result(String, Nil)

// The Erlang/OTP release graded runs on. Not applicable on JavaScript.
@external(erlang, "graded_ffi", "otp_release")
@external(javascript, "./graded_ffi.mjs", "otp_release")
fn otp_release() -> Result(String, Nil)

// The version `gleam --version` reports, or `Error(Nil)` where the binary is
// absent or answers anything but `gleam <version>`.
fn compiler_version() -> Result(String, Nil) {
  compiler_output() |> result.try(parse_compiler_version)
}

// The version out of `gleam --version`'s output. The FFI runs the subprocess
// and this reads what it wrote, so one reading of the format serves both
// targets and one test covers both.
@internal
pub fn parse_compiler_version(output: String) -> Result(String, Nil) {
  case string.split(string.trim(output), " ") {
    ["gleam", version, ..] -> Ok(version)
    _ -> Error(Nil)
  }
}

// What `gleam --version` wrote. The only subprocess graded runs, and only
// `graded coverage` runs it: `check`, `infer`, `effect` and `why` stay
// subprocess-free.
@external(erlang, "graded_ffi", "compiler_output")
@external(javascript, "./graded_ffi.mjs", "compiler_output")
fn compiler_output() -> Result(String, Nil)
