import gleam/io

pub type Notifier {
  Notifier(send: fn(String) -> Nil)
}

fn make() -> Notifier {
  // The field is wired to an inline closure (not a named function). graded
  // analyses the closure body, so `send`'s effect is inferred as [Stdout]
  // without a hand-written `type Notifier.send` annotation.
  Notifier(send: fn(msg) { io.println(msg) })
}

pub fn run() {
  let n = make()
  n.send("hi")
}
