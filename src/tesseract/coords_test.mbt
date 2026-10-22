///|
/// Geometry of the 4D lattice.
///
/// Every assertion here is about the *default* 3-per-axis lattice, so the
/// expected numbers stay exactly as they were. What changed is where they come
/// from: the hardcoded `81`, `82` and `27` are now read off the lattice, so the
/// same assertions keep their meaning at any side rather than silently
/// describing a 3-per-axis world.
test "index and position round-trip over all 81 cells" {
  let lat = @tesseract.default_lattice()
  let mut checked = 0L
  for c in @tesseract.all_coords(lat) {
    let p = @tesseract.position_of(lat, c)
    assert_true(@tesseract.position_in_bounds(lat, p))
    assert_eq(@tesseract.coords_of(lat, p), Some(c))
    assert_eq(@tesseract.index0(lat, c), p - 1L)
    checked = checked + 1
  }
  assert_eq(checked, lat.total)
}

///|
test "positions outside the lattice are rejected, not clamped" {
  let lat = @tesseract.default_lattice()
  assert_eq(@tesseract.coords_of(lat, 0L), None)
  assert_eq(@tesseract.coords_of(lat, lat.last_position + 1L), None)
  assert_eq(@tesseract.coords_of(lat, -1L), None)
  assert_true(@tesseract.position_in_bounds(lat, lat.first_position))
  assert_true(@tesseract.position_in_bounds(lat, lat.last_position))
  assert_false(@tesseract.position_in_bounds(lat, 0L))
  assert_false(@tesseract.position_in_bounds(lat, lat.last_position + 1L))
}

///|
test "coordinates outside 0..side-1 are rejected" {
  let lat = @tesseract.default_lattice()
  assert_false(
    @tesseract.coords_in_bounds(lat, @tesseract.coords(3L, 0L, 0L, 0L)),
  )
  assert_false(
    @tesseract.coords_in_bounds(lat, @tesseract.coords(0L, -1L, 0L, 0L)),
  )
  assert_false(
    @tesseract.coords_in_bounds(lat, @tesseract.coords(0L, 0L, 0L, 3L)),
  )
  assert_true(
    @tesseract.coords_in_bounds(lat, @tesseract.coords(2L, 2L, 2L, 2L)),
  )
}

///|
test "the lattice corners sit at the ends of the row-major order" {
  let lat = @tesseract.default_lattice()
  assert_eq(
    @tesseract.coords_of(lat, 1L),
    Some(@tesseract.coords(0L, 0L, 0L, 0L)),
  )
  assert_eq(
    @tesseract.coords_of(lat, lat.total),
    Some(@tesseract.coords(2L, 2L, 2L, 2L)),
  )
  assert_eq(
    @tesseract.coords_of(lat, 28L),
    Some(@tesseract.coords(1L, 0L, 0L, 0L)),
  )
}

///|
test "coords format and parse agree, with and without parentheses" {
  let lat = @tesseract.default_lattice()
  let c = @tesseract.coords(1L, 0L, 2L, 1L)
  assert_eq(@tesseract.format_coords(c), "(1,0,2,1)")
  assert_eq(@tesseract.parse_coords(lat, "(1,0,2,1)"), Some(c))
  assert_eq(@tesseract.parse_coords(lat, "1,0,2,1"), Some(c))
  assert_eq(@tesseract.parse_coords(lat, " ( 1 , 0 , 2 , 1 ) "), Some(c))
}

///|
test "a malformed address never silently resolves to another cell" {
  let lat = @tesseract.default_lattice()
  assert_eq(@tesseract.parse_coords(lat, "(1,0,2)"), None)
  assert_eq(@tesseract.parse_coords(lat, "(1,0,2,1,0)"), None)
  assert_eq(@tesseract.parse_coords(lat, "(3,0,2,1)"), None)
  assert_eq(@tesseract.parse_coords(lat, "(-1,0,2,1)"), None)
  assert_eq(@tesseract.parse_coords(lat, "(a,0,2,1)"), None)
  assert_eq(@tesseract.parse_coords(lat, ""), None)
}

///|
test "neighbours are bounded, never wrapped" {
  let lat = @tesseract.default_lattice()
  assert_eq(
    @tesseract.neighbours(lat, @tesseract.coords(0L, 0L, 0L, 0L), 0L).length(),
    1,
  )
  assert_eq(
    @tesseract.neighbours(lat, @tesseract.coords(2L, 2L, 2L, 2L), 0L).length(),
    1,
  )
  assert_eq(
    @tesseract.neighbours(lat, @tesseract.coords(1L, 1L, 1L, 1L), 3L).length(),
    2,
  )
  let n = @tesseract.neighbours(lat, @tesseract.coords(0L, 0L, 0L, 0L), 0L)
  assert_eq(n[0], @tesseract.coords(1L, 0L, 0L, 0L))
  let m = @tesseract.neighbours(lat, @tesseract.coords(0L, 0L, 0L, 0L), 3L)
  assert_eq(m[0], @tesseract.coords(0L, 0L, 0L, 1L))
}

///|
test "two cells share a line exactly when they agree on three coordinates" {
  let a = @tesseract.coords(1L, 2L, 0L, 1L)
  assert_true(@tesseract.shares_line(a, @tesseract.coords(1L, 2L, 2L, 1L)))
  assert_true(@tesseract.shares_line(a, a))
  assert_false(@tesseract.shares_line(a, @tesseract.coords(0L, 0L, 0L, 0L)))
  assert_false(@tesseract.shares_line(a, @tesseract.coords(1L, 2L, 1L, 0L)))
  assert_true(
    @tesseract.shares_line(
      @tesseract.coords(0L, 0L, 0L, 0L),
      @tesseract.coords(1L, 0L, 0L, 0L),
    ),
  )
}

///|
test "coord_at and with_coord agree on all four axes" {
  let c = @tesseract.coords(1L, 2L, 0L, 1L)
  assert_eq(@tesseract.coord_at(c, 0L).unwrap(), 1L)
  assert_eq(@tesseract.coord_at(c, 1L).unwrap(), 2L)
  assert_eq(@tesseract.coord_at(c, 2L).unwrap(), 0L)
  assert_eq(@tesseract.coord_at(c, 3L).unwrap(), 1L)
  let axis = 2L
  let moved = @tesseract.with_coord(c, axis, 2L)
  assert_eq(@tesseract.coord_at(moved, axis).unwrap(), 2L)
  assert_eq(@tesseract.coord_at(moved, 0L).unwrap(), 1L)
  assert_eq(@tesseract.coord_at(moved, 1L).unwrap(), 2L)
  assert_eq(@tesseract.coord_at(moved, 3L).unwrap(), 1L)
}

///|
test "an axis outside the lattice is reported, not answered as the last one" {
  // `w` is 2 in this cell, so a fallthrough would hand back 2 for every one of
  // these and look like a real coordinate.
  let c = @tesseract.coords(1L, 2L, 0L, 2L)
  assert_eq(@tesseract.coord_at(c, 0L), Some(1L))
  assert_eq(@tesseract.coord_at(c, 1L), Some(2L))
  assert_eq(@tesseract.coord_at(c, 2L), Some(0L))
  assert_eq(@tesseract.coord_at(c, 3L), Some(2L))
  // Above the last axis, below zero, and far out of range.
  assert_eq(@tesseract.coord_at(c, 4L), None)
  assert_eq(@tesseract.coord_at(c, 7L), None)
  assert_eq(@tesseract.coord_at(c, 99L), None)
  assert_eq(@tesseract.coord_at(c, 0L - 1L), None)
  assert_eq(@tesseract.coord_at(c, 0L - 99L), None)
  // The boundary is the axis count, not a hardcoded 3 or 4.
  assert_eq(@tesseract.coord_at(c, @tesseract.DIM), None)
  assert_eq(@tesseract.coord_at(c, @tesseract.DIM - 1L), Some(2L))
}

///|
test "the geometry helpers refuse an axis they do not have" {
  // Each of these used to answer with the w-axis geometry, reporting it as the
  // axis that was asked for.
  let lat = @tesseract.default_lattice()
  let c = @tesseract.coords(1L, 2L, 0L, 2L)
  let w_line = @tesseract.line_through(lat, c, 3L)
  let w_slab = @tesseract.slab_through(lat, c, 3L)
  // Controls: the valid axes still work, so an empty list below means "bad
  // axis" rather than "this shape happens to be empty". `w` is 2 here, so
  // axis 3 sits at the end of its axis and has one neighbour; axis 0 is
  // x=1, in the middle, and has two.
  assert_eq(w_line.length(), 3)
  assert_eq(w_slab.length(), 27)
  assert_eq(@tesseract.neighbours(lat, c, 3L).length(), 1)
  assert_eq(@tesseract.neighbours(lat, c, 0L).length(), 2)
  assert_eq(
    @tesseract.line_through(lat, c, 3L)[0],
    @tesseract.coords(1L, 2L, 0L, 0L),
  )
  // Now the bad axes.
  assert_eq(@tesseract.line_through(lat, c, 4L).length(), 0)
  assert_eq(@tesseract.line_through(lat, c, 99L).length(), 0)
  assert_eq(@tesseract.line_through(lat, c, 0L - 1L).length(), 0)
  assert_eq(@tesseract.slab_through(lat, c, 4L).length(), 0)
  assert_eq(@tesseract.slab_through(lat, c, 99L).length(), 0)
  assert_eq(@tesseract.slab_through(lat, c, 0L - 1L).length(), 0)
  assert_eq(@tesseract.neighbours(lat, c, 4L).length(), 0)
  assert_eq(@tesseract.neighbours(lat, c, 99L).length(), 0)
  assert_eq(@tesseract.neighbours(lat, c, 0L - 1L).length(), 0)
  // An empty list is not the w-axis line in disguise.
  assert_eq(
    @tesseract.line_through(lat, c, 9L).length() == w_line.length(),
    false,
  )
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

///|
/// Texts are ordered by their letters, not by their length.
///
/// The runtime's own `String::compare` compares the lengths first, so "work"
/// comes **before** "default" — the shorter text wins whatever its letters
/// say. A store that promises its keys "in order" has to mean the order of the
/// letters, or the promise is not the one a reader reads.
test "texts are ordered by their letters, not by their length" {
  assert_true(@tesseract.compare_text("default", "work") < 0)
  assert_true(@tesseract.compare_text("work", "default") > 0)
  assert_true(@tesseract.compare_text("cat", "cow") < 0)
  assert_true(@tesseract.compare_text("cow", "cat") > 0)
  assert_eq(@tesseract.compare_text("same", "same"), 0)
  // A prefix comes first.
  assert_true(@tesseract.compare_text("apple", "apples") < 0)
  assert_true(@tesseract.compare_text("apples", "apple") > 0)
  // And a character outside the basic plane is one thing to compare, not two
  // halves of one thing.
  assert_true(@tesseract.compare_text("a", "🍎") < 0)
  assert_true(@tesseract.compare_text("🍎", "a") > 0)
  // The order is antisymmetric: one way is the other way backwards.
  assert_eq(
    @tesseract.compare_text("default", "work"),
    -@tesseract.compare_text("work", "default"),
  )
}

///|
/// A decimal is parsed, and everything else is refused.
///
/// The grammar is a plain decimal: a sign, digits, and a fractional part.
/// There is no exponent and no hexadecimal, and a number that is not one is
/// `None` rather than a silent zero — the same rule `parse_int` follows.
test "a decimal is parsed, and everything else is refused" {
  assert_eq(@tesseract.parse_float("0.5"), Some(0.5))
  assert_eq(@tesseract.parse_float("1"), Some(1.0))
  assert_eq(@tesseract.parse_float("1.0"), Some(1.0))
  assert_eq(@tesseract.parse_float("-2.25"), Some(-2.25))
  assert_eq(@tesseract.parse_float("+0.5"), Some(0.5))
  assert_eq(@tesseract.parse_float(" 0.5 "), Some(0.5))
  assert_eq(@tesseract.parse_float(".5"), Some(0.5))
  assert_eq(@tesseract.parse_float("3."), Some(3.0))
  // And what is not a number is refused.
  assert_eq(@tesseract.parse_float(""), None)
  assert_eq(@tesseract.parse_float("abc"), None)
  assert_eq(@tesseract.parse_float("1e3"), None)
  assert_eq(@tesseract.parse_float("1.2.3"), None)
  assert_eq(@tesseract.parse_float("0x10"), None)
  assert_eq(@tesseract.parse_float("."), None)
  assert_eq(@tesseract.parse_float("-"), None)
  assert_eq(@tesseract.parse_float("1 2"), None)
  // A number too long to be exact is refused rather than rounded.
  assert_eq(@tesseract.parse_float("0.1234567890123456789"), None)
}

///|
/// A character outside the basic plane survives the text helpers.
///
/// An emoji is two code units in the runtime's string and one character to a
/// reader, and half of a character is not a character: copying code units one
/// at a time **dropped** it. A value is an opaque blob that has to survive a
/// round trip byte-for-byte, so an emoji that went through `lower`, `upper`
/// or `slice` and came back shorter was a value that had been corrupted.
test "a character outside the basic plane survives the text helpers" {
  // The character is kept, and it is still one character.
  assert_eq(@tesseract.lower("🍎"), "🍎")
  assert_eq(@tesseract.upper("🍎"), "🍎")
  assert_eq(@tesseract.slice("🍎", 0, 2), "🍎")
  assert_eq(@tesseract.slice("a🍎b", 1, 3), "🍎")
  assert_eq(@tesseract.slice("a🍎b", 0, 4), "a🍎b")
  // The folding is still ASCII-only, and it does not disturb the rest.
  assert_eq(@tesseract.lower("Ab🍎C"), "ab🍎c")
  assert_eq(@tesseract.upper("ab🍎c"), "AB🍎C")
  // A range that covers only one half of the character cannot keep it: there
  // is no such thing as half a character.
  assert_eq(@tesseract.slice("🍎", 0, 1), "")
  // And the character is two code units wide, which is what `char_at` says.
  let (ch, next) = @tesseract.char_at("🍎", 0)
  assert_eq(ch.to_string(), "🍎")
  assert_eq(next, 2)
  let (ascii, after) = @tesseract.char_at("a", 0)
  assert_eq(ascii.to_string(), "a")
  assert_eq(after, 1)
}
