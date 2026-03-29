import argv
import assay/annotation
import assay/checker
import assay/effects.{type KnowledgeBase}
import assay/types.{
  type AssayFile, type CheckResult, type Violation, AnnotationLine, AssayFile,
  CheckResult,
}
import filepath
import glance
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub type AssayError {
  DirectoryReadError(path: String, cause: simplifile.FileError)
  FileReadError(path: String, cause: simplifile.FileError)
  FileWriteError(path: String, cause: simplifile.FileError)
  DirectoryCreateError(path: String, cause: simplifile.FileError)
  GleamParseError(path: String, cause: glance.Error)
  AssayParseError(path: String, cause: annotation.ParseError)
}

pub fn main() -> Nil {
  let arguments = argv.load().arguments
  case arguments {
    ["infer", ..rest] ->
      case run_infer(target_directory(rest)) {
        Ok(Nil) -> io.println("assay: inferred effects written")
        Error(error) -> {
          io.println_error("assay: error: " <> format_error(error))
          halt(1)
        }
      }
    ["check", ..rest] -> run_check(target_directory(rest))
    _ -> run_check(target_directory(arguments))
  }
}

/// Run the checker on all .gleam files in a directory.
/// Only enforces `check` annotations.
pub fn run(directory: String) -> Result(List(CheckResult), AssayError) {
  let knowledge_base = effects.load_knowledge_base("build/packages")
  use gleam_files <- result.try(find_gleam_files(directory))

  let results =
    list.filter_map(gleam_files, fn(gleam_path) {
      let assay_path = gleam_to_assay_path(gleam_path, directory)
      case simplifile.read(assay_path) {
        Error(_no_assay_file) -> Error(Nil)
        Ok(assay_content) ->
          case check_file(gleam_path, assay_content, knowledge_base) {
            Ok(check_result) -> Ok(check_result)
            Error(_check_error) -> Error(Nil)
          }
      }
    })

  Ok(results)
}

/// Infer effects for all .gleam files and write/merge .assay files.
pub fn run_infer(directory: String) -> Result(Nil, AssayError) {
  let knowledge_base = effects.load_knowledge_base("build/packages")
  use gleam_files <- result.try(find_gleam_files(directory))

  list.try_each(gleam_files, fn(gleam_path) {
    let assay_path = gleam_to_assay_path(gleam_path, directory)
    use module <- result.try(read_and_parse_gleam(gleam_path))

    let inferred = checker.infer(module, knowledge_base)

    let parent_directory = filepath.directory_name(assay_path)
    use Nil <- result.try(
      simplifile.create_directory_all(parent_directory)
      |> result.map_error(DirectoryCreateError(parent_directory, _)),
    )

    case inferred, simplifile.read(assay_path) {
      [], Error(_no_file) -> Ok(Nil)
      _, Ok(existing_content) -> {
        let assay_file = case annotation.parse_file(existing_content) {
          Ok(existing_file) ->
            annotation.merge_inferred(existing_file, inferred)
          Error(_parse_error) ->
            AssayFile(lines: list.map(inferred, AnnotationLine))
        }
        write_assay_file(assay_path, assay_file)
      }
      _, Error(_no_file) -> {
        let assay_file = AssayFile(lines: list.map(inferred, AnnotationLine))
        write_assay_file(assay_path, assay_file)
      }
    }
  })
}

/// Convert a .gleam source path to its .assay path in priv/assay/.
pub fn gleam_to_assay_path(gleam_path: String, source_directory: String) -> String {
  let prefix = source_directory <> "/"
  let relative = case string.starts_with(gleam_path, prefix) {
    True -> string.drop_start(gleam_path, string.length(prefix))
    False -> gleam_path
  }
  let assay_relative = filepath.strip_extension(relative) <> ".assay"
  let priv_directory = case source_directory {
    "src" -> "priv/assay"
    _ -> source_directory <> "/priv/assay"
  }
  priv_directory <> "/" <> assay_relative
}

// PRIVATE

fn target_directory(arguments: List(String)) -> String {
  case arguments {
    [directory, ..] -> directory
    [] -> "src"
  }
}

fn run_check(directory: String) -> Nil {
  case run(directory) {
    Ok(results) -> {
      let violations =
        list.flat_map(results, fn(check_result) { check_result.violations })
      case violations {
        [] -> io.println("assay: all checks passed")
        _ -> {
          list.each(results, print_result)
          io.println(
            "\nassay: "
            <> int.to_string(list.length(violations))
            <> " violation(s) found",
          )
          halt(1)
        }
      }
    }
    Error(error) -> {
      io.println_error("assay: error: " <> format_error(error))
      halt(1)
    }
  }
}

fn find_gleam_files(directory: String) -> Result(List(String), AssayError) {
  simplifile.get_files(directory)
  |> result.map_error(DirectoryReadError(directory, _))
  |> result.map(list.filter(_, fn(path) { string.ends_with(path, ".gleam") }))
}

fn read_and_parse_gleam(gleam_path: String) -> Result(glance.Module, AssayError) {
  use source <- result.try(
    simplifile.read(gleam_path)
    |> result.map_error(FileReadError(gleam_path, _)),
  )
  glance.module(source)
  |> result.map_error(GleamParseError(gleam_path, _))
}

fn check_file(
  gleam_path: String,
  assay_content: String,
  knowledge_base: KnowledgeBase,
) -> Result(CheckResult, AssayError) {
  use assay_file <- result.try(
    annotation.parse_file(assay_content)
    |> result.map_error(AssayParseError(gleam_path, _)),
  )
  let check_annotations = annotation.extract_checks(assay_file)

  use module <- result.try(read_and_parse_gleam(gleam_path))

  let violations = checker.check(module, check_annotations, knowledge_base)
  Ok(CheckResult(file: gleam_path, violations:))
}

fn write_assay_file(
  path: String,
  assay_file: AssayFile,
) -> Result(Nil, AssayError) {
  simplifile.write(path, annotation.format_file(assay_file))
  |> result.map_error(FileWriteError(path, _))
}

fn format_error(error: AssayError) -> String {
  case error {
    DirectoryReadError(path, _) -> "Could not read directory: " <> path
    FileReadError(path, _) -> "Could not read: " <> path
    FileWriteError(path, _) -> "Could not write: " <> path
    DirectoryCreateError(path, _) -> "Could not create directory: " <> path
    GleamParseError(path, _) -> "Could not parse: " <> path
    AssayParseError(path, _) -> "Parse error in .assay file for: " <> path
  }
}

fn print_result(check_result: CheckResult) -> Nil {
  list.each(check_result.violations, fn(violation) {
    print_violation(check_result.file, violation)
  })
}

fn print_violation(file: String, violation: Violation) -> Nil {
  io.println(
    file
    <> ": "
    <> violation.function
    <> " calls "
    <> violation.call.module
    <> "."
    <> violation.call.function
    <> " with effects "
    <> effects.format_effect_set(violation.actual)
    <> " but declared "
    <> effects.format_effect_set(violation.declared),
  )
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
