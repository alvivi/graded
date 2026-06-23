//// Effect checker for Gleam via sidecar `.graded` annotation files.
////
//// graded verifies that your Gleam functions respect their declared effect
//// budgets. Annotations live in `.graded` sidecar files alongside your source
//// — your Gleam code stays clean.
////
//// ## Usage
////
//// ```sh
//// gleam run -m graded check [directory]   # enforce check annotations (default)
//// gleam run -m graded infer [directory]   # infer and write effect annotations
//// gleam run -m graded format [directory]  # normalize .graded file formatting
//// ```
////
//// ## Programmatic API
////
//// Use `run` to check a directory and get back a list of `CheckResult` values,
//// each containing any violations found per file. Use `run_infer` to infer
//// effects and write `.graded` files.
////

import argv
import filepath
import girard
import girard/types as girard_types
import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded/internal/annotation
import graded/internal/checker
import graded/internal/config
import graded/internal/effect_term
import graded/internal/effects.{type KnowledgeBase}
import graded/internal/extract
import graded/internal/signatures.{type SignatureRegistry}
import graded/internal/topo
import graded/internal/typeinfo
import graded/internal/types.{
  type CheckResult, type EffectAnnotation, type GradedFile, type QualifiedName,
  type Violation, type Warning, AnnotationLine, CheckResult, EffectAnnotation,
  GradedFile, QualifiedName, UnmatchedFieldBoundWarning,
  UnmatchedParamBoundWarning, UntrackedEffectWarning,
}
import simplifile

/// Errors that can occur during checking, inference, or formatting.
pub type GradedError {
  /// Could not read the source directory.
  DirectoryReadError(path: String, cause: simplifile.FileError)
  /// Could not read a source or annotation file.
  FileReadError(path: String, cause: simplifile.FileError)
  /// Could not write an annotation file.
  FileWriteError(path: String, cause: simplifile.FileError)
  /// Could not create the output directory for annotation files.
  DirectoryCreateError(path: String, cause: simplifile.FileError)
  /// A `.gleam` source file could not be parsed.
  GleamParseError(path: String, cause: glance.Error)
  /// A `.graded` annotation file could not be parsed.
  GradedParseError(path: String, cause: annotation.ParseError)
  /// `gleam.toml` was present but malformed, or missing its `name`. A missing
  /// `gleam.toml` is tolerated and does not produce this error.
  InvalidConfig(path: String, cause: config.ConfigError)
  /// One or more `.graded` files are not formatted (returned by `run_format_check`).
  FormatCheckFailed(paths: List(String))
  /// The project's import graph contains a cycle. Gleam disallows circular
  /// imports at the language level, so this should be unreachable in
  /// practice — if it ever fires it indicates a bug in the dependency edge
  /// extraction rather than user code.
  CyclicImports(modules: List(String))
}

pub fn main() -> Nil {
  let arguments = argv.load().arguments
  case arguments {
    ["infer", ..rest] ->
      case run_infer(target_directory(rest)) {
        Ok(Nil) -> io.println("graded: inferred effects written")
        Error(error) -> {
          io.println_error("graded: error: " <> format_error(error))
          halt(1)
        }
      }
    ["format", "--stdin", ..] ->
      case run_format_stdin(read_stdin()) {
        Ok(output) -> io.print(output)
        Error(_) -> {
          io.println_error("graded: error: could not parse stdin")
          halt(1)
        }
      }
    ["format", "--check", ..rest] ->
      case run_format_check(target_directory(rest)) {
        Ok(Nil) -> Nil
        Error(error) -> {
          io.println_error("graded: error: " <> format_error(error))
          halt(1)
        }
      }
    ["format", ..rest] ->
      case run_format(target_directory(rest)) {
        Ok(Nil) -> Nil
        Error(error) -> {
          io.println_error("graded: error: " <> format_error(error))
          halt(1)
        }
      }
    ["check", ..rest] -> run_check(target_directory(rest))
    _ -> run_check(target_directory(arguments))
  }
}

/// Run the checker on all .gleam files in a directory.
///
/// Reads the project's single spec file (default `<package_name>.graded`)
/// to find inferred public-API effects, `check` invariants, `external`
/// hints, and `type` field annotations, then reports violations per source
/// file.
pub fn run(directory: String) -> Result(List(CheckResult), GradedError) {
  use cfg <- result.try(read_config(directory))
  let package_root = resolve_package_root(directory)
  let spec = read_spec(cfg.spec_file)
  let checks_by_module = checks_grouped_by_module(spec)

  use gleam_files <- result.try(find_gleam_files(directory))
  use parsed <- result.try(parse_all_files(gleam_files))
  let index = build_module_index(parsed, directory)
  let dep_registry =
    signatures.load_from_packages_dir(packages_dir(package_root))
    |> signatures.merge(path_dep_registry(package_root))
  let registry = signatures.merge(dep_registry, build_project_registry(index))
  let type_info = build_type_index(index)

  // Hand-written `type` lines (last) win over the inferred construction index.
  let kb_base =
    effects.load_knowledge_base(
      packages_dir(package_root),
      manifest_path(package_root),
    )
    |> enrich_with_path_deps(package_root)
    |> effects.with_inferred(effects.load_spec_effects_from_file(spec))
    |> effects.with_inferred_returned_operators(
      effects.load_spec_returns_from_file(spec),
    )
    |> effects.with_externals(annotation.extract_externals(spec))
    // Fill gaps for project modules not (yet) in the spec by inferring them
    // in memory, so `check` resolves cross-module calls without a prior
    // `graded infer`. Spec entries above take priority — committed effects are
    // never overridden — and nothing is written to disk.
    |> infer_project_in_memory(index, registry, type_info)
  let knowledge_base =
    kb_base
    |> effects.with_inferred_type_fields(build_constructor_field_index(
      index,
      kb_base,
    ))
    |> effects.with_type_fields(annotation.extract_type_fields(spec))
    |> effects.with_factories(qualify_by_module(index, extract.factory_map))

  let results =
    list.map(parsed, fn(entry) {
      let #(gleam_path, module) = entry
      let module_path = config.module_path_for_source(gleam_path, directory)
      let module_checks = case dict.get(checks_by_module, module_path) {
        Ok(list) -> list
        Error(_) -> []
      }
      check_one_file(
        gleam_path,
        module_path,
        module,
        module_checks,
        knowledge_base,
        registry,
        typeinfo.for_module(type_info, module_path),
        typeinfo.fn_typed_for_module(type_info, module_path),
      )
    })

  Ok(results)
}

/// Infer effects for all `.gleam` files in `directory`. Writes two outputs:
///
/// 1. **Per-module cache files** under `<cache_dir>/<module_path>.graded`,
///    containing the inferred effects of every function in the module
///    (public + private). Regenerated freely; not shipped.
///
/// 2. **One spec file** at `<spec_file>` containing the inferred effects of
///    every *public* function across all modules, plus any hand-written
///    `check`, `external effects`, or `type` annotations the user already
///    had in the spec file (those lines are preserved verbatim).
///
/// Walks the project's import graph in topological order so each module is
/// analysed after every other project module it imports — a single pass
/// resolves transitive chains of any depth.
pub fn run_infer(directory: String) -> Result(Nil, GradedError) {
  use cfg <- result.try(read_config(directory))
  let package_root = resolve_package_root(directory)
  let spec = read_spec(cfg.spec_file)

  use gleam_files <- result.try(find_gleam_files(directory))
  use parsed <- result.try(parse_all_files(gleam_files))
  let index = build_module_index(parsed, directory)

  let kb_base =
    effects.load_knowledge_base(
      packages_dir(package_root),
      manifest_path(package_root),
    )
    |> enrich_with_path_deps(package_root)
    |> effects.with_externals(annotation.extract_externals(spec))
  // Resolve constructor-field values against the same view `run` uses — catalog
  // + externals + the spec's *existing* inferred effects — so `infer` and
  // `check` agree on a field wired to a qualified project function, converging
  // across runs. The inferred effects are NOT seeded into `base_kb` below: the
  // topo loop recomputes them fresh, threading each module's result forward.
  let construction_kb =
    effects.with_inferred(kb_base, effects.load_spec_effects_from_file(spec))
  let base_kb =
    kb_base
    |> effects.with_inferred_type_fields(build_constructor_field_index(
      index,
      construction_kb,
    ))
    |> effects.with_type_fields(annotation.extract_type_fields(spec))
    |> effects.with_factories(qualify_by_module(index, extract.factory_map))

  let graph = build_dependency_graph(index)
  use sorted <- result.try(
    topo.sort(graph)
    |> result.map_error(fn(error) {
      let topo.Cycle(nodes:) = error
      CyclicImports(modules: nodes)
    }),
  )

  // Build a signature registry covering every project module so the
  // checker can do positional argument matching for cross-module
  // polymorphic calls.
  let dep_registry =
    signatures.load_from_packages_dir(packages_dir(package_root))
    |> signatures.merge(path_dep_registry(package_root))
  let registry = signatures.merge(dep_registry, build_project_registry(index))
  let type_info = build_type_index(index)

  use #(_kb, public_annotations, public_returns) <- result.try(
    list.try_fold(sorted, #(base_kb, [], []), fn(state, module_path) {
      let #(kb, acc, returns_acc) = state
      case dict.get(index, module_path) {
        Error(_) -> Ok(state)
        Ok(#(_gleam_path, module)) -> {
          use #(new_kb, new_public, new_returns) <- result.try(infer_one_module(
            module,
            module_path,
            cfg.cache_dir,
            kb,
            registry,
            typeinfo.for_module(type_info, module_path),
            typeinfo.fn_typed_for_module(type_info, module_path),
          ))
          // Prepend new entries so each iteration is O(|new|) instead of
          // O(|acc|); final order doesn't matter, merge_inferred keys by name.
          Ok(#(
            new_kb,
            list.append(new_public, acc),
            list.append(new_returns, returns_acc),
          ))
        }
      }
    }),
  )

  write_spec_file(cfg.spec_file, spec, public_annotations, public_returns)
}

/// Format the project's spec file in place. The spec file is the single
/// source of truth for hand-written `check`/`external`/`type` lines and
/// the inferred public-API effects.
pub fn run_format(directory: String) -> Result(Nil, GradedError) {
  use cfg <- result.try(read_config(directory))
  use formatted <- result.try(format_one_spec(cfg.spec_file))
  case formatted {
    None -> Ok(Nil)
    Some(formatted) ->
      simplifile.write(cfg.spec_file, formatted)
      |> result.map_error(FileWriteError(cfg.spec_file, _))
  }
}

/// Format a `.graded` spec given as a string, as `graded format --stdin` does
/// for editor integration: parse the input, then sort and reformat it. Returns
/// the input's parse error if it doesn't parse.
pub fn run_format_stdin(
  input: String,
) -> Result(String, annotation.ParseError) {
  use file <- result.map(annotation.parse_file(input))
  annotation.format_sorted(file)
}

/// Check that the project's spec file is already formatted. Returns error
/// with the file path if it isn't. Used by CI as `format --check`.
pub fn run_format_check(directory: String) -> Result(Nil, GradedError) {
  use cfg <- result.try(read_config(directory))
  use formatted <- result.try(format_one_spec(cfg.spec_file))
  case formatted {
    None -> Ok(Nil)
    Some(formatted) ->
      case simplifile.read(cfg.spec_file) {
        Error(_) -> Ok(Nil)
        Ok(content) ->
          case content == formatted {
            True -> Ok(Nil)
            False -> Error(FormatCheckFailed(paths: [cfg.spec_file]))
          }
      }
  }
}

// Format the spec file's contents, or `None` when there is no spec file. A
// missing file is tolerated; a malformed one is a parse error.
fn format_one_spec(
  spec_path: String,
) -> Result(option.Option(String), GradedError) {
  case simplifile.read(spec_path) {
    Error(_) -> Ok(None)
    Ok(content) ->
      annotation.parse_file(content)
      |> result.map(fn(file) { Some(annotation.format_sorted(file)) })
      |> result.map_error(GradedParseError(spec_path, _))
  }
}

// PRIVATE

// Parse every project source file once, returning `(path, parsed module)`
// pairs. Used by `run_infer` so the topo sort can read each module's
// imports without re-parsing on the inference pass.
fn parse_all_files(
  gleam_files: List(String),
) -> Result(List(#(String, glance.Module)), GradedError) {
  list.try_map(gleam_files, fn(gleam_path) {
    use module <- result.try(read_and_parse_gleam(gleam_path))
    Ok(#(gleam_path, module))
  })
}

// Build a signature registry covering every project module. Used by
// the checker's call-site substitution to resolve effect variables
// when the caller passes positional (unlabeled) arguments.
fn build_project_registry(
  index: Dict(String, #(String, glance.Module)),
) -> SignatureRegistry {
  dict.fold(index, signatures.empty(), fn(acc, module_path, entry) {
    let #(_gleam_path, module) = entry
    signatures.merge(acc, signatures.from_glance_module(module_path, module))
  })
}

// Stage C: derive `type Foo.field : [...]` annotations from constructor call
// sites across the package. `Validator(to_error: io.println)` anywhere makes
// `Validator.to_error` carry io.println's effects (unioned across all sites),
// so a field call resolves without a hand-written annotation. Resolved via
// girard's receiver typing at the use site; hand-written `type` lines still
// win, since they are merged over these.
fn build_constructor_field_index(
  index: Dict(String, #(String, glance.Module)),
  knowledge_base: KnowledgeBase,
) -> List(#(#(String, String, String), types.TypeFieldEffect)) {
  // Package-wide #(defining module, constructor) -> type name. Keyed by module
  // so same-named constructors in different modules stay distinct; the call
  // site's resolved module (or the current module for an unqualified call)
  // picks the right entry.
  let constructor_types =
    qualify_by_module(index, extract.build_constructor_type_map)

  // Package-wide #(defining module, constructor) -> field labels, so a
  // cross-module positional constructor call routes its arguments to fields.
  let cross_constructors =
    qualify_by_module(index, extract.constructor_label_map)

  // Accumulate (module, type_name, field) -> effect, unioning across sites.
  // `path` is the module being walked — used to qualify same-module function
  // values wired into fields.
  dict.fold(index, dict.new(), fn(acc, path, entry) {
    let #(_gleam_path, module) = entry
    let context =
      extract.build_import_context(module)
      |> extract.with_cross_constructors(cross_constructors)
    // Resolve a field wired to an inline/let-bound closure by analysing the
    // closure body in this module's context (same-module calls via its
    // function map), instead of collapsing to `[Unknown]`.
    let function_map = checker.build_function_map(module)
    // Built once per module and shared across every field closure analysed
    // below, rather than rebuilt per closure.
    let scc_ids = checker.build_scc_ids(module, context, dict.new(), False)
    let closure_effect = fn(params, body) {
      checker.closure_field_operator(
        params,
        body,
        context,
        function_map,
        knowledge_base,
        scc_ids,
      )
    }
    extract.collect_constructor_bindings(module, context)
    |> list.fold(acc, fn(inner, binding) {
      accumulate_constructor_binding(
        inner,
        binding,
        constructor_types,
        knowledge_base,
        path,
        closure_effect,
      )
    })
  })
  |> dict.to_list()
}

// Build a package-wide map keyed by `#(defining module, name)` from a per-module
// `name -> value` map, qualifying each entry with the module it came from.
fn qualify_by_module(
  index: Dict(String, #(String, glance.Module)),
  per_module: fn(glance.Module) -> Dict(String, value),
) -> Dict(#(String, String), value) {
  dict.fold(index, dict.new(), fn(acc, path, entry) {
    let #(_gleam_path, module) = entry
    dict.fold(per_module(module), acc, fn(inner, name, value) {
      dict.insert(inner, #(path, name), value)
    })
  })
}

// Fold one constructor call's field bindings into the (module, type, field) ->
// effect accumulator, unioning with any effect already recorded for that field.
// The defining module is the call's resolved module (qualified) or the current
// module (unqualified) — so same-named constructors in different modules don't
// collide.
fn accumulate_constructor_binding(
  acc: Dict(#(String, String, String), types.TypeFieldEffect),
  binding: extract.ConstructorBinding,
  constructor_types: Dict(#(String, String), String),
  knowledge_base: KnowledgeBase,
  module_path: String,
  closure_effect: fn(List(String), List(glance.Statement)) -> types.EffectTerm,
) -> Dict(#(String, String, String), types.TypeFieldEffect) {
  let extract.ConstructorBinding(binding_module, constructor, fields) = binding
  let module = option.unwrap(binding_module, module_path)
  case dict.get(constructor_types, #(module, constructor)) {
    Error(Nil) -> acc
    Ok(type_name) ->
      dict.fold(fields, acc, fn(inner, label, value) {
        let field_effect =
          field_effect_of(knowledge_base, value, module_path, closure_effect)
        let key = #(module, type_name, label)
        let merged = case dict.get(inner, key) {
          Ok(existing) -> merge_field_effect(existing, field_effect)
          Error(Nil) -> field_effect
        }
        dict.insert(inner, key, merged)
      })
  }
}

// The effect a constructor field's value contributes. A function reference (or
// a same-module function, qualified by `module_path`) resolves via the
// knowledge base — capturing its param bounds + identity when it is
// effect-polymorphic. A constructor is pure; anything else is `[Unknown]`.
fn field_effect_of(
  knowledge_base: KnowledgeBase,
  value: types.ArgumentValue,
  module_path: String,
  closure_effect: fn(List(String), List(glance.Statement)) -> types.EffectTerm,
) -> types.TypeFieldEffect {
  case field_value_function(value, module_path) {
    Some(name) -> {
      let field_effects = effects.lookup_effects(knowledge_base, name)
      case set.is_empty(effect_term.free_vars(field_effects)) {
        // Concrete effect: no bounds or source to carry.
        True -> types.TypeFieldEffect(field_effects, [], None)
        // Effect-polymorphic: keep the wired function's bounds and identity.
        False ->
          types.TypeFieldEffect(
            field_effects,
            effects.lookup_param_bounds(knowledge_base, name),
            Some(name),
          )
      }
    }
    // A field wired to an inline/let-bound closure: analyse its body for the
    // field's effect instead of collapsing to `[Unknown]`.
    None ->
      case value {
        types.Closure(params, body) ->
          types.TypeFieldEffect(closure_effect(params, body), [], None)
        _ ->
          types.TypeFieldEffect(
            effects.argument_value_effects(knowledge_base, value),
            [],
            None,
          )
      }
  }
}

// The qualified function a field value refers to, if any: a `FunctionRef`
// directly, or a `LocalRef` (a bare same-module name) qualified by the current
// module. `None` for constructors and inline expressions.
fn field_value_function(
  value: types.ArgumentValue,
  module_path: String,
) -> option.Option(QualifiedName) {
  case value {
    types.FunctionRef(name:) -> Some(name)
    types.LocalRef(name:) -> Some(QualifiedName(module_path, name))
    _ -> None
  }
}

// Union two field-effect contributions for the same field across sites. Keeps
// the first polymorphic source — conflicting polymorphism across sites is rare,
// and unbound variables collapse to `[Unknown]` at the call site.
fn merge_field_effect(
  existing: types.TypeFieldEffect,
  new: types.TypeFieldEffect,
) -> types.TypeFieldEffect {
  let #(bounds, source) = case existing.source {
    Some(_) -> #(existing.bounds, existing.source)
    None -> #(new.bounds, new.source)
  }
  types.TypeFieldEffect(
    effect_term.normalize(types.TUnion([existing.effects, new.effects])),
    bounds,
    source,
  )
}

// Run girard's whole-package type inference once over every project module
// and fold the result into a `TypeInfo` (module path -> span start -> type).
// girard is best-effort: a function it can't type contributes no expressions,
// so the checker silently falls back to syntax-level resolution for it.
fn build_type_index(
  index: Dict(String, #(String, glance.Module)),
) -> typeinfo.TypeInfo {
  let options =
    girard.default_options()
    |> girard.with_resolver(build_girard_resolver(index))
  let entries =
    dict.to_list(index)
    |> list.map(fn(pair) {
      let #(module_path, #(_gleam_path, module)) = pair
      #(module_path, module)
    })
  let results = girard.annotate_package(entries, options) |> dict.to_list()
  let span_types =
    list.map(results, fn(pair) {
      let #(module_path, module_result) = pair
      let types =
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
        )
      #(module_path, types)
    })
  let fn_typed =
    list.filter_map(results, fn(pair) {
      let #(module_path, module_result) = pair
      case dict.get(index, module_path) {
        Ok(#(_gleam_path, module)) ->
          Ok(#(module_path, fn_typed_params_from_schemes(module_result, module)))
        Error(Nil) -> Error(Nil)
      }
    })
  typeinfo.from_modules(span_types, fn_typed)
}

// From girard's inferred top-level signatures, the set of function-typed
// parameter names for each function — including parameters with no syntactic
// `fn(...)` annotation, which the glance-only detection misses. A parameter is
// function-typed when its inferred type (positional in the function's `Fn`
// type) is itself a `Fn`.
fn fn_typed_params_from_schemes(
  module_result: girard.ModuleResult,
  module: glance.Module,
) -> Dict(String, Set(String)) {
  let function_map =
    list.fold(module.functions, dict.new(), fn(acc, definition) {
      dict.insert(acc, definition.definition.name, definition.definition)
    })
  list.fold(module_result.annotated.functions, dict.new(), fn(acc, entry) {
    let #(name, scheme) = entry
    case scheme.type_, dict.get(function_map, name) {
      girard_types.Fn(argument_types, _return), Ok(function) ->
        dict.insert(acc, name, fn_typed_names(function, argument_types))
      _, _ -> acc
    }
  })
}

// The names of `function`'s parameters whose inferred type (positional in
// `argument_types`) is itself a `Fn`.
fn fn_typed_names(
  function: glance.Function,
  argument_types: List(girard_types.Type),
) -> Set(String) {
  // Positional mapping is only sound when girard's `Fn` arity matches glance's
  // parameter count. `list.zip` would silently truncate a mismatch, so skip the
  // function entirely rather than map parameters to the wrong types.
  use <- bool.guard(
    when: list.length(function.parameters) != list.length(argument_types),
    return: set.new(),
  )
  list.zip(function.parameters, argument_types)
  |> list.filter_map(fn(pair) {
    let #(parameter, argument_type) = pair
    case argument_type, parameter.name {
      girard_types.Fn(_, _), glance.Named(parameter_name) -> Ok(parameter_name)
      _, _ -> Error(Nil)
    }
  })
  |> set.from_list()
}

// A girard `Resolver` that resolves graded's own project modules from `index`
// first (so non-`src` layouts like `test/fixtures` work), then falls through
// to girard's stock disk resolver for dependencies and stdlib under
// `build/packages`.
fn build_girard_resolver(
  index: Dict(String, #(String, glance.Module)),
) -> fn(String) -> Result(String, Nil) {
  let disk = girard.disk_resolver()
  fn(module_path) {
    case dict.get(index, module_path) {
      Ok(#(gleam_path, _module)) ->
        simplifile.read(gleam_path) |> result.replace_error(Nil)
      Error(Nil) -> disk(module_path)
    }
  }
}

// Build an index from dotted module name (`app/router`) to the parsed file.
// This is the set of *project* modules — every module name in this dict is
// a candidate dependency-graph node.
fn build_module_index(
  parsed: List(#(String, glance.Module)),
  directory: String,
) -> Dict(String, #(String, glance.Module)) {
  list.fold(parsed, dict.new(), fn(acc, entry) {
    let #(gleam_path, module) = entry
    let module_path = config.module_path_for_source(gleam_path, directory)
    dict.insert(acc, module_path, #(gleam_path, module))
  })
}

// For every project module, derive its set of project-internal imports.
// Imports of stdlib/dep modules (anything not in `index`) are filtered out
// — those are leaves with effects already resolved via the knowledge base
// and don't belong in the topological sort.
fn build_dependency_graph(
  index: Dict(String, #(String, glance.Module)),
) -> Dict(String, Set(String)) {
  dict.map_values(index, fn(_module_path, entry) {
    let #(_path, module) = entry
    let context = extract.build_import_context(module)
    context.aliases
    |> dict.values()
    |> list.filter(fn(imported) { dict.has_key(index, imported) })
    |> set.from_list()
  })
}

// Infer effects for a single module, write its cache file (with bare
// names), and return the new knowledge base + the module's *public*
// inferred annotations qualified with the module path. The caller
// accumulates the public annotations for the eventual spec file write.
fn infer_one_module(
  module: glance.Module,
  module_path: String,
  cache_dir: String,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: Dict(#(Int, Int), girard_types.Type),
  girard_fn_typed: Dict(String, Set(String)),
) -> Result(
  #(KnowledgeBase, List(EffectAnnotation), List(types.ReturnsAnnotation)),
  GradedError,
) {
  let #(inferred, returned_operators) =
    checker.infer_with_returns(
      module,
      module_path,
      knowledge_base,
      [],
      registry,
      module_types,
      girard_fn_typed,
    )

  let cache_path = filepath.join(cache_dir, module_path <> ".graded")

  // Skip the cache write when there's nothing to record. Saves an mkdir
  // syscall per stdlib-only module.
  use Nil <- result.try(case inferred {
    [] -> Ok(Nil)
    _ -> {
      let parent_directory = filepath.directory_name(cache_path)
      use Nil <- result.try(
        simplifile.create_directory_all(parent_directory)
        |> result.map_error(DirectoryCreateError(parent_directory, _)),
      )
      let cache_file = GradedFile(lines: list.map(inferred, AnnotationLine))
      write_graded_file(cache_path, cache_file)
    }
  })

  // Thread inferred effects, polymorphic param bounds, and returned-operator
  // signatures into the KB so later modules in the topo-sort pass can resolve
  // call sites targeting this module's functions.
  let new_kb =
    thread_inferred_into_kb(
      knowledge_base,
      inferred,
      returned_operators,
      module_path,
    )

  let public_names = public_function_names(module)
  let public_annotations =
    inferred
    |> list.filter(fn(ann) { set.contains(public_names, ann.function) })
    |> list.map(fn(ann) {
      EffectAnnotation(..ann, function: module_path <> "." <> ann.function)
    })
  // Public functions that return an operator — serialized as `returns` lines so
  // the signature crosses module/package boundaries.
  let public_returns =
    returned_operators
    |> dict.to_list()
    |> list.filter(fn(pair) { set.contains(public_names, pair.0) })
    |> list.map(fn(pair) {
      types.ReturnsAnnotation(
        function: module_path <> "." <> pair.0,
        operator: pair.1,
      )
    })

  Ok(#(new_kb, public_annotations, public_returns))
}

// Infer project modules in topological order, in memory, folding their
// effects, param bounds, and returned operators into `base_kb` — with existing
// (spec / dependency) entries taking priority, so committed effects are never
// overridden. This lets `check` resolve calls into project modules that haven't
// been `graded infer`-ed yet, without writing the cache. Falls back to
// `base_kb` unchanged when the import graph has a cycle (the real
// `graded infer` reports that error; `check` just degrades to spec-only).
fn infer_project_in_memory(
  base_kb: KnowledgeBase,
  index: Dict(String, #(String, glance.Module)),
  registry: SignatureRegistry,
  type_info: typeinfo.TypeInfo,
) -> KnowledgeBase {
  case topo.sort(build_dependency_graph(index)) {
    Error(_) -> base_kb
    Ok(sorted) ->
      list.fold(sorted, base_kb, fn(kb, module_path) {
        case dict.get(index, module_path) {
          Error(_) -> kb
          Ok(#(_gleam_path, module)) ->
            fold_inferred_module(kb, module, module_path, registry, type_info)
        }
      })
  }
}

// Infer one module against `kb` and fold its effects, param bounds, and
// returned operators (qualified by `module_path`) into the knowledge base, with
// existing entries winning. The per-module step of `infer_project_in_memory`.
fn fold_inferred_module(
  kb: KnowledgeBase,
  module: glance.Module,
  module_path: String,
  registry: SignatureRegistry,
  type_info: typeinfo.TypeInfo,
) -> KnowledgeBase {
  let #(inferred, returned_operators) =
    checker.infer_with_returns(
      module,
      module_path,
      kb,
      [],
      registry,
      typeinfo.for_module(type_info, module_path),
      typeinfo.fn_typed_for_module(type_info, module_path),
    )
  thread_inferred_into_kb(kb, inferred, returned_operators, module_path)
}

// Thread a module's freshly inferred effects, polymorphic param bounds, and
// returned-operator signatures (all qualified by `module_path`) into the
// knowledge base. Existing entries win.
fn thread_inferred_into_kb(
  knowledge_base: KnowledgeBase,
  inferred: List(EffectAnnotation),
  returned_operators: Dict(String, types.EffectTerm),
  module_path: String,
) -> KnowledgeBase {
  let #(effects_dict, params_dict, returns_dict) =
    qualified_inferred(inferred, returned_operators, module_path)
  fold_inferred_into_kb(knowledge_base, effects_dict, params_dict, returns_dict)
}

// Qualify a module's freshly inferred effects, polymorphic param bounds, and
// returned operators by `module_path`, producing the three `QualifiedName`-keyed
// maps the knowledge base is threaded with. Split from `thread_inferred_into_kb`
// so the path-dep inference loop can both fold the maps into its running KB and
// accumulate them for the caller without re-deriving them.
fn qualified_inferred(
  inferred: List(EffectAnnotation),
  returned_operators: Dict(String, types.EffectTerm),
  module_path: String,
) -> #(
  Dict(QualifiedName, types.EffectTerm),
  Dict(QualifiedName, List(types.ParamBound)),
  Dict(QualifiedName, types.EffectTerm),
) {
  let qualify = fn(function) { QualifiedName(module: module_path, function:) }
  let effects_dict =
    list.fold(inferred, dict.new(), fn(acc, ann) {
      dict.insert(acc, qualify(ann.function), ann.effects)
    })
  let params_dict =
    list.fold(inferred, dict.new(), fn(acc, ann) {
      case ann.params {
        [] -> acc
        params -> dict.insert(acc, qualify(ann.function), params)
      }
    })
  let returns_dict =
    dict.fold(returned_operators, dict.new(), fn(acc, function, op) {
      dict.insert(acc, qualify(function), op)
    })
  #(effects_dict, params_dict, returns_dict)
}

// Build a set of public function names from a parsed Gleam module.
fn public_function_names(module: glance.Module) -> set.Set(String) {
  list.fold(module.functions, set.new(), fn(acc, def) {
    case def.definition.publicity {
      glance.Public -> set.insert(acc, def.definition.name)
      glance.Private -> acc
    }
  })
}

// Write the project's spec file. Reads the existing spec (if any),
// preserves all `check`/`external`/`type` lines plus comments and blank
// lines, replaces the inferred `effects` lines with the freshly inferred
// public-function annotations, and writes the result back.
fn write_spec_file(
  spec_path: String,
  existing: GradedFile,
  inferred: List(EffectAnnotation),
  inferred_returns: List(types.ReturnsAnnotation),
) -> Result(Nil, GradedError) {
  let merged = annotation.merge_inferred(existing, inferred, inferred_returns)

  // create_directory_all is a no-op when the parent already exists, so it's
  // safe to call unconditionally — and necessary when the user has
  // configured a non-default spec_file in a subdirectory.
  let parent = filepath.directory_name(spec_path)
  use Nil <- result.try(case parent == "" || parent == "." {
    True -> Ok(Nil)
    False ->
      simplifile.create_directory_all(parent)
      |> result.map_error(DirectoryCreateError(parent, _))
  })
  write_graded_file(spec_path, merged)
}

// Group a parsed spec file's `check` annotations by their module path. Used
// during `run` to hand each source file only the checks that apply to it.
// The checker expects bare function names per module, so we strip the
// module qualifier from the grouped annotations.
fn checks_grouped_by_module(
  spec: GradedFile,
) -> Dict(String, List(EffectAnnotation)) {
  list.fold(annotation.extract_checks(spec), dict.new(), fn(acc, ann) {
    case annotation.split_qualified_name(ann.function) {
      Error(_) -> acc
      Ok(#(module, function)) -> {
        let bare = EffectAnnotation(..ann, function:)
        let existing = case dict.get(acc, module) {
          Ok(list) -> list
          Error(_) -> []
        }
        dict.insert(acc, module, [bare, ..existing])
      }
    }
  })
}

// Run the checker against one source file using the slice of `check`
// annotations from the spec file that mention this file's module.
fn check_one_file(
  gleam_path: String,
  module_path: String,
  module: glance.Module,
  module_checks: List(EffectAnnotation),
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: Dict(#(Int, Int), girard_types.Type),
  girard_fn_typed: Dict(String, Set(String)),
) -> CheckResult {
  let #(violations, warnings) =
    checker.check(
      module,
      module_path,
      module_checks,
      knowledge_base,
      registry,
      module_types,
      girard_fn_typed,
    )
  CheckResult(file: gleam_path, violations:, warnings:)
}

// Read the project's `[tools.graded]` config and return spec/cache paths
// already resolved relative to the project root. The "project root" is
// the directory containing `gleam.toml`:
//
// - When `directory == "src"` (the production case), project root is `.`
//   and gleam.toml lives at `./gleam.toml`.
// - Otherwise (tests against ad-hoc directories), the source directory
//   itself acts as the project root and gleam.toml is looked up there.
//
// Resolved paths are returned in the same `GradedConfig` shape so callers
// can use them as-is for I/O without further joining.
fn read_config(directory: String) -> Result(config.GradedConfig, GradedError) {
  let project_root = source_root_for(directory)
  let toml_path = filepath.join(project_root, "gleam.toml")
  use raw <- result.try(case config.read(toml_path) {
    Ok(cfg) -> Ok(cfg)
    // Missing gleam.toml: fall back to defaults. Malformed gleam.toml: error.
    Error(config.TomlReadError(..)) ->
      Ok(config.defaults_for(default_package_name(project_root)))
    Error(cause) -> Error(InvalidConfig(path: toml_path, cause:))
  })
  Ok(config.GradedConfig(
    package_name: raw.package_name,
    spec_file: resolve_path(project_root, raw.spec_file),
    cache_dir: resolve_path(project_root, raw.cache_dir),
  ))
}

// The Gleam project root: where dependency state lives — `build/packages`,
// `manifest.toml`, and the `gleam.toml` that lists path dependencies. Found by
// walking up from the source directory to the nearest ancestor holding a
// `gleam.toml`, so a source directory nested inside a project (e.g. a test
// fixture tree) inherits that project's installed dependencies rather than the
// process cwd's. Falls back to the source directory when no `gleam.toml` is
// found anywhere up the tree.
fn resolve_package_root(directory: String) -> String {
  let source_root = source_root_for(directory)
  find_gleam_toml_dir(source_root, source_root)
}

// The directory a source argument is rooted at. `src` is the production layout,
// whose root is the current directory; any other directory acts as its own
// root. Shared by spec/cache resolution (`read_config`) and the dependency-root
// walk-up so the two stay in step.
fn source_root_for(directory: String) -> String {
  case directory {
    "src" -> "."
    _ -> directory
  }
}

// Dependency `.graded` specs live under `<root>/build/packages/<dep>/`.
fn packages_dir(package_root: String) -> String {
  filepath.join(package_root, "build/packages")
}

// `manifest.toml` (installed dependency versions, for catalog selection) sits
// at the project root next to `gleam.toml`.
fn manifest_path(package_root: String) -> String {
  filepath.join(package_root, "manifest.toml")
}

fn find_gleam_toml_dir(dir: String, original: String) -> String {
  let dir = case dir {
    "" -> "."
    _ -> dir
  }
  case simplifile.is_file(filepath.join(dir, "gleam.toml")) {
    Ok(True) -> dir
    _ -> {
      let parent = case filepath.directory_name(dir) {
        "" -> "."
        other -> other
      }
      // `.` (and `/`) is a fixed point of `directory_name`, so `parent == dir`
      // always halts the walk — at which point no `gleam.toml` was found and we
      // fall back to the source dir.
      case parent == dir {
        True -> original
        False -> find_gleam_toml_dir(parent, original)
      }
    }
  }
}

// Join a path against a root, but leave it untouched if it's already
// absolute (starts with `/`) or if the root is `.` (so production paths
// stay short and unprefixed).
fn resolve_path(root: String, path: String) -> String {
  use <- bool.guard(
    when: string.starts_with(path, "/") || root == ".",
    return: path,
  )
  filepath.join(root, path)
}

fn default_package_name(project_root: String) -> String {
  // Used only when no gleam.toml is found: the project root's last path
  // segment, or "graded" when that's empty, "/", or ".".
  case filepath.base_name(project_root) {
    "" | "/" | "." -> "graded"
    name -> name
  }
}

fn read_spec(spec_path: String) -> GradedFile {
  case simplifile.read(spec_path) {
    Error(_) -> GradedFile(lines: [])
    Ok(content) ->
      case annotation.parse_file(content) {
        Ok(file) -> file
        Error(_) -> GradedFile(lines: [])
      }
  }
}

// For each path dependency declared in `gleam.toml`:
//
// 1. Try to load its spec file (via the dep's own `[tools.graded]`
//    config, defaulting to `<package_name>.graded`) and fold its
//    annotations into the knowledge base. This is the fast, intended
//    path: the dep author already ran `graded infer`, committed the
//    spec file, and the consumer just reads it.
//
// 2. If the dep has no spec file, fall back to inferring from source via
//    `infer_path_dep` so path deps without graded set up still work.
//    Cross-path-dep imports are not currently merged into a single graph
//    — each dep is processed sequentially.
fn enrich_with_path_deps(
  knowledge_base: KnowledgeBase,
  package_root: String,
) -> KnowledgeBase {
  let path_deps =
    effects.parse_path_dependencies(filepath.join(package_root, "gleam.toml"))
  list.fold(path_deps, knowledge_base, fn(kb, dep) {
    let #(name, dep_path) = dep
    // Path dependency locations are declared relative to the project root,
    // except an absolute `path`, which `resolve_path` leaves untouched.
    let resolved_dep_path = resolve_path(package_root, dep_path)
    let spec_path = config.spec_file_for(resolved_dep_path, name)
    case simplifile.is_file(spec_path) {
      Ok(True) -> {
        let #(effs, params, returns) =
          effects.load_dep_spec(resolved_dep_path, name)
        fold_inferred_into_kb(kb, effs, params, returns)
      }
      _ ->
        case infer_path_dep(resolved_dep_path, kb) {
          Error(Nil) -> kb
          Ok(#(effs, params, returns)) ->
            fold_inferred_into_kb(kb, effs, params, returns)
        }
    }
  })
}

// Build a signature registry from every path dependency's `src/` directory.
// Path deps live at their declared `path`, not under `build/packages`, so
// `load_from_packages_dir` never sees them — without this their cross-module
// callees lack the parameter-position info that positional (unlabeled) argument
// matching needs to bind effect variables at the call site.
fn path_dep_registry(package_root: String) -> SignatureRegistry {
  effects.parse_path_dependencies(filepath.join(package_root, "gleam.toml"))
  |> list.fold(signatures.empty(), fn(acc, dep) {
    let #(_name, dep_path) = dep
    let resolved_dep_path = resolve_path(package_root, dep_path)
    signatures.merge(
      acc,
      signatures.load_from_source_dir(resolved_dep_path <> "/src"),
    )
  })
}

// Apply three `QualifiedName`-keyed inferred maps — effects, polymorphic param
// bounds, and returned-operator signatures — to the knowledge base. The shared
// tail of `thread_inferred_into_kb` and the path-dep loaders: effects alone
// would leave a higher-order callee's bound unloaded, so its callback's effect
// variable would leak unsubstituted into every caller. Existing entries win.
fn fold_inferred_into_kb(
  knowledge_base: KnowledgeBase,
  effs: Dict(QualifiedName, types.EffectTerm),
  params: Dict(QualifiedName, List(types.ParamBound)),
  returns: Dict(QualifiedName, types.EffectTerm),
) -> KnowledgeBase {
  knowledge_base
  |> effects.with_inferred(effs)
  |> effects.with_inferred_params(params)
  |> effects.with_inferred_returned_operators(returns)
}

/// Build the dependency-graph index for a single path dep, topo-sort it,
/// then infer every module in dependency order. Returns the union of all
/// inferred effects, polymorphic param bounds, and returned-operator
/// signatures keyed by `QualifiedName` so the caller can fold them into the
/// global knowledge base. Errors are swallowed (returned as `Error(Nil)`) to
/// preserve the existing tolerance: a malformed dep shouldn't break the whole
/// project.
///
/// Exposed (pub) primarily so tests can exercise the topological-order path
/// inference on a temporary directory tree without going through
/// `gleam.toml` resolution. Production callers go through
/// `enrich_with_path_deps` which reads `gleam.toml` to discover dep paths.
pub fn infer_path_dep(
  dep_path: String,
  base_kb: KnowledgeBase,
) -> Result(
  #(
    Dict(QualifiedName, types.EffectTerm),
    Dict(QualifiedName, List(types.ParamBound)),
    Dict(QualifiedName, types.EffectTerm),
  ),
  Nil,
) {
  let source_dir = dep_path <> "/src"
  let gleam_files = case simplifile.get_files(source_dir) {
    Ok(found) ->
      list.filter(found, fn(path) { string.ends_with(path, ".gleam") })
    Error(_) -> []
  }

  let entries =
    list.filter_map(gleam_files, fn(gleam_path) {
      use module <- result.try(
        read_and_parse_gleam(gleam_path) |> result.map_error(fn(_) { Nil }),
      )
      let module_path = config.module_path_for_source(gleam_path, source_dir)
      // Path-dep checks come from the dep's spec file (loaded by
      // enrich_with_path_deps), not from per-module files. Inference here
      // only needs the parsed module.
      Ok(#(module_path, module, []))
    })

  let index =
    list.fold(entries, dict.new(), fn(acc, entry) {
      let #(module_path, module, checks) = entry
      dict.insert(acc, module_path, #(module, checks))
    })

  let graph =
    dict.map_values(index, fn(_module_path, entry) {
      let #(module, _checks) = entry
      let context = extract.build_import_context(module)
      context.aliases
      |> dict.values()
      |> list.filter(fn(imported) { dict.has_key(index, imported) })
      |> set.from_list()
    })

  // A registry covering the dep's own modules, so a cross-module call between
  // them (`b.run` calling `a.apply(cb)`) matches the callee's bound by parameter
  // position during inference — exactly as the project registry does for the
  // project's own modules. Built from the already-parsed `index`, not re-read.
  let registry =
    dict.fold(index, signatures.empty(), fn(acc, module_path, entry) {
      let #(module, _checks) = entry
      signatures.merge(acc, signatures.from_glance_module(module_path, module))
    })

  use sorted <- result.try(topo.sort(graph) |> result.map_error(fn(_) { Nil }))
  let #(effs, params, returns, _final_kb) =
    list.fold(
      sorted,
      #(dict.new(), dict.new(), dict.new(), base_kb),
      fn(state, module_path) {
        infer_path_dep_module(state, module_path, index, registry)
      },
    )
  Ok(#(effs, params, returns))
}

fn infer_path_dep_module(
  state: #(
    Dict(QualifiedName, types.EffectTerm),
    Dict(QualifiedName, List(types.ParamBound)),
    Dict(QualifiedName, types.EffectTerm),
    KnowledgeBase,
  ),
  module_path: String,
  index: Dict(String, #(glance.Module, List(types.EffectAnnotation))),
  registry: SignatureRegistry,
) -> #(
  Dict(QualifiedName, types.EffectTerm),
  Dict(QualifiedName, List(types.ParamBound)),
  Dict(QualifiedName, types.EffectTerm),
  KnowledgeBase,
) {
  let #(eff_acc, param_acc, returns_acc, kb) = state
  case dict.get(index, module_path) {
    Error(_) -> state
    Ok(#(module, checks)) -> {
      // Path-dep inference skips girard in v1 (cost/benefit): pass no types.
      let #(annotations, returned_operators) =
        checker.infer_with_returns(
          module,
          module_path,
          kb,
          checks,
          registry,
          dict.new(),
          dict.new(),
        )
      // Qualify the module's results once, then both fold them into the dep's
      // own KB (so later modules in its topo order resolve calls into this one)
      // and accumulate them for the caller.
      let #(module_effects, module_params, module_returns) =
        qualified_inferred(annotations, returned_operators, module_path)
      let new_kb =
        fold_inferred_into_kb(kb, module_effects, module_params, module_returns)
      #(
        dict.merge(eff_acc, module_effects),
        dict.merge(param_acc, module_params),
        dict.merge(returns_acc, module_returns),
        new_kb,
      )
    }
  }
}

fn target_directory(arguments: List(String)) -> String {
  case arguments {
    [directory, ..] -> directory
    [] -> "src"
  }
}

fn run_check(directory: String) -> Nil {
  case run(directory) {
    Ok(results) -> {
      let violations =
        list.flat_map(results, fn(check_result) { check_result.violations })
      let warnings =
        list.flat_map(results, fn(check_result) { check_result.warnings })
      list.each(results, print_warnings)
      case warnings {
        [] -> Nil
        _ ->
          io.println(
            "graded: " <> int.to_string(list.length(warnings)) <> " warning(s)",
          )
      }
      case violations {
        [] -> io.println("graded: all checks passed")
        _ -> {
          list.each(results, print_violations)
          io.println(
            "\ngraded: "
            <> int.to_string(list.length(violations))
            <> " violation(s) found",
          )
          halt(1)
        }
      }
    }
    Error(error) -> {
      io.println_error("graded: error: " <> format_error(error))
      halt(1)
    }
  }
}

fn find_gleam_files(directory: String) -> Result(List(String), GradedError) {
  simplifile.get_files(directory)
  |> result.map_error(DirectoryReadError(directory, _))
  |> result.map(list.filter(_, fn(path) { string.ends_with(path, ".gleam") }))
}

fn read_and_parse_gleam(
  gleam_path: String,
) -> Result(glance.Module, GradedError) {
  use source <- result.try(
    simplifile.read(gleam_path)
    |> result.map_error(FileReadError(gleam_path, _)),
  )
  glance.module(source)
  |> result.map_error(GleamParseError(gleam_path, _))
}

fn write_graded_file(
  path: String,
  graded_file: GradedFile,
) -> Result(Nil, GradedError) {
  simplifile.write(path, annotation.format_file(graded_file))
  |> result.map_error(FileWriteError(path, _))
}

fn format_error(error: GradedError) -> String {
  case error {
    DirectoryReadError(path, _) -> "Could not read directory: " <> path
    FileReadError(path, _) -> "Could not read: " <> path
    FileWriteError(path, _) -> "Could not write: " <> path
    DirectoryCreateError(path, _) -> "Could not create directory: " <> path
    GleamParseError(path, _) -> "Could not parse: " <> path
    GradedParseError(path, _) -> "Parse error in .graded file for: " <> path
    InvalidConfig(path, _) -> "Invalid gleam.toml: " <> path
    FormatCheckFailed(paths:) ->
      "Unformatted .graded files:\n"
      <> string.join(list.map(paths, fn(path) { "  " <> path }), "\n")
    CyclicImports(modules:) ->
      "Cyclic project imports detected (this should be unreachable — Gleam disallows circular imports):\n"
      <> string.join(list.map(modules, fn(m) { "  " <> m }), "\n")
  }
}

fn print_violations(check_result: CheckResult) -> Nil {
  list.each(check_result.violations, fn(violation) {
    print_violation(check_result.file, violation)
  })
}

fn print_violation(file: String, violation: Violation) -> Nil {
  let base =
    file
    <> ": "
    <> violation.function
    <> " calls "
    <> violation.call.module
    <> "."
    <> violation.call.function
    <> " with effects "
    <> effects.format_effect_set(violation.actual)
    <> " but declared "
    <> effects.format_effect_set(violation.declared)
  // When the actual set still contains effect variables, the substitution
  // couldn't bind them (e.g. caller's own param has no declared bound).
  // Hint at the fix instead of letting the user puzzle over `[e_xxx]`.
  let hint = case types.has_variables(violation.actual) {
    True ->
      "\n  hint: actual effects contain unresolved variables; add a `check "
      <> violation.function
      <> "(<param>: [...])` bound, or pass a function reference / constructor"
      <> " whose effects are known"
    False -> ""
  }
  io.println(base <> hint)
}

fn print_warnings(check_result: CheckResult) -> Nil {
  list.each(check_result.warnings, fn(warning) {
    print_warning(check_result.file, warning)
  })
}

fn print_warning(file: String, warning: Warning) -> Nil {
  case warning {
    UntrackedEffectWarning(function:, reference:, effects: effs, ..) ->
      io.println(
        file
        <> ": warning: "
        <> function
        <> " passes "
        <> reference.module
        <> "."
        <> reference.function
        <> " as a value — its effects "
        <> effects.format_effect_set(effs)
        <> " won't be tracked",
      )
    UnmatchedFieldBoundWarning(function:, field_path:, receiver_is_param:) -> {
      let cause = case receiver_is_param {
        True -> " matches no field call in its body — check the path"
        // A non-parameter receiver can be traced to a construction site, so the
        // call may exist but resolve through value provenance, shadowing the bound.
        False ->
          " matches no field call in its body — check the path,"
          <> " or the receiver is traced to a construction site and resolved"
          <> " through value provenance (field bounds apply only to untraceable"
          <> " receivers)"
      }
      io.println(
        file
        <> ": warning: field bound "
        <> field_path
        <> " on "
        <> function
        <> cause,
      )
    }
    UnmatchedParamBoundWarning(function:, param:) ->
      io.println(
        file
        <> ": warning: parameter bound "
        <> param
        <> " on "
        <> function
        <> " names no parameter of the function — check the name",
      )
  }
}

@external(erlang, "erlang", "halt")
@external(javascript, "./graded_ffi.mjs", "halt")
fn halt(code: Int) -> Nil

// Read all of standard input to EOF as a single string.
@external(erlang, "graded_ffi", "read_stdin")
@external(javascript, "./graded_ffi.mjs", "read_stdin")
fn read_stdin() -> String
