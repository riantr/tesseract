///|
/// Which entry goes when the store is full.
///
/// The names are the ones people already mean by them, and they answer
/// different questions:
///
/// - `LeastRecentlyUsed` — what nobody has touched for longest.
/// - `LeastFrequentlyUsed` — what nobody has read, however long ago.
/// - `SoonestExpiry` — what is closest to expiring anyway. An entry that never
///   expires is infinitely far from expiring, so it goes last.
/// - `OldestFirst` — what was written longest ago, regardless of use.
/// - `Largest` — what takes the most room. The size is the one the byte budget
///   counts: the value and its labels. This is the policy for a store whose
///   entries are not all the same size, where throwing away the smallest one
///   would mean throwing away several of them to make the same room.
///
/// Every policy breaks a tie the same way: by key. A store that evicts a
/// different entry on two runs of the same program is a store nobody can test.
pub enum EvictionPolicy {
  LeastRecentlyUsed
  LeastFrequentlyUsed
  SoonestExpiry
  OldestFirst
  Largest
}

///|
/// Evict the entry nobody has touched for longest.
pub fn evict_lru() -> EvictionPolicy {
  LeastRecentlyUsed
}

///|
/// Evict the entry nobody has read.
pub fn evict_lfu() -> EvictionPolicy {
  LeastFrequentlyUsed
}

///|
/// Evict the entry closest to expiring.
pub fn evict_soonest_expiry() -> EvictionPolicy {
  SoonestExpiry
}

///|
/// Evict the entry written longest ago.
pub fn evict_oldest() -> EvictionPolicy {
  OldestFirst
}

///|
/// Evict the entry that takes the most room.
///
/// The room an entry takes is what the byte budget counts: the value and its
/// labels. A store whose entries are all the same size has no use for this
/// policy — every eviction frees the same — and a store whose entries are not
/// has every use for it.
pub fn evict_largest() -> EvictionPolicy {
  Largest
}

///|
/// The name of a policy, for a report.
pub fn EvictionPolicy::name(self : EvictionPolicy) -> String {
  match self {
    LeastRecentlyUsed => "lru"
    LeastFrequentlyUsed => "lfu"
    SoonestExpiry => "soonest-expiry"
    OldestFirst => "oldest"
    Largest => "largest"
  }
}
