import filepath
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded/internal/annotation
import graded/internal/config
import graded/internal/effect_term
import graded/internal/types.{
  type ArgumentValue, type AssumeAnnotation, type EffectAnnotation,
  type EffectSet, type EffectTerm, type FactorySignature, type FieldAnnotation,
  type LookupOrigin, type ParamBound, type QualifiedName, type ReturnProvenance,
  type TypeFieldEffect, type UpdateSignature, Catalog, Check, CommittedSpec,
  ConstructorRef, DependencySpec, Effects, FieldAssumeOrigin, FunctionAssume,
  FunctionRef, ModuleAssume, ModuleAssumeOrigin, PathDependency,
  PathDependencyInferred, ProjectInferred, QualifiedName, TypeFieldEffect,
  UserAssume,
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
    // tagged with its origin: a **Closed** one read from a `where returns`
    // clause has its free variables checked against the producer's real
    // callback parameters before they are bound; a **Fresh** one produced this
    // run, and any ground summary, is safe.
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
    // Package-wide constructor field labels, keyed by `#(defining module,
    // variant)`. Lets a construction of another module's record route its
    // positional arguments to the fields they fill. (A same-module
    // constructor's labels are derived locally from the module.)
    constructors: Dict(#(String, String), List(Option(String))),
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
    // What the Gleam fallback body of an `@external` does, where that body runs
    // — the targets its declaration leaves uncovered — paired with the
    // parameter bounds the term is stated over. Ordinary Gleam that runs, so
    // every caller is charged it on top of whatever declares the external —
    // unless a suppressing declaration answers alone
    // (`suppresses_running_fallback`) — while the external's own `check` line
    // always covers both. Held apart from
    // `all_effects` because the declaration has to stay reportable on its own:
    // the two are unioned when a name is charged, and told apart when its
    // provenance is explained. The bounds stay beside the term they bind: which
    // bounds are a fallback's is a provenance question every reader answers
    // structurally from this one map.
    //
    // This package's externals and its dependencies' alike: a dependency module
    // declaring one is re-parsed and walked before anything of this package is
    // inferred, so the body a consumer runs is summarized here too. A name here
    // is one a walk reached, which is what `widens_with_dependency_fallback`
    // reads to tell a walked dependency body from an unwalked one.
    fallback_summaries: Dict(QualifiedName, #(EffectTerm, List(ParamBound))),
    // The callback parameters of every function whose signature graded parsed,
    // in position order — the signature registry's fn-typed parameters, folded
    // in as plain names so this module stays glance-free. Read only where a
    // *declaration* answers for a name and states no bounds of its own: there
    // the callback share the declaration is silent about is one variable per
    // name here, so a value channel charges the callback the same way a direct
    // call's registry auto-injection does.
    callback_params: Dict(QualifiedName, List(String)),
    // The targets the package under analysis is built for, and whether it named
    // them. Every foreign lookup is read on the build's own targets, and a
    // declaration is read on the wider set an assumption cannot narrow — see
    // `reachable_halves`.
    package_targets: types.PackageTargets,
    // The targets the code being walked runs on, where that is narrower than
    // the package's own: a Gleam fallback body reached only on the targets its
    // own declaration leaves uncovered. The package's own targets outside such a
    // walk, and `None` for a base no caller has told about a package, which
    // charges every name on every target.
    //
    // Set because a foreign name reads differently from inside one: a fallback
    // running on Erlang that calls a JavaScript-only `@external` reaches that
    // callee's *Gleam fallback*, never the foreign implementation its
    // declaration describes. Charging the union there attributes an effect to a
    // body that provably cannot perform it — the two implementations are never
    // built together.
    active_targets: Option(Set(String)),
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
  knowledge_base_from_catalog(
    packages_directory,
    load_project_catalog(manifest_path),
    dependency_foreign,
  )
}

// The bundled catalog as one value. Held together so a caller needing it twice
// — the knowledge base and the spec lint both do — locates the directory once,
// and so a missing catalog is reported once rather than per reader.
pub type BundledCatalog {
  BundledCatalog(
    functions: Dict(QualifiedName, #(EffectTerm, LookupOrigin)),
    modules: Dict(String, #(EffectTerm, LookupOrigin)),
    param_bounds: Dict(QualifiedName, List(ParamBound)),
    type_fields: List(#(FieldAnnotation, LookupOrigin)),
  )
}

// The catalog graded ships, selected against `manifest_path`'s installed
// versions.
pub fn load_project_catalog(manifest_path: String) -> BundledCatalog {
  let #(functions, modules, param_bounds, type_fields) =
    load_catalog(catalog_directory(), manifest_path)
  BundledCatalog(functions:, modules:, param_bounds:, type_fields:)
}

// The same as `load_knowledge_base`, over a catalog the caller already loaded.
pub fn knowledge_base_from_catalog(
  packages_directory: String,
  catalog: BundledCatalog,
  dependency_foreign: Dict(QualifiedName, types.ForeignFunction),
) -> KnowledgeBase {
  let deps = load_dependencies(packages_directory, dependency_foreign)
  let BundledCatalog(
    functions: cat_effects,
    modules: cat_module_effects,
    param_bounds: cat_params,
    type_fields: cat_type_fields,
  ) = catalog
  KnowledgeBase(
    // Dependency entries win on a clash: dict.merge keeps its second argument.
    all_effects: dict.merge(cat_effects, deps.effects),
    param_bounds: dict.merge(cat_params, deps.params),
    type_fields: dict.new(),
    // Every dependency summary is tagged by `load_dependencies` with the package
    // whose spec held it: Declared for a clause on an `assume` line, Closed for
    // one on an `effects` line.
    returned_operators: deps.returns,
    factories: dict.new(),
    // Update builders are derived from dependency source at run time, not loaded
    // from specs (a serialized signature could skew from the source a consumer
    // compiled against); this starts empty.
    updates: dict.new(),
    constructors: dict.new(),
    // A dependency's module-level external wins over a catalog one for the same
    // module, matching `all_effects`.
    module_effects: dict.merge(cat_module_effects, deps.module_effects),
    provenance: dict.new(),
    // Scanned from the source under analysis, which no dependency spec carries.
    foreign_functions: dict.new(),
    dependency_foreign:,
    project_functions: dict.new(),
    fallback_summaries: dict.new(),
    callback_params: dict.new(),
    package_targets: types.all_targets(),
    active_targets: None,
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
    constructors: dict.new(),
    module_effects: dict.new(),
    provenance: dict.new(),
    foreign_functions: dict.new(),
    dependency_foreign: dict.new(),
    project_functions: dict.new(),
    fallback_summaries: dict.new(),
    callback_params: dict.new(),
    package_targets: types.all_targets(),
    active_targets: None,
  )
}

// Build a knowledge base from the catalog only (no dependency scanning).
pub fn empty_knowledge_base() -> KnowledgeBase {
  let catalog_dir = catalog_directory()
  let #(cat_effects, cat_module_effects, cat_params, cat_type_fields) =
    load_catalog(catalog_dir, "manifest.toml")
  KnowledgeBase(
    all_effects: cat_effects,
    param_bounds: cat_params,
    type_fields: dict.new(),
    returned_operators: dict.new(),
    factories: dict.new(),
    updates: dict.new(),
    constructors: dict.new(),
    module_effects: cat_module_effects,
    provenance: dict.new(),
    foreign_functions: dict.new(),
    dependency_foreign: dict.new(),
    project_functions: dict.new(),
    fallback_summaries: dict.new(),
    callback_params: dict.new(),
    package_targets: types.all_targets(),
    active_targets: None,
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
  type_fields: List(FieldAnnotation),
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
  type_fields: List(#(FieldAnnotation, LookupOrigin)),
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

// Merge assume annotations into a knowledge base.
// Module-level assumes record the whole module's declared effect.
// Function-level assumes are added to all_effects.
//
// `origin` is the source of these declarations: this project's spec passes
// `UserAssume`, the bundled catalog passes `Catalog(package)`. A
// function-level insert records it beside the effect; a module-level one
// records it wrapped in `ModuleAssumeOrigin`, which names both the kind of
// line and the file it sits in.
//
// A declaring line's bound list rides the same fold, at the same precedence:
// a name whose term these externals win takes their bounds with it — empty
// where the line carries none, which pins the pair against a later
// existing-keeps gap-fill — so the term never pairs with a lower tier's
// bounds, whose variable names need not match it.
pub fn with_assumes(
  knowledge_base: KnowledgeBase,
  assumes: List(AssumeAnnotation),
  origin: LookupOrigin,
) -> KnowledgeBase {
  let #(function_assumes, module_assumes) = split_assumes(assumes, origin)
  KnowledgeBase(
    ..knowledge_base,
    all_effects: dict.merge(knowledge_base.all_effects, function_assumes),
    module_effects: dict.merge(knowledge_base.module_effects, module_assumes),
    param_bounds: dict.merge(
      knowledge_base.param_bounds,
      assume_bounds(assumes),
    ),
  )
}

// The two tiers a set of `assume` lines feeds: function-level entries
// keyed by `QualifiedName`, module-level ones keyed by module name.
type AssumeTiers =
  #(
    Dict(QualifiedName, #(EffectTerm, LookupOrigin)),
    Dict(String, #(EffectTerm, LookupOrigin)),
  )

// Sort assume annotations into the two maps they feed, each term paired with
// the source that declared it. Splitting is separate from merging so each
// caller decides its own precedence.
//
// A line with no effects clause is skipped: it claims nothing on this channel,
// so it keys nothing here and the tiers below keep answering. Every path into
// the two maps comes through here, so a `None` cannot be read as `[]`
// anywhere. The function tier folds the same selection the bounds loader
// folds (`declaring_function_assumes`), each dict keeping the last entry.
fn split_assumes(
  assumes: List(AssumeAnnotation),
  origin: LookupOrigin,
) -> AssumeTiers {
  let function_assumes =
    list.fold(
      declaring_function_assumes(assumes),
      dict.new(),
      fn(accumulator, entry) {
        let #(name, effects, _bounds) = entry
        dict.insert(accumulator, name, #(
          effect_term.from_effect_set(effects),
          origin,
        ))
      },
    )
  let module_assumes =
    list.fold(assumes, dict.new(), fn(accumulator, assume) {
      case assume.target, assume.effects {
        ModuleAssume, Some(effects) ->
          dict.insert(accumulator, assume.module, #(
            effect_term.from_effect_set(effects),
            ModuleAssumeOrigin(source: origin),
          ))
        _, _ -> accumulator
      }
    })
  #(function_assumes, module_assumes)
}

// Every function assume that declares effects, keyed and in file order —
// the one selection the assume tier and the bounds map both fold, last
// entry winning in each, so on a duplicate declaration the winning term and
// the winning bounds come off the same line by construction rather than by
// two rules kept in step.
fn declaring_function_assumes(
  assumes: List(AssumeAnnotation),
) -> List(#(QualifiedName, EffectSet, List(ParamBound))) {
  list.filter_map(assumes, fn(assume) {
    case assume.target, assume.effects {
      FunctionAssume(function), Some(effects) ->
        Ok(#(QualifiedName(assume.module, function), effects, assume.params))
      _, _ -> Error(Nil)
    }
  })
}

// Look up the effect set for a qualified function name, with the source that
// wrote the entry that answered.
pub fn lookup(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> EffectLookup {
  let found = case raw_lookup(knowledge_base, name) {
    Some(#(term, source)) -> Known(term, source)
    None -> Unknown
  }
  with_dependency_fallback(knowledge_base, name, found)
}

// The winning entry for `name`, raw: the per-function map first, the
// module-level fallback second. The one spelling of that tier order — `lookup`
// widens this value and `raw_declaration` reads it as written, so the two
// cannot answer off different entries.
fn raw_lookup(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Option(#(EffectTerm, types.EffectSource)) {
  case dict.get(knowledge_base.all_effects, name) {
    Ok(#(term, origin)) -> Some(#(term, types.FunctionEntry(origin:)))
    Error(Nil) ->
      case dict.get(knowledge_base.module_effects, name.module) {
        Ok(#(term, origin)) -> Some(#(term, types.ModuleAssumeEntry(origin:)))
        Error(Nil) -> None
      }
  }
}

// Widen a dependency external's answer by a fallback body nothing walked.
//
// A declaration is unioned with its running fallback body's own effects,
// because that body is ordinary Gleam that runs on the targets the declaration
// doesn't cover. The dependency pass walks those bodies and records them in
// `fallback_summaries`, and where it did, the union takes its second operand
// from there like any of this package's own — nothing is widened here.
//
// Where it did not — a module that would not re-parse, one dropped from a
// cyclic import graph — the declaration alone would read as the whole story:
// `assume dep.run : []` over an `@external(javascript, …)` whose Erlang
// fallback prints would be believed pure on Erlang. `[Unknown]` is the missing
// operand there — the body ran, and what it did is not knowable from here.
//
// Which halves the *calling* body reaches decides this the way it decides one of
// this package's own (see `reachable_halves`), and it is decided here because
// the widening happens here: the `[Unknown]` travels under the declaration's
// source, so nothing downstream can tell it back out of the term or subtract it.
fn with_dependency_fallback(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
  found: EffectLookup,
) -> EffectLookup {
  use <- bool.guard(
    when: !widens_with_dependency_fallback(knowledge_base, name),
    return: found,
  )
  case found {
    Unknown -> found
    Known(term, source) ->
      case reachable_halves(knowledge_base, name) {
        // The declaration covers every target the calling body runs on, so the
        // dependency's fallback body runs only where that body does not. There
        // is no unwalked body in reach to stand `[Unknown]` in for.
        DeclarationOnly -> found
        // And none of them: the dependency's body is what runs where this call
        // is made, so it is the whole answer — while the declaration states what
        // foreign code this call never reaches would have done.
        FallbackOnly -> Known(effect_term.unknown(), source)
        DeclarationAndFallback ->
          Known(
            effect_term.normalize(types.TUnion([term, effect_term.unknown()])),
            source,
          )
      }
  }
}

// Whether a hit for `name` is widened by the fallback body above: a
// dependency's runs, and nothing walked it.
//
// The widening leaves no mark on the answer — the term gains `[Unknown]` and
// keeps the declaration's source — so a caller that reports provenance asks
// here to tell the two apart. Without it the widened `[Time, Unknown]` reads as
// what the dependency's spec said, when the spec said `[Time]` and the
// `Unknown` is a body nobody walked.
//
// The summary is what makes it a body somebody walked, and it has to be weighed
// here rather than beside the union downstream: `lookup` widens the
// *declaration* term itself, so an `[Unknown]` let through travels under the
// declaration's source and nothing after it can subtract it. Both entry points
// — the widening at `with_dependency_fallback` and the backstop at
// `running_fallback_term` — ask this one question, so both stand down together.
pub fn widens_with_dependency_fallback(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Bool {
  case dict.get(knowledge_base.dependency_foreign, name) {
    Ok(types.ForeignFunction(runs_fallback_body:, ..)) ->
      runs_fallback_body
      && !dict.has_key(knowledge_base.fallback_summaries, name)
    Error(Nil) -> False
  }
}

// Record what one of this package's `@external`s does on the targets its
// declaration leaves uncovered, each term paired with the parameter bounds it
// is stated over. Merged into what is already recorded, so the topological
// pass adds a module at a time.
pub fn with_fallback_summaries(
  knowledge_base: KnowledgeBase,
  summaries: Dict(QualifiedName, #(EffectTerm, List(ParamBound))),
) -> KnowledgeBase {
  KnowledgeBase(
    ..knowledge_base,
    fallback_summaries: dict.merge(knowledge_base.fallback_summaries, summaries),
  )
}

// Record the callback parameters of the functions whose signatures graded
// parsed, in position order. Merged into what is already recorded, so a caller
// that parses one more module — the single-module fast path — adds to it.
pub fn with_callback_params(
  knowledge_base: KnowledgeBase,
  callbacks: Dict(QualifiedName, List(String)),
) -> KnowledgeBase {
  KnowledgeBase(
    ..knowledge_base,
    callback_params: dict.merge(knowledge_base.callback_params, callbacks),
  )
}

// The callback parameter names recorded for `name`, in position order. Empty
// where no parsed signature keys it — a dependency whose source is absent or
// would not parse, which is where this widening degrades to charging nothing.
fn registry_callback_names(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> List(String) {
  dict.get(knowledge_base.callback_params, name) |> result.unwrap([])
}

// Whether a declaration's silence about `name`'s callbacks is filled in from
// the signature registry: a parsed signature says the name takes a callback at
// all, it states no bounds of its own, no fallback summary carries the callback
// variables already, and a declaration answers for the name.
//
// The bounds and summary gates are what keep this off every name that already
// answers for its callbacks: a bounded line wrote its own answer, and a
// recorded summary's bounds are the ones `conservative_callback_charge`
// prefers. Requiring a declaration is what keeps an undeclared external out —
// nothing speaks for it, and synthesizing a variable would put one in the term
// no line ever scoped.
//
// Asked cheapest and most selective first, because every value channel asks it
// of every name it resolves: almost nothing takes a callback at all, so the one
// lookup that settles that comes before the two that weigh how the name is
// declared — `raw_declaration`, the dearer of them, last.
fn synthesizes_registry_share(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Bool {
  registry_callback_names(knowledge_base, name) != []
  && !dict.has_key(knowledge_base.fallback_summaries, name)
  && case raw_declaration(knowledge_base, name) {
    None -> False
    Some(#(_term, origin)) ->
      declared_param_bounds(knowledge_base, name, origin) == []
  }
}

// The bounds the *declaration* states for `name`.
//
// None where it is a module-level `assume`, which cannot state any: the grammar
// refuses a bound list on a module path, so whatever `param_bounds` holds under
// such a name came from somewhere else — this run's inference over the very
// body the declaration speaks over, or a committed line for it. Those describe
// what the body does with its callback, which is exactly what the declaration
// overrode, and reading them as the declaration's own answer is what let a
// module-level `assume` silently vouch for every callback its functions take.
fn declared_param_bounds(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
  origin: LookupOrigin,
) -> List(ParamBound) {
  case origin {
    ModuleAssumeOrigin(_) -> []
    _ -> line_param_bounds(knowledge_base, name)
  }
}

// Whether `name`'s recorded bounds are inference's rather than a declaration's
// — a module-level `assume` standing over a body this run also walked. They
// bind nothing in the term the declaration put in that body's place, and
// holding them out is what lets the call site's own registry injection run:
// that reading weighs each argument's shape, declining the closures whose
// bodies are walked separately, where a synthesized bound binds them all.
fn holds_only_inferred_bounds(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Bool {
  line_param_bounds(knowledge_base, name) != []
  && case raw_declaration(knowledge_base, name) {
    Some(#(_term, ModuleAssumeOrigin(_))) -> True
    _ -> False
  }
}

// Which side of the foreign split owns `name`'s synthesized callback share.
// Two readings of one question, so the halves cannot drift into overlapping or
// leaving a gap between them.
//
// The foreign half is folded into the charge itself, where every channel —
// direct call included — reads it. The other half is a value channel's alone,
// because a *direct* call into ordinary Gleam has a better reading available:
// the call site's own registry injection, which weighs each argument's shape
// and declines the closures whose bodies are walked separately. That reading
// only runs where the callee states no bounds, which is what
// `holds_only_inferred_bounds` restores for a module-declared name.
fn synthesizes_foreign_share(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Bool {
  synthesizes_registry_share(knowledge_base, name)
  && is_value_opaque(knowledge_base, name)
}

fn synthesizes_channel_share(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Bool {
  synthesizes_registry_share(knowledge_base, name)
  && !is_value_opaque(knowledge_base, name)
}

// The bounds a per-function line states for `name`, raw — the map's own entry,
// before a fallback summary's bounds are paired with it.
fn line_param_bounds(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> List(ParamBound) {
  dict.get(knowledge_base.param_bounds, name) |> result.unwrap([])
}

// What a foreign name costs the code being walked, and which halves the charge
// is made of.
//
// One value, computed once per lookup, so no two readers assemble the halves
// themselves and come to different totals: `term` is what a caller pays,
// `fallback` is where the half a running Gleam body contributed on its own
// stands — charged into the total, or suppressed out of it by the winning
// `assume` line — and `declaration` says where what the declaration states
// stands in the charge.
pub type ForeignCharge {
  ForeignCharge(
    term: EffectTerm,
    fallback: types.FallbackDisposition(EffectTerm),
    declaration: DeclarationStanding,
  )
}

// Where a foreign name's declaration stands in the charge.
pub type DeclarationStanding {
  // In reach: `term` holds what it declares.
  DeclarationCharged
  // Out of reach — it declares an implementation no target this walk runs on
  // compiles — and a Gleam fallback body runs in its place. Neither the
  // declaration's source nor the `[Unknown]` an undeclared external carries
  // describes any part of the charge; the fallback half does.
  FallbackAnswersInstead
  // Out of reach with no Gleam body to run in its place: nothing this walk
  // reaches implements the name at all. Charging what the declaration states
  // would charge an implementation provably not built, so the charge is the
  // `[Unknown]` that says only that graded cannot see what runs.
  NothingImplementsName
}

// The charge for `name` over what the base itself says declares it — the one
// derivation behind every surface that answers "what does this name charge,
// and from where". Each caller takes all three halves from the one value;
// assembling them from separate calls is how one name came to be charged one
// set by a caller and another by the query that reports it.
//
// The declared half is read raw from the base's own maps rather than taken
// from a `lookup`: `lookup` widens an unwalked dependency declaration with
// `[Unknown]` under the declaration's own source, and nothing downstream can
// tell that half back out — a charge assembled over the widened term would
// re-union the body a suppressing line dropped. The widening is re-derived on
// the fallback half instead (`running_fallback_term` backstops with
// `[Unknown]` off the same question), so every non-suppressed total comes out
// as `lookup`'s reading does.
//
// The declaration alone is the whole story only where it covers every target the
// walking code runs on. Where it doesn't, a Gleam fallback body runs, and that
// body is ordinary code whose effects the caller pays too — so the charge is the
// union. Composition is union, so a caller inherits both — unless the winning
// declaration is one that suppresses the running fallback
// (`suppresses_running_fallback`): a written `assume` is trusted whole, so the
// charge is the declared term alone and the body's half rides beside it as
// `FallbackSuppressed` for the diagnostics that say so.
//
// Both halves only where the walking code reaches both. From inside a fallback
// body the targets are narrower than the package's, and the two halves answer
// for different ones — see `reachable_halves`.
pub fn declared_charge(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> ForeignCharge {
  let declaration = raw_declaration(knowledge_base, name)
  let halves = reachable_halves(knowledge_base, name)
  let suppressed = suppressing_declaration(declaration, halves)
  let raw = case declaration {
    Some(#(term, _origin)) -> term
    None -> effect_term.unknown()
  }
  // One call-site bound list serves both halves, suppressed or not: the
  // self-referential rewrite renames each declared payload variable to the
  // parameter that binds it, so the declared term and the fallback summary —
  // charged as a union, or held apart as a suppressed share — keep distinct
  // variables for distinct parameters and each binds exactly its own
  // argument. `lookup_param_bounds` serves the matching rewritten list.
  let declared = declared_beside_fallback(knowledge_base, name, raw)
  // What the declaration charges wherever it answers without a running
  // fallback beside it — three of the readings below. One definition, so no two
  // of them can come to different terms, and deferred, so the three that read a
  // fallback body instead pay nothing to have it in scope.
  let alone = fn() {
    conservative_callback_charge(knowledge_base, name, declared)
  }
  let fallback = running_fallback_term(knowledge_base, name)
  case halves, fallback {
    // Every target this walk runs on has a foreign implementation for `name`, so
    // its Gleam fallback runs only where this walk does not reach. A boundless
    // declaration — suppressing or not — still keeps the conservative callback
    // charge on this reading: the foreign implementation may call the callback
    // too, the fallback term that would otherwise carry it is no part of the
    // total, and the recorded summary bounds — or, for a name no summary
    // covers, the parsed signature's callback parameters — stand in for the
    // registry injection they pre-empt at the call site.
    DeclarationOnly, _ ->
      ForeignCharge(
        term: alone(),
        fallback: types.NoFallback,
        declaration: DeclarationCharged,
      )
    // No foreign implementation on any target this walk runs on: the fallback
    // body is what it calls, and the declaration answers for targets it never
    // reaches. Never suppressed — suppression there would charge a build that
    // didn't happen.
    FallbackOnly, Some(fallback) ->
      ForeignCharge(
        term: fallback,
        fallback: types.FallbackCharged(fallback),
        declaration: FallbackAnswersInstead,
      )
    FallbackOnly, None ->
      ForeignCharge(
        term: effect_term.unknown(),
        fallback: types.NoFallback,
        declaration: NothingImplementsName,
      )
    // Both halves in reach, each on its own targets: the union — or, under a
    // suppressing declaration, the declared term alone with the body's half
    // recorded as suppressed, so a report can still quote what was overridden.
    DeclarationAndFallback, Some(fallback) ->
      case suppressed {
        True ->
          ForeignCharge(
            term: alone(),
            fallback: types.FallbackSuppressed(fallback),
            declaration: DeclarationCharged,
          )
        False ->
          ForeignCharge(
            term: effect_term.normalize(types.TUnion([declared, fallback])),
            fallback: types.FallbackCharged(fallback),
            declaration: DeclarationCharged,
          )
      }
    // A declaration beside a fallback body nothing runs — a single-target
    // external under defaulted targets, whose Gleam body the declaration's own
    // target never reaches. The declaration is the whole charge, and being
    // boundless it says nothing about the callbacks, so the same conservative
    // share rides it.
    DeclarationAndFallback, None ->
      ForeignCharge(
        term: alone(),
        fallback: types.NoFallback,
        declaration: DeclarationCharged,
      )
  }
}

// The term a declaration charges where the fallback term carries no part of
// the total — a suppressing line, whose body share is held apart, or a
// declaration-only reading, whose fallback is out of reach. A bounded line
// wrote its own answer for the external's callbacks and stays as written. A
// boundless one says nothing about them, so the charge keeps one variable per
// recorded callback parameter — the same conservative share a direct call
// auto-injects from the registry, kept here so a value channel (an operator
// argument, a wired field) charges the callback too. Only the parameter-named
// bounds qualify: a dotted field bound (`r.go`) exists solely to bind the
// body's own field call, and reviving it would charge the share the reading
// dropped.
//
// A summary-less external — a bodyless one, or one whose declaration covers
// every target — has no recorded bounds to read the callbacks off, so the
// names come from the parsed signature instead
// (`synthesizes_registry_share`). Without that the share stood on the direct
// call alone, where the checker injects it from the same registry, and the
// same external passed to a helper or wired into a field charged nothing for
// its callback.
//
// Foreign names only on that last reading. Ordinary Gleam under a module-level
// `assume` comes through this derivation too — a sibling call into one is
// charged what declares it — and that is a *direct* call, where the checker's
// registry injection answers with the argument's shape in hand and declines
// the ones it cannot trace. Synthesizing here would charge that call a
// variable no bound list of this name's binds. What such a name owes on a
// value channel is `declared_effects`'.
fn conservative_callback_charge(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
  declared: EffectTerm,
) -> EffectTerm {
  use <- bool.guard(
    when: line_param_bounds(knowledge_base, name) != [],
    return: declared,
  )
  let callback_names = case dict.get(knowledge_base.fallback_summaries, name) {
    Ok(#(_term, fallback_bounds)) ->
      fallback_bounds
      |> list.filter(fn(bound) { !string.contains(bound.name, ".") })
      |> list.map(fn(bound) { bound.name })
    Error(Nil) -> foreign_registry_callbacks(knowledge_base, name)
  }
  use <- bool.guard(when: callback_names == [], return: declared)
  effect_term.normalize(
    types.TUnion([declared, ..list.map(callback_names, types.TVar)]),
  )
}

// The registry's callback names for a summary-less *foreign* name, and none
// for anything else — the reading `conservative_callback_charge` falls back to
// where no recorded summary names the callbacks.
fn foreign_registry_callbacks(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> List(String) {
  case synthesizes_foreign_share(knowledge_base, name) {
    True -> registry_callback_names(knowledge_base, name)
    False -> []
  }
}

// Whether a declaring origin's line, in reach beside a running Gleam fallback
// body, answers alone: the fallback half is dropped from the union on its
// say-so. Only a *written* per-function line over the author's own body — the
// consumer's `assume`, or the line a dependency's author shipped in their
// spec. `assume` means trusted and never verified everywhere else in the
// tool, and the line's author can see the fallback body too; if they wanted
// the union they would write the wider term.
//
// The catalog does not suppress — it describes a version graded's maintainers
// annotated, not necessarily the installed body. Neither does a module-level
// `assume`: a blanket over names nothing keys individually never named the
// function it would be silencing.
pub fn suppresses_running_fallback(origin: LookupOrigin) -> Bool {
  case origin {
    UserAssume | DependencySpec(_) | PathDependency(_) -> True
    Catalog(_)
    | ModuleAssumeOrigin(_)
    | CommittedSpec
    | ProjectInferred
    | PathDependencyInferred(_)
    | FieldAssumeOrigin(_) -> False
  }
}

// The winning declaring entry for `name`, raw: the value `lookup` computes
// before `with_dependency_fallback` widens it, held to declaring origins as
// the charge requires. `None` where nothing declares the name — a
// non-declaring entry describes a body the foreign implementation needn't
// match, so it declares no more than no entry at all.
fn raw_declaration(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Option(#(EffectTerm, LookupOrigin)) {
  case raw_lookup(knowledge_base, name) {
    Some(#(term, source)) -> {
      let origin = origin_of(source)
      case declares_foreign_code(origin) {
        True -> Some(#(term, origin))
        False -> None
      }
    }
    None -> None
  }
}

// Whether a suppressing declaration answers for `name`'s charge, over halves
// the caller already derived — `declared_charge` decides once off the values
// its arms match on. False where only the fallback is in reach: there the
// body answers instead and its bounds must keep binding its term.
fn suppressing_declaration(
  declaration: Option(#(EffectTerm, LookupOrigin)),
  halves: ReachableHalves,
) -> Bool {
  case declaration {
    Some(#(_term, origin)) ->
      suppresses_running_fallback(origin)
      && case halves {
        DeclarationAndFallback | DeclarationOnly -> True
        FallbackOnly -> False
      }
    None -> False
  }
}

// A bounded declaration standing beside a recorded fallback summary, its term
// rewritten into self-referential form. The charge unions the two halves and
// one bound list binds them at the call site, while each half's variables are
// scoped by its own line alone — a declared payload variable that happens to
// name another fallback parameter (`cb: [other]`) is a distinct variable from
// the parameter the fallback's `other: [other]` binds, and one substitution
// map over the raw union binds one half's variable through the other half's
// argument. Renamed to the parameter whose payload binds it, every variable
// of either half names its own parameter and binds exactly that argument; a
// variable no payload binds is the `[Unknown]` no call site can ever resolve
// (the spec lint flags it). The declaring line's bound list is rewritten off
// the same rename map by `self_referential_declaration`, which
// `lookup_param_bounds` reads its half of. A boundless declaration is left
// alone: its variables resolve through registry-synthesized bounds that
// already carry parameter names.
fn declared_beside_fallback(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
  declared: EffectTerm,
) -> EffectTerm {
  use <- bool.guard(
    when: !dict.has_key(knowledge_base.fallback_summaries, name),
    return: declared,
  )
  case dict.get(knowledge_base.param_bounds, name) {
    Ok([_, ..] as bounds) -> {
      let #(_, rename) = self_referential_declaration(bounds)
      rename(declared)
    }
    Ok([]) | Error(Nil) -> declared
  }
}

// A bounded declaration's self-referential form, both halves off one rename
// map so the term and the bounds that bind it cannot drift apart: the closure
// renames each term variable to the parameter whose payload binds it — the
// last binder winning on a duplicate, as it does in the checker's binding
// fold, and `[Unknown]` where none does — and the bound list has every
// binding payload replaced by its own parameter name, a ground budget kept as
// written. The bounds scrub is deliberately broader than the map's image: on
// a duplicate binder the map keeps only the last, but every binding payload
// is scrubbed, so no declared payload variable survives to capture a
// fallback parameter of the same name at the call site.
pub fn self_referential_declaration(
  bounds: List(ParamBound),
) -> #(List(ParamBound), fn(EffectTerm) -> EffectTerm) {
  let renames =
    list.fold(bounds, dict.new(), fn(acc, bound) {
      bound.effects
      |> effect_term.free_vars()
      |> set.fold(acc, fn(acc, variable) {
        dict.insert(acc, variable, bound.name)
      })
    })
  let rewritten =
    list.map(bounds, fn(bound) {
      case set.is_empty(effect_term.free_vars(bound.effects)) {
        True -> bound
        False ->
          types.ParamBound(name: bound.name, effects: types.TVar(bound.name))
      }
    })
  let rename = fn(declared: EffectTerm) {
    let bindings =
      declared
      |> effect_term.free_vars()
      |> set.fold(dict.new(), fn(acc, variable) {
        case dict.get(renames, variable) {
          Ok(parameter) -> dict.insert(acc, variable, types.TVar(parameter))
          Error(Nil) -> dict.insert(acc, variable, effect_term.unknown())
        }
      })
    effect_term.subst(declared, bindings)
  }
  #(rewritten, rename)
}

// What a running fallback body contributes to `name`'s charge, before the
// narrowing above weighs whether the walk reaches it.
//
// `None` where no fallback runs. An external whose body a walk reached — this
// package's, or a dependency's — contributes what that body does. One no walk
// reached contributes `[Unknown]`, because both scans record that a fallback
// runs before anything walks it: this package's where the pass never reached the
// walk (an import cycle bails the whole in-memory inference), a dependency's
// where its module would not re-parse. Either would otherwise leave the
// declaration standing alone over a body that prints.
fn running_fallback_term(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Option(EffectTerm) {
  case dict.get(knowledge_base.fallback_summaries, name) {
    Ok(#(fallback, _bounds)) -> Some(fallback)
    Error(Nil) ->
      case
        widens_with_dependency_fallback(knowledge_base, name)
        || runs_own_fallback_body(knowledge_base, name)
      {
        True -> Some(effect_term.unknown())
        False -> None
      }
  }
}

// Which halves of a foreign name's answer — its declaration, its running
// fallback body — the code being walked can actually reach.
type ReachableHalves {
  // The unrestricted reading, and what every ordinary caller gets: compiled for
  // everything the package is, it reaches whichever half each target has.
  DeclarationAndFallback
  DeclarationOnly
  FallbackOnly
}

// Which halves a walk on `active_targets` reaches for `name`.
//
// A Gleam fallback body runs on the targets its own declaration leaves
// uncovered, and a name it calls is reached from those and no others. So the
// callee is read there: a target of its own that its `@external` covers reaches
// foreign code, one it doesn't reaches the callee's Gleam fallback. Two
// externals declared for opposite targets are never built together, and reading
// their union charged each with what only the other can do.
//
// Narrowed once more to the targets the build compiles, which is what keeps a
// dependency `@external` covering them from being read as falling back to Gleam
// somewhere — two dozen-odd functions of the standard library declare Erlang and
// fall back to Gleam for JavaScript, and an Erlang build reaches no part of that
// body. Where the build's targets are graded's own assumption rather than the
// package's word, that narrowing may not be the thing that drops a declaration:
// a `--target` this reading cannot see compiles the foreign implementation the
// declaration describes, so both halves stay in reach.
//
// `DeclarationAndFallback` wherever the narrowing has nothing to say — outside
// a walk that carries targets, for a name no scan recorded as foreign, and where
// the sets leave the walk reaching neither half, which is source the compiler
// rejects. Widening back to the union there keeps the conservative reading in
// every case this cannot decide.
//
// A foreign name declaring *no* readable target is one of those. An `@external`
// whose target argument is not a plain name states nothing this can read, and
// "no target declared" is the same empty set as "a target declared in a form
// this cannot read" — read as the first, every target reaches the fallback, and
// the Gleam body becomes the trusted implementation of foreign code whose
// declaration graded simply failed to parse. `extract.is_foreign_definition`
// keeps such a declaration foreign for exactly this reason; keeping both halves
// here is the same refusal to decide on an unread target.
fn reachable_halves(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> ReachableHalves {
  case knowledge_base.active_targets, foreign_entry(knowledge_base, name) {
    Some(active),
      Some(types.ForeignFunction(compiled_targets:, declared_targets:, ..))
    -> {
      use <- bool.guard(
        when: set.is_empty(declared_targets),
        return: DeclarationAndFallback,
      )
      let reachable =
        set.intersection(active, compiled_targets)
        |> set.intersection(types.build_targets(knowledge_base.package_targets))
      let declared = set.intersection(reachable, declared_targets)
      let undeclared = set.difference(reachable, declared_targets)
      case set.is_empty(declared), set.is_empty(undeclared) {
        False, True -> DeclarationOnly
        True, False ->
          case knowledge_base.package_targets {
            types.NamedTargets(_) -> FallbackOnly
            types.DefaultedTargets -> DeclarationAndFallback
          }
        False, False | True, True -> DeclarationAndFallback
      }
    }
    None, _ | _, None -> DeclarationAndFallback
  }
}

// What either scan recorded about `name` being foreign code. This package's
// externals first: a dependency's name cannot collide with one, and asking both
// is what lets a fallback body read a dependency's target-conditional external
// on its own targets too.
fn foreign_entry(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Option(types.ForeignFunction) {
  case dict.get(knowledge_base.foreign_functions, name) {
    Ok(entry) -> Some(entry)
    Error(Nil) ->
      option.from_result(dict.get(knowledge_base.dependency_foreign, name))
  }
}

// The package the base answers for: which targets its build compiles, and every
// foreign lookup narrowed to them package-wide.
//
// Set once per command, before anything is looked up, so a query about a name
// reads it on the same targets the walk charges it on. A body that runs on
// narrower targets than the package's narrows further with `with_active_targets`.
pub fn with_package_targets(
  knowledge_base: KnowledgeBase,
  targets: types.PackageTargets,
) -> KnowledgeBase {
  KnowledgeBase(
    ..knowledge_base,
    package_targets: targets,
    active_targets: Some(types.declaration_targets(targets)),
  )
}

// Narrow every foreign lookup to the targets `active` names, for walking a body
// that runs only there. `None` reads every name on every target.
pub fn with_active_targets(
  knowledge_base: KnowledgeBase,
  active: Option(Set(String)),
) -> KnowledgeBase {
  KnowledgeBase(..knowledge_base, active_targets: active)
}

// Whether `name` is one of *this package's* `@external`s whose Gleam fallback
// body runs. What the source scan recorded, which is settled long before any
// body is walked — so it is the evidence that a missing summary is a walk that
// never happened rather than a fallback that does nothing.
//
// This package's map only: a dependency's running fallback is
// `widens_with_dependency_fallback`'s, which asks the same question of the other
// scan's map and of the summary a walk of that dependency's body left behind.
fn runs_own_fallback_body(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Bool {
  case dict.get(knowledge_base.foreign_functions, name) {
    Ok(types.ForeignFunction(runs_fallback_body:, ..)) -> runs_fallback_body
    Error(Nil) -> False
  }
}

// The parameter bounds a running fallback body's own effects are stated over
// — empty where no fallback of this package's runs for `name`. A fallback
// that calls a function-typed parameter states that parameter's effects, so
// its summary's term is polymorphic over exactly these bounds — as a bounded
// declaration's term is over its own line's — and without the bound the
// variable binds to nothing at the call site and collapses to `[Unknown]`,
// charging a caller for a callback it can see is pure.
pub fn fallback_param_bounds(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> List(types.ParamBound) {
  case dict.get(knowledge_base.fallback_summaries, name) {
    Ok(#(_term, bounds)) -> bounds
    Error(Nil) -> []
  }
}

// Record what a dependency's own source says is `@external`. Merged into what
// is already recorded, so a caller scanning one more dependency module adds to
// it — which is how a fast path that parses a single module reaches the same
// answer the whole-package scan would.
pub fn with_dependency_foreign(
  knowledge_base: KnowledgeBase,
  names: Dict(QualifiedName, types.ForeignFunction),
) -> KnowledgeBase {
  KnowledgeBase(
    ..knowledge_base,
    dependency_foreign: dict.merge(knowledge_base.dependency_foreign, names),
  )
}

// Whether `name` is foreign code a *dependency's* source declares `@external`.
pub fn is_dependency_foreign_function(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Bool {
  dict.has_key(knowledge_base.dependency_foreign, name)
}

// The origin a lookup's source names, for a caller that records provenance
// beside a term rather than rendering it.
pub fn origin_of(source: types.EffectSource) -> LookupOrigin {
  case source {
    types.FunctionEntry(origin:) -> origin
    types.ModuleAssumeEntry(origin:) -> origin
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
// counterpart — nothing declares the provenance of the record an FFI factory
// builds — so every `@external` is opaque to them, declared or not, fallback or
// not. The one exception is the returned operator, which a `where returns`
// line declares: that channel weighs a declaration through
// `declared_return_standing` and asks this only about the summaries it does
// not cover.
pub fn is_value_opaque(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Bool {
  is_foreign_function(knowledge_base, name)
  || is_dependency_foreign_function(knowledge_base, name)
}

// Whether an origin speaks for code graded cannot see. An `assume`
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
    UserAssume
    | Catalog(_)
    | ModuleAssumeOrigin(_)
    | DependencySpec(_)
    | PathDependency(_) -> True
    // Inference over a spec-less path dependency's source is not a declaration:
    // it walked an `@external`'s body, which is exactly what no entry may speak
    // for. It ranks below the catalog for the same reason.
    CommittedSpec
    | ProjectInferred
    | PathDependencyInferred(_)
    | FieldAssumeOrigin(_) -> False
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
//
// One share rides *beside* this boundary rather than inside it: the callback a
// boundless declaration over a **non-foreign** name is silent about. It cannot
// live here, because a same-module sibling's direct call routes through this
// same answer (`declares_for_callers`) and a direct call already charges its
// callbacks precisely, from the argument in hand. So a value channel reads
// `declared_effects` and `value_channel_bounds`, which add it, and this
// function answers those names as written. The invariant above holds outright
// for foreign names, whose share `declared_charge` folds in below.
pub fn lookup_declared(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> EffectLookup {
  let found = lookup(knowledge_base, name)
  // A dependency's `@external` is foreign for the same reason this package's
  // is, and an entry inferred over one — as a spec-less path dependency's
  // source inference produces — describes a body its FFI needn't match. The
  // gate is one rule over both maps, so a name reads the same to a caller and
  // to the query.
  use <- bool.guard(
    when: !is_foreign_function(knowledge_base, name)
      && !is_dependency_foreign_function(knowledge_base, name),
    return: found,
  )
  case found {
    Known(_term, source) ->
      case declares_foreign_code(origin_of(source)) {
        // The term comes off the charge, not off `lookup`'s widened reading:
        // the charge derives the declared half raw and weighs the fallback —
        // suppression included — itself.
        True -> Known(declared_charge(knowledge_base, name).term, source)
        // A non-declaring entry — inference over the body — answers no more
        // than no entry at all, and no less either: rejecting it leaves the
        // external undeclared, not silent, so the fallback its body runs is
        // still charged.
        False -> undeclared_lookup(knowledge_base, name)
      }
    Unknown -> undeclared_lookup(knowledge_base, name)
  }
}

// What an external nothing declares answers: `[Unknown]`, unioned with its
// walked Gleam fallback body where the reading reaches that body — it is still
// code that runs, so what it does is charged even where no declaration answers.
// The charge finds no declaring entry and derives the same `[Unknown]`
// declared half itself.
//
// Charged through the same narrowing every other reader goes through, so a
// warning quoting this answer names the effects the walk charges and no others:
// a body the walk's targets never reach is no part of it, and where that body is
// the only implementation in reach, the `[Unknown]` standing for foreign code is
// no part of it either.
fn undeclared_lookup(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> EffectLookup {
  case dict.get(knowledge_base.fallback_summaries, name) {
    Ok(_) ->
      Known(
        declared_charge(knowledge_base, name).term,
        types.FunctionEntry(origin: ProjectInferred),
      )
    Error(Nil) -> Unknown
  }
}

// The same as an `EffectTerm`, `[Unknown]` where nothing answers for the name.
// The term may be second-order (carry operator applications) for higher-order
// functions; callers reduce it at the resolution boundary.
//
// This is the value channels' reading — a function passed to a higher-order
// callee, lifted as an operator argument, or wired into a record field — and it
// carries the conservative callback share for a *declared* name the charge
// itself does not widen. A foreign name's share rides its charge, so every
// channel reads one term; a Gleam function a catalog entry or a module-level
// `assume` declares has no charge to ride, and a declaration silent about its
// callbacks says nothing about what the value does with them.
pub fn declared_effects(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> EffectTerm {
  case lookup_declared(knowledge_base, name) {
    Known(effect_term, _) ->
      value_channel_term(knowledge_base, name, effect_term)
    Unknown -> effect_term.unknown()
  }
}

// `term` with one variable per recorded callback parameter, where a
// declaration answers for `name` and states no bounds of its own. A foreign
// name is left alone: `declared_charge` already unioned the same share into
// the term every one of its channels reads, and unioning it twice would only
// re-derive it.
//
fn value_channel_term(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
  term: EffectTerm,
) -> EffectTerm {
  use <- bool.guard(
    when: !synthesizes_channel_share(knowledge_base, name),
    return: term,
  )
  effect_term.normalize(
    types.TUnion([
      term,
      ..list.map(registry_callback_names(knowledge_base, name), types.TVar)
    ]),
  )
}

// The same as `declared_effects`, with the source that answered travelling
// beside the term — for the value channel that records provenance rather than
// rendering it, a function wired into a record field.
//
// A value channel reads this rather than `lookup_declared`, whose answer is the
// direct call's: pairing the two by hand at the call site is a step a later
// channel can forget, and forgetting it silently under-charges every
// non-foreign declared name.
pub fn lookup_value_channel(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> EffectLookup {
  case lookup_declared(knowledge_base, name) {
    Known(term, source) ->
      Known(value_channel_term(knowledge_base, name, term), source)
    Unknown -> Unknown
  }
}

// The bounds that bind what a value channel reads: `lookup_param_bounds`,
// widened to the synthesized callback bounds where a declaration answers for
// `name`, states none itself, and the channel's term carries the synthesized
// variables. The bounds a channel binds with pair with the term it charges —
// a variable no bound binds resolves to nothing, and `[Unknown]` is what a
// consumer then reads where the argument's own effect was in hand.
pub fn value_channel_bounds(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> List(ParamBound) {
  case lookup_param_bounds(knowledge_base, name) {
    [] ->
      case synthesizes_channel_share(knowledge_base, name) {
        True -> synthesized_callback_bounds(knowledge_base, name)
        False -> []
      }
    bounds -> bounds
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
//
// A running fallback's recorded bounds lead: its summary's term is stated
// over exactly those parameters, including a girard-typed callback no other
// source names. A per-function bound list — a bounded `assume` line over the
// fallback-running external — rides *with* them rather than standing down:
// each half's variables bind only through its own bounds, whether the foreign
// charge unions the two terms or holds the summary's apart as a suppressed
// share. The declaring line's list rides in its `self_referential_declaration`
// half — the pair of the term rewrite `declared_beside_fallback` applies — so
// a shared name between the halves is always the same parameter binding the
// same argument. Exact duplicates are dropped, so the common case stays one
// list.
//
// Where neither states any — a boundless declaration over a summary-less
// foreign name — the bounds are synthesized from the parsed signature, one
// self-referential bound per callback parameter. They pair with the variables
// `conservative_callback_charge` unions into that name's term: a term carrying
// a variable no bound binds is one the call site cannot resolve, and a bound
// list without its term would send the call site's fast path straight past the
// substitution. Foreign names only — a catalog-declared Gleam function keeps
// its direct calls on the checker's registry auto-injection, which reads the
// argument's shape before it charges anything.
//
// This is therefore the **direct call's** list. A channel that reads a name as
// a *value* — an operator argument, a wired field — wants
// `value_channel_bounds`, which pairs with the term `declared_effects` hands
// that channel; binding a value channel with this list under-charges every
// non-foreign declared name.
pub fn lookup_param_bounds(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> List(types.ParamBound) {
  let declared = line_param_bounds(knowledge_base, name)
  case dict.get(knowledge_base.fallback_summaries, name) {
    Ok(#(_term, fallback_bounds)) -> {
      let #(declared, _rename) = self_referential_declaration(declared)
      list.append(
        fallback_bounds,
        list.filter(declared, fn(bound) {
          !list.contains(fallback_bounds, bound)
        }),
      )
    }
    Error(Nil) ->
      case synthesizes_foreign_share(knowledge_base, name) {
        True -> synthesized_callback_bounds(knowledge_base, name)
        // Inference's own bounds over a body a module-level `assume` speaks
        // over are held out: they bind nothing in the term that declaration
        // put in the body's place, and stating them tells the call site a
        // bound list already answers, which stands its registry injection down
        // and leaves the callback charged to nobody.
        False ->
          case holds_only_inferred_bounds(knowledge_base, name) {
            True -> []
            False -> declared
          }
      }
  }
}

// One self-referential bound per recorded callback parameter — the bound list
// pairing the variables `conservative_callback_charge` synthesizes.
fn synthesized_callback_bounds(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> List(ParamBound) {
  knowledge_base
  |> registry_callback_names(name)
  |> list.map(fn(callback) {
    types.ParamBound(name: callback, effects: types.TVar(callback))
  })
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
    UserAssume -> "your spec's `assume` line"
    ModuleAssumeOrigin(source:) ->
      "a module-level `assume` in " <> describe_source_file(source)
    FieldAssumeOrigin(source:) ->
      "a field `assume` in " <> describe_source_file(source)
    CommittedSpec
    | ProjectInferred
    | DependencySpec(..)
    | PathDependency(..)
    | PathDependencyInferred(..)
    | Catalog(..) -> describe_source_file(origin)
  }
}

// The file a declaration was read from, as the noun phrase that follows "in".
// Shared with the surfaces that name a *kind* of line and the file it sits in.
pub fn describe_source_file(origin: LookupOrigin) -> String {
  case origin {
    UserAssume | CommittedSpec -> "your spec"
    ProjectInferred -> "in-memory inference"
    DependencySpec(package:) -> package <> "'s shipped spec"
    PathDependency(package:) -> "path dependency " <> package
    PathDependencyInferred(package:) ->
      "inference over path dependency " <> package <> "'s source"
    Catalog(package:) -> package <> "'s catalog entry"
    ModuleAssumeOrigin(source:) | FieldAssumeOrigin(source:) ->
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
  // Read from a `where returns` clause on an `effects` line, carrying that
  // line's own bound list — what scopes the clause's variables, since the clause
  // has no bound list of its own. The gate checks its free variables against
  // those bounds and the producer's real callback parameters before binding, so
  // an open clause degrades to `[Unknown]` rather than binding against variables
  // the producer has no parameter for. This is the only summary a bound list
  // means anything for, so it is the only one that carries one.
  Closed(bounds: List(ParamBound))
  // Written by hand as a `where returns` clause: what a foreign producer
  // hands back, declared rather than inferred. It answers for a name every
  // other summary is refused for — that is the whole point of the line — so
  // it is held to `declared_return_standing` instead of to `is_value_opaque`.
  // Closed by its own line's bound list, carried here to scope the clause at
  // the gate and at binding — `declared_returns` is the only place the tag is
  // stamped and it drops any operator with a free variable outside those
  // bound names, which is what makes trusting it sound. The ground case is
  // the empty-bounds instance of the same rule.
  Declared(bounds: List(ParamBound))
}

// A function's returned-operator summary as the knowledge base holds it: the
// operator, how it was produced — with, for a clause, the bounds scoping its
// variables — and the source that wrote it. The three are one value, so a lookup
// can report the summary it used, what its variables answer to, and where it
// came from together.
pub type ReturnedOperator {
  ReturnedOperator(
    operator: EffectTerm,
    summary: SummaryOrigin,
    source: LookupOrigin,
  )
}

// A `where returns` clause as the annotation carries it: the operator and the
// bound list on the same line, which is what scopes the operator's variables.
// The two are read off one line and travel as one value, so no tier has to copy
// the bounds by a rule of its own.
pub type ScopedClause {
  ScopedClause(operator: EffectTerm, bounds: List(ParamBound))
}

// Pair every term of a bare effect map with the source that wrote it, giving
// the shape `all_effects` holds.
fn with_origin(
  entries: Dict(QualifiedName, EffectTerm),
  origin: LookupOrigin,
) -> Dict(QualifiedName, #(EffectTerm, LookupOrigin)) {
  dict.map_values(entries, fn(_name, term) { #(term, origin) })
}

// Pair every clause in a `name -> clause` map with the source that wrote it,
// tagging each `Closed` over the bounds it was read beside, and giving the shape
// `returned_operators` holds.
//
// Guard: never fold a map of clauses on `assume` lines through here. A
// declaration is written for a value-opaque name, and a Closed-tagged summary
// over one is refused at lookup — a new tier folding declarations this way (the
// deferred catalog tier is the one waiting to) silently no-ops instead of
// answering. `declared_returns` is the entry point for those.
fn tag_closed_returns(
  clauses: Dict(QualifiedName, ScopedClause),
  source: LookupOrigin,
) -> Dict(QualifiedName, ReturnedOperator) {
  dict.map_values(clauses, fn(_name, clause) {
    ReturnedOperator(
      operator: clause.operator,
      summary: Closed(bounds: clause.bounds),
      source:,
    )
  })
}

// The same for the one summary no bound list rides: `Fresh`, scoped by the
// params channel's entry for the name.
fn tag_fresh_returns(
  returns: Dict(QualifiedName, EffectTerm),
  source: LookupOrigin,
) -> Dict(QualifiedName, ReturnedOperator) {
  dict.map_values(returns, fn(_name, operator) {
    ReturnedOperator(operator:, summary: Fresh, source:)
  })
}

// Merge **Closed** returned-operator summaries (`where returns` clauses on
// `effects` lines) into a knowledge base — existing entries take priority
// (gap-fill). Used for dependency and committed-project returns.
//
// Guard: this takes clauses on `effects` lines and nothing else. Folding an
// `assume` line's clause through it tags it `Closed`, and a Closed summary over
// the value-opaque name a declaration is written for is refused at lookup, so
// the tier folding them would silently answer nothing. Declarations go through
// `with_declared_returned_operators`.
pub fn with_closed_returned_operators(
  knowledge_base: KnowledgeBase,
  clauses: Dict(QualifiedName, ScopedClause),
  source: LookupOrigin,
) -> KnowledgeBase {
  let merged =
    dict.merge(
      tag_closed_returns(clauses, source),
      knowledge_base.returned_operators,
    )
  KnowledgeBase(..knowledge_base, returned_operators: merged)
}

// Merge **Declared** returned-operator summaries (`where returns` clauses) into
// a knowledge base — the incoming entries win, since a declaration outranks a
// summary inferred over a body and the two merges beside it both gap-fill.
//
// Tier order on this channel is fold order, and the folds run outermost-first:
// a dependency's declarations land while its spec is read, a path dependency's
// when its spec is folded, and the consumer's own last, so a consumer line for
// a dependency's producer is the one that answers. Within one spec, folding the
// declarations ahead of that file's inferred `returns` lines leaves the
// declaration standing.
pub fn with_declared_returned_operators(
  knowledge_base: KnowledgeBase,
  declared: Dict(QualifiedName, ScopedClause),
  source: LookupOrigin,
) -> KnowledgeBase {
  let merged =
    merge_returns(
      knowledge_base.returned_operators,
      declared_returns(declared, source),
    )
  KnowledgeBase(..knowledge_base, returned_operators: merged)
}

// Merge declared summaries that only *fill gaps*: whatever an earlier fold
// already wrote for a name stands, declaration or not.
//
// The path-dependency fold merges this way. Its tier sits below the installed
// dependencies', so a path dep declaring a clause on `dep/ffi.make` for a
// name an installed dependency's own spec already declares must not displace it
// — the inversion of the documented order that `over_catalog` keeps the effects
// channel out of. Within the one spec being folded, this still leaves the
// declaration standing over that file's inferred `returns` line: the
// declarations fold first, and the inferred merge beside them gap-fills too.
fn gap_filling_declared_returns(
  knowledge_base: KnowledgeBase,
  declared: Dict(QualifiedName, ScopedClause),
  source: LookupOrigin,
) -> KnowledgeBase {
  let merged =
    dict.merge(
      declared_returns(declared, source),
      knowledge_base.returned_operators,
    )
  KnowledgeBase(..knowledge_base, returned_operators: merged)
}

// The one precedence rule this channel merges by: an incoming entry wins its
// key, **except** that nothing inferred replaces a declaration.
//
// Tier order on the channel is fold order — the folds run outermost-first, so
// a consumer's line, folded last, is the one that answers. Declared-beats-
// inferred cannot ride on that ordering alone, because it must hold *within* a
// tier as well: installed dependencies are folded in directory order, and a
// stray `returns` line in the second package naming the first package's module
// would otherwise bury the `where returns` clause its author shipped.
fn merge_returns(
  existing: Dict(QualifiedName, ReturnedOperator),
  incoming: Dict(QualifiedName, ReturnedOperator),
) -> Dict(QualifiedName, ReturnedOperator) {
  let winning =
    dict.filter(incoming, fn(name, entry) {
      case entry.summary {
        Declared(..) -> True
        Fresh | Closed(..) ->
          case dict.get(existing, name) {
            Ok(ReturnedOperator(summary: Declared(..), ..)) -> False
            Ok(ReturnedOperator(summary: Fresh, ..))
            | Ok(ReturnedOperator(summary: Closed(..), ..))
            | Error(Nil) -> True
          }
      }
    })
  dict.merge(existing, winning)
}

// Tag declared summaries, dropping every operator its own line's bound list
// does not close — the one place `Declared` is stamped, so the tag means
// closed by construction rather than by the loaders that happen to feed it.
// The ground case is the empty-bounds instance of the same rule.
//
// An operator with a variable outside the line's bound names answers to
// nothing — no parameter binds it and nothing sanitized it — which is the
// substitution a serialized summary is already refused for. Dropping it here
// keeps the checker's unscoped-`Declared` case unreachable, and a new source
// of declarations — a catalog tier, a cache — inherits the rule instead of
// having to restate it. The drop is silent: nothing in this module holds a
// warning channel, and the project's own lines are reported by the spec lint,
// which reads the same `unscoped_clause_variables` base.
fn declared_returns(
  declared: Dict(QualifiedName, ScopedClause),
  source: LookupOrigin,
) -> Dict(QualifiedName, ReturnedOperator) {
  declared
  |> dict.filter(fn(_name, clause) {
    unscoped_clause_variables(clause.operator, clause.bounds) == []
  })
  |> dict.map_values(fn(_name, clause) {
    ReturnedOperator(
      operator: clause.operator,
      summary: Declared(bounds: clause.bounds),
      source:,
    )
  })
}

// The free variables of a declared `where returns` clause that its own line's
// bound list does not scope, sorted — empty exactly when the clause is closed.
// The base closedness oracle for the declared channel: an assumption's clause
// answers to its own line alone, so no registry is consulted and a dotted
// variable is not excused — those are `Closed`-path affordances the checker
// composes on top for clauses on `effects` lines. The loader that stamps
// `Declared`, the checker's admission gate and the spec lint all read this one
// predicate.
pub fn unscoped_clause_variables(
  operator: EffectTerm,
  bounds: List(ParamBound),
) -> List(String) {
  let names = bound_name_set(bounds)
  effect_term.free_vars(operator)
  |> set.filter(fn(variable) { !set.contains(names, variable) })
  |> set.to_list()
  |> list.sort(string.compare)
}

// The names of a bound list's bounds — what a clause's variables are scoped
// against, and what argument matching pairs a call site's values with.
pub fn bound_name_set(bounds: List(ParamBound)) -> Set(String) {
  bounds |> list.map(fn(bound) { bound.name }) |> set.from_list()
}

// The variables a bound list's payloads bind at a call site — what the
// checker's `bind_variables` actually keys substitution off, and the term
// oracle the spec lint weighs a bounded declaration's effects term against.
// For a self-referential bound this is the bound's own name; for a
// hand-written decoupled one (`cb: [e]`) it is the payload's variable, not
// the name. One definition, so the binder and the lint cannot drift.
pub fn bound_payload_variables(bounds: List(ParamBound)) -> Set(String) {
  list.fold(bounds, set.new(), fn(acc, bound) {
    set.union(acc, effect_term.free_vars(bound.effects))
  })
}

// The payload variables of a bound list whose *final* binder is a different
// bound's parameter — the shape whose two binding channels disagree: the
// effects term binds such a variable through the payload that names it, while
// a `where returns` clause binds it by parameter name, so one spelled
// variable can charge two different arguments. Each pair is the variable
// beside the bound whose payload binds it, the last binder winning on a
// duplicate as it does in the checker's binding fold — so a later
// self-referential binding (`other: [cb], cb: [cb]`) clears an earlier
// alias: the channels agree there, and only a variable another parameter's
// payload binds *last* is reported. A dotted variable is a field path, which
// the clause channel never binds by name, so the channels agree on it.
pub fn aliased_bound_variables(
  bounds: List(ParamBound),
) -> List(#(String, String)) {
  let names = bound_name_set(bounds)
  list.fold(bounds, dict.new(), fn(acc, bound) {
    bound.effects
    |> effect_term.free_vars()
    |> set.fold(acc, fn(acc, variable) {
      case variable == bound.name {
        True -> dict.delete(acc, variable)
        False ->
          case
            !string.contains(variable, ".") && set.contains(names, variable)
          {
            True -> dict.insert(acc, variable, bound.name)
            False -> acc
          }
      }
    })
  })
  |> dict.to_list()
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

// Merge **Fresh** returned-operator summaries (produced by this run's inference)
// into a knowledge base — new entries take priority, so a re-inferred summary
// replaces a committed Closed one for the same key. Used for the pre-pass /
// main-loop fresh deltas.
//
// A **Declared** entry is the exception `merge_returns` states: inference
// describes a body, and the line describes what the foreign implementation hands
// back, so the line stands. Fresh inference keys no foreign name in the first
// place and a declaration over an ordinary own function is dropped at load, so
// here the rule is insurance against drift in a chain of invariants that spans
// three files rather than the thing holding the roof up.
pub fn with_fresh_returned_operators(
  knowledge_base: KnowledgeBase,
  inferred: Dict(QualifiedName, EffectTerm),
  source: LookupOrigin,
) -> KnowledgeBase {
  let merged =
    merge_returns(
      knowledge_base.returned_operators,
      tag_fresh_returns(inferred, source),
    )
  KnowledgeBase(..knowledge_base, returned_operators: merged)
}

// Merge a factory map (keyed by `#(module, function)`) into the knowledge
// base, so a let-bound cross-module factory call binds its result's fields.
// Merged rather than replaced, on the same terms as `with_updates`: the
// callers fold installed-dependency source and then the current package's own
// modules, and a later merge wins on a clash.
pub fn with_factories(
  knowledge_base: KnowledgeBase,
  factories: Dict(#(String, String), FactorySignature),
) -> KnowledgeBase {
  KnowledgeBase(
    ..knowledge_base,
    factories: dict.merge(knowledge_base.factories, factories),
  )
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

// Merge a constructor-label map (keyed by `#(module, variant)`) into the
// knowledge base, on the same terms as the builder maps above: derived from
// source at run time, dependency modules first and the current package last.
pub fn with_constructors(
  knowledge_base: KnowledgeBase,
  constructors: Dict(#(String, String), List(Option(String))),
) -> KnowledgeBase {
  KnowledgeBase(
    ..knowledge_base,
    constructors: dict.merge(knowledge_base.constructors, constructors),
  )
}

// The package-wide constructor-label map, for threading into a module's
// extraction context as the constructors other modules define.
pub fn constructors(
  knowledge_base: KnowledgeBase,
) -> Dict(#(String, String), List(Option(String))) {
  knowledge_base.constructors
}

// Look up the operator a function returns, if known, with how it was produced
// (Fix E) and the source that wrote it. `Error(Nil)` when the callee doesn't
// return a (tracked) operator.
//
// A summary inferred over a body answers only for a name no `@external`
// declares, as it always has; a **declared** one answers exactly where it
// stands, which is what a `where returns` clause is written to do.
pub fn lookup_returned_operator(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Result(ReturnedOperator, Nil) {
  use found <- result.try(dict.get(knowledge_base.returned_operators, name))
  case found.summary {
    Declared(..) ->
      case charged_standing(knowledge_base, name, found.source) {
        DeclaredReturnAnswers -> Ok(found)
        DeclaredReturnUnbuilt | DeclaredReturnFallbackRuns | NoDeclaredReturn ->
          Error(Nil)
      }
    Fresh | Closed(..) ->
      case is_value_opaque(knowledge_base, name) {
        True -> Error(Nil)
        False -> Ok(found)
      }
  }
}

// The `where returns` clause a declaration keys for `name`, read without the
// standing that decides whether a caller may trust it. The `check` path reads
// it this way on purpose: where a Gleam fallback body runs beside the
// declaration the standing calls the clause settled, and that is exactly the
// case where the fallback's own returned operator has to be proved beside it.
pub fn declared_returned_operator(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Result(EffectTerm, Nil) {
  use found <- result.try(dict.get(knowledge_base.returned_operators, name))
  case found.summary {
    Declared(..) -> Ok(found.operator)
    Fresh | Closed(..) -> Error(Nil)
  }
}

// Where a declared return stands for one name — read both by the lookup that
// trusts it and by the diagnostic that reports its refusal, so a call and its
// explanation cannot disagree about which gate answered.
pub type DeclaredReturnStanding {
  // In reach, and no Gleam fallback body runs beside it: the declaration is the
  // whole story about what the producer hands back.
  DeclaredReturnAnswers
  // Out of reach: the declaration names targets this build does not compile, so
  // nothing it describes is what runs.
  DeclaredReturnUnbuilt
  // In reach, but a Gleam fallback body runs on some target too, and the
  // closure that body hands back needn't be the foreign one. Only a clause
  // from a non-suppressing origin is refused this way — a written spec's
  // clause is trusted whole (`suppresses_running_fallback` on the clause's
  // own source). No such origin ships clauses today; the arm is the hook a
  // catalog returns tier lands on.
  DeclaredReturnFallbackRuns
  // No `where returns` clause keys the name at all.
  NoDeclaredReturn
}

// How a declared return for `name` stands against what this build compiles.
//
// The effects channel copes with a declaration and a running fallback body by
// unioning them; there is no union of operators, so where a running body's
// closure may stand in for the foreign one, the clause answers only on the
// say-so of a suppressing origin. Standing and fallback are two fields of the
// one `ForeignCharge`, read through `declared_charge` because the returns
// channel holds no declared *effects* term of its own to pass down.
//
// The permissive default underneath is load-bearing: a name no foreign scan
// recorded, a walk carrying no targets, and an `@external` whose declared
// targets cannot be read all reach `DeclarationAndFallback` with no fallback
// term, which answers. Nothing there contradicts the line.
pub fn declared_return_standing(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> DeclaredReturnStanding {
  case dict.get(knowledge_base.returned_operators, name) {
    Error(Nil) -> NoDeclaredReturn
    Ok(ReturnedOperator(summary: Fresh, ..))
    | Ok(ReturnedOperator(summary: Closed(..), ..)) -> NoDeclaredReturn
    Ok(ReturnedOperator(summary: Declared(..), source:, ..)) ->
      charged_standing(knowledge_base, name, source)
  }
}

// The standing of a declaration already known to key `name` — the charge match
// alone, without the triage that established there is one to weigh. The lookup
// reads it having just fetched the entry; the wrapper above adds the fetch for a
// caller holding only the name.
//
// `clause_source` is the `where returns` clause's own origin, not the effects
// declaration's: the two channels can be won by different tiers (a clause-only
// user line beside a catalog effects entry), and the clause is trusted by its
// own author's line. Where a fallback body runs beside the declaration, a
// suppressing clause source answers — the refusal existed because there is no
// union of operators to take, and a trusted line takes none — while any other
// source keeps the refusal.
fn charged_standing(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
  clause_source: LookupOrigin,
) -> DeclaredReturnStanding {
  let charge = declared_charge(knowledge_base, name)
  case charge.declaration, charge.fallback {
    DeclarationCharged, types.NoFallback -> DeclaredReturnAnswers
    DeclarationCharged, types.FallbackCharged(_)
    | DeclarationCharged, types.FallbackSuppressed(_)
    ->
      case suppresses_running_fallback(clause_source) {
        True -> DeclaredReturnAnswers
        False -> DeclaredReturnFallbackRuns
      }
    FallbackAnswersInstead, _ | NothingImplementsName, _ ->
      DeclaredReturnUnbuilt
  }
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

// The installed packages whose `src/` yielded at least one Gleam module — the
// ones `dependency_module_files` could actually read. Told apart from the
// packages a manifest lists so a caller can ask whether the tree it read is the
// whole of what this project depends on, or a partial one whose gaps could hold
// any module.
pub fn packages_with_sources(packages_directory: String) -> Set(String) {
  case simplifile.read_directory(packages_directory) {
    Error(_) -> set.new()
    Ok(packages) ->
      packages
      |> list.filter(fn(package_name) {
        let src_dir = packages_directory <> "/" <> package_name <> "/src"
        !dict.is_empty(source_dir_module_files(src_dir))
      })
      |> set.from_list
  }
}

// The packages the manifest lists, by name. What an installed tree is measured
// against.
pub fn manifest_package_names(manifest_path: String) -> Set(String) {
  manifest_versions(manifest_path) |> dict.keys |> set.from_list
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
// - functions declared `assume <module>.<function>` record the bound list off
//   the declaring line itself: the external term wins in `all_effects`, and a
//   polymorphic one (`assume m/ffi.each(f: [f]) : [f]`) answers to the bounds
//   written beside it. A clause-only bounded line writes no entry here — it
//   decides no term, so a global entry would pair its bounds with a term from
//   a lower tier; its bounds ride the declared summary instead.
//
// Entries for a name a *stale* per-function external also names are the
// project-spec caller's to drop, with the same filter it applies to the
// effects map beside this one.
pub fn load_spec_params_from_file(
  file: types.GradedFile,
) -> Dict(QualifiedName, List(ParamBound)) {
  let from_assumes = assume_bounds(annotation.extract_assumes(file))
  list.fold(annotation.extract_annotations(file), from_assumes, fn(acc, ann) {
    use <- bool.guard(when: ann.kind == Check, return: acc)
    case annotation.split_function_name(ann.function) {
      Ok(#(module, function)) -> {
        let name = QualifiedName(module:, function:)
        // A name a declaring line already keyed answers to that line's bounds.
        case dict.has_key(from_assumes, name) {
          True -> acc
          False -> dict.insert(acc, name, ann.params)
        }
      }
      Error(_) -> acc
    }
  })
}

// The bound list beside each function assume that declares effects, keyed
// by qualified name — a fold over the same selection `split_assumes` folds
// its function tier from, so on a duplicate declaration the winning term and
// the winning bounds come off the same line, never mixed across lines.
fn assume_bounds(
  assumes: List(AssumeAnnotation),
) -> Dict(QualifiedName, List(ParamBound)) {
  list.fold(declaring_function_assumes(assumes), dict.new(), fn(acc, entry) {
    let #(name, _effects, bounds) = entry
    dict.insert(acc, name, bounds)
  })
}

// Everything one dependency's spec file declares. The four `QualifiedName`-keyed
// maps hold the terms, bounds and returned-operator summaries; `type_fields` and
// `assumes` stay lists, since where each lands in the knowledge base is the
// merging caller's decision (`with_type_fields`'s insert order against the
// project spec; `split_assumes`'s two tiers).
//
// The two returns maps are held apart because only one of them is a
// declaration, and the sanitizing below weighs them by exactly that.
//
// `modules` is the package's own module paths, read off the `src/` tree beside
// the spec: what the sanitizing below measures a line's *subject* against, so a
// spec cannot state a returned-operator summary about code it does not ship.
// Empty where that tree could not be read, which the filter reads as "nothing to
// arbitrate with" rather than as "the package owns nothing".
pub type DepSpec {
  DepSpec(
    effects: Dict(QualifiedName, EffectTerm),
    params: Dict(QualifiedName, List(ParamBound)),
    // `where returns` clauses on the spec's `effects` lines, each with the
    // bound list scoping it.
    returns: Dict(QualifiedName, ScopedClause),
    // `where returns` clauses on the spec's `assume` lines, each scoped by
    // that line's own bound list.
    declared_returns: Dict(QualifiedName, ScopedClause),
    type_fields: List(FieldAnnotation),
    assumes: List(AssumeAnnotation),
    modules: Set(String),
  )
}

// Load one package's spec. Reads the spec via the package's own `[tools.graded]`
// config (defaulting to `<package_name>.graded`) at `dep_root`, once. Empty when
// the spec is missing, and empty with a printed warning when it does not
// parse — a consumer cannot fix a dependency's spec, so the package falls back
// to the tiers below it instead of stopping the run. Shared by the `build/packages` dependency
// scan and path-dependency enrichment so both dep kinds load identical metadata —
// effects alone would drop the bounds a higher-order callee needs to discharge
// its callback's effect, the `type` fields a capability record on the dep's own
// types needs to resolve at a consumer's call site, or the `assume`
// lines the dep author wrote for its FFI.
pub fn load_dep_spec(dep_root: String, package_name: String) -> DepSpec {
  case read_spec_file(config.spec_file_for(dep_root, package_name)) {
    Error(reason) -> {
      case reason {
        SpecMissing -> Nil
        SpecMalformed(cause) ->
          io.println_error(
            "graded: warning: "
            <> package_name
            <> "'s spec did not parse (line "
            // Named by the line alone. A dependency's spec is not the
            // consumer's to rewrite, and the rewrite hint a retired spelling
            // carries is a second line, which would leave this sentence's tail
            // dangling after it.
            <> annotation.describe_parse_error_line(cause)
            <> "); its entries are ignored",
          )
      }
      DepSpec(dict.new(), dict.new(), dict.new(), dict.new(), [], [], set.new())
    }
    Ok(file) -> {
      let declared_modules = annotation.module_assume_modules(file)
      // Loaded through the same two readers a package uses for its *own* spec,
      // so a dependency's `check` budgets and externally-declared functions are
      // scoped identically one package boundary away: a `check` line's bounds
      // stay local to that check instead of becoming a global fact about the
      // dependency's function, and every term still travels with the bounds
      // from its own annotation.
      DepSpec(
        // The module-level declarations govern their own module's effects
        // channel, so the spec's `effects` lines for it are dropped rather than
        // left to outrank the declaration per-function-beats-module-level. Only
        // that channel: `infer` keeps such a line when it carries a
        // `where returns` clause, which is the clause's only home, and the
        // clause is read from `returns` below, carrying its own scoping bounds.
        effects: load_spec_effects_from_file(file)
          |> drop_module_declared(declared_modules),
        // A dependency's per-function external is never stale by this rule: its
        // own body is the documented case for the line.
        //
        // Bounds travel with their term, so both channels drop the same names:
        // a surviving term paired with bounds from another annotation is a
        // pairing no annotation wrote.
        params: load_spec_params_from_file(file)
          |> drop_module_declared(declared_modules),
        returns: load_spec_returns_from_file(file),
        declared_returns: load_spec_assume_returns_from_file(file),
        type_fields: annotation.extract_type_fields(file),
        assumes: annotation.extract_assumes(file),
        modules: package_modules(dep_root),
      )
    }
  }
}

// Drop every `QualifiedName`-keyed entry whose module a module-level
// `assume <module> : [...]` declares. Read by both sides of the package
// boundary — a dependency's spec as it loads here, and a consumer's own spec and
// inference in `graded.gleam` — so a declaration means the same thing wherever
// it is read. The caller supplies the declared modules, since only it knows
// whose declarations the entries are being weighed against.
pub fn drop_module_declared(
  entries: Dict(QualifiedName, a),
  modules: Set(String),
) -> Dict(QualifiedName, a) {
  use <- bool.guard(when: set.is_empty(modules), return: entries)
  dict.filter(entries, fn(name, _value) { !set.contains(modules, name.module) })
}

// The module paths a package ships, read off its `src/` tree.
fn package_modules(dep_root: String) -> Set(String) {
  source_dir_module_files(filepath.join(dep_root, "src"))
  |> dict.keys
  |> set.from_list
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
// is the declaration: the dep's own `assume` line, an
// `where returns` clause, a module-level external, or the catalog entry
// underneath.
//
// `declared_returns` is therefore not weighed against the dep's own foreign
// scan. The line is the dep author's declaration of what their producer hands
// back, and arbitrating it against their own source is their `infer`'s job, not
// their consumer's — the same reading that keeps their `assume` line
// for a Gleam-bodied function of their own.
//
// Both returns maps are weighed against a second question, which the effects
// channel has no analogue of: whose code the line is *about*. A spec may state a
// returned-operator summary for a module it ships or for a name the foreign scan
// records, and for nothing else. Without that, a dependency shipping
// a clause on `app.helper` — an ordinary Gleam function of the *consumer* —
// lands a declaration in the tier above the consumer's own body-derived summary,
// and the consumer's source stops being what its own callers are charged for.
// A package whose `src/` tree could not be read arbitrates nothing here.
//
// A term and its bounds are dropped together. `load_knowledge_base` merges terms
// and bounds in two independent passes, so a term dropped without its bounds
// would revive the catalog's term paired with the dependency's bounds — the
// pairing `load_spec_params_from_file` documents, broken.
fn sanitize_dep_spec(
  dep: DepSpec,
  foreign: Dict(QualifiedName, types.ForeignFunction),
) -> DepSpec {
  // Only a line that states effects declares them. A clause-only
  // `assume dep/ffi.make where returns : [X]` claims nothing about the
  // function's own effect, so the dep's `effects` line for that name is still
  // inference over an `@external` fallback body and still drops.
  let declared =
    list.fold(dep.assumes, set.new(), fn(acc, assume) {
      case annotation.assume_qualified_name(assume), assume.effects {
        Ok(qualified), Some(_) -> set.insert(acc, qualified)
        _, _ -> acc
      }
    })
  let inferred_over_foreign = fn(name) {
    dict.has_key(foreign, name) && !set.contains(declared, name)
  }
  let about_other_code = fn(name: QualifiedName) {
    !set.is_empty(dep.modules)
    && !set.contains(dep.modules, name.module)
    && !dict.has_key(foreign, name)
  }
  DepSpec(
    ..dep,
    effects: dict.filter(dep.effects, fn(name, _term) {
      !inferred_over_foreign(name)
    }),
    params: dict.filter(dep.params, fn(name, _bounds) {
      !inferred_over_foreign(name)
    }),
    returns: dict.filter(dep.returns, fn(name, _clause) {
      !dict.has_key(foreign, name) && !about_other_code(name)
    }),
    declared_returns: dict.filter(dep.declared_returns, fn(name, _operator) {
      !about_other_code(name)
    }),
  )
}

// The entries one dependency spec decides, each tagged with the source that
// shipped it: the function-keyed terms for `all_effects` and the module-keyed
// ones for the `module_effects` fallback tier.
//
// A function's `assume` line wins over an `effects` line for the same
// name. `graded infer` writes no `effects` line for an externally-declared
// function unless the line carries a `where returns` clause, so a spec carrying
// both without one has a stale line, and either way only the external's term
// pairs with the bounds `load_spec_params_from_file` records off that same
// line: where the `effects` line is kept for a clause, that clause carries its
// own scoping bounds on the returns channel.
fn decided_entries(dep: DepSpec, origin: LookupOrigin) -> AssumeTiers {
  let #(function_assumes, module_assumes) = split_assumes(dep.assumes, origin)
  #(
    dict.merge(with_origin(dep.effects, origin), function_assumes),
    module_assumes,
  )
}

// Fold everything a path dependency's spec declares — terms, bounds, externals,
// returned-operator summaries and field `assume` lines — into the knowledge base under
// the documented resolution order: below per-function user externals and the
// project's own entries, above the catalog. An existing entry is overridden only
// when its origin is the catalog, so a consumer's own declarations survive a
// merge that runs after the catalog is already loaded, and a term this merge
// decides brings its own bounds entry with it. The summaries merge as `Closed`:
// a committed clause is read back, not inferred this run.
//
// A consumer's *module-level* external stays in the `module_effects` fallback
// tier, which `lookup` consults only after `all_effects` misses, so these
// function-keyed entries outrank it — the per-function-beats-module-level rule.
//
// The spec's `where returns` declarations fold ahead of its inferred
// `returns` lines, so a name both key resolves to the declaration. Both merges
// gap-fill: this tier reads below the installed dependencies', so a name an
// installed dep's spec already answered keeps that answer, declaration or not.
pub fn with_path_dep_spec(
  knowledge_base: KnowledgeBase,
  dep: DepSpec,
  origin: LookupOrigin,
) -> KnowledgeBase {
  // Sanitized against the path dependency's own source, scanned into
  // `dependency_foreign` before this fold — a committed spec is as capable of
  // carrying a stale line for its own `@external` as an installed one is.
  let dep = sanitize_dep_spec(dep, knowledge_base.dependency_foreign)
  let #(decided, module_assumes) = decided_entries(dep, origin)
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
      over_catalog(knowledge_base.module_effects, module_assumes),
    ),
  )
  |> gap_filling_declared_returns(dep.declared_returns, origin)
  |> with_closed_returned_operators(dep.returns, origin)
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
    ModuleAssumeOrigin(source:) | FieldAssumeOrigin(source:) ->
      is_catalog_origin(source)
    UserAssume
    | CommittedSpec
    | ProjectInferred
    | DependencySpec(..)
    | PathDependency(..)
    | PathDependencyInferred(..) -> False
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
  use file <- result.try(read_spec_file(spec_path) |> result.replace_error(Nil))
  Ok(annotation.extract_annotations(file))
}

// Why a spec file yielded no lines: it wasn't there, or it did not parse. The
// caller tells a consumer which one happened for a *dependency's* spec, whose
// lines the consumer cannot fix.
pub type SpecReadError {
  SpecMissing
  SpecMalformed(cause: annotation.ParseError)
}

fn read_spec_file(
  spec_path: String,
) -> Result(types.GradedFile, SpecReadError) {
  use content <- result.try(
    simplifile.read(spec_path) |> result.replace_error(SpecMissing),
  )
  annotation.parse_file(content) |> result.map_error(SpecMalformed)
}

// Build a clause map (qualified name → operator and the bounds scoping it) from
// the `where returns` clauses on a parsed spec's `effects` lines, and those
// only. A `check` line's clause keys nothing — it asserts what a function
// returns rather than declaring it — and an `assume` line's goes through
// `load_spec_assume_returns_from_file` instead.
//
// The line's own bound list travels with the clause it scopes: the clause has
// no bound list of its own, and read apart from that list its variables answer
// to nothing.
pub fn load_spec_returns_from_file(
  file: types.GradedFile,
) -> Dict(QualifiedName, ScopedClause) {
  annotation.extract_effects(file)
  |> list.filter_map(fn(ann) {
    ann.returns
    |> option.to_result(Nil)
    |> result.map(fn(op) {
      #(ann.function, ScopedClause(operator: op, bounds: ann.params))
    })
  })
  |> fold_named_returns()
}

// The declared map: the `where returns` clauses on `assume` lines, each
// paired with its own line's bound list — what scopes the clause's variables.
// A clause on a module path keys nothing — a returns declaration is
// per-function, and a name that resolves nowhere would otherwise sit in the
// file looking effective. The closed-by-own-bounds rule is applied where the
// summaries are tagged, in `declared_returns`.
pub fn load_spec_assume_returns_from_file(
  file: types.GradedFile,
) -> Dict(QualifiedName, ScopedClause) {
  annotation.assume_returns(file)
  |> list.filter_map(fn(entry) {
    let #(assume, operator) = entry
    annotation.assume_qualified_name(assume)
    |> result.map(fn(qualified) {
      #(qualified, ScopedClause(operator:, bounds: assume.params))
    })
  })
  |> dict.from_list()
}

// Key a list of `#(spec name, clause)` pairs by qualified name, dropping the
// names that don't split into a module and a function.
fn fold_named_returns(
  entries: List(#(String, ScopedClause)),
) -> Dict(QualifiedName, ScopedClause) {
  list.fold(entries, dict.new(), fn(acc, entry) {
    let #(name, clause) = entry
    case annotation.split_function_name(name) {
      Ok(#(module, function)) ->
        dict.insert(acc, QualifiedName(module:, function:), clause)
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
    type_fields: List(#(FieldAnnotation, LookupOrigin)),
    module_effects: Dict(String, #(EffectTerm, LookupOrigin)),
  )
}

// For each installed package, locate its spec file via the package's own
// `[tools.graded]` config (defaulting to `<package_name>.graded`), then read
// and parse it *once*, folding its qualified `effects`/`check` annotations
// into the global effect/param maps, its `returns` lines into the
// returned-operator map, its `type` field lines into a flat list, and its
// `assume` lines into the function and module tiers. Packages
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
      let #(decided, module_assumes) = decided_entries(dep, origin)
      Dependencies(
        effects: dict.merge(acc.effects, decided),
        params: dict.merge(acc.params, dep.params),
        returns: merge_returns(
          acc.returns,
          // Within one spec a declared summary answers for a name its own
          // `returns` line also keys: the incoming argument wins. Across the
          // specs, the same rule keeps one package's stray `returns` line from
          // burying another's declaration for the same name.
          merge_returns(
            tag_closed_returns(dep.returns, origin),
            declared_returns(dep.declared_returns, origin),
          ),
        ),
        type_fields: list.append(
          acc.type_fields,
          list.map(dep.type_fields, fn(field) { #(field, origin) }),
        ),
        module_effects: dict.merge(acc.module_effects, module_assumes),
      )
    },
  )
}

// Catalog
//
// The bundled priv/catalog of versioned .graded files: locating the
// directory, selecting the best version per installed package against the
// manifest, and folding the selected files into effect maps.

// The resolved bundled-catalog directory for a caller that reads the catalog
// alongside everything else it resolves against. When no candidate exists, warn
// and return the cwd-relative default — an empty catalog collapses every
// catalogued call to `[Unknown]`, so the degradation is surfaced instead of
// silent.
pub fn catalog_directory() -> String {
  case find_catalog_directory() {
    Ok(directory) -> directory
    Error(_candidates) -> {
      io.println_error(
        "graded: warning: catalog directory not found; catalogued calls will resolve to [Unknown]",
      )
      "priv/catalog"
    }
  }
}

// Resolve graded's bundled `priv/catalog`, or return the candidate paths tried.
// The install location (via `code:priv_dir`) is tried first so the catalog is
// found regardless of the process's working directory; the cwd-relative layouts
// follow as a fallback. A caller for which the catalog directory is the subject
// reports the candidates rather than reading a path that was never a catalog.
pub fn find_catalog_directory() -> Result(String, List(String)) {
  let cwd_relative = ["build/packages/graded/priv/catalog", "priv/catalog"]
  // The install-location candidate (anchored on graded's own priv) is tried
  // ahead of the cwd-relative ones; absent when the priv directory can't be
  // located.
  let candidates = case priv_directory() {
    Ok(priv) -> [filepath.join(priv, "catalog"), ..cwd_relative]
    Error(Nil) -> cwd_relative
  }
  list.find(candidates, is_existing_directory)
  |> result.replace_error(candidates)
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
    assume_effects: Dict(QualifiedName, #(EffectTerm, LookupOrigin)),
    module_effects: Dict(String, #(EffectTerm, LookupOrigin)),
    poly_effects: Dict(QualifiedName, #(EffectTerm, LookupOrigin)),
    // The bounds of each tier, held apart and merged the way the terms beside
    // them are: a name's term and its bounds must come out of one file, or a
    // polymorphic term wins with another file's empty bounds beside it and its
    // variable is left with nothing to bind it.
    assume_params: Dict(QualifiedName, List(ParamBound)),
    poly_params: Dict(QualifiedName, List(ParamBound)),
    type_fields: List(#(FieldAnnotation, LookupOrigin)),
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
  List(#(FieldAnnotation, LookupOrigin)),
) {
  let installed_versions = manifest_versions(manifest_path)
  let catalog_files = bundled_catalog_files(catalog_dir) |> result.unwrap([])
  let selected = resolve_catalog_files(catalog_files, installed_versions)
  let initial =
    CatalogAcc(dict.new(), dict.new(), dict.new(), dict.new(), dict.new(), [])
  let acc = list.fold(selected, initial, fold_catalog_file)
  // Across files, an `effects` annotation takes precedence over another
  // package's per-function `assume` marker; within one file the
  // external already won, in `fold_catalog_file`. Each term carries the package
  // that wrote it, so the winner of this merge brings its own origin. The
  // bounds are merged by the same rule and in the same order, so the file whose
  // term wins a name is the file whose bounds pair with it.
  #(
    dict.merge(acc.assume_effects, acc.poly_effects),
    acc.module_effects,
    dict.merge(acc.assume_params, acc.poly_params),
    acc.type_fields,
  )
}

// Fold one selected catalog file — its package name and path — into the
// accumulator. `assume` lines feed module-level pure markers and
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
          let assumes = annotation.extract_assumes(graded_file)
          let #(function_assumes, module_assumes) =
            split_assumes(assumes, origin)
          // Same two readers as a package's own spec and as `load_dep_spec`, so
          // a catalog entry's `check` budgets and externally-declared functions
          // are scoped like everyone else's. Merging with the new file second
          // keeps the later file winning on a clash, as folding per-annotation
          // did.
          // A name this file keys both ways resolves to its `external
          // effects` line, the rule `decided_entries` applies to a dependency's
          // own spec: dropped from the polymorphic tier here, it keeps the
          // external's term and the bounds the external tier records off the
          // same line.
          let file_poly_effects =
            load_spec_effects_from_file(graded_file)
            |> dict.filter(fn(name, _term) {
              !dict.has_key(function_assumes, name)
            })
            |> with_origin(origin)
          CatalogAcc(
            assume_effects: dict.merge(acc.assume_effects, function_assumes),
            module_effects: dict.merge(acc.module_effects, module_assumes),
            poly_effects: dict.merge(acc.poly_effects, file_poly_effects),
            // An external's bounds come off its own line — empty for the
            // common ground declaration, and the written list for a
            // polymorphic one — keyed by the same last-wins fold as the term,
            // so the line whose term wins a name is the line whose bounds
            // pair with it.
            assume_params: dict.merge(acc.assume_params, assume_bounds(assumes)),
            poly_params: dict.merge(
              acc.poly_params,
              // A catalog entry describes a package graded has no source for,
              // so none of its externals can be stale by the visible-body rule.
              // Kept only for the names whose term this file supplies, so the
              // two travel together through both merges.
              load_spec_params_from_file(graded_file)
                |> dict.filter(fn(name, _bounds) {
                  dict.has_key(file_poly_effects, name)
                }),
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

// One bundled catalog file, as its `{package}@{version}.graded` name reads. The
// raw `version` string is what a caller prints; `parsed` is the
// `major.minor.patch` prefix `parse_semver` reads off it, which selection and
// sorting compare and which drops any pre-release or build suffix
// (`1.2.0-rc.1` parses to `#(1, 2, 0)`).
pub type CatalogFile {
  CatalogFile(
    package: String,
    version: String,
    parsed: #(Int, Int, Int),
    path: String,
  )
}

// Every `{package}@{version}.graded` file under `catalog_dir`, in directory
// order. A file whose name carries no `@`, or more than one, names no package
// and version and is skipped. The read error is returned rather than folded
// into an empty list, so a caller for which the directory is the subject can
// tell "no catalog there" from "nothing bundled".
pub fn bundled_catalog_files(
  catalog_dir: String,
) -> Result(List(CatalogFile), simplifile.FileError) {
  use paths <- result.map(simplifile.get_files(catalog_dir))
  paths
  |> list.filter(fn(path) { string.ends_with(path, ".graded") })
  |> list.filter_map(fn(path) {
    let name = path |> filepath.base_name |> filepath.strip_extension
    case string.split(name, "@") {
      [package, version] ->
        Ok(CatalogFile(package:, version:, parsed: parse_semver(version), path:))
      _ -> Error(Nil)
    }
  })
}

// Which rule chose a package's catalog file. Both variants carry it as `file`,
// so a caller that only wants the file reads that field and ignores the rule.
pub type CatalogSelection {
  // A bundled version at or below the installed one, the highest such.
  Selected(file: CatalogFile)
  // Nothing bundled sits at or below the installed version, so the highest
  // bundled one stands in.
  HighestBundled(file: CatalogFile)
}

// The file `package` resolves to for its `installed` version, and which of the
// two rules chose it. Two files whose versions parse alike are ordered by path,
// so every caller reaches the same file whatever order it holds the catalog in.
pub fn select_catalog_file(
  files: List(CatalogFile),
  package: String,
  installed: String,
) -> Result(CatalogSelection, Nil) {
  use pick <- result.map(
    files
    |> list.filter(fn(file) { file.package == package })
    |> list.sort(fn(left, right) {
      compare_semver(left.parsed, right.parsed)
      |> order.break_tie(string.compare(left.path, right.path))
    })
    |> list.map(fn(file) { #(file.parsed, file) })
    |> pick_best_version(parse_semver(installed)),
  )
  case pick {
    AtOrBelowInstalled(file) -> Selected(file)
    HighestAvailable(file) -> HighestBundled(file)
  }
}

// The file each installed package resolves to, as `#(package, path)`: the
// package name the catalog's `{package}@{version}.graded` file name carries,
// which the fold records as the origin of that file's entries. An installed
// package the catalog does not bundle selects nothing.
fn resolve_catalog_files(
  catalog_files: List(CatalogFile),
  installed_versions: Dict(String, String),
) -> List(#(String, String)) {
  dict.fold(installed_versions, [], fn(selected, package, installed) {
    case select_catalog_file(catalog_files, package, installed) {
      Ok(selection) -> [#(package, selection.file.path), ..selected]
      Error(Nil) -> selected
    }
  })
}

// Which of the two rules picked a version, carrying what it picked. A caller
// that renders the pick reads the rule off this rather than re-deriving it, so
// the two cannot disagree.
pub type VersionPick(a) {
  // The highest version at or below the installed one.
  AtOrBelowInstalled(value: a)
  // Nothing sits at or below the installed version, so the highest available
  // one stands in.
  HighestAvailable(value: a)
}

pub fn pick_best_version(
  versions: List(#(#(Int, Int, Int), a)),
  installed: #(Int, Int, Int),
) -> Result(VersionPick(a), Nil) {
  let eligible =
    list.filter(versions, fn(version) { semver_lte(version.0, installed) })
    |> list.sort(fn(left, right) { compare_semver(right.0, left.0) })
  case eligible {
    [best, ..] -> Ok(AtOrBelowInstalled(best.1))
    [] ->
      case
        list.sort(versions, fn(left, right) { compare_semver(right.0, left.0) })
      {
        [best, ..] -> Ok(HighestAvailable(best.1))
        [] -> Error(Nil)
      }
  }
}

// Parse a version string into the comparable `major.minor.patch` tuple it
// starts with. A pre-release or build suffix is dropped before the components
// are read, so `1.2.0-rc.1` and `1.2.0+build.5` both read as `#(1, 2, 0)`. A
// version that names no numeric components reads as `#(0, 0, 0)`.
pub fn parse_semver(version: String) -> #(Int, Int, Int) {
  case string.split(version_core(version), ".") {
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

// The `major.minor.patch` prefix of a version: everything before the first `-`
// or `+`, which start the pre-release and build suffixes semver orders
// separately.
fn version_core(version: String) -> String {
  version |> take_before("-") |> take_before("+")
}

fn take_before(text: String, marker: String) -> String {
  case string.split_once(text, marker) {
    Ok(#(prefix, _rest)) -> prefix
    Error(Nil) -> text
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

// The installed version of each package `manifest_path` lists. An unreadable
// or malformed manifest yields an empty dict, which reads as a project with no
// dependencies installed; a caller for which the manifest is the subject calls
// `read_manifest_versions` and tells the two apart.
pub fn manifest_versions(manifest_path: String) -> Dict(String, String) {
  read_manifest_versions(manifest_path) |> result.unwrap(dict.new())
}

// The installed version of each package `manifest_path` lists, or `Error(Nil)`
// where there is no manifest to read or its TOML does not parse.
pub fn read_manifest_versions(
  manifest_path: String,
) -> Result(Dict(String, String), Nil) {
  use content <- result.try(
    simplifile.read(manifest_path) |> result.map_error(fn(_) { Nil }),
  )
  use toml <- result.try(tom.parse(content) |> result.map_error(fn(_) { Nil }))
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
