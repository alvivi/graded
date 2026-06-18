// An `@external` is opaque FFI: graded cannot see what the native code does, so
// its effect is the conservative `[Unknown]`, not `[]`. This holds whether or not
// the external carries a Gleam fallback body — the foreign implementation may
// differ from the fallback. The caller `run` inherits `[Unknown]` either way.
@external(erlang, "some_ffi_module", "do_native_io")
pub fn ffi_op() -> Nil

// `@external` WITH a pure-looking Gleam fallback body — still opaque.
@external(erlang, "some_ffi_module", "do_more")
pub fn ffi_with_body() -> Nil {
  Nil
}

pub fn run() -> Nil {
  ffi_op()
  ffi_with_body()
}
