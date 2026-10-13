///|
/// The SQL surface, including the C#-compatible subset and the 4D additions.
fn fresh_db() -> @sudokudb.SudokuDB {
  @sudokudb.new_db("test", @sudokudb.new_logger("test"))
}

///|
fn run_sql(db : @sudokudb.SudokuDB, sql : String) -> @sudokudb.DBResponse {
  @sudokudb.execute(db, sql)
}

///|
test "a geometry predicate keeps the other conjuncts" {
  let db = fresh_db()
  // Positions 1 and 3 share the w-axis line, so they may not carry the same
  // digit; position 40 is on neither of their lines.
  ignore(@sudokudb.SudokuDB::insert(db, "p1", "one", Some(1), 2))
  ignore(@sudokudb.SudokuDB::insert(db, "p3", "three", Some(3), 1))
  ignore(@sudokudb.SudokuDB::insert(db, "far", "far", Some(40), 1))
  // The geometry call answered `line(1,3)` and returned its rows; every other
  // condition in the same WHERE had been parsed and then discarded, so this
  // came back with the digit-1 cell too.
  let on_digit = run_sql(
    db, "SELECT * FROM sudokuDB WHERE line(1,3) AND digit = 2;",
  )
  assert_true(on_digit.success)
  assert_eq(on_digit.total_records, 1)
  assert_eq(on_digit.data[0].key, "p1")
  let no_such_digit = run_sql(
    db, "SELECT * FROM sudokuDB WHERE line(1,3) AND digit = 9;",
  )
  assert_true(no_such_digit.success)
  assert_eq(no_such_digit.total_records, 0)
  let peers_hit = run_sql(
    db, "SELECT * FROM sudokuDB WHERE peers(1) AND key = 'p3';",
  )
  assert_eq(peers_hit.total_records, 1)
  assert_eq(peers_hit.data[0].key, "p3")
  // The case that proved it: a key that is on the line but not in the lattice.
  let peers_miss = run_sql(
    db, "SELECT * FROM sudokuDB WHERE peers(1) AND key = 'zzz';",
  )
  assert_true(peers_miss.success)
  assert_eq(peers_miss.total_records, 0)
  let like_miss = run_sql(
    db, "SELECT * FROM sudokuDB WHERE line(1,3) AND value LIKE '%nope%';",
  )
  assert_eq(like_miss.total_records, 0)
  let like_hit = run_sql(
    db, "SELECT * FROM sudokuDB WHERE line(1,3) AND value LIKE '%hre%';",
  )
  assert_eq(like_hit.total_records, 1)
  assert_eq(like_hit.data[0].key, "p3")
}

///|
test "an unwrapped LIKE pattern matches one value, not every row" {
  let db = fresh_db()
  ignore(@sudokudb.SudokuDB::insert(db, "a", "hello", Some(1), 0))
  ignore(@sudokudb.SudokuDB::insert(db, "b", "zzz", Some(5), 0))
  // A bare literal used to be stripped to "" and "" meant "no predicate", so it
  // matched everything. Too wide is the direction that hides a problem.
  assert_eq(
    run_sql(db, "SELECT * FROM sudokuDB WHERE value LIKE 'hello';").total_records,
    1,
  )
  assert_eq(
    run_sql(db, "SELECT * FROM sudokuDB WHERE value LIKE 'q';").total_records,
    0,
  )
  assert_eq(
    run_sql(db, "SELECT * FROM sudokuDB WHERE value LIKE '%hell%';").total_records,
    1,
  )
  // `LIKE ''` cannot match any stored record - insert rejects empty values - and
  // must not quietly become "no predicate".
  let empty = run_sql(db, "SELECT * FROM sudokuDB WHERE value LIKE '';")
  assert_false(empty.success)
  assert_eq(empty.error_code, "INVALID_SYNTAX")
}

///|
test "a malformed string literal is an error, not a key that matches nothing" {
  let db = fresh_db()
  ignore(@sudokudb.SudokuDB::insert(db, "a", "1", Some(1), 0))
  // Both used to come back as a successful query matching zero rows, which
  // reads as "the data is missing" rather than "the statement is wrong".
  let unterminated = run_sql(db, "SELECT * FROM sudokuDB WHERE key = 'a;")
  assert_false(unterminated.success)
  assert_eq(unterminated.error_code, "INVALID_SYNTAX")
  assert_true(unterminated.error.contains("Unterminated"))
  let trailing = run_sql(db, "SELECT * FROM sudokuDB WHERE key = 'a' garbage;")
  assert_false(trailing.success)
  assert_eq(trailing.error_code, "INVALID_SYNTAX")
  assert_true(trailing.error.contains("Unexpected text"))
  // The well-formed form still works.
  assert_eq(
    run_sql(db, "SELECT * FROM sudokuDB WHERE key = 'a';").total_records,
    1,
  )
}

///|
test "a doubled quote inside a literal is an escaped quote" {
  let db = fresh_db()
  // Standard SQL spells an embedded quote `''`; this dialect's exporter uses
  // `\'`, but a dump written by another engine uses this form.
  let r = run_sql(
    db, "INSERT INTO sudokuDB (key, value) VALUES ('a', 'has '' quote');",
  )
  assert_true(r.success)
  assert_eq(@sudokudb.SudokuDB::cell_at(db, 1).unwrap().value, "has ' quote")
  // ...and it must not turn the trailing-junk check off.
  let junk = run_sql(db, "SELECT * FROM sudokuDB WHERE key = 'a' 'b';")
  assert_false(junk.success)
  assert_eq(junk.error_code, "INVALID_SYNTAX")
}

///|
test "a WHERE inside a SET literal does not cut the UPDATE in two" {
  let db = fresh_db()
  ignore(@sudokudb.SudokuDB::insert(db, "k", "before", Some(1), 0))
  // `where_index` used to find the literal's WHERE first, so the statement was
  // cut there and the remainder failed to parse.
  let r = run_sql(
    db, "UPDATE sudokuDB SET value = 'x WHERE y = z' WHERE key = 'k';",
  )
  assert_true(r.success)
  assert_eq(@sudokudb.SudokuDB::cell_at(db, 1).unwrap().value, "x WHERE y = z")
  let two = run_sql(
    db, "UPDATE sudokuDB SET value = 'a=b WHERE c' WHERE key = 'k';",
  )
  assert_true(two.success)
  assert_eq(@sudokudb.SudokuDB::cell_at(db, 1).unwrap().value, "a=b WHERE c")
}

///|
test "a geometry axis outside 0..3 is a syntax error, not a different axis" {
  let db = fresh_db()
  ignore(@sudokudb.SudokuDB::insert(db, "a", "1", Some(1), 1))
  ignore(@sudokudb.SudokuDB::insert(db, "b", "2", Some(4), 1))
  // `coord_at` falls through to the last axis, so `line(1,7)` used to answer
  // exactly what `line(1,3)` answers - the same rows, reported as if the
  // statement had named the w axis.
  let r = run_sql(db, "SELECT * FROM sudokuDB WHERE line(1,7);")
  assert_false(r.success)
  assert_eq(r.error_code, "INVALID_SYNTAX")
  assert_true(run_sql(db, "SELECT * FROM sudokuDB WHERE line(1,3);").success)
}

///|
test "the C# statement shapes still parse" {
  let db = fresh_db()
  assert_true(run_sql(db, "CREATE DATABASE sudokuDB;").success)
  assert_true(
    run_sql(db, "INSERT INTO sudokuDB (key, value) VALUES ('a', '1');").success,
  )
  let r = run_sql(db, "SELECT * FROM sudokuDB WHERE key = 'a';")
  assert_true(r.success)
  assert_eq(r.total_records, 1)
  assert_true(
    run_sql(db, "UPDATE sudokuDB SET value = '2' WHERE key = 'a';").success,
  )
  assert_eq(@sudokudb.SudokuDB::cell_at(db, 1).unwrap().value, "2")
  assert_true(run_sql(db, "DELETE FROM sudokuDB WHERE key = 'a';").success)
  assert_eq(@sudokudb.SudokuDB::occupancy(db), 0)
}

///|
test "statements are case-insensitive and the semicolon is optional" {
  let db = fresh_db()
  assert_true(
    run_sql(db, "insert into sudokuDB (key, value) values ('a','1')").success,
  )
  assert_true(run_sql(db, "SeLeCt * FrOm sudokuDB").success)
  assert_eq(run_sql(db, "select * from sudokuDB").total_records, 1)
}

///|
test "empty and unsupported statements report their own codes" {
  let db = fresh_db()
  assert_eq(run_sql(db, "   ").error_code, "EMPTY_SQL")
  assert_eq(run_sql(db, ";").error_code, "EMPTY_SQL")
  assert_eq(run_sql(db, "DROP TABLE sudokuDB").error_code, "UNSUPPORTED_SQL")
  // A bare SELECT is a recognised verb with a malformed body, so it reports the
  // more specific INVALID_SYNTAX rather than UNSUPPORTED_SQL.
  assert_eq(run_sql(db, "SELECT").error_code, "INVALID_SYNTAX")
}

///|
test "values keep embedded commas, parens and JSON" {
  let db = fresh_db()
  let sql = "INSERT INTO sudokuDB (key, value) VALUES ('u', '{\"name\": \"Zhang, San\", \"n\": 1}');"
  assert_true(run_sql(db, sql).success)
  let r = run_sql(db, "SELECT * FROM sudokuDB WHERE key = 'u'")
  assert_eq(r.total_records, 1)
  assert_eq(r.data[0].value, "{\"name\": \"Zhang, San\", \"n\": 1}")
}

///|
test "backslash escapes inside quoted values are resolved" {
  let db = fresh_db()
  assert_true(
    run_sql(db, "INSERT INTO sudokuDB (key, value) VALUES ('a', 'x\\'y');").success,
  )
  let r = run_sql(db, "SELECT * FROM sudokuDB WHERE key = 'a'")
  assert_eq(r.data[0].value, "x'y")
}

///|
test "column/value count mismatch is rejected" {
  let db = fresh_db()
  let r = run_sql(
    db, "INSERT INTO sudokuDB (key, value, digit) VALUES ('a', '1')",
  )
  assert_false(r.success)
  assert_eq(r.error_code, "INVALID_COLUMNS")
}

///|
test "AT addresses an explicit position or a 4D address" {
  let db = fresh_db()
  assert_true(
    run_sql(db, "INSERT INTO sudokuDB (key, value) VALUES ('a', '1') AT 42;").success,
  )
  assert_eq(@sudokudb.SudokuDB::cell_at(db, 42).unwrap().key, "a")
  assert_true(
    run_sql(
      db, "INSERT INTO sudokuDB (key, value) VALUES ('b', '2') AT (1,2,0,2);",
    ).success,
  )
  // (1,2,0,2) is row-major index 47, so 1-based position 48.
  assert_eq(@sudokudb.SudokuDB::cell_at(db, 48).unwrap().key, "b")
  assert_eq(@sudokudb.coords_of(48), Some(@sudokudb.coords(1, 2, 0, 2)))
  assert_eq(
    run_sql(
      db, "INSERT INTO sudokuDB (key, value) VALUES ('c','3') AT (9,9,9,9);",
    ).error_code,
    "INVALID_SYNTAX",
  )
  assert_eq(
    run_sql(db, "INSERT INTO sudokuDB (key, value) VALUES ('c','3') AT (1,2);").error_code,
    "INVALID_SYNTAX",
  )
}

///|
test "coordinate predicates address the right cells" {
  let db = fresh_db()
  ignore(
    run_sql(db, "INSERT INTO sudokuDB (key, value) VALUES ('a','1') AT 1;"),
  )
  ignore(
    run_sql(db, "INSERT INTO sudokuDB (key, value) VALUES ('b','2') AT 28;"),
  )
  ignore(
    run_sql(db, "INSERT INTO sudokuDB (key, value) VALUES ('c','3') AT 37;"),
  )
  // 1 = (0,0,0,0), 28 = (1,0,0,0), 37 = (1,1,0,0)
  let x0 = run_sql(db, "SELECT * FROM sudokuDB WHERE x = 0")
  assert_eq(x0.total_records, 1)
  let x1 = run_sql(db, "SELECT * FROM sudokuDB WHERE x = 1")
  assert_eq(x1.total_records, 2)
  let xy = run_sql(db, "SELECT * FROM sudokuDB WHERE x = 1 AND y = 1")
  assert_eq(xy.total_records, 1)
  assert_eq(xy.data[0].key, "c")
  let none = run_sql(db, "SELECT * FROM sudokuDB WHERE x = 2 AND y = 2")
  assert_eq(none.total_records, 0)
}

///|
test "grid_position and digit predicates combine with key" {
  let db = fresh_db()
  ignore(
    run_sql(
      db, "INSERT INTO sudokuDB (key, value, digit) VALUES ('a','1',1) AT 1;",
    ),
  )
  ignore(
    run_sql(
      db, "INSERT INTO sudokuDB (key, value, digit) VALUES ('b','2',2) AT 37;",
    ),
  )
  let d1 = run_sql(db, "SELECT * FROM sudokuDB WHERE digit = 1")
  assert_eq(d1.total_records, 1)
  assert_eq(d1.data[0].key, "a")
  let both = run_sql(
    db, "SELECT * FROM sudokuDB WHERE key = 'b' AND grid_position = 37",
  )
  assert_eq(both.total_records, 1)
  let mismatch = run_sql(
    db, "SELECT * FROM sudokuDB WHERE key = 'b' AND grid_position = 1",
  )
  assert_eq(mismatch.total_records, 0)
}

///|
test "LIKE matches on value, case-insensitively" {
  let db = fresh_db()
  ignore(
    run_sql(
      db, "INSERT INTO sudokuDB (key, value) VALUES ('a','Hello World') AT 1;",
    ),
  )
  assert_eq(
    run_sql(db, "SELECT * FROM sudokuDB WHERE value LIKE '%hello%'").total_records,
    1,
  )
  assert_eq(
    run_sql(db, "SELECT * FROM sudokuDB WHERE value LIKE '%HELLO%'").total_records,
    1,
  )
  assert_eq(
    run_sql(db, "SELECT * FROM sudokuDB WHERE value LIKE '%bye%'").total_records,
    0,
  )
}

///|
test "geometry predicates select lines, slabs and peers" {
  let db = fresh_db()
  ignore(
    run_sql(db, "INSERT INTO sudokuDB (key, value) VALUES ('a','1') AT 1;"),
  )
  ignore(
    run_sql(db, "INSERT INTO sudokuDB (key, value) VALUES ('b','2') AT 3;"),
  )
  ignore(
    run_sql(db, "INSERT INTO sudokuDB (key, value) VALUES ('c','3') AT 37;"),
  )
  let line = run_sql(db, "SELECT * FROM sudokuDB WHERE line(1, 3)")
  assert_eq(line.total_records, 2)
  let slab = run_sql(db, "SELECT * FROM sudokuDB WHERE slab(1, 0)")
  assert_eq(slab.total_records, 2)
  let peers = run_sql(db, "SELECT * FROM sudokuDB WHERE peers(1)")
  assert_eq(peers.total_records, 1)
  assert_eq(peers.data[0].key, "b")
}

///|
test "a digit collision surfaces as SUDOKU_CONFLICT through SQL" {
  let db = fresh_db()
  assert_true(
    run_sql(
      db, "INSERT INTO sudokuDB (key, value, digit) VALUES ('a','1',1) AT 1;",
    ).success,
  )
  let clash = run_sql(
    db, "INSERT INTO sudokuDB (key, value, digit) VALUES ('b','2',1) AT 3;",
  )
  assert_false(clash.success)
  assert_eq(clash.error_code, "SUDOKU_CONFLICT")
}

///|
test "UPDATE can set a value and a digit together" {
  let db = fresh_db()
  ignore(
    run_sql(db, "INSERT INTO sudokuDB (key, value) VALUES ('a','1') AT 1;"),
  )
  assert_true(
    run_sql(db, "UPDATE sudokuDB SET value = '9', digit = 3 WHERE key = 'a';").success,
  )
  let cell = @sudokudb.SudokuDB::cell_at(db, 1).unwrap()
  assert_eq(cell.value, "9")
  assert_eq(cell.digit, 3)
  assert_eq(
    run_sql(db, "UPDATE sudokuDB SET digit = 2 WHERE key = 'a';").error_code,
    "INVALID_SYNTAX",
  )
}

///|
test "DELETE honours WHERE, and bare DELETE clears the lattice" {
  let db = fresh_db()
  ignore(
    run_sql(db, "INSERT INTO sudokuDB (key, value) VALUES ('a','1') AT 1;"),
  )
  ignore(
    run_sql(db, "INSERT INTO sudokuDB (key, value) VALUES ('b','2') AT 2;"),
  )
  ignore(run_sql(db, "DELETE FROM sudokuDB WHERE grid_position = 1;"))
  assert_eq(@sudokudb.SudokuDB::occupancy(db), 1)
  ignore(run_sql(db, "DELETE FROM sudokuDB;"))
  assert_eq(@sudokudb.SudokuDB::occupancy(db), 0)
}

///|
test "unknown columns and functions are rejected, not ignored" {
  let db = fresh_db()
  assert_eq(
    run_sql(db, "SELECT * FROM sudokuDB WHERE bogus = 'x'").error_code,
    "INVALID_SYNTAX",
  )
  assert_eq(
    run_sql(db, "SELECT * FROM sudokuDB WHERE nosuchfn(1)").error_code,
    "INVALID_SYNTAX",
  )
  assert_eq(
    run_sql(db, "SELECT * FROM sudokuDB WHERE grid_position = 'abc'").error_code,
    "INVALID_SYNTAX",
  )
  assert_eq(
    run_sql(db, "UPDATE sudokuDB SET bogus = 'x' WHERE key = 'a';").error_code,
    "INVALID_SYNTAX",
  )
}

///|
test "a key that merely contains a keyword is still just a key" {
  let db = fresh_db()
  ignore(
    run_sql(
      db, "INSERT INTO sudokuDB (key, value) VALUES ('SELECT', '1') AT 1;",
    ),
  )
  let r = run_sql(db, "SELECT * FROM sudokuDB WHERE key = 'SELECT'")
  assert_eq(r.total_records, 1)
  let none = run_sql(db, "SELECT * FROM sudokuDB WHERE key = 'INSERT'")
  assert_eq(none.total_records, 0)
}

///|
test "a full statement cycle matches the C# demo sequence" {
  let db = fresh_db()
  assert_true(run_sql(db, "DELETE FROM sudokuDB;").success)
  ignore(
    run_sql(
      db, "INSERT INTO sudokuDB (key, value) VALUES ('user_001', '{\"age\": 25}');",
    ),
  )
  ignore(
    run_sql(
      db, "INSERT INTO sudokuDB (key, value) VALUES ('user_002', '{\"age\": 30}');",
    ),
  )
  assert_eq(run_sql(db, "SELECT * FROM sudokuDB;").total_records, 2)
  assert_eq(
    run_sql(db, "SELECT * FROM sudokuDB WHERE key = 'user_001'").total_records,
    1,
  )
  ignore(
    run_sql(
      db, "UPDATE sudokuDB SET value = '{\"age\": 26}' WHERE key = 'user_001';",
    ),
  )
  assert_eq(@sudokudb.SudokuDB::cell_at(db, 1).unwrap().value, "{\"age\": 26}")
  ignore(run_sql(db, "DELETE FROM sudokuDB WHERE key = 'user_002';"))
  assert_eq(run_sql(db, "SELECT * FROM sudokuDB;").total_records, 1)
}
