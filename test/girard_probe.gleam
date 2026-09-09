// Cross-tabulate, over a whole package, how graded classifies each ambiguous
// `name.label(args)` against what girard resolved the same reference to. Not
// part of the product: it ships nowhere, changes nothing, and only counts.
//
// The question it answers: where do the two readings of an ambiguous call come
// apart, and where does girard supply no reading at all? Both are the gate on
// making girard's answer authoritative — a disagreement has to be adjudicated
// against the compiler first, and an absence costs precision.
//
// Run it with:
//
//   gleam run -m girard_probe -- <deps_dir> <package_root>...
//
// `deps_dir` is a `build/packages` tree to borrow when a scanned package has
// none of its own — a dep-less run makes every dependency call fail to resolve
// and poisons the numbers.
//
// The classification is graded's own: the probe supplies the package plumbing
// and calls `checker.classify_module`, so what it counts is exactly what
// `graded check` computes and `graded why` prints. Nothing here re-derives
// girard's answer from span annotations; `resolutions` is read directly.

import argv
import girard
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import graded
import graded/internal/checker
import graded/internal/config
import graded/internal/effects
import graded/internal/extract
import graded/internal/typeinfo
import graded/internal/types.{type ClassificationCheck}
import simplifile

pub fn main() -> Nil {
  case argv.load().arguments {
    // `--detail` dumps one line per ambiguous site, which is how the fixture
    // sanity anchors are read.
    ["--detail", deps_dir, ..roots] if roots != [] -> {
      let rows = probe_all(deps_dir, roots)
      list.each(rows, fn(row) { io.println(row_line(row)) })
      report_totals(rows)
    }
    [deps_dir, ..roots] if roots != [] ->
      report_totals(probe_all(deps_dir, roots))
    _ ->
      io.println(
        "usage: gleam run -m girard_probe -- [--detail] <deps_dir> <package_root>...",
      )
  }
}

// One row named by where it sits, with both halves of its reading.
fn row_line(check: ClassificationCheck) -> String {
  check.module
  <> "."
  <> check.function
  <> "  "
  <> checker.format_typed_resolution(check)
}

// Every root, against one borrowed dependency tree. The borrow is scanned once
// here rather than per root: it is the same tree for all of them.
fn probe_all(
  deps_dir: String,
  roots: List(String),
) -> List(ClassificationCheck) {
  let borrowed = effects.dependency_module_files(deps_dir)
  list.flat_map(roots, fn(root) { probe(borrowed, root) })
}

// One package
//
// Parse its `src/`, annotate it with girard against a real dependency tree,
// then hand each module to graded's own classification pass.

fn probe(
  borrowed: Dict(String, String),
  root: String,
) -> List(ClassificationCheck) {
  let source_dir = root <> "/src"
  let entries = parse_sources(source_dir)
  let index =
    list.fold(entries, dict.new(), fn(acc, entry) {
      let #(module_path, module) = entry
      dict.insert(acc, module_path, module)
    })

  let own_deps = effects.dependency_module_files(root <> "/build/packages")
  // A package's own tree wins where it has one; the borrowed tree fills gaps.
  let dep_files = dict.merge(borrowed, own_deps)

  // The package's own declared targets, so a JavaScript-target package is typed
  // for JavaScript first — and its Erlang-gated definitions on the second run.
  let package_targets = read_targets(root)
  let targets = graded.girard_targets(package_targets, entries)
  let type_info =
    graded.annotate_on_targets(
      entries,
      resolver(source_dir, index, dep_files),
      targets,
    )

  let cross_constructors =
    list.fold(entries, dict.new(), fn(acc, entry) {
      let #(module_path, module) = entry
      dict.merge(acc, extract.constructor_registry(module_path, module))
    })
  let knowledge_base =
    effects.empty_knowledge_base(root)
    |> effects.with_constructors(cross_constructors)
  let rows =
    list.flat_map(entries, fn(entry) {
      let #(module_path, module) = entry
      checker.classify_module(
        module,
        module_path,
        knowledge_base,
        typeinfo.reading_for_module(type_info, module_path),
        package_targets,
      )
    })

  report_package(root, entries, type_info, rows)
  rows
}

// The targets the scanned package declares. A root with no readable
// `gleam.toml` — a bare `build/packages/<dep>` directory — names none, and
// defaults as the compiler does.
fn read_targets(root: String) -> types.PackageTargets {
  case config.read(root <> "/gleam.toml") {
    Ok(cfg) -> cfg.targets
    Error(_) -> types.DefaultedTargets
  }
}

fn parse_sources(source_dir: String) -> List(#(String, glance.Module)) {
  let files = case simplifile.get_files(source_dir) {
    Ok(found) -> list.filter(found, string.ends_with(_, ".gleam"))
    Error(_) -> []
  }
  list.filter_map(files, fn(path) {
    use content <- result.try(
      simplifile.read(path) |> result.replace_error(Nil),
    )
    use module <- result.map(
      glance.module(content) |> result.replace_error(Nil),
    )
    #(config.module_path_for_source(path, source_dir), module)
  })
}

fn resolver(
  source_dir: String,
  index: Dict(String, glance.Module),
  dep_files: Dict(String, String),
) -> fn(String) -> Result(String, Nil) {
  let own =
    dict.keys(index)
    |> list.fold(dict.new(), fn(acc, module_path) {
      dict.insert(
        acc,
        module_path,
        source_dir <> "/" <> module_path <> ".gleam",
      )
    })
  fn(module_path) {
    case dict.get(own, module_path) {
      Ok(path) -> simplifile.read(path) |> result.replace_error(Nil)
      Error(Nil) ->
        case dict.get(dep_files, module_path) {
          Ok(path) -> simplifile.read(path) |> result.replace_error(Nil)
          Error(Nil) -> Error(Nil)
        }
    }
  }
}

// Reporting

// What the type inference covered in one package, counted the way the report
// states it and read off the merged reading rather than off girard directly —
// so the probe measures what `graded check` sees.
//
// The accounting is disjoint. A module is *read* (some run returned a result
// for it) or *unread*; a read module may be *unfilled*, read by the primary run
// and omitted by a secondary. Within a read module every function and every
// constant is exactly one of typed, skipped or left out of every run, and an
// unread module's definitions are unread, a count of their own. Skips naming no
// definition are listed apart and counted in none of the three.
pub type Coverage {
  Coverage(
    // The targets the inference ran on, primary first.
    targets: List(girard.Target),
    modules_read: Int,
    modules_unread: Int,
    modules_unfilled: Int,
    functions_typed: Int,
    // The error bucket of every skipped definition that is a function.
    functions_skipped: List(String),
    functions_left_out: Int,
    functions_unread: Int,
    constants_typed: Int,
    constants_skipped: List(String),
    constants_left_out: Int,
    constants_unread: Int,
    // Skips naming no definition the module declares on its run's target.
    unlocated: List(#(String, String)),
  )
}

// One package's coverage, from its parsed modules and the merged reading.
pub fn coverage(
  entries: List(#(String, glance.Module)),
  type_info: typeinfo.TypeInfo,
) -> Coverage {
  list.fold(
    entries,
    Coverage(
      targets: type_info.targets,
      modules_read: 0,
      modules_unread: 0,
      modules_unfilled: 0,
      functions_typed: 0,
      functions_skipped: [],
      functions_left_out: 0,
      functions_unread: 0,
      constants_typed: 0,
      constants_skipped: [],
      constants_left_out: 0,
      constants_unread: 0,
      unlocated: [],
    ),
    fn(acc, entry) {
      let #(module_path, module) = entry
      case set.contains(type_info.absent, module_path) {
        True ->
          Coverage(
            ..acc,
            modules_unread: acc.modules_unread + 1,
            functions_unread: acc.functions_unread
              + list.length(module.functions),
            constants_unread: acc.constants_unread
              + list.length(module.constants),
          )
        False -> {
          let evidence = typeinfo.evidence_for_module(type_info, module_path)
          let functions =
            standing_of(
              list.map(module.functions, fn(d) { { d.definition }.location }),
              evidence,
            )
          let constants =
            standing_of(
              list.map(module.constants, fn(d) { { d.definition }.location }),
              evidence,
            )
          Coverage(
            ..acc,
            modules_read: acc.modules_read + 1,
            modules_unfilled: case
              set.contains(type_info.unfilled, module_path)
            {
              True -> acc.modules_unfilled + 1
              False -> acc.modules_unfilled
            },
            functions_typed: acc.functions_typed + functions.0,
            functions_skipped: list.append(acc.functions_skipped, functions.1),
            functions_left_out: acc.functions_left_out + functions.2,
            constants_typed: acc.constants_typed + constants.0,
            constants_skipped: list.append(acc.constants_skipped, constants.1),
            constants_left_out: acc.constants_left_out + constants.2,
            unlocated: list.append(acc.unlocated, evidence.unlocated),
          )
        }
      }
    },
  )
}

// One module's definitions of one kind as `#(typed, skip buckets, left out)`.
// A definition left out of every run was never walked, so it is neither typed
// nor skipped — the three are exclusive and sum to the definitions declared.
fn standing_of(
  locations: List(glance.Span),
  evidence: typeinfo.ModuleEvidence,
) -> #(Int, List(String), Int) {
  list.fold(locations, #(0, [], 0), fn(acc, location) {
    let #(typed, skipped, left_out) = acc
    case typeinfo.is_dropped(evidence.dropped, location.start, location.end) {
      True -> #(typed, skipped, left_out + 1)
      False ->
        case
          typeinfo.skip_reason(evidence.skipped, location.start, location.end)
        {
          Some(bucket) -> #(typed, [bucket, ..skipped], left_out)
          None -> #(typed + 1, skipped, left_out)
        }
    }
  })
}

fn report_package(
  root: String,
  entries: List(#(String, glance.Module)),
  type_info: typeinfo.TypeInfo,
  rows: List(ClassificationCheck),
) -> Nil {
  let counted = coverage(entries, type_info)

  io.println("")
  io.println("## " <> root)
  io.println("")
  io.println(
    "targets the inference ran on: "
    <> string.join(list.map(counted.targets, typeinfo.target_name), ", "),
  )
  io.println("modules: " <> int.to_string(list.length(entries)))
  io.println(
    "modules the inference did not read: "
    <> int.to_string(counted.modules_unread),
  )
  io.println(
    "modules the second run could not read: "
    <> int.to_string(counted.modules_unfilled),
  )
  io.println(
    "top-level functions: "
    <> int.to_string(
      counted.functions_typed
      + list.length(counted.functions_skipped)
      + counted.functions_left_out
      + counted.functions_unread,
    ),
  )
  io.println(
    "girard-skipped functions: "
    <> int.to_string(list.length(counted.functions_skipped)),
  )
  io.println(
    "girard-typed functions: " <> int.to_string(counted.functions_typed),
  )
  io.println(
    "functions left out of every run: "
    <> int.to_string(counted.functions_left_out),
  )
  io.println(
    "constants left out of every run: "
    <> int.to_string(counted.constants_left_out),
  )
  io.println(
    "skips naming no definition: "
    <> int.to_string(list.length(counted.unlocated)),
  )
  io.println("")
  io.println("skip reasons:")
  print_tally(tally(counted.functions_skipped))
  report_rows(rows)
}

fn report_totals(rows: List(ClassificationCheck)) -> Nil {
  io.println("")
  io.println("## TOTAL")
  report_rows(rows)
}

fn report_rows(rows: List(ClassificationCheck)) -> Nil {
  list.each(report_lines(rows), io.println)
}

// The whole per-package (and total) report over a set of rows, as lines. Built
// rather than printed so a test can pin the wording of a report holding one row
// of each shape it accounts for.
pub fn report_lines(rows: List(ClassificationCheck)) -> List(String) {
  let undecided =
    list.filter(rows, fn(check) {
      case checker.relate(check) {
        types.NoTypedEvidence(..) -> True
        types.Compared(..) -> False
      }
    })
  let disagree =
    list.filter(rows, fn(check) {
      checker.relate(check) == types.Compared(types.Disagree)
    })
  list.flatten([
    ["", "ambiguous call sites: " <> int.to_string(list.length(rows))],
    ["", "relations:"],
    tally_lines(tally(list.map(rows, relation_label))),
    ["", "graded's classification x girard's:"],
    tally_lines(
      tally(
        list.map(rows, fn(check) {
          graded_label(check.graded) <> " / " <> typed_label(check.typed)
        }),
      ),
    ),
    [
      "",
      "sites with no typed evidence: " <> int.to_string(list.length(undecided)),
      "  rate: " <> percent(list.length(undecided), list.length(rows)),
      "",
      "no typed evidence, by reason:",
    ],
    tally_lines(tally(list.map(undecided, relation_label))),
    // Every undecided shadowed call, whatever its relation. The
    // no-typed-evidence tally above filters on the relation, which a
    // resolution mismatch does not have: graded refused what the inference
    // proved, so the row relates as a disagreement and would go uncounted
    // there.
    ["", "undecided shadowed calls, by reason:"],
    tally_lines(tally(list.filter_map(rows, undecided_shadowed_reason))),
    [
      "",
      "disagreements (one read the module, the other the field):",
      "  " <> int.to_string(list.length(disagree)),
    ],
    list.map(disagree, row_line),
  ])
}

// The reason graded left a shadowed call undecided, for the rows that are one.
fn undecided_shadowed_reason(
  check: ClassificationCheck,
) -> Result(String, Nil) {
  case check.graded {
    types.UndecidedShadowed(reason:, ..) -> Ok(undecided_label(reason))
    _ -> Error(Nil)
  }
}

fn relation_label(check: ClassificationCheck) -> String {
  case checker.relate(check) {
    types.Compared(types.Agree) -> "agree"
    types.Compared(types.CompatibleWiredValue) ->
      "compatible:wired-value-vs-member"
    types.Compared(types.Disagree) -> "disagree"
    types.NoTypedEvidence(reason:) ->
      "no-typed-evidence:" <> undecided_label(reason)
  }
}

fn undecided_label(reason: types.UndecidedReason) -> String {
  case reason {
    types.DefinitionDropped -> "dropped"
    types.FunctionSkipped(bucket:) -> "skipped(" <> bucket <> ")"
    types.NoResolutionAtSpan -> "no-resolution-at-span"
    types.ReceiverTypeUnknown -> "receiver-type-unknown"
    types.NotACallTarget(kind:) -> "not-a-call-target(" <> kind <> ")"
    types.ReceiverNotNominal -> "receiver-not-nominal"
    types.ResolutionMismatch(resolved:) ->
      "resolution-mismatch(" <> resolved <> ")"
  }
}

fn graded_label(graded: types.GradedClassification) -> String {
  case graded {
    types.SyntaxModule(..) -> "module(syntax)"
    types.TypeSelectedModule(..) -> "module(type-selected)"
    types.Field(None) -> "field"
    types.Field(Some(..)) -> "field(shadowed)"
    types.UndecidedShadowed(reason:, ..) ->
      "undecided(shadowed: " <> undecided_label(reason) <> ")"
    types.WiredValue(types.WiredFunction(..)) -> "wired(function)"
    types.WiredValue(types.WiredLocal(..)) -> "wired(local)"
    types.WiredValue(types.WiredConstructor) -> "wired(constructor)"
  }
}

fn typed_label(typed: types.TypedClassification) -> String {
  case typed {
    types.ProvedModuleCall(..) -> "proved-module"
    types.ProvedFieldCall(..) -> "proved-field"
    types.Undecided(reason:) -> "undecided:" <> undecided_label(reason)
  }
}

fn tally(items: List(String)) -> List(#(String, Int)) {
  list.fold(items, dict.new(), fn(acc, item) {
    dict.upsert(acc, item, fn(existing) {
      case existing {
        Some(count) -> count + 1
        None -> 1
      }
    })
  })
  |> dict.to_list()
  |> list.sort(fn(a, b) { int.compare(b.1, a.1) })
}

fn print_tally(counts: List(#(String, Int))) -> Nil {
  list.each(tally_lines(counts), io.println)
}

fn tally_lines(counts: List(#(String, Int))) -> List(String) {
  case counts {
    [] -> ["  (none)"]
    _ ->
      list.map(counts, fn(pair) {
        "  " <> pair.0 <> ": " <> int.to_string(pair.1)
      })
  }
}

fn percent(part: Int, whole: Int) -> String {
  case whole {
    0 -> "n/a"
    _ -> {
      let tenths = part * 1000 / whole
      int.to_string(tenths / 10) <> "." <> int.to_string(tenths % 10) <> "%"
    }
  }
}
