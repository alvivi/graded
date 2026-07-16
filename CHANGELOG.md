# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Upgraded girard to 2.0.0 and glance to 7.0.0.** girard's `Type` now lives in the single `girard` module (`girard/types` was removed upstream), and glance 7 parses arithmetic in bit-array pattern segment sizes, so modules using that form now extract and type instead of failing to parse and collapsing to `[Unknown]`.
- **The glinter lint gate is temporarily disabled.** glinter pins glance below 7.0.0, which conflicts with girard 2.0.0; the dev dependency and CI step return once glinter allows glance 7.x.

### Fixed

- **A computed receiver whose helper returns one of its parameters now forwards field effects instead of collapsing to `[Unknown]`.** When the receiver argument is a call to a straight-line helper that returns a parameter (`inner(id_options(o))`), a parameter-rooted receiver path (`inner(get_options(config))` returning `config.options`), or a constructor rebuilt from parameter-rooted fields (`inner(normalize(o))` returning `Options(resolver: o.resolver)`), graded resolves the helper's return-value provenance and substitutes the call's arguments into it, then re-keys the callee's field-effect variable through the resulting value exactly as an inline receiver would. Both a same-module private helper (resolved on demand from its source) and a public cross-module one (threaded through the knowledge base) resolve. A helper whose return is itself a non-self call, or an external with no visible body, stays `[Unknown]`, as does any argument that can't be grounded to a caller parameter — provenance widens to Top on every shape it can't trace.
- **A computed receiver whose helper returns a `case`/`if` now forwards through every branch instead of collapsing to `[Unknown]`.** When the helper's return is a `case`/`if` whose branches are all parameter-rooted — a bare parameter (`True -> a`), a receiver path (`True -> a.options`), or a record rebuilt from a parameter-rooted field (`True -> Options(resolver: a.resolver)`) — graded folds the branches into a join provenance, grounds each against the call's arguments, and unions the re-keyed field effects; branches that all pass the same parameter collapse to that one passthrough. A join with any branch it can't trace — a literal, a call — still widens the whole receiver to `[Unknown]`.
- **A computed receiver whose helper rebuilds a record from a mix of parameters and literal defaults now forwards the parameter-rooted fields.** A rebuild that wires a fn-typed field from a parameter alongside a literal default (`Options(label: "", resolver: o.resolver)`) keeps the parameter-rooted field in the build provenance and drops the untraceable one, so `o.resolver` forwards while the default contributes nothing — where before any non-parameter field collapsed the whole build to `[Unknown]`. The build stays opaque only when no field is parameter-rooted.
- **A computed receiver whose helper builds its record with field shorthand now forwards the parameter-rooted fields.** A smart constructor written in the idiomatic Gleam form (`Options(resolver:)`, sugar for `resolver: resolver`) previously produced no return-value provenance: every shorthand field was treated as opaque, collapsing the whole build so `o.resolver` stayed `[Unknown]`. The shorthand field now resolves to the parameter it puns, exactly as a shorthand call argument already did, so a helper like `fn make(resolver) { Options(label: "", resolver:) }` forwards `resolver` through `inner(make(resolver))` and a `caller(resolver: [Stdout]) : []` bound discharges it.
- **A labeled computed-receiver call now grounds by reordering its arguments into parameter order.** A call that labels its arguments (`inner(rebuild(with: Options(resolver: resolver)))`) previously widened because provenance positions index the parameter list; graded now reorders the labeled arguments into declared parameter order through the callee's signature before substituting, so a labeled call forwards exactly as a positional one. A labeled call whose callee has no known signature still widens.
- **A computed receiver whose helper returns a parameter through tail recursion now resolves by fixpoint.** `inner(pick(True, o))` where `pick` returns `o` through a `case` branch that recurses (`False -> pick(True, o)`) previously widened because a return that is itself a call is opaque; graded now traces direct self-recursion with a bounded fixpoint that grounds the recursive call through the function's own provenance estimate until it converges. A cycle that doesn't converge within the bound, a record rebuilt through the recursion, or mutual recursion still widens to `[Unknown]`.
- **A path dependency inferred from source now propagates its return-value provenance to the consumer.** When a path dependency ships no committed spec, graded infers it from source; that inference's return-value provenance is now threaded out alongside the effects, parameter bounds, and returned-operator signatures and folded into the consumer's knowledge base. A consumer's computed-receiver call into such a dependency (`dep.inner(dep.get_options(config))` where `dep.get_options` returns `config.options`) forwards the field effect instead of collapsing to `[Unknown]`, matching how same-package modules already resolve. A committed dependency spec and the versioned catalog do not carry provenance, so a computed receiver into a spec-backed or catalogued dependency stays `[Unknown]`.
- **Forwarded function-typed field effects now stay polymorphic across direct helper calls.** When a caller passes one of its own parameters directly to a callee, a field-effect variable from the callee is re-keyed onto the caller's parameter path (`inner(options)` forwards `o.resolver` as `options.resolver`). Unbound forwarded fields still collapse to `[Unknown]` at check time, while a caller field bound such as `options.resolver: [Stdout]` discharges the forwarded effect.
- **Field effects also forward through a receiver path rooted at a caller parameter.** When the receiver argument is a field path on one of the caller's own parameters (`inner(config.options)`), the callee's field-effect variable is re-keyed onto the whole path, so `o.resolver` forwards as `config.options.resolver` and a nested `o.inner.run` as `config.options.inner.run`. A bound such as `config.options.resolver: [Stdout]` discharges it; left unbound it collapses to `[Unknown]`. A computed (`inner(make())`) receiver stays conservative.
- **Field effects also forward through an inline constructor or factory call argument.** When the receiver argument is an inline constructor (`inner(Options(resolver: resolver))`) or factory call (`inner(make_options(resolver))`) whose field is wired from one of the caller's own parameters, the callee's field-effect variable re-keys onto that parameter, so `o.resolver` forwards as the caller's bare `resolver` and a `caller(resolver: [Stdout]) : []` bound discharges it. Positional, labeled, and shorthand (`make_options(resolver:)`) wiring all route. A field built at several sites — one wiring the parameter, another wiring an effect-polymorphic function — forwards the parameter site while the other resolves independently, rather than the sibling site regrounding the forward to `[Unknown]`. Opaque-factory (`inner(default_options())`) and computed receivers stay conservative and fall back to `[Unknown]`.
- **Field effects also forward through a let-bound alias of the receiver.** A receiver bound to a `let` before the call now forwards exactly as the inline form does, because aliases are resolved eagerly at the binding: `let v = config.options; inner(v)` re-keys the callee's field var onto `config.options.…`, `let f = options; inner(f)` onto the parameter's own path, and `let o = make_options(resolver); inner(o)` / `let o = Options(resolver: resolver); inner(o)` through the constructor/factory wiring onto the caller's `resolver`. Construction nested one extra level forwards too (`inner(make_holder(make_options(resolver)))` traces both hops). A reassignment (`let o = …` again) or an alias bound from a computed call (`let o = get_options(x); inner(o)`) clears the provenance and stays `[Unknown]`, so a forwarded effect is never understated. Public `.graded` syntax is unchanged.
- **A called let-bound alias of a parameter resolves through the parameter, not the call-site name.** Calling an alias (`let f = handler; f(x)`) now emits a local call on the aliased path, so it resolves via the parameter's bound and shadows an unqualified import of the same name — matching a direct call to the parameter. Previously the alias name was resolved on its own, leaking to a same-named unqualified import or collapsing to `[Unknown]` and understating the parameter's effect.
- **A recursive function reached through a higher-order call resolves to its real effect instead of `[Unknown]`.** A recursion cycle hitting a higher-order analysis stack contributed the conservative `[Unknown]` fallback rather than the neutral effect, in two forms: a self- or mutually-recursive function handed to a higher-order helper by reference (`list.flat_map(children, walk)`) rather than as an inline closure, and a recursive producer whose branch returns a recursive producer call (`fn pick(n) { case n { 0 -> fn() { Nil } _ -> pick(n - 1) } }`). The recursive reference is already on the analysis stack, so it now contributes nothing — its own effects are captured by the frame analysing it — matching how cyclic local calls are already handled. A pure recursive tree walk, or applying a pure recursive producer, resolves to `[]`.
- **graded finds its bundled catalog regardless of the working directory.** The catalog was resolved relative to the process's current directory, so running graded from another project's directory (for example via an Erlang shipment) resolved to an empty catalog and collapsed every catalogued call to `[Unknown]`. The catalog is now located relative to graded's own install directory; when no catalog directory can be found at all, graded warns on standard error instead of degrading silently.
- **`infer` and `check` against an out-of-tree source directory root the spec and cache at the project, not the passed directory.** The project root is resolved by walking up to the nearest `gleam.toml`, so `graded infer ../other/src` writes `../other`'s spec and cache under its package name rather than scattering `../other/src/src.graded` and `../other/src/build/`. A relative source directory inside the current project whose only ancestor `gleam.toml` is the working directory still acts as its own root, so pointing graded at a subtree doesn't write into the surrounding project.

## [0.10.1] - 2026-06-26

### Fixed

- **A function-typed field on a dependency-defined type now resolves to its declared effect instead of `[Unknown]`.** When a receiver is typed by a dependency (`fn use(repo: dep/repo.Repo) { repo.find(..) }`), graded reads the dependency's source — a path dependency at its declared location, an installed dependency under `build/packages` — to type the receiver, so a module-qualified `type dep/repo.Repo.find : [Storage]` line resolves at the call site. Previously the receiver type was unresolved for path dependencies, and for installed dependencies whenever graded ran outside the package root, so the field call leaked `[Unknown]`.
- **A dependency now ships the effects of its own types' function fields.** `type` field annotations in a dependency's spec file, and in the versioned catalog, are loaded into the knowledge base alongside its `effects`/`external` entries, so a consumer resolves `receiver.field(..)` on a dependency-defined record without re-declaring it. A consumer's own `type` line wins on a clash; otherwise the priority follows the effect order (path dependency > installed dependency > catalog).

## [0.10.0] - 2026-06-25

### Added

- **Lustre 5 catalog.** A `lustre@5.0.0.graded` file covers the v5 surface — pure constructors (`application`, `simple`, `component`, `element`, …), the effectful runtime (`start`, `register`, `send`, …), and the element/attribute/event submodules. Lustre 5.x projects select it; 4.x projects keep `lustre@4.0.0.graded`.
- **`graded check` warns on spec lines that match nothing.** A `check` line whose name matches no project function (usually a missing module qualifier) never runs and passed silently — now flagged. A `type` line is flagged when it resolves no field: unqualified, pointing at an unknown module, or naming a non-function field. Callability follows type-alias chains across project and dependency modules. Fields on dependency-owned or unresolvable types are left alone. All warnings report against the spec file.
- **Function-typed record fields resolve polymorphically instead of `[Unknown]`.** A `fn`-typed field on a receiver with no traceable construction site (an opaque parameter) becomes a *field-effect variable* named for its `receiver.field` path. It discharges against a field bound (`check f(r.run: [Stdout]) : [..]`) or a `type myapp.Runner.run : [Stdout]` line, and surfaces as a polymorphic bound when inferred (`effects f(r.run: [r.run]) : [r.run]`); left unbound it concretizes to `[Unknown]`, never silently `[]`. Resolution follows the receiver's inferred type, so it covers nested receivers (`model.service.org.create(..)`) and nested pipe targets (`value |> o.inner.run`). Fields declared through a module-local function alias are recognized as callable.

### Fixed

- **A module-level `external effects <module>` declaration now governs a path dependency's inferred module, with its full effect set.** Previously the declared set was flattened to pure (so `dep.*` calls resolved to `[]`), and graded's own source-inference of the path dependency shadowed the declaration — leaving the module and its in-dependency callers at `[Unknown]`. The declaration now applies during the dependency's inference, so both resolve to the declared set. A per-function `external effects mod.fn` or an authoritative dependency spec/catalog effect still takes precedence.
- **A module-level external now governs the consumer's own project modules too.** A declaration for a project module (`external effects myapp/db : [Database]`) was shadowed by graded's in-memory inference of that module's source, so its functions resolved to the inferred effect rather than the declared set. The inferred call effect is now dropped for a declared module — at both `check` and `infer` time, so a sibling module calling into it agrees — and `graded infer` writes no per-function `effects` lines for it, matching how a per-function external suppresses its own line. Returned-operator and parameter-bound metadata are kept.

## [0.9.4] - 2026-06-24

### Fixed

- **A closure passed to a second-order parameter now keeps its captured callable bindings.** When a closure is lifted over an operator parameter (`with(fn(callback) { suffix("a", "b"); callback("hi") })`), its body is re-analysed away from where it was written; a name bound there (`let suffix = string.append`) was no longer in scope, so it resolved to `[Unknown]` and the closure's effect came out as `[Stdout, Unknown]` instead of `[Stdout]`. The closure now carries the callable bindings in scope at its creation site — a qualified alias, a let-bound closure, a `case`-of-closures, or a returned operator — so re-analysis resolves each to its precise effect. The capture respects shadowing (the binding visible where the closure was written wins) and excludes the closure's own parameters. The earlier direct-call fix already resolved captures for a closure *applied by name*; this extends the same precision to one *passed to a higher-order function*.
- **Expression-valued callees are no longer inferred pure.** An immediately invoked closure (`fn(cb) { cb("x") }(io.println)`), an applied returned function (`printer()("x")`), or a `case`/`if` that selects the function being called now propagates the callee's effect. Previously graded walked the callee as a value without modelling the application, so effectful code could be inferred as `[]` and slip past a `check ... : []` purity invariant. An opaque computed callee (`funcs.0(x)`) now resolves to `[Unknown]` rather than `[]`.
- **A parameter that shadows an unqualified import now resolves to the parameter, not the import.** With `import gleam/string.{uppercase}`, a function `run(uppercase: fn(String) -> String)` that calls or forwards `uppercase` binds to its parameter. Previously the import shadowed the parameter, so an effectful argument passed for a parameter named like a pure import could be inferred pure.
- A let-bound closure that is *called directly* (`let helper = fn(x) { ... }; helper(1)`) now resolves to its body's effect instead of `[Unknown]`. The extractor tracked the binding and resolved it when the closure was *passed* to a higher-order parameter, but a direct application by name fell through to an unresolved local call, so the common idiom of defining a reusable builder as `let row = fn(...) { ... }` and mapping it over a list cascaded to `[Unknown]` and blocked a `check view : []` invariant. The closure body is analysed at its binding site, where the lexical environment resolves any captured callable (`let suffix = string.append; let h = fn(x) { suffix(x) }`), and the direct application adds the effect of each argument the closure actually invokes; a directly-applied `case`-of-functions resolves the same way.
- **More higher-order closure patterns resolve to a precise effect instead of `[Unknown]`:** a callback closure with an ordinary value parameter (`fn(message) { io.println(message) }`); a callback that ignores a higher-order parameter (`fn(_next) { … }`); a producer whose returned closure captures or applies a first-order callback parameter; and an immediately invoked closure with more than one argument (every argument is applied, not only the first).
- An immediate application of a returned function (`make(io.println)()`) no longer drops the producer's arguments. An internal effect variable that can never be bound at a call site now collapses to the conservative `[Unknown]` instead of leaking into the inferred effect set.

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

[0.10.1]: https://github.com/alvivi/graded/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/alvivi/graded/compare/v0.9.4...v0.10.0
[0.9.4]: https://github.com/alvivi/graded/compare/v0.9.3...v0.9.4
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
