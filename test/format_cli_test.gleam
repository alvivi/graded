import gleeunit/should
import graded
import simplifile

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
