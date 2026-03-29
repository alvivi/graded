import gleam/list
import gleam/string

pub fn view(items) {
  items
  |> list.map(fn(item) { string.append("<li>", item) })
  |> string.join("\n")
}
