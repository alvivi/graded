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
// Beside the types, girard's own reading of each reference is retained: which
// member a field access or a bare callee resolved to, which definitions it
// declined to type, and which it left out for the other build target. Those
// three answer the same question from girard's side that the checker answers
// from its own, and they are kept whole rather than reduced, so the two can be
// compared per site.

import girard.{type Error, type Resolution, type Type, Named}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}

// Inferred information for a whole package:
// - `by_module`: module path -> (expression `#(start, end)` span -> type).
// - `fn_typed`: module path -> (function name -> the set of its function-typed
//   parameter names, inferred from girard's signature — covers params with no
//   syntactic `fn(...)` annotation).
// - `evidence`: module path -> girard's own reading of that module.
pub type TypeInfo {
  TypeInfo(
    by_module: Dict(String, Dict(#(Int, Int), Type)),
    fn_typed: Dict(String, Dict(String, Set(String))),
    evidence: Dict(String, ModuleEvidence),
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
// The drops are keyed by the definition's `#(start, end)` span rather than by
// its name: a `@target(erlang)` and a `@target(javascript)` definition share one
// name, and only one of the two is left out of the build.
pub type ModuleEvidence {
  ModuleEvidence(
    resolutions: Dict(#(Int, Int), Resolution),
    skipped: Dict(String, String),
    dropped: Set(#(Int, Int)),
  )
}

// The empty reading — girard said nothing about this module, so every site in it
// reads as "no typed evidence" rather than as an answer. What
// `evidence_for_module` gives for a module girard never saw.
pub fn no_evidence() -> ModuleEvidence {
  ModuleEvidence(dict.new(), dict.new(), set.new())
}

// girard's reading of one module, folded out of its annotation result.
// `skip_bucket` reduces an error to the stable bucket the reading keeps.
pub fn evidence_of(
  result: girard.ModuleResult,
  skip_bucket: fn(Error) -> String,
) -> ModuleEvidence {
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
    skipped: list.fold(result.skipped, dict.new(), fn(acc, entry) {
      dict.insert(acc, entry.0, skip_bucket(entry.1))
    }),
    dropped: list.fold(result.annotated.dropped, set.new(), fn(acc, definition) {
      set.insert(acc, #(definition.span.start, definition.span.end))
    }),
  )
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
  TypeInfo(dict.new(), dict.new(), dict.new())
}

// Build a `TypeInfo` from per-module span->type maps, per-module
// function->fn-typed-params maps, and girard's per-module readings.
pub fn from_modules(
  types_modules: List(#(String, Dict(#(Int, Int), Type))),
  fn_typed_modules: List(#(String, Dict(String, Set(String)))),
  evidence_modules: List(#(String, ModuleEvidence)),
) -> TypeInfo {
  TypeInfo(
    by_module: dict.from_list(types_modules),
    fn_typed: dict.from_list(fn_typed_modules),
    evidence: dict.from_list(evidence_modules),
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

// The error bucket girard declined `function` with, or `None` if it typed it.
pub fn skip_reason(
  module_skipped: Dict(String, String),
  function: String,
) -> Option(String) {
  case dict.get(module_skipped, function) {
    Ok(error) -> Some(error)
    Error(Nil) -> None
  }
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
