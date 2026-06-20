import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded/internal/annotation
import graded/internal/config
import graded/internal/effect_term
import graded/internal/types.{
  type ArgumentValue, type EffectAnnotation, type EffectSet, type EffectTerm,
  type ExternalAnnotation, type ParamBound, type QualifiedName,
  type TypeFieldAnnotation, type TypeFieldEffect, Check, ConstructorRef, Effects,
  FunctionExternal, FunctionRef, ModuleExternal, QualifiedName, TypeFieldEffect,
}
import simplifile
import tom

pub type EffectLookup {
  Known(EffectTerm)
  Unknown
}

// Bundles all effect knowledge: dependency + catalog, precomputed for fast lookup.
pub type KnowledgeBase {
  KnowledgeBase(
    all_effects: Dict(QualifiedName, EffectTerm),
    param_bounds: Dict(QualifiedName, List(ParamBound)),
    // Keyed by #(defining module, type name, field). The module qualifies the
    // type so same-named types in different modules don't collide. Bare
    // (cache/unqualified) annotations use "" — matched by the syntactic-receiver
    // fallback, which can't determine the module.
    type_fields: Dict(#(String, String, String), TypeFieldEffect),
    // For a function that *returns a function* (an operator-shaped result), the
    // lifted effect-operator of its return value — so a consumer
    // `let h = f(); with(h)` resolves `h` instead of going `[Unknown]`. Computed
    // at the producer's inference time (where its module's private callees are
    // in scope) and threaded forward by the topological pass.
    returned_operators: Dict(QualifiedName, EffectTerm),
    // Package-wide factory signatures, keyed by `#(defining module, function)`:
    // each constructor field a function wires to one of its parameters, mapped
    // to that parameter's position. Lets a let-bound *cross-module* factory call
    // bind its result's fields like a direct construction. (Same-module
    // factories are derived locally from the module, like constructors.)
    factories: Dict(#(String, String), Dict(String, Int)),
    pure_modules: Set(String),
  )
}

// Build a knowledge base by scanning dependency .graded files
// and loading versioned catalog files from priv/catalog/.
pub fn load_knowledge_base(packages_directory: String) -> KnowledgeBase {
  let #(dep_effects, dep_params, dep_returns) =
    load_dependencies(packages_directory)
  let catalog_dir = find_catalog_directory()
  let #(cat_effects, cat_pure, cat_params) =
    load_catalog(catalog_dir, "manifest.toml")
  KnowledgeBase(
    // Dependency entries win on a clash: dict.merge keeps its second argument.
    all_effects: dict.merge(cat_effects, dep_effects),
    param_bounds: dict.merge(cat_params, dep_params),
    type_fields: dict.new(),
    returned_operators: dep_returns,
    factories: dict.new(),
    pure_modules: cat_pure,
  )
}

// Build a knowledge base from the catalog only (no dependency scanning).
pub fn empty_knowledge_base() -> KnowledgeBase {
  let catalog_dir = find_catalog_directory()
  let #(cat_effects, cat_pure, cat_params) =
    load_catalog(catalog_dir, "manifest.toml")
  KnowledgeBase(
    all_effects: cat_effects,
    param_bounds: cat_params,
    type_fields: dict.new(),
    returned_operators: dict.new(),
    factories: dict.new(),
    pure_modules: cat_pure,
  )
}

// Look up a type field's resolved effect (with any polymorphic bounds/source).
// `module` is the type's defining module (or "" for an unqualified lookup).
// `Error(Nil)` when the field is not in the registry.
pub fn lookup_type_field(
  knowledge_base: KnowledgeBase,
  module: String,
  type_name: String,
  field: String,
) -> Result(TypeFieldEffect, Nil) {
  dict.get(knowledge_base.type_fields, #(module, type_name, field))
}

// Merge hand-written type field annotations into a knowledge base. These carry
// no polymorphic bounds (a hand-written `type Foo.field : [...]` is a concrete
// budget), so they store empty bounds and no source. A spec-qualified
// annotation (`type myapp.Foo.field`) keys by its module; a bare one by "".
pub fn with_type_fields(
  knowledge_base: KnowledgeBase,
  type_fields: List(TypeFieldAnnotation),
) -> KnowledgeBase {
  let merged =
    list.fold(
      type_fields,
      knowledge_base.type_fields,
      fn(accumulator, type_field) {
        let module = case type_field.module {
          Some(module) -> module
          None -> ""
        }
        dict.insert(
          accumulator,
          #(module, type_field.type_name, type_field.field),
          TypeFieldEffect(type_field.effects, [], None),
        )
      },
    )
  KnowledgeBase(..knowledge_base, type_fields: merged)
}

// Merge inferred type fields (from constructor sites) into a knowledge base.
// Each entry is `#(#(module, type_name, field), TypeFieldEffect)` and may carry
// the wired function's bounds + source for variable substitution at field
// calls. Applied before `with_type_fields(spec)` so hand-written lines win.
pub fn with_inferred_type_fields(
  knowledge_base: KnowledgeBase,
  inferred: List(#(#(String, String, String), TypeFieldEffect)),
) -> KnowledgeBase {
  KnowledgeBase(
    ..knowledge_base,
    type_fields: dict.merge(
      knowledge_base.type_fields,
      dict.from_list(inferred),
    ),
  )
}

// Merge external annotations into a knowledge base.
// Module-level externals mark the whole module as pure.
// Function-level externals are added to all_effects.
pub fn with_externals(
  knowledge_base: KnowledgeBase,
  externals: List(ExternalAnnotation),
) -> KnowledgeBase {
  let #(effect_map, pure_set) =
    list.fold(
      externals,
      #(knowledge_base.all_effects, knowledge_base.pure_modules),
      fn(accumulator, external_annotation) {
        let #(effect_map, pure_set) = accumulator
        case external_annotation.target {
          ModuleExternal -> #(
            effect_map,
            set.insert(pure_set, external_annotation.module),
          )
          FunctionExternal(function) -> #(
            dict.insert(
              effect_map,
              QualifiedName(external_annotation.module, function),
              effect_term.from_effect_set(external_annotation.effects),
            ),
            pure_set,
          )
        }
      },
    )
  KnowledgeBase(
    ..knowledge_base,
    all_effects: effect_map,
    pure_modules: pure_set,
  )
}

// Look up the effect set for a qualified function name.
pub fn lookup(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> EffectLookup {
  case dict.get(knowledge_base.all_effects, name) {
    Ok(effect_set) -> Known(effect_set)
    Error(Nil) ->
      case set.contains(knowledge_base.pure_modules, name.module) {
        True -> Known(effect_term.pure())
        False -> Unknown
      }
  }
}

// Look up effects as an `EffectTerm`, returning `[Unknown]` for unrecognized
// functions. The term may be second-order (carry operator applications) for
// higher-order functions; callers reduce it at the resolution boundary.
pub fn lookup_effects(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> EffectTerm {
  case lookup(knowledge_base, name) {
    Known(effect_term) -> effect_term
    Unknown -> effect_term.unknown()
  }
}

// The effect of a value wired into a constructor field (Stage C). A function
// reference resolves via the knowledge base; a nested constructor is pure;
// anything else (a local identifier, an inline expression) is `[Unknown]`,
// since we can't statically resolve it here.
//
// A function reference may be effect-polymorphic, returning a `Polymorphic`
// set with free variables. Those variables are bound at the field-call site by
// `resolve_field_call` (using the bounds captured in the field's
// `TypeFieldEffect`), or collapse to `[Unknown]` if no argument resolves them.
pub fn argument_value_effects(
  knowledge_base: KnowledgeBase,
  value: ArgumentValue,
) -> EffectTerm {
  case value {
    FunctionRef(name:) -> lookup_effects(knowledge_base, name)
    ConstructorRef -> effect_term.pure()
    _ -> effect_term.unknown()
  }
}

// Look up a function's parameter bounds. Used during call-site
// substitution to know which parameters of the callee are effect-typed
// so arguments at those positions can bind effect variables.
pub fn lookup_param_bounds(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> List(types.ParamBound) {
  case dict.get(knowledge_base.param_bounds, name) {
    Ok(bounds) -> bounds
    Error(Nil) -> []
  }
}

// Format an effect set for display: [] for empty, [_] for wildcard, [A, B]
// sorted. Delegates to `annotation.format_effect_set` so diagnostics and the
// on-disk spec format share one renderer.
pub fn format_effect_set(effect_set: EffectSet) -> String {
  annotation.format_effect_set(effect_set)
}

// Parse gleam.toml to find path dependencies.
// Returns a list of #(package_name, source_directory) pairs.
pub fn parse_path_dependencies(
  gleam_toml_path: String,
) -> List(#(String, String)) {
  let parsed = {
    use content <- result.try(
      simplifile.read(gleam_toml_path) |> result.map_error(fn(_) { Nil }),
    )
    use toml <- result.try(
      tom.parse(content) |> result.map_error(fn(_) { Nil }),
    )
    use deps <- result.try(
      tom.get_table(toml, ["dependencies"]) |> result.map_error(fn(_) { Nil }),
    )
    Ok(
      dict.fold(deps, [], fn(acc, name, value) {
        case value {
          tom.InlineTable(table) ->
            case tom.get_string(table, ["path"]) {
              Ok(path) -> [#(name, path), ..acc]
              Error(_) -> acc
            }
          _ -> acc
        }
      }),
    )
  }
  result.unwrap(parsed, [])
}

// Load inferred effects from a package's spec file. The spec file uses
// module-qualified function names (e.g. `myapp/router.handle`) so each
// `effects` annotation maps directly to a `QualifiedName` without needing
// to know which file it came from. Returns an empty dict when the spec
// file is missing or unparseable.
pub fn load_spec_effects(spec_path: String) -> Dict(QualifiedName, EffectTerm) {
  case read_spec_annotations(spec_path) {
    Error(_) -> dict.new()
    Ok(annotations) -> fold_spec_effects(annotations)
  }
}

// Same as `load_spec_effects` but takes an already-parsed GradedFile,
// avoiding a second read+parse when the caller already has the spec file
// in hand.
pub fn load_spec_effects_from_file(
  file: types.GradedFile,
) -> Dict(QualifiedName, EffectTerm) {
  fold_spec_effects(annotation.extract_annotations(file))
}

fn fold_spec_effects(
  annotations: List(EffectAnnotation),
) -> Dict(QualifiedName, EffectTerm) {
  list.fold(annotations, dict.new(), fn(acc, ann) {
    case ann.kind {
      Effects ->
        case annotation.split_qualified_name(ann.function) {
          Ok(#(module, function)) ->
            dict.insert(acc, QualifiedName(module:, function:), ann.effects)
          Error(_) -> acc
        }
      Check -> acc
    }
  })
}

fn read_spec_annotations(
  spec_path: String,
) -> Result(List(EffectAnnotation), Nil) {
  use file <- result.try(read_spec_file(spec_path))
  Ok(annotation.extract_annotations(file))
}

fn read_spec_file(spec_path: String) -> Result(types.GradedFile, Nil) {
  use content <- result.try(
    simplifile.read(spec_path) |> result.replace_error(Nil),
  )
  annotation.parse_file(content) |> result.replace_error(Nil)
}

// Build a returned-operator map (qualified name → operator) from a parsed
// spec's `returns` lines. Used to load the project spec during `check`.
pub fn load_spec_returns_from_file(
  file: types.GradedFile,
) -> Dict(QualifiedName, EffectTerm) {
  fold_spec_returns(annotation.extract_returns(file))
}

fn fold_spec_returns(
  returns: List(types.ReturnsAnnotation),
) -> Dict(QualifiedName, EffectTerm) {
  list.fold(returns, dict.new(), fn(acc, returns) {
    case annotation.split_qualified_name(returns.function) {
      Ok(#(module, function)) ->
        dict.insert(acc, QualifiedName(module:, function:), returns.operator)
      Error(_) -> acc
    }
  })
}

// Merge inferred effects into a knowledge base.
// Existing entries in the knowledge base take priority.
pub fn with_inferred(
  knowledge_base: KnowledgeBase,
  inferred: Dict(QualifiedName, EffectTerm),
) -> KnowledgeBase {
  let merged = dict.merge(inferred, knowledge_base.all_effects)
  KnowledgeBase(..knowledge_base, all_effects: merged)
}

// Merge inferred param bounds into a knowledge base. Used so that
// call-site substitution can resolve effect variables for functions
// inferred earlier in the topo-sort pass.
// Existing entries take priority.
pub fn with_inferred_params(
  knowledge_base: KnowledgeBase,
  inferred: Dict(QualifiedName, List(types.ParamBound)),
) -> KnowledgeBase {
  let merged = dict.merge(inferred, knowledge_base.param_bounds)
  KnowledgeBase(..knowledge_base, param_bounds: merged)
}

// Merge inferred returned-operator signatures into a knowledge base, so a
// downstream module's `let h = producer(); with(h)` can resolve `h` to the
// operator the producer returns. Existing entries take priority.
pub fn with_inferred_returned_operators(
  knowledge_base: KnowledgeBase,
  inferred: Dict(QualifiedName, EffectTerm),
) -> KnowledgeBase {
  let merged = dict.merge(inferred, knowledge_base.returned_operators)
  KnowledgeBase(..knowledge_base, returned_operators: merged)
}

// Attach the package-wide factory map (keyed by `#(module, function)`), so a
// let-bound cross-module factory call binds its result's fields. Replaces any
// existing map (it's computed once per run).
pub fn with_factories(
  knowledge_base: KnowledgeBase,
  factories: Dict(#(String, String), Dict(String, Int)),
) -> KnowledgeBase {
  KnowledgeBase(..knowledge_base, factories:)
}

// The package-wide factory map, for threading into a module's extraction
// context as its cross-module factories.
pub fn factories(
  knowledge_base: KnowledgeBase,
) -> Dict(#(String, String), Dict(String, Int)) {
  knowledge_base.factories
}

// Look up the operator a function returns, if known. `Error(Nil)` when the
// callee doesn't return a (tracked) operator.
pub fn lookup_returned_operator(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Result(EffectTerm, Nil) {
  dict.get(knowledge_base.returned_operators, name)
}

// PRIVATE

// For each installed package, locate its spec file via the package's own
// `[tools.graded]` config (defaulting to `<package_name>.graded`), then read
// and parse it *once*, folding its qualified `effects`/`check` annotations
// into the global effect/param maps and its `returns` lines into the
// returned-operator map. Packages with no spec file are silently skipped —
// same fail-soft semantics as the catalog and the old per-module reader.
fn load_dependencies(
  packages_directory: String,
) -> #(
  Dict(QualifiedName, EffectTerm),
  Dict(QualifiedName, List(ParamBound)),
  Dict(QualifiedName, EffectTerm),
) {
  let entries = case simplifile.read_directory(packages_directory) {
    Ok(found) -> found
    Error(_) -> []
  }
  list.fold(
    entries,
    #(dict.new(), dict.new(), dict.new()),
    fn(acc, package_name) {
      let #(effect_map, param_map, returns_map) = acc
      let dep_root = packages_directory <> "/" <> package_name
      case read_spec_file(config.spec_file_for(dep_root, package_name)) {
        Error(_) -> acc
        Ok(file) -> {
          let #(new_effects, new_params) =
            list.fold(
              annotation.extract_annotations(file),
              #(effect_map, param_map),
              fold_qualified_annotation,
            )
          let new_returns =
            dict.merge(returns_map, load_spec_returns_from_file(file))
          #(new_effects, new_params, new_returns)
        }
      }
    },
  )
}

fn fold_qualified_annotation(
  accumulator: #(
    Dict(QualifiedName, EffectTerm),
    Dict(QualifiedName, List(ParamBound)),
  ),
  ann: EffectAnnotation,
) -> #(Dict(QualifiedName, EffectTerm), Dict(QualifiedName, List(ParamBound))) {
  let #(effect_map, param_map) = accumulator
  case annotation.split_qualified_name(ann.function) {
    Error(_) -> accumulator
    Ok(#(module, function)) -> {
      let qualified_name = QualifiedName(module:, function:)
      let new_effect_map = case ann.kind {
        Effects -> dict.insert(effect_map, qualified_name, ann.effects)
        Check -> effect_map
      }
      // Both `effects` (auto-inferred polymorphic) and `check`
      // (user-declared) annotations can carry param bounds; store
      // them all so call-site substitution can resolve variables.
      let new_param_map = case ann.params {
        [] -> param_map
        params -> dict.insert(param_map, qualified_name, params)
      }
      #(new_effect_map, new_param_map)
    }
  }
}

fn find_catalog_directory() -> String {
  let installed = "build/packages/graded/priv/catalog"
  case simplifile.is_directory(installed) {
    Ok(True) -> installed
    _ -> "priv/catalog"
  }
}

type CatalogAcc {
  CatalogAcc(
    ext_effects: Dict(QualifiedName, EffectTerm),
    pure_mods: Set(String),
    poly_effects: Dict(QualifiedName, EffectTerm),
    poly_params: Dict(QualifiedName, List(ParamBound)),
  )
}

fn load_catalog(
  catalog_dir: String,
  manifest_path: String,
) -> #(
  Dict(QualifiedName, EffectTerm),
  Set(String),
  Dict(QualifiedName, List(ParamBound)),
) {
  let installed_versions = parse_manifest_versions(manifest_path)
  let catalog_files = case simplifile.get_files(catalog_dir) {
    Ok(files) ->
      list.filter(files, fn(file) { string.ends_with(file, ".graded") })
    Error(_) -> []
  }
  let selected = resolve_catalog_files(catalog_files, installed_versions)
  let initial = CatalogAcc(dict.new(), set.new(), dict.new(), dict.new())
  let acc = list.fold(selected, initial, fold_catalog_file)
  // Explicit `effects` annotations in the catalog take precedence over the
  // module-level `external effects` pure markers.
  let all_effects = dict.merge(acc.ext_effects, acc.poly_effects)
  #(all_effects, acc.pure_mods, acc.poly_params)
}

// Fold one catalog file into the accumulator. `external effects` lines
// feed module-level pure markers and specific function effects; `effects`
// lines with param bounds feed polymorphic higher-order entries. Files
// that fail to read or parse are silently skipped.
fn fold_catalog_file(acc: CatalogAcc, file_path: String) -> CatalogAcc {
  case simplifile.read(file_path) {
    Error(_) -> acc
    Ok(content) ->
      case annotation.parse_file(content) {
        Error(_) -> acc
        Ok(graded_file) -> {
          let kb =
            with_externals(
              KnowledgeBase(
                all_effects: acc.ext_effects,
                param_bounds: dict.new(),
                type_fields: dict.new(),
                returned_operators: dict.new(),
                factories: dict.new(),
                pure_modules: acc.pure_mods,
              ),
              annotation.extract_externals(graded_file),
            )
          let #(poly_effects, poly_params) =
            list.fold(
              annotation.extract_annotations(graded_file),
              #(acc.poly_effects, acc.poly_params),
              fold_qualified_annotation,
            )
          CatalogAcc(
            ext_effects: kb.all_effects,
            pure_mods: kb.pure_modules,
            poly_effects:,
            poly_params:,
          )
        }
      }
  }
}

fn resolve_catalog_files(
  catalog_files: List(String),
  installed_versions: Dict(String, String),
) -> List(String) {
  // Parse filenames: "path/to/gleam_stdlib@0.70.0.graded" → #("gleam_stdlib", #(0,70,0), path)
  let parsed =
    list.filter_map(catalog_files, fn(path) {
      let filename =
        path
        |> string.split("/")
        |> list.last()
        |> result.unwrap("")
        |> string.replace(".graded", "")
      case string.split(filename, "@") {
        [package, version] -> Ok(#(package, parse_semver(version), path))
        _ -> Error(Nil)
      }
    })

  // Group by package name
  let grouped =
    list.fold(parsed, dict.new(), fn(accumulator, entry) {
      let #(package, version, path) = entry
      let existing = dict.get(accumulator, package) |> result.unwrap([])
      dict.insert(accumulator, package, [#(version, path), ..existing])
    })

  // For each installed package, pick best catalog version
  dict.fold(grouped, [], fn(selected, package, versions) {
    case dict.get(installed_versions, package) {
      Error(Nil) -> selected
      Ok(installed_str) -> {
        let installed = parse_semver(installed_str)
        let best = pick_best_version(versions, installed)
        case best {
          Ok(path) -> [path, ..selected]
          Error(Nil) -> selected
        }
      }
    }
  })
}

pub fn pick_best_version(
  versions: List(#(#(Int, Int, Int), String)),
  installed: #(Int, Int, Int),
) -> Result(String, Nil) {
  // Pick highest version ≤ installed; if none, pick highest available
  let eligible =
    list.filter(versions, fn(version) { semver_lte(version.0, installed) })
    |> list.sort(fn(left, right) { compare_semver(right.0, left.0) })
  case eligible {
    [best, ..] -> Ok(best.1)
    [] ->
      // No entry ≤ installed: fall back to the highest available version.
      case
        list.sort(versions, fn(left, right) { compare_semver(right.0, left.0) })
      {
        [best, ..] -> Ok(best.1)
        [] -> Error(Nil)
      }
  }
}

// Parse a `major.minor.patch` string into a comparable tuple. Non-numeric
// components (e.g. a `-rc1` suffix) parse as `0`, so `1.2.0-rc1` reads as
// `#(1, 2, 0)`.
pub fn parse_semver(version: String) -> #(Int, Int, Int) {
  case string.split(version, ".") {
    [major, minor, patch] -> #(
      int.parse(major) |> result.unwrap(0),
      int.parse(minor) |> result.unwrap(0),
      int.parse(patch) |> result.unwrap(0),
    )
    [major, minor] -> #(
      int.parse(major) |> result.unwrap(0),
      int.parse(minor) |> result.unwrap(0),
      0,
    )
    _ -> #(0, 0, 0)
  }
}

pub fn semver_lte(left: #(Int, Int, Int), right: #(Int, Int, Int)) -> Bool {
  compare_semver(left, right) != order.Gt
}

pub fn compare_semver(
  left: #(Int, Int, Int),
  right: #(Int, Int, Int),
) -> order.Order {
  case int.compare(left.0, right.0) {
    order.Eq ->
      case int.compare(left.1, right.1) {
        order.Eq -> int.compare(left.2, right.2)
        other -> other
      }
    other -> other
  }
}

fn parse_manifest_versions(manifest_path: String) -> Dict(String, String) {
  let parsed = {
    use content <- result.try(
      simplifile.read(manifest_path) |> result.map_error(fn(_) { Nil }),
    )
    use toml <- result.try(
      tom.parse(content) |> result.map_error(fn(_) { Nil }),
    )
    use packages <- result.try(
      tom.get_array(toml, ["packages"]) |> result.map_error(fn(_) { Nil }),
    )
    Ok(
      list.fold(packages, dict.new(), fn(accumulator, package) {
        case package {
          tom.InlineTable(table) ->
            case
              tom.get_string(table, ["name"]),
              tom.get_string(table, ["version"])
            {
              Ok(name), Ok(version) -> dict.insert(accumulator, name, version)
              _, _ -> accumulator
            }
          _ -> accumulator
        }
      }),
    )
  }
  result.unwrap(parsed, dict.new())
}
