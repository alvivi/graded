import gleam/io

// A foreign producer that runs its callback with a `[Db]` callback of its own,
// declared as `assume assume_second_order.with_tx(cb: [cb]) : [cb([Db])]` (see
// fixtures.graded). Each consumer is charged what its callback does with the
// callback it is handed: `quiet3` only runs it, `loud3` prints first.
//
// The `@target(erlang)` gate keeps the module out of the JavaScript build, where
// the bodyless external has no implementation.

@target(erlang)
@external(erlang, "some_ffi_module", "with_tx")
pub fn with_tx(cb: fn(fn() -> Nil) -> Nil) -> Nil

@target(erlang)
pub fn quiet3() -> Nil {
  with_tx(fn(run) { run() })
}

@target(erlang)
pub fn loud3() -> Nil {
  with_tx(fn(run) {
    io.println("loud")
    run()
  })
}
