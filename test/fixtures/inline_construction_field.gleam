import gleam/io

pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}

pub fn run() {
  // The receiver is an *inline, un-let-bound* construction. The field call is
  // resolved through the receiver's type and construction provenance: `to_error`
  // is wired to io.println right here, so the call carries [Stdout] — the precise
  // effect, not the conservative [Unknown] of an untraceable receiver, and never
  // an unsound []. The [] check budget must fail.
  Validator(to_error: io.println).to_error("oops")
}
