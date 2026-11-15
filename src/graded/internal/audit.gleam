// A bundled catalog file's audit record: the `.audit` file beside it, read
// only by graded and never shipped in a user's spec.
//
// The record says which names a review of the package's source covered, for
// which installed versions, and what the review found: each reviewed name's
// full contract — the line the catalog publishes for it — the foreign types
// that hold nothing but their type parameters' values, what the reviewed
// constants carry, and the functions whose result carries everything their
// arguments carry and their callbacks cost and return. A name the review did
// not cover is listed with the reason, and reads as any written line does.
//
//   covers 1.0.0 to 1.0.3, 1.0.5
//   contract gleam/list.each(list: [list], f: [f]) : [f] where runs : [], relay : f(list)
//   reviewed gleam/io.println
//   container gleam/dict.Dict
//   constant gleam/dynamic/decode.int : []
//   container_result gleam/dynamic/decode.list
//   unreviewed gleam/io.debug : not in the reviewed versions
//
// Every entry but `unreviewed` belongs to the `covers` line above it: a list
// of exact versions and ranges, each range inclusive at both ends.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded/internal/annotation
import graded/internal/effect_term
import graded/internal/types.{type EffectTerm, type QualifiedName, QualifiedName}

pub type Version =
  #(Int, Int, Int)

// The installed versions a review covers: exact versions and ranges, each
// range inclusive at both ends.
pub type Coverage {
  Coverage(ranges: List(#(Version, Version)))
}

pub type AuditEntry {
  // A reviewed name's contract, as the catalog publishes it.
  ReviewedContract(assume: types.AssumeAnnotation, covers: Coverage)
  // A reviewed name whose catalog line states no contract of its own.
  ReviewedName(name: QualifiedName, covers: Coverage)
  // A foreign type holding nothing but its type parameters' values.
  ContainerType(module: String, name: String, covers: Coverage)
  // What a reviewed constant carries.
  ConstantCarries(name: QualifiedName, carried: EffectTerm, covers: Coverage)
  // A function whose result carries every argument's carried latent and every
  // callback's cost and result.
  ContainerResult(name: QualifiedName, covers: Coverage)
  // A name the review did not cover, and why.
  Unreviewed(path: String, reason: String)
}

pub type AuditFile {
  AuditFile(entries: List(AuditEntry))
}

// A line the reader could not read: its number and its text.
pub type AuditError {
  AuditError(line_number: Int, content: String)
}

pub fn parse(input: String) -> Result(AuditFile, AuditError) {
  input
  |> string.split("\n")
  |> list.index_map(fn(line, index) { #(index + 1, line) })
  |> list.try_fold(#([], None), fn(state, numbered) {
    let #(entries, covers) = state
    let #(line_number, line) = numbered
    let refuse = AuditError(line_number:, content: line)
    case string.trim(line) {
      "" -> Ok(state)
      "//" <> _ -> Ok(state)
      "covers " <> range ->
        parse_coverage(range)
        |> result.map(fn(coverage) { #(entries, Some(coverage)) })
        |> result.replace_error(refuse)
      "unreviewed " <> rest ->
        case string.split_once(rest, " : ") {
          Ok(#(path, reason)) if reason != "" ->
            Ok(#(
              [Unreviewed(path: string.trim(path), reason:), ..entries],
              covers,
            ))
          _ -> Error(refuse)
        }
      trimmed ->
        case covers {
          None -> Error(refuse)
          Some(coverage) ->
            parse_covered(trimmed, coverage)
            |> result.map(fn(entry) { #([entry, ..entries], covers) })
            |> result.replace_error(refuse)
        }
    }
  })
  |> result.map(fn(state) { AuditFile(entries: list.reverse(state.0)) })
}

fn parse_coverage(text: String) -> Result(Coverage, Nil) {
  string.split(text, ",")
  |> list.try_map(fn(part) {
    case string.split_once(part, " to ") {
      Ok(#(low, high)) -> {
        use low <- result.try(parse_version(string.trim(low)))
        use high <- result.map(parse_version(string.trim(high)))
        #(low, high)
      }
      Error(Nil) ->
        parse_version(string.trim(part))
        |> result.map(fn(version) { #(version, version) })
    }
  })
  |> result.map(Coverage)
}

fn parse_version(text: String) -> Result(Version, Nil) {
  case string.split(text, ".") |> list.try_map(int.parse) {
    Ok([major, minor, patch]) -> Ok(#(major, minor, patch))
    _ -> Error(Nil)
  }
}

fn parse_covered(line: String, coverage: Coverage) -> Result(AuditEntry, Nil) {
  case line {
    "contract " <> statement -> {
      use file <- result.try(
        annotation.parse_file("assume " <> statement)
        |> result.replace_error(Nil),
      )
      case file.lines {
        [types.AssumeLine(assume, [])] ->
          case assume.target {
            types.FunctionAssume(_) ->
              Ok(ReviewedContract(assume:, covers: coverage))
            types.ModuleAssume -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    }
    "reviewed " <> path -> {
      use #(module, function) <- result.map(split_path(path))
      ReviewedName(name: QualifiedName(module:, function:), covers: coverage)
    }
    "container " <> path -> {
      use #(module, name) <- result.map(split_path(path))
      ContainerType(module:, name:, covers: coverage)
    }
    "constant " <> rest -> {
      use #(path, term) <- result.try(string.split_once(rest, " : "))
      use #(module, function) <- result.try(split_path(path))
      use file <- result.try(
        annotation.parse_file(
          "assume " <> module <> "." <> function <> " : " <> term,
        )
        |> result.replace_error(Nil),
      )
      case file.lines {
        [
          types.AssumeLine(
            types.AssumeAnnotation(effects: Some(carried), ..),
            [],
          ),
        ] ->
          Ok(ConstantCarries(
            name: QualifiedName(module:, function:),
            carried: effect_term.normalize(carried),
            covers: coverage,
          ))
        _ -> Error(Nil)
      }
    }
    "container_result " <> path -> {
      use #(module, function) <- result.map(split_path(path))
      ContainerResult(name: QualifiedName(module:, function:), covers: coverage)
    }
    _ -> Error(Nil)
  }
}

// `module/path.Name` at its last dot.
fn split_path(path: String) -> Result(#(String, String), Nil) {
  let trimmed = string.trim(path)
  use <- bool.guard(when: string.contains(trimmed, " "), return: Error(Nil))
  case string.split(trimmed, ".") |> list.reverse {
    [name, ..module] if module != [] && name != "" ->
      Ok(#(string.join(list.reverse(module), "."), name))
    _ -> Error(Nil)
  }
}

// What the bundled catalog's audit records, already narrowed to the catalog
// files and installed versions it covers: the names whose catalog line was
// reviewed, the foreign types that hold nothing but their type parameters'
// values, what the reviewed constants carry, and the functions whose result
// carries everything their arguments carry and their callbacks cost and
// return.
pub type CatalogAudit {
  CatalogAudit(
    reviewed: Set(QualifiedName),
    containers: Set(#(String, String)),
    constants: Dict(QualifiedName, EffectTerm),
    container_results: Set(QualifiedName),
  )
}

pub fn empty() -> CatalogAudit {
  CatalogAudit(
    reviewed: set.new(),
    containers: set.new(),
    constants: dict.new(),
    container_results: set.new(),
  )
}

// Two records together: every set unioned, and `later`'s constants over
// `earlier`'s.
pub fn merge(earlier: CatalogAudit, later: CatalogAudit) -> CatalogAudit {
  CatalogAudit(
    reviewed: set.union(earlier.reviewed, later.reviewed),
    containers: set.union(earlier.containers, later.containers),
    constants: dict.merge(earlier.constants, later.constants),
    container_results: set.union(
      earlier.container_results,
      later.container_results,
    ),
  )
}

// What an audit record says for one installed version: the entries whose
// coverage holds it. Of two constant entries for one name, the first holds.
pub fn applicable(file: AuditFile, installed: Version) -> CatalogAudit {
  let holds = fn(coverage: Coverage) {
    list.any(coverage.ranges, fn(range) {
      compare(range.0, installed) != order.Gt
      && compare(installed, range.1) != order.Gt
    })
  }
  list.fold(file.entries, empty(), fn(acc, entry) {
    case entry {
      ReviewedContract(assume:, covers:) ->
        case holds(covers), annotation.assume_qualified_name(assume) {
          True, Ok(name) ->
            CatalogAudit(..acc, reviewed: set.insert(acc.reviewed, name))
          True, Error(Nil) | False, _ -> acc
        }
      ReviewedName(name:, covers:) ->
        case holds(covers) {
          True -> CatalogAudit(..acc, reviewed: set.insert(acc.reviewed, name))
          False -> acc
        }
      ContainerType(module:, name:, covers:) ->
        case holds(covers) {
          True ->
            CatalogAudit(
              ..acc,
              containers: set.insert(acc.containers, #(module, name)),
            )
          False -> acc
        }
      ConstantCarries(name:, carried:, covers:) ->
        case holds(covers), dict.has_key(acc.constants, name) {
          True, False ->
            CatalogAudit(
              ..acc,
              constants: dict.insert(acc.constants, name, carried),
            )
          True, True | False, _ -> acc
        }
      ContainerResult(name:, covers:) ->
        case holds(covers) {
          True ->
            CatalogAudit(
              ..acc,
              reviewed: set.insert(acc.reviewed, name),
              container_results: set.insert(acc.container_results, name),
            )
          False -> acc
        }
      Unreviewed(..) -> acc
    }
  })
}

fn compare(left: Version, right: Version) -> order.Order {
  int.compare(left.0, right.0)
  |> order.lazy_break_tie(fn() { int.compare(left.1, right.1) })
  |> order.lazy_break_tie(fn() { int.compare(left.2, right.2) })
}

// Every reviewed contract a record stages, for comparing with what the
// catalog file publishes.
pub fn contracts(file: AuditFile) -> List(types.AssumeAnnotation) {
  list.filter_map(file.entries, fn(entry) {
    case entry {
      ReviewedContract(assume:, ..) -> Ok(assume)
      ReviewedName(..)
      | ContainerType(..)
      | ConstantCarries(..)
      | ContainerResult(..)
      | Unreviewed(..) -> Error(Nil)
    }
  })
}
