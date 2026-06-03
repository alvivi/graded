import filepath
import glance.{
  type Clause, type Expression, type Field, type Module, type Statement,
}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import graded/internal/types.{
  type ArgumentValue, type CallArgument, type FieldCall, type LocalCall,
  type QualifiedName, type ResolvedCall, CallArgument, ConstructorRef, FieldCall,
  FunctionRef, LocalCall, LocalRef, OtherExpression, QualifiedName, ResolvedCall,
}

/// Classification of a `let`-bound name inside a function body so that
/// later calls through the name can be resolved. `BoundOpaque` covers
/// everything we can't statically track (closures, computed values,
/// destructuring) and is also written on shadowing to erase stale
/// bindings.
type LocalBinding {
  BoundFunctionRef(name: QualifiedName)
  BoundConstructor(fields: Dict(String, ArgumentValue))
  /// A closure's own parameter, bound while walking the closure body. A call
  /// to it is a callback invocation whose effect is accounted where the
  /// closure is applied (operator lifting), so it contributes nothing to the
  /// enclosing function's direct effect — rather than surfacing as `[Unknown]`.
  BoundParam
  /// A let-bound inline closure (`let h = fn(cb) { ... }`). Keeping its
  /// parameters and body lets a later use of `h` as an operator argument be
  /// lifted to an effect operator, just like an inline closure passed directly,
  /// rather than collapsing to `[Unknown]`.
  BoundClosure(params: List(String), body: List(glance.Statement))
  /// A let-bound `case`/`if` over function-like options (`let h = case c { … }`).
  /// A later use of `h` as an operator argument lifts and joins the options.
  BoundChoice(options: List(ArgumentValue))
  /// A let-bound result of calling a function that returns a function
  /// (`let h = pick_handler()`). A later use of `h` as an operator argument
  /// resolves the producer's returned operator.
  BoundReturnedOperator(callee: QualifiedName)
  BoundOpaque
}

type Env =
  Dict(String, LocalBinding)

/// Compute the dotted module name (as it appears in `import` statements) for
/// a `.gleam` file under a given source directory. For example,
/// `module_path_for_source("src/app/router.gleam", "src")` returns
/// `"app/router"`. The returned string is what `build_import_context` will
/// produce for any module that imports this file — the project's dependency
/// graph is built by intersecting the two.
pub fn module_path_for_source(
  gleam_path: String,
  source_directory: String,
) -> String {
  let prefix = source_directory <> "/"
  let relative = case string.starts_with(gleam_path, prefix) {
    True -> string.drop_start(gleam_path, string.length(prefix))
    False -> gleam_path
  }
  filepath.strip_extension(relative)
}

/// Import context built from a module's import list.
///
/// `constructors` maps a same-module custom-type constructor name to
/// the ordered labels of its fields (`None` for unlabelled positions).
/// Used to route positional arguments (`Validator(x)`) to the right
/// field label when building a `BoundConstructor`.
///
/// `cross_constructors` does the same for *other* modules' constructors,
/// keyed by `#(defining module, constructor)`. It is empty by default and
/// populated (via [`with_cross_constructors`](#with_cross_constructors)) only
/// for the package-wide constructor-field walk, so a cross-module positional
/// call (`a.Validator(x)`) can still route `x` to the right field.
pub type ImportContext {
  ImportContext(
    aliases: Dict(String, String),
    unqualified: Dict(String, QualifiedName),
    constructors: Dict(String, List(Option(String))),
    cross_constructors: Dict(#(String, String), List(Option(String))),
  )
}

/// Attach a package-wide `#(defining module, constructor) -> field labels` map
/// to a context, so cross-module positional constructor calls resolve.
pub fn with_cross_constructors(
  context: ImportContext,
  cross_constructors: Dict(#(String, String), List(Option(String))),
) -> ImportContext {
  ImportContext(..context, cross_constructors:)
}

/// A module's `constructor -> field labels` map (the same labels
/// `build_import_context` records for same-module constructors), for building
/// the package-wide cross-module constructor map.
pub fn constructor_label_map(
  module: Module,
) -> Dict(String, List(Option(String))) {
  build_constructor_registry(module)
}

/// Result of extracting calls from a function body.
///
/// `call_args` maps a resolved call's span start (unique per AST node)
/// to the call's arguments. Only populated for resolved calls — local
/// and field calls don't need argument tracking for substitution yet.
pub type ExtractResult {
  ExtractResult(
    resolved: List(ResolvedCall),
    local: List(LocalCall),
    field: List(FieldCall),
    references: List(ResolvedCall),
    call_args: Dict(Int, List(CallArgument)),
  )
}

/// Build import context from a parsed module's imports.
pub fn build_import_context(module: Module) -> ImportContext {
  let #(aliases, unqualified) =
    list.fold(module.imports, #(dict.new(), dict.new()), fn(state, definition) {
      let import_ = definition.definition
      let module_path = import_.module

      let alias = case import_.alias {
        Some(glance.Named(name)) -> name
        Some(glance.Discarded(_)) -> last_segment(module_path)
        None -> last_segment(module_path)
      }

      let new_aliases = dict.insert(state.0, alias, module_path)

      let new_unqualified =
        list.fold(
          import_.unqualified_values,
          state.1,
          fn(unqualified_map, unqualified_import) {
            let name = case unqualified_import.alias {
              Some(alias_name) -> alias_name
              None -> unqualified_import.name
            }
            dict.insert(
              unqualified_map,
              name,
              QualifiedName(
                module: module_path,
                function: unqualified_import.name,
              ),
            )
          },
        )

      #(new_aliases, new_unqualified)
    })

  let constructors = build_constructor_registry(module)
  ImportContext(
    aliases:,
    unqualified:,
    constructors:,
    cross_constructors: dict.new(),
  )
}

fn build_constructor_registry(
  module: Module,
) -> Dict(String, List(Option(String))) {
  list.fold(module.custom_types, dict.new(), fn(acc, definition) {
    list.fold(definition.definition.variants, acc, fn(acc2, variant) {
      let labels =
        list.map(variant.fields, fn(field) {
          case field {
            glance.LabelledVariantField(label:, ..) -> Some(label)
            glance.UnlabelledVariantField(..) -> None
          }
        })
      dict.insert(acc2, variant.name, labels)
    })
  })
}

/// Map each same-module constructor (variant) name to the custom type it
/// belongs to. Stage C keys inferred field effects by *type* name — matching
/// the nominal type girard reports for a receiver — but construction sites name
/// the *constructor*, which can differ (`pub type Shape { Circle(..) }`).
pub fn build_constructor_type_map(module: Module) -> Dict(String, String) {
  list.fold(module.custom_types, dict.new(), fn(acc, definition) {
    let type_name = definition.definition.name
    list.fold(definition.definition.variants, acc, fn(acc2, variant) {
      dict.insert(acc2, variant.name, type_name)
    })
  })
}

/// One constructor call found in a function body. `module` is the constructor's
/// resolved module path for a qualified call (`a.Validator(..)`), or `None` for
/// an unqualified call (resolved against the current module). `fields` maps each
/// field label to its argument value.
pub type ConstructorBinding {
  ConstructorBinding(
    module: Option(String),
    constructor: String,
    fields: Dict(String, ArgumentValue),
  )
}

/// Collect every constructor call in a module's function bodies. Feeds the Stage
/// C constructor-field effect index: a field wired to a known function
/// (`Validator(to_error: io.println)`) lets graded infer that field's effect
/// without a hand-written annotation.
pub fn collect_constructor_bindings(
  module: Module,
  context: ImportContext,
) -> List(ConstructorBinding) {
  list.flat_map(module.functions, fn(definition) {
    ctor_in_statements(definition.definition.body, context)
  })
}

fn ctor_in_statements(
  statements: List(Statement),
  context: ImportContext,
) -> List(ConstructorBinding) {
  list.flat_map(statements, fn(statement) {
    case statement {
      glance.Expression(expression) -> ctor_in_expression(expression, context)
      glance.Assignment(value:, ..) -> ctor_in_expression(value, context)
      glance.Use(function:, ..) -> ctor_in_expression(function, context)
      glance.Assert(expression:, message:, ..) ->
        list.append(
          ctor_in_expression(expression, context),
          ctor_in_optional(message, context),
        )
    }
  })
}

fn ctor_in_each(
  expressions: List(Expression),
  context: ImportContext,
) -> List(ConstructorBinding) {
  list.flat_map(expressions, ctor_in_expression(_, context))
}

fn ctor_in_optional(
  expression: Option(Expression),
  context: ImportContext,
) -> List(ConstructorBinding) {
  case expression {
    Some(e) -> ctor_in_expression(e, context)
    None -> []
  }
}

fn ctor_in_fields(
  fields: List(Field(Expression)),
  context: ImportContext,
) -> List(ConstructorBinding) {
  list.flat_map(fields, fn(field) {
    case field {
      glance.LabelledField(item:, ..) -> ctor_in_expression(item, context)
      glance.UnlabelledField(item:) -> ctor_in_expression(item, context)
      glance.ShorthandField(..) -> []
    }
  })
}

fn ctor_in_expression(
  expression: Expression,
  context: ImportContext,
) -> List(ConstructorBinding) {
  case expression {
    glance.Call(function: glance.Variable(_, name), arguments:, ..) ->
      case is_constructor_name(name) {
        True -> [
          ctor_binding(name, None, arguments, context),
          ..ctor_in_fields(arguments, context)
        ]
        False -> ctor_in_fields(arguments, context)
      }
    glance.Call(
      function: glance.FieldAccess(
        container: glance.Variable(_, alias),
        label: ctor,
        ..,
      ),
      arguments:,
      ..,
    ) ->
      case is_constructor_name(ctor) {
        True -> {
          let module = dict.get(context.aliases, alias) |> option.from_result
          [
            ctor_binding(ctor, module, arguments, context),
            ..ctor_in_fields(arguments, context)
          ]
        }
        False -> ctor_in_fields(arguments, context)
      }
    glance.Call(function:, arguments:, ..) ->
      list.append(
        ctor_in_expression(function, context),
        ctor_in_fields(arguments, context),
      )
    glance.Block(statements:, ..) -> ctor_in_statements(statements, context)
    glance.Fn(body:, ..) -> ctor_in_statements(body, context)
    glance.Tuple(elements:, ..) -> ctor_in_each(elements, context)
    glance.List(elements:, rest:, ..) ->
      list.append(
        ctor_in_each(elements, context),
        ctor_in_optional(rest, context),
      )
    glance.BinaryOperator(left:, right:, ..) ->
      list.append(
        ctor_in_expression(left, context),
        ctor_in_expression(right, context),
      )
    glance.Case(subjects:, clauses:, ..) ->
      list.append(
        ctor_in_each(subjects, context),
        list.flat_map(clauses, fn(clause) {
          ctor_in_expression(clause.body, context)
        }),
      )
    glance.FieldAccess(container:, ..) -> ctor_in_expression(container, context)
    glance.TupleIndex(tuple:, ..) -> ctor_in_expression(tuple, context)
    glance.NegateInt(value:, ..) -> ctor_in_expression(value, context)
    glance.NegateBool(value:, ..) -> ctor_in_expression(value, context)
    glance.Echo(expression:, message:, ..) ->
      list.append(
        ctor_in_optional(expression, context),
        ctor_in_optional(message, context),
      )
    glance.Panic(message:, ..) -> ctor_in_optional(message, context)
    glance.Todo(message:, ..) -> ctor_in_optional(message, context)
    glance.FnCapture(function:, arguments_before:, arguments_after:, ..) ->
      list.append(
        ctor_in_expression(function, context),
        list.append(
          ctor_in_fields(arguments_before, context),
          ctor_in_fields(arguments_after, context),
        ),
      )
    glance.RecordUpdate(record:, fields:, ..) ->
      list.append(
        ctor_in_expression(record, context),
        list.flat_map(fields, fn(field) {
          ctor_in_optional(field.item, context)
        }),
      )
    glance.BitString(segments:, ..) ->
      list.flat_map(segments, fn(segment) {
        ctor_in_expression(segment.0, context)
      })
    _ -> []
  }
}

fn ctor_binding(
  constructor: String,
  module: Option(String),
  arguments: List(Field(Expression)),
  context: ImportContext,
) -> ConstructorBinding {
  let fields = case
    classify_constructor(constructor, module, arguments, context, dict.new())
  {
    BoundConstructor(fields:) -> fields
    _ -> dict.new()
  }
  ConstructorBinding(module:, constructor:, fields:)
}

/// Extract all calls from a list of statements.
pub fn extract_calls(
  statements: List(Statement),
  context: ImportContext,
) -> ExtractResult {
  walk_scope(statements, context, dict.new())
}

/// Walk a sequence of statements threading the binding env forward so
/// later statements see earlier `let`s. The final env is discarded —
/// block/closure bindings don't leak back to the enclosing scope.
fn walk_scope(
  statements: List(Statement),
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  list.fold(statements, #(empty(), env), fn(state, statement) {
    let #(accumulated, current_env) = state
    let #(result, next_env) =
      extract_from_statement(statement, context, current_env)
    #(merge(accumulated, result), next_env)
  }).0
}

// PRIVATE

fn is_constructor_name(name: String) -> Bool {
  case string.first(name) {
    Ok(char) -> char == string.uppercase(char) && char != string.lowercase(char)
    Error(Nil) -> False
  }
}

/// Env-captured function refs beat import-based resolution.
fn resolve_variable_call(
  name: String,
  span: glance.Span,
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  case resolve_env(name, env) {
    BoundFunctionRef(name: qualified) ->
      ExtractResult(
        resolved: [ResolvedCall(qualified, span)],
        local: [],
        field: [],
        references: [],
        call_args: dict.new(),
      )
    // A closure parameter called inside its own body — its effect is the
    // callback's, accounted where the closure is applied, not here.
    BoundParam -> empty()
    _ -> resolve_unqualified_call(name, span, context)
  }
}

/// Bind a closure's parameters as `BoundParam` in a child scope.
fn bind_closure_params(env: Env, parameters: List(glance.FnParameter)) -> Env {
  list.fold(parameters, env, fn(accumulator, parameter) {
    case parameter.name {
      glance.Named(name) -> dict.insert(accumulator, name, BoundParam)
      glance.Discarded(_) -> accumulator
    }
  })
}

fn resolve_unqualified_call(
  name: String,
  span: glance.Span,
  context: ImportContext,
) -> ExtractResult {
  case is_constructor_name(name) {
    True -> empty()
    False ->
      case dict.get(context.unqualified, name) {
        Ok(qualified_name) ->
          ExtractResult(
            resolved: [ResolvedCall(qualified_name, span)],
            local: [],
            field: [],
            references: [],
            call_args: dict.new(),
          )
        Error(Nil) ->
          ExtractResult(
            resolved: [],
            local: [LocalCall(name, span)],
            field: [],
            references: [],
            call_args: dict.new(),
          )
      }
  }
}

/// `alias.label` where `alias` is either an imported module (cross-module
/// call), a locally-constructed record (field-call resolution via env),
/// or an unknown local (FieldCall for type-level annotation lookup).
fn resolve_qualified_call(
  alias: String,
  function_name: String,
  span: glance.Span,
  receiver_span: glance.Span,
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  case is_constructor_name(function_name) {
    True -> empty()
    False ->
      qualified_call_lookup(
        alias,
        function_name,
        span,
        receiver_span,
        context,
        env,
      )
  }
}

fn qualified_call_lookup(
  alias: String,
  function_name: String,
  span: glance.Span,
  receiver_span: glance.Span,
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  case dict.get(context.aliases, alias) {
    Ok(module_path) ->
      ExtractResult(
        resolved: [
          ResolvedCall(QualifiedName(module_path, function_name), span),
        ],
        local: [],
        field: [],
        references: [],
        call_args: dict.new(),
      )
    Error(Nil) ->
      case resolve_env(alias, env) {
        BoundConstructor(fields:) ->
          resolve_constructor_field_call(
            alias,
            function_name,
            span,
            receiver_span,
            fields,
          )
        _ ->
          ExtractResult(
            resolved: [],
            local: [],
            field: [FieldCall(alias, function_name, span, receiver_span)],
            references: [],
            call_args: dict.new(),
          )
      }
  }
}

/// Fallback to `FieldCall` preserves the type-level
/// `type Foo.field : [...]` annotation path for unresolved cases.
fn resolve_constructor_field_call(
  alias: String,
  label: String,
  span: glance.Span,
  receiver_span: glance.Span,
  fields: Dict(String, ArgumentValue),
) -> ExtractResult {
  case dict.get(fields, label) {
    Ok(FunctionRef(name: qualified)) ->
      ExtractResult(
        resolved: [ResolvedCall(qualified, span)],
        local: [],
        field: [],
        references: [],
        call_args: dict.new(),
      )
    Ok(LocalRef(name: local_name)) ->
      ExtractResult(
        resolved: [],
        local: [LocalCall(local_name, span)],
        field: [],
        references: [],
        call_args: dict.new(),
      )
    Ok(ConstructorRef) -> empty()
    Ok(types.Closure(_, _))
    | Ok(types.Choice(_))
    | Ok(types.ReturnedOperator(_))
    | Ok(OtherExpression)
    | Error(Nil) ->
      ExtractResult(
        resolved: [],
        local: [],
        field: [FieldCall(alias, label, span, receiver_span)],
        references: [],
        call_args: dict.new(),
      )
  }
}

/// Resolve a qualified `alias.label` used as a value (not called).
/// Constructors short-circuit to empty; unknown aliases are dropped.
fn resolve_qualified_reference(
  alias: String,
  function_name: String,
  span: glance.Span,
  context: ImportContext,
) -> ExtractResult {
  case is_constructor_name(function_name) {
    True -> empty()
    False -> qualified_reference_lookup(alias, function_name, span, context)
  }
}

fn qualified_reference_lookup(
  alias: String,
  function_name: String,
  span: glance.Span,
  context: ImportContext,
) -> ExtractResult {
  case dict.get(context.aliases, alias) {
    Ok(module_path) ->
      ExtractResult(
        resolved: [],
        local: [],
        field: [],
        references: [
          ResolvedCall(QualifiedName(module_path, function_name), span),
        ],
        call_args: dict.new(),
      )
    Error(Nil) -> empty()
  }
}

fn last_segment(module_path: String) -> String {
  module_path
  |> string.split("/")
  |> list.last()
  |> result.unwrap(module_path)
}

fn extract_from_statement(
  statement: Statement,
  context: ImportContext,
  env: Env,
) -> #(ExtractResult, Env) {
  case statement {
    glance.Expression(expression) -> #(
      extract_from_expression(expression, context, env),
      env,
    )
    glance.Assignment(pattern:, value: expression, ..) -> {
      let result = extract_from_expression(expression, context, env)
      let next_env = bind_assignment(pattern, expression, context, env)
      #(result, next_env)
    }
    glance.Use(patterns:, function: expression, ..) -> {
      let result = extract_from_expression(expression, context, env)
      let next_env = bind_use_patterns(patterns, env)
      #(result, next_env)
    }
    glance.Assert(expression:, message:, ..) -> {
      let expression_result = extract_from_expression(expression, context, env)
      let combined = case message {
        Some(message_expression) ->
          merge(
            expression_result,
            extract_from_expression(message_expression, context, env),
          )
        None -> expression_result
      }
      #(combined, env)
    }
  }
}

/// Record the names introduced by a `let` pattern.
///
/// A `PatternVariable` (simple `let x = rhs`) is classified via
/// Destructuring patterns always bind their names to `BoundOpaque` —
/// tracking values through destructuring is out of scope.
fn bind_assignment(
  pattern: glance.Pattern,
  value: glance.Expression,
  context: ImportContext,
  env: Env,
) -> Env {
  case pattern {
    glance.PatternVariable(name:, ..) ->
      dict.insert(env, name, classify_rhs(value, context, env))
    _ -> fold_pattern_names(pattern, env, bind_opaque)
  }
}

fn bind_opaque(env: Env, name: String) -> Env {
  dict.insert(env, name, BoundOpaque)
}

/// Classify the right-hand side of a `let name = rhs`. Unrecognised
/// shapes become `BoundOpaque`, which deliberately shadows any earlier
/// binding of the same name.
fn classify_rhs(
  expression: glance.Expression,
  context: ImportContext,
  env: Env,
) -> LocalBinding {
  case expression {
    glance.Call(function: glance.Variable(_, name), arguments:, ..) ->
      case is_constructor_name(name) {
        True -> classify_constructor(name, None, arguments, context, env)
        False -> classify_rhs_ref(expression, context, env)
      }
    glance.Call(
      function: glance.FieldAccess(
        container: glance.Variable(_, alias),
        label: ctor,
        ..,
      ),
      arguments:,
      ..,
    ) ->
      case is_constructor_name(ctor) {
        True -> {
          let module = dict.get(context.aliases, alias) |> option.from_result
          classify_constructor(ctor, module, arguments, context, env)
        }
        False -> classify_rhs_ref(expression, context, env)
      }
    _ -> classify_rhs_ref(expression, context, env)
  }
}

/// For RHS expressions that aren't constructor calls, reuse
/// `classify_expression`'s shape recognition and map its result to a
/// `LocalBinding`. Eager resolution through the env means aliases never
/// need to be chased at lookup time.
fn classify_rhs_ref(
  expression: glance.Expression,
  context: ImportContext,
  env: Env,
) -> LocalBinding {
  case classify_expression(expression, context, env) {
    FunctionRef(name:) -> BoundFunctionRef(name:)
    LocalRef(name:) -> dict.get(env, name) |> result.unwrap(BoundOpaque)
    types.Closure(params, body) -> BoundClosure(params, body)
    types.Choice(options) -> BoundChoice(options)
    types.ReturnedOperator(callee) -> BoundReturnedOperator(callee)
    ConstructorRef | OtherExpression -> BoundOpaque
  }
}

/// Build a BoundConstructor from a constructor call's arguments.
/// Labelled arguments populate `fields` directly. Unlabelled ones are
/// mapped to the corresponding labelled slot when the constructor's
/// declared labels are known (same-module); otherwise discarded —
/// field-call resolution only needs the labelled view.
fn classify_constructor(
  type_name: String,
  module: Option(String),
  arguments: List(Field(Expression)),
  context: ImportContext,
  env: Env,
) -> LocalBinding {
  let declared_labels = case module {
    None -> dict.get(context.constructors, type_name) |> result.unwrap([])
    Some(module) ->
      dict.get(context.cross_constructors, #(module, type_name))
      |> result.unwrap([])
  }
  let #(fields, _remaining) =
    list.fold(arguments, #(dict.new(), declared_labels), fn(acc, field) {
      let #(fields_acc, remaining) = acc
      case field {
        glance.LabelledField(label:, item:, ..) -> #(
          dict.insert(
            fields_acc,
            label,
            classify_expression(item, context, env),
          ),
          remaining,
        )
        glance.ShorthandField(label:, ..) -> #(
          dict.insert(fields_acc, label, OtherExpression),
          remaining,
        )
        glance.UnlabelledField(item:) -> {
          let value = classify_expression(item, context, env)
          case remaining {
            [Some(label), ..rest] -> #(
              dict.insert(fields_acc, label, value),
              rest,
            )
            [_, ..rest] -> #(fields_acc, rest)
            [] -> #(fields_acc, [])
          }
        }
      }
    })
  BoundConstructor(fields:)
}

fn resolve_env(name: String, env: Env) -> LocalBinding {
  dict.get(env, name) |> result.unwrap(BoundOpaque)
}

/// `use` bindings come from the callback call-site, which we can't
/// trace syntactically — mark them all opaque.
fn bind_use_patterns(patterns: List(glance.UsePattern), env: Env) -> Env {
  list.fold(patterns, env, fn(acc, use_pattern) {
    fold_pattern_names(use_pattern.pattern, acc, bind_opaque)
  })
}

/// Walk a pattern and fold over every variable name it binds into
/// scope, avoiding the intermediate `List(String)` a collect-then-fold
/// would allocate.
fn fold_pattern_names(
  pattern: glance.Pattern,
  acc: a,
  step: fn(a, String) -> a,
) -> a {
  case pattern {
    glance.PatternVariable(name:, ..) -> step(acc, name)
    glance.PatternAssignment(pattern: inner, name:, ..) ->
      fold_pattern_names(inner, step(acc, name), step)
    glance.PatternTuple(elements:, ..) ->
      list.fold(elements, acc, fn(inner, p) {
        fold_pattern_names(p, inner, step)
      })
    glance.PatternList(elements:, tail:, ..) -> {
      let head =
        list.fold(elements, acc, fn(inner, p) {
          fold_pattern_names(p, inner, step)
        })
      case tail {
        Some(tail_pattern) -> fold_pattern_names(tail_pattern, head, step)
        None -> head
      }
    }
    glance.PatternVariant(arguments:, ..) ->
      list.fold(arguments, acc, fn(inner, field) {
        case field {
          glance.LabelledField(item:, ..) ->
            fold_pattern_names(item, inner, step)
          glance.ShorthandField(label:, ..) -> step(inner, label)
          glance.UnlabelledField(item:) -> fold_pattern_names(item, inner, step)
        }
      })
    glance.PatternConcatenate(prefix_name:, rest_name:, ..) -> {
      let with_prefix = case prefix_name {
        Some(glance.Named(n)) -> step(acc, n)
        _ -> acc
      }
      case rest_name {
        glance.Named(n) -> step(with_prefix, n)
        glance.Discarded(_) -> with_prefix
      }
    }
    glance.PatternBitString(segments:, ..) ->
      list.fold(segments, acc, fn(inner, segment) {
        fold_pattern_names(segment.0, inner, step)
      })
    glance.PatternInt(..)
    | glance.PatternFloat(..)
    | glance.PatternString(..)
    | glance.PatternDiscard(..) -> acc
  }
}

fn extract_from_expression(
  expression: Expression,
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  case expression {
    // Qualified call: io.println(x), or qualified type constructor: types.NotFound(id).
    // The argument walk is unconditional so side-effecting sub-expressions
    // inside a constructor's args (e.g. NotFound(io.println(x))) still propagate.
    glance.Call(
      location: span,
      function: glance.FieldAccess(
        container: glance.Variable(receiver_span, alias),
        label: function_name,
        ..,
      ),
      arguments:,
    ) ->
      merge_with_args(
        resolve_qualified_call(
          alias,
          function_name,
          span,
          receiver_span,
          context,
          env,
        ),
        extract_from_arguments(arguments, context, env),
        span,
        classify_arguments(arguments, context, env, 0),
      )

    // Unqualified or local call: println(x) or helper(x)
    glance.Call(location: span, function: glance.Variable(_, name), arguments:) ->
      merge_with_args(
        resolve_variable_call(name, span, context, env),
        extract_from_arguments(arguments, context, env),
        span,
        classify_arguments(arguments, context, env, 0),
      )

    // Other call shapes (e.g., result of another call being called)
    glance.Call(function: function_expression, arguments:, ..) ->
      merge(
        extract_from_expression(function_expression, context, env),
        extract_from_arguments(arguments, context, env),
      )

    // Pipe: left |> right. The piped value becomes implicit argument 0
    // of the right-hand call; explicit arguments shift up by one.
    glance.BinaryOperator(name: glance.Pipe, left:, right:, ..) -> {
      let pipe_arg =
        CallArgument(
          position: 0,
          label: None,
          value: classify_expression(left, context, env),
        )
      merge(
        extract_from_expression(left, context, env),
        extract_pipe_target(right, context, env, [pipe_arg]),
      )
    }

    // Other binary operators
    glance.BinaryOperator(left:, right:, ..) ->
      merge(
        extract_from_expression(left, context, env),
        extract_from_expression(right, context, env),
      )

    // Closure: effects in body contribute to enclosing function. The closure's
    // own parameters are bound (as `BoundParam`) so calls to them aren't
    // mistaken for unresolved local calls.
    glance.Fn(arguments:, body: statements, ..) ->
      walk_scope(statements, context, bind_closure_params(env, arguments))

    // Block
    glance.Block(statements:, ..) -> walk_scope(statements, context, env)

    // Case expression
    glance.Case(subjects:, clauses:, ..) ->
      merge(
        fold_expressions(subjects, context, env),
        list.fold(clauses, empty(), fn(accumulated, clause) {
          merge(accumulated, extract_from_clause(clause, context, env))
        }),
      )

    // Tuple
    glance.Tuple(elements:, ..) -> fold_expressions(elements, context, env)

    // List
    glance.List(elements:, rest:, ..) ->
      merge_optional(
        fold_expressions(elements, context, env),
        rest,
        context,
        env,
      )

    // Negate
    glance.NegateInt(value:, ..) -> extract_from_expression(value, context, env)
    glance.NegateBool(value:, ..) ->
      extract_from_expression(value, context, env)

    // Record update
    glance.RecordUpdate(record:, ..) ->
      extract_from_expression(record, context, env)

    // Function reference: qualified name used as a value (not called).
    glance.FieldAccess(
      location: span,
      container: glance.Variable(_, alias),
      label: function_name,
    ) -> resolve_qualified_reference(alias, function_name, span, context)

    // Other field access (not a call — just traversing)
    glance.FieldAccess(container:, ..) ->
      extract_from_expression(container, context, env)

    // Tuple index
    glance.TupleIndex(tuple:, ..) ->
      extract_from_expression(tuple, context, env)

    // FnCapture: function reference with partial application
    glance.FnCapture(
      function: function_expression,
      arguments_before:,
      arguments_after:,
      ..,
    ) ->
      merge(
        extract_from_expression(function_expression, context, env),
        merge(
          extract_from_arguments(arguments_before, context, env),
          extract_from_arguments(arguments_after, context, env),
        ),
      )

    // Echo
    glance.Echo(expression: Some(inner), ..) ->
      extract_from_expression(inner, context, env)
    glance.Echo(expression: None, ..) -> empty()

    // Unqualified function reference used as a value (not called)
    glance.Variable(location: span, name:) ->
      case dict.get(context.unqualified, name) {
        Ok(qualified_name) ->
          ExtractResult(
            resolved: [],
            local: [],
            field: [],
            references: [ResolvedCall(qualified_name, span)],
            call_args: dict.new(),
          )
        Error(Nil) -> empty()
      }

    // Leaf nodes
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Panic(..)
    | glance.Todo(..)
    | glance.BitString(..) -> empty()
  }
}

fn extract_pipe_target(
  expression: Expression,
  context: ImportContext,
  env: Env,
  pipe_args: List(CallArgument),
) -> ExtractResult {
  case expression {
    glance.FieldAccess(
      location: span,
      container: glance.Variable(receiver_span, alias),
      label: function_name,
    ) ->
      attach_pipe_args(
        resolve_qualified_call(
          alias,
          function_name,
          span,
          receiver_span,
          context,
          env,
        ),
        span,
        pipe_args,
      )

    glance.Variable(location: span, name:) ->
      attach_pipe_args(
        resolve_variable_call(name, span, context, env),
        span,
        pipe_args,
      )

    // `left |> right(args)` — the piped value is the first argument
    // and the explicit args shift up by one.
    glance.Call(
      location: span,
      function: glance.FieldAccess(
        container: glance.Variable(receiver_span, alias),
        label: function_name,
        ..,
      ),
      arguments:,
    ) ->
      merge_with_args(
        resolve_qualified_call(
          alias,
          function_name,
          span,
          receiver_span,
          context,
          env,
        ),
        extract_from_arguments(arguments, context, env),
        span,
        list.append(pipe_args, classify_arguments(arguments, context, env, 1)),
      )

    glance.Call(location: span, function: glance.Variable(_, name), arguments:) ->
      merge_with_args(
        resolve_variable_call(name, span, context, env),
        extract_from_arguments(arguments, context, env),
        span,
        list.append(pipe_args, classify_arguments(arguments, context, env, 1)),
      )

    // Any other shape — handle normally; no arg tracking.
    _ -> extract_from_expression(expression, context, env)
  }
}

fn extract_from_clause(
  clause: Clause,
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  let body_result = extract_from_expression(clause.body, context, env)
  case clause.guard {
    Some(guard) ->
      merge(body_result, extract_from_expression(guard, context, env))
    None -> body_result
  }
}

/// Build a CallArgument list from glance fields, starting at a given
/// position offset (used by pipes to leave position 0 for the piped value).
fn classify_arguments(
  arguments: List(Field(Expression)),
  context: ImportContext,
  env: Env,
  position_offset: Int,
) -> List(CallArgument) {
  list.index_map(arguments, fn(field, i) {
    let #(label, expression) = case field {
      glance.LabelledField(label:, item:, ..) -> #(Some(label), Some(item))
      glance.ShorthandField(label:, ..) -> #(Some(label), None)
      glance.UnlabelledField(item:) -> #(None, Some(item))
    }
    let value = case expression {
      None -> OtherExpression
      Some(expr) -> classify_expression(expr, context, env)
    }
    CallArgument(position: i + position_offset, label:, value:)
  })
}

/// Classify a single argument expression. Determines whether it's a
/// function reference (qualified or unqualified import), a local
/// identifier, a constructor (uppercase), or something else.
fn classify_expression(
  expression: Expression,
  context: ImportContext,
  env: Env,
) -> types.ArgumentValue {
  case expression {
    glance.FieldAccess(
      container: glance.Variable(_, alias),
      label: function_name,
      ..,
    ) ->
      case is_constructor_name(function_name) {
        True -> ConstructorRef
        False ->
          case dict.get(context.aliases, alias) {
            Ok(module_path) ->
              FunctionRef(name: QualifiedName(module_path, function_name))
            Error(Nil) -> OtherExpression
          }
      }
    glance.Variable(_, name) ->
      case is_constructor_name(name) {
        True -> ConstructorRef
        False ->
          case dict.get(context.unqualified, name) {
            Ok(qualified_name) -> FunctionRef(name: qualified_name)
            Error(Nil) ->
              case resolve_env(name, env) {
                BoundFunctionRef(name: qualified) ->
                  FunctionRef(name: qualified)
                // A let-bound closure used by name resolves to the closure
                // itself, so it can be lifted to an operator at the use site.
                BoundClosure(params, body) -> types.Closure(params, body)
                // A let-bound branch resolves to its options, lifted and joined
                // at the use site.
                BoundChoice(options) -> types.Choice(options)
                // A let-bound producer call resolves to its returned operator
                // at the use site.
                BoundReturnedOperator(callee) -> types.ReturnedOperator(callee)
                _ -> LocalRef(name:)
              }
          }
      }
    // An inline closure argument: capture its parameter names and body so the
    // checker can lift it to an effect operator when it's passed to an operator
    // parameter.
    glance.Fn(arguments:, body:, ..) ->
      types.Closure(
        list.map(arguments, fn(parameter) {
          case parameter.name {
            glance.Named(name) -> name
            glance.Discarded(_) -> "_"
          }
        }),
        body,
      )
    // A `case`/`if` whose every clause body is a bare function-like value is a
    // selection among known operators: capture them as a `Choice` so the checker
    // can lift and join them. Any non-function (or block) clause body, or no
    // clauses, makes the whole thing opaque.
    glance.Case(clauses:, ..) -> classify_case_options(clauses, context, env)
    // A call to a function (not a constructor) is a *returned operator* if that
    // function returns a function — captured here, resolved at the use site
    // against the producer's inferred returned operator.
    glance.Call(function:, ..) -> classify_call_producer(function, context, env)
    _ -> OtherExpression
  }
}

/// Classify a call's *callee* as the producer of a returned operator. When the
/// callee is a function reference (cross-module) or a same-module bare name, the
/// call is a `ReturnedOperator`; a constructor call or anything else is opaque.
fn classify_call_producer(
  function: glance.Expression,
  context: ImportContext,
  env: Env,
) -> types.ArgumentValue {
  case classify_expression(function, context, env) {
    FunctionRef(name: callee) -> types.ReturnedOperator(callee)
    // Same-module bare name: `""` module is the resolved-on-demand sentinel.
    LocalRef(name:) -> types.ReturnedOperator(QualifiedName("", name))
    ConstructorRef
    | types.Closure(..)
    | types.Choice(..)
    | types.ReturnedOperator(..)
    | OtherExpression -> OtherExpression
  }
}

/// The value a function evaluates to, for returned-operator inference: the tail
/// statement's expression classified with only the import context in scope
/// (parameters and prior `let`s are deliberately not threaded — v1 handles a
/// directly-returned ref/closure/branch/producer-call). `Error` when the body's
/// tail isn't a bare expression.
pub fn return_value(
  function: glance.Function,
  context: ImportContext,
) -> Result(ArgumentValue, Nil) {
  case list.last(function.body) {
    Ok(glance.Expression(expression)) ->
      Ok(classify_expression(expression, context, dict.new()))
    _ -> Error(Nil)
  }
}

/// Classify the clause bodies of a `case` as a `Choice` of function-like
/// options, or `OtherExpression` if any body isn't a bare function/closure/
/// branch (or there are no clauses).
fn classify_case_options(
  clauses: List(glance.Clause),
  context: ImportContext,
  env: Env,
) -> types.ArgumentValue {
  let options =
    list.map(clauses, fn(clause) {
      classify_expression(clause.body, context, env)
    })
  // `LocalRef` is admitted: a same-module function resolves via the function
  // map at the use site, and a genuinely opaque local just lifts to `[Unknown]`
  // (sound). Only constructors and unclassifiable expressions disqualify a branch.
  let all_function_like =
    options != []
    && list.all(options, fn(option) {
      case option {
        FunctionRef(..)
        | LocalRef(..)
        | types.Closure(..)
        | types.Choice(..)
        | types.ReturnedOperator(..) -> True
        ConstructorRef | OtherExpression -> False
      }
    })
  case all_function_like {
    True -> types.Choice(options)
    False -> OtherExpression
  }
}

/// Record a pipe target's argument list against its call span. Used
/// by the two pipe-target shapes (`|> foo.bar` and `|> bar`) that
/// don't go through `merge_with_args`.
fn attach_pipe_args(
  base: ExtractResult,
  span: glance.Span,
  pipe_args: List(CallArgument),
) -> ExtractResult {
  ExtractResult(
    ..base,
    call_args: dict.insert(base.call_args, span.start, pipe_args),
  )
}

/// Merge an extraction result with a call's sub-expression walk, and
/// record the call's argument list keyed by span start.
fn merge_with_args(
  call_result: ExtractResult,
  inner: ExtractResult,
  span: glance.Span,
  args: List(CallArgument),
) -> ExtractResult {
  let merged = merge(call_result, inner)
  ExtractResult(
    ..merged,
    call_args: dict.insert(merged.call_args, span.start, args),
  )
}

fn extract_from_arguments(
  arguments: List(Field(Expression)),
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  list.fold(arguments, empty(), fn(accumulated, field) {
    let expression = case field {
      glance.LabelledField(item:, ..) -> Some(item)
      glance.ShorthandField(..) -> None
      glance.UnlabelledField(item:) -> Some(item)
    }
    case expression {
      Some(inner) ->
        merge(accumulated, extract_from_expression(inner, context, env))
      None -> accumulated
    }
  })
}

fn fold_expressions(
  expressions: List(Expression),
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  list.fold(expressions, empty(), fn(accumulated, expression) {
    merge(accumulated, extract_from_expression(expression, context, env))
  })
}

fn merge_optional(
  base: ExtractResult,
  optional_expression: Option(Expression),
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  case optional_expression {
    Some(expression) ->
      merge(base, extract_from_expression(expression, context, env))
    None -> base
  }
}

fn empty() -> ExtractResult {
  ExtractResult(
    resolved: [],
    local: [],
    field: [],
    references: [],
    call_args: dict.new(),
  )
}

fn merge(left: ExtractResult, right: ExtractResult) -> ExtractResult {
  ExtractResult(
    resolved: list.append(left.resolved, right.resolved),
    local: list.append(left.local, right.local),
    field: list.append(left.field, right.field),
    references: list.append(left.references, right.references),
    call_args: dict.merge(left.call_args, right.call_args),
  )
}
