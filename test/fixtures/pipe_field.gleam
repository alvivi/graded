// A nested record-field call used as a *pipe target*: `"x" |> o.inner.run`. The
// pipe path must emit a FieldCall for the nested receiver so the field's effect
// is captured; before the fix it fell through to the generic walker and the
// effect was silently dropped, letting a [] budget pass unsoundly.

pub type Inner {
  Inner(run: fn(String) -> Nil)
}

pub type Outer {
  Outer(inner: Inner)
}

pub fn via_pipe(o: Outer) -> Nil {
  // Resolved by the `type pipe_field.Inner.run : [Disk]` line (girard types the
  // `o.inner` span as Inner). The [] budget fails with the precise [Disk].
  "x" |> o.inner.run
}
