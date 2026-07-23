// Tests for `graded pack`: injecting the configured `.graded` spec into a hex
// tarball so it ships to consumers. A test-support FFI builds a minimal hex
// tarball (`graded_pack_test_ffi`) so these run without a real `gleam export`.
// Project trees are materialised under `build/` (gitignored) at runtime.

import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import gleeunit/should
import graded
import graded/internal/types.{Specific}
import simplifile

// A tarball with one inner source file, plus a gleam.toml and the spec to be
// injected, materialised at `root`. Returns the tarball path.
fn setup_dep(
  root: String,
  name: String,
  version: String,
  spec_file: String,
  spec: String,
) -> String {
  let _ = simplifile.delete(root)
  write(
    root <> "/gleam.toml",
    "name = \"" <> name <> "\"\nversion = \"" <> version <> "\"\n",
  )
  write(root <> "/" <> spec_file, spec)
  let tarball = root <> "/build/" <> name <> "-" <> version <> ".tar"
  ensure_parent(tarball)
  build_tarball(tarball, name, version, [
    #("src/" <> name <> ".gleam", "pub fn work() -> Nil {\n  Nil\n}\n"),
  ])
  tarball
}

fn write(path: String, contents: String) -> Nil {
  ensure_parent(path)
  let assert Ok(Nil) = simplifile.write(path, contents)
  Nil
}

fn ensure_parent(path: String) -> Nil {
  let dir = case string.split(path, "/") {
    [] -> "."
    parts -> string.join(list.take(parts, list.length(parts) - 1), "/")
  }
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  Nil
}

fn cleanup(root: String) -> Nil {
  let _ = simplifile.delete(root)
  Nil
}

pub fn pack_injects_and_reports_test() {
  let root = "build/pack_inject"
  let _ =
    setup_dep(root, "dep", "1.0.0", "dep.graded", "effects dep.work : []\n")

  let assert Ok(message) = graded.pack_project(root, None)
  string.contains(message, "injected dep.graded") |> should.be_true()
  // The publish guidance names the Hex API, never `gleam publish`.
  string.contains(message, "hex.pm/api/publish") |> should.be_true()
  string.contains(message, "gleam publish") |> should.be_true()

  // The patched tarball unpacks with the injected spec present and intact.
  let dest = root <> "/unpacked"
  unpack_inner(root <> "/build/dep-1.0.0.tar", dest)
  let assert Ok(spec) = simplifile.read(dest <> "/dep.graded")
  string.contains(spec, "effects dep.work : []") |> should.be_true()
  // The original source survived the round-trip.
  simplifile.is_file(dest <> "/src/dep.gleam") |> should.equal(Ok(True))

  cleanup(root)
}

pub fn pack_default_tarball_identity_mismatch_test() {
  let root = "build/pack_mismatch"
  let _ = simplifile.delete(root)
  // Project declares version 2.0.0, but only a 1.0.0 tarball exists — the
  // default path build/dep-2.0.0.tar is missing, so pack errors rather than
  // patching the wrong archive.
  write(root <> "/gleam.toml", "name = \"dep\"\nversion = \"2.0.0\"\n")
  write(root <> "/dep.graded", "effects dep.work : []\n")
  let tarball = root <> "/build/dep-1.0.0.tar"
  ensure_parent(tarball)
  build_tarball(tarball, "dep", "1.0.0", [
    #("src/dep.gleam", "pub fn work() {\n  Nil\n}\n"),
  ])

  let assert Error(_) = graded.pack_project(root, None)
  cleanup(root)
}

pub fn pack_explicit_tarball_test() {
  let root = "build/pack_explicit"
  let tarball =
    setup_dep(root, "dep", "9.9.9", "dep.graded", "effects dep.work : []\n")

  // No default build/dep-<version>.tar is looked for; the explicit path is used.
  let assert Ok(_) = graded.pack_project(root, Some(tarball))
  cleanup(root)
}

pub fn pack_custom_spec_file_test() {
  let root = "build/pack_custom_spec"
  let _ = simplifile.delete(root)
  write(
    root <> "/gleam.toml",
    "name = \"dep\"\nversion = \"1.0.0\"\n\n[tools.graded]\nspec_file = \"effects/api.graded\"\n",
  )
  write(root <> "/effects/api.graded", "effects dep.work : []\n")
  let tarball = root <> "/build/dep-1.0.0.tar"
  ensure_parent(tarball)
  build_tarball(tarball, "dep", "1.0.0", [
    #("src/dep.gleam", "pub fn work() {\n  Nil\n}\n"),
  ])

  let assert Ok(_) = graded.pack_project(root, None)

  // The spec lands at the configured archive-relative path, not `dep.graded`.
  let dest = root <> "/unpacked"
  unpack_inner(tarball, dest)
  simplifile.is_file(dest <> "/effects/api.graded") |> should.equal(Ok(True))
  simplifile.is_file(dest <> "/dep.graded") |> should.equal(Ok(False))
  cleanup(root)
}

pub fn pack_rejects_absolute_spec_path_test() {
  let root = "build/pack_absolute"
  let _ = simplifile.delete(root)
  write(
    root <> "/gleam.toml",
    "name = \"dep\"\n\n[tools.graded]\nspec_file = \"/etc/dep.graded\"\n",
  )
  let assert Error(_) = graded.pack_project(root, Some("unused.tar"))
  cleanup(root)
}

pub fn pack_rejects_escaping_spec_path_test() {
  let root = "build/pack_escape"
  let _ = simplifile.delete(root)
  write(
    root <> "/gleam.toml",
    "name = \"dep\"\n\n[tools.graded]\nspec_file = \"../escape.graded\"\n",
  )
  let assert Error(_) = graded.pack_project(root, Some("unused.tar"))
  cleanup(root)
}

// End-to-end: a consumer resolves a dependency call through the injected spec.
pub fn pack_consumer_resolves_injected_spec_test() {
  let dep_root = "build/pack_e2e_dep"
  let _ =
    setup_dep(
      dep_root,
      "packdep",
      "1.0.0",
      "packdep.graded",
      "effects packdep.work : [Stdout]\n",
    )
  let assert Ok(_) = graded.pack_project(dep_root, None)

  // Simulate `gleam` installing the published dependency: unpack the patched
  // tarball's inner contents into the consumer's build/packages/packdep/.
  let consumer = "build/pack_e2e_consumer"
  let _ = simplifile.delete(consumer)
  unpack_inner(
    dep_root <> "/build/packdep-1.0.0.tar",
    consumer <> "/build/packages/packdep",
  )

  write(consumer <> "/gleam.toml", "name = \"consumer\"\n")
  write(consumer <> "/consumer.graded", "check main.run : []\n")
  write(
    consumer <> "/src/main.gleam",
    "import packdep\n\npub fn run() -> Nil {\n  packdep.work()\n}\n",
  )

  // packdep is not in the catalog, so `packdep.work` resolves to [Stdout] only
  // by reading the injected spec at build/packages/packdep/packdep.graded.
  let assert Ok(results) = graded.run(consumer)
  let assert Ok(r) =
    list.find(results, fn(r) { string.ends_with(r.file, "src/main.gleam") })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "run" })
  v.actual |> should.equal(Specific(set.from_list(["Stdout"])))

  cleanup(dep_root)
  cleanup(consumer)
}

@external(erlang, "graded_pack_test_ffi", "build_tarball")
fn build_tarball(
  out_path: String,
  name: String,
  version: String,
  inner_files: List(#(String, String)),
) -> Nil

@external(erlang, "graded_pack_test_ffi", "unpack_inner")
fn unpack_inner(tarball: String, dest_dir: String) -> Nil
