// Tests for `graded/internal/config` — gleam.toml `[tools.graded]` parsing
// and source-path-to-module-name resolution. Fixtures are written under
// `/tmp/` so they don't get picked up by the Gleam compiler as project
// sources.

import filepath
import generators
import glance
import gleam/dict
import gleam/list
import gleam/set
import gleam/string
import gleeunit/should
import graded/internal/config
import graded/internal/extract
import graded/internal/types
import qcheck
import simplifile

// Fixture setup
//
// Each test writes its own gleam.toml into a per-test temporary directory,
// so cases stay independent and reruns start clean.

fn write_toml(name: String, content: String) -> String {
  let directory = "/tmp/graded_config_" <> name
  let _ = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let path = filepath.join(directory, "gleam.toml")
  let assert Ok(Nil) = simplifile.write(path, content)
  path
}

// Reading [tools.graded]
//
// `config.read` on well-formed gleam.toml files: defaults when the table is
// absent, then each override individually, then both together.

pub fn defaults_when_tools_graded_missing_test() {
  let path =
    write_toml(
      "missing_table",
      "name = \"myapp\"
version = \"1.0.0\"
",
    )
  let assert Ok(cfg) = config.read(path)
  cfg.package_name |> should.equal("myapp")
  cfg.spec_file |> should.equal("myapp.graded")
  cfg.cache_dir |> should.equal("build/.graded")
}

pub fn explicit_spec_file_test() {
  let path =
    write_toml(
      "explicit_spec",
      "name = \"myapp\"

[tools.graded]
spec_file = \"support/myapp.graded\"
",
    )
  let assert Ok(cfg) = config.read(path)
  cfg.spec_file |> should.equal("support/myapp.graded")
  cfg.cache_dir |> should.equal("build/.graded")
}

pub fn explicit_cache_dir_test() {
  let path =
    write_toml(
      "explicit_cache",
      "name = \"myapp\"

[tools.graded]
cache_dir = \".graded_cache\"
",
    )
  let assert Ok(cfg) = config.read(path)
  cfg.spec_file |> should.equal("myapp.graded")
  cfg.cache_dir |> should.equal(".graded_cache")
}

pub fn both_overrides_test() {
  let path =
    write_toml(
      "both",
      "name = \"weird_pkg\"

[tools.graded]
spec_file = \"effects/weird_pkg.graded\"
cache_dir = \"_cache/graded\"
",
    )
  let assert Ok(cfg) = config.read(path)
  cfg.package_name |> should.equal("weird_pkg")
  cfg.spec_file |> should.equal("effects/weird_pkg.graded")
  cfg.cache_dir |> should.equal("_cache/graded")
}

// Error cases
//
// `config.read` failures: a gleam.toml without a package name, and a path
// with no gleam.toml at all.

pub fn missing_name_is_error_test() {
  let path =
    write_toml(
      "no_name",
      "version = \"1.0.0\"

[tools.graded]
spec_file = \"foo.graded\"
",
    )
  let result = config.read(path)
  case result {
    Error(config.MissingPackageName(_)) -> Nil
    _ -> should.fail()
  }
}

pub fn missing_file_is_error_test() {
  let result = config.read("/tmp/graded_config_does_not_exist/gleam.toml")
  case result {
    Error(config.TomlReadError(_, _)) -> Nil
    _ -> should.fail()
  }
}

// Defaults helper
//
// `config.defaults_for` builds a config from a bare package name without
// touching the filesystem.

pub fn defaults_for_helper_test() {
  let cfg = config.defaults_for("hello")
  cfg.package_name |> should.equal("hello")
  cfg.spec_file |> should.equal("hello.graded")
  cfg.cache_dir |> should.equal("build/.graded")
}

// Internal modules
//
// The compiler's own `internal_modules` key, read beside `[tools.graded]`: the
// default rule when it is absent, replaced whole by a list, and disabled by an
// empty one.

pub fn internal_modules_default_when_absent_test() {
  let path = write_toml("internal_absent", "name = \"myapp\"\n")
  let assert Ok(cfg) = config.read(path)
  cfg.internal_modules
  |> should.equal(["myapp/internal", "myapp/internal/*"])
  config.is_internal_module(cfg, "myapp/internal") |> should.be_true()
  config.is_internal_module(cfg, "myapp/internal/deep/er") |> should.be_true()
  config.is_internal_module(cfg, "myapp/internallll") |> should.be_false()
  config.is_internal_module(cfg, "myapp/web/internal") |> should.be_false()
  config.is_internal_module(cfg, "other/internal") |> should.be_false()
  config.is_internal_module(cfg, "myapp") |> should.be_false()
}

pub fn internal_modules_explicit_list_replaces_the_default_test() {
  let path =
    write_toml(
      "internal_explicit",
      "name = \"myapp\"\ninternal_modules = [\"myapp/hidden/*\"]\n",
    )
  let assert Ok(cfg) = config.read(path)
  cfg.internal_modules |> should.equal(["myapp/hidden/*"])
  config.is_internal_module(cfg, "myapp/hidden/x") |> should.be_true()
  config.is_internal_module(cfg, "myapp/internal/x") |> should.be_false()
}

pub fn internal_modules_empty_list_makes_nothing_internal_test() {
  let path =
    write_toml("internal_empty", "name = \"myapp\"\ninternal_modules = []\n")
  let assert Ok(cfg) = config.read(path)
  cfg.internal_modules |> should.equal([])
  config.is_internal_module(cfg, "myapp/internal") |> should.be_false()
}

pub fn internal_modules_not_strings_reads_as_the_default_test() {
  let path =
    write_toml(
      "internal_not_strings",
      "name = \"myapp\"\ninternal_modules = [\"myapp/x\", 3]\n",
    )
  let assert Ok(cfg) = config.read(path)
  cfg.internal_modules
  |> should.equal(["myapp/internal", "myapp/internal/*"])
  let path =
    write_toml(
      "internal_not_array",
      "name = \"myapp\"\ninternal_modules = \"myapp/x\"\n",
    )
  let assert Ok(cfg) = config.read(path)
  cfg.internal_modules
  |> should.equal(["myapp/internal", "myapp/internal/*"])
}

pub fn internal_modules_defaults_for_substitutes_the_rule_test() {
  config.defaults_for("fixtures").internal_modules
  |> should.equal(["fixtures/internal", "fixtures/internal/*"])
}

// The glob dialect
//
// Each row of the compiler probe: a pattern list, and which modules of the
// probe package it hides. Probed on gleam 1.18.0 with `gleam export
// package-interface`.

const probe_modules = [
  "probe", "probe/internal", "probe/internal/deep", "probe/internal/deep/deeper",
  "probe/internallll", "probe/priv_impl", "probe/hidden/x", "probe/secret/y",
  "probe/helper", "probe/a/helper", "probe/a/b/helper", "other/internal",
  "other/visible",
]

fn hidden_by(patterns: List(String)) -> List(String) {
  let cfg =
    config.GradedConfig(
      ..config.defaults_for("probe"),
      internal_modules: patterns,
    )
  list.filter(probe_modules, config.is_internal_module(cfg, _))
}

pub fn glob_probe_table_test() {
  [
    #(config.default_internal_modules("probe"), [
      "probe/internal", "probe/internal/deep", "probe/internal/deep/deeper",
    ]),
    #([], []),
    #(["probe/internal"], ["probe/internal"]),
    #(["probe/internal*"], [
      "probe/internal", "probe/internal/deep", "probe/internal/deep/deeper",
      "probe/internallll",
    ]),
    #(["probe/i?ternal"], ["probe/internal"]),
    #(["probe/{internal,hidden}/*"], [
      "probe/internal/deep", "probe/internal/deep/deeper", "probe/hidden/x",
    ]),
    #(["probe/{internal,}"], ["probe/internal"]),
    #(["probe/**/helper"], [
      "probe/helper",
      "probe/a/helper",
      "probe/a/b/helper",
    ]),
    #(["probe/*/helper"], ["probe/a/helper", "probe/a/b/helper"]),
    #(["probe/**"], list.drop(probe_modules, 1) |> list.take(10)),
    #(["**/internal"], ["probe/internal", "other/internal"]),
    #(["probe/a**"], ["probe/a/helper", "probe/a/b/helper"]),
    #(["probe/priv\\_impl"], ["probe/priv_impl"]),
    #(["probe/[!i]*"], [
      "probe/priv_impl", "probe/hidden/x", "probe/secret/y", "probe/helper",
      "probe/a/helper", "probe/a/b/helper",
    ]),
    #(["probe/[a-h]*"], [
      "probe/hidden/x", "probe/helper", "probe/a/helper", "probe/a/b/helper",
    ]),
    #(["probe/{internal,{hidden,secret}}/*", "other/[^i]*"], [
      "probe/internal/deep", "probe/internal/deep/deeper", "probe/hidden/x",
      "probe/secret/y", "other/visible",
    ]),
  ]
  |> list.each(fn(row) {
    let #(patterns, hidden) = row
    #(patterns, hidden_by(patterns)) |> should.equal(#(patterns, hidden))
  })
}

pub fn glob_malformed_patterns_match_nothing_test() {
  // The three shapes the compiler refuses `gleam.toml` over, plus a dangling
  // escape and a reversed range, which it refuses too.
  [
    "probe/{internal", "probe/[abc", "probe/{internal,hidden}}", "probe/\\",
    "probe/[z-a]*",
  ]
  |> list.each(fn(pattern) {
    #(pattern, hidden_by([pattern])) |> should.equal(#(pattern, []))
  })
}

pub fn glob_whole_pattern_double_star_matches_everything_test() {
  hidden_by(["**"]) |> should.equal(probe_modules)
}

pub fn glob_class_edge_graphemes_test() {
  // A `]` or `-` opening a class is itself, and a `-` closing one is too.
  config.glob_matches("a[]]b", "a]b") |> should.be_true()
  config.glob_matches("a[-x]b", "a-b") |> should.be_true()
  config.glob_matches("a[x-]b", "a-b") |> should.be_true()
  config.glob_matches("a[x-]b", "axb") |> should.be_true()
  config.glob_matches("a[x-]b", "ayb") |> should.be_false()
  // `?`, `*` and a negated class all cross `/`.
  config.glob_matches("a?b", "a/b") |> should.be_true()
  config.glob_matches("a[!x]b", "a/b") |> should.be_true()
}

pub fn glob_module_path_property_test() {
  use path <- qcheck.given(generators.module_path_gen())
  let assert Ok(last) = string.split(path, "/") |> list.last
  {
    config.glob_matches(path, path)
    && config.glob_matches("*", path)
    && config.glob_matches("**/" <> last, path)
  }
  |> should.be_true()
}

// Compilation targets
//
// `gleam.toml`'s top-level `target` and `[tools.graded].targets`, which decide
// which `@external` declarations are ever built, and which of the two readings
// of them a package gets. Each case also pins `targets_source`, which states
// where the set came from and changes no decision.

pub fn no_target_field_is_defaulted_test() {
  // Neither field names a target: the compiler's default stands in for the
  // build, and every target stands in wherever reading it narrowly could drop a
  // declared effect.
  let path = write_toml("no_target", "name = \"myapp\"\n")
  let assert Ok(cfg) = config.read(path)
  cfg.targets |> should.equal(types.DefaultedTargets)
  cfg.targets_source |> should.equal(config.NoTargetDeclared)
  types.build_targets(cfg.targets) |> should.equal(types.default_target())
  types.declaration_targets(cfg.targets) |> should.equal(types.every_target())
}

pub fn a_declared_target_list_widens_past_the_compilers_one_test() {
  // The only way a package built for both targets can say so: `target` names
  // exactly one, and so does its absence.
  let path =
    write_toml(
      "declared_targets",
      "name = \"myapp\"\ntarget = \"erlang\"\n\n[tools.graded]\ntargets = [\"erlang\", \"javascript\"]\n",
    )
  let assert Ok(cfg) = config.read(path)
  cfg.targets |> should.equal(types.NamedTargets(types.every_target()))
  // Both keys are present; the list wins and the source says which was read.
  cfg.targets_source |> should.equal(config.ToolsGradedTargets)
}

pub fn a_declared_target_list_can_narrow_too_test() {
  let path =
    write_toml(
      "declared_targets_narrow",
      "name = \"myapp\"\n\n[tools.graded]\ntargets = [\"javascript\"]\n",
    )
  let assert Ok(cfg) = config.read(path)
  cfg.targets
  |> should.equal(types.NamedTargets(set.from_list(["javascript"])))
  cfg.targets_source |> should.equal(config.ToolsGradedTargets)
}

pub fn an_unreadable_target_list_reads_as_every_target_test() {
  // A list holding a target graded does not know states that the package is
  // built for something and leaves graded unable to say which, so every target
  // stays in reach — the same reading an unrecognised `target` gets, and the
  // widest one. Falling through to `target` instead answered with one target for
  // a package whose list plainly names two.
  let path =
    write_toml(
      "declared_targets_odd",
      "name = \"myapp\"\ntarget = \"javascript\"\n\n[tools.graded]\ntargets = [\"erlang\", \"llvm\"]\n",
    )
  let assert Ok(cfg) = config.read(path)
  cfg.targets |> should.equal(types.NamedTargets(types.every_target()))
  cfg.targets_source |> should.equal(config.UnreadableDeclaration)
}

pub fn a_target_list_that_is_not_an_array_reads_as_every_target_test() {
  let path =
    write_toml(
      "declared_targets_string",
      "name = \"myapp\"\ntarget = \"javascript\"\n\n[tools.graded]\ntargets = \"erlang\"\n",
    )
  let assert Ok(cfg) = config.read(path)
  cfg.targets |> should.equal(types.NamedTargets(types.every_target()))
  cfg.targets_source |> should.equal(config.UnreadableDeclaration)
}

pub fn an_empty_target_list_falls_back_to_the_target_field_test() {
  // An empty list names no target the way an absent key does, so the reading
  // falls to `target` rather than to the widest set.
  let path =
    write_toml(
      "declared_targets_empty",
      "name = \"myapp\"\n\n[tools.graded]\ntargets = []\n",
    )
  let assert Ok(cfg) = config.read(path)
  cfg.targets |> should.equal(types.DefaultedTargets)
  cfg.targets_source |> should.equal(config.NoTargetDeclared)
}

pub fn an_erlang_target_narrows_to_erlang_test() {
  let path =
    write_toml("erlang_target", "name = \"myapp\"\ntarget = \"erlang\"\n")
  let assert Ok(cfg) = config.read(path)
  cfg.targets |> should.equal(types.NamedTargets(set.from_list(["erlang"])))
  cfg.targets_source |> should.equal(config.TopLevelTarget)
}

pub fn a_javascript_target_narrows_to_javascript_test() {
  let path =
    write_toml("js_target", "name = \"myapp\"\ntarget = \"javascript\"\n")
  let assert Ok(cfg) = config.read(path)
  cfg.targets
  |> should.equal(types.NamedTargets(set.from_list(["javascript"])))
  cfg.targets_source |> should.equal(config.TopLevelTarget)
}

pub fn an_unrecognised_target_reads_as_every_target_test() {
  // A target graded does not know narrows nothing rather than narrowing to
  // nothing.
  let path = write_toml("odd_target", "name = \"myapp\"\ntarget = \"llvm\"\n")
  let assert Ok(cfg) = config.read(path)
  cfg.targets |> should.equal(types.NamedTargets(types.every_target()))
  cfg.targets_source |> should.equal(config.UnreadableDeclaration)
}

pub fn a_missing_gleam_toml_is_every_target_test() {
  // A package with no `gleam.toml` at all: there is no field whose absence the
  // compiler's default could stand in for, so both readings are every target.
  config.defaults_for("myapp").targets
  |> should.equal(types.NamedTargets(types.every_target()))
  config.defaults_for("myapp").targets_source
  |> should.equal(config.NoConfig)
}

// Module paths
//
// `config.module_path_for_source` turns a source file path into the dotted
// module name, and that name has to agree with what `extract` reads off an
// import.

pub fn module_path_simple_test() {
  config.module_path_for_source("src/app.gleam", "src")
  |> should.equal("app")
}

pub fn module_path_nested_test() {
  config.module_path_for_source("src/app/router.gleam", "src")
  |> should.equal("app/router")
}

pub fn module_path_custom_directory_test() {
  config.module_path_for_source("test/fixtures/view.gleam", "test/fixtures")
  |> should.equal("view")
}

pub fn module_path_deeply_nested_test() {
  config.module_path_for_source("src/app/web/handlers/auth.gleam", "src")
  |> should.equal("app/web/handlers/auth")
}

// Critical: the dotted module name we compute for a `.gleam` file must
// exactly match the string `extract.build_import_context` produces when
// another module imports it. The topological sort relies on intersecting
// these two views — if they ever drift, dependency edges silently
// disappear and inference degenerates back to the per-file behaviour.
pub fn module_path_matches_import_context_test() {
  // Compute the module name for a fake "leaf" file as it would live on disk.
  let leaf_module = config.module_path_for_source("src/app/d.gleam", "src")

  // Parse a sibling that imports it and read what extract sees.
  let src =
    "import app/d
pub fn run() { d.format(\"hi\") }"
  let assert Ok(module) = glance.module(src)
  let ctx = extract.build_import_context(module)

  // The extracted import path must match what we computed from the file path.
  ctx.aliases
  |> dict.values()
  |> list.contains(leaf_module)
  |> should.be_true()
}

pub fn module_path_matches_import_context_nested_test() {
  let leaf_module =
    config.module_path_for_source("src/app/web/handlers/auth.gleam", "src")

  let src =
    "import app/web/handlers/auth
pub fn run() { auth.check() }"
  let assert Ok(module) = glance.module(src)
  let ctx = extract.build_import_context(module)

  ctx.aliases
  |> dict.values()
  |> list.contains(leaf_module)
  |> should.be_true()
}
