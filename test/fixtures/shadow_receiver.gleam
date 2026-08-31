// A parameter named after an imported module. `Thing` declares no `try` field,
// so the compiler reads `gleam/result.try` and the call is reported as one — it
// is not a field call on `result`.
import gleam/io
import gleam/result

pub type Thing {
  Thing(n: Int)
}

pub fn shadowed(result: Thing, r: Result(Int, Nil)) -> Result(Int, Nil) {
  use v <- result.try(r)
  io.println("hi")
  Ok(v + result.n)
}
