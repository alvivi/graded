# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Second-order (higher-kinded) effect variables.** The effect representation moved from a flat `Polymorphic(labels, variables)` set to an `EffectTerm` — a small lambda-calculus-with-union (labels, union, variables, abstraction, application), with `EffectSet` as its ground normal form. This lets graded express and resolve effect variables of kind `Eff → Eff` (operators), not just flat `Eff`:
  - A parameter whose own type takes one or more functions (`action: fn(fn() -> Nil) -> a`, or `fn(fn() -> _, fn() -> _) -> _`) is detected as an *operator* parameter; a call `action(cb1, cb2)` infers a **curried** effect-operator **application** `[action([Stdout], [FileSystem])]` over every callback, in order — none is dropped.
  - At a call site, an operator-typed argument is lifted to an operator (curried over its callbacks) and the application **beta-reduces** to the concrete effect. **Named function references** (abstracting over their callback parameters), **inline closures** (analysing their bodies), **let-bound closures** (`let h = fn(cb) { … }; with(h)`), **`case`/`if` branches over function-like options** (`with(case c { True -> f  False -> g })`, lifted per-branch and **joined** — `(f ⊔ g)(cb) = f(cb) ⊔ g(cb)`), and **functions returned from a call** (`let h = pick_handler(); with(h)` — the producer's returned operator is inferred where the producer is defined and threaded through the knowledge base by the topological pass) are all lifted; an inline closure's parameters are bound while walking it, so calls to them aren't mistaken for unresolved local calls.
  - **Same-module** named functions passed as operator arguments resolve too — sibling functions aren't yet in the knowledge base during their module's inference pass, so they're analysed transitively (mirroring how same-module *calls* already resolve), rather than collapsing to `[Unknown]`.
  - The `.graded` syntax gained operator applications `[action([Stdout], [FileSystem])]` (each argument a bracketed effect term; arguments are curried and order-significant) and operator bounds `fn(a, b) -> [a, b]`; first-order lines are byte-identical to before.
- Resolution is pure-Gleam term reduction — capture-avoiding substitution, beta, and union normalization, fuel-guarded — with no external solver. The reduction laws, capture-avoidance, soundness (over-approximation), and termination are property-tested with qcheck. See [docs/second-order-effects.md](docs/second-order-effects.md).
- **More value flow resolves instead of `[Unknown]`.** Several shapes that previously degraded now carry effects precisely:
  - **Blocks resolve to their tail.** A returned, let-bound, branch-arm, or argument value that is a block (`{ let f = io.println; f }`) is classified by the expression it evaluates to.
  - **Returned operators cross modules and packages.** They're serialized into the spec file as `returns mod.fn : fn(cb) -> [cb]` lines and loaded from the project spec and dependency specs — so `check` (not just `infer`) resolves a `let h = producer(); with(h)` across module and package boundaries.
  - **Record fields wired to an inline closure** (`Validator(to_error: fn(m) { io.println(m) })`) infer the field's effect from the closure body, with no hand-written `type` annotation.
  - **`check` auto-infers project modules missing from the spec**, in memory and in topological order, so a call into a not-yet-inferred module resolves instead of `[Unknown]`. Committed `effects` lines still take priority and nothing is written to disk.
  - **Operator-typed record fields** — a field wired to a closure that calls its own callback (`Middleware(wrap: fn(next) { next() })`) is lifted to an operator `λnext. [next]` and applied at the field call, so `m.wrap(io.println)` resolves to `[Stdout]`.
  - **Return-effect polymorphism** — a returned operator may be polymorphic in the producer's parameters; a producer that returns one of its own operator parameters (`fn wrap(base) { base }`) resolves, binding the parameter to the producer call's argument.

### Notes

- The remaining inference residuals — all sound, collapsing to the conservative `[Unknown]` — are: a **decorator** that returns a closure *wrapping* its parameter (`fn traced(action) { fn(cb) { action(cb) } }`) — the returned operator resolves at the consumer, but a producer that returns a closure has that closure's body over-approximated into its own direct call-effect, which may add `[Unknown]`; a field wired to a **constructor parameter** (inter-procedural value flow); a function value reached through **arbitrary computation** (`handlers |> list.first |> unwrap`); a **`use`-tailed** return; and **external/FFI** code (use `external effects`). Annotate explicitly or widen the budget where needed.

## [0.6.0] - 2026-04-21

### Added

- **Same-function value flow.** graded now tracks three kinds of local `let` bindings inside a function body and resolves calls through them:
  - **Function-ref aliases.** `let f = io.println; f("hi")` resolves to `gleam/io.println` instead of being treated as a local call. Transitive aliases (`let g = f`) resolve through the chain.
  - **Record construction.** `let v = Validator(to_error: io.println); v.to_error("oops")` resolves the field call to `io.println` directly — no per-type annotation needed for the common case of local construction. Both labelled (`Validator(to_error: ...)`) and positional (`Validator(...)`) construction work for same-module constructors; positional arguments are mapped to the constructor's declared labels.
  - **Shadowing.** Later `let`s correctly shadow earlier bindings; unrecognisable RHS expressions erase tracking so stale bindings don't leak forward.
- Block and closure bodies inherit the outer env but their own bindings don't leak out, matching Gleam's scoping.

### Notes

- Cross-function record construction (passing a record built in one function to another) remains opaque and still needs type-level annotations (`type myapp.Foo.field : [...]`). Pattern destructuring and `use`-bound names are deliberately treated as opaque.

## [0.5.0] - 2026-04-13

### Added

- **Effect polymorphism.** Effect variables (lowercase tokens inside brackets) let one signature express that a function propagates whatever effects its callback has:

  ```
  effects myapp/validation.validate_range(to_error: [e]) : [e]
  effects myapp.map_with_log(f: [e]) : [Stdout, e]
  ```

  `graded infer` produces polymorphic signatures automatically when a function calls a parameter annotated with a `fn(...) -> ...` type. The variable is named after the parameter.
- **Call-site substitution.** At each call site, effect variables bind to the concrete effects of the argument passed: a function reference resolves via the knowledge base, a type constructor is pure, the caller's own bounded parameter uses that bound's effects, and anything else falls back to `[Unknown]`. Works with both labeled (`validate_range(42, to_error: OutOfRange)`) and positional (`validate_range(42, OutOfRange)`) arguments. Covers cross-module calls, same-module local helpers, and calls into dependencies.
- **Dependency parameter positions.** graded now parses each `build/packages/<dep>/src/` tree with glance to learn dependency function signatures. Positional arguments to polymorphic dep functions resolve correctly without requiring labels.
- **Wildcard `[_]`.** Documented in the README's new Effect set syntax section. Wildcard is the top of the effect lattice — `[_]` as a declared budget permits any effects. Useful for entrypoints.

### Changed

- Violation messages now include a hint when the actual effects contain unresolved effect variables, suggesting a `check` bound or a concrete argument to bind against.

## [0.4.2] - 2026-04-12

### Fixed

- Added `gleam/dynamic/decode` to the `gleam_stdlib` catalog. Decoder combinators (`field`, `optional_field`, `string`, `int`, `list`, `dict`, `success`, etc.) are pure but were resolving as `[Unknown]`.
- `graded infer` now resolves cross-module type constructors as pure, matching the existing handling for unqualified constructors. Previously, calls like `types.NotFound(id)` from a sibling project module were marked `[Unknown]` because constructors aren't tracked in the knowledge base and the defining project module isn't in `pure_modules`. Constructors are pure by Gleam's syntactic rules — an uppercase-initial label after a `.` is always a type variant — so the qualified call, qualified pipe target, and qualified value-position branches in the extractor now short-circuit the same way the unqualified path does. Side-effecting expressions inside a constructor's argument list (e.g. `NotFound(io.println(x))`) still propagate.

## [0.4.1] - 2026-04-11

### Fixed

- `graded infer` now reads the spec file's `external effects` and `type` field declarations into the knowledge base before walking the import graph. Previously these were only consumed by `graded check`, so functions calling into a third-party module declared pure via `external effects` were still inferred as `[Unknown]`. The `check` pass passed but the inferred spec stayed noisy.

## [0.4.0] - 2026-04-10

### Added

- `[tools.graded]` config table in `gleam.toml`, with `spec_file` and `cache_dir` fields.
- `graded/internal/topo` module: standalone topological sort over a string-keyed dependency graph, with property and unit tests.

### Changed

- Project annotations have moved out of `priv/graded/`. Each Gleam package now has a single **spec file at the project root** (default name `<package_name>.graded`, configurable via `[tools.graded].spec_file` in `gleam.toml`) holding the public-API effects, `check` invariants, `external effects` hints, and `type` field annotations. Per-module inferred effects (public + private) live in **`build/.graded/`** as a regenerable build cache (configurable via `[tools.graded].cache_dir`). Both locations are read by `graded check` and written by `graded infer`.
- Function names in the spec file use the **module-qualified form**: `myapp.view`, `myapp/router.handle_request`. Slashes for the module path, dot before the function name (same convention as `external effects`). Cache files continue to use bare names because each one is implicitly scoped to a module by its file location.
- Type field annotations gained the same qualification: `type myapp.Handler.on_click : [Dom]`. The bare form (`type Handler.on_click : [Dom]`) remains valid in cache files.
- Library authors who want their effect annotations to ship to consumers must add their spec file to `included_files` in `gleam.toml`. Without this, downstream packages will not see the library's effects (and will fall back to `[Unknown]` for its functions, unless the catalog covers them).
- No automatic migration from the old layout. To migrate an existing project: move every `effects`/`check`/`external`/`type` line out of `priv/graded/<module>.graded` into `<package_name>.graded` at the project root, prefixing each function name with its module path. Then run `graded infer` and delete the old `priv/graded/` directory.

## [0.3.0] - 2026-04-07

### Added

- Cross-module effect propagation: inferred effects from sibling project modules are used when analyzing other modules in the same project. Two-pass inference resolves inter-module dependencies.

## [0.2.0] - 2026-04-07

### Added

- Catalog entry for `gleam_time` (all modules pure; `system_time`, `local_offset`, `utc_offset` marked `[Time]`).
- Catalog entry for `houdini` (fully pure).
- Automatic effect inference for path dependencies declared in `gleam.toml`. Functions from local path deps are now inferred from source instead of being marked `[Unknown]`.
- Path dependency inference loads existing `.graded` files for parameter bounds, improving accuracy for higher-order functions.
- Two-pass inference for path dependencies so cross-dep calls resolve correctly.

### Fixed

- Record constructors (`Ok`, `Error`, `Some`, custom types) no longer inferred as `[Unknown]`. Gleam constructors start with an uppercase letter and are always pure.

## [0.1.0] - 2025-04-04

### Added

- Effect checker for Gleam via sidecar `.graded` annotation files.
- `graded check` command to enforce `check` annotations.
- `graded infer` command to infer and write `effects` annotations.
- `graded format` command with `--check` and `--stdin` modes.
- Higher-order effect tracking with parameter bounds.
- Field call effect tracking with type-aware resolution.
- External effect declarations for third-party functions.
- Wildcard effect `[_]` as the universal top element.
- Warnings for function references passed as values with known effects.
- Versioned catalog system resolved against `manifest.toml`.
- Catalog entries for `gleam_stdlib`, `gleam_erlang`, `gleam_otp`, `gleam_http`, `gleam_httpc`, `gleam_json`, `gleam_regexp`, `gleam_yielder`, `gleam_crypto`, `lustre`, `lustre_http`, `simplifile`, `filepath`, `tom`.
