# Future work

graded's effect analysis is mature: first- and second-order effect polymorphism,
girard-backed field resolution, hand-written field bounds, and cross-module /
cross-package inference all ship today. What remains is a short list of refinements
and one new direction, ordered by incrementality — earlier items are smaller, later
items push into different territory.

## Retiring the positional/label heuristics

graded reads expression types from [girard](https://hexdocs.pm/girard), which
already resolves field calls without explicit parameter annotations and detects
fn-typed parameters. The one piece not taken: replacing the positional/label
argument-matching heuristics (`find_matching_arg` / `position_from_registry` in
`signatures.gleam` and `checker.gleam`). They drive polymorphic call-site
substitution — a subsystem girard's expression types don't cleanly map onto — so
they were kept deliberately. Revisit only if a concrete imprecision surfaces.

## Privacy and information-flow checking

The next major direction is **lattice-based privacy tracking** — preventing
sensitive data (PII, credentials) from flowing into logs, error messages, or
third-party services.

Both checkers share the same foundation: graded modal type theory (see
[THEORY.md](./THEORY.md)). Effects use sets with union; privacy uses lattices
with join. This is distinct enough to warrant its own design doc when the time
comes.
