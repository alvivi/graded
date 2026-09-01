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

import glance.{type Definition, type Function, type Module, FunctionType}
import gleam/bool
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
    // Whether the parameter carries a type annotation at all. An unannotated
    // one is the girard-typed case — nothing in the source says what it is, so
    // a bound naming it is the only evidence it is a callback. An annotated
    // parameter that is not `fn(..)` plainly is not one.
    is_annotated: Bool,
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
  SignatureRegistry(
    signatures: Dict(QualifiedName, List(ParameterInfo)),
    // Every custom type whose declaration this package parsed, keyed by
    // `#(defining module, type name)`. Present-but-labelless is a different
    // answer from absent, which is why this rides a dict of its own rather than
    // reusing `types.FieldIndex.labels`.
    accessors: Dict(#(String, String), AccessorInfo),
  )
}

// What one custom type's declaration says about the record accessors it grants.
//
// Read to tell a call through a name that shadows an imported module apart from
// a field call on a record: the compiler reads the module only where the
// receiver's type grants no accessor for the label.
pub type AccessorInfo {
  AccessorInfo(
    // Every label any variant declares. A label absent here is absent from the
    // type under every narrowing, which is the only reading that cannot turn an
    // effectful field into a pure module call: a label on some variants only is
    // reachable through a pattern that narrows the binding to one of them.
    any_label: Set(String),
    // The labels every variant declares at one field index *and* one type —
    // the accessors the type grants on a receiver no pattern narrowed. The
    // index is part of the condition because an accessor compiles to a fixed
    // `erlang:element/2` position, so a label at differing positions across
    // variants grants nothing. The type is part of it because the accessor
    // needs one type to return: a label written `fn(String) -> Nil` on one
    // variant and `fn(Int) -> Nil` on another grants nothing either, and the
    // compiler says so. Two spellings of one type are one type — the aliases a
    // module declares are expanded through their own parameters before the
    // comparison — and a pair this module's aliases cannot decide keeps the
    // label rather than losing it on a guess.
    every_label: Set(String),
    // `opaque` on the declaration — the accessors exist only inside the
    // defining module, and so do the constructors a narrowing would need.
    opaque_: Bool,
  )
}

// An empty registry — nothing known about any function's parameters.
pub fn empty() -> SignatureRegistry {
  SignatureRegistry(signatures: dict.new(), accessors: dict.new())
}

// Merge two registries. On key conflict, `b` wins (so later-loaded
// interfaces override earlier ones — useful when the project's own
// interface is loaded after dependency interfaces).
pub fn merge(a: SignatureRegistry, b: SignatureRegistry) -> SignatureRegistry {
  SignatureRegistry(
    signatures: dict.merge(a.signatures, b.signatures),
    accessors: dict.merge(a.accessors, b.accessors),
  )
}

// What a receiver's nominal type grants, or `None` where the package never
// parsed that type's declaration — the case a caller must resolve toward the
// field, since nothing was proved about it.
pub fn accessor_info(
  registry: SignatureRegistry,
  type_key: #(String, String),
) -> Option(AccessorInfo) {
  dict.get(registry.accessors, type_key) |> option.from_result()
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
// abstraction so its binders line up with the application spine. A parameter
// named in `bound_names` counts as fn-typed too — a running fallback's
// girard-typed callback carries no `fn(...)` annotation for the registry to
// see, and exists only as the bound recorded beside its settled summary — and
// any parameter a bound names binds under the matched bound name (in-body name
// preferred), since that is the variable the recorded term holds free — a
// labeled fallback callback included, whose label would otherwise name the
// binder. Empty when the callee isn't in the registry.
pub fn fn_typed_param_names_ordered(
  registry: SignatureRegistry,
  name: QualifiedName,
  bound_names: Set(String),
) -> List(String) {
  case lookup(registry, name) {
    None -> []
    Some(params) ->
      params
      |> by_position()
      |> list.filter_map(fn(p) {
        // The bound-name match wins for a syntactically fn-typed parameter
        // too: a labeled fallback callback (`with action:`) records its bound
        // — and states its settled term — over the in-body name, so a binder
        // named after the label would leave the term's variable free.
        let bound =
          [p.name, p.label]
          |> list.filter_map(option.to_result(_, Nil))
          |> list.find(set.contains(bound_names, _))
        // And only where the parameter could be a callback at all: fn-typed,
        // or unannotated, which is the girard-typed case the registry never
        // sees a type for. A bound that merely shares a name with an annotated
        // non-function parameter is a coincidence, and binding it would give
        // the operator one binder too many — an arity the application spine
        // cannot match, which goes stuck and collapses to `[Unknown]`.
        let could_be_callback = p.is_fn_typed || !p.is_annotated
        let own_name = option.to_result(option.or(p.label, p.name), Nil)
        case bound, could_be_callback, p.is_fn_typed {
          Ok(name), True, _ -> Ok(name)
          Ok(_), False, _ -> Error(Nil)
          Error(Nil), _, True -> own_name
          Error(Nil), _, False -> Error(Nil)
        }
      })
  }
}

// Every registry entry's fn-typed parameter names, in position order, keyed by
// the function they belong to. Entries with no fn-typed parameter are dropped,
// so a key here is a function that takes a callback.
//
// The in-body name leads and the label is the fallback — the reverse of
// `fn_typed_param_names`' preference, and deliberately so. These names are
// synthesized into the callback share a boundless declaration charges, and the
// bounds recorded beside it; a recorded fallback summary states its own bounds
// over in-body names, and `ordered_callback_param_names` binds over them too.
// Naming the label instead would leave one channel's variable free of the
// other's binder for every labeled callback.
//
// Strictly `is_fn_typed`, where `fn_typed_param_names_ordered` also counts an
// unannotated parameter its bound list names. That function is *binding* an
// operator whose term already holds the variable; this one is deciding whether
// to put a variable there at all, and an unannotated parameter is no evidence
// of a callback — synthesizing one per girard-typed parameter would charge a
// share for every argument a declared function takes.
pub fn callback_param_names(
  registry: SignatureRegistry,
) -> Dict(QualifiedName, List(String)) {
  use acc, name, params <- dict.fold(registry.signatures, dict.new())
  let callbacks =
    params
    |> list.filter(fn(p) { p.is_fn_typed })
    |> by_position()
    |> list.filter_map(fn(p) {
      option.to_result(option.or(p.name, p.label), Nil)
    })
  case callbacks {
    [] -> acc
    _ -> dict.insert(acc, name, callbacks)
  }
}

// A parameter list in declaration order. `from_glance_module` already builds
// one that way, so this is a defence rather than a repair — but every reader
// that depends on the order states that dependence through this one function,
// so two of them cannot come to different orders.
fn by_position(params: List(ParameterInfo)) -> List(ParameterInfo) {
  list.sort(params, fn(a, b) { int.compare(a.position, b.position) })
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
//
// Parameter types are read through the module's own type aliases, so
// `run: Action` with `type Action = fn() -> Nil` registers as the callback it
// is.
pub fn from_glance_module(
  module_path: String,
  module: Module,
) -> SignatureRegistry {
  let alias_map = type_alias_map(module.type_aliases)
  let signatures =
    list.fold(module.functions, dict.new(), fn(acc, definition) {
      dict.insert(
        acc,
        QualifiedName(module: module_path, function: definition.definition.name),
        parameter_infos(definition.definition, alias_map),
      )
    })
  SignatureRegistry(
    signatures:,
    accessors: dict.merge(
      prelude_accessors(),
      accessors_from_module(module_path, module, type_scope(module)),
    ),
  )
}

// The nine types the prelude declares. No module declaration produces them, and
// none grants a record accessor, so a receiver annotated with one is decided
// rather than left unindexed. Seeded on every parsed module, which is what
// carries them through `merge`; a project type of the same name keys under its
// own module and is unaffected.
fn prelude_accessors() -> Dict(#(String, String), AccessorInfo) {
  [
    "Int", "Float", "String", "Bool", "Nil", "BitArray", "UtfCodepoint", "List",
    "Result",
  ]
  |> list.map(fn(name) {
    #(
      #("gleam", name),
      AccessorInfo(any_label: set.new(), every_label: set.new(), opaque_: False),
    )
  })
  |> dict.from_list()
}

// Each custom type a module declares, with the union of its variants' labels
// beside their every-variant intersection. A type whose variants label nothing
// still gets an entry: "indexed, and grants no accessor for this label" is the
// answer the whole index exists to give.
fn accessors_from_module(
  module_path: String,
  module: Module,
  scope: TypeScope,
) -> Dict(#(String, String), AccessorInfo) {
  list.fold(module.custom_types, dict.new(), fn(acc, definition) {
    let declaration = definition.definition
    // Both sets are projections of one `label -> slot` table per variant, so
    // the variants are walked once and the two readings taken off the result.
    let indexed = list.map(declaration.variants, labels_by_slot(_, scope))
    dict.insert(
      acc,
      #(module_path, declaration.name),
      AccessorInfo(
        any_label: any_variant_labels(indexed),
        every_label: every_variant_labels(indexed, scope),
        opaque_: declaration.opaque_,
      ),
    )
  })
}

// Where one labelled field sits: the element position it occupies and the type
// it is declared at, both of which every variant must agree on for the label to
// be an accessor.
type Slot =
  #(Int, glance.Type)

// Every label any variant declares, whatever slot it takes there.
fn any_variant_labels(indexed: List(Dict(String, Slot))) -> Set(String) {
  indexed |> list.flat_map(dict.keys) |> set.from_list()
}

// The labels every variant declares in the same slot. A type with one variant
// answers its whole label set, and a type with no variants answers the empty
// set.
//
// A label is dropped only where two variants are *proved* to slot it
// differently. Selecting the module on a field that is real charges a pure
// module function for an effectful field, so a pair of types a syntax-level
// read cannot decide keeps the label rather than costing it.
fn every_variant_labels(
  indexed: List(Dict(String, Slot)),
  scope: TypeScope,
) -> Set(String) {
  case indexed {
    [] -> set.new()
    [first, ..rest] ->
      list.fold(rest, first, fn(shared, variant) {
        dict.filter(shared, fn(label, slot) {
          case dict.get(variant, label) {
            Ok(#(index, type_)) ->
              index == slot.0 && compare_types(slot.1, type_, scope) != Differs
            Error(Nil) -> False
          }
        })
      })
      |> dict.keys()
      |> set.from_list()
  }
}

// One variant's labels mapped to the slot each occupies. Unlabelled fields take
// positions too, so they are counted and then dropped rather than skipped.
fn labels_by_slot(
  variant: glance.Variant,
  scope: TypeScope,
) -> Dict(String, Slot) {
  variant.fields
  |> list.index_map(fn(field, index) {
    #(field_label(field), #(index, comparable_type(field.item, scope)))
  })
  |> list.filter_map(fn(entry) {
    let #(label, slot) = entry
    result.map(label, fn(label) { #(label, slot) })
  })
  |> dict.from_list()
}

// What a module says about the names its variants' field types are written
// with, which is what deciding whether two of them are one type takes.
type TypeScope {
  TypeScope(
    // The module's own aliases, each with the parameters it takes — what an
    // alias reference carrying arguments needs to expand. The
    // parameter-carrying twin of `type_alias_map`, which the rest of the
    // registry reads.
    aliases: Dict(String, #(List(String), glance.Type)),
    // Type names the module imported unqualified, under the name it reads them
    // by. Written bare like the module's own types, they may still be another
    // module's alias for anything at all, and that module's declarations are
    // not in reach here.
    imported: Set(String),
  )
}

fn type_scope(module: Module) -> TypeScope {
  TypeScope(
    aliases: list.fold(module.type_aliases, dict.new(), fn(acc, definition) {
      let alias = definition.definition
      dict.insert(acc, alias.name, #(alias.parameters, alias.aliased))
    }),
    imported: list.fold(module.imports, set.new(), fn(acc, definition) {
      list.fold(definition.definition.unqualified_types, acc, fn(acc, imported) {
        set.insert(acc, option.unwrap(imported.alias, imported.name))
      })
    }),
  )
}

// A field's declared type in the form two variants' fields are compared in:
// every span zeroed, and every module-local alias expanded through its own
// parameters.
//
// The spans go because glance hangs the source position it read a type at on
// every node of it, and no two variants are written at one position. The
// aliases are expanded because `Handler(String)` and the `fn(String) -> Nil` it
// stands for are one type to the compiler, and the accessor it grants is one
// accessor.
fn comparable_type(type_: glance.Type, scope: TypeScope) -> glance.Type {
  comparable_type_seen(type_, scope, set.new())
}

// `seen` holds the alias names expanded on the way to here, which stops an
// alias standing for itself from expanding forever. An alias handed the wrong
// number of arguments has no expansion to give and keeps its own name.
fn comparable_type_seen(
  type_: glance.Type,
  scope: TypeScope,
  seen: Set(String),
) -> glance.Type {
  let recur = fn(inner) { comparable_type_seen(inner, scope, seen) }
  case type_ {
    glance.NamedType(name:, module: None, parameters:, ..) -> {
      let arguments = list.map(parameters, recur)
      let expanded = case
        set.contains(seen, name),
        dict.get(scope.aliases, name)
      {
        False, Ok(#(alias_parameters, body)) ->
          list.strict_zip(alias_parameters, arguments)
          |> result.map(fn(bindings) {
            substitute_type_variables(body, dict.from_list(bindings))
            |> comparable_type_seen(scope, set.insert(seen, name))
          })
        _, _ -> Error(Nil)
      }
      case expanded {
        Ok(type_) -> type_
        Error(Nil) ->
          glance.NamedType(
            location: no_span,
            name:,
            module: None,
            parameters: arguments,
          )
      }
    }
    glance.NamedType(name:, module:, parameters:, ..) ->
      glance.NamedType(
        location: no_span,
        name:,
        module:,
        parameters: list.map(parameters, recur),
      )
    glance.TupleType(elements:, ..) ->
      glance.TupleType(location: no_span, elements: list.map(elements, recur))
    glance.FunctionType(parameters:, return:, ..) ->
      glance.FunctionType(
        location: no_span,
        parameters: list.map(parameters, recur),
        return: recur(return),
      )
    glance.VariableType(name:, ..) ->
      glance.VariableType(location: no_span, name:)
    glance.HoleType(name:, ..) -> glance.HoleType(location: no_span, name:)
  }
}

// An alias body with its own parameters replaced by the arguments the reference
// carries, so `Handler(String)` expands to `fn(String) -> Nil` rather than to
// the `fn(a) -> Nil` that would read as `Handler(Int)` too.
fn substitute_type_variables(
  type_: glance.Type,
  bindings: Dict(String, glance.Type),
) -> glance.Type {
  let recur = fn(inner) { substitute_type_variables(inner, bindings) }
  case type_ {
    glance.VariableType(name:, ..) ->
      case dict.get(bindings, name) {
        Ok(bound) -> bound
        Error(Nil) -> type_
      }
    glance.NamedType(location:, name:, module:, parameters:) ->
      glance.NamedType(
        location:,
        name:,
        module:,
        parameters: list.map(parameters, recur),
      )
    glance.TupleType(location:, elements:) ->
      glance.TupleType(location:, elements: list.map(elements, recur))
    glance.FunctionType(location:, parameters:, return:) ->
      glance.FunctionType(
        location:,
        parameters: list.map(parameters, recur),
        return: recur(return),
      )
    glance.HoleType(..) -> type_
  }
}

// What comparing two variants' field types settles. `Differs` is a proof that
// no one accessor can serve both; `Undecided` is the answer for a pair this
// module's own aliases and spans cannot separate — a name qualified by a module
// whose aliases were never read may stand for the very type beside it.
type TypeAgreement {
  Agrees
  Differs
  Undecided
}

fn compare_types(
  left: glance.Type,
  right: glance.Type,
  scope: TypeScope,
) -> TypeAgreement {
  use <- bool.guard(left == right, Agrees)
  case left, right {
    glance.NamedType(name: l_name, module: l_module, parameters: l_args, ..),
      glance.NamedType(name: r_name, module: r_module, parameters: r_args, ..)
      if l_name == r_name && l_module == r_module
    -> compare_type_lists(l_args, r_args, scope)
    glance.TupleType(elements: l_elements, ..),
      glance.TupleType(elements: r_elements, ..)
    -> compare_type_lists(l_elements, r_elements, scope)
    glance.FunctionType(parameters: l_params, return: l_return, ..),
      glance.FunctionType(parameters: r_params, return: r_return, ..)
    ->
      combine([
        compare_type_lists(l_params, r_params, scope),
        compare_types(l_return, r_return, scope),
      ])
    _, _ -> undecided_or_apart(left, right, scope)
  }
}

// Two heads that did not match: undecided where either may still stand for
// something else, and proved apart where neither can.
fn undecided_or_apart(
  left: glance.Type,
  right: glance.Type,
  scope: TypeScope,
) -> TypeAgreement {
  use <- bool.guard(
    stands_for_anything(left, scope) || stands_for_anything(right, scope),
    Undecided,
  )
  Differs
}

// Two type lists compared position by position. Lists of different lengths are
// different types: no head takes two arities.
fn compare_type_lists(
  left: List(glance.Type),
  right: List(glance.Type),
  scope: TypeScope,
) -> TypeAgreement {
  case list.strict_zip(left, right) {
    Ok(pairs) ->
      combine(
        list.map(pairs, fn(pair) { compare_types(pair.0, pair.1, scope) }),
      )
    Error(Nil) -> Differs
  }
}

// What a head's children settle for the head itself. One child proved apart
// puts the two types apart whatever the rest read, so `Differs` anywhere
// carries; short of that an undecided child leaves the whole undecided.
fn combine(agreements: List(TypeAgreement)) -> TypeAgreement {
  use <- bool.guard(list.contains(agreements, Differs), Differs)
  use <- bool.guard(list.contains(agreements, Undecided), Undecided)
  Agrees
}

// Whether a type's head could still stand for something else: a name qualified
// by another module, a name imported unqualified from one, or a local alias
// `comparable_type` declined to expand. Each may be the type written beside it
// under another name. What is left — the module's own types and the prelude's —
// names itself.
fn stands_for_anything(type_: glance.Type, scope: TypeScope) -> Bool {
  case type_ {
    glance.NamedType(module: Some(_), ..) -> True
    glance.NamedType(name:, module: None, ..) ->
      dict.has_key(scope.aliases, name) || set.contains(scope.imported, name)
    _ -> False
  }
}

// The position every comparable type is written at.
const no_span = glance.Span(0, 0)

// A registry holding one function, against an alias map handed in. The
// synthetic same-module registries build a `glance.Module` around a single
// definition and have no `type_aliases` list to carry the module's aliases,
// so they state the map directly and reach the same resolution
// `from_glance_module` performs.
pub fn from_single_function(
  module_path: String,
  definition: Definition(Function),
  alias_map: Dict(String, glance.Type),
) -> SignatureRegistry {
  SignatureRegistry(
    signatures: dict.from_list([
      #(
        QualifiedName(module: module_path, function: definition.definition.name),
        parameter_infos(definition.definition, alias_map),
      ),
    ]),
    // One function says nothing about any type's accessors. Merged into a real
    // registry it leaves that one's index intact.
    accessors: dict.new(),
  )
}

// One function's parameters as registry entries, in declaration order.
fn parameter_infos(
  function: Function,
  alias_map: Dict(String, glance.Type),
) -> List(ParameterInfo) {
  list.index_map(function.parameters, fn(param, i) {
    let resolved =
      param.type_
      |> option.then(fn(type_) {
        resolve_function_type(type_, alias_map) |> option.from_result
      })
    let callback_positions = case resolved {
      Some(FunctionType(_, param_types, _)) ->
        fn_typed_argument_positions(param_types, alias_map)
      _ -> []
    }
    ParameterInfo(
      position: i,
      label: param.label,
      name: assignment_name(param.name),
      is_fn_typed: option.is_some(resolved),
      is_annotated: option.is_some(param.type_),
      is_operator: callback_positions != [],
      callback_positions:,
    )
  })
}

// Module-local type aliases as a raw `name → aliased type` map, the input every
// alias-aware reading resolves against.
pub fn type_alias_map(
  aliases: List(Definition(glance.TypeAlias)),
) -> Dict(String, glance.Type) {
  list.fold(aliases, dict.new(), fn(acc, definition) {
    dict.insert(acc, definition.definition.name, definition.definition.aliased)
  })
}

// Function-typed *record fields* of a module's custom types, keyed by
// `#(type_name, field_name)`. A field qualifies when its declared type is a
// direct `fn(..)` or a module-local alias resolving to one (`fn_aliases`). Only
// labelled fields are included — an unlabelled field can't be reached by a
// `record.field(..)` call. The boundary-scoped analog of
// `ordered_callback_params`: it lets the checker treat a `fn`-typed field
// on an opaque receiver as polymorphic (a field-effect variable) instead of
// collapsing it to `[Unknown]`.
pub fn fn_typed_fields_from_module(
  module: Module,
  alias_map: Dict(String, glance.Type),
) -> Set(#(String, String)) {
  module.custom_types
  |> list.flat_map(fn(definition) {
    let type_name = definition.definition.name
    definition.definition.variants
    |> list.flat_map(fn(variant) { variant.fields })
    |> list.filter_map(labelled_fn_field(type_name, _, alias_map))
  })
  |> set.from_list()
}

// The callable record fields of a module's custom types, keyed by
// `#(module, type_name, variant, field)` and carrying the shape a field
// `check` measures a construction site against. Qualified by the module that
// *defines* the type, the same rule a field `assume` line is keyed by, so a
// package-wide pass never confuses same-named types from two modules.
//
// Per variant rather than per type: Gleam lets two variants give one label
// different types — a different arity, different callback positions, or
// callable in one variant and not the other — and a site is always one
// variant's constructor.
pub fn field_index_from_module(
  module_path: String,
  module: Module,
  alias_map: Dict(String, glance.Type),
) -> types.FieldIndex {
  list.fold(module.custom_types, empty_field_index(), fn(acc, definition) {
    let type_name = definition.definition.name
    list.fold(definition.definition.variants, acc, fn(acc, variant) {
      let labels =
        variant.fields
        |> list.filter_map(field_label)
        |> list.map(fn(label) { #(module_path, type_name, label) })
        |> set.from_list()
      let callable =
        variant.fields
        |> list.filter_map(callable_field_signature(_, alias_map))
        |> list.map(fn(entry) {
          let #(label, signature) = entry
          #(#(module_path, type_name, variant.name, label), signature)
        })
        |> dict.from_list()
      types.FieldIndex(
        labels: set.union(acc.labels, labels),
        callable: dict.merge(acc.callable, callable),
        variant_types: dict.insert(
          acc.variant_types,
          #(module_path, variant.name),
          type_name,
        ),
      )
    })
  })
}

// An index over no module at all — the fold's seed and the empty merge.
pub fn empty_field_index() -> types.FieldIndex {
  types.FieldIndex(
    labels: set.new(),
    callable: dict.new(),
    variant_types: dict.new(),
  )
}

// Combine two field indexes; the right one wins on a repeated key, the same
// way the signature registry's merge resolves one.
pub fn merge_field_index(
  left: types.FieldIndex,
  right: types.FieldIndex,
) -> types.FieldIndex {
  types.FieldIndex(
    labels: set.union(left.labels, right.labels),
    callable: dict.merge(left.callable, right.callable),
    variant_types: dict.merge(left.variant_types, right.variant_types),
  )
}

// A labelled field's label; `Error(Nil)` for an unlabelled one, which no
// `record.field(..)` call can reach.
fn field_label(field: glance.VariantField) -> Result(String, Nil) {
  case field {
    glance.LabelledVariantField(label:, ..) -> Ok(label)
    glance.UnlabelledVariantField(..) -> Error(Nil)
  }
}

// One labelled field's callable shape, `Error(Nil)` for an unlabelled or
// non-callable field. The arity is the field's own parameter count, which is
// what an inline closure wired into it is abstracted over.
fn callable_field_signature(
  field: glance.VariantField,
  alias_map: Dict(String, glance.Type),
) -> Result(#(String, types.CallableFieldSignature), Nil) {
  use #(item, label) <- result.try(case field {
    glance.LabelledVariantField(item:, label:) -> Ok(#(item, label))
    glance.UnlabelledVariantField(..) -> Error(Nil)
  })
  use resolved <- result.try(resolve_function_type(item, alias_map))
  case resolved {
    FunctionType(_, param_types, _) ->
      Ok(#(
        label,
        types.CallableFieldSignature(
          arity: list.length(param_types),
          callbacks: callback_shape(param_types, alias_map),
        ),
      ))
    _ -> Error(Nil)
  }
}

// A `#(type_name, label)` entry for a labelled, callable field; `Error(Nil)`
// for an unlabelled or non-fn field.
fn labelled_fn_field(
  type_name: String,
  field: glance.VariantField,
  alias_map: Dict(String, glance.Type),
) -> Result(#(String, String), Nil) {
  case field {
    glance.LabelledVariantField(item:, label:) ->
      case is_fn_typed(item, alias_map) {
        True -> Ok(#(type_name, label))
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// Glance AST detection
//
// Registry-free detection on a single function or type: reads fn-typed
// parameters and operator shapes straight off glance annotations, for
// definition-site inference where no registry lookup applies.

// Whether a declared type is callable: a `fn(...)` written out, or a
// module-local alias resolving to one (`run: Action` with
// `type Action = fn() -> Nil`). The one alias-aware reading of "is this a
// callback", so the registry, the definition-site detection below and the
// checker's bound synthesis cannot come to different answers about one
// parameter.
pub fn is_fn_typed(
  type_: glance.Type,
  alias_map: Dict(String, glance.Type),
) -> Bool {
  resolve_function_type(type_, alias_map) |> result.is_ok
}

// In-body names of a function's callback parameters, in declaration order.
// A parameter named in `extra` counts as one however its type reads — the
// girard-typed case, which carries no annotation for the alias map to chase,
// and a callback a settled summary records a bound for.
//
// Parameters carrying a non-function type, and discarded ones, are omitted.
pub fn ordered_callback_params(
  function: Function,
  alias_map: Dict(String, glance.Type),
  extra: Set(String),
) -> List(String) {
  list.filter_map(function.parameters, fn(param) {
    case param.name {
      glance.Named(name) ->
        case
          option.unwrap(
            option.map(param.type_, is_fn_typed(_, alias_map)),
            False,
          )
          || set.contains(extra, name)
        {
          True -> Ok(name)
          False -> Error(Nil)
        }
      glance.Discarded(_) -> Error(Nil)
    }
  })
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
//
// Alias-aware at every depth: the parameter's own type, each of its arguments,
// and those arguments' arguments each resolve through `alias_map`, so
// `type Action = fn(Callback) -> Nil` over `type Callback = fn() -> Nil` reads
// the same shape as the types written out.
pub fn operator_param_shapes(
  function: Function,
  alias_map: Dict(String, glance.Type),
) -> Dict(String, List(#(Int, List(Int)))) {
  function.parameters
  |> list.filter_map(fn(param) {
    use name <- result.try(option.to_result(assignment_name(param.name), Nil))
    use type_ <- result.try(option.to_result(param.type_, Nil))
    use resolved <- result.try(resolve_function_type(type_, alias_map))
    case resolved {
      FunctionType(_, param_types, _) ->
        Ok(#(name, callback_shape(param_types, alias_map)))
      _ -> Error(Nil)
    }
  })
  |> dict.from_list()
}

// One operator parameter's callback shape: each function-typed argument's
// index paired with that argument's own callback positions. Every layer is
// resolved through `alias_map`, each layer exactly once.
fn callback_shape(
  param_types: List(glance.Type),
  alias_map: Dict(String, glance.Type),
) -> List(#(Int, List(Int))) {
  fn_typed_arguments(param_types, alias_map)
  |> list.map(fn(pair) {
    let #(index, resolved) = pair
    case resolved {
      FunctionType(_, inner, _) -> #(
        index,
        fn_typed_argument_positions(inner, alias_map),
      )
      _ -> #(index, [])
    }
  })
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
  case resolve_alias(type_, alias_map) {
    FunctionType(..) as resolved -> Ok(resolved)
    _ -> Error(Nil)
  }
}

// What a type spells once module-local aliases are followed as far as they go.
// A type that names no alias is its own answer, and so is the alias a cycle
// closes on — so every caller reads the chain's end without a `Result` for
// "went nowhere", which is not a failure.
pub fn resolve_alias(
  type_: glance.Type,
  alias_map: Dict(String, glance.Type),
) -> glance.Type {
  resolve_alias_seen(type_, alias_map, set.new())
}

fn resolve_alias_seen(
  type_: glance.Type,
  alias_map: Dict(String, glance.Type),
  seen: Set(String),
) -> glance.Type {
  case type_ {
    glance.NamedType(name:, module: None, ..) ->
      case set.contains(seen, name), dict.get(alias_map, name) {
        False, Ok(aliased) ->
          resolve_alias_seen(aliased, alias_map, set.insert(seen, name))
        _, _ -> type_
      }
    _ -> type_
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
  use resolved <- result.try(resolve_function_type(type_, alias_map))
  case resolved {
    FunctionType(_, param_types, _) ->
      Ok(fn_typed_argument_positions(param_types, alias_map))
    _ -> Error(Nil)
  }
}

pub fn assignment_name(name: glance.AssignmentName) -> Option(String) {
  case name {
    glance.Named(n) -> Some(n)
    glance.Discarded(_) -> None
  }
}

// The function-typed arguments of a type list: each one's index paired with
// its type resolved through `alias_map`, in order. The one place an argument
// list is filtered for callbacks, so a reader that needs only the indices and
// one that needs the resolved types read the same rule.
fn fn_typed_arguments(
  types: List(glance.Type),
  alias_map: Dict(String, glance.Type),
) -> List(#(Int, glance.Type)) {
  types
  |> list.index_map(fn(type_, index) { #(index, type_) })
  |> list.filter_map(fn(pair) {
    use resolved <- result.map(resolve_function_type(pair.1, alias_map))
    #(pair.0, resolved)
  })
}

// Their indices alone — the callback positions for an operator parameter's
// own argument list.
fn fn_typed_argument_positions(
  types: List(glance.Type),
  alias_map: Dict(String, glance.Type),
) -> List(Int) {
  fn_typed_arguments(types, alias_map) |> list.map(fn(pair) { pair.0 })
}

// Dependency loading
//
// Parses dependency and path-dependency source trees with glance so a caller
// folds each parsed module into everything it derives from dependency source —
// this registry and the update-builder map — from a single read and parse per
// file. Unreadable or unparseable files are skipped rather than failing the run.

// Parse every `.gleam` file under `source_dir` with glance and fold it into
// `initial`, in walk order. `step` receives the module path the file's location
// denotes (`<source_dir>/gleam/list.gleam` → `gleam/list`), the path of the file
// itself, and the parse of it, or `Error(Nil)` where the file would not read or
// parse. Folding rather than returning a list keeps one AST live at a time, so a
// package's whole source never sits in memory at once.
//
// The file path travels alongside because a caller that records the copy of a
// module path it read may want to read that copy again later, and only the path
// names *that* copy — a second search for the module could find a different one.
//
// A file that will not read or parse (a version mismatch, an FFI-only Erlang
// package) is handed to `step` rather than skipped: it derives nothing, but it
// still names a module path, and a caller recording which copy of a path it
// read needs the copies it could not read too. A caller with nothing to record
// for them drops them, and calls into them fall back to label-only argument
// matching at polymorphic call sites. A missing directory yields `initial`,
// with no step at all.
pub fn fold_source_dir(
  source_dir: String,
  initial: acc,
  step: fn(acc, String, String, Result(Module, Nil)) -> acc,
) -> acc {
  case simplifile.get_files(source_dir) {
    Error(_) -> initial
    Ok(files) ->
      files
      |> list.filter(fn(path) { string.ends_with(path, ".gleam") })
      |> list.fold(initial, fn(acc, gleam_path) {
        let parsed = {
          use source <- result.try(result.replace_error(
            simplifile.read(gleam_path),
            Nil,
          ))
          result.replace_error(glance.module(source), Nil)
        }
        step(
          acc,
          config.module_path_for_source(gleam_path, source_dir),
          gleam_path,
          parsed,
        )
      })
  }
}
