///|
/// The command bridge between the page and the store.
///
/// Proton dispatches every call as an `app:<name>` operation: the page calls
/// `window.__MoonBit__.core.invokeOp("app:state", {...})` and receives this
/// package's typed response. Nothing in the page talks to the lattice
/// directly, so the GUI cannot bypass the store's rules - a digit collision
/// still comes back as `SUDOKU_CONFLICT`, with the library's own message.
///
/// # Why the request numbers are `Int32` while the lattice's are `Int64`
///
/// Every number a request struct carries crosses the JSON boundary on its way
/// in, and it is `Int32` on that boundary only. Do not "fix" this back to
/// `Int64` to match the lattice: it breaks the window immediately.
///
/// `@json` treats `Int64` as a *string*. `FromJson` accepts only a JSON string
/// for an `Int64` field, so the page's `{x: 1}` is rejected with "expected
/// number in string representation" and every command fails at the bridge
/// before a handler runs. The page speaks JSON numbers; these structs therefore
/// have to carry JSON numbers.
///
/// The narrow loses nothing. `MAX_SIDE` caps a lattice at 215 cells per axis,
/// so the largest position the store can produce is `215^4 =
/// 2,136,750,625 < 2,147,483,647 = Int32::MAX`; digits are at most `side`, and
/// the page's own position input is already refused outside `+-2^31`. A JSON
/// number loses precision above 2^53 anyway.
///
/// Only the wire narrows. Everything past it is `Int64` again: `widen` turns a
/// request field back into the lattice's type on the first line of a handler,
/// and the view structs in `state.mbt` narrow on the way out. `state.mbt` has
/// the same argument written out in full.

///|
/// A change of shape: how many cells per axis the store should have.
///
/// `x` and `y` are the plane the page is looking at. They are sent back
/// unchanged on purpose - a resize rewinds the cursor and the plane pickers are
/// rebuilt from the new side, so clamping them here would only hide what the
/// store decided.
struct LatticeReq {
  side : Int32
  x : Int32
  y : Int32
} derive(FromJson)

///|
/// The resize result and the repaint it implies.
struct LatticeResp {
  response : RespView
  state : StateResp
} derive(ToJson)

///|
/// Which plane the page is looking at.
///
/// `Int32` for the wire, see the file header: `@json` would decode an `Int64`
/// field only from a JSON string, and the page sends numbers. Both axes are
/// widened to the lattice's `Int64` by `state_resp` before they are used.
struct StateReq {
  x : Int32
  y : Int32
} derive(FromJson)

///|
/// A write. `op` is one of `insert`, `update`, `delete`, `clear`, `cursor`,
/// `solve`, `demo`; an absent `position` means "the insert cursor".
///
/// `position`, `digit` and the plane axes are `Int32` for the wire, see the
/// file header. `widen` hands them to the store as `Int64`.
struct WriteReq {
  op : String
  key : String
  value : String
  position : Int32?
  digit : Int32?
  x : Int32
  y : Int32
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
///
/// The plane axes are `Int32` for the wire, see the file header.
struct QueryReq {
  sql : String
  x : Int32
  y : Int32
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
///
/// `position`, `axis` and the plane axes are `Int32` for the wire, see the file
/// header; the handler widens them to the lattice's `Int64`.
struct GeometryReq {
  position : Int32
  kind : String
  axis : Int32
  x : Int32
  y : Int32
} derive(FromJson)

///|
/// The occupied cells of that sub-structure, plus every position it covers so
/// the page can highlight empties too.
///
/// `positions` is `Array[Int32]` for the wire, see the file header; a lattice's
/// positions never exceed `MAX_SIDE^4`, which fits `Int32`.
struct GeometryResp {
  response : RespView
  rows : Array[RecordView]
  positions : Array[Int32]
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
///
/// The plane axes are `Int32` for the wire, see the file header.
struct ImportReq {
  format : String
  text : String
  x : Int32
  y : Int32
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
/// Change how many cells each axis has.
let cmd_lattice : @proton_contract.Command[LatticeReq, LatticeResp] = @proton_contract.command(
  "lattice",
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
/// Render the store as `.tsr`, Markdown, SQL, or the ASCII lattice.
let cmd_export : @proton_contract.Command[ExportReq, ExportResp] = @proton_contract.command(
  "export",
)

///|
/// Load a `.tsr`, Markdown or SQL dump back in.
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
/// so the page can only ever reach these seven operations.
fn register(registrar : @proton.CommandRegistrar) -> Unit raise {
  registrar.bind(cmd_state, async fn(_ctx, req) {
    locked(fn() { state_resp(req.x, req.y) })
  })
  registrar.bind(cmd_lattice, async fn(_ctx, req) {
    locked(fn() { handle_lattice(req) })
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
/// A change of shape, plus the repaint it implies.
///
/// The store is resized **in place** rather than replaced. The `db` binding
/// cannot be reassigned — MoonBit refuses `db = ...` with "The variable db is
/// not mutable" — and holding it in an `Array` element does not work either,
/// because reading the element copies the struct and its `mut current_position`
/// is lost with the copy (measured: a cyclic insert through `store[0]` left the
/// cursor at 1 rather than advancing to 2). `Tesseract::set_side` rebuilds the
/// same store's lattice and cells in place, so everything the page already held
/// keeps pointing at the live store.
///
/// The repaint keeps the caller's plane; `clamp_axis` already drops one that no
/// longer exists, which is what should happen when a resize shrinks the lattice.
fn handle_lattice(req : LatticeReq) -> LatticeResp {
  match @tesseract.Tesseract::set_side(db, req.side.to_int64()) {
    Err(message) =>
      LatticeResp::{
        response: RespView::{
          success: false,
          operation: "LATTICE",
          message: "操作失败",
          error: message,
          error_code: "INVALID_SIDE",
          affected_rows: 0,
          position: 0,
          total_records: @tesseract.Tesseract::occupancy(db).to_int(),
          text: "✗ 失败\n错误: " + message,
        },
        state: state_resp(req.x, req.y),
      }
    Ok(r) => {
      let s = r.to_side.to_string()
      let summary = "点阵已改为 " +
        s +
        "×" +
        s +
        "×" +
        s +
        "×" +
        s +
        "；按坐标保留 " +
        r.kept.to_string() +
        " 条" +
        (if r.dropped > 0L {
          "，丢弃 " +
          r.dropped.to_string() +
          " 条（坐标超出新点阵）"
        } else {
          ""
        })
      LatticeResp::{
        response: RespView::{
          success: true,
          operation: "LATTICE",
          message: summary,
          error: "",
          error_code: "",
          affected_rows: r.kept.to_int(),
          position: 0,
          total_records: @tesseract.Tesseract::occupancy(db).to_int(),
          text: "✓ 成功\n操作: LATTICE\n" + summary,
        },
        state: state_resp(req.x, req.y),
      }
    }
  }
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
  let pos = widen(req.position)
  match req.op {
    "update" =>
      // `update` addresses the cell by key or position and keeps the cell's
      // own key, so an empty value would leave a record that `export_tsr`
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
          @tesseract.Tesseract::update(
            db,
            req.key,
            req.value,
            pos,
            widen(req.digit),
          ),
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
        resp_view(@tesseract.Tesseract::delete(db, req.key, pos))
      }
    "clear" => resp_view(@tesseract.Tesseract::delete(db, "", None))
    "cursor" => cursor_response(pos)
    "solve" => solve_response()
    "demo" => demo_response()
    _ =>
      resp_view(
        @tesseract.Tesseract::insert(
          db,
          req.key,
          req.value,
          pos,
          digit_or_zero(widen(req.digit)),
        ),
      )
  }
}

///|
/// `set_position` reports nothing, so this builds the message the CLI's
/// `.pos` prints.
fn cursor_response(target : Int64?) -> RespView {
  let lat = lattice()
  let wanted = match target {
    Some(p) => p
    None => 0L
  }
  if !@tesseract.position_in_bounds(lat, wanted) {
    let text = "out of range: " +
      wanted.to_string() +
      " (expected 1.." +
      lat.last_position().to_string() +
      ")"
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
  @tesseract.Tesseract::set_position(db, wanted)
  let here = @tesseract.coords_of(lat, wanted).unwrap()
  let text = "cursor -> " +
    wanted.to_string() +
    " " +
    @tesseract.format_coords(here)
  RespView::{
    success: true,
    operation: "CURSOR",
    message: "插入光标 -> " +
    wanted.to_string() +
    " " +
    @tesseract.format_coords(here),
    error: "",
    error_code: "",
    affected_rows: 0,
    position: wanted.to_int(),
    total_records: 0,
    text,
  }
}

///|
/// Fills every cell from the closed-form solution, through the same SQL the
/// CLI's `.solve` runs, so the window and the command line agree cell for
/// cell.
fn solve_response() -> RespView {
  let lat = lattice()
  let digits = @tesseract.canonical_digits(lat)
  let mut filled = 0L
  let mut first_failure = ""
  let mut p = lat.first_position()
  while p <= lat.last_position() {
    let b = StringBuilder::StringBuilder()
    b.write_string("INSERT INTO tesseract (key, value, digit) VALUES ('cell_")
    b.write_object(p)
    b.write_string("', '{\"pos\": ")
    b.write_object(p)
    b.write_string("}', ")
    // `digits` is indexed by array slot, and `slot_of` is the function that
    // turns a 1-based position into one. It is not `p.to_int()` and it is not
    // `slot_of(p - 1)`: both of those shift the answer by one cell.
    b.write_object(digits[@tesseract.slot_of(p)])
    b.write_string(") AT ")
    b.write_object(p)
    b.write_char(';')
    let r = @tesseract.execute(db, b.to_string())
    if r.success {
      filled = filled + 1L
    } else if first_failure == "" {
      first_failure = " position " +
        p.to_string() +
        ": " +
        r.error_code +
        " (" +
        r.error +
        ")"
    }
    p = p + 1L
  }
  let summary = "已按闭式解 digit(x,y,z,w) = (x+y+z+w) mod 3 + 1 填入 " +
    filled.to_string() +
    " 个格子" +
    first_failure
  RespView::{
    success: filled == lat.total(),
    operation: "SOLVE",
    message: summary,
    error: first_failure,
    error_code: "",
    affected_rows: filled.to_int(),
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
    "DELETE FROM tesseract;", "INSERT INTO tesseract (key, value) VALUES ('user_001', '{\"age\": 25}');",
    "INSERT INTO tesseract (key, value) VALUES ('user_002', '{\"age\": 30}');", "INSERT INTO tesseract (key, value) VALUES ('user_003', '{\"age\": 28}');",
    "SELECT * FROM tesseract;", "UPDATE tesseract SET value = '{\"age\": 26}' WHERE key = 'user_001';",
    "SELECT * FROM tesseract WHERE key = 'user_001';", "INSERT INTO tesseract (key, value, digit) VALUES ('d1', '{\"n\": 1}', 1) AT 1;",
    "INSERT INTO tesseract (key, value, digit) VALUES ('d2', '{\"n\": 2}', 1) AT 3;",
    "DELETE FROM tesseract WHERE key = 'user_003';",
  ]
  let mut applied = 0L
  let mut clash = ""
  let mut i = 0
  while i < steps.length() {
    let r = @tesseract.execute(db, steps[i])
    if r.error_code == "SUDOKU_CONFLICT" {
      clash = r.error_code + " (" + r.error + ")"
    }
    if r.success {
      applied = applied + 1L
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
    affected_rows: applied.to_int(),
    position: 0,
    total_records: @tesseract.Tesseract::occupancy(db).to_int(),
    text: summary,
  }
}

///|
/// A page-supplied optional field as the store's `Int64`.
///
/// The request structs are `Int32` because of the wire format, not because the
/// lattice is 32-bit, so every optional field is widened back the moment a
/// handler reaches for it. `None` stays `None`: an absent `position` is how the
/// page says "use the insert cursor", and widening it to a zero would turn that
/// into a real request against cell 0.
fn widen(v : Int32?) -> Int64? {
  match v {
    Some(n) => Some(n.to_int64())
    None => None
  }
}

///|
fn digit_or_zero(d : Int64?) -> Int64 {
  match d {
    Some(v) => v
    None => @tesseract.NO_DIGIT
  }
}

///|
/// One statement, then a repaint so a SQL `INSERT` shows up in the grid
/// without a second round trip.
///
/// The repaint keeps the caller's plane. Repainting plane (0,0) instead would
/// silently move the user off whatever they were looking at.
fn handle_query(req : QueryReq) -> QueryResp {
  let r = @tesseract.execute(db, req.sql)
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
  let lat = lattice()
  // The request arrives in the wire's `Int32`; the lattice is `Int64`, so both
  // the position and the axis are widened once, here, and stay that way for
  // the rest of the handler.
  let position = req.position.to_int64()
  let axis = clamp_axis(req.axis.to_int64())
  // `kind` is resolved once and drives both halves of the answer. Dispatching
  // it twice - once for the covered positions, once for the rows - meant the
  // highlight and the result set could disagree with each other, and the
  // lattice was decoded twice to allow it.
  let (covered, r) = match @tesseract.coords_of(lat, position) {
    Some(c) =>
      match req.kind {
        "line" =>
          (
            positions_of(lat, @tesseract.line_through(lat, c, axis)),
            @tesseract.Tesseract::line_query(db, position, axis),
          )
        "slab" =>
          (
            positions_of(lat, @tesseract.slab_through(lat, c, axis)),
            @tesseract.Tesseract::slab_query(db, position, axis),
          )
        _ =>
          (
            positions_of(lat, @tesseract.peers(lat, c)),
            @tesseract.Tesseract::peer_query(db, position),
          )
      }
    None =>
      (
        [],
        @tesseract.err_response(
          "POSITION_OUT_OF_RANGE",
          "Position out of range: " + position.to_string(),
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
///
/// Numbered by the lattice, which is the only thing that knows how a
/// coordinate maps onto a position. The answer goes straight into
/// `GeometryResp.positions` and from there onto the wire, so it is narrowed
/// here rather than as a second pass in the handler; `MAX_SIDE^4` keeps every
/// position inside `Int32`.
fn positions_of(
  lat : @tesseract.Lattice,
  cells : Array[@tesseract.Coords],
) -> Array[Int32] {
  cells.map(fn(c) { @tesseract.position_of(lat, c).to_int() })
}

///|
fn handle_export(req : ExportReq) -> ExportResp {
  let text = match req.format {
    "md" => @tesseract.export_markdown(db)
    "sql" => @tesseract.export_sql(db)
    "lattice" =>
      @tesseract.render_lattice(
        db,
        @tesseract.Tesseract::status(db).current_position,
      )
    _ => @tesseract.export_tsr(db)
  }
  ExportResp::{ format: req.format, text, }
}

///|
/// Import reports through the library's own `Result`, so the page shows the
/// same message the CLI prints.
///
/// `lattice` is export-only: it is a rendering, and handing it to
/// `import_tsr` would fail with "Not valid JSON" while looking like a user
/// mistake. It is refused with its own message instead.
fn handle_import(req : ImportReq) -> ImportResp {
  let outcome = match req.format {
    "md" => @tesseract.import_markdown(db, req.text)
    "sql" => @tesseract.import_sql(db, req.text)
    "lattice" =>
      Err("lattice is an export-only rendering; choose tsr, md or sql")
    // `import_tsr` reports its count in `Int64` where the Markdown and SQL
    // importers report `Int`. Both count rows the lattice holds, and
    // `MAX_SIDE` keeps a lattice's cell count inside 32 bits, so the one
    // number is the same either way; it is brought into the shared branch's
    // type here rather than making each branch carry its own rendering.
    _ => {
      let imported = @tesseract.import_tsr(db, req.text)
      match imported {
        Ok(n) => Ok(n.to_int())
        Err(message) => Err(message)
      }
    }
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
