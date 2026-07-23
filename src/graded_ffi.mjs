import { readFileSync } from "node:fs";
import { Error as GError } from "./gleam.mjs";

// Read all of standard input to EOF and return it as a single string.
export function read_stdin() {
  try {
    return readFileSync(0, "utf8");
  } catch (error) {
    // EOF on an empty / closed stdin reads as no input.
    if (error.code === "EOF" || error.code === "EAGAIN") {
      return "";
    }
    throw error;
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
