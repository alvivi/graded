// Operations over `EffectTerm` — the small lambda-calculus-with-union that
// underlies graded's effect representation (the type itself lives in
// `types.gleam` to avoid an import cycle). `EffectSet` is the *ground normal
// form*: a fully-resolved term reduces back to one, and that is the only
// representation the subset check and the knowledge base compare against.
//
// The interesting capability is second-order effect polymorphism: a `TAbs`
// is an effect *operator* (kind `Eff -> Eff`) that `TApp` applies to an
// argument effect and `normalize` beta-reduces. See
// docs/SECOND_ORDER_EFFECTS.md for the design and the property suite.

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

// Canonical terms
//
// The two distinguished ground terms every caller needs: the empty (pure)
// effect and the `[Unknown]` collapse that unresolvable paths funnel into.

// The pure (empty) effect term.
pub fn pure() -> EffectTerm {
  TLabels(set.new())
}

// The `[Unknown]` term — the conservative collapse for anything unresolvable.
pub fn unknown() -> EffectTerm {
  TLabels(set.from_list([types.unknown_label]))
}

// Reserved prefix for internal sentinel `TVar` names (Fix D). `$` is
// un-representable in a Gleam identifier, so a sentinel var can never coincide
// with a variable read from source. `checker` mints sentinels with this prefix
// while inferring a producer's returned-operator summary and renames them back
// before serialization; `annotation` reserves it on parse so a forged token in a
// loaded `.graded` grounds to `[Unknown]` rather than minting one. The two uses
// must agree, so the prefix lives here rather than being duplicated per module.
pub const sentinel_prefix = "$op$"

// Bridges to/from the ground normal form
//
// `EffectSet` is the representation the rest of graded compares against;
// these conversions lift a set into the term calculus and, after
// normalization, collapse a term back down to one.

// Lift an `EffectSet` into an `EffectTerm`. Total and exact.
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

// Reduce a term to its ground normal form. Leftover free variables become
// `Polymorphic` variables; any residual (stuck) application collapses to
// `[Unknown]`. Centralising the stuck-term collapse here is what keeps
// `check` sound — a violation is never silently dropped.
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
    TApp(_, _) -> Specific(set.from_list([types.unknown_label]))
    TAbs(_, _) -> Specific(set.from_list([types.unknown_label]))
    TUnion(members) ->
      list.fold(members, types.empty(), fn(acc, member) {
        types.union(acc, term_to_set(member))
      })
  }
}

// Free variables
//
// Which effect variables a term leaves unbound — substitution consults this
// to detect capture, and leftover free variables surface as `Polymorphic`.

// The free effect variables of a term (a `TAbs` binds its parameter).
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

// Whether a term binds every effect variable it mentions. A ground term means
// the same thing wherever it is read, which is what lets one be trusted without
// the substitution a free variable would otherwise need.
pub fn is_ground(term: EffectTerm) -> Bool {
  set.is_empty(free_vars(term))
}

// Capture-avoiding substitution
//
// Replace effect variables with terms without letting a binder capture an
// incoming free variable. This is the engine behind beta-reduction, so its
// correctness is what makes normalization meaning-preserving.

// Substitute effect variables for terms, capture-avoiding. Bindings may map
// a variable to an operator (`TAbs`), which is what enables nested/second-
// order resolution. Variables not in `bindings` are left free.
pub fn subst(
  term: EffectTerm,
  bindings: Dict(String, EffectTerm),
) -> EffectTerm {
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

// Normalization (beta + union laws)
//
// Reduce a term to its canonical shape: beta-reduce every applied operator
// and flatten/dedup/absorb unions, under a fuel budget so a pathological
// input degrades to `[Unknown]` instead of looping.

// Reduction budget. Beta-reduction of finite, non-recursive terms always
// terminates (call-graph recursion is guarded elsewhere by the `visited`
// set), so this is only a backstop against a pathological input. Exhausting
// it collapses to `[Unknown]` — the same conservative fallback as a stuck
// application, so the checker stays sound rather than looping.
const default_fuel = 1_000_000

// Reduce a term to normal form: beta-reduce every applied operator, and
// flatten/dedup/absorb unions into a canonical shape. Idempotent.
pub fn normalize(term: EffectTerm) -> EffectTerm {
  let #(result, _fuel) = reduce(term, default_fuel)
  result
}

// Like `normalize` but reports fuel exhaustion as `Error` instead of
// collapsing to `[Unknown]`. Used by the termination property test to assert
// that finite terms never hit the budget; production code uses `normalize`.
pub fn normalize_bounded(
  term: EffectTerm,
  fuel: Int,
) -> Result(EffectTerm, Nil) {
  let #(result, remaining) = reduce(term, fuel)
  case remaining < 0 {
    True -> Error(Nil)
    False -> Ok(result)
  }
}

fn reduce(term: EffectTerm, fuel: Int) -> #(EffectTerm, Int) {
  // Negative remaining is the exhaustion sentinel; it propagates because any
  // further `reduce` call sees `fuel <= 0` and stays negative.
  use <- bool.guard(when: fuel <= 0, return: #(unknown(), -1))
  case term {
    TLabels(_) -> #(term, fuel)
    TTop -> #(term, fuel)
    TVar(_) -> #(term, fuel)
    TAbs(param, body) -> {
      let #(reduced_body, fuel1) = reduce(body, fuel)
      #(TAbs(param, reduced_body), fuel1)
    }
    TApp(operator, arg) -> reduce_app(operator, arg, fuel)
    TUnion(terms) -> {
      let #(reduced, fuel1) = reduce_each(terms, fuel)
      #(flatten_union(reduced), fuel1)
    }
  }
}

// Reduce an application: reduce both sides, then beta-reduce if the operator
// became an abstraction, else leave it stuck.
fn reduce_app(
  operator: EffectTerm,
  arg: EffectTerm,
  fuel: Int,
) -> #(EffectTerm, Int) {
  let #(reduced_fn, fuel1) = reduce(operator, fuel - 1)
  let #(reduced_arg, fuel2) = reduce(arg, fuel1)
  case reduced_fn {
    // Beta-redex: substitute and keep reducing.
    TAbs(param, body) ->
      reduce(subst(body, dict.from_list([#(param, reduced_arg)])), fuel2 - 1)
    // Application distributes over a union *of operators*:
    // `(f ⊔ g)(x) → f(x) ⊔ g(x)`, exact when every member is an abstraction.
    // This is what lets a producer that returns one of several operators —
    // `case … { _ -> f  _ -> g }` — resolve when its result is applied.
    //
    // We only distribute when *all* members are abstractions. A mixed union
    // (a label set or free variable alongside an operator) is ill-kinded as an
    // operator; distributing would push the non-operator member into operator
    // position, where it goes stuck and collapses to `[Unknown]` — silently
    // dropping its concrete labels (unsound). So a mixed union stays stuck as a
    // whole, exactly the conservative `[Unknown]` the old code produced. (A
    // `TTop` member can't occur: `flatten_union` absorbs the union to `TTop`
    // before we apply it, so `reduced_fn` would be `TTop`, not a union.)
    TUnion(members) ->
      case list.all(members, is_abstraction) {
        True -> {
          let applied =
            TUnion(list.map(members, fn(m) { TApp(m, reduced_arg) }))
          reduce(applied, fuel2 - 1)
        }
        False -> #(TApp(reduced_fn, reduced_arg), fuel2)
      }
    // Stuck (operator is a free variable) or otherwise irreducible.
    _ -> #(TApp(reduced_fn, reduced_arg), fuel2)
  }
}

fn is_abstraction(term: EffectTerm) -> Bool {
  case term {
    TAbs(_, _) -> True
    _ -> False
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

// Combine already-normalized members into a canonical union: merge all label
// sets into one, absorb `TTop`, drop pure, flatten nested unions, and sort +
// dedup the remaining (variable/application) members so that union is
// commutative, associative, and idempotent up to `==`.
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

// Drop adjacent duplicates (by key) from a key-sorted list.
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

// A canonical structural key, used to order and dedup union members so that
// structurally-equal terms compare equal regardless of how they were built.
// (Alpha-equivalence of operators is intentionally not normalized; variable
// names in practice are parameter-derived and stable.)
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

// Comparison
//
// Ordering and equality *on terms*, as opposed to on the ground `EffectSet`
// they reduce to. Collapsing to a set first is unsound for anything that stays
// residual: every stuck application reduces to `[Unknown]`, so `action([cb])`
// and `action([Stdout])` would compare equal. These relations keep the term
// structure and are conservative — they can reject a declaration that is
// genuinely a superset in a way the structure does not show, never accept one
// that is not.

// Reserved prefix for the depth-indexed binder names alpha-canonicalization
// mints. `$` is un-representable in a Gleam identifier, so a canonical name can
// never coincide with a variable read from source or with `sentinel_prefix`.
const binder_prefix = "$db$"

// True iff two terms are equal up to the names of their bound variables. Free
// variables are compared by name — they are the producer's own parameters and
// mean the same thing on both sides.
pub fn alpha_equivalent(a: EffectTerm, b: EffectTerm) -> Bool {
  alpha_canonical(a) == alpha_canonical(b)
}

// Rename an operator's outermost binder, capture-avoiding. `subst` cannot do
// this: `subst_abs` deletes the bound name from the bindings by design, so
// substituting the binder's own name is a no-op. Anything that is not an
// abstraction is returned unchanged.
pub fn rename_binder(term: EffectTerm, to name: String) -> EffectTerm {
  case term {
    TAbs(param, body) ->
      TAbs(name, subst(body, dict.from_list([#(param, TVar(name))])))
    TLabels(_) | TTop | TVar(_) | TApp(_, _) | TUnion(_) -> term
  }
}

// True iff `actual` is contained in `declared` as *terms*: a total relation
// over every `EffectTerm` variant, defined so that neither side has to be
// ground. The wildcard absorbs everything; unions are compared member-wise;
// operators are compared under aligned binders; and two residual applications
// match only when they are alpha-equivalent.
pub fn operator_subset(actual: EffectTerm, declared: EffectTerm) -> Bool {
  subset_normalized(normalize(actual), normalize(declared))
}

// The relation itself, over already-normalized terms. The case order is
// load-bearing: the wildcard arms come first so they absorb before anything
// partitions, and both union arms precede the operator/non-operator mismatch
// arm so a union of operators is not read as an arity mismatch.
fn subset_normalized(actual: EffectTerm, declared: EffectTerm) -> Bool {
  case declared, actual {
    // The author declined to constrain: anything is within budget.
    TTop, _ -> True
    // An unconstrained actual against a finite declared budget cannot be
    // proved, mirroring `types.is_subset`'s own wildcard arm.
    _, TTop -> False
    TUnion(members), _ -> union_declared_subset(actual, members)
    TLabels(_), TUnion(members)
    | TVar(_), TUnion(members)
    | TApp(_, _), TUnion(members)
    | TAbs(_, _), TUnion(members)
    -> list.all(members, subset_normalized(_, declared))
    TAbs(d_param, d_body), TAbs(a_param, a_body) ->
      abs_subset(a_param, a_body, d_param, d_body)
    // Arity mismatch, in either direction.
    TAbs(_, _), TLabels(_)
    | TAbs(_, _), TVar(_)
    | TAbs(_, _), TApp(_, _)
    | TLabels(_), TAbs(_, _)
    | TVar(_), TAbs(_, _)
    | TApp(_, _), TAbs(_, _)
    -> False
    // Two residual applications: nothing weaker than alpha-equivalence, or
    // `action([cb])` would pass against `action([Stdout])`.
    TApp(_, _), TApp(_, _) -> alpha_equivalent(actual, declared)
    // A residual application against a ground budget, or the reverse: the
    // structure gives no evidence either way, so reject conservatively.
    TApp(_, _), TLabels(_)
    | TApp(_, _), TVar(_)
    | TLabels(_), TApp(_, _)
    | TVar(_), TApp(_, _)
    -> False
    TLabels(_), TLabels(_)
    | TLabels(_), TVar(_)
    | TVar(_), TLabels(_)
    | TVar(_), TVar(_)
    -> types.is_subset(ground_set(actual), ground_set(declared))
  }
}

// A declared union: split both sides into a ground part (label sets and bare
// variables) and the residual members (operators and applications). The ground
// parts compare as effect sets; every residual member of `actual` needs some
// residual member of `declared` that dominates it.
fn union_declared_subset(
  actual: EffectTerm,
  declared_members: List(EffectTerm),
) -> Bool {
  let actual_members = case actual {
    TUnion(members) -> members
    TLabels(_) | TTop | TVar(_) | TApp(_, _) | TAbs(_, _) -> [actual]
  }
  let #(actual_ground, actual_residual) = partition_ground(actual_members)
  let #(declared_ground, declared_residual) = partition_ground(declared_members)
  types.is_subset(
    union_ground_set(actual_ground),
    union_ground_set(declared_ground),
  )
  && list.all(actual_residual, fn(member) {
    list.any(declared_residual, subset_normalized(member, _))
  })
}

fn partition_ground(
  members: List(EffectTerm),
) -> #(List(EffectTerm), List(EffectTerm)) {
  list.partition(members, fn(member) {
    case member {
      TLabels(_) | TVar(_) -> True
      TTop | TApp(_, _) | TAbs(_, _) | TUnion(_) -> False
    }
  })
}

// Two operators: rename both binders to one fresh name, then compare the
// bodies. Renaming changes the keys unions are sorted by, so the bodies are
// re-normalized before the recursive step.
fn abs_subset(
  actual_param: String,
  actual_body: EffectTerm,
  declared_param: String,
  declared_body: EffectTerm,
) -> Bool {
  let shared =
    fresh(
      actual_param,
      set.union(free_vars(actual_body), free_vars(declared_body)),
    )
  let renamed_actual =
    rename_binder(TAbs(actual_param, actual_body), to: shared)
  let renamed_declared =
    rename_binder(TAbs(declared_param, declared_body), to: shared)
  case renamed_actual, renamed_declared {
    TAbs(_, a_body), TAbs(_, d_body) ->
      subset_normalized(normalize(a_body), normalize(d_body))
    _, _ -> False
  }
}

// The effect set of a ground member. Only ever called on `TLabels` / `TVar`,
// where the conversion is exact — `to_effect_set` is not usable here because
// it collapses residual members to `[Unknown]`.
fn ground_set(term: EffectTerm) -> EffectSet {
  case term {
    TLabels(labels) -> Specific(labels)
    TVar(name) -> Polymorphic(set.new(), set.from_list([name]))
    TTop -> Wildcard
    TApp(_, _) | TAbs(_, _) | TUnion(_) -> Specific(set.new())
  }
}

fn union_ground_set(members: List(EffectTerm)) -> EffectSet {
  list.fold(members, types.empty(), fn(acc, member) {
    types.union(acc, ground_set(member))
  })
}

// Rename every binder to its nesting depth, so that alpha-equivalent terms
// become syntactically equal. The normalization on either side of the renaming
// is what makes it total: the first reduces both terms, the second re-sorts
// unions whose member order was keyed on the original binder names.
fn alpha_canonical(term: EffectTerm) -> EffectTerm {
  normalize(canonicalize_binders(normalize(term), dict.new(), 0))
}

fn canonicalize_binders(
  term: EffectTerm,
  renamed: Dict(String, String),
  depth: Int,
) -> EffectTerm {
  case term {
    TLabels(_) | TTop -> term
    TVar(name) ->
      case dict.get(renamed, name) {
        Ok(canonical) -> TVar(canonical)
        Error(Nil) -> term
      }
    TApp(operator, arg) ->
      TApp(
        canonicalize_binders(operator, renamed, depth),
        canonicalize_binders(arg, renamed, depth),
      )
    TUnion(terms) ->
      TUnion(list.map(terms, canonicalize_binders(_, renamed, depth)))
    TAbs(param, body) -> {
      let canonical = binder_prefix <> int.to_string(depth)
      TAbs(
        canonical,
        canonicalize_binders(
          body,
          dict.insert(renamed, param, canonical),
          depth + 1,
        ),
      )
    }
  }
}
