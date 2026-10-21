///|
/// The SQL lexer: source text to a token stream, with offsets.
///
/// This replaces the string scanning that `sql.mbt` did inline. The measured
/// reason is in `parser.mbt`'s header, but the part that belongs here is this:
/// every scan decision is made once, from the outside in, so a character inside
/// a quoted literal can never be mistaken for an operator. The old layer searched
/// for the first `=` in the raw text, which cut `WHERE key = 'x=y'` in the wrong
/// place.
///
/// Offsets are positions into the source string, so a `ParseError` can point at
/// the character a human has to move. They are exact for ASCII, and ASCII is all
/// the grammar admits: keywords are ASCII, and a Tesseract value is always
/// quoted rather than scanned as text. A non-ASCII character is reported as
/// `UnexpectedChar` rather than quietly skipped, which is what keeps the
/// ASCII-only assumption from turning into a silent truncation.
///
/// Keyword recognition is deliberately absent. The lexer emits `Ident` and lets
/// the parser compare case-insensitively, so `Tesseract` in a table name and
/// `key` in a column are the same token kind and only the position in the
/// statement decides what they mean.

///|
/// One lexical token.
///
/// `Ident` carries keywords too: `SELECT` is an identifier as far as this file is
/// concerned. Splitting them here would need a keyword table that then has to
/// stay in step with the grammar in `parser.mbt`, and the only thing it buys is
/// an earlier error message.
pub enum TokenKind {
  Ident(String)
  IntLit(Int64)
  Text(String)
  Punct(String)
  Eof
} derive(Eq, Debug)

///|
pub extend TokenKind with Eq::{equal, not_equal}

///|
pub extend TokenKind with @debug.Debug::{to_repr}

///|
/// A token and where it started.
///
/// The offset is kept per token rather than recovered from the token text, so an
/// error in the middle of a long statement points at the offending token instead
/// of at the start of the statement.
pub struct Token {
  kind : TokenKind
  at : Int32
} derive(Eq, Debug)

///|
pub extend Token with Eq::{equal, not_equal}

///|
pub extend Token with @debug.Debug::{to_repr}

///|
/// The three ways a statement can fail before the grammar even starts.
///
/// Offsets are the same as `Token.at`: the opening quote for an unterminated
/// literal, the first character that cannot continue a token for the other two.
pub enum LexError {
  UnterminatedString(Int32)
  UnexpectedChar(Int32, Int32)
  BadNumber(Int32)
} derive(Eq, Debug)

///|
pub extend LexError with Eq::{equal, not_equal}

///|
pub extend LexError with @debug.Debug::{to_repr}

///|
/// A human-readable rendering of a lexical failure.
///
/// The code point is named rather than numbered. `Unexpected 35` tells a reader
/// nothing about which character their statement has in it, and the offset alone
/// is not enough to find a character they cannot see - an unpaired surrogate or
/// an invisible control character both land on a number.
pub fn lex_error_message(e : LexError) -> String {
  match e {
    UnterminatedString(at) =>
      "Unterminated string literal at offset " + at.to_string()
    UnexpectedChar(at, cp) =>
      "Unexpected character `" +
      cu_char(cp).to_string() +
      "` (code point " +
      cp.to_string() +
      ") at offset " +
      at.to_string()
    BadNumber(at) => "Malformed integer literal at offset " + at.to_string()
  }
}

///|
/// The code point at `i`, as an `Int32` the character helpers can classify.
fn cu_at(s : String, i : Int32) -> Int32 {
  s.at(i).to_int()
}

///|
/// True for the ASCII letter or underscore that starts an identifier.
fn is_ident_start(c : Int32) -> Bool {
  (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
}

///|
/// True for an ASCII letter, digit or underscore.
fn is_ident_char(c : Int32) -> Bool {
  is_ident_start(c) || (c >= 48 && c <= 57)
}

///|
/// True for an ASCII decimal digit.
fn is_digit(c : Int32) -> Bool {
  c >= 48 && c <= 57
}

///|
/// The one-character punctuators.
fn punct1_of(c : Int32) -> String? {
  match cu_char(c) {
    '(' => Some("(")
    ')' => Some(")")
    ',' => Some(",")
    ';' => Some(";")
    '*' => Some("*")
    '=' => Some("=")
    '<' => Some("<")
    '>' => Some(">")
    '+' => Some("+")
    '-' => Some("-")
    '/' => Some("/")
    '%' => Some("%")
    '@' => Some("@")
    _ => None
  }
}

///|
/// The two-character punctuators, or `None`.
///
/// `<` and `>` are tested before the one-character table, so `a <= b` is one
/// token and a `<` followed by an unrelated character stays a lone `<`. Getting
/// this backwards is not cosmetic: `<=` split into `<` `=` would parse as two
/// operators and accept statements with no meaning.
fn punct2_of(a : Int32, b : Int32) -> String? {
  let x = cu_char(a)
  let y = cu_char(b)
  if x == '<' && y == '>' {
    Some("<>")
  } else if x == '<' && y == '=' {
    Some("<=")
  } else if x == '>' && y == '=' {
    Some(">=")
  } else if x == '!' && y == '=' {
    Some("!=")
  } else {
    None
  }
}

///|
/// Reads the escape after the backslash at `i`.
///
/// The scheme is `serialize.mbt`'s `escape_sql_literal`, reversed: `\n`, `\r`,
/// `\t` and `\\` come back as themselves, and any other `\X` yields `X` - the
/// generic rule the C# parser used. The two spellings of an embedded quote,
/// `\'` and `''`, both produce `'`, and a dump written by either engine has to
/// read back through this.
///
/// The text is a string and not a character because a character outside the
/// basic plane is two code units and one character: an escape may name one,
/// and half of it is not a character.
fn read_escape(s : String, i : Int32) -> (String, Int32) {
  let c = cu_at(s, i + 1)
  if c == 110 {
    ("\n", i + 2)
  } else if c == 114 {
    ("\r", i + 2)
  } else if c == 116 {
    ("\t", i + 2)
  } else {
    let (ch, next) = char_at(s, i + 1)
    (ch.to_string(), next)
  }
}

///|
/// Scans the single-quoted literal that opens at `open`, returning its unescaped
/// text and the offset just past the closing quote.
///
/// A character outside the basic plane is two code units and one character,
/// and the literal is a value: it has to come out the way it went in, so the
/// pair is copied whole. Copying the halves apart turned every emoji in a
/// literal into two question marks.
fn scan_text(s : String, open : Int32) -> Result[(String, Int32), LexError] {
  let b = StringBuilder::StringBuilder()
  let mut i = open + 1
  while i < s.length() {
    let c = cu_at(s, i)
    // A backslash is the last character in the statement: the literal opened and
    // never closed, so this is the same failure as running out of input inside
    // the literal and is reported at the opening quote, not here.
    if c == 92 && i + 1 >= s.length() {
      return Err(UnterminatedString(open))
    }
    if c == 92 {
      let (text, next) = read_escape(s, i)
      b.write_string(text)
      i = next
      continue
    }
    if c == 39 {
      // Two quotes in a row are one escaped quote. A lone quote closes the
      // literal, which is what makes `'it''s'` one token and not two.
      if i + 1 < s.length() && cu_at(s, i + 1) == 39 {
        b.write_char('\'')
        i = i + 2
        continue
      }
      return Ok((b.to_string(), i + 1))
    }
    let (ch, next) = char_at(s, i)
    b.write_char(ch)
    i = next
  }
  Err(UnterminatedString(open))
}

///|
/// Skips `-- ...` up to the end of the line, returning the offset of the
/// newline that ended it (or the end of the source).
fn skip_line_comment(s : String, from : Int32) -> Int32 {
  let mut i = from + 2
  while i < s.length() {
    let c = cu_at(s, i)
    if c == 10 || c == 13 {
      break
    }
    i = i + 1
  }
  i
}

///|
/// Skips the block comment that opens at `open`, returning the offset just past
/// its `*/`.
///
/// An unclosed block comment is reported as `UnexpectedChar` at the `/`, with 47
/// (`/`) as the code point. It is not `UnterminatedString`: that variant names a
/// quote, and reusing it here would report an offset at a character that is not
/// the problem. There is no third variant for it because there is no third way
/// to be unterminated - a comment that never closes is a stray slash, and the
/// offset says where.
fn skip_block_comment(s : String, open : Int32) -> Result[Int32, LexError] {
  let mut i = open + 2
  while i + 1 < s.length() {
    if cu_at(s, i) == 42 && cu_at(s, i + 1) == 47 {
      return Ok(i + 2)
    }
    i = i + 1
  }
  Err(UnexpectedChar(open, 47))
}

///|
/// The largest literal that fits an `Int64`; one past it is reported rather than
/// wrapped.
const INT64_MAX : Int64 = 9223372036854775807L

///|
/// Scans the digits that start at `i` into an integer literal.
///
/// `12abc` is the case this exists for. Read as two tokens it would be the
/// integer 12 compared against the column `abc` - a well-formed statement about
/// something the writer did not write. So a digit run that runs straight into an
/// identifier is refused at the first character that does not belong to it.
fn scan_int(s : String, i : Int32) -> Result[(Int64, Int32), LexError] {
  let mut j = i
  let mut acc = 0L
  let mut overflow = false
  while j < s.length() && is_digit(cu_at(s, j)) {
    let d = (cu_at(s, j) - 48).to_int64()
    if acc > (INT64_MAX - d) / 10L {
      overflow = true
    } else {
      acc = acc * 10L + d
    }
    j = j + 1
  }
  if j < s.length() && is_ident_start(cu_at(s, j)) {
    return Err(BadNumber(j))
  }
  // A literal too large for `Int64` is the same refusal at the start of the
  // number rather than a wrapped value, which would name a cell the writer never
  // asked about.
  if overflow {
    return Err(BadNumber(i))
  }
  Ok((acc, j))
}

///|
/// Splits `sql` into tokens, always ending with one `Eof`.
///
/// The trailing `Eof` is what lets the parser ask "am I at the end?" by asking
/// "what is the current token?" - without it, every clause boundary in the
/// grammar would need a separate check for having run out of input.
pub fn lex(sql : String) -> Result[Array[Token], LexError] {
  let out : Array[Token] = []
  let mut i = 0
  while i < sql.length() {
    let c = cu_at(sql, i)
    if is_space(c) {
      i = i + 1
      continue
    }
    if c == 45 && i + 1 < sql.length() && cu_at(sql, i + 1) == 45 {
      i = skip_line_comment(sql, i)
      continue
    }
    if c == 47 && i + 1 < sql.length() && cu_at(sql, i + 1) == 42 {
      match skip_block_comment(sql, i) {
        Ok(next) => i = next
        Err(e) => return Err(e)
      }
      continue
    }
    if is_ident_start(c) {
      let mut j = i
      while j < sql.length() && is_ident_char(cu_at(sql, j)) {
        j = j + 1
      }
      out.push({ kind: Ident(slice(sql, i, j)), at: i, })
      i = j
      continue
    }
    // The C# exporter quoted identifiers with backticks - `` `key` ``, `` `value` `` -
    // and its SQL dumps are documented as still loading here. A backtick is not
    // punctuation and not a character anything else could start, so it is read as
    // a quoted identifier rather than as an error: the dialect is a compatibility
    // promise this package has made since the port, and a lexer that rejected it
    // would break every dump written by the original.
    if c == 96 {
      let mut j = i + 1
      let body = StringBuilder::StringBuilder()
      let mut closed = false
      while j < sql.length() {
        if cu_at(sql, j) == 96 {
          closed = true
          break
        }
        // A character outside the basic plane is two code units and one
        // character, so the pair is copied whole.
        let (ch, next) = char_at(sql, j)
        body.write_char(ch)
        j = next
      }
      if !closed {
        return Err(UnterminatedString(i))
      }
      out.push({ kind: Ident(body.to_string()), at: i, })
      i = j + 1
      continue
    }
    if is_digit(c) {
      match scan_int(sql, i) {
        Ok((value, next)) => {
          out.push({ kind: IntLit(value), at: i, })
          i = next
        }
        Err(e) => return Err(e)
      }
      continue
    }
    if c == 39 {
      match scan_text(sql, i) {
        Ok((value, next)) => {
          out.push({ kind: Text(value), at: i, })
          i = next
        }
        Err(e) => return Err(e)
      }
      continue
    }
    if i + 1 < sql.length() {
      match punct2_of(c, cu_at(sql, i + 1)) {
        Some(op) => {
          out.push({ kind: Punct(op), at: i, })
          i = i + 2
          continue
        }
        None => ()
      }
    }
    match punct1_of(c) {
      Some(op) => {
        out.push({ kind: Punct(op), at: i, })
        i = i + 1
      }
      None => return Err(UnexpectedChar(i, c))
    }
  }
  out.push({ kind: Eof, at: sql.length(), })
  Ok(out)
}
