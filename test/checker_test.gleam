import assay/checker
import assay/effects
import assay/types.{
  type EffectAnnotation, Check, EffectAnnotation, Effects, QualifiedName,
}
import glance
import gleam/list
import gleam/set
import gleeunit/should

fn knowledge_base() -> effects.KnowledgeBase {
  effects.empty_knowledge_base()
}

fn check_source(
  source: String,
  annotations: List(EffectAnnotation),
) -> List(types.Violation) {
  let assert Ok(module) = glance.module(source)
  checker.check(module, annotations, knowledge_base())
}

pub fn pure_function_passes_test() {
  let source =
    "import gleam/list
pub fn view(items) { list.map(items, fn(x) { x }) }"
  check_source(source, [EffectAnnotation(Check, "view", set.new())])
  |> should.equal([])
}

pub fn effectful_call_in_pure_function_fails_test() {
  let source =
    "import gleam/io
pub fn view() { io.println(\"oops\") }"
  let violations =
    check_source(source, [EffectAnnotation(Check, "view", set.new())])
  violations |> list.length() |> should.equal(1)
  let assert [violation] = violations
  violation.function |> should.equal("view")
  violation.call |> should.equal(QualifiedName("gleam/io", "println"))
}

pub fn declared_effects_pass_test() {
  let source =
    "import gleam/io
pub fn log(msg) { io.println(msg) }"
  check_source(source, [
    EffectAnnotation(Check, "log", set.from_list(["Stdout"])),
  ])
  |> should.equal([])
}

pub fn transitive_violation_test() {
  let source =
    "import gleam/io
pub fn view() { helper() }
fn helper() { io.println(\"sneaky\") }"
  let violations =
    check_source(source, [EffectAnnotation(Check, "view", set.new())])
  violations |> list.length() |> should.equal(1)
  let assert [violation] = violations
  violation.call |> should.equal(QualifiedName("gleam/io", "println"))
}

pub fn multiple_effects_union_test() {
  let source =
    "import gleam/io
import gleam/erlang/process
pub fn do_stuff() {
  io.println(\"hi\")
  process.sleep(100)
}"
  let violations =
    check_source(source, [
      EffectAnnotation(Check, "do_stuff", set.from_list(["Stdout"])),
    ])
  violations
  |> list.any(fn(violation) { violation.call.function == "sleep" })
  |> should.be_true()
}

pub fn missing_function_ignored_test() {
  let source = "pub fn other() { Nil }"
  check_source(source, [EffectAnnotation(Check, "nonexistent", set.new())])
  |> should.equal([])
}

pub fn closure_effects_contribute_test() {
  let source =
    "import gleam/io
import gleam/list
pub fn view(items) {
  list.map(items, fn(x) { io.println(x) })
}"
  let violations =
    check_source(source, [EffectAnnotation(Check, "view", set.new())])
  { violations != [] } |> should.be_true()
}

pub fn mutual_recursion_cycle_test() {
  let source =
    "pub fn a() { b() }
fn b() { a() }"
  let violations =
    check_source(source, [EffectAnnotation(Check, "a", set.new())])
  // Should not infinite loop. Both are local with no external calls, so pure.
  violations |> should.equal([])
}

pub fn unknown_local_function_test() {
  // Function "missing" is referenced but not defined in the module
  let source = "pub fn view() { missing() }"
  let violations =
    check_source(source, [EffectAnnotation(Check, "view", set.new())])
  // Should flag as Unknown effect
  { violations != [] } |> should.be_true()
  let assert [violation] = violations
  violation.call.function |> should.equal("missing")
}

// Infer

pub fn infer_pure_function_test() {
  let source =
    "import gleam/list
pub fn view(items) { list.map(items, fn(x) { x }) }"
  let assert Ok(module) = glance.module(source)
  let inferred = checker.infer(module, knowledge_base())
  let assert [annotation] = inferred
  annotation.kind |> should.equal(Effects)
  annotation.function |> should.equal("view")
  set.size(annotation.effects) |> should.equal(0)
}

pub fn infer_effectful_function_test() {
  let source =
    "import gleam/io
pub fn greet() { io.println(\"hi\") }"
  let assert Ok(module) = glance.module(source)
  let inferred = checker.infer(module, knowledge_base())
  let assert [annotation] = inferred
  annotation.effects |> should.equal(set.from_list(["Stdout"]))
}

pub fn infer_only_public_functions_test() {
  let source =
    "import gleam/io
pub fn view() { helper() }
fn helper() { io.println(\"x\") }"
  let assert Ok(module) = glance.module(source)
  let inferred = checker.infer(module, knowledge_base())
  let assert [annotation] = inferred
  annotation.function |> should.equal("view")
}
