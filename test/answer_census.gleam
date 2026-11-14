// The answer census: every public function's answer over a set of package
// roots, one sorted line per item, so two graded revisions can be compared
// line by line.
//
//   gleam run -m answer_census -- <out> <root>...
//
// A root is a directory, or `label=directory` where two roots would share a
// directory name. For each root the census computes what `graded infer` would
// write — from the root's source, never from its committed `effects` lines —
// the call sites behind every answer that holds `Unknown`, and every `check`
// line's verdict against that same knowledge base. It records the imported
// facts it read beside them: each installed package's version, the catalog
// file selected for it and whether it ships a spec, and each local package's
// spec. It writes nothing under the roots.
//
// A root that fails to load is reported with the reason, and its public
// functions stay in the count, each marked unloaded.

import argv
import filepath
import glance
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import graded
import graded/internal/annotation
import graded/internal/checker
import graded/internal/config
import graded/internal/effects
import graded/internal/package_tree
import graded/internal/signatures
import graded/internal/types
import simplifile

pub fn main() -> Nil {
  case argv.load().arguments {
    [out, first, ..rest] -> {
      let content = census([first, ..rest])
      case simplifile.write(out, content) {
        Ok(Nil) -> io.println("answer_census: wrote " <> out)
        Error(error) ->
          io.println_error(
            "answer_census: cannot write "
            <> out
            <> ": "
            <> simplifile.describe_error(error),
          )
      }
    }
    _ -> io.println_error("usage: answer_census <out> <root>...")
  }
}

// The census of every root, as the text written to the output file.
pub fn census(roots: List(String)) -> String {
  roots
  |> list.flat_map(root_lines)
  |> list.sort(string.compare)
  |> list.map(fn(line) { line <> "\n" })
  |> string.concat
}

// Every line one root contributes.
pub fn root_lines(argument: String) -> List(String) {
  let #(label, directory) = case string.split_once(argument, "=") {
    Ok(#(label, directory)) -> #(label, directory)
    Error(Nil) -> #(filepath.base_name(argument), argument)
  }
  let directory = absolute(directory)
  let public = public_functions(directory)
  let header = [
    "root " <> label <> " public " <> int.to_string(list.length(public)),
  ]
  let facts = imported_facts(label, directory)
  let body = case graded.census_root(directory) {
    Ok(report) -> [
      "root " <> label <> " load ok",
      ..report_lines(label, directory, report)
    ]
    Error(error) -> [
      "root "
        <> label
        <> " load error "
        <> normalize(string.inspect(error), directory),
      ..list.map(public, fn(name) {
        "answer " <> label <> " " <> name <> " : unloaded"
      })
    ]
  }
  list.flatten([header, facts, body])
}

// Answers, unknown sources and violations.
fn report_lines(
  label: String,
  directory: String,
  report: graded.CensusRoot,
) -> List(String) {
  let answers =
    list.map(report.answers, fn(ann) {
      "answer " <> label <> " " <> single_line(render_answer(ann))
    })
  let unknowns =
    list.flat_map(report.unknown_sources, fn(entry) {
      let #(function, explanations) = entry
      explanations
      |> list.map(fn(explanation) {
        "unknown "
        <> label
        <> " "
        <> function
        <> " "
        <> shape(checker.call_kind(explanation.call))
        <> " "
        <> origin(explanation.origin)
        <> " "
        <> reason(explanation.reason)
      })
      |> list.unique
    })
  let violations =
    list.map(report.violations, fn(violation) {
      "violation "
      <> label
      <> " "
      <> single_line(normalize(violation, directory))
    })
  list.flatten([answers, unknowns, violations])
}

// An inferred line without its leading keyword: path, bounds, term and the
// returned operator.
fn render_answer(ann: types.EffectAnnotation) -> String {
  let line = annotation.format_annotation(ann)
  case string.split_once(line, " ") {
    Ok(#(_keyword, rest)) -> rest
    Error(Nil) -> line
  }
}

// Classification tags
//
// What a contributor is, where its answer came from, and why it stayed
// unresolved — the classes the measurement groups newly unknown answers by.

pub fn shape(kind: checker.CallKind) -> String {
  case kind {
    checker.DirectCall(..) -> "direct"
    checker.ParameterCall(..) -> "parameter"
    checker.FieldAccessCall(..) -> "field"
    checker.ComputedFieldCall(..) -> "computed-field"
    checker.UnresolvedLocalCall(..) -> "unresolved-local"
    checker.ReturnedOperatorCall(..) -> "returned-operator"
    checker.ExternalDeclaration(..) -> "external-declaration"
    checker.CallerDeclaration(..) -> "caller-declaration"
    checker.InlineFunctionCall -> "inline-function"
    checker.LetBoundValueCall -> "let-bound-value"
    checker.ComputedValueCall -> "computed-value"
    checker.UnclassifiedCall -> "unclassified"
  }
}

pub fn origin(origin: option.Option(types.LookupOrigin)) -> String {
  case origin {
    None -> "no-origin"
    Some(origin) -> origin_tag(origin)
  }
}

fn origin_tag(origin: types.LookupOrigin) -> String {
  case origin {
    types.UserAssume -> "user-assume"
    types.CommittedSpec -> "committed-spec"
    types.ProjectInferred -> "project-inferred"
    types.DependencySpec(package:) -> "dependency-spec:" <> package
    types.PathDependency(package:) -> "path-dependency:" <> package
    types.PathDependencyInferred(package:) ->
      "path-dependency-inferred:" <> package
    types.Catalog(package:) -> "catalog:" <> package
    types.ModuleAssumeOrigin(source:) -> "module-assume:" <> origin_tag(source)
    types.FieldAssumeOrigin(source:) -> "field-assume:" <> origin_tag(source)
  }
}

pub fn reason(reason: option.Option(types.UnknownReason)) -> String {
  case reason {
    None -> "no-reason"
    Some(types.NoKnownEffects) -> "no-known-effects"
    Some(types.UndeclaredExternal) -> "undeclared-external"
    Some(types.UnbuiltExternal) -> "unbuilt-external"
    Some(types.ReceiverTypeUnresolved) -> "receiver-type-unresolved"
    Some(types.FieldNotAnnotated(..)) -> "field-not-annotated"
    Some(types.AmbiguousShadowedReceiver(..)) -> "ambiguous-shadowed-receiver"
    Some(types.UntraceableReceiver) -> "untraceable-receiver"
    Some(types.UnresolvedFieldValue) -> "unresolved-field-value"
    Some(types.UntraceableProducer) -> "untraceable-producer"
    Some(types.RefusedDeclaredReturn) -> "refused-declared-return"
    Some(types.UntraceableArgument) -> "untraceable-argument"
  }
}

// Imported facts
//
// What the root's answers were computed under, beyond its own source.

fn imported_facts(label: String, directory: String) -> List(String) {
  let versions =
    effects.read_manifest_versions(filepath.join(directory, "manifest.toml"))
    |> result.unwrap(dict.new())
  let catalog = catalog_files()
  let installed =
    versions
    |> dict.to_list
    |> list.flat_map(fn(entry) {
      let #(package, version) = entry
      let package_root =
        filepath.join(directory, "build/packages")
        |> filepath.join(package)
      let selected = case
        effects.select_catalog_file(catalog, package, version)
      {
        Ok(effects.Selected(file)) -> file.package <> "@" <> file.version
        Ok(effects.HighestBundled(file)) ->
          file.package <> "@" <> file.version <> " (highest bundled)"
        Error(Nil) -> "none"
      }
      [
        "fact " <> label <> " package " <> package <> "@" <> version,
        "fact " <> label <> " catalog " <> package <> " " <> selected,
        "fact "
          <> label
          <> " spec "
          <> package
          <> " "
          <> spec_state(config.spec_file_for(package_root, package)),
      ]
    })
  let local =
    package_tree.discover(directory).packages
    |> dict.values
    |> list.map(fn(package) {
      "fact "
      <> label
      <> " local "
      <> package.name
      <> " "
      <> spec_state(filepath.join(package.directory, package.spec_file))
    })
  list.append(installed, local)
}

// Whether a spec file is there, and which content it holds.
fn spec_state(path: String) -> String {
  case simplifile.read_bits(path) {
    Ok(content) -> "sha256:" <> sha256_hex(content)
    Error(_) -> "absent"
  }
}

fn catalog_files() -> List(effects.CatalogFile) {
  case graded.locate_catalog(effects.catalog_candidates()) {
    Ok(directory) ->
      effects.bundled_catalog_files(directory) |> result.unwrap([])
    Error(_) -> []
  }
}

@external(erlang, "answer_census_ffi", "sha256_hex")
fn sha256_hex(content: BitArray) -> String

// The denominator
//
// Counted off the root's parsed source alone, so a root that cannot load keeps
// its public functions in the count.

fn public_functions(directory: String) -> List(String) {
  {
    use names, module_path, _path, parsed <- signatures.fold_source_dir(
      filepath.join(directory, "src"),
      [],
    )
    case parsed {
      Error(Nil) -> names
      Ok(module) ->
        module.functions
        |> list.filter(fn(definition) {
          definition.definition.publicity == glance.Public
        })
        |> list.map(fn(definition) {
          module_path <> "." <> definition.definition.name
        })
        |> list.append(names, _)
    }
  }
  |> set.from_list
  |> set.to_list
}

// Normalization

// `text` with the root's absolute directory written as `<root>`.
fn normalize(text: String, directory: String) -> String {
  string.replace(text, directory, "<root>")
}

// A rendering that may wrap onto continuation lines, joined onto one.
fn single_line(text: String) -> String {
  text
  |> string.split("\n")
  |> list.map(string.trim)
  |> string.join(" ")
}

fn absolute(directory: String) -> String {
  case filepath.expand(directory) {
    Ok(path) ->
      case string.starts_with(path, "/") {
        True -> path
        False ->
          case simplifile.current_directory() {
            Ok(cwd) -> filepath.join(cwd, path)
            Error(_) -> path
          }
      }
    Error(Nil) -> directory
  }
}
