# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- An `assume` line over your own or a dependency's `@external` now answers
  alone even where a Gleam fallback body runs; previously the body's effects
  were unioned into what callers pay. Explanations quote the suppressed half,
  the external's own `check` line still weighs the body, and catalog and
  module-level assumptions keep the union.
- A written `assume … where returns` clause on such an external is now
  trusted, where it was previously refused whole.
- A boundless `assume` over a higher-order external now charges its callback
  argument however the external is reached — called, passed to a helper, wired
  into a field, referenced by a sibling — where only a direct call charged it
  before. Checks that passed because the external was handed around as a value
  may now fail; a line with its own bound list is unaffected.
- A module-level `assume` says nothing about the callbacks its functions are
  handed, so `assume myapp/util : []` over `util.each(cb)` now charges each
  caller the callback it passes. Previously that callback was charged to
  nobody.
- A Gleam function a catalog entry declares — `gleam/list.map` and kin —
  charges its callback when passed as a value or wired into a field. Direct
  calls are unchanged.

### Fixed

- A callback parameter spelled through a `fn` type alias — `run(action:
  Action)` with `type Action = fn() -> Nil` — now resolves like a directly
  annotated one: the bound is written on the inferred line, the call site binds
  the argument, and a second-order parameter whose own callback is aliased
  keeps its shape. Such a call read `[Unknown]`, or, where a lift discharged
  the argument, an under-approximation. A boundless `assume` over an external
  whose callback is aliased now charges that callback to its callers too, so a
  check that passed on the old answer may now fail.
- A helper whose callback parameter carries no `fn(...)` annotation now charges
  its callers in the same module the callback's own effects, as callers in
  another module already paid. The same answer now reaches a reference to that
  helper handed to a higher-order function. Both read `[Unknown]` before.
- A call from inside a walked fallback body to an external declared for the
  walk's targets now charges its callback arguments beside the declaration,
  instead of the declaration alone.
- An import cycle no longer drops a higher-order external's callback charge:
  callers pay each callback argument's effects beside the body's `[Unknown]`.

## [0.17.0] - 2026-08-26

### Added

- Catalog entries for the 1.x majors of `gleam_stdlib`, `gleam_erlang` and
  `gleam_otp`. The old majors stay bundled, so older installs keep resolving.
- An `assume` line over a function takes a bound list.
  `assume myapp/ffi.each(f: [f]) : [f]` charges a caller the callback
  argument's actual effects, and `assume myapp/ffi.wrap(cb: [cb]) : []
  where returns : [cb]` declares the closure a producer hands back. As ever,
  nothing verifies an assumption. The effects term is flat — anything deeper
  reads `[Unknown]` — and bounds on a module or field path are a parse error.
- Two new warnings on bounded lines: an effects-term variable no bound's
  payload binds (no call site can ever resolve it), and a payload reusing
  another bound's parameter name (`cb: [e], other: [cb]`), which can charge
  the term and the `where returns` clause different arguments.

### Changed

- The catalog entries for `simplifile`, `gleam_httpc`, `gleam_http` and
  lustre's `server_component` now cover their full surfaces, resolving calls
  that previously read `[Unknown]`.
- `gleam/crypto.strong_random_bytes`, `gleam/float.random` and
  `gleam/int.random` are now charged `[Random]` instead of reading as pure.
- An `assume` line's `where returns` clause is accepted when the line's own
  bounds scope its variables, instead of being dropped for not being ground;
  the warning for an unscoped clause lists only the open variables.
- A `where` region takes a comma-separated clause list. `returns` is still the
  only key graded reads; any other key now parses, warns once per line, and is
  kept verbatim by `graded format` and `graded infer` instead of failing the
  file.
- A statement past 80 columns wraps its `where` region onto an indented
  continuation, one clause per line; the reader accepts either form.

### Fixed

- A decoupled bound (`cb: [e]`) scoping a `where returns` clause now binds
  the clause's variable by parameter name, on `effects` and `assume` lines
  alike — previously `[Unknown]`, or, with an aliased payload
  (`cb: [e], other: [cb]`), silently another parameter's argument. The same
  fix covers a producer called unqualified in its own module.
- `graded pack` refuses a tarball whose contents name an absolute path, instead
  of copying the host file at that path into the archive it tells you to
  publish. A name escaping the package with `..` is refused too.
- `graded pack` refuses an archive carrying a symlink, directory, or device
  member, naming the entry and its kind. Such a member was dropped from the
  output, and the run then failed on a files-list mismatch that named nothing.
- `graded pack` refuses a tarball whose stored `CHECKSUM` does not match its
  contents, rather than replacing it with a fresh one and handing you an
  archive that verifies.
- A malformed tarball now says what is wrong with it — not a tar, a missing
  member, a `metadata.config` that does not parse, a `contents.tar.gz` that is
  not gzip — instead of failing with a raw Erlang term.
- `graded pack` no longer follows a symlink planted at its temporary output
  path while it writes.
- A `where returns` clause on a path dependency that vendors a catalogued
  package now resolves the returned function at the call site, instead of
  charging it `[Unknown]`.
- A clause variable its own line does not scope no longer binds to a call
  argument. Such a clause resolves to `[Unknown]`, and `graded check` reports it
  as open.
- An operator-spelled effects term (`m.f : fn(x) -> [x]`) no longer fails the
  spec file. Every spelling of a statement — bounded or not, any status —
  now reads the same term language, and an operator term reads `[Unknown]`.

## [0.16.0] - 2026-08-24

### Changed

- A call into a dependency `@external` whose Gleam fallback body runs on a
  target you compile is now charged what that body does — read from the
  dependency's source under `build/packages` and walked like one of your own —
  instead of `[Unknown]`. A field call in such a body resolves through the
  field `assume` lines in reach, the dependency's own and yours for its types.
  Callers of `gleam/dict.insert` and its stdlib kin lose their inherited
  `[Unknown]`, so a `check f : [Unknown]` written over the old answer now
  fails, and a committed `effects` line for such a caller changes on the next
  `graded infer`.
- `graded effect` for a dependency `@external` with a running fallback now reads
  that dependency's module before answering, so the query and `graded check`
  quote the same charge.
- graded requires girard 2.1.1 or later, whose shipped spec is written in the
  current grammar. 2.1.0's carried a retired line, which graded rejected the
  file over, resolving calls into girard as unannotated.

### Fixed

- A field call on a parameter typed from its annotation alone (`insert(r:
  Runner)`) now reads a module-qualified `assume myapp/store.Runner.run :
  [Disk]` line, not only a bare `assume Runner.run`. Such a line keyed nothing,
  so the call stayed polymorphic in the field and a caller constructing the
  record specialized the declared effect away.
- A field call on a parameter annotated with an imported type (`insert(r:
  model.Runner)`, however that import is written) now reads the field `assume`
  keyed by the module defining it. A qualified annotation named no type at all,
  so the call cost `[Unknown]`.

## [0.15.0] - 2026-08-23

### Changed

- **Breaking.** `external effects` and `type` lines are now written `assume`.
  What a line covers is read off its path: `assume gleam/list : []` a module,
  `assume gleam/io.println : [Stdout]` a function, `assume
  myapp.Handler.on_click : [Dom]` a function-typed field. The rewrite is
  mechanical:

  ```sh
  sed -i 's/^external effects /assume /; s/^type /assume /' your_package.graded
  ```

  An old spelling is a parse error naming the line and its rewrite, so nothing
  is silently reinterpreted. Bundled catalog files are already rewritten; a
  dependency's spec must be regenerated before its entries are read again.
- **Breaking.** A returned operator is now a `where returns` clause of the
  statement it belongs to, not a line of its own: `effects myapp.make_logger :
  [] where returns : [Stdout]`, and for a foreign producer `assume
  myapp/ffi.make_client where returns : [Net]`. `returns` and `external
  returns` lines are parse errors naming their rewrite — delete an inferred one
  and re-run `graded infer`, rewrite a declared one as an `assume` clause.
- **Breaking.** Upgrade every consumer of a spec to this version *before*
  rewriting that spec to the new grammar. An older graded reads a line it does
  not know as no line at all, so it checks the package as if unannotated and
  says nothing — the one direction the parse errors above cannot cover.
- An `assume` may now carry a clause alone: `assume myapp/ffi.make_client where
  returns : [Net]` states what the producer hands back and claims nothing about
  its own effect, so the catalog or a dependency's spec keeps answering for it.
- An inferred clause now carries a bound for every callback it mentions —
  `effects myapp.traced(action: [action]) : [] where returns : fn(cb) ->
  [Stdout, action([cb])]` — so a decorator whose callback runs only inside the
  closure it returns resolves at the call site instead of costing `[Unknown]`.
- An assumption no longer deletes the inferred clause of the functions it
  covers. `assume db : []` declares what those functions *do*; what one of them
  *returns* is a separate claim, so the clause stays in the spec and consumers
  still resolve the returned function.
- A clause whose variables name no callback parameter of the function is
  flagged by the spec lint and resolves to `[Unknown]`, replacing the warning
  about a polymorphic `external returns` operator. On an `assume` line the
  warning names that channel's own rule: a declared operator must be ground,
  since an assumption carries no bound list to scope a variable with.
- A `check` on a field (`check myapp.Handler.on_click : []`) now warns that
  nothing verifies that shape yet, rather than that the name matches no
  function, and a `check` carrying a clause warns about the clause alone — the
  effects budget on that line is enforced as on any other `check`.

### Fixed

- A `.graded` spec file with a line the parser rejects is now an error naming
  the file and the line, from every command; `format --stdin` names it too, and
  a *dependency's* unparseable spec is a warning naming the package, with its
  entries ignored. Such a file used to read as empty — `check` passed with
  nothing to check, and `infer` wrote its merge over the hand-written lines.
- `graded pack` now refuses to inject a spec the parser rejects, naming the
  file and the line and leaving the tarball untouched. It used to publish one
  happily, and every consumer's loader then dropped the whole file — the
  package shipped with no effect metadata at all.
- A near-miss of the clause keyword — `check myapp.f : [] where returns:
  [Stdout]` or `check myapp.f : []where returns : [Stdout]` — is now a parse
  error instead of an effect variable named after the typo that formatted back
  byte-identically, so a clause that did nothing looked like one that worked.
  An effect set may hold only bare labels and variables.

## [0.14.0] - 2026-08-20

### Added

- New `graded catalog [package[@version]]` command: lists the bundled catalog
  files, or prints the one selected for an installed package (or an explicit
  version), as a valid `.graded` file with a header comment naming the
  selection. Selection follows the `manifest.toml` of the package enclosing the
  directory given — or the current directory, from a subdirectory too — and a
  directory, manifest or catalog directory it cannot read is reported by name
  instead of answered around. Shows the bundled catalog only; `graded effect`
  answers what wins for a name.

### Fixed

- A dependency installed at a pre-release or build-metadata version
  (`1.2.0-rc.1`, `1.2.0+build.5`) now resolves against the catalog entry for
  its `1.2.0` release. Such a version compared as `0.0.0`, so the highest
  bundled entry stood in for it.

## [0.13.0] - 2026-08-20

### Added

- `external returns <module>.<function> : <operator>` declares the closure an
  FFI producer hands back, so calling it resolves instead of costing
  `[Unknown]`. The line is hand-written and preserved by `graded infer`, and it
  answers where the declaration stands alone — a call refuses it where the
  declaration is out of the build's reach or a Gleam fallback body runs beside
  it, and says which. Dependencies and path dependencies can ship the line for
  their own producers.

## [0.12.1] - 2026-08-19

### Fixed

- A catalog entry that both declares a function `external effects` and carries
  an `effects` line for it now resolves to the declaration, so the function's
  effects no longer come from a term whose parameter bounds were dropped.
- Two catalog files keying the same function now settle it whole: the file
  whose `effects` line wins the term supplies its parameter bounds too. A
  higher-order entry another package declares `external effects` no longer
  loses its bounds — and with them its callers' effects — depending on which
  catalog file was read last.
- A stale duplicate copy of a dependency module left under `build/packages` —
  a dependency moved to a path dependency without a `gleam clean` — no longer
  has a say in anything graded reads from dependency source. The copy the build
  compiles against alone decides whether an `external effects` line naming one
  of its functions is dead, which parameter signatures match at call sites,
  which update builders resolve, and which of its functions are foreign; a
  winning copy graded cannot read contributes nothing and still shadows the
  stale one beside it.

## [0.12.0] - 2026-08-18

### Added

- New `graded why <name>` command: explains where a function's effects come
  from, one line per effect contributor, naming the source that resolved each
  one or the reason it stayed `[Unknown]`. Works for any project function,
  private ones included, with or without a `check` line, and writes nothing.
- New `graded effect <name>` command: looks up a function or type-field
  effect and prints it in prose, without writing the spec file or the cache.
  Pass `--format=graded` for a `.graded` line that parses back.
- `graded effect` names the source that answered — your spec, a dependency's
  shipped spec, a catalog entry, inference — as a `source:` line in prose and
  a `// resolved from ...` comment in `--format=graded`.
- New `graded infer --dry-run` flag: prints a line diff of what `infer` would
  change in the spec file, and writes nothing.
- New `graded pack` command: injects the configured `.graded` spec into the
  hex tarball built by `gleam export hex-tarball`, so the spec ships with the
  package and downstream projects read it with no setup.
- New `graded --help` and `graded --version`.
- New `[tools.graded].targets` setting for packages built for more than the
  one target `gleam.toml`'s `target` field can name.
- A record field set through a builder (`with_*`) record update now resolves
  to the set value's precise effect, last-write-wins, instead of `[Unknown]`
  — including when the builder lives in a dependency.

### Changed

- BREAKING: a per-function `external effects` line naming one of your own
  Gleam-bodied functions is now ignored, with a warning — the body is what
  runs, and every path now walks it. `graded infer` deletes the line and
  writes the `effects` line it was suppressing. There is no replacement
  override: fix the source or widen the `check` budget. The module-level
  `external effects <module>` form is unchanged.
- A `check` line on an `@external` function is now verified against what
  declares it — an `external effects` line, a module-level external, or a
  catalog entry — instead of silently passing. Without a declaration it
  checks against `[Unknown]`, and a stale `effects` line no longer answers
  for an external anywhere: not for its callers, not for `graded effect`.
- Foreign code is now opaque on every channel a value carries its effects
  through: a closure returned by an `@external`, or a record field wired
  through one, reads `[Unknown]` instead of inheriting the Gleam fallback
  body's inferred effect. `graded infer` no longer writes a `returns` line
  for an `@external`, and a dependency's shipped `effects`/`returns` line for
  a function its source declares `@external` is refused. Specs that leaned on
  fallback-derived results will report new violations; wrap the producer in
  ordinary Gleam or annotate the field with a `type` line.
- graded now reads build targets. `gleam.toml`'s `target` (or
  `[tools.graded].targets`) decides which `@external` implementations are
  compiled: a Gleam fallback body that runs on a compiled target is charged
  to every caller and weighed against the function's own `check` line, a body
  no compiled target reaches is dead text and charged nothing, and a
  declaration covering only targets the build never compiles reads
  `[Unknown]` under a message that says why. `@target` narrows a single
  function the same way.
- A package that names no `target` now reads Gleam fallback bodies on Erlang
  — the compiler's own default — so stdlib functions with JavaScript
  externals (`list.append`, `dict.from_list`, ...) no longer resolve to
  `[Unknown]` in a default project.
- Violation messages now say why an effect is unresolved (``whose type could
  not be resolved``, ``an external with no declared effects``, ...) and where
  a resolved one came from (``(from gleam_stdlib's catalog entry)``).
- Violation messages describe call sites in prose — ``calls field `resolver`
  on `config` ``, ``calls a computed function value`` — instead of printing
  internal sentinels, and say "unresolved effects" only when the reported set
  carries `Unknown`.
- `graded check` flags `external effects` lines that resolve to nothing — a
  function or module no dependency, catalog entry, or project module can
  place — mirroring the existing `check` and `type` lints.
- The "passed as a value" warning now quotes the declaration callers are
  actually charged rather than a stale spec line, and stays silent when the
  whole effect set is `[Unknown]`.
- `graded effect` reads publicity and existence from your source: a private
  function, a private `@external`, or a spec line naming a function your
  source doesn't define now exits non-zero, and a module that fails to parse
  is reported as such instead of being answered from the spec.
- A directory inside a package's `src/` now narrows what is reported, not
  what is analysed, so a scoped `graded check` reports exactly what the
  whole-package run reports for those files. A scoped `infer` still writes
  the whole package's spec.
- Calls into girard resolve from the spec girard now ships in its hex
  tarball. graded requires girard 2.1.0 or later.
- An unknown command or option now prints a usage error and exits non-zero
  instead of being treated as a directory to check.

### Fixed

- A `check` line admitting `[Unknown]` no longer fails on an effect variable
  the caller has no way to bind; such a variable now reads as the
  `[Unknown]` it is on every channel.
- A call to a function-typed parameter no `check` line names now resolves to
  that parameter's effects instead of `[Unknown]`, agreeing with what
  `graded effect` answers for the same function.
- `graded check` no longer reports one violating call once per call site
  that reaches it, and violations print in source order.
- A spec file that exists but can't be read now errors with
  `Could not read: <path>` instead of being treated as absent.
- A dependency's shipped `external effects` declarations now resolve for
  consumers; previously such functions reported `[Unknown]`.
- A path dependency's committed spec now outranks the bundled catalog for
  the same function, as documented.
- A committed higher-order `effects` line now applies its own parameter
  bounds with its own term, instead of pairing the term with bounds
  re-derived from source.
- `graded infer` no longer writes an effect line that fails to parse back;
  an under-applied effect operator renders as `[Unknown]`.
- A record field wired to a function from the module doing the wiring now
  resolves to that function's effect instead of `[Unknown]`.
- A field a builder overlay does not replace now resolves through a
  traceable base instead of `[Unknown]`.
- A module resolving a field through a builder overlay now reports the same
  effect to its consumers as it does when checked directly.
- A record field wired to one of the producer's own functions now resolves
  in the module that defined it, never against a same-named function of the
  consumer's.
- A field call on a receiver graded can't trace to a construction no longer
  borrows the effect of an unrelated construction elsewhere in the package;
  it stays conservative instead of understating.
- A record field wired from a producer whose return type is a module-local
  alias to a function type now infers the producer's real effect instead of
  `[Unknown]`.
- A polymorphic producer wired into a field now binds the construction-site
  argument's effect instead of dropping it.
- A residual effect variable that collides with a returned closure's
  callback parameter now grounds to `[Unknown]` instead of being captured
  and silently dropped.
- README documentation links now point at the published hexdocs pages
  instead of 404-ing on the package page.
- `graded check`/`infer` pointed at a package root now scope to `src/`
  instead of reporting all checks passed while checking nothing.

## [0.11.0] - 2026-07-16

### Changed

- Modules using arithmetic in bit-array pattern segment sizes
  (`<<value:size(n * 8)>>`) now parse and infer instead of collapsing every
  function in them to `[Unknown]`, via glance 7.0.0 (through girard 2.0.0).

### Fixed

- A computed receiver whose helper returns one of its parameters — as a bare
  parameter, a receiver path (`config.options`), or a constructor rebuilt
  from parameter-rooted fields — now forwards field effects instead of
  collapsing to `[Unknown]`. Same-module and cross-module helpers both
  resolve; anything the provenance can't trace still widens.
- A helper returning a `case`/`if` forwards through every branch when all
  branches are parameter-rooted; a branch it can't trace still widens the
  whole receiver.
- A helper that rebuilds a record from a mix of parameters and literal
  defaults now forwards the parameter-rooted fields instead of collapsing
  the whole build, and field shorthand (`Options(resolver:)`) resolves to
  the parameter it puns.
- A labeled computed-receiver call now reorders its arguments into declared
  parameter order before substituting, forwarding exactly as a positional
  call does.
- A helper returning a parameter through direct tail recursion now resolves
  by a bounded fixpoint instead of widening.
- A path dependency inferred from source now propagates its return-value
  provenance to the consumer, so computed-receiver calls into it forward
  field effects like same-package modules do.
- Function-typed field effects now forward through more receiver argument
  shapes: a parameter passed directly, a field path rooted at a caller
  parameter, an inline constructor or factory call wired from a caller
  parameter, and a let-bound alias of any of these. A caller bound such as
  `config.options.resolver: [Stdout]` discharges the forwarded effect;
  left unbound it still collapses to `[Unknown]`.
- Calling a let-bound alias of a parameter (`let f = handler; f(x)`) now
  resolves through the parameter's bound, shadowing a same-named
  unqualified import.
- A recursive function reached through a higher-order call (`list.flat_map(
  children, walk)`) now resolves to its real effect instead of `[Unknown]`.
- graded now finds its bundled catalog relative to its own install
  directory instead of the working directory, and warns when none can be
  found instead of degrading silently.
- `infer` and `check` against an out-of-tree source directory now root the
  spec and cache at that project's own `gleam.toml`, not the passed
  directory.

## [0.10.1] - 2026-06-26

### Fixed

- A function-typed field on a dependency-defined type now resolves to its
  declared effect instead of `[Unknown]`: the dependency's source is read
  to type the receiver, so a `type dep/repo.Repo.find : [Storage]` line
  resolves at the call site.
- A dependency's `type` field annotations, and the catalog's, are now
  loaded into the knowledge base, so a consumer resolves field calls on
  dependency-defined records without re-declaring them.

## [0.10.0] - 2026-06-25

### Added

- Lustre 5 catalog entry (`lustre@5.0.0.graded`); 4.x projects keep
  `lustre@4.0.0.graded`.
- `graded check` warns on spec lines that match nothing: a `check` line
  naming no project function, or a `type` line resolving no callable field.
- Function-typed record fields on receivers with no traceable construction
  site now resolve polymorphically as field-effect variables, dischargeable
  by a field bound or a `type` line; left unbound they concretize to
  `[Unknown]`, never silently `[]`.

### Fixed

- A module-level `external effects <module>` declaration now governs a path
  dependency's inferred module with its full effect set, instead of being
  flattened to pure or shadowed by source inference.
- A module-level external now governs the consumer's own project modules
  too, at both `check` and `infer` time, instead of being shadowed by
  in-memory inference of the module's source.

## [0.9.4] - 2026-06-24

### Fixed

- A closure passed to a second-order parameter now keeps the callable
  bindings captured at its creation site, so a name bound there
  (`let suffix = string.append`) resolves precisely on re-analysis instead
  of `[Unknown]`.
- Expression-valued callees — an immediately invoked closure, an applied
  returned function, a `case`/`if` selecting the function being called —
  now propagate the callee's effect instead of being inferred pure; an
  opaque computed callee resolves to `[Unknown]` rather than `[]`.
- A parameter that shadows an unqualified import now resolves to the
  parameter, not the import.
- A let-bound closure called directly by name (`let helper = fn(x) { ... };
  helper(1)`) now resolves to its body's effect instead of `[Unknown]`.
- More higher-order closure patterns resolve precisely: callbacks with
  ordinary value parameters, callbacks that ignore a higher-order
  parameter, producers whose returned closure captures a first-order
  callback, and immediately invoked closures with several arguments.
- An immediate application of a returned function (`make(io.println)()`) no
  longer drops the producer's arguments, and an internal effect variable no
  call site can bind collapses to `[Unknown]` instead of leaking.

## [0.9.3] - 2026-06-23

### Fixed

- A same-module (unqualified) call into a bodyless `@external` now applies
  its `external effects` declaration, matching the cross-module path.
  Undeclared externals still resolve to `[Unknown]`.

## [0.9.2] - 2026-06-23

### Fixed

- Record update expressions (`Rec(..base, field: expr)`) now have their
  updated field values walked, so their effects are counted.
- Dependency, catalog, and path-dependency resolution now read from the
  checked project's own root instead of the process working directory.
- A higher-order function defined in a path dependency now discharges its
  callback parameter's effect at the call site instead of leaking the
  parameter's effect variable, reaching parity with `build/packages`
  dependencies.
- graded now compiles and runs on the JavaScript target.

## [0.9.1] - 2026-06-23

### Added

- Catalog entries for the pure value libraries `bigi`, `glearray`, `iv`,
  and `gleam_community_maths`.

### Fixed

- A higher-order callback passed with a Gleam label (`apply(with: parser)`)
  now binds to its parameter, matching positional arguments.

## [0.9.0] - 2026-06-22

### Added

- Field bounds: a `check` line can bound a function-typed field reached
  through a parameter (`check myapp.view(handler.on_click: [Dom]) :
  [Dom]`), taking priority over receiver-type resolution.
- A field bound whose path matches no field call in the body, and a
  parameter bound naming no declared parameter, now emit warnings.

### Fixed

- `gleam/time/calendar.utc_offset` is now `[]` instead of `[Time]`: it is
  a compile-time constant, not a clock read.
- A same-module named function passed to a first-order fn-typed parameter
  now resolves to its actual effect instead of `[Unknown]`.

## [0.8.1] - 2026-06-22

### Changed

- Dropped the `stdin` and `gleam_yielder` dependencies; `graded format
  --stdin` now reads standard input through a small built-in FFI. The
  `stdin` package capped `gleam_stdlib` below `1.0.0`, making graded
  uninstallable alongside packages requiring `gleam_stdlib >= 1.0.0`.

## [0.8.0] - 2026-06-21

### Added

- Catalog entries for 27 more of the most-used Gleam packages: glance,
  glexer, justin, snag, ranger, marceau, gleam_community_colour,
  gleam_community_ansi, glam, splitter, gleam_bitwise, gleam_javascript,
  and gleam_deque (pure); glisten, mist, wisp, pog, gleam_fetch,
  gleam_hackney, gleam_cowboy, gleam_elli, shellout, logging, argv,
  directories, birl, and youid (effectful). The catalog now covers all of
  the core `gleam-lang` runtime, data, and HTTP packages.
- New effect labels `Network`, `Database`, `Exec`, and `Random`.

### Fixed

- A function in both an installed dependency's spec file and the bundled
  catalog now takes its effects from the dependency's spec file.
- Effects inside `panic`/`todo`/`echo` messages and bit-string segments are
  now counted.
- `graded format` and `format --check` now error on an unparseable spec
  file instead of succeeding silently.
- A malformed `gleam.toml` is now reported as an error instead of being
  silently ignored.

## [0.7.0] - 2026-06-19

### Added

- Second-order (higher-kinded) effect variables: the effect representation
  is now an `EffectTerm` (a lambda calculus with union), so an operator
  parameter (`action: fn(fn() -> Nil) -> a`) infers a curried application
  over its callbacks and beta-reduces to concrete effects at each call
  site. Named refs, closures, `case`/`if` branches, and returned operators
  all lift; the `.graded` syntax gained operator applications and bounds
  (`fn(a, b) -> [a, b]`), with first-order lines unchanged. See
  [docs/SECOND_ORDER_EFFECTS.md](docs/SECOND_ORDER_EFFECTS.md).
- More value flow resolves instead of `[Unknown]`: blocks resolve to their
  tail expression; returned operators cross modules and packages via
  `returns` lines; record fields wired to an inline closure infer from the
  body; `check` auto-infers project modules missing from the spec (in
  memory, nothing written); operator-typed record fields are lifted and
  applied; and a producer returning or wrapping an operator parameter (a
  decorator) resolves.
- `Environment` effect and an envoy catalog entry for process env-var
  access.

### Fixed

- `@external` (FFI) functions are now `[Unknown]` by default — foreign code
  is opaque, and a Gleam fallback body only runs on the other compile
  target. Opt into a precise effect with `external effects` or the catalog.
- Field calls on a record built at several construction sites no longer
  leak operator bounds; the union of operators is applied to the call's
  arguments and distributes.
- `infer` no longer hangs on densely mutually-recursive modules: analysis
  is memoized per module and SCC-partitioned, with results unchanged.

### Notes

- Remaining residuals, all sound and collapsing to `[Unknown]`: a parameter
  selected through a branch, a field wired to a constructor parameter, a
  function reached through arbitrary computation, a `use`-tailed return,
  and external/FFI code. Annotate explicitly where needed.

## [0.6.0] - 2026-04-21

### Added

- Same-function value flow: calls through local `let` bindings now
  resolve — function-ref aliases (`let f = io.println; f("hi")`,
  transitively), and record construction (`let v = Validator(to_error:
  io.println); v.to_error("oops")`), labelled or positional. Shadowing and
  Gleam's block/closure scoping are respected.

### Notes

- Cross-function record construction remains opaque and still needs
  type-level annotations. Pattern destructuring and `use`-bound names are
  deliberately treated as opaque.

## [0.5.0] - 2026-04-13

### Added

- Effect polymorphism: effect variables let one signature propagate a
  callback's effects (`effects myapp.map_with_log(f: [e]) : [Stdout, e]`);
  `graded infer` produces them automatically for fn-typed parameters.
- Call-site substitution: at each call, effect variables bind to the
  concrete effects of the argument passed — labeled or positional, across
  modules and into dependencies.
- Dependency parameter positions are learned by parsing each dependency's
  source, so positional arguments to polymorphic dependency functions
  resolve without labels.
- Wildcard `[_]` documented as the top of the effect lattice — a declared
  budget of `[_]` permits any effects.

### Changed

- Violation messages now hint at a `check` bound or a concrete argument
  when the actual effects contain unresolved effect variables.

## [0.4.2] - 2026-04-12

### Fixed

- Added `gleam/dynamic/decode` to the `gleam_stdlib` catalog; decoder
  combinators are pure but resolved as `[Unknown]`.
- Cross-module type constructors (`types.NotFound(id)`) now resolve as
  pure, matching unqualified constructors; effects inside a constructor's
  arguments still propagate.

## [0.4.1] - 2026-04-11

### Fixed

- `graded infer` now reads the spec file's `external effects` and `type`
  declarations into the knowledge base before walking the import graph, so
  functions calling a module declared pure stop inferring `[Unknown]`.

## [0.4.0] - 2026-04-10

### Added

- `[tools.graded]` config table in `gleam.toml`, with `spec_file` and
  `cache_dir` fields.

### Changed

- Annotations moved out of `priv/graded/`: each package now has a single
  spec file at the project root (default `<package_name>.graded`) holding
  the public-API effects, `check` invariants, externals, and `type` lines,
  while per-module inferred effects live in `build/.graded/` as a
  regenerable cache.
- Spec-file names are now module-qualified (`myapp/router.handle_request`,
  `type myapp.Handler.on_click : [Dom]`); cache files keep bare names.
- Library authors must add their spec file to `included_files` in
  `gleam.toml` for consumers to see their effects.
- No automatic migration: move every line from `priv/graded/*.graded` into
  the root spec file, qualify the names, run `graded infer`, and delete
  the old directory.

## [0.3.0] - 2026-04-07

### Added

- Cross-module effect propagation: inferred effects from sibling project
  modules are used when analyzing other modules in the same project.

## [0.2.0] - 2026-04-07

### Added

- Catalog entries for `gleam_time` (`system_time`, `local_offset`,
  `utc_offset` are `[Time]`, the rest pure) and `houdini` (pure).
- Automatic effect inference for path dependencies declared in
  `gleam.toml`, two-pass so cross-dependency calls resolve, loading any
  existing `.graded` files for parameter bounds.

### Fixed

- Record constructors (`Ok`, `Error`, `Some`, custom types) are no longer
  inferred as `[Unknown]`; constructors are always pure.

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
- Catalog entries for `gleam_stdlib`, `gleam_erlang`, `gleam_otp`,
  `gleam_http`, `gleam_httpc`, `gleam_json`, `gleam_regexp`,
  `gleam_yielder`, `gleam_crypto`, `lustre`, `lustre_http`, `simplifile`,
  `filepath`, `tom`.

[0.17.0]: https://github.com/alvivi/graded/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/alvivi/graded/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/alvivi/graded/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/alvivi/graded/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/alvivi/graded/compare/v0.12.1...v0.13.0
[0.12.1]: https://github.com/alvivi/graded/compare/v0.12.0...v0.12.1
[0.12.0]: https://github.com/alvivi/graded/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/alvivi/graded/compare/v0.10.1...v0.11.0
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
