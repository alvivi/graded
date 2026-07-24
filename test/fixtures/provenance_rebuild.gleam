// A helper that rebuilds a record from a parameter-rooted field (`Build`).
// `inner(normalize(Options(resolver: resolver)))` forwards `o.resolver` onto the
// caller's `resolver` through the rebuilt constructor, so the bound discharges to
// [Stdout]. `inner`'s receiver is a parameter, so the field call stays polymorphic
// and never consults the nominal index — the rebuild's own receiver-path wiring on
// a *different* site no longer leaks a conservative [Unknown], so `caller` is the
// precise [Stdout].

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
