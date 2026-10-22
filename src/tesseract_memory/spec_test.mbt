///|
/// The spec of an entry: how long it lives, and how much it counts.
///
/// The importance is a weight in the search score, so these tests are about
/// the *ranking*: a less important entry is found less strongly, and it can
/// lose to a better match. They are also about the three things the store
/// refuses to accept, because a refusal that changes the store is a refusal
/// that is worse than no refusal at all.
///
/// The clock is manual in every test, so each of these is a number rather
/// than a race.

///|
/// A memory on a clock the test moves by hand.
fn spec_memory_at(start_ms : Int64) -> @tesseract_memory.Memory {
  @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_capacity(10),
    @tesseract_memory.memory_clock_manual(start_ms),
  )
}

///|
/// A score, to three decimals, so a float comparison is exact.
fn spec_score_of(s : Double) -> String {
  let scaled = (s * 1000.0).round().to_int64()
  (scaled / 1000L).to_string() + "." + @tesseract.pad_number(scaled % 1000L, 3)
}

///|
/// The keys a search returned, in order.
fn spec_hit_keys(m : @tesseract_memory.Memory, query : String) -> String {
  m.search_keys(query, 10).join(",")
}

///|
/// The default importance is one, and an entry counts fully by default.
///
/// The default has to be the **most** an entry can count, so a caller
/// demotes the entries that matter less instead of trying to raise the ones
/// that matter more.
test "the default importance is one, and an entry counts fully by default" {
  let m = spec_memory_at(0L)
  ignore(m.put("a", "cat"))
  assert_eq(m.entry("a").unwrap().importance, 1.0)
  let hits = m.search("cat", 5)
  assert_eq(hits.length(), 1)
  assert_eq(spec_score_of(hits[0].score), "1.000")
  assert_eq(hits[0].importance, 1.0)
}

///|
/// An importance of half is found half as strongly.
///
/// The score is a product of three weights, and the importance is one of
/// them, so half the importance is half the score — for the same query and at
/// the same age.
test "an importance of half is found half as strongly" {
  let m = spec_memory_at(0L)
  ignore(m.put("a", "cat"))
  ignore(
    m.put_spec(
      "b",
      "cat",
      @tesseract_memory.default_spec().with_importance(0.5),
    ),
  )
  let hits = m.search("cat", 10)
  assert_eq(hits.length(), 2)
  // The one that counts fully is found first.
  assert_eq(hits[0].key, "a")
  assert_eq(spec_score_of(hits[0].score), "1.000")
  assert_eq(hits[1].key, "b")
  assert_eq(spec_score_of(hits[1].score), "0.500")
  assert_eq(hits[1].importance, 0.5)
}

///|
/// An importance can turn a better match into a worse one.
///
/// The point of the weight: a shorter value is the better match, and without
/// the importance it would win. The importance is what turns the order over,
/// and it does so by the score rather than by a rule of its own.
test "an importance can turn a better match into a worse one" {
  let m = spec_memory_at(0L)
  ignore(m.put("a", "the cat sat on the mat"))
  ignore(
    m.put_spec(
      "b",
      "the cat",
      @tesseract_memory.default_spec().with_importance(0.2),
    ),
  )
  // Without the importance "b" would win: it shares the whole of the
  // query's vocabulary against a fifth of it.
  assert_eq(spec_hit_keys(m, "cat"), "a,b")
  let hits = m.search("cat", 10)
  assert_eq(spec_score_of(hits[0].score), "0.200")
  assert_eq(spec_score_of(hits[1].score), "0.100")
}

///|
/// An importance outside the range is refused, and the store is unchanged.
///
/// The range has no zero in it and nothing above one: at zero the entry
/// could never be found, and above one the score would leave the `0.0..1.0`
/// it is documented to be in.
test "an importance outside the range is refused, and the store is unchanged" {
  let m = spec_memory_at(0L)
  ignore(m.put("a", "cat"))
  assert_false(
    m.put_spec(
      "b",
      "cat",
      @tesseract_memory.default_spec().with_importance(0.0),
    ),
  )
  assert_false(
    m.put_spec(
      "c",
      "cat",
      @tesseract_memory.default_spec().with_importance(1.5),
    ),
  )
  assert_false(
    m.put_spec(
      "d",
      "cat",
      @tesseract_memory.default_spec().with_importance(-0.5),
    ),
  )
  // The store is exactly as it was, and the refused writes are not counted.
  assert_eq(m.size(), 1)
  assert_eq(m.keys().join(","), "a")
  assert_eq(m.stats().puts, 1L)
}

///|
/// A lifetime in the past is refused, and the store is unchanged.
///
/// An entry written with one is dead the moment it is written, so accepting
/// the write would be accepting a write that does nothing — and the caller
/// would be told the value was stored.
test "a lifetime in the past is refused, and the store is unchanged" {
  let m = spec_memory_at(0L)
  ignore(m.put("a", "cat"))
  assert_false(
    m.put_with_ttl("b", "cat", @tesseract_memory.ttl_absolute(-1000L)),
  )
  assert_false(m.put_with_ttl("c", "cat", @tesseract_memory.ttl_sliding(-1L)))
  assert_eq(m.size(), 1)
  assert_eq(m.keys().join(","), "a")
  assert_eq(m.get("b"), None)
  assert_eq(m.stats().puts, 1L)
}

///|
/// A lifetime of zero is refused, and so is one in the past.
///
/// An entry whose deadline is the moment it was written is dead on arrival,
/// and a deadline of zero is also the deadline the store gives an entry that
/// never expires — so a store that told those two apart by the deadline would
/// give the zero-lifetime entry the other one's meaning, and it would live
/// forever. The shortest lifetime there is is one millisecond, and
/// `ttl_never` is how a caller says "no deadline".
test "a lifetime of zero is refused, and so is one in the past" {
  let m = spec_memory_at(0L)
  assert_false(m.put_with_ttl("a", "cat", @tesseract_memory.ttl_absolute(0L)))
  assert_false(m.put_with_ttl("b", "cat", @tesseract_memory.ttl_sliding(0L)))
  // The shortest lifetime there is is one millisecond, and it is taken.
  assert_true(m.put_with_ttl("c", "cat", @tesseract_memory.ttl_absolute(1L)))
  assert_eq(m.get("c"), Some("cat"))
  assert_eq(m.size(), 1)
}

///|
/// Whether an entry expires is decided by its window, not by its deadline.
///
/// A deadline of zero is also the deadline the store gives an entry that never
/// expires, so a store that told those two apart by the deadline would give a
/// zero-lifetime entry the other one's meaning. The window is what tells
/// them apart, and the case where it shows is a clock before the epoch: there
/// the deadline of a one-millisecond entry is zero, and the entry is an
/// ordinary one.
test "whether an entry expires is decided by its window, not by its deadline" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_capacity(10),
    @tesseract_memory.memory_clock_manual(-1L),
  )
  ignore(m.put_with_ttl("a", "cat", @tesseract_memory.ttl_absolute(1L)))
  // At t=-1 the entry is live: its deadline is 0 and it is not yet 0.
  assert_eq(m.get("a"), Some("cat"))
  // And at t=0 it is gone, because its deadline is 0 and now is 0.
  ignore(m.advance(1L))
  assert_eq(m.get("a"), None)
}

///|
/// A lifetime too long to add does not come back as a deadline in the past.
///
/// The sum of two instants that does not fit in an `Int64` would wrap round
/// into the past, and a deadline in the past is an entry that is dead on
/// arrival. So the deadline saturates: the entry lives as long as the store
/// can express.
test "a lifetime too long to add does not come back as a deadline in the past" {
  let m = spec_memory_at(0L)
  let forever = 9223372036854775807L
  assert_true(
    m.put_with_ttl("a", "cat", @tesseract_memory.ttl_absolute(forever)),
  )
  assert_eq(m.get("a"), Some("cat"))
  // And a sliding entry refreshed past the end keeps its deadline.
  let s = spec_memory_at(0L)
  ignore(s.put_with_ttl("b", "cat", @tesseract_memory.ttl_sliding(forever)))
  ignore(s.advance(1L))
  assert_eq(s.get("b"), Some("cat"))
}

///|
/// The importance survives a read.
///
/// A read replaces the entry with a touched copy of it, and a copy that
/// dropped the importance would quietly reset it to the default.
test "the importance survives a read" {
  let m = spec_memory_at(0L)
  ignore(
    m.put_spec(
      "a",
      "cat",
      @tesseract_memory.default_spec().with_importance(0.3),
    ),
  )
  ignore(m.get("a"))
  assert_eq(m.entry("a").unwrap().importance, 0.3)
  ignore(m.touch("a"))
  assert_eq(m.entry("a").unwrap().importance, 0.3)
}

///|
/// A spec says whether it is one the store can honour.
test "a spec says whether it is one the store can honour" {
  assert_true(@tesseract_memory.default_spec().is_valid())
  assert_true(@tesseract_memory.default_spec().with_importance(1.0).is_valid())
  assert_true(@tesseract_memory.default_spec().with_importance(0.5).is_valid())
  assert_false(@tesseract_memory.default_spec().with_importance(0.0).is_valid())
  assert_false(@tesseract_memory.default_spec().with_importance(1.5).is_valid())
  assert_false(
    @tesseract_memory.default_spec()
    .with_ttl(@tesseract_memory.ttl_absolute(-1L))
    .is_valid(),
  )
  assert_false(
    @tesseract_memory.default_spec()
    .with_ttl(@tesseract_memory.ttl_absolute(0L))
    .is_valid(),
  )
  assert_true(
    @tesseract_memory.default_spec()
    .with_ttl(@tesseract_memory.ttl_absolute(1L))
    .is_valid(),
  )
  assert_true(
    @tesseract_memory.default_spec()
    .with_ttl(@tesseract_memory.ttl_never())
    .is_valid(),
  )
}

///|
/// A scope's entries carry their importance too.
///
/// The scope is a partition of the keyspace and not a second store, so an
/// entry in one scope counts exactly as much as the same entry in another.
test "a scope's entries carry their importance too" {
  let m = spec_memory_at(0L)
  let work = m.scope("work")
  ignore(
    work.put_spec(
      "a",
      "cat",
      @tesseract_memory.default_spec().with_importance(0.25),
    ),
  )
  assert_eq(work.entry("a").unwrap().importance, 0.25)
  let hits = work.search("cat", 5)
  assert_eq(hits.length(), 1)
  assert_eq(spec_score_of(hits[0].score), "0.250")
  assert_eq(hits[0].importance, 0.25)
  // And a spec the store cannot honour is refused in a scope as well.
  assert_false(
    work.put_spec(
      "b",
      "cat",
      @tesseract_memory.default_spec().with_importance(0.0),
    ),
  )
  assert_eq(work.size(), 1)
}
