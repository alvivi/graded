import generators
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/order
import gleam/set
import gleam/string
import gleeunit/should
import graded/internal/effect_term
import graded/internal/effects
import graded/internal/types.{
  type EffectSet, ConstructorRef, FunctionRef, OtherExpression, Polymorphic,
  QualifiedName, Specific, TypeFieldEffect, Wildcard,
}
import qcheck
import simplifile

// Knowledge-base lookups
//
// Resolving qualified names against the default knowledge base: catalogued
// effectful functions, pure stdlib modules, and the Unknown fallback.

fn knowledge_base() -> effects.KnowledgeBase {
  effects.empty_knowledge_base()
}

pub fn known_effectful_test() {
  effects.lookup_effects(knowledge_base(), QualifiedName("gleam/io", "println"))
  |> effect_term.to_effect_set
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn known_pure_module_test() {
  effects.lookup_effects(knowledge_base(), QualifiedName("gleam/list", "map"))
  |> effect_term.to_effect_set
  |> should.equal(Specific(set.new()))
}

pub fn unknown_function_test() {
  effects.lookup_effects(
    knowledge_base(),
    QualifiedName("some/unknown", "thing"),
  )
  |> effect_term.to_effect_set
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

pub fn lookup_known_variant_test() {
  effects.lookup(knowledge_base(), QualifiedName("gleam/io", "debug"))
  |> should.equal(
    effects.Known(
      effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
    ),
  )
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
// Effect sets carrying variables: variable detection and how union merges
// labels and variables across operands.

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
  let enriched = effects.with_inferred(kb, inferred)
  // Existing KB entry should take priority (Stdout), not be overwritten to []
  effects.lookup_effects(enriched, QualifiedName("gleam/io", "println"))
  |> effect_term.to_effect_set
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn returned_operators_round_trip_test() {
  let kb = knowledge_base()
  let operator = types.TAbs("cb", types.TVar("cb"))
  let enriched =
    effects.with_inferred_returned_operators(
      kb,
      dict.from_list([#(QualifiedName("mylib/foo", "pick"), operator)]),
    )
  effects.lookup_returned_operator(enriched, QualifiedName("mylib/foo", "pick"))
  |> should.equal(Ok(operator))
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
  let enriched = effects.with_inferred(kb, inferred)
  effects.lookup_effects(enriched, QualifiedName("mylib/foo", "bar"))
  |> effect_term.to_effect_set
  |> should.equal(Specific(set.from_list(["Http"])))
}

// Catalog version selection
//
// pick_best_version returns an eligible entry (at or below the installed
// version) whenever one exists.

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
    Ok(label) -> {
      let assert Ok(picked) = list.find(versions, fn(v) { v.1 == label })
      let has_eligible =
        list.any(versions, fn(v) { effects.semver_lte(v.0, installed) })
      case has_eligible {
        True -> effects.semver_lte(picked.0, installed) |> should.be_true()
        False -> Nil
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
    effects.with_inferred_type_fields(knowledge_base(), [
      #(
        #("app/a", "Validator", "f"),
        TypeFieldEffect(
          effect_term.from_effect_set(Specific(set.from_list(["Http"]))),
          [],
          None,
        ),
      ),
      #(
        #("app/b", "Validator", "f"),
        TypeFieldEffect(
          effect_term.from_effect_set(Specific(set.from_list(["Stdout"]))),
          [],
          None,
        ),
      ),
    ])
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

  let kb = effects.load_knowledge_base(packages, "missing_manifest.toml")
  let assert Ok(field) =
    effects.lookup_type_field(kb, "dep/repo", "Repo", "find")
  effect_term.to_effect_set(field.effects)
  |> should.equal(Specific(set.from_list(["Storage"])))

  let _ = simplifile.delete("build/eff_dep_typefield")
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
