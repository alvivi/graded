// Join case: a helper whose return is a `case` over parameter branches has a
// `Join` provenance, so the computed receiver forwards through every branch and
// the field effect resolves onto the caller's `resolver` rather than [Unknown].

pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn inner(o: Options) -> Nil {
  o.resolver()
}

// Branch return: each branch is a parameter, so the join forwards both.
fn pick(flag: Bool, a: Options, b: Options) -> Options {
  case flag {
    True -> a
    False -> b
  }
}

pub fn caller(resolver: fn() -> Nil) -> Nil {
  inner(pick(True, Options(resolver: resolver), Options(resolver: resolver)))
}
