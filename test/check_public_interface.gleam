// Assert graded's public API names no `graded/internal` type.
//
// A `pub fn` name allowlist cannot see an allowed function acquiring an
// internal parameter or return type, and the package's own build happily
// imports its own internals — so this inspects what a *consumer* sees: the
// package interface the compiler exports, walked for every type reference the
// `graded` module makes.
//
// Reading the compiler's own answer is the point. Deriving it from source
// instead would mean re-implementing `@internal`, import-alias resolution,
// unqualified imports and type-alias expansion, and a bug in any of those
// makes this gate pass while the leak ships.
//
// Lives under `test/` so it never reaches the published package. Run it with
// `gleam run -m check_public_interface`.

import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

const internal_prefix = "graded/internal"

const interface_path = "build/.public_interface.json"

pub fn main() -> Nil {
  let output = shell("gleam export package-interface --out " <> interface_path)
  case read_interface() {
    Error(reason) -> {
      io.println_error(
        "could not read the exported package interface: " <> reason,
      )
      io.println_error(string.trim(output))
      halt(1)
    }
    Ok(interface) ->
      case leaks(interface) {
        [] ->
          io.println(
            "graded's public API names no " <> internal_prefix <> " type",
          )
        leaks -> {
          io.println_error(
            "graded's public API names "
            <> int.to_string(list.length(leaks))
            <> " internal type(s):",
          )
          list.each(leaks, fn(leak) { io.println_error("  " <> leak) })
          halt(1)
        }
      }
  }
}

// Every type reference the `graded` module makes that resolves under
// `graded/internal`, as `path: module` lines, sorted and deduplicated.
fn leaks(interface: Value) -> List(String) {
  let graded =
    interface
    |> field("modules")
    |> result.try(field(_, "graded"))
  case graded {
    Error(Nil) -> ["no `graded` module in the exported package interface"]
    Ok(module) ->
      type_references(module, "graded")
      |> list.filter(fn(reference) {
        string.starts_with(reference.1, internal_prefix)
      })
      |> list.map(fn(reference) { reference.0 <> ": " <> reference.1 })
      |> list.unique
      |> list.sort(string.compare)
  }
}

// `#(path, module)` for every named type reference under `value`. A JSON
// object naming a `kind` of `named` is one type reference; `module` says where
// that type is defined. Documentation is prose rather than an object, so it is
// never mistaken for one.
fn type_references(value: Value, path: String) -> List(#(String, String)) {
  case value {
    Object(entries) -> {
      let here = case dict.get(entries, "kind"), dict.get(entries, "module") {
        Ok(String("named")), Ok(String(module)) -> [#(path, module)]
        _, _ -> []
      }
      dict.to_list(entries)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> list.flat_map(fn(entry) {
        type_references(entry.1, path <> "." <> entry.0)
      })
      |> list.append(here, _)
    }
    Array(items) ->
      list.index_map(items, fn(item, index) {
        type_references(item, path <> "[" <> int.to_string(index) <> "]")
      })
      |> list.flatten
    String(_) | Other -> []
  }
}

// JSON as read rather than as modelled: the interface schema is the
// compiler's, it is versioned, and this only ever asks where a type came from.
// Decoding the whole shape would couple the gate to a schema it does not care
// about.
type Value {
  Object(Dict(String, Value))
  Array(List(Value))
  String(String)
  Other
}

fn value_decoder() -> Decoder(Value) {
  use <- decode.recursive
  decode.one_of(
    decode.dict(decode.string, value_decoder()) |> decode.map(Object),
    [
      decode.list(value_decoder()) |> decode.map(Array),
      decode.string |> decode.map(String),
      decode.success(Other),
    ],
  )
}

fn read_interface() -> Result(Value, String) {
  use source <- result.try(
    simplifile.read(interface_path)
    |> result.map_error(simplifile.describe_error),
  )
  json.parse(source, value_decoder())
  |> result.replace_error("the interface is not readable JSON")
}

fn field(value: Value, name: String) -> Result(Value, Nil) {
  case value {
    Object(entries) -> dict.get(entries, name)
    _ -> Error(Nil)
  }
}

@external(erlang, "check_interface_ffi", "run")
fn shell(command: String) -> String

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
