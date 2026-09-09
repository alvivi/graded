// The versions graded was verified on, and how an observed version stands to
// them.
//
// A version is *verified* when girard's compiler differential suite was
// regenerated on it and is clean and the coverage probe was repeated on it,
// both recorded. There is one class of support, verified: "builds on" is not a
// claim graded makes, so an unverified version is stated rather than ranked.
//
// The constants are data, not a gate. Nothing here decides a charge, a spec
// line or an exit code; `graded coverage` prints a standing beside each version
// it observes and every other command ignores them. `release_test` pins them
// against `.tool-versions`, `manifest.toml` and `gleam.toml`, so a bump to any
// of those fails the suite until the constants follow.

import gleam/list

// Every Gleam compiler the suite and the differential corpus were clean on,
// lowest first: the floor, then the pin. `gleam.toml`'s `gleam = ">= …"` names
// the head, and the pin in `.tool-versions` is the last element.
pub const verified_gleam = ["1.15.4", "1.16.0", "1.17.0", "1.18.0"]

// The Erlang/OTP release the suite was run on, as `.tool-versions` pins it.
pub const verified_otp = "28.4.2"

// The girard the corpus was measured against, as `manifest.toml` pins it.
pub const verified_girard = "3.0.0"

// The versions of what is *running*, not of what is analyzed: graded itself,
// the girard and glance it loaded, the Erlang/OTP release under it, and the
// Gleam compiler on the path. Each is `Error(Nil)` where it cannot be read —
// on JavaScript no application metadata exists, and `gleam` may not be
// installed — which the report states as "not observed".
pub type Observed {
  Observed(
    graded: String,
    girard: Result(String, Nil),
    glance: Result(String, Nil),
    otp: Result(String, Nil),
    gleam: Result(String, Nil),
  )
}

// How a version graded observed at runtime stands to the ones it was verified
// on. `Unobserved` is an honest answer, not a failure: a version can be
// unreadable (the JavaScript target holds no application metadata, a `gleam`
// binary may not be on the path), and a diagnostic says so rather than guessing.
pub type VersionStanding {
  Verified
  Unverified(observed: String, verified: List(String))
  Unobserved
}

// The standing of one observed version against the versions verified for it.
pub fn standing(
  observed: Result(String, Nil),
  verified: List(String),
) -> VersionStanding {
  case observed {
    Error(Nil) -> Unobserved
    Ok(version) ->
      case list.contains(verified, version) {
        True -> Verified
        False -> Unverified(observed: version, verified:)
      }
  }
}
