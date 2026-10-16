///|
/// The sudoku constraint layer.
///
/// The claim worth testing hardest is the one written down as a consequence
/// rather than a rule: that the line rule *implies* slab balance. It is
/// checked on solutions found by independent backtracking, not only on the
/// closed form, because a single known-good fixture cannot distinguish
/// "balance follows from the rule" from "this one fixture happens to balance".
test "the closed-form solution satisfies both line and slab constraints" {
  let lat = @tesseract.default_lattice()
  let d = @tesseract.canonical_digits(lat)
  assert_eq(@tesseract.line_violations(lat, d).length(), 0)
  assert_eq(@tesseract.slab_violations(lat, d).length(), 0)
  assert_true(@tesseract.is_solution(lat, d))
}

///|
test "canonical digits are never 0 and stay in 1..side" {
  let lat = @tesseract.default_lattice()
  let d = @tesseract.canonical_digits(lat)
  let mut bad = 0
  let mut i = 0
  while i < d.length() {
    if d[i] < 1L || d[i] > lat.max_digit {
      bad = bad + 1
    }
    i = i + 1
  }
  assert_eq(bad, 0)
}

///|
test "backtracking finds independent solutions, each line-valid" {
  let lat = @tesseract.default_lattice()
  let solutions = @tesseract.solve_lattice(lat, 3L)
  assert_eq(solutions.length(), 3)
  let mut i = 0
  while i < solutions.length() {
    assert_eq(@tesseract.line_violations(lat, solutions[i]).length(), 0)
    i = i + 1
  }
}

///|
test "backtracking solutions are not all the closed form" {
  let lat = @tesseract.default_lattice()
  let solutions = @tesseract.solve_lattice(lat, 3L)
  let canonical = @tesseract.canonical_digits(lat)
  let mut identical = 0
  let mut i = 0
  while i < solutions.length() {
    let mut same = true
    let mut k = 0
    while k < canonical.length() {
      if solutions[i][k] != canonical[k] {
        same = false
      }
      k = k + 1
    }
    if same {
      identical = identical + 1
    }
    i = i + 1
  }
  assert_eq(identical, 1)
}

///|
test "slab balance follows from the line rule on independent solutions" {
  let lat = @tesseract.default_lattice()
  let solutions = @tesseract.solve_lattice(lat, 5L)
  assert_eq(solutions.length(), 5)
  let mut i = 0
  while i < solutions.length() {
    assert_eq(@tesseract.line_violations(lat, solutions[i]).length(), 0)
    assert_eq(@tesseract.slab_violations(lat, solutions[i]).length(), 0)
    i = i + 1
  }
}

///|
test "the checker actually catches a broken line" {
  let lat = @tesseract.default_lattice()
  let d = @tesseract.canonical_digits(lat)
  assert_eq(@tesseract.line_violations(lat, d).length(), 0)
  @tesseract.set_digit(lat, d, 2L, @tesseract.digit_at(lat, d, 1L))
  assert_true(@tesseract.line_violations(lat, d).length() > 0)
  assert_false(@tesseract.is_solution(lat, d))
}

///|
test "a line of identical digits is reported once per line, not per cell" {
  let lat = @tesseract.default_lattice()
  let d = @tesseract.empty_digits(lat)
  @tesseract.set_digit(lat, d, 1L, 2L)
  @tesseract.set_digit(lat, d, 2L, 2L)
  @tesseract.set_digit(lat, d, 3L, 2L)
  assert_eq(@tesseract.line_violations(lat, d).length(), 1)
}

///|
test "an empty lattice has no violations" {
  let lat = @tesseract.default_lattice()
  let d = @tesseract.empty_digits(lat)
  assert_eq(@tesseract.line_violations(lat, d).length(), 0)
  assert_eq(@tesseract.slab_violations(lat, d).length(), 0)
}

///|
test "digit_at ignores out-of-range positions instead of trapping" {
  let lat = @tesseract.default_lattice()
  let d = @tesseract.canonical_digits(lat)
  assert_eq(@tesseract.digit_at(lat, d, 0L), @tesseract.NO_DIGIT)
  assert_eq(
    @tesseract.digit_at(lat, d, lat.last_position + 1L),
    @tesseract.NO_DIGIT,
  )
  assert_true(@tesseract.digit_at(lat, d, 1L) >= 1L)
}

///|
test "the canonical solution shifts by one along every axis" {
  let lat = @tesseract.default_lattice()
  let d = @tesseract.canonical_digits(lat)
  let mut axis = 0L
  while axis < @tesseract.DIM {
    for c in @tesseract.all_coords(lat) {
      // The loop bound is what makes these `Some`; `coord_at` itself is
      // checked and would answer None for an axis outside 0..DIM-1.
      let here_coord = @tesseract.coord_at(c, axis).unwrap()
      if here_coord < lat.side - 1L {
        let next = @tesseract.with_coord(c, axis, here_coord + 1L)
        let here = @tesseract.digit_at(lat, d, @tesseract.position_of(lat, c))
        let there = @tesseract.digit_at(
          lat,
          d,
          @tesseract.position_of(lat, next),
        )
        assert_eq(there, here % lat.side + 1L)
      }
    }
    axis = axis + 1L
  }
}

///|
test "every line of the canonical solution holds every digit" {
  let lat = @tesseract.default_lattice()
  let d = @tesseract.canonical_digits(lat)
  let mut incomplete = 0
  for line in @tesseract.all_lines(lat) {
    let seen : Array[Int64] = []
    let mut i = 0
    while i < line.length() {
      let digit = d[@tesseract.index0(lat, line[i]).to_int()]
      if !seen.contains(digit) {
        seen.push(digit)
      }
      i = i + 1
    }
    if seen.length().to_int64() != lat.side {
      incomplete = incomplete + 1
    }
  }
  assert_eq(incomplete, 0)
}

///|
/// A slab that is not full cannot be judged on balance.
///
/// The three existing slab tests all use a full or an empty lattice, so they
/// never reach the "is this slab complete?" branch. This one does: seven cells
/// are cleared out of the 27 in slab axis 0, leaving 20 filled. Nothing is
/// wrong with that lattice - the line check skips empty cells, and 20 is not a
/// multiple of 3, so no count distribution could be "balanced" for it.
test "a partially filled slab is not reported as imbalanced" {
  let lat = @tesseract.default_lattice()
  let d = @tesseract.canonical_digits(lat)
  let slab = @tesseract.slab_through(lat, @tesseract.coords(0L, 0L, 0L, 0L), 0L)
  assert_eq(slab.length(), 27)
  let mut i = 0
  while i < 7 {
    @tesseract.set_digit(
      lat,
      d,
      @tesseract.position_of(lat, slab[i]),
      @tesseract.NO_DIGIT,
    )
    i = i + 1
  }
  assert_eq(@tesseract.line_violations(lat, d).length(), 0)
  assert_eq(@tesseract.slab_violations(lat, d).length(), 0)
  assert_true(@tesseract.is_solution(lat, d))
}

///|
/// The rule the whole parameterisation rests on: `(x+y+z+w) mod side + 1`
/// steps by one along every axis for *any* side, so every line is a
/// permutation of `1..side` and the closed form is a solution everywhere.
///
/// `slab_violations` is included because it is the part that was written for
/// `side == 3`: its tally used to be a fixed 4-slot array, which addresses
/// digits 0..3 and so would go out of bounds on the very first cell at
/// `side == 4`.
test "the closed form is a solution at every side from 1 to 4" {
  let mut side = 1L
  while side <= 4L {
    let lat = match @tesseract.lattice_of(side) {
      Ok(l) => l
      Err(_) => {
        assert_true(false)
        @tesseract.default_lattice()
      }
    }
    let d = @tesseract.canonical_digits(lat)
    assert_eq(@tesseract.line_violations(lat, d).length(), 0)
    assert_eq(@tesseract.slab_violations(lat, d).length(), 0)
    assert_true(@tesseract.is_solution(lat, d))
    side = side + 1L
  }
}
