// Cross-tabulate, over a whole package, how graded classifies each ambiguous
// `name.label(args)` today against what girard's types prove about the same
// site. Not part of the product: it ships nowhere, changes nothing, and only
// counts.
//
// The question it answers: if girard-proved resolutions became authoritative
// and an ambiguous call without typed evidence fell to `[Unknown]`, how many
// call sites that graded resolves today would be demoted, and which girard gaps
// cause the demotions?
//
// Run it with:
//
//   gleam run -m girard_probe -- <deps_dir> <package_root>...
//
// `deps_dir` is a `build/packages` tree to borrow when a scanned package has
// none of its own — a dep-less run makes every dependency call fail to resolve
// and poisons the numbers.
//
// Girard has no resolution API yet, so typed evidence is read off the span
// annotations girard already emits. `infer_callee` records the *field-access*
// span alone when it selects a module export, and reaches
// `infer_field_access` — which infers, and so records, the *container* — in
// every other case. That gives three readable states per call site, plus the
// shadowed case where a receiver names both a value and a module and the
// annotations alone cannot say which way girard went.

import argv
import girard
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded/internal/config
import graded/internal/effects
import graded/internal/extract.{type ImportContext}
import graded/internal/signatures
import graded/internal/types
import simplifile

// How graded classifies an ambiguous site today, read off the extractor's own
// buckets by span.
type Today {
  TodayModule
  TodayField
  TodayShadowedField
  TodayLocal
  TodayNone
}

// What girard's span annotations prove about the same site.
//
// The three recording paths in girard that a `name.label` can take:
//
//   - module select — `infer_callee`'s first branch, and `module_or_record`:
//     records the field-access span from the module export's scheme and never
//     infers the container;
//   - value field — `value_field`: infers the container first, so both spans
//     are recorded;
//   - variant field — `infer_field_access`'s `env.variants` branch, taken when
//     a pattern narrowed the receiver: records the field-access span from the
//     variant's own field and never infers the container.
//
// So a recorded container proves a field; an unrecorded one is a module select
// only where the alias's module really exports the label, and a variant field
// otherwise.
type Evidence {
  // The enclosing definition is in girard's `skipped` list.
  SkippedFn(reason: String)
  // No container type, and the receiver names an imported module that exports
  // the label: girard selected the module export.
  ProvedModule
  // A type at the container span: girard inferred the receiver as a value and
  // read the label off its type.
  ProvedField
  // No container type and no module export to select: girard read the label off
  // a pattern-narrowed variant.
  ProvedVariantField
  // A container girard typed while the receiver also names a module exporting
  // the label: `value_field` may still have fallen back to that export.
  // Unreadable without the resolution API.
  ShadowedUnreadable
  // Typed function, no annotation at either span.
  NoEvidence
}

type Site {
  Site(
    module: String,
    function: String,
    receiver: String,
    label: String,
    // The span the extractor keys this site under.
    key: #(Int, Int),
    field_access: #(Int, Int),
    container: #(Int, Int),
    is_reference: Bool,
  )
}

type Row {
  Row(site: Site, today: Today, evidence: Evidence)
}

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

fn print_row(row: Row) -> Nil {
  let kind = case row.site.is_reference {
    True -> "ref  "
    False -> "call "
  }
  io.println(
    kind
    <> row.site.module
    <> "."
    <> row.site.function
    <> "  "
    <> row.site.receiver
    <> "."
    <> row.site.label
    <> "  today="
    <> today_label(row.today)
    <> "  girard="
    <> evidence_label(row.evidence),
  )
}

// One package
//
// Parse its `src/`, annotate it with girard against a real dependency tree,
// then walk every top-level function collecting ambiguous sites.

fn probe(deps_dir: String, root: String) -> List(Row) {
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

  let options =
    girard.default_options()
    |> girard.with_resolver(resolver(source_dir, index, dep_files))

  let results = girard.annotate_package(entries, options)

  let cross_constructors =
    list.fold(entries, dict.new(), fn(acc, entry) {
      let #(module_path, module) = entry
      dict.merge(acc, extract.constructor_registry(module_path, module))
    })

  let exports = export_index(entries, index, dep_files)

  let rows =
    list.flat_map(entries, fn(entry) {
      let #(module_path, module) = entry
      let #(spans, skipped) = case dict.get(results, module_path) {
        Ok(module_result) -> #(
          span_types(module_result),
          skip_map(module_result),
        )
        Error(Nil) -> #(set.new(), dict.new())
      }
      let context = module_context(module_path, module, cross_constructors)
      list.flat_map(module.functions, fn(definition) {
        let function = definition.definition
        function_rows(module_path, function, context, exports, spans, skipped)
      })
    })

  report_package(root, entries, results, rows)
  rows
}

// `module path -> the lowercase top-level names it exports`, for every module
// any scanned module imports qualified. This is what tells a module select
// apart from a variant field: girard can only have taken the module branch for
// `alias.label` where the aliased module really exports `label`. A parsed
// lookup, not a resolution decision — the probe never chooses a target with it.
fn export_index(
  entries: List(#(String, glance.Module)),
  index: Dict(String, glance.Module),
  dep_files: Dict(String, String),
) -> Dict(String, Set(String)) {
  let wanted =
    list.fold(entries, set.new(), fn(acc, entry) {
      extract.build_import_context({ entry.1 }).aliases
      |> dict.values()
      |> list.fold(acc, set.insert)
    })
  set.fold(wanted, dict.new(), fn(acc, module_path) {
    let parsed = case dict.get(index, module_path) {
      Ok(module) -> Ok(module)
      Error(Nil) ->
        case dict.get(dep_files, module_path) {
          Ok(path) ->
            simplifile.read(path)
            |> result.replace_error(Nil)
            |> result.try(fn(source) {
              glance.module(source) |> result.replace_error(Nil)
            })
          Error(Nil) -> Error(Nil)
        }
    }
    case parsed {
      Ok(module) -> dict.insert(acc, module_path, exported_names(module))
      Error(Nil) -> acc
    }
  })
}

fn exported_names(module: glance.Module) -> Set(String) {
  let names =
    list.fold(module.functions, set.new(), fn(acc, definition) {
      set.insert(acc, definition.definition.name)
    })
  list.fold(module.constants, names, fn(acc, definition) {
    set.insert(acc, definition.definition.name)
  })
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

// The extractor context, built the way `checker.module_context` builds it,
// minus the knowledge-base-backed cross-package maps: the module-versus-field
// decision reads only `aliases` and the lexical env, and the env's construction
// coverage reads the constructor and factory maps supplied here.
fn module_context(
  module_path: String,
  module: glance.Module,
  cross_constructors: Dict(#(String, String), List(Option(String))),
) -> ImportContext {
  let targets = types.DefaultedTargets
  extract.build_import_context(module)
  |> extract.with_module_path(module_path)
  |> extract.with_package_targets(targets)
  |> extract.with_factories(extract.factory_map(
    module_path,
    module,
    types.declaration_targets(targets),
    cross_constructors,
  ))
  |> extract.with_updates(extract.update_map(
    module_path,
    module,
    types.declaration_targets(targets),
    cross_constructors,
  ))
  |> extract.with_cross_constructors(cross_constructors)
  |> extract.with_fn_typed_fields(signatures.fn_typed_fields_from_module(
    module,
    signatures.type_alias_map(module.type_aliases),
  ))
}

fn span_types(module_result: girard.ModuleResult) -> Set(#(Int, Int)) {
  list.fold(module_result.annotated.expressions, set.new(), fn(acc, annotation) {
    set.insert(acc, #(annotation.span.start, annotation.span.end))
  })
}

fn skip_map(module_result: girard.ModuleResult) -> Dict(String, String) {
  list.fold(module_result.skipped, dict.new(), fn(acc, entry) {
    dict.insert(acc, entry.0, error_bucket(entry.1))
  })
}

// Stable, constructor-level buckets. `Unsupported` splits by its feature
// string, which is the backlog item the coverage table has to name.
fn error_bucket(error: girard.Error) -> String {
  case error {
    girard.TypeMismatch(..) -> "TypeMismatch"
    girard.ArityMismatch -> "ArityMismatch"
    girard.RecursiveType(..) -> "RecursiveType"
    girard.UnboundVariable(..) -> "UnboundVariable"
    girard.UnknownConstructor(..) -> "UnknownConstructor"
    girard.UnknownModule(..) -> "UnknownModule"
    girard.NoSuchExport(..) -> "NoSuchExport"
    girard.NoSuchField(..) -> "NoSuchField"
    girard.NotARecord -> "NotARecord"
    girard.NotATuple -> "NotATuple"
    girard.TupleIndexOutOfRange(..) -> "TupleIndexOutOfRange"
    girard.UnknownLabel(..) -> "UnknownLabel"
    girard.AmbiguousCall -> "AmbiguousCall"
    girard.Unsupported(feature) -> "Unsupported(" <> feature <> ")"
    girard.MissingArgument -> "MissingArgument"
    girard.ParseFailed(..) -> "ParseFailed"
  }
}

// One function
//
// Enumerate its ambiguous sites, read the extractor's verdict for each by span,
// and read girard's evidence off the annotation spans.

fn function_rows(
  module_path: String,
  function: glance.Function,
  context: ImportContext,
  exports: Dict(String, Set(String)),
  spans: Set(#(Int, Int)),
  skipped: Dict(String, String),
) -> List(Row) {
  let extracted = extract.extract_function_calls(function, context)
  let resolved =
    list.fold(extracted.resolved, set.new(), fn(acc, call) {
      set.insert(acc, extract.span_key(call.span))
    })
  let references =
    list.fold(extracted.references, set.new(), fn(acc, call) {
      set.insert(acc, extract.span_key(call.span))
    })
  let fields =
    list.fold(extracted.field, dict.new(), fn(acc, call) {
      dict.insert(acc, extract.span_key(call.span), call.shadowed_module)
    })
  let locals =
    list.fold(extracted.local, set.new(), fn(acc, call) {
      set.insert(acc, extract.span_key(call.span))
    })

  let sites =
    collect_statements(function.body, module_path, function.name, [])
    |> list.reverse()

  list.map(sites, fn(site) {
    let today = case
      set.contains(resolved, site.key) || set.contains(references, site.key),
      dict.get(fields, site.key),
      set.contains(locals, site.key)
    {
      True, _, _ -> TodayModule
      _, Ok(Some(_)), _ -> TodayShadowedField
      _, Ok(None), _ -> TodayField
      _, _, True -> TodayLocal
      _, _, _ -> TodayNone
    }
    // Whether the receiver names an imported module that really exports the
    // label — the only case in which girard's module branch was available.
    let selectable = case dict.get(context.aliases, site.receiver) {
      Ok(module) ->
        case dict.get(exports, module) {
          Ok(names) -> set.contains(names, site.label)
          Error(Nil) -> False
        }
      Error(Nil) -> False
    }
    let evidence = case dict.get(skipped, function.name) {
      Ok(reason) -> SkippedFn(reason)
      Error(Nil) ->
        case
          set.contains(spans, site.container),
          set.contains(spans, site.field_access),
          selectable,
          site.is_reference
        {
          // A container girard typed while a module export of the same name
          // exists: `value_field` records the container and may still fall
          // back to that export, and a `use` target reaches it.
          True, _, True, _ -> ShadowedUnreadable
          True, _, _, _ -> ProvedField
          False, True, True, _ -> ProvedModule
          False, True, False, _ -> ProvedVariantField
          False, False, _, _ -> NoEvidence
        }
    }
    Row(site:, today:, evidence:)
  })
}

// Site collection
//
// A plain walk of the glance tree. Call position and pipe-target position are
// the ambiguous *call* sites; a bare `name.label` anywhere else is an ambiguous
// *reference*, counted separately.

fn collect_statements(
  statements: List(glance.Statement),
  module: String,
  function: String,
  acc: List(Site),
) -> List(Site) {
  list.fold(statements, acc, fn(acc, statement) {
    case statement {
      glance.Use(function: callee, ..) ->
        collect_expression(callee, module, function, acc)
      glance.Assignment(value:, ..) ->
        collect_expression(value, module, function, acc)
      glance.Assert(expression:, message:, ..) ->
        collect_optional(
          message,
          module,
          function,
          collect_expression(expression, module, function, acc),
        )
      glance.Expression(expression) ->
        collect_expression(expression, module, function, acc)
    }
  })
}

fn collect_optional(
  expression: Option(glance.Expression),
  module: String,
  function: String,
  acc: List(Site),
) -> List(Site) {
  case expression {
    Some(inner) -> collect_expression(inner, module, function, acc)
    None -> acc
  }
}

fn collect_each(
  expressions: List(glance.Expression),
  module: String,
  function: String,
  acc: List(Site),
) -> List(Site) {
  list.fold(expressions, acc, fn(acc, expression) {
    collect_expression(expression, module, function, acc)
  })
}

fn collect_fields(
  fields: List(glance.Field(glance.Expression)),
  module: String,
  function: String,
  acc: List(Site),
) -> List(Site) {
  list.fold(fields, acc, fn(acc, field) {
    case field {
      glance.LabelledField(item:, ..) ->
        collect_expression(item, module, function, acc)
      glance.UnlabelledField(item) ->
        collect_expression(item, module, function, acc)
      glance.ShorthandField(..) -> acc
    }
  })
}

fn collect_expression(
  expression: glance.Expression,
  module: String,
  function: String,
  acc: List(Site),
) -> List(Site) {
  case expression {
    // `name.label(args)` — the ambiguous call, keyed by the whole call span.
    glance.Call(
      location: call_span,
      function: glance.FieldAccess(
        location: field_span,
        container: glance.Variable(container_span, receiver),
        label:,
      ),
      arguments:,
    ) ->
      collect_fields(
        arguments,
        module,
        function,
        push(
          acc,
          module,
          function,
          receiver,
          label,
          span_key(call_span),
          span_key(field_span),
          span_key(container_span),
          False,
        ),
      )

    glance.Call(function: callee, arguments:, ..) ->
      collect_fields(
        arguments,
        module,
        function,
        collect_expression(callee, module, function, acc),
      )

    // `left |> name.label` — the extractor keys this under the field-access
    // span, since the piped value is the implicit argument.
    glance.BinaryOperator(
      name: glance.Pipe,
      left:,
      right: glance.FieldAccess(
        location: field_span,
        container: glance.Variable(container_span, receiver),
        label:,
      ),
      ..,
    ) ->
      push(
        collect_expression(left, module, function, acc),
        module,
        function,
        receiver,
        label,
        span_key(field_span),
        span_key(field_span),
        span_key(container_span),
        False,
      )

    glance.BinaryOperator(left:, right:, ..) ->
      collect_expression(
        right,
        module,
        function,
        collect_expression(left, module, function, acc),
      )

    // A bare `name.label` in value position: an ambiguous *reference*.
    glance.FieldAccess(
      location: field_span,
      container: glance.Variable(container_span, receiver),
      label:,
    ) ->
      push(
        acc,
        module,
        function,
        receiver,
        label,
        span_key(field_span),
        span_key(field_span),
        span_key(container_span),
        True,
      )

    glance.FieldAccess(container:, ..) ->
      collect_expression(container, module, function, acc)

    glance.Fn(body:, ..) -> collect_statements(body, module, function, acc)
    glance.Block(statements:, ..) ->
      collect_statements(statements, module, function, acc)
    glance.Case(subjects:, clauses:, ..) ->
      list.fold(
        clauses,
        collect_each(subjects, module, function, acc),
        fn(acc, clause) {
          collect_optional(
            clause.guard,
            module,
            function,
            collect_expression(clause.body, module, function, acc),
          )
        },
      )
    glance.Tuple(elements:, ..) -> collect_each(elements, module, function, acc)
    glance.List(elements:, rest:, ..) ->
      collect_optional(
        rest,
        module,
        function,
        collect_each(elements, module, function, acc),
      )
    glance.NegateInt(value:, ..) | glance.NegateBool(value:, ..) ->
      collect_expression(value, module, function, acc)
    glance.TupleIndex(tuple:, ..) ->
      collect_expression(tuple, module, function, acc)
    glance.FnCapture(function: callee, arguments_before:, arguments_after:, ..) ->
      collect_fields(
        arguments_after,
        module,
        function,
        collect_fields(
          arguments_before,
          module,
          function,
          collect_expression(callee, module, function, acc),
        ),
      )
    glance.RecordUpdate(record:, fields:, ..) ->
      list.fold(
        fields,
        collect_expression(record, module, function, acc),
        fn(acc, field) { collect_optional(field.item, module, function, acc) },
      )
    glance.BitString(segments:, ..) ->
      collect_each(
        list.map(segments, fn(segment) { segment.0 }),
        module,
        function,
        acc,
      )
    glance.Echo(expression:, message:, ..) ->
      collect_optional(
        message,
        module,
        function,
        collect_optional(expression, module, function, acc),
      )
    glance.Panic(message:, ..) | glance.Todo(message:, ..) ->
      collect_optional(message, module, function, acc)
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> acc
  }
}

fn span_key(span: glance.Span) -> #(Int, Int) {
  #(span.start, span.end)
}

// A site is ambiguous only when both halves are lowercase: an uppercase label
// is a constructor call, which the extractor and the compiler both settle
// without types.
fn push(
  acc: List(Site),
  module: String,
  function: String,
  receiver: String,
  label: String,
  key: #(Int, Int),
  field_access: #(Int, Int),
  container: #(Int, Int),
  is_reference: Bool,
) -> List(Site) {
  case types.is_upper_initial(receiver) || types.is_upper_initial(label) {
    True -> acc
    False -> [
      Site(
        module:,
        function:,
        receiver:,
        label:,
        key:,
        field_access:,
        container:,
        is_reference:,
      ),
      ..acc
    ]
  }
}

// Reporting

fn report_package(
  root: String,
  entries: List(#(String, glance.Module)),
  results: Dict(String, girard.ModuleResult),
  rows: List(Row),
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
          True -> Ok(error_bucket(entry.1))
          False -> Error(Nil)
        }
      })
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
  io.println("")
  io.println("skip reasons:")
  print_tally(tally(skipped_functions))
  report_rows(rows)
}

fn report_totals(rows: List(Row)) -> Nil {
  io.println("")
  io.println("## TOTAL")
  report_rows(rows)
}

fn report_rows(rows: List(Row)) -> Nil {
  let calls = list.filter(rows, fn(row) { !row.site.is_reference })
  let refs = list.filter(rows, fn(row) { row.site.is_reference })
  io.println("")
  io.println("ambiguous call sites: " <> int.to_string(list.length(calls)))
  io.println("ambiguous references: " <> int.to_string(list.length(refs)))
  io.println("")
  io.println("calls: today x evidence")
  print_tally(
    tally(
      list.map(calls, fn(row) {
        today_label(row.today) <> " / " <> evidence_label(row.evidence)
      }),
    ),
  )
  io.println("")
  io.println("references: today x evidence")
  print_tally(
    tally(
      list.map(refs, fn(row) {
        today_label(row.today) <> " / " <> evidence_label(row.evidence)
      }),
    ),
  )

  // The headline: sites graded resolves today (module or field) whose girard
  // evidence would not prove them under the authoritative regime.
  let resolved_today =
    list.filter(calls, fn(row) {
      case row.today {
        TodayModule | TodayField | TodayShadowedField -> True
        TodayLocal | TodayNone -> False
      }
    })
  let demoted =
    list.filter(resolved_today, fn(row) {
      case row.evidence {
        SkippedFn(..) | NoEvidence -> True
        ProvedModule | ProvedField | ProvedVariantField | ShadowedUnreadable ->
          False
      }
    })
  io.println("")
  io.println(
    "resolved-today ambiguous calls: "
    <> int.to_string(list.length(resolved_today)),
  )
  io.println(
    "would demote to [Unknown]: " <> int.to_string(list.length(demoted)),
  )
  io.println(
    "demotion rate: "
    <> percent(list.length(demoted), list.length(resolved_today)),
  )
  io.println("")
  io.println("demotions by cause:")
  print_tally(
    tally(list.map(demoted, fn(row) { evidence_label(row.evidence) })),
  )
  io.println("")
  io.println("shadowed-receiver field calls (soundness-sensitive subset):")
  let shadowed =
    list.filter(calls, fn(row) {
      case row.today {
        TodayShadowedField -> True
        _ -> False
      }
    })
  io.println("  total: " <> int.to_string(list.length(shadowed)))
  print_tally(
    tally(list.map(shadowed, fn(row) { evidence_label(row.evidence) })),
  )
  io.println("")
  io.println("disagreements (graded and girard pick different targets):")
  let disagree =
    list.filter(calls, fn(row) {
      case row.today, row.evidence {
        TodayModule, ProvedField -> True
        TodayModule, ProvedVariantField -> True
        TodayField, ProvedModule -> True
        TodayShadowedField, ProvedModule -> True
        _, _ -> False
      }
    })
  io.println("  " <> int.to_string(list.length(disagree)))
  list.each(list.take(disagree, 12), fn(row) {
    io.println(
      "    "
      <> row.site.module
      <> "."
      <> row.site.function
      <> ": "
      <> row.site.receiver
      <> "."
      <> row.site.label,
    )
  })
}

fn today_label(today: Today) -> String {
  case today {
    TodayModule -> "module"
    TodayField -> "field"
    TodayShadowedField -> "field(shadowed)"
    TodayLocal -> "local"
    TodayNone -> "none"
  }
}

fn evidence_label(evidence: Evidence) -> String {
  case evidence {
    SkippedFn(reason) -> "skipped:" <> reason
    ProvedModule -> "proved-module"
    ProvedField -> "proved-field"
    ProvedVariantField -> "proved-field(variant)"
    ShadowedUnreadable -> "shadowed-unreadable"
    NoEvidence -> "no-evidence"
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
