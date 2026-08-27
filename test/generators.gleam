import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import graded/internal/effect_term
import graded/internal/types.{
  type EffectSet, type EffectTerm, AnnotationLine, AssumeAnnotation, AssumeLine,
  BlankLine, Check, CommentLine, EffectAnnotation, Effects, FieldAnnotation,
  FieldAssumeLine, FunctionAssume, GradedFile, ModuleAssume, ParamBound,
  Polymorphic, RetainedAssumeLine, Specific, TAbs, TApp, TLabels, TTop, TUnion,
  TVar, UnknownClause, Wildcard,
}
import qcheck

// Shared pools
//
// Fixed label and variable pools drawn on by every generator, and the
// uniform-choice helper that samples them, so generated data overlaps enough
// for properties to hit interesting collisions.

const effect_labels = ["Http", "Dom", "Stdout", "Db", "FileSystem", "Time"]

const effect_var_names = ["e", "e1", "e2", "a", "cb"]

fn one_of(items: List(String)) -> qcheck.Generator(String) {
  case items {
    [] -> qcheck.return("")
    [first, ..rest] ->
      qcheck.from_generators(
        qcheck.return(first),
        list.map(rest, qcheck.return),
      )
  }
}

// Effect-term generators
//
// Depth-bounded `EffectTerm`s — arbitrary, first-order, and serializable
// shapes — plus variable substitutions, feeding the normalization,
// substitution, and serialization property suites.

// A generator for arbitrary `EffectTerm`s, depth-bounded so reduction stays
// cheap. Produces every constructor, including stuck applications and
// operators, so the property suite exercises the interesting reduction paths.
pub fn effect_term_gen() -> qcheck.Generator(EffectTerm) {
  use depth <- qcheck.bind(qcheck.bounded_int(0, 3))
  effect_term_sized(depth)
}

fn effect_term_sized(depth: Int) -> qcheck.Generator(EffectTerm) {
  case depth <= 0 {
    True -> effect_term_leaf_gen()
    False -> {
      let sub = effect_term_sized(depth - 1)
      qcheck.from_weighted_generators(#(3, effect_term_leaf_gen()), [
        #(3, effect_union_gen(sub)),
        #(2, qcheck.map2(sub, sub, fn(o, a) { TApp(o, a) })),
        #(
          2,
          qcheck.map2(one_of(effect_var_names), sub, fn(p, b) { TAbs(p, b) }),
        ),
      ])
    }
  }
}

fn effect_term_leaf_gen() -> qcheck.Generator(EffectTerm) {
  let labels_gen =
    qcheck.map(qcheck.list_from(one_of(effect_labels)), fn(labels) {
      TLabels(set.from_list(labels))
    })
  qcheck.from_weighted_generators(#(3, labels_gen), [
    #(1, qcheck.return(TTop)),
    #(2, qcheck.map(one_of(effect_var_names), TVar)),
  ])
}

fn effect_union_gen(
  sub: qcheck.Generator(EffectTerm),
) -> qcheck.Generator(EffectTerm) {
  use n <- qcheck.bind(qcheck.bounded_int(0, 3))
  qcheck.map(qcheck.fixed_length_list_from(sub, n), TUnion)
}

// A first-order effect *term* — the lift of an arbitrary `EffectSet`. Used
// where an annotation field (now an `EffectTerm`) must still round-trip
// through the first-order serializer.
pub fn first_order_term_gen() -> qcheck.Generator(EffectTerm) {
  qcheck.map(effect_set_gen(), effect_term.from_effect_set)
}

// A generator for *serializable* effect terms: labels, variables, operator
// applications `f(args)`, and unions of those. Excludes operators (`TAbs`)
// and the wildcard, which don't appear as inferred result effects — so
// `parse ∘ format` round-trips (P-SER-2).
pub fn serializable_effect_term_gen() -> qcheck.Generator(EffectTerm) {
  use depth <- qcheck.bind(qcheck.bounded_int(0, 2))
  serializable_sized(depth)
}

fn serializable_atom_gen() -> qcheck.Generator(EffectTerm) {
  qcheck.from_weighted_generators(
    #(
      3,
      qcheck.map(one_of(effect_labels), fn(l) { TLabels(set.from_list([l])) }),
    ),
    [#(2, qcheck.map(one_of(effect_var_names), TVar))],
  )
}

fn serializable_sized(depth: Int) -> qcheck.Generator(EffectTerm) {
  case depth <= 0 {
    True -> serializable_atom_gen()
    False -> {
      let arg_gen = serializable_atom_gen()
      // A *curried* operator application `((f a0) a1 ...)` over one to three
      // bracketed arguments — exercises the order-significant multi-argument
      // serialization, not just the single-argument case.
      let app_gen = {
        use n <- qcheck.bind(qcheck.bounded_int(1, 3))
        qcheck.map2(
          one_of(effect_var_names),
          qcheck.fixed_length_list_from(arg_gen, n),
          fn(name, args) {
            list.fold(args, TVar(name), fn(acc, arg) { TApp(acc, arg) })
          },
        )
      }
      let union_gen = {
        use n <- qcheck.bind(qcheck.bounded_int(1, 3))
        qcheck.map(
          qcheck.fixed_length_list_from(serializable_atom_gen(), n),
          TUnion,
        )
      }
      qcheck.from_weighted_generators(#(3, serializable_atom_gen()), [
        #(2, app_gen),
        #(2, union_gen),
      ])
    }
  }
}

// A generator for variable→term substitutions over the standard variable
// pool, so substitution domains actually overlap term variables.
pub fn effect_binding_gen() -> qcheck.Generator(dict.Dict(String, EffectTerm)) {
  let pair_gen =
    qcheck.map2(one_of(effect_var_names), effect_term_gen(), fn(name, term) {
      #(name, term)
    })
  qcheck.map(qcheck.list_from(pair_gen), dict.from_list)
}

// Effect-set and spec-file generators
//
// Ground `EffectSet`s and the `.graded` structures built from them —
// annotations, type fields, externals, and whole spec files — for the
// parse/format round-trip properties.

pub fn effect_set_gen() -> qcheck.Generator(EffectSet) {
  let label_gen =
    qcheck.from_generators(qcheck.return("Http"), [
      qcheck.return("Dom"),
      qcheck.return("Stdout"),
      qcheck.return("Db"),
      qcheck.return("FileSystem"),
      qcheck.return("Time"),
    ])
  let specific_gen =
    qcheck.map(qcheck.list_from(label_gen), fn(labels) {
      Specific(set.from_list(labels))
    })
  let variable_gen =
    qcheck.from_generators(qcheck.return("e"), [
      qcheck.return("e1"),
      qcheck.return("e2"),
      qcheck.return("a"),
    ])
  let polymorphic_gen =
    qcheck.map2(
      qcheck.list_from(label_gen),
      qcheck.map2(variable_gen, qcheck.list_from(variable_gen), fn(v, vs) {
        [v, ..vs]
      }),
      fn(labels, variables) {
        Polymorphic(set.from_list(labels), set.from_list(variables))
      },
    )
  qcheck.from_weighted_generators(#(1, qcheck.return(Wildcard)), [
    #(4, specific_gen),
    #(2, polymorphic_gen),
  ])
}

pub fn function_name_gen() -> qcheck.Generator(String) {
  qcheck.from_generators(qcheck.return("foo"), [
    qcheck.return("bar"),
    qcheck.return("baz"),
    qcheck.return("run"),
    qcheck.return("handle"),
    qcheck.return("process"),
  ])
}

// The operator a `where returns` clause carries: a bare term, or an
// abstraction over one binder.
pub fn operator_gen() -> qcheck.Generator(EffectTerm) {
  qcheck.from_generators(first_order_term_gen(), [
    qcheck.map(first_order_term_gen(), fn(body) { TAbs("cb", body) }),
  ])
}

fn optional_operator_gen() -> qcheck.Generator(option.Option(EffectTerm)) {
  qcheck.from_generators(qcheck.return(None), [
    qcheck.map(operator_gen(), Some),
  ])
}

// A bound list of zero to two bounds over the shared parameter-name pool —
// what `effects`/`check` lines and bounded `assume` lines alike carry.
pub fn params_gen() -> qcheck.Generator(List(types.ParamBound)) {
  let param_name_gen =
    qcheck.from_generators(qcheck.return("f"), [
      qcheck.return("g"),
      qcheck.return("h"),
      qcheck.return("callback"),
      qcheck.return("handler"),
    ])
  let param_bound_gen =
    qcheck.map2(param_name_gen, first_order_term_gen(), fn(name, effects) {
      ParamBound(name:, effects:)
    })
  qcheck.from_generators(qcheck.return([]), [
    qcheck.map(param_bound_gen, fn(bound) { [bound] }),
    qcheck.map2(param_bound_gen, param_bound_gen, fn(first, second) {
      [first, second]
    }),
  ])
}

pub fn annotation_gen() -> qcheck.Generator(types.EffectAnnotation) {
  let kind_gen =
    qcheck.from_generators(qcheck.return(Effects), [qcheck.return(Check)])
  use kind <- qcheck.bind(kind_gen)
  use function <- qcheck.bind(function_name_gen())
  use params <- qcheck.bind(params_gen())
  use effects <- qcheck.bind(first_order_term_gen())
  use returns <- qcheck.map(optional_operator_gen())
  EffectAnnotation(kind:, function:, params:, effects:, returns:)
}

pub fn type_field_gen() -> qcheck.Generator(types.FieldAnnotation) {
  let type_name_gen =
    qcheck.from_generators(qcheck.return("Handler"), [
      qcheck.return("Request"),
      qcheck.return("Config"),
    ])
  let field_name_gen =
    qcheck.from_generators(qcheck.return("on_click"), [
      qcheck.return("send"),
      qcheck.return("validate"),
    ])
  qcheck.map2(
    qcheck.map2(type_name_gen, field_name_gen, fn(t, f) { #(t, f) }),
    first_order_term_gen(),
    fn(tf, effects) {
      let #(type_name, field) = tf
      FieldAnnotation(module: None, type_name:, field:, effects:)
    },
  )
}

pub fn external_gen() -> qcheck.Generator(types.AssumeAnnotation) {
  let module_name_gen =
    qcheck.from_generators(qcheck.return("gleam/io"), [
      qcheck.return("gleam/list"),
      qcheck.return("gleam/httpc"),
      qcheck.return("simplifile"),
    ])
  let target_gen =
    qcheck.from_generators(qcheck.return(ModuleAssume), [
      qcheck.map(function_name_gen(), FunctionAssume),
    ])
  // Never both absent: a line carrying neither clause claims nothing and is not
  // a line the parser reads back.
  let clauses_gen =
    qcheck.from_generators(
      qcheck.map(effect_set_gen(), fn(effects) { #(Some(effects), None) }),
      [
        qcheck.map2(effect_set_gen(), operator_gen(), fn(effects, operator) {
          #(Some(effects), Some(operator))
        }),
        qcheck.map(operator_gen(), fn(operator) { #(None, Some(operator)) }),
      ],
    )
  use module <- qcheck.bind(module_name_gen)
  use target <- qcheck.bind(target_gen)
  // A bound list rides a function path alone — on a module path it is a parse
  // error, so the generator never pairs the two.
  use params <- qcheck.bind(case target {
    ModuleAssume -> qcheck.return([])
    FunctionAssume(_) -> params_gen()
  })
  use clauses <- qcheck.map(clauses_gen)
  let #(effects, returns) = clauses
  AssumeAnnotation(module:, target:, params:, effects:, returns:)
}

// One clause this version does not read. The keys cover the dotted and numeric
// shapes a later grammar may mint; the payloads cover interior whitespace,
// which is preserved byte-for-byte, and a top-level `,` is kept out of them
// since the grammar reads one as a clause separator.
fn unknown_clause_gen() -> qcheck.Generator(types.UnknownClause) {
  let key_gen =
    qcheck.from_generators(qcheck.return("future"), [
      qcheck.return("returns.0"),
      qcheck.return("returns.Ok.0"),
      qcheck.return("raises"),
    ])
  let payload_gen =
    qcheck.from_generators(qcheck.return("[Stdout]"), [
      qcheck.return("fn(cb) -> [cb]"),
      qcheck.return("[A, B]"),
      qcheck.return("fn(a,   b) ->  [X]"),
    ])
  qcheck.map2(key_gen, payload_gen, fn(key, payload) {
    UnknownClause(key:, payload:)
  })
}

fn unknown_clauses_gen() -> qcheck.Generator(List(types.UnknownClause)) {
  qcheck.from_weighted_generators(#(3, qcheck.return([])), [
    #(1, qcheck.map(unknown_clause_gen(), fn(clause) { [clause] })),
    #(
      1,
      qcheck.map2(unknown_clause_gen(), unknown_clause_gen(), fn(first, second) {
        [first, second]
      }),
    ),
  ])
}

// An `assume` line retained for its unknown clauses alone, over all three path
// shapes it accepts.
fn retained_assume_gen() -> qcheck.Generator(types.GradedLine) {
  let path_gen =
    qcheck.from_generators(qcheck.return("gleam/io"), [
      qcheck.return("gleam/io.println"),
      qcheck.return("Handler.on_click"),
      qcheck.return("myapp/dom.Handler.on_click"),
    ])
  qcheck.map2(path_gen, unknown_clause_gen(), fn(path, clause) {
    RetainedAssumeLine(path:, unknown_clauses: [clause])
  })
}

pub fn graded_file_gen() -> qcheck.Generator(types.GradedFile) {
  let comment_gen =
    qcheck.from_generators(qcheck.return("// TODO"), [
      qcheck.return("// Effect annotations"),
      qcheck.return("// Auto-generated"),
    ])
  let line_gen =
    qcheck.from_weighted_generators(
      #(3, qcheck.map2(annotation_gen(), unknown_clauses_gen(), AnnotationLine)),
      [
        #(
          1,
          qcheck.map2(type_field_gen(), unknown_clauses_gen(), FieldAssumeLine),
        ),
        #(1, qcheck.map2(external_gen(), unknown_clauses_gen(), AssumeLine)),
        #(1, retained_assume_gen()),
        #(1, qcheck.map(comment_gen, CommentLine)),
        #(1, qcheck.return(BlankLine)),
      ],
    )
  qcheck.map2(line_gen, qcheck.list_from(line_gen), fn(first, rest) {
    GradedFile(lines: [first, ..rest])
  })
}

pub fn inferred_list_gen() -> qcheck.Generator(List(types.EffectAnnotation)) {
  let effects_ann_gen =
    qcheck.map2(
      function_name_gen(),
      first_order_term_gen(),
      fn(function, effects) {
        EffectAnnotation(
          kind: Effects,
          function:,
          params: [],
          effects:,
          returns: None,
        )
      },
    )
  qcheck.map(
    qcheck.map2(
      effects_ann_gen,
      qcheck.list_from(effects_ann_gen),
      fn(first, rest) { [first, ..rest] },
    ),
    fn(anns) {
      anns
      |> list.map(fn(a) { #(a.function, a) })
      |> dict.from_list()
      |> dict.values()
    },
  )
}

// Provenance programs
//
// Paired Gleam source programs whose helper return value is traceable in one
// form and opaque in the other, feeding the provenance regression guard rail.

// A computed-receiver program in two forms differing only in whether the helper's
// return value is traceable: `traced` uses a direct tail shape (passthrough,
// getter, or rebuild); `untraced` wraps the same body in a redundant `case`, so
// its return provenance is `Opaque` while its runtime effect is unchanged. Feeds
// the provenance regression guard rail, which compares the two.
pub type ProvenanceProgram {
  ProvenanceProgram(traced: String, untraced: String, label: String)
}

pub type ProvenanceShape {
  ProvPassthrough
  ProvGetter
  ProvRebuild
  ProvShorthand
  ProvLabeled
  ProvRecursive
}

pub fn provenance_program_gen() -> qcheck.Generator(ProvenanceProgram) {
  use shape <- qcheck.bind(
    qcheck.from_generators(qcheck.return(ProvPassthrough), [
      qcheck.return(ProvGetter),
      qcheck.return(ProvRebuild),
      qcheck.return(ProvShorthand),
      qcheck.return(ProvLabeled),
      qcheck.return(ProvRecursive),
    ]),
  )
  use label <- qcheck.map(one_of(effect_labels))
  build_provenance_program(shape, label)
}

fn build_provenance_program(
  shape: ProvenanceShape,
  label: String,
) -> ProvenanceProgram {
  let options_type =
    "pub type Options {\n  Options(resolver: fn() -> Nil)\n}\n\n"
  let inner = "pub fn inner(o: Options) -> Nil {\n  o.resolver()\n}\n\n"
  // `call_prefix` is the Gleam label the caller applies at the call site
  // (`with:`); `ProvLabeled` gives the helper param a label distinct from its
  // in-body name so the call binds out of textual order, exercising the
  // signature-directed argument reorder.
  let #(extra_type, params, body, call_arg, call_prefix) = case shape {
    ProvPassthrough -> #(
      "",
      "o: Options",
      "o",
      "Options(resolver: resolver)",
      "",
    )
    ProvGetter -> #(
      "pub type Config {\n  Config(options: Options)\n}\n\n",
      "c: Config",
      "c.options",
      "Config(options: Options(resolver: resolver))",
      "",
    )
    ProvRebuild -> #(
      "",
      "o: Options",
      "Options(resolver: o.resolver)",
      "Options(resolver: resolver)",
      "",
    )
    // A smart constructor built with field shorthand (`Options(resolver:)`, sugar
    // for `resolver: resolver`): the shorthand field resolves to the `resolver`
    // parameter, so the `Build` keeps it. The relay-wrapped `untraced` form's tail
    // is a `relay(..)` call, so it stays `Opaque`.
    ProvShorthand -> #(
      "",
      "resolver: fn() -> Nil",
      "Options(resolver:)",
      "resolver",
      "",
    )
    ProvLabeled -> #(
      "",
      "with o: Options",
      "o",
      "Options(resolver: resolver)",
      "with: ",
    )
    // A tail-recursive passthrough: the `case` join's recursive branch calls the
    // helper back with `o` at the same position, so the fixpoint converges to a
    // `Passthrough`. The relay-wrapped `untraced` form isn't self-recursive (its
    // tail is a `relay(..)` call), so it stays `Opaque`.
    ProvRecursive -> #(
      "",
      "o: Options",
      "case True {\n    True -> o\n    False -> helper(o)\n  }",
      "Options(resolver: resolver)",
      "",
    )
  }
  let helper = fn(helper_body: String) {
    "fn helper(" <> params <> ") -> Options {\n  " <> helper_body <> "\n}\n\n"
  }
  let caller =
    "pub fn caller(resolver: fn() -> Nil) -> Nil {\n  inner(helper("
    <> call_prefix
    <> call_arg
    <> "))\n}\n"
  // A helper-call composition (`relay(body)`) stays `Opaque` — Phase 1/2 traces a
  // direct tail shape and a `case` join, but not a return that is itself a call —
  // so it is a faithful provenance-off proxy while leaving the runtime effect
  // unchanged (`relay` is the identity).
  let relay = "fn relay(v: Options) -> Options {\n  v\n}\n\n"
  let common = options_type <> extra_type <> inner
  ProvenanceProgram(
    traced: common <> helper(body) <> caller,
    untraced: common <> relay <> helper("relay(" <> body <> ")") <> caller,
    label:,
  )
}
