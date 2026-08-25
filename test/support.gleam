// Fixture-tree scaffolding shared by the integration tests: materialise file
// trees (creating parent directories as needed) and delete them on cleanup.

import filepath
import gleam/list
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
