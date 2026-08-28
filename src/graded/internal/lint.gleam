// Spec-file lint.
//
// Every `.graded` line whose target resolves nothing, reported against the
// spec file rather than any source file: a `check` naming no project function,
// an `assume` covering a body sitting in plain sight or naming nothing at all,
// a field `assume` whose field cannot be called, a `where returns` clause its
// own line does not scope, an `effects` line whose path is not a function's.
// Such a line is silently dead, so it is surfaced as a warning.
//
// The pass reads a `Context` the caller assembles from the run it already
// performed. Dependency discovery arrives as thunks, not values: the walk they
// perform is the expensive part of the pass, and a spec holding none of the
// line kinds that ask a question of it never forces them.

import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded/internal/annotation
import graded/internal/checker
import graded/internal/effect_term
import graded/internal/effects
import graded/internal/signatures.{type SignatureRegistry}
import graded/internal/types.{
  type EffectAnnotation, type EffectTerm, type FieldAnnotation, type GradedFile,
  type QualifiedName, type Warning, AliasedBoundVariableWarning,
  DotlessReturnsClauseWarning, QualifiedName, StaleFunctionAssumeWarning,
  StaleReturnsClauseWarning, UnboundAssumeTermVariableWarning,
  UnclosedReturnsClauseWarning, UngroundReturnsClauseWarning,
  UnkeyedEffectsShapeWarning, UnknownClauseWarning, UnmatchedCheckWarning,
  UnmatchedFieldAssumeWarning, UnmatchedFunctionAssumeWarning,
  UnmatchedModuleAssumeWarning, UnmatchedReturnsClauseWarning,
  UnsupportedFieldCheckWarning,
}
import simplifile

// What one lint pass reads. Every field is something the run already
// assembled; the three closures are what the pass would otherwise reach into
// `graded` for.
pub type Context {
  Context(
    // The parsed spec file whose lines are linted, in the order it writes them.
    spec: GradedFile,
    // Every parsed project module, keyed by module path.
    index: Dict(String, #(String, glance.Module)),
    // The per-function `assume` lines that declare nothing, and the same about
    // their `where returns` clauses. Decided by the run that assembled the
    // knowledge base without them, so lint and loader cannot disagree about
    // which lines are live.
    stale_assumes: Set(String),
    stale_returns_clauses: Set(String),
    // The bundled catalog this project's knowledge base was assembled against,
    // so a line naming a catalogued function resolves as `check` resolves it.
    catalog: effects.BundledCatalog,
    // The oracle a `where returns` clause's variables are weighed against —
    // the same one the gate that binds them reads, so lint and gate agree by
    // construction.
    registry: SignatureRegistry,
    // What a dependency's own source says about one name. The lint's only read
    // of the dependency scan, so the scan's types stay where they are built.
    dependency_name: fn(QualifiedName) -> DependencyName,
    // Module path -> source file for every installed and path dependency, and
    // whether the tree that yielded them holds every package the manifest
    // lists. Thunks: each walks the dependency tree, and a spec with no
    // `assume`, declared-returns or field line asks neither question.
    dependency_files: fn() -> Dict(String, String),
    dependency_sources_are_complete: fn() -> Bool,
  )
}

// What a dependency's own source says about one name: the three answers the
// lint owes a `module.function` it did not find in this package.
pub type DependencyName {
  // The module's winning copy parsed and defines the function.
  DefinedByDependency
  // It parsed and defines no such function. The one answer that proves a name
  // absent.
  AbsentFromDependency
  // No source graded read says anything: the winning copy would not parse, or
  // the walk never reached the module. No evidence either way.
  UnreadDependency
}

// The module infos one pass consulted, keyed by module path. A module is
// parsed at most once per pass, failures included: the `Result` payload is
// what makes an unreadable or unparseable module a settled miss rather than a
// retry. Ephemeral — nothing keeps it past the pass.
pub type ModuleInfoMemo =
  Dict(String, Result(ModuleInfo, Nil))

// Where the classifier reads types from, and what it has read so far. The two
// sources never change across a pass and the memo does, so they travel
// together rather than as three arguments through a mutual recursion.
type Resolver {
  Resolver(
    index: Dict(String, #(String, glance.Module)),
    dep_files: Dict(String, String),
    memo: ModuleInfoMemo,
  )
}

// Flag `check`/`assume`/`effects` spec lines whose target resolves nothing. A
// `check` line names a function that must exist in some project module; a field
// `assume` line names a `module.Type.field` that must be a callable
// (function-typed) field; an `assume` line names foreign code, so it must name
// something graded cannot see the body of, and something that exists at all; an
// `effects` line names a function by shape, whatever it resolves to.
// When the qualifier is missing or wrong, the field plainly can't be called, or
// the declaration covers a body sitting in plain sight, the line is silently
// dead or silently ignored, so surface it as a warning.
// Every input is a field of the context the caller assembled, so it travels
// whole: a lint needing one more piece of it adds no parameter.
pub fn run(context: Context) -> List(Warning) {
  run_recording_lookups(context).0
}

// The same pass, handing back the module infos it consulted. The memo is what
// makes "parses at most once" a property a test can read rather than one it
// has to infer from timing; `run` is what every other caller wants.
pub fn run_recording_lookups(
  context: Context,
) -> #(List(Warning), ModuleInfoMemo) {
  let Context(
    spec:,
    index:,
    stale_assumes:,
    stale_returns_clauses:,
    registry:,
    ..,
  ) = context
  let known_functions = known_function_names(index)

  // One pass over the `check` lines, so the warnings come out in the order the
  // spec writes them. A field path is not a function name, so membership says
  // nothing about it and the whole line keys nothing. Anything else is a
  // function whose effects budget the run enforces, whether or not it carries a
  // clause: the name is weighed for a typo as usual, and the clause is flagged
  // on its own, since it is the only unverified part of such a line.
  let checks = annotation.extract_checks(spec)
  let check_warnings =
    checks
    |> list.flat_map(fn(ann) {
      case annotation.is_field_path(ann.function) {
        // A field path's own diagnostics belong to the pass that weighs its
        // construction sites, which is the only reader that knows whether the
        // field exists, is callable, and is built anywhere.
        True ->
          case unsupported_field_components(ann) {
            [] -> []
            components -> [
              UnsupportedFieldCheckWarning(name: ann.function, components:),
            ]
          }
        False ->
          case set.contains(known_functions, ann.function) {
            True -> []
            False -> [UnmatchedCheckWarning(function: ann.function)]
          }
      }
    })

  let assumes = annotation.extract_assumes(spec)
  let declared_returns = annotation.assume_returns(spec)
  let type_fields = annotation.extract_type_fields(spec)
  // Every lint here tells a dependency module from a typo, and the scan behind
  // that is the expensive part: walked once here and shared, and not at all for
  // a spec holding none of these line kinds.
  let dep_files = case assumes, declared_returns, type_fields {
    [], [], [] -> dict.new()
    _, _, _ -> context.dependency_files()
  }
  // The two declaring forms weigh a name by one rule, over one precomputation —
  // which reads the whole dependency tree, so it is built only where a
  // declaring line asks a question of it.
  let #(assume_warnings, returns_clause_warnings) = case
    assumes,
    declared_returns
  {
    [], [] -> #([], [])
    _, _ -> {
      let evidence = spec_name_evidence(known_functions, dep_files, context)
      #(
        assume_warnings(assumes, evidence, stale_assumes),
        returns_clause_warnings(
          declared_returns,
          evidence,
          stale_returns_clauses,
        ),
      )
    }
  }

  // The function assumes the existence channel just called dead — stale or
  // unmatched. The lints below skip them, so a line whose one warning says to
  // remove it gets no second piece of advice about its bound list. Derived
  // from that channel's own output, so the two gates cannot drift.
  let dead_assumes = dead_assume_names(assume_warnings)

  // Resolving field `assume` lines needs per-module type info, which the
  // resolver builds on demand and keeps: only the modules a field line names,
  // and whatever its alias chain reaches, are ever read.
  let #(type_field_warnings, resolver) = case type_fields {
    [] -> #([], Resolver(index:, dep_files:, memo: dict.new()))
    type_fields -> {
      let #(resolver, warnings) =
        list.map_fold(
          type_fields,
          Resolver(index:, dep_files:, memo: dict.new()),
          fn(resolver, tf) {
            let #(warning, resolver) =
              unmatched_type_field_warning(tf, resolver)
            #(resolver, warning)
          },
        )
      #(list.filter_map(warnings, fn(w) { w }), resolver)
    }
  }

  // A clause on an `effects` line is written by `infer` and closed by
  // construction, so one that is open was hand-edited or written by a future
  // bug. Reported all the same: the gate drops it silently. A `check` line's
  // clause is weighed against what the function returns, and an open one names
  // a variable nothing in the comparison can bind, so it is linted beside it.
  let effects_lines = annotation.extract_effects(spec)
  let clause_warnings =
    list.append(effects_lines, checks)
    |> list.filter_map(unclosed_clause_warning(_, registry))

  // Only a `module.function` path keys an `effects` line. The question goes to
  // the two readers that already answer it — `split_function_name`, which every
  // consumer of this tier goes through, and the field reader the `check` lint
  // above asks — rather than to a third classification of the same path. Both
  // are needed: the segment count alone reads `Handler.on_click`, the field
  // spelling whose module its type implies, as a function of a module named
  // `Handler`, and no Gleam module is named that. A dangling function path is
  // left alone on purpose: this tier is rewritten from source on every `infer`,
  // so a stale line is a line doing its job, while a field or module path is
  // one no run can key at all.
  let effects_shape_warnings =
    effects_lines
    |> list.filter_map(fn(ann) {
      case
        annotation.is_field_path(ann.function),
        annotation.split_function_name(ann.function)
      {
        False, Ok(_) -> Error(Nil)
        _, _ -> Ok(UnkeyedEffectsShapeWarning(name: ann.function))
      }
    })

  // A clause whose key this version does not read. Reported here rather than by
  // the parser, so a dependency's spec stays silent — its consumer cannot fix it
  // — and so the cache reader inherits that silence instead of a default nobody
  // chose. One warning per line, all its keys together.
  let unknown_clause_warnings =
    annotation.unknown_clause_lines(spec)
    |> list.map(fn(line) {
      let #(path, keys) = line
      UnknownClauseWarning(path:, keys:)
    })

  #(
    list.flatten([
      check_warnings,
      effects_shape_warnings,
      assume_warnings,
      unbound_term_variable_warnings(assumes, dead_assumes),
      aliased_bound_variable_warnings(
        assumes,
        list.append(effects_lines, checks),
        dead_assumes,
      ),
      returns_clause_warnings,
      clause_warnings,
      unknown_clause_warnings,
      type_field_warnings,
    ]),
    resolver.memo,
  )
}

// The term oracle over explicitly bounded `assume` lines: the declared effects
// term's variables are substitution keys, and call-site binding substitutes
// each bound's *payload* variables — so a term variable no payload covers can
// never bind, whatever the bound is named. Lint-only: resolution is already
// conservative about a leftover variable. Scoped to lines with a non-empty
// bound list — a boundless polymorphic assume resolves through
// registry-synthesized bounds and is left alone, and to lines the existence
// channel has not flagged — a stale or unmatched line's one fix is removal.
fn unbound_term_variable_warnings(
  assumes: List(types.AssumeAnnotation),
  dead: Set(String),
) -> List(Warning) {
  list.filter_map(assumes, fn(assume) {
    use <- bool.guard(when: assume.params == [], return: Error(Nil))
    case annotation.assume_qualified_name(assume), assume.effects {
      Ok(qualified), Some(effect_set) -> {
        use <- bool.guard(
          when: set.contains(dead, types.dotted_name(qualified)),
          return: Error(Nil),
        )
        let covered = effects.bound_payload_variables(assume.params)
        let unbound =
          declared_term_variables(Some(effect_set))
          |> set.filter(fn(variable) { !set.contains(covered, variable) })
          |> set.to_list
          |> list.sort(string.compare)
        case unbound {
          [] -> Error(Nil)
          free_vars ->
            Ok(UnboundAssumeTermVariableWarning(
              function: types.dotted_name(qualified),
              free_vars:,
            ))
        }
      }
      _, _ -> Error(Nil)
    }
  })
}

// The aliasing lint (see `effects.aliased_bound_variables`): a bound payload
// naming a *different* bound's parameter, on a line whose effects term or
// `where returns` clause uses that variable — the shape where the term
// channel (payload-keyed) and the clause channel (name-keyed) charge
// different arguments. Every bounded line carries two live channels — an
// `assume`, an `effects`, and a `check`, whose clause is weighed against the
// operator its function returns — so all three are linted. Lint-only: each
// channel's binding stays what it is. A machine-written self-referential list
// never aliases, so the shape is hand-written.
fn aliased_bound_variable_warnings(
  assumes: List(types.AssumeAnnotation),
  bounded_lines: List(EffectAnnotation),
  dead: Set(String),
) -> List(Warning) {
  let from_assumes =
    list.filter_map(assumes, fn(assume) {
      use qualified <- result.try(annotation.assume_qualified_name(assume))
      let function = types.dotted_name(qualified)
      use <- bool.guard(when: set.contains(dead, function), return: Error(Nil))
      aliased_bound_warning(
        function,
        assume.params,
        set.union(
          declared_term_variables(assume.effects),
          returns_variables(assume.returns),
        ),
      )
    })
  let from_lines =
    list.filter_map(bounded_lines, fn(ann) {
      aliased_bound_warning(
        ann.function,
        ann.params,
        set.union(
          effect_term.free_vars(ann.effects),
          returns_variables(ann.returns),
        ),
      )
    })
  list.append(from_assumes, from_lines)
}

// One line's aliasing warning: the collision pairs whose variable the line
// actually uses, `Error(Nil)` where none is used.
fn aliased_bound_warning(
  function: String,
  params: List(types.ParamBound),
  used: Set(String),
) -> Result(Warning, Nil) {
  let variables =
    effects.aliased_bound_variables(params)
    |> list.filter(fn(pair) { set.contains(used, pair.0) })
  case variables {
    [] -> Error(Nil)
    variables -> Ok(AliasedBoundVariableWarning(function:, variables:))
  }
}

// A clause's free variables, none where the line carries no clause.
fn returns_variables(returns: Option(EffectTerm)) -> Set(String) {
  case returns {
    Some(operator) -> effect_term.free_vars(operator)
    None -> set.new()
  }
}

// The variables an `assume` line's declared effects half names. The declared
// term is a flat set, so they are right on the `Polymorphic` variant — no term
// round-trip needed. A line with no effects half names none.
fn declared_term_variables(effects: Option(types.EffectSet)) -> Set(String) {
  case effects {
    Some(types.Polymorphic(_labels, variables)) -> variables
    Some(types.Specific(_)) | Some(types.Wildcard) | None -> set.new()
  }
}

// The components a field-path `check` carries that a field head gives no
// meaning: a bound list, since nothing scopes one on a field head, and a
// `where returns` clause, since nothing keys an operator returned by calling a
// field. Listed in the order the grammar writes them.
fn unsupported_field_components(
  annotation_line: EffectAnnotation,
) -> List(types.CheckComponent) {
  let bounds = case annotation_line.params {
    [] -> []
    [_, ..] -> [types.FieldBoundList]
  }
  let clause = case annotation_line.returns {
    None -> []
    Some(_) -> [types.FieldReturnsClause]
  }
  list.append(bounds, clause)
}

// The warning for one `effects` line's `where returns` clause, or `Error(Nil)`
// where it carries none, names nothing, or is closed.
//
// The line's own bound list is what scopes the clause, and the line is right
// here, so the lint weighs the clause against exactly what the gate weighs it
// against without consulting the knowledge base at all.
fn unclosed_clause_warning(
  annotation_line: EffectAnnotation,
  registry: SignatureRegistry,
) -> Result(Warning, Nil) {
  use operator <- result.try(option.to_result(annotation_line.returns, Nil))
  use #(module, function) <- result.try(annotation.split_function_name(
    annotation_line.function,
  ))
  case
    checker.unclosed_clause_variables(
      operator,
      QualifiedName(module, function),
      annotation_line.params,
      registry,
    )
  {
    [] -> Error(Nil)
    free_vars ->
      Ok(UnclosedReturnsClauseWarning(
        function: annotation_line.function,
        free_vars:,
      ))
  }
}

// What both declaring forms' lints weigh a name against, precomputed once over
// the catalog and the dependency scan and then asked per name. One rule, so an
// `assume` line and a `where returns` clause naming the same
// function are called dead together or not at all.
type SpecNameEvidence {
  SpecNameEvidence(
    // Whether anything graded can read defines the name.
    defines: fn(QualifiedName) -> Bool,
    // Whether the name's module was placed at all — or the dependency tree is
    // too incomplete for its absence to prove anything.
    module_placed: fn(String) -> Bool,
  )
}

// A dependency is weighed by the function, not by the module: graded holds that
// dependency's source, so `assume dep/io.typo` over a `dep/io` that
// defines only `writes` is as dead as one naming no module at all, and the
// module tier would wave every misspelling through. A module-level line has no
// function to weigh and is settled by the module alone.
//
// Existence only. A name that resolves but that graded cannot introspect is
// exactly what a declaring line is for, and is never flagged.
fn spec_name_evidence(
  known_functions: Set(String),
  dep_files: Dict(String, String),
  context: Context,
) -> SpecNameEvidence {
  let Context(index:, catalog:, ..) = context
  // The catalog the knowledge base was assembled from, selected against *this*
  // project's manifest — so a line naming a catalogued function of a package
  // this project depends on resolves exactly as `check` resolves it.
  let effects.BundledCatalog(
    functions: catalog_functions,
    modules: catalog_modules,
    ..,
  ) = catalog
  // A catalogued module is one the catalog *keys*, whether by a module-level
  // line or by the per-function lines that are the usual form: the stdlib
  // catalog holds `gleam/io.println` and no `gleam/io` line, so weighing module
  // existence by `catalog_modules` alone calls a real module a typo wherever
  // the dependency's own sources aren't installed to say otherwise.
  let catalog_function_modules =
    dict.fold(catalog_functions, set.new(), fn(acc, name, _entry) {
      set.insert(acc, name.module)
    })
  // Whether the tree the lint read is the whole of what this project depends
  // on. A module it cannot place is a typo only if there was nowhere left for
  // it to be: with a manifest package whose sources never turned up, the module
  // may be that package's, and no reading of what is on disk disproves it.
  let unplaceable_is_unknown = !context.dependency_sources_are_complete()
  // Whether something *outside* this package's own parsed source speaks for the
  // module: a dependency source the lint could read, or a catalog entry.
  let claimed = fn(module) {
    dict.has_key(dep_files, module)
    || dict.has_key(catalog_modules, module)
    || set.contains(catalog_function_modules, module)
  }
  // And whether anything at all does. Nothing here is what "unplaceable" means.
  let placed = fn(module) { dict.has_key(index, module) || claimed(module) }
  let defines = fn(qualified: QualifiedName) {
    // What answers for the name where no parsed source settles it: a module
    // something outside this package speaks for, a catalog entry for the exact
    // name, or a module the lint cannot place at all while the tree is missing
    // a package that could be holding it. A project module is *not* among them
    // — it was parsed, and `known_functions` is what it defines.
    let unparsed_answers =
      claimed(qualified.module)
      || dict.has_key(catalog_functions, qualified)
      || { unplaceable_is_unknown && !placed(qualified.module) }
    // The catalog is a stand-in for sources graded cannot read, so it is
    // weighed only where the dependency's own source says nothing: a parsed
    // module defines what it defines, and a name it provably lacks is a typo
    // whatever the catalog keys for the module. The lint flags what it can
    // prove dead, and silence is not proof.
    set.contains(known_functions, types.dotted_name(qualified))
    || case context.dependency_name(qualified) {
      DefinedByDependency -> True
      AbsentFromDependency -> False
      UnreadDependency -> unparsed_answers
    }
  }
  SpecNameEvidence(defines:, module_placed: fn(module) {
    placed(module) || unplaceable_is_unknown
  })
}

// One walk of the spec's `assume` lines, yielding the three ways such
// a line can be dead. Both tiers are covered, since a typo is as likely in the
// module name as in the function name:
//
//   - a per-function line naming one of *this package's* Gleam-bodied functions:
//     valid syntax, nothing foreign to declare, so it is ignored and the body
//     walked (see `stale_project_assumes`);
//   - a per-function line whose `module.function` resolves nowhere at all —
//     dependency, catalog, or project index;
//   - a module-level line whose module is neither a dependency nor a project
//     module.
fn assume_warnings(
  assumes: List(types.AssumeAnnotation),
  evidence: SpecNameEvidence,
  stale: Set(String),
) -> List(Warning) {
  assumes
  // A line carrying only a `where returns` clause claims nothing on this
  // channel, so this channel has nothing to call dead about it.
  |> list.filter(fn(assume) { assume.effects != option.None })
  |> list.filter_map(fn(assume) {
    case annotation.assume_qualified_name(assume) {
      Ok(qualified) -> {
        let name = types.dotted_name(qualified)
        case set.contains(stale, name), evidence.defines(qualified) {
          True, _ -> Ok(StaleFunctionAssumeWarning(function: name))
          False, False -> Ok(UnmatchedFunctionAssumeWarning(function: name))
          False, True -> Error(Nil)
        }
      }
      Error(Nil) ->
        case evidence.module_placed(assume.module) {
          True -> Error(Nil)
          False -> Ok(UnmatchedModuleAssumeWarning(module: assume.module))
        }
    }
  })
}

// The function names the existence channel's warnings call dead — a stale
// declaration over a visible body, or one matching nothing anywhere.
fn dead_assume_names(warnings: List(Warning)) -> Set(String) {
  list.filter_map(warnings, fn(warning) {
    case warning {
      StaleFunctionAssumeWarning(function:)
      | UnmatchedFunctionAssumeWarning(function:) -> Ok(function)
      _ -> Error(Nil)
    }
  })
  |> set.from_list()
}

// The same walk over the `where returns` clauses on the spec's `assume` lines,
// yielding the ways one can be dead. Two are the existence branches above, read
// through the same evidence; two are this channel's own, and both are clauses
// the loader drops:
//
//   - a clause on a module path, where nothing keys a whole module's returned
//     value;
//   - a polymorphic operator, whose free variables nothing sanitized.
//
// One warning per clause, so a clause that is dead twice over is reported by
// the first rule that catches it.
fn returns_clause_warnings(
  declared: List(#(types.AssumeAnnotation, EffectTerm)),
  evidence: SpecNameEvidence,
  stale: Set(String),
) -> List(Warning) {
  list.filter_map(declared, fn(entry) {
    let #(assume, operator) = entry
    case annotation.assume_qualified_name(assume) {
      Error(Nil) -> Ok(DotlessReturnsClauseWarning(name: assume.module))
      Ok(qualified) -> {
        let name = types.dotted_name(qualified)
        // The unscoped variables, listed once and by the same base predicate
        // the loader and the gate read: emptiness is what admits the clause,
        // so the same list decides the branch and names it.
        let open = effects.unscoped_clause_variables(operator, assume.params)
        case set.contains(stale, name), evidence.defines(qualified), open {
          True, _, _ -> Ok(StaleReturnsClauseWarning(function: name))
          False, False, _ -> Ok(UnmatchedReturnsClauseWarning(function: name))
          False, True, [] -> Error(Nil)
          False, True, free_vars ->
            Ok(UngroundReturnsClauseWarning(function: name, free_vars:))
        }
      }
    }
  })
}

// A warning for a field `assume` line that resolves nothing, or `Error(Nil)` when the
// line is a valid target. Cases:
//   - unqualified (`type Type.field`): no module to key a receiver's resolved
//     type, so it's always dead;
//   - qualified at a *project* module: dead when the type/field doesn't exist,
//     or the field's declared type plainly can't be called (a record, a scalar,
//     a tuple). A field whose type can't be resolved (an unintrospectable
//     dependency) is left alone rather than flagged;
//   - qualified at a *dependency* module: left alone — the receiver type is the
//     dependency's, which girard resolves; graded doesn't second-guess it;
//   - qualified at an unknown module (neither project nor dependency): a typo,
//     so it's dead and flagged.
fn unmatched_type_field_warning(
  tf: FieldAnnotation,
  resolver: Resolver,
) -> #(Result(Warning, Nil), Resolver) {
  let #(dead, resolver) = case tf.module {
    None -> #(True, resolver)
    Some(module) -> {
      let #(valid, resolver) = valid_type_field(module, tf, resolver)
      #(!valid, resolver)
    }
  }
  case dead {
    False -> #(Error(Nil), resolver)
    True -> #(
      Ok(UnmatchedFieldAssumeWarning(name: annotation.type_field_path(tf))),
      resolver,
    )
  }
}

// Whether a qualified field `assume` line is an accepted target. A project type's field
// must exist and not plainly be non-callable (`Callable`/`Unknown` pass, so an
// unintrospectable field type is never false-flagged). A dependency-owned type
// passes untouched; any other module is a typo.
fn valid_type_field(
  module: String,
  tf: FieldAnnotation,
  resolver: Resolver,
) -> #(Bool, Resolver) {
  case dict.get(resolver.index, module) {
    Ok(#(_gleam_path, mod)) ->
      case lookup_labelled_field(mod, tf.type_name, tf.field) {
        Ok(field_type) -> {
          let #(callable, resolver) =
            classify_field_type(field_type, module, set.new(), resolver)
          #(callable != NotCallable, resolver)
        }
        Error(Nil) -> #(False, resolver)
      }
    Error(Nil) -> #(dict.has_key(resolver.dep_files, module), resolver)
  }
}

// Every `module.function` defined across the project (public and private), the
// set a `check` line's qualified name must belong to.
fn known_function_names(
  index: Dict(String, #(String, glance.Module)),
) -> Set(String) {
  dict.fold(index, set.new(), fn(acc, module_path, entry) {
    let #(_gleam_path, module) = entry
    list.fold(module.functions, acc, fn(acc2, definition) {
      set.insert(acc2, module_path <> "." <> definition.definition.name)
    })
  })
}

// The labelled field `field` of custom type `type_name` in `module`, or
// `Error` when no such type or labelled field exists.
fn lookup_labelled_field(
  module: glance.Module,
  type_name: String,
  field: String,
) -> Result(glance.Type, Nil) {
  use definition <- result.try(
    list.find(module.custom_types, fn(d) { d.definition.name == type_name }),
  )
  list.find_map(definition.definition.variants, fn(variant) {
    list.find_map(variant.fields, fn(f) {
      case f {
        glance.LabelledVariantField(label:, item:) if label == field -> Ok(item)
        _ -> Error(Nil)
      }
    })
  })
}

// The type-resolution surface graded can read for one module: its type aliases,
// its own custom-type names, and the two ways another module's type can be
// referenced — qualified (import alias -> module path) and unqualified
// (imported type's local name -> #(module path, original name)).
pub type ModuleInfo {
  ModuleInfo(
    aliases: Dict(String, glance.Type),
    custom_types: Set(String),
    qualified_imports: Dict(String, String),
    unqualified_types: Dict(String, #(String, String)),
  )
}

// Whether a field's declared type can be called. Three-valued so the lint flags
// only what it can prove is non-callable, never guessing on a type it can't
// resolve.
type Callable {
  Callable
  NotCallable
  UnknownCallable
}

fn module_info_from_glance(module: glance.Module) -> ModuleInfo {
  let aliases =
    list.fold(module.type_aliases, dict.new(), fn(acc, definition) {
      dict.insert(
        acc,
        definition.definition.name,
        definition.definition.aliased,
      )
    })
  let custom_types =
    list.fold(module.custom_types, set.new(), fn(acc, definition) {
      set.insert(acc, definition.definition.name)
    })
  let #(qualified_imports, unqualified_types) =
    list.fold(module.imports, #(dict.new(), dict.new()), fn(acc, definition) {
      let #(quals, unquals) = acc
      let import_ = definition.definition
      let alias = case import_.alias {
        Some(glance.Named(name)) -> name
        _ -> last_segment(import_.module)
      }
      let unquals =
        list.fold(import_.unqualified_types, unquals, fn(u, unqualified) {
          let local = case unqualified.alias {
            Some(a) -> a
            None -> unqualified.name
          }
          dict.insert(u, local, #(import_.module, unqualified.name))
        })
      #(dict.insert(quals, alias, import_.module), unquals)
    })
  ModuleInfo(aliases:, custom_types:, qualified_imports:, unqualified_types:)
}

fn last_segment(module_path: String) -> String {
  module_path |> string.split("/") |> list.last() |> result.unwrap(module_path)
}

// Resolve a module's introspectable type info: a project module from the index,
// or a dependency module parsed from its source on demand. `Error` when neither
// is available (an uninstalled or otherwise unreadable module).
fn lookup_module_info(
  module_path: String,
  resolver: Resolver,
) -> #(Result(ModuleInfo, Nil), Resolver) {
  case dict.get(resolver.memo, module_path) {
    Ok(cached) -> #(cached, resolver)
    Error(Nil) -> {
      let info = case dict.get(resolver.index, module_path) {
        Ok(#(_gleam_path, module)) -> Ok(module_info_from_glance(module))
        Error(Nil) -> {
          use file <- result.try(dict.get(resolver.dep_files, module_path))
          use source <- result.try(
            simplifile.read(file) |> result.replace_error(Nil),
          )
          use module <- result.try(
            glance.module(source) |> result.replace_error(Nil),
          )
          Ok(module_info_from_glance(module))
        }
      }
      #(
        info,
        Resolver(
          ..resolver,
          memo: dict.insert(resolver.memo, module_path, info),
        ),
      )
    }
  }
}

// Whether `type_`, declared in `module_path`, is a callable function type —
// following alias chains across project and dependency modules. `seen` guards
// against alias cycles. A type graded can't introspect resolves to `Unknown`,
// never `NotCallable`, so the lint won't false-flag it.
fn classify_field_type(
  type_: glance.Type,
  module_path: String,
  seen: Set(String),
  resolver: Resolver,
) -> #(Callable, Resolver) {
  case type_ {
    glance.FunctionType(..) -> #(Callable, resolver)
    glance.NamedType(name:, module: None, ..) ->
      classify_named_type(name, module_path, seen, resolver)
    glance.NamedType(name:, module: Some(qualifier), ..) -> {
      let #(info, resolver) = lookup_module_info(module_path, resolver)
      case info {
        Ok(info) ->
          case dict.get(info.qualified_imports, qualifier) {
            Ok(real_module) ->
              classify_named_type(name, real_module, seen, resolver)
            Error(Nil) -> #(UnknownCallable, resolver)
          }
        Error(Nil) -> #(UnknownCallable, resolver)
      }
    }
    // A type variable could be instantiated to a function; don't flag it.
    glance.VariableType(..) -> #(UnknownCallable, resolver)
    // Tuples and holes are never callable.
    _ -> #(NotCallable, resolver)
  }
}

// Classify a bare type name (`module: None`) as seen from `module_path`: a local
// alias is followed, a local custom type is non-callable, an unqualified import
// is chased to its defining module, and anything else is a prelude/builtin type
// (none of which is callable).
fn classify_named_type(
  name: String,
  module_path: String,
  seen: Set(String),
  resolver: Resolver,
) -> #(Callable, Resolver) {
  let key = module_path <> "." <> name
  use <- bool.lazy_guard(when: set.contains(seen, key), return: fn() {
    #(UnknownCallable, resolver)
  })
  let #(info, resolver) = lookup_module_info(module_path, resolver)
  case info {
    Error(Nil) -> #(UnknownCallable, resolver)
    Ok(info) ->
      classify_in_module(
        name,
        module_path,
        info,
        set.insert(seen, key),
        resolver,
      )
  }
}

// `name` resolved within `info` (the module that defines or imports it): a local
// alias is followed, a local custom type is non-callable, and an unqualified
// import is chased to its source. Anything else is a prelude/builtin type.
fn classify_in_module(
  name: String,
  module_path: String,
  info: ModuleInfo,
  seen: Set(String),
  resolver: Resolver,
) -> #(Callable, Resolver) {
  case dict.get(info.aliases, name) {
    Ok(aliased) -> classify_field_type(aliased, module_path, seen, resolver)
    Error(Nil) ->
      case
        set.contains(info.custom_types, name),
        dict.get(info.unqualified_types, name)
      {
        True, _ -> #(NotCallable, resolver)
        False, Ok(#(real_module, original)) ->
          classify_named_type(original, real_module, seen, resolver)
        False, Error(Nil) -> #(NotCallable, resolver)
      }
  }
}
