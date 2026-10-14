///|
/// The sudoku layer: a digit assignment over the 3^4 lattice, the constraint
/// that makes it a sudoku, and a checker for both.
///
/// What the constraint *is* at this size matters, so it is spelled out rather
/// than inherited from the 2D intuition. A 2D sudoku draws rows, columns and
/// boxes from one digit domain of 9. Along a 3-long axis the line rule still
/// works — 3 cells, digits 1..3 — but the box rule degenerates, because a box
/// is only non-trivial when the axis length is at least the digit domain. So the
/// line family is the constraint here, and slab balance is a *consequence*:
///
/// Every slab is exactly nine lines parallel to any one axis within it, and
/// each such line contributes one of every digit, so each digit appears
/// `27 / 3 = 9` times. `slab_violations` checks that empirically rather than
/// trusting the argument, and `solve_lattice` produces independent solutions so
/// the implication is tested on more than the closed form.

///|
/// A digit per cell, indexed by `position - 1`; 0 means "no digit".
pub fn empty_digits() -> Array[Int] {
  let d : Array[Int] = []
  let mut i = 0
  while i < TOTAL {
    d.push(NO_DIGIT)
    i = i + 1
  }
  d
}

///|
/// An independent copy of a digit assignment.
pub fn copy_digits(d : Array[Int]) -> Array[Int] {
  let out : Array[Int] = []
  let mut i = 0
  while i < d.length() {
    out.push(d[i])
    i = i + 1
  }
  out
}

///|
/// The digit at `position`, or 0.
pub fn digit_at(d : Array[Int], position : Int) -> Int {
  if !position_in_bounds(position) {
    return NO_DIGIT
  }
  d[position - 1]
}

///|
/// Places a digit, ignoring out-of-range positions.
pub fn set_digit(d : Array[Int], position : Int, digit : Int) -> Unit {
  if position_in_bounds(position) {
    d[position - 1] = digit
  }
}

///|
/// The closed-form solution `digit(x,y,z,w) = (x+y+z+w) mod 3 + 1`.
///
/// Stepping one cell along any axis adds 1 modulo 3, so each axis-parallel line
/// cycles through all three digits. Useful as a known-good starting point and
/// as the fixture the checkers are tested against.
pub fn canonical_digits() -> Array[Int] {
  let d = empty_digits()
  for c in all_coords() {
    set_digit(d, position_of(c), (c.x + c.y + c.z + c.w) % SIDE + 1)
  }
  d
}

///|
/// Line violations in `d`, as human-readable strings.
///
/// Reports one message per offending line. An empty result means every
/// axis-parallel line holds 1, 2 and 3 exactly once.
pub fn line_violations(d : Array[Int]) -> Array[String] {
  let out : Array[String] = []
  for line in all_lines() {
    let seen : Array[Int] = []
    let mut bad = false
    let mut i = 0
    while i < line.length() {
      let digit = d[index0(line[i])]
      if digit == NO_DIGIT {
        i = i + 1
        continue
      }
      if seen.contains(digit) {
        bad = true
      } else {
        seen.push(digit)
      }
      i = i + 1
    }
    if bad {
      let anchor = line[0]
      let b = StringBuilder::StringBuilder()
      b.write_string("line along axis ")
      b.write_object(free_axis_of(line))
      b.write_string(" through ")
      b.write_string(format_coords(anchor))
      b.write_string(" repeats a digit")
      out.push(b.to_string())
    }
  }
  out
}

///|
/// Slab imbalance in `d`, as human-readable strings.
///
/// A balanced slab holds each digit exactly 9 times. Cells with no digit are
/// skipped, so a partially filled lattice only reports slabs that are already
/// full.
pub fn slab_violations(d : Array[Int]) -> Array[String] {
  let out : Array[String] = []
  let mut axis = 0
  while axis < DIM {
    let mut v = 0
    while v < SIDE {
      let anchor = with_coord(coords(0, 0, 0, 0), axis, v)
      let slab = slab_through(anchor, axis)
      let counts = [0, 0, 0, 0]
      let mut filled = 0
      let mut i = 0
      while i < slab.length() {
        let digit = d[index0(slab[i])]
        if digit != NO_DIGIT {
          counts[digit] = counts[digit] + 1
          filled = filled + 1
        }
        i = i + 1
      }
      // "Balanced" is only meaningful for a *full* slab: a slab with holes in
      // it has no count distribution to be balanced against, and `filled / SIDE`
      // would not even divide. The guard used to be `TOTAL / DIM`, which is 20
      // for a lattice of 81 and 4 axes - not a size any slab can be, so it only
      // ever fired on a half-filled slab and called it imbalanced.
      if filled == slab.length() {
        let expected = filled / SIDE
        let mut k = 1
        let mut imbalanced = false
        while k <= MAX_DIGIT {
          if counts[k] != expected {
            imbalanced = true
          }
          k = k + 1
        }
        if imbalanced {
          let b = StringBuilder::StringBuilder()
          b.write_string("slab axis ")
          b.write_object(axis)
          b.write_string(" coord ")
          b.write_object(v)
          b.write_string(" counts ")
          b.write_object(counts[1])
          b.write_char('/')
          b.write_object(counts[2])
          b.write_char('/')
          b.write_object(counts[3])
          out.push(b.to_string())
        }
      }
      v = v + 1
    }
    axis = axis + 1
  }
  out
}

///|
/// True when `d` has no line violation and no slab imbalance.
pub fn is_solution(d : Array[Int]) -> Bool {
  line_violations(d).length() == 0 && slab_violations(d).length() == 0
}

///|
/// Line-mates of `c` already visited in row-major order.
///
/// Filling in position order means a cell's earlier line-mates are exactly
/// those at *smaller* coordinates on some single axis. Note that a cell can
/// have more than one per axis: (0,0,0,2) shares its line with both
/// (0,0,0,0) and (0,0,0,1), and checking only the nearest one misses a
/// duplicate outright.
fn earlier_peers(c : Coords) -> Array[Coords] {
  let out : Array[Coords] = []
  let mut axis = 0
  while axis < DIM {
    let mut back = coord_at(c, axis) - 1
    while back >= 0 {
      out.push(with_coord(c, axis, back))
      back = back - 1
    }
    axis = axis + 1
  }
  out
}

///|
/// Depth-first fill honouring the line rule, collecting up to `limit` results.
fn backtrack(
  d : Array[Int],
  index : Int,
  limit : Int,
  out : Array[Array[Int]],
) -> Bool {
  if out.length() >= limit {
    return true
  }
  if index >= TOTAL {
    out.push(copy_digits(d))
    return out.length() >= limit
  }
  let c = coords_of(index + 1).unwrap()
  let mut digit = 1
  while digit <= MAX_DIGIT {
    let mut clash = false
    for peer in earlier_peers(c) {
      if digit_at(d, position_of(peer)) == digit {
        clash = true
      }
    }
    if !clash {
      d[index] = digit
      if backtrack(d, index + 1, limit, out) {
        d[index] = NO_DIGIT
        return true
      }
      d[index] = NO_DIGIT
    }
    digit = digit + 1
  }
  false
}

///|
/// Enumerates up to `limit` complete solutions of the line rule.
///
/// Independent of `canonical_digits`, which is what makes it useful: the
/// closed form proves the structure is satisfiable, and this proves the
/// *implication* that slab balance follows, on solutions nobody designed.
pub fn solve_lattice(limit : Int) -> Array[Array[Int]] {
  let out : Array[Array[Int]] = []
  ignore(backtrack(empty_digits(), 0, limit, out))
  out
}
