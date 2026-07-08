// Join case whose branches are parameter-rooted *paths*, not bare parameters. A
// helper whose return is a `case` over `a.options`/`b.options` has a `Join` of two
// `Path`s, so the computed receiver forwards `o.resolver` onto the caller's
// `resolver` through both branches rather than collapsing to [Unknown].
// `classify_case_options` gates path branches out of the called-value path;
// return provenance folds them.

pub type Options {
  Options(resolver: fn() -> Nil)
}

pub type Config {
  Config(options: Options)
}

pub fn inner(o: Options) -> Nil {
  o.resolver()
}

// Branch return: each branch is a parameter-rooted path, so the join forwards both.
fn pick(flag: Bool, a: Config, b: Config) -> Options {
  case flag {
    True -> a.options
    False -> b.options
  }
}

pub fn caller(resolver: fn() -> Nil) -> Nil {
  inner(pick(
    True,
    Config(options: Options(resolver: resolver)),
    Config(options: Options(resolver: resolver)),
  ))
}
