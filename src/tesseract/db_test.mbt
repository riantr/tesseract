///| Store behaviour, including the places where the 4D port deliberately

///| departs from the C# model.

///|
/// A fresh database with a silent logger.
fn fresh() -> @tesseract.Tesseract {
  @tesseract.new_db("test", @tesseract.new_logger("test"))
}

///|
test "a new database is 81 empty cells with the cursor at 1" {
  let db = fresh()
  let s = @tesseract.Tesseract::status(db)
  assert_eq(s.total_cells, 81)
  assert_eq(s.current_count, 0)
  assert_eq(s.current_position, 1)
  assert_eq(s.digit_count, 0)
  assert_eq(@tesseract.Tesseract::occupancy(db), 0)
  assert_eq(@tesseract.Tesseract::cell_at(db, 81).unwrap().key, "")
}

///|
test "insert without a target follows the cursor and advances it" {
  let db = fresh()
  let r = @tesseract.Tesseract::insert(db, "a", "1", None, 0)
  assert_true(r.success)
  assert_eq(r.position, 1)
  assert_eq(@tesseract.Tesseract::status(db).current_position, 2)
  ignore(@tesseract.Tesseract::insert(db, "b", "2", None, 0))
  assert_eq(@tesseract.Tesseract::status(db).current_position, 3)
  assert_eq(@tesseract.Tesseract::cell_at(db, 1).unwrap().key, "a")
  assert_eq(@tesseract.Tesseract::cell_at(db, 2).unwrap().key, "b")
}

///|
test "insert with an explicit target leaves the cursor alone" {
  let db = fresh()
  let r = @tesseract.Tesseract::insert(db, "a", "1", Some(42), 0)
  assert_eq(r.position, 42)
  assert_eq(@tesseract.Tesseract::status(db).current_position, 1)
  assert_eq(@tesseract.Tesseract::cell_at(db, 42).unwrap().key, "a")
}

///|
test "the cursor wraps after 81 cyclic inserts" {
  let db = fresh()
  let mut i = 0
  while i < 81 {
    ignore(@tesseract.Tesseract::insert(db, "k" + i.to_string(), "v", None, 0))
    i = i + 1
  }
  assert_eq(@tesseract.Tesseract::status(db).current_position, 1)
  assert_eq(@tesseract.Tesseract::occupancy(db), 81)
  ignore(@tesseract.Tesseract::insert(db, "wrap", "v", None, 0))
  assert_eq(@tesseract.Tesseract::cell_at(db, 1).unwrap().key, "wrap")
  assert_eq(@tesseract.Tesseract::occupancy(db), 81)
}

///|
test "empty key or value is rejected with INVALID_INPUT" {
  let db = fresh()
  assert_eq(
    @tesseract.Tesseract::insert(db, "", "v", None, 0).error_code,
    "INVALID_INPUT",
  )
  assert_eq(
    @tesseract.Tesseract::insert(db, "k", "", None, 0).error_code,
    "INVALID_INPUT",
  )
  assert_eq(@tesseract.Tesseract::occupancy(db), 0)
}

///|
test "out-of-range positions and digits are rejected" {
  let db = fresh()
  assert_eq(
    @tesseract.Tesseract::insert(db, "k", "v", Some(82), 0).error_code,
    "INVALID_POSITION",
  )
  assert_eq(
    @tesseract.Tesseract::insert(db, "k", "v", Some(0), 0).error_code,
    "INVALID_POSITION",
  )
  assert_eq(
    @tesseract.Tesseract::insert(db, "k", "v", None, 4).error_code,
    "INVALID_DIGIT",
  )
}

///|
test "occupancy stays truthful across a wrap and a delete" {
  // The C# counter saturated at 9 on the first wrap and then only decremented,
  // so it drifted below the real number of stored records.
  let db = fresh()
  let mut i = 0
  while i < 90 {
    ignore(@tesseract.Tesseract::insert(db, "k" + i.to_string(), "v", None, 0))
    i = i + 1
  }
  assert_eq(@tesseract.Tesseract::occupancy(db), 81)
  // After 90 cyclic inserts the ring has wrapped: positions 1..9 now hold
  // k81..k89, so k0 and k1 no longer exist and deleting them must miss.
  assert_eq(
    @tesseract.Tesseract::delete(db, "k0", None).error_code,
    "KEY_NOT_FOUND",
  )
  ignore(@tesseract.Tesseract::delete(db, "k81", None))
  ignore(@tesseract.Tesseract::delete(db, "k10", None))
  assert_eq(@tesseract.Tesseract::occupancy(db), 79)
  assert_eq(@tesseract.Tesseract::status(db).current_count, 79)
}

///|
test "select by key returns every cell carrying it, and the position filter reaches any of them" {
  let db = fresh()
  ignore(@tesseract.Tesseract::insert(db, "k", "1", Some(1), 0))
  ignore(@tesseract.Tesseract::insert(db, "k", "2", Some(2), 0))
  let all = @tesseract.Tesseract::select(
    db,
    "k",
    "",
    None,
    @tesseract.no_filter(),
    None,
  )
  // Keys are not unique. `find_all_by_key` returns every cell carrying one and
  // `delete` with a bare key removes every cell carrying one, so a SELECT that
  // stopped at the first hit disagreed with both of them - and made
  // `WHERE key='k' AND grid_position=2` unreachable.
  assert_eq(all.total_records, 2)
  assert_eq(all.data[0].position, 1)
  assert_eq(all.data[1].position, 2)
  let second = @tesseract.Tesseract::select(
    db,
    "k",
    "",
    Some(2),
    @tesseract.no_filter(),
    None,
  )
  assert_eq(second.total_records, 1)
  assert_eq(second.data[0].position, 2)
}

///|
test "select by key intersects with the value pattern instead of ignoring it" {
  let db = fresh()
  ignore(@tesseract.Tesseract::insert(db, "k", "alpha", Some(1), 0))
  ignore(@tesseract.Tesseract::insert(db, "k", "beta", Some(2), 0))
  let r = @tesseract.Tesseract::select(
    db,
    "k",
    "%alp%",
    None,
    @tesseract.no_filter(),
    None,
  )
  // Both conditions hold on the same row; the pattern was previously only
  // consulted when no key was given at all. `%...%` is what makes this a
  // contains test - `select`'s pattern is a LIKE pattern, not a substring.
  assert_eq(r.total_records, 1)
  assert_eq(r.data[0].value, "alpha")
}

///|
test "update refuses a position whose cell carries a different key" {
  let db = fresh()
  ignore(@tesseract.Tesseract::insert(db, "a", "1", Some(1), 0))
  ignore(@tesseract.Tesseract::insert(db, "b", "2", Some(5), 0))
  // `WHERE key='a' AND grid_position=5` names two conditions. Taking only the
  // position overwrote record b silently; `delete` already refused this.
  let r = @tesseract.Tesseract::update(db, "a", "X", Some(5), None)
  assert_false(r.success)
  assert_eq(r.error_code, "KEY_NOT_FOUND")
  assert_eq(db.cells[4].value, "2")
}

///|
test "select by key with a mismatched position returns nothing" {
  let db = fresh()
  ignore(@tesseract.Tesseract::insert(db, "k", "1", Some(1), 0))
  let r = @tesseract.Tesseract::select(
    db,
    "k",
    "",
    Some(9),
    @tesseract.no_filter(),
    None,
  )
  assert_eq(r.total_records, 0)
  let hit = @tesseract.Tesseract::select(
    db,
    "k",
    "",
    Some(1),
    @tesseract.no_filter(),
    None,
  )
  assert_eq(hit.total_records, 1)
}

///|
test "select by pattern is case-insensitive and value-based" {
  let db = fresh()
  ignore(@tesseract.Tesseract::insert(db, "a", "Hello World", Some(1), 0))
  ignore(@tesseract.Tesseract::insert(db, "b", "goodbye", Some(2), 0))
  let r = @tesseract.Tesseract::select(
    db,
    "",
    "%LO WO%",
    None,
    @tesseract.no_filter(),
    None,
  )
  assert_eq(r.total_records, 1)
  assert_eq(r.data[0].key, "a")
}

///|
test "an unwrapped LIKE pattern is equality, not a match-everything wildcard" {
  let db = fresh()
  ignore(@tesseract.Tesseract::insert(db, "a", "hello", Some(1), 0))
  ignore(@tesseract.Tesseract::insert(db, "b", "goodbye", Some(2), 0))
  // A bare literal used to be stripped to "" and "" meant "no predicate", so it
  // matched every row. Returning more than was asked for is the direction that
  // hides a problem.
  let exact = @tesseract.Tesseract::select(
    db,
    "",
    "hello",
    None,
    @tesseract.no_filter(),
    None,
  )
  assert_eq(exact.total_records, 1)
  assert_eq(exact.data[0].key, "a")
  assert_false(@tesseract.like_matches("goodbye", "hello"))
  assert_true(@tesseract.like_matches("say hello now", "%hello%"))
  // `%%` is a real pattern — a value containing a literal `%` — not "no LIKE".
  assert_true(@tesseract.like_matches("100%", "%%"))
}

///|
test "select with no filter returns only occupied cells" {
  let db = fresh()
  ignore(@tesseract.Tesseract::insert(db, "a", "1", Some(3), 0))
  ignore(@tesseract.Tesseract::insert(db, "b", "2", Some(40), 0))
  let r = @tesseract.Tesseract::select(
    db,
    "",
    "",
    None,
    @tesseract.no_filter(),
    None,
  )
  assert_eq(r.total_records, 2)
}

///|
test "coordinate filters narrow to the right cells" {
  let db = fresh()
  ignore(@tesseract.Tesseract::insert(db, "a", "1", Some(1), 0))
  ignore(@tesseract.Tesseract::insert(db, "b", "2", Some(28), 0))
  ignore(@tesseract.Tesseract::insert(db, "c", "3", Some(81), 0))
  let x0 = @tesseract.coord_filter(0, -1, -1, -1)
  let r = @tesseract.Tesseract::select(db, "", "", None, x0, None)
  assert_eq(r.total_records, 1)
  assert_eq(r.data[0].key, "a")
  let x2 = @tesseract.coord_filter(2, -1, -1, -1)
  let r2 = @tesseract.Tesseract::select(db, "", "", None, x2, None)
  assert_eq(r2.total_records, 1)
  assert_eq(r2.data[0].key, "c")
}

///|
test "update by key and by position both work, and miss cleanly" {
  let db = fresh()
  ignore(@tesseract.Tesseract::insert(db, "a", "1", Some(5), 0))
  let by_key = @tesseract.Tesseract::update(db, "a", "9", None, None)
  assert_true(by_key.success)
  assert_eq(by_key.position, 5)
  assert_eq(@tesseract.Tesseract::cell_at(db, 5).unwrap().value, "9")
  let by_pos = @tesseract.Tesseract::update(db, "", "8", Some(5), None)
  assert_true(by_pos.success)
  assert_eq(@tesseract.Tesseract::cell_at(db, 5).unwrap().value, "8")
  assert_eq(
    @tesseract.Tesseract::update(db, "nope", "x", None, None).error_code,
    "KEY_NOT_FOUND",
  )
  assert_eq(
    @tesseract.Tesseract::update(db, "", "x", Some(77), None).error_code,
    "POSITION_NOT_FOUND",
  )
  assert_eq(
    @tesseract.Tesseract::update(db, "", "x", Some(999), None).error_code,
    "POSITION_OUT_OF_RANGE",
  )
}

///|
test "delete by key removes every cell carrying it" {
  let db = fresh()
  ignore(@tesseract.Tesseract::insert(db, "dup", "1", Some(3), 0))
  ignore(@tesseract.Tesseract::insert(db, "dup", "2", Some(9), 0))
  ignore(@tesseract.Tesseract::insert(db, "dup", "3", Some(27), 0))
  ignore(@tesseract.Tesseract::insert(db, "keep", "1", Some(4), 0))
  let r = @tesseract.Tesseract::delete(db, "dup", None)
  assert_true(r.success)
  assert_eq(r.affected_rows, 3)
  assert_eq(@tesseract.Tesseract::occupancy(db), 1)
  assert_eq(
    @tesseract.Tesseract::delete(db, "dup", None).error_code,
    "KEY_NOT_FOUND",
  )
}

///|
test "delete by position, and full clear resetting the cursor" {
  let db = fresh()
  ignore(@tesseract.Tesseract::insert(db, "a", "1", Some(7), 0))
  ignore(@tesseract.Tesseract::insert(db, "b", "2", Some(8), 0))
  let r = @tesseract.Tesseract::delete(db, "", Some(7))
  assert_true(r.success)
  assert_eq(r.affected_rows, 1)
  assert_eq(
    @tesseract.Tesseract::delete(db, "", Some(7)).error_code,
    "POSITION_EMPTY",
  )
  @tesseract.Tesseract::set_position(db, 40)
  let cleared = @tesseract.Tesseract::delete(db, "", None)
  assert_true(cleared.success)
  assert_eq(@tesseract.Tesseract::occupancy(db), 0)
  assert_eq(@tesseract.Tesseract::status(db).current_position, 1)
  assert_eq(cleared.affected_rows, 0)
}

///|
test "a digit cannot collide with a cell sharing its line" {
  let db = fresh()
  // (0,0,0,0) = position 1; (0,0,0,2) = position 3 share the w-line.
  let ok = @tesseract.Tesseract::insert(db, "a", "1", Some(1), 1)
  assert_true(ok.success)
  let clash = @tesseract.Tesseract::insert(db, "b", "2", Some(3), 1)
  assert_false(clash.success)
  assert_eq(clash.error_code, "SUDOKU_CONFLICT")
  // A different digit on a peer cell is fine.
  let fine = @tesseract.Tesseract::insert(db, "b", "2", Some(3), 2)
  assert_true(fine.success)
  // A non-peer cell may reuse digit 1. Position 37 is (1,1,0,0), which differs
  // from (0,0,0,0) along two axes and so shares no line with it.
  let away = @tesseract.Tesseract::insert(db, "c", "3", Some(37), 1)
  assert_true(away.success)
  assert_eq(@tesseract.Tesseract::digit_count(db), 3)
  // Position 28 is (1,0,0,0): one step along x from position 1, so it *is* a
  // peer and digit 1 is refused there.
  let peer_again = @tesseract.Tesseract::insert(db, "d", "4", Some(28), 1)
  assert_false(peer_again.success)
  assert_eq(peer_again.error_code, "SUDOKU_CONFLICT")
}

///|
test "a rejected insert leaves the cell untouched" {
  let db = fresh()
  ignore(@tesseract.Tesseract::insert(db, "a", "1", Some(1), 1))
  ignore(@tesseract.Tesseract::insert(db, "b", "2", Some(3), 1))
  assert_eq(@tesseract.Tesseract::cell_at(db, 3).unwrap().key, "")
  assert_eq(@tesseract.Tesseract::occupancy(db), 1)
}

///|
test "setting a digit through update is conflict-checked too" {
  let db = fresh()
  ignore(@tesseract.Tesseract::insert(db, "a", "1", Some(1), 1))
  ignore(@tesseract.Tesseract::insert(db, "b", "2", Some(3), 0))
  let bad = @tesseract.Tesseract::update(db, "b", "2", Some(3), Some(1))
  assert_false(bad.success)
  assert_eq(bad.error_code, "SUDOKU_CONFLICT")
  let good = @tesseract.Tesseract::update(db, "b", "2", Some(3), Some(3))
  assert_true(good.success)
  assert_eq(@tesseract.Tesseract::cell_at(db, 3).unwrap().digit, 3)
}

///|
test "line, slab and peer queries return the right neighbourhoods" {
  let db = fresh()
  ignore(@tesseract.Tesseract::insert(db, "a", "1", Some(1), 0))
  ignore(@tesseract.Tesseract::insert(db, "b", "2", Some(3), 0))
  ignore(@tesseract.Tesseract::insert(db, "c", "3", Some(28), 0))
  let line = @tesseract.Tesseract::line_query(db, 1, 3)
  assert_eq(line.total_records, 2)
  // Slab on axis 0 fixes x = 0, which holds positions 1 and 3 but not 28.
  let slab = @tesseract.Tesseract::slab_query(db, 1, 0)
  assert_eq(slab.total_records, 2)
  // Slab on axis 0 fixing x = 1 holds only position 28.
  let slab_x1 = @tesseract.Tesseract::slab_query(db, 28, 0)
  assert_eq(slab_x1.total_records, 1)
  // Peers of (0,0,0,0) are one step along each axis: positions 2, 3, 4, 7,
  // 10, 19, 28 and 55. Two of them are occupied here.
  let peers = @tesseract.Tesseract::peer_query(db, 1)
  assert_eq(peers.total_records, 2)
  assert_eq(
    @tesseract.Tesseract::line_query(db, 99, 0).error_code,
    "POSITION_OUT_OF_RANGE",
  )
}

///|
test "the logger keeps at most 100 entries" {
  let db = fresh()
  let mut i = 0
  while i < 150 {
    ignore(
      @tesseract.Tesseract::insert(
        db,
        "k" + i.to_string(),
        "v",
        Some(i % 80 + 1),
        0,
      ),
    )
    i = i + 1
  }
  let entries = @tesseract.TesseractLogger::entries(
    @tesseract.Tesseract::get_logger(db),
  )
  assert_eq(entries.length(), 100)
  // Stamps stay strictly increasing even after trimming.
  let mut ascending = true
  let mut k = 1
  while k < entries.length() {
    if entries[k].seq <= entries[k - 1].seq {
      ascending = false
    }
    k = k + 1
  }
  assert_true(ascending)
}
