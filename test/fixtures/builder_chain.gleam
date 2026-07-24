// Chained builders and overlays over an untraceable base. Each `with_*` builder
// replaces one field of its options parameter; the overlays compose, an updated
// field is read field-selectively (last-write-wins, never grounding the base),
// and an inherited field over an opaque base stays [Unknown].
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
