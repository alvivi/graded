import gleam/io

// A foreign producer whose callbacks' labels are each other's in-body names,
// under `assume labeled_declared.labelled(cb: [cb]) : [] where returns : [cb]`
// (see fixtures.graded). The clause's `cb` is the parameter *named* `cb` — the
// one labelled `first` — so the returned operator charges what `first:` is
// handed, whatever order the labels are written in.
//
// The `@target(erlang)` gate keeps the module out of the JavaScript build, where
// the bodyless external has no implementation.

@target(erlang)
@external(erlang, "some_ffi_module", "decorate")
pub fn labelled(first cb: fn() -> Nil, cb other: fn() -> Nil) -> fn() -> Nil

@target(erlang)
fn loud() -> Nil {
  io.println("loud")
}

@target(erlang)
fn quiet() -> Nil {
  Nil
}

@target(erlang)
pub fn run_named() -> Nil {
  labelled(first: loud, cb: quiet)()
}

@target(erlang)
pub fn run_reversed() -> Nil {
  labelled(first: quiet, cb: loud)()
}

@target(erlang)
pub fn run_reordered() -> Nil {
  labelled(cb: quiet, first: loud)()
}
