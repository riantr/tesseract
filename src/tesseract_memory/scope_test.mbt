///|
/// The scopes of a memory: partitions of one keyspace, one budget, one clock.
///
/// A scope is not a second store. It is a partition of the store's keyspace,
/// and the rules that follow from that are the whole of what these tests
/// check: the entries of one scope are invisible to another, and the limits
/// — the capacity, the byte budget, the clock — are the **store's**, so a
/// write into one scope can evict an entry from another.
///
/// The clock is manual in every test, so each of these is a number rather
/// than a race.

///|
/// A memory on a clock the test moves by hand.
fn scoped_memory_at(start_ms : Int64) -> @tesseract_memory.Memory {
  @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_capacity(10),
    @tesseract_memory.memory_clock_manual(start_ms),
  )
}

///|
/// The keys of a scope, in order.
fn scope_keys(scope : @tesseract_memory.Scope) -> String {
  scope.keys().join(",")
}

///|
/// The names of the scopes a memory reports.
fn scope_names(m : @tesseract_memory.Memory) -> String {
  m.scopes().join(",")
}

///|
/// Two scopes can hold the same key, and neither sees the other's entry.
///
/// A scope partitions the keyspace, so the key `todo` in one scope and the
/// key `todo` in another are two different entries. A store that let them
/// see each other would not be partitioning anything — it would be one
/// keyspace with two names for it.
test "two scopes can hold the same key, and neither sees the other's entry" {
  let m = scoped_memory_at(0L)
  ignore(m.put("todo", "ship it"))
  ignore(m.scope("notes").put("todo", "buy milk"))
  // Each scope reads its own.
  assert_eq(m.get("todo"), Some("ship it"))
  assert_eq(m.scope("notes").get("todo"), Some("buy milk"))
  // And the memory's own methods are the default scope's, so the memory does
  // not see the other scope's entry either.
  assert_eq(m.keys().join(","), "todo")
  assert_eq(scope_keys(m.scope("notes")), "todo")
  assert_false(m.contains("todo") == false)
  // The two entries are two entries.
  assert_eq(m.size(), 2)
}

///|
/// A scope is a handle, not a copy.
///
/// Two handles on the same scope are two windows onto one set of entries, and
/// the store's byte total is one total. A scope that was a copy would show
/// its own entries and its own bytes, and the two would drift apart.
test "a scope is a handle, not a copy" {
  let m = scoped_memory_at(0L)
  let work = m.scope("work")
  // Written through one handle...
  ignore(m.scope("work").put("a", "1"))
  // ...and read through another.
  assert_eq(work.get("a"), Some("1"))
  assert_eq(work.size(), 1)
  // And the byte total is the store's, not one per handle.
  ignore(work.put("b", "22"))
  assert_eq(m.size_bytes(), 3L)
  assert_eq(work.size_bytes(), 3L)
}

///|
/// The store's size counts every scope, and a scope's size counts only its own.
///
/// The capacity is the store's, so the number to compare with it is the
/// store's count. The two are different numbers once a second scope holds
/// something, and saying so is the point: a caller who compares a scope's
/// size with the capacity would think there was more room than there is.
test "the store's size counts every scope, and a scope's size counts only its own" {
  let m = scoped_memory_at(0L)
  ignore(m.put("a", "1"))
  ignore(m.scope("work").put("b", "2"))
  assert_eq(m.size(), 2)
  assert_eq(m.default_scope().size(), 1)
  assert_eq(m.scope("work").size(), 1)
}

///|
/// The capacity is the store's, so a write in one scope can evict an entry in another.
///
/// A scope is a partition of one pool. If each scope had a budget of its own,
/// the store would hold `scopes * capacity` entries, and a limit that grows
/// with the number of partitions is not a limit.
test "the capacity is the store's, so a write in one scope can evict an entry in another" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_capacity(2),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "1"))
  ignore(m.scope("work").put("b", "2"))
  assert_eq(m.size(), 2)
  // A third entry does not fit, and the room is made by taking an entry out
  // of the *other* scope.
  ignore(m.scope("work").put("c", "3"))
  assert_eq(m.size(), 2)
  assert_eq(scope_keys(m.default_scope()), "")
  assert_eq(scope_keys(m.scope("work")), "b,c")
  assert_eq(m.stats().evictions, 1L)
}

///|
/// The byte budget is the store's too.
///
/// The budget is spent on the values of every scope, so a write into one
/// scope can be refused for the room another scope is taking.
test "the byte budget is the store's too" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_max_bytes(10L),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "12345"))
  ignore(m.scope("work").put("b", "12345"))
  assert_eq(m.size_bytes(), 10L)
  // One more byte does not fit, so the store makes room by evicting an entry
  // from the other scope.
  ignore(m.scope("work").put("c", "1"))
  assert_eq(m.size_bytes(), 6L)
  assert_eq(scope_keys(m.default_scope()), "")
  assert_eq(scope_keys(m.scope("work")), "b,c")
}

///|
/// A tie is broken by the scope before the key.
///
/// The eviction order has to be a rule and not an accident of the order the
/// entries happened to be written in. Two entries that tie on the policy are
/// separated by where they live, and then by their key — so the same program
/// always evicts the same entry, whichever scope it is in.
test "a tie is broken by the scope before the key" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_capacity(2),
    @tesseract_memory.memory_clock_manual(0L),
  )
  // Two entries that tie on the policy, with their scopes and keys crossed:
  // ("b", "a") and ("a", "b"). The scope decides, so the one in scope "a"
  // goes first, even though its key is the later of the two alphabetically.
  ignore(m.scope("b").put("a", "1"))
  ignore(m.scope("a").put("b", "2"))
  ignore(m.scope("b").put("c", "3"))
  assert_eq(scope_keys(m.scope("a")), "")
  assert_eq(scope_keys(m.scope("b")), "a,c")
}

///|
/// The clock is the store's, so an entry in any scope expires on time.
///
/// The scopes share one clock, so one `advance` moves every scope's idea of
/// time, and an entry in a scope nobody looked at expires exactly when it
/// would have expired in any other.
test "the clock is the store's, so an entry in any scope expires on time" {
  let m = scoped_memory_at(0L)
  ignore(m.put_with_ttl("a", "x", @tesseract_memory.ttl_absolute(1000L)))
  ignore(
    m
    .scope("work")
    .put_with_ttl("b", "y", @tesseract_memory.ttl_absolute(1000L)),
  )
  ignore(m.advance(1000L))
  assert_eq(m.size(), 0)
  assert_eq(m.scope("work").size(), 0)
}

///|
/// A scope that holds nothing is not a scope the store reports.
///
/// Listing it would send the caller looking in a place where there is nothing
/// to find, and would make the number of scopes a number that goes up and
/// down with the work rather than with the partitions the caller asked for.
test "a scope that holds nothing is not a scope the store reports" {
  let m = scoped_memory_at(0L)
  assert_eq(m.scopes().length(), 0)
  ignore(m.put("a", "1"))
  ignore(m.scope("work").put("b", "2"))
  assert_eq(scope_names(m), "default,work")
  ignore(m.delete("a"))
  assert_eq(scope_names(m), "work")
  ignore(m.scope("work").delete("b"))
  assert_eq(m.scopes().length(), 0)
}

///|
/// A search in a scope sees only that scope, and a search across the store says which scope a hit is in.
///
/// A key is unique only within a scope, so a hit from a store-wide search
/// only says which entry it is when it says which scope it is in.
test "a search in a scope sees only that scope, and a search across the store says which scope a hit is in" {
  let m = scoped_memory_at(0L)
  ignore(m.put("cat", "the cat sat"))
  ignore(m.scope("work").put("cat", "a cat in the work scope"))
  // A scoped search sees that scope only.
  let scoped = m.scope("work").search("cat", 10)
  assert_eq(scoped.length(), 1)
  assert_eq(scoped[0].scope(), "work")
  assert_eq(scoped[0].key(), "cat")
  // And the memory's own search is the default scope's.
  assert_eq(m.search("cat", 10).length(), 1)
  assert_eq(m.search("cat", 10)[0].scope(), "default")
  // The store-wide search sees both, and says which is which.
  let all = m.search_all("cat", 10)
  assert_eq(all.length(), 2)
  let names : Array[String] = []
  for hit in all {
    names.push(hit.scope())
  }
  names.sort_by(fn(a, b) { @tesseract.compare_text(a, b) })
  assert_eq(names.join(","), "default,work")
}

///|
/// An entry says which scope it is in.
///
/// The scope is part of the entry's identity, and an entry that did not say
/// where it lived could not be told from the same key in another scope.
test "an entry says which scope it is in" {
  let m = scoped_memory_at(0L)
  ignore(m.put("a", "1"))
  ignore(m.scope("work").put("b", "2"))
  assert_eq(m.entry("a").unwrap().scope(), "default")
  assert_eq(m.scope("work").entry("b").unwrap().scope(), "work")
}

///|
/// Clearing a scope forgets that scope, and clearing the memory forgets them all.
///
/// The two are different operations and the difference matters: a caller who
/// wants to empty one partition should not empty the store by accident, and a
/// caller who wants to empty the store should not have to know how many
/// scopes there are.
test "clearing a scope forgets that scope, and clearing the memory forgets them all" {
  let m = scoped_memory_at(0L)
  ignore(m.put("a", "1"))
  ignore(m.scope("work").put("b", "2"))
  m.scope("work").clear()
  assert_eq(m.scope("work").size(), 0)
  assert_eq(m.size(), 1)
  assert_eq(m.size_bytes(), 1L)
  m.clear()
  assert_eq(m.size(), 0)
  assert_eq(m.size_bytes(), 0L)
}

///|
/// The statistics are the store's.
///
/// One store did the work, so one set of counters reports it: a write into
/// one scope and a read out of another are both counted, because there is one
/// store behind them.
test "the statistics are the store's" {
  let m = scoped_memory_at(0L)
  ignore(m.scope("work").put("a", "1"))
  ignore(m.get("b"))
  assert_eq(m.stats().puts, 1L)
  assert_eq(m.stats().gets, 1L)
  assert_eq(m.stats().misses, 1L)
  assert_eq(m.stats().hits, 0L)
}

///|
/// A scope's puts use the store's default TTL.
///
/// The default TTL is a setting of the store, not of a partition of it, so
/// every scope of one memory expires on the same policy.
test "a scope's puts use the store's default TTL" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config()
    .with_capacity(10)
    .with_default_ttl(@tesseract_memory.ttl_absolute(1000L)),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.scope("work").put("a", "1"))
  assert_eq(m.scope("work").get("a"), Some("1"))
  ignore(m.advance(1000L))
  assert_eq(m.scope("work").get("a"), None)
}

///|
/// A refused write in one scope leaves the whole store as it was.
///
/// A write that fails should not cost the caller the entries it already has,
/// and the entries it already has are in every scope, not only in the one
/// that was written to.
test "a refused write in one scope leaves the whole store as it was" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_max_bytes(10L),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "12345"))
  ignore(m.scope("work").put("b", "12345"))
  assert_false(m.scope("work").put("big", "12345678901"))
  assert_eq(m.size(), 2)
  assert_eq(m.size_bytes(), 10L)
  assert_eq(m.stats().evictions, 0L)
}

///|
/// The key being written is never the victim, even when another scope could be.
///
/// The exclusion is of the *pair* — the scope and the key — and not of the key
/// alone. An exclusion by key alone would spare every scope's entry with that
/// name, and a store that could not evict any of them would have no way to
/// make room at all.
test "the key being written is never the victim, even when another scope could be" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_max_bytes(10L),
    @tesseract_memory.memory_clock_manual(0L),
  )
  // Both scopes hold a key called "b", so the two exclusions differ.
  ignore(m.put("b", "12345"))
  ignore(m.scope("work").put("b", "12345"))
  // Replacing the one in "work" with a longer value has to make room, and the
  // entry it makes room with is the one in the *other* scope — not the one
  // being written, and not the other scope's entry with the same name.
  assert_true(m.scope("work").put("b", "1234567890"))
  assert_eq(m.scope("work").get("b"), Some("1234567890"))
  assert_eq(m.default_scope().get("b"), None)
  assert_eq(m.size_bytes(), 10L)
  assert_eq(m.stats().evictions, 1L)
}

///|
/// The byte total stays right across scopes.
///
/// A total that drifts is worse than no total: the budget stops meaning
/// anything, and the drift only shows up as an eviction that happens too
/// early or too late.
test "the byte total stays right across scopes" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_max_bytes(1000L),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "12345"))
  ignore(m.scope("work").put("b", "67890"))
  assert_eq(m.size_bytes(), 10L)
  assert_eq(m.scope("work").size_bytes(), 5L)
  // Replacing a value in one scope.
  ignore(m.scope("work").put("b", "1234567890"))
  assert_eq(m.size_bytes(), 15L)
  assert_eq(m.scope("work").size_bytes(), 10L)
  // Forgetting one.
  ignore(m.scope("work").delete("b"))
  assert_eq(m.size_bytes(), 5L)
  assert_eq(m.scope("work").size_bytes(), 0L)
  // And an expiry in one scope.
  ignore(
    m
    .scope("work")
    .put_with_ttl("c", "xyz", @tesseract_memory.ttl_absolute(1000L)),
  )
  assert_eq(m.size_bytes(), 8L)
  ignore(m.advance(1000L))
  assert_eq(m.size_bytes(), 5L)
}

///|
/// A scope's filtered key search answers the same as the scope's hits.
///
/// The scope's own search is over that scope alone, and the filtered one adds
/// the labels on top. A caller that asks for the keys rather than the hits
/// has to get the same answer — otherwise the scope would offer two answers
/// to one question.
test "a scope's filtered key search answers the same as its hits" {
  let m = scoped_memory_at(0L)
  let work = m.scope("work")
  ignore(work.put("a", "cat dog"))
  ignore(work.put("b", "cat"))
  ignore(m.scope("other").put("c", "cat"))
  // A filter that asks for nothing holds, so it admits every entry.
  let everything = @tesseract_memory.filter_all([])
  let hits = work.search_filtered("cat", 10, everything)
  let keys = work.search_filtered_keys("cat", 10, everything)
  assert_eq(hits.length(), keys.length())
  assert_eq(keys.length(), 2)
  let mut i = 0
  while i < keys.length() {
    assert_eq(hits[i].key(), keys[i])
    i = i + 1
  }
  // The other scope's entry is not a candidate: a scope is a partition of the
  // keyspace, not a second view of it.
  assert_false(keys.contains("c"))
}
