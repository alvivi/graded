// A local that shadows a same-module function, wired into a record field, must
// NOT borrow that function's effect. The receiver's field is really the opaque
// value from `split`, so a call through it is [Unknown], never the shadowed
// `handler`'s pure [].

pub type Config {
  Config(run: fn() -> Nil)
}

// A top-level function with a known, pure effect.
pub fn handler() -> Nil {
  Nil
}

// An opaque producer: the functions it yields can't be traced.
@target(erlang)
@external(erlang, "some_ffi_module", "split")
fn split() -> #(fn() -> Nil, fn() -> Nil)

@target(erlang)
pub fn make() -> Config {
  // `handler` here is the destructured, opaque local — it shadows the top-level
  // `handler`. Wiring it into `run` must stay untraceable.
  let #(handler, _rest) = split()
  Config(run: handler)
}

@target(erlang)
pub fn go() -> Nil {
  let c = make()
  c.run()
}
