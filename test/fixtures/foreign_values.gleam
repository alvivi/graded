// Foreign code is opaque on every channel a value carries its effects through,
// not only on a direct call. An `@external`'s Gleam fallback body is a stand-in
// for the targets its declaration does not cover: on a covered target it never
// runs, and the foreign implementation may return something else entirely. So
// the operator such a function returns, the provenance of the record it builds,
// and the fields a factory or update builder of it wires are all [Unknown] —
// even where an `external effects` line declares what calling it costs, since
// nothing in that line describes the value it hands back.
//
// Every case below is paired with the same shape written as ordinary Gleam,
// whose budget passes: the rule refuses foreign values, not values.
//
// graded reads this file as text, so the `@target(erlang)` gate keeps the
// Erlang-only externals out of the JavaScript build.

pub type Handler {
  Handler(run: fn() -> Nil, name: String)
}

// Declared, so a *call* to it costs [Disk]. The wired callback below uses it to
// make an unresolved field call tell itself apart from a resolved one.
@target(erlang)
@external(erlang, "some_ffi_module", "disk_read")
pub fn disk_read() -> Nil

// The same, declared on both targets so it needs no gate: what the partially
// covered external below reaches, whose own body compiles for both.
@external(erlang, "some_ffi_module", "disk_read")
@external(javascript, "some_ffi_module", "disk_read")
pub fn portable_disk_read() -> Nil

// Fully covered on the target it compiles for: the closure below never runs.
@target(erlang)
@external(erlang, "some_ffi_module", "make_handler")
pub fn returns_operator() -> fn() -> Nil {
  fn() { disk_read() }
}

// Partially covered: it is compiled for both targets and declares javascript
// only, so on erlang this body *is* what runs. Its operator is still refused —
// the JavaScript implementation it stands in for is the one no declaration
// describes, and there is no declared operator to union a fallback-derived one
// with. Ungated, since partial coverage is what it is here for: gating it to
// erlang would leave the declaration covering no target it compiles for, which
// makes the body the sole implementation and the function ordinary Gleam.
@external(javascript, "some_ffi_module", "make_handler")
pub fn partial_returns_operator() -> fn() -> Nil {
  fn() { portable_disk_read() }
}

// A fallback body whose tail is a constructor call — a factory, were it native.
@target(erlang)
@external(erlang, "some_ffi_module", "build_handler")
pub fn builds(run: fn() -> Nil) -> Handler {
  Handler(run: run, name: "ffi")
}

// A fallback body whose tail is a record update — an update builder, were it
// native.
@target(erlang)
@external(erlang, "some_ffi_module", "with_run")
pub fn with_run(base: Handler, run: fn() -> Nil) -> Handler {
  Handler(..base, run: run)
}

// The ordinary twins of the three above.
pub fn native_returns_operator() -> fn() -> Nil {
  fn() { disk_read() }
}

pub fn native_builds(run: fn() -> Nil) -> Handler {
  Handler(run: run, name: "native")
}

pub fn native_with_run(base: Handler, run: fn() -> Nil) -> Handler {
  Handler(..base, run: run)
}

pub fn inner(handler: Handler) -> Nil {
  handler.run()
}

@target(erlang)
pub fn calls_returned_operator() -> Nil {
  let handle = returns_operator()
  handle()
}

pub fn calls_partial_operator() -> Nil {
  let handle = partial_returns_operator()
  handle()
}

@target(erlang)
pub fn calls_native_operator() -> Nil {
  let handle = native_returns_operator()
  handle()
}

@target(erlang)
pub fn calls_built_field() -> Nil {
  let handler = builds(fn() { disk_read() })
  handler.run()
}

@target(erlang)
pub fn calls_native_built_field() -> Nil {
  let handler = native_builds(fn() { disk_read() })
  handler.run()
}

@target(erlang)
pub fn calls_updated_field() -> Nil {
  let handler = with_run(native_builds(fn() { Nil }), fn() { disk_read() })
  handler.run()
}

@target(erlang)
pub fn calls_native_updated_field() -> Nil {
  let handler =
    native_with_run(native_builds(fn() { Nil }), fn() { disk_read() })
  handler.run()
}

// The provenance channel: the receiver is computed by the call, so `inner`
// resolves its field through the callee's return path rather than a binding.
@target(erlang)
pub fn calls_via_provenance() -> Nil {
  inner(builds(fn() { disk_read() }))
}

@target(erlang)
pub fn calls_native_via_provenance() -> Nil {
  inner(native_builds(fn() { disk_read() }))
}
