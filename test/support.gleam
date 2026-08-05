// Fixture-tree scaffolding shared by the integration tests: materialise file
// trees (creating parent directories as needed) and delete them on cleanup.

import filepath
import gleam/list
import simplifile

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
