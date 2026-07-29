// Chained builders and overlays. Each `with_*` builder replaces one field of its
// options parameter; the overlays compose, an updated field is read
// field-selectively (last-write-wins, never grounding the base), an inherited
// field over a traceable base grounds through the producer's wiring, and an
// inherited field over an opaque base stays [Unknown].
import gleam/io

pub type Options {
  Options(resolver: fn(String) -> Nil, reporter: fn(String) -> Nil)
}

@target(erlang)
@external(erlang, "some_ffi_module", "read")
fn disk_read(path: String) -> Nil

@target(erlang)
fn disk_resolver(path: String) -> Nil {
  disk_read(path)
}

fn logging_resolver(message: String) -> Nil {
  io.println(message)
}

fn silent_reporter(_message: String) -> Nil {
  Nil
}

// An untraceable producer: its tail is a call, so its return provenance is
// opaque and its fields can't be grounded.
@target(erlang)
pub fn opaque_options() -> Options {
  passthrough(Options(resolver: disk_resolver, reporter: silent_reporter))
}

fn passthrough(options: Options) -> Options {
  options
}

// A traceable producer: its tail is the construction itself, so its return
// provenance grounds and an inherited field can be read through an overlay.
@target(erlang)
pub fn traceable_options() -> Options {
  Options(resolver: disk_resolver, reporter: silent_reporter)
}

pub fn with_resolver(options: Options, resolver: fn(String) -> Nil) -> Options {
  Options(..options, resolver:)
}

pub fn with_reporter(options: Options, reporter: fn(String) -> Nil) -> Options {
  Options(..options, reporter:)
}

pub fn annotate(source: String, options: Options) -> Nil {
  options.resolver(source)
}

pub fn report(source: String, options: Options) -> Nil {
  options.reporter(source)
}

// A later update (reporter) preserves the resolver set by an earlier one.
@target(erlang)
pub fn run_chained() -> Nil {
  let opts =
    opaque_options()
    |> with_resolver(logging_resolver)
    |> with_reporter(silent_reporter)
  annotate("x", opts)
}

// Two resolver updates: the second wins.
@target(erlang)
pub fn run_last_wins() -> Nil {
  let opts =
    opaque_options()
    |> with_resolver(disk_resolver)
    |> with_resolver(logging_resolver)
  annotate("x", opts)
}

// A builder over an untraceable producer: the updated field still resolves
// precisely (the base never grounds).
@target(erlang)
pub fn run_opaque_base() -> Nil {
  let opts = with_resolver(opaque_options(), logging_resolver)
  annotate("x", opts)
}

// An inline record update over an opaque base: the updated resolver resolves
// precisely...
@target(erlang)
pub fn run_inline_updated() -> Nil {
  let x = Options(..opaque_options(), resolver: logging_resolver)
  annotate("x", x)
}

// ...but the inherited reporter (not updated) over the opaque base stays
// [Unknown].
@target(erlang)
pub fn run_inline_inherited() -> Nil {
  let x = Options(..opaque_options(), resolver: logging_resolver)
  report("x", x)
}

// A producer that returns a resolver closure with a latent [Stdout].
fn make_logging() -> fn(String) -> Nil {
  fn(message) { io.println(message) }
}

// A builder-set field whose replacement is a *call result* resolves precisely
// on a direct read: the per-value resolver applies the returned closure to the
// field call's argument and reports [Stdout], not [Unknown].
@target(erlang)
pub fn run_call_result_direct() -> Nil {
  let x = Options(..opaque_options(), resolver: make_logging())
  x.resolver("hi")
}

// The same call-result replacement forwarded through `annotate`: the forwarding
// site grounds the resolver's operator (its body ignores the argument) to
// [Stdout], rather than falling back to [Unknown].
@target(erlang)
pub fn run_call_result_forwarded() -> Nil {
  let x = Options(..opaque_options(), resolver: make_logging())
  annotate("hi", x)
}

// An inline closure builder replacement forwarded through `annotate`: the
// per-value resolver reports the first-order closure body's [Stdout], not
// [Unknown].
@target(erlang)
pub fn run_closure_forwarded() -> Nil {
  let opts =
    with_resolver(opaque_options(), fn(message) { io.println(message) })
  annotate("x", opts)
}

// An inherited (not updated) field over a TRACEABLE base grounds through the
// producer's wiring: the overlay replaces `reporter`, so reading `resolver`
// falls through to `traceable_options`'s [Disk] rather than [Unknown].
@target(erlang)
pub fn run_traceable_inherited() -> Nil {
  let opts = traceable_options() |> with_reporter(silent_reporter)
  annotate("x", opts)
}

// The same inherited field read directly off the overlay.
@target(erlang)
pub fn run_traceable_inherited_direct() -> Nil {
  let opts = traceable_options() |> with_reporter(silent_reporter)
  opts.resolver("x")
}

// Chained overlays over a traceable base: the inherited field still grounds
// through both layers.
@target(erlang)
pub fn run_traceable_inherited_chained() -> Nil {
  let opts =
    traceable_options()
    |> with_reporter(silent_reporter)
    |> with_reporter(logging_resolver)
  opts.resolver("x")
}
