import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import graded/internal/answer

// Command-line argument decoding
//
// Pure decoders for the argument forms `main` dispatches on. Keeping them here
// rather than inline in `main`'s branches (which print and exit) makes the
// argument rules testable, and keeps the CLI surface off the published
// top-level module.

// Why a command's arguments were rejected. Rendered by `format_argument_error`
// into the message the usage error prints.
pub type ArgumentError {
  // A command's required name was not given. `command` is the command that
  // wanted one, so the message names it.
  MissingName(command: String)
  // A token that looks like a flag where a name or directory was expected.
  UnknownOption(argument: String)
  // A token past the last one the command accepts.
  UnexpectedArgument(argument: String)
  // `--format=` given a value that names no output format.
  UnknownFormat(value: String)
  // A token in the package position that names no package: an empty package or
  // an empty version around the `@`.
  InvalidPackage(argument: String)
}

// Decode the optional directory argument shared by check/infer/format/pack
// (default `src`). A leading `-…` token is an unknown option, not a directory,
// so a stray flag like `graded check --quiet` is rejected rather than taken as
// a directory named `--quiet`. Each of these commands takes at most one
// directory, so anything after it is rejected too. A command with flags of its
// own pulls them out first and passes on what is left (see
// `parse_infer_args`).
pub fn parse_directory_args(
  rest: List(String),
) -> Result(String, ArgumentError) {
  case rest {
    [] -> Ok("src")
    [directory] -> {
      use <- reject_option(directory)
      Ok(directory)
    }
    [directory, extra, ..] -> {
      use <- reject_option(directory)
      Error(UnexpectedArgument(extra))
    }
  }
}

// Whether `infer` writes its results or only previews them.
pub type InferMode {
  Write
  DryRun
}

// Decode the arguments of `graded infer [directory] [--dry-run]`. The directory
// follows the same default and rejection rules as `parse_directory_args`;
// `--dry-run` may sit anywhere after the command, since it says how the command
// runs rather than naming one of the positions.
pub fn parse_infer_args(
  rest: List(String),
) -> Result(#(String, InferMode), ArgumentError) {
  let #(mode, positional) = take_dry_run(rest)
  use directory <- result.map(parse_directory_args(positional))
  #(directory, mode)
}

// Pull `--dry-run` out of the argument list, leaving the positional arguments
// in order. Repeating the flag says nothing more than giving it once.
fn take_dry_run(arguments: List(String)) -> #(InferMode, List(String)) {
  let #(flags, positional) =
    list.partition(arguments, fn(argument) { argument == "--dry-run" })
  case flags {
    [] -> #(Write, positional)
    [_, ..] -> #(DryRun, positional)
  }
}

// Decode the arguments of `graded effect <name> [directory] [--format=…]`. The
// name is required; the directory follows the same default and rejection rules
// as `parse_directory_args`. `--format` may sit anywhere after the command,
// since it qualifies the output rather than naming one of the positions.
pub fn parse_effect_args(
  rest: List(String),
) -> Result(#(String, String, answer.Format), ArgumentError) {
  use #(format, positional) <- result.try(take_format(rest))
  use #(name, directory) <- result.map(parse_name_and_directory(
    "effect",
    positional,
  ))
  #(name, directory, format)
}

// Decode the arguments of `graded why <name> [directory]`. Same positions as
// `effect` without its output-format flag: the explanation is prose only.
pub fn parse_why_args(
  rest: List(String),
) -> Result(#(String, String), ArgumentError) {
  parse_name_and_directory("why", rest)
}

// What `graded catalog` was asked for: the whole bundled catalog, or one
// package's file — at the version the project installs, or at the version the
// argument named.
pub type CatalogRequest {
  ListCatalog
  ShowCatalog(package: String, version: Option(String), directory: String)
}

// Decode the arguments of `graded catalog [package[@version]] [directory]`. The
// package comes first, so a lone argument is always read as one and the listing
// cannot be pointed at another project; the directory that may follow it
// follows `parse_directory_args`' rules. `@` splits the package from the
// version at its first occurrence, so a version may carry one of its own; a
// half left empty on either side names no package.
pub fn parse_catalog_args(
  rest: List(String),
) -> Result(CatalogRequest, ArgumentError) {
  case rest {
    [] -> Ok(ListCatalog)
    [subject, ..directory_args] -> {
      use <- reject_option(subject)
      use #(package, version) <- result.try(split_package_version(subject))
      use directory <- result.map(parse_directory_args(directory_args))
      ShowCatalog(package:, version:, directory:)
    }
  }
}

// Split a `package` or `package@version` token. Neither half may be empty: a
// bare `@`, a trailing one, or a leading one names no package.
fn split_package_version(
  subject: String,
) -> Result(#(String, Option(String)), ArgumentError) {
  case string.split_once(subject, "@") {
    Ok(#("", _)) | Ok(#(_, "")) -> Error(InvalidPackage(subject))
    Ok(#(package, version)) -> Ok(#(package, Some(version)))
    Error(Nil) ->
      case subject {
        "" -> Error(InvalidPackage(subject))
        package -> Ok(#(package, None))
      }
  }
}

// The positions a name-taking command shares: a required name, then the
// optional directory `parse_directory_args` decodes. `command` names the one
// asking, so a missing name reports the command the user typed.
fn parse_name_and_directory(
  command: String,
  positional: List(String),
) -> Result(#(String, String), ArgumentError) {
  case positional {
    [] -> Error(MissingName(command))
    [name, ..directory_args] -> {
      use <- reject_option(name)
      use directory <- result.map(parse_directory_args(directory_args))
      #(name, directory)
    }
  }
}

// Pull `--format=<value>` out of the argument list, leaving the positional
// arguments in order. Prose is the default: the flagless invocation is the one
// a person types.
fn take_format(
  arguments: List(String),
) -> Result(#(answer.Format, List(String)), ArgumentError) {
  use #(format, reversed) <- result.map(
    list.fold(arguments, Ok(#(answer.Prose, [])), fn(acc, argument) {
      use #(format, positional) <- result.try(acc)
      case argument {
        "--format=" <> value ->
          case value {
            "prose" -> Ok(#(answer.Prose, positional))
            "graded" -> Ok(#(answer.Graded, positional))
            _ -> Error(UnknownFormat(value))
          }
        _ -> Ok(#(format, [argument, ..positional]))
      }
    }),
  )
  #(format, list.reverse(reversed))
}

// The message a rejected argument list prints.
pub fn format_argument_error(error: ArgumentError) -> String {
  case error {
    MissingName(command:) -> "missing name for `" <> command <> "`"
    UnknownOption(argument:) -> "unknown option `" <> argument <> "`"
    UnexpectedArgument(argument:) -> "unexpected argument `" <> argument <> "`"
    UnknownFormat(value:) ->
      "unknown format `" <> value <> "` (expected `prose` or `graded`)"
    InvalidPackage(argument:) ->
      "expected a package or package@version, got `" <> argument <> "`"
  }
}

// Reject `argument` as an unknown option when it looks like a flag, otherwise
// continue with `next`.
fn reject_option(
  argument: String,
  next: fn() -> Result(a, ArgumentError),
) -> Result(a, ArgumentError) {
  use <- bool.guard(
    when: string.starts_with(argument, "-"),
    return: Error(UnknownOption(argument)),
  )
  next()
}
