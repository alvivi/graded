// A function discarding a callback parameter, passed where a callback is
// called with callbacks of its own. Each argument reaches the parameter at its
// own position, named or not. `out` and `db` are declared in fixtures.graded.
//
// The `@target(erlang)` gate keeps the module out of the JavaScript build, where
// the bodyless externals have no implementation.

@target(erlang)
@external(erlang, "some_ffi_module", "out")
pub fn out() -> Nil

@target(erlang)
@external(erlang, "some_ffi_module", "db")
pub fn db() -> Nil

@target(erlang)
pub fn run_with(action: fn(fn() -> Nil) -> Nil) -> Nil {
  action(fn() { Nil })
}

// Takes both callbacks as its own parameters, so it charges nothing itself.
@target(erlang)
pub fn run_pair(
  action: fn(fn() -> Nil, fn() -> Nil) -> Nil,
  first: fn() -> Nil,
  second: fn() -> Nil,
) -> Nil {
  action(first, second)
}

@target(erlang)
pub fn ignores(_f: fn() -> Nil) -> Nil {
  Nil
}

@target(erlang)
pub fn pick(_a: fn() -> Nil, b: fn() -> Nil) -> Nil {
  b()
}

@target(erlang)
pub fn pick_first(a: fn() -> Nil, _b: fn() -> Nil) -> Nil {
  a()
}

@target(erlang)
pub fn both(a: fn() -> Nil, b: fn() -> Nil) -> Nil {
  a()
  b()
}

@target(erlang)
pub fn go_ignores() -> Nil {
  run_with(ignores)
}

@target(erlang)
pub fn go_pick() -> Nil {
  run_pair(pick, out, db)
}

@target(erlang)
pub fn go_pick_swapped() -> Nil {
  run_pair(pick, db, out)
}

@target(erlang)
pub fn go_pick_first() -> Nil {
  run_pair(pick_first, out, db)
}

@target(erlang)
pub fn go_pick_first_swapped() -> Nil {
  run_pair(pick_first, db, out)
}

@target(erlang)
pub fn go_both() -> Nil {
  run_pair(both, out, db)
}

@target(erlang)
pub fn go_pick_poly(x: fn() -> Nil, y: fn() -> Nil) -> Nil {
  run_pair(pick, x, y)
}
