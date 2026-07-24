import gleam/io

pub type Logger {
  Logger(emit: fn(String) -> Nil)
}

fn make() -> Logger {
  Logger(emit: io.println)
}

pub fn run() {
  // The receiver is bound from a *call* (`make()`), so its construction isn't
  // proven at the field call — a let-bound call result is untraceable in Tier 1.
  // With no `type Logger.emit` line, the field call resolves to [Unknown] rather
  // than borrowing `make`'s in-package construction. Tier 2's call-result
  // provenance restores the precise [Stdout].
  let l = make()
  l.emit("hi")
}
