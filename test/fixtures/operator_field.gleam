import gleam/io

pub type Middleware {
  Middleware(wrap: fn(fn(String) -> Nil) -> Nil)
}

fn make() -> Middleware {
  // The field is *operator-typed*: the closure calls its own callback `next`.
  // graded lifts it to `λnext. [next]`, so a field call resolves to whatever
  // callback is supplied.
  Middleware(wrap: fn(next) { next("x") })
}

pub fn run() {
  let m = make()
  m.wrap(io.println)
}
