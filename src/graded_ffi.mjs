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

// The version is read from the OTP application on the BEAM target; on JavaScript
// the install metadata isn't resolved.
export function version() {
  return "unknown";
}
