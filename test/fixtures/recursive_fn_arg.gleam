import gleam/list

pub type Tree {
  Leaf(Int)
  Branch(List(Tree))
}

// A self-recursive function passed BY NAME to a higher-order function
// (`list.flat_map(children, walk)`) rather than as an inline closure. The
// recursive reference is already on the analysis stack, so it must contribute
// nothing — the function is pure — instead of collapsing the result to
// [Unknown].
pub fn walk(tree: Tree) -> List(Int) {
  case tree {
    Leaf(n) -> [n]
    Branch(children) -> list.flat_map(children, walk)
  }
}

pub fn run() -> List(Int) {
  walk(Branch([Leaf(1), Branch([Leaf(2)])]))
}
