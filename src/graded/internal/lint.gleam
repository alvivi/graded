// Spec-file lint.
//
// Every `.graded` line whose target resolves nothing, reported against the
// spec file rather than any source file: a `check` naming no project function,
// an `assume` covering a body sitting in plain sight or naming nothing at all,
// a field `assume` whose field cannot be called, a `where returns` clause its
// own line does not scope. Such a line is silently dead, so it is surfaced as
// a warning.
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
  type EffectAnnotation, type EffectTerm, type GradedFile, type QualifiedName,
  type TypeFieldAnnotation, type Warning, AliasedBoundVariableWarning,
  DotlessReturnsClauseWarning, QualifiedName, StaleFunctionExternalWarning,
  StaleReturnsClauseWarning, UnboundExternalTermVariableWarning,
  UnclosedReturnsClauseWarning, UngroundReturnsClauseWarning,
  UnknownClauseWarning, UnmatchedCheckWarning, UnmatchedFunctionExternalWarning,
  UnmatchedModuleExternalWarning, UnmatchedReturnsClauseWarning,
  UnmatchedTypeFieldWarning, UnverifiedCheckShapeWarning,
  UnverifiedReturnsClauseWarning,
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
    stale_externals: Set(String),
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

// Flag `check`/`type`/`external` spec lines whose target resolves nothing. A
// `check` line names a function that must exist in some project module; a `type`
// line names a `module.Type.field` that must be a callable (function-typed)
// field; an `assume` line names foreign code, so it must name
// something graded cannot see the body of, and something that exists at all.
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
    stale_externals:,
    stale_returns_clauses:,
    catalog:,
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
  let check_warnings =
    annotation.extract_checks(spec)
    |> list.flat_map(fn(ann) {
      case annotation.is_field_path(ann.function) {
        True -> [UnverifiedCheckShapeWarning(name: ann.function)]
        False -> {
          let unmatched = case set.contains(known_functions, ann.function) {
            True -> []
            False -> [UnmatchedCheckWarning(function: ann.function)]
          }
          case ann.returns {
            None -> unmatched
            Some(_) ->
              list.append(unmatched, [
                UnverifiedReturnsClauseWarning(function: ann.function),
              ])
          }
        }
      }
    })

  let externals = annotation.extract_externals(spec)
  let declared_returns = annotation.assume_returns(spec)
  let type_fields = annotation.extract_type_fields(spec)
  // Every lint here tells a dependency module from a typo, and the scan behind
  // that is the expensive part: walked once here and shared, and not at all for
  // a spec holding none of these line kinds.
  let dep_files = case externals, declared_returns, type_fields {
    [], [], [] -> dict.new()
    _, _, _ -> context.dependency_files()
  }
  let dep_modules = set.from_list(dict.keys(dep_files))

  // The two declaring forms weigh a name by one rule, over one precomputation —
  // which reads the whole dependency tree, so it is built only where a
  // declaring line asks a question of it.
  let #(external_warnings, returns_clause_warnings) = case
    externals,
    declared_returns
  {
    [], [] -> #([], [])
    _, _ -> {
      let evidence =
        spec_name_evidence(index, known_functions, dep_files, catalog, context)
      #(
        external_warnings(externals, evidence, stale_externals),
        returns_clause_warnings(
          declared_returns,
          evidence,
          stale_returns_clauses,
        ),
      )
    }
  }

  // The function externals the existence channel just called dead — stale or
  // unmatched. The lints below skip them, so a line whose one warning says to
  // remove it gets no second piece of advice about its bound list. Derived
  // from that channel's own output, so the two gates cannot drift.
  let dead_externals = dead_external_names(external_warnings)

  // Resolving field `assume` lines also needs per-module type info; build it only when
  // there are field `assume` lines to check.
  let #(type_field_warnings, memo) = case type_fields {
    [] -> #([], dict.new())
    type_fields -> {
      let project_infos = project_module_infos(index)
      let #(memo, warnings) =
        list.map_fold(type_fields, dict.new(), fn(memo, tf) {
          let #(warning, memo) =
            unmatched_type_field_warning(
              tf,
              index,
              dep_modules,
              project_infos,
              dep_files,
              memo,
            )
          #(memo, warning)
        })
      #(list.filter_map(warnings, fn(w) { w }), memo)
    }
  }

  // A clause on an `effects` line is written by `infer` and closed by
  // construction, so one that is open was hand-edited or written by a future
  // bug. Reported all the same: the gate drops it silently.
  let effects_lines = annotation.extract_effects(spec)
  let clause_warnings =
    effects_lines
    |> list.filter_map(unclosed_clause_warning(_, registry))

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
      external_warnings,
      unbound_term_variable_warnings(externals, dead_externals),
      aliased_bound_variable_warnings(externals, effects_lines, dead_externals),
      returns_clause_warnings,
      clause_warnings,
      unknown_clause_warnings,
      type_field_warnings,
    ]),
    memo,
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
  externals: List(types.ExternalAnnotation),
  dead: Set(String),
) -> List(Warning) {
  list.filter_map(externals, fn(external) {
    use <- bool.guard(when: external.params == [], return: Error(Nil))
    case annotation.external_qualified_name(external), external.effects {
      Ok(qualified), Some(effect_set) -> {
        use <- bool.guard(
          when: set.contains(dead, types.dotted_name(qualified)),
          return: Error(Nil),
        )
        let covered = effects.bound_payload_variables(external.params)
        // The declared term is a flat set, so its variables are right on the
        // `Polymorphic` variant — no term round-trip needed.
        let term_variables = case effect_set {
          types.Polymorphic(_labels, variables) -> variables
          types.Specific(_) | types.Wildcard -> set.new()
        }
        let unbound =
          term_variables
          |> set.filter(fn(variable) { !set.contains(covered, variable) })
          |> set.to_list
          |> list.sort(string.compare)
        case unbound {
          [] -> Error(Nil)
          free_vars ->
            Ok(UnboundExternalTermVariableWarning(
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
// different arguments. Bounded `assume` lines and `effects` lines alike,
// since both carry two live channels; a `check` line's clause is never
// weighed, so its one live channel cannot disagree with itself. Lint-only:
// each channel's binding stays what it is. A machine-written
// self-referential list never aliases, so the shape is hand-written.
fn aliased_bound_variable_warnings(
  externals: List(types.ExternalAnnotation),
  effects_lines: List(EffectAnnotation),
  dead: Set(String),
) -> List(Warning) {
  let from_externals =
    list.filter_map(externals, fn(external) {
      use qualified <- result.try(annotation.external_qualified_name(external))
      let function = types.dotted_name(qualified)
      use <- bool.guard(when: set.contains(dead, function), return: Error(Nil))
      let term_variables = case external.effects {
        Some(types.Polymorphic(_labels, variables)) -> variables
        Some(types.Specific(_)) | Some(types.Wildcard) | None -> set.new()
      }
      aliased_bound_warning(
        function,
        external.params,
        set.union(term_variables, returns_variables(external.returns)),
      )
    })
  let from_effects =
    list.filter_map(effects_lines, fn(ann) {
      aliased_bound_warning(
        ann.function,
        ann.params,
        set.union(
          effect_term.free_vars(ann.effects),
          returns_variables(ann.returns),
        ),
      )
    })
  list.append(from_externals, from_effects)
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
  index: Dict(String, #(String, glance.Module)),
  known_functions: Set(String),
  dep_files: Dict(String, String),
  catalog: effects.BundledCatalog,
  context: Context,
) -> SpecNameEvidence {
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
//     walked (see `stale_project_externals`);
//   - a per-function line whose `module.function` resolves nowhere at all —
//     dependency, catalog, or project index;
//   - a module-level line whose module is neither a dependency nor a project
//     module.
fn external_warnings(
  externals: List(types.ExternalAnnotation),
  evidence: SpecNameEvidence,
  stale: Set(String),
) -> List(Warning) {
  externals
  // A line carrying only a `where returns` clause claims nothing on this
  // channel, so this channel has nothing to call dead about it.
  |> list.filter(fn(external) { external.effects != option.None })
  |> list.filter_map(fn(external) {
    case annotation.external_qualified_name(external) {
      Ok(qualified) -> {
        let name = types.dotted_name(qualified)
        case set.contains(stale, name), evidence.defines(qualified) {
          True, _ -> Ok(StaleFunctionExternalWarning(function: name))
          False, False -> Ok(UnmatchedFunctionExternalWarning(function: name))
          False, True -> Error(Nil)
        }
      }
      Error(Nil) ->
        case evidence.module_placed(external.module) {
          True -> Error(Nil)
          False -> Ok(UnmatchedModuleExternalWarning(module: external.module))
        }
    }
  })
}

// The function names the existence channel's warnings call dead — a stale
// declaration over a visible body, or one matching nothing anywhere.
fn dead_external_names(warnings: List(Warning)) -> Set(String) {
  list.filter_map(warnings, fn(warning) {
    case warning {
      StaleFunctionExternalWarning(function:)
      | UnmatchedFunctionExternalWarning(function:) -> Ok(function)
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
  declared: List(#(types.ExternalAnnotation, EffectTerm)),
  evidence: SpecNameEvidence,
  stale: Set(String),
) -> List(Warning) {
  list.filter_map(declared, fn(entry) {
    let #(external, operator) = entry
    case annotation.external_qualified_name(external) {
      Error(Nil) -> Ok(DotlessReturnsClauseWarning(name: external.module))
      Ok(qualified) -> {
        let name = types.dotted_name(qualified)
        // The unscoped variables, listed once and by the same base predicate
        // the loader and the gate read: emptiness is what admits the clause,
        // so the same list decides the branch and names it.
        let open = effects.unscoped_clause_variables(operator, external.params)
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
  tf: TypeFieldAnnotation,
  index: Dict(String, #(String, glance.Module)),
  dep_modules: Set(String),
  project_infos: Dict(String, ModuleInfo),
  dep_files: Dict(String, String),
  memo: ModuleInfoMemo,
) -> #(Result(Warning, Nil), ModuleInfoMemo) {
  let #(dead, memo) = case tf.module {
    None -> #(True, memo)
    Some(module) -> {
      let #(valid, memo) =
        valid_type_field(
          module,
          tf,
          index,
          dep_modules,
          project_infos,
          dep_files,
          memo,
        )
      #(!valid, memo)
    }
  }
  case dead {
    False -> #(Error(Nil), memo)
    True -> #(
      Ok(UnmatchedTypeFieldWarning(name: annotation.type_field_path(tf))),
      memo,
    )
  }
}

// Whether a qualified field `assume` line is an accepted target. A project type's field
// must exist and not plainly be non-callable (`Callable`/`Unknown` pass, so an
// unintrospectable field type is never false-flagged). A dependency-owned type
// passes untouched; any other module is a typo.
fn valid_type_field(
  module: String,
  tf: TypeFieldAnnotation,
  index: Dict(String, #(String, glance.Module)),
  dep_modules: Set(String),
  project_infos: Dict(String, ModuleInfo),
  dep_files: Dict(String, String),
  memo: ModuleInfoMemo,
) -> #(Bool, ModuleInfoMemo) {
  case dict.get(index, module) {
    Ok(#(_gleam_path, mod)) ->
      case lookup_labelled_field(mod, tf.type_name, tf.field) {
        Ok(field_type) -> {
          let #(callable, memo) =
            classify_field_type(
              field_type,
              module,
              project_infos,
              dep_files,
              set.new(),
              memo,
            )
          #(callable != NotCallable, memo)
        }
        Error(Nil) -> #(False, memo)
      }
    Error(Nil) -> #(set.contains(dep_modules, module), memo)
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
pub type Callable {
  Callable
  NotCallable
  UnknownCallable
}

fn project_module_infos(
  index: Dict(String, #(String, glance.Module)),
) -> Dict(String, ModuleInfo) {
  dict.map_values(index, fn(_module_path, entry) {
    let #(_gleam_path, module) = entry
    module_info_from_glance(module)
  })
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
  project_infos: Dict(String, ModuleInfo),
  dep_files: Dict(String, String),
  memo: ModuleInfoMemo,
) -> #(Result(ModuleInfo, Nil), ModuleInfoMemo) {
  case dict.get(memo, module_path) {
    Ok(cached) -> #(cached, memo)
    Error(Nil) -> {
      let info = case dict.get(project_infos, module_path) {
        Ok(info) -> Ok(info)
        Error(Nil) -> {
          use file <- result.try(dict.get(dep_files, module_path))
          use source <- result.try(
            simplifile.read(file) |> result.replace_error(Nil),
          )
          use module <- result.try(
            glance.module(source) |> result.replace_error(Nil),
          )
          Ok(module_info_from_glance(module))
        }
      }
      #(info, dict.insert(memo, module_path, info))
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
  project_infos: Dict(String, ModuleInfo),
  dep_files: Dict(String, String),
  seen: Set(String),
  memo: ModuleInfoMemo,
) -> #(Callable, ModuleInfoMemo) {
  case type_ {
    glance.FunctionType(..) -> #(Callable, memo)
    glance.NamedType(name:, module: None, ..) ->
      classify_named_type(
        name,
        module_path,
        project_infos,
        dep_files,
        seen,
        memo,
      )
    glance.NamedType(name:, module: Some(qualifier), ..) -> {
      let #(info, memo) =
        lookup_module_info(module_path, project_infos, dep_files, memo)
      case info {
        Ok(info) ->
          case dict.get(info.qualified_imports, qualifier) {
            Ok(real_module) ->
              classify_named_type(
                name,
                real_module,
                project_infos,
                dep_files,
                seen,
                memo,
              )
            Error(Nil) -> #(UnknownCallable, memo)
          }
        Error(Nil) -> #(UnknownCallable, memo)
      }
    }
    // A type variable could be instantiated to a function; don't flag it.
    glance.VariableType(..) -> #(UnknownCallable, memo)
    // Tuples and holes are never callable.
    _ -> #(NotCallable, memo)
  }
}

// Classify a bare type name (`module: None`) as seen from `module_path`: a local
// alias is followed, a local custom type is non-callable, an unqualified import
// is chased to its defining module, and anything else is a prelude/builtin type
// (none of which is callable).
fn classify_named_type(
  name: String,
  module_path: String,
  project_infos: Dict(String, ModuleInfo),
  dep_files: Dict(String, String),
  seen: Set(String),
  memo: ModuleInfoMemo,
) -> #(Callable, ModuleInfoMemo) {
  let key = module_path <> "." <> name
  use <- bool.lazy_guard(when: set.contains(seen, key), return: fn() {
    #(UnknownCallable, memo)
  })
  let #(info, memo) =
    lookup_module_info(module_path, project_infos, dep_files, memo)
  case info {
    Error(Nil) -> #(UnknownCallable, memo)
    Ok(info) ->
      classify_in_module(
        name,
        module_path,
        info,
        project_infos,
        dep_files,
        set.insert(seen, key),
        memo,
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
  project_infos: Dict(String, ModuleInfo),
  dep_files: Dict(String, String),
  seen: Set(String),
  memo: ModuleInfoMemo,
) -> #(Callable, ModuleInfoMemo) {
  case dict.get(info.aliases, name) {
    Ok(aliased) ->
      classify_field_type(
        aliased,
        module_path,
        project_infos,
        dep_files,
        seen,
        memo,
      )
    Error(Nil) ->
      case
        set.contains(info.custom_types, name),
        dict.get(info.unqualified_types, name)
      {
        True, _ -> #(NotCallable, memo)
        False, Ok(#(real_module, original)) ->
          classify_named_type(
            original,
            real_module,
            project_infos,
            dep_files,
            seen,
            memo,
          )
        False, Error(Nil) -> #(NotCallable, memo)
      }
  }
}
