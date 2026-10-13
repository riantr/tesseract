///|
/// Import and export, with round-trip fidelity as the point.
fn db_with_three() -> @sudokudb.SudokuDB {
  let db = @sudokudb.new_db("sudokuDB", @sudokudb.new_logger("t"))
  ignore(
    @sudokudb.SudokuDB::insert(db, "user_001", "{\"age\": 25}", Some(1), 1),
  )
  ignore(
    @sudokudb.SudokuDB::insert(db, "user_002", "{\"age\": 30}", Some(37), 0),
  )
  ignore(@sudokudb.SudokuDB::insert(db, "book, one", "a | b\nc", Some(48), 3))
  db
}

///|
test "sdb round trip does not depend on how much was logged beforehand" {
  let src = db_with_three()
  let text = @sudokudb.export_sdb(src)
  // A destination with a completely different logging history. The stamps used
  // to be re-derived from the logger counter on import, so this comparison only
  // held while both sides happened to be at the same sequence number - which
  // is exactly the condition the fixture above arranges and nothing enforces.
  let dst = @sudokudb.new_db("sudokuDB", @sudokudb.new_logger("t"))
  for p in [7, 8, 9, 10, 11] {
    ignore(@sudokudb.SudokuDB::insert(dst, "noise", "x", Some(p), 0))
  }
  ignore(@sudokudb.SudokuDB::delete(dst, "", None))
  assert_eq(@sudokudb.import_sdb(dst, text), Ok(3))
  assert_eq(@sudokudb.export_sdb(dst), text)
}

///|
test "import_sdb clears first, so a load never merges into existing records" {
  let db = @sudokudb.new_db("sudokuDB", @sudokudb.new_logger("t"))
  ignore(@sudokudb.SudokuDB::insert(db, "stale", "left over", Some(60), 0))
  let text = @sudokudb.export_sdb(db_with_three())
  assert_eq(@sudokudb.import_sdb(db, text), Ok(3))
  // `stale` at position 60 is not in the file, and the load is documented to
  // leave an empty database rather than a half-overwritten one.
  assert_eq(@sudokudb.SudokuDB::occupancy(db), 3)
  assert_true(db.cells[59].key == "")
}

///|
test "import refuses a record with no usable address instead of guessing cell 1" {
  let db = @sudokudb.new_db("sudokuDB", @sudokudb.new_logger("t"))
  ignore(@sudokudb.SudokuDB::insert(db, "occupant", "was here", Some(1), 0))
  let text = "{\n  \"records\": [\n    {\"grid_position\": 999, \"coords\": \"nonsense\", \"key\": \"x\", \"value\": \"y\"}\n  ]\n}"
  let refused = match @sudokudb.import_sdb(db, text) {
    Ok(_) => false
    Err(_) => true
  }
  assert_true(refused)
  // Falling back to FIRST_POSITION would have written `x` into cell 1 and still
  // reported a clean load. The clear runs first, so the refusal leaves the
  // database empty rather than half-overwritten - which is what this function
  // documents.
  assert_false(db.cells[0].key == "x")
  assert_eq(@sudokudb.SudokuDB::occupancy(db), 0)
}

///|
test "import_sql reports a script that partly failed" {
  let db = @sudokudb.new_db("sudokuDB", @sudokudb.new_logger("t"))
  let text = "INSERT INTO sudokuDB (key, value) VALUES ('a', '1') AT 1;\nNOT SQL AT ALL;\n"
  // Counting only the successes reported a broken dump as a clean import, so a
  // file truncated by a stray banner line still came back Ok.
  let outcome = @sudokudb.import_sql(db, text)
  match outcome {
    Ok(_) => assert_true(false)
    Err(message) => assert_true(message.contains("1 of 2"))
  }
}

///|
test "lattice view shows the digit, not a truncated key" {
  let db = db_with_three()
  let view = @sudokudb.render_lattice(db, @sudokudb.FIRST_POSITION)
  // Keys like `cell_1` are 6 characters, so appending the digit and then
  // ellipsizing to 6 columns cut the digit off again - every solved cell used
  // to render as `cell_~`.
  let db2 = @sudokudb.new_db("sudokuDB", @sudokudb.new_logger("t"))
  ignore(@sudokudb.SudokuDB::insert(db2, "cell_1", "{\"pos\": 1}", Some(1), 3))
  let view2 = @sudokudb.render_lattice(db2, @sudokudb.FIRST_POSITION)
  assert_false(view2.contains("cell_~"))
  // The key gives up one column to the digit: `ellipsize` spends 5 on `cell_1`
  // and the digit is appended after it.
  assert_true(view2.contains("cell~3"))
  ignore(view)
}

///|
test "sdb export carries every record with its coordinates" {
  let db = db_with_three()
  let text = @sudokudb.export_sdb(db)
  assert_true(text.contains("\"total_cells\": 81"))
  assert_true(text.contains("\"dimensions\": 4"))
  assert_true(text.contains("\"coords\": \"(1,1,0,0)\""))
  assert_true(text.contains("\"grid_position\": 48"))
  assert_true(text.contains("\"digit\": 3"))
  // The comma and pipe in the value must survive escaping.
  assert_true(text.contains("book, one"))
}

///|
test "sdb round-trips content, position and digit" {
  let src = db_with_three()
  let text = @sudokudb.export_sdb(src)
  let dst = @sudokudb.new_db("sudokuDB", @sudokudb.new_logger("t"))
  let loaded = match @sudokudb.import_sdb(dst, text) {
    Ok(n) => n
    Err(e) => {
      fail("import_sdb failed: " + e)
      0
    }
  }
  assert_eq(loaded, 3)
  assert_eq(@sudokudb.SudokuDB::occupancy(dst), 3)
  let a = @sudokudb.SudokuDB::cell_at(dst, 1).unwrap()
  assert_eq(a.key, "user_001")
  assert_eq(a.digit, 1)
  let b = @sudokudb.SudokuDB::cell_at(dst, 37).unwrap()
  assert_eq(b.key, "user_002")
  assert_eq(b.digit, 0)
  let c = @sudokudb.SudokuDB::cell_at(dst, 48).unwrap()
  assert_eq(c.key, "book, one")
  assert_eq(c.value, "a | b\nc")
  assert_eq(c.digit, 3)
  // Re-exporting the copy must reproduce the original document.
  assert_eq(@sudokudb.export_sdb(dst), text)
}

///|
test "a malformed sdb is reported, not half-loaded" {
  let db = @sudokudb.new_db("t", @sudokudb.new_logger("t"))
  assert_eq(@sudokudb.import_sdb(db, "{not json"), Err("Not valid JSON"))
  assert_eq(
    @sudokudb.import_sdb(db, "{\"other\": 1}"),
    Err("Missing records array"),
  )
  assert_eq(@sudokudb.SudokuDB::occupancy(db), 0)
}

///|
test "markdown export and import round-trip" {
  let src = db_with_three()
  let text = @sudokudb.export_markdown(src)
  assert_true(
    text.contains("| 位置 | 坐标 | Key | Value | 数 | 时间戳 |"),
  )
  assert_true(text.contains("3x3x3x3"))
  let dst = @sudokudb.new_db("copy", @sudokudb.new_logger("t"))
  let loaded = match @sudokudb.import_markdown(dst, text) {
    Ok(n) => n
    Err(e) => {
      fail("import_markdown failed: " + e)
      0
    }
  }
  assert_eq(loaded, 3)
  let c = @sudokudb.SudokuDB::cell_at(dst, 48).unwrap()
  assert_eq(c.key, "book, one")
  assert_eq(c.value, "a | b\nc")
}

///|
test "the C# markdown header still loads" {
  let db = @sudokudb.new_db("t", @sudokudb.new_logger("t"))
  let md = "| 位置 | Key | Value | 时间戳 |\n|------|-----|-------|--------|\n| 5 | legacy | v1 | 2024-01-01 |\n"
  let loaded = match @sudokudb.import_markdown(db, md) {
    Ok(n) => n
    Err(_) => -1
  }
  assert_eq(loaded, 1)
  assert_eq(@sudokudb.SudokuDB::cell_at(db, 5).unwrap().key, "legacy")
}

///|
test "sql export round-trips through the parser" {
  let src = db_with_three()
  let text = @sudokudb.export_sql(src)
  assert_true(text.contains("CREATE DATABASE sudokuDB;"))
  assert_true(text.contains("AT (1,1,0,0);"))
  let dst = @sudokudb.new_db("copy", @sudokudb.new_logger("t"))
  let ok = match @sudokudb.import_sql(dst, text) {
    Ok(n) => n
    Err(e) => {
      fail("import_sql failed: " + e)
      0
    }
  }
  assert_eq(ok, 4)
  assert_eq(@sudokudb.SudokuDB::occupancy(dst), 3)
  assert_eq(@sudokudb.SudokuDB::cell_at(dst, 1).unwrap().digit, 1)
  assert_eq(@sudokudb.SudokuDB::cell_at(dst, 48).unwrap().key, "book, one")
}

///|
test "the C# sql dialect with backticks and timestamp still loads" {
  let db = @sudokudb.new_db("t", @sudokudb.new_logger("t"))
  let dump = "INSERT INTO sudokuDB (grid_position, `key`, `value`, timestamp) VALUES (7, 'legacy', 'v1', '2024-01-01');"
  let ok = match @sudokudb.import_sql(db, dump) {
    Ok(n) => n
    Err(_) => -1
  }
  assert_eq(ok, 1)
  assert_eq(@sudokudb.SudokuDB::cell_at(db, 7).unwrap().key, "legacy")
}

///|
test "a value containing a quote round-trips through sql" {
  let src = @sudokudb.new_db("t", @sudokudb.new_logger("t"))
  ignore(@sudokudb.SudokuDB::insert(src, "q", "it's \"quoted\"", Some(3), 0))
  let text = @sudokudb.export_sql(src)
  let dst = @sudokudb.new_db("c", @sudokudb.new_logger("t"))
  ignore(@sudokudb.import_sql(dst, text))
  assert_eq(
    @sudokudb.SudokuDB::cell_at(dst, 3).unwrap().value,
    "it's \"quoted\"",
  )
}

///|
test "statement splitting respects semicolons inside literals" {
  let db = @sudokudb.new_db("t", @sudokudb.new_logger("t"))
  let script = "INSERT INTO sudokuDB (key, value) VALUES ('a', 'x;y') AT 2;\nINSERT INTO sudokuDB (key, value) VALUES ('b', 'z') AT 4;\n"
  let ok = match @sudokudb.import_sql(db, script) {
    Ok(n) => n
    Err(_) => -1
  }
  assert_eq(ok, 2)
  assert_eq(@sudokudb.SudokuDB::cell_at(db, 2).unwrap().value, "x;y")
}

///|
test "the lattice view names every cell once" {
  let db = @sudokudb.new_db("t", @sudokudb.new_logger("t"))
  ignore(@sudokudb.SudokuDB::insert(db, "k", "v", Some(41), 0))
  let view = @sudokudb.render_lattice(db, 41)
  // Three x sections, each a header plus one line per y value, plus a legend.
  assert_eq(@sudokudb.split(view, "\n").length(), 14)
  assert_true(view.contains("x = 0"))
  assert_true(view.contains("x = 1"))
  assert_true(view.contains("x = 2"))
  assert_true(view.contains(">"))
  assert_true(view.contains("k"))
}

///|
test "markdown round-trips tab and carriage return" {
  let db = @sudokudb.new_db("sudokuDB", @sudokudb.new_logger("t"))
  // TAB used to be written as four spaces and CR dropped outright, so the value
  // came back as a different string - a one-way corruption that only `.sdb` and
  // `.sql` avoided.
  let original = "a\tb\rc"
  ignore(@sudokudb.SudokuDB::insert(db, "tabs", original, Some(1), 0))
  let text = @sudokudb.export_markdown(db)
  let back = @sudokudb.new_db("sudokuDB", @sudokudb.new_logger("t"))
  assert_eq(@sudokudb.import_markdown(back, text), Ok(1))
  assert_eq(@sudokudb.SudokuDB::cell_at(back, 1).unwrap().value, original)
  // A literal backslash-t in the value must not come back as a tab.
  let db2 = @sudokudb.new_db("sudokuDB", @sudokudb.new_logger("t"))
  ignore(@sudokudb.SudokuDB::insert(db2, "esc", "a\\tb", Some(2), 0))
  let back2 = @sudokudb.new_db("sudokuDB", @sudokudb.new_logger("t"))
  assert_eq(
    @sudokudb.import_markdown(back2, @sudokudb.export_markdown(db2)),
    Ok(1),
  )
  assert_eq(@sudokudb.SudokuDB::cell_at(back2, 2).unwrap().value, "a\\tb")
}

///|
test "markdown still escapes pipes, backslashes and newlines" {
  let db = @sudokudb.new_db("sudokuDB", @sudokudb.new_logger("t"))
  let original = "a | b\\c\nd"
  ignore(@sudokudb.SudokuDB::insert(db, "mixed", original, Some(1), 0))
  let back = @sudokudb.new_db("sudokuDB", @sudokudb.new_logger("t"))
  assert_eq(
    @sudokudb.import_markdown(back, @sudokudb.export_markdown(db)),
    Ok(1),
  )
  assert_eq(@sudokudb.SudokuDB::cell_at(back, 1).unwrap().value, original)
}
