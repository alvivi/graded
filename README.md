# graded

[![Package Version](https://img.shields.io/hexpm/v/graded)](https://hex.pm/packages/graded)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/graded/)
[![CI](https://github.com/alvivi/graded/actions/workflows/ci.yml/badge.svg)](https://github.com/alvivi/graded/actions/workflows/ci.yml)

> Effect checking for Gleam.

**graded** verifies that your Gleam functions respect their declared effect budgets. The tool reads and writes a single spec file at the root of your package — your Gleam source stays untouched.

## Quick start

```sh
gleam add --dev graded
```

Infer effects for your project:

```sh
gleam run -m graded infer
```

This scans `src/`, analyses every function, and writes two outputs:

- **`<package_name>.graded`** at the project root — the spec file. Contains the inferred effects of every *public* function plus any hand-written `check` invariants, `external effects` hints, and `type` field annotations. Tracked in git.
- **`build/.graded/<module>.graded`** — per-module cache files. Contain the inferred effects of *every* function (public and private). Regenerated freely on each `graded infer` run, never shipped (`build/` is gitignored).

### Example

In a [Lustre](https://hexdocs.pm/lustre/) app, `view` must be pure — it builds HTML from the model without side effects. Enforce this with graded:

```gleam
// src/app.gleam
import gleam/io
import lustre/element.{type Element}
import lustre/element/html

pub fn view(model: Model) -> Element(Msg) {
  io.println("rendering")  // oops — side effect in view!
  html.div([], [html.text(model.name)])
}
```

```
// app.graded — at the project root
check app.view : []
```

```sh
$ gleam run -m graded check
src/app.gleam: view calls gleam/io.println with effects [Stdout] but declared []

graded: 1 violation(s) found
```

Remove the `io.println` and the check passes. Lustre's `init` and `update` functions are also pure — they return `#(Model, Effect(Msg))` where `Effect` is a data description, not an executed side effect.

Function names in the spec file are **module-qualified**: `app.view` means the `view` function in module `app`. Use slashes for nested module paths (`app/router.handle_request`).

## Configuration

graded reads its configuration from a `[tools.graded]` table in `gleam.toml`. Both fields are optional — omit them to get the defaults.

```toml
[tools.graded]
spec_file = "myapp.graded"      # default: "<package_name>.graded"
cache_dir = "build/.graded"     # default: "build/.graded"
```

## Publishing your spec file to consumers

If you're a library author and want downstream packages to read your effect annotations, add the spec file to `included_files` in your `gleam.toml`:

```toml
included_files = [
  "src",
  "myapp.graded",        # ← add this so consumers see your effects
  "gleam.toml",
  "README.md",
]
```

The cache directory under `build/` is gitignored and never ships, regardless of `included_files`.

## Reference

The `.graded` spec language and graded's analysis model are documented in full in **[the Reference](https://hexdocs.pm/graded/reference.html)** — the annotation kinds (`effects`, `check`, `type`, `external effects`, `returns`), effect-set syntax, effect resolution order, higher-order and second-order effect polymorphism, type field effects, the effect-label conventions, and the bundled catalog of common packages.

## Commands

```sh
gleam run -m graded check [directory]         # enforce check annotations (default)
gleam run -m graded infer [directory]         # infer and write effects annotations
gleam run -m graded format [directory]        # normalize .graded file formatting
gleam run -m graded format --check [directory] # verify formatting (CI mode)
gleam run -m graded format --stdin            # format from stdin (editor integration)
gleam run -m graded -- --help                 # show usage (-- passes the flag through gleam run)
gleam run -m graded -- --version              # show the installed version
```

An unknown command or option is a usage error, not a silently-checked directory.

`check` and `infer` scope to the passed directory (default `src/`), recursing into it but never into `build/`. Passing the package root — `graded check .` — scopes to the root's `src/`, so module names come out as they appear in `import` statements (`app`, not `src/app`). To check another project, run graded from that project's root or point it at its `src/`.

## Limitations

graded is **sound, not complete**: it combines syntax-level analysis ([glance](https://hexdocs.pm/glance/)) with type information ([girard](https://hexdocs.pm/girard)), and when it can't statically trace a function value it falls back to the `[Unknown]` effect rather than guess. `[Unknown]` fails an effect budget, so graded never silently *understates* effects — but a few value-flow patterns need a hand-written annotation or a wider budget to resolve.

Idiomatic Gleam — inline callbacks, direct and aliased function references, pipe chains, higher-order functions passing functions by name (including second-order [operator effects](https://github.com/alvivi/graded/blob/main/docs/SECOND_ORDER_EFFECTS.md)), and validator/handler/config records — is handled automatically, including across modules: a fresh checkout resolves transitive chains with no prior `graded infer` (committed `effects` lines always win, and `check` writes nothing to disk).

The handful of patterns that fall back to `[Unknown]` — each with how it shows up and how to work around it — are documented in **[Limitations](https://hexdocs.pm/graded/limitations.html)**.

## License

Apache-2.0
