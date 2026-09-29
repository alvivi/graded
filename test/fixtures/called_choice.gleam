// A `case` of functions called with arguments — in place, or through a `let` —
// is charged what the same `case` is charged with the call written in every
// branch. `loud`, `db`, `make` and `make_at` are declared in fixtures.graded, and
// every function below is checked against `[]`, so each violation reports what
// the function is charged.
//
// The `@target(erlang)` gate keeps the module out of the JavaScript build, where
// the bodyless externals have no implementation.

import gleam/io

@target(erlang)
@external(erlang, "some_ffi_module", "loud")
pub fn loud() -> Nil

@target(erlang)
@external(erlang, "some_ffi_module", "db")
pub fn db() -> Nil

@target(erlang)
@external(erlang, "some_ffi_module", "make")
pub fn make() -> fn() -> Nil

@target(erlang)
@external(erlang, "some_ffi_module", "make_at")
pub fn make_at() -> fn(Int, fn() -> Nil) -> Nil

@target(erlang)
@external(erlang, "some_ffi_module", "make_int")
pub fn make_int() -> fn(Int) -> Nil

@target(erlang)
pub fn quiet() -> Nil {
  Nil
}

@target(erlang)
pub fn run(cb: fn() -> Nil) -> Nil {
  cb()
}

@target(erlang)
pub fn skip(_cb: fn() -> Nil) -> Nil {
  Nil
}

@target(erlang)
pub fn log_named(n: Int) -> Nil {
  let _ = n
  loud()
}

@target(erlang)
pub fn save(n: Int) -> Nil {
  let _ = n
  db()
}

@target(erlang)
pub fn run_at(n: Int, cb: fn() -> Nil) -> Nil {
  let _ = n
  cb()
}

@target(erlang)
pub fn skip_at(n: Int, cb: fn() -> Nil) -> Nil {
  let _ = n
  let _ = cb
  Nil
}

// The same pair declared with labels, and with the labels crossed against the
// names. A selected function value is called positionally, so neither set of
// labels moves an argument.
@target(erlang)
pub fn run_at_l(n n: Int, cb cb: fn() -> Nil) -> Nil {
  let _ = n
  cb()
}

@target(erlang)
pub fn skip_at_l(n n: Int, cb cb: fn() -> Nil) -> Nil {
  let _ = n
  let _ = cb
  Nil
}

@target(erlang)
pub fn run_at_x(cb n: Int, n cb: fn() -> Nil) -> Nil {
  let _ = n
  cb()
}

@target(erlang)
pub fn skip_at_x(cb n: Int, n cb: fn() -> Nil) -> Nil {
  let _ = n
  let _ = cb
  Nil
}

// Module functions a parameter of the same name shadows.
@target(erlang)
pub fn a() -> Nil {
  Nil
}

@target(erlang)
pub fn act(cb: fn() -> Nil) -> Nil {
  let _ = cb
  Nil
}

// Let-bound: a branch naming a function, a parameter, a call result.

@target(erlang)
pub fn case_named(flag: Bool) -> Nil {
  let op = case flag {
    True -> loud
    False -> db
  }
  op()
}

@target(erlang)
pub fn choose_mixed(flag: Bool, a: fn() -> Nil) -> Nil {
  let op = case flag {
    True -> a
    False -> loud
  }
  op()
}

@target(erlang)
pub fn choose_both(flag: Bool, a: fn() -> Nil, b: fn() -> Nil) -> Nil {
  let op = case flag {
    True -> a
    False -> b
  }
  op()
}

@target(erlang)
pub fn choose_second(
  flag: Bool,
  a: fn(fn() -> Nil) -> Nil,
  b: fn(fn() -> Nil) -> Nil,
) -> Nil {
  let op = case flag {
    True -> a
    False -> b
  }
  op(fn() { Nil })
}

@target(erlang)
pub fn case_block(flag: Bool) -> Nil {
  let op = {
    case flag {
      True -> loud
      False -> quiet
    }
  }
  op()
}

@target(erlang)
pub fn case_in_closure(flag: Bool) -> Nil {
  let op = case flag {
    True -> loud
    False -> db
  }
  Nil |> fn(_) { op() }
}

@target(erlang)
pub fn closure_and_ref(flag: Bool) -> Nil {
  let op = case flag {
    True -> fn() { loud() }
    False -> db
  }
  op()
}

@target(erlang)
pub fn call_result(flag: Bool) -> Nil {
  let op = case flag {
    True -> make()
    False -> db
  }
  op()
}

@target(erlang)
pub fn nested(flag: Bool, other: Bool) -> Nil {
  let op = case flag {
    True ->
      case other {
        True -> loud
        False -> quiet
      }
    False -> db
  }
  op()
}

@target(erlang)
pub fn alias_of_choice(flag: Bool) -> Nil {
  let op = case flag {
    True -> loud
    False -> db
  }
  let again = op
  again()
}

@target(erlang)
pub fn run_or_skip(flag: Bool, cb: fn() -> Nil) -> Nil {
  let op = case flag {
    True -> run
    False -> skip
  }
  op(cb)
}

// Closures, and a plain alias, beside the choices above.

@target(erlang)
pub fn closures_only(flag: Bool) -> Nil {
  let op = case flag {
    True -> fn() { loud() }
    False -> fn() { Nil }
  }
  op()
}

@target(erlang)
pub fn closure_alone() -> Nil {
  let op = fn() { loud() }
  op()
}

@target(erlang)
pub fn plain_alias() -> Nil {
  let op = loud
  op()
}

@target(erlang)
pub fn closure_capture(flag: Bool) -> Nil {
  let suffix = io.println
  let op = case flag {
    True -> fn() { suffix("x") }
    False -> db
  }
  op()
}

// In place.

@target(erlang)
pub fn inline_named(flag: Bool) -> Nil {
  case flag {
    True -> loud
    False -> db
  }()
}

// Piped into: the `case` itself is walked, its subject and a producer call in
// a branch included, and each option is called with the piped value.
@target(erlang)
pub fn piped_subject() -> Nil {
  1
  |> case db() {
    _ -> log_named
  }
}

@target(erlang)
pub fn piped_producer(flag: Bool) -> Nil {
  1
  |> case flag {
    True -> make_int()
    False -> save
  }
}

@target(erlang)
pub fn inline_two(
  flag: Bool,
  a: fn(fn() -> Nil, fn() -> Nil) -> Nil,
  b: fn(fn() -> Nil, fn() -> Nil) -> Nil,
  x: fn() -> Nil,
  y: fn() -> Nil,
) -> Nil {
  case flag {
    True -> a
    False -> b
  }(x, y)
}

@target(erlang)
pub fn branches_two(
  flag: Bool,
  a: fn(fn() -> Nil, fn() -> Nil) -> Nil,
  b: fn(fn() -> Nil, fn() -> Nil) -> Nil,
  x: fn() -> Nil,
  y: fn() -> Nil,
) -> Nil {
  case flag {
    True -> a(x, y)
    False -> b(x, y)
  }
}

// Ordinary arguments, and ordinary arguments beside a callback, each in place
// and through a `let`, for every kind of option.

@target(erlang)
pub fn ordinary_inline(flag: Bool) -> Nil {
  case flag {
    True -> log_named
    False -> save
  }(1)
}

@target(erlang)
pub fn ordinary_let(flag: Bool) -> Nil {
  let op = case flag {
    True -> log_named
    False -> save
  }
  op(1)
}

@target(erlang)
pub fn interleaved_inline(flag: Bool, cb: fn() -> Nil) -> Nil {
  case flag {
    True -> run_at
    False -> skip_at
  }(1, cb)
}

@target(erlang)
pub fn interleaved_let(flag: Bool, cb: fn() -> Nil) -> Nil {
  let op = case flag {
    True -> run_at
    False -> skip_at
  }
  op(1, cb)
}

@target(erlang)
pub fn labelled_inline(flag: Bool, cb: fn() -> Nil) -> Nil {
  case flag {
    True -> run_at_l
    False -> skip_at_l
  }(1, cb)
}

@target(erlang)
pub fn labelled_let(flag: Bool, cb: fn() -> Nil) -> Nil {
  let op = case flag {
    True -> run_at_l
    False -> skip_at_l
  }
  op(1, cb)
}

@target(erlang)
pub fn crossed_inline(flag: Bool, cb: fn() -> Nil) -> Nil {
  case flag {
    True -> run_at_x
    False -> skip_at_x
  }(1, cb)
}

@target(erlang)
pub fn crossed_let(flag: Bool, cb: fn() -> Nil) -> Nil {
  let op = case flag {
    True -> run_at_x
    False -> skip_at_x
  }
  op(1, cb)
}

// The valid labelled form, on a direct call to a named function.
@target(erlang)
pub fn labelled_direct(cb: fn() -> Nil) -> Nil {
  run_at_l(cb: cb, n: 1)
}

@target(erlang)
pub fn crossed_direct(cb: fn() -> Nil) -> Nil {
  run_at_x(n: cb, cb: 1)
}

@target(erlang)
pub fn param_ordinary_inline(flag: Bool, a: fn(Int) -> Nil) -> Nil {
  case flag {
    True -> a
    False -> save
  }(1)
}

@target(erlang)
pub fn param_ordinary_let(flag: Bool, a: fn(Int) -> Nil) -> Nil {
  let op = case flag {
    True -> a
    False -> save
  }
  op(1)
}

@target(erlang)
pub fn param_interleaved_inline(
  flag: Bool,
  a: fn(Int, fn() -> Nil) -> Nil,
  cb: fn() -> Nil,
) -> Nil {
  case flag {
    True -> a
    False -> run_at
  }(1, cb)
}

@target(erlang)
pub fn param_interleaved_let(
  flag: Bool,
  a: fn(Int, fn() -> Nil) -> Nil,
  cb: fn() -> Nil,
) -> Nil {
  let op = case flag {
    True -> a
    False -> run_at
  }
  op(1, cb)
}

@target(erlang)
pub fn returned_inline(flag: Bool, cb: fn() -> Nil) -> Nil {
  case flag {
    True -> make_at()
    False -> run_at
  }(1, cb)
}

@target(erlang)
pub fn returned_let(flag: Bool, cb: fn() -> Nil) -> Nil {
  let op = case flag {
    True -> make_at()
    False -> run_at
  }
  op(1, cb)
}

// The producer's returned function called on its own, the existing path the
// two rows above extend.
@target(erlang)
pub fn returned_alone(cb: fn() -> Nil) -> Nil {
  let h = make_at()
  h(1, cb)
}

// A parameter read before the module function it shadows, first-order and
// operator, in place and through a `let`.

@target(erlang)
pub fn choose(flag: Bool, a: fn() -> Nil) -> Nil {
  case flag {
    True -> a
    False -> fn() { Nil }
  }()
}

@target(erlang)
pub fn choose_let(flag: Bool, a: fn() -> Nil) -> Nil {
  let op = case flag {
    True -> a
    False -> fn() { Nil }
  }
  op()
}

@target(erlang)
pub fn run_shadowed(a: fn() -> Nil) -> Nil {
  run(a)
}

@target(erlang)
pub fn choose_op(flag: Bool, act: fn(fn() -> Nil) -> Nil) -> Nil {
  case flag {
    True -> act
    False -> fn(_) { Nil }
  }(loud)
}

@target(erlang)
pub fn choose_op_let(flag: Bool, act: fn(fn() -> Nil) -> Nil) -> Nil {
  let op = case flag {
    True -> act
    False -> fn(_) { Nil }
  }
  op(loud)
}

// The call written in the branch, the reading `choose_op` agrees with. A
// function of this module handed to an operator parameter reads `[Unknown]`
// as that parameter's argument, in either spelling.
@target(erlang)
pub fn choose_op_twin(flag: Bool, act: fn(fn() -> Nil) -> Nil) -> Nil {
  case flag {
    True -> act(loud)
    False -> Nil
  }
}

// A parameter the body rebinds after the `let`: the branch names the parameter.
@target(erlang)
pub fn rebound_after_let(flag: Bool, a: fn() -> Nil) -> Nil {
  let op = case flag {
    True -> a
    False -> db
  }
  let a = quiet
  let _ = a
  op()
}

// The same choice called from a piped closure whose own parameter is named `a`:
// there the branch's `a` names nothing the closure can reach, and in particular
// not the `b` piped into it.
@target(erlang)
pub fn shadowed_in_closure(flag: Bool, a: fn() -> Nil, b: fn() -> Nil) -> Nil {
  let op = case flag {
    True -> a
    False -> db
  }
  b
  |> fn(a) {
    let _ = a
    op()
  }
}
