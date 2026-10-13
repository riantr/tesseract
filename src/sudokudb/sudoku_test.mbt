///|
/// The sudoku constraint layer.
///
/// The claim worth testing hardest is the one written down as a consequence
/// rather than a rule: that the line rule *implies* slab balance. It is
/// checked on solutions found by independent backtracking, not only on the
/// closed form, because a single known-good fixture cannot distinguish
/// "balance follows from the rule" from "this one fixture happens to balance".
test "the closed-form solution satisfies both line and slab constraints" {
  let d = @sudokudb.canonical_digits()
  assert_eq(@sudokudb.line_violations(d).length(), 0)
  assert_eq(@sudokudb.slab_violations(d).length(), 0)
  assert_true(@sudokudb.is_solution(d))
}

///|
test "canonical digits are never 0 and stay in 1..3" {
  let d = @sudokudb.canonical_digits()
  let mut bad = 0
  let mut i = 0
  while i < @sudokudb.TOTAL {
    if d[i] < 1 || d[i] > @sudokudb.MAX_DIGIT {
      bad = bad + 1
    }
    i = i + 1
  }
  assert_eq(bad, 0)
}

///|
test "backtracking finds independent solutions, each line-valid" {
  let solutions = @sudokudb.solve_lattice(3)
  assert_eq(solutions.length(), 3)
  let mut i = 0
  while i < solutions.length() {
    assert_eq(@sudokudb.line_violations(solutions[i]).length(), 0)
    i = i + 1
  }
}

///|
test "backtracking solutions are not all the closed form" {
  let solutions = @sudokudb.solve_lattice(3)
  let canonical = @sudokudb.canonical_digits()
  let mut identical = 0
  let mut i = 0
  while i < solutions.length() {
    let mut same = true
    let mut k = 0
    while k < @sudokudb.TOTAL {
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
  let solutions = @sudokudb.solve_lattice(5)
  assert_eq(solutions.length(), 5)
  let mut i = 0
  while i < solutions.length() {
    assert_eq(@sudokudb.line_violations(solutions[i]).length(), 0)
    assert_eq(@sudokudb.slab_violations(solutions[i]).length(), 0)
    i = i + 1
  }
}

///|
test "the checker actually catches a broken line" {
  let d = @sudokudb.canonical_digits()
  assert_eq(@sudokudb.line_violations(d).length(), 0)
  @sudokudb.set_digit(d, 2, @sudokudb.digit_at(d, 1))
  assert_true(@sudokudb.line_violations(d).length() > 0)
  assert_false(@sudokudb.is_solution(d))
}

///|
test "a line of identical digits is reported once per line, not per cell" {
  let d = @sudokudb.empty_digits()
  @sudokudb.set_digit(d, 1, 2)
  @sudokudb.set_digit(d, 2, 2)
  @sudokudb.set_digit(d, 3, 2)
  assert_eq(@sudokudb.line_violations(d).length(), 1)
}

///|
test "an empty lattice has no violations" {
  let d = @sudokudb.empty_digits()
  assert_eq(@sudokudb.line_violations(d).length(), 0)
  assert_eq(@sudokudb.slab_violations(d).length(), 0)
}

///|
test "digit_at ignores out-of-range positions instead of trapping" {
  let d = @sudokudb.canonical_digits()
  assert_eq(@sudokudb.digit_at(d, 0), @sudokudb.NO_DIGIT)
  assert_eq(@sudokudb.digit_at(d, 82), @sudokudb.NO_DIGIT)
  assert_true(@sudokudb.digit_at(d, 1) >= 1)
}

///|
test "the canonical solution shifts by one along every axis" {
  let d = @sudokudb.canonical_digits()
  let mut axis = 0
  while axis < @sudokudb.DIM {
    for c in @sudokudb.all_coords() {
      if @sudokudb.coord_at(c, axis) < @sudokudb.SIDE - 1 {
        let next = @sudokudb.with_coord(
          c,
          axis,
          @sudokudb.coord_at(c, axis) + 1,
        )
        let here = @sudokudb.digit_at(d, @sudokudb.position_of(c))
        let there = @sudokudb.digit_at(d, @sudokudb.position_of(next))
        assert_eq(there, here % @sudokudb.SIDE + 1)
      }
    }
    axis = axis + 1
  }
}

///|
test "every line of the canonical solution holds all three digits" {
  let d = @sudokudb.canonical_digits()
  let mut incomplete = 0
  for line in @sudokudb.all_lines() {
    let seen : Array[Int] = []
    let mut i = 0
    while i < line.length() {
      let digit = d[@sudokudb.index0(line[i])]
      if !seen.contains(digit) {
        seen.push(digit)
      }
      i = i + 1
    }
    if seen.length() != 3 {
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
  let d = @sudokudb.canonical_digits()
  let slab = @sudokudb.slab_through(@sudokudb.coords(0, 0, 0, 0), 0)
  assert_eq(slab.length(), 27)
  let mut i = 0
  while i < 7 {
    @sudokudb.set_digit(d, @sudokudb.position_of(slab[i]), @sudokudb.NO_DIGIT)
    i = i + 1
  }
  assert_eq(@sudokudb.line_violations(d).length(), 0)
  assert_eq(@sudokudb.slab_violations(d).length(), 0)
  assert_true(@sudokudb.is_solution(d))
}
