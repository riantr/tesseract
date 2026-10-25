///|
/// The properties the fuzz holds the package to.
///
/// Every property here is a claim the package already makes, written down
/// somewhere a person can read it, and checked here against inputs nobody
/// wrote by hand:
///
/// - the **error vocabulary is closed** — the README says the twelve codes
///   are "the complete set this port emits ... and nothing outside it is
///   produced". A fuzz is how that claim gets tested rather than asserted.
/// - the **parser is deterministic** — the same text gives the same answer.
///   A parser with hidden state would break this, and a caller could not
///   reproduce a failure.
/// - the **lexer and the parser agree** — a statement the lexer rejects is a
///   syntax error, and not some other code a caller would have to know about.
/// - the **store stays consistent** — arbitrary statements do not leave the
///   store answering a different question than the one it was asked.

///|
/// The error codes this port is allowed to produce. The list is the README's,
/// and a code outside it is a bug in the port or a bug in the list.
let allowed_codes : Array[String] = [
  "INVALID_INPUT", "INVALID_DIGIT", "INVALID_POSITION", "INVALID_COLUMNS", "INVALID_SYNTAX",
  "KEY_NOT_FOUND", "POSITION_NOT_FOUND", "POSITION_EMPTY", "POSITION_OUT_OF_RANGE",
  "SUDOKU_CONFLICT", "UNSUPPORTED_SQL", "EMPTY_SQL",
]

///|
/// The codes the parser itself produces. The executor adds the rest.
let parser_codes : Array[String] = [
  "INVALID_SYNTAX", "EMPTY_SQL", "UNSUPPORTED_SQL", "INVALID_COLUMNS",
]

///|
/// How many statements one run of the fuzz draws.
const ROUNDS : Int32 = 3000

///|
/// A store with nothing in it.
fn fresh() -> @tesseract.Tesseract {
  @tesseract.new_db(
    "fuzz",
    @tesseract.default_lattice(),
    @tesseract.new_logger("fuzz"),
  )
}

///|
/// The error vocabulary is closed.
///
/// The README promises the twelve codes are all of them. Every statement the
/// fuzz produces is executed, and every code that comes back has to be one of
/// them — including the codes that come from the *executor*, which is where a
/// new code would most likely appear.
test "the error vocabulary stays closed" {
  let rng = @tesseract_qa_fuzz.Rng::seed(20261024L)
  let mut i = 0
  while i < ROUNDS {
    let sql = @tesseract_qa_fuzz.next_statement(rng)
    let db = fresh()
    let r = @tesseract.execute(db, sql)
    if !r.success {
      if !allowed_codes.contains(r.error_code) {
        // The assertion carries the offending code, so a failure says which
        // one it was rather than just that it was wrong.
        assert_eq(r.error_code, "<one of the twelve documented codes>")
      }
    }
    i = i + 1
  }
}

///|
/// The parser's own codes are closed too.
///
/// The parser is a layer above the executor, and it has a smaller
/// vocabulary: four codes. A parser that invented a fifth would be a caller
/// with a code to learn that the README does not mention.
test "the parser's own error codes stay closed" {
  let rng = @tesseract_qa_fuzz.Rng::seed(20261025L)
  let mut i = 0
  while i < ROUNDS {
    let sql = @tesseract_qa_fuzz.next_statement(rng)
    match @tesseract.parse_statement(sql) {
      Ok(_) => ()
      Err(e) =>
        if !parser_codes.contains(e.code) {
          assert_eq(e.code, "<one of the four parser codes>")
        }
    }
    i = i + 1
  }
}

///|
/// The parser is deterministic.
///
/// The same text gives the same answer, every time. A parser that remembered
/// anything between calls would make a failure unreproducible, and a caller
/// could not file a bug about it.
test "the parser is deterministic" {
  let rng = @tesseract_qa_fuzz.Rng::seed(20261026L)
  let mut i = 0
  while i < ROUNDS {
    let sql = @tesseract_qa_fuzz.next_statement(rng)
    let first = @tesseract.parse_statement(sql)
    let second = @tesseract.parse_statement(sql)
    match (first, second) {
      (Ok(a), Ok(b)) => assert_eq(a, b)
      (Err(a), Err(b)) => assert_eq(a, b)
      _ => assert_true(false)
    }
    i = i + 1
  }
}

///|
/// The lexer and the parser agree.
///
/// A statement the lexer refuses is a malformed statement, and the parser
/// says so with `INVALID_SYNTAX` — the same code it would use for a
/// statement that tokenises but does not parse. A caller therefore has one
/// code for "this statement is wrong", not two depending on how far it got.
test "a statement the lexer rejects is a syntax error" {
  let rng = @tesseract_qa_fuzz.Rng::seed(20261027L)
  let mut i = 0
  while i < ROUNDS {
    let sql = @tesseract_qa_fuzz.next_statement(rng)
    match @tesseract.lex(sql) {
      Ok(_) => ()
      Err(_) =>
        match @tesseract.parse_statement(sql) {
          Ok(_) => assert_true(false)
          Err(e) => assert_eq(e.code, "INVALID_SYNTAX")
        }
    }
    i = i + 1
  }
}

///|
/// The store stays consistent under arbitrary statements.
///
/// Every statement is executed **against the same store**, so the statements
/// fight each other: an `INSERT` followed by a `DELETE` followed by a
/// `ROLLBACK` has to leave a store that still answers the question it is
/// asked. The count of rows the store reports has to be the count of rows it
/// holds.
test "the store stays consistent under arbitrary statements" {
  let db = fresh()
  let rng = @tesseract_qa_fuzz.Rng::seed(20261028L)
  let mut i = 0
  while i < ROUNDS {
    let sql = @tesseract_qa_fuzz.next_statement(rng)
    ignore(@tesseract.execute(db, sql))
    i = i + 1
  }
  // The store still answers, and the two answers agree.
  let r = @tesseract.execute(db, "SELECT * FROM tesseract;")
  assert_true(r.success)
  assert_eq(r.total_records, @tesseract.Tesseract::occupancy(db))
  // And it is still a store: the status command reads it.
  let status = @tesseract.Tesseract::status(db)
  assert_true(status.current_count >= 0L)
  assert_true(status.total_cells > 0L)
}

///|
/// A failed statement changes nothing.
///
/// A statement the store refuses must leave the store exactly as it was. The
/// fuzz tries statements that fail in every way the grammar allows, and the
/// store's size is read before and after each one.
test "a refused statement leaves the store alone" {
  let rng = @tesseract_qa_fuzz.Rng::seed(20261029L)
  let mut i = 0
  while i < ROUNDS {
    let sql = @tesseract_qa_fuzz.next_statement(rng)
    let db = fresh()
    // Put one row in, so a statement that *does* run has something to work
    // on, and a refused one has something to disturb.
    ignore(
      @tesseract.execute(
        db, "INSERT INTO tesseract (key,value) VALUES ('seed','v') AT 1;",
      ),
    )
    let before = @tesseract.Tesseract::occupancy(db)
    let r = @tesseract.execute(db, sql)
    if !r.success {
      assert_eq(@tesseract.Tesseract::occupancy(db), before)
    }
    i = i + 1
  }
}
