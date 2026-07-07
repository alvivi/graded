// Widen case: a helper whose return is itself a call (`get(make(x))`) is
// `Opaque` — Phase 1 has no helper-call composition, so the computed receiver
// stays [Unknown].

pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn inner(o: Options) -> Nil {
  o.resolver()
}

fn make(resolver: fn() -> Nil) -> Options {
  Options(resolver: resolver)
}

fn get(o: Options) -> Options {
  o
}

// The helper's return is a nested call, so its provenance is `Opaque`.
fn deep(resolver: fn() -> Nil) -> Options {
  get(make(resolver))
}

pub fn caller(resolver: fn() -> Nil) -> Nil {
  inner(deep(resolver))
}
