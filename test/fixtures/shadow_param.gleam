import gleam/io

pub fn parse_optional(input: String, parser: fn(String) -> Int) -> Int {
  parser(input)
}

// A same-module named function whose name the `run` parameter below shadows.
pub fn handler(s: String) -> Int {
  io.println(s)
  1
}

// `handler` here is the pure fn-typed parameter, not the [Stdout] same-module
// function of the same name. The argument must resolve through the param bound
// ([]) rather than by lifting the shadowed function, so the [] budget holds.
pub fn run(handler: fn(String) -> Int) -> Int {
  parse_optional("x", handler)
}

// A `let` alias of the fn-typed parameter, called directly. The call resolves
// through the parameter's bound, not the same-module `handler` of the same name
// nor `[Unknown]`, so the [] budget holds.
pub fn run_alias(handler: fn(String) -> Int) -> Int {
  let f = handler
  f("x")
}
