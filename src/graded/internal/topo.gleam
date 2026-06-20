//// Topological sort over a string-keyed dependency graph. Used by inference
//// to walk project (and path-dep) modules in dependency order so each module
//// is analysed after every other module it imports.
////
//// The graph is `Dict(node, Set(node it depends on))`. The output is a
//// leaves-first list: any node `u` that depends on `v` appears *after* `v`.
//// Gleam's no-circular-imports guarantee makes the import graph a DAG in
//// practice, but the algorithm still detects cycles defensively.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}

// Failure mode of `sort`. The contained list names every node still
// participating in unresolved dependencies — useful for diagnostics on
// cyclic input.
pub type SortError {
  Cycle(nodes: List(String))
}

// Kahn's algorithm: produce a leaves-first ordering of `graph`.
pub fn sort(
  graph: Dict(String, Set(String)),
) -> Result(List(String), SortError) {
  let in_degrees = dict.map_values(graph, fn(_node, deps) { set.size(deps) })
  let reverse = build_reverse_graph(graph)
  let initial_queue =
    in_degrees
    |> dict.filter(fn(_node, degree) { degree == 0 })
    |> dict.keys()
  kahn_loop(initial_queue, in_degrees, reverse, [])
}

fn kahn_loop(
  queue: List(String),
  in_degrees: Dict(String, Int),
  reverse: Dict(String, Set(String)),
  acc: List(String),
) -> Result(List(String), SortError) {
  case queue {
    [] -> {
      let remaining = dict.filter(in_degrees, fn(_node, degree) { degree > 0 })
      case dict.is_empty(remaining) {
        True -> Ok(list.reverse(acc))
        False -> Error(Cycle(nodes: dict.keys(remaining)))
      }
    }
    [node, ..rest] -> {
      let dependents = case dict.get(reverse, node) {
        Ok(s) -> set.to_list(s)
        Error(_) -> []
      }
      let #(new_in_degrees, newly_zero) =
        list.fold(dependents, #(in_degrees, []), fn(state, dependent) {
          let #(degrees, zero_acc) = state
          let current = case dict.get(degrees, dependent) {
            Ok(d) -> d
            Error(_) -> 0
          }
          let updated = current - 1
          let new_degrees = dict.insert(degrees, dependent, updated)
          case updated {
            0 -> #(new_degrees, [dependent, ..zero_acc])
            _ -> #(new_degrees, zero_acc)
          }
        })
      // Prepend newly-unblocked nodes instead of appending — `list.append`
      // would be O(N) per iteration, making the sort O(N²) on linear chains.
      // Within-level order changes (DFS-ish instead of BFS-ish) but every
      // valid topological order is still valid.
      kahn_loop(prepend_all(newly_zero, rest), new_in_degrees, reverse, [
        node,
        ..acc
      ])
    }
  }
}

fn prepend_all(prefix: List(a), tail: List(a)) -> List(a) {
  list.fold(prefix, tail, fn(acc, item) { [item, ..acc] })
}

// Tarjan's algorithm: partition `graph` (node -> set of nodes it points at)
// into strongly-connected components, returned in **callee-first** order —
// every component appears before the components that point into it. A
// component is a list of mutually-reachable nodes; a node on no cycle is a
// singleton (a self-loop still yields a size-1 component).
//
// Unlike `sort`, this never fails: cycles are exactly what it groups. The
// checker uses it to memoize same-module effect analysis — a singleton's
// result is independent of its callers and can be cached, while a genuine
// mutual-recursion cluster is handled together as one component.
pub fn scc_order(graph: Dict(String, Set(String))) -> List(List(String)) {
  let state =
    list.fold(dict.keys(graph), new_tarjan(), fn(state, node) {
      case dict.has_key(state.indices, node) {
        True -> state
        False -> strong_connect(node, graph, state)
      }
    })
  // Components are appended (via prepend) as they are finalized, which happens
  // in callee-first order; the accumulated list is therefore caller-first, so
  // one reverse restores callee-first.
  list.reverse(state.output)
}

type Tarjan {
  Tarjan(
    next_index: Int,
    indices: Dict(String, Int),
    lowlinks: Dict(String, Int),
    on_stack: Set(String),
    stack: List(String),
    output: List(List(String)),
  )
}

fn new_tarjan() -> Tarjan {
  Tarjan(
    next_index: 0,
    indices: dict.new(),
    lowlinks: dict.new(),
    on_stack: set.new(),
    stack: [],
    output: [],
  )
}

fn strong_connect(
  v: String,
  graph: Dict(String, Set(String)),
  state: Tarjan,
) -> Tarjan {
  let index = state.next_index
  let state =
    Tarjan(
      ..state,
      next_index: index + 1,
      indices: dict.insert(state.indices, v, index),
      lowlinks: dict.insert(state.lowlinks, v, index),
      stack: [v, ..state.stack],
      on_stack: set.insert(state.on_stack, v),
    )
  let successors =
    dict.get(graph, v) |> result.unwrap(set.new()) |> set.to_list()
  let state =
    list.fold(successors, state, fn(state, w) {
      case dict.get(state.indices, w) {
        // w not yet visited — recurse, then take the min of the lowlinks.
        Error(Nil) -> {
          let state = strong_connect(w, graph, state)
          set_lowlink(state, v, int.min(lowlink(state, v), lowlink(state, w)))
        }
        // w already visited — it constrains v only if it's still on the stack
        // (i.e. part of the current SCC being built).
        Ok(index_w) ->
          case set.contains(state.on_stack, w) {
            True -> set_lowlink(state, v, int.min(lowlink(state, v), index_w))
            False -> state
          }
      }
    })
  // v roots an SCC when its lowlink never escaped its own index: pop the stack
  // down to v to form the component.
  case lowlink(state, v) == index {
    True -> {
      let #(component, rest, on_stack) =
        pop_component(state.stack, state.on_stack, v, [])
      Tarjan(..state, stack: rest, on_stack: on_stack, output: [
        component,
        ..state.output
      ])
    }
    False -> state
  }
}

fn lowlink(state: Tarjan, node: String) -> Int {
  dict.get(state.lowlinks, node) |> result.unwrap(0)
}

fn set_lowlink(state: Tarjan, node: String, value: Int) -> Tarjan {
  Tarjan(..state, lowlinks: dict.insert(state.lowlinks, node, value))
}

fn pop_component(
  stack: List(String),
  on_stack: Set(String),
  root: String,
  acc: List(String),
) -> #(List(String), List(String), Set(String)) {
  case stack {
    [] -> #(acc, [], on_stack)
    [node, ..rest] -> {
      let on_stack = set.delete(on_stack, node)
      let acc = [node, ..acc]
      case node == root {
        True -> #(acc, rest, on_stack)
        False -> pop_component(rest, on_stack, root, acc)
      }
    }
  }
}

fn build_reverse_graph(
  graph: Dict(String, Set(String)),
) -> Dict(String, Set(String)) {
  dict.fold(graph, dict.new(), fn(reverse, node, deps) {
    set.fold(deps, reverse, fn(rev, dep) {
      dict.upsert(rev, dep, fn(existing) {
        case existing {
          Some(s) -> set.insert(s, node)
          None -> set.from_list([node])
        }
      })
    })
  })
}
