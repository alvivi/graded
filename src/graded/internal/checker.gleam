import glance.{type Definition, type Function, type Module}
import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded/internal/effects.{type KnowledgeBase}
import graded/internal/extract.{type ImportContext}
import graded/internal/signatures
import graded/internal/types.{
  type EffectAnnotation, type EffectSet, type LocalCall, type ParamBound,
  type ResolvedCall, type Violation, type Warning, EffectAnnotation, Effects,
  ParamBound, Polymorphic, QualifiedName, UntrackedEffectWarning, Violation,
}

/// Check a parsed module against its effect annotations.
pub fn check(
  module: Module,
  annotations: List(EffectAnnotation),
  knowledge_base: KnowledgeBase,
) -> #(List(Violation), List(Warning)) {
  let context = extract.build_import_context(module)
  let function_map = build_function_map(module)

  let results =
    list.map(annotations, fn(annotation) {
      check_annotation(annotation, function_map, context, knowledge_base)
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
    let fn_typed_params =
      signatures.fn_typed_params_from_function(definition.definition)
      |> set.filter(fn(name) { !set.contains(declared_bound_names, name) })
    let all_effects =
      collect_effects(
        definition.definition,
        function_map,
        context,
        knowledge_base,
        set.new(),
        param_bounds,
        fn_typed_params,
      )
    let effect_set =
      list.fold(all_effects, types.empty(), fn(combined, pair) {
        types.union(combined, pair.1)
      })
    // If the function's inferred effects reference effect variables
    // (because it calls fn-typed params), emit ParamBound entries so
    // the polymorphic annotation round-trips correctly.
    let inferred_params = polymorphic_param_bounds(effect_set, fn_typed_params)
    EffectAnnotation(
      kind: Effects,
      function: definition.definition.name,
      params: inferred_params,
      effects: effect_set,
    )
  })
}

/// Build ParamBound entries for each effect variable in `effect_set`
/// whose name is in `fn_typed_params`. The bound's effects are
/// `Polymorphic({}, {var_name})` — the variable refers to itself,
/// resolved later by substitution at call sites.
fn polymorphic_param_bounds(
  effect_set: EffectSet,
  fn_typed_params: Set(String),
) -> List(ParamBound) {
  case effect_set {
    Polymorphic(_, variables) ->
      variables
      |> set.to_list()
      |> list.filter(fn(v) { set.contains(fn_typed_params, v) })
      |> list.sort(string.compare)
      |> list.map(fn(v) {
        ParamBound(name: v, effects: Polymorphic(set.new(), set.from_list([v])))
      })
    _ -> []
  }
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
          set.new(),
        )
      // A call is a violation when its effect set is not a subset of the
      // declared budget — i.e. it performs effects the caller didn't allow.
      let violations =
        body_effects
        |> list.filter(fn(pair) {
          let #(_, call_effects) = pair
          !types.is_subset(call_effects, annotation.effects)
        })
        |> list.map(fn(pair) {
          let #(call, call_effects) = pair
          Violation(
            function: annotation.function,
            call: call.name,
            span: call.span,
            declared: annotation.effects,
            actual: call_effects,
          )
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
      effects.Known(effect_set) ->
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
      effects.Unknown -> Error(Nil)
    }
  })
}

// Collect all (call, effect_set) pairs reachable from a function body.
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
  fn_typed_params: Set(String),
) -> List(#(types.ResolvedCall, EffectSet)) {
  let result = extract.extract_calls(function.body, context)

  // Resolved calls: qualified names looked up directly in the knowledge base.
  let resolved_effects =
    list.map(result.resolved, fn(call) {
      #(call, effects.lookup_effects(knowledge_base, call.name))
    })

  // Local calls: check param bounds first (user-declared higher-order
  // constraints), then auto-detect fn-typed parameters and emit an
  // effect variable, then fall back to transitive analysis of local
  // definitions.
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
          [#(synthetic_call, bound.effects)]
        }
        Error(Nil) ->
          case set.contains(fn_typed_params, local_call.function) {
            True -> {
              let synthetic_call =
                types.ResolvedCall(
                  name: QualifiedName(
                    module: "<param>",
                    function: local_call.function,
                  ),
                  span: local_call.span,
                )
              [
                #(
                  synthetic_call,
                  Polymorphic(set.new(), set.from_list([local_call.function])),
                ),
              ]
            }
            False ->
              resolve_unknown_local(
                local_call,
                visited,
                function_map,
                context,
                knowledge_base,
              )
          }
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
      let effect_set = resolve_field_call(field_call, function, knowledge_base)
      #(synthetic_call, effect_set)
    })

  list.flatten([resolved_effects, local_effects, field_effects])
}

fn resolve_unknown_local(
  local_call: LocalCall,
  visited: Set(String),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
) -> List(#(ResolvedCall, EffectSet)) {
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
          [#(synthetic_call, types.from_labels(["Unknown"]))]
        }
        Ok(local_definition) -> {
          let new_visited = set.insert(visited, local_call.function)
          // Auto-detect fn-typed params for the local callee so its
          // body can produce effect variables too (nested higher-order
          // calls stay polymorphic through the transitive analysis).
          let nested_fn_typed =
            signatures.fn_typed_params_from_function(
              local_definition.definition,
            )
          collect_effects(
            local_definition.definition,
            function_map,
            context,
            knowledge_base,
            new_visited,
            [],
            nested_fn_typed,
          )
        }
      }
  }
}

fn resolve_field_call(
  field_call: types.FieldCall,
  function: Function,
  knowledge_base: KnowledgeBase,
) -> EffectSet {
  let unknown = types.from_labels(["Unknown"])
  let param =
    list.find(function.parameters, fn(param) {
      case param.name {
        glance.Named(name) -> name == field_call.object
        glance.Discarded(_) -> False
      }
    })
  case param {
    Ok(glance.FunctionParameter(
      type_: Some(glance.NamedType(name: type_name, ..)),
      ..,
    )) ->
      case
        effects.lookup_type_field(knowledge_base, type_name, field_call.label)
      {
        effects.Known(effect_set) -> effect_set
        effects.Unknown -> unknown
      }
    _ -> unknown
  }
}
