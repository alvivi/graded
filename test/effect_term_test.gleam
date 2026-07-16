// Property + unit tests for the `EffectTerm` IR (see
// docs/second-order-effects.md). Property tags (P-LAT-*, P-NORM-*, …) match
// the design doc's "Properties & invariants" section.

import gleam/dict
import gleam/list
import gleam/set.{type Set}
import gleeunit/should
import graded/internal/effect_term.{
  free_vars, from_effect_set, normalize, normalize_bounded, pure, subst,
  to_effect_set, unknown,
}
import graded/internal/types.{
  type EffectSet, type EffectTerm, Polymorphic, Specific, TAbs, TApp, TLabels,
  TTop, TUnion, TVar, Wildcard,
}
import qcheck

import generators

// Helpers
//
// Shared building blocks for the assertions below: a label-set constructor,
// the definite-labels view of a resolved effect set, and a redex detector.

fn labels(items: List(String)) -> EffectTerm {
  TLabels(set.from_list(items))
}

// The concrete labels a resolved effect set definitely contains. `Error`
// means the wildcard (top) — which contains everything, so any subset check
// against it passes vacuously.
fn definite_labels(effect_set: EffectSet) -> Result(Set(String), Nil) {
  case effect_set {
    Wildcard -> Error(Nil)
    Specific(s) -> Ok(s)
    Polymorphic(l, _) -> Ok(l)
  }
}

// True iff a (normalized) term contains no un-reduced beta-redex — i.e. no
// `TApp` whose operator is a `TAbs`.
fn no_redex(term: EffectTerm) -> Bool {
  case term {
    TLabels(_) -> True
    TTop -> True
    TVar(_) -> True
    TAbs(_, body) -> no_redex(body)
    TUnion(terms) -> list.all(terms, no_redex)
    TApp(TAbs(_, _), _) -> False
    TApp(operator, argument) -> no_redex(operator) && no_redex(argument)
  }
}

// P-LAT: union is a bounded semilattice
//
// Commutativity, associativity, idempotence, `pure` as identity, and `TTop`
// as annihilator — the lattice laws normalization must respect.

pub fn union_commutative_property_test() {
  use #(a, b) <- qcheck.given(qcheck.tuple2(
    generators.effect_term_gen(),
    generators.effect_term_gen(),
  ))
  normalize(TUnion([a, b]))
  |> should.equal(normalize(TUnion([b, a])))
}

pub fn union_associative_property_test() {
  use #(a, b, c) <- qcheck.given(qcheck.tuple3(
    generators.effect_term_gen(),
    generators.effect_term_gen(),
    generators.effect_term_gen(),
  ))
  normalize(TUnion([a, TUnion([b, c])]))
  |> should.equal(normalize(TUnion([TUnion([a, b]), c])))
}

pub fn union_idempotent_property_test() {
  use a <- qcheck.given(generators.effect_term_gen())
  normalize(TUnion([a, a]))
  |> should.equal(normalize(a))
}

pub fn union_pure_identity_property_test() {
  use a <- qcheck.given(generators.effect_term_gen())
  normalize(TUnion([a, pure()]))
  |> should.equal(normalize(a))
}

pub fn union_top_annihilator_property_test() {
  use a <- qcheck.given(generators.effect_term_gen())
  normalize(TUnion([a, TTop]))
  |> should.equal(TTop)
}

// P-NORM: normalization is a well-behaved normal form
//
// Normalization is idempotent, and the EffectSet↔EffectTerm bridge
// round-trips ground effect sets exactly.

pub fn normalize_idempotent_property_test() {
  use t <- qcheck.given(generators.effect_term_gen())
  let once = normalize(t)
  normalize(once)
  |> should.equal(once)
}

pub fn normalize_ground_agreement_property_test() {
  // P-NORM-3: the bridge preserves ground effect sets exactly.
  use s <- qcheck.given(generators.effect_set_gen())
  to_effect_set(from_effect_set(s))
  |> should.equal(s)
}

// P-SUBST: capture-avoiding substitution
//
// Substitution is identity on empty bindings and closed terms, never
// captures free variables, and leaves no beta-redex after normalization.

pub fn subst_empty_identity_property_test() {
  use t <- qcheck.given(generators.effect_term_gen())
  subst(t, dict.new())
  |> should.equal(t)
}

pub fn subst_closed_fixed_property_test() {
  // P-SUBST-2: substituting into a closed term is identity.
  use #(t, bindings) <- qcheck.given(qcheck.tuple2(
    generators.effect_term_gen(),
    generators.effect_binding_gen(),
  ))
  case set.is_empty(free_vars(t)) {
    True -> subst(t, bindings) |> should.equal(t)
    False -> Nil
  }
}

pub fn subst_no_capture_property_test() {
  // P-SUBST-3: free_vars(subst(t, σ)) ⊆ (free_vars(t) \ dom σ) ∪ ⋃ free_vars(σ(x)).
  use #(t, bindings) <- qcheck.given(qcheck.tuple2(
    generators.effect_term_gen(),
    generators.effect_binding_gen(),
  ))
  let domain = bindings |> dict.keys() |> set.from_list()
  let term_fv = free_vars(t)
  let used = set.intersection(term_fv, domain)
  let from_subst =
    set.fold(used, set.new(), fn(acc, x) {
      case dict.get(bindings, x) {
        Ok(v) -> set.union(acc, free_vars(v))
        Error(Nil) -> acc
      }
    })
  let allowed = set.union(set.difference(term_fv, domain), from_subst)
  set.is_subset(free_vars(subst(t, bindings)), of: allowed)
  |> should.be_true()
}

pub fn normalize_no_redex_property_test() {
  // P-SUBST-4: a normal form has no surviving beta-redex.
  use t <- qcheck.given(generators.effect_term_gen())
  no_redex(normalize(t))
  |> should.be_true()
}

// P-SOUND: the checker never hides an effect
//
// Resolution only over-approximates: substitution never drops a genuine
// label, subset checking is reflexive, and a union bounds its operands.

pub fn resolution_over_approximates_property_test() {
  // P-SOUND-1: substitution/reduction never drops a *genuine* concrete label.
  // The `Unknown` placeholder is exempt — it marks "unresolved", and resolving
  // a stuck application away (revealing the real, possibly smaller, effect) is
  // precisely the information gain we want, not an unsound drop.
  use #(t, bindings) <- qcheck.given(qcheck.tuple2(
    generators.effect_term_gen(),
    generators.effect_binding_gen(),
  ))
  let before = to_effect_set(t)
  let after = to_effect_set(subst(t, bindings))
  case definite_labels(after) {
    // `after` is top — it contains everything, so nothing was dropped.
    Error(Nil) -> Nil
    Ok(after_labels) ->
      case definite_labels(before) {
        Error(Nil) ->
          // `before` was top but `after` is finite — would be unsound.
          should.fail()
        Ok(before_labels) ->
          set.is_subset(set.delete(before_labels, "Unknown"), of: after_labels)
          |> should.be_true()
      }
  }
}

pub fn subset_reflexive_property_test() {
  // P-SOUND-2.
  use t <- qcheck.given(generators.effect_term_gen())
  let s = to_effect_set(t)
  types.is_subset(s, s)
  |> should.be_true()
}

pub fn union_upper_bound_property_test() {
  // P-SOUND-3: each operand's effect is within the union's effect.
  use #(a, b) <- qcheck.given(qcheck.tuple2(
    generators.effect_term_gen(),
    generators.effect_term_gen(),
  ))
  let combined = to_effect_set(TUnion([a, b]))
  types.is_subset(to_effect_set(a), combined)
  |> should.be_true()
  types.is_subset(to_effect_set(b), combined)
  |> should.be_true()
}

// P-DIST: application distributes over union
//
// Applying a union of operators equals the union of the applications, and
// distribution keeps every branch's effect.

pub fn app_distributes_over_union_property_test() {
  // P-DIST-1: (f ⊔ g)(x) normalizes to the same term as f(x) ⊔ g(x), for
  // arbitrary operator bodies — the distribution law itself.
  use #(a, b, x) <- qcheck.given(qcheck.tuple3(
    generators.effect_term_gen(),
    generators.effect_term_gen(),
    generators.effect_term_gen(),
  ))
  let f = TAbs("p", a)
  let g = TAbs("p", b)
  normalize(TApp(TUnion([f, g]), x))
  |> should.equal(normalize(TUnion([TApp(f, x), TApp(g, x)])))
}

pub fn app_distribution_over_approximates_property_test() {
  // P-DIST-2: distributing application over a union keeps every branch's
  // effect (the `Unknown` placeholder exempt, as in P-SOUND-1). A branch that
  // is top forces the whole union to top.
  use #(a, b, x) <- qcheck.given(qcheck.tuple3(
    generators.effect_term_gen(),
    generators.effect_term_gen(),
    generators.effect_term_gen(),
  ))
  let f = TAbs("p", a)
  let g = TAbs("p", b)
  let combined = to_effect_set(TApp(TUnion([f, g]), x))
  [TApp(f, x), TApp(g, x)]
  |> list.each(fn(branch) {
    case definite_labels(to_effect_set(branch)), definite_labels(combined) {
      Error(Nil), Error(Nil) -> Nil
      // A top branch must keep the union top.
      Error(Nil), Ok(_) -> should.fail()
      Ok(_), Error(Nil) -> Nil
      Ok(branch_labels), Ok(combined_labels) ->
        set.is_subset(set.delete(branch_labels, "Unknown"), of: combined_labels)
        |> should.be_true()
    }
  })
}

// P-TERM: termination
//
// Finite terms normalize within a finite reduction budget, agreeing with
// the unbounded normalizer.

pub fn normalize_terminates_property_test() {
  // P-TERM-1: finite terms never exhaust the reduction budget, and the
  // bounded result matches the unbounded one.
  use t <- qcheck.given(generators.effect_term_gen())
  normalize_bounded(t, 100_000)
  |> should.equal(Ok(normalize(t)))
}

// Unit tests: the second-order motivating example
//
// Concrete beta-reduction, stuck-application, distribution, and
// capture-avoidance scenarios drawn from the second-order design doc.

pub fn beta_reduction_unit_test() {
  // (λcb. [Http, cb])(Stdout)  ──β──►  [Http, Stdout]
  let operator = TAbs("cb", TUnion([labels(["Http"]), TVar("cb")]))
  normalize(TApp(operator, labels(["Stdout"])))
  |> should.equal(labels(["Http", "Stdout"]))
}

pub fn stuck_application_is_unknown_unit_test() {
  // action(Stdout) with action unresolved collapses to [Unknown].
  to_effect_set(TApp(TVar("action"), labels(["Stdout"])))
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

pub fn nested_second_order_unit_test() {
  // λaction. action(Stdout)  applied to  (λcb. [Http, cb])  ──►  [Http, Stdout]
  let with_logger = TAbs("action", TApp(TVar("action"), labels(["Stdout"])))
  let runner = TAbs("cb", TUnion([labels(["Http"]), TVar("cb")]))
  normalize(TApp(with_logger, runner))
  |> should.equal(labels(["Http", "Stdout"]))
}

pub fn app_distributes_over_union_unit_test() {
  // (λcb. [Http, cb]  ⊔  λcb. [Dom, cb])(Stdout)  ──►  [Http, Dom, Stdout]
  // A producer returning one of two operators, applied: both branches fire.
  let f = TAbs("cb", TUnion([labels(["Http"]), TVar("cb")]))
  let g = TAbs("cb", TUnion([labels(["Dom"]), TVar("cb")]))
  normalize(TApp(TUnion([f, g]), labels(["Stdout"])))
  |> should.equal(labels(["Dom", "Http", "Stdout"]))
}

pub fn app_distribution_identity_branch_unit_test() {
  // (λx. x  ⊔  λx. [A])([B])  ──►  [A, B] — the identity branch keeps the arg.
  let identity = TAbs("x", TVar("x"))
  let const_a = TAbs("x", labels(["A"]))
  normalize(TApp(TUnion([identity, const_a]), labels(["B"])))
  |> should.equal(labels(["A", "B"]))
}

pub fn app_distribution_mixed_union_stays_stuck_unit_test() {
  // A *mixed* union (an operator alongside a bare variable) is ill-kinded as an
  // operator: distributing would push `g` into operator position and drop the
  // `[A]` branch's labels. So the whole application stays stuck → [Unknown],
  // the conservative (sound) collapse. Only all-abstraction unions distribute.
  let const_a = TAbs("x", labels(["A"]))
  to_effect_set(TApp(TUnion([const_a, TVar("g")]), labels(["B"])))
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

pub fn free_variable_preserved_unit_test() {
  // A bare free variable round-trips to a polymorphic set, not Unknown.
  to_effect_set(TVar("e"))
  |> should.equal(Polymorphic(set.new(), set.from_list(["e"])))
}

pub fn capture_avoidance_unit_test() {
  // subst (λcb. [e, cb]) with {e := cb} must NOT capture the inner cb;
  // the binder is renamed so the substituted `cb` stays free.
  let operator = TAbs("cb", TUnion([TVar("e"), TVar("cb")]))
  let result = subst(operator, dict.from_list([#("e", TVar("cb"))]))
  // The outer (substituted) cb must remain free in the result.
  free_vars(result)
  |> should.equal(set.from_list(["cb"]))
}

pub fn unknown_term_unit_test() {
  to_effect_set(unknown())
  |> should.equal(Specific(set.from_list(["Unknown"])))
}
