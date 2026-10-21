///|
/// One result of a search.
pub struct Hit {
  key : String
  value : String
  score : Double
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
/// - **Which entries are eligible** — the live ones. An expired entry is gone
///   before the search starts.
/// - **What is returned** — only entries with a score above zero, at most `k`
///   of them, ties broken by key so the same store always answers the same
///   way.
///
/// A `k` of zero or less returns nothing. Returning the zero-score entries
/// would pad the answer with entries that have nothing to do with the query,
/// and a caller that asked for three matches would get three.
pub fn Memory::search(self : Memory, query : String, k : Int32) -> Array[Hit] {
  ignore(self.expire_due())
  if k <= 0 {
    return []
  }
  let now = self.now()
  let policy = self.config.similarity
  let recency = self.config.recency
  let scored : Array[Hit] = []
  for (_, entry) in self.entries.iter() {
    let base = similarity_score(query, entry.value, policy)
    if base <= 0.0 {
      continue
    }
    let weight = recency.weight(entry.age_ms(now))
    let score = base * weight
    if score <= 0.0 {
      continue
    }
    scored.push({ key: entry.key, value: entry.value, score, })
  }
  scored.sort_by(fn(a, b) {
    let by_score = b.score.compare(a.score)
    if by_score != 0 {
      by_score
    } else {
      String::compare(a.key, b.key)
    }
  })
  let out : Array[Hit] = []
  let mut i = 0
  while i < scored.length() && i < k {
    out.push(scored[i])
    i = i + 1
  }
  out
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
  let out : Array[String] = []
  for hit in self.search(query, k) {
    out.push(hit.key)
  }
  out
}
