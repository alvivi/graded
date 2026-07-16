# Contributing to graded

Thanks for helping out. This file is the dev loop and house conventions; for
*what the code is* (architecture, design decisions, effect resolution) read
[AGENTS.md](AGENTS.md) and [docs/](docs/).

The audience here is both human contributors and coding agents, so it is
command-first: run the commands, match the conventions, and a change is
mergeable.

## Setup

Versions are pinned in [`.tool-versions`](.tool-versions). With `asdf` or
`mise`:

```sh
asdf install                 # Erlang + Gleam at the pinned versions
gleam deps download
gleam build
gleam test
git config core.hooksPath .githooks   # local commit-msg + branch-name hooks
pip install gitlint                    # optional: local commit-message linting
```

The hooks in [`.githooks/`](.githooks/) mirror the `Commit checks` CI: a
`commit-msg` hook runs gitlint (a no-op if gitlint is not installed) and a
`pre-push` hook rejects git-flow / conventional branch prefixes. `core.hooksPath`
is per-clone, so the `git config` line above is needed once after cloning.

## Pre-flight checklist

CI runs four gates, in this order. Run them locally before pushing — green here
means green on CI:

```sh
gleam format --check src/ test/    # formatting (test/ too, not just src/)
gleam build --warnings-as-errors   # no warnings allowed
gleam test                         # full suite
```

The glinter lint gate is temporarily disabled: glinter pins glance < 7.0.0,
which conflicts with girard 2.0.0. Restore it (dev dependency + CI step +
this dev loop) once glinter allows glance 7.x.

`gleam format src/ test/` (no `--check`) fixes formatting in place.

## Adding a catalog entry

The versioned catalog under [`priv/catalog/`](priv/catalog/) ships effect specs
for third-party Gleam packages, so consumers resolve calls into those packages
without writing their own annotations. Adding one is the most self-contained way
to contribute.

1. Create `priv/catalog/{package}@{version}.graded`. The version is the lowest
   release whose surface the file describes; at resolution time graded picks the
   highest catalog version `<= ` the consumer's installed version.
2. Write `effects` / `external effects` / `type` lines with **module-qualified**
   names. The grammar, every annotation kind, and the effect-set syntax are in
   [docs/REFERENCE.md](docs/REFERENCE.md); existing entries (e.g.
   `gleam_stdlib@0.70.0.graded`, `lustre@5.0.0.graded`) are working examples.
3. `gleam test` — [`test/release_test.gleam`](test/release_test.gleam)
   validates catalog entries and lints spec lines that match nothing.

## Tests

- gleeunit, one `*_test.gleam` per module under [`test/`](test/); public test
  functions are suffixed `_test`.
- Property tests use [qcheck](https://hexdocs.pm/qcheck/); generators live in
  [`test/generators.gleam`](test/generators.gleam).
- Integration fixtures: put Gleam sources under
  [`test/fixtures/`](test/fixtures/) and their annotations (module-qualified)
  into the single `test/fixtures/fixtures.graded`. Integration tests load these
  end-to-end.

Add or update a test with every behaviour change.

## Conventions

- **Gleam idioms.** Follow Gleam's
  [conventions, patterns, and anti-patterns](https://gleam.run/documentation/conventions-patterns-and-anti-patterns/).
  The ones that come up most here:
  - Return `Result` for fallible functions; never `panic` to signal an error
    a caller could handle.
  - Replace `Bool` with custom types, and make invalid states impossible —
    encode the rule in the type rather than checking it at runtime.
  - Match all variants explicitly; avoid catch-all `_` patterns so the compiler
    keeps flagging unhandled cases.
  - Annotate every module function's arguments and return type.

  Keep new code reading like its neighbours.
- **Comments say what, not why.** Same for changelog and doc prose. Don't
  reference internal planning docs or this guide from code.
- **Doc-comment slashes.** `///` / `////` only on the public API
  (`src/graded.gleam`); use `//` everywhere internal — private entities,
  `src/graded/internal/`, and tests.
- **No ASCII-art rules.** Do not decorate code or docs with divider or banner
  lines built from repeated characters — no `// ====`, `// ----`, `# ----`, or
  similar rows. A plain comment naming a section is fine; the row of dashes or
  equals signs is not.
- **Semantic sections.** Group a file into sections by topic, each introduced
  by a plain `//` title. Add a short description — a blank `//` line, then one
  or two sentences — when it explains the relationship between the entities,
  an important invariant, or why the section exists; avoid repeating adjacent
  entity documentation:

  ```gleam
  // Section name
  //
  // One or two sentences on what this section covers and why.
  ```

  A file that is a single section needs no header; its module doc is enough.

  Order the entities within a section for readability: lead with the
  public API (including `pub opaque` types), then the private implementation,
  and within each put constants before types before functions — but keep a type
  next to the functions that build and operate on it, put an entry point ahead
  of the helpers it calls, and fall back to alphabetical order only to break
  ties among unrelated peers. Test modules follow the same sectioning and
  module-doc rules, but keep their sections in narrative order (by feature or
  scenario) rather than reordering by visibility or kind.
- **No circular dependencies** between the modules under `src/graded/internal/`.

## Changelog & commits

- Record every notable change in [CHANGELOG.md](CHANGELOG.md). The format is
  [Keep a Changelog](https://keepachangelog.com/) and the project follows
  [SemVer](https://semver.org/). Entries lead with a **bold one-sentence
  summary** of the observable change, then explain — match the existing style.
- Version bumps and `Release vX.Y.Z` commits are cut by the maintainer.
- Branch off `main` with a short, descriptive kebab-case name
  (`dependency-field-resolution`). This project does not use git-flow — no
  `feature/`, `fix/`, `release/`, or similar prefixes.

### Commit messages

Follow [the seven rules of a great commit message](https://chris.beams.io/posts/git-commit/#seven-rules):

1. Separate subject from body with a blank line.
2. Limit the subject line to 50 characters.
3. Capitalize the subject line.
4. Do not end the subject line with a period.
5. Use the imperative mood in the subject line ("Resolve …", not "Resolved …").
6. Wrap the body at 72 characters.
7. Use the body to explain what and why, not how.

Do **not** use [Conventional Commits](https://www.conventionalcommits.org/) —
no `feat:` / `fix:` / `chore:` prefixes. Write commit messages and PR
descriptions as your own work, and do not add AI-attribution trailers
(`Co-Authored-By: Claude …`, "Generated with …", and the like).

A `Commit checks` workflow enforces the mechanical rules on every PR via
[gitlint](https://jorisroovers.github.io/gitlint/) (subject ≤ 72, capitalized,
no trailing period, body wrapped at 72; config in [`.gitlint`](.gitlint)) and
rejects git-flow / conventional branch prefixes. Imperative mood and the
what-and-why body are on you.
