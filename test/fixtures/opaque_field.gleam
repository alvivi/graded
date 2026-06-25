pub type Runner {
  Runner(run: fn() -> Nil)
}

pub fn exec(r: Runner) -> Nil {
  // `r` arrives as a parameter — no construction site, no `type` line. `run` is
  // a `fn`-typed field, so the call becomes a *field-effect variable* (`r.run`)
  // instead of [Unknown]. The hand-written field bound on `exec`'s `check` line
  // in fixtures.graded discharges it to [Stdout], so the [] budget must fail.
  r.run()
}

pub fn exec_unbound(r: Runner) -> Nil {
  // Same opaque `fn`-typed field call, but with NO field bound. The synthetic
  // `r.run` variable can't be discharged, so it concretizes to [Unknown] — the
  // soundness floor — and the [] budget fails with [Unknown], not [].
  r.run()
}
