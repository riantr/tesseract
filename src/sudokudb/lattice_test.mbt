///|
/// Sudoku sub-structures, checked as complete partitions rather than subsets.
test "there are 108 lines of 3 cells, and every cell lies on exactly 4" {
  let lines = @sudokudb.all_lines()
  assert_eq(lines.length(), @sudokudb.DIM * 27)
  assert_eq(lines.length(), 108)
  let counts = @sudokudb.empty_digits()
  let mut i = 0
  while i < lines.length() {
    assert_eq(lines[i].length(), @sudokudb.SIDE)
    let mut j = 0
    while j < lines[i].length() {
      counts[@sudokudb.index0(lines[i][j])] = counts[@sudokudb.index0(
          lines[i][j],
        )] +
        1
      j = j + 1
    }
    i = i + 1
  }
  let mut wrong = 0
  let mut k = 0
  while k < @sudokudb.TOTAL {
    if counts[k] != @sudokudb.DIM {
      wrong = wrong + 1
    }
    k = k + 1
  }
  assert_eq(wrong, 0)
}

///|
test "no two lines are the same set of cells" {
  let lines = @sudokudb.all_lines()
  let seen : Array[String] = []
  let mut duplicates = 0
  let mut i = 0
  while i < lines.length() {
    let key = @sudokudb.line_key(lines[i])
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
  let slabs = @sudokudb.all_slabs()
  assert_eq(slabs.length(), @sudokudb.DIM * @sudokudb.SIDE)
  assert_eq(slabs.length(), 12)
  let mut i = 0
  while i < slabs.length() {
    assert_eq(slabs[i].length(), 27)
    i = i + 1
  }
}

///|
test "every cell lies in exactly 4 slabs, one per axis" {
  let counts = @sudokudb.empty_digits()
  let mut axis = 0
  while axis < @sudokudb.DIM {
    let mut v = 0
    while v < @sudokudb.SIDE {
      let anchor = @sudokudb.with_coord(@sudokudb.coords(0, 0, 0, 0), axis, v)
      for cell in @sudokudb.slab_through(anchor, axis) {
        counts[@sudokudb.index0(cell)] = counts[@sudokudb.index0(cell)] + 1
      }
      v = v + 1
    }
    axis = axis + 1
  }
  let mut wrong = 0
  let mut k = 0
  while k < @sudokudb.TOTAL {
    if counts[k] != @sudokudb.DIM {
      wrong = wrong + 1
    }
    k = k + 1
  }
  assert_eq(wrong, 0)
}

///|
test "the 12 slabs are 12 distinct cell sets" {
  let slabs = @sudokudb.all_slabs()
  let seen : Array[String] = []
  let mut duplicates = 0
  let mut i = 0
  while i < slabs.length() {
    let parts : Array[String] = []
    let mut j = 0
    while j < slabs[i].length() {
      parts.push(@sudokudb.format_coords(slabs[i][j]))
      j = j + 1
    }
    let key = @sudokudb.join(parts, "|")
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
  assert_eq(@sudokudb.peer_count(), 8)
  for c in @sudokudb.all_coords() {
    let ps = @sudokudb.peers(c)
    assert_eq(ps.length(), 8)
    assert_false(ps.contains(c))
    let mut i = 0
    while i < ps.length() {
      assert_true(@sudokudb.shares_line(c, ps[i]))
      i = i + 1
    }
  }
}

///|
test "a plane fixes two axes and holds 9 cells" {
  let plane = match
    @sudokudb.plane_through(@sudokudb.coords(1, 2, 0, 1), 0, 2) {
    Ok(p) => p
    Err(message) => {
      assert_true(false)
      ignore(message)
      []
    }
  }
  assert_eq(plane.length(), 9)
  let mut off_axis = 0
  let mut i = 0
  while i < plane.length() {
    if plane[i].x != 1 || plane[i].z != 0 {
      off_axis = off_axis + 1
    }
    i = i + 1
  }
  assert_eq(off_axis, 0)
}

///|
test "a plane refuses the same axis twice instead of returning a slab" {
  let c = @sudokudb.coords(1, 2, 0, 1)
  // Both constraints collapse onto one axis, so the 27-cell slab came back from
  // a call that asked about a 9-cell plane.
  let same = match @sudokudb.plane_through(c, 2, 2) {
    Ok(p) => p
    Err(_) => []
  }
  assert_eq(same.length(), 0)
  let out_of_range = match @sudokudb.plane_through(c, 0, 9) {
    Ok(p) => p
    Err(_) => []
  }
  assert_eq(out_of_range.length(), 0)
  // ...and a genuinely distinct pair still works.
  let ok = match @sudokudb.plane_through(c, 0, 2) {
    Ok(p) => p
    Err(_) => []
  }
  assert_eq(ok.length(), 9)
}

///|
test "free_axis_of recovers the axis a line varies along" {
  for axis in [0, 1, 2, 3] {
    let line = @sudokudb.line_through(@sudokudb.coords(1, 1, 1, 1), axis)
    assert_eq(@sudokudb.free_axis_of(line), axis)
  }
}
