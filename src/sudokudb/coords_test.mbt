///|
/// Geometry of the 3x3x3x3 lattice.
test "index and position round-trip over all 81 cells" {
  let mut checked = 0
  for c in @sudokudb.all_coords() {
    let p = @sudokudb.position_of(c)
    assert_true(@sudokudb.position_in_bounds(p))
    assert_eq(@sudokudb.coords_of(p), Some(c))
    assert_eq(@sudokudb.index0(c), p - 1)
    checked = checked + 1
  }
  assert_eq(checked, @sudokudb.TOTAL)
}

///|
test "positions outside 1..81 are rejected, not clamped" {
  assert_eq(@sudokudb.coords_of(0), None)
  assert_eq(@sudokudb.coords_of(82), None)
  assert_eq(@sudokudb.coords_of(-1), None)
  assert_true(@sudokudb.position_in_bounds(@sudokudb.FIRST_POSITION))
  assert_true(@sudokudb.position_in_bounds(@sudokudb.LAST_POSITION))
  assert_false(@sudokudb.position_in_bounds(0))
  assert_false(@sudokudb.position_in_bounds(82))
}

///|
test "coordinates outside 0..2 are rejected" {
  assert_false(@sudokudb.coords_in_bounds(@sudokudb.coords(3, 0, 0, 0)))
  assert_false(@sudokudb.coords_in_bounds(@sudokudb.coords(0, -1, 0, 0)))
  assert_false(@sudokudb.coords_in_bounds(@sudokudb.coords(0, 0, 0, 3)))
  assert_true(@sudokudb.coords_in_bounds(@sudokudb.coords(2, 2, 2, 2)))
}

///|
test "the lattice corners sit at the ends of the row-major order" {
  assert_eq(@sudokudb.coords_of(1), Some(@sudokudb.coords(0, 0, 0, 0)))
  assert_eq(
    @sudokudb.coords_of(@sudokudb.TOTAL),
    Some(@sudokudb.coords(2, 2, 2, 2)),
  )
  assert_eq(@sudokudb.coords_of(28), Some(@sudokudb.coords(1, 0, 0, 0)))
}

///|
test "coords format and parse agree, with and without parentheses" {
  let c = @sudokudb.coords(1, 0, 2, 1)
  assert_eq(@sudokudb.format_coords(c), "(1,0,2,1)")
  assert_eq(@sudokudb.parse_coords("(1,0,2,1)"), Some(c))
  assert_eq(@sudokudb.parse_coords("1,0,2,1"), Some(c))
  assert_eq(@sudokudb.parse_coords(" ( 1 , 0 , 2 , 1 ) "), Some(c))
}

///|
test "a malformed address never silently resolves to another cell" {
  assert_eq(@sudokudb.parse_coords("(1,0,2)"), None)
  assert_eq(@sudokudb.parse_coords("(1,0,2,1,0)"), None)
  assert_eq(@sudokudb.parse_coords("(3,0,2,1)"), None)
  assert_eq(@sudokudb.parse_coords("(-1,0,2,1)"), None)
  assert_eq(@sudokudb.parse_coords("(a,0,2,1)"), None)
  assert_eq(@sudokudb.parse_coords(""), None)
}

///|
test "neighbours are bounded, never wrapped" {
  assert_eq(@sudokudb.neighbours(@sudokudb.coords(0, 0, 0, 0), 0).length(), 1)
  assert_eq(@sudokudb.neighbours(@sudokudb.coords(2, 2, 2, 2), 0).length(), 1)
  assert_eq(@sudokudb.neighbours(@sudokudb.coords(1, 1, 1, 1), 3).length(), 2)
  let n = @sudokudb.neighbours(@sudokudb.coords(0, 0, 0, 0), 0)
  assert_eq(n[0], @sudokudb.coords(1, 0, 0, 0))
  let m = @sudokudb.neighbours(@sudokudb.coords(0, 0, 0, 0), 3)
  assert_eq(m[0], @sudokudb.coords(0, 0, 0, 1))
}

///|
test "two cells share a line exactly when they agree on three coordinates" {
  let a = @sudokudb.coords(1, 2, 0, 1)
  assert_true(@sudokudb.shares_line(a, @sudokudb.coords(1, 2, 2, 1)))
  assert_true(@sudokudb.shares_line(a, a))
  assert_false(@sudokudb.shares_line(a, @sudokudb.coords(0, 0, 0, 0)))
  assert_false(@sudokudb.shares_line(a, @sudokudb.coords(1, 2, 1, 0)))
  assert_true(
    @sudokudb.shares_line(
      @sudokudb.coords(0, 0, 0, 0),
      @sudokudb.coords(1, 0, 0, 0),
    ),
  )
}

///|
test "coord_at and with_coord agree on all four axes" {
  let c = @sudokudb.coords(1, 2, 0, 1)
  assert_eq(@sudokudb.coord_at(c, 0), 1)
  assert_eq(@sudokudb.coord_at(c, 1), 2)
  assert_eq(@sudokudb.coord_at(c, 2), 0)
  assert_eq(@sudokudb.coord_at(c, 3), 1)
  let axis = 2
  let moved = @sudokudb.with_coord(c, axis, 2)
  assert_eq(@sudokudb.coord_at(moved, axis), 2)
  assert_eq(@sudokudb.coord_at(moved, 0), 1)
  assert_eq(@sudokudb.coord_at(moved, 1), 2)
  assert_eq(@sudokudb.coord_at(moved, 3), 1)
}

///|
test "text helpers: trim, parse and case folding" {
  assert_eq(@sudokudb.trim_ws("  a b \n"), "a b")
  assert_eq(@sudokudb.upper("aBc1"), "ABC1")
  assert_eq(@sudokudb.lower("AbC1"), "abc1")
  assert_eq(@sudokudb.parse_int("42"), Some(42))
  assert_eq(@sudokudb.parse_int(" -7 "), Some(-7))
  assert_eq(@sudokudb.parse_int("+3"), Some(3))
  assert_eq(@sudokudb.parse_int("4 2"), None)
  assert_eq(@sudokudb.parse_int(""), None)
  assert_eq(@sudokudb.parse_int("-"), None)
  assert_eq(@sudokudb.parse_int("0"), Some(0))
  assert_true(@sudokudb.eq_ci("Key", "kEY"))
  assert_false(@sudokudb.eq_ci("Key", "kEYs"))
  assert_true(@sudokudb.starts_ci("SELECT", "sel"))
  assert_true(@sudokudb.contains_ci("Hello World", "LO WO"))
}

///|
test "text helpers: split, join and slice keep empty fields" {
  assert_eq(@sudokudb.split("a,b,,c", ","), ["a", "b", "", "c"])
  assert_eq(@sudokudb.split("abc", ","), ["abc"])
  assert_eq(@sudokudb.join(["a", "b"], "-"), "a-b")
  assert_eq(@sudokudb.slice("abcdef", 1, 4), "bcd")
  assert_eq(@sudokudb.slice("abc", 1, 99), "bc")
  assert_eq(@sudokudb.slice("abc", 2, 2), "")
}
