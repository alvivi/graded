// The commands without the latent-effect rules read every spec exactly as
// before them. A fixture whose own spec and whose dependency's spec use the
// latent-effect clauses — well-formed, malformed, and a carried variable
// charged by an effect term — is run through every command by the built
// graded, and each command's exit status, stdout, stderr and written spec are
// compared with what graded before the rules wrote for the same fixture.

import gleeunit/should
import shellout
import simplifile
import support

const fixture = "/tmp/graded_inactive_commands"

const report = "/tmp/graded_inactive_commands_report.txt"

const script = "/tmp/graded_inactive_commands.sh"

pub fn inactive_commands_match_the_reading_before_the_rules_test() {
  let _ = support.write_fixture(fixture, fixture_files())
  support.write_file(script, runner)
  let assert Ok(cwd) = simplifile.current_directory()
  let assert Ok(_) =
    shellout.command(
      run: "sh",
      with: [script, erl(), cwd <> "/build/dev/erlang", fixture, report],
      in: ".",
      opt: [],
    )
  let assert Ok(written) = simplifile.read(report)
  support.cleanup(fixture)
  let _ = simplifile.delete(report)
  let _ = simplifile.delete(script)
  written |> should.equal(expected_report)
}

fn erl() -> String {
  erts_root() <> "/bin/erl"
}

@external(erlang, "inactive_commands_test_ffi", "erts_root")
fn erts_root() -> String

fn fixture_files() -> List(#(String, String)) {
  [
    #(
      "gleam.toml",
      "name = \"proj\"

[dependencies]
dep = \">= 0.0.0\"
",
    ),
    #(
      "manifest.toml",
      "packages = [
  { name = \"dep\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"hex\", outer_checksum = \"0\" },
]

[requirements]
dep = { version = \">= 0.0.0\" }
",
    ),
    #(
      "build/packages/packages.toml",
      "[packages]
dep = \"1.0.0\"

[git]
",
    ),
    #(
      "proj.graded",
      "// The latent-effect clauses, a malformed one and a carried variable charged
// by an effect term.
assume proj/ffi.run(value: [v]) : [] where runs : [v], carries : [v]
assume proj/ffi.each(values: [l], f: [f]) : [f] where relay : f(l)
assume proj/ffi.bad(value: [v]) : [] where runs : [w]
assume proj/ffi.charged(value: [v]) : [v]
assume proj/ffi.decode(decoder: [d]) where runs : [d]
check proj.go : []
",
    ),
    #(
      "src/proj/ffi.gleam",
      "pub type Config {
  Config(on_item: fn(String) -> Nil)
}

@external(erlang, \"m\", \"run\")
pub fn run(value: Config) -> Nil

@external(erlang, \"m\", \"each\")
pub fn each(values: List(Config), f: fn(Config) -> Nil) -> Nil

@external(erlang, \"m\", \"bad\")
pub fn bad(value: Config) -> Nil

@external(erlang, \"m\", \"charged\")
pub fn charged(value: Config) -> Nil

@external(erlang, \"m\", \"decode\")
pub fn decode(decoder: Config) -> Nil
",
    ),
    #(
      "src/proj.gleam",
      "import dep
import proj/ffi

pub fn go(c: ffi.Config) -> Nil {
  ffi.run(c)
  ffi.each([c], fn(x) { ffi.run(x) })
  ffi.bad(c)
  ffi.decode(c)
  dep.tick([c])
  dep.apply(c)
}

pub fn charged(c: ffi.Config) -> Nil {
  ffi.charged(c)
}
",
    ),
    #(
      "build/packages/dep/src/dep.gleam",
      "pub type Box {
  Box(run: fn() -> Nil)
}

@external(erlang, \"m\", \"tick\")
pub fn tick(values: List(a)) -> Nil

@external(erlang, \"m\", \"apply\")
pub fn apply(value: a) -> Nil
",
    ),
    #(
      "build/packages/dep/dep.graded",
      "assume dep.apply(value: [v]) : [v]
assume dep.tick(values: [l]) : [] where runs : [l], carries : [l
",
    ),
  ]
}

const runner =
  "#!/bin/sh
# Run graded's commands over a fixture with the Erlang at $1 and the build at
# $2, writing every command's exit status, stdout, stderr and the files it
# wrote to $4.
#   run.sh <erl> <erlang build root> <fixture> <report>
ERL=$1
EBIN=$2
FIXTURE=$3
REPORT=$4
cd \"$FIXTURE\" || exit 1
graded() {
  \"$ERL\" -noshell -pa \"$EBIN\"/*/ebin -eval 'graded:main(), erlang:halt(0).' -extra \"$@\"
}
record() {
  {
    echo \"== $1\"
    echo \"exit: $2\"
    echo \"-- stdout\"
    cat stdout.txt
    echo \"-- stderr\"
    cat stderr.txt
  } >>\"$REPORT\"
}
run() {
  graded \"$@\" >stdout.txt 2>stderr.txt </dev/null
  record \"$*\" $?
}
: >\"$REPORT\"
run check
run effect proj.go
run why proj.go
run why proj.charged
run infer --dry-run
run infer --check
run format --check
graded format --stdin <proj.graded >stdout.txt 2>stderr.txt
record \"format --stdin\" $?
run catalog
run format
{ echo \"-- proj.graded after format\"; cat proj.graded; } >>\"$REPORT\"
run infer
{ echo \"-- proj.graded after infer\"; cat proj.graded; } >>\"$REPORT\"
rm -f stdout.txt stderr.txt
"

const expected_report =
  "== check
exit: 1
-- stdout
proj.graded: warning: the `where` clause(s) on proj/ffi.run use key(s) `runs`, `carries` this version of graded does not read, so nothing resolves them. They are kept verbatim through `graded format` and `graded infer`; upgrade graded, or delete them
proj.graded: warning: the `where` clause(s) on proj/ffi.each use key(s) `relay` this version of graded does not read, so nothing resolves them. They are kept verbatim through `graded format` and `graded infer`; upgrade graded, or delete them
proj.graded: warning: the `where` clause(s) on proj/ffi.bad use key(s) `runs` this version of graded does not read, so nothing resolves them. They are kept verbatim through `graded format` and `graded infer`; upgrade graded, or delete them
proj.graded: warning: the `where` clause(s) on proj/ffi.decode use key(s) `runs` this version of graded does not read, so nothing resolves them. They are kept verbatim through `graded format` and `graded infer`; upgrade graded, or delete them
graded: 4 warning(s)
src/proj.gleam: go calls proj/ffi.decode, an external with no declared effects, with unresolved effects [Unknown] but declared []
src/proj.gleam: go calls dep.tick with effects [_] (from dep's shipped spec) but declared []
src/proj.gleam: go calls dep.apply, whose effects depend on an argument that could not be resolved, with unresolved effects [Unknown] but declared []

graded: 3 violation(s) found
-- stderr
graded: warning: dep's spec has 1 line graded could not read (2: assume dep.tick(values: [l]) : [] where runs : [l], carries : [l); the rest of the file is used
== effect proj.go
exit: 0
-- stdout
proj.go has effects [_]
  source: in-memory inference
-- stderr
graded: warning: dep's spec has 1 line graded could not read (2: assume dep.tick(values: [l]) : [] where runs : [l], carries : [l); the rest of the file is used
== why proj.go
exit: 0
-- stdout
proj.go has effects [_]
declared check proj.go : []
  calls proj/ffi.run with effects [] (from your spec's `assume` line)
  calls proj/ffi.each with effects [] (from your spec's `assume` line)
  calls proj/ffi.run with effects [] (from your spec's `assume` line)
  calls proj/ffi.bad with effects [] (from your spec's `assume` line)
  calls proj/ffi.decode, an external with no declared effects, with unresolved effects [Unknown]
  calls dep.tick with effects [_] (from dep's shipped spec)
  calls dep.apply, whose effects depend on an argument that could not be resolved, with unresolved effects [Unknown]

typed resolutions
  ffi.run: typed resolution module proj/ffi.run (agrees)
  ffi.each: typed resolution module proj/ffi.each (agrees)
  ffi.run: typed resolution module proj/ffi.run (agrees)
  ffi.bad: typed resolution module proj/ffi.bad (agrees)
  ffi.decode: typed resolution module proj/ffi.decode (agrees)
  dep.tick: typed resolution module dep.tick (agrees)
  dep.apply: typed resolution module dep.apply (agrees)
-- stderr
graded: warning: dep's spec has 1 line graded could not read (2: assume dep.tick(values: [l]) : [] where runs : [l], carries : [l); the rest of the file is used
== why proj.charged
exit: 0
-- stdout
proj.charged has effects that could not be determined: [Unknown]
  calls proj/ffi.charged, whose effects depend on an argument that could not be resolved, with unresolved effects [Unknown]

typed resolutions
  ffi.charged: typed resolution module proj/ffi.charged (agrees)
-- stderr
graded: warning: dep's spec has 1 line graded could not read (2: assume dep.tick(values: [l]) : [] where runs : [l], carries : [l); the rest of the file is used
== infer --dry-run
exit: 0
-- stdout
  assume proj/ffi.decode(decoder: [d]) where runs : [d]
  check proj.go : []
+ 
+ effects proj.charged : [Unknown]
+ effects proj.go : [_]
+ effects proj/ffi.decode : [Unknown]
\\ No newline at end of file
-- stderr
graded: warning: dep's spec has 1 line graded could not read (2: assume dep.tick(values: [l]) : [] where runs : [l], carries : [l); the rest of the file is used
== infer --check
exit: 1
-- stdout
-- stderr
graded: warning: dep's spec has 1 line graded could not read (2: assume dep.tick(values: [l]) : [] where runs : [l], carries : [l); the rest of the file is used
graded: error: Stale spec file proj.graded; run `graded infer` to update it:
  assume proj/ffi.decode(decoder: [d]) where runs : [d]
  check proj.go : []
+ 
+ effects proj.charged : [Unknown]
+ effects proj.go : [_]
+ effects proj/ffi.decode : [Unknown]
\\ No newline at end of file
== format --check
exit: 1
-- stdout
-- stderr
graded: error: Unformatted .graded files:
  proj.graded
== format --stdin
exit: 0
-- stdout
assume proj/ffi.bad(value: [v]) : [] where runs : [w]
assume proj/ffi.charged(value: [v]) : [v]
assume proj/ffi.decode(decoder: [d]) where runs : [d]
assume proj/ffi.each(values: [l], f: [f]) : [f] where relay : f(l)
// The latent-effect clauses, a malformed one and a carried variable charged
// by an effect term.
assume proj/ffi.run(value: [v]) : [] where runs : [v], carries : [v]

check proj.go : []
-- stderr
== catalog
exit: 0
-- stdout
argv@1.1.0
bigi@4.1.1
birl@2.0.0
directories@1.2.0
envoy@1.0.0
filepath@1.1.2
glam@2.0.4
glance@6.1.0
gleam_bitwise@1.3.1
gleam_community_ansi@1.5.0
gleam_community_colour@2.0.4
gleam_community_maths@2.0.2
gleam_cowboy@1.1.0
gleam_crypto@1.5.1
gleam_deque@1.0.0
gleam_elli@3.0.0
gleam_erlang@0.34.0
gleam_erlang@1.0.0
gleam_fetch@1.4.0
gleam_hackney@1.4.0
gleam_http@3.0.0
gleam_httpc@3.0.0
gleam_javascript@1.0.0
gleam_json@3.0.0
gleam_otp@0.12.0
gleam_otp@1.0.0
gleam_regexp@1.1.1
gleam_stdlib@0.70.0
gleam_stdlib@1.0.0
gleam_time@1.0.0
gleam_yielder@1.1.0
glearray@2.1.2
glexer@2.4.0
glisten@9.0.1
houdini@1.0.0
iv@1.4.4
justin@1.1.0
logging@1.5.0
lustre@4.0.0
lustre@5.0.0
lustre_http@1.0.0
marceau@1.3.0
mist@6.0.3
modem@2.0.0
modem@2.1.0
pog@4.1.0
ranger@1.4.0
shellout@1.8.0
simplifile@2.0.0
snag@1.2.0
splitter@1.2.0
tom@2.0.2
wisp@2.2.2
youid@1.6.0
-- stderr
== format
exit: 0
-- stdout
-- stderr
-- proj.graded after format
assume proj/ffi.bad(value: [v]) : [] where runs : [w]
assume proj/ffi.charged(value: [v]) : [v]
assume proj/ffi.decode(decoder: [d]) where runs : [d]
assume proj/ffi.each(values: [l], f: [f]) : [f] where relay : f(l)
// The latent-effect clauses, a malformed one and a carried variable charged
// by an effect term.
assume proj/ffi.run(value: [v]) : [] where runs : [v], carries : [v]

check proj.go : []
== infer
exit: 0
-- stdout
graded: inferred effects written
-- stderr
graded: warning: dep's spec has 1 line graded could not read (2: assume dep.tick(values: [l]) : [] where runs : [l], carries : [l); the rest of the file is used
-- proj.graded after infer
assume proj/ffi.bad(value: [v]) : [] where runs : [w]
assume proj/ffi.charged(value: [v]) : [v]
assume proj/ffi.decode(decoder: [d]) where runs : [d]
assume proj/ffi.each(values: [l], f: [f]) : [f] where relay : f(l)
// The latent-effect clauses, a malformed one and a carried variable charged
// by an effect term.
assume proj/ffi.run(value: [v]) : [] where runs : [v], carries : [v]

check proj.go : []

effects proj.charged : [Unknown]
effects proj.go : [_]
effects proj/ffi.decode : [Unknown]"
