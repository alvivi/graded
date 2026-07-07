// Widen case: a helper whose return is a `case` branch is `Opaque`, so the
// computed receiver stays [Unknown] — value-level joins are Phase 2.

pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn inner(o: Options) -> Nil {
  o.resolver()
}

// Branch return: not a direct tail shape.
fn pick(flag: Bool, a: Options, b: Options) -> Options {
  case flag {
    True -> a
    False -> b
  }
}

pub fn caller(resolver: fn() -> Nil) -> Nil {
  inner(pick(True, Options(resolver: resolver), Options(resolver: resolver)))
}
