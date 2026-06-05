import gleam/io

pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}

// A *factory*: it wires the constructor field to its own parameter. No
// hand-written `type` annotation is needed — graded records make's factory
// signature and binds the field at the call site below.
fn make(logger: fn(String) -> Nil) -> Validator {
  Validator(to_error: logger)
}

pub fn run() {
  // `v` is built by the factory `make(io.println)`, so `v.to_error` resolves to
  // io.println's effect [Stdout] via factory field provenance — the [] check
  // budget must fail.
  let v = make(io.println)
  v.to_error("oops")
}
