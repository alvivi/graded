# Future work

graded's effect analysis is mature: first- and second-order effect polymorphism,
girard-backed field resolution, and cross-module / cross-package inference all
ship today. What remains is a short list of refinements and one new direction,
ordered by incrementality — earlier items are smaller, later items push into
different territory.

## Hand-written field bounds

Extend parameter bounds to accept a *path* expression, so a user can declare a
record field's effects at the function boundary when graded can't trace the value
on its own (the field-call case in [LIMITATIONS.md](./LIMITATIONS.md#1-a-record-field-reached-through-an-untraceable-receiver)):

```
check myapp.view(handler.on_click: [Dom]) : [Dom]
```

This is a syntax extension to `ParamBound` (a path instead of a bare identifier),
no analysis required — the user states what a field's effects are, and
substitution works exactly like first-order parameter bounds. It gives the
field-call limitation a boundary-level escape hatch, complementing the existing
`type` line.

## Retiring the positional/label heuristics

graded reads expression types from [girard](https://hexdocs.pm/girard), which
already resolves field calls without explicit parameter annotations and detects
fn-typed parameters. The one piece not taken: replacing the positional/label
argument-matching heuristics (`find_matching_arg` / `position_from_registry` in
`signatures.gleam` and `checker.gleam`). They drive polymorphic call-site
substitution — a subsystem girard's expression types don't cleanly map onto — so
they were kept deliberately. Revisit only if a concrete imprecision surfaces.

## Ecosystem catalog growth

The bundled catalog (`priv/catalog/`) covers the core `gleam-lang` packages and
the most-used community libraries. Adding `.graded` entries for more packages as
they come up is an ongoing maintenance thread, not a milestone. The longer-term
fix for the most popular libraries is for them to ship their own `.graded` spec —
dependency specs outrank the catalog — so cataloguing is the stopgap for the head
of the long tail.

## Privacy and information-flow checking

The next major direction is **lattice-based privacy tracking** — preventing
sensitive data (PII, credentials) from flowing into logs, error messages, or
third-party services.

Both checkers share the same foundation: graded modal type theory (see
[THEORY.md](./THEORY.md)). Effects use sets with union; privacy uses lattices
with join. This is distinct enough to warrant its own design doc when the time
comes.
