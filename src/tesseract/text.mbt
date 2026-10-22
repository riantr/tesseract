///|
/// ASCII text helpers.
///
/// The bundled `String` API in this toolchain has no case folding and no
/// integer parsing, and the SQL surface needs both. Rather than take a
/// dependency for four functions they live here. The *folding* is ASCII-only
/// on purpose: SQL keywords are ASCII, and Tesseract values are opaque JSON
/// blobs that must survive a round trip byte-for-byte — so the copying keeps
/// every character, including the ones that take two code units.

///|
/// True for the ASCII whitespace Tesseract trims around SQL tokens.
pub fn is_space(c : Int32) -> Bool {
  c == 32 || c == 9 || c == 10 || c == 13
}

///|
/// ASCII upper-cases a single code unit.
pub fn cu_upper(c : Int32) -> Int32 {
  if c >= 97 && c <= 122 {
    c - 32
  } else {
    c
  }
}

///|
/// ASCII lower-cases a single code unit.
pub fn cu_lower(c : Int32) -> Int32 {
  if c >= 65 && c <= 90 {
    c + 32
  } else {
    c
  }
}

///|
/// Appends one code unit, dropping anything outside the Char range.
fn write_cu(b : StringBuilder, c : Int32) -> Unit {
  match Int32::to_char(c) {
    Some(ch) => b.write_char(ch)
    None => ()
  }
}

///|
/// True for the first half of a surrogate pair.
fn is_high_surrogate(c : Int32) -> Bool {
  c >= 55296 && c <= 56319
}

///|
/// True for the second half of a surrogate pair.
fn is_low_surrogate(c : Int32) -> Bool {
  c >= 56320 && c <= 57343
}

///|
/// The character at `s[i]`, and the index just past it.
///
/// A character outside the basic plane is two code units in the runtime's
/// string and one character to a reader, so a walk that stops at code units
/// has to be told where the character ends. Copying the two halves apart
/// **destroys** the character: `Int32::to_char` refuses a surrogate, so half a
/// character is not a character at all, and an emoji that went through a text
/// helper used to come back as two question marks.
///
/// A half-character — one half of a pair with no other half — is not a
/// character and comes back as a question mark, which is the only thing that
/// can be done with it.
pub fn char_at(s : String, i : Int32) -> (Char, Int32) {
  let c = s.at(i).to_int()
  if is_high_surrogate(c) && i + 1 < s.length() {
    let low = s.at(i + 1).to_int()
    if is_low_surrogate(low) {
      let cp = 0x10000 + (c - 55296) * 1024 + (low - 56320)
      match Int32::to_char(cp) {
        Some(ch) => return (ch, i + 2)
        None => ()
      }
    }
  }
  match Int32::to_char(c) {
    Some(ch) => (ch, i + 1)
    None => ('?', i + 1)
  }
}

///|
/// Orders two texts by their characters.
///
/// The runtime's own `String::compare` is **not** a lexicographic order: it
/// compares the lengths first, so `"work"` sorts *before* `"default"` — the
/// shorter text wins whatever its letters say. A store that promises its keys
/// "in order", and that breaks a tie "by key", has to say which order it
/// means, and the one a reader expects is the order of the letters. So the
/// order is written out here rather than borrowed.
///
/// The comparison is by **character** and not by code unit, so a character
/// outside the basic plane is one thing to compare rather than two halves of
/// one thing. The shorter text comes first when one of them is a prefix of the
/// other, and two equal texts compare equal.
pub fn compare_text(a : String, b : String) -> Int32 {
  let mut i = 0
  let mut j = 0
  while i < a.length() && j < b.length() {
    let (ca, next_a) = char_at(a, i)
    let (cb, next_b) = char_at(b, j)
    let x = ca.to_int()
    let y = cb.to_int()
    if x != y {
      return if x < y { -1 } else { 1 }
    }
    i = next_a
    j = next_b
  }
  let left = a.length() - i
  let right = b.length() - j
  if left == right {
    0
  } else if left < right {
    -1
  } else {
    1
  }
}

///|
/// Copies `s[start, end)` into a fresh string, clamped to `s.length()`.
///
/// The range is in **code units**, the same unit it has always been, and a
/// character is copied whole or not at all: a range that holds both halves of
/// a surrogate pair keeps the character, and a range that cuts one in half
/// does not, because there is no such thing as half a character.
pub fn slice(s : String, start : Int32, end : Int32) -> String {
  let hi = if end > s.length() { s.length() } else { end }
  let b = StringBuilder::StringBuilder()
  let mut i = start
  while i < hi {
    if is_high_surrogate(s.at(i).to_int()) {
      if i + 1 < hi && is_low_surrogate(s.at(i + 1).to_int()) {
        let (ch, next) = char_at(s, i)
        b.write_char(ch)
        i = next
      } else {
        // The range cuts the character in half, so it is not included.
        i = i + 1
      }
    } else {
      let (ch, next) = char_at(s, i)
      b.write_char(ch)
      i = next
    }
  }
  b.to_string()
}

///|
/// One code unit as a `Char`; anything outside the Char range becomes `?`.
pub fn cu_char(c : Int32) -> Char {
  match Int32::to_char(c) {
    Some(ch) => ch
    None => '?'
  }
}

///|
/// ASCII upper-cases the whole string.
///
/// The folding is ASCII-only on purpose — a case rule for a character outside
/// ASCII is a much bigger question than a SQL keyword needs — but the
/// characters themselves are all kept, including the ones that take two code
/// units.
pub fn upper(s : String) -> String {
  let b = StringBuilder::StringBuilder(size_hint=s.length())
  let mut i = 0
  while i < s.length() {
    let c = s.at(i).to_int()
    if c < 128 {
      write_cu(b, cu_upper(c))
      i = i + 1
    } else {
      let (ch, next) = char_at(s, i)
      b.write_char(ch)
      i = next
    }
  }
  b.to_string()
}

///|
/// ASCII lower-case of the whole string.
///
/// The folding is ASCII-only on purpose, and the characters are all kept — see
/// `upper`.
pub fn lower(s : String) -> String {
  let b = StringBuilder::StringBuilder(size_hint=s.length())
  let mut i = 0
  while i < s.length() {
    let c = s.at(i).to_int()
    if c < 128 {
      write_cu(b, cu_lower(c))
      i = i + 1
    } else {
      let (ch, next) = char_at(s, i)
      b.write_char(ch)
      i = next
    }
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
pub fn parse_int(s : String) -> Int32? {
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
/// Parses a decimal number, or `None`.
///
/// The grammar is a plain decimal: an optional sign, digits, and an optional
/// fractional part. There is **no exponent** — `1e3` is not a number here —
/// and there is no hexadecimal, no `inf` and no `nan`. Anything the grammar
/// does not cover is `None` rather than a silent zero, for the same reason
/// `parse_int` refuses what it cannot read: a caller that typed a number
/// deserves to be told when it is not one.
///
/// A number with more than fifteen significant digits is refused rather than
/// rounded. The mantissa is accumulated as an integer and divided by the
/// scale at the end, so the digits are exact; a number too long for that is a
/// number the caller has to shorten, not one the store may quietly change.
///
/// The result is the nearest double to the decimal, which is the same number
/// every double has: `0.1` is not exactly a tenth, and that is the point of
/// using a double rather than a scaled integer.
pub fn parse_float(s : String) -> Double? {
  let t = trim_ws(s)
  let n = t.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  let mut negative = false
  let first = t.at(0).to_int()
  if first == 45 {
    negative = true
    i = 1
  } else if first == 43 {
    i = 1
  }
  if i >= n {
    return None
  }
  // The digits, as an integer, and how many of them there are.
  let mut mantissa : Int64 = 0L
  let mut digits = 0
  while i < n {
    let c = t.at(i).to_int()
    if c < 48 || c > 57 {
      break
    }
    mantissa = mantissa * 10L + (c - 48).to_int64()
    digits = digits + 1
    if digits > 15 {
      return None
    }
    i = i + 1
  }
  // The fraction, and the scale it divides by.
  let mut scale = 0
  if i < n && t.at(i).to_int() == 46 {
    i = i + 1
    let mut fraction = 0
    while i < n {
      let c = t.at(i).to_int()
      if c < 48 || c > 57 {
        break
      }
      mantissa = mantissa * 10L + (c - 48).to_int64()
      scale = scale + 1
      fraction = fraction + 1
      if digits + fraction > 15 {
        return None
      }
      i = i + 1
    }
    // A point with nothing after it is a point, not a number.
    if fraction == 0 && digits == 0 {
      return None
    }
  }
  if digits == 0 && scale == 0 {
    return None
  }
  // Anything left over is not part of the number.
  if i != n {
    return None
  }
  let mut divisor = 1.0
  let mut k = 0
  while k < scale {
    divisor = divisor * 10.0
    k = k + 1
  }
  let value = mantissa.to_double() / divisor
  if negative {
    Some(-value)
  } else {
    Some(value)
  }
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
pub fn index_of_ci(s : String, sub : String) -> Int32? {
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
pub fn pad_right(s : String, w : Int32) -> String {
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
pub fn pad_left(s : String, w : Int32) -> String {
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
pub fn ellipsize(s : String, w : Int32) -> String {
  if s.length() <= w {
    return s
  }
  if w <= 1 {
    return slice(s, 0, w)
  }
  slice(s, 0, w - 1) + "~"
}
