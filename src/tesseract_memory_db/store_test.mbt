///|
/// The durable memory: what it keeps, what it brings back, and what it refuses.
///
/// The fixture writes a real file. The whole job of this package is crossing
/// the process boundary, so a test that kept the store in memory would not be
/// testing the thing that can break.
///
/// The clock is a **manual** one throughout, because a test that reads the
/// host clock cannot assert that something has not happened yet — and the
/// rules this file pins are all about time.
fn scratch(name : String) -> String {
  "tesseract_memory_db_test_" + name + ".db"
}

///|
/// Removes the file a test used. Removing a file that was never created is
/// the normal case here, not a failure worth reporting.
fn remove(path : String) -> Unit {
  @xfs.remove_file(path) catch {
    _ => ()
  }
}

///|
/// A store with a capacity and nothing else.
fn config(capacity : Int32) -> @tesseract_memory.Config {
  @tesseract_memory.default_config().with_capacity(capacity)
}

///|
/// Opens a durable memory on a manual clock that starts at `now`.
fn open_at(
  path : String,
  capacity : Int32,
  now : Int64,
) -> @tesseract_memory_db.DurableMemory {
  @tesseract_memory_db.open_with_clock(
    path,
    config(capacity),
    @tesseract_memory.memory_clock_manual(now),
  ).unwrap()
}

///|
/// Whether an open was refused.
fn refused(result : Result[@tesseract_memory_db.DurableMemory, String]) -> Bool {
  match result {
    Ok(_) => false
    Err(_) => true
  }
}

///|
/// The keys the file holds, read straight out of it.
///
/// The file is the checkpoint, and "the file holds the live entries" is a
/// claim about the **file** — not only about what a reload of it produces.
/// A reload that drops an expired entry on the way in would give the same
/// answer as a checkpoint that never wrote it, and only the file itself tells
/// the two apart.
fn file_keys(path : String) -> Array[String] raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  let stmt = conn.prepare("SELECT key FROM sudoku_cells ORDER BY grid_position")
  defer stmt.finalize()
  let out : Array[String] = []
  while stmt.step() {
    let key : String = stmt.column(index=0)
    out.push(key)
  }
  out
}

///|
/// A reload brings back exactly the entries that were live.
///
/// The clock is moved **without** a checkpoint, so the file on disk still
/// holds the entry that is about to die. The checkpoint is what has to
/// notice, and the reload is what has to leave it out.
test "a reload brings back exactly the entries that were live" {
  let path = scratch("live")
  remove(path)
  let d = open_at(path, 10, 0L)
  ignore(
    d.put_with_ttl("short", "a", @tesseract_memory.ttl_absolute(1000L)).unwrap(),
  )
  ignore(
    d
    .put_with_ttl("long", "b", @tesseract_memory.ttl_absolute(100000L))
    .unwrap(),
  )
  ignore(d.put("forever", "c").unwrap())
  ignore(d.memory().advance(2000L))
  ignore(d.checkpoint().unwrap())
  // The file itself holds the live set: the header, and the two entries that
  // are still alive. The one whose time was up is not in it.
  let keys = file_keys(path)
  assert_eq(keys.length(), 3)
  assert_eq(keys[0], "tesseract-memory")
  assert_eq(keys[1], "forever")
  assert_eq(keys[2], "long")
  let again = open_at(path, 10, 0L)
  assert_eq(again.get("short"), None)
  assert_eq(again.get("long"), Some("b"))
  assert_eq(again.get("forever"), Some("c"))
  assert_eq(again.size(), 2)
  remove(path)
}

///|
/// The deadline is absolute, not a lifetime.
///
/// A lifetime is measured from the moment of the write, so a checkpoint that
/// stored one would move every deadline forward by however long the store was
/// closed. The entry below was written at t=500 with a lifetime of 1000ms, so
/// its deadline is 1500 and its lifetime is 1000 — and the two are different
/// numbers on purpose. A checkpoint that stored the lifetime would bring back
/// a deadline of 1000, and one that recomputed the deadline from the clock
/// would bring back 2000. The entry had 500ms left when it was written out,
/// and it must have 500ms left when it comes back.
test "the deadline is absolute, not a lifetime" {
  let path = scratch("absolute")
  remove(path)
  let d = open_at(path, 10, 500L)
  ignore(
    d.put_with_ttl("k", "v", @tesseract_memory.ttl_absolute(1000L)).unwrap(),
  )
  ignore(d.memory().advance(500L))
  ignore(d.checkpoint().unwrap())
  let again = open_at(path, 10, 0L)
  let entry = again.entry("k").unwrap()
  assert_eq(entry.window_ms, 1000L)
  assert_eq(entry.deadline, 1500L)
  assert_eq(again.memory().now(), 1000L)
  assert_eq(entry.deadline - again.memory().now(), 500L)
  remove(path)
}

///|
/// The clock comes back with the entries.
///
/// A store on a manual clock that was reopened on a fresh one would find its
/// entries younger than they were, and the age it reports would be negative.
test "the clock comes back with the entries" {
  let path = scratch("clock")
  remove(path)
  let d = open_at(path, 10, 12345L)
  ignore(d.put("k", "v").unwrap())
  ignore(d.checkpoint().unwrap())
  let again = open_at(path, 10, 0L)
  assert_eq(again.memory().now(), 12345L)
  remove(path)
}

///|
/// A refused write leaves the store unchanged.
///
/// The store is full of pinned entries, so there is no room for the new one.
/// The refusal has to leave the store as it was **and** the file as it was: a
/// refused write that wrote the file would have written a different store.
test "a refused write leaves the store unchanged" {
  let path = scratch("refused")
  remove(path)
  let d = open_at(path, 1, 0L)
  ignore(
    d
    .put_spec("keep", "v", @tesseract_memory.default_spec().with_pinned(true))
    .unwrap(),
  )
  assert_eq(d.put("other", "v").unwrap(), false)
  assert_eq(d.get("keep"), Some("v"))
  assert_eq(d.get("other"), None)
  assert_eq(d.size(), 1)
  // And the file is the same store.
  let again = open_at(path, 1, 0L)
  assert_eq(again.get("keep"), Some("v"))
  assert_eq(again.get("other"), None)
  assert_eq(again.size(), 1)
  remove(path)
}

///|
/// The labels, the importance and the pin survive a reload.
test "the labels, the importance and the pin survive a reload" {
  let path = scratch("state")
  remove(path)
  let d = open_at(path, 10, 0L)
  ignore(
    d
    .put_spec(
      "k",
      "v",
      @tesseract_memory.default_spec()
      .with_importance(0.5)
      .with_metadata(@tesseract_memory.new_metadata([("kind", "task")]))
      .with_pinned(true),
    )
    .unwrap(),
  )
  let again = open_at(path, 10, 0L)
  let entry = again.entry("k").unwrap()
  assert_eq(entry.importance, 0.5)
  assert_eq(entry.pinned, true)
  assert_eq(entry.metadata.has_value("kind", "task"), true)
  remove(path)
}

///|
/// The scopes survive a reload, and a scope's key is not the default scope's.
test "the scopes survive a reload" {
  let path = scratch("scopes")
  remove(path)
  let d = open_at(path, 10, 0L)
  ignore(d.scope("work").put("todo", "ship").unwrap())
  ignore(d.put("todo", "buy milk").unwrap())
  let again = open_at(path, 10, 0L)
  assert_eq(again.scope("work").get("todo"), Some("ship"))
  assert_eq(again.get("todo"), Some("buy milk"))
  assert_eq(again.scopes().length(), 2)
  remove(path)
}

///|
/// The hit count survives a reload, so the ranking survives it too.
///
/// The count is what the LFU policy ranks by, so a store that came back with
/// its counters at zero would be a store that forgot which entries it had
/// been asked for.
test "the hit count survives a reload, so the ranking survives it too" {
  let path = scratch("hits")
  remove(path)
  let d = open_at(path, 10, 0L)
  ignore(d.put("k", "v").unwrap())
  ignore(d.get("k"))
  ignore(d.get("k"))
  ignore(d.checkpoint().unwrap())
  let again = open_at(path, 10, 0L)
  assert_eq(again.entry("k").unwrap().hits, 2L)
  remove(path)
}

///|
/// A file that is not there yet starts empty.
test "a file that is not there yet starts empty" {
  let path = scratch("new")
  remove(path)
  let d = open_at(path, 10, 0L)
  assert_eq(d.size(), 0)
  assert_eq(d.keys().length(), 0)
  remove(path)
}

///|
/// A checkpoint that does not fit the store it is opened with is refused.
///
/// It is refused rather than half-loaded: restoring an entry into a store
/// that is already full evicts the entries that were there, so a store
/// opened with too small a capacity would lose what the file held.
test "a checkpoint that does not fit the store it is opened with is refused" {
  let path = scratch("toobig")
  remove(path)
  let d = open_at(path, 10, 0L)
  ignore(d.put("a", "1").unwrap())
  ignore(d.put("b", "2").unwrap())
  ignore(d.checkpoint().unwrap())
  assert_true(refused(@tesseract_memory_db.open(path, config(1))))
  remove(path)
}

///|
/// A capacity a checkpoint lattice cannot hold is refused.
///
/// A store that could not be written out is not a store that can be reopened.
test "a capacity a checkpoint lattice cannot hold is refused" {
  let path = scratch("big")
  remove(path)
  assert_true(refused(@tesseract_memory_db.open(path, config(1000))))
  remove(path)
}

///|
/// The handle the store hands out is the store itself.
///
/// `DurableMemory::memory` returns the memory **by value**, and a value that
/// comes back by value could be a copy: a copy would have its own clock, its
/// own byte total and its own entry map, and the checkpoint would then be
/// written from a different store than the one the caller wrote to. The store
/// and the file are the same store, so the handle has to be the same store too.
test "the handle the store hands out is the store itself" {
  let path = scratch("handle")
  remove(path)
  let d = open_at(path, 10, 0L)
  let handle = d.memory()
  ignore(handle.put("k", "v"))
  // The write through the handle is in the store the checkpoint reads.
  assert_eq(d.size(), 1)
  assert_eq(d.get("k"), Some("v"))
  // And the clock moved through the handle is the clock the checkpoint writes.
  ignore(handle.advance(5000L))
  assert_eq(d.memory().now(), 5000L)
  ignore(d.checkpoint().unwrap())
  let again = open_at(path, 10, 0L)
  assert_eq(again.memory().now(), 5000L)
  assert_eq(again.get("k"), Some("v"))
  remove(path)
}

///|
/// A checkpoint on the host's clock does not override the clock it is opened
/// with.
///
/// A **manual** clock in the checkpoint wins, because the entries in it were
/// written on that timeline. The **system** clock is not a timeline at all —
/// it is the host's clock, and it says nothing about when anything was
/// written — so a checkpoint that carries it must not turn a manual clock
/// into the host's.
test "a checkpoint on the host's clock does not override the clock it is opened with" {
  let path = scratch("system")
  remove(path)
  let on_host = @tesseract_memory_db.open(path, config(10)).unwrap()
  ignore(on_host.put("k", "v").unwrap())
  let manual = @tesseract_memory_db.open_with_clock(
    path,
    config(10),
    @tesseract_memory.memory_clock_manual(0L),
  ).unwrap()
  assert_eq(manual.memory().clock().is_manual(), true)
  remove(path)
}

///|
/// A reload keeps the store's clock, and what that clock puts in the past
/// does not come back.
///
/// The clock moves here without a checkpoint, so the file still holds both
/// entries. The reload takes the file's entries, but the clock is the
/// store's — and the entry whose deadline the store's clock puts in the past
/// is dead, so it does not come back.
test "a reload keeps the store's clock, and what that clock puts in the past does not come back" {
  let path = scratch("reloadclock")
  remove(path)
  let d = open_at(path, 10, 0L)
  ignore(
    d.put_with_ttl("short", "a", @tesseract_memory.ttl_absolute(1000L)).unwrap(),
  )
  ignore(
    d
    .put_with_ttl("long", "b", @tesseract_memory.ttl_absolute(100000L))
    .unwrap(),
  )
  ignore(d.memory().advance(2000L))
  ignore(d.reload().unwrap())
  // The clock is where it was left, not where the file says it was.
  assert_eq(d.memory().now(), 2000L)
  assert_eq(d.get("short"), None)
  assert_eq(d.get("long"), Some("b"))
  assert_eq(d.size(), 1)
  remove(path)
}

///|
/// A reload does not take in an entry that is already dead.
///
/// The store's room is one entry wide, and the file holds two: the live one
/// and the one whose time was up before the clock moved. The entries are
/// restored in **key order**, so the live one is taken in first — and then
/// there is no room for the dead one.
///
/// A restore that took the dead one in would have to make room for it, and the
/// room would come out of the live one: a dead entry evicting a live one is
/// the store losing something to something that is not there. So the dead one
/// is refused, and the live one keeps its place.
///
/// The store's own sweep would drop the dead entry at the next observation
/// anyway, so the difference is not in what the store holds at the end. It is
/// in what it had to throw away to get there.
test "a reload does not take in an entry that is already dead" {
  let path = scratch("dead")
  remove(path)
  let d = open_at(path, 10, 0L)
  ignore(
    d
    .put_with_ttl("a-live", "bbbb", @tesseract_memory.ttl_absolute(100000L))
    .unwrap(),
  )
  ignore(
    d
    .put_with_ttl("b-dead", "aaaa", @tesseract_memory.ttl_absolute(1000L))
    .unwrap(),
  )
  // The room goes down to one entry.
  ignore(d.set_config(config(1)).unwrap())
  // The clock moves past the dead entry's deadline, without a checkpoint, so
  // the file still holds both of them.
  ignore(d.memory().advance(2000L))
  ignore(d.reload().unwrap())
  // The live entry is still there.
  assert_eq(d.get("a-live"), Some("bbbb"))
  assert_eq(d.get("b-dead"), None)
  assert_eq(d.size(), 1)
  remove(path)
}

///|
/// A reload replaces what the store holds with what the file holds.
test "a reload replaces what the store holds with what the file holds" {
  let path = scratch("reload")
  remove(path)
  let d = open_at(path, 10, 0L)
  ignore(d.put("k", "v").unwrap())
  ignore(d.checkpoint().unwrap())
  // A write through the raw store is **not** checkpointed, so the store and
  // the file have drifted apart. That is what the reload undoes.
  ignore(d.memory().put("extra", "w"))
  assert_eq(d.size(), 2)
  ignore(d.reload().unwrap())
  assert_eq(d.size(), 1)
  assert_eq(d.get("k"), Some("v"))
  assert_eq(d.get("extra"), None)
  remove(path)
}
