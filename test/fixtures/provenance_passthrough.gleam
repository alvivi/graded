// A helper that returns its whole parameter (`Passthrough`) forwards a computed
// receiver's field-effect variable onto the caller's own parameter, so
// `inner(id_options(Options(resolver: resolver)))` resolves `o.resolver` onto
// the caller's `resolver` instead of collapsing to [Unknown].

pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn inner(o: Options) -> Nil {
  o.resolver()
}

// Parameter passthrough: returns its whole parameter unchanged.
fn id_options(o: Options) -> Options {
  o
}

pub fn caller(resolver: fn() -> Nil) -> Nil {
  inner(id_options(Options(resolver: resolver)))
}
