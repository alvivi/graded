// Tests for `graded/internal/config` — gleam.toml `[tools.graded]` parsing
// and source-path-to-module-name resolution. Fixtures are written under
// `/tmp/` so they don't get picked up by the Gleam compiler as project
// sources.

import filepath
import glance
import gleam/dict
import gleam/list
import gleam/set
import gleeunit/should
import graded/internal/config
import graded/internal/extract
import graded/internal/types
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

// Compilation targets
//
// `gleam.toml`'s top-level `target` and `[tools.graded].targets`, which decide
// which `@external` declarations are ever built, and which of the two readings
// of them a package gets.

pub fn no_target_field_is_defaulted_test() {
  // Neither field names a target: the compiler's default stands in for the
  // build, and every target stands in wherever reading it narrowly could drop a
  // declared effect.
  let path = write_toml("no_target", "name = \"myapp\"\n")
  let assert Ok(cfg) = config.read(path)
  cfg.targets |> should.equal(types.DefaultedTargets)
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
}

pub fn a_target_list_that_is_not_an_array_reads_as_every_target_test() {
  let path =
    write_toml(
      "declared_targets_string",
      "name = \"myapp\"\ntarget = \"javascript\"\n\n[tools.graded]\ntargets = \"erlang\"\n",
    )
  let assert Ok(cfg) = config.read(path)
  cfg.targets |> should.equal(types.NamedTargets(types.every_target()))
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
}

pub fn an_erlang_target_narrows_to_erlang_test() {
  let path =
    write_toml("erlang_target", "name = \"myapp\"\ntarget = \"erlang\"\n")
  let assert Ok(cfg) = config.read(path)
  cfg.targets |> should.equal(types.NamedTargets(set.from_list(["erlang"])))
}

pub fn a_javascript_target_narrows_to_javascript_test() {
  let path =
    write_toml("js_target", "name = \"myapp\"\ntarget = \"javascript\"\n")
  let assert Ok(cfg) = config.read(path)
  cfg.targets
  |> should.equal(types.NamedTargets(set.from_list(["javascript"])))
}

pub fn an_unrecognised_target_reads_as_every_target_test() {
  // A target graded does not know narrows nothing rather than narrowing to
  // nothing.
  let path = write_toml("odd_target", "name = \"myapp\"\ntarget = \"llvm\"\n")
  let assert Ok(cfg) = config.read(path)
  cfg.targets |> should.equal(types.NamedTargets(types.every_target()))
}

pub fn a_missing_gleam_toml_is_every_target_test() {
  // A package with no `gleam.toml` at all: there is no field whose absence the
  // compiler's default could stand in for, so both readings are every target.
  config.defaults_for("myapp").targets
  |> should.equal(types.NamedTargets(types.every_target()))
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
