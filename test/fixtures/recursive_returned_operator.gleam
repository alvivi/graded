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
