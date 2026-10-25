///|
/// The 4D lattice: coordinates, flat positions, and the sudoku
/// sub-structures that make the grid a sudoku grid rather than a reshaped list.
///
/// The C# original kept 9 records in a flat ring presented as a 3x3 box (two
/// dimensions). The 4D form lifted that to 81 cells addressed by four
/// coordinates in `0..2`, which is this module's default.
///
/// **The side is a value, not a constant.** `lattice_of(3)` reproduces the
/// original 81-cell lattice exactly - same positions, same order, same digit
/// domain - and `lattice_of(4)` gives a 256-cell lattice over digits `1..4`.
/// Every function that used to read the `SIDE` constant takes a `Lattice`
/// instead, so a caller has to say which lattice it means.
///
/// Two numbering schemes coexist deliberately:
///
/// - **coordinates** `(x, y, z, w)` are 0-based, matching array indexing;
/// - **positions** `1..total` are 1-based, matching the C# `grid_position`
///   column, so stored SQL and `.tsr` files keep the same shape.
///
/// `position = 1 + x*side^3 + y*side^2 + z*side + w` (row-major, `x` slowest),
/// and the inverse is exact for every cell.
///
/// Everything here is `Int64` rather than `Int32`, for a measured reason, and
/// the reason is narrower than "there are no conversions". What this toolchain
/// lacks is a direct `Int64 -> Int32` (`Int64::to_int32` does not compile) and
/// any `Int32 -> Int` (`Int32::to_int` does not compile either), while `Array`
/// is indexed by `Int`. `Int32` is therefore a dead end from here in both
/// directions: the index arithmetic produces `Int64`, and `Int32` can neither be
/// reached from it nor address storage. `Int64 -> Int` does exist (`to_int`),
/// which is the one narrowing in the library, isolated in `slot_of` and in the
/// array reads that want a flat 0-based index.

///|
/// Number of axes.
///
/// Fixed, and unrelated to `side`: a 2-cell-per-axis lattice and a 9-cell-per-axis
/// lattice are both four-dimensional. Widening the *number* of axes is a
/// different change from widening the number of cells along each axis, and this
/// module does the latter.
pub const DIM : Int64 = 4

///|
/// The highest `side` a lattice can have.
///
/// The cap is storage, not arithmetic. Cells live in one flat `Array` and
/// `Array` is indexed by `Int`, which is 32-bit on the wasm target - the
/// compiler rejects the literal `2147483648` as an `Int` - so `side^4` cells
/// have to stay addressable by a 32-bit index, and `215^4 - 1 = 2136750624`
/// is the largest cell count that fits.
///
/// With `Int64` index arithmetic alone the bound would be 55108 (`55108^4 =
/// 9222710978872688896`); raising it needs storage that is not one flat array,
/// which is a separate change and is recorded in LOOP.md rather than folded in.
pub const MAX_SIDE : Int64 = 215

///|
/// Sudoku digits live in `1..side`; 0 means "this cell carries no digit".
///
/// The only constant here that does not come from a lattice, because it is a
/// sentinel rather than a size.
pub const NO_DIGIT : Int64 = 0L

///|
/// The shape of a lattice: `side` cells along each of four fixed axes.
///
/// Built only by `lattice_of`. The strides are stored rather than recomputed
/// because `index0` is the hottest function in the library and `side^3` is three
/// multiplications it does not need to repeat on every call.
///
/// The fields are **private**, and that is the load-bearing part. A lattice is
/// eight numbers that have to agree with each other — `total` is `side^4`, the
/// strides are the powers of `side`, `first_position` is 1 — and the library
/// divides by the side and by the strides. A lattice with `side = 0` or
/// `stride_y = 0` was therefore a divide by zero away, and it used to be one
/// field assignment away: the fields were public, so a caller could hand the
/// library a lattice it would never have built, and the failure surfaced
/// later, somewhere else, as a different kind of failure.
///
/// Private fields make that impossible rather than merely discouraged. The
/// only way to get a `Lattice` is `lattice_of`, which refuses a side it
/// cannot address; the accessors below are how a caller reads the shape.
pub struct Lattice {
  priv side : Int64
  priv total : Int64
  priv first_position : Int64
  priv last_position : Int64
  priv max_digit : Int64
  priv stride_y : Int64
  priv stride_z : Int64
  priv stride_w : Int64
}

///|
/// The side: cells along each of the four axes.
pub fn Lattice::side(self : Lattice) -> Int64 {
  self.side
}

///|
/// The whole lattice: `side^4` cells.
pub fn Lattice::total(self : Lattice) -> Int64 {
  self.total
}

///|
/// The first position, 1-based, matching the C# `grid_position`.
pub fn Lattice::first_position(self : Lattice) -> Int64 {
  self.first_position
}

///|
/// The last position, 1-based, inclusive.
pub fn Lattice::last_position(self : Lattice) -> Int64 {
  self.last_position
}

///|
/// The largest digit a cell may hold: `1..side`, with `0` meaning none.
pub fn Lattice::max_digit(self : Lattice) -> Int64 {
  self.max_digit
}

///|
/// Builds the lattice shape for `side` cells per axis.
///
/// Two refusals, deliberately kept apart rather than merged into one range
/// check, because they are different mistakes: a side below 1 asks for a
/// lattice with no cells, and a side above `MAX_SIDE` asks for more cells than
/// the store can address. The message names which one happened, and never
/// computes `side^4` on the way to saying so - a large `side` would overflow
/// while the error was being formatted.
pub fn lattice_of(side : Int64) -> Result[Lattice, String] {
  if side < 1L {
    return Err("side must be at least 1, got " + side.to_string())
  }
  if side > MAX_SIDE {
    return Err(
      "side " +
      side.to_string() +
      " is above the maximum " +
      MAX_SIDE.to_string() +
      " (cells are stored in one flat array indexed by a 32-bit Int)",
    )
  }
  let s2 = side * side
  let s3 = s2 * side
  let total = s3 * side
  let lat = {
    side,
    total,
    first_position: 1L,
    last_position: total,
    max_digit: side,
    stride_y: s3,
    stride_z: s2,
    stride_w: side,
  }
  Ok(lat)
}

///|
/// The 3-per-axis lattice: the original 81-cell store.
///
/// Used wherever a caller has no lattice of its own to name, which in practice
/// means the defaults in the CLI and the fixtures in the test suite.
pub fn default_lattice() -> Lattice {
  match lattice_of(3L) {
    Ok(lat) => lat
    Err(_) => abort("default_lattice: lattice_of(3) cannot fail")
  }
}

///|
/// The array slot holding 1-based `position`.
///
/// The single narrowing from `Int64` to `Int` in the whole library. It is safe
/// exactly because `lattice_of` caps `side` at `MAX_SIDE`, so `position` never
/// exceeds `MAX_SIDE^4` and always fits a 32-bit index. Widening `MAX_SIDE` means
/// widening this, not just relaxing a guard.
pub fn slot_of(position : Int64) -> Int32 {
  (position - 1L).to_int()
}

///|
/// A cell in the 4D lattice. Each coordinate is in `0..side-1`.
///
/// Equality and debug output are structural; the `extend` declarations keep the
/// trait methods from being implicitly promoted as regular methods, which the
/// compiler warns about.
pub struct Coords {
  x : Int64
  y : Int64
  z : Int64
  w : Int64
} derive(Eq, Debug)

///|
pub extend Coords with Eq::{equal, not_equal}

///|
pub extend Coords with @debug.Debug::{to_repr}

///|
/// Builds a coordinate tuple. Does not check bounds; use `parse_coords` or
/// `coords_of` for a checked one.
pub fn coords(x : Int64, y : Int64, z : Int64, w : Int64) -> Coords {
  { x, y, z, w, }
}

///|
/// One coordinate inside the lattice.
fn coord_in_bounds(v : Int64, side : Int64) -> Bool {
  v >= 0L && v < side
}

///|
/// True when every coordinate is inside `lat`.
pub fn coords_in_bounds(lat : Lattice, c : Coords) -> Bool {
  coord_in_bounds(c.x, lat.side) &&
  coord_in_bounds(c.y, lat.side) &&
  coord_in_bounds(c.z, lat.side) &&
  coord_in_bounds(c.w, lat.side)
}

///|
/// True when `p` is a valid 1-based position in `lat`.
pub fn position_in_bounds(lat : Lattice, p : Int64) -> Bool {
  p >= lat.first_position && p <= lat.last_position
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
pub fn coord_at(c : Coords, axis : Int64) -> Int64? {
  if axis < 0L || axis >= DIM {
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
fn coord_at_unchecked(c : Coords, axis : Int64) -> Int64 {
  match axis {
    0L => c.x
    1L => c.y
    2L => c.z
    _ => c.w
  }
}

///|
/// `c` with its `axis`-th coordinate replaced by `v`.
pub fn with_coord(c : Coords, axis : Int64, v : Int64) -> Coords {
  match axis {
    0L => { x: v, y: c.y, z: c.z, w: c.w, }
    1L => { x: c.x, y: v, z: c.z, w: c.w, }
    2L => { x: c.x, y: c.y, z: v, w: c.w, }
    _ => { x: c.x, y: c.y, z: c.z, w: v, }
  }
}

///|
/// Zero-based row-major index of `c` in `lat`.
///
/// Was `x*27 + y*9 + z*3 + w` with the strides written out as literals. At
/// `side == 3` the stored strides are 27, 9 and 3, so this is the same
/// arithmetic on the same cells; the literals were only ever a spelling of the
/// strides.
pub fn index0(lat : Lattice, c : Coords) -> Int64 {
  c.x * lat.stride_y + c.y * lat.stride_z + c.z * lat.stride_w + c.w
}

///|
/// The 1-based position of `c` in `lat`.
pub fn position_of(lat : Lattice, c : Coords) -> Int64 {
  index0(lat, c) + lat.first_position
}

///|
/// The coordinate at 1-based position `p` in `lat`.
///
/// Returns `None` for positions outside `1..total`; the caller decides whether
/// that is an error or just an empty result.
pub fn coords_of(lat : Lattice, p : Int64) -> Coords? {
  if !position_in_bounds(lat, p) {
    return None
  }
  let i = p - lat.first_position
  Some(
    coords(
      i / lat.stride_y,
      i / lat.stride_z % lat.side,
      i / lat.stride_w % lat.side,
      i % lat.side,
    ),
  )
}

///|
/// Every cell, in row-major order. Length is always `total`.
pub fn all_coords(lat : Lattice) -> Array[Coords] {
  let out : Array[Coords] = []
  let mut i = lat.first_position
  while i <= lat.last_position {
    out.push(coords_of(lat, i).unwrap())
    i = i + 1L
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
/// Parses `(x,y,z,w)` or `x,y,z,w` into four integers, with no bounds check.
///
/// Split out from `parse_coords` because an importer needs to tell two failures
/// apart. `parse_coords` collapses "not four integers" and "an integer outside
/// the lattice" into one `None`, so a caller cannot report *which* coordinate of
/// a file record did not fit the target lattice. Importing a 3-per-axis file
/// into a 2-per-axis one has to be able to name the offending coordinate, and
/// that needs the parsed value in hand even when it is out of range.
pub fn parse_coords_raw(s : String) -> Coords? {
  let t = trim_ws(s)
  let body = if t.length() >= 2 && t.at(0) == '(' && t.at(t.length() - 1) == ')' {
    slice(t, 1, t.length() - 1)
  } else {
    t
  }
  let parts = split(body, ",")
  if parts.length() != DIM.to_int() {
    return None
  }
  let vals : Array[Int64] = []
  let mut i = 0L
  while i < DIM {
    match parse_int(parts[i.to_int()]) {
      Some(v) => vals.push(v.to_int64())
      None => return None
    }
    i = i + 1L
  }
  Some(coords(vals[0], vals[1], vals[2], vals[3]))
}

///|
/// Parses `(x,y,z,w)` or `x,y,z,w`.
///
/// Every coordinate must be an integer in `0..side-1`; anything else is `None`
/// rather than a clamped value, so a malformed address can never silently
/// address a different cell than the caller asked for.
pub fn parse_coords(lat : Lattice, s : String) -> Coords? {
  match parse_coords_raw(s) {
    Some(c) => if coords_in_bounds(lat, c) { Some(c) } else { None }
    None => None
  }
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
/// neighbour on a `side`-long axis - so an empty result is unambiguously a bad
/// axis and not a cell that happens to stand alone.
pub fn neighbours(lat : Lattice, c : Coords, axis : Int64) -> Array[Coords] {
  let out : Array[Coords] = []
  let here = match coord_at(c, axis) {
    None => return out
    Some(v) => v
  }
  if here - 1L >= 0L {
    out.push(with_coord(c, axis, here - 1L))
  }
  if here + 1L < lat.side {
    out.push(with_coord(c, axis, here + 1L))
  }
  out
}

///|
/// True when `a` and `b` share one axis-parallel line.
///
/// Two cells are on a common line exactly when they agree on all but one
/// coordinate, i.e. differ along a single axis.
pub fn shares_line(a : Coords, b : Coords) -> Bool {
  let mut same = 0L
  if a.x == b.x {
    same = same + 1L
  }
  if a.y == b.y {
    same = same + 1L
  }
  if a.z == b.z {
    same = same + 1L
  }
  if a.w == b.w {
    same = same + 1L
  }
  same >= DIM - 1L
}
