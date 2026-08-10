import gleam/bool
import gleam/list
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
  // The `effect` command's required name was not given.
  MissingName
  // A token that looks like a flag where a name or directory was expected.
  UnknownOption(argument: String)
  // A token past the last one the command accepts.
  UnexpectedArgument(argument: String)
  // `--format=` given a value that names no output format.
  UnknownFormat(value: String)
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
  let #(mode, reversed) =
    list.fold(arguments, #(Write, []), fn(acc, argument) {
      let #(mode, positional) = acc
      case argument {
        "--dry-run" -> #(DryRun, positional)
        _ -> #(mode, [argument, ..positional])
      }
    })
  #(mode, list.reverse(reversed))
}

// Decode the arguments of `graded effect <name> [directory] [--format=…]`. The
// name is required; the directory follows the same default and rejection rules
// as `parse_directory_args`. `--format` may sit anywhere after the command,
// since it qualifies the output rather than naming one of the positions.
pub fn parse_effect_args(
  rest: List(String),
) -> Result(#(String, String, answer.Format), ArgumentError) {
  use #(format, positional) <- result.try(take_format(rest))
  case positional {
    [] -> Error(MissingName)
    [name, ..directory_args] -> {
      use <- reject_option(name)
      use directory <- result.map(parse_directory_args(directory_args))
      #(name, directory, format)
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
    MissingName -> "missing name for `effect`"
    UnknownOption(argument:) -> "unknown option `" <> argument <> "`"
    UnexpectedArgument(argument:) -> "unexpected argument `" <> argument <> "`"
    UnknownFormat(value:) ->
      "unknown format `" <> value <> "` (expected `prose` or `graded`)"
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
