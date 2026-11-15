// A bundled catalog file's audit record: how it reads, which installed
// versions it speaks for, and what a call reads where it does and where it
// does not.

import glance
import gleam/dict

import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/set
import gleam/string
import gleeunit/should
import graded
import graded/internal/annotation
import graded/internal/audit.{
  AuditError, ConstantCarries, ContainerResult, ContainerType, Coverage,
  ReviewedContract, ReviewedName, Unreviewed,
}
import graded/internal/checker
import graded/internal/effect_term
import graded/internal/effects
import graded/internal/signatures
import graded/internal/typedefs
import graded/internal/typeinfo
import graded/internal/types.{QualifiedName}
import simplifile
import support

// The reader

const record =
  "// a review of fake 1.0.0 and 1.0.2
covers 1.0.0, 1.0.2 to 1.0.4
contract fake/str.each(items: [items], f: [f]) : [f] where runs : [], relay : f(items)
reviewed fake/str.inspect
container fake/box.Box
constant fake/decode.int : []
container_result fake/str.wrap

unreviewed fake/str.zip : not in the reviewed versions
"

pub fn the_reader_reads_every_kind_of_entry_test() {
  let assert Ok(file) = audit.parse(record)
  let covers =
    Coverage(ranges: [#(#(1, 0, 0), #(1, 0, 0)), #(#(1, 0, 2), #(1, 0, 4))])
  let assert [
    ReviewedContract(assume:, covers: contract_covers),
    ReviewedName(name: reviewed, covers: reviewed_covers),
    ContainerType(module: "fake/box", name: "Box", covers: container_covers),
    ConstantCarries(name: constant, carried:, covers: constant_covers),
    ContainerResult(name: wrapping, covers: result_covers),
    Unreviewed(path: "fake/str.zip", reason: "not in the reviewed versions"),
  ] = file.entries
  [
    contract_covers,
    reviewed_covers,
    container_covers,
    constant_covers,
    result_covers,
  ]
  |> list.all(fn(entry) { entry == covers })
  |> should.be_true
  annotation.assume_qualified_name(assume)
  |> should.equal(Ok(QualifiedName("fake/str", "each")))
  assume.contract.runs |> should.equal(Some([]))
  assume.contract.relays
  |> should.equal([types.Relay(callback: "f", positions: [Some("items")])])
  reviewed |> should.equal(QualifiedName("fake/str", "inspect"))
  constant |> should.equal(QualifiedName("fake/decode", "int"))
  carried |> should.equal(effect_term.pure())
  wrapping |> should.equal(QualifiedName("fake/str", "wrap"))
  audit.contracts(file) |> should.equal([assume])
}

pub fn an_entry_before_any_covers_line_does_not_read_test() {
  audit.parse("reviewed fake/str.inspect\ncovers 1.0.0\n")
  |> should.equal(Error(AuditError(1, "reviewed fake/str.inspect")))
}

pub fn a_malformed_line_does_not_read_test() {
  [
    #("covers 1.0\n", "covers 1.0"),
    #("covers 1.0.0\ncontract fake/str : []\n", "contract fake/str : []"),
    #("covers 1.0.0\nreviewed fake\n", "reviewed fake"),
    #("covers 1.0.0\nconstant fake/d.int\n", "constant fake/d.int"),
    #("covers 1.0.0\nunreviewed fake/str.zip\n", "unreviewed fake/str.zip"),
    #("covers 1.0.0\nshipped fake/str.zip\n", "shipped fake/str.zip"),
  ]
  |> list.each(fn(case_) {
    let #(input, line) = case_
    let assert Error(AuditError(_, content)) = audit.parse(input)
    content |> should.equal(line)
  })
}

// Which installed versions a record speaks for

pub fn a_record_speaks_for_the_versions_it_covers_only_test() {
  let assert Ok(file) = audit.parse(record)
  let reviewed_at = fn(version) {
    audit.applicable(file, version).reviewed
    |> set.to_list
    |> list.map(fn(name) { name.module <> "." <> name.function })
    |> list.sort(string.compare)
  }
  let all = ["fake/str.each", "fake/str.inspect", "fake/str.wrap"]
  reviewed_at(#(1, 0, 0)) |> should.equal(all)
  reviewed_at(#(1, 0, 3)) |> should.equal(all)
  reviewed_at(#(1, 0, 4)) |> should.equal(all)
  reviewed_at(#(1, 0, 1)) |> should.equal([])
  reviewed_at(#(1, 0, 5)) |> should.equal([])
  reviewed_at(#(0, 9, 9)) |> should.equal([])
  let at_one = audit.applicable(file, #(1, 0, 0))
  at_one.containers |> should.equal(set.from_list([#("fake/box", "Box")]))
  at_one.constants
  |> dict.to_list
  |> should.equal([#(QualifiedName("fake/decode", "int"), effect_term.pure())])
  at_one.container_results
  |> should.equal(set.from_list([QualifiedName("fake/str", "wrap")]))
  audit.applicable(file, #(1, 0, 5)).containers |> should.equal(set.new())
}

// The loader

const catalog_line = "assume fake/str : []\n"

const sidecar =
  "covers 1.0.0 to 1.0.2\nreviewed fake/str.inspect\ncontainer fake/str.Box\n"

fn installed(root: String, version: String) -> effects.BundledCatalog {
  installed_with(root, version, effects.trusting_reading())
}

fn installed_with(
  root: String,
  version: String,
  reading: effects.SpecReading,
) -> effects.BundledCatalog {
  let root =
    support.write_fixture(root, [
      #("catalog/fake@1.0.0.graded", catalog_line),
      #("catalog/fake@1.0.0.audit", sidecar),
      #(
        "manifest.toml",
        "packages = [\n  { name = \"fake\", version = \""
          <> version
          <> "\", build_tools = [\"gleam\"], requirements = [], otp_app = \"fake\", source = \"hex\", outer_checksum = \"00\" },\n]\n",
      ),
    ])
  let assert Ok(files) = effects.bundled_catalog_files(root <> "/catalog")
  let catalog =
    effects.load_project_catalog(files, root <> "/manifest.toml", reading)
  support.cleanup(root)
  catalog
}

pub fn a_record_applies_to_an_installed_version_it_covers_test() {
  let catalog = installed("build/audit_loader_covered", "1.0.1")
  catalog.audit.reviewed
  |> should.equal(set.from_list([QualifiedName("fake/str", "inspect")]))
  catalog.audit.containers
  |> should.equal(set.from_list([#("fake/str", "Box")]))
}

pub fn a_newer_installed_version_than_the_record_covers_is_unaudited_test() {
  // The 1.0.0 catalog file serves 1.0.3 too, but the review stops at 1.0.2.
  let catalog = installed("build/audit_loader_past", "1.0.3")
  catalog.audit |> should.equal(audit.empty())
}

// What a call reads. No types are read, so a list running `loud` reads its
// result unknown beside its cost.

const runs = ["Stdout", "Unknown"]

fn knowledge_base(
  version: String,
  written: List(String),
) -> effects.KnowledgeBase {
  let reading = effects.trusting_reading()
  let catalog =
    installed_with("build/audit_calls_" <> version, version, reading)
  let parse = fn(line) {
    let assert Ok(types.GradedFile(lines: [types.AssumeLine(assume, _)])) =
      annotation.parse_file(line)
    assume
  }
  effects.knowledge_base_from_catalog(
    "build/audit_no_packages",
    catalog,
    dict.new(),
    reading,
  )
  |> effects.with_assumes(
    [parse("assume app/ffi.shout : [Stdout]"), ..list.map(written, parse)],
    types.UserAssume,
  )
}

fn registry() -> signatures.SignatureRegistry {
  let assert Ok(module) =
    glance.module(
      "pub fn inspect(x: List(fn() -> Nil)) -> String {\n  \"\"\n}\n\npub fn show(x: List(fn() -> Nil)) -> String {\n  \"\"\n}\n",
    )
  signatures.from_glance_module("fake/str", module)
  |> signatures.with_types(typedefs.from_module(
    "fake/str",
    module,
    set.from_list(["erlang"]),
  ))
}

fn answer(
  knowledge_base: effects.KnowledgeBase,
  call: String,
) -> types.EffectSet {
  let assert Ok(module) =
    glance.module(
      "import app/ffi\nimport fake/str\n\nfn loud() -> Nil {\n  ffi.shout()\n}\n\npub fn go() -> String {\n  "
      <> call
      <> "\n}\n",
    )
  let assert [annotation] =
    checker.infer(
      module,
      "app",
      knowledge_base,
      [],
      registry(),
      typeinfo.no_reading(),
      types.all_targets(),
    )
  effect_term.to_effect_set(annotation.effects)
}

pub fn a_reviewed_name_reads_no_run_within_the_record_test() {
  knowledge_base("1.0.1", [])
  |> answer("str.inspect([loud])")
  |> should.equal(types.from_labels([]))
}

pub fn a_name_the_record_does_not_list_runs_its_arguments_test() {
  knowledge_base("1.0.1", [])
  |> answer("str.show([loud])")
  |> should.equal(types.from_labels(runs))
}

pub fn a_reviewed_name_runs_its_arguments_past_the_record_test() {
  knowledge_base("1.0.3", [])
  |> answer("str.inspect([loud])")
  |> should.equal(types.from_labels(runs))
}

pub fn a_written_line_over_a_reviewed_name_keeps_its_own_default_test() {
  knowledge_base("1.0.1", ["assume fake/str.inspect : []"])
  |> answer("str.inspect([loud])")
  |> should.equal(types.from_labels(runs))
  knowledge_base("1.0.1", [
    "assume fake/str.inspect(x: [x]) : [] where runs : []",
  ])
  |> answer("str.inspect([loud])")
  |> should.equal(types.from_labels([]))
}

// The records graded ships

pub fn every_bundled_record_reads_beside_its_catalog_file_test() {
  let directory = support.catalog_directory()
  let assert Ok(paths) = simplifile.get_files(directory)
  let catalog =
    list.filter(paths, string.ends_with(_, ".graded"))
    |> list.sort(string.compare)
  let records =
    list.filter(paths, string.ends_with(_, ".audit"))
    |> list.sort(string.compare)
  list.map(records, fn(path) { string.drop_end(path, 6) })
  |> should.equal(list.map(catalog, fn(path) { string.drop_end(path, 7) }))
  list.each(records, fn(path) {
    let assert Ok(text) = simplifile.read(path)
    case audit.parse(text) {
      Ok(_) -> Nil
      Error(AuditError(line_number:, content:)) ->
        panic as {
          path <> ":" <> string.inspect(line_number) <> ": " <> content
        }
    }
  })
}

pub fn every_bundled_record_names_what_its_catalog_file_answers_for_test() {
  let directory = support.catalog_directory()
  let assert Ok(paths) = simplifile.get_files(directory)
  list.filter(paths, string.ends_with(_, ".audit"))
  |> list.each(fn(path) {
    let assert Ok(text) = simplifile.read(path)
    let assert Ok(file) = audit.parse(text)
    let assert Ok(catalog_text) =
      simplifile.read(string.drop_end(path, 6) <> ".graded")
    let assert Ok(catalog) = annotation.parse_catalog(catalog_text)
    let answered = answered_paths(catalog)
    list.each(file.entries, fn(entry) {
      case named(entry) {
        None -> Nil
        Some(name) ->
          case
            set.contains(answered, name.module)
            || set.contains(answered, name.module <> "." <> name.function)
          {
            True -> Nil
            False ->
              panic as {
                path
                <> " names "
                <> name.module
                <> "."
                <> name.function
                <> ", which its catalog file does not answer for"
              }
          }
      }
    })
  })
}

fn answered_paths(catalog: types.GradedFile) -> set.Set(String) {
  list.fold(catalog.lines, set.new(), fn(acc, line) {
    case line {
      types.AssumeLine(assume, _) ->
        case assume.target, annotation.assume_qualified_name(assume) {
          types.ModuleAssume, _ -> set.insert(acc, assume.module)
          types.FunctionAssume(_), Ok(name) ->
            set.insert(acc, name.module <> "." <> name.function)
          types.FunctionAssume(_), Error(Nil) -> acc
        }
      _ -> acc
    }
  })
}

fn named(entry: audit.AuditEntry) -> option.Option(types.QualifiedName) {
  case entry {
    ReviewedContract(assume:, ..) ->
      annotation.assume_qualified_name(assume) |> option.from_result
    ReviewedName(name:, ..) | ContainerResult(name:, ..) -> Some(name)
    ConstantCarries(name:, ..) -> Some(name)
    ContainerType(..) | Unreviewed(..) -> None
  }
}

// What the catalog publishes

pub fn every_published_contract_is_the_one_its_record_staged_test() {
  let directory = support.catalog_directory()
  let assert Ok(paths) = simplifile.get_files(directory)
  list.filter(paths, string.ends_with(_, ".audit"))
  |> list.each(fn(path) {
    let assert Ok(text) = simplifile.read(path)
    let assert Ok(file) = audit.parse(text)
    let staged =
      audit.contracts(file)
      |> list.filter_map(fn(assume) {
        annotation.assume_qualified_name(assume)
        |> result.map(fn(name) { #(name, assume) })
      })
    let catalog_path = string.drop_end(path, 6) <> ".graded"
    let assert Ok(catalog_text) = simplifile.read(catalog_path)
    let assert Ok(catalog) = annotation.parse_catalog(catalog_text)
    let published =
      annotation.extract_assumes(catalog)
      |> list.filter(fn(assume) { assume.contract != types.no_contract })
      |> list.filter_map(fn(assume) {
        annotation.assume_qualified_name(assume)
        |> result.map(fn(name) { #(name, assume) })
      })
    // Each line carrying a contract states exactly what the review staged,
    // and every staged contract is published.
    #(catalog_path, list.sort(published, by_name))
    |> should.equal(#(catalog_path, list.sort(staged, by_name)))
    // And each is a name the record reviews at a version it covers, so the
    // catalog's no-run default speaks for it there.
    let reviewed =
      file.entries
      |> list.flat_map(covered_versions)
      |> list.fold(set.new(), fn(acc, version) {
        set.union(acc, audit.applicable(file, version).reviewed)
      })
    list.each(published, fn(entry) {
      #(entry.0, set.contains(reviewed, entry.0))
      |> should.equal(#(entry.0, True))
    })
  })
}

fn by_name(
  left: #(types.QualifiedName, types.AssumeAnnotation),
  right: #(types.QualifiedName, types.AssumeAnnotation),
) -> order.Order {
  string.compare(
    left.0.module <> "." <> left.0.function,
    right.0.module <> "." <> right.0.function,
  )
}

fn covered_versions(entry: audit.AuditEntry) -> List(audit.Version) {
  let ends = fn(coverage: audit.Coverage) {
    list.flat_map(coverage.ranges, fn(range) { [range.0, range.1] })
  }
  case entry {
    ReviewedContract(covers:, ..)
    | ReviewedName(covers:, ..)
    | ContainerType(covers:, ..)
    | ConstantCarries(covers:, ..)
    | ContainerResult(covers:, ..) -> ends(covers)
    Unreviewed(..) -> []
  }
}

// On Erlang, `gleam/dict.map_values` and `gleam/dict.fold` run their Gleam
// bodies, which hand a closure calling the caller's callback to the private
// `do_map_values` and `do_fold`. The catalog publishes those helpers' contracts
// so the walked body binds that closure through them, its parameters receiving
// the dictionary's entries. `map_values` then reads exactly; `fold`'s closure
// also passes its accumulator, which no relay maps, so calling the caller's
// callback with it reads `[Unknown]`.
pub fn a_private_helper_a_fallback_body_reaches_is_published_test() {
  let knowledge_base = support.knowledge_base()
  let do_fold = QualifiedName("gleam/dict", "do_fold")
  effects.audited_catalog_answer(knowledge_base, do_fold) |> should.be_true
  let assert Some(#(contract, _bounds)) =
    effects.winning_contract(knowledge_base, do_fold)
  contract.relays
  |> should.equal([
    types.Relay(callback: "fun", positions: [Some("dict"), Some("dict"), None]),
  ])
  let root =
    support.write_fixture("build/audit_private_helper", [
      #("gleam.toml", "name = \"app\"\nversion = \"1.0.0\"\n"),
      #(
        "manifest.toml",
        "packages = [\n  { name = \"gleam_stdlib\", version = \"1.0.5\" },\n]\n",
      ),
      #(
        "src/app.gleam",
        "import gleam/dict\n\npub fn bump(d: dict.Dict(String, Int)) -> dict.Dict(String, Int) {\n  dict.map_values(d, fn(_key, value) { value + 1 })\n}\n\npub fn sum(d: dict.Dict(String, Int)) -> Int {\n  dict.fold(d, 0, fn(acc, _key, value) { acc + value })\n}\n",
      ),
    ])
  support.install_stdlib(root)
  let assert Ok(lines) = graded.inferred_lines(root)
  support.cleanup(root)
  lines
  |> should.equal(["effects app.bump : []", "effects app.sum : [Unknown]"])
}
