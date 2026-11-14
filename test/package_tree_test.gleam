// Tests for `graded/internal/package_tree`: discovering local packages, the
// requirement graph over every package, and when the tree read is the whole
// tree Gleam resolved. Trees under `test/trees` were captured from real Gleam
// 1.19.0 builds; the rest are written by hand under `build/`.

import filepath
import gleam/dict
import gleam/list
import gleam/set
import gleam/string
import gleeunit/should
import graded/internal/package_tree.{
  DevOnly, Direct, LocatedTwice, NewlyLoaded, ProvidedTwoWays, UnreadableConfig,
}
import simplifile
import support

// Write each `#(directory, dependency tables)` package under `root`, with a
// `gleam.toml` naming it after its directory and one module.
fn write_packages(root: String, packages: List(#(String, String))) -> Nil {
  let _ = simplifile.delete(root)
  list.each(packages, fn(package) {
    let #(directory, tables) = package
    let name = filepath.base_name(directory)
    support.write_package(
      root <> "/" <> directory,
      name,
      "name = \"" <> name <> "\"\nversion = \"1.0.0\"\n" <> tables,
    )
  })
}

fn directory_of(local: package_tree.LocalPackages, name: String) -> String {
  let assert Ok(package) = dict.get(local.packages, name)
  package.directory
}

// The path dependencies the root declares
//
// `path_dependencies` reads the root's `[dependencies]` entries carrying a
// path, tolerating files with none and missing files.

pub fn path_dependencies_reads_the_root_path_entries_test() {
  let root =
    support.write_fixture("build/pt_path_deps", [
      #(
        "gleam.toml",
        "name = \"myapp\"\nversion = \"1.0.0\"\n\n[dependencies]\ngleam_stdlib = \">= 0.44.0\"\ndep_a = { path = \"../dep_a\" }\ndep_b = { path = \"../dep_b/gleam_lib\" }\n",
      ),
    ])
  package_tree.path_dependencies(root <> "/gleam.toml")
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> should.equal([#("dep_a", "../dep_a"), #("dep_b", "../dep_b/gleam_lib")])
  support.cleanup(root)
}

pub fn path_dependencies_without_path_entries_test() {
  let root =
    support.write_fixture("build/pt_no_path_deps", [
      #(
        "gleam.toml",
        "name = \"myapp\"\nversion = \"1.0.0\"\n\n[dependencies]\ngleam_stdlib = \">= 0.44.0\"\n",
      ),
    ])
  package_tree.path_dependencies(root <> "/gleam.toml") |> should.equal([])
  support.cleanup(root)
}

pub fn path_dependencies_of_a_missing_file_test() {
  package_tree.path_dependencies("nonexistent.toml") |> should.equal([])
}

// Discovery
//
// Local packages are located from the root's `[dependencies]` and
// `[dev-dependencies]`, then each local package's `[dependencies]`.

pub fn a_transitive_path_resolves_against_its_declaring_package_test() {
  write_packages("build/pt_nested", [
    #("app", "[dependencies]\na = { path = \"../libs/a\" }\n"),
    #("libs/a", "[dependencies]\nb = { path = \"../b\" }\n"),
    #("libs/b", ""),
  ])
  let local = package_tree.discover("build/pt_nested/app")
  directory_of(local, "a") |> should.equal("build/pt_nested/libs/a")
  directory_of(local, "b") |> should.equal("build/pt_nested/libs/b")
  local.flags |> should.equal([])
  support.cleanup("build/pt_nested")
}

pub fn a_diamond_is_entered_once_with_both_edges_test() {
  write_packages("build/pt_diamond", [
    #(
      "app",
      "[dependencies]\na = { path = \"../a\" }\nc = { path = \"../c\" }\n",
    ),
    #("a", "[dependencies]\nb = { path = \"../b\" }\n"),
    #("c", "[dependencies]\nb = { path = \"../b\" }\n"),
    #("b", ""),
  ])
  let local = package_tree.discover("build/pt_diamond/app")
  local.visited
  |> should.equal([
    "build/pt_diamond/app",
    "build/pt_diamond/a",
    "build/pt_diamond/c",
    "build/pt_diamond/b",
  ])
  dict.get(local.edges, "a") |> should.equal(Ok(set.from_list(["b"])))
  dict.get(local.edges, "c") |> should.equal(Ok(set.from_list(["b"])))
  support.cleanup("build/pt_diamond")
}

pub fn a_dependencys_dev_dependencies_are_not_walked_test() {
  write_packages("build/pt_dep_dev", [
    #("app", "[dependencies]\na = { path = \"../a\" }\n"),
    #("a", "[dev-dependencies]\nx = { path = \"../x\" }\n"),
    #("x", ""),
  ])
  let local = package_tree.discover("build/pt_dep_dev/app")
  dict.keys(local.packages) |> should.equal(["a"])
  support.cleanup("build/pt_dep_dev")
}

pub fn the_root_dev_dependencies_are_walked_test() {
  write_packages("build/pt_root_dev", [
    #("app", "[dev-dependencies]\nd = { path = \"../d\" }\n"),
    #("d", "[dependencies]\ne = { path = \"../e\" }\n"),
    #("e", ""),
  ])
  let local = package_tree.discover("build/pt_root_dev/app")
  dict.keys(local.packages)
  |> list.sort(string.compare)
  |> should.equal(["d", "e"])
  package_tree.class_of(local, "d") |> should.equal(DevOnly)
  package_tree.class_of(local, "e") |> should.equal(DevOnly)
  support.cleanup("build/pt_root_dev")
}

pub fn the_root_dev_dependencies_are_read_under_either_spelling_test() {
  write_packages("build/pt_root_dev_spelling", [
    #("app", "[dev_dependencies]\nd = { path = \"../d\" }\n"),
    #("d", ""),
  ])
  let local = package_tree.discover("build/pt_root_dev_spelling/app")
  dict.keys(local.packages) |> should.equal(["d"])
  let assert Ok(root) = local.root_declarations
  dict.keys(root.dev_dependencies) |> should.equal(["d"])
  support.cleanup("build/pt_root_dev_spelling")
}

pub fn a_name_located_at_two_directories_is_flagged_test() {
  write_packages("build/pt_located_twice", [
    #(
      "app",
      "[dependencies]\na = { path = \"../a\" }\nb = { path = \"../b\" }\n",
    ),
    #("a", "[dependencies]\nb = { path = \"../other/b\" }\n"),
    #("b", ""),
    #("other/b", ""),
  ])
  let local = package_tree.discover("build/pt_located_twice/app")
  local.flags |> should.equal([LocatedTwice(name: "b")])
  directory_of(local, "b") |> should.equal("build/pt_located_twice/b")
  support.cleanup("build/pt_located_twice")
}

pub fn two_git_refs_for_one_name_are_flagged_test() {
  write_packages("build/pt_two_refs", [
    #(
      "app",
      "[dependencies]\na = { path = \"../a\" }\nc = { path = \"../c\" }\n",
    ),
    #("a", "[dependencies]\ng = { git = \"https://x/g\", ref = \"v1\" }\n"),
    #("c", "[dependencies]\ng = { git = \"https://x/g\", ref = \"v2\" }\n"),
  ])
  package_tree.discover("build/pt_two_refs/app").flags
  |> should.equal([ProvidedTwoWays(name: "g")])
  support.cleanup("build/pt_two_refs")
}

pub fn a_git_and_a_path_for_one_name_are_flagged_test() {
  write_packages("build/pt_git_and_path", [
    #(
      "app",
      "[dependencies]\na = { path = \"../a\" }\nc = { path = \"../c\" }\n",
    ),
    #("a", "[dependencies]\ng = { git = \"https://x/g\", ref = \"v1\" }\n"),
    #("c", "[dependencies]\ng = { path = \"../g\" }\n"),
    #("g", ""),
  ])
  package_tree.discover("build/pt_git_and_path/app").flags
  |> should.equal([ProvidedTwoWays(name: "g")])
  support.cleanup("build/pt_git_and_path")
}

pub fn a_root_path_and_a_local_git_are_flagged_test() {
  write_packages("build/pt_root_path_local_git", [
    #(
      "app",
      "[dependencies]\na = { path = \"../a\" }\ng = { path = \"../g\" }\n",
    ),
    #("a", "[dependencies]\ng = { git = \"https://x/g\", ref = \"v1\" }\n"),
    #("g", ""),
  ])
  package_tree.discover("build/pt_root_path_local_git/app").flags
  |> should.equal([ProvidedTwoWays(name: "g")])
  support.cleanup("build/pt_root_path_local_git")
}

pub fn an_unreadable_local_config_is_flagged_and_kept_test() {
  write_packages("build/pt_unreadable_local", [
    #("app", "[dependencies]\na = { path = \"../a\" }\n"),
  ])
  support.write_file("build/pt_unreadable_local/a/gleam.toml", "[[[ not toml")
  let local = package_tree.discover("build/pt_unreadable_local/app")
  local.flags
  |> should.equal([UnreadableConfig(directory: "build/pt_unreadable_local/a")])
  let assert Ok(package) = dict.get(local.packages, "a")
  package.dependencies |> should.equal(Error(Nil))
  support.cleanup("build/pt_unreadable_local")
}

pub fn an_unreadable_root_config_is_flagged_test() {
  let _ = simplifile.delete("build/pt_unreadable_root")
  support.write_file("build/pt_unreadable_root/app/src/app.gleam", "")
  let local = package_tree.discover("build/pt_unreadable_root/app")
  local.flags
  |> should.equal([UnreadableConfig(directory: "build/pt_unreadable_root/app")])
  package_tree.is_complete(local) |> should.be_false
  support.cleanup("build/pt_unreadable_root")
}

// The graph and the classes, over captured trees
//
// Each tree is the one a real build resolved, so each is complete.

fn captured(shape: String) -> #(String, package_tree.LocalPackages) {
  let root = support.captured_tree(shape, "build/pt_" <> shape)
  #(root, package_tree.discover(root))
}

pub fn a_path_package_satisfies_a_version_requirement_test() {
  let #(root, local) = captured("root_path_local_version")
  dict.get(local.edges, "a") |> should.equal(Ok(set.from_list(["b"])))
  package_tree.class_of(local, "a") |> should.equal(Direct)
  package_tree.class_of(local, "b") |> should.equal(Direct)
  package_tree.is_complete(local) |> should.be_true
  support.cleanup(root <> "/..")
}

pub fn a_dev_path_package_an_installed_package_requires_is_runtime_test() {
  let #(root, local) = captured("git_version_root_dev_path")
  set.contains(local.runtime, "b") |> should.be_true
  package_tree.class_of(local, "b") |> should.equal(NewlyLoaded)
  package_tree.is_complete(local) |> should.be_true
  support.cleanup(root <> "/..")
}

pub fn a_nested_path_provides_a_root_version_requirement_test() {
  let #(root, local) = captured("root_version_local_path")
  package_tree.class_of(local, "a") |> should.equal(Direct)
  package_tree.class_of(local, "b") |> should.equal(NewlyLoaded)
  package_tree.is_complete(local) |> should.be_true
  support.cleanup(root <> "/..")
}

pub fn direct_transitive_and_dev_only_packages_are_told_apart_test() {
  let #(root, local) = captured("direct_transitive_dev")
  package_tree.class_of(local, "a") |> should.equal(Direct)
  package_tree.class_of(local, "b") |> should.equal(NewlyLoaded)
  package_tree.class_of(local, "d") |> should.equal(DevOnly)
  package_tree.is_complete(local) |> should.be_true
  support.cleanup(root <> "/..")
}

pub fn a_git_member_is_provided_by_its_parent_test() {
  let #(root, local) = captured("git_member")
  dict.get(local.edges, "gdep") |> should.equal(Ok(set.from_list(["gmember"])))
  package_tree.is_complete(local) |> should.be_true
  support.cleanup(root <> "/..")
}

pub fn a_nested_git_member_resolves_against_its_declarer_test() {
  let #(root, local) = captured("git_nested_member")
  package_tree.is_complete(local) |> should.be_true
  support.cleanup(root <> "/..")
}

pub fn a_version_requirement_beside_a_git_member_is_a_constraint_test() {
  let #(root, local) = captured("git_member_root_version")
  package_tree.is_complete(local) |> should.be_true
  support.cleanup(root <> "/..")
  let #(root, local) = captured("git_member_local_version")
  package_tree.is_complete(local) |> should.be_true
  support.cleanup(root <> "/..")
}

pub fn an_installed_git_provider_with_a_version_requirer_test() {
  let #(root, local) = captured("local_version_installed_git")
  package_tree.is_complete(local) |> should.be_true
  support.cleanup(root <> "/..")
}

// Completeness
//
// Each captured tree edited the way a stale or hand-made tree differs from the
// one Gleam resolved. Every edit leaves the tree incomplete.

fn incomplete_after(shape: String, edit: fn(String) -> Nil) -> Nil {
  let root = support.captured_tree(shape, "build/pt_edited_" <> shape)
  package_tree.discover(root) |> package_tree.is_complete |> should.be_true
  edit(root)
  package_tree.discover(root) |> package_tree.is_complete |> should.be_false
  support.cleanup(root <> "/..")
}

pub fn a_nested_member_at_another_recorded_path_is_incomplete_test() {
  use root <- incomplete_after("git_nested_member")
  support.edit_file(
    root <> "/manifest.toml",
    "path = \"packages/pkb\"",
    "path = \"packages/other\"",
  )
  support.edit_file(
    root <> "/build/packages/packages.toml",
    "path = \"packages/pkb\"",
    "path = \"packages/other\"",
  )
}

pub fn a_member_path_escaping_the_repository_is_incomplete_test() {
  use root <- incomplete_after("git_nested_member")
  support.edit_file(
    root <> "/build/packages/pka/gleam.toml",
    "\"../pkb\"",
    "\"../../../pkb\"",
  )
}

pub fn a_member_at_another_installed_commit_is_incomplete_test() {
  use root <- incomplete_after("git_member")
  support.edit_file(
    root <> "/build/packages/packages.toml",
    "[git.gmember]\ncommit = \"54d9f8667c1ea2d2422a0c7252f9c1cbd2a9ffeb\"",
    "[git.gmember]\ncommit = \"0000000000000000000000000000000000000000\"",
  )
}

pub fn a_member_at_another_installed_path_is_incomplete_test() {
  use root <- incomplete_after("git_member")
  support.edit_file(
    root <> "/build/packages/packages.toml",
    "path = \"sub/gmember\"",
    "path = \"sub/elsewhere\"",
  )
}

pub fn a_member_from_another_commit_than_its_parent_is_incomplete_test() {
  use root <- incomplete_after("git_member")
  support.edit_file(
    root <> "/manifest.toml",
    "commit = \"54d9f8667c1ea2d2422a0c7252f9c1cbd2a9ffeb\", path = \"sub/gmember\"",
    "commit = \"0000000000000000000000000000000000000000\", path = \"sub/gmember\"",
  )
  support.edit_file(
    root <> "/build/packages/packages.toml",
    "[git.gmember]\ncommit = \"54d9f8667c1ea2d2422a0c7252f9c1cbd2a9ffeb\"",
    "[git.gmember]\ncommit = \"0000000000000000000000000000000000000000\"",
  )
}

pub fn a_member_from_another_repository_than_its_parent_is_incomplete_test() {
  use root <- incomplete_after("git_member")
  support.edit_file(
    root <> "/manifest.toml",
    "repo = \"https://git.example.com/gdep\", commit = \"54d9f8667c1ea2d2422a0c7252f9c1cbd2a9ffeb\", path",
    "repo = \"https://git.example.com/other\", commit = \"54d9f8667c1ea2d2422a0c7252f9c1cbd2a9ffeb\", path",
  )
}

pub fn a_member_its_parent_does_not_declare_is_incomplete_test() {
  use root <- incomplete_after("git_member")
  support.edit_file(
    root <> "/build/packages/gdep/gleam.toml",
    "gmember = { path = \"sub/gmember\" }",
    "",
  )
}

pub fn a_local_git_declaration_edited_to_a_version_is_incomplete_test() {
  // The installed `h` still requires `b`, by version: its name in the
  // manifest's requirements is no evidence that `h` provides `b` by `git`.
  use root <- incomplete_after("local_git_installed_version")
  support.edit_file(
    root <> "/../a/gleam.toml",
    "b = { git = \"https://git.example.com/b\", ref = \"main\" }",
    "b = \">= 1.0.0 and < 2.0.0\"",
  )
}

pub fn a_git_entry_no_installed_package_requires_is_incomplete_test() {
  use root <- incomplete_after("local_version_installed_git")
  support.edit_file(
    root <> "/manifest.toml",
    "{ name = \"h\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [\"b\"]",
    "{ name = \"h\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = []",
  )
}

pub fn a_git_requirer_without_a_gleam_toml_is_incomplete_test() {
  use root <- incomplete_after("local_version_installed_git")
  let assert Ok(Nil) = simplifile.delete(root <> "/build/packages/h/gleam.toml")
  Nil
}

pub fn no_manifest_beside_a_declaration_is_incomplete_test() {
  use root <- incomplete_after("root_path_local_version")
  let assert Ok(Nil) = simplifile.delete(root <> "/manifest.toml")
  Nil
}

pub fn no_manifest_and_nothing_declared_is_complete_test() {
  write_packages("build/pt_nothing_declared", [#("app", "")])
  package_tree.discover("build/pt_nothing_declared/app")
  |> package_tree.is_complete
  |> should.be_true
  support.cleanup("build/pt_nothing_declared")
}

pub fn an_unparseable_manifest_is_incomplete_test() {
  use root <- incomplete_after("root_path_local_version")
  support.write_file(root <> "/manifest.toml", "packages = [[[")
}

pub fn a_manifest_without_packages_is_incomplete_test() {
  use root <- incomplete_after("root_path_local_version")
  support.edit_file(root <> "/manifest.toml", "packages = [", "pkgs = [")
}

pub fn a_malformed_manifest_entry_is_incomplete_test() {
  use root <- incomplete_after("root_path_local_version")
  support.edit_file(
    root <> "/manifest.toml",
    "requirements = [], source = \"local\"",
    "source = \"local\"",
  )
}

pub fn a_duplicate_manifest_entry_is_incomplete_test() {
  use root <- incomplete_after("root_path_local_version")
  support.edit_file(
    root <> "/manifest.toml",
    "{ name = \"b\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"../b\" },",
    "{ name = \"b\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"../b\" },\n  { name = \"b\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"../b\" },",
  )
}

pub fn a_requirement_naming_an_unlisted_package_is_incomplete_test() {
  use root <- incomplete_after("root_path_local_version")
  support.edit_file(
    root <> "/manifest.toml",
    "requirements = [\"b\"]",
    "requirements = [\"b\", \"nowhere\"]",
  )
}

pub fn a_root_requirement_naming_an_unlisted_package_is_incomplete_test() {
  write_packages("build/pt_unlisted_root_requirement", [
    #("app", "[dependencies]\nfoo = \">= 1.0.0\"\n"),
  ])
  support.write_file(
    "build/pt_unlisted_root_requirement/app/manifest.toml",
    "packages = []\n\n[requirements]\nfoo = { version = \">= 1.0.0\" }\n",
  )
  package_tree.discover("build/pt_unlisted_root_requirement/app")
  |> package_tree.is_complete
  |> should.be_false
  support.cleanup("build/pt_unlisted_root_requirement")
}

pub fn a_git_entry_without_a_commit_is_incomplete_test() {
  use root <- incomplete_after("local_version_installed_git")
  support.edit_file(
    root <> "/manifest.toml",
    ", commit = \"148fa4d6737e27c7e1e57f9f190b0a04acf6101e\"",
    "",
  )
  support.edit_file(
    root <> "/build/packages/packages.toml",
    "[git.h]\ncommit = \"148fa4d6737e27c7e1e57f9f190b0a04acf6101e\"",
    "[git.h]",
  )
}

pub fn a_root_dependency_added_is_incomplete_test() {
  use root <- incomplete_after("root_path_local_version")
  support.edit_file(
    root <> "/gleam.toml",
    "b = { path = \"../b\" }",
    "b = { path = \"../b\" }\nc = \">= 1.0.0 and < 2.0.0\"",
  )
}

pub fn a_root_dependency_removed_is_incomplete_test() {
  use root <- incomplete_after("root_path_local_version")
  support.edit_file(root <> "/gleam.toml", "b = { path = \"../b\" }", "")
}

pub fn a_root_dependency_reconstrained_is_incomplete_test() {
  use root <- incomplete_after("root_version_local_path")
  support.edit_file(
    root <> "/gleam.toml",
    "b = \">= 1.0.0 and < 2.0.0\"",
    "b = \">= 1.1.0 and < 2.0.0\"",
  )
}

pub fn a_local_requirement_renamed_is_incomplete_test() {
  use root <- incomplete_after("root_path_local_version")
  support.edit_file(
    root <> "/../a/gleam.toml",
    "b = \">= 1.0.0 and < 2.0.0\"",
    "c = \">= 1.0.0 and < 2.0.0\"",
  )
}

pub fn a_provider_kind_changed_is_incomplete_test() {
  use root <- incomplete_after("root_version_local_path")
  support.edit_file(
    root <> "/manifest.toml",
    "requirements = [], source = \"local\", path = \"../b\"",
    "requirements = [], source = \"hex\", outer_checksum = \"0\"",
  )
}

pub fn a_local_entry_at_another_path_is_incomplete_test() {
  use root <- incomplete_after("root_path_local_version")
  support.edit_file(
    root <> "/manifest.toml",
    "source = \"local\", path = \"../b\" }",
    "source = \"local\", path = \"../elsewhere/b\" }",
  )
}

pub fn a_local_entry_the_walk_does_not_reach_is_incomplete_test() {
  use root <- incomplete_after("root_path_local_version")
  support.edit_file(
    root <> "/manifest.toml",
    "]\n\n[requirements]",
    "  { name = \"stray\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"../stray\" },\n]\n\n[requirements]",
  )
}

pub fn an_installed_version_differing_is_incomplete_test() {
  use root <- incomplete_after("git_member")
  support.edit_file(
    root <> "/build/packages/packages.toml",
    "gdep = \"1.0.0\"",
    "gdep = \"1.0.1\"",
  )
}

pub fn an_installed_commit_differing_is_incomplete_test() {
  use root <- incomplete_after("git_member")
  support.edit_file(
    root <> "/build/packages/packages.toml",
    "[git.gdep]\ncommit = \"54d9f8667c1ea2d2422a0c7252f9c1cbd2a9ffeb\"",
    "[git.gdep]\ncommit = \"0000000000000000000000000000000000000000\"",
  )
}

pub fn an_installed_only_self_cycle_is_incomplete_test() {
  use root <- incomplete_after("git_member")
  support.edit_file(
    root <> "/manifest.toml",
    "requirements = [], source = \"git\"",
    "requirements = [\"gmember\"], source = \"git\"",
  )
}

pub fn an_installed_only_two_node_cycle_is_incomplete_test() {
  use root <- incomplete_after("git_member")
  support.edit_file(
    root <> "/manifest.toml",
    "requirements = [], source = \"git\"",
    "requirements = [\"gdep\"], source = \"git\"",
  )
}

pub fn a_local_cycle_is_incomplete_test() {
  use root <- incomplete_after("transitive_path")
  support.edit_file(
    root <> "/../b/gleam.toml",
    "version = \"1.0.0\"\n",
    "version = \"1.0.0\"\n[dependencies]\na = { path = \"../a\" }\n",
  )
  support.edit_file(
    root <> "/manifest.toml",
    "requirements = [], source = \"local\", path = \"../b\"",
    "requirements = [\"a\"], source = \"local\", path = \"../b\"",
  )
}

pub fn a_search_only_packages_directory_is_incomplete_test() {
  let root = support.real_dependency_tree("build/pt_search_only", "")
  package_tree.discover(root) |> package_tree.is_complete |> should.be_true
  {
    use <- support.with_search_only_packages(root)
    package_tree.discover(root) |> package_tree.is_complete |> should.be_false
  }
  support.cleanup(root)
}

// Edges from installed packages' own `gleam.toml`
//
// Read only where the manifest cannot be read whole.

pub fn installed_requirements_are_ignored_beside_a_parsing_manifest_test() {
  let root = support.captured_tree("git_member", "build/pt_installed_edges")
  support.edit_file(
    root <> "/build/packages/gmember/gleam.toml",
    "version = \"1.0.0\"\n",
    "version = \"1.0.0\"\n[dependencies]\ngdep = \">= 1.0.0\"\n",
  )
  let local = package_tree.discover(root)
  dict.get(local.edges, "gmember") |> should.equal(Ok(set.new()))
  package_tree.is_complete(local) |> should.be_true
  support.cleanup(root <> "/..")
}

pub fn installed_requirements_supply_edges_without_a_manifest_test() {
  let root =
    support.captured_tree("git_member", "build/pt_installed_edges_only")
  support.write_file(root <> "/manifest.toml", "not a manifest")
  let local = package_tree.discover(root)
  dict.get(local.edges, "gdep") |> should.equal(Ok(set.from_list(["gmember"])))
  package_tree.is_complete(local) |> should.be_false
  support.cleanup(root <> "/..")
}

// Packages built without Gleam
//
// A rebar3 or mix package may hold no Gleam module and still be the package
// the manifest lists.

// A project depending on one hex package, `native`, installed with `files` in
// its `src/` and the manifest's `build_tools` replaced by `tools` — `""` drops
// the key.
fn native_package_tree(
  name: String,
  tools: String,
  files: List(String),
) -> String {
  let root = "build/pt_native_" <> name
  support.write_fixture(
    root,
    list.append(support.hex_tree("app", [#("native", "1.0.0")]), [
      #("src/app.gleam", "pub fn f() -> Int {\n  1\n}\n"),
      ..list.map(files, fn(file) { #("build/packages/native/src/" <> file, "") })
    ]),
  )
  support.edit_file(
    root <> "/manifest.toml",
    "build_tools = [\"gleam\"], ",
    tools,
  )
  root
}

fn native_tree_is_complete(
  name: String,
  tools: String,
  files: List(String),
) -> Bool {
  let root = native_package_tree(name, tools, files)
  let complete = package_tree.discover(root) |> package_tree.is_complete
  support.cleanup(root)
  complete
}

pub fn a_rebar3_package_without_gleam_modules_is_located_test() {
  native_tree_is_complete("rebar3", "build_tools = [\"rebar3\"], ", [
    "native.erl",
  ])
  |> should.be_true
}

pub fn a_mix_package_with_mixed_files_is_located_test() {
  native_tree_is_complete("mix", "build_tools = [\"mix\"], ", [
    "native.ex",
    "native/helper.gleam",
  ])
  |> should.be_true
}

pub fn a_package_with_no_directory_is_not_located_test() {
  let root =
    native_package_tree("missing", "build_tools = [\"rebar3\"], ", [
      "native.erl",
    ])
  let assert Ok(Nil) = simplifile.delete(root <> "/build/packages/native")
  package_tree.discover(root) |> package_tree.is_complete |> should.be_false
  support.cleanup(root)
}

pub fn a_package_whose_sources_cannot_be_walked_is_not_located_test() {
  let root =
    native_package_tree("unwalkable", "build_tools = [\"rebar3\"], ", [
      "native.erl",
    ])
  let assert Ok(Nil) =
    simplifile.create_symlink(
      to: "../nowhere",
      from: root <> "/build/packages/native/src/gone",
    )
  package_tree.discover(root) |> package_tree.is_complete |> should.be_false
  support.cleanup(root)
}

pub fn other_build_tools_still_need_a_gleam_module_test() {
  native_tree_is_complete("no_key", "", ["native.erl"]) |> should.be_false
  native_tree_is_complete("empty", "build_tools = [], ", ["native.erl"])
  |> should.be_false
  native_tree_is_complete("make", "build_tools = [\"make\"], ", ["native.erl"])
  |> should.be_false
  native_tree_is_complete(
    "rebar3_gleam",
    "build_tools = [\"rebar3\", \"gleam\"], ",
    ["native.erl"],
  )
  |> should.be_false
}
