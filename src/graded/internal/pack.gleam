// Hex tarball patching for `graded pack`.
//
// Everything the command does to an archive: pick the tarball to patch, check
// the configured spec path is a safe archive-relative entry, inject the spec
// through a temporary file, verify the result, and put it in place. The
// command itself stays in `graded`, which reads the config and the spec and
// renders the problems here into its own error type.

import filepath
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import graded/internal/config
import simplifile

// What can go wrong patching an archive. Rendered by the caller: an internal
// module cannot name `graded`'s error type without a cycle, and every variant
// here is one of that type's cases.
pub type PackProblem {
  // The configured `spec_file` is absolute or escapes the package root, so it
  // names no safe archive-relative entry.
  UnsafeSpecEntry(entry: String)
  // No default tarball path can be derived: `gleam.toml` states no `version`.
  MissingVersion(gleam_toml: String)
  // The default tarball is there and holds another package or version, so
  // patching it would silently touch the wrong archive.
  WrongTarball(
    path: String,
    found: String,
    found_version: String,
    expected: String,
    expected_version: String,
  )
  // The default tarball could not be read at all — usually not exported yet.
  MissingDefaultTarball(path: String, message: String)
  // The transform itself failed; the temporary file is already removed.
  InjectionFailed(tarball: String, message: String)
  // The patched archive is not internally consistent, or lacks the entry.
  VerificationFailed(message: String)
  // The verified archive could not be moved into place. It is the run's
  // finished product, so it stays at `temp` for the user to move by hand.
  ReplaceFailed(path: String, temp: String, cause: simplifile.FileError)
}

// Patch `tarball` so it carries `spec` at the archive-relative `entry_name`,
// returning the recomputed inner checksum.
//
// Inject into a temp, verify, then replace the tarball in place, so a failed
// transform never leaves a corrupt archive behind. `inject_spec` creates the
// temp itself, with an atomic exclusive create it then writes the archive
// through — any existing path (a symlink included) is an error — and removes
// it again on failure, so only what that call created is ever deleted.
pub fn patch_tarball(
  tarball: String,
  spec: String,
  entry_name: String,
) -> Result(String, PackProblem) {
  let temp = tarball <> ".packing"
  use checksum <- result.try(
    inject_spec(tarball, spec, entry_name, temp)
    |> result.map_error(InjectionFailed(tarball, _)),
  )
  use _ <- result.try(
    verify_tarball(temp, entry_name)
    |> result.map_error(fn(message) {
      let _deleted = simplifile.delete(temp)
      VerificationFailed(message)
    }),
  )
  // A rename failure is the one path that keeps the temp: by here the archive
  // is written and verified, so it is the run's finished product and deleting
  // it would throw away the only good copy. It has to be moved or removed by
  // hand — the next run says so, refusing to write over a path it did not
  // create.
  use _ <- result.try(
    simplifile.rename(temp, tarball)
    |> result.map_error(ReplaceFailed(tarball, temp, _)),
  )
  Ok(checksum)
}

// Resolve the tarball to patch: `build/<name>-<version>.tar`, the one archive
// the command touches. It is opened and its identity checked against the
// project's name and version, so `pack` can't silently patch the wrong
// archive.
pub fn resolve_tarball(
  project_root: String,
  gleam_toml: String,
  cfg: config.GradedConfig,
) -> Result(String, PackProblem) {
  let package_name = cfg.package_name
  use version <- result.try(option.to_result(
    cfg.version,
    MissingVersion(gleam_toml),
  ))
  let path =
    filepath.join(
      project_root,
      "build/" <> package_name <> "-" <> version <> ".tar",
    )
  use #(name, tar_version) <- result.try(
    read_package_identity(path)
    |> result.map_error(MissingDefaultTarball(path, _)),
  )
  case name == package_name && tar_version == version {
    True -> Ok(path)
    False ->
      Error(WrongTarball(
        path:,
        found: name,
        found_version: tar_version,
        expected: package_name,
        expected_version: version,
      ))
  }
}

// Reject an absolute path or one that escapes the package root: the spec must
// land at a safe archive-relative location inside the package.
//
// Advisory, not the boundary. `graded_pack_ffi` applies the authoritative rule
// to this entry as well as to the archive's own names, on the platform whose
// `filename:join` semantics are what the rule defends. The two are deliberately
// not identical: this one tests a leading `/`, which is Unix-only, and Gleam
// has no platform-aware path predicate to test instead — `filepath.is_absolute`
// is the same `starts_with("/")` under a `windows support` TODO. What this buys
// is an earlier, better-worded rejection of a value the package author wrote in
// their own gleam.toml. Do not weaken the Erlang guard to match it.
pub fn validate_archive_entry(entry: String) -> Result(Nil, PackProblem) {
  let escapes = list.contains(filepath.split(entry), "..")
  case string.starts_with(entry, "/") || escapes {
    True -> Error(UnsafeSpecEntry(entry))
    False -> Ok(Nil)
  }
}

pub fn success_message(
  tarball: String,
  entry: String,
  checksum: String,
) -> String {
  "graded: injected "
  <> entry
  <> " into "
  <> tarball
  <> "\n  checksum "
  <> checksum
  <> "\n\nPublish this tarball with the Hex publish API — NOT `gleam publish`,\n"
  <> "which rebuilds the tarball and drops the injected spec:\n\n"
  <> "  curl -X POST https://hex.pm/api/publish \\\n"
  <> "    -H \"authorization: $HEX_API_KEY\" \\\n"
  <> "    -H \"content-type: application/octet-stream\" \\\n"
  <> "    --data-binary @"
  <> shell_quote(tarball)
  <> "\n\nDocumentation still publishes via `gleam docs publish`."
}

// Quote a path for a POSIX shell: single-quoted, with embedded single quotes
// escaped as `'\''`, so the printed publish command survives paths with
// whitespace or shell metacharacters.
fn shell_quote(path: String) -> String {
  "'" <> string.replace(path, "'", "'\\''") <> "'"
}

// Inject a `.graded` spec into a hex tarball at `in_tar`, writing the patched
// archive to `out_tar` with `spec` placed at the archive-relative `entry_name`.
// Returns the recomputed inner checksum, or an error message.
// nolint: stringly_typed_error -- opaque erl_tar diagnostic, wrapped in PackProblem
@external(erlang, "graded_pack_ffi", "inject_spec")
@external(javascript, "../../graded_pack_ffi.mjs", "inject_spec")
fn inject_spec(
  in_tar: String,
  spec: String,
  entry_name: String,
  out_tar: String,
) -> Result(String, String)

// Assert a written tarball is internally consistent (checksum + files list) and
// carries `entry_name`.
// nolint: stringly_typed_error -- opaque erl_tar diagnostic, wrapped in PackProblem
@external(erlang, "graded_pack_ffi", "verify_tarball")
@external(javascript, "../../graded_pack_ffi.mjs", "verify_tarball")
fn verify_tarball(tar: String, entry_name: String) -> Result(Nil, String)

// Read `#(name, version)` from a hex tarball's `metadata.config`.
// nolint: stringly_typed_error -- opaque erl_tar diagnostic, wrapped in PackProblem
@external(erlang, "graded_pack_ffi", "read_package_identity")
@external(javascript, "../../graded_pack_ffi.mjs", "read_package_identity")
fn read_package_identity(tar: String) -> Result(#(String, String), String)
