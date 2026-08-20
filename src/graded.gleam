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
//// Use `run` to check a directory and get back a list of `CheckResult` values,
//// each containing any violations found per file. Use `run_infer` to infer
//// effects and write `.graded` files, or `run_infer_dry_run` to get back a
//// diff of what that write would change without performing it. Use
//// `run_effect` to resolve one function or type-field name and get its
//// `.graded` line back, `run_why` to get the effects of one function explained
//// call by call, or `run_catalog` to read graded's own bundled catalog — none
//// of them touching anything on disk.
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
import graded/internal/config
import graded/internal/diff
import graded/internal/effect_term
import graded/internal/effects.{type KnowledgeBase}
import graded/internal/extract
import graded/internal/signatures.{type SignatureRegistry}
import graded/internal/topo
import graded/internal/typeinfo
import graded/internal/types.{
  type CheckResult, type EffectAnnotation, type GradedFile, type QualifiedName,
  type TypeFieldAnnotation, type Violation, type Warning, AnnotationLine,
  CheckResult, DotlessExternalReturnsWarning, EffectAnnotation, GradedFile,
  PolymorphicExternalReturnsWarning, QualifiedName, StaleExternalReturnsWarning,
  StaleFunctionExternalWarning, TypeShapedExternalReturnsWarning,
  UnmatchedCheckWarning, UnmatchedExternalReturnsWarning,
  UnmatchedFunctionExternalWarning, UnmatchedModuleExternalWarning,
  UnmatchedTypeFieldWarning,
}
import simplifile

// Errors and CLI dispatch
//
// The error type every command returns, and the argv dispatcher that routes
// to the per-command runners below.

/// Errors that can occur during checking, inference, or formatting.
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
  /// A `.graded` annotation file could not be parsed.
  GradedParseError(path: String, cause: annotation.ParseError)
  /// `gleam.toml` was present but malformed, or missing its `name`. A missing
  /// `gleam.toml` is tolerated and does not produce this error.
  InvalidConfig(path: String, cause: config.ConfigError)
  /// One or more `.graded` files are not formatted (returned by `run_format_check`).
  FormatCheckFailed(paths: List(String))
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
  /// `graded catalog` could not answer: see `CatalogProblem`.
  CatalogError(problem: CatalogProblem)
}

/// Why `graded catalog` could not answer.
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
  case argv.load().arguments {
    [] -> run_check("src")

    ["--help", ..] | ["-h", ..] | ["help", ..] -> io.println(usage_text())

    ["--version", ..] -> io.println("graded " <> version())

    ["format", "--stdin"] ->
      case run_format_stdin(read_stdin()) {
        Ok(output) -> io.print(output)
        Error(error) -> {
          io.println_error(
            "graded: error: parse error in stdin:"
            <> annotation.describe_parse_error(error),
          )
          halt(1)
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
        run_effect_formatted(directory, name, format)
      })

    ["why", ..rest] ->
      report(cli.parse_why_args(rest), fn(arguments) {
        let #(name, directory) = arguments
        run_why(directory, name)
      })

    ["catalog", ..rest] -> report(cli.parse_catalog_args(rest), run_catalog)

    [first] -> dispatch_unknown(first)

    [first, extra, ..] ->
      case string.starts_with(first, "-") {
        True -> usage_error("unknown option `" <> first <> "`")
        False -> usage_error("unexpected argument `" <> extra <> "`")
      }
  }
}

fn pack_and_report(directory: String) -> Nil {
  case pack_project(resolve_package_root(directory), None) {
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
  graded effect <name> [dir]    Look up a function or type-field effect (read-only)
    --format=prose              Describe the answer in sentences (default)
    --format=graded             Print it as a `.graded` line, provenance in a comment
  graded why <name> [dir]       Explain where a function's effects come from (read-only)
  graded catalog                List the bundled catalog files (read-only)
  graded catalog <pkg> [dir]    Print the catalog file selected for the installed <pkg>
  graded catalog <pkg>@<ver>    Print that bundled version ([dir] accepted); bundled catalog only
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
/// `tarball` overrides the default `build/<name>-<version>.tar`. Returns a
/// success message (with the publish command) or a `PackError`.
pub fn pack_project(
  project_root: String,
  tarball: option.Option(String),
) -> Result(String, GradedError) {
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
  let resolved_spec = resolve_path(project_root, raw_cfg.spec_file)

  // A spec_file that is absolute or escapes the package root can't be a safe
  // archive-relative entry.
  use _ <- result.try(validate_archive_entry(entry_name))

  use spec <- result.try(
    simplifile.read(resolved_spec)
    |> result.map_error(fn(_) {
      PackError(
        "no spec file at " <> resolved_spec <> "; run `graded infer` first",
      )
    }),
  )

  use tarball_path <- result.try(resolve_pack_tarball(
    tarball,
    project_root,
    gleam_toml,
    raw_cfg,
  ))

  // Inject into a temp, verify, then replace the tarball in place, so a failed
  // transform never leaves a corrupt archive behind. The temp is reserved with
  // an atomic exclusive create — any existing path (a symlink included) is an
  // error — so the cleanup below can only ever delete what this run created.
  let temp = tarball_path <> ".packing"
  use _ <- result.try(
    reserve_path(temp)
    |> result.map_error(fn(reason) {
      PackError(
        "could not reserve scratch path "
        <> temp
        <> " ("
        <> reason
        <> "); remove any leftover file and retry",
      )
    }),
  )
  use checksum <- result.try(
    inject_spec(tarball_path, spec, entry_name, temp)
    |> result.map_error(fn(message) {
      let _deleted = simplifile.delete(temp)
      PackError("could not patch " <> tarball_path <> ": " <> message)
    }),
  )
  use _ <- result.try(
    verify_tarball(temp, entry_name)
    |> result.map_error(fn(message) {
      let _deleted = simplifile.delete(temp)
      PackError("patched tarball failed verification: " <> message)
    }),
  )
  use _ <- result.try(
    simplifile.rename(temp, tarball_path)
    |> result.map_error(FileWriteError(tarball_path, _)),
  )

  Ok(pack_success_message(tarball_path, entry_name, checksum))
}

// Resolve the tarball to patch. An explicit path is validated as a readable hex
// tarball. Without one, the default `build/<name>-<version>.tar` is opened and
// its identity checked against the project's name and version, so `pack` can't
// silently patch the wrong archive.
fn resolve_pack_tarball(
  tarball: option.Option(String),
  project_root: String,
  gleam_toml: String,
  cfg: config.GradedConfig,
) -> Result(String, GradedError) {
  let package_name = cfg.package_name
  case tarball {
    Some(path) -> {
      use _ <- result.try(
        read_package_identity(path)
        |> result.map_error(fn(message) {
          PackError("not a readable hex tarball: " <> path <> ": " <> message)
        }),
      )
      Ok(path)
    }
    None -> {
      use version <- result.try(option.to_result(
        cfg.version,
        PackError(
          "no `version` in "
          <> gleam_toml
          <> "; pass the tarball path explicitly",
        ),
      ))
      let path =
        filepath.join(
          project_root,
          "build/" <> package_name <> "-" <> version <> ".tar",
        )
      use #(name, tar_version) <- result.try(
        read_package_identity(path)
        |> result.map_error(fn(message) {
          PackError(
            "could not read "
            <> path
            <> " (run `gleam export hex-tarball` first): "
            <> message,
          )
        }),
      )
      case name == package_name && tar_version == version {
        True -> Ok(path)
        False ->
          Error(PackError(
            "tarball at "
            <> path
            <> " is "
            <> name
            <> "@"
            <> tar_version
            <> ", not the project's "
            <> package_name
            <> "@"
            <> version,
          ))
      }
    }
  }
}

// Reject an absolute path or one that escapes the package root: the spec must
// land at a safe archive-relative location inside the package.
fn validate_archive_entry(entry: String) -> Result(Nil, GradedError) {
  let escapes = list.contains(filepath.split(entry), "..")
  case string.starts_with(entry, "/") || escapes {
    True ->
      Error(PackError(
        "configured spec_file `"
        <> entry
        <> "` must be a relative path inside the package",
      ))
    False -> Ok(Nil)
  }
}

fn pack_success_message(
  tarball: String,
  entry: String,
  checksum: String,
) -> String {
  "graded: injected "
  <> entry
  <> " into "
  <> tarball
  <> "\n  checksum "
  <> checksum
  <> "\n\nPublish this tarball with the Hex publish API — NOT `gleam publish`,\n"
  <> "which rebuilds the tarball and drops the injected spec:\n\n"
  <> "  curl -X POST https://hex.pm/api/publish \\\n"
  <> "    -H \"authorization: $HEX_API_KEY\" \\\n"
  <> "    -H \"content-type: application/octet-stream\" \\\n"
  <> "    --data-binary @"
  <> shell_quote(tarball)
  <> "\n\nDocumentation still publishes via `gleam docs publish`."
}

// Quote a path for a POSIX shell: single-quoted, with embedded single quotes
// escaped as `'\''`, so the printed publish command survives paths with
// whitespace or shell metacharacters.
fn shell_quote(path: String) -> String {
  "'" <> string.replace(path, "'", "'\\''") <> "'"
}

// Checking
//
// The `check` command: assemble the knowledge base for the project, run the
// checker over each source file, and collect violations and warnings.

/// Run the checker on all .gleam files in a directory.
///
/// Reads the project's single spec file (default `<package_name>.graded`)
/// to find inferred public-API effects, `check` invariants, `external`
/// hints, and `type` field annotations, then reports violations per source
/// file.
pub fn run(directory: String) -> Result(List(CheckResult), GradedError) {
  use ctx <- result.try(load_project_context(directory))
  let ProjectContext(
    sources:,
    registry:,
    type_info:,
    stale_externals:,
    stale_external_returns:,
    knowledge_base:,
    catalog:,
    dependencies:,
  ) = ctx
  let ProjectSources(
    source_directory: directory,
    reported_directory:,
    cfg:,
    spec:,
    parsed:,
    index:,
    package_root:,
  ) = sources
  let checks_by_module = checks_grouped_by_module(spec)

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

  let results =
    list.map(reported, fn(entry) {
      let #(gleam_path, module) = entry
      let module_path = config.module_path_for_source(gleam_path, directory)
      let module_checks = case dict.get(checks_by_module, module_path) {
        Ok(list) -> list
        Error(_) -> []
      }
      check_one_file(
        gleam_path,
        module_path,
        module,
        module_checks,
        knowledge_base,
        registry,
        typeinfo.for_module(type_info, module_path),
        typeinfo.fn_typed_for_module(type_info, module_path),
        cfg.targets,
      )
    })

  // Spec-level lint: `check`/`type` lines whose target doesn't exist in any
  // project module. These silently do nothing (a vacuous check, or a field
  // annotation that resolves to [Unknown]), so they're reported against the
  // spec file itself rather than any source file.
  let results = case
    validate_spec_annotations(
      spec,
      index,
      package_root,
      stale_externals,
      stale_external_returns,
      catalog,
      dependencies,
    )
  {
    [] -> results
    spec_warnings -> [
      CheckResult(file: cfg.spec_file, violations: [], warnings: spec_warnings),
      ..results
    ]
  }

  Ok(results)
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
    // The per-function `external effects` lines that declare nothing, because
    // they name one of this package's own Gleam-bodied functions. Decided once
    // here: the knowledge base is assembled without them, and the spec lint
    // reports them, so the two can't disagree about which lines are live.
    stale_externals: Set(String),
    // The same about the `external returns` lines, on the value channel. Two
    // sets rather than one: each suppresses only its own channel's lines, and
    // each is reported by its own warning.
    stale_external_returns: Set(String),
    knowledge_base: KnowledgeBase,
    // The bundled catalog this context was assembled against. Held rather than
    // re-read by the spec lint, which weighs the same entries the knowledge
    // base was built from — and which, reading it a second time, reported a
    // missing catalog twice.
    catalog: effects.BundledCatalog,
    // The dependency scan this context was assembled from. Held for the spec
    // lint, which decides whether a dependency module defines the name an
    // `external effects` line gives it — a question this walk already parsed
    // every dependency module to answer for the registry.
    dependencies: DependencySources,
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
  use spec <- result.try(read_spec(cfg.spec_file))
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
  )
}

// Assemble a project's knowledge base without writing anything: read the config
// and spec, parse every source file, scan dependency sources, run girard, and
// fold the spec, dependencies, catalog, and an in-memory inference pass into one
// knowledge base.
fn load_project_context(
  directory: String,
) -> Result(ProjectContext, GradedError) {
  use sources <- result.map(load_project_sources(directory))
  project_context(sources)
}

// The expensive half: everything a context holds beyond the parsed sources.
fn project_context(sources: ProjectSources) -> ProjectContext {
  let ProjectSources(cfg:, spec:, index:, package_root:, ..) = sources
  let declared_modules = annotation.module_external_modules(spec)
  // The package's targets under both readings, which together decide whether a
  // function is foreign code or the Gleam body is its only implementation, and
  // whether a fallback body beside a declaration runs. One value for the whole
  // run, this package and its dependencies alike: a dependency is compiled for
  // the consumer's target, not its own.
  let package_targets = cfg.targets
  let native_of = native_functions_of(index, package_targets)
  let stale_externals = stale_project_externals(spec, native_of)
  let stale_external_returns = stale_project_external_returns(spec, native_of)
  let dep_sources = dependency_sources(package_root, package_targets)
  let registry =
    signatures.merge(
      dependency_registry(dep_sources),
      build_project_registry(index),
    )
  let type_info = build_type_index(index, package_root)

  // Read once and kept: the knowledge base is built from it and the spec lint
  // weighs the same entries.
  let catalog = effects.load_project_catalog(manifest_path(package_root))

  let kb_base =
    effects.knowledge_base_from_catalog(
      packages_dir(package_root),
      catalog,
      dependency_foreign(dep_sources),
    )
    // Before anything is looked up: every foreign lookup is read on the targets
    // this build compiles, and every command reads them the same way.
    |> effects.with_package_targets(cfg.targets)
    // Consumer externals are applied before path-dep inference so a module-level
    // external governs a path dependency's module during that dep's own
    // inference, not only at the final lookup.
    |> with_spec_externals(spec, stale_externals)
    // Applied before path-dep inference for the same reason the externals above
    // are, one channel over: a spec-less path dependency's bodies are summarized
    // during that pass, and a consumer line declaring what one of its producers
    // hands back has to be in reach while they are, not only afterwards.
    |> with_spec_declared_returns(spec, stale_external_returns)
    |> with_builders(index, dep_sources, package_targets)
    |> enrich_with_path_deps(package_root, declared_modules, package_targets)
    |> with_committed_spec(spec, stale_externals)
    // Recorded before the inference pass below, so an `@external` resolves to
    // what declares it while this project's own modules are being inferred, not
    // only when they are later checked.
    |> effects.with_foreign_functions(project_foreign_functions(
      index,
      package_targets,
    ))
    // What this package defines, for the query that answers from its public API.
    |> effects.with_project_functions(project_function_visibility(index))
    // Committed project returns are Foreign (Fix E): serialized, unsanitized. The
    // fresh in-memory pass below re-infers project returns and, being Fresh, wins
    // over these for the same key.
    //
    // The `external returns` declarations folded above outrank both, by two
    // different mechanisms, and the difference matters to anyone editing either.
    // Against this committed load the **ordering is load-bearing**: the merge
    // gap-fills, so a spec written before the function became `@external`, still
    // carrying its inferred `returns` line until the next `infer`, loses only
    // because the declaration is already there. Against the fresh pass below the
    // ordering decides nothing — that merge lets the incoming summary win — and
    // the declaration survives on `merge_returns`'s explicit
    // declared-beats-inferred rule instead. That rule reads as redundant from
    // here, since fresh inference keys no foreign name; it is what holds if any
    // link of that three-file invariant chain ever gives.
    |> effects.with_foreign_returned_operators(
      effects.load_spec_returns_from_file(spec),
      types.CommittedSpec,
    )
    // Before the inference pass, not after it, and in the order `infer` folds
    // them: a body walked during inference resolves its field calls through the
    // same `type` lines and factory signatures a body walked at check time
    // does. Installed afterwards, the pass ran without them and a function
    // whose effects it settled — an `@external`'s running fallback, whose
    // callers read the summary and never the body — kept an answer the two
    // commands would then disagree about.
    |> with_spec_type_fields(spec)
    |> effects.with_factories(
      qualify_by_module(index, extract.factory_map(
        _,
        types.declaration_targets(package_targets),
      )),
    )
  // Fill gaps for project modules not (yet) in the spec by inferring them in
  // memory, so `check` resolves cross-module calls without a prior `graded infer`.
  // Committed effects are never overridden; fresh returns win over committed
  // Foreign ones (Fix E). The deltas aren't needed here — the pre-pass already
  // folded them into `kb_base`. Nothing is written to disk.
  let knowledge_base =
    infer_project_in_memory(
      kb_base,
      index,
      registry,
      type_info,
      declared_modules,
      package_targets,
    )

  ProjectContext(
    sources:,
    registry:,
    type_info:,
    stale_externals:,
    stale_external_returns:,
    knowledge_base:,
    catalog:,
    dependencies: dep_sources,
  )
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

// The per-function `external effects <module>.<function>` lines that declare
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
fn stale_project_externals(
  spec: GradedFile,
  native_of: fn(String) -> Result(Set(String), Nil),
) -> Set(String) {
  declaring_nothing(annotation.external_function_names(spec), native_of)
}

// The `external returns` lines that declare nothing: the same rule one channel
// over, over the same predicate, so the two cannot drift apart.
//
// Derived apart from `stale_project_externals` and threaded apart from it. That
// set drives the effects channel's two suppressions — committed `effects` lines
// with their bounds, and the inferred lines `infer` writes — and a returns name
// reaching either would delete a function's effect lines because its *value* was
// declared.
fn stale_project_external_returns(
  spec: GradedFile,
  native_of: fn(String) -> Result(Set(String), Nil),
) -> Set(String) {
  declaring_nothing(annotation.external_returns_names(spec), native_of)
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

// A module's Gleam-bodied function names as the project index holds them, in
// the shape `stale_project_externals` asks for.
fn native_functions_of(
  index: Dict(String, #(String, glance.Module)),
  package_targets: types.PackageTargets,
) -> fn(String) -> Result(Set(String), Nil) {
  fn(module_path) {
    dict.get(index, module_path)
    |> result.map(fn(entry) {
      checker.native_function_names(entry.1, package_targets)
    })
  }
}

// The spec's external declarations minus the ones that declare nothing.
fn declaring_externals(
  spec: GradedFile,
  stale: Set(String),
) -> List(types.ExternalAnnotation) {
  annotation.extract_externals(spec)
  |> list.filter(fn(external) {
    case external.target {
      types.FunctionExternal(function) ->
        !set.contains(
          stale,
          types.dotted_name(QualifiedName(external.module, function)),
        )
      types.ModuleExternal -> True
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
// module qualifier from the grouped annotations.
fn checks_grouped_by_module(
  spec: GradedFile,
) -> Dict(String, List(EffectAnnotation)) {
  list.fold(annotation.extract_checks(spec), dict.new(), fn(acc, ann) {
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
  module_types: Dict(#(Int, Int), girard.Type),
  girard_fn_typed: Dict(String, Set(String)),
  package_targets: types.PackageTargets,
) -> CheckResult {
  let #(violations, warnings) =
    checker.check(
      module,
      module_path,
      module_checks,
      knowledge_base,
      registry,
      module_types,
      girard_fn_typed,
      package_targets,
    )
  CheckResult(file: gleam_path, violations:, warnings:)
}

// Spec lint

// Flag `check`/`type`/`external` spec lines whose target resolves nothing. A
// `check` line names a function that must exist in some project module; a `type`
// line names a `module.Type.field` that must be a callable (function-typed)
// field; an `external effects` line names foreign code, so it must name
// something graded cannot see the body of, and something that exists at all.
// When the qualifier is missing or wrong, the field plainly can't be called, or
// the declaration covers a body sitting in plain sight, the line is silently
// dead or silently ignored, so surface it as a warning.
fn validate_spec_annotations(
  spec: GradedFile,
  index: Dict(String, #(String, glance.Module)),
  package_root: String,
  stale_externals: Set(String),
  stale_external_returns: Set(String),
  catalog: effects.BundledCatalog,
  dependencies: DependencySources,
) -> List(Warning) {
  let known_functions = known_function_names(index)

  let check_warnings =
    annotation.extract_checks(spec)
    |> list.filter(fn(ann) { !set.contains(known_functions, ann.function) })
    |> list.map(fn(ann) { UnmatchedCheckWarning(function: ann.function) })

  let externals = annotation.extract_externals(spec)
  let declared_returns = annotation.extract_external_returns(spec)
  let type_fields = annotation.extract_type_fields(spec)
  // Every lint here tells a dependency module from a typo, and the scan behind
  // that is the expensive part: walked once here and shared, and not at all for
  // a spec holding none of these line kinds.
  let dep_files = case externals, declared_returns, type_fields {
    [], [], [] -> dict.new()
    _, _, _ -> dependency_module_files(package_root)
  }
  let dep_modules = set.from_list(dict.keys(dep_files))

  // The two declaring forms weigh a name by one rule, over one precomputation —
  // which reads the whole dependency tree, so it is built only where a
  // declaring line asks a question of it.
  let #(external_warnings, external_returns_warnings) = case
    externals,
    declared_returns
  {
    [], [] -> #([], [])
    _, _ -> {
      let evidence =
        spec_name_evidence(
          index,
          known_functions,
          package_root,
          dep_files,
          catalog,
          dependencies,
        )
      #(
        external_warnings(externals, evidence, stale_externals),
        external_returns_warnings(
          declared_returns,
          evidence,
          stale_external_returns,
        ),
      )
    }
  }

  // Resolving `type` lines also needs per-module type info; build it only when
  // there are `type` lines to check.
  let type_field_warnings = case type_fields {
    [] -> []
    type_fields -> {
      let project_infos = project_module_infos(index)
      let module_info = fn(module_path) {
        lookup_module_info(module_path, project_infos, dep_files)
      }
      list.filter_map(type_fields, unmatched_type_field_warning(
        _,
        index,
        dep_modules,
        module_info,
      ))
    }
  }

  list.flatten([
    check_warnings,
    external_warnings,
    external_returns_warnings,
    type_field_warnings,
  ])
}

// What both declaring forms' lints weigh a name against, precomputed once over
// the catalog and the dependency scan and then asked per name. One rule, so an
// `external effects` line and an `external returns` line naming the same
// function are called dead together or not at all.
type SpecNameEvidence {
  SpecNameEvidence(
    // Whether anything graded can read defines the name.
    defines: fn(QualifiedName) -> Bool,
    // Whether the name's module was placed at all — or the dependency tree is
    // too incomplete for its absence to prove anything.
    module_placed: fn(String) -> Bool,
  )
}

// A dependency is weighed by the function, not by the module: graded holds that
// dependency's source, so `external effects dep/io.typo` over a `dep/io` that
// defines only `writes` is as dead as one naming no module at all, and the
// module tier would wave every misspelling through. A module-level line has no
// function to weigh and is settled by the module alone.
//
// Existence only. A name that resolves but that graded cannot introspect is
// exactly what a declaring line is for, and is never flagged.
fn spec_name_evidence(
  index: Dict(String, #(String, glance.Module)),
  known_functions: Set(String),
  package_root: String,
  dep_files: Dict(String, String),
  catalog: effects.BundledCatalog,
  dependencies: DependencySources,
) -> SpecNameEvidence {
  // The catalog the knowledge base was assembled from, selected against *this*
  // project's manifest — so a line naming a catalogued function of a package
  // this project depends on resolves exactly as `check` resolves it.
  let effects.BundledCatalog(
    functions: catalog_functions,
    modules: catalog_modules,
    ..,
  ) = catalog
  // A catalogued module is one the catalog *keys*, whether by a module-level
  // line or by the per-function lines that are the usual form: the stdlib
  // catalog holds `gleam/io.println` and no `gleam/io` line, so weighing module
  // existence by `catalog_modules` alone calls a real module a typo wherever
  // the dependency's own sources aren't installed to say otherwise.
  let catalog_function_modules =
    dict.fold(catalog_functions, set.new(), fn(acc, name, _entry) {
      set.insert(acc, name.module)
    })
  // Whether the tree the lint read is the whole of what this project depends
  // on. A module it cannot place is a typo only if there was nowhere left for
  // it to be: with a manifest package whose sources never turned up, the module
  // may be that package's, and no reading of what is on disk disproves it.
  let unplaceable_is_unknown = !dependency_sources_are_complete(package_root)
  // Whether something *outside* this package's own parsed source speaks for the
  // module: a dependency source the lint could read, or a catalog entry.
  let claimed = fn(module) {
    dict.has_key(dep_files, module)
    || dict.has_key(catalog_modules, module)
    || set.contains(catalog_function_modules, module)
  }
  // And whether anything at all does. Nothing here is what "unplaceable" means.
  let placed = fn(module) { dict.has_key(index, module) || claimed(module) }
  let defines = fn(qualified: QualifiedName) {
    // What answers for the name where no parsed source settles it: a module
    // something outside this package speaks for, a catalog entry for the exact
    // name, or a module the lint cannot place at all while the tree is missing
    // a package that could be holding it. A project module is *not* among them
    // — it was parsed, and `known_functions` is what it defines.
    let unparsed_answers =
      claimed(qualified.module)
      || dict.has_key(catalog_functions, qualified)
      || { unplaceable_is_unknown && !placed(qualified.module) }
    // The catalog is a stand-in for sources graded cannot read, so it is
    // weighed only where the dependency's own source says nothing: a parsed
    // module defines what it defines, and a name it provably lacks is a typo
    // whatever the catalog keys for the module. The lint flags what it can
    // prove dead, and silence is not proof.
    set.contains(known_functions, types.dotted_name(qualified))
    || case dependency_name(dependencies, qualified) {
      DefinedByDependency -> True
      AbsentFromDependency -> False
      UnreadDependency -> unparsed_answers
    }
  }
  SpecNameEvidence(defines:, module_placed: fn(module) {
    placed(module) || unplaceable_is_unknown
  })
}

// One walk of the spec's `external effects` lines, yielding the three ways such
// a line can be dead. Both tiers are covered, since a typo is as likely in the
// module name as in the function name:
//
//   - a per-function line naming one of *this package's* Gleam-bodied functions:
//     valid syntax, nothing foreign to declare, so it is ignored and the body
//     walked (see `stale_project_externals`);
//   - a per-function line whose `module.function` resolves nowhere at all —
//     dependency, catalog, or project index;
//   - a module-level line whose module is neither a dependency nor a project
//     module.
fn external_warnings(
  externals: List(types.ExternalAnnotation),
  evidence: SpecNameEvidence,
  stale: Set(String),
) -> List(Warning) {
  list.filter_map(externals, fn(external) {
    case external.target {
      types.FunctionExternal(function) -> {
        let qualified = QualifiedName(external.module, function)
        let name = types.dotted_name(qualified)
        case set.contains(stale, name), evidence.defines(qualified) {
          True, _ -> Ok(StaleFunctionExternalWarning(function: name))
          False, False -> Ok(UnmatchedFunctionExternalWarning(function: name))
          False, True -> Error(Nil)
        }
      }
      types.ModuleExternal ->
        case evidence.module_placed(external.module) {
          True -> Error(Nil)
          False -> Ok(UnmatchedModuleExternalWarning(module: external.module))
        }
    }
  })
}

// The same walk over the spec's `external returns` lines, yielding the four ways
// one can be dead. Two are the existence branches above, read through the same
// evidence; two are this form's own, and both are lines the loader drops:
//
//   - a name the function grammar rejects: one with no `.`, where the
//     declaration is read as naming a whole module and nothing keys a module's
//     returned value, and one with more than one, which reaches for the `type`
//     line's field shape;
//   - a polymorphic operator, whose free variables nothing sanitized.
//
// One warning per line, so a line that is dead twice over is reported by the
// first rule that catches it.
fn external_returns_warnings(
  declared: List(types.ReturnsAnnotation),
  evidence: SpecNameEvidence,
  stale: Set(String),
) -> List(Warning) {
  list.filter_map(declared, fn(returns) {
    case annotation.split_function_name(returns.function) {
      Error(Nil) ->
        case string.contains(returns.function, ".") {
          True -> Ok(TypeShapedExternalReturnsWarning(name: returns.function))
          False -> Ok(DotlessExternalReturnsWarning(name: returns.function))
        }
      Ok(#(module, function)) ->
        case
          set.contains(stale, returns.function),
          evidence.defines(QualifiedName(module, function)),
          effect_term.is_ground(returns.operator)
        {
          True, _, _ ->
            Ok(StaleExternalReturnsWarning(function: returns.function))
          False, False, _ ->
            Ok(UnmatchedExternalReturnsWarning(function: returns.function))
          False, True, False ->
            Ok(PolymorphicExternalReturnsWarning(function: returns.function))
          False, True, True -> Error(Nil)
        }
    }
  })
}

// Whether every package the manifest lists yielded sources graded could read —
// installed under `build/packages`, or at a path dependency's own location.
//
// The lint proves a name dead by reading source. A tree missing one of the
// manifest's packages holds source it never read, so a module it cannot place
// might be that package's: only over a complete tree does "nowhere to be found"
// mean "not there". A project with no dependencies is trivially complete, and a
// fresh clone before `gleam deps download` is not.
fn dependency_sources_are_complete(package_root: String) -> Bool {
  let manifest = effects.manifest_package_names(manifest_path(package_root))
  use <- bool.guard(when: set.is_empty(manifest), return: True)
  let located =
    effects.parse_path_dependencies(filepath.join(package_root, "gleam.toml"))
    |> list.filter_map(fn(dep) {
      let #(name, dep_path) = dep
      let src_dir = filepath.join(resolve_path(package_root, dep_path), "src")
      case dict.is_empty(effects.source_dir_module_files(src_dir)) {
        True -> Error(Nil)
        False -> Ok(name)
      }
    })
    |> set.from_list
    |> set.union(effects.packages_with_sources(packages_dir(package_root)))
  set.difference(manifest, located) |> set.is_empty
}

// Map of module path -> source file for every installed dependency (under
// `build/packages`) and path dependency (under its declared `path`). Lets the
// spec lint tell a dependency type from a typo, and parse a dependency module
// when it needs to resolve a field's declared type.
fn dependency_module_files(package_root: String) -> Dict(String, String) {
  let installed = effects.dependency_module_files(packages_dir(package_root))
  effects.parse_path_dependencies(filepath.join(package_root, "gleam.toml"))
  |> list.fold(installed, fn(acc, dep) {
    let #(_name, dep_path) = dep
    let src_dir = filepath.join(resolve_path(package_root, dep_path), "src")
    dict.merge(acc, effects.source_dir_module_files(src_dir))
  })
}

// A warning for a `type` line that resolves nothing, or `Error(Nil)` when the
// line is a valid target. Cases:
//   - unqualified (`type Type.field`): no module to key a receiver's resolved
//     type, so it's always dead;
//   - qualified at a *project* module: dead when the type/field doesn't exist,
//     or the field's declared type plainly can't be called (a record, a scalar,
//     a tuple). A field whose type can't be resolved (an unintrospectable
//     dependency) is left alone rather than flagged;
//   - qualified at a *dependency* module: left alone — the receiver type is the
//     dependency's, which girard resolves; graded doesn't second-guess it;
//   - qualified at an unknown module (neither project nor dependency): a typo,
//     so it's dead and flagged.
fn unmatched_type_field_warning(
  tf: TypeFieldAnnotation,
  index: Dict(String, #(String, glance.Module)),
  dep_modules: Set(String),
  module_info: fn(String) -> Result(ModuleInfo, Nil),
) -> Result(Warning, Nil) {
  case tf.module {
    None -> Ok(UnmatchedTypeFieldWarning(name: tf.type_name <> "." <> tf.field))
    Some(module) ->
      case valid_type_field(module, tf, index, dep_modules, module_info) {
        True -> Error(Nil)
        False ->
          Ok(UnmatchedTypeFieldWarning(
            name: module <> "." <> tf.type_name <> "." <> tf.field,
          ))
      }
  }
}

// Whether a qualified `type` line is an accepted target. A project type's field
// must exist and not plainly be non-callable (`Callable`/`Unknown` pass, so an
// unintrospectable field type is never false-flagged). A dependency-owned type
// passes untouched; any other module is a typo.
fn valid_type_field(
  module: String,
  tf: TypeFieldAnnotation,
  index: Dict(String, #(String, glance.Module)),
  dep_modules: Set(String),
  module_info: fn(String) -> Result(ModuleInfo, Nil),
) -> Bool {
  case dict.get(index, module) {
    Ok(#(_gleam_path, mod)) ->
      case lookup_labelled_field(mod, tf.type_name, tf.field) {
        Ok(field_type) ->
          classify_field_type(field_type, module, module_info, set.new())
          != NotCallable
        Error(Nil) -> False
      }
    Error(Nil) -> set.contains(dep_modules, module)
  }
}

// Every `module.function` defined across the project (public and private), the
// set a `check` line's qualified name must belong to.
fn known_function_names(
  index: Dict(String, #(String, glance.Module)),
) -> Set(String) {
  dict.fold(index, set.new(), fn(acc, module_path, entry) {
    let #(_gleam_path, module) = entry
    list.fold(module.functions, acc, fn(acc2, definition) {
      set.insert(acc2, module_path <> "." <> definition.definition.name)
    })
  })
}

// The labelled field `field` of custom type `type_name` in `module`, or
// `Error` when no such type or labelled field exists.
fn lookup_labelled_field(
  module: glance.Module,
  type_name: String,
  field: String,
) -> Result(glance.Type, Nil) {
  use definition <- result.try(
    list.find(module.custom_types, fn(d) { d.definition.name == type_name }),
  )
  list.find_map(definition.definition.variants, fn(variant) {
    list.find_map(variant.fields, fn(f) {
      case f {
        glance.LabelledVariantField(label:, item:) if label == field -> Ok(item)
        _ -> Error(Nil)
      }
    })
  })
}

// The type-resolution surface graded can read for one module: its type aliases,
// its own custom-type names, and the two ways another module's type can be
// referenced — qualified (import alias -> module path) and unqualified
// (imported type's local name -> #(module path, original name)).
type ModuleInfo {
  ModuleInfo(
    aliases: Dict(String, glance.Type),
    custom_types: Set(String),
    qualified_imports: Dict(String, String),
    unqualified_types: Dict(String, #(String, String)),
  )
}

// Whether a field's declared type can be called. Three-valued so the lint flags
// only what it can prove is non-callable, never guessing on a type it can't
// resolve.
type Callable {
  Callable
  NotCallable
  UnknownCallable
}

fn project_module_infos(
  index: Dict(String, #(String, glance.Module)),
) -> Dict(String, ModuleInfo) {
  dict.map_values(index, fn(_module_path, entry) {
    let #(_gleam_path, module) = entry
    module_info_from_glance(module)
  })
}

fn module_info_from_glance(module: glance.Module) -> ModuleInfo {
  let aliases =
    list.fold(module.type_aliases, dict.new(), fn(acc, definition) {
      dict.insert(
        acc,
        definition.definition.name,
        definition.definition.aliased,
      )
    })
  let custom_types =
    list.fold(module.custom_types, set.new(), fn(acc, definition) {
      set.insert(acc, definition.definition.name)
    })
  let #(qualified_imports, unqualified_types) =
    list.fold(module.imports, #(dict.new(), dict.new()), fn(acc, definition) {
      let #(quals, unquals) = acc
      let import_ = definition.definition
      let alias = case import_.alias {
        Some(glance.Named(name)) -> name
        _ -> last_segment(import_.module)
      }
      let unquals =
        list.fold(import_.unqualified_types, unquals, fn(u, unqualified) {
          let local = case unqualified.alias {
            Some(a) -> a
            None -> unqualified.name
          }
          dict.insert(u, local, #(import_.module, unqualified.name))
        })
      #(dict.insert(quals, alias, import_.module), unquals)
    })
  ModuleInfo(aliases:, custom_types:, qualified_imports:, unqualified_types:)
}

fn last_segment(module_path: String) -> String {
  module_path |> string.split("/") |> list.last() |> result.unwrap(module_path)
}

// Resolve a module's introspectable type info: a project module from the index,
// or a dependency module parsed from its source on demand. `Error` when neither
// is available (an uninstalled or otherwise unreadable module).
fn lookup_module_info(
  module_path: String,
  project_infos: Dict(String, ModuleInfo),
  dep_files: Dict(String, String),
) -> Result(ModuleInfo, Nil) {
  case dict.get(project_infos, module_path) {
    Ok(info) -> Ok(info)
    Error(Nil) ->
      case dict.get(dep_files, module_path) {
        Ok(file) -> {
          use source <- result.try(
            simplifile.read(file) |> result.replace_error(Nil),
          )
          use module <- result.try(
            glance.module(source) |> result.replace_error(Nil),
          )
          Ok(module_info_from_glance(module))
        }
        Error(Nil) -> Error(Nil)
      }
  }
}

// Whether `type_`, declared in `module_path`, is a callable function type —
// following alias chains across project and dependency modules. `seen` guards
// against alias cycles. A type graded can't introspect resolves to `Unknown`,
// never `NotCallable`, so the lint won't false-flag it.
fn classify_field_type(
  type_: glance.Type,
  module_path: String,
  module_info: fn(String) -> Result(ModuleInfo, Nil),
  seen: Set(String),
) -> Callable {
  case type_ {
    glance.FunctionType(..) -> Callable
    glance.NamedType(name:, module: None, ..) ->
      classify_named_type(name, module_path, module_info, seen)
    glance.NamedType(name:, module: Some(qualifier), ..) ->
      case module_info(module_path) {
        Ok(info) ->
          case dict.get(info.qualified_imports, qualifier) {
            Ok(real_module) ->
              classify_named_type(name, real_module, module_info, seen)
            Error(Nil) -> UnknownCallable
          }
        Error(Nil) -> UnknownCallable
      }
    // A type variable could be instantiated to a function; don't flag it.
    glance.VariableType(..) -> UnknownCallable
    // Tuples and holes are never callable.
    _ -> NotCallable
  }
}

// Classify a bare type name (`module: None`) as seen from `module_path`: a local
// alias is followed, a local custom type is non-callable, an unqualified import
// is chased to its defining module, and anything else is a prelude/builtin type
// (none of which is callable).
fn classify_named_type(
  name: String,
  module_path: String,
  module_info: fn(String) -> Result(ModuleInfo, Nil),
  seen: Set(String),
) -> Callable {
  let key = module_path <> "." <> name
  case set.contains(seen, key), module_info(module_path) {
    True, _ -> UnknownCallable
    _, Error(Nil) -> UnknownCallable
    False, Ok(info) ->
      classify_in_module(
        name,
        module_path,
        info,
        module_info,
        set.insert(seen, key),
      )
  }
}

// `name` resolved within `info` (the module that defines or imports it): a local
// alias is followed, a local custom type is non-callable, and an unqualified
// import is chased to its source. Anything else is a prelude/builtin type.
fn classify_in_module(
  name: String,
  module_path: String,
  info: ModuleInfo,
  module_info: fn(String) -> Result(ModuleInfo, Nil),
  seen: Set(String),
) -> Callable {
  case dict.get(info.aliases, name) {
    Ok(aliased) -> classify_field_type(aliased, module_path, module_info, seen)
    Error(Nil) ->
      case
        set.contains(info.custom_types, name),
        dict.get(info.unqualified_types, name)
      {
        True, _ -> NotCallable
        False, Ok(#(real_module, original)) ->
          classify_named_type(original, real_module, module_info, seen)
        False, Error(Nil) -> NotCallable
      }
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
/// declared `type` lines. Any provenance is appended as a `//` comment line, so
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
  run_effect_formatted(directory, name, answer.Graded)
}

/// Look up one name's effect and render it in `format`: `answer.Graded` for
/// the `.graded` line above, `answer.Prose` for sentences describing the same
/// answer. Both render one structured answer, so they can differ in wording but
/// never in what they report.
pub fn run_effect_formatted(
  directory: String,
  name: String,
  format: answer.Format,
) -> Result(String, GradedError) {
  effect_answer(directory, name)
  |> result.map(answer.render(_, format))
}

// Resolve `name` to a structured answer, trying the spec-only fast path first.
fn effect_answer(
  directory: String,
  name: String,
) -> Result(EffectAnswer, GradedError) {
  let directory = source_scope(directory).analysed
  use cfg <- result.try(read_config(directory))
  use spec <- result.try(read_spec(cfg.spec_file))
  case spec_answer(directory, spec, cfg.targets, name) {
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
  answer_from(ctx.knowledge_base, name)
  |> result.replace_error(EffectNotFound(name))
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
// - A `type` line declaring a field under its own module: spec `type` fields
//   are merged last of all, so an exact key wins outright. A bare line's
//   module-less key is a fallback, not a decision, and stays with the full
//   context.
// - A per-function `external effects <module>.<function>`: `with_externals`
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
    Ok(#(module, _function)) -> {
      let project_modules = project_module_files(directory)
      use <- bool.guard(
        when: !set.contains(annotation.external_function_names(spec), name)
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
      let stale =
        stale_project_externals(spec, fn(queried) {
          case queried == module {
            True -> Ok(parsed.native)
            False -> Error(Nil)
          }
        })
      // An `@external` of this package's whose Gleam fallback body runs is
      // charged that body's effects on top of its declaration, and walking a
      // body is exactly what the fast path exists not to do. Deferred whole, so
      // the answer cannot be the declaration alone where the full context says
      // more.
      use <- bool.guard(
        when: runs_a_fallback_body(parsed, module, name),
        return: Error(Nil),
      )
      answer_from(
        with_module_facts(spec_knowledge_base(spec, stale, targets), parsed)
          |> effects.with_dependency_foreign(dependency_foreign_for(
            directory,
            project_modules,
            module,
            targets,
          )),
        name,
      )
    }
    // Not a function name — only a type field can answer. A spec `type` line is
    // merged last of all, so an entry under the queried name's *own* module is
    // final. The module-less key a bare line lands under is not: it is only the
    // fallback `type_field_effect` reaches for when nothing declares the exact
    // module, and a dependency's spec — which the fast path never reads — can
    // declare it. So the spec decides this name only if it declares it
    // qualified; a bare line is left to the full context, which weighs it
    // against every dependency's `type` lines.
    // An answer carrying the queried module is one the exact key produced; one
    // carrying none fell back to the bare key, so it isn't the spec's decision.
    Error(Nil) ->
      case
        type_field_effect(spec_knowledge_base(spec, set.new(), targets), name)
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
// Neither the spec's `returns` lines nor its `external returns` declarations are
// among them: a returned-operator summary is consumed while walking a body, and
// a fast-path answer is one no body was walked for. That holds for the declared
// ones as much as the inferred — the declaration answers a call of the value,
// which this path never reaches.
fn spec_knowledge_base(
  spec: GradedFile,
  stale_externals: Set(String),
  targets: types.PackageTargets,
) -> KnowledgeBase {
  effects.new_knowledge_base()
  |> effects.with_package_targets(targets)
  |> with_spec_externals(spec, stale_externals)
  |> with_committed_spec(spec, stale_externals)
  |> with_spec_type_fields(spec)
}

// Whether the queried name is one of this package's `@external`s that falls
// back to Gleam on some target it is compiled for. The parsed module already
// says so, so the test costs nothing beyond the file the fast path read anyway.
fn runs_a_fallback_body(
  parsed: ModuleFacts,
  module: String,
  name: String,
) -> Bool {
  case annotation.split_function_name(name) {
    Error(Nil) -> False
    Ok(#(_module, function)) ->
      case dict.get(parsed.foreign, QualifiedName(module:, function:)) {
        Ok(types.ForeignFunction(runs_fallback_body:, ..)) -> runs_fallback_body
        Error(Nil) -> False
      }
  }
}

// What a *dependency's* source says is `@external` in the queried module.
//
// Empty for one of this package's own modules: Gleam forbids a dependency from
// keying one, so nothing over there can change the answer. For a dependency
// module — which a per-function `external effects` line may name — the
// declaration alone understates an `@external` whose Gleam fallback body runs,
// because no consumer walks that body and the full context therefore charges
// the declaration unioned with `[Unknown]`. One module is located and parsed to
// settle it, so the fast path cannot answer where the full context would say
// more.
fn dependency_foreign_for(
  directory: String,
  project_modules: Dict(String, String),
  module: String,
  package_targets: types.PackageTargets,
) -> Dict(QualifiedName, types.ForeignFunction) {
  use <- bool.guard(
    when: dict.has_key(project_modules, module),
    return: dict.new(),
  )
  let files = dependency_module_files(resolve_package_root(directory))
  // A dependency graded cannot locate or parse is one the full context cannot
  // read either, so both answer from the declaration alone.
  use <- bool.guard(when: !dict.has_key(files, module), return: dict.new())
  case dict.get(files, module) |> result.try(read_and_parse_gleam_or_nil) {
    Ok(parsed) ->
      checker.dependency_foreign_functions(parsed, module, package_targets)
    Error(Nil) -> dict.new()
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
      )
    }
  }
}

// Fold one module's source facts into a knowledge base, in the same two calls
// the full context makes over the whole package.
fn with_module_facts(
  knowledge_base: KnowledgeBase,
  facts: ModuleFacts,
) -> KnowledgeBase {
  knowledge_base
  |> effects.with_foreign_functions(facts.foreign)
  |> effects.with_project_functions(facts.visibility)
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
  // The bounds a running fallback body states its effects over, for the answers
  // whose own term is ground: a fallback that calls a function-typed parameter
  // names that parameter, and without its bound the line names a variable
  // nothing introduces. Only a fallback's own recorded bounds travel with
  // those answers — a per-function bound from anywhere else was written over a
  // body the foreign implementation needn't match, exactly like the entry
  // beside it, so it is no more an answer here than that entry is.
  let fallback_bounds = effects.fallback_param_bounds(knowledge_base, qualified)
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
        source: case fallback {
          // The body running in the declaration's place is the whole of the
          // term, not a half added to it, so it is named as the source and not
          // beside one.
          Some(_) -> answer.RunningFallbackBody
          None -> answer.UnreachedDeclaration
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
      source: answer.UndeclaredExternal(fallback:),
    )),
  )
  case effects.lookup_declared(knowledge_base, qualified) {
    effects.Unknown -> Error(Nil)
    // Which map answered is reported by the lookup itself, so the recorded
    // source can't disagree with the term beside it.
    effects.Known(term, types.ModuleExternalEntry(origin:)) ->
      Ok(answer.FunctionAnswer(
        name:,
        module:,
        bounds: fallback_bounds,
        term:,
        source: answer.Entry(types.ModuleExternalEntry(origin:), fallback:),
      ))
    effects.Known(term, types.FunctionEntry(origin:)) ->
      Ok(answer.FunctionAnswer(
        name:,
        module:,
        bounds: effects.lookup_param_bounds(knowledge_base, qualified),
        term:,
        source: answer.Entry(types.FunctionEntry(origin:), fallback:),
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
// This outranks the module-level-external carve-out. `external effects <module>`
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

// Render `name` as a `type` line, or `Error(Nil)` when it isn't a declared type
// field. `name` is split by the same grammar that parses a `type` line, so both
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
  let ctx = project_context(sources)
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
  use explained <- result.map(
    checker.explain(
      module,
      module_path,
      function,
      list.map(checks, check_bounds),
      ctx.knowledge_base,
      ctx.registry,
      typeinfo.for_module(ctx.type_info, module_path),
      typeinfo.fn_typed_for_module(ctx.type_info, module_path),
      ctx.sources.cfg.targets,
    )
    |> result.replace_error(FunctionNotFound(name)),
  )
  // One block per bounds set is `explain`'s contract, so a length mismatch is a
  // broken invariant rather than a case to render: `strict_zip` makes it a crash
  // here instead of blocks silently dropped from the output.
  // nolint: assert_ok_pattern -- a broken invariant, not an error to handle
  let assert Ok(blocks) = list.strict_zip(checks, explained)
    as "explain returns one block per bounds set"
  blocks
  |> list.map(fn(block) {
    let #(check, checker.ExplainedBlock(bounds:, total:, explanations:)) = block
    why_block(name, check, bounds, total, explanations)
  })
  |> string.join("\n\n")
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
  explanations: List(types.CallExplanation),
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
  let lines = case explanations {
    [] -> ["  has no reachable effect contributors"]
    explanations ->
      list.map(explanations, fn(explanation) {
        "  " <> checker.format_call_explanation(explanation)
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

/// List the bundled catalog, or print one bundled catalog file.
///
/// `ListCatalog` prints one `package@version` line per bundled file, sorted,
/// with a comment on the line each of this project's installed packages
/// resolves to. `ShowCatalog` prints one file: at the version this project
/// installs, or at the version the request names, under a `//` header line that
/// says which file it is and why — so the output is itself a valid `.graded`
/// file.
///
/// This is graded's bundled catalog alone: a dependency's shipped spec, a path
/// dependency's spec and your own `external effects` all override it, so
/// `run_effect` is what answers which source wins for a name. Nothing is
/// written to disk.
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
  use catalog_dir <- result.try(
    effects.find_catalog_directory()
    |> result.map_error(fn(candidates) {
      CatalogError(NoCatalogDirectory(candidates))
    }),
  )
  catalog_report(catalog_dir, manifest, request)
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
  use files <- result.try(
    effects.bundled_catalog_files(catalog_dir)
    |> result.map_error(fn(cause) { DirectoryReadError(catalog_dir, cause) }),
  )
  // A directory holding no `{package}@{version}.graded` file is not graded's
  // catalog, whichever way the lookup landed on it.
  use <- bool.guard(
    when: files == [],
    return: Error(CatalogError(EmptyCatalog(catalog_dir))),
  )
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
/// source of truth for hand-written `check`/`external`/`type` lines and
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
/// the input's parse error if it doesn't parse.
pub fn run_format_stdin(
  input: String,
) -> Result(String, annotation.ParseError) {
  use file <- result.map(annotation.parse_file(input))
  annotation.format_sorted(file)
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
      |> result.map_error(GradedParseError(spec_path, _))
  }
}

// Source parsing and signatures
//
// Find and glance-parse the project's sources, and build the signature
// registry used for positional argument matching at call sites.

fn find_gleam_files(directory: String) -> Result(List(String), GradedError) {
  simplifile.get_files(directory)
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

// Build a signature registry covering every project module. Used by
// the checker's call-site substitution to resolve effect variables
// when the caller passes positional (unlabeled) arguments.
fn build_project_registry(
  index: Dict(String, #(String, glance.Module)),
) -> SignatureRegistry {
  dict.fold(index, signatures.empty(), fn(acc, module_path, entry) {
    let #(_gleam_path, module) = entry
    signatures.merge(acc, signatures.from_glance_module(module_path, module))
  })
}

// Build a package-wide map keyed by `#(defining module, name)` from a per-module
// `name -> value` map, qualifying each entry with the module it came from.
fn qualify_by_module(
  index: Dict(String, #(String, glance.Module)),
  per_module: fn(glance.Module) -> Dict(String, value),
) -> Dict(#(String, String), value) {
  dict.fold(index, dict.new(), fn(acc, path, entry) {
    let #(_gleam_path, module) = entry
    dict.fold(per_module(module), acc, fn(inner, name, value) {
      dict.insert(inner, #(path, name), value)
    })
  })
}

// Type index

// Run girard's whole-package type inference once over every project module
// and fold the result into a `TypeInfo` (module path -> span start -> type).
// girard is best-effort: a function it can't type contributes no expressions,
// so the checker silently falls back to syntax-level resolution for it.
fn build_type_index(
  index: Dict(String, #(String, glance.Module)),
  package_root: String,
) -> typeinfo.TypeInfo {
  let options =
    girard.default_options()
    |> girard.with_resolver(build_girard_resolver(
      index,
      dependency_module_files(package_root),
    ))
  let entries =
    dict.to_list(index)
    |> list.map(fn(pair) {
      let #(module_path, #(_gleam_path, module)) = pair
      #(module_path, module)
    })
  let results = girard.annotate_package(entries, options) |> dict.to_list()
  let span_types =
    list.map(results, fn(pair) {
      let #(module_path, module_result) = pair
      let types =
        list.fold(
          module_result.annotated.expressions,
          dict.new(),
          fn(acc, annotation) {
            dict.insert(
              acc,
              #(annotation.span.start, annotation.span.end),
              annotation.type_,
            )
          },
        )
      #(module_path, types)
    })
  let fn_typed =
    list.filter_map(results, fn(pair) {
      let #(module_path, module_result) = pair
      case dict.get(index, module_path) {
        Ok(#(_gleam_path, module)) ->
          Ok(#(module_path, fn_typed_params_from_schemes(module_result, module)))
        Error(Nil) -> Error(Nil)
      }
    })
  typeinfo.from_modules(span_types, fn_typed)
}

// From girard's inferred top-level signatures, the set of function-typed
// parameter names for each function — including parameters with no syntactic
// `fn(...)` annotation, which the glance-only detection misses. A parameter is
// function-typed when its inferred type (positional in the function's `Fn`
// type) is itself a `Fn`.
fn fn_typed_params_from_schemes(
  module_result: girard.ModuleResult,
  module: glance.Module,
) -> Dict(String, Set(String)) {
  let function_map =
    list.fold(module.functions, dict.new(), fn(acc, definition) {
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
    let context = extract.build_import_context(module)
    context.aliases
    |> dict.values()
    |> list.filter(fn(imported) { dict.has_key(index, imported) })
    |> set.from_list()
  })
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
///    `check`, `external effects`, or `type` annotations the user already
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
  diff.contextual(
    outcome.spec_on_disk,
    annotation.format_file(outcome.merged_spec),
  )
  |> option.unwrap("graded: no changes")
  |> Ok
}

// Run `infer` in one of its two modes, returning the message to print. The
// seam `main`'s `infer` branch dispatches through, so both modes are reachable
// from tests.
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
    returns: List(types.ReturnsAnnotation),
    cache: Option(CacheFile),
  )
}

// Run the whole of inference without touching disk beyond reads, so both
// `run_infer` and `run_infer_dry_run` decide what would be written from one
// shared computation.
fn compute_infer(directory: String) -> Result(InferOutcome, GradedError) {
  // A package has one spec file, so a scoped `infer` is a whole-package `infer`:
  // a spec written from a subtree's modules alone would state the package's
  // public surface wrongly rather than partially.
  let directory = source_scope(directory).analysed
  use cfg <- result.try(read_config(directory))
  let package_root = resolve_package_root(directory)
  use #(spec_on_disk, spec) <- result.try(read_spec_on_disk(cfg.spec_file))
  let declared_modules = annotation.module_external_modules(spec)

  use gleam_files <- result.try(find_gleam_files(directory))
  use parsed <- result.try(parse_all_files(gleam_files))
  let index = build_module_index(parsed, directory)
  // As in `project_context`: one target set for the package and every
  // dependency it is built with.
  let package_targets = cfg.targets
  let native_of = native_functions_of(index, package_targets)
  let stale_externals = stale_project_externals(spec, native_of)
  let stale_external_returns = stale_project_external_returns(spec, native_of)

  // Build a signature registry covering every project module so the checker can
  // do positional argument matching for cross-module polymorphic calls. Hoisted
  // above `kb_base` because the builders below consume it; it needs only
  // `index`/`package_root`.
  let dep_sources = dependency_sources(package_root, package_targets)
  let registry =
    signatures.merge(
      dependency_registry(dep_sources),
      build_project_registry(index),
    )
  let type_info = build_type_index(index, package_root)

  let kb_base =
    effects.load_knowledge_base(
      packages_dir(package_root),
      manifest_path(package_root),
      dependency_foreign(dep_sources),
    )
    |> effects.with_package_targets(cfg.targets)
    // Consumer externals are applied before path-dep inference so a module-level
    // external governs a path dependency's module during that dep's own
    // inference, not only at the final lookup.
    |> with_spec_externals(spec, stale_externals)
    // Declared returns are state no inference pass re-derives. Without them the
    // walk of a caller's body writes `[Unknown]` where `check` scores the same
    // body from the declaration, and the two commands disagree about it — so
    // they are folded here, at the point `check` folds them, ahead of the
    // path-dep pass whose own inference reads them too.
    |> with_spec_declared_returns(spec, stale_external_returns)
    |> with_builders(index, dep_sources, package_targets)
    |> enrich_with_path_deps(package_root, declared_modules, package_targets)
    |> effects.with_foreign_functions(project_foreign_functions(
      index,
      package_targets,
    ))

  let base_kb =
    kb_base
    |> with_spec_type_fields(spec)
    |> effects.with_factories(
      qualify_by_module(index, extract.factory_map(
        _,
        types.declaration_targets(package_targets),
      )),
    )

  let graph = build_dependency_graph(index)
  use sorted <- result.try(
    topo.sort(graph)
    |> result.map_error(fn(error) {
      let topo.Cycle(nodes:) = error
      CyclicImports(modules: nodes)
    }),
  )

  let #(_kb, public_annotations, public_returns, cache_files) =
    list.fold(sorted, #(base_kb, [], [], []), fn(state, module_path) {
      let #(kb, acc, returns_acc, cache_acc) = state
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
              typeinfo.for_module(type_info, module_path),
              typeinfo.fn_typed_for_module(type_info, module_path),
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
            list.append(inference.returns, returns_acc),
            case inference.cache {
              None -> cache_acc
              Some(cache) -> [cache, ..cache_acc]
            },
          )
        }
      }
    })

  Ok(InferOutcome(
    cfg:,
    spec_on_disk:,
    merged_spec: annotation.merge_inferred(
      spec,
      public_annotations,
      public_returns,
      stale_externals,
      stale_external_returns,
    ),
    cache_files: list.reverse(cache_files),
  ))
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
  module_types: Dict(#(Int, Int), girard.Type),
  girard_fn_typed: Dict(String, Set(String)),
  declared_modules: Set(String),
  package_targets: types.PackageTargets,
) -> ModuleInference {
  let knowledge_base =
    with_module_fallback_effects(
      knowledge_base,
      module,
      module_path,
      registry,
      module_types,
      girard_fn_typed,
      package_targets,
    )
  let #(inferred, returned_operators, provenance) =
    checker.infer_with_returns(
      module,
      module_path,
      knowledge_base,
      [],
      registry,
      module_types,
      girard_fn_typed,
      package_targets,
    )

  // Skip the cache file when there's nothing to record. Saves an mkdir syscall
  // per stdlib-only module.
  let cache = case inferred {
    [] -> None
    _ ->
      Some(CacheFile(
        path: filepath.join(cache_dir, module_path <> ".graded"),
        file: GradedFile(lines: list.map(inferred, AnnotationLine)),
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

  let public_names = public_function_names(module)
  let public_annotations =
    inferred
    |> list.filter(fn(ann) { set.contains(public_names, ann.function) })
    |> list.map(fn(ann) {
      EffectAnnotation(..ann, function: module_path <> "." <> ann.function)
    })
  // Public functions that return an operator — serialized as `returns` lines so
  // the signature crosses module/package boundaries.
  let public_returns =
    returned_operators
    |> dict.to_list()
    |> list.filter(fn(pair) { set.contains(public_names, pair.0) })
    |> list.map(fn(pair) {
      types.ReturnsAnnotation(
        function: module_path <> "." <> pair.0,
        operator: pair.1,
      )
    })

  ModuleInference(
    knowledge_base: new_kb,
    public: public_annotations,
    returns: public_returns,
    cache:,
  )
}

// Infer project modules in topological order, in memory, folding their
// effects, param bounds, and returned operators into `base_kb` — with existing
// (spec / dependency) entries taking priority, so committed effects are never
// overridden. This lets `check` resolve calls into project modules that haven't
// been `graded infer`-ed yet, without writing the cache. Falls back to
// `base_kb` unchanged when the import graph has a cycle (the real
// `graded infer` reports that error; `check` just degrades to spec-only).
fn infer_project_in_memory(
  base_kb: KnowledgeBase,
  index: Dict(String, #(String, glance.Module)),
  registry: SignatureRegistry,
  type_info: typeinfo.TypeInfo,
  declared_modules: Set(String),
  package_targets: types.PackageTargets,
) -> KnowledgeBase {
  case topo.sort(build_dependency_graph(index)) {
    Error(_) -> base_kb
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
      typeinfo.for_module(type_info, module_path),
      typeinfo.fn_typed_for_module(type_info, module_path),
      package_targets,
    )
  let #(inferred, returned_operators, provenance) =
    checker.infer_with_returns(
      module,
      module_path,
      kb,
      [],
      registry,
      typeinfo.for_module(type_info, module_path),
      typeinfo.fn_typed_for_module(type_info, module_path),
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
}

// Fold what the module's running Gleam fallback bodies do into `knowledge_base`,
// before the module is inferred.
//
// Every pass that infers does this, so a caller of a target-conditional
// `@external` is charged the same effects whichever pass ran: the one that
// reports violations, and the one that writes the spec and cache. A write pass
// that skipped it would publish a caller as pure over an external whose
// fallback is not — and publish it for consumers, who have no body to walk.
//
// The walk needs only the callees already folded, which topological order
// guarantees, so it belongs immediately before the module's own inference.
fn with_module_fallback_effects(
  knowledge_base: KnowledgeBase,
  module: glance.Module,
  module_path: String,
  registry: SignatureRegistry,
  module_types: Dict(#(Int, Int), girard.Type),
  girard_fn_typed: Dict(String, Set(String)),
  package_targets: types.PackageTargets,
) -> KnowledgeBase {
  effects.with_fallback_summaries(
    knowledge_base,
    qualify_bare_names(
      checker.fallback_effects(
        module,
        module_path,
        knowledge_base,
        registry,
        module_types,
        girard_fn_typed,
        package_targets,
      ),
      module_path,
    ),
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
// `drop_declared_modules` in `infer_path_dep_module`. Returned-operator and
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
  let effects_dict = drop_declared_modules(effects_dict, declared_modules)
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
    // Missing gleam.toml: fall back to defaults. Malformed gleam.toml: error.
    Error(config.TomlReadError(..)) ->
      Ok(config.defaults_for(default_package_name(project_root)))
    Error(cause) -> Error(InvalidConfig(path: toml_path, cause:))
  })
  Ok(
    config.GradedConfig(
      ..raw,
      spec_file: resolve_path(project_root, raw.spec_file),
      cache_dir: resolve_path(project_root, raw.cache_dir),
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
    // Every `@external` it declares. Scanned here because this walk already
    // parses each dependency module once, and because it is the only evidence a
    // consumer has: a dependency's spec cannot be trusted to say which of its
    // own functions are foreign, since a stale line for one is exactly what
    // this map exists to refuse.
    foreign: Dict(types.QualifiedName, types.ForeignFunction),
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

// What a dependency's own source says about one name: the three answers the
// spec lint owes a `module.function` it did not find in this package.
type DependencyName {
  // The module's winning copy parsed and defines the function.
  DefinedByDependency
  // It parsed and defines no such function. The one answer that proves a name
  // absent.
  AbsentFromDependency
  // No source graded read says anything: the winning copy would not parse, or
  // the walk never reached the module. No evidence either way.
  UnreadDependency
}

// Answer for `name` from the scan, read off the winning copy of its module and
// that copy alone — the answer a name is owed is what the source this build
// compiles against says, not what any copy left on disk beside it still holds.
fn dependency_name(
  sources: DependencySources,
  name: QualifiedName,
) -> DependencyName {
  case dict.get(sources.modules, name.module) {
    Error(Nil) | Ok(UnreadableModule) -> UnreadDependency
    Ok(ParsedModule(functions:, ..)) ->
      case set.contains(functions, name.function) {
        True -> DefinedByDependency
        False -> AbsentFromDependency
      }
  }
}

// Merge two scans; `b`'s copy of a module path replaces `a`'s whole, so no path
// is ever spoken for by two copies at once.
fn merge_dependency_sources(
  a: DependencySources,
  b: DependencySources,
) -> DependencySources {
  DependencySources(modules: dict.merge(a.modules, b.modules))
}

// Every dependency's source-derived entries: installed packages under
// `build/packages`, then path dependencies, whose copy of a module path wins.
fn dependency_sources(
  package_root: String,
  package_targets: types.PackageTargets,
) -> DependencySources {
  merge_dependency_sources(
    packages_dir_sources(packages_dir(package_root), package_targets),
    path_dep_sources(package_root, package_targets),
  )
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
) -> KnowledgeBase {
  knowledge_base
  |> effects.with_updates(dependency_updates(dep_sources))
  |> effects.with_updates(
    qualify_by_module(index, extract.update_map(
      _,
      types.declaration_targets(package_targets),
    )),
  )
}

// Scan the `src/` tree of every installed dependency under `build/packages`.
fn packages_dir_sources(
  packages_directory: String,
  package_targets: types.PackageTargets,
) -> DependencySources {
  case simplifile.read_directory(packages_directory) {
    Error(_) -> empty_dependency_sources()
    Ok(entries) ->
      list.fold(entries, empty_dependency_sources(), fn(acc, dep) {
        let src_dir =
          filepath.join(filepath.join(packages_directory, dep), "src")
        merge_dependency_sources(
          acc,
          source_dir_sources(src_dir, package_targets),
        )
      })
  }
}

// Scan one package's `src/` tree, recording what each module derives under its
// module path. A file that would not read or parse derives nothing, and is
// recorded as the unreadable copy of its path.
fn source_dir_sources(
  source_dir: String,
  package_targets: types.PackageTargets,
) -> DependencySources {
  use acc, module_path, parsed <- signatures.fold_source_dir(
    source_dir,
    empty_dependency_sources(),
  )
  let scanned = case parsed {
    Ok(module) ->
      ParsedModule(
        functions: module_function_names(module),
        registry: signatures.from_glance_module(module_path, module),
        updates: extract.public_update_signatures(
          module,
          module_path,
          types.declaration_targets(package_targets),
        ),
        foreign: checker.dependency_foreign_functions(
          module,
          module_path,
          package_targets,
        ),
      )
    Error(Nil) -> UnreadableModule
  }
  DependencySources(modules: dict.insert(acc.modules, module_path, scanned))
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

// Join a path against a root, but leave it untouched if it's already
// absolute (starts with `/`) or if the root is `.` (so production paths
// stay short and unprefixed).
fn resolve_path(root: String, path: String) -> String {
  use <- bool.guard(
    when: string.starts_with(path, "/") || root == ".",
    return: path,
  )
  filepath.join(root, path)
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
  case simplifile.read(spec_path) {
    Error(simplifile.Enoent) -> Ok(#("", GradedFile(lines: [])))
    Error(cause) -> Error(FileReadError(spec_path, cause))
    Ok(content) ->
      annotation.parse_file(content)
      |> result.map(fn(file) { #(content, file) })
      |> result.map_error(GradedParseError(spec_path, _))
  }
}

// Path dependencies
//
// Fold path dependencies into the knowledge base: read a committed dep spec
// when present, otherwise infer the dep from source in topological order.

// For each path dependency declared in `gleam.toml`:
//
// 1. Try to load its spec file (via the dep's own `[tools.graded]`
//    config, defaulting to `<package_name>.graded`) and fold its
//    annotations into the knowledge base via `with_path_dep_spec`, which
//    places them below the consumer's own entries and above the catalog.
//    This is the fast, intended path: the dep author already ran `graded
//    infer`, committed the spec file, and the consumer just reads it.
//
// 2. If the dep has no spec file, fall back to inferring from source via
//    `infer_path_dep` so path deps without graded set up still work. These
//    results gap-fill: a catalog entry for the same name still wins.
//    Cross-path-dep imports are not currently merged into a single graph
//    — each dep is processed sequentially.
//
// A module the consumer declared with a module-level external (in
// `consumer_modules`) is not inferred over during step 2 (see `infer_path_dep`),
// so the consumer's declaration governs it. The spec-file branch is left
// untouched: a function-keyed entry from an authoritative dep spec still wins
// over a module-level external, per-function beating module-level.
fn enrich_with_path_deps(
  knowledge_base: KnowledgeBase,
  package_root: String,
  consumer_modules: Set(String),
  package_targets: types.PackageTargets,
) -> KnowledgeBase {
  let path_deps =
    effects.parse_path_dependencies(filepath.join(package_root, "gleam.toml"))
  list.fold(path_deps, knowledge_base, fn(kb, dep) {
    let #(name, dep_path) = dep
    // Path dependency locations are declared relative to the project root,
    // except an absolute `path`, which `resolve_path` leaves untouched.
    let resolved_dep_path = resolve_path(package_root, dep_path)
    let spec_path = config.spec_file_for(resolved_dep_path, name)
    case simplifile.is_file(spec_path) {
      Ok(True) ->
        effects.with_path_dep_spec(
          kb,
          effects.load_dep_spec(resolved_dep_path, name),
          types.PathDependency(package: name),
        )
      _ ->
        case
          infer_path_dep(
            resolved_dep_path,
            kb,
            consumer_modules,
            package_targets,
          )
        {
          Error(Nil) -> kb
          // Inference over the dep's source, not a line its author wrote: the
          // origin says so, so nothing downstream reads it as a declaration.
          Ok(#(effs, params, returns, provenance)) ->
            fold_inferred_into_kb(
              kb,
              effs,
              params,
              returns,
              types.PathDependencyInferred(package: name),
            )
            |> effects.with_provenance(provenance)
        }
    }
  })
}

// Scan the `src/` tree of every path dependency declared in `gleam.toml`. Path
// deps live at their declared `path`, not under `build/packages`, so
// `packages_dir_sources` never sees them — without this their cross-module
// callees lack the parameter-position info that positional (unlabeled) argument
// matching needs to bind effect variables at the call site, and their builders
// resolve only from a serialized `update` line.
fn path_dep_sources(
  package_root: String,
  package_targets: types.PackageTargets,
) -> DependencySources {
  effects.parse_path_dependencies(filepath.join(package_root, "gleam.toml"))
  |> list.fold(empty_dependency_sources(), fn(acc, dep) {
    let #(_name, dep_path) = dep
    let resolved_dep_path = resolve_path(package_root, dep_path)
    merge_dependency_sources(
      acc,
      source_dir_sources(resolved_dep_path <> "/src", package_targets),
    )
  })
}

// Apply three `QualifiedName`-keyed inferred maps — effects, polymorphic param
// bounds, and returned-operator signatures — to the knowledge base. The shared
// tail of `thread_inferred_into_kb` and the infer-from-source path-dep branch:
// effects alone would leave a higher-order callee's bound unloaded, so its
// callback's effect variable would leak unsubstituted into every caller.
// Existing effects and param bounds win; the returned-operator summaries are
// `Fresh` (Fix E) — inferred this run, so they win over a committed Foreign
// entry for the same key. `lookup_origin` names the source of the effect terms,
// recorded for the keys this merge wins.
fn fold_inferred_into_kb(
  knowledge_base: KnowledgeBase,
  effs: Dict(QualifiedName, types.EffectTerm),
  params: Dict(QualifiedName, List(types.ParamBound)),
  returns: Dict(QualifiedName, types.EffectTerm),
  lookup_origin: types.LookupOrigin,
) -> KnowledgeBase {
  knowledge_base
  |> effects.with_inferred(effs, lookup_origin)
  |> effects.with_inferred_params(params)
  |> effects.with_fresh_returned_operators(returns, lookup_origin)
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
pub fn infer_path_dep(
  dep_path: String,
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
  let source_dir = dep_path <> "/src"
  let gleam_files = case simplifile.get_files(source_dir) {
    Ok(found) ->
      list.filter(found, fn(path) { string.ends_with(path, ".gleam") })
    Error(_) -> []
  }

  let entries =
    list.filter_map(gleam_files, fn(gleam_path) {
      use module <- result.try(
        read_and_parse_gleam(gleam_path) |> result.map_error(fn(_) { Nil }),
      )
      let module_path = config.module_path_for_source(gleam_path, source_dir)
      // Path-dep checks come from the dep's spec file (loaded by
      // enrich_with_path_deps), not from per-module files. Inference here
      // only needs the parsed module.
      Ok(#(module_path, module, []))
    })

  let index =
    list.fold(entries, dict.new(), fn(acc, entry) {
      let #(module_path, module, checks) = entry
      dict.insert(acc, module_path, #(module, checks))
    })

  let graph =
    dict.map_values(index, fn(_module_path, entry) {
      let #(module, _checks) = entry
      let context = extract.build_import_context(module)
      context.aliases
      |> dict.values()
      |> list.filter(fn(imported) { dict.has_key(index, imported) })
      |> set.from_list()
    })

  // A registry covering the dep's own modules, so a cross-module call between
  // them (`b.run` calling `a.apply(cb)`) matches the callee's bound by parameter
  // position during inference — exactly as the project registry does for the
  // project's own modules. Built from the already-parsed `index`, not re-read.
  let registry =
    dict.fold(index, signatures.empty(), fn(acc, module_path, entry) {
      let #(module, _checks) = entry
      signatures.merge(acc, signatures.from_glance_module(module_path, module))
    })

  use sorted <- result.try(topo.sort(graph) |> result.map_error(fn(_) { Nil }))
  // The dep's own KB is internal to this pass; its entries are re-folded by the
  // caller under the package name `gleam.toml` declared. The directory name is
  // what this entry point knows the dep by.
  let origin =
    types.PathDependencyInferred(package: filepath.base_name(dep_path))
  let #(effs, params, returns, provenance, _final_kb) =
    list.fold(
      sorted,
      #(dict.new(), dict.new(), dict.new(), dict.new(), base_kb),
      fn(state, module_path) {
        infer_path_dep_module(
          state,
          module_path,
          index,
          registry,
          consumer_modules,
          origin,
          package_targets,
        )
      },
    )
  Ok(#(effs, params, returns, provenance))
}

fn infer_path_dep_module(
  state: #(
    Dict(QualifiedName, types.EffectTerm),
    Dict(QualifiedName, List(types.ParamBound)),
    Dict(QualifiedName, types.EffectTerm),
    Dict(QualifiedName, types.ReturnProvenance),
    KnowledgeBase,
  ),
  module_path: String,
  index: Dict(String, #(glance.Module, List(types.EffectAnnotation))),
  registry: SignatureRegistry,
  consumer_modules: Set(String),
  lookup_origin: types.LookupOrigin,
  package_targets: types.PackageTargets,
) -> #(
  Dict(QualifiedName, types.EffectTerm),
  Dict(QualifiedName, List(types.ParamBound)),
  Dict(QualifiedName, types.EffectTerm),
  Dict(QualifiedName, types.ReturnProvenance),
  KnowledgeBase,
) {
  let #(eff_acc, param_acc, returns_acc, prov_acc, kb) = state
  case dict.get(index, module_path) {
    Error(_) -> state
    Ok(#(module, checks)) -> {
      // Path-dep inference skips girard in v1 (cost/benefit): pass no types.
      let #(annotations, returned_operators, provenance) =
        checker.infer_with_returns(
          module,
          module_path,
          kb,
          checks,
          registry,
          dict.new(),
          dict.new(),
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
      let inferred_effs = drop_declared_modules(inferred_effs, consumer_modules)
      let inferred_provenance = qualify_bare_names(provenance, module_path)
      let new_kb =
        fold_inferred_into_kb(
          kb,
          inferred_effs,
          inferred_params,
          inferred_returns,
          lookup_origin,
        )
        |> effects.with_provenance(inferred_provenance)
      #(
        dict.merge(eff_acc, inferred_effs),
        dict.merge(param_acc, inferred_params),
        dict.merge(returns_acc, inferred_returns),
        dict.merge(prov_acc, inferred_provenance),
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

// The spec's `external effects` declarations, minus the stale ones.
fn with_spec_externals(
  knowledge_base: KnowledgeBase,
  spec: GradedFile,
  stale_externals: Set(String),
) -> KnowledgeBase {
  effects.with_externals(
    knowledge_base,
    declaring_externals(spec, stale_externals),
    types.UserExternal,
  )
}

// The spec's `external returns` declarations, minus the stale ones. A stale line
// is ignored at load as well as warned about and rewritten: trusted between
// `infer` runs it would be a per-function override of what the walk can see for
// itself.
fn with_spec_declared_returns(
  knowledge_base: KnowledgeBase,
  spec: GradedFile,
  stale_external_returns: Set(String),
) -> KnowledgeBase {
  effects.with_declared_returned_operators(
    knowledge_base,
    effects.load_spec_external_returns_from_file(spec)
      |> drop_stale_names(stale_external_returns),
    types.UserExternal,
  )
}

// The spec's `type` lines, which resolve a field call on any receiver of the
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
// Lines for a name a *stale* per-function external also names are dropped from
// both too. A healthy spec never holds that pair — `infer` deletes the external
// and rewrites the `effects` line in one pass — so where they coexist the spec's
// state for the name is one no `infer` produced, and the committed term must not
// outrank the fresh walk: the warning promises the body is walked instead, and a
// committed entry surviving here is exactly what would silence it for every
// cross-module caller and for the query.
//
// Shared by the full project context and the `effect` query's spec-only fast
// path, which must fold the spec exactly as the full context does for its answer
// to be the one the full context would have given.
fn with_committed_spec(
  knowledge_base: KnowledgeBase,
  spec: GradedFile,
  stale_externals: Set(String),
) -> KnowledgeBase {
  // Read off the spec being folded, not taken from the caller: the modules to
  // drop are a property of that spec, and a caller passing any other set folds
  // in the very lines this function exists to drop.
  let declared_modules = annotation.module_external_modules(spec)
  knowledge_base
  |> effects.with_inferred(
    effects.load_spec_effects_from_file(spec)
      |> drop_declared_modules(declared_modules)
      |> drop_stale_names(stale_externals),
    types.CommittedSpec,
  )
  |> effects.with_inferred_params(
    effects.load_spec_params_from_file(spec)
    |> drop_declared_modules(declared_modules)
    |> drop_stale_names(stale_externals),
  )
}

// Drop every entry whose dotted name a stale per-function external also names.
fn drop_stale_names(
  entries: Dict(QualifiedName, a),
  stale_externals: Set(String),
) -> Dict(QualifiedName, a) {
  use <- bool.guard(set.is_empty(stale_externals), entries)
  dict.filter(entries, fn(name, _value) {
    !set.contains(stale_externals, types.dotted_name(name))
  })
}

// Drop every `QualifiedName`-keyed entry whose module the consumer declared
// with a module-level external. Keyed off the consumer's declared modules, not
// the whole knowledge base, so a catalog pure-module entry never suppresses a
// same-named path-dependency module.
fn drop_declared_modules(
  entries: Dict(QualifiedName, a),
  modules: Set(String),
) -> Dict(QualifiedName, a) {
  use <- bool.guard(set.is_empty(modules), entries)
  dict.filter(entries, fn(name, _value) { !set.contains(modules, name.module) })
}

// CLI plumbing
//
// Argument handling, human-readable printing of errors, violations, and
// warnings, and the exit/stdin externals behind `main`.

fn run_check(directory: String) -> Nil {
  case run(directory) {
    Ok(results) -> {
      let violations =
        list.flat_map(results, fn(check_result) { check_result.violations })
      let warnings =
        list.flat_map(results, fn(check_result) { check_result.warnings })
      list.each(results, print_warnings)
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
          list.each(results, print_violations)
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

fn format_error(error: GradedError) -> String {
  case error {
    DirectoryReadError(path, _) -> "Could not read directory: " <> path
    FileReadError(path, _) -> "Could not read: " <> path
    FileWriteError(path, _) -> "Could not write: " <> path
    DirectoryCreateError(path, _) -> "Could not create directory: " <> path
    GleamParseError(path, _) -> "Could not parse: " <> path
    GradedParseError(path, cause) ->
      "Parse error in " <> path <> ":" <> annotation.describe_parse_error(cause)
    InvalidConfig(path, _) -> "Invalid gleam.toml: " <> path
    FormatCheckFailed(paths:) ->
      "Unformatted .graded files:\n"
      <> string.join(list.map(paths, fn(path) { "  " <> path }), "\n")
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

fn print_violations(check_result: CheckResult) -> Nil {
  list.each(check_result.violations, fn(violation) {
    print_violation(check_result.file, violation)
  })
}

fn print_violation(file: String, violation: Violation) -> Nil {
  io.println(checker.format_violation(file, violation))
}

fn print_warnings(check_result: CheckResult) -> Nil {
  list.each(check_result.warnings, fn(warning) {
    print_warning(check_result.file, warning)
  })
}

fn print_warning(file: String, warning: Warning) -> Nil {
  io.println(checker.format_warning(file, warning))
}

@external(erlang, "erlang", "halt")
@external(javascript, "./graded_ffi.mjs", "halt")
fn halt(code: Int) -> Nil

// Read all of standard input to EOF as a single string.
@external(erlang, "graded_ffi", "read_stdin")
@external(javascript, "./graded_ffi.mjs", "read_stdin")
fn read_stdin() -> String

// graded's own version, from the loaded OTP application's `vsn`.
@external(erlang, "graded_ffi", "version")
@external(javascript, "./graded_ffi.mjs", "version")
fn version() -> String

// Inject a `.graded` spec into a hex tarball at `in_tar`, writing the patched
// archive to `out_tar` with `spec` placed at the archive-relative `entry_name`.
// Returns the recomputed inner checksum, or an error message.
// nolint: stringly_typed_error -- opaque erl_tar diagnostic, wrapped in PackError
@external(erlang, "graded_pack_ffi", "inject_spec")
@external(javascript, "./graded_pack_ffi.mjs", "inject_spec")
fn inject_spec(
  in_tar: String,
  spec: String,
  entry_name: String,
  out_tar: String,
) -> Result(String, String)

// Assert a written tarball is internally consistent (checksum + files list) and
// carries `entry_name`.
// nolint: stringly_typed_error -- opaque erl_tar diagnostic, wrapped in PackError
@external(erlang, "graded_pack_ffi", "verify_tarball")
@external(javascript, "./graded_pack_ffi.mjs", "verify_tarball")
fn verify_tarball(tar: String, entry_name: String) -> Result(Nil, String)

// Read `#(name, version)` from a hex tarball's `metadata.config`.
// nolint: stringly_typed_error -- opaque erl_tar diagnostic, wrapped in PackError
@external(erlang, "graded_pack_ffi", "read_package_identity")
@external(javascript, "./graded_pack_ffi.mjs", "read_package_identity")
fn read_package_identity(tar: String) -> Result(#(String, String), String)

// Atomically reserve `path` for this invocation: an O_EXCL create that fails
// on any existing path and refuses to follow symlinks (a dangling symlink is
// rejected, not written through).
// nolint: stringly_typed_error -- opaque posix diagnostic, wrapped in PackError
@external(erlang, "graded_pack_ffi", "reserve_path")
@external(javascript, "./graded_pack_ffi.mjs", "reserve_path")
fn reserve_path(path: String) -> Result(Nil, String)
