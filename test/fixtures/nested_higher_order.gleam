import gleam/io
import gleam/list

// Two-hop: apply_twice forwards its callback f to list.map.
// Inferred effects should be polymorphic over f, not [Unknown].
pub fn apply_twice(f: fn(Int) -> Int, x: Int) -> List(Int) {
  list.map([x], f)
}

// Three-hop: outer → middle → inner → list.map.
// Each level forwards its callback through a local helper.
pub fn outer(f: fn(Int) -> Int, x: Int) -> List(Int) {
  middle(f, x)
}

fn middle(g: fn(Int) -> Int, x: Int) -> List(Int) {
  inner(g, x)
}

fn inner(h: fn(Int) -> Int, x: Int) -> List(Int) {
  list.map([x], h)
}

// Mixed forwarder: always performs Stdout AND forwards its callback.
// Inferred effects should be Polymorphic({"Stdout"}, {"f"}).
pub fn log_and_map(f: fn(Int) -> Int, x: Int) -> List(Int) {
  io.println("mapping")
  list.map([x], f)
}

// Pure forwarder: callback forwarded but nothing else.
// When called with a pure callback the function is pure.
pub fn pure_forward(f: fn(Int) -> Int, items: List(Int)) -> List(Int) {
  list.map(items, f)
}
