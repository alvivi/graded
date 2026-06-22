pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}

pub fn caller(v: Validator) -> Nil {
  // `v` arrives as a parameter, so there's no construction site to trace and no
  // `type` line for this module's Validator. The field call resolves only via
  // the hand-written field bound on `caller`'s `check` line in fixtures.graded.
  v.to_error("bad input")
}
