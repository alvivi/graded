import gleam/io

pub fn my_logger(message: String) -> Nil {
  io.println(message)
}

pub type Logger {
  Logger(emit: fn(String) -> Nil)
}

fn make() -> Logger {
  // The field is wired to a *same-module* function (a bare LocalRef). graded
  // qualifies it by this module and resolves its inferred effects.
  Logger(emit: my_logger)
}

pub fn run() {
  // The receiver is bound from a call (`make()`), untraceable in Tier 1, and no
  // `type Logger.emit` line exists — so the field call resolves to [Unknown]
  // rather than borrowing `make`'s in-package construction. Tier 2's call-result
  // provenance restores the precise [Stdout].
  let l = make()
  l.emit("hi")
}
