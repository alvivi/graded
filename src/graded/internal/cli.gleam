import gleam/bool
import gleam/result
import gleam/string

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
}

// Decode the optional directory argument shared by check/infer/format/pack
// (default `src`). A leading `-…` token is an unknown option, not a directory,
// so a stray flag like `graded infer --dry-run` is rejected rather than taken
// as a directory named `--dry-run`. Each of these commands takes at most one
// directory, so anything after it is rejected too.
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

// Decode the arguments of `graded effect <name> [directory]`. The name is
// required; the directory follows the same default and rejection rules as
// `parse_directory_args`.
pub fn parse_effect_args(
  rest: List(String),
) -> Result(#(String, String), ArgumentError) {
  case rest {
    [] -> Error(MissingName)
    [name, ..directory_args] -> {
      use <- reject_option(name)
      use directory <- result.map(parse_directory_args(directory_args))
      #(name, directory)
    }
  }
}

// The message a rejected argument list prints.
pub fn format_argument_error(error: ArgumentError) -> String {
  case error {
    MissingName -> "missing name for `effect`"
    UnknownOption(argument:) -> "unknown option `" <> argument <> "`"
    UnexpectedArgument(argument:) -> "unexpected argument `" <> argument <> "`"
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
