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
  let l = make()
  l.emit("hi")
}
