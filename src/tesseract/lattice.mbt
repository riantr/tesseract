///|
/// Sudoku sub-structures of the 4D lattice.
///
/// Sizing note, because it is easy to assume the wrong thing here: a 2D sudoku
/// has two *different* constraint families - 9 rows/columns of 9 cells, and 9
/// boxes of 3x3 - and both draw from a digit domain of 9. A box is "the digit
/// domain", so it needs the axis length to be at least 9 to be non-trivial; at
/// axis length 3 the only box is the whole grid. What survives as a real
/// constraint is the line family: `DIM` axes x `side^3` lines x `side` cells,
/// each line a permutation of digits `1..side`.
///
/// So this module exposes lines as the load-bearing structure, plus slabs and
/// planes as *geometry* for grouping and querying. Slab balance is a derived
/// invariant here, not an independent rule - `sudoku.mbt` proves that by
/// checking it rather than assuming it.

///|
/// The `side` cells on the axis-parallel line through `c` along `axis`.
///
/// An `axis` outside `0..DIM-1` gives an empty list. A real axis always yields
/// `side` cells, so an empty result is unambiguously a bad axis. The guard is
/// needed even though nothing here reads a coordinate: `with_coord` answers `w`
/// for an axis it does not recognise, so without it `line_through(c, 9)`
/// returned the w-axis line and reported it as the axis the caller asked for.
pub fn line_through(lat : Lattice, c : Coords, axis : Int64) -> Array[Coords] {
  let out : Array[Coords] = []
  match coord_at(c, axis) {
    None => return out
    Some(_) => ()
  }
  let mut v = 0L
  while v < lat.side {
    out.push(with_coord(c, axis, v))
    v = v + 1L
  }
  out
}

///|
/// The `side^3` cells that share `c`'s coordinate along `axis`.
///
/// This is the 4D generalisation of a 3x3 box's bounding region: it is a
/// three-dimensional sub-lattice, not a sudoku box.
///
/// An `axis` outside `0..DIM-1` gives an empty list. A real axis always yields
/// `side^3` cells, so an empty result is unambiguously a bad axis.
pub fn slab_through(lat : Lattice, c : Coords, axis : Int64) -> Array[Coords] {
  let out : Array[Coords] = []
  let fixed = match coord_at(c, axis) {
    None => return out
    Some(v) => v
  }
  // The guard above is what makes `axis` a real one for the rest of this loop.
  for other in all_coords(lat) {
    if coord_at_unchecked(other, axis) == fixed {
      out.push(other)
    }
  }
  out
}

///|
/// The `side^2` cells that share `c`'s coordinates along both given axes.
///
/// The two axes have to be distinct. Naming the same axis twice reads like two
/// coordinates are being fixed and so should still hold `side^2` cells, but
/// both constraints collapse onto one axis and the answer silently becomes the
/// `side^3`-cell slab along it - a call asking about a plane handed back a third
/// of the lattice.
///
/// This is the only one of the three that reports the axis range as an error,
/// because it is the only one with a channel for it: the other two answer an
/// out-of-range axis with an empty list, which is unambiguous only because a
/// valid line always holds `side` cells and a valid slab always `side^3`.
pub fn plane_through(
  lat : Lattice,
  c : Coords,
  axis_a : Int64,
  axis_b : Int64,
) -> Result[Array[Coords], String] {
  if axis_a < 0L || axis_a >= DIM || axis_b < 0L || axis_b >= DIM {
    return Err(
      "Axis must be 0.." +
      (DIM - 1L).to_string() +
      ", got " +
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
  for other in all_coords(lat) {
    if coord_at_unchecked(other, axis_a) == fa &&
      coord_at_unchecked(other, axis_b) == fb {
      out.push(other)
    }
  }
  Ok(out)
}

///|
/// The number of axis-parallel lines through the lattice: `DIM * side^3`.
///
/// This is `all_lines(lat).length()` without building the lines, which is
/// what a status readout wants — the count, not the array.
///
/// It is the library's answer because `all_lines` is the library's. Two
/// command-line tools used to count the lines between them: one named the
/// count, the other wrote the arithmetic out inline. The values agreed, and
/// the agreement was a coincidence rather than a contract, because nothing
/// tied them together. One definition, in the package that owns the thing
/// being counted, ties them together.
pub fn sudoku_line_count(lat : Lattice) -> Int64 {
  lat.total / lat.side * DIM
}

///|
/// Every axis-parallel line, `DIM * side^3`, in a stable order.
///
/// Each line is emitted once by requiring its representative to sit at
/// coordinate 0 on the free axis.
pub fn all_lines(lat : Lattice) -> Array[Array[Coords]] {
  let out : Array[Array[Coords]] = []
  let mut axis = 0L
  while axis < DIM {
    for c in all_coords(lat) {
      if coord_at_unchecked(c, axis) == 0L {
        out.push(line_through(lat, c, axis))
      }
    }
    axis = axis + 1L
  }
  out
}

///|
/// Every slab, `DIM * side`, in a stable order.
pub fn all_slabs(lat : Lattice) -> Array[Array[Coords]] {
  let out : Array[Array[Coords]] = []
  let origin = coords(0L, 0L, 0L, 0L)
  let mut axis = 0L
  while axis < DIM {
    let mut v = 0L
    while v < lat.side {
      out.push(slab_through(lat, with_coord(origin, axis, v), axis))
      v = v + 1L
    }
    axis = axis + 1L
  }
  out
}

///|
/// The axis a line varies along: the one coordinate its cells do not share.
///
/// For a proper `side`-cell line exactly one axis differs across the cells, so
/// the free axis is the *least* agreeing one, not the most.
///
/// Every cell on the line is compared against the first. An earlier version
/// looked only at `line[0]`, `line[1]` and `line[2]`, which is all of a 3-cell
/// line and only the first three quarters of a 4-cell one. It still returned the
/// right axis at `side == 4`, because the free axis disagrees across the cells
/// it happened to look at - but by luck rather than construction.
pub fn free_axis_of(line : Array[Coords]) -> Int64 {
  if line.length() <= 1 {
    return 0L
  }
  let anchor = line[0]
  let mut best = 0L
  let mut best_agree = DIM
  let mut axis = 0L
  while axis < DIM {
    let anchor_v = coord_at_unchecked(anchor, axis)
    let mut agree = 0L
    let mut i = 1
    while i < line.length() {
      if coord_at_unchecked(line[i], axis) == anchor_v {
        agree = agree + 1L
      }
      i = i + 1
    }
    if agree < best_agree {
      best_agree = agree
      best = axis
    }
    axis = axis + 1L
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
/// The `DIM * (side - 1)` cells sharing an axis-parallel line with `c`,
/// excluding `c` itself.
///
/// These are exactly the cells a sudoku digit at `c` can collide with.
pub fn peers(lat : Lattice, c : Coords) -> Array[Coords] {
  let out : Array[Coords] = []
  let mut axis = 0L
  while axis < DIM {
    for n in line_through(lat, c, axis) {
      if index0(lat, n) != index0(lat, c) {
        out.push(n)
      }
    }
    axis = axis + 1L
  }
  out
}

///|
/// Number of cells sharing a line with `c`. `DIM * (side - 1)` - 8 on a 3-per-axis
/// lattice, 12 on a 4-per-axis one.
pub fn peer_count(lat : Lattice) -> Int64 {
  DIM * (lat.side - 1L)
}
