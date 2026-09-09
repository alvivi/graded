import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { Ok, Error as GError } from "./gleam.mjs";

// Read all of standard input to EOF, as `Ok(string)` or `Error(reason)`. The
// reason is worded here, in the sentence the Erlang half words it with, so both
// targets print the same thing for the same failure.
export function read_stdin() {
  try {
    return new Ok(readFileSync(0, "utf8"));
  } catch (error) {
    // EOF on an empty / closed stdin reads as no input.
    if (error.code === "EOF" || error.code === "EAGAIN") {
      return new Ok("");
    }
    return new GError(
      "stdin could not be read: " + (error.code ?? error.message),
    );
  }
}

export function halt(code) {
  process.exit(code);
  return undefined;
}

// graded's bundled catalog is located via the Erlang application on the BEAM
// target; on JavaScript the install location isn't resolved, so callers fall
// back to the working-directory layouts.
export function priv_directory() {
  return new GError(undefined);
}

// No application metadata exists here, so no loaded package's version is
// observed. `graded coverage` prints "not observed", which is the honest answer.
export function loaded_version(_app) {
  return new GError(undefined);
}

// The Erlang/OTP release is not applicable off the BEAM.
export function otp_release() {
  return new GError(undefined);
}

// What `gleam --version` wrote. The only subprocess graded runs, and only
// `graded coverage` runs it; the caller reads the format.
export function compiler_output() {
  try {
    return new Ok(
      execSync("gleam --version", {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      }),
    );
  } catch (_error) {
    return new GError(undefined);
  }
}
