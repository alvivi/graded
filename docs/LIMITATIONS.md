# Limitations

graded is **sound, not complete**. It traces function values statically — through
named references, aliases, pipe chains, `case`/`if` branches, record fields, and
higher-order parameters — using [glance](https://hexdocs.pm/glance/) syntax plus
[girard](https://hexdocs.pm/girard) type information. When a function value flows
through something it *can't* trace, graded falls back to the `[Unknown]` effect
rather than guess. `[Unknown]` fails any concrete effect budget, so graded never
silently *understates* a function's effects — but the patterns below need a
hand-written annotation (or a wider budget) to resolve precisely.

Each section shows how the limitation manifests, then how to work around it.

## 1. A record field reached through an untraceable receiver

graded resolves a function-typed field's effect from where the record is
*constructed*. When the record instead arrives through a parameter (or is threaded
through other data), there's no visible construction site. For a direct parameter
receiver, graded represents this as a polymorphic field bound such as
`v.to_error: [v.to_error]`; if nothing binds that field at check time, it
conservatively collapses to `[Unknown]`.

```gleam
// src/app.gleam
pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}

pub fn caller(v: Validator) -> Nil {
  v.to_error("bad input")   // `v.to_error` field bound, or [Unknown] if unbound
}
```

```
// app.graded
check app.caller : [Stdout]
```

`graded check` flags `caller` even if every `Validator` in your code wires
`to_error` to `io.println` — graded can't see those construction sites from here,
and no bound told it what `v.to_error` costs.

**How to avoid it** — declare the field's effect once, at the type level:

```
type app.Validator.to_error : [Stdout]
```

Field calls then resolve on *any* receiver of that type, however it was obtained.

Or, when the assertion belongs at a single function boundary, declare it as a **field
bound** on that function's `check` line:

```
check app.caller(v.to_error: [Stdout]) : [Stdout]
```

The `param.field` bound resolves the call inside `caller` only, leaving the type
untouched elsewhere. It matches any unproven field call with that textual receiver
path *inside `caller`* — a parameter or a local alike — but it **cannot** describe a
value that `caller` merely *passes* to another function: to resolve `annotate(opts)`
where `opts.resolver` matters, the bound has to be written on `annotate` itself, not
on `caller`.

### Builder-set fields resolve to the builder-set value, not the default

A field call on a bare **parameter** receiver stays polymorphic — graded never
resolves it from a *package-wide* construction site, since a caller can build the
record differently:

```gleam
pub opaque type Options {
  Options(resolver: fn() -> Nil)
}

pub fn default_options() -> Options {
  Options(resolver: disk_resolver)   // disk_resolver : [FileSystem]
}

pub fn with_resolver(o: Options, resolver: fn() -> Nil) -> Options {
  Options(..o, resolver:)            // record update
}

pub fn annotate(options: Options) -> Nil {
  options.resolver()                 // polymorphic: `options.resolver`, not [FileSystem]
}
```

`annotate` infers `annotate(options.resolver: [options.resolver]) : [options.resolver]`
— it does **not** specialize to `default_options`'s `[FileSystem]`.

When a caller builds the options through a `with_*` builder and hands the result to
`annotate`, graded resolves the field to the *builder-set* value's effect,
last-write-wins:

```gleam
pub fn run() -> Nil {
  let opts = default_options() |> with_resolver(logging_resolver)  // [Stdout]
  annotate(opts)   // [Stdout] — the builder-set resolver, never a bare [FileSystem]
}
```

This holds **across a package boundary** too: graded derives a dependency's
builder signature from the dependency's own source under `build/packages` (or a
path dependency's `src/`) — the same source it reads for parameter positions, and
the source the consumer compiled against — so a consumer of an installed
dependency composes the same overlay. A dependency whose source graded can't parse
stays `[Unknown]` for the builder's field — sound, since forwarding then has no
parameter positions to work with either.

A field the overlay does *not* replace is read from the base. It resolves when the
base is traceable — a producer whose return is the construction itself
(`default_options() |> with_reporter(r)` keeps `resolver` at what
`default_options` wired) — on a direct read, forwarded through another function,
and through chained overlays. Over an **untraceable** base (a producer whose
return graded can't trace, such as one whose tail is a call) the inherited field
stays `[Unknown]`; only the fields the overlay itself sets resolve there.

A builder-set value that is itself a *call result* or *closure*
(`with_resolver(o, make_resolver())`) resolves the same per-value way a function
reference does, both on a direct read (`opts.resolver()`) and forwarded through
another function (`annotate(opts)`). The one edge is a **higher-order** resolver
whose effect genuinely depends on a callback argument (`fn(cb) { cb() }`): a
direct read applies it to the real argument, but a forwarded one has no field-call
arguments at the binding site, so it stays `[Unknown]` — sound, not precise.

A field wired from a **closure's own parameter**
(`fn(handler) { Options(..base, resolver: handler) }`) stays `[Unknown]` on both a
direct read and a forwarded one. The value is fixed only where the closure is
applied, so the field is neither a same-named module function nor an enclosing
parameter — reading it as either would understate the effect.

Forwarding that parameter through helper calls preserves the same field bound.
The receiver argument forwards whenever its provenance is syntactically rooted in
one of the caller's parameters: passing a parameter directly, a receiver path
rooted at one (`config.validator`, `config.options.inner`), an inline constructor
or factory call whose field is wired from such a value
(`inner(make_validator(to_error))` forwards `to_error`), or a **let-bound alias**
of any of those.

```gleam
fn inner(v: Validator) -> Nil {
  v.to_error("bad input")
}

pub fn caller(v: Validator) -> Nil {
  inner(v)                  // forwards `v.to_error`
}

pub fn from_config(config: Config) -> Nil {
  inner(config.validator)   // forwards `config.validator.to_error`
}

pub fn from_factory(to_error: fn(String) -> Nil) -> Nil {
  inner(make_validator(to_error))   // forwards `to_error` through the factory
}

pub fn from_alias(config: Config) -> Nil {
  let v = config.validator
  inner(v)                  // alias preserves the path: `config.validator.to_error`
}
```

The factory/constructor shape forwards **positional** (`make_validator(to_error)`,
`Validator(to_error)`), **labeled** (`make_validator(to_error: to_error)`,
`Validator(to_error: to_error)`), and **shorthand labeled** wiring
(`make_validator(to_error:)`, `Validator(to_error:)`). A let-bound alias of a
parameter, a receiver path, or a constructor/factory result forwards exactly as
the un-aliased form does — `let v = config.validator; inner(v)`,
`let v = make_validator(to_error); inner(v)`. Construction nests one extra level:
`inner(make_outer(make_inner(to_error)))` traces both hops' field wiring.

A **computed receiver** also forwards when it is a call to a helper whose
return-value provenance graded can trace: a parameter it returns whole, a receiver
path rooted at a parameter, a constructor rebuilt from parameter-rooted fields
(dropping any literal defaults), a `case`/`if` whose branches are all
parameter-rooted (forwarded through every branch and unioned), or a parameter
returned through a tail-recursive self-call (resolved by fixpoint). A labeled call
is reordered into parameter order first. graded substitutes the call's arguments
into that provenance and re-keys the field effect through the result.

```gleam
fn get_validator(config: Config) -> Validator {
  config.validator          // returns a parameter-rooted path
}

pub fn from_getter(config: Config) -> Nil {
  inner(get_validator(config))   // forwards `config.validator.to_error`
}
```

This forwarding stays narrow and sound: it applies only when the receiver's
provenance is traceable to a caller parameter — whole, through a receiver path,
through constructor/factory wiring, through a join of parameter-rooted branches,
or through a converging self-recursion. Receivers built by an **untraceable
producer** (`inner(default_validator())`), a helper whose return is itself a
**non-self call** (`inner(get(make(x)))` — no helper-call composition), a
**`case`/`if` with any untraceable branch**, a **record rebuilt through the
recursion** or one that **doesn't converge**, **mutual recursion**, or an
**external** with no visible body stay conservative, as does a computed receiver
**aliased** to a `let` bound from a computed call (`let w = get_validator(x);
inner(w)`) or a receiver **reassigned** to an opaque binding before the call. All
fall back to `[Unknown]` unless covered by a `type` line or a field bound.
Construction nested two or more levels beyond the single extra hop is likewise
conservative.

> Note: when a record *is* built by a factory and then **let-bound** before the
> field is read (`let v = make(io.println); v.to_error(..)`), graded resolves the
> field through the factory for both positional and labeled wiring.

Return-value provenance lives only in the in-process knowledge base; it is not
serialized to `.graded` spec files or the catalog. A computed-receiver call
forwards into a dependency only when graded infers that dependency's source in
the same run — a **path dependency with no committed spec**. Into a spec-backed
dependency, a catalogued dependency, or any dependency whose provenance would
have to survive a spec round-trip, a computed receiver stays `[Unknown]`.

## 2. A function pulled out of a data structure

graded follows named bindings and simple aliases, but not function values
extracted by arbitrary computation — indexing a list, reading a dict, etc.

```gleam
import gleam/list

pub fn run(handlers: List(fn(String) -> Nil)) -> Nil {
  let assert Ok(handle) = list.first(handlers)
  handle("event")   // [Unknown] — `handle` came out of a list
}
```

**How to avoid it** — pass the function directly instead of through a collection,
so it has a name graded can resolve:

```gleam
pub fn run(handle: fn(String) -> Nil) -> Nil {
  handle("event")   // resolves to `handle`'s effect
}
```

If the data-structure shape is essential, declare the budget explicitly
(`check app.run : [_]` to allow anything, or the precise set you expect).

## 3. A function returned from a `use` expression

Returned-function inference reads a function whose body **ends in a plain
expression**. A body that ends in a `use` block has no bare tail expression to
read, so callers that apply the returned function see `[Unknown]`.

```gleam
import gleam/io

fn with_logger(run: fn(fn(String) -> Nil) -> a) -> a {
  run(io.println)
}

pub fn get_logger() -> fn(String) -> Nil {
  use log <- with_logger()
  log                      // body tail is a `use`, not a bare expression
}

pub fn caller() -> Nil {
  let h = get_logger()
  h("hello")               // [Unknown] — `get_logger`'s return isn't traced
}
```

**How to avoid it** — return the function without `use`:

```gleam
pub fn get_logger() -> fn(String) -> Nil {
  io.println
}
```

or declare the producer's effect with an `external effects` / `type` line if it
lives behind a record field.

## 4. A higher-order argument to an immediately-applied returned function

When a function returned by a producer is applied straight away
(`producer()(arg)`), graded resolves the producer's returned operator but does
not track that operator's *parameter* types. If `arg` is itself higher-order — a
closure that takes and applies its own function parameter — graded can't tell how
to lift it and falls back to `[Unknown]`. A plain value or a first-order closure
argument resolves precisely.

```gleam
import gleam/io

fn make() -> fn(fn(fn() -> Nil) -> Nil) -> Nil {
  fn(action) { action(io.println) }
}

pub fn caller() -> Nil {
  make()(fn(cb) { cb() })   // [Unknown] — `make()`'s parameter type isn't tracked
}
```

**How to avoid it** — make the operator a *named* function and call it directly,
instead of returning it and applying the result. graded has the named function's
signature, so it lifts the higher-order argument over exactly the right
parameters:

```gleam
fn apply_action(action: fn(fn() -> Nil) -> Nil) -> Nil {
  action(io.println)
}

pub fn caller() -> Nil {
  apply_action(fn(cb) { cb() })   // resolves — `apply_action`'s signature is known
}
```

or declare the budget explicitly (`check app.caller : [_]`, or the precise set).

## 5. External (FFI) and un-annotated precompiled code

graded can't see across an `@external` boundary, so FFI functions are `[Unknown]`
— even when the declaration carries a pure-looking Gleam fallback body, since the
foreign implementation may do anything. (A fallback body an `@external` reaches on
a target it declares no implementation for is ordinary Gleam that runs, so a
`check` line on the function covers it as well as the declaration.) The same applies to dependencies that ship
no `.graded` spec and aren't in the bundled catalog, and to dynamically dispatched
calls.

```gleam
@external(erlang, "my_ffi", "write_log")
pub fn write_log(msg: String) -> Nil

pub fn caller() -> Nil {
  write_log("hi")          // [Unknown] — native code is opaque
}
```

**How to avoid it** — declare the effect explicitly:

```
external effects app.write_log : [Stdout]
```

For common third-party packages, the [bundled catalog](./REFERENCE.md#effect-catalog)
already supplies these declarations, so you only need `external effects` for your
own FFI and for packages the catalog doesn't cover.

An `external effects` line covers the *call*, and there is no form that covers
the **value** foreign code returns. A closure an FFI producer hands back, the
record it builds, and the fields either wires stay `[Unknown]` at every use —
declared or not, fallback body or not — because nothing states what the foreign
implementation returns:

```gleam
@external(erlang, "my_ffi", "make_client")
pub fn make_client() -> fn(Request) -> Response
```

**How to avoid it** — wrap the producer in ordinary Gleam, so the value graded
resolves is one it can see built, or annotate the *field* the returned function
lands in with a `type` line.

### Which targets an `@external` is built for

Whether a declaration is foreign code at all depends on the targets the function
is compiled for: one whose every `@external` names a target the function is never
built for has no foreign implementation, so its Gleam body is the whole story and
graded treats it as ordinary Gleam. graded reads both narrowings — a `@target`
attribute on the function, and `gleam.toml`'s top-level `target` for the package.

It cannot read the *build's* target. `gleam build --target javascript` against a
package whose `gleam.toml` says `target = "erlang"` compiles declarations graded
has ruled out, so a body it treats as the implementation is dead text there, and
a declaration it ignored is what runs. Both readings then describe a build that
did not happen.

**How to avoid it** — keep `gleam.toml`'s `target` in step with how the package
is actually built, or leave the field out. A package that declares no `target` is
read as compiled for both, which charges a declaration and its running fallback
body alike rather than deciding either away.

## 6. A returned-operator summary written by an older graded

A `returns` line records the effect operator a producer returns, e.g.
`returns app.make : fn(handler) -> [handler]`. When `check` consults such a line —
its own package's spec, or a dependency's — it trusts a ground summary as written.
A summary produced by a graded new enough to sanitize returned-closure callback
binders is sound; one produced by an older graded may have dropped a residual
effect that coincided with a callback's name, leaving a summary that under-reports.
Because the spec records no producing version, `check` can't tell the two apart
and trusts both.

**How to avoid it** — re-run `graded infer` with a current graded to regenerate
your own spec (the normal infer-then-check flow already does this). For a
dependency shipping a spec built by an older graded, upgrade or regenerate that
dependency's spec so its summaries are sound. Until then the summary is trusted as
written, so any `check` that resolves through it can't be relied on — a widened
consumer budget only permits more effects, it doesn't restore one the summary
already omitted.

---

Every fallback above is the conservative `[Unknown]`, never a silent `[]`: graded
would rather flag a call it can't prove than let an effect slip through unchecked.
When you hit one, the fix is always one of three escape hatches — a `type` line
for record fields, an `external effects` line for opaque functions, or a wider
declared budget.
