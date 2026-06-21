# Design: second-order effect variables via a uniform `EffectTerm` model

Status: **implemented** (branch `nested-effect-vars`). This closes the "no
nested (second-order) effect variables" limitation that was documented in
[README.md](../README.md#limitations). All
six phases below shipped. Operators are **n-ary** via currying: an operator
parameter whose type takes several functions (`fn(fn() -> _, fn() -> _) -> _`)
threads *all* its callbacks as a curried application `((action e1) e2)`, and an
operator argument is lifted to a curried operator `λp1. λp2. body` over the same
callbacks in order — the unary `TApp`/`TAbs` need no change because `reduce`
already walks spines. Operator arguments are lifted from **named function
references** (cross-module via the knowledge base, same-module via on-demand
transitive analysis, since siblings aren't in the KB during their module's
inference pass), **inline closures**, **let-bound closures**
(`let h = fn(cb) { … }`), **`case`/`if` branches over function-like options**
(each branch lifted and the operators **joined** by descending their `TAbs`
spines in lockstep — `(f ⊔ g)(cb) = f(cb) ⊔ g(cb)`), and **functions returned
from a call** (`let h = pick_handler()`; the producer's returned operator is
computed where the producer is defined — so its module's private callees are in
scope — **serialized into the spec** as a `returns mod.fn : fn(cb) -> [cb]` line
and loaded from the project and dependency specs, so it resolves across module
*and package* boundaries during `check`, not only `infer`). The returned value
is resolved whether it is **passed to an operator parameter** (`with(h)`) or
**applied directly** (`h(cb)`); a returned **first-order** function carries a
**latent effect** instead of an operator (`fn make() -> fn() -> Nil`, serialized
as `returns make : [Stdout]`), so `let f = make(); f()` yields that effect. A value that is a
**block** resolves to its tail expression; a record **field wired to a closure**
is resolved from the closure body (including an **operator-typed field** whose
closure calls its callback — lifted to `λnext. [next]` and applied at the field
call); `check` **auto-infers** project modules missing from the spec; and a
returned operator may be **polymorphic in the producer's parameters** — a producer
returning one of its operator parameters (`fn wrap(base) { base }`) or **wrapping**
it in a closure (a decorator, `fn traced(action) { fn(cb) { log(); action(cb) } }`)
binds the parameter to the producer call's argument. A returned closure is lazy, so
it's excluded from the producer's own direct call-effect (accounted only when
applied), keeping decorators precise. A producer that selects one of its operator
parameters through a *branch* (`case … { _ -> a  _ -> b }`) resolves too — the
union of operators beta-reduces by distributing application over the union. A
record **field wired to a parameter** resolves through a **factory** (a function
whose tail constructs the record from its parameters): `let v = make(io.println)`
binds the result's fields like a direct construction. The remaining residuals,
all sound (`[Unknown]`), are: a function value reached through *arbitrary
computation* (needs whole-program control-flow analysis); a record receiver from
an untraceable source (no provenance to a factory or construction); and a
`use`-tailed *returned operator* — noted in the README limitations.

## Goal

Let graded express and resolve **higher-kinded effect variables** — effect
variables of kind `Eff → Eff` (effect *operators*), not just `Eff` (flat sets).
The motivating program graded cannot currently handle:

```gleam
pub fn with_logger(action: fn(fn(String) -> Nil) -> a) -> a {
  action(fn(msg) { io.println(msg) })   // action applied to a [Stdout] callback
}
```

Target inferred signature, and its resolution at a concrete call site:

```
effects myapp.with_logger(action: fn(cb) -> [cb]) : [action([Stdout])]

// at  with_logger(run)  where  run : fn(cb) -> [Http, cb]
//   action := λcb. [Http, cb]
//   action([Stdout])  ──β──►  [Http, Stdout]
```

In `.graded` syntax an operator application's arguments are each a bracketed
effect term and are **curried** (order-significant): `action([Stdout])` is one
callback, `action([Stdout], [FileSystem])` is two. A single multi-label callback
is `action([Stdout, FileSystem])`. Operator bounds may take several parameters:
`fn(a, b) -> [a, b]`.

First-order effect polymorphism (a variable standing for a flat set, e.g.
`map(f: [e]) : [e]`) already works. What's new is that the quantified variable
can be *higher-kinded* — an effect operator that must be **applied** to an
argument effect and **beta-reduced**. That is the System F-ω story transplanted
from types to effects: `e :: Eff` vs `action :: Eff → Eff`.

## The core reframe

**`EffectSet` is the ground normal form of `EffectTerm`.** There are no longer
"first-order" and "second-order" annotations as two species — there is one
representation (`EffectTerm`), and `EffectSet` is simply what a fully-resolved
term normalizes to. `EffectSet` survives only at the **checking boundary**:
`is_subset` compares ground sets, and that is the one place a term must be
reduced first.

```gleam
// new module: src/graded/internal/effect_term.gleam
pub type EffectTerm {
  TLabels(Set(String))                  // ground labels ({} = pure).        kind Eff
  TTop                                  // wildcard [_], absorbing.          kind Eff
  TVar(String)                          // free effect variable e.           kind Eff
  TApp(fn: EffectTerm, arg: EffectTerm) // operator applied: action(Stdout). kind Eff
  TAbs(param: String, body: EffectTerm) // λcb. body — an effect operator.   kind Eff → Eff
  TUnion(List(EffectTerm))              // composition (set union).          kind Eff
}
```

Kinds stay **implicit in structure** — a `TAbs`-bound variable used under `TApp`
is `Eff → Eff`; a bare `TVar` is `Eff`. No kind field is stored. An explicit
kind-check pass that rejects ill-kinded input (`e(Stdout)` where `e` was
declared flat) is a later nicety, not core.

## Data-model changes (uniform)

`EffectSet` keeps its current definition — it is still the normal form, and
`union` / `is_subset` / `empty` / `from_labels` stay as they are. The annotation
types move to `EffectTerm`:

```gleam
pub type ParamBound {
  ParamBound(name: String, effect: EffectTerm)   // was: effects: EffectSet
}

pub type EffectAnnotation {
  EffectAnnotation(
    kind: AnnotationKind,
    function: String,
    params: List(ParamBound),   // first- and second-order entries, uniformly
    effects: EffectTerm,        // result; may contain applications. was: EffectSet
  )
}
```

`TypeFieldEffect` and `TypeFieldAnnotation` likewise carry `EffectTerm`, so
field calls compose with second-order resolution the same way resolved calls do.

## Where `EffectSet` still appears (the boundary)

| Concern                                            | Representation                       |
| -------------------------------------------------- | ------------------------------------ |
| `is_subset` / violation check                      | `EffectSet` — reduce term, then compare |
| Knowledge-base lookup result, after resolution     | `EffectSet`                          |
| `.graded` serialization of a fully-ground annotation | formats identically to today       |
| Annotation as parsed / stored / inferred (may be symbolic) | `EffectTerm`                 |

Two bridges in `effect_term.gleam`:

- `from_effect_set : EffectSet → EffectTerm` — `Wildcard → TTop`,
  `Specific → TLabels`, `Polymorphic(l, v) → TUnion([TLabels(l), ..v.map(TVar)])`.
- `to_effect_set : EffectTerm → EffectSet` — **normalize first**, then leftover
  free `TVar`s become `Polymorphic` variables and a residual **stuck `TApp`**
  collapses to `[Unknown]` (see "Stuck-term semantics").

## Reduction semantics (`normalize`)

- **Union laws:** `TUnion` flattens nested unions, drops empty `TLabels`, dedups
  labels, and `TTop` absorbs everything.
- **Beta:** `TApp(TAbs(p, body), arg) → body[p := arg]`, capture-avoiding.
- **Stuck:** `TApp(TVar f, arg)` with `f` unbound stays symbolic until a binding
  for `f` arrives at a call site.
- Substitution `subst : EffectTerm → Dict(String, EffectTerm) → EffectTerm`
  replaces the single-pass `types.substitute`; bindings may themselves be
  `TAbs` (an operator), which is what enables the nested case.

### Stuck-term semantics

When a call site cannot resolve an operator application (e.g.
`with_logger(mystery)` where `mystery`'s operator behavior is unknown), a stuck
`TApp` collapses to `[Unknown]` — exactly as unresolved field effects and free
variables already concretize today. This is **sound** (it never hides a
violation), predictable, and consistent with existing behavior. `check` always
applies this collapse before the subset test. (`infer` *may* later choose to
write the symbolic term to disk for precision; that is pure upside with no
soundness effect and is out of scope for the initial implementation.)

## Surface syntax (`annotation.gleam`)

The effect grammar gains two productions; existing lines are unaffected:

- **Operator bound:** `action: fn(cb) -> [cb]` → `ParamBound("action", TAbs("cb", …))`,
  and curried `fn(a, b) -> [a, b]` → `TAbs("a", TAbs("b", …))`.
- **Application in any effect position:** `[action([Stdout])]` →
  `TApp(TVar("action"), TLabels({Stdout}))`; arguments are bracketed effect terms
  and curried, so `[action([Stdout], [FileSystem])]` →
  `TApp(TApp(TVar("action"), TLabels({Stdout})), TLabels({FileSystem}))`;
  `[Http, action([Stdout])]` unions the application with the label.

**Invariant to protect:** a term with no `TAbs` / `TApp` and no higher-kinded
free variables must format to **byte-identical** text vs. today
(`format(from_effect_set(s)) == format_effect_set(s)`). This keeps every
existing `.graded` file and fixture stable; it is a dedicated test, not an
assumption.

## Phasing — each phase keeps the suite green

| Phase | What | Risk |
| --- | --- | --- |
| **0. IR foundations** | `effect_term.gleam`: type, `normalize`, capture-avoiding `subst`, fuel guard, `from/to_effect_set`. Property + unit tests. No behavior change. | Low |
| **1. Migrate data model + boundary** | Switch `ParamBound` / `EffectAnnotation` / `TypeField*` to `EffectTerm`; insert `to_effect_set` at the `is_subset` / KB boundary. Compiler exhaustiveness drives the edits. **Existing suite stays green** — proves the bridge is behavior-preserving before new capability. | Med |
| **2. Serialization** | Parse / format operator bounds and application terms; round-trip + byte-identity tests. | Med |
| **3. Infer** | Detect params typed `fn(fn(..)->_)->_` (girard signatures in `signatures.gleam` / `typeinfo.gleam` already expose this); build the `TAbs` body in `collect_effects`; emit the term-valued signature. | Med–high |
| **4. Resolve at call sites** | Rework `bind_variables` / `substitute_at_call_site` / `resolve_field_effect` to bind operator variables to `TAbs` arguments and beta-reduce, then normalize. The payoff phase. | High |
| **5. Semantics + docs** | `is_subset` for residual terms (conservative); remove the README limitation; THEORY note framing second-order effects as higher-kinded effect variables. | Low |

## Files touched

- **`effect_term.gleam`** *(new, ~280 LOC)* — IR, reduction, substitution, bridges, fuel guard.
- **`types.gleam`** — retype `ParamBound` / `EffectAnnotation` / `TypeField*` fields to `EffectTerm`; `EffectSet` + its ops unchanged.
- **`annotation.gleam`** — parse / format operator bounds + application terms; protect byte-identity.
- **`checker.gleam`** — phases 1, 3, 4: boundary conversion, scheme inference, operator-variable resolution.
- **`effects.gleam`** — KB stores / returns `EffectTerm`; reduces to `EffectSet` at the resolved lookup boundary.
- Tests + `test/fixtures/` — second-order fixtures; docs in phase 5.

## Risks & invariants

1. **Capture-avoidance** in `subst` — freshen bound names before substituting
   under a `TAbs`. Variables are param-named and controlled, so capture is rare
   but must be handled. Property-tested (see P-SUBST-3).
2. **Termination** — finite terms, no recursive *binding* within a function
   (call-graph recursion is already guarded by `visited`), so beta-reduction
   terminates. Backstop: a reduction **fuel** counter that bails to `[Unknown]`.
   Property-tested (see P-TERM-1).
3. **Round-trip byte-identity** for first-order lines (above) — dedicated test.
4. **Soundness of the stuck-term collapse** for `check` — centralized in
   `to_effect_set`, enforced in exactly one place. Property-tested (P-SOUND-1).

## Properties & invariants (qcheck)

This rewrite is dense with algebraic structure, so the test strategy leans
heavily on property-based testing with **`qcheck`** (already a dev dependency,
v1.0.4; existing generators live in `test/generators.gleam` and use the
`use x <- qcheck.given(gen)` pattern). We add an `effect_term_gen()` and the
properties below. Each `P-*` tag is a planned test.

### Generators

- `effect_term_gen()` — recursive, depth-bounded (seed a size budget with
  `qcheck.bounded_int` and decrement through recursion), mixing all six
  constructors. Two flavours:
  - **arbitrary** terms (may contain free vars and stuck applications) — for
    normalization, union-law, and termination properties;
  - **closed / well-kinded** terms (operators only applied to `Eff`-kind
    arguments, all variables bound) — for beta and soundness properties.
- `binding_gen()` — `Dict(String, EffectTerm)` over a small variable pool,
  reusing the existing variable names (`e`, `e1`, `e2`, `a`) plus operator
  names, so substitution domains actually overlap term variables often enough
  to exercise the interesting paths.

### Union forms a bounded semilattice (ties to THEORY.md)

Effects are sets under union; `normalize` must respect the lattice laws.

- **P-LAT-1 commutativity** — `normalize(TUnion([a, b])) == normalize(TUnion([b, a]))`.
- **P-LAT-2 associativity** — `normalize(TUnion([a, TUnion([b, c])])) == normalize(TUnion([TUnion([a, b]), c]))`.
- **P-LAT-3 idempotence** — `normalize(TUnion([a, a])) == normalize(a)`.
- **P-LAT-4 identity** — pure (`TLabels(∅)`) is the unit: `normalize(TUnion([a, TLabels(∅)])) == normalize(a)`.
- **P-LAT-5 top is annihilator** — `normalize(TUnion([a, TTop])) == TTop`.

### Normalization is a well-behaved normal form

- **P-NORM-1 idempotence** — `normalize(normalize(t)) == normalize(t)`.
- **P-NORM-2 stability** — a term already in normal form is returned unchanged.
- **P-NORM-3 ground agreement** — for any `EffectSet s`,
  `to_effect_set(from_effect_set(s)) == s` (the bridge preserves ground sets).

### Serialization round-trips

- **P-SER-1 byte-identity (back-compat)** — for any `EffectSet s`,
  `format(from_effect_set(s)) == format_effect_set(s)`. Protects every existing
  `.graded` file.
- **P-SER-2 term round-trip** — `parse(format(t)) == normalize(t)` for terms in
  normal form (extends the existing annotation round-trip property to the new
  syntax).

### Substitution & beta-reduction (the second-order core)

- **P-SUBST-1 empty is identity** — `subst(t, dict.new()) == t`.
- **P-SUBST-2 closed terms are fixed** — substituting into a term with no free
  variables is identity.
- **P-SUBST-3 no capture / no invention** — `free_vars(subst(t, σ)) ⊆
  (free_vars(t) \ dom(σ)) ∪ ⋃ free_vars(σ(x))`. Directly catches variable
  capture under `TAbs`.
- **P-SUBST-4 redex elimination** — for a closed, well-kinded term, `normalize`
  leaves no `TApp(TAbs(...), _)` redex anywhere in the result.

### Soundness (the checker must never hide an effect)

- **P-SOUND-1 over-approximation** — concrete labels never disappear under
  resolution: `concrete_labels(normalize(t)) ⊆ concrete_labels(normalize(subst(t, σ)))`
  for any binding `σ`. Substitution and reduction can only *add* effects (or
  reveal `Unknown`), never silently drop one. This is the key safety invariant
  behind stuck → `[Unknown]`.
- **P-SOUND-2 subset reflexivity** — `is_subset(s, s)` for `s = to_effect_set(t)`.
- **P-SOUND-3 union upper bound** — `is_subset(to_effect_set(a), to_effect_set(TUnion([a, b])))`
  and symmetrically for `b` (monotonicity of union).

### Termination

- **P-TERM-1 fuel is never exhausted on finite terms** — for every generated
  term, `normalize` completes within the fuel bound. Acts as a fuzz test for the
  termination argument; any exhaustion is a bug to surface, not to swallow.
