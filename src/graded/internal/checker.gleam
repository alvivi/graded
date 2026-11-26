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
import graded/internal/contract
import graded/internal/effect_term
import graded/internal/effects.{type KnowledgeBase}
import graded/internal/extract.{type ImportContext}
import graded/internal/latent
import graded/internal/signatures.{type SignatureRegistry}
import graded/internal/topo
import graded/internal/typedefs
import graded/internal/typeinfo
import graded/internal/types.{
  type CallExplanation, type CheckComponent, type CheckFinding,
  type ClassificationCheck, type Comparison, type ConstructionSite,
  type EffectAnnotation, type EffectTerm, type GradedClassification,
  type LocalCall, type LookupOrigin, type ParamBound, type QualifiedName,
  type Relation, type ResolvedCall, type ReturnedOperatorReason,
  type TypedClassification, type UndecidedReason, type UnknownReason,
  type UnprovedCause, type Violation, type Warning, Agree,
  AliasedBoundVariableWarning, AmbiguousShadowedReceiver, CallExplanation,
  ClassificationCheck, Compared, CompatibleWiredValue, DefinitionDropped,
  Disagree, DotlessReturnsClauseWarning, EffectAnnotation, Effects, Field,
  FieldArityViolation, FieldAssumeOrigin, FieldBoundList, FieldNotAnnotated,
  FieldReturnsClause, FieldSiteViolation, FunctionSkipped,
  MeaninglessBoundWarning, NoKnownEffects, NoResolutionAtSpan,
  NoReturnAnnotation, NoTypedEvidence, NonCallableFieldCheckWarning,
  NonCallableReturnViolation, NotACallTarget, ParamBound, ProvedFieldCall,
  ProvedModuleCall, QualifiedName, ReceiverNotNominal, ReceiverTypeUnknown,
  ReceiverTypeUnresolved, ResolutionMismatch, ReturnIsNotAFunction,
  ReturnsClauseViolation, StaleFunctionAssumeWarning, StaleReturnsClauseWarning,
  SyntaxModule, TUnion, TVar, TypeSelectedModule,
  UnboundAssumeTermVariableWarning, UnbuiltExternal, UncalledFactory,
  UnclosedReturnsClauseWarning, UnconstructedFieldCheckWarning, Undecided,
  UndecidedShadowed, UndeclaredExternal, UndeclaredForeignReturn,
  UnderivableReturnedOperator, UngroundReturnsClauseWarning,
  UnkeyedEffectsShapeWarning, UnknownClauseWarning, UnmatchedCheckWarning,
  UnmatchedFieldAssumeWarning, UnmatchedFieldBoundWarning,
  UnmatchedFieldCheckWarning, UnmatchedFunctionAssumeWarning,
  UnmatchedModuleAssumeWarning, UnmatchedParamBoundWarning,
  UnmatchedReturnsClauseWarning, UnprovedCheck, UnprovedForeignFallback,
  UnresolvedFieldValue, UnresolvedReturnTail, UnsupportedCheckComponent,
  UnsupportedFieldCheckWarning, UntraceableArgument, UntraceableProducer,
  UntraceableReceiver, UntracedFieldValue, Violation, WiredConstructor,
  WiredFunction, WiredLocal, WiredValue,
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
  reading: typeinfo.ModuleReading,
  // The targets the package under analysis is compiled for. Decides which
  // `@external` declarations are ever built, and so which functions are foreign
  // code and which are ordinary Gleam whose body is the only implementation.
  package_targets: types.PackageTargets,
) -> #(List(Violation), List(CheckFinding), List(Warning)) {
  let ModuleContext(context:, cache:, function_map:) =
    module_context(
      module,
      module_path,
      knowledge_base,
      reading,
      package_targets,
    )

  // One memo table threaded across every annotation: same-module callees shared
  // between annotations are analysed once.
  let #(_memo, results) =
    list.map_fold(
      annotations,
      module_memo(module, module_path, knowledge_base, reading, package_targets),
      fn(memo, annotation) {
        let #(result, memo) =
          check_annotation(
            annotation,
            function_map,
            context,
            knowledge_base,
            registry,
            reading,
            cache,
            memo,
          )
        #(memo, result)
      },
    )
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
  reading: typeinfo.ModuleReading,
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
    reading,
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
  reading: typeinfo.ModuleReading,
  // The targets the package under analysis is compiled for. Decides which
  // `@external` declarations are ever built, and so which functions are foreign
  // code and which are ordinary Gleam whose body is the only implementation.
  package_targets: types.PackageTargets,
) -> #(
  List(EffectAnnotation),
  dict.Dict(String, EffectTerm),
  dict.Dict(String, types.ReturnProvenance),
) {
  let ModuleContext(context:, cache:, function_map:) =
    module_context(
      module,
      module_path,
      knowledge_base,
      reading,
      package_targets,
    )

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

  // Every public function, each with its line, the operator it hands back and
  // its provenance read in one walk. One memo table is threaded through every
  // walk.
  let #(_memo, read) =
    list.map_fold(
      public_definitions(module, function_map),
      module_memo(module, module_path, knowledge_base, reading, package_targets),
      fn(memo, definition) {
        let param_bounds =
          dict.get(bounds_map, definition.definition.name)
          |> result.unwrap([])
        let #(one, memo) =
          infer_definition(
            definition,
            param_bounds,
            function_map,
            context,
            knowledge_base,
            registry,
            reading,
            cache,
            memo,
            package_targets,
          )
        #(memo, one)
      },
    )
  #(
    list.map(read, fn(one) { one.annotation }),
    list.filter_map(read, fn(one) {
      result.map(one.returned, fn(operator) {
        #(one.definition.definition.name, operator)
      })
    })
      |> dict.from_list,
    list.filter_map(read, fn(one) {
      use <- bool.guard(when: one.foreign, return: Error(Nil))
      definition_provenance(one.definition, context)
      |> result.map(fn(provenance) {
        #(one.definition.definition.name, provenance)
      })
    })
      |> dict.from_list,
  )
}

// What inference reads off one public function: its line, the operator it
// hands back where its value channel publishes one, and whether it is foreign
// code.
type DefinitionReading {
  DefinitionReading(
    definition: Definition(Function),
    annotation: EffectAnnotation,
    returned: Result(EffectTerm, Nil),
    foreign: Bool,
  )
}

fn infer_definition(
  definition: Definition(Function),
  param_bounds: List(ParamBound),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
  package_targets: types.PackageTargets,
) -> #(DefinitionReading, Memo) {
  // The value channels describe what a function *returns*, which for an
  // `@external` only its foreign implementation decides on the targets it
  // covers. So a foreign function produces neither a returned operator nor
  // provenance here; what its running fallback body hands back is kept beside
  // any declaration (`fallback_operators`), which the lookup joins. A bodyless
  // `@external` is opaque FFI — conservatively `[Unknown]`, not the `[]` its
  // empty body would otherwise infer — and one whose Gleam body runs on
  // another target the package is read on is that `[Unknown]` joined with
  // what the body does there.
  let foreign = foreign_definition(definition, package_targets)
  // Auto-detected fn-typed parameters, so calls to them produce effect
  // variables instead of [Unknown]. The same bounds every other walk of a body
  // uses.
  let fn_typed_params = unbound_fn_typed_params(definition, param_bounds, cache)
  let #(#(returned, effects_term), memo) = case foreign {
    True -> {
      let name =
        QualifiedName(
          module: context.module_path,
          function: definition.definition.name,
        )
      let effects_term = case effects.running_fallback(knowledge_base, name) {
        Some(body) ->
          effect_term.normalize(TUnion([effect_term.unknown(), body]))
        None -> effect_term.unknown()
      }
      #(#(Error(Nil), effects_term), memo)
    }
    False -> {
      // The operator a producer hands back is what its own body builds, so it
      // is computed on the targets that body runs on. Read package-wide, a
      // `@target(erlang)` producer returning a closure over a JavaScript-only
      // external published that unreachable declaration's effect in its
      // `returns` line -- and its `effects` line, narrowed, disagreed.
      use knowledge_base, memo <- walk_body(
        definition,
        package_targets,
        knowledge_base,
        memo,
      )
      let #(returned, memo) =
        compute_returned_operator(
          definition.definition,
          context,
          function_map,
          knowledge_base,
          set.new(),
          registry,
          reading,
          cache,
          memo,
        )
      let #(pairs, memo) =
        collect_effects(
          without_returned_closure(definition.definition),
          function_map,
          context,
          knowledge_base,
          set.new(),
          effective_bounds(param_bounds, fn_typed_params),
          registry,
          reading,
          FunctionFrame,
          cache,
          memo,
        )
      #(#(result.replace_error(returned, Nil), union_of(pairs)), memo)
    }
  }
  let #(effects_term, field_vars) =
    groom_published_term(effects_term, fn_typed_params)
  // The operator this function returns, written as the line's `where returns`
  // clause. The line's own bound list scopes the clause's variables, so they are
  // counted alongside the term's below.
  let returns = option.from_result(returned)
  // If the function's inferred effects or its returned operator reference effect
  // variables (because it calls fn-typed params, or a fn-typed field on an opaque
  // receiver), emit ParamBound entries so the polymorphic signature round-trips
  // correctly. A callback used only inside the returned closure is mentioned by
  // the clause alone, and gets its bound from there.
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
    DefinitionReading(
      definition:,
      annotation: EffectAnnotation(
        kind: Effects,
        function: definition.definition.name,
        params: inferred_params,
        effects: effects_term,
        returns:,
      ),
      returned:,
      foreign:,
    ),
    memo,
  )
}

// A definition's return-value provenance as other modules read it, where it
// traces one, read through the imports built on the targets that build its
// body. Opaque provenance is dropped: a lookup miss is treated as opaque
// anyway.
fn definition_provenance(
  definition: Definition(Function),
  context: ImportContext,
) -> Result(types.ReturnProvenance, Nil) {
  let context =
    definition_imports(
      context,
      definition,
      types.declaration_targets(context.package_targets),
    )
  case extract.return_provenance(definition.definition, context) {
    types.Opaque -> Error(Nil)
    traced -> Ok(extract.exported_provenance(traced, context))
  }
}

// Every public function the package builds, in the order the module first
// lists each name.
fn public_definitions(
  module: Module,
  function_map: dict.Dict(String, Definition(Function)),
) -> List(Definition(Function)) {
  let #(names, _seen) =
    list.fold(module.functions, #([], set.new()), fn(acc, definition) {
      let #(names, seen) = acc
      let name = definition.definition.name
      case
        definition.definition.publicity == glance.Public
        && !set.contains(seen, name)
      {
        True -> #([name, ..names], set.insert(seen, name))
        False -> acc
      }
    })
  list.reverse(names)
  |> list.filter_map(dict.get(function_map, _))
}

fn joined_term(terms: List(EffectTerm)) -> EffectTerm {
  case terms {
    [single] -> single
    _ -> effect_term.normalize(TUnion(terms))
  }
}

// One public name's line as each target's analysis read it, joined into the
// one line the spec states: each read over the published parameters, their
// effects and returned operators joined and their bounds kept. `variants` is
// every definition of the name; each line comes with the definition its target
// builds.
pub fn joined_target_line(
  variants: List(Definition(Function)),
  lines: List(#(Definition(Function), EffectAnnotation)),
) -> Result(EffectAnnotation, Nil) {
  let published = published_parameters(in_source_order(variants))
  let read =
    list.map(lines, fn(pair) {
      let #(definition, line) = pair
      let on_published = on_published_parameters(_, definition, published)
      EffectAnnotation(
        ..line,
        effects: on_published(line.effects),
        returns: option.map(line.returns, on_published),
        params: list.filter_map(line.params, published_bound(
          _,
          definition,
          published,
        )),
      )
    })
  union_of_lines(read)
}

// Lines over one name's same parameters as one: their effects and returned
// operators joined, a returned operator only where every line states one, and
// their bounds kept.
pub fn union_of_lines(
  read: List(EffectAnnotation),
) -> Result(EffectAnnotation, Nil) {
  case read {
    [] -> Error(Nil)
    [single] -> Ok(single)
    [first, ..] -> {
      let returns = case list.all(read, fn(one) { one.returns != None }) {
        True ->
          Some(
            joined_term(option.values(list.map(read, fn(one) { one.returns }))),
          )
        False -> None
      }
      Ok(
        EffectAnnotation(
          ..first,
          effects: joined_term(list.map(read, fn(one) { one.effects })),
          returns:,
          params: list.flat_map(read, fn(one) { one.params }) |> list.unique,
        ),
      )
    }
  }
}

// The names among `names` written more than once, each once, in the order
// each is first written.
pub fn written_more_than_once(names: List(String)) -> List(String) {
  let counts =
    list.fold(names, dict.new(), fn(acc, name) {
      dict.upsert(acc, name, fn(count) { option.unwrap(count, 0) + 1 })
    })
  list.filter(names, fn(name) { dict.get(counts, name) |> result.unwrap(0) > 1 })
  |> list.unique
}

// How many of `lists` hold each value, each list counted once.
pub fn holding_counts(lists: List(List(a))) -> dict.Dict(a, Int) {
  list.fold(lists, dict.new(), fn(counts, one) {
    list.fold(list.unique(one), counts, fn(counts, value) {
      dict.upsert(counts, value, fn(count) { option.unwrap(count, 0) + 1 })
    })
  })
}

// Every label of `labels`, `#(module, type, field)`, by its type and field
// name, each list in the order `set.to_list` reads the labels.
pub fn labels_by_type_field(
  labels: Set(#(String, String, String)),
) -> fn(String, String) -> List(#(String, String, String)) {
  let by_type_field =
    set.to_list(labels)
    |> list.fold(dict.new(), fn(acc, label) {
      dict.upsert(acc, #(label.1, label.2), fn(existing) {
        [label, ..option.unwrap(existing, [])]
      })
    })
  fn(type_name, field) {
    dict.get(by_type_field, #(type_name, field))
    |> result.unwrap([])
    |> list.reverse
  }
}

// Every function `module` defines, beside all its definitions in source
// order.
pub fn module_definitions(
  module: Module,
) -> dict.Dict(String, List(Definition(Function))) {
  list.fold(module.functions, dict.new(), fn(acc, definition) {
    dict.upsert(acc, definition.definition.name, fn(existing) {
      [definition, ..option.unwrap(existing, [])]
    })
  })
  |> dict.map_values(fn(_name, variants) { list.reverse(variants) })
}

// The functions `module` defines once per target, each beside all its
// definitions in source order.
pub fn module_pairs(
  module: Module,
) -> dict.Dict(String, List(Definition(Function))) {
  module_definitions(module)
  |> dict.filter(fn(_name, variants) { list.length(variants) > 1 })
}

// Every definition of `name` among a module's `pairs`, beside the one built on
// `target`.
pub fn pair_variant(
  pairs: dict.Dict(String, List(Definition(Function))),
  name: String,
  target: String,
) -> Result(#(List(Definition(Function)), Definition(Function)), Nil) {
  use variants <- result.try(dict.get(pairs, name))
  extract.built_functions(variants, set.from_list([target]))
  |> list.first
  |> result.map(fn(definition) { #(variants, definition) })
}

// Every definition of `name` in `module` where it defines it once per target,
// beside the one built on `target`.
pub fn target_variant(
  module: Module,
  name: String,
  target: String,
) -> Result(#(List(Definition(Function)), Definition(Function)), Nil) {
  let variants =
    list.filter(module.functions, fn(definition) {
      definition.definition.name == name
    })
  case variants {
    [] | [_] -> Error(Nil)
    _ ->
      extract.built_functions(variants, set.from_list([target]))
      |> list.first
      |> result.map(fn(definition) { #(variants, definition) })
  }
}

// A line over a name's published parameters, its bounds, effects and returned
// operator, read in `definition`'s own parameter names: the inverse of
// publication, by label and then by position.
pub fn in_variant_names(
  variants: List(Definition(Function)),
  definition: Definition(Function),
  line: EffectAnnotation,
) -> EffectAnnotation {
  let renames = variant_renames(variants, definition)
  EffectAnnotation(
    ..line,
    params: list.map(line.params, renamed_bound(_, renames)),
    effects: renamed_term(line.effects, renames),
    returns: option.map(line.returns, renamed_term(_, renames)),
  )
}

// What `explain` read in `definition`'s parameter names stated in the name's
// published ones, as publication states them: its bounds and totals, a
// parameter the published ones lack read as `[Unknown]`, and the calls its
// contributors make.
pub fn explained_in_published_names(
  variants: List(Definition(Function)),
  definition: Definition(Function),
  explained: ExplainResult,
) -> ExplainResult {
  let published = published_parameters(in_source_order(variants))
  let renames = published_renames(variants, definition)
  ExplainResult(
    ..explained,
    blocks: list.map(explained.blocks, fn(block) {
      ExplainedBlock(
        bounds: list.filter_map(block.bounds, published_bound(
          _,
          definition,
          published,
        )),
        total: on_published_parameters(block.total, definition, published),
        explanations: list.map(block.explanations, renamed_explanation(
          _,
          renames,
        )),
      )
    }),
  )
}

// A `check` result read in `definition`'s parameter names stated in the name's
// published ones.
pub fn violation_in_published_names(
  variants: List(Definition(Function)),
  definition: Definition(Function),
  violation: Violation,
) -> Violation {
  let renames = published_renames(variants, definition)
  Violation(
    ..violation,
    declared: renamed_set(violation.declared, renames),
    explanation: renamed_explanation(violation.explanation, renames),
  )
}

pub fn finding_in_published_names(
  variants: List(Definition(Function)),
  definition: Definition(Function),
  finding: CheckFinding,
) -> CheckFinding {
  let renames = published_renames(variants, definition)
  case finding {
    ReturnsClauseViolation(function:, declared:, computed:) ->
      ReturnsClauseViolation(
        function:,
        declared: renamed_term(declared, renames),
        computed: renamed_term(computed, renames),
      )
    NonCallableReturnViolation(function:, declared:) ->
      NonCallableReturnViolation(
        function:,
        declared: renamed_term(declared, renames),
      )
    other -> other
  }
}

// The parameters a line another package wrote over a name it defines once per
// target is stated in: those of the variant `publisher` selects, its own target
// configuration. One named target selects that target's variant, a defaulted
// one the variant a defaulted run reads, and both targets the variant written
// first, with names and labels filled in from the others.
pub fn publisher_parameters(
  variants: List(Definition(Function)),
  publisher: types.PackageTargets,
) -> Result(List(glance.FunctionParameter), Nil) {
  case types.build_targets(publisher) |> set.size {
    1 ->
      extract.built_functions(variants, types.build_targets(publisher))
      |> list.first
      |> result.map(fn(definition) { definition.definition.parameters })
    _ -> Ok(published_parameters(in_source_order(variants)))
  }
}

// The parameters of the one variant `reader` builds, where it builds one.
pub fn reader_parameters(
  variants: List(Definition(Function)),
  reader: types.PackageTargets,
) -> Result(List(glance.FunctionParameter), Nil) {
  case extract.built_functions(variants, types.build_targets(reader)) {
    [definition] -> Ok(definition.definition.parameters)
    _ -> Error(Nil)
  }
}

// An `effects` or `check` line stated over `from`'s parameters, read over
// `to`'s: see `rebased_assume`.
pub fn rebased_line(
  from: List(glance.FunctionParameter),
  to: List(glance.FunctionParameter),
  line: EffectAnnotation,
) -> EffectAnnotation {
  let named =
    bound_variables(line.params)
    |> set.union(effect_term.free_vars(line.effects))
    |> set.union(option_variables(line.returns))
  let Rebasing(bounds:, variable:, ..) = rebasing(from, to, line.params, named)
  EffectAnnotation(
    ..line,
    params: bounds,
    effects: rebased_term(line.effects, variable),
    returns: option.map(line.returns, rebased_term(_, variable)),
  )
}

// The variables an optional term names.
fn option_variables(term: Option(EffectTerm)) -> Set(String) {
  case term {
    Some(term) -> effect_term.free_vars(term)
    None -> set.new()
  }
}

// A line inference stated over `from`'s parameters, read over `to`'s: as
// `rebased_line`, and every variable a parameter of `from` roots renamed with
// that parameter, since an inferred summary names each variable after the
// parameter it stands for. A variable whose parameter `to` has no counterpart
// for reads `[Unknown]`.
pub fn rebased_inferred_line(
  from: List(glance.FunctionParameter),
  to: List(glance.FunctionParameter),
  line: EffectAnnotation,
) -> EffectAnnotation {
  let counterparts = correspondence(from, to)
  let renames =
    dict.fold(counterparts, dict.new(), fn(acc, from, to) {
      case to {
        Some(to) -> dict.insert(acc, from, to)
        None -> acc
      }
    })
  let named =
    list.fold(line.params, effect_term.free_vars(line.effects), fn(acc, bound) {
      set.union(acc, effect_term.free_vars(bound.effects))
    })
    |> set.union(case line.returns {
      Some(operator) -> effect_term.free_vars(operator)
      None -> set.new()
    })
  let substitution =
    set.fold(named, dict.new(), fn(acc, variable) {
      case dict.get(counterparts, bound_parameter(variable)) {
        Ok(Some(_)) ->
          dict.insert(acc, variable, TVar(renamed_path(variable, renames)))
        Ok(None) -> dict.insert(acc, variable, effect_term.unknown())
        Error(Nil) -> acc
      }
    })
  let read = fn(term) {
    effect_term.normalize(effect_term.subst(term, substitution))
  }
  EffectAnnotation(
    ..line,
    params: list.filter_map(line.params, fn(bound) {
      case dict.get(counterparts, bound_parameter(bound.name)) {
        Ok(Some(_)) ->
          Ok(ParamBound(
            name: renamed_path(bound.name, renames),
            effects: read(bound.effects),
          ))
        Ok(None) -> Error(Nil)
        Error(Nil) -> Ok(ParamBound(..bound, effects: read(bound.effects)))
      }
    }),
    effects: read(line.effects),
    returns: option.map(line.returns, read),
  )
}

// An `assume` line stated over `from`'s parameters, read over `to`'s. Each
// bound moves to the parameter of `to` carrying its label where both are
// labelled, else to the one at its position. A parameter `to` has no
// counterpart for loses its bound, and a variable only such bounds introduce
// reads `[Unknown]` wherever the line uses it.
pub fn rebased_assume(
  from: List(glance.FunctionParameter),
  to: List(glance.FunctionParameter),
  line: types.AssumeAnnotation,
) -> types.AssumeAnnotation {
  rebased_assume_view(from, to, line).line
}

// A written `assume` line read in the variant a reader builds, beside how to
// state a name of it in the written line's names: a bound's parameter by the
// parameter it moved from, a variable by its written spelling.
pub type ReaderView {
  ReaderView(
    line: types.AssumeAnnotation,
    parameter: fn(String) -> String,
    variable: fn(String) -> String,
  )
}

// A line read as it is written.
pub fn as_written(line: types.AssumeAnnotation) -> ReaderView {
  ReaderView(line:, parameter: fn(name) { name }, variable: fn(name) { name })
}

// An `assume` line stated over `from`'s parameters, read over `to`'s as
// `rebased_assume` reads it, with the names to state it back in.
pub fn rebased_assume_view(
  from: List(glance.FunctionParameter),
  to: List(glance.FunctionParameter),
  line: types.AssumeAnnotation,
) -> ReaderView {
  let types.LatentContract(runs:, relays:, carries:) = line.contract
  let named =
    bound_variables(line.params)
    |> set.union(option_variables(line.effects))
    |> set.union(option_variables(line.returns))
    |> set.union(option_variables(carries))
    |> set.union(set.from_list(option.unwrap(runs, [])))
    |> set.union(
      list.fold(relays, set.new(), fn(acc, relay) {
        set.insert(acc, relay.callback)
        |> set.union(set.from_list(option.values(relay.positions)))
      }),
    )
  let Rebasing(bounds:, variable:, written_parameter:, written_variable:) =
    rebasing(from, to, line.params, named)
  let line =
    types.AssumeAnnotation(
      ..line,
      params: bounds,
      effects: option.map(line.effects, rebased_term(_, variable)),
      returns: option.map(line.returns, rebased_term(_, variable)),
      contract: types.LatentContract(
        runs: option.map(runs, list.filter_map(_, variable)),
        relays: list.filter_map(relays, fn(relay) {
          use callback <- result.map(variable(relay.callback))
          types.Relay(
            callback:,
            positions: list.map(relay.positions, fn(position) {
              option.then(position, fn(name) {
                option.from_result(variable(name))
              })
            }),
          )
        }),
        carries: option.map(carries, rebased_term(_, variable)),
      ),
    )
  ReaderView(line:, parameter: written_parameter, variable: written_variable)
}

// A written line's bounds moved from `from`'s parameters to `to`'s, how each
// variable it names reads after the move (`Error` where it is lost), and how a
// moved parameter or variable is spelled in the written line.
type Rebasing {
  Rebasing(
    bounds: List(ParamBound),
    variable: fn(String) -> Result(String, Nil),
    written_parameter: fn(String) -> String,
    written_variable: fn(String) -> String,
  )
}

// Each bound moves to the parameter of `to` carrying its label where both are
// labelled, else to the one at its position, keeping the variables its
// payload introduces: a variable is identified by the bound that introduces
// it, wherever the line uses it, and so is every symbol derived from one,
// `e.returns` from `e`. A parameter `to` has no counterpart for loses its
// bound, and a variable only such bounds introduce is lost with the symbols
// derived from it. A variable no bound introduces that names a parameter of
// `from` names that parameter, and moves with it; one naming a parameter `to`
// lacks is lost. A payload variable keeps its spelling unless a moved
// parameter's name would be captured by it or by a symbol derived from it,
// where it and those symbols take a fresh one.
fn rebasing(
  from: List(glance.FunctionParameter),
  to: List(glance.FunctionParameter),
  bounds: List(ParamBound),
  named: Set(String),
) -> Rebasing {
  let counterparts = correspondence(from, to)
  let renames =
    dict.fold(counterparts, dict.new(), fn(acc, from, to) {
      case to {
        Some(to) -> dict.insert(acc, from, to)
        None -> acc
      }
    })
  let kept =
    list.filter_map(bounds, fn(bound) {
      case dict.get(counterparts, bound_parameter(bound.name)) {
        Ok(Some(_)) ->
          Ok(ParamBound(..bound, name: renamed_path(bound.name, renames)))
        Ok(None) -> Error(Nil)
        // A path no parameter of `from` roots is not the line's to move.
        Error(Nil) -> Ok(bound)
      }
    })
  let introduced = bound_variables(bounds)
  let kept_introduced = bound_variables(kept)
  let lost = set.difference(introduced, kept_introduced)
  let moved = fn(variable) {
    case dict.get(counterparts, bound_parameter(variable)) {
      Ok(Some(_)) -> Ok(renamed_path(variable, renames))
      Ok(None) -> Error(Nil)
      Error(Nil) -> Ok(variable)
    }
  }
  let targets =
    set.fold(named, set.new(), fn(acc, variable) {
      case derived_from(variable, introduced), moved(variable) {
        Error(Nil), Ok(name) if name != variable -> set.insert(acc, name)
        _, _ -> acc
      }
    })
  let captured =
    set.fold(targets, set.new(), fn(acc, target) {
      case derived_from(target, kept_introduced) {
        Ok(#(root, _)) -> set.insert(acc, root)
        Error(Nil) -> acc
      }
    })
  let spelled =
    set.union(named, targets)
    |> set.fold(set.new(), fn(acc, name) {
      set.insert(acc, name) |> set.insert(underived(name))
    })
  let fresh =
    set.fold(captured, dict.new(), fn(acc, captured) {
      let avoid = set.union(spelled, set.from_list(dict.values(acc)))
      dict.insert(acc, captured, effect_term.fresh(captured, avoid))
    })
  let variable = fn(name) {
    case derived_from(name, introduced) {
      Ok(#(root, suffix)) ->
        case set.contains(lost, root) {
          True -> Error(Nil)
          False ->
            Ok({ dict.get(fresh, root) |> result.unwrap(root) } <> suffix)
        }
      Error(Nil) -> moved(name)
    }
  }
  let moved_from =
    dict.fold(renames, dict.new(), fn(acc, from, to) {
      dict.insert(acc, to, from)
    })
  let unfresh =
    dict.fold(fresh, dict.new(), fn(acc, written, renamed) {
      dict.insert(acc, renamed, written)
    })
  Rebasing(
    bounds: list.map(kept, fn(bound) {
      ParamBound(..bound, effects: rebased_term(bound.effects, variable))
    }),
    variable:,
    written_parameter: renamed_path(_, moved_from),
    written_variable: fn(name) {
      case derived_from(name, set.from_list(dict.keys(unfresh))) {
        Ok(#(root, suffix)) ->
          { dict.get(unfresh, root) |> result.unwrap(root) } <> suffix
        Error(Nil) -> name
      }
    },
  )
}

// The variable of `introduced` that `name` is or is derived from, beside the
// suffix deriving it: `e.returns` is what callback `e` returns.
fn derived_from(
  name: String,
  introduced: Set(String),
) -> Result(#(String, String), Nil) {
  use <- bool.guard(
    when: set.contains(introduced, name),
    return: Ok(#(name, "")),
  )
  use <- bool.guard(
    when: !string.ends_with(name, types.returns_suffix),
    return: Error(Nil),
  )
  string.drop_end(name, string.length(types.returns_suffix))
  |> derived_from(introduced)
  |> result.map(fn(derived) { #(derived.0, derived.1 <> types.returns_suffix) })
}

// A symbol with every derivation stripped: `e` for `e.returns`.
fn underived(name: String) -> String {
  use <- bool.guard(
    when: !string.ends_with(name, types.returns_suffix),
    return: name,
  )
  underived(string.drop_end(name, string.length(types.returns_suffix)))
}

// A term with each variable read as `variable` says: renamed, or `[Unknown]`
// where lost.
fn rebased_term(
  term: EffectTerm,
  variable: fn(String) -> Result(String, Nil),
) -> EffectTerm {
  let substitution =
    set.fold(effect_term.free_vars(term), dict.new(), fn(acc, name) {
      case variable(name) {
        Ok(renamed) if renamed == name -> acc
        Ok(renamed) -> dict.insert(acc, name, TVar(renamed))
        Error(Nil) -> dict.insert(acc, name, effect_term.unknown())
      }
    })
  case dict.is_empty(substitution) {
    True -> term
    False -> effect_term.normalize(effect_term.subst(term, substitution))
  }
}

// The parameter a bound's path starts at.
fn bound_parameter(name: String) -> String {
  case string.split_once(name, ".") {
    Ok(#(root, _)) -> root
    Error(Nil) -> name
  }
}

fn bound_variables(bounds: List(ParamBound)) -> Set(String) {
  list.fold(bounds, set.new(), fn(acc, bound) {
    set.union(acc, effect_term.free_vars(bound.effects))
  })
}

// Each of `from`'s parameter names beside the name `to` gives the same
// parameter: the one carrying its label where both are labelled, else the one
// at its position; `None` where `to` has no such parameter or discards it.
fn correspondence(
  from: List(glance.FunctionParameter),
  to: List(glance.FunctionParameter),
) -> dict.Dict(String, Option(String)) {
  list.index_fold(from, dict.new(), fn(acc, parameter, index) {
    case parameter.name {
      glance.Discarded(_) -> acc
      glance.Named(name) ->
        dict.insert(acc, name, counterpart_name(parameter, index, to))
    }
  })
}

// The name `to` gives `parameter`, written at `index`: the parameter carrying
// its label, else the one at its position.
fn counterpart_name(
  parameter: glance.FunctionParameter,
  index: Int,
  to: List(glance.FunctionParameter),
) -> Option(String) {
  let at_position = fn() { list.drop(to, index) |> list.first }
  let counterpart = case parameter.label {
    Some(label) ->
      list.find(to, fn(other) { other.label == Some(label) })
      |> result.lazy_or(at_position)
    None -> at_position()
  }
  case counterpart {
    Ok(glance.FunctionParameter(name: glance.Named(other), ..)) -> Some(other)
    _ -> None
  }
}

// Each published parameter's name with the name `definition` gives the same
// parameter: the one carrying its label where both are labelled, else the one
// at its position.
fn variant_renames(
  variants: List(Definition(Function)),
  definition: Definition(Function),
) -> dict.Dict(String, String) {
  let own = definition.definition.parameters
  published_parameters(in_source_order(variants))
  |> list.index_fold(dict.new(), fn(acc, published, index) {
    let counterpart = case published.label {
      Some(label) ->
        list.find(own, fn(parameter) { parameter.label == Some(label) })
        |> result.lazy_or(fn() { list.drop(own, index) |> list.first })
      None -> list.drop(own, index) |> list.first
    }
    case published.name, counterpart {
      glance.Named(from),
        Ok(glance.FunctionParameter(name: glance.Named(to), ..))
      -> dict.insert(acc, from, to)
      _, _ -> acc
    }
  })
}

// Each of `definition`'s parameter names with the published name of the same
// parameter, where it has one.
fn published_renames(
  variants: List(Definition(Function)),
  definition: Definition(Function),
) -> dict.Dict(String, String) {
  parameter_renames(definition, published_parameters(in_source_order(variants)))
  |> dict.fold(dict.new(), fn(acc, from, to) {
    case to {
      Some(to) -> dict.insert(acc, from, to)
      None -> acc
    }
  })
}

// A path whose root parameter `renames` maps, renamed.
fn renamed_path(path: String, renames: dict.Dict(String, String)) -> String {
  let #(root, rest) = case string.split_once(path, ".") {
    Ok(#(root, rest)) -> #(root, "." <> rest)
    Error(Nil) -> #(path, "")
  }
  case dict.get(renames, root) {
    Ok(name) -> name <> rest
    Error(Nil) -> path
  }
}

fn renamed_bound(
  bound: ParamBound,
  renames: dict.Dict(String, String),
) -> ParamBound {
  ParamBound(
    name: renamed_path(bound.name, renames),
    effects: renamed_term(bound.effects, renames),
  )
}

// A term with every free variable rooted at a parameter `renames` maps renamed.
fn renamed_term(
  term: EffectTerm,
  renames: dict.Dict(String, String),
) -> EffectTerm {
  let bindings =
    effect_term.free_vars(term)
    |> set.fold(dict.new(), fn(acc, variable) {
      case renamed_path(variable, renames) {
        renamed if renamed == variable -> acc
        renamed -> dict.insert(acc, variable, TVar(renamed))
      }
    })
  effect_term.subst(term, bindings)
}

fn renamed_set(
  effects: types.EffectSet,
  renames: dict.Dict(String, String),
) -> types.EffectSet {
  case effects {
    types.Polymorphic(labels:, variables:) ->
      types.Polymorphic(
        labels:,
        variables: set.map(variables, renamed_path(_, renames)),
      )
    other -> other
  }
}

// A contributor whose call to a parameter, and whose effects, name parameters
// `renames` maps, renamed.
fn renamed_explanation(
  explanation: types.CallExplanation,
  renames: dict.Dict(String, String),
) -> types.CallExplanation {
  let call = case explanation.call.module == param_sentinel {
    True ->
      QualifiedName(
        ..explanation.call,
        function: renamed_path(explanation.call.function, renames),
      )
    False -> explanation.call
  }
  types.CallExplanation(
    ..explanation,
    call:,
    actual: renamed_set(explanation.actual, renames),
  )
}

// Definitions in the order the source writes them.
fn in_source_order(
  definitions: List(Definition(Function)),
) -> List(Definition(Function)) {
  list.sort(definitions, fn(left, right) {
    int.compare(left.definition.location.start, right.definition.location.start)
  })
}

// The parameters a name defined once per target is published over: those of
// the variant written first, as the signature registry keeps them, each taking
// its name or label from another variant where that one leaves it out.
fn published_parameters(
  variants: List(Definition(Function)),
) -> List(glance.FunctionParameter) {
  case variants {
    [] -> []
    [first, ..later] ->
      list.index_map(first.definition.parameters, fn(parameter, index) {
        let others =
          list.filter_map(later, fn(variant) {
            list.drop(variant.definition.parameters, index) |> list.first
          })
        glance.FunctionParameter(
          ..parameter,
          name: filled_name(parameter.name, others),
          label: option.lazy_or(parameter.label, fn() {
            list.find_map(others, fn(other) {
              option.to_result(other.label, Nil)
            })
            |> option.from_result
          }),
        )
      })
  }
}

// A parameter's name, or the first name `others` give where it is discarded.
fn filled_name(
  name: glance.AssignmentName,
  others: List(glance.FunctionParameter),
) -> glance.AssignmentName {
  case name {
    glance.Named(_) -> name
    glance.Discarded(_) ->
      list.find_map(others, fn(other) {
        case other.name {
          glance.Named(_) -> Ok(other.name)
          glance.Discarded(_) -> Error(Nil)
        }
      })
      |> result.unwrap(name)
  }
}

// The published parameter a variant's parameter is: the one carrying its
// label where both are labelled, else the one at its position.
fn published_parameter(
  parameter: glance.FunctionParameter,
  index: Int,
  published: List(glance.FunctionParameter),
) -> Option(String) {
  let by_label = case parameter.label {
    Some(label) ->
      list.find(published, fn(other) { other.label == Some(label) })
      |> option.from_result
    None -> None
  }
  case
    option.lazy_or(by_label, fn() {
      list.drop(published, index) |> list.first |> option.from_result
    })
  {
    Some(glance.FunctionParameter(name: glance.Named(name), ..)) -> Some(name)
    _ -> None
  }
}

// A variant's term with each of its parameters' variables renamed to the
// published parameter it is, and a parameter that is none read `[Unknown]`.
fn on_published_parameters(
  term: EffectTerm,
  variant: Definition(Function),
  published: List(glance.FunctionParameter),
) -> EffectTerm {
  let renames = parameter_renames(variant, published)
  let bindings =
    effect_term.free_vars(term)
    |> set.fold(dict.new(), fn(acc, variable) {
      let #(root, rest) = case string.split_once(variable, ".") {
        Ok(#(root, rest)) -> #(root, "." <> rest)
        Error(Nil) -> #(variable, "")
      }
      case dict.get(renames, root) {
        Ok(Some(published)) ->
          dict.insert(acc, variable, TVar(published <> rest))
        Ok(None) -> dict.insert(acc, variable, effect_term.unknown())
        Error(Nil) -> acc
      }
    })
  effect_term.subst(term, bindings)
}

fn published_bound(
  bound: ParamBound,
  variant: Definition(Function),
  published: List(glance.FunctionParameter),
) -> Result(ParamBound, Nil) {
  let renames = parameter_renames(variant, published)
  let #(root, rest) = case string.split_once(bound.name, ".") {
    Ok(#(root, rest)) -> #(root, "." <> rest)
    Error(Nil) -> #(bound.name, "")
  }
  case dict.get(renames, root) {
    Ok(Some(name)) ->
      Ok(ParamBound(
        name: name <> rest,
        effects: on_published_parameters(bound.effects, variant, published),
      ))
    Ok(None) -> Error(Nil)
    Error(Nil) -> Ok(bound)
  }
}

// Each named parameter of a variant with the published parameter it is.
fn parameter_renames(
  variant: Definition(Function),
  published: List(glance.FunctionParameter),
) -> dict.Dict(String, Option(String)) {
  list.index_fold(
    variant.definition.parameters,
    dict.new(),
    fn(acc, parameter, index) {
      case parameter.name {
        glance.Named(name) ->
          dict.insert(
            acc,
            name,
            published_parameter(parameter, index, published),
          )
        glance.Discarded(_) -> acc
      }
    },
  )
}

// The return-value provenance `infer_with_returns` records for a module's
// public functions, read through the knowledge base's structural baseline;
// empty where it holds none.
pub fn baseline_provenance(
  module: Module,
  module_path: String,
  knowledge_base: KnowledgeBase,
  package_targets: types.PackageTargets,
) -> dict.Dict(String, types.ReturnProvenance) {
  case effects.structural_baseline_view(knowledge_base) {
    None -> dict.new()
    Some(#(baseline, _modules)) -> {
      let context =
        module_import_context(module, module_path, baseline, package_targets)
      public_definitions(module, build_function_map(module, package_targets))
      |> list.filter_map(fn(definition) {
        use <- bool.guard(
          when: foreign_definition(definition, package_targets),
          return: Error(Nil),
        )
        definition_provenance(definition, context)
        |> result.map(fn(provenance) {
          #(definition.definition.name, provenance)
        })
      })
      |> dict.from_list
    }
  }
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
  reading: typeinfo.ModuleReading,
  // The targets the package under analysis is compiled for. Decides which
  // `@external` declarations are ever built, and so which functions are foreign
  // code and which are ordinary Gleam whose body is the only implementation.
  package_targets: types.PackageTargets,
) -> Result(ExplainResult, Nil) {
  // The lookup comes before the rest of the module analysis, so a name this
  // module does not define costs one map build rather than a whole-module walk.
  // A name defined once per target is explained as each variant the package
  // builds, and the explanations joined.
  let function_map = build_function_map(module, package_targets)
  use definition <- result.map(dict.get(function_map, function_name))
  let declaration =
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
  // The walking apparatus is built only where there is a body to walk.
  let walked = case declaration {
    Some(_) -> None
    None ->
      Some(#(
        module_context(
          module,
          module_path,
          knowledge_base,
          reading,
          package_targets,
        ),
        module_memo(
          module,
          module_path,
          knowledge_base,
          reading,
          package_targets,
        ),
      ))
  }
  explain_definition(
    definition,
    declaration,
    walked,
    module_path,
    bounds,
    knowledge_base,
    registry,
    reading,
  )
}

fn explain_definition(
  variant: Definition(Function),
  declaration: Option(CallExplanation),
  walked: Option(#(ModuleContext, Memo)),
  module_path: String,
  bounds: List(List(ParamBound)),
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
) -> ExplainResult {
  case declaration, walked {
    // A declaration that stands in for the whole function binds no bounds and
    // needs no walking apparatus: answered here, ahead of the call graph and the
    // SCC pass `module_context` builds, and repeated per block unchanged.
    Some(explanation), _ ->
      // No body is walked, so no call of it is classified either.
      ExplainResult(
        blocks: list.map(bounds, fn(bounds) {
          ExplainedBlock(
            bounds:,
            total: effect_term.from_effect_set(explanation.actual),
            explanations: [explanation],
          )
        }),
        classifications: [],
      )
    None, None -> ExplainResult(blocks: [], classifications: [])
    None, Some(#(ModuleContext(context:, cache:, function_map:), memo)) -> {
      // One memo across every bound set, as `check` threads one across every
      // annotation: a callee's own analysis is seeded from its signature, so the
      // caller's bounds neither key it nor reach it.
      let #(_memo, explained) =
        list.map_fold(bounds, memo, fn(memo, bounds) {
          let fn_typed_params = unbound_fn_typed_params(variant, bounds, cache)
          let #(contribution, memo) =
            contributors(
              variant,
              bounds,
              fn_typed_params,
              function_map,
              context,
              knowledge_base,
              registry,
              reading,
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
      // Held outside the per-bounds blocks: the observation is per definition,
      // so a function with three `check` lines states its typed resolutions
      // once rather than once per block.
      ExplainResult(
        blocks: explained,
        classifications: classify_definition(
          variant.definition,
          module_path,
          definition_imports(
            context,
            variant,
            types.declaration_targets(context.package_targets),
          ),
          reading,
        ),
      )
    }
  }
}

// What `explain` answers with: one block per bounds set, plus the typed
// resolution of every ambiguous call lexically in the function — which is per
// definition rather than per bounds set, so it rides beside the blocks rather
// than inside them.
pub type ExplainResult {
  ExplainResult(
    blocks: List(ExplainedBlock),
    classifications: List(ClassificationCheck),
  )
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
  reading: typeinfo.ModuleReading,
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
          reading,
          FunctionFrame,
          cache,
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
    // effects reach it as the walked contributors beside it.
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
  reading: typeinfo.ModuleReading,
  // The targets the package under analysis is compiled for. Decides which
  // `@external` declarations are ever built, and so which functions are foreign
  // code and which are ordinary Gleam whose body is the only implementation.
  package_targets: types.PackageTargets,
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  walk_fallbacks(
    fn(definition, package_targets) {
      foreign_definition(definition, package_targets)
      && runs_fallback_body(definition, package_targets)
    },
    module,
    module_path,
    knowledge_base,
    registry,
    reading,
    package_targets,
  )
}

// What the Gleam fallback body of each of `module`'s own `@external`s hands back,
// where that body runs on the targets the package is read on: the returned
// operator computed over the body on those targets, keyed by bare name. A
// module defining a name once per target is read once for each target, each
// reading selecting the bodies that run there, and the operators joined.
pub fn fallback_operators(
  module: Module,
  module_path: String,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  package_targets: types.PackageTargets,
) -> dict.Dict(String, EffectTerm) {
  use <- bool.guard(
    when: !list.any(module.functions, runs_fallback_body(_, package_targets)),
    return: dict.new(),
  )
  let on = fn(targets) {
    fallback_operators_on(
      module,
      module_path,
      knowledge_base,
      registry,
      reading,
      targets,
    )
  }
  case separate_targets(module, package_targets) {
    [] -> on(package_targets)
    targets ->
      list.map(targets, fn(target) {
        on(types.NamedTargets(set.from_list([target])))
      })
      |> list.fold(dict.new(), joined_operators)
  }
}

// The operators of two readings, by name, each name's joined.
fn joined_operators(
  joined: dict.Dict(String, EffectTerm),
  operators: dict.Dict(String, EffectTerm),
) -> dict.Dict(String, EffectTerm) {
  use joined, name, operator <- dict.fold(operators, joined)
  use existing <- dict.upsert(joined, name)
  case existing {
    Some(other) -> effect_term.normalize(TUnion([other, operator]))
    None -> operator
  }
}

fn fallback_operators_on(
  module: Module,
  module_path: String,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  package_targets: types.PackageTargets,
) -> dict.Dict(String, EffectTerm) {
  let ModuleContext(context:, cache:, function_map:) =
    module_context(
      module,
      module_path,
      knowledge_base,
      reading,
      package_targets,
    )
  let memo =
    module_memo(module, module_path, knowledge_base, reading, package_targets)
  let #(operators, _memo) =
    dict.values(function_map)
    |> list.filter(runs_fallback_body(_, package_targets))
    |> list.fold(#(dict.new(), memo), fn(acc, definition) {
      let #(operators, memo) = acc
      let #(returned, memo) = {
        use knowledge_base, memo <- walk_body(
          definition,
          package_targets,
          knowledge_base,
          memo,
        )
        compute_returned_operator(
          definition.definition,
          context,
          function_map,
          knowledge_base,
          set.new(),
          registry,
          reading,
          cache,
          memo,
        )
      }
      case returned {
        Ok(operator) -> #(
          dict.insert(operators, definition.definition.name, operator),
          memo,
        )
        Error(_) -> #(operators, memo)
      }
    })
  operators
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
// `reading` is girard's reading of this module, taken over the modules the
// fallback pass has a body to walk in — a path dependency's and an installed
// package's alike, both resolved off the consumer's tree. A module girard
// declined passes `no_reading()`, and the walk then takes the syntax-level
// result, what a module it cannot type already falls back to. A shadowed
// receiver is the one site the difference is visible at, since the reading is
// what decides whether it reads the module or the field.
pub fn dependency_fallback_effects(
  module: Module,
  module_path: String,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  package_targets: types.PackageTargets,
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  walk_fallbacks(
    fn(definition, package_targets) {
      extract.declares_external(definition)
      && has_running_fallback(definition, package_targets)
    },
    module,
    module_path,
    knowledge_base,
    registry,
    reading,
    package_targets,
  )
}

// The summaries an aborted walk still owes. An import cycle skips the walk
// entirely, leaving each running fallback the `[Unknown]` an unwalked body
// carries — recorded here with the callback shape the walk would have
// recorded beside it, so a declaration's conservative charge and the call-site
// binding read the same bounds whether the body was walked or not.
// The term carries the callback variables too: an unwalked body may call any
// of them, and a reading that unions this term pays each callback argument's
// effects beside the `[Unknown]`, named where the walk could not name the
// rest.
pub fn unwalked_fallback_effects(
  module: Module,
  reading: typeinfo.ModuleReading,
  package_targets: types.PackageTargets,
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  unwalked_summaries(
    module,
    fn(definition) {
      foreign_definition(definition, package_targets)
      && runs_fallback_body(definition, package_targets)
    },
    reading,
    package_targets,
  )
}

// The same, for a dependency module the walk order dropped for importing
// another in a cycle.
pub fn unwalked_dependency_fallback_effects(
  module: Module,
  package_targets: types.PackageTargets,
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  unwalked_summaries(
    module,
    fn(definition) {
      extract.declares_external(definition)
      && has_running_fallback(definition, package_targets)
    },
    typeinfo.no_reading(),
    package_targets,
  )
}

fn unwalked_summaries(
  module: Module,
  selected: fn(Definition(Function)) -> Bool,
  reading: typeinfo.ModuleReading,
  package_targets: types.PackageTargets,
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  let alias_map = signatures.type_alias_map(module.type_aliases)
  build_function_map(module, package_targets)
  |> dict.values
  |> list.filter(selected)
  |> list.map(fn(definition) {
    let bounds =
      synthetic_fn_typed_bounds(
        set.from_list(callback_params(
          definition.definition,
          alias_map,
          reading.fn_typed,
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

// One summary per name: the join of each target's, beside every bound each of
// them takes.
fn joined_summaries(
  readings: List(dict.Dict(String, #(EffectTerm, List(ParamBound)))),
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  list.fold(readings, dict.new(), fn(acc, reading) {
    dict.fold(reading, acc, fn(acc, name, summary) {
      let #(term, bounds) = summary
      dict.upsert(acc, name, fn(existing) {
        case existing {
          None -> #(term, bounds)
          Some(#(other, other_bounds)) -> #(
            effect_term.normalize(TUnion([other, term])),
            list.unique(list.append(other_bounds, bounds)),
          )
        }
      })
    })
  })
}

// The targets a module is walked on one at a time: each one its package is
// built for, where there are several and the module defines a name once per
// target; none otherwise.
fn separate_targets(
  module: Module,
  package_targets: types.PackageTargets,
) -> List(String) {
  let built = types.build_targets(package_targets)
  case set.size(built) > 1 && defines_per_target(module) {
    True -> set.to_list(built) |> list.sort(string.compare)
    False -> []
  }
}

// Whether anything `module` defines or imports depends on the target it is read
// on: a definition `@target` keeps to some targets, a function whose
// `@external`s leave out a target, or a name its imports bind once per target.
pub fn reads_targets(module: Module) -> Bool {
  list.any(module.functions, fn(definition) {
    extract.gated(definition) || extract.partly_external(definition)
  })
  || list.any(module.constants, extract.gated)
  || list.any(module.type_aliases, extract.gated)
  || list.any(module.custom_types, extract.gated)
  || extract.binds_an_import_name_per_target(module)
}

// Whether `module` defines a public function once per target.
pub fn defines_public_function_per_target(module: Module) -> Bool {
  use <- bool.guard(
    when: !list.any(module.functions, extract.gated),
    return: False,
  )
  let public =
    list.filter_map(module.functions, fn(definition) {
      case definition.definition.publicity {
        glance.Public -> Ok(definition.definition.name)
        glance.Private -> Error(Nil)
      }
    })
    |> set.from_list
  let counts =
    list.fold(module.functions, dict.new(), fn(acc, definition) {
      dict.upsert(acc, definition.definition.name, fn(count) {
        option.unwrap(count, 0) + 1
      })
    })
  dict.fold(counts, False, fn(found, name, count) {
    found || { count > 1 && set.contains(public, name) }
  })
}

// Whether a module defines or imports some name more than once, each binding
// kept on a target by `@target`.
pub fn defines_per_target(module: Module) -> Bool {
  let repeated = fn(names: List(String)) {
    list.length(names) != set.size(set.from_list(names))
  }
  repeated(
    list.map(module.functions, fn(definition) { definition.definition.name }),
  )
  || repeated(
    list.map(module.constants, fn(definition) { definition.definition.name }),
  )
  // Aliases and custom types share one namespace.
  || repeated(list.append(
    list.map(module.type_aliases, fn(definition) { definition.definition.name }),
    list.map(module.custom_types, fn(definition) { definition.definition.name }),
  ))
  || extract.binds_an_import_name_per_target(module)
}

// Summarize each of `targets`, which either selector above chose from
// `module.functions` for the targets it is read on. The whole module comes
// along because a fallback body's unqualified calls are resolved against every
// function beside it — a sibling missing from the map is an unresolved local
// call, charged `[Unknown]`.
fn walk_fallbacks(
  selected: fn(Definition(Function), types.PackageTargets) -> Bool,
  module: Module,
  module_path: String,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  package_targets: types.PackageTargets,
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  use <- bool.guard(
    when: !list.any(module.functions, selected(_, package_targets)),
    return: dict.new(),
  )
  // A module defining a name once per target is walked once for each target,
  // as a run built for that target alone walks it, and the summaries joined:
  // each walk selects the fallbacks that run on its target.
  case separate_targets(module, package_targets) {
    [] ->
      walk_fallbacks_on(
        selected(_, package_targets),
        module,
        module_path,
        knowledge_base,
        registry,
        reading,
        package_targets,
      )
    targets ->
      list.map(targets, fn(target) {
        let on = types.NamedTargets(set.from_list([target]))
        walk_fallbacks_on(
          selected(_, on),
          module,
          module_path,
          knowledge_base,
          registry,
          reading,
          on,
        )
      })
      |> joined_summaries
  }
}

fn walk_fallbacks_on(
  selected: fn(Definition(Function)) -> Bool,
  module: Module,
  module_path: String,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  package_targets: types.PackageTargets,
) -> dict.Dict(String, #(EffectTerm, List(ParamBound))) {
  let ModuleContext(context:, cache:, function_map:) =
    module_context(
      module,
      module_path,
      knowledge_base,
      reading,
      package_targets,
    )
  let targets = dict.values(function_map) |> list.filter(selected)
  // One component at a time, callees first. A body reaching another fallback is
  // charged what the knowledge base says about it, and the call graph already
  // says which fallbacks that can be: a component's members reach only
  // components settled before it, or each other. So a fallback on no cycle is
  // done in one walk, and only a genuine cycle iterates to a fixed point —
  // where every fallback in the module used to be re-walked until the module as
  // a whole stopped changing, at least twice each and once more for every link
  // in the longest chain.
  let recursive = cache.recursive
  // Each component's walk starts from this one memo.
  let memo =
    module_memo(module, module_path, knowledge_base, reading, package_targets)
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
            memo:,
            targets: component,
            function_map:,
            context:,
            cache:,
            module_path:,
            knowledge_base:,
            registry:,
            reading:,
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
    // The memo every group of members starts its walk from.
    memo: Memo,
    targets: List(Definition(Function)),
    function_map: dict.Dict(String, Definition(Function)),
    context: ImportContext,
    cache: LocalCache,
    module_path: String,
    knowledge_base: KnowledgeBase,
    registry: SignatureRegistry,
    reading: typeinfo.ModuleReading,
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
  // Each body on the targets it runs on, because that is what decides how the
  // names it calls read: a member reaching a target-conditional external
  // reaches whichever of its halves is built alongside this body.
  let #(_memo, entries) =
    list.map_fold(walk.targets, walk.memo, fn(memo, variant) {
      // The same synthetic bounds ordinary inference gives a function-typed
      // parameter, so a fallback that calls one is charged that argument's
      // effects rather than the `[Unknown]` an unbound call collapses to. A
      // fallback has no `check` line of its own to declare any, so every one of
      // them is synthesised.
      let fn_typed_params = unbound_fn_typed_params(variant, [], walk.cache)
      let synthetic_bounds = synthetic_fn_typed_bounds(fn_typed_params)
      let #(pairs, memo) = {
        use knowledge_base, memo <- walk_body(
          variant,
          walk.package_targets,
          knowledge_base,
          memo,
        )
        collect_effects(
          without_returned_closure(variant.definition),
          walk.function_map,
          walk.context,
          knowledge_base,
          set.new(),
          synthetic_bounds,
          walk.registry,
          walk.reading,
          FunctionFrame,
          walk.cache,
          memo,
        )
      }
      let #(term, field_vars) =
        groom_published_term(union_of(pairs), fn_typed_params)
      let bounds =
        list.append(
          synthetic_bounds,
          polymorphic_param_bounds(term, field_vars),
        )
      #(memo, #(variant.definition.name, #(term, bounds)))
    })
  dict.from_list(entries)
}

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
  ModuleContext(
    context: ImportContext,
    cache: LocalCache,
    function_map: dict.Dict(String, Definition(Function)),
  )
}

fn module_context(
  module: Module,
  module_path: String,
  knowledge_base: KnowledgeBase,
  reading: typeinfo.ModuleReading,
  package_targets: types.PackageTargets,
) -> ModuleContext {
  let context =
    module_import_context(module, module_path, knowledge_base, package_targets)
  let function_map = build_function_map(module, package_targets)
  let cache = build_scc_ids(module, context, reading.fn_typed)
  ModuleContext(
    context:,
    cache: LocalCache(
      ..cache,
      collapsible: set.filter(cache.collapsible, fn(scc) {
        !crosses_catalog(
          dict.get(cache.members, scc) |> result.unwrap([]),
          context,
          knowledge_base,
        )
      }),
    ),
    function_map:,
  )
}

// Whether the catalog keys any member of a component, which is what takes the
// component's one shared answer away. Collapsing pools every member's effects
// and prices them alike, which holds while the members are mutually reachable;
// a member the catalog answers for is charged that entry instead, cutting its
// edges out of the component, and the pool then prices its callers for code
// none of them reaches. Such a component is walked precisely — the collapse
// only ever bought cost, never an answer.
fn crosses_catalog(
  members: List(String),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
) -> Bool {
  members
  |> list.any(fn(member) {
    case
      declaration_resolution(
        knowledge_base,
        QualifiedName(module: context.module_path, function: member),
      )
    {
      Some(Resolution(origin: Some(origin), ..)) ->
        effects.is_catalog_origin(origin)
      Some(Resolution(origin: None, ..)) | None -> False
    }
  })
}

// The import half of a module's context: the per-module lookup tables a body
// walk reads, with none of the whole-module call-graph analysis `build_scc_ids`
// derives. A pass that recurses into no callee needs only this half.
fn module_import_context(
  module: Module,
  module_path: String,
  knowledge_base: KnowledgeBase,
  package_targets: types.PackageTargets,
) -> ImportContext {
  extract.build_import_context_on(
    module,
    types.declaration_targets(package_targets),
  )
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
}

// Lift a record field wired to an inline closure into an effect *operator*,
// abstracting over every closure parameter. A first-order field
// (`to_error: fn(m) { io.println(m) }`) becomes `λm. [Stdout]` (applying it to
// the field call's argument gives `[Stdout]` back); a higher-order field
// (`run: fn(next) { next() }`) becomes `λnext. [next]` (applying it gives the
// callback's effect). `resolve_field_effect` applies the operator at the field
// call. `function_map` resolves same-module calls, and `reading` carries the
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
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
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
    registry,
    reading,
    dict.new(),
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
// annotated operator params be detected at bind time; `reading` carries the
// enclosing module's own type environment, so a field call in the producer's
// returned closure resolves against girard's types rather than degrading.
fn call_result_field_operator(
  callee: types.QualifiedName,
  args: List(types.CallArgument),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
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
    reading,
    [],
    empty_lexicon(),
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
// The lift runs under the module's own `reading`, the same environment
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
  reading: typeinfo.ModuleReading,
  scc_ids: LocalCache,
  memo: Memo,
) -> #(option.Option(EffectTerm), Memo) {
  use <- bool.guard(name.module != context.module_path, #(None, memo))
  use <- bool.guard(set.contains(visited, name.function), #(None, memo))
  case dict.get(function_map, name.function) {
    Error(Nil) -> #(None, memo)
    Ok(definition) ->
      case
        foreign_definition(definition, walk_targets(context, knowledge_base))
      {
        True -> #(None, memo)
        False -> {
          // A wired value's call supplies no callback the lift binds.
          let #(term, memo) =
            lift_local_function(
              name.function,
              definition,
              [],
              context,
              function_map,
              knowledge_base,
              visited,
              registry,
              reading,
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

const passed_sentinel = "<passes>"

const external_sentinel = "<external>"

const declared_sentinel = "<declared>"

const echo_sentinel = "<echo>"

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
  // What an argument carries, charged because the callee may run it:
  // `argument` names the value as an explanation reads it, `callee` the code it
  // is passed to.
  PassedArgumentCall(argument: String, callee: String)
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
  // An `echo`, which writes to standard error.
  EchoCall
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
    PassedArgumentCall(argument:, callee:) ->
      QualifiedName(passed_sentinel, argument <> "\t" <> callee)
    ReturnedOperatorCall(producer:) ->
      QualifiedName(returned_sentinel, types.dotted_name(producer))
    ExternalDeclaration(name:) -> QualifiedName(external_sentinel, name)
    CallerDeclaration(name:) -> QualifiedName(declared_sentinel, name)
    InlineFunctionCall -> QualifiedName(pipe_sentinel, operator_payload)
    LetBoundValueCall -> QualifiedName(closure_sentinel, applied_payload)
    ComputedValueCall -> QualifiedName(apply_sentinel, unknown_payload)
    EchoCall -> QualifiedName(echo_sentinel, "")
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
    module if module == echo_sentinel -> EchoCall
    module if module == closure_sentinel -> LetBoundValueCall
    module if module == local_sentinel ->
      payload_kind(call.function, UnresolvedLocalCall)
    module if module == passed_sentinel ->
      case string.split_once(call.function, "\t") {
        Ok(#(argument, callee)) -> PassedArgumentCall(argument:, callee:)
        Error(Nil) -> UnclassifiedCall
      }
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
    MeaninglessBoundWarning(function:, param:) ->
      file
      <> ": warning: parameter bound "
      <> param
      <> " on "
      <> function
      <> " names nothing: "
      <> param
      <> " is not a callback, so its bound names what it carries, which takes a single variable"
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
// One ambiguous call's typed resolution, as `graded why` prints it: what girard
// resolved the site to, and how that stands to what graded charged. The two
// halves are both stated whenever they differ, so a reader sees the pair rather
// than a verdict on it.
pub fn format_typed_resolution(check: ClassificationCheck) -> String {
  check.object <> "." <> check.label <> ": " <> typed_resolution_detail(check)
}

// The same row without the site prefix, for a listing that already names the
// site. The wording lives here rather than being reconstructed from the
// formatted line, so `why` and any other surface say one thing about one site.
pub fn typed_resolution_detail(check: ClassificationCheck) -> String {
  case relate(check) {
    NoTypedEvidence(reason:) ->
      "no typed resolution (" <> undecided_reason_text(reason) <> ")"
    Compared(comparison:) ->
      resolution_line(typed_target(check.typed), comparison, check)
  }
}

// The target girard proved, as a row names it. `Undecided` names none, and
// `relate` routes it to the unresolved line before this is ever reached.
fn typed_target(typed: TypedClassification) -> String {
  case typed {
    Undecided(..) -> ""
    ProvedModuleCall(module:, name:) -> "module " <> module <> "." <> name
    ProvedFieldCall(receiver: #(_module, type_name), label:) ->
      "field " <> type_name <> "." <> label
  }
}

// One resolved row: girard's target, then how graded's answer stands to it.
// Both halves are named wherever they differ, so a reader sees the pair rather
// than a verdict on it.
fn resolution_line(
  target: String,
  comparison: Comparison,
  check: ClassificationCheck,
) -> String {
  let standing = case comparison, check.graded {
    // A shadowed call — read as the module, or left as the field — was read
    // *by* this resolution, so the row is one answer stated twice and says so
    // rather than claiming a comparison that did not happen. A field call whose
    // receiver shadows nothing was settled lexically and does compare.
    Agree, TypeSelectedModule(..) | Agree, Field(shadowed: Some(_)) ->
      "decided by the type inference"
    Agree, _ -> "agrees"
    CompatibleWiredValue, _ ->
      "compatible; graded charged " <> graded_target(check)
    Disagree, _ -> "DISAGREES with graded's " <> graded_target(check)
  }
  "typed resolution " <> target <> " (" <> standing <> ")"
}

// graded's half of a row, named as the thing it charged.
fn graded_target(check: ClassificationCheck) -> String {
  case check.graded {
    SyntaxModule(module:) | TypeSelectedModule(module:) ->
      "module call " <> module <> "." <> check.label
    Field(..) -> "field call " <> check.object <> "." <> check.label
    UndecidedShadowed(shadowed:, reason:) ->
      "[Unknown] where "
      <> check.object
      <> " also names "
      <> shadowed
      <> " ("
      <> undecided_reason_text(reason)
      <> ")"
    WiredValue(WiredFunction(name:)) -> "the wired " <> types.dotted_name(name)
    WiredValue(WiredLocal(name:)) -> "the wired " <> name
    WiredValue(WiredConstructor) -> "the wired constructor"
  }
}

// Why girard's answer decided nothing here.
fn undecided_reason_text(reason: UndecidedReason) -> String {
  case reason {
    DefinitionDropped -> "definition dropped for the other build target"
    FunctionSkipped(bucket:) -> "function skipped: " <> bucket
    NoResolutionAtSpan -> "no reference recorded at this span"
    ReceiverTypeUnknown -> "receiver type not fixed at the access"
    NotACallTarget(kind:) -> "not a call target: " <> kind
    ReceiverNotNominal -> "receiver type is not nominal"
    ResolutionMismatch(resolved:) ->
      "resolved to " <> resolved <> ", which is not this site's target"
  }
}

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
    PassedArgumentCall(argument:, callee:) ->
      "passes " <> argument <> " to `" <> callee <> "`, which may run it,"
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
    EchoCall -> "echoes a value"
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
        | AmbiguousShadowedReceiver(..)
        | UntraceableReceiver
        | UnresolvedFieldValue
        | UntraceableProducer -> ""
      }
    FieldAccessCall(..) ->
      case reason {
        FieldNotAnnotated(module:, type_name:) ->
          " of type `"
          <> types.dotted_name(QualifiedName(module:, function: type_name))
          <> "`, which has no effect annotation for that field,"
        ReceiverTypeUnresolved -> ", whose type could not be resolved,"
        // Not "could not be traced": the value may well have been. What is
        // undecided is whether this is a field call at all, and the module it
        // would otherwise be is the other half the reader has to weigh.
        AmbiguousShadowedReceiver(module:, reason:) ->
          ", which also names the module `"
          <> module
          <> "`, and for which the type inference did not establish the module-or-field reading ("
          <> undecided_reason_text(reason)
          <> "),"
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
        NoKnownEffects | UntraceableProducer -> ""
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
        | AmbiguousShadowedReceiver(..)
        | UntraceableReceiver
        | UnresolvedFieldValue
        | UntraceableProducer
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
        NoKnownEffects
        | UndeclaredExternal
        | FieldNotAnnotated(..)
        | ReceiverTypeUnresolved
        | AmbiguousShadowedReceiver(..)
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
    | PassedArgumentCall(..)
    | CallerDeclaration(..)
    | ComputedFieldCall(..)
    | UnresolvedLocalCall(..)
    | InlineFunctionCall
    | LetBoundValueCall
    | ComputedValueCall
    | EchoCall
    | UnclassifiedCall -> ""
  }
}

// The clause for an effect the call site's own argument left unresolved. Shared
// by the kinds that substitute arguments into a resolved term.
const untraceable_argument_clause =
  ", whose effects depend on an argument that could not be resolved,"

// The source that answered, after the effect set it produced.
fn origin_suffix(
  origin: option.Option(LookupOrigin),
  fallback: types.FallbackDisposition(types.EffectSet),
  reason: option.Option(UnknownReason),
) -> String {
  // A running fallback body is a second source, and the origin speaks only for
  // the declaration. Naming it is what stops a declaration of `[]` being read
  // as where a `[Disk]` beside it came from.
  case origin, fallback {
    Some(origin), types.NoFallback ->
      " (from " <> effects.describe_origin(origin) <> ")"
    Some(origin), types.FallbackCharged(_) ->
      " (from "
      <> effects.describe_origin(origin)
      <> ", "
      <> charged_body_clause
      <> ")"
    // No origin and a charged body. Either nothing declared the external, and
    // the `[Unknown]` the call's own clause already names is the union's other
    // half — or a declaration exists and covers no target the calling body runs
    // on, leaving that body as the whole of what was charged.
    None, types.FallbackCharged(_) ->
      case reason {
        Some(UndeclaredExternal) -> " (" <> charged_body_clause <> ")"
        _ ->
          " (from its Gleam fallback body, which is what runs on the targets this one does)"
      }
    None, types.NoFallback -> ""
  }
}

// The clause a running body is named by, worded the same wherever a
// caller-side surface states it.
const charged_body_clause = "unioned with its Gleam fallback body"

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
    types.ProvenValue(_) | types.ProvenReceiver(_) | types.Untraceable ->
      field_call.object
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

// The variables the terms of `calls` name.
fn calls_free_vars(calls: List(CollectedCall)) -> Set(String) {
  list.fold(calls, set.new(), fn(named, one) {
    let term = collected_term(one)
    case has_vars(term) {
      True -> set.union(named, effect_term.free_vars(term))
      False -> named
    }
  })
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
  signatures.slot_names(callback_slots(function, alias_map, girard_fn_typed))
}

// Every callback position of a function, named or not, read from the same two
// sources: `callback_params` is its named part. A lift binds every slot.
fn callback_slots(
  function: Function,
  alias_map: dict.Dict(String, glance.Type),
  girard_fn_typed: dict.Dict(String, Set(String)),
) -> List(signatures.CallbackSlot) {
  signatures.function_callback_slots(
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
  signatures.slot_names(cached_callback_slots(function, cache))
}

// The slots `cached_callback_params` names, nameless ones included, for the
// binders a lift abstracts over.
fn cached_callback_slots(
  function: Function,
  cache: LocalCache,
) -> List(signatures.CallbackSlot) {
  case dict.get(cache.callback_slots, function.name) {
    Ok(slots) -> slots
    // A function the cache was not built over — nothing keys it, so derive it
    // from the same two sources rather than reporting no callbacks.
    Error(Nil) ->
      callback_slots(function, cache.fn_alias_types, cache.girard_fn_typed)
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

// Map a module's functions by name — for transitive same-module resolution —
// keeping, for each name, the definition the package builds. A package read on
// several targets that defines a name once per target is read once for each
// target, so each name here has one definition.
fn build_function_map(
  module: Module,
  package_targets: types.PackageTargets,
) -> dict.Dict(String, Definition(Function)) {
  extract.built_functions(
    module.functions,
    types.build_targets(package_targets),
  )
  |> list.map(fn(definition) { #(definition.definition.name, definition) })
  |> dict.from_list()
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

// `walk` run on the base and the memo `body_walk` gives `definition`.
fn walk_body(
  definition: Definition(Function),
  package_targets: types.PackageTargets,
  knowledge_base: KnowledgeBase,
  memo: Memo,
  walk: fn(KnowledgeBase, Memo) -> #(a, Memo),
) -> #(a, Memo) {
  let #(knowledge_base, memo) =
    body_walk(knowledge_base, memo, definition, package_targets)
  walk(knowledge_base, memo)
}

// `context` with the names its module's imports bind once per target bound for
// the targets `knowledge_base` walks a body on.
fn body_imports(
  context: ImportContext,
  knowledge_base: KnowledgeBase,
) -> ImportContext {
  case knowledge_base.active_targets {
    Some(targets) -> extract.imports_on(context, targets)
    None -> context
  }
}

// `context` with the names its module's imports bind once per target bound for
// the targets of `targets` that build `definition`'s body.
fn definition_imports(
  context: ImportContext,
  definition: Definition(Function),
  targets: Set(String),
) -> ImportContext {
  extract.imports_on(context, body_targets(definition, targets))
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
    // SCC ids that reach themselves: one holding more than a single function,
    // and one whose lone function calls itself. Only these need a fixed point
    // when their fallback bodies are settled — anything else states its
    // summary on the walk that first makes it.
    recursive: Set(Int),
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
    // Each function's callback slots, in declaration order — the two sources
    // above already unioned. Derived here because the collapse decision below
    // needs them for every function anyway, so every later reader is a lookup
    // rather than a second walk of the signature.
    callback_slots: dict.Dict(String, List(signatures.CallbackSlot)),
  )
}

// Index a module's functions by call-graph SCC, recording for each component
// its members, whether it is collapsible, and whether it reaches itself.
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
  let definitions =
    extract.built_functions(
      module.functions,
      types.build_targets(context.package_targets),
    )
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
        callback_slots(definition.definition, fn_alias_types, girard_fn_typed),
      )
    })
  let needs_exact =
    list.filter_map(definitions, fn(definition) {
      let name = definition.definition.name
      // Named callbacks only: a callback it discards leaves its effect the
      // same whatever is passed, so the component still collapses.
      let first_order =
        dict.get(callbacks, name) |> result.map(signatures.slot_names) == Ok([])
      case
        first_order && !foreign_definition(definition, context.package_targets)
      {
        True -> Error(Nil)
        False -> Ok(name)
      }
    })
    |> set.from_list()
  let graph = local_call_graph(definitions, context)
  topo.scc_order(graph)
  |> list.index_fold(
    LocalCache(
      dict.new(),
      dict.new(),
      set.new(),
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
      let recursive = case component {
        [_, _, ..] -> set.insert(cache.recursive, id)
        [only] ->
          case dict.get(graph, only) {
            Ok(edges) ->
              case set.contains(edges, only) {
                True -> set.insert(cache.recursive, id)
                False -> cache.recursive
              }
            Error(Nil) -> cache.recursive
          }
        [] -> cache.recursive
      }
      LocalCache(
        scc_id:,
        members: dict.insert(cache.members, id, component),
        recursive:,
        collapsible:,
        fn_alias_types: cache.fn_alias_types,
        girard_fn_typed: cache.girard_fn_typed,
        callback_slots: cache.callback_slots,
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
    |> list.filter(fn(ancestor) {
      dict.get(cache.scc_id, walked_function(ancestor)) == scc
    })
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
    // The half a running Gleam fallback body contributed to `term`.
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

// A local call's collected calls, with what its arguments carry charged where
// no definition answers for its name: code graded does not see.
fn charge_unseen_local(
  collected: #(List(CollectedCall), Memo),
  local_call: LocalCall,
  function_map: dict.Dict(String, Definition(Function)),
  call_args: dict.Dict(#(Int, Int), List(types.CallArgument)),
  unseen_callee_charge: fn(List(types.CallArgument), Memo) ->
    #(List(ArgumentCharge), Memo),
) -> #(Memo, List(CollectedCall)) {
  let #(calls, memo) = collected
  use <- bool.guard(
    when: local_call.scope == types.ModuleDefinition
      && dict.has_key(function_map, local_call.function),
    return: #(memo, calls),
  )
  let #(charges, memo) =
    unseen_callee_charge(call_args_for(call_args, local_call.span), memo)
  #(memo, list.append(calls, charge_calls(charges, local_call.function)))
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

// What `variant` is to the value channels, where the module defines one.
// The targets a same-module definition is read on from the code being walked:
// those the walk narrowed the knowledge base to, where it did, so a sibling
// `@external` whose declaration leaves those targets out is the ordinary
// Gleam it is there; the package's own otherwise.
fn walk_targets(
  context: ImportContext,
  knowledge_base: KnowledgeBase,
) -> types.PackageTargets {
  case effects.active_targets(knowledge_base) {
    Some(active) ->
      case active == types.declaration_targets(context.package_targets) {
        True -> context.package_targets
        False -> types.NamedTargets(active)
      }
    None -> context.package_targets
  }
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
    types.FallbackCharged(_) -> Resolution(..resolution, fallback:)
    types.NoFallback -> resolution
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
    // The walked bodies of same-module function references' operator lifts,
    // keyed by name + same-SCC ancestors. Each use abstracts one over the
    // binders its own call supplies.
    lifts: dict.Dict(#(String, List(String)), EffectTerm),
    // Closure analyses, keyed by body position, lifting positions, ambient
    // operator names, visited ancestors, and which ambient operators are
    // sentinel-seeded (Fix D) — so a sentinel-flavored analysis never collides
    // with a real-flavored one.
    closures: dict.Dict(
      #(Int, List(Int), List(#(String, Int)), List(String), List(String)),
      EffectTerm,
    ),
    // The targets every entry above was analysed on. Not part of any key —
    // which is why it has to be part of the table: a helper reached from a
    // `@target(erlang)` body and from a `@target(javascript)` one is one name
    // with two answers, and the keys name callees, positions and ancestors
    // alone. Sharing the table across the two let whichever ran first answer
    // for both.
    targets: Option(Set(String)),
    // Whether a same-module name's own reading outranks the catalog's entry for
    // it, keyed by the name. Settled once because the answer is a property of
    // the callee: asked per call site, it re-walked that callee's body under
    // every ancestor set a caller reached it with. A name being weighed is
    // seeded `True`, so a cycle through it charges the catalog rather than
    // recurring.
    catalog_verdicts: dict.Dict(String, Bool),
    // The module under analysis as it reads without the newly loaded
    // packages' structural entries, where the knowledge base records any.
    // A call site whose resolution carries `[Unknown]` is resolved through it
    // too, and takes its answer where that one carries none.
    baseline: Option(BaselineView),
    // The same-module targets of the captures being resolved, outermost
    // first: a capture reached again through one of them is a cycle the call
    // graph does not show, and reads `[Unknown]`.
    capturing: Set(String),
    // The collapsible SCCs whose analysis is under way: one reached again
    // before it is cached is a cycle the call graph does not show, and reads
    // `[Unknown]` rather than being analysed again.
    collapsing: Set(Int),
    // What the type at each span can hold, read once per span and part.
    shapes: latent.ShapeMemo,
    // What the winning written line for each callee says about function
    // values, read once per callee on the knowledge base and targets the memo
    // is filled on.
    contracts: dict.Dict(QualifiedName, Option(latent.CalleeContract)),
    // The same line as what each argument it is handed is charged, read once
    // per callee on the same view.
    declared_lines: dict.Dict(QualifiedName, DeclaredLine),
    // For each function whose walk is under way or done, the variables of its
    // parameters its summary is stated over, in the order a call back into it
    // applies its recursion marker to them.
    recursion_vars: dict.Dict(String, List(String)),
    // For each member of a component analysed as one union, the variables of
    // its parameters that union names, which a call back into it from inside
    // the component contributes, bound to that call's arguments.
    collapsed_vars: dict.Dict(String, List(String)),
    // `member_view` of each member of a component whose union `sccs` holds.
    member_views: dict.Dict(String, List(CollectedCall)),
  )
}

fn new_memo() -> Memo {
  Memo(
    locals: dict.new(),
    sccs: dict.new(),
    lifts: dict.new(),
    closures: dict.new(),
    targets: option.None,
    catalog_verdicts: dict.new(),
    baseline: option.None,
    capturing: set.new(),
    collapsing: set.new(),
    shapes: dict.new(),
    contracts: dict.new(),
    declared_lines: dict.new(),
    recursion_vars: dict.new(),
    collapsed_vars: dict.new(),
    member_views: dict.new(),
  )
}

// One module read without the newly loaded packages' structural entries: the
// import context and module cache built from the knowledge base's baseline,
// the module paths only those packages hold, and a memo of its own. Its memo
// carries no view, so nothing resolved through it is resolved twice.
type BaselineView {
  BaselineView(
    module_path: String,
    context: ImportContext,
    cache: LocalCache,
    modules: Set(String),
    memo: Memo,
  )
}

// A fresh memo for a walk of `module`, with the module's baseline view where
// the knowledge base records a structural baseline.
fn module_memo(
  module: Module,
  module_path: String,
  knowledge_base: KnowledgeBase,
  reading: typeinfo.ModuleReading,
  package_targets: types.PackageTargets,
) -> Memo {
  // Empty, so filled on no target yet: stated as the package's targets, which
  // a body compiled on all of them is walked on without changing views.
  let empty =
    Memo(
      ..new_memo(),
      targets: Some(types.declaration_targets(package_targets)),
    )
  case effects.structural_baseline_view(knowledge_base) {
    None -> empty
    Some(#(baseline, modules)) -> {
      let ModuleContext(context:, cache:, function_map: _) =
        module_context(module, module_path, baseline, reading, package_targets)
      Memo(
        ..empty,
        baseline: Some(BaselineView(
          module_path:,
          context:,
          cache:,
          modules:,
          memo: empty,
        )),
      )
    }
  }
}

// The memo a body walked on `targets` may read: the one in hand where it was
// filled on those same targets, and one holding only its shapes otherwise.
// Emptied rather than keyed per target because a walk stays on one set start
// to finish, so the entries a change strands would not be read again anyway.
// A shape is the join over every target the package is read on, so it holds
// on any of them.
fn memo_on(memo: Memo, targets: Option(Set(String))) -> Memo {
  use <- bool.guard(when: memo.targets == targets, return: memo)
  Memo(
    ..new_memo(),
    targets: targets,
    shapes: memo.shapes,
    recursion_vars: memo.recursion_vars,
    collapsed_vars: memo.collapsed_vars,
    baseline: option.map(memo.baseline, fn(view) {
      BaselineView(..view, memo: memo_on(view.memo, targets))
    }),
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
  let result = extract.extract_function_calls(function, context)
  let local =
    list.filter_map(result.local, fn(call) {
      case call.scope {
        types.ModuleDefinition -> Ok(call.function)
        types.LexicalBinding(..) -> Error(Nil)
      }
    })
  let returned =
    list.filter_map(result.direct_ops, fn(op) {
      case op.callee.module {
        "" -> Ok(op.callee.function)
        _ -> Error(Nil)
      }
    })
  let arguments =
    result.call_args
    |> dict.values()
    |> list.flatten()
  let referenced =
    list.fold(arguments, #([], set.new()), fn(acc, argument) {
      let #(found, seen) = acc
      let #(more, seen) = value_references_at(argument.value, seen)
      #(list.append(more, found), seen)
    }).0
  list.flatten([local, returned, referenced])
  |> set.from_list()
  |> set.intersection(names)
}

// The same-module names reading a value may lift or call, wherever in the
// value they sit: a reference no binding covered, a capture's target, a
// same-module producer, and what a closure or capture captured. A value written
// once is often reached many times — a binding named twice holds its value
// twice — so each component, argument and capture is read once per written
// site, and each closure once per body: the sites in `seen` are skipped, and
// the ones read are added.
fn value_references_at(
  value: types.ArgumentValue,
  seen: Set(#(Int, Int)),
) -> #(List(String), Set(#(Int, Int))) {
  // A span no expression is written at is no site: every value given it is
  // read.
  let within = fn(values: List(#(types.ArgumentValue, #(Int, Int))), seen) {
    list.fold(values, #([], seen), fn(acc, entry) {
      let #(found, seen) = acc
      let #(value, site) = entry
      case site.0 < 0, set.contains(seen, site) {
        False, True -> acc
        True, _ -> {
          let #(more, seen) = value_references_at(value, seen)
          #(list.append(more, found), seen)
        }
        False, False -> {
          let #(more, seen) = value_references_at(value, set.insert(seen, site))
          #(list.append(more, found), seen)
        }
      }
    })
  }
  let components = fn(components: List(types.Component), seen) {
    within(
      list.map(components, fn(component) {
        #(component.value, #(component.span.start, component.span.end))
      }),
      seen,
    )
  }
  let arguments = fn(arguments: List(types.CallArgument), seen) {
    within(
      list.map(arguments, fn(argument) {
        #(argument.value, #(argument.span.start, argument.span.end))
      }),
      seen,
    )
  }
  let captured = fn(captures: List(types.Captured), seen) {
    list.fold(captures, #([], seen), fn(acc, capture) {
      let #(found, seen) = acc
      let #(more, seen) = value_references_at(capture.value, seen)
      #(list.append(more, found), seen)
    })
  }
  case value {
    types.LocalRef(name:, scope: types.ModuleDefinition) -> #([name], seen)
    types.LocalRef(scope: types.LexicalBinding(..), ..) -> #([], seen)
    types.Capture(span:, target:, arguments: fixed, captures:, ..) -> {
      let site = #(span.start, span.end)
      use <- bool.guard(when: set.contains(seen, site), return: #([], seen))
      let #(from_target, seen) =
        value_references_at(target, set.insert(seen, site))
      let #(from_fixed, seen) = arguments(fixed, seen)
      let #(from_captures, seen) = captured(captures, seen)
      #(list.flatten([from_target, from_fixed, from_captures]), seen)
    }
    types.Closure(captures:, body:, ..) -> {
      let site = #(closure_body_start(body), -1)
      case site.0 < 0, set.contains(seen, site) {
        False, True -> #([], seen)
        True, _ -> captured(captures, seen)
        False, False -> captured(captures, set.insert(seen, site))
      }
    }
    types.ReturnedOperator(callee:, args:) | types.CallResult(callee:, args:) -> {
      let producer = case callee.module {
        "" -> [callee.function]
        _ -> []
      }
      let #(from_args, seen) = arguments(args, seen)
      #(list.append(producer, from_args), seen)
    }
    types.Choice(options:) ->
      list.fold(options, #([], seen), fn(acc, option) {
        let #(found, seen) = acc
        let #(more, seen) = value_references_at(option, seen)
        #(list.append(more, found), seen)
      })
    types.Composite(elements:) -> components(elements, seen)
    types.Constructed(components: parts, ..) -> components(parts, seen)
    types.Updated(components: parts, ..) -> components(parts, seen)
    types.ReceiverPath(wired: Some(traced), ..) ->
      value_references_at(traced, seen)
    types.ReceiverPath(wired: None, ..)
    | types.FunctionRef(..)
    | types.ConstructorRef
    | types.OtherExpression -> #([], seen)
  }
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
pub fn has_running_fallback(
  definition: Definition(Function),
  package_targets: types.PackageTargets,
) -> Bool {
  use <- bool.guard(when: definition.definition.body == [], return: False)
  body_targets(definition, types.build_targets(package_targets))
  |> set.is_empty
  |> bool.negate
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

// A `check` line holds for every variant of its function the package builds,
// each walked as itself; a function the module does not define is skipped, as
// the line may be stale or apply to a different build target.
fn check_annotation(
  annotation: EffectAnnotation,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
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
          reading,
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
      let field_bounds =
        list.filter(annotation.params, fn(bound) {
          string.contains(bound.name, ".")
        })
      let field_call_targets = case field_bounds {
        [] -> set.new()
        [_, ..] ->
          extract.extract_function_calls(
            function_definition.definition,
            context,
          ).field
          |> list.map(field_call_target)
          |> set.from_list()
      }
      let unmatched_field_bound_warnings =
        field_bounds
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
        list.append(
          unmatched_field_bound_warnings,
          unmatched_param_bound_warnings,
        )

      let #(findings, memo) =
        check_returns_clause(
          annotation,
          function_definition,
          function_map,
          context,
          knowledge_base,
          registry,
          reading,
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
  reading: typeinfo.ModuleReading,
  package_targets: types.PackageTargets,
) -> FieldSiteReport {
  let ModuleContext(context:, cache:, function_map:) =
    module_context(
      module,
      module_path,
      knowledge_base,
      reading,
      package_targets,
    )
  let module_functions = set.from_list(dict.keys(function_map))
  let #(report, _memo) =
    list.fold(
      module.functions,
      #(
        empty_site_report(),
        module_memo(
          module,
          module_path,
          knowledge_base,
          reading,
          package_targets,
        ),
      ),
      fn(state: #(FieldSiteReport, Memo), definition) {
        let #(report, memo) = state
        // A body no build of this package compiles builds no value: `@target`
        // keeps a definition out of the field pass exactly as it keeps one out
        // of the effects channel, which infers and checks the same function as
        // pure. Weighed anyway, this channel alone charged a site to code that
        // does not exist.
        use <- bool.guard(
          when: !body_is_built(definition, package_targets),
          return: state,
        )
        // And a body that is built is read on the targets it runs on, the same
        // narrowing every other walk of one performs: a site wiring a name the
        // build reaches no declaration of is weighed by what runs there.
        let #(knowledge_base, memo) =
          body_walk(knowledge_base, memo, definition, package_targets)
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
            reading,
            cache,
            memo,
          )
        #(merge_site_reports(report, next), memo)
      },
    )
  report
}

// Whether any build of this package compiles a definition's body.
//
// Read on `declaration_targets`, the wider of the two: this decision *drops* a
// body from the pass, and where the package names no target a `--target` graded
// never sees may still compile it. A body left in is weighed on its own targets;
// one dropped is never weighed at all.
fn body_is_built(
  definition: Definition(Function),
  package_targets: types.PackageTargets,
) -> Bool {
  body_targets(definition, types.declaration_targets(package_targets))
  |> set.is_empty
  |> bool.negate
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
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
) -> #(FieldSiteReport, Memo) {
  let context = body_imports(context, knowledge_base)
  let extracted = extract.extract_function_calls(function, context)
  let parameters = frame_lexicon(function, FunctionFrame)
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
        reading,
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
  parameters: Lexicon,
  module_functions: Set(String),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  function_map: dict.Dict(String, Definition(Function)),
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
) -> #(List(CheckFinding), List(FieldTemplate), Memo) {
  // The enclosing function threads its own argument into the field, so what it
  // wires is whatever its callers pass. Held until the package-wide pass knows
  // whether any call reaches it.
  let from_parameter = case wired.value, wired.through {
    types.LocalRef(name:, scope:), None -> names_binder(parameters, name, scope)
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
    | types.Composite(..), _
    | types.OtherExpression, _
    | types.Capture(..), _
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
          reading,
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
  reading: typeinfo.ModuleReading,
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
      reading,
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
          types.LexicalBinding(..) -> None
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
  reading: typeinfo.ModuleReading,
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
      reading,
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
    types.LocalRef(name:, scope: types.ModuleDefinition) ->
      set.contains(module_functions, name)
    types.LocalRef(scope: types.LexicalBinding(..), ..)
    | types.ConstructorRef
    | types.Choice(..)
    | types.ReceiverPath(..)
    | types.Constructed(..)
    | types.Updated(..)
    | types.Composite(..)
    | types.OtherExpression
    | types.Capture(..) -> False
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
  case source {
    Some(name) ->
      case signatures.lookup(registry, name) {
        // Every bound placed by `param_info`, the lookup a bound's name is
        // resolved against a signature by everywhere else in this file.
        Some(_recorded) ->
          list.fold(bounds, dict.new(), fn(acc, bound) {
            case param_info(name, bound.name, registry) {
              Some(parameter) -> dict.insert(acc, parameter.position, bound)
              None -> acc
            }
          })
        None -> callback_positions(bounds, signature)
      }
    None -> callback_positions(bounds, signature)
  }
}

// The bounds at the field's own callback positions, in order. What a wired name
// no signature records is read by: the value has the field's type, so its
// function-typed parameters are exactly the field's.
fn callback_positions(
  bounds: List(ParamBound),
  signature: types.CallableFieldSignature,
) -> dict.Dict(Int, ParamBound) {
  list.zip(list.map(signature.callbacks, fn(callback) { callback.0 }), bounds)
  |> dict.from_list()
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
  reading: typeinfo.ModuleReading,
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
            reading,
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
              reading,
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
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
) -> #(List(CheckFinding), Memo) {
  let name =
    QualifiedName(module: context.module_path, function: annotation.function)
  // Only whether a Gleam body runs matters here.
  let body_runs = case effects.declared_charge(knowledge_base, name).fallback {
    types.NoFallback -> False
    types.FallbackCharged(_) -> True
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
              reading,
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

// What a body is analysed as: a function on its own, or a closure lifted away
// from where it was written.
type Frame {
  FunctionFrame
  ClosureFrame(
    // The closure's own parameters, bound at `site`.
    params: List(String),
    site: Int,
    // The bindings its body names, as they stood where it was written.
    captures: List(types.Captured),
    // The operator parameters of the enclosing producers in scope, with the
    // binder each one's bound is kept for.
    ambient: OperatorShapes,
    ambient_binders: dict.Dict(String, Int),
  )
}

fn frame_ambient(frame: Frame) -> OperatorShapes {
  case frame {
    FunctionFrame -> dict.new()
    ClosureFrame(ambient:, ..) -> ambient
  }
}

// The parameters a body's references are answered from.
type Lexicon {
  Lexicon(
    // For every parameter a bound in scope is kept for, the offset of its
    // binder: a function's own parameters at its start, a lifted closure's at
    // its body's start, an enclosing producer's operators where that producer
    // binds them.
    binders: dict.Dict(String, Int),
    // The analysed function's own parameters, which its callers bind; none for
    // a lifted closure.
    own: Set(String),
  )
}

// A lexicon no reference names a binder of.
fn empty_lexicon() -> Lexicon {
  Lexicon(binders: dict.new(), own: set.new())
}

fn frame_lexicon(function: Function, frame: Frame) -> Lexicon {
  case frame {
    FunctionFrame -> {
      let own = named_function_params(function)
      Lexicon(
        binders: set.fold(own, dict.new(), fn(acc, name) {
          dict.insert(acc, name, function.location.start)
        }),
        own:,
      )
    }
    ClosureFrame(params:, site:, ambient_binders:, ..) ->
      Lexicon(
        binders: list.fold(params, ambient_binders, fn(acc, name) {
          dict.insert(acc, name, site)
        }),
        own: set.new(),
      )
  }
}

// Whether a reference to `name` under `scope` names the binder the bounds in
// `lexicon` are kept for: a dotted field path by its root's binder. A name no
// binding covered names none.
fn names_binder(
  lexicon: Lexicon,
  name: String,
  scope: types.LocalScope,
) -> Bool {
  case scope {
    types.ModuleDefinition -> False
    types.LexicalBinding(binder:) ->
      dict.get(lexicon.binders, path_root(name)) == Ok(binder)
  }
}

// The first segment of a dotted path.
fn path_root(path: String) -> String {
  case string.split_once(path, ".") {
    Ok(#(root, _)) -> root
    Error(Nil) -> path
  }
}

// The bound a reference to `name` under `scope` reads: the one kept for the
// binder it names, none for any other.
fn reference_bound(
  bounds: List(ParamBound),
  lexicon: Lexicon,
  name: String,
  scope: types.LocalScope,
) -> Result(ParamBound, Nil) {
  use <- bool.guard(
    when: !names_binder(lexicon, name, scope),
    return: Error(Nil),
  )
  list.find(bounds, fn(bound) { bound.name == name })
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
  reading: typeinfo.ModuleReading,
  frame: Frame,
  cache: LocalCache,
  memo: Memo,
) -> #(List(CollectedCall), Memo) {
  let #(calls, memo) =
    collect_view_effects(
      function,
      function_map,
      context,
      knowledge_base,
      visited,
      param_bounds,
      registry,
      reading,
      frame,
      cache,
      memo,
    )
  use view <- with_view_in_reach(memo, context, #(calls, memo))
  // What a site's term may leave free and still publish: the variables the
  // bounds in scope bind, and the enclosing operators' parameters.
  let in_scope =
    list.fold(
      param_bounds,
      set.from_list(dict.keys(frame_ambient(frame))),
      fn(acc, bound) {
        set.union(acc, effect_term.free_vars(bound.effects))
        |> set.insert(bound.name)
      },
    )
  let unresolved =
    list.any(calls, fn(call) {
      unresolved_at_site(call.resolution.term, in_scope)
    })
  case unresolved, effects.structural_baseline_view(knowledge_base) {
    True, Some(#(baseline, _modules)) -> {
      let #(baseline_calls, baseline_memo) =
        collect_view_effects(
          function,
          function_map,
          view.context,
          baseline,
          visited,
          param_bounds,
          signatures.without_modules(registry, view.modules),
          reading,
          frame,
          view.cache,
          view.memo,
        )
      #(
        guarded_calls(calls, baseline_calls, in_scope),
        Memo(..memo, baseline: Some(BaselineView(..view, memo: baseline_memo))),
      )
    }
    False, _ | True, None -> #(calls, memo)
  }
}

// `with_view` applied to the memo's baseline view, where it holds one of the
// module `context` analyses; `otherwise` where it does not.
fn with_view_in_reach(
  memo: Memo,
  context: ImportContext,
  otherwise: a,
  with_view: fn(BaselineView) -> a,
) -> a {
  case memo.baseline {
    Some(view) if view.module_path == context.module_path -> with_view(view)
    Some(_) | None -> otherwise
  }
}

// Each site's resolution, or its counterpart's from the baseline view where
// the site's carries `[Unknown]` and the counterpart's carries none. Sites are
// paired by span, in the order each list reaches them; a site with no
// counterpart keeps its own resolution.
fn guarded_calls(
  calls: List(CollectedCall),
  baseline: List(CollectedCall),
  in_scope: Set(String),
) -> List(CollectedCall) {
  let counterparts =
    list.fold(list.reverse(baseline), dict.new(), fn(acc, call) {
      dict.upsert(acc, site_key(call), fn(existing) {
        [call, ..option.unwrap(existing, [])]
      })
    })
  let #(_unpaired, guarded) =
    list.fold(calls, #(counterparts, []), fn(state, call) {
      let #(counterparts, guarded) = state
      let key = site_key(call)
      case dict.get(counterparts, key) {
        Ok([counterpart, ..rest]) -> #(dict.insert(counterparts, key, rest), [
          guarded_call(call, counterpart, in_scope),
          ..guarded
        ])
        Ok([]) | Error(Nil) -> #(counterparts, [call, ..guarded])
      }
    })
  list.reverse(guarded)
}

fn guarded_call(
  call: CollectedCall,
  counterpart: CollectedCall,
  in_scope: Set(String),
) -> CollectedCall {
  use <- bool.guard(
    when: unresolved_at_site(call.resolution.term, in_scope)
      && !unresolved_at_site(counterpart.resolution.term, in_scope),
    return: counterpart,
  )
  call
}

// Whether a site's term carries `[Unknown]` once published: the label itself,
// or a free variable nothing in scope binds, which publication grounds to it.
// A field-path variable is a receiver's field, bound at a caller.
fn unresolved_at_site(term: EffectTerm, in_scope: Set(String)) -> Bool {
  carries_unknown(groom_published_term(term, in_scope).0)
}

fn site_key(call: CollectedCall) -> #(Int, Int) {
  #(call.call.span.start, call.call.span.end)
}

// Whether a returned operator carries `[Unknown]`: anywhere in it, an
// operator's body included, or as a free variable none of the producer's own
// parameters names.
fn unresolved_operator(operator: EffectTerm, in_scope: Set(String)) -> Bool {
  states_unknown(operator)
  || has_top(operator)
  || !set.is_subset(effect_term.free_vars(operator), in_scope)
}

// Whether the wildcard appears anywhere in a term.
fn has_top(term: EffectTerm) -> Bool {
  case term {
    types.TTop -> True
    types.TLabels(_) | TVar(_) -> False
    types.TApp(operator, argument) -> has_top(operator) || has_top(argument)
    types.TAbs(_param, body) -> has_top(body)
    TUnion(terms) -> list.any(terms, has_top)
  }
}

fn collect_view_effects(
  function: Function,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  // A function on its own, or a closure lifted away from where it was written:
  // its parameters, the bindings it captured, and the operator parameters in
  // scope from an *enclosing* producer, so a call to one becomes a curried
  // operator application rather than `[Unknown]`.
  frame: Frame,
  // Memoized same-module body analyses, keyed by function name. Lets the local-
  // call path resolve a cacheable callee in O(1) instead of re-walking its body.
  cache: LocalCache,
  // Threaded memo state, extended as memoizable sub-analyses are computed.
  memo: Memo,
) -> #(List(CollectedCall), Memo) {
  let context = body_imports(context, knowledge_base)
  let result = case frame {
    FunctionFrame -> extract.extract_function_calls(function, context)
    ClosureFrame(params:, captures:, ..) ->
      extract.extract_closure_calls(params, captures, function.body, context)
  }
  let lexicon = frame_lexicon(function, frame)
  let caller_field_bindings = field_bound_bindings(param_bounds)
  // The function's own fn-typed params join the inherited ambient operators, so
  // a closure in this body that captures one resolves it to its effect variable.
  let operator_params =
    dict.merge(
      frame_ambient(frame),
      signatures.operator_param_shapes(function, cache.fn_alias_types),
    )
  let lift_operator_arg =
    build_lift_operator_arg(
      context,
      function_map,
      knowledge_base,
      visited,
      registry,
      reading,
      operator_params,
      lexicon.binders,
      set.new(),
      cache,
    )
  // What calling code graded does not see charges for the arguments it is
  // handed: a caller's own parameter, or a name nothing resolves.
  let unseen_callee_charge = fn(args, memo) {
    deep_charges(
      args,
      latent_resolver(
        context,
        function_map,
        knowledge_base,
        registry,
        reading,
        param_bounds,
        lexicon,
        lift_operator_arg,
      ),
      memo,
    )
  }

  // A field call whose receiver's name shadows an imported module is two
  // readings until the receiver's type decides between them. Split before the
  // resolved fold, so a call that reads as the module is folded here like any
  // other qualified call rather than appended to a list already consumed.
  let ShadowedSplit(module_reads:, field_reads:, undecided:) =
    split_shadowed_field_calls(result.field, reading, function)
  let resolved_calls = list.append(result.resolved, module_reads)
  // A call neither reading is established for. Charged here rather than through
  // the field resolver, which would answer with the value the receiver was
  // traced to — the field's reading, which is exactly what is unestablished.
  //
  // A hand-written field bound still answers, as it does for every other field
  // call: naming `c.send` on the `check` line declares that this *is* the field
  // call and what it costs, which is a stronger statement than anything the
  // split could establish on its own. Nothing weaker discharges it — the wiring
  // a `type` line or a construction site would supply is the reading in doubt.
  let undecided_effects =
    list.map(undecided, fn(entry) {
      let UndecidedShadowedCall(call:, shadowed:, reason:) = entry
      let resolution = case field_bound_resolution(call, param_bounds) {
        Some(resolution) -> resolution
        None ->
          Resolution(
            term: effect_term.unknown(),
            reason: Some(AmbiguousShadowedReceiver(shadowed, reason)),
            origin: None,
            fallback: types.NoFallback,
          )
      }
      CollectedCall(
        call: sentinel_call(field_call_kind(call), call.span),
        resolution:,
      )
    })

  // Resolved calls: qualified names looked up directly in the knowledge
  // base. If the callee's effects are polymorphic (contain effect
  // variables), bind the variables by matching arguments at fn-typed
  // parameter positions and substitute for concrete effects.
  let #(memo, resolved_nested) =
    list.map_fold(resolved_calls, memo, fn(memo, call) {
      let looked_up = lookup_parts(knowledge_base, call.name, NoKnownEffects)
      let #(concrete, concrete_fallback, charges, memo) =
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
          lexicon,
          caller_field_bindings,
          registry,
          reading,
          cache,
          lift_operator_arg,
          memo,
        )
      let resolution =
        substituted(looked_up, concrete)
        |> with_substituted_fallback(concrete_fallback)
      #(memo, [
        CollectedCall(call:, resolution:),
        ..charge_calls(charges, types.dotted_name(call.name))
      ])
    })
  let resolved_effects = list.flatten(resolved_nested)

  // Local calls: check param bounds first (user-declared and auto-detected
  // fn-typed bounds both live here), then fall back to transitive analysis
  // of local definitions.
  let #(memo, local_effects_nested) =
    list.map_fold(result.local, memo, fn(memo, local_call) {
      case
        reference_bound(
          param_bounds,
          lexicon,
          local_call.function,
          local_call.scope,
        )
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
                lexicon,
                registry,
                lift_operator_arg,
                memo,
              )
          }
          // An operator parameter's callback arguments are lifted into its
          // application; every other argument reaches the caller's code.
          let lifted =
            dict.get(operator_params, local_call.function)
            |> result.map(list.map(_, fn(position) { position.0 }))
            |> result.unwrap([])
          let #(charges, memo) =
            call_args_for(result.call_args, local_call.span)
            |> list.filter(fn(arg) { !list.contains(lifted, arg.position) })
            |> unseen_callee_charge(memo)
          #(memo, [
            plain_call(synthetic_call, effect),
            ..charge_calls(charges, local_call.function)
          ])
        }
        Error(Nil) -> {
          let #(recursive, memo) =
            resolve_unknown_local(
              local_call,
              call_args_for(result.call_args, local_call.span),
              visited,
              function_map,
              context,
              knowledge_base,
              registry,
              reading,
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
            lexicon,
            caller_field_bindings,
            registry,
            reading,
            cache,
            lift_operator_arg,
            memo,
          )
          |> charge_unseen_local(
            local_call,
            function_map,
            result.call_args,
            unseen_callee_charge,
          )
        }
      }
    })
  let local_effects = list.flatten(local_effects_nested)

  // Field calls: object.method(args) resolved via type field annotations.
  let #(memo, field_effects) =
    list.map_fold(field_reads, memo, fn(memo, field_call) {
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
          reading,
          result.call_args,
          param_bounds,
          lexicon,
          registry,
          cache,
          lift_operator_arg,
          memo,
        )
      // A field's function is code graded does not see run its arguments.
      let #(charges, memo) =
        unseen_callee_charge(
          call_args_for(result.call_args, field_call.span),
          memo,
        )
      #(memo, [
        CollectedCall(call: synthetic_call, resolution:),
        ..charge_calls(charges, synthetic_call.name.function)
      ])
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
          reading,
          param_bounds,
          lexicon,
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
            lexicon,
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

  // An inline closure applied to arguments — a pipe target (`x |> fn(f) { f()
  // }`, one argument), an immediately-invoked closure (`fn(a, cb) { cb() }(1,
  // io.println)`, several), or the closure option of a `case` of functions
  // called in place. Lift the closure over the parameter positions the call
  // supplies arguments for, then apply every argument, so each argument's
  // effect reaches the matching parameter.
  let #(memo, direct_pipe_effects) =
    list.map_fold(result.direct_pipe_ops, memo, fn(memo, op) {
      let synthetic_call = sentinel_call(InlineFunctionCall, op.span)
      let positions =
        call_args_for(result.call_args, op.span)
        |> list.map(fn(a) { a.position })
        |> list.sort(int.compare)
      let closure = types.Closure(op.params, op.captures, op.body)
      let #(operator, memo) =
        operator_term_for_argument(
          closure,
          positions,
          knowledge_base,
          param_bounds,
          lexicon,
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
          lexicon,
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

  let echo_effects =
    list.map(result.echoes, fn(span) {
      plain_call(
        sentinel_call(EchoCall, span),
        effect_term.from_effect_set(types.Specific(set.from_list(["Stderr"]))),
      )
    })

  // Direct applications of a let-bound closure, or of the closure option of a
  // let-bound `case` of functions: `let h = fn(x) { ... }; h(a)`. The closure
  // body is already walked at its `let` binding site with the lexical
  // environment in scope, so its first-order effect — including any captured
  // callable (`let suffix = string.append; let h = fn(x) { suffix(x) }`) — is
  // already counted there. The only effect that
  // walk drops is the closure's own parameters, bound as opaque callbacks. So
  // lift the closure to an operator over all its parameters and add just the
  // effect flowing through the parameters it actually invokes: each argument at
  // a position whose parameter is still free in the operator body. Re-deriving
  // the whole body here instead would re-introduce a spurious `[Unknown]` for
  // captured names (which resolve only under the binding-site environment).
  let #(memo, direct_closure_effects) =
    list.map_fold(result.direct_closure_ops, memo, fn(memo, op) {
      let synthetic_call = sentinel_call(LetBoundValueCall, op.span)
      let positions = positions_up_to(list.length(op.params))
      let closure = types.Closure(op.params, op.captures, op.body)
      let #(operator, memo) =
        operator_term_for_argument(
          closure,
          positions,
          knowledge_base,
          param_bounds,
          lexicon,
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
          lexicon,
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
      list.flatten(field_effects),
      undecided_effects,
      direct_op_effects,
      direct_pipe_effects,
      unknown_app_effects,
      echo_effects,
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
  lexicon: Lexicon,
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
            arg.value,
            nested_positions,
            knowledge_base,
            caller_param_bounds,
            lexicon,
            registry,
            lift_operator_arg,
            memo,
          )
        _ -> #(
          resolve_argument_effects(
            arg.value,
            knowledge_base,
            caller_param_bounds,
            lexicon,
          ),
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
  lexicon: Lexicon,
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
        lexicon,
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
  lexicon: Lexicon,
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
              lexicon,
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
  lexicon: Lexicon,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(EffectTerm, Memo) {
  // A forwarded parameter resolves through its bound, never by lifting a
  // same-module function it shadows: only a reference no binding covered names
  // the module's own function.
  case arg.value {
    // A closure or a same-module named function both lift to an operator (the
    // function reference via `lift_local_function`), whose discharge is the
    // effect of calling it.
    types.Closure(_, _, _)
    | types.Capture(..)
    | types.LocalRef(scope: types.ModuleDefinition, ..) -> {
      let #(lifted, memo) = lift_operator_arg(arg.value, [], memo)
      case lifted {
        Ok(operator) -> #(discharge_operator(operator), memo)
        Error(Nil) -> #(
          resolve_argument_effects(
            arg.value,
            knowledge_base,
            caller_param_bounds,
            lexicon,
          ),
          memo,
        )
      }
    }
    _ -> #(
      resolve_argument_effects(
        arg.value,
        knowledge_base,
        caller_param_bounds,
        lexicon,
      ),
      memo,
    )
  }
}

// A pure operator that absorbs `positions`-many callback arguments and reduces
// to `pure`. The contribution of an operator reference whose own effects are
// already accounted for elsewhere — a recursive self-reference, captured by the
// outer frame analysing it. Empty `positions` yields a ground `pure`.
fn pure_operator(positions: List(Int)) -> EffectTerm {
  absorbing_operator(positions, effect_term.pure())
}

// An operator that absorbs `positions`-many callback arguments and reduces to
// `body`.
fn absorbing_operator(positions: List(Int), body: EffectTerm) -> EffectTerm {
  list.fold(positions, body, fn(body, position) {
    types.TAbs("_rec" <> int.to_string(position), body)
  })
}

// What a call to `function` returns while its returned operator is computed up
// the stack: its returns marker applied to its callback parameters, which the
// call site binds to its arguments. A producer with no callback parameter
// returns what it returns whatever it is passed, which the computation up the
// stack already gathers: pure over the callback positions of its returned
// function type. `Error(Nil)` when the return type is absent or not a function.
fn recursive_returned_operator(
  function: Function,
  cache: LocalCache,
) -> Result(EffectTerm, Nil) {
  use return_type <- result.try(option.to_result(function.return, Nil))
  use positions <- result.map(signatures.returned_callback_positions(
    return_type,
    cache.fn_alias_types,
  ))
  case cached_callback_params(function, cache) {
    [] -> pure_operator(positions)
    params ->
      list.fold(
        params,
        TVar(returns_marker(function.name)),
        fn(operator, param) { types.TApp(operator, TVar(param)) },
      )
  }
}

// `operator`, the returned operator computed for `function` over its callback
// parameters `params` (as their sentinels), with each call back into the
// computation resolved: the least fixed point over those calls, iterated from
// the pure operator over `positions`.
fn resolved_returns(
  operator: EffectTerm,
  function: String,
  params: List(String),
  positions: List(Int),
) -> EffectTerm {
  let marker = returns_marker(function)
  use <- bool.guard(
    when: !set.contains(effect_term.free_vars(operator), marker),
    return: operator,
  )
  let summary =
    recursion_fixpoint(
      marker,
      list.map(params, sentinel_of),
      operator,
      pure_operator(positions),
      absorbing_operator(positions, effect_term.unknown()),
      growth_bound(operator, marker),
      0,
    )
  effect_term.normalize(effect_term.subst(
    operator,
    dict.from_list([#(marker, summary)]),
  ))
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
  lexicon: Lexicon,
  caller_field_bindings: dict.Dict(String, EffectTerm),
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
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
      let #(declares, memo) =
        declares_for_callers(
          local_definition,
          context,
          function_map,
          knowledge_base,
          registry,
          reading,
          cache,
          memo,
        )
      use <- bool.lazy_guard(when: declares, return: fn() {
        let #(memo, calls) =
          list.map_fold(recursive, memo, fn(memo, one) {
            let #(concrete, concrete_fallback, charges, memo) =
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
                lexicon,
                caller_field_bindings,
                registry,
                reading,
                cache,
                lift_operator_arg,
                memo,
              )
            let resolution =
              substituted(one.resolution, concrete)
              |> with_substituted_fallback(concrete_fallback)
            #(memo, [
              CollectedCall(..one, resolution:),
              ..charge_calls(charges, types.dotted_name(one.call.name))
            ])
          })
        #(list.flatten(calls), memo)
      })
      let any_polymorphic =
        list.any(recursive, fn(one) { has_vars(collected_term(one)) })
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
          lexicon,
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
          lexicon,
          caller_param_bounds,
          merged_registry,
          function_map,
          context,
          knowledge_base,
          visited,
          reading,
          cache,
          memo,
        )
      let forwarded = forwarded_field_vars(field_bindings.terms)
      // Each site is re-attributed against the term this caller's bindings
      // produced: an `[Unknown]` they introduced is this call's argument, and a
      // field variable the callee left open is answered by the source of the
      // value this caller wired. A fallback share rides the same bindings as
      // the term it is a component of. A site whose term and share name no
      // variable is left as it is: no binding reaches it.
      let substituted =
        list.map(recursive, fn(one) {
          let share_ground = case one.resolution.fallback {
            types.FallbackCharged(share) -> !has_vars(share)
            types.NoFallback -> True
          }
          use <- bool.guard(
            when: !has_vars(collected_term(one)) && share_ground,
            return: one,
          )
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
  variant: Definition(Function),
  cache: LocalCache,
) -> List(ParamBound) {
  synthetic_fn_typed_bounds(unbound_fn_typed_params(variant, [], cache))
}

// Latent charges
//
// Under the latent-effect rules a call is also charged what its arguments
// carry, wherever the callee may run them: every argument a written line does
// not promise no-run, every argument of a callee nothing answers for, and
// every callback a written line does not describe. A generated summary or this
// run's inference already accounts for what the callee runs, and is charged
// nothing more.

// The resolver the latent-effect rules read the checker's knowledge through.
fn latent_resolver(
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  caller_param_bounds: List(ParamBound),
  lexicon: Lexicon,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
) -> latent.Resolver(Memo) {
  let lift_operator = fn(value, positions, memo) {
    let #(operator, memo) =
      operator_term_for_argument(
        value,
        positions,
        knowledge_base,
        caller_param_bounds,
        lexicon,
        registry,
        lift_operator_arg,
        memo,
      )
    #(Ok(operator), memo)
  }
  latent.Resolver(
    types_at: fn(span: Span) {
      typeinfo.types_at(reading, span.start, span.end)
    },
    shapes: registry.shapes,
    shape_memo: fn(memo: Memo) { memo.shapes },
    with_shape_memo: fn(memo: Memo, shapes) { Memo(..memo, shapes:) },
    lift: fn(value, arity, memo) {
      let positions = case arity, value {
        Some(arity), _ -> positions_up_to(arity)
        None, types.LocalRef(name:, scope: types.ModuleDefinition) ->
          case dict.get(function_map, name) {
            Ok(definition) ->
              positions_up_to(list.length(definition.definition.parameters))
            Error(Nil) -> []
          }
        None, _ -> []
      }
      case value {
        types.FunctionRef(..) -> lift_operator(value, positions, memo)
        _ -> lift_operator_arg(value, positions, memo)
      }
    },
    lift_operator:,
    ground: fn(value) {
      ground_value(
        value,
        context,
        function_map,
        knowledge_base,
        registry,
        caller_param_bounds,
        lexicon,
      )
    },
    closure_tail: fn(value) {
      case value {
        types.Closure(params:, captures:, body:) ->
          extract.closure_tail(params, captures, body, context)
        _ -> None
      }
    },
    contract: fn(name, memo) {
      cached_contract(knowledge_base, registry, name, memo)
    },
    match: fn(callee, name, args) {
      match_argument(signatures.lookup_callbacks(registry, callee), name, args).1
    },
    constant: fn(name) {
      effects.catalog_constant(knowledge_base, name)
      |> option.map(latent.Carries)
    },
  )
}

// What the checker traces a value the latent-effect rules cannot read alone
// to: a caller's parameter by its bound, a receiver path by what extraction
// traced it to or by the caller's field bound, a call by its provenance, a
// same-module function as itself.
fn ground_value(
  value: types.ArgumentValue,
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  caller_param_bounds: List(ParamBound),
  lexicon: Lexicon,
) -> latent.Grounding {
  case value {
    types.LocalRef(name:, scope:) ->
      case
        reference_bound(caller_param_bounds, lexicon, name, scope),
        scope,
        dict.has_key(function_map, name)
      {
        Ok(bound), _, _ -> latent.GroundedLatent(latent.Carries(bound.effects))
        Error(Nil), types.ModuleDefinition, True -> latent.GroundedFunction
        Error(Nil), types.ModuleDefinition, False
        | Error(Nil), types.LexicalBinding(..), _
        -> latent.Ungrounded
      }
    types.ReceiverPath(path:, root:, wired:) ->
      case wired, reference_bound(caller_param_bounds, lexicon, path, root) {
        Some(traced), _ -> latent.GroundedValue(traced)
        None, Ok(bound) -> latent.GroundedLatent(latent.Carries(bound.effects))
        None, Error(Nil) -> latent.Ungrounded
      }
    types.CallResult(..) ->
      case
        grounded_receiver(
          value,
          function_map,
          context,
          knowledge_base,
          registry,
        )
      {
        Ok(grounded) -> latent.GroundedValue(grounded)
        Error(Nil) -> latent.Ungrounded
      }
    types.FunctionRef(..)
    | types.ConstructorRef
    | types.Closure(..)
    | types.Choice(..)
    | types.ReturnedOperator(..)
    | types.Constructed(..)
    | types.Updated(..)
    | types.Composite(..)
    | types.OtherExpression
    | types.Capture(..) -> latent.Ungrounded
  }
}

// `callee_contract`, read once per callee on the memo's view.
fn cached_contract(
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  name: QualifiedName,
  memo: Memo,
) -> #(Option(latent.CalleeContract), Memo) {
  case dict.get(memo.contracts, name) {
    Ok(contract) -> #(contract, memo)
    Error(Nil) -> {
      let contract = callee_contract(knowledge_base, registry, name)
      #(
        contract,
        Memo(..memo, contracts: dict.insert(memo.contracts, name, contract)),
      )
    }
  }
}

// What the written line answering for `name` says about function values, with
// each of its bounds' parameter kinds. An audited catalog line marking a
// container result carries everything every argument does. `None` where no
// written line answers.
fn callee_contract(
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  name: QualifiedName,
) -> Option(latent.CalleeContract) {
  use #(written, bounds) <- option.then(effects.winning_contract(
    knowledge_base,
    name,
  ))
  use reach <- option.then(contract_reach(knowledge_base, name))
  let parameters = signatures.lookup_callbacks(registry, name)
  let reviewed = effects.audited_catalog_answer(knowledge_base, name)
  let container =
    reviewed
    && set.contains(effects.audit(knowledge_base).container_results, name)
  let contract = case container, parameters {
    True, Some(parameters) ->
      container_contract(parameters, bounds, written, registry)
    True, None | False, _ ->
      latent.CalleeContract(
        parameters: list.map(bounds, contract_parameter(_, parameters, registry)),
        contract: written,
        reviewed:,
      )
  }
  Some(in_reach(contract, reach))
}

// How much of the line answering for a name speaks for the targets the walk
// reads. A declaration answers only where its `@external` is built.
type ContractReach {
  // Every target the walk reads builds the declaration.
  WholeResult
  // A Gleam fallback body runs on some of them: the line answers for the
  // others alone, so nothing it says about the result covers the result.
  NotTheResult
}

// `None` where none of the targets the walk reads builds the declaration:
// nothing it says applies there.
fn contract_reach(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Option(ContractReach) {
  let charge = effects.declared_charge(knowledge_base, name)
  case charge.declaration, charge.fallback {
    effects.FallbackAnswersInstead, _ | effects.NothingImplementsName, _ -> None
    effects.DeclarationCharged, types.FallbackCharged(_) -> Some(NotTheResult)
    effects.DeclarationCharged, types.NoFallback -> Some(WholeResult)
  }
}

// A callee's contract as far as `reach` lets it speak, whatever it was built
// from: the written line, or what an audit derives from it.
fn in_reach(
  contract: latent.CalleeContract,
  reach: ContractReach,
) -> latent.CalleeContract {
  case reach {
    WholeResult -> contract
    NotTheResult ->
      latent.CalleeContract(
        ..contract,
        contract: types.LatentContract(..contract.contract, carries: None),
      )
  }
}

fn contract_parameter(
  bound: ParamBound,
  parameters: Option(List(signatures.ParameterInfo)),
  registry: SignatureRegistry,
) -> latent.ContractParameter {
  let #(kind, _) =
    contract.parameter_bound_kind(bound, parameters, registry.kinds)
  let operator_positions =
    parameters
    |> option.then(signatures.parameter_named(_, bound.name))
    |> option.then(fn(parameter) {
      case parameter.is_operator {
        True -> Some(parameter.callback_positions)
        False -> None
      }
    })
  latent.ContractParameter(bound:, kind:, operator_positions:)
}

// A container result's contract: the line's own bounds and relays, a variable
// for every parameter the line has no bound for, and a result carrying each
// of them, a callback's result included, beside what the line says it
// carries.
fn container_contract(
  parameters: List(signatures.ParameterInfo),
  bounds: List(ParamBound),
  written: types.LatentContract,
  registry: SignatureRegistry,
) -> latent.CalleeContract {
  let contract_parameters =
    list.filter_map(parameters, fn(parameter) {
      use name <- result.map(
        option.or(parameter.name, parameter.label) |> option.to_result(Nil),
      )
      let bound =
        list.find(bounds, fn(bound) {
          signatures.parameter_named(parameters, bound.name) == Some(parameter)
        })
        |> result.unwrap(ParamBound(name, TVar("$contained$" <> name)))
      latent.ContractParameter(
        ..contract_parameter(bound, Some(parameters), registry),
        kind: contract.kind_of_parameter(parameter, registry.kinds),
      )
    })
  let carried =
    list.flat_map(contract_parameters, fn(parameter) {
      effect_term.free_vars(parameter.bound.effects)
      |> set.to_list
      |> list.flat_map(fn(name) {
        case parameter.kind {
          types.CallbackKind -> [
            TVar(name),
            TVar(name <> types.returns_suffix),
          ]
          types.NonCallbackKind | types.UnknownKind -> [TVar(name)]
        }
      })
    })
  let declared = case written.carries {
    Some(term) -> [term]
    None -> []
  }
  latent.CalleeContract(
    parameters: contract_parameters,
    contract: types.LatentContract(
      runs: Some([]),
      relays: written.relays,
      carries: Some(
        effect_term.normalize(TUnion(list.append(carried, declared))),
      ),
    ),
    reviewed: True,
  )
}

// What a call is charged for what its arguments carry, beyond the callee's own
// term.
fn latent_call_charges(
  callee: QualifiedName,
  args: List(types.CallArgument),
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  resolver: latent.Resolver(Memo),
  memo: Memo,
) -> #(List(ArgumentCharge), Memo) {
  case effects.lookup(knowledge_base, callee) {
    // Nothing answers for the callee: every argument may run.
    effects.Unknown -> deep_charges(args, resolver, memo)
    effects.Known(_term, source) ->
      case effects.lineage_of(source) {
        types.GeneratedLine | types.CurrentInference -> #([], memo)
        types.DeclaredLine ->
          case effects.declared_charge(knowledge_base, callee).declaration {
            // The declaration is built on none of the walk's targets: its
            // Gleam body answers instead, as a summary of what it runs.
            effects.FallbackAnswersInstead -> #([], memo)
            effects.NothingImplementsName -> deep_charges(args, resolver, memo)
            effects.DeclarationCharged ->
              declared_line_charges(
                callee,
                args,
                knowledge_base,
                registry,
                resolver,
                memo,
              )
          }
      }
  }
}

// What a written line charges for its arguments. With `runs`, exactly the
// arguments whose carried variables it lists are charged deep; without, every
// argument that is not a callback is — save under an audited catalog line,
// whose default is no-run. A callback the line has no bound for is charged as
// something that may call it and what it returns; a parameter of unknown kind
// is charged deep; a callee with no signature has every argument charged deep.
fn declared_line_charges(
  callee: QualifiedName,
  args: List(types.CallArgument),
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  resolver: latent.Resolver(Memo),
  memo: Memo,
) -> #(List(ArgumentCharge), Memo) {
  let #(line, memo) = case dict.get(memo.declared_lines, callee) {
    Ok(line) -> #(line, memo)
    Error(Nil) -> {
      let line = declared_line(callee, knowledge_base, registry)
      #(
        line,
        Memo(
          ..memo,
          declared_lines: dict.insert(memo.declared_lines, callee, line),
        ),
      )
    }
  }
  case line.parameters {
    None -> deep_charges(args, resolver, memo)
    Some(parameters) -> {
      let infos = list.map(parameters, fn(parameter) { parameter.info })
      let #(memo, charges) =
        list.map_fold(args, memo, fn(memo, arg) {
          let #(charge, memo) =
            argument_charge(arg, infos, parameters, line, resolver, memo)
          #(memo, ArgumentCharge(arg:, term: charge))
        })
      #(charged_only(charges), memo)
    }
  }
}

// The winning written line for a callee as its arguments are charged: what it
// says about function values, whether a review covered it, and the callee's
// parameters, each with its kind and the line's bound on it. `None` for the
// parameters where the callee has no signature.
type DeclaredLine {
  DeclaredLine(
    written: types.LatentContract,
    audited: Bool,
    parameters: Option(List(DeclaredParameter)),
  )
}

type DeclaredParameter {
  DeclaredParameter(
    info: signatures.ParameterInfo,
    kind: types.BoundKind,
    bound: Result(ParamBound, Nil),
  )
}

fn declared_line(
  callee: QualifiedName,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
) -> DeclaredLine {
  let #(written, bounds) =
    effects.winning_contract(knowledge_base, callee)
    |> option.unwrap(#(types.no_contract, []))
  DeclaredLine(
    written:,
    audited: effects.audited_catalog_answer(knowledge_base, callee),
    parameters: signatures.lookup_callbacks(registry, callee)
      |> option.map(fn(parameters) {
        list.map(parameters, fn(parameter) {
          DeclaredParameter(
            info: parameter,
            kind: contract.kind_of_parameter(parameter, registry.kinds),
            bound: list.find(bounds, fn(bound) {
              signatures.parameter_named(parameters, bound.name)
              == Some(parameter)
            }),
          )
        })
      }),
  )
}

// What one argument is charged where a callee may run it.
type ArgumentCharge {
  ArgumentCharge(arg: types.CallArgument, term: EffectTerm)
}

// The charges that charge something.
fn charged_only(charges: List(ArgumentCharge)) -> List(ArgumentCharge) {
  list.filter(charges, fn(charge) {
    effect_term.normalize(charge.term) != effect_term.pure()
  })
}

// Every charge's term, together.
fn union_of_charges(charges: List(ArgumentCharge)) -> EffectTerm {
  effect_term.normalize(TUnion(list.map(charges, fn(charge) { charge.term })))
}

// Each charge as the call that explains it: the argument passed to `callee`,
// which may run it.
fn charge_calls(
  charges: List(ArgumentCharge),
  callee: String,
) -> List(CollectedCall) {
  list.map(charges, fn(charge) {
    plain_call(
      sentinel_call(
        PassedArgumentCall(
          argument: describe_argument(charge.arg.value),
          callee:,
        ),
        charge.arg.span,
      ),
      charge.term,
    )
  })
}

// How an explanation names an argument value.
fn describe_argument(value: types.ArgumentValue) -> String {
  let named = fn(name) { "`" <> name <> "`" }
  case value {
    types.FunctionRef(name:) -> named(types.dotted_name(name))
    types.LocalRef(name:, ..) -> named(name)
    types.ReceiverPath(path:, ..) -> named(path)
    types.CallResult(callee:, ..) | types.ReturnedOperator(callee:, ..) ->
      "what " <> named(types.dotted_name(callee)) <> " returns"
    types.Closure(..) -> "a closure"
    types.Capture(..) -> "a function capture"
    types.Composite(..) -> "a list or tuple"
    types.Constructed(..) | types.Updated(..) -> "a record"
    types.Choice(..) -> "a choice of functions"
    types.ConstructorRef -> "a constructor"
    types.OtherExpression -> "an argument"
  }
}

fn argument_charge(
  arg: types.CallArgument,
  infos: List(signatures.ParameterInfo),
  parameters: List(DeclaredParameter),
  line: DeclaredLine,
  resolver: latent.Resolver(Memo),
  memo: Memo,
) -> #(EffectTerm, Memo) {
  let DeclaredLine(written:, audited:, ..) = line
  case
    parameter_for_argument(infos, arg)
    |> option.then(fn(info) {
      list.find(parameters, fn(parameter) {
        parameter.info.position == info.position
      })
      |> option.from_result
    })
  {
    None -> deep_charge([arg], resolver, memo)
    Some(DeclaredParameter(kind:, bound:, ..)) -> {
      case kind, bound {
        types.CallbackKind, Ok(_) -> #(effect_term.pure(), memo)
        types.CallbackKind, Error(Nil) -> {
          let #(callback, memo) =
            latent.resolve_callback(
              arg.value,
              arg.span,
              None,
              dict.new(),
              resolver,
              memo,
            )
          #(latent.to_term(latent.escape(callback)), memo)
        }
        // A written line promises nothing for a parameter of unknown kind; a
        // reviewed catalog line's contract speaks for it.
        types.UnknownKind, _ if !audited -> deep_charge([arg], resolver, memo)
        types.NonCallbackKind, _ | types.UnknownKind, _ ->
          case runs_argument(written, bound, audited) {
            True -> deep_charge([arg], resolver, memo)
            False -> #(effect_term.pure(), memo)
          }
      }
    }
  }
}

// Whether a written line lets the argument at a bound run.
fn runs_argument(
  written: types.LatentContract,
  bound: Result(ParamBound, Nil),
  audited: Bool,
) -> Bool {
  case written.runs, bound {
    Some(listed), Ok(bound) ->
      effect_term.free_vars(bound.effects)
      |> set.to_list
      |> list.any(list.contains(listed, _))
    Some(_), Error(Nil) -> False
    None, _ -> !audited
  }
}

// What the arguments carry, charged where they may run.
fn deep_charge(
  args: List(types.CallArgument),
  resolver: latent.Resolver(Memo),
  memo: Memo,
) -> #(EffectTerm, Memo) {
  let #(charges, memo) = deep_charges(args, resolver, memo)
  #(union_of_charges(charges), memo)
}

// What each argument carries, charged where it may run.
fn deep_charges(
  args: List(types.CallArgument),
  resolver: latent.Resolver(Memo),
  memo: Memo,
) -> #(List(ArgumentCharge), Memo) {
  let #(memo, charges) =
    list.map_fold(args, memo, fn(memo, arg) {
      let #(carried, memo) =
        latent.argument_latent(arg.value, arg.span, dict.new(), resolver, memo)
      #(memo, ArgumentCharge(arg:, term: latent.to_term(carried)))
    })
  #(charged_only(charges), memo)
}

// The parameter an argument fills: the one `argument_for_parameter` pairs it
// with.
fn parameter_for_argument(
  parameters: List(signatures.ParameterInfo),
  arg: types.CallArgument,
) -> Option(signatures.ParameterInfo) {
  list.find(parameters, fn(parameter) {
    argument_for_parameter(parameter, [arg]) == Some(arg)
  })
  |> option.from_result
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
  lexicon: Lexicon,
  caller_field_bindings: dict.Dict(String, EffectTerm),
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(
  EffectTerm,
  types.FallbackDisposition(EffectTerm),
  List(ArgumentCharge),
  Memo,
) {
  let substitute = fn(effect, fallback, memo) {
    substitute_bindings(
      call,
      effect,
      fallback,
      call_args,
      function_map,
      context,
      knowledge_base,
      visited,
      caller_param_bounds,
      lexicon,
      caller_field_bindings,
      registry,
      reading,
      cache,
      lift_operator_arg,
      memo,
    )
  }
  let args = call_args_for(call_args, call.span)
  let resolver =
    latent_resolver(
      context,
      function_map,
      knowledge_base,
      registry,
      reading,
      caller_param_bounds,
      lexicon,
      lift_operator_arg,
    )
  // A written line's own variables take what the latent-effect rules bind
  // them to before anything else substitutes.
  let #(contract, memo) =
    cached_contract(knowledge_base, registry, call.name, memo)
  let #(bindings, memo) = case contract {
    None -> #(dict.new(), memo)
    Some(contract) ->
      latent.bind_contract(
        call.name,
        contract,
        args,
        dict.new(),
        resolver,
        memo,
      )
  }
  // A term read in its self-referential form names parameters, not the
  // line's variables: the bindings follow the same rename.
  let bindings = case effects.declared_renames(knowledge_base, call.name) {
    None -> bindings
    Some(renames) -> renamed_bindings(bindings, renames)
  }
  let bind = fn(term) { subst_if(term, bindings) }
  let #(term, fallback, memo) =
    substitute(bind(effect), types.map_fallback(fallback, bind), memo)
  let #(charges, memo) =
    latent_call_charges(
      call.name,
      args,
      knowledge_base,
      registry,
      resolver,
      memo,
    )
  #(term, fallback, charges, memo)
}

// Bindings keyed by a line's variables, keyed instead by the parameters each
// variable renames to; a parameter several variables rename to takes their
// join, and a variable renamed to nothing binds nothing.
fn renamed_bindings(
  bindings: dict.Dict(String, EffectTerm),
  renames: dict.Dict(String, List(String)),
) -> dict.Dict(String, EffectTerm) {
  dict.fold(bindings, dict.new(), fn(acc, variable, term) {
    dict.get(renames, variable)
    |> result.unwrap([])
    |> list.fold(acc, fn(acc, parameter) {
      dict.upsert(acc, parameter, fn(existing) {
        case existing {
          Some(existing) -> effect_term.normalize(TUnion([existing, term]))
          None -> term
        }
      })
    })
  })
}

// The call-site substitution: bind the callee's effect variables to its
// arguments, forward field variables onto the caller's
// receivers, and discharge the caller's own field bounds.
fn substitute_bindings(
  call: types.ResolvedCall,
  effect: EffectTerm,
  fallback: types.FallbackDisposition(EffectTerm),
  call_args: dict.Dict(#(Int, Int), List(types.CallArgument)),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  caller_param_bounds: List(ParamBound),
  lexicon: Lexicon,
  caller_field_bindings: dict.Dict(String, EffectTerm),
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
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
  use <- bool.guard(
    when: !has_vars(effect) && callee_kb_bounds != [],
    return: #(effect, fallback, memo),
  )
  let args = call_args_for(call_args, call.span)
  let #(effective_effects, effective_bounds) = case callee_kb_bounds {
    [_, ..] -> #(effect, callee_kb_bounds)
    [] -> auto_bounds_from_registry(call.name, effect, args, registry)
  }
  use <- bool.guard(when: !has_vars(effective_effects), return: #(
    effective_effects,
    fallback,
    memo,
  ))
  let #(bindings, memo) =
    bind_variables(
      call.name,
      effective_bounds,
      args,
      knowledge_base,
      caller_param_bounds,
      lexicon,
      registry,
      lift_operator_arg,
      memo,
    )
  let #(field_bindings, memo) =
    field_forwarding_bindings(
      call.name,
      effective_effects,
      args,
      lexicon,
      caller_param_bounds,
      registry,
      function_map,
      context,
      knowledge_base,
      visited,
      reading,
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
  lexicon: Lexicon,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  reading: typeinfo.ModuleReading,
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
        lexicon,
        caller_param_bounds,
        registry,
        function_map,
        context,
        knowledge_base,
        visited,
        reading,
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
  lexicon: Lexicon,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  reading: typeinfo.ModuleReading,
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
        lexicon,
        caller_param_bounds,
        registry,
        function_map,
        context,
        knowledge_base,
        visited,
        reading,
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
  lexicon: Lexicon,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  reading: typeinfo.ModuleReading,
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
          lexicon,
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
    | types.Composite(..)
    | types.OtherExpression
    | types.Capture(..) ->
      case forwarded_binding_term(base, tail, lexicon, caller_param_bounds) {
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
            reading,
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
  reading: typeinfo.ModuleReading,
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
          reading,
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
  reading: typeinfo.ModuleReading,
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
      reading,
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
    None, Some(effects) -> Some(#(effect_term.close(effects), origin))
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
  lexicon: Lexicon,
  caller_param_bounds: List(ParamBound),
) -> option.Option(EffectTerm) {
  use path <- option.then(forwarded_path(base, tail, lexicon))
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
  lexicon: Lexicon,
) -> option.Option(String) {
  value_at_path(value, tail)
  |> option.from_result
  |> option.then(caller_rooted_path(_, lexicon))
}

// The receiver path an argument denotes when rooted at one of the caller's own
// parameters: a bare parameter reference is the single-segment case
// (`options`), a receiver path the multi-segment one (`config.options`). `None`
// for any other value, or when the root isn't a caller parameter.
fn caller_rooted_path(
  value: types.ArgumentValue,
  lexicon: Lexicon,
) -> option.Option(String) {
  use #(path, scope) <- option.then(case value {
    types.LocalRef(name:, scope:) -> Some(#(name, scope))
    types.ReceiverPath(path:, root:, ..) -> Some(#(path, root))
    _ -> None
  })
  case
    set.contains(lexicon.own, path_root(path))
    && names_binder(lexicon, path, scope)
  {
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
    types.Updated(base:, fields:, components:) ->
      case
        grounded_receiver(base, function_map, context, knowledge_base, registry)
      {
        Ok(grounded) -> Ok(types.Updated(base: grounded, fields:, components:))
        Error(Nil) -> Ok(value)
      }
    types.FunctionRef(_)
    | types.LocalRef(..)
    | types.ConstructorRef
    | types.Closure(..)
    | types.Choice(_)
    | types.ReturnedOperator(..)
    | types.ReceiverPath(..)
    | types.Constructed(..)
    | types.Composite(..)
    | types.OtherExpression
    | types.Capture(..) -> Ok(value)
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
  use arguments <- result.map(
    list.try_map(sorted, fn(param) {
      argument_for_parameter(param, args)
      |> option.to_result(Nil)
    }),
  )
  list.index_map(arguments, fn(arg, position) {
    types.CallArgument(position:, label: None, value: arg.value, span: arg.span)
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
      // The summary traces the fields it can, not every field the record
      // holds, so its components are not the whole value.
      types.Constructed(
        fields: built,
        components: [],
        coverage: types.PartialValue,
      )
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
// (the `""` sentinel) is re-derived from the variant of it the walk reaches,
// mirroring the on-demand returned-operator path; a qualified callee is looked
// up in the knowledge base (computed at its inference time, available by
// topological order).
fn callee_provenance(
  callee: types.QualifiedName,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
) -> Result(types.ReturnProvenance, Nil) {
  case callee.module {
    "" -> {
      // A fallback body describes neither what the foreign implementation
      // returns nor how, so a same-module consumer of one is charged `[Unknown]`
      // exactly as a cross-module consumer is: this channel reads no
      // declaration, so a foreign definition and no definition end alike here.
      let targets = walk_targets(context, knowledge_base)
      case local_definition(function_map, callee.function, targets) {
        NativeDefinition(definition) ->
          Ok(extract.return_provenance(
            definition.definition,
            definition_imports(
              context,
              definition,
              types.declaration_targets(targets),
            ),
          ))
        ForeignDefinition | NoLocalDefinition -> Error(Nil)
      }
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
        types.Constructed(fields:, ..) -> {
          use wired <- result.try(dict.get(fields, field))
          value_at_path(wired, rest)
        }
        // A record-update overlay: read the head field selectively. An updated
        // field takes its replacement; any other falls through to the base —
        // without requiring the base to be traceable, so an updated field
        // resolves even over an opaque base.
        types.Updated(base:, fields:, ..) ->
          case dict.get(fields, field) {
            Ok(wired) -> value_at_path(wired, rest)
            Error(Nil) -> value_at_path(base, tail)
          }
        types.LocalRef(name:, scope:) ->
          Ok(types.ReceiverPath(name <> "." <> tail, scope, None))
        types.ReceiverPath(path:, root:, ..) ->
          Ok(types.ReceiverPath(path <> "." <> tail, root, None))
        types.FunctionRef(_)
        | types.ConstructorRef
        | types.Closure(..)
        | types.Choice(_)
        | types.ReturnedOperator(..)
        | types.CallResult(..)
        | types.Composite(..)
        | types.OtherExpression
        | types.Capture(..) -> Error(Nil)
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
//
// A synthesised bound is keyed by a name `parameter_named` resolves back to
// its own parameter. A parameter with no such name — a discarded in-body name
// whose label is a sibling's in-body name — contributes `[Unknown]` instead.
fn auto_bounds_from_registry(
  callee_name: types.QualifiedName,
  existing_effects: EffectTerm,
  args: List(types.CallArgument),
  registry: SignatureRegistry,
) -> #(EffectTerm, List(ParamBound)) {
  let params =
    option.unwrap(signatures.lookup_callbacks(registry, callee_name), [])
  let shares =
    params
    |> list.filter(fn(param) {
      param.is_fn_typed && option.values([param.label, param.name]) != []
    })
    |> list.filter_map(fn(param) {
      case argument_for_parameter(param, args) {
        Some(arg) ->
          case arg.value {
            // Closures, branches, and other inline expressions are walked
            // separately by the extractor; binding them here would double-count.
            types.Closure(_, _, _)
            | types.Choice(_)
            | types.ReceiverPath(..)
            | types.Constructed(..)
            | types.Composite(..)
            | types.OtherExpression -> Error(Nil)
            _ -> Ok(synthesized_bound_key(params, param))
          }
        None -> Error(Nil)
      }
    })
  case shares {
    [] -> #(existing_effects, [])
    _ -> {
      let tracked_terms =
        list.map(shares, fn(key) {
          key |> option.map(TVar) |> option.lazy_unwrap(effect_term.unknown)
        })
      #(
        effect_term.normalize(TUnion([existing_effects, ..tracked_terms])),
        shares |> option.values |> list.map(self_referential_bound),
      )
    }
  }
}

// The name a bound synthesised for `param` is keyed by: its label, else its
// in-body name — the first that `parameter_named` resolves back to `param`;
// `None` when neither does.
fn synthesized_bound_key(
  params: List(signatures.ParameterInfo),
  param: signatures.ParameterInfo,
) -> Option(String) {
  option.values([param.label, param.name])
  |> list.find(fn(name) {
    signatures.parameter_named(params, name) == Some(param)
  })
  |> option.from_result
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
  lexicon: Lexicon,
  registry: SignatureRegistry,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(dict.Dict(String, EffectTerm), Memo) {
  let signature = signatures.lookup(registry, callee_name)
  list.fold(callee_bounds, #(dict.new(), memo), fn(state, bound) {
    let #(acc, memo) = state
    // Find the argument matching this parameter by label (caller used
    // an explicit label) or by real parameter position from the
    // registry. If neither matches, the variable stays unresolved.
    let #(parameter, matched) = match_argument(signature, bound.name, args)
    case matched {
      Some(arg) -> {
        // For an *operator* parameter the argument is lifted to an effect
        // operator (a `TAbs`, possibly curried over several callbacks) so the
        // callee's `op(cb1, cb2)` application beta-reduces. The callback
        // positions come from the operator parameter's own signature so a
        // closure argument is abstracted over exactly the right parameters. A
        // first-order parameter just takes the argument's flat effect.
        let #(arg_effects, memo) = case parameter {
          Some(signatures.ParameterInfo(
            is_operator: True,
            callback_positions:,
            ..,
          )) ->
            operator_term_for_argument(
              arg.value,
              callback_positions,
              knowledge_base,
              caller_param_bounds,
              lexicon,
              registry,
              lift_operator_arg,
              memo,
            )
          _ ->
            first_order_arg_effect(
              arg,
              knowledge_base,
              caller_param_bounds,
              lexicon,
              lift_operator_arg,
              memo,
            )
        }
        // Bind the bound's free variable(s) to the argument's effect. For a
        // first-order bound `param: [e]` that's the variable `e`; for a self-
        // referential fn-typed bound it's the parameter name itself.
        let var_names =
          bound.effects |> effect_term.free_vars() |> set.to_list()
        // Under the latent-effect rules a variable several arguments share
        // takes the join of all of them.
        let acc =
          list.fold(var_names, acc, fn(d, var) {
            latent.insert_joined(d, var, arg_effects)
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
  value: types.ArgumentValue,
  positions: List(Int),
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  lexicon: Lexicon,
  registry: SignatureRegistry,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(EffectTerm, Memo) {
  case value {
    types.FunctionRef(name) -> {
      let body = effects.declared_effects(knowledge_base, name)
      // Abstract over `g`'s callback params in declaration order — a discarded
      // one where this use site supplies its argument. The outermost binder is
      // the first param, matching the left-nested application spine built at
      // the definition site. The recorded bounds
      // count as fn-typed too: a running fallback's girard-typed callback has
      // no `fn(...)` annotation for the registry to see, and without its binder
      // the summary's variable stays free and the application goes stuck.
      let operator =
        signatures.callback_slots(
          registry,
          name,
          value_channel_bound_names(knowledge_base, name),
        )
        |> signatures.supplied_slots(positions)
        |> abstract_over_slots(body)
      #(operator, memo)
    }
    // A branch over function-like options: lift each, then join the operators —
    // `(f ⊔ g)(cb) = f(cb) ⊔ g(cb)`, an over-approximation of every branch.
    types.Choice(options) -> {
      let #(memo, operators) =
        list.map_fold(options, memo, fn(memo, option) {
          let #(op, memo) =
            operator_term_for_argument(
              option,
              positions,
              knowledge_base,
              caller_param_bounds,
              lexicon,
              registry,
              lift_operator_arg,
              memo,
            )
          #(memo, op)
        })
      #(join_operators(operators), memo)
    }
    _ -> {
      let #(lifted, memo) = lift_operator_arg(value, positions, memo)
      case lifted {
        Ok(operator) -> #(operator, memo)
        Error(Nil) -> #(
          resolve_argument_effects(
            value,
            knowledge_base,
            caller_param_bounds,
            lexicon,
          ),
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
  reading: typeinfo.ModuleReading,
  ambient_operators: OperatorShapes,
  // The binder each in-scope parameter's bound is kept for, by name.
  binders: dict.Dict(String, Int),
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
            reading,
            ambient_operators,
            binders,
            sentinel_params,
            cache,
            memo,
          )
        #(Ok(operator), memo)
      }
      // A reference no binding covered names the module's own function; a
      // lexical one names a parameter, which no definition answers for.
      types.LocalRef(name:, scope: types.ModuleDefinition) ->
        // Guard against a function passed as an operator argument to itself:
        // `visited` already carries the call stack, so a name on it would loop.
        case set.contains(visited, name), dict.get(function_map, name) {
          False, Ok(definition) -> {
            let #(operator, memo) =
              lift_local_function(
                name,
                definition,
                positions,
                context,
                function_map,
                knowledge_base,
                visited,
                registry,
                reading,
                cache,
                memo,
              )
            #(Ok(operator), memo)
          }
          // A reference to a function already being walked up the stack: what
          // it does with the callbacks it is handed is the summary that walk is
          // computing, as at a call back into it.
          True, Ok(definition) -> #(
            Ok(recursive_reference(name, definition, positions, cache, memo)),
            memo,
          )
          _, Error(Nil) -> #(Error(Nil), memo)
        }
      // A producer parameter passed on reads as its sentinel, as the
      // producer's own body reads it.
      types.ReturnedOperator(callee, args) | types.CallResult(callee, args) -> {
        let producer_params = set.to_list(sentinel_params)
        let #(resolved, memo) =
          resolve_returned_operator(
            callee,
            args,
            context,
            function_map,
            knowledge_base,
            visited,
            registry,
            reading,
            list.map(producer_params, sentinel_bound),
            Lexicon(
              binders: dict.take(binders, producer_params),
              own: set.new(),
            ),
            cache,
            memo,
          )
        #(result.map(resolved, fn(found) { found.0 }), memo)
      }
      types.Capture(..) ->
        capture_operator(
          value,
          positions,
          context,
          function_map,
          knowledge_base,
          visited,
          registry,
          reading,
          ambient_operators,
          binders,
          sentinel_params,
          cache,
          build_lift_operator_arg(
            context,
            function_map,
            knowledge_base,
            visited,
            registry,
            reading,
            ambient_operators,
            binders,
            sentinel_params,
            cache,
          ),
          memo,
        )
      _ -> #(Error(Nil), memo)
    }
  }
}

// A capture `f(a, _, c)` as an operator over its own parameter: evaluating the
// arguments it fixes, walked where the capture is written, and the one call it
// makes — its target with those arguments and the parameter at the hole —
// resolved as that call is wherever it is written, through the target's
// knowledge-base entry or the same-module definition's summary, never by
// walking the target's body again. A target neither names reads `[Unknown]`.
fn capture_operator(
  value: types.ArgumentValue,
  positions: List(Int),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  ambient_operators: OperatorShapes,
  binders: dict.Dict(String, Int),
  sentinel_params: Set(String),
  cache: LocalCache,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(Result(EffectTerm, Nil), Memo) {
  let hole = latent.capture_hole
  let bounds = [ParamBound(hole, TVar(hole))]
  let names = case value {
    types.Capture(span:, ..) ->
      Lexicon(
        binders: dict.from_list([#(hole, span.start)]),
        own: set.from_list([hole]),
      )
    _ -> empty_lexicon()
  }
  let #(called, memo) = case value {
    types.Capture(span:, target: types.FunctionRef(name:), ..) -> {
      let call = types.ResolvedCall(name:, span:)
      let looked_up = lookup_parts(knowledge_base, name, NoKnownEffects)
      let #(concrete, concrete_fallback, charges, memo) =
        substitute_at_call_site(
          call,
          looked_up.term,
          looked_up.fallback,
          capture_call_args(span, value),
          function_map,
          context,
          knowledge_base,
          visited,
          bounds,
          names,
          dict.new(),
          registry,
          reading,
          cache,
          lift_operator_arg,
          memo,
        )
      let resolution =
        substituted(
          looked_up,
          effect_term.normalize(TUnion([concrete, union_of_charges(charges)])),
        )
        |> with_substituted_fallback(concrete_fallback)
      #(Ok([CollectedCall(call:, resolution:)]), memo)
    }
    types.Capture(
      span:,
      target: types.LocalRef(name:, scope: types.ModuleDefinition),
      ..,
    ) ->
      case
        dict.has_key(function_map, name),
        set.contains(memo.capturing, name) && !set.contains(visited, name)
      {
        False, _ | True, True -> #(Error(Nil), memo)
        True, False -> {
          let outer = memo.capturing
          let memo = Memo(..memo, capturing: set.insert(outer, name))
          let local_call =
            types.LocalCall(
              function: name,
              span:,
              scope: types.ModuleDefinition,
            )
          let #(recursive, memo) =
            resolve_unknown_local(
              local_call,
              call_args_for(capture_call_args(span, value), span),
              visited,
              function_map,
              context,
              knowledge_base,
              registry,
              reading,
              cache,
              memo,
            )
          let #(collected, memo) =
            substitute_local_call_effects(
              recursive,
              local_call,
              capture_call_args(span, value),
              function_map,
              context,
              knowledge_base,
              visited,
              bounds,
              names,
              dict.new(),
              registry,
              reading,
              cache,
              lift_operator_arg,
              memo,
            )
          #(Ok(collected), Memo(..memo, capturing: outer))
        }
      }
    _ -> #(Error(Nil), memo)
  }
  let #(evaluation, memo) = case value {
    types.Capture(evaluated: [_, ..] as evaluated, captures:, ..) ->
      analyze_closure(
        [],
        captures,
        list.map(evaluated, glance.Expression),
        [],
        context,
        function_map,
        knowledge_base,
        visited,
        registry,
        reading,
        ambient_operators,
        binders,
        sentinel_params,
        cache,
        memo,
      )
    _ -> #(effect_term.pure(), memo)
  }
  #(
    result.map(called, fn(collected) {
      let body =
        effect_term.normalize(TUnion([evaluation, union_of(collected)]))
      case list.contains(positions, 0) {
        True -> types.TAbs(hole, body)
        False ->
          effect_term.normalize(effect_term.subst(
            body,
            dict.from_list([#(hole, effect_term.pure())]),
          ))
      }
    }),
    memo,
  )
}

// The arguments of a capture's one call, keyed as extraction keys a call's.
fn capture_call_args(
  span: Span,
  value: types.ArgumentValue,
) -> dict.Dict(#(Int, Int), List(types.CallArgument)) {
  dict.from_list([#(extract.span_key(span), latent.capture_arguments(value))])
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

// Why a producer left its applied operator unknown. A declared return out of
// reach is named rather than folded into the generic reason: it is the same
// reading a direct call reports for that `@external`.
fn unresolved_producer_reason(
  knowledge_base: KnowledgeBase,
  producer: QualifiedName,
) -> UnknownReason {
  case effects.declared_return_standing(knowledge_base, producer) {
    effects.DeclaredReturnUnbuilt -> UnbuiltExternal
    effects.DeclaredReturnFallbackRuns
    | effects.DeclaredReturnAnswers
    | effects.NoDeclaredReturn -> UntraceableProducer
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
  reading: typeinfo.ModuleReading,
  // The enclosing scope's caller bounds, threaded into `bind_producer_params`
  // for D1 (nested-producer precision). `[]` when resolving a top-level producer.
  caller_param_bounds: List(ParamBound),
  lexicon: Lexicon,
  cache: LocalCache,
  memo: Memo,
) -> #(Result(#(EffectTerm, option.Option(LookupOrigin)), Nil), Memo) {
  // A same-module (`""`) summary is computed on demand now, hence Fresh and
  // sourced by nothing but this run's analysis; a cross-module one is read from
  // the KB with its recorded origin (Fix E) and the source that wrote it.
  let #(lookup, memo) = case callee.module {
    "" ->
      case
        set.contains(visited, returns_key(callee.function)),
        local_definition(
          function_map,
          callee.function,
          walk_targets(context, knowledge_base),
        )
      {
        False, NativeDefinition(definition) -> {
          let #(computed, memo) =
            compute_returned_operator(
              definition.definition,
              context,
              function_map,
              knowledge_base,
              set.insert(visited, returns_key(callee.function)),
              registry,
              reading,
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
        // A producer whose returned operator is already being computed up the
        // stack: what it returns for this call's arguments is the summary that
        // computation is reaching.
        True, NativeDefinition(definition) -> #(
          recursive_returned_operator(definition.definition, cache)
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
              reading,
              caller_param_bounds,
              lexicon,
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
  reading: typeinfo.ModuleReading,
  // The enclosing scope's caller bounds (Fix D / D1): when a producer's returned
  // closure applies a *nested* producer with one of the outer producer's params
  // as an argument, these carry the outer param's sentinel bound (`$op$name`) so
  // the nested bind resolves it to the sentinel — keeping it distinct from any
  // residual of the same name. `[]` for a top-level producer resolution.
  caller_param_bounds: List(ParamBound),
  lexicon: Lexicon,
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
  // from the *direct* effect, which trims the closure). A variable a scoping
  // bound's payload introduces is that bound's, wherever the line uses it:
  // `bind_variables` binds it to the argument that bound matches, and with
  // `cb: [e], other: [cb]` the clause's `cb` is `other`'s argument. Every
  // other non-dotted free var of the operator names a producer parameter —
  // the gates scope a clause by the line's bound names and payload variables
  // (plus the registry's fn-typed params on the `Closed` path), and a
  // **Fresh** summary is Fix-D-sanitized (free vars ⊆ the producer's fn-typed
  // params) — so each one takes a synthesized self-referential bound. No
  // payload variable takes one, so no parameter spelled like it captures it;
  // a synthesized bound matching no argument binds nothing. Field-path
  // (dotted) vars are excluded (they round-trip as field bounds, not producer
  // params).
  let introduced = effects.bound_payload_variables(scoping)
  let synth =
    effect_term.free_vars(operator)
    |> set.filter(fn(v) {
      !is_field_path_var(v)
      && !is_recursion_marker(v)
      && !set.contains(introduced, v)
    })
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
      reading,
      dict.new(),
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
      lexicon,
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
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
) -> #(Result(EffectTerm, ReturnedOperatorReason), Memo) {
  let #(returned, memo) =
    compute_view_returned_operator(
      function,
      context,
      function_map,
      knowledge_base,
      visited,
      registry,
      reading,
      cache,
      memo,
    )
  use view <- with_view_in_reach(memo, context, #(returned, memo))
  let in_scope = named_function_params(function)
  case
    unresolved_return(returned, in_scope),
    effects.structural_baseline_view(knowledge_base)
  {
    True, Some(#(baseline, _modules)) -> {
      let #(baseline_returned, baseline_memo) =
        compute_view_returned_operator(
          function,
          view.context,
          function_map,
          baseline,
          visited,
          signatures.without_modules(registry, view.modules),
          reading,
          view.cache,
          view.memo,
        )
      let memo =
        Memo(..memo, baseline: Some(BaselineView(..view, memo: baseline_memo)))
      case unresolved_return(baseline_returned, in_scope) {
        True -> #(returned, memo)
        False -> #(baseline_returned, memo)
      }
    }
    False, _ | True, None -> #(returned, memo)
  }
}

// Whether a producer's returned operator carries `[Unknown]`, a refused or
// absent one included.
fn unresolved_return(
  returned: Result(EffectTerm, ReturnedOperatorReason),
  in_scope: Set(String),
) -> Bool {
  case returned {
    Ok(operator) -> unresolved_operator(operator, in_scope)
    Error(_) -> True
  }
}

fn compute_view_returned_operator(
  function: Function,
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
) -> #(Result(EffectTerm, ReturnedOperatorReason), Memo) {
  let context = body_imports(context, knowledge_base)
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
      let lexicon = frame_lexicon(function, FunctionFrame)
      let lift =
        build_lift_operator_arg(
          context,
          function_map,
          knowledge_base,
          visited,
          registry,
          reading,
          producer_operators,
          lexicon.binders,
          producer_params,
          cache,
        )
      let #(operator, memo) =
        operator_term_for_argument(
          value,
          positions,
          knowledge_base,
          producer_bounds,
          lexicon,
          registry,
          lift,
          memo,
        )
      // Fix D steps 3+4: ground every non-sentinel free var (bare residual or any
      // dotted var) to [Unknown], then rename sentinels back to real param names —
      // so the summary's free vars ⊆ the producer's fn-typed params by construction.
      let operator =
        resolved_returns(operator, function.name, ordered_params, positions)
        |> collapse_and_rename_back(producer_params, visited)
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
  visited: Set(String),
) -> EffectTerm {
  let sentinels =
    producer_params |> set.to_list() |> list.map(sentinel_of) |> set.from_list()
  let collapsed =
    ground_vars(
      operator,
      effect_term.free_vars(operator)
        |> set.difference(sentinels)
        |> set.filter(fn(variable) { !owned_up_the_stack(variable, visited) }),
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
  captures: List(types.Captured),
  body: List(Statement),
  positions: List(Int),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  ambient_operators: OperatorShapes,
  // The binder each in-scope parameter's bound is kept for, by name; the
  // ambient operators' are read from it.
  binders: dict.Dict(String, Int),
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
  // ambient operators and their binders, which ancestors are visited, and which
  // of those ambient operators are sentinel-seeded; key by all five.
  let ambient_binders = dict.take(binders, dict.keys(ambient_operators))
  let key = #(
    closure_body_start(body),
    positions,
    list.sort(dict.to_list(ambient_binders), fn(left, right) {
      string.compare(left.0, right.0)
    }),
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
          reading,
          ambient_operators,
          ambient_binders,
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
  captures: List(types.Captured),
  body: List(Statement),
  positions: List(Int),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  ambient_operators: OperatorShapes,
  ambient_binders: dict.Dict(String, Int),
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
  let ambient_binders = dict.take(ambient_binders, dict.keys(ambient_operators))
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
      reading,
      ClosureFrame(
        params:,
        site: closure_body_start(body),
        captures:,
        ambient: ambient_operators,
        ambient_binders:,
      ),
      cache,
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
  extract.closure_site(body)
}

fn lift_local_function(
  name: String,
  definition: Definition(Function),
  positions: List(Int),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
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
  let #(declares, memo) =
    declares_for_callers(
      definition,
      context,
      function_map,
      knowledge_base,
      registry,
      reading,
      cache,
      memo,
    )
  use <- bool.lazy_guard(when: declares, return: fn() {
    let qualified = QualifiedName(module: context.module_path, function: name)
    let declared = effects.declared_effects(knowledge_base, qualified)
    let operator =
      signatures.function_callback_slots(
        function,
        cache.fn_alias_types,
        value_channel_bound_names(knowledge_base, qualified),
      )
      |> signatures.supplied_slots(positions)
      |> abstract_over_slots(declared)
    #(operator, memo)
  })
  let slots =
    signatures.supplied_slots(cached_callback_slots(function, cache), positions)
  let scc = dict.get(cache.scc_id, name) |> result.unwrap(-1)
  case set.contains(cache.collapsible, scc) {
    // A first-order function in a collapsible SCC lifts to its full-reachability
    // effect, which is the component's shared collapsed analysis — reuse it
    // rather than re-walking. A callback it discards still takes a binder, so
    // an application of the lifted operator reduces rather than going stuck.
    True -> {
      let #(pairs, memo) =
        collapsed_member_view(
          name,
          scc,
          function_map,
          context,
          knowledge_base,
          registry,
          reading,
          cache,
          memo,
        )
      #(abstract_over_slots(slots, union_of(pairs)), memo)
    }
    // Otherwise memoize like `memoized_local`'s polymorphic path, but for the
    // operator-lifting of a function reference (an encoder passed to a codec
    // combinator, reached through deep reference chains). Keyed distinctly from
    // the local-call memo; the precise `visited ∩ SCC` ancestors when the lifted
    // function is itself effect-polymorphic.
    False -> {
      let #(_, ancestors) = memo_key(name, visited, cache)
      let key = #(name, ancestors)
      let #(body, memo) = case dict.get(memo.lifts, key) {
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
            reading,
            cache,
            memo,
          )
      }
      #(abstract_over_slots(slots, body), memo)
    }
  }
}

// Compute (and cache) the body of a same-module function's operator lift on a
// `lifts` memo miss: analyse its body with its fn-typed params seeded as
// self-referential variables. The caller abstracts it over the slots its use
// site supplies.
fn lift_operator_miss(
  name: String,
  definition: Definition(Function),
  key: #(String, List(String)),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
) -> #(EffectTerm, Memo) {
  let function = definition.definition
  // The canonical callback set, in declaration order: a callback carrying no
  // `fn(...)` annotation is seeded here too, or the lifted term's variable
  // stays free and the application goes stuck.
  let bounds =
    list.map(cached_callback_params(function, cache), self_referential_bound)
  let #(body_pairs, memo) = {
    use memo <- walk_recursive(
      name,
      definition,
      fn() { path_bound([name], function_map, context, registry) },
      cache,
      memo,
    )
    collect_effects(
      without_returned_closure(function),
      function_map,
      context,
      knowledge_base,
      set.insert(visited, name),
      bounds,
      registry,
      reading,
      FunctionFrame,
      cache,
      memo,
    )
  }
  let body = union_of(body_pairs)
  #(body, Memo(..memo, lifts: dict.insert(memo.lifts, key, body)))
}

// Abstract `body` over a function's callback slots, the first slot outermost. A
// named slot binds its name; a nameless one binds a fresh `_`, clear of the
// body's free variables and of every other binder, so it captures nothing.
fn abstract_over_slots(
  slots: List(signatures.CallbackSlot),
  body: EffectTerm,
) -> EffectTerm {
  let names = signatures.slot_names(slots)
  use <- bool.guard(
    when: list.length(names) == list.length(slots),
    return: wrap_binders(names, body),
  )
  let avoid = set.union(effect_term.free_vars(body), set.from_list(names))
  let #(_, binders) =
    list.map_fold(slots, avoid, fn(avoid, slot) {
      let binder = case slot {
        signatures.NamedSlot(name:, ..) -> name
        signatures.NamelessSlot(..) -> effect_term.fresh("_", avoid)
      }
      #(set.insert(avoid, binder), binder)
    })
  wrap_binders(binders, body)
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
// labeled, `signatures.callback_slots` prefers the label unless a bound names
// the parameter, and a binder named after the label leaves the term's
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

fn find_matching_arg_by_name(
  callee_name: types.QualifiedName,
  name: String,
  args: List(types.CallArgument),
  registry: SignatureRegistry,
) -> option.Option(types.CallArgument) {
  match_argument(signatures.lookup(registry, callee_name), name, args).1
}

// The signature parameter a bound's name names and the argument bound to it.
// With a known signature, that argument is the one carrying the parameter's
// declared Gleam label (a labelled call site, `f(with: cb)`), or the one at the
// parameter's real position (a positional call site); a signature with no
// parameter of that name or label leaves the bound unresolved. With no
// signature, an argument the caller labelled `name` is the only match.
//
// The bound's index in the bounds list is never a fallback: it is only correct
// when every parameter has a bound, and picks the wrong argument when bounds
// are sparse.
fn match_argument(
  signature: Option(List(signatures.ParameterInfo)),
  name: String,
  args: List(types.CallArgument),
) -> #(Option(signatures.ParameterInfo), Option(types.CallArgument)) {
  case signature {
    None -> #(None, find_arg_by_label(args, name))
    Some(params) -> {
      let parameter = signatures.parameter_named(params, name)
      #(parameter, option.then(parameter, argument_for_parameter(_, args)))
    }
  }
}

// The argument a call site passes one parameter of a known signature: the one
// carrying its declared label, else the unlabelled one at its position.
fn argument_for_parameter(
  param: signatures.ParameterInfo,
  args: List(types.CallArgument),
) -> option.Option(types.CallArgument) {
  let by_label = param.label |> option.then(find_arg_by_label(args, _))
  use <- option.lazy_or(by_label)
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
  signatures.parameter_named(params, param_name)
}

// Look up the effects of an argument value. Function references →
// KB lookup, through the boundary that holds foreign code to what declares it
// (so an undeclared `@external` passed as a callback carries the same
// `[Unknown]` a direct call to it does); constructors → pure; local refs
// matching a caller param bound (user-declared or auto-detected fn-typed) →
// that bound's effects; otherwise [Unknown].
fn resolve_argument_effects(
  value: types.ArgumentValue,
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  lexicon: Lexicon,
) -> EffectTerm {
  case value {
    types.FunctionRef(name) -> effects.declared_effects(knowledge_base, name)
    types.ConstructorRef -> effect_term.pure()
    types.LocalRef(name:, scope:) ->
      case reference_bound(caller_param_bounds, lexicon, name, scope) {
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
    types.ReceiverPath(..) -> effect_term.unknown()
    // A constructed record or record-update overlay contributes no callable
    // effect in a first-order position; field forwarding handles it at the
    // receiver argument instead.
    types.Constructed(..) -> effect_term.unknown()
    types.Updated(..) -> effect_term.unknown()
    types.Composite(..) -> effect_term.unknown()
    types.OtherExpression | types.Capture(..) -> effect_term.unknown()
  }
}

// Local call resolution
//
// Resolve same-module calls transitively, memoized over the call-graph SCC
// structure: a collapsible component shares one full-reachability analysis,
// everything else keys precisely on same-SCC ancestors.

fn resolve_unknown_local(
  local_call: LocalCall,
  args: List(types.CallArgument),
  visited: Set(String),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
) -> #(List(CollectedCall), Memo) {
  // A name a lexical binding covers is that binding, which no parameter bound
  // and no traced callable answered for: a module function sharing its name
  // says nothing about it.
  use <- bool.guard(when: local_call.scope != types.ModuleDefinition, return: #(
    [
      plain_call(
        sentinel_call(UnresolvedLocalCall(local_call.function), local_call.span),
        effect_term.unknown(),
      ),
    ],
    memo,
  ))
  // A function already being walked up the call stack: what it does with this
  // call's arguments is the summary that walk is computing.
  use <- bool.guard(when: set.contains(visited, local_call.function), return: #(
    back_edge(
      local_call,
      args,
      function_map,
      context,
      registry,
      reading,
      cache,
      memo,
    ),
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
      let #(declares, memo) =
        declares_for_callers(
          local_definition,
          context,
          function_map,
          knowledge_base,
          registry,
          reading,
          cache,
          memo,
        )
      case declares {
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
            local_call.function,
            local_definition,
            visited,
            function_map,
            context,
            knowledge_base,
            registry,
            reading,
            cache,
            memo,
          )
      }
    }
  }
}

// A call back into `local_call`'s function while it is walked up the stack.
// What that call does with its arguments is the function's own summary, still
// being computed: it is stated as the function's recursion marker applied to
// its callback parameters, which the call site binds as it binds any callee's,
// and the walk of the function resolves. A function with no callback parameter
// does the same thing whatever it is passed, which the walk up the stack
// already gathers.
fn back_edge(
  local_call: LocalCall,
  args: List(types.CallArgument),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
) -> List(CollectedCall) {
  case dict.get(function_map, local_call.function) {
    Error(Nil) -> []
    Ok(definition) ->
      case collapsed(local_call.function, cache) {
        True ->
          case dict.get(memo.collapsed_vars, local_call.function) {
            Ok([_, ..] as variables) -> [
              plain_call(
                types.ResolvedCall(
                  name: QualifiedName(
                    module: context.module_path,
                    function: local_call.function,
                  ),
                  span: local_call.span,
                ),
                effect_term.normalize(TUnion(list.map(variables, TVar))),
              ),
            ]
            _ -> []
          }
        False ->
          case passes_its_frame_on(args, definition, registry, reading) {
            True -> []
            False -> [
              plain_call(
                types.ResolvedCall(
                  name: QualifiedName(
                    module: context.module_path,
                    function: local_call.function,
                  ),
                  span: local_call.span,
                ),
                recursion_application(
                  local_call.function,
                  recursion_variables(
                    local_call.function,
                    definition,
                    cache,
                    memo,
                  ),
                ),
              ),
            ]
          }
      }
  }
}

// Whether a call back into `definition`'s function passes on each parameter
// it was handed, wherever a value of the parameter's type may hold a
// function: the argument is that very parameter, under the binder the frame
// introduced it with, or its type is proven to hold none. Such a call
// contributes an effect set the frame's own walk already holds: every summary
// over an effect set is a constant beside what it runs, so the least fixed
// point is the walk without the call.
fn passes_its_frame_on(
  args: List(types.CallArgument),
  definition: Definition(Function),
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
) -> Bool {
  let binder = definition.definition.location.start
  let parameters = definition.definition.parameters
  list.length(args) == list.length(parameters)
  && list.index_map(parameters, fn(parameter, position) {
    #(parameter, position)
  })
  |> list.all(fn(entry) {
    let #(parameter, position) = entry
    let arg = case parameter.label {
      Some(label) ->
        option.lazy_or(find_arg_by_label(args, label), fn() {
          find_arg_at_position(args, position)
        })
      None -> find_arg_at_position(args, position)
    }
    case arg {
      None -> False
      Some(arg) ->
        passed_on(arg, parameter, binder)
        || holds_no_function(arg, registry, reading)
    }
  })
}

// Whether an argument is the parameter itself, as `binder` introduced it.
fn passed_on(
  arg: types.CallArgument,
  parameter: glance.FunctionParameter,
  binder: Int,
) -> Bool {
  case arg.value, signatures.assignment_name(parameter.name) {
    types.LocalRef(name:, scope: types.LexicalBinding(binder: bound)), Some(own)
    -> name == own && bound == binder
    _, _ -> False
  }
}

// Whether every type girard gives an argument is proven to hold no function.
fn holds_no_function(
  arg: types.CallArgument,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
) -> Bool {
  case typeinfo.types_at(reading, arg.span.start, arg.span.end) {
    [] -> False
    types ->
      list.all(types, fn(type_) {
        case type_ {
          Some(type_) ->
            typedefs.shape(type_, registry.shapes) == typedefs.NoArrows
          None -> False
        }
      })
  }
}

// Whether `function` belongs to a component analysed as one union, where a
// call back in is already gathered by the walk of the component.
fn collapsed(function: String, cache: LocalCache) -> Bool {
  case dict.get(cache.scc_id, function) {
    Ok(scc) -> set.contains(cache.collapsible, scc)
    Error(Nil) -> False
  }
}

// The variables of `function`'s parameters its summary is stated over: what
// its walk settled on, else its callback parameters.
fn recursion_variables(
  function: String,
  definition: Definition(Function),
  cache: LocalCache,
  memo: Memo,
) -> List(String) {
  case dict.get(memo.recursion_vars, function) {
    Ok(variables) -> variables
    Error(Nil) ->
      list.map(local_polymorphic_bounds(definition, cache), fn(bound) {
        bound.name
      })
  }
}

// The walk of `function` over `walk`, with every call back into it stated over
// a set of its parameters' variables closed under the walk: where the walk
// names a variable of a parameter the set lacks — a field of a record
// parameter, or one a call back passes on in another's place — it is walked
// again from `memo` with that variable added, so the summary binds every way
// its effects depend on its arguments. The calls back are then resolved.
fn walk_recursive(
  function: String,
  definition: Definition(Function),
  bound: fn() -> PathBound,
  cache: LocalCache,
  memo: Memo,
  walk: fn(Memo) -> #(List(CollectedCall), Memo),
) -> #(List(CollectedCall), Memo) {
  // A function on no cycle is never called back into: its walk names no
  // marker of its own.
  let scc = dict.get(cache.scc_id, function) |> result.unwrap(-1)
  use <- bool.lazy_guard(
    when: !set.contains(cache.recursive, scc),
    return: fn() { walk(memo) },
  )
  closed_walk(
    function,
    definition,
    recursion_variables(function, definition, cache, memo),
    bound(),
    memo,
    walk,
  )
}

// What the variables of a recursive group's calls back in may name, read off
// the group alone. Every variable the group's first walk names is admitted,
// `written`: that walk names every path the source writes, and those it
// builds through calls out of the group. A variable discovered past those is
// admitted up to `nesting`, the deepest nesting of the types the group's
// parameters are written with, beyond the longest path the first walk names,
// since a call back in builds a longer one only out of a value of a type that
// holds itself. The number discovered is admitted up to the group's
// `parameters` times the paths so long over the labels its first walk names,
// `labels` of them. Variables past either read as `[Unknown]`.
type PathBound {
  PathBound(
    // Measured only where a variable outgrows the first walk's longest path.
    nesting: fn() -> Int,
    parameters: Int,
    written: Set(String),
    longest: Option(Int),
    labels: Int,
  )
}

// The bound of the group `members` form, before its first walk.
fn path_bound(
  members: List(String),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  registry: SignatureRegistry,
) -> PathBound {
  let parameters =
    list.fold(members, 0, fn(count, member) {
      case dict.get(function_map, member) {
        Ok(definition) -> count + list.length(definition.definition.parameters)
        Error(Nil) -> count
      }
    })
  let nesting = fn() {
    list.fold(members, 0, fn(deepest, member) {
      signatures.lookup(registry, QualifiedName(context.module_path, member))
      |> option.unwrap([])
      |> list.fold(deepest, fn(deepest, parameter) {
        case parameter.annotation {
          Some(type_) ->
            int.max(deepest, typedefs.type_nesting(registry.types, type_))
          None -> deepest
        }
      })
    })
  }
  PathBound(nesting:, parameters:, written: set.new(), longest: None, labels: 0)
}

// The bound once a first walk named `variables`.
fn bounded_by(bound: PathBound, variables: List(String)) -> PathBound {
  case bound.longest {
    Some(_) -> bound
    None ->
      PathBound(
        ..bound,
        written: set.from_list(variables),
        longest: Some(
          list.fold(variables, 0, fn(longest, variable) {
            int.max(longest, path_length(variable))
          }),
        ),
        labels: list.flat_map(variables, fn(variable) {
            list.drop(string.split(variable, "."), 1)
          })
          |> list.unique
          |> list.length,
      )
  }
}

// Whether `variables` leave what `bound` admits: of those the first walk did
// not name, one names a longer path, or there are more of them than paths so
// long allow.
fn beyond(bound: PathBound, variables: List(String)) -> Bool {
  let discovered =
    list.filter(variables, fn(variable) {
      !set.contains(bound.written, variable)
    })
  let past = fn(depth) {
    list.any(discovered, fn(variable) { path_length(variable) > depth })
    || list.length(discovered)
    > bound.parameters * { depth + 1 } * { bound.labels + 1 }
  }
  // Within the first walk's own reach the variables are within any depth
  // the nesting adds to it.
  let longest = option.unwrap(bound.longest, 0)
  past(longest) && past(bound.nesting() + longest)
}

// How many field labels a variable's path passes.
fn path_length(variable: String) -> Int {
  list.length(string.split(variable, ".")) - 1
}

// The variables only grow, and within the finite set `bound` admits, as
// `collapsed_rounds`' do; a summary whose variables leave it is read with
// `[Unknown]` beside it.
fn closed_walk(
  function: String,
  definition: Definition(Function),
  variables: List(String),
  bound: PathBound,
  before: Memo,
  walk: fn(Memo) -> #(List(CollectedCall), Memo),
) -> #(List(CollectedCall), Memo) {
  let #(calls, memo) =
    walk(
      Memo(
        ..before,
        recursion_vars: dict.insert(before.recursion_vars, function, variables),
      ),
    )
  let marker = recursion_marker(function)
  let named = calls_free_vars(calls)
  let walked = parameter_variables(named, definition)
  let bound = bounded_by(bound, list.append(variables, walked))
  let missing = case set.contains(named, marker) {
    False -> []
    True ->
      list.filter(walked, fn(variable) { !list.contains(variables, variable) })
  }
  case missing, beyond(bound, list.append(variables, missing)) {
    [], _ -> #(resolved_recursion(calls, function, variables), memo)
    _, True -> #(
      resolved_recursion(
        [
          plain_call(unknown_call(function, definition), effect_term.unknown()),
          ..calls
        ],
        function,
        variables,
      ),
      memo,
    )
    _, False ->
      closed_walk(
        function,
        definition,
        list.append(variables, missing),
        bound,
        before,
        walk,
      )
  }
}

// A call standing for `function` itself, at its declaration.
fn unknown_call(
  function: String,
  definition: Definition(Function),
) -> ResolvedCall {
  types.ResolvedCall(
    name: QualifiedName(module: "", function:),
    span: definition.definition.location,
  )
}

// The variables among `named` that stand for one of `definition`'s parameters
// or a path into one, in name order.
fn parameter_variables(
  named: Set(String),
  definition: Definition(Function),
) -> List(String) {
  rooted_variables(
    variables_by_root(named),
    named_function_params(definition.definition),
  )
}

// The variables of `named` that are not recursion markers, by the parameter
// each is rooted at: read once for every member asking.
pub fn variables_by_root(
  named: Set(String),
) -> dict.Dict(String, List(String)) {
  set.fold(named, dict.new(), fn(acc, variable) {
    case is_recursion_marker(variable) {
      True -> acc
      False ->
        dict.upsert(acc, path_root(variable), fn(existing) {
          [variable, ..option.unwrap(existing, [])]
        })
    }
  })
}

// The variables `by_root` holds that are rooted at one of `parameters`,
// sorted.
pub fn rooted_variables(
  by_root: dict.Dict(String, List(String)),
  parameters: Set(String),
) -> List(String) {
  parameters
  |> set.to_list
  |> list.flat_map(fn(parameter) {
    dict.get(by_root, parameter) |> result.unwrap([])
  })
  |> list.sort(string.compare)
}

// The lifted operator of a reference to `name`, a function already being walked
// up the stack, at a site supplying its callbacks at `positions`: as
// `lift_local_function` abstracts the function's walk, over its recursion
// marker in place of the walk. A function with no callback parameter
// contributes nothing beyond what the walk up the stack gathers.
fn recursive_reference(
  name: String,
  definition: Definition(Function),
  positions: List(Int),
  cache: LocalCache,
  memo: Memo,
) -> EffectTerm {
  case collapsed(name, cache) {
    True -> pure_operator(positions)
    False ->
      abstract_over_slots(
        signatures.supplied_slots(
          cached_callback_slots(definition.definition, cache),
          positions,
        ),
        recursion_application(
          name,
          recursion_variables(name, definition, cache, memo),
        ),
      )
  }
}

// `function`'s recursion marker applied to the variables of its parameters its
// summary is stated over, in that order.
fn recursion_application(
  function: String,
  variables: List(String),
) -> EffectTerm {
  list.fold(variables, TVar(recursion_marker(function)), fn(operator, variable) {
    types.TApp(operator, TVar(variable))
  })
}

// The variable a call back into `function` is stated through until the walk of
// `function` resolves it.
fn recursion_marker(function: String) -> String {
  "<recursion:" <> function <> ">"
}

// The variable what `function` returns is stated through until the computation
// of its returned operator resolves it.
fn returns_marker(function: String) -> String {
  "<returns:" <> function <> ">"
}

fn is_recursion_marker(name: String) -> Bool {
  string.starts_with(name, "<recursion:")
  || string.starts_with(name, "<returns:")
}

// What marks `function`'s returned operator as being computed up the stack,
// beside the walked functions' own names.
fn returns_key(function: String) -> String {
  "<returns>" <> function
}

// Whether `variable` is the marker of a call back into a function, or into a
// producer's returned operator, whose walk up the stack resolves it.
fn owned_up_the_stack(variable: String, visited: Set(String)) -> Bool {
  case variable {
    "<recursion:" <> rest -> set.contains(visited, string.drop_end(rest, 1))
    "<returns:" <> rest ->
      set.contains(visited, returns_key(string.drop_end(rest, 1)))
    _ -> False
  }
}

// The function an entry of the walked set names.
fn walked_function(entry: String) -> String {
  case entry {
    "<returns>" <> function -> function
    function -> function
  }
}

// `calls`, gathered by walking `function` over its callback parameters
// `bounds`, with each call back into it resolved: the function's summary is the
// least fixed point of its body over those calls, iterated from pure, and each
// call back reads that summary applied to its own arguments. Iteration stops at
// `recursion_fuel` rounds, past which the summary reads `[Unknown]`.
fn resolved_recursion(
  calls: List(CollectedCall),
  function: String,
  params: List(String),
) -> List(CollectedCall) {
  let marker = recursion_marker(function)
  use <- bool.guard(
    when: !set.contains(calls_free_vars(calls), marker),
    return: calls,
  )
  let body = union_of(calls)
  let summary =
    recursion_fixpoint(
      marker,
      params,
      body,
      effect_term.pure(),
      effect_term.unknown(),
      growth_bound(body, marker),
      0,
    )
  let bindings = dict.from_list([#(marker, summary)])
  let resolve = fn(term) {
    case set.contains(effect_term.free_vars(term), marker) {
      True -> effect_term.normalize(effect_term.subst(term, bindings))
      False -> term
    }
  }
  list.map(calls, fn(one) {
    CollectedCall(
      ..one,
      resolution: Resolution(
        ..one.resolution,
        term: resolve(collected_term(one)),
        fallback: types.map_fallback(one.resolution.fallback, resolve),
      ),
    )
  })
}

// The least fixed point of `body` over `marker`, iterated from `current`:
// `top` over `params` once `bound` rounds pass without the iteration settling,
// or once a round's term outgrows `work_bound`'s size, which bounds the work of
// every round's substitution and normalization.
fn recursion_fixpoint(
  marker: String,
  params: List(String),
  body: EffectTerm,
  current: EffectTerm,
  top: EffectTerm,
  bound: Int,
  rounds: Int,
) -> EffectTerm {
  let next =
    effect_term.normalize(effect_term.subst(
      body,
      dict.from_list([#(marker, wrap_binders(params, current))]),
    ))
  case next == current, rounds + 1 >= bound || outgrows(next, body) {
    True, _ -> wrap_binders(params, next)
    False, True -> wrap_binders(params, top)
    False, False ->
      recursion_fixpoint(marker, params, body, next, top, bound, rounds + 1)
  }
}

// Whether a round's term has grown past the work a fixed point of `body` is
// given: 16 times the size of `body`. A union of `body`'s labels and variables
// is never larger than `body`; only a term applying an operator to what the
// last round built grows past it.
fn outgrows(term: EffectTerm, body: EffectTerm) -> Bool {
  term_size(term, 0) > 16 * term_size(body, 0)
}

// How many nodes `term` holds, beside `acc`.
fn term_size(term: EffectTerm, acc: Int) -> Int {
  case term {
    types.TLabels(labels) -> acc + 1 + set.size(labels)
    types.TUnion(terms) ->
      list.fold(terms, acc + 1, fn(acc, one) { term_size(one, acc) })
    types.TApp(operator, argument) ->
      term_size(argument, term_size(operator, acc + 1))
    types.TAbs(_, body) -> term_size(body, acc + 1)
    types.TTop | TVar(_) -> acc + 1
  }
}

// How many rounds the fixed point of `body` over `marker` may take. Where
// `body` applies nothing but `marker`, each round adds one of the labels and
// variables `body` names, or settles, so it settles within that many rounds
// and the bound is never reached. Where it applies an operator, a round can
// build a larger term than the last; such a term is given 32 rounds more.
fn growth_bound(body: EffectTerm, marker: String) -> Int {
  let atoms = term_atoms(body)
  case applies_an_operator(body, marker) {
    False -> atoms + 2
    True -> atoms + 34
  }
}

// The labels and variables `term` names, counted.
fn term_atoms(term: EffectTerm) -> Int {
  let labels = term_labels(term, set.new())
  set.size(labels) + set.size(effect_term.free_vars(term))
}

fn term_labels(term: EffectTerm, acc: Set(String)) -> Set(String) {
  case term {
    types.TLabels(labels) -> set.union(acc, labels)
    types.TUnion(terms) ->
      list.fold(terms, acc, fn(acc, one) { term_labels(one, acc) })
    types.TApp(operator, argument) ->
      term_labels(argument, term_labels(operator, acc))
    types.TAbs(_, body) -> term_labels(body, acc)
    types.TTop | TVar(_) -> acc
  }
}

// Whether `term` applies or abstracts anything but `marker`.
fn applies_an_operator(term: EffectTerm, marker: String) -> Bool {
  case term {
    types.TApp(operator, argument) ->
      !applies_only(operator, marker) || applies_an_operator(argument, marker)
    types.TUnion(terms) -> list.any(terms, applies_an_operator(_, marker))
    types.TAbs(_, _) -> True
    types.TLabels(_) | types.TTop | TVar(_) -> False
  }
}

// Whether `operator` is `marker` applied to arguments that apply nothing.
fn applies_only(operator: EffectTerm, marker: String) -> Bool {
  case operator {
    TVar(name) -> name == marker
    types.TApp(inner, argument) ->
      applies_only(inner, marker) && !applies_an_operator(argument, marker)
    _ -> False
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
//
// A catalog entry answers only where this walk would not outrank it. The name
// it keys is arbitrated by `effects.with_path_dep_inferred` on the callee's own
// unspecialized term — resolved answers from source, unresolved or polymorphic
// yields to the entry — and the same question is asked here, so a same-module
// caller and a cross-module one are charged one answer for one callee. An
// `@external` keeps the entry whatever its body reads, and so does every
// written declaration.
fn declares_for_callers(
  local_definition: Definition(Function),
  context: ImportContext,
  function_map: dict.Dict(String, Definition(Function)),
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
) -> #(Bool, Memo) {
  let name = local_definition.definition.name
  let qualified = QualifiedName(module: context.module_path, function: name)
  use <- bool.lazy_guard(
    when: foreign_definition(
      local_definition,
      walk_targets(context, knowledge_base),
    ),
    return: fn() { #(True, memo) },
  )
  case declaration_resolution(knowledge_base, qualified) {
    None -> #(False, memo)
    Some(Resolution(origin: None, ..)) -> #(True, memo)
    Some(Resolution(origin: Some(origin), ..)) ->
      case effects.is_catalog_origin(origin) {
        False -> #(True, memo)
        True ->
          catalog_answers_for(
            name,
            qualified,
            local_definition,
            function_map,
            context,
            knowledge_base,
            registry,
            reading,
            cache,
            memo,
          )
      }
  }
}

// Whether the catalog's entry for a native same-module name answers, weighed
// once and remembered.
//
// The term weighed is the one the module pass publishes for that name: its own
// body walked from no ancestor, under its own callback bounds, groomed as the
// published line is. Not the analysis a *call* into it yields — for a member of
// a collapsible recursive group that is the group's pooled reachability, which
// prices every member alike and so cannot see a catalog boundary cutting one
// edge inside the group. Weighing that pooled term left a caller charged an
// entry the callee's own published reading had already overtaken.
//
// A name already being weighed answers `True`: a cycle back into it is charged
// the catalog, which terminates the walk on the conservative half. The verdict
// that settles is read by both this walk and the published one, so the two
// agree on the callee however the cycle was cut.
fn catalog_answers_for(
  name: String,
  qualified: QualifiedName,
  local_definition: Definition(Function),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
) -> #(Bool, Memo) {
  case dict.get(memo.catalog_verdicts, name) {
    Ok(settled) -> #(settled, memo)
    Error(Nil) -> {
      let memo =
        Memo(
          ..memo,
          catalog_verdicts: dict.insert(memo.catalog_verdicts, name, True),
        )
      let fn_typed_params = unbound_fn_typed_params(local_definition, [], cache)
      let #(body_kb, memo) =
        body_walk(
          knowledge_base,
          memo,
          local_definition,
          context.package_targets,
        )
      let #(collected, memo) =
        collect_effects(
          without_returned_closure(local_definition.definition),
          function_map,
          context,
          body_kb,
          set.new(),
          effective_bounds([], fn_typed_params),
          registry,
          reading,
          FunctionFrame,
          cache,
          memo,
        )
      let #(published, _field_vars) =
        groom_published_term(union_of(collected), fn_typed_params)
      let answers =
        !effects.resolves_over_catalog(knowledge_base, qualified, published)
      #(
        answers,
        Memo(
          ..memo,
          catalog_verdicts: dict.insert(memo.catalog_verdicts, name, answers),
        ),
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
  function: String,
  local_definition: Definition(Function),
  visited: Set(String),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
) -> #(List(CollectedCall), Memo) {
  let scc = dict.get(cache.scc_id, function) |> result.unwrap(-1)
  case set.contains(cache.collapsible, scc) {
    True ->
      collapsed_member_view(
        function,
        scc,
        function_map,
        context,
        knowledge_base,
        registry,
        reading,
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
      let key = memo_key(function, visited, cache)
      case dict.get(memo.locals, key) {
        Ok(cached) -> #(cached, memo)
        Error(Nil) -> {
          let #(result, memo) =
            walk_local(
              function,
              local_definition,
              set.insert(visited, function),
              nested_bounds,
              function_map,
              context,
              knowledge_base,
              registry,
              reading,
              cache,
              memo,
            )
          #(result, Memo(..memo, locals: dict.insert(memo.locals, key, result)))
        }
      }
    }
  }
}

// The body of `function` walked from inside its own frame, its calls back in
// stated over its parameters' variables.
fn walk_local(
  function: String,
  local_definition: Definition(Function),
  visited: Set(String),
  bounds: List(ParamBound),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
) -> #(List(CollectedCall), Memo) {
  use memo <- walk_recursive(
    function,
    local_definition,
    fn() { path_bound([function], function_map, context, registry) },
    cache,
    memo,
  )
  collect_effects(
    without_returned_closure(local_definition.definition),
    function_map,
    context,
    knowledge_base,
    visited,
    bounds,
    registry,
    reading,
    FunctionFrame,
    cache,
    memo,
  )
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
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
) -> #(List(CollectedCall), Memo) {
  let members = dict.get(cache.members, scc) |> result.unwrap([])
  case dict.get(memo.sccs, scc), set.contains(memo.collapsing, scc) {
    Ok(cached), _ -> #(cached, memo)
    Error(Nil), True -> #(reentered_scc(members, function_map, context), memo)
    Error(Nil), False -> {
      let outer = memo.collapsing
      let memo = Memo(..memo, collapsing: set.insert(outer, scc))
      let #(result, memo) = case set.contains(cache.recursive, scc) {
        True ->
          collapsed_rounds(
            members,
            function_map,
            context,
            knowledge_base,
            registry,
            reading,
            cache,
            memo,
            dict.take(memo.collapsed_vars, members),
            path_bound(members, function_map, context, registry),
          )
        // A component that never calls back into itself is walked once.
        False ->
          collapsed_union(
            members,
            function_map,
            context,
            knowledge_base,
            registry,
            reading,
            cache,
            memo,
          )
      }
      #(
        result,
        Memo(
          ..memo,
          collapsing: outer,
          sccs: dict.insert(memo.sccs, scc, result),
          member_views: member_views(
            members,
            result,
            function_map,
            memo.member_views,
          ),
        ),
      )
    }
  }
}

// `function`'s answer from its component's union: the view the union's
// completion stored, or `member_view` of the union while it is still being
// built.
fn collapsed_member_view(
  function: String,
  scc: Int,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
) -> #(List(CollectedCall), Memo) {
  case dict.get(memo.member_views, function) {
    Ok(view) -> #(view, memo)
    Error(Nil) -> {
      let #(calls, memo) =
        collapsed_scc(
          scc,
          function_map,
          context,
          knowledge_base,
          registry,
          reading,
          cache,
          memo,
        )
      case dict.get(memo.member_views, function) {
        Ok(view) -> #(view, memo)
        Error(Nil) -> {
          let members = dict.get(cache.members, scc) |> result.unwrap([])
          let views = member_views(members, calls, function_map, dict.new())
          #(dict.get(views, function) |> result.unwrap(calls), memo)
        }
      }
    }
  }
}

// Each member's answer from a collapsed component's union, beside `views`:
// without the variables of parameters only other members name, which stand
// for what a call into that member passes, and which each call a member makes
// back in already states bound to its own arguments.
fn member_views(
  members: List(String),
  calls: List(CollectedCall),
  function_map: dict.Dict(String, Definition(Function)),
  views: dict.Dict(String, List(CollectedCall)),
) -> dict.Dict(String, List(CollectedCall)) {
  let parameters =
    list.map(members, fn(member) {
      #(
        member,
        dict.get(function_map, member)
          |> result.map(fn(definition) {
            named_function_params(definition.definition)
          })
          |> result.unwrap(set.new()),
      )
    })
  let named = calls_free_vars(calls)
  list.fold(parameters, views, fn(views, entry) {
    let #(member, own) = entry
    let foreign =
      list.fold(parameters, set.new(), fn(acc, other) {
        case other.0 == member {
          True -> acc
          False -> set.union(acc, other.1)
        }
      })
      |> set.difference(own)
    let dropped =
      named
      |> set.filter(fn(variable) { set.contains(foreign, path_root(variable)) })
      |> set.to_list
      |> list.map(fn(variable) { #(variable, effect_term.pure()) })
      |> dict.from_list
    dict.insert(views, member, case dict.is_empty(dropped) {
      True -> calls
      False -> list.map(calls, without_variables(_, dropped))
    })
  })
}

// A collected call with `dropped`'s variables read as nothing.
fn without_variables(
  one: CollectedCall,
  dropped: dict.Dict(String, EffectTerm),
) -> CollectedCall {
  CollectedCall(
    ..one,
    resolution: Resolution(
      ..one.resolution,
      term: effect_term.normalize(effect_term.subst(
        one.resolution.term,
        dropped,
      )),
    ),
  )
}

// The members of a collapsed component walked as one union, each call back in
// from inside contributing the variables of the callee's parameters the last
// round's union names, bound to that call's arguments — a field of a record
// parameter rebound on the way round reaches the walk. Repeated until no
// member's variables change. The variables only grow, and settle within the
// finite set a `PathBound` admits; a union whose variables leave it is read
// with `[Unknown]`.
fn collapsed_rounds(
  members: List(String),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
  estimate: dict.Dict(String, List(String)),
  bound: PathBound,
) -> #(List(CollectedCall), Memo) {
  let memo =
    Memo(..memo, collapsed_vars: dict.merge(memo.collapsed_vars, estimate))
  let #(result, memo) =
    collapsed_union(
      members,
      function_map,
      context,
      knowledge_base,
      registry,
      reading,
      cache,
      memo,
    )
  let by_root = variables_by_root(calls_free_vars(result))
  let next =
    list.fold(members, estimate, fn(estimate, member) {
      case dict.get(function_map, member) {
        Ok(definition) ->
          case
            rooted_variables(
              by_root,
              named_function_params(definition.definition),
            )
          {
            [] -> estimate
            variables -> {
              let before = dict.get(estimate, member) |> result.unwrap([])
              list.append(before, variables)
              |> list.unique
              |> list.sort(string.compare)
              |> dict.insert(estimate, member, _)
            }
          }
        Error(Nil) -> estimate
      }
    })
  let settled =
    list.all(members, fn(member) {
      dict.get(next, member) == dict.get(estimate, member)
    })
  let bound = bounded_by(bound, list.flatten(dict.values(next)))
  let growing = beyond(bound, list.flatten(dict.values(next)))
  case settled, growing {
    True, _ -> #(result, memo)
    False, True -> #(
      list.append(reentered_scc(members, function_map, context), result),
      memo,
    )
    False, False ->
      collapsed_rounds(
        members,
        function_map,
        context,
        knowledge_base,
        registry,
        reading,
        cache,
        memo,
        next,
        bound,
      )
  }
}

// One walk of a collapsed component's members as one union.
fn collapsed_union(
  members: List(String),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
  cache: LocalCache,
  memo: Memo,
) -> #(List(CollectedCall), Memo) {
  let scc_set = set.from_list(members)
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
      reading,
      cache,
      memo,
    )
  })
}

// Re-entering a component that is being collapsed is a cycle the call graph
// should have closed inside it; read it as `[Unknown]` at the first member's
// declaration rather than expanding the component again.
fn reentered_scc(
  members: List(String),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
) -> List(CollectedCall) {
  let span = case members {
    [first, ..] ->
      case dict.get(function_map, first) {
        Ok(definition) -> definition.definition.location
        Error(Nil) -> Span(0, 0)
      }
    [] -> Span(0, 0)
  }
  let name = case members {
    [first, ..] -> first
    [] -> ""
  }
  [
    plain_call(
      types.ResolvedCall(
        name: QualifiedName(module: context.module_path, function: name),
        span:,
      ),
      effect_term.unknown(),
    ),
  ]
}

// One member's share of its component's collapsed analysis: each variant the
// walk reaches, walked as a callee.
fn collapsed_member(
  name: String,
  acc: List(CollectedCall),
  scc_set: Set(String),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  reading: typeinfo.ModuleReading,
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
          reading,
          FunctionFrame,
          cache,
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
  reading: typeinfo.ModuleReading,
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
              reading,
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
              registry,
              reading,
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
        types.LocalRef(..) -> polymorphic_field_effect()
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
              reading,
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
// directly, or a `LocalRef` no binding covered naming one of the current
// module's own functions. A `LocalRef` to a binding is a parameter (or other
// local), returned as `None` so the caller treats it as polymorphic. `None` too
// for constructors and inline expressions.
fn field_value_function(
  value: types.ArgumentValue,
  module_path: String,
  module_functions: Set(String),
) -> option.Option(types.QualifiedName) {
  case value {
    types.FunctionRef(name:) -> Some(name)
    types.LocalRef(name:, scope: types.ModuleDefinition) ->
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
  reading: typeinfo.ModuleReading,
  call_args: dict.Dict(#(Int, Int), List(types.CallArgument)),
  caller_param_bounds: List(ParamBound),
  lexicon: Lexicon,
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
      resolve_proven_field(
        value,
        field_call,
        context,
        knowledge_base,
        function_map,
        visited,
        reading,
        lexicon,
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
        reading,
        call_args,
        caller_param_bounds,
        lexicon,
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
  reading: typeinfo.ModuleReading,
  lexicon: Lexicon,
  call_args: dict.Dict(#(Int, Int), List(types.CallArgument)),
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
  scc_ids: LocalCache,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(Resolution, Memo) {
  // A value naming a binding is that binding, never a same-named module
  // function: only a reference no binding covered reads these.
  let module_functions = set.from_list(dict.keys(function_map))
  let #(field_effect, origin, memo) =
    value_field_effect(
      value,
      module_functions,
      context,
      knowledge_base,
      function_map,
      visited,
      registry,
      reading,
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
  let #(term, resolved_fallback, memo) =
    resolve_field_effect(
      field_effect,
      wired_fallback,
      field_call,
      call_args,
      knowledge_base,
      caller_param_bounds,
      lexicon,
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

// Rule 2 wherever a field call is charged: a hand-written field bound on the
// enclosing `check` line (`check f(recv.field: [..])`). User-declared, so it
// wins over the `type` line and the param fallback, and its effects answer
// verbatim — a concrete effect set, no call-site substitution.
fn field_bound_resolution(
  field_call: types.FieldCall,
  param_bounds: List(ParamBound),
) -> Option(Resolution) {
  let target = field_call_target(field_call)
  case list.find(param_bounds, fn(bound) { bound.name == target }) {
    Ok(bound) -> Some(plain_resolution(bound.effects))
    Error(Nil) -> None
  }
}

fn resolve_unproven_field(
  field_call: types.FieldCall,
  function: Function,
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  reading: typeinfo.ModuleReading,
  call_args: dict.Dict(#(Int, Int), List(types.CallArgument)),
  caller_param_bounds: List(ParamBound),
  lexicon: Lexicon,
  registry: SignatureRegistry,
  lift_operator_arg: fn(types.ArgumentValue, List(Int), Memo) ->
    #(Result(EffectTerm, Nil), Memo),
  memo: Memo,
) -> #(Resolution, Memo) {
  // The canonical receiver — a parameter alias (`let f = options`) resolves
  // through the parameter it stands for — so bound matching, `type`-line lookup,
  // and the field variable all key on the path the bare parameter would use.
  let receiver_object = field_call_receiver(field_call)
  case field_bound_resolution(field_call, caller_param_bounds) {
    Some(resolution) -> #(resolution, memo)
    None -> {
      let receiver_type =
        typeinfo.receiver_type(
          reading.expressions,
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
              lexicon,
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
  lexicon: Lexicon,
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
      lexicon,
    ),
    fallback,
    memo,
  ))
  case has_vars(field_effect.effects), field_effect.source {
    False, _ -> #(field_effect.effects, fallback, memo)
    True, None -> #(
      effect_term.close(field_effect.effects),
      types.map_fallback(fallback, effect_term.close),
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
          lexicon,
          registry,
          lift_operator_arg,
          memo,
        )
      let bind = fn(term) {
        effect_term.close(effect_term.subst(term, bindings))
      }
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
// variable still free after application is closed to `[Unknown]`, as in
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
  lexicon: Lexicon,
) -> EffectTerm {
  let arg_terms =
    args
    |> list.sort(fn(a, b) { int.compare(a.position, b.position) })
    |> list.map(fn(arg) {
      resolve_argument_effects(
        arg.value,
        knowledge_base,
        caller_param_bounds,
        lexicon,
      )
    })
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
      |> effect_term.close
    _ -> effect_term.close(apply_args(operator, arg_terms))
  }
}

// Apply an operator to argument effect terms in order, building the curried
// `TApp` spine the reducer β-reduces.
fn apply_args(operator: EffectTerm, arg_terms: List(EffectTerm)) -> EffectTerm {
  list.fold(arg_terms, operator, fn(acc, arg) { types.TApp(acc, arg) })
}

// girard's reading of an ambiguous call
//
// The same question the shadowed-receiver split answers from the syntax and the
// receiver's type, answered instead from what girard resolved the reference to.
// It decides nothing here: it is recorded beside graded's own answer so the two
// can be compared per site.
//
// Three states and no fourth. A missing annotation, a skipped function, a
// dropped definition, a span girard recorded nothing at, an access it reached
// after the receiver's type was fixed, and every resolution kind that is not a
// call target all read `Undecided`, each keeping the reason it got there by.

// What girard resolved the reference at `access_span` to, inside `definition`.
//
// The checks run in the order the absences nest: a dropped definition was never
// walked, a skipped one was walked and abandoned, and only then is the absence
// of a resolution at the span the span's own. The drop and the skip are read
// alike, by the definition's own span — so one half of a `@target` pair being
// left out of the build, or declined, says nothing about the half beside it.
pub fn classify_typed(
  access_span: Span,
  definition: Function,
  evidence: typeinfo.ModuleEvidence,
) -> TypedClassification {
  use <- bool.guard(
    typeinfo.is_dropped(
      evidence.dropped,
      definition.location.start,
      definition.location.end,
    ),
    Undecided(DefinitionDropped),
  )
  case
    typeinfo.skip_reason(
      evidence.skipped,
      definition.location.start,
      definition.location.end,
    )
  {
    Some(bucket) -> Undecided(FunctionSkipped(bucket))
    None ->
      case
        typeinfo.resolution_at(
          evidence.resolutions,
          access_span.start,
          access_span.end,
        )
      {
        None -> Undecided(NoResolutionAtSpan)
        Some(resolution) -> resolved_classification(resolution)
      }
  }
}

// One `girard.Resolution` as a classification. Only the two kinds that name a
// call target answer; the rest keep their kind as the reason.
fn resolved_classification(
  resolution: girard.Resolution,
) -> TypedClassification {
  case resolution {
    girard.RecordField(receiver: girard.Named(module, name, _), label:) ->
      ProvedFieldCall(receiver: #(module, name), label:)
    girard.RecordField(..) -> Undecided(ReceiverNotNominal)
    girard.ModuleFn(module:, name:) -> ProvedModuleCall(module:, name:)
    girard.ModuleConstant(..) -> Undecided(NotACallTarget("ModuleConstant"))
    girard.Constructor(..) -> Undecided(NotACallTarget("Constructor"))
    girard.LocalVariable(..) -> Undecided(NotACallTarget("LocalVariable"))
    girard.Unresolved(girard.RecordAccessUnknownType) ->
      Undecided(ReceiverTypeUnknown)
  }
}

// A girard error as a stable, constructor-level bucket. `Unsupported` splits by
// its feature string, which is the one part of an error that names a distinct
// gap rather than a distinct program.
pub fn error_bucket(error: girard.Error) -> String {
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
    girard.MissingArgument -> "MissingArgument"
    girard.Unsupported(feature) -> "Unsupported(" <> feature <> ")"
    girard.ParseFailed(..) -> "ParseFailed"
  }
}

// The dual run
//
// Every ambiguous call in the module classified both ways and the pair
// compared. A pass of its own beside `check`: it lowers no effect, recurses
// into no callee and touches no memo, so a function three callers reach is
// walked here once, as itself.

// Classify every ambiguous call in every top-level definition of `module`,
// whether or not a `check` line names one, and compare graded's answer with
// girard's.
pub fn classify_module(
  module: Module,
  module_path: String,
  knowledge_base: KnowledgeBase,
  reading: typeinfo.ModuleReading,
  package_targets: types.PackageTargets,
) -> List(ClassificationCheck) {
  let context =
    module_import_context(module, module_path, knowledge_base, package_targets)
  list.flat_map(module.functions, fn(definition) {
    classify_definition(
      definition.definition,
      module_path,
      definition_imports(
        context,
        definition,
        types.declaration_targets(package_targets),
      ),
      reading,
    )
  })
}

// One definition's rows. The body is extracted once, its ambiguous calls read
// off the result, and the shadowed split run over the same field calls
// `collect_effects` runs it over — so the classification compared is the one
// charged, joined back on the call span each row carries.
pub fn classify_definition(
  function: Function,
  module_path: String,
  context: ImportContext,
  reading: typeinfo.ModuleReading,
) -> List(ClassificationCheck) {
  let result = extract.extract_function_calls(function, context)
  let split = split_shadowed_field_calls(result.field, reading, function)
  let moved =
    list.fold(split.module_reads, dict.new(), fn(acc, call) {
      dict.insert(acc, extract.span_key(call.span), call.name.module)
    })
  let undecided =
    list.fold(split.undecided, dict.new(), fn(acc, entry) {
      dict.insert(acc, extract.span_key(entry.call.span), #(
        entry.shadowed,
        entry.reason,
      ))
    })
  list.map(result.ambiguous, fn(row) {
    let graded = graded_classification(row, moved, undecided)
    let typed = classify_typed(row.site.access_span, function, reading.evidence)
    ClassificationCheck(
      module: module_path,
      function: function.name,
      object: row.site.object,
      label: row.site.label,
      span: row.site.access_span,
      graded:,
      typed:,
    )
  })
}

// graded's final answer for one row: the extractor's verdict, with a field call
// the split moved to the module read as the module instead, and one it
// established neither reading for read as the `[Unknown]` it was charged.
// `moved` and `undecided` are keyed by call span rather than zipped in list
// order, since a body calling the same label twice — one receiver narrowed, one
// not — moves one and keeps the other.
fn graded_classification(
  row: extract.AmbiguousCall,
  moved: dict.Dict(#(Int, Int), String),
  undecided: dict.Dict(#(Int, Int), #(String, UndecidedReason)),
) -> GradedClassification {
  case row.verdict {
    extract.AsModule(module:) -> SyntaxModule(module)
    extract.AsWired(value:) -> WiredValue(value)
    extract.AsField(shadowed:) -> {
      let span = extract.span_key(row.site.call_span)
      case dict.get(moved, span), dict.get(undecided, span) {
        Ok(module), _ -> TypeSelectedModule(module)
        Error(Nil), Ok(#(module, reason)) -> UndecidedShadowed(module, reason)
        Error(Nil), Error(Nil) -> Field(shadowed)
      }
    }
  }
}

// How the two classifications on a row stand to each other. Read off the pair
// on demand rather than carried beside it: the row states what each side made
// of the site, and this is the one reading of the two together.
pub fn relate(check: ClassificationCheck) -> Relation {
  case check.typed {
    Undecided(reason:) -> NoTypedEvidence(reason)
    ProvedFieldCall(label:, ..) ->
      Compared(against_field(check.graded, label == check.label))
    ProvedModuleCall(module:, name:) ->
      Compared(against_module(check.graded, module, name == check.label))
  }
}

// graded's answer against a field the inference proved. The two name different
// halves of one site wherever graded answered with the value wired in — that
// does not contradict the member.
//
// `same_label` is the identity half of the comparison: a proved field under
// another label is not this site's answer, so agreement is off the table
// whatever graded made of it. graded's own undecided is derived from the
// inference's answer, so an undecided beside a proved target is either that
// mismatch or an internal inconsistency, and both must be seen.
fn against_field(graded: GradedClassification, same_label: Bool) -> Comparison {
  case graded {
    Field(..) if same_label -> Agree
    WiredValue(..) if same_label -> CompatibleWiredValue
    Field(..)
    | WiredValue(..)
    | UndecidedShadowed(..)
    | SyntaxModule(..)
    | TypeSelectedModule(..) -> Disagree
  }
}

// graded's answer against a module call the inference proved. The wired-value
// cell is the asymmetric one: here graded charged a value where the compiler
// reads the module, which is the undercharge shape and no compatible pair.
//
// Both halves of the identity are weighed: a module call graded read under
// another module, or under another function than the site's label, is not the
// answer graded gave.
fn against_module(
  graded: GradedClassification,
  module: String,
  same_name: Bool,
) -> Comparison {
  case graded {
    SyntaxModule(m) | TypeSelectedModule(m) if m == module && same_name -> Agree
    SyntaxModule(..)
    | TypeSelectedModule(..)
    | UndecidedShadowed(..)
    | Field(..)
    | WiredValue(..) -> Disagree
  }
}

// Shadowed receivers
//
// `use v <- result.try(r)` inside `fn f(result: Type, ..)` is a call to
// `gleam/result.try`, not a field call on `result`: Gleam reads a bare
// identifier that shadows an import as the module wherever the binding's type
// grants no record accessor for the label. Extraction cannot ask what type a
// receiver has, so it carries both readings on the call, and the decision is
// taken here from the type inference's own resolution of the access — the
// compiler's rule already applied, rather than re-derived from the labels each
// variant declares. Where that resolution establishes neither reading, the call
// is charged `[Unknown]` and keeps the reason.

// What a field call whose receiver's name shadows an import reads.
//
// The two readings are not exhaustive: where the type inference resolved the
// site to neither of them — or to a target that is not this site's — the call
// reads as neither, and the reason rides the third state.
//
// `ReadsTheModule` carries the whole name the inference resolved, so the
// lowered call is the pair it named rather than one reassembled from the
// shadowed module and the accessed label.
type ShadowedReading {
  ReadsTheModule(name: QualifiedName)
  ReadsTheField
  ReadsNeither(module: String, reason: UndecidedReason)
}

// What the shadowed-receiver split makes of a module's field calls: the ones the
// receiver's type says are calls to the module its name shadows, the ones that
// stay field calls, and the ones neither reading is established for.
//
// The module reads join the *resolved* list, so each takes the whole resolved
// path — knowledge-base lookup, call-site substitution, origin reporting and
// `graded why` prose — with no separate code of its own. That is why the split
// runs before the resolved fold rather than inside the field loop, which the
// fold has already passed.
//
// `undecided` is charged `[Unknown]` on its own, without going through the field
// resolver: resolving it would answer with the value the receiver was traced to,
// and that value is the *field's* — the reading nothing here established. The
// calls keep their provenance, which the bound matching and the receiver
// canonicalization read for their own purposes and which is not a verdict.
pub type ShadowedSplit {
  ShadowedSplit(
    module_reads: List(ResolvedCall),
    field_reads: List(types.FieldCall),
    undecided: List(UndecidedShadowedCall),
  )
}

// A field call neither reading is established for, with the module its
// receiver's name shadows and the reason the inference established neither.
// `ReadsNeither` is reached under a shadowed receiver and nowhere else, so the
// module is carried on the entry rather than read back out of an `Option` that
// can no longer be empty.
pub type UndecidedShadowedCall {
  UndecidedShadowedCall(
    call: types.FieldCall,
    shadowed: String,
    reason: UndecidedReason,
  )
}

pub fn split_shadowed_field_calls(
  field_calls: List(types.FieldCall),
  reading: typeinfo.ModuleReading,
  function: Function,
) -> ShadowedSplit {
  use split, call <- list.fold_right(field_calls, ShadowedSplit([], [], []))
  case shadowed_module_read(call, function, reading) {
    ReadsTheModule(name:) ->
      ShadowedSplit(..split, module_reads: [
        types.ResolvedCall(name:, span: call.span),
        ..split.module_reads
      ])
    ReadsTheField ->
      ShadowedSplit(..split, field_reads: [call, ..split.field_reads])
    ReadsNeither(module: module_path, reason:) ->
      ShadowedSplit(..split, undecided: [
        UndecidedShadowedCall(call:, shadowed: module_path, reason:),
        ..split.undecided
      ])
  }
}

// Which of the two readings a shadowed field call takes, decided by what the
// type inference resolved the access to and by nothing else. Gleam's rule —
// the module wherever the receiver's type grants no accessor for the label,
// the field wherever it does — is the compiler's own, and the resolution is
// that rule already applied.
//
// Identity is part of the boundary. A module call is this site's only where the
// module resolved is the one the receiver's name shadows *and* the function is
// the accessed label; a field call only where the label resolved is the
// accessed one. Anything else — a span that landed on a neighbouring reference,
// an alias whose canonical path is not the import string, a regression in the
// inference — reads as neither, naming what was resolved, rather than as a
// lookup under a name the site never wrote.
//
// Every other absence is the third state too: a definition left out of the
// build for the other target, a function the inference declined, a span it
// recorded nothing at, a resolution that is not a call target, and a field on a
// receiver with no nominal type. Each charges `[Unknown]` and keeps its reason.
fn shadowed_module_read(
  call: types.FieldCall,
  function: Function,
  reading: typeinfo.ModuleReading,
) -> ShadowedReading {
  case call.shadowed_module {
    None -> ReadsTheField
    Some(shadowed) -> {
      let resolved =
        classify_typed(call.access_span, function, reading.evidence)
      case resolved {
        ProvedModuleCall(module:, name:)
          if module == shadowed && name == call.label
        -> ReadsTheModule(QualifiedName(module:, function: name))
        ProvedFieldCall(label:, ..) if label == call.label -> ReadsTheField
        // Proved, but not the name the site writes. Rendered here rather than
        // through a helper the `Undecided` arm below would owe an answer for.
        ProvedModuleCall(module:, name:) ->
          ReadsNeither(
            shadowed,
            ResolutionMismatch(
              types.dotted_name(QualifiedName(module:, function: name)),
            ),
          )
        ProvedFieldCall(receiver: #(module, type_name), label:) ->
          ReadsNeither(
            shadowed,
            ResolutionMismatch(
              types.dotted_name(QualifiedName(module:, function: type_name))
              <> "."
              <> label,
            ),
          )
        Undecided(reason:) -> ReadsNeither(shadowed, reason)
      }
    }
  }
}

// The type annotation written on the parameter named `object`, if it carries
// one. The nominal type rule 3 keys by is read from here — the shadowed-receiver
// split no longer consults an annotation at all — so how a receiver name is
// matched against a parameter is stated once.
fn parameter_annotation(
  function: Function,
  object: String,
) -> option.Option(glance.Type) {
  case
    list.find(function.parameters, fn(param) {
      case param.name {
        glance.Named(name) -> name == object
        glance.Discarded(_) -> False
      }
    })
  {
    Ok(glance.FunctionParameter(type_:, ..)) -> type_
    Error(Nil) -> None
  }
}

// The nominal type name declared on the function parameter named `object`, if
// it carries a `NamedType` annotation. The syntax-level fallback for receivers
// girard could not type.
fn syntactic_param_type(
  function: Function,
  object: String,
  context: ImportContext,
) -> option.Option(#(String, String)) {
  case parameter_annotation(function, object) {
    Some(glance.NamedType(name: type_name, module:, ..)) ->
      annotated_type_module(type_name, module, context)
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
