//// Worklist fixpoint solver for effect-variable subset constraints.
////
//// Entry point: `solve(constraints)` where `constraints` maps each variable
//// name to the list of EffectTerm values that must flow into it
//// (`variable ⊇ term` for each term in the list).
////
//// Returns the minimal Dict(String, EffectSet) satisfying all constraints.
//// Variables with no concrete inflow are absent from the solution and will
//// appear as free (polymorphic) variables when the caller calls flatten_term.
////
//// The lattice is powerset(labels) ∪ {Wildcard}, monotone by construction.
//// Terminates in O(|vars| × |labels|) iterations.

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import graded/internal/types.{
  type EffectSet, type EffectTerm, Specific, TConcrete, TUnion,
  TVariable, TWildcard, Wildcard,
}

/// Solve subset constraints `variable ⊇ term` to a minimal solution.
///
/// `constraints` maps variable names to the rhs terms that must flow into them.
/// Returns the concrete solution: for each variable, the EffectSet it resolves
/// to. Variables absent from the result are free (polymorphic).
pub fn solve(
  constraints: Dict(String, List(EffectTerm)),
) -> Dict(String, EffectSet) {
  let all_vars = dict.keys(constraints)
  let rev_deps = build_reverse_deps(constraints)
  let worklist = all_vars
  iterate(constraints, rev_deps, dict.new(), worklist)
}

// ──── Internal ────

fn iterate(
  constraints: Dict(String, List(EffectTerm)),
  rev_deps: Dict(String, List(String)),
  solution: Dict(String, EffectSet),
  worklist: List(String),
) -> Dict(String, EffectSet) {
  case worklist {
    [] -> solution
    [v, ..rest] -> {
      let terms = result.unwrap(dict.get(constraints, v), [])
      let new_val = evaluate_terms(terms, solution)
      let current_val = result.unwrap(dict.get(solution, v), types.empty())
      case new_val == current_val {
        True -> iterate(constraints, rev_deps, solution, rest)
        False -> {
          let new_solution = dict.insert(solution, v, new_val)
          let dependents = result.unwrap(dict.get(rev_deps, v), [])
          iterate(constraints, rev_deps, new_solution, list.append(rest, dependents))
        }
      }
    }
  }
}

/// Evaluate a list of rhs terms under the current solution and union them.
/// During solving, unresolved TVariable references are treated as empty
/// (they contribute nothing until their own solution is computed).
fn evaluate_terms(terms: List(EffectTerm), solution: Dict(String, EffectSet)) -> EffectSet {
  list.fold(terms, types.empty(), fn(acc, term) {
    types.union(acc, evaluate_term(term, solution))
  })
}

fn evaluate_term(term: EffectTerm, solution: Dict(String, EffectSet)) -> EffectSet {
  case term {
    TWildcard -> Wildcard
    TConcrete(labels) -> Specific(labels)
    TVariable(name) ->
      result.unwrap(dict.get(solution, name), types.empty())
    TUnion(ts) -> evaluate_terms(ts, solution)
  }
}

/// Build the reverse dependency graph: for each variable `v`, `rev_deps[v]`
/// is the list of variables `w` such that `v` appears in some rhs of `w`'s
/// constraints. When `v`'s solution grows, `w` must be re-evaluated.
fn build_reverse_deps(
  constraints: Dict(String, List(EffectTerm)),
) -> Dict(String, List(String)) {
  dict.fold(constraints, dict.new(), fn(rev_deps, var, terms) {
    let referenced = list.flat_map(terms, collect_variables)
    list.fold(referenced, rev_deps, fn(rd, dep) {
      let current = result.unwrap(dict.get(rd, dep), [])
      dict.insert(rd, dep, [var, ..current])
    })
  })
}

/// Extract all TVariable names referenced anywhere in a term.
fn collect_variables(term: EffectTerm) -> List(String) {
  case term {
    TWildcard -> []
    TConcrete(_) -> []
    TVariable(name) -> [name]
    TUnion(ts) -> list.flat_map(ts, collect_variables)
  }
}

/// Build a constraint map from a list of Constraint values.
/// Groups rhs terms by their lhs variable name.
pub fn from_constraints(
  constraints: List(types.Constraint),
) -> Dict(String, List(EffectTerm)) {
  list.fold(constraints, dict.new(), fn(acc, c) {
    let types.Superset(lhs:, rhs:, ..) = c
    let current = result.unwrap(dict.get(acc, lhs), [])
    dict.insert(acc, lhs, [rhs, ..current])
  })
}

