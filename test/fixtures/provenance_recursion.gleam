// Recursion fixpoint: `pick` returns its `o` parameter through a tail-recursive
// call, so a naive walk (a return that is itself a call is opaque) would lose the
// passthrough. The fixpoint grounds the recursive branch through `pick`'s own
// estimate — both the base branch and the grounded recursive branch pass `o`
// through position 1 — converging to a `Passthrough`. The computed receiver
// `inner(pick(True, Options(resolver: resolver)))` then forwards `o.resolver`
// onto the caller's `resolver`, discharging the bound to [Stdout] rather than
// widening on the recursion.

pub type Options {
  Options(resolver: fn() -> Nil)
}

pub fn inner(o: Options) -> Nil {
  o.resolver()
}

fn pick(stop: Bool, o: Options) -> Options {
  case stop {
    True -> o
    False -> pick(True, o)
  }
}

pub fn caller(resolver: fn() -> Nil) -> Nil {
  inner(pick(True, Options(resolver: resolver)))
}
