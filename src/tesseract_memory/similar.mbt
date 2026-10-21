///|
/// How two pieces of text are compared for likeness.
///
/// Four ways to mean "like", and they answer different questions:
///
/// - `Jaccard` — how much they share, as a share of their whole vocabulary.
///   Symmetric, and it punishes a long document for being long.
/// - `Cosine` — how similar they are as documents, so a word said three times
///   counts three times.
/// - `Containment` — how much of the **query** the document covers. This is the
///   one that answers a search: a two-word query should match a long document
///   that contains both words, and Jaccard would punish that document.
/// - `Structure` — whether two JSON documents have the same shape. Two records
///   with the same keys are alike even when every value differs, and no amount
///   of word-matching will ever say so.
///
/// Every score is in `0.0..1.0`, and every one of them is **exact**: the same
/// two texts always give the same score, with no model to drift.
pub enum Similarity {
  Jaccard
  Cosine
  Containment
  Structure
}

///|
/// Share of the combined vocabulary that the two texts have in common.
pub fn similarity_jaccard() -> Similarity {
  Jaccard
}

///|
/// Cosine of the two token-count vectors.
pub fn similarity_cosine() -> Similarity {
  Cosine
}

///|
/// How much of the query the document covers.
pub fn similarity_containment() -> Similarity {
  Containment
}

///|
/// Whether the two JSON documents have the same shape.
pub fn similarity_structure() -> Similarity {
  Structure
}

///|
/// The name of a similarity, for a report.
pub fn Similarity::name(self : Similarity) -> String {
  match self {
    Jaccard => "jaccard"
    Cosine => "cosine"
    Containment => "containment"
    Structure => "structure"
  }
}

///|
/// How much a recency weight counts for.
///
/// `None` ranks on similarity alone. `Decay(half_life)` multiplies the
/// similarity by `0.5 ^ (age / half_life)`, so an entry written more than one
/// half-life ago carries half the weight, and the oldest of all approaches
/// zero without ever reaching it.
pub enum Recency {
  None
  Decay(Int64)
}

///|
/// Rank on similarity alone.
pub fn recency_none() -> Recency {
  None
}

///|
/// Halve the weight of an entry every `half_life_ms` milliseconds.
pub fn recency_decay(half_life_ms : Int64) -> Recency {
  Decay(half_life_ms)
}

///|
/// True when the recency weight is doing anything.
pub fn Recency::is_active(self : Recency) -> Bool {
  match self {
    None => false
    Decay(_) => true
  }
}

///|
/// The recency weight of an entry of `age_ms`, in `0.0..1.0`.
pub fn Recency::weight(self : Recency, age_ms : Int64) -> Double {
  match self {
    None => 1.0
    Decay(half_life) =>
      if half_life <= 0L {
        1.0
      } else {
        let exponent = age_ms.to_double() / half_life.to_double()
        @math.pow(0.5, exponent)
      }
  }
}

///|
/// The name of a recency policy, for a report.
pub fn Recency::name(self : Recency) -> String {
  match self {
    None => "none"
    Decay(ms) => "decay " + ms.to_string() + "ms"
  }
}
