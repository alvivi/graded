// Widen case: a receiver computed by an external function has no visible body,
// so its provenance can't be traced and it stays [Unknown].

pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn inner(o: Options) -> Nil {
  o.resolver()
}

@external(erlang, "provenance_ffi", "load_options")
fn load_options(resolver: fn() -> Nil) -> Options

pub fn caller(resolver: fn() -> Nil) -> Nil {
  inner(load_options(resolver))
}
