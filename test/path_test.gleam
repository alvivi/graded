import gleeunit/should
import graded

pub fn simple_path_test() {
  graded.gleam_to_graded_path("src/app.gleam", "src")
  |> should.equal("priv/graded/app.graded")
}

pub fn nested_path_test() {
  graded.gleam_to_graded_path("src/app/router.gleam", "src")
  |> should.equal("priv/graded/app/router.graded")
}

pub fn custom_directory_test() {
  graded.gleam_to_graded_path("test/fixtures/view.gleam", "test/fixtures")
  |> should.equal("test/fixtures/priv/graded/view.graded")
}

pub fn deeply_nested_test() {
  graded.gleam_to_graded_path("src/app/web/handlers/auth.gleam", "src")
  |> should.equal("priv/graded/app/web/handlers/auth.graded")
}
