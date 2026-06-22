import girard/types as girard_types
import glance.{
  type Definition, type Function, type Module, type Statement, Function, Private,
  Span,
}
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded/internal/effect_term
import graded/internal/effects.{type KnowledgeBase}
import graded/internal/extract.{type ImportContext}
import graded/internal/signatures.{type SignatureRegistry}
import graded/internal/topo
import graded/internal/typeinfo
import graded/internal/types.{
  type EffectAnnotation, type EffectTerm, type LocalCall, type ParamBound,
  type ResolvedCall, type Violation, type Warning, EffectAnnotation, Effects,
  ParamBound, QualifiedName, TUnion, TVar, UntrackedEffectWarning, Violation,
}

// Check a parsed module against its effect annotations.
pub fn check(
  module: Module,
  annotations: List(EffectAnnotation),
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  girard_fn_typed: dict.Dict(String, Set(String)),
) -> #(List(Violation), List(Warning)) {
  let context =
    extract.build_import_context(module)
    |> extract.with_factories(extract.factory_map(module))
    |> extract.with_cross_factories(effects.factories(knowledge_base))
  let function_map = build_function_map(module)
  let cache = build_scc_ids(module, context, girard_fn_typed, True)

  // One memo table threaded across every annotation: same-module callees shared
  // between annotations are analysed once.
  let #(_memo, results) =
    list.map_fold(annotations, new_memo(), fn(memo, annotation) {
      let #(result, memo) =
        check_annotation(
          annotation,
          function_map,
          context,
          knowledge_base,
          registry,
          module_types,
          cache,
          memo,
        )
      #(memo, result)
    })
  let violations = list.flat_map(results, fn(r) { r.0 })
  let warnings = list.flat_map(results, fn(r) { r.1 })
  #(violations, warnings)
}

// Infer the effect set for every public function in a module.
// Pass existing `check` annotations so their param bounds are used during inference.
pub fn infer(
  module: Module,
  knowledge_base: KnowledgeBase,
  existing_checks: List(EffectAnnotation),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  girard_fn_typed: dict.Dict(String, Set(String)),
) -> List(EffectAnnotation) {
  infer_with_returns(
    module,
    knowledge_base,
    existing_checks,
    registry,
    module_types,
    girard_fn_typed,
  ).0
}

// Like `infer`, but also returns each public function's *returned operator*
// (bare function name → the operator it returns) for functions that return a
// function — so the topological pass can thread them into the knowledge base
// for downstream `let h = producer(); with(h)` consumers.
pub fn infer_with_returns(
  module: Module,
  knowledge_base: KnowledgeBase,
  existing_checks: List(EffectAnnotation),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  girard_fn_typed: dict.Dict(String, Set(String)),
) -> #(List(EffectAnnotation), dict.Dict(String, EffectTerm)) {
  let context =
    extract.build_import_context(module)
    |> extract.with_factories(extract.factory_map(module))
    |> extract.with_cross_factories(effects.factories(knowledge_base))
  let function_map = build_function_map(module)
  let cache = build_scc_ids(module, context, girard_fn_typed, True)

  let public_functions =
    list.filter(module.functions, fn(definition) {
      definition.definition.publicity == glance.Public
    })

  // Returned operators of public functions that return a function — recorded so
  // downstream consumers resolve `let h = producer(); with(h)`. One memo table
  // is threaded through this pass and reused for the inference pass below.
  let #(memo, returned_pairs) =
    list.map_fold(public_functions, new_memo(), fn(memo, definition) {
      let #(returned, memo) =
        compute_returned_operator(
          definition.definition,
          context,
          function_map,
          knowledge_base,
          set.new(),
          registry,
          module_types,
          cache,
          memo,
        )
      #(
        memo,
        result.map(returned, fn(operator) {
          #(definition.definition.name, operator)
        }),
      )
    })
  let returned_operators =
    returned_pairs |> list.filter_map(fn(pair) { pair }) |> dict.from_list()

  // Seed param bounds from existing `check` annotations only — `effects`
  // annotations don't carry user-declared bounds, so they can't constrain
  // higher-order parameters during inference.
  let bounds_map =
    existing_checks
    |> list.filter(fn(annotation) { annotation.params != [] })
    |> list.map(fn(annotation) { #(annotation.function, annotation.params) })
    |> dict.from_list()

  let #(_memo, annotations) =
    list.map_fold(public_functions, memo, fn(memo, definition) {
      let param_bounds =
        dict.get(bounds_map, definition.definition.name)
        |> result.unwrap([])
      // Auto-detect fn-typed parameters from glance type annotations so
      // calls to them produce effect variables instead of [Unknown].
      // Parameters that already have a user-declared bound take priority
      // and are excluded from auto-detection.
      let declared_bound_names =
        param_bounds |> list.map(fn(b) { b.name }) |> set.from_list()
      // Function-typed parameters: girard's inferred signature (covers params
      // with no `fn(...)` annotation) unioned with the syntactic detection (the
      // fallback when girard skipped this function).
      let fn_typed_params =
        signatures.fn_typed_params_from_function(definition.definition)
        |> set.union(typeinfo.fn_typed_params(
          girard_fn_typed,
          definition.definition.name,
        ))
        |> set.filter(fn(name) { !set.contains(declared_bound_names, name) })
      let effective_bounds =
        list.append(param_bounds, synthetic_fn_typed_bounds(fn_typed_params))
      // A bodyless `@external` is opaque FFI — conservatively `[Unknown]`, not
      // the `[]` its empty body would otherwise infer.
      let #(effects_term, memo) = case is_opaque_external(definition) {
        True -> #(effect_term.unknown(), memo)
        False -> {
          let #(pairs, memo) =
            collect_effects(
              without_returned_closure(definition.definition),
              function_map,
              context,
              knowledge_base,
              set.new(),
              effective_bounds,
              registry,
              module_types,
              dict.new(),
              cache,
              memo,
            )
          #(union_of(pairs), memo)
        }
      }
      // If the function's inferred effects reference effect variables
      // (because it calls fn-typed params), emit ParamBound entries so
      // the polymorphic annotation round-trips correctly.
      let inferred_params =
        polymorphic_param_bounds(effects_term, fn_typed_params)
      #(
        memo,
        EffectAnnotation(
          kind: Effects,
          function: definition.definition.name,
          params: inferred_params,
          effects: effects_term,
        ),
      )
    })
  #(annotations, returned_operators)
}

// The effect of the callback an operator parameter is applied to. The callback
// isn't assumed to be first: `callback_position` is the operator parameter's
// own callback argument index (from its type signature, see
// `signatures.operator_params_from_function`), so `action(config, cb)` resolves
// `cb` and not `config`. Pipe-adjusted call positions already align with the
// operator's logical argument positions (the piped receiver takes position 0),
// so the index applies directly. A missing argument at a callback position means
// the operator is under-applied (a partial application whose deferred effect we
// can't resolve here), so it collapses to `[Unknown]` rather than `pure()` — the
// effect must never be silently dropped.
fn operator_argument_effect(
  call_args: dict.Dict(Int, List(types.CallArgument)),
  span_start: Int,
  callback_position: Int,
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
) -> EffectTerm {
  let args = dict.get(call_args, span_start) |> result.unwrap([])
  case list.find(args, fn(a) { a.position == callback_position }) {
    Ok(arg) ->
      resolve_argument_effects(arg, knowledge_base, caller_param_bounds)
    Error(Nil) -> effect_term.unknown()
  }
}

// Build a call to a second-order parameter as a *curried* effect-operator
// application over all its callback arguments, in order: `action(cb1, cb2)` ⟹
// `((action e1) e2)`. Left-nesting matches the binder order of the lifted
// operator, so each callback beta-reduces against the right binder once the
// operator is bound at a call site.
fn curried_operator_application(
  operator: EffectTerm,
  callback_positions: List(Int),
  call_args: dict.Dict(Int, List(types.CallArgument)),
  span_start: Int,
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
) -> EffectTerm {
  list.fold(callback_positions, operator, fn(acc, position) {
    types.TApp(
      acc,
      operator_argument_effect(
        call_args,
        span_start,
        position,
        knowledge_base,
        caller_param_bounds,
      ),
    )
  })
}

// A bound whose effect is the single variable named after the param
// itself — `TVar(name)`. The variable refers to itself, resolved later by
// substitution at call sites. When the matching argument is an effect
// *operator* (a `TAbs`), binding `name` to it and beta-reducing is exactly
// what resolves a second-order call.
fn self_referential_bound(name: String) -> ParamBound {
  ParamBound(name, TVar(name))
}

// True iff a term still carries unresolved (free) effect variables.
fn has_vars(term: EffectTerm) -> Bool {
  !set.is_empty(effect_term.free_vars(term))
}

// Union the effect terms of a list of `(call, term)` pairs, normalizing once.
fn union_of(pairs: List(#(types.ResolvedCall, EffectTerm))) -> EffectTerm {
  effect_term.normalize(TUnion(list.map(pairs, fn(pair) { pair.1 })))
}

// Synthesise a self-referential polymorphic bound for each auto-detected
// fn-typed parameter. Seeding these into `param_bounds` lets the body
// walker treat direct calls to, and forwarded uses of, the param
// uniformly with user-declared bounds.
fn synthetic_fn_typed_bounds(fn_typed_params: Set(String)) -> List(ParamBound) {
  fn_typed_params
  |> set.to_list()
  |> list.map(self_referential_bound)
}

// Build a `ParamBound` for each free effect variable in `term` whose name is
// a fn-typed parameter. Each is self-referential (`TVar(name)`), resolved by
// substitution at call sites — so the polymorphic signature round-trips.
fn polymorphic_param_bounds(
  term: EffectTerm,
  fn_typed_params: Set(String),
) -> List(ParamBound) {
  term
  |> effect_term.free_vars()
  |> set.to_list()
  |> list.filter(fn(v) { set.contains(fn_typed_params, v) })
  |> list.sort(string.compare)
  |> list.map(self_referential_bound)
}

// PRIVATE

// A function's body with a trailing *returned closure* dropped. A closure is
// lazy: a function that returns one runs nothing of that closure when *called* —
// its effects happen when the returned closure is later applied, and are
// accounted there (via the returned operator, or the conservative `[Unknown]`
// for an untracked application). Excluding it from the direct call-effect
// removes a spurious over-approximation (e.g. a decorator's `io.println` leaking
// into the producer call) while staying sound. Only a bare tail `Fn` is trimmed;
// other returned-closure shapes keep the conservative behaviour.
fn without_returned_closure(function: Function) -> Function {
  case list.reverse(function.body) {
    [glance.Expression(glance.Fn(..)), ..rest] ->
      Function(..function, body: list.reverse(rest))
    _ -> function
  }
}

// Map a module's functions by name — for transitive same-module resolution.
pub fn build_function_map(
  module: Module,
) -> dict.Dict(String, Definition(Function)) {
  module.functions
  |> list.map(fn(definition) { #(definition.definition.name, definition) })
  |> dict.from_list()
}

// The call-graph strongly-connected-component structure of a module, threaded
// read-only through the analysis to drive same-module memoization (see
// `memoized_local`). Without memoization a densely mutually-recursive module
// (a recursive-descent parser, a `use`-chained codec) re-walks each callee once
// per distinct call path — combinatorial blow-up. The component structure makes
// two memo strategies possible, each keeping results identical to the
// un-memoized walk:
//
// - A **collapsible** component (every member first-order) shares one
//   full-reachability effect set across all members, computed once.
// - Any other callee is keyed by `#(callee, visited ∩ callee's SCC)`: its
//   result depends on the caller's `visited` only through same-SCC ancestors
//   (the back-edges cycle-truncation cuts), so that key is exact.
pub type LocalCache {
  LocalCache(
    // Function name → its call-graph SCC id.
    scc_id: dict.Dict(String, Int),
    // SCC id → the names of its member functions.
    members: dict.Dict(Int, List(String)),
    // SCC ids that may be *collapsed*: every member is first-order (no fn-typed
    // params) and has a body. Such a component's members are all mutually
    // reachable, so they share one full-reachability effect set — computed once
    // and reused by name. A component with an effect-polymorphic member instead
    // uses the precise `visited ∩ SCC` key, where the result is path-dependent.
    collapsible: Set(Int),
  )
}

// Index a module's functions by call-graph SCC, recording for each component
// its members and whether it is collapsible.
//
// `girard_fn_typed` carries girard's per-function fn-typed parameter names so a
// parameter that *infers* to a function without a `fn(...)` annotation is still
// recognised as effect-polymorphic — those, syntactic fn-typed params, and
// `@external` functions are all excluded from collapsible components, since the
// collapse pools members' effect *sets* and a free effect variable doesn't
// belong to every member. `collapse` is `False` for callers that can't supply
// girard's view (the constructor-field index), forcing the always-correct
// precise key everywhere. Exposed so the constructor-field index can build it
// once and reuse it across the closures it lifts.
pub fn build_scc_ids(
  module: Module,
  context: ImportContext,
  girard_fn_typed: dict.Dict(String, Set(String)),
  collapse: Bool,
) -> LocalCache {
  let definitions = module.functions
  // Module-local type aliases that resolve to a function type, so a parameter
  // typed with one (`dec: SizedDecoder(a)` where `type SizedDecoder(a) =
  // fn(...)`) is recognised as effect-polymorphic. This is the deterministic,
  // syntax-only counterpart to girard's inference: relying on girard alone here
  // is unsound under load — girard is best-effort and can decline a function
  // (e.g. when a dependency import races under concurrent disk I/O), which would
  // silently drop a fn-typed parameter and let an effect-polymorphic function be
  // wrongly collapsed. Resolving aliases ourselves keeps the collapse decision
  // independent of girard's availability.
  let fn_aliases = function_type_aliases(module.type_aliases)
  let needs_exact =
    list.filter_map(definitions, fn(definition) {
      let name = definition.definition.name
      let first_order =
        signatures.fn_typed_params_from_function(definition.definition)
        |> set.union(alias_fn_typed_params(definition.definition, fn_aliases))
        |> set.union(typeinfo.fn_typed_params(girard_fn_typed, name))
        |> set.is_empty()
      case first_order && !is_opaque_external(definition) {
        True -> Error(Nil)
        False -> Ok(name)
      }
    })
    |> set.from_list()
  topo.scc_order(local_call_graph(definitions, context))
  |> list.index_fold(
    LocalCache(dict.new(), dict.new(), set.new()),
    fn(cache, component, id) {
      let scc_id =
        list.fold(component, cache.scc_id, fn(ids, name) {
          dict.insert(ids, name, id)
        })
      let collapsible = case
        collapse
        && !list.any(component, fn(name) { set.contains(needs_exact, name) })
      {
        True -> set.insert(cache.collapsible, id)
        False -> cache.collapsible
      }
      LocalCache(
        scc_id:,
        members: dict.insert(cache.members, id, component),
        collapsible:,
      )
    },
  )
}

// Names of module-local type aliases that resolve (transitively, through other
// aliases) to a function type. `type Decoder(a) = fn(...)` and an alias of such
// an alias both qualify; an alias to a record or tuple does not.
fn function_type_aliases(
  aliases: List(Definition(glance.TypeAlias)),
) -> Set(String) {
  let alias_map =
    list.fold(aliases, dict.new(), fn(acc, definition) {
      dict.insert(
        acc,
        definition.definition.name,
        definition.definition.aliased,
      )
    })
  list.filter_map(dict.keys(alias_map), fn(name) {
    case
      resolves_to_function(
        glance.NamedType(Span(0, 0), name, None, []),
        alias_map,
        set.new(),
      )
    {
      True -> Ok(name)
      False -> Error(Nil)
    }
  })
  |> set.from_list()
}

// Does `type_` denote a function — directly (`fn(...)`) or via a chain of
// module-local aliases? `seen` guards against alias cycles (which Gleam rejects,
// but the walk must terminate regardless).
fn resolves_to_function(
  type_: glance.Type,
  alias_map: dict.Dict(String, glance.Type),
  seen: Set(String),
) -> Bool {
  case type_ {
    glance.FunctionType(..) -> True
    glance.NamedType(name:, module: None, ..) ->
      case set.contains(seen, name) {
        True -> False
        False ->
          case dict.get(alias_map, name) {
            Ok(aliased) ->
              resolves_to_function(aliased, alias_map, set.insert(seen, name))
            // Not an alias (a custom type or prelude type) — not a function.
            Error(Nil) -> False
          }
      }
    _ -> False
  }
}

// Parameters of `function` whose declared type resolves to a function through a
// module-local alias. The direct `fn(...)` case is already covered by
// `signatures.fn_typed_params_from_function`; this adds the alias-resolved ones.
fn alias_fn_typed_params(
  function: Function,
  fn_aliases: Set(String),
) -> Set(String) {
  list.filter_map(function.parameters, fn(parameter) {
    case parameter.name, parameter.type_ {
      glance.Named(name),
        Some(glance.NamedType(name: type_name, module: None, ..))
      ->
        case set.contains(fn_aliases, type_name) {
          True -> Ok(name)
          False -> Error(Nil)
        }
      _, _ -> Error(Nil)
    }
  })
  |> set.from_list()
}

// Build the same-module call graph: each function mapped to the same-module
// functions its analysis can transitively recurse into. Deriving these from the
// extractor — the same pass that drives resolution — makes the
// strongly-connected-component structure match the truncation relation exactly.
// That agreement matters: a *split* of a real cycle makes `collapsed_scc`
// re-enter itself across the spurious boundary, never hitting its in-progress
// cache (an exponential blow-up); a *merge* of unrelated functions
// over-approximates the collapsed effect. A looser reference scan risks both.
fn local_call_graph(
  definitions: List(Definition(Function)),
  context: ImportContext,
) -> dict.Dict(String, Set(String)) {
  let names =
    definitions
    |> list.map(fn(definition) { definition.definition.name })
    |> set.from_list()
  list.fold(definitions, dict.new(), fn(graph, definition) {
    let edges = recursion_edges(definition.definition, context, names)
    dict.insert(graph, definition.definition.name, edges)
  })
}

// The memo key for a local call: the callee name plus the sorted subset of the
// current `visited` ancestors that share the callee's SCC. Those ancestors are
// exactly the back-edges cycle-truncation can cut, so two calls with the same
// key truncate identically and yield the same `(call, effect)` list. A callee
// on no cycle has no same-SCC ancestors, so its key is always `#(name, [])`.
fn memo_key(
  name: String,
  visited: Set(String),
  cache: LocalCache,
) -> #(String, List(String)) {
  let scc = dict.get(cache.scc_id, name)
  let ancestors =
    visited
    |> set.to_list()
    |> list.filter(fn(ancestor) { dict.get(cache.scc_id, ancestor) == scc })
    |> list.sort(string.compare)
  #(name, ancestors)
}

// Per-module memo tables, threaded through same-module effect analysis as
// explicit immutable state: every memoized function takes a `Memo` and returns
// the (possibly extended) table alongside its result. A fresh `new_memo()` is
// created at each top-level analysis entry (`infer_with_returns`, `check`,
// `closure_field_operator`), so a module's memoized sub-results never leak into
// the next module's analysis. Threading a value beats a process-dictionary memo:
// the analysis stays referentially transparent and the persistent-dict cost is
// negligible.
type Memo {
  Memo(
    // Polymorphic same-module call analyses, keyed by callee + same-SCC
    // ancestors (see `memo_key`).
    locals: dict.Dict(
      #(String, List(String)),
      List(#(ResolvedCall, EffectTerm)),
    ),
    // Collapsible-SCC full-reachability analyses, keyed by SCC id.
    sccs: dict.Dict(Int, List(#(ResolvedCall, EffectTerm))),
    // Operator-lifts of same-module function references, keyed by name +
    // same-SCC ancestors.
    lifts: dict.Dict(#(String, List(String)), EffectTerm),
    // Closure analyses, keyed by body position, lifting positions, ambient
    // operator names, and visited ancestors.
    closures: dict.Dict(
      #(Int, List(Int), List(String), List(String)),
      EffectTerm,
    ),
  )
}

fn new_memo() -> Memo {
  Memo(
    locals: dict.new(),
    sccs: dict.new(),
    lifts: dict.new(),
    closures: dict.new(),
  )
}

// The same-module functions a function actually calls or references as a
// value — its call-graph edges. Computed as the **free** variables of the body
// (those *not* bound by a parameter, `let`, `use`, `fn`, or `case` pattern)
// intersected with the module's function names. Tracking bindings is essential:
// a parameter or local that shadows a sibling function's name (`fn apply(func,
// …)` alongside a `func` function) is a reference to the local, not the
// function, and must not create a spurious edge — a spurious edge merges
// unrelated components, and the SCC-collapse memo would then pool their effects.
// The same-module functions `function`'s analysis recurses into, intersected
// with the module's function names. Mirrors the three same-module recursion
// sites in `collect_effects`: unresolved local calls (`resolve_unknown_local`),
// a let-bound returned operator's same-module producer
// (`resolve_returned_operator`), and a same-module function reference handed to
// an operator parameter (`lift_local_function`, reached when the argument is a
// `LocalRef`). Calls inside nested closures are already flattened into the
// extractor's result, so they are covered too.
fn recursion_edges(
  function: Function,
  context: ImportContext,
  names: Set(String),
) -> Set(String) {
  let result = extract.extract_calls(function.body, context)
  let local = list.map(result.local, fn(call) { call.function })
  let returned =
    list.filter_map(result.direct_ops, fn(op) {
      case op.callee.module {
        "" -> Ok(op.callee.function)
        _ -> Error(Nil)
      }
    })
  let lifted =
    result.call_args
    |> dict.values()
    |> list.flatten()
    |> list.filter_map(fn(argument) {
      case argument.value {
        types.LocalRef(name) -> Ok(name)
        _ -> Error(Nil)
      }
    })
  list.flatten([local, returned, lifted])
  |> set.from_list()
  |> set.intersection(names)
}

// A function declared `@external(...)` is opaque foreign code: graded cannot see
// what the native implementation does, so its effect is the conservative
// `[Unknown]` by default — never the `[]` an empty (or pure-looking fallback)
// body might suggest. Authors opt in to a precise effect by annotating it with
// an `external effects … : [...]` line (or via the versioned catalog), which
// wins at resolution time. This holds even when the `@external` also carries a
// Gleam fallback body: that body only runs on the *other* compile target, where
// the foreign function may still differ, so trusting it would be unsound.
fn is_opaque_external(definition: Definition(Function)) -> Bool {
  list.any(definition.attributes, fn(attribute) { attribute.name == "external" })
}

// Lift a record field wired to an inline closure into an effect *operator*,
// abstracting over every closure parameter. A first-order field
// (`to_error: fn(m) { io.println(m) }`) becomes `λm. [Stdout]` (applying it to
// the field call's argument gives `[Stdout]` back); a higher-order field
// (`run: fn(next) { next() }`) becomes `λnext. [next]` (applying it gives the
// callback's effect). `resolve_field_effect` applies the operator at the field
// call. `function_map` resolves same-module calls; a minimal registry/types is
// enough for the common case of a closure calling library/qualified functions.
pub fn closure_field_operator(
  params: List(String),
  body: List(Statement),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  // The module's SCC ids, built once by the caller (`build_scc_ids`) and reused
  // across every field closure it analyses.
  scc_ids: LocalCache,
) -> EffectTerm {
  // Independent analysis entry (called while building the construction index,
  // not under `infer`/`check`): start from a fresh memo so no other module's
  // entries leak in. Each call gets its own memo — these closures are shallow,
  // so not sharing across fields costs nothing.
  // Abstract over every parameter (positions 0..n-1), in order.
  let positions = list.index_map(params, fn(_, index) { index })
  analyze_closure(
    params,
    body,
    positions,
    context,
    function_map,
    knowledge_base,
    set.new(),
    signatures.empty(),
    dict.new(),
    dict.new(),
    scc_ids,
    new_memo(),
  ).0
}

fn check_annotation(
  annotation: EffectAnnotation,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(#(List(Violation), List(Warning)), Memo) {
  case dict.get(function_map, annotation.function) {
    // Silently skip: the annotation may be stale or apply to a different
    // build target. Missing functions are not an error.
    Error(Nil) -> #(#([], []), memo)
    Ok(function_definition) -> {
      let #(body_effects, memo) =
        collect_effects(
          without_returned_closure(function_definition.definition),
          function_map,
          context,
          knowledge_base,
          set.new(),
          annotation.params,
          registry,
          module_types,
          dict.new(),
          cache,
          memo,
        )
      // A call is a violation when its effect set is not a subset of the
      // declared budget — i.e. it performs effects the caller didn't allow.
      // Both sides are reduced to their ground normal form first.
      let declared = effect_term.to_effect_set(annotation.effects)
      let violations =
        body_effects
        |> list.filter_map(fn(pair) {
          let #(call, call_term) = pair
          let actual = effect_term.to_effect_set(call_term)
          case types.is_subset(actual, declared) {
            True -> Error(Nil)
            False ->
              Ok(Violation(
                function: annotation.function,
                call: call.name,
                span: call.span,
                declared:,
                actual:,
              ))
          }
        })

      // Warn about function references passed as values with known non-pure effects.
      let extract_result =
        extract.extract_calls(function_definition.definition.body, context)
      let warnings =
        collect_reference_warnings(
          annotation.function,
          extract_result.references,
          knowledge_base,
        )

      #(#(violations, warnings), memo)
    }
  }
}

fn collect_reference_warnings(
  function_name: String,
  references: List(types.ResolvedCall),
  knowledge_base: KnowledgeBase,
) -> List(Warning) {
  list.filter_map(references, fn(ref) {
    case effects.lookup(knowledge_base, ref.name) {
      effects.Known(term) -> {
        let effect_set = effect_term.to_effect_set(term)
        case effect_set == types.empty() {
          True -> Error(Nil)
          False ->
            Ok(UntrackedEffectWarning(
              function: function_name,
              reference: ref.name,
              span: ref.span,
              effects: effect_set,
            ))
        }
      }
      effects.Unknown -> Error(Nil)
    }
  })
}

// Collect all (call, effect_term) pairs reachable from a function body. Each
// effect is an `EffectTerm` — possibly still carrying free variables or operator
// applications — reduced to an `EffectSet` only at the subset-check boundary.
// Calls fall into three categories:
//   resolved — qualified module.function calls, looked up in the knowledge base
//   local    — unqualified calls, resolved via param bounds or transitive analysis
//   field    — object.method calls, resolved via type field annotations
// `visited` tracks functions already on the call stack for cycle detection.
fn collect_effects(
  function: Function,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  // Operator parameters in scope from an *enclosing* function (a producer whose
  // returned closure we're analysing), so a call to one becomes a curried
  // operator application rather than `[Unknown]`. Empty for an ordinary function.
  ambient_operators: dict.Dict(String, List(Int)),
  // Memoized same-module body analyses, keyed by function name. Lets the local-
  // call path resolve a cacheable callee in O(1) instead of re-walking its body.
  cache: LocalCache,
  // Threaded memo state, extended as memoizable sub-analyses are computed.
  memo: Memo,
) -> #(List(#(types.ResolvedCall, EffectTerm)), Memo) {
  let result = extract.extract_calls(function.body, context)
  let operator_params =
    dict.merge(
      ambient_operators,
      signatures.operator_params_from_function(function),
    )
  let lift_operator_arg =
    build_lift_operator_arg(
      context,
      function_map,
      knowledge_base,
      visited,
      registry,
      module_types,
      ambient_operators,
      cache,
    )

  // Resolved calls: qualified names looked up directly in the knowledge
  // base. If the callee's effects are polymorphic (contain effect
  // variables), bind the variables by matching arguments at fn-typed
  // parameter positions and substitute for concrete effects.
  let #(memo, resolved_effects) =
    list.map_fold(result.resolved, memo, fn(memo, call) {
      let effect_set = effects.lookup_effects(knowledge_base, call.name)
      let #(concrete, memo) =
        substitute_at_call_site(
          call,
          effect_set,
          result.call_args,
          knowledge_base,
          param_bounds,
          registry,
          lift_operator_arg,
          memo,
        )
      #(memo, #(call, concrete))
    })

  // Local calls: check param bounds first (user-declared and auto-detected
  // fn-typed bounds both live here), then fall back to transitive analysis
  // of local definitions.
  let #(memo, local_effects_nested) =
    list.map_fold(result.local, memo, fn(memo, local_call) {
      case
        list.find(param_bounds, fn(param) { param.name == local_call.function })
      {
        Ok(bound) -> {
          let synthetic_call =
            types.ResolvedCall(
              name: QualifiedName(
                module: "<param>",
                function: local_call.function,
              ),
              span: local_call.span,
            )
          // A call to a fn-typed parameter contributes that parameter's effect
          // variable. If the parameter is *second-order* (an operator — its own
          // type takes one or more functions), the call is a *curried*
          // effect-operator application over all its callback arguments, in
          // order: `action(cb1, cb2)` ⟹ `((action e1) e2)`. Folding left-nests
          // the applications so each binder of the lifted operator (abstracted
          // in the same order) beta-reduces against the matching callback once
          // the operator is bound at a call site.
          let effect = case dict.get(operator_params, local_call.function) {
            Error(Nil) -> bound.effects
            Ok(positions) ->
              curried_operator_application(
                bound.effects,
                positions,
                result.call_args,
                local_call.span.start,
                knowledge_base,
                param_bounds,
              )
          }
          #(memo, [#(synthetic_call, effect)])
        }
        Error(Nil) -> {
          let #(recursive, memo) =
            resolve_unknown_local(
              local_call,
              visited,
              function_map,
              context,
              knowledge_base,
              registry,
              module_types,
              cache,
              memo,
            )
          substitute_local_call_effects(
            recursive,
            local_call,
            result.call_args,
            function_map,
            knowledge_base,
            param_bounds,
            registry,
            lift_operator_arg,
            memo,
          )
          |> fn(pair) { #(pair.1, pair.0) }
        }
      }
    })
  let local_effects = list.flatten(local_effects_nested)

  // Field calls: object.method(args) resolved via type field annotations.
  let #(memo, field_effects) =
    list.map_fold(result.field, memo, fn(memo, field_call) {
      let synthetic_call =
        types.ResolvedCall(
          name: QualifiedName(
            module: "<field>",
            function: field_call.object <> "." <> field_call.label,
          ),
          span: field_call.span,
        )
      let #(effect_set, memo) =
        resolve_field_call(
          field_call,
          function,
          knowledge_base,
          module_types,
          result.call_args,
          param_bounds,
          registry,
          lift_operator_arg,
          memo,
        )
      #(memo, #(synthetic_call, effect_set))
    })

  // Direct applications of a let-bound returned operator: `let h = pick(); h(cb)`.
  // Resolve the producer's returned operator, then apply it to this call's own
  // arguments (curried over the operator's binders). Untraceable producers
  // resolve to [Unknown], exactly as the previous local-call path did.
  let #(memo, direct_op_effects) =
    list.map_fold(result.direct_ops, memo, fn(memo, op) {
      let synthetic_call =
        types.ResolvedCall(
          name: QualifiedName(
            module: "<returned>",
            function: op.callee.function,
          ),
          span: op.span,
        )
      let #(resolved_op, memo) =
        resolve_returned_operator(
          op.callee,
          op.producer_args,
          context,
          function_map,
          knowledge_base,
          visited,
          registry,
          module_types,
          cache,
          memo,
        )
      let effect = case resolved_op {
        Ok(operator) -> {
          let positions = positions_up_to(operator_spine_arity(operator))
          curried_operator_application(
            operator,
            positions,
            result.call_args,
            op.span.start,
            knowledge_base,
            param_bounds,
          )
        }
        Error(Nil) -> effect_term.unknown()
      }
      #(memo, #(synthetic_call, effect))
    })

  // Pipe into an inline closure / case of functions (`x |> fn(f) { f() }`):
  // lift the target to an operator over its first parameter and apply the piped
  // value (argument 0). Resolving this fixes an understatement — walking the
  // target as a value dropped its use of the piped value.
  let #(memo, direct_pipe_effects) =
    list.map_fold(result.direct_pipe_ops, memo, fn(memo, op) {
      let synthetic_call =
        types.ResolvedCall(
          name: QualifiedName(module: "<pipe>", function: "<operator>"),
          span: op.span,
        )
      let #(operator, memo) =
        operator_term_for_argument(
          types.CallArgument(position: 0, label: None, value: op.value),
          [0],
          knowledge_base,
          param_bounds,
          registry,
          lift_operator_arg,
          memo,
        )
      let effect =
        curried_operator_application(
          operator,
          [0],
          result.call_args,
          op.span.start,
          knowledge_base,
          param_bounds,
        )
      #(memo, #(synthetic_call, effect))
    })

  #(
    list.flatten([
      resolved_effects,
      local_effects,
      field_effects,
      direct_op_effects,
      direct_pipe_effects,
    ]),
    memo,
  )
}

// `[0, 1, …, n-1]` — the callback positions of an `n`-ary operator, applied
// in order. Empty for `n <= 0`.
fn positions_up_to(n: Int) -> List(Int) {
  positions_loop(n - 1, [])
}

fn positions_loop(i: Int, acc: List(Int)) -> List(Int) {
  case i < 0 {
    True -> acc
    False -> positions_loop(i - 1, [i, ..acc])
  }
}

// The effect of an argument bound to a *first-order* fn-typed parameter. A
// closure's effect is the effect of *calling* it — its body — recovered by
// lifting and discharging the (value) parameters, rather than collapsing to
// [Unknown]. Covers a `use` callback (`use r <- with_thing()`) and any inline
// closure passed to a first-order higher-order function. Anything else takes
// its flat effect.
fn first_order_arg_effect(
  arg: types.CallArgument,
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(EffectTerm, Memo) {
  case arg.value {
    types.Closure(_, _) -> {
      let #(lifted, memo) = lift_operator_arg(arg.value, [], memo)
      case lifted {
        Ok(operator) -> #(discharge_operator(operator), memo)
        Error(Nil) -> #(
          resolve_argument_effects(arg, knowledge_base, caller_param_bounds),
          memo,
        )
      }
    }
    _ -> #(
      resolve_argument_effects(arg, knowledge_base, caller_param_bounds),
      memo,
    )
  }
}

// Recover a first-order closure's body effect from its lifted operator by
// discharging each value parameter to `pure` (`λr. body ↦ body`). Used when a
// closure is bound to a first-order fn-typed parameter — the effect of calling
// it. A first-order parameter never contributes to the body's *effect*, so the
// substitution is exact.
fn discharge_operator(operator: EffectTerm) -> EffectTerm {
  case operator {
    types.TAbs(param, body) ->
      discharge_operator(
        effect_term.normalize(effect_term.subst(
          body,
          dict.from_list([#(param, effect_term.pure())]),
        )),
      )
    other -> other
  }
}

// The number of leading operator binders a (resolved) returned operator takes
// — its arity, so a direct application `h(cb1, cb2)` can be curried over the
// right number of callback positions. A union of operators shares one arity;
// take the max so a partial member can't shorten the spine.
fn operator_spine_arity(term: EffectTerm) -> Int {
  case term {
    types.TAbs(_, body) -> 1 + operator_spine_arity(body)
    types.TUnion(members) ->
      list.fold(members, 0, fn(max, member) {
        int.max(max, operator_spine_arity(member))
      })
    _ -> 0
  }
}

// Substitute effect variables in the recursive analysis of a local
// (same-module) call. The recursive `collect_effects` returns calls
// from inside the callee whose effects may reference the callee's
// own fn-typed parameters as variables; this resolves those
// variables against the caller's arguments at this call site.
//
// Without this step, a same-module higher-order helper would leak
// `[<var>]` upward — only cross-module calls (which go through
// `substitute_at_call_site`) would get bound.
fn substitute_local_call_effects(
  recursive: List(#(types.ResolvedCall, EffectTerm)),
  local_call: LocalCall,
  call_args: dict.Dict(Int, List(types.CallArgument)),
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(List(#(types.ResolvedCall, EffectTerm)), Memo) {
  let any_polymorphic = list.any(recursive, fn(p) { has_vars(p.1) })
  use <- bool.guard(when: !any_polymorphic, return: #(recursive, memo))
  case dict.get(function_map, local_call.function) {
    Error(Nil) -> #(recursive, memo)
    Ok(local_definition) -> {
      let bounds = local_polymorphic_bounds(local_definition.definition)
      let args = dict.get(call_args, local_call.span.start) |> result.unwrap([])
      let callee_name =
        QualifiedName(module: "<local>", function: local_call.function)
      // The synthetic `<local>` module isn't in `registry`, so build a
      // single-entry registry from this local function's glance AST so
      // positional argument matching has parameter info to work with.
      let local_registry =
        signatures.from_glance_module(
          "<local>",
          glance.Module(
            imports: [],
            custom_types: [],
            type_aliases: [],
            constants: [],
            functions: [local_definition],
          ),
        )
      let merged_registry = signatures.merge(registry, local_registry)
      let #(bindings, memo) =
        bind_variables(
          callee_name,
          bounds,
          args,
          knowledge_base,
          caller_param_bounds,
          merged_registry,
          lift_operator_arg,
          memo,
        )
      let substituted =
        list.map(recursive, fn(pair) {
          let #(call, term) = pair
          #(call, effect_term.normalize(effect_term.subst(term, bindings)))
        })
      #(substituted, memo)
    }
  }
}

// Derive the polymorphic param bounds a local function would carry
// after auto-inference: one bound per fn-typed parameter, with an
// effect variable matching the parameter name.
fn local_polymorphic_bounds(function: Function) -> List(ParamBound) {
  synthetic_fn_typed_bounds(signatures.fn_typed_params_from_function(function))
}

// Resolve effect variables at a call site. If the callee's effects
// carry variables, match arguments to the callee's param bounds and
// bind each variable to the concrete effect set of the corresponding
// argument. `caller_param_bounds` lets us propagate effect bounds
// from the caller's own parameters (when a fn-typed arg is itself
// the caller's parameter).
fn substitute_at_call_site(
  call: types.ResolvedCall,
  effect: EffectTerm,
  call_args: dict.Dict(Int, List(types.CallArgument)),
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(EffectTerm, Memo) {
  let callee_kb_bounds = effects.lookup_param_bounds(knowledge_base, call.name)
  // Fast path: concrete effect with declared bounds — nothing to
  // substitute. With no declared bounds we still need to fall through
  // in case the registry flags auto-injectable fn-typed params.
  use <- bool.guard(
    when: !has_vars(effect) && callee_kb_bounds != [],
    return: #(effect, memo),
  )
  let args = dict.get(call_args, call.span.start) |> result.unwrap([])
  let #(effective_effects, effective_bounds) = case callee_kb_bounds {
    [_, ..] -> #(effect, callee_kb_bounds)
    [] -> auto_bounds_from_registry(call.name, effect, args, registry)
  }
  use <- bool.guard(when: !has_vars(effective_effects), return: #(
    effective_effects,
    memo,
  ))
  let #(bindings, memo) =
    bind_variables(
      call.name,
      effective_bounds,
      args,
      knowledge_base,
      caller_param_bounds,
      registry,
      lift_operator_arg,
      memo,
    )
  #(effect_term.normalize(effect_term.subst(effective_effects, bindings)), memo)
}

// When the KB has no bounds but the registry reports fn-typed params,
// synthesise polymorphic bounds so caller fn-typed args propagate through
// the call. Covers stdlib higher-order functions whose catalog entries
// mark the module pure but don't record callback param bounds.
//
// Bounds are synthesised per fn-typed param, and only when the matching
// argument is a tracked value (FunctionRef / LocalRef / ConstructorRef).
// Inline-closure args are skipped: their bodies are walked separately by
// the extractor, so binding them here would double-count — mixing tracked
// refs and closures in the same call works correctly because each param
// is decided independently.
fn auto_bounds_from_registry(
  callee_name: types.QualifiedName,
  existing_effects: EffectTerm,
  args: List(types.CallArgument),
  registry: SignatureRegistry,
) -> #(EffectTerm, List(ParamBound)) {
  let fn_labels = signatures.fn_typed_param_names(registry, callee_name)
  use <- bool.guard(
    when: set.is_empty(fn_labels),
    return: #(existing_effects, []),
  )
  let tracked_bounds =
    fn_labels
    |> set.to_list()
    |> list.sort(string.compare)
    |> list.filter_map(fn(label) {
      let bound = self_referential_bound(label)
      case find_matching_arg(callee_name, bound, args, registry) {
        Some(arg) ->
          case arg.value {
            // Closures, branches, and other inline expressions are walked
            // separately by the extractor; binding them here would double-count.
            types.Closure(_, _) | types.Choice(_) | types.OtherExpression ->
              Error(Nil)
            _ -> Ok(bound)
          }
        None -> Error(Nil)
      }
    })
  case tracked_bounds {
    [] -> #(existing_effects, [])
    _ -> {
      let tracked_vars = list.map(tracked_bounds, fn(b) { TVar(b.name) })
      #(
        effect_term.normalize(TUnion([existing_effects, ..tracked_vars])),
        tracked_bounds,
      )
    }
  }
}

// Match arguments against a callee's param bounds and produce a
// variable-to-effect-set binding map. For each param bound, find the
// argument at its label (preferred) or position, and resolve the
// argument's effects.
fn bind_variables(
  callee_name: types.QualifiedName,
  callee_bounds: List(ParamBound),
  args: List(types.CallArgument),
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(dict.Dict(String, EffectTerm), Memo) {
  let operator_params = signatures.operator_param_names(registry, callee_name)
  list.fold(callee_bounds, #(dict.new(), memo), fn(state, bound) {
    let #(acc, memo) = state
    // Find the argument matching this parameter by label (caller used
    // an explicit label) or by real parameter position from the
    // registry. If neither matches, the variable stays unresolved.
    let matched = find_matching_arg(callee_name, bound, args, registry)
    case matched {
      Some(arg) -> {
        // For an *operator* parameter the argument is lifted to an effect
        // operator (a `TAbs`, possibly curried over several callbacks) so the
        // callee's `op(cb1, cb2)` application beta-reduces. The callback
        // positions come from the operator parameter's own signature so a
        // closure argument is abstracted over exactly the right parameters. A
        // first-order parameter just takes the argument's flat effect.
        let #(arg_effects, memo) = case
          set.contains(operator_params, bound.name)
        {
          True ->
            operator_term_for_argument(
              arg,
              signatures.operator_callback_positions(
                registry,
                callee_name,
                bound.name,
              ),
              knowledge_base,
              caller_param_bounds,
              registry,
              lift_operator_arg,
              memo,
            )
          False ->
            first_order_arg_effect(
              arg,
              knowledge_base,
              caller_param_bounds,
              lift_operator_arg,
              memo,
            )
        }
        // Bind the bound's free variable(s) to the argument's effect. For a
        // first-order bound `param: [e]` that's the variable `e`; for a self-
        // referential fn-typed bound it's the parameter name itself.
        let var_names =
          bound.effects |> effect_term.free_vars() |> set.to_list()
        let acc =
          list.fold(var_names, acc, fn(d, var) {
            dict.insert(d, var, arg_effects)
          })
        #(acc, memo)
      }
      None -> #(acc, memo)
    }
  })
}

// Lift a call argument bound to an *operator* parameter into an effect operator
// (`TAbs`, curried when the operator takes several callbacks) so the callee's
// `op(cb1, cb2)` application beta-reduces. A function reference `g` becomes
// `λp1. λp2. <g's effect>`, abstracting over all of `g`'s callback parameters in
// order; an inline closure or a same-module named function is lifted by
// `lift_operator_arg` (which has the analysis context). `positions` are the
// operator parameter's callback argument indices, used to abstract a closure
// over exactly those parameters. Anything else falls back to its flat effect
// (leaving the application stuck → `[Unknown]`).
fn operator_term_for_argument(
  arg: types.CallArgument,
  positions: List(Int),
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(EffectTerm, Memo) {
  case arg.value {
    types.FunctionRef(name) -> {
      let body = effects.lookup_effects(knowledge_base, name)
      // Abstract over `g`'s fn-typed params in declaration order. The outermost
      // binder is the first param, matching the left-nested application spine
      // built at the definition site.
      let operator =
        signatures.fn_typed_param_names_ordered(registry, name)
        |> list.fold_right(body, fn(acc, param) { types.TAbs(param, acc) })
      #(operator, memo)
    }
    // A branch over function-like options: lift each, then join the operators —
    // `(f ⊔ g)(cb) = f(cb) ⊔ g(cb)`, an over-approximation of every branch.
    types.Choice(options) -> {
      let #(memo, operators) =
        list.map_fold(options, memo, fn(memo, option) {
          let #(op, memo) =
            operator_term_for_argument(
              types.CallArgument(..arg, value: option),
              positions,
              knowledge_base,
              caller_param_bounds,
              registry,
              lift_operator_arg,
              memo,
            )
          #(memo, op)
        })
      #(join_operators(operators), memo)
    }
    _ -> {
      let #(lifted, memo) = lift_operator_arg(arg.value, positions, memo)
      case lifted {
        Ok(operator) -> #(operator, memo)
        Error(Nil) -> #(
          resolve_argument_effects(arg, knowledge_base, caller_param_bounds),
          memo,
        )
      }
    }
  }
}

// Join several lifted operators into one that over-approximates all of them:
// `λp. ⊔ bodies`. Descends the `TAbs` spines in lockstep, alpha-renaming each
// operator's binder to the first's (capture-avoiding, no fresh names), and
// unions the leaves. A spine-length mismatch (mixed abstraction / non-operator)
// can't happen for well-typed branches but collapses conservatively to
// `[Unknown]` if it does.
fn join_operators(terms: List(EffectTerm)) -> EffectTerm {
  case terms {
    [] -> effect_term.unknown()
    [single] -> single
    _ -> {
      let abstractions =
        list.filter_map(terms, fn(term) {
          case term {
            types.TAbs(param, body) -> Ok(#(param, body))
            _ -> Error(Nil)
          }
        })
      let all_abstractions = list.length(abstractions) == list.length(terms)
      case abstractions {
        // All operators (same arity): descend under the first's binder, renaming
        // the rest to it, and recurse on the bodies.
        [#(binder, _), ..] if all_abstractions -> {
          let bodies = list.map(abstractions, rename_binder(binder, _))
          types.TAbs(binder, join_operators(bodies))
        }
        // At least one operator but not all — arity mismatch, be safe.
        [_, ..] -> effect_term.unknown()
        // All leaves: union the ground effects.
        [] -> effect_term.normalize(types.TUnion(terms))
      }
    }
  }
}

// Alpha-rename an abstraction's body to use `binder` in place of its own
// parameter, so several operators can be joined under one shared binder.
fn rename_binder(
  binder: String,
  abstraction: #(String, EffectTerm),
) -> EffectTerm {
  let #(param, body) = abstraction
  case param == binder {
    True -> body
    False ->
      effect_term.subst(body, dict.from_list([#(param, types.TVar(binder))]))
  }
}

// Build the closure that lifts an operator argument we can only resolve with a
// function's analysis context — an inline closure (analyse its body), a
// same-module named function (transitively analyse its definition, since
// siblings aren't in the KB during their module's inference pass), or a
// returned operator (`pick()` — resolve the producer's inferred returned
// operator from the KB, or on-demand for a same-module producer). `positions`
// are the operator parameter's callback argument indices. `visited` guards the
// recursion (self-reference / cyclic producers).
fn build_lift_operator_arg(
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  ambient_operators: dict.Dict(String, List(Int)),
  cache: LocalCache,
) -> fn(types.ArgumentValue, List(Int), Memo) ->
  #(Result(EffectTerm, Nil), Memo) {
  fn(value: types.ArgumentValue, positions: List(Int), memo: Memo) {
    case value {
      types.Closure(params, body) -> {
        let #(operator, memo) =
          analyze_closure(
            params,
            body,
            positions,
            context,
            function_map,
            knowledge_base,
            visited,
            registry,
            module_types,
            ambient_operators,
            cache,
            memo,
          )
        #(Ok(operator), memo)
      }
      types.LocalRef(name) ->
        // Guard against a function passed as an operator argument to itself:
        // `visited` already carries the call stack, so a name on it would loop.
        case set.contains(visited, name), dict.get(function_map, name) {
          False, Ok(definition) -> {
            let #(operator, memo) =
              lift_local_function(
                name,
                definition,
                context,
                function_map,
                knowledge_base,
                visited,
                registry,
                module_types,
                cache,
                memo,
              )
            #(Ok(operator), memo)
          }
          _, _ -> #(Error(Nil), memo)
        }
      types.ReturnedOperator(callee, args) ->
        resolve_returned_operator(
          callee,
          args,
          context,
          function_map,
          knowledge_base,
          visited,
          registry,
          module_types,
          cache,
          memo,
        )
      _ -> #(Error(Nil), memo)
    }
  }
}

// Resolve the operator a producer returns. A qualified callee is looked up in
// the KB (computed at the producer's inference time, available downstream by
// topological order); a same-module callee (`""` module) is computed on-demand
// (cycle-guarded by `visited`). When the returned operator is *polymorphic* in
// the producer's parameters, `args` (the producer call's arguments) are bound to
// them — so a decorator `traced(real)` substitutes its `action` with `real`.
fn resolve_returned_operator(
  callee: types.QualifiedName,
  args: List(types.CallArgument),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(Result(EffectTerm, Nil), Memo) {
  let #(lookup, memo) = case callee.module {
    "" ->
      case
        set.contains(visited, callee.function),
        dict.get(function_map, callee.function)
      {
        False, Ok(definition) ->
          compute_returned_operator(
            definition.definition,
            context,
            function_map,
            knowledge_base,
            set.insert(visited, callee.function),
            registry,
            module_types,
            cache,
            memo,
          )
        _, _ -> #(Error(Nil), memo)
      }
    _ -> #(effects.lookup_returned_operator(knowledge_base, callee), memo)
  }
  case lookup {
    Error(Nil) -> #(Error(Nil), memo)
    // Concrete operator (no free vars): nothing to bind. Polymorphic in the
    // producer's params: bind them to the producer call's arguments.
    Ok(operator) ->
      case set.is_empty(effect_term.free_vars(operator)) {
        True -> #(Ok(operator), memo)
        False -> {
          let #(bound, memo) =
            bind_producer_params(
              operator,
              callee,
              args,
              context,
              function_map,
              knowledge_base,
              visited,
              registry,
              module_types,
              cache,
              memo,
            )
          #(Ok(bound), memo)
        }
      }
  }
}

// Bind a polymorphic returned operator's free producer-parameter variables to
// the producer call's arguments, reusing the call-site substitution machinery.
// The producer's parameter bounds + a registry that knows its operator params
// come from the KB/project registry (cross-module) or its glance signature
// (same-module, keyed by the `""` module so the synthetic callee name matches).
fn bind_producer_params(
  operator: EffectTerm,
  callee: types.QualifiedName,
  args: List(types.CallArgument),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(EffectTerm, Memo) {
  let #(bounds, effective_registry) = case callee.module {
    "" ->
      case dict.get(function_map, callee.function) {
        Ok(definition) -> {
          // Build a single-entry registry keyed by `""` so operator detection in
          // `bind_variables` lifts operator args (not first-order).
          let local_registry =
            signatures.from_glance_module(
              "",
              glance.Module(
                imports: [],
                custom_types: [],
                type_aliases: [],
                constants: [],
                functions: [definition],
              ),
            )
          let bounds =
            definition.definition
            |> ordered_fn_typed_param_names()
            |> list.map(self_referential_bound)
          #(bounds, signatures.merge(registry, local_registry))
        }
        Error(Nil) -> #([], registry)
      }
    _ -> #(effects.lookup_param_bounds(knowledge_base, callee), registry)
  }
  let lift =
    build_lift_operator_arg(
      context,
      function_map,
      knowledge_base,
      visited,
      registry,
      module_types,
      dict.new(),
      cache,
    )
  let #(bindings, memo) =
    bind_variables(
      callee,
      bounds,
      args,
      knowledge_base,
      [],
      effective_registry,
      lift,
      memo,
    )
  #(effect_term.normalize(effect_term.subst(operator, bindings)), memo)
}

// Compute the operator a function returns, for the returned-operator KB and for
// same-module on-demand resolution: classify its return expression and lift it
// with the callback positions of its declared return type. `Error` when the
// function doesn't return an operator-shaped value (no return-type annotation,
// non-function tail, or a tail that doesn't resolve to a function/operator).
//
// The producer's own operator parameters are seeded both as caller bounds (so a
// returned bare parameter, `fn wrap(base) { base }`, resolves to its variable)
// and as *ambient operators* (so a returned closure that calls a parameter,
// `fn traced(action) { fn(cb) { action(cb) } }`, builds `action(cb)`). The
// result may therefore be **polymorphic** in those parameters — they're bound to
// the producer call's arguments at `resolve_returned_operator`.
fn compute_returned_operator(
  function: Function,
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(Result(EffectTerm, Nil), Memo) {
  // Gate on the return type being *a function* (so there's something to record
  // when called), not specifically operator-shaped — a first-order returned
  // function (`fn make() -> fn() -> Nil`) carries a latent effect too. The
  // callback positions may be empty (a first-order return has no callbacks).
  let gated = {
    use return_type <- result.try(option.to_result(function.return, Nil))
    use <- bool.guard(
      when: !signatures.is_function_return_type(return_type),
      return: Error(Nil),
    )
    use value <- result.try(extract.return_value(function, context))
    Ok(#(return_type, value))
  }
  case gated {
    Error(Nil) -> #(Error(Nil), memo)
    Ok(#(return_type, value)) -> {
      let positions =
        signatures.operator_callback_positions_of_type(return_type)
      let producer_operators =
        signatures.operator_params_from_function(function)
      let producer_bounds =
        function
        |> ordered_fn_typed_param_names()
        |> list.map(self_referential_bound)
      let lift =
        build_lift_operator_arg(
          context,
          function_map,
          knowledge_base,
          visited,
          registry,
          module_types,
          producer_operators,
          cache,
        )
      let #(operator, memo) =
        operator_term_for_argument(
          types.CallArgument(position: 0, label: None, value:),
          positions,
          knowledge_base,
          producer_bounds,
          registry,
          lift,
          memo,
        )
      #(compute_returned_operator_result(operator), memo)
    }
  }
}

// Classify the lifted return value into the operator a producer records.
fn compute_returned_operator_result(
  operator: EffectTerm,
) -> Result(EffectTerm, Nil) {
  // Record the operator a producer returns:
  //   - an abstraction (`λcb. …`, possibly polymorphic in the producer's
  //     params), a bare operator parameter returned directly (`TVar`, the
  //     identity `fn wrap(base) { base }`), or a *union* of these (a producer
  //     that returns one of several operators through a branch). Their free
  //     vars are bound to the producer call's arguments by
  //     `resolve_returned_operator`, and a bound union distributes on application.
  //   - a ground *latent effect* (`TLabels`/`TTop`) — a first-order returned
  //     function, whose effect of *being called* is its body. Applying it (with
  //     no callback arguments) yields this effect directly. A pure-[Unknown]
  //     latent is dropped: it carries no information and resolution falls back
  //     to [Unknown] anyway.
  // A bare stuck application isn't usable.
  case operator {
    types.TAbs(_, _) | types.TVar(_) | types.TUnion(_) -> Ok(operator)
    types.TLabels(_) | types.TTop ->
      case operator == effect_term.unknown() {
        True -> Error(Nil)
        False -> Ok(operator)
      }
    types.TApp(_, _) -> Error(Nil)
  }
}

// Analyse an inline closure's body as if its parameters were fn-typed, then
// abstract over the parameters at the operator's callback `positions`, in
// order — turning `fn(cb) { cb(x) }` (position `[0]`) into the operator
// `λcb. [cb]`, and `fn(f, g) { f(); g() }` (positions `[0, 1]`) into
// `λf. λg. [f, g]`. This lets a closure passed to an operator parameter
// beta-reduce just like a named function reference. With no positions (operator
// info missing) it falls back to abstracting over the first parameter.
fn analyze_closure(
  params: List(String),
  body: List(Statement),
  positions: List(Int),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  ambient_operators: dict.Dict(String, List(Int)),
  cache: LocalCache,
  memo: Memo,
) -> #(EffectTerm, Memo) {
  // Memoize closure analysis. `use`-desugaring nests each continuation inside the
  // previous one, so a naive walk re-analyses the same closure once per path that
  // reaches it — exponential on a long `use` chain (a record decoder, say). A
  // closure is uniquely identified within a module by its body's source position,
  // and its result depends besides on the lifting `positions`, the in-scope
  // ambient operators, and which ancestors are visited; key by all four.
  let key = #(
    closure_body_start(body),
    positions,
    list.sort(dict.keys(ambient_operators), string.compare),
    list.sort(set.to_list(visited), string.compare),
  )
  case dict.get(memo.closures, key) {
    Ok(cached) -> #(cached, memo)
    Error(Nil) -> {
      let #(operator, memo) =
        analyze_closure_uncached(
          params,
          body,
          positions,
          context,
          function_map,
          knowledge_base,
          visited,
          registry,
          module_types,
          ambient_operators,
          cache,
          memo,
        )
      #(
        operator,
        Memo(..memo, closures: dict.insert(memo.closures, key, operator)),
      )
    }
  }
}

fn analyze_closure_uncached(
  params: List(String),
  body: List(Statement),
  positions: List(Int),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  ambient_operators: dict.Dict(String, List(Int)),
  cache: LocalCache,
  memo: Memo,
) -> #(EffectTerm, Memo) {
  let synthetic =
    Function(
      location: Span(0, 0),
      name: "<closure>",
      publicity: Private,
      parameters: [],
      return: None,
      body:,
    )
  // Seed every closure parameter — and every ambient operator parameter from an
  // enclosing producer — as a self-referential bound, so calls to them inside the
  // body resolve to their effect variable (the local-call branch matches on
  // `param_bounds`, and the ambient ones are also flagged as operators).
  let bounds =
    list.append(
      list.map(params, self_referential_bound),
      list.map(dict.keys(ambient_operators), self_referential_bound),
    )
  let #(body_pairs, memo) =
    collect_effects(
      synthetic,
      function_map,
      context,
      knowledge_base,
      visited,
      bounds,
      registry,
      module_types,
      ambient_operators,
      cache,
      memo,
    )
  let body_term = union_of(body_pairs)
  // Which closure parameters to abstract over: those at the operator's callback
  // positions (in order). Fall back to the first parameter when positions are
  // unknown, preserving the previous single-callback behaviour.
  let callback_params = case positions {
    [] ->
      case params {
        [first, ..] -> [first]
        [] -> []
      }
    _ ->
      list.filter_map(positions, fn(position) { extract.at(params, position) })
  }
  let operator =
    list.fold_right(callback_params, body_term, fn(acc, param) {
      types.TAbs(param, acc)
    })
  #(operator, memo)
}

// The source offset of a closure body's first statement — a stable per-module
// identity for the closure, used to memoize its analysis. An empty body (no
// statements, hence nothing distinguishing) keys on `-1`.
fn closure_body_start(body: List(Statement)) -> Int {
  case body {
    [statement, ..] -> statement_start(statement)
    [] -> -1
  }
}

fn statement_start(statement: Statement) -> Int {
  case statement {
    glance.Use(location:, ..) -> location.start
    glance.Assignment(location:, ..) -> location.start
    glance.Assert(location:, ..) -> location.start
    // Every `glance.Expression` variant carries a `location` field.
    glance.Expression(expression) -> expression.location.start
  }
}

// Lift a same-module named function passed as an operator argument into an
// effect operator. Sibling functions aren't in the knowledge base during their
// module's inference pass, so this transitively analyses the definition (its
// fn-typed params seeded as self-referential variables) and abstracts over
// those params in order — the `function_map` analogue of the `FunctionRef`/KB
// path in `operator_term_for_argument`.
fn lift_local_function(
  name: String,
  definition: Definition(Function),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(EffectTerm, Memo) {
  let function = definition.definition
  let fn_param_names = ordered_fn_typed_param_names(function)
  let scc = dict.get(cache.scc_id, name) |> result.unwrap(-1)
  case set.contains(cache.collapsible, scc) {
    // A first-order function in a collapsible SCC lifts to a ground term (no
    // binders): its operator is just its full-reachability effect, which is the
    // component's shared collapsed analysis — reuse it rather than re-walking.
    True -> {
      let #(pairs, memo) =
        collapsed_scc(
          scc,
          function_map,
          context,
          knowledge_base,
          registry,
          module_types,
          cache,
          memo,
        )
      #(union_of(pairs), memo)
    }
    // Otherwise memoize like `memoized_local`'s polymorphic path, but for the
    // operator-lifting of a function reference (an encoder passed to a codec
    // combinator, reached through deep reference chains). Keyed distinctly from
    // the local-call memo; the precise `visited ∩ SCC` ancestors when the lifted
    // function is itself effect-polymorphic.
    False -> {
      let #(_, ancestors) = memo_key(name, visited, cache)
      let key = #(name, ancestors)
      case dict.get(memo.lifts, key) {
        Ok(cached) -> #(cached, memo)
        Error(Nil) ->
          lift_operator_miss(
            name,
            function,
            fn_param_names,
            key,
            context,
            function_map,
            knowledge_base,
            visited,
            registry,
            module_types,
            cache,
            memo,
          )
      }
    }
  }
}

// Compute (and cache) the operator lift of a same-module function on a `lifts`
// memo miss: analyse its body with its fn-typed params seeded as self-referential
// variables, then abstract over those params in declaration order.
fn lift_operator_miss(
  name: String,
  function: Function,
  fn_param_names: List(String),
  key: #(String, List(String)),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(EffectTerm, Memo) {
  let bounds = list.map(fn_param_names, self_referential_bound)
  let #(body_pairs, memo) =
    collect_effects(
      without_returned_closure(function),
      function_map,
      context,
      knowledge_base,
      set.insert(visited, name),
      bounds,
      registry,
      module_types,
      dict.new(),
      cache,
      memo,
    )
  let body_term = union_of(body_pairs)
  let operator =
    list.fold_right(fn_param_names, body_term, fn(acc, param) {
      types.TAbs(param, acc)
    })
  #(operator, Memo(..memo, lifts: dict.insert(memo.lifts, key, operator)))
}

// In-body names of a function's fn-typed parameters, in declaration order.
fn ordered_fn_typed_param_names(function: Function) -> List(String) {
  list.filter_map(function.parameters, fn(param) {
    case param.type_, param.name {
      Some(glance.FunctionType(..)), glance.Named(name) -> Ok(name)
      _, _ -> Error(Nil)
    }
  })
}

// Find the argument that matches a given param bound. Prefers label
// match; falls back to positional match using the bound's index in
// the bound list (which mirrors the parameter order).
fn find_matching_arg(
  callee_name: types.QualifiedName,
  bound: ParamBound,
  args: List(types.CallArgument),
  registry: SignatureRegistry,
) -> option.Option(types.CallArgument) {
  // Try two strategies in order:
  //   1. Label match (caller used an explicit argument label)
  //   2. Registry-backed position (authoritative when available)
  // We deliberately do not fall back to the bound's index in the
  // bounds list — that's only correct when every parameter has a
  // bound, and silently picks the wrong argument when bounds are
  // sparse. If the registry has no entry, the variable stays
  // unresolved and surfaces as part of the result.
  let by_label = find_arg_by_label(args, bound.name)
  use <- option.lazy_or(by_label)
  position_from_registry(callee_name, bound.name, registry)
  |> option.then(fn(pos) { find_arg_at_position(args, pos) })
}

fn find_arg_by_label(
  args: List(types.CallArgument),
  label: String,
) -> option.Option(types.CallArgument) {
  list.find(args, fn(arg) { arg.label == Some(label) })
  |> option.from_result
}

fn find_arg_at_position(
  args: List(types.CallArgument),
  position: Int,
) -> option.Option(types.CallArgument) {
  list.find(args, fn(arg) { arg.position == position && arg.label == None })
  |> option.from_result
}

// Look up the real parameter position of a named parameter in the
// callee's signature. Returns `None` when the callee is not in the
// registry or the parameter name doesn't match any labeled parameter.
fn position_from_registry(
  callee_name: types.QualifiedName,
  param_name: String,
  registry: SignatureRegistry,
) -> option.Option(Int) {
  // Try in-body parameter name first (auto-inferred bounds key off
  // the name, not the Gleam argument label). Fall back to label
  // matching for JSON-sourced signatures where name info isn't
  // available.
  use params <- option.then(signatures.lookup(registry, callee_name))
  let by_name =
    find_param_position(params, fn(p) { p.name == Some(param_name) })
  use <- option.lazy_or(by_name)
  find_param_position(params, fn(p) { p.label == Some(param_name) })
}

fn find_param_position(
  params: List(signatures.ParameterInfo),
  predicate: fn(signatures.ParameterInfo) -> Bool,
) -> option.Option(Int) {
  list.find(params, predicate)
  |> result.map(fn(p) { p.position })
  |> option.from_result
}

// Look up the effects of an argument value. Function references →
// KB lookup; constructors → pure; local refs matching a caller param
// bound (user-declared or auto-detected fn-typed) → that bound's
// effects; otherwise [Unknown].
fn resolve_argument_effects(
  arg: types.CallArgument,
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
) -> EffectTerm {
  case arg.value {
    types.FunctionRef(name) -> effects.lookup_effects(knowledge_base, name)
    types.ConstructorRef -> effect_term.pure()
    types.LocalRef(name) ->
      case list.find(caller_param_bounds, fn(b) { b.name == name }) {
        Ok(bound) -> bound.effects
        Error(Nil) -> effect_term.unknown()
      }
    // A closure in a first-order position contributes nothing here — its body
    // is walked by the enclosing extractor. (Operator positions are handled by
    // `operator_term_for_argument`, which lifts the closure to an operator.)
    types.Closure(_, _) -> effect_term.unknown()
    // Branches and returned operators are only resolvable in an operator
    // position (handled by `operator_term_for_argument`); first-order, they're
    // conservative.
    types.Choice(_) -> effect_term.unknown()
    types.ReturnedOperator(_, _) -> effect_term.unknown()
    types.OtherExpression -> effect_term.unknown()
  }
}

fn resolve_unknown_local(
  local_call: LocalCall,
  visited: Set(String),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(List(#(ResolvedCall, EffectTerm)), Memo) {
  // Cycle detected — already analysing this function up the call stack. Return
  // empty rather than looping; the effects will be captured by the outer frame
  // that started the analysis.
  use <- bool.guard(when: set.contains(visited, local_call.function), return: #(
    [],
    memo,
  ))
  case dict.get(function_map, local_call.function) {
    Error(Nil) -> {
      let synthetic_call =
        types.ResolvedCall(
          name: QualifiedName(module: "<local>", function: local_call.function),
          span: local_call.span,
        )
      #([#(synthetic_call, effect_term.unknown())], memo)
    }
    Ok(local_definition) ->
      case is_opaque_external(local_definition) {
        // A same-module call into a bodyless `@external` resolves to the
        // conservative `[Unknown]`, not the `[]` its empty body would yield.
        True -> #(
          [
            #(
              types.ResolvedCall(
                name: QualifiedName(
                  module: "<local>",
                  function: local_call.function,
                ),
                span: local_call.span,
              ),
              effect_term.unknown(),
            ),
          ],
          memo,
        )
        // A genuine same-module body: memoize its transitive analysis,
        // keyed by callee + same-SCC ancestors (see `memo_key`). The cached
        // list holds in-body call spans, which are call-site-independent, so
        // it is reusable verbatim across every caller sharing the key.
        False ->
          memoized_local(
            local_call,
            local_definition,
            visited,
            function_map,
            context,
            knowledge_base,
            registry,
            module_types,
            cache,
            memo,
          )
      }
  }
}

// Resolve a same-module non-external call, memoized.
//
// A call into a **collapsible** SCC (every member first-order) returns that
// component's single full-reachability analysis — every member is mutually
// reachable, so they share one effect set, and a public entry's truncated union
// already equals that set, so collapsing changes nothing but cost. This is what
// keeps a dense first-order parser linear instead of exploding over the
// component's exponentially-many ancestor subsets.
//
// Any other callee is **effect-polymorphic** (its analysis carries free param
// variables bound per call site, so the result genuinely depends on which
// ancestors cycle-truncation cut): key by callee + same-SCC ancestors, which is
// exact, and analyse the body live on a miss.
fn memoized_local(
  local_call: LocalCall,
  local_definition: Definition(Function),
  visited: Set(String),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(List(#(ResolvedCall, EffectTerm)), Memo) {
  let scc = dict.get(cache.scc_id, local_call.function) |> result.unwrap(-1)
  case set.contains(cache.collapsible, scc) {
    True ->
      collapsed_scc(
        scc,
        function_map,
        context,
        knowledge_base,
        registry,
        module_types,
        cache,
        memo,
      )
    False -> {
      // Seed synthetic bounds for the callee's own fn-typed params so its body
      // can produce effect variables too (nested higher-order calls stay
      // polymorphic through the transitive analysis).
      let nested_bounds =
        synthetic_fn_typed_bounds(signatures.fn_typed_params_from_function(
          local_definition.definition,
        ))
      let key = memo_key(local_call.function, visited, cache)
      case dict.get(memo.locals, key) {
        Ok(cached) -> #(cached, memo)
        Error(Nil) -> {
          let new_visited = set.insert(visited, local_call.function)
          let #(result, memo) =
            collect_effects(
              without_returned_closure(local_definition.definition),
              function_map,
              context,
              knowledge_base,
              new_visited,
              nested_bounds,
              registry,
              module_types,
              dict.new(),
              cache,
              memo,
            )
          #(result, Memo(..memo, locals: dict.insert(memo.locals, key, result)))
        }
      }
    }
  }
}

// The full-reachability analysis of a collapsible SCC, computed once and shared
// by all its members. Each member is analysed with the *whole* component marked
// visited, so intra-SCC calls truncate immediately (every member's direct
// effects are gathered exactly once across the union, and lower SCCs resolve
// through the cache); the union over members is the component's reachable
// effect. Keyed by SCC id, so the members beyond the first are free.
fn collapsed_scc(
  scc: Int,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(List(#(ResolvedCall, EffectTerm)), Memo) {
  case dict.get(memo.sccs, scc) {
    Ok(cached) -> #(cached, memo)
    Error(Nil) -> {
      let members = dict.get(cache.members, scc) |> result.unwrap([])
      let scc_set = set.from_list(members)
      let #(result, memo) =
        list.fold(members, #([], memo), fn(state, name) {
          let #(acc, memo) = state
          collapsed_member(
            name,
            acc,
            scc_set,
            function_map,
            context,
            knowledge_base,
            registry,
            module_types,
            cache,
            memo,
          )
        })
      #(result, Memo(..memo, sccs: dict.insert(memo.sccs, scc, result)))
    }
  }
}

// Analyse one member of a collapsing SCC and append its effects to `acc`. The
// whole component is marked `visited` (`scc_set`), so intra-SCC calls truncate
// immediately and each member's direct effects are gathered exactly once.
fn collapsed_member(
  name: String,
  acc: List(#(ResolvedCall, EffectTerm)),
  scc_set: Set(String),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(List(#(ResolvedCall, EffectTerm)), Memo) {
  case dict.get(function_map, name) {
    Ok(definition) -> {
      let #(member_effects, memo) =
        collect_effects(
          without_returned_closure(definition.definition),
          function_map,
          context,
          knowledge_base,
          scc_set,
          [],
          registry,
          module_types,
          dict.new(),
          cache,
          memo,
        )
      #(list.append(acc, member_effects), memo)
    }
    Error(Nil) -> #(acc, memo)
  }
}

fn resolve_field_call(
  field_call: types.FieldCall,
  function: Function,
  knowledge_base: KnowledgeBase,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  call_args: dict.Dict(Int, List(types.CallArgument)),
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(EffectTerm, Memo) {
  // A hand-written field bound on the enclosing `check` line
  // (`check f(recv.field: [..])`) resolves the call directly, ahead of
  // girard/type-registry resolution. It's the boundary-scoped counterpart to a
  // `type` line — an escape hatch for a receiver graded can't trace to a
  // construction site. User-declared, so it wins over inferred field effects.
  let field_target = field_call.object <> "." <> field_call.label
  case list.find(caller_param_bounds, fn(b) { b.name == field_target }) {
    Ok(bound) -> #(effect_term.normalize(bound.effects), memo)
    Error(Nil) ->
      resolve_field_call_by_type(
        field_call,
        function,
        knowledge_base,
        module_types,
        call_args,
        caller_param_bounds,
        registry,
        lift_operator_arg,
        memo,
      )
  }
}

fn resolve_field_call_by_type(
  field_call: types.FieldCall,
  function: Function,
  knowledge_base: KnowledgeBase,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  call_args: dict.Dict(Int, List(types.CallArgument)),
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(EffectTerm, Memo) {
  // Resolve the receiver's nominal type, qualified by its defining module:
  // girard's inferred type for the receiver expression first (any receiver, and
  // girard reports the defining module), then the receiver's syntactic parameter
  // annotation (no module available, so keyed unqualified as "").
  let receiver_type =
    typeinfo.receiver_type(
      module_types,
      field_call.receiver_span.start,
      field_call.receiver_span.end,
    )
    |> option.lazy_or(fn() {
      syntactic_param_type(function, field_call.object)
      |> option.map(fn(type_name) { #("", type_name) })
    })
  case receiver_type {
    None -> #(effect_term.unknown(), memo)
    Some(#(module, type_name)) ->
      case
        effects.lookup_type_field(
          knowledge_base,
          module,
          type_name,
          field_call.label,
        )
      {
        Error(Nil) -> #(effect_term.unknown(), memo)
        Ok(field_effect) ->
          resolve_field_effect(
            field_effect,
            field_call,
            call_args,
            knowledge_base,
            caller_param_bounds,
            registry,
            lift_operator_arg,
            memo,
          )
      }
  }
}

// Resolve a type field's effect. When it carries effect variables and a
// polymorphic source (a function wired into the field), bind those variables to
// the field call's arguments — the same call-site substitution resolved calls
// use. Any variable left unbound collapses to `[Unknown]`.
fn resolve_field_effect(
  field_effect: types.TypeFieldEffect,
  field_call: types.FieldCall,
  call_args: dict.Dict(Int, List(types.CallArgument)),
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(EffectTerm, Memo) {
  // An *operator*-valued field — a single closure field lifted to `λp. …`, or a
  // *union* of such operators from several construction sites (`pure` wires
  // `λ_. []`, `do` wires `λin. [Unknown]`, …). Apply it to the field call's
  // arguments so the application β-reduces — the reducer distributes over a union
  // of operators, `(f ⊔ g)(x) → f(x) ⊔ g(x)` — instead of leaving the raw
  // operator bounds in the caller's ground effect set.
  use <- bool.guard(when: is_operator_valued(field_effect.effects), return: #(
    apply_field_operator(
      field_effect.effects,
      dict.get(call_args, field_call.span.start) |> result.unwrap([]),
      knowledge_base,
      caller_param_bounds,
    ),
    memo,
  ))
  case has_vars(field_effect.effects), field_effect.source {
    False, _ -> #(field_effect.effects, memo)
    True, None -> #(concretize(field_effect.effects), memo)
    True, Some(source) -> {
      let args = dict.get(call_args, field_call.span.start) |> result.unwrap([])
      let #(bindings, memo) =
        bind_variables(
          source,
          field_effect.bounds,
          args,
          knowledge_base,
          caller_param_bounds,
          registry,
          lift_operator_arg,
          memo,
        )
      #(concretize(effect_term.subst(field_effect.effects, bindings)), memo)
    }
  }
}

// Is this field effect operator-valued — an effect operator (`TAbs`) or a
// union of them? A field constructed at several sites (each wiring a closure)
// has a `TUnion` of operators; it must be *applied* to the field call's
// arguments, not returned raw. A non-operator effect (ground labels, or a
// polymorphic variable bound from a wired function) is handled by the
// `has_vars` path instead. A mixed union (an operator alongside a label set or
// free variable) still counts: applying it goes stuck in the reducer and
// collapses to the conservative `[Unknown]`, which is sound.
fn is_operator_valued(term: EffectTerm) -> Bool {
  case term {
    types.TAbs(_, _) -> True
    types.TUnion(members) -> list.any(members, is_operator_valued)
    _ -> False
  }
}

// Apply an operator-valued field to a field call's arguments, in position
// order: `λp0. λp1. body` applied to `(a0, a1)` β-reduces to `body[p0:=a0]
// [p1:=a1]`. A first-order field's binder is unused, so the result is just its
// body. Leftover binders (fewer args than params) leave the operator partially
// applied → `[Unknown]` (the conservative collapse in `to_effect_set`). Any
// variable still free after application is `concretize`d to `[Unknown]`, as in
// the non-operator branch — a field call has no caller to propagate vars to.
//
// A field built at several construction sites is a *union* of operators
// (possibly mixed with ground members — a site that wired an opaque value
// contributes a bare label set). Distribute the application over the union,
// `(L ⊔ f ⊔ g)(args) = L ⊔ f(args) ⊔ g(args)`: each operator member is applied
// to the arguments, each ground member passes through unchanged. (Wrapping the
// whole mixed union in a single `TApp` would instead go stuck in the reducer
// and surface as a malformed applied-union term.)
fn apply_field_operator(
  operator: EffectTerm,
  args: List(types.CallArgument),
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
) -> EffectTerm {
  let arg_terms =
    args
    |> list.sort(fn(a, b) { int.compare(a.position, b.position) })
    |> list.map(resolve_argument_effects(_, knowledge_base, caller_param_bounds))
  case operator {
    types.TUnion(members) ->
      members
      |> list.map(fn(member) {
        case is_operator_valued(member) {
          True -> apply_args(member, arg_terms)
          False -> member
        }
      })
      |> types.TUnion
      |> concretize
    _ -> concretize(apply_args(operator, arg_terms))
  }
}

// Apply an operator to argument effect terms in order, building the curried
// `TApp` spine the reducer β-reduces.
fn apply_args(operator: EffectTerm, arg_terms: List(EffectTerm)) -> EffectTerm {
  list.fold(arg_terms, operator, fn(acc, arg) { types.TApp(acc, arg) })
}

// Collapse any effect variables left after substitution to `Unknown`, so an
// unbound field effect never surfaces with free variables. (Unlike a regular
// call, a field whose variables can't be bound has no caller to propagate them
// to, so the conservative `[Unknown]` is the right answer.)
fn concretize(term: EffectTerm) -> EffectTerm {
  let bindings =
    term
    |> effect_term.free_vars()
    |> set.fold(dict.new(), fn(d, var) {
      dict.insert(d, var, effect_term.unknown())
    })
  effect_term.normalize(effect_term.subst(term, bindings))
}

// The nominal type name declared on the function parameter named `object`, if
// it carries a `NamedType` annotation. The syntax-level fallback for receivers
// girard could not type.
fn syntactic_param_type(
  function: Function,
  object: String,
) -> option.Option(String) {
  case
    list.find(function.parameters, fn(param) {
      case param.name {
        glance.Named(name) -> name == object
        glance.Discarded(_) -> False
      }
    })
  {
    Ok(glance.FunctionParameter(
      type_: Some(glance.NamedType(name: type_name, ..)),
      ..,
    )) -> Some(type_name)
    _ -> None
  }
}
