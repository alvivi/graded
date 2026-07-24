import gleam/io

// A record wrapping a function-typed field, constructed at two *distinct* sites
// (one pure, one printing) so the field's inferred effect is a union of two
// operators: `λ_. []  ⊔  λ_. [Stdout]`. This is the parser-combinator /
// state-monad idiom (atto, bitty, automata, …).
pub type Parser(a) {
  Parser(run: fn(Int) -> a)
}

pub fn pure(value: a) -> Parser(a) {
  Parser(fn(_) { value })
}

pub fn shout(value: a) -> Parser(a) {
  Parser(fn(_) {
    io.println("x")
    value
  })
}

// Calls the function-typed field on a *parameter* receiver. The two package-wide
// construction sites are nominal evidence that must not resolve a parameter
// receiver (a caller can supply any Parser), so the call stays polymorphic: `run`
// infers the field bound `p.run` and grounds to `[Unknown]` when the `check` line
// supplies no bound. A caller passing a concrete `Parser` resolves it precisely.
pub fn run(p: Parser(a), in: Int) -> a {
  p.run(in)
}
