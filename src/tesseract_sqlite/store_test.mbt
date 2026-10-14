///|
/// Round-trip fidelity for the `.db` adapter.
///
/// The fixture writes a real file: the adapter's whole job is crossing the
/// process boundary, so a test that kept the database in memory would not be
/// testing the thing that can break.
///
/// Every raw-SQL helper below opens and closes its own connection, and lets its
/// statements go out of scope first. `Connection::close` is *rejected* while
/// statements are still prepared, so a helper that held a connection open
/// across two statements would fail for a reason that has nothing to do with
/// what it is testing.
fn scratch(name : String) -> String {
  "tesseract_test_" + name + ".db"
}

///|
fn fresh() -> @tesseract.Tesseract {
  @tesseract.new_db("tesseract", @tesseract.new_logger("test"))
}

///|
fn remove(path : String) -> Unit {
  // Removing a file that was never created is the normal case here, not a
  // failure worth reporting.
  @xfs.remove_file(path) catch {
    _ => ()
  }
}

///|
fn seeded() -> @tesseract.Tesseract {
  let db = fresh()
  ignore(
    @tesseract.Tesseract::insert(db, "user_001", "{\"age\": 25}", Some(1), 1),
  )
  ignore(
    @tesseract.Tesseract::insert(db, "user_002", "{\"age\": 30}", Some(37), 0),
  )
  ignore(@tesseract.Tesseract::insert(db, "cell_48", "a | b", Some(48), 2))
  @tesseract.Tesseract::set_position(db, 12)
  db
}

///|
fn occupied(db : @tesseract.Tesseract) -> Array[@tesseract.Record] {
  @tesseract.Tesseract::select(db, "", "", None, @tesseract.no_filter(), None).data
}

///|
/// Runs a save that is expected to fail, reporting whether it did.
///
/// `catch` without `noraise` re-raises once its handler is done, so the handler
/// returns out of here rather than falling through.
fn save_fails(path : String, db : @tesseract.Tesseract) -> Bool {
  ignore(@tesseract_sqlite.save(path, db)) catch {
    _ => return true
  }
  false
}

///|
/// Adds a row straight into the file, bypassing the store.
fn add_row(
  path : String,
  position : Int,
  key : String,
  value : String,
  digit : Int,
) -> Unit raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  let ins = conn.prepare(
    "INSERT INTO sudoku_cells (grid_position, key, value, digit, timestamp) VALUES (?, ?, ?, ?, ?)",
  )
  defer ins.finalize()
  ins.bind(index=1, position)
  ins.bind(index=2, key)
  ins.bind(index=3, value)
  ins.bind(index=4, digit)
  ins.bind(index=5, "0")
  ignore(ins.step())
}

///|
/// Makes every future INSERT into the cell table abort.
///
/// A trigger rather than a reshaped table: reshaping needs a DROP, and the
/// DROP would destroy the very row this test is asserting survives.
fn block_inserts(path : String) -> Unit raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  let make = conn.prepare(
    "CREATE TRIGGER block_cells AFTER INSERT ON sudoku_cells BEGIN SELECT RAISE(ABORT, 'blocked'); END",
  )
  defer make.finalize()
  ignore(make.step())
}

///|
/// Rewrites one cell's timestamp straight in the file.
fn set_stamp(path : String, position : Int, stamp : String) -> Unit raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  let upd = conn.prepare(
    "UPDATE sudoku_cells SET timestamp = ? WHERE grid_position = ?",
  )
  defer upd.finalize()
  upd.bind(index=1, stamp)
  upd.bind(index=2, position)
  ignore(upd.step())
}

///|
/// The timestamp the store holds at `position`, or `""` when that cell is empty.
///
/// Searches by position instead of indexing, so these tests do not also depend
/// on the order `select` happens to return rows in.
fn stamp_at(db : @tesseract.Tesseract, position : Int) -> String {
  for row in occupied(db) {
    if row.position == position {
      return row.timestamp
    }
  }
  ""
}

///|
test "a lattice survives a save and a load" {
  let path = scratch("roundtrip")
  remove(path)
  let src = seeded()
  assert_eq(@tesseract_sqlite.save(path, src), 3)
  let dst = fresh()
  let report = @tesseract_sqlite.load(path, dst)
  assert_eq(report.loaded, 3)
  assert_eq(report.rejected, 0)
  assert_eq(
    @tesseract.Tesseract::occupancy(dst),
    @tesseract.Tesseract::occupancy(src),
  )
  // Every cell lands on the position it was saved from - the coordinate
  // arithmetic is not redone from the key.
  let rows = occupied(dst)
  assert_eq(rows.length(), 3)
  assert_eq(rows[0].position, 1)
  assert_eq(rows[0].key, "user_001")
  assert_eq(rows[0].value, "{\"age\": 25}")
  assert_eq(rows[0].digit, 1)
  assert_eq(rows[2].position, 48)
  assert_eq(rows[2].value, "a | b")
  assert_eq(rows[2].digit, 2)
  remove(path)
}

///|
test "the cursor comes back with the lattice" {
  let path = scratch("cursor")
  remove(path)
  ignore(@tesseract_sqlite.save(path, seeded()))
  let dst = fresh()
  let report = @tesseract_sqlite.load(path, dst)
  // Without the meta row the store would sit wherever `delete` left it, and a
  // reopen would silently move the insertion point.
  assert_eq(report.cursor, 12)
  assert_eq(@tesseract.Tesseract::status(dst).current_position, 12)
  remove(path)
}

///|
test "saving twice replaces rather than merges" {
  let path = scratch("replace")
  remove(path)
  ignore(@tesseract_sqlite.save(path, seeded()))
  let smaller = fresh()
  ignore(@tesseract.Tesseract::insert(smaller, "only", "one", Some(2), 0))
  ignore(@tesseract_sqlite.save(path, smaller))
  let dst = fresh()
  let report = @tesseract_sqlite.load(path, dst)
  // A merge would report 4 and leave user_001 present.
  assert_eq(report.loaded, 1)
  assert_eq(@tesseract.Tesseract::occupancy(dst), 1)
  assert_eq(occupied(dst)[0].key, "only")
  remove(path)
}

///|
test "loading an empty file clears the store and reports nothing loaded" {
  let path = scratch("empty")
  remove(path)
  let dst = seeded()
  let report = @tesseract_sqlite.load(path, dst)
  // `import_tsr` clears first for the same reason: a load that merges leaves
  // records the file never mentioned.
  assert_eq(report.loaded, 0)
  assert_eq(@tesseract.Tesseract::occupancy(dst), 0)
  remove(path)
}

///|
test "a file the store refuses is counted, not dropped" {
  let path = scratch("conflict")
  remove(path)
  ignore(@tesseract_sqlite.save(path, seeded()))
  // Hand-edit the file into a state the sudoku rules reject. Positions 1 and 4
  // sit on the same z-axis line, so they may not both carry digit 1; no two
  // cells in the seed lattice share a line, which is why a row is added here
  // rather than edited.
  add_row(path, 4, "cell_4", "added", 1)
  let dst = fresh()
  let report = @tesseract_sqlite.load(path, dst)
  // "loaded 3 of 4" and "loaded 4" are different answers and only one of them
  // is what happened, so the rejected count has to exist.
  assert_eq(report.loaded + report.rejected, 4)
  assert_eq(report.loaded, 3)
  assert_eq(report.rejected, 1)
  remove(path)
}

///|
test "a whole generated dataset survives a .db round trip unchanged" {
  let path = scratch("dgp")
  remove(path)
  // The confounded PLR DGP: every treatment value, every outcome and every
  // covariate is an arbitrary double. The other tests in this file use three
  // hand-written records whose values are round numbers, which would pass even
  // through an encoder that lost a digit - so they cannot answer "does the
  // file backend record real data".
  let data = @tesseract_dgp.plr_dataset(81, 4, 0.5, 7)
  let src = fresh()
  let written = @tesseract_dgp.record(src, data)
  assert_eq(written.recorded, 81)
  assert_eq(written.rejected, 0)
  assert_eq(@tesseract_sqlite.save(path, src), 81)
  let dst = fresh()
  let loaded = @tesseract_sqlite.load(path, dst)
  assert_eq(loaded.loaded, 81)
  assert_eq(loaded.rejected, 0)
  match @tesseract_dgp.read_back(dst, data) {
    None => assert_true(false)
    Some(back) => {
      assert_eq(back.length(), 81)
      // `==` on every double: one ulp is already a failure to record it.
      for i = 0; i < 81; i = i + 1 {
        assert_true(back[i].index == data.observations[i].index)
        assert_true(back[i].d == data.observations[i].d)
        assert_true(back[i].y == data.observations[i].y)
        for j = 0; j < data.dim_x; j = j + 1 {
          assert_true(back[i].x[j] == data.observations[i].x[j])
        }
      }
    }
  }
  remove(path)
}

///|
test "a save that fails part way leaves the previous contents in place" {
  let path = scratch("atomic")
  remove(path)
  let first = fresh()
  ignore(@tesseract.Tesseract::insert(first, "keep", "me", Some(1), 0))
  ignore(@tesseract_sqlite.save(path, first))
  // Make the INSERT abort without touching the rows already on disk. The save
  // gets as far as DELETE before it fails, which is the only point at which a
  // missing transaction becomes visible.
  block_inserts(path)
  assert_true(save_fails(path, seeded()))
  // Without BEGIN/COMMIT the DELETE would already be committed and the file
  // would be empty; the transaction rolls it back.
  let dst = fresh()
  ignore(@tesseract_sqlite.load(path, dst))
  assert_eq(@tesseract.Tesseract::occupancy(dst), 1)
  assert_eq(occupied(dst)[0].key, "keep")
  remove(path)
}

///|
test "a cell comes back with the timestamp the file was saved with" {
  let path = scratch("stamps")
  remove(path)
  let src = seeded()
  ignore(@tesseract_sqlite.save(path, src))
  // A stamp no logger counter could mint. Without restoring the file's own
  // value, this cell would carry the *loading* process's `logger.seq` instead -
  // a small integer - so the assertion cannot pass by coincidence.
  set_stamp(path, 48, "18446744073709551615")
  let dst = fresh()
  let report = @tesseract_sqlite.load(path, dst)
  assert_eq(report.loaded, 3)
  assert_eq(stamp_at(dst, 48), "18446744073709551615")
  // The rows nobody touched keep what they were saved with as well, so a load
  // that restored only the edited row would still fail the line above.
  assert_true(stamp_at(src, 1) != "")
  assert_eq(stamp_at(dst, 1), stamp_at(src, 1))
  assert_eq(stamp_at(dst, 37), stamp_at(src, 37))
  remove(path)
}

///|
test "a row with no timestamp gets stamped, not stored blank" {
  let path = scratch("blankstamp")
  remove(path)
  ignore(@tesseract_sqlite.save(path, seeded()))
  // Model a file written by something with no stamp to give. Keeping the empty
  // string would make `timestamp` a field that means two different things:
  // "written at seq 0" and "unknown".
  set_stamp(path, 1, "")
  let dst = fresh()
  let report = @tesseract_sqlite.load(path, dst)
  assert_eq(report.loaded, 3)
  assert_true(stamp_at(dst, 1) != "")
  remove(path)
}
