///|
/// The kinds: a store that holds different kinds of thing, and can say what
/// they are.
///
/// The kind is the value of the `kind` label. Nothing about it is stored
/// separately, so a filter that asks for a kind is a filter like any other, a
/// report that lists the kinds is a report over the labels, and the checkpoint
/// that stores an entry does not have to learn what a kind is.

///|
/// Writes an entry of a kind.
fn put_kind(
  m : @tesseract_memory.Memory,
  kind : String,
  key : String,
  value : String,
) -> Bool {
  m.put_spec(
    key,
    value,
    @tesseract_memory.default_spec().with_metadata(
      @tesseract_memory.no_metadata().with_kind(kind),
    ),
  )
}

///|
/// The kind is a label, so the label system does the work.
test "the kind is a label, so the label system does the work" {
  let m = @tesseract_memory.new_memory(10)
  ignore(put_kind(m, "task", "todo", "ship it"))
  let entry = m.entry("todo").unwrap()
  // The kind is the label, and the label is there for a filter to find.
  assert_eq(entry.metadata().has_value("kind", "task"), true)
  assert_eq(entry.kind(), Some("task"))
  // And a filter that asks for that label admits the entry.
  let hits = m.search_filtered(
    "ship",
    3,
    @tesseract_memory.filter_equals("kind", "task"),
  )
  assert_eq(hits.length(), 1)
}

///|
/// An entry that says nothing about what it is has no kind.
test "an entry that says nothing about what it is has no kind" {
  let m = @tesseract_memory.new_memory(10)
  ignore(m.put("plain", "just a value"))
  assert_eq(m.entry("plain").unwrap().kind(), None)
}

///|
/// The store can say what kinds it holds, and how many of each.
test "the store can say what kinds it holds, and how many of each" {
  let m = @tesseract_memory.new_memory(10)
  ignore(put_kind(m, "task", "a", "1"))
  ignore(put_kind(m, "note", "b", "2"))
  ignore(put_kind(m, "task", "c", "3"))
  // An entry of no kind is of no kind, and is not counted.
  ignore(m.put("plain", "4"))
  let kinds = m.kinds()
  assert_eq(kinds.length(), 2)
  assert_eq(kinds[0].0, "note")
  assert_eq(kinds[0].1, 1)
  assert_eq(kinds[1].0, "task")
  assert_eq(kinds[1].1, 2)
}

///|
/// The kinds come out in the same order however the store was filled.
test "the kinds come out in the same order however the store was filled" {
  let one = @tesseract_memory.new_memory(10)
  ignore(put_kind(one, "task", "a", "1"))
  ignore(put_kind(one, "note", "b", "2"))
  let other = @tesseract_memory.new_memory(10)
  ignore(put_kind(other, "note", "b", "2"))
  ignore(put_kind(other, "task", "a", "1"))
  assert_eq(one.kinds()[0].0, other.kinds()[0].0)
  assert_eq(one.kinds()[1].0, other.kinds()[1].0)
}

///|
/// The entries of one kind, and only those.
test "the entries of one kind, and only those" {
  let m = @tesseract_memory.new_memory(10)
  ignore(put_kind(m, "task", "a", "1"))
  ignore(put_kind(m, "note", "b", "2"))
  ignore(put_kind(m, "task", "c", "3"))
  ignore(m.put("plain", "4"))
  let tasks = m.entries_of_kind("task")
  assert_eq(tasks.length(), 2)
  assert_eq(tasks[0].key(), "a")
  assert_eq(tasks[1].key(), "c")
}

///|
/// A scope has its own kinds, and its own entries of each kind.
test "a scope has its own kinds, and its own entries of each kind" {
  let m = @tesseract_memory.new_memory(10)
  let work = m.scope("work")
  ignore(
    work.put_spec(
      "a",
      "1",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.no_metadata().with_kind("task"),
      ),
    ),
  )
  ignore(put_kind(m, "note", "b", "2"))
  assert_eq(work.kinds().length(), 1)
  assert_eq(work.kinds()[0].0, "task")
  assert_eq(work.kinds()[0].1, 1)
  assert_eq(work.entries_of_kind("task").length(), 1)
  // The store counts every scope, and the scope counts only its own.
  assert_eq(m.kinds().length(), 2)
}

///|
/// The kind is one value: a metadata that already had one is given the new one.
test "the kind is one value: a metadata that already had one is given the new one" {
  let meta = @tesseract_memory.no_metadata().with_kind("task").with_kind("note")
  assert_eq(meta.has_value("kind", "task"), false)
  assert_eq(meta.has_value("kind", "note"), true)
}

///|
/// An empty kind takes the kind away rather than writing an empty one.
test "an empty kind takes the kind away rather than writing an empty one" {
  let meta = @tesseract_memory.no_metadata().with_kind("task").with_kind("")
  assert_eq(meta.has("kind"), false)
  let m = @tesseract_memory.new_memory(10)
  ignore(put_kind(m, "", "a", "1"))
  assert_eq(m.entry("a").unwrap().kind(), None)
  assert_eq(m.kinds().length(), 0)
}
