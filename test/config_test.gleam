// Tests for `graded/internal/config` — gleam.toml `[tools.graded]` parsing.
// Fixtures are written under `/tmp/` so they don't get picked up by the
// Gleam compiler as project sources.

import filepath
import gleeunit/should
import graded/internal/config
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
