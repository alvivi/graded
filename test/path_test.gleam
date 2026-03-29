import assay
import gleeunit/should

pub fn simple_path_test() {
  assay.gleam_to_assay_path("src/app.gleam", "src")
  |> should.equal("priv/assay/app.assay")
}

pub fn nested_path_test() {
  assay.gleam_to_assay_path("src/app/router.gleam", "src")
  |> should.equal("priv/assay/app/router.assay")
}

pub fn custom_directory_test() {
  assay.gleam_to_assay_path("test/fixtures/view.gleam", "test/fixtures")
  |> should.equal("test/fixtures/priv/assay/view.assay")
}

pub fn deeply_nested_test() {
  assay.gleam_to_assay_path("src/app/web/handlers/auth.gleam", "src")
  |> should.equal("priv/assay/app/web/handlers/auth.assay")
}
