import gleeunit/should
import graded
import simplifile

// `graded format --check` exists to fail CI on formatting drift. A spec file
// that doesn't even parse must be a hard error, not a silent pass — otherwise
// a real syntax error in the committed `.graded` slips through green.

pub fn format_check_fails_on_unparseable_spec_test() {
  let dir = "/tmp/graded_fmtcheck_bad"
  let spec = dir <> "/graded_fmtcheck_bad.graded"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) =
    simplifile.write(spec, "@@@ not a valid graded line @@@\n")
  let outcome = graded.run_format_check(dir)
  let _ = simplifile.delete(dir)
  should.be_error(outcome)
}

pub fn format_check_tolerates_missing_spec_test() {
  let dir = "/tmp/graded_fmtcheck_missing"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  // No spec file present → nothing to check → Ok.
  let outcome = graded.run_format_check(dir)
  let _ = simplifile.delete(dir)
  outcome |> should.equal(Ok(Nil))
}

pub fn format_fails_on_unparseable_spec_test() {
  let dir = "/tmp/graded_fmt_bad"
  let spec = dir <> "/graded_fmt_bad.graded"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) =
    simplifile.write(spec, "@@@ not a valid graded line @@@\n")
  let outcome = graded.run_format(dir)
  let _ = simplifile.delete(dir)
  should.be_error(outcome)
}
