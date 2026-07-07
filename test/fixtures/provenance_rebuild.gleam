// A helper that rebuilds a record from a parameter-rooted field (`Build`).
// `inner(normalize(Options(resolver: resolver)))` forwards `o.resolver` onto the
// caller's `resolver` through the rebuilt constructor, so the bound discharges to
// [Stdout]. The rebuild's own `Options(resolver: o.resolver)` site registers a
// conservative [Unknown] source on `Options.resolver` (a receiver-path wiring),
// so the result carries both — the mixed-site shape of `factory_forward`.

pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn inner(o: Options) -> Nil {
  o.resolver()
}

// Constructor rebuild from a parameter-rooted field.
fn normalize(o: Options) -> Options {
  Options(resolver: o.resolver)
}

pub fn caller(resolver: fn() -> Nil) -> Nil {
  inner(normalize(Options(resolver: resolver)))
}
