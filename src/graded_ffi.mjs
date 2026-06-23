import { readFileSync } from "node:fs";

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
