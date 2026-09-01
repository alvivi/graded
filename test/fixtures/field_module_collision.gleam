// An effectful field colliding with a pure module of the receiver's name.
//
// `Client.send` reaches the network, and `list` — the name every receiver below
// is bound to — also names the imported `gleam/list`, whose catalog entry makes
// every function under it pure. Compiling this module emits
// `erlang:element(2, List)` for every one of the seven `send` calls and never a
// `gleam@list` one, so the field is the whole charge; reading the module instead
// would report `[]` for a call that goes out to the network, which is the one
// direction that under-reports.
//
// The polarity is what separates this fixture from `shadow_receiver`, where the
// module is the effectful half and the field the pure one. One call per
// function, so the emitted Erlang maps back to a single source expression.
import gleam/list

// `send` is declared on one variant of two, so Gleam grants no accessor for it
// and only a narrowed receiver reaches the field.
pub type Client {
  Live(send: fn(String) -> Nil)
  Dead(n: Int)
}

@target(erlang)
@external(erlang, "some_ffi_module", "send")
fn net_send(message: String) -> Nil

// Keeps `gleam/list` genuinely imported, so the name really does denote a
// module at every call site below — and pins that the module half is pure.
pub fn count(xs: List(Int)) -> Int {
  list.length(xs)
}

pub fn direct_construction() -> Nil {
  let list = Live(net_send)
  list.send("hi")
}

pub fn case_narrowed(c: Client) -> Nil {
  case c {
    Live(..) as list -> list.send("hi")
    Dead(..) -> Nil
  }
}

pub fn let_assert_narrowed(list: Client) -> Nil {
  let assert Live(..) = list
  list.send("hi")
}

// The three alias shapes below are the ones girard declines to type at all: it
// carries no narrowing across a binding, so it reads `list.send` as an accessor
// on the un-narrowed `Client` and reports no such field. The enclosing function
// is skipped, no type reaches the receiver, and the field reading is all that
// keeps the call off the pure module.
pub fn simple_alias(c: Client) -> Nil {
  let assert Live(..) = c
  let list = c
  list.send("hi")
}

pub fn block_alias(c: Client) -> Nil {
  let assert Live(..) = c
  let list = {
    c
  }
  list.send("hi")
}

pub fn alias_in_narrowed_branch(c: Client) -> Nil {
  case c {
    Live(..) as live -> {
      let list = live
      list.send("hi")
    }
    Dead(..) -> Nil
  }
}

// The narrowing dies on the rebinding and the construction re-establishes it,
// so the compiler still reads the field.
pub fn rebound_after_narrowing(list: Client) -> Nil {
  let assert Live(..) = list
  let list = Live(net_send)
  list.send("hi")
}
