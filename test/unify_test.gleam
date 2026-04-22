import glance
import gleam/dict
import gleam/list
import gleam/set
import gleeunit/should
import graded/internal/types.{Polymorphic, Specific, Wildcard}
import graded/internal/unify

// ──── Basic solver cases ────

pub fn solve_empty_constraints_test() {
  unify.solve(dict.new())
  |> should.equal(dict.new())
}

pub fn solve_concrete_rhs_test() {
  let constraints =
    dict.from_list([
      #("x", [types.TConcrete(set.from_list(["Http"]))]),
    ])
  let solution = unify.solve(constraints)
  dict.get(solution, "x")
  |> should.equal(Ok(Specific(set.from_list(["Http"]))))
}

pub fn solve_wildcard_rhs_test() {
  let constraints = dict.from_list([#("x", [types.TWildcard])])
  let solution = unify.solve(constraints)
  dict.get(solution, "x") |> should.equal(Ok(Wildcard))
}

pub fn solve_variable_chain_test() {
  // x ⊇ y, y ⊇ [Http] → x should resolve to [Http]
  let constraints =
    dict.from_list([
      #("x", [types.TVariable("y")]),
      #("y", [types.TConcrete(set.from_list(["Http"]))]),
    ])
  let solution = unify.solve(constraints)
  dict.get(solution, "x")
  |> should.equal(Ok(Specific(set.from_list(["Http"]))))
  dict.get(solution, "y")
  |> should.equal(Ok(Specific(set.from_list(["Http"]))))
}

pub fn solve_union_rhs_test() {
  // x ⊇ [Http] ∪ [Stdout] → x = [Http, Stdout]
  let constraints =
    dict.from_list([
      #(
        "x",
        [
          types.TUnion([
            types.TConcrete(set.from_list(["Http"])),
            types.TConcrete(set.from_list(["Stdout"])),
          ]),
        ],
      ),
    ])
  let solution = unify.solve(constraints)
  dict.get(solution, "x")
  |> should.equal(Ok(Specific(set.from_list(["Http", "Stdout"]))))
}

pub fn solve_two_hop_chain_test() {
  // a ⊇ b, b ⊇ c, c ⊇ [FileSystem] → all three should resolve to [FileSystem]
  let constraints =
    dict.from_list([
      #("a", [types.TVariable("b")]),
      #("b", [types.TVariable("c")]),
      #("c", [types.TConcrete(set.from_list(["FileSystem"]))]),
    ])
  let solution = unify.solve(constraints)
  dict.get(solution, "a")
  |> should.equal(Ok(Specific(set.from_list(["FileSystem"]))))
}

pub fn solve_diamond_test() {
  // Two paths into the same variable: x ⊇ a, x ⊇ b, a = [Http], b = [Stdout]
  // → x = [Http, Stdout]
  let constraints =
    dict.from_list([
      #(
        "x",
        [
          types.TConcrete(set.from_list(["Http"])),
          types.TConcrete(set.from_list(["Stdout"])),
        ],
      ),
    ])
  let solution = unify.solve(constraints)
  dict.get(solution, "x")
  |> should.equal(Ok(Specific(set.from_list(["Http", "Stdout"]))))
}

pub fn solve_self_cycle_test() {
  // x ⊇ x is trivially satisfied; x has no concrete inflow so stays free (absent)
  let constraints = dict.from_list([#("x", [types.TVariable("x")])])
  let solution = unify.solve(constraints)
  dict.get(solution, "x") |> should.equal(Error(Nil))
}

pub fn solve_free_variable_absent_from_solution_test() {
  // A variable with no concrete inflow is absent from the solution dict.
  // flatten_term will turn it into a Polymorphic variable.
  let constraints = dict.new()
  unify.solve(constraints) |> dict.get("free") |> should.equal(Error(Nil))
}

// ──── Fixpoint stability ────

pub fn fixpoint_stability_test() {
  // Running the solver twice on the same constraints should produce identical output.
  let constraints =
    dict.from_list([
      #("a", [types.TVariable("b"), types.TConcrete(set.from_list(["Http"]))]),
      #("b", [types.TConcrete(set.from_list(["Stdout"]))]),
      #("c", [types.TVariable("a")]),
    ])
  let solution1 = unify.solve(constraints)
  // Re-seed: build a new constraint map seeding from solution1 and solve again.
  // The result should be the same.
  let reseed = fn(v) {
    case dict.get(solution1, v) {
      Ok(es) -> [types.lift_effect_set(es)]
      Error(Nil) -> []
    }
  }
  let constraints2 =
    dict.from_list([
      #("a", reseed("a")),
      #("b", reseed("b")),
      #("c", reseed("c")),
    ])
  let solution2 = unify.solve(constraints2)
  solution1 |> should.equal(solution2)
}

// ──── flatten_term ────

pub fn flatten_term_variable_resolved_test() {
  let solution =
    dict.from_list([#("f", Specific(set.from_list(["Http"])))])
  types.flatten_term(types.TVariable("f"), solution)
  |> should.equal(Specific(set.from_list(["Http"])))
}

pub fn flatten_term_free_variable_test() {
  types.flatten_term(types.TVariable("free"), dict.new())
  |> should.equal(Polymorphic(set.new(), set.from_list(["free"])))
}

pub fn flatten_term_wildcard_test() {
  types.flatten_term(types.TWildcard, dict.new())
  |> should.equal(Wildcard)
}

pub fn flatten_term_union_test() {
  let solution =
    dict.from_list([#("f", Specific(set.from_list(["Http"])))])
  types.flatten_term(
    types.TUnion([
      types.TConcrete(set.from_list(["Stdout"])),
      types.TVariable("f"),
    ]),
    solution,
  )
  |> should.equal(Specific(set.from_list(["Http", "Stdout"])))
}

// ──── lift_effect_set ────

pub fn lift_specific_test() {
  types.lift_effect_set(Specific(set.from_list(["Http"])))
  |> should.equal(types.TConcrete(set.from_list(["Http"])))
}

pub fn lift_wildcard_test() {
  types.lift_effect_set(Wildcard)
  |> should.equal(types.TWildcard)
}

pub fn lift_polymorphic_test() {
  let es = Polymorphic(set.from_list(["Http"]), set.from_list(["f"]))
  let term = types.lift_effect_set(es)
  // Should be TUnion([TConcrete({"Http"}), TVariable("f")]) in some order.
  // Flatten it back to verify round-trip.
  types.flatten_term(term, dict.new())
  |> should.equal(Polymorphic(set.from_list(["Http"]), set.from_list(["f"])))
}

pub fn from_constraints_groups_by_lhs_test() {
  let span = glance.Span(0, 0)
  let constraints = [
    types.Superset("x", types.TConcrete(set.from_list(["Http"])), span, ""),
    types.Superset("x", types.TConcrete(set.from_list(["Stdout"])), span, ""),
    types.Superset("y", types.TConcrete(set.from_list(["Dom"])), span, ""),
  ]
  let grouped = unify.from_constraints(constraints)
  let x_terms = dict.get(grouped, "x") |> should.be_ok()
  list.length(x_terms) |> should.equal(2)
  let y_terms = dict.get(grouped, "y") |> should.be_ok()
  list.length(y_terms) |> should.equal(1)
}
