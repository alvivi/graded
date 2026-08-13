// `check` lines written on `@external` functions themselves, rather than on a
// function that calls one. An external is checked against what declares it —
// there is no body to walk, and the Gleam fallback one may carry is not the
// foreign code that runs — so `declared_over_budget` violates its budget on the
// strength of the spec's `external effects` line alone, and `undeclared` on the
// `[Unknown]` an external nothing declares carries. `declared_within_budget`
// passes: its budget covers what the declaration states.
//
// The `@target(erlang)` gate keeps the module out of the JavaScript build, where
// the bodyless externals have no implementation.

@target(erlang)
@external(erlang, "some_ffi_module", "clock")
pub fn declared_over_budget() -> Nil

@target(erlang)
@external(erlang, "some_ffi_module", "clock")
pub fn declared_within_budget() -> Nil

// A pure-looking Gleam fallback body, which says nothing about what the foreign
// implementation does: walking it would report `[]` and pass the `[]` budget.
@target(erlang)
@external(erlang, "some_ffi_module", "write")
pub fn undeclared() -> Nil {
  Nil
}

// An `effects` line the spec still carries from when this was an ordinary Gleam
// function (see fixtures.graded). Inference over a body is not a statement
// about foreign code, so it declares nothing and the budget is still checked
// against the `[Unknown]` an undeclared external carries.
@target(erlang)
@external(erlang, "some_ffi_module", "clock")
pub fn stale_inferred() -> Nil

// Declared `[Unknown]` on purpose — an admission that the effect isn't known,
// which is still a declaration and still names the line it came from.
@target(erlang)
@external(erlang, "some_ffi_module", "clock")
pub fn declared_unknown() -> Nil
