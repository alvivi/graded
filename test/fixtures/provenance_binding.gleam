// Binding survival: the helper threads its parameter through a `let` alias
// before returning it, so the provenance walk must fold through the binding to
// reach the parameter. The `let`-aliased passthrough forwards the constructed
// `Options` through, `o.resolver` re-keys onto the caller's `resolver`, and the
// bound discharges to [Stdout] rather than widening at the binding.

pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn inner(o: Options) -> Nil {
  o.resolver()
}

fn alias(o: Options) -> Options {
  let aliased = o
  aliased
}

pub fn caller(resolver: fn() -> Nil) -> Nil {
  inner(alias(Options(resolver: resolver)))
}
