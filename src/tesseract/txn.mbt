///|
/// Transactions, by undo journal rather than by snapshot.
///
/// Two things are being bought here, and they are not the same thing:
///
/// - **Atomicity.** A statement that fails halfway leaves nothing behind. This
///   works with or without `BEGIN`, and it is what stops a multi-row `UPDATE`
///   from committing rows 1..n-1 when row n is refused.
/// - **Atomicity across statements.** `BEGIN` ... `ROLLBACK` undoes a whole run.
///
/// The journal holds *before-images of the cells that were written*, so a
/// transaction costs what it wrote rather than what the lattice holds. A copy of
/// all 81 cells per statement would be simpler and would make `side = 215`
/// impossible in a way it currently is not.
///
/// Outside a transaction the journal is truncated as soon as a statement
/// succeeds, so it never grows past one statement's writes. Inside one it grows
/// until `COMMIT`, which is what a rollback needs.
///
/// **On concurrency.** MoonBit has no data race to fix here: one process,
/// cooperative async, and the only shared mutable state is this store. What this
/// file provides is serializability *by construction* - a writer is the only
/// writer, and the journal says exactly how far back it can be taken. The window
/// additionally holds one `@async.Mutex` around every bridge handler; that lock is
/// the isolation boundary and this file is the atomicity mechanism. Neither
/// replaces the other, and neither makes this thread-safe.

///|
/// One reversible change.
///
/// `Cell` carries the before-image of a single position. `All` carries a whole
/// `cells` array, and is what a resize records: a resize changes the lattice, so
/// a per-cell entry would have to mean something different before and after it.
/// It also carries the lattice and the cursor, because `set_side` rewinds the
/// cursor and a rollback that left it pointing into a lattice that no longer
/// exists would be worse than not rolling back at all.
pub enum Undo {
  Cell(Int64, GridCell)
  All(Array[GridCell], Lattice, Int64)
}

///|
/// A named point in the journal that a partial rollback can return to.
pub struct Savepoint {
  name : String
  mark : Int32
}

///|
/// The transaction state carried by a store.
pub struct TxnState {
  mut in_tx : Bool
  mut journal : Array[Undo]
  mut savepoints : Array[Savepoint]
}

///|
/// Transaction state for a store that has never opened one.
pub fn no_txn() -> TxnState {
  { in_tx: false, journal: [], savepoints: [], }
}

///|
/// True while a `BEGIN` is open.
pub fn Tesseract::in_transaction(db : Tesseract) -> Bool {
  db.txn.in_tx
}

///|
/// How many undo records the journal holds, and how deep a savepoint is.
///
/// Exposed so the SQL layer can open an implicit savepoint around a statement
/// without reaching into the journal.
pub fn Tesseract::journal_depth(db : Tesseract) -> Int32 {
  db.txn.journal.length()
}

///|
/// The single point every mutation goes through.
///
/// It exists so that the journal cannot drift out of coverage. There were six
/// places that assigned `db.cells[...]` before this existed - insert, update,
/// delete-by-key, delete-by-position, delete-all and resize - and a transaction
/// that covered five of them would be worse than none, because it would look
/// correct while quietly losing a path. Adding a seventh write means adding a
/// seventh call to this function, which is a visible omission rather than a
/// silent one.
///
/// It is **not** public, and that is the point. It writes whatever it is
/// given, at whatever position it is given, without checking either: the
/// check belongs to the public entry point above it, which refuses an
/// out-of-range position with a code the caller can branch on. Published,
/// this function was an entry point that panicked on `position = 0` (the
/// slot it computes is `-1`) and that stored a cell whose own key, value
/// and digit the library refuses everywhere else - a store that accepted
/// the write and failed later, somewhere else, as a different kind of
/// failure. Every caller is in this package, so nothing is lost by keeping
/// it here.
fn Tesseract::write_cell(
  db : Tesseract,
  position : Int64,
  cell : GridCell,
) -> Unit {
  let slot = slot_of(position)
  db.txn.journal.push(Undo::Cell(position, db.cells[slot]))
  db.cells[slot] = cell
}

///|
/// Replaces the whole array, for the two writes that are not one cell at a time.
///
/// `clear` rewrites every cell; `set_side` replaces the array and the lattice.
///
/// Like `write_cell`, this is not public: it swaps out the store's shape
/// wholesale, and the shape it is given has to be one the library would have
/// built. `set_side` builds it with `lattice_of`, which refuses an
/// out-of-range side.
fn Tesseract::write_all(
  db : Tesseract,
  cells : Array[GridCell],
  lattice : Lattice,
  cursor : Int64,
) -> Unit {
  db.txn.journal.push(Undo::All(db.cells, db.lattice, db.current_position))
  db.cells = cells
  db.lattice = lattice
  db.current_position = cursor
}

///|
/// Replays the journal backwards down to `mark`, restoring every cell it covers.
fn undo_to(db : Tesseract, mark : Int32) -> Unit {
  let mut i = db.txn.journal.length() - 1
  while i >= mark {
    match db.txn.journal[i] {
      Undo::Cell(position, before) => {
        // The array may have been resized after this entry was written, so the
        // position is only meaningful while it still fits. If it does not, the
        // following `All` entry is the one that has to win, and replaying
        // backwards means it does.
        let slot = slot_of(position)
        if slot >= 0 && slot < db.cells.length() {
          db.cells[slot] = before
        }
      }
      Undo::All(cells, lattice, cursor) => {
        db.cells = cells
        db.lattice = lattice
        db.current_position = cursor
      }
    }
    i = i - 1
  }
}

///|
/// Drops journal entries past `mark` without undoing them.
fn truncate_to(db : Tesseract, mark : Int32) -> Unit {
  let kept : Array[Undo] = []
  let mut i = 0
  while i < mark {
    kept.push(db.txn.journal[i])
    i = i + 1
  }
  db.txn.journal = kept
}

///|
/// Closes a statement that succeeded.
///
/// Outside a transaction this discards the undo records the statement produced,
/// which is what keeps the journal from growing over a long run of statements.
/// Inside one the records stay, because a later `ROLLBACK` needs them - and that
/// is the whole difference between the two cases.
pub fn Tesseract::statement_commit(db : Tesseract, mark : Int32) -> Unit {
  if !Tesseract::in_transaction(db) {
    truncate_to(db, mark)
  }
}

///|
/// Undoes everything a failed statement wrote.
///
/// Always undoes, transaction or not: a statement that half-applied is a bug
/// whether or not anybody asked to keep its work.
pub fn Tesseract::statement_abort(db : Tesseract, mark : Int32) -> Unit {
  undo_to(db, mark)
  truncate_to(db, mark)
}

///|
/// Opens a transaction.
///
/// `BEGIN` inside a transaction is refused rather than nested. `SAVEPOINT` is the
/// supported way to have a rollback point inside a transaction, and silently
/// accepting a second `BEGIN` would make the two disagree about what `COMMIT`
/// ends.
pub fn Tesseract::begin(db : Tesseract) -> DBResponse {
  if Tesseract::in_transaction(db) {
    return err_response(
      "INVALID_INPUT", "Already in a transaction; use SAVEPOINT for a nested rollback point",
    )
  }
  db.txn.in_tx = true
  db.txn.journal = []
  db.txn.savepoints = []
  Tesseract::log_operation(db, "BEGIN", true, "", 0L)
  ok_response("BEGIN")
}

///|
/// Ends a transaction and keeps its work.
pub fn Tesseract::commit(db : Tesseract) -> DBResponse {
  if !Tesseract::in_transaction(db) {
    return err_response("INVALID_INPUT", "No transaction is open")
  }
  db.txn.in_tx = false
  db.txn.journal = []
  db.txn.savepoints = []
  Tesseract::log_operation(db, "COMMIT", true, "", 0L)
  ok_response("COMMIT")
}

///|
/// Ends a transaction and undoes every statement in it.
pub fn Tesseract::rollback(db : Tesseract) -> DBResponse {
  if !Tesseract::in_transaction(db) {
    return err_response("INVALID_INPUT", "No transaction is open")
  }
  undo_to(db, 0)
  db.txn.in_tx = false
  db.txn.journal = []
  db.txn.savepoints = []
  Tesseract::log_operation(db, "ROLLBACK", true, "", 0L)
  ok_response("ROLLBACK")
}

///|
/// Marks a point a later `ROLLBACK TO` can return to.
///
/// Requires an open transaction: a savepoint outside one would be a name for a
/// journal the next statement truncates, so it would name nothing.
pub fn Tesseract::savepoint(db : Tesseract, name : String) -> DBResponse {
  if !Tesseract::in_transaction(db) {
    return err_response("INVALID_INPUT", "SAVEPOINT needs an open transaction")
  }
  let mut i = 0
  while i < db.txn.savepoints.length() {
    if db.txn.savepoints[i].name == name {
      return err_response("INVALID_INPUT", "Savepoint already named " + name)
    }
    i = i + 1
  }
  db.txn.savepoints.push(Savepoint::{ name, mark: db.txn.journal.length(), })
  ok_response("SAVEPOINT " + name)
}

///|
/// Index of the savepoint called `name`, or `-1`.
fn find_savepoint(db : Tesseract, name : String) -> Int32 {
  let mut i = 0
  while i < db.txn.savepoints.length() {
    if db.txn.savepoints[i].name == name {
      return i
    }
    i = i + 1
  }
  -1
}

///|
/// Undoes back to a savepoint and keeps the transaction open.
///
/// The savepoint itself **survives**; only the ones after it are dropped. That is
/// the SQL behaviour - `ROLLBACK TO SAVEPOINT sp` leaves `sp` usable - and it is
/// also the only one that makes sense here, because the mark is an index into a
/// journal that has just been truncated *to* that index. So `sp` still describes
/// exactly where things stand, and destroying it would make a second
/// `ROLLBACK TO sp` fail for a reason that has nothing to do with the database.
///
/// The ones after it are dropped because their marks are now past the end of the
/// journal, and a savepoint naming a position the journal no longer reaches is a
/// name for nothing.
pub fn Tesseract::rollback_to(db : Tesseract, name : String) -> DBResponse {
  if !Tesseract::in_transaction(db) {
    return err_response(
      "INVALID_INPUT", "ROLLBACK TO needs an open transaction",
    )
  }
  let at = find_savepoint(db, name)
  if at < 0 {
    return err_response("INVALID_INPUT", "No savepoint named " + name)
  }
  undo_to(db, db.txn.savepoints[at].mark)
  truncate_to(db, db.txn.savepoints[at].mark)
  let kept : Array[Savepoint] = []
  let mut i = 0
  while i <= at {
    kept.push(db.txn.savepoints[i])
    i = i + 1
  }
  db.txn.savepoints = kept
  Tesseract::log_operation(db, "ROLLBACK TO " + name, true, "", 0L)
  ok_response("ROLLBACK TO " + name)
}

///|
/// Forgets a savepoint while keeping the work done since it was set.
///
/// Distinct from `ROLLBACK TO`, which throws that work away.
pub fn Tesseract::release_savepoint(
  db : Tesseract,
  name : String,
) -> DBResponse {
  if !Tesseract::in_transaction(db) {
    return err_response("INVALID_INPUT", "RELEASE needs an open transaction")
  }
  let at = find_savepoint(db, name)
  if at < 0 {
    return err_response("INVALID_INPUT", "No savepoint named " + name)
  }
  let kept : Array[Savepoint] = []
  let mut i = 0
  while i < db.txn.savepoints.length() {
    if i != at {
      kept.push(db.txn.savepoints[i])
    }
    i = i + 1
  }
  db.txn.savepoints = kept
  ok_response("RELEASE " + name)
}
