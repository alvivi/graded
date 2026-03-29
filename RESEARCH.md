# Research Plan

This document breaks the assay project into research areas. Each area needs investigation before implementation.

## 1. Gleam AST and tooling

**Question:** How do we parse and analyze Gleam source code programmatically?

- Does Gleam expose its AST via a library? (There's a `glance` parser on the package registry)
- What information do we need from the AST? (function signatures, call graphs, pattern matches, let bindings, module imports)
- Can we work at the source level, or do we need the compiled BEAM bytecode?
- What language do we write assay itself in? (Gleam? Rust? Haskell? — tradeoffs around ecosystem access vs. type theory tooling)

**Deliverable:** A prototype that parses a Gleam module and extracts its call graph.

## 2. Annotation language design

**Question:** What does the `.assay` annotation syntax look like?

- Study Granule's syntax for graded modalities
- Study Liquid Haskell's annotation approach (refinement types in comments)
- Study RefinedTypescript and other "sidecar specification" systems
- Design a grammar that is algebra-parametric: the same syntax shape works for sets (effects), naturals (usage), and lattices (privacy/capabilities)
- Decide on inline comments vs. sidecar files vs. both
- How do annotations reference Gleam constructs? (by function name? by module path?)

**Deliverable:** A formal grammar (BNF or PEG) for the annotation language, with examples for all four checker domains.

## 3. Graded modal type theory — core formalism

**Question:** What's the minimal type theory we need to implement?

- Read Orchard et al. ICFP 2019 paper on Granule closely
- Understand the bidirectional type checking algorithm
- Understand how grading algebras (semirings, lattices) plug into the checker
- Do we need the full generality of Granule's type theory, or can we get away with a simpler fragment?
- How does polymorphism over grades work? (Do we need it for Gleam, or are monomorphic grades enough?)
- What role does the SMT solver (Z3) play? Do we need one, or are our algebras simple enough for direct computation?

**Deliverable:** A document describing the core typing rules we'll implement, with the Granule rules as reference and notes on what we simplify.

## 4. Effect system design

**Question:** How do we model and check effects for Gleam programs?

- What effects matter for Gleam/BEAM? (IO, Http, Db, Timer, Process spawning, file system, Stdin/Stdout)
- How do effects compose in Gleam? (sequential composition = union of effect sets)
- How do we handle the boundary between Gleam and Erlang FFI? (FFI calls are effect-opaque — need annotations)
- Study how effect systems work in Koka, Frank, Eff, and Haskell
- For Lustre specifically: what are the exact architectural rules? (view = Pure, update = may return Effects, init = may return Effects)
- How do we handle effect polymorphism? (a `map` function shouldn't fix its effect — it should inherit from the function argument)

**Deliverable:** A specification of the effect algebra and checking rules for Gleam, with Lustre as the first test case.

## 5. Linearity and resource tracking

**Question:** How do we track resource usage in a language that doesn't enforce it?

- Gleam is immutable, which helps — no aliasing problems
- But Gleam has no linearity enforcement — values can be silently dropped or used multiple times
- How do we track "this file handle must be closed exactly once" in an annotation?
- Study Rust's ownership model, Linear Haskell, and Granule's bounded usage
- How does the BEAM's garbage collection interact with resource linearity? (finalizers? process exit cleanup?)
- What's the right granularity? Per-function? Per-module? Per-process lifecycle?

**Deliverable:** A specification of the usage algebra and examples of resource linearity annotations for common Gleam patterns (file handles, DB connections, OTP process state).

## 6. Privacy and capability lattices

**Question:** How do we model information flow and permissions?

- Study Jif (Java Information Flow), FlowCaml, and other information flow systems
- Study capability-based security (E language, Pony's reference capabilities)
- What lattice structures make sense for Gleam applications? (Public/Private? User/Moderator/Admin? Custom per-project?)
- How do we handle declassification? (sometimes you intentionally downgrade a private value — the annotation needs to mark this explicitly)
- Can we reuse the same lattice checker for both privacy and capabilities, or do they need different rules?

**Deliverable:** Lattice checker specification with examples for both privacy and capability use cases.

## 7. LLM integration and agent workflow

**Question:** How does an LLM agent use assay effectively?

- What prompt templates produce good annotations from Gleam source?
- Can an LLM reliably infer effect annotations? (likely yes — it's essentially reading code and listing what IO it does)
- Can an LLM reliably infer linearity annotations? (harder — requires tracking value flow)
- What's the feedback loop? (agent proposes annotations → checker verifies → agent corrects if wrong)
- How do we handle false positives? (the checker says violation, but the code is actually fine — the annotation was wrong)
- Multi-model approach: one model generates annotations, a different model (or the checker) verifies?

**Deliverable:** A prototype workflow: LLM reads a Gleam Lustre module → generates effect annotations → checker verifies → report.

## 8. Existing tools and prior art survey

**Question:** What already exists that we can build on or learn from?

- Granule itself — can we use it as a backend or reference implementation?
- Stainless (Scala formal verification)
- Liquid Haskell (refinement types for Haskell)
- RefinedTypescript
- Codeql and Semgrep (for the "sidecar analysis" pattern)
- Gleam's own tooling: `gleam fix`, the formatter, the LSP — how do they parse and analyze code?
- Are there any existing Gleam linters or static analysis tools?

**Deliverable:** A survey document summarizing what exists, what we can reuse, and what we need to build from scratch.

## Suggested research order

1. **Existing tools survey** (#8) — know what's out there before building
2. **Gleam AST and tooling** (#1) — can we parse Gleam? this gates everything
3. **Effect system design** (#4) — first checker target, most immediate value
4. **Annotation language design** (#2) — informed by what we learn from #1 and #4
5. **Core formalism** (#3) — informed by what we learn from #4
6. **Linearity** (#5) — second checker
7. **Privacy and capabilities** (#6) — third and fourth checkers
8. **LLM integration** (#7) — runs in parallel with everything, start prototyping early
