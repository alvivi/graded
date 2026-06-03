import girard/types as girard_types
import glance.{
  type Definition, type Function, type Module, type Statement, Function, Private,
  Span,
}
import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded/internal/effect_term
import graded/internal/effects.{type KnowledgeBase}
import graded/internal/extract.{type ImportContext}
import graded/internal/signatures.{type SignatureRegistry}
import graded/internal/typeinfo
import graded/internal/types.{
  type EffectAnnotation, type EffectTerm, type LocalCall, type ParamBound,
  type ResolvedCall, type Violation, type Warning, EffectAnnotation, Effects,
  ParamBound, QualifiedName, TUnion, TVar, UntrackedEffectWarning, Violation,
}

/// Check a parsed module against its effect annotations.
pub fn check(
  module: Module,
  annotations: List(EffectAnnotation),
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
) -> #(List(Violation), List(Warning)) {
  let context = extract.build_import_context(module)
  let function_map = build_function_map(module)

  let results =
    list.map(annotations, fn(annotation) {
      check_annotation(
        annotation,
        function_map,
        context,
        knowledge_base,
        registry,
        module_types,
      )
    })
  let violations = list.flat_map(results, fn(r) { r.0 })
  let warnings = list.flat_map(results, fn(r) { r.1 })
  #(violations, warnings)
}

/// Infer the effect set for every public function in a module.
/// Pass existing `check` annotations so their param bounds are used during inference.
pub fn infer(
  module: Module,
  knowledge_base: KnowledgeBase,
  existing_checks: List(EffectAnnotation),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
  girard_fn_typed: dict.Dict(String, Set(String)),
) -> List(EffectAnnotation) {
  let context = extract.build_import_context(module)
  let function_map = build_function_map(module)

  // Seed param bounds from existing `check` annotations only — `effects`
  // annotations don't carry user-declared bounds, so they can't constrain
  // higher-order parameters during inference.
  let bounds_map =
    existing_checks
    |> list.filter(fn(annotation) { annotation.params != [] })
    |> list.map(fn(annotation) { #(annotation.function, annotation.params) })
    |> dict.from_list()

  module.functions
  |> list.filter(fn(definition) {
    definition.definition.publicity == glance.Public
  })
  |> list.map(fn(definition) {
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
    let all_effects =
      collect_effects(
        definition.definition,
        function_map,
        context,
        knowledge_base,
        set.new(),
        effective_bounds,
        registry,
        module_types,
      )
    let effects_term = union_of(all_effects)
    // If the function's inferred effects reference effect variables
    // (because it calls fn-typed params), emit ParamBound entries so
    // the polymorphic annotation round-trips correctly.
    let inferred_params =
      polymorphic_param_bounds(effects_term, fn_typed_params)
    EffectAnnotation(
      kind: Effects,
      function: definition.definition.name,
      params: inferred_params,
      effects: effects_term,
    )
  })
}

/// The effect of the callback an operator parameter is applied to. The callback
/// isn't assumed to be first: `callback_position` is the operator parameter's
/// own callback argument index (from its type signature, see
/// `signatures.operator_params_from_function`), so `action(config, cb)` resolves
/// `cb` and not `config`. Pipe-adjusted call positions already align with the
/// operator's logical argument positions (the piped receiver takes position 0),
/// so the index applies directly. A missing argument is pure.
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
    Error(Nil) -> effect_term.pure()
  }
}

/// A bound whose effect is the single variable named after the param
/// itself — `TVar(name)`. The variable refers to itself, resolved later by
/// substitution at call sites. When the matching argument is an effect
/// *operator* (a `TAbs`), binding `name` to it and beta-reducing is exactly
/// what resolves a second-order call.
fn self_referential_bound(name: String) -> ParamBound {
  ParamBound(name, TVar(name))
}

/// True iff a term still carries unresolved (free) effect variables.
fn has_vars(term: EffectTerm) -> Bool {
  !set.is_empty(effect_term.free_vars(term))
}

/// Union the effect terms of a list of `(call, term)` pairs, normalizing once.
fn union_of(pairs: List(#(types.ResolvedCall, EffectTerm))) -> EffectTerm {
  effect_term.normalize(TUnion(list.map(pairs, fn(pair) { pair.1 })))
}

/// Synthesise a self-referential polymorphic bound for each auto-detected
/// fn-typed parameter. Seeding these into `param_bounds` lets the body
/// walker treat direct calls to, and forwarded uses of, the param
/// uniformly with user-declared bounds.
fn synthetic_fn_typed_bounds(fn_typed_params: Set(String)) -> List(ParamBound) {
  fn_typed_params
  |> set.to_list()
  |> list.map(self_referential_bound)
}

/// Build a `ParamBound` for each free effect variable in `term` whose name is
/// a fn-typed parameter. Each is self-referential (`TVar(name)`), resolved by
/// substitution at call sites — so the polymorphic signature round-trips.
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

fn build_function_map(module: Module) -> dict.Dict(String, Definition(Function)) {
  module.functions
  |> list.map(fn(definition) { #(definition.definition.name, definition) })
  |> dict.from_list()
}

fn check_annotation(
  annotation: EffectAnnotation,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
) -> #(List(Violation), List(Warning)) {
  case dict.get(function_map, annotation.function) {
    // Silently skip: the annotation may be stale or apply to a different
    // build target. Missing functions are not an error.
    Error(Nil) -> #([], [])
    Ok(function_definition) -> {
      let body_effects =
        collect_effects(
          function_definition.definition,
          function_map,
          context,
          knowledge_base,
          set.new(),
          annotation.params,
          registry,
          module_types,
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

      #(violations, warnings)
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
) -> List(#(types.ResolvedCall, EffectTerm)) {
  let result = extract.extract_calls(function.body, context)
  let operator_params = signatures.operator_params_from_function(function)
  // Lifts an inline-closure argument to an effect operator, in this function's
  // analysis context. Passed down to the substitution path so operator
  // parameters bound to a closure beta-reduce instead of going `[Unknown]`.
  let lift_closure = fn(value: types.ArgumentValue) -> Result(EffectTerm, Nil) {
    case value {
      types.Closure(params, body) ->
        Ok(analyze_closure(
          params,
          body,
          context,
          function_map,
          knowledge_base,
          visited,
          registry,
          module_types,
        ))
      _ -> Error(Nil)
    }
  }

  // Resolved calls: qualified names looked up directly in the knowledge
  // base. If the callee's effects are polymorphic (contain effect
  // variables), bind the variables by matching arguments at fn-typed
  // parameter positions and substitute for concrete effects.
  let resolved_effects =
    list.map(result.resolved, fn(call) {
      let effect_set = effects.lookup_effects(knowledge_base, call.name)
      let concrete =
        substitute_at_call_site(
          call,
          effect_set,
          result.call_args,
          knowledge_base,
          param_bounds,
          registry,
          lift_closure,
        )
      #(call, concrete)
    })

  // Local calls: check param bounds first (user-declared and auto-detected
  // fn-typed bounds both live here), then fall back to transitive analysis
  // of local definitions.
  let local_effects =
    list.flat_map(result.local, fn(local_call) {
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
          // type takes a function), the call is an effect-operator application
          // `op(callback)`: emit `TApp(op_var, callback_effect)` so it
          // beta-reduces once the operator is bound at a call site.
          let effect = case dict.get(operator_params, local_call.function) {
            Error(Nil) -> bound.effects
            Ok(callback_position) ->
              types.TApp(
                bound.effects,
                operator_argument_effect(
                  result.call_args,
                  local_call.span.start,
                  callback_position,
                  knowledge_base,
                  param_bounds,
                ),
              )
          }
          [#(synthetic_call, effect)]
        }
        Error(Nil) ->
          resolve_unknown_local(
            local_call,
            visited,
            function_map,
            context,
            knowledge_base,
            registry,
            module_types,
          )
          |> substitute_local_call_effects(
            local_call,
            result.call_args,
            function_map,
            knowledge_base,
            param_bounds,
            registry,
            lift_closure,
          )
      }
    })

  // Field calls: object.method(args) resolved via type field annotations.
  let field_effects =
    list.map(result.field, fn(field_call) {
      let synthetic_call =
        types.ResolvedCall(
          name: QualifiedName(
            module: "<field>",
            function: field_call.object <> "." <> field_call.label,
          ),
          span: field_call.span,
        )
      let effect_set =
        resolve_field_call(
          field_call,
          function,
          knowledge_base,
          module_types,
          result.call_args,
          param_bounds,
          registry,
          lift_closure,
        )
      #(synthetic_call, effect_set)
    })

  list.flatten([resolved_effects, local_effects, field_effects])
}

/// Substitute effect variables in the recursive analysis of a local
/// (same-module) call. The recursive `collect_effects` returns calls
/// from inside the callee whose effects may reference the callee's
/// own fn-typed parameters as variables; this resolves those
/// variables against the caller's arguments at this call site.
///
/// Without this step, a same-module higher-order helper would leak
/// `[<var>]` upward — only cross-module calls (which go through
/// `substitute_at_call_site`) would get bound.
fn substitute_local_call_effects(
  recursive: List(#(types.ResolvedCall, EffectTerm)),
  local_call: LocalCall,
  call_args: dict.Dict(Int, List(types.CallArgument)),
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_closure: fn(types.ArgumentValue) -> Result(EffectTerm, Nil),
) -> List(#(types.ResolvedCall, EffectTerm)) {
  let any_polymorphic = list.any(recursive, fn(p) { has_vars(p.1) })
  use <- bool.guard(when: !any_polymorphic, return: recursive)
  case dict.get(function_map, local_call.function) {
    Error(Nil) -> recursive
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
      let bindings =
        bind_variables(
          callee_name,
          bounds,
          args,
          knowledge_base,
          caller_param_bounds,
          merged_registry,
          lift_closure,
        )
      list.map(recursive, fn(pair) {
        let #(call, term) = pair
        #(call, effect_term.normalize(effect_term.subst(term, bindings)))
      })
    }
  }
}

/// Derive the polymorphic param bounds a local function would carry
/// after auto-inference: one bound per fn-typed parameter, with an
/// effect variable matching the parameter name.
fn local_polymorphic_bounds(function: Function) -> List(ParamBound) {
  synthetic_fn_typed_bounds(signatures.fn_typed_params_from_function(function))
}

/// Resolve effect variables at a call site. If the callee's effects
/// carry variables, match arguments to the callee's param bounds and
/// bind each variable to the concrete effect set of the corresponding
/// argument. `caller_param_bounds` lets us propagate effect bounds
/// from the caller's own parameters (when a fn-typed arg is itself
/// the caller's parameter).
fn substitute_at_call_site(
  call: types.ResolvedCall,
  effect: EffectTerm,
  call_args: dict.Dict(Int, List(types.CallArgument)),
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_closure: fn(types.ArgumentValue) -> Result(EffectTerm, Nil),
) -> EffectTerm {
  let callee_kb_bounds = effects.lookup_param_bounds(knowledge_base, call.name)
  // Fast path: concrete effect with declared bounds — nothing to
  // substitute. With no declared bounds we still need to fall through
  // in case the registry flags auto-injectable fn-typed params.
  use <- bool.guard(
    when: !has_vars(effect) && callee_kb_bounds != [],
    return: effect,
  )
  let args = dict.get(call_args, call.span.start) |> result.unwrap([])
  let #(effective_effects, effective_bounds) = case callee_kb_bounds {
    [_, ..] -> #(effect, callee_kb_bounds)
    [] -> auto_bounds_from_registry(call.name, effect, args, registry)
  }
  use <- bool.guard(
    when: !has_vars(effective_effects),
    return: effective_effects,
  )
  let bindings =
    bind_variables(
      call.name,
      effective_bounds,
      args,
      knowledge_base,
      caller_param_bounds,
      registry,
      lift_closure,
    )
  effect_term.normalize(effect_term.subst(effective_effects, bindings))
}

/// When the KB has no bounds but the registry reports fn-typed params,
/// synthesise polymorphic bounds so caller fn-typed args propagate through
/// the call. Covers stdlib higher-order functions whose catalog entries
/// mark the module pure but don't record callback param bounds.
///
/// Bounds are synthesised per fn-typed param, and only when the matching
/// argument is a tracked value (FunctionRef / LocalRef / ConstructorRef).
/// Inline-closure args are skipped: their bodies are walked separately by
/// the extractor, so binding them here would double-count — mixing tracked
/// refs and closures in the same call works correctly because each param
/// is decided independently.
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
            // Closures and other inline expressions are walked separately by
            // the extractor; binding them here would double-count.
            types.Closure(_, _) | types.OtherExpression -> Error(Nil)
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

/// Match arguments against a callee's param bounds and produce a
/// variable-to-effect-set binding map. For each param bound, find the
/// argument at its label (preferred) or position, and resolve the
/// argument's effects.
fn bind_variables(
  callee_name: types.QualifiedName,
  callee_bounds: List(ParamBound),
  args: List(types.CallArgument),
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_closure: fn(types.ArgumentValue) -> Result(EffectTerm, Nil),
) -> dict.Dict(String, EffectTerm) {
  let operator_params = signatures.operator_param_names(registry, callee_name)
  list.fold(callee_bounds, dict.new(), fn(acc, bound) {
    // Find the argument matching this parameter by label (caller used
    // an explicit label) or by real parameter position from the
    // registry. If neither matches, the variable stays unresolved.
    let matched = find_matching_arg(callee_name, bound, args, registry)
    case matched {
      Some(arg) -> {
        // For an *operator* parameter the argument is lifted to an effect
        // operator (a `TAbs`) so the callee's `op(callback)` application
        // beta-reduces. A first-order parameter just takes the argument's
        // flat effect.
        let arg_effects = case set.contains(operator_params, bound.name) {
          True ->
            operator_term_for_argument(
              arg,
              knowledge_base,
              caller_param_bounds,
              registry,
              lift_closure,
            )
          False ->
            resolve_argument_effects(arg, knowledge_base, caller_param_bounds)
        }
        // Bind the bound's free variable(s) to the argument's effect. For a
        // first-order bound `param: [e]` that's the variable `e`; for a self-
        // referential fn-typed bound it's the parameter name itself.
        let var_names =
          bound.effects |> effect_term.free_vars() |> set.to_list()
        list.fold(var_names, acc, fn(d, var) {
          dict.insert(d, var, arg_effects)
        })
      }
      None -> acc
    }
  })
}

/// Lift a call argument bound to an *operator* parameter into an effect
/// operator (`TAbs`) so the callee's `op(callback)` application beta-reduces.
/// A function reference `g` becomes `λcb. <g's effect>`, abstracting over `g`'s
/// callback parameter; an inline closure is analysed by `lift_closure` and
/// abstracted over its first parameter. Anything else falls back to its flat
/// effect (leaving the application stuck → `[Unknown]`).
fn operator_term_for_argument(
  arg: types.CallArgument,
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_closure: fn(types.ArgumentValue) -> Result(EffectTerm, Nil),
) -> EffectTerm {
  case arg.value {
    types.FunctionRef(name) -> {
      let body = effects.lookup_effects(knowledge_base, name)
      case signatures.fn_typed_param_names(registry, name) |> set.to_list() {
        [callback_var, ..] -> types.TAbs(callback_var, body)
        [] -> body
      }
    }
    types.Closure(_, _) ->
      case lift_closure(arg.value) {
        Ok(operator) -> operator
        Error(Nil) ->
          resolve_argument_effects(arg, knowledge_base, caller_param_bounds)
      }
    _ -> resolve_argument_effects(arg, knowledge_base, caller_param_bounds)
  }
}

/// Analyse an inline closure's body as if it were a function whose parameters
/// are fn-typed, then abstract over its first parameter — turning
/// `fn(cb) { cb(x) }` into the operator `λcb. [cb]`. This lets a closure passed
/// to an operator parameter beta-reduce just like a named function reference.
fn analyze_closure(
  params: List(String),
  body: List(Statement),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard_types.Type),
) -> EffectTerm {
  let synthetic =
    Function(
      location: Span(0, 0),
      name: "<closure>",
      publicity: Private,
      parameters: [],
      return: None,
      body:,
    )
  // Seed every closure parameter as a self-referential fn-typed bound so calls
  // to the callback inside the body resolve to its effect variable.
  let bounds = list.map(params, self_referential_bound)
  let body_term =
    collect_effects(
      synthetic,
      function_map,
      context,
      knowledge_base,
      visited,
      bounds,
      registry,
      module_types,
    )
    |> union_of()
  case params {
    [callback, ..] -> types.TAbs(callback, body_term)
    [] -> body_term
  }
}

/// Find the argument that matches a given param bound. Prefers label
/// match; falls back to positional match using the bound's index in
/// the bound list (which mirrors the parameter order).
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

/// Look up the real parameter position of a named parameter in the
/// callee's signature. Returns `None` when the callee is not in the
/// registry or the parameter name doesn't match any labeled parameter.
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

/// Look up the effects of an argument value. Function references →
/// KB lookup; constructors → pure; local refs matching a caller param
/// bound (user-declared or auto-detected fn-typed) → that bound's
/// effects; otherwise [Unknown].
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
) -> List(#(ResolvedCall, EffectTerm)) {
  case set.contains(visited, local_call.function) {
    // Cycle detected — already analysing this function up the call stack.
    // Return empty rather than looping; the effects will be captured by the
    // outer frame that started the analysis.
    True -> []
    False ->
      case dict.get(function_map, local_call.function) {
        Error(Nil) -> {
          let synthetic_call =
            types.ResolvedCall(
              name: QualifiedName(
                module: "<local>",
                function: local_call.function,
              ),
              span: local_call.span,
            )
          [#(synthetic_call, effect_term.unknown())]
        }
        Ok(local_definition) -> {
          let new_visited = set.insert(visited, local_call.function)
          // Seed synthetic bounds for the local callee's own fn-typed
          // params so its body can produce effect variables too (nested
          // higher-order calls stay polymorphic through the transitive
          // analysis).
          let nested_bounds =
            synthetic_fn_typed_bounds(signatures.fn_typed_params_from_function(
              local_definition.definition,
            ))
          collect_effects(
            local_definition.definition,
            function_map,
            context,
            knowledge_base,
            new_visited,
            nested_bounds,
            registry,
            module_types,
          )
        }
      }
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
  lift_closure: fn(types.ArgumentValue) -> Result(EffectTerm, Nil),
) -> EffectTerm {
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
    None -> effect_term.unknown()
    Some(#(module, type_name)) ->
      case
        effects.lookup_type_field(
          knowledge_base,
          module,
          type_name,
          field_call.label,
        )
      {
        Error(Nil) -> effect_term.unknown()
        Ok(field_effect) ->
          resolve_field_effect(
            field_effect,
            field_call,
            call_args,
            knowledge_base,
            caller_param_bounds,
            registry,
            lift_closure,
          )
      }
  }
}

/// Resolve a type field's effect. When it carries effect variables and a
/// polymorphic source (a function wired into the field), bind those variables to
/// the field call's arguments — the same call-site substitution resolved calls
/// use. Any variable left unbound collapses to `[Unknown]`.
fn resolve_field_effect(
  field_effect: types.TypeFieldEffect,
  field_call: types.FieldCall,
  call_args: dict.Dict(Int, List(types.CallArgument)),
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_closure: fn(types.ArgumentValue) -> Result(EffectTerm, Nil),
) -> EffectTerm {
  case has_vars(field_effect.effects), field_effect.source {
    False, _ -> field_effect.effects
    True, None -> concretize(field_effect.effects)
    True, Some(source) -> {
      let args = dict.get(call_args, field_call.span.start) |> result.unwrap([])
      let bindings =
        bind_variables(
          source,
          field_effect.bounds,
          args,
          knowledge_base,
          caller_param_bounds,
          registry,
          lift_closure,
        )
      concretize(effect_term.subst(field_effect.effects, bindings))
    }
  }
}

/// Collapse any effect variables left after substitution to `Unknown`, so an
/// unbound field effect never surfaces with free variables. (Unlike a regular
/// call, a field whose variables can't be bound has no caller to propagate them
/// to, so the conservative `[Unknown]` is the right answer.)
fn concretize(term: EffectTerm) -> EffectTerm {
  let bindings =
    term
    |> effect_term.free_vars()
    |> set.fold(dict.new(), fn(d, var) {
      dict.insert(d, var, effect_term.unknown())
    })
  effect_term.normalize(effect_term.subst(term, bindings))
}

/// The nominal type name declared on the function parameter named `object`, if
/// it carries a `NamedType` annotation. The syntax-level fallback for receivers
/// girard could not type.
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
