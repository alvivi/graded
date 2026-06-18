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

// Calls the function-typed field with a *non-function* argument. The union of
// operators must be applied and β-reduced to the concrete `[Stdout]`, not leak
// the raw operator bounds into run's effect set (which would ground to
// `[Unknown]` and violate the `[Stdout]` budget). Regression for the
// union-of-operators field-call leak.
pub fn run(p: Parser(a), in: Int) -> a {
  p.run(in)
}
