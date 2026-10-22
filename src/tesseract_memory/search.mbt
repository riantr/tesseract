///|
/// One result of a search.
pub struct Hit {
  scope : String
  key : String
  value : String
  score : Double
  importance : Double
  metadata : Metadata
}

///|
/// The scope the hit is in.
///
/// The key is unique **within** a scope, so a hit from a store-wide search
/// only says which entry it is when it says which scope it is in.
pub fn Hit::scope(self : Hit) -> String {
  self.scope
}

///|
/// The key of the hit.
pub fn Hit::key(self : Hit) -> String {
  self.key
}

///|
/// The value of the hit.
pub fn Hit::value(self : Hit) -> String {
  self.value
}

///|
/// The score of the hit, in `0.0..1.0`.
pub fn Hit::score(self : Hit) -> Double {
  self.score
}

///|
/// How much the entry counts, in `0.0..1.0`.
///
/// The score is a product of three things, and this is one of them: an entry
/// that counts half as much is found half as strongly, for the same query and
/// at the same age.
pub fn Hit::importance(self : Hit) -> Double {
  self.importance
}

///|
/// The labels of the entry the hit is.
///
/// The hit carries what the entry was labelled with, so a caller that filtered
/// on the labels can see which of them the entry has — the filter may have
/// been an *or* of several conditions, and then the hit is what says which
/// one held.
pub fn Hit::metadata(self : Hit) -> Metadata {
  self.metadata
}

///|
/// The entries most like `query`, best first.
///
/// Four things decide the answer, and each of them is a choice rather than a
/// default of the implementation:
///
/// - **Which similarity** — the store's configuration. The default is
///   Jaccard.
/// - **How much recency counts** — the store's configuration. With a decay
///   policy the similarity is multiplied by `0.5 ^ (age / half_life)`, so an
///   old entry is worth less even when it matches better.
/// - **How much the entry counts** — the entry's own importance, which
///   multiplies the score like the other two do. An entry written with
///   `with_importance(0.5)` is found half as strongly as the same entry
///   written with the default.
/// - **Which entries are eligible** — the live ones of the **default scope**.
///   An expired entry is gone before the search starts, and an entry in
///   another scope is not a candidate at all.
///
/// What is returned is only entries with a score above zero, at most `k` of
/// them, ties broken by scope and key so the same store always answers the
/// same way.
///
/// A `k` of zero or less returns nothing. Returning the zero-score entries
/// would pad the answer with entries that have nothing to do with the query,
/// and a caller that asked for three matches would get three.
///
/// The search across every scope is `search_all`, and the search that also
/// asks what the entries are labelled is `search_filtered`.
pub fn Memory::search(self : Memory, query : String, k : Int32) -> Array[Hit] {
  self.search_in(default_scope_name(), query, k)
}

///|
/// The entries most like `query` that the filter admits, best first.
///
/// The filter is applied to the **candidates**, before they are scored: an
/// entry whose labels do not satisfy it is not a candidate at all, the same
/// way an entry in another scope is not a candidate for a search of one scope.
/// So the filter does not change the score of what it admits — it changes
/// **which** entries the score is computed for.
///
/// The `k` is a limit on the answer, not on the candidates: the store looks at
/// every entry that satisfies the filter, scores them all, and keeps the best
/// `k`. A filter that admits fewer than `k` entries gives fewer than `k`,
/// rather than padding the answer with entries the filter turned away.
pub fn Memory::search_filtered(
  self : Memory,
  query : String,
  k : Int32,
  filter : MetadataFilter,
) -> Array[Hit] {
  self.search_in_where(default_scope_name(), query, k, Some(filter))
}

///|
/// The keys of the entries most like `query`, best first.
///
/// The same search, without the values, for a caller that only wants to know
/// what to read.
pub fn Memory::search_keys(
  self : Memory,
  query : String,
  k : Int32,
) -> Array[String] {
  self.search_keys_in(default_scope_name(), query, k)
}

///|
/// The keys of the entries most like `query` that the filter admits.
pub fn Memory::search_filtered_keys(
  self : Memory,
  query : String,
  k : Int32,
  filter : MetadataFilter,
) -> Array[String] {
  self.search_keys_in_where(default_scope_name(), query, k, Some(filter))
}

///|
/// The entries most like `query`, in **every** scope, best first.
///
/// The same search as `search`, over the whole store: a scope that holds
/// something close to the query is a candidate, whatever scope it is in. Each
/// hit says which scope it came from, because a key is unique only within a
/// scope.
///
/// The ties are broken by scope and then by key, so the answer does not
/// depend on the order the scopes happened to be written in.
pub fn Memory::search_all(
  self : Memory,
  query : String,
  k : Int32,
) -> Array[Hit] {
  self.search_all_where(query, k, None)
}

///|
/// The entries most like `query` that the filter admits, in **every** scope.
pub fn Memory::search_all_filtered(
  self : Memory,
  query : String,
  k : Int32,
  filter : MetadataFilter,
) -> Array[Hit] {
  self.search_all_where(query, k, Some(filter))
}

///|
/// The keys of the entries most like `query`, in every scope, best first.
///
/// The same search as `search_all`, without the values and without the scope
/// that says which of them each key is in — so it is only unambiguous when
/// the caller knows the key is in one scope.
pub fn Memory::search_all_keys(
  self : Memory,
  query : String,
  k : Int32,
) -> Array[String] {
  self.search_all_keys_where(query, k, None)
}

///|
/// The keys of the entries most like `query` that the filter admits, in every
/// scope.
pub fn Memory::search_all_filtered_keys(
  self : Memory,
  query : String,
  k : Int32,
  filter : MetadataFilter,
) -> Array[String] {
  self.search_all_keys_where(query, k, Some(filter))
}

///|
/// The live entries of the default scope whose labels the filter admits, in
/// key order.
///
/// The same list as `entries`, with the ones the filter turns away left out.
/// There is no text to match here: this is retrieval **by** the labels rather
/// than by the words.
pub fn Memory::entries_filtered(
  self : Memory,
  filter : MetadataFilter,
) -> Array[Entry] {
  self.entries_in_where(default_scope_name(), Some(filter))
}

///|
/// The entries of one scope most like `query`, best first.
///
/// The same search as the store's, over this scope's entries only: an entry
/// in another scope is not a candidate, however well it matches.
fn Memory::search_in(
  self : Memory,
  scope : String,
  query : String,
  k : Int32,
) -> Array[Hit] {
  self.search_in_where(scope, query, k, None)
}

///|
/// The entries of one scope most like `query` that the filter admits.
fn Memory::search_in_where(
  self : Memory,
  scope : String,
  query : String,
  k : Int32,
  filter : MetadataFilter?,
) -> Array[Hit] {
  ignore(self.expire_due())
  if k <= 0 {
    return []
  }
  let now = self.now()
  let policy = self.config.similarity
  let recency = self.config.recency
  let scored : Array[Hit] = []
  match self.entries.get(scope) {
    Some(inner) =>
      for (_, entry) in inner.iter() {
        if admitted(entry, filter) {
          match score_entry(query, entry, policy, recency, now) {
            Some(hit) => scored.push(hit)
            None => ()
          }
        }
      }
    None => ()
  }
  scored.sort_by(fn(a, b) { hit_compare(a, b) })
  let out : Array[Hit] = []
  let mut i = 0
  while i < scored.length() && i < k {
    out.push(scored[i])
    i = i + 1
  }
  out
}

///|
/// The keys of one scope's entries most like `query`, best first.
fn Memory::search_keys_in(
  self : Memory,
  scope : String,
  query : String,
  k : Int32,
) -> Array[String] {
  self.search_keys_in_where(scope, query, k, None)
}

///|
/// The keys of one scope's entries most like `query` that the filter admits.
fn Memory::search_keys_in_where(
  self : Memory,
  scope : String,
  query : String,
  k : Int32,
  filter : MetadataFilter?,
) -> Array[String] {
  let out : Array[String] = []
  for hit in self.search_in_where(scope, query, k, filter) {
    out.push(hit.key)
  }
  out
}

///|
/// The entries most like `query` in every scope that the filter admits.
fn Memory::search_all_where(
  self : Memory,
  query : String,
  k : Int32,
  filter : MetadataFilter?,
) -> Array[Hit] {
  ignore(self.expire_due())
  if k <= 0 {
    return []
  }
  let now = self.now()
  let policy = self.config.similarity
  let recency = self.config.recency
  let scored : Array[Hit] = []
  for (_, inner) in self.entries.iter() {
    for (_, entry) in inner.iter() {
      if admitted(entry, filter) {
        match score_entry(query, entry, policy, recency, now) {
          Some(hit) => scored.push(hit)
          None => ()
        }
      }
    }
  }
  scored.sort_by(fn(a, b) { hit_compare(a, b) })
  let out : Array[Hit] = []
  let mut i = 0
  while i < scored.length() && i < k {
    out.push(scored[i])
    i = i + 1
  }
  out
}

///|
/// The keys of the entries most like `query` in every scope that the filter
/// admits.
fn Memory::search_all_keys_where(
  self : Memory,
  query : String,
  k : Int32,
  filter : MetadataFilter?,
) -> Array[String] {
  let out : Array[String] = []
  for hit in self.search_all_where(query, k, filter) {
    out.push(hit.key)
  }
  out
}

///|
/// The live entries of a scope whose labels the filter admits, in key order.
fn Memory::entries_in_where(
  self : Memory,
  scope : String,
  filter : MetadataFilter?,
) -> Array[Entry] {
  ignore(self.expire_due())
  let out : Array[Entry] = []
  match self.entries.get(scope) {
    Some(inner) =>
      for (_, entry) in inner.iter() {
        if admitted(entry, filter) {
          out.push(entry)
        }
      }
    None => ()
  }
  out.sort_by(fn(a, b) { @tesseract.compare_text(a.key, b.key) })
  out
}

///|
/// Whether the entry is a candidate: the filter admits it, or there is no
/// filter.
///
/// A filter with no conditions at all admits everything, which is what a
/// caller who built an empty `All` asked for.
fn admitted(entry : Entry, filter : MetadataFilter?) -> Bool {
  match filter {
    Some(f) => f.matches(entry.metadata)
    None => true
  }
}

///|
/// The score of an entry against a query, or `None` when it does not match.
///
/// The score is a **product of three weights**: how alike the texts are, how
/// recently the entry was written, and how much the entry counts. Each is a
/// fraction, so the score is in `0.0..1.0` whatever the three are.
///
/// An entry that shares nothing with the query is not a weak match: it is not
/// a match, and padding the answer with it would mean a caller that asked for
/// three matches always got three.
fn score_entry(
  query : String,
  entry : Entry,
  policy : Similarity,
  recency : Recency,
  now : Int64,
) -> Hit? {
  let base = similarity_score(query, entry.value, policy)
  if base <= 0.0 {
    return None
  }
  let weight = recency.weight(entry.age_ms(now))
  let score = base * weight * entry.importance
  if score <= 0.0 {
    return None
  }
  Some({
    scope: entry.scope,
    key: entry.key,
    value: entry.value,
    score,
    importance: entry.importance,
    metadata: entry.metadata,
  })
}

///|
/// Order two hits: the better score first, and a tie broken by scope and key.
///
/// The tie-break has to be total, or the same store answers two runs of the
/// same program differently. The scope comes before the key because a key is
/// only unique within a scope, and the order is by letters — the runtime's
/// `String::compare` would put the scope called "work" before the scope
/// called "default".
fn hit_compare(a : Hit, b : Hit) -> Int32 {
  let by_score = b.score.compare(a.score)
  if by_score != 0 {
    by_score
  } else {
    let by_scope = @tesseract.compare_text(a.scope, b.scope)
    if by_scope != 0 {
      by_scope
    } else {
      @tesseract.compare_text(a.key, b.key)
    }
  }
}
