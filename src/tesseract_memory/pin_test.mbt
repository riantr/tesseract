///|
/// The pin: an entry that is never evicted to make room for another one.
///
/// A pin is a promise about the **eviction** and nothing else. It does not
/// make an entry immortal, it does not change how strongly the entry is
/// found, and it does not make the entry free — a pinned entry still takes up
/// the room the capacity and the budget count.
///
/// The promise is absolute. A store that broke a pin when it had to would
/// make the promise depend on the state of the store, so a store that cannot
/// make room for a write without breaking a pin **refuses the write** — and
/// the refusal leaves the store exactly as it was. That last part is the one
/// that is easy to get wrong, and it is what the fourth test is about.
///
/// The clock is manual in every test, so each of these is a number rather
/// than a race.

///|
/// A memory on a clock the test moves by hand.
fn pin_memory_at(start_ms : Int64) -> @tesseract_memory.Memory {
  @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_capacity(10),
    @tesseract_memory.memory_clock_manual(start_ms),
  )
}

///|
/// A memory with a capacity, on a clock the test moves by hand.
fn pin_memory_with(
  capacity : Int32,
  max_bytes : Int64,
  policy : @tesseract_memory.EvictionPolicy,
) -> @tesseract_memory.Memory {
  @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config()
    .with_capacity(capacity)
    .with_max_bytes(max_bytes)
    .with_eviction(policy),
    @tesseract_memory.memory_clock_manual(0L),
  )
}

///|
/// A spec that pins its entry.
fn pinned_spec() -> @tesseract_memory.EntrySpec {
  @tesseract_memory.default_spec().with_pinned(true)
}

///|
/// The keys a memory holds, in order.
fn pin_keys(m : @tesseract_memory.Memory) -> String {
  m.keys().join(",")
}

///|
/// A pinned entry is not the one thrown away.
///
/// The policy would pick "keep" — it is the least recently used, and the
/// tie-break is by the letters, so "keep" sorts before "other". The pin is
/// what saves it, and "other" goes instead.
test "a pinned entry is not the one thrown away" {
  let m = pin_memory_with(2, 0L, @tesseract_memory.evict_lru())
  ignore(m.put_spec("keep", "kept", pinned_spec()))
  ignore(m.put("other", "dropped"))
  ignore(m.put("new", "new"))
  assert_eq(m.contains("keep"), true)
  assert_eq(m.contains("other"), false)
  assert_eq(m.contains("new"), true)
}

///|
/// The same store without the pin throws "keep" away.
///
/// The control: a test that says a pinned entry survives is only worth
/// anything if the store would otherwise have thrown it away.
test "the same store without the pin throws it away" {
  let m = pin_memory_with(2, 0L, @tesseract_memory.evict_lru())
  ignore(m.put("keep", "kept"))
  ignore(m.put("other", "dropped"))
  ignore(m.put("new", "new"))
  assert_eq(m.contains("keep"), false)
  assert_eq(m.contains("other"), true)
}

///|
/// A store of nothing but pinned entries refuses the write.
///
/// There is nothing to throw away, so there is no room to make, and the write
/// is refused rather than the pin broken.
test "a store of nothing but pinned entries refuses the write" {
  let m = pin_memory_with(1, 0L, @tesseract_memory.evict_lru())
  ignore(m.put_spec("only", "kept", pinned_spec()))
  let refused = m.put("second", "no room")
  assert_eq(refused, false)
  assert_eq(m.contains("only"), true)
  assert_eq(m.contains("second"), false)
  assert_eq(m.size(), 1)
}

///|
/// A refused write leaves the store as it was.
///
/// The store here is full enough that the write does not fit even after
/// everything that *could* be thrown away is thrown away: the pinned entry
/// and the new one are more than the budget allows.
///
/// A store that threw "a" away on its way to refusing the write would cost
/// the caller an entry it did not ask to lose — and the caller would never
/// hear about it, because the write was refused.
test "a refused write leaves the store as it was" {
  let m = pin_memory_with(100, 20L, @tesseract_memory.evict_lru())
  // Eight bytes, then twelve: twenty in all, which is the whole budget.
  ignore(m.put("a", "aaaaaaaa"))
  ignore(m.put_spec("b", "bbbbbbbbbbbb", pinned_spec()))
  let before_size = m.size()
  let before_bytes = m.size_bytes()
  // Twelve more would be thirty-two, and even throwing "a" away leaves
  // twenty-four.
  let refused = m.put("c", "cccccccccccc")
  assert_eq(refused, false)
  assert_eq(m.size(), before_size)
  assert_eq(m.size_bytes(), before_bytes)
  assert_eq(m.contains("a"), true)
  assert_eq(m.contains("b"), true)
  assert_eq(m.contains("c"), false)
}

///|
/// A pinned entry still expires when its time is up.
///
/// "Do not evict me" and "never die" are two different promises, and the pin
/// is the first one.
test "a pinned entry still expires when its time is up" {
  let m = pin_memory_at(0L)
  ignore(
    m.put_spec(
      "a",
      "x",
      @tesseract_memory.default_spec()
      .with_ttl(@tesseract_memory.ttl_absolute(1000L))
      .with_pinned(true),
    ),
  )
  assert_eq(m.contains("a"), true)
  ignore(m.advance(1000L))
  assert_eq(m.contains("a"), false)
}

///|
/// A pinned entry is still found by a search.
///
/// The pin is about the eviction and not about the retrieval.
test "a pinned entry is still found by a search" {
  let m = pin_memory_at(0L)
  ignore(m.put_spec("a", "the cat sat", pinned_spec()))
  let hits = m.search("cat", 5)
  assert_eq(hits.length(), 1)
  assert_eq(hits[0].key(), "a")
}

///|
/// A pinned entry still takes up the room.
///
/// The budget counts it, so a pinned entry that fills the budget leaves no
/// room for anything else — and the write that needs it is refused.
test "a pinned entry still takes up the room" {
  let m = pin_memory_with(100, 20L, @tesseract_memory.evict_lru())
  ignore(m.put_spec("a", "aaaaaaaaaaaa", pinned_spec()))
  let refused = m.put("b", "bbbbbbbbbbbb")
  assert_eq(refused, false)
  assert_eq(m.contains("a"), true)
  assert_eq(m.contains("b"), false)
}

///|
/// Pinning changes nothing else about the entry.
///
/// The pin is the only thing that changes: the age, the hit count, the
/// deadline, the importance and the labels are all left as they were, because
/// pinning something is not the same as reading it.
test "pinning changes nothing else about the entry" {
  let m = pin_memory_at(0L)
  ignore(
    m.put_spec(
      "a",
      "x",
      @tesseract_memory.default_spec()
      .with_importance(0.5)
      .with_metadata(@tesseract_memory.new_metadata([("kind", "note")])),
    ),
  )
  ignore(m.advance(500L))
  ignore(m.get("a"))
  let before = m.entry("a").unwrap()
  assert_eq(m.pin("a"), true)
  let after = m.entry("a").unwrap()
  assert_eq(after.added_at(), before.added_at())
  assert_eq(after.last_seen(), before.last_seen())
  assert_eq(after.hits(), before.hits())
  assert_eq(after.deadline(), before.deadline())
  assert_eq(after.importance(), before.importance())
  assert_eq(after.metadata().pairs().length(), 1)
  assert_eq(after.pinned(), true)
}

///|
/// Pinning a key that is not there does nothing.
test "pinning a key that is not there does nothing" {
  let m = pin_memory_at(0L)
  assert_eq(m.pin("nothing"), false)
  assert_eq(m.unpin("nothing"), false)
  assert_eq(m.size(), 0)
}

///|
/// Unpinning makes the entry evictable again.
test "unpinning makes the entry evictable again" {
  let m = pin_memory_with(2, 0L, @tesseract_memory.evict_lru())
  ignore(m.put_spec("keep", "kept", pinned_spec()))
  ignore(m.put("other", "dropped"))
  assert_eq(m.unpin("keep"), true)
  ignore(m.put("new", "new"))
  assert_eq(m.contains("keep"), false)
  assert_eq(m.contains("new"), true)
}

///|
/// The pin survives a touch.
///
/// A touch moves the deadline and the hit count. It does not unpin an entry.
test "the pin survives a touch" {
  let m = pin_memory_at(0L)
  ignore(m.put_spec("a", "x", pinned_spec()))
  assert_eq(m.touch("a"), true)
  assert_eq(m.entry("a").unwrap().pinned(), true)
}

///|
/// Writing the key again replaces the pin.
///
/// The entry is a new one — it was added now, and nobody has read the new
/// value yet — so it carries the pin it was written with this time.
test "writing the key again replaces the pin" {
  let m = pin_memory_at(0L)
  ignore(m.put_spec("a", "x", pinned_spec()))
  ignore(m.put("a", "y"))
  assert_eq(m.entry("a").unwrap().pinned(), false)
  ignore(m.put_spec("a", "z", pinned_spec()))
  assert_eq(m.entry("a").unwrap().pinned(), true)
}

///|
/// Every eviction policy respects the pin.
///
/// The pin is checked before the policy is asked, so it does not matter which
/// policy the store uses — and a test that says so has to try all four.
test "every eviction policy respects the pin" {
  let policies : Array[@tesseract_memory.EvictionPolicy] = [
    @tesseract_memory.evict_lru(),
    @tesseract_memory.evict_lfu(),
    @tesseract_memory.evict_soonest_expiry(),
    @tesseract_memory.evict_oldest(),
    @tesseract_memory.evict_largest(),
  ]
  for policy in policies {
    let m = pin_memory_with(2, 0L, policy)
    ignore(m.put_spec("keep", "kept", pinned_spec()))
    ignore(m.put("other", "dropped"))
    ignore(m.put("new", "new"))
    assert_eq(m.contains("keep"), true)
    assert_eq(m.contains("other"), false)
  }
}

///|
/// The pin is reported with the entry.
test "the pin is reported with the entry" {
  let m = pin_memory_at(0L)
  ignore(m.put_spec("a", "x", pinned_spec()))
  ignore(m.put("b", "y"))
  assert_eq(
    @tesseract.contains_ci(m.entry("a").unwrap().describe(0L), "pinned"),
    true,
  )
  assert_eq(
    @tesseract.contains_ci(m.entry("b").unwrap().describe(0L), "pinned"),
    false,
  )
}

///|
/// A scope's pin keeps the entry out of the store's eviction.
///
/// The pin belongs to the entry and the eviction is the store's, so a pinned
/// entry in one scope is safe from a write in another.
test "a scope's pin keeps the entry out of the store's eviction" {
  let m = pin_memory_with(2, 0L, @tesseract_memory.evict_lru())
  ignore(m.scope("work").put_spec("keep", "kept", pinned_spec()))
  ignore(m.scope("work").put("other", "dropped"))
  ignore(m.scope("home").put("new", "new"))
  assert_eq(m.scope("work").contains("keep"), true)
  assert_eq(m.scope("work").contains("other"), false)
  assert_eq(m.scope("home").contains("new"), true)
}

///|
/// The scope's own pin and unpin address that scope.
test "the scope's own pin and unpin address that scope" {
  let m = pin_memory_at(0L)
  ignore(m.put("a", "x"))
  assert_eq(m.scope("work").pin("a"), false)
  assert_eq(m.pin("a"), true)
  assert_eq(m.entry("a").unwrap().pinned(), true)
  assert_eq(m.unpin("a"), true)
  assert_eq(m.entry("a").unwrap().pinned(), false)
}

///|
/// The keys of a store are still in order, pinned or not.
test "the keys of a store are still in order, pinned or not" {
  let m = pin_memory_with(10, 0L, @tesseract_memory.evict_lru())
  ignore(m.put("work", "w"))
  ignore(m.put_spec("apple", "a", pinned_spec()))
  ignore(m.put("default", "d"))
  assert_eq(pin_keys(m), "apple,default,work")
}
