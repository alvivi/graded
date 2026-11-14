// End-to-end runs over the dependency tree graded reads: source trees holding
// symbolic links, the spec lint over a whole tree, and the local packages
// loaded in dependency order. Every project is materialised under `build/`,
// which the compiler does not read, and deleted afterwards.

import gleam/dict
import gleam/list
import gleam/string
import gleeunit/should
import graded
import graded/internal/types
import simplifile
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

// Every warning `graded check` reports for the project at `root`.
fn lint_warnings(root: String) -> List(types.Warning) {
  let assert Ok(results) = graded.check_project(root)
  list.flat_map(results, fn(result) { result.warnings })
}

fn typo_reported(root: String) -> Bool {
  lint_warnings(root)
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
  lint_warnings(root)
  |> should.equal([types.UnmatchedModuleAssumeWarning(module: "nosuch_module")])
  support.cleanup(root <> "/..")
}

// A dependency built by rebar3, with no Gleam module of its own, and one built
// by mix holding Gleam modules beside its Elixir ones.
pub fn a_tree_with_rebar3_and_mix_packages_is_linted_test() {
  let root = "build/dt_lint_native"
  support.write_fixture(
    root,
    list.append(
      support.hex_tree("app", [#("erlpkg", "1.0.0"), #("expkg", "1.0.0")]),
      [
        #("src/app.gleam", "pub fn f() -> Int {\n  1\n}\n"),
        #("app.graded", "assume nosuch_module : []\n"),
        #("build/packages/erlpkg/src/erlpkg.erl", ""),
        #("build/packages/expkg/lib/expkg.ex", ""),
        #(
          "build/packages/expkg/src/expkg/bridge.gleam",
          "pub fn f() -> Int {\n  1\n}\n",
        ),
      ],
    ),
  )
  support.edit_file(
    root <> "/manifest.toml",
    "{ name = \"erlpkg\", version = \"1.0.0\", build_tools = [\"gleam\"]",
    "{ name = \"erlpkg\", version = \"1.0.0\", build_tools = [\"rebar3\"]",
  )
  support.edit_file(
    root <> "/manifest.toml",
    "{ name = \"expkg\", version = \"1.0.0\", build_tools = [\"gleam\"]",
    "{ name = \"expkg\", version = \"1.0.0\", build_tools = [\"mix\"]",
  )
  typo_reported(root) |> should.be_true
  graded.placement_module_files(root)
  |> dict.has_key("expkg/bridge")
  |> should.be_true
  support.cleanup(root)
}

// An installed module only placement can place
//
// `real` is installed and in no catalog, beside a module no package holds,
// each named at module level and per function.

const placement_spec =
  "assume real : []
assume real.f : []
assume nosuch_module : []
assume nosuch_module.f : []
"

pub fn an_installed_module_is_placed_beside_a_reported_typo_test() {
  let root =
    support.real_dependency_tree("build/dt_lint_installed", placement_spec)
  lint_warnings(root)
  |> should.equal([
    types.UnmatchedModuleAssumeWarning(module: "nosuch_module"),
    types.UnmatchedFunctionAssumeWarning(function: "nosuch_module.f"),
  ])
  support.cleanup(root)
}

pub fn a_search_only_packages_directory_leaves_the_lint_silent_test() {
  let root =
    support.real_dependency_tree("build/dt_lint_search_only", placement_spec)
  {
    use <- support.with_search_only_packages(root)
    lint_warnings(root) |> should.equal([])
  }
  support.cleanup(root)
}

// Local packages loaded in dependency order
//
// Every local package the root's runtime dependencies reach is loaded, after
// every package it reaches. Each tree is a captured one with sources written
// over it: `#(package, files)` writes each file under that package's
// directory, the root's being `app`.

fn tree_with_sources(
  shape: String,
  sources: List(#(String, List(#(String, String)))),
) -> String {
  let directory = "build/dt_" <> shape
  let root = support.captured_tree(shape, directory)
  list.each(sources, fn(package) {
    let #(name, files) = package
    let package_root = case name {
      "app" -> root
      _ -> directory <> "/" <> name
    }
    list.each(files, fn(file) {
      support.write_file(package_root <> "/" <> file.0, file.1)
    })
  })
  root
}

// The `effects` line `graded effect` answers for `name`, without its
// provenance comments.
fn effect_line(root: String, name: String) -> String {
  let assert Ok(rendered) = graded.run_effect(root, name)
  rendered
  |> string.split("\n")
  |> list.filter(fn(line) { !string.starts_with(line, "//") })
  |> string.join("\n")
}

// The same answer, from the full project context and from the fast path,
// which must agree.
fn agreed_effect_line(root: String, name: String) -> String {
  let assert Ok(full) = graded.run_effect_from_project(root, name)
  let assert Ok(fast) = graded.run_effect(root, name)
  fast |> should.equal(full)
  effect_line(root, name)
}

const pure_fb = "pub fn fb() -> Int {\n  1\n}\n"

const fa_calls_fb = "import b\n\npub fn fa() -> Int {\n  b.fb()\n}\n"

pub fn a_transitive_path_dependency_is_loaded_test() {
  let root =
    tree_with_sources("transitive_path", [
      #("a", [#("src/a.gleam", fa_calls_fb)]),
      #("b", [#("src/b.gleam", pure_fb)]),
    ])
  agreed_effect_line(root, "a.fa") |> should.equal("effects a.fa : []")
  support.cleanup(root <> "/..")
}

pub fn a_transitive_path_dependencys_spec_is_read_test() {
  let root =
    tree_with_sources("transitive_path", [
      #("a", [#("src/a.gleam", fa_calls_fb)]),
      #("b", [#("src/b.gleam", pure_fb), #("b.graded", "effects b.fb : []\n")]),
    ])
  agreed_effect_line(root, "a.fa") |> should.equal("effects a.fa : []")
  let assert Ok(answer) = graded.run_effect(root, "b.fb")
  answer |> string.contains("resolved from path dependency b") |> should.be_true
  support.cleanup(root <> "/..")
}

pub fn the_project_resolves_its_own_import_of_a_transitive_package_test() {
  let root =
    tree_with_sources("transitive_path", [
      #("app", [
        #("src/app.gleam", "import b\n\npub fn go() -> Int {\n  b.fb()\n}\n"),
      ]),
      #("b", [#("src/b.gleam", pure_fb)]),
    ])
  agreed_effect_line(root, "app.go") |> should.equal("effects app.go : []")
  support.cleanup(root <> "/..")
}

// `z` sorts after `b`, so a pass in name order reached `z` first.
pub fn path_dependencies_resolve_whatever_their_names_test() {
  let fz = "import b\n\npub fn fz() -> Int {\n  b.fb()\n}\n"
  let root =
    tree_with_sources("direct_z_b", [
      #("z", [#("src/z.gleam", fz)]),
      #("b", [#("src/b.gleam", pure_fb)]),
    ])
  agreed_effect_line(root, "z.fz") |> should.equal("effects z.fz : []")
  support.cleanup(root <> "/..")
  let root =
    tree_with_sources("root_path_z_version", [
      #("z", [#("src/z.gleam", fz)]),
      #("b", [#("src/b.gleam", pure_fb)]),
    ])
  agreed_effect_line(root, "z.fz") |> should.equal("effects z.fz : []")
  support.cleanup(root <> "/..")
}

// `b` is a dev path dependency of the root, and a runtime one through the
// installed `gdep`.
pub fn a_path_package_an_installed_package_requires_is_loaded_test() {
  let root =
    tree_with_sources("git_version_root_dev_path", [
      #("app", [
        #(
          "src/app.gleam",
          "import b\n\npub fn go() -> Int {\n  b.fb()\n}\n\npub fn ext() -> Nil {\n  b.ext()\n}\n",
        ),
      ]),
      #("b", [
        #(
          "src/b.gleam",
          pure_fb
            <> "\n@external(erlang, \"b_ffi\", \"ext\")\n@external(javascript, \"./b_ffi.mjs\", \"ext\")\npub fn ext() -> Nil\n",
        ),
      ]),
    ])
  agreed_effect_line(root, "app.go") |> should.equal("effects app.go : []")
  let assert Ok(coverage) = graded.run_coverage(root)
  coverage |> string.contains("\n  b (typed on") |> should.be_true
  // Its external was scanned: what an `effects` line inferred over its body
  // does not answer for it.
  support.write_file(root <> "/app.graded", "effects b.ext : []\n")
  effect_line(root, "app.ext") |> should.equal("effects app.ext : [Unknown]")
  support.cleanup(root <> "/..")
}

// A cycle the manifest could never record, beside an unrelated chain.
pub fn a_cycle_beside_a_chain_leaves_the_chain_loaded_test() {
  let root = "build/dt_local_cycle"
  let package = fn(name, dependencies, source) {
    [
      #(
        name <> "/gleam.toml",
        "name = \"" <> name <> "\"\nversion = \"1.0.0\"\n" <> dependencies,
      ),
      #(name <> "/src/" <> name <> ".gleam", source),
    ]
  }
  support.write_fixture(
    root,
    list.flatten([
      package(
        "app",
        "[dependencies]\na = { path = \"../a\" }\ncc = { path = \"../cc\" }\n",
        "pub fn f() -> Int {\n  1\n}\n",
      ),
      package("a", "[dependencies]\nb = { path = \"../b\" }\n", fa_calls_fb),
      package("b", "", pure_fb),
      package("cc", "[dependencies]\ndd = { path = \"../dd\" }\n", pure_fb),
      package("dd", "[dependencies]\ncc = { path = \"../cc\" }\n", pure_fb),
    ]),
  )
  agreed_effect_line(root <> "/app", "a.fa")
  |> should.equal("effects a.fa : []")
  support.cleanup(root)
}

pub fn a_dev_only_path_dependency_is_not_loaded_test() {
  let root =
    tree_with_sources("direct_transitive_dev", [
      #("d", [#("src/d.gleam", pure_fb)]),
    ])
  graded.dependency_module_files(root) |> dict.has_key("d") |> should.be_false
  let assert Ok(coverage) = graded.run_coverage(root)
  coverage |> string.contains("\n  d (typed on") |> should.be_false
  coverage |> string.contains("\n  b (typed on") |> should.be_true
  support.cleanup(root <> "/..")
}

// A newly loaded package weighed against what the run answered before
//
// `justin` is catalogued `assume justin : []`, and loaded here through the
// root's path dependency `a` while the root asks for it by version. `b` is
// reached the same way, `app → a → b`, and is catalogued nowhere.

const justin_tree = "root_version_local_path_catalogued"

fn justin_answer(
  justin_files: List(#(String, String)),
  app_spec: String,
  name: String,
) -> String {
  let root =
    tree_with_sources(justin_tree, [
      #("app", [#("app.graded", app_spec)]),
      #("justin", justin_files),
    ])
  let line = agreed_effect_line(root, name)
  support.cleanup(root <> "/..")
  line
}

pub fn a_catalog_answer_yields_only_to_a_resolved_effects_line_test() {
  let with_spec = fn(spec) {
    justin_answer(
      [#("src/justin.gleam", pure_fb), #("justin.graded", spec)],
      "",
      "justin.fb",
    )
  }
  with_spec("effects justin.fb : [Unknown]\n")
  |> should.equal("effects justin.fb : []")
  with_spec("effects justin.fb : [File]\n")
  |> should.equal("effects justin.fb : [File]")
  with_spec("effects justin.fb : [File, Unknown]\n")
  |> should.equal("effects justin.fb : []")
}

pub fn a_catalog_answer_yields_only_to_a_resolved_assume_line_test() {
  let with_spec = fn(spec) {
    justin_answer(
      [#("src/justin.gleam", pure_fb), #("justin.graded", spec)],
      "",
      "justin.fb",
    )
  }
  with_spec("assume justin.fb : [File]\n")
  |> should.equal("effects justin.fb : [File]")
  with_spec("assume justin.fb : [Unknown]\n")
  |> should.equal("effects justin.fb : []")
}

fn b_answer(
  b_files: List(#(String, String)),
  a_source: String,
  app_spec: String,
  name: String,
) -> String {
  let root =
    tree_with_sources("transitive_path", [
      #("app", [#("app.graded", app_spec)]),
      #("a", [#("src/a.gleam", a_source)]),
      #("b", b_files),
    ])
  let line = agreed_effect_line(root, name)
  support.cleanup(root <> "/..")
  line
}

pub fn a_consumer_module_level_assume_stands_against_inference_test() {
  let answer = fn(b_files) {
    b_answer(b_files, fa_calls_fb, "assume b : []\n", "b.fb")
  }
  answer([
    #("src/b.gleam", pure_fb),
    #("b.graded", "effects b.fb : [Unknown]\n"),
  ])
  |> should.equal("effects b.fb : []")
  answer([#("src/b.gleam", pure_fb), #("b.graded", "effects b.fb : [File]\n")])
  |> should.equal("effects b.fb : []")
  answer([
    #(
      "src/b.gleam",
      "import nowhere\n\npub fn fb() -> Int {\n  nowhere.x()\n}\n",
    ),
  ])
  |> should.equal("effects b.fb : []")
}

pub fn a_consumer_module_level_assume_yields_to_a_resolved_declaration_test() {
  b_answer(
    [#("src/b.gleam", pure_fb), #("b.graded", "assume b.fb : [File]\n")],
    fa_calls_fb,
    "assume b : []\n",
    "b.fb",
  )
  |> should.equal("effects b.fb : [File]")
}

pub fn a_consumer_committed_line_stands_against_any_contribution_test() {
  b_answer(
    [#("src/b.gleam", pure_fb), #("b.graded", "effects b.fb : [Unknown]\n")],
    fa_calls_fb,
    "effects b.fb : [File]\n",
    "b.fb",
  )
  |> should.equal("effects b.fb : [File]")
  b_answer(
    [#("src/b.gleam", pure_fb), #("b.graded", "effects b.fb : []\n")],
    fa_calls_fb,
    "effects b.fb : [File]\n",
    "b.fb",
  )
  |> should.equal("effects b.fb : [File]")
}

pub fn a_consumer_per_function_assume_stands_against_any_contribution_test() {
  let answer = fn(spec, name) {
    b_answer(
      [#("src/b.gleam", pure_fb), #("b.graded", spec)],
      fa_calls_fb,
      "assume b.fb : [Net]\n",
      name,
    )
  }
  answer("effects b.fb : []\n", "b.fb") |> should.equal("effects b.fb : [Net]")
  answer("assume b.fb : []\n", "b.fb") |> should.equal("effects b.fb : [Net]")
  answer("effects b.fb : []\n", "a.fa") |> should.equal("effects a.fa : [Net]")
  answer("assume b.fb : []\n", "a.fa") |> should.equal("effects a.fa : [Net]")
}

const apply_source = "pub fn apply(f: fn() -> Nil) -> Nil {\n  f()\n}\n"

const fa_applies_quietly =
  "import b\n\npub fn fa() -> Nil {\n  b.apply(fn() { Nil })\n}\n"

pub fn a_blanket_stands_against_an_unresolved_declaration_test() {
  // The catalog's blanket over `justin`.
  let catalog = fn(spec) {
    justin_answer(
      [#("src/justin.gleam", apply_source), #("justin.graded", spec)],
      "",
      "justin.apply",
    )
  }
  catalog("assume justin.apply(f: [f]) : [f]\n")
  |> should.equal("effects justin.apply : []")
  catalog("assume justin.apply : [Unknown]\n")
  |> should.equal("effects justin.apply : []")
  // The consumer's blanket over `b`, for the name and for a caller of it.
  let consumer = fn(spec, name) {
    b_answer(
      [#("src/b.gleam", apply_source), #("b.graded", spec)],
      fa_applies_quietly,
      "assume b : []\n",
      name,
    )
  }
  consumer("assume b.apply(f: [f]) : [f]\n", "b.apply")
  |> should.equal("effects b.apply : []")
  consumer("assume b.apply : [Unknown]\n", "b.apply")
  |> should.equal("effects b.apply : []")
  consumer("assume b.apply(f: [f]) : [f]\n", "a.fa")
  |> should.equal("effects a.fa : []")
  consumer("assume b.apply : [Unknown]\n", "a.fa")
  |> should.equal("effects a.fa : []")
}

const make_source = "pub fn make() -> fn() -> Nil {\n  fn() { Nil }\n}\n"

const fa_applies_make =
  "import b\n\npub fn fa() -> Nil {\n  let h = b.make()\n  h()\n}\n"

pub fn a_consumer_committed_return_stands_against_competing_returns_test() {
  let answer = fn(clause, name) {
    let root =
      tree_with_sources("transitive_path", [
        #("app", [
          #("app.graded", "effects b.make : [] where returns : [Stdout]\n"),
          #(
            "src/app.gleam",
            "import b\n\npub fn go() -> Nil {\n  let h = b.make()\n  h()\n}\n",
          ),
        ]),
        #("b", [
          #("src/b.gleam", make_source),
          #(
            "b.graded",
            "effects b.make : [] where returns : " <> clause <> "\n",
          ),
        ]),
      ])
    let line = agreed_effect_line(root, name)
    support.cleanup(root <> "/..")
    line
  }
  // Stuck, with a variable out of scope, and of a different arity.
  list.each(["[h([])]", "[x]", "fn(cb) -> [cb]"], fn(clause) {
    answer(clause, "b.make")
    |> should.equal("effects b.make : [] where returns : [Stdout]")
    answer(clause, "app.go") |> should.equal("effects app.go : [Stdout]")
  })
}

pub fn a_returned_operator_fills_where_nothing_answered_test() {
  // Without the package loaded, the caller read `[Unknown]`.
  b_answer([#("src/b.gleam", make_source)], fa_applies_make, "", "a.fa")
  |> should.equal("effects a.fa : []")
}

pub fn a_consumer_blanket_keeps_the_effect_of_a_returning_function_test() {
  let wrap = "pub fn wrap(f: fn() -> Nil) -> fn() -> Nil {\n  fn() { f() }\n}\n"
  let caller =
    "import b\n\npub fn fa() -> Nil {\n  let h = b.wrap(fn() { Nil })\n  h()\n}\n"
  // Its effect is the blanket's; the operator it returns fills where nothing
  // answered for it.
  b_answer([#("src/b.gleam", wrap)], caller, "assume b : []\n", "b.wrap")
  |> should.equal("effects b.wrap : [] where returns : [f]")
  // The operator fills, and `a` binds its callback through `wrap`'s
  // signature: more precise than the `[Unknown]` it read before.
  b_answer([#("src/b.gleam", wrap)], caller, "assume b : []\n", "a.fa")
  |> should.equal("effects a.fa : []")
}

const justin_ext =
  "@external(erlang, \"justin_ffi\", \"ext\")\n@external(javascript, \"./justin_ffi.mjs\", \"ext\")\npub fn ext() -> Nil\n"

const justin_ext_with_body =
  "@external(erlang, \"justin_ffi\", \"ext\")\npub fn ext() -> Nil {\n  sink()\n}\n\n@external(erlang, \"justin_ffi\", \"sink\")\n@external(javascript, \"./justin_ffi.mjs\", \"sink\")\nfn sink() -> Nil\n"

pub fn a_packages_own_declaration_over_its_external_answers_test() {
  justin_answer(
    [
      #("src/justin.gleam", justin_ext),
      #("justin.graded", "assume justin.ext : [File]\n"),
    ],
    "",
    "justin.ext",
  )
  |> should.equal("effects justin.ext : [File]")
  // A Gleam fallback body runs on JavaScript; the declaration answers alone.
  let root =
    tree_with_sources(justin_tree, [
      #("app", [
        #(
          "gleam.toml",
          support.dual_target_toml("app")
            <> "[dependencies]\na = { path = \"../a\" }\njustin = \">= 1.0.0 and < 2.0.0\"\n",
        ),
        #("app.graded", ""),
      ]),
      #("justin", [
        #("src/justin.gleam", justin_ext_with_body),
        #("justin.graded", "assume justin.ext : [File]\n"),
      ]),
    ])
  agreed_effect_line(root, "justin.ext")
  |> should.equal("effects justin.ext : [File]")
  support.cleanup(root <> "/..")
  // A consumer's own line stands over it.
  justin_answer(
    [
      #("src/justin.gleam", justin_ext),
      #("justin.graded", "assume justin.ext : [File]\n"),
    ],
    "assume justin.ext : [Net]\n",
    "justin.ext",
  )
  |> should.equal("effects justin.ext : [Net]")
}

// Call sites reading a newly loaded package's signatures, factories, update
// builders, constructors or provenance
//
// Each answer is equal to, or more precise than, the one the run gave before
// the package was loaded, except where a callback the package's own source
// declares is now charged. A site whose newly read route would leave it
// `[Unknown]` keeps the answer it had without that route.

const say_external =
  "@external(erlang, \"m\", \"say\")\n@external(javascript, \"m\", \"say\")\npub fn say() -> Nil\n"

const justin_routes =
  "pub type Runner {
  Runner(run: fn() -> Nil)
}

pub fn apply(f: fn() -> Nil) -> Nil {
  f()
}

pub fn apply2(x: Int, g: fn() -> Nil) -> Nil {
  g()
}

pub fn make(run run: fn() -> Nil) -> Runner {
  Runner(run:)
}

pub fn with_run(runner: Runner, run run: fn() -> Nil) -> Runner {
  Runner(..runner, run:)
}
"

const justin_route_spec =
  "assume app.say : [Stdout]
assume justin.apply2(f: [f]) : [f]
assume justin.Runner.run : [Disk]
"

fn justin_route_answer(app_source: String) -> String {
  let root =
    tree_with_sources(justin_tree, [
      #("app", [
        #("app.graded", justin_route_spec),
        #(
          "src/app.gleam",
          "import justin\nimport nowhere\n\n" <> say_external <> app_source,
        ),
      ]),
      #("justin", [#("src/justin.gleam", justin_routes)]),
    ])
  let line = agreed_effect_line(root, "app.go")
  support.cleanup(root <> "/..")
  line
}

pub fn a_signature_route_leaving_a_callback_unbound_keeps_its_answer_test() {
  // `apply2`'s source declares no label `f`, so read through its signature
  // the callback binds to nothing; read by label against the bound it binds.
  justin_route_answer("pub fn go() -> Nil {\n  justin.apply2(1, f: say)\n}\n")
  |> should.equal("effects app.go : [Stdout]")
}

pub fn a_mixed_site_keeps_the_callback_charge_and_reverts_the_route_test() {
  // Without the package, `apply` is the catalog's boundless `[]` and charges
  // `helper` nothing: `[]`. With it, `helper` is charged as `apply`'s
  // callback — `[Stdout]` — and the route inside `helper` that would leave
  // its own callback unbound is reverted, rather than answering
  // `[Stdout, Unknown]`.
  justin_route_answer(
    "fn quiet() -> Nil {\n  Nil\n}\n\nfn helper() -> Nil {\n  say()\n  justin.apply2(1, f: quiet)\n}\n\npub fn go() -> Nil {\n  justin.apply(helper)\n}\n",
  )
  |> should.equal("effects app.go : [Stdout]")
}

pub fn receiver_routes_are_equal_or_more_precise_test() {
  // Before, each of these receivers read `[Unknown]`: nothing traced a
  // newly loaded package's factory, builder or positional construction.
  let untraceable = [
    "pub fn go() -> Nil {\n  let r = justin.make(nowhere.x)\n  r.run()\n}\n",
    "pub fn go() -> Nil {\n  let r = justin.make(run: nowhere.x)\n  r.run()\n}\n",
    "pub fn go(base: justin.Runner) -> Nil {\n  let r = justin.with_run(base, nowhere.x)\n  r.run()\n}\n",
    "pub fn go(base: justin.Runner) -> Nil {\n  let r = justin.with_run(base, run: nowhere.x)\n  r.run()\n}\n",
    "pub fn go() -> Nil {\n  let r = justin.Runner(nowhere.x)\n  r.run()\n}\n",
  ]
  list.each(untraceable, fn(source) {
    justin_route_answer(source) |> should.equal("effects app.go : [Unknown]")
  })
  let resolved = [
    "pub fn go() -> Nil {\n  let r = justin.make(fn() { Nil })\n  r.run()\n}\n",
    "pub fn go() -> Nil {\n  let r = justin.make(run: fn() { Nil })\n  r.run()\n}\n",
    "pub fn go() -> Nil {\n  let r = justin.Runner(fn() { Nil })\n  r.run()\n}\n",
  ]
  list.each(resolved, fn(source) {
    justin_route_answer(source) |> should.equal("effects app.go : []")
  })
}

pub fn a_boundless_declaration_charges_a_function_passed_as_its_callback_test() {
  // A newly loaded function passed as the value of a boundless catalogued
  // function's callback. Before, the catalog's `[]` charged it nothing; now
  // the callback is charged, and the value's own callback binds to nothing.
  justin_route_answer("pub fn go() -> Nil {\n  justin.apply(justin.apply)\n}\n")
  |> should.equal("effects app.go : [Unknown]")
}

// `gleam/javascript/promise.new(a: [a]) : [a([])]` is the catalog's bounded
// entry. Before, a positional call bound nothing and read `[Unknown]`.
pub fn a_catalogued_bounded_entry_binds_through_the_new_signature_test() {
  let root = "build/dt_bounded_catalogue"
  let promise =
    "pub type Promise(a)\n\n@external(erlang, \"p\", \"new\")\n@external(javascript, \"p\", \"new\")\npub fn new(a a: fn(fn(value) -> Nil) -> Nil) -> Promise(value)\n"
  support.write_fixture(root, [
    #(
      "app/gleam.toml",
      "name = \"app\"\nversion = \"1.0.0\"\n[dependencies]\nshim = { path = \"../shim\" }\n",
    ),
    #(
      "app/manifest.toml",
      "packages = [\n  { name = \"gleam_javascript\", version = \"1.0.0\" },\n]\n",
    ),
    #("app/app.graded", "assume app.say : [Stdout]\n"),
    #(
      "app/src/app.gleam",
      "import gleam/javascript/promise\n\n"
        <> say_external
        <> "\npub fn go() -> promise.Promise(Nil) {\n  promise.new(fn(_resolve) { say() })\n}\n\npub fn go_labelled() -> promise.Promise(Nil) {\n  promise.new(a: fn(_resolve) { say() })\n}\n",
    ),
    #(
      "shim/gleam.toml",
      "name = \"shim\"\nversion = \"1.0.0\"\n[dependencies]\ngleam_javascript = { path = \"../gleam_javascript\" }\n",
    ),
    #("shim/src/shim.gleam", "pub fn f() -> Int {\n  1\n}\n"),
    #(
      "gleam_javascript/gleam.toml",
      "name = \"gleam_javascript\"\nversion = \"1.0.0\"\n",
    ),
    #("gleam_javascript/src/gleam/javascript/promise.gleam", promise),
  ])
  let loaded = agreed_effect_line(root <> "/app", "app.go")
  let loaded_labelled = agreed_effect_line(root <> "/app", "app.go_labelled")
  let assert Ok(Nil) = simplifile.delete(root <> "/gleam_javascript")
  agreed_effect_line(root <> "/app", "app.go") |> should.equal(loaded)
  agreed_effect_line(root <> "/app", "app.go_labelled")
  |> should.equal(loaded_labelled)
  loaded |> should.equal("effects app.go : [Stdout, Unknown]")
  loaded_labelled |> should.equal("effects app.go_labelled : [Stdout, Unknown]")
  support.cleanup(root)
}

// What the newly read source says about a name's parameters and its
// `@external`s is a fact about the code, and the answers follow it.

pub fn a_boundless_declaration_charges_its_callback_test() {
  // Before, the catalog's boundless `[]` charged the callback nothing.
  justin_route_answer("pub fn go() -> Nil {\n  justin.apply(say)\n}\n")
  |> should.equal("effects app.go : [Stdout]")
  // A function whose own effect is unresolved, passed as the value.
  let root =
    tree_with_sources(justin_tree, [
      #("app", [
        #(
          "src/app.gleam",
          "import justin\n\n@external(erlang, \"m\", \"untraced\")\n@external(javascript, \"m\", \"untraced\")\npub fn untraced() -> Nil\n\npub fn go() -> Nil {\n  justin.apply(untraced)\n}\n",
        ),
        #("app.graded", "assume app.untraced : [Unknown]\n"),
      ]),
      #("justin", [#("src/justin.gleam", justin_routes)]),
    ])
  agreed_effect_line(root, "app.go")
  |> should.equal("effects app.go : [Unknown]")
  support.cleanup(root <> "/..")
}

const justin_running_body =
  "@external(erlang, \"justin_ffi\", \"ext\")\npub fn ext() -> Nil {\n  say()\n}\n\n@external(erlang, \"justin_ffi\", \"say\")\n@external(javascript, \"./justin_ffi.mjs\", \"say\")\nfn say() -> Nil\n"

// A tree built for both targets, `justin` declaring an Erlang-only external
// whose Gleam body runs on JavaScript.
fn dual_target_justin_answer(
  justin_files: List(#(String, String)),
  app_spec: String,
  app_source: String,
  name: String,
) -> String {
  let root =
    tree_with_sources(justin_tree, [
      #("app", [
        #(
          "gleam.toml",
          support.dual_target_toml("app")
            <> "\n[dependencies]\na = { path = \"../a\" }\njustin = \">= 1.0.0 and < 2.0.0\"\n",
        ),
        #("app.graded", app_spec),
        #("src/app.gleam", app_source),
      ]),
      #("justin", justin_files),
    ])
  let line = agreed_effect_line(root, name)
  support.cleanup(root <> "/..")
  line
}

pub fn a_running_fallback_body_is_charged_beside_the_catalog_test() {
  let caller = "import justin\n\npub fn go() -> Nil {\n  justin.ext()\n}\n"
  // The catalog's `[]`, unioned with what the body does.
  dual_target_justin_answer(
    [#("src/justin.gleam", justin_running_body)],
    "assume justin.say : [Stdout]\n",
    caller,
    "app.go",
  )
  |> should.equal("effects app.go : [Stdout]")
  dual_target_justin_answer(
    [
      #(
        "src/justin.gleam",
        "import nowhere\n\n@external(erlang, \"justin_ffi\", \"ext\")\npub fn ext() -> Nil {\n  nowhere.thing()\n}\n",
      ),
    ],
    "",
    caller,
    "app.go",
  )
  |> should.equal("effects app.go : [Unknown]")
}

// Externals a newly loaded package declares
//
// A newly scanned `@external` is foreign code: only a declaration answers for
// its effects, and nothing inferred answers for what it returns.

const make_external =
  "@external(erlang, \"justin_ffi\", \"make\")\n@external(javascript, \"./justin_ffi.mjs\", \"make\")\npub fn make() -> fn() -> Nil\n"

const make_erlang_with_body =
  "@external(erlang, \"justin_ffi\", \"make\")\npub fn make() -> fn() -> Nil {\n  fn() { Nil }\n}\n"

const applies_justin_make =
  "import justin\n\npub fn go() -> Nil {\n  let h = justin.make()\n  h()\n}\n"

// The same tree for one target: `"dual"` for both, or one target's name.
fn targeted_justin_answer(
  targets: String,
  justin_source: String,
  app_spec: String,
  name: String,
) -> String {
  let toml = case targets {
    "dual" -> support.dual_target_toml("app")
    target -> "name = \"app\"\ntarget = \"" <> target <> "\"\n"
  }
  let root =
    tree_with_sources(justin_tree, [
      #("app", [
        #(
          "gleam.toml",
          toml
            <> "\n[dependencies]\na = { path = \"../a\" }\njustin = \">= 1.0.0 and < 2.0.0\"\n",
        ),
        #("app.graded", app_spec),
        #("src/app.gleam", applies_justin_make),
      ]),
      #("justin", [#("src/justin.gleam", justin_source)]),
    ])
  let line = agreed_effect_line(root, name)
  support.cleanup(root <> "/..")
  line
}

pub fn a_consumer_declared_return_stands_while_its_declaration_is_in_reach_test() {
  let declared = "assume justin.make where returns : [Net]\n"
  // Both halves built: the written line answers, its body suppressed.
  targeted_justin_answer("dual", make_erlang_with_body, declared, "app.go")
  |> should.equal("effects app.go : [Net]")
  targeted_justin_answer("dual", make_external, declared, "app.go")
  |> should.equal("effects app.go : [Net]")
  // Only the Gleam body is built, so the declaration it belongs to is out of
  // reach and its return is refused.
  targeted_justin_answer(
    "javascript",
    make_erlang_with_body,
    declared,
    "app.go",
  )
  |> should.equal("effects app.go : [Unknown]")
}

pub fn a_committed_return_over_a_newly_scanned_external_is_refused_test() {
  // Before, the consumer's committed clause answered: `[Net]`.
  let committed = "effects justin.make : [] where returns : [Net]\n"
  targeted_justin_answer("dual", make_external, committed, "app.go")
  |> should.equal("effects app.go : [Unknown]")
  // The committed line keys the name ahead of the catalog's module-level
  // one, and as inference over an external it answers nothing.
  targeted_justin_answer("dual", make_external, committed, "justin.make")
  |> should.equal("effects justin.make : [Unknown]")
  // An Erlang external with a Gleam body on a JavaScript build: the body's own
  // summary does not answer for the value either.
  targeted_justin_answer(
    "javascript",
    make_erlang_with_body,
    committed,
    "app.go",
  )
  |> should.equal("effects app.go : [Unknown]")
}

pub fn a_committed_effects_line_over_a_newly_scanned_external_is_refused_test() {
  // `b` is catalogued nowhere, so nothing declares its external. Before, the
  // consumer's committed line answered: `[File]`.
  let ext =
    "@external(erlang, \"b_ffi\", \"ext\")\n@external(javascript, \"./b_ffi.mjs\", \"ext\")\npub fn ext() -> Nil\n"
  let root =
    tree_with_sources("transitive_path", [
      #("app", [#("app.graded", "effects b.ext : [File]\n")]),
      #("b", [#("src/b.gleam", ext)]),
    ])
  let assert Ok(answer) = graded.run_effect(root, "b.ext")
  answer |> string.contains("effects b.ext : [Unknown]") |> should.be_true
  answer |> string.contains("external") |> should.be_true
  support.cleanup(root <> "/..")
}

pub fn a_factory_external_without_a_consumer_line_changes_nothing_test() {
  let factory =
    "pub type Runner {\n  Runner(run: fn() -> Nil)\n}\n\n@external(erlang, \"b_ffi\", \"make\")\n@external(javascript, \"./b_ffi.mjs\", \"make\")\npub fn make() -> Runner\n"
  let caller =
    "import b\n\npub fn go() -> Nil {\n  let r = b.make()\n  r.run()\n}\n"
  let root =
    tree_with_sources("transitive_path", [
      #("app", [#("src/app.gleam", caller), #("app.graded", "")]),
      #("b", [#("src/b.gleam", factory)]),
    ])
  let loaded = agreed_effect_line(root, "app.go")
  let assert Ok(Nil) = simplifile.delete(root <> "/../b")
  agreed_effect_line(root, "app.go") |> should.equal(loaded)
  loaded |> should.equal("effects app.go : [Unknown]")
  support.cleanup(root <> "/..")
}

// Answers that agree with a callee's
//
// A caller folded after its callee now reads the callee's final answer,
// `[Unknown]` included.

pub fn a_caller_folded_after_its_callee_reads_its_unknown_test() {
  let root = "build/dt_consistent_callee"
  let package = fn(name, dependencies, files) {
    [
      #(
        name <> "/gleam.toml",
        "name = \"" <> name <> "\"\nversion = \"1.0.0\"\n" <> dependencies,
      ),
      ..files
    ]
  }
  support.write_fixture(
    root,
    list.flatten([
      package(
        "app",
        "[dependencies]\njustin = { path = \"../justin\" }\nz = { path = \"../z\" }\n",
        [
          #(
            "app/manifest.toml",
            "packages = [\n  { name = \"justin\", version = \"1.0.0\" },\n]\n",
          ),
          #("app/src/app.gleam", "pub fn f() -> Int {\n  1\n}\n"),
        ],
      ),
      package("justin", "", [
        #("justin/src/justin.gleam", pure_fb),
        #("justin/justin.graded", "effects justin.fb : [Unknown]\n"),
      ]),
      package("z", "[dependencies]\njustin = { path = \"../justin\" }\n", [
        #(
          "z/src/z.gleam",
          "import justin\n\npub fn fz() -> Int {\n  justin.fb()\n}\n",
        ),
      ]),
    ]),
  )
  agreed_effect_line(root <> "/app", "justin.fb")
  |> should.equal("effects justin.fb : [Unknown]")
  agreed_effect_line(root <> "/app", "z.fz")
  |> should.equal("effects z.fz : [Unknown]")
  support.cleanup(root)
}

// A path dependency is still summarized before the dependency fallback
// bodies are walked, so its call into one reads `[Unknown]` where the
// project's own call reads the body.
pub fn a_path_dependency_calling_a_running_fallback_reads_unknown_test() {
  let ext =
    "@external(erlang, \"b_ffi\", \"ext\")\npub fn ext() -> Nil {\n  say()\n}\n\n@external(erlang, \"b_ffi\", \"say\")\n@external(javascript, \"./b_ffi.mjs\", \"say\")\nfn say() -> Nil\n"
  let root =
    tree_with_sources("transitive_path", [
      #("app", [
        #(
          "gleam.toml",
          "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"javascript\"\n\n[dependencies]\na = { path = \"../a\" }\n",
        ),
        #("app.graded", "assume b.say : [Stdout]\n"),
        #("src/app.gleam", "import b\n\npub fn go() -> Nil {\n  b.ext()\n}\n"),
      ]),
      #("a", [
        #("src/a.gleam", "import b\n\npub fn fa() -> Nil {\n  b.ext()\n}\n"),
      ]),
      #("b", [#("src/b.gleam", ext)]),
    ])
  agreed_effect_line(root, "b.ext") |> should.equal("effects b.ext : [Stdout]")
  agreed_effect_line(root, "app.go")
  |> should.equal("effects app.go : [Stdout]")
  agreed_effect_line(root, "a.fa") |> should.equal("effects a.fa : [Unknown]")
  support.cleanup(root <> "/..")
}

// What the run answered before
//
// The baseline a newly loaded package is weighed against is what the run
// answered for each of its names before the package was loaded: the same
// answer as a run that never reads it.

pub fn the_baseline_is_the_answer_before_the_package_was_loaded_test() {
  let cases = [
    #([#("justin.graded", "effects justin.fb : [File]\n")], "", "justin.fb"),
    #([#("justin.graded", "assume justin.fb : [Unknown]\n")], "", "justin.fb"),
    #([], "assume justin.fb : [Net]\n", "justin.fb"),
    #([], "effects justin.fb : [File]\n", "justin.fb"),
    #([], "effects justin.make : [] where returns : [Net]\n", "justin.make"),
    #([], "", "justin.make"),
  ]
  list.each(cases, fn(case_) {
    let #(justin_files, app_spec, name) = case_
    let root =
      tree_with_sources(justin_tree, [
        #("app", [#("app.graded", app_spec)]),
        #("justin", [
          #("src/justin.gleam", pure_fb <> "\n" <> make_source),
          ..justin_files
        ]),
      ])
    let baseline = graded.arbitration_baseline_answer(root, name)
    let assert Ok(Nil) = simplifile.delete(root <> "/../justin")
    baseline |> should.equal(graded.run_effect_from_project(root, name))
    support.cleanup(root <> "/..")
  })
}

pub fn an_installed_packages_module_level_line_is_never_displaced_test() {
  // A stale tree: the installed `inst` ships module `shared`, and so does
  // the newly loaded `b`. What `inst` declares for its own module stands.
  let root =
    tree_with_sources("transitive_path", [
      #("app", [
        #("build/packages/inst/inst.graded", "assume shared : [Disk]\n"),
        #(
          "build/packages/inst/src/shared.gleam",
          "pub fn go() -> Nil {\n  Nil\n}\n",
        ),
      ]),
      #("b", [
        #("src/shared.gleam", "pub fn go() -> Nil {\n  Nil\n}\n"),
        #("b.graded", "effects shared.go : []\n"),
      ]),
    ])
  agreed_effect_line(root, "shared.go")
  |> should.equal("effects shared.go : [Disk]")
  support.cleanup(root <> "/..")
}

// `envoy` is catalogued function by function: `assume envoy.get :
// [Environment]`, and no module-level line.
pub fn a_resolved_module_level_line_clears_the_catalogs_entries_test() {
  let answer = fn(spec) {
    let root = "build/dt_module_level_envoy"
    support.write_fixture(root, [
      #(
        "app/gleam.toml",
        "name = \"app\"\nversion = \"1.0.0\"\n[dependencies]\nshim = { path = \"../shim\" }\n",
      ),
      #(
        "app/manifest.toml",
        "packages = [\n  { name = \"envoy\", version = \"1.0.0\" },\n]\n",
      ),
      #("app/src/app.gleam", "pub fn f() -> Int {\n  1\n}\n"),
      #(
        "shim/gleam.toml",
        "name = \"shim\"\nversion = \"1.0.0\"\n[dependencies]\nenvoy = { path = \"../envoy\" }\n",
      ),
      #("shim/src/shim.gleam", "pub fn f() -> Int {\n  1\n}\n"),
      #("envoy/gleam.toml", "name = \"envoy\"\nversion = \"1.0.0\"\n"),
      #(
        "envoy/src/envoy.gleam",
        "pub fn get(name: String) -> String {\n  name\n}\n",
      ),
      #("envoy/envoy.graded", spec),
    ])
    let line = agreed_effect_line(root <> "/app", "envoy.get")
    support.cleanup(root)
    line
  }
  answer("assume envoy : [Disk]\n")
  |> should.equal("effects envoy.get : [Disk]")
  answer("assume envoy : [Disk, Unknown]\n")
  |> should.equal("effects envoy.get : [Environment]")
}

pub fn a_newly_loaded_packages_field_lines_are_not_applied_test() {
  let types = "pub type Runner {\n  Runner(run: fn() -> Nil)\n}\n"
  let callers =
    "import b\n\n"
    <> say_external
    <> "\npub fn go(r: b.Runner) -> Nil {\n  r.run()\n}\n\npub fn pure() -> Nil {\n  go(b.Runner(run: fn() { Nil }))\n}\n\npub fn loud() -> Nil {\n  go(b.Runner(run: say))\n}\n"
  list.each(["[Unknown]", "[Disk]"], fn(declared) {
    list.each(["app.go", "app.pure", "app.loud"], fn(name) {
      let root =
        tree_with_sources("transitive_path", [
          #("app", [
            #("src/app.gleam", callers),
            #("app.graded", "assume app.say : [Stdout]\n"),
          ]),
          #("b", [
            #("src/b.gleam", types),
            #("b.graded", "assume b.Runner.run : " <> declared <> "\n"),
          ]),
        ])
      let loaded = agreed_effect_line(root, name)
      let assert Ok(Nil) = simplifile.delete(root <> "/../b/b.graded")
      agreed_effect_line(root, name) |> should.equal(loaded)
      support.cleanup(root <> "/..")
    })
  })
}

pub fn a_newly_loaded_function_answers_where_nothing_did_test() {
  let root =
    tree_with_sources("transitive_path", [#("b", [#("src/b.gleam", pure_fb)])])
  agreed_effect_line(root, "b.fb") |> should.equal("effects b.fb : []")
  // A function-typed field nothing declares is still no answer.
  support.write_file(
    root <> "/../b/src/b.gleam",
    pure_fb <> "\npub type Box {\n  Box(f: fn() -> Nil)\n}\n",
  )
  graded.run_effect(root, "b.Box.f")
  |> should.equal(Error(graded.EffectNotFound("b.Box.f")))
  let assert Ok(Nil) = simplifile.delete(root <> "/../b")
  graded.run_effect(root, "b.fb")
  |> should.equal(Error(graded.EffectNotFound("b.fb")))
  support.cleanup(root <> "/..")
}

pub fn one_command_reads_each_gleam_toml_once_test() {
  let root = "build/dt_diamond_reads"
  let package = fn(name, dependencies) {
    [
      #(
        name <> "/gleam.toml",
        "name = \"" <> name <> "\"\nversion = \"1.0.0\"\n" <> dependencies,
      ),
      #(name <> "/src/" <> name <> ".gleam", "pub fn f() -> Int {\n  1\n}\n"),
    ]
  }
  support.write_fixture(
    root,
    list.flatten([
      package(
        "app",
        "[dependencies]\nleft = { path = \"../left\" }\nright = { path = \"../right\" }\n",
      ),
      package("left", "[dependencies]\nbase = { path = \"../base\" }\n"),
      package("right", "[dependencies]\nbase = { path = \"../base\" }\n"),
      package("base", ""),
    ]),
  )
  let assert Ok(visits) = graded.context_tree_visits(root <> "/app")
  list.length(visits) |> should.equal(4)
  visits |> list.unique |> list.length |> should.equal(4)
  support.cleanup(root)
}

pub fn a_resolved_line_equal_to_the_catalogs_changes_only_the_source_test() {
  let root =
    tree_with_sources(justin_tree, [
      #("justin", [
        #("src/justin.gleam", pure_fb),
        #("justin.graded", "effects justin.fb : []\n"),
      ]),
    ])
  let assert Ok(answer) = graded.run_effect(root, "justin.fb")
  answer |> string.contains("effects justin.fb : []") |> should.be_true
  answer
  |> string.contains("resolved from path dependency justin")
  |> should.be_true
  support.cleanup(root <> "/..")
}

// Path dependencies inferred against the run's signatures
//
// A path dependency's call into another package binds its callback through
// that package's signature, as the project's own call does.

const run_apply =
  "pub fn apply(run f: fn() -> Nil) -> Nil {\n  f()\n}\n\npub fn wrap(f: fn() -> Nil) -> fn() -> Nil {\n  fn() { f() }\n}\n\npub fn g(f: fn() -> Nil) -> Nil {\n  f()\n}\n"

const run_apply_spec =
  "effects b.apply(f: [f]) : [f]\neffects b.wrap(f: [f]) : [] where returns : [f]\neffects b.g(f: [f]) : [f, Unknown]\n"

// `app → a → b`, `b` shipping a spec, `a` calling it with `a_body` beside a
// printing external, and the project calling it with `app_body` beside its
// own.
fn registry_answer(a_body: String, app_body: String, name: String) -> String {
  let root =
    tree_with_sources("transitive_path", [
      #("app", [
        #(
          "src/app.gleam",
          "import b\nimport justin\n\n" <> say_external <> "\n" <> app_body,
        ),
        #(
          "app.graded",
          "assume app.say : [Stdout]\nassume a.say : [Stdout]\nassume a.untraced : [Unknown]\n",
        ),
        #(
          "manifest.toml",
          "packages = [\n  { name = \"justin\", version = \"1.0.0\" },\n]\n",
        ),
        #(
          "build/packages/justin/src/justin.gleam",
          "pub fn apply(f: fn() -> Nil) -> Nil {\n  f()\n}\n",
        ),
      ]),
      #("a", [
        #(
          "src/a.gleam",
          "import b\nimport justin\n\n"
            <> say_external
            <> "\n@external(erlang, \"m\", \"untraced\")\n@external(javascript, \"m\", \"untraced\")\npub fn untraced() -> Nil\n\n"
            <> a_body,
        ),
      ]),
      #("b", [#("src/b.gleam", run_apply), #("b.graded", run_apply_spec)]),
    ])
  let line = agreed_effect_line(root, name)
  support.cleanup(root <> "/..")
  line
}

pub fn a_path_dependency_binds_a_callback_through_the_run_signatures_test() {
  // Before, both read `[Stdout, Unknown]` from `a`, and `[Stdout]` from the
  // project.
  let positional = "pub fn fa() -> Nil {\n  b.apply(fn() { say() })\n}\n"
  let labelled = "pub fn fa() -> Nil {\n  b.apply(run: fn() { say() })\n}\n"
  registry_answer(positional, "", "a.fa")
  |> should.equal("effects a.fa : [Stdout]")
  registry_answer(labelled, "", "a.fa")
  |> should.equal("effects a.fa : [Stdout]")
  registry_answer(
    positional,
    "pub fn go() -> Nil {\n  b.apply(fn() { say() })\n}\n",
    "app.go",
  )
  |> should.equal("effects app.go : [Stdout]")
}

pub fn a_path_dependency_applies_a_returned_operator_test() {
  registry_answer(
    "pub fn fa() -> Nil {\n  let h = b.wrap(say)\n  h()\n}\n",
    "",
    "a.fa",
  )
  |> should.equal("effects a.fa : [Stdout]")
}

pub fn a_path_dependency_calls_a_callback_field_as_the_project_does_test() {
  let body = "pub fn f() -> Nil {\n  let r = b.Runner(run: say)\n  r.run()\n}\n"
  let types = "pub type Runner {\n  Runner(run: fn() -> Nil)\n}\n"
  let root =
    tree_with_sources("transitive_path", [
      #("app", [
        #(
          "src/app.gleam",
          "import b\n\n@external(erlang, \"m\", \"say\")\n@external(javascript, \"m\", \"say\")\npub fn say() -> Nil\n\n"
            <> body,
        ),
        #("app.graded", "assume app.say : [Stdout]\nassume a.say : [Stdout]\n"),
      ]),
      #("a", [
        #(
          "src/a.gleam",
          "import b\n\n@external(erlang, \"m\", \"say\")\n@external(javascript, \"m\", \"say\")\npub fn say() -> Nil\n\n"
            <> body,
        ),
      ]),
      #("b", [#("src/b.gleam", types)]),
    ])
  agreed_effect_line(root, "a.f") |> should.equal("effects a.f : [Stdout]")
  agreed_effect_line(root, "app.f") |> should.equal("effects app.f : [Stdout]")
  support.cleanup(root <> "/..")
}

pub fn a_path_dependencys_own_higher_order_calls_are_unchanged_test() {
  registry_answer(
    "fn local_apply(f: fn() -> Nil) -> Nil {\n  f()\n}\n\npub fn fa() -> Nil {\n  local_apply(say)\n}\n",
    "",
    "a.fa",
  )
  |> should.equal("effects a.fa : [Stdout]")
}

pub fn a_path_dependency_charges_a_boundless_declarations_callback_test() {
  // `justin` is installed and catalogued `assume justin : []`. Before, `a`
  // read no signature for `justin.apply` and charged its callback nothing.
  registry_answer(
    "pub fn fa() -> Nil {\n  justin.apply(untraced)\n}\n",
    "",
    "a.fa",
  )
  |> should.equal("effects a.fa : [Unknown]")
}

pub fn a_path_dependency_agrees_with_its_callees_answer_test() {
  registry_answer("pub fn fa() -> Nil {\n  b.g(say)\n}\n", "", "a.fa")
  |> should.equal("effects a.fa : [Stdout, Unknown]")
  registry_answer("", "pub fn go() -> Nil {\n  b.g(say)\n}\n", "app.go")
  |> should.equal("effects app.go : [Stdout, Unknown]")
}

pub fn one_function_gains_a_resolution_and_a_callback_charge_test() {
  // The first call binds `say` through `b.apply`'s signature (`[Stdout]`);
  // the second charges `untraced` as the boundless `justin.apply`'s callback
  // (`[Unknown]`).
  registry_answer(
    "pub fn fa() -> Nil {\n  b.apply(say)\n  justin.apply(untraced)\n}\n",
    "",
    "a.fa",
  )
  |> should.equal("effects a.fa : [Stdout, Unknown]")
}
