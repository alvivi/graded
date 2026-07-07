// The headline case: a getter that returns a receiver path rooted at its
// parameter (`Path`). `inner(get_options(Config(options: Options(resolver:
// resolver))))` forwards `o.resolver` onto the caller's `resolver` through the
// getter's `config.options` path.

pub type Options {
  Options(resolver: fn() -> Nil)
}

pub type Config {
  Config(options: Options)
}

pub fn inner(o: Options) -> Nil {
  o.resolver()
}

// Receiver-path getter: returns a field of its parameter.
fn get_options(config: Config) -> Options {
  config.options
}

pub fn caller(resolver: fn() -> Nil) -> Nil {
  inner(get_options(Config(options: Options(resolver: resolver))))
}
