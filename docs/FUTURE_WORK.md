# Future work

graded's effect analysis is mature: first- and second-order effect polymorphism,
girard-backed field resolution, hand-written field bounds, and cross-module /
cross-package inference all ship today. What remains is a short list of refinements
and one new direction, ordered by incrementality — earlier items are smaller, later
items push into different territory.

## Deeper provenance for field forwarding

Field-effect forwarding re-keys a callee's field bound onto the caller when the
receiver argument's provenance is syntactically rooted in a caller parameter — a
parameter, a receiver path (`inner(config.options)` → `config.options.resolver`),
an inline constructor/factory call (`inner(make_options(resolver))` → `resolver`),
or a let-bound alias of any of those (`let o = make_options(resolver); inner(o)`).
Construction nests one extra level (`make_outer(make_inner(resolver))`). What
remains conservative is provenance that needs real data-flow analysis: a receiver
threaded through a **computed call** (`inner(get_options(config.options))`),
construction nested **two or more levels** beyond the single extra hop, and values
pulled out of collections or other data structures. Extending forwarding to those
would mean tracing values through arbitrary expressions rather than the syntactic
shapes above — a larger step, and one that risks understating effects if done
unsoundly. The `type` line and field bound remain the escape hatches meanwhile.

## Retiring the positional/label heuristics

graded reads expression types from [girard](https://hexdocs.pm/girard), which
already resolves field calls without explicit parameter annotations and detects
fn-typed parameters. The one piece not taken: replacing the positional/label
argument-matching heuristics (`find_matching_arg` / `param_info` in
`checker.gleam`). They drive polymorphic call-site
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
