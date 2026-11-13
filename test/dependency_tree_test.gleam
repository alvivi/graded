// End-to-end runs over the dependency tree graded reads: source trees holding
// symbolic links. Every project is materialised under `build/`, which the
// compiler does not read, and deleted afterwards.

import gleam/dict
import gleam/list
import gleeunit/should
import graded
import graded/internal/types
import support

// Source trees with symbolic links
//
// A link leading back to one of its own parent directories is skipped, and
// every other link is followed: the project's own tree and an installed
// package's alike.

pub fn a_link_to_a_parent_directory_leaves_the_project_checkable_test() {
  let root =
    support.write_linked_fixture(
      "build/dt_one_link_loop",
      [
        #("gleam.toml", "name = \"proj\"\n"),
        #("src/app.gleam", "pub fn go() -> Int {\n  1\n}\n"),
        #("lib/linked.gleam", "pub fn f() -> Int {\n  1\n}\n"),
      ],
      [#("src/loop", ".."), #("src/viasym", "../lib")],
    )
  graded.run(root) |> should.be_ok
  graded.run_effect(root, "viasym/linked.f")
  |> should.equal(Ok(
    "// resolved from in-memory inference\neffects viasym/linked.f : []",
  ))
  support.cleanup(root)
}

pub fn a_two_link_cycle_infers_every_module_it_reaches_test() {
  let root =
    support.write_linked_fixture(
      "build/dt_two_link_cycle",
      [
        #("gleam.toml", "name = \"proj\"\n"),
        #("src/x/mx.gleam", "pub fn fx() -> Int {\n  1\n}\n"),
        #("src/w/mw.gleam", "pub fn fw() -> Int {\n  1\n}\n"),
      ],
      [#("src/x/to_w", "../w"), #("src/w/to_x", "../x")],
    )
  graded.run_infer_dry_run(root)
  |> should.equal(Ok(
    "+ effects x/to_w/mw.fw : []
+ effects x/mx.fx : []
+ effects w/to_x/mx.fx : []
+ effects w/mw.fw : []
\\ No newline at end of file",
  ))
  support.cleanup(root)
}

pub fn two_branching_loops_infer_every_module_they_reach_test() {
  let root =
    support.write_linked_fixture(
      "build/dt_branching_loops",
      [
        #("gleam.toml", "name = \"proj\"\n"),
        #("src/p/mp.gleam", "pub fn fp() -> Int {\n  1\n}\n"),
        #("src/q/mq.gleam", "pub fn fq() -> Int {\n  1\n}\n"),
      ],
      [#("src/p/l1", "../q"), #("src/p/l2", "../q"), #("src/q/back", "../p")],
    )
  graded.run_infer_dry_run(root)
  |> should.equal(Ok(
    "+ effects q/mq.fq : []
+ effects q/back/mp.fp : []
+ effects p/mp.fp : []
+ effects p/l2/mq.fq : []
+ effects p/l1/mq.fq : []
\\ No newline at end of file",
  ))
  support.cleanup(root)
}

pub fn a_consumer_resolves_each_of_two_links_to_one_directory_test() {
  let root =
    support.write_linked_fixture(
      "build/dt_two_links",
      [
        #("gleam.toml", "name = \"proj\"\n"),
        #(
          "src/app.gleam",
          "import one/m as first
import two/m as second

pub fn go() -> Int {
  first.f() + second.f()
}
",
        ),
        #("lib/m.gleam", "pub fn f() -> Int {\n  1\n}\n"),
      ],
      [#("src/one", "../lib"), #("src/two", "../lib")],
    )
  graded.run_effect(root, "app.go")
  |> should.equal(Ok(
    "// resolved from in-memory inference\neffects app.go : []",
  ))
  support.cleanup(root)
}

pub fn a_linked_directory_and_a_linked_file_are_read_test() {
  let root =
    support.write_linked_fixture(
      "build/dt_linked_dir_and_file",
      [
        #("gleam.toml", "name = \"proj\"\n"),
        #(
          "src/app.gleam",
          "import dir/inner
import file

pub fn go() -> Int {
  inner.f() + file.f()
}
",
        ),
        #("lib/inner.gleam", "pub fn f() -> Int {\n  1\n}\n"),
        #("other/real.gleam", "pub fn f() -> Int {\n  1\n}\n"),
      ],
      [#("src/dir", "../lib"), #("src/file.gleam", "../other/real.gleam")],
    )
  graded.run_effect(root, "app.go")
  |> should.equal(Ok(
    "// resolved from in-memory inference\neffects app.go : []",
  ))
  support.cleanup(root)
}

// An installed package whose `src/` holds a link back to its own root, and a
// higher-order function the consumer calls positionally: the callback binds
// only through the signature parsed from that package's source.
pub fn a_loop_in_an_installed_package_leaves_its_modules_readable_test() {
  let root =
    support.write_linked_fixture(
      "build/dt_installed_loop",
      [
        #("gleam.toml", "name = \"proj\"\n"),
        #("src/app.gleam", support.foreign_fn("say", "() -> Nil") <> "
import dep

pub fn go() -> Nil {
  dep.apply(fn() { say() })
}
"),
        #("proj.graded", "assume app.say : [Stdout]\n"),
        #(
          "build/packages/dep/src/dep.gleam",
          "pub fn apply(f: fn() -> Nil) -> Nil {\n  f()\n}\n",
        ),
        #("build/packages/dep/dep.graded", "effects dep.apply(f: [f]) : [f]\n"),
      ],
      [#("build/packages/dep/src/loop", "..")],
    )
  graded.dependency_module_files(root)
  |> dict.has_key("dep")
  |> should.be_true
  graded.run_effect(root, "app.go")
  |> should.equal(Ok(
    "// resolved from in-memory inference\neffects app.go : [Stdout]",
  ))
  support.cleanup(root)
}

pub fn a_dangling_link_fails_the_project_and_empties_a_dependency_test() {
  let project =
    support.write_linked_fixture(
      "build/dt_dangling_project",
      [
        #("gleam.toml", "name = \"proj\"\n"),
        #("src/app.gleam", "pub fn go() -> Int {\n  1\n}\n"),
      ],
      [#("src/gone", "../nowhere")],
    )
  let assert Error(graded.DirectoryReadError(..)) = graded.run(project)
  support.cleanup(project)

  let installed =
    support.write_linked_fixture(
      "build/dt_dangling_dependency",
      [
        #("gleam.toml", "name = \"proj\"\n"),
        #("src/app.gleam", "pub fn go() -> Int {\n  1\n}\n"),
        #("build/packages/dep/src/dep.gleam", "pub fn f() -> Int {\n  1\n}\n"),
      ],
      [#("build/packages/dep/src/gone", "../nowhere")],
    )
  graded.dependency_module_files(installed) |> should.equal(dict.new())
  support.cleanup(installed)
}

// The spec lint over a whole tree
//
// Every tree below was captured from a real Gleam build, so each is the whole
// tree Gleam resolved, and the root's spec line naming no module is reported.

fn typo_reported(root: String) -> Bool {
  let assert Ok(results) = graded.check_project(root)
  results
  |> list.flat_map(fn(result) { result.warnings })
  |> list.contains(types.UnmatchedModuleAssumeWarning(module: "nosuch_module"))
}

fn assert_typo_reported(shape: String) -> Nil {
  let root = support.captured_tree(shape, "build/dt_lint_" <> shape)
  typo_reported(root) |> should.be_true
  support.cleanup(root <> "/..")
}

pub fn a_tree_with_a_dev_only_path_dependency_is_linted_test() {
  assert_typo_reported("direct_dev_only")
}

pub fn a_tree_with_a_transitive_path_dependency_is_linted_test() {
  assert_typo_reported("transitive_path")
  assert_typo_reported("direct_transitive_dev")
}

pub fn a_path_package_satisfying_a_version_requirement_is_linted_test() {
  assert_typo_reported("root_path_local_version")
}

pub fn a_dev_path_package_an_installed_package_requires_is_linted_test() {
  assert_typo_reported("git_version_root_dev_path")
}

pub fn a_nested_path_providing_a_root_version_is_linted_test() {
  assert_typo_reported("root_version_local_path")
}

pub fn a_tree_with_git_members_is_linted_test() {
  assert_typo_reported("git_member")
  assert_typo_reported("git_nested_member")
  assert_typo_reported("git_member_root_version")
  assert_typo_reported("git_member_local_version")
}

pub fn an_installed_git_provider_is_linted_test() {
  assert_typo_reported("local_version_installed_git")
}

pub fn a_stale_git_provider_leaves_the_lint_silent_test() {
  let root =
    support.captured_tree(
      "local_git_installed_version",
      "build/dt_lint_stale_git_provider",
    )
  support.edit_file(
    root <> "/../a/gleam.toml",
    "b = { git = \"https://git.example.com/b\", ref = \"main\" }",
    "b = \">= 1.0.0 and < 2.0.0\"",
  )
  typo_reported(root) |> should.be_false
  support.cleanup(root <> "/..")
}

pub fn the_lint_places_dev_only_and_transitive_modules_test() {
  let root =
    support.captured_tree("direct_transitive_dev", "build/dt_lint_placement")
  let placement = graded.placement_module_files(root)
  ["a", "b", "d"]
  |> list.all(dict.has_key(placement, _))
  |> should.be_true
  graded.context_placement_files(root) |> should.equal(Ok(placement))
  // A module-level line over each is placed, and only the typo is reported.
  support.write_file(
    root <> "/app.graded",
    "assume b : []\nassume d : []\nassume nosuch_module : []\n",
  )
  let assert Ok(results) = graded.check_project(root)
  results
  |> list.flat_map(fn(result) { result.warnings })
  |> should.equal([types.UnmatchedModuleAssumeWarning(module: "nosuch_module")])
  support.cleanup(root <> "/..")
}
