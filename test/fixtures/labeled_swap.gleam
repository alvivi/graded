import gleam/io

// Callbacks whose labels are each other's in-body names: the parameter labelled
// `first` is named `cb`, and the one labelled `cb` is named `other`. A call
// labelled `first: loud, cb: quiet` hands `loud` to the parameter named `cb`,
// so every consumer below charges `[Stdout]` and fails its `[]` budget.

// Returns a closure over the parameter named `cb`.
pub fn lab(first cb: fn() -> Nil, cb other: fn() -> Nil) -> fn() -> Nil {
  let _ = other
  fn() { cb() }
}

// Calls the parameter named `cb`.
pub fn apply1(first cb: fn() -> Nil, cb other: fn() -> Nil) -> Nil {
  let _ = other
  cb()
}

fn loud() -> Nil {
  io.println("loud")
}

fn quiet() -> Nil {
  Nil
}

pub fn run_lab() -> Nil {
  lab(first: loud, cb: quiet)()
}

pub fn run_apply1() -> Nil {
  apply1(first: loud, cb: quiet)
}

// The positional twin, which never read the labels.
pub fn run_lab_positional() -> Nil {
  lab(loud, quiet)()
}
