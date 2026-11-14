// What a value carries: the latent effects of every function value reachable
// in it, and what a callback costs when the callee runs it.
//
// Every value is read by one precedence. A type proven to hold no function
// carries nothing. Otherwise evidence that bounds the whole value is used — a
// traced reference or closure, a literal or construction whose every component
// is bounded, a call whose winning line declares what its result carries, a
// value the checker traces through provenance or field resolution, a constant
// the audit describes. Anything else carries `[Unknown]`.
//
// The checker hands in what this module cannot compute alone — types, lifting,
// tracing, contracts — through a `Resolver`, together with its memo state, so
// this module imports no checker code.

import girard
import glance.{type Span}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import graded/internal/effect_term
import graded/internal/extract
import graded/internal/typedefs
import graded/internal/types.{
  type ArgumentValue, type BoundKind, type CallArgument, type EffectTerm,
  type LatentContract, type ParamBound, type QualifiedName, CallbackKind,
  NonCallbackKind, TAbs, TApp, TUnion, UnknownKind,
}

// Latents

// What a value carries. `FunctionFree` is proven: the value holds no function.
// `Carries` is an upper bound on the latent effects of every function value in
// it; it holds `Unknown` where part of the value is not known.
pub type Latent {
  FunctionFree
  Carries(term: EffectTerm)
}

pub fn unknown() -> Latent {
  Carries(effect_term.unknown())
}

// Two values together: `FunctionFree` is the unit.
pub fn join(left: Latent, right: Latent) -> Latent {
  case left, right {
    FunctionFree, other | other, FunctionFree -> other
    Carries(a), Carries(b) -> Carries(effect_term.normalize(TUnion([a, b])))
  }
}

// The effect a latent charges where the value may run: nothing for a value
// holding no function.
pub fn to_term(latent: Latent) -> EffectTerm {
  case latent {
    FunctionFree -> effect_term.pure()
    Carries(term:) -> term
  }
}

// What a callback costs when it is run, kept apart from what its result
// carries: a contract may name either, and an unknown consumer may activate
// both.
pub type Callback {
  Callback(cost: EffectTerm, result: Latent)
}

// What a function value carries where something that may call it, and call
// what it returns, receives it.
pub fn escape(callback: Callback) -> Latent {
  join(Carries(callback.cost), callback.result)
}

// The resolver

// What the checker traces a value to.
pub type Grounding {
  // The value the expression holds, to read on.
  GroundedValue(value: ArgumentValue)
  // A function value: lift it.
  GroundedFunction
  // What the value carries, stated directly: a parameter's bound.
  GroundedLatent(latent: Latent)
  // Nothing is known.
  Ungrounded
}

// One bound of a callee's contract with what the run knows of its parameter.
pub type ContractParameter {
  ContractParameter(
    bound: ParamBound,
    kind: BoundKind,
    // The callback positions of an operator parameter: what a callback
    // argument is lifted over when the term applies the bound's variable.
    operator_positions: Option(List(Int)),
  )
}

// What the winning line for a callee says about function values.
pub type CalleeContract {
  CalleeContract(
    parameters: List(ContractParameter),
    contract: LatentContract,
    // Whether the line is a reviewed catalog line, whose contract the review
    // vouches for whatever kind its parameters resolve to. A written line
    // promises nothing for a parameter of unknown kind.
    reviewed: Bool,
  )
}

pub type Resolver(memo) {
  Resolver(
    // girard's type of the expression written at a span, once for every
    // target that compiles it: `None` for one that typed nothing there.
    types_at: fn(Span) -> List(Option(girard.Type)),
    // Every type constructor's summary, solved once for the run.
    shapes: typedefs.Shapes,
    // The shapes read so far, kept in the checker's memo from one reading to
    // the next.
    shape_memo: fn(memo) -> ShapeMemo,
    with_shape_memo: fn(memo, ShapeMemo) -> memo,
    // A function value as an operator over its parameters: `arity` of them
    // where known, else as many as its own signature says. `Error(Nil)` where
    // it cannot be lifted.
    lift: fn(ArgumentValue, Option(Int), memo) ->
      #(Result(EffectTerm, Nil), memo),
    // A function value as an operator over an operator parameter's callback
    // positions.
    lift_operator: fn(ArgumentValue, List(Int), memo) ->
      #(Result(EffectTerm, Nil), memo),
    // What the checker traces a value this module cannot read alone to.
    ground: fn(ArgumentValue) -> Grounding,
    // An inline closure's tail expression, classified in the closure's own
    // scope.
    closure_tail: fn(ArgumentValue) -> Option(types.Component),
    // The winning line's contract for a callee, where it states one.
    contract: fn(QualifiedName, memo) -> #(Option(CalleeContract), memo),
    // The argument a callee's bound takes at a call.
    match: fn(QualifiedName, String, List(CallArgument)) -> Option(CallArgument),
    // What a constant the audit describes carries.
    constant: fn(QualifiedName) -> Option(Latent),
  )
}

// The part of the type at a span a shape is asked of.
pub type TypePart {
  WholeType
  // A function type's return.
  ReturnedType
  // A function type's one parameter, where it has one.
  HoleType
}

// Shapes already read, by the span's start and end and the part asked of.
pub type ShapeMemo =
  Dict(#(Int, Int, TypePart), typedefs.Shape)

// How deep a value is read before what is left carries `[Unknown]`.
const depth_bound = 24

// How many values one reading reads before what is left carries `[Unknown]`.
const read_budget = 10_000

// What one reading threads: the checker's memo; what each value written at a
// site read to, by the site's span, the depth it was read at and the scope it
// was read in; and how many more values it may read.
//
// A value named in several places is held at each of them, and the sites
// inside it are the same wherever it is reached, so each of those is read once
// per depth and scope however many paths reach it.
type Reading(memo) {
  Reading(
    memo: memo,
    sites: Dict(#(Int, Int, Int, Dict(String, Latent)), Latent),
    budget: Int,
  )
}

// Run a reading from a fresh state over `memo`.
fn read_with(
  memo: memo,
  read: fn(Reading(memo)) -> #(a, Reading(memo)),
) -> #(a, memo) {
  let #(result, reading) =
    read(Reading(memo:, sites: dict.new(), budget: read_budget))
  #(result, reading.memo)
}

// Run something that threads the checker's memo inside a reading.
fn with_memo(
  reading: Reading(memo),
  run: fn(memo) -> #(a, memo),
) -> #(a, Reading(memo)) {
  let #(result, memo) = run(reading.memo)
  #(result, Reading(..reading, memo:))
}

// Whether the reading may read one more value.
fn exhausted(reading: Reading(memo), depth: Int) -> Bool {
  depth > depth_bound || reading.budget <= 0
}

fn spend(reading: Reading(memo)) -> Reading(memo) {
  Reading(..reading, budget: reading.budget - 1)
}

// Argument values

// What the value written at `span` carries. `scope` maps the parameters of the
// closures being read through to what they receive.
pub fn argument_latent(
  value: ArgumentValue,
  span: Span,
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  memo: memo,
) -> #(Latent, memo) {
  read_with(memo, site_latent(value, span, scope, resolver, _, 0))
}

// What the value written at `span` carries, from the reading's record of that
// site where it read it at this depth in this scope. A span no expression is
// written at names no site.
fn site_latent(
  value: ArgumentValue,
  span: Span,
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  reading: Reading(memo),
  depth: Int,
) -> #(Latent, Reading(memo)) {
  let key = #(span.start, span.end, depth, scope)
  case span.start < 0, dict.get(reading.sites, key) {
    False, Ok(latent) -> #(latent, reading)
    True, _ -> value_latent(value, span, scope, resolver, reading, depth)
    False, Error(Nil) -> {
      let #(latent, reading) =
        value_latent(value, span, scope, resolver, reading, depth)
      #(
        latent,
        Reading(..reading, sites: dict.insert(reading.sites, key, latent)),
      )
    }
  }
}

fn value_latent(
  value: ArgumentValue,
  span: Span,
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  reading: Reading(memo),
  depth: Int,
) -> #(Latent, Reading(memo)) {
  use <- bool.guard(when: exhausted(reading, depth), return: #(
    unknown(),
    reading,
  ))
  case shape_at(span, WholeType, resolver, reading) {
    #(typedefs.NoArrows, reading) -> #(FunctionFree, reading)
    #(typedefs.HasArrows, reading) | #(typedefs.UnknownShape, reading) ->
      evidence(value, span, scope, resolver, spend(reading), depth)
  }
}

// The shape of one part of the type girard gave the expression at `span`,
// read once per span and part for as long as the checker keeps its memo.
fn shape_at(
  span: Span,
  part: TypePart,
  resolver: Resolver(memo),
  reading: Reading(memo),
) -> #(typedefs.Shape, Reading(memo)) {
  let key = #(span.start, span.end, part)
  let memo = resolver.shape_memo(reading.memo)
  case dict.get(memo, key) {
    Ok(shape) -> #(shape, reading)
    Error(Nil) -> {
      let shape = joined_shape(resolver.types_at(span), part, resolver.shapes)
      let memo =
        resolver.with_shape_memo(reading.memo, dict.insert(memo, key, shape))
      #(shape, Reading(..reading, memo:))
    }
  }
}

// The join of one part's shape in every target's type, `UnknownShape` where
// no target types it.
fn joined_shape(
  types: List(Option(girard.Type)),
  part: TypePart,
  shapes: typedefs.Shapes,
) -> typedefs.Shape {
  case types {
    [] -> typedefs.UnknownShape
    _ ->
      list.fold_until(types, typedefs.NoArrows, fn(acc, type_) {
        case typedefs.join(acc, part_shape(type_, part, shapes)) {
          typedefs.UnknownShape -> list.Stop(typedefs.UnknownShape)
          joined -> list.Continue(joined)
        }
      })
  }
}

fn part_shape(
  type_: Option(girard.Type),
  part: TypePart,
  shapes: typedefs.Shapes,
) -> typedefs.Shape {
  case option.then(type_, type_part(_, part)) {
    Some(type_) -> typedefs.shape(type_, shapes)
    None -> typedefs.UnknownShape
  }
}

// girard's type of the expression at `span` where every target that compiles
// it typed it with the same outermost form: a function of one arity, a named
// type, a tuple or a variable. Read for that form alone.
fn type_at(resolver: Resolver(memo), span: Span) -> Option(girard.Type) {
  case resolver.types_at(span) {
    [Some(first), ..rest] ->
      case list.all(rest, fn(other) { same_form(Some(first), other) }) {
        True -> Some(first)
        False -> None
      }
    [] | [None, ..] -> None
  }
}

fn same_form(left: Option(girard.Type), right: Option(girard.Type)) -> Bool {
  case left, right {
    Some(girard.Fn(arguments: left, ..)), Some(girard.Fn(arguments: right, ..))
    -> list.length(left) == list.length(right)
    Some(girard.Named(..)), Some(girard.Named(..))
    | Some(girard.Tuple(..)), Some(girard.Tuple(..))
    | Some(girard.Var(..)), Some(girard.Var(..))
    -> True
    _, _ -> False
  }
}

fn type_part(type_: girard.Type, part: TypePart) -> Option(girard.Type) {
  case part, type_ {
    WholeType, _ -> Some(type_)
    ReturnedType, girard.Fn(return:, ..) -> Some(return)
    HoleType, girard.Fn(arguments: [hole], ..) -> Some(hole)
    ReturnedType, _ | HoleType, _ -> None
  }
}

fn evidence(
  value: ArgumentValue,
  span: Span,
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  reading: Reading(memo),
  depth: Int,
) -> #(Latent, Reading(memo)) {
  let read = fn(value, span, reading) {
    value_latent(value, span, scope, resolver, reading, depth + 1)
  }
  let read_site = fn(value, span, reading) {
    site_latent(value, span, scope, resolver, reading, depth + 1)
  }
  case value {
    types.FunctionRef(name:) ->
      case resolver.constant(name) {
        Some(latent) -> #(latent, reading)
        None -> function_latent(value, span, scope, resolver, reading, depth)
      }
    types.Closure(..) | types.Capture(..) ->
      function_latent(value, span, scope, resolver, reading, depth)
    types.LocalRef(name:) ->
      case dict.get(scope, name) {
        Ok(latent) -> #(latent, reading)
        Error(Nil) -> grounded(value, span, scope, resolver, reading, depth)
      }
    types.Choice(options:) -> read_all(options, span, read, reading)
    types.Composite(elements:) -> read_components(elements, read_site, reading)
    types.Constructed(components:, coverage: types.WholeValue, ..) ->
      read_components(components, read_site, reading)
    types.Constructed(coverage: types.PartialValue, ..) -> #(unknown(), reading)
    types.Updated(components:, ..) ->
      read_components(components, read_site, reading)
    types.CallResult(callee:, args:) | types.ReturnedOperator(callee:, args:) -> {
      let #(carried, reading) =
        carries_reading(callee, args, scope, resolver, reading)
      case carried, type_at(resolver, span) {
        Some(latent), _ -> #(latent, reading)
        None, Some(girard.Fn(..)) ->
          function_latent(value, span, scope, resolver, reading, depth)
        None, _ -> grounded(value, span, scope, resolver, reading, depth)
      }
    }
    types.ReceiverPath(..) ->
      grounded(value, span, scope, resolver, reading, depth)
    // A constructor is a function whose result holds what it is given; one
    // typed as a named type or a tuple is a value holding nothing, and an
    // unresolved type establishes neither.
    types.ConstructorRef ->
      case type_at(resolver, span) {
        Some(girard.Fn(..)) | None ->
          function_latent(value, span, scope, resolver, reading, depth)
        Some(girard.Var(..)) -> #(unknown(), reading)
        Some(girard.Named(..)) | Some(girard.Tuple(..)) -> #(
          FunctionFree,
          reading,
        )
      }
    types.OtherExpression -> #(unknown(), reading)
  }
}

fn read_all(
  values: List(ArgumentValue),
  span: Span,
  read: fn(ArgumentValue, Span, Reading(memo)) -> #(Latent, Reading(memo)),
  reading: Reading(memo),
) -> #(Latent, Reading(memo)) {
  list.fold(values, #(FunctionFree, reading), fn(acc, value) {
    let #(latent, reading) = acc
    let #(next, reading) = read(value, span, reading)
    #(join(latent, next), reading)
  })
}

fn read_components(
  components: List(types.Component),
  read: fn(ArgumentValue, Span, Reading(memo)) -> #(Latent, Reading(memo)),
  reading: Reading(memo),
) -> #(Latent, Reading(memo)) {
  list.fold(components, #(FunctionFree, reading), fn(acc, component) {
    let #(latent, reading) = acc
    let #(next, reading) = read(component.value, component.span, reading)
    #(join(latent, next), reading)
  })
}

fn grounded(
  value: ArgumentValue,
  span: Span,
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  reading: Reading(memo),
  depth: Int,
) -> #(Latent, Reading(memo)) {
  let grounding = resolver.ground(value)
  case grounding {
    GroundedValue(value: traced) ->
      value_latent(traced, span, scope, resolver, reading, depth + 1)
    GroundedFunction ->
      function_latent(value, span, scope, resolver, reading, depth)
    GroundedLatent(latent:) -> #(latent, reading)
    Ungrounded -> #(unknown(), reading)
  }
}

// A function value reaching code that may call it, and call what it returns:
// its cost with every parameter it calls receiving `[Unknown]`, and what its
// result carries.
fn function_latent(
  value: ArgumentValue,
  span: Span,
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  reading: Reading(memo),
  depth: Int,
) -> #(Latent, Reading(memo)) {
  let #(callback, reading) =
    callback_at(value, span, None, scope, resolver, reading, depth)
  #(escape(callback), reading)
}

// Callbacks

// What a callback argument costs when the callee runs it, its parameters
// receiving `positions` — `None` where the callee says nothing of them, which
// gives every parameter the callback calls `[Unknown]` — and what its result
// carries. A choice of callbacks is resolved option by option, each receiving
// the same parameters, and joined after. What cannot be lifted costs
// `[Unknown]`.
pub fn resolve_callback(
  value: ArgumentValue,
  span: Span,
  positions: Option(List(Latent)),
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  memo: memo,
) -> #(Callback, memo) {
  read_with(memo, callback_at(value, span, positions, scope, resolver, _, 0))
}

fn callback_at(
  value: ArgumentValue,
  span: Span,
  positions: Option(List(Latent)),
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  reading: Reading(memo),
  depth: Int,
) -> #(Callback, Reading(memo)) {
  use <- bool.guard(when: exhausted(reading, depth), return: #(
    unknown_callback(),
    reading,
  ))
  let reading = spend(reading)
  case value {
    types.Choice(options:) ->
      list.fold(
        options,
        #(Callback(cost: effect_term.pure(), result: FunctionFree), reading),
        fn(acc, option) {
          let #(joined, reading) = acc
          let #(callback, reading) =
            callback_at(
              option,
              span,
              positions,
              scope,
              resolver,
              reading,
              depth + 1,
            )
          #(
            Callback(
              cost: effect_term.normalize(TUnion([joined.cost, callback.cost])),
              result: join(joined.result, callback.result),
            ),
            reading,
          )
        },
      )
    types.LocalRef(name:) ->
      case dict.get(scope, name) {
        // A closure parameter called as a callback costs what it carries.
        Ok(latent) -> {
          let #(result, reading) =
            callback_result(
              value,
              span,
              positions,
              scope,
              resolver,
              reading,
              depth,
            )
          #(Callback(cost: to_term(latent), result:), reading)
        }
        Error(Nil) ->
          grounded_callback(
            value,
            span,
            positions,
            scope,
            resolver,
            reading,
            depth,
          )
      }
    types.ReceiverPath(..) ->
      grounded_callback(value, span, positions, scope, resolver, reading, depth)
    types.FunctionRef(..)
    | types.Closure(..)
    | types.Capture(..)
    | types.ReturnedOperator(..)
    | types.CallResult(..) ->
      lifted_callback(value, span, positions, scope, resolver, reading, depth)
    types.ConstructorRef -> {
      let #(result, reading) =
        constructor_result(span, positions, resolver, reading)
      #(Callback(cost: effect_term.pure(), result:), reading)
    }
    types.Composite(..)
    | types.Constructed(..)
    | types.Updated(..)
    | types.OtherExpression -> #(unknown_callback(), reading)
  }
}

// What a constructor's result carries: nothing where its type proves the
// record holds no function, else what each of its arguments carries, an
// argument nothing describes carrying `[Unknown]`.
fn constructor_result(
  span: Span,
  positions: Option(List(Latent)),
  resolver: Resolver(memo),
  reading: Reading(memo),
) -> #(Latent, Reading(memo)) {
  case type_at(resolver, span) {
    Some(girard.Fn(arguments:, ..)) ->
      case shape_at(span, ReturnedType, resolver, reading) {
        #(typedefs.NoArrows, reading) -> #(FunctionFree, reading)
        #(typedefs.HasArrows, reading) | #(typedefs.UnknownShape, reading) -> #(
          list.index_fold(arguments, FunctionFree, fn(acc, _, index) {
            join(acc, position_latent(positions, index))
          }),
          reading,
        )
      }
    _ -> #(unknown(), reading)
  }
}

fn unknown_callback() -> Callback {
  Callback(cost: effect_term.unknown(), result: unknown())
}

fn grounded_callback(
  value: ArgumentValue,
  span: Span,
  positions: Option(List(Latent)),
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  reading: Reading(memo),
  depth: Int,
) -> #(Callback, Reading(memo)) {
  let grounding = resolver.ground(value)
  case grounding {
    GroundedValue(value: traced) ->
      callback_at(traced, span, positions, scope, resolver, reading, depth + 1)
    GroundedFunction ->
      lifted_callback(value, span, positions, scope, resolver, reading, depth)
    // A parameter whose bound names its cost: what it costs is the bound.
    GroundedLatent(latent:) -> {
      let #(result, reading) =
        callback_result(value, span, positions, scope, resolver, reading, depth)
      #(Callback(cost: to_term(latent), result:), reading)
    }
    Ungrounded -> #(unknown_callback(), reading)
  }
}

fn lifted_callback(
  value: ArgumentValue,
  span: Span,
  positions: Option(List(Latent)),
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  reading: Reading(memo),
  depth: Int,
) -> #(Callback, Reading(memo)) {
  let function_type = type_at(resolver, span)
  let arity = case function_type, value {
    Some(girard.Fn(arguments:, ..)), _ -> Some(list.length(arguments))
    _, types.Closure(params:, ..) -> Some(list.length(params))
    _, types.Capture(..) -> Some(1)
    _, _ -> None
  }
  let #(positions, reading) =
    capture_positions(value, span, positions, resolver, reading)
  let #(lifted, reading) = with_memo(reading, resolver.lift(value, arity, _))
  let cost = case lifted {
    Ok(operator) -> apply_positions(operator, positions)
    Error(Nil) -> effect_term.unknown()
  }
  let #(result, reading) =
    callback_result(value, span, positions, scope, resolver, reading, depth)
  #(Callback(cost:, result:), reading)
}

// What calling the callback returns carries: nothing where its return type is
// proven to hold no function; an inline closure's tail, read in its own scope;
// `[Unknown]` for anything else.
fn callback_result(
  value: ArgumentValue,
  span: Span,
  positions: Option(List(Latent)),
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  reading: Reading(memo),
  depth: Int,
) -> #(Latent, Reading(memo)) {
  let #(returned, reading) = shape_at(span, ReturnedType, resolver, reading)
  case returned == typedefs.NoArrows, value {
    True, _ -> #(FunctionFree, reading)
    False, types.Closure(params:, ..) -> {
      let tail = resolver.closure_tail(value)
      case tail {
        None -> #(unknown(), reading)
        Some(component) ->
          tail_latent(
            component,
            params,
            positions,
            scope,
            resolver,
            reading,
            depth,
          )
      }
    }
    False, types.Capture(target: types.FunctionRef(name:), ..) -> {
      let #(carried, reading) =
        carries_reading(
          name,
          capture_arguments(value),
          dict.insert(scope, capture_hole, position_latent(positions, 0)),
          resolver,
          reading,
        )
      #(option.unwrap(carried, unknown()), reading)
    }
    False, _ -> #(unknown(), reading)
  }
}

// What a capture's own parameter receives: nothing where its type is proven to
// hold no function, as a closure's parameter reads at its own typed uses.
fn capture_positions(
  value: ArgumentValue,
  span: Span,
  positions: Option(List(Latent)),
  resolver: Resolver(memo),
  reading: Reading(memo),
) -> #(Option(List(Latent)), Reading(memo)) {
  case value {
    types.Capture(..) ->
      case shape_at(span, HoleType, resolver, reading) {
        #(typedefs.NoArrows, reading) -> #(Some([FunctionFree]), reading)
        #(typedefs.HasArrows, reading) | #(typedefs.UnknownShape, reading) -> #(
          positions,
          reading,
        )
      }
    _ -> #(positions, reading)
  }
}

// The name a capture's own parameter takes while its call is read: no Gleam
// identifier can spell it.
pub const capture_hole = "$hole"

// The arguments a capture calls its target with: the ones it was written with
// and its own parameter at the hole.
pub fn capture_arguments(value: ArgumentValue) -> List(CallArgument) {
  case value {
    types.Capture(hole:, label:, arguments:, ..) ->
      [
        types.CallArgument(
          position: hole,
          label:,
          value: types.LocalRef(capture_hole),
          span: extract.no_site,
        ),
        ..arguments
      ]
      |> list.sort(fn(left, right) {
        int.compare(left.position, right.position)
      })
    types.FunctionRef(..)
    | types.LocalRef(..)
    | types.ConstructorRef
    | types.Closure(..)
    | types.Choice(..)
    | types.ReturnedOperator(..)
    | types.CallResult(..)
    | types.ReceiverPath(..)
    | types.Constructed(..)
    | types.Updated(..)
    | types.Composite(..)
    | types.OtherExpression -> []
  }
}

// An inline closure's tail read in its own scope: each parameter receives what
// the callee passes it there.
fn tail_latent(
  tail: types.Component,
  params: List(String),
  positions: Option(List(Latent)),
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  reading: Reading(memo),
  depth: Int,
) -> #(Latent, Reading(memo)) {
  let inner =
    list.index_fold(params, scope, fn(scope, param, index) {
      dict.insert(scope, param, position_latent(positions, index))
    })
  site_latent(tail.value, tail.span, inner, resolver, reading, depth + 1)
}

fn position_latent(positions: Option(List(Latent)), index: Int) -> Latent {
  case positions {
    None -> unknown()
    Some(latents) ->
      case list.drop(latents, index) {
        [latent, ..] -> latent
        [] -> unknown()
      }
  }
}

// An operator applied to what each of its parameters receives, in order; a
// parameter past the ones stated receives `[Unknown]`, and only the parameters
// the operator's body calls contribute anything.
fn apply_positions(
  operator: EffectTerm,
  positions: Option(List(Latent)),
) -> EffectTerm {
  let arguments = option.unwrap(positions, [])
  apply_loop(effect_term.normalize(operator), arguments)
}

fn apply_loop(operator: EffectTerm, arguments: List(Latent)) -> EffectTerm {
  case operator, arguments {
    TAbs(..), [latent, ..rest] ->
      apply_loop(effect_term.normalize(TApp(operator, to_term(latent))), rest)
    TAbs(..), [] ->
      apply_loop(
        effect_term.normalize(TApp(operator, effect_term.unknown())),
        [],
      )
    TUnion(members), _ ->
      case list.any(members, effect_term.is_abstraction) {
        True ->
          effect_term.normalize(
            TUnion(list.map(members, apply_loop(_, arguments))),
          )
        False -> operator
      }
    _, _ -> operator
  }
}

// Contracts

// What a call's result carries, where the winning line for its callee
// declares it.
pub fn call_carries(
  callee: QualifiedName,
  args: List(CallArgument),
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  memo: memo,
) -> #(Option(Latent), memo) {
  read_with(memo, carries_reading(callee, args, scope, resolver, _))
}

fn carries_reading(
  callee: QualifiedName,
  args: List(CallArgument),
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  reading: Reading(memo),
) -> #(Option(Latent), Reading(memo)) {
  let #(contract, reading) = with_memo(reading, resolver.contract(callee, _))
  case contract {
    None -> #(None, reading)
    Some(contract) ->
      case contract.contract.carries {
        None -> #(None, reading)
        Some(carried) -> {
          let #(bindings, reading) =
            contract_reading(callee, contract, args, scope, resolver, reading)
          #(
            Some(
              Carries(effect_term.close(effect_term.subst(carried, bindings))),
            ),
            reading,
          )
        }
      }
  }
}

// The terms a contract's variables take at a call. A carried variable takes
// what its argument carries, a callback's variable what the callback costs
// with its parameters receiving what the line relays to them, and a
// callback's `.returns` what its result carries. A variable several bounds
// share takes the join of all of them. A variable whose argument is missing
// stays unbound.
pub fn bind_contract(
  callee: QualifiedName,
  contract: CalleeContract,
  args: List(CallArgument),
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  memo: memo,
) -> #(Dict(String, EffectTerm), memo) {
  read_with(memo, contract_reading(callee, contract, args, scope, resolver, _))
}

fn contract_reading(
  callee: QualifiedName,
  contract: CalleeContract,
  args: List(CallArgument),
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  reading: Reading(memo),
) -> #(Dict(String, EffectTerm), Reading(memo)) {
  let #(carried, reading) =
    list.fold(contract.parameters, #(dict.new(), reading), fn(acc, parameter) {
      let #(bindings, reading) = acc
      case
        parameter.kind,
        contract.reviewed,
        resolver.match(callee, parameter.bound.name, args)
      {
        CallbackKind, _, _ | _, _, None -> #(bindings, reading)
        // A written line's parameter of unknown kind gets no promise: what it
        // carries reads unknown.
        UnknownKind, False, Some(_) -> #(
          bind_all(bindings, parameter.bound, effect_term.unknown()),
          reading,
        )
        NonCallbackKind, _, Some(arg) | UnknownKind, True, Some(arg) -> {
          let #(latent, reading) =
            site_latent(arg.value, arg.span, scope, resolver, reading, 0)
          #(bind_all(bindings, parameter.bound, to_term(latent)), reading)
        }
      }
    })
  list.fold(contract.parameters, #(carried, reading), fn(acc, parameter) {
    let #(bindings, reading) = acc
    let variables = effect_term.free_vars(parameter.bound.effects)
    case
      parameter.kind,
      set.is_empty(variables),
      resolver.match(callee, parameter.bound.name, args)
    {
      CallbackKind, False, Some(arg) ->
        bind_callback(
          bindings,
          carried,
          parameter,
          arg,
          contract.contract.relays,
          scope,
          resolver,
          reading,
        )
      // A ground bound answers for the whole callback.
      CallbackKind, True, _ | CallbackKind, _, None -> #(bindings, reading)
      NonCallbackKind, _, _ | UnknownKind, _, _ -> #(bindings, reading)
    }
  })
}

fn bind_callback(
  bindings: Dict(String, EffectTerm),
  carried: Dict(String, EffectTerm),
  parameter: ContractParameter,
  arg: CallArgument,
  relays: List(types.Relay),
  scope: Dict(String, Latent),
  resolver: Resolver(memo),
  reading: Reading(memo),
) -> #(Dict(String, EffectTerm), Reading(memo)) {
  let variables = effect_term.free_vars(parameter.bound.effects)
  case parameter.operator_positions {
    // An operator bound applied in the term keeps its application.
    Some(positions) -> {
      let #(lifted, reading) =
        with_memo(reading, resolver.lift_operator(arg.value, positions, _))
      let operator = case lifted {
        Ok(operator) -> operator
        Error(Nil) -> effect_term.unknown()
      }
      #(bind_all(bindings, parameter.bound, operator), reading)
    }
    None -> {
      let positions =
        list.find(relays, fn(relay) { set.contains(variables, relay.callback) })
        |> option.from_result
        |> option.map(relayed_positions(_, carried))
      let #(callback, reading) =
        callback_at(arg.value, arg.span, positions, scope, resolver, reading, 0)
      let bindings = bind_all(bindings, parameter.bound, callback.cost)
      #(
        set.fold(variables, bindings, fn(bindings, variable) {
          insert_joined(
            bindings,
            variable <> types.returns_suffix,
            to_term(callback.result),
          )
        }),
        reading,
      )
    }
  }
}

// What each parameter of a relayed callback receives: the carried latent the
// relay maps to it, or `[Unknown]` at an unmapped position.
fn relayed_positions(
  relay: types.Relay,
  carried: Dict(String, EffectTerm),
) -> List(Latent) {
  list.map(relay.positions, fn(position) {
    case
      option.then(position, fn(variable) {
        dict.get(carried, variable) |> option.from_result
      })
    {
      Some(term) -> Carries(term)
      None -> unknown()
    }
  })
}

fn bind_all(
  bindings: Dict(String, EffectTerm),
  bound: ParamBound,
  term: EffectTerm,
) -> Dict(String, EffectTerm) {
  effect_term.free_vars(bound.effects)
  |> set.fold(bindings, fn(bindings, variable) {
    insert_joined(bindings, variable, term)
  })
}

// Bind `variable` to `term`, joined with what it is already bound to.
pub fn insert_joined(
  bindings: Dict(String, EffectTerm),
  variable: String,
  term: EffectTerm,
) -> Dict(String, EffectTerm) {
  dict.upsert(bindings, variable, fn(existing) {
    case existing {
      None -> term
      Some(existing) -> effect_term.normalize(TUnion([existing, term]))
    }
  })
}
