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
through other data), there's no visible construction site, so the field call is
`[Unknown]`.

```gleam
// src/app.gleam
pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}

pub fn caller(v: Validator) -> Nil {
  v.to_error("bad input")   // [Unknown] — `v` came in as a parameter
}
```

```
// app.graded
check app.caller : [Stdout]
```

`graded check` flags `caller` even if every `Validator` in your code wires
`to_error` to `io.println` — graded can't see those construction sites from here.

**How to avoid it** — declare the field's effect once, at the type level:

```
type app.Validator.to_error : [Stdout]
```

Field calls then resolve on *any* receiver of that type, however it was obtained.

> Note: when a record *is* built by a factory function (`let v = make(io.println)`),
> graded resolves the field through the factory — but only for **positional**
> wiring (`make(io.println)`). A factory that wires the field with a *labeled*
> argument falls back to `[Unknown]`; use the `type` line above for those.

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

## 4. External (FFI) and un-annotated precompiled code

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

For common third-party packages, the [bundled catalog](../README.md#effect-catalog)
already supplies these declarations, so you only need `external effects` for your
own FFI and for packages the catalog doesn't cover.

---

Every fallback above is the conservative `[Unknown]`, never a silent `[]`: graded
would rather flag a call it can't prove than let an effect slip through unchecked.
When you hit one, the fix is always one of three escape hatches — a `type` line
for record fields, an `external effects` line for opaque functions, or a wider
declared budget.
