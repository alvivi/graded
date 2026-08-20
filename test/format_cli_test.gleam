import gleeunit/should
import graded
import graded/internal/annotation
import simplifile

// Format and format --check on the spec file
//
// `graded format --check` exists to fail CI on formatting drift. A spec file
// that doesn't even parse must be a hard error, not a silent pass — otherwise
// a real syntax error in the committed `.graded` slips through green.

const bad_spec = "@@@ not a valid graded line @@@\n"

// Run `body` with a fresh empty `dir`, cleaning up before and after.
fn with_temp_dir(dir: String, body: fn() -> a) -> a {
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let result = body()
  let _ = simplifile.delete(dir)
  result
}

pub fn format_check_fails_on_unparseable_spec_test() {
  let dir = "/tmp/graded_fmtcheck_bad"
  use <- with_temp_dir(dir)
  let assert Ok(Nil) =
    simplifile.write(dir <> "/graded_fmtcheck_bad.graded", bad_spec)
  graded.run_format_check(dir) |> should.be_error
}

pub fn format_check_tolerates_missing_spec_test() {
  let dir = "/tmp/graded_fmtcheck_missing"
  use <- with_temp_dir(dir)
  // No spec file present → nothing to check → Ok.
  graded.run_format_check(dir) |> should.equal(Ok(Nil))
}

pub fn format_fails_on_unparseable_spec_test() {
  let dir = "/tmp/graded_fmt_bad"
  use <- with_temp_dir(dir)
  let assert Ok(Nil) =
    simplifile.write(dir <> "/graded_fmt_bad.graded", bad_spec)
  graded.run_format(dir) |> should.be_error
}

// Format --stdin
//
// `graded format --stdin` reads a spec on standard input and prints the
// formatted result, for editor integration. `run_format_stdin` is the pure
// transform behind it: parse, sort, reformat.

pub fn format_stdin_sorts_and_normalizes_test() {
  graded.run_format_stdin("effects myapp.b:[Http]\ncheck  myapp.a : []")
  |> should.equal(Ok("check myapp.a : []\n\neffects myapp.b : [Http]\n"))
}

pub fn format_stdin_sorts_external_returns_before_returns_test() {
  graded.run_format_stdin("returns m.f : [Net]\nexternal returns m.g : [Net]")
  |> should.equal(Ok("external returns m.g : [Net]\n\nreturns m.f : [Net]\n"))
}

pub fn format_stdin_is_idempotent_over_external_returns_test() {
  let formatted = "external returns m.g : [Net]\n\nreturns m.f : [Net]\n"
  graded.run_format_stdin(formatted) |> should.equal(Ok(formatted))
}

// A spec still on a retired spelling is refused by name, with the rewrite —
// which is the migration instruction an editor shows.
pub fn format_stdin_reports_a_retired_spelling_test() {
  let error =
    graded.run_format_stdin("external effects m/ffi.send : [Http]")
    |> should.be_error
  annotation.describe_parse_error(error)
  |> should.equal(
    "1: external effects m/ffi.send : [Http]\n  `external effects <path> : <effects>` is retired; write `assume <path> : <effects>`",
  )
}

pub fn format_stdin_orders_assume_before_check_and_effects_test() {
  graded.run_format_stdin(
    "effects m.g : []\ncheck m.f : []\nassume m/ffi.send : [Http]",
  )
  |> should.equal(Ok(
    "assume m/ffi.send : [Http]\n\ncheck m.f : []\n\neffects m.g : []\n",
  ))
}

pub fn format_stdin_fails_on_unparseable_input_test() {
  graded.run_format_stdin(bad_spec) |> should.be_error
}

// An editor integration needs the line the input was rejected at, not just the
// fact that it was.
pub fn format_stdin_names_the_rejected_line_test() {
  graded.run_format_stdin("effects m.f : []\n" <> bad_spec)
  |> should.equal(
    Error(annotation.InvalidLine(2, "@@@ not a valid graded line @@@")),
  )
}
