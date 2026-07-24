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
  // The receiver is bound from a call (`make()`). Tier 2 grounds `make`'s return
  // construction per receiver, resolving the wired same-module function to the
  // precise [Stdout] — proven for this receiver, not borrowed from the nominal
  // index.
  let l = make()
  l.emit("hi")
}
