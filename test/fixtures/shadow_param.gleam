import gleam/io

pub fn parse_optional(input: String, parser: fn(String) -> Int) -> Int {
  parser(input)
}

// A same-module named function whose name the `run` parameter below shadows.
fn handler(s: String) -> Int {
  io.println(s)
  1
}

// `handler` here is the pure fn-typed parameter, not the [Stdout] same-module
// function of the same name. The argument must resolve through the param bound
// ([]) rather than by lifting the shadowed function, so the [] budget holds.
pub fn run(handler: fn(String) -> Int) -> Int {
  parse_optional("x", handler)
}
