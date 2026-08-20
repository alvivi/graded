// The answer to one `graded effect` lookup: what the knowledge base said about
// a name, held as data, plus the renderers that turn it into output.
//
// Resolution builds an `EffectAnswer` and hands it to a renderer, so provenance
// travels as a value rather than as a comment string a second consumer would
// have to read back. Every fact a renderer states has to be a field here; a
// renderer that re-derives one can drift from the lookup that produced it.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded/internal/annotation
import graded/internal/effect_term
import graded/internal/effects
import graded/internal/types.{
  type EffectTerm, type ParamBound, EffectAnnotation, TypeFieldAnnotation,
}

// The answer

pub type EffectAnswer {
  // A qualified function: its effect term, the parameter bounds binding that
  // term's variables, and what answered for it.
  FunctionAnswer(
    // The name as queried, module qualifier included.
    name: String,
    module: String,
    bounds: List(ParamBound),
    term: EffectTerm,
    source: AnswerSource,
  )
  // A field of a custom type, declared by a `type` line. `module` is `None` for
  // a bare declaration, which is keyed under no module.
  TypeFieldAnswer(
    module: Option(String),
    type_name: String,
    field: String,
    term: EffectTerm,
    origin: types.TypeFieldOrigin,
  )
}

// What answered for a function: the knowledge-base entry that keyed it, or —
// for foreign code no entry may speak for — the standing that settled its term
// instead.
//
// The two that name a declaration a Gleam fallback body can be added to carry
// that body's contribution themselves, so no answer can state a fallback half
// beside a source that already accounts for the whole term.
pub type AnswerSource {
  // The entry the lookup returned, and which map it came from, beside what a
  // Gleam fallback body running on an uncovered target contributed to the term.
  // The source speaks for the declaration only, so without that half the union
  // would read as what the declaration said.
  Entry(entry: types.EffectSource, fallback: Option(EffectTerm))
  // A function whose implementation is foreign code — an `@external` — that
  // nothing declares. The entries the knowledge base holds for such a name were
  // inferred over a body the foreign implementation needn't match, so none of
  // them answers, and the effects are the `[Unknown]` `check` and `why` charge
  // for it, unioned with whatever a running Gleam fallback body does.
  //
  // The bounds beside it bind that fallback's variables: a fallback that calls
  // a function-typed parameter states its effects over the parameter, and
  // without them the line names a variable nothing introduces.
  UndeclaredExternal(fallback: Option(EffectTerm))
  // A function whose implementation is foreign code, whose declaration names
  // only targets this build does not compile, and which no Gleam body runs in
  // the place of: nothing this build reaches implements the name at all. What
  // the declaration says is no part of what a caller pays, so neither it nor
  // its source is named — crediting a shipped spec with the conservative
  // `[Unknown]` an out-of-reach declaration collapses to points the reader at
  // the very line the answer ruled out.
  UnreachedDeclaration
  // The same out-of-reach declaration, with a Gleam fallback body running in
  // its place. That body is the whole of the term, not a half added to a
  // declaration.
  RunningFallbackBody
}

// Rendering

pub type Format {
  // Sentences describing the answer, for a person reading a terminal.
  Prose
  // `.graded` syntax: the answer as a spec line with provenance on a `//`
  // comment, so the whole output parses back.
  Graded
}

pub fn render(answer: EffectAnswer, format: Format) -> String {
  case format {
    Prose -> render_prose(answer)
    Graded -> render_graded(answer)
  }
}

// The `.graded` renderer
//
// Spec syntax, so a consumer that already parses `.graded` needs no second
// grammar and a line can be pasted into a spec file. Both hold only while
// provenance stays inside a comment.

pub fn render_graded(answer: EffectAnswer) -> String {
  case answer {
    // Whatever bounds the lookup found are rendered, whichever source answered:
    // a module-level external declares no per-function bounds itself, but a
    // running fallback body under it states its own effects over the parameters
    // it calls.
    FunctionAnswer(name:, module:, bounds:, term:, source:) ->
      effects_line(name, bounds, term)
      <> graded_source(module, source)
      <> graded_fallback(source_fallback(source))
    TypeFieldAnswer(module:, type_name:, field:, term:, origin:) ->
      annotation.format_type_field(TypeFieldAnnotation(
        module:,
        type_name:,
        field:,
        effects: term,
      ))
      <> "\n// "
      <> graded_origin(origin)
  }
}

fn effects_line(
  name: String,
  bounds: List(ParamBound),
  term: EffectTerm,
) -> String {
  annotation.format_annotation(EffectAnnotation(
    kind: types.Effects,
    function: name,
    params: bounds,
    effects: term,
  ))
}

// The comment naming what answered: the source that wrote the winning entry,
// or the standing that settled the term where no entry could.
fn graded_source(module: String, source: AnswerSource) -> String {
  "\n// "
  <> case source {
    Entry(entry: types.ModuleExternalEntry(..), ..) ->
      "resolved via module-level `assume` for " <> module
    Entry(entry: types.FunctionEntry(origin:), ..) ->
      "resolved from " <> effects.describe_origin(origin)
    UndeclaredExternal(..) -> undeclared_external_source
    UnreachedDeclaration -> unreached_declaration_source
    RunningFallbackBody -> running_fallback_source
  }
}

// Only `Declared` entries reach the knowledge base today — `with_type_fields`
// is its only writer — so the `Inferred` wording describes a shape the query
// can't currently return.
fn graded_origin(origin: types.TypeFieldOrigin) -> String {
  case origin {
    types.Declared(source:) ->
      "assumed by a field `assume` in " <> effects.describe_source_file(source)
    types.Inferred -> "inferred from construction"
  }
}

// The prose renderer
//
// A sentence naming what was found, then indented lines for what the knowledge
// base knows about how it was reached. Effect sets keep their bracket notation:
// `[Stdout]` is the spec's vocabulary, and unbracketed it stops reading as a
// set.
//
// Each sentence states only what the answer proves, and states it as a claim
// about effects rather than about behaviour: a term that is exactly a bound
// variable proves the function's effects *are* that argument's, not that the
// argument is ever called. A ground term beside a bound proves a total and an
// assumption about the argument, and is described as such.

pub fn render_prose(answer: EffectAnswer) -> String {
  case answer {
    FunctionAnswer(name:, module:, bounds:, term:, source:) ->
      [
        function_sentence(name, bounds, term),
        ..list.append(
          detail_lines(bounds, module, source),
          prose_fallback(source_fallback(source)),
        )
      ]
      |> string.join("\n")
    TypeFieldAnswer(module:, type_name:, field:, term:, origin:) ->
      [field_sentence(module, type_name, field, term), prose_origin(origin)]
      |> string.join("\n")
  }
}

// The sentences for the sources no knowledge-base entry wrote, worded once so
// the two formats state them identically.

// The source a name answered by the Gleam body running in its declaration's
// place names. `why` says the same of a call, stated from the calling body's
// targets; the query answers for the package, so it names the build's.
const running_fallback_source = "its Gleam fallback body, which is what runs on the targets this build compiles"

// What answered for a name whose declaration this build reaches no part of and
// which no Gleam body runs in the place of.
const unreached_declaration_source = "an external declared only for a target this build does not compile"

// What answered for foreign code nothing declares.
const undeclared_external_source = "an external with no declared effects"

// The fallback half of a source that carries one. The other two sources carry
// none: a body running in an unreached declaration's place is the whole of the
// term, not a half added to it, and there is nothing to name beside it.
fn source_fallback(source: AnswerSource) -> Option(EffectTerm) {
  case source {
    Entry(fallback:, ..) | UndeclaredExternal(fallback:) -> fallback
    UnreachedDeclaration | RunningFallbackBody -> None
  }
}

// The half of the answer the declaration does not account for, named apart from
// it so neither is credited with the other's effects.
fn graded_fallback(fallback: Option(EffectTerm)) -> String {
  case fallback {
    None -> ""
    Some(term) ->
      "\n// unioned with its Gleam fallback body, which runs on the targets its"
      <> " `@external` declares no implementation for: "
      <> annotation.format_effect_term(effect_term.normalize(term))
  }
}

fn prose_fallback(fallback: Option(EffectTerm)) -> List(String) {
  case fallback {
    None -> []
    Some(term) -> [
      "  plus its Gleam fallback body, which runs on the targets its `@external`"
      <> " declares no implementation for: "
      <> annotation.format_effect_term(effect_term.normalize(term)),
    ]
  }
}

// The sentence a total is stated in, shared by every command that reports one
// so they cannot word a function's effects differently.
pub fn function_sentence(
  name: String,
  bounds: List(ParamBound),
  term: EffectTerm,
) -> String {
  case forwarding(bounds, term) {
    ForwardsOnly(argument) ->
      name
      <> " has the effects of its `"
      <> argument
      <> "` argument, and none of its own"
    ForwardsPlus(argument, own) ->
      name
      <> " has the effects of its `"
      <> argument
      <> "` argument, plus "
      <> annotation.format_effect_set(types.Specific(own))
      <> " of its own"
    Total -> name <> " " <> total_effects(term)
  }
}

fn field_sentence(
  module: Option(String),
  type_name: String,
  field: String,
  term: EffectTerm,
) -> String {
  let qualifier = case module {
    Some(module) -> " (" <> module <> ")"
    None -> ""
  }
  "field `"
  <> field
  <> "` on type `"
  <> type_name
  <> "`"
  <> qualifier
  <> " "
  <> total_effects(term)
}

// How a term reads when it states a total rather than a source. `[]` is purity
// and `[Unknown]` is an effect graded could not determine — both answers in
// their own right, not absences — and a set that is only *partly* unknown must
// not read as though none of it resolved.
//
// Only a ground term is classified. A term still carrying a variable, an
// application or an operator is stated as the `.graded` renderer states it —
// collapsing it to a set here would report `[Unknown]` for a term that is
// symbolic, not unresolved, and the two formats would then disagree about what
// was found rather than about how to say it.
//
// Reached through `function_sentence`, which `why`'s header calls so that it
// states a function's total in the words `effect` states one in: two commands
// answering about one function's effects say the same thing about them.
fn total_effects(term: EffectTerm) -> String {
  let normalized = effect_term.normalize(term)
  case ground_labels(normalized) {
    Ok(labels) -> ground_sentence(labels)
    Error(Nil) -> "has effects " <> annotation.format_effect_term(normalized)
  }
}

fn ground_sentence(labels: Set(String)) -> String {
  let rendered = annotation.format_effect_set(types.Specific(labels))
  case set.size(labels), set.contains(labels, types.unknown_label) {
    0, _ -> "is pure — no effects ([])"
    1, True -> "has effects that could not be determined: [Unknown]"
    _, True ->
      "has effects " <> rendered <> "; part of them could not be determined"
    _, False -> "has effects " <> rendered
  }
}

// The labels of an already-normalized term that is ground: plain labels, or a
// union of ground terms. Anything else has no set to classify.
fn ground_labels(term: EffectTerm) -> Result(Set(String), Nil) {
  case term {
    types.TLabels(labels) -> Ok(labels)
    types.TUnion(members) ->
      members
      |> list.try_map(ground_labels)
      |> result.map(list.fold(_, set.new(), set.union))
    types.TTop | types.TVar(_) | types.TApp(_, _) | types.TAbs(_, _) ->
      Error(Nil)
  }
}

// What follows the sentence: the declaration that answered, or the bounds the
// checker applies at call sites.
fn detail_lines(
  bounds: List(ParamBound),
  module: String,
  source: AnswerSource,
) -> List(String) {
  // The bound lines follow the source lines: each states an assumption the
  // checker applies to that argument at call sites. They follow either source —
  // a module-level external declares none itself, but a running fallback body
  // under it does, and the assumption holds however the entry was reached.
  let source_lines = case source {
    Entry(entry: types.ModuleExternalEntry(..), ..) -> [
      "  source: module-level `assume` for `" <> module <> "`",
      "          used when no per-function entry exists",
    ]
    Entry(entry: types.FunctionEntry(origin:), ..) -> [
      "  source: " <> effects.describe_origin(origin),
    ]
    UndeclaredExternal(..) -> ["  source: " <> undeclared_external_source]
    UnreachedDeclaration -> ["  source: " <> unreached_declaration_source]
    RunningFallbackBody -> ["  source: " <> running_fallback_source]
  }
  list.append(source_lines, bound_lines(bounds))
}

fn bound_lines(bounds: List(ParamBound)) -> List(String) {
  bounds |> list.filter(constrains) |> list.map(bound_line)
}

// Whether a bound says anything a reader doesn't already have. The identity
// bound `f: [f]` — what inference writes for an unconstrained callback — states
// that `f`'s effects are `f`'s effects, and the sentence above it already
// attributes them. A bound with content is a real budget and is stated.
fn constrains(bound: ParamBound) -> Bool {
  case bound.effects {
    types.TVar(name) -> name != bound.name
    types.TLabels(_)
    | types.TTop
    | types.TApp(_, _)
    | types.TAbs(_, _)
    | types.TUnion(_) -> True
  }
}

fn bound_line(bound: ParamBound) -> String {
  case bound.effects {
    // A second-order operator bound has no set to state; quote the spec form
    // rather than collapsing it to a set it isn't.
    types.TAbs(_, _) ->
      "  argument `"
      <> bound.name
      <> "` carries the operator bound `"
      <> annotation.format_param_bound(bound)
      <> "`"
    types.TLabels(_)
    | types.TTop
    | types.TVar(_)
    | types.TApp(_, _)
    | types.TUnion(_) ->
      "  calls to argument `"
      <> bound.name
      <> "` are treated as having effects "
      <> annotation.format_effect_term(bound.effects)
  }
}

fn prose_origin(origin: types.TypeFieldOrigin) -> String {
  case origin {
    types.Declared(source:) ->
      "  source: assumed by a field `assume` in "
      <> effects.describe_source_file(source)
    types.Inferred -> "  source: inferred from construction"
  }
}

// Term shapes
//
// Whether a term forwards a bound argument's effects — the one claim about
// causality prose is allowed to make.

type Forwarding {
  // The term is exactly a bound variable: the function's effects are that
  // argument's, and it contributes none itself.
  ForwardsOnly(argument: String)
  // That variable unioned with ground labels the function contributes itself.
  ForwardsPlus(argument: String, own: Set(String))
  // Anything else: the term states a total, not where it came from.
  Total
}

fn forwarding(bounds: List(ParamBound), term: EffectTerm) -> Forwarding {
  let bound_names = list.map(bounds, fn(bound) { bound.name })
  case term {
    types.TVar(name) ->
      case list.contains(bound_names, name) {
        True -> ForwardsOnly(name)
        False -> Total
      }
    types.TUnion(members) -> union_forwarding(bound_names, members)
    types.TLabels(_) | types.TTop | types.TApp(_, _) | types.TAbs(_, _) -> Total
  }
}

// A union forwards when exactly one member is a bound variable and every other
// member is ground labels. Two variables, or a member of any other shape, is
// something prose doesn't characterize.
fn union_forwarding(
  bound_names: List(String),
  members: List(EffectTerm),
) -> Forwarding {
  let classified = list.map(members, classify_member(bound_names, _))
  let arguments =
    list.filter_map(classified, fn(member) {
      case member {
        BoundVariable(name) -> Ok(name)
        GroundLabels(_) | Uncharacterized -> Error(Nil)
      }
    })
  case arguments, list.contains(classified, Uncharacterized) {
    [argument], False ->
      case set.is_empty(union_labels(classified)) {
        True -> ForwardsOnly(argument)
        False -> ForwardsPlus(argument, union_labels(classified))
      }
    // A member prose can't characterize means the union states a total: those
    // effects are not the argument's.
    [_argument], True -> Total
    [], _ | [_, _, ..], _ -> Total
  }
}

// One member of a union, as prose sees it.
type UnionMember {
  BoundVariable(name: String)
  GroundLabels(labels: Set(String))
  Uncharacterized
}

fn classify_member(
  bound_names: List(String),
  member: EffectTerm,
) -> UnionMember {
  case member {
    types.TVar(name) ->
      case list.contains(bound_names, name) {
        True -> BoundVariable(name)
        False -> Uncharacterized
      }
    types.TLabels(labels) -> GroundLabels(labels)
    types.TTop | types.TApp(_, _) | types.TAbs(_, _) | types.TUnion(_) ->
      Uncharacterized
  }
}

fn union_labels(classified: List(UnionMember)) -> Set(String) {
  list.fold(classified, set.new(), fn(acc, member) {
    case member {
      GroundLabels(labels) -> set.union(acc, labels)
      BoundVariable(_) | Uncharacterized -> acc
    }
  })
}
