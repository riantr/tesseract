///|
/// The labels an entry carries.
///
/// Metadata is a **set of key/value pairs**. A key may carry several values —
/// "tag" can be both "urgent" and "infra" — and a pair written twice is one
/// pair, because a set has no duplicates.
///
/// The pairs are kept in order, by the letters of the key and then of the
/// value, so two entries with the same metadata have the same metadata however
/// they were written. The order is not decoration: it is what makes the
/// metadata of one entry comparable with the metadata of another.
///
/// The pairs are held behind a **private** field, and the accessor hands out a
/// copy. An array in this toolchain is *shared* rather than copied when it is
/// bound to another name — `let b = a` then `b.push(x)` changes `a` as well —
/// so a store that handed its array out would be handing out the ability to
/// change the entry behind its own back. The copy is what stops that.
///
/// ```
/// let m = @tesseract_memory.new_memory(100)
/// ignore(
///   m.put_spec(
///     "deploy",
///     "the deploy failed",
///     @tesseract_memory.default_spec()
///     .with_metadata(@tesseract_memory.new_metadata([("kind", "deploy")])),
///   ),
/// )
/// ```
pub struct Metadata {
  priv pairs : Array[(String, String)]
}

///|
/// The label that says what kind of thing an entry is.
///
/// A **kind** is not a new field on an entry: it is the value of this label.
/// That is the whole reason it is done this way. A store that holds notes, tasks
/// and reminders in one place does not need three kinds of entry — it needs one
/// kind of entry that says which it is, and the label is already the thing that
/// says what an entry *is*. So a filter that asks for a kind is a filter like
/// any other, a report that lists the kinds is a report over the labels, and the
/// checkpoint that stores an entry does not have to learn what a kind is.
pub const KIND_LABEL : String = "kind"

///|
/// Metadata with nothing in it.
///
/// An entry written without metadata carries none, and a filter that asks for
/// a key the entry does not have does not match it.
pub fn no_metadata() -> Metadata {
  { pairs: [], }
}

///|
/// Metadata from a list of pairs.
///
/// The pairs are **sorted** and **deduplicated**, so the result is a set: the
/// order the pairs were written in does not survive, and a pair written twice
/// is one pair. Two entries built from the same pairs therefore carry the same
/// metadata, and a filter cannot tell them apart by the order they were
/// written in.
///
/// The pairs are copied out of the caller's array, so a later change to that
/// array does not change the metadata.
pub fn new_metadata(pairs : Array[(String, String)]) -> Metadata {
  let sorted = pairs.copy()
  sorted.sort_by(fn(a, b) { metadata_pair_compare(a, b) })
  let unique : Array[(String, String)] = []
  for pair in sorted {
    if unique.length() == 0 || unique[unique.length() - 1] != pair {
      unique.push(pair)
    }
  }
  { pairs: unique, }
}

///|
/// Order two pairs: by the letters of the key, then of the value.
///
/// The order is by **letters** — `compare_text`, not the runtime's
/// `String::compare`, which compares the lengths first and would put "b" before
/// "aa".
fn metadata_pair_compare(a : (String, String), b : (String, String)) -> Int32 {
  let by_key = @tesseract.compare_text(a.0, b.0)
  if by_key != 0 {
    by_key
  } else {
    @tesseract.compare_text(a.1, b.1)
  }
}

///|
/// The pairs, in order.
///
/// The array is a **copy**. The metadata a caller holds cannot change what the
/// store holds, because an array is shared rather than copied when it is bound
/// to another name.
pub fn Metadata::pairs(self : Metadata) -> Array[(String, String)] {
  self.pairs.copy()
}

///|
/// True when the entry carries no metadata at all.
pub fn Metadata::is_empty(self : Metadata) -> Bool {
  self.pairs.length() == 0
}

///|
/// How many pairs the metadata carries.
pub fn Metadata::size(self : Metadata) -> Int32 {
  self.pairs.length()
}

///|
/// True when this is metadata a store can hold.
///
/// A pair with an **empty key** is not one. The key is the name of the label,
/// and a label with no name is not a label: it cannot be selected by any
/// filter a caller would write, and in a report it renders as `=value`, which
/// says nothing. A pair whose **value** is empty is fine — "the kind is
/// nothing" is a thing a caller can say, and it renders as `kind=`.
pub fn Metadata::is_valid(self : Metadata) -> Bool {
  for (key, _) in self.pairs {
    if key.is_empty() {
      return false
    }
  }
  true
}

///|
/// Whether the metadata carries the key at all, with any value.
pub fn Metadata::has(self : Metadata, key : String) -> Bool {
  for (k, _) in self.pairs {
    if k == key {
      return true
    }
  }
  false
}

///|
/// Whether the metadata carries the key **with** that value.
///
/// The comparison is exact — the same bytes in the same order. A value that
/// differs only in its case is a different value, because a filter that
/// matched loosely would make the answer depend on a rule nobody wrote down.
pub fn Metadata::has_value(
  self : Metadata,
  key : String,
  value : String,
) -> Bool {
  for (k, v) in self.pairs {
    if k == key && v == value {
      return true
    }
  }
  false
}

///|
/// The same labels, with the **kind** set.
///
/// The kind is one value: a metadata that already carried a kind is given the
/// new one rather than carrying both. Two kinds on one entry would be a
/// contradiction, and a set of pairs is the only place that can be said once.
///
/// A kind with **no name** takes the kind away rather than writing an empty
/// one. An entry of no kind is an entry with no kind label, and the two are
/// not the same thing: a label with an empty value is a thing a caller can
/// say about something else.
pub fn Metadata::with_kind(self : Metadata, kind : String) -> Metadata {
  let kept : Array[(String, String)] = []
  for pair in self.pairs {
    if pair.0 != KIND_LABEL {
      kept.push(pair)
    }
  }
  if !kind.is_empty() {
    kept.push((KIND_LABEL, kind))
  }
  new_metadata(kept)
}

///|
/// The values the key carries, in order.
///
/// A key may carry several values, so this is a list and not a single string.
/// A key that is not there gives an empty list.
pub fn Metadata::values(self : Metadata, key : String) -> Array[String] {
  let out : Array[String] = []
  for (k, v) in self.pairs {
    if k == key {
      out.push(v)
    }
  }
  out
}

///|
/// How many bytes the metadata takes up.
///
/// The key and the value of every pair, in UTF-8 bytes. The budget is about
/// what the memory holds, and the labels are part of what it holds.
pub fn Metadata::bytes(self : Metadata) -> Int64 {
  let mut total = 0L
  for (key, value) in self.pairs {
    total = total + utf8_bytes(key) + utf8_bytes(value)
  }
  total
}

///|
/// The metadata as one line, for a report.
///
/// The pairs are separated by a space and written as `key=value`. This is for
/// reading, not for parsing back: a value that contains a space or an equals
/// sign is written as it is and would not survive a round trip.
pub fn Metadata::describe(self : Metadata) -> String {
  let parts : Array[String] = []
  for (key, value) in self.pairs {
    parts.push(key + "=" + value)
  }
  parts.join(" ")
}

///|
/// A condition on the metadata of an entry.
///
/// A filter is a **value**, not a call: it can be built, printed and handed to
/// a shell, which a function cannot. That matters because a filter is the
/// thing a caller composes — several conditions and-ed together — and a
/// composition of calls is a composition nobody can show.
pub enum MetadataFilter {
  Has(String)
  Lacks(String)
  Equals(String, String)
  NotEquals(String, String)
  All(Array[MetadataFilter])
  Any(Array[MetadataFilter])
}

///|
/// A filter that asks for the key, with any value.
pub fn filter_has(key : String) -> MetadataFilter {
  MetadataFilter::Has(key)
}

///|
/// A filter that asks for the key **not** to be there.
pub fn filter_lacks(key : String) -> MetadataFilter {
  MetadataFilter::Lacks(key)
}

///|
/// A filter that asks for the key to carry the value.
pub fn filter_equals(key : String, value : String) -> MetadataFilter {
  MetadataFilter::Equals(key, value)
}

///|
/// A filter that asks for the key not to carry the value.
pub fn filter_not_equals(key : String, value : String) -> MetadataFilter {
  MetadataFilter::NotEquals(key, value)
}

///|
/// A filter that asks for **every** one of the filters to hold.
pub fn filter_all(filters : Array[MetadataFilter]) -> MetadataFilter {
  MetadataFilter::All(filters)
}

///|
/// A filter that asks for **at least one** of the filters to hold.
pub fn filter_any(filters : Array[MetadataFilter]) -> MetadataFilter {
  MetadataFilter::Any(filters)
}

///|
/// Whether the metadata satisfies the filter.
///
/// - **Has** — the key is there, with any value.
/// - **Lacks** — the key is not there.
/// - **Equals** — the key is there and carries the value.
/// - **NotEquals** — the key does not carry the value. A key that is not there
///   satisfies it: it certainly does not carry the value.
/// - **All** — every one of the filters holds. An **empty** list holds: nothing
///   was asked, so nothing was missed.
/// - **Any** — at least one of the filters holds. An **empty** list does not
///   hold: nothing was asked, so nothing was found.
pub fn MetadataFilter::matches(
  self : MetadataFilter,
  metadata : Metadata,
) -> Bool {
  match self {
    Has(key) => metadata.has(key)
    Lacks(key) => !metadata.has(key)
    Equals(key, value) => metadata.has_value(key, value)
    NotEquals(key, value) => !metadata.has_value(key, value)
    All(filters) => filters_all_hold(filters, metadata)
    Any(filters) => filters_any_hold(filters, metadata)
  }
}

///|
/// Whether every one of the filters holds.
fn filters_all_hold(
  filters : Array[MetadataFilter],
  metadata : Metadata,
) -> Bool {
  for filter in filters {
    if !filter.matches(metadata) {
      return false
    }
  }
  true
}

///|
/// Whether at least one of the filters holds.
fn filters_any_hold(
  filters : Array[MetadataFilter],
  metadata : Metadata,
) -> Bool {
  for filter in filters {
    if filter.matches(metadata) {
      return true
    }
  }
  false
}

///|
/// The filter as one line, for a report.
pub fn MetadataFilter::describe(self : MetadataFilter) -> String {
  match self {
    Has(key) => "has " + key
    Lacks(key) => "lacks " + key
    Equals(key, value) => key + "=" + value
    NotEquals(key, value) => key + "!=" + value
    All(filters) => "(" + describe_filters(filters, " and ") + ")"
    Any(filters) => "(" + describe_filters(filters, " or ") + ")"
  }
}

///|
/// The filters, one after another, separated by a word.
fn describe_filters(
  filters : Array[MetadataFilter],
  between : String,
) -> String {
  let parts : Array[String] = []
  for filter in filters {
    parts.push(filter.describe())
  }
  parts.join(between)
}
