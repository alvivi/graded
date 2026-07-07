import gleam/dict
import gleam/list
import gleam/option.{None}
import gleam/set
import graded/internal/effect_term
import graded/internal/types.{
  type EffectSet, type EffectTerm, AnnotationLine, BlankLine, Check, CommentLine,
  EffectAnnotation, Effects, ExternalAnnotation, ExternalLine, FunctionExternal,
  GradedFile, ModuleExternal, ParamBound, Polymorphic, Specific, TAbs, TApp,
  TLabels, TTop, TUnion, TVar, TypeFieldAnnotation, TypeFieldLine, Wildcard,
}
import qcheck

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

pub fn annotation_gen() -> qcheck.Generator(types.EffectAnnotation) {
  let kind_gen =
    qcheck.from_generators(qcheck.return(Effects), [qcheck.return(Check)])
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
  let no_params =
    qcheck.map2(
      qcheck.map2(kind_gen, function_name_gen(), fn(k, f) { #(k, f) }),
      first_order_term_gen(),
      fn(kf, effects) {
        let #(kind, function) = kf
        EffectAnnotation(kind:, function:, params: [], effects:)
      },
    )
  let with_param =
    qcheck.map2(
      qcheck.map2(kind_gen, function_name_gen(), fn(k, f) { #(k, f) }),
      qcheck.map2(param_bound_gen, first_order_term_gen(), fn(p, e) { #(p, e) }),
      fn(kf, pe) {
        let #(kind, function) = kf
        let #(param, effects) = pe
        EffectAnnotation(kind:, function:, params: [param], effects:)
      },
    )
  qcheck.from_generators(no_params, [with_param])
}

pub fn type_field_gen() -> qcheck.Generator(types.TypeFieldAnnotation) {
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
      TypeFieldAnnotation(module: None, type_name:, field:, effects:)
    },
  )
}

pub fn external_gen() -> qcheck.Generator(types.ExternalAnnotation) {
  let module_name_gen =
    qcheck.from_generators(qcheck.return("gleam/io"), [
      qcheck.return("gleam/list"),
      qcheck.return("gleam/httpc"),
      qcheck.return("simplifile"),
    ])
  let module_ext =
    qcheck.map2(module_name_gen, effect_set_gen(), fn(module, effects) {
      ExternalAnnotation(module:, target: ModuleExternal, effects:)
    })
  let function_ext =
    qcheck.map2(
      qcheck.map2(module_name_gen, function_name_gen(), fn(m, f) { #(m, f) }),
      effect_set_gen(),
      fn(mf, effects) {
        let #(module, name) = mf
        ExternalAnnotation(module:, target: FunctionExternal(name), effects:)
      },
    )
  qcheck.from_generators(module_ext, [function_ext])
}

pub fn graded_file_gen() -> qcheck.Generator(types.GradedFile) {
  let comment_gen =
    qcheck.from_generators(qcheck.return("// TODO"), [
      qcheck.return("// Effect annotations"),
      qcheck.return("// Auto-generated"),
    ])
  let line_gen =
    qcheck.from_weighted_generators(
      #(3, qcheck.map(annotation_gen(), AnnotationLine)),
      [
        #(1, qcheck.map(type_field_gen(), TypeFieldLine)),
        #(1, qcheck.map(external_gen(), ExternalLine)),
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
        EffectAnnotation(kind: Effects, function:, params: [], effects:)
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
}

pub fn provenance_program_gen() -> qcheck.Generator(ProvenanceProgram) {
  use shape <- qcheck.bind(
    qcheck.from_generators(qcheck.return(ProvPassthrough), [
      qcheck.return(ProvGetter),
      qcheck.return(ProvRebuild),
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
  let #(extra_type, params, body, call_arg) = case shape {
    ProvPassthrough -> #("", "o: Options", "o", "Options(resolver: resolver)")
    ProvGetter -> #(
      "pub type Config {\n  Config(options: Options)\n}\n\n",
      "c: Config",
      "c.options",
      "Config(options: Options(resolver: resolver))",
    )
    ProvRebuild -> #(
      "",
      "o: Options",
      "Options(resolver: o.resolver)",
      "Options(resolver: resolver)",
    )
  }
  let helper = fn(helper_body: String) {
    "fn helper(" <> params <> ") -> Options {\n  " <> helper_body <> "\n}\n\n"
  }
  let caller =
    "pub fn caller(resolver: fn() -> Nil) -> Nil {\n  inner(helper("
    <> call_arg
    <> "))\n}\n"
  let common = options_type <> extra_type <> inner
  ProvenanceProgram(
    traced: common <> helper(body) <> caller,
    untraced: common
      <> helper("case True {\n    _ -> " <> body <> "\n  }")
      <> caller,
    label:,
  )
}
