import gleam/io

pub type Middleware {
  Middleware(wrap: fn(fn(String) -> Nil) -> Nil)
}

pub fn run() {
  // The receiver is a let-bound *inline construction*, so `wrap`'s value is proven
  // for this receiver. The field is *operator-typed*: the closure calls its own
  // callback `next`, lifted to `λnext. [next]`, so the field call `m.wrap(io.println)`
  // applies it to the supplied callback and resolves to [Stdout].
  let m = Middleware(wrap: fn(next) { next("x") })
  m.wrap(io.println)
}
