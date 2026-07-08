// Labeled-argument grounding: the computed receiver is a helper called with a
// labeled argument (`rebuild(with: ...)`). Provenance positions index the
// parameter list, so grounding reorders the labeled call into parameter-position
// order via the callee's signature before substituting. The `Passthrough`
// forwards the constructed `Options` through, `o.resolver` re-keys onto the
// caller's `resolver`, and the bound discharges to [Stdout] instead of widening
// to [Unknown] on the labeled call site.

pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn inner(o: Options) -> Nil {
  o.resolver()
}

// A pass-through helper with a Gleam label (`with`) distinct from its in-body
// name (`o`), called out of positional order at the caller.
fn rebuild(with o: Options) -> Options {
  o
}

pub fn caller(resolver: fn() -> Nil) -> Nil {
  inner(rebuild(with: Options(resolver: resolver)))
}
