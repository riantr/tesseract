///|
/// The short-term memory: TTL, capacity eviction, and similarity retrieval.
///
/// Every test here names the behaviour it is protecting rather than only the
/// answer it expects, because the answers in this package are the ones that
/// are easy to get subtly wrong: a boundary that is off by one millisecond, an
/// eviction that picks the wrong entry, a similarity that is symmetric when it
/// was asked not to be.
///
/// The clock is **manual** in every test, so each of these is a number rather
/// than a race. A test that reads the host clock cannot assert that something
/// has not happened yet.

///|
/// A memory on a clock the test moves by hand.
fn memory_at(start_ms : Int64) -> @tesseract_memory.Memory {
  @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_capacity(10),
    @tesseract_memory.memory_clock_manual(start_ms),
  )
}

///|
/// The keys of a memory, in order.
fn keys_of(m : @tesseract_memory.Memory) -> String {
  m.keys().join(",")
}

///|
/// The keys a search returned, in order.
fn hit_keys(m : @tesseract_memory.Memory, query : String, k : Int32) -> String {
  m.search_keys(query, k).join(",")
}

///|
/// A score, to three decimals, so a float comparison is exact.
fn score_of(s : Double) -> String {
  let scaled = (s * 1000.0).round().to_int64()
  (scaled / 1000L).to_string() + "." + @tesseract.pad_number(scaled % 1000L, 3)
}

///|
/// An entry lives for exactly its TTL, and not a millisecond more.
///
/// The boundary is the whole contract: a TTL of 1000ms written at t=0 is live
/// at t=999 and gone at t=1000. A store that expired at t=1001 would be
/// promising a thousand and one milliseconds of life.
test "an entry lives for exactly its TTL, and not a millisecond more" {
  let m = memory_at(0L)
  ignore(m.put_with_ttl("a", "x", @tesseract_memory.ttl_absolute(1000L)))
  ignore(m.advance(999L))
  assert_eq(m.get("a"), Some("x"))
  assert_eq(m.size(), 1)
  ignore(m.advance(1L))
  assert_eq(m.get("a"), None)
  assert_eq(m.size(), 0)
}

///|
/// An expired entry is gone from every view of the store.
///
/// Not just from `get`: a key that has expired must not turn up in `keys`, in
/// `entries`, in `contains`, or in a search, and it must not count towards the
/// capacity. An entry that is gone from one view and present in another is a
/// store that answers two different questions.
test "an expired entry is gone from every view of the store" {
  let m = memory_at(0L)
  ignore(m.put_with_ttl("a", "x", @tesseract_memory.ttl_absolute(1000L)))
  ignore(m.put_with_ttl("b", "y", @tesseract_memory.ttl_absolute(5000L)))
  ignore(m.advance(1000L))
  assert_eq(m.get("a"), None)
  assert_false(m.contains("a"))
  assert_eq(keys_of(m), "b")
  assert_eq(m.entries().length(), 1)
  assert_eq(hit_keys(m, "x", 10), "")
  // And it does not count towards the capacity.
  assert_eq(m.size(), 1)
}

///|
/// A sliding entry's deadline moves when it is read; an absolute one's does not.
///
/// This is the difference between a cache and a memory. Both are written at
/// t=0 with a 1000ms lifetime; one is read at t=500 and the other is not, and
/// at t=1000 only the one that was read is still there.
test "a sliding entry's deadline moves when it is read; an absolute one's does not" {
  let m = memory_at(0L)
  ignore(m.put_with_ttl("sliding", "x", @tesseract_memory.ttl_sliding(1000L)))
  ignore(m.put_with_ttl("fixed", "y", @tesseract_memory.ttl_absolute(1000L)))
  ignore(m.advance(500L))
  assert_eq(m.get("sliding"), Some("x"))
  ignore(m.advance(500L))
  // t=1000: the absolute entry's deadline has passed and the sliding one's
  // was pushed to 1500 when it was read at t=500.
  assert_eq(m.get("fixed"), None)
  assert_eq(m.get("sliding"), Some("x"))
}

///|
/// An entry that never expires outlives one that does.
test "an entry that never expires outlives one that does" {
  let m = memory_at(0L)
  ignore(m.put_with_ttl("forever", "x", @tesseract_memory.ttl_never()))
  ignore(m.put_with_ttl("brief", "y", @tesseract_memory.ttl_absolute(1000L)))
  ignore(m.advance(100000L))
  assert_eq(m.get("forever"), Some("x"))
  assert_eq(m.get("brief"), None)
}

///|
/// The store records what it dropped, and why.
test "the store records what it dropped, and why" {
  let m = memory_at(0L)
  ignore(m.put_with_ttl("a", "x", @tesseract_memory.ttl_absolute(1000L)))
  ignore(m.advance(1000L))
  ignore(m.sweep())
  let s = m.stats()
  assert_eq(s.expirations, 1L)
  assert_eq(s.puts, 1L)
  // And an entry that is merely forgotten is not counted as an expiry.
  ignore(m.put("b", "y"))
  ignore(m.delete("b"))
  assert_eq(m.stats().expirations, 1L)
  assert_eq(m.stats().deletes, 1L)
}

///|
/// The store holds at most its capacity, and the overflow is evicted.
test "the store holds at most its capacity, and the overflow is evicted" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_capacity(2),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "1"))
  ignore(m.put("b", "2"))
  assert_eq(m.size(), 2)
  ignore(m.put("c", "3"))
  assert_eq(m.size(), 2)
  // The oldest went, by the default policy.
  assert_eq(keys_of(m), "b,c")
  assert_eq(m.stats().evictions, 1L)
}

///|
/// Overwriting a key evicts nothing.
///
/// A `put` of a key that is already there replaces the value in place. If
/// overwriting cost another key its place, then writing to a full store would
/// throw away a memory the caller had not asked to lose.
test "overwriting a key evicts nothing" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_capacity(2),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "1"))
  ignore(m.put("b", "2"))
  ignore(m.put("a", "3"))
  assert_eq(m.size(), 2)
  assert_eq(keys_of(m), "a,b")
  assert_eq(m.get("a"), Some("3"))
  assert_eq(m.stats().evictions, 0L)
  assert_eq(m.stats().updates, 1L)
}

///|
/// LRU evicts the entry nobody has touched for longest.
test "LRU evicts the entry nobody has touched for longest" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config()
    .with_capacity(2)
    .with_eviction(@tesseract_memory.evict_lru()),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "1"))
  ignore(m.advance(100L))
  ignore(m.put("b", "2"))
  ignore(m.advance(100L))
  // Reading `a` makes `b` the least recently used. The clock has to move for
  // that to mean anything: two entries written at the same instant are tied,
  // and a tie is broken by the key.
  assert_eq(m.get("a"), Some("1"))
  ignore(m.put("c", "3"))
  assert_eq(keys_of(m), "a,c")
}

///|
/// LFU evicts the entry nobody has read.
test "LFU evicts the entry nobody has read" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config()
    .with_capacity(2)
    .with_eviction(@tesseract_memory.evict_lfu()),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "1"))
  ignore(m.put("b", "2"))
  assert_eq(m.get("a"), Some("1"))
  assert_eq(m.get("a"), Some("1"))
  assert_eq(m.get("b"), Some("2"))
  ignore(m.put("c", "3"))
  assert_eq(keys_of(m), "a,c")
}

///|
/// The soonest-to-expire entry goes first, and an entry that never expires goes last.
///
/// "Never" is infinitely far from expiring, so it is the last thing the
/// `SoonestExpiry` policy takes — otherwise the policy would throw away the
/// one entry that cannot be replaced.
test "the soonest-to-expire entry goes first, and one that never expires goes last" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config()
    .with_capacity(2)
    .with_eviction(@tesseract_memory.evict_soonest_expiry()),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put_with_ttl("soon", "1", @tesseract_memory.ttl_absolute(1000L)))
  ignore(m.put_with_ttl("later", "2", @tesseract_memory.ttl_absolute(9000L)))
  ignore(m.put_with_ttl("never", "3", @tesseract_memory.ttl_never()))
  // `soon` expires first, so it is the one that goes.
  assert_eq(keys_of(m), "later,never")
}

///|
/// The oldest entry goes, whatever else is true of it.
test "the oldest entry goes, whatever else is true of it" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config()
    .with_capacity(2)
    .with_eviction(@tesseract_memory.evict_oldest()),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "1"))
  ignore(m.advance(100L))
  ignore(m.put("b", "2"))
  ignore(m.advance(100L))
  // `a` is read, so it is the most recently used — but it is still the oldest.
  assert_eq(m.get("a"), Some("1"))
  ignore(m.put("c", "3"))
  assert_eq(keys_of(m), "b,c")
}

///|
/// A tie is broken by key, so the same program always evicts the same entry.
///
/// A store that evicts differently on two runs of the same program is a store
/// nobody can test. The rule has to be *some* rule, and the key is the one
/// that does not depend on the order the entries happened to be written in.
test "a tie is broken by key, so the same program always evicts the same entry" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config()
    .with_capacity(2)
    .with_eviction(@tesseract_memory.evict_oldest()),
    @tesseract_memory.memory_clock_manual(0L),
  )
  // Written in one order, so that "oldest" is a tie between them.
  ignore(m.put("bbb", "1"))
  ignore(m.put("aaa", "2"))
  ignore(m.put("ccc", "3"))
  assert_eq(keys_of(m), "bbb,ccc")
}

///|
/// Words are compared by their share of the combined vocabulary.
///
/// "the cat sat" and "the cat ran" share two words out of four, so the score
/// is one half. The arithmetic is written out because a similarity that is
/// "roughly half" is not a number anybody can check.
test "words are compared by their share of the combined vocabulary" {
  // "the cat sat" and "the cat ran" share {the, cat} out of {the, cat, sat,
  // ran}: 2 of 4.
  assert_eq(
    score_of(@tesseract_memory.jaccard("the cat sat", "the cat ran")),
    "0.500",
  )
  assert_eq(score_of(@tesseract_memory.jaccard("the cat", "the cat")), "1.000")
  assert_eq(score_of(@tesseract_memory.jaccard("the cat", "a dog")), "0.000")
  // Two empty texts are not alike: they are the absence of anything to
  // compare, and calling that 1.0 would make a blank entry match perfectly.
  assert_eq(score_of(@tesseract_memory.jaccard("", "")), "0.000")
}

///|
/// A repeated word counts once for Jaccard and three times for cosine.
///
/// That is the difference between "do these two texts share words" and "do
/// these two documents look alike", and the two answer differently for a text
/// that repeats itself.
test "a repeated word counts once for Jaccard and three times for cosine" {
  let repeated = "cat cat cat"
  let once = "cat"
  // The vocabulary of both is {cat}, so they share all of it.
  assert_eq(score_of(@tesseract_memory.jaccard(repeated, once)), "1.000")
  // Cosine of (3) and (1): 3 / (3 * 1) = 1.
  assert_eq(score_of(@tesseract_memory.cosine(repeated, once)), "1.000")
  let mixed = "cat cat dog"
  // The vocabulary is {cat, dog} against {cat}: 1 of 2.
  assert_eq(score_of(@tesseract_memory.jaccard(mixed, once)), "0.500")
  // Cosine of (2,1) and (1,0): 2 / (sqrt(5) * 1) = 0.894.
  assert_eq(score_of(@tesseract_memory.cosine(mixed, once)), "0.894")
}

///|
/// Containment asks how much of the *query* the entry covers.
///
/// This is the asymmetry that makes a search work. A two-word query against a
/// long document that contains both words scores 1.0, even though the two
/// share only a little of their combined vocabulary — which is the right
/// answer, and the one a symmetric measure cannot give.
test "containment asks how much of the query the entry covers" {
  let query = "red apple"
  let long = "the red apple sat on the table next to a green one"
  // The query's two words are both in the long text, so it is fully covered.
  assert_eq(score_of(@tesseract_memory.containment(query, long)), "1.000")
  assert_eq(
    score_of(@tesseract_memory.containment(query, "red apple pie")),
    "1.000",
  )
  // One of the two: half the query.
  assert_eq(score_of(@tesseract_memory.containment(query, "red pear")), "0.500")
  assert_eq(score_of(@tesseract_memory.containment(query, "banana")), "0.000")
  // The other direction is not the same number, and must not be: the long text
  // has eleven distinct words and the query covers two of them.
  assert_eq(score_of(@tesseract_memory.containment(long, query)), "0.182")
}

///|
/// Two JSON documents with the same shape are alike, whatever their values.
test "two JSON documents with the same shape are alike, whatever their values" {
  let a = "{\"name\":\"ada\",\"age\":36}"
  let b = "{\"name\":\"alan\",\"age\":41}"
  let c = "{\"name\":\"ada\",\"city\":\"london\"}"
  assert_eq(score_of(@tesseract_memory.structure_similarity(a, b)), "1.000")
  // One path in common out of three: $.name, $.age, $.city.
  assert_eq(score_of(@tesseract_memory.structure_similarity(a, c)), "0.333")
  // And a text that is not a document has no shape at all.
  assert_eq(
    score_of(@tesseract_memory.structure_similarity(a, "not json")),
    "0.000",
  )
  assert_eq(
    score_of(
      @tesseract_memory.structure_similarity("not json", "also not json"),
    ),
    "0.000",
  )
}

///|
/// The shape of a document is the set of its leaf paths.
test "the shape of a document is the set of its leaf paths" {
  let paths = @tesseract_memory.structure_paths(
    "{\"a\":{\"b\":1},\"c\":[10,20]}",
  )
  let sorted = paths
  sorted.sort_by(fn(x, y) { String::compare(x, y) })
  assert_eq(sorted.join(","), "$.a.b,$.c[0],$.c[1]")
}

///|
/// A word outside ASCII is a word of its own.
///
/// Chinese has no spaces, so an ASCII-only tokenizer would reduce a whole
/// sentence to nothing and every Chinese document would score zero against
/// every other one. Splitting by character is crude next to a real
/// segmenter, and it is the difference between a useful score and no score.
test "a word outside ASCII is a word of its own" {
  let tokens = @tesseract_memory.tokenize("苹果手机")
  assert_eq(tokens.join(","), "苹,果,手,机")
  let a = @tesseract_memory.tokenize("我喜欢苹果手机")
  let b = @tesseract_memory.tokenize("他买了苹果电脑")
  let mut shared = 0
  for t in a {
    if b.contains(t) {
      shared = shared + 1
    }
  }
  // 苹, 果, 手 and 机 on one side; 苹, 果, 电, 脑 on the other.
  assert_eq(shared, 2)
}

///|
/// A character outside the basic plane is one word, not two.
///
/// An emoji is one character and four UTF-8 bytes, but it is two code units in
/// the runtime's string. The tokenizer steps over the string a code unit at a
/// time, so it has to put the pair back together — otherwise one character
/// becomes two words, and two *different* emoji that share a half would be
/// treated as alike.
test "a character outside the basic plane is one word, not two" {
  let tokens = @tesseract_memory.tokenize("🍎")
  assert_eq(tokens.length(), 1)
  assert_eq(tokens[0], "🍎")
  // And it does not split a run of ASCII around itself.
  let mixed = @tesseract_memory.tokenize("a🍎b")
  assert_eq(mixed.join(","), "a,🍎,b")
  // Two identical texts are alike, which they were not when the character was
  // dropped on the way in: the two of them tokenized to nothing at all.
  assert_eq(score_of(@tesseract_memory.jaccard("🍎", "🍎")), "1.000")
  // Two different emoji share a high surrogate and must not be alike.
  assert_eq(score_of(@tesseract_memory.jaccard("🍎", "🍏")), "0.000")
}

///|
/// The search returns the best matches, best first, and only the ones that match.
test "the search returns the best matches, best first, and only the ones that match" {
  let m = memory_at(0L)
  // The shorter value is the better match: it shares the whole of the query's
  // vocabulary, while the longer one has the query's words in a sea of others.
  ignore(m.put("short", "the cat"))
  ignore(m.put("long", "the cat sat on the mat"))
  ignore(m.put("other", "a dog barked"))
  assert_eq(hit_keys(m, "the cat", 10), "short,long")
  // A query that matches nothing returns nothing, rather than padding the
  // answer with entries that have nothing to do with it.
  assert_eq(hit_keys(m, "zebra", 10), "")
  // And `k` is a limit, not a suggestion.
  assert_eq(hit_keys(m, "the cat", 1), "short")
  assert_eq(hit_keys(m, "the cat", 0), "")
}

///|
/// The search is stable: the same store answers the same way every time.
test "the search is stable: the same store answers the same way every time" {
  let m = memory_at(0L)
  ignore(m.put("b", "cat"))
  ignore(m.put("a", "cat"))
  ignore(m.put("c", "cat"))
  // All three score the same, so the order is decided by the key and not by
  // the order the entries happened to be written in.
  assert_eq(hit_keys(m, "cat", 3), "a,b,c")
  assert_eq(hit_keys(m, "cat", 3), "a,b,c")
}

///|
/// A recency weight can make an older match lose to a newer one.
///
/// Two entries match equally well, and the one written earlier is worth less
/// once the store is configured to halve the weight every half-life. This is
/// the rule that makes a short-term memory prefer what just happened.
test "a recency weight can make an older match lose to a newer one" {
  // The older entry is the better match; the newer one only half matches.
  let plain = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_capacity(10),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(plain.put("old", "cat dog"))
  ignore(plain.advance(2000L))
  ignore(plain.put("new", "cat"))
  // Without a recency weight the better match wins.
  assert_eq(hit_keys(plain, "cat dog", 2), "old,new")

  // With a half-life of a second, the older entry has lost three quarters of
  // its weight: 1.0 * 0.25 = 0.25 against the newer one's 0.5 * 1.0 = 0.5.
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config()
    .with_capacity(10)
    .with_recency(@tesseract_memory.recency_decay(1000L)),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("old", "cat dog"))
  ignore(m.advance(2000L))
  ignore(m.put("new", "cat"))
  // The order has turned over.
  assert_eq(hit_keys(m, "cat dog", 2), "new,old")
  let hits = m.search("cat dog", 2)
  assert_eq(hits.length(), 2)
  assert_eq(hits[0].key, "new")
  assert_eq(score_of(hits[0].score), "0.500")
  assert_eq(score_of(hits[1].score), "0.250")
}

///|
/// A search does not count as a use.
///
/// Reading is what makes an entry recently used; a search that touched every
/// candidate would make the whole store look freshly read and LRU would stop
/// meaning anything.
test "a search does not count as a use" {
  let m = memory_at(0L)
  ignore(m.put("a", "cat"))
  let before = m.entry("a").unwrap()
  ignore(m.search("cat", 10))
  let after = m.entry("a").unwrap()
  // The entry was not touched: not read, not counted, and not refreshed. A
  // test that only looked at the counters would pass even if the search
  // refreshed every entry, because a search does not count as a *get* either
  // way.
  assert_eq(after.last_seen, before.last_seen)
  assert_eq(after.hits, before.hits)
  assert_eq(m.stats().gets, 0L)
  assert_eq(m.get("a"), Some("cat"))
  assert_eq(m.stats().gets, 1L)
}

///|
/// A memory built with an impossible configuration is given a workable one.
///
/// A capacity of zero or less is a memory that cannot hold anything, and a
/// negative budget is a mistake that would otherwise read as the one value
/// that means no limit at all. A **new** memory has no entries to protect, so
/// the setting it cannot use is replaced; a running one refuses instead.
test "a memory built with an impossible configuration is given a workable one" {
  let impossible = @tesseract_memory.default_config()
    .with_capacity(0)
    .with_max_bytes(-1L)
  assert_false(impossible.is_valid())
  let m = @tesseract_memory.new_memory_with(impossible)
  assert_true(m.capacity() > 0)
  assert_eq(m.max_bytes(), 0L)
  // And the memory works.
  assert_true(m.put("a", "1"))
  assert_eq(m.size(), 1)
}

///|
/// The byte total counts the UTF-8 bytes of a multibyte value.
///
/// A byte budget is only worth having if the bytes it counts are the bytes the
/// text takes up: a value of two Chinese characters is six bytes, not two.
test "the byte total counts the UTF-8 bytes of a multibyte value" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_max_bytes(1000L),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "苹果"))
  assert_eq(m.size_bytes(), 6L)
  ignore(m.put("b", "🍎"))
  assert_eq(m.size_bytes(), 10L)
  // And the total is the sum over the live entries, which is what the store
  // says it is: a total that drifts is a total nobody can trust. The entries
  // themselves are not reachable from outside the package — the map is
  // private — so the total can only drift if this package drifts it.
  ignore(m.delete("a"))
  assert_eq(m.size_bytes(), 4L)
  ignore(m.put("a", "苹果"))
  assert_eq(m.size_bytes(), 10L)
}

///|
/// A search score is never above one.
///
/// The recency weight is a fraction, and a score is a weight times a
/// similarity, so a score cannot leave `0.0..1.0`. A clock that ran backwards
/// would make an entry older than the moment it was written, and the weight
/// larger than one — which is why a backwards clock is refused.
test "a search score is never above one" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config()
    .with_capacity(10)
    .with_recency(@tesseract_memory.recency_decay(1000L)),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "cat"))
  // The clock does not run backwards.
  assert_false(m.advance(-1000L))
  assert_eq(m.now(), 0L)
  let hits = m.search("cat", 5)
  assert_eq(hits.length(), 1)
  assert_true(hits[0].score <= 1.0)
  assert_eq(score_of(hits[0].score), "1.000")
}

///|
/// Reading the clock purges what has expired.
///
/// Expiry is eager, and reading the clock is reading the store, so the
/// entries that are already gone are gone when the clock is read. The counter
/// is what makes that visible: a store that had not purged would still be
/// holding the entry.
test "reading the clock purges what has expired" {
  let m = memory_at(0L)
  ignore(m.put_with_ttl("a", "x", @tesseract_memory.ttl_absolute(1000L)))
  assert_eq(m.stats().expirations, 0L)
  ignore(m.advance(1000L))
  ignore(m.now())
  assert_eq(m.stats().expirations, 1L)
}

///|
/// Touching refreshes an entry without reading it.
test "touching refreshes an entry without reading it" {
  let m = memory_at(0L)
  ignore(m.put_with_ttl("a", "x", @tesseract_memory.ttl_sliding(1000L)))
  ignore(m.advance(500L))
  assert_true(m.touch("a"))
  assert_false(m.touch("nope"))
  ignore(m.advance(500L))
  assert_eq(m.get("a"), Some("x"))
}

///|
/// The store counts what it was asked for and what it had.
test "the store counts what it was asked for and what it had" {
  let m = memory_at(0L)
  ignore(m.put("a", "1"))
  assert_eq(m.get("a"), Some("1"))
  assert_eq(m.get("b"), None)
  let s = m.stats()
  assert_eq(s.puts, 1L)
  assert_eq(s.gets, 2L)
  assert_eq(s.hits, 1L)
  assert_eq(s.misses, 1L)
}

///|
/// A memory of no capacity is refused rather than silently becoming one.
test "a memory of no capacity is refused rather than silently becoming one" {
  let m = memory_at(0L)
  assert_false(
    m.set_config(@tesseract_memory.default_config().with_capacity(0)),
  )
  // The old configuration is still in force.
  assert_eq(m.capacity(), 10)
  assert_false(
    m.set_config(@tesseract_memory.default_config().with_capacity(-1)),
  )
  assert_eq(m.capacity(), 10)
}

///|
/// The capacity is reported, and the store never exceeds it.
test "the capacity is reported, and the store never exceeds it" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_capacity(3),
    @tesseract_memory.memory_clock_manual(0L),
  )
  assert_eq(m.capacity(), 3)
  ignore(m.put("a", "1"))
  ignore(m.put("b", "2"))
  ignore(m.put("c", "3"))
  assert_eq(m.size(), 3)
  ignore(m.put("d", "4"))
  assert_eq(m.size(), 3)
  assert_eq(m.capacity(), 3)
}

///|
/// A text is measured in UTF-8 bytes, not in code units.
///
/// `String::length` counts code units: `苹果` is 2 and `🍎` is 2, while in
/// UTF-8 they are 6 and 4. A budget measured in code units would shrink when
/// the content turned Chinese, which is not a number anybody can reason about.
test "a text is measured in UTF-8 bytes, not in code units" {
  assert_eq(@tesseract_memory.utf8_bytes(""), 0L)
  assert_eq(@tesseract_memory.utf8_bytes("abc"), 3L)
  assert_eq(@tesseract_memory.utf8_bytes("café"), 5L)
  assert_eq(@tesseract_memory.utf8_bytes("苹果"), 6L)
  assert_eq(@tesseract_memory.utf8_bytes("🍎"), 4L)
}

///|
/// A byte budget evicts until the store fits.
///
/// The capacity limit counts entries and the byte limit counts content, and
/// they are different limits: a store of a hundred one-byte entries and a
/// store of ten hundred-byte entries are the same shape to the first and not
/// to the second.
test "a byte budget evicts until the store fits" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_max_bytes(10L),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "12345"))
  assert_eq(m.size_bytes(), 5L)
  ignore(m.put("b", "12345"))
  assert_eq(m.size_bytes(), 10L)
  // The next one does not fit, so the least recently used goes.
  ignore(m.put("c", "12345"))
  assert_eq(m.size_bytes(), 10L)
  assert_eq(m.size(), 2)
  assert_eq(keys_of(m), "b,c")
  assert_eq(m.stats().evictions, 1L)
}

///|
/// A value larger than the whole budget is refused.
///
/// The budget is what the memory holds. A value that does not fit in it does
/// not fit in it, and refusing it loudly is better than accepting it and
/// breaking the limit the caller asked for.
test "a value larger than the whole budget is refused" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_max_bytes(10L),
    @tesseract_memory.memory_clock_manual(0L),
  )
  assert_false(m.put("big", "12345678901"))
  assert_eq(m.size(), 0)
  assert_eq(m.size_bytes(), 0L)
  // A value that does fit is taken.
  assert_true(m.put("small", "12345"))
  assert_eq(m.size_bytes(), 5L)
}

///|
/// The byte total is right after everything that can change it.
///
/// A total that drifts is worse than no total: the budget stops meaning
/// anything, and the drift only shows up as an eviction that happens too
/// early or too late.
test "the byte total is right after everything that can change it" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_max_bytes(1000L),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "12345"))
  assert_eq(m.size_bytes(), 5L)
  // Replacing a value with a longer one.
  ignore(m.put("a", "1234567890"))
  assert_eq(m.size_bytes(), 10L)
  // Replacing it with a shorter one.
  ignore(m.put("a", "xy"))
  assert_eq(m.size_bytes(), 2L)
  // Reading it does not change its size.
  ignore(m.get("a"))
  assert_eq(m.size_bytes(), 2L)
  // Forgetting it.
  ignore(m.delete("a"))
  assert_eq(m.size_bytes(), 0L)
  // And an expiry.
  ignore(m.put_with_ttl("b", "123", @tesseract_memory.ttl_absolute(1000L)))
  assert_eq(m.size_bytes(), 3L)
  ignore(m.advance(1000L))
  assert_eq(m.size_bytes(), 0L)
}

///|
/// The two limits work together, and the smaller one is the one that binds.
test "the two limits work together, and the smaller one is the one that binds" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_capacity(2).with_max_bytes(1000L),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "1"))
  ignore(m.put("b", "2"))
  ignore(m.put("c", "3"))
  // The entry limit binds: three entries would be over a capacity of two.
  assert_eq(m.size(), 2)
  assert_eq(m.size_bytes(), 2L)
}

///|
/// Clearing the store empties the byte total too.
test "clearing the store empties the byte total too" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_max_bytes(1000L),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "12345"))
  ignore(m.put("b", "67890"))
  assert_eq(m.size_bytes(), 10L)
  m.clear()
  assert_eq(m.size_bytes(), 0L)
  assert_eq(m.size(), 0)
}

///|
/// Replacing a value with a bigger one makes room, and does not evict itself.
///
/// The capacity counts entries, so a replacement never grows it. The byte
/// budget counts content, and a replacement can grow that: five bytes replaced
/// by ten is ten bytes of content plus whatever else is there, not five. So a
/// replacement makes room too — and the key being written is never the one
/// that goes, because evicting it would be throwing the value away and then
/// writing it again.
test "replacing a value with a bigger one makes room, and does not evict itself" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_max_bytes(10L),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "12345"))
  ignore(m.put("b", "12345"))
  assert_eq(m.size_bytes(), 10L)
  // `a` grows from five bytes to ten. The store would hold fifteen, so `b` goes.
  assert_true(m.put("a", "1234567890"))
  assert_eq(m.size_bytes(), 10L)
  assert_eq(keys_of(m), "a")
  assert_eq(m.get("a"), Some("1234567890"))
  // One eviction and not two: the key being written was not thrown away and
  // written again.
  assert_eq(m.stats().evictions, 1L)
}

///|
/// A refused write leaves the store as it was.
///
/// A value too large for the whole budget is turned away. Turning it away must
/// not cost the caller the entries it already had: a write that fails should
/// leave the memory alone, not empty it on the way out.
test "a refused write leaves the store as it was" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_max_bytes(10L),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "12345"))
  ignore(m.put("b", "12345"))
  assert_false(m.put("big", "12345678901"))
  assert_eq(m.size(), 2)
  assert_eq(keys_of(m), "a,b")
  assert_eq(m.size_bytes(), 10L)
  assert_eq(m.stats().evictions, 0L)
}

///|
/// A negative byte budget is refused rather than read as no budget at all.
///
/// Zero is how a caller says "no budget". A negative number is a mistake, and
/// the one value that should not mean "keep everything" is a number that is
/// smaller than none.
test "a negative byte budget is refused rather than read as no budget at all" {
  let m = memory_at(0L)
  assert_false(
    m.set_config(@tesseract_memory.default_config().with_max_bytes(-1L)),
  )
  assert_eq(m.max_bytes(), 0L)
}

///|
/// Lowering the budget does not evict on the spot.
///
/// The store is brought back within a new limit by the next write that has to
/// make room. Until then the honest report is a store that is over its
/// budget, rather than one that has quietly thrown something away.
test "lowering the budget does not evict on the spot" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_max_bytes(1000L),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(m.put("a", "12345"))
  assert_true(
    m.set_config(@tesseract_memory.default_config().with_max_bytes(1L)),
  )
  assert_eq(m.size_bytes(), 5L)
  assert_eq(m.max_bytes(), 1L)
  // And the next write brings it back within the budget.
  ignore(m.put("b", "1"))
  assert_eq(m.size_bytes(), 1L)
  assert_eq(keys_of(m), "b")
}
