import gleam/io

pub fn view() {
  helper()
}

fn helper() {
  io.println("sneaky side effect")
}
