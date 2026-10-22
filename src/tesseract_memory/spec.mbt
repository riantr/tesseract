///|
/// How one entry is written: how long it lives, how much it counts, and what
/// it is labelled.
///
/// The three settings are one thing rather than three because they are written
/// together, and a caller who has to remember which call takes which is a
/// caller who will get it wrong. `put` and `put_with_ttl` are the two
/// shorthands for the common cases; `put_spec` is the whole of it.
///
/// ```
/// ignore(m.put_spec(
///   "todo",
///   "ship 0.1.9",
///   @tesseract_memory.default_spec()
///   .with_ttl(@tesseract_memory.ttl_absolute(60000L))
///   .with_importance(0.5)
///   .with_metadata(@tesseract_memory.new_metadata([("kind", "task")])),
/// ))
/// ```
pub struct EntrySpec {
  ttl : Ttl
  importance : Double
  metadata : Metadata
}

///|
/// The spec of an ordinary entry: it never expires, it counts fully, and it
/// carries no labels.
///
/// The default TTL of a *store* is a setting of the store, so a `put` with no
/// TTL of its own gets that one; the spec's own default is "never", which is
/// what a spec carries when the caller has not said otherwise.
pub fn default_spec() -> EntrySpec {
  { ttl: ttl_never(), importance: 1.0, metadata: no_metadata(), }
}

///|
/// The same spec with a different lifetime.
pub fn EntrySpec::with_ttl(self : EntrySpec, ttl : Ttl) -> EntrySpec {
  { ..self, ttl, }
}

///|
/// The same spec with a different importance.
///
/// The importance is a **weight in `(0.0, 1.0]`**: 1.0 counts fully and is
/// the most an entry can count, and a lower number counts less. It is the
/// same number the search score is built from, so an entry at 0.2 is found
/// a fifth as strongly as the same entry at 1.0.
///
/// The range has no zero in it on purpose. An importance of zero would make
/// the entry unfindable — stored, readable by key, and never matched by a
/// search — and a zero-initialised field is the easiest way to get there by
/// accident. An entry that should not be found is an entry that should be
/// deleted.
pub fn EntrySpec::with_importance(
  self : EntrySpec,
  importance : Double,
) -> EntrySpec {
  { ..self, importance, }
}

///|
/// The same spec with different labels.
///
/// The labels are what a **filtered search** looks at: they do not change how
/// much the entry counts, and they do not change what the store evicts. They
/// say what the entry *is*, and a search uses that to say which of the
/// entries it found the caller meant.
pub fn EntrySpec::with_metadata(
  self : EntrySpec,
  metadata : Metadata,
) -> EntrySpec {
  { ..self, metadata, }
}

///|
/// True when this is a spec a memory can honour.
///
/// Three settings are not usable:
///
/// - **An importance outside `(0.0, 1.0]`.** Above one it would carry the
///   search score past the `0.0..1.0` it is documented to be in, and at or
///   below zero the entry could never be found.
/// - **A lifetime in the past.** An entry written with one is dead the
///   moment it is written, so accepting the write would be accepting a write
///   that does nothing.
/// - **A label with an empty key.** The key is the name of the label, and a
///   label with no name is not a label: no filter can select it and a report
///   of it says nothing.
pub fn EntrySpec::is_valid(self : EntrySpec) -> Bool {
  self.importance > 0.0 &&
  self.importance <= 1.0 &&
  self.ttl.is_valid() &&
  self.metadata.is_valid()
}
