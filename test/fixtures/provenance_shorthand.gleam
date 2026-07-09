// Shorthand-punning smart constructor: `make` builds its record with field
// shorthand (`Options(resolver:)`), the idiomatic Gleam form a design-system
// smart constructor uses. The shorthand fn field resolves to the `resolver`
// parameter, so the `Build` provenance keeps it and `o.resolver` forwards onto
// the caller's `resolver`, discharging to [Stdout] — where an opaque shorthand
// field would collapse the whole build to [Unknown].

pub type Options {
  Options(label: String, resolver: fn() -> Nil)
}

pub fn inner(o: Options) -> Nil {
  o.resolver()
}

// Smart constructor built with field shorthand for the fn-typed field.
pub fn make(resolver: fn() -> Nil) -> Options {
  Options(label: "", resolver:)
}

pub fn caller(resolver: fn() -> Nil) -> Nil {
  inner(make(resolver))
}
