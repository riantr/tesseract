///|
/// ASCII text helpers.
///
/// The bundled `String` API in this toolchain has no case folding and no
/// integer parsing, and the SQL surface needs both. Rather than take a
/// dependency for four functions they live here. ASCII-only on purpose: SQL
/// keywords are ASCII, and SudokuDB values are opaque JSON blobs that must
/// survive a round trip byte-for-byte.

///|
/// True for the ASCII whitespace SudokuDB trims around SQL tokens.
pub fn is_space(c : Int) -> Bool {
  c == 32 || c == 9 || c == 10 || c == 13
}

///|
/// ASCII upper-cases a single code unit.
pub fn cu_upper(c : Int) -> Int {
  if c >= 97 && c <= 122 {
    c - 32
  } else {
    c
  }
}

///|
/// ASCII lower-cases a single code unit.
pub fn cu_lower(c : Int) -> Int {
  if c >= 65 && c <= 90 {
    c + 32
  } else {
    c
  }
}

///|
/// Appends one code unit, dropping anything outside the Char range.
fn write_cu(b : StringBuilder, c : Int) -> Unit {
  match Int::to_char(c) {
    Some(ch) => b.write_char(ch)
    None => ()
  }
}

///|
/// Copies `s[start, end)` into a fresh string, clamped to `s.length()`.
pub fn slice(s : String, start : Int, end : Int) -> String {
  let hi = if end > s.length() { s.length() } else { end }
  let b = StringBuilder::StringBuilder()
  let mut i = start
  while i < hi {
    write_cu(b, s.at(i).to_int())
    i = i + 1
  }
  b.to_string()
}

///|
/// One code unit as a `Char`; anything outside the Char range becomes `?`.
pub fn cu_char(c : Int) -> Char {
  match Int::to_char(c) {
    Some(ch) => ch
    None => '?'
  }
}

///|
/// ASCII upper-cases the whole string.
pub fn upper(s : String) -> String {
  let b = StringBuilder::StringBuilder(size_hint=s.length())
  let mut i = 0
  while i < s.length() {
    write_cu(b, cu_upper(s.at(i).to_int()))
    i = i + 1
  }
  b.to_string()
}

///|
/// ASCII lower-case of the whole string.
pub fn lower(s : String) -> String {
  let b = StringBuilder::StringBuilder(size_hint=s.length())
  let mut i = 0
  while i < s.length() {
    write_cu(b, cu_lower(s.at(i).to_int()))
    i = i + 1
  }
  b.to_string()
}

///|
/// Strips ASCII whitespace from both ends.
pub fn trim_ws(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end && is_space(s.at(start).to_int()) {
    start = start + 1
  }
  while end > start && is_space(s.at(end - 1).to_int()) {
    end = end - 1
  }
  slice(s, start, end)
}

///|
/// Parses a decimal integer with an optional sign.
///
/// Returns `None` for empty or non-digit input rather than a silent 0 — the SQL
/// layer needs to tell "grid_position = abc" apart from "grid_position = 0".
pub fn parse_int(s : String) -> Int? {
  let t = trim_ws(s)
  if t.length() == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  let c0 = t.at(0).to_int()
  if c0 == 45 {
    neg = true
    i = 1
  } else if c0 == 43 {
    i = 1
  }
  if i >= t.length() {
    return None
  }
  let mut acc = 0
  let mut digits = 0
  while i < t.length() {
    let c = t.at(i).to_int()
    if c < 48 || c > 57 {
      return None
    }
    acc = acc * 10 + (c - 48)
    digits = digits + 1
    i = i + 1
  }
  if digits == 0 {
    return None
  }
  Some(if neg { -acc } else { acc })
}

///|
/// ASCII case-insensitive equality.
pub fn eq_ci(a : String, b : String) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    if cu_lower(a.at(i).to_int()) != cu_lower(b.at(i).to_int()) {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// Exact ASCII prefix test.
pub fn starts_with(s : String, p : String) -> Bool {
  if p.length() > s.length() {
    return false
  }
  let mut i = 0
  while i < p.length() {
    if s.at(i) != p.at(i) {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// ASCII case-insensitive prefix test.
pub fn starts_ci(s : String, p : String) -> Bool {
  if p.length() > s.length() {
    return false
  }
  let mut i = 0
  while i < p.length() {
    if cu_lower(s.at(i).to_int()) != cu_lower(p.at(i).to_int()) {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// Index of the first ASCII case-insensitive occurrence of `sub`, or `None`.
pub fn index_of_ci(s : String, sub : String) -> Int? {
  let n = sub.length()
  if n == 0 {
    return Some(0)
  }
  if n > s.length() {
    return None
  }
  let last = s.length() - n
  let mut i = 0
  while i <= last {
    let mut j = 0
    let mut hit = true
    while j < n {
      if cu_lower(s.at(i + j).to_int()) != cu_lower(sub.at(j).to_int()) {
        hit = false
        break
      }
      j = j + 1
    }
    if hit {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
/// ASCII case-insensitive substring test.
pub fn contains_ci(s : String, sub : String) -> Bool {
  match index_of_ci(s, sub) {
    Some(_) => true
    None => false
  }
}

///|
/// Splits on a literal separator, keeping empty fields.
pub fn split(s : String, sep : String) -> Array[String] {
  let out : Array[String] = []
  let n = sep.length()
  if n == 0 {
    out.push(s)
    return out
  }
  let mut start = 0
  let mut i = 0
  let limit = s.length() - n
  while i <= limit {
    let mut j = 0
    let mut hit = true
    while j < n {
      if s.at(i + j) != sep.at(j) {
        hit = false
        break
      }
      j = j + 1
    }
    if hit {
      out.push(slice(s, start, i))
      i = i + n
      start = i
    } else {
      i = i + 1
    }
  }
  out.push(slice(s, start, s.length()))
  out
}

///|
/// Joins parts with a separator.
pub fn join(parts : Array[String], sep : String) -> String {
  let b = StringBuilder::StringBuilder()
  let mut i = 0
  while i < parts.length() {
    if i > 0 {
      b.write_string(sep)
    }
    b.write_string(parts[i])
    i = i + 1
  }
  b.to_string()
}

///|
/// Right-pads with spaces to `w`, for table rendering.
pub fn pad_right(s : String, w : Int) -> String {
  let b = StringBuilder::StringBuilder(size_hint=w)
  b.write_string(s)
  let mut i = s.length()
  while i < w {
    b.write_char(' ')
    i = i + 1
  }
  b.to_string()
}

///|
/// Left-pads with spaces to `w`, for table rendering.
pub fn pad_left(s : String, w : Int) -> String {
  let b = StringBuilder::StringBuilder(size_hint=w)
  let mut i = s.length()
  while i < w {
    b.write_char(' ')
    i = i + 1
  }
  b.write_string(s)
  b.to_string()
}

///|
/// Shortens to `w` columns with a trailing `~` when it has to cut.
pub fn ellipsize(s : String, w : Int) -> String {
  if s.length() <= w {
    return s
  }
  if w <= 1 {
    return slice(s, 0, w)
  }
  slice(s, 0, w - 1) + "~"
}
