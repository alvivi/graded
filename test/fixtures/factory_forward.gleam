// A factory/constructor value passed inline as a receiver argument forwards the
// callee's field-effect variable onto the caller parameter the field is wired
// to. None of these need a `type` line: the callers infer a polymorphic bound
// on `resolver`, so a `check caller(resolver: [Stdout]) : []` fails with
// [Stdout]; an aliased receiver stays conservative ([Unknown]).

pub type Options {
  Options(resolver: fn() -> Nil)
}

// A factory declared with a label, so both positional and labeled calls route.
pub fn make_options(resolver resolver: fn() -> Nil) -> Options {
  Options(resolver: resolver)
}

pub fn inner(options: Options) -> Nil {
  options.resolver()
}

// Factory call wiring: `make_options(resolver)` forwards `o.resolver` to the
// caller's `resolver` parameter.
pub fn caller(resolver: fn() -> Nil) -> Nil {
  inner(make_options(resolver))
}

// Inline constructor wiring: `Options(resolver: resolver)`.
pub fn caller_ctor(resolver: fn() -> Nil) -> Nil {
  inner(Options(resolver: resolver))
}

// Labeled factory wiring: `make_options(resolver: resolver)`.
pub fn caller_labeled(resolver: fn() -> Nil) -> Nil {
  inner(make_options(resolver: resolver))
}

// Shorthand labeled wiring: `make_options(resolver:)`, sugar for
// `make_options(resolver: resolver)`, so it forwards the same way.
pub fn caller_shorthand(resolver: fn() -> Nil) -> Nil {
  inner(make_options(resolver:))
}

// Negative: an aliased factory result is not forwarded, so it stays [Unknown].
pub fn caller_alias(resolver: fn() -> Nil) -> Nil {
  let w = make_options(resolver)
  inner(w)
}

fn get_options(options: Options) -> Options {
  options
}

// Negative: a computed receiver (the factory result threaded through a call) is
// not a traceable path, so forwarding doesn't apply and it stays [Unknown].
pub fn caller_computed(resolver: fn() -> Nil) -> Nil {
  inner(get_options(make_options(resolver)))
}

// Mixed-site forwarding: the same `Runner.run` field is built two ways — a
// factory wiring a bare parameter (the forwarding marker) and a site wiring an
// effect-polymorphic module function (a source). The marker must still forward
// through the factory; the sibling source must not reground it to [Unknown].

pub type Runner {
  Runner(run: fn(fn() -> Nil) -> Nil)
}

// Effect-polymorphic module function: its effect is its callback's.
fn relay(task: fn() -> Nil) -> Nil {
  task()
}

// Source site: wires the polymorphic `relay` into `Runner.run`.
pub fn relay_runner() -> Runner {
  Runner(run: relay)
}

// Factory site: wires a bare parameter into `Runner.run`.
pub fn make_runner(run: fn(fn() -> Nil) -> Nil) -> Runner {
  Runner(run: run)
}

fn noop() -> Nil {
  Nil
}

fn run_inner(r: Runner) -> Nil {
  r.run(noop)
}

// Forwards through the factory: `run` forwards onto the caller's own `run`
// parameter despite the sibling `relay` source on `Runner.run`.
pub fn mixed_caller(run: fn(fn() -> Nil) -> Nil) -> Nil {
  run_inner(make_runner(run))
}
