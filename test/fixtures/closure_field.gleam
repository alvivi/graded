import gleam/io

pub type Notifier {
  Notifier(send: fn(String) -> Nil)
}

pub fn run() {
  // The receiver is a let-bound *inline construction*, so `send`'s value is proven
  // for this receiver: graded analyses the wired closure body and resolves the
  // field call to [Stdout] — no hand-written `type Notifier.send` annotation.
  let n = Notifier(send: fn(msg) { io.println(msg) })
  n.send("hi")
}
