// A same-module recursive producer: one branch returns a literal closure, the
// other returns a recursive producer call (`pick(n - 1)`). Resolving the
// operator it returns must treat the recursive branch as neutral — the producer
// is already on the analysis stack — rather than collapsing the applied result
// to [Unknown]. `run` applies the returned operator, so it must stay pure.
pub fn pick(n: Int) -> fn() -> Nil {
  case n {
    0 -> fn() { Nil }
    _ -> pick(n - 1)
  }
}

pub fn run() -> Nil {
  let action = pick(1)
  action()
}

// Second-order variant: the producer returns a callback-taking function
// (`fn(fn() -> Nil) -> Nil`), so the neutral operator the recursive branch
// contributes carries a binder — pure over the callback position — rather than
// a ground pure. Applying it to a pure callback stays pure.
pub fn pick_cb(n: Int) -> fn(fn() -> Nil) -> Nil {
  case n {
    0 -> fn(cb) { cb() }
    _ -> pick_cb(n - 1)
  }
}

pub fn run_cb() -> Nil {
  let action = pick_cb(1)
  action(fn() { Nil })
}
