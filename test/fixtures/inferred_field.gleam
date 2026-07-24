import gleam/io

pub type Logger {
  Logger(emit: fn(String) -> Nil)
}

fn make() -> Logger {
  Logger(emit: io.println)
}

pub fn run() {
  // The receiver is bound from a *call* (`make()`). Tier 2 grounds `make`'s
  // return construction (`Logger(emit: io.println)`) per receiver, so `l.emit()`
  // resolves to the precise [Stdout] — proven for this receiver, not borrowed
  // from the nominal index. The [] check budget must fail.
  let l = make()
  l.emit("hi")
}
