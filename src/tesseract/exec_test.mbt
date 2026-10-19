///|
/// The engine, measured against the five behaviours it was written to change.
///
/// Every test here names the answer the old surface gave. That is the point: a
/// test asserting only that the new answer is right would pass just as happily if
/// the old wrong answer had never been wrong, and nobody reading it later would
/// know what it is protecting. The numbers in the names are the ones that came out
/// of the real CLI before any of this was written.

///|
fn fresh_engine() -> @tesseract.Tesseract {
  @tesseract.new_db(
    "test",
    @tesseract.default_lattice(),
    @tesseract.new_logger("test"),
  )
}

///|
fn go(db : @tesseract.Tesseract, sql : String) -> @tesseract.DBResponse {
  @tesseract.execute(db, sql)
}

///|
/// Three rows on positions 1..3 with keys that are deliberately *not* in
/// insertion order, so a query that fails to sort is visible as such.
fn three_rows() -> @tesseract.Tesseract {
  let db = fresh_engine()
  ignore(go(db, "INSERT INTO tesseract (key, value) VALUES ('zulu','Z') AT 1;"))
  ignore(
    go(db, "INSERT INTO tesseract (key, value) VALUES ('alpha','A') AT 2;"),
  )
  ignore(go(db, "INSERT INTO tesseract (key, value) VALUES ('mike','M') AT 3;"))
  db
}

///|
/// The keys of a result, in order, as a comma-joined string.
///
/// Order is the thing several of these tests are about, so comparing a rendered
/// list beats comparing a count.
fn keys_of(db : @tesseract.Tesseract, sql : String) -> String {
  let r = go(db, sql)
  let parts : Array[String] = []
  for row in r.data {
    parts.push(row.key)
  }
  parts.join(",")
}

///|
/// `AND` over one column is a conjunction.
///
/// Measured before: `WHERE key='alpha' AND key='beta'` returned **1 row**,
/// `beta`. The old `Where` was a struct with one field per column, so the second
/// conjunct overwrote the first and the query answered a different question than
/// the one asked - and reported success.
test "AND over one column is a conjunction, not last-one-wins" {
  let db = three_rows()
  assert_eq(
    keys_of(db, "SELECT key FROM tesseract WHERE key='alpha' AND key='mike';"),
    "",
  )
  assert_eq(
    keys_of(db, "SELECT key FROM tesseract WHERE key='alpha' AND key='alpha';"),
    "alpha",
  )
  assert_eq(
    keys_of(
      db, "SELECT key FROM tesseract WHERE key='zulu' AND key='mike' AND key='alpha';",
    ),
    "",
  )
}

///|
/// `OR` is a disjunction.
///
/// Measured before: `INVALID_SYNTAX`. There was no boolean operator at all below
/// the top level - the parser split a `WHERE` on the `AND` keyword and had nothing
/// to do with what it found.
test "OR is a disjunction and binds looser than AND" {
  let db = three_rows()
  assert_eq(
    keys_of(db, "SELECT key FROM tesseract WHERE key='alpha' OR key='mike';"),
    "alpha,mike",
  )
  assert_eq(
    keys_of(db, "SELECT key FROM tesseract WHERE key='mike' OR key='alpha';"),
    "alpha,mike",
  )
  // Precedence, not just presence: `AND` is the tighter of the two, so this is
  // `key='mike' OR (key='alpha' AND value='M')` - and the second half is false.
  assert_eq(
    keys_of(
      db, "SELECT key FROM tesseract WHERE key='mike' OR key='alpha' AND value='M';",
    ),
    "mike",
  )
}

///|
/// `NOT` binds tighter than `AND` and looser than comparison.
test "NOT negates a comparison, not the whole clause" {
  let db = three_rows()
  assert_eq(
    keys_of(
      db, "SELECT key FROM tesseract WHERE NOT key='alpha' AND key='mike';",
    ),
    "mike",
  )
  // `NOT (...)` over a false conjunction is true for every row, and with no
  // ORDER BY the rows come back in position order. Written that way on purpose:
  // a first draft expected sorted order from a query that never asked for any,
  // and would have failed for a reason that had nothing to do with `NOT`.
  assert_eq(
    keys_of(
      db, "SELECT key FROM tesseract WHERE NOT (key='alpha' AND key='mike');",
    ),
    "zulu,alpha,mike",
  )
}

///|
/// `LIMIT` bounds the rows returned.
///
/// Measured before: `SELECT * FROM tesseract LIMIT 1` returned **3 rows**. The
/// clause was parsed as nothing and dropped, so the query silently answered a
/// different question - this is the failure mode that made the engine worth
/// writing.
test "LIMIT bounds the rows returned" {
  let db = three_rows()
  assert_eq(go(db, "SELECT key FROM tesseract LIMIT 1;").total_records, 1L)
  assert_eq(go(db, "SELECT key FROM tesseract LIMIT 2;").total_records, 2L)
  // More than there is, and zero.
  assert_eq(go(db, "SELECT key FROM tesseract LIMIT 99;").total_records, 3L)
  assert_eq(go(db, "SELECT key FROM tesseract LIMIT 0;").total_records, 0L)
  // And OFFSET composes with it rather than replacing it.
  assert_eq(
    keys_of(db, "SELECT key FROM tesseract ORDER BY key LIMIT 2 OFFSET 1;"),
    "mike,zulu",
  )
}

///|
/// `ORDER BY` orders, in both directions.
///
/// Measured before: `ORDER BY key DESC` over rows inserted `zulu, alpha, mike`
/// returned **`zulu, alpha, mike`** - the insertion order, unchanged, with no
/// error. Same silent-drop as `LIMIT`.
test "ORDER BY orders instead of returning the insertion order" {
  let db = three_rows()
  assert_eq(
    keys_of(db, "SELECT key FROM tesseract ORDER BY key;"),
    "alpha,mike,zulu",
  )
  assert_eq(
    keys_of(db, "SELECT key FROM tesseract ORDER BY key DESC;"),
    "zulu,mike,alpha",
  )
  // Several terms, and a mixed direction, because the merge has to respect both.
  assert_eq(
    keys_of(db, "SELECT key FROM tesseract ORDER BY value DESC, key ASC;"),
    "zulu,mike,alpha",
  )
}

///|
/// Ties keep the order they arrived in.
///
/// `LIMIT` after a tied `ORDER BY` is the case where an unstable sort changes the
/// answer: with equal keys, an unstable sort may keep any subset, so two runs of
/// the same query disagree. Positions 1, 2 and 3 all carry digit 0 here.
test "ORDER BY is stable, so LIMIT after a tie is reproducible" {
  let db = fresh_engine()
  ignore(go(db, "INSERT INTO tesseract (key, value) VALUES ('c','1') AT 1;"))
  ignore(go(db, "INSERT INTO tesseract (key, value) VALUES ('a','2') AT 2;"))
  ignore(go(db, "INSERT INTO tesseract (key, value) VALUES ('b','3') AT 3;"))
  assert_eq(
    keys_of(db, "SELECT key FROM tesseract ORDER BY digit LIMIT 2;"),
    "c,a",
  )
}

///|
/// Arithmetic evaluates.
///
/// Measured before: `WHERE digit=1+1` was `INVALID_SYNTAX` - "digit needs an
/// integer" - because the parser read the right-hand side as one literal.
test "an integer expression evaluates" {
  let db = fresh_engine()
  ignore(
    go(db, "INSERT INTO tesseract (key, value, digit) VALUES ('a','1',1) AT 1;"),
  )
  ignore(
    go(db, "INSERT INTO tesseract (key, value, digit) VALUES ('b','2',2) AT 2;"),
  )
  assert_eq(keys_of(db, "SELECT key FROM tesseract WHERE digit=1+1;"), "b")
  assert_eq(keys_of(db, "SELECT key FROM tesseract WHERE digit=2*1;"), "b")
  assert_eq(keys_of(db, "SELECT key FROM tesseract WHERE digit=4-2;"), "b")
  assert_eq(keys_of(db, "SELECT key FROM tesseract WHERE digit=3;"), "")
  // `*` binds tighter than `+`, and this is the expression that separates the two:
  // with precedence it is `1 + (2*3)` = 7, which matches nothing; read
  // left-to-right it would be `(1+2)*3` = 9 and match every row.
  assert_eq(keys_of(db, "SELECT key FROM tesseract WHERE 1+2*3=9;"), "")
  assert_eq(keys_of(db, "SELECT key FROM tesseract WHERE 1+2*3=7;"), "a,b")
}

///|
/// The scalar functions this engine added.
test "the scalar functions answer" {
  let db = three_rows()
  // A scalar in the select list is a computed column, not a cell column, so it
  // arrives in `computed` rather than in `value`. Reading `.value` here was the
  // first draft's mistake: `value` was the projected value of the underlying
  // record and said nothing about the function that had been asked for.
  let len = go(db, "SELECT length(key) FROM tesseract WHERE key='alpha';")
  assert_eq(len.data[0].computed[0].label, "length(key)")
  assert_eq(len.data[0].computed[0].value, "5")
  assert_eq(
    keys_of(db, "SELECT key FROM tesseract WHERE upper(key)='ALPHA';"),
    "alpha",
  )
  // A constant predicate on the right of `=`: true for every row, in position
  // order because nothing asked for an order.
  assert_eq(
    keys_of(db, "SELECT key FROM tesseract WHERE lower('ABC')='abc';"),
    "zulu,alpha,mike",
  )
  assert_eq(
    go(db, "SELECT abs(-7) FROM tesseract WHERE key='alpha';").data[0].computed[0].value,
    "7",
  )
  assert_eq(
    go(db, "SELECT coords(1) FROM tesseract WHERE key='alpha';").data[0].computed[0].value,
    "(0,0,0,0)",
  )
}

///|
/// An aggregate answers, and `GROUP BY` decides how many rows come back.
///
/// `Record` has a fixed shape, so the aggregate cannot live in one of the cell
/// columns. It goes in `computed`, with the label it was written under - a result
/// a caller has to label by position is a result they cannot read.
test "an aggregate answers and GROUP BY decides the row count" {
  let db = fresh_engine()
  // Positions 1 and 2 differ only in `w`, so they share a line and cannot both
  // carry digit 1. An earlier version of this fixture put digit 1 on each of
  // them, the second insert was refused with `SUDOKU_CONFLICT`, and the aggregate
  // then summed two rows instead of three - which read as an arithmetic bug and
  // was a bug in the test. Digits go on 1, 1, 2 at positions 1, 5 and 3.
  ignore(
    go(db, "INSERT INTO tesseract (key, value, digit) VALUES ('a','1',1) AT 1;"),
  )
  ignore(
    go(db, "INSERT INTO tesseract (key, value, digit) VALUES ('b','2',1) AT 5;"),
  )
  ignore(
    go(db, "INSERT INTO tesseract (key, value, digit) VALUES ('c','3',2) AT 3;"),
  )
  let grouped = go(db, "SELECT count(*) FROM tesseract GROUP BY digit;")
  assert_eq(grouped.total_records, 2L)
  let total = go(db, "SELECT count(*) FROM tesseract;")
  assert_eq(total.total_records, 1L)
  assert_eq(total.data[0].computed.length(), 1)
  assert_eq(total.data[0].computed[0].label, "count(*)")
  assert_eq(total.data[0].computed[0].value, "3")
  // sum/min/max over the same rows, each with its own label.
  assert_eq(
    go(db, "SELECT sum(digit), min(digit), max(digit) FROM tesseract;").data[0].computed[0].value,
    "4",
  )
  // And the rendered form shows it, rather than a row with nothing in it.
  assert_true(@tesseract.format_response(total).contains("count(*): 3"))
}

///|
/// A rolled-back transaction changes nothing.
///
/// This is the case the undo journal exists for. The rows here are written inside
/// `BEGIN`, and one of them overwrites a record that already existed - so a
/// rollback that only cleared cells would leave the original missing.
test "a rolled-back transaction changes nothing" {
  let db = fresh_engine()
  ignore(
    go(db, "INSERT INTO tesseract (key, value) VALUES ('before','0') AT 5;"),
  )
  assert_true(go(db, "BEGIN;").success)
  ignore(go(db, "INSERT INTO tesseract (key, value) VALUES ('new','1') AT 1;"))
  ignore(
    go(db, "INSERT INTO tesseract (key, value) VALUES ('clobber','2') AT 5;"),
  )
  assert_eq(@tesseract.Tesseract::occupancy(db), 2L)
  assert_true(go(db, "ROLLBACK;").success)
  assert_eq(@tesseract.Tesseract::occupancy(db), 1L)
  assert_eq(@tesseract.Tesseract::cell_at(db, 5L).unwrap().key, "before")
  assert_true(@tesseract.Tesseract::cell_at(db, 1L).unwrap().key == "")
}

///|
/// A committed transaction keeps its work, and a savepoint rolls back part of it.
test "COMMIT keeps and SAVEPOINT discards only what came after it" {
  let db = fresh_engine()
  ignore(go(db, "INSERT INTO tesseract (key, value) VALUES ('kept','1') AT 1;"))
  assert_true(go(db, "BEGIN;").success)
  ignore(go(db, "SAVEPOINT sp1;").success)
  ignore(
    go(db, "INSERT INTO tesseract (key, value) VALUES ('dropped','2') AT 2;"),
  )
  assert_true(go(db, "ROLLBACK TO sp1;").success)
  assert_true(go(db, "COMMIT;").success)
  assert_eq(@tesseract.Tesseract::occupancy(db), 1L)
  assert_eq(@tesseract.Tesseract::cell_at(db, 1L).unwrap().key, "kept")
}

///|
/// A multi-row statement that is refused halfway keeps none of its work.
///
/// This is the case the implicit statement savepoint exists for, and it has
/// nothing to do with `BEGIN`: rows 1 and 2 are written, row 3 is refused by the
/// sudoku rule, and the statement leaves nothing behind. Positions 1 and 3 differ
/// only in `w`, so they share a line and cannot both carry digit 1.
test "a failed statement leaves no partial write" {
  let db = fresh_engine()
  ignore(
    go(db, "INSERT INTO tesseract (key, value, digit) VALUES ('x','0',1) AT 1;"),
  )
  ignore(
    go(db, "INSERT INTO tesseract (key, value, digit) VALUES ('y','0',2) AT 3;"),
  )
  let refused = go(db, "UPDATE tesseract SET digit = 1 WHERE digit > 0;")
  assert_true(!refused.success)
  assert_eq(refused.error_code, "SUDOKU_CONFLICT")
  // Nothing moved: the two digits are exactly what they were.
  assert_eq(@tesseract.Tesseract::cell_at(db, 1L).unwrap().digit, 1L)
  assert_eq(@tesseract.Tesseract::cell_at(db, 3L).unwrap().digit, 2L)
}

///|
/// An expression that cannot be evaluated is refused, on an empty table too.
///
/// A filter is evaluated against rows, so on a table with no rows it is never
/// evaluated at all - and `SELECT * FROM t WHERE bogus = 'x'` succeeded with zero
/// rows. Whether the table has data is not a fact that decides whether a
/// statement is well formed.
test "an unknown column is refused whether or not there are rows" {
  let db = fresh_engine()
  assert_eq(@tesseract.Tesseract::occupancy(db), 0L)
  assert_eq(
    go(db, "SELECT * FROM tesseract WHERE bogus = 'x';").error_code,
    "INVALID_COLUMNS",
  )
  assert_eq(
    go(db, "UPDATE tesseract SET bogus = 'x';").error_code,
    "INVALID_COLUMNS",
  )
  // And with rows in it, still refused.
  ignore(go(db, "INSERT INTO tesseract (key, value) VALUES ('a','1') AT 1;"))
  assert_eq(
    go(db, "SELECT * FROM tesseract WHERE bogus = 'x';").error_code,
    "INVALID_COLUMNS",
  )
}

///|
/// A geometry predicate that cannot be answered fails rather than matching.
test "a bad axis is refused instead of matching every row" {
  let db = three_rows()
  // `coord_at` used to fall through to the last axis for anything out of range,
  // so `line(1,7)` answered exactly what `line(1,3)` answers.
  let r = go(db, "SELECT key FROM tesseract WHERE line(1, 7);")
  assert_true(!r.success)
  assert_eq(r.error_code, "INVALID_SYNTAX")
}

///|
/// `peers` does not include the cell it names.
///
/// `shares_line(c, c)` is trivially true, so this needed an explicit guard -
/// without one `WHERE peers(1)` returned the row at position 1 along with its
/// eight line-mates.
test "peers excludes the position it was given" {
  let db = fresh_engine()
  ignore(go(db, "INSERT INTO tesseract (key, value) VALUES ('self','1') AT 1;"))
  ignore(go(db, "INSERT INTO tesseract (key, value) VALUES ('mate','2') AT 2;"))
  ignore(go(db, "INSERT INTO tesseract (key, value) VALUES ('far','3') AT 37;"))
  assert_eq(keys_of(db, "SELECT key FROM tesseract WHERE peers(1);"), "mate")
  assert_eq(
    keys_of(db, "SELECT key FROM tesseract WHERE line(1, 3);"),
    "self,mate",
  )
}

///|
/// A zero-row `SELECT` says so.
///
/// The renderer only printed a result block when there was something in it, so a
/// query that matched nothing was indistinguishable from a statement that had not
/// run - and `AND` answering zero rows is precisely the answer the old surface
/// could not give.
test "a SELECT that matched nothing says so" {
  let db = three_rows()
  let r = go(db, "SELECT key FROM tesseract WHERE key='alpha' AND key='mike';")
  assert_true(r.success)
  assert_eq(r.total_records, 0L)
  assert_true(@tesseract.format_response(r).contains("0 "))
  assert_true(@tesseract.format_response(r).contains("0 "))
}

///|
/// `DISTINCT` drops rows that repeat.
test "DISTINCT drops repeats and keeps the first" {
  let db = fresh_engine()
  ignore(go(db, "INSERT INTO tesseract (key, value) VALUES ('a','same') AT 1;"))
  ignore(go(db, "INSERT INTO tesseract (key, value) VALUES ('b','same') AT 2;"))
  ignore(go(db, "INSERT INTO tesseract (key, value) VALUES ('c','same') AT 3;"))
  assert_eq(go(db, "SELECT value FROM tesseract;").total_records, 3L)
  assert_eq(go(db, "SELECT DISTINCT value FROM tesseract;").total_records, 1L)
}

///|
/// The C# dialect still loads: backticked identifiers, a `grid_position` column
/// and a `timestamp` column.
test "the C# insert dialect still loads" {
  let db = fresh_engine()
  let r = go(
    db, "INSERT INTO tesseract (grid_position, `key`, `value`, timestamp) VALUES (7, 'legacy', 'v1', '2024-01-01');",
  )
  assert_true(r.success)
  let cell = @tesseract.Tesseract::cell_at(db, 7L).unwrap()
  assert_eq(cell.key, "legacy")
  assert_eq(cell.value, "v1")
  // The stamp is carried rather than re-derived, which is what makes a `.sql`
  // round trip keep it.
  assert_eq(cell.timestamp, "2024-01-01")
}

///|
/// Three rows carrying digits 1, 2 and 3.
///
/// Positions 1..3 differ only in `w`, so they lie on one axis-parallel line and
/// the sudoku rule requires three different digits there — which is exactly what
/// makes them three *distinct* values to group by. A fixture without digits
/// cannot tell `GROUP BY digit` apart from `GROUP BY nosuchcol`: both answer one
/// group, so the fixture hides the very difference the test is about.
fn three_rows_with_digits() -> @tesseract.Tesseract {
  let db = fresh_engine()
  ignore(
    go(db, "INSERT INTO tesseract (key, value, digit) VALUES ('a','1',1) AT 1;"),
  )
  ignore(
    go(db, "INSERT INTO tesseract (key, value, digit) VALUES ('b','2',2) AT 2;"),
  )
  ignore(
    go(db, "INSERT INTO tesseract (key, value, digit) VALUES ('c','3',3) AT 3;"),
  )
  db
}

///|
/// `GROUP BY nosuchcol` answered **one group, count 3**.
///
/// Not an error — a result. The unknown column evaluated to null on every row,
/// every row hashed to the same key, and the query reported a single group with
/// the whole table in it, which is the shape a legitimately uniform column
/// reports. Nothing in the answer said the column did not exist.
test "group by an unknown column is refused rather than answering one group" {
  let db = three_rows_with_digits()
  let r = go(
    db, "SELECT nosuchcol, count(*) FROM tesseract GROUP BY nosuchcol;",
  )
  assert_eq(r.error_code, "INVALID_COLUMNS")
  assert_false(r.success)
  assert_eq(r.data.length(), 0)
}

///|
/// The control for the test above: the *same* statement with a column that
/// exists returns three groups, not one. Without this pair the refusal would
/// pass just as happily against a table where every digit was identical.
test "group by a real column still returns one group per distinct value" {
  let db = three_rows_with_digits()
  let r = go(db, "SELECT digit, count(*) FROM tesseract GROUP BY digit;")
  assert_true(r.success)
  assert_eq(r.error_code, "")
  assert_eq(r.data.length(), 3)
}

///|
/// The refusal does not depend on the data — the point of checking against a
/// synthetic row at all.
///
/// With no rows stored, the old path had nothing to evaluate the term against
/// and returned one group with a count of zero, so the answer changed with the
/// contents of the table while the statement stayed exactly as wrong.
test "an unknown group-by column is refused on an empty table too" {
  let db = fresh_engine()
  assert_eq(@tesseract.Tesseract::occupancy(db), 0L)
  assert_eq(
    go(db, "SELECT nosuchcol, count(*) FROM tesseract GROUP BY nosuchcol;").error_code,
    "INVALID_COLUMNS",
  )
}

///|
/// `ORDER BY nosuchcol` answered **three rows in storage order**.
///
/// Sorting on a null is not the same as failing to sort, so the query returned a
/// plausible list rather than an error, and the one thing a caller asks an
/// `ORDER BY` for — an order — was silently not applied.
test "order by an unknown column is refused rather than returning storage order" {
  let db = three_rows()
  assert_eq(
    go(db, "SELECT key FROM tesseract ORDER BY nosuchcol;").error_code,
    "INVALID_COLUMNS",
  )
  // And the real thing still sorts: keys were inserted zulu, alpha, mike.
  assert_eq(
    keys_of(db, "SELECT key FROM tesseract ORDER BY key;"),
    "alpha,mike,zulu",
  )
}

///|
/// An unknown column in a grouped select list was **dropped in silence**.
///
/// `group_rows` takes the plain-column branch for a bare name and never
/// evaluates it, so it reached `project` unchecked and vanished there — the
/// query succeeded and returned a group whose row had an empty key, with no
/// indication that a column of the statement had been discarded.
test "an unknown column in a grouped select list is refused, not dropped" {
  let db = three_rows_with_digits()
  let r = go(
    db, "SELECT digit, nosuchcol, count(*) FROM tesseract GROUP BY digit;",
  )
  assert_eq(r.error_code, "INVALID_COLUMNS")
  assert_false(r.success)
}

///|
/// The check walks the whole expression, not just its top node.
///
/// `GROUP BY length(nosuchcol)` is the same mistake written inside a call, and a
/// validator that only matched on the outermost node would wave it through and
/// group on an empty string — one group again, which is the wrong answer this
/// section exists to stop producing.
test "an unknown column nested inside an expression is refused too" {
  let db = three_rows_with_digits()
  assert_eq(
    go(db, "SELECT count(*) FROM tesseract GROUP BY length(nosuchcol);").error_code,
    "INVALID_COLUMNS",
  )
  assert_eq(
    go(db, "SELECT count(*) FROM tesseract WHERE key IN ('a', nosuchcol);").error_code,
    "INVALID_COLUMNS",
  )
}

///|
/// The check refuses unknown columns and nothing else.
///
/// It walks `Column` nodes only, so aggregates — which have no single row to
/// evaluate against until a group exists — are left to the executor that can
/// actually answer them. If this test ever fails, the validator has started
/// deciding what `count(*)` means before there is anything to count.
test "the column check refuses unknown columns and nothing else" {
  let db = three_rows_with_digits()
  for
    sql in [
      "SELECT count(*) FROM tesseract;", "SELECT digit, count(*) FROM tesseract GROUP BY digit;",
      "SELECT key, length(value) FROM tesseract;", "SELECT key FROM tesseract ORDER BY length(key) DESC;",
      "SELECT DISTINCT digit FROM tesseract;", "SELECT count(*) FROM tesseract WHERE digit > 1 AND key <> 'a';",
    ] {
    let r = go(db, sql)
    assert_eq(r.error_code, "")
    assert_true(r.success)
  }
}
