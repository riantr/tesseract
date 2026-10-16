///|
/// The sudoku layer: a digit assignment over the `side^4` lattice, the
/// constraint that makes it a sudoku, and a checker for both.
///
/// What the constraint *is* matters, so it is spelled out rather than inherited
/// from the 2D intuition. A 2D sudoku draws rows, columns and boxes from one
/// digit domain. Along a `side`-long axis the line rule still works - `side`
/// cells, digits `1..side` - but the box rule degenerates, because a box is only
/// non-trivial when the axis length is at least the digit domain. So the line
/// family is the constraint here, and slab balance is a *consequence*:
///
/// Every slab is exactly `side^2` lines parallel to any one axis within it, and
/// each such line contributes one of every digit, so each digit appears
/// `side^3 / side = side^2` times. `slab_violations` checks that empirically
/// rather than trusting the argument, and `solve_lattice` produces independent
/// solutions so the implication is tested on more than the closed form.

///|
/// A digit per cell, indexed by `position - 1`; 0 means "no digit".
pub fn empty_digits(lat : Lattice) -> Array[Int64] {
  let d : Array[Int64] = []
  let mut i = lat.first_position
  while i <= lat.last_position {
    d.push(NO_DIGIT)
    i = i + 1L
  }
  d
}

///|
/// An independent copy of a digit assignment.
pub fn copy_digits(d : Array[Int64]) -> Array[Int64] {
  let out : Array[Int64] = []
  let mut i = 0
  while i < d.length() {
    out.push(d[i])
    i = i + 1
  }
  out
}

///|
/// The digit at `position`, or 0.
pub fn digit_at(lat : Lattice, d : Array[Int64], position : Int64) -> Int64 {
  if !position_in_bounds(lat, position) {
    return NO_DIGIT
  }
  d[slot_of(position)]
}

///|
/// Places a digit, ignoring out-of-range positions.
pub fn set_digit(
  lat : Lattice,
  d : Array[Int64],
  position : Int64,
  digit : Int64,
) -> Unit {
  if position_in_bounds(lat, position) {
    d[slot_of(position)] = digit
  }
}

///|
/// The closed-form solution `digit(x,y,z,w) = (x+y+z+w) mod side + 1`.
///
/// Stepping one cell along any axis adds 1 modulo `side`, so each axis-parallel
/// line cycles through all `side` digits. Useful as a known-good starting point
/// and as the fixture the checkers are tested against.
pub fn canonical_digits(lat : Lattice) -> Array[Int64] {
  let d = empty_digits(lat)
  for c in all_coords(lat) {
    set_digit(
      lat,
      d,
      position_of(lat, c),
      (c.x + c.y + c.z + c.w) % lat.side + 1L,
    )
  }
  d
}

///|
/// Line violations in `d`, as human-readable strings.
///
/// Reports one message per offending line. An empty result means every
/// axis-parallel line holds `1..side` exactly once.
pub fn line_violations(lat : Lattice, d : Array[Int64]) -> Array[String] {
  let out : Array[String] = []
  for line in all_lines(lat) {
    let seen : Array[Int64] = []
    let mut bad = false
    let mut i = 0
    while i < line.length() {
      let digit = d[index0(lat, line[i]).to_int()]
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
/// A balanced slab holds each digit exactly `side^2` times. Cells with no digit
/// are skipped, so a partially filled lattice only reports slabs that are
/// already full.
pub fn slab_violations(lat : Lattice, d : Array[Int64]) -> Array[String] {
  let out : Array[String] = []
  let origin = coords(0L, 0L, 0L, 0L)
  let mut axis = 0L
  while axis < DIM {
    let mut v = 0L
    while v < lat.side {
      let anchor = with_coord(origin, axis, v)
      let slab = slab_through(lat, anchor, axis)
      // The tally is sized from the lattice rather than written out as
      // `[0, 0, 0, 0]`. A fixed 4-slot array addresses digits 0..3, so at
      // side == 4 - where the domain is 1..4 - `counts[digit]` would reach
      // index 4 and be out of bounds. Digit 0 stays a real slot because
      // NO_DIGIT is skipped by the `filled` branch below but the loop still
      // indexes by digit, and skipping 0 would need a -1 offset on a signed
      // value.
      let counts : Array[Int64] = []
      let mut ci = 0L
      while ci <= lat.max_digit {
        counts.push(0L)
        ci = ci + 1L
      }
      let mut filled = 0L
      let mut i = 0
      while i < slab.length() {
        let digit = d[index0(lat, slab[i]).to_int()]
        if digit != NO_DIGIT {
          counts[digit.to_int()] = counts[digit.to_int()] + 1L
          filled = filled + 1L
        }
        i = i + 1
      }
      // "Balanced" is only meaningful for a *full* slab: a slab with holes in
      // it has no count distribution to be balanced against, and `filled /
      // side` would not even divide. The guard used to be `TOTAL / DIM`, which
      // is 20 for a lattice of 81 and 4 axes - not a size any slab can be, so
      // it only ever fired on a half-filled slab and called it imbalanced.
      if filled == slab.length().to_int64() {
        let expected = filled / lat.side
        let mut k = 1L
        let mut imbalanced = false
        while k <= lat.max_digit {
          if counts[k.to_int()] != expected {
            imbalanced = true
          }
          k = k + 1L
        }
        if imbalanced {
          let b = StringBuilder::StringBuilder()
          b.write_string("slab axis ")
          b.write_object(axis)
          b.write_string(" coord ")
          b.write_object(v)
          b.write_string(" counts ")
          let mut k = 1L
          while k <= lat.max_digit {
            if k > 1L {
              b.write_char('/')
            }
            b.write_object(counts[k.to_int()])
            k = k + 1L
          }
          out.push(b.to_string())
        }
      }
      v = v + 1L
    }
    axis = axis + 1L
  }
  out
}

///|
/// True when `d` has no line violation and no slab imbalance.
pub fn is_solution(lat : Lattice, d : Array[Int64]) -> Bool {
  line_violations(lat, d).length() == 0 && slab_violations(lat, d).length() == 0
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
  let mut axis = 0L
  while axis < DIM {
    let mut back = coord_at_unchecked(c, axis) - 1L
    while back >= 0L {
      out.push(with_coord(c, axis, back))
      back = back - 1L
    }
    axis = axis + 1L
  }
  out
}

///|
/// Depth-first fill honouring the line rule, collecting up to `limit` results.
fn backtrack(
  lat : Lattice,
  d : Array[Int64],
  index : Int64,
  limit : Int64,
  out : Array[Array[Int64]],
) -> Bool {
  if out.length().to_int64() >= limit {
    return true
  }
  if index >= lat.total {
    out.push(copy_digits(d))
    return out.length().to_int64() >= limit
  }
  let c = coords_of(lat, index + lat.first_position).unwrap()
  let mut digit = 1L
  while digit <= lat.max_digit {
    let mut clash = false
    for peer in earlier_peers(c) {
      if digit_at(lat, d, position_of(lat, peer)) == digit {
        clash = true
      }
    }
    if !clash {
      d[slot_of(index + lat.first_position)] = digit
      if backtrack(lat, d, index + 1L, limit, out) {
        d[slot_of(index + lat.first_position)] = NO_DIGIT
        return true
      }
      d[slot_of(index + lat.first_position)] = NO_DIGIT
    }
    digit = digit + 1L
  }
  false
}

///|
/// Enumerates up to `limit` complete solutions of the line rule.
///
/// Independent of `canonical_digits`, which is what makes it useful: the closed
/// form proves the structure is satisfiable, and this proves the *implication*
/// that slab balance follows, on solutions nobody designed.
pub fn solve_lattice(lat : Lattice, limit : Int64) -> Array[Array[Int64]] {
  let out : Array[Array[Int64]] = []
  ignore(backtrack(lat, empty_digits(lat), 0L, limit, out))
  out
}
