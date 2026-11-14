// What a value carries and what a callback costs, read over constructed data:
// a resolver that answers from tables stands in for the checker, so every rule
// is exercised without the grammar or a call site.

import girard
import glance
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleeunit/should
import graded/internal/effect_term
import graded/internal/latent.{Carries, FunctionFree}
import graded/internal/typedefs
import graded/internal/types.{
  type ArgumentValue, CallbackKind, NonCallbackKind, ParamBound, QualifiedName,
  TAbs, TLabels, TUnion, TVar, UnknownKind,
}

// The stand-in resolver

fn span(n: Int) -> glance.Span {
  glance.Span(n, n + 1)
}

fn named(module: String, name: String, arguments: List(girard.Type)) {
  girard.Named(module:, name:, arguments:)
}

fn nil_type() -> girard.Type {
  named("gleam", "Nil", [])
}

fn int_type() -> girard.Type {
  named("gleam", "Int", [])
}

fn thunk() -> girard.Type {
  girard.Fn([], nil_type())
}

fn labels(names: List(String)) -> types.EffectTerm {
  TLabels(set.from_list(names))
}

fn stdout() -> latent.Latent {
  Carries(labels(["Stdout"]))
}

fn loud() -> ArgumentValue {
  types.FunctionRef(QualifiedName("app", "loud"))
}

fn quiet() -> ArgumentValue {
  types.FunctionRef(QualifiedName("app", "quiet"))
}

fn outer() -> ArgumentValue {
  types.FunctionRef(QualifiedName("app", "outer"))
}

type Tables {
  Tables(
    types: dict.Dict(glance.Span, girard.Type),
    lifts: List(#(ArgumentValue, types.EffectTerm)),
    groundings: List(#(ArgumentValue, latent.Grounding)),
    tails: List(#(ArgumentValue, types.Component)),
    contracts: dict.Dict(types.QualifiedName, latent.CalleeContract),
    constants: dict.Dict(types.QualifiedName, latent.Latent),
    containers: typedefs.Containers,
    type_registry: typedefs.TypeRegistry,
  )
}

fn tables() -> Tables {
  Tables(
    types: dict.new(),
    lifts: [
      #(loud(), labels(["Stdout"])),
      #(quiet(), effect_term.pure()),
      #(outer(), effect_term.pure()),
    ],
    groundings: [],
    tails: [],
    contracts: dict.new(),
    constants: dict.new(),
    containers: set.new(),
    type_registry: typedefs.empty(),
  )
}

fn typed(tables: Tables, at: glance.Span, type_: girard.Type) -> Tables {
  Tables(..tables, types: dict.insert(tables.types, at, type_))
}

fn resolver(tables: Tables) -> latent.Resolver(Nil) {
  latent.Resolver(
    types_at: fn(at) { [dict.get(tables.types, at) |> option.from_result] },
    shapes: typedefs.shapes(tables.type_registry, tables.containers),
    shape_memo: fn(_memo) { dict.new() },
    with_shape_memo: fn(memo, _shapes) { memo },
    lift: fn(value, _arity, memo) {
      #(lookup(tables.lifts, value) |> option.to_result(Nil), memo)
    },
    lift_operator: fn(value, _positions, memo) {
      #(lookup(tables.lifts, value) |> option.to_result(Nil), memo)
    },
    ground: fn(value) {
      lookup(tables.groundings, value) |> option.unwrap(latent.Ungrounded)
    },
    closure_tail: fn(value) { lookup(tables.tails, value) },
    contract: fn(callee, memo) {
      #(dict.get(tables.contracts, callee) |> option.from_result, memo)
    },
    match: fn(_callee, name, args) {
      list.find(args, fn(arg) { arg.label == Some(name) }) |> option.from_result
    },
    constant: fn(name) {
      dict.get(tables.constants, name) |> option.from_result
    },
  )
}

fn lookup(pairs: List(#(ArgumentValue, a)), value: ArgumentValue) -> Option(a) {
  list.find(pairs, fn(pair) { pair.0 == value })
  |> option.from_result
  |> option.map(fn(pair) { pair.1 })
}

fn latent_of(
  tables: Tables,
  value: ArgumentValue,
  at: glance.Span,
) -> latent.Latent {
  latent.argument_latent(value, at, dict.new(), resolver(tables), Nil).0
}

fn closure(params: List(String), marker: Int) -> ArgumentValue {
  // The body only tells two closures apart; the stand-in reads nothing of it.
  types.Closure(params:, captures: [], body: [
    glance.Expression(glance.Int(span(marker), "0")),
  ])
}

fn argument(label: String, value: ArgumentValue, at: glance.Span) {
  types.CallArgument(position: 0, label: Some(label), value:, span: at)
}

fn parameter(name: String, variable: String, kind: types.BoundKind) {
  latent.ContractParameter(
    bound: ParamBound(name, TVar(variable)),
    kind:,
    operator_positions: None,
  )
}

// The tiers, in precedence order

pub fn a_function_free_shape_carries_nothing_test() {
  tables()
  |> typed(span(1), int_type())
  |> latent_of(types.OtherExpression, span(1))
  |> should.equal(FunctionFree)
}

pub fn a_traced_reference_carries_its_cost_test() {
  tables()
  |> typed(span(1), thunk())
  |> latent_of(loud(), span(1))
  |> should.equal(stdout())
}

pub fn a_closure_carries_what_calling_it_does_test() {
  let calls_its_parameter = closure(["f"], 10)
  let tables =
    Tables(..tables(), lifts: [
      #(calls_its_parameter, TAbs("f", TVar("f"))),
      ..tables().lifts
    ])
    |> typed(span(1), girard.Fn([thunk()], nil_type()))
  // Escaping to code that may call it, the parameter it calls receives what
  // nothing describes.
  latent_of(tables, calls_its_parameter, span(1))
  |> should.equal(latent.unknown())
}

pub fn a_composite_carries_every_component_test() {
  let tables =
    tables()
    |> typed(span(2), thunk())
    |> typed(span(3), thunk())
    |> typed(span(4), int_type())
  latent_of(
    tables,
    types.Composite([
      types.Component(span(2), loud()),
      types.Component(span(3), quiet()),
      types.Component(span(4), types.OtherExpression),
    ]),
    span(1),
  )
  |> should.equal(Carries(labels(["Stdout"])))
  // One component nothing bounds leaves the whole partly unknown.
  latent_of(
    tables,
    types.Composite([
      types.Component(span(2), loud()),
      types.Component(span(5), types.OtherExpression),
    ]),
    span(1),
  )
  |> should.equal(Carries(labels(["Stdout", "Unknown"])))
}

pub fn a_construction_is_bounded_only_when_whole_test() {
  let tables = tables() |> typed(span(2), thunk())
  let components = [types.Component(span(2), loud())]
  latent_of(
    tables,
    types.Constructed(dict.new(), components, types.WholeValue),
    span(1),
  )
  |> should.equal(stdout())
  latent_of(
    tables,
    types.Constructed(dict.new(), components, types.PartialValue),
    span(1),
  )
  |> should.equal(latent.unknown())
}

pub fn a_declared_result_carries_what_its_line_says_test() {
  let fresh = QualifiedName("app/ffi", "fresh")
  let declaring = fn(carries) {
    Tables(
      ..tables(),
      contracts: dict.from_list([
        #(
          fresh,
          latent.CalleeContract(
            parameters: [],
            contract: types.LatentContract(..types.no_contract, carries:),
            reviewed: False,
          ),
        ),
      ]),
    )
  }
  let call = types.CallResult(fresh, [])
  // An external type and `Dynamic` prove nothing; the declaration does.
  [named("app/ffi", "Handle", []), named("gleam/dynamic", "Dynamic", [])]
  |> list.flat_map(fn(type_) {
    [
      declaring(Some(labels(["Stdout"])))
        |> typed(span(1), type_)
        |> latent_of(call, span(1)),
      declaring(Some(effect_term.pure()))
        |> typed(span(1), type_)
        |> latent_of(call, span(1)),
      declaring(None) |> typed(span(1), type_) |> latent_of(call, span(1)),
    ]
  })
  |> should.equal([
    stdout(),
    Carries(effect_term.pure()),
    latent.unknown(),
    stdout(),
    Carries(effect_term.pure()),
    latent.unknown(),
  ])
}

pub fn a_traced_value_carries_what_it_was_traced_to_test() {
  let call = types.CallResult(QualifiedName("app", "make"), [])
  let tables =
    Tables(..tables(), groundings: [
      #(
        call,
        latent.GroundedValue(
          types.Composite([types.Component(span(2), loud())]),
        ),
      ),
    ])
    |> typed(span(2), thunk())
  latent_of(tables, call, span(1)) |> should.equal(stdout())
}

pub fn a_described_constant_carries_what_the_audit_records_test() {
  let int_decoder =
    types.FunctionRef(QualifiedName("gleam/dynamic/decode", "int"))
  Tables(
    ..tables(),
    constants: dict.from_list([
      #(
        QualifiedName("gleam/dynamic/decode", "int"),
        Carries(effect_term.pure()),
      ),
    ]),
  )
  |> latent_of(int_decoder, span(1))
  |> should.equal(Carries(effect_term.pure()))
}

pub fn container_arguments_locate_positions_and_prove_nothing_test() {
  let assert Ok(dict_module) = glance.module("pub type Dict(key, value)")
  let tables =
    Tables(
      ..tables(),
      containers: set.from_list([#("gleam/dict", "Dict")]),
      type_registry: typedefs.from_module(
        "gleam/dict",
        dict_module,
        set.from_list(["erlang"]),
      ),
    )
  let parameter = types.LocalRef("handlers")
  tables
  |> typed(span(1), named("gleam/dict", "Dict", [int_type(), thunk()]))
  |> latent_of(parameter, span(1))
  |> should.equal(latent.unknown())
  tables
  |> typed(span(1), named("gleam/dict", "Dict", [int_type(), int_type()]))
  |> latent_of(parameter, span(1))
  |> should.equal(FunctionFree)
}

// One callback-resolution path

pub fn a_choice_resolves_every_option_before_joining_test() {
  let relayed = closure(["f"], 10)
  let ignoring = closure(["_"], 11)
  let returned = types.ReturnedOperator(QualifiedName("app", "pick"), [])
  let tables =
    Tables(..tables(), lifts: [
      #(relayed, TAbs("f", TVar("f"))),
      #(ignoring, TAbs("_", effect_term.pure())),
      #(returned, TAbs("g", labels(["Dom"]))),
      ..tables().lifts
    ])
  let resolve = fn(options) {
    latent.resolve_callback(
      types.Choice(options),
      span(1),
      Some([stdout()]),
      dict.new(),
      resolver(tables),
      Nil,
    ).0.cost
  }
  resolve([relayed, ignoring]) |> should.equal(labels(["Stdout"]))
  resolve([quiet(), returned]) |> should.equal(labels(["Dom"]))
  resolve([relayed, types.OtherExpression])
  |> should.equal(labels(["Stdout", "Unknown"]))
}

pub fn a_relay_through_a_choice_reaches_the_relayed_option_test() {
  // `list.each([loud], case flag { True -> fn(f) { f() } False -> fn(_) { Nil } })`
  let each = QualifiedName("gleam/list", "each")
  let relayed = closure(["f"], 10)
  let ignoring = closure(["_"], 11)
  let tables =
    Tables(
      ..tables(),
      lifts: [
        #(relayed, TAbs("f", TVar("f"))),
        #(ignoring, TAbs("_", effect_term.pure())),
        ..tables().lifts
      ],
      contracts: dict.from_list([
        #(
          each,
          latent.CalleeContract(
            parameters: [
              parameter("list", "l", NonCallbackKind),
              parameter("f", "f", CallbackKind),
            ],
            contract: types.LatentContract(
              runs: Some([]),
              relays: [types.Relay(callback: "f", positions: [Some("l")])],
              carries: None,
            ),
            reviewed: False,
          ),
        ),
      ]),
    )
    |> typed(span(2), thunk())
  let args = [
    argument(
      "list",
      types.Composite([types.Component(span(2), loud())]),
      span(1),
    ),
    argument("f", types.Choice([relayed, ignoring]), span(3)),
  ]
  let assert Ok(contract) = dict.get(tables.contracts, each)
  let #(bindings, Nil) =
    latent.bind_contract(
      each,
      contract,
      args,
      dict.new(),
      resolver(tables),
      Nil,
    )
  dict.get(bindings, "f") |> should.equal(Ok(labels(["Stdout"])))
  dict.get(bindings, "l") |> should.equal(Ok(labels(["Stdout"])))
}

// Inline callback results: the decoder shapes

fn decoder_tables(continuation: ArgumentValue) -> Tables {
  let decode = fn(name) { QualifiedName("gleam/dynamic/decode", name) }
  Tables(
    ..tables(),
    lifts: [#(continuation, TAbs("a", labels(["Stdout"]))), ..tables().lifts],
    constants: dict.from_list([#(decode("int"), Carries(effect_term.pure()))]),
    contracts: dict.from_list([
      #(
        decode("success"),
        latent.CalleeContract(
          parameters: [parameter("data", "d", NonCallbackKind)],
          contract: types.LatentContract(
            runs: Some([]),
            relays: [],
            carries: Some(TVar("d")),
          ),
          reviewed: False,
        ),
      ),
      #(
        decode("field"),
        latent.CalleeContract(
          parameters: [
            parameter("field_decoder", "d", NonCallbackKind),
            parameter("next", "n", CallbackKind),
          ],
          contract: types.LatentContract(
            runs: Some([]),
            relays: [],
            carries: Some(
              effect_term.normalize(
                TUnion([TVar("d"), TVar("n"), TVar("n.returns")]),
              ),
            ),
          ),
          reviewed: False,
        ),
      ),
    ]),
  )
}

fn field_call(continuation: ArgumentValue) -> ArgumentValue {
  types.CallResult(QualifiedName("gleam/dynamic/decode", "field"), [
    argument(
      "field_decoder",
      types.FunctionRef(QualifiedName("gleam/dynamic/decode", "int")),
      span(20),
    ),
    argument("next", continuation, span(21)),
  ])
}

pub fn an_inline_continuation_returning_success_carries_its_cost_test() {
  // 18a: `fn(a) { io.println("x") decode.success(a) }`, `a: Int`.
  let continuation = closure(["a"], 30)
  let tail =
    types.CallResult(QualifiedName("gleam/dynamic/decode", "success"), [
      argument("data", types.LocalRef("a"), span(31)),
    ])
  Tables(..decoder_tables(continuation), tails: [
    #(continuation, types.Component(span(32), tail)),
  ])
  |> typed(span(31), int_type())
  |> latent_of(field_call(continuation), span(1))
  |> should.equal(stdout())
}

pub fn an_inline_continuation_returning_a_traced_decoder_test() {
  // 18b: the tail is a captured decoder built with a printing closure; traced,
  // it carries `[Stdout]`, and untraced (a parameter) it is unknown.
  let continuation = closure(["_"], 30)
  let inner = types.LocalRef("inner")
  let traced =
    Tables(
      ..decoder_tables(continuation),
      tails: [#(continuation, types.Component(span(33), inner))],
      groundings: [#(inner, latent.GroundedLatent(stdout()))],
    )
  latent_of(traced, field_call(continuation), span(1))
  |> should.equal(stdout())
  let untraced =
    Tables(..decoder_tables(continuation), tails: [
      #(continuation, types.Component(span(33), inner)),
    ])
  latent_of(untraced, field_call(continuation), span(1))
  |> should.equal(Carries(labels(["Stdout", "Unknown"])))
}

pub fn a_named_continuation_has_an_unknown_result_test() {
  // 18c: `next_fn`'s cost is known; what it returns is not.
  let next_fn = types.FunctionRef(QualifiedName("app", "next_fn"))
  latent_of(decoder_tables(next_fn), field_call(next_fn), span(1))
  |> should.equal(Carries(labels(["Stdout", "Unknown"])))
}

// What calling a returned function returns

pub fn a_function_whose_result_holds_a_function_escapes_unknown_test() {
  // `get_outer()`, `outer`, a choice holding `outer` and a field holding it:
  // each costs `[]` once called, and what that call returns is undescribed.
  let get_outer = types.CallResult(QualifiedName("app", "get_outer"), [])
  let field = types.ReceiverPath("cfg.run", None)
  let returning = girard.Fn([], thunk())
  let tables =
    Tables(
      ..tables(),
      lifts: [#(get_outer, effect_term.pure()), ..tables().lifts],
      groundings: [#(field, latent.GroundedValue(outer()))],
    )
    |> typed(span(1), returning)
  [get_outer, outer(), types.Choice([outer(), quiet()]), field]
  |> list.map(latent_of(tables, _, span(1)))
  |> should.equal(list.repeat(latent.unknown(), 4))
}

pub fn a_result_is_kept_apart_from_the_cost_by_a_contract_test() {
  // A callback costing nothing whose result prints.
  let callback = closure([], 40)
  let run = QualifiedName("app/ffi", "run")
  let make = QualifiedName("app/ffi", "make")
  let contract = fn(carries) {
    latent.CalleeContract(
      parameters: [parameter("f", "n", CallbackKind)],
      contract: types.LatentContract(..types.no_contract, carries:),
      reviewed: False,
    )
  }
  let tables =
    Tables(
      ..tables(),
      lifts: [#(callback, effect_term.pure()), ..tables().lifts],
      tails: [#(callback, types.Component(span(41), loud()))],
      contracts: dict.from_list([
        #(run, contract(None)),
        #(make, contract(Some(TVar("n.returns")))),
      ]),
    )
    |> typed(span(41), thunk())
  let args = [argument("f", callback, span(42))]
  // Under an unknown runner, the result may run too.
  latent_of(tables, callback, span(42)) |> should.equal(stdout())
  // A contract binding `n` gives its immediate cost alone, and `n.returns`
  // the result.
  let assert Ok(run_contract) = dict.get(tables.contracts, run)
  let #(bindings, Nil) =
    latent.bind_contract(
      run,
      run_contract,
      args,
      dict.new(),
      resolver(tables),
      Nil,
    )
  dict.get(bindings, "n") |> should.equal(Ok(effect_term.pure()))
  dict.get(bindings, "n.returns") |> should.equal(Ok(labels(["Stdout"])))
  latent.call_carries(make, args, dict.new(), resolver(tables), Nil).0
  |> should.equal(Some(stdout()))
}

pub fn a_result_holding_functions_is_unknown_unless_declared_test() {
  let make = QualifiedName("app", "make_record")
  let call = types.CallResult(make, [])
  let assert Ok(record) =
    glance.module("pub type Handlers { Handlers(run: fn() -> Nil) }")
  let base =
    Tables(
      ..tables(),
      type_registry: typedefs.from_module(
        "app",
        record,
        set.from_list(["erlang"]),
      ),
    )
    |> typed(span(1), named("app", "Handlers", []))
  latent_of(base, call, span(1)) |> should.equal(latent.unknown())
  Tables(
    ..base,
    contracts: dict.from_list([
      #(
        make,
        latent.CalleeContract(
          parameters: [],
          contract: types.LatentContract(
            ..types.no_contract,
            carries: Some(labels(["Stdout"])),
          ),
          reviewed: False,
        ),
      ),
    ]),
  )
  |> latent_of(call, span(1))
  |> should.equal(stdout())
}

// Shared variables

pub fn a_shared_variable_takes_the_join_of_every_argument_test() {
  let run_two = QualifiedName("app/ffi", "run_two")
  let contract =
    latent.CalleeContract(
      parameters: [
        parameter("left", "e", NonCallbackKind),
        parameter("right", "e", NonCallbackKind),
      ],
      contract: types.LatentContract(
        runs: Some(["e"]),
        relays: [],
        carries: Some(TVar("e")),
      ),
      reviewed: False,
    )
  let tables =
    Tables(..tables(), contracts: dict.from_list([#(run_two, contract)]))
    |> typed(span(1), thunk())
    |> typed(span(2), thunk())
  let bind = fn(args) {
    latent.bind_contract(
      run_two,
      contract,
      args,
      dict.new(),
      resolver(tables),
      Nil,
    ).0
    |> dict.get("e")
  }
  let left = argument("left", loud(), span(1))
  let right = argument("right", quiet(), span(2))
  let unknown_right = argument("right", types.OtherExpression, span(3))
  // Either order, and with a side nothing bounds.
  bind([left, right]) |> should.equal(Ok(labels(["Stdout"])))
  bind([right, left]) |> should.equal(Ok(labels(["Stdout"])))
  bind([unknown_right, left]) |> should.equal(Ok(labels(["Stdout", "Unknown"])))
  // The same join reaches `carries`.
  latent.call_carries(run_two, [right, left], dict.new(), resolver(tables), Nil).0
  |> should.equal(Some(stdout()))
  latent.call_carries(
    run_two,
    [left, unknown_right],
    dict.new(),
    resolver(tables),
    Nil,
  ).0
  |> should.equal(Some(Carries(labels(["Stdout", "Unknown"]))))
}

pub fn an_unknown_kind_carries_unknown_test() {
  let run = QualifiedName("app/ffi", "run_any")
  let contract =
    latent.CalleeContract(
      parameters: [parameter("x", "x", UnknownKind)],
      contract: types.LatentContract(
        ..types.no_contract,
        carries: Some(TVar("x")),
      ),
      reviewed: False,
    )
  let tables =
    Tables(..tables(), contracts: dict.from_list([#(run, contract)]))
    |> typed(span(1), thunk())
  latent.call_carries(
    run,
    [argument("x", quiet(), span(1))],
    dict.new(),
    resolver(tables),
    Nil,
  ).0
  |> should.equal(Some(latent.unknown()))
}

// A function capture

fn capture(target: ArgumentValue, label: Option(String)) -> ArgumentValue {
  types.Capture(
    span: span(70),
    target:,
    hole: 0,
    label:,
    arguments: [
      types.CallArgument(
        position: 1,
        label: None,
        value: types.LocalRef("b"),
        span: span(71),
      ),
    ],
    evaluated: [],
    captures: [],
  )
}

fn http() -> latent.Latent {
  Carries(labels(["Http"]))
}

pub fn a_capture_costs_its_call_with_the_hole_receiving_the_relay_test() {
  let noisy = capture(types.FunctionRef(QualifiedName("app", "noisy")), None)
  // Lifted, the capture's call prints and runs whatever its hole receives.
  let operator =
    TAbs(latent.capture_hole, TUnion([labels(["Stdout"]), TVar("$hole")]))
  let base = Tables(..tables(), lifts: [#(noisy, operator), ..tables().lifts])
  let cost = fn(hole_type, positions) {
    let tables = typed(base, span(72), girard.Fn([hole_type], nil_type()))
    let #(callback, Nil) =
      latent.resolve_callback(
        noisy,
        span(72),
        positions,
        dict.new(),
        resolver(tables),
        Nil,
      )
    callback
  }
  // A hole that may hold a function receives what the callee relays to it.
  cost(thunk(), Some([http()]))
  |> should.equal(latent.Callback(
    cost: labels(["Http", "Stdout"]),
    result: FunctionFree,
  ))
  // Under a runner that says nothing of it, it receives `[Unknown]`.
  { cost(thunk(), None) }.cost
  |> should.equal(labels(["Stdout", "Unknown"]))
  // A hole typed to hold no function receives nothing, as a closure's
  // parameter of that type reads at its own uses.
  { cost(int_type(), None) }.cost |> should.equal(labels(["Stdout"]))
}

pub fn a_capture_whose_target_cannot_be_lifted_costs_unknown_test() {
  let unnamed = capture(types.OtherExpression, None)
  let tables = typed(tables(), span(72), girard.Fn([int_type()], nil_type()))
  latent.resolve_callback(
    unnamed,
    span(72),
    None,
    dict.new(),
    resolver(tables),
    Nil,
  ).0.cost
  |> should.equal(effect_term.unknown())
}

pub fn a_capture_result_is_what_its_target_line_says_it_carries_test() {
  let make = QualifiedName("app/ffi", "make")
  let wrap = capture(types.FunctionRef(make), Some("x"))
  let tables =
    Tables(
      ..tables(),
      lifts: [
        #(wrap, TAbs(latent.capture_hole, effect_term.pure())),
        ..tables().lifts
      ],
      contracts: dict.from_list([
        #(
          make,
          latent.CalleeContract(
            parameters: [parameter("x", "x", NonCallbackKind)],
            contract: types.LatentContract(
              ..types.no_contract,
              runs: Some([]),
              carries: Some(TVar("x")),
            ),
            reviewed: False,
          ),
        ),
      ]),
    )
    |> typed(span(72), girard.Fn([thunk()], thunk()))
  // What the hole receives comes back in the result, and escapes with it.
  latent.resolve_callback(
    wrap,
    span(72),
    Some([http()]),
    dict.new(),
    resolver(tables),
    Nil,
  ).0
  |> should.equal(latent.Callback(cost: effect_term.pure(), result: http()))
  latent_of(tables, wrap, span(72))
  |> should.equal(Carries(effect_term.unknown()))
}

pub fn a_scalar_literal_carries_nothing_without_types_test() {
  // Extraction reads `1`, `1.0` and `"x"` as values with no components.
  latent_of(tables(), types.Composite([]), span(90))
  |> should.equal(FunctionFree)
}

// A constructor reference read at every type boundary, as a callback and as a
// value: the two readings agree on what the type establishes.

fn constructor_readings(
  type_: Option(girard.Type),
  positions: Option(List(latent.Latent)),
) -> #(latent.Latent, latent.Latent) {
  let at = span(95)
  let tables = case type_ {
    Some(type_) -> typed(tables(), at, type_)
    None -> tables()
  }
  let callback =
    latent.resolve_callback(
      types.ConstructorRef,
      at,
      positions,
      dict.new(),
      resolver(tables),
      Nil,
    ).0
  #(callback.result, latent_of(tables, types.ConstructorRef, at))
}

pub fn a_constructor_reads_alike_on_both_paths_at_each_type_boundary_test() {
  let int = girard.Named("gleam", "Int", [])
  let box = fn(argument) { girard.Named("app", "Box", [argument]) }
  [
    // No type: nothing says what the reference is.
    constructor_readings(None, None),
    // A partly resolved function type: its result holds what it is handed.
    constructor_readings(
      Some(girard.Fn([girard.Var(1)], girard.Var(1))),
      Some([stdout()]),
    ),
    constructor_readings(Some(girard.Fn([girard.Var(1)], girard.Var(1))), None),
    // An unresolved type establishes nothing either.
    constructor_readings(Some(girard.Var(1)), None),
    // A function to a value whose type holds no function.
    constructor_readings(
      Some(girard.Fn([int], girard.Named("gleam", "Result", [int, int]))),
      None,
    ),
    // A named type, nullary: a value holding nothing.
    constructor_readings(Some(box(girard.Var(1))), None),
  ]
  |> should.equal([
    #(latent.unknown(), latent.unknown()),
    #(stdout(), latent.unknown()),
    #(latent.unknown(), latent.unknown()),
    #(latent.unknown(), latent.unknown()),
    #(FunctionFree, Carries(effect_term.pure())),
    #(latent.unknown(), FunctionFree),
  ])
}
