# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- A let-bound closure that is *called directly* (`let helper = fn(x) { ... }; helper(1)`) now resolves to its body's effect instead of `[Unknown]`. The extractor tracked the binding and resolved it when the closure was *passed* to a higher-order parameter, but a direct application by name fell through to an unresolved local call, so the common idiom of defining a reusable builder as `let row = fn(...) { ... }` and mapping it over a list cascaded to `[Unknown]` and blocked a `check view : []` invariant. The closure body is analysed at its binding site, where the lexical environment resolves any captured callable (`let suffix = string.append; let h = fn(x) { suffix(x) }`), and the direct application adds the effect of each argument the closure actually invokes; a directly-applied `case`-of-functions resolves the same way.

## [0.9.3] - 2026-06-23

### Fixed

- A same-module (unqualified) call into a bodyless `@external` now applies its `external effects` declaration, matching the cross-module (qualified) call path. The local-call path resolved opaque externals straight to `[Unknown]` without consulting the knowledge base, so a declared `external effects` entry took effect only for callers in other modules; the common FFI idiom of an `@external` binding plus a same-module wrapper cascaded to `[Unknown]`. Undeclared externals still resolve to `[Unknown]`.

## [0.9.2] - 2026-06-23

### Fixed

- Record update expressions (`Rec(..base, field: expr)`) now have their updated field values walked, so effects in those expressions are counted. Previously only the base record was extracted, under-approximating the effect set and letting a `check ... : []` pass over a record update whose field called an effectful function.
- Dependency, catalog, and path-dependency resolution now read from the checked project's own root (`build/packages`, `manifest.toml`, and the path-dep `gleam.toml`), found by walking up from the source directory to the nearest `gleam.toml`. Previously these paths were resolved relative to the process working directory, so checking a project from a different directory loaded the wrong dependency specs, installed versions, or path dependencies.
- A higher-order function defined in a **path dependency** now discharges its callback parameter's effect at the call site, instead of leaking the parameter's effect variable (e.g. `[on_change]`) into the caller. Path dependencies are loaded through a separate code path that recorded each callee's effects but dropped its polymorphic parameter bounds, and never registered the dep's parameter signatures — so neither labelled nor positional callback arguments could be matched. The path-dep loaders now thread parameter bounds and returned-operator signatures into the knowledge base and register path-dep signatures, reaching parity with `build/packages` dependencies. The identical function defined in-project was already handled.
- graded now compiles and runs on the JavaScript target by providing JavaScript externals for the built-in FFI used by `format --stdin` and process halting.

## [0.9.1] - 2026-06-23

### Added

- Added catalog entries for the pure value libraries `bigi`, `glearray`, `iv`, and `gleam_community_maths` — calls into them now resolve to `[]` instead of `[Unknown]`.

### Fixed

- A higher-order callback passed with a Gleam label (`apply(with: parser)`) now binds to its parameter, so the parameter's effect variable resolves instead of leaking into the fully-applied caller. Previously only positional callback arguments were matched; a labelled call site left the variable unresolved (e.g. `[parser]`).

## [0.9.0] - 2026-06-22

### Added

- **Field bounds.** A `check` line can bound a function-typed field reached through a parameter, using a `param.field` path: `check myapp.view(handler.on_click: [Dom]) : [Dom]`. The field call resolves to the declared effect, taking priority over receiver-type resolution — the boundary-scoped counterpart to a `type` line, for a receiver graded can't trace to a construction site.
- A field bound whose `param.field` path matches no field call in the checked function's body now emits a warning, catching typos in the path that would otherwise resolve nothing silently. When the receiver is not a parameter, the warning also notes the call may have resolved through value provenance, which shadows the bound, rather than blaming the path.
- A plain parameter bound whose name matches no declared parameter now emits a warning. It is matched on parameter existence, not call presence, so a callback that's forwarded but never called directly is not flagged.

### Fixed

- **`gleam/time/calendar.utc_offset` is now `[]` instead of `[Time]`.** It is a compile-time constant (`duration.empty`), not a clock or timezone read, so it carries no effect. `calendar.local_offset` and `timestamp.system_time` remain `[Time]`.
- **A same-module named function passed to a first-order fn-typed parameter now resolves to its actual effect instead of `[Unknown]`.** `parse_optional("x", logging_parser)` binds the parameter to `logging_parser`'s effect — so a fully-applied caller is no longer polluted by an unresolved effect variable from a higher-order callee. Inline closures already resolved; named references now take the same lift-and-discharge path operator arguments have used since 0.7.0.

## [0.8.1] - 2026-06-22

### Changed

- **Dropped the `stdin` and `gleam_yielder` dependencies.** `graded format --stdin` now reads standard input through a small built-in Erlang FFI. The `stdin` package capped `gleam_stdlib` below `1.0.0`, which made graded uninstallable alongside packages that require `gleam_stdlib >= 1.0.0`.

## [0.8.0] - 2026-06-21

### Added

- **Catalog entries for 27 more of the most-used Gleam packages.** Calls into these now resolve to a precise effect (or `[]` for pure libraries) instead of `[Unknown]`: glance, glexer, justin, snag, ranger, marceau, gleam_community_colour, gleam_community_ansi, glam, splitter, gleam_bitwise, gleam_javascript, and gleam_deque (pure); glisten, mist, wisp, pog, gleam_fetch, gleam_hackney, gleam_cowboy, gleam_elli, shellout, logging, argv, directories, birl, and youid (effectful).
- **The catalog now covers all of the core `gleam-lang` runtime, data, and HTTP packages.** The two remaining official packages, `gleam_package_interface` and `gleam_hexpm`, are tooling libraries and stay uncatalogued for now.
- **New effect labels `Network`, `Database`, `Exec`, and `Random`** for socket/server I/O (glisten, mist), database queries (pog), running external programs (shellout), and nondeterministic generation (youid v4/v7, `wisp.random_string`).

### Fixed

- When a function appears in both an installed dependency's spec file and the bundled catalog, its effects now come from the dependency's spec file.
- Effects performed inside `panic`/`todo`/`echo` messages and bit-string segments are now counted toward a function's effects.
- `graded format` and `graded format --check` now report an error on a `.graded` spec file that cannot be parsed, instead of succeeding silently. A missing spec file is still treated as nothing to do.
- A malformed `gleam.toml` is now reported as an error instead of being silently ignored. A missing `gleam.toml` still falls back to defaults.

## [0.7.0] - 2026-06-19

### Added

- **Second-order (higher-kinded) effect variables.** The effect representation moved from a flat `Polymorphic(labels, variables)` set to an `EffectTerm` (a lambda-calculus-with-union), letting graded express and resolve effect variables of kind `Eff → Eff` (operators), not just flat `Eff`.
  - An operator parameter (one whose type takes functions, `action: fn(fn() -> Nil) -> a`) infers a curried application `[action([Stdout], [FileSystem])]` over every callback, in order.
  - At a call site, operator arguments beta-reduce to concrete effects. Named refs, inline/let-bound closures, `case`/`if` branches (joined per-branch), and operators returned from calls are all lifted.
  - Same-module named functions passed as operator arguments resolve transitively instead of collapsing to `[Unknown]`.
  - The `.graded` syntax gained operator applications and operator bounds (`fn(a, b) -> [a, b]`); first-order lines are byte-identical to before.
- Resolution is pure-Gleam term reduction (capture-avoiding substitution, beta, union normalization, fuel-guarded), no external solver. Laws, soundness, and termination are property-tested with qcheck. See [docs/SECOND_ORDER_EFFECTS.md](docs/SECOND_ORDER_EFFECTS.md).
- **More value flow resolves instead of `[Unknown]`.**
  - **Blocks resolve to their tail** — a block value (`{ let f = io.println; f }`) is classified by the expression it evaluates to.
  - **Returned operators cross modules and packages** via `returns mod.fn : fn(cb) -> [cb]` lines, so `check` resolves `let h = producer(); with(h)` across boundaries.
  - **Record fields wired to an inline closure** infer the field's effect from the closure body, no `type` annotation needed.
  - **`check` auto-infers project modules missing from the spec** (in memory, topological order); committed `effects` lines still win and nothing is written to disk.
  - **Operator-typed record fields** — a field wired to a closure calling its own callback (`Middleware(wrap: fn(next) { next() })`) is lifted to an operator and applied at the field call.
  - **Return-effect polymorphism** — a producer that returns or wraps an operator parameter (a decorator) resolves, binding the parameter to the call's argument. Returned closures are lazy, so they're excluded from the producer's own direct effect.
- **`Environment` effect + envoy catalog entry.** Process env-var access is now a first-class effect via `priv/catalog/envoy@1.0.0.graded`, mapping `envoy.get`/`set`/`unset`/`all` to `[Environment]` instead of `[Unknown]`.

### Fixed

- **`@external` (FFI) functions are now `[Unknown]` by default.** Foreign code is opaque, so an `@external` function infers `[Unknown]` instead of the `[]` an empty or fallback body would yield — even with a Gleam fallback, since it only runs on the other compile target. Opt into a precise effect with `external effects mod.fn : [...]` (or the catalog), which wins at resolution and drops the inferred line.
- **Field calls on a record built at several construction sites no longer leak operator bounds.** A function-typed field gets a *union* of operators (one per construction site); the resolver previously returned it raw, leaking bounds into first-order callers. The union is now applied to the call's arguments and distributes (`(L ⊔ f ⊔ g)(args) = L ⊔ f(args) ⊔ g(args)`). Always sound, but the leaked bounds weren't round-trip parseable.
- **`infer` no longer hangs on densely mutually-recursive modules.** Per-callee body analysis is now memoized per module, and the call graph is partitioned into SCCs (Tarjan's): first-order components collapse to one shared effect set, polymorphic callees are keyed by name plus same-component ancestors. First-orderness is decided syntactically (not via the best-effort type annotator) for stable results. Results unchanged — only speed: three corpus packages that timed out now infer in 1–5s.

### Notes

- Remaining residuals (all sound, collapsing to `[Unknown]`): a parameter selected through a **branch**, a field wired to a **constructor parameter**, a function reached through **arbitrary computation** (`handlers |> list.first |> unwrap`), a **`use`-tailed** return, and **external/FFI** code. Annotate explicitly where needed.

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

[0.9.3]: https://github.com/alvivi/graded/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/alvivi/graded/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/alvivi/graded/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/alvivi/graded/compare/v0.8.1...v0.9.0
[0.8.1]: https://github.com/alvivi/graded/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/alvivi/graded/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/alvivi/graded/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/alvivi/graded/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/alvivi/graded/compare/v0.4.2...v0.5.0
[0.4.2]: https://github.com/alvivi/graded/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/alvivi/graded/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/alvivi/graded/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/alvivi/graded/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/alvivi/graded/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/alvivi/graded/releases/tag/v0.1.0
