///|
/// Sudoku sub-structures of the 3x3x3x3 lattice.
///
/// Sizing note, because it is easy to assume the wrong thing here: a 2D sudoku
/// has two *different* constraint families — 9 rows/columns of 9 cells, and 9
/// boxes of 3x3 — and both draw from a digit domain of 9. At side 3 in 4D
/// that second family collapses. A box is "the digit domain", so it needs the
/// axis length to be at least 9 to be non-trivial; at axis length 3 the only
/// box is the whole grid. What survives as a real constraint is the line
/// family: 4 axes x 27 lines x 3 cells, each line a permutation of digits
/// 1..3.
///
/// So this module exposes lines as the load-bearing structure, plus slabs and
/// planes as *geometry* for grouping and querying. Slab balance is a derived
/// invariant here, not an independent rule — `sudoku.mbt` proves that by
/// checking it rather than assuming it.

///|
/// The 3 cells on the axis-parallel line through `c` along `axis`.
///
/// An `axis` outside `0..DIM-1` gives an empty list. A real axis always yields
/// 3 cells, so an empty result is unambiguously a bad axis. The guard is needed
/// even though nothing here reads a coordinate: `with_coord` answers `w` for an
/// axis it does not recognise, so without it `line_through(c, 9)` returned the
/// w-axis line and reported it as the axis the caller asked for.
pub fn line_through(c : Coords, axis : Int32) -> Array[Coords] {
  let out : Array[Coords] = []
  match coord_at(c, axis) {
    None => return out
    Some(_) => ()
  }
  let mut v = 0
  while v < SIDE {
    out.push(with_coord(c, axis, v))
    v = v + 1
  }
  out
}

///|
/// The 27 cells that share `c`'s coordinate along `axis`.
///
/// This is the 4D generalisation of a 3x3 box's bounding region: it is a
/// three-dimensional sub-lattice, not a sudoku box.
///
/// An `axis` outside `0..DIM-1` gives an empty list. A real axis always yields
/// 27 cells, so an empty result is unambiguously a bad axis.
pub fn slab_through(c : Coords, axis : Int32) -> Array[Coords] {
  let out : Array[Coords] = []
  let fixed = match coord_at(c, axis) {
    None => return out
    Some(v) => v
  }
  // The guard above is what makes `axis` a real one for the rest of this loop.
  for other in all_coords() {
    if coord_at_unchecked(other, axis) == fixed {
      out.push(other)
    }
  }
  out
}

///|
/// The 9 cells that share `c`'s coordinates along both given axes.
///
/// The two axes have to be distinct. Naming the same axis twice reads like two
/// coordinates are being fixed and so should still hold 9 cells, but both
/// constraints collapse onto one axis and the answer silently becomes the
/// 27-cell slab along it — a call asking about a plane handed back a third of
/// the lattice.
///
/// This is the only one of the three that reports the axis range as an error,
/// because it is the only one with a channel for it: the other two answer an
/// out-of-range axis with an empty list, which is unambiguous only because a
/// valid line is always 3 cells and a valid slab always 27. `coord_at` used to
/// answer `w` for any axis it did not recognise, so all three of them silently
/// returned the w-axis geometry; that is what this guard and the empty lists
/// above now prevent.
pub fn plane_through(
  c : Coords,
  axis_a : Int32,
  axis_b : Int32,
) -> Result[Array[Coords], String] {
  if axis_a < 0 || axis_a >= DIM || axis_b < 0 || axis_b >= DIM {
    return Err(
      "Axis must be 0..3, got " +
      axis_a.to_string() +
      " and " +
      axis_b.to_string(),
    )
  }
  if axis_a == axis_b {
    return Err(
      "A plane fixes two different axes; " +
      axis_a.to_string() +
      " was given twice",
    )
  }
  let out : Array[Coords] = []
  // Both axes were just checked against DIM, so these cannot be None.
  let fa = coord_at_unchecked(c, axis_a)
  let fb = coord_at_unchecked(c, axis_b)
  for other in all_coords() {
    if coord_at_unchecked(other, axis_a) == fa &&
      coord_at_unchecked(other, axis_b) == fb {
      out.push(other)
    }
  }
  Ok(out)
}

///|
/// Every axis-parallel line, 4 x 27 = 108, in a stable order.
///
/// Each line is emitted once by requiring its representative to sit at
/// coordinate 0 on the free axis.
pub fn all_lines() -> Array[Array[Coords]] {
  let out : Array[Array[Coords]] = []
  let mut axis = 0
  while axis < DIM {
    for c in all_coords() {
      if coord_at_unchecked(c, axis) == 0 {
        out.push(line_through(c, axis))
      }
    }
    axis = axis + 1
  }
  out
}

///|
/// Every slab, 4 axes x 3 = 12, in a stable order.
pub fn all_slabs() -> Array[Array[Coords]] {
  let out : Array[Array[Coords]] = []
  let mut axis = 0
  while axis < DIM {
    let mut v = 0
    while v < SIDE {
      out.push(slab_through(with_coord(coords(0, 0, 0, 0), axis, v), axis))
      v = v + 1
    }
    axis = axis + 1
  }
  out
}

///|
/// The axis a line varies along: the one coordinate its 3 cells do not share.
///
/// For a proper 3-cell line exactly one axis differs across the cells, so the
/// free axis is the *least* agreeing one, not the most.
pub fn free_axis_of(line : Array[Coords]) -> Int32 {
  let mut best = 0
  let mut best_agree = DIM
  let mut axis = 0
  while axis < DIM {
    let mut agree = 0
    if line.length() > 1 &&
      coord_at_unchecked(line[1], axis) == coord_at_unchecked(line[0], axis) {
      agree = agree + 1
    }
    if line.length() > 2 &&
      coord_at_unchecked(line[2], axis) == coord_at_unchecked(line[0], axis) {
      agree = agree + 1
    }
    if agree < best_agree {
      best_agree = agree
      best = axis
    }
    axis = axis + 1
  }
  best
}

///|
/// Order-independent identity of a line, for de-duplicating cell sets.
pub fn line_key(line : Array[Coords]) -> String {
  let parts : Array[String] = []
  let mut i = 0
  while i < line.length() {
    parts.push(format_coords(line[i]))
    i = i + 1
  }
  let mut j = 0
  while j + 1 < parts.length() {
    if parts[j + 1] < parts[j] {
      let t = parts[j]
      parts[j] = parts[j + 1]
      parts[j + 1] = t
    }
    j = j + 1
  }
  join(parts, "|")
}

///|
/// The 8 cells sharing an axis-parallel line with `c`, excluding `c` itself.
///
/// These are exactly the cells a sudoku digit at `c` can collide with.
pub fn peers(c : Coords) -> Array[Coords] {
  let out : Array[Coords] = []
  let mut axis = 0
  while axis < DIM {
    for n in line_through(c, axis) {
      if index0(n) != index0(c) {
        out.push(n)
      }
    }
    axis = axis + 1
  }
  out
}

///|
/// Number of cells sharing a line with `c`. Constant at 8 on a 3^4 lattice.
pub fn peer_count() -> Int32 {
  DIM * (SIDE - 1)
}
