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
import graded/internal/annotation
import graded/internal/types.{Specific}
import simplifile
import support.{cleanup, ensure_parent, write_file}

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
  write_file(
    root <> "/gleam.toml",
    "name = \"" <> name <> "\"\nversion = \"" <> version <> "\"\n",
  )
  write_file(root <> "/" <> spec_file, spec)
  let tarball = root <> "/build/" <> name <> "-" <> version <> ".tar"
  ensure_parent(tarball)
  build_tarball(tarball, name, version, [
    #("src/" <> name <> ".gleam", "pub fn work() -> Nil {\n  Nil\n}\n"),
  ])
  tarball
}

pub fn pack_injects_and_reports_test() {
  let root = "build/pack_inject"
  let tarball =
    setup_dep(root, "dep", "1.0.0", "dep.graded", "effects dep.work : []\n")

  let assert Ok(message) = graded.pack_project(root, None)
  string.contains(message, "injected dep.graded") |> should.be_true()
  // The publish guidance names the Hex API, never `gleam publish`, and
  // shell-quotes the tarball path.
  string.contains(message, "hex.pm/api/publish") |> should.be_true()
  string.contains(message, "gleam publish") |> should.be_true()
  string.contains(message, "--data-binary @'") |> should.be_true()

  // The patched tarball unpacks with the injected spec present and intact.
  let dest = root <> "/unpacked"
  unpack_inner(tarball, dest)
  let assert Ok(spec) = simplifile.read(dest <> "/dep.graded")
  string.contains(spec, "effects dep.work : []") |> should.be_true()
  // The original source survived the round-trip.
  simplifile.is_file(dest <> "/src/dep.gleam") |> should.equal(Ok(True))

  cleanup(root)
}

// Existing entry modes survive the transform: an executable runtime asset in
// the original tarball stays executable after the spec is injected.
pub fn pack_preserves_entry_modes_test() {
  let root = "build/pack_modes"
  let _ = simplifile.delete(root)
  write_file(root <> "/gleam.toml", "name = \"dep\"\nversion = \"1.0.0\"\n")
  write_file(root <> "/dep.graded", "effects dep.work : []\n")
  let tarball = root <> "/build/dep-1.0.0.tar"
  ensure_parent(tarball)
  build_tarball_with_modes(tarball, "dep", "1.0.0", [
    #("src/dep.gleam", "pub fn work() {\n  Nil\n}\n", 0o644),
    #("priv/helper", "#!/bin/sh\n", 0o755),
  ])

  let assert Ok(_) = graded.pack_project(root, None)

  let dest = root <> "/unpacked"
  unpack_inner(tarball, dest)
  let assert Ok(info) = simplifile.file_info(dest <> "/priv/helper")
  simplifile.file_info_permissions_octal(info) |> should.equal(0o755)
  cleanup(root)
}

// Re-packing an already-patched tarball replaces the spec entry rather than
// appending a duplicate: the files list stays canonical and the fresh spec
// content wins.
pub fn pack_rerun_is_idempotent_test() {
  let root = "build/pack_rerun"
  let tarball =
    setup_dep(root, "dep", "1.0.0", "dep.graded", "effects dep.work : []\n")

  let assert Ok(_) = graded.pack_project(root, None)
  write_file(root <> "/dep.graded", "effects dep.work : [Stdout]\n")
  let assert Ok(_) = graded.pack_project(root, None)

  metadata_files(tarball)
  |> list.filter(fn(file) { file == "dep.graded" })
  |> list.length
  |> should.equal(1)

  let dest = root <> "/unpacked"
  unpack_inner(tarball, dest)
  let assert Ok(spec) = simplifile.read(dest <> "/dep.graded")
  spec |> should.equal("effects dep.work : [Stdout]\n")
  cleanup(root)
}

// The scratch paths are invocation-owned: a pre-existing user path with the
// same deterministic name is an error, never a recursive delete.
pub fn pack_scratch_collision_is_an_error_test() {
  let root = "build/pack_scratch"
  let tarball =
    setup_dep(root, "dep", "1.0.0", "dep.graded", "effects dep.work : []\n")

  // A user directory at the `.packing` temp path survives the failed pack.
  let packing_marker = tarball <> ".packing"
  write_file(packing_marker <> "/keep.txt", "precious\n")
  let assert Error(_) = graded.pack_project(root, None)
  simplifile.read(packing_marker <> "/keep.txt")
  |> should.equal(Ok("precious\n"))
  let assert Ok(Nil) = simplifile.delete(packing_marker)

  // A user directory at the FFI work-directory path gets the same guarantee,
  // and the failed run cleans up its own temp file.
  let work_marker = tarball <> ".packing.work"
  write_file(work_marker <> "/keep.txt", "precious\n")
  let assert Error(_) = graded.pack_project(root, None)
  simplifile.read(work_marker <> "/keep.txt") |> should.equal(Ok("precious\n"))
  simplifile.is_file(tarball <> ".packing") |> should.equal(Ok(False))
  let assert Ok(Nil) = simplifile.delete(work_marker)

  // A dangling symlink at the temp path is rejected atomically, not followed:
  // the pack fails and nothing is written through to the symlink's target.
  let assert Ok(Nil) =
    simplifile.create_symlink("dangling_target", packing_marker)
  let assert Error(_) = graded.pack_project(root, None)
  simplifile.is_file(root <> "/build/dangling_target")
  |> should.equal(Ok(False))

  cleanup(root)
}

pub fn pack_default_tarball_identity_mismatch_test() {
  let root = "build/pack_mismatch"
  let _ = simplifile.delete(root)
  // Project declares version 2.0.0, but only a 1.0.0 tarball exists — the
  // default path build/dep-2.0.0.tar is missing, so pack errors rather than
  // patching the wrong archive.
  write_file(root <> "/gleam.toml", "name = \"dep\"\nversion = \"2.0.0\"\n")
  write_file(root <> "/dep.graded", "effects dep.work : []\n")
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
  write_file(
    root <> "/gleam.toml",
    "name = \"dep\"\nversion = \"1.0.0\"\n\n[tools.graded]\nspec_file = \"effects/api.graded\"\n",
  )
  write_file(root <> "/effects/api.graded", "effects dep.work : []\n")
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
  write_file(
    root <> "/gleam.toml",
    "name = \"dep\"\n\n[tools.graded]\nspec_file = \"/etc/dep.graded\"\n",
  )
  let assert Error(_) = graded.pack_project(root, Some("unused.tar"))
  cleanup(root)
}

pub fn pack_rejects_escaping_spec_path_test() {
  let root = "build/pack_escape"
  let _ = simplifile.delete(root)
  write_file(
    root <> "/gleam.toml",
    "name = \"dep\"\n\n[tools.graded]\nspec_file = \"../escape.graded\"\n",
  )
  let assert Error(_) = graded.pack_project(root, Some("unused.tar"))
  cleanup(root)
}

// A spec the parser rejects never reaches the archive
//
// Every consumer's loader parses a dependency's spec whole: one line it rejects
// drops the file's entire metadata. So the spec has to parse before `pack`
// opens the tarball, or the package publishes annotations nobody reads.

pub fn pack_refuses_a_spec_that_does_not_parse_test() {
  let root = "build/pack_unparseable"
  let tarball =
    setup_dep(
      root,
      "dep",
      "1.0.0",
      "dep.graded",
      "effects dep.work : []\nreturns dep.make : [Stdout]\n",
    )
  let assert Ok(before) = simplifile.read_bits(tarball)

  // The standard parse error, naming the file and the retired line.
  let assert Error(graded.GradedParseError(path, cause)) =
    graded.pack_project(root, None)
  string.ends_with(path, "dep.graded") |> should.be_true()
  cause
  |> should.equal(annotation.RetiredSpelling(
    2,
    "returns dep.make : [Stdout]",
    annotation.RetiredReturns,
  ))

  // The tarball is untouched and the run left no scratch path behind: the spec
  // is refused before either is opened.
  simplifile.read_bits(tarball) |> should.equal(Ok(before))
  simplifile.is_file(tarball <> ".packing") |> should.equal(Ok(False))
  metadata_files(tarball)
  |> list.contains("dep.graded")
  |> should.be_false()

  cleanup(root)
}

pub fn pack_without_a_spec_names_infer_test() {
  let root = "build/pack_no_spec"
  let _ = simplifile.delete(root)
  write_file(root <> "/gleam.toml", "name = \"dep\"\nversion = \"1.0.0\"\n")
  let tarball = root <> "/build/dep-1.0.0.tar"
  ensure_parent(tarball)
  build_tarball(tarball, "dep", "1.0.0", [
    #("src/dep.gleam", "pub fn work() {\n  Nil\n}\n"),
  ])

  let assert Error(graded.PackError(message)) = graded.pack_project(root, None)
  string.contains(message, "no spec file at") |> should.be_true()
  string.contains(message, "run `graded infer` first") |> should.be_true()
  cleanup(root)
}

pub fn pack_reports_an_unreadable_spec_as_a_read_error_test() {
  // Not "no spec file … run `graded infer` first": the file is right there, and
  // inference does not fix a permissions failure.
  let root = "build/pack_unreadable"
  let _ =
    setup_dep(root, "dep", "1.0.0", "dep.graded", "effects dep.work : []\n")
  let spec = root <> "/dep.graded"
  let assert Ok(Nil) = simplifile.set_permissions_octal(spec, 0o000)

  // A process that reads the file anyway — root, most often — proves nothing
  // here, so the assertion runs only where the mode is honoured.
  case simplifile.read(spec) {
    Error(_) -> {
      let assert Error(graded.FileReadError(path, _cause)) =
        graded.pack_project(root, None)
      path |> should.equal(spec)
    }
    Ok(_) -> Nil
  }

  let assert Ok(Nil) = simplifile.set_permissions_octal(spec, 0o644)
  cleanup(root)
}

// End-to-end: a consumer resolves a dependency call through the injected spec.
pub fn pack_consumer_resolves_injected_spec_test() {
  let dep_root = "build/pack_e2e_dep"
  let tarball =
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
  unpack_inner(tarball, consumer <> "/build/packages/packdep")

  write_file(consumer <> "/gleam.toml", "name = \"consumer\"\n")
  write_file(consumer <> "/consumer.graded", "check main.run : []\n")
  write_file(
    consumer <> "/src/main.gleam",
    "import packdep\n\npub fn run() -> Nil {\n  packdep.work()\n}\n",
  )

  // packdep is not in the catalog, so `packdep.work` resolves to [Stdout] only
  // by reading the injected spec at build/packages/packdep/packdep.graded.
  let assert Ok(results) = graded.run(consumer)
  let assert Ok(r) =
    list.find(results, fn(r) { string.ends_with(r.file, "src/main.gleam") })
  let assert Ok(v) = list.find(r.violations, fn(v) { v.function == "run" })
  v.explanation.actual |> should.equal(Specific(set.from_list(["Stdout"])))

  cleanup(dep_root)
  cleanup(consumer)
}

// An archive graded did not build is untrusted input
//
// The rebuild re-adds every inner member by `filename:join(InnerDir, Name)`,
// and an absolute Name wins that join outright — so a crafted archive makes
// pack read a host file and embed it in the tarball whose success message tells
// the user to publish. The names are guarded before anything is extracted.

// A member for `build_tarball_with_raw_names`: `Regular` stores its name
// verbatim, `Symlink` stages a real link so the member is genuinely typed.
type Member {
  Regular(name: String, content: String)
  Symlink(name: String, target: String)
}

// A project whose default tarball is built from `members`, with a spec ready to
// inject. Returns the tarball path.
fn setup_crafted(root: String, members: List(Member)) -> String {
  let _ = simplifile.delete(root)
  write_file(root <> "/gleam.toml", "name = \"dep\"\nversion = \"1.0.0\"\n")
  write_file(root <> "/dep.graded", "effects dep.work : []\n")
  let tarball = root <> "/build/dep-1.0.0.tar"
  ensure_parent(tarball)
  build_tarball_with_raw_names(tarball, "dep", "1.0.0", members)
  tarball
}

pub fn pack_rejects_an_absolute_inner_entry_test() {
  let root = "build/pack_absolute_entry"
  // The decoy is a file this test creates under its own tree — the exploit
  // needs an absolute path, never a real system one.
  let assert Ok(cwd) = simplifile.current_directory()
  let decoy = cwd <> "/" <> root <> "/decoy.txt"

  let tarball =
    setup_crafted(root, [
      Regular("src/dep.gleam", "pub fn work() {\n  Nil\n}\n"),
      // The crafted member: its stored bytes are a placeholder, but the name
      // names the decoy, so an unguarded rebuild reads the decoy instead.
      Regular(decoy, "placeholder"),
    ])
  // Written after the setup clears `root`, so the name in the archive resolves
  // to a real host file at pack time — which is the whole of the exploit.
  write_file(decoy, "HOST-SECRET-DECOY\n")
  let assert Ok(before) = simplifile.read_bits(tarball)

  let assert Error(graded.PackError(message)) = graded.pack_project(root, None)
  string.contains(message, decoy) |> should.be_true()
  string.contains(message, "unsafe tar entry name") |> should.be_true()

  // There is no output tarball to inspect on a rejection, so assert on what
  // remains: the input is untouched, both scratch paths are gone, and the
  // decoy's bytes never moved.
  simplifile.read_bits(tarball) |> should.equal(Ok(before))
  simplifile.is_file(tarball <> ".packing") |> should.equal(Ok(False))
  simplifile.is_directory(tarball <> ".packing.work") |> should.equal(Ok(False))
  simplifile.read(decoy) |> should.equal(Ok("HOST-SECRET-DECOY\n"))

  cleanup(root)
}

// The `..` half of the rule is graded's, not `erl_tar`'s. Extraction rejects an
// escaping member on its own (`unsafe_path`), but only once the archive is
// already being unpacked; this pins the guard ahead of extraction, where the
// diagnostic is graded's own.
pub fn pack_rejects_an_escaping_inner_entry_test() {
  let root = "build/pack_escaping_entry"
  let tarball =
    setup_crafted(root, [
      Regular("src/dep.gleam", "pub fn work() {\n  Nil\n}\n"),
      Regular("../escaped.txt", "x"),
    ])
  let assert Ok(before) = simplifile.read_bits(tarball)

  let assert Error(graded.PackError(message)) = graded.pack_project(root, None)
  string.contains(message, "../escaped.txt") |> should.be_true()
  string.contains(message, "unsafe tar entry name") |> should.be_true()

  simplifile.read_bits(tarball) |> should.equal(Ok(before))
  simplifile.is_directory(tarball <> ".packing.work") |> should.equal(Ok(False))
  cleanup(root)
}

// A non-regular member is refused by its type, and the message says which type.
// The rebuild carries regular members only, so a symlink was previously dropped
// from the output and the run failed on the files-list mismatch, naming
// nothing. graded cannot see a link's target at all — `erl_tar:table/2` leaves
// it out of the tuple — which is why the member kind is what gets refused.
pub fn pack_rejects_a_non_regular_inner_entry_test() {
  let root = "build/pack_symlink_entry"
  let tarball =
    setup_crafted(root, [
      Regular("src/dep.gleam", "pub fn work() {\n  Nil\n}\n"),
      Symlink("link.txt", "dangling_target"),
    ])

  let assert Error(graded.PackError(message)) = graded.pack_project(root, None)
  string.contains(message, "link.txt") |> should.be_true()
  string.contains(message, "symlink") |> should.be_true()

  simplifile.is_directory(tarball <> ".packing.work") |> should.equal(Ok(False))
  cleanup(root)
}

// The function that certifies an archive as internally consistent refuses to
// certify one carrying a name graded would never write.
pub fn verify_tarball_rejects_an_unsafe_entry_test() {
  let root = "build/pack_verify_unsafe"
  let tarball =
    setup_crafted(root, [
      Regular("dep.graded", "effects dep.work : []\n"),
      Regular("/etc/dep.graded", "placeholder"),
    ])

  let assert Error(message) = verify_tarball(tarball, "dep.graded")
  string.contains(message, "/etc/dep.graded") |> should.be_true()
  string.contains(message, "unsafe tar entry name") |> should.be_true()
  cleanup(root)
}

// A malformed archive says what is wrong with it
//
// Every one of these used to badmatch or reach a term as `undefined`, and
// surface as an Erlang tuple through `format_reason`'s `~p`.

// A project ready to pack, whose tarball is written from `members` verbatim —
// no VERSION/CHECKSUM quartet unless the members say so. Returns the tarball.
fn setup_malformed(root: String, members: List(#(String, String))) -> String {
  let _ = simplifile.delete(root)
  write_file(root <> "/gleam.toml", "name = \"dep\"\nversion = \"1.0.0\"\n")
  write_file(root <> "/dep.graded", "effects dep.work : []\n")
  let tarball = root <> "/build/dep-1.0.0.tar"
  ensure_parent(tarball)
  build_outer_tarball(tarball, members)
  tarball
}

// A metadata.config good enough to name the package, for the archives whose
// defect is somewhere other than the metadata.
const good_metadata = "{<<\"name\">>, <<\"dep\"/utf8>>}.
{<<\"version\">>, <<\"1.0.0\"/utf8>>}.
{<<\"files\">>, [
  <<\"src/dep.gleam\"/utf8>>]}.
"

fn pack_error(root: String) -> String {
  let assert Error(graded.PackError(message)) = graded.pack_project(root, None)
  message
}

pub fn pack_names_a_corrupt_outer_tar_test() {
  let root = "build/pack_corrupt_outer"
  let _ = simplifile.delete(root)
  write_file(root <> "/gleam.toml", "name = \"dep\"\nversion = \"1.0.0\"\n")
  write_file(root <> "/dep.graded", "effects dep.work : []\n")
  write_file(root <> "/build/dep-1.0.0.tar", "this is not a tar file\n")

  let message = pack_error(root)
  string.contains(message, "as a hex tarball") |> should.be_true()
  cleanup(root)
}

// Also the proof that `read_package_identity` surfaces a thrown message as
// itself: its catch was `_:Reason` only, so a clean message rendered as
// `{graded_error,<<"...">>}` through `format_reason`'s `~p`.
pub fn pack_names_a_missing_metadata_member_test() {
  let root = "build/pack_no_metadata"
  let _ = setup_malformed(root, [#("VERSION", "3")])

  let message = pack_error(root)
  string.contains(message, "hex tarball has no metadata.config member")
  |> should.be_true()
  string.contains(message, "graded_error") |> should.be_false()
  cleanup(root)
}

pub fn pack_names_metadata_that_does_not_scan_test() {
  let root = "build/pack_metadata_scan"
  let _ =
    setup_malformed(root, [
      #("VERSION", "3"),
      #("metadata.config", "{<<\"name\">>, \"unterminated"),
    ])

  let message = pack_error(root)
  string.contains(message, "does not scan as Erlang terms") |> should.be_true()
  cleanup(root)
}

pub fn pack_names_metadata_with_no_terminating_dot_test() {
  let root = "build/pack_metadata_dot"
  let _ =
    setup_malformed(root, [
      #("VERSION", "3"),
      #("metadata.config", "{<<\"name\">>, <<\"dep\"/utf8>>}"),
    ])

  let message = pack_error(root)
  string.contains(message, "no terminating `.`") |> should.be_true()
  cleanup(root)
}

pub fn pack_names_metadata_that_does_not_parse_test() {
  let root = "build/pack_metadata_parse"
  let _ =
    setup_malformed(root, [#("VERSION", "3"), #("metadata.config", "{a, }.")])

  let message = pack_error(root)
  string.contains(message, "does not parse") |> should.be_true()
  cleanup(root)
}

pub fn pack_names_a_truncated_contents_member_test() {
  let root = "build/pack_truncated_contents"
  let _ =
    setup_malformed(root, [
      #("VERSION", "3"),
      #("metadata.config", good_metadata),
      #("contents.tar.gz", "not a gzip stream at all"),
      #("CHECKSUM", "00"),
    ])

  let message = pack_error(root)
  string.contains(message, "not a readable gzip stream") |> should.be_true()
  cleanup(root)
}

@external(erlang, "graded_pack_test_ffi", "build_tarball")
fn build_tarball(
  out_path: String,
  name: String,
  version: String,
  inner_files: List(#(String, String)),
) -> Nil

@external(erlang, "graded_pack_test_ffi", "build_tarball_with_modes")
fn build_tarball_with_modes(
  out_path: String,
  name: String,
  version: String,
  inner_files: List(#(String, String, Int)),
) -> Nil

@external(erlang, "graded_pack_test_ffi", "build_tarball_with_raw_names")
fn build_tarball_with_raw_names(
  out_path: String,
  name: String,
  version: String,
  members: List(Member),
) -> Nil

@external(erlang, "graded_pack_test_ffi", "build_outer_tarball")
fn build_outer_tarball(
  out_path: String,
  members: List(#(String, String)),
) -> Nil

@external(erlang, "graded_pack_test_ffi", "unpack_inner")
fn unpack_inner(tarball: String, dest_dir: String) -> Nil

// Called directly: `pack` reaches it only through a tarball it just wrote, and
// the guard under test is about archives it did not.
@external(erlang, "graded_pack_ffi", "verify_tarball")
fn verify_tarball(tarball: String, entry_name: String) -> Result(Nil, String)

@external(erlang, "graded_pack_test_ffi", "metadata_files")
fn metadata_files(tarball: String) -> List(String)
