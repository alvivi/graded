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

Every line reads `<status> <path>[(bounds)] : <effects> [where <clauses>]`.
Three statuses say how much graded trusts the line — `effects` is inferred and
regenerated, `check` is asserted and verified, `assume` is trusted and never
verified — and the path's shape says what the line covers. The two optional
halves are the higher-order budgets ([Parameter effect
bounds](#parameter-effect-bounds)) and the `where` region
([`where returns`](#where-returns--returned-operators-and-latent-effects)); on
an `assume` line the `: <effects>` half is optional as well, so a clause can
stand alone.

### Statement layout

A statement fits on one physical line, or wraps: `graded format` and
`graded infer` write it on one line where the whole thing fits in 80 columns,
and otherwise put `where` on an indented continuation with one clause per line,
subsequent clauses aligned under the first.

```
effects myapp/router.handle_request : [Net] where returns : [Stdout]

effects myapp/router.handle_request(action: [action]) : [Net]
  where returns : fn(cb) -> [Stdout, action([cb])]
```

The reader accepts both forms whatever the width, so a spec may be hand-wrapped.
A continuation is an indented line that is *also* at a clause boundary: it
either opens the `where` region, or starts a new clause after the previous
fragment's trailing comma. Indentation alone continues nothing — an indented
comment is still a comment and an indented statement is still its own statement.
A statement left waiting for a clause that never comes (a trailing comma, or a
`where` with nothing after it) is a parse error naming the line it starts on.

Only the `where` region wraps. A long effect set stays on its line whatever its
width, and a payload never spans a wrap.

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

### `assume` — what graded is told rather than shown

```
assume gleam/httpc.send : [Http]              // one function
assume gleam/list : []                        // a whole module
assume myapp.Handler.on_click : [Dom]         // a function-typed field
assume myapp/ffi.each(f: [f]) : [f]           // a higher-order function
```

A trusted declaration: graded takes it as given and never verifies it. Use it
for code graded can't analyse — dependencies and FFI — and for the effect of a
function-typed field on a custom type. Hand-written and never regenerated:
`graded infer` preserves the line and writes none of its own for what it covers.

A **function-path** head takes a bound list, with the same
`(name: [set], …)` grammar as [Parameter effect
bounds](#parameter-effect-bounds). A paren group opening before the head's
first colon *is* a bound list — there is no other reading — so one that does
not parse as bounds is a parse error, as is a bound list on a module path or
a field path: a module has no parameters, and a field's callable shape is not
per-parameter. The declared effects term is **flat**: labels and
variables (`assume myapp/ffi.each(f: [f]) : [f]`); a second-order application
such as `[action([cb])]` and an operator spelling such as `fn(x) -> [x]`
both read as `[Unknown]`.

The bounds are **substitution scaffolding, not caller-side constraints** —
nothing ever verifies an assumption, its arguments included:

- A polymorphic term substitutes at call sites exactly as a bounded `effects`
  line's does: `assume myapp/ffi.each(f: [f]) : [f]` charges a caller the
  argument's actual effects.
- A bound contributes through its *name* (matching the call-site argument,
  scoping the line's clause) and through its payload's *free variables* (the
  substitution keys). `assume m.f(cb: [e]) : [e]` is valid and binds even
  though `e` names no bound.
- A ground budget (`assume m/ffi.each(f: [Disk]) : []`) is inert for callers:
  nothing checks the argument against it, so it is documentation. A term
  variable no bound's payload binds is flagged — no call site can ever
  resolve it.

What an `assume` line covers is read off the path's shape:

| Path | Covers |
|---|---|
| `gleam/list` (no `.`) | every function of that module, its name written without a file extension (`./ffi/thing.mjs` splits on the dot into a two-segment function path instead) |
| `gleam/httpc.send` | that one function |
| `myapp.Handler.on_click` | the `on_click` field of `myapp`'s `Handler` type |
| `Handler.on_click` | the same field, its module implied by the file |

Gleam casing decides between the last two forms and a function: module paths are
lower snake with slashes, type names UpperCamel, so a segment before the final
one that starts uppercase is a type name. A three-segment path whose
second-to-last segment is not a type name names no shape and is a parse error.

See [Assumptions: foreign code and field effects](#assumptions-foreign-code-and-field-effects)
and [Type field effects](#type-field-effects).

The type in a field `assume` is module-qualified by the module that *defines*
it. An unqualified or mis-qualified one keys nothing, so the field silently
resolves to `[Unknown]`; `graded check` warns when a field `assume` matches no
field of any project type.

### `where returns` — returned operators and latent effects

A clause of the statement, not a statement of its own:

```
// a producer that returns a closure with a latent effect
effects myapp.make_logger : [] where returns : [Stdout]

// a decorator that returns one of its own callbacks, its bound list scoping
// the clause's variables
effects myapp.traced(action: [action]) : [] where returns : fn(cb) -> [Stdout, action([cb])]

// what a foreign producer hands back, declared rather than inferred
assume myapp/ffi.make_client where returns : [Net]

// a foreign decorator: the returned closure runs the callback it was handed,
// the line's own bound list scoping the clause's variable
assume myapp/ffi.wrap(cb: [cb]) : [] where returns : [cb]
```

The clause states the operator a function that *returns a function* hands back,
so the returned function's effect resolves at the call site
(`let h = make_logger(); h()`) across module and package boundaries, not just
within the defining module.

On an `effects` line it is written by `graded infer` and regenerated with the
line — don't edit it by hand. Every variable it mentions is a callback parameter
of the line's own bound list; one that names anything else is ignored and
flagged, and the returned function resolves to `[Unknown]`. No clause is written
for an `@external`.

On an `assume` line it is a declaration: what an `@external` producer hands
back, hand-written and never regenerated. The effects clause before it is
optional — `assume myapp/ffi.make_client where returns : [Net]` claims nothing
about `make_client`'s own effect, and the tiers below keep answering for it. A
declared operator's variables are scoped by **the line's own bound list, and
nothing else**: one the bounds do not name is ignored and flagged, and the
registry-and-dotted-variable leniencies an `effects` line's clause enjoys do
not apply — a foreign producer has neither a walkable signature nor a
field-bound story. A ground operator is the empty-bounds case of the same
rule, so `assume myapp/ffi.make_client where returns : [Net]` needs no bound
list, while a foreign decorator writes
`assume myapp/ffi.wrap(cb: [cb]) : [] where returns : [cb]` and a caller
invoking the returned closure is charged its argument's actual effects.

On a `check` line it parses and keys nothing: verifying what a function returns
is not implemented, and `graded check` says so.

#### The clause list

The `where` region is a comma-separated list of `<key> : <payload>` entries,
split at bracket and paren depth 0 — so a comma inside `[...]` or `fn(...)` is
not a separator. `returns` is the one key this version reads, and it may appear
at most once; a second one is a parse error rather than a silent last-wins.

Every other key is **retained, not read**. The line parses, the clause resolves
nothing, and `graded check` warns once per line naming all of its unknown keys.
The clause is then kept verbatim — key, payload interior and order — through
`graded format` and `graded infer`, so a spec written by a newer graded is not
quietly stripped by an older one running over it. Only a version that
understands a key can re-derive what it means, so no rewrite drops one in order
to regenerate it.

```
// read: the returned operator resolves at call sites
effects myapp.make_logger : [] where returns : [Stdout]

// retained: warned about, resolved by nothing, re-emitted as written
effects myapp.make_logger : [] where returns : [Stdout], raises : [DivideByZero]
```

A retained clause rides the line it sits on, which leaves one case — and only
one — where `graded infer` removes it: an `effects` line whose function no
longer exists, because it was renamed, made private, or its module is gone. The
whole line goes, its clauses with it. Nothing on such a line describes anything
any more, and `effects` lines are regenerated from source on every run.

That exception is confined to `effects` lines. A `check` line, an `assume` line,
and a line retained for its clauses alone are hand-written, so they survive
their subject vanishing — clauses included.

For a `check` line, and for an `assume` line that declares an effect,
`graded check` then reports the dangling name. A line retained for its clauses
alone gets no such report. Its path's *shape* is still checked when the file is
read — a malformed one is a parse error — but whether that path resolves is a
question about the key this version does not read, and answering it would mean
asserting what a grammar it cannot read meant the path to name. The unknown-key
warning is the only one such a line draws.

A key is one or more of `A-Z`, `a-z`, `0-9`, `_` and `.`. A payload's brackets
and parens must nest and match; anything else — an empty key, an empty payload,
an empty entry, unbalanced delimiters — is a parse error, since a malformed
clause blessed as "unknown" would be accepted permanently.

An `assume` line whose every clause is one this version does not read keys
nothing at all. It parses and round-trips, and it declares neither an effect nor
a returned operator — a missing clause never means *pure*.

## Lines the parser rejects

A spec file is read whole or not at all. One line the parser rejects is an error
naming the file and the line, from every command that reads a spec — `check`,
`infer`, `format`, `effect`, `why` and `pack` — and nothing is written: `infer`
leaves the spec file untouched, `pack` leaves the tarball untouched.
`format --stdin` names the rejected line and prints no formatting. A
*dependency's* spec that does not parse is a warning naming the package and the
line, and that package's entries are ignored for the run.

Four spellings read before 0.15 are rejected by name, each error carrying its
rewrite:

| Retired | Write instead |
|---|---|
| `type <path> : <effects>` | `assume <path> : <effects>` |
| `external effects <path> : <effects>` | `assume <path> : <effects>` |
| `returns <path> : <operator>` | delete it; `graded infer` writes the operator as a `where returns` clause on the `effects` line |
| `external returns <path> : <operator>` | `assume <path> where returns : <operator>` |

The first two are a mechanical rewrite:

```sh
sed -i 's/^external effects /assume /; s/^type /assume /' your_package.graded
```

Upgrade every consumer of a spec to 0.15 before rewriting that spec: a graded
older than 0.15 reads a line it does not know as no line at all, so it checks
the package as if unannotated and says nothing.

## Effect resolution order

When graded needs a function's effects, it consults these sources in priority
order and takes the first hit:

1. **Your spec file** — the `check` and `assume` lines in
   `<package_name>.graded`, and the `where returns` clauses on them.
2. **Cross-module project effects** — effects inferred from sibling modules in the
   same project, propagated in topological order. A fresh checkout resolves
   transitive call chains with no prior `graded infer`; committed `effects` lines
   always win, and `check` writes nothing to disk.
3. **Dependency spec files** — shipped by libraries at
   `build/packages/<dep>/<dep_spec_file>` (each dep's spec path comes from its own
   `[tools.graded]` config). A dependency's own spec outranks the bundled catalog.
   Its `assume` lines count: a per-function one resolves here, and a
   module-level one joins the module-external fallback tier — consulted only for
   names nothing else keys, so it sits below every per-function entry, the
   catalog's included.
4. **Path dependencies** — local deps declared with `path = "..."` in `gleam.toml`.
   graded reads their spec files, `assume` lines and all; if a path dep
   ships none, it falls back to inferring from that dep's source. The two branches
   rank differently against the catalog: a *committed* path-dep spec outranks a
   catalog entry for the same function, while a spec-less path dep's
   source-inferred effects sit **below** one — inference yields `[Unknown]` for
   the FFI bodies a catalog entry describes precisely.
5. **Bundled catalog** — the versioned catalog files shipped with graded (see
   [Effect catalog](#effect-catalog)).
6. **Conservative default** — anything still unresolved gets `[Unknown]`.

Returned-operator summaries follow the same order on their own channel: a
clause on an `assume` line outranks one on an `effects` line for the same name —
across two packages' specs as well as within one — and this package's spec
outranks a dependency's, which outranks a path dependency's. The catalog carries
no clauses of either kind.

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

A function-typed parameter no bound names still resolves to a bound: the identity
one, `f: [f]`, saying its effects are whatever the argument's are. So `check`,
`why`, `graded effect` and `graded infer` all report `apply` as `[f]`, and a
`check` line that names only some of a function's callbacks reports the rest as
the parameters they are rather than as `[Unknown]`. A budget still has to account
for them — `check myapp.apply : []` fails as `[f]`, since nothing said `f` is
pure — which is what declaring `check myapp.apply(f: []) : []` is for.

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
[field `assume`](#type-field-effects): the field `assume` declares a field's effect for
every receiver of that type package-wide, the field bound for one `check`'d function.
A field bound and an ordinary parameter bound can share one `check` line.

A field bound declares a *concrete* effect set: it resolves to exactly the effects
written, with no call-site substitution. For an effect-polymorphic field — one whose
effect depends on its own arguments — use a [field `assume` line](#type-field-effects)
instead, which substitutes the field call's arguments into the declared variables.

If a field bound's `param.field` path matches no field call in the checked function's
body, graded emits a warning — the bound is dead. When the receiver is a parameter the
cause is a typo in the path; when it isn't, the warning also notes the field call may
have resolved through value provenance (a receiver traced to a construction site),
which shadows the bound.

**Precedence.** A field bound only competes with receiver-type (field-`assume`)
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

### References passed as values

A function *reference* passed as a value rather than called — `list.map(lines,
io.println)`, `Handler(on_click: dom.focus)` — carries its effects to wherever
that value is finally called, which may be past anything graded checks. When the
reference's effects are known and not pure, graded warns at the site that passes
it:

```
src/app.gleam: warning: greet_all passes gleam/io.println as a value — its effects [Stdout] won't be tracked
```

The quoted set is what a *call* to that name resolves to, read through the same
boundary a call goes through: a stale `effects` line over an `@external` is never
quoted, since no caller of that name is charged it either.

A set that mixes a known effect with `[Unknown]` warns and quotes both halves —
the known half is a real effect travelling past whatever would track it:

```
src/app.gleam: warning: pass_loud passes dep/fs.read as a value — its effects [Disk, Unknown] won't be tracked
```

A reference whose whole effect set is `[Unknown]` stays **silent**, as does a
pure one: an unresolved reference has nothing to report, and warning about it
would read as a quoted effect. So does any reference in a body that never runs —
an `@external` covering every target the build compiles keeps its Gleam body as
dead text.

Warnings are counted separately from violations and never fail a check: `graded
check` prints them, reports `graded: N warning(s)`, and still exits zero when no
budget was exceeded.

## Type field effects

Custom types can have function-typed fields (a `Handler` with an `on_click`, a
`Validator` with a `to_error`). graded resolves a field call `v.on_click(event)` in
two steps: it asks girard for `v`'s nominal type — which works for **any** receiver,
a parameter, a returned value, or an alias chain, falling back to a syntactic
parameter annotation when girard can't type the function — and then looks up that
type's field effect.

The field's effect comes from one of:

- a **hand-written field `assume` line**:

  ```
  assume myapp.Handler.on_click : [Dom]
  assume myapp/router.Request.send : [Http]
  ```

- **inference from construction sites** — when no field `assume` exists, graded
  reads
  the effect off where the record is built (`Validator(to_error: io.println)` ⟹
  `Validator.to_error : [Stdout]`), unioned across every construction site in the
  package. A field wired to an inline closure is resolved by analysing the closure
  body, and a field wired to an effect-polymorphic function binds its variables to
  the field call's own arguments.

- **factory provenance** — when a record is built by a factory
  (`let v = make(io.println)`, where `make` wires its parameter into the field),
  graded follows the value through the factory, so `v.to_error` resolves with no
  field `assume` line. Positional and labeled factory calls both route. When the factory
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
field `assume`, or a [field bound](#field-bounds) when the assertion belongs at
a single
function boundary; see [LIMITATIONS.md](./LIMITATIONS.md).

**Dependency-defined types.** The receiver type a field call resolves to can belong
to a dependency, so a field `assume` line may name a dependency module
(`type dep/repo.Repo.find : [Storage]`). This works for both path and published
dependencies — girard reads the dependency's source to type the receiver. A
dependency can also **ship** its own field `assume` lines in its committed spec file; a
consumer picks them up automatically, the same way it inherits a dependency's
`effects` and `external` annotations, so the capability-record pattern needs no
per-consumer re-declaration. A consumer's own field `assume` line still wins on a clash.

## Assumptions: foreign code and field effects

`assume` annotates a function graded can't see into, without touching the
library:

```
assume gleam/httpc.send : [Http]
assume simplifile.read : [FileSystem]
assume gleam/otp/actor.start : [Process]
```

These are merged into the knowledge base before both `infer` and `check`, so
callers resolve them instead of getting `[Unknown]`.

A library's `assume` lines are part of what its spec ships: a consumer
of a published or path dependency reads them the same way it reads that
dependency's `effects` lines, so declaring your FFI once resolves it for everyone
downstream. Within one spec the `assume` line is authoritative — it
decides the function's effect (and its bounds) over any `effects` line for the
same name, which is why `graded infer` writes none.

**Except where it names one of your own functions with a Gleam body.** The line
declares code graded cannot see; a function of this package whose body is right
there has nothing foreign to declare, and the body is what every caller runs. A
per-function line naming one is stale: `check` warns about it once, the body is
walked instead — for the function's own `check`/`why`/`effect` and for every
caller, same-module or not — and `graded infer` deletes the line and writes the
`effects` line it was suppressing. There is no replacement: `assume` is
not an override for inference over your own code. If inference is wrong for one
of your functions, fix the source or widen the `check` budget. (A *dependency*
function with a visible body is unaffected — declaring one is what the line is
for.)

A name with no `.` is a **module-level** external: it declares the whole module's
effect at once, so every function in it resolves to that set without a per-function
line.

```
assume gleam/list : []           // the whole module is pure
assume some_db/client : [Database] // every client function does Database I/O
```

Module-level externals work on dependency modules (hex or path) **and on your own
project modules**. For a dependency or project module graded would otherwise infer,
the declaration suppresses that inference: every function in the module resolves to
the declared set instead of an inferred `[Unknown]`, and `graded infer` writes no
per-function `effects` lines for it (just as a per-function external suppresses its
own line). Use the module-level form when one budget fits the module. A
per-function `assume mod.fn` or a catalog `effects` line for the same
function takes precedence over a module-level external.

The declared set is what the module's functions cost *on their own*. It says
nothing about a callback one of them is handed, so a caller that passes an
effectful function to a higher-order name in the module pays that function's
effects on top: under `assume gleam/list : []`, `list.map(xs, io.println)`
is still charged the `[Stdout]` of `io.println`. That holds however the
higher-order name is reached — called, passed to a helper, or wired into a
record field. To state a callback's budget instead of having it charged, give
the function a per-function line with a bound list (`assume mod.each(cb: []) :
[]`), which is available wherever a per-function line is.

For a *dependency* module whose functions differ, use the per-function form. For
one of **your own** modules, the per-function form is not the answer — it names a
function graded can see the body of, so it is stale (above). The module-level form
is the one that governs your own code, and it is a whole-module budget by design.

Over a module of your own, the line governs what *callers* pay, not what its own
functions may do. A caller of `myapp/db.connect` is charged exactly the declared
set — never the union of the declaration and what `connect`'s body does — and
`graded effect myapp/db.connect` reports that same declared set, since it answers
what calling the name costs. A function in the declaring module is a caller like
any other: `myapp/db.disconnect` calling `connect()` pays the declared set too.

The function's own budget is a different question. Those bodies are visible Gleam
that runs, so a `check` line on one of them is weighed against the declaration
**and** the body: `assume myapp/db : [Database]` with `check
myapp/db.connect : [Database]` still reports a `connect` that writes to stdout,
and `graded why myapp/db.connect` lists both halves. No line over source graded
can read silences that source.

A module-level line whose module is neither a dependency nor one of your own is
flagged as a probable typo: no call can resolve into a module that isn't there.
A per-function line is flagged the same way when its name resolves nowhere — and
a dependency whose source is installed and parses settles that by what it
defines, so `assume gleam/list.typo : []` is flagged even though a
catalog module-level entry for `gleam/list` would answer for any name in it. The
catalog stands in only where graded holds no readable source. (`graded effect`
still answers from a module-level line — see
[Looking up one effect](#looking-up-one-effect) — it reports what the spec says
about a name rather than checking that the name exists.)

This is also the mechanism for **FFI**. A bodyless `@external` function is opaque —
graded infers `[Unknown]`, never the `[]` an empty body would suggest, since the
foreign implementation may do anything (this holds even when the `@external`
carries a pure-looking Gleam fallback body). Declare its real effect with an
`assume` line to make callers propagate correctly.

A *higher-order* external takes a bound list:
`assume myapp/ffi.each(f: [f]) : [f]` charges a caller its callback argument's
actual effects, the same substitution a bounded `effects` line performs. And a
foreign *decorator* — a producer whose returned closure runs the callback it
was handed — declares that with the clause, its variable scoped by the same
bound list: `assume myapp/ffi.wrap(cb: [cb]) : [] where returns : [cb]`. What
stays `assume`'s meaning throughout is that nothing verifies the declaration
itself.

A `check` line on the external itself is checked against that declaration, never
against a body: `check myapp/ffi.now : []` fails against a declared
`assume myapp/ffi.now : [Time]`, and fails as `[Unknown]` when nothing
declares the external. Whether the foreign code matches its declaration is the
FFI author's to establish — graded checks the budget against what was declared,
and `graded why myapp/ffi.now` reports the same, as `is an external with …`.

The one body graded does weigh is a Gleam fallback an `@external` reaches on a
target it declares no implementation for: `@external(javascript, …)` on a
function with a body means that body is what runs on Erlang, so the budget covers
both the declaration and the fallback. An `@external` for every target it is
compiled for (both, or the one a `@target` narrows it to) is answered by the
declaration alone.

Whether *callers* pay that body too is decided by who wrote the winning
declaration. A per-function `assume` from a written spec — your own line, or
the one a dependency's author ships, path dependencies included — answers
**alone**, even where the fallback body runs: `assume` means trusted and never
verified, the line's author can see the body too, and if they wanted the union
they would have written the wider term. Callers pay the declared term exactly;
the body's own charge is dropped from the union and reported as suppressed
wherever the charge is explained, so a body that runs is never silently read
as absent. A **boundless** line answers only for the external's own effects:
it says nothing about the callbacks, so a caller still pays each
function-typed argument's actual effects on top of the declared term —
whether the external is called directly, passed as a value, or wired into a
field. A line with its own bound list answers for the callbacks too, as
written. The other declaring forms keep the union: a **catalog** entry
describes the version graded's maintainers annotated, not necessarily the
installed body, and a **module-level** `assume` is a blanket that never named
the function it would be silencing — under either, callers still pay the
declaration beside what the body does. And in every case the external's own
`check` line weighs the walked body beside the declaration: an `assume`
changes what callers pay, never what the function's own line proves. Where the
declaration is out of reach entirely — its targets are ones this build never
compiles — the fallback body answers instead, suppressed by nothing:
suppression there would charge a build that didn't happen.

Which targets your package is compiled for comes from `gleam.toml`: the top-level
`target`, or `[tools.graded].targets` for a package really built for both, which
is the only place it can say so since `target` names exactly one:

```toml
[tools.graded]
targets = ["erlang", "javascript"]
```

Under a single declared target, an `@external` declaring that target is answered by
its declaration and its Gleam body is dead text; one declaring only the *other*
target runs its Gleam body and nothing else — its declaration describes foreign
code your build never compiles, and where there is no body either, the call reads
`[Unknown]`. Under two, both halves are in reach at once and a caller is charged
their union. A value that is not a target graded knows — `target = "llvm"`, or a
`targets` list it cannot read whole — reads as every target rather than narrowing
to a guess.

Where **neither** field names a target, graded holds two readings at once, because
a `gleam build --target javascript` against such a package is invisible to it:

- Gleam fallback bodies are read on `erlang`, the compiler's own default, in your
  package and its dependencies alike. So an `@external(erlang, …)` with a Gleam
  fallback — the shape most of the standard library uses, and the shape hand-written
  FFI usually takes — is answered by its declaration alone: callers are charged it,
  `graded why` and a `check` line on the external weigh it, and the body beside it
  is dead text to all four.
- What a declaration *states* is read on every target. So an
  `@external(javascript, …)` with a Gleam fallback is still foreign code, an
  `assume` line for it still answers, `graded infer` keeps that line, and
  callers are charged the declaration beside what the fallback body does — or
  the declaration alone, where a written per-function `assume` suppresses the
  body's half (above).

Declaring `[tools.graded].targets` replaces both readings with what you wrote.

That body is weighed *on the targets it runs on*. A name it calls is reached from
those targets and no others, so a fallback running on Erlang that calls another
`@external(javascript, …)` reaches the callee's Gleam fallback, never the foreign
implementation its declaration describes — the two are never built together. A
callee whose declaration does cover a target this body runs on is charged that
declaration as usual.

Where `@target` excludes *every* target the declaration names — `@target(erlang)`
on a function whose only `@external` is `@external(javascript, …)` — no foreign
implementation is compiled at all. The Gleam body is the sole implementation, and
the function is ordinary Gleam: its effects are inferred from that body, and the
values it returns, builds and wires are traced like any other function's.

Only an `assume` line, a module-level external, or a catalog entry
declares an external. An `effects` line does not, whatever it says: for an
`@external` it is inference over a body the foreign implementation needn't
match, so a function that became an `@external` after the spec was written is
checked against `[Unknown]`, not against the `effects` line it left behind — and
so is every *call* into it, so `check`, `why`, `graded effect` and a caller's
budget all report one name the same way.
Declaring `assume myapp/ffi.now : [Unknown]` is still a declaration —
it names itself as the source rather than reporting the external as undeclared.

The declaration answers wherever the external is reached, not only at a call:
passing it as a callback (`apply(myapp/ffi.now)`) or wiring it into a record
field (`Clock(read: now)`) charges the same effect a direct call is charged, so
a helper handed an undeclared external contributes `[Unknown]` rather than the
`[]` its bodyless declaration reads as.

What it does *not* answer for is the value the external hands back. A declaration
states what calling the function costs; nothing in it describes the closure an FFI
producer returns, the record it builds, or the fields either wires. So an
`@external`'s return provenance and its factory and update-builder signatures are
refused whether or not it is declared and whether or not a Gleam fallback body
beside it runs, and an inferred `where returns` clause for one is refused too:
`graded infer` writes none for an `@external`, and removes one a function that
has since become `@external` left behind.

The closure it hands back is the one channel with a declaring form of its own:

```gleam
@external(erlang, "my_ffi", "make_logger")
@external(javascript, "my_ffi", "make_logger")
pub fn make_logger() -> fn(String) -> Nil

pub fn caller() -> Nil {
  let log = make_logger()
  log("hi")            // [Stdout] — from the `where returns` clause
}
```

```
assume myapp/ffi.make_logger : [] where returns : [Stdout]
```

Without that clause the call is `[Unknown]`. With it, a written clause is
trusted even where a Gleam fallback body runs beside the declaration — the
clause is its author's own line, trusted whole exactly as the effects half of
a written `assume` is, and this holds by the clause's *own* source: a
clause-only `assume dep/ffi.make where returns : [Net]` answers even while the
name's *effects* come from the catalog and keep the body union — two channels,
two winning lines, each trusted by its own author. One reading still refuses
the clause, and the call says so:

- **out of reach** — the declaration names only targets this build does not
  compile, so nothing it describes is what runs. The same reading that drops
  the external's own declared effects.

(A clause from a source that does not suppress the running fallback would stay
refused beside one — the two implementations can hand back different closures
and there is no union of operators to take — but every declared clause today
comes from a written spec; the refusing arm waits on a catalog returns tier.)

Three declared clauses are dropped rather than trusted, each flagged by the spec
lint: an operator with free effect variables (a foreign decorator returning a
closure that runs its own argument — wrap the producer in Gleam instead), a
clause on a module path (`assume mymodule where returns : [...]` names no
function), and one on a name that is one of *this package's own* ordinary Gleam
functions, whose body every caller can already see. `graded infer` deletes the
last; where the function returns an operator, the inferred clause takes its
place. A clause on a field path (`assume myapp.Handler.run where returns : …`)
is not dropped but refused: a field annotation has no slot for a returned
operator, so the line is a parse error.

A dependency is held to the same rules, against the dependency's *own* source
under `build/packages`: a shipped `effects` line, or a clause on one, for a
function that package declares `@external` is refused, while its `assume` line,
that line's own clause, a module-level `assume`, and the catalog entry underneath
keep answering. A dependency's declared clause is kept even over one of its own
Gleam-bodied functions — weighing a spec against the source beside it is that
package's job at its own `infer` time. What a spec may state a returned-operator
summary *about* is narrower: the modules that package ships, plus the names a
scan of dependency source records as `@external`. A clause for anyone else's
code — your own modules included — is dropped, so no dependency can overrule what
your own body says it hands back. Where a
dependency's external carries a fallback body that runs on some target, that body
is walked — read from the dependency's own source, on the targets your build
compiles — and its effects are unioned into a catalog or module-level
declaration, exactly as they are for one of your own, while the package's
shipped per-function `assume` answers alone with the walked half reported as
suppressed. `[Unknown]` joins the union only where the walk reaches a
name nothing declares, or where graded could not read the module the body lives
in — and the same shipped line suppresses that `[Unknown]` too, so an
unreadable module does not widen a declared name.

`graded effect` answers for the public API, so a *private* `@external` exits
non-zero there as a private ordinary function does — including one a valid
`assume` line declares, since a declaration describes what the foreign
code does for its callers rather than exporting the name. Callers still resolve
it normally, and `graded why`, which accepts private functions, still explains
it.

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
assume my_app/email.send : [Email]
assume my_app/metrics.record : [Telemetry]
check my_app/api.handle_request : [Http, Email]
```

`graded infer` regenerates the inferred `effects` lines and their clauses while
preserving your `check` and `assume` lines, comments, and blank lines.
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
  source: declared by a field `assume` line in your spec
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

The `source:` line names which source answered: `your spec`, ``your spec's
`assume` line``, `in-memory inference`, `<pkg>'s shipped spec`, `path
dependency <pkg>`, or `<pkg>'s catalog entry`. A name answered by a module-level
`assume` reads ``module-level `assume` for`` that module instead, with the
precedence note below it. A type field names the file its field `assume` sits in
the same way (``assumed by a field `assume` in wisp's shipped spec``). Every
answer names a source.

Where no entry answered, the line names why instead: `an external declared only
for a target this build does not compile` where what declares it is out of reach
and no Gleam body runs in its place, `its Gleam fallback body, which is what runs
on the targets this build compiles` where one does, and `an external with no
declared effects` for foreign code this build compiles and nothing declares. In
none of these three does the declaration account for the effects, so none of them
names it — and an external that is both undeclared and out of reach reads as out
of reach, that being what decides the charge. `graded check` and `graded why`
name the same cause in the same words, a field call wired to such a name
continuing the phrase (``calls field `read` on `c`, wired to an external with no
declared effects, …``).

`--format=graded` prints the same answer as a `.graded` line, with provenance on
a `//` comment, so the whole output parses back — the format to pipe into a spec
file or hand to a tool that already reads `.graded`:

```sh
$ gleam run -m graded effect myapp/repo.Repo.find --format=graded
assume myapp/repo.Repo.find : [Storage]
// assumed by a field `assume` in your spec

$ gleam run -m graded effect myapp.apply --format=graded
effects myapp.apply(f: [Stdout]) : [Stdout]
// resolved from your spec
```

Both formats render one structured answer, so they differ in wording but never
in what they report. Any other `--format` value is a usage error.

Functions resolve through the same order as `check`, including the in-memory
inference pass, so a public function answers on a fresh checkout with no prior
`graded infer`. Type fields resolve from declared field `assume` lines only. A private
function, an undeclared field, or an unknown name exits non-zero with
``no public function or type field named `<name>` ``. A function graded knows
about but can't resolve is a *hit*: it reports `[Unknown]`.

Publicity and existence are read from your source, not from your spec. In a
module of this package that graded parsed, a **private** function and a name the
module **does not define** both exit non-zero — whatever a hand-written line
says about them, and whether or not the function is an `@external`. A spec line
cannot export a name the package doesn't.

One carve-out: a module-level `assume <module> : [...]` answers for
every name in that module that nothing else keys, so under such a module a name
resolves — including one that doesn't exist. With `assume fake_clock : [Time]`,
`graded effect fake_clock.zzz_nope` reports `[Time]` and exits zero. `effect`
reports what the spec says about a name; it isn't a
check that the name exists. This holds where graded has no source to consult —
a module outside the package, as `fake_clock` is. Over one of *your* modules the
source decides: a module-level external answers for that module's public
functions, and its private and undefined names still exit non-zero.

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
knowledge out of the box without writing `assume` for standard libraries.

Catalog files live in `priv/catalog/` and are named `{package}@{version}.graded`.
At load time graded reads your project's `manifest.toml` to determine installed
dependency versions, then selects the highest catalog version that doesn't exceed
the installed one. So `gleam_stdlib@0.71.0` installed against a
`gleam_stdlib@0.70.0.graded` catalog file uses that file — effects don't change
between patch versions. Where *no* bundled version is at or below the installed
one — a dependency older than every catalog file for it — the *highest* bundled
file applies anyway rather than nothing, so a newer version's effects can stand
in; `graded catalog` reports that selection as "highest bundled; none ≤". A new
catalog file is only needed when a library adds modules or changes effect
semantics. A dependency that ships its own `.graded` spec overrides the catalog
(resolution order step 3 above).

The catalog covers the core `gleam-lang` packages and the most-used community
libraries.

### Reading the catalog

`graded catalog` prints what the bundled catalog holds, writing nothing. Which
file each of your packages resolves to comes from `manifest.toml`, found by
walking up from the directory you name — or from the current directory when you
name none, so a run from anywhere inside a package reads that package's
manifest. A directory that isn't there is an error, not a walk up to whatever
project the shell is sitting in. Where there is no readable `manifest.toml` —
a fresh clone before `gleam deps download`, or a manifest with a TOML error —
no package has an installed version to select on: the listing says so on its
first line and marks nothing, and `graded catalog <package>` is an error naming
the file it looked for rather than a report that the package is not installed.

With no argument it lists every bundled file, marking the one each of your
installed packages resolves to:

```sh
$ gleam run -m graded catalog
argv@1.1.0  // selected for argv 1.1.0
gleam_stdlib@0.70.0  // selected for gleam_stdlib 1.0.3
lustre@4.0.0
lustre@5.0.0
```

With a package it prints that file, under a header naming it and why it was
chosen — so the output is itself a valid `.graded` file you can redirect into a
spec and edit down to `assume` overrides:

```sh
$ gleam run -m graded catalog gleam_stdlib
// gleam_stdlib@0.70.0.graded — selected for gleam_stdlib 1.0.3 in manifest.toml
// gleam_stdlib — pure modules and effectful functions

assume gleam/list : []
...
```

`graded catalog <package>@<version>` prints exactly that bundled file and reads
no manifest, which is also how you read a package you don't depend on: the
implicit form means "the file *your project* resolves against", so a bundled
package missing from `manifest.toml` is an error that names the bundled versions
and the command that prints one.

What it shows is the bundled catalog alone — what `graded effect` names as a
package's *catalog entry*. A dependency's shipped spec, a path dependency's spec
and your own externals may all still override its entries, so
`graded effect <name>` is what says which source wins for a name.

### Declaring uncatalogued dependencies

The bundled catalog is a curated convenience for common packages, not a
general-purpose registry that grows on request. To teach graded about a dependency
it doesn't catalog — hex or path — declare its effects yourself with
`assume` in your spec file:

```
assume some_dep/io : [FileSystem]   // module-level: whole-module budget
assume some_dep/net.fetch : [Http]   // per-function: precision
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
line, plus two phrases for the declarations that only resolve a field call: ``a
field `assume` in <source>`` and ``a module-level `assume` in <source>``, where
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
