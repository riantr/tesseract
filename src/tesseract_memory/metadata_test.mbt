///|
/// The labels an entry carries, and the searches that use them.
///
/// Two things are being tested here, and they are different things.
///
/// The first is the **metadata** itself: a set of key/value pairs, in order,
/// with duplicates dropped, and a pair with an empty key refused. The second is
/// the **filter**: a value that says which entries a search may look at.
///
/// The rule that matters most for the filter is where it is applied. A filter
/// is applied to the *candidates*, before they are scored — so it changes
/// which entries the store looks at, and not how they are ranked. A filter
/// applied after the ranking would give a different answer, and a worse one:
/// the best match would win and then be thrown away, and the answer would be
/// short.
///
/// The clock is manual in every test, so each of these is a number rather
/// than a race.

///|
/// A memory on a clock the test moves by hand.
fn meta_memory_at(start_ms : Int64) -> @tesseract_memory.Memory {
  @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config().with_capacity(10),
    @tesseract_memory.memory_clock_manual(start_ms),
  )
}

///|
/// The pairs of a metadata, as one string, so a comparison is exact.
fn meta_pairs_of(m : @tesseract_memory.Metadata) -> String {
  let parts : Array[String] = []
  for (key, value) in m.pairs() {
    parts.push(key + "=" + value)
  }
  parts.join(",")
}

///|
/// A score, to three decimals, so a float comparison is exact.
fn meta_score_of(s : Double) -> String {
  let scaled = (s * 1000.0).round().to_int64()
  (scaled / 1000L).to_string() + "." + @tesseract.pad_number(scaled % 1000L, 3)
}

///|
/// The keys of a search, in order.
fn meta_hit_keys(hits : Array[@tesseract_memory.Hit]) -> String {
  let parts : Array[String] = []
  for hit in hits {
    parts.push(hit.key())
  }
  parts.join(",")
}

///|
/// Metadata with nothing in it is empty, and carries nothing.
test "metadata with nothing in it is empty" {
  let m = @tesseract_memory.no_metadata()
  assert_eq(m.is_empty(), true)
  assert_eq(m.size(), 0)
  assert_eq(m.has("kind"), false)
  assert_eq(m.bytes(), 0L)
}

///|
/// The pairs are in order, by the letters of the key and then of the value.
///
/// The order the pairs were written in does not survive, so two entries built
/// from the same pairs carry the same metadata.
test "the pairs are in order, by their letters" {
  let m = @tesseract_memory.new_metadata([
    ("tag", "urgent"),
    ("kind", "note"),
    ("tag", "infra"),
  ])
  assert_eq(meta_pairs_of(m), "kind=note,tag=infra,tag=urgent")
}

///|
/// A pair written twice is one pair: the metadata is a set.
test "a pair written twice is one pair" {
  let m = @tesseract_memory.new_metadata([("kind", "note"), ("kind", "note")])
  assert_eq(m.size(), 1)
  assert_eq(meta_pairs_of(m), "kind=note")
}

///|
/// The metadata is copied out of the caller's array.
///
/// An array in this toolchain is shared rather than copied when it is bound to
/// another name, so a metadata that kept the caller's array would change under
/// the caller.
test "the metadata is copied out of the caller's array" {
  let pairs = [("kind", "note")]
  let m = @tesseract_memory.new_metadata(pairs)
  pairs.push(("tag", "later"))
  assert_eq(m.size(), 1)
  assert_eq(meta_pairs_of(m), "kind=note")
}

///|
/// A label with no name is not a label, and the store refuses it.
///
/// The key is the name of the label. A pair with an empty key cannot be
/// selected by any filter a caller would write, and in a report it renders
/// as `=value`, which says nothing.
test "a label with no name is refused" {
  let bad = @tesseract_memory.new_metadata([("", "note")])
  assert_eq(bad.is_valid(), false)
  assert_eq(
    @tesseract_memory.default_spec().with_metadata(bad).is_valid(),
    false,
  )
  let m = meta_memory_at(0L)
  let refused = m.put_spec(
    "a",
    "x",
    @tesseract_memory.default_spec().with_metadata(
      @tesseract_memory.new_metadata([("", "note")]),
    ),
  )
  assert_eq(refused, false)
  assert_eq(m.size(), 0)
}

///|
/// A refused write leaves the store as it was.
test "a refused write leaves the store as it was" {
  let m = meta_memory_at(0L)
  ignore(m.put("keep", "value"))
  let size_before = m.size()
  let bytes_before = m.size_bytes()
  let refused = m.put_spec(
    "bad",
    "x",
    @tesseract_memory.default_spec().with_metadata(
      @tesseract_memory.new_metadata([("", "note")]),
    ),
  )
  assert_eq(refused, false)
  assert_eq(m.size(), size_before)
  assert_eq(m.size_bytes(), bytes_before)
  assert_eq(m.contains("bad"), false)
  assert_eq(m.get("keep"), Some("value"))
}

///|
/// An entry carries the labels it was written with.
test "an entry carries the labels it was written with" {
  let m = meta_memory_at(0L)
  ignore(
    m.put_spec(
      "a",
      "the deploy failed",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "deploy")]),
      ),
    ),
  )
  let entry = m.entry("a").unwrap()
  assert_eq(meta_pairs_of(entry.metadata()), "kind=deploy")
  assert_eq(entry.metadata().has("kind"), true)
  assert_eq(entry.metadata().has_value("kind", "deploy"), true)
}

///|
/// An entry written without labels carries none.
test "an entry written without labels carries none" {
  let m = meta_memory_at(0L)
  ignore(m.put("a", "x"))
  assert_eq(m.entry("a").unwrap().metadata().is_empty(), true)
}

///|
/// The labels take up room in the byte budget.
///
/// The budget is about what the memory holds, and a label is something the
/// memory holds. The key is not counted — it is the name of the entry rather
/// than its content.
test "the labels take up room in the byte budget" {
  let plain = meta_memory_at(0L)
  ignore(plain.put("a", "cat"))
  let labelled = meta_memory_at(0L)
  ignore(
    labelled.put_spec(
      "a",
      "cat",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "note")]),
      ),
    ),
  )
  // "cat" is three bytes, and the label "kind=note" is eight.
  assert_eq(plain.size_bytes(), 3L)
  assert_eq(labelled.size_bytes(), 11L)
}

///|
/// A filter that asks for the key admits the entry that has it.
test "a filter that asks for the key admits the entry that has it" {
  let m = @tesseract_memory.new_metadata([("kind", "note")])
  assert_eq(@tesseract_memory.filter_has("kind").matches(m), true)
  assert_eq(@tesseract_memory.filter_has("tag").matches(m), false)
}

///|
/// A filter that asks for the key to be absent.
test "a filter that asks for the key to be absent" {
  let m = @tesseract_memory.new_metadata([("kind", "note")])
  assert_eq(@tesseract_memory.filter_lacks("tag").matches(m), true)
  assert_eq(@tesseract_memory.filter_lacks("kind").matches(m), false)
}

///|
/// A filter that asks for the value.
test "a filter that asks for the value" {
  let m = @tesseract_memory.new_metadata([("kind", "note")])
  assert_eq(@tesseract_memory.filter_equals("kind", "note").matches(m), true)
  assert_eq(@tesseract_memory.filter_equals("kind", "task").matches(m), false)
  assert_eq(@tesseract_memory.filter_equals("tag", "note").matches(m), false)
}

///|
/// A filter that asks for the key **not** to carry the value.
///
/// A key that is not there satisfies it: it certainly does not carry the
/// value.
test "a filter that asks for the key not to carry the value" {
  let m = @tesseract_memory.new_metadata([("kind", "note")])
  assert_eq(
    @tesseract_memory.filter_not_equals("kind", "task").matches(m),
    true,
  )
  assert_eq(
    @tesseract_memory.filter_not_equals("kind", "note").matches(m),
    false,
  )
  assert_eq(@tesseract_memory.filter_not_equals("tag", "note").matches(m), true)
}

///|
/// A key with several values matches any of them.
test "a key with several values matches any of them" {
  let m = @tesseract_memory.new_metadata([("tag", "urgent"), ("tag", "infra")])
  assert_eq(m.values("tag").join(","), "infra,urgent")
  assert_eq(m.has_value("tag", "urgent"), true)
  assert_eq(m.has_value("tag", "infra"), true)
  assert_eq(m.has_value("tag", "later"), false)
  assert_eq(@tesseract_memory.filter_equals("tag", "urgent").matches(m), true)
  assert_eq(@tesseract_memory.filter_equals("tag", "later").matches(m), false)
}

///|
/// The values of a key that is not there are none.
test "the values of a key that is not there are none" {
  let m = @tesseract_memory.new_metadata([("kind", "note")])
  assert_eq(m.values("tag").length(), 0)
}

///|
/// Every one of the filters has to hold.
test "every one of the filters has to hold" {
  let m = @tesseract_memory.new_metadata([("kind", "note"), ("tag", "urgent")])
  let both = @tesseract_memory.filter_all([
    @tesseract_memory.filter_has("kind"),
    @tesseract_memory.filter_equals("tag", "urgent"),
  ])
  assert_eq(both.matches(m), true)
  let one_wrong = @tesseract_memory.filter_all([
    @tesseract_memory.filter_has("kind"),
    @tesseract_memory.filter_equals("tag", "later"),
  ])
  assert_eq(one_wrong.matches(m), false)
}

///|
/// At least one of the filters has to hold.
test "at least one of the filters has to hold" {
  let m = @tesseract_memory.new_metadata([("kind", "note")])
  let either = @tesseract_memory.filter_any([
    @tesseract_memory.filter_equals("kind", "note"),
    @tesseract_memory.filter_equals("tag", "urgent"),
  ])
  assert_eq(either.matches(m), true)
  let neither = @tesseract_memory.filter_any([
    @tesseract_memory.filter_equals("kind", "task"),
    @tesseract_memory.filter_equals("tag", "urgent"),
  ])
  assert_eq(neither.matches(m), false)
}

///|
/// An empty list of filters holds, and an empty list of alternatives does not.
///
/// Nothing was asked, so nothing was missed; nothing was asked, so nothing was
/// found.
test "an empty list holds, and an empty list of alternatives does not" {
  let m = @tesseract_memory.new_metadata([("kind", "note")])
  assert_eq(@tesseract_memory.filter_all([]).matches(m), true)
  assert_eq(@tesseract_memory.filter_any([]).matches(m), false)
}

///|
/// A filtered search leaves out the entries the filter turns away.
test "a filtered search leaves out the entries the filter turns away" {
  let m = meta_memory_at(0L)
  ignore(
    m.put_spec(
      "note",
      "the cat sat",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "note")]),
      ),
    ),
  )
  ignore(
    m.put_spec(
      "task",
      "the cat ran",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "task")]),
      ),
    ),
  )
  let hits = m.search_filtered(
    "cat",
    10,
    @tesseract_memory.filter_equals("kind", "note"),
  )
  assert_eq(meta_hit_keys(hits), "note")
}

///|
/// The filter does not change the score of what it admits.
///
/// The filter chooses the candidates; the similarity, the recency and the
/// importance still say how strongly each one is found.
test "the filter does not change the score of what it admits" {
  let m = meta_memory_at(0L)
  ignore(
    m.put_spec(
      "note",
      "the cat sat",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "note")]),
      ),
    ),
  )
  let plain = m.search("cat", 10)
  let filtered = m.search_filtered(
    "cat",
    10,
    @tesseract_memory.filter_has("kind"),
  )
  assert_eq(meta_score_of(filtered[0].score()), meta_score_of(plain[0].score()))
}

///|
/// A filter that admits nothing gives nothing.
///
/// The answer is not padded with the entries the filter turned away: a
/// caller that asked for notes and there are none should hear that there are
/// none.
test "a filter that admits nothing gives nothing" {
  let m = meta_memory_at(0L)
  ignore(
    m.put_spec(
      "note",
      "the cat sat",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "note")]),
      ),
    ),
  )
  let hits = m.search_filtered(
    "cat",
    10,
    @tesseract_memory.filter_equals("kind", "task"),
  )
  assert_eq(hits.length(), 0)
}

///|
/// The filter chooses the candidates, and the limit chooses the answer.
///
/// The entry the filter turns away is the **best match of all** — so a store
/// that ranked first and filtered afterwards would answer with nothing at
/// all, and a store that filtered first would answer with the best entry it
/// was allowed to look at.
///
/// The three entries score, against a five-word query: "the cat sat on the
/// mat" is 1.0, "the cat sat" is 0.6 and "the cat" is 0.4. The 1.0 is the one
/// the filter turns away.
test "the filter chooses the candidates, and the limit chooses the answer" {
  let m = meta_memory_at(0L)
  ignore(
    m.put_spec(
      "blocked",
      "the cat sat on the mat",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "task")]),
      ),
    ),
  )
  ignore(
    m.put_spec(
      "admitted_better",
      "the cat sat",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "note")]),
      ),
    ),
  )
  ignore(
    m.put_spec(
      "admitted_worse",
      "the cat",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "note")]),
      ),
    ),
  )
  let hits = m.search_filtered(
    "the cat sat on the mat",
    1,
    @tesseract_memory.filter_equals("kind", "note"),
  )
  // The best entry the filter admits, not the best entry there is, and not
  // nothing at all.
  assert_eq(hits.length(), 1)
  assert_eq(hits[0].key(), "admitted_better")
  // And with room for all of them, the two admitted ones are both there.
  let both = m.search_filtered(
    "the cat sat on the mat",
    10,
    @tesseract_memory.filter_equals("kind", "note"),
  )
  assert_eq(meta_hit_keys(both), "admitted_better,admitted_worse")
}

///|
/// A filtered search over every scope says which scope the hit is in.
test "a filtered search over every scope says which scope the hit is in" {
  let m = meta_memory_at(0L)
  ignore(
    m
    .scope("work")
    .put_spec(
      "todo",
      "the cat sat",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "note")]),
      ),
    ),
  )
  ignore(
    m
    .scope("home")
    .put_spec(
      "todo",
      "the cat ran",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "task")]),
      ),
    ),
  )
  let hits = m.search_all_filtered(
    "cat",
    10,
    @tesseract_memory.filter_equals("kind", "note"),
  )
  assert_eq(hits.length(), 1)
  assert_eq(hits[0].scope(), "work")
}

///|
/// The scope's own filtered search looks at that scope only.
test "the scope's own filtered search looks at that scope only" {
  let m = meta_memory_at(0L)
  ignore(
    m
    .scope("work")
    .put_spec(
      "todo",
      "the cat sat",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "note")]),
      ),
    ),
  )
  ignore(
    m.put_spec(
      "todo",
      "the cat ran",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "note")]),
      ),
    ),
  )
  let hits = m
    .scope("work")
    .search_filtered("cat", 10, @tesseract_memory.filter_equals("kind", "note"))
  assert_eq(hits.length(), 1)
  assert_eq(hits[0].scope(), "work")
}

///|
/// The entries can be listed by their labels alone.
///
/// There is no text to match here: this is retrieval *by* the labels.
test "the entries can be listed by their labels alone" {
  let m = meta_memory_at(0L)
  ignore(
    m.put_spec(
      "note",
      "the cat sat",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "note")]),
      ),
    ),
  )
  ignore(
    m.put_spec(
      "task",
      "the dog ran",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "task")]),
      ),
    ),
  )
  let listed = m.entries_filtered(
    @tesseract_memory.filter_equals("kind", "note"),
  )
  assert_eq(listed.length(), 1)
  assert_eq(listed[0].key(), "note")
}

///|
/// The labels do not change what the store evicts.
///
/// The labels say what an entry **is**; they are not a weight. A store that
/// evicted by them would make the eviction depend on a field nobody promised
/// anything about.
test "the labels do not change what the store evicts" {
  let m = @tesseract_memory.new_memory_with_clock(
    @tesseract_memory.default_config()
    .with_capacity(2)
    .with_eviction(@tesseract_memory.evict_lru()),
    @tesseract_memory.memory_clock_manual(0L),
  )
  ignore(
    m.put_spec(
      "first",
      "1",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "keep")]),
      ),
    ),
  )
  ignore(m.advance(100L))
  ignore(m.put("second", "2"))
  ignore(m.advance(100L))
  ignore(m.get("first"))
  ignore(m.put("third", "3"))
  // "first" was read, so "second" goes, labels or no labels.
  assert_eq(m.contains("second"), false)
  assert_eq(m.contains("first"), true)
}

///|
/// The labels survive a touch.
///
/// A touch moves the deadline and the hit count. It does not make a different
/// entry.
test "the labels survive a touch" {
  let m = meta_memory_at(0L)
  ignore(
    m.put_spec(
      "a",
      "x",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "note")]),
      ),
    ),
  )
  assert_eq(m.touch("a"), true)
  assert_eq(meta_pairs_of(m.entry("a").unwrap().metadata()), "kind=note")
}

///|
/// Writing the key again replaces the labels.
///
/// The entry is a new one — it was added now, and nobody has read the new
/// value yet — so it carries the labels it was written with this time.
test "writing the key again replaces the labels" {
  let m = meta_memory_at(0L)
  ignore(
    m.put_spec(
      "a",
      "x",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "note")]),
      ),
    ),
  )
  ignore(
    m.put_spec(
      "a",
      "y",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "task")]),
      ),
    ),
  )
  assert_eq(meta_pairs_of(m.entry("a").unwrap().metadata()), "kind=task")
}

///|
/// The replacement takes the old labels out of the byte count.
///
/// The total is a running count of what the store holds, and the old labels
/// are gone.
test "the replacement takes the old labels out of the byte count" {
  let m = meta_memory_at(0L)
  ignore(
    m.put_spec(
      "a",
      "x",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "note")]),
      ),
    ),
  )
  let bytes_with_labels = m.size_bytes()
  ignore(
    m.put_spec(
      "a",
      "x",
      @tesseract_memory.default_spec().with_metadata(
        @tesseract_memory.new_metadata([("kind", "task")]),
      ),
    ),
  )
  assert_eq(m.size_bytes(), bytes_with_labels)
  ignore(m.put("a", "x"))
  assert_eq(m.size_bytes(), 1L)
}

///|
/// A filter is a value, and it says what it is.
test "a filter is a value, and it says what it is" {
  assert_eq(@tesseract_memory.filter_has("kind").describe(), "has kind")
  assert_eq(@tesseract_memory.filter_lacks("kind").describe(), "lacks kind")
  assert_eq(
    @tesseract_memory.filter_equals("kind", "note").describe(),
    "kind=note",
  )
  assert_eq(
    @tesseract_memory.filter_not_equals("kind", "note").describe(),
    "kind!=note",
  )
}
