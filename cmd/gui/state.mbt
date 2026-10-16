///|
/// The window's view of the store.
///
/// The GUI owns exactly one lattice, created here at module initialisation and
/// mutated in place by every command handler. A top-level `let` is a mutable
/// place in MoonBit, so the store - including the insert cursor inside it -
/// survives across command invocations instead of being rebuilt per request.
///
/// The shape starts at the library's default (3 cells per axis, 81 cells) and the
/// page can change it with the side selector. What changed is where the shape
/// comes from: it is read back off the database rather than written out as a
/// constant, so the loops in this file follow whatever lattice the store
/// actually has.
///
/// The binding `db` itself cannot be replaced - MoonBit refuses `db = ...` with
/// "The variable db is not mutable" - so changing the side does not swap the
/// store. It calls `Tesseract::set_side`, which resizes the same `Tesseract` in
/// place and carries the records over by coordinate.
///
/// # Why the view numbers are `Int32` while the store's are `Int64`
///
/// Every struct in this file that carries a number crosses the JSON boundary,
/// and its number is `Int32` on that boundary only. Do not "fix" this back to
/// `Int64` to match the store: it silently breaks the window in both
/// directions.
///
/// `@json` treats `Int64` as a *string*. `ToJson` writes `Int64` as
/// `"81"` and `FromJson` accepts only a JSON string for an `Int64` field, so
/// an `Int64` field rejects the page's `1` with "expected number in string
/// representation" and sends back `{"position": "81"}` for a field the page
/// compares with `===` and `Set.has`. The page speaks JSON numbers; these
/// structs therefore have to carry JSON numbers.
///
/// The narrow loses nothing. `MAX_SIDE` caps a lattice at 215 cells per axis,
/// so the largest position the store can produce is `215^4 =
/// 2,136,750,625 < 2,147,483,647 = Int32::MAX`. Digits are at most `side`,
/// and counts are at most the cell count, so every number crossing here fits
/// an `Int32`. A JSON number loses precision above 2^53 anyway, long before
/// the value could outgrow 32 bits.
///
/// Only the wire narrows. The lattice, its strides and every piece of
/// arithmetic behind these structs stay `Int64`, and each value is converted
/// where it is put into a view - see `cell_view`, `status_view`,
/// `resp_view` and `record_view`.

///|
/// The store the window drives. Reads `@tesseract.Tesseract` and mutates it.
///
/// The clock is set on the logger *before* it goes into `new_db`, because
/// `new_db` keeps its own copy and the store's copy is the one that stamps.
/// The window shows the log tail and exports carry timestamps, so it reads the
/// host clock; the library default is the logical counter, which is what keeps
/// the test suite comparable between runs.
let db : @tesseract.Tesseract = {
  let logger = @tesseract.new_logger("Tesseract")
  @tesseract.TesseractLogger::set_clock(logger, @tesseract.system_clock())
  @tesseract.new_db("Tesseract", @tesseract.default_lattice(), logger)
}

///|
/// The lattice of the store this window drives.
///
/// Read rather than rebuilt, so no view can describe a different shape from the
/// one whose cells it is reading.
fn lattice() -> @tesseract.Lattice {
  @tesseract.Tesseract::lattice_of_db(db)
}

///|
/// How many log entries the window keeps on screen.
const LOG_TAIL : Int32 = 40

///|
/// One lattice cell as the page needs it: its position, its four coordinates,
/// and whatever it currently holds.
///
/// The numbers are `Int32` for the wire, not because a position fits in 32 bits
/// - it does, but `MAX_SIDE` is what makes that true - but because `@json`
/// encodes `Int64` as a string and the page speaks numbers. The file header has
/// the full argument; `MAX_SIDE^4` fits `Int32`, so nothing is lost.
struct CellView {
  position : Int32
  x : Int32
  y : Int32
  z : Int32
  w : Int32
  key : String
  value : String
  digit : Int32
  timestamp : String
  occupied : Bool
} derive(ToJson)

///|
/// One log line, newest last.
struct LogView {
  seq : Int32
  stamp : String
  level : String
  message : String
  details : String
} derive(ToJson)

///|
/// Sudoku health over the whole lattice, not just the visible plane: how many
/// cells carry a digit, which axis-parallel lines are broken, and whether the
/// assignment is a complete solution.
///
/// `placed` is `Int32` for the wire; it counts cells, so `MAX_SIDE^4` bounds
/// it and the narrow is lossless. See the file header.
struct PuzzleView {
  placed : Int32
  violations : Array[String]
  complete : Bool
} derive(ToJson)

///|
/// The status line the C# view model showed above the grid.
///
/// Every count is `Int32` for the wire. All four are bounded by the cell count,
/// which `MAX_SIDE^4` keeps inside `Int32`. See the file header.
struct StatusView {
  db_name : String
  total_cells : Int32
  occupancy : Int32
  cursor : Int32
  digit_count : Int32
} derive(ToJson)

///|
/// Everything one repaint needs. Sent after every mutation so the page never
/// has to reconcile two snapshots.
///
/// `side` is the cells-per-axis of the lattice this snapshot came from, and
/// `plane_x` / `plane_y` are `Int32` for the wire, narrowed from the clamped
/// `Int64` axis. See the file header.
///
/// `side` is on every snapshot rather than sent once at startup because the page
/// is not allowed to remember the shape: the selector, the plane pickers and the
/// digit list all have to be rebuilt from the lattice the cells actually came
/// from, and a page that remembered a stale `3` would quietly offer a digit the
/// store would reject.
struct StateResp {
  status : StatusView
  side : Int32
  plane_x : Int32
  plane_y : Int32
  cells : Array[CellView]
  puzzle : PuzzleView
  logs : Array[LogView]
} derive(ToJson)

///|
/// A `DBResponse` reduced to what the page shows. `text` is the library's own
/// `format_response` rendering, so the GUI prints exactly what the CLI and the
/// C# view model printed for the same statement.
///
/// The three numbers are `Int32` for the wire; rows and records cannot outnumber
/// the cells. See the file header.
struct RespView {
  success : Bool
  operation : String
  message : String
  error : String
  error_code : String
  affected_rows : Int32
  position : Int32
  total_records : Int32
  text : String
} derive(ToJson)

///|
/// A `SELECT` row.
///
/// `position` and `digit` are `Int32` for the wire, narrowed from the store's
/// `Int64`. `MAX_SIDE` bounds both. See the file header.
struct RecordView {
  key : String
  value : String
  position : Int32
  coords : String
  timestamp : String
  digit : Int32
} derive(ToJson)

///|
/// The view of one cell, empty or not.
///
/// Takes the cell's coordinates rather than its position because that is the
/// side that owns the shape: `position_of` asks the lattice how to number a
/// cell, where the old `x*27 + y*9 + z*3 + w` spelled its strides out again.
///
/// This is where the `Int64` store becomes an `Int32` view. The position is
/// requested from the lattice as an `Int64` and narrowed here; every value is
/// bounded by `MAX_SIDE^4`, which fits `Int32`.
fn cell_view(lat : @tesseract.Lattice, c : @tesseract.Coords) -> CellView {
  let position = @tesseract.position_of(lat, c)
  match @tesseract.Tesseract::cell_at(db, position) {
    Some(cell) =>
      CellView::{
        position: position.to_int(),
        x: c.x.to_int(),
        y: c.y.to_int(),
        z: c.z.to_int(),
        w: c.w.to_int(),
        key: cell.key,
        value: cell.value,
        digit: cell.digit.to_int(),
        timestamp: cell.timestamp,
        occupied: !@tesseract.cell_is_empty(cell),
      }
    None =>
      CellView::{
        position: position.to_int(),
        x: c.x.to_int(),
        y: c.y.to_int(),
        z: c.z.to_int(),
        w: c.w.to_int(),
        key: "",
        value: "",
        digit: @tesseract.NO_DIGIT.to_int(),
        timestamp: "",
        occupied: false,
      }
  }
}

///|
/// The cells of the plane at `(x, y)`, in row-major order over `(z, w)`.
///
/// `(x, y)` picks one of the `side^2` boxes; `(z, w)` is the classic row and
/// column inside it. The page walks the same cells as before - `side` of them
/// per row, `side` rows - but the count comes from the lattice rather than a
/// constant, so a wider plane would show all of its cells instead of the first
/// three rows and columns of it.
///
/// The axes stay `Int64` here: this loop is arithmetic over the lattice, not a
/// wire format. `state_resp` is where the plane narrows to what the page sees.
fn plane_cells(x : Int64, y : Int64) -> Array[CellView] {
  let lat = lattice()
  let out : Array[CellView] = []
  let mut row = 0L
  while row < lat.side {
    let mut col = 0L
    while col < lat.side {
      out.push(cell_view(lat, @tesseract.coords(x, y, row, col)))
      col = col + 1L
    }
    row = row + 1L
  }
  out
}

///|
/// Occupancy, cursor and digit count.
///
/// Narrowed from the store's `Int64` status; each is bounded by the cell count,
/// which `MAX_SIDE^4` keeps inside `Int32`.
fn status_view() -> StatusView {
  let s = @tesseract.Tesseract::status(db)
  StatusView::{
    db_name: s.db_name,
    total_cells: s.total_cells.to_int(),
    occupancy: s.current_count.to_int(),
    cursor: s.current_position.to_int(),
    digit_count: s.digit_count.to_int(),
  }
}

///|
/// The last `LOG_TAIL` entries, oldest first.
fn log_views() -> Array[LogView] {
  let all = @tesseract.TesseractLogger::entries(
    @tesseract.Tesseract::get_logger(db),
  )
  let out : Array[LogView] = []
  let start = if all.length() > LOG_TAIL { all.length() - LOG_TAIL } else { 0 }
  let mut i = start
  while i < all.length() {
    let e = all[i]
    out.push(LogView::{
      seq: e.seq,
      stamp: e.stamp,
      level: @tesseract.level_name(e.level),
      message: e.message,
      details: e.details,
    })
    i = i + 1
  }
  out
}

///|
/// Sudoku health over every cell.
///
/// The digits are read back out of the cells rather than kept beside them, so
/// this cannot drift from what the store actually holds. The walk is the
/// lattice's own `1..last_position`; it used to be the same walk written with
/// the two constants that no longer exist.
///
/// The walk counts in `Int64` and narrows once, at the view: `placed` cannot
/// exceed the cell count, which `MAX_SIDE^4` keeps inside `Int32`.
fn puzzle_view() -> PuzzleView {
  let lat = lattice()
  let d = @tesseract.empty_digits(lat)
  let mut placed = 0L
  let mut p = lat.first_position
  while p <= lat.last_position {
    match @tesseract.Tesseract::cell_at(db, p) {
      Some(cell) =>
        if cell.digit != @tesseract.NO_DIGIT {
          @tesseract.set_digit(lat, d, p, cell.digit)
          placed = placed + 1L
        }
      None => ()
    }
    p = p + 1L
  }
  PuzzleView::{
    placed: placed.to_int(),
    violations: @tesseract.line_violations(lat, d),
    complete: @tesseract.is_solution(lat, d),
  }
}

///|
/// A full repaint of one plane.
///
/// The plane arrives from the page as `Int32` - the wire type, see the file
/// header - and is widened back to the lattice's `Int64` for the arithmetic in
/// `clamp_axis` and `plane_cells`. Only the two echoed plane numbers narrow.
fn state_resp(x : Int32, y : Int32) -> StateResp {
  let lat = lattice()
  let plane_x = clamp_axis(x.to_int64())
  let plane_y = clamp_axis(y.to_int64())
  StateResp::{
    status: status_view(),
    side: lat.side.to_int(),
    plane_x: plane_x.to_int(),
    plane_y: plane_y.to_int(),
    cells: plane_cells(plane_x, plane_y),
    puzzle: puzzle_view(),
    logs: log_views(),
  }
}

///|

///|
/// Positions are 1-based and negative means "unconstrained on this axis", so
/// the page's 0..2 selectors cannot produce an invalid plane. The value is
/// still clamped rather than rejected, because a plane is a *view* choice and
/// there is no cell it could write to the wrong place.
fn clamp_axis(v : Int64) -> Int64 {
  if v < 0L || v >= lattice().side {
    0L
  } else {
    v
  }
}

///|
/// A library response, rendered the way the C# view model rendered it.
///
/// The three numbers are narrowed from the response's `Int64`. Rows and records
/// cannot outnumber the cells, so `MAX_SIDE^4` bounds them inside `Int32`.
fn resp_view(r : @tesseract.DBResponse) -> RespView {
  RespView::{
    success: r.success,
    operation: r.operation,
    message: r.message,
    error: r.error,
    error_code: r.error_code,
    affected_rows: r.affected_rows.to_int(),
    position: r.position.to_int(),
    total_records: r.total_records.to_int(),
    text: @tesseract.format_response(r),
  }
}

///|
/// One result row.
///
/// `position` and `digit` are narrowed from the record's `Int64`; `MAX_SIDE`
/// bounds both inside `Int32`.
fn record_view(r : @tesseract.Record) -> RecordView {
  RecordView::{
    key: r.key,
    value: r.value,
    position: r.position.to_int(),
    coords: @tesseract.format_coords(r.coords),
    timestamp: r.timestamp,
    digit: r.digit.to_int(),
  }
}

///|
/// Rows of a response, in order.
fn record_views(r : @tesseract.DBResponse) -> Array[RecordView] {
  r.data.map(fn(row) { record_view(row) })
}
