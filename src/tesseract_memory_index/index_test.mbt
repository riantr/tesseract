///|
/// The index: what it holds, and how it knows what it should hold.
///
/// The fixture writes a **real file**, and the tests read the table with SQL
/// rather than through the package's own door. The whole claim of the package
/// is that the index is a plain SQL table a person can query, so a test that
/// only ever asked the package would be asking the only witness that is not
/// independent.
///
/// The clock is a **manual** one, because a test that reads the host clock
/// cannot assert that something has not happened yet.
fn scratch(name : String) -> String {
  "tesseract_memory_index_test_" + name + ".db"
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
/// A memory with a capacity and a clock that only moves when it is told to.
fn memory(capacity : Int32) -> @tesseract_memory.Memory {
  @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_capacity(capacity),
    @tesseract_memory.memory_clock_manual(0L),
  )
}

///|
/// The store the tests share: three entries in two scopes.
///
/// - `a`, in the default scope: "the cat sat"
/// - `b`, in the default scope: "a dog barked"
/// - `c`, in the `notes` scope: "cat notes", carrying the kind `task`
///
/// Nine words in all, so the index of it holds nine rows — one for each word
/// of each entry, the kind's **value** included.
fn sample() -> @tesseract_memory.Memory {
  let m = memory(10)
  ignore(m.put("a", "the cat sat"))
  ignore(m.put("b", "a dog barked"))
  ignore(
    m
    .scope("notes")
    .put_spec(
      "c",
      "cat notes",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "task")]),
      ),
    ),
  )
  m
}

///|
/// The rows in the file, read straight out of it.
fn rows(path : String) -> Array[(String, String, String)] raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  let stmt = conn.prepare(
    "SELECT token, scope, key FROM tesseract_memory_index ORDER BY token, scope, key",
  )
  defer stmt.finalize()
  let out : Array[(String, String, String)] = []
  while stmt.step() {
    let token : String = stmt.column(index=0)
    let scope : String = stmt.column(index=1)
    let key : String = stmt.column(index=2)
    out.push((token, scope, key))
  }
  out
}

///|
/// The rows as one string each, so a test can say what it expects in a line.
fn row_text(path : String) -> Array[String] raise {
  let out : Array[String] = []
  for (token, scope, key) in rows(path) {
    out.push(token + "@" + scope + "/" + key)
  }
  out
}

///|
/// Whether two sets of rows are the same.
///
/// The comparison is element by element rather than `assert_eq` on the arrays,
/// so a failure says **which** row is the one that differs.
fn same_rows(a : Array[String], b : Array[String]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// Runs one statement against the index file, as a person editing it would.
fn edit(path : String, sql : String) -> Unit raise {
  let conn = @sqlite3.Connection::open(path)
  defer conn.close()
  let stmt = conn.prepare(sql)
  defer stmt.finalize()
  ignore(stmt.step())
}

///|
/// The rows are exactly what the entries say.
///
/// One row for each word of each entry, and the kind's **value** is one of
/// those words. The index is a table of words, so this is the whole of what it
/// holds — anything else in it would be a thing the store does not have.
test "the rows are exactly what the entries say" {
  let path = scratch("rows")
  remove(path)
  let m = sample()
  let index = @tesseract_memory_index.open(path).unwrap()
  let report = index.rebuild(m).unwrap()
  assert_eq(report.entries, 3)
  assert_eq(report.added, 9)
  assert_eq(report.changed, 3)
  assert_eq(report.removed, 0)
  let got = row_text(path)
  assert_eq(got.length(), 9)
  assert_eq(got[0], "a@default/b")
  assert_eq(got[1], "barked@default/b")
  assert_eq(got[2], "cat@default/a")
  assert_eq(got[3], "cat@notes/c")
  assert_eq(got[4], "dog@default/b")
  assert_eq(got[5], "notes@notes/c")
  assert_eq(got[6], "sat@default/a")
  assert_eq(got[7], "task@notes/c")
  assert_eq(got[8], "the@default/a")
  remove(path)
}

///|
/// A rebuild of an index that was already right changes nothing.
///
/// This is the proof that the index is **derivative**: it holds nothing the
/// entries do not, so recomputing it finds the same thing and the report says
/// nothing at all. An index that were not derivative — one holding something
/// of its own — would come back with a change every time.
test "a rebuild of an index that was already right changes nothing" {
  let path = scratch("derivative")
  remove(path)
  let m = sample()
  let index = @tesseract_memory_index.open(path).unwrap()
  ignore(index.rebuild(m).unwrap())
  let before = row_text(path)
  let again = index.rebuild(m).unwrap()
  assert_eq(again.entries, 3)
  assert_eq(again.changed, 0)
  assert_eq(again.added, 0)
  assert_eq(again.removed, 0)
  // And the file is the same file, down to the rows.
  assert_true(same_rows(before, row_text(path)))
  // A verify asks the same question without the answer, and agrees.
  let clean = index.verify(m).unwrap()
  assert_eq(clean.changed, 0)
  assert_eq(clean.added, 0)
  assert_eq(clean.removed, 0)
  remove(path)
}

///|
/// A drifted index is detected, and repaired.
///
/// The file is edited by hand: a row of a live entry is taken away, and a row
/// for an entry the store does not have is put in. The verify says how far the
/// index is from the store, and the rebuild puts it back.
test "a drifted index is detected and repaired" {
  let path = scratch("drift")
  remove(path)
  let m = sample()
  let index = @tesseract_memory_index.open(path).unwrap()
  ignore(index.rebuild(m).unwrap())
  edit(
    path, "DELETE FROM tesseract_memory_index WHERE token = 'cat' AND scope = 'default' AND key = 'a'",
  )
  edit(
    path, "INSERT INTO tesseract_memory_index (token, scope, key) VALUES ('ghost', 'default', 'zzz')",
  )
  // The drift: one row to put back, one row to take away, and two entries
  // that are not what the store says.
  let drift = index.verify(m).unwrap()
  assert_eq(drift.entries, 3)
  assert_eq(drift.changed, 2)
  assert_eq(drift.added, 1)
  assert_eq(drift.removed, 1)
  // A verify changes **nothing**, so the file still holds the drift: the row
  // that was taken away is still away, and the row that was put in is still
  // in. The row count cannot tell the two apart — the repair leaves the same
  // number of rows — so the drift is looked for by what it says.
  assert_eq(index.rows().unwrap(), 9)
  assert_eq(index.lookup("cat").unwrap().length(), 1)
  assert_eq(index.lookup("ghost").unwrap().length(), 1)
  // The rebuild says the same thing — the drift it found is the drift there
  // is — and repairs it.
  let repaired = index.rebuild(m).unwrap()
  assert_eq(repaired.changed, 2)
  assert_eq(repaired.added, 1)
  assert_eq(repaired.removed, 1)
  let clean = index.verify(m).unwrap()
  assert_eq(clean.changed, 0)
  assert_eq(clean.added, 0)
  assert_eq(clean.removed, 0)
  assert_eq(index.rows().unwrap(), 9)
  let got = row_text(path)
  assert_eq(got.length(), 9)
  assert_eq(got[2], "cat@default/a")
  assert_eq(got[3], "cat@notes/c")
  remove(path)
}

///|
/// The index is disposable.
///
/// The file is thrown away and the rebuild gives back the same index. That is
/// the property that makes an index worth having: a caller who does not trust
/// it can delete it, and the next rebuild is the index the store says.
test "the index is disposable" {
  let path = scratch("disposable")
  remove(path)
  let m = sample()
  let index = @tesseract_memory_index.open(path).unwrap()
  ignore(index.rebuild(m).unwrap())
  let before = row_text(path)
  // The file goes, and the index goes with it.
  remove(path)
  let report = index.rebuild(m).unwrap()
  assert_eq(report.entries, 3)
  assert_eq(report.changed, 3)
  assert_eq(report.added, 9)
  assert_eq(report.removed, 0)
  assert_true(same_rows(before, row_text(path)))
  remove(path)
}

///|
/// The key of a label is not a word; its value is.
///
/// "kind" is the name of the label, and every entry with a kind would then be
/// found by the word "kind" — which says nothing about the entry. The value
/// is the content, so the value is the word.
test "the key of a label is not a word; its value is" {
  let path = scratch("labels")
  remove(path)
  let m = sample()
  let index = @tesseract_memory_index.open(path).unwrap()
  ignore(index.rebuild(m).unwrap())
  assert_eq(index.lookup("kind").unwrap().length(), 0)
  let found = index.lookup("task").unwrap()
  assert_eq(found.length(), 1)
  assert_eq(found[0].0, "notes")
  assert_eq(found[0].1, "c")
  remove(path)
}

///|
/// The index covers every scope, not just the default one.
///
/// The scopes are the store's own, so a word in the `notes` scope is found the
/// same way a word in the default scope is.
test "the index covers every scope" {
  let path = scratch("scopes")
  remove(path)
  let m = sample()
  let index = @tesseract_memory_index.open(path).unwrap()
  ignore(index.rebuild(m).unwrap())
  let found = index.lookup("cat").unwrap()
  assert_eq(found.length(), 2)
  assert_eq(found[0].0, "default")
  assert_eq(found[0].1, "a")
  assert_eq(found[1].0, "notes")
  assert_eq(found[1].1, "c")
  remove(path)
}

///|
/// The lookup is exact.
///
/// The memory's own search is a similarity; this is not that. A word that is
/// part of another word is not the word, and a word that is only there in
/// another case is the same word — the index holds the words the tokenizer
/// wrote, and the tokenizer lowercases.
test "the lookup is exact" {
  let path = scratch("exact")
  remove(path)
  let m = sample()
  let index = @tesseract_memory_index.open(path).unwrap()
  ignore(index.rebuild(m).unwrap())
  assert_eq(index.lookup("ca").unwrap().length(), 0)
  assert_eq(index.lookup("cats").unwrap().length(), 0)
  assert_eq(index.lookup("nothing").unwrap().length(), 0)
  assert_eq(index.lookup("Cat").unwrap().length(), 2)
  assert_eq(index.lookup("cat").unwrap().length(), 2)
  remove(path)
}

///|
/// Putting an entry again replaces its rows.
///
/// An entry whose value changed is indexed under its new words and not its old
/// ones — otherwise the index would answer with an entry that no longer says
/// what the index claims it says.
test "putting an entry again replaces its rows" {
  let path = scratch("replace")
  remove(path)
  let m = sample()
  let index = @tesseract_memory_index.open(path).unwrap()
  ignore(index.rebuild(m).unwrap())
  ignore(m.put("a", "the owl sat"))
  let entry = m.entry("a").unwrap()
  index.put(entry).unwrap()
  // "cat" is left to the entry in the other scope.
  let cat = index.lookup("cat").unwrap()
  assert_eq(cat.length(), 1)
  assert_eq(cat[0].1, "c")
  let owl = index.lookup("owl").unwrap()
  assert_eq(owl.length(), 1)
  assert_eq(owl[0].0, "default")
  assert_eq(owl[0].1, "a")
  assert_eq(index.rows().unwrap(), 9)
  remove(path)
}

///|
/// Forgetting an entry drops its rows and leaves the entry alone.
///
/// The index is not the store. A row that is taken away is a word the index
/// no longer answers with — and the entry it was in is still there.
test "forgetting an entry drops its rows and leaves the entry alone" {
  let path = scratch("forget")
  remove(path)
  let m = sample()
  let index = @tesseract_memory_index.open(path).unwrap()
  ignore(index.rebuild(m).unwrap())
  index.forget("default", "a").unwrap()
  assert_eq(index.lookup("sat").unwrap().length(), 0)
  assert_eq(index.lookup("the").unwrap().length(), 0)
  // The other scope's entry keeps its rows.
  assert_eq(index.lookup("cat").unwrap().length(), 1)
  assert_eq(index.rows().unwrap(), 6)
  // The entry itself is untouched: the index is not the store.
  assert_eq(m.get("a"), Some("the cat sat"))
  remove(path)
}

///|
/// A rebuild puts back what a forget took away.
///
/// The index is derived from the store, so the store is what decides: an entry
/// the store still holds is indexed again, whatever the index said before.
test "a rebuild puts back what a forget took away" {
  let path = scratch("rebuild-forgotten")
  remove(path)
  let m = sample()
  let index = @tesseract_memory_index.open(path).unwrap()
  ignore(index.rebuild(m).unwrap())
  index.forget("default", "a").unwrap()
  assert_eq(index.rows().unwrap(), 6)
  let report = index.rebuild(m).unwrap()
  assert_eq(report.changed, 1)
  assert_eq(report.added, 3)
  assert_eq(report.removed, 0)
  assert_eq(index.rows().unwrap(), 9)
  assert_eq(index.lookup("sat").unwrap().length(), 1)
  remove(path)
}

///|
/// An entry that is gone from the store is gone from the index.
///
/// The store is what decides which entries exist, so an entry the store has
/// forgotten has no rows — and a rebuild takes the rows away.
test "an entry that is gone from the store is gone from the index" {
  let path = scratch("gone")
  remove(path)
  let m = sample()
  let index = @tesseract_memory_index.open(path).unwrap()
  ignore(index.rebuild(m).unwrap())
  ignore(m.delete("b"))
  let report = index.rebuild(m).unwrap()
  assert_eq(report.entries, 2)
  assert_eq(report.changed, 1)
  assert_eq(report.added, 0)
  assert_eq(report.removed, 3)
  assert_eq(index.rows().unwrap(), 6)
  assert_eq(index.lookup("barked").unwrap().length(), 0)
  remove(path)
}

///|
/// An entry that is dead is not in the index.
///
/// The store's dead entries are not entries: an expired one is gone the
/// moment its time is up. So the index does not answer with it either.
test "an entry that is dead is not in the index" {
  let path = scratch("dead")
  remove(path)
  let m = memory(10)
  ignore(
    m.put_with_ttl(
      "short",
      "a fading word",
      @tesseract_memory.ttl_absolute(1000L),
    ),
  )
  ignore(m.put("long", "a lasting word"))
  let index = @tesseract_memory_index.open(path).unwrap()
  ignore(index.rebuild(m).unwrap())
  assert_eq(index.lookup("fading").unwrap().length(), 1)
  ignore(m.advance(2000L))
  let report = index.rebuild(m).unwrap()
  assert_eq(report.entries, 1)
  // The dead entry carried three words — "a", "fading" and "word" — and all
  // three rows go with it.
  assert_eq(report.removed, 3)
  assert_eq(index.lookup("fading").unwrap().length(), 0)
  assert_eq(index.lookup("lasting").unwrap().length(), 1)
  remove(path)
}

///|
/// A verify of an index that is not there says the whole story.
///
/// The file does not exist, so the index holds nothing, and the report says
/// what the store would put into it. The verify does not create the file: a
/// read that wrote would be a read that lied.
test "a verify of an index that is not there says the whole story" {
  let path = scratch("missing")
  remove(path)
  let m = sample()
  let index = @tesseract_memory_index.open(path).unwrap()
  remove(path)
  let report = index.verify(m).unwrap()
  assert_eq(report.entries, 3)
  assert_eq(report.changed, 3)
  assert_eq(report.added, 9)
  assert_eq(report.removed, 0)
  // The file is still not there: the verify did not create it.
  assert_false(@xfs.path_exists(path))
  remove(path)
}

///|
/// The index folds and orders the way the core does.
///
/// The word a lookup asks for is folded with the core's own folding, so "Cat"
/// finds the entry that says "cat". And the answer is in the core's text
/// order — the runtime's own comparison is length-first, and it would put
/// "work" before "default".
///
/// Both are the core's decisions, and this index is only the core's index: an
/// index that folded or ordered the text its own way would answer a lookup
/// differently from the store it is an index of, and the two would disagree
/// about what the entry says.
test "the index folds and orders the way the core does" {
  let path = scratch("fold")
  remove(path)
  let index = @tesseract_memory_index.open(path).unwrap()
  let m = memory(10)
  ignore(m.put("cat", "cat sat"))
  ignore(m.scope("work").put("cat", "cat sat"))
  ignore(index.rebuild(m).unwrap())
  // The core's own folding and its own order, which are the two the index
  // uses.
  assert_eq(@tesseract.lower("Cat"), "cat")
  assert_true(@tesseract.compare_text("default", "work") < 0)
  // And the runtime's own comparison would have it the other way round: it is
  // length-first, so "work" would come before "default". That is the whole
  // reason the core has a text order of its own.
  assert_true("work" < "default")
  // The word is folded with the core's folding, so "Cat" finds the entries
  // that say "cat".
  let found = index.lookup("Cat").unwrap()
  assert_eq(found.length(), 2)
  // And the answer is in the core's text order: "default" before "work".
  assert_eq(found[0].0, "default")
  assert_eq(found[1].0, "work")
  remove(path)
}
