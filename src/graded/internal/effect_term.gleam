//// Operations over `EffectTerm` — the small lambda-calculus-with-union that
//// underlies graded's effect representation (the type itself lives in
//// `types.gleam` to avoid an import cycle). `EffectSet` is the *ground normal
//// form*: a fully-resolved term reduces back to one, and that is the only
//// representation the subset check and the knowledge base compare against.
////
//// The interesting capability is second-order effect polymorphism: a `TAbs`
//// is an effect *operator* (kind `Eff -> Eff`) that `TApp` applies to an
//// argument effect and `normalize` beta-reduces. See
//// docs/second-order-effects.md for the design and the property suite.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/set.{type Set}
import gleam/string
import graded/internal/types.{
  type EffectSet, type EffectTerm, Polymorphic, Specific, TAbs, TApp, TLabels,
  TTop, TUnion, TVar, Wildcard,
}

/// Reduction budget. Beta-reduction of finite, non-recursive terms always
/// terminates (call-graph recursion is guarded elsewhere by the `visited`
/// set), so this is only a backstop against a pathological input. Exhausting
/// it collapses to `[Unknown]` — the same conservative fallback as a stuck
/// application, so the checker stays sound rather than looping.
const default_fuel = 1_000_000

/// The pure (empty) effect term.
pub fn pure() -> EffectTerm {
  TLabels(set.new())
}

/// The `[Unknown]` term — the conservative collapse for anything unresolvable.
pub fn unknown() -> EffectTerm {
  TLabels(set.from_list(["Unknown"]))
}

// ---------------------------------------------------------------------------
// Bridges to/from the ground normal form
// ---------------------------------------------------------------------------

/// Lift an `EffectSet` into an `EffectTerm`. Total and exact.
pub fn from_effect_set(effect_set: EffectSet) -> EffectTerm {
  case effect_set {
    Wildcard -> TTop
    Specific(labels) -> TLabels(labels)
    Polymorphic(labels, variables) -> {
      // Already flat (one label set + bare variables, no redexes) — canonicalise
      // directly rather than running the full reduce pipeline.
      let var_terms = variables |> set.to_list() |> list.map(TVar)
      flatten_union([TLabels(labels), ..var_terms])
    }
  }
}

/// Reduce a term to its ground normal form. Leftover free variables become
/// `Polymorphic` variables; any residual (stuck) application collapses to
/// `[Unknown]`. Centralising the stuck-term collapse here is what keeps
/// `check` sound — a violation is never silently dropped.
pub fn to_effect_set(term: EffectTerm) -> EffectSet {
  term_to_set(normalize(term))
}

fn term_to_set(normalized: EffectTerm) -> EffectSet {
  case normalized {
    TTop -> Wildcard
    TLabels(labels) -> Specific(labels)
    TVar(name) -> Polymorphic(set.new(), set.from_list([name]))
    // A stuck application or a bare operator can't be a ground set; both
    // collapse conservatively to [Unknown].
    TApp(_, _) -> Specific(set.from_list(["Unknown"]))
    TAbs(_, _) -> Specific(set.from_list(["Unknown"]))
    TUnion(members) ->
      list.fold(members, types.empty(), fn(acc, member) {
        types.union(acc, term_to_set(member))
      })
  }
}

// ---------------------------------------------------------------------------
// Free variables
// ---------------------------------------------------------------------------

/// The free effect variables of a term (a `TAbs` binds its parameter).
pub fn free_vars(term: EffectTerm) -> Set(String) {
  case term {
    TLabels(_) -> set.new()
    TTop -> set.new()
    TVar(name) -> set.from_list([name])
    TApp(operator, arg) -> set.union(free_vars(operator), free_vars(arg))
    TUnion(terms) ->
      list.fold(terms, set.new(), fn(acc, t) { set.union(acc, free_vars(t)) })
    TAbs(param, body) -> set.delete(free_vars(body), param)
  }
}

// ---------------------------------------------------------------------------
// Capture-avoiding substitution
// ---------------------------------------------------------------------------

/// Substitute effect variables for terms, capture-avoiding. Bindings may map
/// a variable to an operator (`TAbs`), which is what enables nested/second-
/// order resolution. Variables not in `bindings` are left free.
pub fn subst(term: EffectTerm, bindings: Dict(String, EffectTerm)) -> EffectTerm {
  case term {
    TLabels(_) -> term
    TTop -> term
    TVar(name) ->
      case dict.get(bindings, name) {
        Ok(replacement) -> replacement
        Error(Nil) -> term
      }
    TApp(operator, arg) -> TApp(subst(operator, bindings), subst(arg, bindings))
    TUnion(terms) -> TUnion(list.map(terms, subst(_, bindings)))
    TAbs(param, body) -> subst_abs(param, body, bindings)
  }
}

fn subst_abs(
  param: String,
  body: EffectTerm,
  bindings: Dict(String, EffectTerm),
) -> EffectTerm {
  // The bound parameter shadows any binding of the same name inside the body.
  let inner = dict.delete(bindings, param)
  // Nothing left to substitute (the common case for a beta-step's singleton
  // binding of the bound parameter) — return unchanged.
  use <- bool.guard(when: dict.is_empty(inner), return: TAbs(param, body))
  // Free variables that the substitution could drag into the body — these are
  // the ones at risk of capture by `param`.
  let body_fv = free_vars(body)
  let incoming =
    dict.fold(inner, set.new(), fn(acc, key, value) {
      case set.contains(body_fv, key) {
        True -> set.union(acc, free_vars(value))
        False -> acc
      }
    })
  case set.contains(incoming, param) {
    // No capture possible: substitute under the binder as-is.
    False -> TAbs(param, subst(body, inner))
    // `param` would capture a free variable being substituted in — alpha-
    // rename the binder to something fresh first.
    True -> {
      let avoid = set.union(incoming, body_fv)
      let renamed_param = fresh(param, avoid)
      let renamed_body =
        subst(body, dict.from_list([#(param, TVar(renamed_param))]))
      TAbs(renamed_param, subst(renamed_body, inner))
    }
  }
}

fn fresh(base: String, avoid: Set(String)) -> String {
  fresh_loop(base, avoid, 0)
}

fn fresh_loop(base: String, avoid: Set(String), n: Int) -> String {
  let candidate = base <> int.to_string(n)
  case set.contains(avoid, candidate) {
    True -> fresh_loop(base, avoid, n + 1)
    False -> candidate
  }
}

// ---------------------------------------------------------------------------
// Normalization (beta + union laws)
// ---------------------------------------------------------------------------

/// Reduce a term to normal form: beta-reduce every applied operator, and
/// flatten/dedup/absorb unions into a canonical shape. Idempotent.
pub fn normalize(term: EffectTerm) -> EffectTerm {
  let #(result, _fuel) = reduce(term, default_fuel)
  result
}

/// Like `normalize` but reports fuel exhaustion as `Error` instead of
/// collapsing to `[Unknown]`. Used by the termination property test to assert
/// that finite terms never hit the budget; production code uses `normalize`.
pub fn normalize_bounded(term: EffectTerm, fuel: Int) -> Result(EffectTerm, Nil) {
  let #(result, remaining) = reduce(term, fuel)
  case remaining < 0 {
    True -> Error(Nil)
    False -> Ok(result)
  }
}

fn reduce(term: EffectTerm, fuel: Int) -> #(EffectTerm, Int) {
  case fuel <= 0 {
    // Negative remaining is the exhaustion sentinel; it propagates because
    // any further `reduce` call sees `fuel <= 0` and stays negative.
    True -> #(unknown(), -1)
    False ->
      case term {
        TLabels(_) -> #(term, fuel)
        TTop -> #(term, fuel)
        TVar(_) -> #(term, fuel)
        TAbs(param, body) -> {
          let #(reduced_body, fuel1) = reduce(body, fuel)
          #(TAbs(param, reduced_body), fuel1)
        }
        TApp(operator, arg) -> {
          let #(reduced_fn, fuel1) = reduce(operator, fuel - 1)
          let #(reduced_arg, fuel2) = reduce(arg, fuel1)
          case reduced_fn {
            // Beta-redex: substitute and keep reducing.
            TAbs(param, body) -> {
              let substituted =
                subst(body, dict.from_list([#(param, reduced_arg)]))
              reduce(substituted, fuel2 - 1)
            }
            // Stuck (operator is a free variable) or otherwise irreducible.
            _ -> #(TApp(reduced_fn, reduced_arg), fuel2)
          }
        }
        TUnion(terms) -> {
          let #(reduced, fuel1) = reduce_each(terms, fuel)
          #(flatten_union(reduced), fuel1)
        }
      }
  }
}

fn reduce_each(terms: List(EffectTerm), fuel: Int) -> #(List(EffectTerm), Int) {
  let #(acc, final_fuel) =
    list.fold(terms, #([], fuel), fn(state, t) {
      let #(done, remaining) = state
      let #(reduced, remaining1) = reduce(t, remaining)
      #([reduced, ..done], remaining1)
    })
  #(list.reverse(acc), final_fuel)
}

/// Combine already-normalized members into a canonical union: merge all label
/// sets into one, absorb `TTop`, drop pure, flatten nested unions, and sort +
/// dedup the remaining (variable/application) members so that union is
/// commutative, associative, and idempotent up to `==`.
fn flatten_union(members: List(EffectTerm)) -> EffectTerm {
  let flat =
    list.flat_map(members, fn(member) {
      case member {
        TUnion(inner) -> inner
        _ -> [member]
      }
    })
  case list.any(flat, fn(m) { m == TTop }) {
    True -> TTop
    False -> {
      let #(label_members, other_members) =
        list.partition(flat, fn(m) {
          case m {
            TLabels(_) -> True
            _ -> False
          }
        })
      let merged_labels =
        list.fold(label_members, set.new(), fn(acc, m) {
          case m {
            TLabels(labels) -> set.union(acc, labels)
            _ -> acc
          }
        })
      // Decorate each member with its structural key once, then sort and drop
      // adjacent duplicates — `term_key` (a full recursive render) is computed
      // exactly once per member rather than on every comparison and again to
      // dedup.
      let others =
        other_members
        |> list.map(fn(m) { #(term_key(m), m) })
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> dedup_adjacent()
        |> list.map(fn(pair) { pair.1 })
      let label_part = case set.is_empty(merged_labels) {
        True -> []
        False -> [TLabels(merged_labels)]
      }
      case list.append(label_part, others) {
        [] -> pure()
        [single] -> single
        all -> TUnion(all)
      }
    }
  }
}

/// Drop adjacent duplicates (by key) from a key-sorted list.
fn dedup_adjacent(
  keyed: List(#(String, EffectTerm)),
) -> List(#(String, EffectTerm)) {
  keyed
  |> list.fold([], fn(acc, pair) {
    case acc {
      [#(previous, _), ..] if previous == pair.0 -> acc
      _ -> [pair, ..acc]
    }
  })
  |> list.reverse
}

/// A canonical structural key, used to order and dedup union members so that
/// structurally-equal terms compare equal regardless of how they were built.
/// (Alpha-equivalence of operators is intentionally not normalized; variable
/// names in practice are parameter-derived and stable.)
fn term_key(term: EffectTerm) -> String {
  case term {
    TTop -> "T"
    TLabels(labels) ->
      "L["
      <> {
        labels |> set.to_list() |> list.sort(string.compare) |> string.join(",")
      }
      <> "]"
    TVar(name) -> "V(" <> name <> ")"
    TApp(operator, arg) ->
      "A(" <> term_key(operator) <> " " <> term_key(arg) <> ")"
    TAbs(param, body) -> "F(" <> param <> "." <> term_key(body) <> ")"
    TUnion(terms) ->
      "U("
      <> {
        terms
        |> list.map(term_key)
        |> list.sort(string.compare)
        |> string.join("|")
      }
      <> ")"
  }
}
