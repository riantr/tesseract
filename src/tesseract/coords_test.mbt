///|
/// Geometry of the 3x3x3x3 lattice.
test "index and position round-trip over all 81 cells" {
  let mut checked = 0
  for c in @tesseract.all_coords() {
    let p = @tesseract.position_of(c)
    assert_true(@tesseract.position_in_bounds(p))
    assert_eq(@tesseract.coords_of(p), Some(c))
    assert_eq(@tesseract.index0(c), p - 1)
    checked = checked + 1
  }
  assert_eq(checked, @tesseract.TOTAL)
}

///|
test "positions outside 1..81 are rejected, not clamped" {
  assert_eq(@tesseract.coords_of(0), None)
  assert_eq(@tesseract.coords_of(82), None)
  assert_eq(@tesseract.coords_of(-1), None)
  assert_true(@tesseract.position_in_bounds(@tesseract.FIRST_POSITION))
  assert_true(@tesseract.position_in_bounds(@tesseract.LAST_POSITION))
  assert_false(@tesseract.position_in_bounds(0))
  assert_false(@tesseract.position_in_bounds(82))
}

///|
test "coordinates outside 0..2 are rejected" {
  assert_false(@tesseract.coords_in_bounds(@tesseract.coords(3, 0, 0, 0)))
  assert_false(@tesseract.coords_in_bounds(@tesseract.coords(0, -1, 0, 0)))
  assert_false(@tesseract.coords_in_bounds(@tesseract.coords(0, 0, 0, 3)))
  assert_true(@tesseract.coords_in_bounds(@tesseract.coords(2, 2, 2, 2)))
}

///|
test "the lattice corners sit at the ends of the row-major order" {
  assert_eq(@tesseract.coords_of(1), Some(@tesseract.coords(0, 0, 0, 0)))
  assert_eq(
    @tesseract.coords_of(@tesseract.TOTAL),
    Some(@tesseract.coords(2, 2, 2, 2)),
  )
  assert_eq(@tesseract.coords_of(28), Some(@tesseract.coords(1, 0, 0, 0)))
}

///|
test "coords format and parse agree, with and without parentheses" {
  let c = @tesseract.coords(1, 0, 2, 1)
  assert_eq(@tesseract.format_coords(c), "(1,0,2,1)")
  assert_eq(@tesseract.parse_coords("(1,0,2,1)"), Some(c))
  assert_eq(@tesseract.parse_coords("1,0,2,1"), Some(c))
  assert_eq(@tesseract.parse_coords(" ( 1 , 0 , 2 , 1 ) "), Some(c))
}

///|
test "a malformed address never silently resolves to another cell" {
  assert_eq(@tesseract.parse_coords("(1,0,2)"), None)
  assert_eq(@tesseract.parse_coords("(1,0,2,1,0)"), None)
  assert_eq(@tesseract.parse_coords("(3,0,2,1)"), None)
  assert_eq(@tesseract.parse_coords("(-1,0,2,1)"), None)
  assert_eq(@tesseract.parse_coords("(a,0,2,1)"), None)
  assert_eq(@tesseract.parse_coords(""), None)
}

///|
test "neighbours are bounded, never wrapped" {
  assert_eq(@tesseract.neighbours(@tesseract.coords(0, 0, 0, 0), 0).length(), 1)
  assert_eq(@tesseract.neighbours(@tesseract.coords(2, 2, 2, 2), 0).length(), 1)
  assert_eq(@tesseract.neighbours(@tesseract.coords(1, 1, 1, 1), 3).length(), 2)
  let n = @tesseract.neighbours(@tesseract.coords(0, 0, 0, 0), 0)
  assert_eq(n[0], @tesseract.coords(1, 0, 0, 0))
  let m = @tesseract.neighbours(@tesseract.coords(0, 0, 0, 0), 3)
  assert_eq(m[0], @tesseract.coords(0, 0, 0, 1))
}

///|
test "two cells share a line exactly when they agree on three coordinates" {
  let a = @tesseract.coords(1, 2, 0, 1)
  assert_true(@tesseract.shares_line(a, @tesseract.coords(1, 2, 2, 1)))
  assert_true(@tesseract.shares_line(a, a))
  assert_false(@tesseract.shares_line(a, @tesseract.coords(0, 0, 0, 0)))
  assert_false(@tesseract.shares_line(a, @tesseract.coords(1, 2, 1, 0)))
  assert_true(
    @tesseract.shares_line(
      @tesseract.coords(0, 0, 0, 0),
      @tesseract.coords(1, 0, 0, 0),
    ),
  )
}

///|
test "coord_at and with_coord agree on all four axes" {
  let c = @tesseract.coords(1, 2, 0, 1)
  assert_eq(@tesseract.coord_at(c, 0).unwrap(), 1)
  assert_eq(@tesseract.coord_at(c, 1).unwrap(), 2)
  assert_eq(@tesseract.coord_at(c, 2).unwrap(), 0)
  assert_eq(@tesseract.coord_at(c, 3).unwrap(), 1)
  let axis = 2
  let moved = @tesseract.with_coord(c, axis, 2)
  assert_eq(@tesseract.coord_at(moved, axis).unwrap(), 2)
  assert_eq(@tesseract.coord_at(moved, 0).unwrap(), 1)
  assert_eq(@tesseract.coord_at(moved, 1).unwrap(), 2)
  assert_eq(@tesseract.coord_at(moved, 3).unwrap(), 1)
}

///|
test "an axis outside the lattice is reported, not answered as the last one" {
  // `w` is 2 in this cell, so a fallthrough would hand back 2 for every one of
  // these and look like a real coordinate.
  let c = @tesseract.coords(1, 2, 0, 2)
  assert_eq(@tesseract.coord_at(c, 0), Some(1))
  assert_eq(@tesseract.coord_at(c, 1), Some(2))
  assert_eq(@tesseract.coord_at(c, 2), Some(0))
  assert_eq(@tesseract.coord_at(c, 3), Some(2))
  // Above the last axis, below zero, and far out of range.
  assert_eq(@tesseract.coord_at(c, 4), None)
  assert_eq(@tesseract.coord_at(c, 7), None)
  assert_eq(@tesseract.coord_at(c, 99), None)
  assert_eq(@tesseract.coord_at(c, 0 - 1), None)
  assert_eq(@tesseract.coord_at(c, 0 - 99), None)
  // The boundary is the axis count, not a hardcoded 3 or 4.
  assert_eq(@tesseract.coord_at(c, @tesseract.DIM), None)
  assert_eq(@tesseract.coord_at(c, @tesseract.DIM - 1), Some(2))
}

///|
test "the geometry helpers refuse an axis they do not have" {
  // Each of these used to answer with the w-axis geometry, reporting it as the
  // axis that was asked for.
  let c = @tesseract.coords(1, 2, 0, 2)
  let w_line = @tesseract.line_through(c, 3)
  let w_slab = @tesseract.slab_through(c, 3)
  // Controls: the valid axes still work, so an empty list below means "bad
  // axis" rather than "this shape happens to be empty". `w` is 2 here, so
  // axis 3 sits at the end of its axis and has one neighbour; axis 0 is
  // x=1, in the middle, and has two.
  assert_eq(w_line.length(), 3)
  assert_eq(w_slab.length(), 27)
  assert_eq(@tesseract.neighbours(c, 3).length(), 1)
  assert_eq(@tesseract.neighbours(c, 0).length(), 2)
  assert_eq(@tesseract.line_through(c, 3)[0], @tesseract.coords(1, 2, 0, 0))
  // Now the bad axes.
  assert_eq(@tesseract.line_through(c, 4).length(), 0)
  assert_eq(@tesseract.line_through(c, 99).length(), 0)
  assert_eq(@tesseract.line_through(c, 0 - 1).length(), 0)
  assert_eq(@tesseract.slab_through(c, 4).length(), 0)
  assert_eq(@tesseract.slab_through(c, 99).length(), 0)
  assert_eq(@tesseract.slab_through(c, 0 - 1).length(), 0)
  assert_eq(@tesseract.neighbours(c, 4).length(), 0)
  assert_eq(@tesseract.neighbours(c, 99).length(), 0)
  assert_eq(@tesseract.neighbours(c, 0 - 1).length(), 0)
  // An empty list is not the w-axis line in disguise.
  assert_eq(@tesseract.line_through(c, 9).length() == w_line.length(), false)
}

///|
test "text helpers: trim, parse and case folding" {
  assert_eq(@tesseract.trim_ws("  a b \n"), "a b")
  assert_eq(@tesseract.upper("aBc1"), "ABC1")
  assert_eq(@tesseract.lower("AbC1"), "abc1")
  assert_eq(@tesseract.parse_int("42"), Some(42))
  assert_eq(@tesseract.parse_int(" -7 "), Some(-7))
  assert_eq(@tesseract.parse_int("+3"), Some(3))
  assert_eq(@tesseract.parse_int("4 2"), None)
  assert_eq(@tesseract.parse_int(""), None)
  assert_eq(@tesseract.parse_int("-"), None)
  assert_eq(@tesseract.parse_int("0"), Some(0))
  assert_true(@tesseract.eq_ci("Key", "kEY"))
  assert_false(@tesseract.eq_ci("Key", "kEYs"))
  assert_true(@tesseract.starts_ci("SELECT", "sel"))
  assert_true(@tesseract.contains_ci("Hello World", "LO WO"))
}

///|
test "text helpers: split, join and slice keep empty fields" {
  assert_eq(@tesseract.split("a,b,,c", ","), ["a", "b", "", "c"])
  assert_eq(@tesseract.split("abc", ","), ["abc"])
  assert_eq(@tesseract.join(["a", "b"], "-"), "a-b")
  assert_eq(@tesseract.slice("abcdef", 1, 4), "bcd")
  assert_eq(@tesseract.slice("abc", 1, 99), "bc")
  assert_eq(@tesseract.slice("abc", 2, 2), "")
}
