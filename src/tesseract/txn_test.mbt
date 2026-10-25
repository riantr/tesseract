///|
/// Transactions: what commits, what rolls back, and what is refused.
///
/// The distinction these pin is the one that is easy to get wrong. A savepoint
/// that is released keeps the work; a savepoint that is rolled back to discards
/// it. Both are named the same way in most people's heads and behave oppositely,
/// so each has its own case here rather than one case covering "savepoints".

///|
fn fresh_txn() -> @tesseract.Tesseract {
  @tesseract.new_db(
    "t",
    @tesseract.default_lattice(),
    @tesseract.new_logger("t"),
  )
}

///|
/// Writes `key` at `position` and ignores the response.
fn put(db : @tesseract.Tesseract, key : String, position : Int64) -> Unit {
  ignore(@tesseract.Tesseract::insert(db, key, "v", Some(position), 0L))
}

///|
/// The key at `position`, or "" when the cell is empty.
fn key_at(db : @tesseract.Tesseract, position : Int64) -> String {
  match @tesseract.Tesseract::cell_at(db, position) {
    Some(c) => c.key
    None => ""
  }
}

///|
/// A committed transaction keeps everything it wrote.
test "a committed transaction keeps its work" {
  let db = fresh_txn()
  assert_true(@tesseract.Tesseract::begin(db).success)
  put(db, "a", 1L)
  put(db, "b", 2L)
  assert_true(@tesseract.Tesseract::commit(db).success)
  assert_eq(@tesseract.Tesseract::occupancy(db), 2L)
  assert_eq(key_at(db, 1L), "a")
  assert_eq(key_at(db, 2L), "b")
  assert_true(!@tesseract.Tesseract::in_transaction(db))
}

///|
/// A rolled-back transaction leaves the store exactly as it was.
///
/// Including the cells it overwrote: the before-image is restored, not just the
/// emptiness. `b` sat on a cell that already held `old`.
test "a rolled-back transaction restores the cells it overwrote" {
  let db = fresh_txn()
  put(db, "old", 5L)
  assert_true(@tesseract.Tesseract::begin(db).success)
  put(db, "a", 1L)
  put(db, "b", 5L)
  assert_true(@tesseract.Tesseract::rollback(db).success)
  assert_eq(@tesseract.Tesseract::occupancy(db), 1L)
  assert_eq(key_at(db, 1L), "")
  // Not "b was deleted" - `old` is back, which is the whole point of a
  // before-image rather than a deletion record.
  assert_eq(key_at(db, 5L), "old")
  assert_true(!@tesseract.Tesseract::in_transaction(db))
}

///|
/// `ROLLBACK` with nothing open is refused rather than silently succeeding.
///
/// A rollback that quietly did nothing is how a caller learns to ignore the
/// error code.
test "rolling back with no transaction is refused" {
  let db = fresh_txn()
  let r = @tesseract.Tesseract::rollback(db)
  assert_true(!r.success)
  assert_eq(r.error_code, "INVALID_INPUT")
}

///|
/// A second `BEGIN` is refused; `SAVEPOINT` is the way to nest.
test "a nested BEGIN is refused and names the alternative" {
  let db = fresh_txn()
  ignore(@tesseract.Tesseract::begin(db))
  let r = @tesseract.Tesseract::begin(db)
  assert_true(!r.success)
  // The code is the part a caller branches on; the message is prose, and
  // prose is the part that has no reason to stay put.
  assert_eq(r.error_code, "INVALID_INPUT")
  assert_true(r.error.contains("SAVEPOINT"))
  ignore(@tesseract.Tesseract::rollback(db))
}

///|
/// Rolling back to a savepoint discards only what came after it.
test "ROLLBACK TO discards the work after the savepoint and keeps the rest" {
  let db = fresh_txn()
  ignore(@tesseract.Tesseract::begin(db))
  put(db, "kept", 1L)
  assert_true(@tesseract.Tesseract::savepoint(db, "sp1").success)
  put(db, "discarded", 2L)
  assert_true(@tesseract.Tesseract::rollback_to(db, "sp1").success)
  assert_eq(@tesseract.Tesseract::occupancy(db), 1L)
  assert_eq(key_at(db, 1L), "kept")
  assert_eq(key_at(db, 2L), "")
  // The transaction is still open: rolling back to a savepoint is not a commit.
  assert_true(@tesseract.Tesseract::in_transaction(db))
  ignore(@tesseract.Tesseract::commit(db))
}

///|
/// `RELEASE` is the opposite of `ROLLBACK TO`, and the difference is the point.
///
/// Same statement position, same name, opposite effect on the work. Pinning both
/// is what stops one being implemented as the other.
test "RELEASE forgets the savepoint and keeps the work" {
  let db = fresh_txn()
  ignore(@tesseract.Tesseract::begin(db))
  put(db, "a", 1L)
  assert_true(@tesseract.Tesseract::savepoint(db, "sp1").success)
  put(db, "b", 2L)
  assert_true(@tesseract.Tesseract::release_savepoint(db, "sp1").success)
  assert_true(@tesseract.Tesseract::commit(db).success)
  assert_eq(@tesseract.Tesseract::occupancy(db), 2L)
  assert_eq(key_at(db, 2L), "b")
}

///|
/// Rolling back to a savepoint invalidates the ones after it.
///
/// Keeping them would let a later `ROLLBACK TO` name a mark whose contents no
/// longer describe anything - the mark is an index into a journal that has since
/// been truncated past it.
test "ROLLBACK TO drops the savepoints set after it" {
  let db = fresh_txn()
  ignore(@tesseract.Tesseract::begin(db))
  assert_true(@tesseract.Tesseract::savepoint(db, "outer").success)
  put(db, "a", 1L)
  assert_true(@tesseract.Tesseract::savepoint(db, "inner").success)
  put(db, "b", 2L)
  ignore(@tesseract.Tesseract::rollback_to(db, "outer"))
  let gone = @tesseract.Tesseract::rollback_to(db, "inner")
  assert_true(!gone.success)
  assert_eq(gone.error_code, "INVALID_INPUT")
  assert_true(gone.error.contains("inner"))
  // The outer one survived, because it was set before the one rolled back to.
  assert_true(@tesseract.Tesseract::rollback_to(db, "outer").success)
  ignore(@tesseract.Tesseract::rollback(db))
}

///|
/// Two savepoints cannot share a name, because the name is how one is found.
test "a duplicate savepoint name is refused" {
  let db = fresh_txn()
  ignore(@tesseract.Tesseract::begin(db))
  assert_true(@tesseract.Tesseract::savepoint(db, "sp1").success)
  let again = @tesseract.Tesseract::savepoint(db, "sp1")
  assert_true(!again.success)
  assert_eq(again.error_code, "INVALID_INPUT")
  assert_true(again.error.contains("sp1"))
  ignore(@tesseract.Tesseract::rollback(db))
}

///|
/// Savepoint machinery outside a transaction is refused, with the reason.
///
/// A savepoint outside one would name a position in a journal the next
/// successful statement truncates - it would name nothing at all.
test "a savepoint needs an open transaction" {
  let db = fresh_txn()
  let r = @tesseract.Tesseract::savepoint(db, "sp1")
  assert_true(!r.success)
  assert_eq(r.error_code, "INVALID_INPUT")
  assert_true(r.error.contains("transaction"))
}

///|
/// A failed statement leaves nothing behind, with no `BEGIN` in sight.
///
/// This is the property the implicit statement savepoint exists for, and it is
/// independent of transactions: a multi-row statement that is refused on its
/// last row must not have committed its earlier ones. Driven through the journal
/// API here because the multi-row case belongs to the SQL executor, which does
/// not exist yet.
test "an aborted statement undoes its own writes outside a transaction" {
  let db = fresh_txn()
  let mark = @tesseract.Tesseract::journal_depth(db)
  put(db, "a", 1L)
  put(db, "b", 2L)
  assert_eq(@tesseract.Tesseract::occupancy(db), 2L)
  @tesseract.Tesseract::statement_abort(db, mark)
  assert_eq(@tesseract.Tesseract::occupancy(db), 0L)
}

///|
/// A successful statement outside a transaction leaves no journal behind.
///
/// Without this the journal would grow for the life of the process, holding a
/// before-image of every cell ever written, and a transaction opened later would
/// roll back to a mark in the middle of it.
test "a committed statement clears the journal it used" {
  let db = fresh_txn()
  let mark = @tesseract.Tesseract::journal_depth(db)
  put(db, "a", 1L)
  put(db, "b", 2L)
  @tesseract.Tesseract::statement_commit(db, mark)
  assert_eq(@tesseract.Tesseract::journal_depth(db), 0)
  // The writes themselves are of course still there.
  assert_eq(@tesseract.Tesseract::occupancy(db), 2L)
}

///|
/// Inside a transaction the journal survives a successful statement, because a
/// later `ROLLBACK` is the thing that needs it.
test "inside a transaction a committed statement keeps its undo record" {
  let db = fresh_txn()
  ignore(@tesseract.Tesseract::begin(db))
  let mark = @tesseract.Tesseract::journal_depth(db)
  put(db, "a", 1L)
  @tesseract.Tesseract::statement_commit(db, mark)
  assert_true(@tesseract.Tesseract::journal_depth(db) > mark)
  assert_true(@tesseract.Tesseract::rollback(db).success)
  assert_eq(@tesseract.Tesseract::occupancy(db), 0L)
}

///|
/// A resize is undoable, and undoing it restores the lattice too.
///
/// A rollback that restored the cells but left the store on the new lattice
/// would hand back 81 cells on a 256-cell point, which is not a state anything
/// else in this package can read.
test "a rolled-back resize restores the lattice and the cursor" {
  let db = fresh_txn()
  put(db, "a", 1L)
  ignore(@tesseract.Tesseract::begin(db))
  @tesseract.Tesseract::set_position(db, 40L)
  ignore(@tesseract.Tesseract::set_side(db, 4L).unwrap())
  assert_eq(@tesseract.Tesseract::lattice_of_db(db).side(), 4L)
  ignore(@tesseract.Tesseract::rollback(db))
  let back = @tesseract.Tesseract::lattice_of_db(db)
  assert_eq(back.side(), 3L)
  assert_eq(back.total(), 81L)
  // The cursor is back where it was, not rewound to the start.
  assert_eq(@tesseract.Tesseract::status(db).current_position, 40L)
  assert_eq(key_at(db, 1L), "a")
}

///|
/// The sudoku rule still refuses the write, and still leaves nothing partial.
///
/// Measured before any of this existed: a digit conflict returns
/// `SUDOKU_CONFLICT` and the target cell keeps its previous record. Pinned so a
/// journal refactor cannot quietly change it into a partial write.
///
/// Positions 1 and 2 differ only in `w`, so they share an axis-parallel line and
/// one digit may occupy at most one of them. An earlier version of this test put
/// the *setup* digit on both of them, so the setup's second insert was itself
/// refused and `ignore` swallowed it - the test then asserted against a cell that
/// had never been written, and failed for a reason that had nothing to do with
/// what it was checking.
test "a refused digit leaves the target cell holding its previous record" {
  let db = fresh_txn()
  put(db, "existing", 2L)
  ignore(@tesseract.Tesseract::insert(db, "p1", "v", Some(1L), 1L))
  let refused = @tesseract.Tesseract::insert(db, "p4", "v", Some(2L), 1L)
  assert_true(!refused.success)
  assert_eq(refused.error_code, "SUDOKU_CONFLICT")
  assert_eq(key_at(db, 2L), "existing")
}
