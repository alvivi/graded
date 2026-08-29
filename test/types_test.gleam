// Tests for `graded/internal/types` — the EffectSet lattice and the
// polymorphic sets that ride on it.

import generators
import gleam/set
import gleeunit/should
import graded/internal/types.{type EffectSet, Polymorphic, Wildcard}
import qcheck

// EffectSet lattice laws
//
// Property tests: subset is a partial order with empty as bottom and Wildcard
// as top, and union is its idempotent, commutative join.

pub fn subset_reflexivity_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.is_subset(a, a) |> should.be_true()
}

pub fn subset_transitivity_test() {
  use #(a, b, c) <- qcheck.given(
    qcheck.map2(
      qcheck.map2(
        generators.effect_set_gen(),
        generators.effect_set_gen(),
        fn(a, b) { #(a, b) },
      ),
      generators.effect_set_gen(),
      fn(ab, c) { #(ab.0, ab.1, c) },
    ),
  )
  case types.is_subset(a, b) && types.is_subset(b, c) {
    True -> types.is_subset(a, c) |> should.be_true()
    False -> Nil
  }
}

pub fn subset_antisymmetry_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(
      generators.effect_set_gen(),
      generators.effect_set_gen(),
      fn(a, b) { #(a, b) },
    ),
  )
  case types.is_subset(a, b) && types.is_subset(b, a) {
    True -> a |> should.equal(b)
    False -> Nil
  }
}

pub fn union_commutativity_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(
      generators.effect_set_gen(),
      generators.effect_set_gen(),
      fn(a, b) { #(a, b) },
    ),
  )
  types.union(a, b) |> should.equal(types.union(b, a))
}

pub fn union_associativity_test() {
  use #(a, b, c) <- qcheck.given(
    qcheck.map2(
      qcheck.map2(
        generators.effect_set_gen(),
        generators.effect_set_gen(),
        fn(a, b) { #(a, b) },
      ),
      generators.effect_set_gen(),
      fn(ab, c) { #(ab.0, ab.1, c) },
    ),
  )
  types.union(types.union(a, b), c)
  |> should.equal(types.union(a, types.union(b, c)))
}

pub fn union_idempotence_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.union(a, a) |> should.equal(a)
}

pub fn union_identity_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.union(a, types.empty()) |> should.equal(a)
}

pub fn wildcard_absorbs_union_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.union(Wildcard, a) |> should.equal(Wildcard)
}

pub fn empty_is_bottom_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.is_subset(types.empty(), a) |> should.be_true()
}

pub fn wildcard_is_top_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.is_subset(a, Wildcard) |> should.be_true()
}

pub fn union_monotonicity_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(
      generators.effect_set_gen(),
      generators.effect_set_gen(),
      fn(a, b) { #(a, b) },
    ),
  )
  types.is_subset(a, types.union(a, b)) |> should.be_true()
}

pub fn subset_union_compatibility_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(
      generators.effect_set_gen(),
      generators.effect_set_gen(),
      fn(a, b) { #(a, b) },
    ),
  )
  let subset = types.is_subset(a, b)
  let union_eq = types.union(a, b) == b
  subset |> should.equal(union_eq)
}

// Polymorphic effect sets
//
// Effect sets carrying variables: variable detection, `Unknown`-label
// detection, and how union merges labels and variables across operands.

pub fn has_variables_specific_is_false_test() {
  types.has_variables(types.from_labels(["Stdout"])) |> should.be_false()
}

pub fn has_variables_wildcard_is_false_test() {
  types.has_variables(Wildcard) |> should.be_false()
}

pub fn has_variables_polymorphic_is_true_test() {
  let set: EffectSet = Polymorphic(set.new(), set.from_list(["e"]))
  types.has_variables(set) |> should.be_true()
}

pub fn contains_unknown_specific_with_label_is_true_test() {
  types.contains_unknown(types.from_labels(["Stdout", "Unknown"]))
  |> should.be_true()
}

pub fn contains_unknown_specific_without_label_is_false_test() {
  types.contains_unknown(types.from_labels(["Stdout"])) |> should.be_false()
}

pub fn contains_unknown_polymorphic_with_label_is_true_test() {
  let set: EffectSet =
    Polymorphic(set.from_list(["Unknown"]), set.from_list(["e"]))
  types.contains_unknown(set) |> should.be_true()
}

pub fn contains_unknown_polymorphic_without_label_is_false_test() {
  let set: EffectSet = Polymorphic(set.new(), set.from_list(["e"]))
  types.contains_unknown(set) |> should.be_false()
}

pub fn contains_unknown_wildcard_is_false_test() {
  types.contains_unknown(Wildcard) |> should.be_false()
}

pub fn union_polymorphic_merges_both_test() {
  let a: EffectSet = Polymorphic(set.from_list(["Http"]), set.from_list(["e1"]))
  let b: EffectSet =
    Polymorphic(set.from_list(["Stdout"]), set.from_list(["e2"]))
  types.union(a, b)
  |> should.equal(Polymorphic(
    set.from_list(["Http", "Stdout"]),
    set.from_list(["e1", "e2"]),
  ))
}

pub fn union_polymorphic_and_specific_test() {
  let a: EffectSet = Polymorphic(set.new(), set.from_list(["e"]))
  let b: EffectSet = types.from_labels(["Stdout"])
  types.union(a, b)
  |> should.equal(Polymorphic(set.from_list(["Stdout"]), set.from_list(["e"])))
}
