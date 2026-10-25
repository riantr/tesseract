///| Store behaviour, including the places where the 4D port deliberately

///| departs from the C# model.
///

///| Every shape number these tests quote - the cell count, the out-of-range

///| position, the cells that share a line - is read off the lattice rather than

///| written as a literal, so the same assertions keep their meaning at any side

///| instead of silently describing a 3-per-axis world.

///|
/// A fresh database with a silent logger.
fn fresh() -> @tesseract.Tesseract {
  @tesseract.new_db(
    "test",
    @tesseract.default_lattice(),
    @tesseract.new_logger("test"),
  )
}

///|
/// The cells these tests address by number, named through the lattice.
///
/// The four positions below are the ones whose *relationship* is what the
/// assertions are about, so they are derived rather than picked: the origin, the
/// far end of its w-line, a cell two steps away that shares no line with it, and
/// a cell one step along x that is therefore a peer.
fn geometry(lat : @tesseract.Lattice) -> (Int64, Int64, Int64, Int64) {
  (
    @tesseract.position_of(lat, @tesseract.coords(0L, 0L, 0L, 0L)),
    @tesseract.position_of(lat, @tesseract.coords(0L, 0L, 0L, lat.side() - 1L)),
    @tesseract.position_of(lat, @tesseract.coords(1L, 1L, 0L, 0L)),
    @tesseract.position_of(lat, @tesseract.coords(1L, 0L, 0L, 0L)),
  )
}

///|
test "a new database is a whole lattice of empty cells with the cursor at 1" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  let s = @tesseract.Tesseract::status(db)
  assert_eq(s.total_cells, lat.total())
  assert_eq(s.current_count, 0L)
  assert_eq(s.current_position, lat.first_position())
  assert_eq(s.digit_count, 0L)
  assert_eq(@tesseract.Tesseract::occupancy(db), 0L)
  assert_eq(
    @tesseract.Tesseract::cell_at(db, lat.last_position()).unwrap().key,
    "",
  )
}

///|
test "insert without a target follows the cursor and advances it" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  let first = lat.first_position()
  let second = lat.first_position() + 1L
  let third = lat.first_position() + 2L
  let r = @tesseract.Tesseract::insert(db, "a", "1", None, 0L)
  assert_true(r.success)
  assert_eq(r.position, first)
  assert_eq(@tesseract.Tesseract::status(db).current_position, second)
  ignore(@tesseract.Tesseract::insert(db, "b", "2", None, 0L))
  assert_eq(@tesseract.Tesseract::status(db).current_position, third)
  assert_eq(@tesseract.Tesseract::cell_at(db, first).unwrap().key, "a")
  assert_eq(@tesseract.Tesseract::cell_at(db, second).unwrap().key, "b")
}

///|
test "insert with an explicit target leaves the cursor alone" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  let target = lat.first_position() + 41L
  let r = @tesseract.Tesseract::insert(db, "a", "1", Some(target), 0L)
  assert_eq(r.position, target)
  assert_eq(
    @tesseract.Tesseract::status(db).current_position,
    lat.first_position(),
  )
  assert_eq(@tesseract.Tesseract::cell_at(db, target).unwrap().key, "a")
}

///|
test "the cursor wraps after one full cycle of cyclic inserts" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  let mut i = 0L
  while i < lat.total() {
    ignore(@tesseract.Tesseract::insert(db, "k" + i.to_string(), "v", None, 0L))
    i = i + 1L
  }
  assert_eq(
    @tesseract.Tesseract::status(db).current_position,
    lat.first_position(),
  )
  assert_eq(@tesseract.Tesseract::occupancy(db), lat.total())
  ignore(@tesseract.Tesseract::insert(db, "wrap", "v", None, 0L))
  assert_eq(
    @tesseract.Tesseract::cell_at(db, lat.first_position()).unwrap().key,
    "wrap",
  )
  assert_eq(@tesseract.Tesseract::occupancy(db), lat.total())
}

///|
test "empty key or value is rejected with INVALID_INPUT" {
  let db = fresh()
  assert_eq(
    @tesseract.Tesseract::insert(db, "", "v", None, 0L).error_code,
    "INVALID_INPUT",
  )
  assert_eq(
    @tesseract.Tesseract::insert(db, "k", "", None, 0L).error_code,
    "INVALID_INPUT",
  )
  assert_eq(@tesseract.Tesseract::occupancy(db), 0L)
}

///|
test "out-of-range positions and digits are rejected" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  assert_eq(
    @tesseract.Tesseract::insert(
      db,
      "k",
      "v",
      Some(lat.last_position() + 1L),
      0L,
    ).error_code,
    "INVALID_POSITION",
  )
  assert_eq(
    @tesseract.Tesseract::insert(db, "k", "v", Some(0L), 0L).error_code,
    "INVALID_POSITION",
  )
  assert_eq(
    @tesseract.Tesseract::insert(db, "k", "v", None, lat.side() + 1L).error_code,
    "INVALID_DIGIT",
  )
}

///|
test "occupancy stays truthful across a wrap and a delete" {
  // The C# counter saturated at 9 on the first wrap and then only decremented,
  // so it drifted below the real number of stored records.
  let lat = @tesseract.default_lattice()
  let db = fresh()
  // `extra` rows past the cell count is enough to wrap the ring by nine cells.
  let extra = 9L
  let mut i = 0L
  while i < lat.total() + extra {
    ignore(@tesseract.Tesseract::insert(db, "k" + i.to_string(), "v", None, 0L))
    i = i + 1L
  }
  assert_eq(@tesseract.Tesseract::occupancy(db), lat.total())
  // After the wrap the first `extra` cells hold the last `extra` keys, so k0 and
  // k1 no longer exist and deleting them must miss.
  assert_eq(
    @tesseract.Tesseract::delete(db, "k0", None).error_code,
    "KEY_NOT_FOUND",
  )
  ignore(@tesseract.Tesseract::delete(db, "k" + lat.total().to_string(), None))
  ignore(@tesseract.Tesseract::delete(db, "k" + (extra + 1L).to_string(), None))
  assert_eq(@tesseract.Tesseract::occupancy(db), lat.total() - 2L)
  assert_eq(@tesseract.Tesseract::status(db).current_count, lat.total() - 2L)
}

///|
test "select by key returns every cell carrying it, and the position filter reaches any of them" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  let first = lat.first_position()
  let second = lat.first_position() + 1L
  ignore(@tesseract.Tesseract::insert(db, "k", "1", Some(first), 0L))
  ignore(@tesseract.Tesseract::insert(db, "k", "2", Some(second), 0L))
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
  assert_eq(all.total_records, 2L)
  assert_eq(all.data[0].position, first)
  assert_eq(all.data[1].position, second)
  let one = @tesseract.Tesseract::select(
    db,
    "k",
    "",
    Some(second),
    @tesseract.no_filter(),
    None,
  )
  assert_eq(one.total_records, 1L)
  assert_eq(one.data[0].position, second)
}

///|
test "select by key intersects with the value pattern instead of ignoring it" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  let first = lat.first_position()
  let second = lat.first_position() + 1L
  ignore(@tesseract.Tesseract::insert(db, "k", "alpha", Some(first), 0L))
  ignore(@tesseract.Tesseract::insert(db, "k", "beta", Some(second), 0L))
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
  assert_eq(r.total_records, 1L)
  assert_eq(r.data[0].value, "alpha")
}

///|
test "update refuses a position whose cell carries a different key" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  let mine = lat.first_position()
  let theirs = lat.first_position() + 4L
  ignore(@tesseract.Tesseract::insert(db, "a", "1", Some(mine), 0L))
  ignore(@tesseract.Tesseract::insert(db, "b", "2", Some(theirs), 0L))
  // `WHERE key='a' AND grid_position=5` names two conditions. Taking only the
  // position overwrote record b silently; `delete` already refused this.
  let r = @tesseract.Tesseract::update(db, "a", "X", Some(theirs), None)
  assert_false(r.success)
  assert_eq(r.error_code, "KEY_NOT_FOUND")
  assert_eq(db.cells[@tesseract.slot_of(theirs)].value, "2")
}

///|
test "select by key with a mismatched position returns nothing" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  let first = lat.first_position()
  ignore(@tesseract.Tesseract::insert(db, "k", "1", Some(first), 0L))
  let r = @tesseract.Tesseract::select(
    db,
    "k",
    "",
    Some(lat.first_position() + 8L),
    @tesseract.no_filter(),
    None,
  )
  assert_eq(r.total_records, 0L)
  let hit = @tesseract.Tesseract::select(
    db,
    "k",
    "",
    Some(first),
    @tesseract.no_filter(),
    None,
  )
  assert_eq(hit.total_records, 1L)
}

///|
test "select by pattern is case-insensitive and value-based" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "a",
      "Hello World",
      Some(lat.first_position()),
      0L,
    ),
  )
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "b",
      "goodbye",
      Some(lat.first_position() + 1L),
      0L,
    ),
  )
  let r = @tesseract.Tesseract::select(
    db,
    "",
    "%LO WO%",
    None,
    @tesseract.no_filter(),
    None,
  )
  assert_eq(r.total_records, 1L)
  assert_eq(r.data[0].key, "a")
}

///|
test "an unwrapped LIKE pattern is equality, not a match-everything wildcard" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "a",
      "hello",
      Some(lat.first_position()),
      0L,
    ),
  )
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "b",
      "goodbye",
      Some(lat.first_position() + 1L),
      0L,
    ),
  )
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
  assert_eq(exact.total_records, 1L)
  assert_eq(exact.data[0].key, "a")
  assert_false(@tesseract.like_matches("goodbye", "hello"))
  assert_true(@tesseract.like_matches("say hello now", "%hello%"))
  // `%%` is a real pattern — a value containing a literal `%` — not "no LIKE".
  assert_true(@tesseract.like_matches("100%", "%%"))
}

///|
test "select with no filter returns only occupied cells" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "a",
      "1",
      Some(lat.first_position() + 2L),
      0L,
    ),
  )
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "b",
      "2",
      Some(lat.last_position() - 41L),
      0L,
    ),
  )
  let r = @tesseract.Tesseract::select(
    db,
    "",
    "",
    None,
    @tesseract.no_filter(),
    None,
  )
  assert_eq(r.total_records, 2L)
}

///|
test "coordinate filters narrow to the right cells" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  let far = lat.side() - 1L
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "a",
      "1",
      Some(@tesseract.position_of(lat, @tesseract.coords(0L, 0L, 0L, 0L))),
      0L,
    ),
  )
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "b",
      "2",
      Some(@tesseract.position_of(lat, @tesseract.coords(1L, 0L, 0L, 0L))),
      0L,
    ),
  )
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "c",
      "3",
      Some(@tesseract.position_of(lat, @tesseract.coords(far, far, far, far))),
      0L,
    ),
  )
  let x0 = @tesseract.coord_filter(0L, -1L, -1L, -1L)
  let r = @tesseract.Tesseract::select(db, "", "", None, x0, None)
  assert_eq(r.total_records, 1L)
  assert_eq(r.data[0].key, "a")
  let x_last = @tesseract.coord_filter(far, -1L, -1L, -1L)
  let r2 = @tesseract.Tesseract::select(db, "", "", None, x_last, None)
  assert_eq(r2.total_records, 1L)
  assert_eq(r2.data[0].key, "c")
}

///|
test "update by key and by position both work, and miss cleanly" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  let target = lat.first_position() + 4L
  ignore(@tesseract.Tesseract::insert(db, "a", "1", Some(target), 0L))
  let by_key = @tesseract.Tesseract::update(db, "a", "9", None, None)
  assert_true(by_key.success)
  assert_eq(by_key.position, target)
  assert_eq(@tesseract.Tesseract::cell_at(db, target).unwrap().value, "9")
  let by_pos = @tesseract.Tesseract::update(db, "", "8", Some(target), None)
  assert_true(by_pos.success)
  assert_eq(@tesseract.Tesseract::cell_at(db, target).unwrap().value, "8")
  assert_eq(
    @tesseract.Tesseract::update(db, "nope", "x", None, None).error_code,
    "KEY_NOT_FOUND",
  )
  assert_eq(
    @tesseract.Tesseract::update(
      db,
      "",
      "x",
      Some(lat.last_position() - 4L),
      None,
    ).error_code,
    "POSITION_NOT_FOUND",
  )
  assert_eq(
    @tesseract.Tesseract::update(
      db,
      "",
      "x",
      Some(lat.last_position() + 1000L),
      None,
    ).error_code,
    "POSITION_OUT_OF_RANGE",
  )
}

///|
test "delete by key removes every cell carrying it" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "dup",
      "1",
      Some(lat.first_position() + 2L),
      0L,
    ),
  )
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "dup",
      "2",
      Some(lat.first_position() + 8L),
      0L,
    ),
  )
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "dup",
      "3",
      Some(lat.first_position() + 26L),
      0L,
    ),
  )
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "keep",
      "1",
      Some(lat.first_position() + 3L),
      0L,
    ),
  )
  let r = @tesseract.Tesseract::delete(db, "dup", None)
  assert_true(r.success)
  assert_eq(r.affected_rows, 3L)
  assert_eq(@tesseract.Tesseract::occupancy(db), 1L)
  assert_eq(
    @tesseract.Tesseract::delete(db, "dup", None).error_code,
    "KEY_NOT_FOUND",
  )
}

///|
test "delete by position, and full clear resetting the cursor" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  let target = lat.first_position() + 6L
  ignore(@tesseract.Tesseract::insert(db, "a", "1", Some(target), 0L))
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "b",
      "2",
      Some(lat.first_position() + 7L),
      0L,
    ),
  )
  let r = @tesseract.Tesseract::delete(db, "", Some(target))
  assert_true(r.success)
  assert_eq(r.affected_rows, 1L)
  assert_eq(
    @tesseract.Tesseract::delete(db, "", Some(target)).error_code,
    "POSITION_EMPTY",
  )
  @tesseract.Tesseract::set_position(db, lat.last_position() - 41L)
  let cleared = @tesseract.Tesseract::delete(db, "", None)
  assert_true(cleared.success)
  assert_eq(@tesseract.Tesseract::occupancy(db), 0L)
  assert_eq(
    @tesseract.Tesseract::status(db).current_position,
    lat.first_position(),
  )
  assert_eq(cleared.affected_rows, 0L)
}

///|
test "a digit cannot collide with a cell sharing its line" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  let (origin, along_w, no_line, peer) = geometry(lat)
  // (0,0,0,0) shares the w-line with (0,0,0,side-1).
  let ok = @tesseract.Tesseract::insert(db, "a", "1", Some(origin), 1L)
  assert_true(ok.success)
  let clash = @tesseract.Tesseract::insert(db, "b", "2", Some(along_w), 1L)
  assert_false(clash.success)
  assert_eq(clash.error_code, "SUDOKU_CONFLICT")
  // A different digit on a peer cell is fine.
  let fine = @tesseract.Tesseract::insert(db, "b", "2", Some(along_w), 2L)
  assert_true(fine.success)
  // A non-peer cell may reuse digit 1. (1,1,0,0) differs from (0,0,0,0) along
  // two axes and so shares no line with it.
  let away = @tesseract.Tesseract::insert(db, "c", "3", Some(no_line), 1L)
  assert_true(away.success)
  assert_eq(@tesseract.Tesseract::digit_count(db), 3L)
  // (1,0,0,0) is one step along x from (0,0,0,0), so it *is* a peer and digit 1
  // is refused there.
  let peer_again = @tesseract.Tesseract::insert(db, "d", "4", Some(peer), 1L)
  assert_false(peer_again.success)
  assert_eq(peer_again.error_code, "SUDOKU_CONFLICT")
}

///|
test "a rejected insert leaves the cell untouched" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  let (origin, along_w, _, _) = geometry(lat)
  ignore(@tesseract.Tesseract::insert(db, "a", "1", Some(origin), 1L))
  ignore(@tesseract.Tesseract::insert(db, "b", "2", Some(along_w), 1L))
  assert_eq(@tesseract.Tesseract::cell_at(db, along_w).unwrap().key, "")
  assert_eq(@tesseract.Tesseract::occupancy(db), 1L)
}

///|
test "setting a digit through update is conflict-checked too" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  let (origin, along_w, _, _) = geometry(lat)
  ignore(@tesseract.Tesseract::insert(db, "a", "1", Some(origin), 1L))
  ignore(@tesseract.Tesseract::insert(db, "b", "2", Some(along_w), 0L))
  let bad = @tesseract.Tesseract::update(db, "b", "2", Some(along_w), Some(1L))
  assert_false(bad.success)
  assert_eq(bad.error_code, "SUDOKU_CONFLICT")
  let good = @tesseract.Tesseract::update(
    db,
    "b",
    "2",
    Some(along_w),
    Some(lat.side()),
  )
  assert_true(good.success)
  assert_eq(
    @tesseract.Tesseract::cell_at(db, along_w).unwrap().digit,
    lat.side(),
  )
}

///|
test "line, slab and peer queries return the right neighbourhoods" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  let (origin, along_w, _, along_x) = geometry(lat)
  ignore(@tesseract.Tesseract::insert(db, "a", "1", Some(origin), 0L))
  ignore(@tesseract.Tesseract::insert(db, "b", "2", Some(along_w), 0L))
  ignore(@tesseract.Tesseract::insert(db, "c", "3", Some(along_x), 0L))
  let line = @tesseract.Tesseract::line_query(db, origin, 3L)
  assert_eq(line.total_records, 2L)
  // Slab on axis 0 fixes x = 0, which holds the origin and the far-w cell but
  // not the x = 1 one.
  let slab = @tesseract.Tesseract::slab_query(db, origin, 0L)
  assert_eq(slab.total_records, 2L)
  // Slab on axis 0 fixing x = 1 holds only the cell one step along x.
  let slab_x1 = @tesseract.Tesseract::slab_query(db, along_x, 0L)
  assert_eq(slab_x1.total_records, 1L)
  // Peers of (0,0,0,0) are one step along each axis: at three per axis, positions
  // 2, 3, 4, 7, 10, 19, 28 and 55. Two of them are occupied here.
  let peers = @tesseract.Tesseract::peer_query(db, origin)
  assert_eq(peers.total_records, 2L)
  assert_eq(
    @tesseract.Tesseract::line_query(db, lat.last_position() + 1L, 0L).error_code,
    "POSITION_OUT_OF_RANGE",
  )
}

///|
test "the logger keeps at most 100 entries" {
  let lat = @tesseract.default_lattice()
  let db = fresh()
  let mut i = 0L
  while i < 150L {
    ignore(
      @tesseract.Tesseract::insert(
        db,
        "k" + i.to_string(),
        "v",
        Some(i % (lat.total() - 1L) + lat.first_position()),
        0L,
      ),
    )
    i = i + 1L
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

///|
/// A side-3 solution carried into a side-4 lattice: what is actually true of it.
///
/// This is the question the window's badge does not answer on its own. Carrying
/// digits by coordinate keeps each digit on the cell it was on, but a digit rule
/// is about *neighbours*, and the new lattice has neighbours the old one did not:
/// the side-3 cell at `(1,0,0,2)` gains a w-line-mate at `(1,0,0,3)`, which no
/// side-3 formula ever looked at. Does that new mate collide?
///
/// Measured answer: no, and not by luck of the fixture. Two cells share an
/// axis-parallel line when their coordinates agree in all but one axis - a
/// property of the coordinates, not of `side`. Widening only appends *blank*
/// cells to each line; it never changes which filled cells share one. Both
/// checkers skip `NO_DIGIT`, so a wider lattice cannot introduce a violation
/// that the narrower one did not already have.
///
/// The cost of that safety is the wording: on 81 digits out of 256,
/// `is_solution` means "no violation so far", not "this is a complete solution".
/// The other half of this file measures the shrink direction, where the digits
/// that *do* get dropped are the reason a resize reports `dropped`.
test "a carried-over side-3 solution is measured against the side-4 rule" {
  let db = @tesseract.new_db(
    "t",
    @tesseract.default_lattice(),
    @tesseract.new_logger("t"),
  )
  let three = @tesseract.default_lattice()
  // Exactly what `.solve` stores at side 3.
  let digits = @tesseract.canonical_digits(three)
  let mut p = three.first_position()
  while p <= three.last_position() {
    ignore(
      @tesseract.Tesseract::insert(
        db,
        "cell_" + p.to_string(),
        p.to_string(),
        Some(p),
        @tesseract.digit_at(three, digits, p),
      ),
    )
    p = p + 1L
  }
  assert_eq(@tesseract.line_violations(three, digits).length(), 0)
  ignore(@tesseract.Tesseract::set_side(db, 4L).unwrap())
  // All 81 carry, because every side-3 coordinate is inside a side-4 lattice.
  assert_eq(@tesseract.Tesseract::occupancy(db), 81L)
  let four = @tesseract.Tesseract::lattice_of_db(db)
  // Read the digits back out of the store, not off the old fixture, so this
  // measures what the store actually holds after the resize.
  let carried = @tesseract.empty_digits(four)
  let mut q = four.first_position()
  while q <= four.last_position() {
    match @tesseract.Tesseract::cell_at(db, q) {
      Some(cell) => @tesseract.set_digit(four, carried, q, cell.digit)
      None => ()
    }
    q = q + 1L
  }
  // Without this count the two assertions below are worth nothing: an all-empty
  // `carried` has no line that can repeat a digit and no full slab, so both
  // checkers would report nothing and the test would pass on a resize that
  // dropped every digit.
  let mut filled = 0L
  let mut i = 0
  while i < carried.length() {
    if carried[i] != @tesseract.NO_DIGIT {
      filled = filled + 1L
    }
    i = i + 1
  }
  assert_eq(filled, 81L)
  // And the verdict, measured rather than assumed.
  assert_eq(@tesseract.line_violations(four, carried).length(), 0)
  assert_true(@tesseract.is_solution(four, carried))
}

///|
/// A wider lattice keeps every record, on the cell its coordinates name.
///
/// The point is the *cell*, not the count: `(1,1,1,1)` is position 41 at side 3
/// and 86 at side 4, so a resize that carried position numbers would report the
/// right number of surviving records while having moved every one of them.
test "widening the lattice carries records by coordinate, not by position number" {
  let db = @tesseract.new_db(
    "t",
    @tesseract.default_lattice(),
    @tesseract.new_logger("t"),
  )
  let cell = @tesseract.coords(1L, 1L, 1L, 1L)
  let was = @tesseract.position_of(@tesseract.default_lattice(), cell)
  ignore(@tesseract.Tesseract::insert(db, "kept", "v", Some(was), 0L))
  let report = @tesseract.Tesseract::set_side(db, 4L).unwrap()
  assert_eq(report.from_side, 3L)
  assert_eq(report.to_side, 4L)
  assert_eq(report.kept, 1L)
  assert_eq(report.dropped, 0L)
  let now = @tesseract.Tesseract::lattice_of_db(db)
  assert_eq(now.side(), 4L)
  assert_eq(@tesseract.Tesseract::occupancy(db), 1L)
  let landed = @tesseract.position_of(now, cell)
  assert_true(landed != was)
  assert_eq(@tesseract.Tesseract::cell_at(db, landed).unwrap().key, "kept")
  assert_true(
    @tesseract.cell_is_empty(@tesseract.Tesseract::cell_at(db, was).unwrap()),
  )
}

///|
/// Narrowing drops what cannot fit, and says how much.
test "narrowing drops records that no longer fit instead of clamping them" {
  let db = @tesseract.new_db(
    "t",
    @tesseract.default_lattice(),
    @tesseract.new_logger("t"),
  )
  let three = @tesseract.default_lattice()
  // (0,0,0,0) fits on a side-2 lattice; (2,2,2,2) cannot.
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "fits",
      "v",
      Some(@tesseract.position_of(three, @tesseract.coords(0L, 0L, 0L, 0L))),
      0L,
    ),
  )
  ignore(
    @tesseract.Tesseract::insert(
      db,
      "toobig",
      "v",
      Some(@tesseract.position_of(three, @tesseract.coords(2L, 2L, 2L, 2L))),
      0L,
    ),
  )
  let report = @tesseract.Tesseract::set_side(db, 2L).unwrap()
  assert_eq(report.kept, 1L)
  assert_eq(report.dropped, 1L)
  assert_eq(@tesseract.Tesseract::occupancy(db), 1L)
  assert_eq(@tesseract.Tesseract::cell_at(db, 1L).unwrap().key, "fits")
}

///|
/// A resize that is refused leaves the store exactly as it was.
test "an out-of-range side is refused and changes nothing" {
  let db = @tesseract.new_db(
    "t",
    @tesseract.default_lattice(),
    @tesseract.new_logger("t"),
  )
  ignore(@tesseract.Tesseract::insert(db, "a", "1", Some(1L), 0L))
  match @tesseract.Tesseract::set_side(db, 999L) {
    Ok(r) => {
      assert_true(false)
      ignore(r)
    }
    Err(message) => assert_true(message.contains("215"))
  }
  assert_eq(@tesseract.Tesseract::lattice_of_db(db).side(), 3L)
  assert_eq(@tesseract.Tesseract::occupancy(db), 1L)
  assert_eq(@tesseract.Tesseract::cell_at(db, 1L).unwrap().key, "a")
}

///|
/// The cursor rewinds rather than pointing at a cell that may not exist.
test "a resize rewinds the cursor to the first position" {
  let db = @tesseract.new_db(
    "t",
    @tesseract.default_lattice(),
    @tesseract.new_logger("t"),
  )
  let three = @tesseract.default_lattice()
  @tesseract.Tesseract::set_position(
    db,
    @tesseract.position_of(three, @tesseract.coords(2L, 2L, 2L, 2L)),
  )
  assert_eq(@tesseract.Tesseract::status(db).current_position, 81L)
  ignore(@tesseract.Tesseract::set_side(db, 4L).unwrap())
  assert_eq(@tesseract.Tesseract::status(db).current_position, 1L)
}
