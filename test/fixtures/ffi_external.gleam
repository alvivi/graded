// A bodyless `@external` is opaque FFI: graded cannot see what the native code
// does, so its effect is the conservative `[Unknown]`, not the `[]` an empty
// body would otherwise infer. The caller `run` inherits that `[Unknown]`.
@external(erlang, "some_ffi_module", "do_native_io")
pub fn ffi_op() -> Nil

pub fn run() -> Nil {
  ffi_op()
}
