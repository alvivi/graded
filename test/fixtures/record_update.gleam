import gleam/io

pub type Config {
  Config(name: String, count: Int)
}

// An effectful same-module helper used as a record-update field value.
fn shout(s: String) -> String {
  io.println(s)
  s
}

// Updates a field with an effectful expression. The call in the field value
// (`shout : [Stdout]`) sits inside a record update, so it is only seen if the
// extractor walks the updated fields, not just the base record.
pub fn run(base: Config) -> Config {
  Config(..base, name: shout("x"))
}
