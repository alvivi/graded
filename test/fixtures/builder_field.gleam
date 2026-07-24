// A builder function (`with_resolver`) is a record update of its options
// parameter, replacing one field. graded resolves a field call reached through
// the builder result to the *builder-set* value's effect (last-write-wins), not
// the default the constructor wired — and unions it with the construction's own
// effect at the caller. A field with no override inherits the default.
import gleam/io

pub type Options {
  Options(resolver: fn(String) -> Nil, target: String)
}

// The default resolver reads disk (a distinct effect from the logging one), so a
// builder override is observably replace-not-union.
@target(erlang)
@external(erlang, "some_ffi_module", "read")
fn read_disk(path: String) -> Nil

@target(erlang)
fn default_resolver(path: String) -> Nil {
  read_disk(path)
}

fn logging_resolver(message: String) -> Nil {
  io.println(message)
}

pub fn default_options() -> Options {
  Options(resolver: default_resolver, target: "erlang")
}

pub fn with_resolver(options: Options, resolver: fn(String) -> Nil) -> Options {
  Options(..options, resolver:)
}

pub fn annotate(source: String, options: Options) -> Nil {
  options.resolver(source)
}

// The builder overrides the resolver: [Stdout] wins, the default [Disk] is gone.
pub fn run_replaced() -> Nil {
  let opts = default_options() |> with_resolver(logging_resolver)
  annotate("x", opts)
}

// No override: the default resolver's [Disk] shows through.
pub fn run_default() -> Nil {
  annotate("x", default_options())
}

// The builder call inline as the argument, not let-bound: resolves the same.
pub fn run_inline_arg() -> Nil {
  annotate("x", with_resolver(default_options(), logging_resolver))
}

// Whole-caller union: a construction-side effect ([Disk]) alongside the
// overridden field call's [Stdout] — a real, separate effect, not the field's.
@target(erlang)
pub fn run_union() -> Nil {
  read_disk("init")
  let opts = default_options() |> with_resolver(logging_resolver)
  annotate("x", opts)
}
