// A same-module call into a bodyless `@external` that carries an
// `external effects` declaration inherits the DECLARED effects, not the
// conservative `[Unknown]` an undeclared external yields. This is the common
// FFI idiom: an `@external` binding paired with a same-module wrapper.
//
// graded reads this file as text, so the Erlang-only external exercises the
// path on either compilation target. The `@target(erlang)` gate keeps the
// bodyless external out of the JavaScript build.
@target(erlang)
@external(erlang, "some_ffi_module", "now")
pub fn now() -> Int

@target(erlang)
pub fn read_clock() -> Int {
  now()
}
