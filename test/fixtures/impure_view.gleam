import gleam/io
import gleam/list

pub fn view(items) {
  io.println("rendering...")
  list.map(items, fn(item) { item })
}
