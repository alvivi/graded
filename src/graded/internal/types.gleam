import glance.{type Span, type Statement}
import gleam/dict.{type Dict}
import gleam/option.{type Option}
import gleam/set.{type Set}
import gleam/string

// Names
//
// Qualified function names and the lexical rule that classifies identifiers,
// shared by every stage of the pipeline.

// A fully qualified function name: module path + function name.
pub type QualifiedName {
  QualifiedName(module: String, function: String)
}

// A qualified name written the way a spec line and a diagnostic write it. The
// one place the dot is put in, so a name reads the same wherever it is printed
// or keyed. An unqualified name — a sentinel, a same-module local — is its
// function alone rather than a leading dot.
pub fn dotted_name(name: QualifiedName) -> String {
  case name.module {
    "" -> name.function
    module -> module <> "." <> name.function
  }
}

// Compilation targets
//
// The targets a Gleam package is analysed on. Two readings of them, because one
// of the two sources they come from is an assumption rather than a statement.

// Every target a Gleam package can be compiled for. The widest reading, which
// charges a declaration and its running fallback body alike rather than
// deciding either away.
pub fn every_target() -> Set(String) {
  set.from_list(["erlang", "javascript"])
}

// The target the Gleam compiler builds when nothing says otherwise.
pub fn default_target() -> Set(String) {
  set.from_list(["erlang"])
}

// Where the targets a package is analysed on came from.
//
// `gleam.toml`'s `target` field is optional, and a package that leaves it out is
// still compiled for whatever `--target` the build passes — a flag graded never
// sees. So the two readings below come apart for such a package, and a decision
// reads whichever one it cannot be wrong about.
pub type PackageTargets {
  // Targets `gleam.toml` names, in `target` or `[tools.graded].targets`, and
  // every target where there is no `gleam.toml` to name any. Both readings are
  // this set.
  NamedTargets(targets: Set(String))
  // No field names a target.
  DefaultedTargets
}

// Every target under both readings. What a package graded holds no `gleam.toml`
// for is analysed on: no field is absent there for the compiler's default to
// stand in for, so nothing is assumed and nothing is narrowed.
pub fn all_targets() -> PackageTargets {
  NamedTargets(every_target())
}

// The targets a build compiles: what the package names, or the compiler's
// default where it names none. Read by decisions that only ever *add* to a
// charge — whether a Gleam fallback body runs beside a declaration, which
// unioned it — so an assumption too narrow costs precision and nothing else.
pub fn build_targets(targets: PackageTargets) -> Set(String) {
  case targets {
    NamedTargets(targets:) -> targets
    DefaultedTargets -> default_target()
  }
}

// The targets a declaration is read on: every target where the package names
// none. Read by decisions that can *drop* what a declaration states — a
// `@external` reclassified as ordinary Gleam, a spec line called stale, a
// foreign half left out of a charge — so an assumption never loses a declared
// effect the build performs.
pub fn declaration_targets(targets: PackageTargets) -> Set(String) {
  case targets {
    NamedTargets(targets:) -> targets
    DefaultedTargets -> every_target()
  }
}

// Whether a name's first character is an uppercase letter. This single
// lexical rule distinguishes effect labels from effect variables and record
// constructors from ordinary functions — the comparison against both cases
// excludes non-cased graphemes (digits, symbols) that compare equal to
// themselves under both `uppercase` and `lowercase`.
pub fn is_upper_initial(name: String) -> Bool {
  case string.first(name) {
    Ok(first) ->
      first == string.uppercase(first) && first != string.lowercase(first)
    Error(Nil) -> False
  }
}

// Effect sets
//
// The ground effect representation — sets of string labels ordered by subset
// inclusion — and its lattice operations.

// The label every unresolvable path collapses to. Minted by
// `effect_term.unknown` and by the stuck-term collapse in
// `effect_term.to_effect_set`.
pub const unknown_label = "Unknown"

// An effect set: either a concrete set of named effects, the universal
// wildcard [_], or a polymorphic set with effect variables.
//
// Effect variables (lowercase identifiers like `e`, `e1`) represent
// "whatever effects the corresponding callback has". They are bound at
// call sites by argument-to-parameter matching and substituted away.
pub type EffectSet {
  // [_] — the universal set, top element of the effect lattice.
  // Declaring [_] means "any effects are permitted here".
  Wildcard
  // A concrete set of named effects, e.g. [Http, Stdout] or [].
  Specific(set: Set(String))
  // A polymorphic set mixing concrete labels with effect variables,
  // e.g. [e] or [Stdout, e]. Variables are resolved by substitution
  // at call sites.
  Polymorphic(labels: Set(String), variables: Set(String))
}

// True iff `actual` is a subset of `declared` in the effect lattice.
// Wildcard as declared always passes; Wildcard as actual against a
// finite declared set always fails. Polymorphic sets are conservatively
// handled: as `actual`, any unresolved variables fail the subset check
// (substitution should happen before comparison); as `declared`,
// variables are treated as open slots that accept anything.
pub fn is_subset(actual: EffectSet, declared: EffectSet) -> Bool {
  case declared, actual {
    Wildcard, _ -> True
    _, Wildcard -> False
    Polymorphic(d_labels, _), Specific(a) -> set.is_subset(a, of: d_labels)
    Polymorphic(d_labels, d_vars), Polymorphic(a_labels, a_vars) ->
      set.is_subset(a_labels, of: d_labels) && set.is_subset(a_vars, of: d_vars)
    Specific(d), Specific(a) -> set.is_subset(a, of: d)
    // Polymorphic with unresolved variables cannot be verified against
    // a finite concrete set. Return False conservatively.
    Specific(_), Polymorphic(_, _) -> False
  }
}

// Union of two effect sets. Wildcard absorbs everything. Polymorphic
// sets merge labels and variables component-wise.
pub fn union(a: EffectSet, b: EffectSet) -> EffectSet {
  case a, b {
    Wildcard, _ -> Wildcard
    _, Wildcard -> Wildcard
    Specific(x), Specific(y) -> Specific(set.union(x, y))
    Polymorphic(l1, v1), Polymorphic(l2, v2) ->
      Polymorphic(set.union(l1, l2), set.union(v1, v2))
    Specific(x), Polymorphic(l, v) -> Polymorphic(set.union(x, l), v)
    Polymorphic(l, v), Specific(x) -> Polymorphic(set.union(l, x), v)
  }
}

// The empty (pure) effect set.
pub fn empty() -> EffectSet {
  Specific(set.new())
}

// Construct a Specific effect set from a list of label strings.
pub fn from_labels(labels: List(String)) -> EffectSet {
  Specific(set.from_list(labels))
}

// True iff this effect set contains unresolved effect variables.
pub fn has_variables(effect_set: EffectSet) -> Bool {
  case effect_set {
    Polymorphic(_, variables) -> !set.is_empty(variables)
    _ -> False
  }
}

// True iff this effect set carries the `Unknown` label — some part of it came
// from a path graded could not resolve. `Wildcard` is a declared permission
// rather than an unresolved effect, so it is False.
pub fn contains_unknown(effect_set: EffectSet) -> Bool {
  case effect_set {
    Wildcard -> False
    Specific(labels) -> set.contains(labels, unknown_label)
    Polymorphic(labels, _) -> set.contains(labels, unknown_label)
  }
}

// True iff this effect set is exactly `[Unknown]` and nothing else: the whole
// of it came from a path graded could not resolve, so it names no effect a
// reader could act on. Distinct from `contains_unknown`, which holds of a mixed
// `[Disk, Unknown]` — there the known half is a real effect.
pub fn is_wholly_unknown(effect_set: EffectSet) -> Bool {
  case effect_set {
    Wildcard | Polymorphic(_, _) -> False
    Specific(labels) -> labels == set.from_list([unknown_label])
  }
}

// Effect terms
//
// The lambda-calculus-with-union form of effects, whose ground normal form is
// an `EffectSet`; it carries the second-order polymorphism `EffectSet` can't.

// A richer effect representation: a small lambda-calculus-with-union over
// effects. `EffectSet` is its ground normal form — anything an `EffectSet`
// can express, a variable-free, application-free `EffectTerm` can too.
//
// Effect variables come in two kinds, kept implicit in structure:
//   - `Eff`       — a flat effect (a bare `TVar`, e.g. `e`)
//   - `Eff -> Eff` — an effect *operator* (a `TAbs`, used under `TApp`,
//                    e.g. a higher-order parameter `action`)
//
// This is what lets graded express *second-order* effect polymorphism: an
// effect variable that is itself parameterized by a callback. See
// docs/second-order-effects.md.
pub type EffectTerm {
  // Ground labels. `TLabels(∅)` is pure. Kind `Eff`.
  TLabels(labels: Set(String))
  // The wildcard `[_]`, absorbing under union. Kind `Eff`.
  TTop
  // A free effect variable. Kind `Eff` when bare.
  TVar(name: String)
  // Operator application: `operator` applied to `argument`, e.g.
  // `action(Stdout)`. Stuck (left symbolic) when `operator` is an unresolved
  // variable. Kind `Eff`.
  TApp(operator: EffectTerm, argument: EffectTerm)
  // An effect operator `λparam. body` — a higher-order parameter's latent
  // effect as a function of its callback. Kind `Eff -> Eff`.
  TAbs(param: String, body: EffectTerm)
  // Composition of effects (set union). Kind `Eff`.
  TUnion(terms: List(EffectTerm))
}

// Annotations
//
// Every annotation kind a .graded file can carry, their resolved forms in the
// knowledge base, and the line-preserving file structure they round-trip
// through.

// Distinguishes auto-inferred annotations from enforced invariants.
pub type AnnotationKind {
  // Auto-generated by `graded infer`. Not enforced.
  Effects
  // Hand-written invariant. Violations break the build.
  Check
}

// An effect bound on a function-typed parameter. The `effects` is an
// `EffectTerm`: a flat `Eff` term for a first-order callback (`f: [e]`), or
// an operator `TAbs` for a higher-order one (`action: fn(cb) -> [cb]`).
//
// `name` is the bare parameter name (`f`) for a parameter bound, or a
// `param.field` path (`handler.on_click`) for a *field bound* — a hand-written
// declaration of a record field's effect at the function boundary, the
// boundary-scoped counterpart to a field `assume` line. A field bound's path carries a
// dot; a parameter name never can, so the two forms don't collide.
pub type ParamBound {
  ParamBound(name: String, effects: EffectTerm)
}

// An effect annotation from a .graded sidecar file. `effects` is an
// `EffectTerm` — for the common first-order case a variable-free or flat-
// variable term equivalent to an `EffectSet`, but it may carry operator
// applications (`[action(Stdout)]`) for second-order signatures.
// `returns` carries the `where returns` clause: the operator the function hands
// back, scoped by this line's own bound list.
pub type EffectAnnotation {
  EffectAnnotation(
    kind: AnnotationKind,
    function: String,
    params: List(ParamBound),
    effects: EffectTerm,
    returns: Option(EffectTerm),
  )
}

// The operator a function *returns*, for a function whose result is itself a
// function (`fn pick() -> fn(fn() -> _) -> _`). Serialized into the spec file so
// the signature crosses module and package boundaries — a downstream
// `let h = pick(); with(h)` resolves `h` to this operator. `function` is
// module-qualified in the spec.
pub type ReturnsAnnotation {
  ReturnsAnnotation(function: String, operator: EffectTerm)
}

// Effect annotation for a type's field (e.g., `type Handler.on_click : [Dom]`).
//
// `module` is `Some(...)` when the annotation comes from a spec file (one
// file per package, qualified names like `myapp.Handler.on_click`) and
// `None` when it comes from a per-module cache file (bare names scoped to
// the file's module by location).
pub type TypeFieldAnnotation {
  TypeFieldAnnotation(
    module: Option(String),
    type_name: String,
    field: String,
    effects: EffectTerm,
  )
}

// Whether a type field's effect was hand-written on a `type Type.field : [...]`
// line (`Declared`) or inferred from a construction site (`Inferred`). A field
// call on a parameter/opaque receiver consults only `Declared` lines — an
// inferred, nominal-type-keyed entry never resolves such a receiver, since it
// holds package-wide evidence keyed by type rather than proof for this receiver.
// Whether a type field's effect was written by hand or read off a construction
// site. `Declared` carries the source that holds the field `assume` line.
pub type TypeFieldOrigin {
  Declared(source: LookupOrigin)
  Inferred
}

// Why a call's effect could not be resolved. Recorded by the resolver that
// decided it, at the moment it decided — never reconstructed afterwards.
pub type UnknownReason {
  // A qualified call no knowledge-base source keys: no spec line, no external,
  // no dependency spec, no catalog entry. The module is on the violation's
  // `call`, so this carries no payload.
  NoKnownEffects
  // A same-module call to a bodyless `@external` function with no
  // `assume` declaration.
  UndeclaredExternal
  // A call to an `@external` whose declaration names only targets this build
  // does not compile, and which has no Gleam body to run in their place. Nothing
  // in reach implements the name, so what it declares is no part of the charge —
  // which is why the value channel reuses it for a declared return the same
  // reading puts out of reach.
  UnbuiltExternal
  // A field call whose receiver girard could not type and no syntactic
  // parameter annotation names.
  ReceiverTypeUnresolved
  // A field call on a receiver of a known type that no field `assume` line, check
  // bound, or wired value decides. The payload names the receiver type; the
  // module is "" for the syntactic fallback, which has none.
  FieldNotAnnotated(module: String, type_name: String)
  // A field call whose receiver's construction could not be traced or grounded.
  UntraceableReceiver
  // A field call whose receiver's construction was traced, but the wired
  // value's effect still carries `Unknown` after substitution with no origin
  // explaining it: a wired function no source resolves, an unrecognised wired
  // value, a bare local name whose polymorphic marker concretized unbound, or a
  // locally analysed value whose effect is partly unknown.
  UnresolvedFieldValue
  // A direct application of a returned operator whose producer could not be
  // resolved.
  UntraceableProducer
  // A direct application of a returned operator whose producer's declared
  // return is in reach beside a Gleam fallback body that also runs. The two can
  // hand back different closures and there is no union of operators, so the
  // declaration answers nothing.
  RefusedDeclaredReturn
  // A call whose own effect resolved, and whose effect variable call-site
  // substitution then bound to `[Unknown]` — an argument this call site passed
  // that nothing resolves.
  UntraceableArgument
}

// Where a resolved effect came from: which source wrote the winning
// knowledge-base entry, or — for a field call — which rule decided it.
pub type LookupOrigin {
  // A per-function declaring line in this project's spec: an
  // `assume` one, or an `external returns` one.
  UserExternal
  // A committed `effects` line in this project's spec.
  CommittedSpec
  // In-memory inference over this project's source, this run.
  ProjectInferred
  // A dependency's shipped spec under `build/packages`.
  DependencySpec(package: String)
  // A path dependency's committed spec file. A declaration: its author wrote it.
  PathDependency(package: String)
  // Inference over a spec-less path dependency's source. Held apart from the
  // committed form because only one of the two is a declaration: inference over
  // an `@external`'s body describes something the foreign implementation needn't
  // match, so it must not answer for foreign code the way a written line does.
  PathDependencyInferred(package: String)
  // The bundled versioned catalog entry for a package.
  Catalog(package: String)
  // An `assume <module>` line answered for a name nothing else keys.
  // `source` is the file that declares it. Named apart from
  // `ExternalTarget.ModuleExternal`, which shares this module's namespace.
  ModuleExternalOrigin(source: LookupOrigin)
  // A hand-written field `assume` line resolved a field call. `source` is the file that
  // declares it. Set only by the field path, never stored beside a function
  // entry.
  TypeLine(source: LookupOrigin)
}

// Which of the knowledge base's two maps answered a function lookup. Reported
// by the lookup itself, so a caller that renders provenance can't drift out of
// step with the branch order that produced the term.
pub type EffectSource {
  // An entry keyed by the function itself, from any of the merged sources.
  // `origin` names the source that wrote it.
  FunctionEntry(origin: LookupOrigin)
  // The function's module carries `assume <module> : [...]`. Reached
  // only when nothing keys the function itself, so a per-function external or a
  // catalog line for it takes precedence; it carries no per-function bounds.
  ModuleExternalEntry(origin: LookupOrigin)
}

// A type field's resolved effect in the knowledge base. `effects` is the field
// call's effect set. When the field was inferred from a constructor site that
// wired an effect-polymorphic function, `bounds` and `source` carry that
// function's parameter bounds and qualified name, so a field call can bind the
// effect variables to its arguments (the same substitution resolved calls do).
// Both are empty/`None` for hand-written annotations and concrete field values.
// `origin` marks a hand-written field `assume` line apart from a construction-inferred
// entry.
pub type TypeFieldEffect {
  TypeFieldEffect(
    effects: EffectTerm,
    bounds: List(ParamBound),
    source: Option(QualifiedName),
    origin: TypeFieldOrigin,
  )
}

// Whether the package under analysis exports a function. Recorded for every
// function its parsed modules define, because `graded effect` answers for the
// public API alone and so has to tell a private name from one this package
// never defined. Resolution weighs none of it: a caller charges a private
// function exactly as it charges a public one.
pub type Visibility {
  Exported
  Internal
}

// What a knowledge base records about one `@external` it has seen the source
// of: whether its Gleam fallback body is code that runs on some target the
// function is compiled for. It travels with the name because it decides an
// answer no other entry can supply — a running fallback widens a declaration
// downstream, where the body itself is never walked.
//
// The target sets that decided it ride along, because a caller that runs on
// only some of them needs the same question answered for *its* targets: a body
// running where this name's declaration is compiled reaches foreign code, and
// one running where it isn't reaches the Gleam fallback. Reading the summary
// bool alone charges a caller both halves wherever either can happen.
pub type ForeignFunction {
  ForeignFunction(
    runs_fallback_body: Bool,
    // What the function is built for, and what its `@external` attributes
    // declare an implementation for. The difference is where the fallback runs.
    compiled_targets: Set(String),
    declared_targets: Set(String),
  )
}

// Whether an external targets a whole module or a specific function.
pub type ExternalTarget {
  // `assume gleam/list : []` — the entire module is pure.
  ModuleExternal
  // `assume gleam/httpc.send : [Http]` — a specific function.
  FunctionExternal(name: String)
}

// A trusted declaration (`assume gleam/httpc.send : [Http]`).
//
// `effects` is `None` for a line that carries only a `where returns` clause: it
// claims nothing about the function's own effect, and the tiers below keep
// answering for it. No reader may default a `None` to the empty set — that
// turns "claims nothing" into "is pure".
//
// `returns` carries the `where returns` clause, meaningful for a function
// target; a clause on a module path is a lint.
pub type ExternalAnnotation {
  ExternalAnnotation(
    module: String,
    target: ExternalTarget,
    effects: Option(EffectSet),
    returns: Option(EffectTerm),
  )
}

// A single line in an .graded file, preserving structure for round-trip rewrites.
pub type GradedLine {
  AnnotationLine(annotation: EffectAnnotation)
  TypeFieldLine(type_field: TypeFieldAnnotation)
  ExternalLine(external: ExternalAnnotation)
  ReturnsLine(returns: ReturnsAnnotation)
  // `external returns mod.fn : [Net]` — the operator a foreign producer hands
  // back, written by hand. The payload matches `ReturnsLine`; the separate
  // variant is what tells a declaration from an inferred line, at parse time.
  ExternalReturnsLine(returns: ReturnsAnnotation)
  CommentLine(text: String)
  BlankLine
}

// A complete parsed .graded file, preserving line-level structure.
pub type GradedFile {
  GradedFile(lines: List(GradedLine))
}

// Call extraction
//
// Call sites and argument values collected from function bodies, plus the
// provenance summaries that let receivers, factory-built records, and
// returned functions resolve at call sites instead of degrading to
// `[Unknown]`.

// A resolved call site found in a function body.
pub type ResolvedCall {
  ResolvedCall(name: QualifiedName, span: Span)
}

// What kind of value is at a call-site argument position? Used for
// binding effect variables during call-site substitution.
pub type ArgumentValue {
  // A qualified function reference, e.g. `io.println` or `types.OutOfRange`.
  // Effects are looked up in the knowledge base.
  FunctionRef(name: QualifiedName)
  // A bare identifier — a local function, a parameter, or an unbound
  // local variable. Resolved against the caller's param bounds or
  // local function map.
  LocalRef(name: String)
  // A record constructor (uppercase-initial qualified or bare name).
  // Pure by Gleam's semantics.
  ConstructorRef
  // An inline closure `fn(params) { body }`. `params` are its parameter names
  // (`_` for discarded), `body` its statements. When passed to an operator
  // parameter, the checker analyses the body — treating the first parameter as
  // the callback — and lifts it to an effect operator so the application
  // beta-reduces (rather than collapsing to `[Unknown]`). `captures` are the
  // callable bindings in scope at the closure's creation site (`let suffix =
  // string.append`), so re-analysing the body resolves a captured name to its
  // effect instead of `[Unknown]` — the binding-site lexical environment, kept
  // only for the callables the body could invoke.
  Closure(
    params: List(String),
    captures: List(#(String, ArgumentValue)),
    body: List(Statement),
  )
  // A value selected among several function-like options by a `case`/`if`
  // (`case c { True -> f  False -> g }`). When passed to an operator parameter,
  // each option is lifted and the results are joined (`(f ⊔ g)(cb) = f(cb) ⊔
  // g(cb)`), so the effect over-approximates every branch. Any non-function
  // branch makes the whole expression `OtherExpression` instead.
  Choice(options: List(ArgumentValue))
  // A value produced by *calling* a function that returns a function
  // (`let h = pick_handler()`). `callee` names the producer; a `""` module is
  // the same-module sentinel (resolved on-demand via the function map),
  // otherwise it's resolved from the producer's inferred returned-operator in
  // the knowledge base. `args` are the producer call's arguments, bound to the
  // producer's parameters when its returned operator is *polymorphic* in them
  // (a decorator, `fn traced(action) { fn(cb) { action(cb) } }`). Lets
  // `with_logger(pick_handler())` resolve instead of `[Unknown]`.
  ReturnedOperator(callee: QualifiedName, args: List(CallArgument))
  // A receiver path rooted at a bare identifier (`config.options` or
  // `config.a.b`). Carries the dotted path so a forwarded field-effect variable
  // can be re-keyed onto it when the root is one of the caller's parameters.
  // Treated as opaque (`[Unknown]`) everywhere except call-site field forwarding.
  ReceiverPath(path: String)
  // An inline constructor or factory call passed as an argument
  // (`inner(Options(resolver: resolver))` / `inner(make_options(resolver))`).
  // `fields` maps each constructor field label to the argument value wired into
  // it, so call-site field forwarding can re-key a callee field-effect variable
  // (`o.resolver`) onto the caller parameter the field is wired to. Opaque
  // (`[Unknown]`) everywhere except call-site field forwarding.
  Constructed(fields: Dict(String, ArgumentValue))
  // A call whose result is a record/value (not a returned function): the
  // receiver of a forwarding site, e.g. `inner(get_options(config))`. `callee`
  // names the function (with the `""` same-module sentinel); `args` are the
  // call's grounded arguments. Resolved at the call site against the callee's
  // `ReturnProvenance`; opaque provenance leaves it `[Unknown]`, exactly as
  // `OtherExpression` would.
  CallResult(callee: QualifiedName, args: List(CallArgument))
  // A record-update overlay: `base` with `fields` replaced (last-write-wins).
  // Built from a `Constructor(..base, label: value)` record update or a builder
  // call (`with_resolver(opts, http)`) whose body is one. Read field-selectively
  // — an updated field takes its replacement value, any other field falls
  // through to `base` — so the base need not be traceable to resolve an updated
  // field. Composes: chained builders nest `Updated`s.
  Updated(base: ArgumentValue, fields: Dict(String, ArgumentValue))
  // Anything else (a computed expression, literal, etc.). Effects come from
  // the enclosing walk; at the argument level we have no concrete function to
  // propagate.
  OtherExpression
}

// What a function's return value is built from, abstract over its parameters.
// `Passthrough` is the whole Nth parameter; `Path` is a receiver path rooted at
// the Nth parameter (`config.options` from parameter `config`); `Build` is a
// record rebuilt from parameter-rooted field provenances. `Opaque` is the Top
// element — the return can't be traced and any call to it yields `[Unknown]`.
pub type ReturnProvenance {
  Passthrough(position: Int)
  Path(position: Int, tail: String)
  Build(fields: Dict(String, FieldProvenance))
  // A union of branch provenances from a `case`/`if` return (`case c { True -> a
  // False -> b }`). Every branch is grounded against the same call arguments and
  // the results join, over-approximating the branch — mirroring how `Choice`
  // lifts function-valued branches. Any `Opaque` branch makes the whole join
  // `Opaque` (widen to Top), so a partially-traceable branch never under-reports.
  Join(branches: List(ReturnProvenance))
  Opaque
}

// A constructor field's provenance inside a `Build` summary: the whole Nth
// parameter, a path rooted at it, a concrete value wired at the construction
// site (a function reference, same-module function, closure, or nested
// construction/call — resolved per receiver, independent of the call's
// arguments), or untraceable. A field wired to anything else makes that field
// `FieldOpaque`.
pub type FieldProvenance {
  FieldParam(position: Int)
  FieldPath(position: Int, tail: String)
  FieldValue(value: ArgumentValue)
  FieldOpaque
}

// One argument at a call site. `position` respects pipes (the piped
// expression is implicitly position 0 and explicit arguments shift up).
// `label` is `Some(name)` for labeled arguments, `None` otherwise.
pub type CallArgument {
  CallArgument(position: Int, label: Option(String), value: ArgumentValue)
}

// A local (unresolved) call — needs transitive analysis.
pub type LocalCall {
  LocalCall(function: String, span: Span)
}

// A field access call: object.label(args) where object is a local variable.
// `span` is the whole call's span (for diagnostics); `receiver_span` is the
// receiver variable's own span, used to look up its inferred type.
// `provenance` records what extraction proved about the receiver, so the checker
// can resolve the call by concrete evidence (a wired field value), a live
// parameter root, or conservatively as `[Unknown]`.
pub type FieldCall {
  FieldCall(
    object: String,
    label: String,
    span: Span,
    receiver_span: Span,
    provenance: FieldCallProvenance,
  )
}

// What extraction proved about a field call's receiver, driving the checker's
// resolution precedence:
//
// - `ProvenValue` — this receiver's construction directly wired the queried
//   field to `value` (a closure, call result, returned operator, or inline
//   construction). Resolved per receiver via the field-value resolver, beating
//   any annotation. `FunctionRef`/`LocalRef` field values never reach here —
//   extraction resolves them to a plain call at their construction site.
// - `ParameterRoot` — the receiver path is rooted at a live top-level parameter
//   of the enclosing function (env-verified through nested aliases). Stays
//   polymorphic: a receiver-keyed field variable that forwards up and grounds to
//   `[Unknown]` if unbound.
// - `ProvenReceiver` — the whole receiver is a traced value (a let-bound call
//   result or a record-update overlay) whose construction is known but whose
//   queried field's value is not extracted until check time. The checker grounds
//   the receiver (a call result through its callee's return provenance) and reads
//   the queried field from it, resolving per receiver — never the nominal index.
// - `Untraceable` — the receiver is a shadowed/computed/opaque value, or a field
//   inherited from an untraceable base. Resolved conservatively to `[Unknown]`.
pub type FieldCallProvenance {
  ProvenValue(value: ArgumentValue)
  ProvenReceiver(value: ArgumentValue)
  ParameterRoot(path: String)
  Untraceable
}

// A *factory* function's signature. `fields` maps each constructor field the
// factory wires to one of its own parameters to that parameter's position; a
// call `make(io.println)` to `fn make(logger) { Validator(to_error: logger) }`
// binds the result's `to_error` field to argument 0, so a later `v.to_error(..)`
// resolves like a direct construction instead of `[Unknown]`. `param_labels`
// maps each factory parameter's Gleam label to its position, so a labeled call
// (`make(logger: io.println)`) routes to the same fields as the positional one.
pub type FactorySignature {
  FactorySignature(fields: Dict(String, Int), param_labels: Dict(String, Int))
}

// An *update builder*'s signature: its body is a record update of one of its
// parameters (`with_resolver(o, resolver) { Options(..o, resolver:) }`).
// `base_param` is the position of the parameter being updated (`o`); `fields`
// maps each updated field label to the parameter position wiring it (`resolver`
// -> 1). A call `with_resolver(base, http)` then builds an `Updated` overlay of
// the base argument with those fields replaced. `param_labels` maps each
// parameter's Gleam label to its position, for labeled calls. Only builders whose
// every updated field is wired to a parameter qualify — a field wired to a fixed
// value would need the base to ground, so such a function stays a plain call.
pub type UpdateSignature {
  UpdateSignature(
    base_param: Int,
    fields: Dict(String, Int),
    param_labels: Dict(String, Int),
  )
}

// A *returned operator applied directly*: `let h = pick_handler(); h(cb)`.
// `callee` names the producer (with the `""` same-module sentinel, as in
// `ReturnedOperator`) and `producer_args` are the producer call's arguments;
// together they resolve the operator the producer returns. The direct call's
// own arguments (`cb`) are recorded in `call_args` under `span.start`, so the
// resolved operator is applied to them. Lets a let-bound returned operator
// resolve when *applied directly*, not only when passed to an operator
// parameter.
pub type DirectOperatorCall {
  DirectOperatorCall(
    callee: QualifiedName,
    producer_args: List(CallArgument),
    span: Span,
  )
}

// A let-bound function-like value *applied directly by name*: `let h = fn(x) {
// ... }; h(a, b)`. `value` is the lifted operator source (a `Closure` or
// `Choice`); the call's own arguments are recorded in `call_args` under
// `span.start` and applied (curried) over the operator's binders. Lets a
// let-bound closure that is called — not just passed to an operator parameter —
// resolve to its body effect rather than collapsing to `[Unknown]`.
pub type DirectClosureCall {
  DirectClosureCall(value: ArgumentValue, span: Span)
}

// An inline function-like value used as a *pipe target* and thereby applied to
// the piped value: `x |> fn(f) { f() }` or `x |> case c { _ -> a  _ -> b }`.
// `value` is the lifted operator source (a `Closure` or `Choice`); the piped
// value is recorded in `call_args` under `span.start` as argument 0. Without
// this the closure/branch body's use of the piped value is dropped — an
// *understatement*, so resolving it is a soundness fix, not just precision.
pub type DirectPipeOp {
  DirectPipeOp(value: ArgumentValue, span: Span)
}

// Check results
//
// The violations and warnings the checker reports, and the per-file result
// that carries them.

// One reachable effect contributor of a function body: the call site, its
// position, the ground effect set it contributes, and why the set stayed
// unresolved or which source answered.
//
// `reason` and `origin` are what the resolver recorded about this call: why its
// effect could not be resolved, and which knowledge-base source answered.
// Either may be absent — a call whose kind already states the whole story
// records no reason, and a term no source keyed carries no origin.
pub type CallExplanation {
  CallExplanation(
    call: QualifiedName,
    span: Span,
    actual: EffectSet,
    reason: Option(UnknownReason),
    origin: Option(LookupOrigin),
    // What a running Gleam fallback body contributed to `actual`, when the call
    // reaches an `@external` that has one. `origin` speaks for the declaration
    // only, so without this the union would be credited to a declaration that
    // never stated it — `[]` reported as the source of a `[Disk]`.
    fallback: Option(EffectSet),
  )
}

// A single effect violation: an annotated function called something that
// exceeds its declared effect budget. The call is held as the explanation
// `why` prints for it, so a violation states what a contributor states and the
// two can't drift apart.
pub type Violation {
  Violation(function: String, declared: EffectSet, explanation: CallExplanation)
}

// A warning surfaced during checking.
pub type Warning {
  // A function reference passed as a value whose effects won't be tracked
  // through the callee.
  UntrackedEffectWarning(
    function: String,
    reference: QualifiedName,
    span: Span,
    effects: EffectSet,
  )
  // A field bound (`check f(recv.field: [..])`) whose `recv.field` path matched
  // no field call in the function's body. Such a bound resolves nothing and is
  // silently dead, so it's flagged. `receiver_is_param` distinguishes the cause:
  // when the receiver is a parameter it can't be traced to a construction site,
  // so a missing field call is a genuine typo; when it isn't, the field call may
  // exist but have resolved through value provenance, shadowing the bound.
  UnmatchedFieldBoundWarning(
    function: String,
    field_path: String,
    receiver_is_param: Bool,
  )
  // A plain parameter bound (`check f(g: [..])`) whose name matches no declared
  // parameter of the function — a typo. Matched on parameter *existence*, not
  // call presence: a callback forwarded but never called directly is still a
  // real parameter and isn't flagged, since its bound stays load-bearing during
  // substitution.
  UnmatchedParamBoundWarning(function: String, param: String)
  // A `check` line whose qualified function name matches no function defined in
  // any project module — a missing module qualifier or a typo. The check then
  // never runs against any function and passes vacuously, so it's flagged.
  // A `check` whose subject is a field rather than a function is
  // `UnverifiedCheckShapeWarning` instead.
  UnmatchedCheckWarning(function: String)
  // A `check` line over a shape nothing verifies yet: a field path
  // (`m.Handler.on_click`). The line parses and keys nothing. `name` is the
  // subject as written.
  UnverifiedCheckShapeWarning(name: String)
  // A field `assume` line whose module/type/field matches no field of a project custom
  // type — unqualified, mis-qualified, or a typo. The annotation then resolves
  // nothing and the field call silently degrades to `[Unknown]`, so it's
  // flagged. `name` is the annotation as written (`Opts.on_change` when
  // unqualified, `myapp/opts.Opts.on_change` when qualified).
  UnmatchedTypeFieldWarning(name: String)
  // A per-function `assume <module>.<function>` line naming one of
  // this package's own ordinary Gleam functions — a body graded can see and
  // every caller runs. The syntax declares foreign code, so the line describes
  // nothing the body does not; it is ignored and the body is walked instead.
  // Scoped to modules the project index holds: declaring a *dependency*
  // function with a visible body is the line's documented use.
  StaleFunctionExternalWarning(function: String)
  // A per-function `assume <module>.<function>` line whose name
  // resolves nowhere — no dependency, no catalog entry, no project module. The
  // declaration then covers nothing, so it is a typo rather than a budget.
  UnmatchedFunctionExternalWarning(function: String)
  // A module-level `assume <module>` line whose module is neither an
  // installed dependency, a path dependency, nor a project module. Same
  // reasoning one tier up: the declaration governs no module at all.
  UnmatchedModuleExternalWarning(module: String)
  // An `external returns <module>.<function>` line naming one of this package's
  // own ordinary Gleam functions. The same rule as
  // `StaleFunctionExternalWarning` one channel over: the body is visible, so
  // every caller resolves what it hands back for itself and the line declares
  // nothing. It is ignored and the body walked instead.
  StaleExternalReturnsWarning(function: String)
  // An `external returns <module>.<function>` line whose name resolves nowhere
  // — no dependency, no catalog entry, no project module. The declaration then
  // covers nothing, so it is a typo rather than a signature.
  UnmatchedExternalReturnsWarning(function: String)
  // An `external returns` line whose operator is polymorphic (`fn(cb) -> [cb]`).
  // Its free variables are unsanitized, so substituting through it would pass a
  // budget nothing backs: only a ground operator is loaded, and this line is
  // ignored.
  PolymorphicExternalReturnsWarning(function: String)
  // An `external returns <module>` line with no function part. The declaration
  // is per-function by nature — nothing keys a whole module's returned value —
  // so the line resolves nothing at all.
  DotlessExternalReturnsWarning(name: String)
  // An `external returns <module>.<Type>.<field>` line: a name of more than two
  // parts, which is the field `assume` line's shape, not this one's. A returns
  // declaration keys a function, so the line resolves nothing.
  TypeShapedExternalReturnsWarning(name: String)
}

// Result of checking one file.
pub type CheckResult {
  CheckResult(
    file: String,
    violations: List(Violation),
    warnings: List(Warning),
  )
}
