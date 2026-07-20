// Glance-backed signature registry.
//
// Parses Gleam source with glance to learn which function parameters
// are themselves function-typed. This powers call-site effect
// substitution and auto-inference of polymorphic signatures: knowing a
// parameter's type is `fn(...) -> ...` lets graded bind an effect
// variable at the definition site and substitute the caller's
// concrete argument at each call site.
//
// Project modules are parsed during `run_infer` / `run`; dependency
// modules are parsed from `build/packages/<dep>/src/` on demand.

import filepath
import glance.{type Function, type Module, FunctionType}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded/internal/config
import graded/internal/types.{type QualifiedName, QualifiedName}
import simplifile

// Registry
//
// The registry itself: what a ParameterInfo records, and the queries the
// checker runs against it — which of a callee's parameters are fn-typed or
// operators, in what order, and where their callbacks sit.

// One parameter of a function's signature.
//
// `label` is the Gleam argument label (e.g. `by` in `fn foo(by name: X)`).
// `name` is the in-body parameter name when we have source access via
// glance (`None` when the info was loaded from `gleam export
// package-interface` JSON, which doesn't expose in-body names).
//
// Auto-inferred param bounds key off the in-body name (because it's
// what appears at call sites in the body), so matching at a call site
// tries `name` before `label`.
pub type ParameterInfo {
  ParameterInfo(
    position: Int,
    label: Option(String),
    name: Option(String),
    is_fn_typed: Bool,
    // True when the parameter is *second-order* — its own type takes a
    // function (`fn(fn(..) -> _) -> _`). Calls to it are effect-operator
    // applications, and arguments bound to it are lifted to operators.
    // Equivalent to `callback_positions != []`.
    is_operator: Bool,
    // For an operator parameter, the argument indices (within its own type's
    // argument list) that are themselves function-typed — its callbacks, in
    // order. Empty for first-order parameters. Lets the call site curry an
    // argument's abstraction over exactly the right positions.
    callback_positions: List(Int),
  )
}

// Maps qualified function names to their parameter signatures.
//
// Only populated for functions whose signatures are known — anything
// parsed successfully from project or dependency source. Functions
// absent from the registry fall back to glance-AST inspection at the
// definition site, or are treated as opaque at call sites.
pub type SignatureRegistry {
  SignatureRegistry(signatures: Dict(QualifiedName, List(ParameterInfo)))
}

// An empty registry — nothing known about any function's parameters.
pub fn empty() -> SignatureRegistry {
  SignatureRegistry(signatures: dict.new())
}

// Merge two registries. On key conflict, `b` wins (so later-loaded
// interfaces override earlier ones — useful when the project's own
// interface is loaded after dependency interfaces).
pub fn merge(a: SignatureRegistry, b: SignatureRegistry) -> SignatureRegistry {
  SignatureRegistry(signatures: dict.merge(a.signatures, b.signatures))
}

// Look up a function's parameter signatures.
pub fn lookup(
  registry: SignatureRegistry,
  name: QualifiedName,
) -> Option(List(ParameterInfo)) {
  case dict.get(registry.signatures, name) {
    Ok(params) -> Some(params)
    Error(Nil) -> None
  }
}

// Names of a function's fn-typed parameters. Returns an empty set if
// the function isn't in the registry (conservative: "we don't know").
// Prefers the argument label (canonical for cross-module calls), falling
// back to the in-body name when no label is declared. `param_info`
// matches by either, so both forms round-trip.
pub fn fn_typed_param_names(
  registry: SignatureRegistry,
  name: QualifiedName,
) -> Set(String) {
  case lookup(registry, name) {
    None -> set.new()
    Some(params) ->
      params
      |> list.filter(fn(p) { p.is_fn_typed })
      |> list.filter_map(fn(p) {
        option.to_result(option.or(p.label, p.name), Nil)
      })
      |> set.from_list()
  }
}

// Names (label or in-body) of a callee's *operator* parameters — those whose
// type takes a function. Empty when the callee isn't in the registry.
pub fn operator_param_names(
  registry: SignatureRegistry,
  name: QualifiedName,
) -> Set(String) {
  case lookup(registry, name) {
    None -> set.new()
    Some(params) ->
      params
      |> list.filter(fn(p) { p.is_operator })
      |> list.filter_map(fn(p) {
        option.to_result(option.or(p.label, p.name), Nil)
      })
      |> set.from_list()
  }
}

// In-body parameter names of a callee's fn-typed parameters, **in declaration
// order** (label preferred, then in-body name). Unlike `fn_typed_param_names`
// (a `Set`), this preserves order — needed to curry an operator argument's
// abstraction so its binders line up with the application spine. Empty when the
// callee isn't in the registry.
pub fn fn_typed_param_names_ordered(
  registry: SignatureRegistry,
  name: QualifiedName,
) -> List(String) {
  case lookup(registry, name) {
    None -> []
    Some(params) ->
      params
      |> list.filter(fn(p) { p.is_fn_typed })
      |> list.sort(fn(a, b) { int.compare(a.position, b.position) })
      |> list.filter_map(fn(p) {
        option.to_result(option.or(p.label, p.name), Nil)
      })
  }
}

// The argument positions of the callbacks of one *operator* parameter — the
// function-typed argument indices within that parameter's own type, in order.
// For `action: fn(Config, fn() -> _, fn() -> _) -> _` this is `[1, 2]`. Empty
// when the callee or parameter isn't a known operator. The registry-backed twin
// of `operator_param_shapes`, used at the call site to curry a closure
// argument's abstraction over the right parameters.
pub fn operator_callback_positions(
  registry: SignatureRegistry,
  callee_name: QualifiedName,
  param_name: String,
) -> List(Int) {
  case lookup(registry, callee_name) {
    None -> []
    Some(params) ->
      params
      |> list.find(fn(p) { option.or(p.label, p.name) == Some(param_name) })
      |> result.map(fn(p) { p.callback_positions })
      |> result.unwrap([])
  }
}

// Glance AST to SignatureRegistry
//
// Builds registry entries and the fn-typed field index from parsed modules,
// so both project and dependency signatures come from one construction path.

// Build a SignatureRegistry from a parsed project module. Used during
// `run_infer` / `run` to give the checker position information for
// every function in the project — which powers positional argument
// matching at polymorphic call sites.
pub fn from_glance_module(
  module_path: String,
  module: Module,
) -> SignatureRegistry {
  let signatures =
    list.fold(module.functions, dict.new(), fn(acc, definition) {
      let function = definition.definition
      let params =
        list.index_map(function.parameters, fn(param, i) {
          let callback_positions = case param.type_ {
            Some(FunctionType(_, param_types, _)) ->
              all_function_indices(param_types)
            _ -> []
          }
          ParameterInfo(
            position: i,
            label: param.label,
            name: assignment_name(param.name),
            is_fn_typed: case param.type_ {
              Some(FunctionType(_, _, _)) -> True
              _ -> False
            },
            is_operator: callback_positions != [],
            callback_positions:,
          )
        })
      dict.insert(
        acc,
        QualifiedName(module: module_path, function: function.name),
        params,
      )
    })
  SignatureRegistry(signatures:)
}

// Function-typed *record fields* of a module's custom types, keyed by
// `#(type_name, field_name)`. A field qualifies when its declared type is a
// direct `fn(..)` or a module-local alias resolving to one (`fn_aliases`). Only
// labelled fields are included — an unlabelled field can't be reached by a
// `record.field(..)` call. The boundary-scoped analog of
// `fn_typed_params_from_function`: it lets the checker treat a `fn`-typed field
// on an opaque receiver as polymorphic (a field-effect variable) instead of
// collapsing it to `[Unknown]`.
pub fn fn_typed_fields_from_module(
  module: Module,
  fn_aliases: Set(String),
) -> Set(#(String, String)) {
  module.custom_types
  |> list.flat_map(fn(definition) {
    let type_name = definition.definition.name
    definition.definition.variants
    |> list.flat_map(fn(variant) { variant.fields })
    |> list.filter_map(labelled_fn_field(type_name, _, fn_aliases))
  })
  |> set.from_list()
}

// A `#(type_name, label)` entry for a labelled, callable field; `Error(Nil)`
// for an unlabelled or non-fn field.
fn labelled_fn_field(
  type_name: String,
  field: glance.VariantField,
  fn_aliases: Set(String),
) -> Result(#(String, String), Nil) {
  case field {
    glance.LabelledVariantField(item:, label:) ->
      case is_field_fn_typed(item, fn_aliases) {
        True -> Ok(#(type_name, label))
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// Whether a field's declared type is callable: a direct `fn(..)` or a
// module-local alias that resolves to one (`run: Action` with
// `type Action = fn() -> Nil`). Mirrors the alias handling applied to fn-typed
// parameters.
fn is_field_fn_typed(type_: glance.Type, fn_aliases: Set(String)) -> Bool {
  case type_ {
    FunctionType(_, _, _) -> True
    glance.NamedType(name:, module: None, ..) -> set.contains(fn_aliases, name)
    _ -> False
  }
}

// Glance AST detection
//
// Registry-free detection on a single function or type: reads fn-typed
// parameters and operator shapes straight off glance annotations, for
// definition-site inference where no registry lookup applies.

// Names of a local function's fn-typed parameters, detected from
// glance AST type annotations. Returns names of parameters whose
// type annotation is `fn(...) -> ...`.
//
// Parameters without explicit type annotations (or with non-function
// types) are omitted.
pub fn fn_typed_params_from_function(function: Function) -> Set(String) {
  function.parameters
  |> list.filter_map(fn(param) {
    case param.type_ {
      Some(FunctionType(_, _, _)) -> {
        case assignment_name(param.name) {
          Some(name) -> Ok(name)
          None -> Error(Nil)
        }
      }
      _ -> Error(Nil)
    }
  })
  |> set.from_list()
}

// Every fn-typed parameter of a function, mapped to the *shape* of its
// callbacks: a list of `#(callback position, that callback's own callback
// positions)`. For `op: fn(fn(String) -> Nil) -> Nil` the entry is
// `op -> [#(0, [])]` — its position-0 argument is a callback that itself takes
// no function (a first-order callback). For `op: fn(fn(fn() -> Nil) -> Nil) ->
// Nil` it is `op -> [#(0, [0])]` — the callback at position 0 itself takes a
// function at position 0. A first-order fn-typed parameter (`cb: fn(String) ->
// Nil`) maps to `[]`. This lets a call site lift each callback argument over
// exactly its own function parameters — discharging value parameters — instead
// of guessing.
pub fn operator_param_shapes(
  function: Function,
) -> Dict(String, List(#(Int, List(Int)))) {
  function.parameters
  |> list.filter_map(fn(param) {
    case param.type_, assignment_name(param.name) {
      Some(FunctionType(_, param_types, _)), Some(name) -> {
        let shape =
          param_types
          |> list.index_map(fn(t, i) { #(i, t) })
          |> list.filter(fn(pair) { is_function_type(pair.1) })
          |> list.map(fn(pair) {
            #(pair.0, operator_callback_positions_of_type(pair.1))
          })
        Ok(#(name, shape))
      }
      _, _ -> Error(Nil)
    }
  })
  |> dict.from_list()
}

// The callback positions of an operator-shaped *type* — the function-typed
// argument indices of a `fn(.., fn(..) -> _, ..) -> _`, in order. Empty when
// the type isn't a function type that takes a function (i.e. not an operator).
// Used to lift a function *returned* by a producer (its declared return type).
pub fn operator_callback_positions_of_type(type_: glance.Type) -> List(Int) {
  case type_ {
    FunctionType(_, param_types, _) -> all_function_indices(param_types)
    _ -> []
  }
}

// Resolve a type to its underlying function type, following module-local type
// aliases transitively (cycle-guarded). Returns the `fn(...)` type itself — not
// a name — so an operator-shaped alias keeps its callback positions. `Error(Nil)`
// when the type is not (transitively) a function. A producer whose return type
// resolves here *returns a function*, so the effect of calling that function is
// worth recording — even when it isn't operator-shaped (takes no callback).
pub fn resolve_function_type(
  type_: glance.Type,
  alias_map: Dict(String, glance.Type),
) -> Result(glance.Type, Nil) {
  resolve_function_type_seen(type_, alias_map, set.new())
}

fn resolve_function_type_seen(
  type_: glance.Type,
  alias_map: Dict(String, glance.Type),
  seen: Set(String),
) -> Result(glance.Type, Nil) {
  case type_ {
    FunctionType(..) -> Ok(type_)
    glance.NamedType(name:, module: None, ..) ->
      case set.contains(seen, name) {
        True -> Error(Nil)
        False ->
          case dict.get(alias_map, name) {
            Ok(aliased) ->
              resolve_function_type_seen(
                aliased,
                alias_map,
                set.insert(seen, name),
              )
            Error(Nil) -> Error(Nil)
          }
      }
    _ -> Error(Nil)
  }
}

// The callback positions of a producer's returned function, alias-aware at both
// layers: the outer return type is resolved to its underlying `fn(args) -> _`
// (through module-local aliases), and each argument index counts as a callback
// when it *itself* resolves to a function through the alias map. `Error(Nil)`
// when the return type isn't (transitively) a function — so a caller gates on
// "returns a function at all" and reads the callback positions in one step. The
// alias-aware twin of `operator_callback_positions_of_type`, used to lift a
// function returned by a producer whose return type — or whose callback
// arguments — are aliases.
pub fn returned_callback_positions(
  type_: glance.Type,
  alias_map: Dict(String, glance.Type),
) -> Result(List(Int), Nil) {
  use resolved <- result.map(resolve_function_type(type_, alias_map))
  let assert FunctionType(_, param_types, _) = resolved
  param_types
  |> list.index_map(fn(t, i) {
    #(i, resolve_function_type(t, alias_map) |> result.is_ok)
  })
  |> list.filter(fn(pair) { pair.1 })
  |> list.map(fn(pair) { pair.0 })
}

pub fn assignment_name(name: glance.AssignmentName) -> Option(String) {
  case name {
    glance.Named(n) -> Some(n)
    glance.Discarded(_) -> None
  }
}

// The indices of the function-typed arguments in a type list, in order. These
// are the callback positions for an operator parameter's own argument list.
fn all_function_indices(types: List(glance.Type)) -> List(Int) {
  types
  |> list.index_map(fn(t, i) { #(i, is_function_type(t)) })
  |> list.filter(fn(pair) { pair.1 })
  |> list.map(fn(pair) { pair.0 })
}

fn is_function_type(t: glance.Type) -> Bool {
  case t {
    FunctionType(_, _, _) -> True
    _ -> False
  }
}

// Dependency loading
//
// Parses dependency and path-dependency source trees with glance to fill the
// registry with cross-package signatures; unreadable or unparseable packages
// are skipped rather than failing the run.

// Load signature registries for every dependency in `packages_dir`
// by parsing each dep's `src/` directory with glance.
//
// For each `<packages_dir>/<dep>/src/` subtree, walks every `.gleam`
// file and folds it into the registry via `from_glance_module`,
// using the path under `src/` as the module path (e.g.
// `gleam_stdlib/src/gleam/list.gleam` → `gleam/list`).
//
// Failures (missing `src/`, parse errors from version mismatches,
// FFI-only Erlang packages) are silently skipped — affected deps
// contribute no entries and calls into them fall back to label-only
// argument matching at polymorphic call sites.
pub fn load_from_packages_dir(packages_dir: String) -> SignatureRegistry {
  case simplifile.read_directory(packages_dir) {
    Error(_) -> empty()
    Ok(entries) ->
      list.fold(entries, empty(), fn(acc, dep) {
        let src_dir = filepath.join(filepath.join(packages_dir, dep), "src")
        merge(acc, registry_from_source_dir(src_dir))
      })
  }
}

// Build a registry from a single package's `src/` directory by parsing every
// `.gleam` file under it. Used for path dependencies, whose source lives at the
// declared `path` rather than under `build/packages` — so `load_from_packages_dir`
// never sees them and their cross-module calls would otherwise lack the position
// info positional argument matching needs.
pub fn load_from_source_dir(source_dir: String) -> SignatureRegistry {
  registry_from_source_dir(source_dir)
}

fn registry_from_source_dir(source_dir: String) -> SignatureRegistry {
  case simplifile.get_files(source_dir) {
    Error(_) -> empty()
    Ok(files) ->
      files
      |> list.filter(fn(p) { string.ends_with(p, ".gleam") })
      |> list.fold(empty(), fn(acc, gleam_path) {
        merge(acc, registry_from_gleam_file(gleam_path, source_dir))
      })
  }
}

fn registry_from_gleam_file(
  gleam_path: String,
  source_dir: String,
) -> SignatureRegistry {
  use source <- bool_or_default(simplifile.read(gleam_path), empty())
  use module <- bool_or_default(glance.module(source), empty())
  from_glance_module(
    config.module_path_for_source(gleam_path, source_dir),
    module,
  )
}

// Continuation-style result-or-default: runs `next` with the Ok value,
// or returns `default` on Error. Lets callers chain reads/parses
// without nested case expressions.
fn bool_or_default(result: Result(a, b), default: c, next: fn(a) -> c) -> c {
  case result {
    Ok(v) -> next(v)
    Error(_) -> default
  }
}
