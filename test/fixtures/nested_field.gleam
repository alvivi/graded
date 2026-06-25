// Nested record-field calls: `o.inner.run(..)`. The receiver of `.run` is the
// intermediate `o.inner`, not a bare variable, so the call is a *nested* field
// call. girard types the `o.inner` sub-expression as `Inner`, which drives the
// `type`-line, `check`-bound, and polymorphic resolution exactly as the
// single-level case does.

pub type Inner {
  Inner(run: fn() -> Nil)
}

pub type Outer {
  Outer(inner: Inner)
}

pub fn via_type(o: Outer) -> Nil {
  // No field bound; resolved by the `type nested_field.Inner.run : [Disk]`
  // line in fixtures.graded (girard types `o.inner` as Inner).
  o.inner.run()
}

pub fn via_bound(o: Outer) -> Nil {
  // Resolved by the dotted field bound on `via_bound`'s `check` line
  // (`check nested_field.via_bound(o.inner.run: [Stdout]) : []`), which wins
  // ahead of the `type` line.
  o.inner.run()
}

pub type Loose {
  Loose(act: fn() -> Nil)
}

pub type Holder {
  Holder(loose: Loose)
}

pub fn unbound(h: Holder) -> Nil {
  // `Loose.act` has NO `type` line and `unbound` has NO field bound, so the
  // nested fn-typed field call gets a field-effect variable that concretizes to
  // [Unknown] — the soundness floor — making the [] budget fail with [Unknown].
  h.loose.act()
}
