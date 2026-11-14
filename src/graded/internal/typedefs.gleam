// The custom types and type aliases graded can read, normalized so a type
// named anywhere resolves to its definition, and the question asked of them:
// can a value of this type hold a function?
//
// A definition keeps every variant's fields, labelled and unlabelled, with
// every type name resolved to the module that defines it and the definition's
// generic parameters left as parameters.

import girard
import glance
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import graded/internal/extract

// Type expressions
//
// A type as a definition's field states it, or as girard inferred it, with
// every name resolved.

pub type TypeExpr {
  // A nominal type: a prelude type (module `gleam`), a custom type or an
  // alias, by the module that defines it.
  NamedExpr(module: String, name: String, arguments: List(TypeExpr))
  FnExpr(parameters: List(TypeExpr), return: TypeExpr)
  TupleExpr(elements: List(TypeExpr))
  // One of the enclosing definition's generic parameters.
  ParamExpr(name: String)
  // A type variable girard left open.
  VarExpr(id: Int)
  // A name nothing in reach places: no definition, no import, no prelude type.
  UnresolvedExpr
}

// Definitions

pub type TypeDefinition {
  // A type with constructors: each variant's field types, in order.
  CustomDefinition(parameters: List(String), variants: List(List(TypeExpr)))
  // `type Name(params) = aliased`.
  AliasDefinition(parameters: List(String), aliased: TypeExpr)
  // A type declared with no constructors: its representation is foreign.
  ExternalDefinition(parameters: List(String))
}

// Every definition of each name, one per `@target` variant: a module may
// define a type once for Erlang and once for JavaScript.
pub opaque type TypeRegistry {
  TypeRegistry(definitions: Dict(#(String, String), List(TypeDefinition)))
}

pub fn empty() -> TypeRegistry {
  TypeRegistry(definitions: dict.new())
}

// The definitions of both; `b`'s win where both define one name.
pub fn merge(a: TypeRegistry, b: TypeRegistry) -> TypeRegistry {
  TypeRegistry(definitions: dict.merge(a.definitions, b.definitions))
}

pub fn is_empty(registry: TypeRegistry) -> Bool {
  dict.is_empty(registry.definitions)
}

// Every custom type and alias one module defines that is compiled on some of
// `targets`, each `@target` variant of a name kept. A definition `@target`
// keeps off all of them is left out, so it reads as missing.
pub fn from_module(
  module_path: String,
  module: glance.Module,
  targets: Set(String),
) -> TypeRegistry {
  let context = extract.build_import_context(module)
  let local =
    list.append(
      list.map(module.custom_types, fn(definition) {
        definition.definition.name
      }),
      list.map(module.type_aliases, fn(definition) {
        definition.definition.name
      }),
    )
    |> set.from_list
  let scope =
    Scope(
      module_path:,
      local:,
      aliases: context.aliases,
      unqualified: dict.map_values(context.unqualified_types, fn(_name, name) {
        #(name.module, name.function)
      }),
      parameters: set.new(),
    )
  let customs =
    module.custom_types
    |> list.filter(fn(definition) { compiled(definition, targets) })
    |> list.map(fn(definition) {
      let glance.CustomType(name:, parameters:, variants:, ..) =
        definition.definition
      let scope = Scope(..scope, parameters: set.from_list(parameters))
      let definition = case variants {
        [] -> ExternalDefinition(parameters:)
        variants ->
          CustomDefinition(
            parameters:,
            variants: list.map(variants, fn(variant) {
              list.map(variant.fields, fn(field) {
                resolve(field_type(field), scope)
              })
            }),
          )
      }
      #(#(module_path, name), definition)
    })
  let aliases =
    module.type_aliases
    |> list.filter(fn(definition) { compiled(definition, targets) })
    |> list.map(fn(definition) {
      let glance.TypeAlias(name:, parameters:, aliased:, ..) =
        definition.definition
      let scope = Scope(..scope, parameters: set.from_list(parameters))
      #(
        #(module_path, name),
        AliasDefinition(parameters:, aliased: resolve(aliased, scope)),
      )
    })
  TypeRegistry(
    definitions: list.fold(
      list.append(customs, aliases),
      dict.new(),
      fn(acc, entry) {
        dict.upsert(acc, entry.0, fn(existing) {
          list.append(option.unwrap(existing, []), [entry.1])
        })
      },
    ),
  )
}

fn compiled(definition: glance.Definition(a), targets: Set(String)) -> Bool {
  !set.is_empty(extract.compiled_targets(definition, targets))
}

fn field_type(field: glance.VariantField) -> glance.Type {
  case field {
    glance.LabelledVariantField(item:, ..) -> item
    glance.UnlabelledVariantField(item:) -> item
  }
}

// What a type name written in one definition can refer to.
type Scope {
  Scope(
    module_path: String,
    // Types this module defines.
    local: Set(String),
    // Module aliases in scope, `alias -> module path`.
    aliases: Dict(String, String),
    // Types imported unqualified, `written name -> #(module, name)`.
    unqualified: Dict(String, #(String, String)),
    // The enclosing definition's generic parameters.
    parameters: Set(String),
  )
}

const prelude_types = [
  "Int", "Float", "String", "Bool", "Nil", "BitArray", "UtfCodepoint", "List",
  "Result",
]

fn resolve(type_: glance.Type, scope: Scope) -> TypeExpr {
  case type_ {
    glance.NamedType(name:, module: Some(alias), parameters:, ..) ->
      case dict.get(scope.aliases, alias) {
        Ok(module) ->
          NamedExpr(
            module:,
            name:,
            arguments: list.map(parameters, resolve(_, scope)),
          )
        Error(Nil) -> UnresolvedExpr
      }
    glance.NamedType(name:, module: None, parameters:, ..) -> {
      let arguments = list.map(parameters, resolve(_, scope))
      case
        set.contains(scope.local, name),
        dict.get(scope.unqualified, name),
        list.contains(prelude_types, name)
      {
        True, _, _ -> NamedExpr(module: scope.module_path, name:, arguments:)
        False, Ok(#(module, original)), _ ->
          NamedExpr(module:, name: original, arguments:)
        False, Error(Nil), True -> NamedExpr(module: "gleam", name:, arguments:)
        False, Error(Nil), False -> UnresolvedExpr
      }
    }
    glance.TupleType(elements:, ..) ->
      TupleExpr(list.map(elements, resolve(_, scope)))
    glance.FunctionType(parameters:, return:, ..) ->
      FnExpr(
        parameters: list.map(parameters, resolve(_, scope)),
        return: resolve(return, scope),
      )
    glance.VariableType(name:, ..) ->
      case set.contains(scope.parameters, name) {
        True -> ParamExpr(name:)
        False -> UnresolvedExpr
      }
    glance.HoleType(..) -> UnresolvedExpr
  }
}

// Shapes
//
// Whether a value of a type can hold a function. `NoArrows` is proven: every
// position of the fully expanded type is function-free. `HasArrows` proves a
// function position exists and that nothing is missing. `UnknownShape` is
// everything else: an open type variable, a missing or foreign definition.
//
// No instantiation is ever built. Each type constructor is summarized once
// for the run, from the definitions alone: what its fields hold whatever its
// arguments are, and which of its parameters reach a field's value. An
// instantiation is answered from its constructor's summary and the shapes of
// the arguments those parameters take, so an argument that grows at every
// step, as in `type Grow(a) { Step(Grow(#(a, a))) Leaf(a) }`, costs nothing
// more than one that does not.

pub type Shape {
  NoArrows
  HasArrows
  UnknownShape
}

// The join: `NoArrows` is the unit, and a missing component is never forgotten
// because another one proves an arrow.
pub fn join(left: Shape, right: Shape) -> Shape {
  case left, right {
    UnknownShape, _ | _, UnknownShape -> UnknownShape
    HasArrows, _ | _, HasArrows -> HasArrows
    NoArrows, NoArrows -> NoArrows
  }
}

// The external types whose values hold nothing but their type parameters'
// values, keyed `#(module, type name)`.
pub type Containers =
  Set(#(String, String))

// Every constructor's summary, solved once for a run's registry and container
// policy. `shape` reads a type against them and solves nothing.
pub opaque type Shapes {
  Shapes(summaries: Dict(Key, Summary))
}

// The summaries of every definition in `registry` under `containers`.
pub fn shapes(registry: TypeRegistry, containers: Containers) -> Shapes {
  Shapes(summaries: summarize(graph(registry), containers))
}

// No summaries: every custom type, alias and external type reads
// `UnknownShape`.
pub fn no_shapes() -> Shapes {
  Shapes(summaries: dict.new())
}

// The shape of girard's type for a value, read where it stands in one pass
// against the solved summaries: linear in the type girard built.
pub fn shape(type_: girard.Type, shapes: Shapes) -> Shape {
  girard_shape(type_, shapes.summaries)
}

// What a nominal type's name alone says of its shape, before any definition
// is read.
type Head {
  // A prelude scalar: function-free.
  Scalar
  // `List` and `Result`: what their arguments hold.
  Structural
  // `Dynamic`: anything.
  Opaque
  // A custom type, alias or external type, read from its definition.
  Defined
}

// Compared rather than matched: a match on a string literal allocates, and
// this runs at every node of a type being read.
fn head(module: String, name: String) -> Head {
  case module == "gleam", module == "gleam/dynamic" {
    True, _ ->
      case
        name == "Int"
        || name == "Float"
        || name == "String"
        || name == "Bool"
        || name == "Nil"
        || name == "BitArray"
        || name == "UtfCodepoint",
        name == "List" || name == "Result"
      {
        True, _ -> Scalar
        False, True -> Structural
        False, False -> Defined
      }
    False, True ->
      case name == "Dynamic" {
        True -> Opaque
        False -> Defined
      }
    False, False -> Defined
  }
}

fn girard_shape(type_: girard.Type, summaries: Dict(Key, Summary)) -> Shape {
  case type_ {
    girard.Fn(..) -> HasArrows
    girard.Var(..) -> UnknownShape
    girard.Tuple(elements:) -> girard_shape_all(elements, summaries, NoArrows)
    girard.Named(module:, name:, arguments:) ->
      case head(module, name) {
        Scalar -> NoArrows
        Structural -> girard_shape_all(arguments, summaries, NoArrows)
        Opaque -> UnknownShape
        Defined ->
          case applied(summaries, #(module, name), arguments) {
            Error(Nil) -> UnknownShape
            Ok(#(holds, reached)) -> girard_shape_all(reached, summaries, holds)
          }
      }
  }
}

// `shape` joined with every type's shape, stopping at the first
// `UnknownShape`, which every later join keeps. Allocates nothing, so reading
// a large type girard built leaves the heap as it found it.
fn girard_shape_all(
  types: List(girard.Type),
  summaries: Dict(Key, Summary),
  shape: Shape,
) -> Shape {
  case shape, types {
    UnknownShape, _ -> UnknownShape
    _, [] -> shape
    _, [type_, ..rest] ->
      girard_shape_all(
        rest,
        summaries,
        join(shape, girard_shape(type_, summaries)),
      )
  }
}

// A defined constructor applied to arguments: what it holds whatever they are,
// and the arguments at the parameters that reach a value. `Error(Nil)` where
// that is `UnknownShape` already: a missing definition, a summary that is, or
// a count of arguments the definition does not take.
fn applied(
  summaries: Dict(Key, Summary),
  key: Key,
  arguments: List(a),
) -> Result(#(Shape, List(a)), Nil) {
  case dict.get(summaries, key) {
    Error(Nil) | Ok(Summary(holds: UnknownShape, ..)) -> Error(Nil)
    Ok(Summary(holds:, reaches:)) -> {
      use pairs <- result.map(list.strict_zip(reaches, arguments))
      #(
        holds,
        list.filter_map(pairs, fn(pair) {
          case pair {
            #(True, argument) -> Ok(argument)
            #(False, _) -> Error(Nil)
          }
        }),
      )
    }
  }
}

type Key =
  #(String, String)

// What a type constructor's values hold, whatever its arguments: the shape of
// its fields with every parameter function-free, and, per parameter in order,
// whether that parameter reaches a field's value. An `UnknownShape` summary
// reaches every parameter, so it is the top of the order the fixpoint climbs.
type Summary {
  Summary(holds: Shape, reaches: List(Bool))
}

// What one type expression holds with its definition's parameters
// function-free, and which of those parameters reach a value in it.
type Contribution {
  Contribution(holds: Shape, reached: Set(String))
}

fn unknown() -> Contribution {
  Contribution(holds: UnknownShape, reached: set.new())
}

// A registry's definitions, and for each type constructor the constructors
// whose definitions name it.
type Graph {
  Graph(
    definitions: Dict(Key, List(TypeDefinition)),
    dependents: Dict(Key, List(Key)),
  )
}

fn graph(registry: TypeRegistry) -> Graph {
  let dependents =
    dict.fold(registry.definitions, dict.new(), fn(acc, key, variants) {
      list.unique(list.flat_map(variants, definition_mentions))
      |> list.fold(acc, fn(acc, mention) {
        dict.upsert(acc, mention, fn(existing) {
          [key, ..option.unwrap(existing, [])]
        })
      })
    })
  Graph(definitions: registry.definitions, dependents:)
}

// Every type constructor a type expression names where its shape is read: a
// function type is an arrow whatever it names.
fn mentioned(type_: TypeExpr, acc: List(Key)) -> List(Key) {
  case type_ {
    NamedExpr(module:, name:, arguments:) -> {
      let acc = case head(module, name) {
        Defined -> [#(module, name), ..acc]
        Scalar | Structural | Opaque -> acc
      }
      list.fold(arguments, acc, fn(acc, type_) { mentioned(type_, acc) })
    }
    TupleExpr(elements:) ->
      list.fold(elements, acc, fn(acc, type_) { mentioned(type_, acc) })
    FnExpr(..) | ParamExpr(..) | VarExpr(..) | UnresolvedExpr -> acc
  }
}

fn definition_mentions(definition: TypeDefinition) -> List(Key) {
  case definition {
    CustomDefinition(variants:, ..) ->
      list.fold(list.flatten(variants), [], fn(acc, type_) {
        mentioned(type_, acc)
      })
    AliasDefinition(aliased:, ..) -> mentioned(aliased, [])
    ExternalDefinition(..) -> []
  }
}

// Every constructor's summary: the least fixpoint of the definitions, from
// function-free summaries reaching nothing. A summary only climbs, at most two
// more times than its constructor has parameters, and a change re-reads only
// the definitions that name its constructor, so the work is the definitions'
// size times that height.
fn summarize(graph: Graph, containers: Containers) -> Dict(Key, Summary) {
  let summaries =
    dict.map_values(graph.definitions, fn(_key, variants) {
      case variants_parameters(variants) {
        Ok(parameters) ->
          Summary(
            holds: NoArrows,
            reaches: list.map(parameters, fn(_) { False }),
          )
        Error(Nil) -> Summary(holds: UnknownShape, reaches: [])
      }
    })
  let pending = dict.keys(graph.definitions)
  climb(pending, set.from_list(pending), summaries, graph, containers)
}

fn climb(
  pending: List(Key),
  queued: Set(Key),
  summaries: Dict(Key, Summary),
  graph: Graph,
  containers: Containers,
) -> Dict(Key, Summary) {
  case pending {
    [] -> summaries
    [key, ..rest] -> {
      let queued = set.delete(queued, key)
      case climbed(key, summaries, graph, containers) {
        Error(Nil) -> climb(rest, queued, summaries, graph, containers)
        Ok(next) -> {
          let woken = waiting_on(graph, key, queued)
          climb(
            list.append(woken, rest),
            list.fold(woken, queued, set.insert),
            dict.insert(summaries, key, next),
            graph,
            containers,
          )
        }
      }
    }
  }
}

// The constructors whose definitions name `key` and are not queued already.
fn waiting_on(graph: Graph, key: Key, queued: Set(Key)) -> List(Key) {
  dict.get(graph.dependents, key)
  |> result.unwrap([])
  |> list.filter(fn(dependent) { !set.contains(queued, dependent) })
}

// One constructor's summary read again, where it climbed.
fn climbed(
  key: Key,
  summaries: Dict(Key, Summary),
  graph: Graph,
  containers: Containers,
) -> Result(Summary, Nil) {
  use variants <- result.try(dict.get(graph.definitions, key))
  let next = variants_summary(key, variants, summaries, containers)
  case dict.get(summaries, key) == Ok(next) {
    True -> Error(Nil)
    False -> Ok(next)
  }
}

// How many parameters every variant of a name takes, where they agree.
fn variants_parameters(
  variants: List(TypeDefinition),
) -> Result(List(String), Nil) {
  case list.map(variants, definition_parameters) {
    [] -> Error(Nil)
    [first, ..rest] ->
      case
        list.all(rest, fn(other) { list.length(other) == list.length(first) })
      {
        True -> Ok(first)
        False -> Error(Nil)
      }
  }
}

// A name's summary: the join of its variants', the parameters each reaches
// joined by position. Variants taking different counts of parameters
// summarize as `UnknownShape`.
fn variants_summary(
  key: Key,
  variants: List(TypeDefinition),
  summaries: Dict(Key, Summary),
  containers: Containers,
) -> Summary {
  case variants_parameters(variants), variants {
    Error(Nil), _ -> Summary(holds: UnknownShape, reaches: [])
    Ok(_), [single] -> summary(key, single, summaries, containers)
    Ok(_), _ ->
      list.map(variants, summary(key, _, summaries, containers))
      |> list.reduce(fn(left, right) {
        Summary(
          holds: join(left.holds, right.holds),
          reaches: list.map2(left.reaches, right.reaches, fn(a, b) { a || b }),
        )
      })
      |> result.unwrap(Summary(holds: UnknownShape, reaches: []))
  }
}

fn definition_parameters(definition: TypeDefinition) -> List(String) {
  case definition {
    CustomDefinition(parameters:, ..)
    | AliasDefinition(parameters:, ..)
    | ExternalDefinition(parameters:) -> parameters
  }
}

// One constructor's summary read from its definition against the current
// summaries of the constructors it names.
fn summary(
  key: Key,
  definition: TypeDefinition,
  summaries: Dict(Key, Summary),
  containers: Containers,
) -> Summary {
  let parameters = definition_parameters(definition)
  let read = case definition {
    CustomDefinition(variants:, ..) ->
      contribution_all(list.flatten(variants), summaries)
    AliasDefinition(aliased:, ..) -> contribution(aliased, summaries)
    ExternalDefinition(..) ->
      case set.contains(containers, key) {
        True ->
          Contribution(holds: NoArrows, reached: set.from_list(parameters))
        False -> unknown()
      }
  }
  case read.holds {
    UnknownShape ->
      Summary(
        holds: UnknownShape,
        reaches: list.map(parameters, fn(_) { True }),
      )
    holds ->
      Summary(
        holds:,
        reaches: list.map(parameters, set.contains(read.reached, _)),
      )
  }
}

fn contribution(
  type_: TypeExpr,
  summaries: Dict(Key, Summary),
) -> Contribution {
  case type_ {
    FnExpr(..) -> Contribution(holds: HasArrows, reached: set.new())
    VarExpr(..) | UnresolvedExpr -> unknown()
    ParamExpr(name:) ->
      Contribution(holds: NoArrows, reached: set.from_list([name]))
    TupleExpr(elements:) -> contribution_all(elements, summaries)
    NamedExpr(module:, name:, arguments:) ->
      named_contribution(module, name, arguments, summaries)
  }
}

// The join of every type's contribution, stopping at the first
// `UnknownShape`, which every later join keeps.
fn contribution_all(
  types: List(TypeExpr),
  summaries: Dict(Key, Summary),
) -> Contribution {
  list.fold_until(
    types,
    Contribution(holds: NoArrows, reached: set.new()),
    fn(acc, type_) {
      let next = contribution(type_, summaries)
      case join(acc.holds, next.holds) {
        UnknownShape -> list.Stop(unknown())
        holds ->
          list.Continue(Contribution(
            holds:,
            reached: set.union(acc.reached, next.reached),
          ))
      }
    },
  )
}

fn named_contribution(
  module: String,
  name: String,
  arguments: List(TypeExpr),
  summaries: Dict(Key, Summary),
) -> Contribution {
  case head(module, name) {
    Scalar -> Contribution(holds: NoArrows, reached: set.new())
    Structural -> contribution_all(arguments, summaries)
    Opaque -> unknown()
    Defined ->
      case applied(summaries, #(module, name), arguments) {
        Error(Nil) -> unknown()
        Ok(#(holds, reached)) -> {
          let arguments = contribution_all(reached, summaries)
          case join(holds, arguments.holds) {
            UnknownShape -> unknown()
            holds -> Contribution(..arguments, holds:)
          }
        }
      }
  }
}
