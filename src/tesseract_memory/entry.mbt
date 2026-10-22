///|
/// One thing the memory remembers.
///
/// The fields are public so a caller can read them, and the memory owns the
/// lifecycle: an entry is written, touched, and eventually removed. Nothing
/// outside this package writes one.
///
/// The entry says which **scope** it is in, because a key is unique only
/// within a scope: the key `todo` in `default` and the key `todo` in `notes`
/// are two entries, and an entry that did not say where it lived could not be
/// told from the other.
pub struct Entry {
  scope : String
  key : String
  value : String
  added_at : Int64
  deadline : Int64
  window_ms : Int64
  sliding : Bool
  last_seen : Int64
  hits : Int64
  importance : Double
}

///|
/// True when the entry is past its deadline.
///
/// The boundary is *exclusive at the live end*: an entry with deadline `D` is
/// live while `now < D` and expired at `now == D`. A TTL of 1000ms therefore
/// gives exactly 1000 milliseconds of life, and the entry written at t=0 is
/// gone at t=1000 — not a millisecond later, and not a millisecond earlier.
///
/// Whether an entry has a deadline at all is decided by its **window**, not
/// by its deadline. An entry with no deadline has a window of zero, and a
/// deadline of zero is an ordinary deadline — the one an entry written at
/// t=0 with the shortest lifetime there is would have. Deciding it by the
/// deadline instead would make that entry live forever.
pub fn Entry::expired(self : Entry, now_ms : Int64) -> Bool {
  if self.window_ms == 0L {
    false
  } else {
    now_ms >= self.deadline
  }
}

///|
/// How long the entry has been in the memory, in milliseconds.
pub fn Entry::age_ms(self : Entry, now_ms : Int64) -> Int64 {
  now_ms - self.added_at
}

///|
/// How long the entry has been untouched, in milliseconds.
pub fn Entry::idle_ms(self : Entry, now_ms : Int64) -> Int64 {
  now_ms - self.last_seen
}

///|
/// The entry as it is after being read at `now_ms`.
///
/// A read counts as a use — the hit count goes up and the idle clock restarts.
/// A sliding entry also gets its deadline pushed forward by a whole window,
/// which is the whole difference between it and an absolute one.
pub fn Entry::touched(self : Entry, now_ms : Int64) -> Entry {
  {
    scope: self.scope,
    key: self.key,
    value: self.value,
    added_at: self.added_at,
    deadline: if self.sliding && self.window_ms > 0L {
      instant_after(now_ms, self.window_ms)
    } else {
      self.deadline
    },
    window_ms: self.window_ms,
    sliding: self.sliding,
    last_seen: now_ms,
    hits: self.hits + 1L,
    importance: self.importance,
  }
}

///|
/// How much this entry counts, in `0.0..1.0`.
///
/// The importance is the weight the search score is built from, so an entry at
/// 0.2 is found a fifth as strongly as the same entry at 1.0.
pub fn Entry::importance(self : Entry) -> Double {
  self.importance
}

///|
/// A one-line description of the entry, for a report.
pub fn Entry::describe(self : Entry, now_ms : Int64) -> String {
  self.key +
  " (age " +
  self.age_ms(now_ms).to_string() +
  "ms, hits " +
  self.hits.to_string() +
  ", importance " +
  self.importance.to_string() +
  ", " +
  (if self.window_ms == 0L {
    "no deadline"
  } else {
    "expires in " + (self.deadline - now_ms).to_string() + "ms"
  }) +
  ")"
}
