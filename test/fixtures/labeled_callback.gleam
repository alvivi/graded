import gleam/io

// A first-order higher-order helper whose callback carries a Gleam label
// (`with`). The label at the call site, not the definition, is what used to
// block argument-to-parameter matching.
pub fn apply_labeled(input: String, with parser: fn(String) -> Int) -> Int {
  parser(input)
}

// An effectful same-module named function, passed with the `with:` label.
fn logging_parser(s: String) -> Int {
  io.println(s)
  1
}

pub fn run() -> Int {
  apply_labeled("x", with: logging_parser)
}
