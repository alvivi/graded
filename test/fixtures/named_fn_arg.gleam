import gleam/io

// A first-order higher-order helper: `parser` is fn-typed but not an operator
// (it takes a value, not a function), so a call site resolves its argument
// through the first-order path.
pub fn parse_optional(input: String, parser: fn(String) -> Int) -> Int {
  parser(input)
}

// An effectful same-module named function, passed to `parse_optional` by
// reference (not as an inline closure).
fn logging_parser(s: String) -> Int {
  io.println(s)
  1
}

pub fn run() -> Int {
  parse_optional("x", logging_parser)
}
