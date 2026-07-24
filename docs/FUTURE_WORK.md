# Future work

graded's effect analysis is mature: first- and second-order effect polymorphism,
girard-backed field resolution, hand-written field bounds, and cross-module /
cross-package inference all ship today. What remains is a short list of refinements
and one new direction, ordered by incrementality — earlier items are smaller, later
items push into different territory.

## Deeper provenance for field forwarding

Field-effect forwarding re-keys a callee's field bound onto the caller when the
receiver argument's provenance is traceable to a caller parameter — a parameter, a
receiver path (`inner(config.options)` → `config.options.resolver`), an inline
constructor/factory call (`inner(make_options(resolver))` → `resolver`), a
let-bound alias of any of those (`let o = make_options(resolver); inner(o)`), or a
**computed call** to a helper whose return-value provenance graded can trace. That
last case now covers a direct tail shape (`inner(get_options(config))` where
`get_options` returns `config.options`), a partial record rebuild that keeps its
parameter-rooted fields, a labeled call (reordered into parameter order), a
`case`/`if` join of parameter-rooted branches, and a parameter returned through a
converging tail-recursive self-call. Construction nests one extra level
(`make_outer(make_inner(resolver))`).

What remains conservative is provenance that needs still-deeper data-flow
analysis: a helper whose return is itself a **non-self call** (`get(make(x))` — no
helper-call composition), a **record rebuilt through a recursion** or one that
doesn't converge, **mutual recursion**, construction nested **two or more levels**
beyond the single extra hop, and values pulled out of collections or other data
structures. Return-value provenance also lives only in the in-process knowledge
base — it isn't serialized to `.graded` specs or the catalog, so a computed
receiver into a spec-backed or catalogued dependency stays conservative. Closing
these would mean helper-call composition, tracing through arbitrary expressions,
and a provenance serialization format — larger steps, each risking understated
effects if done unsoundly. The `type` line and field bound remain the escape
hatches meanwhile.

## Direct field calls on computed receivers

A field call whose receiver is itself a call result (`decode_user().function(x)`,
`make_yielder().continuation()`) resolves its receiver type through girard, then
looks up the field's effect on that type. When the field is a callback stored on
the record with no visible body — the decoder/iterator/context idiom
(`.function`, `.continuation`, `.lookup`) — that field's own effect is already
`[Unknown]`, so typing the receiver changes nothing and the call stays
`[Unknown]`. Discharging it would need tracing the callback back to its
construction site, the same construction-site data-flow the deeper-provenance
items above defer, and understates the effect if done unsoundly. The `type` line
remains the escape hatch meanwhile.

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
