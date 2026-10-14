///|
/// The window's view of the store.
///
/// The GUI owns exactly one 81-cell lattice, created here at module
/// initialisation and mutated in place by every command handler. A top-level
/// `let` is a mutable place in MoonBit, so the store - including the insert
/// cursor inside it - survives across command invocations instead of being
/// rebuilt per request.

///|
/// The store the window drives. Reads `@tesseract.Tesseract` and mutates it.
let db : @tesseract.Tesseract = @tesseract.new_db(
  "Tesseract",
  @tesseract.new_logger("Tesseract"),
)

///|
/// How many log entries the window keeps on screen.
const LOG_TAIL : Int = 40

///|
/// One lattice cell as the page needs it: its position, its four coordinates,
/// and whatever it currently holds.
struct CellView {
  position : Int
  x : Int
  y : Int
  z : Int
  w : Int
  key : String
  value : String
  digit : Int
  timestamp : String
  occupied : Bool
} derive(ToJson)

///|
/// One log line, newest last.
struct LogView {
  seq : Int
  stamp : String
  level : String
  message : String
  details : String
} derive(ToJson)

///|
/// Sudoku health over the whole lattice, not just the visible plane: how many
/// cells carry a digit, which axis-parallel lines are broken, and whether the
/// assignment is a complete solution.
struct PuzzleView {
  placed : Int
  violations : Array[String]
  complete : Bool
} derive(ToJson)

///|
/// The status line the C# view model showed above the grid.
struct StatusView {
  db_name : String
  total_cells : Int
  occupancy : Int
  cursor : Int
  digit_count : Int
} derive(ToJson)

///|
/// Everything one repaint needs. Sent after every mutation so the page never
/// has to reconcile two snapshots.
struct StateResp {
  status : StatusView
  plane_x : Int
  plane_y : Int
  cells : Array[CellView]
  puzzle : PuzzleView
  logs : Array[LogView]
} derive(ToJson)

///|
/// A `DBResponse` reduced to what the page shows. `text` is the library's own
/// `format_response` rendering, so the GUI prints exactly what the CLI and the
/// C# view model printed for the same statement.
struct RespView {
  success : Bool
  operation : String
  message : String
  error : String
  error_code : String
  affected_rows : Int
  position : Int
  total_records : Int
  text : String
} derive(ToJson)

///|
/// A `SELECT` row.
struct RecordView {
  key : String
  value : String
  position : Int
  coords : String
  timestamp : String
  digit : Int
} derive(ToJson)

///|
/// The view of one cell, empty or not.
fn cell_view(position : Int) -> CellView {
  let c = @tesseract.coords_of(position).unwrap()
  match @tesseract.Tesseract::cell_at(db, position) {
    Some(cell) =>
      CellView::{
        position,
        x: c.x,
        y: c.y,
        z: c.z,
        w: c.w,
        key: cell.key,
        value: cell.value,
        digit: cell.digit,
        timestamp: cell.timestamp,
        occupied: !@tesseract.cell_is_empty(cell),
      }
    None =>
      CellView::{
        position,
        x: c.x,
        y: c.y,
        z: c.z,
        w: c.w,
        key: "",
        value: "",
        digit: 0,
        timestamp: "",
        occupied: false,
      }
  }
}

///|
/// The nine cells of the plane at `(x, y)`, in row-major order over `(z, w)`.
///
/// `(x, y)` picks one of the nine 3x3 boxes; `(z, w)` is the classic row and
/// column inside it. `position = 1 + x*27 + y*9 + z*3 + w` is the library's
/// own formula, not a second one.
fn plane_cells(x : Int, y : Int) -> Array[CellView] {
  let out : Array[CellView] = []
  let mut row = 0
  while row < @tesseract.SIDE {
    let mut col = 0
    while col < @tesseract.SIDE {
      out.push(cell_view(1 + x * 27 + y * 9 + row * 3 + col))
      col = col + 1
    }
    row = row + 1
  }
  out
}

///|
/// Occupancy, cursor and digit count.
fn status_view() -> StatusView {
  let s = @tesseract.Tesseract::status(db)
  StatusView::{
    db_name: s.db_name,
    total_cells: s.total_cells,
    occupancy: s.current_count,
    cursor: s.current_position,
    digit_count: s.digit_count,
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
/// Sudoku health over all 81 cells.
///
/// The digits are read back out of the cells rather than kept beside them, so
/// this cannot drift from what the store actually holds.
fn puzzle_view() -> PuzzleView {
  let d = @tesseract.empty_digits()
  let mut placed = 0
  let mut p = @tesseract.FIRST_POSITION
  while p <= @tesseract.LAST_POSITION {
    match @tesseract.Tesseract::cell_at(db, p) {
      Some(cell) =>
        if cell.digit != @tesseract.NO_DIGIT {
          @tesseract.set_digit(d, p, cell.digit)
          placed = placed + 1
        }
      None => ()
    }
    p = p + 1
  }
  PuzzleView::{
    placed,
    violations: @tesseract.line_violations(d),
    complete: @tesseract.is_solution(d),
  }
}

///|
/// A full repaint of one plane.
fn state_resp(x : Int, y : Int) -> StateResp {
  StateResp::{
    status: status_view(),
    plane_x: clamp_axis(x),
    plane_y: clamp_axis(y),
    cells: plane_cells(clamp_axis(x), clamp_axis(y)),
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
fn clamp_axis(v : Int) -> Int {
  if v < 0 || v >= @tesseract.SIDE {
    0
  } else {
    v
  }
}

///|
/// A library response, rendered the way the C# view model rendered it.
fn resp_view(r : @tesseract.DBResponse) -> RespView {
  RespView::{
    success: r.success,
    operation: r.operation,
    message: r.message,
    error: r.error,
    error_code: r.error_code,
    affected_rows: r.affected_rows,
    position: r.position,
    total_records: r.total_records,
    text: @tesseract.format_response(r),
  }
}

///|
/// One result row.
fn record_view(r : @tesseract.Record) -> RecordView {
  RecordView::{
    key: r.key,
    value: r.value,
    position: r.position,
    coords: @tesseract.format_coords(r.coords),
    timestamp: r.timestamp,
    digit: r.digit,
  }
}

///|
/// Rows of a response, in order.
fn record_views(r : @tesseract.DBResponse) -> Array[RecordView] {
  r.data.map(fn(row) { record_view(row) })
}
