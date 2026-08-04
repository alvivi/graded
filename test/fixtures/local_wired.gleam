// A record field wired to a function defined in the same module as the wiring.
// Sibling functions are absent from the knowledge base while their own module is
// being inferred, so the field call resolves them from the module's own
// definitions instead of collapsing to [Unknown]. Every shape below — direct
// construction, an inherited constructor default, a builder overlay, a producer
// call, a let-bound closure — reaches its effect through the field call.
import gleam/io

pub type Reader {
  Reader(read: fn(String) -> Nil, label: String)
}

@target(erlang)
@external(erlang, "some_ffi_module", "read")
fn read_disk(path: String) -> Nil

// Private, with no `effects` line in the spec file: while `local_wired` is being
// inferred nothing but its own definition says this is [Disk].
@target(erlang)
fn disk_read(path: String) -> Nil {
  read_disk(path)
}

fn logging_read(message: String) -> Nil {
  io.println(message)
}

// A producer whose returned closure carries the effect.
@target(erlang)
fn make_read() -> fn(String) -> Nil {
  fn(path) { read_disk(path) }
}

pub fn default_reader() -> Reader {
  Reader(read: disk_read, label: "default")
}

pub fn with_read(reader: Reader, read: fn(String) -> Nil) -> Reader {
  Reader(..reader, read:)
}

pub fn perform(reader: Reader, path: String) -> Nil {
  reader.read(path)
}

// Direct construction. Constructor arguments are skipped during extraction, so
// the field call is the only route to [Disk].
@target(erlang)
pub fn run_direct() -> Nil {
  perform(Reader(read: disk_read, label: "direct"), "x")
}

// The receiver is a call result whose construction wired the field: [Disk]
// resolves through the callee's return provenance, with no reference to
// `disk_read` anywhere in this body.
pub fn run_inherited() -> Nil {
  perform(default_reader(), "x")
}

// A builder overlay replaces the constructor default. [Stdout] wins
// last-write-wins, so the default's [Disk] must not show through.
pub fn run_replaced() -> Nil {
  perform(with_read(default_reader(), logging_read), "x")
}

// The field wired from a *call*: the producer's returned closure carries [Disk].
@target(erlang)
pub fn run_producer() -> Nil {
  perform(Reader(read: make_read(), label: "producer"), "x")
}

// A let-bound closure wired into the field by shorthand.
@target(erlang)
pub fn run_closure() -> Nil {
  let read = fn(path) { read_disk(path) }
  perform(Reader(read:, label: "wired"), "x")
}

// Nothing proves what the caller's own parameter does, so the field call stays
// polymorphic in that parameter rather than borrowing a same-module definition.
pub fn run_unresolved(read: fn(String) -> Nil) -> Nil {
  perform(Reader(read:, label: "wired"), "x")
}

@target(erlang)
@external(erlang, "some_ffi_module", "reader")
fn opaque_read() -> fn(String) -> Nil

// The field is wired from a producer graded can't see into, so there is nothing
// to lift: [Unknown], not a same-module guess.
@target(erlang)
pub fn run_opaque() -> Nil {
  perform(Reader(read: opaque_read(), label: "opaque"), "x")
}

// The field holds the very function being analysed. Resolution stops at the
// cycle instead of looping, leaving [Unknown].
fn self_wired(path: String) -> Nil {
  perform(Reader(read: self_wired, label: "self"), path)
}

pub fn run_self_wired() -> Nil {
  self_wired("x")
}

// Two functions wiring each other into the field: mutual recursion terminates
// the same way.
fn ping(path: String) -> Nil {
  perform(Reader(read: pong, label: "ping"), path)
}

fn pong(path: String) -> Nil {
  perform(Reader(read: ping, label: "pong"), path)
}

pub fn run_mutual() -> Nil {
  ping("x")
}
