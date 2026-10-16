///|
/// The SQL lexer: offsets, escapes, comments, and the three ways a statement
/// can fail before the grammar starts.
///
/// The cases here are the ones the old string scanner got wrong, one for one.
/// The largest single source of them was scanning text that a quoted literal
/// owned: `SELECT * FROM tesseract WHERE key = 'x=y'` used to be cut at the
/// `=` inside the literal, and a `--` comment was data rather than a comment.
/// A lexer that decides every character once cannot do either.
///
/// Assertions are written as matches rather than as equality against a built
/// value, because this toolchain will not let a blackbox test *construct* a
/// package enum - `Ident("SELECT")` is a read-only value here, and matching it
/// is allowed. The tests read a little better for it: the pattern is the shape
/// the tokens are supposed to have.

///|
/// The tokens of a statement that lexed.
fn toks(sql : String) -> Array[@tesseract.Token] {
  match @tesseract.lex(sql) {
    Ok(t) => t
    Err(e) => abort("lex failed: " + @tesseract.lex_error_message(e))
  }
}

///|
/// The failure of a statement that did not lex.
fn lex_failure(sql : String) -> @tesseract.LexError {
  match @tesseract.lex(sql) {
    Ok(_) => abort("expected a lexical failure from: " + sql)
    Err(e) => e
  }
}

///|
fn is_ident_token(t : @tesseract.Token, text : String, at : Int32) -> Bool {
  match t.kind {
    Ident(s) => s == text && t.at == at
    _ => false
  }
}

///|
fn is_int_token(t : @tesseract.Token, value : Int64, at : Int32) -> Bool {
  match t.kind {
    IntLit(n) => n == value && t.at == at
    _ => false
  }
}

///|
fn is_text_token(t : @tesseract.Token, value : String, at : Int32) -> Bool {
  match t.kind {
    Text(s) => s == value && t.at == at
    _ => false
  }
}

///|
fn is_punct(t : @tesseract.Token, value : String, at : Int32) -> Bool {
  match t.kind {
    Punct(s) => s == value && t.at == at
    _ => false
  }
}

///|
fn is_eof(t : @tesseract.Token, at : Int32) -> Bool {
  match t.kind {
    Eof => t.at == at
    _ => false
  }
}

///|
fn is_unterminated(e : @tesseract.LexError, at : Int32) -> Bool {
  match e {
    UnterminatedString(a) => a == at
    _ => false
  }
}

///|
fn is_unexpected(
  e : @tesseract.LexError,
  at : Int32,
  code_point : Int32,
) -> Bool {
  match e {
    UnexpectedChar(a, cp) => a == at && cp == code_point
    _ => false
  }
}

///|
fn is_bad_number(e : @tesseract.LexError, at : Int32) -> Bool {
  match e {
    BadNumber(a) => a == at
    _ => false
  }
}

///|
test "a token carries the offset it starts at" {
  let t = toks("SELECT a FROM tesseract")
  assert_eq(t.length(), 5)
  assert_true(is_ident_token(t[0], "SELECT", 0))
  assert_true(is_ident_token(t[1], "a", 7))
  assert_true(is_ident_token(t[2], "FROM", 9))
  assert_true(is_ident_token(t[3], "tesseract", 14))
  assert_true(is_eof(t[4], 23))
}

///|
test "keywords lex as identifiers and keep their case" {
  let t = toks("SeLeCt")
  assert_true(is_ident_token(t[0], "SeLeCt", 0))
  // `_` starts an identifier, so a column called `_pos2` is one token and not an
  // identifier followed by a stray `_`.
  let u = toks("_pos2")
  assert_true(is_ident_token(u[0], "_pos2", 0))
}

///|
test "a two-character punctuator is one token, a lone angle bracket is not" {
  let two = toks("a<>b")
  assert_true(is_punct(two[1], "<>", 1))
  let le = toks("a<=b")
  assert_true(is_punct(le[1], "<=", 1))
  let ne = toks("a!=b")
  assert_true(is_punct(ne[1], "!=", 1))
  let ge = toks("a>=b")
  assert_true(is_punct(ge[1], ">=", 1))
  // A `<` with nothing to make a two-character operator out of stays alone.
  // Splitting `<=` into `<` `=` would parse as two operators and accept
  // statements that mean something else.
  let lone = toks("a<b")
  assert_true(is_punct(lone[1], "<", 1))
  assert_true(is_ident_token(lone[2], "b", 2))
  let eq = toks("a=b")
  assert_true(is_punct(eq[1], "=", 1))
}

///|
test "both spellings of an embedded quote unescape to one apostrophe" {
  // Standard SQL doubles the quote; this dialect's exporter backslash-escapes
  // it. A dump written by either has to read back through the same lexer.
  let doubled = toks("'it''s'")
  assert_true(is_text_token(doubled[0], "it's", 0))
  assert_true(is_eof(doubled[1], 7))
  let backslashed = toks("'it\\'s'")
  assert_true(is_text_token(backslashed[0], "it's", 0))
  assert_true(is_eof(backslashed[1], 7))
  // An operator inside a literal is content. The old parser searched for the
  // first `=` in the raw text and cut here.
  let eq = toks("'x=y'")
  assert_true(is_text_token(eq[0], "x=y", 0))
  assert_eq(eq.length(), 2)
}

///|
test "control-character escapes come back as the control characters" {
  let t = toks("'a\\nb'")
  assert_true(is_text_token(t[0], "a\nb", 0))
  // `\\` is a backslash, which is what `serialize.mbt` writes for one.
  let bs = toks("'a\\\\b'")
  assert_true(is_text_token(bs[0], "a\\b", 0))
}

///|
test "comments are skipped and a block comment may span lines" {
  let t = toks("-- a comment\nSELECT /* two\nlines */ 1")
  assert_eq(t.length(), 3)
  assert_true(is_ident_token(t[0], "SELECT", 13))
  assert_true(is_int_token(t[1], 1L, 36))
  assert_true(is_eof(t[2], 37))
  // A line comment runs to the end of the line, not to the end of the input,
  // and a block comment ends at its own `*/`.
  let two = toks("-- x\ny /* z */ w")
  assert_true(is_ident_token(two[0], "y", 5))
  assert_true(is_ident_token(two[1], "w", 15))
}

///|
test "an unterminated literal is reported at its opening quote" {
  // The offset is the quote, not the end of the input: a caller has to find
  // where the literal started to fix it.
  assert_true(is_unterminated(lex_failure("SELECT 'abc"), 7))
  // A trailing backslash cannot escape anything, so it cannot close the
  // literal either - and it is reported as the unterminated literal it is.
  assert_true(is_unterminated(lex_failure("SELECT 'abc\\"), 7))
}

///|
test "an unclosed block comment is reported at the slash that opened it" {
  // `UnexpectedChar` rather than `UnterminatedString`: that variant names a
  // quote, and the character at this offset is not the problem. 47 is `/`.
  assert_true(is_unexpected(lex_failure("SELECT /* x"), 7, 47))
}

///|
test "digits that run into an identifier are not two tokens" {
  // `12abc` read as the integer 12 followed by the column `abc` is a
  // well-formed statement about something nobody wrote.
  assert_true(is_bad_number(lex_failure("12abc"), 2))
  // The `x` after `3` is at offset 11, not where the number started.
  assert_true(is_bad_number(lex_failure("WHERE x = 3x"), 11))
  // A plain integer is fine, including zero.
  let t = toks("0 12")
  assert_true(is_int_token(t[0], 0L, 0))
  assert_true(is_int_token(t[1], 12L, 2))
}

///|
test "an integer too large for Int64 is refused, not wrapped" {
  // Wrapping would name a cell the writer never asked about.
  assert_true(is_bad_number(lex_failure("99999999999999999999"), 0))
  // The largest literal that does fit still parses.
  let t = toks("9223372036854775807")
  assert_true(is_int_token(t[0], 9223372036854775807L, 0))
}

///|
test "a stray character is named rather than numbered" {
  // A backslash outside a literal is not an escape, so it is a character with
  // nowhere to go.
  assert_true(is_unexpected(lex_failure("a\\b"), 1, 92))
  assert_true(is_unexpected(lex_failure("key = ?"), 6, 63))
  // A non-ASCII character is refused rather than skipped: the offsets in this
  // file are positions in an ASCII grammar, and quietly dropping a byte would
  // make every offset after it wrong.
  assert_true(is_unexpected(lex_failure("a é"), 2, 233))
}

///|
test "the stream always ends with one Eof" {
  let empty = toks("")
  assert_eq(empty.length(), 1)
  assert_true(is_eof(empty[0], 0))
  let ws = toks("   \n\t ")
  assert_eq(ws.length(), 1)
  assert_true(is_eof(ws[0], 6))
}

///|
test "a lexical failure reads as a sentence naming what was found" {
  // A code point on its own tells a reader nothing about which character their
  // statement has in it.
  let msg = @tesseract.lex_error_message(lex_failure("a?"))
  assert_true(msg.contains("code point 63"))
  assert_true(msg.contains("offset 1"))
  let open = @tesseract.lex_error_message(lex_failure("'x"))
  assert_true(open.contains("Unterminated"))
  let num = @tesseract.lex_error_message(lex_failure("12abc"))
  assert_true(num.contains("Malformed"))
}
