// Join case whose branches rebuild a record from a parameter-rooted field, not a
// bare parameter. A helper whose return is a `case` over
// `Options(resolver: a.resolver)`/`Options(resolver: b.resolver)` has a `Join` of
// two `Build`s, so the computed receiver forwards `o.resolver` onto the caller's
// `resolver` through both branches. Each rebuild's receiver-path wiring registers
// a conservative [Unknown] source on the field, so the result carries both — the
// mixed-site shape of `provenance_rebuild`, now reached through a `case`.

pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn inner(o: Options) -> Nil {
  o.resolver()
}

// Branch return: each branch rebuilds the record from a parameter-rooted field.
fn pick(flag: Bool, a: Options, b: Options) -> Options {
  case flag {
    True -> Options(resolver: a.resolver)
    False -> Options(resolver: b.resolver)
  }
}

pub fn caller(resolver: fn() -> Nil) -> Nil {
  inner(pick(True, Options(resolver: resolver), Options(resolver: resolver)))
}
