# assay

> Test the composition of your Gleam programs.

**assay** is a parallel proof and annotation language for [Gleam](https://gleam.run/) that uses graded modal types to verify properties your type system can't reach — effects, resource linearity, data privacy, and capability permissions.

It's designed to be written and checked by LLM agents as part of an agentic development harness, while your Gleam code stays clean and human-readable.

## The problem

Gleam's type system is deliberately simple. That's a strength — it keeps code approachable. But it means the compiler can't catch certain classes of bugs:

- A Lustre `view` function that accidentally performs side effects
- A database connection that's opened but never closed
- User PII that leaks across module boundaries
- A handler that calls admin-only functions without authorization

These are all **graded properties** — they're not about *what* a value is, but *how* it's used: how many times, with what effects, at what privacy level, with what permissions.

## The idea

Instead of making Gleam's type system more complex, assay adds a **sidecar specification layer**. You write Gleam. Assay annotations live alongside your code (in structured comments or `.assay` files) and describe the graded properties of your functions:

```
-- example.assay

@algebra Effect = set {Pure, Stdin, Stdout, Http, Db}
@algebra Usage  = nat

@sig read_name : UserInput [Usage: 1] -> String [Effect: {Stdin}]
@sig render    : Model -> Html [Effect: {Pure}]
```

A checker verifies that your Gleam implementation is consistent with these annotations. An LLM agent can generate, maintain, and verify the annotations as part of a CI pipeline or development workflow.

## Design principles

1. **One annotation language, multiple checkers.** The annotation syntax is parametric over the grading algebra. Effects use sets, linearity uses natural numbers, privacy uses lattices — but the syntax and core checker architecture are shared.

2. **For agents first, humans second.** The annotations are meant to be machine-written and machine-read. Humans can read them, but the primary consumer is an LLM agent that reasons about your codebase.

3. **Incremental adoption.** Annotate the modules that matter. The checker verifies what's annotated and ignores the rest.

4. **Sound foundations.** The theory is graded modal type theory, as developed in [Granule](https://granule-project.github.io/) and the coeffect literature. We're not inventing new type theory — we're building engineering on top of proven foundations.

## Roadmap

### Phase 1: Foundations
- [ ] Gleam AST parsing — read Gleam source and extract function signatures, call graphs, module structure
- [ ] Annotation language design — formal grammar for `.assay` files
- [ ] Core grading framework — the algebra-parametric checker infrastructure

### Phase 2: Effect checker
- [ ] Effect algebra implementation (set semiring)
- [ ] Effect inference from Gleam call graphs
- [ ] Lustre architecture rules (view must be Pure, effects only via Effect return channel)
- [ ] CLI tool: `assay check --effects`

### Phase 3: Linearity checker
- [ ] Usage algebra implementation (natural number semiring)
- [ ] Resource tracking through Gleam's pattern matching and let bindings
- [ ] CLI tool: `assay check --linearity`

### Phase 4: Privacy & capabilities
- [ ] Lattice-based grading for information flow
- [ ] Capability/permission checking
- [ ] CLI tool: `assay check --privacy`, `assay check --capabilities`

### Phase 5: Agent integration
- [ ] LLM prompt templates for annotation generation
- [ ] CI integration (GitHub Actions, etc.)
- [ ] Auto-inference mode: agent reads Gleam, proposes annotations, verifies them

## Research areas

This project requires research across several domains before implementation. See [RESEARCH.md](./RESEARCH.md) for the detailed breakdown.

## Theoretical foundations

- [Granule](https://granule-project.github.io/) — graded modal type theory in practice
- [Coeffects: a calculus of context-dependent computation](http://tomasp.net/academic/papers/structural/coeffects-icfp.pdf) — Petricek et al.
- [Combining effects and coeffects via grading](https://www.cs.kent.ac.uk/people/staff/dao7/publ/combining-effects-and-coeffects-icfp16.pdf) — Gaboardi et al.
- [Bounded Linear Logic](https://www.sciencedirect.com/science/article/pii/030439759290386T) — Girard et al.
- [Quantitative program reasoning with graded modal types (ICFP 2019)](https://www.cs.kent.ac.uk/people/staff/dao7/publ/granule-icfp19.pdf) — Orchard et al.

## License

TBD
