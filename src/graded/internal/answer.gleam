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
  // term's variables, and which knowledge-base entry answered.
  FunctionAnswer(
    // The name as queried, module qualifier included.
    name: String,
    module: String,
    bounds: List(ParamBound),
    term: EffectTerm,
    source: types.EffectSource,
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
    // A module-level external carries no per-function bounds, so its line is
    // rendered without them and labelled.
    FunctionAnswer(name:, module:, term:, source: types.ModuleExternalEntry, ..) ->
      effects_line(name, [], term)
      <> "\n// resolved via module-level external for "
      <> module
    FunctionAnswer(
      name:,
      bounds:,
      term:,
      source: types.FunctionEntry(origin:),
      ..,
    ) -> effects_line(name, bounds, term) <> graded_source(origin)
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

// The comment naming the source that wrote the winning entry, or nothing when
// the lookup recorded none.
fn graded_source(origin: Option(types.LookupOrigin)) -> String {
  case origin {
    Some(origin) -> "\n// resolved from " <> effects.describe_origin(origin)
    None -> ""
  }
}

// Only `Declared` entries reach the knowledge base today — `with_type_fields`
// is its only writer — so the `Inferred` wording describes a shape the query
// can't currently return.
fn graded_origin(origin: types.TypeFieldOrigin) -> String {
  case origin {
    types.Declared -> "declared by a type line"
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
        ..detail_lines(bounds, module, source)
      ]
      |> string.join("\n")
    TypeFieldAnswer(module:, type_name:, field:, term:, origin:) ->
      [field_sentence(module, type_name, field, term), prose_origin(origin)]
      |> string.join("\n")
  }
}

fn function_sentence(
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
  source: types.EffectSource,
) -> List(String) {
  // A bound is an assumption applied to the argument at call sites, not a
  // claim about where this function's own effects came from, so it follows the
  // source line rather than standing in for it.
  let bound_lines = bounds |> list.filter(constrains) |> list.map(bound_line)
  case source {
    types.ModuleExternalEntry -> [
      "  source: module-level external for `" <> module <> "`",
      "          used when no per-function entry exists",
    ]
    types.FunctionEntry(origin: Some(origin)) -> [
      "  source: " <> effects.describe_origin(origin),
      ..bound_lines
    ]
    types.FunctionEntry(origin: None) -> bound_lines
  }
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
    types.Declared -> "  source: declared by a `type` line"
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
