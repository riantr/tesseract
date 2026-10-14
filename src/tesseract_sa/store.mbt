///|
/// Storing a `ScanReport` in SQLite.
///
/// A scan gets its own tables rather than going through the lattice in
/// `src/tesseract_sqlite`. Two reasons, both about shape rather than taste:
/// a project can have far more files than the lattice's 81 cells, and a
/// finding is a `(file, line, column, family)` tuple, which is not a
/// key/value record. Flattening either into the other loses the thing the
/// table is for.
///
/// Runs accumulate: `save` appends, so a database can hold the history of
/// several scans and `latest_run` picks out the newest.

///|
const RUNS_DDL : String = "CREATE TABLE IF NOT EXISTS sa_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, target TEXT NOT NULL, root TEXT NOT NULL, files INTEGER NOT NULL, parsed INTEGER NOT NULL, parsed_pct TEXT NOT NULL, partial_files INTEGER NOT NULL, actionable INTEGER NOT NULL, notices INTEGER NOT NULL, unreliable INTEGER NOT NULL, withheld INTEGER NOT NULL, total INTEGER NOT NULL)"

///|
const FILES_DDL : String = "CREATE TABLE IF NOT EXISTS sa_files (run_id INTEGER NOT NULL, kind TEXT NOT NULL, path TEXT NOT NULL, outcome TEXT NOT NULL, defects INTEGER NOT NULL, notices INTEGER NOT NULL, shown INTEGER NOT NULL, read_up_to INTEGER NOT NULL, not_shown INTEGER NOT NULL)"

///|
const FINDINGS_DDL : String = "CREATE TABLE IF NOT EXISTS sa_findings (run_id INTEGER NOT NULL, seq INTEGER NOT NULL, path TEXT NOT NULL, line INTEGER NOT NULL, column INTEGER NOT NULL, severity TEXT NOT NULL, family TEXT NOT NULL, lenses TEXT NOT NULL, message TEXT NOT NULL)"

///|
const UNPARSED_DDL : String = "CREATE TABLE IF NOT EXISTS sa_unparsed (run_id INTEGER NOT NULL, reason TEXT NOT NULL, count INTEGER NOT NULL, examples TEXT NOT NULL)"

///|
const BYKIND_DDL : String = "CREATE TABLE IF NOT EXISTS sa_by_kind (run_id INTEGER NOT NULL, kind TEXT NOT NULL, files INTEGER NOT NULL, parsed INTEGER NOT NULL, defects INTEGER NOT NULL, notices INTEGER NOT NULL)"

///|
/// The outcome of a file, as stored.
fn outcome_text(o : FileOutcome) -> String {
  match o {
    Clean => "clean"
    Partial => "partial"
    Found => "found"
  }
}

///|
/// The inverse of `outcome_text`; an unreadable value is `Found`, which is the
/// pessimistic reading - a row that claims `clean` it cannot justify is worse
/// than one that claims a finding that may not be there.
fn outcome_of(s : String) -> FileOutcome {
  if s == "clean" {
    Clean
  } else if s == "partial" {
    Partial
  } else {
    Found
  }
}

///|
/// Runs one statement for its effect and releases it.
fn run(conn : @sqlite3.Connection, sql : String) -> Unit raise {
  let stmt = conn.prepare(sql)
  defer stmt.finalize()
  ignore(stmt.step())
}

///|
/// Creates the tables when they are not already there.
pub fn ensure_schema(conn : @sqlite3.Connection) -> Unit raise {
  run(conn, RUNS_DDL)
  run(conn, FILES_DDL)
  run(conn, FINDINGS_DDL)
  run(conn, UNPARSED_DDL)
  run(conn, BYKIND_DDL)
}

///|
/// Appends `report` to the database at `path` and returns its run id.
///
/// One transaction, assembled from ordinary statements because the package
/// ships no transaction helper - the same arrangement `src/tesseract_sqlite`
/// uses. A half-written run would be worse than none: a summary with no file
/// rows reads as "the scan found nothing".
pub fn save(path : String, report : ScanReport) -> Int32 raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  ensure_schema(conn)
  run(conn, "BEGIN")
  let id = insert_run(conn, report)
  insert_files(conn, id, report.file_results)
  insert_findings(conn, id, report.findings)
  insert_unparsed(conn, id, report.unparsed)
  insert_by_kind(conn, id, report.by_kind)
  run(conn, "COMMIT")
  id
}

///|
/// The run header, and the row id it lands on.
///
/// The id comes back from `ORDER BY id DESC LIMIT 1` rather than from
/// `last_insert_rowid`: the sqlite3 package this project uses exposes
/// `changes()`, which counts rows affected, not the new row id.
fn insert_run(conn : @sqlite3.Connection, report : ScanReport) -> Int32 raise {
  let ins = conn.prepare(
    "INSERT INTO sa_runs (target, root, files, parsed, parsed_pct, partial_files, actionable, notices, unreliable, withheld, total) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
  )
  defer ins.finalize()
  ins.bind(index=1, report.target)
  ins.bind(index=2, report.root)
  ins.bind(index=3, report.files)
  ins.bind(index=4, report.parsed)
  ins.bind(index=5, report.parsed_pct)
  ins.bind(index=6, report.partial_files)
  ins.bind(index=7, report.actionable)
  ins.bind(index=8, report.notices)
  ins.bind(index=9, report.unreliable)
  ins.bind(index=10, report.withheld)
  ins.bind(index=11, report.total)
  ignore(ins.step())
  let sel = conn.prepare("SELECT id FROM sa_runs ORDER BY id DESC LIMIT 1")
  defer sel.finalize()
  if sel.step() {
    let id : Int64 = sel.column(index=0)
    return id.to_int()
  }
  0
}

///|
fn insert_files(
  conn : @sqlite3.Connection,
  run_id : Int32,
  rows : Array[FileResult],
) -> Unit raise {
  let ins = conn.prepare(
    "INSERT INTO sa_files (run_id, kind, path, outcome, defects, notices, shown, read_up_to, not_shown) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
  )
  defer ins.finalize()
  for row in rows {
    ins.reset(clear_bindings=true)
    ins.bind(index=1, run_id)
    ins.bind(index=2, row.kind)
    ins.bind(index=3, row.path)
    ins.bind(index=4, outcome_text(row.outcome))
    ins.bind(index=5, row.defects)
    ins.bind(index=6, row.notices)
    ins.bind(index=7, row.shown)
    ins.bind(index=8, row.read_up_to)
    ins.bind(index=9, row.not_shown)
    ignore(ins.step())
  }
}

///|
fn insert_findings(
  conn : @sqlite3.Connection,
  run_id : Int32,
  rows : Array[Finding],
) -> Unit raise {
  let ins = conn.prepare(
    "INSERT INTO sa_findings (run_id, seq, path, line, column, severity, family, lenses, message) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
  )
  defer ins.finalize()
  for i = 0; i < rows.length(); i = i + 1 {
    let row = rows[i]
    ins.reset(clear_bindings=true)
    ins.bind(index=1, run_id)
    ins.bind(index=2, i)
    ins.bind(index=3, row.path)
    ins.bind(index=4, row.line)
    ins.bind(index=5, row.column)
    ins.bind(index=6, row.severity)
    ins.bind(index=7, row.family)
    ins.bind(index=8, row.lenses)
    ins.bind(index=9, row.message)
    ignore(ins.step())
  }
}

///|
fn insert_unparsed(
  conn : @sqlite3.Connection,
  run_id : Int32,
  rows : Array[UnparsedGroup],
) -> Unit raise {
  let ins = conn.prepare(
    "INSERT INTO sa_unparsed (run_id, reason, count, examples) VALUES (?, ?, ?, ?)",
  )
  defer ins.finalize()
  for row in rows {
    ins.reset(clear_bindings=true)
    ins.bind(index=1, run_id)
    ins.bind(index=2, row.reason)
    ins.bind(index=3, row.count)
    // One column, newline-joined: the tool prints at most three examples, so a
    // joined string is the whole of what there is, and a separate table would
    // imply a list length the source never claimed.
    ins.bind(index=4, row.examples.join("\n"))
    ignore(ins.step())
  }
}

///|
fn insert_by_kind(
  conn : @sqlite3.Connection,
  run_id : Int32,
  rows : Array[ByKind],
) -> Unit raise {
  let ins = conn.prepare(
    "INSERT INTO sa_by_kind (run_id, kind, files, parsed, defects, notices) VALUES (?, ?, ?, ?, ?, ?)",
  )
  defer ins.finalize()
  for row in rows {
    ins.reset(clear_bindings=true)
    ins.bind(index=1, run_id)
    ins.bind(index=2, row.kind)
    ins.bind(index=3, row.files)
    ins.bind(index=4, row.parsed)
    ins.bind(index=5, row.defects)
    ins.bind(index=6, row.notices)
    ignore(ins.step())
  }
}

///|
/// The newest run's id, or `None` on a database with no runs.
pub fn latest_run(path : String) -> Int32? raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  ensure_schema(conn)
  let sel = conn.prepare("SELECT id FROM sa_runs ORDER BY id DESC LIMIT 1")
  defer sel.finalize()
  if sel.step() {
    let id : Int64 = sel.column(index=0)
    return Some(id.to_int())
  }
  None
}

///|
/// Every stored run, oldest first.
///
/// The database accumulates runs and `latest_run` only ever surfaces one of
/// them, which is the wrong shape for the question this store actually gets
/// asked: a 0.3.5 scan and a 0.4.0 scan of the same tree should be comparable
/// side by side, and they are not if the only way to see the older one is to
/// know its id already.
pub fn list_runs(path : String) -> Array[RunSummary] raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  ensure_schema(conn)
  let sel = conn.prepare(
    "SELECT id, target, root, files, parsed, parsed_pct, partial_files, actionable, notices, unreliable, withheld, total FROM sa_runs ORDER BY id",
  )
  defer sel.finalize()
  let rows : Array[RunSummary] = []
  while sel.step() {
    rows.push({
      id: read_int(sel, 0),
      target: read_text(sel, 1),
      root: read_text(sel, 2),
      files: read_int(sel, 3),
      parsed: read_int(sel, 4),
      parsed_pct: read_text(sel, 5),
      partial_files: read_int(sel, 6),
      actionable: read_int(sel, 7),
      notices: read_int(sel, 8),
      unreliable: read_int(sel, 9),
      withheld: read_int(sel, 10),
      total: read_int(sel, 11),
    })
  }
  rows
}

///|
/// One text column, read once.
fn read_text(stmt : @sqlite3.Statement, index : Int32) -> String raise {
  let v : String = stmt.column(index~)
  v
}

///|
/// One integer column, read once.
fn read_int(stmt : @sqlite3.Statement, index : Int32) -> Int32 raise {
  let v : Int64 = stmt.column(index~)
  v.to_int()
}

///|
/// Reads a run back out, for verifying that what was stored is what was parsed.
///
/// `None` when the run id is not in the database.
pub fn load(path : String, run_id : Int32) -> ScanReport? raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  ensure_schema(conn)
  let head = conn.prepare(
    "SELECT target, root, files, parsed, parsed_pct, partial_files, actionable, notices, unreliable, withheld, total FROM sa_runs WHERE id = ?",
  )
  defer head.finalize()
  head.bind(index=1, run_id)
  if !head.step() {
    return None
  }
  let report = {
    target: read_text(head, 0),
    root: read_text(head, 1),
    files: read_int(head, 2),
    parsed: read_int(head, 3),
    parsed_pct: read_text(head, 4),
    partial_files: read_int(head, 5),
    actionable: read_int(head, 6),
    notices: read_int(head, 7),
    unreliable: read_int(head, 8),
    withheld: read_int(head, 9),
    total: read_int(head, 10),
    file_results: [],
    findings: [],
    unparsed: [],
    by_kind: [],
  }
  read_files(conn, run_id, report.file_results)
  read_findings(conn, run_id, report.findings)
  read_unparsed(conn, run_id, report.unparsed)
  read_by_kind(conn, run_id, report.by_kind)
  Some(report)
}

///|
fn read_files(
  conn : @sqlite3.Connection,
  run_id : Int32,
  into : Array[FileResult],
) -> Unit raise {
  let sel = conn.prepare(
    "SELECT kind, path, outcome, defects, notices, shown, read_up_to, not_shown FROM sa_files WHERE run_id = ?",
  )
  defer sel.finalize()
  sel.bind(index=1, run_id)
  while sel.step() {
    into.push({
      kind: read_text(sel, 0),
      path: read_text(sel, 1),
      outcome: outcome_of(read_text(sel, 2)),
      defects: read_int(sel, 3),
      notices: read_int(sel, 4),
      shown: read_int(sel, 5),
      read_up_to: read_int(sel, 6),
      not_shown: read_int(sel, 7),
    })
  }
}

///|
fn read_findings(
  conn : @sqlite3.Connection,
  run_id : Int32,
  into : Array[Finding],
) -> Unit raise {
  let sel = conn.prepare(
    "SELECT path, line, column, severity, family, lenses, message FROM sa_findings WHERE run_id = ? ORDER BY seq",
  )
  defer sel.finalize()
  sel.bind(index=1, run_id)
  while sel.step() {
    into.push({
      path: read_text(sel, 0),
      line: read_int(sel, 1),
      column: read_int(sel, 2),
      severity: read_text(sel, 3),
      family: read_text(sel, 4),
      lenses: read_text(sel, 5),
      message: read_text(sel, 6),
    })
  }
}

///|
fn read_unparsed(
  conn : @sqlite3.Connection,
  run_id : Int32,
  into : Array[UnparsedGroup],
) -> Unit raise {
  let sel = conn.prepare(
    "SELECT reason, count, examples FROM sa_unparsed WHERE run_id = ?",
  )
  defer sel.finalize()
  sel.bind(index=1, run_id)
  while sel.step() {
    let text = read_text(sel, 2)
    let examples : Array[String] = if text == "" {
      []
    } else {
      @tesseract.split(text, "\n")
    }
    into.push({ reason: read_text(sel, 0), count: read_int(sel, 1), examples, })
  }
}

///|
fn read_by_kind(
  conn : @sqlite3.Connection,
  run_id : Int32,
  into : Array[ByKind],
) -> Unit raise {
  let sel = conn.prepare(
    "SELECT kind, files, parsed, defects, notices FROM sa_by_kind WHERE run_id = ?",
  )
  defer sel.finalize()
  sel.bind(index=1, run_id)
  while sel.step() {
    into.push({
      kind: read_text(sel, 0),
      files: read_int(sel, 1),
      parsed: read_int(sel, 2),
      defects: read_int(sel, 3),
      notices: read_int(sel, 4),
    })
  }
}
