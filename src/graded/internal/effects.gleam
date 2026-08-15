import filepath
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/set
import gleam/string
import graded/internal/annotation
import graded/internal/config
import graded/internal/effect_term
import graded/internal/types.{
  type ArgumentValue, type EffectAnnotation, type EffectSet, type EffectTerm,
  type ExternalAnnotation, type FactorySignature, type LookupOrigin,
  type ParamBound, type QualifiedName, type ReturnProvenance,
  type TypeFieldAnnotation, type TypeFieldEffect, type UpdateSignature, Catalog,
  Check, CommittedSpec, ConstructorRef, DependencySpec, Effects,
  FunctionExternal, FunctionRef, ModuleExternal, ModuleExternalOrigin,
  PathDependency, ProjectInferred, QualifiedName, TypeFieldEffect, TypeLine,
  UserExternal,
}
import simplifile
import tom

// Knowledge base
//
// The KnowledgeBase record bundling every effect source (dependencies,
// catalog, externals, inferred data), with the lookup and merge operations
// the checker and inference passes use against it.

pub type EffectLookup {
  Known(term: EffectTerm, source: types.EffectSource)
  Unknown
}

// Bundles all effect knowledge: dependency + catalog, precomputed for fast lookup.
pub type KnowledgeBase {
  KnowledgeBase(
    // Each function's effect term paired with the source that wrote it. The two
    // are one value, so every insert, merge and lookup carries both: the merge
    // that picks a term picks its origin with it.
    all_effects: Dict(QualifiedName, #(EffectTerm, LookupOrigin)),
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
    // in scope) and threaded forward by the topological pass. Each summary is
    // tagged with its origin (Fix E): a **Foreign** summary loaded from a
    // serialized `.graded` isn't sanitized by this run's
    // `compute_returned_operator`, so a polymorphic one is not trusted for
    // synthesis — it resolves to `[Unknown]`; a **Fresh** one produced this run,
    // and any ground summary, is safe.
    returned_operators: Dict(QualifiedName, ReturnedOperator),
    // Package-wide factory signatures, keyed by `#(defining module, function)`:
    // each constructor field a function wires to one of its parameters, mapped
    // to that parameter's position. Lets a let-bound *cross-module* factory call
    // bind its result's fields like a direct construction. (Same-module
    // factories are derived locally from the module, like constructors.)
    factories: Dict(#(String, String), FactorySignature),
    // Package-wide update-builder signatures, keyed by `#(defining module,
    // function)`. Lets a cross-module builder call (`options.with_resolver(base,
    // http)`) compose an overlay of its base. Same-module builders are derived
    // locally, like factories.
    updates: Dict(#(String, String), UpdateSignature),
    // Module-level externals: a whole module's declared effect paired with the
    // source that declared it, keyed by module name. Consulted by `lookup` when
    // `all_effects` has no entry for a name, so every function in the module
    // resolves to this set. An empty set is a pure module.
    module_effects: Dict(String, #(EffectTerm, LookupOrigin)),
    // Return-value provenance of public functions, keyed by `QualifiedName`. Lets
    // a downstream module's computed receiver (`inner(other.get_options(config))`)
    // resolve `get_options`'s return path and forward its field effects. Computed
    // at the function's inference time and threaded forward by the topological
    // pass. (Same-module private helpers resolve on demand from the AST instead.)
    provenance: Dict(QualifiedName, ReturnProvenance),
    // The functions whose implementation is foreign code — the `@external`
    // declarations of the source under analysis. An entry here says nothing
    // about a name's effects; it says
    // that only a *declaration* speaks for them, since every other entry the
    // base holds for one describes a body the foreign implementation needn't
    // match. Weighed by `lookup_declared`, so one name reads the same to
    // `check`, `why`, `effect` and every caller.
    foreign_functions: Dict(QualifiedName, types.ForeignFunction),
    // The same fact about the *dependencies'* `@external` declarations, scanned
    // from their sources under `build/packages` and at each path dependency's
    // own location. Held apart from `foreign_functions` because the two answer
    // different questions: a project name's entry decides which of *this*
    // package's entries may speak for it, while a dependency name's decides that
    // no value channel may speak for it at all, and that a running fallback
    // widens whatever declaration does.
    dependency_foreign: Dict(QualifiedName, types.ForeignFunction),
    // Every function of every project module graded parsed, keyed by module and
    // then by function, with whether the package exports it. Consulted by
    // `graded effect`, which answers for the public API alone and so has to tell
    // a private name from one this package never defined — two cases a
    // hand-written spec line states identically.
    //
    // Nested rather than keyed by `QualifiedName` because the absences differ: a
    // function missing from a module that *is* here is a name the package does
    // not define, while a module missing entirely is no evidence at all.
    project_functions: Dict(String, Dict(String, types.Visibility)),
  )
}

// Build a knowledge base by scanning dependency .graded files under
// `packages_directory` and loading versioned catalog files from priv/catalog/,
// selecting versions from the manifest at `manifest_path`.
//
// `dependency_foreign` is what the dependencies' own sources say is `@external`,
// scanned before this call. Each dep spec is sanitized against it *as it loads*,
// which is the only place the sanitizing can happen: the merges below let a dep
// entry bury the catalog entry for the same name, so refusing a stale dep line
// at lookup time would answer `[Unknown]` where a valid catalog declaration was
// waiting underneath it.
pub fn load_knowledge_base(
  packages_directory: String,
  manifest_path: String,
  dependency_foreign: Dict(QualifiedName, types.ForeignFunction),
) -> KnowledgeBase {
  let deps = load_dependencies(packages_directory, dependency_foreign)
  let catalog_dir = find_catalog_directory()
  let #(cat_effects, cat_module_effects, cat_params, cat_type_fields) =
    load_catalog(catalog_dir, manifest_path)
  KnowledgeBase(
    // Dependency entries win on a clash: dict.merge keeps its second argument.
    all_effects: dict.merge(cat_effects, deps.effects),
    param_bounds: dict.merge(cat_params, deps.params),
    type_fields: dict.new(),
    // Every dependency summary is Foreign (loaded from a serialized dep spec),
    // tagged by `load_dependencies` with the package whose spec held it.
    returned_operators: deps.returns,
    factories: dict.new(),
    // Update builders are derived from dependency source at run time, not loaded
    // from specs (a serialized signature could skew from the source a consumer
    // compiled against); this starts empty.
    updates: dict.new(),
    // A dependency's module-level external wins over a catalog one for the same
    // module, matching `all_effects`.
    module_effects: dict.merge(cat_module_effects, deps.module_effects),
    provenance: dict.new(),
    // Scanned from the source under analysis, which no dependency spec carries.
    foreign_functions: dict.new(),
    dependency_foreign:,
    project_functions: dict.new(),
  )
  // Catalog `type` fields first, then dependency ones (appended last, so they
  // win on a clash) — matching the effect priority (dependency spec > catalog).
  |> with_sourced_type_fields(list.append(cat_type_fields, deps.type_fields))
}

// A knowledge base holding nothing at all — no dependencies, no catalog. The
// base for a caller that wants only what it folds in itself, such as the
// spec-only lookup `run_effect` answers from before building a project context.
pub fn new_knowledge_base() -> KnowledgeBase {
  KnowledgeBase(
    all_effects: dict.new(),
    param_bounds: dict.new(),
    type_fields: dict.new(),
    returned_operators: dict.new(),
    factories: dict.new(),
    updates: dict.new(),
    module_effects: dict.new(),
    provenance: dict.new(),
    foreign_functions: dict.new(),
    dependency_foreign: dict.new(),
    project_functions: dict.new(),
  )
}

// Build a knowledge base from the catalog only (no dependency scanning).
pub fn empty_knowledge_base() -> KnowledgeBase {
  let catalog_dir = find_catalog_directory()
  let #(cat_effects, cat_module_effects, cat_params, cat_type_fields) =
    load_catalog(catalog_dir, "manifest.toml")
  KnowledgeBase(
    all_effects: cat_effects,
    param_bounds: cat_params,
    type_fields: dict.new(),
    returned_operators: dict.new(),
    factories: dict.new(),
    updates: dict.new(),
    module_effects: cat_module_effects,
    provenance: dict.new(),
    foreign_functions: dict.new(),
    dependency_foreign: dict.new(),
    project_functions: dict.new(),
  )
  |> with_sourced_type_fields(cat_type_fields)
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

// Merge hand-written type field annotations into a knowledge base, all read
// from `origin`'s file. These carry no polymorphic bounds (a hand-written `type
// Foo.field : [...]` is a concrete budget), so they store empty bounds and no
// source. A spec-qualified annotation (`type myapp.Foo.field`) keys by its
// module; a bare one by "".
pub fn with_type_fields(
  knowledge_base: KnowledgeBase,
  type_fields: List(TypeFieldAnnotation),
  origin: LookupOrigin,
) -> KnowledgeBase {
  with_sourced_type_fields(
    knowledge_base,
    list.map(type_fields, fn(type_field) { #(type_field, origin) }),
  )
}

// The same merge for annotations gathered from several files, each paired with
// the file it was read from. A later entry wins on a clash.
fn with_sourced_type_fields(
  knowledge_base: KnowledgeBase,
  type_fields: List(#(TypeFieldAnnotation, LookupOrigin)),
) -> KnowledgeBase {
  let merged =
    list.fold(type_fields, knowledge_base.type_fields, fn(accumulator, entry) {
      let #(type_field, origin) = entry
      let module = case type_field.module {
        Some(module) -> module
        None -> ""
      }
      dict.insert(
        accumulator,
        #(module, type_field.type_name, type_field.field),
        TypeFieldEffect(
          type_field.effects,
          [],
          None,
          types.Declared(source: origin),
        ),
      )
    })
  KnowledgeBase(..knowledge_base, type_fields: merged)
}

// Merge external annotations into a knowledge base.
// Module-level externals record the whole module's declared effect.
// Function-level externals are added to all_effects.
//
// `origin` is the source of these declarations: this project's spec passes
// `UserExternal`, the bundled catalog passes `Catalog(package)`. A
// function-level insert records it beside the effect; a module-level one
// records it wrapped in `ModuleExternalOrigin`, which names both the kind of
// line and the file it sits in.
pub fn with_externals(
  knowledge_base: KnowledgeBase,
  externals: List(ExternalAnnotation),
  origin: LookupOrigin,
) -> KnowledgeBase {
  let #(function_externals, module_externals) =
    split_externals(externals, origin)
  KnowledgeBase(
    ..knowledge_base,
    all_effects: dict.merge(knowledge_base.all_effects, function_externals),
    module_effects: dict.merge(knowledge_base.module_effects, module_externals),
  )
}

// The two tiers a set of `external effects` lines feeds: function-level entries
// keyed by `QualifiedName`, module-level ones keyed by module name.
type ExternalTiers =
  #(
    Dict(QualifiedName, #(EffectTerm, LookupOrigin)),
    Dict(String, #(EffectTerm, LookupOrigin)),
  )

// Sort external annotations into the two maps they feed, each term paired with
// the source that declared it. Splitting is separate from merging so each
// caller decides its own precedence.
fn split_externals(
  externals: List(ExternalAnnotation),
  origin: LookupOrigin,
) -> ExternalTiers {
  list.fold(externals, #(dict.new(), dict.new()), fn(accumulator, external) {
    let #(function_externals, module_externals) = accumulator
    let term = effect_term.from_effect_set(external.effects)
    case external.target {
      ModuleExternal -> #(
        function_externals,
        dict.insert(module_externals, external.module, #(
          term,
          ModuleExternalOrigin(source: origin),
        )),
      )
      FunctionExternal(function) -> #(
        dict.insert(
          function_externals,
          QualifiedName(external.module, function),
          #(term, origin),
        ),
        module_externals,
      )
    }
  })
}

// Look up the effect set for a qualified function name, with the source that
// wrote the entry that answered.
pub fn lookup(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> EffectLookup {
  let found = case dict.get(knowledge_base.all_effects, name) {
    Ok(#(effect_set, origin)) -> Known(effect_set, types.FunctionEntry(origin:))
    Error(Nil) ->
      case dict.get(knowledge_base.module_effects, name.module) {
        Ok(#(effect_set, origin)) ->
          Known(effect_set, types.ModuleExternalEntry(origin:))
        Error(Nil) -> Unknown
      }
  }
  with_dependency_fallback(knowledge_base, name, found)
}

// Widen a dependency external's answer by the fallback body nobody walks.
//
// Where the source is walked — this package — a declaration is unioned with a
// running fallback body's own effects, because that body is ordinary Gleam that
// runs on the targets the declaration doesn't cover. A consumer never walks a
// dependency's bodies, so the union has no second operand there and the
// declaration alone would read as the whole story: `external effects dep.run :
// []` over an `@external(javascript, …)` whose Erlang fallback prints would be
// believed pure on Erlang. `[Unknown]` is that missing operand — the body ran,
// and what it did is not knowable from here.
fn with_dependency_fallback(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
  found: EffectLookup,
) -> EffectLookup {
  case dict.get(knowledge_base.dependency_foreign, name), found {
    Ok(types.ForeignFunction(runs_fallback_body: True)), Known(term, source) ->
      Known(
        effect_term.normalize(types.TUnion([term, effect_term.unknown()])),
        source,
      )
    Ok(_), _ | Error(Nil), _ -> found
  }
}

// The origin a lookup's source names, for a caller that records provenance
// beside a term rather than rendering it.
pub fn origin_of(source: types.EffectSource) -> LookupOrigin {
  case source {
    types.FunctionEntry(origin:) -> origin
    types.ModuleExternalEntry(origin:) -> origin
  }
}

// Record the functions whose implementation is foreign code: the `@external`
// declarations of the source under analysis. Merged into what is already
// recorded, so a caller scanning a second set of modules adds to it.
pub fn with_foreign_functions(
  knowledge_base: KnowledgeBase,
  names: Dict(QualifiedName, types.ForeignFunction),
) -> KnowledgeBase {
  KnowledgeBase(
    ..knowledge_base,
    foreign_functions: dict.merge(knowledge_base.foreign_functions, names),
  )
}

// Whether `name`'s implementation is foreign code, so that only a declaration
// speaks for its effects. False for a name from source nobody scanned: the base
// reports what it was told, and a caller that wants the rule applied to an
// `@external` it holds the definition of applies it from that definition.
pub fn is_foreign_function(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Bool {
  dict.has_key(knowledge_base.foreign_functions, name)
}

// What this package's own source says about a name: that it defines it with
// this visibility, that the module it names defines no such function, or that
// there is no evidence either way — the module is not this package's, or was
// never parsed.
//
// The third case is why the first two can be trusted. A miss is only a fact
// about the package where the module was read; anywhere else it is silence, and
// silence must not decide anything.
pub type ProjectVisibility {
  ProjectFunction(visibility: types.Visibility)
  NotProjectFunction
  NoProjectEvidence
}

// Record what this package's parsed modules define, keyed by module. Merged into
// what is already recorded, so a caller that parses a second module adds to it.
pub fn with_project_functions(
  knowledge_base: KnowledgeBase,
  modules: Dict(String, Dict(String, types.Visibility)),
) -> KnowledgeBase {
  KnowledgeBase(
    ..knowledge_base,
    project_functions: dict.merge(knowledge_base.project_functions, modules),
  )
}

// This package's own source's answer for `name` — see `ProjectVisibility`.
pub fn project_visibility(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> ProjectVisibility {
  case dict.get(knowledge_base.project_functions, name.module) {
    Error(Nil) -> NoProjectEvidence
    Ok(functions) ->
      case dict.get(functions, name.function) {
        Ok(visibility) -> ProjectFunction(visibility:)
        Error(Nil) -> NotProjectFunction
      }
  }
}

// Whether `name` is foreign code on any *value* channel: an `@external` graded
// has seen the source of, this package's or a dependency's.
//
// The effects channel can afford a narrower rule, because it unions a
// declaration with a fallback body that runs. The value channels have no such
// counterpart — nothing declares the operator an FFI factory returns, or the
// provenance of the record it builds — so every `@external` is opaque to them,
// declared or not, fallback or not.
pub fn is_value_opaque(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Bool {
  dict.has_key(knowledge_base.foreign_functions, name)
  || dict.has_key(knowledge_base.dependency_foreign, name)
}

// Whether an origin speaks for code graded cannot see. An `external effects`
// line, a module-level external and a catalog entry all declare what foreign
// code does; an `effects` line does not — for an `@external` it is inference
// over a body the foreign implementation needn't match, so trusting one would
// pass a budget nothing backs (a function that becomes `@external` leaves
// exactly such a line behind until the spec is regenerated).
//
// Told from the winning entry rather than from its effects: a declaration of
// `[Unknown]` is still a declaration and still names its source, and an
// inferred `[]` is not one however concrete it reads.
pub fn declares_foreign_code(origin: LookupOrigin) -> Bool {
  case origin {
    // A dependency's spec speaks for foreign code as the catalog does, though
    // neither keys a function of the project module under analysis today.
    UserExternal
    | Catalog(_)
    | ModuleExternalOrigin(_)
    | DependencySpec(_)
    | PathDependency(_) -> True
    CommittedSpec | ProjectInferred | TypeLine(_) -> False
  }
}

// The base's answer for `name`, holding foreign code to what declares it: for
// an `@external`, only a declaring entry answers, and anything else the base
// holds describes a body the foreign implementation needn't match, so it leaves
// the effects unresolved however concrete it looks.
//
// The one boundary through which a name is charged its effects. A call, a
// function value passed to a higher-order callee, a function wired into a
// record field and a `check` line all come through here, so no two of them can
// charge one name differently — a raw `lookup` that skipped the rule is exactly
// how a stale `effects` line for an `@external` used to be believed.
pub fn lookup_declared(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> EffectLookup {
  let found = lookup(knowledge_base, name)
  use <- bool.guard(
    when: !is_foreign_function(knowledge_base, name),
    return: found,
  )
  case found {
    Known(_, source) as known ->
      case declares_foreign_code(origin_of(source)) {
        True -> known
        False -> Unknown
      }
    Unknown -> Unknown
  }
}

// The same as an `EffectTerm`, `[Unknown]` where nothing answers for the name.
// The term may be second-order (carry operator applications) for higher-order
// functions; callers reduce it at the resolution boundary.
pub fn declared_effects(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> EffectTerm {
  case lookup_declared(knowledge_base, name) {
    Known(effect_term, _) -> effect_term
    Unknown -> effect_term.unknown()
  }
}

// The effect of a value wired into a constructor field. A function
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
    FunctionRef(name:) -> declared_effects(knowledge_base, name)
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

// Name the source that answered a lookup, as a noun phrase. Every surface that
// states provenance — the violation suffix `(from ...)`, the `graded effect`
// prose `source:` line, and its `.graded` `// resolved from ...` comment —
// reads from this one vocabulary.
pub fn describe_origin(origin: LookupOrigin) -> String {
  case origin {
    UserExternal -> "your spec's external declaration"
    ModuleExternalOrigin(source:) ->
      "a module-level external in " <> describe_source_file(source)
    TypeLine(source:) -> "a type line in " <> describe_source_file(source)
    CommittedSpec
    | ProjectInferred
    | DependencySpec(..)
    | PathDependency(..)
    | Catalog(..) -> describe_source_file(origin)
  }
}

// The file a declaration was read from, as the noun phrase that follows "in".
// Shared with the surfaces that name a *kind* of line and the file it sits in.
pub fn describe_source_file(origin: LookupOrigin) -> String {
  case origin {
    UserExternal | CommittedSpec -> "your spec"
    ProjectInferred -> "in-memory inference"
    DependencySpec(package:) -> package <> "'s shipped spec"
    PathDependency(package:) -> "path dependency " <> package
    Catalog(package:) -> package <> "'s catalog entry"
    ModuleExternalOrigin(source:) | TypeLine(source:) ->
      describe_source_file(source)
  }
}

// Merge inferred effects into a knowledge base, tagged with the source they
// came from. Existing entries in the knowledge base take priority, keeping
// their own origin with their own term.
pub fn with_inferred(
  knowledge_base: KnowledgeBase,
  inferred: Dict(QualifiedName, EffectTerm),
  origin: LookupOrigin,
) -> KnowledgeBase {
  KnowledgeBase(
    ..knowledge_base,
    all_effects: dict.merge(
      with_origin(inferred, origin),
      knowledge_base.all_effects,
    ),
  )
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

// The origin of a returned-operator summary (Fix E). Named `SummaryOrigin`, not
// `Provenance`, to avoid confusion with `types.ReturnProvenance` (return-value
// field provenance, an unrelated concept).
pub type SummaryOrigin {
  // Produced by this run's `compute_returned_operator` — Fix-D-sanitized, so its
  // free vars ⊆ the producer's fn-typed params; safe to synthesize/bind.
  Fresh
  // Loaded from a serialized `.graded` (dependency or committed project spec),
  // unsanitized; a polymorphic Foreign summary is not trusted for synthesis.
  Foreign
}

// A function's returned-operator summary as the knowledge base holds it: the
// operator, whether this run produced it, and the source that wrote it. The
// three are one value, so a lookup can report the summary it used and where it
// came from together.
pub type ReturnedOperator {
  ReturnedOperator(
    operator: EffectTerm,
    summary: SummaryOrigin,
    source: LookupOrigin,
  )
}

// Pair every term of a bare effect map with the source that wrote it, giving
// the shape `all_effects` holds.
fn with_origin(
  entries: Dict(QualifiedName, EffectTerm),
  origin: LookupOrigin,
) -> Dict(QualifiedName, #(EffectTerm, LookupOrigin)) {
  dict.map_values(entries, fn(_name, term) { #(term, origin) })
}

// Pair every summary in a bare `name -> operator` map with how it was produced
// and the source that wrote it, giving the shape `returned_operators` holds.
fn tag_returns(
  returns: Dict(QualifiedName, EffectTerm),
  summary: SummaryOrigin,
  source: LookupOrigin,
) -> Dict(QualifiedName, ReturnedOperator) {
  dict.map_values(returns, fn(_, operator) {
    ReturnedOperator(operator:, summary:, source:)
  })
}

// Merge **Foreign** returned-operator summaries (from a serialized `.graded`)
// into a knowledge base — existing entries take priority (gap-fill). Used for
// dependency and committed-project returns.
pub fn with_foreign_returned_operators(
  knowledge_base: KnowledgeBase,
  inferred: Dict(QualifiedName, EffectTerm),
  source: LookupOrigin,
) -> KnowledgeBase {
  let merged =
    dict.merge(
      tag_returns(inferred, Foreign, source),
      knowledge_base.returned_operators,
    )
  KnowledgeBase(..knowledge_base, returned_operators: merged)
}

// Merge **Fresh** returned-operator summaries (produced by this run's inference)
// into a knowledge base — new entries take priority, so a re-inferred summary
// replaces a committed Foreign one for the same key. Used for the pre-pass /
// main-loop fresh deltas.
pub fn with_fresh_returned_operators(
  knowledge_base: KnowledgeBase,
  inferred: Dict(QualifiedName, EffectTerm),
  source: LookupOrigin,
) -> KnowledgeBase {
  let merged =
    dict.merge(
      knowledge_base.returned_operators,
      tag_returns(inferred, Fresh, source),
    )
  KnowledgeBase(..knowledge_base, returned_operators: merged)
}

// Attach the package-wide factory map (keyed by `#(module, function)`), so a
// let-bound cross-module factory call binds its result's fields. Replaces any
// existing map (it's computed once per run).
pub fn with_factories(
  knowledge_base: KnowledgeBase,
  factories: Dict(#(String, String), FactorySignature),
) -> KnowledgeBase {
  KnowledgeBase(..knowledge_base, factories:)
}

// The package-wide factory map, for threading into a module's extraction
// context as its cross-module factories.
pub fn factories(
  knowledge_base: KnowledgeBase,
) -> Dict(#(String, String), FactorySignature) {
  knowledge_base.factories
}

// Merge an update-builder map (keyed by `#(module, function)`) into the
// knowledge base. Every map here is derived from source at run time — the
// knowledge base starts with none, and the callers merge installed-dependency
// source, then path-dependency source, then the current package's own builders.
// A later merge wins on a clash, so the current package takes precedence.
pub fn with_updates(
  knowledge_base: KnowledgeBase,
  updates: Dict(#(String, String), UpdateSignature),
) -> KnowledgeBase {
  KnowledgeBase(
    ..knowledge_base,
    updates: dict.merge(knowledge_base.updates, updates),
  )
}

// The package-wide update-builder map, for threading into a module's extraction
// context as its cross-module update builders.
pub fn updates(
  knowledge_base: KnowledgeBase,
) -> Dict(#(String, String), UpdateSignature) {
  knowledge_base.updates
}

// Look up the operator a function returns, if known, with how it was produced
// (Fix E) and the source that wrote it. `Error(Nil)` when the callee doesn't
// return a (tracked) operator.
pub fn lookup_returned_operator(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Result(ReturnedOperator, Nil) {
  use <- bool.guard(
    when: is_value_opaque(knowledge_base, name),
    return: Error(Nil),
  )
  dict.get(knowledge_base.returned_operators, name)
}

// Merge inferred return-value provenance into a knowledge base, so a downstream
// module's computed receiver (`inner(other.get_options(config))`) can resolve the
// callee's return path. Existing entries take priority.
pub fn with_provenance(
  knowledge_base: KnowledgeBase,
  inferred: Dict(QualifiedName, ReturnProvenance),
) -> KnowledgeBase {
  let merged = dict.merge(inferred, knowledge_base.provenance)
  KnowledgeBase(..knowledge_base, provenance: merged)
}

// Look up a function's return-value provenance, if known. `Error(Nil)` when the
// callee's provenance wasn't tracked (a private helper resolves on demand).
pub fn lookup_provenance(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Result(ReturnProvenance, Nil) {
  use <- bool.guard(
    when: is_value_opaque(knowledge_base, name),
    return: Error(Nil),
  )
  dict.get(knowledge_base.provenance, name)
}

// Dependency sources
//
// Locating dependency source code on disk: module-path -> file maps for
// installed packages and path dependencies declared in gleam.toml.

// Map of module path -> source file for every `.gleam` under each installed
// dependency's `src/` directory. Derived from file paths (no parsing), so it's
// cheap and covers type-only modules. Used both to confirm that a qualified
// spec annotation names a real dependency (rather than a typo) and to parse a
// dependency module on demand when resolving a field's declared type.
pub fn dependency_module_files(
  packages_directory: String,
) -> Dict(String, String) {
  case simplifile.read_directory(packages_directory) {
    Error(_) -> dict.new()
    Ok(packages) ->
      list.fold(packages, dict.new(), fn(acc, package_name) {
        let src_dir = packages_directory <> "/" <> package_name <> "/src"
        dict.merge(acc, source_dir_module_files(src_dir))
      })
  }
}

// Map of module path -> source file for every `.gleam` under `source_dir` (a
// single package's `src/`), keyed the same way the rest of the tool keys
// modules.
pub fn source_dir_module_files(source_dir: String) -> Dict(String, String) {
  case simplifile.get_files(source_dir) {
    Error(_) -> dict.new()
    Ok(files) ->
      files
      |> list.filter(string.ends_with(_, ".gleam"))
      |> list.fold(dict.new(), fn(acc, file) {
        dict.insert(acc, config.module_path_for_source(file, source_dir), file)
      })
  }
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

// Spec files
//
// Reading .graded spec files into effect, param-bound, returned-operator, and
// type-field maps, for the project spec and for installed dependencies.

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

// Load a package's own committed parameter bounds from its parsed spec file,
// keyed the same way `load_spec_effects_from_file` keys effects so a
// higher-order line's bounds travel with the line's own effect term.
//
// Whichever annotation supplies a function's effect term must also supply its
// bounds, so this records an entry — an *empty* one where the line carries no
// bounds — for every function whose term this file decides. An empty entry is
// what pins the pair together: `with_inferred_params` keeps existing entries, so
// it stops a later inference pass from gap-filling bounds whose variables answer
// to a term this file never wrote.
//
// - `check` lines are skipped: their bounds are a budget scoped to that check,
//   not a global fact about the function, and they don't decide the term.
// - functions declared `external effects <module>.<function>` record an empty
//   entry: the external term wins in `all_effects` and is ground by
//   construction, so any bounds pairing with it come from another source.
//
// `stale_externals` names the per-function external lines that declare nothing —
// those naming one of this package's own ordinary functions. Their `effects`
// line decides the term, so it decides the bounds too, and they take no empty
// entry here.
pub fn load_spec_params_from_file(
  file: types.GradedFile,
  stale_externals: set.Set(String),
) -> Dict(QualifiedName, List(ParamBound)) {
  let external_functions =
    set.difference(annotation.external_function_names(file), stale_externals)
  let from_externals =
    set.fold(external_functions, dict.new(), fn(acc, name) {
      case annotation.split_function_name(name) {
        Ok(#(module, function)) ->
          dict.insert(acc, QualifiedName(module:, function:), [])
        Error(_) -> acc
      }
    })
  list.fold(annotation.extract_annotations(file), from_externals, fn(acc, ann) {
    use <- bool.guard(when: ann.kind == Check, return: acc)
    use <- bool.guard(
      when: set.contains(external_functions, ann.function),
      return: acc,
    )
    case annotation.split_function_name(ann.function) {
      Ok(#(module, function)) ->
        dict.insert(acc, QualifiedName(module:, function:), ann.params)
      Error(_) -> acc
    }
  })
}

// Everything one dependency's spec file declares. The three `QualifiedName`-keyed
// maps hold the terms, bounds and returned-operator summaries; `type_fields` and
// `externals` stay lists, since where each lands in the knowledge base is the
// merging caller's decision (`with_type_fields`'s insert order against the
// project spec; `split_externals`'s two tiers).
pub type DepSpec {
  DepSpec(
    effects: Dict(QualifiedName, EffectTerm),
    params: Dict(QualifiedName, List(ParamBound)),
    returns: Dict(QualifiedName, EffectTerm),
    type_fields: List(TypeFieldAnnotation),
    externals: List(ExternalAnnotation),
  )
}

// Load one package's spec. Reads the spec via the package's own `[tools.graded]`
// config (defaulting to `<package_name>.graded`) at `dep_root`, once. Empty when
// the spec is missing or unparseable. Shared by the `build/packages` dependency
// scan and path-dependency enrichment so both dep kinds load identical metadata —
// effects alone would drop the bounds a higher-order callee needs to discharge
// its callback's effect, the `type` fields a capability record on the dep's own
// types needs to resolve at a consumer's call site, or the `external effects`
// lines the dep author wrote for its FFI.
pub fn load_dep_spec(dep_root: String, package_name: String) -> DepSpec {
  case read_spec_file(config.spec_file_for(dep_root, package_name)) {
    Error(_) -> DepSpec(dict.new(), dict.new(), dict.new(), [], [])
    Ok(file) ->
      // Loaded through the same two readers a package uses for its *own* spec,
      // so a dependency's `check` budgets and externally-declared functions are
      // scoped identically one package boundary away: a `check` line's bounds
      // stay local to that check instead of becoming a global fact about the
      // dependency's function, and every term still travels with the bounds
      // from its own annotation.
      DepSpec(
        effects: load_spec_effects_from_file(file),
        // A dependency's per-function external is never stale by this rule: its
        // own body is the documented case for the line.
        params: load_spec_params_from_file(file, set.new()),
        returns: load_spec_returns_from_file(file),
        type_fields: annotation.extract_type_fields(file),
        externals: annotation.extract_externals(file),
      )
  }
}

// A dependency spec minus the entries no dependency spec may state about its
// own foreign code.
//
// A dep function the dep's *own source* declares `@external` is foreign code:
// an `effects` line for it is inference over a fallback body the foreign
// implementation needn't match — exactly what this package's own spec is barred
// from believing about its own `@external` — and a `returns` line for it
// describes a value only that implementation produces, so it is dropped whether
// or not a declaration also covers the name. What survives for a declared name
// is the declaration: the dep's own `external effects` line, a module-level
// external, or the catalog entry underneath.
//
// A term and its bounds are dropped together. `load_knowledge_base` merges terms
// and bounds in two independent passes, so a term dropped without its bounds
// would revive the catalog's term paired with the dependency's bounds — the
// pairing `load_spec_params_from_file` documents, broken.
fn sanitize_dep_spec(
  dep: DepSpec,
  foreign: Dict(QualifiedName, types.ForeignFunction),
) -> DepSpec {
  let declared =
    list.fold(dep.externals, set.new(), fn(acc, external) {
      case external.target {
        FunctionExternal(function) ->
          set.insert(acc, QualifiedName(external.module, function))
        ModuleExternal -> acc
      }
    })
  let inferred_over_foreign = fn(name) {
    dict.has_key(foreign, name) && !set.contains(declared, name)
  }
  DepSpec(
    ..dep,
    effects: dict.filter(dep.effects, fn(name, _term) {
      !inferred_over_foreign(name)
    }),
    params: dict.filter(dep.params, fn(name, _bounds) {
      !inferred_over_foreign(name)
    }),
    returns: dict.filter(dep.returns, fn(name, _operator) {
      !dict.has_key(foreign, name)
    }),
  )
}

// The entries one dependency spec decides, each tagged with the source that
// shipped it: the function-keyed terms for `all_effects` and the module-keyed
// ones for the `module_effects` fallback tier.
//
// A function's `external effects` line wins over an `effects` line for the same
// name. `graded infer` writes no `effects` line for an externally-declared
// function, so a spec carrying both has a stale one, and only the external's
// ground term pairs with the empty bounds `load_spec_params_from_file` records
// for it.
fn decided_entries(dep: DepSpec, origin: LookupOrigin) -> ExternalTiers {
  let #(function_externals, module_externals) =
    split_externals(dep.externals, origin)
  #(
    dict.merge(with_origin(dep.effects, origin), function_externals),
    module_externals,
  )
}

// Fold everything a path dependency's spec declares — terms, bounds, externals,
// returned-operator summaries and `type` lines — into the knowledge base under
// the documented resolution order: below per-function user externals and the
// project's own entries, above the catalog. An existing entry is overridden only
// when its origin is the catalog, so a consumer's own declarations survive a
// merge that runs after the catalog is already loaded, and a term this merge
// decides brings its own bounds entry with it. The summaries merge as `Foreign`:
// a committed spec is serialized, not inferred this run.
//
// A consumer's *module-level* external stays in the `module_effects` fallback
// tier, which `lookup` consults only after `all_effects` misses, so these
// function-keyed entries outrank it — the per-function-beats-module-level rule.
pub fn with_path_dep_spec(
  knowledge_base: KnowledgeBase,
  dep: DepSpec,
  origin: LookupOrigin,
) -> KnowledgeBase {
  // Sanitized against the path dependency's own source, scanned into
  // `dependency_foreign` before this fold — a committed spec is as capable of
  // carrying a stale line for its own `@external` as an installed one is.
  let dep = sanitize_dep_spec(dep, knowledge_base.dependency_foreign)
  let #(decided, module_externals) = decided_entries(dep, origin)
  let winning = over_catalog(knowledge_base.all_effects, decided)
  KnowledgeBase(
    ..knowledge_base,
    all_effects: dict.merge(knowledge_base.all_effects, winning),
    param_bounds: dict.merge(
      knowledge_base.param_bounds,
      dict.map_values(winning, fn(name, _entry) {
        dict.get(dep.params, name) |> result.unwrap([])
      }),
    ),
    module_effects: dict.merge(
      knowledge_base.module_effects,
      over_catalog(knowledge_base.module_effects, module_externals),
    ),
  )
  |> with_foreign_returned_operators(dep.returns, origin)
  |> with_type_fields(dep.type_fields, origin)
}

// The incoming entries a path dependency's spec may write over a knowledge-base
// tier: those whose key nothing holds, and those whose key the catalog holds.
fn over_catalog(
  existing: Dict(k, #(EffectTerm, LookupOrigin)),
  incoming: Dict(k, #(EffectTerm, LookupOrigin)),
) -> Dict(k, #(EffectTerm, LookupOrigin)) {
  dict.filter(incoming, fn(key, _entry) {
    case dict.get(existing, key) {
      Error(Nil) -> True
      Ok(#(_term, origin)) -> is_catalog_origin(origin)
    }
  })
}

// Whether an entry was written by the bundled catalog, directly or as the source
// of a module-level external.
fn is_catalog_origin(origin: LookupOrigin) -> Bool {
  case origin {
    Catalog(..) -> True
    ModuleExternalOrigin(source:) | TypeLine(source:) ->
      is_catalog_origin(source)
    UserExternal
    | CommittedSpec
    | ProjectInferred
    | DependencySpec(..)
    | PathDependency(..) -> False
  }
}

fn fold_spec_effects(
  annotations: List(EffectAnnotation),
) -> Dict(QualifiedName, EffectTerm) {
  list.fold(annotations, dict.new(), fn(acc, ann) {
    case ann.kind {
      Effects ->
        case annotation.split_function_name(ann.function) {
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
    case annotation.split_function_name(returns.function) {
      Ok(#(module, function)) ->
        dict.insert(acc, QualifiedName(module:, function:), returns.operator)
      Error(_) -> acc
    }
  })
}

// The installed dependencies' specs, gathered into the shapes the knowledge
// base holds: every term already tagged with the package whose spec declared it.
type Dependencies {
  Dependencies(
    effects: Dict(QualifiedName, #(EffectTerm, LookupOrigin)),
    params: Dict(QualifiedName, List(ParamBound)),
    returns: Dict(QualifiedName, ReturnedOperator),
    type_fields: List(#(TypeFieldAnnotation, LookupOrigin)),
    module_effects: Dict(String, #(EffectTerm, LookupOrigin)),
  )
}

// For each installed package, locate its spec file via the package's own
// `[tools.graded]` config (defaulting to `<package_name>.graded`), then read
// and parse it *once*, folding its qualified `effects`/`check` annotations
// into the global effect/param maps, its `returns` lines into the
// returned-operator map, its `type` field lines into a flat list, and its
// `external effects` lines into the function and module tiers. Packages
// with no spec file are silently skipped — same fail-soft semantics as the
// catalog and the old per-module reader. Across packages the later one in the
// directory fold wins, as effects lines do.
fn load_dependencies(
  packages_directory: String,
  foreign: Dict(QualifiedName, types.ForeignFunction),
) -> Dependencies {
  let entries = case simplifile.read_directory(packages_directory) {
    Ok(found) -> found
    Error(_) -> []
  }
  list.fold(
    entries,
    Dependencies(dict.new(), dict.new(), dict.new(), [], dict.new()),
    fn(acc, package_name) {
      let origin = DependencySpec(package: package_name)
      let dep_root = packages_directory <> "/" <> package_name
      let dep =
        sanitize_dep_spec(load_dep_spec(dep_root, package_name), foreign)
      let #(decided, module_externals) = decided_entries(dep, origin)
      Dependencies(
        effects: dict.merge(acc.effects, decided),
        params: dict.merge(acc.params, dep.params),
        returns: dict.merge(
          acc.returns,
          tag_returns(dep.returns, Foreign, origin),
        ),
        type_fields: list.append(
          acc.type_fields,
          list.map(dep.type_fields, fn(field) { #(field, origin) }),
        ),
        module_effects: dict.merge(acc.module_effects, module_externals),
      )
    },
  )
}

// Catalog
//
// The bundled priv/catalog of versioned .graded files: locating the
// directory, selecting the best version per installed package against the
// manifest, and folding the selected files into effect maps.

// The resolved bundled-catalog directory (see `find_catalog_directory`).
pub fn catalog_directory() -> String {
  find_catalog_directory()
}

// Resolve graded's bundled `priv/catalog`. The install location (via
// `code:priv_dir`) is tried first so the catalog is found regardless of the
// process's working directory; the cwd-relative layouts follow as a fallback.
// When no candidate exists, warn and return the cwd-relative default — an empty
// catalog collapses every catalogued call to `[Unknown]`, so the degradation is
// surfaced instead of silent.
fn find_catalog_directory() -> String {
  let cwd_relative = ["build/packages/graded/priv/catalog", "priv/catalog"]
  // The install-location candidate (anchored on graded's own priv) is tried
  // ahead of the cwd-relative ones; absent when the priv directory can't be
  // located.
  let candidates = case priv_directory() {
    Ok(priv) -> [filepath.join(priv, "catalog"), ..cwd_relative]
    Error(Nil) -> cwd_relative
  }
  case list.find(candidates, is_existing_directory) {
    Ok(directory) -> directory
    Error(Nil) -> {
      io.println_error(
        "graded: warning: catalog directory not found; catalogued calls will resolve to [Unknown]",
      )
      "priv/catalog"
    }
  }
}

fn is_existing_directory(path: String) -> Bool {
  case simplifile.is_directory(path) {
    Ok(True) -> True
    _ -> False
  }
}

@external(erlang, "graded_ffi", "priv_directory")
@external(javascript, "../../graded_ffi.mjs", "priv_directory")
fn priv_directory() -> Result(String, Nil)

type CatalogAcc {
  CatalogAcc(
    ext_effects: Dict(QualifiedName, #(EffectTerm, LookupOrigin)),
    module_effects: Dict(String, #(EffectTerm, LookupOrigin)),
    poly_effects: Dict(QualifiedName, #(EffectTerm, LookupOrigin)),
    poly_params: Dict(QualifiedName, List(ParamBound)),
    type_fields: List(#(TypeFieldAnnotation, LookupOrigin)),
  )
}

// Fold the catalog files selected for `manifest_path`'s installed versions into
// the function effects, module-level externals, parameter bounds and `type`
// field annotations they declare. Exposed so a test can compose a catalog of
// its own; production callers reach it through the knowledge-base builders.
pub fn load_catalog(
  catalog_dir: String,
  manifest_path: String,
) -> #(
  Dict(QualifiedName, #(EffectTerm, LookupOrigin)),
  Dict(String, #(EffectTerm, LookupOrigin)),
  Dict(QualifiedName, List(ParamBound)),
  List(#(TypeFieldAnnotation, LookupOrigin)),
) {
  let installed_versions = parse_manifest_versions(manifest_path)
  let catalog_files = case simplifile.get_files(catalog_dir) {
    Ok(files) ->
      list.filter(files, fn(file) { string.ends_with(file, ".graded") })
    Error(_) -> []
  }
  let selected = resolve_catalog_files(catalog_files, installed_versions)
  let initial = CatalogAcc(dict.new(), dict.new(), dict.new(), dict.new(), [])
  let acc = list.fold(selected, initial, fold_catalog_file)
  // Explicit `effects` annotations in the catalog take precedence over the
  // module-level `external effects` markers. Each term carries the package that
  // wrote it, so the winner of this merge brings its own origin.
  #(
    dict.merge(acc.ext_effects, acc.poly_effects),
    acc.module_effects,
    acc.poly_params,
    acc.type_fields,
  )
}

// Fold one selected catalog file — its package name and path — into the
// accumulator. `external effects` lines feed module-level pure markers and
// specific function effects; `effects` lines with param bounds feed polymorphic
// higher-order entries. Both kinds of function entry are tagged
// `Catalog(package)`. Files that fail to read or parse are silently skipped.
fn fold_catalog_file(acc: CatalogAcc, entry: #(String, String)) -> CatalogAcc {
  let #(package, file_path) = entry
  case simplifile.read(file_path) {
    Error(_) -> acc
    Ok(content) ->
      case annotation.parse_file(content) {
        Error(_) -> acc
        Ok(graded_file) -> {
          let origin = Catalog(package:)
          let #(function_externals, module_externals) =
            split_externals(annotation.extract_externals(graded_file), origin)
          // Same two readers as a package's own spec and as `load_dep_spec`, so
          // a catalog entry's `check` budgets and externally-declared functions
          // are scoped like everyone else's. Merging with the new file second
          // keeps the later file winning on a clash, as folding per-annotation
          // did.
          let file_poly_effects =
            with_origin(load_spec_effects_from_file(graded_file), origin)
          CatalogAcc(
            ext_effects: dict.merge(acc.ext_effects, function_externals),
            module_effects: dict.merge(acc.module_effects, module_externals),
            poly_effects: dict.merge(acc.poly_effects, file_poly_effects),
            poly_params: dict.merge(
              acc.poly_params,
              // A catalog entry describes a package graded has no source for,
              // so none of its externals can be stale by the visible-body rule.
              load_spec_params_from_file(graded_file, set.new()),
            ),
            type_fields: list.append(
              acc.type_fields,
              list.map(annotation.extract_type_fields(graded_file), fn(field) {
                #(field, origin)
              }),
            ),
          )
        }
      }
  }
}

// Each selected file as `#(package, path)`: the package name the catalog's
// `{package}@{version}.graded` file name carries, which the fold records as the
// origin of that file's entries.
fn resolve_catalog_files(
  catalog_files: List(String),
  installed_versions: Dict(String, String),
) -> List(#(String, String)) {
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
          Ok(path) -> [#(package, path), ..selected]
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
