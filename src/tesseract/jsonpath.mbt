///|
/// Asking a question about the *structure* of a JSON value.
///
/// The `value` column is text, and the only way to reach a field inside it was
/// `value LIKE '%name%'` — a substring match. That cannot tell `{"name":"x"}`
/// from `{"other":"name"}`, cannot compare a number, and cannot follow a path.
///
/// Two rules decide everything here, and they are deliberately different rules:
///
/// - A **path** belongs to the statement, so a malformed path is an error. It
///   does not depend on what is stored, so the data cannot decide whether it
///   is right.
/// - A **value** belongs to the row, so a row whose text is not JSON, or whose
///   JSON has no such key, answers `null` rather than failing the query. One
///   row holding a plain string must not take the whole query down with it.

///|
/// One step of a path: an object key or an array index.
pub enum JsonStep {
  Key(String)
  Index(Int32)
}

///|
/// True for a code unit that may appear in a bare path name.
fn is_path_name_char(c : Int32) -> Bool {
  if (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) {
    true
  } else {
    c == 95 || c == 45
  }
}

///|
/// Parses `$.a.b[0].c` into steps.
///
/// The grammar is deliberately small: `$` for the root, `.name` for an object
/// key, `[n]` for an array index, and `["name"]` for a key that is not a plain
/// identifier. A larger grammar would be a second language to learn, and this
/// is the part that answers real questions about a document.
pub fn json_path_parse(path : String) -> Result[Array[JsonStep], String] {
  let n = path.length()
  if n == 0 {
    return Err("json path is empty")
  }
  if path.at(0).to_int() != 36 {
    return Err("json path must start with '$'")
  }
  let steps : Array[JsonStep] = []
  let mut i = 1
  while i < n {
    let c = path.at(i).to_int()
    if c == 46 {
      i = i + 1
      if i >= n {
        return Err("json path ends with '.'")
      }
      let start = i
      while i < n && is_path_name_char(path.at(i).to_int()) {
        i = i + 1
      }
      if i == start {
        return Err("json path has a '.' with no name after it")
      }
      steps.push(JsonStep::Key(slice(path, start, i)))
    } else if c == 91 {
      let (step, next) = match json_path_bracket(path, i) {
        Err(message) => return Err(message)
        Ok(parsed) => parsed
      }
      steps.push(step)
      i = next
    } else {
      return Err("json path has a character that is not part of a step")
    }
  }
  Ok(steps)
}

///|
/// One bracketed step, and the position just past it.
///
/// The two bracketed forms are an index and a quoted name, and they are told
/// apart by the first character after the `[`: a digit means an index, a quote
/// means a name.
fn json_path_bracket(
  path : String,
  start : Int32,
) -> Result[(JsonStep, Int32), String] {
  let n = path.length()
  let mut i = start + 1
  if i >= n {
    return Err("json path ends with '['")
  }
  let q = path.at(i).to_int()
  if q == 34 || q == 39 {
    let quote = q
    i = i + 1
    let name_start = i
    while i < n && path.at(i).to_int() != quote {
      i = i + 1
    }
    if i >= n {
      return Err("json path has an unterminated quoted name")
    }
    let name = slice(path, name_start, i)
    i = i + 1
    if i >= n || path.at(i).to_int() != 93 {
      return Err("json path has a quoted name not closed by ']'")
    }
    return Ok((JsonStep::Key(name), i + 1))
  }
  let num_start = i
  while i < n {
    let c = path.at(i).to_int()
    if c < 48 || c > 57 {
      break
    }
    i = i + 1
  }
  if i == num_start {
    return Err("json path has a '[' that is not an index or a quoted name")
  }
  if i >= n || path.at(i).to_int() != 93 {
    return Err("json path has an index not closed by ']'")
  }
  let digits = slice(path, num_start, i)
  match json_path_index(digits) {
    Some(idx) => Ok((JsonStep::Index(idx), i + 1))
    None => Err("json path has an index that is not a number")
  }
}

///|
/// The digits of an array index.
///
/// An index that does not fit is not an index: it is a name of the wrong kind,
/// and answering it as "no such element" would be indistinguishable from an
/// out-of-range index.
fn json_path_index(digits : String) -> Int32? {
  let n = digits.length()
  if n == 0 || n > 9 {
    return None
  }
  let mut acc = 0
  let mut i = 0
  while i < n {
    let c = digits.at(i).to_int()
    if c < 48 || c > 57 {
      return None
    }
    acc = acc * 10 + (c - 48)
    i = i + 1
  }
  Some(acc)
}

///|
/// Follows the steps through a document, or `None` if the path does not exist.
///
/// A step that does not fit the value it is applied to is a miss, not an error:
/// asking for `$.a.b` of a document whose `a` is a number has no answer, and
/// the honest one is `null`.
pub fn json_walk(doc : Json, steps : Array[JsonStep]) -> Json? {
  let mut cur = doc
  let mut i = 0
  while i < steps.length() {
    let found = match steps[i] {
      JsonStep::Key(k) =>
        match cur {
          Json::Object(obj) => obj.get(k)
          _ => None
        }
      JsonStep::Index(idx) =>
        match cur {
          Json::Array(a) =>
            if idx < 0 || idx >= a.length() {
              None
            } else {
              Some(a[idx])
            }
          _ => None
        }
    }
    match found {
      Some(v) => cur = v
      None => return None
    }
    i = i + 1
  }
  Some(cur)
}

///|
/// A JSON number written as a whole number, at full 64-bit width.
///
/// JSON numbers may be written `25`, `25.0`, `2.5e3` or `-3.5`. A value is a
/// whole number when it has no fractional part, however it was spelled, so
/// `25.0` is 25 and `2.5e3` is not.
///
/// The text is parsed rather than the double, because a double cannot hold a
/// 64-bit integer exactly: `9007199254740993` is one more than `2^53`, and
/// reading it as a double would change it by one without saying so.
pub fn json_whole_number(text : String) -> Int64? {
  let n = text.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  let mut negative = false
  if text.at(i).to_int() == 45 {
    negative = true
    i = i + 1
  }
  let int_start = i
  let mut acc = 0L
  let mut digits = 0
  while i < n {
    let c = text.at(i).to_int()
    if c < 48 || c > 57 {
      break
    }
    digits = digits + 1
    // Eighteen digits cannot overflow Int64; nineteen can.
    if digits > 18 {
      return None
    }
    acc = acc * 10L + (c - 48).to_int64()
    i = i + 1
  }
  if i == int_start {
    return None
  }
  if i < n && text.at(i).to_int() == 46 {
    i = i + 1
    let frac_start = i
    while i < n {
      let c = text.at(i).to_int()
      if c < 48 || c > 57 {
        break
      }
      if c != 48 {
        return None
      }
      i = i + 1
    }
    if i == frac_start {
      return None
    }
  }
  if i != n {
    return None
  }
  Some(if negative { -acc } else { acc })
}

///|
/// A JSON value as a SQL value.
///
/// `SqlValue` has no floating-point variant, so a number that is not a whole
/// number stays text — and it stays the *original* text, not a double's idea of
/// it, so `0.1` and a 19-digit integer both survive untouched.
///
/// A JSON `true` becomes 1 and `false` becomes 0, because that is how the rest
/// of this surface spells a boolean. An object or an array becomes its JSON
/// text, so it can still be compared, returned, and fed back into
/// `json_extract`.
pub fn json_to_sql(v : Json) -> SqlValue {
  match v {
    Json::Null => SqlValue::Null
    Json::True => SqlValue::Int(1L)
    Json::False => SqlValue::Int(0L)
    Json::String(s) => SqlValue::Text(s)
    Json::Number(_, repr=Some(r)) =>
      match json_whole_number(r) {
        Some(n) => SqlValue::Int(n)
        None => SqlValue::Text(r)
      }
    Json::Number(_, repr=None) => {
      let text = v.stringify()
      match json_whole_number(text) {
        Some(n) => SqlValue::Int(n)
        None => SqlValue::Text(text)
      }
    }
    Json::Array(_) => SqlValue::Text(v.stringify())
    Json::Object(_) => SqlValue::Text(v.stringify())
  }
}
