// Per-expression type information sourced from girard, keyed so the checker
// can ask "what is the nominal type of the receiver at this span?" and "which
// of this function's parameters are function-typed?" — without knowing
// anything about girard's package-annotation shape.
//
// Expressions are keyed by their full `#(start, end)` span. The start offset
// alone is not unique — a receiver `v`, the field access `v.field`, and the
// whole call `v.field(x)` all share a start offset but have different types,
// so we need the end offset to pick out the receiver. A function girard could
// not type contributes no expressions, so its spans are simply absent: every
// lookup miss falls back to the syntax-level path, which is what makes girard
// a pure enhancement layer (it can only ever upgrade an `[Unknown]`, never
// change an already-resolved result).
//
// The one exception is a call through a name that shadows an imported module.
// Which of the two the compiler reads is *decided* by girard's resolution of
// that access, and the call reads `[Unknown]` wherever that resolution
// establishes neither reading: it recorded nothing, recorded an explicit
// unresolved, recorded something that is not a module function or a nominal
// record field, or recorded a target whose identity is not the site's.
//
// Beside the types, girard's own reading of each reference is retained: which
// member a field access or a bare callee resolved to, which definitions it
// declined to type, and which it left out for the other build target. Those
// three answer the same question from girard's side that the checker answers
// from its own, and they are kept whole rather than reduced, so the two can be
// compared per site.

import girard.{type Error, type Resolution, type Type, Named}
import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import graded/internal/extract
import graded/internal/types

// Inferred information for a whole package:
// - `by_module`: module path -> (expression `#(start, end)` span -> type).
// - `fn_typed`: module path -> (function name -> the set of its function-typed
//   parameter names, inferred from girard's signature — covers params with no
//   syntactic `fn(...)` annotation).
// - `evidence`: module path -> girard's own reading of that module.
// - `targets`: the targets girard ran on, in order, primary first.
// - `absent`: the module paths the primary run returned no result for.
// - `unfilled`: the module paths a secondary run returned no result for.
//
// The last three are observational: the coverage report reads them, and
// nothing that decides a charge does.
pub type TypeInfo {
  TypeInfo(
    by_module: Dict(String, Dict(#(Int, Int), Type)),
    fn_typed: Dict(String, Dict(String, Set(String))),
    evidence: Dict(String, ModuleEvidence),
    targets: List(girard.Target),
    absent: Set(String),
    unfilled: Set(String),
  )
}

// girard's own reading of one module: which member every reference resolved to,
// which definitions it declined and under which error bucket, and which it left
// out for the other build target. A call site is judged against all three at
// once — dropped, then skipped, then the resolution at its span — so they are
// held together rather than as three separately-keyed maps that could be sliced
// for different modules.
//
// A skip keeps only `error_bucket`'s answer rather than the `girard.Error`: the
// error carries whole inferred type trees, and nothing reads them.
//
// Skips and drops are both keyed by the definition's `#(start, end)` span rather
// than by its name: a `@target(erlang)` and a `@target(javascript)` definition
// share one name, and only one of the two is in the build for a given run.
//
// `unlocated` holds the skips whose name matched no definition the module
// declares on the run's target. They are kept whole — name and bucket — rather
// than folded onto a sentinel span where two would collide. Expected empty.
pub type ModuleEvidence {
  ModuleEvidence(
    resolutions: Dict(#(Int, Int), Resolution),
    skipped: Dict(#(Int, Int), String),
    unlocated: List(#(String, String)),
    dropped: Set(#(Int, Int)),
  )
}

// The empty reading — girard said nothing about this module, so every site in it
// reads as "no typed evidence" rather than as an answer. What
// `evidence_for_module` gives for a module girard never saw.
pub fn no_evidence() -> ModuleEvidence {
  ModuleEvidence(dict.new(), dict.new(), [], set.new())
}

// girard's reading of one module, folded out of its annotation result.
// `skip_bucket` reduces an error to the stable bucket the reading keeps; the
// glance module and the run's target place each skipped name on the span of the
// definition of that name the run kept. girard skips functions and constants
// alike, and the span alone tells a reader which it was.
//
// A skip naming no definition the module declares on this target goes to
// `unlocated` whole: a span it has not got cannot be invented, and two unplaced
// skips must stay two entries.
pub fn evidence_of(
  result: girard.ModuleResult,
  skip_bucket: fn(Error) -> String,
  module: glance.Module,
  target: girard.Target,
) -> ModuleEvidence {
  let #(skipped, unlocated) =
    list.fold(result.skipped, #(dict.new(), []), fn(acc, entry) {
      let #(skipped, unlocated) = acc
      let #(name, error) = entry
      case locate_definition(module, target, name) {
        Ok(span) -> #(dict.insert(skipped, span, skip_bucket(error)), unlocated)
        Error(Nil) -> #(skipped, [#(name, skip_bucket(error)), ..unlocated])
      }
    })
  ModuleEvidence(
    resolutions: list.fold(
      result.annotated.resolutions,
      dict.new(),
      fn(acc, reference) {
        dict.insert(
          acc,
          #(reference.span.start, reference.span.end),
          reference.resolution,
        )
      },
    ),
    skipped:,
    unlocated: list.reverse(unlocated),
    dropped: list.fold(result.annotated.dropped, set.new(), fn(acc, definition) {
      set.insert(acc, #(definition.span.start, definition.span.end))
    }),
  )
}

// The span of the definition named `name` that the run's target keeps. Gleam
// admits one on-target definition per name, so the first match is the only one;
// a name matching none — girard named a definition this module does not declare
// — answers `Error(Nil)` and the skip stays unlocated.
fn locate_definition(
  module: glance.Module,
  target: girard.Target,
  name: String,
) -> Result(#(Int, Int), Nil) {
  case
    list.find(module.functions, fn(definition) {
      definition.definition.name == name && kept_on_target(definition, target)
    })
  {
    Ok(definition) -> Ok(span_of(definition.definition.location))
    Error(Nil) ->
      case
        list.find(module.constants, fn(definition) {
          definition.definition.name == name
          && kept_on_target(definition, target)
        })
      {
        Ok(definition) -> Ok(span_of(definition.definition.location))
        Error(Nil) -> Error(Nil)
      }
  }
}

// Whether the run's target compiles this definition — girard's own `@target`
// partition, read from graded's side of the same attribute.
pub fn kept_on_target(
  definition: glance.Definition(a),
  target: girard.Target,
) -> Bool {
  set.contains(
    extract.compiled_targets(definition, types.every_target()),
    target_name(target),
  )
}

// girard's target as the name a `@target` attribute writes.
pub fn target_name(target: girard.Target) -> String {
  case target {
    girard.Erlang -> "erlang"
    girard.JavaScript -> "javascript"
  }
}

// A glance span as the `#(start, end)` pair every map here keys on.
fn span_of(location: glance.Span) -> #(Int, Int) {
  #(location.start, location.end)
}

// The span->type slice of one module's annotation result, keyed the way
// `receiver_type` and `type_at` read it back.
pub fn span_types(result: girard.ModuleResult) -> Dict(#(Int, Int), Type) {
  list.fold(result.annotated.expressions, dict.new(), fn(acc, annotation) {
    dict.insert(
      acc,
      #(annotation.span.start, annotation.span.end),
      annotation.type_,
    )
  })
}

// The empty type index — every lookup misses, so the checker behaves exactly
// as it did before girard. Used when type inference is unavailable.
pub fn none() -> TypeInfo {
  TypeInfo(dict.new(), dict.new(), dict.new(), [], set.new(), set.new())
}

// Build a `TypeInfo` from per-module span->type maps, per-module
// function->fn-typed-params maps, and girard's per-module readings — with the
// targets the runs used and the modules each of them said nothing about.
pub fn from_modules(
  types_modules: List(#(String, Dict(#(Int, Int), Type))),
  fn_typed_modules: List(#(String, Dict(String, Set(String)))),
  evidence_modules: List(#(String, ModuleEvidence)),
  targets: List(girard.Target),
  absent: Set(String),
  unfilled: Set(String),
) -> TypeInfo {
  TypeInfo(
    by_module: dict.from_list(types_modules),
    fn_typed: dict.from_list(fn_typed_modules),
    evidence: dict.from_list(evidence_modules),
    targets:,
    absent:,
    unfilled:,
  )
}

// The span->type slice for one module, or an empty map if the module was not
// annotated (girard error, or not part of the package).
pub fn for_module(
  info: TypeInfo,
  module_path: String,
) -> Dict(#(Int, Int), Type) {
  case dict.get(info.by_module, module_path) {
    Ok(module_types) -> module_types
    Error(Nil) -> dict.new()
  }
}

// The function->fn-typed-params slice for one module.
pub fn fn_typed_for_module(
  info: TypeInfo,
  module_path: String,
) -> Dict(String, Set(String)) {
  case dict.get(info.fn_typed, module_path) {
    Ok(module_fn_typed) -> module_fn_typed
    Error(Nil) -> dict.new()
  }
}

// Everything girard said about one module: the type of every expression it
// annotated keyed by span, which of each function's parameters it inferred as
// function-typed, and the member every reference resolved to beside the
// definitions it declined and the ones it left out for the other target. The
// checker threads the three slices to the same places and reads them at the
// same sites, so they travel as one value.
pub type ModuleReading {
  ModuleReading(
    expressions: Dict(#(Int, Int), Type),
    fn_typed: Dict(String, Set(String)),
    evidence: ModuleEvidence,
  )
}

// girard's whole reading of one module. A module girard never saw yields the
// empty reading, so every site in it reads as "no typed evidence".
pub fn reading_for_module(
  info: TypeInfo,
  module_path: String,
) -> ModuleReading {
  ModuleReading(
    expressions: for_module(info, module_path),
    fn_typed: fn_typed_for_module(info, module_path),
    evidence: evidence_for_module(info, module_path),
  )
}

// The empty reading — girard said nothing about this module. Used where type
// inference is unavailable, and by every test that drives the checker untyped.
pub fn no_reading() -> ModuleReading {
  ModuleReading(dict.new(), dict.new(), no_evidence())
}

// The merge
//
// girard runs once per target a definition in the package is gated to, and the
// readings merge per module: the primary target's reading whole, the other
// target's reading only inside the definitions the primary left out.
//
// Three rules carry it. The merge fills holes and overwrites nothing — an entry
// from the secondary run enters only when it lies inside a definition span the
// primary run `dropped`, and a span the primary annotated keeps the primary's
// entry whatever the secondary says. A definition is read against the target
// that builds it, which needs no rule of its own: the other run recorded
// nothing inside it. And every kind of entry obeys the first rule, skips
// included — a function both runs kept can type on the primary and fail on the
// secondary, and importing that skip would move a proved charge to `[Unknown]`.

// `primary` whole, then every entry of `secondary` — expression, resolution,
// skip, or fn-typed signature — whose definition lies inside a span
// `primary.evidence.dropped` holds, and no other. `secondary_definitions` holds
// the span of every function the secondary run kept, by name, which is the
// identity the merge needs to place a name-keyed `fn_typed` entry inside or
// outside a hole.
//
// The merged `dropped` is the intersection: a definition both runs left out is
// still left out, and one the secondary run built is not. `unlocated` is the
// primary's alone — an unlocated skip names no span, so nothing can place it in
// a hole.
pub fn merge_readings(
  primary: ModuleReading,
  secondary: ModuleReading,
  secondary_definitions: Dict(String, #(Int, Int)),
) -> ModuleReading {
  let holes = set.to_list(primary.evidence.dropped)
  let primary_evidence = primary.evidence
  let secondary_evidence = secondary.evidence
  ModuleReading(
    expressions: fill(primary.expressions, secondary.expressions, holes),
    fn_typed: fill_fn_typed(
      primary.fn_typed,
      secondary.fn_typed,
      secondary_definitions,
      holes,
    ),
    evidence: ModuleEvidence(
      resolutions: fill(
        primary_evidence.resolutions,
        secondary_evidence.resolutions,
        holes,
      ),
      skipped: fill(primary_evidence.skipped, secondary_evidence.skipped, holes),
      unlocated: primary_evidence.unlocated,
      dropped: set.intersection(
        primary_evidence.dropped,
        secondary_evidence.dropped,
      ),
    ),
  )
}

// `primary` with every span-keyed entry of `secondary` that lies inside a hole
// and that `primary` does not already answer. A hole set is tiny — a handful of
// definitions per package at most — so membership is a scan rather than an
// index.
fn fill(
  primary: Dict(#(Int, Int), a),
  secondary: Dict(#(Int, Int), a),
  holes: List(#(Int, Int)),
) -> Dict(#(Int, Int), a) {
  dict.fold(secondary, primary, fn(acc, span, entry) {
    case dict.has_key(acc, span) || !inside_a_hole(span, holes) {
      True -> acc
      False -> dict.insert(acc, span, entry)
    }
  })
}

// The fn-typed map merged by the same rule, read through the secondary run's
// kept-definition spans: a name the primary lacks is imported only when the
// secondary's definition of that name lies inside a hole. The name-keyed map
// alone cannot say that, and importing a name from outside every hole would
// hand the bound synthesis evidence from the wrong run.
fn fill_fn_typed(
  primary: Dict(String, Set(String)),
  secondary: Dict(String, Set(String)),
  definitions: Dict(String, #(Int, Int)),
  holes: List(#(Int, Int)),
) -> Dict(String, Set(String)) {
  dict.fold(secondary, primary, fn(acc, name, params) {
    case dict.has_key(acc, name), dict.get(definitions, name) {
      False, Ok(span) ->
        case inside_a_hole(span, holes) {
          True -> dict.insert(acc, name, params)
          False -> acc
        }
      _, _ -> acc
    }
  })
}

// Whether a span lies within one of the primary run's dropped definitions.
fn inside_a_hole(span: #(Int, Int), holes: List(#(Int, Int))) -> Bool {
  list.any(holes, fn(hole) { span.0 >= hole.0 && span.1 <= hole.1 })
}

// girard's reading of one module: its resolutions, its skips and its dropped
// definitions. A module girard never saw yields three empty slices, which read
// as "no typed evidence" at every site rather than as an answer.
pub fn evidence_for_module(
  info: TypeInfo,
  module_path: String,
) -> ModuleEvidence {
  case dict.get(info.evidence, module_path) {
    Ok(module_evidence) -> module_evidence
    Error(Nil) -> no_evidence()
  }
}

// The fn-typed parameter names girard inferred for a single function, or an
// empty set if girard did not type it (fall back to syntactic detection).
pub fn fn_typed_params(
  module_fn_typed: Dict(String, Set(String)),
  function: String,
) -> Set(String) {
  case dict.get(module_fn_typed, function) {
    Ok(names) -> names
    Error(Nil) -> set.new()
  }
}

// The `#(defining module, type name)` of the expression spanning
// `#(start, end)`, if girard inferred it as a `Named` type (a record / custom
// type — exactly what the type-field registry is keyed by). The module
// qualifies the type so same-named types in different modules don't collide.
// `None` when the span is absent (girard skipped the enclosing function) or the
// expression is not a named type.
pub fn receiver_type(
  module_types: Dict(#(Int, Int), Type),
  start: Int,
  end: Int,
) -> Option(#(String, String)) {
  case type_at(module_types, start, end) {
    Some(Named(module, name, _arguments)) -> Some(#(module, name))
    _ -> None
  }
}

// girard's whole answer for the expression spanning `#(start, end)`, unreduced.
// `receiver_type` narrows it to the nominal identity the field registry is
// keyed by, which is what most readers want; this is for the one that has to
// tell "a type with no fields at all" apart from "no answer here".
pub fn type_at(
  module_types: Dict(#(Int, Int), Type),
  start: Int,
  end: Int,
) -> Option(Type) {
  case dict.get(module_types, #(start, end)) {
    Ok(type_) -> Some(type_)
    Error(Nil) -> None
  }
}

// The member girard resolved the reference spanning `#(start, end)` to. The key
// is the whole access — `x.label`, not the receiver and not the label — which
// is the span girard records the reference under. `None` when no reference was
// recorded there.
pub fn resolution_at(
  module_resolutions: Dict(#(Int, Int), Resolution),
  start: Int,
  end: Int,
) -> Option(Resolution) {
  case dict.get(module_resolutions, #(start, end)) {
    Ok(resolution) -> Some(resolution)
    Error(Nil) -> None
  }
}

// Where one declared definition stands in a run's reading. The three are
// exclusive and every definition of a module the run read is exactly one of
// them, so a count built from this cannot double-count or leave a definition
// out. A definition left out of every run was never walked, which is why it
// takes precedence over a skip.
pub type DefinitionStanding {
  LeftOut
  Skipped(bucket: String)
  Typed
}

// The standing of the definition occupying `location`.
pub fn standing_of(
  evidence: ModuleEvidence,
  location: glance.Span,
) -> DefinitionStanding {
  use <- bool.guard(
    is_dropped(evidence.dropped, location.start, location.end),
    LeftOut,
  )
  case skip_reason(evidence.skipped, location.start, location.end) {
    Some(bucket) -> Skipped(bucket)
    None -> Typed
  }
}

// The error bucket girard declined the definition spanning `#(start, end)`
// with, or `None` if it typed it. The span is the definition's own, the same
// key `is_dropped` reads, so one half of a `@target` pair being declined says
// nothing about the half beside it.
pub fn skip_reason(
  module_skipped: Dict(#(Int, Int), String),
  start: Int,
  end: Int,
) -> Option(String) {
  dict.get(module_skipped, #(start, end)) |> option.from_result()
}

// Whether girard left the definition spanning `#(start, end)` out of the build
// for the other target. The span is the definition's own — from its `pub`, `fn`
// or `const` keyword to its closing token — which is what tells the two halves
// of a `@target` pair apart where their name cannot.
pub fn is_dropped(
  module_dropped: Set(#(Int, Int)),
  start: Int,
  end: Int,
) -> Bool {
  set.contains(module_dropped, #(start, end))
}
