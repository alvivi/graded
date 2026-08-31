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

// A two-variant type declaring `println` on one variant only. Gleam grants an
// accessor only for a label every variant declares, so a receiver nothing
// narrowed reads `gleam/io.println` and only a narrowed one reads the record's
// own field — which `make_logger` wires to a pure function.
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

fn quiet_print(_s: String) -> Nil {
  Nil
}

pub fn make_logger() -> Logger {
  Loud(quiet_print)
}

// An un-narrowed parameter: the module call, and the [Stdout] it carries. The
// receiver itself is never read, which is what makes the shape easy to write by
// accident — `volume` is here only to keep the compiler from saying so.
pub fn logger_param(io: Logger) -> Int {
  io.println("hi")
  volume(io)
}

// A call result is un-narrowed too, and the compiler reads the module through
// it — but no type reaches this receiver: girard records one only where it
// reads the call as a field, and the written annotation answers only for the
// parameter of the receiver's own name. So the call stays a field here and
// grounds to the pure function `make_logger` wired, which is the undercharge
// this shape still carries.
pub fn logger_call_result() -> Int {
  let io = make_logger()
  io.println("hi")
  volume(io)
}

fn volume(l: Logger) -> Int {
  case l {
    Loud(..) -> 1
    Quiet(n:) -> n
  }
}

// The narrowed counterpart: the clause fixes which variant `io` holds, so the
// compiler reads the record's own field and so does graded. No construction
// site is in reach of this receiver, so the field's effect is [Unknown] —
// imprecise, and the direction that cannot under-report.
pub fn logger_narrowed(l: Logger) -> Nil {
  case l {
    Loud(..) as io -> io.println("hi")
    Quiet(..) -> Nil
  }
}
