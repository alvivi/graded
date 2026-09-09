// Tests for `graded/internal/compat` — the versions graded was verified on and
// how an observed version stands to them. The standing is the whole of the
// module's behaviour: everything else there is data the release test pins.

import gleeunit/should
import graded/internal/compat

pub fn an_observed_version_on_the_list_is_verified_test() {
  compat.standing(Ok("1.18.0"), ["1.16.0", "1.18.0"])
  |> should.equal(compat.Verified)
}

pub fn an_observed_version_off_the_list_names_every_verified_one_test() {
  // The notice a user reads is the whole list, not "unverified": a compiler
  // outside the range is stated beside what the range is.
  compat.standing(Ok("1.19.0"), ["1.16.0", "1.18.0"])
  |> should.equal(compat.Unverified("1.19.0", ["1.16.0", "1.18.0"]))
}

pub fn a_version_that_could_not_be_read_is_unobserved_test() {
  // Not a failure: on JavaScript no application metadata exists, and `gleam`
  // may not be on the path.
  compat.standing(Error(Nil), ["1.18.0"]) |> should.equal(compat.Unobserved)
}

pub fn nothing_is_verified_against_an_empty_list_test() {
  compat.standing(Ok("1.18.0"), [])
  |> should.equal(compat.Unverified("1.18.0", []))
}
