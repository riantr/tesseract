///|
/// Import and export, with round-trip fidelity as the point.
///
/// The fixtures address their cells through the lattice rather than through
/// numbers, so the export assertions below - the coordinates a record carries,
/// the position it lands on - keep describing the same three cells at any side.
fn fixture_cells(lat : @tesseract.Lattice) -> (Int64, Int64, Int64) {
  let high = lat.side - 1L
  (
    @tesseract.position_of(lat, @tesseract.coords(0L, 0L, 0L, 0L)),
    @tesseract.position_of(lat, @tesseract.coords(1L, 1L, 0L, 0L)),
    @tesseract.position_of(lat, @tesseract.coords(1L, high, 0L, high)),
  )
}

///|
fn db_with_three() -> @tesseract.Tesseract {
  let lat = @tesseract.default_lattice()
  let (first, second, third) = fixture_cells(lat)
  let db = @tesseract.new_db("tesseract", lat, @tesseract.new_logger("t"))
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "user_001",
      "{\"age\": 25}",
      Some(first),
      1L,
    ),
  )
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "user_002",
      "{\"age\": 30}",
      Some(second),
      0L,
    ),
  )
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "book, one",
      "a | b\nc",
      Some(third),
      lat.side,
    ),
  )
  db
}

///|
/// A value with a character outside the basic plane survives the export.
///
/// A value is an opaque blob that has to come back as it went in, and an
/// emoji is two code units and one character. Copying the halves apart turned
/// every emoji in a value into two question marks — in the `.tsr` JSON, in
/// the `.md` table and in the `.sql` dump alike.
test "a value with a character outside the basic plane survives the export" {
  let lat = @tesseract.default_lattice()
  let (first, _, _) = fixture_cells(lat)
  let db = @tesseract.new_db("tesseract", lat, @tesseract.new_logger("t"))
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "emoji",
      "🍎 and 苹果",
      Some(first),
      1L,
    ),
  )
  // The `.tsr` JSON, which is the native format.
  let tsr = @tesseract.export_tsr(db)
  assert_true(tsr.contains("🍎 and 苹果"))
  let dst = @tesseract.new_db("tesseract", lat, @tesseract.new_logger("t"))
  assert_eq(@tesseract.import_tsr(dst, tsr), Ok(1L))
  // The value is the same one, not a mangled copy of it.
  let rows = @tesseract.Tesseract::select(
    dst,
    "",
    "",
    None,
    @tesseract.no_filter(),
    None,
  )
  assert_eq(rows.data[0].value, "🍎 and 苹果")
  // The `.md` table and the `.sql` dump carry it too.
  assert_true(@tesseract.export_markdown(db).contains("🍎 and 苹果"))
  let sql = @tesseract.export_sql(db)
  assert_true(sql.contains("🍎 and 苹果"))
  let back = @tesseract.new_db("tesseract", lat, @tesseract.new_logger("t"))
  ignore(@tesseract.import_sql(back, sql))
  assert_eq(
    @tesseract.Tesseract::cell_at(back, first).unwrap().value,
    "🍎 and 苹果",
  )
}

///|
test "tsr round trip does not depend on how much was logged beforehand" {
  let lat = @tesseract.default_lattice()
  let src = db_with_three()
  let text = @tesseract.export_tsr(src)
  // A destination with a completely different logging history. The stamps used
  // to be re-derived from the logger counter on import, so this comparison only
  // held while both sides happened to be at the same sequence number - which
  // is exactly the condition the fixture above arranges and nothing enforces.
  let dst = @tesseract.new_db("tesseract", lat, @tesseract.new_logger("t"))
  for p in [7L, 8L, 9L, 10L, 11L] {
    ignore(@tesseract.Tesseract::insert(dst, "noise", "x", Some(p), 0L))
  }
  ignore(@tesseract.Tesseract::delete(dst, "", None))
  assert_eq(@tesseract.import_tsr(dst, text), Ok(3L))
  assert_eq(@tesseract.export_tsr(dst), text)
}

///|
test "import_tsr clears first, so a load never merges into existing records" {
  let lat = @tesseract.default_lattice()
  let db = @tesseract.new_db("tesseract", lat, @tesseract.new_logger("t"))
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "stale",
      "left over",
      Some(lat.last_position - 21L),
      0L,
    ),
  )
  let text = @tesseract.export_tsr(db_with_three())
  assert_eq(@tesseract.import_tsr(db, text), Ok(3L))
  // `stale` is not in the file, and the load is documented to leave an empty
  // database rather than a half-overwritten one.
  assert_eq(@tesseract.Tesseract::occupancy(db), 3L)
  assert_true(db.cells[@tesseract.slot_of(lat.last_position - 21L)].key == "")
}

///|
test "import refuses a record with no usable address instead of guessing the first cell" {
  let lat = @tesseract.default_lattice()
  let db = @tesseract.new_db("tesseract", lat, @tesseract.new_logger("t"))
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "occupant",
      "was here",
      Some(lat.first_position),
      0L,
    ),
  )
  let text = "{\n  \"records\": [\n    {\"grid_position\": 999, \"coords\": \"nonsense\", \"key\": \"x\", \"value\": \"y\"}\n  ]\n}"
  let refused = match @tesseract.import_tsr(db, text) {
    Ok(_) => false
    Err(_) => true
  }
  assert_true(refused)
  // Falling back to the lattice's first position would have written `x` into that
  // cell and still reported a clean load. The clear runs first, so the refusal
  // leaves the database empty rather than half-overwritten - which is what this
  // function documents.
  assert_false(db.cells[@tesseract.slot_of(lat.first_position)].key == "x")
  assert_eq(@tesseract.Tesseract::occupancy(db), 0L)
}

///|
test "import_sql reports a script that partly failed" {
  let lat = @tesseract.default_lattice()
  let db = @tesseract.new_db("tesseract", lat, @tesseract.new_logger("t"))
  let text = "INSERT INTO tesseract (key, value) VALUES ('a', '1') AT 1;\nNOT SQL AT ALL;\n"
  // Counting only the successes reported a broken dump as a clean import, so a
  // file truncated by a stray banner line still came back Ok.
  let outcome = @tesseract.import_sql(db, text)
  match outcome {
    Ok(_) => assert_true(false)
    Err(message) => assert_true(message.contains("1 of 2"))
  }
}

///|
test "lattice view shows the digit, not a truncated key" {
  let lat = @tesseract.default_lattice()
  let db = db_with_three()
  let view = @tesseract.render_lattice(db, lat.first_position)
  // Keys like `cell_1` are 6 characters, so appending the digit and then
  // ellipsizing to 6 columns cut the digit off again - every solved cell used
  // to render as `cell_~`.
  let db2 = @tesseract.new_db("tesseract", lat, @tesseract.new_logger("t"))
  ignore(
    @tesseract.Tesseract::insert(
      db2,
      "cell_1",
      "{\"pos\": 1}",
      Some(lat.first_position),
      lat.side,
    ),
  )
  let view2 = @tesseract.render_lattice(db2, lat.first_position)
  assert_false(view2.contains("cell_~"))
  // The key gives up one column to the digit: `ellipsize` spends 5 on `cell_1`
  // and the digit is appended after it.
  assert_true(view2.contains("cell~" + lat.side.to_string()))
  ignore(view)
}

///|
test "tsr export carries every record with its coordinates" {
  let lat = @tesseract.default_lattice()
  let (_, _, third) = fixture_cells(lat)
  let db = db_with_three()
  let text = @tesseract.export_tsr(db)
  assert_true(text.contains("\"total_cells\": " + lat.total.to_string()))
  assert_true(text.contains("\"dimensions\": " + @tesseract.DIM.to_string()))
  assert_true(
    text.contains(
      "\"coords\": \"" +
      @tesseract.format_coords(@tesseract.coords(1L, 1L, 0L, 0L)) +
      "\"",
    ),
  )
  assert_true(text.contains("\"grid_position\": " + third.to_string()))
  assert_true(text.contains("\"digit\": " + lat.side.to_string()))
  // The comma and pipe in the value must survive escaping.
  assert_true(text.contains("book, one"))
}

///|
test "tsr round-trips content, position and digit" {
  let lat = @tesseract.default_lattice()
  let (first, second, third) = fixture_cells(lat)
  let src = db_with_three()
  let text = @tesseract.export_tsr(src)
  let dst = @tesseract.new_db("tesseract", lat, @tesseract.new_logger("t"))
  let loaded = match @tesseract.import_tsr(dst, text) {
    Ok(n) => n
    Err(e) => {
      fail("import_tsr failed: " + e)
      0L
    }
  }
  assert_eq(loaded, 3L)
  assert_eq(@tesseract.Tesseract::occupancy(dst), 3L)
  let a = @tesseract.Tesseract::cell_at(dst, first).unwrap()
  assert_eq(a.key, "user_001")
  assert_eq(a.digit, 1L)
  let b = @tesseract.Tesseract::cell_at(dst, second).unwrap()
  assert_eq(b.key, "user_002")
  assert_eq(b.digit, 0L)
  let c = @tesseract.Tesseract::cell_at(dst, third).unwrap()
  assert_eq(c.key, "book, one")
  assert_eq(c.value, "a | b\nc")
  assert_eq(c.digit, lat.side)
  // Re-exporting the copy must reproduce the original document.
  assert_eq(@tesseract.export_tsr(dst), text)
}

///|
test "a malformed tsr is reported, not half-loaded" {
  let lat = @tesseract.default_lattice()
  let db = @tesseract.new_db("t", lat, @tesseract.new_logger("t"))
  assert_eq(@tesseract.import_tsr(db, "{not json"), Err("Not valid JSON"))
  assert_eq(
    @tesseract.import_tsr(db, "{\"other\": 1}"),
    Err("Missing records array"),
  )
  assert_eq(@tesseract.Tesseract::occupancy(db), 0L)
}

///|
test "markdown export and import round-trip" {
  let lat = @tesseract.default_lattice()
  let (_, _, third) = fixture_cells(lat)
  let src = db_with_three()
  let text = @tesseract.export_markdown(src)
  assert_true(
    text.contains("| 位置 | 坐标 | Key | Value | 数 | 时间戳 |"),
  )
  // The shape line is written from the lattice, so it cannot describe a lattice
  // the database does not have.
  assert_true(text.contains(@tesseract.lattice_shape_text(lat)))
  let dst = @tesseract.new_db("copy", lat, @tesseract.new_logger("t"))
  let loaded = match @tesseract.import_markdown(dst, text) {
    Ok(n) => n
    Err(e) => {
      fail("import_markdown failed: " + e)
      0
    }
  }
  assert_eq(loaded, 3)
  let c = @tesseract.Tesseract::cell_at(dst, third).unwrap()
  assert_eq(c.key, "book, one")
  assert_eq(c.value, "a | b\nc")
}

///|
test "the C# markdown header still loads" {
  let lat = @tesseract.default_lattice()
  let db = @tesseract.new_db("t", lat, @tesseract.new_logger("t"))
  let md = "| 位置 | Key | Value | 时间戳 |\n|------|-----|-------|--------|\n| 5 | legacy | v1 | 2024-01-01 |\n"
  let loaded = match @tesseract.import_markdown(db, md) {
    Ok(n) => n
    Err(_) => -1
  }
  assert_eq(loaded, 1)
  assert_eq(@tesseract.Tesseract::cell_at(db, 5L).unwrap().key, "legacy")
}

///|
test "sql export round-trips through the parser" {
  let lat = @tesseract.default_lattice()
  let (first, _, third) = fixture_cells(lat)
  let src = db_with_three()
  let text = @tesseract.export_sql(src)
  assert_true(text.contains("CREATE DATABASE tesseract;"))
  assert_true(
    text.contains(
      "AT " + @tesseract.format_coords(@tesseract.coords(1L, 1L, 0L, 0L)) + ";",
    ),
  )
  let dst = @tesseract.new_db("copy", lat, @tesseract.new_logger("t"))
  let ok = match @tesseract.import_sql(dst, text) {
    Ok(n) => n
    Err(e) => {
      fail("import_sql failed: " + e)
      0
    }
  }
  assert_eq(ok, 4)
  assert_eq(@tesseract.Tesseract::occupancy(dst), 3L)
  assert_eq(@tesseract.Tesseract::cell_at(dst, first).unwrap().digit, 1L)
  assert_eq(@tesseract.Tesseract::cell_at(dst, third).unwrap().key, "book, one")
}

///|
test "the C# sql dialect with backticks and timestamp still loads" {
  let lat = @tesseract.default_lattice()
  let db = @tesseract.new_db("t", lat, @tesseract.new_logger("t"))
  let dump = "INSERT INTO tesseract (grid_position, `key`, `value`, timestamp) VALUES (7, 'legacy', 'v1', '2024-01-01');"
  let ok = match @tesseract.import_sql(db, dump) {
    Ok(n) => n
    Err(_) => -1
  }
  assert_eq(ok, 1)
  assert_eq(@tesseract.Tesseract::cell_at(db, 7L).unwrap().key, "legacy")
}

///|
test "a value containing a quote round-trips through sql" {
  let lat = @tesseract.default_lattice()
  let src = @tesseract.new_db("t", lat, @tesseract.new_logger("t"))
  ignore(
    @tesseract.Tesseract::insert(src, "q", "it's \"quoted\"", Some(3L), 0L),
  )
  let text = @tesseract.export_sql(src)
  let dst = @tesseract.new_db("c", lat, @tesseract.new_logger("t"))
  ignore(@tesseract.import_sql(dst, text))
  assert_eq(
    @tesseract.Tesseract::cell_at(dst, 3L).unwrap().value,
    "it's \"quoted\"",
  )
}

///|
test "statement splitting respects semicolons inside literals" {
  let lat = @tesseract.default_lattice()
  let db = @tesseract.new_db("t", lat, @tesseract.new_logger("t"))
  let script = "INSERT INTO tesseract (key, value) VALUES ('a', 'x;y') AT 2;\nINSERT INTO tesseract (key, value) VALUES ('b', 'z') AT 4;\n"
  let ok = match @tesseract.import_sql(db, script) {
    Ok(n) => n
    Err(_) => -1
  }
  assert_eq(ok, 2)
  assert_eq(@tesseract.Tesseract::cell_at(db, 2L).unwrap().value, "x;y")
}

///|
test "the lattice view names every cell once" {
  let lat = @tesseract.default_lattice()
  let db = @tesseract.new_db("t", lat, @tesseract.new_logger("t"))
  ignore(@tesseract.Tesseract::insert(db, "k", "v", Some(41L), 0L))
  let view = @tesseract.render_lattice(db, 41L)
  // One header plus one line per y value for each x section, then the legend,
  // then the empty field the trailing newline leaves behind: `side` sections of
  // `1 + side` lines, plus two.
  assert_eq(
    @tesseract.split(view, "\n").length().to_int64(),
    lat.side * lat.side + lat.side + 2L,
  )
  assert_true(view.contains("x = 0"))
  assert_true(view.contains("x = 1"))
  assert_true(view.contains("x = 2"))
  assert_true(view.contains(">"))
  assert_true(view.contains("k"))
}

///|
test "markdown round-trips tab and carriage return" {
  let lat = @tesseract.default_lattice()
  let db = @tesseract.new_db("tesseract", lat, @tesseract.new_logger("t"))
  // TAB used to be written as four spaces and CR dropped outright, so the value
  // came back as a different string - a one-way corruption that only `.tsr` and
  // `.sql` avoided.
  let original = "a\tb\rc"
  ignore(@tesseract.Tesseract::insert(db, "tabs", original, Some(1L), 0L))
  let text = @tesseract.export_markdown(db)
  let back = @tesseract.new_db("tesseract", lat, @tesseract.new_logger("t"))
  assert_eq(@tesseract.import_markdown(back, text), Ok(1))
  assert_eq(@tesseract.Tesseract::cell_at(back, 1L).unwrap().value, original)
  // A literal backslash-t in the value must not come back as a tab.
  let db2 = @tesseract.new_db("tesseract", lat, @tesseract.new_logger("t"))
  ignore(@tesseract.Tesseract::insert(db2, "esc", "a\\tb", Some(2L), 0L))
  let back2 = @tesseract.new_db("tesseract", lat, @tesseract.new_logger("t"))
  assert_eq(
    @tesseract.import_markdown(back2, @tesseract.export_markdown(db2)),
    Ok(1),
  )
  assert_eq(@tesseract.Tesseract::cell_at(back2, 2L).unwrap().value, "a\\tb")
}

///|
test "markdown still escapes pipes, backslashes and newlines" {
  let lat = @tesseract.default_lattice()
  let db = @tesseract.new_db("tesseract", lat, @tesseract.new_logger("t"))
  let original = "a | b\\c\nd"
  ignore(@tesseract.Tesseract::insert(db, "mixed", original, Some(1L), 0L))
  let back = @tesseract.new_db("tesseract", lat, @tesseract.new_logger("t"))
  assert_eq(
    @tesseract.import_markdown(back, @tesseract.export_markdown(db)),
    Ok(1),
  )
  assert_eq(@tesseract.Tesseract::cell_at(back, 1L).unwrap().value, original)
}

///|
/// A lattice pair that differs in size, for the cross-side tests below.
fn side_pair() -> (@tesseract.Lattice, @tesseract.Lattice) {
  let three = @tesseract.default_lattice()
  let four = @tesseract.lattice_of(4L).unwrap()
  (three, four)
}

///|
/// Import places a record by the COORDINATES the file carries, not by the
/// position number it was written with.
///
/// This is the whole point of the cross-side import rule, and it is the one
/// behaviour a round-trip test on a single side cannot see: both sides of such a
/// test share one lattice, so both position numbers agree and the two candidate
/// rules are indistinguishable.
///
/// The negative half is what gives the test teeth. `cell_at(dst, 41L)` is
/// asserted *empty*, so a resolver that quietly fell back to the position number
/// - which is in range at side 4, and which would have "worked" - fails here
/// instead of passing.
test "a side-3 file imported into a side-4 database lands on its coordinates, not its position number" {
  let (three, four) = side_pair()
  let cell = @tesseract.coords(1L, 1L, 1L, 1L)
  let src = @tesseract.new_db("tesseract", three, @tesseract.new_logger("t"))
  let written_at = @tesseract.position_of(three, cell)
  ignore(
    @tesseract.Tesseract::insert(src, "moved", "payload", Some(written_at), 0L),
  )
  let text = @tesseract.export_tsr(src)
  let dst = @tesseract.new_db("tesseract", four, @tesseract.new_logger("t"))
  assert_eq(@tesseract.import_tsr(dst, text), Ok(1L))
  let expected = @tesseract.position_of(four, cell)
  // The two numbers are different, which is what makes this test mean anything.
  assert_true(expected != written_at)
  assert_eq(@tesseract.Tesseract::cell_at(dst, expected).unwrap().key, "moved")
  // `cell_at` answers `Some` for every in-range position, occupied or not, so
  // "the record is not here" is an emptiness check, not a presence check.
  assert_true(
    @tesseract.cell_is_empty(
      @tesseract.Tesseract::cell_at(dst, written_at).unwrap(),
    ),
  )
  assert_eq(@tesseract.Tesseract::occupancy(dst), 1L)
}

///|
/// The scale of the trap, pinned as a number rather than an anecdote.
///
/// 78 of the 81 positions in a 3-per-axis lattice name a *different cell* once
/// the side is 4. Had the resolver used position numbers, 78 of 81 records would
/// have moved while the load still reported success. If this assertion ever fails
/// the arithmetic above changed, and the prose in `resolve_import_position` and
/// in LOOP.md has to change with it.
test "78 of the 81 side-3 positions name a different cell at side 4" {
  let (three, four) = side_pair()
  let mut moved = 0L
  let mut p = three.first_position
  while p <= three.last_position {
    let c = @tesseract.coords_of(three, p).unwrap()
    if @tesseract.position_of(four, c) != p {
      moved = moved + 1L
    }
    p = p + 1L
  }
  assert_eq(moved, 78L)
}

///|
/// A coordinate the target lattice cannot hold is refused, by name.
///
/// Clamping it would put the record in a cell the file never mentioned and still
/// report a successful load; falling back to the position number would do the
/// same by a different route. Both are worse than an error that says what was
/// wrong.
test "a coordinate outside the target lattice is refused and named, never clamped" {
  let three = @tesseract.default_lattice()
  let two = @tesseract.lattice_of(2L).unwrap()
  let cell = @tesseract.coords(2L, 2L, 2L, 2L)
  let src = @tesseract.new_db("tesseract", three, @tesseract.new_logger("t"))
  ignore(
    @tesseract.Tesseract::insert(
      src,
      "toobig",
      "x",
      Some(@tesseract.position_of(three, cell)),
      0L,
    ),
  )
  let text = @tesseract.export_tsr(src)
  let dst = @tesseract.new_db("tesseract", two, @tesseract.new_logger("t"))
  match @tesseract.import_tsr(dst, text) {
    Ok(n) => {
      assert_true(false)
      ignore(n)
    }
    Err(message) => {
      assert_true(message.contains("(2,2,2,2)"))
      assert_true(message.contains("side-2"))
    }
  }
  assert_eq(@tesseract.Tesseract::occupancy(dst), 0L)
}

///|
/// The header the export writes is the database's own shape, read back.
///
/// `"side": 3` was a literal in the export, so a side-4 database described
/// itself as a side-3 one and the importer had nothing to cross-check against.
test "the tsr header describes the database that produced it" {
  let (_, four) = side_pair()
  let db = @tesseract.new_db("tesseract", four, @tesseract.new_logger("t"))
  let text = @tesseract.export_tsr(db)
  assert_true(text.contains("\"side\": 4"))
  assert_true(text.contains("\"total_cells\": 256"))
  assert_true(text.contains("\"dimensions\": 4"))
}
