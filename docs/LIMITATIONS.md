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
untouched elsewhere.

Forwarding that parameter through helper calls preserves the same field bound.
Three argument shapes forward: passing one of the caller's own parameters
directly, passing a receiver path rooted at one of them (`config.validator`,
`config.options.inner`), and passing an inline constructor or factory call whose
field is wired from such a value (`inner(make_validator(to_error))` forwards
`to_error`).

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
```

The factory/constructor shape forwards both **positional** (`make_validator(to_error)`,
`Validator(to_error)`) and **labeled** wiring (`make_validator(to_error: to_error)`,
`Validator(to_error: to_error)`).

This forwarding is intentionally narrow. It applies only when the receiver
argument is one of the caller's own parameters, a field path rooted at one, or an
inline constructor/factory call wiring such a value into the field. Aliases
(`let w = config.validator; inner(w)`, `let v = make_validator(to_error); inner(v)`),
opaque factory returns whose field wiring can't be traced
(`inner(default_validator())`), nested factory calls
(`inner(make_outer(make_inner(to_error)))`, traced one level only), and other
computed expressions remain conservative and fall back to `[Unknown]` unless
covered by a `type` line or a field bound.

> Note: when a record *is* built by a factory and then **let-bound** before the
> field is read (`let v = make(io.println); v.to_error(..)`), graded resolves the
> field through the factory for both positional and labeled wiring.

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
foreign implementation may do anything. The same applies to dependencies that ship
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

---

Every fallback above is the conservative `[Unknown]`, never a silent `[]`: graded
would rather flag a call it can't prove than let an effect slip through unchecked.
When you hit one, the fix is always one of three escape hatches — a `type` line
for record fields, an `external effects` line for opaque functions, or a wider
declared budget.
