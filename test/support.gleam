// Fixture-tree scaffolding shared by the integration tests: materialise file
// trees (creating parent directories as needed) and delete them on cleanup.

import filepath
import gleam/list
import gleam/result
import gleam/string
import graded
import graded/internal/config
import graded/internal/effects
import simplifile

// A `gleam.toml` for a package built for both targets. What a library its
// consumers compile either way declares, and the only configuration under which
// an `@external` declared for one target and the Gleam fallback body that runs
// on the other are both in reach: a plain `target` names exactly one, and where
// no field names any, fallback bodies are read on the compiler's default alone.
pub fn dual_target_toml(package_name: String) -> String {
  "name = \"" <> package_name <> "\"

[tools.graded]
targets = [\"erlang\", \"javascript\"]
"
}

// The files of a project named `package` whose dependencies are the hex
// packages `#(name, version)`, each installed: `gleam.toml` declaring them, the
// manifest Gleam writes for them, and the install record under
// `build/packages`. The packages' own sources are the caller's to add.
pub fn hex_tree(
  package: String,
  dependencies: List(#(String, String)),
) -> List(#(String, String)) {
  let declared =
    list.map(dependencies, fn(dependency) {
      dependency.0 <> " = \">= 0.0.0\"\n"
    })
  let entries =
    list.map(dependencies, fn(dependency) {
      "  { name = \""
      <> dependency.0
      <> "\", version = \""
      <> dependency.1
      <> "\", build_tools = [\"gleam\"], requirements = [], source = \"hex\", outer_checksum = \"0\" },\n"
    })
  let requirements =
    list.map(dependencies, fn(dependency) {
      dependency.0 <> " = { version = \">= 0.0.0\" }\n"
    })
  let installed =
    list.map(dependencies, fn(dependency) {
      dependency.0 <> " = \"" <> dependency.1 <> "\"\n"
    })
  [
    #(
      "gleam.toml",
      "name = \""
        <> package
        <> "\"\n\n[dependencies]\n"
        <> string.concat(declared),
    ),
    #(
      "manifest.toml",
      "packages = [\n"
        <> string.concat(entries)
        <> "]\n\n[requirements]\n"
        <> string.concat(requirements),
    ),
    #(
      "build/packages/packages.toml",
      "[packages]\n" <> string.concat(installed) <> "\n[git]\n",
    ),
  ]
}

// A project depending on one installed hex package, `real`, whose module
// `real` defines `f`, with `spec` as the root's spec. `real` is in no catalog.
// Returns `directory`.
pub fn real_dependency_tree(directory: String, spec: String) -> String {
  reset_directory_mode(directory <> "/build/packages")
  write_fixture(
    directory,
    list.append(hex_tree("app", [#("real", "1.0.0")]), [
      #("src/app.gleam", "pub fn f() -> Int {\n  1\n}\n"),
      #("app.graded", spec),
      #("build/packages/real/src/real.gleam", "pub fn f() -> Int {\n  1\n}\n"),
    ]),
  )
}

// Run `assertions` while the `build/packages` of the `real_dependency_tree` at
// `root` can be searched and not listed (mode `0311`), then restore its mode.
// They run only where the mode is honoured, and after `packages.toml` and
// `real`'s sources are shown to still read.
pub fn with_search_only_packages(root: String, assertions: fn() -> Nil) -> Nil {
  let packages = root <> "/build/packages"
  use <- with_directory_mode(packages, 0o311, honoured: fn() {
    result.is_error(simplifile.read_directory(packages))
  })
  let assert Ok(_) = config.read_toml(packages <> "/packages.toml")
    as "packages.toml no longer reads"
  let assert Ok(_) = config.source_files(packages <> "/real/src")
    as "real's sources no longer walk"
  assertions()
}

// Run `assertions` with the directory at `path` set to `mode`, then restore
// mode `0755`. They run only where `honoured` says the mode holds: a process
// that reads past it, root most often, proves nothing.
pub fn with_directory_mode(
  path: String,
  mode: Int,
  honoured honoured: fn() -> Bool,
  run assertions: fn() -> Nil,
) -> Nil {
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, mode)
  case honoured() {
    True -> assertions()
    False -> Nil
  }
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o755)
  Nil
}

// Set mode `0755` on the directory at `path` if there is one, undoing a mode
// an earlier run left in place, so the fixture there can be deleted.
pub fn reset_directory_mode(path: String) -> Nil {
  let _ = simplifile.set_permissions_octal(path, 0o755)
  Nil
}

// Materialise the tree captured from a Gleam 1.19.0 build under
// `test/trees/<shape>` at `directory`: the root project at `app/` with its
// `gleam.toml` and manifest, each local package beside it, and each installed
// package under `app/build/packages` with the install record. Every package
// captured by its `gleam.toml` (`local-<name>.toml`, `installed-<name>.toml`)
// gets one module, `src/<name>.gleam`. A package Gleam builds with rebar3 or
// mix (`native-<name>.files`) gets each file its listing names, empty. The
// root gets a spec holding one `assume` line naming no module. Returns the
// root project's directory.
pub fn captured_tree(shape: String, directory: String) -> String {
  let captured = "test/trees/" <> shape
  let _ = simplifile.delete(directory)
  let root = directory <> "/app"
  let assert Ok(files) = simplifile.read_directory(captured)
  list.each(files, fn(file) {
    let assert Ok(contents) = simplifile.read(captured <> "/" <> file)
    case file {
      "gleam.toml" | "manifest.toml" ->
        write_file(root <> "/" <> file, contents)
      "packages.toml" ->
        write_file(root <> "/build/packages/packages.toml", contents)
      _ ->
        case string.split_once(file, "-") {
          Ok(#("installed", rest)) -> {
            let name = string.drop_end(rest, 5)
            write_package(root <> "/build/packages/" <> name, name, contents)
          }
          Ok(#("local", rest)) -> {
            let name = string.drop_end(rest, 5)
            write_package(directory <> "/" <> name, name, contents)
          }
          Ok(#("native", rest)) -> {
            let name = string.drop_end(rest, 6)
            write_listed_files(root <> "/build/packages/" <> name, contents)
          }
          _ -> panic as { "unexpected captured file " <> file }
        }
    }
  })
  write_file(root <> "/src/app.gleam", "pub fn f() -> Int {\n  1\n}\n")
  write_file(root <> "/app.graded", "assume nosuch_module : []\n")
  root
}

// A package at `directory` named `name`: its `gleam.toml` and one module,
// `src/<name>.gleam`.
pub fn write_package(directory: String, name: String, config: String) -> Nil {
  write_file(directory <> "/gleam.toml", config)
  write_file(
    directory <> "/src/" <> name <> ".gleam",
    "pub fn f() -> Int {\n  1\n}\n",
  )
}

// Create each file `listing` names under `directory`, empty. The listing holds
// one path per line, relative to `directory`, and blank lines are ignored.
// Panics on an absolute path, a `..` segment, or a listing naming no file.
fn write_listed_files(directory: String, listing: String) -> Nil {
  let files =
    string.split(listing, "\n")
    |> list.filter(fn(line) { string.trim(line) != "" })
  case files {
    [] -> panic as { "no file listed for " <> directory }
    [_, ..] ->
      list.each(files, fn(file) {
        case
          string.starts_with(file, "/")
          || list.contains(string.split(file, "/"), "..")
        {
          True -> panic as { "unsafe listed file " <> file }
          False -> write_file(directory <> "/" <> file, "")
        }
      })
  }
}

// Replace the one occurrence of `old` in the file at `path` with `new`.
pub fn edit_file(path: String, old: String, new: String) -> Nil {
  let assert Ok(contents) = simplifile.read(path)
  let assert [before, after] = string.split(contents, old)
    as { "expected one occurrence in " <> path <> " of " <> old }
  let assert Ok(Nil) = simplifile.write(path, before <> new <> after)
  Nil
}

// graded's own bundled catalog directory.
pub fn catalog_directory() -> String {
  let assert Ok(directory) = graded.locate_catalog(effects.catalog_candidates())
    as "graded's bundled catalog is not found"
  directory
}

// graded's own bundled catalog files.
pub fn bundled_catalog() -> List(effects.CatalogFile) {
  catalog_files(catalog_directory())
}

// The catalog files under `catalog_dir`.
pub fn catalog_files(catalog_dir: String) -> List(effects.CatalogFile) {
  let assert Ok(files) = effects.bundled_catalog_files(catalog_dir)
  files
}

// A knowledge base holding graded's bundled catalog alone, its versions
// selected against the working directory's manifest.
pub fn knowledge_base() -> effects.KnowledgeBase {
  effects.empty_knowledge_base(bundled_catalog(), ".")
}

// Write one file, creating its parent directories first.
pub fn write_file(path: String, contents: String) -> Nil {
  ensure_parent(path)
  let assert Ok(Nil) = simplifile.write(path, contents)
  Nil
}

// Create a path's parent directory, recursively.
pub fn ensure_parent(path: String) -> Nil {
  let assert Ok(Nil) =
    simplifile.create_directory_all(filepath.directory_name(path))
  Nil
}

// Materialise a tree of files at `directory`, replacing any prior contents.
pub fn write_fixture(
  directory: String,
  files: List(#(String, String)),
) -> String {
  let _ = simplifile.delete(directory)
  list.each(files, fn(entry) {
    let #(relative_path, contents) = entry
    write_file(directory <> "/" <> relative_path, contents)
  })
  directory
}

// Materialise `files` at `directory`, as `write_fixture` does, then create
// each `#(link, target)` symbolic link, both relative to `directory`. Returns
// `directory`.
pub fn write_linked_fixture(
  directory: String,
  files: List(#(String, String)),
  links: List(#(String, String)),
) -> String {
  write_fixture(directory, files)
  list.each(links, fn(link) {
    let #(at, target) = link
    let path = directory <> "/" <> at
    ensure_parent(path)
    let assert Ok(Nil) = simplifile.create_symlink(to: target, from: path)
  })
  directory
}

// Delete a fixture directory written by `write_fixture`/`write_file`.
pub fn cleanup(directory: String) -> Nil {
  let _ = simplifile.delete(directory)
  Nil
}

// One bodyless `@external` declared for both targets: foreign code on every
// build, so a declaration alone answers for it. `signature` is everything
// after the function name (`"(cb: fn() -> Nil) -> fn() -> Nil"`).
pub fn foreign_fn(name: String, signature: String) -> String {
  "@external(erlang, \"m\", \""
  <> name
  <> "\")\n@external(javascript, \"m\", \""
  <> name
  <> "\")\npub fn "
  <> name
  <> signature
  <> "\n"
}

// Write bytes that are not UTF-8 at `path`. One of the two shapes a spec file
// can take that is there and cannot be read, and the one a test can write
// portably beside a directory.
pub fn write_not_utf8(path: String) -> Nil {
  ensure_parent(path)
  let assert Ok(Nil) = simplifile.write_bits(path, <<255, 254, 255>>)
  Nil
}

// Create a directory at `path` — the other unreadable shape, for a test about
// a spec path that holds one.
pub fn write_directory_at(path: String) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(path)
  Nil
}

// Materialise a minimal package whose spec file's second line the parser
// rejects, for the commands that must refuse it. Returns the directory.
pub fn write_unparseable_spec_project(directory: String) -> String {
  write_fixture(directory, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("src/proj.gleam", "pub fn go() -> Nil {\n  Nil\n}\n"),
    #("proj.graded", "effects proj.go : []\nnot a graded line\n"),
  ])
}

// A project with one installed dependency, materialised at `directory`: the
// project's own `gleam.toml`, spec and sources, and the dependency's spec and
// sources under `build/packages/<dependency>/src/`. Source paths are relative
// to the package they belong to. Returns the project directory.
pub fn write_project_with_dependency(
  directory directory: String,
  package package: String,
  spec spec: String,
  sources sources: List(#(String, String)),
  dependency dependency: String,
  dependency_spec dependency_spec: String,
  dependency_sources dependency_sources: List(#(String, String)),
) -> String {
  let dep_root = "build/packages/" <> dependency
  let dep_files =
    list.map(dependency_sources, fn(entry) {
      let #(path, contents) = entry
      #(dep_root <> "/src/" <> path, contents)
    })
  write_fixture(
    directory,
    list.flatten([
      [
        #("gleam.toml", "name = \"" <> package <> "\"\n"),
        #(package <> ".graded", spec),
        #(dep_root <> "/" <> dependency <> ".graded", dependency_spec),
      ],
      sources,
      dep_files,
    ]),
  )
}
