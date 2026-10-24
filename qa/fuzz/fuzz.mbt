///|
/// A generator, and the corpus it draws from.
///
/// The generator is **seeded**, because a fuzz that cannot be repeated is a
/// rumour. Every seed in this file is a constant, so a failure is a failure
/// somebody can see again by running the same line.
///
/// The corpus is three things mixed together, because each of them finds a
/// different kind of mistake:
///
/// - **token soup** — words from the SQL vocabulary in a random order. The
///   grammar has to reject nearly all of it, and the interesting failures are
///   the ones it accepts.
/// - **mutated statements** — a real statement with one character ruined.
///   These find the boundaries: the last character of a number, the closing
///   quote of a string, the bracket of a function call.
/// - **raw characters** — punctuation, quotes, control characters and
///   characters outside ASCII, which is where a lexer that assumes ASCII
///   falls over.

///|
/// A xorshift64* generator.
///
/// The seed is a value, not a call, for the reason the memory's clock is a
/// value: a test that reads an entropy source cannot assert that something
/// has not happened yet.
pub struct Rng {
  mut state : Int64
}

///|
/// A generator on a seed. A seed of zero is replaced, because zero is the one
/// state xorshift cannot leave.
pub fn Rng::seed(value : Int64) -> Rng {
  { state: if value == 0L { 88172645463325252L } else { value } }
}

///|
/// The next number.
pub fn Rng::next(self : Rng) -> Int64 {
  let mut x = self.state
  x = x ^ (x >> 12)
  x = x ^ (x << 25)
  x = x ^ (x >> 27)
  self.state = x
  x * 88172645463325252L
}

///|
/// A number in `0..n`.
pub fn Rng::below(self : Rng, n : Int) -> Int {
  let v = self.next() % n.to_int64()
  if v < 0L { (-v).to_int() } else { v.to_int() }
}

///|
/// One of `items`.
pub fn Rng::pick(self : Rng, items : Array[String]) -> String {
  items[self.below(items.length())]
}

///|
/// The words the SQL vocabulary is made of.
pub let vocabulary : Array[String] = [
  "SELECT", "INSERT", "INTO", "UPDATE", "DELETE", "CREATE", "DROP", "TABLE",
  "tesseract", "WHERE", "SET", "VALUES", "KEY", "VALUE", "DIGIT", "POSITION",
  "AND", "OR", "NOT", "NULL", "IS", "LIKE", "BETWEEN", "IN", "EXISTS",
  "LIMIT", "OFFSET", "ORDER", "BY", "GROUP", "HAVING", "ASC", "DESC",
  "AT", "COORDS", "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE",
  "TO", "TRUE", "FALSE", "json_extract", "count", "sum", "min", "max", "avg",
  "line", "slab", "peers", "left", "right", "structure", "json",
  "'a'", "'b'", "'k'", "0", "1", "2", "3", "42", "-1", "1.5", "x",
  "=", "==", "!=", "<", ">", "<=", ">=", "+", "-", "*", "/", "%",
  "(", ")", ",", ";", ".", "?", ":", "'", "\"", "`", " ",
]

///|
/// The statements the mutations are made from. Each one is a statement the
/// dialect serves, so a ruined one is a statement that is *nearly* right.
pub let templates : Array[String] = [
  "SELECT * FROM tesseract;",
  "SELECT * FROM tesseract WHERE key = 'a';",
  "SELECT key, value FROM tesseract WHERE digit = 1 ORDER BY key DESC;",
  "SELECT count(*) FROM tesseract;",
  "SELECT json_extract(value, '$.a') FROM tesseract;",
  "INSERT INTO tesseract (key,value) VALUES ('k','v') AT 1;",
  "INSERT INTO tesseract (key,value,digit) VALUES ('k','v',2) AT (1,2,3,4);",
  "UPDATE tesseract SET value = 'x' WHERE key = 'k';",
  "DELETE FROM tesseract WHERE key = 'k';",
  "BEGIN;",
  "COMMIT;",
  "ROLLBACK;",
  "SAVEPOINT s1;",
  "ROLLBACK TO s1;",
  "RELEASE s1;",
  "CREATE DATABASE t;",
]

///|
/// The characters a mutation likes to use.
pub let nasty : Array[String] = [
  "'", "\"", "`", ";", ",", "(", ")", "*", "-", "/", "%", "=", "<", ">", ".",
  "?", ":", "!", "&", "|", "^", "~", "$", "@", "#", "\\", "{", "}", "[", "]",
  "\n", "\t", "\r", " ", "0", "9", "x", "SELECT", "FROM", "苹果", "🍎",
  " ", " ", "﻿",
]

///|
/// A statement made of random words.
pub fn token_soup(rng : Rng) -> String {
  let n = 1 + rng.below(16)
  let parts : Array[String] = []
  let mut i = 0
  while i < n {
    parts.push(rng.pick(vocabulary))
    i = i + 1
  }
  @tesseract.join(parts, " ")
}

///|
/// A real statement with one thing ruined.
///
/// Four kinds of ruin, because they find different things: a character
/// replaced, a character removed, a character doubled, and the statement cut
/// short.
pub fn mutated(rng : Rng) -> String {
  let template = rng.pick(templates)
  let chars = template.to_array()
  if chars.length() == 0 {
    return rng.pick(vocabulary)
  }
  let at = rng.below(chars.length())
  let kind = rng.below(4)
  let parts : Array[String] = []
  let mut i = 0
  while i < chars.length() {
    if i == at {
      match kind {
        0 => parts.push(rng.pick(nasty))
        1 => ()
        2 => {
          parts.push(chars[i].to_string())
          parts.push(rng.pick(nasty))
        }
        _ => ()
      }
    } else {
      parts.push(chars[i].to_string())
    }
    i = i + 1
  }
  if kind == 3 {
    let cut = at + 1
    let kept : Array[String] = []
    let mut j = 0
    while j < cut && j < parts.length() {
      kept.push(parts[j])
      j = j + 1
    }
    return @tesseract.join(kept, "")
  }
  @tesseract.join(parts, "")
}

///|
/// Random characters, with no structure at all.
pub fn noise(rng : Rng) -> String {
  let n = rng.below(60)
  let parts : Array[String] = []
  let mut i = 0
  while i < n {
    parts.push(rng.pick(nasty))
    i = i + 1
  }
  @tesseract.join(parts, "")
}

///|
/// The next statement from the corpus, whichever kind it is.
pub fn next_statement(rng : Rng) -> String {
  match rng.below(3) {
    0 => token_soup(rng)
    1 => mutated(rng)
    _ => noise(rng)
  }
}
