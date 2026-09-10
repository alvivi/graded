# Coverage

`graded coverage [dir]` reports what graded's type-inference layer could and
could not read of one package. It is read-only, decides nothing, and always
exits 0 — `graded check` is the command that fails, and nothing in this report
is a property of your code's effects.

graded parses your source with [glance](https://hexdocs.pm/glance/) and
additionally runs [girard](https://hexdocs.pm/girard), a Hindley-Milner type
annotator for Gleam, over the whole package. Types resolve field calls on
receivers nothing annotates, derive a field's effects from where the record is
constructed, and decide calls through a name that shadows an imported module.
That layer is best-effort and per-function: a definition girard can't type
contributes no types, and graded falls back to the syntax-level path for it.
`coverage` is how you see whether the layer reached your code — before you spend
time on an `[Unknown]` that a type error three lines away explains.

Run it when:

- `graded check` reports `[Unknown]` and you want to know whether the type layer
  ran at all on that function,
- you added a `@target` annotation and want to see which targets are typed,
- you're upgrading Gleam, girard or glance and want the standing of what's
  installed,
- you want a per-release number for how much of a package the layer reads.

```sh
gleam run -m graded coverage         # this package
gleam run -m graded coverage ../lib  # another package's root
```

Nothing is written: not the spec file, not the cache under `build/.graded/`.

## Anatomy of a report

Over a one-module package:

```gleam
// src/app.gleam
import gleam/io

pub fn greet(name: String) -> Nil {
  io.println("hello " <> name)
}
```

```
$ gleam run -m graded coverage
gleam 1.18.0 (verified), erlang/OTP 28.4.2 (verified)
graded 0.20.0, girard 3.0.0 (verified), glance 7.0.0 (verified)

targets: erlang — gleam.toml declares none, so bodies are read on erlang and declarations on both
type inference: ran on erlang; no @target function, so no second run

modules: 1 read, 0 unread
functions: 1 typed, 0 skipped, 0 left out of every run, 0 unread
constants: 0 typed, 0 skipped, 0 left out of every run, 0 unread
ambiguous calls: 1
  - 0 decided by the type inference
  - 1 settled lexically with typed evidence
  - 0 settled lexically with no typed evidence
  - 0 wired from a construction
  - 0 undecided
  - 0 disagreements, counted again in the class each falls in

path dependencies: none
```

Blocks in a fixed order: the versions, the targets and the runs, the counts,
then any listing that has a row, then the path dependencies, and last a
`versions` section where a version standing is worth acting on. A listing with
no rows prints nothing at all, so the report above is the shape of a package
with nothing to report.

The counts are disjoint by construction. A module is read or unread; within a
read module every function and every constant is exactly one of typed, skipped
or left out of every run; every ambiguous call is in exactly one class. Nothing
is derived by subtraction from a total, and nothing is counted as "typed" by
omission.

## Versions

The first two lines state what is *running* — not what the package pins. The
toolchain comes first, then graded and the libraries it reads your package
through:

```
gleam 1.18.0 (verified), erlang/OTP 28.4.2 (verified)
graded 0.20.0, girard 3.0.0 (verified), glance 7.0.0 (verified)
```

Each version carries its standing:

| Standing | Means |
|---|---|
| `(verified)` | a version graded was verified on |
| `(verified: 1.15.4, 1.16.0, 1.17.0, 1.18.0)` | this is not one of them; the list is what was verified |
| `not observed` | the version could not be read at all |

`not observed` is an answer, not a failure: the JavaScript target holds no
application metadata, and `gleam` may not be on the path. graded states the
compiler by running `gleam --version` — the only subprocess it ever runs, and no
other command runs it.

Anything worth acting on is repeated in a `versions` section at the very end of
the report:

```
versions
  gleam 1.19.0 is not a verified version (verified: 1.15.4, 1.16.0, 1.17.0, 1.18.0)
  the project's manifest pins girard 3.1.0; the analyzer running is girard 3.0.0
```

The second line is the checkout case: a build of graded pointed at a project
whose `manifest.toml` names a different girard. The analyzer running is the one
graded loaded, and the line says which is which.

See [the Reference](./REFERENCE.md#supported-versions) for what "verified" is
claimed on and how a version enters the list.

## Targets and the runs

```
targets: erlang — gleam.toml declares none, so bodies are read on erlang and declarations on both
type inference: ran on erlang; no @target function, so no second run
```

The `targets:` line is the package's target set and the reading of `gleam.toml`
that produced it:

| Sentence | Source |
|---|---|
| … `[tools.graded].targets` names erlang and javascript | the `[tools.graded]` table |
| … gleam.toml's `target` names it | the top-level `target` key |
| … gleam.toml names a target graded cannot read, so every target stays in reach | a `target` or `targets` key graded cannot read whole |
| … gleam.toml declares none, so bodies are read on erlang and declarations on both | neither key |
| … there is no gleam.toml, so nothing is narrowed | no `gleam.toml` at all |

(Each is what follows the em dash on the `targets:` line.)

The `type inference:` line is a different fact: which targets girard actually
*ran* on, primary first. girard runs once per target a definition in your own
source is gated to by `@target`, and the readings merge per module, so a
definition is typed on the target that builds it. A package with no gated
function runs it once.

```gleam
// src/app.gleam — no gated function
@target(javascript)
pub const runtime = "browser"

pub fn go() -> Int {
  1
}
```

```
type inference: ran on erlang; no @target function, so no second run

functions: 1 typed, 0 skipped, 0 left out of every run, 0 unread
constants: 0 typed, 0 skipped, 1 left out of every run, 0 unread
```

Add a function on that target and the second run happens, which reads the
constant too:

```gleam
// src/app.gleam
@target(javascript)
pub const runtime = "browser"

@target(javascript)
pub fn boot() -> String {
  runtime
}

pub fn go() -> Int {
  1
}
```

```
type inference: ran on erlang, javascript; a @target function gates the second run

functions: 2 typed, 0 skipped, 0 left out of every run, 0 unread
constants: 1 typed, 0 skipped, 0 left out of every run, 0 unread
```

## Modules

```
modules: 1 read, 0 unread
```

*Unread* means girard returned no result for that module at all — not a
per-definition decline but nothing for the whole file. Its functions and
constants are then counted under `unread` on their own lines and appear in no
other count, so a non-zero here points at the inference rather than at your
code.

## Functions and constants

```
functions: 1115 typed, 0 skipped, 0 left out of every run, 0 unread
constants: 40 typed, 0 skipped, 0 left out of every run, 0 unread
```

Four standings, one definition in exactly one of them:

| Standing | Means |
|---|---|
| `typed` | girard produced types for the definition |
| `skipped` | girard read the module and declined this definition, under an error bucket |
| `left out of every run` | the definition is `@target`-gated to a target no run covered, so it was never walked |
| `unread` | its module produced no result at all (see above) |

### skipped

A definition girard declines contributes no types, and graded falls back to the
syntax-level path for it — sound, but less precise. Every skip is listed with
its coordinates and girard's error bucket:

```gleam
// src/app.gleam
import gleam/io

pub type Logger {
  Logger(println: fn(String) -> Nil)
}

pub fn log_with(io: Logger) -> Nil {
  io.println("one")
  let count: Int = "not an int"
  case count {
    _ -> Nil
  }
}
```

```
functions: 0 typed, 1 skipped, 0 left out of every run, 0 unread

skipped definitions
  app.log_with (src/app.gleam:7:1): TypeMismatch

undecided shadowed calls
  app.log_with `io.println` (src/app.gleam:8:3): no typed resolution (function skipped: TypeMismatch)
```

The two sections are one finding: the type error costs the definition its types,
and the call inside it — where `io` names both the parameter and the imported
module — has nothing left to decide it. Fix the type error and both rows go.

A skip that names no definition the module declares carries no coordinates and
is listed apart:

```
skipped definitions
  (unlocated) app/server.helper: NoSuchField
```

### left out of every run

Expected at zero for functions: a gated function triggers a run on its own
target. A gated *constant* can leave it non-zero — a constant holds no call, so
it triggers no run of its own, and it is left out whenever no gated function
shares its target. That is the first example in
[Targets and the runs](#targets-and-the-runs); adding a function on the target
is what reads it.

One other state leaves it non-zero for functions: a module the primary run read
and a second run did not keeps the primary run's drops. Those modules are named
under `modules the second run could not read`.

## Ambiguous calls

An **ambiguous call** is a dotted call site — `name.label(args)` — where the
spelling alone does not say whether `name` is an imported module (a
module-qualified call) or a value (a record-field call). Every such site in the
package is one row, classified twice: once by graded's own extractor, once by
what girard resolved that span to. girard decides nothing here; the second
reading exists so a disagreement is visible before any answer is charged.

```
ambiguous calls: 6
  - 2 decided by the type inference
  - 1 settled lexically with typed evidence
  - 1 settled lexically with no typed evidence
  - 1 wired from a construction
  - 1 undecided
  - 1 disagreements, counted again in the class each falls in
```

The first five classes partition the rows and sum to the headline. The
disagreement row is outside that sum: it counts rows across the classes, each
already counted in its own.

### decided by the type inference

The receiver's name shadows an imported module, and girard's resolution is what
chose between the two readings. This is the one place a type resolution *decides*
a charge rather than sharpening one: without it, the call in `log_with` below
would be charged `[Unknown]`.

```gleam
// src/app.gleam
import gleam/io

pub type Logger {
  Logger(println: fn(String) -> Nil)
}

pub fn log_with(io: Logger) -> Nil {
  io.println("through the record")
}

pub fn log_plain() -> Nil {
  io.println("through the module")
}
```

```
ambiguous calls: 2
  - 1 decided by the type inference
  - 1 settled lexically with typed evidence
  - 0 settled lexically with no typed evidence
  - 0 wired from a construction
  - 0 undecided
  - 0 disagreements, counted again in the class each falls in
```

`log_with`'s `io.println` is the decided row — `io` is the parameter there. In
`log_plain` nothing shadows `gleam/io`, so the extractor settled it on syntax
alone.

### settled lexically with typed evidence

The extractor settled the site by itself — the name is an import alias and no
binding, or it is a plain field call on a receiver that shadows nothing — and
girard also answered at that span. The healthy bulk of any package. Whether the
two answers *agree* is the separate disagreement count.

### settled lexically with no typed evidence

The extractor settled it, and girard answered nothing for the span. The charge
is sound but unwitnessed:

```gleam
// src/app.gleam
import gleam/io

pub fn report() -> Nil {
  io.println("starting")
  let count: Int = "not an int"
  case count {
    _ -> Nil
  }
}
```

```
functions: 0 typed, 1 skipped, 0 left out of every run, 0 unread
ambiguous calls: 1
  - 0 decided by the type inference
  - 0 settled lexically with typed evidence
  - 1 settled lexically with no typed evidence
  - 0 wired from a construction
  - 0 undecided
  - 0 disagreements, counted again in the class each falls in

skipped definitions
  app.report (src/app.gleam:3:1): TypeMismatch

no typed evidence
  app.report `io.println` (src/app.gleam:4:3): no typed resolution (function skipped: TypeMismatch)
```

### wired from a construction

The receiver's construction site already named the function wired into that
field, so the call was charged that value rather than the field's declared
budget:

```gleam
// src/app.gleam
import gleam/io

pub type Logger {
  Logger(println: fn(String) -> Nil)
}

fn shout(message: String) -> Nil {
  io.println(message)
}

pub fn run() -> Nil {
  let logger = Logger(shout)
  logger.println("hi")
}
```

```
ambiguous calls: 2
  - 0 decided by the type inference
  - 1 settled lexically with typed evidence
  - 0 settled lexically with no typed evidence
  - 1 wired from a construction
  - 0 undecided
  - 0 disagreements, counted again in the class each falls in
```

`logger.println` is charged `shout`'s effects. When girard names the member
instead of the wired value, the two are naming different halves of one site —
that is recorded as *compatible*, not as a disagreement.

A wired row reaches the `no typed evidence` listing the same way a lexically
settled one does, and still counts once, in its own class. Adding the same type
error to `run` gives:

```
skipped definitions
  app.run (src/app.gleam:11:1): TypeMismatch

no typed evidence
  app.run `logger.println` (src/app.gleam:13:3): no typed resolution (function skipped: TypeMismatch)
```

### undecided

The receiver's name shadows a module and *neither* reading was established, so
the call is charged `[Unknown]` rather than either one. This is the class that
costs precision, and every row is listed under `undecided shadowed calls` with
the reason:

| Reason | Means |
|---|---|
| `function skipped: <bucket>` | girard declined the enclosing definition |
| `definition dropped for the other build target` | the enclosing definition was not in this build |
| `no reference recorded at this span` | girard walked the definition and recorded nothing here |
| `receiver type not fixed at the access` | the receiver's type was fixed only after the access |
| `not a call target: <kind>` | the resolution is a local binding, a constructor, or a module constant |
| `receiver type is not nominal` | a field of a type with no nominal identity, which nothing can key |
| `resolved to <name>, which is not this site's target` | see [identity mismatches](#identity-mismatches) |

The worked example is under [skipped](#skipped). The general fix is to stop the
shadowing — rename the parameter, or alias the import — which moves the row into
a lexically settled class and the charge off `[Unknown]`.

### disagreements

graded and girard named genuinely different things: graded read the module where
girard proved a field, or the reverse, or graded charged a wired value where
girard reads a module call (the undercharge shape). Each such row is listed with
both halves — the resolution, then graded's own answer:

```
disagreements
  app.go `io.println` (src/app.gleam:4:3): typed resolution field Logger.println (DISAGREES with graded's module call gleam/io.println)
```

Ordinary source does not produce these. A row here is worth reporting as a bug —
in graded, or in the interaction with the girard version in play, which the
version lines name.

### identity mismatches

girard resolved *something* at the span, but under another module, another
function name, or another field label than the site asked about. graded refuses
that resolution rather than charging another site's answer: the row counts once,
under `undecided`, and is listed again because the mismatch is itself the
finding. The row names what was resolved, so you can see where the span landed:

```
identity mismatches
  app.go `list.each` (src/app.gleam:9:3): no typed resolution (resolved to gleam/list.map, which is not this site's target)
```

## The listings

Each section is present only when it has a row, in this order:

| Section | One row per |
|---|---|
| `modules the second run could not read` | module the primary run read and a secondary run did not — the one state in which a non-zero left-out count is expected |
| `skipped definitions` | definition girard declined, with its error bucket |
| `undecided shadowed calls` | call charged `[Unknown]` because neither reading was established |
| `no typed evidence` | call the inference answered nothing for, whatever class it counts in |
| `disagreements` | call the two readings contradict each other on |
| `identity mismatches` | resolution that landed on another target than the site's |
| `versions` | version standing worth acting on — the one section printed after the path dependencies |

Every call row carries `module.function`, the site as written, and its
`file:line:column`, so two calls on one label in one function are two places you
can open. The wording of a row is `checker`'s own — the same text `graded check`
uses in a violation and `graded why` prints in its **typed resolutions**
section, so one site is never worded three ways.

## Path dependencies

A `{ path = "..." }` dependency is typed the same way your own package is; a hex
dependency is not typed and is not listed. Its counts are stated apart, so your
package's own numbers are only ever about your source:

```gleam
// ../logger/src/logger.gleam
import gleam/io

pub fn log(message: String) -> Nil {
  io.println(message)
}

pub fn broken() -> Nil {
  let count: Int = "not an int"
  case count {
    _ -> Nil
  }
}
```

```
modules: 1 read, 0 unread
functions: 1 typed, 0 skipped, 0 left out of every run, 0 unread

path dependencies:
  logger (typed on erlang): 0 modules unread, 1 skipped, 0 left out of every run
```

With no path dependencies the line reads `path dependencies: none`.

## What to act on

| You see | Do |
|---|---|
| a `skipped definitions` row | fix what its error bucket names; a declined definition costs the calls inside it their precision |
| an `undecided shadowed calls` row | rename the shadowing binding, or alias the import, so the site is no longer ambiguous |
| a `no typed evidence` row | nothing, unless the charge is wrong — the site was settled without the inference, and the reason says why it stayed silent |
| a non-zero `left out of every run` on constants | expected where no gated function shares the constant's target |
| a non-zero `left out of every run` on functions | check the `@target` gating, and the `modules the second run could not read` listing |
| a non-zero `unread` | report it — a module the inference read nothing of is not an ordinary state |
| a `disagreements` or `identity mismatches` row | report it, with the version lines |
| a version stated `(verified: <list>)` | nothing to fix; graded's release gates were not run on the version you have |

None of these fail a build. `graded check` is what enforces budgets, and
[Limitations](./LIMITATIONS.md) is where the `[Unknown]` patterns that survive a
clean coverage report are documented.

## See also

- [Reference](./REFERENCE.md) — the `.graded` grammar, the effect-resolution
  order, and the [`graded coverage` summary](./REFERENCE.md#reporting-what-the-inference-read)
- [Limitations](./LIMITATIONS.md) — the value-flow patterns that fall back to
  `[Unknown]` even when the type layer read everything
- [Theory](./THEORY.md) — the graded modal type theory the effect algebra is built
  on
