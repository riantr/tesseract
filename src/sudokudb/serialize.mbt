///|
/// Import and export in the three formats the C# app could read and write.
///
/// - `.sdb` — JSON, the native save format, kept field-for-field compatible
///   with the C# exporter so old files load, extended with `coords` and `digit`;
/// - `.md` — a Markdown table, human-readable and diffable;
/// - `.sql` — a SQL dump that this package's own parser can re-import.
///
/// Round-tripping preserves *positions*, not just contents: a re-import puts
/// each record back in the cell it came from, so a saved lattice reloads as
/// the same lattice.

///|
/// Escapes a string for a JSON string body.
fn json_escape(s : String) -> String {
  let b = StringBuilder::StringBuilder(size_hint=s.length() + 8)
  let mut i = 0
  while i < s.length() {
    let c = s.at(i).to_int()
    if c == 34 {
      b.write_string("\\\"")
    } else if c == 92 {
      b.write_string("\\\\")
    } else if c == 10 {
      b.write_string("\\n")
    } else if c == 13 {
      b.write_string("\\r")
    } else if c == 9 {
      b.write_string("\\t")
    } else if c < 0x20 {
      b.write_string("\\u00")
      let hex = "0123456789abcdef"
      b.write_char(cu_char(hex.at(c / 16).to_int()))
      b.write_char(cu_char(hex.at(c % 16).to_int()))
    } else {
      b.write_char(cu_char(c))
    }
    i = i + 1
  }
  b.to_string()
}

///|
/// The `.sdb` JSON document for the whole database.
pub fn export_sdb(db : SudokuDB) -> String {
  let b = StringBuilder::StringBuilder()
  b.write_string("{\n")
  b.write_string("  \"dbName\": \"")
  b.write_string(json_escape(db.db_name))
  b.write_string("\",\n")
  b.write_string("  \"dimensions\": 4,\n")
  b.write_string("  \"side\": 3,\n")
  b.write_string("  \"total_cells\": 81,\n")
  b.write_string("  \"records\": [\n")
  let all = SudokuDB::select(db, "", "", None, no_filter(), None)
  let mut first = true
  let mut i = 0
  while i < all.data.length() {
    let r = all.data[i]
    if !first {
      b.write_string(",\n")
    }
    first = false
    b.write_string("    {\"grid_position\": ")
    b.write_object(r.position)
    b.write_string(", \"coords\": \"")
    b.write_string(format_coords(r.coords))
    b.write_string("\", \"key\": \"")
    b.write_string(json_escape(r.key))
    b.write_string("\", \"value\": \"")
    b.write_string(json_escape(r.value))
    b.write_string("\", \"digit\": ")
    b.write_object(r.digit)
    b.write_string(", \"timestamp\": \"")
    b.write_string(r.timestamp)
    b.write_string("\"}")
    i = i + 1
  }
  b.write_string("\n  ]\n}\n")
  b.to_string()
}

///|
/// The value at a JSON object's key, or `None` for a non-object.
fn json_field(v : Json, key : String) -> Json? {
  match v {
    Json::Object(obj) => obj.get(key)
    _ => None
  }
}

///|
/// Reads a value at a JSON key as a string, or "" when absent.
fn json_str(v : Json, key : String) -> String {
  match json_field(v, key) {
    Some(Json::String(s)) => s
    _ => ""
  }
}

///|
/// Reads a value at a JSON key as an integer, or `fallback`.
fn json_int(v : Json, key : String, fallback : Int) -> Int {
  match json_field(v, key) {
    Some(Json::Number(n, repr=_)) => n.to_int()
    _ => fallback
  }
}

///|
/// Loads a `.sdb` document, returning how many records were restored.
///
/// The database is cleared first, so a failed load leaves an empty database
/// rather than a half-overwritten one mixed with whatever was there before.
pub fn import_sdb(db : SudokuDB, text : String) -> Result[Int, String] {
  if !@json.valid(text) {
    return Err("Not valid JSON")
  }
  let root = @json.parse(text) catch { _ => return Err("Not valid JSON") }
  let items = match json_field(root, "records") {
    Some(Json::Array(a)) => a
    _ => return Err("Missing records array")
  }
  let mut loaded = 0
  let mut i = 0
  // The clear this function has always documented. Without it a load merged
  // into whatever was already stored, so the count it returned described only
  // the records in the file and the lattice kept records the file never
  // mentioned.
  ignore(SudokuDB::delete(db, "", None))
  while i < items.length() {
    let item = items[i]
    let key = json_str(item, "key")
    let value = json_str(item, "value")
    if key != "" && value != "" {
      let mut target = json_int(item, "grid_position", 0)
      if !position_in_bounds(target) {
        let coords_field = json_str(item, "coords")
        target = match parse_coords(coords_field) {
          Some(c) => position_of(c)
          None => 0
        }
      }
      if !position_in_bounds(target) {
        // Falling back to cell 1 is exactly the "a malformed address resolves
        // to another cell" behaviour the rest of the library refuses: it
        // displaces whatever was in cell 1 and still reads as a clean load.
        return Err(
          "Record " +
          i.to_string() +
          " (" +
          key +
          ") has no usable grid_position or coords",
        )
      }
      let digit = json_int(item, "digit", NO_DIGIT)
      // The file's own timestamp is restored rather than re-derived from the
      // logger counter, which is what lets `export` after `import` reproduce
      // the source document byte for byte.
      let stamp = json_str(item, "timestamp")
      let response = SudokuDB::insert_stamped(
        db,
        key,
        value,
        Some(target),
        digit,
        if stamp == "" {
          None
        } else {
          Some(stamp)
        },
      )
      if response.success {
        loaded = loaded + 1
      }
    }
    i = i + 1
  }
  Ok(loaded)
}

///|
/// Escapes a value for the Markdown table.
///
/// A `|` inside a value has to survive the round trip, so it is backslash
/// escaped and the importer below splits on unescaped pipes only. Newlines
/// become `<br>` for readability; a value containing the literal text `<br>`
/// therefore comes back as a newline — the JSON `.sdb` format is the lossless
/// one.
fn escape_markdown(s : String) -> String {
  let b = StringBuilder::StringBuilder(size_hint=s.length())
  let mut i = 0
  while i < s.length() {
    let c = s.at(i).to_int()
    if c == 92 {
      b.write_string("\\\\")
    } else if c == 124 {
      b.write_string("\\|")
    } else if c == 10 {
      b.write_string("<br>")
    } else if c == 9 {
      // TAB and CR are escaped rather than reformatted. TAB used to be
      // written as four spaces and CR was dropped outright, so a value came
      // back as a different string - a silent, one-way corruption that only
      // `.sdb` and `.sql` avoided.
      b.write_string("\\t")
    } else if c == 13 {
      b.write_string("\\r")
    } else {
      b.write_char(cu_char(c))
    }
    i = i + 1
  }
  b.to_string()
}

///|
/// Reverses `escape_markdown` for a single cell.
fn unescape_markdown(s : String) -> String {
  let b = StringBuilder::StringBuilder(size_hint=s.length())
  let mut i = 0
  while i < s.length() {
    let c = s.at(i).to_int()
    if c == 92 && i + 1 < s.length() {
      let next = s.at(i + 1)
      if next == 'n' {
        b.write_char('\n')
      } else if next == 'r' {
        b.write_char('\r')
      } else if next == 't' {
        b.write_char('\t')
      } else {
        b.write_char(cu_char(next.to_int()))
      }
      i = i + 2
      continue
    }
    if starts_ci(slice(s, i, s.length()), "<br>") {
      b.write_char('\n')
      i = i + 4
      continue
    }
    b.write_char(cu_char(c))
    i = i + 1
  }
  b.to_string()
}

///|
/// Splits a Markdown row on unescaped pipes.
///
/// A trailing empty field is kept so column indexes line up with the header,
/// which is produced by the same rule.
fn split_markdown_row(line : String) -> Array[String] {
  let out : Array[String] = []
  let current = StringBuilder::StringBuilder(size_hint=line.length())
  let mut i = 1
  while i < line.length() {
    let c = line.at(i).to_int()
    if c == 92 && i + 1 < line.length() {
      current.write_char(cu_char(c))
      current.write_char(cu_char(line.at(i + 1).to_int()))
      i = i + 2
      continue
    }
    if c == 124 {
      out.push(trim_ws(current.to_string()))
      ignore(current.reset())
    } else {
      current.write_char(cu_char(c))
    }
    i = i + 1
  }
  out.push(trim_ws(current.to_string()))
  out
}

///|
/// The Markdown table for the whole database.
pub fn export_markdown(db : SudokuDB) -> String {
  let b = StringBuilder::StringBuilder()
  b.write_string("# SudokuDB 4D 数据导出\n\n")
  let s = SudokuDB::status(db)
  b.write_string("维度: 3x3x3x3 (81 cells)  \n")
  b.write_string("总记录数: ")
  b.write_object(s.current_count)
  b.write_string("  \n")
  b.write_string("写入位置: ")
  b.write_object(s.current_position)
  b.write_string("\n\n## 数据表格\n\n")
  b.write_string("| 位置 | 坐标 | Key | Value | 数 | 时间戳 |\n")
  b.write_string("|------|------|-----|-------|----|--------|\n")
  let all = SudokuDB::select(db, "", "", None, no_filter(), None)
  let mut i = 0
  while i < all.data.length() {
    let r = all.data[i]
    b.write_string("| ")
    b.write_object(r.position)
    b.write_string(" | ")
    b.write_string(format_coords(r.coords))
    b.write_string(" | ")
    b.write_string(escape_markdown(r.key))
    b.write_string(" | ")
    b.write_string(escape_markdown(r.value))
    b.write_string(" | ")
    b.write_object(r.digit)
    b.write_string(" | ")
    b.write_string(r.timestamp)
    b.write_string(" |\n")
    i = i + 1
  }
  b.write_string("\n---\n\n*导出完成*\n")
  b.to_string()
}

///|
/// True when every cell is made only of `-` and `:`, i.e. a table rule.
///
/// Without this the separator row `|------|-----|` parses as a record whose
/// key and value are both `------`.
fn is_table_rule(cells : Array[String]) -> Bool {
  if cells.length() == 0 {
    return false
  }
  let mut i = 0
  while i < cells.length() {
    let c = cells[i]
    let mut j = 0
    while j < c.length() {
      let u = c.at(j).to_int()
      if u != 45 && u != 58 {
        return false
      }
      j = j + 1
    }
    i = i + 1
  }
  true
}

///|
/// Index of `name` in a Markdown header row, or -1.
fn md_column(header : Array[String], name : String) -> Int {
  let mut i = 0
  while i < header.length() {
    if eq_ci(header[i], name) {
      return i
    }
    i = i + 1
  }
  -1
}

///|
/// Loads a Markdown table previously written by `export_markdown`.
///
/// The C# header (`位置 | Key | Value | 时间戳`) is accepted too, as long as
/// it carries at least a key and a value column.
pub fn import_markdown(db : SudokuDB, text : String) -> Result[Int, String] {
  let lines = split(text, "\n")
  let mut header : Array[String] = []
  let mut loaded = 0
  let mut i = 0
  while i < lines.length() {
    let line = trim_ws(lines[i])
    if line.length() > 1 && line.at(0) == '|' {
      let cells = split_markdown_row(line)
      if header.length() == 0 {
        header = cells
        i = i + 1
        continue
      }
      if is_table_rule(cells) {
        i = i + 1
        continue
      }
      let key_col = md_column(header, "key")
      let value_col = md_column(header, "value")
      let mut pos_col = md_column(header, "位置")
      if pos_col < 0 {
        pos_col = md_column(header, "position")
      }
      let coords_col = md_column(header, "坐标")
      let digit_col = md_column(header, "数")
      if key_col < 0 ||
        value_col < 0 ||
        key_col >= cells.length() ||
        value_col >= cells.length() {
        i = i + 1
        continue
      }
      let key = unescape_markdown(cells[key_col])
      let value = unescape_markdown(cells[value_col])
      if key == "" || value == "" {
        i = i + 1
        continue
      }
      let mut target = 0
      if pos_col >= 0 && pos_col < cells.length() {
        match parse_int(cells[pos_col]) {
          Some(p) => target = p
          None => target = 0
        }
      }
      if !position_in_bounds(target) &&
        coords_col >= 0 &&
        coords_col < cells.length() {
        match parse_coords(cells[coords_col]) {
          Some(c) => target = position_of(c)
          None => target = 0
        }
      }
      if !position_in_bounds(target) {
        return Err(
          "Row " +
          i.to_string() +
          " (" +
          key +
          ") has no usable position or coords",
        )
      }
      let digit = if digit_col >= 0 && digit_col < cells.length() {
        match parse_int(cells[digit_col]) {
          Some(d) => d
          None => NO_DIGIT
        }
      } else {
        NO_DIGIT
      }
      let response = SudokuDB::insert(db, key, value, Some(target), digit)
      if response.success {
        loaded = loaded + 1
      }
    }
    i = i + 1
  }
  if header.length() == 0 {
    return Err("No Markdown table found")
  }
  Ok(loaded)
}

///|
/// Escapes a value for a single-quoted SQL literal.
///
/// Control characters are escaped rather than emitted raw: a literal newline
/// inside the quotes would split the dump into two broken statements. The
/// scheme is exactly what `sql.mbt`'s `unquote` reverses.
fn escape_sql_literal(s : String) -> String {
  let b = StringBuilder::StringBuilder(size_hint=s.length())
  let mut i = 0
  while i < s.length() {
    let c = s.at(i).to_int()
    if c == 39 {
      b.write_string("\\'")
    } else if c == 92 {
      b.write_string("\\\\")
    } else if c == 10 {
      b.write_string("\\n")
    } else if c == 13 {
      b.write_string("\\r")
    } else if c == 9 {
      b.write_string("\\t")
    } else {
      b.write_char(cu_char(c))
    }
    i = i + 1
  }
  b.to_string()
}

///|
/// A SQL dump that this package's parser reads back exactly.
pub fn export_sql(db : SudokuDB) -> String {
  let b = StringBuilder::StringBuilder()
  b.write_string("-- SudokuDB 4D export\n")
  b.write_string("-- lattice: 3x3x3x3, 81 cells\n")
  let s = SudokuDB::status(db)
  b.write_string("-- records: ")
  b.write_object(s.current_count)
  b.write_string("\n\nCREATE DATABASE sudokuDB;\n\n")
  let all = SudokuDB::select(db, "", "", None, no_filter(), None)
  let mut i = 0
  while i < all.data.length() {
    let r = all.data[i]
    b.write_string("INSERT INTO sudokuDB (key, value, digit) VALUES ('")
    b.write_string(escape_sql_literal(r.key))
    b.write_string("', '")
    b.write_string(escape_sql_literal(r.value))
    b.write_string("', ")
    b.write_object(r.digit)
    b.write_string(") AT ")
    b.write_string(format_coords(r.coords))
    b.write_string(";\n")
    i = i + 1
  }
  b.to_string()
}

///|
/// Splits a SQL script on `;` outside string literals.
fn split_statements(text : String) -> Array[String] {
  let out : Array[String] = []
  let mut start = 0
  let mut i = 0
  let mut in_quote = false
  let mut escape = false
  while i < text.length() {
    let c = text.at(i).to_int()
    if escape {
      escape = false
    } else if c == 92 {
      escape = true
    } else if c == 39 {
      in_quote = !in_quote
    } else if c == 59 && !in_quote {
      let stmt = trim_ws(slice(text, start, i))
      if stmt != "" {
        out.push(stmt)
      }
      start = i + 1
    }
    i = i + 1
  }
  let tail = trim_ws(slice(text, start, text.length()))
  if tail != "" {
    out.push(tail)
  }
  out
}

///|
/// Removes `--` comments, honouring string literals.
///
/// A statement whose *first* characters are a comment must not be skipped
/// wholesale: an export opens with a comment banner, so skipping it would drop
/// the `CREATE DATABASE` that follows on later lines.
fn strip_sql_comments(text : String) -> String {
  let out = StringBuilder::StringBuilder(size_hint=text.length())
  let mut i = 0
  let mut in_quote = false
  let mut escape = false
  let mut line_start = true
  while i < text.length() {
    let c = text.at(i).to_int()
    if escape {
      out.write_char(cu_char(c))
      escape = false
      line_start = c == 10
      i = i + 1
      continue
    }
    if c == 92 && in_quote {
      out.write_char(cu_char(c))
      escape = true
      i = i + 1
      continue
    }
    if c == 39 {
      in_quote = !in_quote
      out.write_char(cu_char(c))
      line_start = false
      i = i + 1
      continue
    }
    if !in_quote &&
      c == 45 &&
      i + 1 < text.length() &&
      text.at(i + 1).to_int() == 45 {
      // Skip to end of line, but keep the newline itself.
      while i < text.length() && text.at(i).to_int() != 10 {
        i = i + 1
      }
      continue
    }
    if c == 10 {
      line_start = true
    } else if !is_space(c) {
      line_start = false
    }
    out.write_char(cu_char(c))
    i = i + 1
  }
  ignore(line_start)
  out.to_string()
}

///|
/// Runs a SQL script, returning how many statements succeeded.
pub fn import_sql(db : SudokuDB, text : String) -> Result[Int, String] {
  let statements = split_statements(text)
  if statements.length() == 0 {
    return Err("No statements found")
  }
  let mut ok = 0
  let mut failed = 0
  let mut first_error = ""
  let mut i = 0
  while i < statements.length() {
    let stmt = trim_ws(strip_sql_comments(statements[i]))
    if stmt != "" {
      let response = execute(db, stmt)
      if response.success {
        ok = ok + 1
      } else {
        // Counting only the successes reported a broken script as a clean
        // import: a dump truncated by a stray banner line still came back Ok.
        failed = failed + 1
        if first_error == "" {
          first_error = response.error_code + ": " + response.error
        }
      }
    }
    i = i + 1
  }
  if failed > 0 {
    return Err(
      failed.to_string() +
      " of " +
      statements.length().to_string() +
      " statement(s) failed; first was " +
      first_error,
    )
  }
  Ok(ok)
}

///|
/// One cell rendered for the lattice view.
fn lattice_cell(db : SudokuDB, position : Int, cursor : Int) -> String {
  let cell = db.cells[position - 1]
  let marker = if position == cursor { ">" } else { " " }
  let label = if cell_is_empty(cell) {
    "."
  } else {
    // The digit is what a solved lattice is read for, so it is appended after
    // the width has been spent on the key. Truncating the key to 6 first and
    // then ellipsizing key+digit deleted it again - `ellipsize` cuts from the
    // end - so a 6-character key like `cell_1` always rendered as `cell_~`.
    let room = if cell.digit == NO_DIGIT { 6 } else { 5 }
    let shown = ellipsize(cell.key, room)
    if cell.digit == NO_DIGIT {
      shown
    } else {
      shown + cell.digit.to_string()
    }
  }
  let b = StringBuilder::StringBuilder()
  b.write_string(marker)
  b.write_string(ellipsize(label, 6))
  return b.to_string()
}

///|
/// The 4D lattice as 27 slices of 3x3, grouped three to a line.
///
/// With only 3 cells per axis there is no single "right" way to flatten four
/// dimensions onto a terminal, so this fixes the two slowest axes and lays the
/// remaining 3x3 out as a grid — the same reading a 2D sudoku grid gets.
pub fn render_lattice(db : SudokuDB, cursor : Int) -> String {
  let b = StringBuilder::StringBuilder()
  let mut x = 0
  while x < SIDE {
    b.write_string("=== x = ")
    b.write_object(x)
    b.write_string(" ===\n")
    let mut y = 0
    while y < SIDE {
      let mut z = 0
      while z < SIDE {
        let mut w = 0
        while w < SIDE {
          let cell_c = coords(x, y, z, w)
          let text = lattice_cell(db, position_of(cell_c), cursor)
          b.write_string(pad_right(text, 8))
          w = w + 1
        }
        b.write_string("  ")
        z = z + 1
      }
      b.write_string("  y=")
      b.write_object(y)
      b.write_char('\n')
      y = y + 1
    }
    x = x + 1
  }
  b.write_string("cells: . empty, digits appended (1-3), > = insert cursor\n")
  b.to_string()
}
