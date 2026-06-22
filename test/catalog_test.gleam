import gleam/list
import gleam/set
import gleam/string
import gleeunit/should
import graded/internal/annotation
import graded/internal/types.{ModuleExternal, Specific}
import simplifile

fn catalog_files() -> List(String) {
  let assert Ok(files) = simplifile.get_files("priv/catalog")
  list.filter(files, string.ends_with(_, ".graded"))
}

// A catalog file that fails to parse is silently skipped at load time, so a
// typo would quietly resolve nothing. Guard every shipped file at the source.
pub fn every_catalog_file_parses_test() {
  let files = catalog_files()
  { files != [] } |> should.be_true()
  list.each(files, fn(path) {
    let assert Ok(content) = simplifile.read(path)
    case annotation.parse_file(content) {
      Ok(_) -> Nil
      Error(_) -> panic as { "catalog file failed to parse: " <> path }
    }
  })
}

// The pure value libraries are declared module-pure, so every call into them
// resolves to [] rather than [Unknown].
pub fn pure_value_libraries_are_module_pure_test() {
  [
    #("priv/catalog/bigi@4.1.1.graded", "bigi"),
    #("priv/catalog/glearray@2.1.2.graded", "glearray"),
    #("priv/catalog/iv@1.4.4.graded", "iv"),
    #(
      "priv/catalog/gleam_community_maths@2.0.2.graded",
      "gleam_community/maths",
    ),
  ]
  |> list.each(fn(entry) {
    let #(path, module) = entry
    let assert Ok(content) = simplifile.read(path)
    let assert Ok(file) = annotation.parse_file(content)
    annotation.extract_externals(file)
    |> list.any(fn(external) {
      external.module == module
      && external.target == ModuleExternal
      && external.effects == Specific(set.new())
    })
    |> should.be_true()
  })
}
