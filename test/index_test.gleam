// Each index read in place of a scan answers what the scan answered: over
// generated inputs, the index beside the scan it replaced, whose predicate is
// written out here.

import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import gleeunit/should
import graded/internal/checker
import graded/internal/extract
import graded/internal/package_tree
import graded/internal/typeinfo
import qcheck

fn many() -> qcheck.Config {
  qcheck.default_config() |> qcheck.with_test_count(400)
}

fn one_of(first: a, rest: List(a)) -> qcheck.Generator(a) {
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

// Source directories

// A path segment: `src` itself, or a name beside it.
fn segment_gen() -> qcheck.Generator(String) {
  one_of("src", ["lib", "a", "s"])
}

fn segments_gen(longest: Int) -> qcheck.Generator(List(String)) {
  qcheck.generic_list(segment_gen(), qcheck.bounded_int(0, longest))
}

// `segments` written out with what leaves the directory it names unchanged,
// chosen per segment by `plan`: a `.` before it, a name and `..` before it, or
// a repeated slash, and a trailing slash after the last. A relative spelling
// never starts with a slash, and names its own directory `.`.
fn spelled(segments: List(String), plan: List(Int), absolute: Bool) -> String {
  let parts =
    list.zip(segments, plan)
    |> list.index_map(fn(pair, index) {
      case pair.1, index, absolute {
        1, _, _ -> [".", pair.0]
        2, _, _ -> ["a", "..", pair.0]
        3, 0, False -> [".", pair.0]
        3, _, _ -> ["", pair.0]
        _, _, _ -> [pair.0]
      }
    })
    |> list.flatten
  let trailing = case list.last(plan) {
    Ok(4) -> [""]
    _ -> []
  }
  case absolute, list.append(parts, trailing) {
    True, written -> "/" <> string.join(written, "/")
    False, [] -> "."
    False, written -> string.join(written, "/")
  }
}

// The segments that lead from the directory `from` to `to`, both absolute
// and written as segments: up to their common prefix, then down.
fn relative_segments(from: List(String), to: List(String)) -> List(String) {
  let common = common_length(from, to, 0)
  list.append(
    list.repeat("..", list.length(from) - common),
    list.drop(to, common),
  )
}

fn common_length(left: List(String), right: List(String), count: Int) -> Int {
  case left, right {
    [a, ..left], [b, ..right] if a == b -> common_length(left, right, count + 1)
    _, _ -> count
  }
}

// One spelling of the absolute directory `target`, read from `working`.
fn spelling_gen(
  target: List(String),
  working: List(String),
) -> qcheck.Generator(String) {
  use #(absolute, plan) <- qcheck.map(qcheck.tuple2(
    qcheck.bool(),
    qcheck.fixed_length_list_from(
      qcheck.bounded_int(0, 4),
      list.length(target) + list.length(working) + 1,
    ),
  ))
  case absolute {
    True -> spelled(target, plan, True)
    False -> spelled(relative_segments(working, target), plan, False)
  }
}

type Membership {
  Membership(
    working: List(String),
    roots: List(List(String)),
    path: List(String),
    spelled_roots: List(String),
    spelled_path: String,
  )
}

fn membership_gen() -> qcheck.Generator(Membership) {
  use working <- qcheck.bind(segments_gen(3))
  use roots <- qcheck.bind(qcheck.generic_list(
    segments_gen(3),
    qcheck.bounded_int(1, 3),
  ))
  use path <- qcheck.bind(
    qcheck.from_generators(segments_gen(6), [
      // A path under one of the roots, so membership is often true.
      {
        use #(index, tail) <- qcheck.map(qcheck.tuple2(
          qcheck.bounded_int(0, list.length(roots) - 1),
          segments_gen(3),
        ))
        let root = list.drop(roots, index) |> list.first |> result.unwrap([])
        list.flatten([root, ["src"], tail])
      },
    ]),
  )
  use spelled_roots <- qcheck.bind(
    list.fold(list.reverse(roots), qcheck.return([]), fn(acc, root) {
      use #(spelling, rest) <- qcheck.map(qcheck.tuple2(
        spelling_gen(root, working),
        acc,
      ))
      [spelling, ..rest]
    }),
  )
  use spelled_path <- qcheck.map(spelling_gen(path, working))
  Membership(working:, roots:, path:, spelled_roots:, spelled_path:)
}

fn absolute(segments: List(String)) -> String {
  "/" <> string.join(segments, "/")
}

// Whether `path` lies under a root's `src/`, read off the segments themselves.
fn under_by_segments(path: List(String), roots: List(List(String))) -> Bool {
  list.any(roots, fn(root) {
    list.length(path) >= list.length(root) + 2
    && list.take(path, list.length(root) + 1) == list.append(root, ["src"])
  })
}

// The membership test lies under the same roots however the path and the roots
// are spelled: adjacent, leading and trailing `src` segments, roots named
// `src` or nested under one, `.`, `..`, repeated and trailing slashes, and a
// relative spelling read from the working directory beside an absolute one.
// On the absolute spellings it is the prefix test it replaced.
pub fn source_directory_membership_answers_the_prefix_test_test() {
  use case_ <- qcheck.run(many(), membership_gen())
  let Membership(working:, roots:, path:, spelled_roots:, spelled_path:) = case_
  let directories =
    package_tree.source_directories_of(spelled_roots, absolute(working))
  let prefix_test =
    list.any(roots, fn(root) {
      let directory = case root {
        [] -> "/src/"
        _ -> absolute(root) <> "/src/"
      }
      string.starts_with(absolute(path), directory)
    })
  #(
    package_tree.under_source_directory(
      spelled_path,
      directories,
      absolute(working),
    ),
    prefix_test,
  )
  |> should.equal(#(
    under_by_segments(path, roots),
    under_by_segments(path, roots),
  ))
}

pub fn a_source_directory_named_src_holds_its_files_test() {
  let directories =
    package_tree.source_directories_of(
      ["/r/src", "../lib", "/r/outer/src/lib"],
      "/r/app",
    )
  [
    "/r/src/src/dep.gleam",
    "/r/app/../lib/src/dep.gleam",
    "./../lib//src/./dep.gleam",
    "/r/outer/src/lib/src/dep.gleam",
    "/r/src/dep.gleam",
    "/r/lib/src",
  ]
  |> list.map(package_tree.under_source_directory(_, directories, "/r/app"))
  |> should.equal([True, True, True, True, False, False])
}

// Holes

fn offset_gen() -> qcheck.Generator(Int) {
  qcheck.from_generators(qcheck.bounded_int(0, 1100), [
    qcheck.return(0),
    qcheck.return(255),
    qcheck.return(256),
    qcheck.return(511),
    qcheck.return(512),
    qcheck.return(768),
  ])
}

fn span_gen() -> qcheck.Generator(#(Int, Int)) {
  use #(start, length) <- qcheck.map(qcheck.tuple2(
    offset_gen(),
    qcheck.from_generators(qcheck.return(0), [
      qcheck.bounded_int(0, 12),
      qcheck.bounded_int(200, 600),
    ]),
  ))
  #(start, start + length)
}

// A span beside holes: any span, or one at a hole's own edges.
fn holes_and_span_gen() -> qcheck.Generator(#(List(#(Int, Int)), #(Int, Int))) {
  use holes <- qcheck.bind(qcheck.generic_list(
    span_gen(),
    qcheck.bounded_int(0, 6),
  ))
  let edges =
    list.flat_map(holes, fn(hole) {
      [
        hole,
        #(hole.0, hole.1 + 1),
        #(hole.0 - 1, hole.1),
        #(hole.1, hole.1),
        #(hole.0, hole.0),
      ]
    })
  use span <- qcheck.map(case edges {
    [] -> span_gen()
    [first, ..rest] -> qcheck.from_generators(span_gen(), [one_of(first, rest)])
  })
  #(holes, span)
}

// The holes index places a span inside a hole exactly where the containment
// test over every hole does: across stretch boundaries, for a zero-width hole,
// and for a span ending on a hole's last byte.
pub fn the_holes_index_answers_the_containment_test_test() {
  use #(holes, span) <- qcheck.run(many(), holes_and_span_gen())
  typeinfo.inside_a_hole(span, typeinfo.holes(holes))
  |> should.equal(
    list.any(holes, fn(hole) { span.0 >= hole.0 && span.1 <= hole.1 }),
  )
}

// Field labels

fn label_gen() -> qcheck.Generator(#(String, String, String)) {
  qcheck.tuple3(
    one_of("m", ["n", "o/p"]),
    one_of("T", ["U"]),
    one_of("f", ["g"]),
  )
}

// The labels by type and field are the labels the filter over every label
// keeps, in the same order.
pub fn the_field_label_index_answers_the_label_filter_test() {
  use labels <- qcheck.run(
    many(),
    qcheck.generic_set(label_gen(), qcheck.bounded_int(0, 8)),
  )
  let labelled = checker.labels_by_type_field(labels)
  list.flat_map(["T", "U", "V"], fn(type_name) {
    list.map(["f", "g", "h"], fn(field) { #(type_name, field) })
  })
  |> list.each(fn(query) {
    labelled(query.0, query.1)
    |> should.equal(
      set.to_list(labels)
      |> list.filter(fn(label) { label.1 == query.0 && label.2 == query.1 }),
    )
  })
}

// Counts

fn name_gen() -> qcheck.Generator(String) {
  one_of("a", ["b", "c", "d"])
}

// How many lists hold each value is how many the containment test finds.
pub fn holding_counts_answer_the_containment_count_test() {
  use lists <- qcheck.run(
    many(),
    qcheck.generic_list(
      qcheck.generic_list(name_gen(), qcheck.bounded_int(0, 5)),
      qcheck.bounded_int(0, 4),
    ),
  )
  let counts = checker.holding_counts(lists)
  ["a", "b", "c", "d"]
  |> list.each(fn(value) {
    let held = list.count(lists, list.contains(_, value))
    dict.get(counts, value)
    |> should.equal(case held {
      0 -> Error(Nil)
      held -> Ok(held)
    })
  })
}

// The names written more than once are those the count over every name finds.
pub fn names_written_more_than_once_answer_the_count_test() {
  use names <- qcheck.run(
    many(),
    qcheck.generic_list(name_gen(), qcheck.bounded_int(0, 8)),
  )
  checker.written_more_than_once(names)
  |> should.equal(
    list.filter(names, fn(name) {
      list.count(names, fn(other) { other == name }) > 1
    })
    |> list.unique,
  )
}

// Definitions

fn definition_gen() -> qcheck.Generator(String) {
  use #(name, target, public) <- qcheck.map(qcheck.tuple3(
    name_gen(),
    one_of("", ["@target(erlang)\n", "@target(javascript)\n"]),
    qcheck.bool(),
  ))
  target
  <> case public {
    True -> "pub "
    False -> ""
  }
  <> "fn "
  <> name
  <> "() -> Int {\n  "
  <> int.to_string(string.length(name))
  <> "\n}\n"
}

// A module's definitions by name are its functions the name filter keeps, in
// source order, and its pairs are the names the count finds more than once.
pub fn the_definitions_index_answers_the_name_filter_test() {
  use sources <- qcheck.run(
    many(),
    qcheck.generic_list(definition_gen(), qcheck.bounded_int(0, 6)),
  )
  let assert Ok(module) = glance.module(string.join(sources, "\n"))
  let definitions = checker.module_definitions(module)
  let pairs = checker.module_pairs(module)
  ["a", "b", "c", "d"]
  |> list.each(fn(name) {
    let named =
      list.filter(module.functions, fn(definition) {
        definition.definition.name == name
      })
    #(dict.get(definitions, name) |> result.unwrap([]), dict.get(pairs, name))
    |> should.equal(
      #(named, case list.length(named) > 1 {
        True -> Ok(named)
        False -> Error(Nil)
      }),
    )
  })
}

fn one_name_definition_gen() -> qcheck.Generator(String) {
  use target <- qcheck.map(
    one_of("", ["@target(erlang)\n", "@target(javascript)\n"]),
  )
  target <> "pub fn a() -> Int {\n  0\n}\n"
}

// The definition each target builds, read off each definition's targets once,
// is the one the scan per target finds: the first of the definitions
// `built_functions` keeps on that target that `compiled_targets` places there.
pub fn built_variants_answer_the_per_target_scan_test() {
  use #(sources, targets) <- qcheck.run(
    many(),
    qcheck.tuple2(
      qcheck.generic_list(one_name_definition_gen(), qcheck.bounded_int(0, 4)),
      one_of(["erlang", "javascript"], [["erlang"], ["javascript"]]),
    ),
  )
  let assert Ok(module) = glance.module(string.join(sources, "\n"))
  extract.built_variants(module.functions, targets)
  |> should.equal(
    list.filter_map(targets, fn(target) {
      extract.built_functions(module.functions, set.from_list([target]))
      |> list.find(fn(definition) {
        set.contains(
          extract.compiled_targets(definition, set.from_list([target])),
          target,
        )
      })
      |> result.map(fn(definition) { #(target, definition) })
    }),
  )
}
