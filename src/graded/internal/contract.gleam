// What a written `assume` line's bounds and latent-effect clauses mean once
// the function's signature is read: which bounds name a callback's cost and
// which name what an argument carries, and which uses of them the rules forbid.
//
// Kinds are not the parser's to decide: whether a parameter is a callback is
// read off its declared type, through any alias, after every signature and
// type definition of the run is known.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string
import graded/internal/effect_term
import graded/internal/signatures.{type SignatureRegistry}
import graded/internal/typedefs.{type Kinds}
import graded/internal/types.{
  type AssumeAnnotation, type BoundKind, type ParamBound, CallbackKind,
  FunctionAssume, ModuleAssume, NonCallbackKind, QualifiedName, UnknownKind,
}

// Kinds

// One bound of a line, with its parameter's kind and, for a callback whose type
// was read, how many parameters it takes.
pub type ResolvedBound {
  ResolvedBound(bound: ParamBound, kind: BoundKind, arity: Option(Int))
}

// Every bound of a line, resolved against the run's signatures and types.
pub fn resolve_bounds(
  assume: AssumeAnnotation,
  registry: SignatureRegistry,
) -> List(ResolvedBound) {
  let parameters = case assume.target {
    FunctionAssume(function) ->
      signatures.lookup_callbacks(
        registry,
        QualifiedName(module: assume.module, function:),
      )
    ModuleAssume -> None
  }
  list.map(assume.params, fn(bound) {
    let #(kind, arity) = parameter_bound_kind(bound, parameters, registry.kinds)
    ResolvedBound(bound:, kind:, arity:)
  })
}

// The uses of a line's bounds the rules forbid, against the run's signatures
// and types.
pub fn line_violations(
  assume: AssumeAnnotation,
  registry: SignatureRegistry,
) -> List(ContractViolation) {
  violations(assume, resolve_bounds(assume, registry))
}

// The kind of a parameter read off its signature entry.
pub fn kind_of_parameter(
  parameter: signatures.ParameterInfo,
  kinds: Kinds,
) -> BoundKind {
  parameter_kind(parameter, kinds).0
}

// The kind of one bound's parameter against a signature that may be missing.
pub fn parameter_bound_kind(
  bound: ParamBound,
  parameters: Option(List(signatures.ParameterInfo)),
  kinds: Kinds,
) -> #(BoundKind, Option(Int)) {
  // A field bound names a callable field's cost, matched as it always was.
  use <- bool.guard(when: string.contains(bound.name, "."), return: #(
    CallbackKind,
    None,
  ))
  case parameters {
    None -> #(UnknownKind, None)
    Some(parameters) ->
      case signatures.parameter_named(parameters, bound.name) {
        None -> #(UnknownKind, None)
        Some(parameter) -> parameter_kind(parameter, kinds)
      }
  }
}

fn parameter_kind(
  parameter: signatures.ParameterInfo,
  kinds: Kinds,
) -> #(BoundKind, Option(Int)) {
  let kind = case parameter.annotation {
    Some(annotation) -> typedefs.function_kind(annotation, kinds)
    None -> typedefs.UnresolvedFunctionKind
  }
  case parameter.is_fn_typed, kind {
    _, typedefs.IsFunction(arity:) -> #(CallbackKind, Some(arity))
    True, typedefs.NotFunction | True, typedefs.UnresolvedFunctionKind -> #(
      CallbackKind,
      None,
    )
    False, typedefs.NotFunction -> #(NonCallbackKind, None)
    False, typedefs.UnresolvedFunctionKind -> #(UnknownKind, None)
  }
}

// Violations
//
// A use the rules forbid makes the whole line unreadable: in the project's own
// spec it is an error, and in a dependency's spec the line is refused and its
// path charged the wildcard.

pub type ContractViolation {
  // The line's effect term or returned operator charges `variable`, which names
  // what the argument at `parameter` carries; `runs` is what charges it.
  CarriedVariableCharged(variable: String, parameter: String)
  // `.returns` names what a callback's result carries, and `parameter` is not a
  // callback.
  ResultOfNonCallback(variable: String, parameter: String)
  // A `relay` maps values into `parameter`, which is not a callback.
  RelayIntoNonCallback(callback: String, parameter: String)
  // A `relay` maps `written` positions into a callback that takes `arity`.
  RelayArityMismatch(callback: String, arity: Int, written: Int)
  // `runs` or a `relay` position names `variable`, the cost of the callback at
  // `parameter` rather than what an argument carries.
  CallbackCostCarried(variable: String, parameter: String)
  // `variable` is shared by bounds that cannot share it: a callback's and a
  // carried one, or callbacks of different arity.
  IncompatibleSharing(variable: String)
}

pub fn violations(
  assume: AssumeAnnotation,
  resolved: List(ResolvedBound),
) -> List(ContractViolation) {
  let binders = binders_by_variable(resolved)
  let binders_of = fn(variable) {
    dict.get(binders, variable) |> option.from_result |> option.unwrap([])
  }
  let carried_parameter = fn(variable) {
    binders_of(variable)
    |> list.find(fn(binder) { binder.kind == NonCallbackKind })
    |> option.from_result
    |> option.map(fn(binder) { binder.bound.name })
  }
  let cost_parameter = fn(variable) {
    binders_of(variable)
    |> list.find(fn(binder) { binder.kind == CallbackKind })
    |> option.from_result
    |> option.map(fn(binder) { binder.bound.name })
  }
  let charged =
    [assume.effects, assume.returns]
    |> option.values
    |> list.fold(set.new(), fn(acc, term) {
      set.union(acc, effect_term.free_vars(term))
    })
    |> set.to_list
    |> list.sort(string.compare)
  let charged_violations =
    list.filter_map(charged, fn(variable) {
      carried_parameter(variable)
      |> option.map(CarriedVariableCharged(variable, _))
      |> option.to_result(Nil)
    })
  let contract = assume.contract
  let result_violations = case contract.carries {
    None -> []
    Some(carried) ->
      effect_term.free_vars(carried)
      |> set.to_list
      |> list.sort(string.compare)
      |> list.filter_map(fn(variable) {
        case string.ends_with(variable, types.returns_suffix) {
          False -> Error(Nil)
          True ->
            string.drop_end(variable, string.length(types.returns_suffix))
            |> carried_parameter
            |> option.map(ResultOfNonCallback(variable, _))
            |> option.to_result(Nil)
        }
      })
  }
  let relay_violations =
    list.flat_map(contract.relays, fn(relay) {
      let into_carried = case carried_parameter(relay.callback) {
        Some(parameter) -> [RelayIntoNonCallback(relay.callback, parameter)]
        None -> []
      }
      let written = list.length(relay.positions)
      let arity =
        binders_of(relay.callback)
        |> list.filter_map(fn(binder) { option.to_result(binder.arity, Nil) })
        |> list.filter(fn(arity) { arity != written })
        |> list.map(RelayArityMismatch(relay.callback, _, written))
      list.append(into_carried, list.unique(arity))
    })
  let carried_names =
    list.append(
      option.unwrap(contract.runs, []),
      list.flat_map(contract.relays, fn(relay) {
        option.values(relay.positions)
      }),
    )
    |> list.unique
  let cost_violations =
    list.filter_map(carried_names, fn(variable) {
      cost_parameter(variable)
      |> option.map(CallbackCostCarried(variable, _))
      |> option.to_result(Nil)
    })
  let sharing_violations =
    binders
    |> dict.to_list
    |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
    |> list.filter_map(fn(entry) {
      let #(variable, binders) = entry
      let kinds = list.map(binders, fn(binder) { binder.kind })
      let arities =
        binders
        |> list.filter_map(fn(binder) { option.to_result(binder.arity, Nil) })
        |> list.unique
      case
        list.contains(kinds, CallbackKind)
        && list.contains(kinds, NonCallbackKind),
        list.length(arities) > 1
      {
        False, False -> Error(Nil)
        True, _ | _, True -> Ok(IncompatibleSharing(variable))
      }
    })
  list.flatten([
    charged_violations,
    result_violations,
    relay_violations,
    cost_violations,
    sharing_violations,
  ])
}

// Each variable a bound's payload names, with every bound that names it.
fn binders_by_variable(
  resolved: List(ResolvedBound),
) -> Dict(String, List(ResolvedBound)) {
  list.fold(resolved, dict.new(), fn(acc, binder) {
    effect_term.free_vars(binder.bound.effects)
    |> set.fold(acc, fn(acc, variable) {
      dict.upsert(acc, variable, fn(existing) {
        list.append(option.unwrap(existing, []), [binder])
      })
    })
  })
}

// `violation` with each parameter it names stated through `parameter` and
// each variable through `variable`.
pub fn stated_in(
  violation: ContractViolation,
  parameter: fn(String) -> String,
  variable: fn(String) -> String,
) -> ContractViolation {
  case violation {
    CarriedVariableCharged(variable: v, parameter: p) ->
      CarriedVariableCharged(variable: variable(v), parameter: parameter(p))
    ResultOfNonCallback(variable: v, parameter: p) ->
      ResultOfNonCallback(variable: variable(v), parameter: parameter(p))
    RelayIntoNonCallback(callback:, parameter: p) ->
      RelayIntoNonCallback(
        callback: variable(callback),
        parameter: parameter(p),
      )
    RelayArityMismatch(callback:, arity:, written:) ->
      RelayArityMismatch(callback: variable(callback), arity:, written:)
    CallbackCostCarried(variable: v, parameter: p) ->
      CallbackCostCarried(variable: variable(v), parameter: parameter(p))
    IncompatibleSharing(variable: v) -> IncompatibleSharing(variable(v))
  }
}

pub fn describe(violation: ContractViolation) -> String {
  case violation {
    CarriedVariableCharged(variable:, parameter:) ->
      "`"
      <> variable
      <> "` names what `"
      <> parameter
      <> "` carries, which the effect term cannot charge; list it in `runs` instead"
    ResultOfNonCallback(variable:, parameter:) ->
      "`"
      <> variable
      <> "` names what a callback's result carries, and `"
      <> parameter
      <> "` is not a callback"
    RelayIntoNonCallback(callback:, parameter:) ->
      "`relay : "
      <> callback
      <> "(..)` maps values into `"
      <> parameter
      <> "`, which is not a callback"
    RelayArityMismatch(callback:, arity:, written:) ->
      "`relay : "
      <> callback
      <> "(..)` maps "
      <> int.to_string(written)
      <> " positions into a callback that takes "
      <> int.to_string(arity)
    CallbackCostCarried(variable:, parameter:) ->
      "`"
      <> variable
      <> "` is the cost of the callback `"
      <> parameter
      <> "`, not what an argument carries"
    IncompatibleSharing(variable:) ->
      "`"
      <> variable
      <> "` is shared by bounds that cannot share it: a callback's and a carried one, or callbacks of different arity"
  }
}

// Bounds that mean nothing: a bound on a parameter that is not a callback names
// what that argument carries, so only a single variable is a meaning it can
// have.
pub fn meaningless_bounds(resolved: List(ResolvedBound)) -> List(String) {
  list.filter_map(resolved, fn(binder) {
    case binder.kind, binder.bound.effects {
      NonCallbackKind, types.TVar(_) -> Error(Nil)
      NonCallbackKind, _ -> Ok(binder.bound.name)
      CallbackKind, _ | UnknownKind, _ -> Error(Nil)
    }
  })
}
