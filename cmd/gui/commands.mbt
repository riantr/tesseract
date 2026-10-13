///|
/// The command bridge between the page and the store.
///
/// Proton dispatches every call as an `app:<name>` operation: the page calls
/// `window.__MoonBit__.core.invokeOp("app:state", {...})` and receives this
/// package's typed response. Nothing in the page talks to the lattice
/// directly, so the GUI cannot bypass the store's rules - a digit collision
/// still comes back as `SUDOKU_CONFLICT`, with the library's own message.

///|
/// Which plane the page is looking at.
struct StateReq {
  x : Int
  y : Int
} derive(FromJson)

///|
/// A write. `op` is one of `insert`, `update`, `delete`, `clear`, `cursor`,
/// `solve`, `demo`; an absent `position` means "the insert cursor".
struct WriteReq {
  op : String
  key : String
  value : String
  position : Int?
  digit : Int?
  x : Int
  y : Int
} derive(FromJson)

///|
/// A write plus the repaint it implies.
struct WriteResp {
  response : RespView
  state : StateResp
} derive(ToJson)

///|
/// One SQL statement, plus the plane the page is looking at so the repaint
/// keeps showing it.
struct QueryReq {
  sql : String
  x : Int
  y : Int
} derive(FromJson)

///|
/// The response and its rows.
struct QueryResp {
  response : RespView
  rows : Array[RecordView]
  state : StateResp
} derive(ToJson)

///|
/// A lattice question about one cell. `kind` is `line`, `slab` or `peers`;
/// `axis` is 0..3 and is ignored for `peers`.
struct GeometryReq {
  position : Int
  kind : String
  axis : Int
  x : Int
  y : Int
} derive(FromJson)

///|
/// The occupied cells of that sub-structure, plus every position it covers so
/// the page can highlight empties too.
struct GeometryResp {
  response : RespView
  rows : Array[RecordView]
  positions : Array[Int]
  state : StateResp
} derive(ToJson)

///|
/// Which serialisation to render.
struct ExportReq {
  format : String
} derive(FromJson)

///|
/// The serialised store.
struct ExportResp {
  format : String
  text : String
} derive(ToJson)

///|
/// Text to load back in.
struct ImportReq {
  format : String
  text : String
  x : Int
  y : Int
} derive(FromJson)

///|
/// The import result and the repaint it implies.
struct ImportResp {
  ok : Bool
  detail : String
  state : StateResp
} derive(ToJson)

///|
/// Repaint the current plane.
let cmd_state : @proton_contract.Command[StateReq, StateResp] = @proton_contract.command(
  "state",
)

///|
/// Insert, update, delete, clear, move the cursor, or run a tour.
let cmd_write : @proton_contract.Command[WriteReq, WriteResp] = @proton_contract.command(
  "write",
)

///|
/// Run one SQL statement.
let cmd_query : @proton_contract.Command[QueryReq, QueryResp] = @proton_contract.command(
  "query",
)

///|
/// Line, slab or peer query around one cell.
let cmd_geometry : @proton_contract.Command[GeometryReq, GeometryResp] = @proton_contract.command(
  "geometry",
)

///|
/// Render the store as `.sdb`, Markdown, SQL, or the ASCII lattice.
let cmd_export : @proton_contract.Command[ExportReq, ExportResp] = @proton_contract.command(
  "export",
)

///|
/// Load a `.sdb`, Markdown or SQL dump back in.
let cmd_import : @proton_contract.Command[ImportReq, ImportResp] = @proton_contract.command(
  "import",
)

///|
/// Proton runs every bridge request as its own task, so two of these handlers
/// can be in flight at once. The store is a single global value, and a handler
/// that is interrupted between reading the lattice and writing it back loses
/// the update. Today each body is straight-line, so nothing actually
/// interleaves - but that is a property of the current code rather than of the
/// runtime, and the first `await` added to any handler would break it
/// invisibly. One mutex makes the guarantee explicit.
let store_lock : @async.Mutex = @async.Mutex::Mutex()

///|
/// Runs one handler body with exclusive access to the store.
async fn[T] locked(body : () -> T) -> T {
  store_lock.acquire()
  defer store_lock.release()
  body()
}

///|
/// Binds every command. Registration happens before the renderer bridge starts,
/// so the page can only ever reach these six operations.
fn register(registrar : @proton.CommandRegistrar) -> Unit raise {
  registrar.bind(cmd_state, async fn(_ctx, req) {
    locked(fn() { state_resp(req.x, req.y) })
  })
  registrar.bind(cmd_write, async fn(_ctx, req) {
    locked(fn() { handle_write(req) })
  })
  registrar.bind(cmd_query, async fn(_ctx, req) {
    locked(fn() { handle_query(req) })
  })
  registrar.bind(cmd_geometry, async fn(_ctx, req) {
    locked(fn() { handle_geometry(req) })
  })
  registrar.bind(cmd_export, async fn(_ctx, req) {
    locked(fn() { handle_export(req) })
  })
  registrar.bind(cmd_import, async fn(_ctx, req) {
    locked(fn() { handle_import(req) })
  })
}

///|
/// A write plus the repaint it implies.
fn handle_write(req : WriteReq) -> WriteResp {
  WriteResp::{ response: write_response(req), state: state_resp(req.x, req.y), }
}

///|
/// The response for one write verb.
///
/// Every branch ends in a `RespView` built from the library's own response, so
/// the error codes on screen are the C# vocabulary, not a second set invented
/// for the window.
fn write_response(req : WriteReq) -> RespView {
  // The page omits `position` when the box is empty, and that omission is the
  // only thing that means "use the insert cursor". A position the user typed
  // but that is out of range is passed straight through, so the library
  // answers INVALID_POSITION / POSITION_OUT_OF_RANGE instead of the write
  // silently landing on the cursor cell.
  let pos = req.position
  match req.op {
    "update" =>
      // `update` addresses the cell by key or position and keeps the cell's
      // own key, so an empty value would leave a record that `export_sdb`
      // skips and a re-import rejects with INVALID_INPUT - an invisible record
      // that reads as a successful write. The page's own hint already says
      // value cannot be empty; this is where that becomes true.
      if req.value == "" {
        RespView::{
          success: false,
          operation: "UPDATE",
          message: "操作失败",
          error: "UPDATE needs a value; an empty value would blank the record",
          error_code: "INVALID_INPUT",
          affected_rows: 0,
          position: 0,
          total_records: 0,
          text: "✗ 失败\n错误: UPDATE needs a value; an empty value would blank the record\n错误代码: INVALID_INPUT",
        }
      } else {
        resp_view(
          @sudokudb.SudokuDB::update(db, req.key, req.value, pos, req.digit),
        )
      }
    // `delete` with neither a key nor a position is the library's
    // clear-everything form. That is a whole-lattice wipe wearing the label of
    // a single delete, and the window has a separate button for it, so it is
    // refused here rather than reachable from an empty form.
    "delete" =>
      if req.key == "" && pos == None {
        RespView::{
          success: false,
          operation: "DELETE",
          message: "操作失败",
          error: "DELETE needs a key or a position; to empty the lattice use 清空整个点阵",
          error_code: "INVALID_INPUT",
          affected_rows: 0,
          position: 0,
          total_records: 0,
          text: "✗ 失败\n错误: DELETE needs a key or a position; to empty the lattice use 清空整个点阵\n错误代码: INVALID_INPUT",
        }
      } else {
        resp_view(@sudokudb.SudokuDB::delete(db, req.key, pos))
      }
    "clear" => resp_view(@sudokudb.SudokuDB::delete(db, "", None))
    "cursor" => cursor_response(pos)
    "solve" => solve_response()
    "demo" => demo_response()
    _ =>
      resp_view(
        @sudokudb.SudokuDB::insert(
          db,
          req.key,
          req.value,
          pos,
          digit_or_zero(req.digit),
        ),
      )
  }
}

///|
/// `set_position` reports nothing, so this builds the message the CLI's
/// `.pos` prints.
fn cursor_response(target : Int?) -> RespView {
  let wanted = match target {
    Some(p) => p
    None => 0
  }
  if !@sudokudb.position_in_bounds(wanted) {
    let text = "out of range: " + wanted.to_string() + " (expected 1..81)"
    return RespView::{
      success: false,
      operation: "CURSOR",
      message: "操作失败",
      error: text,
      error_code: "POSITION_OUT_OF_RANGE",
      affected_rows: 0,
      position: 0,
      total_records: 0,
      text,
    }
  }
  @sudokudb.SudokuDB::set_position(db, wanted)
  let here = @sudokudb.coords_of(wanted).unwrap()
  let text = "cursor -> " +
    wanted.to_string() +
    " " +
    @sudokudb.format_coords(here)
  RespView::{
    success: true,
    operation: "CURSOR",
    message: "插入光标 -> " +
    wanted.to_string() +
    " " +
    @sudokudb.format_coords(here),
    error: "",
    error_code: "",
    affected_rows: 0,
    position: wanted,
    total_records: 0,
    text,
  }
}

///|
/// Fills every cell from the closed-form solution, through the same SQL the
/// CLI's `.solve` runs, so the window and the command line agree cell for
/// cell.
fn solve_response() -> RespView {
  let digits = @sudokudb.canonical_digits()
  let mut filled = 0
  let mut first_failure = ""
  let mut p = @sudokudb.FIRST_POSITION
  while p <= @sudokudb.LAST_POSITION {
    let b = StringBuilder::StringBuilder()
    b.write_string("INSERT INTO sudokuDB (key, value, digit) VALUES ('cell_")
    b.write_object(p)
    b.write_string("', '{\"pos\": ")
    b.write_object(p)
    b.write_string("}', ")
    b.write_object(digits[p - 1])
    b.write_string(") AT ")
    b.write_object(p)
    b.write_char(';')
    let r = @sudokudb.execute(db, b.to_string())
    if r.success {
      filled = filled + 1
    } else if first_failure == "" {
      first_failure = " position " +
        p.to_string() +
        ": " +
        r.error_code +
        " (" +
        r.error +
        ")"
    }
    p = p + 1
  }
  let summary = "已按闭式解 digit(x,y,z,w) = (x+y+z+w) mod 3 + 1 填入 " +
    filled.to_string() +
    " 个格子" +
    first_failure
  RespView::{
    success: filled == @sudokudb.TOTAL,
    operation: "SOLVE",
    message: summary,
    error: first_failure,
    error_code: "",
    affected_rows: filled,
    position: 0,
    total_records: 0,
    text: summary,
  }
}

///|
/// The CLI's `.demo` tour, statement for statement.
///
/// The list is the CLI's, not a paraphrase: same statements, same order. The
/// window exists to show the same database the command line does, so a
/// "demo" that ended in a different cell state would be a lie. The clash is
/// found by its error code rather than by index, so reordering or extending
/// the list cannot silently detach the report from the step it describes.
fn demo_response() -> RespView {
  let steps = [
    "DELETE FROM sudokuDB;", "INSERT INTO sudokuDB (key, value) VALUES ('user_001', '{\"age\": 25}');",
    "INSERT INTO sudokuDB (key, value) VALUES ('user_002', '{\"age\": 30}');", "INSERT INTO sudokuDB (key, value) VALUES ('user_003', '{\"age\": 28}');",
    "SELECT * FROM sudokuDB;", "UPDATE sudokuDB SET value = '{\"age\": 26}' WHERE key = 'user_001';",
    "SELECT * FROM sudokuDB WHERE key = 'user_001';", "INSERT INTO sudokuDB (key, value, digit) VALUES ('d1', '{\"n\": 1}', 1) AT 1;",
    "INSERT INTO sudokuDB (key, value, digit) VALUES ('d2', '{\"n\": 2}', 1) AT 3;",
    "DELETE FROM sudokuDB WHERE key = 'user_003';",
  ]
  let mut applied = 0
  let mut clash = ""
  let mut i = 0
  while i < steps.length() {
    let r = @sudokudb.execute(db, steps[i])
    if r.error_code == "SUDOKU_CONFLICT" {
      clash = r.error_code + " (" + r.error + ")"
    }
    if r.success {
      applied = applied + 1
    }
    i = i + 1
  }
  let summary = "已按 CLI 的 .demo 逐条执行 " +
    steps.length().to_string() +
    " 条语句；digit 1 在共享行上的第二次落子被拒：" +
    clash
  RespView::{
    // Success is "the tour demonstrated what it claims", not "the last
    // statement happened to go through". Reading it off the final DELETE
    // meant the verdict depended on an arbitrary step: the tour reports OK
    // even if every statement before it failed, and FAIL if the clash step
    // ever moved. The clash is the one failure the tour exists to produce.
    success: clash != "",
    operation: "DEMO",
    message: summary,
    error: if clash == "" {
      "the tour did not reach its SUDOKU_CONFLICT step"
    } else {
      ""
    },
    error_code: "",
    affected_rows: applied,
    position: 0,
    total_records: @sudokudb.SudokuDB::occupancy(db),
    text: summary,
  }
}

///|
fn digit_or_zero(d : Int?) -> Int {
  match d {
    Some(v) => v
    None => @sudokudb.NO_DIGIT
  }
}

///|
/// One statement, then a repaint so a SQL `INSERT` shows up in the grid
/// without a second round trip.
///
/// The repaint keeps the caller's plane. Repainting plane (0,0) instead would
/// silently move the user off whatever they were looking at.
fn handle_query(req : QueryReq) -> QueryResp {
  let r = @sudokudb.execute(db, req.sql)
  QueryResp::{
    response: resp_view(r),
    rows: record_views(r),
    state: state_resp(req.x, req.y),
  }
}

///|
/// Line, slab or peers.
///
/// The covered positions come from the lattice functions rather than from the
/// result rows, because an empty cell still belongs to the sub-structure and
/// the page highlights it.
fn handle_geometry(req : GeometryReq) -> GeometryResp {
  let axis = clamp_axis(req.axis)
  // `kind` is resolved once and drives both halves of the answer. Dispatching
  // it twice - once for the covered positions, once for the rows - meant the
  // highlight and the result set could disagree with each other, and the
  // lattice was decoded twice to allow it.
  let (covered, r) = match @sudokudb.coords_of(req.position) {
    Some(c) =>
      match req.kind {
        "line" =>
          (
            positions_of(@sudokudb.line_through(c, axis)),
            @sudokudb.SudokuDB::line_query(db, req.position, axis),
          )
        "slab" =>
          (
            positions_of(@sudokudb.slab_through(c, axis)),
            @sudokudb.SudokuDB::slab_query(db, req.position, axis),
          )
        _ =>
          (
            positions_of(@sudokudb.peers(c)),
            @sudokudb.SudokuDB::peer_query(db, req.position),
          )
      }
    None =>
      (
        [],
        @sudokudb.err_response(
          "POSITION_OUT_OF_RANGE",
          "Position out of range: " + req.position.to_string(),
        ),
      )
  }
  GeometryResp::{
    response: resp_view(r),
    rows: record_views(r),
    positions: covered,
    state: state_resp(req.x, req.y),
  }
}

///|
/// Positions of a set of cells.
fn positions_of(cells : Array[@sudokudb.Coords]) -> Array[Int] {
  cells.map(fn(c) { @sudokudb.position_of(c) })
}

///|
fn handle_export(req : ExportReq) -> ExportResp {
  let text = match req.format {
    "md" => @sudokudb.export_markdown(db)
    "sql" => @sudokudb.export_sql(db)
    "lattice" =>
      @sudokudb.render_lattice(
        db,
        @sudokudb.SudokuDB::status(db).current_position,
      )
    _ => @sudokudb.export_sdb(db)
  }
  ExportResp::{ format: req.format, text, }
}

///|
/// Import reports through the library's own `Result`, so the page shows the
/// same message the CLI prints.
///
/// `lattice` is export-only: it is a rendering, and handing it to
/// `import_sdb` would fail with "Not valid JSON" while looking like a user
/// mistake. It is refused with its own message instead.
fn handle_import(req : ImportReq) -> ImportResp {
  let outcome = match req.format {
    "md" => @sudokudb.import_markdown(db, req.text)
    "sql" => @sudokudb.import_sql(db, req.text)
    "lattice" =>
      Err("lattice is an export-only rendering; choose sdb, md or sql")
    _ => @sudokudb.import_sdb(db, req.text)
  }
  let (ok, detail) = match outcome {
    // The SQL importer counts the statements it ran, not the rows it wrote, so
    // a round trip reports one more than the record count. Say which it is.
    Ok(n) =>
      if req.format == "sql" {
        (true, "Executed " + n.to_string() + " statement(s)")
      } else {
        (true, "Imported " + n.to_string() + " record(s)")
      }
    Err(message) => (false, message)
  }
  ImportResp::{ ok, detail, state: state_resp(req.x, req.y), }
}
