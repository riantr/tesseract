///|
/// The 3x3x3x3 lattice: coordinates, flat positions, and the sudoku
/// sub-structures that make the grid a sudoku grid rather than a reshaped list.
///
/// The C# original kept 9 records in a flat ring presented as a 3x3 box (two
/// dimensions). The 4D form lifts that to 81 cells addressed by four
/// coordinates in `0..2`.
///
/// Two numbering schemes coexist deliberately:
///
/// - **coordinates** `(x, y, z, w)` are 0-based, matching array indexing;
/// - **positions** `1..81` are 1-based, matching the C# `grid_position`
///   column, so stored SQL and `.tsr` files keep the same shape.
///
/// `position = 1 + x*27 + y*9 + z*3 + w` (row-major, `x` slowest) and the
/// inverse is exact for all 81 cells.

///|
/// Cells along each of the four axes.
pub const SIDE : Int32 = 3

///|
/// Number of axes.
pub const DIM : Int32 = 4

///|
/// Total cells in the lattice: 3^4 = 81.
pub const TOTAL : Int32 = 81

///|
/// Lowest valid 1-based position.
pub const FIRST_POSITION : Int32 = 1

///|
/// Highest valid 1-based position.
pub const LAST_POSITION : Int32 = 81

///|
/// Sudoku digits live in `1..SIDE`; 0 means "this cell carries no digit".
pub const NO_DIGIT : Int32 = 0

///|
/// Highest sudoku digit.
pub const MAX_DIGIT : Int32 = 3

///|
/// A cell in the 4D lattice. Each coordinate is in `0..SIDE-1`.
///
/// Equality and debug output are structural; the `extend` declarations keep the
/// trait methods from being implicitly promoted as regular methods, which the
/// compiler warns about.
pub struct Coords {
  x : Int32
  y : Int32
  z : Int32
  w : Int32
} derive(Eq, Debug)

///|
pub extend Coords with Eq::{equal, not_equal}

///|
pub extend Coords with @debug.Debug::{to_repr}

///|
/// Builds a coordinate tuple.
pub fn coords(x : Int32, y : Int32, z : Int32, w : Int32) -> Coords {
  { x, y, z, w, }
}

///|
/// One coordinate inside the lattice.
fn coord_in_bounds(v : Int32) -> Bool {
  v >= 0 && v < SIDE
}

///|
/// True when every coordinate is inside the lattice.
pub fn coords_in_bounds(c : Coords) -> Bool {
  let a = coord_in_bounds(c.x)
  let b = coord_in_bounds(c.y)
  let d = coord_in_bounds(c.z)
  let e = coord_in_bounds(c.w)
  a && b && d && e
}

///|
/// True when `p` is a valid 1-based position.
pub fn position_in_bounds(p : Int32) -> Bool {
  p >= FIRST_POSITION && p <= LAST_POSITION
}

///|
/// The `axis`-th coordinate of `c`, counting `x=0, y=1, z=2, w=3`.
///
/// `None` when `axis` is outside `0..DIM-1`.
///
/// The previous version answered `w` for anything that was not 0, 1 or 2, so
/// `coord_at(c, 4)`, `coord_at(c, 99)` and `coord_at(c, -1)` each returned the
/// fourth coordinate as if the caller had asked for it. A wrong coordinate is
/// the one failure a caller cannot notice from the result: every value is a
/// legitimate coordinate of `c`, and nothing marks it as the wrong one.
pub fn coord_at(c : Coords, axis : Int32) -> Int32? {
  if axis < 0 || axis >= DIM {
    return None
  }
  Some(coord_at_unchecked(c, axis))
}

///|
/// `coord_at` without the range check, for callers that have already
/// established `axis < DIM`.
///
/// Private on purpose. Every caller here is a `while axis < DIM` loop, where a
/// `None` branch is unreachable; writing `.unwrap()` at each would put a guard
/// that can never fail into the code, which reads like a check and checks
/// nothing. An outside caller goes through `coord_at`, which reports the range.
fn coord_at_unchecked(c : Coords, axis : Int32) -> Int32 {
  match axis {
    0 => c.x
    1 => c.y
    2 => c.z
    _ => c.w
  }
}

///|
/// `c` with its `axis`-th coordinate replaced by `v`.
pub fn with_coord(c : Coords, axis : Int32, v : Int32) -> Coords {
  match axis {
    0 => { x: v, y: c.y, z: c.z, w: c.w, }
    1 => { x: c.x, y: v, z: c.z, w: c.w, }
    2 => { x: c.x, y: c.y, z: v, w: c.w, }
    _ => { x: c.x, y: c.y, z: c.z, w: v, }
  }
}

///|
/// Zero-based row-major index of `c`.
pub fn index0(c : Coords) -> Int32 {
  c.x * 27 + c.y * 9 + c.z * 3 + c.w
}

///|
/// The 1-based position of `c`.
pub fn position_of(c : Coords) -> Int32 {
  index0(c) + 1
}

///|
/// The coordinate at 1-based position `p`.
///
/// Returns `None` for positions outside `1..81`; the caller decides whether
/// that is an error or just an empty result.
pub fn coords_of(p : Int32) -> Coords? {
  if !position_in_bounds(p) {
    return None
  }
  let i = p - 1
  Some(coords(i / 27, i / 9 % 3, i / 3 % 3, i % 3))
}

///|
/// Every cell, in row-major order. Length is always `TOTAL`.
pub fn all_coords() -> Array[Coords] {
  let out : Array[Coords] = []
  for i = 0; i < TOTAL; i = i + 1 {
    out.push(coords_of(i + 1).unwrap())
  }
  out
}

///|
/// Renders `(x,y,z,w)`, e.g. `(1,0,2,1)`.
pub fn format_coords(c : Coords) -> String {
  let b = StringBuilder::StringBuilder(size_hint=16)
  b.write_char('(')
  b.write_object(c.x)
  b.write_char(',')
  b.write_object(c.y)
  b.write_char(',')
  b.write_object(c.z)
  b.write_char(',')
  b.write_object(c.w)
  b.write_char(')')
  b.to_string()
}

///|
/// Parses `(x,y,z,w)` or `x,y,z,w`.
///
/// Every coordinate must be an integer in `0..2`; anything else is `None`
/// rather than a clamped value, so a malformed address can never silently
/// address a different cell than the caller asked for.
pub fn parse_coords(s : String) -> Coords? {
  let t = trim_ws(s)
  let body = if t.length() >= 2 && t.at(0) == '(' && t.at(t.length() - 1) == ')' {
    slice(t, 1, t.length() - 1)
  } else {
    t
  }
  let parts = split(body, ",")
  if parts.length() != DIM {
    return None
  }
  let vals : Array[Int32] = []
  let mut i = 0
  while i < DIM {
    match parse_int(parts[i]) {
      Some(v) => vals.push(v)
      None => return None
    }
    i = i + 1
  }
  let c = coords(vals[0], vals[1], vals[2], vals[3])
  if !coords_in_bounds(c) {
    return None
  }
  Some(c)
}

///|
/// The cells adjacent to `c` along `axis`: two in the middle of the axis, one
/// at either end.
///
/// Sudoku lines are bounded, never wrapped: stepping off the lattice is a real
/// boundary, so a walk that wraps would report cells that are not neighbours.
///
/// An `axis` outside `0..DIM-1` gives an empty list. For a real axis this
/// function never returns an empty list - every cell has at least one
/// neighbour on a 3-long axis - so an empty result is unambiguously a bad axis
/// and not a cell that happens to stand alone.
pub fn neighbours(c : Coords, axis : Int32) -> Array[Coords] {
  let out : Array[Coords] = []
  let here = match coord_at(c, axis) {
    None => return out
    Some(v) => v
  }
  if here - 1 >= 0 {
    out.push(with_coord(c, axis, here - 1))
  }
  if here + 1 < SIDE {
    out.push(with_coord(c, axis, here + 1))
  }
  out
}

///|
/// True when `a` and `b` share one axis-parallel line.
///
/// Two cells are on a common line exactly when they agree on three of four
/// coordinates, i.e. differ along a single axis.
pub fn shares_line(a : Coords, b : Coords) -> Bool {
  let mut same = 0
  if a.x == b.x {
    same = same + 1
  }
  if a.y == b.y {
    same = same + 1
  }
  if a.z == b.z {
    same = same + 1
  }
  if a.w == b.w {
    same = same + 1
  }
  same >= DIM - 1
}
