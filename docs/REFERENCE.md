# graded reference

This document is the reference for the `.graded` spec language. graded resolves
each function's effects — a set of string labels — and checks them against the
budgets you declare: an effect set passes when it is a subset of its budget.
Below: every annotation kind, the effect-set syntax, the resolution order, the
effect-label conventions, and the bundled catalog. For installation, project
layout, configuration, and the CLI, see the [README](../README.md); for how the
analysis works under the hood, see [How analysis works](#how-analysis-works) at the
end.

## The spec file and the cache

graded keeps two kinds of `.graded` file:

- **The spec file** (`<package_name>.graded` at the project root) uses
  **module-qualified** names — `myapp/router.handle_request`, with slashes for the
  module path and a final `.` before the function. It holds the inferred public-API
  effects plus your hand-written invariants, and it's the file you commit and
  (optionally) ship.
- **The cache** (`build/.graded/<module>.graded`) uses **bare** names because each
  file is implicitly scoped to one module by its location. It holds the inferred
  effects of *every* function, public and private, and is regenerated freely by
  `graded infer`. It's gitignored and never ships.

## Annotation kinds

Five kinds of line appear in a spec file.

### `effects` — inferred effects

```
effects myapp.view : []
effects myapp/router.handle_request : [Http, Stdout]
```

Written by `graded infer` for every public function. Regenerated on each run — do
not edit by hand. (The cache holds the same lines for private functions too.)

### `check` — enforced invariant

```
check myapp.view : []
check myapp/router.handle_request : [Http, Stdout]
```

An invariant enforced by `graded check`. If the function's actual effects aren't a
subset of the declared budget, the build breaks. This is the line you write to pin
a function's effects down.

### `type` — function-typed field effects

```
type myapp.Handler.on_click : [Dom]
type myapp/router.Request.send : [Http]
```

Declares the effect of a function-typed field on a custom type. See
[Type field effects](#type-field-effects).

### `external effects` — third-party and FFI functions

```
external effects gleam/httpc.send : [Http]
external effects simplifile.read : [FileSystem]
```

Declares effects for functions graded can't analyse — dependencies and FFI. See
[External declarations](#external-declarations-and-ffi).

### `returns` — returned operators and latent effects

```
// a producer that returns one of its operator parameters (a decorator)
returns myapp.traced : fn(cb) -> [cb]

// a producer that returns a closure with a latent effect
returns myapp.make_logger : [Stdout]
```

Serialized by `graded infer` for functions that *return* a function. It lets the
returned function's effect resolve at the call site (`let h = make_logger(); h()`)
across module and package boundaries, not just within the defining module. Like
`effects`, these lines are regenerated and shouldn't be hand-edited.

## Effect resolution order

When graded needs a function's effects, it consults these sources in priority
order and takes the first hit:

1. **Your spec file** — `check`, `external effects`, `type`, and `returns`
   declarations in `<package_name>.graded`.
2. **Cross-module project effects** — effects inferred from sibling modules in the
   same project, propagated in topological order. A fresh checkout resolves
   transitive call chains with no prior `graded infer`; committed `effects` lines
   always win, and `check` writes nothing to disk.
3. **Dependency spec files** — shipped by libraries at
   `build/packages/<dep>/<dep_spec_file>` (each dep's spec path comes from its own
   `[tools.graded]` config). A dependency's own spec outranks the bundled catalog.
4. **Path dependencies** — local deps declared with `path = "..."` in `gleam.toml`.
   graded reads their spec files; if a path dep ships none, it falls back to
   inferring from that dep's source.
5. **Bundled catalog** — the versioned catalog files shipped with graded (see
   [Effect catalog](#effect-catalog)).
6. **Conservative default** — anything still unresolved gets `[Unknown]`.

## Effect set syntax

An effect set appears inside brackets. The shapes:

- **`[]`** — pure; no effects. The bottom of the effect lattice.
- **`[Label1, Label2, …]`** — a specific set of effect labels (see
  [Effect labels](#effect-labels)).
- **`[_]`** — wildcard; the top of the lattice. As a declared budget it permits any
  effect and matches anything — handy for entrypoints (`main`) or deliberately
  un-restricted parameter bounds (`check run(f: [_]) : [_]`).
- **`[e]`, `[e1, e2]`** — lowercase-initial tokens are effect *variables* for
  [polymorphic signatures](#effect-polymorphism).

Higher-order signatures add two more shapes (see
[Higher-order functions](#higher-order-functions)):

- **Operator bound** — `action: fn(cb) -> [cb]` declares a *second-order*
  parameter whose own type takes a function. Several callbacks curry:
  `fn(a, b) -> [a, b]`.
- **Operator application** — `[action([Stdout])]` applies an operator variable to a
  callback's effects; it beta-reduces to a concrete set once the operator is known.

> **Wildcard caveat.** Because `[_]` is lattice top, it absorbs everything in a
> union. A function whose inferred effects would be `[Stdout, e]` (polymorphic) but
> whose declared type is `[_]` loses the variable — correct, but surprising. If you
> want polymorphism, don't declare a wildcard bound.

## Higher-order functions

### Parameter effect bounds

A function that accepts a callback can bound that parameter's effects:

```
// f must be pure — safe_map inherits no effects from its callback
check myapp.safe_map(f: []) : []

// apply passes f's effects straight through
effects myapp.apply(f: [Stdout]) : [Stdout]
```

A call to a bounded parameter (`f(x)` inside `apply`) uses the declared bound
instead of `[Unknown]`.

### Effect polymorphism

When a function's effects *depend on* its callback, use lowercase effect variables:

```
// validate_range's effects are whatever to_error's effects are
effects myapp.validate_range(to_error: [e]) : [e]

// map_with_log carries [Stdout] on top of f's effects
effects myapp.map_with_log(f: [e]) : [Stdout, e]
```

`graded infer` writes these automatically when it sees a function calling a
parameter that has a `fn(...) -> ...` type (whether annotated in source or inferred
by girard) — the variable is named after the parameter. At each call site, graded
binds the variable to the argument's effects:

- a **named function reference** (`io.println`) → its effects from the knowledge
  base;
- a **record/type constructor** (`OutOfRange`) → pure `[]`;
- the caller's **own bounded parameter** → that bound's effects.

An **inline closure** argument (`validate_range(42, fn(m) { io.println(m) })`) is
analysed directly — its body's effects are counted in the caller — so it resolves
without needing the variable. Both labeled (`to_error: OutOfRange`) and positional
(`OutOfRange`) arguments resolve. A function value graded can't trace — pulled from
a data structure, say — stays `[Unknown]`; see [LIMITATIONS.md](./LIMITATIONS.md).

### Second-order (operator) effects

When a parameter's *own* type takes a function (`action: fn(fn() -> Nil) -> a`),
its effect variable is **higher-kinded** — an operator `Eff → Eff` rather than a
flat `Eff`. A call `action(cb)` infers an operator *application*, and at the call
site the operator argument is lifted and the application beta-reduces to the
concrete effect. graded models this with a small lambda-calculus-with-union
(`EffectTerm`); the operator-bound and application syntax above is its surface
form. Operator arguments resolve from named references, inline and let-bound
closures, `case`/`if` branches over function-like options, blocks, and functions
returned from a call. The full design and the property suite are in
[docs/SECOND_ORDER_EFFECTS.md](./SECOND_ORDER_EFFECTS.md).

## Type field effects

Custom types can have function-typed fields (a `Handler` with an `on_click`, a
`Validator` with a `to_error`). graded resolves a field call `v.on_click(event)` in
two steps: it asks girard for `v`'s nominal type — which works for **any** receiver,
a parameter, a returned value, or an alias chain, falling back to a syntactic
parameter annotation when girard can't type the function — and then looks up that
type's field effect.

The field's effect comes from one of:

- a **hand-written `type` line**:

  ```
  type myapp.Handler.on_click : [Dom]
  type myapp/router.Request.send : [Http]
  ```

- **inference from construction sites** — when no `type` line exists, graded reads
  the effect off where the record is built (`Validator(to_error: io.println)` ⟹
  `Validator.to_error : [Stdout]`), unioned across every construction site in the
  package. A field wired to an inline closure is resolved by analysing the closure
  body, and a field wired to an effect-polymorphic function binds its variables to
  the field call's own arguments.

- **factory provenance** — when a record is built by a factory
  (`let v = make(io.println)`, where `make` wires its parameter into the field),
  graded follows the value through the factory, so `v.to_error` resolves with no
  `type` line. (v1 routes positional factory calls.)

Field effects are keyed by the type's **defining module** (from girard's inferred
type), so two different types both named `Validator` never conflate. When a field
is wired to a value graded can't trace — a constructor parameter, or a local that
isn't a traceable function — it falls back to `[Unknown]`, and the `type` line is
the escape hatch; see [LIMITATIONS.md](./LIMITATIONS.md).

## External declarations and FFI

`external effects` annotates a function graded can't see into, without touching the
library:

```
external effects gleam/httpc.send : [Http]
external effects simplifile.read : [FileSystem]
external effects gleam/otp/actor.start : [Process]
```

These are merged into the knowledge base before both `infer` and `check`, so
callers resolve them instead of getting `[Unknown]`.

This is also the mechanism for **FFI**. A bodyless `@external` function is opaque —
graded infers `[Unknown]`, never the `[]` an empty body would suggest, since the
foreign implementation may do anything (this holds even when the `@external`
carries a pure-looking Gleam fallback body). Declare its real effect with an
`external effects` line to make callers propagate correctly.

## Effect labels

Effect labels are plain strings — you can use any name. The bundled catalog uses
these conventions:

| Label | Meaning | Example functions |
|---|---|---|
| `Stdout` | Writes to standard output | `gleam/io.println`, `logging.log` |
| `Stderr` | Writes to standard error | `gleam/io.print_error` |
| `Stdin` | Reads from standard input | `gleam/erlang.get_line` |
| `Process` | Spawns, sends to, or manages BEAM processes | `gleam/erlang/process.send`, `gleam/otp/actor.start` |
| `Http` | Network HTTP requests | `gleam/httpc.send`, `gleam/fetch.send`, `lustre_http.get` |
| `Network` | Lower-level socket / server I/O | `glisten.start`, `mist.start` |
| `Database` | Database queries | `pog.query`, `pog.execute` |
| `FileSystem` | Reads or writes the filesystem | `simplifile.read`, `wisp.serve_static` |
| `Environment` | Reads env vars or command-line arguments | `envoy.get`, `argv.load`, `directories.home_dir` |
| `Exec` | Runs an external program | `shellout.command`, `shellout.which` |
| `Dom` | Browser DOM manipulation | `lustre.start`, `lustre.register` |
| `Time` | Reads system clock or timezone | `gleam/time/timestamp.system_time`, `birl.now` |
| `Random` | Nondeterministic generation | `youid/uuid.v4`, `wisp.random_string` |

Define your own labels for project-specific effects — they need no registration:

```
external effects my_app/email.send : [Email]
external effects my_app/metrics.record : [Telemetry]
check my_app/api.handle_request : [Http, Email]
```

`graded infer` regenerates the inferred `effects` and `returns` lines while
preserving your `check`, `type`, `external`, comments, and blank lines.
`graded format` normalizes spacing and sorting.

## Effect catalog

graded ships versioned catalog files for common Gleam packages, so you get effect
knowledge out of the box without writing `external effects` for standard libraries.

Catalog files live in `priv/catalog/` and are named `{package}@{version}.graded`.
At load time graded reads your project's `manifest.toml` to determine installed
dependency versions, then selects the highest catalog version that doesn't exceed
the installed one. So `gleam_stdlib@0.71.0` installed against a
`gleam_stdlib@0.70.0.graded` catalog file uses that file — effects don't change
between patch versions. A new catalog file is only needed when a library adds
modules or changes effect semantics. A dependency that ships its own `.graded` spec
overrides the catalog (resolution order step 3 above).

Browse [`priv/catalog/`](../priv/catalog/) for the exact set of covered packages
and the effects each one declares — the files are plain `.graded` and readable at a
glance. It covers the core `gleam-lang` packages and the most-used community
libraries. For a package the catalog doesn't cover, add an `external effects`
declaration in your spec file.

## How analysis works

graded parses your Gleam source with [glance](https://hexdocs.pm/glance/), resolves
imports, follows local calls transitively, and unions the effect sets it finds.
Composition is set union; checking is subset inclusion — if a function's actual
effects aren't a subset of its declared budget, that's a violation, reported with
the call site.

On top of the syntax layer, graded runs [girard](https://hexdocs.pm/girard) — a
Hindley-Milner type annotator for Gleam — over the whole package to learn the
inferred type of every expression. Types are an enhancement layer applied per
function: a function girard can't type falls back to the syntax-level path, so
types only ever *sharpen* a result (resolving a field call's receiver, for
example), never change an already-resolved one. The analysis is **sound, not
complete**: when it can't statically trace a value it falls back to the `[Unknown]`
effect rather than guess, so effects are never silently understated. The patterns
that fall back are catalogued in [LIMITATIONS.md](./LIMITATIONS.md).
