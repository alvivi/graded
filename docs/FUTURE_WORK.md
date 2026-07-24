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

## Precise builder-chain field effects (Tier 2)

A fn-typed field reached through a parameter or a builder (`with_*`) record update
stays **polymorphic** — `annotate(options.resolver: [options.resolver])` — and a
consumer that binds the builder result before the field is read gets `[Unknown]`:

```gleam
let opts = default_options() |> with_resolver(logging_resolver)  // [Stdout]
annotate(opts)   // [Unknown] today — sound, but not the precise [FileSystem, Stdout]
```

This is sound (see [LIMITATIONS.md](LIMITATIONS.md#1-a-record-field-reached-through-an-untraceable-receiver))
but imprecise. Two representations would recover the precise set:

- **Let-bound call-result provenance.** A `let o = default_options() |>
  with_resolver(http)` binds a *call result*; graded classifies that as a returned
  operator (meant for functions returned by producers) and loses the `with_resolver`
  value provenance. A `BoundCallResult(callee, args)` binding that survives the `let`
  and carries its provenance when passed onward would let the field call resolve
  through the builder chain.
- **Field-selective overlay for record updates.** `Options(..base, resolver: http)`
  replaces only `resolver` (last-write-wins, not union) and inherits the rest from
  `base`. An `Updated(base, fields)` provenance that resolves per field — reading the
  replacement immediately and consulting the base only for fields *not* updated, so an
  opaque base never has to ground before an updated field is read — composes a chain
  (`… |> with_resolver(http) |> with_target(js)`) precisely.

Both are needed together to make the builder idiom precise where graded sees the
builder's source in the same run. Carrying the precision *across* a package boundary
(an installed/catalogued dependency whose builder source graded never infers) is a
separate, still-undecided step: value/overlay provenance lives only in the in-process
knowledge base, not in `.graded` specs or the catalog, so an installed consumer stays
`[Unknown]` for a field it supplies unless a provenance-transport format is added.

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
