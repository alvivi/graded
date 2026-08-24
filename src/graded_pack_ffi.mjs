import { Error as GError } from "./gleam.mjs";

// `graded pack` rewrites a hex tarball via Erlang's erl_tar/zlib/crypto and is
// only supported on the BEAM target. The JavaScript stubs keep the module
// compiling for `--target javascript` and fail gracefully if ever called.
const unsupported = "graded pack is only supported on the Erlang target";

export function inject_spec(_in_tar, _spec, _entry_name, _out_tar) {
  return new GError(unsupported);
}

export function verify_tarball(_tar, _entry_name) {
  return new GError(unsupported);
}

export function read_package_identity(_tar) {
  return new GError(unsupported);
}
