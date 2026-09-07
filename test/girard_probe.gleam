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
import graded/internal/signatures
import graded/internal/typeinfo
import graded/internal/types.{type ClassificationCheck}
import simplifile

pub fn main() -> Nil {
  case argv.load().arguments {
    // `--detail` dumps one line per ambiguous site, which is how the fixture
    // sanity anchors are read.
    ["--detail", deps_dir, ..roots] if roots != [] -> {
      let rows = list.flat_map(roots, fn(root) { probe(deps_dir, root) })
      list.each(rows, print_row)
      report_totals(rows)
    }
    [deps_dir, ..roots] if roots != [] -> {
      let rows = list.flat_map(roots, fn(root) { probe(deps_dir, root) })
      report_totals(rows)
    }
    _ ->
      io.println(
        "usage: gleam run -m girard_probe -- [--detail] <deps_dir> <package_root>...",
      )
  }
}

fn print_row(check: ClassificationCheck) -> Nil {
  io.println(
    check.module
    <> "."
    <> check.function
    <> "  "
    <> checker.format_typed_resolution(check),
  )
}

// One package
//
// Parse its `src/`, annotate it with girard against a real dependency tree,
// then hand each module to graded's own classification pass.

fn probe(deps_dir: String, root: String) -> List(ClassificationCheck) {
  let source_dir = root <> "/src"
  let entries = parse_sources(source_dir)
  let index =
    list.fold(entries, dict.new(), fn(acc, entry) {
      let #(module_path, module) = entry
      dict.insert(acc, module_path, module)
    })

  let own_deps = effects.dependency_module_files(root <> "/build/packages")
  let borrowed = effects.dependency_module_files(deps_dir)
  // A package's own tree wins where it has one; the borrowed tree fills gaps.
  let dep_files = dict.merge(borrowed, own_deps)

  // The package's own declared targets, so a JavaScript-target package is typed
  // for JavaScript and its Erlang-only definitions are the dropped ones.
  let package_targets = read_targets(root)
  let options =
    girard.default_options()
    |> girard.with_target(graded.girard_target(package_targets))
    |> girard.with_resolver(resolver(source_dir, index, dep_files))

  let results = girard.annotate_package(entries, options)
  let type_info = type_index(results)

  let cross_constructors =
    list.fold(entries, dict.new(), fn(acc, entry) {
      let #(module_path, module) = entry
      dict.merge(acc, extract.constructor_registry(module_path, module))
    })
  let knowledge_base =
    effects.empty_knowledge_base(root)
    |> effects.with_constructors(cross_constructors)
  // The dependency modules' signatures as well as the package's own: the
  // shadowed-receiver split asks the registry whether the receiver's type
  // declares the label, and a type declared in a dependency answers nothing
  // from a package-only registry — which reads as "no accessor index at all"
  // and keeps the field. Production merges the two the same way.
  let registry =
    list.fold(entries, dependency_registry(dep_files), fn(acc, entry) {
      let #(module_path, module) = entry
      signatures.merge(acc, signatures.from_glance_module(module_path, module))
    })

  let rows =
    list.flat_map(entries, fn(entry) {
      let #(module_path, module) = entry
      checker.classify_module(
        module,
        module_path,
        knowledge_base,
        registry,
        typeinfo.for_module(type_info, module_path),
        typeinfo.fn_typed_for_module(type_info, module_path),
        typeinfo.evidence_for_module(type_info, module_path),
        package_targets,
      )
    })

  report_package(root, entries, results, rows)
  rows
}

// girard's whole answer for the package, folded the way `build_type_index`
// folds it — so the probe's classification reads the same maps production does.
fn type_index(results: Dict(String, girard.ModuleResult)) -> typeinfo.TypeInfo {
  let pairs = dict.to_list(results)
  typeinfo.from_modules(
    list.map(pairs, fn(pair) {
      let #(module_path, module_result) = pair
      #(
        module_path,
        list.fold(
          module_result.annotated.expressions,
          dict.new(),
          fn(acc, annotation) {
            dict.insert(
              acc,
              #(annotation.span.start, annotation.span.end),
              annotation.type_,
            )
          },
        ),
      )
    }),
    [],
    list.map(pairs, fn(pair) {
      let #(module_path, module_result) = pair
      #(
        module_path,
        list.fold(
          module_result.annotated.resolutions,
          dict.new(),
          fn(acc, reference) {
            dict.insert(
              acc,
              #(reference.span.start, reference.span.end),
              reference.resolution,
            )
          },
        ),
      )
    }),
    list.map(pairs, fn(pair) {
      let #(module_path, module_result) = pair
      #(module_path, dict.from_list(module_result.skipped))
    }),
    list.map(pairs, fn(pair) {
      let #(module_path, module_result) = pair
      #(
        module_path,
        list.fold(module_result.annotated.dropped, set.new(), fn(acc, entry) {
          set.insert(acc, entry.name)
        }),
      )
    }),
  )
}

// Every readable dependency module's signatures, keyed by its module path.
fn dependency_registry(
  dep_files: Dict(String, String),
) -> signatures.SignatureRegistry {
  use acc, module_path, path <- dict.fold(dep_files, signatures.empty())
  case simplifile.read(path) {
    Ok(source) ->
      case glance.module(source) {
        Ok(module) ->
          signatures.merge(
            acc,
            signatures.from_glance_module(module_path, module),
          )
        Error(_) -> acc
      }
    Error(_) -> acc
  }
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

fn report_package(
  root: String,
  entries: List(#(String, glance.Module)),
  results: Dict(String, girard.ModuleResult),
  rows: List(ClassificationCheck),
) -> Nil {
  let total_functions =
    list.fold(entries, 0, fn(acc, entry) {
      acc + list.length({ entry.1 }.functions)
    })
  let function_names =
    list.fold(entries, set.new(), fn(acc, entry) {
      let #(module_path, module) = entry
      list.fold(module.functions, acc, fn(acc, definition) {
        set.insert(acc, #(module_path, definition.definition.name))
      })
    })
  let skipped_functions =
    dict.to_list(results)
    |> list.flat_map(fn(pair) {
      let #(module_path, module_result) = pair
      list.filter_map(module_result.skipped, fn(entry) {
        case set.contains(function_names, #(module_path, entry.0)) {
          True -> Ok(checker.error_bucket(entry.1))
          False -> Error(Nil)
        }
      })
    })
  let dropped_definitions =
    dict.to_list(results)
    |> list.fold(0, fn(acc, pair) {
      acc + list.length({ pair.1 }.annotated.dropped)
    })
  let missing_modules =
    list.length(entries) - list.length(dict.to_list(results))

  io.println("")
  io.println("## " <> root)
  io.println("")
  io.println("modules: " <> int.to_string(list.length(entries)))
  io.println("modules girard dropped: " <> int.to_string(missing_modules))
  io.println("top-level functions: " <> int.to_string(total_functions))
  io.println(
    "girard-skipped functions: "
    <> int.to_string(list.length(skipped_functions)),
  )
  io.println(
    "girard-typed functions: "
    <> int.to_string(total_functions - list.length(skipped_functions)),
  )
  io.println(
    "definitions dropped for the other target: "
    <> int.to_string(dropped_definitions),
  )
  io.println("")
  io.println("skip reasons:")
  print_tally(tally(skipped_functions))
  report_rows(rows)
}

fn report_totals(rows: List(ClassificationCheck)) -> Nil {
  io.println("")
  io.println("## TOTAL")
  report_rows(rows)
}

fn report_rows(rows: List(ClassificationCheck)) -> Nil {
  io.println("")
  io.println("ambiguous call sites: " <> int.to_string(list.length(rows)))
  io.println("")
  io.println("relations:")
  print_tally(tally(list.map(rows, relation_label)))
  io.println("")
  io.println("graded's classification x girard's:")
  print_tally(
    tally(
      list.map(rows, fn(check) {
        graded_label(check.graded) <> " / " <> typed_label(check.typed)
      }),
    ),
  )

  let undecided =
    list.filter(rows, fn(check) {
      case check.relation {
        types.NoTypedEvidence(..) -> True
        types.Agree | types.Compatible(..) | types.Disagree -> False
      }
    })
  io.println("")
  io.println(
    "sites with no typed evidence: " <> int.to_string(list.length(undecided)),
  )
  io.println("  rate: " <> percent(list.length(undecided), list.length(rows)))
  io.println("")
  io.println("no typed evidence, by reason:")
  print_tally(tally(list.map(undecided, relation_label)))

  let disagree =
    list.filter(rows, fn(check) { check.relation == types.Disagree })
  io.println("")
  io.println("disagreements (one read the module, the other the field):")
  io.println("  " <> int.to_string(list.length(disagree)))
  list.each(disagree, print_row)
}

fn relation_label(check: ClassificationCheck) -> String {
  case check.relation {
    types.Agree -> "agree"
    types.Compatible(types.WiredValueVersusMember) ->
      "compatible:wired-value-vs-member"
    types.Disagree -> "disagree"
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
  }
}

fn graded_label(graded: types.GradedClassification) -> String {
  case graded {
    types.SyntaxModule(..) -> "module(syntax)"
    types.TypeSelectedModule(..) -> "module(type-selected)"
    types.Field(None) -> "field"
    types.Field(Some(..)) -> "field(shadowed)"
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
  case counts {
    [] -> io.println("  (none)")
    _ ->
      list.each(counts, fn(pair) {
        io.println("  " <> pair.0 <> ": " <> int.to_string(pair.1))
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
