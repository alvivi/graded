// A narrowed receiver whose effectful field collides with a label the module of
// its own name really exports.
//
// `Client.println` reaches the network, and `io` — the name every receiver below
// is bound to — also names `gleam/io`, which exports `println`. That export is
// what separates this fixture from `field_module_collision`: `gleam/list`
// exports no `send`, so there the module branch is unavailable and the field
// reading is reached by elimination. Here both readings are available at once,
// which is the shape the compiler settles from the receiver's narrowed type.
//
// Compiling this module emits `erlang:element(2, Io)` for all three of the
// receiver-bound `println` calls, and `gleam_stdlib:println` only for `greet`,
// where the name really is the module — so the field is the whole charge below.
// girard resolves them the other way: `infer_callee` selects the module export
// whenever `accessor` grants no shared label, and never consults the variant a
// pattern narrowed the receiver to. The charge here has to stay the field's
// [Net] or [Unknown] whatever the module's own budget says — reading the module
// reports [Stdout] under this package's spec, and nothing at all under one that
// declares `gleam/io` pure, and both miss a call that goes out to the network.
//
// One call per function, so the emitted Erlang maps back to a single source
// expression.
import gleam/io

// `println` is declared on one variant of two, so Gleam grants no accessor for
// it and only a narrowed receiver reaches the field.
pub type Client {
  Live(println: fn(String) -> Nil)
  Dead(n: Int)
}

@target(erlang)
@external(erlang, "some_ffi_module", "send")
fn net_send(message: String) -> Nil

// Keeps `gleam/io` genuinely imported, so the name really does denote a module
// at every call site below — and pins what the module half answers.
pub fn greet() -> Nil {
  io.println("hi")
}

pub fn case_narrowed(c: Client) -> Nil {
  case c {
    Live(..) as io -> io.println("hi")
    Dead(..) -> Nil
  }
}

pub fn let_assert_narrowed(io: Client) -> Nil {
  let assert Live(..) = io
  io.println("hi")
}

pub fn direct_construction() -> Nil {
  let io = Live(net_send)
  io.println("hi")
}
