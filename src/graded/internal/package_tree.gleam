// The packages a project depends on: where each local package is, what each
// one declares, the graph of their requirements, and whether the tree graded
// reads is provably the whole tree Gleam resolved.
//
// A local package is located only by a path declaration, in the root's
// `gleam.toml` or a local package's, and can be required by any package: a
// package provided at a path satisfies every version requirement for its name.

import filepath
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded/internal/config
import graded/internal/topo
import simplifile
import tom

// Declarations
//
// One entry of a `[dependencies]` or `[dev-dependencies]` table, read whole.

pub type Declaration {
  // `name = "..."` or `{ version = "..." }`.
  VersionDeclaration(constraint: String)
  // `{ path = "..." }`: the path as written, and the directory it names —
  // resolved against the package that declares it and normalized.
  PathDeclaration(path: String, directory: String)
  // `{ git = "...", ref = "..." }`, with the subdirectory `path` it may name.
  GitDeclaration(repo: String, ref: String, path: Option(String))
  // An entry of any other shape, kept as written.
  OtherDeclaration(value: tom.Toml)
}

// The entries of the table at `key` in a parsed `gleam.toml`, with each path
// resolved against `declarer`. An absent table declares nothing; one that is
// there and not a table is `Error(Nil)`.
fn declarations_at(
  toml: Dict(String, tom.Toml),
  key: String,
  declarer: String,
) -> Result(Dict(String, Declaration), Nil) {
  case tom.get_table(toml, [key]) {
    Ok(table) ->
      Ok(
        dict.map_values(table, fn(_name, value) { declaration(value, declarer) }),
      )
    Error(tom.NotFound(..)) -> Ok(dict.new())
    Error(tom.WrongType(..)) -> Error(Nil)
  }
}

fn declaration(value: tom.Toml, declarer: String) -> Declaration {
  case value {
    tom.String(constraint) -> VersionDeclaration(constraint:)
    tom.InlineTable(table) | tom.Table(table) ->
      case
        tom.get_string(table, ["git"]),
        tom.get_string(table, ["path"]),
        tom.get_string(table, ["version"])
      {
        Ok(repo), path, _ ->
          case tom.get_string(table, ["ref"]) {
            Ok(ref) ->
              GitDeclaration(repo:, ref:, path: option.from_result(path))
            Error(_) -> OtherDeclaration(value:)
          }
        Error(_), Ok(path), _ ->
          PathDeclaration(
            path:,
            directory: config.normalized_path(config.resolve_path(
              declarer,
              path,
            )),
          )
        Error(_), Error(_), Ok(constraint) -> VersionDeclaration(constraint:)
        Error(_), Error(_), Error(_) -> OtherDeclaration(value:)
      }
    _ -> OtherDeclaration(value:)
  }
}

// The root's `[dependencies]` entries carrying a `path`, as `#(name, path)`.
// Only inline tables are read, and the list comes back in the order its fold
// over the table builds it — the path dependencies graded has always loaded,
// and the order it has always loaded them in.
pub fn path_dependencies(gleam_toml_path: String) -> List(#(String, String)) {
  case config.read_toml(gleam_toml_path) {
    Ok(toml) -> direct_path_dependencies(toml)
    Error(Nil) -> []
  }
}

fn direct_path_dependencies(
  toml: Dict(String, tom.Toml),
) -> List(#(String, String)) {
  case tom.get_table(toml, ["dependencies"]) {
    Error(_) -> []
    Ok(deps) ->
      dict.fold(deps, [], fn(acc, name, value) {
        case value {
          tom.InlineTable(table) ->
            case tom.get_string(table, ["path"]) {
              Ok(path) -> [#(name, path), ..acc]
              Error(_) -> acc
            }
          _ -> acc
        }
      })
  }
}

// Discovery
//
// One walk from the root's declarations through every local package's
// `[dependencies]`, never a dependency's dev-dependencies, and the graph over
// every package the tree names.

pub type LocalPackages {
  LocalPackages(
    // The package root the walk started at.
    root: String,
    // The root's own declarations, or `Error(Nil)` where its `gleam.toml`
    // could not be read or parsed.
    root_declarations: Result(RootDeclarations, Nil),
    // Every local package the walk located, by name.
    packages: Dict(String, LocalPackage),
    // The root's `[dependencies]` entries carrying a `path`, as
    // `path_dependencies` reads them.
    direct: List(#(String, String)),
    // What makes the tree one Gleam would refuse, or one the walk could not
    // read whole.
    flags: List(Flag),
    // The directories whose `gleam.toml` the walk read, in the order it read
    // them, the root's first.
    visited: List(String),
    // The manifest, read whole, or why it could not be.
    manifest: Result(Manifest, ManifestProblem),
    // Each package's requirement names, over every package the tree names.
    edges: Dict(String, Set(String)),
    // The packages reachable from the root's `[dependencies]`.
    runtime: Set(String),
  )
}

pub type RootDeclarations {
  RootDeclarations(
    dependencies: Dict(String, Declaration),
    dev_dependencies: Dict(String, Declaration),
  )
}

pub type LocalPackage {
  LocalPackage(
    name: String,
    // The directory its declaration names, normalized.
    directory: String,
    // Its `[dependencies]`, or `Error(Nil)` where its `gleam.toml` could not
    // be read or parsed.
    dependencies: Result(Dict(String, Declaration), Nil),
    // Its spec file, relative to its directory, as its `gleam.toml` names it.
    spec_file: String,
  )
}

pub type Flag {
  // One name declared at two directories. The first located is kept.
  LocatedTwice(name: String)
  // One name provided two ways: two `git` declarations differing in
  // repository or ref, or a `git` declaration and a path.
  ProvidedTwoWays(name: String)
  // A `gleam.toml` that could not be read or parsed, or holds a dependency
  // table that is not a table.
  UnreadableConfig(directory: String)
}

// Which local packages a command loads, and how.
pub type PackageClass {
  // A root `[dependencies]` entry carrying a path: loaded as it always was.
  Direct
  // Any other local package the root's runtime dependencies reach.
  NewlyLoaded
  // A local package only the root's dev-dependencies reach.
  DevOnly
}

// Walk the tree rooted at `package_root`.
pub fn discover(package_root: String) -> LocalPackages {
  let root_config = config.read_toml(filepath.join(package_root, "gleam.toml"))
  let root_declarations = {
    use toml <- result.try(root_config)
    use dependencies <- result.try(declarations_at(
      toml,
      "dependencies",
      package_root,
    ))
    // Gleam reads the table under either spelling.
    use underscored <- result.try(declarations_at(
      toml,
      "dev_dependencies",
      package_root,
    ))
    use hyphenated <- result.map(declarations_at(
      toml,
      "dev-dependencies",
      package_root,
    ))
    RootDeclarations(
      dependencies:,
      dev_dependencies: dict.merge(hyphenated, underscored),
    )
  }
  let direct = case root_config {
    Ok(toml) -> direct_path_dependencies(toml)
    Error(Nil) -> []
  }
  let walk = case root_declarations {
    Ok(declarations) ->
      walk_from_root(list.append(
        sorted_entries(declarations.dependencies),
        sorted_entries(declarations.dev_dependencies),
      ))
    Error(Nil) ->
      Walk(
        packages: dict.new(),
        flags: [UnreadableConfig(package_root)],
        visited: [],
      )
  }
  let manifest = read_manifest(filepath.join(package_root, "manifest.toml"))
  let edges = package_edges(package_root, walk.packages, manifest)
  let runtime = case root_declarations {
    Ok(declarations) ->
      reachable(edges, set.from_list(dict.keys(declarations.dependencies)))
    Error(Nil) -> set.new()
  }
  LocalPackages(
    root: package_root,
    root_declarations:,
    packages: walk.packages,
    direct:,
    flags: list.append(
      list.reverse(walk.flags),
      provider_flags(root_declarations, walk.packages),
    ),
    visited: [package_root, ..list.reverse(walk.visited)],
    manifest:,
    edges:,
    runtime:,
  )
}

// The class of the local package `name`, which the walk located.
pub fn class_of(local: LocalPackages, name: String) -> PackageClass {
  use <- bool.guard(
    when: list.any(local.direct, fn(entry) { entry.0 == name }),
    return: Direct,
  )
  case set.contains(local.runtime, name) {
    True -> NewlyLoaded
    False -> DevOnly
  }
}

// The local packages the root's runtime dependencies reach, callees first:
// a package comes after every package it reaches through any path of the
// graph, installed packages included. Within a cycle, the root's own path
// dependencies keep the order `path_dependencies` gives them, and the others
// follow by name. No order is promised between independent packages.
pub fn runtime_order(local: LocalPackages) -> List(LocalPackage) {
  let direct_rank =
    list.index_map(local.direct, fn(entry, rank) { #(entry.0, rank) })
    |> dict.from_list
  topo.scc_order(local.edges)
  |> list.flat_map(fn(component) {
    component
    |> list.filter(set.contains(local.runtime, _))
    |> list.filter_map(dict.get(local.packages, _))
    |> list.sort(fn(a, b) {
      case dict.get(direct_rank, a.name), dict.get(direct_rank, b.name) {
        Ok(a_rank), Ok(b_rank) -> int.compare(a_rank, b_rank)
        Ok(_), Error(Nil) -> order.Lt
        Error(Nil), Ok(_) -> order.Gt
        Error(Nil), Error(Nil) -> string.compare(a.name, b.name)
      }
    })
  })
}

// The runtime local packages the root does not declare by path, in
// `runtime_order`.
pub fn newly_loaded(local: LocalPackages) -> List(LocalPackage) {
  runtime_order(local)
  |> list.filter(fn(package) { class_of(local, package.name) == NewlyLoaded })
}

fn sorted_entries(
  declarations: Dict(String, Declaration),
) -> List(#(String, Declaration)) {
  dict.to_list(declarations)
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

type Walk {
  Walk(
    packages: Dict(String, LocalPackage),
    flags: List(Flag),
    visited: List(String),
  )
}

// Locate every package the root declares by path before entering any of
// them, then walk into each in turn.
fn walk_from_root(entries: List(#(String, Declaration))) -> Walk {
  let walk = Walk(packages: dict.new(), flags: [], visited: [])
  let #(walk, located) =
    list.fold(entries, #(walk, []), fn(state, entry) {
      let #(walk, located) = state
      case locate(walk, entry) {
        #(walk, Some(package)) -> #(walk, [package, ..located])
        #(walk, None) -> #(walk, located)
      }
    })
  list.fold(list.reverse(located), walk, enter)
}

// Record the package a path declaration names, unless that name is already
// located. Returns the package when it is newly located.
fn locate(
  walk: Walk,
  entry: #(String, Declaration),
) -> #(Walk, Option(LocalPackage)) {
  case entry {
    #(name, PathDeclaration(directory:, ..)) ->
      case dict.has_key(walk.packages, name) {
        True -> #(walk, None)
        False -> {
          let toml = config.read_toml(filepath.join(directory, "gleam.toml"))
          let dependencies =
            result.try(toml, declarations_at(_, "dependencies", directory))
          let package =
            LocalPackage(
              name:,
              directory:,
              dependencies:,
              spec_file: config.spec_file_in(toml, name),
            )
          let flags = case dependencies {
            Ok(_) -> walk.flags
            Error(Nil) -> [UnreadableConfig(directory), ..walk.flags]
          }
          #(
            Walk(
              packages: dict.insert(walk.packages, name, package),
              flags:,
              visited: [directory, ..walk.visited],
            ),
            Some(package),
          )
        }
      }
    #(_name, VersionDeclaration(..))
    | #(_name, GitDeclaration(..))
    | #(_name, OtherDeclaration(..)) -> #(walk, None)
  }
}

fn enter(walk: Walk, package: LocalPackage) -> Walk {
  case package.dependencies {
    Error(Nil) -> walk
    Ok(dependencies) ->
      list.fold(sorted_entries(dependencies), walk, fn(walk, entry) {
        case locate(walk, entry) {
          #(walk, Some(nested)) -> enter(walk, nested)
          #(walk, None) -> walk
        }
      })
  }
}

// The names declared at two directories, or provided two ways, across the
// root's declarations and every located package's.
fn provider_flags(
  root: Result(RootDeclarations, Nil),
  packages: Dict(String, LocalPackage),
) -> List(Flag) {
  let providers =
    declaration_tables(root, packages)
    |> list.flat_map(dict.to_list)
    |> list.fold(dict.new(), fn(acc, entry) {
      let #(name, declaration) = entry
      case providing(declaration) {
        Some(provider) ->
          dict.upsert(acc, name, fn(existing) {
            set.insert(option.unwrap(existing, set.new()), provider)
          })
        None -> acc
      }
    })
  dict.to_list(providers)
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.filter_map(fn(entry) {
    let #(name, providers) = entry
    let paths =
      set.filter(providers, fn(provider) {
        case provider {
          ProvidedAt(..) -> True
          ProvidedByGit(..) -> False
        }
      })
    case set.size(providers), set.size(paths) {
      0, _ | 1, _ -> Error(Nil)
      _, paths if paths > 1 -> Ok(LocatedTwice(name:))
      _, _ -> Ok(ProvidedTwoWays(name:))
    }
  })
}

// Every dependency table the walk read: the root's two, and each located
// package's own.
fn declaration_tables(
  root: Result(RootDeclarations, Nil),
  packages: Dict(String, LocalPackage),
) -> List(Dict(String, Declaration)) {
  let root_tables = case root {
    Ok(declarations) -> [
      declarations.dependencies,
      declarations.dev_dependencies,
    ]
    Error(Nil) -> []
  }
  list.append(
    root_tables,
    list.filter_map(dict.values(packages), fn(package) { package.dependencies }),
  )
}

type Provider {
  ProvidedAt(directory: String)
  ProvidedByGit(repo: String, ref: String)
}

fn providing(declaration: Declaration) -> Option(Provider) {
  case declaration {
    PathDeclaration(directory:, ..) -> Some(ProvidedAt(directory:))
    GitDeclaration(repo:, ref:, ..) -> Some(ProvidedByGit(repo:, ref:))
    VersionDeclaration(..) | OtherDeclaration(..) -> None
  }
}

// Requirement edges: the root's declarations of every kind, each local
// package's `[dependencies]`, and the manifest's per-entry requirements — or,
// where the manifest cannot be read whole, each installed package's own
// `[dependencies]`. Only names that are packages of the tree are nodes; an
// edge to any other name is dropped.
fn package_edges(
  package_root: String,
  packages: Dict(String, LocalPackage),
  manifest: Result(Manifest, ManifestProblem),
) -> Dict(String, Set(String)) {
  let local_edges =
    dict.map_values(packages, fn(_name, package) {
      case package.dependencies {
        Ok(dependencies) -> set.from_list(dict.keys(dependencies))
        Error(Nil) -> set.new()
      }
    })
  let other_edges = case manifest {
    Ok(manifest) ->
      list.fold(manifest.entries, dict.new(), fn(acc, entry) {
        dict.insert(acc, entry.name, set.from_list(entry.requirements))
      })
    Error(_) -> installed_edges(package_root)
  }
  let edges = dict.combine(local_edges, other_edges, set.union)
  let nodes = set.from_list(dict.keys(edges))
  dict.map_values(edges, fn(_name, names) { set.intersection(names, nodes) })
}

fn installed_edges(package_root: String) -> Dict(String, Set(String)) {
  case
    simplifile.read_directory(filepath.join(package_root, "build/packages"))
  {
    Error(_) -> dict.new()
    Ok(names) ->
      list.fold(names, dict.new(), fn(acc, name) {
        case installed_dependencies(package_root, name) {
          Ok(dependencies) ->
            dict.insert(acc, name, set.from_list(dict.keys(dependencies)))
          Error(Nil) -> acc
        }
      })
  }
}

fn reachable(
  edges: Dict(String, Set(String)),
  from: Set(String),
) -> Set(String) {
  reach(edges, set.to_list(from), set.new())
}

fn reach(
  edges: Dict(String, Set(String)),
  pending: List(String),
  seen: Set(String),
) -> Set(String) {
  case pending {
    [] -> seen
    [name, ..rest] ->
      case set.contains(seen, name) {
        True -> reach(edges, rest, seen)
        False -> {
          let next = case dict.get(edges, name) {
            Ok(names) -> set.to_list(names)
            Error(Nil) -> []
          }
          reach(edges, list.append(next, rest), set.insert(seen, name))
        }
      }
  }
}

// Whether the graph holds a cycle, a package requiring itself included.
fn has_cycle(edges: Dict(String, Set(String))) -> Bool {
  result.is_error(topo.sort(edges))
}

// The manifest
//
// `manifest.toml` read whole: every entry with the fields completeness weighs,
// and the root requirements the last resolution was made from.

pub type Manifest {
  Manifest(entries: List(ManifestEntry), requirements: Dict(String, tom.Toml))
}

pub type ManifestEntry {
  ManifestEntry(
    name: String,
    version: String,
    source: String,
    requirements: List(String),
    path: Option(String),
    repo: Option(String),
    commit: Option(String),
    build_tools: Option(List(String)),
  )
}

pub type ManifestProblem {
  // No `manifest.toml` at all.
  NoManifest
  // One that is there and is not a manifest graded can read whole.
  MalformedManifest
}

fn read_manifest(path: String) -> Result(Manifest, ManifestProblem) {
  case simplifile.read(path) {
    Error(simplifile.Enoent) -> Error(NoManifest)
    Error(_) -> Error(MalformedManifest)
    Ok(content) -> {
      use toml <- result.try(
        tom.parse(content) |> result.replace_error(MalformedManifest),
      )
      use packages <- result.try(
        tom.get_array(toml, ["packages"])
        |> result.replace_error(MalformedManifest),
      )
      use entries <- result.try(
        list.try_map(packages, manifest_entry)
        |> result.replace_error(MalformedManifest),
      )
      use requirements <- result.map(
        case tom.get_table(toml, ["requirements"]) {
          Ok(table) -> Ok(table)
          Error(tom.NotFound(..)) -> Ok(dict.new())
          Error(tom.WrongType(..)) -> Error(MalformedManifest)
        },
      )
      Manifest(entries:, requirements:)
    }
  }
}

fn manifest_entry(value: tom.Toml) -> Result(ManifestEntry, Nil) {
  use table <- result.try(case value {
    tom.InlineTable(table) | tom.Table(table) -> Ok(table)
    _ -> Error(Nil)
  })
  use name <- result.try(
    tom.get_string(table, ["name"]) |> result.replace_error(Nil),
  )
  use version <- result.try(
    tom.get_string(table, ["version"]) |> result.replace_error(Nil),
  )
  use source <- result.try(
    tom.get_string(table, ["source"]) |> result.replace_error(Nil),
  )
  use requirements <- result.try(
    tom.get_array(table, ["requirements"])
    |> result.replace_error(Nil)
    |> result.try(strings),
  )
  let build_tools =
    tom.get_array(table, ["build_tools"])
    |> result.replace_error(Nil)
    |> result.try(strings)
    |> option.from_result
  Ok(ManifestEntry(
    name:,
    version:,
    source:,
    requirements:,
    path: tom.get_string(table, ["path"]) |> option.from_result,
    repo: tom.get_string(table, ["repo"]) |> option.from_result,
    commit: tom.get_string(table, ["commit"]) |> option.from_result,
    build_tools:,
  ))
}

fn strings(values: List(tom.Toml)) -> Result(List(String), Nil) {
  list.try_map(values, fn(value) {
    case value {
      tom.String(string) -> Ok(string)
      _ -> Error(Nil)
    }
  })
}

// Completeness
//
// Whether the tree graded reads is provably the whole tree Gleam resolved:
// the manifest is well formed, agrees with the root's declarations and with
// the provider of every package, the installed records agree with it, nothing
// was flagged, the graph is acyclic, and every package it lists was found.

pub fn is_complete(local: LocalPackages) -> Bool {
  case local.root_declarations, local.manifest {
    Error(Nil), _ -> False
    Ok(root), Error(NoManifest) ->
      dict.is_empty(root.dependencies) && dict.is_empty(root.dev_dependencies)
    Ok(_), Error(MalformedManifest) -> False
    Ok(root), Ok(manifest) ->
      well_formed(manifest)
      && root_matches(local.root, root, manifest)
      && local_entries_match(local, manifest)
      && list.all(manifest.entries, provider_matches(local, root, manifest, _))
      && installed_records_match(local.root, manifest)
      && local.flags == []
      && !has_cycle(local.edges)
      && list.all(manifest.entries, is_located(local, _))
  }
}

// No name listed twice, and every requirement — an entry's, or one of the
// root's — names a listed package.
fn well_formed(manifest: Manifest) -> Bool {
  let names = list.map(manifest.entries, fn(entry) { entry.name })
  let listed = set.from_list(names)
  set.size(listed) == list.length(names)
  && list.all(dict.keys(manifest.requirements), set.contains(listed, _))
  && list.all(manifest.entries, fn(entry) {
    list.all(entry.requirements, set.contains(listed, _))
  })
}

// The manifest's root requirements are the root's `[dependencies]` and
// `[dev-dependencies]`: a bare version reads as `{ version = ... }`, and a path
// is compared as the directory it names.
fn root_matches(
  package_root: String,
  root: RootDeclarations,
  manifest: Manifest,
) -> Bool {
  let declared =
    dict.merge(root.dev_dependencies, root.dependencies)
    |> dict.map_values(fn(_name, declaration) { comparable(declaration) })
  let recorded =
    dict.map_values(manifest.requirements, fn(_name, value) {
      comparable(declaration(value, package_root))
    })
  declared == recorded
}

fn comparable(declaration: Declaration) -> Declaration {
  case declaration {
    PathDeclaration(directory:, ..) -> PathDeclaration(path: "", directory:)
    VersionDeclaration(..) | GitDeclaration(..) | OtherDeclaration(..) ->
      declaration
  }
}

// Every located package is a local entry at the directory the walk found it
// at, requiring exactly the names its `[dependencies]` declare, and every local
// entry is one the walk located.
fn local_entries_match(local: LocalPackages, manifest: Manifest) -> Bool {
  let local_entries =
    list.filter(manifest.entries, fn(entry) { entry.source == "local" })
  list.length(local_entries) == dict.size(local.packages)
  && list.all(local_entries, fn(entry) {
    case dict.get(local.packages, entry.name), entry.path {
      Ok(package), Some(path) ->
        config.normalized_path(config.resolve_path(local.root, path))
        == package.directory
        && case package.dependencies {
          Ok(dependencies) ->
            set.from_list(entry.requirements)
            == set.from_list(dict.keys(dependencies))
          Error(Nil) -> False
        }
      _, _ -> False
    }
  })
}

// The entry's source is the provider the declarations select. A version
// requirement is only ever a constraint and never selects one: a path the walk
// located selects the package there, a `git` declaration it read selects that
// repository, and otherwise the providing declaration sits in a requiring
// installed package's own `gleam.toml`.
fn provider_matches(
  local: LocalPackages,
  root: RootDeclarations,
  manifest: Manifest,
  entry: ManifestEntry,
) -> Bool {
  case dict.has_key(local.packages, entry.name) {
    True -> entry.source == "local"
    False ->
      case git_declaration_read(root, local.packages, entry.name) {
        Some(repo) -> entry.source == "git" && entry.repo == Some(repo)
        None ->
          case entry.source {
            "hex" -> True
            "git" -> provided_by_installed(local.root, manifest, entry)
            _ -> False
          }
      }
  }
}

// The repository a `git` declaration of `name` names, in the root's
// declarations or a located package's.
fn git_declaration_read(
  root: RootDeclarations,
  packages: Dict(String, LocalPackage),
  name: String,
) -> Option(String) {
  list.find_map(declaration_tables(Ok(root), packages), fn(table) {
    case dict.get(table, name) {
      Ok(GitDeclaration(repo:, ..)) -> Ok(repo)
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

// Whether an installed package requiring the `git` entry declares it in its
// own `gleam.toml`: by `git` with the entry's repository, or — for a member of
// a repository — by a path that, resolved against the requiring package's own
// place in the same repository and commit, is the member's.
fn provided_by_installed(
  package_root: String,
  manifest: Manifest,
  entry: ManifestEntry,
) -> Bool {
  list.any(manifest.entries, fn(requirer) {
    requirer.source != "local"
    && list.contains(requirer.requirements, entry.name)
    && case installed_dependencies(package_root, requirer.name) {
      Error(Nil) -> False
      Ok(dependencies) ->
        case dict.get(dependencies, entry.name), entry.path {
          Ok(GitDeclaration(repo:, ..)), None -> entry.repo == Some(repo)
          Ok(PathDeclaration(path:, ..)), Some(member_path) ->
            requirer.source == "git"
            && requirer.repo == entry.repo
            && requirer.commit == entry.commit
            && within_repository(option.unwrap(requirer.path, ""), path)
            == Ok(config.normalized_path(member_path))
          _, _ -> False
        }
    }
  })
}

fn installed_dependencies(
  package_root: String,
  name: String,
) -> Result(Dict(String, Declaration), Nil) {
  config.read_toml(filepath.join(
    package_root,
    "build/packages/" <> name <> "/gleam.toml",
  ))
  |> result.try(declarations_at(_, "dependencies", ""))
}

// `path`, declared by the package at `base` in a repository, as a path from
// the repository's root. `Error(Nil)` where it leads outside the repository.
fn within_repository(base: String, path: String) -> Result(String, Nil) {
  use <- bool.guard(when: string.starts_with(path, "/"), return: Error(Nil))
  let resolved = config.normalized_path(config.resolve_path(base, path))
  case resolved == ".." || string.starts_with(resolved, "../") {
    True -> Error(Nil)
    False -> Ok(resolved)
  }
}

// `build/packages/packages.toml` records every installed entry at the
// manifest's version, and a `git` entry — which must name its commit — at
// that commit and its path.
fn installed_records_match(package_root: String, manifest: Manifest) -> Bool {
  let installed =
    list.filter(manifest.entries, fn(entry) { entry.source != "local" })
  use <- bool.guard(when: installed == [], return: True)
  case
    config.read_toml(filepath.join(package_root, "build/packages/packages.toml"))
  {
    Error(Nil) -> False
    Ok(records) ->
      list.all(installed, fn(entry) {
        tom.get_string(records, ["packages", entry.name]) == Ok(entry.version)
        && case entry.source, entry.commit {
          "git", Some(commit) ->
            tom.get_string(records, ["git", entry.name, "commit"]) == Ok(commit)
            && option.from_result(
              tom.get_string(records, ["git", entry.name, "path"]),
            )
            == entry.path
          "git", None -> False
          _, _ -> True
        }
      })
  }
}

// The entry's package was found: its directory's `src/` walks, and holds a
// Gleam module, unless the package is built by rebar3 or mix alone and may
// hold none.
fn is_located(local: LocalPackages, entry: ManifestEntry) -> Bool {
  let directory = case dict.get(local.packages, entry.name) {
    Ok(package) -> package.directory
    Error(Nil) -> filepath.join(local.root, "build/packages/" <> entry.name)
  }
  case config.source_files(filepath.join(directory, "src")) {
    Ok(files) ->
      list.any(files, string.ends_with(_, ".gleam"))
      || built_without_gleam(entry.build_tools)
    Error(_) -> False
  }
}

// A `build_tools` list naming at least one tool, each of them rebar3 or mix.
fn built_without_gleam(build_tools: Option(List(String))) -> Bool {
  case build_tools {
    Some([_, ..] as tools) ->
      list.all(tools, fn(tool) { tool == "rebar3" || tool == "mix" })
    Some([]) | None -> False
  }
}
