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

The name is module-qualified (`myapp/router.handle_request`). A `check` whose name
matches no function in any project module — most often a missing module qualifier —
never runs against anything and passes silently; `graded check` warns about it.

### `type` — function-typed field effects

```
type myapp.Handler.on_click : [Dom]
type myapp/router.Request.send : [Http]
```

Declares the effect of a function-typed field on a custom type. See
[Type field effects](#type-field-effects).

The type is module-qualified by the module that *defines* it. An unqualified or
mis-qualified `type` line keys nothing, so the field silently resolves to
`[Unknown]`; `graded check` warns when a `type` line matches no field of any
project type.

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
   Its `external effects` lines count: a per-function one resolves here, and a
   module-level one joins the module-external fallback tier — consulted only for
   names nothing else keys, so it sits below every per-function entry, the
   catalog's included.
4. **Path dependencies** — local deps declared with `path = "..."` in `gleam.toml`.
   graded reads their spec files, `external effects` lines and all; if a path dep
   ships none, it falls back to inferring from that dep's source. The two branches
   rank differently against the catalog: a *committed* path-dep spec outranks a
   catalog entry for the same function, while a spec-less path dep's
   source-inferred effects sit **below** one — inference yields `[Unknown]` for
   the FFI bodies a catalog entry describes precisely.
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

### Field bounds

A bound's name can be a `param.field` path, declaring the effect of a function-typed
field reached through a parameter:

```
// handler.on_click carries [Dom] inside view
check myapp.view(handler.on_click: [Dom]) : [Dom]
```

The path may have more than two segments (`config.handler.on_click`), naming a
field reached through a nested receiver path forwarded from a parameter. A field
call `handler.on_click(event)` then resolves to `[Dom]` directly, taking
priority over receiver-type resolution. This is the boundary-scoped counterpart to a
[`type` line](#type-field-effects): the `type` line declares a field's effect for
every receiver of that type package-wide, the field bound for one `check`'d function.
A field bound and an ordinary parameter bound can share one `check` line.

A field bound declares a *concrete* effect set: it resolves to exactly the effects
written, with no call-site substitution. For an effect-polymorphic field — one whose
effect depends on its own arguments — use a [`type` line](#type-field-effects)
instead, which substitutes the field call's arguments into the declared variables.

If a field bound's `param.field` path matches no field call in the checked function's
body, graded emits a warning — the bound is dead. When the receiver is a parameter the
cause is a typo in the path; when it isn't, the warning also notes the field call may
have resolved through value provenance (a receiver traced to a construction site),
which shadows the bound.

**Precedence.** A field bound only competes with receiver-type (`type`-line)
resolution, and wins it. It does *not* override value provenance: when the receiver
is traced to a construction site — a direct constructor or a factory — and the field
resolves through that value, the call is resolved before it is ever treated as a
field call, so the bound doesn't apply. This isn't a conflict in practice: field
bounds exist for receivers graded can't trace (a parameter, a value threaded through
data), which is exactly the case where there's no provenance to compete with.

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
  `type` line. Positional and labeled factory calls both route. When the factory
  result is passed to a helper (`inner(make(resolver))`), the helper's
  field-effect variable forwards onto the wired argument — see
  [field-effect forwarding](./LIMITATIONS.md).

- **alias-aware forwarding** — a receiver passed to a helper forwards its field
  effects whether passed inline or through a let-bound alias. `let v =
  config.options; inner(v)` re-keys the helper's field bound onto
  `config.options.…` just as `inner(config.options)` does, and `let v =
  make(resolver); inner(v)` forwards through the factory wiring. Aliasing is
  resolved eagerly at the binding, so a reassignment (`let v = …` again) or a
  binding from a computed call result clears the provenance and stays
  `[Unknown]`. See [field-effect forwarding](./LIMITATIONS.md).

- **return-value provenance** — an *inline* computed receiver forwards when it is
  a call to a helper whose return provenance graded can trace: a parameter
  (`inner(id_options(o))`), a parameter-rooted receiver path
  (`inner(get_options(config))` returning `config.options`), a constructor rebuilt
  from parameter-rooted fields (`inner(normalize(o))`, keeping literal defaults out
  of the summary), a `case`/`if` join of parameter-rooted branches, or a parameter
  returned through a converging tail-recursive self-call; a labeled call is
  reordered into parameter order first. graded substitutes the call's arguments
  into the helper's return provenance and forwards through the result. A helper
  whose return is itself a non-self call, a `case`/`if` with an untraceable branch,
  a non-converging or mutual recursion, or an external body stays `[Unknown]`. See
  [field-effect forwarding](./LIMITATIONS.md).

Field effects are keyed by the type's **defining module** (from girard's inferred
type), so two different types both named `Validator` never conflate. When a field
is wired to a value graded can't trace — a constructor parameter, or a local that
isn't a traceable function — it falls back to `[Unknown]`. The escape hatch is a
`type` line, or a [field bound](#field-bounds) when the assertion belongs at a single
function boundary; see [LIMITATIONS.md](./LIMITATIONS.md).

**Dependency-defined types.** The receiver type a field call resolves to can belong
to a dependency, so a `type` line may name a dependency module
(`type dep/repo.Repo.find : [Storage]`). This works for both path and published
dependencies — girard reads the dependency's source to type the receiver. A
dependency can also **ship** its own `type` lines in its committed spec file; a
consumer picks them up automatically, the same way it inherits a dependency's
`effects` and `external` annotations, so the capability-record pattern needs no
per-consumer re-declaration. A consumer's own `type` line still wins on a clash.

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

A library's `external effects` lines are part of what its spec ships: a consumer
of a published or path dependency reads them the same way it reads that
dependency's `effects` lines, so declaring your FFI once resolves it for everyone
downstream. Within one spec the `external effects` line is authoritative — it
decides the function's effect (and its bounds) over any `effects` line for the
same name, which is why `graded infer` writes none.

A name with no `.` is a **module-level** external: it declares the whole module's
effect at once, so every function in it resolves to that set without a per-function
line.

```
external effects gleam/list : []           // the whole module is pure
external effects some_db/client : [Database] // every client function does Database I/O
```

Module-level externals work on dependency modules (hex or path) **and on your own
project modules**. For a dependency or project module graded would otherwise infer,
the declaration suppresses that inference: every function in the module resolves to
the declared set instead of an inferred `[Unknown]`, and `graded infer` writes no
per-function `effects` lines for it (just as a per-function external suppresses its
own line). Use the per-function form when functions in a module differ; use the
module-level form when one budget fits the module. A per-function
`external effects mod.fn` or a catalog `effects` line for the same function takes
precedence over a module-level external.

This is also the mechanism for **FFI**. A bodyless `@external` function is opaque —
graded infers `[Unknown]`, never the `[]` an empty body would suggest, since the
foreign implementation may do anything (this holds even when the `@external`
carries a pure-looking Gleam fallback body). Declare its real effect with an
`external effects` line to make callers propagate correctly.

A `check` line on the external itself is checked against that declaration, never
against a body: `check myapp/ffi.now : []` fails against a declared
`external effects myapp/ffi.now : [Time]`, and fails as `[Unknown]` when nothing
declares the external. Whether the foreign code matches its declaration is the
FFI author's to establish — graded checks the budget against what was declared,
and `graded why myapp/ffi.now` reports the same, as `is an external with …`.

The one body graded does weigh is a Gleam fallback an `@external` reaches on a
target it declares no implementation for: `@external(javascript, …)` on a
function with a body means that body is what runs on Erlang, so the budget covers
both the declaration and the fallback. An `@external` for every target it is
compiled for (both, or the one a `@target` narrows it to) is answered by the
declaration alone.

Only an `external effects` line, a module-level external, or a catalog entry
declares an external. An `effects` line does not, whatever it says: for an
`@external` it is inference over a body the foreign implementation needn't
match, so a function that became an `@external` after the spec was written is
checked against `[Unknown]`, not against the `effects` line it left behind — and
so is every *call* into it, so `check`, `why`, `graded effect` and a caller's
budget all report one name the same way.
Declaring `external effects myapp/ffi.now : [Unknown]` is still a declaration —
it names itself as the source rather than reporting the external as undeclared.

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

## Querying one name

`graded effect <name> [directory]` prints what graded resolves for a single name
and writes nothing — no spec file, no cache:

```sh
$ gleam run -m graded effect myapp/router.handle
myapp/router.handle has effects [Stdout]
  source: your spec

$ gleam run -m graded effect myapp/repo.Repo.find
field `find` on type `Repo` (myapp/repo) has effects [Storage]
  source: declared by a `type` line in your spec
```

`<name>` is a module-qualified function or a `module.Type.field` type field.

### Output formats

The default, `--format=prose`, describes the answer in sentences. It states only
what the answer proves, as a claim about effects rather than about behaviour. A
term that is exactly a bound variable means the function's effects *are* the
argument's — not that the argument is called:

```sh
$ gleam run -m graded effect myapp.forward
myapp.forward has the effects of its `f` argument, and none of its own
  source: in-memory inference
```

A ground term beside a bound is a total and an assumption, not a cause — the
function may do those effects itself — so the bound is stated separately:

```sh
$ gleam run -m graded effect myapp.apply
myapp.apply has effects [Stdout]
  source: your spec
  calls to argument `f` are treated as having effects [Stdout]
```

A pure function is named as pure, and `[Unknown]` is a resolved answer — an
effect graded could not settle, not a missing name:

```sh
$ gleam run -m graded effect myapp.helper
myapp.helper is pure — no effects ([])
  source: in-memory inference

$ gleam run -m graded effect myapp.opaque
myapp.opaque has effects that could not be determined: [Unknown]
  source: your spec
```

The `source:` line names which source answered: `your spec`, `your spec's
external declaration`, `in-memory inference`, `<pkg>'s shipped spec`, `path
dependency <pkg>`, or `<pkg>'s catalog entry`. A name answered by a module-level
`external effects` declaration reads "module-level external for" that module
instead, with the precedence note below it. A type field names the file its
`type` line sits in the same way (`declared by a `type` line in wisp's shipped
spec`). Every answer names a source.

`--format=graded` prints the same answer as a `.graded` line, with provenance on
a `//` comment, so the whole output parses back — the format to pipe into a spec
file or hand to a tool that already reads `.graded`:

```sh
$ gleam run -m graded effect myapp/repo.Repo.find --format=graded
type myapp/repo.Repo.find : [Storage]
// declared by a type line in your spec

$ gleam run -m graded effect myapp.apply --format=graded
effects myapp.apply(f: [Stdout]) : [Stdout]
// resolved from your spec
```

Both formats render one structured answer, so they differ in wording but never
in what they report. Any other `--format` value is a usage error.

Functions resolve through the same order as `check`, including the in-memory
inference pass, so a public function answers on a fresh checkout with no prior
`graded infer`. Type fields resolve from declared `type` lines only. A private
function, an undeclared field, or an unknown name exits non-zero with
``no public function or type field named `<name>` ``. A function graded knows
about but can't resolve is a *hit*: it reports `[Unknown]`.

One carve-out: a module-level `external effects <module> : [...]` answers for
every name in that module that nothing else keys, so under such a module a name
resolves — including one that doesn't exist. With `external effects fake_clock : [Time]`,
`graded effect fake_clock.zzz_nope` reports `[Time]` and exits zero. `effect` reports what the spec says about a name; it isn't a
check that the name exists.

## Explaining one function

`graded why <name> [directory]` explains where one function's effects come from,
writing nothing. Where `effect` answers *what* a name's effects are, `why`
accounts for them call by call:

```sh
$ gleam run -m graded why myapp/router.handle_request
myapp/router.handle_request has effects [Http, Log, Unknown]
declared check myapp/router.handle_request(f: [Log]) : [Http, Log]
  calls parameter `f` with effects [Log]
  calls wisp/client.send with effects [Http] (from wisp's catalog entry)
  calls field `run` on `config.inner`, whose type could not be resolved, with unresolved effects [Unknown]
```

The header states the function's total effect. When the function has a `check`
line, the whole declaration follows — bounds included, since they decide what the
analysis substitutes. No subset verdict is printed: whether the total fits the
budget is `graded check`'s answer, and `why` explains a function whether or not
it has a budget at all.

Each remaining line is one **effect contributor**, in source order, phrased
exactly as a violation phrases it: what the call is, the effects it contributes,
and either the reason they stayed unresolved or the source that resolved them.

`<name>` is a module-qualified function in one of your own modules. Private
functions are explained too — `why` walks source your project holds, unlike
`effect`, which answers from the public surface. A dependency function, a type
field, or an unqualified name exits non-zero: there is no body here to walk.

Two things about the contributor list are worth knowing:

- **Contributors are not the call sites you wrote.** A resolved call to a
  function of the same module is replaced by *that* function's calls, so a
  helper's calls surface in its caller's list, at spans inside the helper — the
  same substitution that lets a violation point into a helper. A function whose
  helpers are all pure therefore reports `has no reachable effect contributors`
  even though it plainly calls something.
- **One block per `check` line.** Each line is analysed under its own bounds, so
  two lines can resolve the same body differently; `why` runs once per line and
  prints a block for each, in spec-file order. With no `check` line there is a
  single block, analysed with no bounds.

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

### Declaring uncatalogued dependencies

The bundled catalog is a curated convenience for common packages, not a
general-purpose registry that grows on request. To teach graded about a dependency
it doesn't catalog — hex or path — declare its effects yourself with
`external effects` in your spec file:

```
external effects some_dep/io : [FileSystem]   // module-level: whole-module budget
external effects some_dep/net.fetch : [Http]   // per-function: precision
```

Use the module-level form when one budget fits the whole module, the per-function
form when functions differ. Both forms apply uniformly to hex and path
dependencies — a module-level external suppresses path-dep source inference for
that module, so it resolves to the declared set rather than an inferred `[Unknown]`.
This keeps your effect knowledge in your own spec file, versioned with your project.

## How analysis works

graded parses your Gleam source with [glance](https://hexdocs.pm/glance/), resolves
imports, follows local calls transitively, and unions the effect sets it finds.
Composition is set union; checking is subset inclusion — if a function's actual
effects aren't a subset of its declared budget, that's a violation, reported with
the call site.

A violation names what it can about the call. A resolved effect carries the
source that answered it (`with effects [Stdout] (from gleam_stdlib's catalog
entry)`), and an unresolved one says what stopped the resolution — a receiver
whose type nothing annotates for that field, a receiver whose type or value
couldn't be traced, a call no spec, external, or catalog declares, an external
with no declared effects, a returned operator whose producer couldn't be
resolved, or an argument this call site passed that nothing resolves:

```
src/app.gleam: run calls field `find` on `repo` of type `dep/repo.Repo`, which has no effect annotation for that field, with unresolved effects [Unknown] but declared []
```

The `(from ...)` suffix uses the same vocabulary as `graded effect`'s `source:`
line, plus two phrases for the declarations that only resolve a field call: `a
type line in <source>` and `a module-level external in <source>`, where
`<source>` names the file the line sits in (`your spec`, `<pkg>'s shipped spec`,
`<pkg>'s catalog entry`, `path dependency <pkg>`). An effect an *argument* left
unresolved names no source: the entry that answered resolved, so blaming it
would point at a line that is fine.

On top of the syntax layer, graded runs [girard](https://hexdocs.pm/girard) — a
Hindley-Milner type annotator for Gleam — over the whole package to learn the
inferred type of every expression. Types are an enhancement layer applied per
function: a function girard can't type falls back to the syntax-level path, so
types only ever *sharpen* a result (resolving a field call's receiver, for
example), never change an already-resolved one. The analysis is **sound, not
complete**: when it can't statically trace a value it falls back to the `[Unknown]`
effect rather than guess, so effects are never silently understated. The patterns
that fall back are catalogued in [LIMITATIONS.md](./LIMITATIONS.md).
