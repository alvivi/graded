// Shadowing must not let a builder overlay borrow the wrong value. A builder
// that rebinds its parameter, a local that shadows a builder's name, and a
// parameter that collides with a module function name each previously let a
// field call resolve to a value the record does not actually store — an
// under-report. Each now resolves soundly (untraceable, or the parameter).
@target(erlang)
@external(erlang, "some_ffi_module", "read")
fn disk_read(path: String) -> Nil

pub type Options {
  Options(resolver: fn(String) -> Nil, target: String)
}

@target(erlang)
fn disk_resolver(path: String) -> Nil {
  disk_read(path)
}

fn silent(_message: String) -> Nil {
  Nil
}

fn wrap(options: Options) -> Options {
  options
}

// An untraceable producer, so the base of every overlay below can't ground.
@target(erlang)
fn opaque_options() -> Options {
  wrap(Options(resolver: disk_resolver, target: "erlang"))
}

pub fn with_resolver(options: Options, resolver: fn(String) -> Nil) -> Options {
  Options(..options, resolver:)
}

pub fn annotate(source: String, options: Options) -> Nil {
  options.resolver(source)
}

// P1: the builder rebinds `resolver` before the update, so it always stores
// disk_resolver and ignores its argument — it is not a builder that stores the
// caller's value. Passing a pure resolver must not model the field as pure.
@target(erlang)
pub fn with_shadowed_param(
  options: Options,
  resolver: fn(String) -> Nil,
) -> Options {
  let resolver = case resolver {
    _ -> disk_resolver
  }
  Options(..options, resolver:)
}

@target(erlang)
pub fn run_shadowed_param() -> Nil {
  let opts = opaque_options() |> with_shadowed_param(silent)
  annotate("x", opts)
}

// P1: a local closure shadows the top-level builder `with_resolver` and ignores
// its argument. The top-level builder's signature must not be applied.
@target(erlang)
pub fn run_shadowed_name() -> Nil {
  let with_resolver = fn(o: Options, _r: fn(String) -> Nil) {
    Options(..o, resolver: disk_resolver)
  }
  let opts = with_resolver(opaque_options(), silent)
  annotate("x", opts)
}

// P1: a module function `handler` (pure) collides with a fn-typed parameter of
// the same name. The field wired to the parameter is the parameter, not the
// function — so calling it resolves to the parameter's effect, not the
// function's [].
pub fn handler(_message: String) -> Nil {
  Nil
}

@target(erlang)
pub fn run_param_collision(handler: fn(String) -> Nil) -> Nil {
  let opts = Options(..opaque_options(), resolver: handler)
  annotate("x", opts)
}

// P1: the same collision one lexical scope deeper — a *closure* parameter named
// after the pure module function `handler`. The field is wired to neither the
// function nor an enclosing parameter, so it stays [Unknown]; the closure is
// applied with the [Disk] resolver, which the module function's [] would hide.
@target(erlang)
pub fn run_closure_param_collision() -> Nil {
  let build = fn(handler: fn(String) -> Nil) {
    let opts = Options(..opaque_options(), resolver: handler)
    opts.resolver("x")
  }
  build(disk_resolver)
}

// P1: the closure-parameter collision read through a forwarding callee rather
// than directly — `annotate` re-keys its own field call onto the overlay.
@target(erlang)
pub fn run_closure_param_collision_forwarded() -> Nil {
  let build = fn(handler: fn(String) -> Nil) {
    let opts = Options(..opaque_options(), resolver: handler)
    annotate("x", opts)
  }
  build(disk_resolver)
}
