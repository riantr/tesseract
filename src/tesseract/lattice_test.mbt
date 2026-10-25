///|
/// Sudoku sub-structures, checked as complete partitions rather than subsets.
///
/// The counts here are the 3-per-axis ones (108 lines, 12 slabs of 27, 8
/// peers); they are written out literally so the test still says what it
/// checked. Everything the *shape* of the assertion depends on is read off the
/// lattice instead, so the partition argument keeps working at another side.
test "there are 108 lines of 3 cells, and every cell lies on exactly 4" {
  let lat = @tesseract.default_lattice()
  let lines = @tesseract.all_lines(lat)
  assert_eq(
    lines.length().to_int64(),
    @tesseract.DIM * lat.total() / lat.side(),
  )
  assert_eq(lines.length(), 108)
  let counts = @tesseract.empty_digits(lat)
  let mut i = 0
  while i < lines.length() {
    assert_eq(lines[i].length().to_int64(), lat.side())
    let mut j = 0
    while j < lines[i].length() {
      let slot = @tesseract.index0(lat, lines[i][j]).to_int()
      counts[slot] = counts[slot] + 1L
      j = j + 1
    }
    i = i + 1
  }
  let mut wrong = 0
  let mut k = 0L
  while k < lat.total() {
    if counts[k.to_int()] != @tesseract.DIM {
      wrong = wrong + 1
    }
    k = k + 1L
  }
  assert_eq(wrong, 0)
}

///|
test "no two lines are the same set of cells" {
  let lat = @tesseract.default_lattice()
  let lines = @tesseract.all_lines(lat)
  let seen : Array[String] = []
  let mut duplicates = 0
  let mut i = 0
  while i < lines.length() {
    let key = @tesseract.line_key(lines[i])
    if seen.contains(key) {
      duplicates = duplicates + 1
    } else {
      seen.push(key)
    }
    i = i + 1
  }
  assert_eq(duplicates, 0)
  assert_eq(seen.length(), 108)
}

///|
test "there are 12 slabs of 27 cells" {
  let lat = @tesseract.default_lattice()
  let slabs = @tesseract.all_slabs(lat)
  assert_eq(slabs.length().to_int64(), @tesseract.DIM * lat.side())
  assert_eq(slabs.length(), 12)
  let mut i = 0
  while i < slabs.length() {
    assert_eq(slabs[i].length().to_int64(), lat.total() / lat.side())
    i = i + 1
  }
}

///|
test "every cell lies in exactly 4 slabs, one per axis" {
  let lat = @tesseract.default_lattice()
  let counts = @tesseract.empty_digits(lat)
  let mut axis = 0L
  while axis < @tesseract.DIM {
    let mut v = 0L
    while v < lat.side() {
      let anchor = @tesseract.with_coord(
        @tesseract.coords(0L, 0L, 0L, 0L),
        axis,
        v,
      )
      for cell in @tesseract.slab_through(lat, anchor, axis) {
        let slot = @tesseract.index0(lat, cell).to_int()
        counts[slot] = counts[slot] + 1L
      }
      v = v + 1L
    }
    axis = axis + 1L
  }
  let mut wrong = 0
  let mut k = 0L
  while k < lat.total() {
    if counts[k.to_int()] != @tesseract.DIM {
      wrong = wrong + 1
    }
    k = k + 1L
  }
  assert_eq(wrong, 0)
}

///|
/// The line count is the number of lines.
///
/// `sudoku_line_count` is the count of `all_lines`, without building the
/// lines. If the two ever disagree, the count is a number that cannot be
/// checked against the thing it counts — and the two command-line tools
/// that report it would be reporting a number nothing in the library
/// vouches for.
test "the line count is the number of lines" {
  let lat = @tesseract.default_lattice()
  assert_eq(
    @tesseract.sudoku_line_count(lat),
    @tesseract.all_lines(lat).length().to_int64(),
  )
  assert_eq(@tesseract.sudoku_line_count(lat), 108L)
}

///|
test "the 12 slabs are 12 distinct cell sets" {
  let lat = @tesseract.default_lattice()
  let slabs = @tesseract.all_slabs(lat)
  let seen : Array[String] = []
  let mut duplicates = 0
  let mut i = 0
  while i < slabs.length() {
    let parts : Array[String] = []
    let mut j = 0
    while j < slabs[i].length() {
      parts.push(@tesseract.format_coords(slabs[i][j]))
      j = j + 1
    }
    let key = @tesseract.join(parts, "|")
    if seen.contains(key) {
      duplicates = duplicates + 1
    } else {
      seen.push(key)
    }
    i = i + 1
  }
  assert_eq(duplicates, 0)
  assert_eq(seen.length(), 12)
}

///|
test "each cell has 8 peers, all sharing a line with it" {
  let lat = @tesseract.default_lattice()
  assert_eq(@tesseract.peer_count(lat), 8)
  for c in @tesseract.all_coords(lat) {
    let ps = @tesseract.peers(lat, c)
    assert_eq(ps.length().to_int64(), @tesseract.peer_count(lat))
    assert_false(ps.contains(c))
    let mut i = 0
    while i < ps.length() {
      assert_true(@tesseract.shares_line(c, ps[i]))
      i = i + 1
    }
  }
}

///|
test "a plane fixes two axes and holds 9 cells" {
  let lat = @tesseract.default_lattice()
  let plane = match
    @tesseract.plane_through(lat, @tesseract.coords(1L, 2L, 0L, 1L), 0L, 2L) {
    Ok(p) => p
    Err(message) => {
      assert_true(false)
      ignore(message)
      []
    }
  }
  assert_eq(plane.length().to_int64(), lat.total() / (lat.side() * lat.side()))
  assert_eq(plane.length(), 9)
  let mut off_axis = 0
  let mut i = 0
  while i < plane.length() {
    if plane[i].x != 1L || plane[i].z != 0L {
      off_axis = off_axis + 1
    }
    i = i + 1
  }
  assert_eq(off_axis, 0)
}

///|
test "a plane refuses the same axis twice instead of returning a slab" {
  let lat = @tesseract.default_lattice()
  let c = @tesseract.coords(1L, 2L, 0L, 1L)
  // Both constraints collapse onto one axis, so the 27-cell slab came back from
  // a call that asked about a 9-cell plane.
  let same = match @tesseract.plane_through(lat, c, 2L, 2L) {
    Ok(p) => p
    Err(_) => []
  }
  assert_eq(same.length(), 0)
  let out_of_range = match @tesseract.plane_through(lat, c, 0L, 9L) {
    Ok(p) => p
    Err(_) => []
  }
  assert_eq(out_of_range.length(), 0)
  // ...and a genuinely distinct pair still works.
  let ok = match @tesseract.plane_through(lat, c, 0L, 2L) {
    Ok(p) => p
    Err(_) => []
  }
  assert_eq(ok.length(), 9)
}

///|
test "free_axis_of recovers the axis a line varies along" {
  let lat = @tesseract.default_lattice()
  let mut axis = 0L
  while axis < @tesseract.DIM {
    let line = @tesseract.line_through(
      lat,
      @tesseract.coords(1L, 1L, 1L, 1L),
      axis,
    )
    assert_eq(@tesseract.free_axis_of(line), axis)
    axis = axis + 1L
  }
}

///|
/// The line count is `DIM * side^3`, so the loop above would silently check a
/// different number of lines at another side without this.
test "line and slab counts follow the side, not a constant" {
  let mut side = 1L
  while side <= 4L {
    let lat = match @tesseract.lattice_of(side) {
      Ok(l) => l
      Err(_) => {
        assert_true(false)
        @tesseract.default_lattice()
      }
    }
    assert_eq(
      @tesseract.all_lines(lat).length().to_int64(),
      @tesseract.DIM * lat.side() * lat.side() * lat.side(),
    )
    assert_eq(
      @tesseract.all_slabs(lat).length().to_int64(),
      @tesseract.DIM * lat.side(),
    )
    assert_eq(@tesseract.peer_count(lat), @tesseract.DIM * (lat.side() - 1L))
    assert_eq(@tesseract.all_coords(lat).length().to_int64(), lat.total())
    side = side + 1L
  }
}
