import gleam/io

// Shapes `graded why` explains. A resolved same-module call is replaced by the
// callee's own call sites, so what these functions contribute is decided inside
// their helpers.

// The helper performs nothing, so the caller collects no contributors at all —
// even though it plainly makes a call.
pub fn calls_pure_helper(item: String) -> String {
  pure_helper(item)
}

fn pure_helper(item: String) -> String {
  item
}

// One helper called twice: the helper's own site is collected once per call,
// identically both times.
pub fn calls_helper_twice() -> Nil {
  noisy_helper("first")
  noisy_helper("second")
}

fn noisy_helper(message: String) -> Nil {
  io.println(message)
}

// The same shape under a `check` line (see fixtures.graded): the helper's site
// is collected once per call, so the budget it blows is reported once — the one
// line `why` prints for it.
pub fn checked_calls_helper_twice() -> Nil {
  noisy_helper("first")
  noisy_helper("second")
}

// One helper site, two substitutions: the callback each call passes decides what
// that site contributes, so the same position reports two different effects.
pub fn passes_two_callbacks() -> Nil {
  run(fn() { io.println("noise") })
  run(fn() { Nil })
}

fn run(action: fn() -> Nil) -> Nil {
  action()
}

// Two `check` lines bind one parameter each (see fixtures.graded), so they share
// a budget and differ only in which call they resolve.
pub fn two_bounds(f: fn() -> Nil, g: fn() -> Nil) -> Nil {
  f()
  g()
}
