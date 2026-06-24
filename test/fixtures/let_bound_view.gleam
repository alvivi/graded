import gleam/list
import gleam/string

// Idiomatic MVU pattern: a reusable element builder is defined as a let-bound
// closure and mapped over a list. The whole view is pure, so `check view : []`
// must pass — the let-bound `row` must not collapse to `[Unknown]`.
pub fn view(items) {
  let row = fn(item) { string.append("<li>", item) }
  items
  |> list.map(fn(item) { row(item) })
  |> string.join("\n")
}
