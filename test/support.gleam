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

// Materialise a minimal package whose spec file's second line the parser
// rejects, for the commands that must refuse it. Returns the directory.
pub fn write_unparseable_spec_project(directory: String) -> String {
  write_fixture(directory, [
    #("gleam.toml", "name = \"proj\"\n"),
    #("src/proj.gleam", "pub fn go() -> Nil {\n  Nil\n}\n"),
    #("proj.graded", "effects proj.go : []\nnot a graded line\n"),
  ])
}
