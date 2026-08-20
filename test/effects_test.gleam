import generators
import gleam/dict
import gleam/int
import gleam/list
import gleam/option
import gleam/order
import gleam/result
import gleam/set
import gleam/string
import gleeunit/should
import graded/internal/annotation
import graded/internal/effect_term
import graded/internal/effects
import graded/internal/types.{
  type EffectSet, type ParamBound, type QualifiedName, ConstructorRef,
  FunctionRef, OtherExpression, ParamBound, Polymorphic, QualifiedName, Specific,
  Wildcard,
}
import qcheck
import simplifile
import support.{cleanup, write_fixture}

// Knowledge-base lookups
//
// Resolving qualified names against the default knowledge base: catalogued
// effectful functions, pure stdlib modules, and the Unknown fallback.

fn knowledge_base() -> effects.KnowledgeBase {
  effects.empty_knowledge_base()
}

pub fn known_effectful_test() {
  effects.declared_effects(
    knowledge_base(),
    QualifiedName("gleam/io", "println"),
  )
  |> effect_term.to_effect_set
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn known_pure_module_test() {
  effects.declared_effects(knowledge_base(), QualifiedName("gleam/list", "map"))
  |> effect_term.to_effect_set
  |> should.equal(Specific(set.new()))
}

pub fn unknown_function_test() {
  effects.declared_effects(
    knowledge_base(),
    QualifiedName("some/unknown", "thing"),
  )
  |> effect_term.to_effect_set
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

pub fn lookup_known_variant_test() {
  effects.lookup(knowledge_base(), QualifiedName("gleam/io", "debug"))
  |> should.equal(effects.Known(
    effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
    types.FunctionEntry(origin: types.Catalog("gleam_stdlib")),
  ))
}

pub fn lookup_unknown_variant_test() {
  effects.lookup(knowledge_base(), QualifiedName("mystery/module", "foo"))
  |> should.equal(effects.Unknown)
}

// Effect-set formatting
//
// Rendering effect sets as the bracketed, sorted list syntax used in spec
// files.

pub fn format_effect_set_empty_test() {
  effects.format_effect_set(Specific(set.new()))
  |> should.equal("[]")
}

pub fn format_effect_set_sorted_test() {
  effects.format_effect_set(Specific(set.from_list(["Http", "Dom"])))
  |> should.equal("[Dom, Http]")
}

pub fn format_wildcard_set_test() {
  effects.format_effect_set(Wildcard) |> should.equal("[_]")
}

// Spec file effects
//
// Loading `effects` lines from a spec file into a lookup dict; `check` lines
// and missing files contribute nothing.

pub fn load_spec_effects_test() {
  let spec_path = "/tmp/graded_load_spec_effects.graded"
  let _ = simplifile.delete(spec_path)
  let assert Ok(Nil) =
    simplifile.write(
      spec_path,
      "effects myapp/currency.from_string : []
effects myapp/currency.to_string : []
effects myapp/api.handle : [Http]
check myapp/api.handle : [Http]
",
    )

  let spec_effects = effects.load_spec_effects(spec_path)

  dict.get(spec_effects, QualifiedName("myapp/currency", "from_string"))
  |> should.equal(Ok(effect_term.from_effect_set(Specific(set.new()))))

  dict.get(spec_effects, QualifiedName("myapp/currency", "to_string"))
  |> should.equal(Ok(effect_term.from_effect_set(Specific(set.new()))))

  dict.get(spec_effects, QualifiedName("myapp/api", "handle"))
  |> should.equal(
    Ok(effect_term.from_effect_set(Specific(set.from_list(["Http"])))),
  )

  // `check` lines are NOT loaded as effects — only `effects` lines are.
  dict.size(spec_effects) |> should.equal(3)

  let _ = simplifile.delete(spec_path)
  Nil
}

pub fn load_spec_effects_missing_file_test() {
  effects.load_spec_effects("/tmp/graded_does_not_exist.graded")
  |> dict.size()
  |> should.equal(0)
}

// EffectSet lattice laws
//
// Property tests: subset is a partial order with empty as bottom and Wildcard
// as top, and union is its idempotent, commutative join.

pub fn subset_reflexivity_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.is_subset(a, a) |> should.be_true()
}

pub fn subset_transitivity_test() {
  use #(a, b, c) <- qcheck.given(
    qcheck.map2(
      qcheck.map2(
        generators.effect_set_gen(),
        generators.effect_set_gen(),
        fn(a, b) { #(a, b) },
      ),
      generators.effect_set_gen(),
      fn(ab, c) { #(ab.0, ab.1, c) },
    ),
  )
  case types.is_subset(a, b) && types.is_subset(b, c) {
    True -> types.is_subset(a, c) |> should.be_true()
    False -> Nil
  }
}

pub fn subset_antisymmetry_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(
      generators.effect_set_gen(),
      generators.effect_set_gen(),
      fn(a, b) { #(a, b) },
    ),
  )
  case types.is_subset(a, b) && types.is_subset(b, a) {
    True -> a |> should.equal(b)
    False -> Nil
  }
}

pub fn union_commutativity_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(
      generators.effect_set_gen(),
      generators.effect_set_gen(),
      fn(a, b) { #(a, b) },
    ),
  )
  types.union(a, b) |> should.equal(types.union(b, a))
}

pub fn union_associativity_test() {
  use #(a, b, c) <- qcheck.given(
    qcheck.map2(
      qcheck.map2(
        generators.effect_set_gen(),
        generators.effect_set_gen(),
        fn(a, b) { #(a, b) },
      ),
      generators.effect_set_gen(),
      fn(ab, c) { #(ab.0, ab.1, c) },
    ),
  )
  types.union(types.union(a, b), c)
  |> should.equal(types.union(a, types.union(b, c)))
}

pub fn union_idempotence_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.union(a, a) |> should.equal(a)
}

pub fn union_identity_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.union(a, types.empty()) |> should.equal(a)
}

pub fn wildcard_absorbs_union_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.union(Wildcard, a) |> should.equal(Wildcard)
}

pub fn empty_is_bottom_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.is_subset(types.empty(), a) |> should.be_true()
}

pub fn wildcard_is_top_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.is_subset(a, Wildcard) |> should.be_true()
}

pub fn union_monotonicity_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(
      generators.effect_set_gen(),
      generators.effect_set_gen(),
      fn(a, b) { #(a, b) },
    ),
  )
  types.is_subset(a, types.union(a, b)) |> should.be_true()
}

pub fn subset_union_compatibility_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(
      generators.effect_set_gen(),
      generators.effect_set_gen(),
      fn(a, b) { #(a, b) },
    ),
  )
  let subset = types.is_subset(a, b)
  let union_eq = types.union(a, b) == b
  subset |> should.equal(union_eq)
}

// Polymorphic effect sets
//
// Effect sets carrying variables: variable detection, `Unknown`-label
// detection, and how union merges labels and variables across operands.

pub fn has_variables_specific_is_false_test() {
  types.has_variables(types.from_labels(["Stdout"])) |> should.be_false()
}

pub fn has_variables_wildcard_is_false_test() {
  types.has_variables(Wildcard) |> should.be_false()
}

pub fn has_variables_polymorphic_is_true_test() {
  let set: EffectSet = Polymorphic(set.new(), set.from_list(["e"]))
  types.has_variables(set) |> should.be_true()
}

pub fn contains_unknown_specific_with_label_is_true_test() {
  types.contains_unknown(types.from_labels(["Stdout", "Unknown"]))
  |> should.be_true()
}

pub fn contains_unknown_specific_without_label_is_false_test() {
  types.contains_unknown(types.from_labels(["Stdout"])) |> should.be_false()
}

pub fn contains_unknown_polymorphic_with_label_is_true_test() {
  let set: EffectSet =
    Polymorphic(set.from_list(["Unknown"]), set.from_list(["e"]))
  types.contains_unknown(set) |> should.be_true()
}

pub fn contains_unknown_polymorphic_without_label_is_false_test() {
  let set: EffectSet = Polymorphic(set.new(), set.from_list(["e"]))
  types.contains_unknown(set) |> should.be_false()
}

pub fn contains_unknown_wildcard_is_false_test() {
  types.contains_unknown(Wildcard) |> should.be_false()
}

pub fn union_polymorphic_merges_both_test() {
  let a: EffectSet = Polymorphic(set.from_list(["Http"]), set.from_list(["e1"]))
  let b: EffectSet =
    Polymorphic(set.from_list(["Stdout"]), set.from_list(["e2"]))
  types.union(a, b)
  |> should.equal(Polymorphic(
    set.from_list(["Http", "Stdout"]),
    set.from_list(["e1", "e2"]),
  ))
}

pub fn union_polymorphic_and_specific_test() {
  let a: EffectSet = Polymorphic(set.new(), set.from_list(["e"]))
  let b: EffectSet = types.from_labels(["Stdout"])
  types.union(a, b)
  |> should.equal(Polymorphic(set.from_list(["Stdout"]), set.from_list(["e"])))
}

// Semver ordering laws
//
// Property tests over the catalog's version comparison: total-order laws and
// parse/format round-tripping.

fn semver_gen() -> qcheck.Generator(#(Int, Int, Int)) {
  qcheck.map2(
    qcheck.map2(qcheck.bounded_int(0, 20), qcheck.bounded_int(0, 50), fn(a, b) {
      #(a, b)
    }),
    qcheck.bounded_int(0, 100),
    fn(ab, c) { #(ab.0, ab.1, c) },
  )
}

fn semver_string_gen() -> qcheck.Generator(String) {
  qcheck.map(semver_gen(), fn(v) {
    int.to_string(v.0) <> "." <> int.to_string(v.1) <> "." <> int.to_string(v.2)
  })
}

fn version_entry_gen() -> qcheck.Generator(#(#(Int, Int, Int), String)) {
  qcheck.map(semver_gen(), fn(v) {
    let label =
      int.to_string(v.0)
      <> "."
      <> int.to_string(v.1)
      <> "."
      <> int.to_string(v.2)
    #(v, label)
  })
}

pub fn semver_lte_reflexivity_test() {
  use a <- qcheck.given(semver_gen())
  effects.semver_lte(a, a) |> should.be_true()
}

pub fn semver_lte_transitivity_test() {
  use #(a, b, c) <- qcheck.given(
    qcheck.map2(
      qcheck.map2(semver_gen(), semver_gen(), fn(a, b) { #(a, b) }),
      semver_gen(),
      fn(ab, c) { #(ab.0, ab.1, c) },
    ),
  )
  case effects.semver_lte(a, b) && effects.semver_lte(b, c) {
    True -> effects.semver_lte(a, c) |> should.be_true()
    False -> Nil
  }
}

pub fn semver_lte_antisymmetry_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(semver_gen(), semver_gen(), fn(a, b) { #(a, b) }),
  )
  case effects.semver_lte(a, b) && effects.semver_lte(b, a) {
    True -> a |> should.equal(b)
    False -> Nil
  }
}

pub fn semver_lte_totality_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(semver_gen(), semver_gen(), fn(a, b) { #(a, b) }),
  )
  let either = effects.semver_lte(a, b) || effects.semver_lte(b, a)
  either |> should.be_true()
}

pub fn compare_semver_consistent_with_lte_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(semver_gen(), semver_gen(), fn(a, b) { #(a, b) }),
  )
  let cmp = effects.compare_semver(a, b)
  let lte = effects.semver_lte(a, b)
  case cmp {
    order.Lt | order.Eq -> lte |> should.be_true()
    order.Gt -> lte |> should.be_false()
  }
}

pub fn parse_semver_roundtrip_test() {
  use s <- qcheck.given(semver_string_gen())
  let parsed = effects.parse_semver(s)
  let reparsed =
    int.to_string(parsed.0)
    <> "."
    <> int.to_string(parsed.1)
    <> "."
    <> int.to_string(parsed.2)
  reparsed |> should.equal(s)
}

pub fn parse_semver_reads_the_version_before_its_suffix_test() {
  // A pre-release or build suffix orders separately in semver and carries no
  // `major.minor.patch` of its own, so the components are read off the prefix
  // that does — a version whose suffix is dotted included.
  effects.parse_semver("1.2.0") |> should.equal(#(1, 2, 0))
  effects.parse_semver("4.2.0-rc.1") |> should.equal(#(4, 2, 0))
  effects.parse_semver("1.2.0+build.5") |> should.equal(#(1, 2, 0))
  effects.parse_semver("1.2.0-rc.1+build.5") |> should.equal(#(1, 2, 0))
}

pub fn parse_semver_without_numeric_components_test() {
  effects.parse_semver("latest") |> should.equal(#(0, 0, 0))
}

// Path dependencies
//
// Extracting `{ path = ... }` dependencies from gleam.toml, tolerating files
// with none and missing files.

pub fn parse_path_dependencies_test() {
  let toml_path = "test/fixtures/gleam_with_path_deps.toml"
  let content =
    "name = \"myapp\"\nversion = \"1.0.0\"\n\n[dependencies]\ngleam_stdlib = \">= 0.44.0\"\ndep_a = { path = \"../dep_a\" }\ndep_b = { path = \"../dep_b/gleam_lib\" }\n"
  let assert Ok(Nil) = simplifile.write(toml_path, content)
  let deps = effects.parse_path_dependencies(toml_path)
  let assert Ok(Nil) = simplifile.delete(toml_path)
  deps
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> should.equal([
    #("dep_a", "../dep_a"),
    #("dep_b", "../dep_b/gleam_lib"),
  ])
}

pub fn parse_path_dependencies_no_path_deps_test() {
  let toml_path = "test/fixtures/gleam_no_path_deps.toml"
  let content =
    "name = \"myapp\"\nversion = \"1.0.0\"\n\n[dependencies]\ngleam_stdlib = \">= 0.44.0\"\n"
  let assert Ok(Nil) = simplifile.write(toml_path, content)
  let deps = effects.parse_path_dependencies(toml_path)
  let assert Ok(Nil) = simplifile.delete(toml_path)
  deps |> should.equal([])
}

pub fn parse_path_dependencies_missing_file_test() {
  effects.parse_path_dependencies("nonexistent.toml")
  |> should.equal([])
}

// Knowledge-base enrichment
//
// Merging inferred effects and returned operators into the knowledge base:
// existing entries keep priority, new entries are added.

pub fn with_inferred_does_not_overwrite_test() {
  let kb = knowledge_base()
  let inferred =
    dict.from_list([
      #(
        QualifiedName("gleam/io", "println"),
        effect_term.from_effect_set(types.empty()),
      ),
    ])
  let enriched = effects.with_inferred(kb, inferred, types.ProjectInferred)
  // Existing KB entry should take priority (Stdout), not be overwritten to []
  effects.declared_effects(enriched, QualifiedName("gleam/io", "println"))
  |> effect_term.to_effect_set
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn returned_operators_round_trip_test() {
  let kb = knowledge_base()
  let operator = types.TAbs("cb", types.TVar("cb"))
  let enriched =
    effects.with_fresh_returned_operators(
      kb,
      dict.from_list([#(QualifiedName("mylib/foo", "pick"), operator)]),
      types.ProjectInferred,
    )
  effects.lookup_returned_operator(enriched, QualifiedName("mylib/foo", "pick"))
  |> should.equal(
    Ok(effects.ReturnedOperator(operator, effects.Fresh, types.ProjectInferred)),
  )
  effects.lookup_returned_operator(
    enriched,
    QualifiedName("mylib/foo", "absent"),
  )
  |> should.equal(Error(Nil))
}

pub fn with_inferred_adds_new_entries_test() {
  let kb = knowledge_base()
  let inferred =
    dict.from_list([
      #(
        QualifiedName("mylib/foo", "bar"),
        effect_term.from_effect_set(Specific(set.from_list(["Http"]))),
      ),
    ])
  let enriched = effects.with_inferred(kb, inferred, types.ProjectInferred)
  effects.declared_effects(enriched, QualifiedName("mylib/foo", "bar"))
  |> effect_term.to_effect_set
  |> should.equal(Specific(set.from_list(["Http"])))
}

// Entry origins
//
// A term and the source that wrote it are one value in `all_effects`, so the
// merge that picks a term picks its origin with it and `lookup` reports the
// pair. These pin what each writer records, and that a losing source labels
// nothing.

fn external(
  module: String,
  function: String,
  labels: List(String),
) -> types.ExternalAnnotation {
  types.ExternalAnnotation(
    module:,
    target: types.FunctionExternal(function),
    effects: Specific(set.from_list(labels)),
  )
}

fn module_external(
  module: String,
  labels: List(String),
) -> types.ExternalAnnotation {
  types.ExternalAnnotation(
    module:,
    target: types.ModuleExternal,
    effects: Specific(set.from_list(labels)),
  )
}

fn inferred_entry(
  module: String,
  function: String,
  labels: List(String),
) -> dict.Dict(QualifiedName, types.EffectTerm) {
  dict.from_list([
    #(
      QualifiedName(module, function),
      effect_term.from_effect_set(Specific(set.from_list(labels))),
    ),
  ])
}

fn origin_of(
  kb: effects.KnowledgeBase,
  name: QualifiedName,
) -> option.Option(types.LookupOrigin) {
  case effects.lookup(kb, name) {
    effects.Known(_, source) -> option.Some(effects.origin_of(source))
    effects.Unknown -> option.None
  }
}

// The term and the origin `lookup` answers with, so a test can assert that the
// pair agrees rather than that each is separately plausible.
fn entry_of(
  kb: effects.KnowledgeBase,
  name: QualifiedName,
) -> Result(#(EffectSet, types.LookupOrigin), Nil) {
  case effects.lookup(kb, name) {
    effects.Known(term, source) ->
      Ok(#(effect_term.to_effect_set(term), effects.origin_of(source)))
    effects.Unknown -> Error(Nil)
  }
}

pub fn function_external_records_its_origin_test() {
  effects.with_externals(
    effects.new_knowledge_base(),
    [external("app", "now", ["Time"])],
    types.UserExternal,
  )
  |> origin_of(QualifiedName("app", "now"))
  |> should.equal(option.Some(types.UserExternal))
}

pub fn inferred_entry_records_its_origin_test() {
  effects.with_inferred(
    effects.new_knowledge_base(),
    inferred_entry("app", "run", ["Stdout"]),
    types.CommittedSpec,
  )
  |> origin_of(QualifiedName("app", "run"))
  |> should.equal(option.Some(types.CommittedSpec))
}

pub fn an_existing_entry_keeps_its_own_origin_test() {
  // `with_inferred` is existing-wins, so the second merge decides neither the
  // term nor the origin: a losing source must not label an entry it didn't
  // write.
  let kb =
    effects.new_knowledge_base()
    |> effects.with_inferred(
      inferred_entry("app", "run", ["Stdout"]),
      types.CommittedSpec,
    )
    |> effects.with_inferred(
      inferred_entry("app", "run", ["Disk"]),
      types.ProjectInferred,
    )
  origin_of(kb, QualifiedName("app", "run"))
  |> should.equal(option.Some(types.CommittedSpec))
  effects.declared_effects(kb, QualifiedName("app", "run"))
  |> effect_term.to_effect_set
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn a_module_external_names_the_file_that_declared_it_test() {
  // Module-level externals live in their own map and are reported as the module
  // entry, whose origin names both the kind of line and the file it sits in.
  let kb =
    effects.with_externals(
      effects.new_knowledge_base(),
      [module_external("fake_clock", ["Time"])],
      types.Catalog("fake_clock_pkg"),
    )
  effects.lookup(kb, QualifiedName("fake_clock", "now"))
  |> should.equal(effects.Known(
    effect_term.from_effect_set(Specific(set.from_list(["Time"]))),
    types.ModuleExternalEntry(
      origin: types.ModuleExternalOrigin(source: types.Catalog("fake_clock_pkg")),
    ),
  ))
}

pub fn a_dependency_spec_entry_names_its_package_test() {
  let packages = "build/eff_dep_origin/packages"
  let _ = simplifile.delete("build/eff_dep_origin")
  let assert Ok(Nil) = simplifile.create_directory_all(packages <> "/dep")
  let assert Ok(Nil) =
    simplifile.write(
      packages <> "/dep/dep.graded",
      "effects dep.run : [Time]\n",
    )

  effects.load_knowledge_base(packages, "missing_manifest.toml", dict.new())
  |> origin_of(QualifiedName("dep", "run"))
  |> should.equal(option.Some(types.DependencySpec("dep")))

  let _ = simplifile.delete("build/eff_dep_origin")
  Nil
}

pub fn a_catalog_entry_names_its_package_test() {
  // `gleam/io.println` is an `external effects` line in the bundled catalog, so
  // this covers the catalog's route through `with_externals` — the one that
  // made the origin a parameter rather than a constant.
  let root = "build/eff_catalog_origin"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/manifest.toml",
      "packages = [\n  { name = \"gleam_stdlib\", version = \"0.70.0\" },\n]\n",
    )

  effects.load_knowledge_base(
    root <> "/packages",
    root <> "/manifest.toml",
    dict.new(),
  )
  |> origin_of(QualifiedName("gleam/io", "println"))
  |> should.equal(option.Some(types.Catalog("gleam_stdlib")))

  let _ = simplifile.delete(root)
  Nil
}

pub fn a_dependency_spec_overriding_the_catalog_reports_both_test() {
  // The term and the origin come out of one merge, so the source named is the
  // one whose term won — not the source the losing merge would have named.
  let root = "build/eff_origin_agreement"
  let packages = root <> "/packages"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) =
    simplifile.create_directory_all(packages <> "/gleam_stdlib")
  let assert Ok(Nil) =
    simplifile.write(
      packages <> "/gleam_stdlib/gleam_stdlib.graded",
      "effects gleam/io.println : [Shipped]\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/manifest.toml",
      "packages = [\n  { name = \"gleam_stdlib\", version = \"0.70.0\" },\n]\n",
    )

  effects.load_knowledge_base(packages, root <> "/manifest.toml", dict.new())
  |> entry_of(QualifiedName("gleam/io", "println"))
  |> should.equal(
    Ok(#(
      Specific(set.from_list(["Shipped"])),
      types.DependencySpec("gleam_stdlib"),
    )),
  )

  let _ = simplifile.delete(root)
  Nil
}

pub fn a_catalog_effects_line_beats_another_packages_external_test() {
  // Two catalog files key the same function: one with an `effects` line, one
  // with an `external effects` line. The `effects` line decides the term, so it
  // must decide the origin too — the external's package never claims it.
  let root =
    write_fixture("build/eff_catalog_clash", [
      #("catalog/a_pkg@1.0.0.graded", "effects shared/mod.run : [Http]\n"),
      #(
        "catalog/b_pkg@1.0.0.graded",
        "external effects shared/mod.run : [Disk]\n",
      ),
      #("manifest.toml", two_package_manifest),
    ])

  let #(all_effects, _module_effects, _params, _type_fields) =
    effects.load_catalog(root <> "/catalog", root <> "/manifest.toml")
  dict.get(all_effects, QualifiedName("shared/mod", "run"))
  |> result.map(fn(entry) { #(effect_term.to_effect_set(entry.0), entry.1) })
  |> should.equal(
    Ok(#(Specific(set.from_list(["Http"])), types.Catalog("a_pkg"))),
  )

  cleanup(root)
}

pub fn a_catalog_external_beats_its_own_files_effects_line_test() {
  // One catalog file keys the same function both ways. The `external effects`
  // line decides the term, pairing with the empty bounds the file's own reader
  // records for a declared name — the `effects` line's polymorphic term would
  // leave `cb` free with nothing left to bind it.
  let root =
    write_fixture("build/eff_catalog_same_file_clash", [
      #(
        "catalog/a_pkg@1.0.0.graded",
        "effects shared/mod.run(cb: [cb]) : [cb]\nexternal effects shared/mod.run : [Disk]\n",
      ),
      #(
        "manifest.toml",
        "packages = [\n  { name = \"a_pkg\", version = \"1.0.0\" },\n]\n",
      ),
    ])

  let #(all_effects, _module_effects, params, _type_fields) =
    effects.load_catalog(root <> "/catalog", root <> "/manifest.toml")
  dict.get(all_effects, QualifiedName("shared/mod", "run"))
  |> result.map(fn(entry) { #(effect_term.to_effect_set(entry.0), entry.1) })
  |> should.equal(
    Ok(#(Specific(set.from_list(["Disk"])), types.Catalog("a_pkg"))),
  )
  dict.get(params, QualifiedName("shared/mod", "run"))
  |> should.equal(Ok([]))

  cleanup(root)
}

// The manifest both cross-file clash fixtures install: each of the two catalog
// files is selected only if its package is installed.
const two_package_manifest = "packages = [
  { name = \"a_pkg\", version = \"1.0.0\" },
  { name = \"b_pkg\", version = \"1.0.0\" },
]
"

// What `load_catalog` settles on for `shared/mod.run` when two catalog files key
// it: `poly_package`'s polymorphic `effects` line and `ext_package`'s
// `external effects` line.
fn catalog_clash_entry(
  root: String,
  poly_package: String,
  ext_package: String,
) -> #(
  Result(#(types.EffectTerm, types.LookupOrigin), Nil),
  Result(List(ParamBound), Nil),
) {
  let root =
    write_fixture(root, [
      #(
        "catalog/" <> poly_package <> "@1.0.0.graded",
        "effects shared/mod.run(cb: [cb]) : [cb]\n",
      ),
      #(
        "catalog/" <> ext_package <> "@1.0.0.graded",
        "external effects shared/mod.run : [Disk]\n",
      ),
      #("manifest.toml", two_package_manifest),
    ])
  let #(all_effects, _module_effects, params, _type_fields) =
    effects.load_catalog(root <> "/catalog", root <> "/manifest.toml")
  cleanup(root)
  #(
    dict.get(all_effects, QualifiedName("shared/mod", "run")),
    dict.get(params, QualifiedName("shared/mod", "run")),
  )
}

pub fn a_catalog_effects_lines_bounds_travel_with_its_term_test() {
  // The `effects` line decides the term across files, so the file that wrote it
  // must decide the bounds too: the external's file records empty bounds for
  // the name, and pairing those with this term leaves `cb` with nothing to bind
  // it.
  catalog_clash_entry("build/eff_catalog_bounds_clash", "a_pkg", "b_pkg")
  |> should.equal(#(
    Ok(#(types.TVar("cb"), types.Catalog("a_pkg"))),
    Ok([ParamBound("cb", types.TVar("cb"))]),
  ))
}

pub fn a_catalog_clash_resolves_the_same_either_way_round_test() {
  // The same clash with the two files swapped. Which file the fold reaches last
  // is the catalog directory's own order, so the pair pins both: in one of the
  // two the losing file is folded last, and its empty bounds must not outlive
  // its term there either.
  catalog_clash_entry(
    "build/eff_catalog_bounds_clash_swapped",
    "b_pkg",
    "a_pkg",
  )
  |> should.equal(#(
    Ok(#(types.TVar("cb"), types.Catalog("b_pkg"))),
    Ok([ParamBound("cb", types.TVar("cb"))]),
  ))
}

// Dependency-declared externals
//
// A dependency's own `external effects` lines are part of what it ships: the
// function-level ones key `all_effects`, the module-level ones the fallback
// tier. These pin where those lines land against every other source, and that a
// term the external decides brings its (empty) bounds with it.

// Build a package's spec on disk and read it back through `load_dep_spec`, so a
// test states what the dependency ships as spec text rather than as records.
fn dep_spec(root: String, package: String, source: String) -> effects.DepSpec {
  write_fixture(root, [#(package <> ".graded", source)])
  let spec = effects.load_dep_spec(root, package)
  cleanup(root)
  spec
}

// Install a package's spec under a `build/packages`-shaped tree and load the
// knowledge base from it, with no catalog in reach.
fn installed_dep(
  root: String,
  package: String,
  source: String,
) -> effects.KnowledgeBase {
  write_fixture(root, [#(dep_spec_path(package), source)])
  let kb =
    effects.load_knowledge_base(
      root <> "/packages",
      root <> "/missing_manifest.toml",
      dict.new(),
    )
  cleanup(root)
  kb
}

// One installed package's spec, at its `build/packages`-shaped location under a
// fixture root.
fn dep_spec_path(package: String) -> String {
  "packages/" <> package <> "/" <> package <> ".graded"
}

pub fn a_dependency_function_external_resolves_test() {
  // The line the dep author wrote for its FFI. Before it was read, every
  // consumer resolved `dep/ffi.now` to [Unknown].
  installed_dep(
    "build/eff_dep_fn_external",
    "dep",
    "external effects dep/ffi.now : [Time]\n",
  )
  |> entry_of(QualifiedName("dep/ffi", "now"))
  |> should.equal(
    Ok(#(Specific(set.from_list(["Time"])), types.DependencySpec("dep"))),
  )
}

pub fn a_dependency_module_external_resolves_test() {
  // A dep's module-level external governs every function in that module, and is
  // reported as the module entry naming the shipped spec it sits in.
  installed_dep(
    "build/eff_dep_module_external",
    "dep",
    "external effects dep/internal : [Db]\n",
  )
  |> effects.lookup(QualifiedName("dep/internal", "anything"))
  |> should.equal(effects.Known(
    effect_term.from_effect_set(Specific(set.from_list(["Db"]))),
    types.ModuleExternalEntry(
      origin: types.ModuleExternalOrigin(source: types.DependencySpec("dep")),
    ),
  ))
}

pub fn a_dependency_external_beats_its_own_effects_line_test() {
  // A well-formed spec never carries both — `graded infer` writes no `effects`
  // line for an externally-declared function — so the clash means a stale line
  // and the external is the one the author opted into. The bounds must follow
  // the same decision: the spec reader empties the bounds of an
  // externally-declared function, and pairing those with the `effects` line's
  // polymorphic term would leave `cb` free with nothing left to bind it.
  let kb =
    installed_dep(
      "build/eff_dep_external_clash",
      "dep",
      "effects dep.run(cb: [cb]) : [cb]\nexternal effects dep.run : [Time]\n",
    )
  entry_of(kb, QualifiedName("dep", "run"))
  |> should.equal(
    Ok(#(Specific(set.from_list(["Time"])), types.DependencySpec("dep"))),
  )
  effects.lookup_param_bounds(kb, QualifiedName("dep", "run"))
  |> should.equal([])
}

pub fn a_user_external_beats_a_dependency_external_test() {
  // The composition `load_project_context` performs: the knowledge base is built
  // from the deps, then the consumer's own externals are applied over it.
  installed_dep(
    "build/eff_dep_vs_user_external",
    "dep",
    "external effects dep/ffi.now : [Time]\n",
  )
  |> effects.with_externals(
    [external("dep/ffi", "now", ["Mocked"])],
    types.UserExternal,
  )
  |> entry_of(QualifiedName("dep/ffi", "now"))
  |> should.equal(
    Ok(#(Specific(set.from_list(["Mocked"])), types.UserExternal)),
  )
}

pub fn a_dependency_external_beats_the_catalog_test() {
  // A shipped external is the package author's own word on its FFI, so it
  // outranks graded's bundled description of the same function.
  let root = "build/eff_dep_external_vs_catalog"
  write_fixture(root, [
    #(
      dep_spec_path("gleam_stdlib"),
      "external effects gleam/io.println : [Shipped]\n",
    ),
    #(
      "manifest.toml",
      "packages = [\n  { name = \"gleam_stdlib\", version = \"0.70.0\" },\n]\n",
    ),
  ])

  effects.load_knowledge_base(
    root <> "/packages",
    root <> "/manifest.toml",
    dict.new(),
  )
  |> entry_of(QualifiedName("gleam/io", "println"))
  |> should.equal(
    Ok(#(
      Specific(set.from_list(["Shipped"])),
      types.DependencySpec("gleam_stdlib"),
    )),
  )

  cleanup(root)
}

// Path-dependency spec precedence
//
// A path dep's spec is folded in after the catalog is already loaded, so its
// merge decides the order by origin rather than by arrival: it overrides what
// the catalog wrote and yields to everything the consumer wrote.

pub fn a_path_dep_spec_overrides_a_catalog_entry_test() {
  // Both kinds of line the spec can decide a term with, against the catalog
  // entry the documented order puts below them. The `effects` line's bounds
  // travel with its term — a term that binds `cb` is useless without them.
  let kb =
    effects.new_knowledge_base()
    |> effects.with_externals(
      [external("dep/ffi", "now", ["Catalogued"]), external("dep", "run", [])],
      types.Catalog("dep"),
    )
    |> effects.with_path_dep_spec(
      dep_spec(
        "build/eff_path_dep_over_catalog",
        "dep",
        "external effects dep/ffi.now : [Time]\neffects dep.run(cb: [cb]) : [cb]\n",
      ),
      types.PathDependency("dep"),
    )
  entry_of(kb, QualifiedName("dep/ffi", "now"))
  |> should.equal(
    Ok(#(Specific(set.from_list(["Time"])), types.PathDependency("dep"))),
  )
  origin_of(kb, QualifiedName("dep", "run"))
  |> should.equal(option.Some(types.PathDependency("dep")))
  effects.lookup_param_bounds(kb, QualifiedName("dep", "run"))
  |> should.equal([
    ParamBound(
      name: "cb",
      effects: effect_term.from_effect_set(Polymorphic(
        set.new(),
        set.from_list(["cb"]),
      )),
    ),
  ])
}

pub fn a_path_dep_external_drops_a_catalog_entrys_bounds_test() {
  // The bounds a name carries are the ones recorded for the term that won: a
  // bound-less `external effects` line overriding a polymorphic catalog entry
  // leaves its ground term standing alone, with the catalog's bounds gone.
  let name = QualifiedName("dep", "run")
  // The catalog's `effects dep.run(cb: [cb]) : [cb]`: a term binding `cb`, and
  // the bound that discharges it.
  let cb =
    effect_term.from_effect_set(Polymorphic(set.new(), set.from_list(["cb"])))
  let kb =
    effects.new_knowledge_base()
    |> effects.with_inferred(
      dict.from_list([#(name, cb)]),
      types.Catalog("dep"),
    )
    |> effects.with_inferred_params(
      dict.from_list([#(name, [ParamBound(name: "cb", effects: cb)])]),
    )
    |> effects.with_path_dep_spec(
      dep_spec(
        "build/eff_path_dep_drops_catalog_bounds",
        "dep",
        "external effects dep.run : [Time]\n",
      ),
      types.PathDependency("dep"),
    )
  entry_of(kb, name)
  |> should.equal(
    Ok(#(Specific(set.from_list(["Time"])), types.PathDependency("dep"))),
  )
  effects.lookup_param_bounds(kb, name)
  |> should.equal([])
}

pub fn a_path_dep_spec_yields_to_a_user_external_test() {
  // The consumer's own declaration is not overridable by a dependency, and the
  // bounds standing beside it stay put too: the kept term is the one they were
  // recorded for.
  let bounds = [
    ParamBound(
      name: "cb",
      effects: effect_term.from_effect_set(Specific(set.from_list(["Ui"]))),
    ),
  ]
  let kb =
    effects.new_knowledge_base()
    |> effects.with_externals(
      [external("dep", "run", ["Mocked"])],
      types.UserExternal,
    )
    |> effects.with_inferred_params(
      dict.from_list([#(QualifiedName("dep", "run"), bounds)]),
    )
    |> effects.with_path_dep_spec(
      dep_spec(
        "build/eff_path_dep_under_user",
        "dep",
        "effects dep.run(cb: [cb]) : [cb]\n",
      ),
      types.PathDependency("dep"),
    )
  entry_of(kb, QualifiedName("dep", "run"))
  |> should.equal(
    Ok(#(Specific(set.from_list(["Mocked"])), types.UserExternal)),
  )
  effects.lookup_param_bounds(kb, QualifiedName("dep", "run"))
  |> should.equal(bounds)
}

pub fn a_path_dep_module_external_overrides_only_the_catalogs_test() {
  // The same origin rule one tier down: a path dep's module-level external
  // replaces the catalog's word on that module and yields to the consumer's.
  let spec =
    dep_spec(
      "build/eff_path_dep_module_external",
      "dep",
      "external effects dep/catalogued : [Time]\nexternal effects dep/declared : [Time]\n",
    )
  let kb =
    effects.new_knowledge_base()
    |> effects.with_externals(
      [module_external("dep/catalogued", ["Catalogued"])],
      types.Catalog("dep"),
    )
    |> effects.with_externals(
      [module_external("dep/declared", ["Mocked"])],
      types.UserExternal,
    )
    |> effects.with_path_dep_spec(spec, types.PathDependency("dep"))
  entry_of(kb, QualifiedName("dep/catalogued", "anything"))
  |> should.equal(
    Ok(#(
      Specific(set.from_list(["Time"])),
      types.ModuleExternalOrigin(source: types.PathDependency("dep")),
    )),
  )
  entry_of(kb, QualifiedName("dep/declared", "anything"))
  |> should.equal(
    Ok(#(
      Specific(set.from_list(["Mocked"])),
      types.ModuleExternalOrigin(source: types.UserExternal),
    )),
  )
}

pub fn a_path_dep_function_entry_beats_a_module_external_test() {
  // A consumer's module-level external lives in the fallback tier `lookup`
  // reaches only after `all_effects` misses, so a path dep's function-keyed
  // entry answers first — per-function beats module-level, whoever wrote it.
  let kb =
    effects.new_knowledge_base()
    |> effects.with_externals(
      [module_external("dep/ffi", ["Mocked"])],
      types.UserExternal,
    )
    |> effects.with_path_dep_spec(
      dep_spec(
        "build/eff_path_dep_over_module_external",
        "dep",
        "external effects dep/ffi.now : [Time]\n",
      ),
      types.PathDependency("dep"),
    )
  effects.lookup(kb, QualifiedName("dep/ffi", "now"))
  |> should.equal(effects.Known(
    effect_term.from_effect_set(Specific(set.from_list(["Time"]))),
    types.FunctionEntry(origin: types.PathDependency("dep")),
  ))
  // Every other function in the module still answers from the consumer's line.
  origin_of(kb, QualifiedName("dep/ffi", "later"))
  |> should.equal(
    option.Some(types.ModuleExternalOrigin(source: types.UserExternal)),
  )
}

pub fn a_source_inferred_path_dep_yields_to_the_catalog_test() {
  // The asymmetry the spec branch does not share: a spec-less path dep is
  // inferred from source through `with_inferred`, which gap-fills, so a catalog
  // entry for the same function keeps the term and the origin. Inference yields
  // [Unknown] for the FFI bodies a catalog entry describes precisely, so
  // reordering this needs its own design.
  effects.new_knowledge_base()
  |> effects.with_externals(
    [external("dep/ffi", "now", ["Catalogued"])],
    types.Catalog("dep"),
  )
  |> effects.with_inferred(
    inferred_entry("dep/ffi", "now", ["Unknown"]),
    types.PathDependency("dep"),
  )
  |> entry_of(QualifiedName("dep/ffi", "now"))
  |> should.equal(
    Ok(#(Specific(set.from_list(["Catalogued"])), types.Catalog("dep"))),
  )
}

// Catalog version selection
//
// Reading the bundled `{package}@{version}.graded` names off disk, and picking
// the file a package's installed version resolves to: an eligible entry (at or
// below the installed version) whenever one exists, else the highest bundled.

// The three-file catalog the selection tests below select from, plus a name
// that carries no version and is skipped.
fn catalog_fixture(root: String) -> List(effects.CatalogFile) {
  let root =
    write_fixture(root, [
      #("lustre@4.0.0.graded", "effects lustre/x.a : []\n"),
      #("lustre@5.0.0.graded", "effects lustre/x.a : []\n"),
      #("argv@1.1.0.graded", "effects argv.load : []\n"),
      #("README", "not a catalog file\n"),
    ])
  let assert Ok(files) = effects.bundled_catalog_files(root)
  cleanup(root)
  files
}

// Catalog files by `package@version`, so an assertion does not depend on the
// order the directory walk returns them in.
fn file_labels(files: List(effects.CatalogFile)) -> List(String) {
  files
  |> list.map(fn(file) { file.package <> "@" <> file.version })
  |> list.sort(string.compare)
}

pub fn bundled_catalog_files_reads_the_versioned_names_test() {
  catalog_fixture("build/eff_catalog_listing")
  |> file_labels
  |> should.equal(["argv@1.1.0", "lustre@4.0.0", "lustre@5.0.0"])
}

pub fn bundled_catalog_files_keeps_the_raw_version_string_test() {
  // `parse_semver` reads `1.2.0-rc1` as `#(1, 2, 0)`; the raw string is what a
  // caller prints, so both survive side by side.
  let root =
    write_fixture("build/eff_catalog_prerelease", [
      #("beta@1.2.0-rc1.graded", "effects beta.run : []\n"),
    ])
  let assert Ok(files) = effects.bundled_catalog_files(root)
  cleanup(root)
  files
  |> list.map(fn(file) { #(file.package, file.version, file.parsed) })
  |> should.equal([#("beta", "1.2.0-rc1", #(1, 2, 0))])
}

pub fn bundled_catalog_files_reports_an_unreadable_directory_test() {
  effects.bundled_catalog_files("build/eff_catalog_missing")
  |> result.is_error
  |> should.be_true()
}

pub fn select_catalog_file_picks_the_highest_at_or_below_installed_test() {
  let files = catalog_fixture("build/eff_catalog_select")
  effects.select_catalog_file(files, "lustre", "5.7.0")
  |> selected_version
  |> should.equal(Ok(#("5.0.0", Eligible)))
  // Below the highest bundled file: the lower one is the eligible pick, which
  // is what tells "highest ≤ installed" apart from "highest bundled".
  effects.select_catalog_file(files, "lustre", "4.5.0")
  |> selected_version
  |> should.equal(Ok(#("4.0.0", Eligible)))
}

pub fn select_catalog_file_falls_back_to_the_highest_bundled_test() {
  // Nothing bundled at or below 3.0.0, so the fall-back is the highest file,
  // not the lowest — and the selection says which rule it was.
  catalog_fixture("build/eff_catalog_select_fallback")
  |> effects.select_catalog_file("lustre", "3.0.0")
  |> selected_version
  |> should.equal(Ok(#("5.0.0", FellBack)))
}

// Which rule a selection reports, as a value an assertion can name.
type SelectionRule {
  Eligible
  FellBack
}

fn selected_version(
  selection: Result(effects.CatalogSelection, Nil),
) -> Result(#(String, SelectionRule), Nil) {
  use selection <- result.map(selection)
  case selection {
    effects.Selected(file) -> #(file.version, Eligible)
    effects.HighestBundled(file) -> #(file.version, FellBack)
  }
}

pub fn select_catalog_file_without_a_file_for_the_package_test() {
  catalog_fixture("build/eff_catalog_select_absent")
  |> effects.select_catalog_file("wisp", "1.0.0")
  |> should.equal(Error(Nil))
}

pub fn pick_best_version_eligible_test() {
  use #(versions, installed) <- qcheck.given(
    qcheck.map2(
      qcheck.map2(
        version_entry_gen(),
        qcheck.list_from(version_entry_gen()),
        fn(first, rest) { [first, ..rest] },
      ),
      semver_gen(),
      fn(vs, inst) { #(vs, inst) },
    ),
  )
  case effects.pick_best_version(versions, installed) {
    Ok(pick) -> {
      let assert Ok(picked) = list.find(versions, fn(v) { v.1 == pick.value })
      let has_eligible =
        list.any(versions, fn(v) { effects.semver_lte(v.0, installed) })
      // The rule the pick reports is the rule that fired, so a caller
      // rendering it says what the pick actually did.
      case has_eligible, pick {
        True, effects.AtOrBelowInstalled(_) ->
          effects.semver_lte(picked.0, installed) |> should.be_true()
        False, effects.HighestAvailable(_) -> Nil
        True, effects.HighestAvailable(_)
        | False, effects.AtOrBelowInstalled(_)
        -> should.fail()
      }
    }
    Error(Nil) -> Nil
  }
}

// Argument value effects
//
// Construction-index value resolution: a FunctionRef resolves through
// the knowledge base, constructors are pure, anything else is Unknown.

pub fn argument_value_effects_resolves_function_ref_test() {
  // A FunctionRef resolves against the KB, including inferred project effects.
  // This is what lets `run` and `run_infer` agree on a constructor field wired
  // to a qualified project function once the spec carries its effects.
  let kb =
    effects.with_inferred(
      knowledge_base(),
      dict.from_list([
        #(
          QualifiedName("myapp/log", "emit"),
          effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
        ),
      ]),
      types.ProjectInferred,
    )
  effects.argument_value_effects(
    kb,
    FunctionRef(QualifiedName("myapp/log", "emit")),
  )
  |> effect_term.to_effect_set
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn argument_value_effects_constructor_is_pure_test() {
  effects.argument_value_effects(knowledge_base(), ConstructorRef)
  |> effect_term.to_effect_set
  |> should.equal(Specific(set.new()))
}

pub fn argument_value_effects_other_is_unknown_test() {
  effects.argument_value_effects(knowledge_base(), OtherExpression)
  |> effect_term.to_effect_set
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

// Type-field registry
//
// Type-field keys are qualified by the defining module (no cross-module
// collision), and dependency spec `type` lines load into the registry.

pub fn type_fields_distinguish_modules_test() {
  // Two `Validator` types in different modules, same field — must NOT conflate.
  let kb =
    effects.with_type_fields(
      knowledge_base(),
      [
        types.TypeFieldAnnotation(
          option.Some("app/a"),
          "Validator",
          "f",
          effect_term.from_effect_set(Specific(set.from_list(["Http"]))),
        ),
        types.TypeFieldAnnotation(
          option.Some("app/b"),
          "Validator",
          "f",
          effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
        ),
      ],
      types.CommittedSpec,
    )
  let assert Ok(a) = effects.lookup_type_field(kb, "app/a", "Validator", "f")
  effect_term.to_effect_set(a.effects)
  |> should.equal(Specific(set.from_list(["Http"])))
  let assert Ok(b) = effects.lookup_type_field(kb, "app/b", "Validator", "f")
  effect_term.to_effect_set(b.effects)
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn load_knowledge_base_loads_dependency_type_fields_test() {
  // A dependency's committed spec under `build/packages` carries a module-
  // qualified `type` line. `load_knowledge_base` must fold it into the registry
  // so a consumer's field call against that dependency type resolves, rather
  // than dropping `type` lines as it did before.
  let packages = "build/eff_dep_typefield/packages"
  let _ = simplifile.delete("build/eff_dep_typefield")
  let assert Ok(Nil) = simplifile.create_directory_all(packages <> "/dep")
  let assert Ok(Nil) =
    simplifile.write(
      packages <> "/dep/dep.graded",
      "type dep/repo.Repo.find : [Storage]\n",
    )

  let kb =
    effects.load_knowledge_base(packages, "missing_manifest.toml", dict.new())
  let assert Ok(field) =
    effects.lookup_type_field(kb, "dep/repo", "Repo", "find")
  effect_term.to_effect_set(field.effects)
  |> should.equal(Specific(set.from_list(["Storage"])))

  let _ = simplifile.delete("build/eff_dep_typefield")
  Nil
}

// Committed parameter bounds
//
// Whichever annotation decides a function's effect term decides its bounds too.
// The reader records an entry for every function a spec speaks for — empty
// where the deciding line carries no bounds — because an empty entry is what
// stops a later inference pass from gap-filling a mismatched pair.

fn spec_params(source: String) -> dict.Dict(QualifiedName, List(ParamBound)) {
  let assert Ok(file) = annotation.parse_file(source)
  effects.load_spec_params_from_file(file)
}

pub fn bound_less_effects_line_records_an_empty_entry_test() {
  spec_params("effects app.run : [Stdout]\n")
  |> dict.get(QualifiedName("app", "run"))
  |> should.equal(Ok([]))
}

pub fn effects_line_bounds_are_recorded_test() {
  let assert Ok(bounds) =
    spec_params("effects app.run(f: [f]) : [f]\n")
    |> dict.get(QualifiedName("app", "run"))
  bounds |> list.map(fn(bound) { bound.name }) |> should.equal(["f"])
}

pub fn check_line_bounds_are_not_recorded_test() {
  // A `check` line's bounds are a budget scoped to that check, not a global
  // fact about the function, and the line doesn't decide the term either.
  spec_params("check app.run(f: [Stdout]) : []\n")
  |> dict.get(QualifiedName("app", "run"))
  |> should.equal(Error(Nil))
}

pub fn externally_declared_function_records_an_empty_entry_test() {
  // The external term wins in `all_effects` and is ground by construction, so
  // the stale `effects` line's bounds must not pair with it.
  spec_params(
    "external effects app.run : [Time]\neffects app.run(cb: [cb]) : [cb]\n",
  )
  |> dict.get(QualifiedName("app", "run"))
  |> should.equal(Ok([]))
}

pub fn dependency_check_line_bounds_stay_out_of_the_knowledge_base_test() {
  // The same scoping one package boundary away: a dependency's `check` budget
  // is local to that check, so loading its spec must not install the budget as
  // a global fact about `dep.run`. Its `effects` line decides both halves.
  let packages = "build/eff_dep_checkbounds/packages"
  let _ = simplifile.delete("build/eff_dep_checkbounds")
  let assert Ok(Nil) = simplifile.create_directory_all(packages <> "/dep")
  let assert Ok(Nil) =
    simplifile.write(
      packages <> "/dep/dep.graded",
      "check dep.run(f: [Stdout]) : []\neffects dep.run : [Time]\n",
    )

  let kb =
    effects.load_knowledge_base(packages, "missing_manifest.toml", dict.new())
  effects.lookup_param_bounds(kb, QualifiedName("dep", "run"))
  |> should.equal([])
  effects.declared_effects(kb, QualifiedName("dep", "run"))
  |> effect_term.to_effect_set
  |> should.equal(Specific(set.from_list(["Time"])))

  let _ = simplifile.delete("build/eff_dep_checkbounds")
  Nil
}

// Catalog directory resolution
//
// The catalog directory resolves via graded's own install location (its
// bundled `priv`), not a bare cwd-relative path — so an out-of-tree run still
// finds the catalog instead of silently degrading every catalogued call to
// [Unknown].

pub fn catalog_directory_anchored_on_install_location_test() {
  let directory = effects.catalog_directory()

  // The bundled path ends at `priv/catalog` but is prefixed by the install
  // location, so it differs from the bare cwd-relative fallback.
  string.ends_with(directory, "priv/catalog")
  |> should.be_true()
  { directory != "priv/catalog" }
  |> should.be_true()

  // It points at a real directory holding catalog spec files.
  simplifile.is_directory(directory)
  |> should.equal(Ok(True))
  let assert Ok(files) = simplifile.get_files(directory)
  list.any(files, string.ends_with(_, ".graded"))
  |> should.be_true()
}

// Foreign code a dependency ships
//
// A dependency's spec is as capable of carrying a stale line for its own
// `@external` as this package's spec is for its own — and the consumer's
// evidence for which of its functions are foreign is the dependency's source,
// not its spec. These pin what survives the sanitizing that runs as each spec
// loads: a declaration does, inference over a fallback body does not, and a
// dropped entry uncovers whatever tier the merges would otherwise have buried.

// A dependency `@external` declaring an implementation for every target it is
// compiled for, so no fallback of its ever runs.
fn foreign_declared_everywhere() -> types.ForeignFunction {
  types.ForeignFunction(
    runs_fallback_body: False,
    compiled_targets: types.every_target(),
    declared_targets: types.every_target(),
  )
}

// One declaring an implementation for javascript alone, so its Gleam fallback
// is what runs on erlang.
fn foreign_with_running_fallback() -> types.ForeignFunction {
  types.ForeignFunction(
    runs_fallback_body: True,
    compiled_targets: types.every_target(),
    declared_targets: set.from_list(["javascript"]),
  )
}

// A `build/packages`-shaped tree holding one package's spec, loaded with
// `foreign` standing in for what a scan of that package's source found.
fn installed_dep_over_source(
  root: String,
  package: String,
  source: String,
  manifest: String,
  foreign: List(#(QualifiedName, types.ForeignFunction)),
) -> effects.KnowledgeBase {
  write_fixture(root, [
    #(dep_spec_path(package), source),
    #("manifest.toml", manifest),
  ])
  let kb =
    effects.load_knowledge_base(
      root <> "/packages",
      root <> "/manifest.toml",
      dict.from_list(foreign),
    )
  cleanup(root)
  kb
}

pub fn a_dependency_effects_line_for_its_own_external_is_dropped_test() {
  // The dep's source declares `dep/ffi.now` `@external`, so its shipped
  // `effects` line is inference over a fallback body its FFI needn't match.
  // Nothing else keys the name, so it resolves to [Unknown].
  installed_dep_over_source(
    "build/eff_dep_stale_external",
    "dep",
    "effects dep/ffi.now : []\n",
    "",
    [
      #(QualifiedName("dep/ffi", "now"), foreign_declared_everywhere()),
    ],
  )
  |> entry_of(QualifiedName("dep/ffi", "now"))
  |> should.equal(Error(Nil))
}

pub fn a_dependency_external_line_for_its_own_external_answers_test() {
  // The declaring form of the same line still answers: what the rule refuses is
  // inference over a body, not the dependency author's declaration.
  installed_dep_over_source(
    "build/eff_dep_declared_external",
    "dep",
    "external effects dep/ffi.now : [Time]\n",
    "",
    [
      #(QualifiedName("dep/ffi", "now"), foreign_declared_everywhere()),
    ],
  )
  |> entry_of(QualifiedName("dep/ffi", "now"))
  |> should.equal(
    Ok(#(Specific(set.from_list(["Time"])), types.DependencySpec("dep"))),
  )
}

pub fn a_dependency_effects_line_on_an_ordinary_function_answers_test() {
  // The rule is scoped to the dep's foreign names. An `effects` line for an
  // ordinary dep function is inference over a body every caller runs, and
  // answers exactly as before.
  installed_dep_over_source(
    "build/eff_dep_ordinary",
    "dep",
    "effects dep/ffi.now : [Time]\neffects dep/ffi.plain : [Disk]\n",
    "",
    [
      #(QualifiedName("dep/ffi", "now"), foreign_declared_everywhere()),
    ],
  )
  |> entry_of(QualifiedName("dep/ffi", "plain"))
  |> should.equal(
    Ok(#(Specific(set.from_list(["Disk"])), types.DependencySpec("dep"))),
  )
}

pub fn a_stale_dependency_effects_line_does_not_bury_the_catalog_test() {
  // The reason the sanitizing runs as the spec loads rather than at lookup: the
  // dependency tier is merged *over* the catalog, so refusing the stale line
  // afterwards would answer [Unknown] with the catalog's declaration of the same
  // name sitting underneath it, unreachable.
  installed_dep_over_source(
    "build/eff_dep_over_catalog",
    "gleam_stdlib",
    "effects gleam/io.println : [Shipped]\n",
    "packages = [\n  { name = \"gleam_stdlib\", version = \"0.70.0\" },\n]\n",
    [
      #(QualifiedName("gleam/io", "println"), foreign_declared_everywhere()),
    ],
  )
  |> entry_of(QualifiedName("gleam/io", "println"))
  |> should.equal(
    Ok(#(Specific(set.from_list(["Stdout"])), types.Catalog("gleam_stdlib"))),
  )
}

pub fn a_dropped_dependency_effects_line_takes_its_bounds_with_it_test() {
  // Terms and bounds are merged in two independent passes, so dropping a term
  // without its bounds would pair the catalog's term with the dependency's
  // bounds — a budget answering to a variable the winning term never mentions.
  let kb =
    installed_dep_over_source(
      "build/eff_dep_bounds_atomic",
      "gleam_stdlib",
      "effects gleam/io.println(cb: [cb]) : [cb]\n",
      "packages = [\n  { name = \"gleam_stdlib\", version = \"0.70.0\" },\n]\n",
      [
        #(QualifiedName("gleam/io", "println"), foreign_declared_everywhere()),
      ],
    )
  kb
  |> entry_of(QualifiedName("gleam/io", "println"))
  |> should.equal(
    Ok(#(Specific(set.from_list(["Stdout"])), types.Catalog("gleam_stdlib"))),
  )
  effects.lookup_param_bounds(kb, QualifiedName("gleam/io", "println"))
  |> should.equal([])
}

pub fn a_declared_dependency_external_with_a_running_fallback_is_widened_test() {
  // Where the source is walked, a declaration is unioned with the fallback body
  // that runs beside it. A consumer never walks a dependency's bodies, so the
  // union has no second operand there: [Unknown] stands in for the body that
  // ran, and the declaration alone does not read as the whole story.
  installed_dep_over_source(
    "build/eff_dep_partial_fallback",
    "dep",
    "external effects dep/ffi.run : [Time]\n",
    "",
    [
      #(QualifiedName("dep/ffi", "run"), foreign_with_running_fallback()),
    ],
  )
  |> entry_of(QualifiedName("dep/ffi", "run"))
  |> should.equal(
    Ok(#(
      Specific(set.from_list(["Time", "Unknown"])),
      types.DependencySpec("dep"),
    )),
  )
}

pub fn a_dependency_returns_line_for_its_own_external_is_refused_test() {
  // The value channel, one package away. Nothing declares the operator an FFI
  // producer returns, so a shipped `returns` line for one describes a fallback
  // body the foreign implementation needn't match — refused whether or not the
  // call itself is declared.
  let kb =
    installed_dep_over_source(
      "build/eff_dep_returns",
      "dep",
      "external effects dep/ffi.make : []\nreturns dep/ffi.make : []\nreturns dep/ffi.plain : []\n",
      "",
      [
        #(QualifiedName("dep/ffi", "make"), foreign_declared_everywhere()),
      ],
    )
  effects.lookup_returned_operator(kb, QualifiedName("dep/ffi", "make"))
  |> result.is_ok
  |> should.be_false()
  // An ordinary dep producer's summary still answers.
  effects.lookup_returned_operator(kb, QualifiedName("dep/ffi", "plain"))
  |> result.is_ok
  |> should.be_true()
}

pub fn one_dep_specs_returns_line_cannot_bury_anothers_declaration_test() {
  // Two installed specs keying the same name: `alib` declares what its own
  // producer hands back, `zlib` carries a stray inferred `returns` line for it.
  // The packages are folded in whatever order the directory yields, so the rule
  // has to be the merge's, not the order's — declared outranks inferred across
  // specs as it does within one.
  let root = "build/eff_cross_package_stray_returns"
  write_fixture(root, [
    #(dep_spec_path("alib"), "external returns alib/mod.make : [Stdout]\n"),
    #(dep_spec_path("zlib"), "returns alib/mod.make : [Net]\n"),
  ])
  let kb =
    effects.load_knowledge_base(
      root <> "/packages",
      root <> "/missing_manifest.toml",
      dict.new(),
    )
  cleanup(root)
  let assert Ok(found) =
    effects.lookup_returned_operator(kb, QualifiedName("alib/mod", "make"))
  found.operator
  |> should.equal(
    effect_term.from_effect_set(
      Specific(
        set.from_list([
          "Stdout",
        ]),
      ),
    ),
  )
}

// Target-narrowed foreign lookups
//
// A Gleam fallback body runs only on the targets its own declaration leaves
// uncovered, and the names it calls are read there. Which half of a foreign
// callee's answer it reaches — the declaration, the callee's own fallback — is
// what `with_active_targets` narrows the base to.

// A base holding one foreign name: what the source scan recorded about it, the
// summary its fallback walked to, and the targets the body doing the calling
// runs on.
fn narrowed_to(
  name: QualifiedName,
  entry: types.ForeignFunction,
  fallback: List(String),
  active: List(String),
) -> effects.KnowledgeBase {
  effects.new_knowledge_base()
  |> effects.with_foreign_functions(dict.from_list([#(name, entry)]))
  |> effects.with_fallback_summaries(
    dict.from_list([
      #(
        name,
        #(effect_term.from_effect_set(Specific(set.from_list(fallback))), []),
      ),
    ]),
  )
  |> effects.with_active_targets(option.Some(set.from_list(active)))
}

// The declared external's own entry, compiled for both targets.
fn declared_for(targets: List(String)) -> types.ForeignFunction {
  types.ForeignFunction(
    runs_fallback_body: True,
    compiled_targets: types.every_target(),
    declared_targets: set.from_list(targets),
  )
}

fn charged(base: effects.KnowledgeBase, name: QualifiedName) -> EffectSet {
  effects.with_running_fallback(
    base,
    name,
    effect_term.from_effect_set(Specific(set.from_list(["Disk"]))),
  )
  |> effect_term.to_effect_set
}

pub fn a_callee_declared_elsewhere_charges_its_fallback_alone_test() {
  // The declaration covers javascript and the calling body runs on erlang, so
  // the calling body reaches this name's Gleam fallback and never its foreign
  // implementation. Charging the union attributed `[Disk]` — an effect of the
  // javascript implementation — to a body that only ever runs on erlang.
  let name = QualifiedName("app/ffi", "b")
  narrowed_to(name, declared_for(["javascript"]), ["Time"], ["erlang"])
  |> charged(name)
  |> should.equal(Specific(set.from_list(["Time"])))
}

pub fn a_callee_declared_here_charges_its_declaration_alone_test() {
  // The other direction: the declaration covers the target the calling body
  // runs on, so the foreign implementation is what that body reaches and the
  // callee's fallback runs where this body does not.
  let name = QualifiedName("app/ffi", "b")
  narrowed_to(name, declared_for(["erlang"]), ["Time"], ["erlang"])
  |> charged(name)
  |> should.equal(Specific(set.from_list(["Disk"])))
}

pub fn a_callee_reached_on_both_targets_charges_both_halves_test() {
  // A body running on both targets reaches the declaration on one and the
  // fallback on the other, which is the union the unnarrowed reading gives.
  let name = QualifiedName("app/ffi", "b")
  narrowed_to(name, declared_for(["javascript"]), ["Time"], [
    "erlang", "javascript",
  ])
  |> charged(name)
  |> should.equal(Specific(set.from_list(["Disk", "Time"])))
}

pub fn an_unreadable_declared_target_charges_both_halves_test() {
  // A declaration whose target argument is not a plain name states nothing this
  // can read, and "no target declared" is the same empty set. Narrowed on it,
  // every target reaches the fallback and the declaration is dropped -- making
  // the Gleam body the trusted implementation of foreign code whose declaration
  // graded merely failed to parse, which is the reading
  // `is_foreign_definition` refuses for the same reason.
  let name = QualifiedName("app/ffi", "b")
  narrowed_to(name, declared_for([]), ["Time"], ["erlang"])
  |> charged(name)
  |> should.equal(Specific(set.from_list(["Disk", "Time"])))
}

pub fn no_active_targets_charges_both_halves_test() {
  // Outside a fallback walk nothing is narrowed: an ordinary caller is compiled
  // for everything the package is, and pays whichever half each target has.
  let name = QualifiedName("app/ffi", "b")
  let base =
    narrowed_to(name, declared_for(["javascript"]), ["Time"], ["erlang"])
    |> effects.with_active_targets(option.None)
  charged(base, name) |> should.equal(Specific(set.from_list(["Disk", "Time"])))
}
