///|
/// A `.db` file that holds one Tesseract lattice.
///
/// This is a persistence *adapter*, not a second store. The lattice rules — the
/// digit conflict, the coordinate arithmetic, the C# error vocabulary — all
/// stay in `tesseract`; what lives here is only how a snapshot of that store
/// reaches a file and comes back. A save is a snapshot, not a synchronised
/// backend: the file is written when you ask for it, not on every write.
///
/// ## Why this is not a SQL engine replacement
///
/// The hand-written parser in `tesseract/sql.mbt` exists to accept one specific
/// C# dialect: twelve documented error codes, `AT (x,y,z,w)`, and the
/// `line()` / `slab()` / `peers()` predicates. SQLite understands none of them.
/// Routing `execute` through SQLite would replace that dialect rather than
/// extend it, so this package deliberately does not touch the parser.
///
/// ## Timestamps round trip
///
/// The `timestamp` column is written from the store and read back into it, via
/// `Tesseract::insert_stamped` — the same call `import_tsr` makes, which is why
/// `insert_stamped` is public. A reopened `.db` therefore carries the stamps it
/// was saved with, not ones derived from however many log lines this process
/// happened to emit first. A row whose `timestamp` column is empty falls back to
/// a fresh stamp rather than storing an empty string, matching `import_tsr`.
///
/// What does *not* round trip is the log itself. The logger's sequence counter
/// keeps counting from where the new process started, so timestamps minted
/// *after* a load do not continue the saved file's numbering. `.tsr` is the
/// format to use when that continuity matters; `.db` restores what it stored.

///|
/// One row of the cell table.
///
/// Its own type rather than `@tesseract.Record`, because `Record` carries a
/// `coords` field the file does not store — coordinates are derived from the
/// position on load rather than persisted twice.
pub struct CellRow {
  position : Int
  key : String
  value : String
  digit : Int
  timestamp : String
}

///|
/// What a load put into the store.
pub struct LoadReport {
  loaded : Int
  rejected : Int
  cursor : Int
} derive(Eq, Debug)

///|
/// One row per occupied lattice position.
const CELLS_DDL : String = "CREATE TABLE IF NOT EXISTS sudoku_cells (grid_position INTEGER PRIMARY KEY, key TEXT NOT NULL, value TEXT NOT NULL, digit INTEGER NOT NULL, timestamp TEXT NOT NULL)"

///|
/// Cursor and database name, so a reopened file is the store it was saved from.
const META_DDL : String = "CREATE TABLE IF NOT EXISTS sudoku_meta (name TEXT PRIMARY KEY, value TEXT NOT NULL)"

///|
/// Runs one statement for its effect and releases it.
///
/// `Connection::prepare` accepts exactly one statement at a time, which is also
/// how this package builds the transactions the package itself does not wrap:
/// `BEGIN` and `COMMIT` are statements like any other.
fn run(conn : @sqlite3.Connection, sql : String) -> Unit raise {
  let stmt = conn.prepare(sql)
  defer stmt.finalize()
  ignore(stmt.step())
}

///|
/// Creates the two tables when they are not already there.
pub fn ensure_schema(conn : @sqlite3.Connection) -> Unit raise {
  run(conn, CELLS_DDL)
  run(conn, META_DDL)
}

///|
/// Writes every occupied cell of `db` into the file at `path`, replacing that
/// file's contents, and returns how many rows were written.
///
/// The whole replacement is one transaction, assembled from ordinary statements
/// because the package ships no transaction helper. A save that fails part way
/// therefore rolls back rather than leaving a half-replaced lattice behind:
/// `conn.close()` on a connection with an open transaction is what performs
/// that rollback.
pub fn save(path : String, db : @tesseract.Tesseract) -> Int raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  ensure_schema(conn)
  let rows = @tesseract.Tesseract::select(
      db,
      "",
      "",
      None,
      @tesseract.no_filter(),
      None,
    ).data
  run(conn, "BEGIN")
  run(conn, "DELETE FROM sudoku_cells")
  run(conn, "DELETE FROM sudoku_meta")
  write_cells(conn, rows)
  write_meta(conn, db)
  run(conn, "COMMIT")
  rows.length()
}

///|
/// The insert loop, scoped so its statement is finalized before the commit.
fn write_cells(
  conn : @sqlite3.Connection,
  rows : Array[@tesseract.Record],
) -> Unit raise {
  let ins = conn.prepare(
    "INSERT INTO sudoku_cells (grid_position, key, value, digit, timestamp) VALUES (?, ?, ?, ?, ?)",
  )
  defer ins.finalize()
  for row in rows {
    // Every column is rebound on every iteration, so `clear_bindings` is not
    // load-bearing today — it is here so that adding a column later cannot
    // silently reuse the previous row's value for it.
    ins.reset(clear_bindings=true)
    ins.bind(index=1, row.position)
    ins.bind(index=2, row.key)
    ins.bind(index=3, row.value)
    ins.bind(index=4, row.digit)
    ins.bind(index=5, row.timestamp)
    ignore(ins.step())
  }
}

///|
/// The cursor, so a reopened file resumes where the last one left off.
fn write_meta(
  conn : @sqlite3.Connection,
  db : @tesseract.Tesseract,
) -> Unit raise {
  let status = @tesseract.Tesseract::status(db)
  let ins = conn.prepare("INSERT INTO sudoku_meta (name, value) VALUES (?, ?)")
  defer ins.finalize()
  ins.reset(clear_bindings=true)
  ins.bind(index=1, "cursor")
  ins.bind(index=2, status.current_position.to_string())
  ignore(ins.step())
}

///|
/// Every cell row in the file, ordered by position.
fn read_cells(conn : @sqlite3.Connection) -> Array[CellRow] raise {
  let stmt = conn.prepare(
    "SELECT grid_position, key, value, digit, timestamp FROM sudoku_cells ORDER BY grid_position",
  )
  defer stmt.finalize()
  let out : Array[CellRow] = []
  // `step` reruns the statement once it has returned false, so the loop must
  // never call it again after the end — `while` stops on false, which is what
  // makes this correct rather than accidentally correct.
  while stmt.step() {
    let position : Int64 = stmt.column(index=0)
    let key : String = stmt.column(index=1)
    let value : String = stmt.column(index=2)
    let digit : Int64 = stmt.column(index=3)
    let timestamp : String = stmt.column(index=4)
    out.push(CellRow::{
      position: position.to_int(),
      key,
      value,
      digit: digit.to_int(),
      timestamp,
    })
  }
  out
}

///|
/// One meta value, or `None` when the file does not carry that name.
fn read_meta(conn : @sqlite3.Connection, name : String) -> String? raise {
  let stmt = conn.prepare("SELECT value FROM sudoku_meta WHERE name = ?")
  defer stmt.finalize()
  stmt.bind(index=1, name)
  if stmt.step() {
    let value : String = stmt.column(index=0)
    return Some(value)
  }
  None
}

///|
/// Replaces the contents of `db` with the file at `path`.
///
/// The store is cleared first, for the same reason `import_tsr` clears: a load
/// that merges leaves behind records the file never mentioned, and the count it
/// reports then describes only the file rather than the store.
///
/// Rows the store refuses — a hand-edited file can hold two cells with the same
/// digit on a shared line — are counted in `LoadReport::rejected` rather than
/// dropped silently, because "loaded 10 of 12" and "loaded 12" are different
/// answers and only one of them is what happened.
///
/// Each row is reinserted through `insert_stamped` with the timestamp the file
/// carried, so the lattice that comes back is the one that was saved.
pub fn load(path : String, db : @tesseract.Tesseract) -> LoadReport raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  ensure_schema(conn)
  let rows = read_cells(conn)
  let cursor = read_meta(conn, "cursor")
  ignore(@tesseract.Tesseract::delete(db, "", None))
  let mut loaded = 0
  let mut rejected = 0
  for row in rows {
    // An empty `timestamp` means the row was written by something that had no
    // stamp to give; `None` lets the logger mint one, exactly as `import_tsr`
    // does for a `.tsr` record with no `timestamp` field.
    let stamp = if row.timestamp == "" { None } else { Some(row.timestamp) }
    let response = @tesseract.Tesseract::insert_stamped(
      db,
      row.key,
      row.value,
      Some(row.position),
      row.digit,
      stamp,
    )
    if response.success {
      loaded = loaded + 1
    } else {
      rejected = rejected + 1
    }
  }
  // A cursor the file does not carry, or one outside the lattice, leaves the
  // store where `delete` put it rather than failing the whole load.
  match cursor {
    Some(text) =>
      match @tesseract.parse_int(text) {
        Some(p) =>
          if @tesseract.position_in_bounds(p) {
            @tesseract.Tesseract::set_position(db, p)
          }
        None => ()
      }
    None => ()
  }
  LoadReport::{
    loaded,
    rejected,
    cursor: @tesseract.Tesseract::status(db).current_position,
  }
}
