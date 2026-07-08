// Partial-build case: a helper rebuilds a record keeping a literal default field
// (`label`) alongside a parameter-rooted fn field (`resolver`). The `Build`
// provenance keeps `resolver` and drops the literal, so `o.resolver` forwards
// onto the caller's `resolver` and the bound discharges to [Stdout] rather than
// collapsing the whole build to [Unknown].

pub type Options {
  Options(label: String, resolver: fn() -> Nil)
}

pub fn inner(o: Options) -> Nil {
  o.resolver()
}

// Rebuild with a literal default alongside the parameter-rooted fn field.
fn normalize(o: Options) -> Options {
  Options(label: "", resolver: o.resolver)
}

pub fn caller(resolver: fn() -> Nil) -> Nil {
  inner(normalize(Options(label: "", resolver: resolver)))
}
