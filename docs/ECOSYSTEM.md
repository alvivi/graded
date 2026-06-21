# graded in the ecosystem

Where graded sits among effect systems, sidecar specification tools, and the
static analysers of its own runtime — what it borrows, and what makes it
different. graded is a **sound, sidecar-based effect checker** for Gleam: effects
are sets of labels, composition is union, checking is subset inclusion (see
[THEORY.md](./THEORY.md)). Its design draws deliberately from three neighbourhoods.

## On the BEAM: Dialyzer and the Elixir types

graded targets the Erlang/BEAM runtime, where the incumbent static analyser is
**Dialyzer** (DIscrepancy AnaLYZer for ERlang). The two make opposite bets on the
soundness/completeness trade-off, and they look at different things:

- **Dialyzer uses success typing.** It is optimistic: it reports only code that is
  *provably* wrong, so it (almost) never raises a false positive — but it misses
  real problems it can't prove. It analyses type discrepancies and **does not track
  side effects at all**.
- **graded is sound (over-approximating) for effects.** It takes the dual stance:
  it never *misses* an effect, but it may *ask* for an annotation on a value it
  can't statically resolve (`[Unknown]`) rather than stay silent. A green check is
  a guarantee; a red one may just need a hint.

So they are **complementary, not competing**: Dialyzer answers "will this code
crash on a type discrepancy?", graded answers "what effects can this function
perform, and are they within budget?" Nothing on the BEAM tracked the latter before
graded.

The Elixir side of the runtime is similar. **`@spec` typespecs** (optional, and
themselves checked by Dialyzer) and Elixir's newer **set-theoretic gradual types**
are both type-level and say nothing about effects. Gleam itself has a sound static
type system but, before graded, no general static-analysis tooling and no effect
tracking — which is the niche graded fills.

## Effect systems

graded's effect model sits at the conservative end of a well-trodden design space:

| System | Effect representation | Polymorphism | Inference | Takeaway for graded |
|---|---|---|---|---|
| **Koka** | Row types | Row variables | Full, H-M style | The gold standard — and far heavier than a sidecar checker needs |
| **Eff** | Sets with subtyping | Limited | Constraint-based | Subset ordering matches graded's checking relation |
| **Frank** | Implicit | All arguments polymorphic | Implicit | Elegant, but impossible to retrofit onto an existing language |
| **Haskell `effectful`** | Type-level list | Type variables | Manual | Pragmatism drives adoption |
| **OCaml 5** | Untracked at the type level | — | None | Validates tracking effects *outside* the type system |
| **Java checked exceptions** | Declared sets | **None** | Partial | Cautionary tale: no polymorphism ⇒ unusable for higher-order code |

Two lessons shaped graded. First, **effect polymorphism is non-negotiable**:
without it you cannot annotate `map`, and Java's checked exceptions are the
canonical failure. graded answers with effect variables (`map(f: [e]) : [e]`) and —
going further than most set-based systems — higher-kinded *operator* variables for
second-order callbacks (see [THEORY.md](./THEORY.md) and
[SECOND_ORDER_EFFECTS.md](./SECOND_ORDER_EFFECTS.md)). Second, an effect checker can
live **outside** the type system (as OCaml 5's untyped effects, or any external
analyser, show), which is exactly what lets graded be a sidecar over plain Gleam
rather than a language fork.

## Sidecar specification tools

graded keeps its annotations *beside* the code rather than inline, joining a family
of tools that made the same call:

| Tool | Annotation location | Reference mechanism |
|---|---|---|
| **Liquid Haskell** | Inline `{-@ … @-}` comments | By name, co-located |
| **Stainless** | Embedded Scala DSL | By code structure |
| **JML / ACSL** | Inline comments | By adjacency |
| **Python `.pyi` stubs** | Sidecar files | Filename + qualified name |
| **CodeQL** | Separate query files | AST pattern matching |
| **Semgrep** | YAML rule files | Syntactic patterns |

The durable lessons, and how graded applies each:

- **Sidecar beats inline.** JML, ACSL, and Liquid Haskell all accrete annotation
  clutter; Python `.pyi` stubs and graded's `.graded` spec keep the source clean.
  graded goes a step further than per-file stubs: one spec file per package holds
  the public surface, with a regenerable `build/` cache for the rest.
- **Reference by qualified name.** Gleam has no overloading, so `module.function` is
  unambiguous — the same property `.pyi` stubs rely on.
- **Staleness is the #1 risk.** Every surviving sidecar tool fails loudly when an
  annotation drifts from the code; graded regenerates inferred lines on `infer` and
  checks formatting in CI (`graded format --check`).
- **Partial adoption is essential.** Unannotated modules are simply unchecked, the
  way untyped Python is ignored by stubs — this is how sidecar tools get adopted at
  all.
- **Skeletons must be generated.** Nobody hand-maintains sidecar files; `graded
  infer` writes the initial spec from source.

## Graded modal type theory: Granule and Gerty

graded's foundations come from **graded modal type theory**, whose reference
implementation is **Granule** (with the smaller **Gerty** as a cleaner reading of
the constraint machinery). The illuminating comparison is what graded *doesn't*
need from it.

Granule is a research language (~27k lines of Haskell, Z3 at runtime via `sbv`)
where graded modalities generate constraints that are batch-solved by an SMT solver.
But for *effects specifically*, Granule's own `Effects.hs` uses no SMT at all —
composition is set union, checking is a subset test, branch-join is union, purity is
an emptiness check. **All trivial set operations.** graded is, in effect, that
fragment promoted to a standalone tool: a lightweight checker over the set semiring,
with no solver, no bidirectional inference, and none of the graded-modality
machinery.

SMT only becomes necessary for *richer* grades — naturals for linearity
(`n + m ≤ k`), parametric privacy lattices, interval arithmetic. graded defers all
of those; privacy is a [planned](./FUTURE_WORK.md) next checker on the same
foundation. Direct reuse of Granule's checker is impractical — it is fused to
Granule's own AST and checker monad — so it serves as an architectural reference,
not a dependency.

For the theory itself and the papers behind it, see [THEORY.md](./THEORY.md).
