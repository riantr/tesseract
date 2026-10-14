///|
/// The SQL surface.
///
/// A superset of what the C# `SQLParser` accepted, keeping its statement
/// shapes and its error-code vocabulary so existing `.sql` dumps still load:
///
/// ```sql
/// CREATE DATABASE tesseract;
/// INSERT INTO tesseract (key, value) VALUES ('k', 'v');
/// SELECT * FROM tesseract WHERE key = 'k';
/// SELECT * FROM tesseract WHERE grid_position = 42;
/// SELECT * FROM tesseract WHERE x = 1 AND y = 2;
/// SELECT * FROM tesseract WHERE value LIKE '%pat%';
/// UPDATE tesseract SET value = 'v' WHERE key = 'k';
/// DELETE FROM tesseract WHERE key = 'k';
/// ```
///
/// The 4D additions are an optional target address, an optional digit, and
/// geometric predicates:
///
/// ```sql
/// INSERT INTO tesseract (key, value) VALUES ('k', 'v') AT 42;
/// INSERT INTO tesseract (key, value) VALUES ('k', 'v') AT (1,2,0,2);
/// INSERT INTO tesseract (key, value, digit) VALUES ('k', 'v', 2);
/// UPDATE tesseract SET value = 'v', digit = 3 WHERE grid_position = 42;
/// SELECT * FROM tesseract WHERE line(42, 0);
/// SELECT * FROM tesseract WHERE slab(42, 1);
/// SELECT * FROM tesseract WHERE peers(42);
/// ```
///
/// The parser is hand-written against the ASCII helpers in `text.mbt`; MoonBit
/// ships no regex, and the subset is small enough not to want one.

///|
/// A geometric restriction that replaces the ordinary cell scan.
pub enum Geometry {
  None
  Line(Int32, Int32)
  Slab(Int32, Int32)
  Peers(Int32)
}

///|
/// A parsed `WHERE` clause. Every field is optional and they compose with AND.
pub struct Where {
  key : String
  pattern : String
  position : Int32?
  coords : CoordFilter
  digit : Int32?
  geometry : Geometry
}

///|
/// An empty `WHERE`, matching every occupied cell.
pub fn no_where() -> Where {
  {
    key: "",
    pattern: "",
    position: None,
    coords: no_filter(),
    digit: None,
    geometry: None,
  }
}

///|
/// A copy of `w` with a different key predicate.
fn with_key(w : Where, key : String) -> Where {
  {
    key,
    pattern: w.pattern,
    position: w.position,
    coords: w.coords,
    digit: w.digit,
    geometry: w.geometry,
  }
}

///|
/// A copy of `w` with a different LIKE pattern.
fn with_pattern(w : Where, pattern : String) -> Where {
  {
    key: w.key,
    pattern,
    position: w.position,
    coords: w.coords,
    digit: w.digit,
    geometry: w.geometry,
  }
}

///|
/// A copy of `w` with a different position predicate.
fn with_position(w : Where, position : Int32) -> Where {
  {
    key: w.key,
    pattern: w.pattern,
    position: Some(position),
    coords: w.coords,
    digit: w.digit,
    geometry: w.geometry,
  }
}

///|
/// A copy of `w` with a different digit predicate.
fn with_digit(w : Where, digit : Int32) -> Where {
  {
    key: w.key,
    pattern: w.pattern,
    position: w.position,
    coords: w.coords,
    digit: Some(digit),
    geometry: w.geometry,
  }
}

///|
/// A copy of `w` with a different coordinate filter.
fn with_coords(w : Where, coords : CoordFilter) -> Where {
  {
    key: w.key,
    pattern: w.pattern,
    position: w.position,
    coords,
    digit: w.digit,
    geometry: w.geometry,
  }
}

///|
/// A copy of `w` with a different geometry restriction.
fn with_geometry(w : Where, geometry : Geometry) -> Where {
  {
    key: w.key,
    pattern: w.pattern,
    position: w.position,
    coords: w.coords,
    digit: w.digit,
    geometry,
  }
}

///|
/// A copy of `f` with `axis` constrained to `v`.
fn set_axis(f : CoordFilter, axis : Int32, v : Int32) -> CoordFilter {
  match axis {
    0 => { x: v, y: f.y, z: f.z, w: f.w, }
    1 => { x: f.x, y: v, z: f.z, w: f.w, }
    2 => { x: f.x, y: f.y, z: v, w: f.w, }
    _ => { x: f.x, y: f.y, z: f.z, w: v, }
  }
}

///|
/// True for a SQL identifier character.
fn is_word_char(c : Int32) -> Bool {
  let alpha = (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
  let digit = c >= 48 && c <= 57
  alpha || digit || c == 95
}

///|
/// Index of `kw` in `s` at a word boundary at or after `from`, or `None`.
fn find_word(s : String, kw : String, from : Int32) -> Int32? {
  let mut at = from
  while at <= s.length() - kw.length() {
    match index_of_ci(slice(s, at, s.length()), kw) {
      Some(rel) => {
        let abs = at + rel
        let before_ok = abs == 0 || !is_word_char(s.at(abs - 1).to_int())
        let end = abs + kw.length()
        let after_ok = end >= s.length() || !is_word_char(s.at(end).to_int())
        if before_ok && after_ok {
          return Some(abs)
        }
        at = abs + 1
      }
      None => return None
    }
  }
  None
}

///|
/// Index of the `(` at or after `from`, ignoring quoted text.
fn find_paren(s : String, from : Int32) -> Int32? {
  let mut i = from
  let mut in_quote = false
  let mut escape = false
  while i < s.length() {
    let c = s.at(i)
    if escape {
      escape = false
    } else if c == '\\' {
      escape = true
    } else if c == '\'' {
      in_quote = !in_quote
    } else if c == '(' && !in_quote {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
/// Index of the `)` closing the group opened at `open`, ignoring quoted text.
fn close_paren(s : String, open : Int32) -> Int32? {
  let mut i = open + 1
  let mut depth = 0
  let mut in_quote = false
  let mut escape = false
  while i < s.length() {
    let c = s.at(i)
    if escape {
      escape = false
    } else if c == '\\' {
      escape = true
    } else if c == '\'' {
      in_quote = !in_quote
    } else if !in_quote && c == '(' {
      depth = depth + 1
    } else if !in_quote && c == ')' {
      if depth == 0 {
        return Some(i)
      }
      depth = depth - 1
    }
    i = i + 1
  }
  None
}

///|
/// Splits a group body on top-level commas.
///
/// Tracks quotes *and* parentheses: without the depth counter a predicate like
/// `line(1, 3)` would be cut in half at its comma.
fn split_top_level(body : String) -> Array[String] {
  let out : Array[String] = []
  let mut start = 0
  let mut i = 0
  let mut depth = 0
  let mut in_quote = false
  let mut escape = false
  while i < body.length() {
    let c = body.at(i)
    if escape {
      escape = false
    } else if c == '\\' {
      escape = true
    } else if c == '\'' {
      in_quote = !in_quote
    } else if !in_quote && c == '(' {
      depth = depth + 1
    } else if !in_quote && c == ')' {
      depth = depth - 1
    } else if c == ',' && !in_quote && depth == 0 {
      out.push(trim_ws(slice(body, start, i)))
      start = i + 1
    }
    i = i + 1
  }
  out.push(trim_ws(slice(body, start, body.length())))
  out
}

///|
/// Splits on the word `kw`, ignoring occurrences inside quotes or parentheses.
///
/// `AND` is the clause separator here, not the comma — a comma is only a
/// separator in the value list and the SET list, both of which are extracted
/// before reaching this point.
fn split_keyword(s : String, kw : String) -> Array[String] {
  let out : Array[String] = []
  let mut start = 0
  let mut i = 0
  let mut depth = 0
  let mut in_quote = false
  let mut escape = false
  while i < s.length() {
    let c = s.at(i)
    if escape {
      escape = false
      i = i + 1
      continue
    }
    if c == '\\' {
      escape = true
      i = i + 1
      continue
    }
    if c == '\'' {
      in_quote = !in_quote
      i = i + 1
      continue
    }
    if in_quote {
      i = i + 1
      continue
    }
    if c == '(' {
      depth = depth + 1
      i = i + 1
      continue
    }
    if c == ')' {
      depth = depth - 1
      i = i + 1
      continue
    }
    if depth == 0 && eq_ci(slice(s, i, i + kw.length()), kw) {
      let before_ok = i == 0 || !is_word_char(s.at(i - 1).to_int())
      let end = i + kw.length()
      let after_ok = end >= s.length() || !is_word_char(s.at(end).to_int())
      if before_ok && after_ok {
        out.push(trim_ws(slice(s, start, i)))
        start = end
        i = end
        continue
      }
    }
    i = i + 1
  }
  out.push(trim_ws(slice(s, start, s.length())))
  out
}

///|
/// Strips one layer of single quotes and resolves backslash escapes.
///
/// Reverses `serialize.mbt`'s `escape_sql_literal`: `\\n`, `\\r`, `\\t` become
/// the control characters, `\\'` and `\\\\` become `'` and `\`, and any other
/// `\X` yields `X` — the generic rule the C# parser used.
fn unquote(s : String) -> Result[String, String] {
  let t = trim_ws(s)
  if t == "" {
    return Err("Missing value")
  }
  if t.at(0) != '\'' {
    // A bare token is an integer or an identifier. A quote *inside* one means
    // the writer opened a literal and lost the closing quote.
    if t.contains("'") {
      return Err("Unterminated string literal: " + t)
    }
    return Ok(t)
  }
  let mut scan = 1
  let mut esc = false
  let mut closed = -1
  while scan < t.length() {
    let c = t.at(scan)
    if esc {
      esc = false
    } else if c == '\\' {
      esc = true
    } else if c == '\'' {
      // `''` inside a literal is an escaped quote - the standard SQL spelling.
      // The exporter here uses the backslash form, but a dump written by
      // another engine uses this one. It cannot be confused with "closing quote
      // then junk": the junk would have to begin with a quote as well.
      if scan + 1 < t.length() && t.at(scan + 1) == '\'' {
        scan = scan + 2
        continue
      }
      closed = scan
    }
    if closed >= 0 {
      break
    }
    scan = scan + 1
  }
  if closed < 0 {
    return Err("Unterminated string literal: " + t)
  }
  let tail = trim_ws(slice(t, closed + 1, t.length()))
  if tail != "" {
    return Err("Unexpected text after string literal: " + tail)
  }
  let body = slice(t, 1, closed)
  let b = StringBuilder::StringBuilder(size_hint=body.length())
  let mut i = 0
  let mut escape = false
  while i < body.length() {
    let c = body.at(i).to_int()
    if escape {
      if c == 110 {
        b.write_char('\n')
      } else if c == 114 {
        b.write_char('\r')
      } else if c == 116 {
        b.write_char('\t')
      } else {
        b.write_char(cu_char(c))
      }
      escape = false
      i = i + 1
    } else if c == '\\' {
      escape = true
      i = i + 1
    } else if c == 39 && i + 1 < body.length() && body.at(i + 1) == '\'' {
      b.write_char('\'')
      i = i + 2
    } else {
      b.write_char(cu_char(c))
      i = i + 1
    }
  }
  return Ok(b.to_string())
}

///|
/// The literal of a `LIKE` predicate, with its `%` wildcards left in place.
///
/// The markers stay because they are the dialect: `%...%` means "contains" and
/// anything else means equality. Stripping them and reading "nothing left" as
/// "no predicate" is what made `LIKE 'hello'` match every row — and a filter
/// that comes back too wide hides a problem instead of showing it.
fn like_pattern(s : String) -> Result[String, String] {
  let raw = match unquote(s) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if raw == "" {
    return Err("LIKE needs a non-empty pattern")
  }
  Ok(raw)
}

///|
/// Parses `name(a, b)`, returning the name and its integer arguments.
fn call_predicate(s : String) -> (String, Array[Int32])? {
  let open = match find_paren(s, 0) {
    Some(o) => o
    None => return None
  }
  let close = match close_paren(s, open) {
    Some(c) => c
    None => return None
  }
  if close + 1 < s.length() {
    return None
  }
  let name = trim_ws(slice(s, 0, open))
  let args : Array[Int32] = []
  for part in split_top_level(slice(s, open + 1, close)) {
    let lit = match unquote(part) {
      Ok(v) => v
      Err(_) => return None
    }
    match parse_int(lit) {
      Some(v) => args.push(v)
      None => return None
    }
  }
  Some((name, args))
}

///|
/// Parses one `WHERE` condition onto `w`.
fn parse_condition(w : Where, cond : String) -> Result[Where, DBResponse] {
  let c = trim_ws(cond)
  if c == "" {
    return Ok(w)
  }
  match call_predicate(c) {
    Some((name, args)) => {
      let name_lower = lower(name)
      if name_lower == "line" || name_lower == "slab" {
        if args.length() != 2 {
          return Err(
            err_response(
              "INVALID_SYNTAX", "line()/slab() need (position, axis)",
            ),
          )
        }
        let axis = args[1]
        // This guard is what turns a mistake into an error rather than a
        // different question than the one that was asked. `coord_at` used to
        // fall through to the last axis for anything out of range, and
        // `with_coord` still does, so `line(1,7)` answered exactly what
        // `line(1,3)` answers. Both helpers now refuse a bad axis themselves —
        // they answer an empty result — so this is defence at the SQL
        // boundary, where a wrong axis can be reported as `INVALID_SYNTAX`
        // instead of as an empty row set.
        if axis < 0 || axis >= DIM {
          return Err(
            err_response(
              "INVALID_SYNTAX",
              "Axis must be 0..3, got " + axis.to_string(),
            ),
          )
        }
        let geometry = if name_lower == "line" {
          Geometry::Line(args[0], axis)
        } else {
          Geometry::Slab(args[0], axis)
        }
        return Ok(with_geometry(w, geometry))
      }
      if name_lower == "peers" {
        if args.length() != 1 {
          return Err(
            err_response("INVALID_SYNTAX", "peers() needs one position"),
          )
        }
        return Ok(with_geometry(w, Geometry::Peers(args[0])))
      }
      Err(err_response("INVALID_SYNTAX", "Unknown function: " + name))
    }
    None =>
      match find_word(c, "LIKE", 0) {
        Some(at) => {
          let lhs = lower(trim_ws(slice(c, 0, at)))
          if lhs != "value" {
            return Err(
              err_response("INVALID_SYNTAX", "LIKE only applies to value"),
            )
          }
          match like_pattern(trim_ws(slice(c, at + 4, c.length()))) {
            Ok(p) => Ok(with_pattern(w, p))
            Err(message) => Err(err_response("INVALID_SYNTAX", message))
          }
        }
        None => parse_equality(w, c)
      }
  }
}

///|
/// Parses a `column = value` condition.
fn parse_equality(w : Where, c : String) -> Result[Where, DBResponse] {
  let eq = match index_of_ci(c, "=") {
    Some(e) => e
    None =>
      return Err(err_response("INVALID_SYNTAX", "Condition needs '=': " + c))
  }
  let lhs = trim_ws(slice(c, 0, eq))
  let rhs = trim_ws(slice(c, eq + 1, c.length()))
  match lower(lhs) {
    "key" =>
      match unquote(rhs) {
        Ok(k) => Ok(with_key(w, k))
        Err(message) => Err(err_response("INVALID_SYNTAX", message))
      }
    "grid_position" =>
      match parse_int(rhs) {
        Some(v) => Ok(with_position(w, v))
        None =>
          Err(err_response("INVALID_SYNTAX", "grid_position needs an integer"))
      }
    "digit" =>
      match parse_int(rhs) {
        Some(v) => Ok(with_digit(w, v))
        None => Err(err_response("INVALID_SYNTAX", "digit needs an integer"))
      }
    "x" => coord_pred(w, lhs, rhs, 0)
    "y" => coord_pred(w, lhs, rhs, 1)
    "z" => coord_pred(w, lhs, rhs, 2)
    "w" => coord_pred(w, lhs, rhs, 3)
    _ => Err(err_response("INVALID_SYNTAX", "Unknown column: " + lhs))
  }
}

///|
/// Applies a single-axis coordinate predicate onto `w`.
fn coord_pred(
  w : Where,
  lhs : String,
  rhs : String,
  axis : Int32,
) -> Result[Where, DBResponse] {
  match parse_int(rhs) {
    Some(v) => Ok(with_coords(w, set_axis(w.coords, axis, v)))
    None => Err(err_response("INVALID_SYNTAX", lhs + " needs an integer"))
  }
}

///|
/// Parses a whole `WHERE` body (everything after the keyword).
pub fn parse_where(body : String) -> Result[Where, DBResponse] {
  let mut w = no_where()
  for cond in split_keyword(body, "AND") {
    match parse_condition(w, cond) {
      Ok(next) => w = next
      Err(e) => return Err(e)
    }
  }
  Ok(w)
}

///|
/// Index of the next occurrence of `kw` at a word boundary, skipping anything
/// inside quotes or parentheses, or -1 when there is none.
///
/// `find_word` looks at the raw text, so a `WHERE` inside a SET literal won the
/// race against the real keyword: `UPDATE ... SET value='x WHERE y = z' WHERE
/// key='k'` cut the statement at the literal's `WHERE` and then failed to parse
/// the remainder. `SELECT` and `DELETE` escaped this only because their `WHERE`
/// always comes before any literal.
fn find_word_outside(s : String, kw : String, from : Int32) -> Int32 {
  let mut i = from
  let mut depth = 0
  let mut in_quote = false
  let mut escape = false
  while i < s.length() {
    let c = s.at(i)
    if escape {
      escape = false
    } else if c == '\\' && in_quote {
      escape = true
    } else if c == '\'' {
      in_quote = !in_quote
    } else if !in_quote && c == '(' {
      depth = depth + 1
    } else if !in_quote && c == ')' {
      depth = depth - 1
    } else if !in_quote && depth == 0 && eq_ci(slice(s, i, i + kw.length()), kw) {
      let before_ok = i == 0 || !is_word_char(s.at(i - 1).to_int())
      let end = i + kw.length()
      let after_ok = end >= s.length() || !is_word_char(s.at(end).to_int())
      if before_ok && after_ok {
        return i
      }
    }
    i = i + 1
  }
  -1
}

///|
/// Index of the `WHERE` keyword, or -1 when there is none.
///
/// Callers that need to cut the statement in two use the *keyword* index, not
/// the index of the body after it — the body starts one character later, at the
/// space, and cutting there leaves the tail of the SET list attached.
fn where_index(sql : String) -> Int32 {
  find_word_outside(sql, "WHERE", 0)
}

///|
/// Text after the `WHERE` keyword, if present.
fn where_body(sql : String) -> String {
  let at = where_index(sql)
  if at < 0 {
    return ""
  }
  slice(sql, at + 5, sql.length())
}

///|
/// Resolves an `AT <position|(x,y,z,w)>` target to a position.
fn parse_at(sql : String) -> Result[Int32?, DBResponse] {
  let at = match find_word(sql, "AT", 0) {
    Some(i) => i
    None => return Ok(None)
  }
  let rest = trim_ws(slice(sql, at + 2, sql.length()))
  let head = if rest.length() > 0 && rest.at(0) == '(' {
    match close_paren(rest, 0) {
      Some(close) => slice(rest, 0, close + 1)
      None =>
        return Err(err_response("INVALID_SYNTAX", "AT expects a valid address"))
    }
  } else {
    let mut i = 0
    while i < rest.length() && !is_space(rest.at(i).to_int()) {
      i = i + 1
    }
    slice(rest, 0, i)
  }
  if starts_ci(head, "(") {
    match parse_coords(head) {
      Some(c) => Ok(Some(position_of(c)))
      None =>
        Err(
          err_response("INVALID_SYNTAX", "AT expects a valid (x,y,z,w) address"),
        )
    }
  } else {
    match parse_int(head) {
      Some(v) => Ok(Some(v))
      None =>
        Err(err_response("INVALID_SYNTAX", "AT expects a position or address"))
    }
  }
}

///|
/// Column names from `INTO t (a, b)`, lower-cased.
///
/// Backticks and double quotes are stripped so the C# exporter's
/// `` `key` ``/`` `value` `` quoting still parses.
fn insert_columns(sql : String) -> Array[String]? {
  let open = match find_paren(sql, 0) {
    Some(o) => o
    None => return None
  }
  let close = match close_paren(sql, open) {
    Some(c) => c
    None => return None
  }
  let cols : Array[String] = []
  for part in split_top_level(slice(sql, open + 1, close)) {
    cols.push(unquote_identifier(trim_ws(part)))
  }
  Some(cols)
}

///|
/// Strips backticks and double quotes from an identifier.
fn unquote_identifier(s : String) -> String {
  let t = trim_ws(s)
  if t.length() >= 2 {
    let first = t.at(0)
    let last = t.at(t.length() - 1)
    if (first == '`' && last == '`') || (first == '"' && last == '"') {
      return lower(slice(t, 1, t.length() - 1))
    }
  }
  lower(t)
}

///|
/// `INSERT INTO tesseract (cols) VALUES (...) [AT target]`.
fn parse_insert(db : Tesseract, sql : String) -> DBResponse {
  let cols = match insert_columns(sql) {
    Some(c) => c
    None => return err_response("INVALID_SYNTAX", "Invalid INSERT syntax")
  }
  let values_at = match find_word(sql, "VALUES", 0) {
    Some(at) => at
    None => return err_response("INVALID_SYNTAX", "Invalid INSERT syntax")
  }
  let open = match find_paren(sql, values_at) {
    Some(o) => o
    None => return err_response("INVALID_SYNTAX", "Invalid INSERT syntax")
  }
  let close = match close_paren(sql, open) {
    Some(c) => c
    None => return err_response("INVALID_SYNTAX", "Invalid INSERT syntax")
  }
  let values = split_top_level(slice(sql, open + 1, close))
  if cols.length() != values.length() {
    let msg = StringBuilder::StringBuilder()
    msg.write_string("INSERT column/value mismatch: ")
    msg.write_object(cols.length())
    msg.write_string(" columns, ")
    msg.write_object(values.length())
    msg.write_string(" values")
    return err_response("INVALID_COLUMNS", msg.to_string())
  }
  let mut key = ""
  let mut value = ""
  let mut digit = NO_DIGIT
  let mut explicit_position = 0
  let mut i = 0
  while i < cols.length() {
    let raw = values[i]
    let lit = match unquote(raw) {
      Ok(v) => v
      Err(message) => return err_response("INVALID_SYNTAX", message)
    }
    if cols[i] == "key" {
      key = lit
    } else if cols[i] == "value" {
      value = lit
    } else if cols[i] == "digit" {
      match parse_int(lit) {
        Some(v) => digit = v
        None => return err_response("INVALID_SYNTAX", "digit needs an integer")
      }
    } else if cols[i] == "grid_position" {
      match parse_int(lit) {
        Some(v) => explicit_position = v
        None =>
          return err_response(
            "INVALID_SYNTAX", "grid_position needs an integer",
          )
      }
    } else if cols[i] == "timestamp" {
      // Accepted and ignored: MoonBit's core library has no wall clock, so
      // there is nothing meaningful to restore from the C# dump's timestamp.
      ()
    } else {
      return err_response("INVALID_COLUMNS", "Unknown column: " + cols[i])
    }
    i = i + 1
  }
  // Column order is irrelevant, so collect everything before acting: the C#
  // dump puts grid_position first, and acting on it in place would insert an
  // empty key.
  let target = if position_in_bounds(explicit_position) {
    Some(explicit_position)
  } else {
    match parse_at(slice(sql, close + 1, sql.length())) {
      Ok(t) => t
      Err(e) => return e
    }
  }
  Tesseract::insert(db, key, value, target, digit)
}

///|
/// `UPDATE tesseract SET col = val [, col = val] [WHERE ...]`.
fn parse_update(db : Tesseract, sql : String) -> DBResponse {
  let set_at = match find_word(sql, "SET", 0) {
    Some(at) => at
    None => return err_response("INVALID_SYNTAX", "Invalid UPDATE syntax")
  }
  let cut = where_index(sql)
  let stop = if cut < 0 { sql.length() } else { cut }
  let head = slice(sql, set_at + 3, stop)
  let body = if cut < 0 { "" } else { slice(sql, cut + 5, sql.length()) }
  let mut value = ""
  let mut digit : Int32? = None
  let mut seen_value = false
  for assign in split_top_level(head) {
    let eq = match index_of_ci(assign, "=") {
      Some(e) => e
      None => return err_response("INVALID_SYNTAX", "Invalid UPDATE syntax")
    }
    let col = lower(trim_ws(slice(assign, 0, eq)))
    let raw = trim_ws(slice(assign, eq + 1, assign.length()))
    let lit = match unquote(raw) {
      Ok(v) => v
      Err(message) => return err_response("INVALID_SYNTAX", message)
    }
    if col == "value" {
      value = lit
      seen_value = true
    } else if col == "digit" {
      match parse_int(lit) {
        Some(v) => digit = Some(v)
        None => return err_response("INVALID_SYNTAX", "digit needs an integer")
      }
    } else {
      return err_response("INVALID_SYNTAX", "Unknown column: " + col)
    }
  }
  if !seen_value {
    return err_response("INVALID_SYNTAX", "UPDATE needs SET value = '...'")
  }
  match parse_where(body) {
    Ok(w) => Tesseract::update(db, w.key, value, w.position, digit)
    Err(e) => e
  }
}

///|
/// `DELETE FROM tesseract [WHERE ...]`.
fn parse_delete(db : Tesseract, sql : String) -> DBResponse {
  let body = where_body(sql)
  match parse_where(body) {
    Ok(w) => Tesseract::delete(db, w.key, w.position)
    Err(e) => e
  }
}

///|
/// True when a result row satisfies every non-geometric condition in `w`.
fn row_matches(w : Where, row : Record) -> Bool {
  let key_ok = w.key == "" || row.key == w.key
  let pattern_ok = w.pattern == "" || like_matches(row.value, w.pattern)
  let position_ok = match w.position {
    Some(p) => row.position == p
    None => true
  }
  let digit_ok = match w.digit {
    Some(d) => row.digit == d
    None => true
  }
  key_ok &&
  pattern_ok &&
  position_ok &&
  digit_ok &&
  filter_matches(w.coords, row.coords)
}

///|
/// Narrows a geometry answer by the conjuncts the geometry call cannot see.
///
/// `line_query` / `slab_query` / `peer_query` each answer exactly one question
/// and return those rows. Every other condition in the same `WHERE` had been
/// parsed and then thrown away, so `WHERE line(1,3) AND digit = 2` answered a
/// different question than the one asked and `peers(1) AND key='zzz'` came back
/// with a row. Filtering the answer is what makes `AND` mean AND — the same
/// rule the non-geometry path gets from `Tesseract::select`.
fn narrow_by_others(r : DBResponse, w : Where) -> DBResponse {
  let kept = r.data.filter(fn(row) { row_matches(w, row) })
  {
    success: r.success,
    operation: r.operation,
    affected_rows: kept.length(),
    position: r.position,
    error: r.error,
    error_code: r.error_code,
    message: r.message,
    data: kept,
    total_records: kept.length(),
  }
}

///|
/// `SELECT * FROM tesseract [WHERE ...]`.
fn parse_select(db : Tesseract, sql : String) -> DBResponse {
  match find_word(sql, "FROM", 0) {
    Some(_) => ()
    None => return err_response("INVALID_SYNTAX", "SELECT needs FROM tesseract")
  }
  let body = where_body(sql)
  match parse_where(body) {
    Ok(w) =>
      match w.geometry {
        Geometry::None =>
          Tesseract::select(db, w.key, w.pattern, w.position, w.coords, w.digit)
        Geometry::Line(p, axis) =>
          narrow_by_others(Tesseract::line_query(db, p, axis), w)
        Geometry::Slab(p, axis) =>
          narrow_by_others(Tesseract::slab_query(db, p, axis), w)
        Geometry::Peers(p) => narrow_by_others(Tesseract::peer_query(db, p), w)
      }
    Err(e) => e
  }
}

///|
/// Runs one statement.
///
/// A trailing `;` is optional. Unknown statements come back as
/// `UNSUPPORTED_SQL`, matching the C# parser.
pub fn execute(db : Tesseract, sql : String) -> DBResponse {
  let mut t = trim_ws(sql)
  while t.length() > 0 && t.at(t.length() - 1) == ';' {
    t = trim_ws(slice(t, 0, t.length() - 1))
  }
  if t == "" {
    return err_response("EMPTY_SQL", "Empty SQL statement")
  }
  if find_word(t, "INSERT", 0) == Some(0) {
    return parse_insert(db, t)
  }
  if find_word(t, "SELECT", 0) == Some(0) {
    return parse_select(db, t)
  }
  if find_word(t, "UPDATE", 0) == Some(0) {
    return parse_update(db, t)
  }
  if find_word(t, "DELETE", 0) == Some(0) {
    return parse_delete(db, t)
  }
  if find_word(t, "CREATE", 0) == Some(0) {
    if find_word(t, "DATABASE", 0) != None {
      return ok_response("CREATE_DATABASE")
    }
    return err_response("UNSUPPORTED_SQL", "Unsupported SQL statement: " + t)
  }
  err_response("UNSUPPORTED_SQL", "Unsupported SQL statement: " + t)
}
