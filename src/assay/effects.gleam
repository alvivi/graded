import assay/annotation
import assay/types.{type QualifiedName, Effects, QualifiedName}
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile

pub type EffectLookup {
  Known(Set(String))
  Unknown
}

/// Bundles all effect knowledge: dependency + catalog, precomputed for fast lookup.
pub type KnowledgeBase {
  KnowledgeBase(
    all_effects: Dict(QualifiedName, Set(String)),
    pure_modules: Set(String),
  )
}

/// Build a knowledge base by scanning dependency .assay files,
/// merged with the hardcoded catalog.
pub fn load_knowledge_base(packages_directory: String) -> KnowledgeBase {
  let dependency = load_dependency_effects(packages_directory)
  let catalog = catalog_effectful_functions()
  let merged = dict.merge(dependency, catalog)
  KnowledgeBase(all_effects: merged, pure_modules: catalog_pure_modules())
}

/// Build a knowledge base from the hardcoded catalog only.
pub fn empty_knowledge_base() -> KnowledgeBase {
  KnowledgeBase(
    all_effects: catalog_effectful_functions(),
    pure_modules: catalog_pure_modules(),
  )
}

/// Look up the effect set for a qualified function name.
pub fn lookup(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> EffectLookup {
  case dict.get(knowledge_base.all_effects, name) {
    Ok(effect_set) -> Known(effect_set)
    Error(Nil) ->
      case set.contains(knowledge_base.pure_modules, name.module) {
        True -> Known(set.new())
        False -> Unknown
      }
  }
}

/// Look up effects, returning [Unknown] for unrecognized functions.
pub fn lookup_effects(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Set(String) {
  case lookup(knowledge_base, name) {
    Known(effect_set) -> effect_set
    Unknown -> set.from_list(["Unknown"])
  }
}

/// Format an effect set for display: [] for empty, [A, B] sorted.
pub fn format_effect_set(effect_set: Set(String)) -> String {
  case set.to_list(effect_set) |> list.sort(string.compare) {
    [] -> "[]"
    labels -> "[" <> string.join(labels, ", ") <> "]"
  }
}

// PRIVATE

fn load_dependency_effects(
  packages_directory: String,
) -> Dict(QualifiedName, Set(String)) {
  let entries = case simplifile.read_directory(packages_directory) {
    Ok(found) -> found
    Error(_) -> []
  }
  list.fold(entries, dict.new(), fn(effect_map, package_name) {
    let assay_directory =
      packages_directory <> "/" <> package_name <> "/priv/assay"
    let files = case simplifile.get_files(assay_directory) {
      Ok(found) -> found
      Error(_) -> []
    }
    list.fold(files, effect_map, fn(inner_map, file_path) {
      case string.ends_with(file_path, ".assay") {
        True -> load_assay_file(inner_map, file_path, assay_directory)
        False -> inner_map
      }
    })
  })
}

fn load_assay_file(
  effect_map: Dict(QualifiedName, Set(String)),
  file_path: String,
  assay_directory: String,
) -> Dict(QualifiedName, Set(String)) {
  let parsed =
    simplifile.read(file_path)
    |> result.map_error(fn(_) { Nil })
    |> result.try(fn(content) {
      annotation.parse_file(content) |> result.map_error(fn(_) { Nil })
    })
  case parsed {
    Error(_) -> effect_map
    Ok(assay_file) -> {
      let module_path = file_path_to_module(file_path, assay_directory)
      annotation.extract_annotations(assay_file)
      |> list.filter_map(fn(ann) {
        case ann.kind {
          Effects ->
            Ok(#(
              QualifiedName(module: module_path, function: ann.function),
              ann.effects,
            ))
          _ -> Error(Nil)
        }
      })
      |> list.fold(effect_map, fn(map, pair) {
        dict.insert(map, pair.0, pair.1)
      })
    }
  }
}

fn file_path_to_module(path: String, assay_directory: String) -> String {
  let prefix = assay_directory <> "/"
  let relative = case string.starts_with(path, prefix) {
    True -> string.drop_start(path, string.length(prefix))
    False -> path
  }
  string.replace(relative, ".assay", "")
}

fn catalog_effectful_functions() -> Dict(QualifiedName, Set(String)) {
  [
    #(QualifiedName("gleam/io", "println"), set.from_list(["Stdout"])),
    #(QualifiedName("gleam/io", "print"), set.from_list(["Stdout"])),
    #(QualifiedName("gleam/io", "debug"), set.from_list(["Stdout"])),
    #(QualifiedName("gleam/io", "print_error"), set.from_list(["Stderr"])),
    #(QualifiedName("gleam/io", "println_error"), set.from_list(["Stderr"])),
    #(QualifiedName("gleam/erlang/process", "send"), set.from_list(["Process"])),
    #(
      QualifiedName("gleam/erlang/process", "start"),
      set.from_list(["Process"]),
    ),
    #(
      QualifiedName("gleam/erlang/process", "sleep"),
      set.from_list(["Process"]),
    ),
    #(
      QualifiedName("gleam/erlang/process", "sleep_forever"),
      set.from_list(["Process"]),
    ),
    #(QualifiedName("lustre_http", "send"), set.from_list(["Http"])),
    #(QualifiedName("lustre_http", "get"), set.from_list(["Http"])),
    #(QualifiedName("lustre_http", "post"), set.from_list(["Http"])),
    #(QualifiedName("lustre/effect", "from"), set.from_list(["Effect"])),
    #(QualifiedName("lustre/effect", "batch"), set.from_list(["Effect"])),
  ]
  |> dict.from_list()
}

fn catalog_pure_modules() -> Set(String) {
  set.from_list([
    "gleam/list", "gleam/string", "gleam/int", "gleam/float", "gleam/bool",
    "gleam/option", "gleam/result", "gleam/dict", "gleam/set", "gleam/pair",
    "gleam/order", "gleam/bit_array", "gleam/bytes_tree", "gleam/string_tree",
    "gleam/regex", "gleam/uri", "gleam/dynamic", "lustre/element",
    "lustre/element/html", "lustre/element/svg", "lustre/attribute",
    "lustre/event",
  ])
}
