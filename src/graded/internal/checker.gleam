import girard
import glance.{
  type Definition, type Function, type Module, type Span, type Statement,
  Function, Private, Span,
}
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded/internal/annotation
import graded/internal/effect_term
import graded/internal/effects.{type KnowledgeBase}
import graded/internal/extract.{type ImportContext}
import graded/internal/signatures.{type SignatureRegistry}
import graded/internal/topo
import graded/internal/typeinfo
import graded/internal/types.{
  type CallExplanation, type CheckComponent, type CheckFinding,
  type ConstructionSite, type EffectAnnotation, type EffectTerm, type LocalCall,
  type LookupOrigin, type ParamBound, type QualifiedName, type ResolvedCall,
  type ReturnedOperatorReason, type UnknownReason, type UnprovedCause,
  type Violation, type Warning, AliasedBoundVariableWarning, CallExplanation,
  DotlessReturnsClauseWarning, EffectAnnotation, Effects, FieldArityViolation,
  FieldAssumeOrigin, FieldBoundList, FieldNotAnnotated, FieldReturnsClause,
  FieldSiteViolation, NoKnownEffects, NoReturnAnnotation,
  NonCallableFieldCheckWarning, NonCallableReturnViolation, ParamBound,
  QualifiedName, ReceiverTypeUnresolved, RefusedDeclaredReturn,
  ReturnIsNotAFunction, ReturnsClauseViolation, StaleFunctionAssumeWarning,
  StaleReturnsClauseWarning, TUnion, TVar, UnboundAssumeTermVariableWarning,
  UnbuiltExternal, UncalledFactory, UnclosedReturnsClauseWarning,
  UnconstructedFieldCheckWarning, UndeclaredExternal, UndeclaredForeignReturn,
  UnderivableReturnedOperator, UngroundReturnsClauseWarning,
  UnkeyedEffectsShapeWarning, UnknownClauseWarning, UnmatchedCheckWarning,
  UnmatchedFieldAssumeWarning, UnmatchedFieldBoundWarning,
  UnmatchedFieldCheckWarning, UnmatchedFunctionAssumeWarning,
  UnmatchedModuleAssumeWarning, UnmatchedParamBoundWarning,
  UnmatchedReturnsClauseWarning, UnprovedCheck, UnprovedForeignFallback,
  UnresolvedFieldValue, UnresolvedReturnTail, UnsupportedCheckComponent,
  UnsupportedFieldCheckWarning, UntraceableArgument, UntraceableProducer,
  UntraceableReceiver, UntracedFieldValue, UntrackedEffectWarning, Violation,
}

// Entry points
//
// The public analysis entries: check a module against its effect annotations,
// infer the public API's effects (plus returned operators and provenance), and
// lift a constructor-field closure for the construction-site index.

// Check a parsed module against its effect annotations.
pub fn check(
  module: Module,
  module_path: String,
  annotations: List(EffectAnnotation),
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  girard_fn_typed: dict.Dict(String, Set(String)),
  // The targets the package under analysis is compiled for. Decides which
  // `@external` declarations are ever built, and so which functions are foreign
  // code and which are ordinary Gleam whose body is the only implementation.
  package_targets: types.PackageTargets,
) -> #(List(Violation), List(CheckFinding), List(Warning)) {
  let function_map = build_function_map(module)
  let ModuleContext(context:, cache:) =
    module_context(
      module,
      module_path,
      knowledge_base,
      girard_fn_typed,
      package_targets,
    )

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
  let findings = list.flat_map(results, fn(r) { r.1 })
  let warnings = list.flat_map(results, fn(r) { r.2 })
  #(violations, findings, warnings)
}

// Infer the effect set for every public function in a module.
// Pass existing `check` annotations so their param bounds are used during inference.
pub fn infer(
  module: Module,
  module_path: String,
  knowledge_base: KnowledgeBase,
  existing_checks: List(EffectAnnotation),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  girard_fn_typed: dict.Dict(String, Set(String)),
  // The targets the package under analysis is compiled for. Decides which
  // `@external` declarations are ever built, and so which functions are foreign
  // code and which are ordinary Gleam whose body is the only implementation.
  package_targets: types.PackageTargets,
) -> List(EffectAnnotation) {
  infer_with_returns(
    module,
    module_path,
    knowledge_base,
    existing_checks,
    registry,
    module_types,
    girard_fn_typed,
    package_targets,
  ).0
}

// Like `infer`, but also returns each public function's *returned operator*
// (bare function name → the operator it returns) for functions that return a
// function — so the topological pass can thread them into the knowledge base
// for downstream `let h = producer(); with(h)` consumers.
pub fn infer_with_returns(
  module: Module,
  module_path: String,
  knowledge_base: KnowledgeBase,
  existing_checks: List(EffectAnnotation),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  girard_fn_typed: dict.Dict(String, Set(String)),
  // The targets the package under analysis is compiled for. Decides which
  // `@external` declarations are ever built, and so which functions are foreign
  // code and which are ordinary Gleam whose body is the only implementation.
  package_targets: types.PackageTargets,
) -> #(
  List(EffectAnnotation),
  dict.Dict(String, EffectTerm),
  dict.Dict(String, types.ReturnProvenance),
) {
  let function_map = build_function_map(module)
  let ModuleContext(context:, cache:) =
    module_context(
      module,
      module_path,
      knowledge_base,
      girard_fn_typed,
      package_targets,
    )

  let public_functions =
    list.filter(module.functions, fn(definition) {
      definition.definition.publicity == glance.Public
    })

  // The value channels describe what a function *returns*, which for an
  // `@external` only its foreign implementation decides — a summary lifted from
  // a fallback body would state something no caller can rely on, and there is no
  // declaration to union it with as the effects channel unions one. So foreign
  // names produce neither a returned operator nor provenance, and a consumer of
  // one resolves `[Unknown]`. This is the gate that stops such a line being
  // written into the spec at all.
  let value_channel_functions =
    list.filter(public_functions, fn(definition) {
      !foreign_definition(definition, package_targets)
    })

  // Returned operators of public functions that return a function — recorded so
  // downstream consumers resolve `let h = producer(); with(h)`. One memo table
  // is threaded through this pass and reused for the inference pass below.
  let #(memo, returned_pairs) =
    list.map_fold(value_channel_functions, new_memo(), fn(memo, definition) {
      // The operator a producer hands back is what its own body builds, so it
      // is computed on the targets that body runs on. Read package-wide, a
      // `@target(erlang)` producer returning a closure over a JavaScript-only
      // external published that unreachable declaration's effect in its
      // `returns` line -- and its `effects` line, narrowed, disagreed.
      let #(knowledge_base, memo) =
        body_walk(knowledge_base, memo, definition, package_targets)
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

  // Return-value provenance of public functions — recorded so a downstream
  // module's computed receiver resolves the callee's return path. Opaque
  // provenance is dropped: a lookup miss is treated as opaque anyway.
  let provenance =
    value_channel_functions
    |> list.filter_map(fn(definition) {
      case extract.return_provenance(definition.definition, context) {
        types.Opaque -> Error(Nil)
        traced -> Ok(#(definition.definition.name, traced))
      }
    })
    |> dict.from_list()

  // Seed param bounds from existing `check` annotations only — `effects`
  // annotations don't carry user-declared bounds, so they can't constrain
  // higher-order parameters during inference. Field bounds (dotted `param.field`
  // names) ride this same path: they resolve field calls during the seeded
  // inference exactly as plain bounds resolve parameter calls. Only callers that
  // pass real checks here are affected — the `graded infer` cache pass passes
  // `[]`, so a `check`-line bound never leaks into the written cache; path-dep
  // inference passes its spec checks, so a dep's bounds do constrain it.
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
      // Auto-detected fn-typed parameters, so calls to them produce effect
      // variables instead of [Unknown]. The same bounds every other walk of a
      // body uses.
      let fn_typed_params =
        unbound_fn_typed_params(definition, param_bounds, cache)
      let effective_bounds = effective_bounds(param_bounds, fn_typed_params)
      // A bodyless `@external` is opaque FFI — conservatively `[Unknown]`, not
      // the `[]` its empty body would otherwise infer.
      let #(effects_term, memo) = case
        foreign_definition(definition, package_targets)
      {
        True -> #(effect_term.unknown(), memo)
        False -> {
          let #(knowledge_base, memo) =
            body_walk(knowledge_base, memo, definition, package_targets)
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
              [],
              memo,
            )
          #(union_of(pairs), memo)
        }
      }
      let #(effects_term, field_vars) =
        groom_published_term(effects_term, fn_typed_params)
      // The operator this function returns, written as the line's `where
      // returns` clause. The line's own bound list scopes the clause's
      // variables, so they are counted alongside the term's below.
      let returns =
        dict.get(returned_operators, definition.definition.name)
        |> option.from_result()
      // If the function's inferred effects or its returned operator reference
      // effect variables (because it calls fn-typed params, or a fn-typed field
      // on an opaque receiver), emit ParamBound entries so the polymorphic
      // signature round-trips correctly. A callback used only inside the
      // returned closure is mentioned by the clause alone, and gets its bound
      // from there.
      let published_vars =
        set.union(
          effect_term.free_vars(effects_term),
          annotation.clause_free_vars(returns),
        )
      let inferred_params =
        list.append(
          bounds_for_vars(published_vars, fn_typed_params),
          polymorphic_param_bounds(effects_term, field_vars),
        )
      #(
        memo,
        EffectAnnotation(
          kind: Effects,
          function: definition.definition.name,
          params: inferred_params,
          effects: effects_term,
          returns:,
        ),
      )
    })
  #(annotations, returned_operators, provenance)
}

// Explain one function: every effect contributor `check` would subset-check,
// whether or not it fits a budget. One entry per set of bounds — the parameter
// and field bounds of one `check` line, or a single empty set for a function
// with no line — since the bounds decide what the analysis substitutes, and two
// lines can therefore explain one body differently.
//
// Each block carries the bounds the walk actually ran under — the declared ones
// plus the identity bound synthesised for every other function-typed parameter —
// so a renderer stating the block's total states it over the same bounds, and a
// term that is exactly a parameter's variable reads as the forwarding it is.
//
// `Error(Nil)` when the module defines no function by that name. Publicity is
// not consulted: the walk is over a body this module holds, so a private
// function explains exactly as a public one does.
//
// Contributors are the calls `collect_effects` reaches, not the call sites of
// the body — a resolved same-module call is replaced by the callee's own sites,
// so a helper's calls surface with spans inside the helper, as violations
// already report them.
pub fn explain(
  module: Module,
  module_path: String,
  function_name: String,
  bounds: List(List(ParamBound)),
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  girard_fn_typed: dict.Dict(String, Set(String)),
  // The targets the package under analysis is compiled for. Decides which
  // `@external` declarations are ever built, and so which functions are foreign
  // code and which are ordinary Gleam whose body is the only implementation.
  package_targets: types.PackageTargets,
) -> Result(List(ExplainedBlock), Nil) {
  // The lookup comes before the rest of the module analysis, so a name this
  // module does not define costs one map build rather than a whole-module walk.
  let function_map = build_function_map(module)
  use definition <- result.map(dict.get(function_map, function_name))
  case
    standalone_declaration(
      declaration_explanation(
        module_path,
        knowledge_base,
        definition,
        package_targets,
      ),
      definition,
      package_targets,
    )
  {
    // A declaration that stands in for the whole function binds no bounds and
    // needs no walking apparatus: answered here, ahead of the call graph and the
    // SCC pass `module_context` builds, and repeated per block unchanged.
    Some(explanation) ->
      list.map(bounds, fn(bounds) {
        ExplainedBlock(
          bounds:,
          total: effect_term.from_effect_set(explanation.actual),
          explanations: [explanation],
        )
      })
    None -> {
      let ModuleContext(context:, cache:) =
        module_context(
          module,
          module_path,
          knowledge_base,
          girard_fn_typed,
          package_targets,
        )
      // One memo across every bound set, as `check` threads one across every
      // annotation: a callee's own analysis is seeded from its signature, so the
      // caller's bounds neither key it nor reach it.
      let #(_memo, explained) =
        list.map_fold(bounds, new_memo(), fn(memo, bounds) {
          let fn_typed_params =
            unbound_fn_typed_params(definition, bounds, cache)
          let #(contribution, memo) =
            contributors(
              definition,
              bounds,
              fn_typed_params,
              function_map,
              context,
              knowledge_base,
              registry,
              module_types,
              cache,
              memo,
            )
          // The same grooming inference gives a function's term before the
          // spec states it, so the block's total is the term `graded effect`
          // answers with, not the ground projection the per-call lines print.
          //
          // Against the same names the contributors were groomed against —
          // declared bounds included, not the synthesised ones alone. A
          // variable a `check` line's own bound names is one this function can
          // bind, so grounding it in the total alone would head a block stating
          // `[cb]` per call with an `[Unknown]` the projection is not a
          // subset of, inverting the relationship between the two.
          let #(total, field_vars) =
            groom_published_term(
              contribution.total,
              effects.bound_name_set(contribution.effective_bounds),
            )
          // A field-effect variable surviving in the total gets the identity
          // bound inference writes beside it, exactly as the fn-typed params
          // already carry theirs in the effective bounds: a renderer stating
          // the total over these bounds then reads a bare `r.run` as
          // forwarding that field's effects — the sentence `graded effect`
          // answers with — instead of as an effect named after the path.
          #(
            memo,
            ExplainedBlock(
              bounds: list.append(
                contribution.effective_bounds,
                polymorphic_param_bounds(total, field_vars),
              ),
              total:,
              explanations: contribution.explanations,
            ),
          )
        })
      explained
    }
  }
}

// One `check` line's worth of `explain` output: the bounds the walk actually
// substituted (declared plus synthesised), the function's total effect as a
// term, and its contributors.
pub type ExplainedBlock {
  ExplainedBlock(
    bounds: List(ParamBound),
    total: EffectTerm,
    explanations: List(CallExplanation),
  )
}

// Every effect contributor of one function under one set of bounds, ordered and
// deduplicated: `check` subset-checks these and `why` prints them, so the two
// can't disagree about what a function does or report it a different number of
// times.
//
// Foreign code is answered by what declares it rather than by a body: an
// `@external` has none graded may weigh. Whether the foreign code matches its
// declaration is the FFI author's to establish; what graded weighs is the budget
// against the declaration.
//
// A body graded *can* read is always weighed, and where a declaration answers
// for it too, weighed *as well* — the budget then covers both what the
// declaration states and what the body does. Two ways that happens: a Gleam
// fallback an `@external` reaches on a target it declares no implementation for,
// and ordinary Gleam under a module-level `assume <module>` line. The
// line still answers for every caller; here it answers beside the body rather
// than instead of it, so a body over its own budget cannot pass by being
// declared.
fn contributors(
  definition: Definition(Function),
  bounds: List(ParamBound),
  fn_typed_params: Set(String),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(Contribution, Memo) {
  let declaration =
    declaration_explanation(
      context.module_path,
      knowledge_base,
      definition,
      context.package_targets,
    )
  let #(walked, body_term, effective, body, memo) = case
    standalone_declaration(declaration, definition, context.package_targets)
  {
    // An `@external` reaching here covers every target it is compiled for, so
    // the Gleam body beside it — if it has one at all — is text nothing runs,
    // and neither its effects nor the references it passes are reported.
    Some(_declaration) -> #(
      [],
      effect_term.pure(),
      bounds,
      BodyIsDeadText,
      memo,
    )
    None -> {
      let effective = effective_bounds(bounds, fn_typed_params)
      // Where this body is an `@external`'s running fallback, it is walked on
      // the targets it runs on — the same narrowing the summary walk performs.
      // Reading the names it calls package-wide here would charge this
      // function's own `check` line effects its callers, charged through that
      // summary, are not: one name, two totals.
      let #(knowledge_base, memo) =
        body_walk(knowledge_base, memo, definition, context.package_targets)
      let #(body_effects, memo) =
        collect_effects(
          without_returned_closure(definition.definition),
          function_map,
          context,
          knowledge_base,
          set.new(),
          effective,
          registry,
          module_types,
          dict.new(),
          cache,
          [],
          memo,
        )
      // Each printed effect is groomed against the variables this function's
      // bounds can actually bind: any other free variable — a nested closure's
      // binder an unresolved application left behind in a knowledge-base term —
      // is a phantom, and a contributor keeping it would print the internal
      // name beside a header that grounds the same variable to `[Unknown]`.
      let permitted = effects.bound_name_set(effective)
      #(
        list.map(body_effects, call_explanation(_, permitted)),
        union_of(body_effects),
        effective,
        BodyWalked,
        memo,
      )
    }
  }
  let declared = case declaration {
    Some(explanation) -> [explanation]
    None -> []
  }
  // The total as a *term*, beside the per-call explanations: each explanation
  // grounds its own effect for printing, which concretizes a still-symbolic
  // operator application to `[Unknown]` — the term keeps it, so a renderer
  // stating the function's total states the same polymorphic effect the
  // inferred spec line holds.
  let declared_term = case declaration {
    Some(explanation) -> effect_term.from_effect_set(explanation.actual)
    None -> effect_term.pure()
  }
  let total = effect_term.normalize(types.TUnion([declared_term, body_term]))
  #(
    Contribution(
      explanations: ordered_explanations(list.append(declared, walked)),
      effective_bounds: effective,
      total:,
      body:,
    ),
    memo,
  )
}

// What one walk under one set of bounds established: the ordered contributors,
// the bounds the walk actually substituted, the total as a term, and what
// became of the function's Gleam body.
type Contribution {
  Contribution(
    explanations: List(CallExplanation),
    effective_bounds: List(ParamBound),
    total: EffectTerm,
    body: BodyStanding,
  )
}

// What the walk did with a function's Gleam body: weighed it, or left it
// unweighed because nothing runs it.
type BodyStanding {
  // Walked: its contributors are among the explanations.
  BodyWalked
  // An `@external` covering every target it is compiled for. The Gleam body is
  // there, and nothing ever runs it.
  BodyIsDeadText
}

// What stands in for a body graded does not weigh: the declaration that answers
// for foreign code, when this function is foreign code.
//
// An `@external` attribute makes a function foreign whatever the knowledge base
// holds — an undeclared one is `[Unknown]`, not the `[]` a stale `effects` line
// claims. A function without one is foreign only where a declaration covers it,
// which for a project module is the module-level `assume <module>`
// line: the per-function form naming a Gleam-bodied function of this package
// declares nothing and never reaches the base.
fn declaration_explanation(
  module_path: String,
  knowledge_base: KnowledgeBase,
  definition: Definition(Function),
  package_targets: types.PackageTargets,
) -> option.Option(CallExplanation) {
  let qualified =
    QualifiedName(module: module_path, function: definition.definition.name)
  let declared = declaration_resolution(knowledge_base, qualified)
  use <- bool.guard(
    when: !foreign_definition(definition, package_targets)
      && option.is_none(declared),
    return: None,
  )
  // Keyed by the external's own qualified name and spanning its declaration. Read
  // through the charge a same-module call into it is resolved through, so the two
  // can't disagree about what the external does — including the `[Unknown]` an
  // `@external` nothing declares carries, and the `[Unknown]` one declared for a
  // target this build never compiles collapses to.
  let ForeignCharge(resolution:, standing:) =
    foreign_charge(knowledge_base, qualified)
  use resolution <- option.then(case standing {
    // The declaration's own term, not the charge's: a Gleam fallback body in
    // reach beside it is walked, and reaches this line as the contributors
    // beside it rather than unioned into it.
    effects.DeclarationCharged ->
      Some(option.unwrap(declared, undeclared_resolution()))
    // Nothing this build compiles implements the name, so the line states what
    // every caller of it is charged and says why.
    effects.NothingImplementsName -> Some(resolution)
    // The Gleam body running in the declaration's place is walked beside this
    // line and its contributors state the whole charge. A line for the
    // declaration as well would weigh against this function's own budget effects
    // no caller of it pays.
    effects.FallbackAnswersInstead -> None
  })
  // Which of the two the line is: foreign code the declaration answers for, or
  // ordinary Gleam whose callers it answers for. Only the wording differs — the
  // effects, the source and the total are the same either way.
  let kind = case foreign_definition(definition, package_targets) {
    True -> ExternalDeclaration(types.dotted_name(qualified))
    False -> CallerDeclaration(types.dotted_name(qualified))
  }
  Some(CallExplanation(
    call: sentinel_name(kind),
    span: definition.definition.location,
    actual: effect_term.to_effect_set(resolution.term),
    reason: resolution.reason,
    origin: resolution.origin,
    // The declaration's own line reports the declaration; the fallback body's
    // effects reach it as the walked contributors beside it. Nothing is
    // suppressed on this line either way — the body is still weighed here, so
    // suppressed wording would contradict the body-inclusive total beside it.
    fallback: types.NoFallback,
  ))
}

// Whether a declaration answers for the whole function, so nothing of the body
// is walked. One rule, read by `explain`'s fast path and by the walk itself, so
// the two can't disagree about which functions have a body worth weighing.
//
// Only foreign code with no Gleam of its own that runs. Two ways a declaration
// falls short of the whole function, and a body is walked *as well as* declared:
//
// - An `@external` whose Gleam fallback runs on some target it is compiled for.
// - Ordinary Gleam a module-level `assume <module>` line covers. The
//   line answers for every *caller* of the function; the body is visible Gleam
//   that runs, and a `check` line on that function is a budget for what the
//   function does. No line an author writes over their own package's source
//   silences a body graded can read — the per-function form naming one is
//   rejected as declaring nothing, and this is the module-level form's half of
//   that rule.
fn standalone_declaration(
  declaration: option.Option(CallExplanation),
  definition: Definition(Function),
  package_targets: types.PackageTargets,
) -> option.Option(CallExplanation) {
  use <- bool.guard(
    when: has_weighable_body(definition, package_targets),
    return: None,
  )
  declaration
}

// Whether this function has Gleam that graded can weigh — the question that
// decides whether a declaration answers alone, stated once so no caller has to
// assemble it from the predicates underneath.
//
// Ordinary Gleam always does: its body is the implementation, whatever else
// declares it. Foreign code does only where its Gleam fallback runs, on a target
// the build compiles and its declaration leaves uncovered — the reading the
// knowledge base charges callers by, so the function's own budget covers what
// every caller pays and nothing more.
fn has_weighable_body(
  definition: Definition(Function),
  package_targets: types.PackageTargets,
) -> Bool {
  !foreign_definition(definition, package_targets)
  || runs_fallback_body(definition, package_targets)
}

// What the knowledge base says about foreign code: the declaration that answers
// for it, or the conservative `[Unknown]` an external nothing declares carries.
//
// Only a declaration answers, and which entry won says so — its effect value
// does not. Anything else the base holds describes a body the foreign
// implementation needn't match, so it leaves the effects unresolved however
// concrete it looks. One rule for the external's own `check`/`why` line and for
// every call into it, so the two can never charge one name differently.
fn foreign_resolution(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Resolution {
  foreign_charge(knowledge_base, name).resolution
}

// The same, with the standing the charge was assembled under: what a channel
// reads when it carries a term of its own — a wired field's, or the external's
// own line — and needs to know which halves that term was made of.
type ForeignCharge {
  ForeignCharge(resolution: Resolution, standing: effects.DeclarationStanding)
}

// One derivation behind every channel that answers "what does this name charge,
// and from where": a call site, the external's own `check`/`why` line, a local
// call into a declared sibling, and a value wired into a record field. Each
// takes what it needs from the one value, so no two of them can charge one name
// differently or name a different cause for the same charge.
fn foreign_charge(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> ForeignCharge {
  let declared =
    option.unwrap(
      declaration_resolution(knowledge_base, name),
      undeclared_resolution(),
    )
  // What a *caller* pays, in the halves it is made of: the declaration where the
  // walk's targets reach it, and the Gleam fallback body beside it where they
  // reach that — that body is ordinary code, and composition is union. The
  // external's own `check` line covers both halves by walking the body beside
  // the declaration; this is how every other caller comes to the same total.
  let charge = effects.declared_charge(knowledge_base, name)
  let declared = standing_provenance(declared, charge.declaration)
  ForeignCharge(
    resolution: Resolution(
      ..declared,
      term: charge.term,
      fallback: charge.fallback,
    ),
    standing: charge.declaration,
  )
}

// What a declaration's standing leaves of the provenance a reader would quote
// beside the charge.
//
// Out of reach, neither the declaration's source nor the `[Unknown]` an
// undeclared external carries describes any part of what is charged: the
// fallback contribution beside the term carries the story where a body runs, and
// the unbuilt-declaration reason carries it where none does. Applied wherever a
// channel states a cause, so one name reads the same on all of them.
fn standing_provenance(
  resolution: Resolution,
  standing: effects.DeclarationStanding,
) -> Resolution {
  case standing {
    effects.DeclarationCharged -> resolution
    effects.FallbackAnswersInstead ->
      Resolution(..resolution, reason: None, origin: None)
    effects.NothingImplementsName ->
      Resolution(..resolution, reason: Some(UnbuiltExternal), origin: None)
  }
}

// What foreign code nothing declares carries: the conservative `[Unknown]`, and
// the reason that says why it stayed unresolved.
fn undeclared_resolution() -> Resolution {
  Resolution(
    term: effect_term.unknown(),
    reason: Some(UndeclaredExternal),
    origin: None,
    fallback: types.NoFallback,
  )
}

// The declaration that answers for `name`, when the winning entry is one. Also
// asked of names that are *not* foreign code — a module-level external can
// cover an ordinary Gleam function — so it weighs the winning entry's origin
// directly rather than going through the boundary, which only applies the rule
// to names already known to be foreign.
fn declaration_resolution(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> option.Option(Resolution) {
  case effects.lookup(knowledge_base, name) {
    effects.Known(term, source) -> {
      let origin = effects.origin_of(source)
      case effects.declares_foreign_code(origin) {
        True ->
          Some(Resolution(
            term:,
            reason: None,
            origin: Some(origin),
            fallback: types.NoFallback,
          ))
        False -> None
      }
    }
    effects.Unknown -> None
  }
}

// Whether `name` is foreign code that nothing declares — an `@external` whose
// effects therefore stay `[Unknown]`, however concrete an inferred entry left
// behind for it reads. Asked by `graded effect`, so a lookup answers what
// `check` and `why` say about the same name.
//
// Publicity is not weighed here. Whether the rule applies is a fact about the
// implementation being foreign; whether the query may answer at all is a
// separate question its caller settles first, for every project function alike.
pub fn undeclared_external(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Bool {
  {
    effects.is_foreign_function(knowledge_base, name)
    || effects.is_dependency_foreign_function(knowledge_base, name)
  }
  && option.is_none(declaration_resolution(knowledge_base, name))
}

// A body's contributors, ordered and deduplicated for reporting.
fn ordered_explanations(
  explanations: List(CallExplanation),
) -> List(CallExplanation) {
  explanations
  // Calling one helper twice repeats its body's sites verbatim. Only a wholly
  // identical entry is a repetition: two calls can substitute the same span to
  // different effects, and both of those are contributions.
  |> dedupe_explanations
  // By the whole span: nested calls can share a start offset, and ordering on
  // the start alone would leave them at the mercy of the category order the
  // collection concatenates in. Sorting after the deduplication keeps entries
  // that share a span in the order they were collected, the sort being stable.
  |> list.sort(fn(a, b) {
    order.break_tie(
      int.compare(a.span.start, b.span.start),
      int.compare(a.span.end, b.span.end),
    )
  })
}

// Drop repeated entries, keeping the first of each. Through a set rather than
// `list.unique`, whose pairwise scan is quadratic in a contributor count that
// grows with every call a helper's body makes.
fn dedupe_explanations(
  explanations: List(CallExplanation),
) -> List(CallExplanation) {
  let #(_seen, kept) =
    list.fold(explanations, #(set.new(), []), fn(acc, explanation) {
      let #(seen, kept) = acc
      case set.contains(seen, explanation) {
        True -> acc
        False -> #(set.insert(seen, explanation), [explanation, ..kept])
      }
    })
  list.reverse(kept)
}

// What one collected call contributes, in ground form. `check_annotation`
// subset-checks this projection and `explain` prints it, so the two can't
// disagree about what a call did.
//
// A field-effect variable that reached here undischarged (no `check`-line field
// bound bound it) concretizes to `[Unknown]`, so a `fn`-typed field call on an
// opaque receiver is never silently `[]`.
fn call_explanation(
  collected: CollectedCall,
  permitted: Set(String),
) -> CallExplanation {
  // Besides the field-variable concretization, every variable outside
  // `permitted` — the caller's own bound names — grounds to `[Unknown]`: such
  // a variable can never be bound here, so printing it would leak an internal
  // binder as an effect named after it.
  let ground = fn(term) {
    effect_term.to_effect_set(collapse_phantom_vars(
      concretize_field_vars(term),
      permitted,
    ))
  }
  CallExplanation(
    call: collected.call.name,
    span: collected.call.span,
    actual: ground(collected_term(collected)),
    reason: collected.resolution.reason,
    origin: collected.resolution.origin,
    fallback: types.map_fallback(collected.resolution.fallback, ground),
  )
}

// What each of the module's running Gleam fallback bodies does, keyed by
// function name.
//
// An `@external` that declares no implementation for some target it is compiled
// for falls back to its Gleam body on that target. That body is ordinary code
// that runs, so its effects are charged to every caller on top of whatever
// declares the external — the declaration speaks for the targets it covers, and
// says nothing about the rest.
//
// Walked here rather than left to each caller because a caller a module away
// holds no body to walk. Empty, and free, for a module with no such external:
// the walking apparatus is built only when there is one.
pub fn fallback_effects(
  module: Module,
  module_path: String,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  girard_fn_typed: dict.Dict(String, Set(String)),
  // The targets the package under analysis is compiled for. Decides which
  // `@external` declarations are ever built, and so which functions are foreign
  // code and which are ordinary Gleam whose body is the only implementation.
  package_targets: types.PackageTargets,
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  walk_fallbacks(
    list.filter(module.functions, fn(definition) {
      foreign_definition(definition, package_targets)
      && runs_fallback_body(definition, package_targets)
    }),
    module,
    module_path,
    knowledge_base,
    registry,
    module_types,
    girard_fn_typed,
    package_targets,
  )
}

// The same, for a module of a *dependency*, walked on the consumer's targets.
//
// One selector apart, and the difference is the whole point of a second entry
// point: `foreign_definition` asks whether the build compiles the declaration,
// and an `@external(javascript, …)` read by an Erlang-only consumer fails it.
// In this package's source that answer is right — nothing foreign is compiled,
// so the function is ordinary Gleam and the ordinary walk covers its body. A
// dependency's is not walked as ordinary Gleam by anything, so the question here
// is only whether a body runs at all: `has_running_fallback`, the same reading
// `dependency_foreign_functions` records the name under.
//
// girard types no consumer holds for a dependency, so the walk takes the
// syntax-level result — what a module girard cannot type already falls back to.
pub fn dependency_fallback_effects(
  module: Module,
  module_path: String,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  package_targets: types.PackageTargets,
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  walk_fallbacks(
    list.filter(module.functions, fn(definition) {
      extract.declares_external(definition)
      && has_running_fallback(definition, package_targets)
    }),
    module,
    module_path,
    knowledge_base,
    registry,
    dict.new(),
    dict.new(),
    package_targets,
  )
}

// The summaries an aborted walk still owes. An import cycle skips the walk
// entirely, leaving each running fallback the `[Unknown]` an unwalked body
// carries — recorded here with the callback shape the walk would have
// recorded beside it, so a suppressing line's conservative charge and the
// call-site binding read the same bounds whether the body was walked or not.
// The term carries the callback variables too: an unwalked body may call any
// of them, and a reading that unions this term pays each callback argument's
// effects beside the `[Unknown]`, named where the walk could not name the
// rest.
pub fn unwalked_fallback_effects(
  module: Module,
  girard_fn_typed: dict.Dict(String, Set(String)),
  package_targets: types.PackageTargets,
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  unwalked_summaries(
    list.filter(module.functions, fn(definition) {
      foreign_definition(definition, package_targets)
      && runs_fallback_body(definition, package_targets)
    }),
    signatures.type_alias_map(module.type_aliases),
    girard_fn_typed,
  )
}

// The same, for a dependency module the walk order dropped for importing
// another in a cycle.
pub fn unwalked_dependency_fallback_effects(
  module: Module,
  package_targets: types.PackageTargets,
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  unwalked_summaries(
    list.filter(module.functions, fn(definition) {
      extract.declares_external(definition)
      && has_running_fallback(definition, package_targets)
    }),
    signatures.type_alias_map(module.type_aliases),
    dict.new(),
  )
}

fn unwalked_summaries(
  targets: List(Definition(Function)),
  alias_map: dict.Dict(String, glance.Type),
  girard_fn_typed: dict.Dict(String, Set(String)),
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  targets
  |> list.map(fn(definition) {
    let bounds =
      synthetic_fn_typed_bounds(
        set.from_list(callback_params(
          definition.definition,
          alias_map,
          girard_fn_typed,
        )),
      )
    let term =
      effect_term.normalize(
        TUnion([
          effect_term.unknown(),
          ..list.map(bounds, fn(bound) { TVar(bound.name) })
        ]),
      )
    #(definition.definition.name, #(term, bounds))
  })
  |> dict.from_list
}

// Summarize each of `targets`, which either selector above chose from
// `module.functions`. The whole module comes along because a fallback body's
// unqualified calls are resolved against every function beside it — a sibling
// missing from the map is an unresolved local call, charged `[Unknown]`.
fn walk_fallbacks(
  targets: List(Definition(Function)),
  module: Module,
  module_path: String,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  girard_fn_typed: dict.Dict(String, Set(String)),
  package_targets: types.PackageTargets,
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  use <- bool.guard(when: targets == [], return: dict.new())
  let function_map = build_function_map(module)
  let ModuleContext(context:, cache:) =
    module_context(
      module,
      module_path,
      knowledge_base,
      girard_fn_typed,
      package_targets,
    )
  // One component at a time, callees first. A body reaching another fallback is
  // charged what the knowledge base says about it, and the call graph already
  // says which fallbacks that can be: a component's members reach only
  // components settled before it, or each other. So a fallback on no cycle is
  // done in one walk, and only a genuine cycle iterates to a fixed point —
  // where every fallback in the module used to be re-walked until the module as
  // a whole stopped changing, at least twice each and once more for every link
  // in the longest chain.
  let recursive = recursive_components(module.functions, context, cache)
  let #(settled, _knowledge_base) =
    fallback_components(targets, cache)
    |> list.fold(#(dict.new(), knowledge_base), fn(state, entry) {
      let #(settled, knowledge_base) = state
      let #(component_id, component) = entry
      // A component the cache names no id for is settled as a recursive one:
      // nothing said it isn't.
      let iterates = case component_id {
        Ok(id) -> set.contains(recursive, id)
        Error(Nil) -> True
      }
      let summaries =
        settle_component(
          iterates,
          FallbackWalk(
            targets: component,
            function_map:,
            context:,
            cache:,
            module_path:,
            knowledge_base:,
            registry:,
            module_types:,
            package_targets:,
          ),
        )
      #(
        dict.merge(settled, summaries),
        // Read by the next component's walk, which is a caller of this one.
        effects.with_fallback_summaries(
          knowledge_base,
          qualified_summaries(summaries, module_path),
        ),
      )
    })
  settled
}

// The module's fallback targets grouped into their call-graph components, in
// callee-first order. `build_scc_ids` numbers the components in exactly that
// order, so sorting on the id restores it. A target the cache names no
// component for settles last, on its own — every definition is in the graph, so
// this is an ordering for a state that does not arise rather than a case.
fn fallback_components(
  targets: List(Definition(Function)),
  cache: LocalCache,
) -> List(#(Result(Int, Nil), List(Definition(Function)))) {
  targets
  |> list.group(fn(definition) {
    dict.get(cache.scc_id, definition.definition.name)
  })
  |> dict.to_list
  |> list.sort(fn(left, right) {
    case left.0, right.0 {
      Ok(left), Ok(right) -> int.compare(left, right)
      Ok(_), Error(Nil) -> order.Lt
      Error(Nil), Ok(_) -> order.Gt
      Error(Nil), Error(Nil) -> order.Eq
    }
  })
}

// The call-graph components that reach themselves: one holding more than a
// single function, and one whose lone function calls itself. Only these need a
// fixed point — anything else states its summary on the walk that first makes
// it, and a second walk could only confirm what the knowledge base already
// holds unchanged.
fn recursive_components(
  definitions: List(Definition(Function)),
  context: ImportContext,
  cache: LocalCache,
) -> Set(Int) {
  let names =
    definitions
    |> list.map(fn(definition) { definition.definition.name })
    |> set.from_list
  let multi_member =
    dict.fold(cache.members, set.new(), fn(acc, id, members) {
      case members {
        [_, _, ..] -> set.insert(acc, id)
        _ -> acc
      }
    })
  list.fold(definitions, multi_member, fn(acc, definition) {
    let name = definition.definition.name
    let calls_itself =
      set.contains(recursion_edges(definition.definition, context, names), name)
    case calls_itself, dict.get(cache.scc_id, name) {
      True, Ok(id) -> set.insert(acc, id)
      True, Error(Nil) | False, _ -> acc
    }
  })
}

// Settle one component's summaries. A component that cannot reach itself is
// walked once — nothing it could read changes after that walk. A recursive one
// circulates each label one member per pass until nothing moves. The fuel is a
// cap on divergence, not on the passes convergence takes: a member's first pass
// sees no summary for the call back into the component, so what that call
// substitutes arrives a pass later. Anything still moving when the fuel runs out
// is widened to `[Unknown]` rather than reported as the under-approximation the
// last pass walked.
fn settle_component(
  recursive: Bool,
  walk: FallbackWalk,
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  case recursive {
    False -> walk_component(dict.new(), walk)
    True ->
      settle_fallback_effects(
        dict.new(),
        2 * list.length(walk.targets) + 2,
        walk,
      )
  }
}

// A module's settled summaries keyed the way a knowledge base holds them.
fn qualified_summaries(
  summaries: dict.Dict(String, #(EffectTerm, List(ParamBound))),
  module_path: String,
) -> dict.Dict(QualifiedName, #(EffectTerm, List(ParamBound))) {
  dict.fold(summaries, dict.new(), fn(acc, function, summary) {
    dict.insert(acc, QualifiedName(module: module_path, function:), summary)
  })
}

// Everything a fallback-summary pass re-uses across iterations: `targets` is
// one call-graph component's worth of them, and `knowledge_base` already holds
// what every earlier component settled. Only the summaries settled so far change
// between passes, so the walking apparatus is built once and travels whole.
type FallbackWalk {
  FallbackWalk(
    targets: List(Definition(Function)),
    function_map: dict.Dict(String, Definition(Function)),
    context: ImportContext,
    cache: LocalCache,
    module_path: String,
    knowledge_base: KnowledgeBase,
    registry: SignatureRegistry,
    module_types: dict.Dict(#(Int, Int), girard.Type),
    // What decides the targets each member's body runs on, and so the targets
    // every name that body calls is read on.
    package_targets: types.PackageTargets,
  )
}

fn settle_fallback_effects(
  settled: dict.Dict(String, #(EffectTerm, List(ParamBound))),
  fuel: Int,
  walk: FallbackWalk,
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  // Reached only while the summaries are still changing, so what `settled`
  // holds is not a fixed point: some effect is still travelling and the next
  // pass would have added it. Every summary is widened to `[Unknown]` — which
  // ones were still moving is unknowable without the passes the fuel denies —
  // so a caller is charged conservatively rather than a pass-count under-count.
  use <- bool.guard(when: fuel <= 0, return: widen_unsettled(settled))
  let walked = walk_component(settled, walk)
  case walked == settled {
    True -> settled
    False -> settle_fallback_effects(walked, fuel - 1, walk)
  }
}

// One walk of every member of a component, each body summarised against what
// the component has settled so far.
fn walk_component(
  settled: dict.Dict(String, #(EffectTerm, List(ParamBound))),
  walk: FallbackWalk,
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  // What this component has settled so far, so a body reaching one of its own
  // members is charged what that member's body does. The bounds travel inside
  // the summaries: a member's summary is stated over its parameters, and without
  // the bound the call into it has nothing to re-key its variable onto the
  // calling fallback's own parameter — a girard-typed parameter carries no
  // annotation for the syntactic fallback to find.
  //
  // Every target this pass will summarize has an entry, empty where no pass has
  // settled it yet. What the base holds is then the iteration's own state rather
  // than silence, and silence outside it means a walk that never ran — which is
  // what `with_running_fallback` widens to `[Unknown]`. Left absent, that
  // widening would enter a self-recursive fallback's first pass and no later
  // pass would remove it.
  let knowledge_base =
    effects.with_fallback_summaries(
      walk.knowledge_base,
      list.fold(walk.targets, dict.new(), fn(acc, definition) {
        let function = definition.definition.name
        let summary = case dict.get(settled, function) {
          Ok(summary) -> summary
          Error(Nil) -> #(effect_term.pure(), [])
        }
        dict.insert(acc, function, summary)
      })
        |> qualified_summaries(walk.module_path),
    )
  // Grouped by the targets each body runs on, because that is what decides how
  // the names it calls read: a member reaching a target-conditional external
  // reaches whichever of its halves is built alongside this body. The memo
  // holding those readings is per group for the same reason — shared across two
  // groups, it would hand one member an analysis performed on targets that
  // member never runs on. A module's fallbacks nearly always share one set, so
  // grouping costs the sharing nothing in practice.
  walk.targets
  |> list.group(body_targets(_, types.declaration_targets(walk.package_targets)))
  |> dict.to_list
  |> list.flat_map(fn(group) {
    let #(active, definitions) = group
    let knowledge_base =
      effects.with_active_targets(knowledge_base, option.Some(active))
    let #(_memo, entries) =
      list.map_fold(definitions, new_memo(), fn(memo, definition) {
        // The same synthetic bounds ordinary inference gives a function-typed
        // parameter, so a fallback that calls one is charged that argument's
        // effects rather than the `[Unknown]` an unbound call collapses to. A
        // fallback has no `check` line of its own to declare any, so every one
        // of them is synthesised.
        let fn_typed_params =
          unbound_fn_typed_params(definition, [], walk.cache)
        let synthetic_bounds = synthetic_fn_typed_bounds(fn_typed_params)
        let #(pairs, memo) =
          collect_effects(
            without_returned_closure(definition.definition),
            walk.function_map,
            walk.context,
            knowledge_base,
            set.new(),
            synthetic_bounds,
            walk.registry,
            walk.module_types,
            dict.new(),
            walk.cache,
            [],
            memo,
          )
        // The same grooming inference applies before a term is stated anywhere:
        // a summary keeping a phantom would make `graded effect` report the
        // internal name while callers and `why` groom the same term to
        // `[Unknown]`.
        let #(term, field_vars) =
          groom_published_term(union_of(pairs), fn_typed_params)
        // The bounds carry the fallback's *whole* callback shape — every
        // fn-typed parameter, invoked by the body or not — plus a binder for
        // each field-effect variable the term keeps. A lift rebuilding the
        // abstraction reads the parameters off these names, and filtering to
        // the variables surviving in the term would drop an uninvoked callback
        // and shift every later binder onto the wrong argument. A bound whose
        // variable the term never mentions binds vacuously everywhere else, so
        // the fuller list costs nothing.
        let bounds =
          list.append(
            synthetic_bounds,
            polymorphic_param_bounds(term, field_vars),
          )
        #(memo, #(definition.definition.name, #(term, bounds)))
      })
    entries
  })
  |> dict.from_list
}

// Union `[Unknown]` into every summary term. The bounds stay: the term's
// variables still substitute at call sites, so a caller passing an effectful
// callback is charged it beside the conservative widening.
fn widen_unsettled(
  settled: dict.Dict(String, #(EffectTerm, List(ParamBound))),
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  dict.map_values(settled, fn(_function, summary) {
    let #(term, bounds) = summary
    #(
      effect_term.normalize(types.TUnion([term, effect_term.unknown()])),
      bounds,
    )
  })
}

// Everything the body walker needs about the module it walks. Built the same
// way for every entry point, so a function explained is a function checked.
type ModuleContext {
  ModuleContext(context: ImportContext, cache: LocalCache)
}

fn module_context(
  module: Module,
  module_path: String,
  knowledge_base: KnowledgeBase,
  girard_fn_typed: dict.Dict(String, Set(String)),
  package_targets: types.PackageTargets,
) -> ModuleContext {
  let context =
    extract.build_import_context(module)
    |> extract.with_module_path(module_path)
    |> extract.with_package_targets(package_targets)
    |> extract.with_factories(extract.factory_map(
      module_path,
      module,
      types.declaration_targets(package_targets),
      effects.constructors(knowledge_base),
    ))
    |> extract.with_updates(extract.update_map(
      module_path,
      module,
      types.declaration_targets(package_targets),
      effects.constructors(knowledge_base),
    ))
    |> extract.with_cross_factories(effects.factories(knowledge_base))
    |> extract.with_cross_updates(effects.updates(knowledge_base))
    |> extract.with_cross_constructors(effects.constructors(knowledge_base))
    |> extract.with_fn_typed_fields(signatures.fn_typed_fields_from_module(
      module,
      signatures.type_alias_map(module.type_aliases),
    ))
  ModuleContext(
    context:,
    cache: build_scc_ids(module, context, girard_fn_typed),
  )
}

// Lift a record field wired to an inline closure into an effect *operator*,
// abstracting over every closure parameter. A first-order field
// (`to_error: fn(m) { io.println(m) }`) becomes `λm. [Stdout]` (applying it to
// the field call's argument gives `[Stdout]` back); a higher-order field
// (`run: fn(next) { next() }`) becomes `λnext. [next]` (applying it gives the
// callback's effect). `resolve_field_effect` applies the operator at the field
// call. `function_map` resolves same-module calls, and `module_types` is the
// enclosing module's own type environment, so a field call in the closure body
// whose receiver only girard can type (`c.inner.run(m)`) resolves here as it
// does in an ordinary body. A minimal registry is enough for the common case of
// a closure calling library/qualified functions.
fn closure_field_operator(
  params: List(String),
  body: List(Statement),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  // The module's SCC ids, built once by the caller (`build_scc_ids`) and reused
  // across every field closure it analyses.
  scc_ids: LocalCache,
) -> EffectTerm {
  // A fresh memo per closure: these bodies are shallow, so not sharing
  // sub-results across the fields of one module costs nothing. It is discarded,
  // so nothing computed here is reused under a different type environment.
  // Abstract over every parameter (positions 0..n-1), in order.
  let positions = list.index_map(params, fn(_, index) { index })
  analyze_closure(
    params,
    [],
    body,
    positions,
    context,
    function_map,
    knowledge_base,
    set.new(),
    signatures.empty(),
    module_types,
    dict.new(),
    set.new(),
    scc_ids,
    new_memo(),
  ).0
}

// Resolve a record field wired from a *call* (`Options(resolver: disk_resolver())`)
// to the operator that call's callee returns, so the field consumes a producer's
// `returns` summary instead of falling to `[Unknown]`.
// Reuses the returned-operator engine: a same-module producer's summary is
// computed on demand from `function_map` (the `""` callee), a cross-module one is
// read from the knowledge base, and a polymorphic summary is bound to the
// construction-site `args`. `scc_ids` carries Fix A's alias map so an aliased
// return type resolves; the real `registry` lets a cross-module producer's
// annotated operator params be detected at bind time; `module_types` is the
// enclosing module's own type environment, so a field call in the producer's
// returned closure resolves against girard's types rather than degrading.
fn call_result_field_operator(
  callee: types.QualifiedName,
  args: List(types.CallArgument),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  scc_ids: LocalCache,
) -> Result(EffectTerm, Nil) {
  resolve_returned_operator(
    callee,
    args,
    context,
    function_map,
    knowledge_base,
    set.new(),
    registry,
    module_types,
    [],
    scc_ids,
    new_memo(),
  ).0
  |> result.map(fn(found) { found.0 })
}

// The ground effect of a function from the module under inference wired into a
// record field. Sibling functions aren't in the knowledge base during their
// module's inference pass, so a knowledge-base *miss* on a same-module name
// lifts the definition out of `function_map` — the same `lift_local_function`
// call an operator argument already makes for a same-module reference —
// instead of collapsing to `[Unknown]`.
//
// Only a ground lift is taken. A term carrying binders or free variables is an
// operator awaiting the field call's arguments, or a summary whose sentinel
// variables are never collapsed; carrying either into a `TypeFieldEffect` can
// resolve *narrower* than `[Unknown]`, so those keep the knowledge-base answer.
// A bodyless `@external` has no body to analyse — lifting one would read as
// pure — so it keeps the knowledge-base answer too, as `resolve_unknown_local`
// does for a direct call. `visited` is the enclosing call stack, so a field
// wired to a function already under analysis lifts nothing.
//
// The lift runs under the module's own `module_types`, the same environment
// every other analysis of this module uses. A field call in the lifted body
// whose receiver only girard can type — `config.inner.run()` against a
// `type Config.inner`/`type Box.run` pair — then resolves here exactly as it
// does when the function is inferred directly, instead of leaving a residual
// field variable that `has_vars` rejects into `[Unknown]`. Sharing the enclosing
// memo is sound for the same reason: `memo.lifts` is keyed on
// `#(name, ancestors)` with no type-environment component, so every lift of a
// given function must run under one environment.
fn local_function_field_effect(
  name: types.QualifiedName,
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  scc_ids: LocalCache,
  memo: Memo,
) -> #(option.Option(EffectTerm), Memo) {
  use <- bool.guard(name.module != context.module_path, #(None, memo))
  use <- bool.guard(set.contains(visited, name.function), #(None, memo))
  case dict.get(function_map, name.function) {
    Error(Nil) -> #(None, memo)
    Ok(definition) ->
      case foreign_definition(definition, context.package_targets) {
        True -> #(None, memo)
        False -> {
          let #(term, memo) =
            lift_local_function(
              name.function,
              definition,
              context,
              function_map,
              knowledge_base,
              visited,
              registry,
              module_types,
              scc_ids,
              memo,
            )
          case is_operator_valued(term) || has_vars(term) {
            True -> #(None, memo)
            False -> #(Some(term), memo)
          }
        }
      }
  }
}

// Violation reporting
//
// The prose rendering of a `Violation`. Synthetic call sites are minted as a
// `CallKind` (see `sentinel_call`) and carried on the violation as a sentinel
// qualified name, so the encoder and the decoder that reads one back into a
// description of the call both belong here.

// The sentinel modules a synthetic call site is encoded with. `<` can't start a
// Gleam module path, so a sentinel never collides with a real qualified call.
// `sentinel_name` writes them and `call_kind` reads them — both from here, so a
// mint site can't drift from the classifier.
const param_sentinel = "<param>"

const field_sentinel = "<field>"

const returned_sentinel = "<returned>"

const pipe_sentinel = "<pipe>"

const apply_sentinel = "<apply>"

const closure_sentinel = "<closure>"

const local_sentinel = "<local>"

const external_sentinel = "<external>"

const declared_sentinel = "<declared>"

// The sentinel for a kind that carries no name of its own, and the placeholder
// payloads of the kinds whose identity is the sentinel module alone.
const unclassified_sentinel = "<call>"

const operator_payload = "<operator>"

const applied_payload = "<applied>"

const unknown_payload = "<unknown>"

// What a violating call site is. `DirectCall` is an ordinary qualified call;
// every other variant is one of the synthetic forms `sentinel_call` mints.
pub type CallKind {
  // A qualified call to a module function.
  DirectCall(module: String, function: String)
  // A call to a fn-typed parameter of the enclosing function.
  ParameterCall(parameter: String)
  // A field call `receiver.label(args)`. `receiver` may itself be a dotted path.
  FieldAccessCall(receiver: String, label: String)
  // A field call whose receiver is a computed value (`make().label(args)`), so
  // it has no source path to name.
  ComputedFieldCall(label: String)
  // An unqualified call that matched no parameter bound and no function of the
  // enclosing module, so nothing resolved its effects.
  UnresolvedLocalCall(function: String)
  // A direct application of a let-bound function that `producer` returned.
  // `producer.module` is `""` for a producer in the calling module.
  ReturnedOperatorCall(producer: QualifiedName)
  // The `@external` declaration of the function under analysis, not a call in
  // its body: what an external contributes is what declares it. Carried as a
  // kind of its own so the prose says the function *is* an external rather
  // than that it calls one. `name` is the declaration's own dotted name, which
  // identifies the entry — the prose states it from the enclosing function.
  ExternalDeclaration(name: String)
  // The declaration that answers for an ordinary Gleam function of this
  // package: a module-level `assume <module>` line, which is what its
  // callers pay whatever the body beside it does. Separate from
  // `ExternalDeclaration` because the function is not foreign code — its Gleam
  // body is right there and walked beside this line — and calling it an external
  // contradicted the rule that rejects the per-function form over such a
  // function for exactly that reason.
  CallerDeclaration(name: String)
  // An application of an inline function value: a pipe target (`x |> fn(f) {
  // .. }`) or an immediately-invoked closure / `case` of functions.
  InlineFunctionCall
  // A direct application of a let-bound function value — a closure or a `case`
  // of functions.
  LetBoundValueCall
  // An application of an opaque computed function value.
  ComputedValueCall
  // A synthetic call site this classifier doesn't recognise, or a recognised one
  // whose payload is malformed. Rendered generically, so a sentinel is never
  // shown as the call's identity.
  UnclassifiedCall
}

// The sentinel qualified name a synthetic call site carries for `kind` — the
// inverse of `call_kind`.
fn sentinel_name(kind: CallKind) -> QualifiedName {
  case kind {
    DirectCall(module:, function:) -> QualifiedName(module:, function:)
    ParameterCall(parameter:) -> QualifiedName(param_sentinel, parameter)
    FieldAccessCall(receiver:, label:) ->
      QualifiedName(field_sentinel, receiver <> "." <> label)
    ComputedFieldCall(label:) ->
      QualifiedName(field_sentinel, extract.computed_receiver <> "." <> label)
    UnresolvedLocalCall(function:) -> QualifiedName(local_sentinel, function)
    ReturnedOperatorCall(producer:) ->
      QualifiedName(returned_sentinel, types.dotted_name(producer))
    ExternalDeclaration(name:) -> QualifiedName(external_sentinel, name)
    CallerDeclaration(name:) -> QualifiedName(declared_sentinel, name)
    InlineFunctionCall -> QualifiedName(pipe_sentinel, operator_payload)
    LetBoundValueCall -> QualifiedName(closure_sentinel, applied_payload)
    ComputedValueCall -> QualifiedName(apply_sentinel, unknown_payload)
    UnclassifiedCall -> QualifiedName(unclassified_sentinel, "")
  }
}

// Classify a call site by its (possibly sentinel) qualified name. A module
// starting with `<` that matches no sentinel is `UnclassifiedCall`; only a
// module that cannot be a sentinel is a `DirectCall`.
pub fn call_kind(call: QualifiedName) -> CallKind {
  case call.module {
    module if module == param_sentinel ->
      payload_kind(call.function, ParameterCall)
    module if module == field_sentinel -> field_access_kind(call.function)
    module if module == returned_sentinel ->
      returned_operator_kind(call.function)
    module if module == external_sentinel -> ExternalDeclaration(call.function)
    module if module == declared_sentinel -> CallerDeclaration(call.function)
    module if module == pipe_sentinel -> InlineFunctionCall
    module if module == apply_sentinel -> ComputedValueCall
    module if module == closure_sentinel -> LetBoundValueCall
    module if module == local_sentinel ->
      payload_kind(call.function, UnresolvedLocalCall)
    module -> {
      use <- bool.guard(
        when: string.starts_with(module, "<"),
        return: UnclassifiedCall,
      )
      DirectCall(module:, function: call.function)
    }
  }
}

// Render a warning as the line `graded check` reports.
pub fn format_warning(file: String, warning: Warning) -> String {
  case warning {
    UntrackedEffectWarning(function:, reference:, effects: effs, ..) ->
      file
      <> ": warning: "
      <> function
      <> " passes "
      <> reference.module
      <> "."
      <> reference.function
      <> " as a value — its effects "
      <> effects.format_effect_set(effs)
      <> " won't be tracked"
    UnmatchedFieldBoundWarning(function:, field_path:, receiver_is_param:) -> {
      let cause = case receiver_is_param {
        True -> " matches no field call in its body — check the path"
        // A non-parameter receiver can be traced to a construction site, so the
        // call may exist but resolve through value provenance, shadowing the bound.
        False ->
          " matches no field call in its body — check the path, or the receiver is traced to a construction site and resolved through value provenance (field bounds apply only to untraceable receivers)"
      }
      file
      <> ": warning: field bound "
      <> field_path
      <> " on "
      <> function
      <> cause
    }
    UnmatchedParamBoundWarning(function:, param:) ->
      file
      <> ": warning: parameter bound "
      <> param
      <> " on "
      <> function
      <> " names no parameter of the function — check the name"
    UnmatchedCheckWarning(function:) ->
      file
      <> ": warning: check "
      <> function
      <> " names no function in any project module — check the module qualifier; the check never runs"
    UnmatchedFieldCheckWarning(name:) ->
      file
      <> ": warning: check "
      <> name
      <> " names no field of any type this package can see — check the module qualifier; the check weighs no construction site"
    NonCallableFieldCheckWarning(name:) ->
      file
      <> ": warning: check "
      <> name
      <> " names a field no variant makes callable — only a callable field carries an effect budget, so the check weighs nothing"
    UnconstructedFieldCheckWarning(name:) ->
      file
      <> ": warning: check "
      <> name
      <> " names a callable field nothing in this package constructs a value of — the check holds over no site, and proves nothing. A construction outside the package is not one graded can see"
    UnsupportedFieldCheckWarning(name:, components:) ->
      file
      <> ": warning: check "
      <> name
      <> " carries "
      <> listed_components(components)
      <> " on a field path, which nothing verifies — a field check weighs the values the package wires into the field, and a field head scopes no bound list and keys no returned operator"
    UnkeyedEffectsShapeWarning(name:) ->
      file
      <> ": warning: effects "
      <> name
      <> " is not a function path — only `module.function` keys an effects line, so this one resolves nothing and the next `graded infer` drops it; `assume` is the line that takes a field or module path"
    UnmatchedFieldAssumeWarning(name:) ->
      file
      <> ": warning: assume "
      <> name
      <> " names no field of any project type — check the module qualifier; the field resolves to [Unknown]"
    StaleFunctionAssumeWarning(function:) ->
      file
      <> ": warning: assume "
      <> function
      <> " names a function of this package with a Gleam body — the line declares no foreign code and is ignored; the body is walked instead. There is no replacement: fix the source, or widen the check budget"
    UnmatchedFunctionAssumeWarning(function:) ->
      file
      <> ": warning: assume "
      <> function
      <> " names no dependency, catalog, or project function — check the module qualifier; the declaration covers nothing"
    UnmatchedModuleAssumeWarning(module:) ->
      file
      <> ": warning: assume "
      <> module
      <> " names no dependency or project module — check the module path; the declaration covers nothing"
    StaleReturnsClauseWarning(function:) ->
      file
      <> ": warning: assume "
      <> function
      <> " where returns names a function of this package with a Gleam body — every caller resolves what it returns from that body, so the clause declares nothing and is ignored. `graded infer` removes it and writes the inferred clause on the `effects` line in its place"
    UnmatchedReturnsClauseWarning(function:) ->
      file
      <> ": warning: assume "
      <> function
      <> " where returns names no dependency, catalog, or project function — check the module qualifier; the declaration covers nothing"
    UnclosedReturnsClauseWarning(function:, free_vars:) ->
      file
      <> ": warning: the `where returns` clause on "
      <> function
      <> " has free variable(s) "
      <> quoted_names(free_vars)
      <> " naming no callback parameter of it — the clause is ignored and the returned function resolves to [Unknown]"
    UngroundReturnsClauseWarning(function:, free_vars:) ->
      file
      <> ": warning: the `where returns` clause on assume "
      <> function
      <> " has variable(s) "
      <> quoted_names(free_vars)
      <> " the line's bounds do not scope — nothing binds an unscoped variable at a call site, so the clause is ignored. Name the variable in the line's bound list, or spell out the concrete effects"
    UnboundAssumeTermVariableWarning(function:, free_vars:) ->
      file
      <> ": warning: assume "
      <> function
      <> " declares effects with variable(s) "
      <> quoted_names(free_vars)
      <> " that no bound's payload binds — substitution keys are the payloads' variables, so no call site can resolve them and they stay conservative. Add a bound whose payload names the variable, or remove it"
    AliasedBoundVariableWarning(function:, variables:) ->
      file
      <> ": warning: on "
      <> function
      <> " variable(s) "
      <> quoted_aliases(variables)
      <> " also name a parameter of the line — the effects term binds such a variable through the payload while the `where returns` clause binds it by parameter name, so the two can charge different arguments. Rename the payload's variable"
    DotlessReturnsClauseWarning(name:) ->
      file
      <> ": warning: assume "
      <> name
      <> " where returns names a module, not a function — a returns declaration is per-function; the clause resolves nothing"
    UnknownClauseWarning(path:, keys:) ->
      file
      <> ": warning: the `where` clause(s) on "
      <> path
      <> " use key(s) "
      <> quoted_names(keys)
      <> " this version of graded does not read, so nothing resolves them. They are kept verbatim through `graded format` and `graded infer`; upgrade graded, or delete them"
  }
}

// A list of names as a comma-separated run of backticked ones, the spelling
// every warning that names more than one uses.
fn quoted_names(names: List(String)) -> String {
  names |> list.map(fn(name) { "`" <> name <> "`" }) |> string.join(", ")
}

// A list of aliased variables, each beside the bound whose payload binds it.
fn quoted_aliases(variables: List(#(String, String))) -> String {
  variables
  |> list.map(fn(pair) { "`" <> pair.0 <> "` (payload of `" <> pair.1 <> "`)" })
  |> string.join(", ")
}

// Render a violation as the line `graded check` reports.
pub fn format_violation(file: String, violation: Violation) -> String {
  file
  <> ": "
  <> violation.function
  <> " "
  <> format_call_explanation(violation.explanation)
  <> " but declared "
  <> effects.format_effect_set(violation.declared)
  <> variables_hint(violation.function, violation.explanation)
}

// Render a `check` finding as the line `graded check` reports. An unproved
// outcome is worded as something graded could not prove, never as something
// the checked code violates: it rides the reported channel so the run exits
// non-zero, but the limit is the analysis's.
pub fn format_finding(file: String, finding: CheckFinding) -> String {
  case finding {
    ReturnsClauseViolation(function:, declared:, computed:) ->
      file
      <> ": "
      <> function
      <> " returns the operator "
      <> annotation.format_operator(computed)
      <> " but its `where returns` clause declares "
      <> annotation.format_operator(declared)
    NonCallableReturnViolation(function:, declared:) ->
      file
      <> ": "
      <> function
      <> " does not return a function, so its `where returns` clause "
      <> annotation.format_operator(declared)
      <> " describes an operator the function never hands back"
    FieldArityViolation(field_path:, declared:, arity:, site:) ->
      file
      <> ": "
      <> site.function
      <> " builds "
      <> site.constructor.variant
      <> ", whose "
      <> field_path
      <> " takes "
      <> int.to_string(arity)
      <> " argument(s), but the check declares the operator "
      <> annotation.format_operator(declared)
    FieldSiteViolation(field_path:, declared:, actual:, site:) ->
      file
      <> ": "
      <> site.function
      <> " wires "
      <> field_path
      <> " with effects "
      <> annotation.format_operator(actual)
      <> " but the field is declared "
      <> annotation.format_operator(declared)
    UnprovedCheck(subject:, cause:, site:) ->
      file
      <> ": could not prove check "
      <> subject
      <> site_clause(site)
      <> " — "
      <> unproved_cause_clause(cause)
  }
}

fn listed_components(components: List(CheckComponent)) -> String {
  components
  |> list.map(fn(component) {
    case component {
      FieldBoundList -> "a bound list"
      FieldReturnsClause -> "a `where returns` clause"
    }
  })
  |> string.join(" and ")
}

fn site_clause(site: Option(ConstructionSite)) -> String {
  case site {
    None -> ""
    Some(site) -> " at " <> site.function
  }
}

fn unproved_cause_clause(cause: UnprovedCause) -> String {
  case cause {
    UntracedFieldValue ->
      "the value wired here does not resolve to a function graded can follow; an `assume` line is the trusted form for a field it cannot"
    UncalledFactory(factory:) ->
      "the field is wired from a parameter of `"
      <> factory
      <> "`, and no call of it is visible in this package"
    UnderivableReturnedOperator(reason:) -> underivable_clause(reason)
    UndeclaredForeignReturn ->
      "the producer is foreign, so its returned operator comes from a declaration rather than from source, and nothing declares one; an `assume … where returns` line is what answers for it"
    UnprovedForeignFallback ->
      "the external's Gleam fallback body runs, and there is no union of operators to weigh it with the declaration; the clause holds only when it agrees with the declaration and the fallback's own returned operator is proved beside it"
    UnsupportedCheckComponent(component: FieldBoundList) ->
      "a bound list on a field path is not verified, and the bounds are what scope the effects term, so the budget cannot be read without them"
    UnsupportedCheckComponent(component: FieldReturnsClause) ->
      "a `where returns` clause on a field path is not verified — nothing keys an operator returned by calling a field. The field budget on the same line still is"
  }
}

fn underivable_clause(reason: ReturnedOperatorReason) -> String {
  case reason {
    NoReturnAnnotation ->
      "the function carries no return type annotation, so the operator it hands back cannot be derived from source"
    ReturnIsNotAFunction -> "its return type is not a function type"
    UnresolvedReturnTail ->
      "the value it returns does not resolve to a function graded can follow"
  }
}

// What the function did and the effects it picked up doing it. The effects are
// `unresolved` exactly when the set carries the `Unknown` label — a call that
// resolves cleanly and still blows its budget is not an unresolved one.
//
// The recorded reason refines the action only for a set that stayed unresolved:
// a reason discharged by a bound describes nothing the reader can still see.
// The origin is stated whenever one was recorded, including beside an
// `[Unknown]` a source claims — there, naming the source *is* the explanation.
pub fn format_call_explanation(explanation: CallExplanation) -> String {
  let kind = call_kind(explanation.call)
  let unresolved = types.contains_unknown(explanation.actual)
  let action = case unresolved, explanation.reason {
    True, Some(reason) -> refined_action(kind, reason)
    True, None | False, _ -> plain_action(kind)
  }
  let effects_word = case unresolved {
    True -> " with unresolved effects "
    False -> " with effects "
  }
  action
  <> effects_word
  <> effects.format_effect_set(explanation.actual)
  <> origin_suffix(explanation.origin, explanation.fallback, explanation.reason)
}

// What a call site is, stated from its kind alone.
fn plain_action(kind: CallKind) -> String {
  case kind {
    DirectCall(module:, function:) -> "calls " <> module <> "." <> function
    ParameterCall(parameter:) -> "calls parameter `" <> parameter <> "`"
    FieldAccessCall(receiver:, label:) ->
      "calls field `" <> label <> "` on `" <> receiver <> "`"
    ComputedFieldCall(label:) ->
      "calls field `" <> label <> "` on a computed value"
    // States only what the sentinel establishes. The name may well be bound in
    // the body (a destructured binding, a module constant, a record field
    // path) — what failed is resolving it to a parameter bound or to a function
    // of this module.
    UnresolvedLocalCall(function:) ->
      "calls `"
      <> function
      <> "`, which is neither a bound parameter nor a function in this module,"
    ReturnedOperatorCall(producer:) ->
      "calls a function returned by `" <> types.dotted_name(producer) <> "`"
    // Not the call's name: the enclosing function *is* this external, and the
    // line already leads with that function's name.
    ExternalDeclaration(..) -> "is an external"
    // Ordinary Gleam, so the phrase says what the declaration does rather than
    // what the function is: it governs the callers, and the body walked beside
    // it is the rest of the block.
    CallerDeclaration(..) -> "is declared for its callers"
    InlineFunctionCall -> "calls an inline function"
    LetBoundValueCall -> "calls a let-bound function value"
    ComputedValueCall -> "calls a computed function value"
    UnclassifiedCall -> "calls an unclassified call site"
  }
}

// A kind's own phrase followed by the clause its recorded reason adds.
fn refined_action(kind: CallKind, reason: UnknownReason) -> String {
  plain_action(kind) <> reason_clause(kind, reason)
}

// What a reason adds to the phrase its call kind already carries, continuing
// that phrase up to the effects clause. Empty for a reason minted for a
// different kind: the phrase then says everything the reason would. Every
// kind names the reasons it has no clause for, so a new pairing has to be
// decided rather than silently dropped.
fn reason_clause(kind: CallKind, reason: UnknownReason) -> String {
  case kind {
    DirectCall(..) ->
      case reason {
        NoKnownEffects -> ", which no spec, external, or catalog declares,"
        UndeclaredExternal -> ", an external with no declared effects,"
        UnbuiltExternal ->
          ", an external declared only for a target this build does not compile,"
        UntraceableArgument -> untraceable_argument_clause
        FieldNotAnnotated(..)
        | ReceiverTypeUnresolved
        | UntraceableReceiver
        | UnresolvedFieldValue
        | UntraceableProducer
        | RefusedDeclaredReturn -> ""
      }
    FieldAccessCall(..) ->
      case reason {
        FieldNotAnnotated(module:, type_name:) ->
          " of type `"
          <> types.dotted_name(QualifiedName(module:, function: type_name))
          <> "`, which has no effect annotation for that field,"
        ReceiverTypeUnresolved -> ", whose type could not be resolved,"
        UntraceableReceiver -> ", whose value could not be traced,"
        UnresolvedFieldValue ->
          ", whose wired value's effects could not be resolved,"
        UntraceableArgument -> untraceable_argument_clause
        // The value wired into the field is foreign code nothing declares, so
        // the field call says what a direct call to that name says.
        UndeclaredExternal -> ", wired to an external with no declared effects,"
        // The value wired into the field is foreign code this build never
        // compiles, so the field call says what a direct call to that name says.
        UnbuiltExternal ->
          ", wired to an external declared only for a target this build does not compile,"
        NoKnownEffects | UntraceableProducer | RefusedDeclaredReturn -> ""
      }
    // An undeclared external is the one reason worth stating: nothing said what
    // the foreign code does, which is why the effects stayed unresolved.
    ExternalDeclaration(..) ->
      case reason {
        UndeclaredExternal | NoKnownEffects -> " with no declared effects,"
        UnbuiltExternal ->
          " declared only for a target this build does not compile,"
        FieldNotAnnotated(..)
        | ReceiverTypeUnresolved
        | UntraceableReceiver
        | UnresolvedFieldValue
        | UntraceableProducer
        | RefusedDeclaredReturn
        | UntraceableArgument -> ""
      }
    ReturnedOperatorCall(..) ->
      case reason {
        UntraceableProducer -> ", whose producer could not be resolved,"
        // The producer is the same `@external` a direct call reports out of
        // reach, read one channel over: what it declares about the value is no
        // more built than what it declares about the call.
        UnbuiltExternal ->
          ", an external declared only for a target this build does not compile,"
        RefusedDeclaredReturn ->
          ", whose declared return is refused where its Gleam fallback body also runs,"
        NoKnownEffects
        | UndeclaredExternal
        | FieldNotAnnotated(..)
        | ReceiverTypeUnresolved
        | UntraceableReceiver
        | UnresolvedFieldValue
        | UntraceableArgument -> ""
      }
    // A computed receiver keeps its wording throughout — "on a computed value"
    // already states the untraceability every field reason would repeat. A
    // declaration over ordinary Gleam carries no reason at all: the line that
    // answered is what makes it a contributor, and a name nothing declares is
    // never one.
    ParameterCall(..)
    | CallerDeclaration(..)
    | ComputedFieldCall(..)
    | UnresolvedLocalCall(..)
    | InlineFunctionCall
    | LetBoundValueCall
    | ComputedValueCall
    | UnclassifiedCall -> ""
  }
}

// The clause for an effect the call site's own argument left unresolved. Shared
// by the kinds that substitute arguments into a resolved term.
const untraceable_argument_clause = ", whose effects depend on an argument that could not be resolved,"

// The source that answered, after the effect set it produced.
fn origin_suffix(
  origin: option.Option(LookupOrigin),
  fallback: types.FallbackDisposition(types.EffectSet),
  reason: option.Option(UnknownReason),
) -> String {
  // A running fallback body is a second source, and the origin speaks only for
  // the declaration. Naming it is what stops a declaration of `[]` being read
  // as where a `[Disk]` beside it came from — and, where the `assume` line
  // suppressed the body's charge, what says a body runs that the total no
  // longer counts.
  let body = case fallback {
    types.NoFallback -> ""
    types.FallbackCharged(_) -> charged_body_clause
    types.FallbackSuppressed(_) -> suppressed_body_clause
  }
  case origin, fallback {
    Some(origin), types.NoFallback ->
      " (from " <> effects.describe_origin(origin) <> ")"
    Some(origin), types.FallbackCharged(_)
    | Some(origin), types.FallbackSuppressed(_)
    -> " (from " <> effects.describe_origin(origin) <> ", " <> body <> ")"
    // No origin and a charged body. Either nothing declared the external, and
    // the `[Unknown]` the call's own clause already names is the union's other
    // half — or a declaration exists and covers no target the calling body runs
    // on, leaving that body as the whole of what was charged.
    None, types.FallbackCharged(_) ->
      case reason {
        Some(UndeclaredExternal) -> " (" <> body <> ")"
        _ ->
          " (from its Gleam fallback body, which is what runs on the targets this one does)"
      }
    // Suppression is minted only where a declaration is charged, and the
    // branches that drop the origin drop the fallback share with it.
    None, types.FallbackSuppressed(_) -> " (" <> body <> ")"
    None, types.NoFallback -> ""
  }
}

// The two clauses a running body is named by, each worded the same wherever a
// caller-side surface states it: one for a body's charge in the total, one for
// a body an `assume` line un-charged.
const charged_body_clause = "unioned with its Gleam fallback body"

const suppressed_body_clause = "its Gleam fallback body's charge suppressed by the `assume` line"

// When the actual set still contains effect variables, the substitution
// couldn't bind them (e.g. caller's own param has no declared bound).
// Hint at the fix instead of letting the user puzzle over `[e_xxx]`.
fn variables_hint(function: String, explanation: CallExplanation) -> String {
  use <- bool.guard(when: !types.has_variables(explanation.actual), return: "")
  "\n  hint: actual effects contain unresolved variables; add a `check "
  <> function
  <> "(<param>: [...])` bound, or pass a function reference / constructor"
  <> " whose effects are known"
}

// A sentinel kind that carries a name, or the generic kind when the name is
// missing.
fn payload_kind(payload: String, build: fn(String) -> CallKind) -> CallKind {
  case payload {
    "" -> UnclassifiedCall
    name -> build(name)
  }
}

// Split a `<field>` payload into receiver and label at its *last* dot, so a
// nested receiver stays whole (`config.inner.run` -> `config.inner` / `run`).
// A payload missing either half is the generic kind rather than a crash. The
// receiver sentinel a call-result receiver carries names no source path, so it
// describes the receiver as computed instead of printing the sentinel.
fn field_access_kind(payload: String) -> CallKind {
  case annotation.split_qualified_name(payload) {
    Ok(#(receiver, label)) ->
      case receiver == extract.computed_receiver {
        True -> ComputedFieldCall(label:)
        False -> FieldAccessCall(receiver:, label:)
      }
    Error(Nil) -> UnclassifiedCall
  }
}

// Split a `<returned>` payload into the producer's module and function at its
// last dot. A payload with no dot names a producer in the calling module.
fn returned_operator_kind(payload: String) -> CallKind {
  case payload, annotation.split_qualified_name(payload) {
    "", _ -> UnclassifiedCall
    _, Ok(#(module, function)) ->
      ReturnedOperatorCall(QualifiedName(module:, function:))
    _, Error(Nil) ->
      ReturnedOperatorCall(QualifiedName(module: "", function: payload))
  }
}

// A qualified name as one dotted string, bare when the module is `""` — the
// calling module for a function, and the syntactic fallback (which resolves no
// module) for a receiver type. Used for the `<returned>` payload, for a
// receiver's type, and for the prose.

// Shared analysis helpers
//
// Small utilities shared across every resolution path: call-argument lookup,
// sentinel calls for derived effects, returned-closure trimming, and
// effect-term/param-bound manipulation.

// A call's recorded arguments, or `[]` if none were tracked. Keyed by the
// call's full span (see `extract.span_key`), so writer and reader agree.
fn call_args_for(
  call_args: dict.Dict(#(Int, Int), List(types.CallArgument)),
  span: Span,
) -> List(types.CallArgument) {
  dict.get(call_args, extract.span_key(span)) |> result.unwrap([])
}

// A synthetic resolved call carrying an inferred effect that isn't an ordinary
// catalog lookup. `kind` says how the effect was derived; it travels as the
// sentinel name `sentinel_name` encodes, which `call_kind` decodes back for
// diagnostics.
fn sentinel_call(kind: CallKind, span: Span) -> ResolvedCall {
  types.ResolvedCall(name: sentinel_name(kind), span:)
}

// How to describe a call resolved through `param_bounds`. That one list holds
// parameter bounds *and* dotted field bounds, so a dotted name is a field
// access (`let f = config.resolver; f("x")`) and describes as one — matching
// what the un-aliased `config.resolver("x")` reports.
fn bound_call_kind(name: String) -> CallKind {
  case annotation.split_qualified_name(name) {
    Ok(#(receiver, label)) -> FieldAccessCall(receiver:, label:)
    Error(Nil) -> ParameterCall(name)
  }
}

// The receiver path a field call keys its bound, field variable, and diagnostics
// on: the canonical parameter path for a parameter-rooted receiver (a `let`
// alias resolves through the parameter it stands for), otherwise the syntactic
// receiver. Keeping every site on this one path means `let f = options;
// f.resolver()` matches a `check f(options.resolver: …)` bound, resolves like the
// bare parameter, and never reports a spurious unmatched-bound warning.
fn field_call_receiver(field_call: types.FieldCall) -> String {
  case field_call.provenance {
    types.ParameterRoot(path) -> path
    _ -> field_call.object
  }
}

fn field_call_target(field_call: types.FieldCall) -> String {
  field_call_receiver(field_call) <> "." <> field_call.label
}

// How to describe a field call. A receiver with no source path (`make().f()`)
// carries the computed-receiver sentinel, which names nothing the user wrote,
// so the call describes its receiver as computed rather than by path.
fn field_call_kind(field_call: types.FieldCall) -> CallKind {
  let receiver = field_call_receiver(field_call)
  case receiver == extract.computed_receiver {
    True -> ComputedFieldCall(label: field_call.label)
    False -> FieldAccessCall(receiver:, label: field_call.label)
  }
}

// A bound whose effect is the single variable named after the param
// itself — `TVar(name)`. The variable refers to itself, resolved later by
// substitution at call sites. When the matching argument is an effect
// *operator* (a `TAbs`), binding `name` to it and beta-reducing is exactly
// what resolves a second-order call.
fn self_referential_bound(name: String) -> ParamBound {
  ParamBound(name, TVar(name))
}

// The sentinel name for a producer parameter (Fix D): the reserved
// `effect_term.sentinel_prefix` followed by the real name. A sentinel can never
// coincide with a residual leaked var read from source (the prefix is
// un-representable in a Gleam identifier), and the parser reserves the prefix so
// a forged `.graded` token can't mint one either.
fn sentinel_of(name: String) -> String {
  effect_term.sentinel_prefix <> name
}

// A producer parameter's bound whose *name* stays real (so a body call to the
// param still matches, and its operator shape still looks up) but whose *effect*
// is the sentinel var — so the summary distinguishes this param from any residual
// of the same name until rename-back.
fn sentinel_bound(name: String) -> ParamBound {
  ParamBound(name, TVar(sentinel_of(name)))
}

// A lexically-unique sentinel for a returned closure's callback binder. Keyed by
// the closure body's source position, so nested or shadowed callbacks that share
// a source name never share a sentinel. Carries the reserved `sentinel_prefix`,
// so it can never coincide with a variable read from source (and a leaked one
// grounds to [Unknown] rather than surviving). Distinct from `sentinel_of` (a
// producer parameter's sentinel), which the position infix keeps apart.
fn callback_binder_sentinel(start: Int, name: String) -> String {
  effect_term.sentinel_prefix <> int.to_string(start) <> "$" <> name
}

// True iff a term still carries unresolved (free) effect variables.
fn has_vars(term: EffectTerm) -> Bool {
  !effect_term.is_ground(term)
}

// Union the effect terms of a list of collected calls, normalizing once.
fn union_of(collected: List(CollectedCall)) -> EffectTerm {
  effect_term.normalize(TUnion(list.map(collected, collected_term)))
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

// A function's callback parameters, in declaration order.
//
// Detected from the glance signature — through the module's own type aliases,
// so `run: Action` with `type Action = fn() -> Nil` counts — and from girard's
// inferred one, which covers a parameter carrying no annotation at all. The
// alias leg is deterministic where girard's is best-effort, so a bound stays
// where girard declines the function.
//
// The one answer to "which of this function's parameters are callbacks" on the
// effects channel: every walk, every substitution and every lift over a
// producer reads it through `cached_callback_params`, so no two of them can
// abstract over different parameters. Two sites deliberately ask a different
// question and so derive their own: the declares-for-callers lift widens the
// set with the value channel's bound names, and the closure gate admits the
// registry's girard-free set.
fn callback_params(
  function: Function,
  alias_map: dict.Dict(String, glance.Type),
  girard_fn_typed: dict.Dict(String, Set(String)),
) -> List(String) {
  signatures.ordered_callback_params(
    function,
    alias_map,
    typeinfo.fn_typed_params(girard_fn_typed, function.name),
  )
}

// The function-typed parameters a set of declared bounds leaves unbound: the
// ones a walk resolves to an effect variable of their own name. A parameter the
// bounds already name is left to what was declared for it, which is the more
// specific claim.
fn unbound_fn_typed_params(
  definition: Definition(Function),
  declared: List(ParamBound),
  cache: LocalCache,
) -> Set(String) {
  let declared_names = effects.bound_name_set(declared)
  cached_callback_params(definition.definition, cache)
  |> set.from_list
  |> set.filter(fn(name) { !set.contains(declared_names, name) })
}

// The same set for a function of the module the cache was built over, read off
// the cache rather than recomputed: `build_scc_ids` derives it for every
// function to decide collapsibility, so every later reader is a lookup. In
// declaration order, which the lift path needs to abstract over them.
fn cached_callback_params(
  function: Function,
  cache: LocalCache,
) -> List(String) {
  case dict.get(cache.callback_params, function.name) {
    Ok(params) -> params
    // A function the cache was not built over — nothing keys it, so derive it
    // from the same two sources rather than reporting no callbacks.
    Error(Nil) ->
      callback_params(function, cache.fn_alias_types, cache.girard_fn_typed)
  }
}

// The bounds a body is walked under: what was declared for it, plus a
// self-referential bound for every function-typed parameter left over.
// `fn_typed_params` is `unbound_fn_typed_params` of the same `declared`,
// computed once by the caller, which always needs it separately too.
//
// One rule for every walk of a body — inference, a running fallback's summary,
// `check` and `why` — so no two of them can disagree about what one function
// does. A call to a function-typed parameter is what the argument does; without
// the bound it collapses to `[Unknown]`, which reports a parameter in plain
// sight as a name the module does not define and charges a caller passing a
// demonstrably pure callback for it.
fn effective_bounds(
  declared: List(ParamBound),
  fn_typed_params: Set(String),
) -> List(ParamBound) {
  list.append(declared, synthetic_fn_typed_bounds(fn_typed_params))
}

// Groom a term for publication outside its own walk. A free variable that is
// neither one of the function's fn-typed parameters nor a `recv.field`
// field-effect variable is a *phantom* — e.g. an inline closure's parameter
// that leaked out of an application graded couldn't fully resolve. It can
// never be bound, so it collapses to the conservative `[Unknown]` rather than
// surfacing an internal name. Field-effect variables survive and are returned
// beside the term: they round-trip as the identity bounds each publication
// pairs with them. One rule for every channel that states a term — the
// inferred spec line, a `why` block's total, a fallback summary — so no two of
// them can disagree about one function's effects.
fn groom_published_term(
  term: EffectTerm,
  fn_typed_params: Set(String),
) -> #(EffectTerm, Set(String)) {
  let field_vars = effect_term.free_vars(term) |> set.filter(is_field_path_var)
  #(
    collapse_phantom_vars(term, set.union(fn_typed_params, field_vars)),
    field_vars,
  )
}

// Build a `ParamBound` for each free effect variable in `term` whose name is
// a fn-typed parameter. Each is self-referential (`TVar(name)`), resolved by
// substitution at call sites — so the polymorphic signature round-trips.
fn polymorphic_param_bounds(
  term: EffectTerm,
  fn_typed_params: Set(String),
) -> List(ParamBound) {
  bounds_for_vars(effect_term.free_vars(term), fn_typed_params)
}

// The same, over a variable set gathered from more than one term.
fn bounds_for_vars(
  vars: Set(String),
  fn_typed_params: Set(String),
) -> List(ParamBound) {
  vars
  |> set.to_list()
  |> list.filter(fn(v) { set.contains(fn_typed_params, v) })
  |> list.sort(string.compare)
  |> list.map(self_referential_bound)
}

// Substitute every variable in `vars` with `[Unknown]` in `term`. The shared
// core of phantom collapse and field-variable concretization: both select a set
// of free variables that can never be bound here and ground them.
fn ground_vars(term: EffectTerm, vars: Set(String)) -> EffectTerm {
  use <- bool.guard(set.is_empty(vars), term)
  vars
  |> set.to_list()
  |> list.map(fn(v) { #(v, effect_term.unknown()) })
  |> dict.from_list()
  |> effect_term.subst(term, _)
}

// Replace every free effect variable in `term` that isn't one of `params` with
// [Unknown]. Such a variable is a phantom: it can never be bound at a call site
// (only the function's own fn-typed parameters can), so leaving it would surface
// an internal name in the effect set instead of the conservative fallback.
fn collapse_phantom_vars(term: EffectTerm, params: Set(String)) -> EffectTerm {
  ground_vars(term, set.difference(effect_term.free_vars(term), params))
}

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

// Module structure and memo state
//
// Per-module indexes threaded read-only through the analysis — the function
// map, the call-graph SCC structure that drives same-module memoization, and
// the memo tables — plus the alias/external classification that decides which
// components may collapse.

// Map a module's functions by name — for transitive same-module resolution.
fn build_function_map(
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
    // Module-local type aliases, raw name → aliased type. Lets the returns
    // machinery resolve an aliased return type (`fn make() -> Resolver` where
    // `type Resolver = fn(...)`) to its underlying function type and callback
    // positions.
    fn_alias_types: dict.Dict(String, glance.Type),
    // girard's fn-typed parameter names, function name → parameter names. A
    // parameter that infers to a function without carrying a `fn(...)`
    // annotation is recognised as effect-polymorphic wherever a walk reaches
    // it from inside the module, not only at the module's top level.
    girard_fn_typed: dict.Dict(String, Set(String)),
    // Each function's callback parameters, in declaration order — the two
    // sources above already unioned. Derived here because the collapse
    // decision below needs it for every function anyway, so every later
    // reader is a lookup rather than a second walk of the signature.
    callback_params: dict.Dict(String, List(String)),
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
// belong to every member.
pub fn build_scc_ids(
  module: Module,
  context: ImportContext,
  girard_fn_typed: dict.Dict(String, Set(String)),
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
  let fn_alias_types = signatures.type_alias_map(module.type_aliases)
  let callbacks =
    list.fold(definitions, dict.new(), fn(acc, definition) {
      dict.insert(
        acc,
        definition.definition.name,
        callback_params(definition.definition, fn_alias_types, girard_fn_typed),
      )
    })
  let needs_exact =
    list.filter_map(definitions, fn(definition) {
      let name = definition.definition.name
      let first_order = dict.get(callbacks, name) == Ok([])
      case
        first_order && !foreign_definition(definition, context.package_targets)
      {
        True -> Error(Nil)
        False -> Ok(name)
      }
    })
    |> set.from_list()
  topo.scc_order(local_call_graph(definitions, context))
  |> list.index_fold(
    LocalCache(
      dict.new(),
      dict.new(),
      set.new(),
      fn_alias_types,
      girard_fn_typed,
      callbacks,
    ),
    fn(cache, component, id) {
      let scc_id =
        list.fold(component, cache.scc_id, fn(ids, name) {
          dict.insert(ids, name, id)
        })
      let collapsible = case
        !list.any(component, fn(name) { set.contains(needs_exact, name) })
      {
        True -> set.insert(cache.collapsible, id)
        False -> cache.collapsible
      }
      LocalCache(
        scc_id:,
        members: dict.insert(cache.members, id, component),
        collapsible:,
        fn_alias_types: cache.fn_alias_types,
        girard_fn_typed: cache.girard_fn_typed,
        callback_params: cache.callback_params,
      )
    },
  )
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
// What one resolver established about a call: the effect term it produced, why
// that term is unresolved (`reason`), and which knowledge-base source answered
// (`origin`). Either may be absent — a term whose call kind already states the
// whole story records no reason, and a term no source keyed carries no origin.
type Resolution {
  Resolution(
    term: EffectTerm,
    reason: option.Option(UnknownReason),
    origin: option.Option(LookupOrigin),
    // Where the half a running Gleam fallback body contributed stands in
    // `term` — charged into it, or suppressed out of it by an `assume` line.
    // Carried beside the origin rather than folded into it: the declaration
    // and the body are two sources, and one must not be credited with the
    // other's effects.
    fallback: types.FallbackDisposition(EffectTerm),
  )
}

// A resolution whose deciding rule adds nothing to the call's own description.
fn plain_resolution(term: EffectTerm) -> Resolution {
  Resolution(term:, reason: None, origin: None, fallback: types.NoFallback)
}

// One call site collected from a function body: the call and what the resolver
// established about it.
//
// A resolution is a property of the callee's own body sites, not of the call
// site that reached them, so a memoized analysis carries it verbatim across
// every caller sharing its key — as the cached spans already do.
type CollectedCall {
  CollectedCall(call: ResolvedCall, resolution: Resolution)
}

// What the module under analysis defines for `function`, as the value channels
// read it: a Gleam body they may walk, an `@external` only a declaration speaks
// for, or no definition at all. The three are held apart because a declared
// return answers for the middle case and for neither of the others — collapsing
// them is how a plain miss would start consulting the knowledge base.
type LocalDefinition {
  NativeDefinition(definition: Definition(Function))
  ForeignDefinition
  NoLocalDefinition
}

fn local_definition(
  function_map: dict.Dict(String, Definition(Function)),
  function: String,
  package_targets: types.PackageTargets,
) -> LocalDefinition {
  case dict.get(function_map, function) {
    Error(Nil) -> NoLocalDefinition
    Ok(definition) ->
      case foreign_definition(definition, package_targets) {
        True -> ForeignDefinition
        False -> NativeDefinition(definition)
      }
  }
}

// A collected call whose kind states the whole story: the sentinel names what
// happened, so there is nothing to add.
fn plain_call(call: ResolvedCall, term: EffectTerm) -> CollectedCall {
  CollectedCall(call:, resolution: plain_resolution(term))
}

// The term a collected call contributes to its caller's effect.
fn collected_term(collected: CollectedCall) -> EffectTerm {
  collected.resolution.term
}

// A knowledge-base lookup as a resolution: the term, the source that answered
// a hit, and the reason a miss deserves. `if_unknown` is what a miss means to
// the call shape asking — the only part that differs between call sites.
fn lookup_parts(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
  if_unknown: UnknownReason,
) -> Resolution {
  // A call into foreign code is charged what declares that code, exactly as the
  // external's own line is: an entry inferred over a body the foreign
  // implementation needn't match answers for neither. A *dependency's*
  // `@external` is foreign for the same reason its own package's is, and the
  // knowledge base already records which of a dependency's functions are — so
  // an undeclared one reports as the external it is rather than as a name
  // nothing happened to key.
  use <- bool.lazy_guard(
    when: effects.is_foreign_function(knowledge_base, name)
      || effects.is_dependency_foreign_function(knowledge_base, name),
    return: fn() { foreign_resolution(knowledge_base, name) },
  )
  case effects.lookup(knowledge_base, name) {
    effects.Known(term, source) ->
      Resolution(
        term:,
        reason: None,
        origin: Some(effects.origin_of(source)),
        fallback: types.NoFallback,
      )
    effects.Unknown ->
      Resolution(
        term: effect_term.unknown(),
        reason: Some(if_unknown),
        origin: None,
        fallback: types.NoFallback,
      )
  }
}

// The resolution a call carries once call-site substitution has rewritten the
// source's term into `term`. An `Unknown` the source's own term does not state
// was put there by the substitution — an argument this call site passed that
// nothing resolves — so the call reports that argument instead of the source,
// which answered with a term that resolved.
fn substituted(looked_up: Resolution, term: EffectTerm) -> Resolution {
  use <- bool.guard(
    when: !carries_unknown(term) || states_unknown(looked_up.term),
    return: Resolution(..looked_up, term:),
  )
  Resolution(
    term:,
    reason: Some(UntraceableArgument),
    origin: None,
    fallback: types.NoFallback,
  )
}

// Replace a resolution's fallback share with the one the call-site bindings
// rewrote, where the resolution still reports one. `substituted`'s
// untraceable-argument branch drops the fallback along with the origin — the
// call reports the argument, not the source — and it stays dropped here.
fn with_substituted_fallback(
  resolution: Resolution,
  fallback: types.FallbackDisposition(EffectTerm),
) -> Resolution {
  case resolution.fallback {
    types.FallbackCharged(_) | types.FallbackSuppressed(_) ->
      Resolution(..resolution, fallback:)
    types.NoFallback -> resolution
  }
}

// Whether a fallback share carries variables the enclosing term does not. A
// charged share is a component of the term's union, so a term with no free
// variables has none hiding in that share either; a *suppressed* share is no
// part of the term, so its own variables are weighed apart — a polymorphic
// body beside a ground `assume` still has its overridden share substituted,
// and the quote of what was suppressed stays each call site's.
fn suppressed_share_vars(
  fallback: types.FallbackDisposition(EffectTerm),
) -> Bool {
  case fallback {
    types.FallbackSuppressed(term) -> has_vars(term)
    types.FallbackCharged(_) | types.NoFallback -> False
  }
}

// The same, for a collected call of a callee's body whose term this caller's
// bindings have rewritten, plus — for a term that resolved — the source of the
// wired value one of its field variables bound to.
fn rebound(
  collected: Resolution,
  term: EffectTerm,
  field_origins: dict.Dict(String, LookupOrigin),
) -> Resolution {
  let resolution = substituted(collected, term)
  use <- bool.guard(when: carries_unknown(term), return: resolution)
  Resolution(
    ..resolution,
    origin: option.or(
      resolution.origin,
      bound_field_origin(collected.term, field_origins),
    ),
  )
}

// Whether a term names the `Unknown` label itself, as opposed to grounding to
// it because a variable stayed free or an application stayed stuck.
fn states_unknown(term: EffectTerm) -> Bool {
  case term {
    types.TLabels(labels) -> set.contains(labels, types.unknown_label)
    TUnion(members) -> list.any(members, states_unknown)
    types.TAbs(_, body) -> states_unknown(body)
    types.TApp(function, argument) ->
      states_unknown(function) || states_unknown(argument)
    types.TTop | TVar(_) -> False
  }
}

type Memo {
  Memo(
    // Polymorphic same-module call analyses, keyed by callee + same-SCC
    // ancestors (see `memo_key`).
    locals: dict.Dict(#(String, List(String)), List(CollectedCall)),
    // Collapsible-SCC full-reachability analyses, keyed by SCC id.
    sccs: dict.Dict(Int, List(CollectedCall)),
    // Operator-lifts of same-module function references, keyed by name +
    // same-SCC ancestors.
    lifts: dict.Dict(#(String, List(String)), EffectTerm),
    // Closure analyses, keyed by body position, lifting positions, ambient
    // operator names, visited ancestors, and which ambient operators are
    // sentinel-seeded (Fix D) — so a sentinel-flavored analysis never collides
    // with a real-flavored one.
    closures: dict.Dict(
      #(Int, List(Int), List(String), List(String), List(String)),
      EffectTerm,
    ),
    // The targets every entry above was analysed on. Not part of any key —
    // which is why it has to be part of the table: a helper reached from a
    // `@target(erlang)` body and from a `@target(javascript)` one is one name
    // with two answers, and the keys name callees, positions and ancestors
    // alone. Sharing the table across the two let whichever ran first answer
    // for both.
    targets: Option(Set(String)),
  )
}

fn new_memo() -> Memo {
  Memo(
    locals: dict.new(),
    sccs: dict.new(),
    lifts: dict.new(),
    closures: dict.new(),
    targets: option.None,
  )
}

// The memo a body walked on `targets` may read: the one in hand where it was
// filled on those same targets, and an empty one otherwise. Emptied rather than
// keyed per target because a walk stays on one set start to finish, so the
// entries a change strands would not be read again anyway.
fn memo_on(memo: Memo, targets: Option(Set(String))) -> Memo {
  use <- bool.guard(when: memo.targets == targets, return: memo)
  Memo(..new_memo(), targets: targets)
}

// The base and the memo one definition's body is walked with: the base narrowed
// to the targets that body runs on, and a memo holding only what was analysed
// there.
fn body_walk(
  knowledge_base: KnowledgeBase,
  memo: Memo,
  definition: Definition(Function),
  package_targets: types.PackageTargets,
) -> #(KnowledgeBase, Memo) {
  let knowledge_base =
    body_knowledge_base(knowledge_base, definition, package_targets)
  #(knowledge_base, memo_on(memo, knowledge_base.active_targets))
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
  let result = extract.extract_function_calls(function, context)
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

// The module's functions whose implementation is foreign code, qualified by
// `module_path` and each paired with what a knowledge base records about it.
// What a knowledge base holds so that every consumer — a caller's resolution,
// `check`, `why`, `effect` — reads one of these names as only its declaration
// describes it. Whether the fallback body runs rides along, so a charge assembled
// before the walk reaches that body says so rather than reading the declaration
// as the whole story.
pub fn foreign_functions(
  module: Module,
  module_path: String,
  package_targets: types.PackageTargets,
) -> dict.Dict(QualifiedName, types.ForeignFunction) {
  module.functions
  |> list.filter(foreign_definition(_, package_targets))
  |> list.map(fn(definition) {
    let name =
      QualifiedName(module: module_path, function: definition.definition.name)
    #(
      name,
      types.ForeignFunction(
        runs_fallback_body: runs_fallback_body(definition, package_targets),
        compiled_targets: extract.compiled_targets(
          definition,
          types.declaration_targets(package_targets),
        ),
        declared_targets: extract.declared_targets(definition),
      ),
    )
  })
  |> dict.from_list()
}

// The same, for a module of a *dependency*: every `@external` it declares,
// including one the consumer's targets exclude.
//
// The consumer's own modules drop such a declaration, and rightly — no foreign
// implementation is compiled, so the Gleam body is the sole one and the function
// is ordinary Gleam whose body graded walks. A dependency's body is walked by a
// pass of its own, and this is what tells that pass which names have one.
// Dropping the entry left the name keyed by a shipped or catalogued declaration
// with nothing to say that declaration answers for a target this build does not
// compile, so `assume dep/ffi.run : [Disk]` over an `@external(javascript, …)`
// was charged in full to an Erlang-only consumer that reaches only the Gleam body
// underneath it. Kept, the lookup narrows the declaration out and charges what
// the body does instead — or the `[Unknown]` an unwalked body is worth, where
// nothing walked it.
pub fn dependency_foreign_functions(
  module: Module,
  module_path: String,
  package_targets: types.PackageTargets,
) -> dict.Dict(QualifiedName, types.ForeignFunction) {
  module.functions
  |> list.filter(extract.declares_external)
  |> list.map(fn(definition) {
    let name =
      QualifiedName(module: module_path, function: definition.definition.name)
    #(
      name,
      types.ForeignFunction(
        runs_fallback_body: has_running_fallback(definition, package_targets),
        compiled_targets: extract.compiled_targets(
          definition,
          types.declaration_targets(package_targets),
        ),
        declared_targets: extract.declared_targets(definition),
      ),
    )
  })
  |> dict.from_list()
}

// The module's functions whose body is what every caller runs: the ones it
// defines in Gleam rather than declares `@external`. What tells a per-function
// `assume` line that declares real foreign code from one that names a
// body sitting in plain sight.
pub fn native_function_names(
  module: Module,
  package_targets: types.PackageTargets,
) -> Set(String) {
  module.functions
  |> list.filter(fn(definition) {
    !foreign_definition(definition, package_targets)
  })
  |> list.map(fn(definition) { definition.definition.name })
  |> set.from_list()
}

// Every function the module defines, with whether the package exports it. What
// `graded effect` needs to tell a private name from one this package's source
// never defined — two cases a hand-written spec line reads the same way, and
// which a knowledge base keyed by function alone cannot separate. Held per
// module, because "absent here" means "this module defines no such function"
// only for a module that was parsed at all.
pub fn function_visibility(
  module: Module,
) -> dict.Dict(String, types.Visibility) {
  module.functions
  |> list.map(fn(definition) {
    let visibility = case definition.definition.publicity {
      glance.Public -> types.Exported
      glance.Private -> types.Internal
    }
    #(definition.definition.name, visibility)
  })
  |> dict.from_list()
}

// Whether a definition's implementation is foreign code: an `@external` the
// build compiles. Read on the targets a *declaration* is read on, the widest of
// the two — reclassifying an external as ordinary Gleam drops what it declares,
// and an assumption about the build may not do that.
fn foreign_definition(
  definition: Definition(Function),
  package_targets: types.PackageTargets,
) -> Bool {
  extract.is_foreign_definition(
    definition,
    types.declaration_targets(package_targets),
  )
}

// Whether an `@external`'s Gleam fallback body is code that runs: it has one,
// and some target the function is compiled for has no foreign implementation
// declared for it. That body is ordinary Gleam — nothing else checks it, since
// the declaration answers for every caller — so its effects are collected
// alongside the declaration rather than instead of it.
fn runs_fallback_body(
  definition: Definition(Function),
  package_targets: types.PackageTargets,
) -> Bool {
  use <- bool.guard(
    when: !foreign_definition(definition, package_targets),
    return: False,
  )
  has_running_fallback(definition, package_targets)
}

// Whether a definition carries a Gleam body that some target it is compiled for
// reaches. The same question `runs_fallback_body` answers, minus the
// this-package classification in front of it — a dependency's declaration the
// consumer's targets exclude is not foreign code *to the consumer*, and its body
// still runs where that declaration does not reach.
//
// Read on the targets the build compiles, the narrower of the two: this decision
// only ever *adds* a body's effects to what a declaration already states, so
// where the package names no target the compiler's default stands in and an
// `@external(erlang, …)` beside a Gleam body is answered by its declaration
// alone. The same reading the knowledge base charges callers by, so the
// function's own budget covers what every caller pays and nothing more.
fn has_running_fallback(
  definition: Definition(Function),
  package_targets: types.PackageTargets,
) -> Bool {
  use <- bool.guard(when: definition.definition.body == [], return: False)
  body_targets(definition, types.build_targets(package_targets))
  |> set.is_empty
  |> bool.negate
}

// The knowledge base a definition's own body is walked against, narrowed to the
// targets that body runs on.
//
// Asked of every definition, because `@target` restricts an ordinary function
// exactly as it restricts an `@external`: a `@target(erlang)` function's body is
// reached from Erlang and nowhere else, so a JavaScript-only external it calls
// answers with its Gleam fallback there, not with what its declaration says the
// foreign implementation does. Restricting only fallback bodies charged such a
// caller an effect no build of it can perform.
fn body_knowledge_base(
  knowledge_base: KnowledgeBase,
  definition: Definition(Function),
  package_targets: types.PackageTargets,
) -> KnowledgeBase {
  effects.with_active_targets(
    knowledge_base,
    option.Some(body_targets(
      definition,
      types.declaration_targets(package_targets),
    )),
  )
}

// The targets a definition's body runs on, out of the `targets` its package is
// read on: the ones it is compiled for, less those its own `@external`
// attributes hand to foreign code. What the body is walked *as* — a call it
// makes is reached from these targets and no others, so this is the set every
// name it resolves has to be read on.
//
// For an ordinary function the subtraction removes nothing and the answer is
// simply what it is compiled for; for an `@external` with a Gleam body it is
// where that fallback runs.
fn body_targets(
  definition: Definition(Function),
  targets: Set(String),
) -> Set(String) {
  set.difference(
    extract.compiled_targets(definition, targets),
    extract.declared_targets(definition),
  )
}

// Annotation checking
//
// Check one `check` annotation against its function: subset-check every
// collected effect against the declared budget, and warn about untracked
// references and dead parameter/field bounds.

fn check_annotation(
  annotation: EffectAnnotation,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(#(List(Violation), List(CheckFinding), List(Warning)), Memo) {
  case dict.get(function_map, annotation.function) {
    // Silently skip: the annotation may be stale or apply to a different
    // build target. Missing functions are not an error.
    Error(Nil) -> #(#([], [], []), memo)
    Ok(function_definition) -> {
      let fn_typed_params =
        unbound_fn_typed_params(function_definition, annotation.params, cache)
      // The same contributors `why` explains — including the declaration that
      // stands in for an `@external`'s absent body, so a `check` line
      // contradicting a declaration is a violation, as is one over an external
      // nothing declares.
      let #(contribution, memo) =
        contributors(
          function_definition,
          annotation.params,
          fn_typed_params,
          function_map,
          context,
          knowledge_base,
          registry,
          module_types,
          cache,
          memo,
        )
      // A call is a violation when its effect set is not a subset of the
      // declared budget — i.e. it performs effects the caller didn't allow.
      // Both sides are reduced to their ground normal form first.
      let declared = effect_term.to_effect_set(annotation.effects)
      let violations =
        contribution.explanations
        |> list.filter_map(fn(explanation) {
          case
            types.is_subset(
              weighed_actual(explanation.actual, fn_typed_params),
              declared,
            )
          {
            True -> Error(Nil)
            False ->
              Ok(Violation(
                function: annotation.function,
                declared:,
                explanation:,
              ))
          }
        })

      // Warn about function references passed as values with known non-pure
      // effects. A reference sits in the Gleam body, so the warning turns on
      // whether that body is code that runs: an `@external` covering every
      // compiled target keeps its body as dead text, and nothing it references
      // is ever passed anywhere.
      let extract_result =
        extract.extract_function_calls(function_definition.definition, context)
      let reference_warnings = case contribution.body {
        BodyIsDeadText -> []
        BodyWalked ->
          collect_reference_warnings(
            annotation.function,
            extract_result.references,
            // Read on the targets the body passing the reference runs on, like
            // every other name that body reaches: a reference whose effects
            // belong to an implementation this build never compiles is not one
            // the caller is failing to track.
            body_knowledge_base(
              knowledge_base,
              function_definition,
              context.package_targets,
            ),
          )
      }

      let param_names =
        function_definition.definition.parameters
        |> list.filter_map(fn(param) {
          case param.name {
            glance.Named(name) -> Ok(name)
            glance.Discarded(_) -> Error(Nil)
          }
        })
        |> set.from_list()

      // Warn about field bounds whose `recv.field` path matches no field call in
      // the body — a dead bound. When the receiver is a parameter it can't be
      // traced to a construction site, so a missing field call is a genuine typo.
      // When it isn't, the field call may exist but have resolved through value
      // provenance, shadowing the bound; the warning says so rather than blaming
      // the path. (Provenance only traces let-bound constructions, never a
      // parameter, so the parameter case is never a false provenance report.)
      let field_call_targets =
        extract_result.field
        |> list.map(field_call_target)
        |> set.from_list()
      let unmatched_field_bound_warnings =
        annotation.params
        |> list.filter(fn(bound) { string.contains(bound.name, ".") })
        |> list.filter(fn(bound) {
          !set.contains(field_call_targets, bound.name)
        })
        |> list.map(fn(bound) {
          let receiver = case string.split_once(bound.name, ".") {
            Ok(#(receiver, _)) -> receiver
            Error(Nil) -> bound.name
          }
          UnmatchedFieldBoundWarning(
            function: annotation.function,
            field_path: bound.name,
            receiver_is_param: set.contains(param_names, receiver),
          )
        })

      // Warn about plain parameter bounds whose name matches no declared
      // parameter — a typo. Checked on parameter *existence*, not call presence:
      // a callback that's forwarded but never called directly is still a real
      // parameter, so its bound stays load-bearing during substitution and isn't
      // flagged. Only a name that is no parameter at all is dead.
      let unmatched_param_bound_warnings =
        annotation.params
        |> list.filter(fn(bound) { !string.contains(bound.name, ".") })
        |> list.filter(fn(bound) { !set.contains(param_names, bound.name) })
        |> list.map(fn(bound) {
          UnmatchedParamBoundWarning(
            function: annotation.function,
            param: bound.name,
          )
        })

      let warnings =
        reference_warnings
        |> list.append(unmatched_field_bound_warnings)
        |> list.append(unmatched_param_bound_warnings)

      let #(findings, memo) =
        check_returns_clause(
          annotation,
          function_definition,
          function_map,
          context,
          knowledge_base,
          registry,
          module_types,
          cache,
          memo,
        )

      #(#(violations, findings, warnings), memo)
    }
  }
}

// Construction-site resolution
//
// What one site wires into a checked field, as something to weigh — or as the
// limit that stopped it resolving. `value_field_effect` answers a conservative
// `[Unknown]` for a value it cannot follow, which a budget reads as an effect
// the site performs; a `check` has to tell that apart from a value carrying no
// function at all, so the untraceable shapes are refused here instead.

// One field `check` line, resolved to the type it names. The type's defining
// module is where the check is keyed; its construction sites are anywhere.
pub type FieldCheck {
  FieldCheck(
    path: String,
    module: String,
    type_name: String,
    field: String,
    declared: EffectTerm,
  )
}

// What one module's construction sites prove about the package's field
// `check` lines.
pub type FieldSiteReport {
  FieldSiteReport(
    findings: List(CheckFinding),
    // Templates in this module that wire a checked field from one of their own
    // parameters. What such a site wires is decided by the template's callers,
    // so one no visible call reaches proves nothing.
    templates: List(FieldTemplate),
    // The templates this module's calls reached, by qualified name.
    called: Set(String),
    // The `check` paths at least one site in this module answered to. A check
    // no site anywhere in the package answers holds vacuously.
    touched: Set(String),
  )
}

// A factory or update builder that wires a checked field from a parameter,
// held until the package-wide pass knows whether anything calls it.
pub type FieldTemplate {
  FieldTemplate(
    function: String,
    check_path: String,
    site: types.ConstructionSite,
  )
}

// Weigh every construction site one module holds against the field `check`
// lines they touch. The checks are the package's, because a type's sites are
// wherever the package builds it; the findings are this module's, because that
// is the file they are reported against.
pub fn check_field_sites(
  module: Module,
  module_path: String,
  checks: List(FieldCheck),
  field_index: types.FieldIndex,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  girard_fn_typed: dict.Dict(String, Set(String)),
  package_targets: types.PackageTargets,
) -> FieldSiteReport {
  let function_map = build_function_map(module)
  let ModuleContext(context:, cache:) =
    module_context(
      module,
      module_path,
      knowledge_base,
      girard_fn_typed,
      package_targets,
    )
  let module_functions = set.from_list(dict.keys(function_map))
  let #(report, _memo) =
    list.fold(
      module.functions,
      #(empty_site_report(), new_memo()),
      fn(state: #(FieldSiteReport, Memo), definition) {
        let #(report, memo) = state
        let #(next, memo) =
          function_field_sites(
            definition.definition,
            module_path,
            checks,
            field_index,
            module_functions,
            context,
            knowledge_base,
            function_map,
            registry,
            module_types,
            cache,
            memo,
          )
        #(merge_site_reports(report, next), memo)
      },
    )
  report
}

// One function body's sites: the values it wires directly, and the values its
// calls to templates wire through them.
fn function_field_sites(
  function: Function,
  module_path: String,
  checks: List(FieldCheck),
  field_index: types.FieldIndex,
  module_functions: Set(String),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  function_map: dict.Dict(String, Definition(Function)),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(FieldSiteReport, Memo) {
  let extracted = extract.extract_function_calls(function, context)
  let parameters = named_function_params(function)
  let weigh = fn(state: #(FieldSiteReport, Memo), wired: WiredField) {
    let #(report, memo) = state
    let #(findings, templates, memo) =
      weigh_wired_field(
        wired,
        types.dotted_name(QualifiedName(module_path, function.name)),
        parameters,
        module_functions,
        context,
        knowledge_base,
        function_map,
        registry,
        module_types,
        cache,
        memo,
      )
    #(
      merge_site_reports(
        report,
        FieldSiteReport(
          findings:,
          templates:,
          called: case wired.through {
            Some(callee) -> set.from_list([callee])
            None -> set.new()
          },
          touched: set.from_list([wired.check.path]),
        ),
      ),
      memo,
    )
  }
  list.fold(
    list.append(
      constructed_fields(extracted, function.name, checks, field_index),
      template_fields(
        extracted,
        function.name,
        checks,
        field_index,
        context,
        module_path,
      ),
    ),
    #(empty_site_report(), memo),
    weigh,
  )
}

fn empty_site_report() -> FieldSiteReport {
  FieldSiteReport(
    findings: [],
    templates: [],
    called: set.new(),
    touched: set.new(),
  )
}

fn merge_site_reports(
  left: FieldSiteReport,
  right: FieldSiteReport,
) -> FieldSiteReport {
  FieldSiteReport(
    findings: list.append(left.findings, right.findings),
    templates: list.append(left.templates, right.templates),
    called: set.union(left.called, right.called),
    touched: set.union(left.touched, right.touched),
  )
}

// One checked field at one site, with everything the verdict needs.
type WiredField {
  WiredField(
    check: FieldCheck,
    signature: types.CallableFieldSignature,
    value: types.ArgumentValue,
    site: types.ConstructionSite,
    // The template this value came through, `None` for a direct construction.
    // A value wired from a parameter of the enclosing function is the
    // template's own business, not the construction's.
    through: Option(String),
  )
}

// Every checked field a body's direct constructions wire.
fn constructed_fields(
  extracted: extract.ExtractResult,
  enclosing: String,
  checks: List(FieldCheck),
  field_index: types.FieldIndex,
) -> List(WiredField) {
  use construction <- list.flat_map(extracted.constructions)
  use #(check, signature, site) <- list.flat_map(matching_checks(
    construction.constructor,
    checks,
    field_index,
    enclosing,
  ))
  case dict.get(construction.fields, check.field) {
    Ok(value) -> [WiredField(check:, signature:, value:, site:, through: None)]
    Error(Nil) -> []
  }
}

// Every checked field a body's calls to factory or update templates wire.
// A template names what it builds, so the site is attributed by the identity
// recorded on the template rather than inferred at the call.
fn template_fields(
  extracted: extract.ExtractResult,
  enclosing: String,
  checks: List(FieldCheck),
  field_index: types.FieldIndex,
  context: ImportContext,
  module_path: String,
) -> List(WiredField) {
  use call <- list.flat_map(template_calls(extracted, context, module_path))
  use #(check, signature, site) <- list.flat_map(matching_checks(
    call.constructor,
    checks,
    field_index,
    enclosing,
  ))
  case dict.get(call.fields, check.field) {
    Error(Nil) -> []
    Ok(position) ->
      case template_argument(call.arguments, position, call.param_labels) {
        Some(value) -> [
          WiredField(
            check:,
            signature:,
            value:,
            site:,
            through: Some(call.callee),
          ),
        ]
        None -> []
      }
  }
}

// The checks one constructor's sites answer to, each with the callable
// signature of the variant actually built. A label callable in some variants
// and not this one is not this check's business.
fn matching_checks(
  built: types.BuiltConstructor,
  checks: List(FieldCheck),
  field_index: types.FieldIndex,
  enclosing: String,
) -> List(#(FieldCheck, types.CallableFieldSignature, types.ConstructionSite)) {
  case dict.get(field_index.variant_types, #(built.module, built.variant)) {
    Error(Nil) -> []
    Ok(type_name) -> {
      let site =
        types.ConstructionSite(
          function: enclosing,
          constructor: types.ConstructorIdentity(
            module: built.module,
            type_name:,
            variant: built.variant,
          ),
        )
      use check <- list.filter_map(checks)
      use <- bool.guard(
        when: check.module != built.module || check.type_name != type_name,
        return: Error(Nil),
      )
      dict.get(field_index.callable, #(
        built.module,
        type_name,
        built.variant,
        check.field,
      ))
      |> result.map(fn(signature) { #(check, signature, site) })
    }
  }
}

// One site's verdict: a value wired from a parameter of the enclosing function
// belongs to that function's own callers, and everything else is resolved and
// weighed here.
fn weigh_wired_field(
  wired: WiredField,
  enclosing: String,
  parameters: Set(String),
  module_functions: Set(String),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  function_map: dict.Dict(String, Definition(Function)),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(List(CheckFinding), List(FieldTemplate), Memo) {
  // The enclosing function threads its own argument into the field, so what it
  // wires is whatever its callers pass. Held until the package-wide pass knows
  // whether any call reaches it.
  let from_parameter = case wired.value, wired.through {
    types.LocalRef(name:), None ->
      set.contains(parameters, name) && !set.contains(module_functions, name)
    types.LocalRef(..), Some(_)
    | types.FunctionRef(..), _
    | types.Closure(..), _
    | types.ReturnedOperator(..), _
    | types.CallResult(..), _
    | types.ConstructorRef, _
    | types.Choice(..), _
    | types.ReceiverPath(..), _
    | types.Constructed(..), _
    | types.Updated(..), _
    | types.OtherExpression, _
    -> False
  }
  case from_parameter {
    True -> #(
      [],
      [
        FieldTemplate(
          function: enclosing,
          check_path: wired.check.path,
          site: wired.site,
        ),
      ],
      memo,
    )
    False -> {
      let #(findings, memo) =
        resolved_verdict(
          wired,
          module_functions,
          context,
          knowledge_base,
          function_map,
          registry,
          module_types,
          cache,
          memo,
        )
      #(findings, [], memo)
    }
  }
}

fn resolved_verdict(
  wired: WiredField,
  module_functions: Set(String),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  function_map: dict.Dict(String, Definition(Function)),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(List(CheckFinding), Memo) {
  let #(resolved, memo) =
    resolve_site_value(
      wired.value,
      module_functions,
      context,
      knowledge_base,
      function_map,
      registry,
      module_types,
      cache,
      memo,
    )
  let findings = case resolved {
    Error(cause) -> [
      UnprovedCheck(subject: wired.check.path, cause:, site: Some(wired.site)),
    ]
    Ok(effect) ->
      case
        field_site_comparison(
          effect.effects,
          bound_positions(
            effect.bounds,
            effect.source,
            wired.signature,
            registry,
          ),
          wired.check.declared,
          wired.signature,
        )
      {
        FieldWithinBudget -> []
        FieldOverBudget(actual:) -> [
          FieldSiteViolation(
            field_path: wired.check.path,
            declared: wired.check.declared,
            actual:,
            site: wired.site,
          ),
        ]
        DeclaredArityMismatch(arity:) -> [
          FieldArityViolation(
            field_path: wired.check.path,
            declared: wired.check.declared,
            arity:,
            site: wired.site,
          ),
        ]
      }
  }
  #(findings, memo)
}

// What one template builds and how its call's arguments reach the fields,
// normalized over the two template kinds so one reader serves both.
type Template {
  Template(
    constructor: types.BuiltConstructor,
    fields: dict.Dict(String, Int),
    param_labels: dict.Dict(String, Int),
  )
}

// A template call the walked body makes.
type TemplateCall {
  TemplateCall(
    callee: String,
    constructor: types.BuiltConstructor,
    fields: dict.Dict(String, Int),
    param_labels: dict.Dict(String, Int),
    arguments: List(types.CallArgument),
    span: Span,
  )
}

fn template_calls(
  extracted: extract.ExtractResult,
  context: ImportContext,
  module_path: String,
) -> List(TemplateCall) {
  let resolved =
    list.flat_map(extracted.resolved, fn(call) {
      template_call_of(
        types.dotted_name(call.name),
        template_of(
          dict.get(context.cross_factories, #(
            call.name.module,
            call.name.function,
          )),
          dict.get(context.cross_updates, #(
            call.name.module,
            call.name.function,
          )),
        ),
        call.span,
        extracted,
      )
    })
  let local =
    list.flat_map(extracted.local, fn(call) {
      template_call_of(
        types.dotted_name(QualifiedName(module_path, call.function)),
        // Only a name the module's own definitions answer for can name a
        // template. A parameter or local shadowing a sibling factory is a call
        // to that binding, and matching it by name attributed the binding's
        // arguments to a factory the body never calls -- the same precedence
        // the effects channel reads an unqualified call by.
        case call.scope {
          types.LexicalBinding -> None
          types.ModuleDefinition ->
            template_of(
              dict.get(context.factories, call.function),
              dict.get(context.updates, call.function),
            )
        },
        call.span,
        extracted,
      )
    })
  list.append(resolved, local)
}

// What a factory or an update builder wires, read off whichever of the two
// keys the callee. A factory wins where a name somehow keys both.
fn template_of(
  factory: Result(types.FactorySignature, Nil),
  update: Result(types.UpdateSignature, Nil),
) -> Option(Template) {
  case factory, update {
    Ok(factory), _ ->
      Some(Template(
        constructor: factory.constructor,
        fields: factory.fields,
        param_labels: factory.param_labels,
      ))
    Error(Nil), Ok(update) ->
      Some(Template(
        constructor: update.constructor,
        fields: update.fields,
        param_labels: update.param_labels,
      ))
    Error(Nil), Error(Nil) -> None
  }
}

fn template_call_of(
  callee: String,
  template: Option(Template),
  span: Span,
  extracted: extract.ExtractResult,
) -> List(TemplateCall) {
  case template {
    None -> []
    Some(template) -> [
      TemplateCall(
        callee:,
        constructor: template.constructor,
        fields: template.fields,
        param_labels: template.param_labels,
        arguments: dict.get(extracted.call_args, #(span.start, span.end))
          |> result.unwrap([]),
        span:,
      ),
    ]
  }
}

// The argument a template's field is wired from: matched by the parameter's
// label where the call used one, else by position — the same helpers a
// parameter bound's argument is bound by.
fn template_argument(
  arguments: List(types.CallArgument),
  position: Int,
  param_labels: dict.Dict(String, Int),
) -> Option(types.ArgumentValue) {
  let by_label = case
    param_labels |> dict.to_list() |> list.find(fn(pair) { pair.1 == position })
  {
    Ok(#(label, _)) -> find_arg_by_label(arguments, label)
    Error(Nil) -> None
  }
  by_label
  |> option.lazy_or(fn() { find_arg_at_position(arguments, position) })
  |> option.map(fn(argument) { argument.value })
}

// Resolve one construction site's wired value. `Error` names an analysis limit
// and never a defect at the site.
fn resolve_site_value(
  value: types.ArgumentValue,
  module_functions: Set(String),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  function_map: dict.Dict(String, Definition(Function)),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(Result(types.TypeFieldEffect, UnprovedCause), Memo) {
  use <- bool.guard(
    when: !traceable_field_value(value, module_functions),
    return: #(Error(UntracedFieldValue), memo),
  )
  let #(effect, _origin, memo) =
    value_field_effect(
      value,
      module_functions,
      context,
      knowledge_base,
      function_map,
      set.new(),
      registry,
      module_types,
      cache,
      memo,
    )
  #(Ok(effect), memo)
}

// Whether a wired value names something a proof can follow: a function, an
// inline closure, or a call whose result is one. A bare local that is not a
// module function is a parameter or an opaque binding — the polymorphic self
// marker stands for it, which is a placeholder rather than an effect — and a
// record, a branch, a receiver path or a computed expression carries no
// function at all.
fn traceable_field_value(
  value: types.ArgumentValue,
  module_functions: Set(String),
) -> Bool {
  case value {
    types.FunctionRef(..)
    | types.Closure(..)
    | types.ReturnedOperator(..)
    | types.CallResult(..) -> True
    types.LocalRef(name:) -> set.contains(module_functions, name)
    types.ConstructorRef
    | types.Choice(..)
    | types.ReceiverPath(..)
    | types.Constructed(..)
    | types.Updated(..)
    | types.OtherExpression -> False
  }
}

// Construction-site comparison
//
// What a field `check` weighs one construction site against. Both sides are
// canonicalized to `λp₀ … λpₙ₋₁. body` at the field's own arity first, because
// the wired value arrives in three different shapes — an inline closure is
// already abstracted, a named concrete function is ground, a named polymorphic
// one is a free term beside its bounds — and comparing shapes rather than
// budgets would report correct code for two of them.
//
// The arity comes from the field's signature, never from either term: measuring
// a term against itself proves nothing.

// The verdict on one wired value.
pub type FieldComparison {
  FieldWithinBudget
  // `actual` is the canonicalized, grounded term, so the diagnostic quotes
  // what was actually weighed.
  FieldOverBudget(actual: EffectTerm)
  // The author declared an operator of a different arity than the field the
  // site builds. Their error, not a site's.
  DeclaredArityMismatch(arity: Int)
}

// Where each of a wired function's bounds sits in its own parameter list.
//
// A bound list names the parameters it constrains and skips the rest, so it is
// sparse: `f(cb: [cb])` on `fn(Int, fn() -> Nil)` is one bound for parameter
// one. Read as arity-aligned it bound that budget to parameter zero, and the
// callback the declaration constrains grounded as if nothing constrained it.
//
// The wired function's recorded signature places a bound by the name it is
// written under. Where no signature records it — a wired name graded parsed no
// source for — the bounds fall on the field's own callback positions in order:
// the value has the field's type, so its function-typed parameters are exactly
// those.
fn bound_positions(
  bounds: List(ParamBound),
  source: Option(QualifiedName),
  signature: types.CallableFieldSignature,
  registry: SignatureRegistry,
) -> dict.Dict(Int, ParamBound) {
  let parameters =
    source
    |> option.map(signatures.lookup(registry, _))
    |> option.flatten
  case parameters {
    Some(parameters) ->
      list.fold(bounds, dict.new(), fn(acc, bound) {
        case parameter_position(parameters, bound.name) {
          Some(position) -> dict.insert(acc, position, bound)
          None -> acc
        }
      })
    None ->
      list.zip(
        list.map(signature.callbacks, fn(callback) { callback.0 }),
        bounds,
      )
      |> dict.from_list()
  }
}

// The position a parameter of this name occupies, matched by either the label a
// caller writes or the name the body reads — the two spellings a bound is
// written under.
fn parameter_position(
  parameters: List(signatures.ParameterInfo),
  name: String,
) -> Option(Int) {
  parameters
  |> list.find(fn(parameter) {
    parameter.label == Some(name) || parameter.name == Some(name)
  })
  |> option.from_result
  |> option.map(fn(parameter) { parameter.position })
}

// Weigh one wired value against a field's declared budget. `bounds` are the
// wired function's own parameter bounds at the positions they constrain, which
// name the variables the symbolic lift binds; they are empty for a ground value
// or an inline closure.
pub fn field_site_comparison(
  actual: EffectTerm,
  bounds: dict.Dict(Int, ParamBound),
  declared: EffectTerm,
  signature: types.CallableFieldSignature,
) -> FieldComparison {
  case canonical_declared(declared, signature.arity) {
    Error(Nil) -> DeclaredArityMismatch(arity: signature.arity)
    Ok(declared_operator) -> {
      let grounded =
        canonical_actual(actual, bounds, signature.arity)
        |> ground_unconstrained(declared_operator, signature)
      case effect_term.operator_subset(grounded, declared_operator) {
        True -> FieldWithinBudget
        False -> FieldOverBudget(actual: grounded)
      }
    }
  }
}

// The declared side at the field's arity: a ground budget is the constant
// operator at that arity — well-defined however many arguments the field takes,
// which is what lets one line cover a heterogeneous type — while a declared
// operator has one fixed arity and disagreeing with the field's is an error.
fn canonical_declared(
  declared: EffectTerm,
  arity: Int,
) -> Result(EffectTerm, Nil) {
  case declared {
    types.TAbs(_, _) -> {
      let #(binders, _body) = peel_abstractions(declared, [])
      case list.length(binders) == arity {
        True -> Ok(declared)
        False -> Error(Nil)
      }
    }
    types.TLabels(_)
    | types.TTop
    | types.TVar(_)
    | types.TApp(_, _)
    | TUnion(_) -> Ok(constant_operator(arity, declared, "_"))
  }
}

// The actual side at the field's arity. An inline closure already arrives
// abstracted over its parameters; a ground term lifts to the constant operator
// exactly as a ground declared budget does; a polymorphic one is lifted
// *symbolically*, since a construction site has no field-call arguments to
// bind its variables with.
fn canonical_actual(
  actual: EffectTerm,
  bounds: dict.Dict(Int, ParamBound),
  arity: Int,
) -> EffectTerm {
  case actual {
    types.TAbs(_, _) -> actual
    types.TLabels(_)
    | types.TTop
    | types.TVar(_)
    | types.TApp(_, _)
    | TUnion(_) ->
      case effect_term.is_ground(actual) {
        True -> constant_operator(arity, actual, "_")
        False -> symbolic_lift(actual, bounds, arity)
      }
  }
}

// Lift a polymorphic field effect to `λc₀ … λcₙ₋₁. term[payload_var(i) := cᵢ]`.
//
// A bound's *name* identifies the argument while the free variables of its
// *payload* are what bind to that argument's effects, so the substitution keys
// come from the payload — `cb: [e]` binds `e`, not `cb`. A binder standing in
// an operator position stays a bare higher-kinded variable, still applied;
// eta-expanding it here would collapse the distinction the grounding step
// below depends on.
fn symbolic_lift(
  term: EffectTerm,
  bounds: dict.Dict(Int, ParamBound),
  arity: Int,
) -> EffectTerm {
  let taken = effect_term.free_vars(term)
  let #(binders, bindings) =
    positions_up_to(arity)
    |> list.fold(#([], dict.new()), fn(state, position) {
      let #(names, acc) = state
      let bound = dict.get(bounds, position) |> option.from_result
      let binder =
        effect_term.fresh(
          case bound {
            Some(bound) -> bound.name
            None -> "p" <> int.to_string(position)
          },
          set.union(taken, set.from_list(names)),
        )
      let payload = case bound {
        Some(bound) -> effect_term.free_vars(bound.effects)
        None -> set.new()
      }
      #(
        [binder, ..names],
        set.fold(payload, acc, fn(acc, variable) {
          dict.insert(acc, variable, TVar(binder))
        }),
      )
    })
  wrap_binders(list.reverse(binders), effect_term.subst(term, bindings))
}

// Ground the binders the author's declaration does not constrain.
//
// Synthesized-ness is a property of what the author wrote — a position whose
// binder the declared body never mentions, which is every position of a ground
// budget. It is read off the declared side, never off whatever the lift
// happened to build.
//
// The substitution goes into the *body*, with the spine peeled, because a
// binding shadowed by the binder it is descending under is deliberately
// dropped: substituting into the whole operator would leave it untouched.
//
// An operator-valued binder is replaced by a constant `[Unknown]` operator at
// that binder's own callback arity, not by `[Unknown]` itself: a ground term in
// operator position leaves the application stuck, and a stuck application never
// matches a ground budget.
fn ground_unconstrained(
  actual: EffectTerm,
  declared: EffectTerm,
  signature: types.CallableFieldSignature,
) -> EffectTerm {
  let #(declared_binders, declared_body) = peel_abstractions(declared, [])
  let declared_free = effect_term.free_vars(declared_body)
  let #(actual_binders, actual_body) = peel_abstractions(actual, [])
  let bindings =
    list.index_fold(declared_binders, dict.new(), fn(acc, binder, position) {
      case set.contains(declared_free, binder) {
        True -> acc
        False ->
          case extract.at(actual_binders, position) {
            Ok(name) ->
              dict.insert(
                acc,
                name,
                unconstrained_stand_in(signature, position),
              )
            Error(Nil) -> acc
          }
      }
    })
  wrap_binders(actual_binders, effect_term.subst(actual_body, bindings))
}

// What an unconstrained binder at one position stands for: `[Unknown]` for a
// flat one, and for an operator-valued one the constant `[Unknown]` operator
// curried once per *inner* callback position — the number of effect arguments
// the callee applies it to, which is not its source arity.
fn unconstrained_stand_in(
  signature: types.CallableFieldSignature,
  position: Int,
) -> EffectTerm {
  case list.key_find(signature.callbacks, position) {
    Ok(inner) ->
      constant_operator(list.length(inner), effect_term.unknown(), "_")
    Error(Nil) -> effect_term.unknown()
  }
}

// A term wrapped in `count` binders that the body never mentions. One name
// serves every binder: none of them occurs in the body, so the inner ones
// shadow nothing, and repeating it keeps the rendered operator readable.
fn constant_operator(count: Int, body: EffectTerm, base: String) -> EffectTerm {
  let name = effect_term.fresh(base, effect_term.free_vars(body))
  wrap_binders(list.map(positions_up_to(count), fn(_position) { name }), body)
}

fn wrap_binders(names: List(String), body: EffectTerm) -> EffectTerm {
  list.fold_right(names, body, fn(acc, name) { types.TAbs(name, acc) })
}

// Returned-operator checking
//
// Verify a `check` line's `where returns` clause against the operator the
// function actually hands back. The comparison is a subset in the same
// direction as the effects half — declared ⊇ computed — so one line means one
// thing in both of its channels.

fn check_returns_clause(
  annotation: EffectAnnotation,
  function_definition: Definition(Function),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(List(CheckFinding), Memo) {
  case annotation.returns {
    None -> #([], memo)
    Some(declared) ->
      case foreign_definition(function_definition, context.package_targets) {
        // Only the foreign implementation decides what a foreign name returns,
        // so the value channel says nothing about one and a declaration is what
        // answers.
        True ->
          foreign_returns_clause(
            annotation,
            declared,
            function_definition,
            function_map,
            context,
            knowledge_base,
            registry,
            module_types,
            cache,
            memo,
          )
        False -> {
          // The operator a producer hands back is what its own body builds, so
          // it is computed on the targets that body runs on — the same
          // narrowing the summary walk performs before deriving the clause
          // `graded infer` writes. Reading the names it calls package-wide here
          // charges the clause a declaration this body never reaches, and the
          // written clause fails its own check.
          let #(knowledge_base, memo) =
            body_walk(
              knowledge_base,
              memo,
              function_definition,
              context.package_targets,
            )
          let #(computed, memo) =
            compute_returned_operator(
              function_definition.definition,
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
            weigh_returned_operator(annotation.function, declared, computed),
            memo,
          )
        }
      }
  }
}

// One computed operator against one declared clause. A derivation that failed
// is a violation only where it proves the function returns no function at all;
// the other two causes leave the question open, which is an analysis limit and
// reads as one.
fn weigh_returned_operator(
  function: String,
  declared: EffectTerm,
  computed: Result(EffectTerm, ReturnedOperatorReason),
) -> List(CheckFinding) {
  case computed {
    Ok(operator) ->
      case effect_term.operator_subset(operator, declared) {
        True -> []
        False -> [
          ReturnsClauseViolation(function:, declared:, computed: operator),
        ]
      }
    Error(ReturnIsNotAFunction) -> [
      NonCallableReturnViolation(function:, declared:),
    ]
    Error(NoReturnAnnotation) -> [
      unproved_clause(function, NoReturnAnnotation),
    ]
    Error(UnresolvedReturnTail) -> [
      unproved_clause(function, UnresolvedReturnTail),
    ]
  }
}

fn unproved_clause(
  function: String,
  reason: ReturnedOperatorReason,
) -> CheckFinding {
  UnprovedCheck(
    subject: function,
    cause: UnderivableReturnedOperator(reason:),
    site: None,
  )
}

// A foreign producer's clause. The declaration is read raw rather than through
// the standing that gates a caller's trust, because the standing calls a
// written clause settled even where a Gleam fallback body runs beside it — the
// one case that needs a second proof. There is no union of operators, so where
// a body runs the clause holds only when it contains the declaration *and* the
// body's own returned operator.
fn foreign_returns_clause(
  annotation: EffectAnnotation,
  declared: EffectTerm,
  function_definition: Definition(Function),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(List(CheckFinding), Memo) {
  let name =
    QualifiedName(module: context.module_path, function: annotation.function)
  // Only whether a Gleam body runs matters here; whether its charge is counted
  // or suppressed is the effects channel's question, not this one.
  let body_runs = case effects.declared_charge(knowledge_base, name).fallback {
    types.NoFallback -> False
    types.FallbackCharged(_) | types.FallbackSuppressed(_) -> True
  }
  case effects.declared_returned_operator(knowledge_base, name), body_runs {
    Error(Nil), False -> #(
      [
        UnprovedCheck(
          subject: annotation.function,
          cause: UndeclaredForeignReturn,
          site: None,
        ),
      ],
      memo,
    )
    Error(Nil), True -> #(
      [unproved_foreign_fallback(annotation.function)],
      memo,
    )
    Ok(operator), False -> #(
      weigh_returned_operator(annotation.function, declared, Ok(operator)),
      memo,
    )
    Ok(operator), True ->
      case
        weigh_returned_operator(annotation.function, declared, Ok(operator))
      {
        [] -> {
          // The fallback body is read on the targets it runs on, exactly as the
          // non-foreign branch reads an ordinary body.
          let #(knowledge_base, memo) =
            body_walk(
              knowledge_base,
              memo,
              function_definition,
              context.package_targets,
            )
          let #(computed, memo) =
            compute_returned_operator(
              function_definition.definition,
              context,
              function_map,
              knowledge_base,
              set.new(),
              registry,
              module_types,
              cache,
              memo,
            )
          case computed {
            Ok(body_operator) -> #(
              weigh_returned_operator(
                annotation.function,
                declared,
                Ok(body_operator),
              ),
              memo,
            )
            Error(_) -> #(
              [unproved_foreign_fallback(annotation.function)],
              memo,
            )
          }
        }
        findings -> #(findings, memo)
      }
  }
}

fn unproved_foreign_fallback(function: String) -> CheckFinding {
  UnprovedCheck(subject: function, cause: UnprovedForeignFallback, site: None)
}

// What a budget weighs one contributor against: the set `why` prints, with
// every variable *this walk synthesised* grounded to `[Unknown]`.
//
// An unbound function-typed parameter carries the identity bound the walk gives
// every one of them, so a call to it contributes the symbolic `[cb]` — and no
// symbolic set is a subset of a concrete budget. The author wrote that budget
// against a parameter no line names, whose call is the `[Unknown]` an unbound
// call collapses to, so that is what it is weighed against: `check m.run :
// [Unknown]` over `pub fn run(cb: fn() -> Nil) { cb() }` passes.
//
// A variable an author *declared* a bound for is untouched, so `check
// m.run(cb: [cb]) : [Unknown]` states a symbolic effect against a concrete
// budget and stays the violation it has always been. The violation reports the
// ungroomed set either way — the wording names the bound to add, which is the
// variable itself.
//
// Grounding here rather than in `types.is_subset`: every other caller compares
// terms where a variable genuinely means "unbound", and widening the shared
// primitive would answer for them too.
fn weighed_actual(
  actual: types.EffectSet,
  synthesized: Set(String),
) -> types.EffectSet {
  case actual {
    types.Wildcard | types.Specific(_) -> actual
    types.Polymorphic(labels:, variables:) -> {
      let remaining = set.difference(variables, synthesized)
      let labels = case set.is_empty(set.intersection(variables, synthesized)) {
        True -> labels
        False -> set.insert(labels, types.unknown_label)
      }
      case set.is_empty(remaining) {
        True -> types.Specific(labels)
        False -> types.Polymorphic(labels:, variables: remaining)
      }
    }
  }
}

// A warning quotes an effect, so it goes through the boundary that decides what
// an effect *is* — `lookup_declared`, not the raw map. Otherwise a reference to
// an `@external` a stale `effects` line names would be reported as carrying that
// line's effects, which is the one thing no caller of the same name is charged.
//
// Held to `Unknown` meaning silence, as it already was: an unresolved reference
// warns about nothing, so a foreign name the rule collapses to `[Unknown]` warns
// about nothing either, rather than newly warning about an unknown. Silence is
// decided on the *set*, not on which lookup variant carried it — an undeclared
// external with a running fallback answers `Known([…, Unknown])`, so reading the
// variant alone let one warn that its effects `[Unknown]` won't be tracked.
//
// A set that mixes the two (`[Disk, Unknown]`) still warns: the known half is a
// real effect the reference carries past anything that tracks it.
fn collect_reference_warnings(
  function_name: String,
  references: List(types.ResolvedCall),
  knowledge_base: KnowledgeBase,
) -> List(Warning) {
  list.filter_map(references, fn(ref) {
    case effects.lookup_declared(knowledge_base, ref.name) {
      effects.Known(term, _) -> {
        let effect_set = effect_term.to_effect_set(term)
        case
          effect_set == types.empty() || types.is_wholly_unknown(effect_set)
        {
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

// Effect collection
//
// The core body walker: turn a function's extracted calls — resolved, local,
// field, and applied operators — into (call, effect term) pairs, applying
// second-order operator parameters to their callback arguments.

// Operator parameters in scope, mapped to their callback shape: for each
// callback position, that callback's own callback positions (see
// `signatures.operator_param_shapes`). Threaded as `ambient_operators` so a
// closure analysed inside a producer's returned closure can both resolve a
// captured operator and lift a callback argument over exactly its own function
// parameters.
type OperatorShapes =
  dict.Dict(String, List(#(Int, List(Int))))

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
  module_types: dict.Dict(#(Int, Int), girard.Type),
  // Operator parameters in scope from an *enclosing* function (a producer whose
  // returned closure we're analysing), so a call to one becomes a curried
  // operator application rather than `[Unknown]`. Empty for an ordinary function.
  ambient_operators: OperatorShapes,
  // Memoized same-module body analyses, keyed by function name. Lets the local-
  // call path resolve a cacheable callee in O(1) instead of re-walking its body.
  cache: LocalCache,
  // Callable bindings to seed into the body's lexical scope, for a closure being
  // re-analysed away from its creation site. Empty for an ordinary function.
  captures: List(#(String, types.ArgumentValue)),
  // Threaded memo state, extended as memoizable sub-analyses are computed.
  memo: Memo,
) -> #(List(CollectedCall), Memo) {
  let result =
    extract.extract_function_calls_with_captures(function, context, captures)
  let caller_param_names = named_function_params(function)
  let caller_field_bindings = field_bound_bindings(param_bounds)
  // The function's own fn-typed params join the inherited ambient operators, so
  // a closure in this body that captures one resolves it to its effect variable.
  let operator_params =
    dict.merge(
      ambient_operators,
      signatures.operator_param_shapes(function, cache.fn_alias_types),
    )
  let lift_operator_arg =
    build_lift_operator_arg(
      context,
      function_map,
      knowledge_base,
      visited,
      registry,
      module_types,
      operator_params,
      set.new(),
      cache,
    )

  // Resolved calls: qualified names looked up directly in the knowledge
  // base. If the callee's effects are polymorphic (contain effect
  // variables), bind the variables by matching arguments at fn-typed
  // parameter positions and substitute for concrete effects.
  let #(memo, resolved_effects) =
    list.map_fold(result.resolved, memo, fn(memo, call) {
      let looked_up = lookup_parts(knowledge_base, call.name, NoKnownEffects)
      let #(concrete, concrete_fallback, memo) =
        substitute_at_call_site(
          call,
          looked_up.term,
          looked_up.fallback,
          result.call_args,
          function_map,
          context,
          knowledge_base,
          visited,
          param_bounds,
          caller_param_names,
          caller_field_bindings,
          registry,
          module_types,
          cache,
          lift_operator_arg,
          memo,
        )
      let resolution =
        substituted(looked_up, concrete)
        |> with_substituted_fallback(concrete_fallback)
      #(memo, CollectedCall(call:, resolution:))
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
            sentinel_call(bound_call_kind(bound.name), local_call.span)
          // A call to a fn-typed parameter contributes that parameter's effect
          // variable. If the parameter is *second-order* (an operator — its own
          // type takes one or more functions), the call is a *curried*
          // effect-operator application over all its callback arguments, in
          // order: `action(cb1, cb2)` ⟹ `((action e1) e2)`. Folding left-nests
          // the applications so each binder of the lifted operator (abstracted
          // in the same order) beta-reduces against the matching callback once
          // the operator is bound at a call site.
          let #(effect, memo) = case
            dict.get(operator_params, local_call.function)
          {
            Error(Nil) -> #(bound.effects, memo)
            Ok(shape) ->
              curried_operator_application(
                bound.effects,
                shape,
                result.call_args,
                local_call.span,
                knowledge_base,
                param_bounds,
                registry,
                lift_operator_arg,
                memo,
              )
          }
          #(memo, [plain_call(synthetic_call, effect)])
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
            context,
            knowledge_base,
            visited,
            param_bounds,
            caller_param_names,
            caller_field_bindings,
            registry,
            module_types,
            cache,
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
        sentinel_call(field_call_kind(field_call), field_call.span)
      let #(resolution, memo) =
        resolve_field_call(
          field_call,
          function,
          context,
          knowledge_base,
          function_map,
          visited,
          module_types,
          result.call_args,
          param_bounds,
          registry,
          cache,
          lift_operator_arg,
          memo,
        )
      #(memo, CollectedCall(call: synthetic_call, resolution:))
    })

  // Direct applications of a let-bound returned operator: `let h = pick(); h(cb)`.
  // Resolve the producer's returned operator, then apply it to this call's own
  // arguments (curried over the operator's binders). Untraceable producers
  // resolve to [Unknown], exactly as the previous local-call path did.
  let #(memo, direct_op_effects) =
    list.map_fold(result.direct_ops, memo, fn(memo, op) {
      let synthetic_call =
        sentinel_call(ReturnedOperatorCall(op.callee), op.span)
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
          param_bounds,
          cache,
          memo,
        )
      // A producer nothing resolves leaves the applied operator unknown; the
      // kind names the producer, so the reason says what failed about it. A
      // producer that resolved from a serialized summary names the spec that
      // holds it.
      let #(reason, origin) = case resolved_op {
        Ok(#(_, origin)) -> #(None, origin)
        Error(Nil) -> #(
          Some(unresolved_producer_reason(
            knowledge_base,
            producer_key(op.callee, context),
          )),
          None,
        )
      }
      let #(effect, memo) = case resolved_op {
        Ok(#(operator, _)) -> {
          // The returned operator's outer arguments have no tracked type here, so
          // their own callback positions are unknown — lift each over nothing.
          let shape =
            positions_up_to(operator_spine_arity(operator))
            |> list.map(fn(p) { #(p, []) })
          curried_operator_application(
            operator,
            shape,
            result.call_args,
            op.span,
            knowledge_base,
            param_bounds,
            registry,
            lift_operator_arg,
            memo,
          )
        }
        Error(Nil) -> #(effect_term.unknown(), memo)
      }
      #(
        memo,
        CollectedCall(
          call: synthetic_call,
          resolution: Resolution(
            term: effect,
            reason:,
            origin:,
            fallback: types.NoFallback,
          ),
        ),
      )
    })

  // An inline closure / `case` of functions applied to arguments — a pipe target
  // (`x |> fn(f) { f() }`, one argument) or an immediately-invoked closure
  // (`fn(a, cb) { cb() }(1, io.println)`, several). Lift the value over the
  // parameter positions the call supplies arguments for, then apply every
  // argument, so each argument's effect reaches the matching parameter.
  let #(memo, direct_pipe_effects) =
    list.map_fold(result.direct_pipe_ops, memo, fn(memo, op) {
      let synthetic_call = sentinel_call(InlineFunctionCall, op.span)
      let positions =
        call_args_for(result.call_args, op.span)
        |> list.map(fn(a) { a.position })
        |> list.sort(int.compare)
      let #(operator, memo) =
        operator_term_for_argument(
          types.CallArgument(position: 0, label: None, value: op.value),
          positions,
          knowledge_base,
          param_bounds,
          registry,
          lift_operator_arg,
          memo,
        )
      let #(effect, memo) =
        curried_operator_application(
          operator,
          list.map(positions, fn(p) { #(p, []) }),
          result.call_args,
          op.span,
          knowledge_base,
          param_bounds,
          registry,
          lift_operator_arg,
          memo,
        )
      #(memo, plain_call(synthetic_call, effect))
    })

  // Applications of an opaque computed function value (`funcs.0(x)`): the callee
  // can't be resolved to a concrete function, so the application is [Unknown] —
  // never silently pure.
  let unknown_app_effects =
    list.map(result.unknown_apps, fn(span) {
      plain_call(sentinel_call(ComputedValueCall, span), effect_term.unknown())
    })

  // Direct applications of a let-bound closure / case-of-functions: `let h =
  // fn(x) { ... }; h(a)`. The closure body is already walked at its `let`
  // binding site with the lexical environment in scope, so its first-order
  // effect — including any captured callable (`let suffix = string.append; let h
  // = fn(x) { suffix(x) }`) — is already counted there. The only effect that
  // walk drops is the closure's own parameters, bound as opaque callbacks. So
  // lift the closure to an operator over all its parameters and add just the
  // effect flowing through the parameters it actually invokes: each argument at
  // a position whose parameter is still free in the operator body. Re-deriving
  // the whole body here instead would re-introduce a spurious `[Unknown]` for
  // captured names (which resolve only under the binding-site environment).
  let #(memo, direct_closure_effects) =
    list.map_fold(result.direct_closure_ops, memo, fn(memo, op) {
      let synthetic_call = sentinel_call(LetBoundValueCall, op.span)
      let positions = direct_call_positions(op.value)
      let #(operator, memo) =
        operator_term_for_argument(
          types.CallArgument(position: 0, label: None, value: op.value),
          positions,
          knowledge_base,
          param_bounds,
          registry,
          lift_operator_arg,
          memo,
        )
      let #(effect, memo) =
        invoked_parameter_effect(
          operator,
          result.call_args,
          op.span,
          knowledge_base,
          param_bounds,
          registry,
          lift_operator_arg,
          memo,
        )
      #(memo, plain_call(synthetic_call, effect))
    })

  #(
    list.flatten([
      resolved_effects,
      local_effects,
      field_effects,
      direct_op_effects,
      direct_pipe_effects,
      unknown_app_effects,
      direct_closure_effects,
    ]),
    memo,
  )
}

// The effect of the callback an operator parameter is applied to. The callback
// isn't assumed to be first: `callback_position` is the operator parameter's
// own callback argument index (from its type signature, see
// `signatures.operator_param_shapes`), so `action(config, cb)` resolves
// `cb` and not `config`. Pipe-adjusted call positions already align with the
// operator's logical argument positions (the piped receiver takes position 0),
// so the index applies directly. A missing argument at a callback position means
// the operator is under-applied (a partial application whose deferred effect we
// can't resolve here), so it collapses to `[Unknown]` rather than `pure()` — the
// effect must never be silently dropped.
fn operator_argument_effect(
  call_args: dict.Dict(#(Int, Int), List(types.CallArgument)),
  span: Span,
  callback_position: Int,
  nested_positions: List(Int),
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(EffectTerm, Memo) {
  case
    list.find(call_args_for(call_args, span), fn(a) {
      a.position == callback_position
    })
  {
    // A closure, branch, or returned operator passed as the callback must be
    // *lifted* (its body analysed / producer resolved), as at a direct operator
    // call — `resolve_argument_effects` would collapse it to [Unknown]. It is
    // lifted over `nested_positions` — the callback's own function parameters,
    // taken from the operator parameter's type — so a value-parameter callback
    // (`fn(message) { … }`, no nested positions) reduces to its ground effect
    // while a higher-order callback (`fn(_next) { … }`) keeps a binder that
    // β-reduces when the operator applies it.
    Ok(arg) ->
      case arg.value {
        types.Closure(..)
        | types.Choice(..)
        | types.ReturnedOperator(..)
        | types.CallResult(..) ->
          operator_term_for_argument(
            arg,
            nested_positions,
            knowledge_base,
            caller_param_bounds,
            registry,
            lift_operator_arg,
            memo,
          )
        _ -> #(
          resolve_argument_effects(arg, knowledge_base, caller_param_bounds),
          memo,
        )
      }
    Error(Nil) -> #(effect_term.unknown(), memo)
  }
}

// Build a call to a second-order parameter as a *curried* effect-operator
// application over all its callback arguments, in order: `action(cb1, cb2)` ⟹
// `((action e1) e2)`. Left-nesting matches the binder order of the lifted
// operator, so each callback beta-reduces against the right binder once the
// operator is bound at a call site. `shape` is the operator's callbacks: each
// `#(callback position, that callback's own callback positions)`.
fn curried_operator_application(
  operator: EffectTerm,
  shape: List(#(Int, List(Int))),
  call_args: dict.Dict(#(Int, Int), List(types.CallArgument)),
  span: Span,
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(EffectTerm, Memo) {
  list.fold(shape, #(operator, memo), fn(acc, entry) {
    let #(term, memo) = acc
    let #(position, nested_positions) = entry
    let #(arg_effect, memo) =
      operator_argument_effect(
        call_args,
        span,
        position,
        nested_positions,
        knowledge_base,
        caller_param_bounds,
        registry,
        lift_operator_arg,
        memo,
      )
    #(types.TApp(term, arg_effect), memo)
  })
}

// The effect a directly-applied closure adds beyond its binding-site walk: the
// effect of each argument whose parameter the closure actually invokes. The
// lifted `operator` is `λp0. … λpn-1. body`; a parameter that is invoked stays
// free in `body`, so peel the binders and, for each one free in the body, union
// the argument at that position (`operator_argument_effect` resolves the
// callback's effect, recurring through second-order callbacks). The body's own
// first-order effect is deliberately ignored — it is counted at the `let` site.
fn invoked_parameter_effect(
  operator: EffectTerm,
  call_args: dict.Dict(#(Int, Int), List(types.CallArgument)),
  span: Span,
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(EffectTerm, Memo) {
  let #(binders, body) = peel_abstractions(operator, [])
  let free = effect_term.free_vars(body)
  let #(effect, memo) =
    binders
    |> list.index_fold(#(effect_term.pure(), memo), fn(acc, binder, position) {
      let #(term, memo) = acc
      case set.contains(free, binder) {
        // The argument's own callback shape isn't tracked at a direct call, so
        // lift it over no nested positions ([]).
        True -> {
          let #(arg_effect, memo) =
            operator_argument_effect(
              call_args,
              span,
              position,
              [],
              knowledge_base,
              caller_param_bounds,
              registry,
              lift_operator_arg,
              memo,
            )
          #(TUnion([term, arg_effect]), memo)
        }
        False -> #(term, memo)
      }
    })
  #(effect_term.normalize(effect), memo)
}

// Peel a `TAbs` spine, returning its binder names in order plus the innermost
// (non-abstraction) body.
fn peel_abstractions(
  term: EffectTerm,
  acc: List(String),
) -> #(List(String), EffectTerm) {
  case term {
    types.TAbs(param, body) -> peel_abstractions(body, [param, ..acc])
    other -> #(list.reverse(acc), other)
  }
}

// The callback positions to abstract a directly-applied closure over: every one
// of its parameters, in order. A `case`-of-functions takes the widest arity
// among its options, so each branch is fully abstracted. A non-function value
// has no binders.
fn direct_call_positions(value: types.ArgumentValue) -> List(Int) {
  positions_up_to(value_arity(value))
}

fn value_arity(value: types.ArgumentValue) -> Int {
  case value {
    types.Closure(params, _, _) -> list.length(params)
    types.Choice(options) ->
      list.fold(options, 0, fn(max, option) {
        int.max(max, value_arity(option))
      })
    _ -> 0
  }
}

// `[0, 1, …, n-1]` — the callback positions of an `n`-ary operator, applied
// in order. Empty for `n <= 0`.
fn positions_up_to(n: Int) -> List(Int) {
  positions_loop(n - 1, [])
}

fn positions_loop(i: Int, acc: List(Int)) -> List(Int) {
  use <- bool.guard(when: i < 0, return: acc)
  positions_loop(i - 1, [i, ..acc])
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
  // A `LocalRef` naming a caller parameter bound is a forwarded *parameter*,
  // which can shadow a same-module function of the same name. Resolve it
  // through the bound, never by lifting the shadowed function — a param bound
  // only ever names a parameter, so this can't misfire on a real function ref.
  let shadows_param = case arg.value {
    types.LocalRef(name) ->
      list.any(caller_param_bounds, fn(b) { b.name == name })
    _ -> False
  }
  case arg.value, shadows_param {
    // A closure or a same-module named function both lift to an operator (the
    // function reference via `lift_local_function`), whose discharge is the
    // effect of calling it. A `LocalRef` that isn't a same-module function — a
    // forwarded parameter with no bound — lifts to `Error(Nil)` and falls back
    // to the param-bound lookup, so a named function resolves to its real
    // effect instead of collapsing to [Unknown].
    types.Closure(_, _, _), _ | types.LocalRef(_), False -> {
      let #(lifted, memo) = lift_operator_arg(arg.value, [], memo)
      case lifted {
        Ok(operator) -> #(discharge_operator(operator), memo)
        Error(Nil) -> #(
          resolve_argument_effects(arg, knowledge_base, caller_param_bounds),
          memo,
        )
      }
    }
    _, _ -> #(
      resolve_argument_effects(arg, knowledge_base, caller_param_bounds),
      memo,
    )
  }
}

// A pure operator that absorbs `positions`-many callback arguments and reduces
// to `pure`. The contribution of an operator reference whose own effects are
// already accounted for elsewhere — a recursive self-reference, captured by the
// outer frame analysing it. Empty `positions` yields a ground `pure`.
fn pure_operator(positions: List(Int)) -> EffectTerm {
  list.fold(positions, effect_term.pure(), fn(body, position) {
    types.TAbs("_rec" <> int.to_string(position), body)
  })
}

// The neutral operator a recursive producer call contributes: pure over the
// callback positions of the producer's returned function type. `Error(Nil)`
// when the return type is absent or not a function (no arity to recover), so
// resolution stays conservative.
fn neutral_returned_operator(
  function: Function,
  alias_map: dict.Dict(String, glance.Type),
) -> Result(EffectTerm, Nil) {
  use return_type <- result.try(option.to_result(function.return, Nil))
  use positions <- result.map(signatures.returned_callback_positions(
    return_type,
    alias_map,
  ))
  pure_operator(positions)
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

fn named_function_params(function: Function) -> Set(String) {
  function.parameters
  |> list.filter_map(fn(param) {
    param.name |> signatures.assignment_name |> option.to_result(Nil)
  })
  |> set.from_list()
}

// Call-site substitution
//
// Bind a callee's free effect variables against the caller's arguments and
// bounds, so polymorphic effects ground at each call site instead of leaking
// upward as internal variable names.

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
  recursive: List(CollectedCall),
  local_call: LocalCall,
  call_args: dict.Dict(#(Int, Int), List(types.CallArgument)),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  caller_param_bounds: List(ParamBound),
  caller_param_names: Set(String),
  caller_field_bindings: dict.Dict(String, EffectTerm),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(List(CollectedCall), Memo) {
  case dict.get(function_map, local_call.function) {
    Error(Nil) -> #(recursive, memo)
    Ok(local_definition) -> {
      // A sibling a declaration answers for was collected as the knowledge
      // base's charge under its qualified name. Substitute it exactly as a
      // qualified call is — auto-detected callback bounds included — so both
      // call shapes pay the same set.
      //
      // A *native* sibling under a module-level `assume` comes through here
      // too. That line states the function's own effects and says nothing
      // about what it does with a callback it is handed, exactly as a
      // boundless per-function line does; keeping the declaration's set alone
      // charged its callback to nobody, and let a same-module caller pass an
      // effectful function to a module-assumed helper for free.
      use <- bool.lazy_guard(
        when: declares_for_callers(local_definition, context, knowledge_base),
        return: fn() {
          let #(memo, calls) =
            list.map_fold(recursive, memo, fn(memo, one) {
              let #(concrete, concrete_fallback, memo) =
                substitute_at_call_site(
                  one.call,
                  one.resolution.term,
                  one.resolution.fallback,
                  call_args,
                  function_map,
                  context,
                  knowledge_base,
                  visited,
                  caller_param_bounds,
                  caller_param_names,
                  caller_field_bindings,
                  registry,
                  module_types,
                  cache,
                  lift_operator_arg,
                  memo,
                )
              let resolution =
                substituted(one.resolution, concrete)
                |> with_substituted_fallback(concrete_fallback)
              #(memo, CollectedCall(..one, resolution:))
            })
          #(calls, memo)
        },
      )
      let any_polymorphic =
        list.any(recursive, fn(one) {
          has_vars(collected_term(one))
          || suppressed_share_vars(one.resolution.fallback)
        })
      use <- bool.guard(when: !any_polymorphic, return: #(recursive, memo))
      let bounds = local_polymorphic_bounds(local_definition, cache)
      let args = call_args_for(call_args, local_call.span)
      let callee_name =
        QualifiedName(module: local_sentinel, function: local_call.function)
      // The synthetic local module isn't in `registry`, so build a
      // single-entry registry from this local function's glance AST so
      // positional argument matching has parameter info to work with.
      let local_registry =
        signatures.from_single_function(
          local_sentinel,
          local_definition,
          cache.fn_alias_types,
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
      let callee_terms = list.map(recursive, collected_term)
      let #(field_bindings, memo) =
        field_forwarding_bindings(
          callee_name,
          TUnion(callee_terms),
          args,
          caller_param_names,
          caller_param_bounds,
          merged_registry,
          function_map,
          context,
          knowledge_base,
          visited,
          module_types,
          cache,
          memo,
        )
      let forwarded = forwarded_field_vars(field_bindings.terms)
      // Each site is re-attributed against the term this caller's bindings
      // produced: an `[Unknown]` they introduced is this call's argument, and a
      // field variable the callee left open is answered by the source of the
      // value this caller wired. A fallback share rides the same bindings as
      // the term it is a component of.
      let substituted =
        list.map(recursive, fn(one) {
          let bind = fn(term) {
            apply_call_bindings(
              term,
              bindings,
              field_bindings.terms,
              caller_field_bindings,
              forwarded,
            )
          }
          let resolution =
            rebound(one.resolution, bind(collected_term(one)), {
              field_bindings.origins
            })
            |> with_substituted_fallback(types.map_fallback(
              one.resolution.fallback,
              bind,
            ))
          CollectedCall(..one, resolution:)
        })
      #(substituted, memo)
    }
  }
}

// Derive the polymorphic param bounds a local function would carry
// after auto-inference: one bound per fn-typed parameter, with an
// effect variable matching the parameter name.
//
// The same set the walk abstracted over, girard's parameters included, so a
// term the walk left polymorphic is bound here rather than substituting
// nothing and collapsing to `[Unknown]`.
fn local_polymorphic_bounds(
  definition: Definition(Function),
  cache: LocalCache,
) -> List(ParamBound) {
  synthetic_fn_typed_bounds(unbound_fn_typed_params(definition, [], cache))
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
  fallback: types.FallbackDisposition(EffectTerm),
  call_args: dict.Dict(#(Int, Int), List(types.CallArgument)),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  caller_param_bounds: List(ParamBound),
  caller_param_names: Set(String),
  caller_field_bindings: dict.Dict(String, EffectTerm),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(EffectTerm, types.FallbackDisposition(EffectTerm), Memo) {
  let callee_kb_bounds = effects.lookup_param_bounds(knowledge_base, call.name)
  // Fast path: concrete effect with declared bounds — nothing to
  // substitute. With no declared bounds we still need to fall through
  // in case the registry flags auto-injectable fn-typed params.
  //
  let fallback_vars = suppressed_share_vars(fallback)
  use <- bool.guard(
    when: !has_vars(effect) && !fallback_vars && callee_kb_bounds != [],
    return: #(effect, fallback, memo),
  )
  let args = call_args_for(call_args, call.span)
  let #(effective_effects, effective_bounds) = case callee_kb_bounds {
    [_, ..] -> #(effect, callee_kb_bounds)
    [] -> auto_bounds_from_registry(call.name, effect, args, registry)
  }
  use <- bool.guard(
    when: !has_vars(effective_effects) && !fallback_vars,
    return: #(effective_effects, fallback, memo),
  )
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
  let #(field_bindings, memo) =
    field_forwarding_bindings(
      call.name,
      effective_effects,
      args,
      caller_param_names,
      caller_param_bounds,
      registry,
      function_map,
      context,
      knowledge_base,
      visited,
      module_types,
      cache,
      memo,
    )
  let forwarded = forwarded_field_vars(field_bindings.terms)
  let bind = fn(term) {
    apply_call_bindings(
      term,
      bindings,
      field_bindings.terms,
      caller_field_bindings,
      forwarded,
    )
  }
  // The fallback share is rewritten by the same bindings as the total it is a
  // component of: the two describe one call, and a variable the total resolved
  // must not survive in the share a structured consumer reads beside it.
  #(bind(effective_effects), types.map_fallback(fallback, bind), memo)
}

// Finish a call-site effect: bind the callee's effect variables, re-key any
// forwarded field paths onto the caller's parameters, discharge the caller's
// own field bounds, then ground every field variable still naming a
// callee-local receiver. Shared by the resolved and local call paths.
fn apply_call_bindings(
  term: EffectTerm,
  bindings: dict.Dict(String, EffectTerm),
  field_bindings: dict.Dict(String, EffectTerm),
  caller_field_bindings: dict.Dict(String, EffectTerm),
  forwarded: Set(String),
) -> EffectTerm {
  term
  |> subst_if(bindings)
  |> subst_if(field_bindings)
  |> subst_if(caller_field_bindings)
  |> concretize_field_vars_except(forwarded)
  |> effect_term.normalize()
}

// `effect_term.subst` walks and reallocates the whole term even for an empty
// binding set, so skip it when there is nothing to substitute.
fn subst_if(
  term: EffectTerm,
  bindings: dict.Dict(String, EffectTerm),
) -> EffectTerm {
  use <- bool.guard(when: dict.is_empty(bindings), return: term)
  effect_term.subst(term, bindings)
}

// Field forwarding and receiver grounding
//
// Re-key a callee's field-effect variables onto the caller's own parameters,
// grounding computed receivers through return provenance so factory-built
// values still resolve to a caller-scope path.

// What a callee's field-effect variables bind to at one call site: the term
// each takes, and — for a variable bound to the effect of a value wired at the
// receiver's construction — the source that answered for that value, so a field
// call resolved by forwarding names its source like a direct read does.
type FieldBindings {
  FieldBindings(
    terms: dict.Dict(String, EffectTerm),
    origins: dict.Dict(String, LookupOrigin),
  )
}

// One field variable's binding.
type FieldBinding {
  FieldBinding(
    variable: String,
    term: EffectTerm,
    origin: option.Option(LookupOrigin),
  )
}

// The source that answered for a field variable this term carried, when the
// substitution bound exactly one such variable. Two bound variables name two
// sources and the message states one, so neither is claimed.
fn bound_field_origin(
  term: EffectTerm,
  origins: dict.Dict(String, LookupOrigin),
) -> option.Option(LookupOrigin) {
  case
    term
    |> effect_term.free_vars()
    |> set.to_list()
    |> list.filter_map(dict.get(origins, _))
    |> list.unique()
  {
    [origin] -> Some(origin)
    [] | [_, _, ..] -> None
  }
}

// Re-key free field-effect variables from a callee receiver parameter onto a
// caller parameter when the caller forwards that parameter directly:
// `inner(options)` lets `inner`'s `o.run` become this caller's `options.run`.
// Only the first path segment is matched as the callee parameter; the remaining
// tail is preserved, so `o.inner.run` forwards to `options.inner.run`.
fn field_forwarding_bindings(
  callee_name: types.QualifiedName,
  effect: EffectTerm,
  args: List(types.CallArgument),
  caller_param_names: Set(String),
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(FieldBindings, Memo) {
  effect
  |> effect_term.free_vars()
  |> set.filter(is_field_path_var)
  |> set.fold(#(FieldBindings(dict.new(), dict.new()), memo), fn(state, var) {
    let #(bindings, memo) = state
    let #(binding, memo) =
      field_forwarding_binding(
        var,
        callee_name,
        args,
        caller_param_names,
        caller_param_bounds,
        registry,
        function_map,
        context,
        knowledge_base,
        visited,
        module_types,
        cache,
        memo,
      )
    case binding {
      Some(FieldBinding(variable:, term:, origin:)) -> {
        let terms = dict.insert(bindings.terms, variable, term)
        let origins = case origin {
          Some(origin) -> dict.insert(bindings.origins, variable, origin)
          None -> bindings.origins
        }
        #(FieldBindings(terms:, origins:), memo)
      }
      None -> #(bindings, memo)
    }
  })
}

fn field_forwarding_binding(
  var: String,
  callee_name: types.QualifiedName,
  args: List(types.CallArgument),
  caller_param_names: Set(String),
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(option.Option(FieldBinding), Memo) {
  case
    forwarded_receiver_value(
      var,
      callee_name,
      args,
      registry,
      function_map,
      context,
      knowledge_base,
    )
  {
    None -> #(None, memo)
    Some(#(base, tail)) ->
      forwarded_var_binding(
        var,
        base,
        tail,
        caller_param_names,
        caller_param_bounds,
        registry,
        function_map,
        context,
        knowledge_base,
        visited,
        module_types,
        cache,
        memo,
      )
  }
}

// The caller-scope value a callee field variable's receiver segment names, with
// the remaining path tail. A computed receiver (`inner(get_options(config))`)
// resolves through the callee's return provenance; a plain receiver forwards
// as-is.
fn forwarded_receiver_value(
  var: String,
  callee_name: types.QualifiedName,
  args: List(types.CallArgument),
  registry: SignatureRegistry,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
) -> option.Option(#(types.ArgumentValue, String)) {
  use #(receiver, tail) <- option.then(
    option.from_result(string.split_once(var, ".")),
  )
  use arg <- option.then(find_matching_arg_by_name(
    callee_name,
    receiver,
    args,
    registry,
  ))
  use base <- option.then(
    option.from_result(grounded_receiver(
      arg.value,
      function_map,
      context,
      knowledge_base,
      registry,
    )),
  )
  Some(#(base, tail))
}

// What one field variable binds to for a grounded receiver value: a re-keyed
// caller path, or the concrete effect of a value wired at the construction the
// receiver was built by.
fn forwarded_var_binding(
  var: String,
  base: types.ArgumentValue,
  tail: String,
  caller_param_names: Set(String),
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(option.Option(FieldBinding), Memo) {
  case base {
    // A grounded `Join` (a `case`/`if` return) forwards through every branch and
    // unions the results; any branch that can't re-key onto a caller parameter
    // widens the whole join to Top, so the field var stays and concretizes to
    // `[Unknown]` — the join never under-reports a branch.
    types.Choice(options) -> {
      let terms =
        list.map(options, forwarded_binding_term(
          _,
          tail,
          caller_param_names,
          caller_param_bounds,
        ))
      case option.all(terms) {
        Some([_, ..] as effects) -> #(
          Some(FieldBinding(
            variable: var,
            term: effect_term.normalize(TUnion(effects)),
            origin: None,
          )),
          memo,
        )
        // A branch that can't re-key widens the join to Top (`None`), and a
        // `Choice` carrying no options proves nothing (`Some([])`); both leave
        // the field variable in place.
        None | Some([]) -> #(None, memo)
      }
    }
    types.FunctionRef(..)
    | types.LocalRef(..)
    | types.ConstructorRef
    | types.Closure(..)
    | types.ReturnedOperator(..)
    | types.ReceiverPath(..)
    | types.Constructed(..)
    | types.CallResult(..)
    | types.Updated(..)
    | types.OtherExpression ->
      case
        forwarded_binding_term(
          base,
          tail,
          caller_param_names,
          caller_param_bounds,
        )
      {
        Some(term) -> #(
          Some(FieldBinding(variable: var, term:, origin: None)),
          memo,
        )
        // Not caller-rooted: the field may resolve to a concrete
        // construction-site value (a builder-set field, `opts.resolver =
        // logging_resolver`). Bind the var to that value's own effect, so a
        // builder overlay forwards a precise effect instead of `[Unknown]`.
        None ->
          wired_value_binding(
            var,
            value_at_path(base, tail),
            context,
            knowledge_base,
            function_map,
            visited,
            registry,
            module_types,
            cache,
            memo,
          )
      }
  }
}

// Bind a field variable to the effect of the value wired at the construction the
// receiver was built by, when that value's effect is ground.
fn wired_value_binding(
  var: String,
  value: Result(types.ArgumentValue, Nil),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  function_map: dict.Dict(String, Definition(Function)),
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(option.Option(FieldBinding), Memo) {
  case value {
    Error(Nil) -> #(None, memo)
    Ok(value) -> {
      let #(bound, memo) =
        concrete_field_effect(
          value,
          context,
          knowledge_base,
          function_map,
          visited,
          registry,
          module_types,
          cache,
          memo,
        )
      let binding =
        option.map(bound, fn(effect) {
          let #(term, origin) = effect
          FieldBinding(variable: var, term:, origin:)
        })
      #(binding, memo)
    }
  }
}

// The effect a callee field variable takes when it forwards onto a builder-set
// field value: a function reference or same-module function whose effect is a
// ground set resolves via the knowledge base. A closure or call-result value —
// whose field effect is an *operator* awaiting the field call's own arguments —
// can't be resolved here, since the forwarding site binds a ground effect but has
// no field-call arguments to apply the operator to; those live in the callee's
// body. Such a value, and any operator-valued or still-polymorphic effect,
// yields `None`, so the variable stays and concretizes to `[Unknown]` — never a
// guessed narrower set. (A *direct* read of the same field resolves it precisely
// through `resolve_proven_field`, which does have the field call's arguments.)
// The source that answered for the value travels out beside the effect.
fn concrete_field_effect(
  value: types.ArgumentValue,
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  function_map: dict.Dict(String, Definition(Function)),
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(option.Option(#(EffectTerm, option.Option(LookupOrigin))), Memo) {
  let #(field_effect, origin, memo) =
    value_field_effect(
      value,
      set.from_list(dict.keys(function_map)),
      context,
      knowledge_base,
      function_map,
      visited,
      registry,
      module_types,
      cache,
      memo,
    )
  let bound = case
    field_effect.source,
    ground_field_operator(field_effect.effects)
  {
    // A wired effect-polymorphic function (a decorator), or a higher-order
    // field whose effect depends on the field call's own arguments: those are
    // bound at the call site and unavailable here — leave the variable to
    // concretize to `[Unknown]`.
    Some(_), _ | _, None -> None
    // A ground effect — including the resolved effect of a first-order closure or
    // call-result field value, which `value_field_effect` grounds via the same
    // per-value resolution the direct-read path uses. Residual variables ground
    // to `[Unknown]`; never a narrower set than the true effect.
    None, Some(effects) -> Some(#(concretize(effects), origin))
  }
  #(bound, memo)
}

// The effect a forwarding site can bind a field variable to: the term itself
// when it is already ground, or the body of an operator whose binders are all
// vacuous. A vacuous binder never appears in the body, so every application
// β-reduces to that same body — `λm. [Stdout]`, the operator a first-order
// closure wired into a field lifts to, binds `[Stdout]` however the field is
// called. `λnext. [next]` does depend on its argument and binds nothing.
fn ground_field_operator(term: EffectTerm) -> option.Option(EffectTerm) {
  let #(binders, body) = peel_abstractions(term, [])
  let free = effect_term.free_vars(body)
  use <- bool.guard(list.any(binders, set.contains(free, _)), None)
  use <- bool.guard(is_operator_valued(body), None)
  Some(body)
}

// The effect term a callee field var (`o.run`) re-keys to for one grounded
// receiver value: a dotted forwarded path (`config.options.run`) stays a variable
// the caller's field-bound substitution discharges; a plain forwarded path is a
// bare fn-typed caller parameter, discharged here against the caller's own param
// bound (self-referential during infer, concrete at check). `None` when the value
// can't re-key onto a caller parameter.
fn forwarded_binding_term(
  base: types.ArgumentValue,
  tail: String,
  caller_param_names: Set(String),
  caller_param_bounds: List(ParamBound),
) -> option.Option(EffectTerm) {
  use path <- option.then(forwarded_path(base, tail, caller_param_names))
  case is_field_path_var(path) {
    True -> Some(TVar(path))
    False ->
      case list.find(caller_param_bounds, fn(b) { b.name == path }) {
        Ok(bound) -> Some(bound.effects)
        Error(Nil) -> Some(TVar(path))
      }
  }
}

// The caller-rooted path a callee field var (`o.run`) re-keys to, given the
// argument bound to the callee receiver and the callee tail (`run`): follow the
// tail through the argument (grafting a receiver path, or resolving each field
// wiring of an inline constructor/factory), then require the value it lands on
// to be rooted at a caller parameter. So `inner(config.options)` makes `o.run`
// the caller's `config.options.run` and `inner(make_options(resolver))` makes
// `o.resolver` the caller's `resolver`. `None` when the argument isn't rooted at
// a caller parameter, or the field isn't wired to one.
fn forwarded_path(
  value: types.ArgumentValue,
  tail: String,
  caller_param_names: Set(String),
) -> option.Option(String) {
  value_at_path(value, tail)
  |> option.from_result
  |> option.then(caller_rooted_path(_, caller_param_names))
}

// The receiver path an argument denotes when rooted at one of the caller's own
// parameters: a bare parameter reference is the single-segment case
// (`options`), a receiver path the multi-segment one (`config.options`). `None`
// for any other value, or when the root isn't a caller parameter.
fn caller_rooted_path(
  value: types.ArgumentValue,
  caller_param_names: Set(String),
) -> option.Option(String) {
  use path <- option.then(case value {
    types.LocalRef(name) -> Some(name)
    types.ReceiverPath(path) -> Some(path)
    _ -> None
  })
  let root = case string.split_once(path, ".") {
    Ok(#(root, _)) -> root
    Error(Nil) -> path
  }
  case set.contains(caller_param_names, root) {
    True -> Some(path)
    False -> None
  }
}

// Resolve a computed-receiver `CallResult` to a caller-scope value by
// substituting its grounded arguments into the callee's `ReturnProvenance`: a
// `Passthrough` yields the argument itself, a `Path` extends it into a receiver
// path, and a `Build` produces a constructed value. The result is handed to
// `forwarded_path`, which re-keys the callee field tail onto it. Any other value
// forwards as-is. `Error` when the provenance is opaque or can't be grounded —
// the receiver stays `[Unknown]`.
fn grounded_receiver(
  value: types.ArgumentValue,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
) -> Result(types.ArgumentValue, Nil) {
  case value {
    types.CallResult(callee, args) -> {
      // Provenance positions index the callee's parameter list, but a labeled
      // argument can bind out of textual order. Reorder a labeled call into
      // parameter-position order via the callee's signature before grounding;
      // an all-positional call already lines up, so it grounds as-is. A labeled
      // call whose callee isn't in the registry can't be reordered and widens.
      use positional <- result.try(
        case list.any(args, fn(arg) { arg.label != None }) {
          False -> Ok(args)
          True -> reorder_args_by_signature(callee, args, context, registry)
        },
      )
      use provenance <- result.try(callee_provenance(
        callee,
        function_map,
        context,
        knowledge_base,
      ))
      ground_provenance(provenance, positional)
    }
    // A record-update overlay: ground its base too, so a field the overlay
    // doesn't replace can still be read through it (`default_options() |>
    // with_reporter(r)` keeps a traceable `resolver`). Updated fields are read
    // from the overlay first and don't depend on this; a base that won't ground
    // keeps the overlay as-is, so an inherited field over an untraceable base
    // stays `[Unknown]` exactly as before. Chained builders unwrap one layer per
    // step.
    types.Updated(base:, fields:) ->
      case
        grounded_receiver(base, function_map, context, knowledge_base, registry)
      {
        Ok(grounded) -> Ok(types.Updated(base: grounded, fields:))
        Error(Nil) -> Ok(value)
      }
    types.FunctionRef(_)
    | types.LocalRef(_)
    | types.ConstructorRef
    | types.Closure(..)
    | types.Choice(_)
    | types.ReturnedOperator(..)
    | types.ReceiverPath(_)
    | types.Constructed(_)
    | types.OtherExpression -> Ok(value)
  }
}

// Reorder a labeled call's arguments into the callee's declared parameter order
// so provenance positions (which index the parameter list) still line up. Each
// parameter takes the argument carrying its Gleam label, else the positional
// argument at its position. The result is re-keyed to canonical positions
// (`position: i, label: None`) so `arg_value_at` indexes it directly. `Error`
// when the callee isn't in the registry or a parameter has no matching argument
// — the receiver stays `[Unknown]`. A same-module (`""`) callee is keyed by the
// module under check, where the registry stored its signature.
fn reorder_args_by_signature(
  callee: types.QualifiedName,
  args: List(types.CallArgument),
  context: ImportContext,
  registry: SignatureRegistry,
) -> Result(List(types.CallArgument), Nil) {
  use params <- result.try(option.to_result(
    signatures.lookup(registry, producer_key(callee, context)),
    Nil,
  ))
  let sorted =
    list.sort(params, fn(a, b) { int.compare(a.position, b.position) })
  use values <- result.map(
    list.try_map(sorted, fn(param) {
      let by_label = param.label |> option.then(find_arg_by_label(args, _))
      case by_label {
        Some(arg) -> Ok(arg.value)
        None ->
          find_arg_at_position(args, param.position)
          |> option.to_result(Nil)
          |> result.map(fn(arg) { arg.value })
      }
    }),
  )
  list.index_map(values, fn(value, position) {
    types.CallArgument(position:, label: None, value:)
  })
}

// Substitute a call's grounded arguments into a `ReturnProvenance`, yielding a
// caller-scope value: a `Passthrough` is the argument itself, a `Path` extends it
// into a receiver path, a `Build` produces a constructed value, and a `Join`
// grounds every branch into a `Choice` (whose branches the forwarding path
// re-keys and unions). `Error` when the provenance is opaque or a branch/argument
// can't be grounded — the receiver stays `[Unknown]`.
fn ground_provenance(
  provenance: types.ReturnProvenance,
  args: List(types.CallArgument),
) -> Result(types.ArgumentValue, Nil) {
  case provenance {
    types.Passthrough(position) -> arg_value_at(args, position)
    types.Path(position, tail) -> {
      use grounded <- result.try(arg_value_at(args, position))
      value_at_path(grounded, tail)
    }
    types.Build(fields) -> {
      use built <- result.map(substitute_build_fields(fields, args))
      types.Constructed(fields: built)
    }
    types.Join(branches) -> {
      use values <- result.try(
        list.try_map(branches, ground_provenance(_, args)),
      )
      case values {
        [] -> Error(Nil)
        _ -> Ok(types.Choice(values))
      }
    }
    types.Opaque -> Error(Nil)
  }
}

// The return-value provenance of a `CallResult`'s callee: a same-module callee
// (the `""` sentinel) is re-derived from the module-local function map, mirroring
// the on-demand returned-operator path; a qualified callee is looked up in the
// knowledge base (computed at its inference time, available by topological order).
fn callee_provenance(
  callee: types.QualifiedName,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
) -> Result(types.ReturnProvenance, Nil) {
  case callee.module {
    "" ->
      // A fallback body describes neither what the foreign implementation
      // returns nor how, so a same-module consumer of one is charged `[Unknown]`
      // exactly as a cross-module consumer is: this channel reads no
      // declaration, so a foreign definition and no definition end alike here.
      case
        local_definition(function_map, callee.function, context.package_targets)
      {
        NativeDefinition(definition) ->
          Ok(extract.return_provenance(definition.definition, context))
        ForeignDefinition | NoLocalDefinition -> Error(Nil)
      }
    _ -> effects.lookup_provenance(knowledge_base, callee)
  }
}

// The value at positional call-argument `position` (grounding runs only on
// all-positional calls), or `Error` when out of range.
fn arg_value_at(
  args: List(types.CallArgument),
  position: Int,
) -> Result(types.ArgumentValue, Nil) {
  find_arg_at_position(args, position)
  |> option.to_result(Nil)
  |> result.map(fn(arg) { arg.value })
}

// Ground each field of a `Build` provenance to a caller-scope value. Any field
// that can't be grounded (an out-of-range or non-path argument) widens the whole
// construction to `Error`, leaving the receiver `[Unknown]`.
fn substitute_build_fields(
  fields: dict.Dict(String, types.FieldProvenance),
  args: List(types.CallArgument),
) -> Result(dict.Dict(String, types.ArgumentValue), Nil) {
  dict.fold(fields, Ok(dict.new()), fn(accumulator, label, provenance) {
    use built <- result.try(accumulator)
    case provenance {
      types.FieldParam(position) -> {
        use grounded <- result.map(arg_value_at(args, position))
        dict.insert(built, label, grounded)
      }
      types.FieldPath(position, tail) -> {
        use grounded <- result.try(arg_value_at(args, position))
        use extended <- result.map(value_at_path(grounded, tail))
        dict.insert(built, label, extended)
      }
      // A concrete construction-site value: independent of the call's arguments,
      // so it grounds to itself.
      types.FieldValue(value) -> Ok(dict.insert(built, label, value))
      types.FieldOpaque -> Error(Nil)
    }
  })
}

// The value reached by following `tail` (a dotted field path) from `value`:
// navigate a `Constructed` record's wiring, or extend a caller-rooted path. An
// empty tail returns the value unchanged. `Error` when the path can't be followed.
fn value_at_path(
  value: types.ArgumentValue,
  tail: String,
) -> Result(types.ArgumentValue, Nil) {
  case tail {
    "" -> Ok(value)
    _ -> {
      // The head field and the path remaining under it, empty at the last step
      // — which the `""` base case above then returns unchanged.
      let #(field, rest) = case string.split_once(tail, ".") {
        Ok(split) -> split
        Error(Nil) -> #(tail, "")
      }
      case value {
        types.Constructed(fields) -> {
          use wired <- result.try(dict.get(fields, field))
          value_at_path(wired, rest)
        }
        // A record-update overlay: read the head field selectively. An updated
        // field takes its replacement; any other falls through to the base —
        // without requiring the base to be traceable, so an updated field
        // resolves even over an opaque base.
        types.Updated(base, fields) ->
          case dict.get(fields, field) {
            Ok(wired) -> value_at_path(wired, rest)
            Error(Nil) -> value_at_path(base, tail)
          }
        types.LocalRef(name) -> Ok(types.ReceiverPath(name <> "." <> tail))
        types.ReceiverPath(path) -> Ok(types.ReceiverPath(path <> "." <> tail))
        types.FunctionRef(_)
        | types.ConstructorRef
        | types.Closure(..)
        | types.Choice(_)
        | types.ReturnedOperator(..)
        | types.CallResult(..)
        | types.OtherExpression -> Error(Nil)
      }
    }
  }
}

fn field_bound_bindings(
  caller_param_bounds: List(ParamBound),
) -> dict.Dict(String, EffectTerm) {
  caller_param_bounds
  |> list.filter(fn(bound) { is_field_path_var(bound.name) })
  |> list.map(fn(bound) { #(bound.name, bound.effects) })
  |> dict.from_list()
}

// The forwarded vars re-keyed onto the caller's own parameters, which
// `concretize_field_vars_except` must preserve while grounding every remaining
// callee-local field var. Usually a dotted field path (`config.options.run`);
// a factory field wired to a bare fn-typed parameter forwards to that plain
// parameter var (`resolver`), which `concretize_field_vars_except` leaves alone
// anyway (it grounds only dotted vars), so keeping it is harmless.
fn forwarded_field_vars(
  bindings: dict.Dict(String, EffectTerm),
) -> Set(String) {
  bindings
  |> dict.values()
  |> list.fold(set.new(), fn(vars, term) {
    set.union(vars, effect_term.free_vars(term))
  })
}

// Variable binding and operator lifting
//
// Match caller arguments to callee param bounds, lifting closures, same-module
// functions, and returned operators into effect operators that beta-reduce at
// their application sites.

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
            types.Closure(_, _, _)
            | types.Choice(_)
            | types.ReceiverPath(_)
            | types.Constructed(_)
            | types.OtherExpression -> Error(Nil)
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
// `λp1. λp2. <g's declared effect>`, abstracting over all of `g`'s callback
// parameters in order — the body comes through the boundary that holds foreign
// code to what declares it, so an undeclared `@external` abstracts over
// `[Unknown]` and every application of it stays `[Unknown]`. An inline closure
// or a same-module named function is lifted by
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
      let body = effects.declared_effects(knowledge_base, name)
      // Abstract over `g`'s fn-typed params in declaration order. The outermost
      // binder is the first param, matching the left-nested application spine
      // built at the definition site. The recorded bounds count as fn-typed
      // too: a running fallback's girard-typed callback has no `fn(...)`
      // annotation for the registry to see, and without its binder the
      // summary's variable stays free and the application goes stuck.
      let operator =
        signatures.fn_typed_param_names_ordered(
          registry,
          name,
          value_channel_bound_names(knowledge_base, name),
        )
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
  module_types: dict.Dict(#(Int, Int), girard.Type),
  ambient_operators: OperatorShapes,
  sentinel_params: Set(String),
  cache: LocalCache,
) -> fn(types.ArgumentValue, List(Int), Memo) ->
  #(Result(EffectTerm, Nil), Memo) {
  fn(value: types.ArgumentValue, positions: List(Int), memo: Memo) {
    case value {
      types.Closure(params, captures, body) -> {
        let #(operator, memo) =
          analyze_closure(
            params,
            captures,
            body,
            positions,
            context,
            function_map,
            knowledge_base,
            visited,
            registry,
            module_types,
            ambient_operators,
            sentinel_params,
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
          // A recursive reference — the function is already being analysed up
          // the call stack, so its own effects are captured by that outer
          // frame. This reference contributes nothing: a pure operator over the
          // callback positions, rather than collapsing to [Unknown]. Mirrors
          // the cycle handling in `resolve_unknown_local`.
          True, Ok(_) -> #(Ok(pure_operator(positions)), memo)
          _, _ -> #(Error(Nil), memo)
        }
      types.ReturnedOperator(callee, args) | types.CallResult(callee, args) -> {
        let #(resolved, memo) =
          resolve_returned_operator(
            callee,
            args,
            context,
            function_map,
            knowledge_base,
            visited,
            registry,
            module_types,
            [],
            cache,
            memo,
          )
        #(result.map(resolved, fn(found) { found.0 }), memo)
      }
      _ -> #(Error(Nil), memo)
    }
  }
}

// A producer's knowledge-base key. A same-module callee carries no module of its
// own, so the module being walked qualifies it — the resolution path and the
// diagnostic that explains its failure ask about one name this way.
fn producer_key(
  callee: QualifiedName,
  context: ImportContext,
) -> QualifiedName {
  case callee.module {
    "" -> QualifiedName(module: context.module_path, function: callee.function)
    _ -> callee
  }
}

// Why a producer left its applied operator unknown. A declared return that a
// gate refused is named rather than folded into the generic reason: one gate is
// the same reading a direct call reports for that `@external`, and the other is
// this channel's own refusal, which no other surface has words for.
fn unresolved_producer_reason(
  knowledge_base: KnowledgeBase,
  producer: QualifiedName,
) -> UnknownReason {
  case effects.declared_return_standing(knowledge_base, producer) {
    effects.DeclaredReturnUnbuilt -> UnbuiltExternal
    effects.DeclaredReturnFallbackRuns -> RefusedDeclaredReturn
    effects.DeclaredReturnAnswers | effects.NoDeclaredReturn ->
      UntraceableProducer
  }
}

// The knowledge base's summary for `name`, in the shape the trust match reads:
// the operator, how it was produced — a `Closed` summary carrying the bounds
// that scope it — and the source that wrote it.
fn knowledge_base_operator(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Result(
  #(EffectTerm, effects.SummaryOrigin, option.Option(LookupOrigin)),
  Nil,
) {
  effects.lookup_returned_operator(knowledge_base, name)
  |> result.map(fn(found) {
    #(found.operator, found.summary, Some(found.source))
  })
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
  module_types: dict.Dict(#(Int, Int), girard.Type),
  // The enclosing scope's caller bounds, threaded into `bind_producer_params`
  // for D1 (nested-producer precision). `[]` when resolving a top-level producer.
  caller_param_bounds: List(ParamBound),
  cache: LocalCache,
  memo: Memo,
) -> #(Result(#(EffectTerm, option.Option(LookupOrigin)), Nil), Memo) {
  // A same-module (`""`) summary is computed on demand now, hence Fresh and
  // sourced by nothing but this run's analysis; a cross-module one is read from
  // the KB with its recorded origin (Fix E) and the source that wrote it.
  let #(lookup, memo) = case callee.module {
    "" ->
      case
        set.contains(visited, callee.function),
        local_definition(function_map, callee.function, context.package_targets)
      {
        False, NativeDefinition(definition) -> {
          let #(computed, memo) =
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
          #(
            computed
              |> result.replace_error(Nil)
              |> result.map(fn(op) { #(op, effects.Fresh, None) }),
            memo,
          )
        }
        // A recursive producer call — the producer is already on the analysis
        // stack, so this branch contributes the neutral operator (pure over the
        // returned function's callback positions), not [Unknown]. Mirrors the
        // recursive function-reference handling in `build_lift_operator_arg`.
        // Arity comes from the producer's return type; if it isn't a function
        // type, stay conservative.
        True, NativeDefinition(definition) -> #(
          neutral_returned_operator(definition.definition, cache.fn_alias_types)
            |> result.map(fn(op) { #(op, effects.Fresh, None) }),
          memo,
        )
        // A same-module `@external`: there is no body to compute a summary
        // from, so the only thing that can say what it hands back is a
        // declaration. Extraction keys a bare reference with no module, so the
        // name is qualified with the module being walked before the base is
        // asked.
        //
        // The branch is reached for foreign definitions alone, and a foreign
        // name is value-opaque, so the gated lookup can answer here only with a
        // `Declared` summary — no same-module `Fresh` or `Foreign` one leaks
        // through it.
        _, ForeignDefinition -> #(
          knowledge_base_operator(knowledge_base, producer_key(callee, context)),
          memo,
        )
        _, NoLocalDefinition -> #(Error(Nil), memo)
      }
    _ -> #(knowledge_base_operator(knowledge_base, callee), memo)
  }
  case lookup {
    Error(Nil) -> #(Error(Nil), memo)
    Ok(#(operator, summary, source)) ->
      case effect_term.is_ground(operator), summary {
        // Ground operator (no free vars): trusted regardless of origin. A Fresh
        // one is sanitized by this run (callback binders can't have captured a
        // residual); a Closed or Declared one carries no variable to
        // substitute, so the gate's check has nothing left to decide.
        True, _ -> #(Ok(#(operator, source)), memo)
        // Polymorphic: whether the free variables are ones this run may
        // substitute over. One answer per summary kind, so the binding below
        // runs once for every kind that admits it.
        //
        //   - **Fresh**: Fix D guarantees the free vars are the producer's own
        //     params.
        //   - **Closed**: a clause read back from a spec, whose variables are
        //     checked against the producer's real callback parameters here,
        //     where the substitution happens; one naming anything else degrades
        //     to [Unknown] rather than binding against a parameter the clause
        //     never scoped.
        //   - **Declared**: re-checked against the summary's own bounds — the
        //     strict base with no registry and no dotted-variable leniency,
        //     since an assumption's clause answers to its own line alone.
        //     `declared_returns` stamps the tag only for a clause that passes
        //     the same predicate, so the re-check is expected to hold; it
        //     stands so an edit that changed the loader degrades to [Unknown]
        //     rather than substituting over variables nothing scoped.
        False, summary -> {
          let admitted = case summary {
            effects.Fresh -> True
            effects.Closed(bounds:) ->
              clause_is_closed(operator, callee, bounds, registry)
            effects.Declared(bounds:) ->
              effects.unscoped_clause_variables(operator, bounds) == []
          }
          use <- bool.guard(when: !admitted, return: #(Error(Nil), memo))
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
              caller_param_bounds,
              summary,
              cache,
              memo,
            )
          #(Ok(#(bound, source)), memo)
        }
      }
  }
}

// Bind a polymorphic returned operator's free producer-parameter variables to
// the producer call's arguments, reusing the call-site substitution machinery.
// The producer's parameter bounds + a registry that knows its operator params
// come from the summary and the KB/project registry (cross-module) or from its
// glance signature (same-module, keyed by the `""` module so the synthetic
// callee name matches).
fn bind_producer_params(
  operator: EffectTerm,
  callee: types.QualifiedName,
  args: List(types.CallArgument),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  // The enclosing scope's caller bounds (Fix D / D1): when a producer's returned
  // closure applies a *nested* producer with one of the outer producer's params
  // as an argument, these carry the outer param's sentinel bound (`$op$name`) so
  // the nested bind resolves it to the sentinel — keeping it distinct from any
  // residual of the same name. `[]` for a top-level producer resolution.
  caller_param_bounds: List(ParamBound),
  // How the operator was produced, which is what says where its scoping bounds
  // come from on the cross-module path below.
  summary: effects.SummaryOrigin,
  cache: LocalCache,
  memo: Memo,
) -> #(EffectTerm, Memo) {
  // The module/summary branches only *select* the scoping bounds and the
  // registry; the completion synthesis below runs once, after selection, for
  // every summary that reaches binding — a decoupled bound scoping a clause
  // needs it on the same-module path exactly as it does cross-module.
  let #(scoping, effective_registry) = case callee.module {
    "" ->
      case dict.get(function_map, callee.function) {
        Ok(definition) -> {
          // Build a single-entry registry keyed by `""` so operator detection in
          // `bind_variables` lifts operator args (not first-order). It serves
          // detection whatever the summary: a `Declared` summary's carried
          // bounds replace only the scoping list, never the registry.
          let local_registry =
            signatures.from_single_function(
              "",
              definition,
              cache.fn_alias_types,
            )
          // A **Declared** summary — an assumption over this package's own
          // `@external`, whose producer is called from its own module — binds
          // against the bounds its line carries: a written line is the more
          // specific claim, and detection cannot see a bound name differing
          // from the label. `Fresh` and `Closed` scope over the producer's own
          // callback parameters — the canonical set, so the clause is scoped
          // by exactly what the walk that produced it abstracted over.
          // Deliberately so for `Closed` too: a same-module `Closed` clause
          // sits on a function whose definition is right here, and this run's
          // fresh inference replaces such a committed summary anyway.
          let scoping = case summary {
            effects.Declared(bounds:) -> bounds
            effects.Fresh | effects.Closed(..) ->
              cached_callback_params(definition.definition, cache)
              |> list.map(self_referential_bound)
          }
          #(scoping, signatures.merge(registry, local_registry))
        }
        Error(Nil) -> #([], registry)
      }
    _ -> {
      // A **Closed** clause is scoped by the bound list on its own line, and a
      // **Declared** one likewise: the summary's own bounds are authoritative,
      // never the params channel — a clause-only declaration has no entry
      // there, and where an effects declaration for the same name carries
      // different bounds, each must bind against its own. A **Fresh** summary
      // reads the params channel's entry for the name, which holds the
      // girard-typed callbacks no syntactic signature shows.
      let scoping = case summary {
        effects.Closed(bounds:) | effects.Declared(bounds:) -> bounds
        effects.Fresh -> effects.lookup_param_bounds(knowledge_base, callee)
      }
      #(scoping, registry)
    }
  }
  // Completion (Fix B/C-B/E): the scoping bounds omit params that are
  // polymorphic only through the returned closure (inference derives bounds
  // from the *direct* effect, which trims the closure). Every non-dotted free
  // var of the operator names a producer parameter — the gates scope a clause
  // by the line's bound *names* (plus the registry's fn-typed params on the
  // `Closed` path), and a **Fresh** summary is Fix-D-sanitized (free vars ⊆
  // the producer's fn-typed params) — so each one takes a synthesized
  // self-referential bound, appended after the scoping list so its name-keyed
  // binding is the one that stands. `bind_variables` binds a bound's *payload*
  // variables, and a hand-written decoupled list may reuse one parameter's
  // name in another bound's payload (`cb: [e], other: [cb]`) — the clause's
  // `cb` still means the parameter named `cb`, never `other`'s argument. For
  // a machine-written self-referential bound the appended binding repeats the
  // payload's, so nothing moves on machine-written specs, and a synthesized
  // bound matching no argument binds nothing, leaving the payload bindings
  // standing. Field-path (dotted) vars are excluded (they round-trip as field
  // bounds, not producer params).
  let synth =
    effect_term.free_vars(operator)
    |> set.filter(fn(v) { !is_field_path_var(v) })
    |> set.to_list()
    |> list.map(self_referential_bound)
  let bounds = list.append(scoping, synth)
  let lift =
    build_lift_operator_arg(
      context,
      function_map,
      knowledge_base,
      visited,
      registry,
      module_types,
      dict.new(),
      set.new(),
      cache,
    )
  let #(bindings, memo) =
    bind_variables(
      callee,
      bounds,
      args,
      knowledge_base,
      caller_param_bounds,
      effective_registry,
      lift,
      memo,
    )
  #(effect_term.normalize(effect_term.subst(operator, bindings)), memo)
}

// Compute the operator a function returns, for the returned-operator KB and for
// same-module on-demand resolution: classify its return expression and lift it
// with the callback positions of its declared return type. `Error` carries
// which step of the gate failed, because the three are not one outcome: only a
// return type that is provably not a function proves the function returns no
// operator, while a missing annotation or an unresolvable tail leave the
// question open.
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
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(Result(EffectTerm, ReturnedOperatorReason), Memo) {
  // Gate on the return type being *a function* (so there's something to record
  // when called), not specifically operator-shaped — a first-order returned
  // function (`fn make() -> fn() -> Nil`) carries a latent effect too. The
  // callback positions may be empty (a first-order return has no callbacks);
  // `returned_callback_positions` errors only when the return isn't a function.
  let gated = {
    use return_type <- result.try(option.to_result(
      function.return,
      NoReturnAnnotation,
    ))
    use positions <- result.try(
      signatures.returned_callback_positions(return_type, cache.fn_alias_types)
      |> result.replace_error(ReturnIsNotAFunction),
    )
    use value <- result.try(
      extract.return_value(function, context)
      |> result.replace_error(UnresolvedReturnTail),
    )
    Ok(#(positions, value))
  }
  case gated {
    Error(reason) -> #(Error(reason), memo)
    Ok(#(positions, value)) -> {
      let producer_operators =
        signatures.operator_param_shapes(function, cache.fn_alias_types)
      // Every callback parameter of the producer, canonically — girard's
      // included, so a producer whose callback carries no `fn(...)` annotation
      // is abstracted over here as the walk abstracted over it. Covers both
      // seed origins S1 (producer_bounds) and S3 (ambient ops).
      let ordered_params = cached_callback_params(function, cache)
      let producer_params = set.from_list(ordered_params)
      // Fix D S1: seed the producer's params as sentinels (`$op$name`) rather than
      // self-referential, so a residual leaked var of the same name cannot merge
      // with a genuine producer param before rename-back.
      let producer_bounds = list.map(ordered_params, sentinel_bound)
      let lift =
        build_lift_operator_arg(
          context,
          function_map,
          knowledge_base,
          visited,
          registry,
          module_types,
          producer_operators,
          producer_params,
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
      // Fix D steps 3+4: ground every non-sentinel free var (bare residual or any
      // dotted var) to [Unknown], then rename sentinels back to real param names —
      // so the summary's free vars ⊆ the producer's fn-typed params by construction.
      let operator = collapse_and_rename_back(operator, producer_params)
      #(compute_returned_operator_result(operator), memo)
    }
  }
}

// Fix D steps 3+4. Ground every free var that is not a producer *sentinel* to
// [Unknown] — a bare residual left by an unresolvable inner call, and any dotted
// var (no consumer discharges a summary's field var across a producer call) —
// then rename the sentinels back to the producer's real parameter names for
// serialization and consumer name-matching. After this the summary's free vars ⊆
// the producer's fn-typed params, the invariant the completion path relies on.
fn collapse_and_rename_back(
  operator: EffectTerm,
  producer_params: Set(String),
) -> EffectTerm {
  let sentinels =
    producer_params |> set.to_list() |> list.map(sentinel_of) |> set.from_list()
  let collapsed =
    ground_vars(
      operator,
      set.difference(effect_term.free_vars(operator), sentinels),
    )
  let rename =
    producer_params
    |> set.to_list()
    |> list.map(fn(p) { #(sentinel_of(p), TVar(p)) })
    |> dict.from_list()
  effect_term.normalize(effect_term.subst(collapsed, rename))
}

// Classify the lifted return value into the operator a producer records.
fn compute_returned_operator_result(
  operator: EffectTerm,
) -> Result(EffectTerm, ReturnedOperatorReason) {
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
  //   - an application still polymorphic in a producer parameter (`op(cb)` in a
  //     returned zero-argument closure, `TApp(op, …)`): it β-reduces once `op` is
  //     bound to the producer call's argument. Only a *ground* stuck application
  //     (no free vars left to bind) is unusable.
  case operator {
    types.TAbs(_, _) | types.TVar(_) | types.TUnion(_) -> Ok(operator)
    types.TLabels(_) | types.TTop ->
      case operator == effect_term.unknown() {
        True -> Error(UnresolvedReturnTail)
        False -> Ok(operator)
      }
    types.TApp(_, _) ->
      case effect_term.is_ground(operator) {
        True -> Error(UnresolvedReturnTail)
        False -> Ok(operator)
      }
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
  captures: List(#(String, types.ArgumentValue)),
  body: List(Statement),
  positions: List(Int),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  ambient_operators: OperatorShapes,
  // Producer parameters seeded as `$op$`-prefixed sentinels (Fix D), so a residual
  // leaked var can never merge with a genuine producer param of the same name.
  // Empty for every use other than computing a producer's returned-operator summary.
  sentinel_params: Set(String),
  cache: LocalCache,
  memo: Memo,
) -> #(EffectTerm, Memo) {
  // Memoize closure analysis. `use`-desugaring nests each continuation inside the
  // previous one, so a naive walk re-analyses the same closure once per path that
  // reaches it — exponential on a long `use` chain (a record decoder, say). A
  // closure is uniquely identified within a module by its body's source position,
  // and its result depends besides on the lifting `positions`, the in-scope
  // ambient operators, which ancestors are visited, and which of those ambient
  // operators are sentinel-seeded; key by all five.
  let key = #(
    closure_body_start(body),
    positions,
    list.sort(dict.keys(ambient_operators), string.compare),
    list.sort(set.to_list(visited), string.compare),
    list.sort(set.to_list(sentinel_params), string.compare),
  )
  case dict.get(memo.closures, key) {
    Ok(cached) -> #(cached, memo)
    Error(Nil) -> {
      let #(operator, memo) =
        analyze_closure_uncached(
          params,
          captures,
          body,
          positions,
          context,
          function_map,
          knowledge_base,
          visited,
          registry,
          module_types,
          ambient_operators,
          sentinel_params,
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
  captures: List(#(String, types.ArgumentValue)),
  body: List(Statement),
  positions: List(Int),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  ambient_operators: OperatorShapes,
  sentinel_params: Set(String),
  cache: LocalCache,
  memo: Memo,
) -> #(EffectTerm, Memo) {
  // A display name for the synthetic glance function wrapping the closure body,
  // not a call-site sentinel: nothing decodes it, so it stays a plain literal.
  let synthetic =
    Function(
      location: Span(0, 0),
      name: "<closure>",
      publicity: Private,
      parameters: [],
      return: None,
      body:,
    )
  // A closure parameter shadows an enclosing ambient operator of the same name:
  // drop the stale callback positions so calls to the parameter aren't treated
  // as applications of the (differently-shaped) enclosing operator. Shadowing
  // also removes it from `ambient_operators`, so a shadowed producer param is
  // seeded real below (not as a sentinel) — the closure's own binder wins.
  let ambient_operators =
    list.fold(params, ambient_operators, fn(acc, param) {
      dict.delete(acc, param)
    })
  // Which closure parameters to abstract over: those at the operator's callback
  // positions (in order). `positions` is authoritative — derived from the
  // operator parameter's type at the call site — so an empty list means the
  // callback is first-order (no parameters to abstract, its body is the ground
  // effect), not "unknown".
  let callback_params =
    list.filter_map(positions, fn(position) { extract.at(params, position) })
  // Give each callback binder a lexically-unique internal sentinel (keyed by this
  // closure's body position). Body calls to the callback then resolve to its
  // sentinel var, staying distinct from any residual effect variable that happens
  // to share the binder's source name — otherwise the `TAbs` below would capture
  // that residual, hide it from `free_vars`, and silently drop it (unsound). The
  // sentinels are ground out and renamed back to the real names before the
  // abstraction is built.
  let callback_sentinels =
    callback_params
    |> list.map(fn(name) {
      #(name, callback_binder_sentinel(closure_body_start(body), name))
    })
    |> dict.from_list()
  // Seed every closure parameter — and every ambient operator parameter from an
  // enclosing producer — as a bound, so calls to them inside the body resolve to
  // their effect variable (the local-call branch matches on `param_bounds`, and
  // the ambient ones are also flagged as operators). A callback parameter is
  // seeded with its unique sentinel; an ambient operator that is a *producer*
  // parameter (in `sentinel_params`) is seeded with the sentinel effect
  // `$op$name` (Fix D S3); every other closure param stays self-referential.
  let bounds =
    list.append(
      list.map(params, fn(name) {
        case dict.get(callback_sentinels, name) {
          Ok(sentinel) -> ParamBound(name, TVar(sentinel))
          Error(Nil) -> self_referential_bound(name)
        }
      }),
      list.map(dict.keys(ambient_operators), fn(name) {
        case set.contains(sentinel_params, name) {
          True -> sentinel_bound(name)
          False -> self_referential_bound(name)
        }
      }),
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
      captures,
      memo,
    )
  let body_term = union_of(body_pairs)
  // Ground any residual effect variable that collides with a callback binder's
  // source name: with the callback seeded as a sentinel, a surviving real-named
  // free var is an unrelated residual (from an unresolvable inner call), not the
  // callback — grounding it now, while the two are still distinct, keeps the
  // abstraction from capturing and later discharging it.
  let body_term =
    ground_vars(
      body_term,
      set.intersection(
        effect_term.free_vars(body_term),
        set.from_list(callback_params),
      ),
    )
  // Rename each sentinel back to its callback's source name (residuals are ground,
  // so the name is now collision-free), then abstract over the real names in
  // callback order.
  let rename =
    callback_sentinels
    |> dict.to_list()
    |> list.map(fn(pair) { #(pair.1, TVar(pair.0)) })
    |> dict.from_list()
  let body_term = effect_term.subst(body_term, rename)
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
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(EffectTerm, Memo) {
  let function = definition.definition
  // A sibling a declaration answers for is lifted from that declaration, not
  // from the body beside it — the rule a direct same-module call into it
  // already follows — abstracted over its own callback parameters so an
  // application of the lifted operator still reduces.
  //
  // An `@external` has no body to lift at all: walking the empty or fallback
  // body would lift an undeclared one to `[]`, and a caller passing it to a
  // higher-order helper would inherit that `[]` while a direct call to the
  // same name inherits `[Unknown]`.
  //
  // Ordinary Gleam under a module-level `assume` has a body, and walking it is
  // just as wrong: the line is what its callers pay, and a helper that happens
  // not to call the callback it is handed lifts to `λcb. []` — handing a
  // caller a free pass the same line refuses a direct call. The term is the
  // value channel's for that reason, so the sibling reference and a
  // cross-module one read one answer.
  //
  // The bounds name callback parameters the signature does not: a running
  // fallback's girard-typed callback carries no `fn(...)` annotation, and
  // without its binder the term's variable stays free and the application goes
  // stuck.
  use <- bool.lazy_guard(
    when: declares_for_callers(definition, context, knowledge_base),
    return: fn() {
      let qualified = QualifiedName(module: context.module_path, function: name)
      let declared = effects.declared_effects(knowledge_base, qualified)
      let params =
        signatures.ordered_callback_params(
          function,
          cache.fn_alias_types,
          value_channel_bound_names(knowledge_base, qualified),
        )
      #(
        list.fold_right(params, declared, fn(acc, param) {
          types.TAbs(param, acc)
        }),
        memo,
      )
    },
  )
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
            definition,
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
  definition: Definition(Function),
  key: #(String, List(String)),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(EffectTerm, Memo) {
  let function = definition.definition
  // The canonical callback set, in declaration order: a callback carrying no
  // `fn(...)` annotation needs its binder here too, or the lifted term's
  // variable stays free and the application goes stuck.
  let fn_param_names = cached_callback_params(function, cache)
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
      [],
      memo,
    )
  let body_term = union_of(body_pairs)
  let operator =
    list.fold_right(fn_param_names, body_term, fn(acc, param) {
      types.TAbs(param, acc)
    })
  #(operator, Memo(..memo, lifts: dict.insert(memo.lifts, key, operator)))
}

// Whether every free variable of a `where returns` clause is a real callback
// parameter of the producer the clause sits on.
//
// The oracle is the signature registry's fn-typed parameters together with
// `bounds` — the clause's own scoping list, read off the line the clause sits
// on. A callback that girard typed and no syntactic signature shows is admitted
// through that list rather than spuriously rejected, and a variable the line
// never scoped is rejected however the knowledge base happens to key the name:
// the list is the only thing consulted, so a bound another line records for the
// same function cannot widen it. Field-path (dotted) variables round-trip as
// field bounds rather than as producer parameters, so they are not weighed here.
fn clause_is_closed(
  operator: EffectTerm,
  callee: QualifiedName,
  bounds: List(ParamBound),
  registry: SignatureRegistry,
) -> Bool {
  unclosed_clause_variables(operator, callee, bounds, registry) == []
}

// The clause's free variables that name no callback parameter, sorted. Empty
// for a closed clause. The gate binds against it and the spec lint reports
// against it, so the two read one oracle by construction.
//
// A composition over `effects.unscoped_clause_variables`, the strict base the
// declared channel reads whole: on top of the line's own bound names, the
// `Closed` path further admits the registry's fn-typed parameters (a producer
// parameter the line's bounds happen not to record) and excuses dotted
// variables (they round-trip as field bounds, not producer parameters). Both
// are `Closed`-only affordances — a foreign producer has neither a walkable
// signature nor a field-bound story.
pub fn unclosed_clause_variables(
  operator: EffectTerm,
  callee: QualifiedName,
  bounds: List(ParamBound),
  registry: SignatureRegistry,
) -> List(String) {
  let callbacks = signatures.fn_typed_param_names(registry, callee)
  effects.unscoped_clause_variables(operator, bounds)
  |> list.filter(fn(variable) {
    !is_field_path_var(variable) && !set.contains(callbacks, variable)
  })
}

// The parameter names a value channel's bounds state effects over, for the
// binders a lifted operator abstracts over. For one of this package's running
// fallbacks these carry the girard-typed callbacks no syntactic signature
// shows, and for a declared name they carry its synthesized callback share.
//
// The binder has to be the variable the term holds free: where the callback is
// labeled, `fn_typed_param_names_ordered` prefers the label unless a bound
// names the parameter, and a binder named after the label leaves the term's
// variable free, the application stuck, and the result `[Unknown]`.
fn value_channel_bound_names(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Set(String) {
  effects.bound_name_set(effects.value_channel_bounds(knowledge_base, name))
}

// Argument matching
//
// Locate the call argument bound to a named callee parameter — by label, then
// signature position — and resolve an argument value's flat effect.

// Find the argument that matches a given param bound, via the bound's
// own label, then the callee signature's declared label, then the
// parameter's real position. See the body for why the bound's index in
// the bound list is deliberately not used as a fallback.
fn find_matching_arg(
  callee_name: types.QualifiedName,
  bound: ParamBound,
  args: List(types.CallArgument),
  registry: SignatureRegistry,
) -> option.Option(types.CallArgument) {
  find_matching_arg_by_name(callee_name, bound.name, args, registry)
}

fn find_matching_arg_by_name(
  callee_name: types.QualifiedName,
  name: String,
  args: List(types.CallArgument),
  registry: SignatureRegistry,
) -> option.Option(types.CallArgument) {
  // Match the argument bound to this parameter, in order:
  //   1. An argument the caller labelled with the parameter's own name.
  //   2. The callee's signature: an argument carrying the parameter's
  //      declared Gleam label (a labelled call site, `f(with: cb)`), or the
  //      argument at the parameter's real position (a positional call site).
  // We deliberately do not fall back to the bound's index in the bounds
  // list — that's only correct when every parameter has a bound, and
  // silently picks the wrong argument when bounds are sparse. If the
  // registry has no entry, the variable stays unresolved and surfaces as
  // part of the result.
  let by_name = find_arg_by_label(args, name)
  use <- option.lazy_or(by_name)
  use param <- option.then(param_info(callee_name, name, registry))
  let by_param_label = param.label |> option.then(find_arg_by_label(args, _))
  use <- option.lazy_or(by_param_label)
  find_arg_at_position(args, param.position)
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

// Look up the parameter in the callee's signature matching the bound's name.
// Tries the in-body parameter name first (auto-inferred bounds key off the
// name, not the Gleam argument label), then falls back to label matching for
// JSON-sourced signatures where in-body names aren't available. Returns `None`
// when the callee is not in the registry or nothing matches.
fn param_info(
  callee_name: types.QualifiedName,
  param_name: String,
  registry: SignatureRegistry,
) -> option.Option(signatures.ParameterInfo) {
  use params <- option.then(signatures.lookup(registry, callee_name))
  let by_name =
    list.find(params, fn(p) { p.name == Some(param_name) })
    |> option.from_result
  use <- option.lazy_or(by_name)
  list.find(params, fn(p) { p.label == Some(param_name) })
  |> option.from_result
}

// Look up the effects of an argument value. Function references →
// KB lookup, through the boundary that holds foreign code to what declares it
// (so an undeclared `@external` passed as a callback carries the same
// `[Unknown]` a direct call to it does); constructors → pure; local refs
// matching a caller param bound (user-declared or auto-detected fn-typed) →
// that bound's effects; otherwise [Unknown].
fn resolve_argument_effects(
  arg: types.CallArgument,
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
) -> EffectTerm {
  case arg.value {
    types.FunctionRef(name) -> effects.declared_effects(knowledge_base, name)
    types.ConstructorRef -> effect_term.pure()
    types.LocalRef(name) ->
      case list.find(caller_param_bounds, fn(b) { b.name == name }) {
        Ok(bound) -> bound.effects
        Error(Nil) -> effect_term.unknown()
      }
    // A closure in a first-order position contributes nothing here — its body
    // is walked by the enclosing extractor. (Operator positions are handled by
    // `operator_term_for_argument`, which lifts the closure to an operator.)
    types.Closure(_, _, _) -> effect_term.unknown()
    // Branches and returned operators are only resolvable in an operator
    // position (handled by `operator_term_for_argument`); first-order, they're
    // conservative.
    types.Choice(_) -> effect_term.unknown()
    types.ReturnedOperator(_, _) -> effect_term.unknown()
    // A computed receiver's effect is resolved through its return provenance at
    // the forwarding site; first-order, it's conservative.
    types.CallResult(_, _) -> effect_term.unknown()
    types.ReceiverPath(_) -> effect_term.unknown()
    // A constructed record or record-update overlay contributes no callable
    // effect in a first-order position; field forwarding handles it at the
    // receiver argument instead.
    types.Constructed(_) -> effect_term.unknown()
    types.Updated(..) -> effect_term.unknown()
    types.OtherExpression -> effect_term.unknown()
  }
}

// Local call resolution
//
// Resolve same-module calls transitively, memoized over the call-graph SCC
// structure: a collapsible component shares one full-reachability analysis,
// everything else keys precisely on same-SCC ancestors.

fn resolve_unknown_local(
  local_call: LocalCall,
  visited: Set(String),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(List(CollectedCall), Memo) {
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
        sentinel_call(UnresolvedLocalCall(local_call.function), local_call.span)
      #([plain_call(synthetic_call, effect_term.unknown())], memo)
    }
    Ok(local_definition) -> {
      let qualified =
        QualifiedName(
          module: context.module_path,
          function: local_call.function,
        )
      case declares_for_callers(local_definition, context, knowledge_base) {
        // A call into a name a declaration answers for is charged what that
        // declaration states — qualifying the bare name with the current module.
        // A declaration wins; without one (or when the module is unknown) it
        // falls back to the conservative `[Unknown]`, not the `[]` an empty or
        // fallback body would yield.
        True -> #(
          [
            CollectedCall(
              call: types.ResolvedCall(name: qualified, span: local_call.span),
              resolution: foreign_resolution(knowledge_base, qualified),
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
}

// Whether a declaration answers for every caller of a same-module name, so a
// local call is charged it rather than the body beside it.
//
// An `@external` has no body graded may weigh at all. Ordinary Gleam under a
// module-level `assume <module>` line has one, and the line still
// answers for its callers — the body is weighed against that function's own
// budget and against nothing else. Read here so a sibling and a cross-module
// caller, which resolves through the knowledge base, pay the same name the same
// set.
fn declares_for_callers(
  local_definition: Definition(Function),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
) -> Bool {
  foreign_definition(local_definition, context.package_targets)
  || option.is_some(declaration_resolution(
    knowledge_base,
    QualifiedName(
      module: context.module_path,
      function: local_definition.definition.name,
    ),
  ))
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
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(List(CollectedCall), Memo) {
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
        synthetic_fn_typed_bounds(unbound_fn_typed_params(
          local_definition,
          [],
          cache,
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
              [],
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
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(List(CollectedCall), Memo) {
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
  acc: List(CollectedCall),
  scc_set: Set(String),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(List(CollectedCall), Memo) {
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
          [],
          memo,
        )
      #(list.append(acc, member_effects), memo)
    }
    Error(Nil) -> #(acc, memo)
  }
}

// Field-call resolution
//
// Resolve `object.field(args)` calls by a precedence that never resolves a
// receiver by its type alone (that understates when a caller supplies a
// different field value):
//
//   1. A value proven for *this* receiver (a field wired at its construction).
//   2. A hand-written `check f(recv.field: [..])` field bound.
//   3. A hand-written `type Type.field : [..]` line.
//   4. A live parameter root → a receiver-keyed field variable (polymorphic).
//   5. Otherwise → `[Unknown]`.

// The effect a constructor field's value contributes, resolved per receiver. A
// function reference (or a same-module function, qualified by the module under
// inference) resolves via the knowledge base — capturing its param bounds +
// identity when it is effect-polymorphic — and, on a knowledge-base miss, from
// the module's own definitions. A constructor is pure; a closure is analysed
// through `closure_field_operator`; a call result through
// `call_result_field_operator`; anything else is `[Unknown]`.
// `module_functions` is the set of same-module function names a `LocalRef`
// field value may resolve to — each caller narrows it to what is visible at its
// own site.
//
// The knowledge-base source that answered travels out beside the field effect —
// it belongs to the wired value, not inside `TypeFieldEffect`, whose own
// `origin` classifies something else. A value analysed here rather than looked
// up (a closure body, a call result, the module's own definition) is this run's
// analysis, not a source's claim, so it carries no origin.
fn value_field_effect(
  value: types.ArgumentValue,
  module_functions: Set(String),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  function_map: dict.Dict(String, Definition(Function)),
  visited: Set(String),
  registry: SignatureRegistry,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  cache: LocalCache,
  memo: Memo,
) -> #(types.TypeFieldEffect, option.Option(LookupOrigin), Memo) {
  case field_value_function(value, context.module_path, module_functions) {
    // A wired function the knowledge base doesn't hold — the module under
    // inference isn't in it — resolves from its own definition, when that lifts
    // to a ground effect. Everything else stays on the knowledge-base answer,
    // taken through the boundary that holds foreign code to what declares it:
    // an `@external` wired into a field is charged the same `[Unknown]` a call
    // to it is, and `local_function_field_effect` declines to walk its body.
    Some(name) ->
      // Read as the value channel it is: a declaration silent about the wired
      // function's callbacks says nothing about what calling the field does
      // with them, so the term carries a variable for each. A no-op for a
      // foreign name, whose charge carries the same share already.
      case effects.lookup_value_channel(knowledge_base, name) {
        effects.Known(effect, source) -> #(
          known_field_effect(effect, knowledge_base, name),
          Some(effects.origin_of(source)),
          memo,
        )
        effects.Unknown -> {
          let #(local, memo) =
            local_function_field_effect(
              name,
              context,
              function_map,
              knowledge_base,
              visited,
              registry,
              module_types,
              cache,
              memo,
            )
          case local {
            Some(effect) -> #(
              types.TypeFieldEffect(effect, [], None, types.Inferred),
              None,
              memo,
            )
            None -> #(
              known_field_effect(effect_term.unknown(), knowledge_base, name),
              None,
              memo,
            )
          }
        }
      }
    None -> {
      // The default for an unrecognised field value: its argument-value effects
      // with no bounds or source (the `[Unknown]` a plain lookup would give).
      let fallback =
        types.TypeFieldEffect(
          effects.argument_value_effects(knowledge_base, value),
          [],
          None,
          types.Inferred,
        )
      let effect = case value {
        // A field wired to an inline/let-bound closure: analyse its body for the
        // field's effect instead of collapsing to `[Unknown]`.
        types.Closure(params, _captures, body) ->
          types.TypeFieldEffect(
            closure_field_operator(
              params,
              body,
              context,
              function_map,
              knowledge_base,
              module_types,
              cache,
            ),
            [],
            None,
            types.Inferred,
          )
        // A field wired to a bare parameter (a factory threading its own
        // argument into the field): polymorphic in that parameter, so carry the
        // self marker rather than the `[Unknown]` a plain lookup would give —
        // letting the call site forward through it.
        types.LocalRef(_) -> polymorphic_field_effect()
        // A field wired from a *call* (`Options(resolver: disk_resolver())`):
        // resolve the callee's returned-operator summary. `Error` preserves the
        // prior `[Unknown]` behaviour exactly.
        types.CallResult(callee, args) ->
          case
            call_result_field_operator(
              callee,
              args,
              context,
              function_map,
              knowledge_base,
              registry,
              module_types,
              cache,
            )
          {
            Ok(operator) ->
              types.TypeFieldEffect(operator, [], None, types.Inferred)
            Error(Nil) -> fallback
          }
        _ -> fallback
      }
      #(effect, None, memo)
    }
  }
}

// The field effect of a wired function as the knowledge base reports it: a
// concrete effect carries no bounds or source; an effect-polymorphic one keeps
// the wired function's bounds and identity for substitution at the field call.
//
// The bounds are the value channel's, which pair with the term this channel
// reads: a callback variable synthesized into that term binds through a bound
// of the same name, and without it the field call resolves the argument it was
// handed to nothing.
fn known_field_effect(
  field_effects: EffectTerm,
  knowledge_base: KnowledgeBase,
  name: types.QualifiedName,
) -> types.TypeFieldEffect {
  case has_vars(field_effects) {
    False -> types.TypeFieldEffect(field_effects, [], None, types.Inferred)
    True ->
      types.TypeFieldEffect(
        field_effects,
        effects.value_channel_bounds(knowledge_base, name),
        Some(name),
        types.Inferred,
      )
  }
}

// The qualified function a field value refers to, if any: a `FunctionRef`
// directly, or a `LocalRef` naming one of the current module's own functions.
// A `LocalRef` that isn't a module function is a parameter (or other local),
// returned as `None` so the caller treats it as polymorphic. `None` too for
// constructors and inline expressions.
fn field_value_function(
  value: types.ArgumentValue,
  module_path: String,
  module_functions: Set(String),
) -> option.Option(types.QualifiedName) {
  case value {
    types.FunctionRef(name:) -> Some(name)
    types.LocalRef(name:) ->
      case set.contains(module_functions, name) {
        True -> Some(QualifiedName(module_path, name))
        False -> None
      }
    _ -> None
  }
}

fn resolve_field_call(
  field_call: types.FieldCall,
  function: Function,
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  function_map: dict.Dict(String, Definition(Function)),
  visited: Set(String),
  module_types: dict.Dict(#(Int, Int), girard.Type),
  call_args: dict.Dict(#(Int, Int), List(types.CallArgument)),
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  scc_ids: LocalCache,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(Resolution, Memo) {
  // The value proven wired to this field, if any:
  //
  //   - Rule 1: a value proven at this receiver's construction. Concrete
  //     evidence — resolved per receiver, beating any annotation.
  //   - Rule 1, receiver form: the whole receiver is a traced value (a let-bound
  //     call result or a record-update overlay). Read the queried field's value
  //     out of it — grounding a call result through its callee's return
  //     provenance, an overlay field-selectively. An untraceable receiver
  //     (opaque callee, field neither updated nor inherited) proves nothing.
  let proven = case field_call.provenance {
    types.ProvenValue(value) -> Some(Ok(value))
    types.ProvenReceiver(receiver) ->
      Some(field_value_of_receiver(
        receiver,
        field_call.label,
        context,
        knowledge_base,
        function_map,
        registry,
      ))
    types.ParameterRoot(..) | types.Untraceable -> None
  }
  case proven {
    Some(Ok(value)) -> {
      // A field value that is one of the enclosing function's own parameters (a
      // `LocalRef` naming it) is that parameter — even when a module function
      // shares the name, since the parameter shadows it lexically. Excluding
      // these names keeps a proven field value from borrowing a same-named
      // module function's effect (an under-report); the parameter resolves
      // polymorphically instead.
      let caller_param_names = named_function_params(function)
      resolve_proven_field(
        value,
        field_call,
        context,
        knowledge_base,
        function_map,
        visited,
        module_types,
        caller_param_names,
        call_args,
        caller_param_bounds,
        registry,
        scc_ids,
        lift_operator_arg,
        memo,
      )
    }
    // A traced receiver that couldn't be followed leaves the field `[Unknown]`.
    Some(Error(Nil)) -> #(
      Resolution(
        term: effect_term.unknown(),
        reason: Some(UntraceableReceiver),
        origin: None,
        fallback: types.NoFallback,
      ),
      memo,
    )
    None ->
      resolve_unproven_field(
        field_call,
        function,
        context,
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

// The value wired to `label` in a traced receiver: a call result is first
// grounded through `grounded_receiver` — a same-module callee's return
// provenance re-derived, a cross-module one read from the KB — into the record it
// builds; a record-update overlay is read field-selectively (an updated field
// takes its replacement, any other falls through to the base). `Error` when the
// receiver can't ground to a record wiring this field — the field stays
// `[Unknown]`.
fn field_value_of_receiver(
  receiver: types.ArgumentValue,
  label: String,
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  function_map: dict.Dict(String, Definition(Function)),
  registry: SignatureRegistry,
) -> Result(types.ArgumentValue, Nil) {
  use grounded <- result.try(grounded_receiver(
    receiver,
    function_map,
    context,
    knowledge_base,
    registry,
  ))
  value_at_path(grounded, label)
}

// Resolve a field call whose receiver's construction directly wired the queried
// field to `value` (rule 1). Resolves the value's effect per receiver via
// `value_field_effect`, then applies the field call's own arguments — the same
// call-site substitution the `type`-line path uses. Never consults the
// nominal-type index, so a different receiver never borrows this one's value.
fn resolve_proven_field(
  value: types.ArgumentValue,
  field_call: types.FieldCall,
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  function_map: dict.Dict(String, Definition(Function)),
  visited: Set(String),
  module_types: dict.Dict(#(Int, Int), girard.Type),
  caller_param_names: Set(String),
  call_args: dict.Dict(#(Int, Int), List(types.CallArgument)),
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  scc_ids: LocalCache,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(Resolution, Memo) {
  // A name that is one of the enclosing function's parameters resolves to that
  // parameter, not a same-named module function — the parameter shadows it.
  let module_functions =
    set.difference(set.from_list(dict.keys(function_map)), caller_param_names)
  let #(field_effect, origin, memo) =
    value_field_effect(
      value,
      module_functions,
      context,
      knowledge_base,
      function_map,
      visited,
      registry,
      module_types,
      scc_ids,
      memo,
    )
  // A field wired to an `@external` whose Gleam body runs carries that body's
  // effects exactly as a direct call to the same name does, so the field call
  // names the two sources apart too — the origin speaks for the declaration
  // alone. Read off the wired value, which is what the field's effect came
  // from.
  let wired = field_value_function(value, context.module_path, module_functions)
  // The same charge a direct call to the wired name is resolved through, so the
  // field call reports the halves and the cause that call reports: the fallback
  // body apart from the declaration, and — where this build reaches no part of
  // the declaration — the reason that says so instead of a source the
  // `[Unknown]` beside it has ruled out.
  let wired_charge = option.map(wired, foreign_charge(knowledge_base, _))
  let wired_fallback = case wired_charge {
    Some(ForeignCharge(resolution:, ..)) -> resolution.fallback
    None -> types.NoFallback
  }
  // A ground wired term carries no bounds or source of its own; a polymorphic
  // suppressed share beside it still binds at this call site, through the
  // wired name's recorded bounds.
  let field_effect = case
    field_effect.source,
    wired,
    suppressed_share_vars(wired_fallback)
  {
    None, Some(name), True ->
      types.TypeFieldEffect(
        ..field_effect,
        bounds: effects.lookup_param_bounds(knowledge_base, name),
        source: Some(name),
      )
    _, _, _ -> field_effect
  }
  let #(term, resolved_fallback, memo) =
    resolve_field_effect(
      field_effect,
      wired_fallback,
      field_call,
      call_args,
      knowledge_base,
      caller_param_bounds,
      registry,
      lift_operator_arg,
      memo,
    )
  // What the proven path records, read off the term after
  // `resolve_field_effect` has applied the field call's arguments — the point
  // where a `LocalRef` value's polymorphic self marker has become `[Unknown]`
  // if nothing bound it.
  let wired_standing = case wired_charge {
    Some(ForeignCharge(standing:, ..)) -> standing
    None -> effects.DeclarationCharged
  }
  // An external nothing declares is answered by an entry the lookup mints to
  // carry its running fallback, whose origin no source ever claimed. A direct
  // call to the same name reports `an external with no declared effects`, and
  // one name cannot have two provenance stories — so this channel reads it off
  // the same predicate the direct one does.
  let undeclared = case wired {
    Some(name) -> undeclared_external(knowledge_base, name)
    None -> False
  }
  let resolution = case origin, undeclared {
    _, True ->
      substituted(
        standing_provenance(
          Resolution(
            term: field_effect.effects,
            reason: Some(UndeclaredExternal),
            origin: None,
            fallback: resolved_fallback,
          ),
          wired_standing,
        ),
        term,
      )
    // A source answered for the wired value, so an `Unknown` its own term does
    // not state came from applying this call's arguments.
    Some(_), False ->
      substituted(
        standing_provenance(
          Resolution(
            term: field_effect.effects,
            reason: None,
            origin:,
            fallback: resolved_fallback,
          ),
          wired_standing,
        ),
        term,
      )
    None, False ->
      Resolution(
        term:,
        reason: unresolved_value_reason(term),
        origin:,
        fallback: types.NoFallback,
      )
  }
  #(resolution, memo)
}

// The reason a field call whose wired value no source keyed carries, when
// nothing grounded the value's effect.
fn unresolved_value_reason(term: EffectTerm) -> option.Option(UnknownReason) {
  use <- bool.guard(when: !carries_unknown(term), return: None)
  Some(UnresolvedFieldValue)
}

// Whether a term's ground normal form carries the `Unknown` label — the same
// question the violation renderer asks of the effect set it prints.
fn carries_unknown(term: EffectTerm) -> Bool {
  types.contains_unknown(effect_term.to_effect_set(term))
}

// Resolve a field call with no proven value (rule 2 onward): a hand-written
// field bound, then a hand-written field `assume` line (looked up by the receiver's
// nominal type — girard first, then the syntactic parameter annotation), then a
// receiver-keyed field variable for a live parameter root, then `[Unknown]`. A
// construction-inferred nominal entry is never consulted — it holds package-wide
// evidence keyed by type, not proof for this receiver.
// The hand-written `type Type.field` line for a receiver's nominal type, with
// the source that declares it — the first of `keys` a line is written under. A
// construction-inferred entry keyed by the same type does *not* qualify — it is
// package-wide nominal evidence, which must never resolve an unproven receiver.
fn declared_type_field(
  knowledge_base: KnowledgeBase,
  keys: List(#(String, String)),
  field: String,
) -> option.Option(#(types.TypeFieldEffect, LookupOrigin)) {
  option.from_result(
    list.find_map(keys, fn(key) {
      let #(module, type_name) = key
      use field_effect <- result.try(effects.lookup_type_field(
        knowledge_base,
        module,
        type_name,
        field,
      ))
      case field_effect.origin {
        types.Declared(source:) -> Ok(#(field_effect, source))
        types.Inferred -> Error(Nil)
      }
    }),
  )
}

// The keys a receiver's nominal type is looked up under.
//
// girard names the type's defining module, which keys a line exactly. The
// syntactic parameter annotation (`r: Runner`) carries no module — it names a
// type of the module the walk is in — so it keys both by that module, the form
// every spec file writes a shipped line in, and bare, the form of a line written
// without one. Trying only the bare key left a module-qualified line unmatched
// wherever girard holds no type for the receiver: a dependency's own module,
// which girard never annotates, or a function girard could not type.
fn declared_type_field_keys(
  receiver_type: option.Option(#(String, String)),
  module_path: String,
) -> List(#(String, String)) {
  case receiver_type {
    None -> []
    Some(#("", type_name)) -> [#(module_path, type_name), #("", type_name)]
    Some(qualified) -> [qualified]
  }
}

fn resolve_unproven_field(
  field_call: types.FieldCall,
  function: Function,
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  module_types: dict.Dict(#(Int, Int), girard.Type),
  call_args: dict.Dict(#(Int, Int), List(types.CallArgument)),
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(Resolution, Memo) {
  // The canonical receiver — a parameter alias (`let f = options`) resolves
  // through the parameter it stands for — so bound matching, `type`-line lookup,
  // and the field variable all key on the path the bare parameter would use.
  let receiver_object = field_call_receiver(field_call)
  // Rule 2: a hand-written field bound on the enclosing `check` line
  // (`check f(recv.field: [..])`). User-declared, so it wins over the `type`
  // line and the param fallback. The bound's effects are returned verbatim — a
  // concrete effect set, no call-site substitution.
  let field_target = field_call_target(field_call)
  case list.find(caller_param_bounds, fn(b) { b.name == field_target }) {
    Ok(bound) -> #(plain_resolution(bound.effects), memo)
    Error(Nil) -> {
      let receiver_type =
        typeinfo.receiver_type(
          module_types,
          field_call.receiver_span.start,
          field_call.receiver_span.end,
        )
        |> option.lazy_or(fn() {
          syntactic_param_type(function, receiver_object, context)
        })
      // Rule 3: a hand-written `type Type.field` line, resolved by the
      // receiver's nominal type.
      let declared =
        declared_type_field(
          knowledge_base,
          declared_type_field_keys(receiver_type, context.module_path),
          field_call.label,
        )
      case declared {
        Some(#(field_effect, source)) -> {
          let #(term, _fallback, memo) =
            resolve_field_effect(
              field_effect,
              types.NoFallback,
              field_call,
              call_args,
              knowledge_base,
              caller_param_bounds,
              registry,
              lift_operator_arg,
              memo,
            )
          // The line answered, so an `Unknown` its own term does not state came
          // from applying this call's arguments.
          let looked_up =
            Resolution(
              term: field_effect.effects,
              reason: None,
              origin: Some(FieldAssumeOrigin(source:)),
              fallback: types.NoFallback,
            )
          #(substituted(looked_up, term), memo)
        }
        None ->
          resolve_undeclared_field(field_call, receiver_type, context, memo)
      }
    }
  }
}

// Rules 4 and 5, for a field call with no `check` bound, no declared field `assume` line,
// and no proven value.
//
// Rule 4: a receiver rooted at a live parameter stays polymorphic in the field —
// a receiver-keyed field variable that grounds to `[Unknown]` if never bound,
// keyed on the canonical parameter path (an alias `let f = options` resolves to
// `options.field`, not the dead `f.field`). Rule 5: any other receiver
// (untraceable, opaque, computed) is `[Unknown]`. A proven provenance never
// reaches here — `resolve_unproven_field` runs only after the proven path
// declines — and resolves to `[Unknown]` if it somehow does.
// The reason is recorded here, where the receiver's type is in scope: a
// receiver graded could not type at all, and one whose type nothing annotates
// for this field, fail differently and are fixed differently. It is recorded
// whether or not `field_fallback` mints a variable — a bound may still discharge
// it, and the renderer prints the reason only for a set that stayed unknown.
fn resolve_undeclared_field(
  field_call: types.FieldCall,
  receiver_type: option.Option(#(String, String)),
  context: ImportContext,
  memo: Memo,
) -> #(Resolution, Memo) {
  case field_call.provenance {
    types.ParameterRoot(path) -> {
      let reason = case receiver_type {
        None -> ReceiverTypeUnresolved
        Some(#(module, type_name)) -> FieldNotAnnotated(module:, type_name:)
      }
      let #(module, type_name) = option.unwrap(receiver_type, #("", ""))
      #(
        Resolution(
          term: field_fallback(
            path,
            field_call.label,
            module,
            type_name,
            context,
          ),
          reason: Some(reason),
          origin: None,
          fallback: types.NoFallback,
        ),
        memo,
      )
    }
    types.ProvenValue(..) | types.ProvenReceiver(..) | types.Untraceable -> #(
      Resolution(
        term: effect_term.unknown(),
        reason: Some(UntraceableReceiver),
        origin: None,
        fallback: types.NoFallback,
      ),
      memo,
    )
  }
}

// The effect of a field call the type registry couldn't resolve. When the
// receiver's same-module type declares this field as `fn`-typed, the call gets a
// synthetic *field-effect variable* named after the `receiver.field` path — the
// boundary-scoped analog of the self-referential bound a `fn`-typed parameter
// gets. The variable discharges against a `check f(recv.field: [..])` bound (by
// the field-bound match in `resolve_field_call`) or collapses to `[Unknown]`
// when nothing binds it (`collapse_phantom_vars` during infer, the concretize at
// the check boundary, and the consume-side guard in `substitute_at_call_site`).
// `type_name` is `""` for a receiver typed only syntactically (the syntactic
// fallback yields no module), which the same-module set still matches by name.
fn field_fallback(
  object: String,
  label: String,
  module: String,
  type_name: String,
  context: ImportContext,
) -> EffectTerm {
  // A receiver with no clean access path (`make().field` — a call result) gets
  // the computed-receiver sentinel object; never mint a `<expr>.field` variable
  // for it, since no `check` bound can name it and an inferred spec shouldn't
  // carry one.
  let has_path = object != extract.computed_receiver
  // The field registry holds only the current module's types. An imported
  // receiver type sharing a name with a local fn-typed type must not borrow the
  // local field. `module` is the receiver type's defining module (from girard);
  // "" is the syntactic-annotation fallback, matched by name as before.
  let in_scope = module == "" || module == context.module_path
  case has_path && in_scope && is_fn_typed_field(context, type_name, label) {
    True -> TVar(object <> "." <> label)
    False -> effect_term.unknown()
  }
}

// The sentinel variable a construction-inferred field uses when it is wired to a
// bare parameter (the factory's own plumbing): the field's effect is whatever
// that parameter turns out to be, so it stays polymorphic until a receiver
// resolves it. `$` can't appear in a Gleam identifier, so it never collides with
// a real parameter or field name.
const self_field_marker = "$field"

// The construction-inferred field effect for a field wired to a bare parameter:
// polymorphic in that parameter, carried as the self marker so the call site
// resolves it to the receiver-keyed field variable instead of a fixed
// `[Unknown]`. Built here so the marker name stays internal to the checker.
pub fn polymorphic_field_effect() -> types.TypeFieldEffect {
  types.TypeFieldEffect(TVar(self_field_marker), [], None, types.Inferred)
}

// Whether a field of a same-module custom type is `fn`-typed. The registry is
// keyed by `#(type_name, field)`; a `""` type name (syntactic-only receiver
// type) can't be matched against a concrete type, so it never reports `fn`-typed
// — the conservative `[Unknown]` still wins there.
fn is_fn_typed_field(
  context: ImportContext,
  type_name: String,
  field: String,
) -> Bool {
  type_name != "" && set.contains(context.fn_typed_fields, #(type_name, field))
}

// Whether an effect-variable name is a *field-effect* variable — a `recv.field`
// path (the dot distinguishes it from a plain parameter name, which can't carry
// one). Used to collapse such a variable to `[Unknown]` at every boundary where
// it could otherwise leak past the function whose body it belongs to.
fn is_field_path_var(name: String) -> Bool {
  string.contains(name, ".")
}

// Collapse every surviving field-effect variable in `term` to `[Unknown]`.
// Call-site substitution uses the `_except` variant to preserve variables it has
// re-keyed onto the caller's own parameters; every other dotted variable still
// names a callee-local receiver and is conservatively grounded at the boundary.
fn concretize_field_vars(term: EffectTerm) -> EffectTerm {
  concretize_field_vars_except(term, set.new())
}

fn concretize_field_vars_except(
  term: EffectTerm,
  keep: Set(String),
) -> EffectTerm {
  let field_vars =
    term
    |> effect_term.free_vars()
    |> set.filter(is_field_path_var)
    |> fn(vars) { set.difference(vars, keep) }
  case set.is_empty(field_vars) {
    True -> term
    False -> ground_vars(term, field_vars) |> effect_term.normalize()
  }
}

// Resolve a type field's effect. When it carries effect variables and a
// polymorphic source (a function wired into the field), bind those variables to
// the field call's arguments — the same call-site substitution resolved calls
// use. Any variable left unbound collapses to `[Unknown]`.
fn resolve_field_effect(
  field_effect: types.TypeFieldEffect,
  // The wired name's fallback share, rewritten by the same bindings as the
  // term it sits beside — one call, one substitution for both halves.
  fallback: types.FallbackDisposition(EffectTerm),
  field_call: types.FieldCall,
  call_args: dict.Dict(#(Int, Int), List(types.CallArgument)),
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(EffectTerm, types.FallbackDisposition(EffectTerm), Memo) {
  // An *operator*-valued field — a single closure field lifted to `λp. …`, or a
  // *union* of such operators from several construction sites (`pure` wires
  // `λ_. []`, `do` wires `λin. [Unknown]`, …). Apply it to the field call's
  // arguments so the application β-reduces — the reducer distributes over a union
  // of operators, `(f ⊔ g)(x) → f(x) ⊔ g(x)` — instead of leaving the raw
  // operator bounds in the caller's ground effect set. A wired *named* function
  // is never operator-valued, so no fallback share reaches this branch.
  use <- bool.guard(when: is_operator_valued(field_effect.effects), return: #(
    apply_field_operator(
      field_effect.effects,
      call_args_for(call_args, field_call.span),
      knowledge_base,
      caller_param_bounds,
    ),
    fallback,
    memo,
  ))
  case
    has_vars(field_effect.effects) || suppressed_share_vars(fallback),
    field_effect.source
  {
    False, _ -> #(field_effect.effects, fallback, memo)
    True, None -> #(
      concretize(field_effect.effects),
      types.map_fallback(fallback, concretize),
      memo,
    )
    True, Some(source) -> {
      let args = call_args_for(call_args, field_call.span)
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
      let bind = fn(term) { concretize(effect_term.subst(term, bindings)) }
      #(bind(field_effect.effects), types.map_fallback(fallback, bind), memo)
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
  context: ImportContext,
) -> option.Option(#(String, String)) {
  case
    list.find(function.parameters, fn(param) {
      case param.name {
        glance.Named(name) -> name == object
        glance.Discarded(_) -> False
      }
    })
  {
    Ok(glance.FunctionParameter(
      type_: Some(glance.NamedType(name: type_name, module:, ..)),
      ..,
    )) -> annotated_type_module(type_name, module, context)
    _ -> None
  }
}

// The module a parameter's type annotation names, read through the imports of
// the module the annotation is written in.
//
// A qualified annotation (`r: model.Runner`) names the module its alias stands
// for, and an unresolvable alias names nothing — the local registry must not
// claim an imported type's fields. An unqualified one is the module's own type,
// left for the caller to key, unless the module imports a type of that name
// unqualified (`import dep/model.{type Runner}`), which is the same imported
// type written shorter.
fn annotated_type_module(
  type_name: String,
  module: option.Option(String),
  context: ImportContext,
) -> option.Option(#(String, String)) {
  case module {
    Some(alias) ->
      dict.get(context.aliases, alias)
      |> option.from_result
      |> option.map(fn(module_path) { #(module_path, type_name) })
    None ->
      case dict.get(context.unqualified_types, type_name) {
        Ok(imported) -> Some(#(imported.module, imported.function))
        Error(Nil) -> Some(#("", type_name))
      }
  }
}
