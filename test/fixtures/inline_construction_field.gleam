import gleam/io

pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}

pub fn run() {
  // The receiver is an *inline, un-let-bound* construction, so the field access
  // hangs off a `Call` rather than a `Variable`. That callee shape isn't a
  // construction site graded can trace, so the field call resolves to
  // [Unknown] — not [], which would be unsound here since `to_error` is wired
  // to the effectful io.println. The [] check budget must fail.
  Validator(to_error: io.println).to_error("oops")
}
