///|
/// The index of a memory's entries, by the words they contain.
///
/// The index is an **inverted index**: one row per word, per entry, and the
/// row says which entry it is. "Which of my entries mention the word 'cat'?"
/// is a lookup rather than a scan, and the answer is **exact** — the memory's
/// own search is a similarity, and an entry that shares nothing with the
/// query is not in its answer at all.
///
/// The index lives in a **SQLite** file, so it is a plain SQL table —
/// `tesseract_memory_index(token, scope, key)` — and a person can query it
/// with SQL. The package is the API form of that table, not a replacement for
/// it.
///
/// The index is **derivative**. Every row is a word of an entry's value or of
/// one of its labels, so the index holds nothing the entries do not: it can be
/// thrown away and built again, and the rebuild is the same index. That is
/// what `rebuild` and `verify` are for — they say what the index would have to
/// change to match the store, which is how a caller finds out whether the
/// index it has is the one the store says it should be.
///
/// An index that is in step with the store is **disposable**, and that is the
/// property worth having: a caller who does not trust it can delete it, and
/// the next rebuild gives back the same thing.
pub struct MemoryIndex {
  path : String
}

///|
/// What a rebuild found.
///
/// The three numbers say how far the index was from the store: the entries
/// that had to change, the rows that had to be put back, and the rows that had
/// to go. A rebuild of an index that was already right says **nothing** on all
/// three counts, and that is the proof that the index holds nothing of its
/// own.
pub struct RebuildReport {
  entries : Int32
  changed : Int32
  added : Int32
  removed : Int32
} derive(Eq, Debug)

///|
/// The table the index is.
///
/// The name says what the file is, and the three columns say what a row is: a
/// word, and the entry it is in. The key is all three, because a word may be
/// in many entries and an entry may have many words.
const INDEX_DDL : String = "CREATE TABLE IF NOT EXISTS tesseract_memory_index (token TEXT NOT NULL, scope TEXT NOT NULL, key TEXT NOT NULL, PRIMARY KEY (token, scope, key))"

///|
/// The index over the entries of one key, so that an entry's rows can be
/// found without reading the whole table.
const ENTRY_INDEX_DDL : String = "CREATE INDEX IF NOT EXISTS tesseract_memory_index_entry ON tesseract_memory_index (scope, key)"

///|
/// Opens the index in the file at `path`, creating it if it is not there.
///
/// A file that is not there yet is an empty index, not an error: the index is
/// derived, and an index that has never been built is the same as one that was
/// built and thrown away.
pub fn open(path : String) -> Result[MemoryIndex, String] {
  let index = { path, }
  match index.ensure_schema() {
    Ok(_) => Ok(index)
    Err(message) => Err(message)
  }
}

///|
/// The file the index is in.
pub fn MemoryIndex::path(self : MemoryIndex) -> String {
  self.path
}

///|
/// How many rows the index holds.
pub fn MemoryIndex::rows(self : MemoryIndex) -> Result[Int32, String] {
  let count = count_rows(self.path) catch {
    _ => return Err("the index at " + self.path + " could not be read")
  }
  Ok(count)
}

///|
/// The entries that contain a word.
///
/// The word is matched **exactly**, the way the entry was indexed: it is
/// lowercased, and it is one word. So "cat" finds the entry that says "cat",
/// and "ca" and "cats" find nothing — the memory's own search is a similarity
/// and this is not that.
///
/// The pairs are in the order of the scope and then the key, so the same
/// index answers the same way however it was built.
pub fn MemoryIndex::lookup(
  self : MemoryIndex,
  token : String,
) -> Result[Array[(String, String)], String] {
  let found = lookup_rows(self.path, token) catch {
    _ => return Err("the index at " + self.path + " could not be read")
  }
  Ok(found)
}

///|
/// Indexes one entry, replacing whatever rows it had.
///
/// The rows of an entry are the words of its value and of its labels, so an
/// entry whose value changed is indexed under its new words and not its old
/// ones. The replacement is in one transaction, so an index that is read
/// halfway through a write never sees half an entry.
pub fn MemoryIndex::put(
  self : MemoryIndex,
  entry : @tesseract_memory.Entry,
) -> Result[Unit, String] {
  let done = put_entry(self.path, entry) catch {
    _ => return Err("the index at " + self.path + " could not be written")
  }
  Ok(done)
}

///|
/// Drops the rows of one entry.
///
/// The entry itself is not touched: the index is not the store, and forgetting
/// a word from the index does not forget the entry it was in.
pub fn MemoryIndex::forget(
  self : MemoryIndex,
  scope : String,
  key : String,
) -> Result[Unit, String] {
  let done = forget_entry(self.path, scope, key) catch {
    _ => return Err("the index at " + self.path + " could not be written")
  }
  Ok(done)
}

///|
/// Says what the index would have to change to match the store, and changes
/// it.
///
/// The index is rebuilt from the store, so what comes back is the index the
/// store says: a file that was deleted, emptied or edited by hand is put back
/// the way it was, and the report says what had to be put back.
///
/// A rebuild of an index that was already right changes **nothing**, and the
/// report says so. That is the proof that the index is derivative: it holds
/// nothing the entries do not, so recomputing it finds the same thing.
pub fn MemoryIndex::rebuild(
  self : MemoryIndex,
  memory : @tesseract_memory.Memory,
) -> Result[RebuildReport, String] {
  let report = rebuild_index(self.path, memory, true) catch {
    _ => return Err("the index at " + self.path + " could not be rebuilt")
  }
  Ok(report)
}

///|
/// Says what the index would have to change to match the store, and changes
/// **nothing**.
///
/// This is the question the rebuild answers, asked without the answer: how far
/// is this index from the one the store says it should be? A caller that keeps
/// an index up to date asks it after every write, and a caller that does not
/// asks it to find out.
pub fn MemoryIndex::verify(
  self : MemoryIndex,
  memory : @tesseract_memory.Memory,
) -> Result[RebuildReport, String] {
  // A verify that created the file it was asked about would be a write in a
  // read's clothing, so a file that is not there is answered without opening
  // it: the index holds nothing, and the report says what the store would put
  // into it.
  if !@xfs.path_exists(self.path) {
    return Ok(drift_of_nothing(wanted_rows(memory)))
  }
  let report = rebuild_index(self.path, memory, false) catch {
    _ => return Err("the index at " + self.path + " could not be read")
  }
  Ok(report)
}

///|
/// The report as one line.
pub fn RebuildReport::describe(self : RebuildReport) -> String {
  self.entries.to_string() +
  " entries, " +
  self.changed.to_string() +
  " changed, " +
  self.added.to_string() +
  " rows added, " +
  self.removed.to_string() +
  " rows removed"
}

///|
/// Creates the table and the index when they are not already there.
fn MemoryIndex::ensure_schema(self : MemoryIndex) -> Result[Unit, String] {
  let done = create_schema(self.path) catch {
    _ => return Err("the index at " + self.path + " could not be opened")
  }
  Ok(done)
}

///|
/// The words an entry is indexed under.
///
/// The words of its **value**, and the words of the **values** of its labels:
/// the content of an entry is its value and its labels, and the byte budget
/// counts both, so the index counts both.
///
/// The **keys** of the labels are not words. "kind" is the name of a label,
/// and every entry with a kind would then be found by the word "kind" — which
/// says nothing about the entry.
fn tokens_of(entry : @tesseract_memory.Entry) -> Array[String] {
  let words : Array[String] = []
  for token in @tesseract_memory.tokenize(entry.value()) {
    words.push(token)
  }
  for (_, value) in entry.metadata().pairs() {
    for token in @tesseract_memory.tokenize(value) {
      words.push(token)
    }
  }
  // The same word twice is one row: the table's key says so, and a row that
  // said it twice would be a row the store cannot have.
  let unique : Array[String] = []
  for word in words {
    if !unique.contains(word) {
      unique.push(word)
    }
  }
  unique.sort_by(fn(a, b) { @tesseract.compare_text(a, b) })
  unique
}

///|
/// The rows the store says the index should hold.
///
/// Every entry of every scope, with the words it is indexed under. The scopes
/// are the store's own, so the index covers the whole store and not one part
/// of it.
fn wanted_rows(
  memory : @tesseract_memory.Memory,
) -> Array[(String, String, Array[String])] {
  let wanted : Array[(String, String, Array[String])] = []
  for scope in memory.scopes() {
    for entry in memory.scope(scope).entries() {
      wanted.push((entry.scope(), entry.key(), tokens_of(entry)))
    }
  }
  wanted
}

///|
/// The report for an index that holds nothing.
///
/// Every entry is a change, and every word of every entry is a row to add.
fn drift_of_nothing(
  wanted : Array[(String, String, Array[String])],
) -> RebuildReport {
  let mut added = 0
  for (_, _, tokens) in wanted {
    added = added + tokens.length()
  }
  RebuildReport::{
    entries: wanted.length(),
    changed: wanted.length(),
    added,
    removed: 0,
  }
}

///|
/// Whether the file holds the index table.
///
/// A file that is not an index yet is not an error: the index is derived, and
/// a file with no table in it holds no rows.
fn has_table(conn : @sqlite3.Connection) -> Bool raise {
  let stmt = conn.prepare(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'tesseract_memory_index'",
  )
  defer stmt.finalize()
  stmt.step()
}

///|
/// Runs one statement for its effect and releases it.
fn run(conn : @sqlite3.Connection, sql : String) -> Unit raise {
  let stmt = conn.prepare(sql)
  defer stmt.finalize()
  ignore(stmt.step())
}

///|
/// Creates the table and the index when they are not already there.
fn create_schema(path : String) -> Unit raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  run(conn, INDEX_DDL)
  run(conn, ENTRY_INDEX_DDL)
}

///|
/// How many rows the index holds.
fn count_rows(path : String) -> Int32 raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  let stmt = conn.prepare("SELECT COUNT(*) FROM tesseract_memory_index")
  defer stmt.finalize()
  if stmt.step() {
    let count : Int64 = stmt.column(index=0)
    count.to_int()
  } else {
    0
  }
}

///|
/// The entries that contain a word.
fn lookup_rows(path : String, token : String) -> Array[(String, String)] raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  let stmt = conn.prepare(
    "SELECT scope, key FROM tesseract_memory_index WHERE token = ?",
  )
  defer stmt.finalize()
  // The words are indexed the way the tokenizer writes them, and the tokenizer
  // lowercases. So the word is lowercased too, or "Cat" would miss the entry
  // that says "cat".
  stmt.bind(index=1, @tesseract.lower(token))
  let out : Array[(String, String)] = []
  while stmt.step() {
    let scope : String = stmt.column(index=0)
    let key : String = stmt.column(index=1)
    out.push((scope, key))
  }
  out.sort_by(fn(a, b) {
    let by_scope = @tesseract.compare_text(a.0, b.0)
    if by_scope != 0 {
      by_scope
    } else {
      @tesseract.compare_text(a.1, b.1)
    }
  })
  out
}

///|
/// The rows of one entry, as the index holds them.
fn entry_rows(
  conn : @sqlite3.Connection,
  scope : String,
  key : String,
) -> Array[String] raise {
  let stmt = conn.prepare(
    "SELECT token FROM tesseract_memory_index WHERE scope = ? AND key = ?",
  )
  defer stmt.finalize()
  stmt.bind(index=1, scope)
  stmt.bind(index=2, key)
  let out : Array[String] = []
  while stmt.step() {
    let token : String = stmt.column(index=0)
    out.push(token)
  }
  out
}

///|
/// The entries the index holds, as (scope, key) pairs.
fn indexed_entries(conn : @sqlite3.Connection) -> Array[(String, String)] raise {
  let stmt = conn.prepare(
    "SELECT DISTINCT scope, key FROM tesseract_memory_index",
  )
  defer stmt.finalize()
  let out : Array[(String, String)] = []
  while stmt.step() {
    let scope : String = stmt.column(index=0)
    let key : String = stmt.column(index=1)
    out.push((scope, key))
  }
  out
}

///|
/// The rows of one entry, written.
fn write_entry_rows(
  conn : @sqlite3.Connection,
  scope : String,
  key : String,
  tokens : Array[String],
) -> Unit raise {
  let del = conn.prepare(
    "DELETE FROM tesseract_memory_index WHERE scope = ? AND key = ?",
  )
  defer del.finalize()
  del.bind(index=1, scope)
  del.bind(index=2, key)
  ignore(del.step())
  let ins = conn.prepare(
    "INSERT OR IGNORE INTO tesseract_memory_index (token, scope, key) VALUES (?, ?, ?)",
  )
  defer ins.finalize()
  for token in tokens {
    ins.reset(clear_bindings=true)
    ins.bind(index=1, token)
    ins.bind(index=2, scope)
    ins.bind(index=3, key)
    ignore(ins.step())
  }
}

///|
/// Indexes one entry, replacing whatever rows it had.
fn put_entry(path : String, entry : @tesseract_memory.Entry) -> Unit raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  run(conn, "BEGIN")
  write_entry_rows(conn, entry.scope(), entry.key(), tokens_of(entry))
  run(conn, "COMMIT")
}

///|
/// Drops the rows of one entry.
fn forget_entry(path : String, scope : String, key : String) -> Unit raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  run(conn, "BEGIN")
  write_entry_rows(conn, scope, key, [])
  run(conn, "COMMIT")
}

///|
/// Rebuilds the index from the store, or says what it would have to change.
///
/// The whole thing is one transaction, so the index is never half-rebuilt: a
/// reader sees the index it had or the index the store says, not something in
/// between.
fn rebuild_index(
  path : String,
  memory : @tesseract_memory.Memory,
  apply : Bool,
) -> RebuildReport raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  let wanted = wanted_rows(memory)
  if apply {
    // A rebuild writes, so it creates the table when the file has not got it:
    // the index is disposable, and a rebuild of a deleted index is a rebuild.
    run(conn, INDEX_DDL)
    run(conn, ENTRY_INDEX_DDL)
  } else if !has_table(conn) {
    // A file that is not an index holds no rows, and that is the whole answer.
    return drift_of_nothing(wanted)
  }
  let mut changed = 0
  let mut added = 0
  let mut removed = 0
  let seen : Array[(String, String)] = []
  if apply {
    run(conn, "BEGIN")
  }
  for (scope, key, tokens) in wanted {
    seen.push((scope, key))
    let have = entry_rows(conn, scope, key)
    let missing = tokens.filter(fn(t) { !have.contains(t) })
    let extra = have.filter(fn(t) { !tokens.contains(t) })
    if missing.length() > 0 || extra.length() > 0 {
      changed = changed + 1
      added = added + missing.length()
      removed = removed + extra.length()
      if apply {
        write_entry_rows(conn, scope, key, tokens)
      }
    }
  }
  // The entries the index holds that the store does not: their rows go.
  for (scope, key) in indexed_entries(conn) {
    if !seen.contains((scope, key)) {
      removed = removed + entry_rows(conn, scope, key).length()
      changed = changed + 1
      if apply {
        write_entry_rows(conn, scope, key, [])
      }
    }
  }
  if apply {
    run(conn, "COMMIT")
  }
  RebuildReport::{ entries: wanted.length(), changed, added, removed, }
}
