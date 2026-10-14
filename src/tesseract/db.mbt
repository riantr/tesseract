///|
/// The 4D store: 81 cells in a lattice, addressed by position or by
/// coordinate.
///
/// Behaviour is carried over from the C# `Tesseract` model — cyclic insert
/// cursor, key/pattern/position selects, key-or-position delete, the
/// `TRUNCATE`-style clear — with three deliberate changes:
///
/// 1. the grid is 3x3x3x3 rather than a flat 9-cell ring;
/// 2. a cell may carry a sudoku digit, enforced against the axis-parallel
///    lines through it (`sudoku.mbt` owns that rule);
/// 3. `current_count` is *computed* from occupancy rather than accumulated in a
///    counter. The C# counter saturated at 9 on the first wrap and then only
///    ever decremented, so it drifted away from the number of stored records;
///    reporting the real occupancy is what `GetStatus` was always asking for.

///|
/// Coordinate filter; -1 means "unconstrained on this axis".
pub struct CoordFilter {
  x : Int
  y : Int
  z : Int
  w : Int
}

///|
/// A filter that matches every cell.
pub fn no_filter() -> CoordFilter {
  { x: -1, y: -1, z: -1, w: -1, }
}

///|
/// A filter constraining the given axes; pass -1 to leave one unconstrained.
pub fn coord_filter(x : Int, y : Int, z : Int, w : Int) -> CoordFilter {
  { x, y, z, w, }
}

///|
/// True when `c` satisfies every constrained axis of `f`.
pub fn filter_matches(f : CoordFilter, c : Coords) -> Bool {
  if f.x >= 0 && c.x != f.x {
    return false
  }
  if f.y >= 0 && c.y != f.y {
    return false
  }
  if f.z >= 0 && c.z != f.z {
    return false
  }
  if f.w >= 0 && c.w != f.w {
    return false
  }
  true
}

///|
/// The 4D Tesseract.
pub struct Tesseract {
  db_name : String
  cells : Array[GridCell]
  mut current_position : Int
  logger : TesseractLogger
}

///|
/// An empty 81-cell database.
///
/// The cursor starts at position 1, matching the C# constructor.
pub fn new_db(name : String, logger : TesseractLogger) -> Tesseract {
  let cells : Array[GridCell] = []
  let mut i = FIRST_POSITION
  while i <= LAST_POSITION {
    cells.push(empty_cell(i))
    i = i + 1
  }
  { db_name: name, cells, current_position: FIRST_POSITION, logger, }
}

///|
/// The database's logger, for callers that want to read it back.
pub fn Tesseract::get_logger(db : Tesseract) -> TesseractLogger {
  db.logger
}

///|
/// The cell at 1-based `position`, or `None` when out of range.
pub fn Tesseract::cell_at(db : Tesseract, position : Int) -> GridCell? {
  if !position_in_bounds(position) {
    return None
  }
  Some(db.cells[position - 1])
}

///|
/// Number of cells holding a record.
pub fn Tesseract::occupancy(db : Tesseract) -> Int {
  let mut n = 0
  let mut i = 0
  while i < db.cells.length() {
    if !cell_is_empty(db.cells[i]) {
      n = n + 1
    }
    i = i + 1
  }
  n
}

///|
/// Number of cells carrying a sudoku digit.
pub fn Tesseract::digit_count(db : Tesseract) -> Int {
  let mut n = 0
  let mut i = 0
  while i < db.cells.length() {
    if db.cells[i].digit != NO_DIGIT {
      n = n + 1
    }
    i = i + 1
  }
  n
}

///|
/// The lowest cell on a line through `position` that already carries `digit`.
///
/// The line rule is what a 3^4 sudoku can actually enforce: digits live in
/// `1..3` and each axis-parallel line of 3 cells must hold all three. Two cells
/// share such a line exactly when they agree on three of four coordinates.
pub fn Tesseract::digit_conflict(
  db : Tesseract,
  position : Int,
  digit : Int,
) -> GridCell? {
  match coords_of(position) {
    Some(c) => {
      for peer in peers(c) {
        let cell = db.cells[index0(peer)]
        if cell.digit == digit && index0(peer) != position - 1 {
          return Some(cell)
        }
      }
      None
    }
    None => None
  }
}

///|
/// Moves the insert cursor. Out-of-range positions are ignored, as in C#.
pub fn Tesseract::set_position(db : Tesseract, position : Int) -> Unit {
  if position_in_bounds(position) {
    db.current_position = position
    db.logger.log_info("Position set to: " + position.to_string(), Map([]))
  }
}

///|
/// Occupancy snapshot.
pub fn Tesseract::status(db : Tesseract) -> DBStatus {
  {
    db_name: db.db_name,
    total_cells: TOTAL,
    current_count: Tesseract::occupancy(db),
    current_position: db.current_position,
    digit_count: Tesseract::digit_count(db),
  }
}

///|
/// Records that a stored value was replaced in place.
fn Tesseract::log_operation(
  db : Tesseract,
  operation : String,
  success : Bool,
  key : String,
  position : Int,
) -> Unit {
  let details : Map[String, String] = Map([])
  details["key"] = key
  details["grid_position"] = position.to_string()
  db.logger.log_operation(operation, success, details)
}

///|
/// Writes `key`/`value` into the lattice.
///
/// `target` addresses an explicit cell; `None` writes at the insert cursor and
/// then advances it, which is the C# cyclic behaviour. `digit` is 0 for "no
/// sudoku digit", or 1..3 to place one.
pub fn Tesseract::insert(
  db : Tesseract,
  key : String,
  value : String,
  target : Int?,
  digit : Int,
) -> DBResponse {
  Tesseract::insert_stamped(db, key, value, target, digit, None)
}

///|
/// `insert` with the cell's timestamp supplied rather than stamped.
///
/// `None` is the ordinary path, where the timestamp comes from the logger's
/// sequence counter. The importers pass the value the file carried, which is
/// what makes a `.tsr` round trip byte-identical instead of only structurally
/// similar - without it the stamps depend on how many log lines happened to be
/// written before the load.
///
/// Public so that `src/tesseract_sqlite` can do the same for a `.db`. It was
/// private while that was the only caller, which left `.db` the one import
/// format that could not restore what it stored.
pub fn Tesseract::insert_stamped(
  db : Tesseract,
  key : String,
  value : String,
  target : Int?,
  digit : Int,
  stamp : String?,
) -> DBResponse {
  if key == "" || value == "" {
    db.logger.log_error("INSERT: Invalid key or value", Map([]))
    return err_response("INVALID_INPUT", "Invalid key or value")
  }
  if digit < NO_DIGIT || digit > MAX_DIGIT {
    db.logger.log_error("INSERT: Invalid digit " + digit.to_string(), Map([]))
    return err_response("INVALID_DIGIT", "Digit must be 0..3")
  }
  let position = match target {
    Some(p) => p
    None => db.current_position
  }
  if !position_in_bounds(position) {
    let msg = "Position out of range: " + position.to_string()
    db.logger.log_error("INSERT: " + msg, Map([]))
    return err_response("INVALID_POSITION", msg)
  }
  if digit != NO_DIGIT {
    match Tesseract::digit_conflict(db, position, digit) {
      Some(other) => {
        let msg = digit_conflict_message(digit, other.position)
        db.logger.log_error("INSERT: " + msg, Map([]))
        return err_response("SUDOKU_CONFLICT", msg)
      }
      None => ()
    }
  }
  let previous = db.cells[position - 1]
  if !cell_is_empty(previous) {
    let details : Map[String, String] = Map([])
    details["grid_position"] = position.to_string()
    details["overwritten_key"] = previous.key
    db.logger.log_warning("Cyclic overwrite: " + position.to_string(), details)
  }
  db.cells[position - 1] = {
    position,
    key,
    value,
    timestamp: match stamp {
      Some(t) => t
      None => db.logger.seq.to_string()
    },
    digit,
  }
  Tesseract::log_operation(db, "INSERT", true, key, position)
  let mut response = ok_response("INSERT")
  response = {
    success: response.success,
    operation: "INSERT",
    affected_rows: 1,
    position,
    error: response.error,
    error_code: response.error_code,
    message: response.message,
    data: response.data,
    total_records: response.total_records,
  }
  if target == None {
    db.current_position = db.current_position % TOTAL + 1
  }
  response
}

///|
/// Turns a stored cell into a result row.
fn to_record(cell : GridCell) -> Record {
  {
    key: cell.key,
    value: cell.value,
    position: cell.position,
    coords: coords_of(cell.position).unwrap(),
    timestamp: cell.timestamp,
    digit: cell.digit,
  }
}

///|

///|
/// True when `value` satisfies a `LIKE` pattern.
///
/// The pattern keeps its `%` wildcards, because they are the dialect: `%...%`
/// is a "contains" test and anything else is an equality test. The old parser
/// stripped the markers and read "nothing left" as "no predicate at all", so
/// `LIKE 'hello'` matched every row — and a filter that comes back too wide
/// hides a problem instead of showing it.
pub fn like_matches(value : String, pattern : String) -> Bool {
  if pattern.length() >= 2 &&
    pattern.at(0) == '%' &&
    pattern.at(pattern.length() - 1) == '%' {
    contains_ci(value, slice(pattern, 1, pattern.length() - 1))
  } else {
    eq_ci(value, pattern)
  }
}

///|
/// `SELECT`.
///
/// `key`, `pattern`, `position_filter`, `coords_filter` and `digit_filter` are
/// independent conditions and all of them apply: `key` and `pattern` intersect
/// rather than one shadowing the other, and every cell carrying `key` is a
/// candidate (keys are not unique — `find_all_by_key` returns all of them and
/// `delete` by a bare key removes all of them). With none of them set, every
/// occupied cell matches.
///
/// `pattern` is a LIKE pattern, not a bare substring: `%x%` is a contains test
/// and anything else is equality, matching what `value LIKE '...'` means in SQL.
/// An empty `pattern` is "no predicate".
pub fn Tesseract::select(
  db : Tesseract,
  key : String,
  pattern : String,
  position_filter : Int?,
  coords_filter : CoordFilter,
  digit_filter : Int?,
) -> DBResponse {
  let rows : Array[Record] = []
  let mut i = 0
  while i < db.cells.length() {
    let cell = db.cells[i]
    let c = coords_of(cell.position).unwrap()
    let digit_ok = match digit_filter {
      Some(d) => cell.digit == d
      None => true
    }
    if cell_is_empty(cell) || !filter_matches(coords_filter, c) || !digit_ok {
      i = i + 1
      continue
    }
    // Key and pattern are two independent conditions on one cell and both
    // apply: `WHERE key='a' AND value LIKE '%x%'` is an intersection. The key
    // branch used to `break` after its first hit - so a key held by two cells
    // returned only one of them - and short-circuited the pattern entirely,
    // making `key=... AND LIKE ...` ignore the LIKE.
    let key_ok = key == "" || cell.key == key
    let pattern_ok = pattern == "" || like_matches(cell.value, pattern)
    if !key_ok || !pattern_ok {
      i = i + 1
      continue
    }
    match position_filter {
      Some(p) => if p == cell.position { rows.push(to_record(cell)) }
      None => rows.push(to_record(cell))
    }
    i = i + 1
  }
  Tesseract::log_operation(db, "SELECT", true, key, 0)
  let base = ok_response("SELECT")
  {
    success: base.success,
    operation: "SELECT",
    affected_rows: base.affected_rows,
    position: base.position,
    error: base.error,
    error_code: base.error_code,
    message: "查询成功",
    data: rows,
    total_records: rows.length(),
  }
}

///|
/// Replaces the value (and optionally the digit) of a stored record.
///
/// With `position_filter` the named cell must be occupied; without it, the
/// first occupied cell carrying `key` is used. Out-of-range positions get a
/// clean `POSITION_OUT_OF_RANGE` rather than the C# `KeyNotFoundException`.
pub fn Tesseract::update(
  db : Tesseract,
  key : String,
  value : String,
  position_filter : Int?,
  digit : Int?,
) -> DBResponse {
  if !position_in_bounds(db.current_position) && position_filter == None {
    return err_response("POSITION_OUT_OF_RANGE", "Insert cursor out of range")
  }
  let target = match position_filter {
    Some(p) => {
      if !position_in_bounds(p) {
        return err_response(
          "POSITION_OUT_OF_RANGE",
          "Position out of range: " + p.to_string(),
        )
      }
      // `WHERE key='a' AND grid_position=5` states two conditions, and taking
      // only the position overwrites whatever record sits in cell 5 - silent
      // corruption of a record the statement never named. `delete` has always
      // checked the key here; the two verbs must not disagree about the same
      // WHERE clause.
      if key != "" && db.cells[p - 1].key != key {
        db.logger.log_error("UPDATE: Key not found - " + key, Map([]))
        return err_response("KEY_NOT_FOUND", "Key not found")
      }
      Some(p)
    }
    None => {
      let found = find_by_key(db, key)
      found
    }
  }
  let position = match target {
    Some(p) => p
    None => {
      db.logger.log_error("UPDATE: Key not found - " + key, Map([]))
      return err_response("KEY_NOT_FOUND", "Key not found")
    }
  }
  let cell = db.cells[position - 1]
  if cell_is_empty(cell) {
    db.logger.log_error(
      "UPDATE: Position not found or empty - " + position.to_string(),
      Map([]),
    )
    return err_response("POSITION_NOT_FOUND", "Position not found or empty")
  }
  let new_digit = match digit {
    Some(d) => {
      if d < NO_DIGIT || d > MAX_DIGIT {
        return err_response("INVALID_DIGIT", "Digit must be 0..3")
      }
      d
    }
    None => cell.digit
  }
  if new_digit != NO_DIGIT && new_digit != cell.digit {
    match Tesseract::digit_conflict(db, position, new_digit) {
      Some(other) => {
        let msg = digit_conflict_message(new_digit, other.position)
        db.logger.log_error("UPDATE: " + msg, Map([]))
        return err_response("SUDOKU_CONFLICT", msg)
      }
      None => ()
    }
  }
  db.cells[position - 1] = {
    position,
    key: cell.key,
    value,
    timestamp: db.logger.seq.to_string(),
    digit: new_digit,
  }
  Tesseract::log_operation(db, "UPDATE", true, cell.key, position)
  let base = ok_response("UPDATE")
  {
    success: base.success,
    operation: "UPDATE",
    affected_rows: 1,
    position,
    error: base.error,
    error_code: base.error_code,
    message: base.message,
    data: base.data,
    total_records: base.total_records,
  }
}

///|
/// The message both the insert and update paths use for a digit collision.
fn digit_conflict_message(digit : Int, position : Int) -> String {
  let b = StringBuilder::StringBuilder()
  b.write_string("Digit ")
  b.write_object(digit)
  b.write_string(" already used at position ")
  b.write_object(position)
  b.to_string()
}

///|
/// First occupied position carrying `key`, scanning in position order.
pub fn find_by_key(db : Tesseract, key : String) -> Int? {
  if key == "" {
    return None
  }
  let mut i = 0
  while i < db.cells.length() {
    if db.cells[i].key == key {
      return Some(db.cells[i].position)
    }
    i = i + 1
  }
  None
}

///|
/// Every occupied position carrying `key`, in descending position order.
///
/// Descending matches the C# comment about deleting high positions first; with
/// a fixed lattice it is only about reporting order, but keeping it costs
/// nothing and keeps the exported SQL stable.
pub fn find_all_by_key(db : Tesseract, key : String) -> Array[Int] {
  let out : Array[Int] = []
  if key == "" {
    return out
  }
  let mut i = db.cells.length() - 1
  while i >= 0 {
    if db.cells[i].key == key {
      out.push(db.cells[i].position)
    }
    i = i - 1
  }
  out
}

///|
/// `DELETE`.
///
/// A `key` plus `position` removes that one cell; a bare `key` removes every
/// cell carrying it; a bare `position` clears that cell; and no arguments at
/// all empties the lattice and rewinds the cursor to 1.
pub fn Tesseract::delete(
  db : Tesseract,
  key : String,
  position_filter : Int?,
) -> DBResponse {
  let mut affected = 0
  let mut first_position = 0
  if key != "" {
    let targets = match position_filter {
      Some(p) => {
        if !position_in_bounds(p) {
          return err_response(
            "POSITION_OUT_OF_RANGE",
            "Position out of range: " + p.to_string(),
          )
        }
        let cell = db.cells[p - 1]
        if cell.key != key {
          db.logger.log_error("DELETE: Key not found - " + key, Map([]))
          return err_response("KEY_NOT_FOUND", "Key not found")
        }
        [p]
      }
      None => find_all_by_key(db, key)
    }
    if targets.length() == 0 {
      db.logger.log_error("DELETE: Key not found - " + key, Map([]))
      return err_response("KEY_NOT_FOUND", "Key not found")
    }
    let mut i = 0
    while i < targets.length() {
      let p = targets[i]
      if i == 0 {
        first_position = p
      }
      db.cells[p - 1] = empty_cell(p)
      Tesseract::log_operation(db, "DELETE", true, key, p)
      affected = affected + 1
      i = i + 1
    }
  } else if position_filter != None {
    let p = position_filter.unwrap()
    if !position_in_bounds(p) {
      return err_response(
        "POSITION_OUT_OF_RANGE",
        "Position out of range: " + p.to_string(),
      )
    }
    if cell_is_empty(db.cells[p - 1]) {
      return err_response("POSITION_EMPTY", "No data at specified position")
    }
    first_position = p
    Tesseract::log_operation(db, "DELETE", true, db.cells[p - 1].key, p)
    db.cells[p - 1] = empty_cell(p)
    affected = 1
  } else {
    let mut i = 0
    while i < db.cells.length() {
      db.cells[i] = empty_cell(db.cells[i].position)
      i = i + 1
    }
    db.current_position = FIRST_POSITION
    Tesseract::log_operation(db, "DELETE", true, "", 0)
  }
  let base = ok_response("DELETE")
  {
    success: base.success,
    operation: "DELETE",
    affected_rows: affected,
    position: first_position,
    error: base.error,
    error_code: base.error_code,
    message: base.message,
    data: base.data,
    total_records: base.total_records,
  }
}

///|
/// Occupied cells on the axis-parallel line through `position` along `axis`.
pub fn Tesseract::line_query(
  db : Tesseract,
  position : Int,
  axis : Int,
) -> DBResponse {
  let rows : Array[Record] = []
  match coords_of(position) {
    Some(c) =>
      for cell_c in line_through(c, axis) {
        let cell = db.cells[index0(cell_c)]
        if !cell_is_empty(cell) {
          rows.push(to_record(cell))
        }
      }
    None =>
      return err_response(
        "POSITION_OUT_OF_RANGE",
        "Position out of range: " + position.to_string(),
      )
  }
  let base = ok_response("SELECT")
  {
    success: base.success,
    operation: "SELECT",
    affected_rows: base.affected_rows,
    position: base.position,
    error: base.error,
    error_code: base.error_code,
    message: "查询成功",
    data: rows,
    total_records: rows.length(),
  }
}

///|
/// Occupied cells in the 27-cell slab sharing `position`'s `axis` coordinate.
pub fn Tesseract::slab_query(
  db : Tesseract,
  position : Int,
  axis : Int,
) -> DBResponse {
  let rows : Array[Record] = []
  match coords_of(position) {
    Some(c) =>
      for cell_c in slab_through(c, axis) {
        let cell = db.cells[index0(cell_c)]
        if !cell_is_empty(cell) {
          rows.push(to_record(cell))
        }
      }
    None =>
      return err_response(
        "POSITION_OUT_OF_RANGE",
        "Position out of range: " + position.to_string(),
      )
  }
  let base = ok_response("SELECT")
  {
    success: base.success,
    operation: "SELECT",
    affected_rows: base.affected_rows,
    position: base.position,
    error: base.error,
    error_code: base.error_code,
    message: "查询成功",
    data: rows,
    total_records: rows.length(),
  }
}

///|
/// Occupied cells among the 8 that share a line with `position`.
pub fn Tesseract::peer_query(db : Tesseract, position : Int) -> DBResponse {
  let rows : Array[Record] = []
  match coords_of(position) {
    Some(c) =>
      for cell_c in peers(c) {
        let cell = db.cells[index0(cell_c)]
        if !cell_is_empty(cell) {
          rows.push(to_record(cell))
        }
      }
    None =>
      return err_response(
        "POSITION_OUT_OF_RANGE",
        "Position out of range: " + position.to_string(),
      )
  }
  let base = ok_response("SELECT")
  {
    success: base.success,
    operation: "SELECT",
    affected_rows: base.affected_rows,
    position: base.position,
    error: base.error,
    error_code: base.error_code,
    message: "查询成功",
    data: rows,
    total_records: rows.length(),
  }
}
